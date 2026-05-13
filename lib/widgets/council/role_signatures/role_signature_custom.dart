/// Custom role signature — generic specialist fallback.
///
/// Preserves the look of the original `_DigitalGridPainter` that used
/// to back every agent card pre-redesign: a 4px dot grid, a slow
/// top→bottom scan line, four HUD-style corner brackets, and a
/// horizontal data stripe near the bottom. Used by `RolePreset.custom`
/// when the user hasn't pinned the agent to one of the six fixed
/// specialist roles — the goal is "this is an AI agent, no specific
/// domain" rather than any one specialist's vocabulary.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kCustomSignatureAccent = DuckColors.accentCyan;
const Color kCustomSignatureFallback = DuckColors.accentCyan;

class CustomRoleSignaturePainter extends CustomPainter {
  CustomRoleSignaturePainter({
    required this.active,
    required this.idleT,
    required this.accent,
  });

  final bool active;
  final double idleT;
  final Color accent;

  static const double _gridStride = 4.0;
  static const double _tickLen = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;

    final gridAlpha = (active ? 0.052 : 0.030) + 0.012 * idleT;
    final dotPaint = Paint()
      ..color = accent.withValues(alpha: gridAlpha)
      ..style = PaintingStyle.fill;
    for (var y = _gridStride; y < size.height - 1; y += _gridStride) {
      for (var x = _gridStride; x < size.width - 1; x += _gridStride) {
        canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), dotPaint);
      }
    }

    final scanY = size.height * (0.05 + 0.95 * idleT);
    final scanRect = Rect.fromLTWH(0, scanY - 4, size.width, 8);
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: active ? 0.10 : 0.05),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(scanRect);
    canvas.drawRect(scanRect, scanPaint);

    final tickPaint = Paint()
      ..color = accent.withValues(alpha: active ? 0.55 : 0.28)
      ..strokeWidth = 0.9
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;
    canvas.drawLine(const Offset(0, 0), const Offset(_tickLen, 0), tickPaint);
    canvas.drawLine(const Offset(0, 0), const Offset(0, _tickLen), tickPaint);
    canvas.drawLine(
      Offset(size.width - _tickLen, 0),
      Offset(size.width, 0),
      tickPaint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, _tickLen),
      tickPaint,
    );
    canvas.drawLine(
      Offset(0, size.height),
      Offset(_tickLen, size.height),
      tickPaint,
    );
    canvas.drawLine(
      Offset(0, size.height - _tickLen),
      Offset(0, size.height),
      tickPaint,
    );
    canvas.drawLine(
      Offset(size.width - _tickLen, size.height),
      Offset(size.width, size.height),
      tickPaint,
    );
    canvas.drawLine(
      Offset(size.width, size.height - _tickLen),
      Offset(size.width, size.height),
      tickPaint,
    );

    final dataPhase = (idleT * 1.7) % 1.0;
    final dataRect = Rect.fromLTWH(0, size.height - 12, size.width, 2);
    final dataPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: active ? 0.22 : 0.10),
          accent.withValues(alpha: 0.0),
        ],
        stops: [
          (dataPhase - 0.18).clamp(0.0, 1.0),
          dataPhase.clamp(0.0, 1.0),
          (dataPhase + 0.18).clamp(0.0, 1.0),
        ],
      ).createShader(dataRect);
    canvas.drawRect(dataRect, dataPaint);
  }

  @override
  bool shouldRepaint(covariant CustomRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
