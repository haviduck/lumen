import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// Anchor positions + layout contract for the council canvas.
///
/// PUBLISHED CONTRACT (Stage Director → Drift, Mesh):
///   * [rectOf]      — card rect for an agent id, stage-local coords.
///   * [centerOf]    — card centroid for an agent id.
///   * [topOf]       — top-edge midpoint of a card (legacy bubble anchor).
///   * [outwardOf]   — unit vector pointing from stage center toward the
///                     card centre. Drift uses this so bubbles drift
///                     OUTWARD past the ring instead of stacking upward
///                     into the header safe zone.
///   * [safeZone]    — the rect inside which any UI may paint without
///                     colliding with the header / footer chrome. Bubble
///                     drift, traffic glow extents and any spawn FX must
///                     clip to this rect.
///   * [ringCenter]  — orchestrator focal point.
///   * [ringRadii]   — Size(rx, ry) of the ellipse the agents sit on.
///                     Mesh paints chords inside this; Drift can use it
///                     to scale travel distance.
///
/// Z-ORDER CONTRACT (bottom → top):
///   1. CouncilDiagonalBackdrop  (atmosphere, owns its own RepaintBoundary)
///   2. CouncilTrafficLayer      (always-on ambient mesh + comms pulses)
///   3. CouncilSpeechBubblesLayer (Drift — bubbles below cards, above mesh)
///   4. Agent cards              (orchestrator + sectors)
///   5. Modal overlays           (ping panel, user prompt, scrim)
class CouncilStageAnchors extends ChangeNotifier {
  final Map<String, Rect> _rects = {};
  Rect _safeZone = Rect.zero;
  Offset _ringCenter = Offset.zero;
  Size _ringRadii = Size.zero;

  /// Unmodifiable snapshot of all registered agent rects (id -> bounding box).
  /// Used by the pentest attack-lines painter to locate agent origins.
  Map<String, Rect> get agentRects => Map.unmodifiable(_rects);

  Rect? rectOf(String id) => _rects[id];
  Offset? topOf(String id) {
    final r = _rects[id];
    if (r == null) return null;
    return Offset(r.center.dx, r.top);
  }

  Offset? centerOf(String id) => _rects[id]?.center;

  /// Unit vector from the ring centre toward the agent's card centre.
  /// Drift consumes this for outward bubble drift.
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

/// Semantic kind drives the eyebrow label / leading-rule accent only.
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

/// Public spawn API for the orchestrator. The layer also auto-feeds
/// itself from CouncilSession.events; this controller is a side-channel
/// for callers that want to inject a bubble manually (e.g. system
/// announcements, debug tooling).
class BubbleController extends ChangeNotifier {
  final List<_SpawnRequest> _pending = [];

  /// Push a new bubble request. The layer drains on its next frame.
  void spawn(
    String originId,
    String text, {
    String? replyTo,
    BubbleKind kind = BubbleKind.speak,
  }) {
    if (originId.isEmpty || text.trim().isEmpty) return;
    _pending.add(_SpawnRequest(
      originId: originId,
      text: text,
      replyTo: replyTo,
      kind: kind,
    ));
    notifyListeners();
  }

  List<_SpawnRequest> drain() {
    if (_pending.isEmpty) return const [];
    final out = List<_SpawnRequest>.from(_pending);
    _pending.clear();
    return out;
  }
}

class _SpawnRequest {
  final String originId;
  final String text;
  final String? replyTo;
  final BubbleKind kind;
  _SpawnRequest({
    required this.originId,
    required this.text,
    required this.replyTo,
    required this.kind,
  });
}

class _Bubble {
  final int id;
  final String originId;
  final String? replyTo;
  final String text;
  final BubbleKind kind;
  final int spawnedAtMs;
  final int lifeMs;
  final int zoomMs;
  final int trailMs;
  final int fadeInMs;
  final int fadeOutMs;
  // Outward unit vector captured at spawn (origin → away from ring).
  Offset driftDir;
  // Origin rect captured at spawn time so layout reflows mid-life
  // don't yank the start point.
  final Rect originRect;

  _Bubble({
    required this.id,
    required this.originId,
    required this.replyTo,
    required this.text,
    required this.kind,
    required this.spawnedAtMs,
    required this.lifeMs,
    required this.zoomMs,
    required this.trailMs,
    required this.fadeInMs,
    required this.fadeOutMs,
    required this.driftDir,
    required this.originRect,
  });

  bool get isReply => replyTo != null && replyTo!.isNotEmpty;
}

/// Drift-outward speech bubble layer.
///
/// Behaviour summary (full spec at the top of this file):
///   * Spawns on the OUTWARD edge of the origin card and drifts radially
///     past the ring. ease-out drift, ease-in fade.
///   * Lifetime ≈ clamp(2.5s + 60ms × chars, 4s, 10s).
///   * Overlap with any non-origin / non-target card dips opacity to
///     ~0.22 ("passing under" feel). The parent Stack already paints
///     this layer below the cards, so cards stay legible.
///   * Reply choreography (replyTo set): zoom → trail → drift outward.
///   * Single Ticker drives every bubble; reply trailing re-samples the
///     target anchor every tick so it sticks during layout reflows.
///   * Reduced motion: appears at outward edge, holds, fades.
class CouncilSpeechBubblesLayer extends StatefulWidget {
  final CouncilSession session;
  final CouncilStageAnchors anchors;

  /// When true, evaluator chunks/done are suppressed (its surface is on
  /// the LeftBlackboard).
  final bool evaluatorOnBlackboard;

  /// Optional manual spawn channel.
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
    with SingleTickerProviderStateMixin {
  // Lifetime envelope.
  static const int _lifeMinMs = 4000;
  static const int _lifeMaxMs = 10000;
  static const int _lifeBaseMs = 2500;
  static const int _lifeCharMs = 60;

  static const int _fadeInMs = 280;
  static const int _fadeOutMs = 620;
  static const int _replyZoomMs = 900;
  static const int _replyTrailMs = 1200;

  static const Duration _coalesceIdle = Duration(milliseconds: 1500);
  static const int _maxConcurrent = 14;
  static const int _maxPerAgent = 3;
  static const int _maxBubbleChars = 200;

  // (Drift / per-bubble width constants removed — bubbles now render in
  // per-agent column layout; column width is the file-level
  // `_columnWidth` constant declared at the bottom of this file.)

  final List<_Bubble> _bubbles = [];
  BubbleController? _injected;
  late BubbleController _controller;
  bool _ownsController = false;

  int _nextId = 1;
  int _processedEvents = 0;
  DateTime? _mountedAt;

  final Map<String, StringBuffer> _chunkBuffers = {};
  final Map<String, Timer> _chunkTimers = {};
  final Map<String, bool> _agentSawChunks = {};
  // Tracks the single "live" chunk-sourced bubble per agent. When new
  // chunks arrive, the existing bubble is replaced rather than spawning
  // a new one — ensures at most ONE streaming bubble per agent at any time.
  final Map<String, int> _liveChunkBubbleIds = {};

  late final Ticker _ticker;
  int _nowMs = 0;

  @override
  void initState() {
    super.initState();
    _mountedAt = DateTime.now();
    _processedEvents = widget.session.events.length;
    _bindController(widget.controller);
    _ticker = createTicker(_onFrame)..start();
  }

  void _bindController(BubbleController? injected) {
    _injected = injected;
    _controller = injected ?? BubbleController();
    _ownsController = injected == null;
    _controller.addListener(_drainController);
  }

  void _unbindController() {
    _controller.removeListener(_drainController);
    if (_ownsController) {
      _controller.dispose();
    }
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
    for (final t in _chunkTimers.values) {
      t.cancel();
    }
    _unbindController();
    super.dispose();
  }

  void _onFrame(Duration elapsed) {
    _nowMs = DateTime.now().millisecondsSinceEpoch;
    final before = _bubbles.length;
    _bubbles.removeWhere((b) => _nowMs - b.spawnedAtMs > b.lifeMs);
    if (_bubbles.isNotEmpty || _bubbles.length != before) {
      // While bubbles are alive every frame matters — they're moving.
      setState(() {});
    }
  }

  void _drainController() {
    final pending = _controller.drain();
    if (pending.isEmpty) return;
    for (final r in pending) {
      _spawn(
        agentId: r.originId,
        text: r.text,
        kind: r.kind,
        replyTo: r.replyTo,
      );
    }
  }

  void _processNewEvents() {
    final events = widget.session.events;
    if (events.length <= _processedEvents) return;
    final fresh = events.sublist(_processedEvents);
    _processedEvents = events.length;

    final mountedAt = _mountedAt;
    for (final e in fresh) {
      if (mountedAt != null &&
          e.createdAt.isBefore(
            mountedAt.subtract(const Duration(seconds: 2)),
          )) {
        continue;
      }
      _handleEvent(e);
    }
  }

  bool _isEvaluatorMuted(String agentId) {
    if (!widget.evaluatorOnBlackboard) return false;
    return agentId == widget.session.config.finalEvaluator.id;
  }

  void _handleEvent(CouncilEvent e) {
    switch (e.type) {
      case CouncilEventType.agentChunk:
        if (_isEvaluatorMuted(e.fromAgentId)) break;
        _accumulateChunk(e.fromAgentId, e.message);
        break;
      case CouncilEventType.askedPool:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message,
          kind: BubbleKind.askPool,
          replyTo: e.toAgentId.isNotEmpty ? e.toAgentId : null,
        );
        break;
      case CouncilEventType.poolReply:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message,
          kind: BubbleKind.poolReply,
          replyTo: e.toAgentId.isNotEmpty ? e.toAgentId : null,
        );
        break;
      case CouncilEventType.askedUser:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message,
          kind: BubbleKind.askUser,
        );
        break;
      case CouncilEventType.userReply:
        final anchor = e.toAgentId.isNotEmpty ? e.toAgentId : e.fromAgentId;
        if (anchor.isNotEmpty) {
          _spawn(
            agentId: anchor,
            text: e.message,
            kind: BubbleKind.userReply,
          );
        }
        break;
      case CouncilEventType.userPingedOrchestrator:
        final anchor = e.toAgentId.isNotEmpty ? e.toAgentId : e.fromAgentId;
        if (anchor.isNotEmpty) {
          _spawn(
            agentId: anchor,
            text: e.message,
            kind: BubbleKind.userPing,
          );
        }
        break;
      case CouncilEventType.agentDone:
      case CouncilEventType.evaluatorDone:
        if (_isEvaluatorMuted(e.fromAgentId)) break;
        // Retire the live streaming bubble — the agent is done, so
        // its final summary replaces whatever partial text was showing.
        _retireLiveBubble(e.fromAgentId);
        _flushChunkBuffer(e.fromAgentId);
        // Show ONE final summary bubble regardless of whether we saw
        // chunks — this is the consolidated "done" message.
        if (e.message.trim().isNotEmpty) {
          _spawn(
            agentId: e.fromAgentId,
            text: e.message,
            kind: e.type == CouncilEventType.evaluatorDone
                ? BubbleKind.done
                : BubbleKind.done,
          );
        }
        _agentSawChunks.remove(e.fromAgentId);
        break;
      case CouncilEventType.agentError:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message.isEmpty ? 'error' : e.message,
          kind: BubbleKind.error,
        );
        break;
      case CouncilEventType.agentStalled:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message.isEmpty ? 'stalled' : e.message,
          kind: BubbleKind.error,
        );
        break;
    }
  }

  void _accumulateChunk(String agentId, String delta) {
    if (agentId.isEmpty) return;
    _agentSawChunks[agentId] = true;
    final buf = _chunkBuffers.putIfAbsent(agentId, () => StringBuffer());
    buf.write(delta);
    _chunkTimers[agentId]?.cancel();
    // Longer coalesce window — chunks flow into the single live bubble
    // rather than spawning many separate ones.
    _chunkTimers[agentId] = Timer(_coalesceIdle, () {
      _flushChunkBuffer(agentId);
    });
    // Still flush when the buffer gets large, but into the SAME live
    // bubble so the user sees consolidated text, not a burst of widgets.
    if (buf.length > 600) _flushChunkBuffer(agentId);
  }

  void _flushChunkBuffer(String agentId) {
    final buf = _chunkBuffers[agentId];
    if (buf == null || buf.isEmpty) return;
    final text = buf.toString();
    buf.clear();
    _chunkTimers[agentId]?.cancel();
    _chunkTimers.remove(agentId);
    // Instead of spawning multiple bubbles, take the tail of the
    // accumulated text and replace the existing live bubble. This
    // guarantees at most ONE chunk-sourced bubble per agent.
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return;
    final display = cleaned.length > _maxBubbleChars
        ? cleaned.substring(cleaned.length - _maxBubbleChars)
        : cleaned;
    _replaceLiveBubble(agentId: agentId, text: display);
  }


  /// Replace the single live chunk-bubble for [agentId]. If one exists,
  /// it is removed before spawning the replacement so the agent never
  /// has more than one streaming bubble on screen at a time.
  void _replaceLiveBubble({
    required String agentId,
    required String text,
  }) {
    final existingId = _liveChunkBubbleIds[agentId];
    if (existingId != null) {
      _bubbles.removeWhere((b) => b.id == existingId);
    }
    _spawn(
      agentId: agentId,
      text: text,
      kind: BubbleKind.speak,
      isLiveChunk: true,
    );
  }

  /// Remove the live chunk bubble for an agent (e.g. when it finishes).
  void _retireLiveBubble(String agentId) {
    _liveChunkBubbleIds.remove(agentId);
  }

  void _spawn({
    required String agentId,
    required String text,
    required BubbleKind kind,
    String? replyTo,
    bool isLiveChunk = false,
  }) {
    if (agentId.isEmpty) return;
    final cleaned = _normalizeBubbleText(text);
    if (cleaned.isEmpty) return;
    final display = cleaned.length > _maxBubbleChars
        ? '${cleaned.substring(0, _maxBubbleChars - 1)}…'
        : cleaned;

    final originRect = widget.anchors.rectOf(agentId);
    if (originRect == null) {
      // Layout hasn't published yet; defer one frame.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _spawn(agentId: agentId, text: text, kind: kind, replyTo: replyTo);
      });
      return;
    }

    // Consume the layout contract: outward unit vector from ring centre.
    // Falls back to centroid-based direction if ring data isn't ready.
    final outward = widget.anchors.outwardOf(agentId) ??
        _fallbackOutward(originRect.center);

    final lifeMs = (_lifeBaseMs + display.length * _lifeCharMs)
        .clamp(_lifeMinMs, _lifeMaxMs);

    final perAgent = _bubbles.where((b) => b.originId == agentId).toList();
    while (perAgent.length >= _maxPerAgent) {
      final oldest = perAgent.removeAt(0);
      _bubbles.remove(oldest);
    }
    while (_bubbles.length >= _maxConcurrent) {
      _bubbles.removeAt(0);
    }

    final bubbleId = _nextId++;
    if (isLiveChunk) {
      _liveChunkBubbleIds[agentId] = bubbleId;
    }
    setState(() {
      _bubbles.add(_Bubble(
        id: bubbleId,
        originId: agentId,
        replyTo: replyTo,
        text: display,
        kind: kind,
        spawnedAtMs: DateTime.now().millisecondsSinceEpoch,
        lifeMs: lifeMs,
        zoomMs: _replyZoomMs,
        trailMs: _replyTrailMs,
        fadeInMs: _fadeInMs,
        fadeOutMs: _fadeOutMs,
        driftDir: outward,
        originRect: originRect,
      ));
    });
  }

  String _normalizeBubbleText(String raw) {
    final original = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (original.isEmpty) return '';
    var text = original;
    text = text.replaceFirst(
      RegExp(r'^(task|task name|objective)\s*[:\-–]\s*', caseSensitive: false),
      '',
    );
    text = text.replaceFirst(
      RegExp(r'^[\"“][^\"”\n]{3,90}[\"”]\s*[:\-–]\s*'),
      '',
    );
    text = text.trim();
    return text.isEmpty ? original : text;
  }

  Offset _fallbackOutward(Offset cardCenter) {
    final ringC = widget.anchors.ringCenter;
    final v = cardCenter - ringC;
    final len = v.distance;
    if (len < 1) return const Offset(0, -1);
    return Offset(v.dx / len, v.dy / len);
  }

  /// Test hook: simple count of visible bubble entries grouped by agent.
  /// Layout is now deterministic (per-agent column anchored to the card),
  /// so detailed rect debugging is no longer load-bearing.
  @visibleForTesting
  Map<String, int> debugBubbleCountsByAgent() {
    final out = <String, int>{};
    for (final b in _bubbles) {
      out.update(b.originId, (v) => v + 1, ifAbsent: () => 1);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.anchors,
      builder: (context, _) {
        final cardRects = widget.anchors._rects;
        final groups = <String, List<_Bubble>>{};
        for (final b in _bubbles) {
          groups.putIfAbsent(b.originId, () => <_Bubble>[]).add(b);
        }
        // Newest first → renders closest to the agent card edge.
        for (final list in groups.values) {
          list.sort((a, b) => b.spawnedAtMs.compareTo(a.spawnedAtMs));
        }

        // Compute one collision-aware placement per agent column.
        // Recomputed every frame the anchors notify, so resize and
        // ring reflows automatically reposition bubbles. This is the
        // "never overlap a panel" invariant — see _kBubblePanelMinGap.
        final placements = <String, _BubblePlacement>{};
        for (final entry in groups.entries) {
          final cardRect = cardRects[entry.key];
          if (cardRect == null) continue;
          placements[entry.key] = _placeColumn(
            agentId: entry.key,
            cardRect: cardRect,
            allRects: cardRects,
            bubbleCount: entry.value.length,
          );
        }

        return IgnorePointer(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Hairline leaders below bubbles so the bubble body
              // visually overlaps the line endpoint instead of vice
              // versa. Painted only for reflowed placements (i.e.
              // when the bubble is not on its preferred side and the
              // association needs reinforcing).
              Positioned.fill(
                child: CustomPaint(
                  painter: _LeaderLinesPainter(
                    cardRects: cardRects,
                    placements: placements,
                  ),
                ),
              ),
              for (final entry in groups.entries)
                if (placements[entry.key] != null)
                  _buildAgentColumn(
                    agentId: entry.key,
                    cardRect: cardRects[entry.key]!,
                    bubbles: entry.value,
                    placement: placements[entry.key]!,
                  ),
            ],
          ),
        );
      },
    );
  }

  /// Pick a non-overlapping rect for an agent's bubble column.
  ///
  /// Algorithm (in order):
  ///   1. Preferred side = outward direction of the card on the ring
  ///      (right wing → right, left wing → left).
  ///   2. Try preferred → opposite → above → below. Each candidate is
  ///      offset from the panel edge by [_kBubblePanelMinGap] so the
  ///      bubble bbox can NEVER touch the panel rect.
  ///   3. A candidate is rejected if its rect (a) escapes the theater
  ///      safe zone, or (b) overlaps any sibling panel rect inflated
  ///      by [_kBubblePanelMinGap]. The orchestrator counts as a
  ///      sibling so bubbles never cross the centre card.
  ///   4. If every side fails, fall back to the preferred side and
  ///      flag the placement reflowed=true so a leader line paints.
  ///   5. Column height is content-bounded (per bubble estimate ×
  ///      count) so the column rect doesn't claim an entire wing's
  ///      worth of vertical space for collision purposes.
  _BubblePlacement _placeColumn({
    required String agentId,
    required Rect cardRect,
    required Map<String, Rect> allRects,
    required int bubbleCount,
  }) {
    final outward = widget.anchors.outwardOf(agentId) ??
        _fallbackOutward(cardRect.center);
    final safe = widget.anchors.safeZone;
    final preferred = outward.dx >= 0 ? _BubbleSide.right : _BubbleSide.left;
    final inUpperHalf = !safe.isEmpty
        ? cardRect.center.dy <= safe.center.dy
        : cardRect.center.dy <= widget.anchors.ringCenter.dy;

    final order = <_BubbleSide>[
      preferred,
      preferred == _BubbleSide.right ? _BubbleSide.left : _BubbleSide.right,
      inUpperHalf ? _BubbleSide.below : _BubbleSide.above,
      inUpperHalf ? _BubbleSide.above : _BubbleSide.below,
    ];

    // Estimate column footprint from bubble count so collision testing
    // doesn't reserve a whole wing's worth of vertical space.
    final count = math.max(1, bubbleCount);
    final estContent = count * _kEstBubbleHeight +
        math.max(0, count - 1) * _columnGap;
    final maxAvail = safe.isEmpty
        ? 720.0
        : math.max(120.0, safe.height - 24);
    final estHeight = math.min(estContent, maxAvail);

    for (final side in order) {
      final rect = _candidateRect(cardRect, side, _columnWidth, estHeight);
      if (!_safeContains(safe, rect)) continue;
      if (_collidesWithSiblings(rect, allRects, agentId)) continue;
      return _BubblePlacement(
        rect: rect,
        side: side,
        reflowed: side != preferred,
      );
    }

    // Fallback: preferred side, clamped into safeZone, leader line on.
    var fallback = _candidateRect(cardRect, preferred, _columnWidth, estHeight);
    if (!safe.isEmpty) {
      var l = fallback.left;
      var t = fallback.top;
      if (l < safe.left + 4) l = safe.left + 4;
      if (l + fallback.width > safe.right - 4) {
        l = safe.right - 4 - fallback.width;
      }
      if (t < safe.top + 4) t = safe.top + 4;
      if (t + fallback.height > safe.bottom - 4) {
        t = safe.bottom - 4 - fallback.height;
      }
      fallback = Rect.fromLTWH(l, t, fallback.width, fallback.height);
    }
    return _BubblePlacement(rect: fallback, side: preferred, reflowed: true);
  }

  Rect _candidateRect(Rect card, _BubbleSide side, double w, double h) {
    switch (side) {
      case _BubbleSide.right:
        return Rect.fromLTWH(
          card.right + _kBubblePanelMinGap,
          card.top,
          w,
          h,
        );
      case _BubbleSide.left:
        return Rect.fromLTWH(
          card.left - _kBubblePanelMinGap - w,
          card.top,
          w,
          h,
        );
      case _BubbleSide.above:
        return Rect.fromLTWH(
          card.center.dx - w / 2,
          card.top - _kBubblePanelMinGap - h,
          w,
          h,
        );
      case _BubbleSide.below:
        return Rect.fromLTWH(
          card.center.dx - w / 2,
          card.bottom + _kBubblePanelMinGap,
          w,
          h,
        );
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
    String selfId,
  ) {
    for (final e in allRects.entries) {
      if (e.key == selfId) continue;
      final inflated = e.value.inflate(_kBubblePanelMinGap);
      if (candidate.overlaps(inflated)) return true;
    }
    return false;
  }

  /// Per-agent commentary column, placed by [_placeColumn].
  /// Newest entry sits closest to the card edge; older entries stack
  /// away from it and fade out as they age.
  Widget _buildAgentColumn({
    required String agentId,
    required Rect cardRect,
    required List<_Bubble> bubbles,
    required _BubblePlacement placement,
  }) {
    final rect = placement.rect;
    final children = <Widget>[];
    for (var i = 0; i < bubbles.length; i++) {
      if (i > 0) children.add(const SizedBox(height: _columnGap));
      children.add(_buildAgentBubble(bubbles[i]));
    }

    // Decide stack direction and cross-axis alignment per side so
    // "newest closest to the card" holds regardless of which way we
    // reflowed.
    late final bool reverseChildren;
    late final MainAxisAlignment mainAxis;
    late final CrossAxisAlignment crossAxis;
    switch (placement.side) {
      case _BubbleSide.right:
        reverseChildren = false;
        mainAxis = MainAxisAlignment.start;
        crossAxis = CrossAxisAlignment.start;
        break;
      case _BubbleSide.left:
        reverseChildren = false;
        mainAxis = MainAxisAlignment.start;
        crossAxis = CrossAxisAlignment.end;
        break;
      case _BubbleSide.below:
        reverseChildren = false;
        mainAxis = MainAxisAlignment.start;
        crossAxis = CrossAxisAlignment.center;
        break;
      case _BubbleSide.above:
        // Newest at the bottom (nearest the card), older fade upward.
        reverseChildren = true;
        mainAxis = MainAxisAlignment.end;
        crossAxis = CrossAxisAlignment.center;
        break;
    }

    return Positioned(
      key: ValueKey('council-col-$agentId'),
      left: rect.left,
      top: rect.top,
      width: rect.width,
      // Height is intentionally omitted — the Column sizes itself to
      // its intrinsic height. The placement rect's height is a
      // collision-detection budget only; clamping the Positioned to it
      // caused multi-line bubble text to clip at the bottom.
      child: Column(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: mainAxis,
        crossAxisAlignment: crossAxis,
        children: reverseChildren
            ? children.reversed.toList(growable: false)
            : children,
      ),
    );
  }

  Widget _buildAgentBubble(_Bubble b) {
    final ageMs = _nowMs - b.spawnedAtMs;
    final lifeMs = b.lifeMs;
    final clamped = ageMs.clamp(0, lifeMs).toInt();

    double opacity;
    if (clamped < b.fadeInMs) {
      opacity = _easeOutCubic(clamped / b.fadeInMs);
    } else if (clamped > lifeMs - b.fadeOutMs) {
      final t = (clamped - (lifeMs - b.fadeOutMs)) / b.fadeOutMs;
      opacity = 1.0 - _easeInQuad(t.clamp(0.0, 1.0).toDouble());
    } else {
      opacity = 1.0;
    }

    return Opacity(
      opacity: opacity,
      child: SizedBox(
        width: _columnWidth,
        child: _BubbleText(
          text: b.text,
          kind: b.kind,
          agentLabel: _agentLabel(b.originId),
          softBackdrop: true,
        ),
      ),
    );
  }

  String _agentLabel(String agentId) {
    final a = widget.session.agentById(agentId);
    if (a == null || a.name.trim().isEmpty) return '';
    return a.name.trim().toUpperCase();
  }

  double _easeOutCubic(double t) {
    final u = 1.0 - t;
    return 1.0 - u * u * u;
  }

  double _easeInQuad(double t) => t * t;
}

const double _columnWidth = 280;
const double _columnGap = 6;

/// Hard layout invariant: a speech-bubble column's bounding box must
/// sit at least this many logical pixels away from EVERY agent panel
/// rect (origin card included on its inside edge, all sibling cards
/// fully). Never zero, never negative. If you tune this, keep it in
/// the 8–12px band so bubbles read as "near the panel" without
/// kissing it.
const double _kBubblePanelMinGap = 10.0;

/// Per-bubble vertical estimate used only for collision sizing — the
/// actual bubble paints at its measured intrinsic height. Accounts for
/// multi-line consolidated live-bubbles (up to 200 chars wrapping at
/// ~260px column width ≈ 4–5 text lines + eyebrow + padding).
const double _kEstBubbleHeight = 120.0;

/// Which side of the owning panel a bubble column was placed on.
enum _BubbleSide { right, left, above, below }

/// Result of the collision-aware placement pass. [reflowed] is true
/// when the bubble could not sit on its preferred side and needed to
/// be relocated; the leader-line painter uses this to draw a hairline
/// connector reinforcing the bubble→panel association.
class _BubblePlacement {
  final Rect rect;
  final _BubbleSide side;
  final bool reflowed;
  const _BubblePlacement({
    required this.rect,
    required this.side,
    required this.reflowed,
  });
}

/// Hairline connector from a panel edge to its bubble column when the
/// column is reflowed off the preferred side. Stays out of the way
/// when the bubble is already adjacent to its panel — there's no
/// value in re-labelling an obvious association.
class _LeaderLinesPainter extends CustomPainter {
  final Map<String, Rect> cardRects;
  final Map<String, _BubblePlacement> placements;

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
        case _BubbleSide.right:
          from = Offset(card.right, card.center.dy);
          to = Offset(p.rect.left, p.rect.top + 18);
          break;
        case _BubbleSide.left:
          from = Offset(card.left, card.center.dy);
          to = Offset(p.rect.right, p.rect.top + 18);
          break;
        case _BubbleSide.above:
          from = Offset(card.center.dx, card.top);
          to = Offset(p.rect.center.dx, p.rect.bottom);
          break;
        case _BubbleSide.below:
          from = Offset(card.center.dx, card.bottom);
          to = Offset(p.rect.center.dx, p.rect.top);
          break;
      }
      canvas.drawLine(from, to, paint);
      // Subtle terminator dot at the bubble end so the eye knows
      // which side the line "arrives" at.
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

/// Chromeless body. White (fgPrimary) text on the existing dark
/// surface. Soft frosted scrim only when dipped beneath a card.
class _BubbleText extends StatelessWidget {
  final String text;
  final BubbleKind kind;
  final String agentLabel;

  /// Show a soft frosted backdrop when the bubble is over a busy area
  /// (currently engaged: while opacity-dipped beneath a card). Hard
  /// pill is intentionally avoided.
  final bool softBackdrop;

  const _BubbleText({
    required this.text,
    required this.kind,
    required this.agentLabel,
    required this.softBackdrop,
  });

  Color get _accent {
    return switch (kind) {
      BubbleKind.speak => DuckColors.accentCyan,
      BubbleKind.askPool => DuckColors.accentPurple,
      BubbleKind.askUser => DuckColors.accentDuck,
      BubbleKind.poolReply => DuckColors.accentMint,
      BubbleKind.userReply => DuckColors.accentDuck,
      BubbleKind.userPing => DuckColors.accentDuck,
      BubbleKind.done => DuckColors.accentCyan,
      BubbleKind.error => DuckColors.stateError,
    };
  }

  String get _eyebrowKindLabel {
    return switch (kind) {
      BubbleKind.askPool => 'TO POOL',
      BubbleKind.poolReply => 'POOL',
      BubbleKind.askUser => 'ASKS YOU',
      BubbleKind.userReply => 'YOU →',
      BubbleKind.userPing => 'YOU →',
      BubbleKind.done => 'DONE',
      BubbleKind.error => 'ERROR',
      BubbleKind.speak => '',
    };
  }

  @override
  Widget build(BuildContext context) {
    final accent = _accent;
    final kindLabel = _eyebrowKindLabel;
    final hasEyebrow = agentLabel.isNotEmpty || kindLabel.isNotEmpty;

    final body = ConstrainedBox(
      // Hard width contract: the bubble's parent SizedBox is 280px
      // (`_columnWidth`). The DecoratedBox below adds 10px padding on
      // each side, so the body must not exceed 280 - 20 = 260. We keep
      // a small safety margin so the hairline border doesn't pixel-clip
      // on fractional DPR scales.
      constraints: const BoxConstraints(maxWidth: 256),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasEyebrow)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 14,
                    height: 1,
                    color: accent.withValues(alpha: 0.85),
                  ),
                  const SizedBox(width: 6),
                  if (agentLabel.isNotEmpty)
                    Flexible(
                      child: Text(
                        agentLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent.withValues(alpha: 0.98),
                          fontSize: 10.4,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.75,
                        ),
                      ),
                    ),
                  if (kindLabel.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        kindLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: accent.withValues(alpha: 0.66),
                          fontSize: 9.4,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          Text(
            text,
            softWrap: true,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 13,
              height: 1.38,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );

    if (!softBackdrop) return body;
    // Opaque dark-blue bubble surface. The user explicitly asked for
    // a dark, opaque (alpha 1.0) fill that "fits" the modal palette —
    // no translucent glass, no gradient bleed-through. We use the
    // dedicated `councilBubbleBg` token (#0E1626) which sits a
    // notch deeper than `councilSurface` so bubbles read as quoted
    // utterances above the panels rather than another panel surface.
    // Hairline `councilBorder` keeps the edge crisp at any DPR;
    // `fgPrimary` (#D8DEE9) on this fill clears WCAG AA easily
    // (contrast ≈ 11.6:1).
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DuckColors.councilBubbleBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DuckColors.councilBorder, width: 0.8),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 14,
            spreadRadius: -2,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        child: body,
      ),
    );
  }
}
