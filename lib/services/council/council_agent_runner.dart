import 'dart:async';

import '../anthropic_service.dart';
import '../copilot_service.dart';
import '../gemini_service.dart';
import '../ollama_service.dart' show CancellationToken, OllamaService;
import '../tool_executor.dart';
import '../tools/native_tool_format.dart';
import 'council_models.dart';
import 'council_protocol.dart';

class CouncilToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const CouncilToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

class CouncilToolResult {
  final String feedback;
  final bool shouldContinue;
  final bool finalizesSession;

  const CouncilToolResult({
    required this.feedback,
    this.shouldContinue = true,
    this.finalizesSession = false,
  });
}

class CouncilRunResult {
  final String content;
  final bool cancelled;

  const CouncilRunResult({required this.content, this.cancelled = false});
}

typedef CouncilChunkCallback = void Function(String chunk);
typedef CouncilToolCallback =
    Future<CouncilToolResult> Function(CouncilToolCall call);

/// Callback fired when a runner detects that the model has gone silent.
/// [agentId] identifies the stalled agent; [silentSeconds] is how long
/// the stream has been quiet. Return true to auto-nudge the runner with
/// a continuation prompt; return false to leave it alone.
typedef StallCallback = bool Function(String agentId, int silentSeconds);

/// Callback fired just before a tool call executes. Allows the controller
/// to surface a structured "currently doing X" signal in the UI (file
/// being read, file being edited, command being run, etc.) without
/// piping raw model output into a speech bubble.
///
/// [agentId] is the runner's agent. [toolId] is the canonical tool name
/// (e.g. `read_file`, `edit_file`, `run_cmd`). [arguments] is the raw
/// arguments map from the native tool format — the controller decides
/// which argument is the user-facing "primary" (path / pattern / cmd).
typedef ToolFireCallback = void Function(
  String agentId,
  String toolId,
  Map<String, dynamic> arguments,
);

class CouncilAgentRunner {
  CouncilAgentRunner({
    required this.agent,
    required this.anthropic,
    required this.copilot,
    required this.gemini,
    required this.ollama,
    required this.toolExecutor,
    required this.systemPrompt,
    required this.userPrompt,
    required this.nativeToolIds,
    required this.onChunk,
    required this.onCouncilTool,
    this.userImages = const <String>[],
    this.onStall,
    this.stallTimeoutSeconds = 90,
    this.onToolFire,
  });

  final CouncilAgent agent;
  final AnthropicService anthropic;
  final CopilotService copilot;
  final GeminiService gemini;
  final OllamaService ollama;
  final ToolExecutor toolExecutor;
  final String systemPrompt;
  final String userPrompt;
  /// Base64 JPEG images to attach to the very first user turn. Wire shape
  /// matches mid-session `_pendingUserNotes` and `ChatController` — the
  /// Anthropic / Gemini / Ollama services convert this `images` key into
  /// their respective vision blocks. Used by the Convene-the-Council
  /// modal so pasted/picked images become real visual context for the
  /// orchestrator instead of filename references in prose.
  final List<String> userImages;
  final Set<String> nativeToolIds;
  final CouncilChunkCallback onChunk;
  final CouncilToolCallback onCouncilTool;
  final CancellationToken token = CancellationToken();

  /// Fired when the model has been silent for [stallTimeoutSeconds].
  /// If callback returns true, a nudge message is injected automatically.
  final StallCallback? onStall;

  /// Seconds of silence before firing [onStall]. Default 90s — long
  /// enough for legitimate thinking pauses, short enough to catch
  /// genuinely stuck Ollama / weaker models.
  final int stallTimeoutSeconds;

  /// Fired the moment a native tool call is identified, BEFORE the tool
  /// runs. Lets the controller emit `agentToolFire` so the activity
  /// bubble can flash "Reading X" / "Editing Y" while the work happens
  /// instead of waiting for the model to narrate.
  final ToolFireCallback? onToolFire;

  Timer? _stallTimer;
  DateTime _lastChunkAt = DateTime.now();
  int _nudgeCount = 0;
  bool _awaitingToolResult = false;
  static const int _maxAutoNudges = 3;

  /// Mid-session messages from the human to splice into the agent's
  /// message list at the next iteration boundary. Used by the orchestrator
  /// "ping" UX so the user can change directives without aborting the run.
  ///
  /// Each entry pairs the trimmed text with an optional list of base64
  /// JPEG images sourced from the clipboard / file picker. The images
  /// are emitted on the message map under the `images` key so the wire
  /// shape matches `ChatController` exactly — Anthropic / Gemini /
  /// Ollama services convert it to their respective vision blocks.
  /// (Copilot / GitHub Models currently silently drop the images key,
  /// which is a separate provider-side fix.)
  final List<({String text, List<String> images})> _pendingUserNotes =
      <({String text, List<String> images})>[];

  /// Queue a human note to inject before the next iteration. Empty
  /// notes with no attachments are ignored; an image-only note (no
  /// text) is allowed and forwarded to the model as a user turn whose
  /// content is a short stub plus the image attachments.
  void addUserNote(String note, {List<String> images = const []}) {
    final trimmed = note.trim();
    if (trimmed.isEmpty && images.isEmpty) return;
    _pendingUserNotes.add((
      text: trimmed,
      images: List<String>.unmodifiable(images),
    ));
  }

  Future<CouncilRunResult> run({int maxIterations = 12}) async {
    final initialUser = <String, dynamic>{
      'role': 'user',
      'content': userPrompt,
    };
    if (userImages.isNotEmpty) {
      initialUser['images'] = List<String>.unmodifiable(userImages);
    }
    final messages = <Map<String, dynamic>>[
      {'role': 'system', 'content': systemPrompt},
      initialUser,
    ];
    final transcript = StringBuffer();

    _startStallTimer();
    try {
    for (var i = 0; i < maxIterations; i++) {
      if (token.isCancelled) {
        return CouncilRunResult(
          content: transcript.toString(),
          cancelled: true,
        );
      }

      // Drain any user notes the human pushed mid-session before the
      // next stream call, so the agent sees them as a fresh user turn
      // and can rewire the plan / re-dispatch agents accordingly.
      while (_pendingUserNotes.isNotEmpty) {
        final note = _pendingUserNotes.removeAt(0);
        final body = note.text.isEmpty
            ? '(image-only attachment from the human user)'
            : note.text;
        final entry = <String, dynamic>{
          'role': 'user',
          'content':
              'USER NOTE (mid-session injection from the human user). '
              'Bake this into the plan. If it changes any other agent\'s '
              'directives, update them via the council_dispatch tool with '
              'revised tasks instead of ignoring them:\n\n$body',
        };
        if (note.images.isNotEmpty) {
          entry['images'] = note.images;
        }
        messages.add(entry);
      }

      final visible = StringBuffer();
      NativeToolUse? pendingTool;

      _resetStallTimer();
      await for (final rawChunk in _stream(messages)) {
        if (token.isCancelled) {
          return CouncilRunResult(
            content: transcript.toString(),
            cancelled: true,
          );
        }

        _resetStallTimer();

        if (rawChunk.contains(NativeToolUseMarker.prefix)) {
          final parsed = NativeToolUseMarker.tryParse(rawChunk);
          if (parsed != null) {
            final before = rawChunk.substring(0, parsed.markerStart);
            final cleanBefore = _cleanVisibleChunk(before);
            if (cleanBefore.isNotEmpty) {
              visible.write(cleanBefore);
              transcript.write(cleanBefore);
              onChunk(cleanBefore);
            }
            pendingTool = parsed;
            break;
          }
        }

        final cleanChunk = _cleanVisibleChunk(rawChunk);
        if (cleanChunk.isEmpty) continue;
        visible.write(cleanChunk);
        transcript.write(cleanChunk);
        onChunk(cleanChunk);
      }

      final visibleText = visible.toString();
      if (pendingTool == null) {
        _awaitingToolResult = true;
        final pass = await toolExecutor.run(visibleText);
        _awaitingToolResult = false;
        _resetStallTimer();
        if (pass.hasToolCalls) {
          messages.add({'role': 'assistant', 'content': visibleText});
          messages.add({
            'role': 'user',
            'content': '<tool_result>\n${pass.toolFeedback}\n</tool_result>',
          });
          continue;
        }
        messages.add({'role': 'assistant', 'content': visibleText});
        return CouncilRunResult(content: transcript.toString());
      }

      final tool = pendingTool;
      final call = CouncilToolCall(
        id: tool.id,
        name: tool.name,
        arguments: tool.arguments,
      );
      // Surface the tool fire BEFORE running it so the activity bubble
      // shows "Reading X" / "Editing Y" while the work is in flight,
      // not after. Skip council protocol tools — those have their own
      // dedicated event surfaces (dispatched / askedPool / askedUser /
      // reported) that the UI already handles.
      if (!CouncilProtocol.allCouncilToolIds.contains(tool.name)) {
        onToolFire?.call(agent.id, tool.name, tool.arguments);
      }
      _awaitingToolResult = true;
      final toolResult = CouncilProtocol.allCouncilToolIds.contains(tool.name)
          ? await onCouncilTool(call)
          : await _runLumenTool(call);
      _awaitingToolResult = false;
      _resetStallTimer();

      messages.add({
        'role': 'assistant',
        'content': visibleText,
        'tool_use': {
          'id': tool.id,
          'name': tool.name,
          'arguments': tool.arguments,
        },
      });
      messages.add({
        'role': 'tool',
        'tool_use_id': tool.id,
        'tool_name': tool.name,
        'content': toolResult.feedback,
      });

      if (toolResult.finalizesSession || !toolResult.shouldContinue) {
        return CouncilRunResult(content: transcript.toString());
      }
    }

    return CouncilRunResult(content: transcript.toString());
    } finally {
      _cancelStallTimer();
    }
  }

  void _startStallTimer() {
    _lastChunkAt = DateTime.now();
    _nudgeCount = 0;
    _cancelStallTimer();
    if (stallTimeoutSeconds <= 0 || onStall == null) return;
    _stallTimer = Timer.periodic(
      Duration(seconds: stallTimeoutSeconds ~/ 3),
      (_) => _checkStall(),
    );
  }

  void _resetStallTimer() {
    _lastChunkAt = DateTime.now();
  }

  void _cancelStallTimer() {
    _stallTimer?.cancel();
    _stallTimer = null;
  }

  void _checkStall() {
    if (token.isCancelled) {
      _cancelStallTimer();
      return;
    }
    // Don't fire during tool execution — the model can't produce output
    // while waiting for a tool result (especially council_wait which
    // blocks for minutes). This is the expected state, not a stall.
    if (_awaitingToolResult) return;
    final silentSecs = DateTime.now().difference(_lastChunkAt).inSeconds;
    if (silentSecs < stallTimeoutSeconds) return;
    if (_nudgeCount >= _maxAutoNudges) {
      _cancelStallTimer();
      return;
    }
    final shouldNudge = onStall?.call(agent.id, silentSecs) ?? false;
    if (shouldNudge) {
      _nudgeCount++;
      _lastChunkAt = DateTime.now();
      addUserNote(
        'SYSTEM NUDGE (auto-generated — the model has been silent for '
        '${silentSecs}s). You are mid-task. Continue producing output. '
        'If you are stuck, describe the blocker. Do NOT start over — '
        'resume from where you left off.',
      );
    }
  }

  String _cleanVisibleChunk(String chunk) {
    return chunk
        .replaceAll(
          RegExp(r'<!--\s*LUMEN_THINK_START\s*-->', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<!--\s*LUMEN_THINK_END\s*-->', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<!--\s*lumen_think_start\s*-->', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<!--\s*lumen_think_end\s*-->', caseSensitive: false),
          '',
        );
  }

  Future<CouncilToolResult> _runLumenTool(CouncilToolCall call) async {
    final pass = await toolExecutor.runNativeToolCall(
      toolId: call.name,
      args: call.arguments,
    );
    return CouncilToolResult(feedback: pass.toolFeedback);
  }

  Stream<String> _stream(List<Map<String, dynamic>> messages) {
    final split = _splitModel(agent.model);
    switch (split.provider) {
      case 'claude':
        return anthropic.generateChatStream(
          messages,
          model: split.rawModel,
          token: token,
          nativeToolIds: nativeToolIds,
        );
      case 'copilot':
        return copilot.generateChatStream(
          messages,
          model: split.rawModel,
          token: token,
          nativeToolIds: nativeToolIds,
        );
      case 'gemini':
        return gemini.generateChatStream(
          messages,
          model: split.rawModel,
          token: token,
          nativeToolIds: nativeToolIds,
        );
      case 'ollama-cloud':
        return ollama.generateChatStream(
          messages,
          model: split.rawModel,
          token: token,
          forceCloud: true,
          nativeToolIds: nativeToolIds,
        );
      case 'ollama':
        return ollama.generateChatStream(
          messages,
          model: split.rawModel,
          token: token,
          nativeToolIds: nativeToolIds,
        );
      case 'github':
        return Stream<String>.value(
          'GitHub Models was removed; please pick another model.',
        );
      default:
        return Stream<String>.value(
          'Council does not support model "${agent.model}". '
          'Pick a claude / copilot / gemini / ollama / ollama-cloud model.',
        );
    }
  }

  ({String provider, String rawModel}) _splitModel(String model) {
    final idx = model.indexOf(':');
    if (idx < 0) return (provider: model, rawModel: model);
    return (
      provider: model.substring(0, idx),
      rawModel: model.substring(idx + 1),
    );
  }

}
