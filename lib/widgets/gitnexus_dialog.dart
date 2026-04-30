import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/gitnexus_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';

/// One step in the new-project wizard: offer to set up GitNexus on
/// the freshly-created workspace.
///
/// What it actually does on "Set up GitNexus":
///   1. Probe `npx --version` to confirm Node.js is on PATH.
///      → if absent, flip to the noNode informational variant.
///   2. `git init` the workspace if it isn't already a git repo
///      (GitNexus refuses to run outside a git tree).
///   3. `npx gitnexus analyze` in the workspace dir.
///
/// All steps run via `Process.run` with `runInShell: true` so
/// Windows resolves `npx.cmd` / `git.exe` from PATH the same way a
/// terminal would. Output is shown raw on success/failure for
/// transparency — first runs of `npx gitnexus` download a chunk of
/// JS and the user might want to confirm what landed.
///
/// **Skip is always available.** No silent assumptions, no automatic
/// "next time" — user can re-run the flow manually later.
Future<void> showGitNexusOnboardingDialog(
  BuildContext context, {
  required String workspacePath,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => _GitNexusDialog(workspacePath: workspacePath),
  );
}

enum _Phase { offering, running, result, noNode }

class _GitNexusDialog extends StatefulWidget {
  final String workspacePath;
  const _GitNexusDialog({required this.workspacePath});

  @override
  State<_GitNexusDialog> createState() => _GitNexusDialogState();
}

class _GitNexusDialogState extends State<_GitNexusDialog> {
  _Phase _phase = _Phase.offering;
  String _busyLabel = '';

  // Result-state fields. `_ok` distinguishes success from failure;
  // `_outputTail` is the last ~3 KB of the analyze stdout/stderr,
  // truncated to keep the dialog readable.
  bool _ok = false;
  String _resultMessage = '';
  String? _outputTail;

  Future<void> _setUp() async {
    setState(() {
      _phase = _Phase.running;
      _busyLabel = S.gitnexusCheckingNode;
    });

    final state = context.read<AppState>();
    final service = state.gitnexus;
    await service.refreshStatus();
    if (!mounted) return;
    if (service.status == GitNexusStatus.noNode) {
      if (!mounted) return;
      setState(() => _phase = _Phase.noNode);
      return;
    }

    // Analyze is managed by AppState.gitnexus so the explorer status icon and
    // Settings panel see the same hidden background job / output tail.
    if (!mounted) return;
    setState(() => _busyLabel = S.gitnexusRunningAnalyze);
    if (service.workspacePath != widget.workspacePath) {
      await service.bindWorkspace(widget.workspacePath);
    }
    await service.analyze();
    if (!mounted) return;

    if (service.status == GitNexusStatus.indexed) {
      setState(() {
        _phase = _Phase.result;
        _ok = true;
        _resultMessage =
            '`.gitnexus/` index built. The agent can now '
            'query GitNexus tools for symbol navigation and impact '
            'analysis on this codebase.';
        _outputTail = _tail(service.outputTail, 1500);
      });
    } else {
      _flipToError(
        'gitnexus analyze exited with an error. You can retry, or '
        'skip and run `npx gitnexus analyze` manually later.',
        service.outputTail,
      );
    }
  }

  void _flipToError(String message, String? rawOutput) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.result;
      _ok = false;
      _resultMessage = message;
      _outputTail = _tail(rawOutput ?? '', 2000);
    });
  }

  static String _tail(String s, int max) {
    if (s.length <= max) return s;
    return '…\n${s.substring(s.length - max)}';
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 540,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: switch (_phase) {
            _Phase.offering => _buildOffer(),
            _Phase.running => _buildBusy(),
            _Phase.noNode => _buildNoNode(),
            _Phase.result => _buildResult(),
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
          icon: Icons.account_tree_outlined,
          title: S.gitnexusTitle,
        ),
        const SizedBox(height: 12),
        const Text(
          S.gitnexusBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
          child: const Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14, color: DuckColors.fgSubtle),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  S.gitnexusRequirements,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.fgSubtle,
                    height: 1.45,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: DuckColors.fgMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              child: const Text(S.gitnexusSkip),
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text(S.gitnexusSetUp),
              onPressed: _setUp,
              style: ElevatedButton.styleFrom(
                backgroundColor: DuckColors.accentCyan,
                foregroundColor: DuckColors.bgDeepest,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
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
          icon: Icons.account_tree_outlined,
          title: S.gitnexusTitle,
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
        Text(
          _busyLabel,
          style: const TextStyle(
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

  Widget _buildNoNode() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(
          icon: Icons.error_outline,
          title: S.gitnexusNoNodeTitle,
          accent: DuckColors.stateWarn,
        ),
        const SizedBox(height: 12),
        const Text(
          S.gitnexusNoNodeBody,
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
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: DuckColors.accentCyan,
                foregroundColor: DuckColors.bgDeepest,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
              ),
              child: const Text(S.ok),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResult() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: _ok ? Icons.check_circle_outline : Icons.error_outline,
          title: _ok ? S.gitnexusSuccessTitle : S.gitnexusErrorTitle,
          accent: _ok ? DuckColors.accentMint : DuckColors.stateError,
        ),
        const SizedBox(height: 12),
        Text(
          _resultMessage,
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        if (_outputTail != null && _outputTail!.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            constraints: const BoxConstraints(maxHeight: 200),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _outputTail!,
                style: const TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 11,
                  color: DuckColors.fgSubtle,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!_ok) ...[
              TextButton(
                onPressed: _setUp,
                style: TextButton.styleFrom(
                  foregroundColor: DuckColors.accentCyan,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                child: const Text(S.gitnexusRetry),
              ),
              const SizedBox(width: 6),
            ],
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: DuckColors.accentCyan,
                foregroundColor: DuckColors.bgDeepest,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                textStyle: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: const Text(S.gitnexusDone),
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
