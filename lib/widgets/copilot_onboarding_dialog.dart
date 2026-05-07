import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state.dart';
import '../services/copilot_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_toast.dart';

/// First-run onboarding for the GitHub Copilot CLI integration. Walks
/// the user through the three concrete prerequisites in order:
///
///   1. Install Node.js / npm (link to nodejs.org).
///   2. `npm install -g @github/copilot` (button copies command).
///   3. `copilot` first-run login (button opens a terminal running the
///      `copilot` binary so the user can complete the device-code flow).
///
/// Each step shows a live status badge driven by
/// [CopilotService.probeAuthState] and refreshes whenever the user hits
/// the Re-check button — no polling, no hidden state.
Future<void> showCopilotOnboardingDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (_) => const _CopilotOnboardingDialog(),
  );
}

class _CopilotOnboardingDialog extends StatefulWidget {
  const _CopilotOnboardingDialog();

  @override
  State<_CopilotOnboardingDialog> createState() =>
      _CopilotOnboardingDialogState();
}

class _CopilotOnboardingDialogState extends State<_CopilotOnboardingDialog> {
  late Future<CopilotAuthState> _probe;

  @override
  void initState() {
    super.initState();
    _probe = _runProbe();
  }

  Future<CopilotAuthState> _runProbe() {
    return context.read<AppState>().refreshCopilotAuthState();
  }

  void _recheck() {
    setState(() {
      _probe = _runProbe();
    });
  }

  Future<void> _openBrowser(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {}
  }

  Future<void> _openTerminalForLogin() async {
    try {
      if (Platform.isWindows) {
        await Process.start(
          'cmd',
          ['/c', 'start', 'cmd', '/k', 'copilot'],
          runInShell: true,
        );
      } else if (Platform.isMacOS) {
        await Process.start('osascript', [
          '-e',
          'tell application "Terminal" to do script "copilot"',
        ]);
      } else {
        // Best-effort: try common terminal emulators.
        for (final term in ['x-terminal-emulator', 'gnome-terminal', 'konsole', 'xterm']) {
          try {
            await Process.start(term, ['-e', 'copilot']);
            return;
          } catch (_) {}
        }
      }
    } catch (_) {
      if (mounted) {
        showDuckToast(context, 'Could not launch terminal — run `copilot` manually.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: FutureBuilder<CopilotAuthState>(
            future: _probe,
            builder: (context, snap) {
              final state = snap.data;
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'GitHub Copilot CLI',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Lumen drives the official `copilot` binary for the GitHub Copilot provider. '
                    'Three one-time steps and you\'re done.',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: DuckColors.fgMuted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (state != null) _banner(state),
                  const SizedBox(height: 12),
                  _step(
                    n: 1,
                    title: 'Install Node.js (includes npm)',
                    description:
                        'Copilot CLI is distributed as an npm package, so you need Node.js first.',
                    actionLabel: 'Open nodejs.org',
                    onAction: () => _openBrowser('https://nodejs.org/'),
                  ),
                  const SizedBox(height: 8),
                  _step(
                    n: 2,
                    title: 'Install the Copilot CLI',
                    description: 'Run this in a terminal:',
                    code: 'npm install -g @github/copilot',
                  ),
                  const SizedBox(height: 8),
                  _step(
                    n: 3,
                    title: 'Sign in',
                    description:
                        'The first time you run `copilot` it walks you through a GitHub device-code login. '
                        'Lumen reuses that token automatically.',
                    actionLabel: 'Open terminal & run copilot',
                    onAction: _openTerminalForLogin,
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _recheck,
                        child: const Text('Re-check'),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _banner(CopilotAuthState s) {
    final (color, label) = switch (s) {
      CopilotAuthState.loggedIn => (
          DuckColors.stateOk,
          'Copilot CLI is installed and signed in. You\'re ready to chat.',
        ),
      CopilotAuthState.notLoggedIn => (
          DuckColors.stateWarn,
          'Copilot CLI is installed but not signed in. Run step 3.',
        ),
      CopilotAuthState.notInstalled => (
          DuckColors.stateWarn,
          'Copilot CLI not found in your global npm packages. Run step 2.',
        ),
      CopilotAuthState.unavailable => (
          DuckColors.fgMuted,
          'Could not probe Copilot CLI state (npm not on PATH?).',
        ),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _step({
    required int n,
    required String title,
    required String description,
    String? code,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: DuckColors.border, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 20,
                height: 20,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: DuckColors.bgChip,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '$n',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 28),
            child: Text(
              description,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.4,
              ),
            ),
          ),
          if (code != null)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 6),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: DuckColors.bgChip,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: SelectableText(
                  code,
                  style: const TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          if (actionLabel != null && onAction != null)
            Padding(
              padding: const EdgeInsets.only(left: 28, top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: onAction,
                  child: Text(actionLabel),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
