import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_terminal_pre_processor.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Dialog that exposes the two shell helpers powering Lumen's SSH
/// integration "magic":
///
///   - `lumen-edit <path>` — prints an OSC 1337 sequence that the
///     pre-processor catches and routes to the editor's remote-mirror
///     open path. Net effect: type `lumen-edit foo.conf` in the
///     terminal → the file pops up in Lumen's editor with save-back.
///   - `_lumen_osc7` PROMPT_COMMAND — emits OSC 7 on every prompt
///     so the upload dialog and "drop here" hint can default to the
///     user's current shell directory rather than `$HOME`.
///
/// Two install paths:
///
///   - **Install for this session.** Types the snippet straight into
///     the active shell (and presses Enter), making the helpers
///     available *right now* without the user having to touch their
///     dotfiles. Trade-off: the snippet is visible in scrollback,
///     and it disappears when the shell exits.
///   - **Copy.** Puts the snippet on the clipboard so the user can
///     paste it into `~/.bashrc` / `~/.zshrc` for persistence.
///
/// We intentionally don't ssh-write the dotfiles for the user.
/// Editing someone else's shell init silently is a hostile move,
/// and the snippet is short enough that "copy + paste" is a
/// reasonable ask.
Future<void> showSshShellHelpersDialog(
  BuildContext context, {
  required SshController ssh,
  required String sessionId,
}) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => _SshShellHelpersDialog(ssh: ssh, sessionId: sessionId),
  );
}

class _SshShellHelpersDialog extends StatelessWidget {
  final SshController ssh;
  final String sessionId;
  const _SshShellHelpersDialog({required this.ssh, required this.sessionId});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(
              color: DuckColors.glassSeam,
              height: 1,
              thickness: 0.5,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Block(
                      title: S.sshShellHelpersLumenEditTitle,
                      blurb: S.sshShellHelpersLumenEditBlurb,
                      snippet: lumenEditShellSnippet(),
                      onInstallSession: () => _installInSession(
                        context,
                        '${lumenEditShellSnippet()}\n',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _Block(
                      title: S.sshShellHelpersLumenGrabTitle,
                      blurb: S.sshShellHelpersLumenGrabBlurb,
                      snippet: lumenGrabShellSnippet(),
                      onInstallSession: () => _installInSession(
                        context,
                        '${lumenGrabShellSnippet()}\n',
                      ),
                    ),
                    const SizedBox(height: 14),
                    _Block(
                      title: S.sshShellHelpersOsc7Title,
                      blurb: S.sshShellHelpersOsc7Blurb,
                      snippet: osc7PromptSnippet(),
                      onInstallSession: () => _installInSession(
                        context,
                        '${osc7PromptSnippet()}\n',
                      ),
                    ),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: DuckColors.bgChip,
                        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                        border: Border.all(
                          color: DuckColors.glassSeam,
                          width: 0.5,
                        ),
                      ),
                      child: const Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline,
                            size: 14,
                            color: DuckColors.fgMuted,
                          ),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              S.sshShellHelpersPersistHint,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: DuckColors.fgMuted,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(
              color: DuckColors.glassSeam,
              height: 1,
              thickness: 0.5,
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
              child: Row(
                children: [
                  TextButton.icon(
                    icon: const Icon(Icons.copy_all, size: 13),
                    label: const Text(S.sshShellHelpersCopyAll),
                    onPressed: () => _copyAll(context),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text(S.close),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return const Padding(
      padding: EdgeInsets.fromLTRB(18, 14, 18, 10),
      child: Row(
        children: [
          Icon(
            Icons.terminal_outlined,
            size: 14,
            color: DuckColors.accentCyan,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              S.sshShellHelpersTitle,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _installInSession(BuildContext context, String snippet) async {
    try {
      await ssh.pasteIntoSession(sessionId, snippet);
      if (!context.mounted) return;
      showDuckToast(context, S.sshShellHelpersInstalled);
    } catch (e) {
      if (!context.mounted) return;
      showDuckToast(context, '${S.error}: $e');
    }
  }

  Future<void> _copyAll(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: allShellHelpers()));
    if (!context.mounted) return;
    showDuckToast(context, S.sshShellHelpersCopied);
  }
}

/// One snippet block: title + blurb + monospace box + per-block
/// "Copy" / "Install for this session" actions.
class _Block extends StatelessWidget {
  final String title;
  final String blurb;
  final String snippet;
  final Future<void> Function() onInstallSession;
  const _Block({
    required this.title,
    required this.blurb,
    required this.snippet,
    required this.onInstallSession,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: DuckColors.fgPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          blurb,
          style: const TextStyle(
            fontSize: 11.5,
            color: DuckColors.fgMuted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: DuckColors.bgDeepest,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: SelectableText(
            snippet,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: DuckColors.fgPrimary,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            TextButton.icon(
              icon: const Icon(Icons.content_copy, size: 12),
              label: const Text(S.copy),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: snippet));
                if (!context.mounted) return;
                showDuckToast(context, S.sshShellHelpersCopied);
              },
            ),
            TextButton.icon(
              icon: const Icon(Icons.bolt, size: 12),
              label: const Text(S.sshShellHelpersInstallSession),
              onPressed: () => onInstallSession(),
            ),
          ],
        ),
      ],
    );
  }
}
