import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/auto_backup_scheduler.dart';
import '../../services/git_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Collapsible "Automatic Backups" section embedded in the backup dialog.
/// Listens to [AppState.autoBackup] so toggling settings rebuilds in place,
/// and runs a low-frequency ticker so the "next run / last run" relative
/// times don't go stale while the dialog stays open.
class AutoBackupSection extends StatefulWidget {
  const AutoBackupSection({super.key});

  @override
  State<AutoBackupSection> createState() => _AutoBackupSectionState();
}

class _AutoBackupSectionState extends State<AutoBackupSection> {
  final GitService _git = GitService();
  Timer? _ticker;
  String? _lastCheckedWorkspace;
  bool _isRepo = false;
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    // Cheap rebuild every 30s to keep relative-time labels honest.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refreshRepoStatus(String? ws) async {
    if (ws == _lastCheckedWorkspace) return;
    _lastCheckedWorkspace = ws;
    final r = ws != null && ws.isNotEmpty ? await _git.isRepo(ws) : false;
    if (!mounted) return;
    setState(() => _isRepo = r);
  }

  String _formatRelative(DateTime? t) {
    if (t == null) return S.backupAutoNever;
    final now = DateTime.now();
    final diff = t.difference(now);
    final past = diff.isNegative;
    final secs = diff.abs().inSeconds;
    final mins = diff.abs().inMinutes;
    final hrs = diff.abs().inHours;
    final days = diff.abs().inDays;

    String body;
    if (secs < 60) {
      body = '${secs}s';
    } else if (mins < 60) {
      body = '${mins}m';
    } else if (hrs < 48) {
      body = '${hrs}h';
    } else {
      body = '${days}d';
    }
    return past ? '$body ago' : 'in $body';
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final ws = state.currentDirectory;
    _refreshRepoStatus(ws);

    return AnimatedBuilder(
      animation: state.autoBackup,
      builder: (context, _) {
        final s = state.autoBackup;
        return Container(
          decoration: BoxDecoration(
            // Subtly darker chip than the surrounding glass dialog so the
            // section reads as a grouped block, but still translucent so
            // the dialog's blur shows through.
            color: DuckColors.bgChip.withValues(alpha: 0.45),
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          ),
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(s),
              if (_expanded) ...[
                const SizedBox(height: 8),
                _intervalRow(s),
                const SizedBox(height: 8),
                _gitCommitRow(s),
                _gitPushRow(s),
                const SizedBox(height: 10),
                _statusFooter(s),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _header(AutoBackupScheduler s) {
    return Row(
      children: [
        Icon(
          s.enabled ? Icons.timer : Icons.timer_outlined,
          size: 16,
          color: s.enabled ? DuckColors.accentMint : DuckColors.fgMuted,
        ),
        const SizedBox(width: 8),
        const Expanded(
          child: Text(
            S.backupAutomatic,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: DuckColors.fgPrimary,
            ),
          ),
        ),
        IconButton(
          tooltip: S.backupAutoRunNow,
          icon: const Icon(Icons.play_arrow, size: 16),
          onPressed: s.isRunning ? null : () => s.runOnce(),
        ),
        Switch(
          value: s.enabled,
          onChanged: (v) => s.setEnabled(v),
        ),
        IconButton(
          icon: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 16,
          ),
          onPressed: () => setState(() => _expanded = !_expanded),
        ),
      ],
    );
  }

  Widget _intervalRow(AutoBackupScheduler s) {
    return Row(
      children: [
        const Expanded(
          child: Text(
            S.backupInterval,
            style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
          ),
        ),
        IconButton(
          tooltip: '−',
          icon: const Icon(Icons.remove, size: 14),
          onPressed: s.intervalMinutes > AutoBackupScheduler.kMinMinutes
              ? () => s.setIntervalMinutes(_step(s.intervalMinutes, -1))
              : null,
        ),
        Container(
          width: 64,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          ),
          child: Text(
            '${s.intervalMinutes} ${S.backupAutoMinutes}',
            style: const TextStyle(
              fontSize: 12,
              color: DuckColors.fgPrimary,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ),
        IconButton(
          tooltip: '+',
          icon: const Icon(Icons.add, size: 14),
          onPressed: s.intervalMinutes < AutoBackupScheduler.kMaxMinutes
              ? () => s.setIntervalMinutes(_step(s.intervalMinutes, 1))
              : null,
        ),
      ],
    );
  }

  /// Progressive stepping so users aren't tapping +1 four hundred times to
  /// get from 30 minutes to 8 hours.
  int _step(int current, int direction) {
    int delta;
    if (current < 15) {
      delta = 5;
    } else if (current < 60) {
      delta = 15;
    } else if (current < 360) {
      delta = 30;
    } else {
      delta = 60;
    }
    return current + delta * direction;
  }

  Widget _gitCommitRow(AutoBackupScheduler s) {
    return _toggleTile(
      title: S.backupGitAutoCommit,
      description: _isRepo ? S.backupGitAutoCommitDesc : S.backupGitNotARepo,
      value: s.gitAutoCommit,
      onChanged: (v) => s.setGitAutoCommit(v),
      muted: !_isRepo,
    );
  }

  Widget _gitPushRow(AutoBackupScheduler s) {
    return _toggleTile(
      title: S.backupGitAutoPush,
      description: _isRepo ? S.backupGitAutoPushDesc : S.backupGitNotARepo,
      value: s.gitAutoPush,
      onChanged: s.gitAutoCommit ? (v) => s.setGitAutoPush(v) : null,
      muted: !_isRepo || !s.gitAutoCommit,
    );
  }

  Widget _toggleTile({
    required String title,
    required String description,
    required bool value,
    required ValueChanged<bool>? onChanged,
    required bool muted,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12,
                    color: muted ? DuckColors.fgSubtle : DuckColors.fgPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ],
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _statusFooter(AutoBackupScheduler s) {
    final last = _formatRelative(s.lastRunAt);
    final next = s.enabled ? _formatRelative(s.nextRunAt) : '—';
    final running = s.isRunning;
    final status = s.lastStatus;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (running)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5),
                )
              else
                const Icon(Icons.history, size: 12, color: DuckColors.fgSubtle),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  running
                      ? S.backupAutoRunning
                      : '${S.backupAutoLastRun}: $last  •  ${S.backupAutoNextRun}: $next',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ),
            ],
          ),
          if (status != null && status.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              status,
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.fgSubtle,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
