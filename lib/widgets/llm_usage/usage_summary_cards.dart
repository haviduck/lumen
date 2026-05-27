import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/llm_usage_log_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Top-of-panel row of four summary stat cards.
///
/// Headline numbers for the current filter slice — prompts fired,
/// input tokens, output tokens, billed total. The latter sums the
/// three chargeable token buckets (input + output + cache-write +
/// reasoning), matching the in-chat counter chip's headline so the
/// numbers don't disagree between the two surfaces.
///
/// Pulled into its own file because the column layout (Wrap with
/// per-card min/max widths, responsive spacing) is independent of
/// the daily chart + model table siblings and tends to get tweaked
/// in isolation when the design changes.
class UsageSummaryCards extends StatelessWidget {
  final LlmUsageAggregate agg;

  const UsageSummaryCards({super.key, required this.agg});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: [
        _Card(
          icon: Icons.forum_outlined,
          accent: DuckColors.accentCyan,
          label: S.llmUsageStatPrompts,
          value: _Formatter.compact(agg.promptCount),
          tooltip: S.llmUsageStatPromptsTooltip,
          exact: _Formatter.exact(agg.promptCount),
        ),
        _Card(
          icon: Icons.arrow_upward,
          accent: DuckColors.accentCyan,
          label: S.llmUsageStatInput,
          value: _Formatter.compact(agg.inputTokens),
          tooltip: S.llmUsageStatInputTooltip,
          exact: _Formatter.exact(agg.inputTokens),
        ),
        _Card(
          icon: Icons.arrow_downward,
          accent: DuckColors.accentDuck,
          label: S.llmUsageStatOutput,
          value: _Formatter.compact(agg.outputTokens),
          tooltip: S.llmUsageStatOutputTooltip,
          exact: _Formatter.exact(agg.outputTokens),
        ),
        _Card(
          icon: Icons.functions,
          accent: DuckColors.accentPurple,
          label: S.llmUsageStatBilledTotal,
          value: _Formatter.compact(agg.billedTotal),
          tooltip: S.llmUsageStatBilledTotalTooltip,
          exact: _Formatter.exact(agg.billedTotal),
        ),
        if (agg.cacheReadTokens > 0 || agg.cacheWriteTokens > 0)
          _Card(
            icon: Icons.bolt_outlined,
            accent: DuckColors.accentMint,
            label: S.llmUsageStatCache,
            value: _Formatter.compact(agg.cacheReadTokens),
            tooltip: S.llmUsageStatCacheTooltip,
            exact:
                '${S.chatTokenCounterCacheRead}: ${_Formatter.exact(agg.cacheReadTokens)}\n'
                '${S.chatTokenCounterCacheWrite}: ${_Formatter.exact(agg.cacheWriteTokens)}',
          ),
        if (agg.reasoningTokens > 0)
          _Card(
            icon: Icons.psychology_outlined,
            accent: DuckColors.accentPurple,
            label: S.llmUsageStatReasoning,
            value: _Formatter.compact(agg.reasoningTokens),
            tooltip: S.llmUsageStatReasoningTooltip,
            exact: _Formatter.exact(agg.reasoningTokens),
          ),
      ],
    );
  }
}

class _Card extends StatelessWidget {
  final IconData icon;
  final Color accent;
  final String label;
  final String value;
  final String tooltip;
  final String exact;

  const _Card({
    required this.icon,
    required this.accent,
    required this.label,
    required this.value,
    required this.tooltip,
    required this.exact,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$tooltip\n\n$exact',
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        width: 168,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: DuckColors.bgDeeper,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.border, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 14, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                      color: DuckColors.fgMuted,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              value,
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
                fontFeatures: [FontFeature.tabularFigures()],
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Number formatters reused by the summary cards + tooltips. Static
/// so callers don't have to thread a state object through every cell.
class _Formatter {
  static String compact(int n) {
    if (n < 1000) return n.toString();
    if (n < 10000) return '${(n / 1000).toStringAsFixed(2)}k';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    if (n < 10000000) return '${(n / 1000000).toStringAsFixed(2)}M';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  static String exact(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
