/// Council Stage Anchors + Legacy Bubble Spawn API
/// =================================================
///
/// Hosts the shared stage layout contract ([CouncilStageAnchors]) plus the
/// manual-spawn API ([BubbleController] / [BubbleKind]) that legacy
/// callers (system announcements, debug tooling) still drive into the
/// agent surface.
///
/// History: this file used to render an entire floating-bubble overlay
/// (`CouncilSpeechBubblesLayer`) that placed per-agent narration cards
/// outside the ring with leader lines + collision-aware placement. That
/// surface was retired in the 2026-05 voice-panel redesign — narration
/// now lives inside each agent card via `speech/agent_voice_panel.dart`.
///
/// What stayed and why:
///   * [CouncilStageAnchors] — the traffic layer, discourse layer,
///     pentest attack lines and the theater itself all read this
///     anchor map to position arcs / packets / chrome. Deleting it
///     would cascade into every other layer.
///   * [BubbleController] / [BubbleKind] / [legacyBubbleKindToFlash] —
///     the public spawn contract is preserved so external callers
///     keep compiling. Spawned bubbles still route into the same
///     activity-flash pipeline ([FlashKind] in
///     `speech/activity_models.dart`) the voice panel consumes.
///
/// Narration composition + event → flash mapping live in
/// `speech/activity_models.dart` (untouched by this refactor). Visual
/// rendering lives in `speech/agent_voice_panel.dart`.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'speech/activity_models.dart';

// ════════════════════════════════════════════════════════════════
// Stage anchors — unchanged contract. Other layers (traffic, discourse,
// pentest attack lines) read this to position their geometry relative
// to the card layout the theater computes each frame.
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
// can be drained by anyone subscribing to the controller listener;
// the voice panel doesn't consume these directly today but the
// surface is kept stable for compatibility with old test / debug
// code paths.
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
  final List<BubbleSpawnRequest> _pending = [];

  void spawn(
    String originId,
    String text, {
    String? replyTo,
    BubbleKind kind = BubbleKind.speak,
  }) {
    if (originId.isEmpty || text.trim().isEmpty) return;
    _pending.add(
      BubbleSpawnRequest(originId: originId, text: text, kind: kind),
    );
    notifyListeners();
  }

  /// Returns the queued spawn requests and clears the buffer.
  List<BubbleSpawnRequest> drain() {
    if (_pending.isEmpty) return const [];
    final out = List<BubbleSpawnRequest>.from(_pending);
    _pending.clear();
    return out;
  }
}

class BubbleSpawnRequest {
  final String originId;
  final String text;
  final BubbleKind kind;
  const BubbleSpawnRequest({
    required this.originId,
    required this.text,
    required this.kind,
  });
}

/// Translate a [BubbleKind] from the legacy spawn API to the
/// canonical [FlashKind] vocabulary the voice panel + narration
/// pipeline use.
FlashKind legacyBubbleKindToFlash(BubbleKind k) {
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
