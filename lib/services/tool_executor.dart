import 'timeline_recorder.dart';
import 'tool_registry.dart';

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

  /// Base64-encoded images produced by tools during this pass. The chat
  /// loop forwards them as `images:` on the next user-feedback message
  /// so the multimodal model can react to them on the next turn.
  final List<String> imageAttachments;

  /// Tools that actually executed during this pass (in source order).
  /// Read by `ChatController.sendMessage` to build a deterministic
  /// summary line for the per-chat tasks.md.
  final List<FiredTool> firedTools;

  ToolPassResult(
    this.processedResponse,
    this.hasToolCalls,
    this.toolFeedback, {
    List<String> imageAttachments = const [],
    List<FiredTool> firedTools = const [],
  }) : imageAttachments = List.unmodifiable(imageAttachments),
       firedTools = List.unmodifiable(firedTools);
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

  ToolExecutor({
    required this.workspaceDir,
    required this.approver,
    Set<String>? enabledTools,
    this.onToolOutput,
    this.recorder,
    this.allowWritesOutsideWorkspace = false,
  }) : enabledTools =
           enabledTools ??
           ToolRegistry.all
               .where((t) => t.defaultEnabled)
               .map((t) => t.id)
               .toSet();

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
    final attachments = <String>[];
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
          attachImage: attachments.add,
          allowWritesOutsideWorkspace: allowWritesOutsideWorkspace,
          onOutput: onToolOutput,
        );
        // Pre-snapshot the file the tool will touch (if any). Cheap —
        // when the file already has a baseline / head this is a no-op;
        // when it doesn't, we ensure one exists so the post-snapshot
        // has something to diff against. Errors are swallowed by the
        // recorder; capture failures must never break tool dispatch.
        await recorder?.beforeTool(tool, raw);
        final result = await tool.execute(inv);
        feedback.writeln(result);
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

    return ToolPassResult(
      processed,
      hasToolCalls,
      feedback.toString(),
      imageAttachments: attachments,
      firedTools: fired,
    );
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
  /// Format: `<!-- LUMEN_TOOL:<id>|<percent-encoded-arg>|<status> -->`
  /// where `status` is `ok` or `err`. We surround with `\n` so the
  /// marker forms its own paragraph in markdown — the chat-side
  /// parser splits on this, rendering prose as `MarkdownBody` and
  /// markers as widgets.
  String _friendlyReplacement(AgentTool tool, Match m, String rawResult) {
    final isError =
        rawResult.contains('Error:') ||
        rawResult.contains('Failed') ||
        rawResult.contains('Denied');
    // Most tools use capture group 1 as the relevant target. MOVE_FILE is the
    // exception: group 1 is the source and group 2 is the destination. If we
    // only encode the source, the chat card tries to open the old path after a
    // successful move and appears "not clickable" because the file no longer
    // exists. Preserve both sides so the UI can display/open the destination.
    final firstArg = tool.id == 'move_file' && m.groupCount >= 2
        ? '${m.group(1) ?? ''} -> ${m.group(2) ?? ''}'
        : ((m.groupCount >= 1 ? m.group(1) : '') ?? '');
    final encoded = Uri.encodeComponent(firstArg);
    final status = isError ? 'err' : 'ok';
    return '\n<!-- LUMEN_TOOL:${tool.id}|$encoded|$status -->\n';
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
      case 'append_file':
        return '(Appended to: `$firstArg`)';
      case 'move_file':
        return '(Moved: `$firstArg`)';
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
      case 'snapshot_url':
        return '(Snapshot: `$firstArg`)';
    }
    return '($toolId `$firstArg`)';
  }
}
