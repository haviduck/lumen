/// Council Phase Transition Overlay — "Curtain rise on a new act"
/// ================================================================
///
/// A transient full-stage cinematic overlay that fires when the
/// orchestrator declares a new phase via `council_phase`. Before this
/// existed, a phase transition was registered only by a single tick
/// forward on `CouncilPhaseStrip` — visually almost nothing. This
/// overlay turns the transition into a deliberate theatrical beat:
///
///   * Stage tint sweep — a wash of the destination phase's signature
///     color travels diagonally across the stage at peak ~0.10 alpha.
///   * Centred phase headline — the phase name in large, heavily
///     letter-spaced caps, fading in for 200 ms, holding for ~600 ms,
///     fading out over 300 ms. The orchestrator's rationale (if any)
///     sits beneath in smaller muted type for the same window.
///   * Particle burst — a ring of ~24 small dots bursts outward from
///     stage center, alpha 0.6 → 0.0, radius 8 → 200 px over 800 ms.
///   * Underline accent — a short bar in the new phase's color sits
///     directly under the headline for the same hold + fade window.
///
/// Composition rules (non-negotiable):
///   * The overlay is `IgnorePointer: true` — must never block clicks
///     on the user prompt panel, inspector, or finished overlay.
///   * Mounts ABOVE the agent ring + traffic + discourse, BELOW the
///     modal overlays (user prompt, inspector, finished, ping).
///   * No layout disruption — the agent cards do not move. The cinema
///     is OVERLAY-only.
///
/// Trigger: the widget watches `session.phaseHistory.length`. When the
/// list grows by one, the new last entry is the transition. The
/// overlay then plays its single beat and returns to dormant. The
/// `_seenLength` counter keeps a re-render from re-firing on the same
/// transition. This pattern mirrors the voice panel's
/// flash-sweep edge trigger — single one-shot AnimationController, no
/// per-overlay ticker / repeating vsync.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// How long the cinematic beat plays end-to-end. Picked to feel like
/// a theatrical beat — short enough to never feel slow, long enough
/// to register.
const Duration kPhaseTransitionTotal = Duration(milliseconds: 1400);

/// Sub-windows inside the total beat. Sum to <= kPhaseTransitionTotal.
const Duration kPhaseTintRise = Duration(milliseconds: 320);
const Duration kPhaseTintFall = Duration(milliseconds: 480);
const Duration kPhaseHeadlineFadeIn = Duration(milliseconds: 200);
const Duration kPhaseHeadlineHold = Duration(milliseconds: 600);
const Duration kPhaseHeadlineFadeOut = Duration(milliseconds: 300);
const Duration kPhaseParticleLife = Duration(milliseconds: 800);

class CouncilPhaseTransitionOverlay extends StatefulWidget {
  const CouncilPhaseTransitionOverlay({
    super.key,
    required this.session,
  });

  /// The session whose phaseHistory drives this overlay. We compare
  /// `phaseHistory.length` against an internal counter and play one
  /// beat each time the list grows.
  final CouncilSession session;

  @override
  State<CouncilPhaseTransitionOverlay> createState() =>
      _CouncilPhaseTransitionOverlayState();
}

class _CouncilPhaseTransitionOverlayState
    extends State<CouncilPhaseTransitionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  /// Length of `phaseHistory` we have already animated. New entries
  /// past this index trigger a fresh play. Initialised to the
  /// current length on mount so we don't re-fire historical
  /// transitions on a resumed session.
  int _seenLength = 0;

  /// The entry that drives the current play — captured from the tail
  /// of `phaseHistory` at trigger time. Null while dormant.
  CouncilPhaseEntry? _activeEntry;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: kPhaseTransitionTotal,
    );
    _seenLength = widget.session.phaseHistory.length;
  }

  @override
  void didUpdateWidget(covariant CouncilPhaseTransitionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeFire();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _maybeFire() {
    final hist = widget.session.phaseHistory;
    if (hist.length <= _seenLength) return;
    _seenLength = hist.length;
    _activeEntry = hist.last;
    // Defer the forward to a post-frame callback so we never call
    // setState/animate during a parent build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _ctl.forward(from: 0);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Catch transitions that landed before this build settled — keep
    // didUpdateWidget as the primary path but this safety net handles
    // edge cases where the parent forgets to pass a fresh widget.
    if (widget.session.phaseHistory.length > _seenLength) {
      _maybeFire();
    }

    final entry = _activeEntry;
    if (entry == null) return const SizedBox.shrink();

    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (context, _) {
          if (!_ctl.isAnimating && _ctl.value == 0) {
            // Dormant — paint nothing so the overlay has zero cost
            // between transitions.
            return const SizedBox.shrink();
          }
          return _OverlayPaint(
            t: _ctl.value,
            entry: entry,
          );
        },
      ),
    );
  }
}

/// Phase color signature — drives the tint sweep, particle burst, and
/// the headline underline accent. Kept inside this file so the
/// vocabulary is co-located with the visual that consumes it.
Color phaseTransitionAccentFor(CouncilPhase phase) {
  switch (phase) {
    case CouncilPhase.discovery:
      return DuckColors.accentCyan;
    case CouncilPhase.architecture:
      return DuckColors.accentPurple;
    case CouncilPhase.build:
      return DuckColors.accentDuck;
    case CouncilPhase.review:
      // "Review" reads as agents attacking each other's work — a
      // muted warning tone, not a soft "complete". Using stateError
      // at low alpha (per usage) makes the transition feel tense
      // without being alarming.
      return DuckColors.stateError;
    case CouncilPhase.polish:
      return DuckColors.accentMint;
    case CouncilPhase.ship:
      return DuckColors.accentMint;
  }
}

String phaseTransitionLabelFor(CouncilPhase phase) {
  switch (phase) {
    case CouncilPhase.discovery:
      return S.councilPhaseDiscovery;
    case CouncilPhase.architecture:
      return S.councilPhaseArchitecture;
    case CouncilPhase.build:
      return S.councilPhaseBuild;
    case CouncilPhase.review:
      return S.councilPhaseReview;
    case CouncilPhase.polish:
      return S.councilPhasePolish;
    case CouncilPhase.ship:
      return S.councilPhaseShip;
  }
}

class _OverlayPaint extends StatelessWidget {
  const _OverlayPaint({required this.t, required this.entry});

  final double t;
  final CouncilPhaseEntry entry;

  @override
  Widget build(BuildContext context) {
    final accent = phaseTransitionAccentFor(entry.phase);
    final label = phaseTransitionLabelFor(entry.phase);
    final rationale = entry.rationale.trim();
    final ms = t * kPhaseTransitionTotal.inMilliseconds;

    // ── Tint sweep envelope ────────────────────────────────────────
    double tintAlpha;
    final riseMs = kPhaseTintRise.inMilliseconds;
    final fallMs = kPhaseTintFall.inMilliseconds;
    if (ms < riseMs) {
      tintAlpha = (ms / riseMs).clamp(0.0, 1.0) * 0.10;
    } else if (ms < riseMs + fallMs) {
      tintAlpha = (1.0 - ((ms - riseMs) / fallMs).clamp(0.0, 1.0)) * 0.10;
    } else {
      tintAlpha = 0.0;
    }

    // ── Headline envelope ──────────────────────────────────────────
    double headlineOpacity = 0.0;
    final inMs = kPhaseHeadlineFadeIn.inMilliseconds;
    final holdMs = kPhaseHeadlineHold.inMilliseconds;
    final outMs = kPhaseHeadlineFadeOut.inMilliseconds;
    if (ms < inMs) {
      headlineOpacity = (ms / inMs).clamp(0.0, 1.0);
    } else if (ms < inMs + holdMs) {
      headlineOpacity = 1.0;
    } else if (ms < inMs + holdMs + outMs) {
      headlineOpacity =
          (1.0 - ((ms - inMs - holdMs) / outMs).clamp(0.0, 1.0));
    }

    // ── Headline lift on entry (rises 18 px during fade-in) ────────
    double headlineLift;
    if (ms < inMs) {
      headlineLift = 18.0 * (1.0 - (ms / inMs)).clamp(0.0, 1.0);
    } else {
      headlineLift = 0.0;
    }

    // ── Particle burst envelope ────────────────────────────────────
    final particleMs = kPhaseParticleLife.inMilliseconds;
    final particleT = (ms / particleMs).clamp(0.0, 1.0);

    return Stack(
      fit: StackFit.expand,
      children: [
        // Tint sweep — diagonal gradient wash, full stage width.
        if (tintAlpha > 0.001)
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: tintAlpha),
                    accent.withValues(alpha: tintAlpha * 0.4),
                    Colors.transparent,
                  ],
                  stops: const [0.0, 0.55, 1.0],
                ),
              ),
            ),
          ),

        // Particle ring — bursts outward from stage center.
        if (particleT < 1.0)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _PhaseParticlePainter(t: particleT, accent: accent),
              ),
            ),
          ),

        // Headline + rationale, centred — driven by their own opacity
        // envelope so they outlast the tint sweep slightly.
        if (headlineOpacity > 0.001)
          Center(
            child: Opacity(
              opacity: headlineOpacity,
              child: Transform.translate(
                offset: Offset(0, headlineLift),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PhaseHeadlineGlyph(label: label, accent: accent),
                    const SizedBox(height: 10),
                    Container(
                      width: 96,
                      height: 2,
                      decoration: BoxDecoration(
                        color: accent.withValues(alpha: 0.95),
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: [
                          BoxShadow(
                            color: accent.withValues(alpha: 0.65),
                            blurRadius: 12,
                            spreadRadius: 0.5,
                          ),
                        ],
                      ),
                    ),
                    if (rationale.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      Container(
                        constraints: const BoxConstraints(maxWidth: 580),
                        child: Text(
                          rationale,
                          textAlign: TextAlign.center,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: DuckColors.fgSecondary
                                .withValues(alpha: 0.92),
                            fontSize: 13.5,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 1.4,
                            height: 1.35,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The big phase headline — letter-spaced caps with a faint accent
/// glow behind the type so the word reads as "lit", not pasted on.
class _PhaseHeadlineGlyph extends StatelessWidget {
  const _PhaseHeadlineGlyph({required this.label, required this.accent});

  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final display = label.toUpperCase();
    return Stack(
      alignment: Alignment.center,
      children: [
        // Halo — same text, blurred + accent-tinted, sits behind the
        // primary type. Cheap one-pass blur from `ImageFilter.blur`.
        ImageFiltered(
          imageFilter: ui.ImageFilter.blur(sigmaX: 8, sigmaY: 8),
          child: Text(
            display,
            style: TextStyle(
              color: accent.withValues(alpha: 0.6),
              fontSize: 44,
              fontWeight: FontWeight.w900,
              letterSpacing: 8.0,
              height: 1.0,
            ),
          ),
        ),
        Text(
          display,
          style: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 44,
            fontWeight: FontWeight.w900,
            letterSpacing: 8.0,
            height: 1.0,
          ),
        ),
      ],
    );
  }
}

class _PhaseParticlePainter extends CustomPainter {
  _PhaseParticlePainter({required this.t, required this.accent});

  final double t;
  final Color accent;

  static const int _count = 24;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    if (t >= 1.0) return;
    final center = Offset(size.width / 2, size.height / 2);
    final eased = Curves.easeOutCubic.transform(t);
    final radius = 8.0 + 192.0 * eased;
    final alpha = (0.6 * (1.0 - t)).clamp(0.0, 0.6);
    final paint = Paint()..color = accent.withValues(alpha: alpha);
    for (var i = 0; i < _count; i++) {
      final theta = (i / _count) * math.pi * 2;
      final dx = center.dx + math.cos(theta) * radius;
      final dy = center.dy + math.sin(theta) * radius;
      canvas.drawCircle(Offset(dx, dy), 2.4, paint);
    }
    // Soft inner ring — a single low-alpha stroke gives the burst a
    // visual "core" so the eye reads it as one event, not 24.
    final ringPaint = Paint()
      ..color = accent.withValues(alpha: alpha * 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(center, radius, ringPaint);
  }

  @override
  bool shouldRepaint(covariant _PhaseParticlePainter old) {
    return old.t != t || old.accent != accent;
  }
}
