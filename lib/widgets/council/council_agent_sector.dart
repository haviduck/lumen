import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_protocol.dart';
import '../../services/council/council_task_ledger.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'council_agent_idle_indicator.dart';

class CouncilAgentSector extends StatefulWidget {
  final CouncilAgent agent;
  final bool isOrchestrator;
  /// Delay before this card begins its arrival animation. The Stage
  /// Director uses this to stagger the ring spawn so cards materialize
  /// in a pulsating-inward sweep instead of all at once.
  final int spawnDelayMs;

  const CouncilAgentSector({
    super.key,
    required this.agent,
    this.isOrchestrator = false,
    this.spawnDelayMs = 0,
  });

  @override
  State<CouncilAgentSector> createState() => _CouncilAgentSectorState();
}

class _CouncilAgentSectorState extends State<CouncilAgentSector>
    with TickerProviderStateMixin {
  late final AnimationController _arrive;
  late final AnimationController _idle;
  CouncilAgentStatus? _lastStatus;
  late final AnimationController _doneFlash;

  @override
  void initState() {
    super.initState();
    // Pulsating-inwards arrival: starts oversized + blurred + transparent,
    // settles into the resting card.  See [_buildCard] for the curves.
    //   • duration: 880ms easeOutCubic on scale + opacity, with an outer
    //     ring that contracts inward to the card edge.
    //   • staggered start via [widget.spawnDelayMs] so the ring lights up
    //     as a sweep, not a flash.
    _arrive = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 880),
    );
    if (widget.spawnDelayMs <= 0) {
      _arrive.forward();
    } else {
      Future.delayed(Duration(milliseconds: widget.spawnDelayMs), () {
        if (mounted) _arrive.forward();
      });
    }
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    )..repeat(reverse: true);
    _doneFlash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _lastStatus = widget.agent.status;
  }

  @override
  void didUpdateWidget(covariant CouncilAgentSector old) {
    super.didUpdateWidget(old);
    final next = widget.agent.status;
    if (_lastStatus != next) {
      if (next == CouncilAgentStatus.done) {
        _doneFlash.forward(from: 0);
      }
      _lastStatus = next;
    }
  }

  @override
  void dispose() {
    _arrive.dispose();
    _idle.dispose();
    _doneFlash.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final agent = widget.agent;
    final isOrchestrator = widget.isOrchestrator;
    final active =
        agent.status == CouncilAgentStatus.working ||
        agent.status == CouncilAgentStatus.askingPool ||
        agent.status == CouncilAgentStatus.awaitingUser ||
        agent.status == CouncilAgentStatus.replying;
    final done = agent.status == CouncilAgentStatus.done;
    final errored = agent.status == CouncilAgentStatus.error;

    return AnimatedBuilder(
      animation: Listenable.merge([_arrive, _idle, _doneFlash]),
      builder: (context, _) {
        // Pulsating-inwards spawn:
        //   scale  : 1.32 → 1.00  (settles INWARD; easeOutCubic)
        //   opacity: 0.00 → 1.00  (clamped)
        //   blur   : the contracting ring acts as the "blur" cue —
        //            painted around the card and pulled inward.
        final raw = _arrive.value.clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(raw);
        final scale = 1.32 - 0.32 * eased;
        final fadeIn = Curves.easeOutCubic.transform(raw);
        // `done` intentionally maps to `accentCyan` — using `stateOk`
        // here painted every persisted-done card with a hard nord-green
        // border (and fed the same color into `_ArrivalRingPainter`,
        // which re-flashed green on every modal refresh). Desat fade
        // (`desat = 0.55`) is now the sole "done" cue.
        final accent = errored
            ? DuckColors.stateError
            : done
            ? DuckColors.accentCyan
            : isOrchestrator
            ? DuckColors.accentPurple
            : DuckColors.accentCyan;
        final desat = done ? 0.55 : 1.0;

        return Opacity(
          opacity: fadeIn,
          child: Transform.scale(
            scale: scale,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                // Pulsating-inwards arrival ring — starts ~80px outside
                // the card and contracts to the card edge as the card
                // settles.  Replaces the old expand-outward ring which
                // read as "exploding" rather than "materializing".
                if (raw < 1.0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ArrivalRingPainter(
                          progress: raw,
                          accent: accent,
                        ),
                      ),
                    ),
                  ),
                // Done celebration ring — intentionally REMOVED.
                // The previous _DoneRingPainter painted a stroked rrect at
                // DuckColors.stateOk α 0.7 around the card on completion.
                // That was the "ugly green border" the user flagged. The
                // check-circle icon in the title row is now the only done
                // affordance — no halo, no painter.
                _buildCard(
                  active: active,
                  done: done,
                  errored: errored,
                  isOrchestrator: isOrchestrator,
                  accent: accent,
                  idleT: _idle.value,
                  desat: desat,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCard({
    required bool active,
    required bool done,
    required bool errored,
    required bool isOrchestrator,
    required Color accent,
    required double idleT,
    required double desat,
  }) {
    final agent = widget.agent;
    // Stronger card presence (Stage Director spec):
    //   • Accent stroke (always present, 0.6 → 1.4px) — gives every card
    //     a faint colored hairline so cards read as "lit objects" even
    //     when idle.  Not neon: alpha sits low on idle, breathes with
    //     activity.
    //   • Outer glow (active only): wide soft accent halo behind card.
    //   • Rim light (active + orchestrator): bright top-edge highlight
    //     via a 1px inner gradient stroke — sells the depth.
    //   • Layered shadow: a wide soft shadow + a tight contact shadow.
    final ambientGlow = active ? 0.16 + 0.08 * idleT : 0.05;
    final accentStrokeAlpha = errored
        ? 0.65
        : isOrchestrator
        ? 0.55 + 0.20 * idleT
        : active
        ? 0.42 + 0.18 * idleT
        : 0.16; // always-on subtle accent
    final borderColor = errored
        ? DuckColors.stateError.withValues(alpha: 0.72)
        : accent.withValues(alpha: accentStrokeAlpha);
    final borderWidth = errored
        ? 1.2
        : isOrchestrator
        ? 1.0
        : active
        ? 0.9
        : 0.7;
    return AnimatedContainer(
      duration: DuckMotion.medium,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active ? DuckColors.bgRaisedHi : DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        // Inner top-to-bottom sheen: very subtle highlight at the top
        // and a deeper sink toward the bottom — gives the card a sense
        // of being lit from above without any explicit gradient panel.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            (active ? DuckColors.bgRaisedHi : DuckColors.bgRaised)
                .withValues(alpha: 1.0),
            accent.withValues(alpha: active ? 0.06 : 0.025),
            DuckColors.bgDeepest.withValues(alpha: 0.18),
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: [
          // Wide ambient accent glow — taste-level alpha so the canvas
          // gets the "subtle lighting" the user asked for without
          // becoming neon vomit.
          BoxShadow(
            color: accent.withValues(alpha: ambientGlow),
            blurRadius: active ? 24 : 14,
            spreadRadius: active ? 1.0 : 0.0,
            offset: Offset.zero,
          ),
          // Contact shadow: tight, dark, downward — anchors card to
          // backdrop so it reads as an elevated surface.
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.42),
            blurRadius: 18,
            spreadRadius: -2,
            offset: const Offset(0, 6),
          ),
          ...DuckTheme.shadowSoft,
        ],
      ),
      child: Opacity(
        opacity: desat,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                // Accent rail along the leading edge of the title row.
                // Stands in for the dropped monogram tile so the role
                // color still has a presence on the card without the
                // 36px chip the user called clutter.
                Container(
                  width: 2,
                  height: 30,
                  decoration: BoxDecoration(
                    color: accent.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        agent.name,
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        isOrchestrator
                            ? S.councilOrchestrator
                            : _roleLabel(agent.role),
                        maxLines: 1,
                        softWrap: false,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgMuted,
                          fontSize: 10.5,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
                if (done)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Icon(
                      Icons.check_rounded,
                      size: 16,
                      color: DuckColors.fgMuted,
                    ),
                  )
                else
                  _StatusPill(status: agent.status),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              isOrchestrator
                  ? S.councilOrchestrator
                  : CouncilProtocol.roleInstruction(agent),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: DuckColors.fgMuted,
                fontSize: 11,
                height: 1.32,
                letterSpacing: 0.1,
              ),
            ),
            const SizedBox(height: 10),
            _AgentStatusBlock(
              agent: agent,
              errored: errored,
              done: done,
              accent: accent,
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _TranscriptWell(
                agentId: agent.id,
                transcript: agent.transcript,
                active: active,
                done: done,
                accent: accent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _roleLabel(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => 'Pentester',
      RolePreset.reviewer => 'Reviewer',
      RolePreset.researcher => 'Researcher',
      RolePreset.architect => 'Architect',
      RolePreset.tester => 'Tester',
      RolePreset.writer => 'Writer',
      RolePreset.custom => 'Agent',
    };
  }
}

class _ArrivalRingPainter extends CustomPainter {
  final double progress;
  final Color accent;

  _ArrivalRingPainter({required this.progress, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final t = progress.clamp(0.0, 1.0);
    final eased = Curves.easeOutCubic.transform(t);
    // Pulsating INWARD: ring starts ~70px outside the card edge and
    // contracts to a tight halo at the card border as the card settles.
    final outset = 70.0 * (1 - eased);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4 + 1.6 * (1 - t)
      ..color = accent.withValues(alpha: (1 - t) * 0.65)
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 4 * (1 - t) + 0.6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -outset,
          -outset,
          size.width + outset * 2,
          size.height + outset * 2,
        ),
        Radius.circular(20 + outset * 0.4),
      ),
      paint,
    );

    // Secondary inner sheen contracting on the card itself for the last
    // third of the animation — gives a "settling" highlight.
    if (t > 0.55) {
      final s = ((t - 0.55) / 0.45).clamp(0.0, 1.0);
      final sheen = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8 * (1 - s)
        ..color = accent.withValues(alpha: 0.45 * (1 - s));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width, size.height).deflate(2.0 + 4 * s),
          const Radius.circular(16),
        ),
        sheen,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ArrivalRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

// _DoneRingPainter intentionally removed — it painted a green halo
// around each card on completion, which read as the "ugly green
// border" the user flagged. Done state is now communicated solely by
// the check-circle icon in the title row.

class _TranscriptWell extends StatelessWidget {
  final String agentId;
  final String transcript;
  final bool active;
  final bool done;
  final Color accent;

  const _TranscriptWell({
    required this.agentId,
    required this.transcript,
    required this.active,
    required this.done,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final text = transcript.trim();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.46),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: active ? accent.withValues(alpha: 0.28) : DuckColors.border,
          width: 0.5,
        ),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    accent.withValues(alpha: active ? 0.05 : 0.02),
                    Colors.transparent,
                    DuckColors.bgDeepest.withValues(alpha: 0.16),
                  ],
                ),
              ),
            ),
          ),
          // Each agent gets a deterministic idle-indicator variant
          // (FNV hash of agent.id → variant). Same family vibe across
          // agents (subtle, low-amplitude, accent-tinted) but each
          // card animates in its own rhythm so the row reads as
          // individuated, not uniform. Inactive cards still mount the
          // indicator but at t=0 (no ticker) so the panel doesn't
          // pop in/out on state transitions.
          Positioned.fill(
            child: IgnorePointer(
              child: AgentIdleIndicator.forAgent(
                agentId: agentId,
                accent: accent,
                active: active,
              ),
            ),
          ),
          // Live transcript is now MUCH dimmer — bubbles are the hero.
          SingleChildScrollView(
            reverse: true,
            child: Text(
              text.isEmpty ? S.councilNoTranscript : text,
              style: TextStyle(
                color: text.isEmpty
                    ? DuckColors.fgSubtle.withValues(alpha: 0.45)
                    : DuckColors.fgSecondary.withValues(
                        alpha: done ? 0.18 : 0.22,
                      ),
                fontSize: 10.5,
                height: 1.35,
                fontStyle: FontStyle.italic,
                letterSpacing: 0.05,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkingField extends StatefulWidget {
  final Color accent;

  const _WorkingField({required this.accent});

  @override
  State<_WorkingField> createState() => _WorkingFieldState();
}

class _WorkingFieldState extends State<_WorkingField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: _WorkingFieldPainter(
            t: _controller.value,
            accent: widget.accent,
          ),
        );
      },
    );
  }
}

class _WorkingFieldPainter extends CustomPainter {
  final double t;
  final Color accent;

  _WorkingFieldPainter({required this.t, required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 5; i++) {
      final y = size.height * (0.2 + i * 0.14);
      final start = (t * size.width * 1.4 + i * 37) % (size.width + 42) - 42;
      paint.color = accent.withValues(alpha: 0.08 + i * 0.018);
      canvas.drawLine(Offset(start, y), Offset(start + 34 + i * 6, y), paint);
    }

    final dotPaint = Paint()..color = accent.withValues(alpha: 0.16);
    for (var i = 0; i < 9; i++) {
      final x = (size.width * ((t + i * 0.137) % 1.0));
      final y = size.height * (0.18 + ((i * 37) % 68) / 100);
      canvas.drawCircle(Offset(x, y), 1.4, dotPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _WorkingFieldPainter oldDelegate) {
    return oldDelegate.t != t || oldDelegate.accent != accent;
  }
}

class _StatusPill extends StatelessWidget {
  final CouncilAgentStatus status;

  const _StatusPill({required this.status});

  @override
  Widget build(BuildContext context) {
    final (icon, color) = _glyph;
    return Semantics(
      label: 'Status: $_label',
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 7),
        decoration: BoxDecoration(
          color: DuckColors.bgChip,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: color.withValues(alpha: 0.45),
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Status-bearing GLYPH (not just color) — required for
            // reduced-motion / colorblind perceivability.
            if (icon is _SpinnerGlyph)
              const _SpinnerDot(color: DuckColors.accentCyan)
            else
              Icon(icon as IconData, size: 11, color: color),
            const SizedBox(width: 5),
            Text(
              _label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }

  // Returns either an `IconData` or a `_SpinnerGlyph` sentinel for the
  // working/replying spinner (rendered as an animated dot).
  (Object, Color) get _glyph {
    return switch (status) {
      CouncilAgentStatus.idle => (
          Icons.fiber_manual_record,
          DuckColors.fgSubtle,
        ),
      CouncilAgentStatus.queued => (
          Icons.schedule_outlined,
          DuckColors.fgMuted,
        ),
      CouncilAgentStatus.working => (_SpinnerGlyph(), DuckColors.accentCyan),
      CouncilAgentStatus.askingPool => (
          Icons.forum_outlined,
          DuckColors.accentPurple,
        ),
      CouncilAgentStatus.awaitingUser => (
          Icons.hourglass_bottom,
          DuckColors.accentDuck,
        ),
      CouncilAgentStatus.replying => (_SpinnerGlyph(), DuckColors.accentMint),
      CouncilAgentStatus.done => (
          Icons.check_circle_outline,
          DuckColors.stateOk,
        ),
      CouncilAgentStatus.error => (
          Icons.warning_amber_rounded,
          DuckColors.stateError,
        ),
    };
  }

  String get _label {
    return switch (status) {
      CouncilAgentStatus.idle => S.councilStatusIdle,
      CouncilAgentStatus.queued => S.councilAgentStatusQueued,
      CouncilAgentStatus.working => S.councilStatusWorking,
      CouncilAgentStatus.askingPool => S.councilAgentStatusAskingPool,
      CouncilAgentStatus.awaitingUser => S.councilStatusAwaitingUser,
      CouncilAgentStatus.replying => S.councilAgentStatusReplying,
      CouncilAgentStatus.done => S.councilStatusDone,
      CouncilAgentStatus.error => S.councilStatusError,
    };
  }
}

class _SpinnerGlyph {
  const _SpinnerGlyph();
}

/// Tiny spinner used inside the status pill. Reduced-motion friendly:
/// the sweep is small (~11px) and the dot is also drawn as a static
/// solid mark so the status remains legible if motion is disabled or
/// the widget is captured in a screenshot.
class _SpinnerDot extends StatefulWidget {
  final Color color;
  const _SpinnerDot({required this.color});

  @override
  State<_SpinnerDot> createState() => _SpinnerDotState();
}

class _SpinnerDotState extends State<_SpinnerDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.of(context).disableAnimations;
    if (reduce) {
      return Icon(Icons.sync, size: 11, color: widget.color);
    }
    return SizedBox(
      width: 11,
      height: 11,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, _) {
          return Transform.rotate(
            angle: _c.value * 6.28318,
            child: Icon(Icons.sync, size: 11, color: widget.color),
          );
        },
      ),
    );
  }
}

/// Compact error badge — appears only when [count] > 0. Uses a static
/// red dot with the integer count so the affordance remains
/// perceivable without animation. The full last_error / waiting_on /
/// next_intended_action stanza is reachable via the parent block's
/// tooltip and tap-popover.
class _ErrorBadge extends StatelessWidget {
  final int count;
  const _ErrorBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: S.councilAgentErrorBadgeTooltip(count),
      child: Container(
        height: 20,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: DuckColors.stateError.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: DuckColors.stateError.withValues(alpha: 0.55),
            width: 0.7,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              size: 11,
              color: DuckColors.stateError,
            ),
            const SizedBox(width: 4),
            Text(
              '$count',
              style: const TextStyle(
                color: DuckColors.stateError,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Per-agent activity block. Replaces the old two-`Flexible`-chip Row
/// whose bolt-chip wrapped to 2 lines and broke cross-axis baseline.
///
/// Layout (HOW-B):
///   row 1 — model chip (fixed-height, single-line, ellipsis) +
///           status pill + optional error badge.
///   row 2 — ONE single-line activity hint, picked by priority:
///             error  → ⚠ last_error
///             waitingOn → ⏳ waiting on X
///             nextIntendedAction → → next: Y
///             currentTask → ⚡ doing Z
///
/// Binds to Forge's [CouncilTask] schema via the live session ledger.
/// On hover/tap the full stanza (cause / waiting_on / next_action) is
/// surfaced via the Tooltip — never as a copy-pasted error blob.
class _AgentStatusBlock extends StatelessWidget {
  final CouncilAgent agent;
  final bool errored;
  final bool done;
  final Color accent;

  const _AgentStatusBlock({
    required this.agent,
    required this.errored,
    required this.done,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final session = context
        .select<AppState, CouncilSession?>((s) => s.council.session);
    final task = _latestTaskFor(session, agent.id);
    final errorCount = _errorCountFor(session, agent.id, task);
    final hint = _activityHint(task);

    final tooltip = _composeTooltip(task, errorCount);

    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 350),
      preferBelow: false,
      textStyle: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 11,
        height: 1.35,
      ),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: errorCount > 0
              ? DuckColors.stateError.withValues(alpha: 0.55)
              : DuckColors.glassSeam,
          width: 0.6,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Flexible(
                child: _Chip(
                  icon: Icons.memory_outlined,
                  label: agent.model.isEmpty ? '—' : agent.model,
                ),
              ),
              const SizedBox(width: 6),
              if (!done) _StatusPill(status: agent.status),
              if (errorCount > 0) ...[
                const SizedBox(width: 6),
                _ErrorBadge(count: errorCount),
              ],
            ],
          ),
          if (hint != null) ...[
            const SizedBox(height: 6),
            _ActivityHint(hint: hint, accent: accent),
          ],
        ],
      ),
    );
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

  int _errorCountFor(
    CouncilSession? session,
    String agentId,
    CouncilTask? latest,
  ) {
    if (session == null) {
      return errored ? 1 : 0;
    }
    var sum = 0;
    for (final t in session.tasks) {
      if (t.agentId == agentId) sum += t.errorCount;
    }
    if (sum == 0 && errored) return 1;
    return sum;
  }

  _ActivityHintData? _activityHint(CouncilTask? task) {
    // Priority: error > waiting > next > current task. We only ever
    // surface ONE line at the row level; the full stanza is in the
    // tooltip. This keeps every card the same height regardless of
    // how rich the underlying ledger snapshot is.
    if (errored || (task?.lastError?.isNotEmpty ?? false)) {
      final msg = task?.lastError ?? agent.currentTask;
      return _ActivityHintData(
        icon: Icons.warning_amber_rounded,
        color: DuckColors.stateError,
        prefix: S.councilAgentLastError,
        text: msg.isEmpty ? S.councilAgentNoErrorDetail : msg,
      );
    }
    final waitingOn = task?.waitingOn;
    if (waitingOn != null && waitingOn.isNotEmpty) {
      return _ActivityHintData(
        icon: Icons.hourglass_bottom,
        color: DuckColors.accentDuck,
        prefix: S.councilAgentWaitingOn,
        text: waitingOn,
      );
    }
    final next = task?.nextIntendedAction;
    if (next != null && next.isNotEmpty) {
      return _ActivityHintData(
        icon: Icons.east_outlined,
        color: DuckColors.accentMint,
        prefix: S.councilAgentNextAction,
        text: next,
      );
    }
    if (agent.currentTask.isNotEmpty) {
      return _ActivityHintData(
        icon: Icons.bolt_outlined,
        color: DuckColors.fgSubtle,
        prefix: S.councilAgentDoing,
        text: agent.currentTask,
      );
    }
    return null;
  }

  String _composeTooltip(CouncilTask? task, int errorCount) {
    // Structured tooltip — title / cause / waiting_on / next_action.
    // Never a verbatim error blob.
    final lines = <String>[];
    final stateLabel = task?.state.name ?? agent.status.name;
    lines.add('${agent.name} · $stateLabel');
    if (errorCount > 0) {
      lines.add('Errors: $errorCount');
    }
    if (task?.lastError != null && task!.lastError!.trim().isNotEmpty) {
      lines.add('Cause: ${_clip(task.lastError!, 240)}');
    }
    if (task?.waitingOn != null && task!.waitingOn!.trim().isNotEmpty) {
      lines.add('Waiting on: ${task.waitingOn}');
    }
    if (task?.nextIntendedAction != null &&
        task!.nextIntendedAction!.trim().isNotEmpty) {
      lines.add('Next: ${task.nextIntendedAction}');
    }
    if (agent.currentTask.isNotEmpty) {
      lines.add('Doing: ${_clip(agent.currentTask, 200)}');
    }
    if (task != null) {
      lines.add('Attempts: ${task.attempts}/${task.maxAttempts}');
    }
    return lines.join('\n');
  }

  String _clip(String s, int max) =>
      s.length <= max ? s : '${s.substring(0, max)}…';
}

class _ActivityHintData {
  final IconData icon;
  final Color color;
  final String prefix;
  final String text;

  const _ActivityHintData({
    required this.icon,
    required this.color,
    required this.prefix,
    required this.text,
  });
}

class _ActivityHint extends StatelessWidget {
  final _ActivityHintData hint;
  final Color accent;

  const _ActivityHint({required this.hint, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Icon(hint.icon, size: 12, color: hint.color),
        const SizedBox(width: 6),
        Expanded(
          child: RichText(
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            text: TextSpan(
              style: const TextStyle(
                color: DuckColors.fgMuted,
                fontSize: 10.5,
                height: 1.2,
              ),
              children: [
                TextSpan(
                  text: '${hint.prefix} ',
                  style: TextStyle(
                    color: hint.color.withValues(alpha: 0.95),
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
                TextSpan(text: hint.text),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    // Fixed height + single-line text + ellipsis → guarantees the chip
    // never bumps the surrounding Row's cross-axis baseline. This is
    // the precise root cause of the user-reported asymmetry: the
    // previous `Flexible(Text(...))` allowed the bolt chip's
    // `currentTask` to wrap to 2 lines, making it taller than the
    // model chip beside it.
    return SizedBox(
      height: 20,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: DuckColors.bgChip,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 12, color: DuckColors.fgSubtle),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 10,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
