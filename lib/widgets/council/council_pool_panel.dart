import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class CouncilPoolPanel extends StatelessWidget {
  final CouncilSession session;

  const CouncilPoolPanel({super.key, required this.session});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 170),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DuckColors.bgRaised.withValues(alpha: 0.94),
            DuckColors.bgDeepest.withValues(alpha: 0.92),
          ],
        ),
        border: const Border(top: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(
                Icons.forum_outlined,
                size: 15,
                color: DuckColors.accentCyan,
              ),
              SizedBox(width: 8),
              Text(
                S.councilAskPoolHeader,
                style: TextStyle(
                  color: DuckColors.fgPrimary,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: session.poolQuestions.isEmpty
                ? const Text(
                    S.councilNoPoolQuestions,
                    style: TextStyle(color: DuckColors.fgMuted, fontSize: 11),
                  )
                : ListView.separated(
                    itemCount: session.poolQuestions.length,
                    separatorBuilder: (context, index) =>
                        const SizedBox(height: 8),
                    itemBuilder: (context, index) {
                      final q = session.poolQuestions[index];
                      final asker =
                          session.agentById(q.fromAgentId)?.name ??
                          q.fromAgentId;
                      return Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [DuckColors.bgChip, DuckColors.bgDeeper],
                          ),
                          borderRadius: BorderRadius.circular(
                            DuckTheme.radiusM,
                          ),
                          border: Border.all(color: DuckColors.borderStrong),
                          boxShadow: [
                            BoxShadow(
                              color: DuckColors.accentCyan.withValues(
                                alpha: 0.06,
                              ),
                              blurRadius: 18,
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '$asker: ${q.question}',
                              style: const TextStyle(
                                color: DuckColors.fgPrimary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            for (final reply in q.replies)
                              Padding(
                                padding: const EdgeInsets.only(top: 5),
                                child: Text(
                                  '${session.agentById(reply.fromAgentId)?.name ?? reply.fromAgentId}: ${reply.answer}',
                                  style: const TextStyle(
                                    color: DuckColors.fgMuted,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
