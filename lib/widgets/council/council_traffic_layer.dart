import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_speech_bubbles.dart';
import 'network_controller.dart';

/// Persistent inter-agent network mesh + traveling communication packets.
///
/// Z-order: rendered above the diagonal backdrop, below Drift's bubbles
/// and below the agent cards (theater stacks bubbles + cards above us).
///
/// Topology: orchestrator-spokes are always brighter (the orchestrator
/// is the real broker) plus a dimmer full-mesh between non-orchestrator
/// agents so the eye reads "everyone could whisper to everyone". For
/// 10 nodes this is 9 spokes + 36 chords = 45 edges, matching the
/// perf-budget brief.
///
/// Volume mapping: each [CouncilEvent] within the last 4s adds heat
/// to its (from,to) edge; heat decays exponentially and modulates
/// stroke width (0.55 -> 1.8 logical px) and alpha (0.06 floor -> 0.55
/// ceiling). Idle edges therefore never disappear — alpha floor is
/// load-bearing for the brief's "lines never disappear entirely"
/// constraint.
///
/// Packets: come from two sources — recent [CouncilEvent]s and the
/// imperative [NetworkController.pulse] API (Signal uses the latter
/// for `agent_error`). Each packet is drawn as an eased traveling
/// head + 4-segment fading trail; error packets strobe + bigger halo.
class CouncilTrafficLayer extends StatelessWidget {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final Animation<double> pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;
  final NetworkController? network;

  const CouncilTrafficLayer({
    super.key,
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required this.anchors,
    this.mutedAgentIds = const <String>{},
    this.network,
  });

  @override
  Widget build(BuildContext context) {
    final repaint = network == null
        ? Listenable.merge(<Listenable>[pulse, anchors])
        : Listenable.merge(<Listenable>[pulse, anchors, network!]);
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
              network: network,
              repaint: repaint,
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
  final NetworkController? network;

  _CouncilTrafficPainter({
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required this.anchors,
    required this.mutedAgentIds,
    required this.network,
    required Listenable repaint,
  }) : super(repaint: repaint);

  Offset _resolve(String id, Offset fallback) {
    return anchors.centerOf(id) ?? fallback;
  }

  String _pairKey(String a, String b) {
    return a.compareTo(b) <= 0 ? '$a\u0001$b' : '$b\u0001$a';
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

    // ── Volume / heat map ─────────────────────────────────────────
    // Walk recent events and accumulate exponentially-decayed heat
    // per canonical edge key. Heat drives both width and alpha.
    final now = DateTime.now();
    final heat = <String, double>{};
    for (final e in events) {
      if (e.fromAgentId.isEmpty || e.toAgentId.isEmpty) continue;
      if (e.fromAgentId == e.toAgentId) continue;
      if (mutedAgentIds.contains(e.fromAgentId)) continue;
      if (mutedAgentIds.contains(e.toAgentId)) continue;
      final ageMs = now.difference(e.createdAt).inMilliseconds;
      if (ageMs > 4000) continue;
      final w = math.exp(-ageMs / 1400.0);
      final k = _pairKey(e.fromAgentId, e.toAgentId);
      heat[k] = (heat[k] ?? 0) + w;
    }

    final breathe = 0.5 + 0.5 * math.sin(pulse * math.pi * 2);
    final shimmer = 0.5 + 0.5 * math.sin(pulse * math.pi * 6 + 1.7);

    // ── Baseline persistent edges ─────────────────────────────────
    // 1) Inter-agent dim full-mesh (chords).
    // 2) Orchestrator spokes (brighter — real broker topology).
    // Both layers always paint — alpha floor is load-bearing for the
    // brief's "lines never disappear entirely" constraint.
    for (var i = 0; i < agents.length; i++) {
      final a = agents[i];
      if (mutedAgentIds.contains(a.id)) continue;
      final pa = points[a.id];
      if (pa == null) continue;
      for (var j = i + 1; j < agents.length; j++) {
        final b = agents[j];
        if (mutedAgentIds.contains(b.id)) continue;
        final pb = points[b.id];
        if (pb == null) continue;
        final h = heat[_pairKey(a.id, b.id)] ?? 0;
        _drawEdge(
          canvas,
          pa,
          pb,
          baseAlpha: 0.06 + 0.025 * shimmer,
          heat: h,
          baseColor: DuckColors.accentCyan,
          hotColor: DuckColors.accentCyan,
          baseWidth: 0.55,
        );
      }
    }

    for (final agent in agents) {
      if (mutedAgentIds.contains(agent.id)) continue;
      final p = points[agent.id];
      if (p == null) continue;
      final h = heat[_pairKey(orchestrator.id, agent.id)] ?? 0;
      _drawEdge(
        canvas,
        orchPoint,
        p,
        // Spokes have a higher floor — the orchestrator backbone is
        // always slightly more present than the inter-agent web.
        baseAlpha: 0.13 + 0.05 * breathe,
        heat: h,
        baseColor: DuckColors.glassEdgeHi,
        hotColor: DuckColors.accentCyan,
        baseWidth: 0.85,
      );
    }

    // ── Live packets from CouncilEvents ───────────────────────────
    for (final event in events.reversed.take(28)) {
      final ageMs = now.difference(event.createdAt).inMilliseconds;
      if (ageMs > 2400) continue;
      if (mutedAgentIds.contains(event.fromAgentId)) continue;
      if (mutedAgentIds.contains(event.toAgentId)) continue;
      final fromPoint = points[event.fromAgentId];
      final toPoint = points[event.toAgentId];
      if (fromPoint == null && toPoint == null) continue;
      final from = fromPoint ?? orchPoint;
      final to = toPoint ?? orchPoint;
      if (from == to) continue;
      final spec = _eventSpec(event.type);
      if (spec == null) continue;
      final t = (ageMs / 2400).clamp(0.0, 1.0);
      _drawPacket(
        canvas,
        from,
        to,
        t: t,
        accent: spec.color,
        isError: spec.isError,
      );
    }

    // ── Imperative packets via NetworkController ──────────────────
    final ctrl = network;
    if (ctrl != null) {
      ctrl.prune();
      for (final p in ctrl.packets) {
        if (mutedAgentIds.contains(p.fromId)) continue;
        if (mutedAgentIds.contains(p.toId)) continue;
        final from = points[p.fromId];
        final to = points[p.toId];
        if (from == null || to == null || from == to) continue;
        final ttl = p.kind == NetworkPacketKind.error
            ? NetworkController.errorPacketTtl.inMilliseconds
            : NetworkController.packetTtl.inMilliseconds;
        final ageMs =
            now.difference(p.spawnedAt).inMilliseconds * p.speedScale;
        final t = (ageMs / ttl).clamp(0.0, 1.0);
        if (t >= 1.0) continue;
        final accent = switch (p.kind) {
          NetworkPacketKind.message => DuckColors.accentCyan,
          NetworkPacketKind.reply => DuckColors.accentMint,
          NetworkPacketKind.error => DuckColors.stateError,
        };
        _drawPacket(
          canvas,
          from,
          to,
          t: t,
          accent: accent,
          isError: p.kind == NetworkPacketKind.error,
        );
      }
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Edge rendering: gradient stroke + soft additive bloom underlay.
  // Heat saturates around 2.5 (~3 events within ~1.4s).
  // ──────────────────────────────────────────────────────────────
  void _drawEdge(
    Canvas canvas,
    Offset a,
    Offset b, {
    required double baseAlpha,
    required double heat,
    required Color baseColor,
    required Color hotColor,
    required double baseWidth,
  }) {
    if (a == b) return;
    final norm = (heat / 2.5).clamp(0.0, 1.0);
    final alpha = (baseAlpha + (0.55 - baseAlpha) * norm).clamp(0.0, 0.7);
    final width = baseWidth + (1.8 - baseWidth) * norm;

    if (norm > 0.05) {
      // Hot edges get an additive bloom underlay. Cold edges skip
      // the MaskFilter to keep the 45-edge baseline cheap.
      final glow = Paint()
        ..color = hotColor.withValues(alpha: 0.22 * norm)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width + 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
        ..blendMode = BlendMode.plus;
      canvas.drawLine(a, b, glow);
    }

    final shader = ui.Gradient.linear(a, b, [
      baseColor.withValues(alpha: alpha * 0.55),
      Color.lerp(baseColor, hotColor, norm)!.withValues(alpha: alpha),
      baseColor.withValues(alpha: alpha * 0.55),
    ], const [0.0, 0.5, 1.0]);
    final stroke = Paint()
      ..shader = shader
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width;
    canvas.drawLine(a, b, stroke);
  }

  // ──────────────────────────────────────────────────────────────
  // Packet rendering: eased head + 4-segment fading trail + arrival
  // ring. Error packets strobe and carry a wider halo.
  // ──────────────────────────────────────────────────────────────
  void _drawPacket(
    Canvas canvas,
    Offset from,
    Offset to, {
    required double t,
    required Color accent,
    required bool isError,
  }) {
    final eased = Curves.easeInOutCubic.transform(t);
    final fade = 1 - t;
    final strobe = isError
        ? (0.65 + 0.35 * math.sin(pulse * math.pi * 18))
        : 1.0;

    // Energized edge under the packet — gives a sense the packet is
    // riding a wire that briefly lights up under it.
    final edgePaint = Paint()
      ..color = accent.withValues(alpha: 0.55 * fade * strobe)
      ..strokeWidth = isError ? 2.4 : 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(from, to, edgePaint);

    // Trail: 4 fading dots behind the head along the eased path.
    const trailSteps = 4;
    for (var i = trailSteps; i >= 1; i--) {
      final lag = i * 0.045;
      final tt = (eased - lag).clamp(0.0, 1.0);
      final pos = Offset.lerp(from, to, tt)!;
      final alpha = (fade * (1.0 - i / (trailSteps + 1.0))) * 0.85 * strobe;
      canvas.drawCircle(
        pos,
        (isError ? 4.5 : 3.8) * (1.0 - i / (trailSteps + 1.5)),
        Paint()..color = accent.withValues(alpha: alpha),
      );
    }

    // Head + halo.
    final head = Offset.lerp(from, to, eased)!;
    final headRadius = (isError ? 6.0 : 5.0) + fade * 2.0;
    canvas.drawCircle(
      head,
      headRadius + (isError ? 8 : 5),
      Paint()
        ..color = accent.withValues(alpha: 0.30 * fade * strobe)
        ..maskFilter = MaskFilter.blur(
          BlurStyle.normal,
          isError ? 9 : 6,
        )
        ..blendMode = BlendMode.plus,
    );
    canvas.drawCircle(
      head,
      headRadius,
      Paint()..color = accent.withValues(alpha: fade * strobe),
    );

    // Arrival ring near landing.
    if (t > 0.78) {
      final arriveT = ((t - 0.78) / 0.22).clamp(0.0, 1.0);
      canvas.drawCircle(
        to,
        14 + arriveT * (isError ? 26 : 18),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = (isError ? 1.8 : 1.4) * (1 - arriveT)
          ..color = accent.withValues(alpha: 0.55 * (1 - arriveT) * strobe),
      );
    }
  }

  _EventSpec? _eventSpec(String type) {
    switch (type) {
      case 'dispatched':
        return const _EventSpec(DuckColors.accentCyan, false);
      case 'asked_pool':
        return const _EventSpec(DuckColors.accentPurple, false);
      case 'pool_reply':
        return const _EventSpec(DuckColors.accentMint, false);
      case 'asked_user':
        return const _EventSpec(DuckColors.accentDuck, false);
      case 'user_reply':
        return const _EventSpec(DuckColors.accentDuck, false);
      case 'agent_done':
      case 'evaluator_done':
        return const _EventSpec(DuckColors.stateOk, false);
      case 'agent_error':
        return const _EventSpec(DuckColors.stateError, true);
    }
    return null;
  }

  @override
  bool shouldRepaint(covariant _CouncilTrafficPainter oldDelegate) {
    return oldDelegate.events.length != events.length ||
        oldDelegate.agents.length != agents.length ||
        oldDelegate.pulse != pulse ||
        oldDelegate.network != network;
  }
}

class _EventSpec {
  final Color color;
  final bool isError;
  const _EventSpec(this.color, this.isError);
}
