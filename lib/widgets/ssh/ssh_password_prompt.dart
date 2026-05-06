import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';

/// Single shared dialog for password / key passphrase. `passphrase`
/// flips the title and surrounding language. Returns the entered
/// secret on Accept, null on Cancel.
///
/// Used by:
///   - `SshController` (via the bound `passwordRequester` /
///     `passphraseRequester` closures) when the vault doesn't have
///     the relevant secret cached.
///   - `SshHostDialog` for the inline "Test connection" button.
Future<String?> showSshPasswordPrompt(
  BuildContext context, {
  required SshHost host,
  bool passphrase = false,
}) async {
  final ctrl = TextEditingController();
  return showDialog<String?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Text(
        passphrase ? S.sshHostFieldPassphrase : S.sshHostAuthPassword,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 380),
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
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                hintText: passphrase
                    ? S.sshHostFieldPassphrase
                    : S.sshHostFieldPassword,
                isDense: true,
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text(S.cancel),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(ctrl.text),
          child: const Text(S.ok),
        ),
      ],
    ),
  );
}
