/// Council Traffic Layer — Dispatch Beams + Sustained Channels
/// =============================================================
///
/// This layer paints the orchestrator → agent dispatch traffic. It
/// reads three signals to build the picture every frame:
///
///   1. Recent `dispatched` events → fire a bright BEAM from the
///      orchestrator card edge toward the recipient. The beam is a
///      thick gradient lance with a short contrail; it travels over
///      ~400ms and dies. On arrival the recipient end of the beam
///      flares briefly so the eye reads "the packet landed."
///
///   2. Agents currently in `working` (or replying / askingPool)
///      state → draw a SUSTAINED CHANNEL between the orchestrator
///      and that agent. Dim, bezier-arced, with a slow low-alpha
///      energy pulse riding the curve from source to target. Reads
///      as "this agent is actively under orders." Persists for the
///      duration of the agent's work.
///
///   3. Recent `agentDone` events → fire a one-shot RETURN PACKET
///      from the agent back to the orchestrator. Bright cyan,
///      source/target swapped from the dispatch beam. Reads as
///      "result coming back." After it lands the channel fades.
///
///   * Recent `agentError` events → the channel desaturates to grey
///     and fades out (no return packet).
///
/// The three phases all use the same accent family (cyan / mint
/// frost — `DuckColors.councilAccent` ramp) so the user reads them
/// as distinct phases of ONE conversation, not three independent
/// effects. Color discipline:
///
///   * Beam (outbound dispatch) — `councilAccentHi`, bright, sharp.
///   * Channel (sustained work) — `councilAccentDim` → `councilAccent`,
///     low alpha, slow pulse.
///   * Return packet — `councilAccentHi`, one-shot, swapped endpoints.
///   * Error fade — desaturates to `fgSubtle`, no replacement glow.
///
/// A faint ambient mesh continues to live in the background. Without
/// it the chamber's "everyone could whisper" topology disappears and
/// idle moments read as cold; with it the room stays networked at all
/// times. The mesh is intentionally MUCH dimmer than the dispatch
/// beams — it's wallpaper, not signal.
///
/// Z-order: rendered above the chamber backdrop + stage lighting,
/// below the discourse layer and the agent cards.
///
/// Performance:
///   * Single [CustomPaint] with one painter, owns one [RepaintBoundary].
///   * Per-frame work is O(agents) for the channels + O(recent events)
///     for the beams/return-packets. Path / Paint objects are reused
///     between frames where possible.
///   * `NetworkController` API surface is preserved. Its imperative
///     `pulse(...)` API still works — it now feeds the same beam
///     pipeline as event-driven dispatches.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_speech_bubbles.dart';
import 'network_controller.dart';

/// Lifetime of an outbound dispatch beam. Tuned so the eye can
/// register the source, the travel, and the arrival burst as one
/// coherent gesture without it lingering on the stage. 400ms is the
/// canonical Material "expressive" duration for a directional motion.
const Duration kDispatchBeamLifetime = Duration(milliseconds: 420);

/// Lifetime of a return-packet from agent → orchestrator on agentDone.
/// Slightly longer than the outbound beam — the result coming back
/// is the satisfying beat the user is waiting for, so we let it
/// breathe.
///
/// Named `kDispatchReturnPacketLifetime` rather than the shorter
/// `kReturnPacketLifetime` because `council_discourse_layer.dart`
/// already exports the latter (with a different meaning + value)
/// and both files are imported into `council_theater.dart` — the
/// rename avoids a top-level symbol collision.
const Duration kDispatchReturnPacketLifetime = Duration(milliseconds: 520);

/// How long after an agent enters `error` we keep painting the
/// channel as a desaturated fade-out. Past this window the channel
/// is gone.
const Duration kErrorFadeOutLifetime = Duration(milliseconds: 900);

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
    return RepaintBoundary(
      child: IgnorePointer(
        child: AnimatedBuilder(
          animation: anchors,
          builder: (context, _) {
            return CustomPaint(
              painter: _DispatchTrafficPainter(
                agents: agents,
                orchestrator: orchestrator,
                events: _windowEvents(events),
                pulse: pulse.value,
                anchors: anchors,
                mutedAgentIds: mutedAgentIds,
                network: network,
                repaint: repaint,
              ),
            );
          },
        ),
      ),
    );
  }

  /// Trim the events list to the recent window the painter actually
  /// reads. Anything older than the longest relevant lifetime can
  /// safely be dropped — saves us a per-frame scan over the full
  /// event history.
  List<CouncilEvent> _windowEvents(List<CouncilEvent> all) {
    if (all.isEmpty) return all;
    final now = DateTime.now();
    final maxAge = math.max(
      math.max(
        kDispatchBeamLifetime.inMilliseconds,
        kDispatchReturnPacketLifetime.inMilliseconds,
      ),
      kErrorFadeOutLifetime.inMilliseconds,
    );
    final cutoff = now.subtract(Duration(milliseconds: maxAge + 200));
    // Cap by count too — protects against pathological event spam.
    final list = all.where((e) => e.createdAt.isAfter(cutoff)).toList();
    if (list.length > 64) return list.sublist(list.length - 64);
    return list;
  }
}

class _DispatchTrafficPainter extends CustomPainter {
  final List<CouncilAgent> agents;
  final CouncilAgent orchestrator;
  final List<CouncilEvent> events;
  final double pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;
  final NetworkController? network;

  _DispatchTrafficPainter({
    required this.agents,
    required this.orchestrator,
    required this.events,
    required this.pulse,
    required this.anchors,
    required this.mutedAgentIds,
    required this.network,
    required Listenable repaint,
  }) : super(repaint: repaint);

  // Reusable paint objects. The shaders MUST be rebuilt every paint
  // (their gradients depend on per-frame endpoints) but the Paint
  // struct itself can be reused.
  final Paint _strokePaint = Paint()
    ..style = PaintingStyle.stroke
    ..isAntiAlias = true
    ..strokeCap = StrokeCap.round;
  final Paint _fillPaint = Paint()..isAntiAlias = true;
  final Path _path = Path();

  Offset _resolve(String id, Offset fallback) {
    return anchors.centerOf(id) ?? fallback;
  }

  /// Quadratic bezier control point for the bezier that the channel
  /// and return-packet ride on. Slight outward bow so concurrent
  /// channels don't all overlap each other.
  Offset _channelControl(Offset a, Offset b, Offset center) {
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final delta = b - a;
    final length = delta.distance;
    if (length < 1) return mid;
    final perp = Offset(-delta.dy / length, delta.dx / length);
    final outward = mid - center;
    final outLen = outward.distance;
    final sign = outLen < 0.5
        ? 1.0
        : (perp.dx * outward.dx + perp.dy * outward.dy) >= 0
            ? 1.0
            : -1.0;
    final sag = math.max(8.0, length * 0.07);
    return mid + perp * (sag * sign);
  }

  Offset _bezier(Offset a, Offset c, Offset b, double t) {
    final u = 1.0 - t;
    return Offset(
      u * u * a.dx + 2 * u * t * c.dx + t * t * b.dx,
      u * u * a.dy + 2 * u * t * c.dy + t * t * b.dy,
    );
  }

  /// Direction of the recent error events keyed by agent id, so the
  /// channel painter can desaturate while the fade-out window runs.
  /// Returns the age of the most recent error event or null if none
  /// landed in the fade window.
  int? _recentErrorAgeMs(String agentId, DateTime now) {
    int? best;
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.type != CouncilEventType.agentError) continue;
      if (e.fromAgentId != agentId && e.toAgentId != agentId) continue;
      final age = now.difference(e.createdAt).inMilliseconds;
      if (age < 0) continue;
      if (age > kErrorFadeOutLifetime.inMilliseconds) continue;
      if (best == null || age < best) best = age;
    }
    return best;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (agents.isEmpty) return;
    final center = Offset(size.width / 2, size.height / 2);
    final orchPoint = _resolve(orchestrator.id, center);

    // Resolve every agent's anchor. Fall back to a ring approximation
    // so the layer still draws *something* before the post-frame
    // anchor sync lands on the first paint of a new session.
    final points = <String, Offset>{orchestrator.id: orchPoint};
    for (var i = 0; i < agents.length; i++) {
      final fallbackAngle = -math.pi / 2 + (math.pi * 2 * i / agents.length);
      final fallback = Offset(
        center.dx + math.cos(fallbackAngle) * size.shortestSide * 0.34,
        center.dy + math.sin(fallbackAngle) * size.shortestSide * 0.34,
      );
      points[agents[i].id] = _resolve(agents[i].id, fallback);
    }

    final now = DateTime.now();

    // ── 1. Ambient mesh ─────────────────────────────────────────
    // VERY dim baseline so the room stays networked when nothing
    // active is happening. The mesh is wallpaper, not signal — beams
    // and channels dominate visually.
    _paintAmbientMesh(canvas, points, center);

    // ── 2. Sustained channels ────────────────────────────────────
    // One per agent currently working / replying / asking pool. The
    // channel is a thin bezier with a slow low-alpha energy pulse
    // riding source → target.
    for (final agent in agents) {
      if (mutedAgentIds.contains(agent.id)) continue;
      final pt = points[agent.id];
      if (pt == null || pt == orchPoint) continue;
      final isWorking = agent.status == CouncilAgentStatus.working ||
          agent.status == CouncilAgentStatus.replying ||
          agent.status == CouncilAgentStatus.askingPool;
      if (!isWorking) continue;
      final errorAge = _recentErrorAgeMs(agent.id, now);
      _paintChannel(
        canvas,
        from: orchPoint,
        to: pt,
        center: center,
        agentId: agent.id,
        // Channel is bright until the agent transitions away from
        // working; once an error has landed within the fade window,
        // we desaturate over the remaining time.
        errorAgeMs: errorAge,
      );
    }

    // Agents in `error` get an explicit fade-out channel even after
    // their status moved off `working`. This is the "no replacement
    // glow" the brief calls for — the channel still paints, just
    // desaturated, then disappears.
    for (final agent in agents) {
      if (mutedAgentIds.contains(agent.id)) continue;
      if (agent.status != CouncilAgentStatus.error) continue;
      final pt = points[agent.id];
      if (pt == null || pt == orchPoint) continue;
      final errorAge = _recentErrorAgeMs(agent.id, now);
      if (errorAge == null) continue;
      _paintChannel(
        canvas,
        from: orchPoint,
        to: pt,
        center: center,
        agentId: agent.id,
        errorAgeMs: errorAge,
        errorOnly: true,
      );
    }

    // ── 3. Event-driven beams + return packets ─────────────────
    for (final event in events) {
      final ageMs = now.difference(event.createdAt).inMilliseconds;
      if (ageMs < 0) continue;
      switch (event.type) {
        case CouncilEventType.dispatched:
          if (ageMs > kDispatchBeamLifetime.inMilliseconds) continue;
          _paintBeam(
            canvas,
            from: _resolveBeamEndpoint(event.fromAgentId, points, orchPoint),
            to: _resolveBeamEndpoint(event.toAgentId, points, orchPoint),
            center: center,
            ageMs: ageMs,
            lifetimeMs: kDispatchBeamLifetime.inMilliseconds,
            color: DuckColors.councilAccentHi,
            isReturn: false,
          );
        case CouncilEventType.agentDone:
        case CouncilEventType.evaluatorDone:
          if (ageMs > kDispatchReturnPacketLifetime.inMilliseconds) continue;
          // `agentDone` carries fromAgentId = agent, toAgentId =
          // orchestrator in the council event schema. The return
          // packet visually moves from the agent back to the orch.
          _paintBeam(
            canvas,
            from: _resolveBeamEndpoint(event.fromAgentId, points, orchPoint),
            to: _resolveBeamEndpoint(event.toAgentId, points, orchPoint),
            center: center,
            ageMs: ageMs,
            lifetimeMs: kDispatchReturnPacketLifetime.inMilliseconds,
            color: DuckColors.councilAccentHi,
            isReturn: true,
          );
        default:
          break;
      }
    }

    // ── 4. Imperative NetworkController packets ────────────────
    // External callers (Signal, debug tooling) can still fire a
    // packet via `network.pulse(...)`. We route them through the
    // same beam pipeline so they read identically to event-driven
    // dispatches. Error packets get the desaturated-grey treatment
    // because we don't want a red beam strobing across the chamber
    // when an agent's already showing a red status pill.
    final ctrl = network;
    if (ctrl != null) {
      ctrl.prune();
      for (final p in ctrl.packets) {
        if (mutedAgentIds.contains(p.fromId)) continue;
        if (mutedAgentIds.contains(p.toId)) continue;
        final ttl = p.kind == NetworkPacketKind.error
            ? NetworkController.errorPacketTtl.inMilliseconds
            : NetworkController.packetTtl.inMilliseconds;
        final ageMs =
            now.difference(p.spawnedAt).inMilliseconds * p.speedScale;
        if (ageMs > ttl) continue;
        final color = switch (p.kind) {
          NetworkPacketKind.message => DuckColors.councilAccentHi,
          NetworkPacketKind.reply => DuckColors.councilAccent,
          NetworkPacketKind.error => DuckColors.fgSubtle,
        };
        _paintBeam(
          canvas,
          from: _resolveBeamEndpoint(p.fromId, points, orchPoint),
          to: _resolveBeamEndpoint(p.toId, points, orchPoint),
          center: center,
          ageMs: ageMs.round(),
          lifetimeMs: ttl,
          color: color,
          isReturn: p.kind == NetworkPacketKind.reply,
        );
      }
    }
  }

  Offset _resolveBeamEndpoint(
    String id,
    Map<String, Offset> points,
    Offset orchFallback,
  ) {
    if (id.isEmpty) return orchFallback;
    return points[id] ?? orchFallback;
  }

  /// Ambient mesh — VERY dim baseline lines so the room stays
  /// networked when nothing is in flight. Significantly quieter than
  /// the previous fiber-flow blob spam so the eye doesn't read
  /// "decorative noise" when looking at idle state.
  void _paintAmbientMesh(
    Canvas canvas,
    Map<String, Offset> points,
    Offset center,
  ) {
    final orchPoint = points[orchestrator.id] ?? center;
    // Orchestrator spokes — bright enough to register as the backbone.
    for (final agent in agents) {
      if (mutedAgentIds.contains(agent.id)) continue;
      final pt = points[agent.id];
      if (pt == null || pt == orchPoint) continue;
      final ctrl = _channelControl(orchPoint, pt, center);
      _path
        ..reset()
        ..moveTo(orchPoint.dx, orchPoint.dy)
        ..quadraticBezierTo(ctrl.dx, ctrl.dy, pt.dx, pt.dy);
      _strokePaint
        ..shader = null
        ..color = DuckColors.councilAccentDim.withValues(alpha: 0.10)
        ..strokeWidth = 0.6;
      canvas.drawPath(_path, _strokePaint);
    }
    // Inter-agent chords — dimmer still. Cap to the first N pairs to
    // bound per-frame cost on large councils.
    var pairs = 0;
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
        if (pairs++ > 28) return; // cap
        final ctrl = _channelControl(pa, pb, center);
        _path
          ..reset()
          ..moveTo(pa.dx, pa.dy)
          ..quadraticBezierTo(ctrl.dx, ctrl.dy, pb.dx, pb.dy);
        _strokePaint
          ..shader = null
          ..color = DuckColors.councilAccentDim.withValues(alpha: 0.045)
          ..strokeWidth = 0.45;
        canvas.drawPath(_path, _strokePaint);
      }
    }
  }

  /// Sustained channel from [from] (orchestrator) to [to] (an agent
  /// currently in `working`/`replying`/`askingPool` state).
  ///
  /// Visual:
  ///   * A thin bezier core drawn in the cyan accent ramp.
  ///   * A slow energy pulse (Gaussian highlight) riding the bezier
  ///     source → target. Subtle — the pulse is the cue that the
  ///     channel is "live", but not loud enough to compete with the
  ///     dispatch beam that lit it up in the first place.
  ///
  /// If [errorAgeMs] is non-null we desaturate by interpolating to
  /// muted grey over the fade-out window. If [errorOnly] is true the
  /// channel is painted ONLY as the fade-out (used when the agent
  /// itself transitioned to error and is no longer "working").
  void _paintChannel(
    Canvas canvas, {
    required Offset from,
    required Offset to,
    required Offset center,
    required String agentId,
    int? errorAgeMs,
    bool errorOnly = false,
  }) {
    if (from == to) return;
    final ctrl = _channelControl(from, to, center);

    // Fade math — 1.0 for healthy channel, 0.0 at the end of the
    // error fade window.
    var alphaScale = 1.0;
    var desaturation = 0.0;
    if (errorAgeMs != null) {
      final norm = (errorAgeMs / kErrorFadeOutLifetime.inMilliseconds)
          .clamp(0.0, 1.0);
      alphaScale = 1.0 - norm;
      desaturation = norm;
      if (errorOnly) {
        // For error-only channels we additionally taper the start
        // alpha because the agent has already moved past `working`.
        alphaScale *= 0.85;
      }
    }
    if (alphaScale <= 0.02) return;

    final baseColor = Color.lerp(
      DuckColors.councilAccent,
      DuckColors.fgSubtle,
      desaturation,
    )!;
    final hotColor = Color.lerp(
      DuckColors.councilAccentHi,
      DuckColors.fgSubtle,
      desaturation,
    )!;

    _path
      ..reset()
      ..moveTo(from.dx, from.dy)
      ..quadraticBezierTo(ctrl.dx, ctrl.dy, to.dx, to.dy);

    // Core stroke — a thin bezier core with a longitudinal gradient
    // so the channel feels "lit through" rather than uniformly dim.
    final coreShader = ui.Gradient.linear(
      from,
      to,
      [
        baseColor.withValues(alpha: 0.22 * alphaScale),
        hotColor.withValues(alpha: 0.32 * alphaScale),
        baseColor.withValues(alpha: 0.18 * alphaScale),
      ],
      const <double>[0.0, 0.5, 1.0],
    );
    _strokePaint
      ..shader = coreShader
      ..color = baseColor.withValues(alpha: 0.30 * alphaScale)
      ..strokeWidth = 1.05;
    canvas.drawPath(_path, _strokePaint);

    // Soft halo (only on healthy channels) — sells the "lit" feel
    // when the channel is active. Suppressed during error fade so
    // the desaturation reads clearly.
    if (desaturation < 0.45) {
      final haloShader = ui.Gradient.linear(
        from,
        to,
        [
          hotColor.withValues(alpha: 0.08 * alphaScale),
          hotColor.withValues(alpha: 0.16 * alphaScale),
          hotColor.withValues(alpha: 0.08 * alphaScale),
        ],
        const <double>[0.0, 0.5, 1.0],
      );
      _strokePaint
        ..shader = haloShader
        ..color = hotColor.withValues(alpha: 0.16 * alphaScale)
        ..strokeWidth = 4.0
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
      canvas.drawPath(_path, _strokePaint);
      _strokePaint.maskFilter = null;
    }

    // Slow source → target energy pulse. The pulse phase is derived
    // from a stable hash of `agentId` so different agents' channels
    // don't pulse in lockstep.
    if (desaturation < 0.85) {
      final clockSec = DateTime.now().millisecondsSinceEpoch / 1000.0;
      final phaseOffset = _phaseForId(agentId);
      final raw = clockSec * 0.55 + phaseOffset;
      final t = raw - raw.floorToDouble();
      final env = math.sin(t * math.pi);
      if (env > 0.05) {
        final pos = _bezier(from, ctrl, to, t);
        _fillPaint
          ..color = hotColor.withValues(alpha: 0.45 * env * alphaScale)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3.0)
          ..blendMode = BlendMode.plus;
        canvas.drawCircle(pos, 3.2, _fillPaint);
        _fillPaint
          ..maskFilter = null
          ..blendMode = BlendMode.srcOver
          ..color = hotColor.withValues(alpha: 0.85 * env * alphaScale);
        canvas.drawCircle(pos, 1.6, _fillPaint);
      }
    }
  }

  /// One-shot beam (outbound dispatch OR return packet).
  ///
  /// Visuals:
  ///   * The path "fires" from [from] toward [to] — at ageMs=0 nothing
  ///     is visible, at ageMs ~ 0.18 * lifetime the whole bezier is
  ///     lit, then the trailing edge collapses behind the leading
  ///     edge to give a moving lance with a contrail.
  ///   * On arrival (t > 0.75) a soft halo blooms at the recipient
  ///     end so the eye sees "the packet landed".
  ///
  /// Return packets are visually identical to outbound beams except
  /// the endpoints are swapped at the call site, so the reader sees
  /// "result coming back" via direction alone.
  void _paintBeam(
    Canvas canvas, {
    required Offset from,
    required Offset to,
    required Offset center,
    required int ageMs,
    required int lifetimeMs,
    required Color color,
    required bool isReturn,
  }) {
    if (from == to) return;
    final t = (ageMs / lifetimeMs).clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(t);
    final ctrl = _channelControl(from, to, center);

    // Lance window: a moving span [tHead-len, tHead] along the
    // bezier. The lance grows from a point to ~30% of the curve as
    // it accelerates, then shrinks at arrival.
    final tHead = eased;
    final lanceLen = (0.28 * math.sin(t * math.pi)).clamp(0.04, 0.32);
    final tTail = (tHead - lanceLen).clamp(0.0, 1.0);

    // Sample the bezier in N segments between tTail and tHead and
    // paint a tapered line. Easier + faster than Path.extractPath
    // for a one-shot lance.
    const segments = 14;
    Offset? prev;
    for (var i = 0; i <= segments; i++) {
      final segT = tTail + (tHead - tTail) * (i / segments);
      final pos = _bezier(from, ctrl, to, segT);
      if (prev != null) {
        // Brightness ramps from 0 at the tail to 1 at the head.
        final localT = i / segments;
        final brightness = math.pow(localT, 1.4).toDouble();
        final segColor = color.withValues(
          alpha: (0.85 * brightness * (1.0 - t * 0.45)).clamp(0.0, 0.95),
        );
        _strokePaint
          ..shader = null
          ..color = segColor
          ..strokeWidth = isReturn
              ? (1.6 + 1.6 * brightness)
              : (2.0 + 2.0 * brightness)
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(prev, pos, _strokePaint);
      }
      prev = pos;
    }

    // Head halo — wide soft glow around the leading point. Sells the
    // "fired projectile" energy.
    final head = _bezier(from, ctrl, to, tHead);
    final headFade = 1.0 - t;
    _fillPaint
      ..color = color.withValues(alpha: 0.45 * headFade)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, isReturn ? 7 : 9)
      ..blendMode = BlendMode.plus;
    canvas.drawCircle(head, isReturn ? 8 : 10, _fillPaint);
    _fillPaint
      ..maskFilter = null
      ..blendMode = BlendMode.srcOver
      ..color = color.withValues(alpha: 0.95 * headFade);
    canvas.drawCircle(head, isReturn ? 3.0 : 3.6, _fillPaint);
    // White-hot pinpoint so the head reads as a coherent object.
    _fillPaint.color = Colors.white.withValues(alpha: 0.85 * headFade);
    canvas.drawCircle(head, isReturn ? 1.0 : 1.4, _fillPaint);

    // Arrival burst — once the lance is past ~75% of travel, paint
    // an expanding ring at the destination. Reads as "packet landed".
    if (t > 0.62) {
      final arriveT = ((t - 0.62) / 0.38).clamp(0.0, 1.0);
      final r = 6.0 + 22.0 * arriveT;
      _strokePaint
        ..shader = null
        ..color = color.withValues(alpha: 0.55 * (1.0 - arriveT))
        ..strokeWidth = (1.6 * (1.0 - arriveT)).clamp(0.4, 1.6);
      canvas.drawCircle(to, r, _strokePaint);

      // Soft inner bloom at the recipient — the card-edge flash the
      // brief calls for. We paint it here so the traffic layer owns
      // it; agent cards don't need to react.
      _fillPaint
        ..color = color.withValues(alpha: 0.35 * (1.0 - arriveT))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 8 + 12 * arriveT)
        ..blendMode = BlendMode.plus;
      canvas.drawCircle(to, 14 + 6 * arriveT, _fillPaint);
      _fillPaint
        ..maskFilter = null
        ..blendMode = BlendMode.srcOver;
    }
  }

  double _phaseForId(String id) {
    var h = 2166136261;
    for (var i = 0; i < id.length; i++) {
      h = (h ^ id.codeUnitAt(i)) & 0xFFFFFFFF;
      h = (h * 16777619) & 0xFFFFFFFF;
    }
    return (h % 1000) / 1000.0;
  }

  @override
  bool shouldRepaint(covariant _DispatchTrafficPainter old) {
    return old.events.length != events.length ||
        old.agents.length != agents.length ||
        old.pulse != pulse ||
        old.network != network;
  }
}
