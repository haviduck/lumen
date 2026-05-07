import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Canonical workspace/app-support config locations for Lumen.
///
/// Two directory namespaces coexist:
///   - `.lumen/`  — Lumen-private state (rules.md, tools/, legacy
///                  skills/, legacy knowledgebase.md). Read/written by
///                  Lumen only.
///   - `.agents/` — cross-tool ecosystem dir for content other agentic
///                  IDEs also consume (skills, knowledgebase). Claude
///                  Code, Cursor, Aider, etc. are converging on this
///                  name, so authoring once benefits the user across
///                  tools.
///
/// Skills + knowledgebase live in `.agents/`. Rules + tool JSON stay
/// in `.lumen/` (those are Lumen-specific concepts and would conflict
/// with neighbouring tools' equivalents). Skills loader keeps a
/// `.lumen/skills/` fallback for one release so existing workspaces
/// keep working until the on-launch migration runs.
class LumenWorkspaceConfig {
  static const String dirName = '.lumen';
  static const String legacyDirName = '.duckoff';
  static const String agentsDirName = '.agents';
  static const String rulesFileName = 'rules.md';
  static const String toolsDirName = 'tools';
  static const String skillsDirName = 'skills';
  static const String knowledgebaseFileName = 'knowledgebase.md';

  static Directory dir(String basePath) => Directory(p.join(basePath, dirName));

  static Directory legacyDir(String basePath) =>
      Directory(p.join(basePath, legacyDirName));

  static Directory agentsDir(String basePath) =>
      Directory(p.join(basePath, agentsDirName));

  static File rulesFile(String basePath) =>
      File(p.join(basePath, dirName, rulesFileName));

  /// Directory of command-style external tool definitions
  /// (`*.json`) — see `services/external_tool_loader.dart`.
  static Directory toolsDir(String workspacePath) =>
      Directory(p.join(workspacePath, dirName, toolsDirName));

  /// Canonical (current) directory of instruction-style skill
  /// markdown files (`*.md`). Lives under `.agents/skills/` so
  /// cross-tool ecosystems can share the same authored skills.
  /// Loader: `services/workspace_skills_service.dart`. Generator
  /// writes here; importer writes here. The `.lumen/skills/` path
  /// (see [legacySkillsDir]) is read-only fallback for workspaces
  /// that haven't been migrated yet.
  static Directory skillsDir(String workspacePath) =>
      Directory(p.join(workspacePath, agentsDirName, skillsDirName));

  /// Pre-`.agents` location of skills. Kept for one release as a
  /// fallback path so workspaces created before the rename still
  /// load their skills; the on-launch migration in
  /// `WorkspaceSkillsService.reload` copies its contents to
  /// [skillsDir] on first open.
  static Directory legacySkillsDir(String workspacePath) =>
      Directory(p.join(workspacePath, dirName, skillsDirName));

  /// Cross-chat memory file. Lives under `.agents/` so other
  /// agentic tools that also adopt the convention pick it up.
  /// See `services/kb_service.dart` for read/write/migrate.
  static File knowledgebaseFile(String workspacePath) =>
      File(p.join(workspacePath, agentsDirName, knowledgebaseFileName));

  /// Pre-`.agents` knowledgebase location. Migrated to
  /// [knowledgebaseFile] on first open by `KbService.ensure`.
  static File legacyKnowledgebaseFile(String workspacePath) =>
      File(p.join(workspacePath, dirName, knowledgebaseFileName));

  /// Materialise `.agents/` (creating it lazily). Idempotent.
  static Future<Directory> ensureAgentsDir(String basePath) async {
    final d = agentsDir(basePath);
    if (!await d.exists()) {
      await d.create(recursive: true);
    }
    return d;
  }

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
