/// Orchestrator role signature — "command surface".
///
/// The conductor's card. This is intentionally the most elaborate of
/// all the signatures — the user should glance at the ring of agents
/// and pick the orchestrator out immediately. Vibe pieces:
///   • Concentric grid of rings — three of them, finer detail than
///     any of the peer cards.
///   • Six phase tick marks placed around the inner ring at the
///     positions of the six `CouncilPhase` values (DISC, ARCH, BUILD,
///     REV, POL, SHIP). The tick corresponding to `currentPhase` is
///     significantly brighter and a touch longer than the rest.
///   • Slow radar-sweep arc rotating around the rings, pumped by
///     `idleT` (no extra vsync — landmine compliant). The radar arc
///     is what gives the surface its "command center" energy.
///   • Subtle crosshair through the rings + bracket marks at the
///     corners that anchor the surface as a command panel.
///
/// Subtlety contract still applies — none of this should compete with
/// the voice panel, status block, or transcript well. The ambition
/// here is "more elaborate than the peer cards" not "loud."
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../services/council/council_models.dart';
import '../../../theme/app_colors.dart';

const Color kOrchestratorSignatureAccent = DuckColors.accentPurple;
const Color kOrchestratorSignatureFallback = DuckColors.accentCyan;

class OrchestratorRoleSignaturePainter extends CustomPainter {
  OrchestratorRoleSignaturePainter({
    required this.active,
    required this.idleT,
    required this.accent,
    required this.currentPhase,
  });

  final bool active;
  final double idleT;
  final Color accent;
  final CouncilPhase currentPhase;

  static const List<CouncilPhase> _phasesInOrder = CouncilPhase.values;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final center = Offset(size.width / 2, size.height * 0.42);
    final baseR = size.shortestSide * 0.18;
    _paintGridLines(canvas, size);
    _paintRings(canvas, center, baseR);
    _paintCrosshair(canvas, center, baseR);
    _paintRadarSweep(canvas, center, baseR);
    _paintPhaseTicks(canvas, center, baseR);
    _paintCornerBrackets(canvas, size);
  }

  void _paintGridLines(Canvas canvas, Size size) {
    // Fine grid underlay — smaller stride than any peer card so the
    // orchestrator surface reads as "denser, more instrumented."
    final alpha = (active ? 0.040 : 0.026) + 0.008 * idleT;
    final paint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..strokeWidth = 0.3
      ..isAntiAlias = true;
    const stride = 6.0;
    for (var x = stride; x < size.width; x += stride) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (var y = stride; y < size.height; y += stride) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  void _paintRings(Canvas canvas, Offset center, double baseR) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;
    final alphaBase = (active ? 0.13 : 0.085) + 0.018 * idleT;
    for (var i = 0; i < 3; i++) {
      final radius = baseR * (1.0 + i * 0.85);
      paint
        ..strokeWidth = 0.55 + i * 0.06
        ..color = accent.withValues(
          alpha: (alphaBase * (1.0 - i * 0.18)).clamp(0.0, 1.0),
        );
      canvas.drawCircle(center, radius, paint);
    }
  }

  void _paintCrosshair(Canvas canvas, Offset center, double baseR) {
    final alpha = (active ? 0.085 : 0.055) + 0.010 * idleT;
    final paint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..strokeWidth = 0.45
      ..isAntiAlias = true;
    final outerR = baseR * 2.85;
    canvas.drawLine(
      Offset(center.dx - outerR, center.dy),
      Offset(center.dx - baseR * 0.55, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx + baseR * 0.55, center.dy),
      Offset(center.dx + outerR, center.dy),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - outerR),
      Offset(center.dx, center.dy - baseR * 0.55),
      paint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + baseR * 0.55),
      Offset(center.dx, center.dy + outerR),
      paint,
    );
  }

  void _paintRadarSweep(Canvas canvas, Offset center, double baseR) {
    // Comet-tail sweep — full revolution per `_idle` cycle. The arc
    // is short (~60deg) and fades along the tail so the rotation
    // reads more like a radar than a barber pole.
    final outerR = baseR * 2.75;
    final rect = Rect.fromCircle(center: center, radius: outerR);
    final angle = idleT * math.pi * 2;
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: math.pi * 2,
      transform: GradientRotation(angle - math.pi / 3),
      colors: [
        accent.withValues(alpha: 0.0),
        accent.withValues(alpha: active ? 0.085 : 0.050),
        accent.withValues(alpha: active ? 0.22 : 0.14),
        accent.withValues(alpha: 0.0),
        accent.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.10, 0.18, 0.30, 1.0],
    ).createShader(rect);
    final paint = Paint()
      ..shader = shader
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8)
      ..isAntiAlias = true;
    canvas.drawCircle(center, outerR, paint);
  }

  void _paintPhaseTicks(Canvas canvas, Offset center, double baseR) {
    // Six tick marks around the OUTERMOST ring (third ring). The tick
    // matching `currentPhase` is brighter + slightly longer. The
    // angular position of phase[0] starts at 12 o'clock and walks
    // clockwise — same direction users read the phase strip.
    final r = baseR * 2.55;
    final paint = Paint()
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < _phasesInOrder.length; i++) {
      final angle = -math.pi / 2 + (i / _phasesInOrder.length) * math.pi * 2;
      final isCurrent = _phasesInOrder[i] == currentPhase;
      final tickLen = isCurrent ? 6.0 : 3.4;
      final alpha = isCurrent
          ? (active ? 0.88 : 0.65) + 0.10 * idleT
          : (active ? 0.32 : 0.22);
      paint
        ..color = accent.withValues(alpha: alpha.clamp(0.0, 1.0))
        ..strokeWidth = isCurrent ? 1.1 : 0.7;
      final cos = math.cos(angle);
      final sin = math.sin(angle);
      final p1 = Offset(center.dx + cos * r, center.dy + sin * r);
      final p2 = Offset(
        center.dx + cos * (r + tickLen),
        center.dy + sin * (r + tickLen),
      );
      canvas.drawLine(p1, p2, paint);

      // Halo for the current-phase tick — sells the "this is the
      // live phase" beat even at a quick glance.
      if (isCurrent) {
        final halo = Paint()
          ..color = accent.withValues(alpha: 0.45 * (0.6 + 0.4 * idleT))
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.4);
        canvas.drawCircle(p2, 2.2, halo);
      }
    }
  }

  void _paintCornerBrackets(Canvas canvas, Size size) {
    // Four corner brackets — same shape as the custom signature but
    // slightly longer arms so the orchestrator frame reads as "more
    // assertive" than the peer cards.
    const armLen = 8.0;
    final paint = Paint()
      ..color = accent.withValues(alpha: active ? 0.55 : 0.32)
      ..strokeWidth = 0.95
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 0), const Offset(armLen, 0), paint);
    canvas.drawLine(const Offset(0, 0), const Offset(0, armLen), paint);
    canvas.drawLine(
      Offset(size.width - armLen, 0),
      Offset(size.width, 0),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, armLen),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(armLen, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(0, size.height - armLen),
      Offset(0, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width - armLen, size.height),
      Offset(size.width, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, size.height - armLen),
      Offset(size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant OrchestratorRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent ||
        old.currentPhase != currentPhase;
  }
}
