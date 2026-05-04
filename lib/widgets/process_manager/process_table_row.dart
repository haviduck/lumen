import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/process_manager_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'process_format.dart';

/// Single row in the process manager table.
///
/// Layout columns mirror the header (PID / Name / Memory /
/// Command line / Action). Lumen-spawned rows get a small cyan
/// dot on the left so the user can scan the table for "things
/// this IDE started" without re-toggling the filter chip.
class ProcessTableRow extends StatelessWidget {
  final ProcessInfo info;
  final bool isLumenSpawned;
  final bool busy;
  final VoidCallback onKill;

  const ProcessTableRow({
    super.key,
    required this.info,
    required this.isLumenSpawned,
    required this.busy,
    required this.onKill,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: isLumenSpawned
                ? Tooltip(
                    message: S.processLumenSpawnedTooltip,
                    child: Container(
                      width: 6,
                      height: 6,
                      decoration: const BoxDecoration(
                        color: DuckColors.accentCyan,
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
          SizedBox(
            width: 64,
            child: Text(
              '${info.pid}',
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(
            width: 200,
            child: Text(
              info.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 12.5,
                color: DuckColors.fgPrimary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          SizedBox(
            width: 90,
            child: Text(
              ProcessFormat.memory(info.memoryBytes),
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            child: Tooltip(
              message: info.commandLine ?? info.executablePath ?? '',
              waitDuration: const Duration(milliseconds: 400),
              child: Text(
                ProcessFormat.trimCommand(
                  info.commandLine ?? info.executablePath,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgSubtle,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          _KillButton(busy: busy, onKill: onKill),
        ],
      ),
    );
  }
}

class _KillButton extends StatelessWidget {
  final bool busy;
  final VoidCallback onKill;
  const _KillButton({required this.busy, required this.onKill});

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const SizedBox(
        width: 60,
        height: 22,
        child: Center(
          child: SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: DuckColors.fgMuted,
            ),
          ),
        ),
      );
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onKill,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            border: Border.all(color: DuckColors.border, width: 0.5),
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
          child: const Text(
            S.processKill,
            style: TextStyle(
              fontSize: 11.5,
              color: DuckColors.stateError,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    );
  }
}
