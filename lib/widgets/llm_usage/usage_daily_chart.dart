import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/llm_usage_log_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Daily-bucket bar chart for the "View token usage" panel.
///
/// Stacked bars: input tokens at the bottom (cyan), output on top
/// (gold). Hover shows a per-day tooltip with the exact breakdown
/// including prompts fired that day. Y-axis is auto-scaled to the
/// max bucket; X-axis labels are sampled (first, last, every Nth)
/// so a 90-day window doesn't produce illegible label salad.
///
/// Custom-painted instead of pulling in `fl_chart` — keeps the
/// dependency surface small and the look matches Lumen's other
/// custom visuals (the council stage paints similarly).
class UsageDailyChart extends StatelessWidget {
  final List<LlmUsageDayBucket> buckets;
  final double height;

  const UsageDailyChart({
    super.key,
    required this.buckets,
    this.height = 180,
  });

  @override
  Widget build(BuildContext context) {
    if (buckets.isEmpty) {
      return _EmptyState(height: height);
    }
    int maxValue = 1;
    for (final b in buckets) {
      if (b.billedTotal > maxValue) maxValue = b.billedTotal;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
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
              const Icon(
                Icons.bar_chart_outlined,
                size: 14,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: 6),
              Text(
                S.llmUsageDailyChartTitle,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: DuckColors.fgPrimary,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 10),
              _LegendDot(color: DuckColors.accentCyan, label: S.chatTokenCounterInput),
              const SizedBox(width: 8),
              _LegendDot(color: DuckColors.accentDuck, label: S.chatTokenCounterOutput),
              const Spacer(),
              Text(
                S.llmUsageDailyChartMaxLabel(_formatTokens(maxValue)),
                style: const TextStyle(
                  fontSize: 10.5,
                  color: DuckColors.fgMuted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: height,
            child: LayoutBuilder(
              builder: (context, constraints) {
                return _ChartBody(
                  buckets: buckets,
                  maxValue: maxValue,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTokens(int n) {
    if (n < 1000) return n.toString();
    if (n < 10000) return '${(n / 1000).toStringAsFixed(2)}k';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }
}

class _LegendDot extends StatelessWidget {
  final Color color;
  final String label;
  const _LegendDot({required this.color, required this.label});
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(
          label,
          style: const TextStyle(
            fontSize: 10.5,
            color: DuckColors.fgMuted,
            letterSpacing: 0.2,
          ),
        ),
      ],
    );
  }
}

class _ChartBody extends StatefulWidget {
  final List<LlmUsageDayBucket> buckets;
  final int maxValue;
  final double width;
  final double height;

  const _ChartBody({
    required this.buckets,
    required this.maxValue,
    required this.width,
    required this.height,
  });

  @override
  State<_ChartBody> createState() => _ChartBodyState();
}

class _ChartBodyState extends State<_ChartBody> {
  int? _hoverIdx;

  @override
  Widget build(BuildContext context) {
    final count = widget.buckets.length;
    final reservedAxis = 16.0;
    final plotHeight = (widget.height - reservedAxis).clamp(20.0, double.infinity);
    final slot = widget.width / count;
    final barWidth = (slot * 0.65).clamp(2.0, 20.0).toDouble();

    // X-axis label sampling. Show first + last always; in between,
    // pick every Nth where N is sized so we get ~6–8 labels total.
    // Stops the axis from turning into illegible "May 1 2 3 4 …" salad
    // on a 30/90-day window.
    final labelStride = (count / 7).ceil().clamp(1, count);

    return MouseRegion(
      onExit: (_) => setState(() => _hoverIdx = null),
      child: GestureDetector(
        onTapDown: (details) {
          final idx = (details.localPosition.dx / slot).floor();
          if (idx >= 0 && idx < count) {
            setState(() => _hoverIdx = idx);
          }
        },
        child: Listener(
          onPointerHover: (event) {
            final idx = (event.localPosition.dx / slot).floor();
            if (idx >= 0 && idx < count && idx != _hoverIdx) {
              setState(() => _hoverIdx = idx);
            }
          },
          child: SizedBox(
            width: widget.width,
            height: widget.height,
            child: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  top: 0,
                  height: plotHeight,
                  child: CustomPaint(
                    painter: _BarsPainter(
                      buckets: widget.buckets,
                      maxValue: widget.maxValue,
                      barWidth: barWidth,
                      slotWidth: slot,
                      hoverIdx: _hoverIdx,
                    ),
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: reservedAxis,
                  child: _AxisLabels(
                    buckets: widget.buckets,
                    slotWidth: slot,
                    labelStride: labelStride,
                  ),
                ),
                if (_hoverIdx != null)
                  _HoverTooltip(
                    bucket: widget.buckets[_hoverIdx!],
                    slotWidth: slot,
                    slotIndex: _hoverIdx!,
                    chartWidth: widget.width,
                    chartHeight: widget.height,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  final List<LlmUsageDayBucket> buckets;
  final int maxValue;
  final double barWidth;
  final double slotWidth;
  final int? hoverIdx;

  _BarsPainter({
    required this.buckets,
    required this.maxValue,
    required this.barWidth,
    required this.slotWidth,
    required this.hoverIdx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final baselineY = size.height;
    // Quartile gridlines for a sense of scale without numeric Y-axis.
    final gridPaint = Paint()
      ..color = DuckColors.glassSeam
      ..strokeWidth = 0.5;
    for (var q = 1; q <= 3; q++) {
      final y = baselineY * (1 - q / 4);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final inputPaint = Paint()..color = DuckColors.accentCyan;
    final outputPaint = Paint()..color = DuckColors.accentDuck;
    final hoverHighlightPaint = Paint()
      ..color = DuckColors.bgRaisedHi.withValues(alpha: 0.45);

    for (var i = 0; i < buckets.length; i++) {
      final b = buckets[i];
      final slotX = i * slotWidth;
      final centerX = slotX + slotWidth / 2;
      final leftX = centerX - barWidth / 2;

      if (hoverIdx == i) {
        canvas.drawRect(
          Rect.fromLTWH(slotX, 0, slotWidth, baselineY),
          hoverHighlightPaint,
        );
      }

      if (b.billedTotal == 0) continue;
      final total = b.inputTokens + b.outputTokens;
      if (total == 0) continue;
      final totalH = baselineY * (b.billedTotal / maxValue);
      final inputH = totalH * (b.inputTokens / total);
      final outputH = totalH - inputH;

      // Output stacks on top (lighter visual). Drawn first so input
      // overpaints any 0.5 px subpixel gap at the seam.
      if (outputH > 0) {
        final rect = RRect.fromRectAndCorners(
          Rect.fromLTWH(
            leftX,
            baselineY - totalH,
            barWidth,
            outputH,
          ),
          topLeft: const Radius.circular(2),
          topRight: const Radius.circular(2),
        );
        canvas.drawRRect(rect, outputPaint);
      }
      if (inputH > 0) {
        canvas.drawRect(
          Rect.fromLTWH(
            leftX,
            baselineY - inputH,
            barWidth,
            inputH,
          ),
          inputPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter old) =>
      old.buckets != buckets ||
      old.maxValue != maxValue ||
      old.barWidth != barWidth ||
      old.slotWidth != slotWidth ||
      old.hoverIdx != hoverIdx;
}

class _AxisLabels extends StatelessWidget {
  final List<LlmUsageDayBucket> buckets;
  final double slotWidth;
  final int labelStride;

  const _AxisLabels({
    required this.buckets,
    required this.slotWidth,
    required this.labelStride,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        for (var i = 0; i < buckets.length; i++)
          if (i == 0 ||
              i == buckets.length - 1 ||
              i % labelStride == 0)
            Positioned(
              left: i * slotWidth,
              width: slotWidth,
              top: 2,
              child: Text(
                _shortLabel(buckets[i].day),
                textAlign: TextAlign.center,
                overflow: TextOverflow.clip,
                maxLines: 1,
                style: const TextStyle(
                  fontSize: 9.5,
                  color: DuckColors.fgSubtle,
                  letterSpacing: 0.1,
                ),
              ),
            ),
      ],
    );
  }

  static String _shortLabel(String yyyyMmDd) {
    // YYYY-MM-DD → M/D (locale-agnostic short form).
    final parts = yyyyMmDd.split('-');
    if (parts.length != 3) return yyyyMmDd;
    final m = int.tryParse(parts[1]) ?? 0;
    final d = int.tryParse(parts[2]) ?? 0;
    return '$m/$d';
  }
}

class _HoverTooltip extends StatelessWidget {
  final LlmUsageDayBucket bucket;
  final double slotWidth;
  final int slotIndex;
  final double chartWidth;
  final double chartHeight;

  const _HoverTooltip({
    required this.bucket,
    required this.slotWidth,
    required this.slotIndex,
    required this.chartWidth,
    required this.chartHeight,
  });

  @override
  Widget build(BuildContext context) {
    final lines = <String>[
      bucket.day,
      '${S.llmUsageStatPrompts}: ${bucket.promptCount}',
      '${S.chatTokenCounterInput}: ${_compact(bucket.inputTokens)}',
      '${S.chatTokenCounterOutput}: ${_compact(bucket.outputTokens)}',
      if (bucket.cacheReadTokens > 0)
        '${S.chatTokenCounterCacheRead}: ${_compact(bucket.cacheReadTokens)}',
      if (bucket.reasoningTokens > 0)
        '${S.chatTokenCounterReasoning}: ${_compact(bucket.reasoningTokens)}',
    ];
    final approxWidth = 150.0;
    final centerX = slotIndex * slotWidth + slotWidth / 2;
    var left = centerX - approxWidth / 2;
    if (left + approxWidth > chartWidth) left = chartWidth - approxWidth - 2;
    if (left < 2) left = 2;
    return Positioned(
      left: left,
      top: 6,
      child: IgnorePointer(
        child: Container(
          width: approxWidth,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: DuckColors.bgDeepest,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.border, width: 0.5),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < lines.length; i++) ...[
                Text(
                  lines[i],
                  style: TextStyle(
                    fontSize: 10.5,
                    color: i == 0
                        ? DuckColors.fgPrimary
                        : DuckColors.fgMuted,
                    fontWeight: i == 0 ? FontWeight.w600 : FontWeight.w400,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (i < lines.length - 1) const SizedBox(height: 2),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _compact(int n) {
    if (n < 1000) return n.toString();
    if (n < 10000) return '${(n / 1000).toStringAsFixed(2)}k';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }
}

class _EmptyState extends StatelessWidget {
  final double height;
  const _EmptyState({required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: const Center(
        child: Text(
          S.llmUsageEmpty,
          style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
        ),
      ),
    );
  }
}
