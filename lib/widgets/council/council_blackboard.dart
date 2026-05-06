import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class CouncilBlackboard extends StatelessWidget {
  final CouncilSession session;
  final VoidCallback? onOpenReport;

  const CouncilBlackboard({
    super.key,
    required this.session,
    this.onOpenReport,
  });

  @override
  Widget build(BuildContext context) {
    final tasks = _tasks();
    return Container(
      margin: const EdgeInsets.fromLTRB(8, 14, 14, 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF10151C), Color(0xFF171D26), Color(0xFF0D1117)],
        ),
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        border: Border.all(color: DuckColors.borderStrong, width: 0.8),
        boxShadow: [
          BoxShadow(
            color: DuckColors.accentMint.withValues(alpha: 0.08),
            blurRadius: 28,
          ),
          ...DuckTheme.shadowSoft,
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.fact_check_outlined, color: DuckColors.accentMint),
              SizedBox(width: 8),
              Text(
                S.councilBlackboardTitle,
                style: TextStyle(
                  color: DuckColors.fgPrimary,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: tasks.isEmpty
                ? const Text(
                    S.councilBlackboardEmpty,
                    style: TextStyle(color: DuckColors.fgMuted, fontSize: 12),
                  )
                : ListView.separated(
                    itemCount: tasks.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      return _TaskRow(task: tasks[index]);
                    },
                  ),
          ),
          if (session.reportPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ReportCard(session: session, onOpenReport: onOpenReport),
          ],
        ],
      ),
    );
  }

  List<_BoardTask> _tasks() {
    final dispatched = session.events
        .where((e) => e.type == 'dispatched' && e.toAgentId.isNotEmpty)
        .toList();
    final doneEvents = session.events
        .where((e) => e.type == 'agent_done' || e.type == 'agent_error')
        .toList();
    return [
      for (final event in dispatched)
        _BoardTask(
          agentName:
              session.agentById(event.toAgentId)?.name ?? event.toAgentId,
          task: event.message,
          done: doneEvents.any(
            (done) =>
                done.fromAgentId == event.toAgentId &&
                !done.createdAt.isBefore(event.createdAt),
          ),
          failed: doneEvents.any(
            (done) =>
                done.type == 'agent_error' &&
                done.fromAgentId == event.toAgentId &&
                !done.createdAt.isBefore(event.createdAt),
          ),
        ),
      if (session.config.finalEvaluator.status != CouncilAgentStatus.idle ||
          session.config.finalEvaluator.transcript.trim().isNotEmpty)
        _BoardTask(
          agentName: session.config.finalEvaluator.name,
          task: session.config.finalEvaluator.currentTask.isEmpty
              ? S.councilBlackboardReportBody
              : session.config.finalEvaluator.currentTask,
          done: session.config.finalEvaluator.status == CouncilAgentStatus.done,
          failed:
              session.config.finalEvaluator.status == CouncilAgentStatus.error,
        ),
    ];
  }
}

class _TaskRow extends StatelessWidget {
  final _BoardTask task;

  const _TaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final color = task.failed
        ? DuckColors.stateError
        : task.done
        ? DuckColors.stateOk
        : DuckColors.accentCyan;
    return Container(
      padding: const EdgeInsets.all(9),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: color.withValues(alpha: 0.28), width: 0.7),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            task.failed
                ? Icons.error_outline
                : task.done
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            size: 17,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.agentName,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  task.task,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: task.done ? DuckColors.fgSubtle : DuckColors.fgMuted,
                    decoration: task.done
                        ? TextDecoration.lineThrough
                        : TextDecoration.none,
                    fontSize: 11,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ReportCard extends StatelessWidget {
  final CouncilSession session;
  final VoidCallback? onOpenReport;

  const _ReportCard({required this.session, this.onOpenReport});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.accentPurple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            S.councilBlackboardReportTitle,
            style: TextStyle(
              color: DuckColors.fgPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            S.councilBlackboardReportBody,
            style: TextStyle(color: DuckColors.fgMuted, fontSize: 11),
          ),
          if (session.reportMarkdown.trim().isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              session.reportMarkdown.trim(),
              maxLines: 7,
              overflow: TextOverflow.fade,
              style: const TextStyle(
                color: DuckColors.fgSecondary,
                fontSize: 11,
                height: 1.25,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: onOpenReport,
              icon: const Icon(Icons.open_in_new, size: 14),
              label: const Text(S.councilOpenReport),
            ),
          ),
        ],
      ),
    );
  }
}

class _BoardTask {
  final String agentName;
  final String task;
  final bool done;
  final bool failed;

  const _BoardTask({
    required this.agentName,
    required this.task,
    required this.done,
    required this.failed,
  });
}
