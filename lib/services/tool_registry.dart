import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'agent_terminal_bridge.dart';
import 'ollama_service.dart' show CancellationToken;
import 'ripgrep_provisioner.dart';

/// Definition of a single agent tool. The agent uses [syntaxExample] in
/// its system prompt and we parse the response with [pattern].
class AgentTool {
  final String id;
  final String name;
  final String description;
  final String syntaxExample;
  final RegExp pattern;
  final bool requiresApproval;
  final bool defaultEnabled;

  /// True when the tool came from a JSON file in the workspace or the global
  /// app-support tools dir. Used by the UI to badge the entry; the executor
  /// itself does not care.
  final bool isExternal;

  /// Returns the textual feedback for the LLM. The runner invokes this with
  /// a [ToolInvocation] that exposes workspace context and an [approver]
  /// for gated tools.
  final Future<String> Function(ToolInvocation inv) execute;

  const AgentTool({
    required this.id,
    required this.name,
    required this.description,
    required this.syntaxExample,
    required this.pattern,
    required this.execute,
    this.requiresApproval = false,
    this.defaultEnabled = true,
    this.isExternal = false,
  });
}

/// Closure used by `RUN_CMD` to spawn an agent command through the
/// terminal-pane bridge (`AgentTerminalBridge.start`). Production wiring
/// in `ChatController._runGenerationLoop` baked in via `tool_executor.dart`;
/// tests / non-IDE callers can omit it and `RUN_CMD` falls back to its
/// legacy `Process.start` path. The closure shape lives here so
/// `tool_registry.dart` doesn't have to import widget code transitively.
typedef AgentTerminalLauncher = Future<AgentRunHandle> Function({
  required String command,
  required String workingDirectory,
  void Function(String stripped)? onOutput,
});

/// Closures used by `WEB_SEARCH` / `WEB_FETCH` to reach Ollama Cloud's
/// web tooling (`POST /api/web_search`, `POST /api/web_fetch`). Wired
/// from `ChatController._runGenerationLoop` so the registry doesn't
/// have to depend on `OllamaService` directly — tests / non-IDE
/// callers can leave these null and the tools will report a
/// configuration error instead of erroring out at the import.
typedef WebSearchFn =
    Future<Map<String, dynamic>> Function(String query, {int maxResults});
typedef WebFetchFn = Future<Map<String, dynamic>> Function(String url);

class ToolInvocation {
  final RegExpMatch match;
  final String? workspaceDir;
  final Future<bool> Function(String label, String detail) approver;
  final bool allowWritesOutsideWorkspace;

  /// Optional callback for live output from long-running tools. When set,
  /// the tool can push incremental chunks (stdout/stderr lines) as they
  /// arrive, so the UI shows progress in real time.
  final void Function(String chunk)? onOutput;

  /// Optional cancellation handle. Long-running tool bodies (RUN_CMD)
  /// race their work against [CancellationToken.whenCancelled] so the
  /// chat's "Stop" button can interrupt a hung subprocess. Without
  /// this the executor's `await tool.execute(inv)` blocks forever
  /// when a server command never closes its stdout (`npm start`,
  /// `vite dev`, …) and the user has no way out short of killing
  /// the whole IDE.
  final CancellationToken? cancelToken;

  /// Optional launcher that routes `RUN_CMD` through the agent
  /// terminal bridge so long-running commands surface as real
  /// terminal-pane tabs the user can see and kill. When null,
  /// `RUN_CMD` falls back to its legacy `Process.start` path
  /// (which orphans detached processes — see `RUN_CMD`'s body
  /// for the long history of why).
  final AgentTerminalLauncher? agentTerminalLauncher;

  /// Optional bridge to Ollama Cloud's web search endpoint
  /// (https://docs.ollama.com/capabilities/web-search). Used by the
  /// `WEB_SEARCH` tool. When null, the tool returns a configuration
  /// error pointing the user at Settings → AI / Chat → Ollama
  /// Cloud API key.
  final WebSearchFn? webSearch;

  /// Optional bridge to Ollama Cloud's web fetch endpoint
  /// (https://docs.ollama.com/capabilities/web-search#web-fetch-api).
  /// Used by the `WEB_FETCH` tool. Same null semantics as
  /// [webSearch] — without a wired closure the tool reports a
  /// configuration error rather than crashing.
  final WebFetchFn? webFetch;

  ToolInvocation({
    required this.match,
    required this.workspaceDir,
    required this.approver,
    this.allowWritesOutsideWorkspace = false,
    this.onOutput,
    this.cancelToken,
    this.agentTerminalLauncher,
    this.webSearch,
    this.webFetch,
  });
}

/// All tools available to the agent. Built-ins are declared statically;
/// runtime tools come from JSON files via [ExternalToolLoader].
///
/// Order matters for matching — most specific patterns are declared first
/// (e.g. CREATE_FILE before READ_FILE because both contain "_FILE").
class ToolRegistry {
  ToolRegistry._();

  /// READ_FILE caps. The line-and-byte caps protect the model's context
  /// window when it reads a large file without specifying a range; the
  /// truncation footer points it at the line range to use for the rest.
  /// `_kReadMaxFileBytes` is the hard ceiling — even with a range we
  /// refuse to load files larger than this through READ_FILE; the model
  /// should reach for SEARCH_TEXT / GLOB / RUN_CMD instead.
  static const int _kReadMaxLines = 2000;
  static const int _kReadMaxBytes = 200 * 1024;
  static const int _kReadMaxFileBytes = 5 * 1024 * 1024;

  /// Width used to right-pad line numbers in READ_FILE output. 6 covers
  /// up to 999,999 lines and matches the convention most models have
  /// seen in tool output elsewhere — switching widths confuses smaller
  /// models that key off the column for `LINE|content` parsing.
  static const int _kLineNoPad = 6;

  /// Format a slice of file lines as `   42|content` so the model can
  /// reference exact line numbers in EDIT_FILE SEARCH blocks. The
  /// numbers are metadata — the model is expected to strip the
  /// `<num>|` prefix before composing a SEARCH block. EDIT_FILE's
  /// "SEARCH block must match the file exactly" rule still applies to
  /// the actual file content, not the numbered display.
  static String _formatNumbered(List<String> lines, int firstLineNo) {
    final buf = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      buf
        ..write((firstLineNo + i).toString().padLeft(_kLineNoPad))
        ..write('|')
        ..writeln(lines[i]);
    }
    // Trim the trailing newline writeln just added so the caller can
    // append its own footer cleanly without a blank line.
    final s = buf.toString();
    return s.endsWith('\n') ? s.substring(0, s.length - 1) : s;
  }

  /// Stream-based range read. Reads the file line-by-line via
  /// `openRead().transform(LineSplitter())` and only emits lines
  /// inside `[start, end]`. Memory footprint is one decoded chunk at
  /// a time — works on a 9 GiB log the same as a 9 KiB source.
  ///
  /// Output caps are still enforced: at most [_kReadMaxLines] lines
  /// and [_kReadMaxBytes] bytes are emitted, even if the model asked
  /// for more. A truncation footer names the next call to fetch the
  /// remainder. This stops a wild `:1-99999999` from blowing the
  /// context window even though the underlying read is bounded.
  ///
  /// Returns the same `READ_FILE <fileName> lines X-Y:\n<body>`
  /// shape the full-read path uses so the model parses both
  /// uniformly.
  static Future<String> _streamReadRange({
    required String filePath,
    required String fileName,
    required int start,
    required int end,
    required int fileBytes,
  }) async {
    // Hard ceiling for range reads. Way above any realistic source
    // file or even most logs; exists to refuse a `:1-1` on a 50 GiB
    // VM disk image rather than spending a minute scanning to line 1.
    const int rangeFileCeilingBytes = 500 * 1024 * 1024;
    if (fileBytes > rangeFileCeilingBytes) {
      final mib = (fileBytes / (1024 * 1024)).toStringAsFixed(1);
      return 'READ_FILE $fileName: Error: file is $mib MiB '
          '(range-read ceiling 500 MiB). Use SEARCH_TEXT for content '
          'lookup or RUN_CMD with `head` / `tail` for a slice.';
    }

    final wantSize = end - start + 1;
    // We never emit more than [_kReadMaxLines]; if the model asked
    // for more, cap the emission window and tell them in the footer.
    final emitMax = wantSize > _kReadMaxLines ? _kReadMaxLines : wantSize;
    final emitEndLine = start + emitMax - 1;

    final buf = StringBuffer();
    var byteBudget = _kReadMaxBytes;
    var lineNo = 0;
    var emitted = 0;
    var byteCapHit = false;

    try {
      final stream = File(filePath)
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in stream) {
        lineNo++;
        if (lineNo < start) continue;
        if (lineNo > emitEndLine) break;
        // +1 newline + a few bytes for the `<num>|` prefix. Conservative
        // — the cap is a guardrail, not an exact accounting.
        final cost = line.length + _kLineNoPad + 2;
        if (cost > byteBudget) {
          byteCapHit = true;
          break;
        }
        byteBudget -= cost;
        buf
          ..write(lineNo.toString().padLeft(_kLineNoPad))
          ..write('|')
          ..writeln(line);
        emitted++;
      }
    } on FormatException {
      return 'READ_FILE $fileName: Error: file is not valid UTF-8 '
          '(likely binary). READ_FILE only handles text.';
    } catch (e) {
      return 'READ_FILE $fileName: Error: $e';
    }

    if (emitted == 0) {
      // Either the file is shorter than `start`, or the requested
      // range is past EOF, or the very first line in the range
      // already busted the byte cap.
      if (byteCapHit) {
        return 'READ_FILE $fileName: Error: line $start exceeds the '
            '${_kReadMaxBytes ~/ 1024} KiB display cap. The line is too '
            'long for inline display — use SEARCH_TEXT for targeted '
            'lookup or RUN_CMD with `head -c` / `Get-Content -TotalCount` '
            'to slice within the line.';
      }
      return 'READ_FILE $fileName: Empty range (file has $lineNo line'
          '${lineNo == 1 ? '' : 's'}; requested $start-$end is past EOF).';
    }

    // Strip the trailing newline writeln just added so the footer (if
    // any) doesn't introduce a blank line.
    var body = buf.toString();
    if (body.endsWith('\n')) {
      body = body.substring(0, body.length - 1);
    }
    final lastEmittedLine = start + emitted - 1;
    final hitCap = byteCapHit || (emitted >= emitMax && lastEmittedLine < end);
    if (hitCap) {
      final reason = byteCapHit
          ? 'byte cap (${_kReadMaxBytes ~/ 1024} KiB)'
          : 'line cap ($_kReadMaxLines)';
      return 'READ_FILE $fileName lines $start-$lastEmittedLine '
          '(requested $start-$end, capped at $reason):\n'
          '$body\n'
          '... (continue with '
          '`<<<READ_FILE: $fileName:${lastEmittedLine + 1}-$end>>>`)';
    }
    return 'READ_FILE $fileName lines $start-$lastEmittedLine:\n$body';
  }

  static String? _resolvePath(
    ToolInvocation inv,
    String rawPath, {
    required bool forWrite,
  }) {
    final workspace = inv.workspaceDir;
    if (workspace == null) return null;
    final resolved = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(workspace, rawPath),
    );
    if (!forWrite || inv.allowWritesOutsideWorkspace) return resolved;
    final root = p.normalize(workspace);
    if (p.equals(resolved, root) || p.isWithin(root, resolved)) {
      return resolved;
    }
    return null;
  }

  static String _outsideWorkspaceBlocked(String toolName, String path) {
    return '$toolName $path: Error: writing outside the active workspace is '
        'blocked by Settings → Rules → Allow agent writes outside workspace.';
  }

  static final List<AgentTool> _builtin = [
    AgentTool(
      id: 'create_file',
      name: 'CREATE_FILE',
      description:
          'Create a NEW file with the given content. **Refuses to '
          'overwrite an existing file** — for edits use EDIT_FILE or '
          'MULTI_EDIT (rewriting a 200-line file with CREATE_FILE '
          'costs minutes of generation per turn and silently drops '
          'content). To intentionally replace an existing file, '
          'append the suffix `:overwrite` to the filename, e.g. '
          '`<<<CREATE_FILE: foo.dart:overwrite>>>`.',
      syntaxExample:
          '<<<CREATE_FILE: filename.ext>>>\nfile contents go here\n<<<END_FILE>>>',
      // Tolerant separator: `\s*?\n` between the opener and the body
      // accepts CRLF, blank lines, and indented markers. The content
      // capture itself stays bounded by `\n?<<<END_FILE>>>` so a
      // body's trailing newline isn't silently stripped.
      pattern: RegExp(
        r'<<<CREATE_FILE:\s*(.*?)\s*>>>\s*?\n(.*?)\n?\s*?<<<END_FILE>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        var fileName = inv.match.group(1)!;
        final content = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'CREATE_FILE $fileName: Failed (no workspace open).';
        }
        // `:overwrite` opt-in flag. We strip it here so the rest of
        // the path-resolution code sees a clean filename. The flag
        // exists deliberately as a friction point — see the description
        // and the May 2026 knowledgebase entry on CREATE_FILE
        // misuse. Don't loosen this without re-reading those notes.
        var overwrite = false;
        if (fileName.endsWith(':overwrite')) {
          overwrite = true;
          fileName = fileName.substring(0, fileName.length - ':overwrite'.length).trim();
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('CREATE_FILE', fileName);
        }
        try {
          final f = File(filePath);
          if (await f.exists() && !overwrite) {
            return 'CREATE_FILE $fileName: Error: file already exists. '
                'Use EDIT_FILE / MULTI_EDIT for changes (preserves '
                'surrounding code), or pass `:overwrite` if you '
                'genuinely intend a full rewrite '
                '(`<<<CREATE_FILE: $fileName:overwrite>>>`).';
          }
          await f.parent.create(recursive: true);
          await f.writeAsString(content);
          return overwrite
              ? 'CREATE_FILE $fileName: Success (overwrote existing file)'
              : 'CREATE_FILE $fileName: Success';
        } catch (e) {
          return 'CREATE_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'edit_file',
      name: 'EDIT_FILE',
      description:
          'Edit an existing file by replacing a specific text block with new '
          'content. Safer than CREATE_FILE for targeted edits because it '
          'preserves surrounding code. The SEARCH block must match the file '
          'EXACTLY (including whitespace/indentation) AND uniquely — if the '
          'SEARCH text appears more than once the call FAILS with a '
          'count-of-matches error. Add more surrounding context to '
          'disambiguate, or use MULTI_EDIT to target multiple sites '
          'explicitly.',
      syntaxExample:
          '<<<EDIT_FILE: filename.ext>>>\n<<<SEARCH>>>\nexact text to find\n<<<REPLACE>>>\nreplacement text\n<<<END_EDIT>>>',
      // Tolerant separators between markers (`\s*?\n` accepts CRLF,
      // an extra blank line, or indented markers) but content
      // captures stay anchored by `\n` boundaries so trailing
      // whitespace inside SEARCH / REPLACE bodies isn't stripped —
      // some `EDIT_FILE` calls genuinely need to match a line that
      // ends in spaces. Smaller / quirky models (Nemotron, gemma
      // variants) routinely emit one of these whitespace
      // variations; the strict `\n` requirement turned them all
      // into "malformed" without any benefit.
      pattern: RegExp(
        r'<<<EDIT_FILE:\s*(.*?)\s*>>>\s*?\n\s*?<<<SEARCH>>>\s*?\n'
        r'(.*?)'
        r'\n\s*?<<<REPLACE>>>\s*?\n'
        r'(.*?)'
        r'\n\s*?<<<END_EDIT>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final search = inv.match.group(2)!;
        final replace = inv.match.group(3)!;
        if (inv.workspaceDir == null) {
          return 'EDIT_FILE $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('EDIT_FILE', fileName);
        }
        try {
          final f = File(filePath);
          if (!await f.exists()) {
            return 'EDIT_FILE $fileName: Error: file does not exist.';
          }
          var content = await f.readAsString();
          // Direct match first; fall back to CRLF-normalised content
          // since some editors / OSes write `\r\n` line endings the
          // model didn't include in its SEARCH block.
          var effectiveSearch = search;
          var effectiveContent = content;
          if (!content.contains(search)) {
            final normalizedContent = content.replaceAll('\r\n', '\n');
            final normalizedSearch = search.replaceAll('\r\n', '\n');
            if (normalizedContent.contains(normalizedSearch)) {
              effectiveContent = normalizedContent;
              effectiveSearch = normalizedSearch;
            } else {
              return 'EDIT_FILE $fileName: Error: SEARCH block not found in '
                  'file. Make sure it matches exactly, including whitespace.';
            }
          }
          // **Uniqueness gate.** Multi-match is the silent-wrong-edit
          // failure mode — smaller models read "Success" and stop
          // even if we noted the ambiguity in a parenthetical. Refuse
          // and force the model to add context. MULTI_EDIT remains
          // the explicit multi-site path.
          final occurrences = RegExp(
            RegExp.escape(effectiveSearch),
          ).allMatches(effectiveContent).length;
          if (occurrences > 1) {
            return 'EDIT_FILE $fileName: Error: SEARCH matched $occurrences '
                'places (file unchanged — refusing to guess which one). '
                'Add more surrounding context to make the SEARCH block '
                'uniquely identify ONE site, or use MULTI_EDIT to target '
                'multiple sites explicitly.';
          }
          final result = effectiveContent.replaceFirst(
            effectiveSearch,
            replace,
          );
          // No-op detection. If the SEARCH matched but the REPLACE
          // produced byte-identical content, the model thinks it
          // edited the file but nothing actually changed. Without
          // this branch the model gets back "Success (1 replacement
          // made)" and confidently moves on, only to be confused
          // when a re-read shows the change isn't there. Common
          // failure shape on big files: model copies a line from
          // its READ_FILE output for the SEARCH block, copies the
          // SAME line for the REPLACE block (intending to rewrite
          // it), then fills in the wrong target — or the model
          // mis-typed and SEARCH equals REPLACE verbatim. Skipping
          // the write also avoids the silent CRLF→LF normalisation
          // that would otherwise happen on a no-op via the
          // fallback path above.
          if (result == effectiveContent) {
            return 'EDIT_FILE $fileName: No-op — SEARCH matched but '
                'REPLACE produced byte-identical content (your SEARCH '
                'and REPLACE blocks are effectively the same, OR the '
                'matched region is already in the target state). '
                'File NOT written. Re-read the file, pick a SEARCH '
                'region that actually differs from your REPLACE, '
                'and try again.';
          }
          await f.writeAsString(result);
          return 'EDIT_FILE $fileName: Success (1 replacement made)';
        } catch (e) {
          return 'EDIT_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'multi_edit',
      name: 'MULTI_EDIT',
      description:
          'Apply multiple find-replace edits to a single file in one atomic '
          'pass. All SEARCH blocks must match — if any one fails the file is '
          'left untouched (no partial writes). Use this instead of issuing '
          'several EDIT_FILE calls on the same file in one turn — fewer '
          'round trips, safer transactional semantics.',
      syntaxExample:
          '<<<MULTI_EDIT: filename.ext>>>\n<<<SEARCH>>>\nold text 1\n<<<REPLACE>>>\nnew text 1\n<<<NEXT>>>\n<<<SEARCH>>>\nold text 2\n<<<REPLACE>>>\nnew text 2\n<<<END_EDIT>>>',
      // Outer wrapper is intentionally permissive — the inner
      // SEARCH/REPLACE/NEXT structure is parsed below in `execute`,
      // and the chunk-level regex over there gets the same
      // tolerant-separator treatment.
      pattern: RegExp(
        r'<<<MULTI_EDIT:\s*(.+?)\s*>>>\s*?\n(.*?)\n?\s*?<<<END_EDIT>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final body = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'MULTI_EDIT $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('MULTI_EDIT', fileName);
        }
        try {
          final f = File(filePath);
          if (!await f.exists()) {
            return 'MULTI_EDIT $fileName: Error: file does not exist.';
          }
          // Split on `<<<NEXT>>>` separators; each chunk holds one
          // SEARCH/REPLACE pair. Tolerant of CRLF, blank padding
          // around the `<<<NEXT>>>` marker, and indentation —
          // matches how the outer EDIT_FILE pattern is forgiving.
          final chunks = body.split(RegExp(r'\s*?\n\s*?<<<NEXT>>>\s*?\n\s*?'));
          final edits = <({String search, String replace})>[];
          final chunkRe = RegExp(
            r'<<<SEARCH>>>\s*?\n'
            r'(.*?)'
            r'\n\s*?<<<REPLACE>>>\s*?\n'
            r'(.*?)'
            r'\s*$',
            dotAll: true,
          );
          for (var i = 0; i < chunks.length; i++) {
            final m = chunkRe.firstMatch(chunks[i]);
            if (m == null) {
              return 'MULTI_EDIT $fileName: Error: chunk ${i + 1} malformed '
                  '(expected <<<SEARCH>>> ... <<<REPLACE>>> ...).';
            }
            edits.add((search: m.group(1)!, replace: m.group(2)!));
          }
          if (edits.isEmpty) {
            return 'MULTI_EDIT $fileName: Error: no SEARCH/REPLACE chunks '
                'found in body.';
          }
          // Atomic: apply all edits to an in-memory copy first;
          // only write back if every SEARCH found its match.
          final originalContent = await f.readAsString();
          var content = originalContent;
          for (var i = 0; i < edits.length; i++) {
            final e = edits[i];
            if (content.contains(e.search)) {
              content = content.replaceFirst(e.search, e.replace);
              continue;
            }
            // \r\n vs \n fallback (same trick EDIT_FILE uses).
            final normalizedContent = content.replaceAll('\r\n', '\n');
            final normalizedSearch = e.search.replaceAll('\r\n', '\n');
            if (normalizedContent.contains(normalizedSearch)) {
              content = normalizedContent.replaceFirst(
                normalizedSearch,
                e.replace,
              );
              continue;
            }
            return 'MULTI_EDIT $fileName: Error: edit ${i + 1} SEARCH not '
                'found (file unchanged — no edits applied).';
          }
          // Aggregate no-op detection. Same rationale as EDIT_FILE
          // above: every chunk's SEARCH matched but the cumulative
          // REPLACE content is byte-identical to the file's prior
          // state. Skip the write so a re-read shows the truth
          // (file unchanged) and tell the model what happened
          // instead of letting it move on confidently with
          // "${edits.length} edits applied".
          if (content == originalContent) {
            return 'MULTI_EDIT $fileName: No-op — all ${edits.length} '
                'SEARCH blocks matched, but the resulting file '
                'content is BYTE-IDENTICAL to before. Your '
                'SEARCH/REPLACE pairs cancelled out or were '
                'already in their target state. File NOT written. '
                'Re-read the file and pick edits that actually '
                'change content.';
          }
          await f.writeAsString(content);
          return 'MULTI_EDIT $fileName: Success (${edits.length} edits applied)';
        } catch (e) {
          return 'MULTI_EDIT $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'append_file',
      name: 'APPEND_FILE',
      description:
          'Append content to the end of an existing file. Creates the file if '
          'it does not exist. Useful for adding imports, entries, or log lines '
          'without reading the full file first.',
      syntaxExample:
          '<<<APPEND_FILE: filename.ext>>>\ncontent to append\n<<<END_APPEND>>>',
      pattern: RegExp(
        r'<<<APPEND_FILE:\s*(.*?)\s*>>>\s*?\n(.*?)\n?\s*?<<<END_APPEND>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final content = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'APPEND_FILE $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('APPEND_FILE', fileName);
        }
        try {
          final f = File(filePath);
          await f.parent.create(recursive: true);
          // If the existing file does not end in a newline, prepend
          // one to the appended content so we don't fuse the new
          // text onto the previous last line. Cheap to read the
          // last byte; saves a real corruption class.
          var toWrite = content;
          if (await f.exists()) {
            final raf = await f.open();
            try {
              final len = await raf.length();
              if (len > 0) {
                await raf.setPosition(len - 1);
                final tail = await raf.read(1);
                final lastByte = tail.isEmpty ? -1 : tail[0];
                if (lastByte != 0x0a /* \n */ ) {
                  toWrite = '\n$content';
                }
              }
            } finally {
              await raf.close();
            }
          }
          await f.writeAsString(toWrite, mode: FileMode.append);
          return 'APPEND_FILE $fileName: Success';
        } catch (e) {
          return 'APPEND_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'move_file',
      name: 'MOVE_FILE',
      description:
          'Move or rename a file or directory. Both paths are relative to '
          'the workspace; the destination parent directory is created if '
          'needed. Refuses if the destination already exists (use '
          'DELETE_FILE first if you really mean to clobber).',
      syntaxExample: '<<<MOVE_FILE: old/path.dart -> new/path.dart>>>',
      pattern: RegExp(r'<<<MOVE_FILE:\s*(.+?)\s*->\s*(.+?)\s*>>>'),
      execute: (inv) async {
        final src = inv.match.group(1)!;
        final dst = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'MOVE_FILE $src -> $dst: Failed (no workspace open).';
        }
        final srcPath = _resolvePath(inv, src, forWrite: true);
        final dstPath = _resolvePath(inv, dst, forWrite: true);
        if (srcPath == null) {
          return _outsideWorkspaceBlocked('MOVE_FILE', src);
        }
        if (dstPath == null) {
          return _outsideWorkspaceBlocked('MOVE_FILE', dst);
        }
        try {
          final srcType = await FileSystemEntity.type(srcPath);
          if (srcType == FileSystemEntityType.notFound) {
            return 'MOVE_FILE $src -> $dst: Error: source does not exist.';
          }
          final dstType = await FileSystemEntity.type(dstPath);
          if (dstType != FileSystemEntityType.notFound) {
            return 'MOVE_FILE $src -> $dst: Error: destination already '
                'exists.';
          }
          await Directory(p.dirname(dstPath)).create(recursive: true);
          if (srcType == FileSystemEntityType.directory) {
            await Directory(srcPath).rename(dstPath);
            return 'MOVE_FILE $src -> $dst: Success (directory moved)';
          }
          await File(srcPath).rename(dstPath);
          return 'MOVE_FILE $src -> $dst: Success';
        } catch (e) {
          return 'MOVE_FILE $src -> $dst: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'read_file',
      name: 'READ_FILE',
      description:
          'Read a file relative to the workspace. Output is line-numbered '
          '(format: `<lineNo>|<content>`) so you can reference exact lines '
          'in EDIT_FILE SEARCH blocks — strip the `<num>|` prefix before '
          'building a SEARCH block; the file itself does NOT contain it. '
          'Append `:start-end` to read a 1-based inclusive line range '
          '(ends are clamped, so 1-99999 reads to EOF safely). The '
          'response is always capped at $_kReadMaxLines lines / '
          '${_kReadMaxBytes ~/ 1024} KiB; on truncation a footer tells '
          'you the exact next call to fetch the remainder. **Range '
          'reads stream the file** so they work on arbitrarily large '
          'files — full reads still refuse files larger than '
          '${_kReadMaxFileBytes ~/ (1024 * 1024)} MiB, but a range '
          'like `:48000-48050` on a 9 MiB log just works. The legacy '
          '`<<<READ_FILE_RANGE: file:start-end>>>` syntax is still '
          'accepted but `<<<READ_FILE: file:start-end>>>` is preferred.',
      syntaxExample:
          '<<<READ_FILE: filename.ext>>>\n'
          '    <<<READ_FILE: filename.ext:10-50>>>',
      // Single regex covers four shapes:
      //   <<<READ_FILE: file>>>             — full file (capped)
      //   <<<READ_FILE: file:10-50>>>       — line range
      //   <<<READ_FILE_RANGE: file:10-50>>> — legacy alias
      //   <<<READ_FILE_RANGE: file>>>       — accepted (legacy alias,
      //                                        treated as full file)
      // The optional `:NN-MM` capture is greedy enough that paths
      // containing colons but not a digit-dash-digit suffix still
      // resolve as a full-file read.
      pattern: RegExp(
        r'<<<READ_FILE(?:_RANGE)?:\s*(.+?)(?::(\d+)-(\d+))?\s*>>>',
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final startStr = inv.match.group(2);
        final endStr = inv.match.group(3);
        final hasRange = startStr != null && endStr != null;
        final int? start = hasRange ? int.tryParse(startStr) : null;
        final int? end = hasRange ? int.tryParse(endStr) : null;
        if (inv.workspaceDir == null) {
          return 'READ_FILE $fileName: Failed (no workspace open).';
        }
        if (hasRange) {
          if (start == null || end == null || start < 1 || end < start) {
            return 'READ_FILE $fileName: Error: invalid range '
                '$startStr-$endStr.';
          }
        }
        try {
          final filePath = _resolvePath(inv, fileName, forWrite: false);
          if (filePath == null) {
            return 'READ_FILE $fileName: Failed (no workspace open).';
          }
          final file = File(filePath);
          if (!file.existsSync()) {
            return 'READ_FILE $fileName: Error: file does not exist.';
          }
          final fileBytes = await file.length();

          // Range reads use a streaming reader. We never load the
          // whole file into memory, so the full-read file-size
          // ceiling does NOT apply here. The model can pull
          // `:48000-48050` out of a 9 MiB HTML or a 9 GiB log the
          // same way. The 2000-line / 200 KiB output caps still
          // protect context if the model asks for `:1-9999999`.
          if (hasRange) {
            return await _streamReadRange(
              filePath: filePath,
              fileName: fileName,
              start: start!,
              end: end!,
              fileBytes: fileBytes,
            );
          }

          // Full-read path. Refuse oversized files since the whole
          // body would have to be loaded. The error message names a
          // concrete next call (`:1-2000`) so the model doesn't have
          // to guess that ranges are the escape hatch.
          if (fileBytes > _kReadMaxFileBytes) {
            final mib = (fileBytes / (1024 * 1024)).toStringAsFixed(1);
            return 'READ_FILE $fileName: Error: file is $mib MiB '
                '(full-read limit '
                '${_kReadMaxFileBytes ~/ (1024 * 1024)} MiB). Use a '
                'range like `<<<READ_FILE: $fileName:1-2000>>>` — '
                'range reads stream the file and have no size limit. '
                'For locating content first, `<<<SEARCH_TEXT: pattern '
                ':glob=$fileName>>>`.';
          }
          final List<String> lines;
          try {
            lines = await file.readAsLines();
          } on FormatException {
            return 'READ_FILE $fileName: Error: file is not valid UTF-8 '
                '(likely binary). READ_FILE only handles text.';
          }
          final total = lines.length;
          if (total == 0) {
            return 'READ_FILE $fileName: Empty (0 lines).';
          }

          // Full-file read with line + byte caps. Walk lines until
          // either cap is hit so we never blow the context window.
          var byteBudget = _kReadMaxBytes;
          var taken = 0;
          for (var i = 0; i < total && i < _kReadMaxLines; i++) {
            // +1 for the joining newline. Approximation in chars is fine
            // — the cap is a guardrail, not an exact byte accounting.
            final cost = lines[i].length + 1;
            if (cost > byteBudget) break;
            byteBudget -= cost;
            taken++;
          }
          if (taken == 0) {
            // First line alone exceeds the byte cap (very long minified
            // line). Surface this clearly instead of returning empty.
            return 'READ_FILE $fileName: Error: first line exceeds the '
                '${_kReadMaxBytes ~/ 1024} KiB display cap '
                '(line length: ${lines[0].length}). Use a range like '
                '`<<<READ_FILE: $fileName:1-1>>>` to force the read, or '
                'SEARCH_TEXT for targeted lookup.';
          }
          final slice = lines.sublist(0, taken);
          final numbered = _formatNumbered(slice, 1);
          if (taken < total) {
            final reason = taken >= _kReadMaxLines
                ? 'line cap ($_kReadMaxLines)'
                : 'byte cap (${_kReadMaxBytes ~/ 1024} KiB)';
            return 'READ_FILE $fileName lines 1-$taken (of $total):\n'
                '$numbered\n'
                '... (truncated at $reason; ${total - taken} more '
                'lines. Continue with '
                '`<<<READ_FILE: $fileName:${taken + 1}-$total>>>`)';
          }
          return 'READ_FILE $fileName ($total lines):\n$numbered';
        } catch (e) {
          return 'READ_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'list_dir',
      name: 'LIST_DIR',
      description:
          'List entries in a directory relative to the workspace. Shows file '
          'sizes and marks directories with [DIR].',
      syntaxExample: '<<<LIST_DIR: path/to/dir>>>',
      pattern: RegExp(r'<<<LIST_DIR:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        var dirName = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'LIST_DIR $dirName: Failed (no workspace open).';
        }
        if (dirName == '.' || dirName.isEmpty) dirName = '';
        final dirPath = dirName.isEmpty
            ? inv.workspaceDir!
            : p.join(inv.workspaceDir!, dirName);
        try {
          final entries = await Directory(dirPath).list().toList();
          entries.sort((a, b) {
            final aDir = a is Directory;
            final bDir = b is Directory;
            if (aDir != bDir) return aDir ? -1 : 1;
            return p
                .basename(a.path)
                .toLowerCase()
                .compareTo(p.basename(b.path).toLowerCase());
          });
          final lines = <String>[];
          for (final e in entries) {
            final name = p.basename(e.path);
            if (e is Directory) {
              lines.add('[DIR]  $name/');
            } else if (e is File) {
              try {
                final stat = await e.stat();
                lines.add('       $name  (${_humanSize(stat.size)})');
              } catch (_) {
                lines.add('       $name');
              }
            }
          }
          return 'LIST_DIR ${dirName.isEmpty ? '.' : dirName}:\n${lines.join('\n')}';
        } catch (e) {
          return 'LIST_DIR $dirName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'tree',
      name: 'TREE',
      description:
          'Show the recursive directory tree for a path. Respects common '
          'ignore patterns (node_modules, .git, build, etc). Optional depth '
          'limit defaults to 3. Use to understand project structure quickly.',
      syntaxExample: '<<<TREE: path/to/dir>>>',
      pattern: RegExp(r'<<<TREE:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        var dirName = inv.match.group(1)!.trim();
        if (inv.workspaceDir == null) {
          return 'TREE $dirName: Failed (no workspace open).';
        }
        if (dirName == '.' || dirName.isEmpty) dirName = '';
        final dirPath = dirName.isEmpty
            ? inv.workspaceDir!
            : p.join(inv.workspaceDir!, dirName);
        try {
          final buf = StringBuffer();
          var count = 0;
          const maxEntries = 500;
          const maxDepth = 4;

          Future<void> walk(Directory dir, String prefix, int depth) async {
            if (depth > maxDepth || count >= maxEntries) return;
            final entries = await dir.list().toList();
            entries.sort((a, b) {
              final aDir = a is Directory;
              final bDir = b is Directory;
              if (aDir != bDir) return aDir ? -1 : 1;
              return p
                  .basename(a.path)
                  .toLowerCase()
                  .compareTo(p.basename(b.path).toLowerCase());
            });
            for (var i = 0; i < entries.length && count < maxEntries; i++) {
              final e = entries[i];
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              final isLast = i == entries.length - 1;
              final connector = isLast ? '└── ' : '├── ';
              final childPrefix = isLast ? '    ' : '│   ';
              if (e is Directory) {
                buf.writeln('$prefix$connector$name/');
                count++;
                await walk(e, '$prefix$childPrefix', depth + 1);
              } else {
                buf.writeln('$prefix$connector$name');
                count++;
              }
            }
          }

          buf.writeln(dirName.isEmpty ? '.' : dirName);
          count++;
          await walk(Directory(dirPath), '', 0);
          if (count >= maxEntries) {
            buf.writeln('... (truncated at $maxEntries entries)');
          }
          return 'TREE ${dirName.isEmpty ? '.' : dirName}:\n${buf.toString().trimRight()}';
        } catch (e) {
          return 'TREE $dirName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'search_text',
      name: 'SEARCH_TEXT',
      description:
          'Search for a pattern across the workspace. Output is grouped '
          'by file: `path:line:content` per match. Default is a literal, '
          'case-insensitive substring scan. Trailing flags refine the '
          'search:\n'
          '  :re             — interpret pattern as a regex\n'
          '  :cs             — case sensitive (default is insensitive)\n'
          '  :glob=<pattern> — limit to files matching this glob '
          '(e.g. `:glob=lib/**/*.dart`); repeat for multiple\n'
          '  :context=N      — include N lines of context around each '
          'match (max 10)\n'
          '  :max=N          — cap at N matches (default 100, max 500)\n'
          'Uses ripgrep (`rg`) when available — orders of magnitude '
          'faster than the in-process scanner — and falls back to a '
          'native walker that supports `:re` / `:cs` only (`:glob` and '
          '`:context` require rg). Skips binary files and common ignore '
          'dirs (node_modules, .git, build, …).',
      syntaxExample:
          '<<<SEARCH_TEXT: search pattern>>>\n'
          '    <<<SEARCH_TEXT: function\\s+\\w+ :re :glob=lib/**/*.dart :context=2>>>',
      pattern: RegExp(r'<<<SEARCH_TEXT:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final raw = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'SEARCH_TEXT $raw: Failed (no workspace open).';
        }
        final flags = <String, List<String>>{};
        final query = _stripTrailingFlags(raw, flags);
        if (query.isEmpty) {
          return 'SEARCH_TEXT: Failed (empty query after parsing flags).';
        }
        final useRegex = flags.containsKey('re');
        final caseSensitive = flags.containsKey('cs');
        final globs = flags['glob'] ?? const <String>[];
        final contextLines = (int.tryParse(
                  flags['context']?.lastOrNull ?? '0',
                ) ??
                0)
            .clamp(0, 10);
        final maxMatches = (int.tryParse(flags['max']?.lastOrNull ?? '100') ??
                100)
            .clamp(1, 500);

        // Try ripgrep first. Most dev machines have it, and the
        // perf gap is huge on real codebases. Falls back cleanly
        // when rg isn't on PATH.
        final rgOut = await _runRipgrep(
          workspaceDir: inv.workspaceDir!,
          query: query,
          useRegex: useRegex,
          caseSensitive: caseSensitive,
          globs: globs,
          contextLines: contextLines,
          maxMatches: maxMatches,
        );
        if (rgOut != null) return rgOut;

        // Fallback: native Dart walker. Supports `:re` / `:cs` only —
        // `:glob` / `:context` need rg's path-matcher and pre/post
        // line emission, which would more than double this code path.
        if (globs.isNotEmpty || contextLines > 0) {
          return 'SEARCH_TEXT "$query": ripgrep (`rg`) not found and '
              'fallback scanner does not support `:glob` / `:context`. '
              'Install ripgrep, or rerun without those flags.';
        }
        try {
          final results = <String>[];
          final RegExp pattern;
          try {
            pattern = useRegex
                ? RegExp(query, caseSensitive: caseSensitive)
                : RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
          } on FormatException catch (e) {
            return 'SEARCH_TEXT "$query": Error: invalid regex — '
                '${e.message}';
          }
          var fileCount = 0;
          var matchCount = 0;

          Future<void> walkDir(Directory dir) async {
            if (matchCount >= maxMatches) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (matchCount >= maxMatches) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                await walkDir(e);
              } else if (e is File) {
                final ext = p.extension(name).toLowerCase();
                if (_binaryExts.contains(ext)) continue;
                try {
                  final stat = await e.stat();
                  if (stat.size > 2 * 1024 * 1024) continue;
                } catch (_) {
                  continue;
                }
                String content;
                try {
                  content = await e.readAsString();
                } catch (_) {
                  continue;
                }
                final lines = content.split('\n');
                final rel = p
                    .relative(e.path, from: inv.workspaceDir!)
                    .replaceAll(r'\', '/');
                for (
                  var i = 0;
                  i < lines.length && matchCount < maxMatches;
                  i++
                ) {
                  if (pattern.hasMatch(lines[i])) {
                    if (matchCount == 0 || results.last.startsWith(rel) == false) {
                      // Track first occurrence to count files.
                      if (!results.any((r) => r.startsWith('$rel:'))) {
                        fileCount++;
                      }
                    }
                    matchCount++;
                    // ripgrep-style `path:line:content`. Trim huge
                    // lines so a minified-asset hit doesn't blow
                    // the budget on its own.
                    final body = lines[i].trimRight();
                    final trimmed = body.length > 240
                        ? '${body.substring(0, 240)}…'
                        : body;
                    results.add('$rel:${i + 1}:$trimmed');
                  }
                }
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          if (results.isEmpty) {
            return 'SEARCH_TEXT "$query": No matches found.';
          }
          final truncNote = matchCount >= maxMatches
              ? '\n... (truncated at $maxMatches matches; pass `:max=N` '
                  'to raise, or narrow with `:glob=...`)'
              : '';
          return 'SEARCH_TEXT "$query": $matchCount matches in '
              '$fileCount file(s) (native fallback)\n'
              '${results.join('\n')}$truncNote';
        } catch (e) {
          return 'SEARCH_TEXT "$query": Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'find_file',
      name: 'FIND_FILE',
      description:
          'Find files by name pattern (substring match, case-insensitive). '
          'Returns relative paths. Use to locate files when you do not know '
          'the exact path.',
      syntaxExample: '<<<FIND_FILE: partial_name>>>',
      pattern: RegExp(r'<<<FIND_FILE:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final query = inv.match.group(1)!.toLowerCase();
        if (inv.workspaceDir == null) {
          return 'FIND_FILE $query: Failed (no workspace open).';
        }
        try {
          final results = <String>[];
          const maxResults = 50;

          Future<void> walkDir(Directory dir) async {
            if (results.length >= maxResults) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (results.length >= maxResults) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                if (name.toLowerCase().contains(query)) {
                  results.add(
                    '${p.relative(e.path, from: inv.workspaceDir!)}/  [DIR]',
                  );
                }
                await walkDir(e);
              } else {
                if (name.toLowerCase().contains(query)) {
                  results.add(p.relative(e.path, from: inv.workspaceDir!));
                }
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          if (results.isEmpty) {
            return 'FIND_FILE "$query": No matching files found.';
          }
          return 'FIND_FILE "$query": ${results.length} result(s)\n${results.join('\n')}';
        } catch (e) {
          return 'FIND_FILE $query: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'glob',
      name: 'GLOB',
      description:
          'Find files matching a glob pattern. More powerful than FIND_FILE '
          '(which only does substring). Patterns are relative to the '
          'workspace: `**` matches any depth, `*` matches one path '
          'segment, `?` matches a single character. Examples: '
          '`lib/**/*.dart`, `test/*_test.dart`, `**/Dockerfile`. Returns '
          'workspace-relative paths sorted alphabetically.',
      syntaxExample: '<<<GLOB: lib/**/*.dart>>>',
      pattern: RegExp(r'<<<GLOB:\s*(.+?)\s*>>>'),
      execute: (inv) async {
        final pat = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'GLOB $pat: Failed (no workspace open).';
        }
        final regex = _globToRegExp(pat);
        try {
          final results = <String>[];
          const maxResults = 200;

          Future<void> walkDir(Directory dir) async {
            if (results.length >= maxResults) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (results.length >= maxResults) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                await walkDir(e);
              } else if (e is File) {
                // Forward-slash normalised so glob patterns work
                // identically on Windows and Unix paths.
                final rel = p
                    .relative(e.path, from: inv.workspaceDir!)
                    .replaceAll(r'\', '/');
                if (regex.hasMatch(rel)) results.add(rel);
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          results.sort();
          if (results.isEmpty) return 'GLOB "$pat": No matches.';
          final cap = results.length >= maxResults
              ? '\n... (truncated at $maxResults)'
              : '';
          return 'GLOB "$pat": ${results.length} match(es)\n'
              '${results.join('\n')}$cap';
        } catch (e) {
          return 'GLOB $pat: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'delete_file',
      name: 'DELETE_FILE',
      description: 'Delete a file or empty directory. Requires user approval.',
      syntaxExample: '<<<DELETE_FILE: path/to/file>>>',
      pattern: RegExp(r'<<<DELETE_FILE:\s*(.*?)\s*>>>'),
      requiresApproval: true,
      execute: (inv) async {
        final target = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'DELETE_FILE $target: Failed (no workspace open).';
        }
        final approved = await inv.approver('DELETE_FILE', target);
        if (!approved) {
          return 'DELETE_FILE $target: Denied by user.';
        }
        final filePath = _resolvePath(inv, target, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('DELETE_FILE', target);
        }
        try {
          final type = await FileSystemEntity.type(filePath);
          if (type == FileSystemEntityType.file) {
            await File(filePath).delete();
            return 'DELETE_FILE $target: Success (file deleted)';
          } else if (type == FileSystemEntityType.directory) {
            await Directory(filePath).delete(recursive: false);
            return 'DELETE_FILE $target: Success (empty directory deleted)';
          }
          return 'DELETE_FILE $target: Error: path does not exist.';
        } catch (e) {
          return 'DELETE_FILE $target: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_status',
      name: 'GIT_STATUS',
      description:
          'Show `git status` (porcelain + branch) for the workspace. Lists '
          'modified, staged, untracked, and deleted files. Use this before '
          'making changes to understand the working-tree baseline; use it '
          'after to confirm what your edits touched.',
      syntaxExample: '<<<GIT_STATUS>>>',
      pattern: RegExp(r'<<<GIT_STATUS>>>'),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_STATUS: Failed (no workspace open).';
        }
        try {
          final r = await Process.run(
            'git',
            ['status', '--porcelain', '--branch'],
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_STATUS: Error: '
                '${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = r.stdout.toString().trim();
          if (out.isEmpty) return 'GIT_STATUS: clean (no changes).';
          return 'GIT_STATUS:\n$out';
        } on ProcessException catch (e) {
          return 'GIT_STATUS: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_STATUS: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_diff',
      name: 'GIT_DIFF',
      description:
          'Show `git diff` for the workspace. Default is unstaged '
          'changes. Argument is optional and accepts:\n'
          '  - a file/directory path → diff scoped to that path\n'
          '  - `:staged` → show staged (`--cached`) changes\n'
          '  - a git revision (`HEAD~1`, `main..HEAD`, `<sha>`) → diff '
          'against that ref; combine with a path after `--` if needed\n'
          'Examples: `<<<GIT_DIFF>>>`, '
          '`<<<GIT_DIFF: lib/foo.dart>>>`, '
          '`<<<GIT_DIFF: :staged>>>`, '
          '`<<<GIT_DIFF: HEAD~3>>>`. Output capped at 64KB.',
      syntaxExample: '<<<GIT_DIFF>>>  or  <<<GIT_DIFF: HEAD~1>>>',
      pattern: RegExp(r'<<<GIT_DIFF(?::\s*(.+?))?\s*>>>'),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_DIFF: Failed (no workspace open).';
        }
        final argRaw = inv.match.group(1)?.trim() ?? '';
        // Parse the argument shape. Three buckets, in priority order:
        //   1. exactly `:staged` → --cached
        //   2. starts with a non-`:` token that resolves to a git rev →
        //      pass through, optionally with a `--` path tail
        //   3. otherwise → treat as a path
        // We don't try to detect "rev or path" by syntax — we hand the
        // whole arg to git as the first positional, and let git
        // disambiguate via its own `--` convention. Models that want
        // a path with a complex name pass it after `--`.
        final args = <String>['diff'];
        var label = argRaw;
        if (argRaw.isEmpty) {
          // unstaged, full workspace
        } else if (argRaw == ':staged' || argRaw == '--staged') {
          args.add('--cached');
          label = 'staged';
        } else if (argRaw.contains(' -- ')) {
          // explicit `<rev> -- <path>` form
          final idx = argRaw.indexOf(' -- ');
          final rev = argRaw.substring(0, idx).trim();
          final pathPart = argRaw.substring(idx + 4).trim();
          if (rev.isNotEmpty) args.add(rev);
          if (pathPart.isNotEmpty) args.addAll(['--', pathPart]);
        } else if (argRaw.startsWith(':')) {
          return 'GIT_DIFF: Unknown flag `$argRaw`. Supported: `:staged`. '
              'Pass a path or git revision otherwise.';
        } else {
          // Heuristic: looks like a rev (no slash, no `.`, or contains
          // `..` / `~` / `^` / is short hex) → pass as rev, else path.
          final looksLikeRev = !argRaw.contains('/') &&
              (RegExp(r'^[0-9a-f]{7,40}$').hasMatch(argRaw) ||
                  argRaw.contains('..') ||
                  argRaw.contains('~') ||
                  argRaw.contains('^') ||
                  argRaw == 'HEAD' ||
                  argRaw.startsWith('HEAD'));
          if (looksLikeRev) {
            args.add(argRaw);
          } else {
            args.addAll(['--', argRaw]);
          }
        }
        try {
          final r = await Process.run(
            'git',
            args,
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_DIFF${label.isEmpty ? '' : ' $label'}: '
                'Error: ${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = _cap(r.stdout.toString());
          if (out.trim().isEmpty) {
            return 'GIT_DIFF${label.isEmpty ? '' : ' $label'}: '
                'no changes.';
          }
          return 'GIT_DIFF${label.isEmpty ? '' : ' $label'}:\n$out';
        } on ProcessException catch (e) {
          return 'GIT_DIFF: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_DIFF: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_log',
      name: 'GIT_LOG',
      description:
          'Show recent commit history for the workspace. One line per '
          'commit: `<short-sha> <date> <author> <subject>`. Argument is '
          'optional: pass a file/directory path to scope, or '
          '`:n=<count>` to change the limit (default 20, max 200). '
          'Combine with `:n=` to drill in deeper, e.g. '
          '`<<<GIT_LOG: lib/foo.dart :n=50>>>`. Read-only — does not '
          'fetch from remotes.',
      syntaxExample:
          '<<<GIT_LOG>>>  or  <<<GIT_LOG: lib/foo.dart>>>',
      pattern: RegExp(r'<<<GIT_LOG(?::\s*(.+?))?\s*>>>'),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_LOG: Failed (no workspace open).';
        }
        final raw = inv.match.group(1)?.trim() ?? '';
        final flags = <String, List<String>>{};
        final pathArg = _stripTrailingFlags(raw, flags);
        final n = (int.tryParse(flags['n']?.lastOrNull ?? '20') ?? 20)
            .clamp(1, 200);
        final args = <String>[
          'log',
          '-n', '$n',
          '--pretty=format:%h %ad %an %s',
          '--date=short',
        ];
        if (pathArg.isNotEmpty) args.addAll(['--', pathArg]);
        try {
          final r = await Process.run(
            'git',
            args,
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_LOG: Error: '
                '${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = r.stdout.toString().trim();
          if (out.isEmpty) {
            return 'GIT_LOG${pathArg.isEmpty ? '' : ' $pathArg'}: '
                'no commits.';
          }
          return 'GIT_LOG${pathArg.isEmpty ? '' : ' $pathArg'} '
              '(last $n):\n$out';
        } on ProcessException catch (e) {
          return 'GIT_LOG: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_LOG: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_blame',
      name: 'GIT_BLAME',
      description:
          'Show `git blame` for a file — who last touched each line and '
          'in which commit. Output format: `<short-sha> (<author> '
          '<date>) <lineNo>) <content>`. Optional `:start-end` '
          'suffix limits to a 1-based inclusive line range, useful for '
          'big files. Examples: `<<<GIT_BLAME: lib/foo.dart>>>`, '
          '`<<<GIT_BLAME: lib/foo.dart:42-80>>>`. Read-only.',
      syntaxExample: '<<<GIT_BLAME: lib/foo.dart>>>',
      pattern: RegExp(
        r'<<<GIT_BLAME:\s*(.+?)(?::(\d+)-(\d+))?\s*>>>',
      ),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_BLAME: Failed (no workspace open).';
        }
        final fileName = inv.match.group(1)!;
        final startStr = inv.match.group(2);
        final endStr = inv.match.group(3);
        final args = <String>['blame', '-c'];
        if (startStr != null && endStr != null) {
          args.addAll(['-L', '$startStr,$endStr']);
        }
        args.addAll(['--', fileName]);
        try {
          final r = await Process.run(
            'git',
            args,
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_BLAME $fileName: Error: '
                '${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = _cap(r.stdout.toString());
          if (out.trim().isEmpty) {
            return 'GIT_BLAME $fileName: no blame output '
                '(file may be untracked).';
          }
          return 'GIT_BLAME $fileName${startStr != null ? ' lines $startStr-$endStr' : ''}:\n$out';
        } on ProcessException catch (e) {
          return 'GIT_BLAME $fileName: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_BLAME $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'check_url',
      name: 'CHECK_URL',
      description:
          'Probe whether a URL or host:port is reachable, without '
          'starting anything. Use BEFORE any RUN_CMD that starts a '
          'dev server — if the port is already open, the user has '
          'it running already; do not spawn a duplicate.',
      syntaxExample:
          '<<<CHECK_URL: http://localhost:3000>>> '
          '(also accepts localhost:3000, 5173, https://example.com)',
      pattern: RegExp(r'<<<CHECK_URL:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final raw = inv.match.group(1)!.trim();
        if (raw.isEmpty) {
          return 'CHECK_URL: Failed (empty target).';
        }
        // Three input shapes: "http(s)://host[:port]/path", bare
        // "host:port", or a bare port like "3000". Resolve to
        // (host, port, scheme?) for the actual probe — the full
        // URL is preserved in `raw` for the HTTP stage so we
        // don't need to reconstruct path/query manually.
        String host;
        int port;
        String? scheme;
        try {
          if (raw.startsWith('http://') || raw.startsWith('https://')) {
            final u = Uri.parse(raw);
            scheme = u.scheme;
            host = u.host.isEmpty ? 'localhost' : u.host;
            port = u.hasPort
                ? u.port
                : (scheme == 'https' ? 443 : 80);
          } else if (RegExp(r'^\d+$').hasMatch(raw)) {
            host = 'localhost';
            port = int.parse(raw);
          } else {
            // host:port form
            final colon = raw.lastIndexOf(':');
            if (colon < 0) {
              return 'CHECK_URL $raw: Failed (no port specified).';
            }
            host = raw.substring(0, colon);
            port = int.parse(raw.substring(colon + 1));
          }
        } catch (e) {
          return 'CHECK_URL $raw: Failed to parse target — $e';
        }

        // Stage 1: TCP connect with 2s timeout. If the port is
        // closed we can answer immediately; no need to attempt
        // an HTTP round-trip that would just fail.
        final swTcp = Stopwatch()..start();
        try {
          final sock = await Socket.connect(host, port,
              timeout: const Duration(seconds: 2));
          final tcpMs = swTcp.elapsedMilliseconds;
          await sock.close();
          if (scheme == null) {
            return 'CHECK_URL $raw: Reachable. TCP connect to '
                '$host:$port succeeded in ${tcpMs}ms. '
                'Something is listening — likely the user already '
                'has the app running. Do NOT spawn a duplicate '
                'server.';
          }
        } on SocketException catch (e) {
          return 'CHECK_URL $raw: Closed. TCP connect to $host:$port '
              'failed (${e.osError?.message ?? e.message}). '
              'Nothing is listening — safe to start a server here.';
        } on TimeoutException {
          return 'CHECK_URL $raw: Timed out connecting to '
              '$host:$port (2s). Likely closed or firewalled — '
              'safe to start a server here.';
        } catch (e) {
          return 'CHECK_URL $raw: TCP probe failed — $e';
        }

        // Stage 2: HTTP HEAD when the input had a scheme. Falls
        // back to GET if HEAD returns 405 — some dev servers
        // (Vite without explicit support) only handle GET.
        final swHttp = Stopwatch()..start();
        try {
          final client = HttpClient()
            ..connectionTimeout = const Duration(seconds: 2);
          try {
            HttpClientRequest req;
            try {
              req = await client.headUrl(Uri.parse(raw));
            } catch (_) {
              req = await client.getUrl(Uri.parse(raw));
            }
            final res = await req.close().timeout(
                  const Duration(seconds: 3),
                );
            // Drain the body so the connection can be closed
            // cleanly; we don't need the bytes.
            await res.drain<void>();
            return 'CHECK_URL $raw: Reachable. '
                'HTTP ${res.statusCode} ${res.reasonPhrase} '
                'in ${swHttp.elapsedMilliseconds}ms. '
                'Something is serving on $host:$port — likely '
                'the user already has the app running. Do NOT '
                'spawn a duplicate server.';
          } finally {
            client.close(force: true);
          }
        } catch (e) {
          // TCP succeeded but HTTP didn't — port is open but
          // not speaking HTTP (or it's slow / wrong protocol).
          // Still report it as "reachable" because a duplicate
          // server start would still collide on the port.
          return 'CHECK_URL $raw: Port $host:$port is OPEN but did '
              'not respond to HTTP within 3s ($e). Whatever owns '
              'the port may not be the right app — but starting '
              'a new server on the same port WILL fail with '
              'EADDRINUSE. Ask the user.';
        }
      },
    ),
    AgentTool(
      id: 'run_cmd',
      name: 'RUN_CMD',
      description:
          'Run a shell command in the workspace. Requires user '
          'approval. For long-running processes (dev servers, '
          'watchers): CHECK_URL the expected port FIRST so you do '
          'not spawn a duplicate. The call soft-times-out at ~25s; '
          'a "detached, still running" result is success, not '
          'failure — the process keeps running as a tab in the '
          'terminal pane that the user can see and close.',
      syntaxExample: '<<<RUN_CMD: command to run>>>',
      pattern: RegExp(r'<<<RUN_CMD:\s*(.*?)\s*>>>'),
      requiresApproval: true,
      execute: (inv) async {
        final cmd = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'RUN_CMD $cmd: Failed (no workspace open).';
        }
        final approved = await inv.approver('RUN_CMD', cmd);
        if (!approved) {
          return 'RUN_CMD $cmd: Denied by user.';
        }

        // **Two execution paths**, depending on whether the IDE has
        // wired up the agent terminal bridge:
        //
        //   1. **Bridge path (production wiring)** — preferred.
        //      Routes the command through `AgentTerminalBridge` so
        //      it runs inside a real PTY-backed `TerminalSession`.
        //      On detach (soft-timeout / ready-detect), we promote
        //      the session into the visible terminal pane: the user
        //      sees a fresh tab labeled `agent: <cmd>`, can interact
        //      with it (`r` to hot-reload Vite, `q` to quit, etc.),
        //      and can kill it cleanly via tab close — pty.kill
        //      forwards Ctrl+C to the foreground process group, so
        //      `npm run dev` actually shuts down `node` instead of
        //      orphaning it.
        //
        //   2. **Legacy path (tests / non-IDE callers)** — when no
        //      launcher is attached. Runs via `Process.start` and
        //      detaches the orphan as before. Same semantics it
        //      always had; kept so headless test harnesses keep
        //      working without mounting a terminal pane.
        if (inv.agentTerminalLauncher != null) {
          return _runCmdViaBridge(cmd, inv);
        }
        return _runCmdLegacy(cmd, inv);
      },
    ),
    AgentTool(
      id: 'verify',
      name: 'VERIFY',
      description:
          'Run the workspace static analyzer / type-checker / linter '
          'and return a digest. No arguments. Auto-detects the '
          'toolchain (pubspec.yaml → dart analyze, tsconfig.json → '
          'tsc, package.json → eslint, pyproject/requirements → ruff '
          'or pyflakes). Call after source edits before declaring '
          'done. If the result says "no analyzer detected" or '
          '"dependencies are not installed" — STOP calling VERIFY '
          'for this workspace; either run RUN_CMD with the project\'s '
          'actual check command or skip verification.',
      syntaxExample: '<<<VERIFY>>>',
      pattern: RegExp(r'<<<VERIFY\s*>>>'),
      execute: _executeVerify,
    ),
    AgentTool(
      id: 'web_search',
      name: 'WEB_SEARCH',
      description:
          'Search the public web via Ollama Cloud and return ranked '
          'results (title, URL, content snippet). Requires an Ollama '
          'Cloud API key (Settings → AI / Chat → Ollama Cloud API '
          'key). Use this when the user\'s question depends on '
          'fresh / external knowledge the model can\'t be expected '
          'to know — current events, library APIs released after '
          'training, error messages from third-party tools, etc. '
          'Pair with WEB_FETCH to drill into a specific result. '
          'Trailing flag refines the call:\n'
          '  :max=N  — max results (default 5, clamped to 1..10)',
      syntaxExample:
          '<<<WEB_SEARCH: search query>>>\n'
          '    <<<WEB_SEARCH: ollama new engine release notes :max=10>>>',
      pattern: RegExp(r'<<<WEB_SEARCH:\s*(.*?)\s*>>>'),
      execute: _executeWebSearch,
    ),
    AgentTool(
      id: 'web_fetch',
      name: 'WEB_FETCH',
      description:
          'Fetch a single web page via Ollama Cloud and return its '
          'title, main content, and outbound links. Requires an '
          'Ollama Cloud API key (Settings → AI / Chat → Ollama '
          'Cloud API key). Routes through ollama.com\'s extractor '
          'so the response is cleaned of ads / boilerplate and '
          'SPA content is rendered before extraction. Use after '
          'WEB_SEARCH to read the actual article, or to look up a '
          'URL the user pasted. Content is truncated to '
          '~16k characters; if you need more, fetch a more '
          'specific URL (e.g. the article\'s permalink rather than '
          'a section index).',
      syntaxExample:
          '<<<WEB_FETCH: https://example.com/article>>>',
      pattern: RegExp(r'<<<WEB_FETCH:\s*(.*?)\s*>>>'),
      execute: _executeWebFetch,
    ),
  ];

  /// Hard caps on `WEB_FETCH` content / link list size. Web pages
  /// can easily blow past 100k characters of body text — even with
  /// cloud models running at ~32k tokens the agent doesn't benefit
  /// from feeding the model a wall of nav-menu boilerplate. Caller
  /// is told to fetch a more specific URL when they hit the cap.
  static const int _kWebFetchMaxContentChars = 16 * 1024;
  static const int _kWebFetchMaxLinks = 30;

  /// Per-result content snippet cap for `WEB_SEARCH`. The Ollama
  /// API already returns short snippets but we trim further so a
  /// `:max=10` call with verbose content stays under ~6k chars
  /// total. Models can call `WEB_FETCH` on a result URL when they
  /// need the full body.
  static const int _kWebSearchSnippetChars = 600;

  static Future<String> _executeWebSearch(ToolInvocation inv) async {
    final raw = inv.match.group(1)!.trim();
    if (raw.isEmpty) {
      return 'WEB_SEARCH: Error: query is empty.';
    }

    var query = raw;
    var maxResults = 5;
    final maxFlag = RegExp(r'\s:max=(\d+)\s*$').firstMatch(query);
    if (maxFlag != null) {
      final parsed = int.tryParse(maxFlag.group(1)!);
      if (parsed != null) maxResults = parsed.clamp(1, 10);
      query = query.substring(0, maxFlag.start).trim();
    }
    if (query.isEmpty) {
      return 'WEB_SEARCH: Error: query is empty (only flags supplied).';
    }

    if (inv.webSearch == null) {
      return 'WEB_SEARCH "$query": Error: Ollama Cloud API key is not '
          'configured. Set it in Settings → AI / Chat → Ollama Cloud '
          'API key.';
    }

    Map<String, dynamic> body;
    try {
      body = await inv.webSearch!(query, maxResults: maxResults);
    } on StateError catch (e) {
      return 'WEB_SEARCH "$query": Error: ${e.message}';
    } on TimeoutException {
      return 'WEB_SEARCH "$query": Error: request timed out after 30s.';
    } catch (e) {
      return 'WEB_SEARCH "$query": Error: $e';
    }

    final results = (body['results'] as List?) ?? const [];
    if (results.isEmpty) {
      return 'WEB_SEARCH "$query": No results.';
    }

    final out = StringBuffer();
    out.writeln('WEB_SEARCH "$query": ${results.length} result(s)');
    for (var i = 0; i < results.length; i++) {
      final r = results[i] as Map?;
      if (r == null) continue;
      final title = (r['title'] ?? '').toString().trim();
      final url = (r['url'] ?? '').toString().trim();
      var content = (r['content'] ?? '').toString().trim();
      if (content.length > _kWebSearchSnippetChars) {
        content =
            '${content.substring(0, _kWebSearchSnippetChars)}…';
      }
      out.writeln();
      out.writeln('[${i + 1}] ${title.isEmpty ? '(no title)' : title}');
      if (url.isNotEmpty) out.writeln('    URL: $url');
      if (content.isNotEmpty) out.writeln('    $content');
    }
    return out.toString().trimRight();
  }

  static Future<String> _executeWebFetch(ToolInvocation inv) async {
    final raw = inv.match.group(1)!.trim();
    if (raw.isEmpty) {
      return 'WEB_FETCH: Error: URL is empty.';
    }
    // Tolerate URLs without a scheme (the Ollama API accepts
    // `ollama.com` per their docs, but normalising up-front keeps
    // the feedback string stable and gives us a parse error with
    // a clear message when the agent passes obvious garbage).
    final url = raw.contains('://') ? raw : 'https://$raw';
    final parsed = Uri.tryParse(url);
    if (parsed == null || parsed.host.isEmpty) {
      return 'WEB_FETCH "$raw": Error: not a valid URL.';
    }

    if (inv.webFetch == null) {
      return 'WEB_FETCH "$url": Error: Ollama Cloud API key is not '
          'configured. Set it in Settings → AI / Chat → Ollama Cloud '
          'API key.';
    }

    Map<String, dynamic> body;
    try {
      body = await inv.webFetch!(url);
    } on StateError catch (e) {
      return 'WEB_FETCH "$url": Error: ${e.message}';
    } on TimeoutException {
      return 'WEB_FETCH "$url": Error: request timed out after 30s.';
    } catch (e) {
      return 'WEB_FETCH "$url": Error: $e';
    }

    final title = (body['title'] ?? '').toString().trim();
    var content = (body['content'] ?? '').toString();
    final truncated = content.length > _kWebFetchMaxContentChars;
    if (truncated) {
      content = content.substring(0, _kWebFetchMaxContentChars);
    }
    final linksRaw = (body['links'] as List?) ?? const [];
    final links = linksRaw
        .map((e) => e?.toString() ?? '')
        .where((s) => s.isNotEmpty)
        .toList(growable: false);
    final shownLinks = links.length > _kWebFetchMaxLinks
        ? links.sublist(0, _kWebFetchMaxLinks)
        : links;

    final out = StringBuffer();
    out.writeln('WEB_FETCH "$url":');
    out.writeln('Title: ${title.isEmpty ? '(no title)' : title}');
    out.writeln();
    out.writeln('--- Content ---');
    out.writeln(content.trimRight());
    if (truncated) {
      out.writeln(
        '... (content truncated at $_kWebFetchMaxContentChars chars; '
        'fetch a more specific URL for the rest)',
      );
    }
    if (shownLinks.isNotEmpty) {
      out.writeln();
      out.writeln('--- Links (${shownLinks.length}'
          '${links.length > shownLinks.length ? ' of ${links.length}' : ''}) ---');
      for (final l in shownLinks) {
        out.writeln(l);
      }
      if (links.length > shownLinks.length) {
        out.writeln('... (${links.length - shownLinks.length} more)');
      }
    }
    return out.toString().trimRight();
  }

  /// Directories/files never descended into by TREE, SEARCH_TEXT, FIND_FILE.
  static const _treeIgnore = <String>{
    'node_modules',
    '.git',
    '.gitnexus',
    '.dart_tool',
    'build',
    'dist',
    'out',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.turbo',
    '.cache',
    '.parcel-cache',
    '.idea',
    '.vscode',
    '.vscode-test',
    'venv',
    '.venv',
    'env',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    '.tox',
    'target',
    'Pods',
    '.gradle',
    '.expo',
    '.expo-shared',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    'coverage',
    '.lumen',
    '.duckoff',
  };

  /// Binary extensions skipped by SEARCH_TEXT.
  static const _binaryExts = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.ico',
    '.svg',
    '.mp3',
    '.wav',
    '.ogg',
    '.flac',
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.zip',
    '.tar',
    '.gz',
    '.7z',
    '.rar',
    '.bz2',
    '.xz',
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.bin',
    '.iso',
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
    '.eot',
    '.class',
    '.jar',
    '.pyc',
    '.pyo',
    '.o',
    '.obj',
    '.lib',
    '.a',
    '.lock',
  };

  /// Human-readable file size for LIST_DIR output.
  static String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  /// Peel trailing `:flag` / `:flag=value` tokens off the end of a
  /// SEARCH_TEXT (and similar) raw input so the residue is the actual
  /// query. We only strip from the END — anything earlier in the input
  /// stays as part of the query, which lets natural patterns like
  /// `Map<K, V>` or `foo:bar` appear in the body without being parsed
  /// as flags.
  ///
  /// Multiple instances of the same flag accumulate into a list (e.g.
  /// repeated `:glob=...` for unioned include patterns).
  static String _stripTrailingFlags(
    String input,
    Map<String, List<String>> flagsOut,
  ) {
    // Trailing run of one-or-more flag tokens, each preceded by
    // whitespace. Anchored at end; we pull the whole run once.
    final flagRun = RegExp(
      r'(?:\s+:[a-zA-Z]+(?:=\S+)?)+\s*$',
    );
    final m = flagRun.firstMatch(input);
    if (m == null) return input.trim();
    final tail = input.substring(m.start);
    final body = input.substring(0, m.start).trim();
    final tokenRe = RegExp(r':([a-zA-Z]+)(?:=(\S+))?');
    for (final t in tokenRe.allMatches(tail)) {
      final key = t.group(1)!;
      final value = t.group(2) ?? '';
      flagsOut.putIfAbsent(key, () => <String>[]).add(value);
    }
    return body;
  }

  /// Run ripgrep against the workspace, returning a fully-formatted
  /// `SEARCH_TEXT ...` payload on success or `null` when rg isn't
  /// available (so the caller can fall back). Errors from rg itself
  /// (regex parse, IO) are surfaced as a normal payload — the caller
  /// should NOT retry the fallback for those.
  static Future<String?> _runRipgrep({
    required String workspaceDir,
    required String query,
    required bool useRegex,
    required bool caseSensitive,
    required List<String> globs,
    required int contextLines,
    required int maxMatches,
  }) async {
    final args = <String>[
      '--no-heading',
      '-n',
      '-H',
      '--color=never',
      '--max-columns=240',
      '--max-count', '$maxMatches',
    ];
    // Smart-case is the wrong default for an LLM agent — it makes
    // identical queries behave differently based on the casing the
    // model happens to type. Pin to explicit insensitive / sensitive.
    args.add(caseSensitive ? '-s' : '-i');
    if (!useRegex) args.add('-F');
    if (contextLines > 0) {
      args.addAll(['-C', '$contextLines']);
    }
    for (final g in globs) {
      if (g.isEmpty) continue;
      args.addAll(['-g', g]);
    }
    args.addAll(['-e', query]);
    // The trailing `.` makes ripgrep search the workingDirectory we
    // pass to Process.run, so workspace-relative paths come out
    // clean in the output (matching what the model expects).
    args.add('.');

    // Resolve which rg to spawn. Order:
    //   1. Bundled binary materialised by RipgrepProvisioner — same
    //      version on every install, no install friction for colleagues.
    //   2. Bare `rg` on PATH — for power users who already have a
    //      newer (or differently-built) ripgrep installed.
    //   3. Caller falls back to native Dart walker.
    // First-attempt failure (binary present but blew up) is reported
    // up; only "rg not found" via ProcessException triggers fallback,
    // since a real error (regex parse, IO) shouldn't be silently
    // retried with a different engine.
    var rgExecutable = await RipgrepProvisioner.ensure() ?? 'rg';
    ProcessResult res;
    try {
      res = await Process.run(
        rgExecutable,
        args,
        workingDirectory: workspaceDir,
        runInShell: false,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );
    } on ProcessException {
      // Provisioned path failed (e.g. AV quarantine, permissions) AND
      // we tried bare `rg` only if the provisioned path was the
      // sentinel string. Try the PATH fallback once more before
      // giving up.
      if (rgExecutable != 'rg') {
        try {
          res = await Process.run(
            'rg',
            args,
            workingDirectory: workspaceDir,
            runInShell: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
        } on ProcessException {
          return null;
        } catch (_) {
          return null;
        }
      } else {
        return null;
      }
    } catch (_) {
      return null;
    }

    // rg exit codes: 0 = matches, 1 = no matches, 2+ = error.
    if (res.exitCode == 1) {
      final flagSummary = _formatFlagSummary(
        useRegex: useRegex,
        caseSensitive: caseSensitive,
        globs: globs,
        contextLines: contextLines,
      );
      return 'SEARCH_TEXT "$query"$flagSummary: No matches found.';
    }
    if (res.exitCode >= 2) {
      final err = (res.stderr as String? ?? '').trim();
      if (err.isEmpty) {
        return 'SEARCH_TEXT "$query": ripgrep failed '
            '(exit ${res.exitCode}).';
      }
      return 'SEARCH_TEXT "$query": ripgrep error — $err';
    }

    var out = (res.stdout as String? ?? '').replaceAll('\r\n', '\n');
    // Normalise path separators to forward slashes for consistency
    // with GLOB / READ_FILE conventions; only touch the leading path
    // segment up to the first `:`.
    final lines = out.split('\n');
    var matchCount = 0;
    var fileCount = 0;
    final seenFiles = <String>{};
    final fixed = <String>[];
    for (final line in lines) {
      if (line.isEmpty) {
        fixed.add(line);
        continue;
      }
      // Context lines from rg use `path-line-content` (note: hyphen
      // separator); match lines use `path:line:content`. Both flow
      // through unchanged; we just normalise the path slashes.
      final colon = line.indexOf(RegExp(r'[:\-]'));
      if (colon <= 0) {
        fixed.add(line);
        continue;
      }
      final pathPart = line.substring(0, colon);
      final rest = line.substring(colon);
      final normPath = pathPart.replaceAll(r'\', '/');
      // First char of `rest` is the separator; ':' = match line.
      if (rest.startsWith(':')) {
        matchCount++;
        if (seenFiles.add(normPath)) fileCount++;
      }
      fixed.add('$normPath$rest');
    }
    final body = fixed.join('\n').trim();
    if (body.isEmpty || matchCount == 0) {
      return 'SEARCH_TEXT "$query": No matches found.';
    }
    final flagSummary = _formatFlagSummary(
      useRegex: useRegex,
      caseSensitive: caseSensitive,
      globs: globs,
      contextLines: contextLines,
    );
    final truncNote = matchCount >= maxMatches
        ? '\n... (capped at $maxMatches matches; pass `:max=N` to raise, '
            'or narrow with `:glob=...`)'
        : '';
    return 'SEARCH_TEXT "$query"$flagSummary: '
        '$matchCount match(es) in $fileCount file(s)\n'
        '$body$truncNote';
  }

  static String _formatFlagSummary({
    required bool useRegex,
    required bool caseSensitive,
    required List<String> globs,
    required int contextLines,
  }) {
    final parts = <String>[];
    if (useRegex) parts.add('regex');
    if (caseSensitive) parts.add('cs');
    if (globs.isNotEmpty) parts.add('glob=${globs.join(",")}');
    if (contextLines > 0) parts.add('±$contextLines');
    return parts.isEmpty ? '' : ' [${parts.join(", ")}]';
  }

  /// Convert a glob pattern into an anchored `RegExp`. Supports the
  /// three operators agents actually use:
  /// - `**`  : any sequence of segments (including `/`).
  /// - `*`   : any chars within one path segment (no `/`).
  /// - `?`   : exactly one non-`/` character.
  ///
  /// `**/` and `**` are both treated as "any depth"; trailing `/` after
  /// `**` is consumed so `lib/**/*.dart` matches `lib/foo.dart` AND
  /// `lib/a/b/c.dart`. Other regex metacharacters in the input are
  /// escaped — patterns are interpreted as literal text outside the
  /// glob operators above.
  ///
  /// We don't pull in `package:glob` because (a) we only need ~20
  /// lines of converter and (b) the pubspec is already noisy enough.
  static RegExp _globToRegExp(String glob) {
    final buf = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          // ** — consume the second star plus any immediately
          // following `/` so `lib/**/*.dart` matches paths with
          // zero, one, or many intermediate directories.
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') i++;
          buf.write('(?:.*)?');
        } else {
          buf.write('[^/]*');
        }
      } else if (c == '?') {
        buf.write('[^/]');
      } else if ('.+()|^\$\\{}[]'.contains(c)) {
        buf.write(r'\');
        buf.write(c);
      } else {
        buf.write(c);
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }

  /// Tools loaded at runtime from disk. Mutable; replaced wholesale by
  /// [replaceRuntime] when the workspace changes.
  static final List<AgentTool> _runtime = [];

  static List<AgentTool> get all =>
      List.unmodifiable([..._builtin, ..._runtime]);

  static List<AgentTool> get builtin => List.unmodifiable(_builtin);

  static List<AgentTool> get runtime => List.unmodifiable(_runtime);

  static AgentTool? byId(String id) {
    for (final t in _builtin) {
      if (t.id == id) return t;
    }
    for (final t in _runtime) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Drop existing runtime tools and replace with [tools]. Any [tools] entry
  /// whose id collides with a built-in is rejected (built-ins always win)
  /// and logged. Duplicate ids within [tools] keep the first occurrence.
  static void replaceRuntime(List<AgentTool> tools) {
    _runtime.clear();
    final seen = <String>{};
    for (final t in tools) {
      if (_builtin.any((b) => b.id == t.id)) {
        debugPrint(
          'External tool "${t.id}" rejected: collides with built-in tool.',
        );
        continue;
      }
      if (!seen.add(t.id)) {
        debugPrint('External tool "${t.id}" rejected: duplicate id.');
        continue;
      }
      _runtime.add(t);
    }
  }

  static void clearRuntime() {
    _runtime.clear();
  }

  /// Internal helper used by [ExternalToolLoader] so it can spawn child
  /// processes through a single hardened path that mirrors RUN_CMD's
  /// quoting/IO handling. Lives here to keep the loader free of platform
  /// special-cases.
  static Future<String> runExternalCommand({
    required String name,
    required List<String> command,
    required String firstArg,
    required ToolInvocation inv,
  }) async {
    if (inv.workspaceDir == null) {
      return '$name $firstArg: Failed (no workspace open).';
    }
    try {
      final ProcessResult res;
      if (Platform.isWindows) {
        // flutter_pty quoting issues are PTY-only; Process.run uses
        // CreateProcess with proper escaping. Wrapping through cmd.exe /c
        // preserves the user's command exactly as authored, including
        // pipes/redirects in the JSON definition.
        final joined = command.map((s) => _quoteForCmd(s)).join(' ');
        res = await Process.run('cmd.exe', [
          '/c',
          joined,
        ], workingDirectory: inv.workspaceDir);
      } else {
        res = await Process.run(
          command.first,
          command.skip(1).toList(),
          workingDirectory: inv.workspaceDir,
        );
      }
      final stdout = _cap(res.stdout?.toString() ?? '');
      final stderr = _cap(res.stderr?.toString() ?? '');
      return '$name $firstArg:\nSTDOUT:\n$stdout\nSTDERR:\n$stderr';
    } catch (e) {
      return '$name $firstArg: Error: $e';
    }
  }

  /// **Bridge path** for `RUN_CMD`. Routes the command through the
  /// agent terminal bridge: it runs inside a real PTY-backed
  /// `TerminalSession`, output is teed to the agent's view (with ANSI
  /// stripped for the model's regex scanners), and on detach the
  /// session is promoted to a visible tab in the terminal pane.
  ///
  /// Same race semantics as the legacy path:
  ///   - `processDone` wins → return full STDOUT/exit_code (short
  ///     command, no tab ever appeared);
  ///   - `cancelled` wins → kill via PTY (Ctrl+C → SIGINT → SIGKILL),
  ///     return cancelled marker;
  ///   - `softTimeout` or `readyDetected` wins → promote to visible
  ///     tab, return detached marker (process keeps running, user can
  ///     see and close it).
  static Future<String> _runCmdViaBridge(
    String cmd,
    ToolInvocation inv,
  ) async {
    final launcher = inv.agentTerminalLauncher!;
    final outputBuf = StringBuffer();
    final readyDetected = Completer<void>();
    DateTime lastReadyHit = DateTime.fromMillisecondsSinceEpoch(0);

    void scanForReady(String chunk) {
      if (readyDetected.isCompleted) return;
      if (_serverReadyPattern.hasMatch(chunk)) {
        lastReadyHit = DateTime.now();
        Timer(const Duration(milliseconds: 500), () {
          if (readyDetected.isCompleted) return;
          final sinceHit = DateTime.now().difference(lastReadyHit);
          if (sinceHit >= const Duration(milliseconds: 500)) {
            readyDetected.complete();
          }
        });
      }
    }

    AgentRunHandle? handle;
    try {
      handle = await launcher(
        command: cmd,
        workingDirectory: inv.workspaceDir!,
        onOutput: (stripped) {
          outputBuf.write(stripped);
          inv.onOutput?.call(stripped);
          scanForReady(stripped);
        },
      );

      final processDone = handle.exitCode;
      final softTimeout = Future<void>.delayed(_runCmdSoftTimeout);
      final cancelled = inv.cancelToken?.whenCancelled ??
          Completer<void>().future;

      var didCancel = false;
      var didTimeout = false;
      var didReady = false;
      int? exitCode;

      await Future.any<void>([
        processDone.then((c) {
          exitCode = c;
        }),
        cancelled.then((_) {
          didCancel = true;
        }),
        softTimeout.then((_) {
          didTimeout = true;
        }),
        readyDetected.future.then((_) {
          didReady = true;
        }),
      ]);

      if (didCancel) {
        try {
          await handle.kill();
        } catch (_) {}
        handle.dispose();
        final out = _cap(outputBuf.toString());
        return 'RUN_CMD $cmd: cancelled by user.\n'
            'OUTPUT-so-far:\n$out';
      }

      if (didReady || didTimeout) {
        // Detach: promote the session to a visible terminal tab so
        // the user can watch it stream, interact with it, and close
        // it (which kills the PTY → SIGINT to the process group →
        // `node`/`vite`/etc. shut down cleanly). Bookkeeping
        // ownership transfers from the bridge to the pane at this
        // moment.
        handle.promoteToVisible();
        final out = _cap(outputBuf.toString());
        final reason = didReady
            ? 'detected ready signal in output'
            : 'soft-timed-out after ${_runCmdSoftTimeout.inSeconds}s';
        return 'RUN_CMD $cmd: detached, still running '
            '($reason). The process is now a terminal tab labeled '
            '"agent: $cmd" — the user can see it stream and close '
            'the tab to kill it. STDOUT-so-far:\n$out';
      }

      // Normal completion — short command, no tab appeared. Hidden
      // session is auto-disposed by the bridge when its exit
      // completer resolves.
      final out = _cap(outputBuf.toString());
      final tail = exitCode == 0 ? '' : ' (exit code: $exitCode)';
      return 'RUN_CMD $cmd:$tail\nSTDOUT:\n$out';
    } catch (e) {
      try {
        handle?.dispose();
      } catch (_) {}
      return 'RUN_CMD $cmd: Error: $e';
    }
  }

  /// **Legacy path** for `RUN_CMD` when no agent terminal bridge is
  /// attached (test harnesses, non-IDE callers). Same behavior as
  /// before the bridge landed — `Process.start` with stdout/stderr
  /// capture, detach-orphan on soft-timeout. **Has the orphan-process
  /// problem this whole feature was added to fix**, so production
  /// flows should never hit this path.
  static Future<String> _runCmdLegacy(
    String cmd,
    ToolInvocation inv,
  ) async {
    try {
      final process = await Process.start(
        Platform.isWindows ? 'cmd.exe' : 'bash',
        Platform.isWindows ? ['/c', cmd] : ['-c', cmd],
        workingDirectory: inv.workspaceDir,
      );

      final stdoutBuf = StringBuffer();
      final stderrBuf = StringBuffer();
      final readyDetected = Completer<void>();
      DateTime lastReadyHit = DateTime.fromMillisecondsSinceEpoch(0);

      void scanForReady(String chunk) {
        if (readyDetected.isCompleted) return;
        if (_serverReadyPattern.hasMatch(chunk)) {
          lastReadyHit = DateTime.now();
          Timer(const Duration(milliseconds: 500), () {
            if (readyDetected.isCompleted) return;
            final sinceHit = DateTime.now().difference(lastReadyHit);
            if (sinceHit >= const Duration(milliseconds: 500)) {
              readyDetected.complete();
            }
          });
        }
      }

      final stdoutSub = process.stdout
          .transform(const SystemEncoding().decoder)
          .listen((chunk) {
            stdoutBuf.write(chunk);
            inv.onOutput?.call(chunk);
            scanForReady(chunk);
          });
      final stderrSub = process.stderr
          .transform(const SystemEncoding().decoder)
          .listen((chunk) {
            stderrBuf.write(chunk);
            inv.onOutput?.call(chunk);
            scanForReady(chunk);
          });

      final processDone = process.exitCode;
      final softTimeout = Future<void>.delayed(_runCmdSoftTimeout);
      final cancelled = inv.cancelToken?.whenCancelled ??
          Completer<void>().future;

      var didCancel = false;
      var didTimeout = false;
      var didReady = false;
      int? exitCode;

      await Future.any<void>([
        processDone.then((c) {
          exitCode = c;
        }),
        cancelled.then((_) {
          didCancel = true;
        }),
        softTimeout.then((_) {
          didTimeout = true;
        }),
        readyDetected.future.then((_) {
          didReady = true;
        }),
      ]);

      if (didCancel) {
        try {
          process.kill(ProcessSignal.sigterm);
          await Future<void>.delayed(const Duration(milliseconds: 200));
          process.kill(ProcessSignal.sigkill);
        } catch (_) {}
        await stdoutSub.cancel();
        await stderrSub.cancel();
        final out = _cap(stdoutBuf.toString());
        final err = _cap(stderrBuf.toString());
        return 'RUN_CMD $cmd: cancelled by user.\n'
            'STDOUT-so-far:\n$out\nSTDERR-so-far:\n$err';
      }

      if (didReady || didTimeout) {
        final out = _cap(stdoutBuf.toString());
        final err = _cap(stderrBuf.toString());
        final reason = didReady
            ? 'detected ready signal in output'
            : 'soft-timed-out after ${_runCmdSoftTimeout.inSeconds}s';
        return 'RUN_CMD $cmd: detached, still running '
            '($reason). The process keeps running in the '
            'background. STDOUT-so-far:\n$out\n'
            'STDERR-so-far:\n$err';
      }

      await stdoutSub.cancel();
      await stderrSub.cancel();
      final stdout = _cap(stdoutBuf.toString());
      final stderr = _cap(stderrBuf.toString());
      final tail = exitCode == 0 ? '' : ' (exit code: $exitCode)';
      return 'RUN_CMD $cmd:$tail\nSTDOUT:\n$stdout\nSTDERR:\n$stderr';
    } catch (e) {
      return 'RUN_CMD $cmd: Error: $e';
    }
  }

  /// 64KB cap mirrors what most chat UIs can actually display before
  /// turning into glue. Anything longer is almost certainly noise.
  static String _cap(String s) {
    const max = 64 * 1024;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n… (truncated)';
  }

  /// Tighter cap for VERIFY output — analyzer dumps can be long
  /// (tens of thousands of lines on a fresh codebase), and the
  /// model only needs the first chunk to start fixing. 3 KB is
  /// roughly 60 lines of `dart analyze` output, which is
  /// usually enough to pinpoint the highest-priority issues.
  static String _capVerify(String s) {
    const max = 3 * 1024;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n… (verify output truncated; '
        'fix the issues above first, then call VERIFY again to see '
        'the rest)';
  }

  /// Body for the `verify` tool. Auto-detects the workspace toolchain
  /// from marker files and dispatches to the appropriate analyzer.
  /// Returns a stable digest the model can act on — error count first,
  /// then a capped tail of stdout/stderr.
  ///
  /// Detection priority (first match wins):
  ///   1. `pubspec.yaml`                     → `dart analyze`
  ///   2. `tsconfig.json`                    → `tsc --noEmit`
  ///   3. `package.json` (no tsconfig)       → `eslint .`
  ///   4. `pyproject.toml` / `setup.py` /
  ///      `requirements.txt`                 → `ruff check` → fallback
  ///                                           `python -m pyflakes`
  ///   5. anything else                      → "no analyzer detected"
  ///
  /// The 60-second outer timeout is intentionally generous — `dart
  /// analyze` on a multi-thousand-file Flutter project routinely
  /// takes 20-30s on first run because it's also fetching package
  /// summaries. Running through `cmd.exe /c` on Windows mirrors
  /// `runExternalCommand` so PATH-resolved tools (`dart`, `npx`,
  /// `python`) work the same as the user's terminal.
  static Future<String> _executeVerify(ToolInvocation inv) async {
    final ws = inv.workspaceDir;
    if (ws == null || ws.isEmpty) {
      return 'VERIFY: Failed (no workspace open).';
    }
    final root = Directory(ws);
    if (!root.existsSync()) {
      return 'VERIFY: Failed (workspace directory does not exist: $ws).';
    }

    bool hasFile(String name) => File(p.join(ws, name)).existsSync();
    bool hasDir(String name) => Directory(p.join(ws, name)).existsSync();

    // Toolchain dispatch. **Order matters** — `pubspec.yaml` wins
    // over JS markers because Flutter projects routinely include a
    // `package.json` for tooling (e.g. linters, husky) without that
    // implying tsc is the right verifier. Python comes last because
    // its markers (`requirements.txt`) leak into a lot of mixed-
    // language repos as a runner-config file rather than a real
    // Python project.
    if (hasFile('pubspec.yaml')) {
      // `dart analyze` defaults to --fatal-warnings ON and infos
      // NOT fatal, which is exactly what we want for a "is this
      // safe to call done?" check. There is no `--no-fatal-infos`
      // flag — passing it returns exit code 64 ("unrecognised
      // option") and the user sees a confusing analyzer-failed
      // message instead of analyzer output.
      final result = await _runVerify(
        runner: 'dart',
        args: const ['analyze'],
        ws: ws,
        label: 'dart analyze',
      );
      return result ??
          'VERIFY (dart analyze): Failed to launch — `dart` is not on '
              'PATH. Install the Dart/Flutter SDK or run your check '
              'command via RUN_CMD instead.';
    }

    if (hasFile('tsconfig.json')) {
      return await _runJsVerify(
        ws: ws,
        binName: 'tsc',
        binArgs: const ['--noEmit', '--pretty', 'false'],
        action: 'tsc --noEmit',
        hasNodeModules: hasDir('node_modules'),
      );
    }

    if (hasFile('package.json')) {
      return await _runJsVerify(
        ws: ws,
        binName: 'eslint',
        binArgs: const ['.'],
        action: 'eslint .',
        hasNodeModules: hasDir('node_modules'),
      );
    }

    if (hasFile('pyproject.toml') ||
        hasFile('setup.py') ||
        hasFile('requirements.txt')) {
      // ruff is the fast modern default; pyflakes is the universal
      // fallback because it ships with most stdlib-adjacent Python
      // installs (or is one `pip install pyflakes` away). We try
      // ruff first and only fall back if ruff fails to launch
      // (binary missing) — a non-zero exit from ruff is real
      // analyzer output, not a missing-tool error.
      final ruffResult = await _runVerify(
        runner: 'ruff',
        args: const ['check', '.'],
        ws: ws,
        label: 'ruff check',
      );
      if (ruffResult != null) return ruffResult;
      final pyflakesResult = await _runVerify(
        runner: 'python',
        args: const ['-m', 'pyflakes', '.'],
        ws: ws,
        label: 'python -m pyflakes',
      );
      return pyflakesResult ??
          'VERIFY (python -m pyflakes): Failed to launch — neither '
              '`ruff` nor `python -m pyflakes` is available. Install '
              'one (`pip install ruff`) or run your check command '
              'via RUN_CMD instead.';
    }

    return 'VERIFY: no analyzer detected for this workspace '
        '(no pubspec.yaml, tsconfig.json, package.json, '
        'pyproject.toml, setup.py, or requirements.txt at the '
        'root). Use RUN_CMD with the project-specific check '
        'command instead.';
  }

  /// JS/TS analyzer dispatch. Tries, in order:
  ///   1. **Direct local binary** (`node_modules/.bin/<bin>(.cmd|.bat|.ps1)`).
  ///      This is the fastest, most reliable path — bypasses the
  ///      package manager entirely and just runs whatever the user
  ///      already has installed. Works even when `npx` / `pnpm` /
  ///      `yarn` aren't on PATH globally.
  ///   2. **Package-manager exec** (`pnpm exec` / `yarn run` /
  ///      `bun x` / `npx --no-install`), picked from the lockfile
  ///      so we don't try `npx` on a pnpm repo (where dev binaries
  ///      aren't in npx's lookup tree).
  ///   3. **Actionable error** explaining what to do — usually
  ///      "run `<pm> install` first," because the most common cause
  ///      of getting here on a real project is that the user
  ///      cloned it and hasn't installed deps yet.
  ///
  /// **Why this exists:** prior versions hard-jumped to the
  /// package-manager exec, which on Windows would surface as
  /// `'tsc' is not recognized as an internal or external command`
  /// (cmd.exe stderr) every time the user worked on a TS project
  /// without globally-installed `npx`. The same project would have
  /// `node_modules\.bin\tsc.cmd` sitting right there waiting.
  static Future<String> _runJsVerify({
    required String ws,
    required String binName,
    required List<String> binArgs,
    required String action,
    required bool hasNodeModules,
  }) async {
    if (!hasNodeModules) {
      // No `node_modules` = deps haven't been installed. Trying to
      // run the analyzer is guaranteed to fail noisily; tell the
      // user what to do instead. This is the "annoying & useless"
      // failure mode the original implementation kept producing.
      final pm = _detectJsPackageManager(ws);
      return 'VERIFY ($action): no `node_modules/` in this workspace '
          '— dependencies are not installed. Run `$pm install` first, '
          'then call VERIFY again. (Or use RUN_CMD with your '
          'project\'s actual check command.)';
    }

    final localBin = _localJsBin(ws: ws, binName: binName);
    if (localBin != null) {
      final result = await _runVerify(
        runner: localBin,
        args: binArgs,
        ws: ws,
        label: 'node_modules/.bin/$binName ${binArgs.join(' ')}'.trim(),
      );
      if (result != null) return result;
      // Local bin existed but launch claimed missing — extremely
      // unusual (corrupted shim?). Fall through to package-manager
      // exec rather than declaring failure.
    }

    final pmRunner = _jsPackageManagerRunner(ws);
    final pmResult = await _runVerify(
      runner: pmRunner.runner,
      args: [...pmRunner.prefix, binName, ...binArgs],
      ws: ws,
      label: '${pmRunner.label} $binName ${binArgs.join(' ')}'.trim(),
    );
    if (pmResult != null) return pmResult;

    return 'VERIFY ($action): $binName is not installed in this '
        'workspace. The lockfile is `${pmRunner.lockfile}` but '
        '`node_modules/.bin/$binName` is missing. Run '
        '`${pmRunner.label} install` to install it, or use RUN_CMD '
        'with your actual check command.';
  }

  /// Resolve the path to a locally-installed JS binary in the
  /// workspace's `node_modules/.bin/`. Tries each platform-appropriate
  /// extension (Windows ships `.cmd` shims; some setups also have
  /// `.bat` / `.ps1`; POSIX has the bare name). Returns null if none
  /// of the candidates exist on disk — the caller falls back to a
  /// package-manager exec invocation.
  static String? _localJsBin({required String ws, required String binName}) {
    final binDir = p.join(ws, 'node_modules', '.bin');
    final candidates = Platform.isWindows
        ? <String>[
            p.join(binDir, '$binName.cmd'),
            p.join(binDir, '$binName.bat'),
            p.join(binDir, '$binName.ps1'),
            p.join(binDir, binName),
          ]
        : <String>[p.join(binDir, binName)];
    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null;
  }

  /// Pick a friendly package-manager name from the workspace
  /// lockfile. Used purely for user-facing strings ("run `pnpm
  /// install`"); the actual exec dispatch goes through
  /// [_jsPackageManagerRunner].
  static String _detectJsPackageManager(String ws) {
    if (File(p.join(ws, 'pnpm-lock.yaml')).existsSync()) return 'pnpm';
    if (File(p.join(ws, 'yarn.lock')).existsSync()) return 'yarn';
    if (File(p.join(ws, 'bun.lockb')).existsSync() ||
        File(p.join(ws, 'bun.lock')).existsSync()) {
      return 'bun';
    }
    return 'npm';
  }

  /// Resolve the package-manager exec runner to use as a fallback
  /// when the local bin lookup misses. Lockfile-driven so a pnpm
  /// project doesn't get an `npx` invocation that can't see its
  /// `node_modules/.pnpm/` content-addressed store.
  static _JsPmRunner _jsPackageManagerRunner(String ws) {
    if (File(p.join(ws, 'pnpm-lock.yaml')).existsSync()) {
      return _JsPmRunner(
        runner: Platform.isWindows ? 'pnpm.cmd' : 'pnpm',
        prefix: const ['exec', '--'],
        label: 'pnpm exec',
        lockfile: 'pnpm-lock.yaml',
      );
    }
    if (File(p.join(ws, 'yarn.lock')).existsSync()) {
      return _JsPmRunner(
        runner: Platform.isWindows ? 'yarn.cmd' : 'yarn',
        // `yarn run -- <bin>` works on classic Yarn AND Yarn Berry;
        // `yarn exec` differs between the two.
        prefix: const ['run', '--'],
        label: 'yarn run',
        lockfile: 'yarn.lock',
      );
    }
    if (File(p.join(ws, 'bun.lockb')).existsSync() ||
        File(p.join(ws, 'bun.lock')).existsSync()) {
      return _JsPmRunner(
        runner: Platform.isWindows ? 'bun.exe' : 'bun',
        prefix: const ['x', '--'],
        label: 'bun x',
        lockfile: 'bun.lock',
      );
    }
    return _JsPmRunner(
      runner: Platform.isWindows ? 'npx.cmd' : 'npx',
      prefix: const ['--no-install', '--'],
      label: 'npx',
      lockfile: 'package-lock.json',
    );
  }

  /// Spawns the analyzer process. Returns `null` when the binary
  /// is missing (caller falls back to a different runner); returns
  /// a populated digest string on either success OR analyzer error
  /// (a non-zero exit code is *expected* output, not a tool failure
  /// — the whole point of VERIFY is to surface those).
  ///
  /// Output cap is applied per-stream so a noisy stdout cannot
  /// crowd out a one-line stderr that contains the actual error.
  static Future<String?> _runVerify({
    required String runner,
    required List<String> args,
    required String ws,
    required String label,
  }) async {
    try {
      final ProcessResult res;
      if (Platform.isWindows) {
        // Wrap through cmd.exe /c so PATH-resolved shims (`npx.cmd`,
        // `dart.bat`, `python.exe` from a venv) all work. Direct
        // Process.run on `npx` (no extension) refuses to find the
        // .cmd shim on some Windows shells.
        final joined = [runner, ...args].map(_quoteForCmd).join(' ');
        res = await Process.run(
          'cmd.exe',
          ['/c', joined],
          workingDirectory: ws,
        ).timeout(const Duration(seconds: 60));
      } else {
        res = await Process.run(
          runner,
          args,
          workingDirectory: ws,
        ).timeout(const Duration(seconds: 60));
      }

      final stdout = _capVerify(res.stdout?.toString() ?? '');
      final stderr = _capVerify(res.stderr?.toString() ?? '');

      // **cmd.exe missing-binary detection.** When the wrapped
      // command isn't on PATH, cmd.exe itself runs successfully (no
      // ProcessException) and exits with code 1 (or 9009 in some
      // shells), printing one of these signatures to stderr/stdout:
      //   - "'<bin>' is not recognized as an internal or external command"
      //   - "command not found: <bin>"
      //   - "The system cannot find the file specified."
      // Without this check the user kept getting "analyzer reported
      // issues (exit code 1)" with the missing-bin string buried
      // in stderr — confusing because there are no real issues, the
      // tool just isn't installed. Returning null lets the caller
      // fall back (local bin → pkg-mgr exec → actionable message).
      if (res.exitCode != 0 && _looksLikeMissingBinary(stdout, stderr)) {
        return null;
      }

      final clean = stdout.isEmpty && stderr.isEmpty;
      final exitTag = res.exitCode == 0
          ? 'no analyzer errors'
          : 'analyzer reported issues (exit code ${res.exitCode})';
      if (clean && res.exitCode == 0) {
        return 'VERIFY ($label): $exitTag.';
      }
      final body = StringBuffer('VERIFY ($label): $exitTag.\n');
      if (stdout.isNotEmpty) body.writeln('STDOUT:\n$stdout');
      if (stderr.isNotEmpty) body.writeln('STDERR:\n$stderr');
      return body.toString().trimRight();
    } on TimeoutException {
      return 'VERIFY ($label): Timed out after 60s. The analyzer is '
          'unusually slow on this workspace; consider running it '
          'manually via RUN_CMD with a tighter scope.';
    } catch (e) {
      // Heuristic: distinguish "binary missing" (which we want the
      // caller to handle so we can fall back, e.g. ruff → pyflakes)
      // from genuine launch errors. Dart's `Process.run` raises
      // `ProcessException` with a message like "The system cannot
      // find the file specified" / "No such file or directory"
      // when the binary itself isn't on PATH. We return null in
      // that case so the caller can try another runner.
      final msg = e.toString().toLowerCase();
      final missing = msg.contains('no such file') ||
          msg.contains('cannot find the file') ||
          msg.contains('not recognized') ||
          msg.contains('not found');
      if (missing) return null;
      return 'VERIFY ($label): Error launching analyzer: $e';
    }
  }

  /// Pattern-match a process's stdout/stderr for "the binary doesn't
  /// exist" rather than "the binary ran and reported issues." Hits
  /// the well-known signatures from cmd.exe (Windows), bash, zsh,
  /// fish, and the package managers' own missing-bin messages.
  static bool _looksLikeMissingBinary(String stdout, String stderr) {
    final combined = '$stdout\n$stderr'.toLowerCase();
    return combined.contains('is not recognized as an internal or external') ||
        combined.contains('is not recognized as the name of') ||
        combined.contains('command not found') ||
        combined.contains('no such file or directory') ||
        combined.contains('cannot find the file specified') ||
        // npx / pnpm both phrase this as "could not determine ..."
        // when they can't resolve the requested binary.
        combined.contains('could not determine executable to run') ||
        // pnpm-specific: when the requested package isn't installed,
        // pnpm 8+ emits this exact phrase to stderr.
        combined.contains('command "') &&
            combined.contains('" not found');
  }

  /// How long [RUN_CMD] waits before declaring a command "long-running"
  /// and detaching the process so the executor loop can move on.
  /// Tuned by trial: 25s comfortably covers `npm install` /
  /// `flutter pub get` / one-shot builds, while still catching real
  /// daemon-style commands (`npm start`, `vite`) within the soft
  /// window — most dev servers print their "Local: …" banner well
  /// under 10s, so the ready-pattern path will usually win first.
  static const Duration _runCmdSoftTimeout = Duration(seconds: 25);

  /// Lines that mean "the dev server / watcher / REPL is up and
  /// idle". Matched on stdout AND stderr because Vite, webpack-dev-
  /// server and a few others log their banner to stderr. **Case
  /// insensitive**, deliberately broad — over-detection just
  /// triggers an early detach (which is exactly what we want for
  /// daemon-style commands), under-detection falls back to the
  /// 25s soft timeout. The list grows as we observe new patterns
  /// in the wild rather than enumerating every framework upfront.
  static final RegExp _serverReadyPattern = RegExp(
    r'(server\s+is?\s+running|listening\s+on|now\s+listening|'
    r'started\s+server\s+on|local:\s*https?://|ready\s+in\s+\d+|'
    r'compiled\s+successfully|webpack\s+compiled|app\s+listening|'
    r'server\s+started|nest\s+application\s+successfully\s+started|'
    r'serving\s+at\s+http|running\s+at\s+http)',
    caseSensitive: false,
  );

  static String _quoteForCmd(String s) {
    if (s.isEmpty) return '""';
    if (RegExp(r'[\s"&|<>^]').hasMatch(s)) {
      return '"${s.replaceAll('"', '\\"')}"';
    }
    return s;
  }

  /// Used in unit tests to round-trip JSON definitions without disk IO.
  /// Public so [ExternalToolLoader] (in its own file) can call it.
  static AgentTool buildExternal(Map<String, dynamic> def) {
    final id = def['id'] as String;
    final name = (def['name'] as String?) ?? id.toUpperCase();
    final description = (def['description'] as String?) ?? '';
    final syntax = (def['syntax'] as String?) ?? '<<<$name: ...>>>';
    final patternStr = def['pattern'] as String;
    final commandRaw = def['command'] as List<dynamic>;
    final command = commandRaw.cast<String>();
    final requiresApproval = def['requiresApproval'] == true;
    final defaultEnabled = def['defaultEnabled'] == true;
    final pattern = RegExp(patternStr, dotAll: true);

    return AgentTool(
      id: id,
      name: name,
      description: description,
      syntaxExample: syntax,
      pattern: pattern,
      requiresApproval: requiresApproval,
      defaultEnabled: defaultEnabled,
      isExternal: true,
      execute: (inv) async {
        final firstArg = inv.match.groupCount >= 1
            ? (inv.match.group(1) ?? '')
            : '';
        if (requiresApproval) {
          final ok = await inv.approver(name, firstArg);
          if (!ok) return '$name $firstArg: Denied by user.';
        }
        final substituted = command
            .map((segment) => _substituteGroups(segment, inv.match))
            .toList();
        return runExternalCommand(
          name: name,
          command: substituted,
          firstArg: firstArg,
          inv: inv,
        );
      },
    );
  }

  static String _substituteGroups(String segment, RegExpMatch m) {
    return segment.replaceAllMapped(RegExp(r'\$(\d+)'), (g) {
      final i = int.parse(g.group(1)!);
      if (i < 0 || i > m.groupCount) return g.group(0)!;
      return m.group(i) ?? '';
    });
  }
}

/// Convenience: encode a `Map<String, dynamic>` of a tool definition the
/// same way the loader does. Handy for tests.
String encodeToolDefinition(Map<String, dynamic> def) => jsonEncode(def);

/// Resolved JS package-manager exec command for a workspace, used as
/// VERIFY's fallback path when a local `node_modules/.bin` shim isn't
/// present. The split between `runner` (binary to invoke) and `prefix`
/// (args before the user's bin name) lets the caller compose a
/// complete command without knowing which package manager ran.
class _JsPmRunner {
  final String runner;
  final List<String> prefix;
  final String label;
  final String lockfile;
  const _JsPmRunner({
    required this.runner,
    required this.prefix,
    required this.label,
    required this.lockfile,
  });
}
