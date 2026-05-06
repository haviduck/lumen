/// Single source of truth for per-RetryReason nudge prose.
///
/// Pulled out of [ChatController._runGenerationLoop] in 2026-05.
/// The inline 6-branch switch had grown to ~120 lines of English
/// prose interleaved with control flow — moved here so the prose
/// stays editable without scrolling past nudge logic, and so future
/// localization work has a single file to translate.
///
/// Brevity matters: a long scolding primes weaker models to apologize
/// and start over instead of taking the next concrete action. Each
/// nudge is one or two sentences, action-first, no negative-example
/// rehearsal.
library;

import '../../services/tool_registry.dart';
import 'generation_loop_types.dart';
import 'hallucination_detector.dart';

/// Build the user-message text injected into history when the
/// auto-continue gate fires for [reason]. Caller is responsible for
/// only invoking this when the reason is non-null.
///
/// [extra] carries reason-specific context: for [RetryReason.nearMissTool]
/// the (toolName, shape) tuple; for [RetryReason.thinkingNoOutput]
/// whether thinking content was actually present (changes the
/// nudge's framing).
String buildNudge(RetryReason reason, {NudgeContext? extra}) {
  switch (reason) {
    case RetryReason.hallucinatedToolResult:
      return 'I cut your stream because you started writing a '
          '`<tool_result>` block. NO tool has actually run. Those '
          'messages come ONLY from Lumen, AFTER a real tool '
          'executes. To call a tool, emit one tool call (native '
          'tools API or three-bracket text grammar), then STOP and '
          'wait for the real result.';

    case RetryReason.nearMissTool:
      return _nearMissNudge(extra);

    case RetryReason.intentWithoutAction:
      return 'You said you would do something but never invoked the '
          'tool. The IDE only sees a tool call when you actually '
          'emit one. Either call the tool now, or ask the user a '
          'concrete question if you genuinely don\'t know what to '
          'do.';

    case RetryReason.incompleteFileTool:
      return 'You opened a multi-line tool block (CREATE_FILE / '
          'EDIT_FILE / MULTI_EDIT / EDIT_RANGE / APPEND_FILE) but '
          'never emitted the matching close marker. No file was '
          'created or edited. Re-emit ONE complete tool block with '
          'opening, body, and close, then stop and wait for the '
          'tool result.';

    case RetryReason.truncation:
      return 'Your previous response was cut at the output token '
          'cap. Continue from where you left off. Prefer EDIT_FILE '
          '/ MULTI_EDIT over CREATE_FILE so you don\'t retype '
          'content you already produced.';

    case RetryReason.thinkingNoOutput:
      return 'You reasoned internally but produced no visible '
          'output. Your thinking was received — now commit to an '
          'action: either call a tool or give a brief answer. Do '
          'not stay silent after thinking.';

    case RetryReason.empty:
      return 'Your previous response had no content. Either '
          'complete the task with a tool call, or briefly say what '
          'you need from me to proceed.';
  }
}

/// Per-reason context for nudge customization.
class NudgeContext {
  final String? toolName;
  final NearMissShape? shape;
  final Set<String>? enabledToolIds;

  const NudgeContext({this.toolName, this.shape, this.enabledToolIds});
}

String _nearMissNudge(NudgeContext? extra) {
  final toolName = extra?.toolName ?? 'TOOL_NAME';
  final shape = extra?.shape;
  switch (shape) {
    case NearMissShape.xmlStyle:
      return 'You wrote `<$toolName: ...>` (single angle brackets). '
          'NO tool ran. The text-grammar parser requires three angle '
          'brackets each side: `<<<$toolName: args>>>`. Re-emit the '
          'invocation, then stop.';
    case NearMissShape.doubleBracket:
      return 'You wrote `<<$toolName: ...>>` (two angle brackets). '
          'NO tool ran. The parser requires three: '
          '`<<<$toolName: args>>>`. Re-emit and stop.';
    case NearMissShape.malformedClose:
      return 'You opened with three brackets `<<<$toolName:` but '
          'closed with fewer than three `>`. Re-emit with the proper '
          'close: `<<<$toolName: args>>>`, then stop.';
    case NearMissShape.htmlComment:
      final isGeneric = toolName == 'LUMEN_TOOL';
      final example = isGeneric
          ? '<<<TOOL_NAME: args>>>'
          : '<<<$toolName: args>>>';
      return 'You wrote `<!-- LUMEN_TOOL ... -->`. That is an '
          'INTERNAL Lumen display token, not a tool invocation. To '
          'actually call a tool, emit `$example`, then stop.';
    case NearMissShape.unknownTool:
      final candidates = _suggestSimilarToolsLocal(
        toolName,
        extra?.enabledToolIds ?? const <String>{},
      );
      final hint = candidates.isEmpty
          ? 'See the system prompt\'s tool list.'
          : 'Closest registered tools: ${candidates.join(', ')}.';
      return 'You called `<<<$toolName: ...>>>` but $toolName is not '
          'a registered tool — NO tool ran. $hint Re-emit ONE real '
          'tool call, then stop.';
    case null:
      return 'NO tool ran — your last message looked like a tool '
          'call but didn\'t parse. Re-emit using the canonical '
          'three-bracket syntax: `<<<TOOL_NAME: args>>>`, then stop.';
  }
}

/// Cheap edit-distance ranking for unknown-tool suggestions. Local
/// copy so this module stays controller-agnostic; matches the
/// algorithm used by `ChatController._suggestSimilarTools`.
List<String> _suggestSimilarToolsLocal(
    String unknown, Set<String> enabledToolNames) {
  if (enabledToolNames.isEmpty) return const <String>[];
  // Convert tool ids to upper-snake names for comparison if the
  // caller passed lowercase ids.
  final normalized = enabledToolNames.map((s) => s.toUpperCase()).toSet();
  final upper = unknown.toUpperCase();
  final scored = <(int, String)>[];
  for (final name in normalized) {
    if (name.contains(upper) || upper.contains(name)) {
      scored.add((0, name));
      continue;
    }
    final dist = _levenshtein(upper, name);
    if (dist <= 3 || dist <= name.length ~/ 3) {
      scored.add((dist, name));
    }
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return scored.take(3).map((p) => p.$2).toList();
}

int _levenshtein(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  final m = a.length, n = b.length;
  var prev = List<int>.generate(n + 1, (i) => i);
  var curr = List<int>.filled(n + 1, 0);
  for (var i = 1; i <= m; i++) {
    curr[0] = i;
    for (var j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      curr[j] = [
        prev[j] + 1,
        curr[j - 1] + 1,
        prev[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }
  return prev[n];
}

/// Convenience wrapper: build a NudgeContext from the loop's
/// near-miss tool record.
NudgeContext nearMissContext(
    {required String toolName,
    required NearMissShape shape,
    required Set<String> enabledToolIds}) {
  return NudgeContext(
    toolName: toolName, shape: shape, enabledToolIds: enabledToolIds,
  );
}

/// Marker — keep [ToolRegistry] referenced so dead-code analysers
/// don't suggest dropping the import (the helpers may use it in
/// future tier-aware suggestions).
// ignore: unused_element
void _keepToolRegistryRef() => ToolRegistry.all.length;
