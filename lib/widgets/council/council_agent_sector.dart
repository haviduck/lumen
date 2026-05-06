import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_protocol.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'council_agent_idle_indicator.dart';

class CouncilAgentSector extends StatefulWidget {
  final CouncilAgent agent;
  final bool isOrchestrator;

  const CouncilAgentSector({
    super.key,
    required this.agent,
    this.isOrchestrator = false,
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
    _arrive = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    )..forward();
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
        final arriveT = Curves.easeOutBack.transform(_arrive.value);
        final scale = 0.86 + 0.14 * arriveT;
        final fadeIn = _arrive.value.clamp(0.0, 1.0);
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
                // Arrival ring pulse — fades after the first ~720ms.
                if (_arrive.value < 1.0)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _ArrivalRingPainter(
                          progress: _arrive.value,
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
    final ambientGlow = active ? 0.10 + 0.05 * idleT : 0.0;
    final borderColor = errored
        ? DuckColors.stateError.withValues(alpha: 0.5)
        : active
        ? accent.withValues(alpha: 0.35 + 0.15 * idleT)
        : DuckColors.glassSeam;
    final borderWidth = active ? 1.0 : (errored ? 1.0 : 0.6);
    return AnimatedContainer(
      duration: DuckMotion.medium,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: active ? DuckColors.bgRaisedHi : DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        border: Border.all(color: borderColor, width: borderWidth),
        boxShadow: active
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: ambientGlow),
                  blurRadius: 18,
                  spreadRadius: 0,
                ),
                ...DuckTheme.shadowSoft,
              ]
            : DuckTheme.shadowSoft,
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
            Row(
              children: [
                Flexible(
                  child: _Chip(icon: Icons.memory_outlined, label: agent.model),
                ),
                if (agent.currentTask.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Flexible(
                    child: _Chip(
                      icon: Icons.bolt_outlined,
                      label: agent.currentTask,
                    ),
                  ),
                ],
              ],
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
    final maxRadius = math.max(size.width, size.height) * (0.6 + 0.4 * eased);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 * (1 - t)
      ..color = accent.withValues(alpha: (1 - t) * 0.55);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(
          -maxRadius * 0.06,
          -maxRadius * 0.06,
          size.width + maxRadius * 0.12,
          size.height + maxRadius * 0.12,
        ).deflate(-eased * 14),
        const Radius.circular(20),
      ),
      paint,
    );
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: Text(
        _label,
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 10),
      ),
    );
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

class _Chip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _Chip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
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
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: DuckColors.fgMuted, fontSize: 10),
            ),
          ),
        ],
      ),
    );
  }
}
