import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Per-connect prompt asking the user whether to inject the
/// session-scoped shell helpers (`lumen-edit`, `lumen-grab`, and
/// OSC 7 cwd reporting) into the freshly opened SSH session.
///
/// Returns `true` on accept, `false` on Skip / dismiss / barrier-tap.
/// Declining means the controller skips the SFTP upload entirely —
/// nothing is left behind on the remote. Accepting hands off to the
/// existing self-deleting script flow, which `rm -f`s its own file
/// as the last statement.
///
/// Pre-v1.5 the helpers were auto-injected without asking; this
/// prompt is the user-facing opt-in introduced after a request to
/// keep the remote untouched unless the user explicitly opts in.
Future<bool> showSshHelpersInstallPrompt(
  BuildContext context, {
  required SshHost host,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: const [
          Icon(
            Icons.terminal_outlined,
            size: 16,
            color: DuckColors.accentDuck,
          ),
          SizedBox(width: 8),
          Text(
            S.sshHelpersPromptTitle,
            style: TextStyle(
              fontSize: 14,
              color: DuckColors.fgPrimary,
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              host.displayName,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              host.addressLine,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: DuckColors.fgFaint,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              S.sshHelpersPromptBody,
              style: TextStyle(
                fontSize: 12.5,
                color: DuckColors.fgPrimary,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            const _Bullet(text: S.sshHelpersPromptBulletEdit),
            const _Bullet(text: S.sshHelpersPromptBulletGrab),
            const _Bullet(text: S.sshHelpersPromptBulletCwd),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              decoration: BoxDecoration(
                color: DuckColors.bgChip,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(
                  color: DuckColors.glassSeam,
                  width: 0.5,
                ),
              ),
              child: const Text(
                S.sshHelpersPromptFootnote,
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgMuted,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text(S.sshHelpersPromptSkip),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.accentCyan,
            foregroundColor: DuckColors.bgDeepest,
          ),
          child: const Text(S.sshHelpersPromptAccept),
        ),
      ],
    ),
  );
  return accepted == true;
}

class _Bullet extends StatelessWidget {
  final String text;
  const _Bullet({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6, right: 8),
            child: Icon(
              Icons.circle,
              size: 4,
              color: DuckColors.fgFaint,
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
