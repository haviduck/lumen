/// Researcher role signature — "document field".
///
/// Vibe: a sheet of notebook paper. Horizontal ruled lines spaced ~6px
/// across the card, a single vertical margin rule near the leading
/// edge, and an occasional "highlight strike" where one row briefly
/// brightens — like the researcher just underlined a finding.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';

const Color kResearcherSignatureAccent = DuckColors.accentDuck;
const Color kResearcherSignatureFallback = DuckColors.accentCyan;

class ResearcherRoleSignaturePainter extends CustomPainter {
  ResearcherRoleSignaturePainter({
    required this.active,
    required this.idleT,
    required this.accent,
  });

  final bool active;
  final double idleT;
  final Color accent;

  static const double _ruleStride = 6.0;
  static const double _marginX = 12.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    _paintRules(canvas, size);
    _paintHighlightStrike(canvas, size);
    _paintMarginRule(canvas, size);
  }

  void _paintRules(Canvas canvas, Size size) {
    // Horizontal ruled lines. The researcher signature is the only one
    // that fully covers the surface with a regular pattern so the
    // alpha is kept extra low — we want the lines to read as "paper
    // texture," not "a chart."
    final alpha = (active ? 0.055 : 0.038) + 0.010 * idleT;
    final paint = Paint()
      ..color = accent.withValues(alpha: alpha)
      ..strokeWidth = 0.45
      ..isAntiAlias = true;
    for (var y = _ruleStride * 1.5; y < size.height - 1; y += _ruleStride) {
      canvas.drawLine(Offset(_marginX + 2, y), Offset(size.width - 4, y), paint);
    }
  }

  void _paintHighlightStrike(Canvas canvas, Size size) {
    // One row brightens at any given time — the row index walks down
    // the page as idleT advances. Reads as "researcher underlining
    // their notes." Width-bound to a soft gradient so the leading and
    // trailing edges don't sit as hard caps.
    final rowSpan = size.height - _ruleStride * 2;
    final rowIndex = (idleT * rowSpan / _ruleStride).floor();
    final y = _ruleStride * 1.5 + rowIndex * _ruleStride;
    if (y < 0 || y > size.height - 1) return;
    final phase = (idleT * rowSpan / _ruleStride) - rowIndex;
    final env = (phase < 0.5 ? phase * 2 : (1.0 - phase) * 2).clamp(0.0, 1.0);
    if (env < 0.05) return;
    final rect = Rect.fromLTWH(_marginX + 2, y - 1.0, size.width - _marginX - 6, 2.0);
    final alpha = (active ? 0.18 : 0.10) * env;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: alpha),
          accent.withValues(alpha: alpha * 0.6),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.25, 0.7, 1.0],
      ).createShader(rect);
    canvas.drawRect(rect, paint);
  }

  void _paintMarginRule(Canvas canvas, Size size) {
    // Single vertical line ~12px from the left edge — the printed-page
    // margin convention. Slightly warmer (red-tinted) margin in real
    // notebooks; here we keep it on the accent color but a touch
    // brighter than the rules so it reads as "this is the margin."
    final paint = Paint()
      ..color = accent.withValues(alpha: active ? 0.18 : 0.12)
      ..strokeWidth = 0.55
      ..isAntiAlias = true;
    canvas.drawLine(
      Offset(_marginX, 2),
      Offset(_marginX, size.height - 2),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant ResearcherRoleSignaturePainter old) {
    return old.idleT != idleT ||
        old.active != active ||
        old.accent != accent;
  }
}
