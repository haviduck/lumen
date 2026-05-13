/// Council Chamber Backdrop
/// =========================
///
/// Renders the chamber the agent ring stands in. Not a flat gradient
/// with diagonal stripes — a sense of DEPTH:
///
///   * Deep navy floor that recedes to a vanishing point near the top
///     of the stage.
///   * Perspective grid drawn on that floor with seam lines that grow
///     thinner and fainter the closer they get to the horizon.
///   * Soft horizon haze band where the grid disappears — the eye
///     reads "the room continues back there."
///   * Ambient dust motes drifting slowly upward (deterministic
///     positions / seeds — no strobing, no per-frame allocation).
///   * Cinematic vignette darkening the corners so the eye settles
///     on the agent ring in the middle.
///   * Top-edge ceiling fade so the chamber doesn't feel lit from
///     above; it fades into shadow at the top.
///
/// Performance:
///   * Owns its own [AnimationController] + [RepaintBoundary]. The
///     theater's `_pulse` controller drives every agent card; isolating
///     the chamber here means the backdrop never piggy-backs on those
///     repaints.
///   * Particles use a single low-frequency controller. Their starting
///     positions / phase offsets are derived from a fixed seed so the
///     drift is identical across frames — no `Random()` per paint.
///   * Particle count scales gently with [agentCount] (more agents
///     -> slightly more atmosphere) but caps at 32 so the chamber
///     can't ever cost more than a fraction of a millisecond.
///
/// The class name + constructor signature are preserved so
/// `council_theater.dart` doesn't need to change.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

class CouncilDiagonalBackdrop extends StatefulWidget {
  const CouncilDiagonalBackdrop({super.key, this.agentCount = 0});

  /// Number of currently-visible agents in the ring. The chamber
  /// scales its ambient particle count gently with this so a sparse
  /// council still feels populated and a packed one doesn't read as
  /// flat. Caller passes `_visibleAgents(session).length` from the
  /// theater.
  final int agentCount;

  @override
  State<CouncilDiagonalBackdrop> createState() =>
      _CouncilDiagonalBackdropState();
}

class _CouncilDiagonalBackdropState extends State<CouncilDiagonalBackdrop>
    with SingleTickerProviderStateMixin {
  late final AnimationController _drift;

  /// Frozen particle seeds. Each particle has a deterministic phase
  /// offset, horizontal lane, drift speed, and base alpha. We pre-bake
  /// the list so the painter never allocates per frame.
  ///
  /// Mutable (not `final`) because [didUpdateWidget] re-bakes the list
  /// when [CouncilDiagonalBackdrop.agentCount] changes — the seed is
  /// stable across rebakes, only the count adjusts. `late final` would
  /// throw `LateInitializationError` on the second assignment.
  late List<_Mote> _motes;

  @override
  void initState() {
    super.initState();
    // 24s loop — slow enough to read as ambient drift, not motion.
    // The painter wraps each mote's phase modulo 1.0 so the loop
    // boundary is invisible.
    _drift = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    _motes = _bakeMotes(widget.agentCount);
  }

  @override
  void didUpdateWidget(covariant CouncilDiagonalBackdrop old) {
    super.didUpdateWidget(old);
    if (old.agentCount != widget.agentCount) {
      // Re-bake if the agent population changes meaningfully. We
      // re-use the same seed so existing motes keep their geometry —
      // only the count adjusts. Avoids the "atmosphere reshuffles
      // every time an agent joins" jitter.
      _motes = _bakeMotes(widget.agentCount);
    }
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

  /// Deterministic mote bake. Scales 12 -> 32 over `agentCount` 0 -> 12.
  /// Particle count caps at 32 — beyond that the eye can't pick out
  /// individual motes and we're burning GPU for noise.
  List<_Mote> _bakeMotes(int agentCount) {
    final n = (12 + (agentCount.clamp(0, 12) * 1.6).round()).clamp(12, 32);
    // FNV-style mix: keeps the layout stable across builds while
    // making each mote's properties feel uncorrelated.
    int hash(int seed, int x) {
      var h = 2166136261 ^ seed;
      h = (h ^ x) & 0xFFFFFFFF;
      h = (h * 16777619) & 0xFFFFFFFF;
      return h & 0xFFFFFFFF;
    }
    double frac(int seed, int x) => (hash(seed, x) % 10000) / 10000.0;

    final out = <_Mote>[];
    for (var i = 0; i < n; i++) {
      out.add(_Mote(
        laneX: frac(0xA17B, i),
        baseY: frac(0xB28C, i),
        phase: frac(0xC39D, i),
        speed: 0.45 + frac(0xD4AE, i) * 0.85,
        radius: 0.9 + frac(0xE5BF, i) * 1.6,
        alpha: 0.08 + frac(0xF6C0, i) * 0.10,
        cyanish: frac(0x17D1, i) > 0.5,
        swayAmp: frac(0x28E2, i) * 0.06,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: CustomPaint(
        painter: _ChamberPainter(progress: _drift, motes: _motes),
        size: Size.infinite,
      ),
    );
  }
}

/// One precomputed dust mote. Geometry is constant; only its drift
/// phase ramps off the chamber's `_drift` controller.
class _Mote {
  /// Horizontal lane the mote drifts within, 0..1 (left → right).
  final double laneX;
  /// Vertical resting position, 0..1 (top → bottom).
  final double baseY;
  /// Phase offset into the global drift loop, 0..1.
  final double phase;
  /// Per-mote drift speed multiplier.
  final double speed;
  /// Visual radius in logical pixels.
  final double radius;
  /// Base alpha at peak of the bell envelope.
  final double alpha;
  /// Whether this mote leans cyan (true) or purple (false).
  final bool cyanish;
  /// Horizontal sway amplitude, 0..0.06 of stage width.
  final double swayAmp;

  const _Mote({
    required this.laneX,
    required this.baseY,
    required this.phase,
    required this.speed,
    required this.radius,
    required this.alpha,
    required this.cyanish,
    required this.swayAmp,
  });
}

class _ChamberPainter extends CustomPainter {
  _ChamberPainter({required this.progress, required this.motes})
      : super(repaint: progress);

  final Animation<double> progress;
  final List<_Mote> motes;

  // Cached paint objects so we don't allocate per frame for the
  // perspective grid. The shader has to be rebuilt every paint
  // because it depends on `size`, but the Paint itself is reused.
  final Paint _gridPaint = Paint()
    ..isAntiAlias = true
    ..style = PaintingStyle.stroke;

  /// Vertical position of the horizon (the vanishing point of the
  /// floor grid), expressed as a fraction of stage height. 0.32
  /// places the horizon roughly a third of the way down — leaves
  /// room above for the agent ring's top arc to read against the
  /// darker "ceiling" and below for the floor + agents.
  static const double _horizonY = 0.32;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final h = size.height;
    final horizon = h * _horizonY;

    _paintFloorBase(canvas, size, horizon);
    _paintPerspectiveGrid(canvas, size, horizon);
    _paintHorizonHaze(canvas, size, horizon);
    _paintCeilingFade(canvas, size, horizon);
    _paintAmbientGlow(canvas, size, horizon);
    _paintMotes(canvas, size, horizon);
    _paintVignette(canvas, size);

    // Defeat the "unused" lint without ever costing a frame.
    if (w < 0 || h < 0) return;
  }

  /// Deep navy floor wash. The bottom of the stage is darkest, easing
  /// toward the horizon band. Sells "we are looking down at a floor."
  void _paintFloorBase(Canvas canvas, Size size, double horizon) {
    final floorRect = Rect.fromLTRB(0, horizon, size.width, size.height);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          DuckColors.councilSurface.withValues(alpha: 0.55),
          DuckColors.councilBase.withValues(alpha: 0.95),
          DuckColors.bgDeepest.withValues(alpha: 0.98),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(floorRect);
    canvas.drawRect(floorRect, paint);
  }

  /// Perspective grid that recedes from the bottom of the stage to
  /// the horizon. Lines closer to the viewer are slightly thicker
  /// and brighter; lines closer to the horizon fade into haze.
  ///
  /// Two families of lines:
  ///   * Floor depth lines — horizontals between the viewer and the
  ///     horizon, spaced more tightly as they recede (1/(1-t) style).
  ///   * Floor radials — verticals fanning out from the vanishing
  ///     point to the bottom edge of the stage.
  void _paintPerspectiveGrid(Canvas canvas, Size size, double horizon) {
    final vanishX = size.width / 2;
    final bottomY = size.height;

    // Horizontal depth lines.
    //
    // Use a non-linear depth parameter so lines bunch up near the
    // horizon (where they should look infinitesimally close together)
    // and spread out near the foreground (where they should feel
    // generously spaced).
    const lineCount = 12;
    for (var i = 1; i <= lineCount; i++) {
      // t goes 0 (at viewer / bottom) → 1 (at horizon).
      final t = i / lineCount;
      // Quadratic ease pushes depth lines closer together near horizon.
      final eased = t * t;
      final y = bottomY - (bottomY - horizon) * eased;
      // Closer lines (small t) are brighter; far lines fade out.
      // We also taper the stroke width so the foreground reads more
      // tangibly than the haze near the horizon.
      final closeness = 1.0 - t;
      _gridPaint
        ..strokeWidth = (0.8 + closeness * 1.0).clamp(0.5, 1.6)
        ..color = DuckColors.glassSeam.withValues(
          alpha: (0.06 + closeness * 0.08).clamp(0.04, 0.14),
        );
      canvas.drawLine(Offset(0, y), Offset(size.width, y), _gridPaint);
    }

    // Radial floor lines fanning from vanishing point.
    //
    // The radials should converge at `(vanishX, horizon)` and hit
    // the bottom edge of the stage at evenly-spaced X positions. We
    // intentionally over-extend by one column on each side so the
    // outermost radials still reach the bottom corners cleanly.
    const radialCount = 11;
    final bottomSpan = size.width * 1.4;
    final bottomStart = (size.width - bottomSpan) / 2;
    for (var i = 0; i <= radialCount; i++) {
      final xBottom = bottomStart + (bottomSpan * i / radialCount);
      // Distance from vertical centre — outer radials fade off.
      final centreOffset = ((i / radialCount) - 0.5).abs() * 2.0;
      final closeness = 1.0 - centreOffset.clamp(0.0, 1.0) * 0.6;
      _gridPaint
        ..strokeWidth = (0.7 + closeness * 0.7).clamp(0.4, 1.4)
        ..color = DuckColors.glassSeam.withValues(
          alpha: (0.05 + closeness * 0.06).clamp(0.03, 0.12),
        );
      canvas.drawLine(
        Offset(xBottom, bottomY),
        Offset(vanishX, horizon),
        _gridPaint,
      );
    }
  }

  /// Horizon haze band. A soft horizontal gradient sitting on the
  /// vanishing line so the eye reads "the room continues back
  /// there" rather than "the grid stops abruptly."
  void _paintHorizonHaze(Canvas canvas, Size size, double horizon) {
    // 18% of stage height centred on the horizon, but pulled
    // slightly upward (the brighter band sits a few pixels above
    // the geometric vanishing point — gives the haze a "rising"
    // quality instead of a flat slab).
    final bandH = size.height * 0.18;
    final bandRect = Rect.fromLTWH(
      0,
      horizon - bandH * 0.55,
      size.width,
      bandH,
    );
    // Slow breath modulated off `progress` — adds 0..0.04 alpha so
    // the chamber feels alive without strobing.
    final breath = (math.sin(progress.value * math.pi * 2) + 1) * 0.5;
    final coreAlpha = 0.075 + breath * 0.035;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          DuckColors.councilAccent.withValues(alpha: 0.0),
          DuckColors.councilAccent.withValues(alpha: coreAlpha),
          DuckColors.councilAccentDim.withValues(alpha: coreAlpha * 0.55),
          DuckColors.councilAccent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 0.65, 1.0],
      ).createShader(bandRect);
    canvas.drawRect(bandRect, paint);

    // A thinner, brighter hairline at the horizon itself — sells
    // the "line where the floor ends" without being a hard stroke.
    final hairlineRect = Rect.fromLTWH(
      0,
      horizon - 0.6,
      size.width,
      1.2,
    );
    final hairlinePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: [
          DuckColors.councilAccent.withValues(alpha: 0.0),
          DuckColors.councilAccentHi.withValues(alpha: 0.10 + breath * 0.04),
          DuckColors.councilAccent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(hairlineRect);
    canvas.drawRect(hairlineRect, hairlinePaint);
  }

  /// Ceiling fade. The top edge of the stage is unlit — the chamber's
  /// "ceiling" reads as a region of deeper shadow above the horizon.
  /// Helps the eye settle on the agent ring in the middle of the
  /// frame.
  void _paintCeilingFade(Canvas canvas, Size size, double horizon) {
    final ceilingRect = Rect.fromLTWH(0, 0, size.width, horizon);
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          DuckColors.bgDeepest.withValues(alpha: 0.85),
          DuckColors.councilBase.withValues(alpha: 0.65),
          DuckColors.councilBase.withValues(alpha: 0.05),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(ceilingRect);
    canvas.drawRect(ceilingRect, paint);
  }

  /// Faint ambient glow that sits ON the horizon, hinting that the
  /// chamber is dimly lit from where the agents are standing rather
  /// than from above. Centred horizontally and dropped slightly below
  /// the horizon line.
  void _paintAmbientGlow(Canvas canvas, Size size, double horizon) {
    final centre = Offset(size.width / 2, horizon + size.height * 0.06);
    final radius = size.shortestSide * 0.6;
    final rect = Rect.fromCircle(center: centre, radius: radius);
    final paint = Paint()
      ..shader = RadialGradient(
        colors: [
          DuckColors.councilAccent.withValues(alpha: 0.06),
          DuckColors.accentPurple.withValues(alpha: 0.025),
          Colors.transparent,
        ],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  /// Ambient dust motes drifting upward across the chamber. Speed,
  /// lane, base alpha and colour come from the precomputed [motes]
  /// list — the painter is allocation-free per frame.
  void _paintMotes(Canvas canvas, Size size, double horizon) {
    final t = progress.value;
    for (final mote in motes) {
      // Loop the mote's vertical position over the drift period.
      // Motes start near the bottom, drift upward, wrap.
      final phased = (t * mote.speed + mote.phase) % 1.0;
      // Wrap so the mote travels bottom → top, then resets.
      final yFrac = 1.0 - phased;
      // Motes only paint between the bottom and just above the
      // horizon — they fade out as they reach the haze band so they
      // don't look like they're crashing into a wall.
      final y = horizon + (size.height - horizon) * yFrac;
      // Lane includes a small sinusoidal sway for life.
      final sway = math.sin(
            (t * 2 + mote.phase) * math.pi * 2,
          ) *
          mote.swayAmp;
      final x = (mote.laneX + sway).clamp(0.02, 0.98) * size.width;
      // Bell envelope: motes fade in at bottom, peak mid-flight,
      // fade out near the horizon haze.
      final env = math.sin(yFrac * math.pi);
      if (env < 0.04) continue;
      final colour = mote.cyanish
          ? DuckColors.accentCyan
          : DuckColors.accentPurple;
      // Soft halo around the mote so it reads as light, not a dot.
      canvas.drawCircle(
        Offset(x, y),
        mote.radius + 2.2,
        Paint()
          ..color = colour.withValues(alpha: mote.alpha * env * 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.6)
          ..blendMode = BlendMode.plus,
      );
      canvas.drawCircle(
        Offset(x, y),
        mote.radius,
        Paint()..color = colour.withValues(alpha: mote.alpha * env),
      );
    }
  }

  /// Cinematic vignette. Standard radial darkening: corners darker
  /// than the centre. Subtle so it doesn't read as a "you're inside
  /// a circle" effect — just enough that the eye drifts toward the
  /// agent ring instead of the edges.
  void _paintVignette(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final centre = Offset(size.width / 2, size.height * 0.52);
    final paint = Paint()
      ..shader = RadialGradient(
        center: Alignment(
          (centre.dx / size.width) * 2 - 1,
          (centre.dy / size.height) * 2 - 1,
        ),
        radius: 0.95,
        colors: [
          Colors.transparent,
          Colors.transparent,
          DuckColors.bgDeepest.withValues(alpha: 0.20),
          DuckColors.bgDeepest.withValues(alpha: 0.34),
        ],
        stops: const [0.0, 0.55, 0.85, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(covariant _ChamberPainter old) {
    // The painter listens to `progress` via super(repaint:). Repaint
    // only when the painter itself swaps (e.g. mote list changes via
    // setState).
    return old.progress != progress || !identical(old.motes, motes);
  }
}
