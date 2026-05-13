/// Writer role signature — "manuscript surface".
///
/// Vibe: a wireframe of a document — a couple of "heading" bars at the
/// top, several "body text" bars below them, a quiet margin rule on
/// the leading edge, and a thin blinking cursor near the bottom. Reads
/// as: "this agent works in prose."
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kWriterSignatureAccent = DuckColors.accentDuck;
const Color kWriterSignatureFallback = DuckColors.fgPrimary;

class WriterRoleSignaturePainter extends CustomPainter {
  WriterRoleSignaturePainter({
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
    _paintMarginRule(canvas, size);
    _paintParagraphSkeleton(canvas, size);
    _paintCursor(canvas, size);
  }

  void _paintMarginRule(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = accent.withValues(alpha: active ? 0.14 : 0.09)
      ..strokeWidth = 0.55
      ..isAntiAlias = true;
    canvas.drawLine(
      const Offset(12, 4),
      Offset(12, size.height - 4),
      paint,
    );
  }

  void _paintParagraphSkeleton(Canvas canvas, Size size) {
    // A few "body text" bars of varied widths, with two heading-like
    // bars at the top. Layout is deterministic so the wireframe is
    // stable across rebuilds — alpha is the only thing breathing.
    final alphaBody = (active ? 0.075 : 0.052) + 0.012 * idleT;
    final alphaHeading = (active ? 0.13 : 0.090) + 0.014 * idleT;
    final body = Paint()
      ..color = accent.withValues(alpha: alphaBody)
      ..style = PaintingStyle.fill;
    final heading = Paint()
      ..color = accent.withValues(alpha: alphaHeading)
      ..style = PaintingStyle.fill;

    final left = 18.0;
    final right = size.width - 10.0;
    final usable = math.max(0.0, right - left);

    // Two headings: one larger, one smaller.
    canvas.drawRRect(
      RRect.fromLTRBR(left, 7, left + usable * 0.55, 10.0, const Radius.circular(1)),
      heading,
    );
    canvas.drawRRect(
      RRect.fromLTRBR(left, 14, left + usable * 0.32, 16.6, const Radius.circular(1)),
      heading,
    );

    // Body lines — varied widths so the block reads as paragraph
    // text. Vertical density tuned so we don't fight the voice panel
    // that sits on top.
    final widths = <double>[0.92, 0.85, 0.94, 0.62, 0.88, 0.78, 0.30];
    final yStart = 26.0;
    final dy = 5.6;
    for (var i = 0; i < widths.length; i++) {
      final y = yStart + i * dy;
      if (y > size.height - 18) break;
      final w = usable * widths[i];
      canvas.drawRRect(
        RRect.fromLTRBR(left, y, left + w, y + 2.0, const Radius.circular(1)),
        body,
      );
    }
  }

  void _paintCursor(Canvas canvas, Size size) {
    // Thin vertical line near the bottom that fades in and out with
    // idleT — the "writing cursor" blink. Sits one body-width into
    // the page so it reads as actively being typed at.
    if (size.height < 50 || size.width < 50) return;
    final cy = size.height - 11.0;
    final cx = 26.0;
    // Triangle-wave fade — symmetric so the cursor pulses evenly.
    final phase = (idleT * 2.0).clamp(0.0, 2.0);
    final pulse = phase > 1.0 ? 2.0 - phase : phase;
    final alpha = (active ? 0.60 : 0.30) * pulse;
    final paint = Paint()
      ..color = accent.withValues(alpha: alpha.clamp(0.0, 1.0))
      ..strokeWidth = 0.9
      ..isAntiAlias = true;
    canvas.drawLine(Offset(cx, cy - 4), Offset(cx, cy + 1.5), paint);
  }

  @override
  bool shouldRepaint(covariant WriterRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
