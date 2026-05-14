/// Agent Voice Panel
/// ==================
///
/// The "speech" surface of an agent card. Lives INSIDE the card (between
/// the identity header and the activity well), replacing the floating
/// [CouncilSpeechBubblesLayer] that used to render bubbles outside the
/// ring. The user's redesign brief (2026-05): "the speech bubbles to be
/// a part of their panels. it has to look right but its a necessity."
///
/// Surface composition:
///   • Eyebrow row — tone glyph + UPPERCASE agent label + status chip,
///     plus optional pool-targeting and mention chips.
///   • Primary narration line — up to 3 lines, driven by
///     [narrateAgent] (single source of truth — the floating layer used
///     the same function).
///   • Secondary line — "Next: …" or "Just did: …" if available.
///   • Streaming pulse — 3 fading dots + STREAMING label when chunks
///     are flowing.
///   • Flash sweep — a thin accent hairline that travels across the
///     top edge whenever the primary content changes.
///
/// Public surface contract:
///   • The constants [kActivityPrimaryText] / [kActivitySecondaryText]
///     are EXPORTED here so callers (and the opacity test) can find
///     them at this path. They previously lived in the now-deleted
///     `activity_bubble_card.dart`.
///   • The DecoratedBox that paints the voice section background is
///     wrapped in `// VOICE_BG_BEGIN` / `// VOICE_BG_END` markers so
///     the static-source opacity guard in
///     `test/widgets/council/council_speech_bubble_opacity_test.dart`
///     can lock the fill to alpha == 1.0.
///
/// Implementation notes:
///   • NO new per-card vsync. The flash-sweep and typing-pulse animations
///     are driven by the host card's existing `_idle` controller
///     (passed in as `breathT`) plus a small one-shot
///     [AnimationController] for the flash-sweep edge trigger.
///   • The mention chip subscribes to the controller's event stream
///     directly so the recipient's panel reacts even when the speaker's
///     status/transcript hasn't otherwise changed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../l10n/strings.dart';
import '../../../providers/app_state.dart';
import '../../../services/council/council_models.dart';
import '../../../services/council/council_task_ledger.dart';
import '../../../theme/app_colors.dart';
import 'activity_models.dart';

/// CSS-class style shared text style for the voice panel's primary
/// narration line. Per-bubble tone is conveyed via the accent stroke /
/// chip colours, NOT by replacing this style wholesale — the user
/// expects a stable typographic rhythm across every agent.
const TextStyle kActivityPrimaryText = TextStyle(
  color: DuckColors.fgPrimary,
  fontSize: 13,
  height: 1.36,
  fontWeight: FontWeight.w500,
  letterSpacing: 0.05,
);

const TextStyle kActivitySecondaryText = TextStyle(
  color: DuckColors.fgMuted,
  fontSize: 11,
  height: 1.32,
  fontWeight: FontWeight.w500,
);

/// Integrated speech surface for one agent. Mounted by
/// `_CouncilAgentSectorState._buildCard` between the identity header
/// and the activity / cadence-spectrum region.
///
/// `breathT` is the host card's `_idle` value (0..1, bounces) — drives
/// the border-top hairline pulse. Reusing the host ticker honours the
/// landmine "do NOT add a per-card vsync ticker for the voice section."
class AgentVoicePanel extends StatefulWidget {
  const AgentVoicePanel({
    super.key,
    required this.agent,
    required this.isOrchestrator,
    required this.breathT,
  });

  final CouncilAgent agent;
  final bool isOrchestrator;
  final double breathT;

  @override
  State<AgentVoicePanel> createState() => _AgentVoicePanelState();
}

class _AgentVoicePanelState extends State<AgentVoicePanel>
    with TickerProviderStateMixin {
  /// One-shot edge-trigger for the flash-sweep painter. Repaints the
  /// top hairline travelling across the panel whenever the primary
  /// narration content changes.
  late final AnimationController _flashSweep;

  StreamSubscription<CouncilEvent>? _eventSub;

  /// Most recent mention-chip state. Set when an `agentPeerMention`
  /// event names this agent's id in its `mentions` payload. Cleared
  /// when the fade-out window elapses (see [kMentionDisplay]).
  _MentionChipState? _mention;
  Timer? _mentionTimer;

  /// Last seen primary narration line — used to fire the flash sweep
  /// on content changes ONLY (not on every rebuild).
  String? _lastPrimary;

  /// Most recent recorded askPool event from this agent — used to
  /// surface the targeting chip while the corresponding pool question
  /// is still open in `session.poolQuestions`.
  List<String> _targetingIds = const <String>[];

  @override
  void initState() {
    super.initState();
    _flashSweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bindEvents();
    });
  }

  void _bindEvents() {
    final controller = context.read<AppState>().council;
    _eventSub?.cancel();
    _eventSub = controller.events.listen(_onCouncilEvent);
  }

  void _onCouncilEvent(CouncilEvent event) {
    if (!mounted) return;
    switch (event.type) {
      case CouncilEventType.agentPeerMention:
        if (event.fromAgentId == widget.agent.id) break;
        final raw = event.data['mentions'];
        if (raw is! List) break;
        if (!raw.contains(widget.agent.id)) break;
        _showMention(event.fromAgentId);
      case CouncilEventType.askedPool:
        if (event.fromAgentId != widget.agent.id) break;
        final raw = event.data['resolvedTargets'];
        if (raw is! List) break;
        final ids = <String>[
          for (final r in raw)
            if (r is String && r.isNotEmpty) r,
        ];
        if (ids.isEmpty) break;
        setState(() => _targetingIds = ids);
    }
  }

  void _showMention(String speakerId) {
    final speakerName = _displayNameFor(speakerId);
    if (speakerName == null) return;
    _mentionTimer?.cancel();
    final chip = _MentionChipState(
      speakerId: speakerId,
      speakerName: speakerName,
      shownAt: DateTime.now(),
    );
    setState(() => _mention = chip);
    _mentionTimer = Timer(kMentionDisplay, () {
      if (!mounted) return;
      // Only clear when this is still the active mention — guards
      // against a second speaker overwriting us mid-window.
      if (_mention?.shownAt == chip.shownAt) {
        setState(() => _mention = null);
      }
    });
  }

  String? _displayNameFor(String agentId) {
    if (agentId.isEmpty) return null;
    final session = context.read<AppState>().council.session;
    if (session == null) return null;
    final candidate = session.agentById(agentId);
    if (candidate == null) return null;
    final name = candidate.name.trim();
    return name.isEmpty ? null : name;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    _mentionTimer?.cancel();
    _flashSweep.dispose();
    super.dispose();
  }

  /// Trim the trailing target ids whose pool question has already been
  /// resolved. Returns the names to show; empty list ⇒ no chip.
  List<String> _resolveActiveTargetNames(CouncilSession? session) {
    if (session == null || _targetingIds.isEmpty) return const [];
    final hasOpenQuestion = session.poolQuestions.any(
      (q) => q.fromAgentId == widget.agent.id && !q.resolved,
    );
    if (!hasOpenQuestion) {
      // Schedule a microtask to clear the cached ids on next frame —
      // safe inside the build pipeline because we use addPostFrameCallback.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_targetingIds.isNotEmpty) {
          setState(() => _targetingIds = const []);
        }
      });
      return const [];
    }
    final names = <String>[];
    for (final id in _targetingIds) {
      final name = _displayNameFor(id);
      if (name != null) names.add(name);
    }
    return names;
  }

  @override
  Widget build(BuildContext context) {
    // Selecting just the session keeps rebuilds tight — we don't need
    // the entire AppState tree to invalidate this panel on every
    // ancillary change.
    final session =
        context.select<AppState, CouncilSession?>((s) => s.council.session);
    final agent = widget.agent;
    final latestTask = _latestTaskFor(session, agent.id);
    final live = _liveStateFor(session, agent.id);
    final narration = narrateAgent(
      agent: agent,
      latestTask: latestTask,
      live: live,
      isOrchestrator: widget.isOrchestrator,
      now: DateTime.now(),
    );

    // Fire the flash sweep when the primary line changes.
    if (_lastPrimary != narration.primary) {
      _lastPrimary = narration.primary;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _flashSweep.forward(from: 0);
      });
    }

    final accent = _accentFor(narration.tone);
    final targetNames = _resolveActiveTargetNames(session);

    // Border-top hairline alpha breathes with the host card's idle
    // controller for tones that read as "alive". Idle / done / success
    // panels hold steady so finished cards don't keep pulsing.
    final breathing = _isBreathingTone(narration.tone);
    final hairlineAlphaBase = narration.tone == NarrationTone.alert ? 0.72 : 0.34;
    final hairlineAlpha = breathing
        ? hairlineAlphaBase + 0.18 * widget.breathT
        : hairlineAlphaBase;

    return AnimatedBuilder(
      animation: _flashSweep,
      builder: (context, _) {
        return _buildShell(
          accent: accent,
          narration: narration,
          hairlineAlpha: hairlineAlpha,
          targetNames: targetNames,
          session: session,
        );
      },
    );
  }

  Widget _buildShell({
    required Color accent,
    required AgentNarration narration,
    required double hairlineAlpha,
    required List<String> targetNames,
    required CouncilSession? session,
  }) {
    return Container(
      // VOICE_BG_BEGIN — voice panel surface FILL must be fully opaque
      // (alpha == 1.0) so narration text is readable over the card
      // chrome (digital grid + scan line). The opacity test scans
      // inside these markers and rejects any `.withValues(alpha: <1)`,
      // `.withOpacity(<1)`, or `Color(0x__...)` where the alpha byte
      // is < 0xFF. The glass-seam outline + breathing top hairline
      // are intentionally OUTSIDE these markers — the hairline must
      // stay translucent or the surface stops reading as "lit".
      decoration: const BoxDecoration(
        color: DuckColors.councilBubbleBg,
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      // VOICE_BG_END
      // Glass seam OUTLINE is the visual separator between the voice
      // section and the regions above + below. Uniform color so it
      // composes with the borderRadius (Flutter rejects radius on a
      // non-uniform Border).
      foregroundDecoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Breathing top-edge accent hairline. Drawn AS A CHILD (not
          // as a Border on the decoration) so we can keep the tone
          // accent independent from the uniform glass-seam outline.
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              child: Container(
                height: 0.9,
                decoration: BoxDecoration(
                  color: accent.withValues(alpha: hairlineAlpha),
                ),
              ),
            ),
          ),
          Padding(
            // Vertical padding kept tight (7 not 9) — the voice panel
            // sits inside an already-bordered card whose max height
            // is ~290 px. Every extra px of breathing room here
            // multiplies into a real overflow risk at the bottom of
            // the agent card column (see the cardH math in
            // `council_theater.dart::_layoutAgents`).
            padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildEyebrow(
                  accent: accent,
                  narration: narration,
                  targetNames: targetNames,
                ),
                const SizedBox(height: 4),
                _buildPrimaryLine(narration),
                if (narration.secondary.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  _buildSecondaryLine(narration),
                ],
                if (narration.streaming) ...[
                  const SizedBox(height: 4),
                  _VoiceTypingPulse(accent: accent, t: widget.breathT),
                ],
              ],
            ),
          ),
          // Flash sweep — only paints during the controller's 720ms
          // forward window, then short-circuits so we don't burn
          // paints on idle frames.
          if (_flashSweep.isAnimating)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _VoiceFlashSweepPainter(
                    t: _flashSweep.value,
                    accent: accent,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildPrimaryLine(AgentNarration narration) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 280),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) => FadeTransition(
        opacity: anim,
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, 0.18),
            end: Offset.zero,
          ).animate(anim),
          child: child,
        ),
      ),
      // Primary narration line caps at 2 visible lines. The earlier
      // 3-line cap was the dominant contributor to the agent-card
      // bottom-edge RenderFlex overflow (see knowledgebase entry
      // "Council Agent Card Vertical Budget"). One ellipsised line
      // is already plenty to read the narrative beat — the full text
      // is available via the inspector + transcript well.
      child: Text(
        narration.primary,
        key: ValueKey(narration.primary),
        softWrap: true,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: kActivityPrimaryText,
      ),
    );
  }

  Widget _buildSecondaryLine(AgentNarration narration) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      // Secondary line capped at 1 visible line for the same overflow
      // budget reason above. Secondary line is almost always
      // "Just did: …" / "Next: …" — short by construction.
      child: Text(
        narration.secondary,
        key: ValueKey(narration.secondary),
        softWrap: true,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: kActivitySecondaryText,
      ),
    );
  }

  Widget _buildEyebrow({
    required Color accent,
    required AgentNarration narration,
    required List<String> targetNames,
  }) {
    final agentLabel = _agentLabel();
    return Row(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Tone glyph — small filled square with a halo, drives the
        // colour vocabulary alongside the eyebrow text.
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.55),
                blurRadius: 5,
              ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            agentLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent.withValues(alpha: 0.96),
              fontSize: 10.2,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.85,
            ),
          ),
        ),
        const SizedBox(width: 7),
        _VoiceChip(
          label: narration.statusLabel,
          accent: accent,
        ),
        if (targetNames.isNotEmpty) ...[
          const SizedBox(width: 6),
          Flexible(
            child: _VoiceChip(
              label: S.councilVoicePanelTargetingFmt(targetNames.join(', ')),
              accent: DuckColors.accentPurple,
              tooltip: S.councilVoicePanelTargetingTooltip(
                targetNames.join(', '),
              ),
              fade: true,
            ),
          ),
        ],
        if (_mention != null) ...[
          const SizedBox(width: 6),
          Flexible(
            child: _MentionChip(
              speakerName: _mention!.speakerName,
              accent: accent,
              shownAt: _mention!.shownAt,
            ),
          ),
        ],
      ],
    );
  }

  String _agentLabel() {
    final name = widget.agent.name.trim();
    if (name.isEmpty) {
      return widget.isOrchestrator
          ? S.councilOrchestrator.toUpperCase()
          : '';
    }
    return name.toUpperCase();
  }

  CouncilTask? _latestTaskFor(CouncilSession? session, String agentId) {
    if (session == null) return null;
    CouncilTask? latest;
    for (final t in session.tasks) {
      if (t.agentId != agentId) continue;
      if (latest == null || t.updatedAt.isAfter(latest.updatedAt)) {
        latest = t;
      }
    }
    return latest;
  }

  /// Synthesise a fresh [AgentLiveState] from the session each rebuild.
  /// The floating bubble layer used to keep this as long-lived state;
  /// here we derive it on demand from the same source (chunk/done/error
  /// events + the active flash) so we don't double-account the data.
  AgentLiveState _liveStateFor(CouncilSession? session, String agentId) {
    final state = AgentLiveState(agentId: agentId);
    if (session == null) return state;
    final now = DateTime.now();
    final events = session.events;
    // Walk newest → oldest until we've populated everything we need.
    for (var i = events.length - 1; i >= 0; i--) {
      final e = events[i];
      if (e.fromAgentId != agentId && e.toAgentId != agentId) continue;
      final age = now.difference(e.createdAt);
      switch (e.type) {
        case CouncilEventType.agentChunk:
          if (e.fromAgentId != agentId) break;
          state.lastChunkAt ??= e.createdAt;
        case CouncilEventType.agentDone:
        case CouncilEventType.evaluatorDone:
          if (e.fromAgentId != agentId) break;
          state.doneAt ??= e.createdAt;
        case CouncilEventType.agentError:
        case CouncilEventType.agentStalled:
          if (e.fromAgentId != agentId) break;
          state.erroredAt ??= e.createdAt;
      }
      // Compose an active flash from the most recent event that maps
      // to one and isn't expired.
      if (state.flash == null) {
        final candidate = flashForEvent(
          event: e,
          selfAgentId: agentId,
          now: e.createdAt,
        );
        if (candidate != null) {
          final duration = candidate.expiresAt.difference(e.createdAt);
          if (age < duration) {
            state.flash = ActivityFlash(
              text: candidate.text,
              kind: candidate.kind,
              expiresAt: candidate.expiresAt,
            );
          }
        }
      }
      // Early-out: if we have flash + chunk + done + error captured,
      // older events can't add anything. Cheap on the common path.
      if (state.flash != null &&
          state.lastChunkAt != null &&
          (state.doneAt != null || state.erroredAt != null)) {
        break;
      }
    }
    return state;
  }

  bool _isBreathingTone(NarrationTone t) {
    return t == NarrationTone.working ||
        t == NarrationTone.awaiting ||
        t == NarrationTone.alert;
  }

  Color _accentFor(NarrationTone tone) {
    // Same tone → color mapping the floating bubble layer used, so
    // the visual vocabulary is preserved verbatim across the
    // redesign.
    switch (tone) {
      case NarrationTone.idle:
        return DuckColors.councilAccentDim;
      case NarrationTone.working:
        return DuckColors.accentCyan;
      case NarrationTone.awaiting:
        return DuckColors.accentDuck;
      case NarrationTone.alert:
        return DuckColors.stateError;
      case NarrationTone.success:
        return DuckColors.accentMint;
    }
  }
}

/// How long a mention chip stays mounted on the recipient's voice
/// panel. ~2.5s window: 180ms fade-in + 2200ms hold + 380ms fade-out.
const Duration kMentionDisplay = Duration(milliseconds: 2760);

class _MentionChipState {
  final String speakerId;
  final String speakerName;
  final DateTime shownAt;
  const _MentionChipState({
    required this.speakerId,
    required this.speakerName,
    required this.shownAt,
  });
}

/// Pill chip rendered in the eyebrow row. Used by the status chip,
/// the pool targeting chip, and (via [_MentionChip]) the recipient-side
/// mention reinforcement. Kept small + outline-style so multiple chips
/// can sit side-by-side without dominating the row.
class _VoiceChip extends StatelessWidget {
  const _VoiceChip({
    required this.label,
    required this.accent,
    this.tooltip,
    this.fade = false,
  });

  final String label;
  final Color accent;
  final String? tooltip;

  /// When true, render at slightly reduced contrast — used for chips
  /// that are auxiliary (e.g. targeting list) so the status chip
  /// still wins the eye.
  final bool fade;

  @override
  Widget build(BuildContext context) {
    final alphaBg = fade ? 0.13 : 0.16;
    final alphaBorder = fade ? 0.36 : 0.42;
    final alphaText = fade ? 0.88 : 0.96;
    final pill = Container(
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: alphaBg),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent.withValues(alpha: alphaBorder),
          width: 0.6,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: accent.withValues(alpha: alphaText),
          fontSize: 9.4,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.7,
          height: 1.0,
        ),
      ),
    );
    if (tooltip == null || tooltip!.isEmpty) return pill;
    return Tooltip(message: tooltip!, child: pill);
  }
}

class _MentionChip extends StatefulWidget {
  const _MentionChip({
    required this.speakerName,
    required this.accent,
    required this.shownAt,
  });

  final String speakerName;
  final Color accent;
  final DateTime shownAt;

  @override
  State<_MentionChip> createState() => _MentionChipStateWidget();
}

class _MentionChipStateWidget extends State<_MentionChip>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  static const _fadeIn = Duration(milliseconds: 180);
  static const _hold = Duration(milliseconds: 2200);
  static const _fadeOut = Duration(milliseconds: 380);
  static const _total = Duration(milliseconds: 2760);

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: _total,
    )..forward();
  }

  @override
  void didUpdateWidget(covariant _MentionChip old) {
    super.didUpdateWidget(old);
    if (widget.shownAt != old.shownAt) {
      _ctl.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctl,
      builder: (context, _) {
        final ms = (_ctl.value * _total.inMilliseconds);
        final inMs = _fadeIn.inMilliseconds;
        final outStartMs = inMs + _hold.inMilliseconds;
        double opacity;
        if (ms < inMs) {
          opacity = (ms / inMs).clamp(0.0, 1.0);
        } else if (ms < outStartMs) {
          opacity = 1.0;
        } else {
          final fadeMs = (ms - outStartMs).clamp(0.0, _fadeOut.inMilliseconds.toDouble());
          opacity = (1.0 - fadeMs / _fadeOut.inMilliseconds).clamp(0.0, 1.0);
        }
        if (opacity <= 0.0) return const SizedBox.shrink();
        return Opacity(
          opacity: opacity,
          child: _VoiceChip(
            label: S.councilVoicePanelMentionedByFmt(widget.speakerName),
            accent: widget.accent,
            tooltip: S.councilVoicePanelMentionedByTooltip(widget.speakerName),
          ),
        );
      },
    );
  }
}

/// 3 dots that fade in/out in sequence to indicate the agent is
/// actively streaming tokens. Driven by `breathT` from the host card
/// so we don't add a per-card vsync (landmine compliance).
class _VoiceTypingPulse extends StatelessWidget {
  const _VoiceTypingPulse({required this.accent, required this.t});
  final Color accent;
  final double t;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          _PulseDot(
            opacity: _dotOpacity(t, i),
            accent: accent,
          ),
          if (i < 2) const SizedBox(width: 4),
        ],
        const SizedBox(width: 7),
        Text(
          S.councilActivityStreaming,
          style: TextStyle(
            color: accent.withValues(alpha: 0.80),
            fontSize: 9.4,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
      ],
    );
  }

  double _dotOpacity(double t, int i) {
    final phase = (t * 3 - i / 1.6) % 1.0;
    final wave = math.sin(phase * math.pi).clamp(0.0, 1.0).toDouble();
    return 0.25 + 0.75 * wave;
  }
}

class _PulseDot extends StatelessWidget {
  const _PulseDot({required this.opacity, required this.accent});
  final double opacity;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 5.5,
      height: 5.5,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

/// Flash-sweep painter: travels a thin accent hairline across the top
/// edge of the voice panel whenever the primary narration content
/// changes. Same visual contract as the legacy floating-bubble sweep
/// — same easing, same 48px highlight width — so the moment-of-news
/// vocabulary stays consistent for users coming from the prior build.
class _VoiceFlashSweepPainter extends CustomPainter {
  _VoiceFlashSweepPainter({required this.t, required this.accent});
  final double t;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 4 || size.height < 4) return;
    final eased = Curves.easeInOutQuad.transform(t.clamp(0.0, 1.0));
    const w = 48.0;
    final x = -w + (size.width + w * 2) * eased;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: 0.85),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(x, 0, w, 2.2));
    canvas.drawRect(Rect.fromLTWH(x, 0, w, 2.2), paint);
  }

  @override
  bool shouldRepaint(covariant _VoiceFlashSweepPainter old) =>
      old.t != t || old.accent != accent;
}
