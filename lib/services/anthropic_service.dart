import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ollama_service.dart' show CancellationToken;
import 'reasoning_effort.dart';
import 'tools/native_tool_format.dart';

/// Detect image MIME type from base64 data by inspecting magic bytes.
/// Falls back to image/jpeg since that's what our resize pipeline produces.
String _detectMediaType(String base64Data) {
  if (base64Data.length < 8) return 'image/jpeg';
  try {
    final bytes = base64Decode(base64Data.substring(0, 16));
    if (bytes.length >= 8 &&
        bytes[0] == 0x89 &&
        bytes[1] == 0x50 &&
        bytes[2] == 0x4E &&
        bytes[3] == 0x47) {
      return 'image/png';
    }
    if (bytes.length >= 3 &&
        bytes[0] == 0xFF &&
        bytes[1] == 0xD8 &&
        bytes[2] == 0xFF) {
      return 'image/jpeg';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x52 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x46) {
      return 'image/webp';
    }
    if (bytes.length >= 4 &&
        bytes[0] == 0x47 &&
        bytes[1] == 0x49 &&
        bytes[2] == 0x46 &&
        bytes[3] == 0x38) {
      return 'image/gif';
    }
  } catch (_) {}
  return 'image/jpeg';
}

/// Talks to Anthropic's Claude Messages API.
///
/// The rest of Lumen speaks an Ollama-style message shape:
/// `{role, content, images?}`. This service adapts that shape to
/// Anthropic's `system` + `messages[].content[]` format while keeping
/// the same cancellation and streaming behaviour as the other providers.
class AnthropicService {
  String apiKey;
  String baseUrl;

  AnthropicService({
    this.apiKey = '',
    this.baseUrl = 'https://api.anthropic.com',
  });

  static const _anthropicVersion = '2023-06-01';

  Map<String, String> get _headers => {
    'Content-Type': 'application/json',
    'x-api-key': apiKey,
    'anthropic-version': _anthropicVersion,
  };

  Map<String, dynamic> _buildRequestBody(
    List<Map<String, dynamic>> messages, {
    required String model,
    required int maxTokens,
    double temperature = 0.7,
    ReasoningEffort? effort,
    Set<String>? nativeToolIds,
  }) {
    final systemParts = <String>[];
    final converted = <Map<String, dynamic>>[];

    for (final m in messages) {
      final role = m['role'] as String;
      final content = m['content'] as String? ?? '';
      if (role == 'system') {
        if (content.isNotEmpty) systemParts.add(content);
        continue;
      }

      // Native tool-result reply (came from the executor in a prior
      // iteration). Anthropic encodes this as a `user` message
      // carrying a single `tool_result` content block referencing
      // the assistant's `tool_use_id`.
      if (role == 'tool') {
        final toolUseId = (m['tool_use_id'] as String?) ?? '';
        converted.add({
          'role': 'user',
          'content': <Map<String, dynamic>>[
            {
              'type': 'tool_result',
              'tool_use_id': toolUseId,
              'content': content,
            },
          ],
        });
        continue;
      }

      final blocks = <Map<String, dynamic>>[];
      if (content.isNotEmpty) {
        blocks.add({'type': 'text', 'text': content});
      }

      // Native tool_use carried on an assistant turn. Anthropic
      // requires the tool_use block alongside the prose in the
      // SAME assistant message, otherwise the next tool_result
      // can't reference the id.
      final toolUse = m['tool_use'];
      if (role == 'assistant' && toolUse is Map<String, dynamic>) {
        blocks.add({
          'type': 'tool_use',
          'id': (toolUse['id'] as String?) ?? '',
          'name': (toolUse['name'] as String?) ?? '',
          'input':
              (toolUse['arguments'] as Map?)?.cast<String, dynamic>() ?? {},
        });
      }

      final images = m['images'] as List<dynamic>? ?? [];
      for (final img in images) {
        blocks.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': _detectMediaType(img as String),
            'data': img as String,
          },
        });
      }

      if (blocks.isEmpty) continue;
      converted.add({
        'role': role == 'assistant' ? 'assistant' : 'user',
        'content': blocks,
      });
    }

    // Anthropic is happiest with alternating turns. Tool feedback can
    // produce consecutive user messages, so merge adjacent same-role turns.
    final merged = <Map<String, dynamic>>[];
    for (final msg in converted) {
      if (merged.isNotEmpty && merged.last['role'] == msg['role']) {
        (merged.last['content'] as List).addAll(msg['content'] as List);
      } else {
        merged.add({
          'role': msg['role'],
          'content': List<Map<String, dynamic>>.from(msg['content'] as List),
        });
      }
    }

    if (merged.isNotEmpty && merged.first['role'] != 'user') {
      merged.insert(0, {
        'role': 'user',
        'content': [
          {'type': 'text', 'text': '(start)'},
        ],
      });
    }

    final body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
      'temperature': temperature,
      'messages': merged,
    };
    if (systemParts.isNotEmpty) {
      // Send `system` as a content-block array (instead of a plain
      // string) so we can attach `cache_control: {type: 'ephemeral'}`
      // to the last block. Anthropic's prompt cache then covers the
      // entire system prompt on every subsequent turn within ~5 min,
      // turning a large prefill into a near-zero-cost lookup. Plain
      // strings can't carry cache_control, hence the array form.
      final joined = systemParts.join('\n\n');
      body['system'] = [
        {
          'type': 'text',
          'text': joined,
          'cache_control': {'type': 'ephemeral'},
        },
      ];
    }

    // Attach native tool definitions when the caller wants the
    // structured `tools[]` path. We let Claude choose freely
    // (tool_choice: auto) — forcing a tool with `tool_choice:
    // {type: "tool", name: "..."}` would break the agentic loop.
    if (nativeToolIds != null && nativeToolIds.isNotEmpty) {
      body['tools'] = NativeToolDefinitions.forAnthropic(nativeToolIds);
      body['tool_choice'] = {'type': 'auto'};
    }

    // **Extended thinking** — Claude Opus 4+ / Sonnet 4+ accept a
    // `thinking` block that allocates internal reasoning tokens before
    // the model emits user-visible text. Anthropic requires
    // `temperature == 1` whenever a thinking block is present (any
    // other value 400s with `temperature may only be set to 1 when
    // thinking is enabled`), so we override the caller's temperature
    // for both the adaptive and legacy shapes below.
    //
    // Two API shapes coexist:
    //
    //   1. **Adaptive** (Opus 4.7+, ~Apr 2026): `thinking: {type:
    //      "adaptive"}` + `output_config: {effort: "low"|"medium"|
    //      "high"|"xhigh"|"max"}`. The model picks the budget itself;
    //      `budget_tokens` is REJECTED with a 400 on these models.
    //   2. **Legacy** (Opus 4.0–4.6, Sonnet 4.0–4.6): `thinking: {type:
    //      "enabled", budget_tokens: <int>}`. Unknown to Opus 4.7.
    //
    // [ReasoningEffortHelper.usesAdaptiveThinking] dispatches between
    // the two; defaults to legacy on unknown models so older Claudes
    // still work. [modelSupportsNative] gates Haiku / 3.x out from
    // both paths.
    final thinkingCapable = ReasoningEffortHelper.modelSupportsNative(
      provider: 'claude',
      rawModel: model,
    );
    // Anthropic enforces `temperature == 1` on thinking-capable models
    // (Sonnet 4+, Opus 4+) regardless of whether a `thinking` block is
    // present. Sending any other value 400s with "temperature may only
    // be set to 1 when thinking is enabled". Override unconditionally
    // so callers that don't pass `effort` (e.g. the council agent
    // runner) don't hit this.
    if (thinkingCapable) {
      body['temperature'] = 1.0;
    }

    if (effort != null && effort != ReasoningEffort.off && thinkingCapable) {
      if (ReasoningEffortHelper.usesAdaptiveThinking(rawModel: model)) {
        final effortStr =
            ReasoningEffortHelper.anthropicAdaptiveEffort(effort);
        if (effortStr != null) {
          body['thinking'] = {'type': 'adaptive'};
          body['output_config'] = {'effort': effortStr};
        }
      } else {
        final budget = ReasoningEffortHelper.anthropicBudget(effort);
        if (budget != null) {
          if (budget >= (body['max_tokens'] as int)) {
            body['max_tokens'] = budget + 8192;
          }
          body['thinking'] = {
            'type': 'enabled',
            'budget_tokens': budget,
          };
        }
      }
    }
    return body;
  }

  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'claude-sonnet-4-6',
    CancellationToken? token,
    ReasoningEffort? effort,
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    if (apiKey.isEmpty) return 'Error: No Anthropic API key configured.';

    final client = http.Client();
    token?.attach(client);
    try {
      final body = _buildRequestBody(
        messages,
        model: model,
        maxTokens: 16384,
        effort: effort,
      );
      final res = await client.post(
        Uri.parse('$baseUrl/v1/messages'),
        headers: _headers,
        body: jsonEncode(body),
      );

      if (token?.isCancelled == true) return '_(cancelled)_';
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final content = data['content'] as List<dynamic>? ?? [];
        return content
            .where((block) => block['type'] == 'text')
            .map((block) => block['text'] as String? ?? '')
            .join('');
      }
      return _formatError(res.statusCode, res.body);
    } catch (e) {
      if (token?.isCancelled == true) return '_(cancelled)_';
      return 'Error connecting to Anthropic: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  Stream<String> generateChatStream(
    List<Map<String, dynamic>> messages, {
    String model = 'claude-sonnet-4-6',
    CancellationToken? token,
    // Bumped from 3 → 6 minutes (2026-05). Extended-thinking on Opus
    // 4.7+ with high effort can legitimately go 3+ minutes between
    // SSE deltas while reasoning server-side — the old 3-min idle
    // window was killing long-form Claude turns mid-thought, and
    // the closed sink surfaced as a clean "stream ended" with no
    // visible signal to the user (the controller's auto-continue
    // gate doesn't fire when the partial content is non-empty,
    // which is the typical Opus-mid-reasoning shape). 6 minutes
    // covers Anthropic's documented worst-case adaptive thinking
    // duration with margin; genuine network stalls past this
    // bound are exceptionally rare and the user can Stop+retry.
    Duration idleTimeout = const Duration(minutes: 6),
    ReasoningEffort? effort,
    Set<String>? nativeToolIds,
  }) async* {
    if (token?.isCancelled == true) return;
    if (apiKey.isEmpty) {
      yield 'Error: No Anthropic API key configured.';
      return;
    }

    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      final body = _buildRequestBody(
        messages,
        model: model,
        maxTokens: 16384,
        effort: effort,
        nativeToolIds: nativeToolIds,
      )..['stream'] = true;

      final req = http.Request('POST', Uri.parse('$baseUrl/v1/messages'))
        ..headers.addAll(_headers)
        ..body = jsonEncode(body);
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final err = await res.stream.bytesToString();
        yield _formatError(res.statusCode, err);
        return;
      }

      final lineStream = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(
            idleTimeout,
            onTimeout: (sink) {
              timedOut = true;
              sink.close();
            },
          );

      // Per-content-block bookkeeping for native tool_use parsing.
      // Anthropic SSE emits content blocks one at a time, indexed
      // by `obj['index']`; tool_use blocks open with a
      // `content_block_start` carrying id+name, then stream
      // `input_json_delta` chunks of partial JSON, then
      // `content_block_stop` signals end. We buffer per-index and
      // emit a `NativeToolUseMarker` on close.
      final blockType = <int, String>{};
      final blockToolId = <int, String>{};
      final blockToolName = <int, String>{};
      final blockToolInput = <int, StringBuffer>{};

      await for (final line in lineStream) {
        if (token?.isCancelled == true) return;
        if (line.isEmpty || !line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') continue;

        try {
          final obj = jsonDecode(data) as Map<String, dynamic>;
          final type = obj['type'] as String? ?? '';
          if (type == 'content_block_start') {
            final idx = (obj['index'] as int?) ?? -1;
            final cb =
                obj['content_block'] as Map<String, dynamic>? ?? const {};
            final cbType = cb['type'] as String? ?? '';
            blockType[idx] = cbType;
            if (cbType == 'tool_use') {
              blockToolId[idx] = (cb['id'] as String?) ?? '';
              blockToolName[idx] = (cb['name'] as String?) ?? '';
              blockToolInput[idx] = StringBuffer();
            }
          } else if (type == 'content_block_stop') {
            final idx = (obj['index'] as int?) ?? -1;
            if (blockType[idx] == 'tool_use') {
              final id = blockToolId[idx] ?? '';
              final name = blockToolName[idx] ?? '';
              final raw = blockToolInput[idx]?.toString() ?? '';
              Map<String, dynamic> args;
              try {
                args = raw.isEmpty
                    ? <String, dynamic>{}
                    : (jsonDecode(raw) as Map).cast<String, dynamic>();
              } catch (e) {
                debugPrint(
                  'Anthropic tool_use arg parse failed: $e ($raw)',
                );
                args = <String, dynamic>{};
              }
              yield NativeToolUseMarker.build(
                id: id, name: name, arguments: args,
              );
            }
            blockType.remove(idx);
            blockToolId.remove(idx);
            blockToolName.remove(idx);
            blockToolInput.remove(idx);
          } else if (type == 'content_block_delta') {
            // With extended thinking enabled, the SSE stream emits
            // multiple delta types: `thinking_delta` (carries
            // `delta.thinking`, model's internal reasoning),
            // `text_delta` (carries `delta.text`, user-visible
            // response), and `input_json_delta` (carries
            // `delta.partial_json`, native tool_use args streamed
            // as JSON tokens). We forward `text_delta` directly
            // and accumulate `input_json_delta` for the
            // content_block_stop emission. Thinking deltas are
            // dropped — they're for the model's benefit, not the
            // chat panel. Anthropic guarantees thinking blocks
            // arrive before user-visible blocks.
            final delta = obj['delta'] as Map<String, dynamic>? ?? {};
            final deltaType = delta['type'] as String? ?? '';
            if (deltaType == 'text_delta' || deltaType.isEmpty) {
              final text = delta['text'] as String? ?? '';
              if (text.isNotEmpty) yield text;
            } else if (deltaType == 'input_json_delta') {
              final idx = (obj['index'] as int?) ?? -1;
              final partial = delta['partial_json'] as String? ?? '';
              blockToolInput[idx]?.write(partial);
            }
          } else if (type == 'message_delta') {
            // Final-message envelope. `delta.stop_reason` is one of
            // `end_turn`, `max_tokens`, `stop_sequence`, `tool_use`.
            // When `max_tokens` we hit Anthropic's hard cap mid-
            // response — the model has more to say. Surface a hidden
            // marker so the controller can auto-continue. The
            // marker is on its own line with comments around it so
            // markdown ignores it; the chat parser doesn't match
            // LUMEN_TRUNCATED (different matcher than LUMEN_TOOL /
            // LUMEN_ERR), only the controller's post-stream scan does.
            final delta = obj['delta'] as Map<String, dynamic>? ?? {};
            final stopReason = delta['stop_reason'] as String?;
            if (stopReason == 'max_tokens') {
              yield '\n<!-- LUMEN_TRUNCATED:length -->\n';
            }
          } else if (type == 'error') {
            final error = obj['error'] as Map<String, dynamic>? ?? {};
            final message = error['message'] as String? ?? 'Unknown error';
            yield 'Anthropic API error: $message';
            return;
          }
        } catch (e) {
          debugPrint('Anthropic stream parse error: $e');
        }
      }

      if (timedOut && token?.isCancelled != true) {
        yield '\n\n_(generation paused - no response from Anthropic for '
            '${idleTimeout.inMinutes} min. Network may be stalled - '
            'send a follow-up to continue.)_\n';
      }
    } catch (e) {
      if (token?.isCancelled == true) return;
      yield 'Error connecting to Anthropic: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  Future<List<String>> getModels() async {
    if (apiKey.isEmpty) return _defaultModels;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final items = (data['data'] ?? data['models']) as List<dynamic>?;
        final models = (items ?? const <dynamic>[])
            .map((m) {
              if (m is String) return m;
              if (m is Map<String, dynamic>) return m['id'] as String? ?? '';
              return '';
            })
            .where((id) => id.startsWith('claude-'))
            .toList();
        if (models.isNotEmpty) return models;
      }
    } catch (e) {
      debugPrint('Error fetching Anthropic models: $e');
    }
    return _defaultModels;
  }

  Future<bool> isReachable() async {
    if (apiKey.isEmpty) return false;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/v1/models'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<String> summarizeTitle(
    String firstMessage, {
    String model = 'claude-haiku-4-5',
  }) async {
    if (apiKey.isEmpty) return _fallbackTitle(firstMessage);
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl/v1/messages'),
            headers: _headers,
            body: jsonEncode({
              'model': model,
              'max_tokens': 30,
              'temperature': 0.2,
              'system':
                  'Reply with a 3-6 word title summarizing the user message. No quotes, no punctuation at the end, no preamble.',
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {'type': 'text', 'text': firstMessage},
                  ],
                },
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final content = data['content'] as List<dynamic>? ?? [];
        final raw = content
            .where((block) => block['type'] == 'text')
            .map((block) => block['text'] as String? ?? '')
            .join('')
            .replaceAll(RegExp(r'["`*\n]'), '')
            .trim();
        if (raw.isNotEmpty) return raw;
      }
    } catch (_) {}
    return _fallbackTitle(firstMessage);
  }

  static String _formatError(int statusCode, String body) {
    try {
      final err = jsonDecode(body) as Map<String, dynamic>;
      final error = err['error'] as Map<String, dynamic>?;
      final msg = error?['message'] as String? ?? body;
      return 'Anthropic API error ($statusCode): $msg';
    } catch (_) {
      return 'Anthropic API error ($statusCode): $body';
    }
  }

  static String _fallbackTitle(String firstMessage) {
    final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    return fallback.length > 40 ? '${fallback.substring(0, 40)}...' : fallback;
  }

  static const _defaultModels = [
    'claude-opus-4-7',
    'claude-sonnet-4-6',
    'claude-haiku-4-5',
  ];
}
