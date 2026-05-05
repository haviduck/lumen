/// Two related model-misbehaviour detectors that run on every
/// agent-loop iteration in `chat_controller.dart`:
///
///  1. **Tool-syntax near-miss detector** — catches cases where the
///     model emitted what *looks like* a tool call but used the
///     wrong outer syntax (single-bracket `<LIST_DIR: .>`,
///     XML-style `<list_dir>...</list_dir>`, markdown fence). The
///     existing `_kCompleteToolCall` regex in `chat_controller.dart`
///     requires three angle brackets on each side, so a near-miss
///     fires zero tools and the model just keeps narrating —
///     resulting in the "model emits the same broken text twice
///     and gives up" failure mode the user reported on
///     `qwen3.5:cloud`.
///
///  2. **Hallucination detector** — catches cases where the model's
///     prose claims it "Created" / "Wrote" / "Edited" a specific
///     file path but no actual file-mutation tool fired for that
///     path during the turn. Common on weaker / smaller models
///     under reasoning load: the model role-plays the work instead
///     of invoking the tools.
///
/// Both are pure parsers — no I/O, no LLM round-trip. The chat
/// controller decides what to do with the findings:
///   - near-miss: append a synthetic tool_result to apiMessages
///     telling the model "you used `<X>` (wrong) — the correct
///     syntax is `<<<X: arg>>>`" and trigger auto-continue;
///   - hallucination: increment a per-turn counter and halt the
///     loop with a user-facing warning when it crosses a small
///     threshold (default 3).
library;

/// Outcome of a near-miss tool-syntax detection: the tool the
/// model was probably trying to call, plus a tag describing
/// which bracket-count shape was wrong so the controller can
/// build a precise correction nudge.
///
/// Three observed shapes in real usage (qwen3.5:cloud,
/// glm-5.1:cloud):
///   - `xmlStyle`: `<TOOL: arg>` or `<TOOL>` — single brackets
///     on both sides, classic XML-style.
///   - `doubleBracket`: `<<TOOL: arg>>` — two brackets on both
///     sides; the model is "halfway" to triple.
///   - `malformedClose`: `<<<TOOL: arg>>` or `<<<TOOL: arg>` —
///     opening is right (three `<`), but the close is short.
///     The most common shape with glm-5.1 because the model
///     drops a token at the end.
enum NearMissShape { xmlStyle, doubleBracket, malformedClose }

class HallucinationDetector {
  /// Threshold for halting a turn when hallucinated file-op claims
  /// accumulate within a single iteration. 3 is generous enough
  /// that a model writing past-tense in a recap section ("we
  /// updated foo and bar earlier") doesn't trip it on its own,
  /// while still catching the "spamming claims" failure mode
  /// where a model lists 5+ files it never actually wrote.
  static const int defaultHallucinationThreshold = 3;

  /// Tool ids whose presence in the per-turn `firedAcrossTurn`
  /// list satisfies a "Created / Wrote / Edited `path`" claim.
  /// Read tools and inspection tools (search_text, list_dir,
  /// read_file) intentionally not here — claiming "Created foo"
  /// after only reading foo is a hallucination.
  static const Set<String> _fileMutationToolIds = <String>{
    'create_file',
    'edit_file',
    'multi_edit',
    'append_file',
  };

  /// Detect "intent without action" — the model wrote a brief
  /// commitment ("Let me read the file:" / "I'll check that") and
  /// then stopped without invoking any tool. Distinct from the
  /// "empty response" case the auto-continue gate already handles
  /// because the response IS non-empty; the model just narrated
  /// instead of acting.
  ///
  /// Caller is expected to only call this when `pass.firedTools`
  /// is empty for the iteration. False-positive risk is real
  /// (model legitimately ending a chat-style answer with a
  /// trailing colon for a list it then forgot to write) but
  /// bounded by the auto-continue retry cap, and the recovered
  /// case (model finally invokes the tool) is far more valuable
  /// than the rare false trigger.
  ///
  /// Heuristics:
  ///   1. Strip code fences and thinking blocks first; we only
  ///      care about the model's surface prose.
  ///   2. The response is short (≤ [_kIntentMaxChars]) — long
  ///      multi-paragraph answers aren't this failure mode.
  ///   3. The trailing prose ends with a colon (the strongest
  ///      "tool call should have followed" signal) OR contains a
  ///      `Let me <verb>` / `I'll <verb>` / `I will <verb>` /
  ///      `Going to <verb>` commitment with an action verb
  ///      ([_actionVerbs]) AND ends without the kind of
  ///      conversational closer that signals "waiting for user"
  ///      (a question mark, "?", indicates the model handed
  ///      back to the user — leave it alone).
  static bool detectIntentWithoutAction(String assistantText) {
    if (assistantText.isEmpty) return false;
    final stripped = _stripFencedBlocks(assistantText)
        .replaceAll(RegExp(r'<!-- LUMEN_THINKING -->[\s\S]*?<!-- /LUMEN_THINKING -->'), '')
        .trim();
    if (stripped.isEmpty) return false;
    if (stripped.length > _kIntentMaxChars) return false;
    if (stripped.endsWith('?')) return false;

    if (stripped.endsWith(':')) return true;

    final intentRe = RegExp(
      r'\b(?:Let me|I[\u2019\x27]?ll|I will|Going to|Now I[\u2019\x27]?ll|First[,]? let me)\s+'
      r'([a-z]+)\b',
      caseSensitive: false,
    );
    for (final m in intentRe.allMatches(stripped)) {
      final verb = (m.group(1) ?? '').toLowerCase();
      if (_actionVerbs.contains(verb)) return true;
    }
    return false;
  }

  /// Generous upper bound. A model writing 800 chars of
  /// response is committing to a substantive answer; if it
  /// still didn't tool-call we're more likely looking at a
  /// chat-style reply than a stalled action. Tuned by the
  /// observed real-world cases (qwen3.5:cloud "Let me read
  /// the file:" was 39 chars; "Let me read more of the
  /// App.jsx file to identify the issues." was 60).
  static const int _kIntentMaxChars = 800;

  /// Verbs that almost always imply a tool call should have
  /// followed. Conservative on purpose — "think", "consider",
  /// "ponder", "wonder" intentionally NOT here because those
  /// are legit chat verbs the model uses without tools.
  static const Set<String> _actionVerbs = <String>{
    'read', 'check', 'look', 'examine', 'find', 'search', 'list',
    'see', 'view', 'inspect', 'identify', 'analyze', 'analyse',
    'fix', 'edit', 'update', 'create', 'write', 'modify',
    'run', 'execute', 'test', 'verify', 'open', 'load', 'fetch',
    'grep', 'scan',
  };

  /// `(toolName, shape)` describing the first near-miss found in
  /// the assistant text, or `null` if none.
  static ({String name, NearMissShape shape})? detectNearMissTool({
    required String assistantText,
    required Set<String> knownToolNames,
  }) {
    if (assistantText.isEmpty || knownToolNames.isEmpty) return null;

    final stripped = _stripFencedBlocks(assistantText);

    // First pass: look for any `<<<TOOL:` opener and check
    // whether it has a proper `>>>` close on the same logical
    // span. This catches the glm-5.1 "right-open, short-close"
    // shape (`<<<FIND_FILE: Legend>>`).
    //
    // Span = until next newline OR next `<<<` (whichever first),
    // because tools are line-oriented and a stray short-close
    // inside a multi-line body would be confused for a malformed
    // single-line call. Capping at 200 chars keeps us out of
    // CREATE_FILE / EDIT_FILE bodies entirely (those bodies
    // start with their own `<<<SEARCH>>>` / content lines).
    final tripleOpenRe = RegExp(r'<<<([A-Z][A-Z0-9_]{2,})\b');
    for (final m in tripleOpenRe.allMatches(stripped)) {
      final name = m.group(1) ?? '';
      if (!knownToolNames.contains(name)) continue;
      // Skip multi-line tool openers (`<<<EDIT_FILE: foo>>>`
      // followed by a body) — false-positives explode otherwise.
      // Multi-line tools always have their proper close as the
      // very next `>>>` on the same line as the opener, so the
      // scan below handles both cases naturally.
      final spanStart = m.end;
      final spanEnd = _findSpanEnd(stripped, spanStart, 200);
      final span = stripped.substring(spanStart, spanEnd);
      if (span.contains('>>>')) continue; // proper close exists
      // No `>>>` in the span; check for short closers `>>` or
      // `>` (in that priority — prefer reporting the more
      // specific case).
      if (RegExp(r'>>(?!>)').hasMatch(span) || RegExp(r'>(?![>])').hasMatch(span)) {
        return (name: name, shape: NearMissShape.malformedClose);
      }
    }

    // Second pass: `<<TOOL...>>` (double brackets both sides).
    // Anchored on a `<<` not preceded by `<` (so we don't catch
    // the inner two of a triple-open).
    final doubleOpenRe = RegExp(r'(?<!<)<<([A-Z][A-Z0-9_]{2,})(?::|\s|>)');
    for (final m in doubleOpenRe.allMatches(stripped)) {
      final name = m.group(1) ?? '';
      if (!knownToolNames.contains(name)) continue;
      return (name: name, shape: NearMissShape.doubleBracket);
    }

    // Third pass: original single-bracket XML-style. Anchored on
    // a `<` not preceded by another `<` so we don't double-fire
    // on the same span the doubleOpen / tripleOpen passes
    // already considered.
    final xmlRe = RegExp(r'(?<!<)<([A-Z][A-Z0-9_]{2,})(?::|\s|>)');
    for (final m in xmlRe.allMatches(stripped)) {
      final name = m.group(1) ?? '';
      if (!knownToolNames.contains(name)) continue;
      return (name: name, shape: NearMissShape.xmlStyle);
    }
    return null;
  }

  /// Find the end of a logical span starting at [from] in [s] —
  /// either the next newline, the next `<<<` (start of another
  /// tool block), or [from] + [maxLen], whichever comes first.
  /// Used by [detectNearMissTool] to scope the search for a
  /// matching `>>>` close.
  static int _findSpanEnd(String s, int from, int maxLen) {
    final hardCap = (from + maxLen).clamp(0, s.length);
    var end = hardCap;
    final nl = s.indexOf('\n', from);
    if (nl >= 0 && nl < end) end = nl;
    final next = s.indexOf('<<<', from);
    if (next > from && next < end) end = next;
    return end;
  }

  /// Find file-op claims in [assistantText] (past-tense like
  /// "Created `foo`" / "Wrote `foo`" / "Edited `foo`"), then
  /// return the subset of paths that DON'T have a corresponding
  /// fired tool.
  ///
  /// Path-comparison normalisation:
  ///   - Backslashes collapsed to forward slashes (Windows users
  ///     mention `src\foo.dart` while the executor's firstArg is
  ///     `src/foo.dart` — without normalisation you'd false-
  ///     positive on every Windows session).
  ///   - Surrounding whitespace, backticks, and quotes stripped.
  ///   - Both sides lower-cased, because models occasionally
  ///     case-flip in prose ("Created `App.jsx`" vs the tool
  ///     having received `app.jsx`).
  ///
  /// Returns paths in source order. Same path mentioned twice
  /// counts twice — that's the right behaviour because a model
  /// "spamming claims" is exactly the case we're trying to catch.
  static List<String> detectHallucinatedClaims({
    required String assistantText,
    required Iterable<String> firedFilePaths,
  }) {
    if (assistantText.isEmpty) return const <String>[];

    final stripped = _stripFencedBlocks(assistantText);
    final fired = firedFilePaths.map(_normalisePath).toSet();
    final result = <String>[];

    // Past-tense file-op claim. Negative lookbehind rules out
    // intent ("I'll create" / "going to write" / "plan to edit").
    // Path is a backtick / quote / bare token containing a `.ext`
    // suffix so we don't false-positive on bare words ("Created a
    // dashboard"). Capped extension length keeps the regex from
    // matching prose like "Edited a section.").
    final claimRe = RegExp(
      r'''(?<![Ww]ill\s|[Gg]oing\s+to\s|[Pp]lan(?:ning)?\s+to\s|I'?ll\s|[Ww]ould\s|[Cc]ould\s|[Mm]ight\s)'''
      r'\b(?:Created|Wrote|Added|Edited|Updated|Modified|Saved)\b'
      r'''[^`"\n]{0,40}'''
      r'''[`"]?([A-Za-z0-9_./\\-]+\.[A-Za-z0-9]{1,8})[`"]?''',
    );

    for (final m in claimRe.allMatches(stripped)) {
      final raw = m.group(1);
      if (raw == null || raw.isEmpty) continue;
      final norm = _normalisePath(raw);
      if (norm.isEmpty) continue;
      // A claim "matches" a fired tool when the fired path
      // contains or equals the claimed path. Accept either
      // direction so `src/foo.dart` matches a fired
      // `lib/src/foo.dart` and vice versa — models are sloppy
      // about path prefixes when narrating.
      final isMatched = fired.any(
        (f) =>
            f == norm ||
            f.endsWith('/$norm') ||
            norm.endsWith('/$f') ||
            f == _basename(norm) ||
            _basename(f) == _basename(norm),
      );
      if (!isMatched) {
        result.add(norm);
      }
    }
    return result;
  }

  /// Strip ``` fenced ``` and `~~~` code blocks so prose-only
  /// detectors (near-miss tool, file-op claims) don't match
  /// content the model is documenting rather than invoking.
  /// Inline backtick-runs are preserved — those are how the
  /// model quotes paths and tool names in prose, and stripping
  /// them would defeat the path matching.
  static String _stripFencedBlocks(String s) {
    final fenceRe = RegExp(
      r'(?:^|\n)(?:```|~~~)[^\n]*\n[\s\S]*?(?:\n)(?:```|~~~)(?=$|\n)',
      multiLine: true,
    );
    return s.replaceAll(fenceRe, '');
  }

  /// Tool ids that count as "I actually mutated a file".
  static bool isFileMutationTool(String toolId) =>
      _fileMutationToolIds.contains(toolId);

  static String _normalisePath(String s) {
    return s.trim().replaceAll('\\', '/').replaceAll(RegExp(r'^/+'), '').toLowerCase();
  }

  static String _basename(String s) {
    final i = s.lastIndexOf('/');
    return i < 0 ? s : s.substring(i + 1);
  }
}
