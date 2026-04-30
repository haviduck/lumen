import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Canonical workspace/app-support config locations for Lumen.
class LumenWorkspaceConfig {
  static const String dirName = '.lumen';
  static const String legacyDirName = '.duckoff';
  static const String rulesFileName = 'rules.md';
  static const String toolsDirName = 'tools';
  static const String skillsDirName = 'skills';

  static Directory dir(String basePath) => Directory(p.join(basePath, dirName));

  static Directory legacyDir(String basePath) =>
      Directory(p.join(basePath, legacyDirName));

  static File rulesFile(String basePath) =>
      File(p.join(basePath, dirName, rulesFileName));

  /// Directory of command-style external tool definitions
  /// (`*.json`) — see `services/external_tool_loader.dart`.
  static Directory toolsDir(String workspacePath) =>
      Directory(p.join(workspacePath, dirName, toolsDirName));

  /// Directory of instruction-style skill markdown files
  /// (`*.md`) — see `services/workspace_skills_service.dart`.
  /// Distinct from `toolsDir`: tools are *invoked*, skills are
  /// *read and followed*.
  static Directory skillsDir(String workspacePath) =>
      Directory(p.join(workspacePath, dirName, skillsDirName));

  /// Moves an old `.duckoff` config directory to `.lumen` when possible.
  ///
  /// If both exist, `.lumen` wins and the legacy directory is left untouched so
  /// user data is never silently overwritten.
  static Future<Directory> ensureDir(String basePath) async {
    final canonical = dir(basePath);
    if (await canonical.exists()) return canonical;

    final legacy = legacyDir(basePath);
    if (await legacy.exists()) {
      try {
        await legacy.rename(canonical.path);
        return canonical;
      } catch (e) {
        debugPrint('Could not migrate ${legacy.path} to ${canonical.path}: $e');
        try {
          await _copyDirectory(legacy, canonical);
          return canonical;
        } catch (copyError) {
          debugPrint(
            'Could not copy ${legacy.path} to ${canonical.path}: $copyError',
          );
        }
      }
    }

    await canonical.create(recursive: true);
    return canonical;
  }

  static Future<void> _copyDirectory(Directory source, Directory target) async {
    await target.create(recursive: true);
    await for (final entity in source.list()) {
      final targetPath = p.join(target.path, p.basename(entity.path));
      if (entity is Directory) {
        await _copyDirectory(entity, Directory(targetPath));
      } else if (entity is File) {
        await entity.copy(targetPath);
      }
    }
  }
}
