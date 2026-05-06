/// History compression for the LLM wire payload.
///
/// Lumen uses a uniform text protocol with `<tool_result>...</tool_result>`
/// blocks injected as `'role': 'user'` messages during a turn's iteration
/// loop (see `chat_controller.dart` → `_runGenerationLoop`). Each tool_result
/// can carry an entire READ_FILE / TREE / GIT_DIFF payload — tens of
/// thousands of tokens. By the time the model reaches iteration 8 or 9 of
/// a long agentic turn, the early tool_results are stale (the file has
/// been edited since, the listing was already used to navigate, …) but we
/// still ship them verbatim on every subsequent iteration.
///
/// On models with smaller effective output budgets (cloud Ollama models
/// pin `num_ctx` to model max but `num_predict` defaults to "until end of
/// context" — meaning a 200K-token prompt leaves only ~56K for output on
/// a 256K model), this hits `done_reason: length` mid-edit and the
/// auto-continue path can't recover because the prompt is still huge on
/// the next attempt.
///
/// **Strategy**: keep the most recent N tool_result-bearing user messages
/// verbatim. Replace the inner content of older ones with a short stub
/// like `(elided: 8421 chars — "first line of original output")` while
/// preserving the `<tool_result>...</tool_result>` framing the model
/// uses to distinguish tool output from genuine user input. Also strip
/// Lumen's internal italic UI markers from assistant messages — those
/// strings (`_(auto-continued — …)_`, `_(loop guard tripped — …)_`,
/// `_(generation paused — …)_`) are UX text for the human reader and
/// just confuse smaller models when re-fed as conversation history.
///
/// Pure / stateless. Caller decides whether to apply (e.g. skip on
/// Anthropic to preserve automatic prompt-caching prefix stability).
library;

class HistoryCompressor {
  /// Recent tool_result count to keep verbatim when nothing else is
  /// specified. 4 covers the working window for a typical
  /// recon→read→edit→verify cycle without bloating the prompt with
  /// stale file dumps from earlier in the turn.
  static const int defaultKeepRecentToolResults = 4;

  /// Maximum length of the first-line preview embedded in an elision
  /// stub. Long enough to be useful as a "what was this?" hint
  /// (`[FAILED] foo.dart line 42: …`), short enough that 30 stubs
  /// don't themselves blow the context.
  static const int _previewMaxChars = 80;

  /// Returns a NEW list with the same shape as [messages] but with
  /// stale `<tool_result>` blocks elided and Lumen UI markers stripped.
  ///
  /// - [keepRecentToolResults]: number of trailing tool_result-bearing
  ///   user messages kept verbatim. Earlier ones get the inner content
  ///   replaced with a short stub. The XML-ish framing
  ///   (`<tool_result>...</tool_result>`) is preserved so the model
  ///   still recognises the message as tool output, not user prose.
  ///
  /// Original message maps are not mutated — entries are shallow-cloned
  /// when their content changes, and passed through unchanged otherwise.
  static List<Map<String, dynamic>> compressForWire(
    List<Map<String, dynamic>> messages, {
    int keepRecentToolResults = defaultKeepRecentToolResults,
  }) {
    if (messages.isEmpty) return messages;

    // Identify all tool_result-bearing user messages by index.
    final toolResultIndices = <int>[];
    for (var i = 0; i < messages.length; i++) {
      if (_isToolResultMessage(messages[i])) {
        toolResultIndices.add(i);
      }
    }

    // Indices that should be elided (everything except the last N).
    final eliminationCount = toolResultIndices.length - keepRecentToolResults;
    final elideIndices = eliminationCount > 0
        ? toolResultIndices.take(eliminationCount).toSet()
        : const <int>{};

    // Walk once, copying-on-modify.
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (elideIndices.contains(i)) {
        final original = m['content'] as String;
        out.add({...m, 'content': _stubForToolResult(original)});
        continue;
      }
      if (m['role'] == 'assistant' && m['content'] is String) {
        final stripped = stripUiMarkers(m['content'] as String);
        if (!identical(stripped, m['content'])) {
          out.add({...m, 'content': stripped});
          continue;
        }
      }
      out.add(m);
    }
    return out;
  }

  static bool _isToolResultMessage(Map<String, dynamic> m) {
    final role = m['role'];
    // Native-tools shape (Anthropic / Gemini / OpenAI / Ollama tool path).
    // Translated to provider-specific tool_result blocks at request
    // time; compression of stale entries works the same way.
    if (role == 'tool') return true;
    if (role != 'user') return false;
    final content = m['content'];
    return content is String && content.contains('<tool_result>');
  }

  /// Replace the inner body of a tool_result with a one-line summary.
  /// Handles BOTH shapes:
  ///
  /// - Text-grammar: `<tool_result>...</tool_result>` blocks inside a
  ///   user-role message's `content` string.
  /// - Native: a `role: 'tool'` message whose entire `content` IS the
  ///   tool output (no XML wrapper).
  ///
  /// Visible only via [compressForWire]; not exported because the
  /// regex shape is an implementation detail.
  static String _stubForToolResult(String original) {
    // Native shape — entire string IS the tool output. Compose the
    // stub directly without trying to find XML boundaries.
    if (!original.contains('<tool_result>')) {
      final inner = original.trim();
      if (inner.isEmpty) return '(elided: empty)';
      final firstLine = inner.split('\n').first.trim();
      final preview = firstLine.length > _previewMaxChars
          ? '${firstLine.substring(0, _previewMaxChars)}…'
          : firstLine;
      return '(elided: ${inner.length} chars — "$preview")';
    }
    final re = RegExp(r'<tool_result>([\s\S]*?)</tool_result>');
    return original.replaceAllMapped(re, (match) {
      final inner = (match.group(1) ?? '').trim();
      if (inner.isEmpty) return '<tool_result>(elided: empty)</tool_result>';
      final firstLine = inner.split('\n').first.trim();
      final preview = firstLine.length > _previewMaxChars
          ? '${firstLine.substring(0, _previewMaxChars)}…'
          : firstLine;
      return '<tool_result>(elided: ${inner.length} chars — '
          '"$preview")</tool_result>';
    });
  }

  /// Lumen UI markers we strip from assistant messages going to the
  /// wire. These are italic-prefixed status notes the chat panel
  /// renders for the human user — they have no signal value to the
  /// model on a follow-up turn and (worse) some smaller models parrot
  /// them or "complete" the truncated note instead of continuing the
  /// task.
  ///
  /// Patterns are non-greedy so a single message containing several
  /// markers gets each removed independently. Multi-line `[\s\S]` is
  /// used because the "generation paused" message in
  /// `OllamaService.generateChatStream` spans two lines.
  static final RegExp _kUiMarkerRe = RegExp(
    r'_\((?:auto-continued|loop guard tripped|generation paused|stopped) '
    r'(?:—[\s\S]*?)?\)_',
  );

  /// Public for unit testing. Strips the italic UI markers in
  /// `_kUiMarkerRe` and collapses any blank-line spam they leave behind.
  /// Returns the input unchanged (same instance) if no markers matched
  /// — caller can use `identical` to skip the copy.
  static String stripUiMarkers(String content) {
    if (!content.contains('_(')) return content;
    final stripped = content.replaceAll(_kUiMarkerRe, '');
    if (stripped.length == content.length) return content;
    return stripped.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  }
}
