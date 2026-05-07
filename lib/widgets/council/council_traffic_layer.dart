import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

// Pulse visual encoding (event kind -> color/speed/intensity)
//
//   dispatch        councilAccentHi  fast    bright   orchestrator -> agent kickoff
//   reply / done    councilAccent    normal  warm     agent -> orchestrator return
//   ask_pool        accentPurple     normal  medium   inter-agent question
//   pool_reply      accentMint mix   normal  warm     pool answer
//   ask_user        accentDuck       normal  medium   agent -> user
//   user_reply      accentDuck       normal  medium   user -> agent
//   review/followup accentDuck       normal  medium   evaluator turn
//   agent_error     stateError       x1.55   strobe   triple-burst red
//
// Accent source: DuckColors.councilAccent / councilAccentHi / councilAccentDim
// (agent_0's published dark-blue ramp). No literals.
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

  // Quadratic bezier control point that bows the edge AWAY from the
  // stage center. Two effects fall out of this:
  //   • inter-agent chords no longer cut straight through the
  //     orchestrator card — they arc around it, so the topology reads
  //     as a *bundle* of fiber, not an X-shaped scribble.
  //   • orchestrator spokes get a tiny perpendicular sag (sign derived
  //     from a hash of the pair key) so no two spokes lie on top of
  //     each other when the ring is symmetric.
  Offset _curveControl(
    Offset a,
    Offset b,
    Offset center, {
    required double sagFactor,
    double minSagPx = 6.0,
  }) {
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final delta = b - a;
    final length = delta.distance;
    if (length < 1) return mid;
    // Perpendicular unit vector (rotate 90°).
    final perp = Offset(-delta.dy / length, delta.dx / length);
    // Direction from midpoint to center; we want to push AWAY from it.
    final outward = mid - center;
    final outLen = outward.distance;
    final sign = outLen < 0.5
        ? 1.0
        : (perp.dx * outward.dx + perp.dy * outward.dy) >= 0
            ? 1.0
            : -1.0;
    final sag = math.max(minSagPx, length * sagFactor);
    return mid + perp * (sag * sign);
  }

  Offset _bezier(Offset a, Offset c, Offset b, double t) {
    final u = 1.0 - t;
    return Offset(
      u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx,
      u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (agents.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final orchPoint = _resolve(orchestrator.id, center);
    // Monotonic flow clock — seconds since epoch as a double. The
    // wire-flow blobs phase off this instead of `pulse.value`, which
    // is an AnimationController in repeat() mode and snaps 1.0→0.0
    // every cycle. That snap was making every edge's blob stream
    // jump backwards in lockstep ("all lines jump at once"). Using
    // a monotonic clock and wrapping with `t - t.floor()` keeps
    // motion perfectly continuous across cycle boundaries.
    final flowTime =
        DateTime.now().millisecondsSinceEpoch / 1000.0;

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

    // Per-edge deterministic phase offset so streams on different
    // edges aren't all aligned (would read as a single global pulse
    // instead of independent network links).
    double edgePhase(String ka, String kb) {
      final s = ka.compareTo(kb) <= 0 ? '$ka|$kb' : '$kb|$ka';
      var hash = 0x811c9dc5;
      for (var i = 0; i < s.length; i++) {
        hash ^= s.codeUnitAt(i);
        hash = (hash * 0x01000193) & 0xFFFFFFFF;
      }
      return (hash & 0xFFFF) / 0xFFFF;
    }

    // ── Baseline persistent edges ─────────────────────────────────
    // 1) Inter-agent dim full-mesh (chords).
    // 2) Orchestrator spokes (brighter — real broker topology).
    // Both layers always paint and always *flow* — the wire itself is
    // the ambient activity, not occasional blips on top of a static
    // line. Alpha floor is load-bearing for the brief's "lines never
    // disappear entirely" constraint.
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
        final ctrl = _curveControl(pa, pb, center, sagFactor: 0.11);
        _drawEdge(
          canvas,
          pa,
          pb,
          control: ctrl,
          baseAlpha: 0.07,
          heat: h,
          baseColor: DuckColors.councilAccentDim,
          hotColor: DuckColors.councilAccentHi,
          baseWidth: 0.55,
          phaseOffset: edgePhase(a.id, b.id),
          flowDensity: 0.6,
          flowTime: flowTime,
        );
      }
    }

    for (final agent in agents) {
      if (mutedAgentIds.contains(agent.id)) continue;
      final p = points[agent.id];
      if (p == null) continue;
      final h = heat[_pairKey(orchestrator.id, agent.id)] ?? 0;
      // Spokes get a smaller sag — they're the broker backbone, the
      // eye expects them mostly straight. The hash-driven sign baked
      // into _curveControl still keeps adjacent spokes from
      // collapsing onto each other visually.
      final ctrl = _curveControl(orchPoint, p, center, sagFactor: 0.05);
      _drawEdge(
        canvas,
        orchPoint,
        p,
        control: ctrl,
        // Spokes have a higher floor — the orchestrator backbone is
        // always slightly more present than the inter-agent web.
        baseAlpha: 0.16,
        heat: h,
        baseColor: DuckColors.councilAccent,
        hotColor: DuckColors.councilAccentHi,
        baseWidth: 0.85,
        phaseOffset: edgePhase(orchestrator.id, agent.id),
        flowDensity: 1.0,
        flowTime: flowTime,
      );
    }

    // ── Live packets from CouncilEvents ───────────────────────────
    // Real events drive every packet — no fake timer. Each event
    // resolves to a (color, speed, intensity, isError) spec via
    // `_eventSpec`. message_sent events read their `data['kind']`
    // so dispatch reads bright, reply reads warm, ask_pool reads
    // purple, errors strobe red. See encoding table at top of file.
    //
    // Multiple concurrent packets on the same edge are staggered
    // two ways: (a) ageMs naturally separates them along t, and
    // (b) a per-event lane offset hashed from createdAt nudges the
    // bezier control point so co-directional packets ride slightly
    // different sub-curves instead of stacking into one smear.
    for (final event in events.reversed.take(40)) {
      final ageMs = now.difference(event.createdAt).inMilliseconds;
      final spec = _eventSpec(event.type, event.data);
      if (spec == null) continue;
      if (ageMs > spec.ttlMs) continue;
      if (mutedAgentIds.contains(event.fromAgentId)) continue;
      if (mutedAgentIds.contains(event.toAgentId)) continue;
      final fromPoint = points[event.fromAgentId];
      final toPoint = points[event.toAgentId];
      if (fromPoint == null && toPoint == null) continue;
      final from = fromPoint ?? orchPoint;
      final to = toPoint ?? orchPoint;
      if (from == to) continue;
      final t = ((ageMs / spec.ttlMs) * spec.speedScale).clamp(0.0, 1.0);
      // Lane offset in [-1,1] from a stable hash of the event's
      // timestamp + endpoints. Multiplies the perpendicular sag so
      // concurrent packets fan out instead of overlapping.
      final laneSeed = event.createdAt.microsecondsSinceEpoch ^
          event.fromAgentId.hashCode ^
          (event.toAgentId.hashCode << 1);
      final laneOffset = (((laneSeed & 0xFFFF) / 0xFFFF) - 0.5) * 0.06;
      final ctrl = _curveControl(
        from,
        to,
        center,
        sagFactor: 0.10 + laneOffset,
      );
      _drawPacket(
        canvas,
        from,
        to,
        control: ctrl,
        t: t,
        accent: spec.color,
        isError: spec.isError,
        intensity: spec.intensity,
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
          NetworkPacketKind.message => DuckColors.councilAccentHi,
          NetworkPacketKind.reply => DuckColors.councilAccent,
          NetworkPacketKind.error => DuckColors.stateError,
        };
        final intensity = switch (p.kind) {
          NetworkPacketKind.message => 1.15,
          NetworkPacketKind.reply => 0.9,
          NetworkPacketKind.error => 1.4,
        };
        _drawPacket(
          canvas,
          from,
          to,
          control: _curveControl(from, to, center, sagFactor: 0.10),
          t: t,
          accent: accent,
          isError: p.kind == NetworkPacketKind.error,
          intensity: intensity,
        );
      }
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Edge rendering: curved (quadratic-bezier) wire with three
  // layered strokes for depth + a traveling Gaussian highlight that
  // reads as fiber-optic light, not Morse-code dashes.
  //
  //   Layer 1 (only when hot): wide, blurred halo, additive — the
  //           "the wire is glowing through fog" cue.
  //   Layer 2 (always)       : the persistent colored core, drawn
  //           as a path stroke so curvature is preserved end-to-end.
  //   Layer 3 (when warm)    : a thin white-hot specular sitting on
  //           top of the core for ~30% of width — gives the wire a
  //           sense of being lit FROM ABOVE rather than emitting.
  //   Highlight stream       : N traveling Gaussian "blobs" sampled
  //           along the bezier with a bell envelope. Two streams
  //           (forward + reverse) phase-locked to the global pulse.
  //
  // Heat saturates around 2.5 (~3 events within ~1.4s) and increases
  // brightness, width, halo radius, and blob count.
  // ──────────────────────────────────────────────────────────────
  void _drawEdge(
    Canvas canvas,
    Offset a,
    Offset b, {
    required Offset control,
    required double baseAlpha,
    required double heat,
    required Color baseColor,
    required Color hotColor,
    required double baseWidth,
    double phaseOffset = 0.0,
    double flowDensity = 1.0,
    required double flowTime,
  }) {
    if (a == b) return;
    final length = (b - a).distance;
    if (length < 4) return;

    final norm = (heat / 2.5).clamp(0.0, 1.0);
    final width = baseWidth + (1.6 - baseWidth) * norm;
    final wireAlpha = (baseAlpha + (0.18 * norm)).clamp(0.0, 0.42);
    final hot = Color.lerp(baseColor, hotColor, 0.35 + 0.65 * norm)!;

    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..quadraticBezierTo(control.dx, control.dy, b.dx, b.dy);

    // 1) Hot bloom underlay (only when there's recent traffic).
    if (norm > 0.05) {
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..color = hotColor.withValues(alpha: 0.20 * norm)
        ..strokeCap = StrokeCap.round
        ..strokeWidth = width + 5
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5)
        ..blendMode = BlendMode.plus;
      canvas.drawPath(path, glow);
    }

    // 2) Persistent colored core — draw with a longitudinal gradient
    //    shader so the line itself has parallax-style brightness
    //    variation along its length (brighter mid, dimmer at the
    //    endpoints). This is the single biggest "not flat" cue.
    final coreShader = ui.Gradient.linear(
      a,
      b,
      [
        baseColor.withValues(alpha: wireAlpha * 0.55),
        hot.withValues(alpha: wireAlpha),
        baseColor.withValues(alpha: wireAlpha * 0.55),
      ],
      const <double>[0.0, 0.5, 1.0],
    );
    final wirePaint = Paint()
      ..style = PaintingStyle.stroke
      ..shader = coreShader
      ..strokeCap = StrokeCap.round
      ..strokeWidth = width * 0.75;
    canvas.drawPath(path, wirePaint);

    // 3) Specular highlight (warm/hot only) — a thinner, brighter
    //    inner stroke that lands inside the core and sells "lit from
    //    above" geometry instead of "I am a flat line".
    if (norm > 0.18) {
      final spec = Paint()
        ..style = PaintingStyle.stroke
        ..color = Color.lerp(hot, Colors.white, 0.55)!
            .withValues(alpha: (0.22 + 0.30 * norm).clamp(0.0, 0.55))
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(0.4, width * 0.32);
      canvas.drawPath(path, spec);
    }

    // 4) Traveling Gaussian highlights — fiber-optic light packets
    //    riding the wire. Each "blob" is a soft circle sampled at a
    //    point on the bezier; multiple blobs per stream give a
    //    smooth flowing quality without the staccato of dashes.
    // Cut blob density hard: a single forward stream with 1..2 blobs
    // reads as light traveling along a wire, not a beaded necklace.
    // (Old: 2 streams × 1..2 blobs = 2..4 dots per edge.)
    final blobCount = 1 + (1 * norm).round();
    const streamCount = 1;
    // Flow speed is now in CYCLES PER SECOND. Driven by the
    // monotonic flowTime clock so cycle boundaries don't snap every
    // edge backwards in lockstep (the old `pulse * flowSpeed` form
    // did exactly that — pulse wraps 1.0→0.0 every 5.2s).
    final flowSpeed = 0.085 + 0.125 * norm;
    final blobAlpha = (0.34 + 0.42 * norm).clamp(0.30, 0.78);
    final blobRadius = (width * 1.6 + 1.4).clamp(1.6, 4.4);

    for (var stream = 0; stream < streamCount; stream++) {
      final reverse = stream == 1;
      final streamPhase = stream * 0.5;
      for (var i = 0; i < blobCount; i++) {
        final raw = flowTime * flowSpeed +
            phaseOffset +
            streamPhase +
            i / blobCount;
        var t = raw - raw.floorToDouble();
        if (reverse) t = 1.0 - t;
        // Bell envelope so blobs softly fade in/out at the ends.
        final env = math.sin(t * math.pi);
        if (env <= 0.06) continue;

        final pos = _bezier(a, control, b, t);
        // Soft outer glow for this blob.
        canvas.drawCircle(
          pos,
          blobRadius + 2.2,
          Paint()
            ..color = hotColor.withValues(alpha: blobAlpha * env * 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3)
            ..blendMode = BlendMode.plus,
        );
        // Crisp head.
        canvas.drawCircle(
          pos,
          blobRadius,
          Paint()..color = hot.withValues(alpha: blobAlpha * env),
        );
        // White-hot pinpoint specular at peak only — turns the blob
        // into a glistening bead rather than a colored dot.
        if (env > 0.7) {
          canvas.drawCircle(
            pos,
            blobRadius * 0.45,
            Paint()
              ..color = Colors.white.withValues(alpha: 0.55 * (env - 0.7) / 0.3),
          );
        }
      }
    }
  }

  // ──────────────────────────────────────────────────────────────
  // Packet rendering: the packet now rides the SAME quadratic bezier
  // the edge was drawn on, so live comms read as light traveling
  // along the fiber rather than a separate straight overlay.
  // ──────────────────────────────────────────────────────────────
  void _drawPacket(
    Canvas canvas,
    Offset from,
    Offset to, {
    required Offset control,
    required double t,
    required Color accent,
    required bool isError,
    double intensity = 1.0,
  }) {
    final eased = Curves.easeInOutCubic.transform(t);
    final fade = (1 - t) * intensity;
    final strobe = isError
        ? (0.65 + 0.35 * math.sin(pulse * math.pi * 18))
        : 1.0;

    // Energized edge under the packet — same bezier as the wire so
    // the highlight kisses the curve, not a chord across it.
    final path = Path()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(control.dx, control.dy, to.dx, to.dy);
    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..color = accent.withValues(alpha: 0.55 * fade * strobe)
      ..strokeWidth = isError ? 2.4 : 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, edgePaint);

    // Trail: 5 fading dots behind the head along the eased curve.
    const trailSteps = 5;
    for (var i = trailSteps; i >= 1; i--) {
      final lag = i * 0.040;
      final tt = (eased - lag).clamp(0.0, 1.0);
      final pos = _bezier(from, control, to, tt);
      final alpha = (fade * (1.0 - i / (trailSteps + 1.0))) * 0.85 * strobe;
      canvas.drawCircle(
        pos,
        (isError ? 4.5 : 3.8) * (1.0 - i / (trailSteps + 1.5)),
        Paint()..color = accent.withValues(alpha: alpha),
      );
    }

    // Head + halo — sampled on the curve.
    final head = _bezier(from, control, to, eased);
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
    // White-hot core: the packet has a tiny bright pinpoint that
    // sells it as a coherent "thing" rather than a colored smudge.
    canvas.drawCircle(
      head,
      headRadius * 0.42,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.85 * fade * strobe),
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

  // (Ambient-packet stub removed — fiber-flow blobs in _drawEdge
  // now own the ambient channel.)

  // Resolve a CouncilEvent to its visual pulse spec. message_sent
  // events delegate to the embedded `kind` (dispatch / reply /
  // ask_pool / pool_reply / ask_user / user_reply / review /
  // followup) — without this, the bulk of agent-to-agent traffic
  // would emit zero pulses (only lifecycle events would fire).
  _EventSpec? _eventSpec(String type, Map<String, dynamic> data) {
    switch (type) {
      case 'message_sent':
        final kind = (data['kind'] as String?) ?? '';
        return _messageKindSpec(kind);
      case 'dispatched':
        return const _EventSpec(
          DuckColors.councilAccentHi,
          false,
          ttlMs: 2400,
          speedScale: 1.25,
          intensity: 1.2,
        );
      case 'asked_pool':
        return const _EventSpec(
          DuckColors.accentPurple,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
      case 'pool_reply':
        return const _EventSpec(
          DuckColors.councilAccent,
          false,
          ttlMs: 2400,
          intensity: 0.95,
        );
      case 'asked_user':
      case 'user_reply':
        return const _EventSpec(
          DuckColors.accentDuck,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
      case 'agent_done':
      case 'evaluator_done':
        return const _EventSpec(
          DuckColors.councilAccent,
          false,
          ttlMs: 2400,
          intensity: 0.9,
        );
      case 'reviewer_followup':
        return const _EventSpec(
          DuckColors.accentDuck,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
      case 'agent_error':
        return const _EventSpec(
          DuckColors.stateError,
          true,
          ttlMs: 1600,
          speedScale: 1.55,
          intensity: 1.4,
        );
    }
    return null;
  }

  _EventSpec? _messageKindSpec(String kind) {
    switch (kind) {
      case 'dispatch':
        return const _EventSpec(
          DuckColors.councilAccentHi,
          false,
          ttlMs: 2400,
          speedScale: 1.25,
          intensity: 1.2,
        );
      case 'reply':
        return const _EventSpec(
          DuckColors.councilAccent,
          false,
          ttlMs: 2400,
          intensity: 0.95,
        );
      case 'ask_pool':
        return const _EventSpec(
          DuckColors.accentPurple,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
      case 'pool_reply':
        return const _EventSpec(
          DuckColors.councilAccent,
          false,
          ttlMs: 2400,
          intensity: 0.9,
        );
      case 'ask_user':
      case 'user_reply':
        return const _EventSpec(
          DuckColors.accentDuck,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
      case 'review':
      case 'followup':
        return const _EventSpec(
          DuckColors.accentDuck,
          false,
          ttlMs: 2400,
          intensity: 1.0,
        );
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
  final int ttlMs;
  final double speedScale;
  final double intensity;
  const _EventSpec(
    this.color,
    this.isError, {
    this.ttlMs = 2400,
    this.speedScale = 1.0,
    this.intensity = 1.0,
  });
}

// (`_AgentRhythm` removed — was dead code; per-edge phase is now
// derived inline in _CouncilTrafficPainter via `edgePhase`.)
