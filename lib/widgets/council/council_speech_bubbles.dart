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

  static const Duration _coalesceIdle = Duration(milliseconds: 450);
  static const int _maxConcurrent = 14;
  static const int _maxPerAgent = 3;
  static const int _maxBubbleChars = 200;

  // Drift travel = card.shortestSide × _driftSpan. Capped to the safe
  // zone via clamp at projection time.
  static const double _driftSpan = 1.7;
  static const double _bubbleWidth = 268.0;

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
        _flushChunkBuffer(e.fromAgentId);
        if (!(_agentSawChunks[e.fromAgentId] ?? false) &&
            e.message.trim().isNotEmpty) {
          _spawn(
            agentId: e.fromAgentId,
            text: e.message,
            kind: BubbleKind.speak,
          );
        }
        if (e.type == CouncilEventType.evaluatorDone &&
            e.message.trim().isNotEmpty) {
          _spawn(
            agentId: e.fromAgentId,
            text: e.message,
            kind: BubbleKind.done,
          );
        }
        break;
      case CouncilEventType.agentError:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message.isEmpty ? 'error' : e.message,
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
    _chunkTimers[agentId] = Timer(_coalesceIdle, () {
      _flushChunkBuffer(agentId);
    });
    if (buf.length > 320) _flushChunkBuffer(agentId);
  }

  void _flushChunkBuffer(String agentId) {
    final buf = _chunkBuffers[agentId];
    if (buf == null || buf.isEmpty) return;
    final text = buf.toString();
    buf.clear();
    _chunkTimers[agentId]?.cancel();
    _chunkTimers.remove(agentId);
    for (final piece in _splitForBubbles(text)) {
      _spawn(agentId: agentId, text: piece, kind: BubbleKind.speak);
    }
  }

  Iterable<String> _splitForBubbles(String text) sync* {
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return;
    if (cleaned.length <= _maxBubbleChars) {
      yield cleaned;
      return;
    }
    final parts = cleaned.split(RegExp(r'(?<=[.!?])\s+'));
    final buf = StringBuffer();
    for (final p in parts) {
      if (buf.length + p.length + 1 > _maxBubbleChars && buf.isNotEmpty) {
        yield buf.toString().trim();
        buf.clear();
      }
      if (p.length > _maxBubbleChars) {
        for (var i = 0; i < p.length; i += _maxBubbleChars) {
          yield p.substring(i, math.min(i + _maxBubbleChars, p.length));
        }
        continue;
      }
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(p);
    }
    if (buf.isNotEmpty) yield buf.toString().trim();
  }

  void _spawn({
    required String agentId,
    required String text,
    required BubbleKind kind,
    String? replyTo,
  }) {
    if (agentId.isEmpty) return;
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
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

    setState(() {
      _bubbles.add(_Bubble(
        id: _nextId++,
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

  Offset _fallbackOutward(Offset cardCenter) {
    final ringC = widget.anchors.ringCenter;
    final v = cardCenter - ringC;
    final len = v.distance;
    if (len < 1) return const Offset(0, -1);
    return Offset(v.dx / len, v.dy / len);
  }

  /// Test hook: rough on-screen rects of the visible bubbles.
  @visibleForTesting
  List<Rect> debugBubbleSlotRects() {
    final out = <Rect>[];
    for (final b in _bubbles) {
      final layout = _projectBubble(b, reduced: false);
      if (layout == null) continue;
      out.add(layout.rect);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    return AnimatedBuilder(
      animation: widget.anchors,
      builder: (context, _) {
        final cardRects = widget.anchors._rects;

        return IgnorePointer(
          // Bubbles drift; pinning/hover doesn't fit a moving target.
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              for (final b in _bubbles)
                _buildBubble(b, cardRects, reduced: reduced),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBubble(
    _Bubble b,
    Map<String, Rect> cardRects, {
    required bool reduced,
  }) {
    final layout = _projectBubble(b, reduced: reduced);
    if (layout == null) return const SizedBox.shrink();

    // Card-overlap dim. Origin & current target are exempt.
    var dim = 1.0;
    final exemptIds = <String>{b.originId};
    if (b.replyTo != null) exemptIds.add(b.replyTo!);
    for (final entry in cardRects.entries) {
      if (exemptIds.contains(entry.key)) continue;
      if (layout.rect.overlaps(entry.value)) {
        dim = math.min(dim, 0.22);
      }
    }

    final agentLabel = _agentLabel(b.originId);

    return Positioned(
      key: ValueKey('bubble-${b.id}'),
      left: layout.rect.left,
      top: layout.rect.top,
      width: layout.rect.width,
      child: Opacity(
        opacity: (layout.opacity * dim).clamp(0.0, 1.0),
        child: Transform.scale(
          alignment: Alignment.center,
          scale: layout.scale,
          child: _BubbleText(
            text: b.text,
            kind: b.kind,
            agentLabel: agentLabel,
            softBackdrop: dim < 0.6,
          ),
        ),
      ),
    );
  }

  String _agentLabel(String agentId) {
    final a = widget.session.agentById(agentId);
    if (a == null || a.name.trim().isEmpty) return '';
    return a.name.trim().toUpperCase();
  }

  /// Project a bubble to its current rect/scale/opacity for `_nowMs`.
  _BubbleLayout? _projectBubble(_Bubble b, {required bool reduced}) {
    final ageMs = _nowMs - b.spawnedAtMs;
    if (ageMs < 0) return null;
    final lifeMs = b.lifeMs;
    final clamped = ageMs.clamp(0, lifeMs).toInt();

    final originEdge = _outwardEdge(b.originRect, b.driftDir);

    Offset center;
    double scale = 1.0;

    if (reduced) {
      center = originEdge + b.driftDir * 12;
    } else if (b.isReply) {
      final targetRect = widget.anchors.rectOf(b.replyTo!);
      if (targetRect == null) {
        center = _driftCenter(b, originEdge, clamped, lifeMs);
      } else {
        center = _replyCenter(
          b,
          originEdge: originEdge,
          targetRect: targetRect,
          ageMs: clamped,
          lifeMs: lifeMs,
        );
        if (clamped < b.zoomMs) {
          final t = clamped / b.zoomMs;
          final eased = _easeInOutCubic(t);
          // 0.9 → 1.0 with a tiny cosine overshoot.
          scale = 0.9 + 0.10 * eased + 0.05 * math.sin(t * math.pi);
        }
      }
    } else {
      center = _driftCenter(b, originEdge, clamped, lifeMs);
      if (clamped < b.fadeInMs) {
        final t = clamped / b.fadeInMs;
        scale = 0.94 + 0.06 * _easeOutCubic(t);
      }
    }

    // Opacity envelope.
    double opacity;
    if (clamped < b.fadeInMs) {
      opacity = _easeOutCubic(clamped / b.fadeInMs);
    } else if (clamped > lifeMs - b.fadeOutMs) {
      final t = (clamped - (lifeMs - b.fadeOutMs)) / b.fadeOutMs;
      opacity = 1.0 - _easeInQuad(t.clamp(0.0, 1.0).toDouble());
    } else {
      opacity = 1.0;
    }

    final estimatedHeight = _estimateHeight(b.text);
    var rect = Rect.fromCenter(
      center: center,
      width: _bubbleWidth,
      height: estimatedHeight,
    );

    // Clamp into the published safe zone so bubbles never escape into
    // header/footer chrome. Only clamp if a non-empty safe zone exists.
    final safe = widget.anchors.safeZone;
    if (!safe.isEmpty) {
      var dx = 0.0, dy = 0.0;
      if (rect.left < safe.left) dx = safe.left - rect.left;
      if (rect.right > safe.right) dx = safe.right - rect.right;
      if (rect.top < safe.top) dy = safe.top - rect.top;
      if (rect.bottom > safe.bottom) dy = safe.bottom - rect.bottom;
      if (dx != 0 || dy != 0) rect = rect.shift(Offset(dx, dy));
    }

    return _BubbleLayout(rect: rect, opacity: opacity, scale: scale);
  }

  Offset _driftCenter(
    _Bubble b,
    Offset originEdge,
    int ageMs,
    int lifeMs,
  ) {
    final t = (ageMs / lifeMs).clamp(0.0, 1.0).toDouble();
    // 1 - exp(-3t): asymptotic ease-out; reaches ~95% by EOL.
    final eased = 1.0 - math.exp(-3.0 * t);
    final maxDistance = b.originRect.shortestSide * _driftSpan;
    return originEdge + b.driftDir * (eased * maxDistance);
  }

  Offset _replyCenter(
    _Bubble b, {
    required Offset originEdge,
    required Rect targetRect,
    required int ageMs,
    required int lifeMs,
  }) {
    final zoomMs = b.zoomMs;
    final trailMs = b.trailMs;
    final fadeOutMs = b.fadeOutMs;

    final targetDir = widget.anchors.outwardOf(b.replyTo!) ??
        _fallbackOutward(targetRect.center);
    final targetEdge = _outwardEdge(targetRect, targetDir);
    final landing = targetEdge + targetDir * 22;

    if (ageMs <= zoomMs) {
      // Phase A: zoom — origin → landing with a brief overshoot bias.
      final t = (ageMs / zoomMs).clamp(0.0, 1.0).toDouble();
      final eased = _easeInOutCubic(t);
      final overshoot = math.sin(t * math.pi) * 0.06;
      final extended = landing + targetDir * (overshoot * 24);
      return Offset.lerp(originEdge, extended, eased)!;
    } else if (ageMs <= zoomMs + trailMs) {
      // Phase B: trail — sit at landing with a soft 2px bob.
      final localT = (ageMs - zoomMs) / trailMs;
      final bob = math.sin(localT * math.pi * 2) * 2.0;
      return landing + Offset(0, bob);
    } else {
      // Phase C: release outward from the target.
      final remaining = lifeMs - (zoomMs + trailMs);
      final phaseLen = math.max(remaining, fadeOutMs);
      final localMs = (ageMs - (zoomMs + trailMs)).clamp(0, phaseLen).toInt();
      final t = (localMs / phaseLen).clamp(0.0, 1.0).toDouble();
      final eased = 1.0 - math.exp(-3.0 * t);
      final maxDistance = targetRect.shortestSide * _driftSpan;
      b.driftDir = targetDir;
      return landing + targetDir * (eased * maxDistance);
    }
  }

  /// Midpoint of the side of `rect` that faces in the direction of
  /// `outward` (unit vector pointing away from ring centre).
  Offset _outwardEdge(Rect rect, Offset outward) {
    final ax = outward.dx.abs();
    final ay = outward.dy.abs();
    if (ax > ay) {
      return outward.dx >= 0
          ? Offset(rect.right, rect.center.dy)
          : Offset(rect.left, rect.center.dy);
    } else {
      return outward.dy >= 0
          ? Offset(rect.center.dx, rect.bottom)
          : Offset(rect.center.dx, rect.top);
    }
  }

  double _easeOutCubic(double t) {
    final u = 1.0 - t;
    return 1.0 - u * u * u;
  }

  double _easeInQuad(double t) => t * t;

  double _easeInOutCubic(double t) {
    if (t < 0.5) return 4 * t * t * t;
    final f = 2 * t - 2;
    return 0.5 * f * f * f + 1;
  }

  double _estimateHeight(String text) {
    final lines = (text.length / 38).ceil().clamp(1, 6);
    return 16.0 + 22.0 * lines + 12.0;
  }
}

class _BubbleLayout {
  final Rect rect;
  final double opacity;
  final double scale;
  _BubbleLayout({
    required this.rect,
    required this.opacity,
    required this.scale,
  });
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
      BubbleKind.done => DuckColors.stateOk,
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
    final eyebrowText = [
      if (agentLabel.isNotEmpty) agentLabel,
      if (kindLabel.isNotEmpty) kindLabel,
    ].join(' · ');

    final body = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 268),
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
                  Flexible(
                    child: Text(
                      eyebrowText,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: accent.withValues(alpha: 0.95),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Text(
            text,
            softWrap: true,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 13,
              height: 1.35,
              fontWeight: FontWeight.w500,
              shadows: [
                // Subtle readability shadow — keeps glyphs legible
                // against the diagonal backdrop without a hard pill.
                Shadow(
                  color: Color(0xCC000000),
                  blurRadius: 6,
                  offset: Offset(0, 1),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (!softBackdrop) return body;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DuckColors.bgDeepest.withValues(alpha: 0.30),
            DuckColors.bgDeeper.withValues(alpha: 0.10),
          ],
        ),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        child: body,
      ),
    );
  }
}
