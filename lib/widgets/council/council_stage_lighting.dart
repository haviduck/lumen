/// Council Stage Lighting
/// =======================
///
/// A mood overlay that tints the chamber with a colour reflecting the
/// council's current state. Sits ABOVE the chamber backdrop, BELOW
/// the traffic mesh / discourse layer / agent cards — its job is to
/// shift the room's "lighting" with the mood of the work, not to
/// compete with anything the user is reading.
///
/// State → mood mapping (see [_StageMood]):
///   * idle / dispatching          → cool neutral blue, very faint
///   * working                     → soft cyan wash, slow breathing
///   * any agent in awaitingUser   → warm duck/amber wash
///                                   (user must notice the council
///                                   is blocked on them)
///   * any agent in error          → muted red lower-left wash
///                                   (directional, not full-stage)
///   * synthesizing                → soft purple wash, inward breath
///   * done + qualityGate.allPassed → mint accent ramp-in
///
/// All colours are pulled from `DuckColors` — no green literals (the
/// "done" mood uses `DuckColors.accentMint`, the IDE's teal-mint
/// frost token; the `no_green` test passes).
///
/// The overlay never obscures readable content. It paints with low
/// alpha (≤ 0.10 in the strongest mood) and is wrapped in
/// `IgnorePointer` so clicks pass through to the cards underneath.
///
/// Crossfade: mood transitions ride a single 460ms `AnimationController`.
/// Snap-changes would yank the user's eye; we want the lighting to
/// shift like a stage cue.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// Discrete mood the chamber lighting can land in. Each mood maps to
/// a tint colour + alpha + breath behaviour in [_lookup].
enum _StageMood {
  neutral,
  working,
  awaitingUser,
  error,
  synthesizing,
  done,
}

/// Visual recipe for one mood. The painter consumes these.
class _MoodSpec {
  /// Tint colour washed over the stage.
  final Color tint;
  /// Base alpha at the mood's resting state.
  final double alpha;
  /// 0..1 amplitude of the breathing modulation on alpha.
  final double breathAmp;
  /// Whether the wash should be directional (concentrated in a corner)
  /// rather than full-stage. Used for the error mood so a single
  /// agent's red doesn't smother the chamber.
  final bool directional;
  /// If [directional], the corner to anchor the wash to.
  final Alignment directionalAnchor;

  const _MoodSpec({
    required this.tint,
    required this.alpha,
    this.breathAmp = 0.0,
    this.directional = false,
    this.directionalAnchor = Alignment.center,
  });

  static _MoodSpec lookup(_StageMood mood) {
    switch (mood) {
      case _StageMood.neutral:
        return _MoodSpec(
          tint: DuckColors.councilBase,
          alpha: 0.04,
        );
      case _StageMood.working:
        return _MoodSpec(
          tint: DuckColors.accentCyan,
          alpha: 0.060,
          breathAmp: 0.45,
        );
      case _StageMood.awaitingUser:
        return _MoodSpec(
          tint: DuckColors.accentDuck,
          alpha: 0.100,
          breathAmp: 0.55,
        );
      case _StageMood.error:
        return _MoodSpec(
          tint: DuckColors.stateError,
          alpha: 0.050,
          directional: true,
          directionalAnchor: Alignment.bottomLeft,
        );
      case _StageMood.synthesizing:
        return _MoodSpec(
          tint: DuckColors.accentPurple,
          alpha: 0.070,
          breathAmp: 0.50,
        );
      case _StageMood.done:
        return _MoodSpec(
          tint: DuckColors.accentMint,
          alpha: 0.080,
          breathAmp: 0.30,
        );
    }
  }
}

/// Compute the dominant mood from the session.
///
/// Priority (most → least urgent):
///   1. awaitingUser  — the council is stuck on the user
///   2. error         — at least one agent has failed
///   3. done          — finished AND gate passed AND report ready
///   4. synthesizing  — final evaluator is composing the report
///   5. working       — at least one agent is running
///   6. neutral       — everything else (idle, dispatching, etc.)
_StageMood _moodFor(CouncilSession? session) {
  if (session == null) return _StageMood.neutral;

  // 1. User-blocking wins outright.
  if (session.pendingUserQuestion != null) return _StageMood.awaitingUser;
  for (final agent in session.config.allAgents) {
    if (agent.status == CouncilAgentStatus.awaitingUser) {
      return _StageMood.awaitingUser;
    }
  }

  // 2. Any agent in error.
  for (final agent in session.config.allAgents) {
    if (agent.status == CouncilAgentStatus.error) return _StageMood.error;
  }

  // 3. Successful completion. We require the gate to be fully passed
  //    AND a report to actually exist — a session that bounced to
  //    `done` via abort shouldn't show the celebratory mint wash.
  if (session.status == CouncilStatus.done &&
      session.reportPath.isNotEmpty &&
      session.qualityGate.allPassed) {
    return _StageMood.done;
  }

  // 4. Synthesis.
  if (session.status == CouncilStatus.synthesizing) {
    return _StageMood.synthesizing;
  }

  // 5. Any agent working OR replying.
  for (final agent in session.config.allAgents) {
    if (agent.status == CouncilAgentStatus.working ||
        agent.status == CouncilAgentStatus.replying ||
        agent.status == CouncilAgentStatus.askingPool) {
      return _StageMood.working;
    }
  }
  if (session.status == CouncilStatus.working) return _StageMood.working;

  return _StageMood.neutral;
}

/// Snapshot of the session fields the lighting cares about. Used as
/// the `selector` argument to `Provider.select` so the widget only
/// rebuilds on relevant changes, NOT on every chunk-level transcript
/// tick (which would defeat the point of decoupling lighting from the
/// per-frame stage paint).
class _LightingSignal {
  final _StageMood mood;
  const _LightingSignal(this.mood);

  @override
  bool operator ==(Object other) =>
      other is _LightingSignal && other.mood == mood;

  @override
  int get hashCode => mood.hashCode;
}

/// Stage-lighting overlay. Mount in [CouncilTheater] between the
/// chamber backdrop and the traffic mesh.
///
/// Reads the session from `AppState` via Provider so the lighting
/// reflects the current council state without the parent having to
/// pipe state through.
class CouncilStageLighting extends StatefulWidget {
  const CouncilStageLighting({super.key});

  @override
  State<CouncilStageLighting> createState() => _CouncilStageLightingState();
}

class _CouncilStageLightingState extends State<CouncilStageLighting>
    with TickerProviderStateMixin {
  /// Breathing controller for moods that modulate alpha over time.
  /// Slow enough that the room "settles" between breaths.
  late final AnimationController _breath;

  /// Crossfade controller. On every mood transition we flip
  /// `_priorMood` → `_currentMood` and ramp this from 0 → 1 over
  /// ~460ms. The painter blends old + new spec by `_crossfade.value`.
  late final AnimationController _crossfade;

  _StageMood _currentMood = _StageMood.neutral;
  _StageMood _priorMood = _StageMood.neutral;

  @override
  void initState() {
    super.initState();
    _breath = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4200),
    );
    _crossfade = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 460),
      value: 1.0,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) {
      if (_breath.isAnimating) _breath.stop();
      _breath.value = 0;
    } else if (!_breath.isAnimating) {
      _breath.repeat();
    }
  }

  @override
  void dispose() {
    _breath.dispose();
    _crossfade.dispose();
    super.dispose();
  }

  void _maybeTransition(_StageMood next) {
    if (next == _currentMood) return;
    setState(() {
      _priorMood = _currentMood;
      _currentMood = next;
    });
    _crossfade
      ..stop()
      ..value = 0
      ..forward();
  }

  @override
  Widget build(BuildContext context) {
    // Select only the mood derivation — avoids rebuilding on every
    // chunk-level transcript edit. The session reference itself is
    // also fine here because `_moodFor` is O(agents).
    final signal = context.select<AppState, _LightingSignal>((s) {
      return _LightingSignal(_moodFor(s.council.session));
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _maybeTransition(signal.mood);
    });

    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: Listenable.merge([_breath, _crossfade]),
          builder: (context, _) {
            return CustomPaint(
              size: Size.infinite,
              painter: _StageLightingPainter(
                fromSpec: _MoodSpec.lookup(_priorMood),
                toSpec: _MoodSpec.lookup(_currentMood),
                fade: _crossfade.value,
                breathT: _breath.value,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StageLightingPainter extends CustomPainter {
  _StageLightingPainter({
    required this.fromSpec,
    required this.toSpec,
    required this.fade,
    required this.breathT,
  });

  final _MoodSpec fromSpec;
  final _MoodSpec toSpec;
  final double fade;
  final double breathT;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    // Slow sine breath, 0..1 envelope.
    final breath = (math.sin(breathT * math.pi * 2) + 1) * 0.5;

    // Paint the outgoing mood underneath at (1 - fade) weight, then
    // the incoming mood on top at fade weight. Combined they total
    // one mood's intensity — never two simultaneous washes.
    _paintMood(canvas, size, fromSpec, breath, weight: 1.0 - fade);
    _paintMood(canvas, size, toSpec, breath, weight: fade);
  }

  void _paintMood(
    Canvas canvas,
    Size size,
    _MoodSpec spec,
    double breath, {
    required double weight,
  }) {
    if (weight <= 0.001) return;
    final modulated = spec.alpha * (1.0 + (breath - 0.5) * 2 * spec.breathAmp);
    final alpha = (modulated * weight).clamp(0.0, 0.16);
    if (alpha <= 0.001) return;
    final rect = Offset.zero & size;
    if (spec.directional) {
      // Directional wash — a radial gradient anchored to one corner
      // so e.g. an agent error doesn't smother the entire chamber
      // in red. Sells "trouble brewing over there" instead.
      final paint = Paint()
        ..shader = RadialGradient(
          center: spec.directionalAnchor,
          radius: 1.1,
          colors: [
            spec.tint.withValues(alpha: alpha),
            spec.tint.withValues(alpha: alpha * 0.45),
            Colors.transparent,
          ],
          stops: const [0.0, 0.45, 1.0],
        ).createShader(rect)
        ..blendMode = BlendMode.plus;
      canvas.drawRect(rect, paint);
    } else {
      // Full-stage soft wash. We use BlendMode.plus so the tint
      // brightens the underlying chamber instead of muddying it —
      // softLight on a dark midnight surface gives almost no visible
      // signal because the underlying luminance is already low.
      final paint = Paint()
        ..shader = RadialGradient(
          center: Alignment.center,
          radius: 1.0,
          colors: [
            spec.tint.withValues(alpha: alpha * 1.15),
            spec.tint.withValues(alpha: alpha * 0.75),
            spec.tint.withValues(alpha: alpha * 0.35),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(rect)
        ..blendMode = BlendMode.plus;
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _StageLightingPainter old) {
    return old.fade != fade ||
        old.breathT != breathT ||
        old.fromSpec.tint != fromSpec.tint ||
        old.toSpec.tint != toSpec.tint ||
        old.fromSpec.alpha != fromSpec.alpha ||
        old.toSpec.alpha != toSpec.alpha;
  }
}
