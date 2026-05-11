/// Cross-session memory persistence for the AI chat agent.
///
/// Mem0-inspired "user memory" layer: facts the agent learns during a
/// session (user preferences, codebase patterns, past decisions) are
/// persisted to a plain markdown file so future sessions start warm
/// instead of cold.
///
/// Two scopes:
///   - **Workspace memory** (`<workspace>/.lumen/memory.md`) — facts
///     about THIS project (architecture, conventions, deployment targets).
///   - **Global memory** (`<appSupport>/agent_memory/global.md`) — facts
///     about the USER that apply across all workspaces (preferred
///     languages, coding style, tool preferences).
///
/// Both are plain markdown the user can inspect, edit, and
/// version-control. The agent reads them at the top of the system prompt
/// and writes to them via the `SAVE_MEMORY` tool.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Which scope a memory entry targets.
enum MemoryScope { workspace, global }

class MemoryService {
  Directory? _globalRoot;

  /// Cap on the memory file size injected into the system prompt.
  /// Past this we'd be defeating the purpose — memory is supposed
  /// to SAVE context budget, not consume it. When the file exceeds
  /// this, the agent should be told to consolidate/prune.
  static const int maxInjectChars = 3000;

  Future<Directory> _ensureGlobalRoot() async {
    if (_globalRoot != null) return _globalRoot!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'agent_memory'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _globalRoot = dir;
    return dir;
  }

  File _workspaceFile(String workspacePath) =>
      File(p.join(workspacePath, '.lumen', 'memory.md'));

  Future<File> _globalFile() async {
    final root = await _ensureGlobalRoot();
    return File(p.join(root.path, 'global.md'));
  }

  /// Load memory from both scopes, merged. Returns empty string when
  /// no memory exists. Each scope is labelled so the agent can tell
  /// them apart.
  Future<String> load({String? workspacePath}) async {
    final buf = StringBuffer();

    // Workspace memory
    if (workspacePath != null) {
      final wsContent = await _readFile(_workspaceFile(workspacePath));
      if (wsContent.isNotEmpty) {
        buf.writeln('### Project memory');
        buf.writeln(wsContent.length > maxInjectChars
            ? '${wsContent.substring(0, maxInjectChars)}\n(… truncated — '
                'memory file is ${wsContent.length} chars, cap is '
                '$maxInjectChars. Consolidate with SAVE_MEMORY scope=workspace '
                'replace=true.)'
            : wsContent);
      }
    }

    // Global memory
    final globalContent = await _readFile(await _globalFile());
    if (globalContent.isNotEmpty) {
      if (buf.isNotEmpty) buf.writeln();
      buf.writeln('### User memory (global)');
      buf.writeln(globalContent.length > maxInjectChars
          ? '${globalContent.substring(0, maxInjectChars)}\n(… truncated — '
              'memory file is ${globalContent.length} chars, cap is '
              '$maxInjectChars. Consolidate with SAVE_MEMORY scope=global '
              'replace=true.)'
          : globalContent);
    }

    return buf.toString().trimRight();
  }

  /// Append a fact to the specified scope. When [replace] is true the
  /// entire file is overwritten (used for consolidation/pruning).
  Future<String> save({
    required String fact,
    required MemoryScope scope,
    String? workspacePath,
    bool replace = false,
  }) async {
    final File target;
    if (scope == MemoryScope.workspace) {
      if (workspacePath == null) {
        return 'SAVE_MEMORY: Failed — no workspace open, cannot write '
            'workspace memory. Use scope=global instead.';
      }
      target = _workspaceFile(workspacePath);
    } else {
      target = await _globalFile();
    }

    try {
      final dir = target.parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      if (replace) {
        await target.writeAsString(fact);
        return 'SAVE_MEMORY: Replaced ${scope.name} memory '
            '(${fact.length} chars).';
      }

      final exists = await target.exists();
      final buf = StringBuffer();
      if (!exists) {
        buf.writeln('<!-- Agent memory — edit freely, the agent reads '
            'this on every turn. -->');
        buf.writeln();
      }
      buf.writeln('- $fact');
      await target.writeAsString(buf.toString(), mode: FileMode.append);
      return 'SAVE_MEMORY: Appended to ${scope.name} memory.';
    } catch (e) {
      debugPrint('MemoryService.save failed: $e');
      return 'SAVE_MEMORY: Error — $e';
    }
  }

  Future<String> _readFile(File f) async {
    try {
      if (!await f.exists()) return '';
      return (await f.readAsString()).trim();
    } catch (e) {
      debugPrint('MemoryService._readFile failed: $e');
      return '';
    }
  }
}
