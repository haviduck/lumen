import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'lumen_workspace_config.dart';
import 'tool_registry.dart';

/// Discovers JSON tool definitions in the workspace and the global
/// app-support tools dir, and converts them into runtime [AgentTool]s.
///
/// JSON contract:
/// ```json
/// {
///   "id": "ripgrep",
///   "name": "RIPGREP",
///   "description": "Run ripgrep across the workspace.",
///   "syntax": "<<<RIPGREP: <pattern>>>>",
///   "pattern": "<<<RIPGREP:\\s*(.*?)\\s*>>>",
///   "command": ["rg", "--vimgrep", "$1"],
///   "requiresApproval": true,
///   "defaultEnabled": false
/// }
/// ```
///
/// Substitution: `$1`, `$2`, … in `command` segments are replaced with the
/// regex match groups before the command is launched.
///
/// Failure mode: any parse error on a single file is logged via
/// `debugPrint` and the file is skipped — the IDE never crashes because
/// of a malformed plugin.
class ExternalToolLoader {
  /// Walks `<workspace>/.lumen/tools/` and the global app-support tools
  /// dir; returns the runtime tools (built-in collisions are filtered by
  /// [ToolRegistry.replaceRuntime] downstream).
  Future<List<AgentTool>> loadAll({String? workspacePath}) async {
    final tools = <AgentTool>[];
    final seenIds = <String>{};

    final dirs = <Directory>[];
    if (workspacePath != null) {
      await LumenWorkspaceConfig.ensureDir(workspacePath);
      dirs.add(LumenWorkspaceConfig.toolsDir(workspacePath));
    }
    try {
      final support = await getApplicationSupportDirectory();
      dirs.add(Directory(p.join(support.path, 'tools')));
    } catch (e) {
      debugPrint('ExternalToolLoader: app-support tools dir unavailable: $e');
    }

    for (final dir in dirs) {
      if (!await dir.exists()) continue;
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list().toList();
      } catch (e) {
        debugPrint('ExternalToolLoader: scan failed for ${dir.path}: $e');
        continue;
      }
      for (final entry in entries) {
        if (entry is! File) continue;
        if (!entry.path.toLowerCase().endsWith('.json')) continue;
        final tool = await _loadFile(entry);
        if (tool == null) continue;
        if (!seenIds.add(tool.id)) {
          // Workspace dir is scanned first, so it wins over global on
          // collision — matches the "more local config wins" intuition
          // every other IDE has trained users to expect.
          debugPrint(
            'ExternalToolLoader: ignoring later definition of "${tool.id}" '
            'from ${entry.path} (already loaded).',
          );
          continue;
        }
        tools.add(tool);
      }
    }
    return tools;
  }

  Future<AgentTool?> _loadFile(File f) async {
    try {
      final raw = await f.readAsString();
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        debugPrint('External tool ${f.path}: top-level must be a JSON object.');
        return null;
      }
      _validate(decoded, f.path);
      return ToolRegistry.buildExternal(decoded);
    } catch (e) {
      debugPrint('External tool ${f.path}: $e');
      return null;
    }
  }

  void _validate(Map<String, dynamic> def, String path) {
    void require(String key) {
      if (def[key] == null || (def[key] is String && def[key] == '')) {
        throw FormatException('missing required field "$key"', path);
      }
    }

    require('id');
    require('pattern');
    require('command');
    final command = def['command'];
    if (command is! List || command.isEmpty) {
      throw FormatException('"command" must be a non-empty array', path);
    }
    for (final segment in command) {
      if (segment is! String) {
        throw FormatException('"command" entries must be strings', path);
      }
    }
    final id = def['id'];
    if (id is! String || id.isEmpty) {
      throw FormatException('"id" must be a non-empty string', path);
    }
    final patternStr = def['pattern'];
    if (patternStr is! String || patternStr.isEmpty) {
      throw FormatException('"pattern" must be a non-empty string', path);
    }
    try {
      RegExp(patternStr);
    } on FormatException {
      rethrow;
    } catch (e) {
      throw FormatException('invalid regex in "pattern": $e', path);
    }
  }
}
