import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

class CouncilTrafficLayer extends StatelessWidget {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final Animation<double> pulse;

  const CouncilTrafficLayer({
    super.key,
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        painter: _CouncilTrafficPainter(
          agents: agents,
          orchestrator: orchestrator,
          events: events.take(80).toList(),
          pulse: pulse.value,
          repaint: pulse,
        ),
      ),
    );
  }
}

class _CouncilTrafficPainter extends CustomPainter {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final double pulse;

  _CouncilTrafficPainter({
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (agents.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) * 0.34;
    final points = <String, Offset>{orchestrator.id: center};
    for (var i = 0; i < agents.length; i++) {
      final angle = -math.pi / 2 + (math.pi * 2 * i / agents.length);
      points[agents[i].id] = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
    }

    final line = Paint()
      ..color = DuckColors.glassSeam.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    final activeLine = Paint()
      ..color = DuckColors.accentCyan.withValues(alpha: 0.78)
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    final glowLine = Paint()
      ..color = DuckColors.accentCyan.withValues(alpha: 0.16)
      ..strokeWidth = 8
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);

    for (final agent in agents) {
      final p = points[agent.id]!;
      canvas.drawLine(center, p, line);
    }

    final now = DateTime.now();
    for (final event in events.reversed.take(20)) {
      final age = now.difference(event.createdAt).inMilliseconds;
      if (age > 5200) continue;
      final from = points[event.fromAgentId] ?? center;
      final to = points[event.toAgentId] ?? center;
      if (from == to) continue;
      final t = (age / 5200).clamp(0.0, 1.0);
      final dot = Offset.lerp(from, to, t)!;
      canvas.drawLine(from, to, glowLine);
      canvas.drawLine(from, to, activeLine);
      canvas.drawCircle(
        dot,
        4.5 + (1 - t) * 3,
        Paint()..color = DuckColors.accentDuck.withValues(alpha: 1 - t * 0.55),
      );
      canvas.drawCircle(
        dot,
        13 + math.sin(pulse * math.pi * 2) * 1.2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = DuckColors.accentDuck.withValues(alpha: 0.2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CouncilTrafficPainter oldDelegate) {
    return oldDelegate.events.length != events.length ||
        oldDelegate.agents.length != agents.length ||
        oldDelegate.pulse != pulse;
  }
}
