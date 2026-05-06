import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/strings.dart';
import '../../services/ssh/ssh_remote_file_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Prompt for `lumen-grab` filename collisions. Shows the existing
/// local file's size + mtime so the user has enough context to make
/// a reasonable Replace / Keep both / Cancel decision (you don't
/// want to clobber a 500 MB log file you spent 20 minutes generating).
///
/// Returns the user's [SshGrabConflictDecision]. Cancel is the
/// default — barrierDismissible + the X button both resolve to
/// [SshGrabConflictDecision.cancel].
Future<SshGrabConflictDecision> showSshGrabConflictDialog(
  BuildContext context, {
  required String existingLocalPath,
  required String remotePath,
  required String hostLabel,
}) async {
  final result = await showDialog<SshGrabConflictDecision>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SshGrabConflictDialog(
      existingLocalPath: existingLocalPath,
      remotePath: remotePath,
      hostLabel: hostLabel,
    ),
  );
  return result ?? SshGrabConflictDecision.cancel;
}

class _SshGrabConflictDialog extends StatelessWidget {
  final String existingLocalPath;
  final String remotePath;
  final String hostLabel;
  const _SshGrabConflictDialog({
    required this.existingLocalPath,
    required this.remotePath,
    required this.hostLabel,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: const Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 16,
            color: DuckColors.stateWarn,
          ),
          SizedBox(width: 8),
          Text(
            S.sshGrabConflictTitle,
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.sshGrabConflictBody,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgPrimary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            // Source / dest summary box. Mono-font so paths line up
            // visually; fgFaint on the labels keeps the eye on the
            // actual paths.
            _PathRow(
              label: S.sshGrabConflictRemote,
              value: '$hostLabel:$remotePath',
            ),
            const SizedBox(height: 4),
            _PathRow(
              label: S.sshGrabConflictExisting,
              value: existingLocalPath,
            ),
            const SizedBox(height: 8),
            FutureBuilder<FileStat>(
              future: FileStat.stat(existingLocalPath),
              builder: (ctx, snap) {
                if (!snap.hasData) return const SizedBox.shrink();
                final stat = snap.data!;
                return Text(
                  S.sshGrabConflictExistingMetaFmt(
                    _humanSize(stat.size),
                    _humanMtime(stat.modified),
                  ),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            // "Keep both" preview — show the user exactly what filename
            // they'll end up with so the choice isn't a leap of faith.
            Text(
              S.sshGrabConflictKeepBothPreviewFmt(
                p.basename(_previewKeepBothName(existingLocalPath)),
              ),
              style: const TextStyle(
                fontSize: 11.5,
                fontFamily: 'monospace',
                color: DuckColors.fgMuted,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(context, SshGrabConflictDecision.cancel),
          child: const Text(S.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(context, SshGrabConflictDecision.keepBoth),
          child: const Text(S.sshGrabConflictKeepBoth),
        ),
        ElevatedButton.icon(
          onPressed: () =>
              Navigator.pop(context, SshGrabConflictDecision.replace),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.stateError,
            foregroundColor: DuckColors.fgPrimary,
          ),
          icon: const Icon(Icons.refresh, size: 13),
          label: const Text(S.sshGrabConflictReplace),
        ),
      ],
    );
  }

  /// Best-guess preview of the `(1)` suffixed filename so users see
  /// what "Keep both" will produce. Doesn't actually probe disk —
  /// the real grab path increments past existing siblings; this is
  /// just so the button label has a concrete next-to-it preview.
  static String _previewKeepBothName(String path) {
    final dir = p.dirname(path);
    final ext = p.extension(path);
    final stem = p.basenameWithoutExtension(path);
    return p.join(dir, '$stem (1)$ext');
  }

  /// 1024-based humanise. Same as the remote browser's helper —
  /// duplicated locally rather than imported because the dialog's
  /// scope is a tight prompt, not a viewer for SFTP rows.
  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }

  static String _humanMtime(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}

class _PathRow extends StatelessWidget {
  final String label;
  final String value;
  const _PathRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgFaint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(
              fontSize: 11.5,
              fontFamily: 'monospace',
              color: DuckColors.fgPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
