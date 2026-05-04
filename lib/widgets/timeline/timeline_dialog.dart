import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/timeline_models.dart';
import '../../services/timeline_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';
import 'timeline_diff.dart';

/// Floating panel that exposes the per-workspace file revision
/// history. Layout mirrors the convention every IDE-class history
/// panel uses (Cursor, VSCode timeline, JetBrains Local History):
///   - left rail: filterable list of revisions
///   - right pane: side-by-side diff (revision vs current file)
///   - top bar: filters + path filter + restore button
///
/// Opened via [showTimelineDialog]. Listens to the service so newly
/// captured revisions appear immediately while the panel is open
/// (e.g. user keeps editing while the dialog is up).
class TimelineDialog extends StatefulWidget {
  /// Optional initial path filter. When non-null, the list is
  /// pre-scoped to that file's history; the user can still flip
  /// the "active file only" chip off to see workspace-wide.
  final String? initialRelPath;

  const TimelineDialog({super.key, this.initialRelPath});

  @override
  State<TimelineDialog> createState() => _TimelineDialogState();
}

enum _OriginFilter { all, agent, user, external, baseline }

class _TimelineDialogState extends State<TimelineDialog> {
  String? _selectedEntryId;
  _OriginFilter _filter = _OriginFilter.all;
  String _query = '';
  bool _scopeToPath;

  TimelineSnapshotPair? _pair;
  bool _loadingPair = false;
  String? _pairError;

  _TimelineDialogState() : _scopeToPath = false;

  @override
  void initState() {
    super.initState();
    _scopeToPath = widget.initialRelPath != null;
    final timeline = context.read<AppState>().timeline;
    timeline.addListener(_onTimelineChanged);
  }

  @override
  void dispose() {
    final timeline = context.read<AppState>().timeline;
    timeline.removeListener(_onTimelineChanged);
    super.dispose();
  }

  void _onTimelineChanged() {
    if (!mounted) return;
    setState(() {});
  }

  List<TimelineEntry> _filterEntries(TimelineService timeline) {
    final all = timeline.entries;
    final relScope = widget.initialRelPath;
    final q = _query.trim().toLowerCase();
    return all
        .where((e) {
          if (_scopeToPath && relScope != null) {
            if (e.relPath != relScope) return false;
          }
          switch (_filter) {
            case _OriginFilter.all:
              break;
            case _OriginFilter.agent:
              if (e.origin != TimelineOrigin.agentTool) return false;
              break;
            case _OriginFilter.user:
              if (e.origin != TimelineOrigin.userSave) return false;
              break;
            case _OriginFilter.external:
              if (e.origin != TimelineOrigin.fsEvent) return false;
              break;
            case _OriginFilter.baseline:
              if (e.origin != TimelineOrigin.baseline) return false;
              break;
          }
          if (q.isNotEmpty) {
            if (!e.relPath.toLowerCase().contains(q) &&
                !(e.tool ?? '').toLowerCase().contains(q) &&
                !(e.note ?? '').toLowerCase().contains(q)) {
              return false;
            }
          }
          return true;
        })
        .toList(growable: false);
  }

  Future<void> _selectEntry(TimelineEntry entry, TimelineService svc) async {
    setState(() {
      _selectedEntryId = entry.id;
      _loadingPair = true;
      _pair = null;
      _pairError = null;
    });
    try {
      final pair = await svc.buildPair(entry);
      if (!mounted) return;
      setState(() {
        _pair = pair;
        _loadingPair = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _pair = null;
        _pairError = '$e';
        _loadingPair = false;
      });
    }
  }

  Future<void> _restore(TimelineEntry entry, TimelineService svc) async {
    final confirmed = await _confirmRestore(entry);
    if (!confirmed) return;
    final result = await svc.restoreToRevision(entry);
    if (!mounted) return;
    showDuckToast(context, result.message);
    if (result.ok) {
      // **Editor buffer freshness** — restore writes the blob to
      // disk, but the editor keeps its own `_fileContents[path]`
      // in-memory buffer that is NOT bound to the FS watcher. If
      // the restored file is currently open as a tab, its visible
      // content would still be the pre-restore version until the
      // user closes-and-reopens it. Re-read the file from disk and
      // push the bytes back into AppState so the editor reflects
      // the restore immediately.
      final state = context.read<AppState>();
      final ws = state.currentDirectory;
      if (ws != null) {
        final abs = p.join(ws, entry.relPath.replaceAll('/', p.separator));
        final isOpen = state.openFiles.any((f) => f.path == abs);
        if (isOpen) {
          try {
            final fresh = await File(abs).readAsString();
            state.resyncOpenFileFromDisk(abs, fresh);
          } catch (_) {
            /* best-effort; explorer refresh will show file anyway */
          }
        }
      }
      // Refresh the diff pane so the "current" side reflects the
      // new on-disk content.
      await _selectEntry(entry, svc);
    }
  }

  /// Project-wide revert path. Treats the entry's timestamp as the
  /// chosen point in time and rolls the whole workspace back to that
  /// moment, regardless of which file the entry refers to.
  Future<void> _revertProject(
    TimelineEntry entry,
    TimelineService svc,
  ) async {
    final preview = svc.previewProjectRevertTo(entry.when);
    if (preview.isNoOp) {
      showDuckToast(context, S.timelineProjectRevertNoChanges);
      return;
    }
    // Capture the AppState read BEFORE the async confirm dialog so
    // we don't reach across an async gap to read the inherited
    // widget tree (the analyzer-flagged
    // `use_build_context_synchronously` warning).
    final state = context.read<AppState>();
    final outcome = await _confirmProjectRevert(entry, preview);
    if (outcome == null) return;
    final result = await state.revertProjectToPointInTime(
      entry.when,
      deleteFilesCreatedAfter: outcome.deleteCreatedAfter,
    );
    if (!mounted) return;
    showDuckToast(context, result.message);
    if (result.ok) {
      // The diff pane's "current" side may now match the revision —
      // re-fetch so the user sees the synchronised state.
      await _selectEntry(entry, svc);
    }
  }

  Future<bool> _confirmRestore(TimelineEntry entry) async {
    final ans = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: Text(S.timelineRestoreConfirmTitle),
        content: Text(
          S.timelineRestoreConfirmBody(entry.relPath, _humanWhen(entry.when)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentCyan,
              foregroundColor: DuckColors.bgDeepest,
            ),
            child: const Text(S.timelineRestoreAction),
          ),
        ],
      ),
    );
    return ans == true;
  }

  Future<_ProjectRevertChoice?> _confirmProjectRevert(
    TimelineEntry entry,
    TimelineProjectRevertPreview preview,
  ) async {
    return showDialog<_ProjectRevertChoice>(
      context: context,
      builder: (ctx) => _ProjectRevertConfirmDialog(
        entry: entry,
        preview: preview,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final svc = state.timeline;
    final entries = _filterEntries(svc);

    final selected = _selectedEntryId != null
        ? svc.entryById(_selectedEntryId!)
        : null;
    final size = MediaQuery.of(context).size;
    // Account for `insetPadding` so we never produce a tight
    // SizedBox larger than the viewport — that layout combo with
    // `DuckGlass.hero`'s `BackdropFilter` is the documented Windows
    // "empty glass rectangle" symptom (see knowledgebase: splash
    // screen warning). Clamp generously and inset the sizing inside
    // the glass via a Container, not outside via SizedBox.
    const inset = 24.0;
    final maxW = size.width - inset * 2;
    final maxH = size.height - inset * 2;
    final w = (size.width * 0.86).clamp(720.0, 1480.0).clamp(420.0, maxW);
    final h = (size.height * 0.84).clamp(520.0, 980.0).clamp(360.0, maxH);

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      insetPadding: const EdgeInsets.all(inset),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        // Sizing lives INSIDE the hero (Container), not outside in a
        // SizedBox. The dialogs that work on Windows
        // (`backup_dialog`, `gitnexus_dialog`) all follow this
        // pattern; flipping them around made the BackdropFilter
        // child stop painting on first frame.
        child: Container(
          width: w,
          height: h,
          padding: EdgeInsets.zero,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                onClose: () => Navigator.of(context).pop(),
                workspace: state.currentDirectory,
              ),
              _Filters(
                filter: _filter,
                onFilter: (f) => setState(() => _filter = f),
                query: _query,
                onQuery: (q) => setState(() => _query = q),
                scopeToPath: _scopeToPath,
                pathLabel: widget.initialRelPath,
                onScopeToggle: widget.initialRelPath == null
                    ? null
                    : (v) => setState(() => _scopeToPath = v),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: 340,
                      child: _EntryList(
                        entries: entries,
                        selectedId: _selectedEntryId,
                        onSelect: (e) => _selectEntry(e, svc),
                      ),
                    ),
                    Container(width: 0.5, color: DuckColors.glassSeam),
                    Expanded(
                      child: _DiffPane(
                        entry: selected,
                        pair: _pair,
                        loading: _loadingPair,
                        error: _pairError,
                        onRestore: () {
                          if (selected != null) _restore(selected, svc);
                        },
                        onRevertProject: () {
                          if (selected != null) {
                            _revertProject(selected, svc);
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  final String? workspace;
  const _Header({required this.onClose, required this.workspace});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(20, 14, 8, 14),
      child: Row(
        children: [
          const Icon(Icons.history, size: 18, color: DuckColors.accentCyan),
          const SizedBox(width: 10),
          Text(
            S.timelineTitle,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(width: 14),
          if (workspace != null && workspace!.isNotEmpty)
            Expanded(
              child: Text(
                workspace!,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 11,
                  letterSpacing: 0.2,
                ),
              ),
            )
          else
            const Spacer(),
          IconButton(
            tooltip: S.close,
            onPressed: onClose,
            mouseCursor: SystemMouseCursors.click,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            icon: const Icon(Icons.close, size: 18, color: DuckColors.fgMuted),
            splashRadius: 16,
          ),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  final _OriginFilter filter;
  final ValueChanged<_OriginFilter> onFilter;
  final String query;
  final ValueChanged<String> onQuery;
  final bool scopeToPath;
  final String? pathLabel;
  final ValueChanged<bool>? onScopeToggle;

  const _Filters({
    required this.filter,
    required this.onFilter,
    required this.query,
    required this.onQuery,
    required this.scopeToPath,
    required this.pathLabel,
    required this.onScopeToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          _Chip(
            label: S.timelineFilterAll,
            selected: filter == _OriginFilter.all,
            onTap: () => onFilter(_OriginFilter.all),
          ),
          _Chip(
            label: S.timelineFilterAgent,
            selected: filter == _OriginFilter.agent,
            tint: DuckColors.accentCyan,
            onTap: () => onFilter(_OriginFilter.agent),
          ),
          _Chip(
            label: S.timelineFilterUser,
            selected: filter == _OriginFilter.user,
            tint: DuckColors.accentMint,
            onTap: () => onFilter(_OriginFilter.user),
          ),
          _Chip(
            label: S.timelineFilterExternal,
            selected: filter == _OriginFilter.external,
            tint: DuckColors.accentPurple,
            onTap: () => onFilter(_OriginFilter.external),
          ),
          _Chip(
            label: S.timelineFilterBaseline,
            selected: filter == _OriginFilter.baseline,
            tint: DuckColors.fgSubtle,
            onTap: () => onFilter(_OriginFilter.baseline),
          ),
          const SizedBox(width: 12),
          if (onScopeToggle != null)
            _Chip(
              label: scopeToPath
                  ? S.timelineScopeOn(pathLabel ?? '')
                  : S.timelineScopeOff,
              selected: scopeToPath,
              tint: DuckColors.accentCyan,
              onTap: () => onScopeToggle!(!scopeToPath),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: SizedBox(
              height: 28,
              child: TextField(
                onChanged: onQuery,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 12,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: S.timelineSearchHint,
                  hintStyle: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 12,
                  ),
                  filled: true,
                  fillColor: DuckColors.bgChip,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(6),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final Color? tint;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final c = tint ?? DuckColors.accentCyan;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: selected ? c.withValues(alpha: 0.18) : DuckColors.bgChip,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: selected
                    ? c.withValues(alpha: 0.5)
                    : DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: selected ? c : DuckColors.fgMuted,
                fontSize: 11,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                letterSpacing: 0.2,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EntryList extends StatelessWidget {
  final List<TimelineEntry> entries;
  final String? selectedId;
  final ValueChanged<TimelineEntry> onSelect;
  const _EntryList({
    required this.entries,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            S.timelineEmpty,
            textAlign: TextAlign.center,
            style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 12),
          ),
        ),
      );
    }
    // Group by day for readability.
    final groups = _groupByDay(entries);
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: groups.length,
      itemBuilder: (ctx, i) {
        final g = groups[i];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
              child: Text(
                g.label,
                style: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.0,
                ),
              ),
            ),
            for (final entry in g.entries)
              _EntryRow(
                entry: entry,
                selected: entry.id == selectedId,
                onTap: () => onSelect(entry),
              ),
          ],
        );
      },
    );
  }

  static List<_EntryGroup> _groupByDay(List<TimelineEntry> entries) {
    final today = DateTime.now();
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    DateTime startOfDay(DateTime t) => DateTime(t.year, t.month, t.day);

    final groups = <_EntryGroup>[];
    String? currentLabel;
    List<TimelineEntry>? bucket;
    for (final e in entries) {
      String label;
      if (sameDay(e.when, today)) {
        label = S.timelineGroupToday;
      } else if (sameDay(e.when, today.subtract(const Duration(days: 1)))) {
        label = S.timelineGroupYesterday;
      } else if (today.difference(startOfDay(e.when)).inDays < 7) {
        label = S.timelineGroupThisWeek;
      } else {
        label = '${e.when.year}-${_two(e.when.month)}-${_two(e.when.day)}';
      }
      if (label != currentLabel) {
        currentLabel = label;
        bucket = <TimelineEntry>[];
        groups.add(_EntryGroup(label: label, entries: bucket));
      }
      bucket!.add(e);
    }
    return groups;
  }

  static String _two(int n) => n.toString().padLeft(2, '0');
}

class _EntryGroup {
  final String label;
  final List<TimelineEntry> entries;
  _EntryGroup({required this.label, required this.entries});
}

class _EntryRow extends StatelessWidget {
  final TimelineEntry entry;
  final bool selected;
  final VoidCallback onTap;
  const _EntryRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final originColor = _originTint(entry.origin);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          decoration: BoxDecoration(
            color: selected
                ? DuckColors.accentCyan.withValues(alpha: 0.10)
                : Colors.transparent,
            border: Border(
              left: BorderSide(
                color: selected ? DuckColors.accentCyan : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 8,
                height: 8,
                margin: const EdgeInsets.only(top: 5, right: 10),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: originColor,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            p.basename(entry.relPath),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: DuckColors.fgPrimary,
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                        ),
                        Text(
                          _humanWhen(entry.when),
                          style: const TextStyle(
                            color: DuckColors.fgSubtle,
                            fontSize: 10.5,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      p.dirname(entry.relPath) == '.'
                          ? entry.relPath
                          : entry.relPath,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DuckColors.fgSubtle,
                        fontSize: 10.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        _OpBadge(op: entry.op),
                        const SizedBox(width: 6),
                        Text(
                          _originLabel(entry),
                          style: TextStyle(
                            color: originColor,
                            fontSize: 10.5,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OpBadge extends StatelessWidget {
  final TimelineOp op;
  const _OpBadge({required this.op});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (op) {
      TimelineOp.create => (S.timelineOpCreate, DuckColors.stateOk),
      TimelineOp.modify => (S.timelineOpModify, DuckColors.accentCyan),
      TimelineOp.delete => (S.timelineOpDelete, DuckColors.stateError),
      TimelineOp.rename => (S.timelineOpRename, DuckColors.accentPurple),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4), width: 0.5),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _DiffPane extends StatelessWidget {
  final TimelineEntry? entry;
  final TimelineSnapshotPair? pair;
  final bool loading;
  final String? error;
  final VoidCallback onRestore;
  final VoidCallback onRevertProject;
  const _DiffPane({
    required this.entry,
    required this.pair,
    required this.loading,
    required this.error,
    required this.onRestore,
    required this.onRevertProject,
  });

  @override
  Widget build(BuildContext context) {
    if (entry == null) {
      return _emptyPlaceholder(S.timelineSelectPrompt);
    }
    if (loading) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DuckColors.accentCyan,
          ),
        ),
      );
    }
    if (error != null) {
      return _emptyPlaceholder('${S.error}: $error');
    }
    final p = pair;
    if (p == null) {
      return _emptyPlaceholder(S.timelineSelectPrompt);
    }

    final canDiff =
        p.revisionKind == TimelineKind.text &&
        p.currentKind == TimelineKind.text;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry!.relPath,
                      style: const TextStyle(
                        color: DuckColors.fgPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${_originLabel(entry!)} · ${entry!.when.toLocal()}',
                      style: const TextStyle(
                        color: DuckColors.fgSubtle,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (entry!.note != null && entry!.note!.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          entry!.note!,
                          style: const TextStyle(
                            color: DuckColors.fgMuted,
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Tooltip(
                message: S.timelineProjectRevertTooltip,
                child: OutlinedButton.icon(
                  onPressed: onRevertProject,
                  icon: const Icon(Icons.history_toggle_off, size: 16),
                  label: const Text(S.timelineProjectRevertAction),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DuckColors.fgPrimary,
                    side: const BorderSide(
                      color: DuckColors.borderStrong,
                      width: 0.8,
                    ),
                    textStyle: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: onRestore,
                icon: const Icon(Icons.restore, size: 16),
                label: const Text(S.timelineRestoreAction),
                style: ElevatedButton.styleFrom(
                  backgroundColor: DuckColors.accentCyan,
                  foregroundColor: DuckColors.bgDeepest,
                  textStyle: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: canDiff
              ? TimelineDiffView(
                  revisionLabel: S.timelineDiffRevision(
                    _humanWhen(entry!.when),
                  ),
                  currentLabel: S.timelineDiffCurrent,
                  revisionText: p.revisionText,
                  currentText: p.currentText,
                )
              : _binaryPane(p),
        ),
      ],
    );
  }

  Widget _binaryPane(TimelineSnapshotPair p) {
    return Container(
      color: DuckColors.editorBg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.attachment, size: 36, color: DuckColors.fgSubtle),
          const SizedBox(height: 12),
          Text(
            S.timelineBinaryNotice,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: DuckColors.fgMuted,
              fontSize: 12.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            S.timelineBinarySizes(p.revisionSize, p.currentSize),
            textAlign: TextAlign.center,
            style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _emptyPlaceholder(String text) {
    return Container(
      color: DuckColors.editorBg,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 12),
      ),
    );
  }
}

// ── helpers (top-level so other timeline widgets can reuse) ───────

Color _originTint(TimelineOrigin o) {
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

String _originLabel(TimelineEntry e) {
  switch (e.origin) {
    case TimelineOrigin.agentTool:
      return e.tool != null
          ? S.timelineOriginAgentTool(e.tool!)
          : S.timelineOriginAgent;
    case TimelineOrigin.userSave:
      return S.timelineOriginUser;
    case TimelineOrigin.fsEvent:
      return S.timelineOriginExternal;
    case TimelineOrigin.explorer:
      return S.timelineOriginExplorer;
    case TimelineOrigin.baseline:
      return S.timelineOriginBaseline;
    case TimelineOrigin.unknown:
      return S.timelineOriginOther;
  }
}

String _humanWhen(DateTime t) {
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inSeconds < 5) return S.timelineWhenJustNow;
  if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// User's choice from the project-revert confirm dialog. Captures
/// the one toggle that has user-data implications: whether files
/// created after the chosen revert point should be deleted (true)
/// or left in place (false). The dialog returns null on cancel.
class _ProjectRevertChoice {
  final bool deleteCreatedAfter;
  const _ProjectRevertChoice({required this.deleteCreatedAfter});
}

/// Confirm dialog that explains the blast radius of a project-wide
/// revert. Shows counts grouped by category (rewrite / recreate /
/// created-after / unrestorable) and exposes the keep-or-delete
/// toggle when there are post-revert-point files. Defaults to
/// "Keep" — deletion is opt-in because it's the only destructive
/// part of the flow.
class _ProjectRevertConfirmDialog extends StatefulWidget {
  final TimelineEntry entry;
  final TimelineProjectRevertPreview preview;
  const _ProjectRevertConfirmDialog({
    required this.entry,
    required this.preview,
  });

  @override
  State<_ProjectRevertConfirmDialog> createState() =>
      _ProjectRevertConfirmDialogState();
}

class _ProjectRevertConfirmDialogState
    extends State<_ProjectRevertConfirmDialog> {
  bool _deleteCreatedAfter = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    final whenLabel =
        '${_humanWhen(widget.entry.when)} (${widget.entry.when.toLocal()})';
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Text(S.timelineProjectRevertConfirmTitle),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              whenLabel,
              style: const TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.timelineProjectRevertSummary(
                changed: preview.filesToRewrite.length,
                recreated: preview.filesToRecreate.length,
                createdAfter: preview.filesCreatedAfter.length,
                unrestorable: preview.filesUnrestorable.length,
              ),
              style: const TextStyle(
                color: DuckColors.fgMuted,
                fontSize: 12,
              ),
            ),
            if (preview.filesToRewrite.isNotEmpty) ...[
              const SizedBox(height: 14),
              _RevertFileSection(
                title: S.timelineProjectRevertChangedFiles,
                count: preview.filesToRewrite.length,
                files: preview.filesToRewrite,
                tint: DuckColors.accentCyan,
              ),
            ],
            if (preview.filesToRecreate.isNotEmpty) ...[
              const SizedBox(height: 12),
              _RevertFileSection(
                title: S.timelineProjectRevertRecreatedFiles,
                count: preview.filesToRecreate.length,
                files: preview.filesToRecreate,
                tint: DuckColors.stateOk,
              ),
            ],
            if (preview.filesUnrestorable.isNotEmpty) ...[
              const SizedBox(height: 12),
              _RevertFileSection(
                title: S.timelineProjectRevertUnrestorable,
                count: preview.filesUnrestorable.length,
                files: preview.filesUnrestorable,
                tint: DuckColors.stateError,
              ),
            ],
            if (preview.filesCreatedAfter.isNotEmpty) ...[
              const SizedBox(height: 14),
              _RevertFileSection(
                title: S.timelineProjectRevertCreatedAfter,
                count: preview.filesCreatedAfter.length,
                files: preview.filesCreatedAfter,
                tint: DuckColors.accentDuck,
              ),
              const SizedBox(height: 6),
              Text(
                S.timelineProjectRevertNewFilesPrompt,
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 11.5,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  _RadioPill(
                    label: S.timelineProjectRevertKeepNewFiles,
                    selected: !_deleteCreatedAfter,
                    tint: DuckColors.stateOk,
                    onTap: () =>
                        setState(() => _deleteCreatedAfter = false),
                  ),
                  const SizedBox(width: 6),
                  _RadioPill(
                    label: S.timelineProjectRevertDeleteNewFiles,
                    selected: _deleteCreatedAfter,
                    tint: DuckColors.stateError,
                    onTap: () =>
                        setState(() => _deleteCreatedAfter = true),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            Text(
              S.timelineProjectRevertSafetyNote,
              style: const TextStyle(
                color: DuckColors.fgSubtle,
                fontSize: 11,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(S.cancel),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(
            context,
            _ProjectRevertChoice(deleteCreatedAfter: _deleteCreatedAfter),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.accentCyan,
            foregroundColor: DuckColors.bgDeepest,
          ),
          child: const Text(S.timelineProjectRevertAction),
        ),
      ],
    );
  }
}

class _RevertFileSection extends StatelessWidget {
  final String title;
  final int count;
  final List<String> files;
  final Color tint;
  const _RevertFileSection({
    required this.title,
    required this.count,
    required this.files,
    required this.tint,
  });

  @override
  Widget build(BuildContext context) {
    final preview = files.take(6).toList(growable: false);
    final extra = files.length - preview.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: tint, shape: BoxShape.circle),
            ),
            const SizedBox(width: 8),
            Text(
              '$title ($count)',
              style: TextStyle(
                color: tint,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.only(left: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final f in preview)
                Text(
                  f,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
              if (extra > 0)
                Text(
                  '… and $extra more',
                  style: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 10.5,
                    fontStyle: FontStyle.italic,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _RadioPill extends StatelessWidget {
  final String label;
  final bool selected;
  final Color tint;
  final VoidCallback onTap;
  const _RadioPill({
    required this.label,
    required this.selected,
    required this.tint,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: selected ? tint.withValues(alpha: 0.18) : DuckColors.bgChip,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? tint.withValues(alpha: 0.55)
                  : DuckColors.glassSeam,
              width: 0.7,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? tint : DuckColors.fgMuted,
              fontSize: 11.5,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Convenience — open the dialog. Pre-scopes to the active editor
/// file when no [relPath] is passed and one is available.
Future<void> showTimelineDialog(BuildContext context, {String? relPath}) async {
  String? scope = relPath;
  if (scope == null) {
    final state = context.read<AppState>();
    final active = state.activeFile?.path;
    final ws = state.currentDirectory;
    if (active != null && ws != null && !AppState.isSettingsTab(active)) {
      try {
        final rel = p.relative(active, from: ws).replaceAll(r'\', '/');
        if (!rel.startsWith('..') && File(active).existsSync()) {
          scope = rel;
        }
      } catch (_) {}
    }
  }
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.45),
    builder: (ctx) => TimelineDialog(initialRelPath: scope),
  );
}
