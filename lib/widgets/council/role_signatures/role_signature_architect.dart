/// Architect role signature — "blueprint surface".
///
/// Vibe: a draftsman's grid (thicker lines every 32px, thinner every
/// 8px), three faint construction lines projected across the card at
/// small angles, and a short scale-ruler tick row near the bottom-left.
/// Reads as: "this card is a working drawing."
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kArchitectSignatureAccent = DuckColors.accentPurple;
const Color kArchitectSignatureFallback = DuckColors.accentCyan;

class ArchitectRoleSignaturePainter extends CustomPainter {
  ArchitectRoleSignaturePainter({
    required this.active,
    required this.idleT,
    required this.accent,
  });

  final bool active;
  final double idleT;
  final Color accent;

  static const double _minorStride = 8.0;
  static const double _majorStride = 32.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _paintGrid(canvas, size);
    _paintConstructionLines(canvas, size);
    _paintScaleRuler(canvas, size);
  }

  void _paintGrid(Canvas canvas, Size size) {
    final minorAlpha = (active ? 0.050 : 0.034) + 0.010 * idleT;
    final majorAlpha = (active ? 0.10 : 0.062) + 0.014 * idleT;
    final minor = Paint()
      ..color = accent.withValues(alpha: minorAlpha)
      ..strokeWidth = 0.35
      ..isAntiAlias = true;
    final major = Paint()
      ..color = accent.withValues(alpha: majorAlpha)
      ..strokeWidth = 0.65
      ..isAntiAlias = true;

    for (var x = _minorStride; x < size.width; x += _minorStride) {
      final isMajor = (x % _majorStride).abs() < 0.5;
      if (isMajor) continue;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), minor);
    }
    for (var y = _minorStride; y < size.height; y += _minorStride) {
      final isMajor = (y % _majorStride).abs() < 0.5;
      if (isMajor) continue;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), minor);
    }
    for (var x = _majorStride; x < size.width; x += _majorStride) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), major);
    }
    for (var y = _majorStride; y < size.height; y += _majorStride) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), major);
    }
  }

  void _paintConstructionLines(Canvas canvas, Size size) {
    // Three projection lines emanating from a vanishing point just off
    // the bottom-right corner. Reads as "drawing's underlying
    // geometry." Alpha is kept extra low so they hint at structure
    // without becoming a stage element.
    final vp = Offset(size.width + 30, size.height + 18);
    final alpha = (active ? 0.090 : 0.060) + 0.012 * idleT;
    final paint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..strokeWidth = 0.45
      ..isAntiAlias = true;
    final targets = <Offset>[
      Offset(0, size.height * 0.18),
      Offset(0, size.height * 0.40),
      Offset(0, size.height * 0.62),
    ];
    for (final t in targets) {
      canvas.drawLine(t, vp, paint);
    }
  }

  void _paintScaleRuler(Canvas canvas, Size size) {
    // Five tick marks of varying heights, like a scale ruler. The
    // longest mid-tick reads as the "5" mark; flanking shorter ticks
    // sell the ruler vocabulary. Sits in the bottom-left corner where
    // the architect would label their drawing's scale.
    if (size.height < 40) return;
    final baseY = size.height - 5.0;
    final paint = Paint()
      ..color = accent.withValues(alpha: active ? 0.45 : 0.30)
      ..strokeWidth = 0.7
      ..isAntiAlias = true;
    final baseX = 10.0;
    canvas.drawLine(
      Offset(baseX, baseY),
      Offset(baseX + 28, baseY),
      paint,
    );
    for (var i = 0; i <= 5; i++) {
      final x = baseX + i * (28 / 5);
      final h = (i == 0 || i == 5)
          ? 4.2
          : (i == 3 ? 3.4 : 2.0);
      canvas.drawLine(Offset(x, baseY), Offset(x, baseY - h), paint);
    }
  }

  @override
  bool shouldRepaint(covariant ArchitectRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
