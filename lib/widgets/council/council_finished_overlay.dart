import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Full-stage overlay that appears when the council reaches
/// [CouncilStatus.awaitingFollowup] or [CouncilStatus.done].
///
/// Shows a concise completion summary: elapsed time, per-agent
/// status grid (done vs error), and a prominent "View Report" CTA.
/// The user can dismiss it to see the underlying stage, or tap
/// "View Report" to dock the report panel.
///
/// Animates in with a staggered fade + scale. The scrim sits at
/// ~60% so the agent ring is still visible as a silhouette.
class CouncilFinishedOverlay extends StatefulWidget {
  final CouncilSession session;
  final VoidCallback? onViewReport;
  final VoidCallback onDismiss;
  final VoidCallback? onRoundTwo;
  final VoidCallback? onFinish;

  const CouncilFinishedOverlay({
    super.key,
    required this.session,
    this.onViewReport,
    required this.onDismiss,
    this.onRoundTwo,
    this.onFinish,
  });

  @override
  State<CouncilFinishedOverlay> createState() => _CouncilFinishedOverlayState();
}

class _CouncilFinishedOverlayState extends State<CouncilFinishedOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _enter;
  late final Animation<double> _scrim;
  late final Animation<double> _card;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );
    _scrim = CurvedAnimation(
      parent: _enter,
      curve: Curves.easeOut,
    );
    _card = CurvedAnimation(
      parent: _enter,
      curve: const Interval(0.15, 1.0, curve: Curves.easeOutCubic),
    );
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _dismiss() async {
    await _enter.reverse();
    if (mounted) widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _scrim,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _dismiss,
        child: ColoredBox(
          color: DuckColors.bgDeepest.withValues(alpha: 0.62),
          child: Center(
            child: FadeTransition(
              opacity: _card,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.92, end: 1.0).animate(_card),
                child: GestureDetector(
                  onTap: () {},
                  child: _FinishedCard(
                    session: widget.session,
                    onViewReport: widget.onViewReport,
                    onDismiss: _dismiss,
                    onRoundTwo: widget.onRoundTwo,
                    onFinish: widget.onFinish,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FinishedCard extends StatelessWidget {
  final CouncilSession session;
  final VoidCallback? onViewReport;
  final VoidCallback onDismiss;
  final VoidCallback? onRoundTwo;
  final VoidCallback? onFinish;

  const _FinishedCard({
    required this.session,
    this.onViewReport,
    required this.onDismiss,
    this.onRoundTwo,
    this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final w = (media.size.width * 0.50).clamp(340.0, 580.0);

    final allAgents = session.config.allAgents;
    final doneCount =
        allAgents.where((a) => a.status == CouncilAgentStatus.done).length;
    final errorCount =
        allAgents.where((a) => a.status == CouncilAgentStatus.error).length;
    final elapsed = _formatElapsed(session);
    final hasReport = session.reportPath.isNotEmpty;
    final followup = session.reviewerFollowup;
    final canRoundTwo = followup != null &&
        followup.suggestedRoundTwo &&
        session.status == CouncilStatus.awaitingFollowup;
    final isDone = session.status == CouncilStatus.done;

    return Material(
      color: Colors.transparent,
      child: Container(
        width: w,
        constraints: BoxConstraints(
          maxHeight: media.size.height * 0.82,
        ),
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 22),
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(
            color: DuckColors.accentCyan.withValues(alpha: 0.35),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: DuckColors.accentCyan.withValues(alpha: 0.12),
              blurRadius: 48,
              spreadRadius: 2,
            ),
            ...DuckTheme.shadowSoft,
          ],
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const _CompletionIcon(),
              const SizedBox(height: 16),
              Text(
                S.councilFinishedTitle,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    elapsed,
                    style: TextStyle(
                      color: DuckColors.accentCyan.withValues(alpha: 0.85),
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                  if (session.roundIndex > 0) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: DuckColors.accentPurple.withValues(alpha: 0.12),
                        borderRadius:
                            BorderRadius.circular(DuckTheme.radiusS),
                        border: Border.all(
                          color:
                              DuckColors.accentPurple.withValues(alpha: 0.35),
                          width: 0.6,
                        ),
                      ),
                      child: Text(
                        S.councilFinishedRound(session.roundIndex + 1),
                        style: TextStyle(
                          color:
                              DuckColors.accentPurple.withValues(alpha: 0.90),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 18),
              _AgentGrid(agents: allAgents),
              const SizedBox(height: 14),
              _SummaryRow(
                done: doneCount,
                errors: errorCount,
                total: allAgents.length,
              ),
              if (followup != null && followup.summary.trim().isNotEmpty) ...[
                const SizedBox(height: 18),
                _ReviewerSummary(summary: followup.summary.trim()),
              ],
              const SizedBox(height: 20),
              if (canRoundTwo && !isDone)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: _ActionButton(
                      label: S.councilFinishedRoundTwo,
                      icon: Icons.replay_rounded,
                      accent: true,
                      onTap: onRoundTwo,
                    ),
                  ),
                ),
              Row(
                children: [
                  if (!isDone && onFinish != null)
                    Expanded(
                      child: _ActionButton(
                        label: S.councilFinishedFinish,
                        icon: Icons.done_all_rounded,
                        onTap: onFinish,
                      ),
                    )
                  else
                    Expanded(
                      child: _ActionButton(
                        label: S.councilFinishedDismiss,
                        icon: Icons.arrow_back_rounded,
                        onTap: onDismiss,
                      ),
                    ),
                  if (hasReport) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: _ActionButton(
                        label: S.councilFinishedViewReport,
                        icon: Icons.description_outlined,
                        primary: true,
                        onTap: onViewReport,
                      ),
                    ),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatElapsed(CouncilSession session) {
    final end = session.finishedAt ?? DateTime.now();
    final dur = end.difference(session.startedAt);
    if (dur.inHours > 0) {
      return S.councilFinishedElapsed(
        '${dur.inHours}h ${dur.inMinutes.remainder(60)}m',
      );
    }
    if (dur.inMinutes > 0) {
      return S.councilFinishedElapsed(
        '${dur.inMinutes}m ${dur.inSeconds.remainder(60)}s',
      );
    }
    return S.councilFinishedElapsed('${dur.inSeconds}s');
  }
}

class _CompletionIcon extends StatefulWidget {
  const _CompletionIcon();

  @override
  State<_CompletionIcon> createState() => _CompletionIconState();
}

class _CompletionIconState extends State<_CompletionIcon>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (context, _) {
        final t = Curves.elasticOut.transform(_anim.value.clamp(0.0, 1.0));
        return Transform.scale(
          scale: t,
          child: Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  DuckColors.accentCyan.withValues(alpha: 0.20),
                  DuckColors.accentMint.withValues(alpha: 0.12),
                ],
              ),
              border: Border.all(
                color: DuckColors.accentCyan.withValues(alpha: 0.50),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: DuckColors.accentCyan.withValues(alpha: 0.18),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: const Icon(
              Icons.check_rounded,
              size: 28,
              color: DuckColors.accentCyan,
            ),
          ),
        );
      },
    );
  }
}

class _AgentGrid extends StatelessWidget {
  final List<CouncilAgent> agents;

  const _AgentGrid({required this.agents});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      alignment: WrapAlignment.center,
      children: [
        for (final agent in agents) _AgentChip(agent: agent),
      ],
    );
  }
}

class _AgentChip extends StatelessWidget {
  final CouncilAgent agent;

  const _AgentChip({required this.agent});

  @override
  Widget build(BuildContext context) {
    final isDone = agent.status == CouncilAgentStatus.done;
    final isError = agent.status == CouncilAgentStatus.error;
    final color = isError
        ? DuckColors.stateError
        : isDone
            ? DuckColors.accentCyan
            : DuckColors.fgSubtle;
    final statusLabel = isError
        ? S.councilFinishedAgentError
        : S.councilFinishedAgentDone;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: color.withValues(alpha: 0.30),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.check_circle_outline,
            size: 13,
            color: color,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              agent.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color.withValues(alpha: 0.95),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            statusLabel,
            style: TextStyle(
              color: color.withValues(alpha: 0.65),
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryRow extends StatelessWidget {
  final int done;
  final int errors;
  final int total;

  const _SummaryRow({
    required this.done,
    required this.errors,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          errors > 0 ? Icons.warning_amber_rounded : Icons.check_circle,
          size: 14,
          color: errors > 0 ? DuckColors.stateError : DuckColors.accentCyan,
        ),
        const SizedBox(width: 6),
        Text(
          S.councilFinishedAgentsDone(done, total),
          style: const TextStyle(
            color: DuckColors.fgSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (errors > 0) ...[
          const SizedBox(width: 10),
          Text(
            S.councilFinishedErrors(errors),
            style: const TextStyle(
              color: DuckColors.stateError,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _ReviewerSummary extends StatelessWidget {
  final String summary;

  const _ReviewerSummary({required this.summary});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DuckColors.accentPurple.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.25),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 2,
                height: 12,
                color: DuckColors.accentPurple.withValues(alpha: 0.80),
              ),
              const SizedBox(width: 8),
              const Text(
                S.councilFinishedReviewerSummary,
                style: TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            maxLines: 5,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: DuckColors.fgSecondary,
              fontSize: 11.5,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool primary;
  final bool accent;
  final VoidCallback? onTap;

  const _ActionButton({
    required this.label,
    required this.icon,
    this.primary = false,
    this.accent = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    final Color bg;
    final Color borderColor;
    if (primary) {
      color = DuckColors.accentCyan;
      bg = DuckColors.accentCyan.withValues(alpha: 0.12);
      borderColor = DuckColors.accentCyan.withValues(alpha: 0.45);
    } else if (accent) {
      color = DuckColors.accentPurple;
      bg = DuckColors.accentPurple.withValues(alpha: 0.10);
      borderColor = DuckColors.accentPurple.withValues(alpha: 0.40);
    } else {
      color = DuckColors.fgMuted;
      bg = DuckColors.bgChip.withValues(alpha: 0.72);
      borderColor = DuckColors.border;
    }

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: borderColor, width: 0.7),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: color,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
