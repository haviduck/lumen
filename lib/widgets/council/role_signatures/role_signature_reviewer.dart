/// Reviewer role signature — "microscope view".
///
/// Vibe: a radial vignette (corners darker, center slightly brighter)
/// + a soft graticule of concentric circles emanating from the card
/// center, breathing in radius with `idleT` + a small "+" reticle in
/// the top-right corner. Reads as: "we're looking through a lens at
/// this code."
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kReviewerSignatureAccent = DuckColors.accentCyan;
const Color kReviewerSignatureFallback = DuckColors.accentCyan;

class ReviewerRoleSignaturePainter extends CustomPainter {
  ReviewerRoleSignaturePainter({
    required this.active,
    required this.idleT,
    required this.accent,
  });

  final bool active;
  final double idleT;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _paintVignette(canvas, size);
    _paintGraticule(canvas, size);
    _paintReticle(canvas, size);
  }

  void _paintVignette(Canvas canvas, Size size) {
    // Radial gradient pulled tighter than the card's own gradient.
    // Inner brighter (transparent), outer corners dark. Helps the eye
    // settle on the voice panel which sits roughly mid-card.
    final center = Offset(size.width / 2, size.height * 0.42);
    final radius = size.shortestSide * 0.85;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final alpha = active ? 0.16 : 0.12;
    final shader = RadialGradient(
      center: Alignment.center,
      colors: [
        Colors.black.withValues(alpha: 0.0),
        Colors.black.withValues(alpha: alpha * 0.55),
        Colors.black.withValues(alpha: alpha),
      ],
      stops: const [0.0, 0.65, 1.0],
    ).createShader(rect);
    final paint = Paint()..shader = shader;
    canvas.drawRect(Offset.zero & size, paint);
  }

  void _paintGraticule(Canvas canvas, Size size) {
    // Concentric rings — a focus graticule. Three rings total: their
    // radii breathe via idleT so the lens reads as "adjusting focus."
    final center = Offset(size.width / 2, size.height * 0.42);
    final baseR = size.shortestSide * 0.18;
    final breath = 1.0 + 0.08 * (idleT - 0.5) * 2.0;
    final alphaBase = (active ? 0.075 : 0.050) + 0.012 * idleT;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    for (var i = 0; i < 3; i++) {
      final radius = baseR * breath * (1.0 + i * 0.9);
      paint
        ..strokeWidth = 0.55 + i * 0.05
        ..color = accent.withValues(
          alpha: (alphaBase * (1.0 - i * 0.22)).clamp(0.0, 1.0),
        );
      canvas.drawCircle(center, radius, paint);
    }

    // Crosshair across the center — keeps the lens reading even when
    // the rings drift out of frame on tall cards.
    final crossPaint = Paint()
      ..color = accent.withValues(alpha: (alphaBase * 0.9).clamp(0.0, 1.0))
      ..strokeWidth = 0.45
      ..isAntiAlias = true;
    canvas.drawLine(
      Offset(center.dx - baseR * 0.55, center.dy),
      Offset(center.dx - baseR * 0.18, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx + baseR * 0.18, center.dy),
      Offset(center.dx + baseR * 0.55, center.dy),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy - baseR * 0.55),
      Offset(center.dx, center.dy - baseR * 0.18),
      crossPaint,
    );
    canvas.drawLine(
      Offset(center.dx, center.dy + baseR * 0.18),
      Offset(center.dx, center.dy + baseR * 0.55),
      crossPaint,
    );
  }

  void _paintReticle(Canvas canvas, Size size) {
    // Small "+" reticle in the top-right corner — the framing mark
    // that anchors the lens metaphor. Drawn at low alpha so it never
    // competes with the title row text.
    final cx = size.width - 9.0;
    final cy = 9.0;
    final paint = Paint()
      ..color = accent.withValues(alpha: active ? 0.55 : 0.36)
      ..strokeWidth = 0.85
      ..isAntiAlias = true;
    canvas.drawLine(Offset(cx - 3.2, cy), Offset(cx + 3.2, cy), paint);
    canvas.drawLine(Offset(cx, cy - 3.2), Offset(cx, cy + 3.2), paint);
    // Tiny dot at the intersection for the "locked" feel.
    final dot = Paint()
      ..color = accent.withValues(alpha: active ? 0.65 : 0.40)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 0.9, dot);
  }

  @override
  bool shouldRepaint(covariant ReviewerRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
