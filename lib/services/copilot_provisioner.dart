import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Materialises the bundled GitHub Copilot bridge into app-support.
///
/// The bridge is a tiny Node program that talks to `@github/copilot-sdk`.
/// Flutter assets are not spawnable files, so we copy the script and its
/// package manifest to disk, then run `npm install` in that directory when
/// the manifest/script stamp changes.
class CopilotProvisioner {
  CopilotProvisioner._();

  static const _assetRoot = 'assets/bin/copilot';
  static const _bridgeAsset = '$_assetRoot/bridge.js';
  static const _packageAsset = '$_assetRoot/package.json';

  static String? _cachedBridgePath;
  static String? _cachedFailure;

  static String? get lastFailure => _cachedFailure;

  static Future<String?> ensureRoot() async {
    final bridgePath = await ensure();
    if (bridgePath == null) return null;
    return p.dirname(bridgePath);
  }

  static Future<String?> ensureCliPath() async {
    final root = await ensureRoot();
    if (root == null) return null;
    final binDir = p.join(root, 'node_modules', '.bin');
    final exeName = Platform.isWindows ? 'copilot.cmd' : 'copilot';
    final cli = File(p.join(binDir, exeName));
    if (await cli.exists()) return cli.path;
    _cachedFailure = 'Copilot CLI shim not found at ${cli.path}';
    return null;
  }

  static Future<String?> ensure() async {
    if (_cachedBridgePath != null) return _cachedBridgePath;

    try {
      final bridge = await _loadString(_bridgeAsset);
      final packageJson = await _loadString(_packageAsset);
      final stamp = sha256
          .convert(utf8.encode('$bridge\n$packageJson'))
          .toString();

      final supportDir = await getApplicationSupportDirectory();
      final root = Directory(p.join(supportDir.path, 'bin', 'copilot'));
      await root.create(recursive: true);

      final bridgeFile = File(p.join(root.path, 'bridge.js'));
      final packageFile = File(p.join(root.path, 'package.json'));
      final stampFile = File(p.join(root.path, '.copilot-bridge.sha256'));

      final needsInstall =
          !await _stampMatches(stampFile, stamp) ||
          !await bridgeFile.exists() ||
          !await packageFile.exists() ||
          !await Directory(p.join(root.path, 'node_modules')).exists();

      if (needsInstall) {
        await bridgeFile.writeAsString(bridge, flush: true);
        await packageFile.writeAsString(packageJson, flush: true);
        final npm = Platform.isWindows ? 'npm.cmd' : 'npm';
        final result = await Process.run(npm, [
          'install',
          '--omit=dev',
          '--no-audit',
          '--no-fund',
        ], workingDirectory: root.path).timeout(const Duration(minutes: 3));
        if (result.exitCode != 0) {
          _cachedFailure =
              'npm install failed (${result.exitCode}): ${result.stderr}';
          debugPrint('CopilotProvisioner.ensure failed: $_cachedFailure');
          return null;
        }
        await stampFile.writeAsString(stamp, flush: true);
      }

      _cachedFailure = null;
      _cachedBridgePath = bridgeFile.path;
      return _cachedBridgePath;
    } catch (e, st) {
      _cachedFailure = '$e';
      debugPrint('CopilotProvisioner.ensure failed: $e\n$st');
      return null;
    }
  }

  static Future<String> _loadString(String key) async {
    final data = await rootBundle.load(key);
    return utf8.decode(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
    );
  }

  static Future<bool> _stampMatches(File stampFile, String expected) async {
    try {
      if (!await stampFile.exists()) return false;
      return (await stampFile.readAsString()).trim() == expected;
    } catch (_) {
      return false;
    }
  }
}
