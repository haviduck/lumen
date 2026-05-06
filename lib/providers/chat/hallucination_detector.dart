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
/// Four observed shapes in real usage (qwen3.5:cloud,
/// glm-5.1:cloud, gemma):
///   - `xmlStyle`: `<TOOL: arg>` or `<TOOL>` — single brackets
///     on both sides, classic XML-style.
///   - `doubleBracket`: `<<TOOL: arg>>` — two brackets on both
///     sides; the model is "halfway" to triple.
///   - `malformedClose`: `<<<TOOL: arg>>` or `<<<TOOL: arg>` —
///     opening is right (three `<`), but the close is short.
///     The most common shape with glm-5.1 because the model
///     drops a token at the end.
///   - `htmlComment`: `<!-- LUMEN_TOOL:edit_file|...|ok -->` (or
///     lowercase / dash-separated variants). The model has seen
///     these markers in conversation history — they're our
///     internal "tool ran" markers that the executor rewrites
///     real tool calls into for the chat UI — and started
///     emitting them as a fake tool-call syntax. NO real tool
///     runs; the UI parses the marker as if a tool already
///     completed, and the user gets a hallucinated card. Most
///     common with weaker Ollama models that latch onto any
///     repeated structural pattern in their context window.
///   - `unknownTool`: `<<<COPY_FILE: src -> dst>>>` shape — the
///     SYNTAX is correct (proper triple-bracket open and close,
///     colon, args), but the tool name isn't registered. Means
///     the model is inventing tools (`COPY_FILE` before this
///     existed, `LIST_FILES`, `GREP`, `RG`, …) instead of using
///     what's in the system prompt. Without this shape the
///     `intentWithoutAction` path mis-diagnoses these as "the
///     model never tool-called" — but it DID, just with a name
///     we don't dispatch on. Surfacing the unknown name lets us
///     nudge with "that tool doesn't exist; the registered ones
///     are: …" so the model can self-correct in one turn.
enum NearMissShape {
  xmlStyle,
  doubleBracket,
  malformedClose,
  htmlComment,
  unknownTool,
}

class HallucinationDetector {
  /// Threshold for halting a turn when hallucinated file-op claims
  /// accumulate within a single iteration. 3 is generous enough
  /// that a model writing past-tense in a recap section ("we
  /// updated foo and bar earlier") doesn't trip it on its own,
  /// while still catching the "spamming claims" failure mode
  /// where a model lists 5+ files it never actually wrote.
  static const int defaultHallucinationThreshold = 3;

  /// Tool ids whose presence in the per-turn `firedAcrossTurn`
  /// list satisfies a "Created / Wrote / Edited / Copied `path`"
  /// claim. Read tools and inspection tools (search_text,
  /// list_dir, read_file) intentionally not here — claiming
  /// "Created foo" after only reading foo is a hallucination.
  ///
  /// `copy_file` is included because the destination of a copy IS
  /// a newly-created file, and the model legitimately narrates it
  /// as "Created `dst.dart`" or "Copied `dst.dart`". MOVE_FILE and
  /// DELETE_FILE are intentionally NOT here — those don't satisfy
  /// a creation claim, and the prose-claim regex below doesn't
  /// include `Moved` / `Deleted` for the same reason.
  static const Set<String> _fileMutationToolIds = <String>{
    'create_file',
    'edit_file',
    'multi_edit',
    'edit_range',
    'append_file',
    'copy_file',
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
  ///      "tool call should have followed" signal), OR contains
  ///      a commitment phrase (`Let me`, `I'll`, `I will`,
  ///      `Going to`, `First, let me`, `Now I'll`) followed
  ///      within ~80 chars by an action verb in any inflection
  ///      (`read | reads | reading | readed`). The window-based
  ///      match catches the common "Let me start by reading…"
  ///      pattern where the immediate next word is a filler
  ///      ("start", "begin", "first") and the real verb sits
  ///      a few words later as a gerund. False positives at
  ///      this layer are bounded by the auto-continue retry
  ///      cap; recovered cases (model finally invokes the
  ///      tool) are far more valuable than the rare miss.
  ///   4. A trailing question mark short-circuits — "?" means
  ///      the model handed back to the user; leave it alone.
  static bool detectIntentWithoutAction(String assistantText) {
    if (assistantText.isEmpty) return false;
    final stripped = _stripFencedBlocks(assistantText)
        .replaceAll(RegExp(r'<!-- LUMEN_THINKING -->[\s\S]*?<!-- /LUMEN_THINKING -->'), '')
        .trim();
    if (stripped.isEmpty) return false;
    if (stripped.length > _kIntentMaxChars) return false;
    if (stripped.endsWith('?')) return false;

    if (stripped.endsWith(':')) return true;

    // Match a commitment phrase, then look for ANY action verb in
    // any inflection within the next 80 chars. This is the
    // permissive form of the old "exact next word must be an
    // action verb" rule — wide enough to catch "Let me start by
    // looking at App.tsx" / "I'll begin by reading the
    // BubbleBackground component" / "First, let me explore the
    // styles", which the strict form missed because it stopped
    // at "start" / "begin" / "explore".
    final commitRe = RegExp(
      r'\b(?:Let me|I[\u2019\x27]?ll|I will|Going to|'
      r'Now I[\u2019\x27]?ll|First[,]? let me|First[,]? I[\u2019\x27]?ll|'
      r'Let me start|Let me begin|Let me first)\b',
      caseSensitive: false,
    );
    for (final m in commitRe.allMatches(stripped)) {
      final scanFrom = m.end;
      final scanTo = (scanFrom + 80).clamp(0, stripped.length);
      final span = stripped.substring(scanFrom, scanTo).toLowerCase();
      for (final verb in _actionVerbs) {
        if (RegExp('\\b$verb(?:s|es|ed|ing)?\\b').hasMatch(span)) {
          return true;
        }
      }
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
  /// followed. Includes both direct action verbs (`read`, `edit`,
  /// `run`) AND recon-flavored verbs (`understand`, `review`,
  /// `investigate`) that small / cloud-Ollama models routinely
  /// commit to without follow-through. Conservative on intentional
  /// chat verbs — "think", "consider", "ponder", "wonder",
  /// "imagine", "guess" stay OFF the list because those are legit
  /// reasoning patterns where no tool should fire.
  ///
  /// The detector matches any inflection (`read | reads | reading
  /// | readed`) so we don't have to enumerate every form here.
  static const Set<String> _actionVerbs = <String>{
    'read', 'check', 'look', 'examine', 'find', 'search', 'list',
    'see', 'view', 'inspect', 'identify', 'analyze', 'analyse',
    'fix', 'edit', 'update', 'create', 'write', 'modify',
    'run', 'execute', 'test', 'verify', 'open', 'load', 'fetch',
    'grep', 'scan',
    // Added 2026-05 after observing gemma4:31b and deepseek-v4-pro
    // commit-and-stop with these recon verbs and never invoke a
    // tool. "Let me start by understanding…" / "Let me begin by
    // exploring the codebase" / "First, let me review the
    // structure" all need to fire the detector now.
    'understand', 'review', 'explore', 'investigate', 'gather',
    'dig', 'walk', 'browse', 'trace',
    // Direct mutation verbs the small-model commit-and-stop
    // pattern also lands on. "I'll add bubble animation",
    // "I'll implement the change", "Going to remove the dead
    // code". Same false-positive bound as the recon set.
    'add', 'remove', 'delete', 'implement', 'build', 'install',
    'refactor', 'rename', 'move',
  };

  /// `(toolName, shape)` describing the first near-miss found in
  /// the assistant text, or `null` if none.
  static ({String name, NearMissShape shape})? detectNearMissTool({
    required String assistantText,
    required Set<String> knownToolNames,
  }) {
    if (assistantText.isEmpty || knownToolNames.isEmpty) return null;

    final stripped = _stripFencedBlocks(assistantText);

    // Zeroth pass: HTML-comment marker mimicry. Catches
    // `<!-- LUMEN_TOOL:edit_file|...|ok -->` and lowercase /
    // dash-separated variants. These are our internal
    // "executor rewrote your tool call into a marker" form —
    // when the model sees them in history and emits them as if
    // they were a tool-call syntax, NO tool runs. Caught here so
    // the auto-continue gate can nudge with the correct
    // `<<<TOOL: arg>>>` form. Lexical priority over the
    // triple/double/xml passes below: those are anchored on
    // `<[A-Z]` so they would never match `<!--` anyway, but
    // making the order explicit guards against a future regex
    // tweak that might.
    final htmlCommentRe = RegExp(
      r'<!--\s*LUMEN[\s_-]?TOOL(?::\s*([a-z_]+))?',
      caseSensitive: false,
    );
    final htmlMatch = htmlCommentRe.firstMatch(stripped);
    if (htmlMatch != null) {
      // Capture group 1 is the lowercase tool id from the marker
      // (e.g. `edit_file`). Uppercase to match the convention the
      // existing nudges use (`<<<EDIT_FILE: …>>>`). Fall back to
      // a sentinel when the marker doesn't include a tool id —
      // the controller renders a shape-specific message that
      // doesn't depend on a known tool name.
      final captured = (htmlMatch.group(1) ?? '').toUpperCase();
      final name = captured.isNotEmpty && knownToolNames.contains(captured)
          ? captured
          : 'LUMEN_TOOL';
      return (name: name, shape: NearMissShape.htmlComment);
    }

    // First pass: look for any `<<<TOOL:` opener and check
    // whether it has a proper `>>>` close on the same logical
    // span. Two near-miss outcomes from this pass:
    //   - Known tool name, missing close (`>>` / `>`) → catches
    //     the glm-5.1 "right-open, short-close" shape
    //     (`<<<FIND_FILE: Legend>>`). Returned as `malformedClose`.
    //   - Unknown tool name, proper close → catches the model
    //     inventing tools (`<<<COPY_FILE: …>>>` before this PR,
    //     `<<<LIST_FILES: …>>>`, `<<<GREP: …>>>`). Syntax is
    //     correct, name isn't registered, NO tool runs. Returned
    //     as `unknownTool` so the controller can nudge with the
    //     real tool list instead of falling through to the
    //     generic `intentWithoutAction` message which obscures the
    //     real failure.
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
      // Skip multi-line tool openers (`<<<EDIT_FILE: foo>>>`
      // followed by a body) — false-positives explode otherwise.
      // Multi-line tools always have their proper close as the
      // very next `>>>` on the same line as the opener, so the
      // scan below handles both cases naturally.
      final spanStart = m.end;
      final spanEnd = _findSpanEnd(stripped, spanStart, 200);
      final span = stripped.substring(spanStart, spanEnd);
      final hasProperClose = span.contains('>>>');
      if (knownToolNames.contains(name)) {
        if (hasProperClose) continue; // valid call, not a near-miss
        // No `>>>` in the span; check for short closers `>>` or
        // `>` (in that priority — prefer reporting the more
        // specific case).
        if (RegExp(r'>>(?!>)').hasMatch(span) ||
            RegExp(r'>(?![>])').hasMatch(span)) {
          return (name: name, shape: NearMissShape.malformedClose);
        }
        continue;
      }
      // Unknown name. Only count as `unknownTool` when the close
      // is well-formed (`>>>`) AND the call shape includes a
      // colon-args separator OR an immediate close — i.e., it
      // *looks* like a tool invocation, not a stray template
      // placeholder like `<<<API_KEY_HERE>>>` which models
      // sometimes emit in code samples. The `tripleOpenRe` itself
      // doesn't enforce this, so we re-check the trailing chars
      // here.
      if (!hasProperClose) continue;
      // Discard the `>>>` and everything after; what remains in
      // `span` is the trailing chars after the tool name. Valid
      // tool-call shapes leave either a colon (args) or a `>`
      // (immediate close, no args) here.
      final closeIdx = span.indexOf('>>>');
      final between = span.substring(0, closeIdx);
      final looksLikeCall = between.startsWith(':') ||
          between.startsWith(' :') ||
          between.startsWith('>') ||
          between.isEmpty; // `<<<NAME>>>` no-arg shape
      if (!looksLikeCall) continue;
      return (name: name, shape: NearMissShape.unknownTool);
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
      r'\b(?:Created|Wrote|Added|Edited|Updated|Modified|Saved|Copied)\b'
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
