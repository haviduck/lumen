import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/backup_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'backup/auto_backup_section.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

class BackupDialog extends StatefulWidget {
  const BackupDialog({super.key});

  @override
  State<BackupDialog> createState() => _BackupDialogState();
}

class _BackupDialogState extends State<BackupDialog> {
  late final BackupService _svc = context.read<AppState>().backups;
  bool _busy = false;
  String? _currentFile;
  List<BackupRecord> _records = [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final list = await _svc.listBackups();
    if (!mounted) return;
    setState(() => _records = list);
  }

  Future<void> _runBackup() async {
    final ws = context.read<AppState>().currentDirectory;
    if (ws == null) return;
    setState(() {
      _busy = true;
      _currentFile = null;
    });
    try {
      await _svc.backup(
        ws,
        onProgress: (f) {
          setState(() => _currentFile = f);
        },
      );
      if (!mounted) return;
      showDuckToast(context, S.backupDone);
    } catch (e) {
      if (!mounted) return;
      showDuckToast(context, '${S.backupFailed}: $e');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      }
      _refresh();
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
    }
    return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
  }

  @override
  Widget build(BuildContext context) {
    final ws = context.watch<AppState>().currentDirectory;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 600,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.archive,
                    size: 18,
                    color: DuckColors.accentPurple,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    S.backupTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      ws ?? S.backupNoWorkspaceLabel,
                      style: const TextStyle(
                        fontSize: 12,
                        color: DuckColors.fgMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: ws == null || _busy ? null : _runBackup,
                    icon: const Icon(Icons.archive, size: 14),
                    label: const Text(S.backupCreate),
                  ),
                ],
              ),
              if (_busy)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const LinearProgressIndicator(),
                      const SizedBox(height: 4),
                      Text(
                        _currentFile == null
                            ? S.backupRunning
                            : '${S.backupRunning} $_currentFile',
                        style: const TextStyle(
                          fontSize: 11,
                          color: DuckColors.fgSubtle,
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 12),
              const AutoBackupSection(),
              const SizedBox(height: 16),
              const Text(S.backupExistingHeader, style: DuckTheme.titleS),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 320),
                child: _records.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 16),
                        child: Center(
                          child: Text(
                            S.backupNone,
                            style: TextStyle(color: DuckColors.fgSubtle),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: _records.length,
                        separatorBuilder: (_, i) => const Divider(
                          height: 1,
                          color: DuckColors.glassSeam,
                        ),
                        itemBuilder: (context, i) {
                          final r = _records[i];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: const Icon(
                              Icons.folder_zip,
                              size: 16,
                              color: DuckColors.fgMuted,
                            ),
                            title: Text(
                              r.archivePath.split(RegExp(r'[\\/]')).last,
                              style: const TextStyle(fontSize: 12),
                            ),
                            subtitle: Text(
                              '${r.createdAt} • ${_formatBytes(r.sizeBytes)}',
                              style: const TextStyle(
                                fontSize: 11,
                                color: DuckColors.fgSubtle,
                              ),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: S.backupOpenInOs,
                                  icon: const Icon(Icons.open_in_new, size: 14),
                                  onPressed: () =>
                                      _svc.revealInOs(r.archivePath),
                                ),
                                IconButton(
                                  tooltip: S.delete,
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 14,
                                    color: DuckColors.stateError,
                                  ),
                                  onPressed: () async {
                                    await _svc.deleteBackup(r.archivePath);
                                    _refresh();
                                  },
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
