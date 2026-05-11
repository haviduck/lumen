import 'dart:math' as math;
import 'dart:ui' as ui;

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
import 'compact_model_label.dart';

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
        // Accent ramp re-tokenised to Nord (`accentCyan` #88C0D0) so
        // the card reads as part of the IDE chrome family instead of
        // the saturated `councilAccent` blue, which the user flagged
        // as "too much" against the rest of the IDE. Orchestrator
        // keeps purple for role distinctness; error keeps Nord red.
        // Small chrome (spinner, status pill, checkmark) stays on
        // `councilAccent` — those punchier accents are deliberate.
        // Desat fade (`desat = 0.55`) is still the sole "done" cue.
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
    final ambientGlow = active ? 0.10 + 0.05 * idleT : 0.035;
    final accentStrokeAlpha = errored
        ? 0.65
        : isOrchestrator
        ? 0.42 + 0.16 * idleT
        : active
        ? 0.30 + 0.14 * idleT
        : 0.12; // always-on subtle accent
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
        color: active ? DuckColors.councilSurfaceHi : DuckColors.councilSurface,
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        // 2026-05: diagonal gradient washed out per user feedback —
        // it was reading as "harsh dark corner" rather than ambient
        // shading. Stops pushed later (0.7 instead of 0.55), final
        // base-color alpha lowered (0.18 from 0.45). Result: most
        // of the card surface is the pure navy `councilSurface`/`Hi`
        // tone, with only a faint dark-edge sink at the bottom-right
        // to give a hint of dimensionality.
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            (active
                    ? DuckColors.councilSurfaceHi
                    : DuckColors.councilSurface)
                .withValues(alpha: 1.0),
            accent.withValues(alpha: active ? 0.040 : 0.016),
            DuckColors.councilBase.withValues(alpha: 0.18),
          ],
          stops: const [0.0, 0.7, 1.0],
        ),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: [
          // Wide ambient accent glow — back on dark blue, slightly
          // brighter than the Nord-grey iteration so the panel reads
          // as a lit AI surface rather than just a dim card.
          BoxShadow(
            color: accent.withValues(alpha: ambientGlow * 1.4),
            blurRadius: active ? 22 : 14,
            spreadRadius: active ? 0.8 : 0.0,
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
      child: Stack(
        children: [
          // Digital-grid overlay — paints behind the card content
          // (between the gradient background and the children). The
          // grid + scanline + corner-ticks combine to read as an "AI
          // visualization panel" rather than a flat material card.
          // Animation is tied to the existing `_idle` ticker so we
          // don't add another vsync; opacity scales with `idleT` so
          // active cards "breathe" the digitized look.
          Positioned.fill(
            child: IgnorePointer(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(DuckTheme.radiusL),
                child: CustomPaint(
                  painter: _DigitalGridPainter(
                    accent: accent,
                    active: active,
                    idleT: idleT,
                    isOrchestrator: isOrchestrator,
                  ),
                ),
              ),
            ),
          ),
          Opacity(
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
                  ),
                // Status pill intentionally NOT shown here — moved to
                // the row alongside the model chip below, per Stage
                // Director directive: "working/idle/etc. badge belongs
                // on the same row as the model badge".
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
        ],
      ),
    );
  }

  String _roleLabel(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => S.councilRolePentester,
      RolePreset.reviewer => S.councilRoleReviewer,
      RolePreset.researcher => S.councilRoleResearcher,
      RolePreset.architect => S.councilRoleArchitect,
      RolePreset.tester => S.councilRoleTester,
      RolePreset.writer => S.councilRoleWriter,
      RolePreset.custom => S.councilRoleCustom,
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
    // Stripped down per Stage Director directive: no dark panel, no
    // dim transcript readout — those duplicated the click-history
    // popover. The mid panel is now PURELY the animation surface so
    // every card (idle or active) carries a quiet sign of life. The
    // idle indicator runs unconditionally so the row never goes
    // visually inert; cadence spectrum still gates on `active` so
    // it doesn't dance for sleeping agents.
    return SizedBox(
      width: double.infinity,
      child: Stack(
        children: [
          Positioned.fill(
            child: IgnorePointer(
              child: AgentIdleIndicator(
                variant: idleVariantForAgent(agentId),
                accent: accent,
                active: true,
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 36,
            child: IgnorePointer(
              child: _LiveCadenceSpectrum(
                transcript: transcript,
                accent: accent,
                active: active,
                done: done,
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
              const _SpinnerDot(color: DuckColors.councilAccent)
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
      CouncilAgentStatus.working => (_SpinnerGlyph(), DuckColors.councilAccent),
      CouncilAgentStatus.askingPool => (
          Icons.forum_outlined,
          DuckColors.accentPurple,
        ),
      CouncilAgentStatus.awaitingUser => (
          Icons.hourglass_bottom,
          DuckColors.accentDuck,
        ),
      CouncilAgentStatus.replying => (
          _SpinnerGlyph(),
          DuckColors.councilAccentHi,
        ),
      CouncilAgentStatus.done => (
          Icons.check_circle_outline,
          DuckColors.councilAccent,
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
  final Color accent;

  const _AgentStatusBlock({
    required this.agent,
    required this.errored,
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
                  // Compact label (e.g. `opus 4.6`, `gpt 5.5`) — the
                  // verbose `claude-opus-4.6`/`copilot:claude-…` form
                  // overflowed the 200-px card and ellipsised into
                  // unreadable `claud…`. Helper lives in
                  // `compact_model_label.dart` and is the single source
                  // of truth for this transformation.
                  label: compactModelLabel(agent.model),
                ),
              ),
              // Status pill lives HERE now, alongside the model chip.
              // Earlier this slot was empty and the pill was duplicated
              // on the title row; per Stage Director directive the pill
              // sits with the model badge so the title row stays clean
              // and the activity affordances are co-located.
              if (agent.status != CouncilAgentStatus.done) ...[
                const SizedBox(width: 6),
                _StatusPill(status: agent.status),
              ],
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
        color: DuckColors.councilAccent,
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


// ════════════════════════════════════════════════════════════════
// _LiveCadenceSpectrum — the "insanely cool" bottom strip.
//
// Why this isn't cheap:
//   • The motion is REAL. We measure `transcript.length` deltas
//     between rebuilds and feed them into a 22-bar spectrum, so a
//     burst of tokens visibly slams the bars; a slow trickle reads
//     as a low murmur. No fake `sin(t)` choreography.
//   • The bars don't all share one envelope. Each bar carries a
//     hash-derived phase and a 2nd-harmonic wobble, so a hot
//     cadence reads as a ragged, organic spectrum, not a fan.
//   • At peak intensity the entire strip chromatically aberrates:
//     a faint cyan offset is layered ±1.2 px against a magenta
//     copy in additive blend. Real RGB split, gated by intensity,
//     so it never strobes when the agent is idle.
//   • Beneath the bars sit two horizontal "plasma flowlines" with
//     traveling Gaussian highlights — the bottom of the card now
//     reads as a piece of *equipment*, not a divider.
//   • Pauses fully when not active and when there is no recent
//     token delta (>1.4s stale). When that's true the controller
//     stops ticking and the painter short-circuits — perf budget
//     is whatever the rest of the card costs, plus zero.
//
// State hooks: tied to `agent.transcript.length` deltas observed
// in `didUpdateWidget`. `active` flag (working|askingPool|
// awaitingUser|replying — see CouncilAgentStatus) gates the
// ticker. `done` desaturates the strip so finished agents don't
// keep dancing.
// ════════════════════════════════════════════════════════════════

class _LiveCadenceSpectrum extends StatefulWidget {
  final String transcript;
  final Color accent;
  final bool active;
  final bool done;

  const _LiveCadenceSpectrum({
    required this.transcript,
    required this.accent,
    required this.active,
    required this.done,
  });

  @override
  State<_LiveCadenceSpectrum> createState() => _LiveCadenceSpectrumState();
}

class _LiveCadenceSpectrumState extends State<_LiveCadenceSpectrum>
    with SingleTickerProviderStateMixin {
  static const int _bars = 22;
  // Heat target per bar (ramps toward this; decays exponentially).
  final List<double> _target = List<double>.filled(_bars, 0.0);
  final List<double> _level = List<double>.filled(_bars, 0.0);
  late final AnimationController _ticker;
  int _lastLen = 0;
  DateTime _lastDeltaAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Ring buffer of recent (timestamp, deltaChars) for cadence
  // estimation. Small bounded list — never grows.
  final List<_Tick> _recent = <_Tick>[];

  @override
  void initState() {
    super.initState();
    _lastLen = widget.transcript.length;
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    );
    _maybeTick();
  }

  @override
  void didUpdateWidget(covariant _LiveCadenceSpectrum old) {
    super.didUpdateWidget(old);
    final len = widget.transcript.length;
    if (len > _lastLen) {
      final delta = len - _lastLen;
      _lastDeltaAt = DateTime.now();
      _recent.add(_Tick(_lastDeltaAt, delta));
      // Bound the buffer.
      if (_recent.length > 24) _recent.removeAt(0);
      // Inject the burst across the spectrum: pick a hash-deterministic
      // bin, raise it + neighbors. Larger deltas = wider injection.
      final hash = (len * 2654435761) & 0x7FFFFFFF;
      final centerBin = hash % _bars;
      final spread = math.min(5, 1 + (delta / 4).round());
      final amp = (delta / 18.0).clamp(0.18, 1.0);
      for (var k = -spread; k <= spread; k++) {
        final i = (centerBin + k) % _bars;
        final ii = i < 0 ? i + _bars : i;
        final w = math.exp(-(k * k) / (spread * 0.9));
        _target[ii] = math.min(1.0, _target[ii] + amp * w);
      }
    }
    _lastLen = len;
    _maybeTick();
  }

  void _maybeTick() {
    final stale = DateTime.now().difference(_lastDeltaAt) >
        const Duration(milliseconds: 1400);
    final shouldRun = widget.active && !stale;
    final hasResidual = _level.any((v) => v > 0.005);
    if (shouldRun || hasResidual) {
      if (!_ticker.isAnimating) {
        _ticker.repeat();
      }
    } else {
      if (_ticker.isAnimating) _ticker.stop();
    }
  }

  void _stepLevels() {
    // Decay targets, ease levels toward targets. ~16ms tick.
    for (var i = 0; i < _bars; i++) {
      _target[i] *= 0.92;
      final delta = _target[i] - _level[i];
      _level[i] += delta * (delta > 0 ? 0.45 : 0.18);
      if (_level[i] < 0.0008 && _target[i] < 0.0008) {
        _level[i] = 0;
        _target[i] = 0;
      }
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return AnimatedBuilder(
      animation: _ticker,
      builder: (context, _) {
        if (!reduceMotion) _stepLevels();
        // After stepping, levels may have all settled — re-evaluate
        // whether we still need to tick.
        if (!widget.active && _level.every((v) => v < 0.005)) {
          if (_ticker.isAnimating) _ticker.stop();
        }
        // Aggregate intensity for chromatic aberration gating.
        var sum = 0.0;
        for (final v in _level) {
          sum += v;
        }
        final intensity = (sum / _bars).clamp(0.0, 1.0);
        return CustomPaint(
          painter: _CadenceSpectrumPainter(
            levels: _level,
            time: _ticker.lastElapsedDuration?.inMilliseconds ?? 0,
            accent: widget.accent,
            intensity: intensity,
            done: widget.done,
            reduceMotion: reduceMotion,
          ),
        );
      },
    );
  }
}

class _Tick {
  final DateTime at;
  final int delta;
  const _Tick(this.at, this.delta);
}

class _CadenceSpectrumPainter extends CustomPainter {
  final List<double> levels;
  final int time;
  final Color accent;
  final double intensity;
  final bool done;
  final bool reduceMotion;

  _CadenceSpectrumPainter({
    required this.levels,
    required this.time,
    required this.accent,
    required this.intensity,
    required this.done,
    required this.reduceMotion,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 4 || size.height < 4) return;
    final t = time / 1000.0;
    final desat = done ? 0.55 : 1.0;

    // Top fade so the bars feather into the transcript text above
    // instead of cutting it off with a hard line. Saved as a layer
    // so the gradient mask only applies to the spectrum + flow,
    // not the rest of the card.
    final layerRect = Offset.zero & size;
    canvas.saveLayer(layerRect, Paint());

    // ── 1) Plasma flowlines (always on, very subtle) ──────────
    // Two horizontal hairlines with traveling Gaussian highlights.
    // These are the "magnetic field" beneath the spectrum bars.
    final flowY1 = size.height - 6.0;
    final flowY2 = size.height - 3.0;
    final basePaint = Paint()
      ..color = accent.withValues(alpha: 0.10 * desat)
      ..strokeWidth = 0.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(2, flowY1), Offset(size.width - 2, flowY1), basePaint);
    canvas.drawLine(Offset(2, flowY2), Offset(size.width - 2, flowY2), basePaint);

    if (!reduceMotion) {
      const blobs = 3;
      for (var stream = 0; stream < 2; stream++) {
        final y = stream == 0 ? flowY1 : flowY2;
        final dir = stream == 0 ? 1.0 : -1.0;
        for (var i = 0; i < blobs; i++) {
          final phase = (t * 0.18 * dir + stream * 0.5 + i / blobs);
          final tt = phase - phase.floorToDouble();
          final env = math.sin(tt * math.pi);
          if (env <= 0.05) continue;
          final x = 4 + tt * (size.width - 8);
          final r = 2.6 + 1.4 * intensity;
          canvas.drawCircle(
            Offset(x, y),
            r + 2.0,
            Paint()
              ..color = accent.withValues(alpha: 0.20 * env * desat)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5)
              ..blendMode = BlendMode.plus,
          );
          canvas.drawCircle(
            Offset(x, y),
            r * 0.45,
            Paint()..color = accent.withValues(alpha: 0.85 * env * desat),
          );
        }
      }
    }

    // ── 2) Spectrum bars ──────────────────────────────────────
    // Bars rise from the bottom of the strip; max height ~ 78%
    // of strip height so the top stays clear for the transcript.
    final n = levels.length;
    final slot = (size.width - 8) / n;
    final barW = (slot * 0.62).clamp(2.0, 8.0);
    final maxH = size.height * 0.78;
    final baseY = size.height - 2;

    void paintBars(double xOffset, Color tint, double alphaScale) {
      for (var i = 0; i < n; i++) {
        final lvl = levels[i];
        if (lvl < 0.01) continue;
        // Per-bar wobble: 2nd harmonic with a phase from the bar
        // index so bars don't move in lockstep.
        final wobble = reduceMotion
            ? 1.0
            : (0.92 + 0.08 *
                math.sin(t * 5.2 + i * 0.83));
        final h = (maxH * lvl * wobble).clamp(1.0, maxH);
        final cx = 4 + i * slot + slot / 2 + xOffset;
        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - barW / 2, baseY - h, barW, h),
          const Radius.circular(1.2),
        );
        // Bar gradient: tint at base → bright cap.
        final shader = ui.Gradient.linear(
          Offset(cx, baseY),
          Offset(cx, baseY - h),
          [
            tint.withValues(alpha: 0.55 * lvl * alphaScale * desat),
            tint.withValues(alpha: (0.85 * lvl + 0.10) * alphaScale * desat),
            Color.lerp(tint, Colors.white, 0.65)!
                .withValues(alpha: (0.75 * lvl) * alphaScale * desat),
          ],
          const <double>[0.0, 0.7, 1.0],
        );
        canvas.drawRRect(
          rect,
          Paint()..shader = shader,
        );
      }
    }

    // ── 3) Chromatic aberration on peak ───────────────────────
    // Only when intensity > 0.18 and animations enabled. Two
    // offset copies in additive blend. Very small offsets — this
    // is *suggestion*, not a glitch effect.
    final aber = reduceMotion ? 0.0 : ((intensity - 0.18) * 1.7).clamp(0.0, 1.0);
    if (aber > 0.02) {
      final cyanLike = const Color(0xFF66E2FF);
      final magentaLike = const Color(0xFFFF6FB3);
      paintBars(-1.2 * aber, cyanLike, 0.55 * aber);
      paintBars(1.2 * aber, magentaLike, 0.55 * aber);
    }
    // Main bars on top.
    paintBars(0.0, accent, 1.0);

    // ── 4) Top feather mask so the strip melts into the panel.
    final fade = ui.Gradient.linear(
      Offset(0, 0),
      Offset(0, size.height * 0.45),
      const <Color>[Colors.transparent, Colors.black],
      const <double>[0.0, 1.0],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..shader = fade
        ..blendMode = BlendMode.dstIn,
    );

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CadenceSpectrumPainter old) {
    if (old.time != time) return true;
    if (old.intensity != intensity) return true;
    if (old.accent != accent) return true;
    if (old.done != done) return true;
    return false;
  }
}

/// Painter that gives each agent card an "AI visualization" texture:
///   • Faint pixel-grid (4×4 dot field at low alpha)
///   • Slow vertical scan-line that sweeps top→bottom
///   • Corner ticks (HUD-style brackets) at the four card corners
///   • Faint horizontal data-stream shimmer near the bottom
///
/// All four layers are tuned to be subtle by default — the user
/// asked for "more digitizing effects" but the cards still need to
/// be readable, so the grid sits below 0.06 alpha and the scan
/// line below 0.10. Active cards bump opacities slightly via
/// `idleT`. Orchestrator gets a hue shift toward purple.
///
/// Driven off the agent's existing `_idle` ticker so we don't add
/// another vsync per card. Repaints are gated on `shouldRepaint`
/// so static frames (idleT pinned, status unchanged) don't burn
/// CPU.
class _DigitalGridPainter extends CustomPainter {
  _DigitalGridPainter({
    required this.accent,
    required this.active,
    required this.idleT,
    required this.isOrchestrator,
  });

  final Color accent;
  final bool active;
  final double idleT;
  final bool isOrchestrator;

  // Grid spacing — 4px feels like "pixel art" without being too busy.
  // Larger spacing reads as a checker; smaller starts looking like noise.
  static const double _gridStride = 4.0;
  // Corner-tick length in logical pixels.
  static const double _tickLen = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final r = Offset.zero & size;

    // ── Layer 1: pixel-grid dot field ─────────────────────────────
    // Tiny 1px dots on a 4px grid. Alpha is intentionally so low that
    // it reads as texture, not pattern. Active cards bump it slightly.
    final gridAlpha = (active ? 0.052 : 0.030) + 0.012 * idleT;
    final dotPaint = Paint()
      ..color = accent.withValues(alpha: gridAlpha)
      ..style = PaintingStyle.fill;
    for (var y = _gridStride; y < size.height - 1; y += _gridStride) {
      for (var x = _gridStride; x < size.width - 1; x += _gridStride) {
        canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), dotPaint);
      }
    }

    // ── Layer 2: vertical scan line ───────────────────────────────
    // Sweeps top → bottom across the lifetime of the idle ticker.
    // The line is a thin gradient stripe (8px tall) painted with a
    // soft horizontal fade so its leading/trailing edges aren't sharp.
    final scanY = size.height * (0.05 + 0.95 * idleT);
    final scanRect = Rect.fromLTWH(0, scanY - 4, size.width, 8);
    final scanPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: active ? 0.10 : 0.05),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(scanRect);
    canvas.drawRect(scanRect, scanPaint);

    // ── Layer 3: corner ticks (HUD brackets) ──────────────────────
    // Four L-shaped strokes at the card corners. Standard sci-fi UI
    // bracketing — frames the card as a "reading panel" without
    // drawing a full inner border. Brighter on active cards.
    final tickPaint = Paint()
      ..color = accent.withValues(alpha: active ? 0.55 : 0.28)
      ..strokeWidth = 0.9
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke;

    // Top-left
    canvas.drawLine(const Offset(0, 0), const Offset(_tickLen, 0), tickPaint);
    canvas.drawLine(const Offset(0, 0), const Offset(0, _tickLen), tickPaint);
    // Top-right
    canvas.drawLine(
      Offset(size.width - _tickLen, 0),
      Offset(size.width, 0),
      tickPaint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(size.width, _tickLen),
      tickPaint,
    );
    // Bottom-left
    canvas.drawLine(
      Offset(0, size.height),
      Offset(_tickLen, size.height),
      tickPaint,
    );
    canvas.drawLine(
      Offset(0, size.height - _tickLen),
      Offset(0, size.height),
      tickPaint,
    );
    // Bottom-right
    canvas.drawLine(
      Offset(size.width - _tickLen, size.height),
      Offset(size.width, size.height),
      tickPaint,
    );
    canvas.drawLine(
      Offset(size.width, size.height - _tickLen),
      Offset(size.width, size.height),
      tickPaint,
    );

    // ── Layer 4: horizontal data stripe (bottom) ──────────────────
    // Thin moving stripe near the card footer that suggests "data
    // flowing through". Reuses the idle ticker — a phase-shifted
    // gradient that wraps. Subtler than the scan line so the two
    // motions don't compete for attention.
    final dataPhase = ((idleT * 1.7) % 1.0);
    final dataRect = Rect.fromLTWH(
      0,
      size.height - 12,
      size.width,
      2,
    );
    final dataPaint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: active ? 0.22 : 0.10),
          accent.withValues(alpha: 0.0),
        ],
        stops: [
          (dataPhase - 0.18).clamp(0.0, 1.0),
          dataPhase.clamp(0.0, 1.0),
          (dataPhase + 0.18).clamp(0.0, 1.0),
        ],
      ).createShader(dataRect);
    canvas.drawRect(dataRect, dataPaint);

    // Faint hue shift for orchestrator: overlay a thin purple wash
    // at very low alpha so the orchestrator card reads as the
    // "command surface" without restyling the whole painter chain.
    if (isOrchestrator) {
      final purplePaint = Paint()
        ..color = const Color(0xFFB48EAD).withValues(alpha: 0.025)
        ..style = PaintingStyle.fill;
      canvas.drawRect(r, purplePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _DigitalGridPainter old) {
    if (old.idleT != idleT) return true;
    if (old.active != active) return true;
    if (old.accent != accent) return true;
    if (old.isOrchestrator != isOrchestrator) return true;
    return false;
  }
}
