import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/ssh_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Modal that confirms a remote → local download triggered from
/// the SFTP file browser's right-click menu.
///
/// Two flows behind one dialog:
///   - File: SFTP-stream a single remote file into a local file.
///   - Folder: walk the remote tree (recursing into subdirs),
///     mirror the structure locally, and pull each file in turn.
///
/// Default destination is `<workspaceRoot>/ssh_sync/<basename>`. The
/// `ssh_sync/` prefix is intentional (per user request) — it
/// prevents the very common foot-gun of pulling a remote file
/// straight into the project root and shadowing a real source file
/// of the same name. The user can always override the path; the
/// `Browse…` button picks a parent directory and re-appends the
/// basename, the text field is fully editable for renaming.
///
/// Conflict handling is at the destination ROOT only (not per file
/// inside a recursive folder pull):
///   - File destination already exists → Replace / Keep both / Cancel.
///   - Folder destination already exists → Replace (rm -rf) /
///     Keep both / Cancel.
/// "Keep both" appends ` (1)`, ` (2)`, … before the extension (file)
/// or as a suffix (folder), Finder-style.
///
/// Why no per-file conflict prompt during recursive folder pulls?
/// Because the destination root is fresh after the user resolves
/// the root-level conflict, so per-file collisions can't happen.
Future<void> showSshDownloadDialog(
  BuildContext context, {
  required SshController ssh,
  required SshSessionEntry session,
  required String remotePath,
  required bool isDirectory,
}) async {
  final appState = context.read<AppState>();
  final workspaceRoot = appState.currentDirectory;
  if (workspaceRoot == null || workspaceRoot.isEmpty) {
    showDuckToast(context, S.sshDownloadNoWorkspace);
    return;
  }
  final basename = _safeBasename(remotePath);
  final defaultDestination = p.join(workspaceRoot, 'ssh_sync', basename);

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SshDownloadDialog(
      ssh: ssh,
      session: session,
      remotePath: remotePath,
      isDirectory: isDirectory,
      defaultDestination: defaultDestination,
      workspaceRoot: workspaceRoot,
    ),
  );
}

/// Strip a remote POSIX path down to its last segment. Defends
/// against trailing slashes and the special "/" case (which would
/// otherwise produce an empty basename and break the destination
/// path join).
String _safeBasename(String remotePath) {
  var path = remotePath;
  while (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final idx = path.lastIndexOf('/');
  final name = idx < 0 ? path : path.substring(idx + 1);
  return name.isEmpty ? 'download' : name;
}

class _SshDownloadDialog extends StatefulWidget {
  final SshController ssh;
  final SshSessionEntry session;
  final String remotePath;
  final bool isDirectory;
  final String defaultDestination;
  final String workspaceRoot;

  const _SshDownloadDialog({
    required this.ssh,
    required this.session,
    required this.remotePath,
    required this.isDirectory,
    required this.defaultDestination,
    required this.workspaceRoot,
  });

  @override
  State<_SshDownloadDialog> createState() => _SshDownloadDialogState();
}

class _SshDownloadDialogState extends State<_SshDownloadDialog> {
  late final TextEditingController _destCtrl;
  bool _busy = false;
  String? _error;

  // Progress state for folder downloads. Files are counted as we
  // walk the remote tree; the live `_completed` ticks up as each
  // SFTP read finishes. For single-file downloads `_total` is 1.
  int _completed = 0;
  int _total = 0;
  String? _currentRelPath;

  @override
  void initState() {
    super.initState();
    _destCtrl = TextEditingController(text: widget.defaultDestination);
  }

  @override
  void dispose() {
    _destCtrl.dispose();
    super.dispose();
  }

  Future<void> _browseDestination() async {
    // Pick a parent directory and re-append the current basename.
    // Behaviour matches the Save-As convention everywhere: the
    // file/folder name comes from the entry being downloaded, the
    // browse picker only chooses where it lands.
    final initialDir = p.dirname(_destCtrl.text);
    final picked = await FilePicker.getDirectoryPath(
      initialDirectory: initialDir.isEmpty ? widget.workspaceRoot : initialDir,
      dialogTitle: S.sshDownloadDestinationLabel,
    );
    if (picked == null || !mounted) return;
    final basename = p.basename(_destCtrl.text);
    setState(() => _destCtrl.text = p.join(picked, basename));
  }

  Future<void> _confirm() async {
    final dest = _destCtrl.text.trim();
    if (dest.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final conn = widget.session.connection;
      if (conn == null || conn.isClosed) {
        throw StateError(S.sshDisconnected);
      }
      final sftp = await conn.sftp();

      // Resolve any root-level conflict BEFORE we start touching
      // the filesystem. After this call returns, the destination
      // path is guaranteed not-exist OR caller asked us to replace.
      final resolvedDest = await _resolveRootConflict(dest);
      if (resolvedDest == null) {
        // Cancelled.
        if (!mounted) return;
        Navigator.of(context).pop();
        return;
      }

      if (widget.isDirectory) {
        await _downloadFolder(sftp, widget.remotePath, resolvedDest);
      } else {
        await _downloadFile(sftp, widget.remotePath, resolvedDest);
      }

      if (!mounted) return;
      // Refresh the file explorer so the new entry shows up
      // immediately — the user has no other reason to expect a
      // manual reload after a deliberate "download" action.
      // ignore: use_build_context_synchronously
      context.read<AppState>().refreshDirectory();
      Navigator.of(context).pop();
      // ignore: use_build_context_synchronously
      showDuckToast(context, S.sshDownloadCompleteFmt(p.basename(resolvedDest)));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = S.sshDownloadFailedFmt(e.toString());
      });
    }
  }

  /// Returns the final destination path if the user wants to proceed,
  /// or null if they cancelled at the conflict prompt. Handles the
  /// "Replace" branch by deleting the existing entry; handles
  /// "Keep both" by computing a sibling path with a numeric suffix.
  Future<String?> _resolveRootConflict(String desired) async {
    final exists = await _entryExists(desired);
    if (!exists) return desired;

    // Pre-compute the keep-both sibling path BEFORE we show the
    // dialog — `showDialog`'s builder is synchronous, so we can't
    // await inside it. Computing here also lets the user see the
    // exact filename they'd get if they pick "Keep both".
    final keepBothCandidate = await _siblingFor(desired, widget.isDirectory);

    if (!mounted) return null;
    final decision = await showDialog<_DownloadConflictDecision>(
      // ignore: use_build_context_synchronously
      context: context,
      builder: (ctx) => _ConflictDialog(
        existingPath: desired,
        isDirectory: widget.isDirectory,
        suggestedKeepBoth: keepBothCandidate,
      ),
    );
    if (decision == null || decision == _DownloadConflictDecision.cancel) {
      return null;
    }
    switch (decision) {
      case _DownloadConflictDecision.replace:
        if (widget.isDirectory) {
          await Directory(desired).delete(recursive: true);
        } else {
          await File(desired).delete();
        }
        return desired;
      case _DownloadConflictDecision.keepBoth:
        return keepBothCandidate;
      case _DownloadConflictDecision.cancel:
        return null;
    }
  }

  Future<bool> _entryExists(String path) async {
    if (await Directory(path).exists()) return true;
    if (await File(path).exists()) return true;
    return false;
  }

  /// Compute the next free sibling path. For files this slots a
  /// numeric counter before the extension (`.txt` → ` (1).txt`); for
  /// directories it appends ` (1)` to the bare name. Caps at 999 so
  /// a degenerate dir can't loop forever.
  Future<String> _siblingFor(String original, bool isDirectory) async {
    final dir = p.dirname(original);
    final ext = isDirectory ? '' : p.extension(original);
    final stem = isDirectory
        ? p.basename(original)
        : p.basenameWithoutExtension(original);
    for (var i = 1; i <= 999; i++) {
      final candidate = p.join(dir, '$stem ($i)$ext');
      if (!await _entryExists(candidate)) return candidate;
    }
    throw StateError('Too many sibling collisions for $original');
  }

  /// Stream-download a single SFTP file into a local file. Mirrors
  /// `AppState.grabRemoteFile` but without the 5 MB cap — that cap
  /// only existed to keep the editor responsive on
  /// `lumen-grab` / `openRemoteFile`. Right-click "Download" is an
  /// explicit user gesture; the user picks the destination and
  /// understands they're moving bytes, so we don't second-guess size.
  Future<void> _downloadFile(
    SftpClient sftp,
    String remotePath,
    String localPath,
  ) async {
    setState(() {
      _total = 1;
      _completed = 0;
      _currentRelPath = p.basename(remotePath);
    });
    final localFile = File(localPath);
    await localFile.parent.create(recursive: true);
    final sink = localFile.openWrite();
    try {
      await sftp.download(remotePath, sink, closeDestination: true);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }
    if (mounted) setState(() => _completed = 1);
  }

  /// Recursively download a remote directory into the local
  /// filesystem.
  ///
  /// Two-phase to keep the progress UI honest:
  ///   1. Walk the remote tree to count files (cheap — `listdir`
  ///      only). Captures `(remotePath, relativePath)` for each
  ///      file we'll later pull. Skips symlinks defensively to
  ///      avoid following something that points outside the tree
  ///      and accidentally pulling `/proc` or similar.
  ///   2. For each captured file, ensure its local parent exists
  ///      then `sftp.download` into it.
  ///
  /// Empty directories are mirrored as well — important for
  /// scaffolding-style folders the user expects to keep on download.
  Future<void> _downloadFolder(
    SftpClient sftp,
    String remoteRoot,
    String localRoot,
  ) async {
    setState(() {
      _total = 0;
      _completed = 0;
      _currentRelPath = '…';
    });

    final files = <_RemoteFile>[];
    final dirs = <String>[]; // relative dirs to mirror locally
    await _walkRemote(sftp, remoteRoot, '', files, dirs);

    if (!mounted) return;
    if (files.isEmpty && dirs.isEmpty) {
      throw StateError(S.sshDownloadFolderEmpty);
    }
    setState(() => _total = files.isEmpty ? 1 : files.length);

    // Create local directory skeleton up-front so that empty
    // remote dirs land on disk too, and so a later parent.create
    // is a fast no-op for the file writes.
    await Directory(localRoot).create(recursive: true);
    for (final rel in dirs) {
      await Directory(p.join(localRoot, rel)).create(recursive: true);
    }

    for (final file in files) {
      if (!mounted) return;
      setState(() => _currentRelPath = file.relativePath);
      final localPath = p.join(localRoot, file.relativePath);
      await Directory(p.dirname(localPath)).create(recursive: true);
      final sink = File(localPath).openWrite();
      try {
        await sftp.download(file.remotePath, sink, closeDestination: true);
      } catch (_) {
        try {
          await sink.close();
        } catch (_) {}
        rethrow;
      }
      if (mounted) setState(() => _completed += 1);
    }
  }

  Future<void> _walkRemote(
    SftpClient sftp,
    String absoluteRoot,
    String relativeBase,
    List<_RemoteFile> outFiles,
    List<String> outDirs,
  ) async {
    final dir = relativeBase.isEmpty
        ? absoluteRoot
        : '$absoluteRoot/${relativeBase.replaceAll(Platform.pathSeparator, '/')}';
    final entries = await sftp.listdir(dir);
    for (final e in entries) {
      if (e.filename == '.' || e.filename == '..') continue;
      final isDir = e.attr.isDirectory;
      final isLink = e.attr.type == SftpFileType.symbolicLink;
      // Defensive — symlinks can escape the tree; treating them as
      // skipped here mirrors how the upload planner handles them.
      // If a user really wants to pull a symlinked subtree they can
      // navigate into it and download the resolved target directly.
      if (isLink) continue;
      final childRel = relativeBase.isEmpty
          ? e.filename
          : p.join(relativeBase, e.filename);
      if (isDir) {
        outDirs.add(childRel);
        await _walkRemote(sftp, absoluteRoot, childRel, outFiles, outDirs);
      } else {
        final remotePath = '$absoluteRoot/${childRel.replaceAll(Platform.pathSeparator, '/')}';
        outFiles.add(_RemoteFile(remotePath: remotePath, relativePath: childRel));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final hostLabel = widget.session.host.displayName;
    final title = widget.isDirectory
        ? S.sshDownloadDialogTitleFolder
        : S.sshDownloadDialogTitleFile;
    return Dialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 80, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.fgPrimary,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.sshDownloadDialogSubtitleFmt(hostLabel, widget.remotePath),
                style: const TextStyle(
                  fontSize: 11.5,
                  fontFamily: 'monospace',
                  color: DuckColors.fgFaint,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                S.sshDownloadDestinationLabel,
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgMuted,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _destCtrl,
                      enabled: !_busy,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  TextButton.icon(
                    onPressed: _busy ? null : _browseDestination,
                    icon: const Icon(Icons.folder_open, size: 13),
                    label: const Text(S.sshDownloadBrowse),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              const Text(
                S.sshDownloadDestinationHint,
                style: TextStyle(fontSize: 10.5, color: DuckColors.fgFaint),
              ),
              if (_busy) ...[
                const SizedBox(height: 14),
                _ProgressStrip(
                  total: _total,
                  completed: _completed,
                  currentRelPath: _currentRelPath,
                  isFolder: widget.isDirectory,
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DuckColors.stateError.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  ),
                  child: Text(
                    _error!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      color: DuckColors.stateError,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: const Text(S.cancel),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _busy ? null : _confirm,
                    child: Text(
                      _busy ? S.sshDownloadInProgress : S.sshDownloadConfirm,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _RemoteFile {
  final String remotePath;
  final String relativePath;
  const _RemoteFile({required this.remotePath, required this.relativePath});
}

enum _DownloadConflictDecision { replace, keepBoth, cancel }

class _ConflictDialog extends StatelessWidget {
  final String existingPath;
  final bool isDirectory;
  final String suggestedKeepBoth;
  const _ConflictDialog({
    required this.existingPath,
    required this.isDirectory,
    required this.suggestedKeepBoth,
  });

  @override
  Widget build(BuildContext context) {
    final body = isDirectory
        ? S.sshDownloadConflictBodyFolder
        : S.sshDownloadConflictBodyFile;
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: const Text(
        S.sshDownloadConflictTitle,
        style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(body, style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            Text(
              existingPath,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: DuckColors.fgFaint,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.sshDownloadConflictKeepBothPreviewFmt(
                p.basename(suggestedKeepBoth),
              ),
              style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_DownloadConflictDecision.cancel),
          child: const Text(S.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(_DownloadConflictDecision.keepBoth),
          child: const Text(S.sshDownloadConflictKeepBoth),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.of(context).pop(_DownloadConflictDecision.replace),
          child: const Text(S.sshDownloadConflictReplace),
        ),
      ],
    );
  }
}

class _ProgressStrip extends StatelessWidget {
  final int total;
  final int completed;
  final String? currentRelPath;
  final bool isFolder;
  const _ProgressStrip({
    required this.total,
    required this.completed,
    required this.currentRelPath,
    required this.isFolder,
  });

  @override
  Widget build(BuildContext context) {
    // Indeterminate while we're still walking the remote tree
    // (`total == 0`); switches to a determinate bar once the walk
    // finishes and we know the file count.
    final fraction = total == 0 ? null : completed / total;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 4,
            backgroundColor: DuckColors.bgDeeper,
            color: DuckColors.accentCyan,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            if (isFolder)
              Text(
                S.sshDownloadProgressFilesFmt(completed, total),
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: DuckColors.fgMuted,
                ),
              )
            else
              const Text(
                S.sshDownloadInProgress,
                style: TextStyle(fontSize: 11, color: DuckColors.fgMuted),
              ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                currentRelPath ?? '',
                style: const TextStyle(
                  fontSize: 11,
                  fontFamily: 'monospace',
                  color: DuckColors.fgFaint,
                ),
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
