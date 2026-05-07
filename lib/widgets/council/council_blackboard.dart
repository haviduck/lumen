import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Which flank of the theater a blackboard panel is mounted on.
/// Drives margin asymmetry only — both sides share visual language.
enum BlackboardSide { left, right }

/// Shared shell for both the right (task tracker) and left (evaluator)
/// blackboards. Provides the framed surface, header rail, and scrollable
/// body region. Content is injected via [child]; a tasteful empty-state
/// placeholder is shown via [empty] when [child] is null.
class BlackboardPanel extends StatelessWidget {
  final BlackboardSide side;
  final String title;
  final String? emptyText;
  final Widget? child;

  const BlackboardPanel({
    super.key,
    required this.side,
    required this.title,
    this.emptyText,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final margin = side == BlackboardSide.right
        ? const EdgeInsets.fromLTRB(8, 14, 14, 14)
        : const EdgeInsets.fromLTRB(14, 14, 8, 14);
    return Container(
      margin: margin,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusL),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
        boxShadow: DuckTheme.shadowSoft,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 2,
                height: 14,
                color: DuckColors.accentMint.withValues(alpha: 0.85),
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: child ??
                Text(
                  emptyText ?? '',
                  style: const TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 12,
                  ),
                ),
          ),
        ],
      ),
    );
  }
}

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
    return BlackboardPanel(
      side: BlackboardSide.right,
      title: S.councilBlackboardTitle,
      emptyText: S.councilBlackboardEmpty,
      child: tasks.isEmpty && session.reportPath.isEmpty
          ? null
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: tasks.isEmpty
                      ? const Text(
                          S.councilBlackboardEmpty,
                          style: TextStyle(
                            color: DuckColors.fgMuted,
                            fontSize: 12,
                          ),
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


/// Left-side counterpart to [CouncilBlackboard]: hosts the final
/// evaluator's structured verdict (sectioned by markdown headings)
/// instead of having it spammed across the speech-bubble layer.
///
/// Renders progressively as `session.config.finalEvaluator.transcript`
/// streams in. Falls back to `session.reportMarkdown` once the report
/// is finalized (which is the canonical, persisted text).
///
/// Empty state: tasteful "Awaiting evaluation…" placeholder.
class CouncilLeftBlackboard extends StatelessWidget {
  final CouncilSession session;

  const CouncilLeftBlackboard({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    final evaluator = session.config.finalEvaluator;
    final live = evaluator.transcript.trim();
    final finalText = session.reportMarkdown.trim();
    // Prefer the canonical report once available; otherwise stream live.
    final body = finalText.isNotEmpty ? finalText : live;
    final streaming = evaluator.status == CouncilAgentStatus.working ||
        evaluator.status == CouncilAgentStatus.replying;

    if (body.isEmpty) {
      return BlackboardPanel(
        side: BlackboardSide.left,
        title: S.councilLeftBlackboardTitle,
        emptyText: streaming
            ? S.councilLeftBlackboardStreaming
            : S.councilLeftBlackboardEmpty,
      );
    }

    final sections = _parseSections(body);
    return BlackboardPanel(
      side: BlackboardSide.left,
      title: S.councilLeftBlackboardTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (streaming) const _StreamingPip(),
          Expanded(
            child: ListView.separated(
              itemCount: sections.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (_, i) => _SectionView(section: sections[i]),
            ),
          ),
        ],
      ),
    );
  }

  /// Lightweight markdown sectioner: splits body on H1/H2/H3 headings.
  /// Anything before the first heading becomes an untitled lead section.
  static List<_BoardSection> _parseSections(String body) {
    final lines = body.split('\n');
    final sections = <_BoardSection>[];
    String? currentTitle;
    int? currentLevel;
    final buf = StringBuffer();
    void flush() {
      final text = buf.toString().trim();
      if (text.isEmpty && currentTitle == null) return;
      sections.add(
        _BoardSection(
          title: currentTitle,
          level: currentLevel ?? 0,
          body: text,
        ),
      );
      buf.clear();
    }

    final headingRe = RegExp(r'^(#{1,3})\s+(.+?)\s*$');
    for (final line in lines) {
      final m = headingRe.firstMatch(line);
      if (m != null) {
        flush();
        currentLevel = m.group(1)!.length;
        currentTitle = m.group(2)!.trim();
      } else {
        buf.writeln(line);
      }
    }
    flush();
    if (sections.isEmpty) {
      sections.add(_BoardSection(title: null, level: 0, body: body.trim()));
    }
    return sections;
  }
}

class _BoardSection {
  final String? title;
  final int level;
  final String body;
  const _BoardSection({
    required this.title,
    required this.level,
    required this.body,
  });
}

class _SectionView extends StatelessWidget {
  final _BoardSection section;
  const _SectionView({required this.section});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentMint.withValues(alpha: 0.20),
          width: 0.7,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (section.title != null) ...[
            Text(
              section.title!,
              style: TextStyle(
                color: DuckColors.fgPrimary,
                fontWeight: FontWeight.w800,
                fontSize: section.level <= 1 ? 13 : 12,
                letterSpacing: section.level <= 1 ? 0.4 : 0.2,
              ),
            ),
            const SizedBox(height: 6),
          ],
          if (section.body.isNotEmpty)
            Text(
              section.body,
              style: const TextStyle(
                color: DuckColors.fgSecondary,
                fontSize: 11,
                height: 1.35,
              ),
            ),
        ],
      ),
    );
  }
}

class _StreamingPip extends StatelessWidget {
  const _StreamingPip();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: DuckColors.accentMint,
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 6),
          const Text(
            'LIVE',
            style: TextStyle(
              color: DuckColors.accentMint,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}
