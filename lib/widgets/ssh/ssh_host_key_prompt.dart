import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/ssh/ssh_client_service.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Prompt the user to accept a host key. `firstTime: true` means
/// we've never connected to this host before; `firstTime: false`
/// means the live fingerprint differs from the one we have stored
/// (the more dangerous case — show with red chrome and a louder
/// warning).
Future<SshHostKeyDecision> showSshHostKeyPrompt(
  BuildContext context, {
  required SshHost host,
  required String fingerprint,
  required bool firstTime,
}) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Text(
        firstTime ? S.sshHostKeyFirstTrust : S.sshHostKeyChanged,
        style: TextStyle(
          color: firstTime ? DuckColors.fgPrimary : DuckColors.stateError,
          fontSize: 14,
        ),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!firstTime) ...[
              const Text(
                S.sshHostKeyChangedBody,
                style: TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgPrimary,
                ),
              ),
              const SizedBox(height: 10),
            ],
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
            const SizedBox(height: 10),
            const Text(
              S.sshFingerprintLabel,
              style: TextStyle(
                fontSize: 11,
                color: DuckColors.fgMuted,
              ),
            ),
            Container(
              margin: const EdgeInsets.only(top: 4),
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
              child: SelectableText(
                fingerprint,
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: DuckColors.fgPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text(S.sshHostKeyAbort),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor:
                firstTime ? DuckColors.accentCyan : DuckColors.stateError,
            foregroundColor: DuckColors.bgDeepest,
          ),
          child: Text(firstTime ? S.sshTrust : S.sshHostKeyTrustNew),
        ),
      ],
    ),
  );
  return accepted == true
      ? SshHostKeyDecision.accept
      : SshHostKeyDecision.reject;
}
