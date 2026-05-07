import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class CouncilHeaderBar extends StatelessWidget {
  final CouncilController controller;
  final VoidCallback? onOpenReport;
  final VoidCallback? onPingOrchestrator;

  const CouncilHeaderBar({
    super.key,
    required this.controller,
    this.onOpenReport,
    this.onPingOrchestrator,
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
          // Header button audit (2026-05): only show buttons that
          // actually affect the running council. Ping is conditional
          // on a live runner, Open Report is conditional on a saved
          // report path, Abort is conditional on the session still
          // being active. The previous "Back to editor" button only
          // flipped an internal `_theaterVisible` flag without closing
          // the council tab — visually a no-op — so it's been removed.
          // The X on the editor tab is the canonical close.
          if (controller.canPingOrchestrator && onPingOrchestrator != null)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _HeaderButton(
                icon: Icons.send_outlined,
                label: S.councilPingHeaderLabel,
                tooltip: S.councilPingHeaderTooltip,
                accent: true,
                onTap: onPingOrchestrator,
              ),
            ),
          if (session?.reportPath.isNotEmpty == true) ...[
            _HeaderButton(
              icon: Icons.description_outlined,
              label: S.councilOpenReport,
              onTap: onOpenReport,
            ),
            const SizedBox(width: 6),
          ],
          if (controller.isActive)
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
      CouncilStatus.awaitingFollowup => S.councilStatusAwaitingUser,
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
  final bool accent;
  final String? tooltip;

  const _HeaderButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.danger = false,
    this.accent = false,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final Color color;
    final Color bgColor;
    final Color borderColor;
    if (danger) {
      color = DuckColors.stateError;
      bgColor = DuckColors.stateError.withValues(alpha: 0.08);
      borderColor = DuckColors.stateError.withValues(alpha: 0.28);
    } else if (accent) {
      color = DuckColors.accentCyan;
      bgColor = DuckColors.accentCyan.withValues(alpha: 0.10);
      borderColor = DuckColors.accentCyan.withValues(alpha: 0.40);
    } else {
      color = DuckColors.fgMuted;
      bgColor = DuckColors.bgChip.withValues(alpha: 0.72);
      borderColor = DuckColors.border;
    }
    return Tooltip(
      message: tooltip ?? label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: borderColor, width: 0.6),
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
