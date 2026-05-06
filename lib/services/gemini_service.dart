import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ollama_service.dart' show CancellationToken;
import 'reasoning_effort.dart';
import 'tools/native_tool_format.dart';

/// Detect image MIME type from base64 data by inspecting magic bytes.
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

/// Talks to the Google Gemini REST API.
/// Supports the same `CancellationToken` pattern as `OllamaService`.
class GeminiService {
  String apiKey;
  String baseUrl;

  GeminiService({
    this.apiKey = '',
    this.baseUrl = 'https://generativelanguage.googleapis.com',
  });

  /// Apply a [ReasoningEffort] to a Gemini request body in place.
  /// No-op when [effort] is null/off OR when the model isn't on the
  /// 2.5 family (older Gemini doesn't accept `thinkingConfig` and
  /// will 400 if we send it).
  void _applyReasoningEffort(
    Map<String, dynamic> body,
    ReasoningEffort? effort,
    String model,
  ) {
    if (effort == null) return;
    if (!ReasoningEffortHelper.modelSupportsNative(
      provider: 'gemini',
      rawModel: model,
    )) {
      return;
    }
    final budget = ReasoningEffortHelper.geminiBudget(effort, rawModel: model);
    if (budget == null) return;
    final genConfig = (body['generationConfig'] as Map<String, dynamic>?) ??
        <String, dynamic>{};
    genConfig['thinkingConfig'] = {'thinkingBudget': budget};
    body['generationConfig'] = genConfig;
  }

  /// Build the Gemini request body from Ollama-style message list.
  /// Returns (body, systemInstruction) — shared by both streaming and
  /// non-streaming paths.
  (Map<String, dynamic>, String?) _buildRequestBody(
    List<Map<String, dynamic>> messages,
  ) {
    String? systemInstruction;
    final contents = <Map<String, dynamic>>[];

    for (final m in messages) {
      final role = m['role'] as String;
      if (role == 'system') {
        systemInstruction = m['content'] as String;
        continue;
      }

      final parts = <Map<String, dynamic>>[];

      // Text content
      final content = m['content'] as String? ?? '';
      if (content.isNotEmpty) {
        parts.add({'text': content});
      }

      // Image attachments (base64)
      final images = m['images'] as List<dynamic>? ?? [];
      for (final img in images) {
        parts.add({
          'inline_data': {
            'mime_type': _detectMediaType(img as String),
            'data': img as String,
          },
        });
      }

      contents.add({
        'role': role == 'assistant' ? 'model' : 'user',
        'parts': parts,
      });
    }

    // Gemini requires alternating user/model turns. Merge consecutive
    // same-role entries (common when tool feedback inserts multiple
    // user turns back-to-back).
    final merged = <Map<String, dynamic>>[];
    for (final c in contents) {
      if (merged.isNotEmpty && merged.last['role'] == c['role']) {
        (merged.last['parts'] as List).addAll(c['parts'] as List);
      } else {
        merged.add({
          'role': c['role'],
          'parts': List<Map<String, dynamic>>.from(c['parts'] as List),
        });
      }
    }

    // Gemini requires the first message to be from the user.
    if (merged.isNotEmpty && merged.first['role'] != 'user') {
      merged.insert(0, {
        'role': 'user',
        'parts': [{'text': '(start)'}],
      });
    }

    final body = <String, dynamic>{
      'contents': merged,
      'generationConfig': {
        'temperature': 0.7,
        'maxOutputTokens': 16384,
      },
    };

    if (systemInstruction != null) {
      body['system_instruction'] = {
        'parts': [{'text': systemInstruction}],
      };
    }

    return (body, systemInstruction);
  }

  /// Chat completion. Converts the Ollama-style message list into
  /// Gemini's `contents` format and returns the full response.
  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'gemini-2.5-flash',
    CancellationToken? token,
    ReasoningEffort? effort,
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    if (apiKey.isEmpty) return 'Error: No Gemini API key configured.';

    final client = http.Client();
    token?.attach(client);

    try {
      final (body, _) = _buildRequestBody(messages);
      _applyReasoningEffort(body, effort, model);
      final url = '$baseUrl/v1beta/models/$model:generateContent?key=$apiKey';

      final res = await client.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(body),
      );

      if (token?.isCancelled == true) return '_(cancelled)_';

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final candidates = data['candidates'] as List<dynamic>?;
        if (candidates != null && candidates.isNotEmpty) {
          final parts =
              candidates[0]['content']?['parts'] as List<dynamic>? ?? [];
          final textParts = parts
              .where((p) => p['text'] != null)
              .map((p) => p['text'] as String)
              .toList();
          return textParts.join('');
        }
        // Check for safety block
        final feedback = data['promptFeedback'];
        if (feedback != null) {
          final reason = feedback['blockReason'] ?? 'Unknown';
          return 'Blocked by Gemini safety filter: $reason';
        }
        return '';
      }

      // Parse error message from response
      try {
        final err = jsonDecode(res.body);
        final msg = err['error']?['message'] ?? res.body;
        return 'Gemini API error (${res.statusCode}): $msg';
      } catch (_) {
        return 'Gemini API error (${res.statusCode}): ${res.body}';
      }
    } catch (e) {
      if (token?.isCancelled == true) return '_(cancelled)_';
      return 'Error connecting to Gemini: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Streaming chat. Uses the `streamGenerateContent` endpoint and yields
  /// individual text chunks as they arrive.
  Stream<String> streamChat(
    List<Map<String, dynamic>> messages, {
    String model = 'gemini-2.5-flash',
    CancellationToken? token,
  }) async* {
    if (token?.isCancelled == true) return;
    if (apiKey.isEmpty) {
      yield 'Error: No Gemini API key configured.';
      return;
    }

    final client = http.Client();
    token?.attach(client);

    try {
      final (body, _) = _buildRequestBody(messages);
      final url =
          '$baseUrl/v1beta/models/$model:streamGenerateContent?alt=sse&key=$apiKey';

      final request = http.Request('POST', Uri.parse(url));
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);

      final response = await client.send(request);

      if (response.statusCode != 200) {
        final errorBody = await response.stream.bytesToString();
        try {
          final err = jsonDecode(errorBody);
          final msg = err['error']?['message'] ?? errorBody;
          yield 'Gemini API error (${response.statusCode}): $msg';
        } catch (_) {
          yield 'Gemini API error (${response.statusCode}): $errorBody';
        }
        return;
      }

      // Gemini SSE: each event is `data: {json}\n\n`.
      // We accumulate partial lines and parse complete JSON objects.
      final lineStream = response.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in lineStream) {
        if (token?.isCancelled == true) break;
        if (line.trim().isEmpty) continue;

        // Strip the `data: ` SSE prefix.
        String jsonStr = line;
        if (line.startsWith('data: ')) {
          jsonStr = line.substring(6);
        } else if (!line.startsWith('{')) {
          // Skip non-data lines (e.g. event type markers).
          continue;
        }

        try {
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          final candidates = data['candidates'] as List<dynamic>? ?? [];
          for (final candidate in candidates) {
            final parts =
                candidate['content']?['parts'] as List<dynamic>? ?? [];
            for (final part in parts) {
              final text = part['text'] as String? ?? '';
              if (text.isNotEmpty) {
                yield text;
              }
            }
          }
        } catch (e) {
          debugPrint('Gemini stream parse error: $e');
        }
      }
    } catch (e) {
      if (token?.isCancelled != true) {
        yield 'Error connecting to Gemini: $e';
      }
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Streaming variant of [generateChat]. Hits Gemini's
  /// `:streamGenerateContent?alt=sse` endpoint and yields incremental
  /// text chunks as they arrive. Same payload-conversion logic as
  /// `generateChat` (system_instruction split, alternating-role merge,
  /// leading-user injection).
  ///
  /// SSE format: `data: <json>\n\n` per chunk. Gemini also emits an
  /// occasional empty heartbeat line we skip.
  Stream<String> generateChatStream(
    List<Map<String, dynamic>> messages, {
    String model = 'gemini-2.5-flash',
    CancellationToken? token,
    // Same idle-timeout treatment as Ollama — Gemini is normally
    // very fast but the network can stall, especially over flaky
    // connections, and we don't want the chat panel to lock up
    // forever waiting on a connection that's already dead.
    Duration idleTimeout = const Duration(minutes: 3),
    ReasoningEffort? effort,
    Set<String>? nativeToolIds,
  }) async* {
    if (token?.isCancelled == true) return;
    if (apiKey.isEmpty) {
      yield 'Error: No Gemini API key configured.';
      return;
    }
    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      // Same body construction as `generateChat` — keep them in sync
      // when one changes, change both.
      String? systemInstruction;
      final contents = <Map<String, dynamic>>[];
      for (final m in messages) {
        final role = m['role'] as String;
        if (role == 'system') {
          systemInstruction = m['content'] as String;
          continue;
        }

        // Native tool-result reply. Gemini encodes this as a `user`
        // turn with a `function_response` part referencing the
        // tool name (Gemini doesn't carry tool_use_id; the name +
        // history order is the linkage).
        if (role == 'tool') {
          contents.add({
            'role': 'user',
            'parts': [
              {
                'function_response': {
                  // We don't have a separate tool name on the wire
                  // here, so reuse `tool_use_id` which the
                  // controller stamps with the tool id — matches
                  // what Gemini wants.
                  'name': (m['tool_use_id'] as String?) ?? '',
                  'response': {
                    'content': (m['content'] as String?) ?? '',
                  },
                },
              },
            ],
          });
          continue;
        }

        final parts = <Map<String, dynamic>>[];
        final content = m['content'] as String? ?? '';
        if (content.isNotEmpty) parts.add({'text': content});

        // Native tool_use carried on an assistant turn. Gemini's
        // `function_call` part lives alongside the prose part(s).
        final toolUse = m['tool_use'];
        if (role == 'assistant' && toolUse is Map<String, dynamic>) {
          final args =
              (toolUse['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
          parts.add({
            'function_call': {
              'name': (toolUse['name'] as String?) ?? '',
              'args': args,
            },
          });
        }

        final images = m['images'] as List<dynamic>? ?? [];
        for (final img in images) {
          parts.add({
            'inline_data': {
              'mime_type': _detectMediaType(img as String),
              'data': img as String,
            },
          });
        }
        contents.add({
          'role': role == 'assistant' ? 'model' : 'user',
          'parts': parts,
        });
      }
      final merged = <Map<String, dynamic>>[];
      for (final c in contents) {
        if (merged.isNotEmpty && merged.last['role'] == c['role']) {
          (merged.last['parts'] as List).addAll(c['parts'] as List);
        } else {
          merged.add({
            'role': c['role'],
            'parts': List<Map<String, dynamic>>.from(c['parts'] as List),
          });
        }
      }
      if (merged.isNotEmpty && merged.first['role'] != 'user') {
        merged.insert(0, {
          'role': 'user',
          'parts': [{'text': '(start)'}],
        });
      }
      final body = <String, dynamic>{
        'contents': merged,
        'generationConfig': {
          'temperature': 0.7,
          'maxOutputTokens': 16384,
        },
      };
      if (systemInstruction != null) {
        body['system_instruction'] = {
          'parts': [{'text': systemInstruction}],
        };
      }
      _applyReasoningEffort(body, effort, model);

      if (nativeToolIds != null && nativeToolIds.isNotEmpty) {
        body['tools'] = [NativeToolDefinitions.forGemini(nativeToolIds)];
        // Gemini's tool_config: `mode: AUTO` lets the model pick
        // when to call. `ANY` would force a tool every turn — bad
        // for agentic loops where the model needs to be free to
        // produce a final summary.
        body['tool_config'] = {
          'function_calling_config': {'mode': 'AUTO'},
        };
      }

      final url =
          '$baseUrl/v1beta/models/$model:streamGenerateContent?alt=sse&key=$apiKey';
      final req = http.Request('POST', Uri.parse(url))
        ..headers['Content-Type'] = 'application/json'
        ..body = jsonEncode(body);
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final err = await res.stream.bytesToString();
        yield 'Gemini API error (${res.statusCode}): $err';
        return;
      }
      // **Idle timeout** — see ollama_service.dart::generateChatStream
      // for the rationale. `Stream.timeout(onTimeout: sink.close())`
      // ends the await-for cleanly so the chat controller still runs
      // its executor on whatever partial chunks accumulated.
      final lineStream = res.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(idleTimeout, onTimeout: (sink) {
        timedOut = true;
        sink.close();
      });
      await for (final line in lineStream) {
        if (token?.isCancelled == true) return;
        if (line.isEmpty || !line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') continue;
        try {
          final obj = jsonDecode(data) as Map<String, dynamic>;
          final candidates = obj['candidates'] as List<dynamic>?;
          if (candidates == null || candidates.isEmpty) continue;
          final candidate = candidates[0] as Map<String, dynamic>;
          final parts = candidate['content']?['parts'] as List<dynamic>? ?? [];
          for (final p in parts) {
            final t = p['text'] as String?;
            if (t != null && t.isNotEmpty) yield t;
            // Native tool_use — Gemini emits `function_call` parts
            // inline alongside text. Surface as a NativeToolUseMarker
            // so the controller dispatches through the executor.
            // Gemini doesn't carry a stable tool_use_id; we synthesize
            // one from the call name + index for the tool_result
            // round-trip linkage. (Gemini's API matches by call name
            // + history order, so any unique id works as long as we
            // round-trip it ourselves consistently.)
            final fc = p['function_call'];
            if (fc is Map) {
              final name = (fc['name'] as String?) ?? '';
              final rawArgs = fc['args'];
              final args = rawArgs is Map
                  ? rawArgs.cast<String, dynamic>()
                  : <String, dynamic>{};
              if (name.isNotEmpty) {
                final id =
                    'gemini-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
                yield NativeToolUseMarker.build(
                  id: id, name: name, arguments: args,
                );
              }
            }
          }
          // Truncation marker — `finishReason: MAX_TOKENS` means the
          // model hit `maxOutputTokens` (we send 16384) before its
          // natural stop. Surface a hidden marker so the controller
          // can auto-continue. Hidden in markdown; chat parser only
          // matches LUMEN_TOOL / LUMEN_ERR.
          final finishReason = candidate['finishReason'] as String?;
          if (finishReason == 'MAX_TOKENS') {
            yield '\n<!-- LUMEN_TRUNCATED:length -->\n';
          }
          // Stop on safety block.
          final feedback = obj['promptFeedback'];
          if (feedback != null && feedback['blockReason'] != null) {
            yield '\n\n[Blocked by Gemini safety filter: '
                '${feedback['blockReason']}]';
            return;
          }
        } catch (_) {
          // Skip malformed chunk.
        }
      }
      if (timedOut && token?.isCancelled != true) {
        yield '\n\n_(generation paused — no response from Gemini for '
            '${idleTimeout.inMinutes} min. Network may be stalled — '
            'send a follow-up to continue.)_\n';
      }
    } catch (e) {
      if (token?.isCancelled == true) return;
      yield 'Error connecting to Gemini: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Fetch available Gemini models from the API.
  Future<List<String>> getModels() async {
    if (apiKey.isEmpty) return _defaultModels;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/v1beta/models?key=$apiKey'))
          .timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final models = (data['models'] as List<dynamic>)
            .where((m) {
              final methods = m['supportedGenerationMethods'] as List? ?? [];
              return methods.contains('generateContent');
            })
            .map((m) => (m['name'] as String).replaceFirst('models/', ''))
            .where((name) =>
                name.startsWith('gemini-') && !name.contains('embedding'))
            .toList();
        if (models.isNotEmpty) {
          // Sort so the most capable models come first
          models.sort((a, b) {
            // Pro before flash, higher version first
            final aScore = _modelSortScore(a);
            final bScore = _modelSortScore(b);
            return bScore.compareTo(aScore);
          });
          return models;
        }
      }
    } catch (e) {
      debugPrint('Error fetching Gemini models: $e');
    }
    return _defaultModels;
  }

  static int _modelSortScore(String name) {
    int score = 0;
    if (name.contains('pro')) score += 100;
    if (name.contains('flash')) score += 50;
    if (name.contains('ultra')) score += 200;
    if (name.contains('2.5')) score += 20;
    if (name.contains('2.0')) score += 10;
    if (name.contains('thinking')) score -= 5;
    return score;
  }

  static const _defaultModels = [
    'gemini-2.5-pro',
    'gemini-2.5-flash',
    'gemini-2.0-flash',
  ];

  /// Lightweight reachability check.
  Future<bool> isReachable() async {
    if (apiKey.isEmpty) return false;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/v1beta/models?key=$apiKey'))
          .timeout(const Duration(seconds: 5));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Summarize a chat title using Gemini.
  Future<String> summarizeTitle(
    String firstMessage, {
    String model = 'gemini-2.5-flash',
  }) async {
    if (apiKey.isEmpty) {
      final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
      return fallback.length > 40 ? '${fallback.substring(0, 40)}…' : fallback;
    }
    try {
      final url = '$baseUrl/v1beta/models/$model:generateContent?key=$apiKey';
      final res = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'system_instruction': {
                'parts': [
                  {
                    'text':
                        'Reply with a 3-6 word title summarizing the user message. No quotes, no punctuation at the end, no preamble.',
                  }
                ],
              },
              'contents': [
                {
                  'role': 'user',
                  'parts': [{'text': firstMessage}],
                },
              ],
              'generationConfig': {
                'temperature': 0.2,
                'maxOutputTokens': 30,
              },
            }),
          )
          .timeout(const Duration(seconds: 10));

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final candidates = data['candidates'] as List? ?? [];
        if (candidates.isNotEmpty) {
          final parts =
              candidates[0]['content']?['parts'] as List<dynamic>? ?? [];
          final raw = parts
              .where((p) => p['text'] != null)
              .map((p) => p['text'] as String)
              .join('')
              .replaceAll(RegExp(r'["`*\n]'), '')
              .trim();
          if (raw.isNotEmpty) return raw;
        }
      }
    } catch (_) {}
    final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    return fallback.length > 40 ? '${fallback.substring(0, 40)}…' : fallback;
  }
}
