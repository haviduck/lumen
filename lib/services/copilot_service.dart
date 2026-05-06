import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import 'copilot_provisioner.dart';
import 'ollama_service.dart' show CancellationToken, OllamaService;
import 'reasoning_effort.dart';
import 'tools/native_tool_format.dart';

/// Talks to GitHub Copilot through the official `@github/copilot-sdk`.
///
/// The SDK is Node-only, so this service owns a local bridge process and
/// exchanges line-delimited JSON over stdio. The bridge is intentionally
/// local-only: no open TCP port, no plaintext remote server.
class CopilotService {
  String apiKey;
  bool useLoggedInUser;

  CopilotService({this.apiKey = '', this.useLoggedInUser = true});

  final Set<String> unavailableModels = <String>{};
  void Function(String modelId)? onUnavailableModelDiscovered;

  Process? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  int _requestSeq = 0;

  final Map<String, Completer<Map<String, dynamic>>> _pending =
      <String, Completer<Map<String, dynamic>>>{};
  final Map<String, StreamController<Map<String, dynamic>>> _streams =
      <String, StreamController<Map<String, dynamic>>>{};

  bool get _hasAuth => apiKey.trim().isNotEmpty || useLoggedInUser;

  Map<String, dynamic> get _auth => <String, dynamic>{
    if (apiKey.trim().isNotEmpty) ...{
      'gitHubToken': apiKey.trim(),
      'githubToken': apiKey.trim(),
    },
    'useLoggedInUser': useLoggedInUser,
  };

  Future<List<String>> getModels() async {
    if (!_hasAuth) return const <String>[];
    try {
      final res = await _request(
        'list_models',
      ).timeout(const Duration(seconds: 45));
      final raw = res['models'] as List<dynamic>? ?? const [];
      final ids = <String>[];
      for (final item in raw) {
        final id = item is Map<String, dynamic>
            ? item['id'] as String?
            : item.toString();
        if (id != null && id.isNotEmpty && !unavailableModels.contains(id)) {
          ids.add(id);
        }
      }
      ids.sort();
      return ids;
    } catch (e) {
      debugPrint('[Copilot] model fetch failed: $e');
      rethrow;
    }
  }

  Future<String> generateChat(
    List<Map<String, dynamic>> messages, {
    String model = 'gpt-5',
    CancellationToken? token,
    ReasoningEffort? effort,
  }) async {
    final out = StringBuffer();
    await for (final chunk in generateChatStream(
      messages,
      model: model,
      token: token,
      effort: effort,
    )) {
      out.write(chunk);
    }
    return out.toString();
  }

  Stream<String> generateChatStream(
    List<Map<String, dynamic>> messages, {
    String model = 'gpt-5',
    CancellationToken? token,
    ReasoningEffort? effort,
    Set<String>? nativeToolIds,
  }) async* {
    if (token?.isCancelled == true) return;
    if (!_hasAuth) {
      yield S.copilotNoAuth;
      return;
    }

    final requestId = _nextRequestId();
    final controller = StreamController<Map<String, dynamic>>();
    _streams[requestId] = controller;
    var thinkingOpen = false;

    try {
      await _ensureProcess();
      _write({
        'type': 'chat_start',
        'requestId': requestId,
        'auth': _auth,
        'model': model,
        'messages': messages,
        'effort': _copilotEffort(effort),
        'tools': _toolsForBridge(nativeToolIds),
      });
      if (token != null) {
        unawaited(token.whenCancelled.then((_) => _cancel(requestId)));
      }

      await for (final event in controller.stream.timeout(
        const Duration(minutes: 6),
        onTimeout: (sink) {
          sink.add({'type': 'error', 'error': S.copilotNoResponse});
          sink.close();
        },
      )) {
        if (token?.isCancelled == true) {
          await _cancel(requestId);
          return;
        }
        final type = event['type'] as String? ?? '';
        if (type == 'delta') {
          if (thinkingOpen) {
            thinkingOpen = false;
            yield OllamaService.thinkEndMarker;
          }
          final text = event['text'] as String? ?? '';
          if (text.isNotEmpty) yield text;
        } else if (type == 'thinking_delta') {
          if (!thinkingOpen) {
            thinkingOpen = true;
            yield OllamaService.thinkStartMarker;
          }
          final text = event['text'] as String? ?? '';
          if (text.isNotEmpty) yield text;
        } else if (type == 'tool_call') {
          if (thinkingOpen) {
            thinkingOpen = false;
            yield OllamaService.thinkEndMarker;
          }
          final name = event['name'] as String? ?? '';
          final id = event['id'] as String? ?? '';
          final args =
              (event['arguments'] as Map?)?.cast<String, dynamic>() ?? {};
          if (name.isNotEmpty) {
            yield NativeToolUseMarker.build(
              id: id,
              name: name,
              arguments: args,
            );
          }
          await _cancel(requestId);
          return;
        } else if (type == 'done' || type == 'cancelled') {
          break;
        } else if (type == 'error') {
          if (thinkingOpen) {
            thinkingOpen = false;
            yield OllamaService.thinkEndMarker;
          }
          final message = event['error'] as String? ?? 'Unknown Copilot error.';
          yield _formatError(message, attemptedModel: model);
          return;
        }
      }
    } catch (e) {
      if (token?.isCancelled == true) return;
      yield _formatError('$e', attemptedModel: model);
    } finally {
      if (thinkingOpen) yield OllamaService.thinkEndMarker;
      _streams.remove(requestId);
      await controller.close();
    }
  }

  Future<bool> isReachable() async {
    if (!_hasAuth) return false;
    try {
      final models = await getModels().timeout(const Duration(seconds: 45));
      return models.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<({bool ok, String message, int modelCount})> testConnection() async {
    if (!_hasAuth) {
      return (ok: false, message: S.copilotNoAuthSettings, modelCount: 0);
    }
    final bridgePath = await CopilotProvisioner.ensure();
    if (bridgePath == null) {
      return (
        ok: false,
        message:
            '${S.copilotBridgeNotReady} ${CopilotProvisioner.lastFailure ?? ''}',
        modelCount: 0,
      );
    }
    try {
      final models = await getModels().timeout(const Duration(seconds: 60));
      if (models.isEmpty) {
        return (
          ok: false,
          message: 'Connected to Copilot, but no models were returned.',
          modelCount: 0,
        );
      }
      return (
        ok: true,
        message:
            '${S.copilotConnectedPrefix} ${models.length} ${S.copilotConnectedSuffix}',
        modelCount: models.length,
      );
    } catch (e) {
      return (
        ok: false,
        message: '${S.copilotConnectionFailed}: $e',
        modelCount: 0,
      );
    }
  }

  Future<({bool ok, String message})> openLoginTerminal() async {
    final cliPath = await CopilotProvisioner.ensureCliPath();
    final root = await CopilotProvisioner.ensureRoot();
    if (cliPath == null || root == null) {
      return (
        ok: false,
        message:
            '${S.copilotBridgeNotReady} ${CopilotProvisioner.lastFailure ?? ''}',
      );
    }

    try {
      if (Platform.isWindows) {
        final command = [
          r"$Host.UI.RawUI.WindowTitle = 'Lumen GitHub Copilot Login'",
          "Set-Location -LiteralPath ${_psQuote(root)}",
          "Write-Host ${_psQuote(S.copilotLoginTerminalIntro)}",
          "Write-Host ${_psQuote(S.copilotLoginTerminalCommand)}",
          "& ${_psQuote(cliPath)}",
          "Write-Host ${_psQuote(S.copilotLoginTerminalDone)}",
        ].join('; ');
        await Process.start('cmd.exe', [
          '/c',
          'start',
          'Lumen GitHub Copilot Login',
          'powershell',
          '-NoExit',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          command,
        ]);
      } else if (Platform.isMacOS) {
        final script =
            'cd ${_shQuote(root)}; '
            'echo ${_shQuote(S.copilotLoginTerminalIntro)}; '
            'echo ${_shQuote(S.copilotLoginTerminalCommand)}; '
            '${_shQuote(cliPath)}; '
            'echo ${_shQuote(S.copilotLoginTerminalDone)}; '
            'exec bash';
        await Process.start('osascript', [
          '-e',
          'tell app "Terminal" to do script ${jsonEncode(script)}',
        ]);
      } else {
        final script =
            'cd ${_shQuote(root)}; '
            'echo ${_shQuote(S.copilotLoginTerminalIntro)}; '
            'echo ${_shQuote(S.copilotLoginTerminalCommand)}; '
            '${_shQuote(cliPath)}; '
            'echo ${_shQuote(S.copilotLoginTerminalDone)}; '
            'exec bash';
        await Process.start('x-terminal-emulator', [
          '-e',
          'bash',
          '-lc',
          script,
        ]);
      }
      return (ok: true, message: S.copilotLoginLaunched);
    } catch (e) {
      return (ok: false, message: '${S.copilotLoginFailed}: $e');
    }
  }

  Future<String> summarizeTitle(
    String firstMessage, {
    String model = 'gpt-5',
  }) async {
    if (!_hasAuth) return _fallbackTitle(firstMessage);
    final text = await generateChat([
      {
        'role': 'system',
        'content':
            'Reply with a 3-6 word title summarizing the user message. No quotes, no punctuation at the end, no preamble.',
      },
      {'role': 'user', 'content': firstMessage},
    ], model: model).timeout(const Duration(seconds: 45), onTimeout: () => '');
    final raw = text.replaceAll(RegExp(r'["`*\n]'), '').trim();
    return raw.isEmpty ? _fallbackTitle(firstMessage) : raw;
  }

  Future<void> dispose() async {
    for (final id in _streams.keys.toList()) {
      await _cancel(id);
    }
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    try {
      _process?.kill();
    } catch (_) {}
    _process = null;
  }

  Future<Map<String, dynamic>> _request(String type) async {
    final requestId = _nextRequestId();
    final completer = Completer<Map<String, dynamic>>();
    _pending[requestId] = completer;
    await _ensureProcess();
    _write({'type': type, 'requestId': requestId, 'auth': _auth});
    return completer.future;
  }

  Future<void> _ensureProcess() async {
    if (_process != null) return;
    final bridgePath = await CopilotProvisioner.ensure();
    if (bridgePath == null) {
      throw StateError(
        '${S.copilotBridgeNotReady} ${CopilotProvisioner.lastFailure ?? ''}',
      );
    }
    try {
      final process = await Process.start('node', [bridgePath]);
      _process = process;
      _stdoutSub = process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen(_handleLine);
      _stderrSub = process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => debugPrint('[Copilot bridge] $line'));
      unawaited(
        process.exitCode.then((code) {
          debugPrint('[Copilot bridge] exited with code $code');
          _process = null;
          final error = StateError('Copilot bridge exited with code $code');
          for (final completer in _pending.values) {
            if (!completer.isCompleted) completer.completeError(error);
          }
          _pending.clear();
          for (final controller in _streams.values) {
            controller.add({'type': 'error', 'error': '$error'});
            unawaited(controller.close());
          }
          _streams.clear();
        }),
      );
    } on ProcessException catch (e) {
      throw StateError('${S.copilotInstallNode} $e');
    }
  }

  void _handleLine(String line) {
    Map<String, dynamic> event;
    try {
      event = jsonDecode(line) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[Copilot] invalid bridge JSON: $line ($e)');
      return;
    }
    final requestId = event['requestId'] as String?;
    if (requestId == null) return;

    final type = event['type'] as String? ?? '';
    if (type == 'models') {
      final completer = _pending.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.complete(event);
      }
      return;
    }
    if (type == 'error' && _pending.containsKey(requestId)) {
      final completer = _pending.remove(requestId);
      if (completer != null && !completer.isCompleted) {
        completer.completeError(event['error'] as String? ?? 'Copilot error');
      }
      return;
    }
    _streams[requestId]?.add(event);
  }

  void _write(Map<String, dynamic> message) {
    final process = _process;
    if (process == null) throw StateError('Copilot bridge is not running.');
    process.stdin.writeln(jsonEncode(message));
  }

  Future<void> _cancel(String requestId) async {
    if (_process == null) return;
    try {
      _write({'type': 'cancel', 'requestId': requestId});
    } catch (_) {}
  }

  String _nextRequestId() => 'copilot-${++_requestSeq}';

  static String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

  static String _shQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

  static String? _copilotEffort(ReasoningEffort? effort) {
    if (effort == null) return null;
    return switch (effort) {
      ReasoningEffort.off => 'low',
      ReasoningEffort.standard => 'medium',
      ReasoningEffort.deep => 'high',
    };
  }

  static List<Map<String, dynamic>> _toolsForBridge(
    Set<String>? nativeToolIds,
  ) {
    if (nativeToolIds == null || nativeToolIds.isEmpty) return const [];
    return [
      for (final tool in NativeToolDefinitions.forOpenAi(nativeToolIds))
        {
          'name': tool['function']['name'],
          'description': tool['function']['description'],
          'parameters': tool['function']['parameters'],
        },
    ];
  }

  String _formatError(String message, {String? attemptedModel}) {
    final lower = message.toLowerCase();
    if (lower.contains('rate') || lower.contains('quota')) {
      return '${S.copilotErrorPrefix}: $message';
    }
    if (lower.contains('model') &&
        lower.contains('not') &&
        lower.contains('available') &&
        attemptedModel != null) {
      if (unavailableModels.add(attemptedModel)) {
        onUnavailableModelDiscovered?.call(attemptedModel);
      }
    }
    return '${S.copilotErrorPrefix}: $message';
  }

  static String _fallbackTitle(String firstMessage) {
    final fallback = firstMessage.trim().replaceAll(RegExp(r'\s+'), ' ');
    return fallback.length > 40 ? '${fallback.substring(0, 40)}...' : fallback;
  }
}
