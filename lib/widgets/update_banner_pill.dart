import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../services/update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'update_dialog.dart';

/// Compact pill that sits in the menu bar (between the menu items
/// and the drag region) when an update is available. Tappable: opens
/// the full update dialog.
///
/// Hidden when the service is in any non-actionable state — idle
/// without a release, checking, or after the user explicitly skipped
/// the current release. Keeps the menu bar visually quiet for
/// users who don't need to think about updates today.
class UpdateBannerPill extends StatelessWidget {
  const UpdateBannerPill({super.key});

  @override
  Widget build(BuildContext context) {
    final s = context.watch<UpdateService>();
    if (!s.hasActionableUpdate &&
        s.status != UpdateStatus.downloading &&
        s.status != UpdateStatus.ready &&
        s.status != UpdateStatus.installing) {
      return const SizedBox.shrink();
    }
    final r = s.release;
    final isDownloading = s.status == UpdateStatus.downloading;
    final isReady = s.status == UpdateStatus.ready;
    final isInstalling = s.status == UpdateStatus.installing;
    final accent = isInstalling || isReady
        ? DuckColors.accentMint
        : DuckColors.accentCyan;
    final label = switch (s.status) {
      UpdateStatus.downloading => S.updateBannerDownloading,
      UpdateStatus.ready => S.updateBannerReady,
      UpdateStatus.installing => S.updateBannerInstalling,
      _ => r == null
          ? S.updateBannerAvailable
          : S.updateBannerAvailableFmt(r.version),
    };
    return Tooltip(
      message: S.updateBannerTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () => showUpdateDialog(context),
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              border: Border.all(
                color: accent.withValues(alpha: 0.45),
                width: 0.7,
              ),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (isDownloading)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: accent,
                      value: s.downloadProgress.clamp(0.0, 1.0),
                    ),
                  )
                else if (isInstalling)
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.6,
                      color: accent,
                    ),
                  )
                else
                  Icon(
                    isReady
                        ? Icons.task_alt
                        : Icons.cloud_download_outlined,
                    size: 11,
                    color: accent,
                  ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: accent,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
