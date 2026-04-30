import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import 'backup_service.dart';
import 'git_service.dart';
import 'preferences_service.dart';

/// Owns the periodic backup `Timer` and orchestrates the backup → optional
/// `git add/commit` → optional `git push` sequence. Settings are persisted
/// through [PreferencesService] so they survive restarts.
///
/// The workspace is fetched lazily on every fire via [workspacePathProvider]
/// because the user can switch projects between ticks; capturing it once
/// would happily back up the wrong directory after a workspace change.
class AutoBackupScheduler extends ChangeNotifier {
  AutoBackupScheduler({
    required this.backups,
    required this.prefs,
    required this.workspacePathProvider,
    GitService? git,
  }) : git = git ?? GitService();

  final BackupService backups;
  final PreferencesService prefs;
  final GitService git;
  final Future<String?> Function() workspacePathProvider;

  /// 5 minutes is already aggressive given workspaces can hit hundreds of
  /// MB; anything tighter than that is just abuse on the disk.
  static const int kMinMinutes = 5;
  static const int kMaxMinutes = 1440;
  static const int kDefaultMinutes = 30;

  bool _enabled = false;
  int _intervalMinutes = kDefaultMinutes;
  bool _gitAutoCommit = false;
  bool _gitAutoPush = false;

  bool _busy = false;
  Timer? _timer;
  DateTime? _lastRunAt;
  DateTime? _nextRunAt;
  String? _lastStatus;

  bool get enabled => _enabled;
  int get intervalMinutes => _intervalMinutes;
  bool get gitAutoCommit => _gitAutoCommit;
  bool get gitAutoPush => _gitAutoPush;
  bool get isRunning => _busy;
  DateTime? get lastRunAt => _lastRunAt;
  DateTime? get nextRunAt => _nextRunAt;
  String? get lastStatus => _lastStatus;

  Future<void> init() async {
    _enabled = await prefs.getAutoBackupEnabled();
    _intervalMinutes = _clamp(await prefs.getAutoBackupIntervalMinutes());
    _gitAutoCommit = await prefs.getAutoBackupGitAutoCommit();
    _gitAutoPush = await prefs.getAutoBackupGitAutoPush();
    if (_enabled) _startTimer();
    notifyListeners();
  }

  Future<void> setEnabled(bool v) async {
    if (_enabled == v) return;
    _enabled = v;
    await prefs.setAutoBackupEnabled(v);
    if (v) {
      _startTimer();
    } else {
      _stopTimer();
    }
    notifyListeners();
  }

  Future<void> setIntervalMinutes(int v) async {
    final clamped = _clamp(v);
    if (clamped == _intervalMinutes) return;
    _intervalMinutes = clamped;
    await prefs.setAutoBackupIntervalMinutes(clamped);
    if (_enabled) _startTimer();
    notifyListeners();
  }

  Future<void> setGitAutoCommit(bool v) async {
    if (_gitAutoCommit == v) return;
    _gitAutoCommit = v;
    await prefs.setAutoBackupGitAutoCommit(v);
    notifyListeners();
  }

  Future<void> setGitAutoPush(bool v) async {
    if (_gitAutoPush == v) return;
    _gitAutoPush = v;
    await prefs.setAutoBackupGitAutoPush(v);
    notifyListeners();
  }

  /// Trigger one cycle manually. Safe to call regardless of enabled state.
  Future<void> runOnce() async {
    // Skip overlapping ticks — backups walk the whole tree and stream into
    // a single zip; a second pass while the first is mid-write would
    // corrupt the encoder's open archive.
    if (_busy) return;
    _busy = true;
    notifyListeners();

    final parts = <String>[];
    try {
      final ws = await workspacePathProvider();
      if (ws == null || ws.isEmpty) {
        _lastStatus = S.backupNoWorkspace;
      } else {
        bool backupOk = false;
        try {
          await backups.backup(ws);
          parts.add(S.backupDone);
          backupOk = true;
        } catch (e) {
          parts.add('${S.backupFailed}: $e');
        }

        if (backupOk && (_gitAutoCommit || _gitAutoPush)) {
          final repo = await git.isRepo(ws);
          if (!repo) {
            parts.add(S.backupGitNotARepo);
          } else {
            if (_gitAutoCommit) {
              final message =
                  'lumen: auto-backup ${DateTime.now().toIso8601String()}';
              final commit = await git.autoCommit(ws, message: message);
              if (commit.ok) {
                parts.add(
                  commit.message == 'no changes'
                      ? '${S.backupGitOk} (no changes)'
                      : S.backupGitOk,
                );
                if (_gitAutoPush) {
                  final push = await git.push(ws);
                  parts.add(
                    push.ok
                        ? S.backupGitPushed
                        : '${S.backupGitFailed}: ${push.message}',
                  );
                }
              } else {
                parts.add('${S.backupGitFailed}: ${commit.message}');
              }
            } else if (_gitAutoPush) {
              // commit off + push on is unusual but support it for the
              // user who manages commits manually but wants auto-push.
              final push = await git.push(ws);
              parts.add(
                push.ok
                    ? S.backupGitPushed
                    : '${S.backupGitFailed}: ${push.message}',
              );
            }
          }
        }

        _lastStatus = parts.join(' · ');
      }
    } catch (e) {
      _lastStatus = '${S.backupFailed}: $e';
    } finally {
      _busy = false;
      _lastRunAt = DateTime.now();
      if (_enabled) {
        _nextRunAt = _lastRunAt!.add(Duration(minutes: _intervalMinutes));
      }
      notifyListeners();
    }
  }

  void _startTimer() {
    _stopTimer();
    final dur = Duration(minutes: _intervalMinutes);
    // First fire is now+interval, never immediate — the user just enabled
    // it, an instant backup would feel like the toggle "did" something
    // unexpected.
    _nextRunAt = DateTime.now().add(dur);
    _timer = Timer.periodic(dur, (_) => runOnce());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
    _nextRunAt = null;
  }

  int _clamp(int v) {
    if (v < kMinMinutes) return kMinMinutes;
    if (v > kMaxMinutes) return kMaxMinutes;
    return v;
  }

  @override
  void dispose() {
    _stopTimer();
    super.dispose();
  }
}
