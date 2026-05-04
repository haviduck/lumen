import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/lumen_process_tracker.dart';
import '../../services/process_filters.dart';
import '../../services/process_manager_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'process_filter_chip.dart';
import 'process_table_row.dart';

/// Process manager virtual tab.
///
/// Renders inside the editor pane area when the active path is
/// `AppState.processManagerSentinel`. Modeled after `SettingsView`
/// — full-bleed surface, no chrome around the edges, scrolls
/// internally.
///
/// Refresh strategy: a single 2-second `Timer.periodic` re-snapshots
/// the system. The OS call (`Get-CimInstance` on Windows, `ps` on
/// Unix) takes 200–800 ms, so we lock out concurrent refreshes
/// with `_isRefreshing` to avoid the queue piling up if the box
/// is under load. Pause toggle exposes a mental escape hatch —
/// useful when the user wants the table frozen while they read
/// command-line columns.
class ProcessManagerView extends StatefulWidget {
  const ProcessManagerView({super.key});

  @override
  State<ProcessManagerView> createState() => _ProcessManagerViewState();
}

class _ProcessManagerViewState extends State<ProcessManagerView> {
  static const Duration _refreshInterval = Duration(seconds: 2);

  List<ProcessInfo> _all = const [];
  Set<int> _lumenExpanded = const {};
  String _query = '';
  ProcessFilterPreset _preset = ProcessFilterPreset.all;
  Timer? _refreshTimer;
  bool _isRefreshing = false;
  bool _autoRefresh = true;
  bool _initialLoaded = false;
  String? _error;
  // Per-PID busy flag — shows a spinner inline on the kill button
  // for rows the user has clicked but which haven't disappeared
  // from the next snapshot yet.
  final Set<int> _killing = <int>{};

  late final TextEditingController _searchCtrl = TextEditingController();
  late final FocusNode _searchFocus = FocusNode();
  LumenProcessTracker? _tracker;

  @override
  void initState() {
    super.initState();
    _scheduleRefresh();
    // Kick off an immediate refresh — without this the user sees
    // an empty table for ~2s on tab open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _refresh();
      _wireTracker();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wireTracker();
  }

  void _wireTracker() {
    final t = context.read<AppState>().lumenProcesses;
    if (identical(t, _tracker)) return;
    _tracker?.removeListener(_onTrackerChanged);
    _tracker = t;
    _tracker!.addListener(_onTrackerChanged);
  }

  void _onTrackerChanged() {
    // Tracker mutations don't change the underlying process list,
    // they only change which subset counts as Lumen-spawned. Just
    // re-run the cheap descendant walk against the cached
    // snapshot.
    if (!mounted || _all.isEmpty) {
      if (mounted) setState(() {});
      return;
    }
    setState(() {
      _lumenExpanded = _tracker?.expand(_all) ?? const {};
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _tracker?.removeListener(_onTrackerChanged);
    _searchCtrl.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _scheduleRefresh() {
    _refreshTimer?.cancel();
    if (!_autoRefresh) return;
    _refreshTimer = Timer.periodic(_refreshInterval, (_) => _refresh());
  }

  Future<void> _refresh() async {
    if (_isRefreshing || !mounted) return;
    _isRefreshing = true;
    try {
      final list = await ProcessManagerService.list();
      if (!mounted) return;
      setState(() {
        _all = list;
        _lumenExpanded = _tracker?.expand(list) ?? const {};
        _error = null;
        _initialLoaded = true;
        // Drop "killing" markers for PIDs the OS has confirmed
        // gone — avoids stuck spinners after a successful kill.
        final live = <int>{for (final p in list) p.pid};
        _killing.removeWhere((pid) => !live.contains(pid));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _initialLoaded = true;
      });
    } finally {
      _isRefreshing = false;
    }
  }

  Future<void> _killOne(ProcessInfo p) async {
    setState(() => _killing.add(p.pid));
    final r = await ProcessManagerService.kill(p.pid);
    if (!mounted) return;
    if (!r.ok) {
      setState(() => _killing.remove(p.pid));
      showDuckToast(
        context,
        '${S.processKillFailed} ${p.name} (${p.pid}): ${r.message ?? ''}',
      );
    } else {
      // Eager UI update — drop the row before the next refresh
      // confirms it. If the kill silently failed (rare:
      // taskkill returned 0 but OS lied), the next snapshot
      // will re-introduce the row.
      setState(() {
        _all = _all.where((q) => q.pid != p.pid).toList(growable: false);
      });
      // Trigger a refresh slightly after to reconcile.
      Future.delayed(const Duration(milliseconds: 300), _refresh);
    }
  }

  Future<void> _killAllMatching(List<ProcessInfo> matching) async {
    if (matching.isEmpty) return;
    final confirmed = await _confirmBulkKill(matching.length);
    if (!confirmed || !mounted) return;
    setState(() {
      for (final p in matching) {
        _killing.add(p.pid);
      }
    });
    int failed = 0;
    for (final p in matching) {
      final r = await ProcessManagerService.kill(p.pid);
      if (!r.ok) failed++;
    }
    if (!mounted) return;
    if (failed > 0) {
      showDuckToast(context, S.processKillBulkPartial(matching.length - failed, failed));
    } else {
      showDuckToast(context, S.processKillBulkDone(matching.length));
    }
    await _refresh();
  }

  Future<bool> _confirmBulkKill(int count) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.border, width: 0.5),
        ),
        title: Text(
          S.processKillBulkConfirmTitle,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        content: Text(
          S.processKillBulkConfirmBody(count),
          style: const TextStyle(fontSize: 12.5, color: DuckColors.fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.processKillBulkConfirmAction,
              style: const TextStyle(color: DuckColors.stateError),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ── Filtering ───────────────────────────────────────────────────────

  ProcessFilterContext _ctx(AppState state) => ProcessFilterContext(
        workspacePath: state.currentDirectory,
        lumenSpawned: _lumenExpanded,
      );

  List<ProcessInfo> _filtered(ProcessFilterContext ctx) {
    final q = _query.trim().toLowerCase();
    final out = <ProcessInfo>[];
    for (final p in _all) {
      if (!ProcessFilters.matches(_preset, p, ctx)) continue;
      if (q.isNotEmpty && !p.haystack.contains(q)) continue;
      out.add(p);
    }
    out.sort((a, b) {
      final am = a.memoryBytes ?? 0;
      final bm = b.memoryBytes ?? 0;
      if (am != bm) return bm.compareTo(am);
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return out;
  }

  int _countFor(ProcessFilterPreset preset, ProcessFilterContext ctx) {
    var n = 0;
    for (final p in _all) {
      if (ProcessFilters.matches(preset, p, ctx)) n++;
    }
    return n;
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ctx = _ctx(state);
    final filtered = _filtered(ctx);

    return Container(
      color: DuckColors.bgRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(filtered),
          _buildToolbar(ctx),
          if (_error != null) _buildErrorBanner(),
          Expanded(child: _buildBody(filtered)),
          _buildFooter(filtered),
        ],
      ),
    );
  }

  Widget _buildHeader(List<ProcessInfo> filtered) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.memory_outlined,
            size: 18,
            color: DuckColors.fgMuted,
          ),
          const SizedBox(width: 8),
          const Text(
            S.processManagerTitle,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 10),
          if (_isRefreshing)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: DuckColors.fgMuted,
              ),
            ),
          const Spacer(),
          if (filtered.isNotEmpty && _preset != ProcessFilterPreset.all)
            _HeaderButton(
              label: S.processKillAllMatching(filtered.length),
              danger: true,
              onTap: () => _killAllMatching(filtered),
            ),
          const SizedBox(width: 8),
          _HeaderButton(
            label: _autoRefresh
                ? S.processAutoRefreshOn
                : S.processAutoRefreshOff,
            onTap: () {
              setState(() => _autoRefresh = !_autoRefresh);
              _scheduleRefresh();
            },
          ),
          const SizedBox(width: 8),
          _HeaderButton(
            label: S.processRefresh,
            onTap: _refresh,
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar(ProcessFilterContext ctx) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Search field. Plain `TextField` over `re_editor` because
          // the global editor controller would override the IDE's
          // global hotkeys and we want this scoped tightly.
          SizedBox(
            height: 30,
            child: Focus(
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.escape) {
                  setState(() {
                    _query = '';
                    _searchCtrl.clear();
                  });
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: TextField(
                controller: _searchCtrl,
                focusNode: _searchFocus,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgPrimary,
                ),
                decoration: InputDecoration(
                  hintText: S.processSearchHint,
                  hintStyle: const TextStyle(
                    fontSize: 12.5,
                    color: DuckColors.fgSubtle,
                  ),
                  prefixIcon: const Icon(
                    Icons.search,
                    size: 16,
                    color: DuckColors.fgSubtle,
                  ),
                  prefixIconConstraints: const BoxConstraints(
                    minWidth: 30,
                    minHeight: 0,
                  ),
                  isDense: true,
                  filled: true,
                  fillColor: DuckColors.bgChip,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 8,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    borderSide: const BorderSide(
                      color: DuckColors.border,
                      width: 0.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    borderSide: const BorderSide(
                      color: DuckColors.border,
                      width: 0.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    borderSide: const BorderSide(
                      color: DuckColors.borderFocus,
                      width: 1,
                    ),
                  ),
                ),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final preset in ProcessFilterPreset.values)
                ProcessFilterChip(
                  preset: preset,
                  selected: _preset == preset,
                  count: _countFor(preset, ctx),
                  onTap: () => setState(() => _preset = preset),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner() {
    return Container(
      width: double.infinity,
      color: DuckColors.stateError.withValues(alpha: 0.12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(
        '${S.processError}: $_error',
        style: const TextStyle(
          fontSize: 12,
          color: DuckColors.stateError,
        ),
      ),
    );
  }

  Widget _buildBody(List<ProcessInfo> filtered) {
    if (!_initialLoaded) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: DuckColors.accentCyan,
          ),
        ),
      );
    }
    if (filtered.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _all.isEmpty ? S.processEmpty : S.processNoMatches,
            style: const TextStyle(
              fontSize: 13,
              color: DuckColors.fgMuted,
            ),
          ),
        ),
      );
    }
    return Column(
      children: [
        _buildTableHeader(),
        Expanded(
          child: ListView.builder(
            itemCount: filtered.length,
            itemBuilder: (ctx, i) {
              final p = filtered[i];
              return ProcessTableRow(
                info: p,
                isLumenSpawned: _lumenExpanded.contains(p.pid),
                busy: _killing.contains(p.pid),
                onKill: () => _killOne(p),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          bottom: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      child: Row(
        children: const [
          SizedBox(width: 14),
          SizedBox(width: 64, child: _HeaderCell(S.processColPid)),
          SizedBox(width: 200, child: _HeaderCell(S.processColName)),
          SizedBox(width: 90, child: _HeaderCell(S.processColMemory)),
          Expanded(child: _HeaderCell(S.processColCommand)),
          SizedBox(width: 68),
        ],
      ),
    );
  }

  Widget _buildFooter(List<ProcessInfo> filtered) {
    final total = _all.length;
    final matched = filtered.length;
    final spawned = _lumenExpanded.length;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Text(
            S.processFooterStats(total, matched, spawned),
            style: const TextStyle(
              fontSize: 11.5,
              color: DuckColors.fgMuted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  const _HeaderCell(this.label);
  @override
  Widget build(BuildContext context) => Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: DuckColors.fgMuted,
          letterSpacing: 0.5,
        ),
      );
}

class _HeaderButton extends StatelessWidget {
  final String label;
  final bool danger;
  final VoidCallback onTap;

  const _HeaderButton({
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? DuckColors.stateError : DuckColors.fgPrimary;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            border: Border.all(color: DuckColors.border, width: 0.5),
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
