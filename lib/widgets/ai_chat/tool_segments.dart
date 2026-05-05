import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/chat_controller.dart';
import '../../services/provider_error.dart';
import '../../services/tool_executor.dart';
import '../../services/tool_registry.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Parses an LLM-response body that may contain `<!-- LUMEN_TOOL:... -->`
/// markers (emitted by `ToolExecutor._friendlyReplacement`) into an
/// ordered list of segments. Prose chunks render via `MarkdownBody`;
/// tool segments render as the structured cards / badges in this file.
///
/// Marker grammar (matches the executor's emitter):
///
///     <!-- LUMEN_TOOL:<id>|<percent-encoded-arg>|<status> -->
///
/// `status` is `ok`, `err`, `pending`, or `malformed`. The marker is
/// anchored on its own paragraph (newline padding on both sides) so
/// splitting on it produces clean prose chunks without orphan whitespace
/// at the segment boundary.
///
/// `malformed` is emitted when the tool-shaped block exists in the
/// model's response (opener + closer present) but the inner structure
/// doesn't conform to the strict per-tool regex (e.g. EDIT_FILE
/// without SEARCH/REPLACE). The executor cannot run it, so we surface
/// a warning chip instead of letting the raw body leak through as
/// prose.
sealed class ChatSegment {
  const ChatSegment();
}

class ProseSegment extends ChatSegment {
  final String text;
  const ProseSegment(this.text);
}

/// Model reasoning trace, rendered as a collapsible "Thinking…"
/// section. [isActive] true means the model is still thinking
/// (stream in progress) — shows an animated indicator. When false,
/// the section collapses to a single-line summary the user can expand.
class ThinkingSegment extends ChatSegment {
  final String content;
  final bool isActive;
  const ThinkingSegment({required this.content, this.isActive = false});
}

class ToolSegment extends ChatSegment {
  final String toolId;
  final String firstArg;
  final String status;
  bool get ok => status == 'ok';
  bool get pending => status == 'pending';
  bool get failed => status == 'err';
  bool get malformed => status == 'malformed';

  const ToolSegment({
    required this.toolId,
    required this.firstArg,
    required this.status,
  });
}

/// Cluster of consecutive [ToolSegment]s that share the same
/// action label, tool kind, and final status. Rendered as a single
/// collapsible card so a turn that touched 12 files surfaces as
/// "Read 12 files" rather than 12 stacked rows.
///
/// Grouping happens AFTER raw segment parsing in
/// [parseChatSegments] — see [_groupConsecutiveTools] for the
/// exact bucketing rules. Singletons (groups of 1) and pairs are
/// always passed through as plain [ToolSegment]s; only 3+
/// consecutive same-action calls get grouped, because savings
/// below that threshold don't justify hiding individual paths
/// behind a collapse.
class ToolGroupSegment extends ChatSegment {
  final List<ToolSegment> tools;
  const ToolGroupSegment(this.tools);
}

/// Rendered when the controller swapped a turn's raw error text for a
/// `<!-- LUMEN_ERR:... -->` marker. Drives `_ProviderErrorCard` —
/// surfaces a friendly title/body and a Retry chip that re-runs the
/// last user prompt without losing context.
class ProviderErrorSegment extends ChatSegment {
  final ProviderError error;
  const ProviderErrorSegment(this.error);
}

/// One-pass marker → segment list. Text outside markers becomes
/// `ProseSegment`s; tool markers become `ToolSegment`s; provider-error
/// markers become `ProviderErrorSegment`s. Adjacent prose chunks are
/// NOT merged — splitting on `\n<!-- ... -->\n` already removes the
/// surrounding newlines, so we just trust the regex.
///
/// Both marker families are gathered with a single combined matcher
/// so a chat turn that contains BOTH (rare but possible: the agent
/// fired a tool, the next iteration overloaded the provider) renders
/// in source order — tool card, prose, error card.
///
/// After raw parsing, runs of 3+ consecutive [ToolSegment]s sharing
/// the same action label / kind / status get collapsed into a single
/// [ToolGroupSegment]. This is what turns "10 file reads" into a
/// single expandable "Read 10 files" card instead of a stack of 10.
List<ChatSegment> parseChatSegments(String content) {
  final raw = <ChatSegment>[];

  // ── Phase 1: Extract thinking blocks first ──
  // They sit before/between tool markers. We replace them with a
  // placeholder so the tool regex doesn't trip over them, then
  // re-inject as ThinkingSegments at the right positions.
  final thinkRe = RegExp(
    r'<!-- LUMEN_THINKING(\s+active)? -->\n([\s\S]*?)\n<!-- /LUMEN_THINKING -->',
  );
  final thinkMatches = thinkRe.allMatches(content).toList();
  // Replace thinking blocks with unique tokens we can split on later.
  var processed = content;
  for (var t = thinkMatches.length - 1; t >= 0; t--) {
    final m = thinkMatches[t];
    processed = processed.replaceRange(
      m.start, m.end, '\u0000THINK:$t\u0000',
    );
  }

  // Combined matcher — alternation between LUMEN_TOOL and LUMEN_ERR.
  // Group 1-3 = tool fields; group 4-5 = error fields. Either
  // half is null for any given match.
  final re = RegExp(
    r'<!--\s*LUMEN_TOOL:([a-z_]+)\|([^|]*)\|(ok|err|pending|malformed)\s*-->'
    r'|'
    r'<!--\s*LUMEN_ERR:([a-z_]+)\|([^|]*)\s*-->'
    r'|'
    r'\x00THINK:(\d+)\x00',
    multiLine: true,
  );
  int cursor = 0;
  for (final m in re.allMatches(processed)) {
    if (m.start > cursor) {
      final prose = processed.substring(cursor, m.start);
      if (prose.trim().isNotEmpty) {
        raw.add(ProseSegment(prose));
      }
    }
    if (m.group(1) != null) {
      raw.add(
        ToolSegment(
          toolId: m.group(1)!,
          firstArg: Uri.decodeComponent(m.group(2)!),
          status: m.group(3)!,
        ),
      );
    } else if (m.group(4) != null) {
      final err = ProviderError.fromMarkerMatch(m);
      if (err != null) raw.add(ProviderErrorSegment(err));
    } else if (m.group(6) != null) {
      final idx = int.parse(m.group(6)!);
      if (idx < thinkMatches.length) {
        final tm = thinkMatches[idx];
        final isActive = tm.group(1) != null;
        final thinkContent = tm.group(2) ?? '';
        raw.add(ThinkingSegment(content: thinkContent, isActive: isActive));
      }
    }
    cursor = m.end;
  }
  if (cursor < processed.length) {
    final tail = processed.substring(cursor);
    if (tail.trim().isNotEmpty) {
      raw.add(ProseSegment(tail));
    }
  }
  return _groupConsecutiveTools(raw);
}

/// Walk a flat segment list and collapse runs of consecutive
/// [ToolSegment]s into [ToolGroupSegment]s when they meet the
/// grouping bar:
///
/// - **Same action label** (`Read`, `Edited`, `Searched`, …). Mixing
///   "Read foo" with "Edited foo" stays as two segments.
/// - **Same `_ToolKind`**. fileOps and inspections never group
///   across boundaries.
/// - **Status is consistent**: pending tools never group with
///   completed ones, errored tools form their own groups so the
///   bad-news count stays visible at a glance.
/// - **Run length ≥ 3**. Two-of-a-kind stays as two cards — the
///   collapsed header + an expand interaction is heavier than just
///   showing the second card.
/// - **Commands (RUN_CMD) never group.** A shell command is
///   meaningful by itself; collapsing them would hide the actual
///   command line.
List<ChatSegment> _groupConsecutiveTools(List<ChatSegment> input) {
  if (input.isEmpty) return input;
  final out = <ChatSegment>[];
  var i = 0;
  while (i < input.length) {
    final seg = input[i];
    if (seg is! ToolSegment || !_groupable(seg)) {
      out.add(seg);
      i++;
      continue;
    }
    final action = _actionLabel(seg);
    final kind = _kindFor(seg.toolId);
    final status = seg.status;
    final batch = <ToolSegment>[seg];
    var j = i + 1;
    while (j < input.length) {
      final next = input[j];
      if (next is! ToolSegment) break;
      if (!_groupable(next)) break;
      if (_kindFor(next.toolId) != kind) break;
      if (next.status != status) break;
      if (_actionLabel(next) != action) break;
      batch.add(next);
      j++;
    }
    if (batch.length >= 3) {
      out.add(ToolGroupSegment(List.unmodifiable(batch)));
    } else {
      out.addAll(batch);
    }
    i = j;
  }
  return out;
}

/// Tools eligible for collapsing into a [ToolGroupSegment]. We
/// keep `command`-kind tools out — RUN_CMD carries meaningful
/// payload that the user wants to scan, not bury.
bool _groupable(ToolSegment seg) {
  final kind = _kindFor(seg.toolId);
  return kind == _ToolKind.fileOp || kind == _ToolKind.inspection;
}

/// Strip markers from a body and replace with the friendly plain-text
/// rendering — used by the per-message Copy chip so paste-to-other-app
/// is readable instead of dumping HTML comments. Both marker families
/// are stripped in one pass.
String stripMarkersForCopy(String content) {
  final toolRe = RegExp(
    r'<!--\s*LUMEN_TOOL:([a-z_]+)\|([^|]*)\|(ok|err|pending|malformed)\s*-->',
    multiLine: true,
  );
  final errRe = ProviderError.markerRegExp;
  var s = content.replaceAllMapped(toolRe, (m) {
    final id = m.group(1)!;
    final arg = Uri.decodeComponent(m.group(2)!);
    final status = m.group(3)!;
    final ok = status == 'ok' || status == 'pending';
    if (status == 'malformed') {
      return '($id `$arg` malformed — not executed)';
    }
    return ToolExecutor.friendlyTextForMarker(id, arg, ok);
  });
  s = s.replaceAllMapped(errRe, (m) {
    final err = ProviderError.fromMarkerMatch(m);
    return err != null ? ProviderError.friendlyTextFor(err) : '';
  });
  // Strip thinking blocks — copy gets the answer, not the trace.
  s = s.replaceAll(
    RegExp(r'<!-- LUMEN_THINKING[^>]* -->\n[\s\S]*?\n<!-- /LUMEN_THINKING -->\n*'),
    '',
  );
  return s;
}

/// Render-only cleanup for the live assistant message while it is still
/// streaming. Tool execution still receives the raw model output after the
/// stream completes; this only hides noisy `<<<...>>>` syntax from the UI and
/// swaps it for the same card markers the final executor pass emits.
///
/// Three layered passes, ordered specifically so each catches what
/// the previous missed:
///
/// 1. **Per-tool complete-pattern matching.** `tool.pattern.allMatches`
///    on every registered tool. Replaces fully-formed calls with
///    `pending` markers (after the executor runs the post-stream
///    pass these become `ok`/`err`).
/// 2. **Salvage pass for malformed blocks.** Catches the case where
///    BOTH the opener and the closer are present but the inner
///    structure rejected step 1's strict regex (e.g. an EDIT_FILE
///    body without SEARCH/REPLACE markers, or extra blank lines
///    breaking the literal `\n` separators). Without this pass the
///    entire raw body — often hundreds of lines of code — leaks
///    through as prose into the chat. Replaces with a `malformed`
///    marker so the user sees the failed attempt without the dump.
/// 3. **Trailing incomplete openers.** A `<<<EDIT_FILE: …>>>` at the
///    tail of the stream with no closer yet (still typing). Replaces
///    with a `pending` marker so the partial body stays hidden until
///    the close arrives or the stream ends.
String streamingToolPreview(String rawContent) {
  var content = _normalizeForToolPreview(rawContent);

  for (final tool in ToolRegistry.all) {
    final matches = tool.pattern.allMatches(content).toList();
    for (final match in matches) {
      final firstArg = (match.groupCount >= 1 ? match.group(1) : '') ?? '';
      content = content.replaceAll(
        match.group(0)!,
        _toolMarker(tool.id, firstArg, 'pending'),
      );
    }
  }

  content = _replaceMalformedBlockTool(content);
  content = _replaceIncompleteBlockTool(content);
  content = _replaceIncompleteInlineTool(content);
  return content;
}

/// Catch tool-shaped blocks where opener AND closer are both present
/// but step 1's strict per-tool regex rejected them. Replaces the
/// entire span (including the body) with a `malformed` marker so
/// the raw block — which often contains the exact code the model
/// was trying to insert — never reaches `MarkdownBody`.
///
/// **The bug this fixes:** the strict EDIT_FILE pattern requires
/// `<<<EDIT_FILE: x>>>\n<<<SEARCH>>>\n…\n<<<REPLACE>>>\n…\n<<<END_EDIT>>>`.
/// When the model emits an EDIT_FILE that's structurally off (no
/// SEARCH/REPLACE markers, surplus blank lines, or even just
/// `\r\n` line endings the literal `\n` doesn't match), step 1
/// fails. The previous fallback only fired when the closer was
/// missing — so a malformed but "complete-looking" block leaked
/// the entire raw body into the rendered chat as prose. Reported
/// in user feedback as "the model just dumps code into the chat".
String _replaceMalformedBlockTool(String content) {
  final salvage = RegExp(
    r'<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):\s*(.*?)\s*>>>'
    r'(?:.*?)'
    r'<<<END_(?:FILE|EDIT|APPEND)>>>',
    dotAll: true,
  );
  return content.replaceAllMapped(salvage, (m) {
    final toolName = m.group(1)!;
    final firstArg = (m.group(2) ?? '').trim();
    final id = _toolIdForName(toolName);
    if (id == null) return m.group(0)!;
    return _toolMarker(id, firstArg, 'malformed');
  });
}

String _toolMarker(String toolId, String firstArg, String status) {
  final encoded = Uri.encodeComponent(firstArg);
  return '\n<!-- LUMEN_TOOL:$toolId|$encoded|$status -->\n';
}

String _normalizeForToolPreview(String input) {
  var s = input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  s = s.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
  const angleMap = {
    '\u00AB': '<',
    '\u00BB': '>',
    '\u276E': '<',
    '\u276F': '>',
    '\uFF1C': '<',
    '\uFF1E': '>',
    '\u2329': '<',
    '\u232A': '>',
    '\u3008': '<',
    '\u3009': '>',
  };
  angleMap.forEach((from, to) {
    s = s.replaceAll(from, to);
  });
  return s;
}

String _replaceIncompleteBlockTool(String content) {
  final opener = RegExp(
    r'<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):\s*(.*?)\s*>>>',
    dotAll: true,
  );
  final matches = opener.allMatches(content).toList();
  if (matches.isEmpty) return content;

  final match = matches.last;
  final toolName = match.group(1)!;
  final firstArg = match.group(2) ?? '';
  final id = _toolIdForName(toolName);
  if (id == null) return content;

  final tail = content.substring(match.start);
  final hasEnd = switch (toolName) {
    'CREATE_FILE' => tail.contains('<<<END_FILE>>>'),
    'APPEND_FILE' => tail.contains('<<<END_APPEND>>>'),
    _ => tail.contains('<<<END_EDIT>>>'),
  };
  if (hasEnd) return content;

  return '${content.substring(0, match.start)}${_toolMarker(id, firstArg, 'pending')}';
}

String _replaceIncompleteInlineTool(String content) {
  final match = RegExp(
    r'<<<([A-Z_]+)(?::\s*([^>\n]*))?$',
    multiLine: false,
  ).firstMatch(content);
  if (match == null) return content;

  final id = _toolIdForName(match.group(1)!);
  if (id == null) return content;
  final firstArg = match.group(2) ?? '';
  return '${content.substring(0, match.start)}${_toolMarker(id, firstArg, 'pending')}';
}

String? _toolIdForName(String toolName) {
  for (final tool in ToolRegistry.all) {
    if (tool.name == toolName) return tool.id;
  }
  return null;
}

// ─── classification ──────────────────────────────────────────────

/// Classifies tool ids into the three visual buckets the chat panel
/// renders. Add new tools here when adding to ToolRegistry — anything
/// uncategorised falls through to `_inspection` (the safest default
/// since inspection badges are non-destructive in appearance).
enum _ToolKind { fileOp, command, inspection }

_ToolKind _kindFor(String toolId) {
  switch (toolId) {
    case 'create_file':
    case 'edit_file':
    case 'multi_edit':
    case 'append_file':
    case 'move_file':
    case 'read_file':
    case 'read_file_range':
    case 'delete_file':
      return _ToolKind.fileOp;
    case 'run_cmd':
      return _ToolKind.command;
    default:
      return _ToolKind.inspection;
  }
}

/// One-line action label per tool — what the *card title* says.
String _actionLabel(ToolSegment segment) {
  if (segment.pending) return _pendingActionLabel(segment.toolId);
  if (segment.malformed) return S.toolMalformedLabel;
  final toolId = segment.toolId;
  final ok = segment.ok;
  if (!ok) {
    switch (toolId) {
      case 'edit_file':
      case 'multi_edit':
        return 'Edit failed';
      case 'create_file':
        return 'Create failed';
      case 'delete_file':
        return 'Delete failed';
      case 'move_file':
        return 'Move failed';
      case 'read_file':
      case 'read_file_range':
        return 'Read failed';
      case 'run_cmd':
        return 'Command failed';
      case 'append_file':
        return 'Append failed';
      default:
        return 'Failed';
    }
  }
  switch (toolId) {
    case 'create_file':
      return 'Created';
    case 'edit_file':
      return 'Edited';
    case 'multi_edit':
      return 'Multi-edited';
    case 'append_file':
      return 'Appended';
    case 'move_file':
      return 'Moved';
    case 'read_file':
    case 'read_file_range':
      return 'Read';
    case 'delete_file':
      return 'Deleted';
    case 'tree':
      return 'Tree';
    case 'list_dir':
      return 'Listed';
    case 'search_text':
      return 'Searched';
    case 'find_file':
      return 'Found';
    case 'glob':
      return 'Glob';
    case 'git_status':
      return 'git status';
    case 'git_diff':
      return 'git diff';
    case 'run_cmd':
      return 'Ran';
    case 'verify':
      return 'Verified';
    default:
      return toolId;
  }
}

String _pendingActionLabel(String toolId) {
  switch (toolId) {
    case 'create_file':
      return S.toolPendingCreate;
    case 'edit_file':
    case 'multi_edit':
      return S.toolPendingEdit;
    case 'append_file':
      return S.toolPendingAppend;
    case 'move_file':
      return S.toolPendingMove;
    case 'read_file':
    case 'read_file_range':
      return S.toolPendingRead;
    case 'delete_file':
      return S.toolPendingDelete;
    case 'search_text':
    case 'find_file':
    case 'glob':
      return S.toolPendingSearch;
    case 'run_cmd':
      return S.toolPendingRun;
    default:
      return S.toolPendingInspect;
  }
}

/// File-extension → icon mapping. Falls back to a generic file icon
/// for unknown extensions. Kept small on purpose — we don't need an
/// icon for every language, just enough to make the most common
/// project files distinguishable at a glance.
IconData _iconForFile(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.dart':
    case '.js':
    case '.jsx':
    case '.ts':
    case '.tsx':
    case '.py':
    case '.rb':
    case '.go':
    case '.rs':
    case '.java':
    case '.kt':
    case '.swift':
    case '.c':
    case '.cpp':
    case '.h':
      return Icons.code;
    case '.json':
    case '.yaml':
    case '.yml':
    case '.toml':
    case '.ini':
    case '.conf':
      return Icons.data_object;
    case '.md':
    case '.txt':
    case '.rst':
      return Icons.article_outlined;
    case '.html':
    case '.htm':
    case '.xml':
      return Icons.html;
    case '.css':
    case '.scss':
    case '.sass':
    case '.less':
      return Icons.style;
    case '.png':
    case '.jpg':
    case '.jpeg':
    case '.gif':
    case '.webp':
    case '.svg':
      return Icons.image_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

// ─── widgets ─────────────────────────────────────────────────────

/// Public dispatcher — picks the right widget per `_ToolKind` and
/// status. Malformed segments are routed to a dedicated warning
/// card regardless of the tool's normal kind: a malformed EDIT_FILE
/// shouldn't render as a clickable file card pretending it landed.
class ToolSegmentView extends StatelessWidget {
  final ToolSegment segment;
  const ToolSegmentView({super.key, required this.segment});

  @override
  Widget build(BuildContext context) {
    if (segment.malformed) {
      return _MalformedToolCard(segment: segment);
    }
    switch (_kindFor(segment.toolId)) {
      case _ToolKind.fileOp:
        return _FileToolCard(segment: segment);
      case _ToolKind.command:
        return _CommandToolCard(segment: segment);
      case _ToolKind.inspection:
        return _InspectionBadge(segment: segment);
    }
  }
}

/// Public dispatcher for grouped tool runs. Renders the collapsed
/// `Read 12 files` summary header; expanding shows each member as
/// the same widget [ToolSegmentView] would have produced for it
/// solo.
class ToolGroupView extends StatefulWidget {
  final ToolGroupSegment group;
  const ToolGroupView({super.key, required this.group});

  @override
  State<ToolGroupView> createState() => _ToolGroupViewState();
}

class _ToolGroupViewState extends State<ToolGroupView> {
  bool _expanded = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final tools = widget.group.tools;
    final first = tools.first;
    final kind = _kindFor(first.toolId);
    final accent = first.failed
        ? DuckColors.stateError
        : (first.pending ? DuckColors.accentCyan : DuckColors.accentMint);
    final headerIcon = kind == _ToolKind.fileOp
        ? _iconForFileGroup(tools)
        : _iconForInspection(first.toolId);
    final action = _actionLabel(first);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: AnimatedContainer(
                duration: DuckMotion.fast,
                padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
                decoration: BoxDecoration(
                  color: _hover ? DuckColors.bgRaised : DuckColors.bgDeeper,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                  border: Border.all(
                    color: _hover
                        ? DuckColors.accentCyan.withValues(alpha: 0.4)
                        : DuckColors.glassSeam,
                    width: 0.5,
                  ),
                ),
                child: Row(
                  children: [
                    AnimatedRotation(
                      duration: DuckMotion.fast,
                      turns: _expanded ? 0.25 : 0.0,
                      child: const Icon(
                        Icons.chevron_right,
                        size: 14,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(headerIcon, size: 14, color: DuckColors.fgMuted),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.toolGroupTitle(action, tools.length),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _ToolStatusBadge(
                      label: '${tools.length}',
                      accent: accent,
                      pending: first.pending,
                    ),
                  ],
                ),
              ),
            ),
          ),
          AnimatedSize(
            duration: DuckMotion.fast,
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(left: 12, top: 2),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < tools.length; i++)
                          KeyedSubtree(
                            key: ValueKey(
                              'group-member-${tools[i].toolId}-${tools[i].firstArg}-$i',
                            ),
                            child: ToolSegmentView(segment: tools[i]),
                          ),
                      ],
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  /// Pick a representative icon for a file-group header. Uses the
  /// most common extension in the group; falls back to the generic
  /// "file" glyph when the group spans many extensions.
  IconData _iconForFileGroup(List<ToolSegment> tools) {
    final counts = <IconData, int>{};
    for (final t in tools) {
      final icon = _iconForFile(t.firstArg);
      counts[icon] = (counts[icon] ?? 0) + 1;
    }
    IconData? best;
    var bestCount = 0;
    counts.forEach((icon, count) {
      if (count > bestCount) {
        bestCount = count;
        best = icon;
      }
    });
    return best ?? Icons.insert_drive_file_outlined;
  }
}

/// Shared inspection-icon lookup used by both the singleton
/// [_InspectionBadge] and the grouped [ToolGroupView] header.
IconData _iconForInspection(String toolId) {
  switch (toolId) {
    case 'tree':
      return Icons.account_tree_outlined;
    case 'list_dir':
      return Icons.folder_open_outlined;
    case 'search_text':
      return Icons.search;
    case 'find_file':
    case 'glob':
      return Icons.find_in_page_outlined;
    case 'git_status':
    case 'git_diff':
      return Icons.commit_outlined;
    default:
      return Icons.visibility_outlined;
  }
}

/// Friendly card rendered in place of a raw provider error. Shows
/// the kind / title / body, a Retry chip (only when retryable), and
/// an expandable detail panel for the original raw error string.
///
/// Retry calls [ChatController.retryLastTurn] which deletes the
/// failed assistant message and re-runs the same prompt against the
/// currently-selected model — no new user message is appended.
class ProviderErrorCard extends StatefulWidget {
  final ProviderError error;
  const ProviderErrorCard({super.key, required this.error});

  @override
  State<ProviderErrorCard> createState() => _ProviderErrorCardState();
}

class _ProviderErrorCardState extends State<ProviderErrorCard> {
  bool _showDetails = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    // Auto-expand details for kinds where the canned body is generic
    // enough that the raw error is what the user actually needs to
    // see. Saves a click on the failure modes that previously
    // rendered as a "barely-visible dark grey square" — the user
    // had to copy the bubble to find out it was a 400.
    final kind = widget.error.kind;
    _showDetails =
        kind == ProviderErrorKind.badRequest ||
        kind == ProviderErrorKind.unknown ||
        kind == ProviderErrorKind.serverError;
  }

  /// One-line excerpt of the raw detail for the always-visible
  /// summary row. Strips the friendly preamble that the controller
  /// added (e.g. `Anthropic API error (400):`) so what remains is
  /// the actually-useful provider-side message.
  String _detailExcerpt(String raw) {
    var s = raw.trim();
    s = s.replaceFirst(
      RegExp(
        r'^(?:Error[:\s]+)?'
        r'(?:Anthropic|Gemini|GitHub Models|OpenAI|Ollama)'
        r'\s*API error\s*\(\d+\)\s*:\s*',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length <= 180) return s;
    return '${s.substring(0, 177)}…';
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      final state = context.read<AppState>();
      await state.chat.retryLastTurn(
        workspacePath: state.currentDirectory,
        activeFilePath: state.activeFile?.path,
        openFilePaths: state.openFiles.map((f) => f.path).toList(),
      );
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = widget.error;
    // `badRequest` is the same severity as auth/notFound from the
    // user's perspective ("this won't work, do something") so it
    // shares the red accent rather than the amber one used for
    // transient cases.
    final accent =
        err.kind == ProviderErrorKind.unauthorized ||
            err.kind == ProviderErrorKind.notFound ||
            err.kind == ProviderErrorKind.badRequest
        ? DuckColors.stateError
        : DuckColors.stateWarn;
    final excerpt = _detailExcerpt(err.rawDetail);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: DuckColors.bgDeeper,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border(
            left: BorderSide(color: accent, width: 2),
            top: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
            right: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
            bottom: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconFor(err.kind), size: 14, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    err.title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: DuckColors.fgPrimary,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              err.body,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.4,
              ),
            ),
            // Always-visible one-line excerpt of the actual provider
            // message. Without this the card was a faint warn-bordered
            // rectangle that felt empty unless the user expanded
            // details — Opus 4.7's 400 was the exact failure mode
            // ("dark grey square" per user report). We strip the
            // generic `<Provider> API error (NNN):` preamble so what
            // remains is the substantive bit.
            if (excerpt.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(
                excerpt,
                style: const TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 11,
                  color: DuckColors.fgPrimary,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (err.retryable)
                  _ErrorChip(
                    icon: Icons.refresh,
                    label: S.providerErrorRetry,
                    accent: DuckColors.accentCyan,
                    onTap: _retrying ? null : _retry,
                    busy: _retrying,
                  ),
                if (err.kind == ProviderErrorKind.unauthorized ||
                    err.kind == ProviderErrorKind.notFound) ...[
                  if (err.retryable) const SizedBox(width: 6),
                  _ErrorChip(
                    icon: Icons.settings_outlined,
                    label: S.providerErrorOpenSettings,
                    accent: DuckColors.fgMuted,
                    onTap: () => context.read<AppState>().openSettingsTab(
                      category: 'general',
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                _ErrorChip(
                  icon: _showDetails ? Icons.expand_less : Icons.expand_more,
                  label: _showDetails
                      ? S.providerErrorHideDetails
                      : S.providerErrorShowDetails,
                  accent: DuckColors.fgMuted,
                  onTap: () => setState(() => _showDetails = !_showDetails),
                ),
              ],
            ),
            if (_showDetails) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: DuckColors.bgDeepest,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    err.rawDetail,
                    style: const TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 11,
                      color: DuckColors.fgMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ProviderErrorKind kind) {
    switch (kind) {
      case ProviderErrorKind.overloaded:
      case ProviderErrorKind.serverError:
        return Icons.cloud_off_outlined;
      case ProviderErrorKind.rateLimited:
        return Icons.speed_outlined;
      case ProviderErrorKind.timeout:
        return Icons.timer_off_outlined;
      case ProviderErrorKind.unauthorized:
        return Icons.lock_outline;
      case ProviderErrorKind.badRequest:
        return Icons.report_gmailerrorred_outlined;
      case ProviderErrorKind.notFound:
        return Icons.help_outline;
      case ProviderErrorKind.network:
        return Icons.wifi_off_outlined;
      case ProviderErrorKind.unknown:
        return Icons.error_outline;
    }
  }
}

class _ErrorChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback? onTap;
  final bool busy;
  const _ErrorChip({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.busy = false,
  });

  @override
  State<_ErrorChip> createState() => _ErrorChipState();
}

class _ErrorChipState extends State<_ErrorChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: _hover && !disabled
                ? widget.accent.withValues(alpha: 0.12)
                : DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: _hover && !disabled
                  ? widget.accent.withValues(alpha: 0.55)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.busy)
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: DuckColors.accentCyan,
                  ),
                )
              else
                Icon(widget.icon, size: 12, color: widget.accent),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: disabled ? DuckColors.fgSubtle : widget.accent,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cursor-style file card. Icon + filename + action label, hover
/// reveals a "click to open" affordance, click opens the file in
/// the editor (resolves relative-to-workspace via `AppState`).
class _FileToolCard extends StatefulWidget {
  final ToolSegment segment;
  const _FileToolCard({required this.segment});

  @override
  State<_FileToolCard> createState() => _FileToolCardState();
}

class _FileToolCardState extends State<_FileToolCard> {
  bool _hover = false;

  String _targetPath() {
    final s = widget.segment;
    String relPath = s.firstArg.trim();
    if (s.toolId == 'move_file' && relPath.contains('->')) {
      relPath = relPath.split('->').last.trim();
    }
    // Some tools encode line ranges (read_file_range: "path:S-E");
    // chop off everything after the first colon for path resolution.
    final colonIdx = relPath.indexOf(':');
    if (colonIdx > 0) relPath = relPath.substring(0, colonIdx);
    return relPath.trim();
  }

  Future<void> _openFile(BuildContext context) async {
    final s = widget.segment;
    if (s.pending || s.toolId == 'delete_file') return;
    final relPath = _targetPath();
    if (relPath.isEmpty) return;
    final state = context.read<AppState>();
    final ws = state.currentDirectory;
    if (ws == null) return; // no workspace, nothing to open
    final abs = p.isAbsolute(relPath) ? relPath : p.join(ws, relPath);
    final f = File(abs);
    if (!await f.exists()) return;
    await state.openFile(f);
    state.ideActions.revealFileExplorerPath(f.path);
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.segment;
    final action = _actionLabel(s);
    final targetPath = _targetPath();
    final icon = _iconForFile(targetPath);
    final filename = targetPath.isEmpty ? s.firstArg : p.basename(targetPath);
    final dir = targetPath.isEmpty ? '' : p.dirname(targetPath);
    final accent = s.pending
        ? DuckColors.accentCyan
        : s.ok
        ? DuckColors.accentMint
        : DuckColors.stateError;
    final openable = !s.pending && s.toolId != 'delete_file';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: MouseRegion(
        cursor: openable ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: openable ? () => _openFile(context) : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
            decoration: BoxDecoration(
              color: _hover ? DuckColors.bgRaised : DuckColors.bgDeeper,
              borderRadius: BorderRadius.circular(DuckTheme.radiusM),
              border: Border.all(
                color: _hover
                    ? DuckColors.accentCyan.withValues(alpha: 0.4)
                    : DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            child: Row(
              children: [
                Icon(icon, size: 14, color: DuckColors.fgMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final stackBadge = constraints.maxWidth < 120;
                      final title = Text(
                        filename,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: DuckTheme.monoFont,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: DuckColors.fgPrimary,
                        ),
                      );
                      final badge = _ToolStatusBadge(
                        label: action,
                        accent: accent,
                        pending: s.pending,
                      );
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (stackBadge) ...[
                            title,
                            const SizedBox(height: 3),
                            badge,
                          ] else
                            Row(
                              children: [
                                Expanded(child: title),
                                const SizedBox(width: 8),
                                badge,
                              ],
                            ),
                          if (dir.isNotEmpty && dir != '.') ...[
                            const SizedBox(height: 2),
                            Text(
                              dir,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontFamily: DuckTheme.monoFont,
                                fontSize: 10.5,
                                color: DuckColors.fgFaint,
                                height: 1.2,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ),
                if (openable)
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 120),
                    opacity: _hover ? 1.0 : 0.0,
                    child: const Padding(
                      padding: EdgeInsets.only(left: 6),
                      child: Icon(
                        Icons.open_in_new,
                        size: 12,
                        color: DuckColors.accentCyan,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Terminal-style card for shell commands. Slightly taller than the
/// file card because the command itself is the payload — needs more
/// horizontal room for typical command lines.
class _CommandToolCard extends StatelessWidget {
  final ToolSegment segment;
  const _CommandToolCard({required this.segment});

  @override
  Widget build(BuildContext context) {
    final accent = segment.pending
        ? DuckColors.accentCyan
        : segment.ok
        ? DuckColors.accentMint
        : DuckColors.stateError;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 12, 8),
        decoration: BoxDecoration(
          color: DuckColors.bgDeepest,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        ),
        child: Row(
          children: [
            const Icon(Icons.terminal, size: 14, color: DuckColors.fgMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                segment.firstArg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 12,
                  color: DuckColors.fgPrimary,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 8),
            _ToolStatusBadge(
              label: _actionLabel(segment),
              accent: accent,
              pending: segment.pending,
            ),
          ],
        ),
      ),
    );
  }
}

/// Tiny accent-tinted pill that doubles as the status indicator
/// inside file/command cards. Adds a subtle 1Hz breath to the
/// background opacity when [pending] is true so the user can see
/// at a glance which tools are still in flight, without the
/// visual cost of a full spinner / shimmer overlay.
///
/// Cost: one [AnimationController] only when pending. In the
/// finished-message case the badge is a plain [StatelessWidget]
/// equivalent (no ticker), so persisted history doesn't allocate
/// hundreds of controllers for old turns.
class _ToolStatusBadge extends StatefulWidget {
  final String label;
  final Color accent;
  final bool pending;

  const _ToolStatusBadge({
    required this.label,
    required this.accent,
    this.pending = false,
  });

  @override
  State<_ToolStatusBadge> createState() => _ToolStatusBadgeState();
}

class _ToolStatusBadgeState extends State<_ToolStatusBadge>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;

  @override
  void initState() {
    super.initState();
    if (widget.pending) _ensureController();
  }

  @override
  void didUpdateWidget(covariant _ToolStatusBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pending && _ctrl == null) {
      _ensureController();
    } else if (!widget.pending && _ctrl != null) {
      _ctrl?.dispose();
      _ctrl = null;
    }
  }

  void _ensureController() {
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl?.dispose();
    super.dispose();
  }

  Widget _pill(double alpha) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: widget.accent.withValues(alpha: alpha),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Text(
        widget.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: widget.accent,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    if (ctrl == null) return _pill(0.15);
    return AnimatedBuilder(
      animation: ctrl,
      builder: (_, _) {
        final t = Curves.easeInOut.transform(ctrl.value);
        // Breathe between 0.10 and 0.28 — wide enough to read as
        // "alive", not so wide it strobes.
        final alpha = 0.10 + (0.18 * t);
        return _pill(alpha);
      },
    );
  }
}

/// Compact pill for read-only inspection ops. Doesn't deserve a full
/// card — these are "the agent looked at something", not "the agent
/// changed something". When 3+ consecutive inspections share the
/// same action, [parseChatSegments] collapses them into a
/// [ToolGroupSegment] and renders the [ToolGroupView] header
/// instead, so a long search-spam turn doesn't blow up the column.
class _InspectionBadge extends StatelessWidget {
  final ToolSegment segment;
  const _InspectionBadge({required this.segment});

  @override
  Widget build(BuildContext context) {
    final accent = segment.pending
        ? DuckColors.accentCyan
        : segment.ok
        ? DuckColors.fgSubtle
        : DuckColors.stateError;
    // The badge is rendered inside the agent message bubble's Column,
    // which gives it the full bubble width as its max constraint.
    // We use `Align` so the pill shrinks to its content when there's
    // room — but the inner `firstArg` text is `Flexible` with
    // ellipsis, so a long argument string (e.g. a SEARCH_TEXT query
    // that's a sentence) gets truncated to fit the available bubble
    // width instead of overflowing horizontally. Without the
    // Flexible wrapper, the Row's `mainAxisSize: min` would let the
    // inner ConstrainedBox claim its full 200px regardless of
    // parent — visible as Flutter's yellow-and-black overflow chevron
    // when the chat panel is narrower than ~300px.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: segment.pending
                  ? DuckColors.accentCyan.withValues(alpha: 0.45)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (segment.pending)
                const _PendingDot()
              else
                Icon(
                  _iconForInspection(segment.toolId),
                  size: 11,
                  color: accent,
                ),
              const SizedBox(width: 5),
              Text(
                _actionLabel(segment),
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: accent,
                  letterSpacing: 0.3,
                ),
              ),
              if (segment.firstArg.isNotEmpty) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Text(
                      segment.firstArg,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: const TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 10.5,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Three-dot loading glyph used inside the compact inspection
/// badge instead of a static icon when a tool is still in flight.
/// Cheaper than wrapping the whole badge in a shimmer; the dots
/// occupy the icon slot exactly so layout doesn't shift when a
/// pending inspection completes.
class _PendingDot extends StatefulWidget {
  const _PendingDot();

  @override
  State<_PendingDot> createState() => _PendingDotState();
}

class _PendingDotState extends State<_PendingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 11,
      height: 11,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return CustomPaint(painter: _PendingDotPainter(t: _ctrl.value));
        },
      ),
    );
  }
}

class _PendingDotPainter extends CustomPainter {
  final double t;
  _PendingDotPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    const dotR = 1.2;
    final cy = size.height / 2;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i * 0.18) % 1.0;
      final wave = (phase < 0.5)
          ? Curves.easeInOut.transform(phase * 2)
          : Curves.easeInOut.transform((1 - phase) * 2);
      final alpha = 0.30 + 0.55 * wave;
      paint.color = DuckColors.accentCyan.withValues(alpha: alpha);
      final cx = 1.5 + i * 4.0;
      canvas.drawCircle(Offset(cx, cy), dotR, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PendingDotPainter old) => old.t != t;
}

/// Yellow warning card surfaced when the parser detected a
/// tool-shaped block in the model's output but the inner structure
/// rejected the strict per-tool regex. The block will NOT execute
/// — neither here in the UI nor in `ToolExecutor.run` — so we
/// surface a "model tried to do this, but the call is malformed"
/// chip instead of letting the raw body leak into the chat as
/// hundreds of lines of code.
///
/// Displayed inline in the conversation flow alongside other tool
/// segments. Tapping the help glyph opens a tooltip explaining
/// what went wrong; tapping anywhere else is a no-op (there's
/// nothing to navigate to — the call never ran).
class _MalformedToolCard extends StatelessWidget {
  final ToolSegment segment;
  const _MalformedToolCard({required this.segment});

  @override
  Widget build(BuildContext context) {
    final tool = ToolRegistry.byId(segment.toolId);
    final toolLabel = tool?.name ?? segment.toolId.toUpperCase();
    final summary = segment.firstArg.trim().isEmpty
        ? toolLabel
        : '$toolLabel: ${segment.firstArg.trim()}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Tooltip(
        message: S.toolMalformedTooltip(toolLabel),
        waitDuration: const Duration(milliseconds: 350),
        child: Container(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          decoration: BoxDecoration(
            color: DuckColors.bgDeeper,
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border(
              left: const BorderSide(color: DuckColors.stateWarn, width: 2),
              top: BorderSide(
                color: DuckColors.stateWarn.withValues(alpha: 0.25),
                width: 0.5,
              ),
              right: BorderSide(
                color: DuckColors.stateWarn.withValues(alpha: 0.25),
                width: 0.5,
              ),
              bottom: BorderSide(
                color: DuckColors.stateWarn.withValues(alpha: 0.25),
                width: 0.5,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 14,
                color: DuckColors.stateWarn,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      S.toolMalformedTitle,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: DuckColors.stateWarn,
                        letterSpacing: 0.2,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 11,
                        color: DuckColors.fgMuted,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const Icon(
                Icons.help_outline,
                size: 13,
                color: DuckColors.fgSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
