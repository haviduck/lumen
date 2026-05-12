/// Council Discourse Layer
/// ========================
///
/// Renders animated, curved tethers between agents during *peer-to-peer*
/// pool exchanges. Distinct from the traffic layer (which paints the
/// orchestrator-broker mesh) — discourse is about agents talking to
/// agents, NOT about dispatch packets. The user reads this as "look,
/// they're conferring", which is the visual the speech-bubble flashes
/// can't carry on their own (they're per-agent, not relational).
///
/// Z-order: sits ABOVE the traffic layer, BELOW the agent cards and
/// activity bubbles. Imported and placed in `CouncilTheater` between
/// the traffic layer and the positioned agent widgets.
///
/// Event sourcing (read-only — emits nothing):
///   - `askedPool`     — asker fires a pool question. Data carries
///                       `resolvedTargets: List<String>` (the agent ids
///                       the question was routed to).
///   - `poolReply`     — a responder answers. `fromAgentId` is the
///                       responder; `toAgentId` is the asker.
///
/// State model:
///   - Each (asker, responder) pair is a `DiscourseThread`.
///   - On `askedPool`, threads are created in `kQuestioning` for every
///     responder in `resolvedTargets`. The traveling glow runs
///     asker → responder.
///   - On `poolReply`, the matching thread transitions to `kAnswered`.
///     The traveling glow reverses (responder → asker) and the arc
///     warms from purple → mint.
///   - After [kAnsweredLinger], an answered thread fades out and
///     removes itself. Unanswered threads time out after
///     [kQuestionTimeout] so a stuck pool doesn't paint forever.
///
/// Visual encoding:
///   - Arc: cubic bezier with an outward bow proportional to chord
///     length. Avoids overlapping the straight orchestrator spokes.
///   - Base stroke: dim purple (questioning) → soft mint (answered).
///   - Traveling glow: small bright dot riding the arc at ~1.6s
///     period; direction flips between phases.
///   - Soft halo around the glow head so it reads on the dark stage.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_speech_bubbles.dart';

/// How long an answered thread lingers on stage before fading out.
const Duration kAnsweredLinger = Duration(seconds: 6);

/// How long an unanswered question stays on stage if no reply arrives.
/// Pool reply runners cap themselves around `maxIterations: 2` so this
/// generously covers real exchanges; the timeout is a safety net for
/// errored / cancelled replies.
const Duration kQuestionTimeout = Duration(seconds: 45);

/// How long a peer-mention tether stays on stage. Short — these fire
/// frequently and the user reads them as a quick flicker of "agent X
/// just name-checked Y", not as a sustained channel.
const Duration kMentionLinger = Duration(milliseconds: 2400);

/// How long a return-packet on agentDone visibly travels. The packet
/// is a one-shot glow that rides from the completed agent back to
/// the orchestrator — a visual acknowledgement.
const Duration kReturnPacketLifetime = Duration(milliseconds: 1800);

enum DiscoursePhase {
  /// Asker → responder is in flight, waiting for a reply.
  questioning,

  /// Reply received; arc warms purple → mint, glow reverses.
  answered,

  /// One-shot transient: agent name-checked a peer in the stream.
  /// Read-only relational signal; not part of the question cycle.
  mention,

  /// One-shot transient: agent transitioned to done; a "result
  /// packet" travels from the agent back to the orchestrator.
  returnPacket,
}

class DiscourseThread {
  final String askerId;
  final String responderId;
  final DateTime startedAt;
  DiscoursePhase phase;
  DateTime? answeredAt;

  DiscourseThread({
    required this.askerId,
    required this.responderId,
    required this.startedAt,
    this.phase = DiscoursePhase.questioning,
    this.answeredAt,
  });
}

class CouncilDiscourseLayer extends StatelessWidget {
  final List<CouncilEvent> events;
  final Animation<double> pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;

  /// Agent id of the orchestrator. Used as the terminus for
  /// `returnPacket` threads triggered by `agentDone` so completed
  /// agents visibly ack back to the conductor.
  final String orchestratorId;

  const CouncilDiscourseLayer({
    super.key,
    required this.events,
    required this.pulse,
    required this.anchors,
    this.orchestratorId = '',
    this.mutedAgentIds = const <String>{},
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: Listenable.merge([pulse, anchors]),
        builder: (context, _) {
          return CustomPaint(
            painter: _DiscoursePainter(
              threads: _buildThreads(),
              pulse: pulse.value,
              anchors: anchors,
              mutedAgentIds: mutedAgentIds,
              repaint: Listenable.merge([pulse, anchors]),
            ),
          );
        },
      ),
    );
  }

  /// Replay the recent event window into a list of [DiscourseThread]s.
  /// Pure derivation — no internal state — so this widget reacts to
  /// session.events changes the same way the traffic layer does.
  List<DiscourseThread> _buildThreads() {
    final now = DateTime.now();
    final threads = <String, DiscourseThread>{};
    final transients = <DiscourseThread>[];
    String key(String a, String r) => '$a->$r';

    for (final event in events) {
      final age = now.difference(event.createdAt);
      // Window: keep events that could still drive a visible thread.
      // Take the max of all phase windows so a transient mention or
      // a fresh return-packet isn't filtered out before it renders.
      if (age > kQuestionTimeout &&
          age > kAnsweredLinger &&
          age > kMentionLinger &&
          age > kReturnPacketLifetime) {
        continue;
      }

      if (event.type == CouncilEventType.askedPool) {
        final asker = event.fromAgentId;
        if (asker.isEmpty) continue;
        final resolved = (event.data['resolvedTargets'] as List?) ?? const [];
        for (final raw in resolved) {
          if (raw is! String || raw.isEmpty) continue;
          if (raw == asker) continue;
          threads[key(asker, raw)] = DiscourseThread(
            askerId: asker,
            responderId: raw,
            startedAt: event.createdAt,
          );
        }
      } else if (event.type == CouncilEventType.poolReply) {
        final responder = event.fromAgentId;
        final asker = event.toAgentId;
        if (responder.isEmpty || asker.isEmpty) continue;
        final existing = threads[key(asker, responder)];
        if (existing != null) {
          existing
            ..phase = DiscoursePhase.answered
            ..answeredAt = event.createdAt;
        } else {
          threads[key(asker, responder)] = DiscourseThread(
            askerId: asker,
            responderId: responder,
            startedAt: event.createdAt,
            phase: DiscoursePhase.answered,
            answeredAt: event.createdAt,
          );
        }
      } else if (event.type == CouncilEventType.agentPeerMention) {
        // Transient mention tethers — one thread per (speaker → peer).
        // Stored in `transients` (not the keyed map) so a repeated
        // mention within the cooldown window still gets its own
        // short-lived render, and they coexist with any ongoing
        // pool exchange between the same two agents.
        final speaker = event.fromAgentId;
        if (speaker.isEmpty) continue;
        if (age > kMentionLinger) continue;
        final raw = (event.data['mentions'] as List?) ?? const [];
        for (final mentioned in raw) {
          if (mentioned is! String || mentioned.isEmpty) continue;
          if (mentioned == speaker) continue;
          transients.add(
            DiscourseThread(
              askerId: speaker,
              responderId: mentioned,
              startedAt: event.createdAt,
              phase: DiscoursePhase.mention,
            ),
          );
        }
      } else if (event.type == CouncilEventType.agentDone) {
        // Return-packet — completed agent → orchestrator. Skipped
        // when the orchestrator id wasn't provided (e.g. embedded
        // unit-test scenarios), and skipped if the done agent IS
        // the orchestrator.
        if (orchestratorId.isEmpty) continue;
        final from = event.fromAgentId;
        if (from.isEmpty || from == orchestratorId) continue;
        if (age > kReturnPacketLifetime) continue;
        transients.add(
          DiscourseThread(
            askerId: from,
            responderId: orchestratorId,
            startedAt: event.createdAt,
            phase: DiscoursePhase.returnPacket,
          ),
        );
      }
    }

    final out = <DiscourseThread>[];
    for (final t in threads.values) {
      if (t.phase == DiscoursePhase.answered && t.answeredAt != null) {
        if (now.difference(t.answeredAt!) > kAnsweredLinger) continue;
      } else {
        if (now.difference(t.startedAt) > kQuestionTimeout) continue;
      }
      out.add(t);
    }
    out.addAll(transients);
    return out;
  }
}

class _DiscoursePainter extends CustomPainter {
  final List<DiscourseThread> threads;
  final double pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;

  _DiscoursePainter({
    required this.threads,
    required this.pulse,
    required this.anchors,
    required this.mutedAgentIds,
    required Listenable repaint,
  }) : super(repaint: repaint);

  @override
  void paint(Canvas canvas, Size size) {
    if (threads.isEmpty) return;
    final now = DateTime.now();
    for (final thread in threads) {
      if (mutedAgentIds.contains(thread.askerId)) continue;
      if (mutedAgentIds.contains(thread.responderId)) continue;
      _paintThread(canvas, size, thread, now);
    }
  }

  void _paintThread(
    Canvas canvas,
    Size size,
    DiscourseThread thread,
    DateTime now,
  ) {
    final asker = anchors.centerOf(thread.askerId);
    final responder = anchors.centerOf(thread.responderId);
    if (asker == null || responder == null) return;
    if ((asker - responder).distance < 4) return;

    final phaseAlpha = _phaseAlpha(thread, now);
    if (phaseAlpha <= 0.01) return;

    final color = switch (thread.phase) {
      DiscoursePhase.questioning => DuckColors.accentPurple,
      DiscoursePhase.answered => DuckColors.accentMint,
      // Mentions get the warm-gold "duck" accent so the eye reads
      // them as distinct from question/answer arcs.
      DiscoursePhase.mention => DuckColors.accentDuck,
      // Return packets ride the orchestrator's signature cyan so
      // they read as "result back to the conductor".
      DiscoursePhase.returnPacket => DuckColors.accentCyan,
    };
    final glowColor = color;

    final path = _arcPath(asker, responder);
    final metric = path.computeMetrics().first;
    final length = metric.length;

    // Soft halo behind the arc — a wider, more transparent pass to
    // give the line a luminous quality on the dark stage.
    final haloPaint = Paint()
      ..color = color.withValues(alpha: 0.10 * phaseAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.5
      ..strokeCap = StrokeCap.round
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6);
    canvas.drawPath(path, haloPaint);

    // Base arc — dashed to read as "conversation in progress" rather
    // than a hard rendered tether.
    final basePaint = Paint()
      ..color = color.withValues(alpha: 0.42 * phaseAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    _drawDashedPath(
      canvas: canvas,
      metric: metric,
      paint: basePaint,
      dashLength: 7.0,
      gapLength: 5.0,
      phaseOffset: (pulse * length * 0.6) % 12.0,
    );

    // Traveling glow head — direction depends on phase.
    //   • questioning : asker → responder (question travels)
    //   • answered    : responder → asker (answer comes back)
    //   • mention     : speaker → mentioned (eye trace to the peer)
    //   • returnPacket: agent → orchestrator (a single, decaying ride)
    //
    // For one-shot transients we tie progress to the thread's age
    // rather than the global pulse so the packet only travels ONCE
    // across its lifetime (no looping).
    double tForward;
    switch (thread.phase) {
      case DiscoursePhase.questioning:
        tForward = (pulse * 1.6) % 1.0;
      case DiscoursePhase.answered:
        tForward = 1.0 - ((pulse * 1.6) % 1.0);
      case DiscoursePhase.mention:
        final age = now.difference(thread.startedAt);
        tForward = (age.inMilliseconds / kMentionLinger.inMilliseconds)
            .clamp(0.0, 1.0);
      case DiscoursePhase.returnPacket:
        final age = now.difference(thread.startedAt);
        tForward =
            (age.inMilliseconds / kReturnPacketLifetime.inMilliseconds)
                .clamp(0.0, 1.0);
    }
    final tangent = metric.getTangentForOffset(length * tForward);
    if (tangent == null) return;
    final head = tangent.position;

    // Soft outer glow.
    final headGlow = Paint()
      ..color = glowColor.withValues(alpha: 0.45 * phaseAlpha)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 9);
    canvas.drawCircle(head, 6.5, headGlow);

    // Bright core.
    final headCore = Paint()
      ..color = glowColor.withValues(alpha: 0.95 * phaseAlpha);
    canvas.drawCircle(head, 2.6, headCore);

    // A short trailing tail behind the head so the motion reads even
    // when the dashed base is the same color.
    final tailSegments = 4;
    for (var i = 1; i <= tailSegments; i++) {
      final tTail = (tForward - i * 0.018);
      if (tTail < 0 || tTail > 1) continue;
      final tailTangent = metric.getTangentForOffset(length * tTail);
      if (tailTangent == null) continue;
      final tailAlpha = (1.0 - i / (tailSegments + 1)) * 0.55 * phaseAlpha;
      final tailPaint = Paint()
        ..color = glowColor.withValues(alpha: tailAlpha);
      canvas.drawCircle(tailTangent.position, 2.0 - i * 0.32, tailPaint);
    }
  }

  /// Fade-in on spawn, full alpha mid-life, fade-out near expiry. Smooth
  /// per-thread alpha so adding/removing threads never pops.
  double _phaseAlpha(DiscourseThread thread, DateTime now) {
    const fadeIn = Duration(milliseconds: 350);
    const fadeOut = Duration(milliseconds: 850);
    final ageSinceStart = now.difference(thread.startedAt);

    // Transient phases — fast fade-in, half-life mid, fade-out
    // tied to the thread's own lifetime constant. They don't share
    // the question/answer windows so encode their alpha curves
    // directly.
    if (thread.phase == DiscoursePhase.mention ||
        thread.phase == DiscoursePhase.returnPacket) {
      final lifetime = thread.phase == DiscoursePhase.mention
          ? kMentionLinger
          : kReturnPacketLifetime;
      final remaining = lifetime - ageSinceStart;
      if (remaining <= Duration.zero) return 0.0;
      const tFadeIn = Duration(milliseconds: 180);
      const tFadeOut = Duration(milliseconds: 380);
      if (ageSinceStart < tFadeIn) {
        return (ageSinceStart.inMilliseconds / tFadeIn.inMilliseconds)
            .clamp(0.0, 1.0);
      }
      if (remaining < tFadeOut) {
        return (remaining.inMilliseconds / tFadeOut.inMilliseconds)
            .clamp(0.0, 1.0);
      }
      return 1.0;
    }

    if (ageSinceStart < fadeIn) {
      return (ageSinceStart.inMilliseconds / fadeIn.inMilliseconds)
          .clamp(0.0, 1.0);
    }
    if (thread.phase == DiscoursePhase.answered && thread.answeredAt != null) {
      final ageSinceAnswered = now.difference(thread.answeredAt!);
      final remaining = kAnsweredLinger - ageSinceAnswered;
      if (remaining <= Duration.zero) return 0.0;
      if (remaining < fadeOut) {
        return (remaining.inMilliseconds / fadeOut.inMilliseconds)
            .clamp(0.0, 1.0);
      }
    } else {
      final remaining = kQuestionTimeout - ageSinceStart;
      if (remaining <= Duration.zero) return 0.0;
      if (remaining < fadeOut) {
        return (remaining.inMilliseconds / fadeOut.inMilliseconds)
            .clamp(0.0, 1.0);
      }
    }
    return 1.0;
  }

  /// Cubic bezier arcing outward from the chord midpoint so two agents
  /// don't draw their tether on top of straight orchestrator spokes.
  /// Bow size is proportional to chord length so distant pairs bow
  /// further; co-located pairs barely bow at all.
  Path _arcPath(Offset a, Offset b) {
    final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
    final dx = b.dx - a.dx;
    final dy = b.dy - a.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    final nx = -dy / len;
    final ny = dx / len;
    final bow = (len * 0.18).clamp(18.0, 80.0);
    // Bow toward the side facing the stage center inversely — choose
    // a deterministic side based on the chord direction so the same
    // pair always bows the same way and doesn't jitter on rebuilds.
    final sign = dx + dy >= 0 ? 1.0 : -1.0;
    final control = Offset(
      mid.dx + nx * bow * sign,
      mid.dy + ny * bow * sign,
    );
    final path = Path()..moveTo(a.dx, a.dy);
    // Two control points for a smoother sweep — both at the bow apex
    // so the curve hugs the apex rather than bulging only at the
    // midpoint.
    path.cubicTo(
      a.dx + (control.dx - a.dx) * 0.6,
      a.dy + (control.dy - a.dy) * 0.6,
      b.dx + (control.dx - b.dx) * 0.6,
      b.dy + (control.dy - b.dy) * 0.6,
      b.dx,
      b.dy,
    );
    return path;
  }

  /// Paint a dashed pattern along a single path-metric. [phaseOffset]
  /// shifts the dash pattern so it reads as flowing along the arc.
  void _drawDashedPath({
    required Canvas canvas,
    required ui.PathMetric metric,
    required Paint paint,
    required double dashLength,
    required double gapLength,
    required double phaseOffset,
  }) {
    final length = metric.length;
    var distance = -phaseOffset;
    while (distance < length) {
      final start = math.max(0.0, distance);
      final end = math.min(length, distance + dashLength);
      if (end > start) {
        final segment = metric.extractPath(start, end);
        canvas.drawPath(segment, paint);
      }
      distance += dashLength + gapLength;
    }
  }

  @override
  bool shouldRepaint(covariant _DiscoursePainter old) {
    return old.threads != threads ||
        old.pulse != pulse ||
        old.mutedAgentIds != mutedAgentIds;
  }
}
