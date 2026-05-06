import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/ssh/ssh_remote_file_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Show the "remote changed since you opened it" prompt. Returns
/// true to proceed with overwrite, false to cancel the save.
///
/// Hooked into [AppState] via [bindSsh]'s `conflictResolver` arg so
/// every save path (Ctrl+S, save button, save-on-blur) routes through
/// the same UX. Surfaces the snapshot vs. live comparison so the user
/// can decide whether to keep their version or fetch the remote.
Future<bool> showSshRemoteConflictDialog(
  BuildContext context, {
  required RemoteFileOrigin origin,
  required int? currentSize,
  required int? currentMtime,
}) async {
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: const Text(
        S.sshRemoteFileConflictTitle,
        style: TextStyle(
          fontSize: 14,
          color: DuckColors.stateWarn,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              S.sshRemoteFileConflictBody,
              style: TextStyle(fontSize: 12.5, color: DuckColors.fgPrimary),
            ),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: DuckColors.bgChip,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(
                  color: DuckColors.glassSeam,
                  width: 0.5,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    origin.displaySuffix,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _Row(
                    label: 'When opened',
                    size: origin.downloadedSize,
                    mtime: origin.downloadedMtime,
                  ),
                  _Row(
                    label: 'Now',
                    size: currentSize,
                    mtime: currentMtime,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text(S.sshRemoteFileConflictCancel),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.stateWarn,
          ),
          child: const Text(S.sshRemoteFileConflictOverwrite),
        ),
      ],
    ),
  );
  return result == true;
}

class _Row extends StatelessWidget {
  final String label;
  final int? size;
  final int? mtime;
  const _Row({
    required this.label,
    required this.size,
    required this.mtime,
  });

  @override
  Widget build(BuildContext context) {
    final mtimeStr = mtime == null
        ? '—'
        : DateTime.fromMillisecondsSinceEpoch(mtime! * 1000)
            .toLocal()
            .toIso8601String()
            .replaceFirst('T', ' ')
            .substring(0, 19);
    final sizeStr = size == null
        ? '—'
        : '${(size! / 1024).toStringAsFixed(1)} KB';
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Text(
        '$label  ·  size=$sizeStr  ·  mtime=$mtimeStr',
        style: const TextStyle(
          fontFamily: 'monospace',
          fontSize: 10.5,
          color: DuckColors.fgFaint,
        ),
      ),
    );
  }
}
