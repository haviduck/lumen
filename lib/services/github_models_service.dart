import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ollama_service.dart' show CancellationToken;
import 'reasoning_effort.dart';

/// Talks to GitHub Models inference API (https://models.github.ai).
///
/// This is **NOT** GitHub Copilot. GitHub Models is a separate, public
/// inference service GitHub provides via REST. It accepts a GitHub token
/// (fine-grained PAT with `models:read`, classic PAT, or GitHub App user
/// token) in the `Authorization: Bearer` header.
///
/// API shape is OpenAI-compatible:
///   POST /inference/chat/completions               (personal entitlement)
///   POST /orgs/{org}/inference/chat/completions    (org-attributed billing)
///   GET  /catalog/models
///
/// When [organization] is set, inference requests route through the
/// org-attributed endpoint so usage is billed to the org's GitHub Models
/// paid plan and unlocks models the org has entitled (e.g. gpt-5 on
/// Copilot Business). The personal endpoint only sees your free tier,
/// which is why paid models 403 there.
///
/// Streaming responses come as SSE `data: <json>\n\n` lines with OpenAI-style
/// `choices[0].delta.content` deltas, terminated by `data: [DONE]`.
class GitHubModelsService {
  String apiKey;
  String baseUrl;

  /// Optional organization login. When set, chat/completions and title
  /// summarization route through the org-attributed endpoint
  /// (`/orgs/<org>/inference/chat/completions`) so requests use the org's
  /// paid Copilot/Models entitlement (e.g. gpt-5 on Copilot Business),
  /// instead of the caller's personal free tier. Empty string == personal.
  String organization;

  GitHubModelsService({
    this.apiKey = '',
    this.baseUrl = 'https://models.github.ai',
    this.organization = '',
  });

  static const _apiVersion = '2026-03-10';

  /// URL path prefix for inference. Switches to org-attributed when
  /// [organization] is set (e.g. `/orgs/<org-login>/inference`).
  String get _inferencePath {
    final org = organization.trim();
    if (org.isEmpty) return '/inference/chat/completions';
    return '/orgs/${Uri.encodeComponent(org)}/inference/chat/completions';
  }

  Map<String, String> get _headers => {
        if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': _apiVersion,
        'Content-Type': 'application/json',
      };

  Map<String, dynamic> _buildRequestBody(
    List<Map<String, dynamic>> messages, {
    required String model,
    required int maxTokens,
    double temperature = 0.7,
    ReasoningEffort? effort,
  }) {
    // GitHub Models accepts only string `content` for now (per current docs).
    // We flatten any image attachments to a textual placeholder so a multimodal
    // turn doesn't silently drop signal — when GH adds image support, this
    // becomes the upgrade hook.
    final converted = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] as String;
      final content = m['content'] as String? ?? '';
      final images = (m['images'] as List<dynamic>? ?? const []).length;
      final extra = images > 0 ? '\n\n[+$images image(s) attached]' : '';
      converted.add({
        'role': role == 'assistant'
            ? 'assistant'
            : (role == 'system' ? 'system' : 'user'),
        'content': '$content$extra',
      });
    }

    final body = <String, dynamic>{
      'model': model,
      'messages': converted,
      'temperature': temperature,
      'max_tokens': maxTokens,
    };

    // **Reasoning effort** — gpt-5 family + o-series accept the
    // `reasoning_effort` field (low/medium/high). gpt-4o / gpt-4.1 /
    // similar legacy chat models reject it (400 unknown_parameter), so
    // we only attach when the helper says the model supports it.
    if (effort != null && effort != ReasoningEffort.off) {
      final supports = ReasoningEffortHelper.modelSupportsNative(
        provider: 'github',
        rawModel: model,
      );
      final value = ReasoningEffortHelper.openAiEffortValue(effort);
      if (supports && value != null) {
        body['reasoning_effort'] = value;
      }
    }
    return body;
  }

  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'openai/gpt-4o-mini',
    CancellationToken? token,
    ReasoningEffort? effort,
  }) async {
    if (token?.isCancelled == true) return '_(cancelled)_';
    if (apiKey.isEmpty) return 'Error: No GitHub Models token configured.';

    final client = http.Client();
    token?.attach(client);
    try {
      final body = _buildRequestBody(
        messages,
        model: model,
        maxTokens: 8192,
        effort: effort,
      );
      final res = await client.post(
        Uri.parse('$baseUrl$_inferencePath'),
        headers: _headers,
        body: jsonEncode(body),
      );
      if (token?.isCancelled == true) return '_(cancelled)_';
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>? ?? const [];
        if (choices.isEmpty) return '';
        final msg = choices.first['message'] as Map<String, dynamic>?;
        return (msg?['content'] as String?) ?? '';
      }
      return _formatError(res.statusCode, res.body, attemptedModel: model);
    } catch (e) {
      if (token?.isCancelled == true) return '_(cancelled)_';
      return 'Error connecting to GitHub Models: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  Stream<String> generateChatStream(
    List<Map<String, dynamic>> messages, {
    String model = 'openai/gpt-4o-mini',
    CancellationToken? token,
    Duration idleTimeout = const Duration(minutes: 3),
    ReasoningEffort? effort,
  }) async* {
    if (token?.isCancelled == true) return;
    if (apiKey.isEmpty) {
      yield 'Error: No GitHub Models token configured.';
      return;
    }

    final client = http.Client();
    token?.attach(client);
    bool timedOut = false;
    try {
      final body = _buildRequestBody(
        messages,
        model: model,
        maxTokens: 8192,
        effort: effort,
      )..['stream'] = true;
      final url = '$baseUrl$_inferencePath';
      // Verifies the exact wire-level model id and endpoint, since GitHub's
      // error responses sometimes echo a stripped model name and obscure
      // whether the request was actually correct on our side.
      debugPrint(
        '[GitHubModels] POST $url  body.model="${body['model']}"  '
        'org="$organization"',
      );
      final req =
          http.Request('POST', Uri.parse(url))
            ..headers.addAll(_headers)
            ..body = jsonEncode(body);
      final res = await client.send(req);
      if (res.statusCode != 200) {
        final err = await res.stream.bytesToString();
        debugPrint(
          '[GitHubModels] non-200 response (${res.statusCode}): $err',
        );
        yield _formatError(res.statusCode, err, attemptedModel: model);
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

      await for (final line in lineStream) {
        if (token?.isCancelled == true) return;
        if (line.isEmpty || !line.startsWith('data: ')) continue;
        final data = line.substring(6).trim();
        if (data.isEmpty || data == '[DONE]') {
          if (data == '[DONE]') return;
          continue;
        }
        try {
          final obj = jsonDecode(data) as Map<String, dynamic>;
          final choices = obj['choices'] as List<dynamic>? ?? const [];
          if (choices.isEmpty) continue;
          final delta =
              choices.first['delta'] as Map<String, dynamic>? ?? const {};
          final text = delta['content'] as String? ?? '';
          if (text.isNotEmpty) yield text;
        } catch (e) {
          debugPrint('GitHub Models stream parse error: $e');
        }
      }

      if (timedOut && token?.isCancelled != true) {
        yield '\n\n_(generation paused - no response from GitHub Models for '
            '${idleTimeout.inMinutes} min. Send a follow-up to continue.)_\n';
      }
    } catch (e) {
      if (token?.isCancelled == true) return;
      yield 'Error connecting to GitHub Models: $e';
    } finally {
      try {
        client.close();
      } catch (_) {}
    }
  }

  /// Set of model IDs known to return `400 unavailable_model` on inference
  /// for the current token+org. Populated dynamically as inference fails.
  ///
  /// Why this exists: GitHub's `/catalog/models` is the marketing catalog,
  /// not a list of what's actually deployed to inference. New flagship
  /// models (gpt-5 family etc.) appear in the catalog before they're
  /// wired into the inference backend, sometimes by months. There is no
  /// REST endpoint that tells you which catalog entries are *actually*
  /// callable for your org — you can only discover by trying. This set
  /// records discoveries so we can prune the picker.
  ///
  /// AppState persists this across restarts via prefs so users don't
  /// rediscover the same dead models every session.
  final Set<String> unavailableModels = <String>{};

  /// Optional callback fired when a new model is observed to be
  /// `unavailable_model`. AppState wires this to persist the set.
  void Function(String modelId)? onUnavailableModelDiscovered;

  /// Returns model IDs from the marketing catalog
  /// (`/catalog/models`), with any [unavailableModels] pruned.
  /// Each id is in the form `<publisher>/<model>` (e.g. `openai/gpt-4o`).
  /// The chat picker prefixes these with `github:` for routing.
  Future<List<String>> getModels() async {
    if (apiKey.isEmpty) return _defaultModels;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/catalog/models'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final dynamic raw = jsonDecode(res.body);
        final items = raw is List<dynamic>
            ? raw
            : (raw is Map<String, dynamic>
                  ? (raw['data'] ?? raw['models']) as List<dynamic>?
                  : null);
        if (items == null) return _defaultModels;
        final ids = <String>[];
        for (final m in items) {
          if (m is Map<String, dynamic>) {
            final id = m['id'] as String?;
            if (id != null &&
                id.isNotEmpty &&
                !unavailableModels.contains(id)) {
              ids.add(id);
            }
          } else if (m is String &&
              m.isNotEmpty &&
              !unavailableModels.contains(m)) {
            ids.add(m);
          }
        }
        if (ids.isEmpty) return _defaultModels;
        ids.sort();
        return ids;
      }
    } catch (e) {
      debugPrint('[GitHubModels] error fetching catalog: $e');
    }
    return _defaultModels;
  }

  /// Lightweight readiness probe — succeeds when the catalog endpoint
  /// answers 200 with the configured token. Used by the Settings "Test
  /// connection" button and provider routing guards.
  Future<bool> isReachable() async {
    if (apiKey.isEmpty) return false;
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/catalog/models'), headers: _headers)
          .timeout(const Duration(seconds: 6));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Detailed connection test for the Settings panel: returns
  /// (ok, message, modelCount). On failure, [message] is the human-readable
  /// reason ("401 Unauthorized: bad token", "missing models:read", etc).
  Future<({bool ok, String message, int modelCount})> testConnection() async {
    if (apiKey.isEmpty) {
      return (ok: false, message: 'No token configured.', modelCount: 0);
    }
    try {
      final res = await http
          .get(Uri.parse('$baseUrl/catalog/models'), headers: _headers)
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final dynamic raw = jsonDecode(res.body);
        final list = raw is List<dynamic>
            ? raw
            : (raw is Map<String, dynamic>
                  ? (raw['data'] ?? raw['models']) as List<dynamic>?
                  : null);
        final catalogCount = list?.length ?? 0;
        final pruned = unavailableModels.length;
        final pruneNote = pruned > 0
            ? ' ($pruned hidden as known-unavailable)'
            : '';
        return (
          ok: true,
          message:
              'Connected. $catalogCount models in catalog$pruneNote. '
              'Save to apply.',
          modelCount: catalogCount,
        );
      }
      if (res.statusCode == 401) {
        return (
          ok: false,
          message: 'Unauthorized. Check that the token has Models: read.',
          modelCount: 0,
        );
      }
      if (res.statusCode == 403) {
        return (
          ok: false,
          message: organization.isEmpty
              ? 'Forbidden. The token may lack Models access, or paid models '
                    'require billing your org — set Organization below.'
              : 'Forbidden. Check that "$organization" has GitHub Models '
                    'enabled and your token can attribute to it.',
          modelCount: 0,
        );
      }
      return (
        ok: false,
        message: 'GitHub Models error ${res.statusCode}: ${res.body}',
        modelCount: 0,
      );
    } catch (e) {
      return (ok: false, message: 'Connection failed: $e', modelCount: 0);
    }
  }

  Future<String> summarizeTitle(
    String firstMessage, {
    String model = 'openai/gpt-4o-mini',
  }) async {
    if (apiKey.isEmpty) return _fallbackTitle(firstMessage);
    try {
      final res = await http
          .post(
            Uri.parse('$baseUrl$_inferencePath'),
            headers: _headers,
            body: jsonEncode({
              'model': model,
              'temperature': 0.2,
              'max_tokens': 30,
              'messages': [
                {
                  'role': 'system',
                  'content':
                      'Reply with a 3-6 word title summarizing the user message. '
                      'No quotes, no punctuation at the end, no preamble.',
                },
                {'role': 'user', 'content': firstMessage},
              ],
            }),
          )
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final choices = data['choices'] as List<dynamic>? ?? const [];
        if (choices.isNotEmpty) {
          final msg = choices.first['message'] as Map<String, dynamic>?;
          final raw = (msg?['content'] as String? ?? '')
              .replaceAll(RegExp(r'["`*\n]'), '')
              .trim();
          if (raw.isNotEmpty) return raw;
        }
      }
    } catch (_) {}
    return _fallbackTitle(firstMessage);
  }

  String _formatError(int statusCode, String body, {String? attemptedModel}) {
    String msg;
    String? code;
    try {
      final err = jsonDecode(body) as Map<String, dynamic>;
      final inner = err['error'] is Map<String, dynamic>
          ? err['error'] as Map<String, dynamic>
          : null;
      msg =
          err['message'] as String? ??
          inner?['message'] as String? ??
          body;
      code = err['code'] as String? ?? inner?['code'] as String?;
    } catch (_) {
      msg = body;
    }
    final base = 'GitHub Models error ($statusCode): $msg';

    // 400 unavailable_model: the catalog lists the model but GitHub hasn't
    // wired it into the inference dispatcher for this caller. There is no
    // GET endpoint that exposes which catalog entries are actually
    // serveable, so we discover by trying. Record the failure so it gets
    // pruned from the model picker on next reload.
    final isUnavailable =
        statusCode == 400 &&
        (code == 'unavailable_model' ||
            msg.toLowerCase().contains('unavailable model'));
    if (isUnavailable && attemptedModel != null && attemptedModel.isNotEmpty) {
      if (unavailableModels.add(attemptedModel)) {
        onUnavailableModelDiscovered?.call(attemptedModel);
      }
      return '$base\n'
          'GitHub advertises "$attemptedModel" in its catalog but hasn\'t '
          'rolled it out to inference yet. Removing it from your model '
          'picker now. Try a flagship that\'s already deployed '
          '(e.g. openai/gpt-4o, openai/gpt-4.1).';
    }

    // 403 No access on the personal endpoint when org isn't set: usually
    // means the model is paid-tier and the personal token doesn't cover it.
    if (statusCode == 403 &&
        organization.isEmpty &&
        msg.toLowerCase().contains('no access to model')) {
      return '$base\n'
          'Hint: this model is likely paid-tier. Set your GitHub org in '
          'Settings → GitHub Models → Organization to bill the org plan.';
    }
    return base;
  }

  static String _fallbackTitle(String firstMessage) {
    final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    return fallback.length > 40 ? '${fallback.substring(0, 40)}...' : fallback;
  }

  static const _defaultModels = <String>[
    'openai/gpt-4o',
    'openai/gpt-4o-mini',
    'openai/gpt-4.1',
  ];
}
