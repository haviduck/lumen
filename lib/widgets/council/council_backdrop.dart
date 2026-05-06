import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Ambient diagonal-line drift background for the Council theater.
///
/// Owns its own [AnimationController] so background repaints do NOT
/// piggy-back on `_CouncilTheaterState._pulse` — that pulse drives the
/// stage `AnimatedBuilder` which rebuilds every agent card on each
/// tick. Hosting the drift here in an isolated [RepaintBoundary] keeps
/// the background at 60fps without dragging the rest of the stage into
/// the repaint cycle.
///
/// Layer contract (z-order, bottom → top):
///   1. CouncilDiagonalBackdrop  ← this widget
///   2. Blackboard surface       (Vista)
///   3. Traffic + agent cards    (Vista)
///   4. Speech bubbles           (Vista)
///   5. Modal chrome / panels    (orchestrator ping, user prompt, …)
///
/// Respects `MediaQuery.disableAnimations` — when reduced motion is
/// requested the painter renders one static frame and the controller
/// is never started.
class CouncilDiagonalBackdrop extends StatefulWidget {
  const CouncilDiagonalBackdrop({super.key, this.agentCount = 0});

  final int agentCount;

  @override
  State<CouncilDiagonalBackdrop> createState() =>
      _CouncilDiagonalBackdropState();
}

class _CouncilDiagonalBackdropState extends State<CouncilDiagonalBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  @override
  void initState() {
    super.initState();
    // 18s loop → ~2.3 px/sec drift on a 42px stride. Slow enough to
    // feel ambient, fast enough to register as motion. Linear curve so
    // the seamless wrap-around at the period boundary is invisible.
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 18),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      if (_drift.isAnimating) _drift.stop();
      _drift.value = 0;
    } else if (!_drift.isAnimating) {
      _drift.repeat();
    }
  }

  @override
  void dispose() {
    _drift.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _DiagonalDriftPainter(progress: _drift),
        size: Size.infinite,
      ),
    );
  }
}

class _DiagonalDriftPainter extends CustomPainter {
  _DiagonalDriftPainter({required this.progress}) : super(repaint: progress);

  final Animation<double> progress;

  static const double _stride = 42.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    // Soft radial halo sets the stage depth. Replaces the ring/node
    // "starfish" that used to live in `_CouncilAtmospherePainter` —
    // the rings + radial pulse-nodes were the culprit visible on
    // refresh; only the halo + diagonal drift survive.
    final shortest = size.shortestSide;
    final center = Offset(size.width / 2, size.height * 0.42);
    final haloRect = Rect.fromCircle(center: center, radius: shortest * 0.62);
    final haloPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          DuckColors.accentCyan.withValues(alpha: 0.10),
          DuckColors.accentPurple.withValues(alpha: 0.045),
          Colors.transparent,
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(haloRect);
    canvas.drawRect(haloRect, haloPaint);

    // Diagonal drift. One paint, many lines, no per-line allocation.
    // `borderStrong` at very low alpha is intentionally neutral —
    // mint/cyan at any alpha would reinforce the "green everywhere"
    // complaint we just killed elsewhere.
    final linePaint = Paint()
      ..isAntiAlias = true
      ..strokeWidth = 0.8
      ..color = DuckColors.borderStrong.withValues(alpha: 0.07);

    final accentPaint = Paint()
      ..isAntiAlias = true
      ..strokeWidth = 0.8
      ..color = DuckColors.accentCyan.withValues(alpha: 0.045);

    final t = progress.value;
    // Drift one full stride across the loop period — wraps seamlessly
    // because the line pattern itself has period `_stride`.
    final driftX = t * _stride;
    final slope = size.height * 0.42; // gentle 22° lean
    final startX = -size.height - _stride + (driftX % _stride);

    var i = 0;
    for (var x = startX; x < size.width + _stride; x += _stride) {
      // Every 5th line picks up the cyan accent — a faint rhythm
      // without crossing into "stripes".
      final paint = (i % 5 == 0) ? accentPaint : linePaint;
      canvas.drawLine(Offset(x, 0), Offset(x + slope, size.height), paint);
      i++;
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalDriftPainter oldDelegate) {
    // Listen via super(repaint: progress) — Flutter handles repaint
    // notifications. Only repaint on actual constructor swap.
    return oldDelegate.progress != progress;
  }
}
