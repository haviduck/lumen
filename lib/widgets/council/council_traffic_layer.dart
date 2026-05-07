import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_speech_bubbles.dart';

class CouncilTrafficLayer extends StatelessWidget {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final Animation<double> pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;

  const CouncilTrafficLayer({
    super.key,
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required this.anchors,
    this.mutedAgentIds = const <String>{},
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: anchors,
        builder: (context, _) {
          return CustomPaint(
            painter: _CouncilTrafficPainter(
              agents: agents,
              orchestrator: orchestrator,
              events: events.length > 80
                  ? events.sublist(events.length - 80)
                  : events,
              pulse: pulse.value,
              anchors: anchors,
              mutedAgentIds: mutedAgentIds,
              repaint: pulse,
            ),
          );
        },
      ),
    );
  }
}

class _CouncilTrafficPainter extends CustomPainter {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final double pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;

  _CouncilTrafficPainter({
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required this.anchors,
    required this.mutedAgentIds,
    required Listenable repaint,
  }) : super(repaint: repaint);

  Offset _resolve(String id, Offset fallback) {
    return anchors.centerOf(id) ?? fallback;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (agents.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final orchPoint = _resolve(orchestrator.id, center);

    final points = <String, Offset>{orchestrator.id: orchPoint};
    for (var i = 0; i < agents.length; i++) {
      final fallbackAngle = -math.pi / 2 + (math.pi * 2 * i / agents.length);
      final fallback = Offset(
        center.dx + math.cos(fallbackAngle) * size.shortestSide * 0.34,
        center.dy + math.sin(fallbackAngle) * size.shortestSide * 0.34,
      );
      points[agents[i].id] = _resolve(agents[i].id, fallback);
    }

    // Faint base graph (orchestrator → each agent), gated on recent
    // activity. With no live events the canvas stays empty so the
    // orchestrator-centered spokes can't compose into a "starfish"
    // shape during idle. With live activity the spokes act as
    // tracking wires that frame the traveling pulses.
    final now = DateTime.now();
    final hasRecentActivity = events.any(
      (e) => now.difference(e.createdAt).inMilliseconds < 2600,
    );
    if (hasRecentActivity) {
      final baseLine = Paint()
        ..color = DuckColors.glassSeam.withValues(alpha: 0.22)
        ..strokeWidth = 0.6;
      for (final agent in agents) {
        final p = points[agent.id]!;
        canvas.drawLine(orchPoint, p, baseLine);
      }
    }

    // Idle pool-reply web (faint purple).
    final collabLine = Paint()
      ..color = DuckColors.accentPurple.withValues(alpha: 0.16)
      ..strokeWidth = 0.9
      ..strokeCap = StrokeCap.round;
    for (final event in events.where((e) => e.type == 'pool_reply').take(24)) {
      if (mutedAgentIds.contains(event.fromAgentId) ||
          mutedAgentIds.contains(event.toAgentId)) {
        continue;
      }
      final from = points[event.fromAgentId];
      final to = points[event.toAgentId];
      if (from == null || to == null || from == to) continue;
      canvas.drawLine(from, to, collabLine);
    }

    // Live event pulses — directional traveling glow per event type.
    for (final event in events.reversed.take(28)) {
      final age = now.difference(event.createdAt).inMilliseconds;
      if (age > 2600) continue;
      // Suppress evaluator-touching pulses when the evaluator lives on
      // the blackboard; otherwise they'd silently fall back to orchPoint
      // and either vanish (from==to guard) or render as phantom
      // orchestrator→orchestrator self-loops. The blackboard's own
      // status surface carries the "done" signal in that mode.
      if (mutedAgentIds.contains(event.fromAgentId) ||
          mutedAgentIds.contains(event.toAgentId)) {
        continue;
      }
      final fromPoint = points[event.fromAgentId];
      final toPoint = points[event.toAgentId];
      if (fromPoint == null && toPoint == null) continue;
      final from = fromPoint ?? orchPoint;
      final to = toPoint ?? orchPoint;
      if (from == to) continue;
      final accent = _accentFor(event.type);
      if (accent == null) continue;

      final t = (age / 2600).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(t);
      final fade = 1 - t;

      // Glow underlay
      final glow = Paint()
        ..color = accent.withValues(alpha: 0.18 * fade)
        ..strokeWidth = 9
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      canvas.drawLine(from, to, glow);

      // Bright edge
      final edge = Paint()
        ..color = accent.withValues(alpha: 0.78 * fade)
        ..strokeWidth = 2.0
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(from, to, edge);

      // Traveling head — leads the message toward the recipient.
      final head = Offset.lerp(from, to, eased)!;
      canvas.drawCircle(
        head,
        5.0 + (1 - t) * 3,
        Paint()..color = accent.withValues(alpha: fade),
      );
      canvas.drawCircle(
        head,
        12 + math.sin(pulse * math.pi * 2) * 1.2,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.1
          ..color = accent.withValues(alpha: 0.30 * fade),
      );

      // Arrival ring on the recipient at the end of the trip.
      if (t > 0.78) {
        final arriveT = ((t - 0.78) / 0.22).clamp(0.0, 1.0);
        canvas.drawCircle(
          to,
          14 + arriveT * 18,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4 * (1 - arriveT)
            ..color = accent.withValues(alpha: 0.55 * (1 - arriveT)),
        );
      }
    }
  }

  Color? _accentFor(String type) {
    switch (type) {
      case 'dispatched':
        return DuckColors.accentCyan;
      case 'asked_pool':
        return DuckColors.accentPurple;
      case 'pool_reply':
        return DuckColors.accentMint;
      case 'asked_user':
        return DuckColors.accentDuck;
      case 'user_reply':
        return DuckColors.accentDuck;
      case 'agent_done':
      case 'evaluator_done':
        return DuckColors.stateOk;
      case 'agent_error':
        return DuckColors.stateError;
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _CouncilTrafficPainter oldDelegate) {
    return oldDelegate.events.length != events.length ||
        oldDelegate.agents.length != agents.length ||
        oldDelegate.pulse != pulse;
  }
}
