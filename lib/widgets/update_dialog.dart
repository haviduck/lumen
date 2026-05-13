import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../services/update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

/// Opens the update dialog. Routes through the `UpdateService` from
/// Provider so all state (current release info, download progress,
/// staged installer path, error state) survives the dialog being
/// closed + reopened mid-download.
///
/// Behavior on close:
///   - If the user is mid-download we DON'T cancel — closing the
///     dialog just dismisses the visual. The next reopen picks up
///     where it left off.
///   - If the install has already been launched (`installing` state)
///     the dialog stays open with the spinner; Lumen is about to be
///     restarted by the installer anyway.
Future<void> showUpdateDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const _UpdateDialog(),
  );
}

class _UpdateDialog extends StatefulWidget {
  const _UpdateDialog();

  @override
  State<_UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<_UpdateDialog> {
  bool _initialCheckIssued = false;

  @override
  void initState() {
    super.initState();
    // If we land on the dialog from a "Check for updates" gesture
    // and the service is idle, kick a fresh check so the user sees
    // an answer immediately. Re-opening for an already-known update
    // skips the round-trip.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (_initialCheckIssued) return;
      _initialCheckIssued = true;
      if (!mounted) return;
      final s = context.read<UpdateService>();
      if (s.status == UpdateStatus.idle &&
          (s.release == null || !s.hasActionableUpdate)) {
        await s.checkForUpdates(force: true);
      }
    });
  }

  void _close() {
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _downloadAndInstall() async {
    final service = context.read<UpdateService>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    final hostContext = context;
    final path = await service.downloadInstaller();
    if (!mounted) return;
    if (path == null) {
      return; // _ErrorBlock will render service.error
    }
    final ok = await service.launchInstaller();
    if (!ok) return;
    if (!hostContext.mounted) return;
    // The installer is now running detached in the background.
    // Lumen needs to close so the installer can swap files. Route
    // through the AppCloseGuard (which owns the unsaved-changes
    // prompt + the actual `destroy()`) instead of calling exit()
    // directly.
    showDuckToast(hostContext, S.updateClosingLumen);
    messenger?.showSnackBar(
      const SnackBar(content: Text(S.updateClosingLumen)),
    );
    try {
      await windowManager.close();
    } catch (e) {
      // If windowManager isn't usable (e.g. a future host port),
      // fall back to a clean process exit. We've already launched
      // the installer, so the worst case is the user has to relaunch
      // Lumen manually after install.
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<UpdateService>();
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 560,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: _bodyFor(service),
        ),
      ),
    );
  }

  Widget _bodyFor(UpdateService s) {
    if (!s.enabled) {
      return _UnsupportedBlock(onClose: _close, currentVersion: s.currentVersion);
    }
    switch (s.status) {
      case UpdateStatus.checking:
        return _CheckingBlock(currentVersion: s.currentVersion);
      case UpdateStatus.idle:
        if (s.release != null && s.hasActionableUpdate) {
          return _AvailableBlock(
            service: s,
            onSkip: () async {
              await s.skipCurrentRelease();
              _close();
            },
            onLater: () {
              s.dismissForNow();
              _close();
            },
            onInstall: _downloadAndInstall,
          );
        }
        return _UpToDateBlock(
          currentVersion: s.currentVersion,
          lastCheck: s.lastCheck,
          onRecheck: () => s.checkForUpdates(force: true),
          onClose: _close,
        );
      case UpdateStatus.available:
        return _AvailableBlock(
          service: s,
          onSkip: () async {
            await s.skipCurrentRelease();
            _close();
          },
          onLater: () {
            s.dismissForNow();
            _close();
          },
          onInstall: _downloadAndInstall,
        );
      case UpdateStatus.downloading:
        return _DownloadingBlock(service: s);
      case UpdateStatus.ready:
        return _ReadyBlock(
          service: s,
          onInstall: _downloadAndInstall,
          onCancel: () async {
            await s.reset();
          },
        );
      case UpdateStatus.installing:
        return const _InstallingBlock();
      case UpdateStatus.error:
        return _ErrorBlock(
          service: s,
          onRetry: () => s.checkForUpdates(force: true),
          onClose: _close,
        );
    }
  }
}

class _UnsupportedBlock extends StatelessWidget {
  final String currentVersion;
  final VoidCallback onClose;
  const _UnsupportedBlock({required this.currentVersion, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(
          icon: Icons.system_update_alt,
          title: S.updateDialogTitle,
        ),
        const SizedBox(height: 12),
        Text(
          S.updateUnsupportedBodyFmt(currentVersion),
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [_PrimaryButton(label: S.close, onPressed: onClose)],
        ),
      ],
    );
  }
}

class _CheckingBlock extends StatelessWidget {
  final String currentVersion;
  const _CheckingBlock({required this.currentVersion});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _DialogHeader(
          icon: Icons.system_update_alt,
          title: S.updateDialogTitle,
        ),
        const SizedBox(height: 18),
        const SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: DuckColors.accentCyan,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          S.updateCheckingFmt(currentVersion),
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _UpToDateBlock extends StatelessWidget {
  final String currentVersion;
  final DateTime? lastCheck;
  final VoidCallback onRecheck;
  final VoidCallback onClose;
  const _UpToDateBlock({
    required this.currentVersion,
    required this.lastCheck,
    required this.onRecheck,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final last = lastCheck;
    final lastLine = last == null
        ? S.updateLastCheckNever
        : S.updateLastCheckFmt(_formatTimestamp(last.toLocal()));
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(
          icon: Icons.check_circle_outline,
          title: S.updateUpToDateTitle,
          accent: DuckColors.accentMint,
        ),
        const SizedBox(height: 12),
        Text(
          S.updateUpToDateBodyFmt(currentVersion),
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          lastLine,
          style: const TextStyle(
            fontSize: 11.5,
            color: DuckColors.fgSubtle,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _GhostButton(label: S.updateRecheck, onPressed: onRecheck),
            const SizedBox(width: 6),
            _PrimaryButton(label: S.close, onPressed: onClose),
          ],
        ),
      ],
    );
  }
}

class _AvailableBlock extends StatelessWidget {
  final UpdateService service;
  final VoidCallback onSkip;
  final VoidCallback onLater;
  final VoidCallback onInstall;
  const _AvailableBlock({
    required this.service,
    required this.onSkip,
    required this.onLater,
    required this.onInstall,
  });

  @override
  Widget build(BuildContext context) {
    final r = service.release!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DialogHeader(
          icon: Icons.cloud_download_outlined,
          title: S.updateAvailableTitleFmt(r.version),
          accent: DuckColors.accentCyan,
        ),
        const SizedBox(height: 8),
        Text(
          S.updateCurrentVsNextFmt(service.currentVersion, r.version),
          style: const TextStyle(
            fontSize: 11.5,
            color: DuckColors.fgSubtle,
          ),
        ),
        const SizedBox(height: 14),
        _ReleaseNotesBox(notes: r.body),
        const SizedBox(height: 12),
        const _SmartScreenWarning(),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _GhostButton(
              label: S.updateSkipVersion,
              onPressed: onSkip,
              tone: _GhostTone.subtle,
            ),
            const SizedBox(width: 4),
            _GhostButton(label: S.updateLater, onPressed: onLater),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.download_outlined,
              label: S.updateInstallNow,
              onPressed: onInstall,
            ),
          ],
        ),
      ],
    );
  }
}

class _DownloadingBlock extends StatelessWidget {
  final UpdateService service;
  const _DownloadingBlock({required this.service});

  @override
  Widget build(BuildContext context) {
    final pct = (service.downloadProgress * 100).toStringAsFixed(0);
    final mbTotal = service.release == null
        ? null
        : (service.release!.installerBytes / 1024 / 1024).toStringAsFixed(1);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DialogHeader(
          icon: Icons.downloading_outlined,
          title: S.updateDownloadingTitle,
          accent: DuckColors.accentCyan,
        ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: service.downloadProgress.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: DuckColors.bgChip,
            valueColor: const AlwaysStoppedAnimation(DuckColors.accentCyan),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          mbTotal == null
              ? S.updateDownloadingPctFmt(pct)
              : S.updateDownloadingPctSizeFmt(pct, mbTotal),
          style: const TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
        ),
        const SizedBox(height: 14),
        const Text(
          S.updateDownloadingHint,
          style: TextStyle(fontSize: 11.5, color: DuckColors.fgSubtle, height: 1.5),
        ),
      ],
    );
  }
}

class _ReadyBlock extends StatelessWidget {
  final UpdateService service;
  final VoidCallback onInstall;
  final VoidCallback onCancel;
  const _ReadyBlock({
    required this.service,
    required this.onInstall,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final r = service.release!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DialogHeader(
          icon: Icons.task_alt,
          title: S.updateReadyTitleFmt(r.version),
          accent: DuckColors.accentMint,
        ),
        const SizedBox(height: 12),
        const Text(
          S.updateReadyBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _GhostButton(label: S.cancel, onPressed: onCancel),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.play_arrow,
              label: S.updateRestartAndInstall,
              onPressed: onInstall,
            ),
          ],
        ),
      ],
    );
  }
}

class _InstallingBlock extends StatelessWidget {
  const _InstallingBlock();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _DialogHeader(
          icon: Icons.system_update_alt,
          title: S.updateInstallingTitle,
          accent: DuckColors.accentMint,
        ),
        const SizedBox(height: 18),
        const SizedBox(
          width: 30,
          height: 30,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: DuckColors.accentMint,
          ),
        ),
        const SizedBox(height: 14),
        const Text(
          S.updateInstallingBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final UpdateService service;
  final VoidCallback onRetry;
  final VoidCallback onClose;
  const _ErrorBlock({
    required this.service,
    required this.onRetry,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(
          icon: Icons.error_outline,
          title: S.updateErrorTitle,
          accent: DuckColors.stateError,
        ),
        const SizedBox(height: 12),
        Text(
          service.error ?? S.updateErrorGeneric,
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        const _ReleaseLinkRow(),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _GhostButton(label: S.close, onPressed: onClose),
            const SizedBox(width: 6),
            _PrimaryButton(
              icon: Icons.refresh,
              label: S.updateRetry,
              onPressed: onRetry,
            ),
          ],
        ),
      ],
    );
  }
}

class _ReleaseNotesBox extends StatelessWidget {
  final String notes;
  const _ReleaseNotesBox({required this.notes});

  @override
  Widget build(BuildContext context) {
    final trimmed = notes.trim();
    final body = trimmed.isEmpty ? S.updateNoReleaseNotes : trimmed;
    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Scrollbar(
        child: SingleChildScrollView(
          child: SelectableText(
            body,
            style: const TextStyle(
              fontSize: 12,
              color: DuckColors.fgMuted,
              height: 1.5,
            ),
          ),
        ),
      ),
    );
  }
}

class _SmartScreenWarning extends StatelessWidget {
  const _SmartScreenWarning();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip.withValues(alpha: 0.55),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.shield_outlined,
            size: 14,
            color: DuckColors.stateWarn,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              S.updateSmartScreenWarning,
              style: TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgMuted,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ReleaseLinkRow extends StatelessWidget {
  const _ReleaseLinkRow();
  static const _url = 'https://github.com/haviduck/lumen/releases';

  Future<void> _open() async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', _url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [_url]);
      } else {
        await Process.start('xdg-open', [_url]);
      }
    } catch (_) {}
  }

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: _url));
    if (context.mounted) {
      showDuckToast(context, S.updateLinkCopied);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Row(
        children: [
          const Icon(Icons.open_in_new, size: 13, color: DuckColors.accentCyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: S.updateOpenReleasesPage,
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.accentCyan,
                  decoration: TextDecoration.underline,
                ),
                recognizer: TapGestureRecognizer()..onTap = _open,
              ),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            iconSize: 13,
            icon: const Icon(Icons.copy_outlined),
            color: DuckColors.fgMuted,
            tooltip: S.updateCopyLink,
            onPressed: () => _copy(context),
          ),
        ],
      ),
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;
  const _DialogHeader({
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

enum _GhostTone { regular, subtle }

class _GhostButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final _GhostTone tone;
  const _GhostButton({
    required this.label,
    required this.onPressed,
    this.tone = _GhostTone.regular,
  });

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: tone == _GhostTone.subtle
            ? DuckColors.fgSubtle
            : DuckColors.fgMuted,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      child: Text(label),
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  final IconData? icon;
  final String label;
  final VoidCallback onPressed;
  const _PrimaryButton({
    this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final base = ElevatedButton.styleFrom(
      backgroundColor: DuckColors.accentCyan,
      foregroundColor: DuckColors.bgDeepest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );
    if (icon != null) {
      return ElevatedButton.icon(
        icon: Icon(icon, size: 16),
        label: Text(label),
        onPressed: onPressed,
        style: base,
      );
    }
    return ElevatedButton(
      onPressed: onPressed,
      style: base,
      child: Text(label),
    );
  }
}

String _formatTimestamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}
