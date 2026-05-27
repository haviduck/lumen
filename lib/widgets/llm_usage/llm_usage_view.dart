import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/llm_usage_log_service.dart';
import '../../theme/app_colors.dart';
import '../common/duck_toast.dart';
import 'usage_daily_chart.dart';
import 'usage_filter_bar.dart';
import 'usage_model_table.dart';
import 'usage_summary_cards.dart';

/// "View token usage" virtual tab.
///
/// Routed by `editor.dart` when the active path matches
/// `AppState.llmUsageSentinel`. Reads from
/// `AppState.llmUsageLog` — the same singleton the chat controller
/// writes to per-iteration — and listens for new entries so the
/// dashboard updates live during an active chat session.
///
/// Layout: full-bleed, no chrome around edges, scrolls internally
/// (same shape as `ProcessManagerView` and `SettingsView`).
///   1. Header — title, "live" indicator, prompt-count summary.
///   2. Filter bar — date range pills, model dropdown, provider
///      dropdown, refresh, reset.
///   3. Summary cards — prompts / input / output / billed total
///      (+ cache and reasoning when present).
///   4. Daily bar chart — stacked input + output per day in range.
///   5. Per-model table — sorted by billed total descending.
///
/// State management:
///   - Recomputes the aggregate on filter changes (cheap; the log
///     is ~tens of KB even after months of heavy use).
///   - Listens to the [LlmUsageLogService] so logs landing during
///     an active chat trigger an automatic re-aggregate without
///     manual refresh.
///   - Distinct-filter list (models / providers) is recomputed
///     alongside so the dropdowns stay in sync as new providers
///     get used.
class LlmUsageView extends StatefulWidget {
  const LlmUsageView({super.key});

  @override
  State<LlmUsageView> createState() => _LlmUsageViewState();
}

class _LlmUsageViewState extends State<LlmUsageView> {
  UsageRange _range = UsageRange.last30;
  String? _modelFilter;
  String? _providerFilter;

  LlmUsageAggregate _agg = LlmUsageAggregate.empty;
  List<String> _availableModels = const [];
  List<String> _availableProviders = const [];
  bool _initialLoaded = false;
  bool _refreshing = false;
  Timer? _debounce;

  LlmUsageLogService? _log;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _wireLog();
      _refresh();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _wireLog();
  }

  void _wireLog() {
    final log = context.read<AppState>().llmUsageLog;
    if (identical(log, _log)) return;
    _log?.removeListener(_onLogChanged);
    _log = log;
    _log!.addListener(_onLogChanged);
  }

  void _onLogChanged() {
    // Debounce — a streaming chat can fire several `log()` calls
    // in quick succession during a multi-iteration agent loop.
    // Coalesce into one re-aggregate.
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 250), _refresh);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _log?.removeListener(_onLogChanged);
    super.dispose();
  }

  LlmUsageFilter _currentFilter() {
    final now = DateTime.now();
    return LlmUsageFilter(
      since: _range.since(now),
      until: _range.until(now),
      provider: _providerFilter,
      model: _modelFilter,
    );
  }

  Future<void> _refresh() async {
    if (_refreshing || _log == null) return;
    setState(() => _refreshing = true);
    try {
      final filter = _currentFilter();
      final results = await Future.wait<dynamic>([
        _log!.aggregate(filter),
        _log!.distinctFilters(),
      ]);
      if (!mounted) return;
      final agg = results[0] as LlmUsageAggregate;
      final distinct = results[1] as ({
        List<String> models,
        List<String> providers,
      });
      setState(() {
        _agg = agg;
        _availableModels = distinct.models;
        _availableProviders = distinct.providers;
        _initialLoaded = true;
        _refreshing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _refreshing = false);
      showDuckToast(context, '${S.error}: $e');
    }
  }

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(
          S.llmUsageResetConfirmTitle,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        content: const Text(
          S.llmUsageResetConfirmBody,
          style: TextStyle(fontSize: 12.5, color: DuckColors.fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              S.llmUsageResetConfirmAction,
              style: TextStyle(color: DuckColors.stateError),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final removed = await _log!.reset();
    if (!mounted) return;
    showDuckToast(context, S.llmUsageResetDone(removed));
    setState(() {
      _modelFilter = null;
      _providerFilter = null;
    });
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DuckColors.bgRaised,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          UsageFilterBar(
            range: _range,
            modelFilter: _modelFilter,
            providerFilter: _providerFilter,
            availableModels: _availableModels,
            availableProviders: _availableProviders,
            onRangeChanged: (r) {
              setState(() => _range = r);
              _refresh();
            },
            onModelChanged: (m) {
              setState(() => _modelFilter = m);
              _refresh();
            },
            onProviderChanged: (p) {
              setState(() => _providerFilter = p);
              _refresh();
            },
            onReset: _confirmReset,
            onRefresh: _refresh,
            refreshing: _refreshing,
          ),
          Expanded(
            child: !_initialLoaded
                ? const Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 1.8,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        UsageSummaryCards(agg: _agg),
                        const SizedBox(height: 16),
                        UsageDailyChart(buckets: _agg.dailyBuckets),
                        const SizedBox(height: 16),
                        UsageModelTable(rows: _agg.byModel),
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
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
            Icons.bar_chart_outlined,
            size: 18,
            color: DuckColors.fgMuted,
          ),
          const SizedBox(width: 8),
          const Text(
            S.llmUsageTitle,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w500,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 10),
          if (_refreshing)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: DuckColors.fgMuted,
              ),
            ),
          const SizedBox(width: 16),
          if (_initialLoaded)
            Text(
              S.llmUsageHeaderSummary(
                _agg.promptCount,
                _agg.billedTotal,
              ),
              style: const TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgMuted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          const Spacer(),
          // Live indicator — pulses when at least one log fired
          // within the past 10 s.
          _LiveDot(log: _log),
        ],
      ),
    );
  }
}

/// Tiny status indicator that lights up when the log has been
/// touched recently. Subscribes to the same change notifier and
/// uses a debounced "fade back to dim" so a burst of writes leaves
/// the dot glowing for a couple of seconds rather than flickering
/// once per event.
class _LiveDot extends StatefulWidget {
  final LlmUsageLogService? log;
  const _LiveDot({required this.log});

  @override
  State<_LiveDot> createState() => _LiveDotState();
}

class _LiveDotState extends State<_LiveDot> {
  bool _active = false;
  Timer? _dim;

  @override
  void initState() {
    super.initState();
    widget.log?.addListener(_onLog);
  }

  @override
  void didUpdateWidget(covariant _LiveDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.log, widget.log)) {
      oldWidget.log?.removeListener(_onLog);
      widget.log?.addListener(_onLog);
    }
  }

  @override
  void dispose() {
    _dim?.cancel();
    widget.log?.removeListener(_onLog);
    super.dispose();
  }

  void _onLog() {
    if (!mounted) return;
    setState(() => _active = true);
    _dim?.cancel();
    _dim = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _active = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 300),
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _active
                ? DuckColors.stateOk
                : DuckColors.fgFaint,
            boxShadow: _active
                ? [
                    BoxShadow(
                      color: DuckColors.stateOk.withValues(alpha: 0.45),
                      blurRadius: 6,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
        ),
        const SizedBox(width: 5),
        Text(
          _active ? S.llmUsageLive : S.llmUsageIdle,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            color: _active ? DuckColors.stateOk : DuckColors.fgMuted,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}
