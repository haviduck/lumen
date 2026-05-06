import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// One file the dialog will upload. The pair `(localPath,
/// remoteRelativePath)` is enough to reconstruct the remote layout:
/// the dialog joins `<destDir>/<remoteRelativePath>` for the final
/// SFTP destination, and `mkdir -p` walks the relative path's
/// parent components on the remote.
///
/// For top-level file drops, `remoteRelativePath` is just the file's
/// basename. For folder drops, it preserves the relative path under
/// the dropped folder — `~/Desktop/mydir/sub/foo.txt` dropped
/// alongside the `mydir` root produces `mydir/sub/foo.txt`.
class SshUploadItem {
  final String localPath;
  final String remoteRelativePath;
  final int sizeBytes;

  const SshUploadItem({
    required this.localPath,
    required this.remoteRelativePath,
    required this.sizeBytes,
  });

  /// Top-level basename of the path the user actually dropped — used
  /// in the dialog's grouped display so a folder full of files reads
  /// as "📁 mydir  ·  47 files".
  String get topLevelLabel {
    final parts =
        remoteRelativePath.split('/').where((s) => s.isNotEmpty).toList();
    return parts.isEmpty ? p.basename(localPath) : parts.first;
  }
}

/// Result of expanding a list of dropped paths (files + directories)
/// into a flat list of files. Directories are walked recursively;
/// symlinks are skipped (no loop chasing in v1). Returned to the
/// upload dialog for display + upload.
class SshUploadPlan {
  /// Files to upload, ordered roughly as the user dropped them
  /// (top-level files first, then directory contents in walk order).
  final List<SshUploadItem> items;

  /// Number of symlinks skipped during the walk. Surfaced in the
  /// dialog so users know why the count looks lower than expected.
  final int skippedSymlinks;

  /// Number of unreadable entries encountered. Permission errors,
  /// vanished files mid-walk, etc.
  final int skippedUnreadable;

  /// Sum of [items]' sizes — handy for the dialog header.
  int get totalBytes => items.fold(0, (a, b) => a + b.sizeBytes);

  /// Distinct top-level labels, in insertion order. Drives the
  /// grouped display ("you dropped these 3 things").
  List<String> get groupLabels {
    final seen = <String>{};
    final out = <String>[];
    for (final i in items) {
      final l = i.topLevelLabel;
      if (seen.add(l)) out.add(l);
    }
    return out;
  }

  const SshUploadPlan({
    required this.items,
    this.skippedSymlinks = 0,
    this.skippedUnreadable = 0,
  });

  /// Walk a list of OS-level paths and produce a flat upload plan.
  /// File paths become single items; directory paths produce one
  /// item per file in the recursive walk. Symlinks are skipped at
  /// every level.
  static Future<SshUploadPlan> fromPaths(List<String> paths) async {
    final items = <SshUploadItem>[];
    var skippedSymlinks = 0;
    var skippedUnreadable = 0;

    for (final raw in paths) {
      try {
        final entityType = await FileSystemEntity.type(raw);
        if (entityType == FileSystemEntityType.notFound) {
          skippedUnreadable++;
          continue;
        }
        if (entityType == FileSystemEntityType.link) {
          skippedSymlinks++;
          continue;
        }
        if (entityType == FileSystemEntityType.file) {
          final stat = await File(raw).stat();
          items.add(
            SshUploadItem(
              localPath: raw,
              remoteRelativePath: p.basename(raw),
              sizeBytes: stat.size,
            ),
          );
          continue;
        }
        if (entityType == FileSystemEntityType.directory) {
          final dir = Directory(raw);
          final rootName = p.basename(raw);
          // `followLinks: false` so we don't chase symlink loops.
          // `recursive: true` walks the subtree breadth-first by
          // dart:io's contract.
          final stream = dir.list(recursive: true, followLinks: false);
          await for (final entity in stream) {
            try {
              if (entity is File) {
                final stat = await entity.stat();
                final rel = p.relative(entity.path, from: raw);
                // Normalise to forward slashes — the path goes onto
                // a remote POSIX filesystem regardless of which OS
                // we're walking on. `p.posix.joinAll(p.split(...))`
                // covers Windows-host-walking-with-backslashes case.
                final relPosix = p.posix.joinAll(p.split(rel));
                items.add(
                  SshUploadItem(
                    localPath: entity.path,
                    remoteRelativePath: '$rootName/$relPosix',
                    sizeBytes: stat.size,
                  ),
                );
              } else if (entity is Link) {
                skippedSymlinks++;
              }
              // Directory entities don't need explicit handling —
              // we mkdir-on-demand from the file paths during upload.
            } catch (_) {
              skippedUnreadable++;
            }
          }
        }
      } catch (_) {
        skippedUnreadable++;
      }
    }

    return SshUploadPlan(
      items: items,
      skippedSymlinks: skippedSymlinks,
      skippedUnreadable: skippedUnreadable,
    );
  }
}

/// Confirmation dialog for SFTP-uploading files (and recursively-walked
/// directories) into a connected SSH host. Defaults the destination
/// to the host's `lastUploadDir`, the caller-supplied
/// [preferredDestination] (typically the live shell's OSC-7 cwd), or
/// a `$HOME` probe.
///
/// Triggered from:
///   - `RemotePane._handleDroppedFiles` (drag-drop, OS or in-app).
///   - File explorer right-click → "Upload to host..." (future).
///
/// Returns true on a successful upload (any file uploaded), false on
/// cancel / total failure. The caller doesn't usually inspect the
/// return value — feedback rides via toast inside the dialog.
Future<bool> showSshUploadDialog(
  BuildContext context, {
  required SshController ssh,
  required SshHost host,
  required SshUploadPlan plan,
  String? preferredDestination,
}) async {
  if (plan.items.isEmpty) {
    showDuckToast(context, S.sshUploadFailed);
    return false;
  }
  final result = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SshUploadDialog(
      ssh: ssh,
      host: host,
      plan: plan,
      preferredDestination: preferredDestination,
    ),
  );
  return result == true;
}

class _SshUploadDialog extends StatefulWidget {
  final SshController ssh;
  final SshHost host;
  final SshUploadPlan plan;
  final String? preferredDestination;
  const _SshUploadDialog({
    required this.ssh,
    required this.host,
    required this.plan,
    this.preferredDestination,
  });

  @override
  State<_SshUploadDialog> createState() => _SshUploadDialogState();
}

class _SshUploadDialogState extends State<_SshUploadDialog> {
  late TextEditingController _destCtrl;
  bool _overwrite = false;
  bool _uploading = false;

  /// Per-file progress for the in-flight item.
  String? _currentName;
  int _currentSent = 0;
  int _currentTotal = 0;

  /// Aggregate progress across the whole plan.
  int _completedFiles = 0;
  int _totalFiles = 0;

  String? _error;
  int _skipped = 0; // remote-already-exists + overwrite=false

  /// Cache of remote directories we've already ensured during this
  /// upload session. Avoids a redundant `mkdir` round-trip for every
  /// file in the same subtree (a folder of 1000 files would otherwise
  /// emit 1000 mkdirs for the same parent).
  final Set<String> _ensuredDirs = {};

  @override
  void initState() {
    super.initState();
    _totalFiles = widget.plan.items.length;
    final defaultDir = widget.preferredDestination ??
        widget.host.lastUploadDir ??
        _guessHomeDir();
    _destCtrl = TextEditingController(text: defaultDir);
    _resolveBetterDefault();
  }

  /// Best-effort probe of the remote $HOME via `client.run("echo \$HOME")`.
  /// Skipped when a higher-priority default is already in play.
  Future<void> _resolveBetterDefault() async {
    if (widget.preferredDestination != null ||
        widget.host.lastUploadDir != null) {
      return;
    }
    try {
      final session = widget.ssh.findSessionForHost(widget.host.id);
      final conn = session?.connection;
      if (conn == null) return;
      final out = await conn.client
          .run(r'echo $HOME')
          .timeout(const Duration(seconds: 4));
      final home = String.fromCharCodes(out).trim();
      if (mounted && home.isNotEmpty && home.startsWith('/')) {
        final withSlash = home.endsWith('/') ? home : '$home/';
        if (_destCtrl.text == _guessHomeDir()) {
          _destCtrl.text = withSlash;
        }
      }
    } catch (_) {}
  }

  String _guessHomeDir() => '/home/${widget.host.user}/';

  @override
  void dispose() {
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _doUpload() async {
    final dest = _destCtrl.text.trim();
    if (dest.isEmpty) return;
    setState(() {
      _uploading = true;
      _error = null;
      _completedFiles = 0;
      _skipped = 0;
      _ensuredDirs.clear();
    });

    final session = widget.ssh.findSessionForHost(widget.host.id);
    final conn = session?.connection;
    if (conn == null || conn.isClosed) {
      setState(() {
        _uploading = false;
        _error = S.sshDisconnected;
      });
      return;
    }

    try {
      final sftp = await conn.sftp();
      // Validate the destination root. We DO NOT auto-mkdir the root
      // — that's the user's typed input and silently creating dirs
      // there would be hostile. Subdirectories implied by the plan
      // (e.g. `mydir/`, `mydir/sub/`) get mkdir-on-demand because
      // those are an explicit consequence of "the user dragged a
      // folder, they want the folder structure preserved".
      try {
        final stat = await sftp.stat(dest);
        if (!stat.isDirectory) {
          throw FileSystemException('Destination is not a directory', dest);
        }
      } catch (_) {
        setState(() {
          _uploading = false;
          _error = '$dest does not exist';
        });
        return;
      }
      final destNoTrail = dest.endsWith('/') && dest.length > 1
          ? dest.substring(0, dest.length - 1)
          : dest;
      _ensuredDirs.add(destNoTrail);

      for (final item in widget.plan.items) {
        if (!mounted) return;
        final remotePath = '$destNoTrail/${item.remoteRelativePath}';
        // Ensure every parent directory exists. We walk leftwards
        // from the file's parent up to (but not past) `destNoTrail`,
        // creating any missing component. Idempotent: `_ensuredDirs`
        // short-circuits the second + visit to the same dir.
        await _ensureRemoteParent(sftp, remotePath, destNoTrail);

        if (!_overwrite) {
          try {
            await sftp.stat(remotePath);
            // Exists → skip.
            _skipped++;
            _completedFiles++;
            if (mounted) setState(() {});
            continue;
          } catch (_) {
            // Doesn't exist — proceed.
          }
        }

        final localFile = File(item.localPath);
        setState(() {
          _currentName = item.remoteRelativePath;
          _currentSent = 0;
          _currentTotal = item.sizeBytes;
        });

        final remote = await sftp.open(
          remotePath,
          mode: SftpFileOpenMode.write |
              SftpFileOpenMode.create |
              SftpFileOpenMode.truncate,
        );
        try {
          final reader = localFile.openRead();
          var offset = 0;
          await for (final chunk in reader) {
            final bytes = Uint8List.fromList(chunk);
            await remote.writeBytes(bytes, offset: offset);
            offset += bytes.length;
            if (mounted) {
              setState(() => _currentSent = offset);
            }
          }
        } finally {
          await remote.close();
        }
        _completedFiles++;
      }

      // Persist the destination so next time it auto-fills.
      await widget.ssh.vault.rememberUploadDir(widget.host.id, destNoTrail);

      if (mounted) {
        showDuckToast(
          context,
          _skipped == 0
              ? S.sshUploadDone
              : S.sshUploadDoneWithSkipsFmt(
                  _completedFiles - _skipped,
                  _skipped,
                ),
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _error = e.toString();
        });
      }
    }
  }

  /// Ensure `dirname(remotePath)` exists on the remote, creating any
  /// missing components via `sftp.mkdir`. [stopAt] is the destination
  /// root we already validated — we never `mkdir` past it (and never
  /// `mkdir` it itself, since the user typed it in and we already
  /// confirmed it exists).
  ///
  /// Walks the path from leftmost-missing-component to right. The
  /// leftmost is found by repeatedly stripping the basename and
  /// stat'ing until we hit something that exists; everything between
  /// that pivot and `dirname(remotePath)` gets created.
  ///
  /// `_ensuredDirs` caches successful results so a folder of 10k
  /// files doesn't pay the stat round-trip for every single one.
  Future<void> _ensureRemoteParent(
    SftpClient sftp,
    String remotePath,
    String stopAt,
  ) async {
    final parent = _posixDirname(remotePath);
    if (parent.isEmpty || parent == stopAt) return;
    if (_ensuredDirs.contains(parent)) return;

    // Build the list of components from `stopAt` down to `parent`.
    if (!parent.startsWith(stopAt)) {
      // Caller bug — parent must be inside stopAt. Defensive bail.
      return;
    }
    final remainder = parent.substring(stopAt.length);
    final parts = remainder.split('/').where((s) => s.isNotEmpty).toList();
    var acc = stopAt;
    for (final part in parts) {
      acc = '$acc/$part';
      if (_ensuredDirs.contains(acc)) continue;
      try {
        final stat = await sftp.stat(acc);
        if (!stat.isDirectory) {
          throw FileSystemException(
            'Path exists and is not a directory',
            acc,
          );
        }
        _ensuredDirs.add(acc);
      } catch (_) {
        // Either doesn't exist, or stat threw for a transient reason.
        // Try mkdir; if THAT fails, escalate so the upload aborts
        // visibly rather than silently failing per-file.
        await sftp.mkdir(acc);
        _ensuredDirs.add(acc);
      }
    }
  }

  static String _posixDirname(String path) {
    final i = path.lastIndexOf('/');
    if (i < 0) return '';
    if (i == 0) return '/';
    return path.substring(0, i);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Text(S.sshUploadTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.host.displayName,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            _SummaryHeader(plan: widget.plan),
            const SizedBox(height: 8),
            // Grouped list — one row per top-level item the user
            // dropped, with the file count + size for any directories.
            // Caps at 6 rows; the rest scrolls.
            Container(
              constraints: const BoxConstraints(maxHeight: 140),
              decoration: BoxDecoration(
                color: DuckColors.bgChip,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(
                  color: DuckColors.glassSeam,
                  width: 0.5,
                ),
              ),
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 6,
              ),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final group in _groups()) _GroupRow(group: group),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            Text(
              S.sshUploadDestination,
              style: const TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgMuted,
              ),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: _destCtrl,
              autofocus: true,
              enabled: !_uploading,
              decoration: const InputDecoration(
                hintText: S.sshUploadDestinationHint,
                isDense: true,
              ),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Checkbox(
                  value: _overwrite,
                  onChanged: _uploading
                      ? null
                      : (v) => setState(() => _overwrite = v ?? false),
                ),
                const Text(
                  S.sshUploadOverwrite,
                  style: TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ],
            ),
            if (_uploading) ...[
              const SizedBox(height: 6),
              Text(
                S.sshUploadAggregateProgressFmt(_completedFiles, _totalFiles),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.fgPrimary,
                ),
              ),
              const SizedBox(height: 2),
              if (_currentName != null)
                Text(
                  S.sshUploadProgressFmt(
                    _currentName!,
                    _currentSent,
                    _currentTotal,
                  ),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              const SizedBox(height: 4),
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: _totalFiles == 0
                      ? null
                      : (_completedFiles / _totalFiles).clamp(0.0, 1.0),
                  minHeight: 3,
                  backgroundColor: DuckColors.bgChip,
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    DuckColors.accentCyan,
                  ),
                ),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.stateError,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _uploading
              ? null
              : () => Navigator.of(context).pop(false),
          child: const Text(S.cancel),
        ),
        ElevatedButton(
          onPressed: _uploading ? null : _doUpload,
          child: Text(_uploading ? S.sshUploadInFlight : S.sshUploadStart),
        ),
      ],
    );
  }

  List<_GroupSummary> _groups() {
    // Aggregate items by their top-level label (the thing the user
    // dropped). Each group surfaces a count + total bytes so the
    // user can sanity-check before clicking Upload.
    final byLabel = <String, _GroupSummary>{};
    for (final item in widget.plan.items) {
      final label = item.topLevelLabel;
      final sum = byLabel[label] ??=
          _GroupSummary(label: label, isFolder: false);
      sum.files++;
      sum.bytes += item.sizeBytes;
      // If we see more than one item under a single label, OR the
      // remoteRelativePath has nested segments, the label refers to
      // a folder rather than a single file.
      if (item.remoteRelativePath.contains('/') || sum.files > 1) {
        sum.isFolder = true;
      }
    }
    return byLabel.values.toList(growable: false);
  }
}

class _GroupSummary {
  final String label;
  bool isFolder;
  int files = 0;
  int bytes = 0;
  _GroupSummary({required this.label, required this.isFolder});
}

class _GroupRow extends StatelessWidget {
  final _GroupSummary group;
  const _GroupRow({required this.group});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Icon(
            group.isFolder ? Icons.folder : Icons.insert_drive_file_outlined,
            size: 12,
            color: group.isFolder
                ? DuckColors.folderIcon
                : DuckColors.fgMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              group.label,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: DuckColors.fgPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (group.isFolder) ...[
            const SizedBox(width: 8),
            Text(
              S.sshUploadGroupFolderFmt(
                group.files,
                _humanSize(group.bytes),
              ),
              style: const TextStyle(
                fontSize: 10.5,
                color: DuckColors.fgFaint,
              ),
            ),
          ] else ...[
            const SizedBox(width: 8),
            Text(
              _humanSize(group.bytes),
              style: const TextStyle(
                fontSize: 10.5,
                color: DuckColors.fgFaint,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }
}

class _SummaryHeader extends StatelessWidget {
  final SshUploadPlan plan;
  const _SummaryHeader({required this.plan});

  @override
  Widget build(BuildContext context) {
    final n = plan.items.length;
    final size = _humanSize(plan.totalBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          S.sshUploadHeaderFmt(n, size),
          style: const TextStyle(
            fontSize: 12,
            color: DuckColors.fgPrimary,
          ),
        ),
        if (plan.skippedSymlinks > 0 || plan.skippedUnreadable > 0)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              S.sshUploadSkippedFmt(
                plan.skippedSymlinks,
                plan.skippedUnreadable,
              ),
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.stateWarn,
              ),
            ),
          ),
      ],
    );
  }

  static String _humanSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }
}
