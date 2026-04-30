import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Always-ignore patterns regardless of .gitignore content. These are
/// build artefacts that explode backup size with no user value.
const _hardIgnore = <String>{
  'node_modules', '.git', '.dart_tool', 'build', 'dist', 'out',
  '.next', '.nuxt', '.svelte-kit', '.turbo', '.cache', '.parcel-cache',
  '.idea', '.vscode-test', 'venv', '.venv', 'env', '__pycache__',
  '.pytest_cache', '.mypy_cache', '.tox', 'target', 'Pods',
  '.gradle', '.expo', '.expo-shared', '.flutter-plugins',
  '.flutter-plugins-dependencies', 'coverage',
};

class BackupRecord {
  final String id;
  final String workspacePath;
  final String archivePath;
  final DateTime createdAt;
  final int sizeBytes;

  BackupRecord({
    required this.id,
    required this.workspacePath,
    required this.archivePath,
    required this.createdAt,
    required this.sizeBytes,
  });
}

class BackupService {
  Directory? _root;

  Future<Directory> backupRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'backups'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _root = dir;
    return dir;
  }

  Future<List<String>> _readGitignore(String workspacePath) async {
    final f = File(p.join(workspacePath, '.gitignore'));
    if (!await f.exists()) return [];
    final raw = await f.readAsString();
    return raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('#'))
        .toList();
  }

  bool _matchesPattern(String relPath, String pattern) {
    if (pattern.startsWith('!')) return false;
    final clean = pattern.replaceAll(RegExp(r'^/+'), '').replaceAll(RegExp(r'/+$'), '');
    if (clean.contains('/')) {
      return relPath == clean || relPath.startsWith('$clean/');
    }
    final segments = relPath.split('/');
    if (clean.contains('*')) {
      final regex = RegExp(
        '^${RegExp.escape(clean).replaceAll(r'\*', '.*')}\$',
      );
      return segments.any(regex.hasMatch);
    }
    return segments.contains(clean);
  }

  bool _shouldExclude(String relPath, List<String> gitignorePatterns) {
    final segments = relPath.split('/');
    for (final s in segments) {
      if (_hardIgnore.contains(s)) return true;
    }
    for (final pat in gitignorePatterns) {
      if (_matchesPattern(relPath, pat)) return true;
    }
    return false;
  }

  /// Returns the path to the produced archive.
  Future<BackupRecord> backup(
    String workspacePath, {
    void Function(String fileName)? onProgress,
  }) async {
    final ws = Directory(workspacePath);
    if (!await ws.exists()) {
      throw StateError('Workspace does not exist: $workspacePath');
    }

    final ignore = await _readGitignore(workspacePath);
    final timestamp = DateTime.now();
    final id = 'backup_${timestamp.millisecondsSinceEpoch}';
    final wsName = p.basename(workspacePath);
    final root = await backupRoot();
    final archivePath = p.join(root.path, '${wsName}_$id.zip');

    final encoder = ZipFileEncoder();
    encoder.create(archivePath);

    try {
      await for (final entity
          in ws.list(recursive: true, followLinks: false)) {
        final rel = p
            .relative(entity.path, from: workspacePath)
            .replaceAll(r'\', '/');
        if (rel.isEmpty || rel == '.') continue;
        if (_shouldExclude(rel, ignore)) continue;

        if (entity is File) {
          try {
            onProgress?.call(rel);
            encoder.addFile(entity, rel);
          } catch (e) {
            debugPrint('Skip file (read error): $rel — $e');
          }
        }
      }
    } finally {
      encoder.close();
    }

    final size = await File(archivePath).length();
    return BackupRecord(
      id: id,
      workspacePath: workspacePath,
      archivePath: archivePath,
      createdAt: timestamp,
      sizeBytes: size,
    );
  }

  Future<List<BackupRecord>> listBackups() async {
    final root = await backupRoot();
    final list = <BackupRecord>[];
    await for (final e in root.list()) {
      if (e is File && e.path.endsWith('.zip')) {
        final stat = await e.stat();
        list.add(BackupRecord(
          id: p.basenameWithoutExtension(e.path),
          workspacePath: '',
          archivePath: e.path,
          createdAt: stat.modified,
          sizeBytes: stat.size,
        ));
      }
    }
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  Future<void> deleteBackup(String archivePath) async {
    final f = File(archivePath);
    if (await f.exists()) await f.delete();
  }

  Future<void> revealInOs(String archivePath) async {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', archivePath]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', archivePath]);
    } else {
      await Process.start('xdg-open', [p.dirname(archivePath)]);
    }
  }

  /// Decompress a backup zip into a directory selected by caller.
  Future<void> restore(String archivePath, String targetDir) async {
    final bytes = await File(archivePath).readAsBytes();
    final archive = ZipDecoder().decodeBytes(bytes);
    for (final entry in archive) {
      final outPath = p.join(targetDir, entry.name);
      if (entry.isFile) {
        final f = File(outPath);
        await f.create(recursive: true);
        await f.writeAsBytes(entry.content as List<int>);
      } else {
        await Directory(outPath).create(recursive: true);
      }
    }
  }
}
