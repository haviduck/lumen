import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// Anchor positions for every agent on the council canvas.
/// Keys are agent IDs; values are the centre point of the agent card
/// in stage-local coordinates. Updated by the stage on every layout.
class CouncilStageAnchors extends ChangeNotifier {
  final Map<String, Rect> _rects = {};

  Rect? rectOf(String id) => _rects[id];
  Offset? topOf(String id) {
    final r = _rects[id];
    if (r == null) return null;
    return Offset(r.center.dx, r.top);
  }

  Offset? centerOf(String id) => _rects[id]?.center;

  void update(Map<String, Rect> rects) {
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
    if (!changed) return;
    _rects
      ..clear()
      ..addAll(rects);
    notifyListeners();
  }
}

/// Semantic kind drives the eyebrow label / leading-rule accent only.
/// There is NO bubble chrome anymore — overlays are flat white text.
enum _BubbleKind { speak, askPool, askUser, poolReply, userReply, userPing, done, error }

class _Bubble {
  final int id;
  final String agentId;
  final String text;
  final _BubbleKind kind;
  final DateTime spawnedAt;

  _Bubble({
    required this.id,
    required this.agentId,
    required this.text,
    required this.kind,
    required this.spawnedAt,
  });
}

/// Ephemeral text overlays anchored above agent cards.
///
/// Visual contract (Vista spec, post-addendum):
///   * No chrome. No bubble shape, no tail, no fill, no border, no shadow.
///   * White (fgPrimary) body text on the existing dark surface.
///   * Optional thin 1px leading rule + small uppercase agent-name eyebrow.
///   * Slide-up + fade in (220ms, easeOutCubic, ~12px Y travel).
///   * 8s readable dwell.
///   * Soft fade out (320ms, easeInQuad). Total life ≈ 8.54s.
///   * Hover-to-persist: cursor over the text rect cancels the dwell timer
///     and keeps the overlay at full opacity until the cursor leaves.
///   * Click-to-pin: tap freezes the overlay (no dwell, no fade) until
///     tapped again. Pin overrides hover.
///
/// Hit-test contract:
///   * The layer itself does NOT wrap in IgnorePointer — that would kill
///     hover-to-persist and click-to-pin entirely.
///   * Each bubble is wrapped in a MouseRegion (hover detection still fires
///     even when its child IgnorePointer is active) plus a per-bubble
///     IgnorePointer that ignores pointers UNLESS the bubble is hovered or
///     pinned. Result: idle bubbles fall through to agent cards / traffic
///     layer underneath; only the bubble actually under the cursor steals
///     events, and only on the tight glyph rect (no padding halo).
///
/// Coalesces `agent_chunk` deltas per agent in a 450ms idle window so
/// streaming tokens become readable utterances.
class CouncilSpeechBubblesLayer extends StatefulWidget {
  final CouncilSession session;
  final CouncilStageAnchors anchors;
  /// When true, the final evaluator's output is being rendered on the
  /// LeftBlackboard panel; suppress chunk + done bubbles for the
  /// evaluator so it doesn't double-render in chat-style overlays.
  final bool evaluatorOnBlackboard;

  const CouncilSpeechBubblesLayer({
    super.key,
    required this.session,
    required this.anchors,
    this.evaluatorOnBlackboard = false,
  });

  @override
  State<CouncilSpeechBubblesLayer> createState() =>
      _CouncilSpeechBubblesLayerState();
}

class _CouncilSpeechBubblesLayerState extends State<CouncilSpeechBubblesLayer>
    with TickerProviderStateMixin {
  // Total visible life when not pinned/hovered:
  //   220ms in + 8000ms dwell + 320ms out = 8540ms.
  static const Duration _fadeIn = Duration(milliseconds: 220);
  // Dwell window (8000ms) is folded into _bubbleLife below; kept implicit.
  static const Duration _fadeOut = Duration(milliseconds: 320);
  static const Duration _bubbleLife = Duration(milliseconds: 8540);

  static const Duration _coalesceIdle = Duration(milliseconds: 450);
  static const int _maxConcurrent = 14;
  static const int _maxPerAgent = 3;
  static const int _maxBubbleChars = 180;

  final List<_Bubble> _bubbles = [];
  // Bubble IDs the user is currently hovering or has pinned. Either keeps
  // the overlay alive past its dwell.
  final Set<int> _hovered = {};
  final Set<int> _pinned = {};

  int _nextId = 1;
  int _processedEvents = 0;
  DateTime? _mountedAt;

  // Per-agent streaming buffers
  final Map<String, StringBuffer> _chunkBuffers = {};
  final Map<String, Timer> _chunkTimers = {};
  final Map<String, bool> _agentSawChunks = {};

  late final Ticker _frameTicker;

  @override
  void initState() {
    super.initState();
    _mountedAt = DateTime.now();
    _processedEvents = widget.session.events.length;
    _frameTicker = createTicker(_onFrame)..start();
  }

  @override
  void didUpdateWidget(covariant CouncilSpeechBubblesLayer old) {
    super.didUpdateWidget(old);
    _processNewEvents();
  }

  void _onFrame(Duration _) {
    final now = DateTime.now();
    final removed = _bubbles
        .where(
          (b) =>
              !_hovered.contains(b.id) &&
              !_pinned.contains(b.id) &&
              now.difference(b.spawnedAt) > _bubbleLife,
        )
        .toList();
    if (removed.isNotEmpty) {
      setState(() {
        for (final b in removed) {
          _bubbles.remove(b);
        }
      });
    }
  }

  @override
  void dispose() {
    _frameTicker.dispose();
    for (final t in _chunkTimers.values) {
      t.cancel();
    }
    super.dispose();
  }

  void _processNewEvents() {
    final events = widget.session.events;
    if (events.length <= _processedEvents) return;
    final fresh = events.sublist(_processedEvents);
    _processedEvents = events.length;

    final mountedAt = _mountedAt;
    for (final e in fresh) {
      // Suppress firework on session resume — only animate live events.
      if (mountedAt != null &&
          e.createdAt.isBefore(mountedAt.subtract(
            const Duration(seconds: 2),
          ))) {
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
          kind: _BubbleKind.askPool,
        );
        break;
      case CouncilEventType.poolReply:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message,
          kind: _BubbleKind.poolReply,
        );
        break;
      case CouncilEventType.askedUser:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message,
          kind: _BubbleKind.askUser,
        );
        break;
      case CouncilEventType.userReply:
        // User answered an agent's askUser prompt. Anchor to the agent the
        // user replied TO so the response shows above its addressee.
        final anchor = e.toAgentId.isNotEmpty ? e.toAgentId : e.fromAgentId;
        if (anchor.isNotEmpty) {
          _spawn(agentId: anchor, text: e.message, kind: _BubbleKind.userReply);
        }
        break;
      case CouncilEventType.userPingedOrchestrator:
        // Mid-council user inject. Anchored to orchestrator (toAgentId).
        final anchor = e.toAgentId.isNotEmpty ? e.toAgentId : e.fromAgentId;
        if (anchor.isNotEmpty) {
          _spawn(agentId: anchor, text: e.message, kind: _BubbleKind.userPing);
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
            kind: _BubbleKind.speak,
          );
        }
        if (e.type == CouncilEventType.evaluatorDone &&
            e.message.trim().isNotEmpty) {
          _spawn(
            agentId: e.fromAgentId,
            text: e.message,
            kind: _BubbleKind.done,
          );
        }
        break;
      case CouncilEventType.agentError:
        _spawn(
          agentId: e.fromAgentId,
          text: e.message.isEmpty ? 'error' : e.message,
          kind: _BubbleKind.error,
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
      _spawn(agentId: agentId, text: piece, kind: _BubbleKind.speak);
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
    required _BubbleKind kind,
  }) {
    if (agentId.isEmpty) return;
    final cleaned = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned.isEmpty) return;
    final display = cleaned.length > _maxBubbleChars
        ? '${cleaned.substring(0, _maxBubbleChars - 1)}…'
        : cleaned;

    setState(() {
      final perAgent = _bubbles.where((b) => b.agentId == agentId).toList();
      while (perAgent.length >= _maxPerAgent) {
        final oldest = perAgent.removeAt(0);
        _bubbles.remove(oldest);
        _hovered.remove(oldest.id);
        _pinned.remove(oldest.id);
      }
      while (_bubbles.length >= _maxConcurrent) {
        final dropped = _bubbles.removeAt(0);
        _hovered.remove(dropped.id);
        _pinned.remove(dropped.id);
      }
      _bubbles.add(
        _Bubble(
          id: _nextId++,
          agentId: agentId,
          text: display,
          kind: kind,
          spawnedAt: DateTime.now(),
        ),
      );
    });
  }

  void _setHovered(int id, bool hovering) {
    if (hovering) {
      if (_hovered.add(id)) setState(() {});
    } else {
      if (_hovered.remove(id)) {
        // If we hovered past the natural fade-out window, give the overlay
        // a fresh fade-out so it doesn't pop out instantly on un-hover.
        final idx = _bubbles.indexWhere((x) => x.id == id);
        if (idx >= 0) {
          final b = _bubbles[idx];
          final age = DateTime.now().difference(b.spawnedAt);
          if (age >= _bubbleLife - _fadeOut) {
            _bubbles[idx] = _Bubble(
              id: b.id,
              agentId: b.agentId,
              text: b.text,
              kind: b.kind,
              spawnedAt: DateTime.now().subtract(_bubbleLife - _fadeOut),
            );
          }
        }
        setState(() {});
      }
    }
  }

  void _togglePinned(int id) {
    setState(() {
      if (!_pinned.remove(id)) {
        _pinned.add(id);
      } else {
        // Just unpinned — restart dwell so user gets a moment before fade.
        final idx = _bubbles.indexWhere((x) => x.id == id);
        if (idx >= 0) {
          final b = _bubbles[idx];
          _bubbles[idx] = _Bubble(
            id: b.id,
            agentId: b.agentId,
            text: b.text,
            kind: b.kind,
            spawnedAt: DateTime.now(),
          );
        }
      }
    });
  }

  String _agentLabel(String agentId) {
    final a = widget.session.agentById(agentId);
    if (a == null || a.name.trim().isEmpty) return '';
    return a.name.trim().toUpperCase();
  }

  /// Test hook: expose the on-screen rects of every visible bubble slot.
  /// A widget test asserts that no two rects intersect — that's the
  /// "no overlapping bubbles, ever" invariant in machine-checkable form.
  @visibleForTesting
  List<Rect> debugBubbleSlotRects() {
    final out = <Rect>[];
    for (final agentId in _bubbles.map((b) => b.agentId).toSet()) {
      final r = widget.anchors.rectOf(agentId);
      if (r == null) continue;
      // Slot lives directly above the card, same width.
      // Height is bounded by _maxPerAgent rows × ~44px.
      const slotHeight = _maxPerAgent * 44.0 + 8.0;
      out.add(Rect.fromLTWH(
        r.left,
        r.top - slotHeight,
        r.width,
        slotHeight,
      ));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.anchors,
      // No outer IgnorePointer: hit-testing is gated per-bubble so idle
      // overlays fall through to agent cards / traffic layer beneath.
      builder: (context, _) {
        // Group bubbles by agent so each agent gets ONE stacked slot.
        // Within the slot, bubbles are a vertical Column (newest at the
        // bottom, anchored to the card's top edge; older bubbles get
        // pushed upward by AnimatedSize). This makes same-agent overlap
        // structurally impossible. Slot width = card width, so two
        // agents whose cards don't overlap horizontally also can't
        // have overlapping bubble slots.
        final byAgent = <String, List<_Bubble>>{};
        for (final b in _bubbles) {
          (byAgent[b.agentId] ??= []).add(b);
        }
        return Stack(
          children: [
            for (final entry in byAgent.entries)
              _AgentBubbleSlot(
                key: ValueKey('slot-${entry.key}'),
                agentId: entry.key,
                bubbles: entry.value,
                rect: widget.anchors.rectOf(entry.key),
                stageCenter: _stageCenter(),
                agentLabel: _agentLabel(entry.key),
                life: _bubbleLife,
                fadeIn: _fadeIn,
                fadeOut: _fadeOut,
                hovered: _hovered,
                pinned: _pinned,
                onHoverChange: _setHovered,
                onTap: _togglePinned,
              ),
          ],
        );
      },
    );
  }

  /// Approximate stage center for radial direction of the bubble slot.
  /// We use the centroid of all anchor rects — when an orchestrator is
  /// present its rect dominates and the centroid lands close to it,
  /// which is exactly what we want for "grow outward".
  Offset _stageCenter() {
    var sx = 0.0;
    var sy = 0.0;
    var n = 0;
    final cfg = widget.session.config;
    final ids = <String>[
      cfg.orchestrator.id,
      cfg.finalEvaluator.id,
      ...cfg.agents.map((a) => a.id),
    ];
    for (final id in ids) {
      final r = widget.anchors.rectOf(id);
      if (r == null) continue;
      sx += r.center.dx;
      sy += r.center.dy;
      n += 1;
    }
    if (n == 0) return Offset.zero;
    return Offset(sx / n, sy / n);
  }
}

/// One slot per agent. Holds that agent's bubbles in a vertical Column
/// anchored to either the top OR bottom edge of the card depending on
/// which side faces "outward" (away from the stage centroid). Within
/// the slot, bubbles can never overlap each other (single column).
class _AgentBubbleSlot extends StatelessWidget {
  final String agentId;
  final List<_Bubble> bubbles;
  final Rect? rect;
  final Offset stageCenter;
  final String agentLabel;
  final Duration life;
  final Duration fadeIn;
  final Duration fadeOut;
  final Set<int> hovered;
  final Set<int> pinned;
  final void Function(int id, bool hovering) onHoverChange;
  final void Function(int id) onTap;

  const _AgentBubbleSlot({
    super.key,
    required this.agentId,
    required this.bubbles,
    required this.rect,
    required this.stageCenter,
    required this.agentLabel,
    required this.life,
    required this.fadeIn,
    required this.fadeOut,
    required this.hovered,
    required this.pinned,
    required this.onHoverChange,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final r = rect;
    if (r == null || bubbles.isEmpty) return const SizedBox.shrink();

    // Agents in the top half of the stage grow their slot DOWNWARD
    // (below the card); bottom-half agents grow UPWARD (above the
    // card). In both cases, motion is "outward from centroid", so
    // the slot never points back at the orchestrator.
    final growUp = r.center.dy >= stageCenter.dy;

    // Newest bubble is closest to the card edge; older bubbles drift
    // outward. Reverse the list when growing upward so the *visual*
    // bottom of the column (closest to card.top) is the newest.
    final ordered = growUp ? bubbles : bubbles.reversed.toList();

    final column = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final b in ordered)
          _SlotBubble(
            key: ValueKey(b.id),
            bubble: b,
            agentLabel: agentLabel,
            life: life,
            fadeIn: fadeIn,
            fadeOut: fadeOut,
            hovered: hovered.contains(b.id),
            pinned: pinned.contains(b.id),
            onHoverChange: (h) => onHoverChange(b.id, h),
            onTap: () => onTap(b.id),
          ),
      ],
    );

    // Slot width is clamped to the card width so adjacent agents'
    // slots can never share horizontal extent unless their cards do.
    // Slot height grows with content via Wrap/Column intrinsic sizing.
    if (growUp) {
      // Column lives ABOVE card.top. Anchor with bottom = r.top so
      // the column grows upward as bubbles are added.
      return Positioned(
        left: r.left,
        top: 0,
        width: r.width,
        height: r.top,
        child: Align(
          alignment: Alignment.bottomLeft,
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.bottomLeft,
            child: column,
          ),
        ),
      );
    } else {
      // Column lives BELOW card.bottom. Grows downward.
      return Positioned(
        left: r.left,
        top: r.bottom,
        width: r.width,
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topLeft,
          child: column,
        ),
      );
    }
  }
}

/// One bubble inside the per-agent slot. No Positioned. No jitter.
/// Just the chromeless text with fade/slide-in driven by elapsed age.
class _SlotBubble extends StatefulWidget {
  final _Bubble bubble;
  final String agentLabel;
  final Duration life;
  final Duration fadeIn;
  final Duration fadeOut;
  final bool hovered;
  final bool pinned;
  final ValueChanged<bool> onHoverChange;
  final VoidCallback onTap;

  const _SlotBubble({
    super.key,
    required this.bubble,
    required this.agentLabel,
    required this.life,
    required this.fadeIn,
    required this.fadeOut,
    required this.hovered,
    required this.pinned,
    required this.onHoverChange,
    required this.onTap,
  });

  @override
  State<_SlotBubble> createState() => _SlotBubbleState();
}

class _SlotBubbleState extends State<_SlotBubble>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    final age = DateTime.now().difference(widget.bubble.spawnedAt);
    if (age != _elapsed) {
      setState(() => _elapsed = age);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lifeMs = widget.life.inMilliseconds;
    final inMs = widget.fadeIn.inMilliseconds;
    final outMs = widget.fadeOut.inMilliseconds;
    final ageMs = _elapsed.inMilliseconds.clamp(0, lifeMs).toInt();

    final inT = (ageMs / inMs).clamp(0.0, 1.0);
    final inEased = Curves.easeOutCubic.transform(inT);
    final slideY = (1 - inEased) * 8.0;

    double opacity;
    final pinnedOrHovered = widget.pinned || widget.hovered;
    if (pinnedOrHovered) {
      opacity = inEased;
    } else if (ageMs >= lifeMs - outMs) {
      final outT =
          ((ageMs - (lifeMs - outMs)) / outMs).clamp(0.0, 1.0).toDouble();
      opacity = (1.0 - Curves.easeInQuad.transform(outT)) * inEased;
    } else {
      opacity = inEased;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: IgnorePointer(
        ignoring: !pinnedOrHovered,
        child: MouseRegion(
          onEnter: (_) => widget.onHoverChange(true),
          onExit: (_) => widget.onHoverChange(false),
          opaque: false,
          cursor: SystemMouseCursors.click,
          child: Opacity(
            opacity: opacity,
            child: Transform.translate(
              offset: Offset(0, slideY),
              child: GestureDetector(
                behavior: HitTestBehavior.deferToChild,
                onTap: widget.onTap,
                child: _BubbleText(
                  bubble: widget.bubble,
                  agentLabel: widget.agentLabel,
                  pinned: widget.pinned,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}


/// Chromeless body. White (fgPrimary) text on the existing dark surface.
/// No fill. No border. No shadow chrome. No bubble shape. No tail.
///
/// Optional eyebrow: a 1px leading rule + uppercase agent name above the
/// utterance. The rule's color is the only place the kind's accent shows
/// up — and even then it's a 1px line, not a fill.
class _BubbleText extends StatelessWidget {
  final _Bubble bubble;
  final String agentLabel;
  final bool pinned;

  const _BubbleText({
    required this.bubble,
    required this.agentLabel,
    required this.pinned,
  });

  Color get _accent {
    return switch (bubble.kind) {
      _BubbleKind.speak => DuckColors.accentCyan,
      _BubbleKind.askPool => DuckColors.accentPurple,
      _BubbleKind.askUser => DuckColors.accentDuck,
      _BubbleKind.poolReply => DuckColors.accentMint,
      _BubbleKind.userReply => DuckColors.accentDuck,
      _BubbleKind.userPing => DuckColors.accentDuck,
      _BubbleKind.done => DuckColors.stateOk,
      _BubbleKind.error => DuckColors.stateError,
    };
  }

  String get _eyebrowKindLabel {
    return switch (bubble.kind) {
      _BubbleKind.askPool => 'TO POOL',
      _BubbleKind.poolReply => 'POOL',
      _BubbleKind.askUser => 'ASKS YOU',
      _BubbleKind.userReply => 'YOU →',
      _BubbleKind.userPing => 'YOU →',
      _BubbleKind.done => 'DONE',
      _BubbleKind.error => 'ERROR',
      _BubbleKind.speak => '',
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

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 300),
      child: IntrinsicWidth(
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
                      color: accent.withValues(alpha: pinned ? 0.95 : 0.7),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      eyebrowText,
                      style: const TextStyle(
                        color: DuckColors.fgMuted,
                        fontSize: 9.5,
                        height: 1.0,
                        letterSpacing: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            Text(
              bubble.text,
              softWrap: true,
              style: TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 12.5,
                height: 1.4,
                letterSpacing: 0.05,
                fontWeight: FontWeight.w400,
                shadows: [
                  // Single tight shadow purely for legibility against
                  // bright bg pixels (diagonal-line drift, agent cards).
                  // Not chrome — invisible on dark, just disambiguates
                  // glyph edges where the layer overlaps a bright pixel.
                  Shadow(
                    color: DuckColors.bgDeepest.withValues(alpha: 0.85),
                    blurRadius: 6,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
