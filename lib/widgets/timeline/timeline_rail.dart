import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/timeline_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'timeline_dialog.dart';

/// Compact bottom strip pinned under the file explorer tree.
///
/// Shows the most recent revisions for the **active editor file**.
/// Two states:
///   - Collapsed (default): one-line bar with the most recent
///     revision's relative time + origin tint dot. Hover reveals a
///     chevron; clicking the bar expands.
///   - Expanded: list of the last 5 revisions, each clickable —
///     click opens the floating [TimelineDialog] pre-scoped to that
///     file with the row's revision pre-selected. A trailing "View
///     all" link opens the dialog without a scope filter so the
///     user can still browse workspace-wide.
///
/// The rail does NOT render anything when no workspace is open or
/// no active editor file is set — it would be visually noisy under
/// the empty explorer placeholder. It also self-collapses when the
/// active file has zero revisions in the journal (FS event hasn't
/// fired, file just opened); same reason.
///
/// **Why a rail instead of an editor toolbar button?**
/// Cursor / VSCode put the timeline in the file explorer for a
/// reason: the user thinks of "history of THIS file" the moment
/// they're locating files in the tree, not when they're already
/// editing. Pinning under the explorer also keeps the chrome
/// vertically tidy on smaller screens — the editor toolbar would
/// gain another button at the cost of ~32px of canvas, the rail
/// reuses already-blank space.
class TimelineRail extends StatefulWidget {
  const TimelineRail({super.key});

  @override
  State<TimelineRail> createState() => _TimelineRailState();
}

class _TimelineRailState extends State<TimelineRail> {
  bool _expanded = false;

  @override
  void initState() {
    super.initState();
    final timeline = context.read<AppState>().timeline;
    timeline.addListener(_onChanged);
  }

  @override
  void dispose() {
    final timeline = context.read<AppState>().timeline;
    timeline.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ws = state.currentDirectory;
    final active = state.activeFile?.path;
    if (ws == null || active == null) return const SizedBox.shrink();
    if (AppState.isSettingsTab(active) || AppState.isUntitledTab(active)) {
      return const SizedBox.shrink();
    }

    final svc = state.timeline;
    final rel = p.relative(active, from: ws).replaceAll(r'\', '/');
    final entries = svc.entriesForPath(rel);

    if (entries.isEmpty) return const SizedBox.shrink();
    final head = entries.first;

    return Container(
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _RailHeader(
            head: head,
            relPath: rel,
            count: entries.length,
            expanded: _expanded,
            onToggle: () => setState(() => _expanded = !_expanded),
            onOpenDialog: () => showTimelineDialog(context, relPath: rel),
          ),
          if (_expanded)
            _RailExpanded(
              entries: entries.take(5).toList(growable: false),
              onOpenWithEntry: (e) => _openDialogAtEntry(rel, e),
              onOpenAll: () => showTimelineDialog(context),
            ),
        ],
      ),
    );
  }

  void _openDialogAtEntry(String rel, TimelineEntry _) {
    // Pre-scoping is the same as the rail header path — selecting
    // the specific entry inside the dialog is a UX nice-to-have
    // we'd add by passing an `initialEntryId`. The current dialog
    // takes only a path filter; selecting a specific entry on
    // open would require widening that interface. Keeping this as
    // a follow-up so the rail ships now.
    showTimelineDialog(context, relPath: rel);
  }
}

class _RailHeader extends StatelessWidget {
  final TimelineEntry head;
  final String relPath;
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onOpenDialog;

  const _RailHeader({
    required this.head,
    required this.relPath,
    required this.count,
    required this.expanded,
    required this.onToggle,
    required this.onOpenDialog,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onToggle,
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
          child: Row(
            children: [
              Icon(
                expanded
                    ? Icons.keyboard_arrow_down
                    : Icons.keyboard_arrow_right,
                size: 14,
                color: DuckColors.fgSubtle,
              ),
              const SizedBox(width: 4),
              Text(
                S.timelineRailHeader,
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: DuckColors.bgChip,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _originColor(head.origin),
                ),
              ),
              Text(
                _humanWhen(head.when),
                style: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 10.5,
                ),
              ),
              IconButton(
                tooltip: S.timelineOpenDialog,
                onPressed: onOpenDialog,
                mouseCursor: SystemMouseCursors.click,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 28, minHeight: 24),
                splashRadius: 14,
                icon: const Icon(
                  Icons.open_in_full,
                  size: 13,
                  color: DuckColors.fgMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailExpanded extends StatelessWidget {
  final List<TimelineEntry> entries;
  final void Function(TimelineEntry) onOpenWithEntry;
  final VoidCallback onOpenAll;
  const _RailExpanded({
    required this.entries,
    required this.onOpenWithEntry,
    required this.onOpenAll,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 0.5, thickness: 0.5, color: DuckColors.glassSeam),
        for (final e in entries)
          _RailEntryRow(entry: e, onTap: () => onOpenWithEntry(e)),
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: onOpenAll,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: Row(
                children: [
                  const Icon(
                    Icons.history,
                    size: 13,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    S.timelineViewAll,
                    style: const TextStyle(
                      color: DuckColors.accentCyan,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RailEntryRow extends StatelessWidget {
  final TimelineEntry entry;
  final VoidCallback onTap;
  const _RailEntryRow({required this.entry, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.fromLTRB(14, 5, 12, 5),
          child: Row(
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _originColor(entry.origin),
                ),
              ),
              Expanded(
                child: Text(
                  _shortLabel(entry),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontSize: 11,
                  ),
                ),
              ),
              Text(
                _humanWhen(entry.when),
                style: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _shortLabel(TimelineEntry e) {
  switch (e.origin) {
    case TimelineOrigin.agentTool:
      return e.tool != null
          ? S.timelineRailAgentEntry(e.tool!)
          : S.timelineRailAgentEntryGeneric;
    case TimelineOrigin.userSave:
      return S.timelineRailUserEntry;
    case TimelineOrigin.fsEvent:
      return S.timelineRailExternalEntry;
    case TimelineOrigin.explorer:
      return S.timelineRailExplorerEntry;
    case TimelineOrigin.baseline:
      return S.timelineRailBaselineEntry;
    case TimelineOrigin.unknown:
      return S.timelineRailUnknownEntry;
  }
}

Color _originColor(TimelineOrigin o) {
  switch (o) {
    case TimelineOrigin.agentTool:
      return DuckColors.accentCyan;
    case TimelineOrigin.userSave:
      return DuckColors.accentMint;
    case TimelineOrigin.fsEvent:
      return DuckColors.accentPurple;
    case TimelineOrigin.explorer:
      return DuckColors.accentDuck;
    case TimelineOrigin.baseline:
      return DuckColors.fgSubtle;
    case TimelineOrigin.unknown:
      return DuckColors.stateError;
  }
}

String _humanWhen(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inSeconds < 5) return 'now';
  if (diff.inSeconds < 60) return '${diff.inSeconds}s';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m';
  if (diff.inHours < 24) return '${diff.inHours}h';
  if (diff.inDays < 7) return '${diff.inDays}d';
  return '${t.month}/${t.day}';
}
