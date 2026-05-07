import '../anthropic_service.dart';
import '../copilot_service.dart';
import '../ollama_service.dart' show CancellationToken;
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

class CouncilAgentRunner {
  CouncilAgentRunner({
    required this.agent,
    required this.anthropic,
    required this.copilot,
    required this.toolExecutor,
    required this.systemPrompt,
    required this.userPrompt,
    required this.nativeToolIds,
    required this.onChunk,
    required this.onCouncilTool,
    this.userImages = const <String>[],
  });

  final CouncilAgent agent;
  final AnthropicService anthropic;
  final CopilotService copilot;
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

      await for (final rawChunk in _stream(messages)) {
        if (token.isCancelled) {
          return CouncilRunResult(
            content: transcript.toString(),
            cancelled: true,
          );
        }

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
        final pass = await toolExecutor.run(visibleText);
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
      final toolResult = CouncilProtocol.allCouncilToolIds.contains(tool.name)
          ? await onCouncilTool(call)
          : await _runLumenTool(call);

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
    if (split.provider == 'claude') {
      return anthropic.generateChatStream(
        messages,
        model: split.rawModel,
        token: token,
        nativeToolIds: nativeToolIds,
      );
    }
    if (split.provider == 'copilot') {
      return copilot.generateChatStream(
        messages,
        model: split.rawModel,
        token: token,
        nativeToolIds: nativeToolIds,
      );
    }
    if (split.provider == 'github') {
      return Stream<String>.value(
        'GitHub Models was removed; please pick another model.',
      );
    }
    return Stream<String>.value(
      'Council requires a claude:* or copilot:* model.',
    );
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
