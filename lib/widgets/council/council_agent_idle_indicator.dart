import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Family of idle/working micro-animations used in the agent card's
/// "transcript well" middle panel.
///
/// All variants share one visual vibe (Vista spec):
///   * monochrome / accent-tinted at very low alpha (≤ 0.22)
///   * low amplitude — nothing bigger than ~3px of motion
///   * slow rhythms (1.6–3.2s cycles) that don't compete with the
///     diagonal-line backdrop (which drifts at ~7s/loop, 27°)
///   * no fills, no shadows, no rounded chrome — strokes + dots only
///
/// Coordination with Loom (CouncilDiagonalBackdrop):
///   * the backdrop owns the diagonal axis (~27°). Idle indicators
///     deliberately use ORTHOGONAL or VERTICAL motion (horizontal
///     sweeps, vertical breathing, sine bars) so they don't read as
///     a second diagonal layer fighting the bg. The one diagonal
///     variant (`diagHairline`) is at a steeper angle (~60°) and
///     a much shorter wavelength so it reads as a different rhythm.
enum AgentIdleVariant {
  shimmerSweep,
  breathingDots,
  diagHairline,
  morphingDottedRule,
  caretPulse,
  /// Horizontal "data stream": a baseline rule with a row of bright
  /// particles traveling left→right, each trailing a short fading tail.
  /// Used as the explicit "AI is awaiting / thinking" idle motion.
  dataStream,
  orbitGlyph,
}

/// Deterministically pick one of the seven variants for a given
/// agent id. Same id → same variant, no matter when called.
///
/// FNV-1a 32-bit on the id bytes. Cheap, stable across sessions,
/// no `Random` involved (no per-frame jitter).
AgentIdleVariant idleVariantForAgent(String agentId) {
  if (agentId.isEmpty) return AgentIdleVariant.shimmerSweep;
  var hash = 0x811c9dc5;
  for (var i = 0; i < agentId.length; i++) {
    hash ^= agentId.codeUnitAt(i);
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  final values = AgentIdleVariant.values;
  return values[hash % values.length];
}

/// Single entry-point widget. Pick variant explicitly or pass an
/// agent id and let the dispatcher decide.
class AgentIdleIndicator extends StatefulWidget {
  final AgentIdleVariant variant;
  final Color accent;

  /// When false the widget renders a static, low-alpha baseline
  /// (no animation tick). Lets callers keep the indicator mounted
  /// for layout reasons but go silent when the agent isn't working.
  final bool active;

  const AgentIdleIndicator({
    super.key,
    required this.variant,
    required this.accent,
    this.active = true,
  });

  AgentIdleIndicator.forAgent({
    super.key,
    required String agentId,
    required this.accent,
    this.active = true,
  }) : variant = idleVariantForAgent(agentId);

  @override
  State<AgentIdleIndicator> createState() => _AgentIdleIndicatorState();
}

class _AgentIdleIndicatorState extends State<AgentIdleIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t;

  @override
  void initState() {
    super.initState();
    _t = AnimationController(
      vsync: this,
      duration: _periodFor(widget.variant),
    );
    if (widget.active) _t.repeat();
  }

  @override
  void didUpdateWidget(covariant AgentIdleIndicator old) {
    super.didUpdateWidget(old);
    if (widget.variant != old.variant) {
      _t.duration = _periodFor(widget.variant);
    }
    if (widget.active && !_t.isAnimating) _t.repeat();
    if (!widget.active && _t.isAnimating) _t.stop();
  }

  Duration _periodFor(AgentIdleVariant v) {
    switch (v) {
      case AgentIdleVariant.shimmerSweep:
        return const Duration(milliseconds: 2200);
      case AgentIdleVariant.breathingDots:
        return const Duration(milliseconds: 2800);
      case AgentIdleVariant.diagHairline:
        return const Duration(milliseconds: 1900);
      case AgentIdleVariant.morphingDottedRule:
        return const Duration(milliseconds: 3200);
      case AgentIdleVariant.caretPulse:
        return const Duration(milliseconds: 1600);
      case AgentIdleVariant.dataStream:
        // ~1500ms is sweet spot: particles read as continuously moving
        // without feeling frantic. Each particle takes one full cycle to
        // traverse, with 5 staggered → ~3.3 Hz pulse rate at the eye.
        return const Duration(milliseconds: 1500);
      case AgentIdleVariant.orbitGlyph:
        return const Duration(milliseconds: 2600);
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) {
          return CustomPaint(
            painter: _IdlePainter(
              variant: widget.variant,
              t: widget.active ? _t.value : 0.0,
              accent: widget.accent,
            ),
          );
        },
      ),
    );
  }
}

class _IdlePainter extends CustomPainter {
  final AgentIdleVariant variant;
  final double t;
  final Color accent;

  _IdlePainter({
    required this.variant,
    required this.t,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    switch (variant) {
      case AgentIdleVariant.shimmerSweep:
        _shimmerSweep(canvas, size);
        break;
      case AgentIdleVariant.breathingDots:
        _breathingDots(canvas, size);
        break;
      case AgentIdleVariant.diagHairline:
        _diagHairline(canvas, size);
        break;
      case AgentIdleVariant.morphingDottedRule:
        _morphingDottedRule(canvas, size);
        break;
      case AgentIdleVariant.caretPulse:
        _caretPulse(canvas, size);
        break;
      case AgentIdleVariant.dataStream:
        _dataStream(canvas, size);
        break;
      case AgentIdleVariant.orbitGlyph:
        _orbitGlyph(canvas, size);
        break;
    }
  }

  // ---------- variants ----------

  /// 1. A 1px horizontal rule with a soft accent gradient sliding L→R.
  void _shimmerSweep(Canvas canvas, Size size) {
    final y = size.height * 0.5;
    final base = Paint()
      ..color = DuckColors.fgSubtle.withValues(alpha: 0.10)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(size.width * 0.06, y),
      Offset(size.width * 0.94, y),
      base,
    );

    final sweepW = size.width * 0.32;
    final cx = -sweepW + (size.width + sweepW * 2) * t;
    final shader = LinearGradient(
      colors: [
        accent.withValues(alpha: 0.0),
        accent.withValues(alpha: 0.22),
        accent.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(Rect.fromLTWH(cx - sweepW / 2, y - 1, sweepW, 2));
    final glow = Paint()
      ..shader = shader
      ..strokeWidth = 1.4;
    canvas.drawLine(
      Offset(cx - sweepW / 2, y),
      Offset(cx + sweepW / 2, y),
      glow,
    );
  }

  /// 2. Five vertical dots, each breathing on a phase offset.
  void _breathingDots(Canvas canvas, Size size) {
    const n = 5;
    final cx = size.width * 0.5;
    final spacing = math.min(8.0, size.height * 0.12);
    final totalH = spacing * (n - 1);
    final topY = (size.height - totalH) * 0.5;
    for (var i = 0; i < n; i++) {
      final phase = (t + i * 0.18) % 1.0;
      final pulse = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
      final r = 1.2 + pulse * 0.9;
      final paint = Paint()
        ..color = accent.withValues(alpha: 0.10 + pulse * 0.12);
      canvas.drawCircle(Offset(cx, topY + spacing * i), r, paint);
    }
  }

  /// 3. A short hairline traveling diagonally — steeper than the bg
  /// (~60° vs bg's ~27°) so it reads as a different rhythm, not a
  /// second drift layer.
  void _diagHairline(Canvas canvas, Size size) {
    final angle = -60 * math.pi / 180;
    final dx = math.cos(angle);
    final dy = math.sin(angle);
    final diag = math.sqrt(size.width * size.width + size.height * size.height);
    // Travel from below-left to above-right, looping.
    final progress = t;
    final cx = size.width * 0.5 + (progress - 0.5) * size.width * 1.4;
    final cy = size.height * 0.5 - (progress - 0.5) * size.height * 1.4;
    final segLen = math.min(diag * 0.22, 28.0);
    final p1 = Offset(cx - dx * segLen / 2, cy - dy * segLen / 2);
    final p2 = Offset(cx + dx * segLen / 2, cy + dy * segLen / 2);

    // Fade in/out at the travel ends.
    final fade = math.sin(progress * math.pi);
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.18 * fade)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(p1, p2, paint);
  }

  /// 4. A row of dots whose radii morph in a rolling wave.
  void _morphingDottedRule(Canvas canvas, Size size) {
    final y = size.height * 0.5;
    const n = 9;
    final padX = size.width * 0.08;
    final span = size.width - padX * 2;
    for (var i = 0; i < n; i++) {
      final x = padX + span * (i / (n - 1));
      final phase = (t + i / n) % 1.0;
      final wave = 0.5 + 0.5 * math.sin(phase * math.pi * 2);
      final r = 0.8 + wave * 1.1;
      final paint = Paint()
        ..color = accent.withValues(alpha: 0.08 + wave * 0.14);
      canvas.drawCircle(Offset(x, y), r, paint);
    }
  }

  /// 5. A short typewriter caret that pulses with a random-feeling dwell.
  void _caretPulse(Canvas canvas, Size size) {
    final cx = size.width * 0.5;
    final cy = size.height * 0.5;
    // Asymmetric duty cycle — long on, short off — feels like a caret.
    final phase = t;
    final visible = phase < 0.62
        ? 1.0
        : phase < 0.78
            ? 1.0 - (phase - 0.62) / 0.16
            : phase < 0.92
                ? 0.0
                : (phase - 0.92) / 0.08;
    final caretH = math.min(10.0, size.height * 0.42);
    final paint = Paint()
      ..color = accent.withValues(alpha: 0.20 * visible)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx, cy - caretH / 2),
      Offset(cx, cy + caretH / 2),
      paint,
    );
    // Anchoring rule under the caret so the panel doesn't read empty
    // during the off-phase.
    final rule = Paint()
      ..color = DuckColors.fgSubtle.withValues(alpha: 0.08)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(cx - 14, cy + caretH / 2 + 3),
      Offset(cx + 14, cy + caretH / 2 + 3),
      rule,
    );
  }

  /// 6. Horizontal "data stream": a faint baseline rule with five bright
  /// particles flowing left→right at staggered phase offsets, each
  /// trailing a short fading tail. Reads as continuously moving "data
  /// in the wire" — distinct from any other variant in this family.
  void _dataStream(Canvas canvas, Size size) {
    final left = size.width * 0.06;
    final right = size.width * 0.94;
    final width = (right - left).clamp(8.0, double.infinity);
    final cy = size.height * 0.5;

    // Faint baseline rule so the panel doesn't read empty between particles.
    final baseline = Paint()
      ..color = DuckColors.fgSubtle.withValues(alpha: 0.10)
      ..strokeWidth = 1.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(left, cy), Offset(right, cy), baseline);

    const n = 5;
    const tailSteps = 4;

    Offset positionAt(double phase, int slot) {
      final x = left + width * phase;
      // Subtle vertical drift per slot so particles feel organic.
      final drift =
          math.sin((phase * math.pi * 2) + slot * 1.13) * 1.6 +
          math.sin((phase * math.pi * 4) + slot * 0.37) * 0.6;
      return Offset(x, cy + drift);
    }

    for (var i = 0; i < n; i++) {
      final phase = (t + i / n) % 1.0;
      // Bell envelope: fades in/out at the wire ends.
      final env = math.sin(phase * math.pi);
      if (env <= 0.04) continue;
      final head = positionAt(phase, i);

      // Trail: shrink + fade a few steps behind the head.
      for (var k = tailSteps; k >= 1; k--) {
        final tailPhase = phase - k * 0.028;
        if (tailPhase <= 0) continue;
        final p = positionAt(tailPhase, i);
        final fade = env * (1.0 - k / (tailSteps + 1.0));
        canvas.drawCircle(
          p,
          1.4 * (1.0 - k / (tailSteps + 1.5)),
          Paint()..color = accent.withValues(alpha: 0.55 * fade),
        );
      }

      // Soft halo behind the head.
      canvas.drawCircle(
        head,
        4.2,
        Paint()
          ..color = accent.withValues(alpha: 0.20 * env)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.5)
          ..blendMode = BlendMode.plus,
      );

      // Bright head.
      canvas.drawCircle(
        head,
        1.9,
        Paint()..color = accent.withValues(alpha: 0.92 * env),
      );
    }
  }

  /// 7. A baseline rule with a single micro-glyph orbiting along it
  /// (dot drifts L→R, fades, returns).
  void _orbitGlyph(Canvas canvas, Size size) {
    final y = size.height * 0.5;
    final padX = size.width * 0.10;
    final span = size.width - padX * 2;

    final rule = Paint()
      ..color = DuckColors.fgSubtle.withValues(alpha: 0.10)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(padX, y), Offset(padX + span, y), rule);

    // Quadratic ease in/out so the dot lingers at the ends.
    final eased = t < 0.5
        ? 2 * t * t
        : 1 - math.pow(-2 * t + 2, 2).toDouble() / 2;
    final x = padX + span * eased;
    // A subtle vertical drift so it isn't a perfect rail.
    final drift = math.sin(t * math.pi * 2) * 1.4;
    final dot = Paint()..color = accent.withValues(alpha: 0.22);
    canvas.drawCircle(Offset(x, y + drift), 1.8, dot);
    final halo = Paint()..color = accent.withValues(alpha: 0.08);
    canvas.drawCircle(Offset(x, y + drift), 4.0, halo);
  }

  @override
  bool shouldRepaint(covariant _IdlePainter old) {
    return old.t != t || old.variant != variant || old.accent != accent;
  }
}
