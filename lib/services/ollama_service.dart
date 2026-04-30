import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

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

  OllamaService({this.baseUrl = 'http://localhost:11434'});

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
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    final client = http.Client();
    token?.attach(client);
    try {
      final payload = <String, dynamic>{
        'model': model,
        'messages': messages,
        'stream': false,
      };
      if (keepAlive != null) payload['keep_alive'] = keepAlive;
      if (options != null && options.isNotEmpty) payload['options'] = options;
      final body = jsonEncode(payload);

      final res = await client.post(
        Uri.parse('$baseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
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
  }) async* {
    if (token?.isCancelled == true) return;
    final client = http.Client();
    token?.attach(client);
    try {
      final request = http.Request(
        'POST',
        Uri.parse('$baseUrl/api/chat'),
      );
      request.headers['Content-Type'] = 'application/json';
      final payload = <String, dynamic>{
        'model': model,
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

  /// Streaming chat. Same payload shape as [generateChat] but with
  /// `stream: true` — Ollama responds with NDJSON (one JSON object
  /// per line). Each yielded `String` is an incremental content
  /// chunk for the chat UI to append to the in-progress assistant
  /// message. Errors / cancellation yield once and end the stream.
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
  }) async* {
    if (token?.isCancelled == true) return;
    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      final payload = <String, dynamic>{
        'model': model,
        'messages': messages,
        'stream': true,
      };
      if (keepAlive != null) payload['keep_alive'] = keepAlive;
      if (options != null && options.isNotEmpty) payload['options'] = options;
      final body = jsonEncode(payload);
      final req = http.Request('POST', Uri.parse('$baseUrl/api/chat'))
        ..headers['Content-Type'] = 'application/json'
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
      // **Idle timeout** — `Stream.timeout(onTimeout: ...)` lets us
      // *close* the sink rather than throw, so the await-for below
      // exits cleanly and the chat controller still runs the
      // executor on whatever partial content we accumulated.
      // Trying to do this with try/catch around `await for` instead
      // would mean tossing the partial content into the catch block.
      final lineStream = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(idleTimeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      });
      await for (final line in lineStream) {
        if (token?.isCancelled == true) return;
        if (line.isEmpty) continue;
        try {
          final obj = jsonDecode(line) as Map<String, dynamic>;
          final content = obj['message']?['content'] as String?;
          if (content != null && content.isNotEmpty) yield content;
          if (obj['done'] == true) {
            // Final frame carries timing metrics + done_reason.
            // Surface a hidden marker when the model hit its output
            // token cap (`length`) so the controller can auto-
            // continue: the model has more to say and we know it.
            // Markdown ignores the comment, downstream chat parser
            // doesn't match LUMEN_TRUNCATED (it's a separate matcher
            // from LUMEN_TOOL / LUMEN_ERR), but the controller's
            // post-stream scan picks it up.
            //
            // We log timing in debug so devs can tell prefill
            // latency apart from generation latency.
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
      // Append a one-liner so the user knows we cut early. Markdown
      // italic so it visually separates from the model's content.
      // Only fires when the stream ended via timeout, not on natural
      // completion or cancellation.
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
    return ['llama3', 'mistral', 'phi3'];
  }

  /// Lightweight reachability check. Does Ollama's HTTP API respond
  /// at the configured `baseUrl` with a 200 right now? Returns false
  /// for any error (network, timeout, non-200).
  ///
  /// Distinct from `getModels()` which intentionally falls back to a
  /// hardcoded list when unreachable — that fallback is a UX nicety
  /// for the model picker, but features that need a working LLM
  /// (e.g. the skill generator) MUST gate on `isReachable()` instead.
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
  Future<String> summarizeTitle(String firstMessage, {String model = 'llama3'}) async {
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': model,
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
