import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'ssh_client_service.dart';
import 'ssh_host.dart';

/// Provenance metadata for a file that was opened over SSH and is now
/// represented in the editor as a local mirror buffer. Stored in
/// memory by [SshRemoteFileService]; never persisted across restarts
/// — if the user reopens Lumen, mirror tabs do NOT auto-restore. This
/// matches the contract that remote sessions are session-scoped (the
/// connection is gone, the cached file is stale, opening it again
/// from the same path is a fresh download).
class RemoteFileOrigin {
  /// SSH host id this file came from. The cache directory uses this
  /// as a path component so renaming the host's label keeps the
  /// cache working.
  final String hostId;

  /// Display label cached at download time so the editor tab can show
  /// `host:path` even after the host was deleted from the vault.
  final String hostLabel;

  /// Absolute path on the remote.
  final String remotePath;

  /// When we downloaded the file. Used to age-out the cache.
  final DateTime downloadedAt;

  /// Remote size at download time. Used by the conflict-detect path:
  /// if `sftp.stat(remotePath)` shows a different size now, the
  /// remote has been modified since we last read.
  final int? downloadedSize;

  /// Remote mtime at download time (epoch seconds, nullable because
  /// some SFTP servers don't report it). Same conflict detect role
  /// as [downloadedSize].
  final int? downloadedMtime;

  const RemoteFileOrigin({
    required this.hostId,
    required this.hostLabel,
    required this.remotePath,
    required this.downloadedAt,
    required this.downloadedSize,
    required this.downloadedMtime,
  });

  /// User-facing tab suffix `host:path` so the editor's tab strip
  /// can clearly mark this buffer as remote.
  String get displaySuffix => '$hostLabel:$remotePath';

  RemoteFileOrigin copyWith({
    int? downloadedSize,
    int? downloadedMtime,
    DateTime? downloadedAt,
  }) {
    return RemoteFileOrigin(
      hostId: hostId,
      hostLabel: hostLabel,
      remotePath: remotePath,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      downloadedSize: downloadedSize ?? this.downloadedSize,
      downloadedMtime: downloadedMtime ?? this.downloadedMtime,
    );
  }
}

/// Result of a save attempt. `cancelled` means the user chose not to
/// overwrite remote on a conflict; `succeeded` means the upload
/// completed and the local snapshot was refreshed.
enum SshSaveOutcome { succeeded, cancelled, failed }

class SshSaveResult {
  final SshSaveOutcome outcome;
  final String? errorMessage;
  const SshSaveResult(this.outcome, {this.errorMessage});
}

/// Caller-provided callback that asks the user what to do when the
/// remote file has changed since they opened it. `currentSize` /
/// `currentMtime` are the live values; the snapshot lives on the
/// [RemoteFileOrigin] passed to the callback.
typedef SshConflictResolver = Future<bool> Function({
  required RemoteFileOrigin origin,
  required int? currentSize,
  required int? currentMtime,
});

/// User decision when a `lumen-grab` download lands on an existing
/// file in the project. [keepBoth] resolves the collision by saving
/// the new file with a `name (1).ext` / `name (2).ext` suffix (numeric
/// disambiguation, mirrors the macOS Finder convention).
enum SshGrabConflictDecision { replace, keepBoth, cancel }

/// Caller-provided callback that prompts the user when a grab is
/// about to clobber an existing file in the workspace. The resolver
/// is responsible for showing the UI; this layer only consumes the
/// returned decision. Default behaviour when no resolver is bound
/// is `cancel` (safer than silent overwrite).
typedef SshGrabConflictResolver = Future<SshGrabConflictDecision> Function({
  /// Absolute path on disk where the grabbed file would land if we
  /// chose [SshGrabConflictDecision.replace]. Pre-computed by the
  /// caller (basename of [remotePath] joined to the project root).
  required String existingLocalPath,
  /// The remote source path so the prompt can show "downloading
  /// /var/log/foo onto C:\proj\foo" — orientation for the user.
  required String remotePath,
  /// Human-friendly host label (e.g. "prod-web (web@10.0.1.5:22)")
  /// for the prompt header.
  required String hostLabel,
});

/// Maximum size we'll mirror into the editor. Above this, the open
/// path refuses with a friendly toast suggesting the terminal.
/// Same threshold for save (we trust the editor not to bloat the
/// buffer past the limit; if it ever did the upload would reject).
const int kSshRemoteFileMaxBytes = 5 * 1024 * 1024;

/// SFTP-mirrored remote file editing.
///
/// **Open flow** (`open`):
///   1. `sftp.stat(remotePath)` — refuse if size > [kSshRemoteFileMaxBytes].
///   2. Allocate a local mirror path under
///      `<appSupport>/lumen/ssh-mirror/<host_id>/<sanitized_remote_path>`.
///   3. Stream-download via `sftp.download` into the mirror file.
///   4. Record a [RemoteFileOrigin] keyed by the absolute mirror path.
///   5. Return the mirror [File] — the caller (`AppState.openFile`)
///      treats it as a regular file from then on.
///
/// **Save flow** (`saveIfRemote`):
///   1. Look up the [RemoteFileOrigin] by local path. Return null if
///      this isn't a mirror.
///   2. `sftp.stat(remotePath)` — compare size/mtime against snapshot.
///   3. If drifted, ask `resolveConflict`. If user says "keep both",
///      bail with `SshSaveOutcome.cancelled` so AppState doesn't
///      mark the buffer clean.
///   4. Upload via `sftp.open(write|truncate|create)` →
///      `file.writeBytes(...)`.
///   5. Update the snapshot on the origin so subsequent saves don't
///      re-trigger the conflict prompt.
///
/// **Cache directory layout** is explicit on purpose so a user
/// poking around the appSupport `lumen/ssh-mirror/` directory can
/// recognize what they're looking at: `[host_id]/[absolute remote
/// path with slashes converted to underscore and the leading slash
/// stripped]`. We do NOT preserve the directory structure — the goal
/// is "a single mirror file per remote path", not "a recursive
/// remote FS clone".
class SshRemoteFileService {
  /// Connection lookup — the controller owns the live connections,
  /// the file service just borrows them by host id when it needs to
  /// upload or stat. Returning null here means "the host disconnected
  /// since we opened this file"; save bails with a friendly error.
  final SshConnection? Function(String hostId) connectionForHostId;

  /// localMirrorPath → origin. Lives only in memory (re-opening a
  /// remote file after restart re-downloads).
  final Map<String, RemoteFileOrigin> _origins = {};

  Directory? _cacheRoot;

  SshRemoteFileService({required this.connectionForHostId});

  /// True when [localPath] is a remote-mirror buffer we own. Used by
  /// `AppState.saveFileByPath` to detect "save this through SFTP
  /// instead of the local writeAsString path".
  bool isRemoteMirror(String localPath) => _origins.containsKey(localPath);

  RemoteFileOrigin? originFor(String localPath) => _origins[localPath];

  /// Path to the mirror cache root. Created on first use, never
  /// deleted by us — the user can clear from Settings → SSH.
  Future<Directory> ensureCacheRoot() async {
    final cached = _cacheRoot;
    if (cached != null) return cached;
    final base = await getApplicationSupportDirectory();
    final root = Directory(p.join(base.path, 'lumen', 'ssh-mirror'));
    await root.create(recursive: true);
    _cacheRoot = root;
    return root;
  }

  /// Drop every mirror entry and delete the cache root contents.
  /// Called by the Settings → SSH "Clear mirror cache" button. Any
  /// open editor tab pointing at a wiped mirror file is the caller's
  /// problem to handle (typically: close them first).
  Future<void> clearCache() async {
    _origins.clear();
    final root = _cacheRoot ?? await ensureCacheRoot();
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } catch (_) {}
      await root.create(recursive: true);
    }
  }

  /// Open a remote file. Returns the local mirror [File] on success.
  /// Throws on:
  ///   - File not found / SFTP error.
  ///   - File exceeds [kSshRemoteFileMaxBytes].
  ///   - Connection has gone away.
  Future<File> open({
    required SshConnection conn,
    required String remotePath,
  }) async {
    final sftp = await conn.sftp();
    final attrs = await sftp.stat(remotePath);
    final size = attrs.size;
    if (size != null && size > kSshRemoteFileMaxBytes) {
      throw _RemoteFileTooLargeException(size);
    }

    final mirrorPath = await _mirrorPathFor(conn.host, remotePath);
    final mirror = File(mirrorPath);
    await mirror.parent.create(recursive: true);

    // Stream-download into the mirror file. dartssh2's `download`
    // takes a `StreamSink<List<int>>`; `IOSink` from File.openWrite()
    // satisfies that. closeDestination=true makes dartssh2 flush +
    // close the sink for us so we don't have to bookkeep cleanup on
    // the throw path.
    final sink = mirror.openWrite();
    try {
      await sftp.download(remotePath, sink, closeDestination: true);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }

    _origins[mirrorPath] = RemoteFileOrigin(
      hostId: conn.host.id,
      hostLabel: conn.host.displayName,
      remotePath: remotePath,
      downloadedAt: DateTime.now(),
      downloadedSize: size,
      downloadedMtime: attrs.modifyTime,
    );

    return mirror;
  }

  /// Save a (potentially) remote-mirror buffer. Returns null when
  /// `localPath` isn't a mirror — the caller should fall through to
  /// its normal local write path.
  Future<SshSaveResult?> saveIfRemote({
    required String localPath,
    required String content,
    required SshConflictResolver resolveConflict,
  }) async {
    final origin = _origins[localPath];
    if (origin == null) return null;

    final conn = connectionForHostId(origin.hostId);
    if (conn == null || conn.isClosed) {
      return SshSaveResult(
        SshSaveOutcome.failed,
        errorMessage: 'Connection to ${origin.hostLabel} is closed',
      );
    }

    final bytes = utf8.encode(content);
    if (bytes.length > kSshRemoteFileMaxBytes) {
      return SshSaveResult(
        SshSaveOutcome.failed,
        errorMessage: 'Buffer exceeds $kSshRemoteFileMaxBytes bytes',
      );
    }

    final sftp = await conn.sftp();

    // Conflict detect — compare current remote stat to snapshot.
    int? currentSize;
    int? currentMtime;
    try {
      final stat = await sftp.stat(origin.remotePath);
      currentSize = stat.size;
      currentMtime = stat.modifyTime;
    } catch (_) {
      // File might've been deleted on the remote. Treat as "no
      // remote conflict, but the upload itself will create it" —
      // proceed straight to write.
    }

    final drifted = _hasDrifted(origin, currentSize, currentMtime);
    if (drifted) {
      final overwrite = await resolveConflict(
        origin: origin,
        currentSize: currentSize,
        currentMtime: currentMtime,
      );
      if (!overwrite) {
        return const SshSaveResult(SshSaveOutcome.cancelled);
      }
    }

    // Upload. truncate so we don't leave trailing bytes from a
    // previous-larger-version on disk; create so a since-deleted
    // remote file can still be saved back.
    SftpFile? remote;
    try {
      remote = await sftp.open(
        origin.remotePath,
        mode: SftpFileOpenMode.write |
            SftpFileOpenMode.create |
            SftpFileOpenMode.truncate,
      );
      await remote.writeBytes(Uint8List.fromList(bytes));
      await remote.close();
      remote = null;

      // Re-stat to refresh the snapshot. If this fails, fall back
      // to clamping size = bytes.length, mtime = now-ish; better
      // than leaving the snapshot stale and triggering a phantom
      // conflict on the next save.
      int? newSize = bytes.length;
      int? newMtime;
      try {
        final stat = await sftp.stat(origin.remotePath);
        newSize = stat.size ?? bytes.length;
        newMtime = stat.modifyTime;
      } catch (_) {}

      _origins[localPath] = origin.copyWith(
        downloadedSize: newSize,
        downloadedMtime: newMtime,
        downloadedAt: DateTime.now(),
      );

      // Mirror the new content to the local cache file too — so a
      // subsequent re-open from a fresh tab sees the just-saved
      // bytes without round-tripping the network.
      try {
        await File(localPath).writeAsBytes(bytes);
      } catch (_) {}

      return const SshSaveResult(SshSaveOutcome.succeeded);
    } catch (e) {
      try {
        await remote?.close();
      } catch (_) {}
      debugPrint('SFTP save failed: $e');
      return SshSaveResult(
        SshSaveOutcome.failed,
        errorMessage: e.toString(),
      );
    }
  }

  /// Forget a single mirror entry — called when the editor tab is
  /// closed. The local file stays on disk (cheap re-open later);
  /// `clearCache` is the heavy hammer.
  void forget(String localPath) {
    _origins.remove(localPath);
  }

  /// All mirror paths we currently know about. Used by the editor
  /// tab strip to render the `host:path` suffix.
  Iterable<MapEntry<String, RemoteFileOrigin>> entries() => _origins.entries;

  // ── Internals ────────────────────────────────────────────────

  bool _hasDrifted(
    RemoteFileOrigin origin,
    int? currentSize,
    int? currentMtime,
  ) {
    // Defensive: if both server-side stat fields are null we have
    // no signal. Don't surface a phantom conflict in that case.
    if (currentSize == null && currentMtime == null) return false;
    if (origin.downloadedSize != null &&
        currentSize != null &&
        origin.downloadedSize != currentSize) {
      return true;
    }
    if (origin.downloadedMtime != null &&
        currentMtime != null &&
        origin.downloadedMtime != currentMtime) {
      return true;
    }
    return false;
  }

  Future<String> _mirrorPathFor(SshHost host, String remotePath) async {
    final root = await ensureCacheRoot();
    // Sanitise the remote path into a single filesystem-safe segment.
    // Strip leading slash so the output isn't an absolute path that
    // breaks `p.join`. Slashes → underscore. Backslashes (rare on
    // remote linux but possible on Windows OpenSSH hosts) → underscore.
    // Drive colons (`C:` on Windows OpenSSH) → underscore.
    final sanitized = remotePath
        .replaceAll(RegExp(r'^[\\/]+'), '')
        .replaceAll('/', '_')
        .replaceAll('\\', '_')
        .replaceAll(':', '_');
    return p.join(root.path, host.id, sanitized);
  }
}

/// Thrown by [SshRemoteFileService.open] when the remote file is
/// larger than [kSshRemoteFileMaxBytes]. Carries the actual size so
/// the toast can show the user how big the file is.
class _RemoteFileTooLargeException implements Exception {
  final int size;
  _RemoteFileTooLargeException(this.size);
  @override
  String toString() => 'Remote file is too large to mirror: $size bytes';
}

/// Convenience predicate so callers don't need to import the private
/// exception type just to branch on the message.
bool isRemoteFileTooLarge(Object e) => e is _RemoteFileTooLargeException;

/// Raise the `RemoteFileTooLarge` exception from outside this file
/// without exposing the private exception type. Used by
/// `AppState.grabRemoteFile` so its callers can keep using the
/// existing [isRemoteFileTooLarge] predicate to branch their toasts.
Never raiseRemoteFileTooLarge(int size) {
  throw _RemoteFileTooLargeException(size);
}
