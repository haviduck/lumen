import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Unpacks the bundled uBlock Origin Lite (MV3) extension zip from the
/// Flutter asset bundle into a real on-disk folder so WebView2's
/// `ICoreWebView2Profile7::AddBrowserExtension` can consume it.
///
/// ## Why a runtime extraction step
///
/// `AddBrowserExtension` requires a *real* directory path (it reads
/// manifest.json, JS files, ruleset JSONs etc. live off disk while the
/// browser runs). Flutter assets aren't real files at runtime — they're
/// served through the asset bundle and only exist as zipped blobs inside
/// the app payload. So we have to materialise them once.
///
/// We unpack into the app-support directory (cross-instance state, not
/// the workspace) and version-stamp by SHA-256 of the bundled zip. If a
/// future Lumen build ships a newer uBOL zip, the stamp mismatches and
/// the extracted folder is rebuilt on next launch. Existing folder is
/// nuked rather than merge-extracted to avoid stale-file accumulation.
///
/// ## Failure mode
///
/// Returns `null` on any failure (asset missing, IO error, zip corrupt).
/// The caller (`MediaController`) treats null as "no ad blocking
/// available this session" and falls back to the JS-injection layer.
/// We never throw across the public API — first-launch IO failures
/// shouldn't crash the IDE, just degrade ad blocking.
class ExtensionProvisioner {
  ExtensionProvisioner._();

  static const String _ubolAssetKey = 'assets/extensions/ublock-lite.zip';
  static const String _ubolDirName = 'ublock-lite';
  static const String _ubolStampName = '.ublock-lite.sha256';

  static String? _cachedUbolPath;

  /// Returns the absolute path to the unpacked uBlock Origin Lite folder,
  /// extracting from the asset bundle on first call (and re-extracting
  /// when the bundled zip has changed). Cached for the process lifetime
  /// after the first successful materialisation.
  static Future<String?> ensureUblockLite() async {
    if (_cachedUbolPath != null) return _cachedUbolPath;
    try {
      final bytes = await _loadAsset(_ubolAssetKey);
      if (bytes == null) return null;
      final stamp = sha256.convert(bytes).toString();

      final supportDir = await getApplicationSupportDirectory();
      final extensionsRoot = Directory(p.join(supportDir.path, 'extensions'));
      await extensionsRoot.create(recursive: true);

      final targetDir = Directory(p.join(extensionsRoot.path, _ubolDirName));
      final stampFile = File(p.join(extensionsRoot.path, _ubolStampName));

      final needsExtract = !await _stampMatches(stampFile, stamp) ||
          !await _looksExtracted(targetDir);
      if (needsExtract) {
        if (await targetDir.exists()) {
          await targetDir.delete(recursive: true);
        }
        await targetDir.create(recursive: true);
        if (!await _extractZip(bytes, targetDir.path)) {
          return null;
        }
        await stampFile.writeAsString(stamp, flush: true);
      }

      _cachedUbolPath = targetDir.path;
      return _cachedUbolPath;
    } catch (e, st) {
      debugPrint('ExtensionProvisioner.ensureUblockLite failed: $e\n$st');
      return null;
    }
  }

  static Future<Uint8List?> _loadAsset(String key) async {
    try {
      final data = await rootBundle.load(key);
      return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } catch (e) {
      debugPrint('ExtensionProvisioner: missing asset $key: $e');
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

  // Sanity check after a previous extraction — the manifest must exist
  // for the directory to be loadable. Catches the case where someone
  // manually deleted bits of the unpacked folder while the stamp file
  // is still present.
  static Future<bool> _looksExtracted(Directory dir) async {
    try {
      if (!await dir.exists()) return false;
      final manifest = File(p.join(dir.path, 'manifest.json'));
      return manifest.existsSync();
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _extractZip(Uint8List bytes, String destPath) async {
    try {
      final archive = ZipDecoder().decodeBytes(bytes);
      for (final entry in archive) {
        // ZIP entries can carry `..` segments in malicious archives;
        // refuse anything that escapes destPath. Belt-and-braces — uBOL
        // ships clean — but a stray malicious zip dropped here shouldn't
        // grant arbitrary file write.
        final relative = entry.name.replaceAll('\\', '/');
        if (relative.contains('..')) continue;
        final outPath = p.normalize(p.join(destPath, relative));
        if (!p.isWithin(destPath, outPath) && p.equals(destPath, outPath) == false) {
          continue;
        }
        if (entry.isFile) {
          final f = File(outPath);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(entry.content as List<int>, flush: true);
        } else {
          await Directory(outPath).create(recursive: true);
        }
      }
      return true;
    } catch (e) {
      debugPrint('ExtensionProvisioner: zip extract failed: $e');
      return false;
    }
  }
}
