import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class CouncilHeaderBar extends StatelessWidget {
  final CouncilController controller;
  final VoidCallback? onOpenReport;

  const CouncilHeaderBar({
    super.key,
    required this.controller,
    this.onOpenReport,
  });

  @override
  Widget build(BuildContext context) {
    final session = controller.session;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [DuckColors.bgDeepest, DuckColors.bgRaised],
        ),
        border: const Border(bottom: BorderSide(color: DuckColors.glassSeam)),
        boxShadow: [
          BoxShadow(
            color: DuckColors.accentCyan.withValues(alpha: 0.08),
            blurRadius: 26,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [DuckColors.accentCyan, DuckColors.accentPurple],
              ),
              boxShadow: [
                BoxShadow(
                  color: DuckColors.accentPurple.withValues(alpha: 0.24),
                  blurRadius: 18,
                ),
              ],
            ),
            child: const Icon(
              Icons.hub_outlined,
              color: DuckColors.bgDeepest,
              size: 19,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  session?.config.title.isNotEmpty == true
                      ? session!.config.title
                      : S.councilTitle,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 15,
                  ),
                ),
                Text(
                  _statusLabel(session?.status ?? CouncilStatus.idle),
                  style: const TextStyle(
                    color: DuckColors.accentMint,
                    fontSize: 11,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          if (session?.reportPath.isNotEmpty == true)
            _HeaderButton(
              icon: Icons.description_outlined,
              label: S.councilOpenReport,
              onTap: onOpenReport,
            ),
          const SizedBox(width: 6),
          _HeaderButton(
            icon: Icons.keyboard_return_outlined,
            label: S.councilBackToEditor,
            onTap: controller.hideTheater,
          ),
          const SizedBox(width: 6),
          _HeaderButton(
            icon: Icons.stop_circle_outlined,
            label: S.councilAbort,
            danger: true,
            onTap: () => controller.abort(),
          ),
        ],
      ),
    );
  }

  String _statusLabel(CouncilStatus status) {
    return switch (status) {
      CouncilStatus.idle => S.councilStatusIdle,
      CouncilStatus.dispatching => S.councilStatusDispatching,
      CouncilStatus.working => S.councilStatusWorking,
      CouncilStatus.awaitingUser => S.councilStatusAwaitingUser,
      CouncilStatus.awaitingPool => S.councilStatusAwaitingPool,
      CouncilStatus.synthesizing => S.councilStatusSynthesizing,
      CouncilStatus.done => S.councilStatusDone,
      CouncilStatus.aborted => S.councilStatusAborted,
      CouncilStatus.error => S.councilStatusError,
    };
  }
}

class _HeaderButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;

  const _HeaderButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? DuckColors.stateError : DuckColors.fgMuted;
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: danger
                ? DuckColors.stateError.withValues(alpha: 0.08)
                : DuckColors.bgChip.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: danger
                  ? DuckColors.stateError.withValues(alpha: 0.28)
                  : DuckColors.border,
              width: 0.6,
            ),
          ),
          child: Row(
            children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(color: color, fontSize: 11)),
            ],
          ),
        ),
      ),
    );
  }
}
