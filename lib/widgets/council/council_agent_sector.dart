import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_protocol.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class CouncilAgentSector extends StatelessWidget {
  final CouncilAgent agent;
  final bool isOrchestrator;

  const CouncilAgentSector({
    super.key,
    required this.agent,
    this.isOrchestrator = false,
  });

  @override
  Widget build(BuildContext context) {
    final active =
        agent.status == CouncilAgentStatus.working ||
        agent.status == CouncilAgentStatus.askingPool ||
        agent.status == CouncilAgentStatus.awaitingUser ||
        agent.status == CouncilAgentStatus.replying;
    return AnimatedContainer(
      duration: DuckMotion.medium,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: active
              ? const [
                  Color(0xFF2A313D),
                  DuckColors.bgRaised,
                  DuckColors.bgDeeper,
                ]
              : const [
                  DuckColors.bgRaised,
                  DuckColors.bgChip,
                  DuckColors.bgDeeper,
                ],
        ),
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        border: Border.all(
          color: active
              ? (isOrchestrator ? DuckColors.accentDuck : DuckColors.accentCyan)
              : DuckColors.glassSeam,
          width: active ? 1.6 : 0.7,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color:
                      (isOrchestrator
                              ? DuckColors.accentDuck
                              : DuckColors.accentCyan)
                          .withValues(alpha: 0.22),
                  blurRadius: 28,
                  spreadRadius: 1,
                ),
                ...DuckTheme.shadowSoft,
              ]
            : DuckTheme.shadowSoft,
      ),
      child: Stack(
        children: [
          if (active)
            Positioned(
              right: -34,
              top: -36,
              child: Container(
                width: 96,
                height: 96,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color:
                      (isOrchestrator
                              ? DuckColors.accentDuck
                              : DuckColors.accentCyan)
                          .withValues(alpha: 0.08),
                ),
              ),
            ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: AnimatedContainer(
              duration: DuckMotion.medium,
              width: active ? 3 : 1,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                color: active
                    ? (isOrchestrator
                          ? DuckColors.accentDuck
                          : DuckColors.accentCyan)
                    : DuckColors.border,
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: isOrchestrator
                          ? DuckColors.duckGradient
                          : const LinearGradient(
                              colors: [
                                DuckColors.accentCyan,
                                DuckColors.accentMint,
                              ],
                            ),
                      boxShadow: active
                          ? [
                              BoxShadow(
                                color:
                                    (isOrchestrator
                                            ? DuckColors.accentDuck
                                            : DuckColors.accentCyan)
                                        .withValues(alpha: 0.35),
                                blurRadius: 18,
                              ),
                            ]
                          : null,
                    ),
                    child: Icon(
                      isOrchestrator
                          ? Icons.hub_outlined
                          : _iconForRole(agent.role),
                      size: 17,
                      color: DuckColors.bgDeepest,
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      agent.name,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DuckColors.fgPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                  _StatusPill(status: agent.status),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                isOrchestrator
                    ? S.councilOrchestrator
                    : CouncilProtocol.roleInstruction(agent),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 11,
                  height: 1.28,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Flexible(
                    child: _Chip(
                      icon: Icons.memory_outlined,
                      label: agent.model,
                    ),
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
              const SizedBox(height: 8),
              Expanded(
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(9),
                  decoration: BoxDecoration(
                    color: DuckColors.bgDeepest.withValues(alpha: 0.58),
                    borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                    border: Border.all(
                      color: active
                          ? DuckColors.borderStrong
                          : DuckColors.border,
                      width: 0.5,
                    ),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    child: Text(
                      agent.transcript.trim().isEmpty
                          ? S.councilNoTranscript
                          : agent.transcript.trim(),
                      style: TextStyle(
                        color: agent.transcript.trim().isEmpty
                            ? DuckColors.fgSubtle
                            : DuckColors.fgSecondary,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _iconForRole(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => Icons.security_outlined,
      RolePreset.reviewer => Icons.rate_review_outlined,
      RolePreset.researcher => Icons.travel_explore_outlined,
      RolePreset.architect => Icons.account_tree_outlined,
      RolePreset.tester => Icons.bug_report_outlined,
      RolePreset.writer => Icons.edit_note_outlined,
      RolePreset.custom => Icons.person_outline,
    };
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
