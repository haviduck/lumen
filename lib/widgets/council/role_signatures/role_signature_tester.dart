/// Tester role signature — "test bench".
///
/// Vibe: two faint horizontal rails at 30% and 70% of the card height
/// (the "test track"), a small passing-indicator dot that travels back
/// and forth along the upper rail, and a tiny stack of test-result
/// tick marks in one corner (filled = pass, hollow = fail). Reads as:
/// "a piece of equipment running pass/fail cases."
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kTesterSignatureAccent = DuckColors.accentCyan;
const Color kTesterSignatureFallback = DuckColors.accentMint;

class TesterRoleSignaturePainter extends CustomPainter {
  TesterRoleSignaturePainter({
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
    _paintRails(canvas, size);
    _paintTravelingDot(canvas, size);
    _paintResultMarks(canvas, size);
  }

  void _paintRails(Canvas canvas, Size size) {
    final alphaLine = (active ? 0.08 : 0.052) + 0.012 * idleT;
    final alphaTie = alphaLine * 0.55;
    final railPaint = Paint()
      ..color = accent.withValues(alpha: alphaLine)
      ..strokeWidth = 0.55
      ..isAntiAlias = true;
    final tiePaint = Paint()
      ..color = accent.withValues(alpha: alphaTie)
      ..strokeWidth = 0.35
      ..isAntiAlias = true;
    final y1 = size.height * 0.30;
    final y2 = size.height * 0.70;
    canvas.drawLine(Offset(4, y1), Offset(size.width - 4, y1), railPaint);
    canvas.drawLine(Offset(4, y2), Offset(size.width - 4, y2), railPaint);
    // Cross ties at irregular spacing — sells the rail metaphor and
    // adds a hint of texture between the two lines without crowding.
    final span = size.width - 12;
    final ties = (span / 28).clamp(2, 12).toInt();
    for (var i = 0; i <= ties; i++) {
      final x = 6 + (span * i / ties);
      canvas.drawLine(Offset(x, y1 + 0.4), Offset(x, y2 - 0.4), tiePaint);
    }
  }

  void _paintTravelingDot(Canvas canvas, Size size) {
    // Indicator dot oscillates left↔right along the upper rail.
    // Velocity comes from a sine of idleT so the dot pauses at each
    // end. Mint flash on the dot's halo when active.
    final t = math.sin(idleT * math.pi);
    final x = 10 + (size.width - 20) * (0.5 + 0.5 * t * (idleT > 0.5 ? 1 : -1));
    final y = size.height * 0.30;
    final coreAlpha = active ? 0.78 : 0.45;
    final core = Paint()
      ..color = accent.withValues(alpha: coreAlpha)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(x, y), 1.6, core);
    if (active) {
      final glow = Paint()
        ..color = DuckColors.accentMint.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(Offset(x, y), 3.4, glow);
    }
  }

  void _paintResultMarks(Canvas canvas, Size size) {
    // Six tiny rectangles stacked in the top-right corner. Filled
    // shapes read as "pass" cases, hollow as "fail." A 4-pass /
    // 2-fail pattern echoes the "mostly green CI" feel without using
    // any green: filled marks land on the accent ramp.
    if (size.width < 60) return;
    const pattern = <bool>[true, true, false, true, true, false];
    const cellW = 3.4;
    const cellH = 2.4;
    final originX = size.width - 8.0 - pattern.length * cellW - 1.0;
    final originY = 9.0;
    final fillPaint = Paint()
      ..color = accent.withValues(alpha: active ? 0.62 : 0.42)
      ..style = PaintingStyle.fill;
    final outlinePaint = Paint()
      ..color = accent.withValues(alpha: active ? 0.42 : 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.55;
    for (var i = 0; i < pattern.length; i++) {
      final rect = Rect.fromLTWH(
        originX + i * cellW,
        originY,
        cellW - 1.2,
        cellH,
      );
      canvas.drawRect(rect, pattern[i] ? fillPaint : outlinePaint);
    }
  }

  @override
  bool shouldRepaint(covariant TesterRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
