import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/token_usage.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Live per-chat token usage panel.
///
/// Mounts in the composer's model-watcher row, right-edge of the row,
/// as a peer to the `_ModelPicker` on the left. Sized + styled to
/// match the picker's visual weight (same border radius, padding,
/// surface tokens, icon scale) so the row reads as a balanced
/// "model in / tokens out" pair rather than picker-plus-chip.
///
/// Always rendered (no `isEmpty` gating). Producers that don't report
/// usage yet — Ollama before its first done-frame, Gemini before its
/// first `usageMetadata`, a brand-new chat with zero turns — display
/// `—` placeholders so the slot is discoverable from turn zero
/// instead of looking dead.
///
/// Three live numbers:
///   - **`↑ INPUT`** — system + history + user-prompt tokens billed
///     this session (excludes prompt-cache reads).
///   - **`↓ OUTPUT`** — model-emitted tokens billed this session,
///     including reasoning when the provider folds it into the
///     output count (Ollama, Anthropic). Reasoning-broken-out
///     providers (Gemini's `thoughtsTokenCount`, Copilot's
///     `reasoningTokens`) surface the split in the tooltip.
///   - **`%`** — context-window utilization when known (Copilot's
///     `session.usage_info`). Tints amber past 85 %, red past 95 %
///     so the user notices BEFORE the next turn gets compacted /
///     refused by the model.
///
/// Tooltip breaks every dimension out (cache read, cache write,
/// reasoning, full thousands-separator input/output) so cost audits
/// don't require math.
class TokenCounterChip extends StatelessWidget {
  final SessionTokenStats stats;
  final bool compact;

  const TokenCounterChip({
    super.key,
    required this.stats,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    final utilization = stats.contextUtilization;
    final tight = utilization != null && utilization >= 0.85;
    final critical = utilization != null && utilization >= 0.95;
    final hasData = !stats.isEmpty;

    final pctAccent = critical
        ? DuckColors.stateError
        : tight
            ? DuckColors.stateWarn
            : DuckColors.accentCyan;

    final placeholder = '—';
    final inText = hasData ? _formatTokens(stats.inputTokens) : placeholder;
    final effectiveOutput = stats.outputTokens + stats.streamingOutputEstimate;
    final outText = hasData ? _formatTokens(effectiveOutput) : placeholder;
    final pctText = utilization != null
        ? '${(utilization * 100).toStringAsFixed(0)}%'
        : placeholder;

    final borderColor = critical || tight
        ? pctAccent.withValues(alpha: 0.55)
        : DuckColors.border;

    return Tooltip(
      message: _buildTooltip(stats),
      waitDuration: const Duration(milliseconds: 300),
      preferBelow: false,
      child: MouseRegion(
        cursor: SystemMouseCursors.help,
        child: AnimatedContainer(
          duration: DuckMotion.instant,
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 6 : 8,
            vertical: 4,
          ),
          decoration: BoxDecoration(
            color: DuckColors.bgDeeper,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: borderColor, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _DirectionStat(
                icon: Icons.arrow_upward,
                label: compact ? null : S.chatTokenCounterInputShort,
                value: inText,
                accent: DuckColors.accentCyan,
                dim: !hasData,
              ),
              _Separator(),
              _DirectionStat(
                icon: Icons.arrow_downward,
                label: compact ? null : S.chatTokenCounterOutputShort,
                value: outText,
                accent: DuckColors.accentDuck,
                dim: !hasData,
              ),
              _Separator(),
              _ContextPercent(
                text: pctText,
                accent: pctAccent,
                utilization: utilization,
                dim: utilization == null,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _buildTooltip(SessionTokenStats s) {
    final lines = <String>[
      S.chatTokenCounterTooltipTitle,
      '',
      '${S.chatTokenCounterInput}: ${_formatTokens(s.inputTokens, exact: true)}',
      '${S.chatTokenCounterOutput}: '
          '${_formatTokens(s.outputTokens, exact: true)}',
    ];
    if (s.cacheReadTokens > 0) {
      lines.add(
        '${S.chatTokenCounterCacheRead}: '
        '${_formatTokens(s.cacheReadTokens, exact: true)}',
      );
    }
    if (s.cacheWriteTokens > 0) {
      lines.add(
        '${S.chatTokenCounterCacheWrite}: '
        '${_formatTokens(s.cacheWriteTokens, exact: true)}',
      );
    }
    if (s.reasoningTokens > 0) {
      lines.add(
        '${S.chatTokenCounterReasoning}: '
        '${_formatTokens(s.reasoningTokens, exact: true)}',
      );
    }
    final ctx = s.contextWindowTokens;
    final lim = s.tokenLimit;
    if (ctx != null && lim != null && lim > 0) {
      lines.add('');
      final pct = ((ctx / lim) * 100).toStringAsFixed(1);
      lines.add(
        '${S.chatTokenCounterContext}: '
        '${_formatTokens(ctx, exact: true)} / '
        '${_formatTokens(lim, exact: true)} ($pct%)',
      );
    }
    lines.add('');
    lines.add(S.chatTokenCounterFooter);
    return lines.join('\n');
  }

  /// Compact human-readable formatter — `1.2k`, `3.4M`, etc. When
  /// [exact] is true (tooltip body) we render the full integer with
  /// thousands separators so the user can audit the precise count.
  static String _formatTokens(int n, {bool exact = false}) {
    if (exact) {
      return _withThousandsSeparator(n);
    }
    if (n < 1000) return n.toString();
    if (n < 10000) return '${(n / 1000).toStringAsFixed(2)}k';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    if (n < 10000000) return '${(n / 1000000).toStringAsFixed(2)}M';
    return '${(n / 1000000).toStringAsFixed(1)}M';
  }

  static String _withThousandsSeparator(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}

/// Pre-measured visual height of the token-counter element (the model
/// picker is sized similarly). Exported so the model-watcher row can
/// reserve a stable line height when the counter swaps content.
const double kTokenCounterChipHeight = 22;

/// Internal sub-widget — the `↑ in 1.2k` cluster. Pulled out so the
/// row layout stays declarative and the dim state (no data yet) reads
/// uniformly across input/output.
class _DirectionStat extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String value;
  final Color accent;
  final bool dim;

  const _DirectionStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.accent,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    final fg = dim ? DuckColors.fgSubtle : DuckColors.fgPrimary;
    final accentColor = dim ? DuckColors.fgMuted : accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: accentColor),
        const SizedBox(width: 3),
        if (label != null) ...[
          Text(
            label!,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: DuckColors.fgMuted,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(width: 3),
        ],
        Text(
          value,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: fg,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

/// Internal sub-widget — the trailing `8%` + ~12 px progress bar
/// when context-window data is available. The bar is INLINE with the
/// percentage (not a row below) so the panel keeps a single text-line
/// height matching the model picker's.
class _ContextPercent extends StatelessWidget {
  final String text;
  final Color accent;
  final double? utilization;
  final bool dim;

  const _ContextPercent({
    required this.text,
    required this.accent,
    required this.utilization,
    required this.dim,
  });

  @override
  Widget build(BuildContext context) {
    final fg = dim ? DuckColors.fgSubtle : accent;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          text,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            color: fg,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (utilization != null) ...[
          const SizedBox(width: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              width: 22,
              height: 4,
              child: LinearProgressIndicator(
                value: utilization,
                backgroundColor: DuckColors.bgRaised,
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Thin vertical divider between the three stat clusters.
class _Separator extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 1,
      height: 11,
      margin: const EdgeInsets.symmetric(horizontal: 7),
      color: DuckColors.glassSeam,
    );
  }
}
