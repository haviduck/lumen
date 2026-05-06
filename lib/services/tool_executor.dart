import 'ollama_service.dart' show CancellationToken;
import 'timeline_recorder.dart';
import 'tool_registry.dart';
import 'tools/tool_match_adapter.dart';
import 'tools/tool_schemas.dart';

/// `(tool id, first regex capture group)` for one tool invocation. The
/// chat controller uses this to build a per-turn entry in the
/// `<chat-id>.tasks.md` log so the model can see what was already
/// done in prior turns. First-arg is usually the relevant target —
/// file path for edit/read tools, query for search tools, command
/// for run_cmd, etc. Good enough for "what happened here" without
/// embedding entire payloads.
class FiredTool {
  final String id;
  final String firstArg;
  const FiredTool({required this.id, required this.firstArg});
}

/// Output of a single executor pass.
class ToolPassResult {
  final String processedResponse;
  final bool hasToolCalls;
  final String toolFeedback;

  /// Tools that actually executed during this pass (in source order).
  /// Read by `ChatController.sendMessage` to build a deterministic
  /// summary line for the per-chat tasks.md.
  final List<FiredTool> firedTools;

  ToolPassResult(
    this.processedResponse,
    this.hasToolCalls,
    this.toolFeedback, {
    List<FiredTool> firedTools = const [],
  }) : firedTools = List.unmodifiable(firedTools);
}

/// Walks the LLM response, looks for tool-call patterns, executes them,
/// and returns the cleaned response plus aggregated feedback to send back
/// to the model.
class ToolExecutor {
  String? workspaceDir;
  Set<String> enabledTools;

  /// Approver receives the tool id alongside label + detail so the
  /// approval surface can register a per-tool blanket "Always allow"
  /// without flipping the global auto-approve. The 3-arg shape is
  /// the executor-side API; downstream `ToolInvocation.approver`
  /// stays at 2-args (`label`, `detail`) — see `run()` below for
  /// where we wrap to inject `tool.id`.
  Future<bool> Function(String toolId, String label, String detail) approver;

  /// Optional callback for live output from long-running tools (e.g.
  /// RUN_CMD). The chat controller uses this to push incremental output
  /// into the streaming content so the user sees what commands are doing.
  void Function(String chunk)? onToolOutput;

  /// Optional bridge to the per-workspace file revision timeline.
  /// When provided, every file-touching tool fires a pre-snapshot
  /// (so the diff view has a "before") and a post-snapshot (carrying
  /// the chat correlation IDs the controller has set on the timeline
  /// service ambient context). See `timeline_recorder.dart` for the
  /// id-mapping rules; the recorder is intentionally optional so
  /// non-IDE callers (tests, scripts, …) can run the executor
  /// without forcing a timeline mount.
  TimelineRecorder? recorder;
  bool allowWritesOutsideWorkspace;

  /// Optional cancel handle propagated to every [ToolInvocation] this
  /// executor builds. RUN_CMD (and any future long-running tool body)
  /// uses it to abort a hung subprocess when the user clicks Stop.
  CancellationToken? cancelToken;

  /// Optional launcher that routes `RUN_CMD` through the agent
  /// terminal-pane bridge. When supplied, long-running commands
  /// (dev servers, watchers) appear as real terminal tabs the user
  /// can see and kill. When omitted, `RUN_CMD` runs through the
  /// legacy `Process.start` path. Production wiring in
  /// `ChatController._runGenerationLoop` always supplies one.
  AgentTerminalLauncher? agentTerminalLauncher;

  /// Optional bridge to Ollama Cloud's web search endpoint, plumbed
  /// down to every `ToolInvocation` for the `WEB_SEARCH` tool. When
  /// null, `WEB_SEARCH` returns a configuration-error feedback
  /// string (caller should set the Ollama Cloud API key in
  /// Settings → AI / Chat).
  WebSearchFn? webSearch;

  /// Optional bridge to Ollama Cloud's web fetch endpoint. Same
  /// null semantics as [webSearch] — without a wired closure the
  /// `WEB_FETCH` tool fails closed rather than reaching out
  /// directly to arbitrary URLs from the host process.
  WebFetchFn? webFetch;

  /// Per-message random hex token baked into every
  /// `<!-- LUMEN_TOOL:... -->` marker emitted by `_friendlyReplacement`
  /// and `_SalvageOutcome.from`. The chat-side renderer validates
  /// each marker's trailing nonce against the message's stored
  /// `toolMarkerNonce`; markers with a missing or mismatching
  /// nonce are treated as model-emitted impersonation and
  /// stripped from the rendered output.
  ///
  /// Set by `ChatController._runGenerationLoop` at the start of
  /// every assistant turn (fresh value per turn) and cleared
  /// between turns. `null` means "do not nonce-bind" — useful for
  /// non-chat invocations of the executor (none today, but the
  /// API stays usable in tests / scripts without forcing a
  /// nonce).
  String? markerNonce;

  ToolExecutor({
    required this.workspaceDir,
    required this.approver,
    Set<String>? enabledTools,
    this.onToolOutput,
    this.recorder,
    this.allowWritesOutsideWorkspace = false,
    this.cancelToken,
    this.agentTerminalLauncher,
    this.webSearch,
    this.webFetch,
  }) : enabledTools =
           enabledTools ??
           ToolRegistry.all
               .where((t) => t.defaultEnabled)
               .map((t) => t.id)
               .toSet();

  /// Dispatch a single native tool call (provider emitted a
  /// structured `tool_use` / `function_call` block instead of a
  /// `<<<TOOL>>>` text grammar).
  ///
  /// Translates the parsed JSON args back into the [Match] shape
  /// that existing tool bodies expect, dispatches through
  /// [AgentTool.execute], and returns a [ToolPassResult] in the
  /// same shape as [run] so the chat controller's iteration loop
  /// can consume both paths uniformly.
  ///
  /// Why route through a synthesized Match rather than a parallel
  /// `executeFromArgs(Map)` on each tool: roughly 25 tool bodies
  /// would each need a duplicate JSON-aware adapter inside them,
  /// for zero behavioural difference. The bridge through
  /// [SyntheticMatch] preserves tool implementations as the
  /// single source of truth and keeps the diff for native-tools
  /// support contained to the executor + provider services.
  Future<ToolPassResult> runNativeToolCall({
    required String toolId,
    required Map<String, dynamic> args,
  }) async {
    if (!enabledTools.contains(toolId)) {
      // The model called a tool the user has disabled. Surface a
      // failure feedback line — the controller's loop can decide
      // whether to nudge the model or surface a chat warning.
      return ToolPassResult(
        '',
        true,
        '[FAILED] $toolId: tool is disabled in this workspace.\n'
        '! action required: re-prompt without this tool, or enable '
        'it in Settings → Tools.\n',
      );
    }
    final tool = ToolRegistry.byId(toolId);
    final schema = ToolSchemas.byId(toolId);
    if (tool == null || schema == null) {
      return ToolPassResult(
        '',
        true,
        '[FAILED] $toolId: unknown tool. Native tool dispatch could '
        'not find a registered implementation.\n',
      );
    }
    final match = ToolSchemas.matchFor(schema, args);
    final inv = ToolInvocation(
      match: match,
      workspaceDir: workspaceDir,
      approver: (label, detail) => approver(tool.id, label, detail),
      allowWritesOutsideWorkspace: allowWritesOutsideWorkspace,
      onOutput: onToolOutput,
      cancelToken: cancelToken,
      agentTerminalLauncher: agentTerminalLauncher,
      webSearch: webSearch,
      webFetch: webFetch,
    );
    // Recorder pre/post — same contract as the text-grammar path.
    // The recorder's by-tool snapshotting reads from `inv.match.group(N)`
    // which the synthetic match provides.
    await recorder?.beforeTool(tool, match);
    final result = await tool.execute(inv);
    await recorder?.afterTool(tool, match, result);
    final isFailure = _looksLikeFailure(result);
    final feedbackBuf = StringBuffer();
    if (isFailure) {
      feedbackBuf.writeln('[FAILED] $result');
      feedbackBuf.writeln(
        '! action required: the tool above did NOT execute. Either '
        'fix the call (re-read the file with read_file:start_line/end_line '
        'so your search matches exactly) or tell the user why this '
        "can't be done.",
      );
    } else {
      feedbackBuf.writeln(result);
    }
    final firstArg =
        match.groupCount >= 1 ? (match.group(1) ?? '') : '';
    final friendly = _friendlyReplacement(tool, match, result);
    final fired = <FiredTool>[FiredTool(id: tool.id, firstArg: firstArg)];
    return ToolPassResult(
      friendly,
      true,
      feedbackBuf.toString(),
      firedTools: fired,
    );
  }

  Future<ToolPassResult> run(String response) async {
    // **Normalize** the LLM output before regex matching to absorb
    // common quirks from smaller / quantized models (gemma:e31b is
    // the bug report that triggered this) which sometimes emit
    // tool-call markup that *looks* identical to the user but
    // doesn't match our patterns:
    //   - HTML-encoded angle brackets (`&lt;&lt;&lt;RUN_CMD: ...&gt;&gt;&gt;`)
    //     — markdown decodes these so the chat shows `<<<...>>>`
    //     but the executor sees `&lt;...&gt;`.
    //   - Zero-width characters (ZWSP / ZWNJ / ZWJ / BOM) inserted
    //     between the bracket runs and the tool name.
    //   - Unicode bracket lookalikes («« »» ❮❮ ❯❯) that render
    //     visually similar to `<<<`.
    //
    // We normalize `processed` BUT also re-do replaceAll using the
    // matched span from the *normalized* text — `processed` is what
    // the user ultimately sees, so it must agree with what we
    // actually executed.
    final normalized = _normalizeForToolMatching(response);

    String processed = normalized;
    bool hasToolCalls = false;
    final feedback = StringBuffer();
    final fired = <FiredTool>[];

    for (final tool in ToolRegistry.all) {
      if (!enabledTools.contains(tool.id)) continue;
      final matches = tool.pattern.allMatches(normalized).toList();
      for (final raw in matches) {
        hasToolCalls = true;
        final inv = ToolInvocation(
          match: raw,
          workspaceDir: workspaceDir,
          // Bake the current tool's id into the 2-arg
          // `ToolInvocation.approver` so individual `AgentTool.execute`
          // bodies don't need to know about the per-tool approval
          // mechanism — they just call `inv.approver(label, detail)`
          // exactly like before.
          approver: (label, detail) => approver(tool.id, label, detail),
          allowWritesOutsideWorkspace: allowWritesOutsideWorkspace,
          onOutput: onToolOutput,
          cancelToken: cancelToken,
          agentTerminalLauncher: agentTerminalLauncher,
          webSearch: webSearch,
          webFetch: webFetch,
        );
        // Pre-snapshot the file the tool will touch (if any). Cheap —
        // when the file already has a baseline / head this is a no-op;
        // when it doesn't, we ensure one exists so the post-snapshot
        // has something to diff against. Errors are swallowed by the
        // recorder; capture failures must never break tool dispatch.
        await recorder?.beforeTool(tool, raw);
        final result = await tool.execute(inv);
        // Make failures impossible to gloss over. We've observed
        // models (Gemma cloud especially) reading a tool_result that
        // says `EDIT_FILE foo.scss: Error: SEARCH block not found`
        // and then claiming success in the next message. Wrapping
        // failed lines in `[FAILED]` and a `! action required`
        // suffix makes the failure structurally distinct from
        // success lines that might sit next to it in the same
        // result batch.
        final isFailure = _looksLikeFailure(result);
        if (isFailure) {
          feedback.writeln('[FAILED] $result');
          feedback.writeln(
            '! action required: the tool above did NOT execute. Do '
            'not claim it succeeded. Either fix the call (re-read '
            'the file with `READ_FILE: file:start-end` so your '
            'SEARCH block matches exactly) or tell the user why '
            'this can\'t be done.',
          );
        } else {
          feedback.writeln(result);
        }
        // Post-snapshot. Tagged with the chat correlation IDs the
        // controller set on `TimelineService` before this pass —
        // i.e. (sessionId, turnId, messageId) — so the future
        // "click chat message → revert" feature has every agent-
        // origin entry already grouped per turn.
        await recorder?.afterTool(tool, raw, result);

        final firstArg = (raw.groupCount >= 1 ? raw.group(1) : '') ?? '';
        fired.add(FiredTool(id: tool.id, firstArg: firstArg));

        final friendly = _friendlyReplacement(tool, raw, result);
        processed = processed.replaceAll(raw.group(0)!, friendly);
      }
    }

    // **Salvage pass for malformed blocks.** Catches `<<<EDIT_FILE…>>>
    // …<<<END_EDIT>>>` (and friends) where the strict per-tool regex
    // (post-relaxed-separators) STILL rejected the inner structure
    // — typically because SEARCH or REPLACE markers are missing
    // entirely or are spelled differently. Without this, the raw
    // body would leak as prose. Replacing with a `malformed`
    // marker mirrors the streaming-side preview so the chat surface
    // stays consistent before vs. after the executor runs.
    //
    // **Auto-retry contract:** when salvage replaces anything we
    // (a) flip `hasToolCalls = true` so the chat loop runs another
    // iteration and (b) push a corrective-syntax feedback line
    // into `pass.toolFeedback` per malformed block. The model gets
    // told exactly what shape was missing and the canonical example
    // it should have followed — small models recover on the second
    // round once they see the right syntax instead of the void.
    final salvage = _SalvageOutcome.from(processed, markerNonce: markerNonce);
    processed = salvage.cleanedContent;
    if (salvage.malformedCount > 0) {
      hasToolCalls = true;
      feedback.write(salvage.feedback);
    }

    return ToolPassResult(
      processed,
      hasToolCalls,
      feedback.toString(),
      firedTools: fired,
    );
  }

  static String? _toolIdForName(String toolName) {
    for (final tool in ToolRegistry.all) {
      if (tool.name == toolName) return tool.id;
    }
    return null;
  }

  /// True when a tool's textual result represents a non-successful
  /// outcome. Mirrors `_friendlyReplacement`'s status detection so a
  /// row's chat-card status and its `<tool_result>` framing always
  /// agree. Conservative — only triggers on the explicit error words
  /// our tool bodies emit (`Error:`, `Failed`, `Denied`), so a
  /// stdout that happens to contain "error" in passing isn't tagged.
  static bool _looksLikeFailure(String result) {
    return result.contains('Error:') ||
        result.contains('Failed') ||
        result.contains('Denied');
  }

  /// Pre-pass that normalizes a chunk of LLM output so the
  /// existing tool-pattern regexes have a fighting chance against
  /// quirky model output. **Conservative** — only undoes
  /// transformations that are safe and don't change semantics:
  ///
  /// 1. HTML entities for the angle brackets (`&lt;`, `&gt;`, `&amp;`).
  ///    Common when the model is trained on HTML-escaped corpora.
  /// 2. Zero-width Unicode noise (ZWSP, ZWNJ, ZWJ, BOM). Some models
  ///    insert these between tokens for reasons unclear; they're
  ///    invisible in chat but break literal regex matching.
  /// 3. Unicode bracket lookalikes mapped to ASCII `<` / `>`. We
  ///    only map the obvious ones (« » ❮ ❯ ＜ ＞ 〈 〉) — anything
  ///    rarer requires a real bug report.
  ///
  /// We don't decode `&quot;` or `&#39;` because legitimate user
  /// content (e.g. inside a CREATE_FILE body) might contain them
  /// intentionally and decoding would corrupt the file.
  static String _normalizeForToolMatching(String input) {
    var s = input;
    // (1) HTML entities for our bracket characters.
    s = s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&amp;', '&');
    // (2) Zero-width / BOM characters.
    s = s.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
    // (3) Unicode angle-bracket lookalikes that render like `<<<`/`>>>`.
    //     Map each to its ASCII equivalent. List is intentionally
    //     short — only tested visual confusables.
    const angleMap = {
      '\u00AB': '<', // «
      '\u00BB': '>', // »
      '\u276E': '<', // ❮
      '\u276F': '>', // ❯
      '\uFF1C': '<', // ＜ fullwidth
      '\uFF1E': '>', // ＞ fullwidth
      '\u2329': '<', // 〈
      '\u232A': '>', // 〉
      '\u3008': '<', // 〈 CJK
      '\u3009': '>', // 〉 CJK
    };
    angleMap.forEach((from, to) {
      s = s.replaceAll(from, to);
    });
    return s;
  }

  /// Build the structured marker the chat panel detects and replaces
  /// with a tool card / badge. HTML-comment syntax was picked because:
  ///   - Markdown silently ignores `<!-- ... -->` so if our parser
  ///     ever fails the user sees nothing (preferred over leaked
  ///     custom-syntax tokens like `[[lumen-tool:...]]`).
  ///   - It's regex-parseable in one pass, no nested-scope concerns.
  ///   - `Uri.encodeComponent` on the arg keeps `|` / `-->` from
  ///     colliding with the field separator / comment terminator.
  ///
  /// Format: `<!-- LUMEN_TOOL:<id>|<percent-encoded-arg>|<status>|<nonce> -->`
  /// where `status` is `ok`, `err`, `pending`, or `malformed` and
  /// `<nonce>` is the per-message random token from [markerNonce]
  /// (omitted entirely when `markerNonce` is null, preserving the
  /// pre-binding marker shape for backwards-compat callers and
  /// tests). We surround with `\n` so the marker forms its own
  /// paragraph in markdown — the chat-side parser splits on this,
  /// rendering prose as `MarkdownBody` and markers as widgets.
  ///
  /// **Why the trailing nonce field?** Renderer-side validation —
  /// see `tool_segments.dart::parseChatSegments` and
  /// `PersistedMessage.toolMarkerNonce` for the full rationale.
  /// Short version: when a model emits a fake `<!-- LUMEN_TOOL:... -->`
  /// in its own output (mimicking what it sees in conversation
  /// history), the fake marker has no way of carrying the right
  /// nonce, so the renderer can distinguish "marker the executor
  /// wrote because a real tool ran" from "marker the model wrote
  /// because it pattern-matched the shape from history".
  String _friendlyReplacement(AgentTool tool, Match m, String rawResult) {
    final isError = _looksLikeFailure(rawResult);
    // Most tools use capture group 1 as the relevant target. MOVE_FILE and
    // COPY_FILE are the exceptions: group 1 is the source and group 2 is the
    // destination. If we only encode the source, the chat card tries to open
    // the old path after a successful move (which no longer exists) or the
    // source path after a copy (correct file, but not what the user just
    // asked for). Preserve both sides so the UI can display the arrow grammar
    // and open the destination on click.
    final isArrowTool = tool.id == 'move_file' || tool.id == 'copy_file';
    var firstArg = isArrowTool && m.groupCount >= 2
        ? '${m.group(1) ?? ''} -> ${m.group(2) ?? ''}'
        : ((m.groupCount >= 1 ? m.group(1) : '') ?? '');

    // **Line-range hint** (2026-05). Edit-shaped tools record the
    // touched line range in their success message as ` lines N-M`
    // (or just ` lines N` for a single-line touch). When present
    // and not an error, fold it into the firstArg as a `#L42-58`
    // suffix so the chat-side `_FileToolCard` can render a trailing
    // line-number chip AND pass the range to the editor when the
    // user clicks the row. GitHub URL fragment shape is
    // intentional — it's a familiar `path#Lstart-end` convention
    // and it round-trips cleanly through `Uri.encodeComponent`
    // (the `#` becomes `%23`, decoded back on the other side).
    if (!isError) {
      final range = _extractLineRange(rawResult);
      if (range != null) {
        firstArg = '$firstArg#L$range';
      }
    }
    final encoded = Uri.encodeComponent(firstArg);
    final status = isError ? 'err' : 'ok';
    final nonceField = markerNonce == null ? '' : '|$markerNonce';
    return '\n<!-- LUMEN_TOOL:${tool.id}|$encoded|$status$nonceField -->\n';
  }

  /// Parse the `lines N-M` (or `lines N`) hint each edit-shaped tool
  /// appends to its success message. Returns the canonical chip
  /// string (`'42'` or `'42-58'`) ready to splice into a
  /// `path#L<range>` URL fragment, or `null` when the result has no
  /// such hint (read-only tools, errors, legacy bodies).
  ///
  /// Multi-range success messages (MULTI_EDIT) are summarised by
  /// taking the FIRST range — that's where the user's reading focus
  /// jumps when they click the card. The full list still lives in
  /// the model-facing tool feedback for context.
  static String? _extractLineRange(String rawResult) {
    final m = RegExp(
      r'lines\s+(\d+)(?:\s*-\s*(\d+))?',
      caseSensitive: false,
    ).firstMatch(rawResult);
    if (m == null) return null;
    final start = m.group(1);
    final end = m.group(2);
    if (start == null) return null;
    if (end == null || end == start) return start;
    return '$start-$end';
  }

  /// Companion to `_friendlyReplacement` — used by the message-copy
  /// path and as fallback when marker parsing fails. Mirrors the
  /// original italic-text style this method used to emit, so paste-
  /// to-other-app gives the user readable plain text.
  static String friendlyTextForMarker(String toolId, String firstArg, bool ok) {
    if (!ok) return '($toolId `$firstArg` failed)';
    switch (toolId) {
      case 'create_file':
        return '(Created file: `$firstArg`)';
      case 'edit_file':
        return '(Edited file: `$firstArg`)';
      case 'multi_edit':
        return '(Multi-edited: `$firstArg`)';
      case 'edit_range':
        return '(Edited range: `$firstArg`)';
      case 'append_file':
        return '(Appended to: `$firstArg`)';
      case 'move_file':
        return '(Moved: `$firstArg`)';
      case 'copy_file':
        return '(Copied: `$firstArg`)';
      case 'read_file':
        return '(Read: `$firstArg`)';
      case 'read_file_range':
        return '(Read range: `$firstArg`)';
      case 'list_dir':
        return '(Listed: `$firstArg`)';
      case 'tree':
        return '(Tree: `$firstArg`)';
      case 'search_text':
        return '(Searched: `$firstArg`)';
      case 'find_file':
        return '(Found: `$firstArg`)';
      case 'glob':
        return '(Glob: `$firstArg`)';
      case 'delete_file':
        return '(Deleted: `$firstArg`)';
      case 'git_status':
        return '(git status)';
      case 'git_diff':
        return '(git diff)';
      case 'run_cmd':
        return '(Ran: `$firstArg`)';
      case 'verify':
        return '(Verified workspace)';
    }
    return '($toolId `$firstArg`)';
  }
}

/// Result of the executor's malformed-block salvage pass.
///
/// - [cleanedContent] is the response with every malformed block
///   replaced by a `<!-- LUMEN_TOOL:…|malformed -->` marker so the
///   chat panel renders the warning chip instead of leaking the
///   raw body.
/// - [malformedCount] is the number of replaced blocks. When > 0
///   the caller flips `hasToolCalls = true` so the chat loop
///   continues for another iteration with the corrective feedback.
/// - [feedback] is the model-facing corrective text — one entry
///   per malformed block, each pulling the canonical syntax
///   straight from `ToolRegistry` so the example never drifts.
///
/// Kept as a value type so `ToolExecutor.run` can fold it back into
/// [ToolPassResult] cleanly without smuggling a half-dozen fields
/// through positional args.
class _SalvageOutcome {
  final String cleanedContent;
  final int malformedCount;
  final String feedback;

  const _SalvageOutcome._(
    this.cleanedContent,
    this.malformedCount,
    this.feedback,
  );

  static _SalvageOutcome from(String content, {String? markerNonce}) {
    final salvage = RegExp(
      r'<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):\s*(.*?)\s*>>>'
      r'(?:.*?)'
      r'<<<END_(?:FILE|EDIT|APPEND)>>>',
      dotAll: true,
    );
    var count = 0;
    final fb = StringBuffer();
    final nonceField = markerNonce == null ? '' : '|$markerNonce';
    final cleaned = content.replaceAllMapped(salvage, (m) {
      final toolName = m.group(1)!;
      final firstArg = (m.group(2) ?? '').trim();
      final id = ToolExecutor._toolIdForName(toolName);
      if (id == null) return m.group(0)!;
      count++;
      final tool = ToolRegistry.byId(id);
      final example = tool?.syntaxExample ?? '<<<$toolName: …>>>';
      fb.writeln(
        '$toolName $firstArg: MALFORMED — the call structure was '
        'rejected by the parser and was NOT executed. Re-issue it '
        'using this exact syntax (mind the newline between every '
        'marker, no extra blank lines, no markdown code fences):\n'
        '$example\n',
      );
      final encoded = Uri.encodeComponent(firstArg);
      return '\n<!-- LUMEN_TOOL:$id|$encoded|malformed$nonceField -->\n';
    });
    return _SalvageOutcome._(cleaned, count, fb.toString());
  }
}
