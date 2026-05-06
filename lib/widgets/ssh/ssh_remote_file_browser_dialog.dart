import 'dart:async';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_remote_file_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'ssh_download_dialog.dart';

/// Modal SFTP file browser. Replaces the v1 "type a path" dialog as
/// the primary entry point for opening remote files in the editor —
/// the typed-path flow is still available behind a "Type path" button
/// for power users who already know exactly where they're going.
///
/// Navigation:
///   - Single-click a directory row → enter that directory.
///   - Single-click a file row → close the dialog and route through
///     [AppState.openRemoteFile] (download → mirror → editor.openFile).
///   - Breadcrumb segments → jump to that ancestor directory.
///   - "Up" / "Home" buttons in the header.
///
/// Initial directory resolution:
///   1. The session's OSC-7-reported cwd, if known.
///   2. The host's `lastUploadDir`.
///   3. `$HOME` from a `client.run("echo \$HOME")` probe.
///   4. `/` as last-ditch.
Future<void> showSshRemoteFileBrowser(
  BuildContext context, {
  required SshController ssh,
  required String hostId,
}) async {
  final session = ssh.findSessionForHost(hostId);
  if (session == null) {
    showDuckToast(context, S.sshDisconnected);
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) => _SshRemoteFileBrowserDialog(
      ssh: ssh,
      session: session,
    ),
  );
}

class _SshRemoteFileBrowserDialog extends StatefulWidget {
  final SshController ssh;
  final SshSessionEntry session;
  const _SshRemoteFileBrowserDialog({
    required this.ssh,
    required this.session,
  });

  @override
  State<_SshRemoteFileBrowserDialog> createState() =>
      _SshRemoteFileBrowserDialogState();
}

class _SshRemoteFileBrowserDialogState
    extends State<_SshRemoteFileBrowserDialog> {
  /// Currently displayed directory path. Always absolute, normalised
  /// to use forward slashes (POSIX) — Windows-OpenSSH hosts also
  /// accept forward slashes in SFTP paths so this is portable.
  String _currentPath = '/';
  bool _loading = true;
  String? _error;
  List<SftpName> _entries = const [];

  /// Hide dotfiles by default — most users browsing a remote home
  /// don't want `.cache` and `.gitconfig` flooding their screen.
  /// Toggleable in the header.
  bool _showHidden = false;

  /// Cached `$HOME` for the Home button. Resolved once on first entry
  /// to the dialog. Null until the probe completes.
  String? _homeDir;

  @override
  void initState() {
    super.initState();
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    final initial = widget.session.lastKnownCwd ??
        widget.session.host.lastUploadDir;
    if (initial != null && initial.isNotEmpty) {
      _currentPath = _normalise(initial);
    }
    // Background-resolve $HOME so the Home button works without a
    // cold-start round-trip when the user clicks it. Doesn't block
    // the initial listing.
    unawaited(_resolveHome());
    await _refresh();
  }

  Future<void> _resolveHome() async {
    try {
      final out = await widget.session.connection!.client
          .run(r'echo $HOME')
          .timeout(const Duration(seconds: 4));
      final home = String.fromCharCodes(out).trim();
      if (mounted && home.startsWith('/')) {
        setState(() => _homeDir = home);
        // If we landed on `/` only because we had no signal at all,
        // jump to home as a friendlier starting point.
        if (_currentPath == '/' && _entries.isEmpty) {
          await _navigate(home);
        }
      }
    } catch (_) {}
  }

  Future<void> _refresh() async {
    final conn = widget.session.connection;
    if (conn == null || conn.isClosed) {
      setState(() {
        _loading = false;
        _error = S.sshDisconnected;
        _entries = const [];
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sftp = await conn.sftp();
      final entries = await sftp.listdir(_currentPath);
      // Drop the synthetic `.` / `..` rows that SFTP servers include
      // (the breadcrumb + Up button cover those affordances; showing
      // them as rows is just clutter).
      final filtered = entries
          .where((e) => e.filename != '.' && e.filename != '..')
          .toList(growable: false);
      filtered.sort(_compare);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _entries = filtered;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
        _entries = const [];
      });
    }
  }

  static int _compare(SftpName a, SftpName b) {
    final aDir = a.attr.isDirectory ? 0 : 1;
    final bDir = b.attr.isDirectory ? 0 : 1;
    if (aDir != bDir) return aDir - bDir;
    return a.filename.toLowerCase().compareTo(b.filename.toLowerCase());
  }

  Future<void> _navigate(String path) async {
    final next = _normalise(path);
    if (next == _currentPath) return;
    setState(() => _currentPath = next);
    await _refresh();
  }

  Future<void> _onRowTap(SftpName entry) async {
    if (entry.attr.isDirectory) {
      await _navigate(_join(_currentPath, entry.filename));
      return;
    }
    // Symlinks: dartssh2 doesn't auto-follow on `listdir`. We attempt
    // to stat the resolved target; if it's a directory, treat as a
    // directory; otherwise treat as a file and open. Best-effort —
    // a stat failure (broken symlink) just falls through to "open".
    if (entry.attr.type == SftpFileType.symbolicLink) {
      final resolvedPath = _join(_currentPath, entry.filename);
      try {
        final sftp = await widget.session.connection!.sftp();
        final attrs = await sftp.stat(resolvedPath);
        if (attrs.isDirectory) {
          await _navigate(resolvedPath);
          return;
        }
      } catch (_) {}
    }
    await _openFile(_join(_currentPath, entry.filename));
  }

  Future<void> _openFile(String absolutePath) async {
    final appState = context.read<AppState>();
    Navigator.of(context).pop();
    try {
      await appState.openRemoteFile(
        hostId: widget.session.host.id,
        remotePath: absolutePath,
      );
    } catch (e) {
      if (!mounted) return;
      showDuckToast(
        context,
        isRemoteFileTooLarge(e)
            ? S.sshRemoteFileTooLarge
            : '${S.error}: $e',
      );
    }
  }

  Future<void> _goUp() async {
    if (_currentPath == '/' || _currentPath.isEmpty) return;
    final idx = _currentPath.lastIndexOf('/');
    final parent = idx <= 0 ? '/' : _currentPath.substring(0, idx);
    await _navigate(parent);
  }

  /// Normalise to a single absolute POSIX path: collapse `//`,
  /// strip trailing slash (except for the root). Fed by user input
  /// (Type-path flow) and ancestor navigation.
  static String _normalise(String path) {
    if (path.isEmpty) return '/';
    var p = path.replaceAll(RegExp(r'/+'), '/');
    if (p.length > 1 && p.endsWith('/')) {
      p = p.substring(0, p.length - 1);
    }
    if (!p.startsWith('/')) p = '/$p';
    return p;
  }

  static String _join(String dir, String name) {
    if (dir.endsWith('/')) return '$dir$name';
    return '$dir/$name';
  }

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
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 560),
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
            _buildBreadcrumb(),
            const Divider(
              color: DuckColors.glassSeam,
              height: 1,
              thickness: 0.5,
            ),
            Expanded(child: _buildBody()),
            const Divider(
              color: DuckColors.glassSeam,
              height: 1,
              thickness: 0.5,
            ),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
      child: Row(
        children: [
          const Icon(
            Icons.folder_open,
            size: 14,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              S.sshRemoteBrowserTitleFmt(widget.session.host.displayName),
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: _showHidden
                ? S.sshRemoteBrowserHideHidden
                : S.sshRemoteBrowserShowHidden,
            icon: Icon(
              _showHidden ? Icons.visibility : Icons.visibility_off,
              size: 16,
            ),
            onPressed: () => setState(() => _showHidden = !_showHidden),
          ),
          IconButton(
            tooltip: S.sshRemoteBrowserRefresh,
            icon: const Icon(Icons.refresh, size: 16),
            onPressed: _loading ? null : _refresh,
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    final segments = <_BreadcrumbSeg>[
      _BreadcrumbSeg(label: '/', path: '/'),
    ];
    if (_currentPath != '/') {
      final parts = _currentPath.split('/').where((s) => s.isNotEmpty).toList();
      var acc = '';
      for (final part in parts) {
        acc = '$acc/$part';
        segments.add(_BreadcrumbSeg(label: part, path: acc));
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          IconButton(
            tooltip: S.sshRemoteBrowserUp,
            icon: const Icon(Icons.arrow_upward, size: 14),
            onPressed: _currentPath == '/' ? null : _goUp,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            tooltip: S.sshRemoteBrowserHome,
            icon: const Icon(Icons.home_outlined, size: 14),
            onPressed: _homeDir == null
                ? null
                : () async => _navigate(_homeDir!),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                children: [
                  for (var i = 0; i < segments.length; i++) ...[
                    _BreadcrumbButton(
                      label: segments[i].label,
                      onTap: () => _navigate(segments[i].path),
                      isLast: i == segments.length - 1,
                    ),
                    if (i < segments.length - 1)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(
                          Icons.chevron_right,
                          size: 12,
                          color: DuckColors.fgFaint,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.4),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            _error!,
            style: const TextStyle(
              fontSize: 12,
              color: DuckColors.stateError,
            ),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final visible = _showHidden
        ? _entries
        : _entries.where((e) => !e.filename.startsWith('.')).toList();
    if (visible.isEmpty) {
      return const Center(
        child: Text(
          S.sshRemoteBrowserEmpty,
          style: TextStyle(fontSize: 12, color: DuckColors.fgFaint),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: visible.length,
      itemBuilder: (ctx, i) => _RemoteRow(
        entry: visible[i],
        onTap: () => _onRowTap(visible[i]),
        onDownload: () => _downloadEntry(visible[i]),
        onOpenInEditor: visible[i].attr.isDirectory
            ? null
            : () => _openFile(_join(_currentPath, visible[i].filename)),
      ),
    );
  }

  /// Right-click → "Download" handler. Stacks the download dialog
  /// over the browser dialog so the user lands back in the same
  /// directory if they cancel. We only try to follow symlinks
  /// shallowly (one stat) to determine file-vs-directory; broken
  /// symlinks just download as a 0-byte file with the same name,
  /// which is the SFTP server's view anyway.
  Future<void> _downloadEntry(SftpName entry) async {
    final remotePath = _join(_currentPath, entry.filename);
    var isDir = entry.attr.isDirectory;
    if (entry.attr.type == SftpFileType.symbolicLink) {
      try {
        final sftp = await widget.session.connection!.sftp();
        final attrs = await sftp.stat(remotePath);
        isDir = attrs.isDirectory;
      } catch (_) {}
    }
    if (!mounted) return;
    await showSshDownloadDialog(
      context,
      ssh: widget.ssh,
      session: widget.session,
      remotePath: remotePath,
      isDirectory: isDir,
    );
  }

  Widget _buildFooter() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
      child: Row(
        children: [
          TextButton.icon(
            icon: const Icon(Icons.edit_outlined, size: 13),
            label: const Text(S.sshRemoteBrowserTypePath),
            onPressed: _promptTypePath,
          ),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(S.cancel),
          ),
        ],
      ),
    );
  }

  Future<void> _promptTypePath() async {
    final ctrl = TextEditingController(text: _currentPath);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(
          S.sshRemoteBrowserTypePath,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: TextField(
            controller: ctrl,
            autofocus: true,
            decoration: const InputDecoration(
              hintText: '/var/log',
              isDense: true,
            ),
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text(S.go),
          ),
        ],
      ),
    );
    if (next == null || next.isEmpty) return;
    if (!mounted) return;
    // Best-effort: try as directory first, fall back to opening as
    // file if the user pasted in a file path.
    final conn = widget.session.connection!;
    try {
      final sftp = await conn.sftp();
      final attrs = await sftp.stat(_normalise(next));
      if (attrs.isDirectory) {
        await _navigate(next);
      } else {
        await _openFile(_normalise(next));
      }
    } catch (e) {
      if (!mounted) return;
      showDuckToast(context, '${S.error}: $e');
    }
  }
}

class _BreadcrumbSeg {
  final String label;
  final String path;
  const _BreadcrumbSeg({required this.label, required this.path});
}

class _BreadcrumbButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool isLast;
  const _BreadcrumbButton({
    required this.label,
    required this.onTap,
    required this.isLast,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontFamily: 'monospace',
            color: isLast ? DuckColors.fgPrimary : DuckColors.fgMuted,
            fontWeight: isLast ? FontWeight.w600 : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

enum _RowAction { open, download }

class _RemoteRow extends StatefulWidget {
  final SftpName entry;
  final VoidCallback onTap;
  final VoidCallback onDownload;
  // Null when the entry is a directory — directories don't have an
  // "Open in editor" action, only "Open" (== navigate, == [onTap])
  // and "Download". Files get the explicit editor entry on top of
  // the implicit click-to-open primary action so the right-click
  // menu reads symmetrically with the directory case.
  final VoidCallback? onOpenInEditor;
  const _RemoteRow({
    required this.entry,
    required this.onTap,
    required this.onDownload,
    this.onOpenInEditor,
  });

  @override
  State<_RemoteRow> createState() => _RemoteRowState();
}

class _RemoteRowState extends State<_RemoteRow> {
  bool _hover = false;

  /// Show the right-click context menu anchored at the tap
  /// position. Uses Material's `showMenu` directly with a manual
  /// `RelativeRect` so the menu opens exactly where the cursor was
  /// — `PopupMenuButton` would have anchored to the row's left
  /// edge instead, which feels off for a list of equal-weight rows.
  Future<void> _showContextMenu(Offset globalPosition) async {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;
    final isDir = widget.entry.attr.isDirectory;
    final selected = await showMenu<_RowAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromPoints(globalPosition, globalPosition),
        Offset.zero & overlay.size,
      ),
      color: DuckColors.bgRaised,
      items: [
        PopupMenuItem<_RowAction>(
          value: _RowAction.open,
          child: Row(
            children: [
              Icon(
                isDir ? Icons.folder_open : Icons.edit_outlined,
                size: 13,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: 8),
              Text(
                isDir
                    ? S.sshContextMenuOpen
                    : S.sshContextMenuOpenInEditor,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
        PopupMenuItem<_RowAction>(
          value: _RowAction.download,
          child: Row(
            children: [
              const Icon(
                Icons.download_outlined,
                size: 13,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: 8),
              Text(
                isDir
                    ? S.sshContextMenuDownloadFolder
                    : S.sshContextMenuDownload,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case _RowAction.open:
        if (isDir) {
          widget.onTap();
        } else {
          (widget.onOpenInEditor ?? widget.onTap)();
        }
      case _RowAction.download:
        widget.onDownload();
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    final isDir = entry.attr.isDirectory;
    final size = entry.attr.size;
    final mtime = entry.attr.modifyTime;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        // `onSecondaryTapDown` fires on the press, before the user
        // releases — this is how Finder / Windows Explorer feel
        // (menu under the cursor the moment they right-click).
        onSecondaryTapDown: (details) =>
            _showContextMenu(details.globalPosition),
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          color: _hover
              ? DuckColors.bgRaisedHi.withValues(alpha: 0.5)
              : Colors.transparent,
          child: Row(
            children: [
              Icon(
                isDir ? Icons.folder : _iconFor(entry),
                size: 14,
                color: isDir ? DuckColors.folderIcon : DuckColors.fgMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  entry.filename,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: isDir ? DuckColors.fgPrimary : DuckColors.fgMuted,
                    fontWeight:
                        isDir ? FontWeight.w600 : FontWeight.w400,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!isDir && size != null) ...[
                const SizedBox(width: 8),
                Text(
                  _formatSize(size),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'monospace',
                    color: DuckColors.fgFaint,
                  ),
                ),
              ],
              if (mtime != null) ...[
                const SizedBox(width: 12),
                Text(
                  _formatMtime(mtime),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgFaint,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static IconData _iconFor(SftpName entry) {
    final t = entry.attr.type;
    if (t == SftpFileType.symbolicLink) return Icons.link;
    if (t == SftpFileType.pipe) return Icons.cable_outlined;
    return Icons.insert_drive_file_outlined;
  }

  /// 1024-based humanise; matches `du -h` style enough for a casual
  /// "is this 4 KB or 4 MB?" glance.
  static String _formatSize(int bytes) {
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(v < 10 && i > 0 ? 1 : 0)} ${units[i]}';
  }

  /// SFTP modify-time is epoch SECONDS (per protocol). Renders as
  /// "yyyy-MM-dd HH:mm" — locale-agnostic, fits in 16 chars.
  static String _formatMtime(int epochSeconds) {
    final dt = DateTime.fromMillisecondsSinceEpoch(epochSeconds * 1000);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }
}
