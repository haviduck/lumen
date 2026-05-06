import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'tools/native_tool_format.dart';

/// Talks to Ollama. Supports cancellation via `CancellationToken` so the
/// "Stop Generation" button can interrupt in-flight requests.
class CancellationToken {
  bool _cancelled = false;
  http.Client? _client;

  /// Resolves on the first [cancel] call. Allows synchronous awaits
  /// (e.g. `Process.start` stdout collection in `RUN_CMD`) to **race**
  /// the cancellation signal via `Future.any([work, token.whenCancelled])`
  /// instead of polling `isCancelled` between awaits — which never
  /// fires for a hung subprocess.
  ///
  /// Idempotent: second `cancel()` is a no-op (Completer.complete
  /// would throw, so we guard with `isCompleted`).
  final Completer<void> _cancelCompleter = Completer<void>();
  Future<void> get whenCancelled => _cancelCompleter.future;

  bool get isCancelled => _cancelled;

  void attach(http.Client c) {
    _client = c;
    if (_cancelled) {
      try {
        c.close();
      } catch (_) {}
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    if (!_cancelCompleter.isCompleted) {
      _cancelCompleter.complete();
    }
    try {
      _client?.close();
    } catch (_) {}
  }
}

class OllamaService {
  String baseUrl;

  /// Optional Ollama Cloud API key. When set, Lumen can talk to
  /// `https://ollama.com` directly with `Authorization: Bearer <key>`
  /// for cloud-tagged models, bypassing the local daemon entirely.
  /// When empty, only the local [baseUrl] is used (the historic
  /// behaviour — cloud models still work IFF the user previously ran
  /// `ollama signin` against their local daemon, which proxies them
  /// transparently).
  ///
  /// Per Ollama Cloud docs (https://docs.ollama.com/cloud) the key
  /// is created at https://ollama.com/settings/keys and authenticates
  /// the same `/api/tags` and `/api/chat` shapes — only the host and
  /// auth header differ.
  String apiKey;

  OllamaService({this.baseUrl = 'http://localhost:11434', this.apiKey = ''});

  /// Cloud host. Same API shape as the local daemon — `/api/tags`
  /// for listing models, `/api/chat` for chat — but requires
  /// `Authorization: Bearer <apiKey>` and obviously goes over the
  /// public internet.
  static const String cloudBaseUrl = 'https://ollama.com';

  /// Whether a non-empty cloud API key is configured. Routes chat
  /// requests for cloud-tagged models to [cloudBaseUrl] when true.
  bool get hasCloudApiKey => apiKey.trim().isNotEmpty;

  /// Default `keep_alive` we send on every chat request.
  ///
  /// Why 30m: Ollama's default is 5 min, after which the model is
  /// unloaded (local) or the cloud slot is released (cloud). For an
  /// agentic workflow where a single turn can span many tool calls
  /// and the user might pause mid-conversation to read code or fix
  /// terminal output, 5 min is far too aggressive — every "cold"
  /// resume means a full prefix re-prefill, which on a 100K-token
  /// conversation against a 480B cloud model is 10–30s of dead air
  /// before the next token streams. 30 min covers realistic "AFK to
  /// look at the diff" gaps without keeping the slot pinned forever.
  /// Per-call override via [keepAlive].
  static const String defaultKeepAlive = '30m';

  /// Cloud-model heuristic. Ollama's cloud tags are suffixed
  /// `-cloud` (e.g. `gpt-oss:120b-cloud`, `qwen3-coder:480b-cloud`,
  /// `deepseek-v3.1:671b-cloud`). They're served from Ollama's
  /// datacenter; `num_ctx` is auto-pinned to the model's max so we
  /// must NOT send a smaller value (would shrink it). Other
  /// per-call options (temperature, etc.) are still respected.
  ///
  /// Used by callers that want to skip local-only tuning for
  /// cloud-routed requests.
  static bool isCloudModel(String rawModel) {
    return rawModel.endsWith('-cloud') || rawModel.endsWith(':cloud');
  }

  /// Strip Ollama's `-cloud` / `:cloud` marker from a raw model
  /// name. The local daemon expects the suffix (so it knows to proxy
  /// the request to Ollama's cloud), but the cloud endpoint at
  /// [cloudBaseUrl] expects the bare name (e.g. `gpt-oss:120b`, not
  /// `gpt-oss:120b-cloud`). Used when re-routing a request for a
  /// cloud-tagged model directly through the API-key path.
  static String stripCloudSuffix(String rawModel) {
    if (rawModel.endsWith('-cloud')) {
      return rawModel.substring(0, rawModel.length - '-cloud'.length);
    }
    if (rawModel.endsWith(':cloud')) {
      return rawModel.substring(0, rawModel.length - ':cloud'.length);
    }
    return rawModel;
  }

  /// Pick the right (host, headers, model) tuple for a chat request.
  ///
  /// Routing rules:
  ///   * [forceCloud] true (caller selected a model from the
  ///     `ollama-cloud:` namespace) → `cloudBaseUrl` with
  ///     `Authorization: Bearer <apiKey>`, model name unchanged
  ///     (cloud-namespace names are already bare).
  ///   * `apiKey` set + model carries the legacy `-cloud`/`:cloud`
  ///     suffix (came from the local `ollama:` namespace because
  ///     the user pulled it via SSO) → `cloudBaseUrl` with auth,
  ///     suffix stripped (cloud endpoint expects the bare name).
  ///   * otherwise → local [baseUrl], no auth, model unchanged.
  ///
  /// Centralised so `generateChat`, `generateChatStream`, and
  /// `summarizeTitle` all dispatch identically — adding a new
  /// route mode (e.g. a custom remote daemon) only touches this
  /// function.
  ({String host, Map<String, String> headers, String model})
      _resolveChatRoute(String rawModel, {bool forceCloud = false}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (forceCloud) {
      if (hasCloudApiKey) {
        headers['Authorization'] = 'Bearer ${apiKey.trim()}';
      }
      return (
        host: cloudBaseUrl,
        headers: headers,
        model: stripCloudSuffix(rawModel),
      );
    }
    if (hasCloudApiKey && isCloudModel(rawModel)) {
      headers['Authorization'] = 'Bearer ${apiKey.trim()}';
      return (
        host: cloudBaseUrl,
        headers: headers,
        model: stripCloudSuffix(rawModel),
      );
    }
    return (host: baseUrl, headers: headers, model: rawModel);
  }

  /// Non-streaming chat. Honours [token] cancellation by closing the client.
  /// Messages may carry `images` (base64) for multimodal models.
  ///
  /// [keepAlive] controls the daemon's model-residency timeout for this
  /// request; passing `null` falls through to Ollama's server default
  /// (5 min). [options] are forwarded under the `options` key
  /// (`num_ctx`, `temperature`, `num_predict`, …); leave empty for
  /// model defaults (and ALWAYS leave empty for cloud models, which
  /// auto-pin `num_ctx` to max).
  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'llama3',
    CancellationToken? token,
    String? keepAlive = defaultKeepAlive,
    Map<String, dynamic>? options,
    // Set when the caller already knows the request must hit Ollama
    // Cloud (e.g. routed from the `ollama-cloud:` provider namespace).
    // Bypasses the `-cloud` suffix heuristic.
    bool forceCloud = false,
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    final client = http.Client();
    token?.attach(client);
    try {
      final route = _resolveChatRoute(model, forceCloud: forceCloud);
      final payload = <String, dynamic>{
        'model': route.model,
        'messages': messages,
        'stream': false,
      };
      if (keepAlive != null) payload['keep_alive'] = keepAlive;
      if (options != null && options.isNotEmpty) payload['options'] = options;
      final body = jsonEncode(payload);

      final res = await client.post(
        Uri.parse('${route.host}/api/chat'),
        headers: route.headers,
        body: body,
      );

      if (token?.isCancelled == true) return '_(cancelled)_';

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        _maybeLogMetrics('generateChat', model, data);
        return data['message']?['content'] ?? '';
      }
      return 'Error: Server returned status code ${res.statusCode}\n${res.body}';
    } catch (e) {
      if (token?.isCancelled == true) return '_(cancelled)_';
      return 'Error connecting to Ollama: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Streaming chat. Yields individual content tokens as they arrive from
  /// Ollama's streaming API. Each event is a JSON object with
  /// `message.content` containing the next chunk.
  ///
  /// Currently unused — the chat controller routes through
  /// [generateChatStream] which adds idle-timeout protection. Kept here
  /// so callers that want a thinner abstraction can opt in. If
  /// nothing's calling this six months from now, delete it.
  Stream<String> streamChat(
    List<Map<String, dynamic>> messages, {
    String model = 'llama3',
    CancellationToken? token,
    String? keepAlive = defaultKeepAlive,
    Map<String, dynamic>? options,
    bool forceCloud = false,
  }) async* {
    if (token?.isCancelled == true) return;
    final client = http.Client();
    token?.attach(client);
    try {
      final route = _resolveChatRoute(model, forceCloud: forceCloud);
      final request = http.Request(
        'POST',
        Uri.parse('${route.host}/api/chat'),
      );
      request.headers.addAll(route.headers);
      final payload = <String, dynamic>{
        'model': route.model,
        'messages': messages,
        'stream': true,
      };
      if (keepAlive != null) payload['keep_alive'] = keepAlive;
      if (options != null && options.isNotEmpty) payload['options'] = options;
      request.body = jsonEncode(payload);

      final response = await client.send(request);

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield 'Error: Server returned status code ${response.statusCode}\n$body';
        return;
      }

      // Ollama streams newline-delimited JSON objects.
      final lineStream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (token?.isCancelled == true) break;
        if (line.trim().isEmpty) continue;
        try {
          final data = jsonDecode(line) as Map<String, dynamic>;
          final content = data['message']?['content'] as String? ?? '';
          if (content.isNotEmpty) {
            yield content;
          }
          // Ollama signals completion with `done: true`.
          if (data['done'] == true) break;
        } catch (e) {
          debugPrint('Ollama stream parse error: $e');
        }
      }
    } catch (e) {
      if (token?.isCancelled != true) {
        yield 'Error connecting to Ollama: $e';
      }
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Marker yielded BEFORE thinking content so the controller / UI
  /// can distinguish reasoning tokens from answer tokens.
  static const String thinkStartMarker = '<!-- LUMEN_THINK_START -->';

  /// Marker yielded AFTER the thinking phase ends (first content
  /// chunk arrives, or stream completes while still in thinking).
  static const String thinkEndMarker = '<!-- LUMEN_THINK_END -->';

  /// Streaming chat. Same payload shape as [generateChat] but with
  /// `stream: true` — Ollama responds with NDJSON (one JSON object
  /// per line). Each yielded `String` is an incremental content
  /// chunk for the chat UI to append to the in-progress assistant
  /// message. Errors / cancellation yield once and end the stream.
  ///
  /// **Thinking models** (Qwen 3, DeepSeek R1, GPT-OSS, etc.) emit
  /// a separate `message.thinking` field during their reasoning
  /// phase. We yield those tokens wrapped in `thinkStartMarker` /
  /// `thinkEndMarker` so the controller tracks activity and the UI
  /// can render a collapsible "Thinking…" section. Without this,
  /// the user sees dead air for the entire reasoning phase.
  ///
  /// Cancellation: closing `client` mid-response surfaces as a
  /// `ClientException` we swallow. The token's `isCancelled` is
  /// checked between chunks so a cancel takes effect within one
  /// chunk's worth of latency.
  Stream<String> generateChatStream(
    List<Map<String, dynamic>> messages, {
    String model = 'llama3',
    CancellationToken? token,
    // Max time between consecutive chunks before we declare the stream
    // hung and close it gracefully. Heavy models on weak hardware
    // (gemma:e31b on a hobby GPU; deepseek-coder-33b on a laptop) can
    // legitimately go quiet for 30-60s between tokens during KV-cache
    // thrash or VRAM pressure, so we lean generous. 1 hour with no
    // chunks means the server's effectively dead — abort.
    Duration idleTimeout = const Duration(minutes: 3),
    String? keepAlive = defaultKeepAlive,
    Map<String, dynamic>? options,
    bool forceCloud = false,
    Set<String>? nativeToolIds,
  }) async* {
    if (token?.isCancelled == true) return;
    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      final route = _resolveChatRoute(model, forceCloud: forceCloud);
      final translated = _translateMessagesForOllama(messages);
      final payload = <String, dynamic>{
        'model': route.model,
        'messages': translated,
        'stream': true,
      };
      if (keepAlive != null) payload['keep_alive'] = keepAlive;
      if (options != null && options.isNotEmpty) payload['options'] = options;
      if (nativeToolIds != null && nativeToolIds.isNotEmpty) {
        // Ollama tool-calling docs
        // (https://docs.ollama.com/capabilities/tool-calling) put
        // the `tools` array at the top level of /api/chat with the
        // OpenAI-style `[{type: 'function', function: {name,
        // description, parameters}}]` shape. Tool_calls in the
        // RESPONSE arrive across streaming chunks (per the
        // "Tool calling with streaming" section) — must be
        // accumulated, not just read from the final frame.
        payload['tools'] = NativeToolDefinitions.forOpenAi(nativeToolIds);
        // We deliberately do NOT send `think: true`. Per
        // https://docs.ollama.com/capabilities/thinking:
        //   "Thinking is enabled by default in the CLI and API
        //    for supported models."
        // So a redundant `true` is wasted noise. Worse, GPT-OSS
        // *ignores* boolean `think` and expects string levels
        // (`"low"` / `"medium"` / `"high"`). If we ever want to
        // tune reasoning intensity per model, the right place is
        // a small switch on `model` that maps `ReasoningEffort`
        // → `"low|medium|high"` for the GPT-OSS family and omits
        // the field for everyone else (since the default is
        // correct).
      }
      final body = jsonEncode(payload);
      final req = http.Request('POST', Uri.parse('${route.host}/api/chat'))
        ..headers.addAll(route.headers)
        ..body = body;
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final err = await res.stream.bytesToString();
        yield 'Error: Ollama returned ${res.statusCode}\n$err';
        return;
      }
      // NDJSON: lines like {"message":{"content":"..."},"done":false}
      // and a final {"done":true}.
      //
      // Thinking models add {"message":{"thinking":"..."}} chunks
      // before the content phase begins. We track the phase transition
      // to emit start/end markers exactly once.
      //
      // **Idle timeout** — `Stream.timeout(onTimeout: ...)` lets us
      // *close* the sink rather than throw, so the await-for below
      // exits cleanly and the chat controller still runs the
      // executor on whatever partial content we accumulated.
      final lineStream = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(idleTimeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      });
      // Two parallel "thinking" sources we have to handle:
      //
      //   1. `msg.thinking` — Ollama's proper separate field for
      //      reasoning models (Qwen, DeepSeek R1, GPT-OSS). The
      //      original happy path.
      //
      //   2. Inline `<think>...</think>` tags WITHIN `msg.content`
      //      — observed on glm-5.1:cloud where the model leaks
      //      its reasoning format into the visible stream. Without
      //      handling these, the user sees orphan `</think>` tags
      //      mid-reply.
      //
      // The controller's marker-based state machine is idempotent
      // (a thinkEndMarker while not in think mode is a no-op), so
      // we can over-emit at the seams without breaking it. That
      // simplifies things: each inline `<think>` block emits its
      // own start/end pair regardless of whether field-thinking
      // is also active.
      bool inThinking = false;
      bool inlineInThink = false;
      String inlineCarry = '';
      // Hold back this many trailing bytes between yields so a
      // `<think>` or `</think>` tag split across chunk boundaries
      // doesn't leak. `</think>` is 8 bytes — that's the max we
      // ever need.
      const inlineMinHold = 8;
      // **Tool-call accumulator.** Per the Ollama tool-calling docs
      // (https://docs.ollama.com/capabilities/tool-calling) tool_calls
      // are streamed across chunks — the docs' Python example
      // explicitly does `tool_calls.extend(chunk.message.tool_calls)`
      // on every chunk and then processes once at the end. Lumen's
      // single-tool-per-iter discipline emits a NativeToolUseMarker
      // for the FIRST tool_call we see and returns early — the
      // controller breaks on the marker. `seenToolCalls` flags this
      // so the done-frame fallback below doesn't emit twice.
      bool seenToolCalls = false;
      await for (final line in lineStream) {
        if (token?.isCancelled == true) return;
        if (line.isEmpty) continue;
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final msg = obj['message'] as Map<String, dynamic>?;
          final thinking = msg?['thinking'] as String?;
          final content = msg?['content'] as String?;
          final perChunkToolCalls = msg?['tool_calls'];

          // Emit native tool_calls as they arrive — NOT just on the
          // done frame. (See accumulator comment above for the
          // 2026-05 bug-fix history.) Single-tool-per-iter: the
          // first tool_call closes our stream cleanly, mirroring
          // the controller's text-grammar `cutOnFirstTool` boundary.
          if (!seenToolCalls &&
              perChunkToolCalls is List &&
              perChunkToolCalls.isNotEmpty) {
            seenToolCalls = true;
            final tc = perChunkToolCalls.first as Map<String, dynamic>;
            final fn = tc['function'] as Map<String, dynamic>? ?? const {};
            final name = (fn['name'] as String?) ?? '';
            final rawArgs = fn['arguments'];
            Map<String, dynamic> args;
            if (rawArgs is Map) {
              args = rawArgs.cast<String, dynamic>();
            } else if (rawArgs is String) {
              try {
                args = (jsonDecode(rawArgs) as Map).cast<String, dynamic>();
              } catch (_) {
                args = <String, dynamic>{};
              }
            } else {
              args = <String, dynamic>{};
            }
            // Close any open thinking phase so the controller's
            // marker state machine doesn't leave the live message
            // stuck in "thinking…" while we ship the tool call.
            if (inThinking) {
              inThinking = false;
              yield thinkEndMarker;
            }
            if (inlineInThink) {
              inlineInThink = false;
              yield thinkEndMarker;
            }
            if (name.isNotEmpty) {
              yield NativeToolUseMarker.build(
                id: 'ollama-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
                name: name,
                arguments: args,
              );
              // Return early: the controller's break-on-marker has
              // already fired, the model has nothing useful to add
              // before the tool_result round-trips. Closing our
              // stream here releases the upstream HTTP connection
              // promptly instead of letting it drain.
              return;
            }
          }

          // Phase: thinking tokens arriving.
          if (thinking != null && thinking.isNotEmpty) {
            if (!inThinking) {
              inThinking = true;
              yield thinkStartMarker;
            }
            yield thinking;
          }

          // Phase transition: first content chunk closes thinking.
          if (content != null && content.isNotEmpty) {
            if (inThinking) {
              inThinking = false;
              yield thinkEndMarker;
            }
            // Run content through the inline-`<think>` state
            // machine. Anything that's NOT inside a `<think>...
            // </think>` block is yielded as content; anything
            // inside is yielded as content but bracketed by
            // think-markers so the controller routes it to the
            // thinking buffer. Orphan `</think>` (close without
            // matching open) is silently dropped.
            inlineCarry += content;
            bool keepProcessing = true;
            while (keepProcessing) {
              if (!inlineInThink) {
                final openIdx = inlineCarry.indexOf('<think>');
                final orphanIdx = inlineCarry.indexOf('</think>');
                final firstIsOpen = openIdx >= 0 &&
                    (orphanIdx < 0 || openIdx < orphanIdx);
                final firstIsOrphan = orphanIdx >= 0 &&
                    (openIdx < 0 || orphanIdx < openIdx);
                if (firstIsOpen) {
                  if (openIdx > 0) {
                    yield inlineCarry.substring(0, openIdx);
                  }
                  yield thinkStartMarker;
                  inlineInThink = true;
                  inlineCarry =
                      inlineCarry.substring(openIdx + '<think>'.length);
                } else if (firstIsOrphan) {
                  if (orphanIdx > 0) {
                    yield inlineCarry.substring(0, orphanIdx);
                  }
                  inlineCarry = inlineCarry
                      .substring(orphanIdx + '</think>'.length);
                } else {
                  if (inlineCarry.length > inlineMinHold) {
                    yield inlineCarry.substring(
                      0,
                      inlineCarry.length - inlineMinHold,
                    );
                    inlineCarry = inlineCarry.substring(
                      inlineCarry.length - inlineMinHold,
                    );
                  }
                  keepProcessing = false;
                }
              } else {
                final closeIdx = inlineCarry.indexOf('</think>');
                if (closeIdx >= 0) {
                  if (closeIdx > 0) {
                    yield inlineCarry.substring(0, closeIdx);
                  }
                  yield thinkEndMarker;
                  inlineInThink = false;
                  inlineCarry = inlineCarry
                      .substring(closeIdx + '</think>'.length);
                } else {
                  if (inlineCarry.length > inlineMinHold) {
                    yield inlineCarry.substring(
                      0,
                      inlineCarry.length - inlineMinHold,
                    );
                    inlineCarry = inlineCarry.substring(
                      inlineCarry.length - inlineMinHold,
                    );
                  }
                  keepProcessing = false;
                }
              }
            }
          }

          if (obj['done'] == true) {
            // Flush any inline carry — a final chunk might have
            // ended mid-tag-detection-window, but the stream is
            // closing so we have to surface what's left.
            if (inlineCarry.isNotEmpty) {
              yield inlineCarry;
              inlineCarry = '';
            }
            if (inlineInThink) {
              inlineInThink = false;
              yield thinkEndMarker;
            }
            // Close thinking if stream ended mid-reasoning (model
            // exhausted output budget during think phase).
            if (inThinking) {
              inThinking = false;
              yield thinkEndMarker;
            }
            // Done-frame tool_calls fallback. The mid-stream
            // accumulator above is the primary path (per the docs,
            // tool_calls are streamed). Some Ollama versions /
            // models still consolidate them onto the done frame —
            // we honour that path too, but ONLY when we haven't
            // already emitted from a mid-stream chunk. Without the
            // `!seenToolCalls` guard we'd emit the same call twice.
            final finalMsg = msg ?? obj['message'] as Map<String, dynamic>?;
            final toolCalls = finalMsg?['tool_calls'];
            if (!seenToolCalls && toolCalls is List && toolCalls.isNotEmpty) {
              final tc = toolCalls.first as Map<String, dynamic>;
              final fn = tc['function'] as Map<String, dynamic>? ?? const {};
              final name = (fn['name'] as String?) ?? '';
              final rawArgs = fn['arguments'];
              Map<String, dynamic> args;
              if (rawArgs is Map) {
                args = rawArgs.cast<String, dynamic>();
              } else if (rawArgs is String) {
                // Some Ollama models return arguments as a JSON
                // string even though the docs say object. Tolerate
                // both shapes.
                try {
                  args = (jsonDecode(rawArgs) as Map).cast<String, dynamic>();
                } catch (e) {
                  debugPrint(
                    'Ollama tool_calls arg parse failed: $e ($rawArgs)',
                  );
                  args = <String, dynamic>{};
                }
              } else {
                args = <String, dynamic>{};
              }
              final providedId = tc['id'];
              final id = (providedId is String && providedId.isNotEmpty)
                  ? providedId
                  : 'ollama-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
              if (name.isNotEmpty) {
                yield NativeToolUseMarker.build(
                  id: id, name: name, arguments: args,
                );
              }
            }
            // Final frame carries timing metrics + done_reason.
            // Surface a hidden marker when the model hit its output
            // token cap (`length`) so the controller can auto-
            // continue.
            final reason = obj['done_reason'] as String?;
            if (reason == 'length') {
              yield '\n<!-- LUMEN_TRUNCATED:length -->\n';
            }
            _maybeLogMetrics('generateChatStream', model, obj);
            return;
          }
        } catch (_) {
          // Skip malformed line — Ollama occasionally emits empty or
          // partial frames during disconnects.
        }
      }
      // Flush inline state on stream-end-without-done (timeout,
      // disconnect). Same shape as the done branch above so we
      // never leave the controller's think-phase flag in a
      // permanently-stuck state.
      if (inlineCarry.isNotEmpty) {
        yield inlineCarry;
        inlineCarry = '';
      }
      if (inlineInThink) {
        inlineInThink = false;
        yield thinkEndMarker;
      }
      // Close thinking if we exited via timeout while still reasoning.
      if (inThinking) {
        yield thinkEndMarker;
      }
      if (timedOut && token?.isCancelled != true) {
        yield '\n\n_(generation paused — no response from Ollama for '
            '${idleTimeout.inMinutes} min. The model may have stalled '
            '— send a follow-up to continue, or pick a smaller model.)_\n';
      }
    } catch (e) {
      if (token?.isCancelled == true) return;
      yield 'Error connecting to Ollama: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Fetch the list of models the daemon currently exposes via
  /// `/api/tags`. Returns an empty list on **any** failure
  /// (unreachable, non-200, malformed JSON) — the picker has its
  /// own "No models available" empty state, and silently substituting
  /// a hardcoded list of model names the user almost certainly
  /// hasn't pulled is worse than showing nothing: the user picks
  /// `ollama:llama3`, sends a message, and gets a generation error
  /// because the model doesn't exist on this machine.
  ///
  /// Callers that need to *know* whether Ollama is reachable should
  /// gate on [isReachable] in addition to / instead of treating an
  /// empty list as "down".
  Future<List<String>> getModels() async {
    try {
      final res = await http.get(Uri.parse('$baseUrl/api/tags'));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        return (data['models'] as List).map((m) => m['name'] as String).toList();
      }
    } catch (e) {
      debugPrint('Error fetching models: $e');
    }
    return const <String>[];
  }

  /// Fetch the list of cloud-hosted models reachable via the Ollama
  /// Cloud API key path (`https://ollama.com/api/tags`). Returns the
  /// names exactly as the API surfaces them (bare — `gpt-oss:120b`,
  /// `deepseek-v3.1:671b`, etc.). The `-cloud` suffix that the
  /// LOCAL daemon uses to mark a proxied cloud pull is intentionally
  /// stripped if the API ever sent one, because in our model surface
  /// the namespace prefix (`ollama-cloud:`) already carries that
  /// information — callers route on the prefix, not on a name suffix.
  ///
  /// We always attach the `Authorization: Bearer <key>` header when
  /// a key is set; the public catalogue is reachable without auth
  /// but per-account model entitlements aren't, and there's no
  /// downside to authenticating an idempotent GET.
  ///
  /// Returns an empty list when no key is configured or any failure
  /// occurs (network, non-200, malformed JSON). Mirrors [getModels]
  /// — the picker has its own "no models" empty state, and we'd
  /// rather show nothing than ghost entries the user can't actually
  /// run.
  Future<List<String>> getCloudModels() async {
    if (!hasCloudApiKey) return const <String>[];
    try {
      final res = await http.get(
        Uri.parse('$cloudBaseUrl/api/tags'),
        headers: {'Authorization': 'Bearer ${apiKey.trim()}'},
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint(
          'Ollama Cloud /api/tags returned ${res.statusCode}: ${res.body}',
        );
        return const <String>[];
      }
      final data = jsonDecode(res.body);
      final models = (data['models'] as List?) ?? const [];
      return models
          .map((m) => (m as Map)['name'] as String)
          .map(stripCloudSuffix)
          .toList(growable: false);
    } catch (e) {
      debugPrint('Error fetching Ollama Cloud models: $e');
      return const <String>[];
    }
  }

  /// Translate the controller's neutral message shape into Ollama's
  /// wire format. Per the Ollama tool-calling docs
  /// (https://docs.ollama.com/capabilities/tool-calling):
  ///
  ///   - **Assistant turn with native tool_use** carries
  ///     `tool_calls: [{type: 'function', function: {index, name,
  ///     arguments}}]` where `arguments` is a Map, not a JSON-encoded
  ///     string (OpenAI uses encoded; Ollama uses raw). No outer
  ///     `id` field — Ollama matches replies by tool **name**, not
  ///     by a call-site id.
  ///   - **Tool result reply** uses `role: 'tool'` with the
  ///     literal field `tool_name: <function name>` (NOT
  ///     `tool_call_id`). The 2026-05 first-cut implementation
  ///     used `tool_call_id` after copying OpenAI's shape; that
  ///     broke the link Ollama needs between calls and replies,
  ///     manifesting as "model thought, kept calling tools we
  ///     never saw, looped".
  ///   - Non-native messages pass through with classic
  ///     `{role, content, images?}` shape.
  ///
  /// Pure transformation; doesn't mutate the input list.
  List<Map<String, dynamic>> _translateMessagesForOllama(
    List<Map<String, dynamic>> messages,
  ) {
    return [
      for (final m in messages) _translateOneOllamaMessage(m),
    ];
  }

  Map<String, dynamic> _translateOneOllamaMessage(Map<String, dynamic> m) {
    final role = m['role'] as String? ?? 'user';
    if (role == 'tool') {
      return {
        'role': 'tool',
        // Ollama links replies to calls by function name. The
        // controller stamps `tool_name` on every tool reply (along
        // with `tool_use_id` for OpenAI/Anthropic compatibility).
        // Falls back to `tool_use_id` for very old chat history
        // recorded before the field existed — better wrong-ish
        // than empty.
        'tool_name': (m['tool_name'] as String?) ??
            (m['tool_use_id'] as String?) ??
            '',
        'content': (m['content'] as String?) ?? '',
      };
    }
    final out = <String, dynamic>{
      'role': role,
      'content': (m['content'] as String?) ?? '',
    };
    final images = m['images'];
    if (images is List && images.isNotEmpty) {
      out['images'] = images;
    }
    final toolUse = m['tool_use'];
    if (role == 'assistant' && toolUse is Map<String, dynamic>) {
      final args =
          (toolUse['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
      out['tool_calls'] = <Map<String, dynamic>>[
        {
          'type': 'function',
          'function': {
            'index': 0,
            'name': (toolUse['name'] as String?) ?? '',
            'arguments': args,
          },
        },
      ];
    }
    return out;
  }

  /// Per-model capability cache. `/api/show` exposes the
  /// `capabilities` array (e.g. `["completion", "tools", "vision"]`)
  /// for installed local models AND for cloud models when authed.
  /// We hit the endpoint once per (host, model) tuple and remember
  /// the answer for the lifetime of the [OllamaService] instance —
  /// capabilities don't change between pulls and re-querying every
  /// turn would add 50–150 ms of latency before the prompt-cache
  /// warm path even starts.
  ///
  /// Cache key folds in the route (`local|cloud`) because the same
  /// model name can resolve to different daemons (a `qwen3:8b`
  /// pulled locally vs. the cloud catalogue entry of the same name)
  /// and we want each route's capability sniffed independently.
  final Map<String, Set<String>> _capabilityCache = <String, Set<String>>{};

  /// Returns the model's capability set per `/api/show`, or an
  /// empty set on any failure (unreachable / non-200 / malformed /
  /// missing key for cloud). Capabilities of interest are
  /// `tools` (native function calling), `vision` (multimodal),
  /// `embedding`, `completion`, `thinking`. Callers should treat
  /// "not found" as "no, the model doesn't have it" — we don't
  /// want to gamble on a yes when the daemon couldn't tell us.
  ///
  /// [forceCloud] mirrors the `generateChatStream` flag — needed
  /// because some `qwen3-coder:480b`-style names are reachable
  /// via both routes and we want each cached separately.
  Future<Set<String>> getModelCapabilities(
    String rawModel, {
    bool forceCloud = false,
  }) async {
    final route = _resolveChatRoute(rawModel, forceCloud: forceCloud);
    final cacheKey = '${route.host}|${route.model}';
    final hit = _capabilityCache[cacheKey];
    if (hit != null) return hit;
    try {
      final res = await http
          .post(
            Uri.parse('${route.host}/api/show'),
            headers: route.headers,
            body: jsonEncode({'model': route.model}),
          )
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) {
        debugPrint(
          'Ollama /api/show ${route.model} returned ${res.statusCode}',
        );
        final empty = <String>{};
        _capabilityCache[cacheKey] = empty;
        return empty;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final caps = (data['capabilities'] as List?)
              ?.whereType<String>()
              .toSet() ??
          <String>{};
      _capabilityCache[cacheKey] = caps;
      return caps;
    } catch (e) {
      debugPrint('Ollama getModelCapabilities ${route.model} failed: $e');
      final empty = <String>{};
      _capabilityCache[cacheKey] = empty;
      return empty;
    }
  }

  /// Convenience: does this model support native tool calling?
  /// Equivalent to `(await getModelCapabilities(model)).contains('tools')`.
  /// Used by `ChatController._shouldUseNativeTools` to gate the
  /// native-tools strategy on Ollama-routed models.
  Future<bool> modelSupportsTools(
    String rawModel, {
    bool forceCloud = false,
  }) async {
    final caps = await getModelCapabilities(rawModel, forceCloud: forceCloud);
    return caps.contains('tools');
  }

  /// Drop the capability cache. Wired to provider-settings save and
  /// model-list refresh in `ChatController` so a user pulling a new
  /// model OR rotating the cloud API key sees fresh capability info
  /// without restarting Lumen.
  void clearCapabilityCache() {
    _capabilityCache.clear();
  }

  /// Lightweight "is the cloud key valid?" probe. GETs
  /// `https://ollama.com/api/tags` with the configured key and
  /// returns true on a 200. Used by Settings UI to validate a
  /// pasted key before save.
  Future<bool> isCloudReachable() async {
    if (!hasCloudApiKey) return false;
    try {
      final res = await http.get(
        Uri.parse('$cloudBaseUrl/api/tags'),
        headers: {'Authorization': 'Bearer ${apiKey.trim()}'},
      ).timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Run an Ollama Cloud web search. Hits
  /// `POST https://ollama.com/api/web_search` with the configured
  /// API key (https://docs.ollama.com/capabilities/web-search) and
  /// returns the parsed JSON body — `{ results: [{title, url, content}, …] }`.
  ///
  /// [maxResults] is clamped to 1..10 (the API's documented bounds).
  /// Throws [StateError] when no API key is set, [HttpException] for
  /// non-2xx responses, and lets [TimeoutException] propagate after
  /// 30 s — the caller (a tool body) translates these into a
  /// human-readable feedback string for the agent.
  Future<Map<String, dynamic>> webSearch(
    String query, {
    int maxResults = 5,
  }) async {
    if (!hasCloudApiKey) {
      throw StateError(
        'Ollama Cloud API key is not configured. Set it in '
        'Settings → AI / Chat → Ollama Cloud API key.',
      );
    }
    final clamped = maxResults.clamp(1, 10);
    final res = await http
        .post(
          Uri.parse('$cloudBaseUrl/api/web_search'),
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'query': query, 'max_results': clamped}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException(
        'Ollama Cloud /api/web_search returned ${res.statusCode}: ${res.body}',
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Ollama Cloud /api/web_search returned a non-object body',
      );
    }
    return decoded;
  }

  /// Fetch a single URL via Ollama Cloud's web-fetch endpoint
  /// (`POST https://ollama.com/api/web_fetch`). Returns the parsed
  /// JSON body — `{ title, content, links: [...] }`.
  ///
  /// We deliberately go through Ollama rather than a direct HTTP
  /// request because (a) the cloud endpoint already strips ads /
  /// boilerplate and renders SPA content, and (b) it hides the
  /// user's IP from the target site. Throws on misconfiguration /
  /// network / non-2xx responses; see [webSearch] for the error
  /// taxonomy.
  Future<Map<String, dynamic>> webFetch(String url) async {
    if (!hasCloudApiKey) {
      throw StateError(
        'Ollama Cloud API key is not configured. Set it in '
        'Settings → AI / Chat → Ollama Cloud API key.',
      );
    }
    final res = await http
        .post(
          Uri.parse('$cloudBaseUrl/api/web_fetch'),
          headers: {
            'Authorization': 'Bearer ${apiKey.trim()}',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'url': url}),
        )
        .timeout(const Duration(seconds: 30));
    if (res.statusCode < 200 || res.statusCode >= 300) {
      throw HttpException(
        'Ollama Cloud /api/web_fetch returned ${res.statusCode}: ${res.body}',
      );
    }
    final decoded = jsonDecode(res.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException(
        'Ollama Cloud /api/web_fetch returned a non-object body',
      );
    }
    return decoded;
  }

  /// Lightweight reachability check. Does Ollama's HTTP API respond
  /// at the configured `baseUrl` with a 200 right now? Returns false
  /// for any error (network, timeout, non-200).
  ///
  /// Complementary to [getModels], which returns an empty list on
  /// the same failure modes — features that need to distinguish
  /// "Ollama is down" from "Ollama is up but has no models pulled
  /// yet" should gate on `isReachable()` directly. Both share the
  /// same `/api/tags` endpoint, so a positive `isReachable` plus an
  /// empty `getModels` is the canonical "running but empty" signal.
  ///
  /// Times out at 4 seconds — Ollama is local; if it can't answer
  /// in 4s it's effectively down.
  Future<bool> isReachable() async {
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/api/tags'))
          .timeout(const Duration(seconds: 4));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Whether the `ollama` CLI binary is on PATH. Distinct from
  /// [isReachable] — `isInstalled` only confirms the executable
  /// resolves; the daemon may still be stopped (in which case
  /// `isReachable()` will be false).
  ///
  /// Used by the new-project wizard to distinguish "user needs to
  /// download Ollama from ollama.com/download" (not installed) from
  /// "user needs to start the Ollama service" (installed but
  /// unreachable). 6 s budget — `ollama --version` is normally
  /// sub-second; we lean generous because cold starts on Windows
  /// can stall briefly while AV scans the binary on first run.
  Future<bool> isInstalled() async {
    try {
      final result = await Process.run(
        'ollama',
        const ['--version'],
        runInShell: true,
      ).timeout(const Duration(seconds: 6));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Helper for naming chat sessions: ask the model to summarize the
  /// first user message in 4-6 words. Uses a small temperature & cap to
  /// keep responses short.
  ///
  /// Sends `keep_alive` so the daemon (or cloud slot) stays warm for
  /// the chat that immediately follows — without this, title
  /// summarization would race with the first chat turn for the model
  /// load / cloud slot, occasionally adding seconds to the user's
  /// first response.
  Future<String> summarizeTitle(
    String firstMessage, {
    String model = 'llama3',
    bool forceCloud = false,
  }) async {
    try {
      final route = _resolveChatRoute(model, forceCloud: forceCloud);
      final res = await http.post(
        Uri.parse('${route.host}/api/chat'),
        headers: route.headers,
        body: jsonEncode({
          'model': route.model,
          'stream': false,
          'keep_alive': defaultKeepAlive,
          'options': {'temperature': 0.2, 'num_predict': 24},
          'messages': [
            {
              'role': 'system',
              'content':
                  'Reply with a 3-6 word title summarizing the user message. No quotes, no punctuation at the end, no preamble.'
            },
            {'role': 'user', 'content': firstMessage},
          ],
        }),
      );
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final raw = (data['message']?['content'] ?? '') as String;
        final cleaned = raw.replaceAll(RegExp(r'["`*\n]'), '').trim();
        if (cleaned.isNotEmpty) return cleaned;
      }
    } catch (_) {}
    final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    return fallback.length > 40 ? '${fallback.substring(0, 40)}…' : fallback;
  }

  /// Emit a one-line debug log with the per-request timing metrics
  /// Ollama returns in its final frame. Fields:
  ///
  /// - `prompt_eval_count` — tokens evaluated for the prompt this
  ///   turn. Near-zero on a warm KV-cache hit; near full context
  ///   length on a cold miss. The single best signal for diagnosing
  ///   "why did the follow-up take 8 seconds before the first token".
  /// - `prompt_eval_duration` (ns) — wall time spent on prefill.
  /// - `eval_count` / `eval_duration` (ns) — generated tokens and
  ///   the time it took. Ratio is your generation tok/s.
  /// - `total_duration` (ns) — full request, useful as a sanity
  ///   bound (network + queue + prefill + gen).
  /// - `done_reason` — `stop` (natural), `length` (hit num_predict),
  ///   `load` (couldn't load), etc. Blank/missing on older
  ///   Ollama versions; useful for diagnosing "why did the model
  ///   stop mid-thought".
  ///
  /// Debug-only — release builds skip the print. Cheap to leave on
  /// in dev; emits one line per LLM request.
  static void _maybeLogMetrics(
    String origin,
    String model,
    Map<String, dynamic> frame,
  ) {
    if (!kDebugMode) return;
    final pec = frame['prompt_eval_count'];
    final ped = frame['prompt_eval_duration'];
    final ec = frame['eval_count'];
    final ed = frame['eval_duration'];
    final td = frame['total_duration'];
    final dr = frame['done_reason'];
    // Skip frames that don't carry timing — older daemons or
    // intermediate frames the caller forwarded by mistake.
    if (pec == null && ec == null) return;
    String ms(num? ns) =>
        ns == null ? '?' : '${(ns / 1e6).toStringAsFixed(0)}ms';
    String tps(num? count, num? durNs) {
      if (count == null || durNs == null || durNs == 0) return '?';
      final s = durNs / 1e9;
      return '${(count / s).toStringAsFixed(1)} tok/s';
    }
    debugPrint(
      '[ollama:$origin] $model '
      'prompt=${pec ?? '?'}t/${ms(ped)} (${tps(pec, ped)}) '
      'gen=${ec ?? '?'}t/${ms(ed)} (${tps(ec, ed)}) '
      'total=${ms(td)}'
      '${dr != null ? ' done=$dr' : ''}',
    );
  }
}
