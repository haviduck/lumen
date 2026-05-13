import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:webview_windows/webview_windows.dart';

/// Configures WebView2's per-environment `userDataFolder` so two
/// Lumen processes never share Chromium state.
///
/// **Why this exists.** WebView2's contract is documented: each call to
/// `CreateCoreWebView2EnvironmentWithOptions` must own a unique
/// `userDataFolder`. Two processes pointing at the same folder either
/// (a) block one process indefinitely on `EBWebView/Default/parent.lock`
/// (manifests as a "frozen" Lumen window when a webview is mounted),
/// or (b) silently corrupt cookie/IndexedDB state for both. The
/// bundled `packages/webview_windows` plugin defaults to a single
/// shared folder (`platform_->GetDefaultDataDirectory()`), so opening
/// two Lumen windows and triggering a webview in either (watch-media,
/// Teams shortcut, SSH render, copilot bridge UI) was the crash trigger
/// reported as "no pattern". The lock contention only fires when the
/// second window's WebView2 environment actually initialises, which is
/// what made it look pattern-less.
///
/// **Mechanism.** On boot, we walk slot directories
/// `<appSupport>/lumen/webview2/slot-N` from N=0 upward and try to
/// acquire an exclusive flock on a `.in_use.lock` file inside each.
/// The first slot we can lock becomes this process's WebView2 user
/// data folder for the lifetime of the process. The lock RandomAccessFile
/// is held in a static so it never closes, which is the OS contract
/// that keeps the slot reserved.
///
/// **Cleanup.** A polite cleanup sweep tries to delete `slot-*` folders
/// whose lock is currently un-acquirable + last-modified more than 7
/// days ago. Best-effort; failure to clean up old slots is fine,
/// the disk cost is bounded by the slot cap.
///
/// **Failure mode.** If `path_provider` can't resolve the support
/// directory, or every slot up to the cap is taken, or the runtime
/// has no `webview_windows` plugin registered, we fall back to letting
/// the plugin pick its default folder. The user is back in the
/// pre-fix lock-contention scenario, but no boot-blocking error.
/// Never throws across [bootstrap].
class WebviewEnvironment {
  WebviewEnvironment._();

  static const int _maxSlots = 16;
  static const String _slotPrefix = 'slot-';
  static const String _lockName = '.in_use.lock';
  static const Duration _staleAfter = Duration(days: 7);

  static bool _initialized = false;
  // The lock handle MUST stay open for the process lifetime — closing it
  // (or letting it get GC'd) releases the OS-level lock and frees the
  // slot for another Lumen process to claim. Keep it pinned in a static
  // and silence the "unused" lint: the field's purpose is its existence,
  // not any read access.
  // ignore: unused_field
  static RandomAccessFile? _lockHandle;
  static String? _chosenPath;

  /// Whether bootstrap ran successfully (regardless of whether we
  /// ended up using a custom path or the default fallback).
  static bool get isReady => _initialized;

  /// The resolved per-process WebView2 user data folder, or `null`
  /// if bootstrap failed and the plugin will pick its default.
  static String? get userDataPath => _chosenPath;

  /// Probe the slot directories, lock one, and configure the WebView2
  /// environment to point at it. Must be called once from `main()` —
  /// after `WidgetsFlutterBinding.ensureInitialized()` but BEFORE any
  /// `WebviewController.initialize()` lands, since the environment is
  /// shared across all controllers and gets locked in by the first
  /// init. Idempotent: a second call is a no-op.
  static Future<void> bootstrap() async {
    if (_initialized) return;
    if (!_isSupported) {
      _initialized = true;
      return;
    }
    try {
      final root = await _resolveRoot();
      if (root == null) {
        _initialized = true;
        return;
      }
      _maybeCleanupStale(root);
      final slot = _acquireSlot(root);
      if (slot == null) {
        debugPrint(
          'WebviewEnvironment: all $_maxSlots slots locked; '
          'falling back to plugin default (multi-window may freeze).',
        );
        _initialized = true;
        return;
      }
      await WebviewController.initializeEnvironment(userDataPath: slot);
      _chosenPath = slot;
      _initialized = true;
    } catch (e, st) {
      debugPrint('WebviewEnvironment.bootstrap failed: $e\n$st');
      _initialized = true;
    }
  }

  static Future<Directory?> _resolveRoot() async {
    try {
      final support = await getApplicationSupportDirectory();
      final root = Directory(p.join(support.path, 'webview2'));
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      return root;
    } catch (e) {
      debugPrint('WebviewEnvironment._resolveRoot failed: $e');
      return null;
    }
  }

  /// Walk slots in order, try to lock the first available one. Returns
  /// the absolute path of the locked slot directory, or `null` if all
  /// slots up to [_maxSlots] are taken.
  static String? _acquireSlot(Directory root) {
    for (var i = 0; i < _maxSlots; i++) {
      final slotDir = Directory(p.join(root.path, '$_slotPrefix$i'));
      try {
        slotDir.createSync(recursive: true);
      } catch (_) {
        continue;
      }
      final lockFile = File(p.join(slotDir.path, _lockName));
      RandomAccessFile? raf;
      try {
        raf = lockFile.openSync(mode: FileMode.write);
        // `FileLock.exclusive` is non-blocking — throws / returns
        // unsuccessfully if another process holds any lock on the
        // region. That's exactly the probe we want.
        raf.lockSync(FileLock.exclusive);
        // Stamp the lockfile with the PID so a human poking around the
        // app-support folder can tell which process owns which slot.
        // Truncating to a fresh write is fine: the lock is held on the
        // file descriptor, not the contents.
        try {
          raf.setPositionSync(0);
          raf.truncateSync(0);
          raf.writeStringSync('pid=$pid\n');
          raf.flushSync();
        } catch (_) {
          // Stamp is decorative; lock acquisition is the actual contract.
        }
        _lockHandle = raf;
        return slotDir.path;
      } catch (_) {
        try {
          raf?.closeSync();
        } catch (_) {}
        continue;
      }
    }
    return null;
  }

  /// Best-effort: walk all `slot-*` directories. If we can lock one AND
  /// it hasn't been touched in over [_staleAfter], delete it so the
  /// app-support folder doesn't accumulate dead slots forever. Never
  /// throws; failure to clean up an individual slot is fine.
  static void _maybeCleanupStale(Directory root) {
    List<FileSystemEntity> children;
    try {
      children = root.listSync(followLinks: false);
    } catch (_) {
      return;
    }
    final now = DateTime.now();
    for (final entity in children) {
      if (entity is! Directory) continue;
      final name = p.basename(entity.path);
      if (!name.startsWith(_slotPrefix)) continue;
      final lockFile = File(p.join(entity.path, _lockName));
      RandomAccessFile? raf;
      try {
        if (!lockFile.existsSync()) {
          // No lockfile yet — definitely unused. Age-gate before delete
          // so a freshly-created slot for another process that hasn't
          // gotten as far as writing the lock doesn't get nuked from
          // under it.
          final stat = entity.statSync();
          if (now.difference(stat.modified) < _staleAfter) continue;
          entity.deleteSync(recursive: true);
          continue;
        }
        raf = lockFile.openSync(mode: FileMode.write);
        raf.lockSync(FileLock.exclusive);
        // Lock acquired ⇒ no other process owns this slot. Check age
        // and reap if stale.
        final stat = entity.statSync();
        if (now.difference(stat.modified) >= _staleAfter) {
          try {
            raf.closeSync();
            raf = null;
          } catch (_) {}
          entity.deleteSync(recursive: true);
        }
      } catch (_) {
        // Lock failed → another process owns the slot. Skip.
      } finally {
        try {
          raf?.closeSync();
        } catch (_) {}
      }
    }
  }

  static bool get _isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows;
  }
}
