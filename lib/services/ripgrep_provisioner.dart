import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Materialises the bundled ripgrep binary onto disk so SEARCH_TEXT
/// (and any future tool that wants the rg engine) can spawn it via
/// `Process.run`.
///
/// ## Why bundle rg
///
/// The native Dart fallback in `tool_registry.dart` covers literal +
/// `:re` + `:cs` SEARCH_TEXT, but `:glob`, `:context`, and the
/// 10–100× speed gap on real codebases all need ripgrep. Requiring
/// colleagues to `winget install BurntSushi.ripgrep.MSVC` before
/// SEARCH_TEXT works well is bad IDE UX, so we ship the binary in
/// the app bundle and extract it on first use.
///
/// ## Asset → disk extraction
///
/// Flutter assets aren't real files at runtime. `Process.run` needs
/// a real path on disk. We materialise the asset bytes into
/// `<appSupport>/bin/rg/<platformDir>/<rgExecutable>` once, stamp it
/// with a SHA-256 of the bundled bytes, and re-extract automatically
/// when a future Lumen build ships a different rg version.
///
/// ## Failure mode
///
/// Returns `null` on any failure (asset missing, IO error, platform
/// without a bundled binary). The caller (`_runRipgrep` in
/// `tool_registry.dart`) treats null as "no provisioned rg this
/// session" and falls back to whatever the user has on `$PATH`,
/// then to the pure-Dart walker. Provisioning failures must never
/// crash the IDE — degrade silently.
class RipgrepProvisioner {
  RipgrepProvisioner._();

  /// Triple identifying the OS+arch combination, used as both the
  /// asset-bundle subdirectory and the on-disk extraction folder.
  /// Returns `null` for platforms / arches we don't ship a binary
  /// for yet — caller silently falls back to PATH-rg.
  ///
  /// We use `Abi.current()` from `dart:ffi` rather than
  /// `Platform.isWindows` alone because Windows-on-ARM is real (the
  /// user's first attempt at bundling rg actually pulled the ARM64
  /// build; loading it on x64 Windows produces a confusing "not
  /// compatible with this version of Windows" error). Splitting by
  /// arch as well as OS prevents that class of silent mistake.
  static String? _platformTriple() {
    final abi = Abi.current();
    if (abi == Abi.windowsX64) return 'win-x64';
    if (abi == Abi.windowsArm64) return 'win-arm64';
    if (abi == Abi.macosX64) return 'macos-x64';
    if (abi == Abi.macosArm64) return 'macos-arm64';
    if (abi == Abi.linuxX64) return 'linux-x64';
    if (abi == Abi.linuxArm64) return 'linux-arm64';
    return null;
  }

  /// Filename of the executable on this platform.
  static String _executableName() =>
      Platform.isWindows ? 'rg.exe' : 'rg';

  /// Asset key for the platform-appropriate binary. Returns `null`
  /// when we don't ship a binary for the current OS+arch.
  static String? _assetKeyForPlatform() {
    final triple = _platformTriple();
    if (triple == null) return null;
    return 'assets/bin/rg/$triple/${_executableName()}';
  }

  static String? _cachedRgPath;
  static bool _cachedNotAvailable = false;

  /// Returns the absolute path to a usable `rg` binary, materialising
  /// from the asset bundle on first call. Cached for the process
  /// lifetime after the first successful resolve. Returns `null`
  /// when the binary isn't bundled for this platform OR extraction
  /// failed — caller falls back to PATH / native walker.
  static Future<String?> ensure() async {
    if (_cachedRgPath != null) return _cachedRgPath;
    if (_cachedNotAvailable) return null;
    final assetKey = _assetKeyForPlatform();
    final platDir = _platformTriple();
    if (assetKey == null || platDir == null) {
      _cachedNotAvailable = true;
      return null;
    }
    try {
      final bytes = await _loadAsset(assetKey);
      if (bytes == null) {
        _cachedNotAvailable = true;
        return null;
      }
      final stamp = sha256.convert(bytes).toString();

      final supportDir = await getApplicationSupportDirectory();
      final binRoot = Directory(p.join(supportDir.path, 'bin', 'rg', platDir));
      await binRoot.create(recursive: true);

      final exeFile = File(p.join(binRoot.path, _executableName()));
      final stampFile = File(p.join(binRoot.path, '.rg.sha256'));

      final needsExtract = !await _stampMatches(stampFile, stamp) ||
          !await exeFile.exists();
      if (needsExtract) {
        // Atomic-ish: write next to the target then rename, so a
        // half-written .exe can never be observed as "ready".
        final tmpFile = File('${exeFile.path}.tmp');
        await tmpFile.writeAsBytes(bytes, flush: true);
        if (await exeFile.exists()) {
          try {
            await exeFile.delete();
          } catch (_) {
            // On Windows, the file may be locked if a previous
            // SEARCH_TEXT is in flight from a hot-reload session.
            // Bail to PATH this session — next launch will succeed.
            _cachedNotAvailable = true;
            return null;
          }
        }
        await tmpFile.rename(exeFile.path);
        // POSIX: ensure the bit is executable. No-op on Windows.
        if (!Platform.isWindows) {
          try {
            await Process.run('chmod', ['+x', exeFile.path]);
          } catch (_) {
            // Best-effort; if chmod isn't available we'll find out
            // when Process.run fails and the caller falls back.
          }
        }
        await stampFile.writeAsString(stamp, flush: true);
      }

      _cachedRgPath = exeFile.path;
      return _cachedRgPath;
    } catch (e, st) {
      debugPrint('RipgrepProvisioner.ensure failed: $e\n$st');
      _cachedNotAvailable = true;
      return null;
    }
  }

  static Future<Uint8List?> _loadAsset(String key) async {
    try {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      debugPrint('RipgrepProvisioner: missing asset $key: $e');
      return null;
    }
  }

  static Future<bool> _stampMatches(File stampFile, String expected) async {
    try {
      if (!await stampFile.exists()) return false;
      final actual = (await stampFile.readAsString()).trim();
      return actual == expected;
    } catch (_) {
      return false;
    }
  }
}
