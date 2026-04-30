import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Talks to Ollama. Supports cancellation via `CancellationToken` so the
/// "Stop Generation" button can interrupt in-flight requests.
class CancellationToken {
  bool _cancelled = false;
  http.Client? _client;

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
    _cancelled = true;
    try {
      _client?.close();
    } catch (_) {}
  }
}

class OllamaService {
  String baseUrl;

  OllamaService({this.baseUrl = 'http://localhost:11434'});

  /// Non-streaming chat. Honours [token] cancellation by closing the client.
  /// Messages may carry `images` (base64) for multimodal models.
  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'llama3',
    CancellationToken? token,
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    final client = http.Client();
    token?.attach(client);
    try {
      final body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': false,
      });

      final res = await client.post(
        Uri.parse('$baseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (token?.isCancelled == true) return '_(cancelled)_';

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
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
  Stream<String> streamChat(
    List<Map<String, dynamic>> messages, {
    String model = 'llama3',
    CancellationToken? token,
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
      request.body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
      });

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
  }) async* {
    if (token?.isCancelled == true) return;
    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      final body = jsonEncode({
        'model': model,
        'messages': messages,
        'stream': true,
      });
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
          if (obj['done'] == true) return;
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

  /// Helper for naming chat sessions: ask the model to summarize the
  /// first user message in 4-6 words. Uses a small temperature & cap to
  /// keep responses short.
  Future<String> summarizeTitle(String firstMessage, {String model = 'llama3'}) async {
    try {
      final res = await http.post(
        Uri.parse('$baseUrl/api/chat'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'model': model,
          'stream': false,
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
}
