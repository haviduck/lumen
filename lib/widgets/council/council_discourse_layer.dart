/// Council Discourse Layer — "Discourse Cinema"
/// ==============================================
///
/// Replaces the calm bezier arcs of the prior pool-exchange visualisation
/// with a tangible thought-object: a small floating pill carrying the
/// first few characters of the question / reply that physically travels
/// from one agent's voice panel to the other. The user reads the
/// (asker, responder) edge as a real conversation, not as ambient
/// network telemetry.
///
/// The widget is stateless — every visible pill, contrail dot, chewing
/// pulse and landing flash is derived from the session's events list
/// against wall-clock time. The layer rebuilds at ~60 Hz by riding the
/// stage's existing pulse controller (same pattern as the traffic
/// layer), which keeps the pill positions smooth without owning a
/// per-layer vsync.
///
/// Z-order:
///   * ABOVE the traffic layer (so conversation reads as a distinct
///     signal from orchestrator-broker dispatch packets).
///   * BELOW the agent cards (so a pill never paints over an agent's
///     voice panel — it LANDS at the panel's edge).
///
/// Events consumed (read-only — emits nothing):
///   * `askedPool`  — `fromAgentId` is the asker, `data.resolvedTargets`
///                    is the list of responder ids, `message` carries
///                    the raw question text. Spawns one scene per
///                    (asker, responder) pair.
///   * `poolReply`  — `fromAgentId` is the responder, `toAgentId` is
///                    the asker, `message` is the reply text. Matches
///                    the most recent unanswered scene for that pair.
///   * `agentDone`  — orchestrator return packet. One-shot pill (no
///                    text payload, check-mark icon) rides from the
///                    completed agent to the orchestrator card.
///
/// Per-pill timeline (~1.8s end-to-end for pool exchanges):
///
///                       [dwell]   [travel]                  [land]
///       source ▏███████▏░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░▏░░░░ destination
///              0ms      280ms                            ~1580ms  1800ms
///
///   * 0..dwell — pill sits at the source voice-panel edge, fully
///     visible. This pause exists ON PURPOSE so the user reads "ah,
///     that's the question" BEFORE the motion starts. Without the
///     pause the pill just whooshes by and the eye reads "packet",
///     not "thought".
///   * dwell..(dwell+travel) — pill rides a cubic bezier from source
///     edge to destination edge with `Curves.easeOutCubic`. A short
///     contrail of fading dots trails behind it on the path so the
///     eye reads MOVEMENT, not just an in-betweened tween.
///   * (dwell+travel)..(dwell+travel+land) — pill DOCKS at the
///     recipient's voice-panel edge. A soft accent burst (~24 px
///     radius) blooms at the destination and fades out so the recipient
///     panel "catches" the thought visibly.
///   * Final fade — pill fades to 0 over the last ~200 ms so it
///     doesn't snap out.
///
/// While a question is in flight but not yet answered, the recipient
/// gets a quiet "chewing" pulse: two small dots near their voice panel
/// edge breathing on the global pulse, so the user reads "they're
/// thinking about it" between landing and reply.
///
/// Performance:
///   * Hard cap of [kMaxActivePills] simultaneous pills — older scenes
///     are dropped so a busy run can never burn through the paint
///     budget.
///   * The painter receives a single `Listenable.merge` for repaint
///     triggers (the stage pulse + anchors).
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_speech_bubbles.dart';

// ════════════════════════════════════════════════════════════════════
// Timing constants
// ════════════════════════════════════════════════════════════════════

/// How long the pill rests at its source edge before traveling. The
/// pause is load-bearing — without it the pill flashes by too fast for
/// the user to read the text and the scene loses its narrative.
const Duration kPillDwell = Duration(milliseconds: 280);

/// Cubic-eased travel along the bezier from source edge to destination
/// edge.
const Duration kPillTravel = Duration(milliseconds: 1300);

/// Landing flash radius / fade-out window at the destination.
const Duration kPillLanding = Duration(milliseconds: 220);

/// Final pill-only fade after the landing flash, so the chip doesn't
/// snap to invisible.
const Duration kPillFadeOut = Duration(milliseconds: 200);

/// Composite total — pill is alive from the spawning event for this
/// duration. Mirrors the brief: "DOCKS to the recipient's voice panel,
/// brief landing flash, then the pill fades out."
const Duration kPillTotal = Duration(
  milliseconds: 280 + 1300 + 220 + 200, // 2000 ms
);

/// How long the recipient's "chewing" pulse keeps breathing while a
/// pool question is in flight but unanswered. Capped so a stuck pool
/// reply doesn't paint forever.
const Duration kChewingTimeout = Duration(seconds: 45);

/// How long an answered scene lingers on stage AFTER its reply pill
/// finishes. Picked short — once both pills have docked, the eye has
/// already seen the conversation; longer linger just clutters busy
/// runs.
const Duration kAnsweredLinger = Duration(seconds: 6);

/// Return packet (agentDone → orchestrator) lifetime — single one-shot
/// ride, same vocabulary as a pool pill.
const Duration kReturnPacketLifetime = Duration(milliseconds: 1800);

/// Hard cap on simultaneously-animating pills. When more scenes are
/// queued, oldest get dropped so the paint budget is bounded even when
/// a busy pool exchange fires several questions at once.
const int kMaxActivePills = 6;

/// Legacy alias kept for tests / callers that imported the old
/// `kQuestionTimeout` from this library. Maps to [kChewingTimeout].
const Duration kQuestionTimeout = kChewingTimeout;

// ════════════════════════════════════════════════════════════════════
// Scene model — derived from events, kept private to this layer
// ════════════════════════════════════════════════════════════════════

enum _SceneKind {
  /// Pool question asker → responder. Purple, carries question text.
  question,

  /// Pool reply responder → asker. Mint, carries reply text.
  reply,

  /// Agent done → orchestrator. Cyan, no text payload (check-mark icon).
  returnPacket,
}

/// One traveling pill scene. Each (asker, responder) pool exchange
/// produces one [_SceneKind.question] scene and (if the reply
/// arrives in time) one matching [_SceneKind.reply] scene.
class _Scene {
  final _SceneKind kind;
  final String fromId;
  final String toId;
  final String text;
  final DateTime startedAt;

  _Scene({
    required this.kind,
    required this.fromId,
    required this.toId,
    required this.text,
    required this.startedAt,
  });
}

/// Recipient-side "chewing" pulse — fires while a question is in
/// flight but not yet answered. Cleared when the matching reply lands
/// or the question times out.
class _ChewingPulse {
  final String responderId;
  final DateTime questionLandedAt;
  _ChewingPulse({required this.responderId, required this.questionLandedAt});
}

// ════════════════════════════════════════════════════════════════════
// Widget
// ════════════════════════════════════════════════════════════════════

class CouncilDiscourseLayer extends StatelessWidget {
  final List<CouncilEvent> events;
  final Animation<double> pulse;
  final CouncilStageAnchors anchors;
  final Set<String> mutedAgentIds;

  /// Agent id of the orchestrator. Used as the terminus for return
  /// packets so completed agents visibly ack back to the conductor.
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
          final now = DateTime.now();
          final derived = _derive(now);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              // Contrails + landing flashes — painted UNDER the pill
              // widgets so the burst halos the pill on arrival.
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _DiscourseFxPainter(
                      scenes: derived.scenes,
                      chewing: derived.chewing,
                      anchors: anchors,
                      pulse: pulse.value,
                      now: now,
                      repaint: Listenable.merge([pulse, anchors]),
                    ),
                  ),
                ),
              ),
              for (final scene in derived.scenes)
                _ScenePill(
                  key: ValueKey(
                    'pill-${scene.kind.name}-${scene.fromId}-${scene.toId}-'
                    '${scene.startedAt.microsecondsSinceEpoch}',
                  ),
                  scene: scene,
                  anchors: anchors,
                  now: now,
                ),
            ],
          );
        },
      ),
    );
  }

  // ── Derivation ────────────────────────────────────────────────────

  _DiscourseSnapshot _derive(DateTime now) {
    // First pass: collect every (asker, responder) question scene
    // walking events in chronological order. Each `askedPool` event
    // creates N scenes (one per resolved target). Later `poolReply`
    // events match the OLDEST unmatched scene for that pair.
    final scenes = <_Scene>[];
    final pendingByPair = <String, List<int>>{};
    final pendingReturnPackets = <_Scene>[];

    String key(String a, String r) => '$a->$r';

    for (final event in events) {
      final age = now.difference(event.createdAt);
      // Outside any relevant window — skip.
      if (age > kChewingTimeout &&
          age > kAnsweredLinger &&
          age > kReturnPacketLifetime &&
          age > kPillTotal) {
        continue;
      }

      switch (event.type) {
        case CouncilEventType.askedPool:
          final asker = event.fromAgentId;
          if (asker.isEmpty) continue;
          if (mutedAgentIds.contains(asker)) continue;
          final resolved = (event.data['resolvedTargets'] as List?) ?? const [];
          for (final raw in resolved) {
            if (raw is! String || raw.isEmpty) continue;
            if (raw == asker) continue;
            if (mutedAgentIds.contains(raw)) continue;
            scenes.add(
              _Scene(
                kind: _SceneKind.question,
                fromId: asker,
                toId: raw,
                text: _trim(event.message),
                startedAt: event.createdAt,
              ),
            );
            pendingByPair.putIfAbsent(key(asker, raw), () => []).add(
                  scenes.length - 1,
                );
          }
        case CouncilEventType.poolReply:
          final responder = event.fromAgentId;
          final asker = event.toAgentId;
          if (responder.isEmpty || asker.isEmpty) continue;
          if (mutedAgentIds.contains(responder)) continue;
          if (mutedAgentIds.contains(asker)) continue;
          // Pop the oldest unmatched question scene for this pair so
          // a second question fired before the first answered doesn't
          // grab a reply meant for the second.
          pendingByPair[key(asker, responder)]?.removeAt(0);
          scenes.add(
            _Scene(
              kind: _SceneKind.reply,
              fromId: responder,
              toId: asker,
              text: _trim(event.message),
              startedAt: event.createdAt,
            ),
          );
        case CouncilEventType.agentDone:
          // Return packet — one-shot from the completed agent back to
          // the orchestrator. Skipped when no orchestrator id was
          // supplied (e.g. test scenarios) and when the done agent IS
          // the orchestrator.
          if (orchestratorId.isEmpty) continue;
          final from = event.fromAgentId;
          if (from.isEmpty || from == orchestratorId) continue;
          if (mutedAgentIds.contains(from)) continue;
          if (age > kReturnPacketLifetime) continue;
          pendingReturnPackets.add(
            _Scene(
              kind: _SceneKind.returnPacket,
              fromId: from,
              toId: orchestratorId,
              text: '',
              startedAt: event.createdAt,
            ),
          );
      }
    }

    // ── Chewing pulses — derive from the pending question list.
    // For every pair that still has an unmatched question scene, if
    // the question's travel has finished but no reply has landed, emit
    // a chewing pulse on the responder until either timeout or reply.
    final chewing = <_ChewingPulse>[];
    for (final entry in pendingByPair.entries) {
      if (entry.value.isEmpty) continue;
      // Oldest unmatched question scene index for this pair.
      final sceneIdx = entry.value.first;
      final scene = scenes[sceneIdx];
      final ageSinceQ = now.difference(scene.startedAt);
      // Don't start chewing until the pill has finished traveling.
      final travelStartTotal = kPillDwell + kPillTravel;
      if (ageSinceQ < travelStartTotal) continue;
      if (ageSinceQ > kChewingTimeout) continue;
      chewing.add(
        _ChewingPulse(
          responderId: scene.toId,
          questionLandedAt: scene.startedAt.add(travelStartTotal),
        ),
      );
    }

    // ── Filter to scenes currently in flight or recently landed.
    final filtered = <_Scene>[];
    for (final s in scenes) {
      final age = now.difference(s.startedAt);
      // Pool pills: visible for kPillTotal, after that just gone.
      if (age > kPillTotal) continue;
      filtered.add(s);
    }
    for (final s in pendingReturnPackets) {
      final age = now.difference(s.startedAt);
      if (age > kReturnPacketLifetime) continue;
      filtered.add(s);
    }

    // ── Cap to kMaxActivePills, dropping the OLDEST so the freshest
    // exchanges always get airtime.
    filtered.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    final capped =
        filtered.length > kMaxActivePills
            ? filtered.sublist(0, kMaxActivePills)
            : filtered;

    return _DiscourseSnapshot(scenes: capped, chewing: chewing);
  }

  static String _trim(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return '';
    // Collapse internal whitespace so the pill renders one clean line.
    final flat = s.replaceAll(RegExp(r'\s+'), ' ');
    if (flat.length <= 40) return flat;
    return '${flat.substring(0, 39).trimRight()}\u2026';
  }
}

class _DiscourseSnapshot {
  final List<_Scene> scenes;
  final List<_ChewingPulse> chewing;
  _DiscourseSnapshot({required this.scenes, required this.chewing});
}

// ════════════════════════════════════════════════════════════════════
// Pill widget
// ════════════════════════════════════════════════════════════════════

class _ScenePill extends StatelessWidget {
  final _Scene scene;
  final CouncilStageAnchors anchors;
  final DateTime now;

  const _ScenePill({
    super.key,
    required this.scene,
    required this.anchors,
    required this.now,
  });

  @override
  Widget build(BuildContext context) {
    final fromRect = anchors.rectOf(scene.fromId);
    final toRect = anchors.rectOf(scene.toId);
    if (fromRect == null || toRect == null) return const SizedBox.shrink();

    final source = _edgePointTowards(fromRect, toRect.center);
    final dest = _edgePointTowards(toRect, fromRect.center);
    if ((source - dest).distance < 4) return const SizedBox.shrink();

    final age = now.difference(scene.startedAt);
    final progress = _progressFor(scene, age);
    if (progress == null) return const SizedBox.shrink();

    final pos = _positionOnArc(source, dest, progress.t);
    final accent = _accentForKind(scene.kind);
    final icon = _iconForKind(scene.kind);

    final pillWidth = scene.text.isEmpty ? 32.0 : _estimatePillWidth(scene.text);
    const pillHeight = 22.0;

    return Positioned(
      left: pos.dx - pillWidth / 2,
      top: pos.dy - pillHeight / 2,
      width: pillWidth,
      height: pillHeight,
      child: Opacity(
        opacity: progress.opacity,
        child: Transform.scale(
          scale: progress.scale,
          child: _PillChrome(
            accent: accent,
            icon: icon,
            text: scene.text,
          ),
        ),
      ),
    );
  }

  /// Pill width estimate: padding + icon + gap + text width.
  /// Tunes the pill so a 40-character text caps cleanly within the
  /// pool exchange brief's "120-180 px" target band.
  double _estimatePillWidth(String text) {
    const padding = 10.0 * 2;
    const iconWidth = 12.0;
    const gap = 5.0;
    // ~5.6 px per character at 10.5 px font / w500 letter-spacing 0.2.
    final textWidth = text.length * 5.6;
    final raw = padding + iconWidth + gap + textWidth;
    return raw.clamp(56.0, 200.0);
  }

  Color _accentForKind(_SceneKind kind) {
    switch (kind) {
      case _SceneKind.question:
        return DuckColors.accentPurple;
      case _SceneKind.reply:
        return DuckColors.accentMint;
      case _SceneKind.returnPacket:
        return DuckColors.accentCyan;
    }
  }

  IconData _iconForKind(_SceneKind kind) {
    switch (kind) {
      case _SceneKind.question:
        return Icons.forum_outlined;
      case _SceneKind.reply:
        return Icons.reply_outlined;
      case _SceneKind.returnPacket:
        return Icons.check_rounded;
    }
  }
}

/// Phase-aware progress descriptor for a single pill at "now".
class _PillProgress {
  /// Parametric t along the bezier (0..1). Held at 0 during dwell, at
  /// 1 during landing + fade.
  final double t;

  /// Opacity (0..1). Includes fade-in on spawn and fade-out at the
  /// tail of the scene lifetime.
  final double opacity;

  /// Scale factor — a tiny "settle" pop on arrival (1.05 → 1.0) reads
  /// as "thought lands", same vocabulary as the voice panel's flash
  /// sweep.
  final double scale;

  _PillProgress({required this.t, required this.opacity, required this.scale});
}

_PillProgress? _progressFor(_Scene scene, Duration age) {
  if (age < Duration.zero) return null;

  // Return packets have their own envelope — single forward sweep.
  if (scene.kind == _SceneKind.returnPacket) {
    final ms = age.inMilliseconds.toDouble();
    final life = kReturnPacketLifetime.inMilliseconds.toDouble();
    if (ms >= life) return null;
    final raw = (ms / life).clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(raw);
    final opacity = ms < 180
        ? (ms / 180).clamp(0.0, 1.0)
        : (life - ms < 380 ? ((life - ms) / 380).clamp(0.0, 1.0) : 1.0);
    return _PillProgress(t: eased, opacity: opacity, scale: 1.0);
  }

  final dwellMs = kPillDwell.inMilliseconds;
  final travelMs = kPillTravel.inMilliseconds;
  final landMs = kPillLanding.inMilliseconds;
  final fadeMs = kPillFadeOut.inMilliseconds;
  final totalMs = dwellMs + travelMs + landMs + fadeMs;
  final ms = age.inMilliseconds;
  if (ms >= totalMs) return null;

  double t;
  double opacity;
  double scale;

  if (ms < dwellMs) {
    // Dwell — pinned at source, full opacity ramping in over the
    // first 160 ms so a freshly-spawned pill doesn't pop in hard.
    t = 0;
    opacity = (ms / 160).clamp(0.0, 1.0);
    scale = 1.0;
  } else if (ms < dwellMs + travelMs) {
    // Travel — cubic ease-out along the arc.
    final localT = ((ms - dwellMs) / travelMs).clamp(0.0, 1.0);
    t = Curves.easeOutCubic.transform(localT);
    opacity = 1.0;
    scale = 1.0;
  } else if (ms < dwellMs + travelMs + landMs) {
    // Landing — at the destination edge, briefly bumped up to 1.05
    // scale then easing back to 1.0 over 220ms.
    final localT = ((ms - dwellMs - travelMs) / landMs).clamp(0.0, 1.0);
    t = 1.0;
    opacity = 1.0;
    scale = 1.0 + 0.05 * (1.0 - Curves.easeOutCubic.transform(localT));
  } else {
    // Fade out — held at destination, opacity fading to zero.
    final localT =
        ((ms - dwellMs - travelMs - landMs) / fadeMs).clamp(0.0, 1.0);
    t = 1.0;
    opacity = (1.0 - localT).clamp(0.0, 1.0);
    scale = 1.0;
  }

  return _PillProgress(t: t, opacity: opacity, scale: scale);
}

class _PillChrome extends StatelessWidget {
  const _PillChrome({
    required this.accent,
    required this.icon,
    required this.text,
  });

  final Color accent;
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final hasText = text.isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        // bgChip is fully opaque so the pill always reads against the
        // stage backdrop, even when the bezier crosses a busy traffic
        // edge or another pill's contrail.
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: accent.withValues(alpha: 0.85),
          width: 0.7,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.28),
            blurRadius: 9,
            spreadRadius: 0.2,
          ),
          const BoxShadow(
            color: Color(0x66000000),
            blurRadius: 4,
            offset: Offset(0, 1),
          ),
        ],
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: hasText ? 10 : 8,
          vertical: 4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: accent),
            if (hasText) ...[
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  text,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontSize: 10.5,
                    height: 1.1,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
// Painter for contrails, chewing pulses, and landing flashes
// ════════════════════════════════════════════════════════════════════

class _DiscourseFxPainter extends CustomPainter {
  _DiscourseFxPainter({
    required this.scenes,
    required this.chewing,
    required this.anchors,
    required this.pulse,
    required this.now,
    required Listenable repaint,
  }) : super(repaint: repaint);

  final List<_Scene> scenes;
  final List<_ChewingPulse> chewing;
  final CouncilStageAnchors anchors;
  final double pulse;
  final DateTime now;

  @override
  void paint(Canvas canvas, Size size) {
    if (scenes.isEmpty && chewing.isEmpty) return;

    for (final scene in scenes) {
      _paintScene(canvas, scene);
    }
    for (final c in chewing) {
      _paintChewing(canvas, c);
    }
  }

  void _paintScene(Canvas canvas, _Scene scene) {
    final fromRect = anchors.rectOf(scene.fromId);
    final toRect = anchors.rectOf(scene.toId);
    if (fromRect == null || toRect == null) return;

    final source = _edgePointTowards(fromRect, toRect.center);
    final dest = _edgePointTowards(toRect, fromRect.center);
    if ((source - dest).distance < 4) return;

    final age = now.difference(scene.startedAt);
    final progress = _progressFor(scene, age);
    if (progress == null) return;

    final accent = _accentFor(scene.kind);
    final t = progress.t;

    // Contrail dots — 4 fading dots trailing behind the head, only
    // while the pill is actively moving (skip during dwell + landing
    // + fade so it doesn't trail a stationary pill).
    final dwellMs = kPillDwell.inMilliseconds;
    final travelMs = kPillTravel.inMilliseconds;
    final inTravel = age.inMilliseconds >= dwellMs &&
        age.inMilliseconds < dwellMs + travelMs;
    if (inTravel) {
      _paintContrail(canvas, source, dest, t, accent);
    }

    // Landing flash — fires during the landing window, fading out.
    final landStartMs = dwellMs + travelMs;
    final landMs = kPillLanding.inMilliseconds;
    if (age.inMilliseconds >= landStartMs &&
        age.inMilliseconds < landStartMs + landMs) {
      final flashT = ((age.inMilliseconds - landStartMs) / landMs)
          .clamp(0.0, 1.0);
      _paintLandingFlash(canvas, dest, accent, flashT);
    }
  }

  void _paintContrail(
    Canvas canvas,
    Offset source,
    Offset dest,
    double t,
    Color accent,
  ) {
    // Build the path once and sample the trailing positions from the
    // path metrics so the contrail hugs the same bezier the pill rides.
    final path = _arcPath(source, dest);
    final metric = path.computeMetrics().first;
    final length = metric.length;

    const tailSegments = 4;
    for (var i = 1; i <= tailSegments; i++) {
      final tTail = t - i * 0.045;
      if (tTail < 0) continue;
      final tangent = metric.getTangentForOffset(length * tTail);
      if (tangent == null) continue;
      final alpha = 0.45 - i * 0.085;
      final radius = 1.6 - i * 0.2;
      if (alpha <= 0 || radius <= 0) continue;
      final paint = Paint()..color = accent.withValues(alpha: alpha);
      canvas.drawCircle(tangent.position, radius, paint);
    }

    // Subtle halo halo on the head position too — gives the pill's
    // accent border a slight luminous lift while it's still riding.
    final headTangent = metric.getTangentForOffset(length * t);
    if (headTangent != null) {
      final haloPaint = Paint()
        ..color = accent.withValues(alpha: 0.18)
        ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 8);
      canvas.drawCircle(headTangent.position, 12, haloPaint);
    }
  }

  void _paintLandingFlash(
    Canvas canvas,
    Offset dest,
    Color accent,
    double t,
  ) {
    // 24-px radius burst that fades to zero alpha over the landing
    // window. The brief asks for "soft accent burst, 220 ms ease-out
    // fade" — easing here is a (1 - t) drop with a small inward
    // bloom so the eye reads "catch" not "explode".
    final eased = 1.0 - Curves.easeOutCubic.transform(t);
    final radius = 12.0 + 12.0 * Curves.easeOutCubic.transform(t);
    final ringPaint = Paint()
      ..color = accent.withValues(alpha: 0.42 * eased)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 3);
    canvas.drawCircle(dest, radius, ringPaint);

    final corePaint = Paint()
      ..color = accent.withValues(alpha: 0.30 * eased)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 10);
    canvas.drawCircle(dest, 14, corePaint);
  }

  void _paintChewing(Canvas canvas, _ChewingPulse c) {
    final rect = anchors.rectOf(c.responderId);
    if (rect == null) return;
    // Anchor the dots near the bottom-leading edge of the recipient's
    // voice panel — same band the voice panel renders its eyebrow on
    // so the dots read as "still attached to this agent."
    final anchor = Offset(rect.center.dx, rect.top + rect.height * 0.18);
    // Pulse alpha breath — same global controller as the stage.
    final breath = (math.sin(pulse * math.pi * 2) + 1) * 0.5;
    for (var i = 0; i < 2; i++) {
      final phase = (pulse + i * 0.18) % 1.0;
      final localBreath = (math.sin(phase * math.pi * 2) + 1) * 0.5;
      final alpha = 0.20 + 0.45 * localBreath;
      final dx = (i - 0.5) * 6;
      final paint = Paint()
        ..color = DuckColors.accentPurple.withValues(alpha: alpha);
      canvas.drawCircle(Offset(anchor.dx + dx, anchor.dy), 1.6, paint);
    }
    // Soft halo unifies the two dots as one signal.
    final haloPaint = Paint()
      ..color = DuckColors.accentPurple.withValues(alpha: 0.10 + 0.12 * breath)
      ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 6);
    canvas.drawCircle(anchor, 9, haloPaint);
  }

  Color _accentFor(_SceneKind kind) {
    switch (kind) {
      case _SceneKind.question:
        return DuckColors.accentPurple;
      case _SceneKind.reply:
        return DuckColors.accentMint;
      case _SceneKind.returnPacket:
        return DuckColors.accentCyan;
    }
  }

  @override
  bool shouldRepaint(covariant _DiscourseFxPainter old) {
    return old.scenes != scenes ||
        old.chewing != chewing ||
        old.pulse != pulse ||
        old.now != now;
  }
}

// ════════════════════════════════════════════════════════════════════
// Geometry helpers (shared by pill widget + painter)
// ════════════════════════════════════════════════════════════════════

/// Ray-cast from the rect's center toward [toward], intersect the
/// rect's bounding edge. Used to anchor pills + flashes on the voice
/// panel edge facing the other agent, NOT the panel's center.
Offset _edgePointTowards(Rect from, Offset toward) {
  final c = from.center;
  final dx = toward.dx - c.dx;
  final dy = toward.dy - c.dy;
  if (dx == 0 && dy == 0) return c;
  final hx = from.width / 2;
  final hy = from.height / 2;
  final tx = dx == 0 ? double.infinity : hx / dx.abs();
  final ty = dy == 0 ? double.infinity : hy / dy.abs();
  final t = math.min(tx, ty);
  // Pad outward by a small margin so the pill sits a few pixels off
  // the voice-panel edge instead of clipping into it.
  const margin = 4.0;
  final scale = t + (margin / math.sqrt(dx * dx + dy * dy));
  return Offset(c.dx + dx * scale, c.dy + dy * scale);
}

/// Sample a cubic bezier arc between source and dest at parametric
/// position [t] (0..1). Uses the same arc geometry as the painter so
/// pill widget positions line up with the contrail dots.
Offset _positionOnArc(Offset source, Offset dest, double t) {
  final path = _arcPath(source, dest);
  final metric = path.computeMetrics().first;
  final tangent = metric.getTangentForOffset(metric.length * t.clamp(0.0, 1.0));
  return tangent?.position ?? source;
}

/// Cubic bezier arcing outward from the chord midpoint so two agents
/// don't draw their tether on top of the straight orchestrator spokes.
/// Bow size is proportional to chord length so distant pairs bow
/// further; co-located pairs barely bow at all. Side is deterministic
/// from the chord direction so the same pair always bows the same way
/// and doesn't jitter on rebuilds.
Path _arcPath(Offset a, Offset b) {
  final mid = Offset((a.dx + b.dx) / 2, (a.dy + b.dy) / 2);
  final dx = b.dx - a.dx;
  final dy = b.dy - a.dy;
  final len = math.sqrt(dx * dx + dy * dy);
  if (len < 1) {
    return Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(b.dx, b.dy);
  }
  final nx = -dy / len;
  final ny = dx / len;
  final bow = (len * 0.18).clamp(18.0, 80.0);
  final sign = dx + dy >= 0 ? 1.0 : -1.0;
  final control = Offset(
    mid.dx + nx * bow * sign,
    mid.dy + ny * bow * sign,
  );
  final path = Path()..moveTo(a.dx, a.dy);
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
