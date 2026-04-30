import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

/// First step in the new-project wizard: nudge the user to install
/// and run Ollama.
///
/// Three terminal states the dialog can land in:
///
///   * **ready**   — `ollama --version` succeeded AND the local
///                   API responded. Show a green "you're set" panel
///                   plus optional `ollama pull` / `ollama signin`
///                   tips, then Continue.
///   * **installedNotRunning** — CLI is on PATH but the daemon
///                   isn't reachable. Tell them to start the Ollama
///                   app / `ollama serve`. Retry button.
///   * **missing** — CLI not on PATH. Show the download link
///                   (ollama.com/download) plus the post-install
///                   tips so they only have to read the dialog
///                   once. Retry button rechecks after they install.
///
/// Skip is always available — Ollama is optional. Cloud providers
/// alone are a perfectly fine setup.
Future<void> showOllamaSetupDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const _OllamaSetupDialog(),
  );
}

enum _Phase { offering, checking, ready, installedNotRunning, missing }

class _OllamaSetupDialog extends StatefulWidget {
  const _OllamaSetupDialog();

  @override
  State<_OllamaSetupDialog> createState() => _OllamaSetupDialogState();
}

class _OllamaSetupDialogState extends State<_OllamaSetupDialog> {
  _Phase _phase = _Phase.offering;

  Future<void> _runCheck() async {
    setState(() => _phase = _Phase.checking);
    final state = context.read<AppState>();
    // Run both probes in parallel — `isInstalled` shells out to
    // `ollama --version`, `isReachable` hits the local API. Either
    // one alone is misleading; together they tell us which of the
    // three terminal states to land in.
    final results = await Future.wait([
      state.ollamaService.isInstalled(),
      state.ollamaService.isReachable(),
    ]);
    if (!mounted) return;
    final installed = results[0];
    final reachable = results[1];
    setState(() {
      if (reachable) {
        // Reachable implies the daemon is up. Treat as ready
        // even if `ollama --version` somehow failed (e.g. on a
        // remote endpoint or a sandboxed CLI).
        _phase = _Phase.ready;
      } else if (installed) {
        _phase = _Phase.installedNotRunning;
      } else {
        _phase = _Phase.missing;
      }
    });
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 560,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: switch (_phase) {
            _Phase.offering => _buildOffer(),
            _Phase.checking => _buildBusy(),
            _Phase.ready => _buildReady(),
            _Phase.installedNotRunning => _buildInstalledNotRunning(),
            _Phase.missing => _buildMissing(),
          },
        ),
      ),
    );
  }

  Widget _buildOffer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          icon: Icons.memory_outlined,
          title: S.ollamaSetupTitle,
        ),
        const SizedBox(height: 12),
        const Text(
          S.ollamaSetupBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _SkipButton(onPressed: _close),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.search,
              label: S.ollamaSetupCheck,
              onPressed: _runCheck,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBusy() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _Header(
          icon: Icons.memory_outlined,
          title: S.ollamaSetupTitle,
        ),
        const SizedBox(height: 18),
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: DuckColors.accentCyan,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          S.ollamaSetupChecking,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildReady() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          icon: Icons.check_circle_outline,
          title: S.ollamaStateReadyTitle,
          accent: DuckColors.accentMint,
        ),
        const SizedBox(height: 12),
        const Text(
          S.ollamaStateReadyBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        const _NextStepsPanel(),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _PrimaryButton(
              icon: Icons.arrow_forward,
              label: S.ollamaSetupContinue,
              onPressed: _close,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildInstalledNotRunning() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          icon: Icons.power_settings_new,
          title: S.ollamaStateInstalledNotRunningTitle,
          accent: DuckColors.stateWarn,
        ),
        const SizedBox(height: 12),
        const Text(
          S.ollamaStateInstalledNotRunningBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        const _NextStepsPanel(),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _SkipButton(onPressed: _close),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.refresh,
              label: S.ollamaSetupRetry,
              onPressed: _runCheck,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMissing() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          icon: Icons.cloud_download_outlined,
          title: S.ollamaStateMissingTitle,
          accent: DuckColors.stateWarn,
        ),
        const SizedBox(height: 12),
        const Text(
          S.ollamaStateMissingBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        const _DownloadLinkRow(),
        const SizedBox(height: 14),
        const _NextStepsPanel(),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _SkipButton(onPressed: _close),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.refresh,
              label: S.ollamaSetupRetry,
              onPressed: _runCheck,
            ),
          ],
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;
  const _Header({
    required this.icon,
    required this.title,
    this.accent = DuckColors.accentCyan,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Inline `ollama.com/download` link. Same `Process.start` browser-launch
/// pattern as `_SyncthingAbout` in `settings_view.dart` so we don't
/// pull in `url_launcher` for one URL.
class _DownloadLinkRow extends StatelessWidget {
  const _DownloadLinkRow();

  static const _url = 'https://ollama.com/download';

  Future<void> _open() async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', _url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [_url]);
      } else {
        await Process.start('xdg-open', [_url]);
      }
    } catch (_) {
      // Best-effort. The label still shows the URL so users can
      // copy it manually if no http(s) handler is registered.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.open_in_new,
            size: 14,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 8),
          Text.rich(
            TextSpan(
              text: S.ollamaDownloadLabel,
              style: const TextStyle(
                fontSize: 12.5,
                color: DuckColors.accentCyan,
                decoration: TextDecoration.underline,
                fontWeight: FontWeight.w500,
              ),
              recognizer: TapGestureRecognizer()..onTap = _open,
            ),
          ),
        ],
      ),
    );
  }
}

/// Post-install tips: `ollama pull <model>` for local models and
/// `ollama signin` for Ollama Cloud. Identical content shown in both
/// the `ready` (as a confirmation) and `missing`/`installedNotRunning`
/// (as preparation) phases — keeps the user from having to come back
/// to this screen later just to find the commands.
class _NextStepsPanel extends StatelessWidget {
  const _NextStepsPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Row(
            children: [
              Icon(Icons.tips_and_updates_outlined,
                  size: 14, color: DuckColors.accentDuck),
              SizedBox(width: 8),
              Text(
                S.ollamaNextStepsTitle,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.4,
                  color: DuckColors.fgPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            S.ollamaNextStepLocal,
            style: TextStyle(
              fontSize: 12,
              color: DuckColors.fgMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          const _CommandRow(command: S.ollamaNextStepLocalCmd),
          const SizedBox(height: 12),
          const Text(
            S.ollamaNextStepCloudIntro,
            style: TextStyle(
              fontSize: 12,
              color: DuckColors.fgMuted,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 6),
          const _CommandRow(command: S.ollamaNextStepCloudCmd),
          const SizedBox(height: 6),
          const Text(
            S.ollamaNextStepCloudHint,
            style: TextStyle(
              fontSize: 11.5,
              color: DuckColors.fgSubtle,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final String command;
  const _CommandRow({required this.command});

  Future<void> _copy(BuildContext context) async {
    // Strip trailing inline comments before copying so the user can
    // paste straight into a shell. The commented version is what we
    // display; the executable version is what we copy.
    final exe = command.split('#').first.trim();
    await Clipboard.setData(ClipboardData(text: exe));
    if (context.mounted) {
      showDuckToast(context, S.ollamaCopiedToast);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.55),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: SelectableText(
              command,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 12,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Tooltip(
            message: S.ollamaCopyCommand,
            child: IconButton(
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              iconSize: 14,
              icon: const Icon(Icons.copy_outlined),
              color: DuckColors.fgMuted,
              onPressed: () => _copy(context),
            ),
          ),
        ],
      ),
    );
  }
}

class _SkipButton extends StatelessWidget {
  final VoidCallback onPressed;
  const _SkipButton({required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: DuckColors.fgMuted,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      ),
      child: const Text(S.ollamaSetupSkip),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton.icon(
      icon: Icon(icon, size: 16),
      label: Text(label),
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: DuckColors.accentCyan,
        foregroundColor: DuckColors.bgDeepest,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
