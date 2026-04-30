import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'lumen_workspace_config.dart';

/// One workspace skill — an instruction-set markdown document with
/// optional YAML-ish frontmatter that the chat agent reads (NOT
/// invokes) to gain a behavioural capability.
///
/// **Skill vs. Tool, explicitly:**
///   - **Tool** (`.lumen/tools/*.json`) = the agent fires
///     `<<<NAME: arg>>>` and a shell command runs. *Action.*
///   - **Skill** (`.lumen/skills/*.md`) = the agent reads the body
///     and follows it as part of its system prompt. *Convention.*
///
/// Skills are the right shape for "design system / coding style /
/// project conventions / domain knowledge"-type requests. Tools are
/// the right shape for "run tests / lint / build / scaffold"-type
/// requests.
class WorkspaceSkill {
  /// Stable filename-safe id. Defaults to the file's basename
  /// without extension when frontmatter omits it.
  final String id;

  /// Human-readable label used in the system prompt heading and
  /// any UI listing.
  final String name;

  /// Plain-language description of when the agent should apply this
  /// skill. Injected near the top of the skill block so the agent
  /// can decide relevance at a glance without re-reading the body.
  /// `null` means "always-on" (the model should treat it as
  /// applicable to every prompt for this workspace).
  final String? trigger;

  /// Whether the skill ships enabled in the system prompt by
  /// default (when the user hasn't explicitly toggled it). True
  /// is the safe default — a skill that exists but isn't loaded is
  /// dead weight.
  final bool defaultEnabled;

  /// Markdown body — what the agent actually reads. Free-form;
  /// the loader doesn't impose structure.
  final String body;

  /// Absolute path to the source `.md` file. Used by the settings
  /// UI's "open in editor" affordance.
  final String filePath;

  /// True when this skill came from the workspace's own
  /// `.lumen/skills/` (vs. the global app-support skills dir).
  /// Workspace-local skills win on id collisions.
  final bool isWorkspaceLocal;

  const WorkspaceSkill({
    required this.id,
    required this.name,
    required this.trigger,
    required this.defaultEnabled,
    required this.body,
    required this.filePath,
    required this.isWorkspaceLocal,
  });
}

/// Loads workspace + global skill markdown files, validates them,
/// and compiles the active set into a single text block ready to
/// drop into the chat-agent system prompt.
///
/// Two source roots, in priority order:
///   1. `<workspace>/.lumen/skills/*.md` (workspace-local; wins on
///      id collision)
///   2. `<app-support>/.lumen/skills/*.md` (global, applies to
///      every workspace)
///
/// Frontmatter parsing is intentionally minimal — a YAML-ish header
/// delimited by `---` lines, with `key: value` rows. We don't pull
/// in a real YAML dep because the field set is tiny and stable.
/// Files without frontmatter are still valid skills (sensible
/// defaults filled in from the filename).
///
/// Extends [ChangeNotifier] so the Settings UI can re-render the
/// skill list reactively after a `reload` (e.g. after the generator
/// writes a new file).
class WorkspaceSkillsService extends ChangeNotifier {
  String? _workspacePath;
  List<WorkspaceSkill> _all = const [];

  /// Last-loaded skills (workspace + global merged, dedup'd by id
  /// with workspace-local winning).
  List<WorkspaceSkill> get all => List.unmodifiable(_all);

  /// Reload the on-disk skill set for [workspacePath]. Pass `null`
  /// to load just the global skills (no workspace open).
  ///
  /// Parsing failures are logged and the offending file is silently
  /// skipped — same defensive shape as `ExternalToolLoader`. A
  /// malformed skill should never crash the IDE.
  Future<List<WorkspaceSkill>> reload(String? workspacePath) async {
    _workspacePath = workspacePath;
    final out = <String, WorkspaceSkill>{};

    // Global first; workspace-local overrides.
    try {
      final globalDir = await _globalSkillsDir();
      final globalSkills = await _walkDir(globalDir, isWorkspaceLocal: false);
      for (final s in globalSkills) {
        out[s.id] = s;
      }
    } catch (e) {
      debugPrint('SkillsService: global walk failed: $e');
    }

    if (workspacePath != null) {
      try {
        final wsDir = LumenWorkspaceConfig.skillsDir(workspacePath);
        final wsSkills = await _walkDir(wsDir, isWorkspaceLocal: true);
        for (final s in wsSkills) {
          out[s.id] = s;
        }
      } catch (e) {
        debugPrint('SkillsService: workspace walk failed: $e');
      }
    }

    _all = out.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    notifyListeners();
    return _all;
  }

  /// Build the system-prompt block for the currently-loaded skill
  /// set, filtered by [enabledIds]. Returns an empty string when no
  /// skills are active so the system prompt doesn't gain a stray
  /// empty header.
  ///
  /// Format:
  /// ```
  /// ## Workspace skills
  /// (one-line about how the agent should treat these)
  ///
  /// ### <name>
  /// _When to apply: <trigger>_
  /// <body>
  ///
  /// ### <name 2>
  /// ...
  /// ```
  String compileForPrompt({Set<String>? enabledIds}) {
    if (_all.isEmpty) return '';
    final active = _all.where((s) {
      if (enabledIds == null) return s.defaultEnabled;
      return enabledIds.contains(s.id);
    }).toList();
    if (active.isEmpty) return '';

    final buf = StringBuffer();
    buf.writeln('## Workspace skills');
    buf.writeln(
      'These are user-authored conventions / instructions for this '
      'workspace. Apply each skill whose "When to apply" line matches '
      'the current task. Skills are NOT shell commands — read them '
      'and follow the guidance, do not try to invoke them with `<<<>>>`.',
    );
    buf.writeln('');
    for (final s in active) {
      buf.writeln('### ${s.name}');
      if (s.trigger != null && s.trigger!.isNotEmpty) {
        buf.writeln('_When to apply: ${s.trigger}_');
      }
      buf.writeln('');
      buf.writeln(s.body.trimRight());
      buf.writeln('');
    }
    return buf.toString().trimRight();
  }

  /// Re-derive the in-memory skills under the cached workspace path.
  /// Used after the generator writes a new skill file.
  Future<void> refresh() => reload(_workspacePath);

  Future<List<WorkspaceSkill>> _walkDir(
    Directory dir, {
    required bool isWorkspaceLocal,
  }) async {
    if (!await dir.exists()) return const [];
    final results = <WorkspaceSkill>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final lower = entity.path.toLowerCase();
      if (!lower.endsWith('.md') && !lower.endsWith('.markdown')) continue;
      try {
        final content = await entity.readAsString();
        final skill = _parse(
          path: entity.path,
          content: content,
          isWorkspaceLocal: isWorkspaceLocal,
        );
        if (skill != null) results.add(skill);
      } catch (e) {
        debugPrint('SkillsService: skipped ${entity.path}: $e');
      }
    }
    return results;
  }

  /// Parse a single skill file. Tolerates missing / partial
  /// frontmatter; only an empty body causes us to drop the file.
  static WorkspaceSkill? _parse({
    required String path,
    required String content,
    required bool isWorkspaceLocal,
  }) {
    final defaultId = p
        .basenameWithoutExtension(path)
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_]+'), '_');
    String? id;
    String? name;
    String? trigger;
    bool defaultEnabled = true;
    String body = content;

    if (content.startsWith('---')) {
      final endIdx = content.indexOf('\n---', 3);
      if (endIdx > 0) {
        final fm = content.substring(3, endIdx).trim();
        body = content.substring(endIdx + 4).trimLeft();
        for (final raw in fm.split('\n')) {
          final line = raw.trim();
          if (line.isEmpty || line.startsWith('#')) continue;
          final colon = line.indexOf(':');
          if (colon < 0) continue;
          final key = line.substring(0, colon).trim().toLowerCase();
          final value = _stripQuotes(line.substring(colon + 1).trim());
          switch (key) {
            case 'id':
              id = value;
            case 'name':
              name = value;
            case 'trigger':
            case 'when':
            case 'when_to_apply':
              trigger = value;
            case 'enabled':
            case 'default_enabled':
            case 'defaultenabled':
              final lc = value.toLowerCase();
              defaultEnabled = !(lc == 'false' || lc == 'off' || lc == 'no');
          }
        }
      }
    }

    if (body.trim().isEmpty) return null;

    return WorkspaceSkill(
      id: (id == null || id.isEmpty) ? defaultId : id,
      name: (name == null || name.isEmpty)
          ? p.basenameWithoutExtension(path)
          : name,
      trigger: (trigger == null || trigger.isEmpty) ? null : trigger,
      defaultEnabled: defaultEnabled,
      body: body,
      filePath: path,
      isWorkspaceLocal: isWorkspaceLocal,
    );
  }

  static String _stripQuotes(String v) {
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return v.substring(1, v.length - 1);
      }
    }
    return v;
  }

  static Future<Directory> _globalSkillsDir() async {
    final base = await getApplicationSupportDirectory();
    return Directory(p.join(base.path, '.lumen', 'skills'));
  }

  /// Materialize the global skills dir without writing into it —
  /// used by the generator to drop new skill files.
  static Future<Directory> ensureGlobalDir() async {
    final dir = await _globalSkillsDir();
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }
}
