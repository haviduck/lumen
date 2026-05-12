/// Council Activity Bubbles Layer
/// ===============================
///
/// Per-agent persistent activity card layered over the council stage.
/// REPLACES the previous chunk-streamed snippet bubble system. The
/// previous design treated speech bubbles like a chat transcript,
/// truncated raw chunks to 200 chars, and produced unreadable
/// snippets that fought with the agent card's own transcript well.
///
/// New model (2026-05 redesign):
///   * Every active agent gets ONE persistent activity card anchored
///     to its outward-facing card edge.
///   * The card narrates the agent's life in first-person, driven by
///     `agent.status`, the latest task ledger entry, and a transient
///     event-flash overlay that surfaces newsworthy transitions
///     (asking pool, pool replied, asked user, dispatched, done,
///     error, stalled, pinged).
///   * Streaming chunks ARE NOT shown verbatim. Instead, a typing
///     indicator (3 fading dots + STREAMING badge) lights up when
///     `agent_chunk` events arrive — the full streamed text lives in
///     the agent inspector (click the agent card).
///   * Errors are loud (red border, attention shake on first paint,
///     extended flash linger).
///   * Done bubbles linger ~9s and fade out so the user has a beat
///     to register completion before the card disappears.
///
/// Public surface preserved:
///   * [CouncilStageAnchors] — stage layout contract for other layers.
///   * [BubbleKind] — legacy enum kept so callers (manual spawn paths,
///     debug tooling) keep compiling. Mapped to [FlashKind] internally.
///   * [BubbleController.spawn] — manual spawn API; routed into the
///     activity layer as a custom flash for the target agent.
///
/// Z-order contract is unchanged:
///   1. Backdrop  2. Traffic mesh  3. Activity bubbles  4. Agent cards
///   5. Modal overlays.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_task_ledger.dart';
import '../../theme/app_colors.dart';
import 'speech/activity_bubble_card.dart';
import 'speech/activity_models.dart';

// ════════════════════════════════════════════════════════════════
// Stage anchors — unchanged from prior rev. Other layers (Drift's
// successor, Mesh, Pentest attack lines) read this contract.
// ════════════════════════════════════════════════════════════════

/// Anchor positions + layout contract for the council canvas.
class CouncilStageAnchors extends ChangeNotifier {
  final Map<String, Rect> _rects = {};
  Rect _safeZone = Rect.zero;
  Offset _ringCenter = Offset.zero;
  Size _ringRadii = Size.zero;

  Map<String, Rect> get agentRects => Map.unmodifiable(_rects);

  Rect? rectOf(String id) => _rects[id];

  Offset? topOf(String id) {
    final r = _rects[id];
    if (r == null) return null;
    return Offset(r.center.dx, r.top);
  }

  Offset? centerOf(String id) => _rects[id]?.center;

  Offset? outwardOf(String id) {
    final c = _rects[id]?.center;
    if (c == null) return null;
    final dx = c.dx - _ringCenter.dx;
    final dy = c.dy - _ringCenter.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.5) return const Offset(0, -1);
    return Offset(dx / len, dy / len);
  }

  Rect get safeZone => _safeZone;
  Offset get ringCenter => _ringCenter;
  Size get ringRadii => _ringRadii;

  void update(
    Map<String, Rect> rects, {
    Rect? safeZone,
    Offset? ringCenter,
    Size? ringRadii,
  }) {
    var changed = rects.length != _rects.length;
    if (!changed) {
      for (final entry in rects.entries) {
        final existing = _rects[entry.key];
        if (existing == null || existing != entry.value) {
          changed = true;
          break;
        }
      }
    }
    if (safeZone != null && safeZone != _safeZone) changed = true;
    if (ringCenter != null && ringCenter != _ringCenter) changed = true;
    if (ringRadii != null && ringRadii != _ringRadii) changed = true;
    if (!changed) return;
    _rects
      ..clear()
      ..addAll(rects);
    if (safeZone != null) _safeZone = safeZone;
    if (ringCenter != null) _ringCenter = ringCenter;
    if (ringRadii != null) _ringRadii = ringRadii;
    notifyListeners();
  }
}

// ════════════════════════════════════════════════════════════════
// Legacy manual-spawn API — preserved for callers that inject
// custom flashes (system announcements, debug tooling). Each spawn
// becomes a flash overlay on the targeted agent's bubble.
// ════════════════════════════════════════════════════════════════

enum BubbleKind {
  speak,
  askPool,
  askUser,
  poolReply,
  userReply,
  userPing,
  done,
  error,
}

class BubbleController extends ChangeNotifier {
  final List<_SpawnRequest> _pending = [];

  void spawn(
    String originId,
    String text, {
    String? replyTo,
    BubbleKind kind = BubbleKind.speak,
  }) {
    if (originId.isEmpty || text.trim().isEmpty) return;
    _pending.add(_SpawnRequest(originId: originId, text: text, kind: kind));
    notifyListeners();
  }

  /// Returns the queued spawn requests and clears the buffer. The
  /// return type is intentionally `List<dynamic>` so callers outside
  /// this library can treat each request as a tuple of `(originId,
  /// text, kind)` without depending on the private spawn record.
  /// In-library callers downcast.
  List<Object> drain() {
    if (_pending.isEmpty) return const [];
    final out = List<Object>.from(_pending);
    _pending.clear();
    return out;
  }
}

class _SpawnRequest {
  final String originId;
  final String text;
  final BubbleKind kind;
  _SpawnRequest({
    required this.originId,
    required this.text,
    required this.kind,
  });
}

FlashKind _legacyKindToFlash(BubbleKind k) {
  switch (k) {
    case BubbleKind.askPool:
      return FlashKind.askPool;
    case BubbleKind.askUser:
      return FlashKind.askUser;
    case BubbleKind.poolReply:
      return FlashKind.poolReply;
    case BubbleKind.userReply:
      return FlashKind.userReply;
    case BubbleKind.userPing:
      return FlashKind.userPing;
    case BubbleKind.done:
      return FlashKind.done;
    case BubbleKind.error:
      return FlashKind.error;
    case BubbleKind.speak:
      return FlashKind.dispatch;
  }
}

// ════════════════════════════════════════════════════════════════
// Layer widget.
// ════════════════════════════════════════════════════════════════

class CouncilSpeechBubblesLayer extends StatefulWidget {
  final CouncilSession session;
  final CouncilStageAnchors anchors;
  final bool evaluatorOnBlackboard;
  final BubbleController? controller;

  const CouncilSpeechBubblesLayer({
    super.key,
    required this.session,
    required this.anchors,
    this.evaluatorOnBlackboard = false,
    this.controller,
  });

  @override
  State<CouncilSpeechBubblesLayer> createState() =>
      _CouncilSpeechBubblesLayerState();
}

class _CouncilSpeechBubblesLayerState extends State<CouncilSpeechBubblesLayer>
    with TickerProviderStateMixin {
  /// One live state record per agent. Created lazily the first time
  /// an agent goes non-idle or receives a flash.
  final Map<String, AgentLiveState> _live = <String, AgentLiveState>{};

  /// Number of events already consumed from the session bus. We pull
  /// new events forward only — the layer never re-runs past events,
  /// to avoid replaying flashes after a hot-reload / widget rebind.
  int _processedEvents = 0;

  DateTime? _mountedAt;

  /// Shared breathing phase pumped to every bubble. One controller
  /// is cheaper than N per-card controllers when the ring scales up.
  late final AnimationController _breath;

  /// Frame tick used to evict expired flashes / advance the done
  /// linger window. We don't need a ticker per agent.
  late final Ticker _ticker;

  BubbleController? _injected;
  late BubbleController _controller;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _mountedAt = DateTime.now();
    _processedEvents = widget.session.events.length;
    _bindController(widget.controller);
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _ticker = createTicker(_onTick)..start();
  }

  void _bindController(BubbleController? injected) {
    _injected = injected;
    _controller = injected ?? BubbleController();
    _ownsController = injected == null;
    _controller.addListener(_drainController);
  }

  void _unbindController() {
    _controller.removeListener(_drainController);
    if (_ownsController) _controller.dispose();
  }

  @override
  void didUpdateWidget(covariant CouncilSpeechBubblesLayer old) {
    super.didUpdateWidget(old);
    if (widget.controller != _injected) {
      _unbindController();
      _bindController(widget.controller);
    }
    _processNewEvents();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _breath.dispose();
    _unbindController();
    super.dispose();
  }

  /// Frame loop. Responsibilities, all cheap:
  ///   1. Evict expired flashes so the primary line returns to the
  ///      composed status narration.
  ///   2. Detect streaming-holdover edge (chunk → idle) once so the
  ///      typing dots come down. We DON'T dirty every frame after
  ///      the holdover — the breath AnimatedBuilder is already
  ///      rebuilding the layer at frame rate while bubbles are
  ///      visible, so this is a one-shot edge trigger guarded by
  ///      `_streamingFlagged` per-agent.
  void _onTick(Duration _) {
    final now = DateTime.now();
    var dirty = false;
    for (final state in _live.values) {
      final f = state.flash;
      if (f != null && f.isExpired(now)) {
        state.flash = null;
        dirty = true;
      }
      if (state.lastChunkAt != null) {
        final past = now.difference(state.lastChunkAt!) > kStreamingHoldover;
        if (past && !_streamingExpiredFlagged.contains(state.agentId)) {
          _streamingExpiredFlagged.add(state.agentId);
          dirty = true;
        } else if (!past && _streamingExpiredFlagged.contains(state.agentId)) {
          _streamingExpiredFlagged.remove(state.agentId);
        }
      }
    }
    if (dirty && mounted) setState(() {});
  }

  /// Set of agent ids whose streaming-holdover lapse has already
  /// produced a repaint. Cleared when a new chunk arrives.
  final Set<String> _streamingExpiredFlagged = <String>{};

  void _drainController() {
    final pending = _controller.drain();
    if (pending.isEmpty) return;
    final now = DateTime.now();
    for (final raw in pending) {
      final r = raw as _SpawnRequest;
      _ensureLive(r.originId);
      final kind = _legacyKindToFlash(r.kind);
      _live[r.originId]!.flash = ActivityFlash(
        text: clampSnippet(r.text, kFlashSnippetMax),
        kind: kind,
        expiresAt: now.add(
          kFlashDurations[kind] ?? const Duration(seconds: 5),
        ),
      );
    }
    setState(() {});
  }

  void _processNewEvents() {
    final events = widget.session.events;
    if (events.length <= _processedEvents) return;
    final fresh = events.sublist(_processedEvents);
    _processedEvents = events.length;
    final mountedAt = _mountedAt;
    final now = DateTime.now();
    var dirty = false;
    for (final e in fresh) {
      if (mountedAt != null &&
          e.createdAt.isBefore(
            mountedAt.subtract(const Duration(seconds: 2)),
          )) {
        continue;
      }
      // Record streaming activity for the typing indicator.
      if (e.type == CouncilEventType.agentChunk && e.fromAgentId.isNotEmpty) {
        _ensureLive(e.fromAgentId);
        _live[e.fromAgentId]!.lastChunkAt = e.createdAt;
        _streamingExpiredFlagged.remove(e.fromAgentId);
        dirty = true;
      }
      // Record done / error pivot points.
      if (e.type == CouncilEventType.agentDone ||
          e.type == CouncilEventType.evaluatorDone) {
        _ensureLive(e.fromAgentId);
        _live[e.fromAgentId]!.doneAt = e.createdAt;
      }
      if (e.type == CouncilEventType.agentError ||
          e.type == CouncilEventType.agentStalled) {
        _ensureLive(e.fromAgentId);
        _live[e.fromAgentId]!.erroredAt = e.createdAt;
      }
      // Build a flash if the event maps to one.
      final targets = _flashTargetsFor(e);
      for (final id in targets) {
        final flash = flashForEvent(
          event: e,
          selfAgentId: id,
          now: now,
        );
        if (flash != null) {
          _ensureLive(id);
          _live[id]!.flash = flash;
          dirty = true;
        }
      }
    }
    if (dirty && mounted) setState(() {});
  }

  /// Which agents should receive a flash for a given event. Most
  /// events fire on a single agent (`fromAgentId`), but a few (e.g.
  /// dispatched) target the recipient too.
  Iterable<String> _flashTargetsFor(CouncilEvent e) sync* {
    if (e.fromAgentId.isNotEmpty) yield e.fromAgentId;
    if (e.toAgentId.isNotEmpty && e.toAgentId != e.fromAgentId) {
      yield e.toAgentId;
    }
  }

  void _ensureLive(String id) {
    final existing = _live[id];
    if (existing != null) {
      existing.firstActiveAt ??= DateTime.now();
      return;
    }
    _live[id] = AgentLiveState(agentId: id)..firstActiveAt = DateTime.now();
  }

  bool _isEvaluatorMuted(String agentId) {
    if (!widget.evaluatorOnBlackboard) return false;
    return agentId == widget.session.config.finalEvaluator.id;
  }

  /// Test hook — visible bubbles grouped by agent id. Replaces the
  /// legacy count map; the new layer renders at most one bubble per
  /// agent so the count is always 0 or 1.
  @visibleForTesting
  Map<String, int> debugBubbleCountsByAgent() {
    final now = DateTime.now();
    final out = <String, int>{};
    final cardRects = widget.anchors._rects;
    for (final entry in _live.entries) {
      if (!cardRects.containsKey(entry.key)) continue;
      if (_isEvaluatorMuted(entry.key)) continue;
      if (!_shouldRender(entry.key, entry.value, now)) continue;
      out[entry.key] = 1;
    }
    return out;
  }

  bool _shouldRender(String id, AgentLiveState state, DateTime now) {
    // Always render while an active flash is up.
    if (state.flash != null && !state.flash!.isExpired(now)) return true;
    final agent = widget.session.agentById(id);
    if (agent == null) return false;
    if (agent.status == CouncilAgentStatus.idle) {
      // Linger after done so users see the completion before fade.
      if (state.doneAt != null &&
          now.difference(state.doneAt!) < kDoneLinger) {
        return true;
      }
      return false;
    }
    // Any non-idle status = render.
    return true;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.anchors, _breath]),
      builder: (context, _) {
        final now = DateTime.now();
        final cardRects = widget.anchors._rects;
        final candidates = <String, _BubbleCandidate>{};
        for (final entry in _live.entries) {
          final id = entry.key;
          if (_isEvaluatorMuted(id)) continue;
          if (!cardRects.containsKey(id)) continue;
          if (!_shouldRender(id, entry.value, now)) continue;
          final agent = widget.session.agentById(id);
          if (agent == null) continue;
          final task = _latestTaskFor(id);
          final narration = narrateAgent(
            agent: agent,
            latestTask: task,
            live: entry.value,
            isOrchestrator: id == widget.session.config.orchestrator.id,
            now: now,
          );
          candidates[id] = _BubbleCandidate(
            agentId: id,
            agentLabel: _agentLabel(agent),
            cardRect: cardRects[id]!,
            narration: narration,
          );
        }

        // Run collision-aware placement.
        //
        // Order matters: place the orchestrator's bubble FIRST so peer
        // bubbles can treat it as a fixed exclusion zone. The conductor
        // owns a dedicated bubble slot above (or below) its card; peers
        // arc their bubbles outward from the boss's card.
        final orchestratorId = widget.session.config.orchestrator.id;
        final placements = <String, _Placement>{};
        final orchestratorCand = candidates[orchestratorId];
        if (orchestratorCand != null) {
          placements[orchestratorId] = _placeColumn(
            agentId: orchestratorId,
            cardRect: orchestratorCand.cardRect,
            allRects: cardRects,
            orchestratorId: orchestratorId,
            orchestratorBubble: null,
          );
        }
        final orchestratorBubble = placements[orchestratorId]?.rect;
        for (final cand in candidates.values) {
          if (cand.agentId == orchestratorId) continue;
          placements[cand.agentId] = _placeColumn(
            agentId: cand.agentId,
            cardRect: cand.cardRect,
            allRects: cardRects,
            orchestratorId: orchestratorId,
            orchestratorBubble: orchestratorBubble,
          );
        }

        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _LeaderLinesPainter(
                    cardRects: cardRects,
                    placements: placements,
                  ),
                ),
              ),
              for (final cand in candidates.values)
                if (placements[cand.agentId] != null)
                  _buildPositionedBubble(
                    cand: cand,
                    placement: placements[cand.agentId]!,
                  ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPositionedBubble({
    required _BubbleCandidate cand,
    required _Placement placement,
  }) {
    return Positioned(
      key: ValueKey('council-bubble-${cand.agentId}'),
      left: placement.rect.left,
      top: placement.rect.top,
      width: placement.rect.width,
      child: ActivityBubbleCard(
        key: ValueKey('activity-${cand.agentId}'),
        narration: cand.narration,
        agentLabel: cand.agentLabel,
        side: _toBubbleSide(placement.side),
        breathT: _breath.value,
      ),
    );
  }

  CouncilTask? _latestTaskFor(String agentId) {
    CouncilTask? latest;
    for (final t in widget.session.tasks) {
      if (t.agentId != agentId) continue;
      if (latest == null || t.updatedAt.isAfter(latest.updatedAt)) latest = t;
    }
    return latest;
  }

  String _agentLabel(CouncilAgent agent) {
    final name = agent.name.trim();
    if (name.isEmpty) {
      return agent.id == widget.session.config.orchestrator.id
          ? S.councilOrchestrator.toUpperCase()
          : '';
    }
    return name.toUpperCase();
  }

  // ── Placement (collision-aware column layout) ──────────────────
  //
  // The new layer renders at most one bubble per agent, so column
  // sizing is much simpler than the legacy stack-of-bubbles version.
  // We keep the side-preference + reflow + safe-zone clamp from the
  // old code so the bubble never overlaps a sibling card and the
  // "never touches a panel rect" invariant holds (10px min gap).

  _Placement _placeColumn({
    required String agentId,
    required Rect cardRect,
    required Map<String, Rect> allRects,
    required String orchestratorId,
    required Rect? orchestratorBubble,
  }) {
    final safe = widget.anchors.safeZone;
    final orchestratorRect = allRects[orchestratorId];

    // Conservative content estimate for collision; bubble paints at
    // intrinsic height.
    const estHeight = 130.0;

    // The orchestrator gets its own placement strategy: it's the
    // conductor, not a peer. Its bubble belongs in the dead-center
    // column above (or below) its card so it never competes with peer
    // bubbles for outward real estate. Peers then treat both the
    // orchestrator card AND its bubble as a hard exclusion zone.
    if (agentId == orchestratorId) {
      // Prefer above; fall back to below; only then sides (rare on a
      // sane ring layout).
      const order = <_Side>[
        _Side.above,
        _Side.below,
        _Side.right,
        _Side.left,
      ];
      for (final side in order) {
        final rect = _candidateRect(cardRect, side, _columnWidth, estHeight);
        if (!_safeContains(safe, rect)) continue;
        if (_collidesWithSiblings(
          rect,
          allRects,
          agentId,
          orchestratorId: orchestratorId,
        )) {
          continue;
        }
        return _Placement(rect: rect, side: side, reflowed: side != _Side.above);
      }
      // Hard fallback: above, clamped.
      var fallback =
          _candidateRect(cardRect, _Side.above, _columnWidth, estHeight);
      fallback = _clampToSafe(fallback, safe);
      return _Placement(rect: fallback, side: _Side.above, reflowed: true);
    }

    // Peer agents — outward is "away from the orchestrator card",
    // not "away from the ring center". Those are the same in a
    // symmetric ellipse, but the orchestrator-relative framing is
    // what the user actually reads on the stage ("the bubble points
    // AWAY from the boss"). It also handles non-ring layouts (pentest
    // formation, future custom shapes) without special-casing.
    final away = _awayFromOrchestrator(
      cardRect: cardRect,
      orchestratorRect: orchestratorRect,
      fallback: widget.anchors.outwardOf(agentId) ??
          _fallbackOutward(cardRect.center),
    );
    final absDx = away.dx.abs();
    final absDy = away.dy.abs();
    // Pick the DOMINANT axis as preferred. A near-equal split (e.g.
    // an agent at the 45° diagonal) prefers horizontal — bubbles are
    // wider than they are tall, so a left/right placement uses the
    // empty corner of the stage better than above/below.
    final _Side preferred;
    if (absDx >= absDy * 0.85) {
      preferred = away.dx >= 0 ? _Side.right : _Side.left;
    } else {
      preferred = away.dy >= 0 ? _Side.below : _Side.above;
    }

    // Side ordering after the preferred side: prefer the perpendicular
    // axis (so a right-side reflow goes above/below, NEVER straight
    // across to left where it'd cross the orchestrator). Only fall
    // back to the opposite of `preferred` if both perpendiculars fail.
    final perp = (preferred == _Side.right || preferred == _Side.left)
        ? <_Side>[_Side.above, _Side.below]
        : <_Side>[_Side.right, _Side.left];
    final opposite = _opposite(preferred);
    final order = <_Side>[preferred, ...perp, opposite];

    for (final side in order) {
      final rect = _candidateRect(cardRect, side, _columnWidth, estHeight);
      if (!_safeContains(safe, rect)) continue;
      if (_collidesWithSiblings(
        rect,
        allRects,
        agentId,
        orchestratorId: orchestratorId,
        extraExclusion: orchestratorBubble,
      )) {
        continue;
      }
      return _Placement(
        rect: rect,
        side: side,
        reflowed: side != preferred,
      );
    }

    // Fallback: preferred side, clamped, leader-line marker on.
    var fallback = _candidateRect(cardRect, preferred, _columnWidth, estHeight);
    fallback = _clampToSafe(fallback, safe);
    return _Placement(rect: fallback, side: preferred, reflowed: true);
  }

  Rect _clampToSafe(Rect r, Rect safe) {
    if (safe.isEmpty) return r;
    var l = r.left;
    var t = r.top;
    if (l < safe.left + 4) l = safe.left + 4;
    if (l + r.width > safe.right - 4) l = safe.right - 4 - r.width;
    if (t < safe.top + 4) t = safe.top + 4;
    if (t + r.height > safe.bottom - 4) t = safe.bottom - 4 - r.height;
    return Rect.fromLTWH(l, t, r.width, r.height);
  }

  Offset _awayFromOrchestrator({
    required Rect cardRect,
    required Rect? orchestratorRect,
    required Offset fallback,
  }) {
    if (orchestratorRect == null) return fallback;
    final dx = cardRect.center.dx - orchestratorRect.center.dx;
    final dy = cardRect.center.dy - orchestratorRect.center.dy;
    final len = math.sqrt(dx * dx + dy * dy);
    if (len < 0.5) return fallback;
    return Offset(dx / len, dy / len);
  }

  _Side _opposite(_Side s) {
    switch (s) {
      case _Side.right:
        return _Side.left;
      case _Side.left:
        return _Side.right;
      case _Side.above:
        return _Side.below;
      case _Side.below:
        return _Side.above;
    }
  }

  Rect _candidateRect(Rect card, _Side side, double w, double h) {
    switch (side) {
      case _Side.right:
        return Rect.fromLTWH(
            card.right + _kPanelGap, card.top, w, h);
      case _Side.left:
        return Rect.fromLTWH(
            card.left - _kPanelGap - w, card.top, w, h);
      case _Side.above:
        return Rect.fromLTWH(
            card.center.dx - w / 2, card.top - _kPanelGap - h, w, h);
      case _Side.below:
        return Rect.fromLTWH(
            card.center.dx - w / 2, card.bottom + _kPanelGap, w, h);
    }
  }

  bool _safeContains(Rect safe, Rect r) {
    if (safe.isEmpty) return true;
    return r.left >= safe.left - 0.5 &&
        r.right <= safe.right + 0.5 &&
        r.top >= safe.top - 0.5 &&
        r.bottom <= safe.bottom + 0.5;
  }

  bool _collidesWithSiblings(
    Rect candidate,
    Map<String, Rect> allRects,
    String selfId, {
    required String orchestratorId,
    Rect? extraExclusion,
  }) {
    for (final e in allRects.entries) {
      if (e.key == selfId) continue;
      // The orchestrator gets a wider clearance — its card carries the
      // most chrome and its bubble lives in the center column, so peer
      // bubbles need to keep their distance to stop "bubble on top of
      // conductor" overlap (the user's #2 complaint).
      final gap = e.key == orchestratorId
          ? _kOrchestratorClearance
          : _kPanelGap;
      final inflated = e.value.inflate(gap);
      if (candidate.overlaps(inflated)) return true;
    }
    if (extraExclusion != null &&
        candidate.overlaps(extraExclusion.inflate(_kPanelGap))) {
      return true;
    }
    return false;
  }

  Offset _fallbackOutward(Offset cardCenter) {
    final ringC = widget.anchors.ringCenter;
    final v = cardCenter - ringC;
    final len = v.distance;
    if (len < 1) return const Offset(0, -1);
    return Offset(v.dx / len, v.dy / len);
  }

  BubbleAnchorSide _toBubbleSide(_Side s) {
    switch (s) {
      case _Side.right:
        return BubbleAnchorSide.right;
      case _Side.left:
        return BubbleAnchorSide.left;
      case _Side.above:
        return BubbleAnchorSide.above;
      case _Side.below:
        return BubbleAnchorSide.below;
    }
  }
}

class _BubbleCandidate {
  final String agentId;
  final String agentLabel;
  final Rect cardRect;
  final AgentNarration narration;
  const _BubbleCandidate({
    required this.agentId,
    required this.agentLabel,
    required this.cardRect,
    required this.narration,
  });
}

// ════════════════════════════════════════════════════════════════
// Placement constants & types.
// ════════════════════════════════════════════════════════════════

const double _columnWidth = kActivityBubbleWidth;

/// Hard invariant: an activity bubble's bounding box must sit at
/// least this many logical pixels away from every agent card rect
/// (origin card included on its inside edge, all sibling cards
/// fully). 10px keeps bubbles "near the panel" without touching it.
const double _kPanelGap = 10.0;

/// Extra clearance reserved around the orchestrator card. The
/// conductor is in the visual middle of the stage and carries its
/// own bubble plus traffic spokes; peer bubbles need to stay further
/// away or they read as "overlapping the boss". 32px is the sweet
/// spot — close enough that the stage doesn't feel sparse, far
/// enough that a peer bubble never paints onto the orchestrator's
/// card chrome (border, halo, return-packet zone).
const double _kOrchestratorClearance = 32.0;

enum _Side { right, left, above, below }

class _Placement {
  final Rect rect;
  final _Side side;
  final bool reflowed;
  const _Placement({
    required this.rect,
    required this.side,
    required this.reflowed,
  });
}

/// Hairline connector from a panel edge to its bubble when the
/// bubble could not sit on its preferred side. The bubble's own
/// speech-bubble tail handles the preferred-side case (the
/// adjacency is obvious there). Reflowed cases need the extra
/// connector so the user reads the bubble↔panel association at a
/// glance even when the bubble is across the stage.
class _LeaderLinesPainter extends CustomPainter {
  final Map<String, Rect> cardRects;
  final Map<String, _Placement> placements;

  _LeaderLinesPainter({
    required this.cardRects,
    required this.placements,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (placements.isEmpty) return;
    final paint = Paint()
      ..color = DuckColors.fgMuted.withValues(alpha: 0.32)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke
      ..isAntiAlias = true;

    placements.forEach((agentId, p) {
      if (!p.reflowed) return;
      final card = cardRects[agentId];
      if (card == null) return;

      late final Offset from;
      late final Offset to;
      switch (p.side) {
        case _Side.right:
          from = Offset(card.right, card.center.dy);
          to = Offset(p.rect.left, p.rect.top + 18);
          break;
        case _Side.left:
          from = Offset(card.left, card.center.dy);
          to = Offset(p.rect.right, p.rect.top + 18);
          break;
        case _Side.above:
          from = Offset(card.center.dx, card.top);
          to = Offset(p.rect.center.dx, p.rect.bottom);
          break;
        case _Side.below:
          from = Offset(card.center.dx, card.bottom);
          to = Offset(p.rect.center.dx, p.rect.top);
          break;
      }
      canvas.drawLine(from, to, paint);
      final dot = Paint()
        ..color = DuckColors.fgMuted.withValues(alpha: 0.45)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(to, 1.6, dot);
    });
  }

  @override
  bool shouldRepaint(covariant _LeaderLinesPainter old) {
    return old.placements != placements || old.cardRects != cardRects;
  }
}
