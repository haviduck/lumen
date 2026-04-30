import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'snapshot_service.dart';

/// Definition of a single agent tool. The agent uses [syntaxExample] in
/// its system prompt and we parse the response with [pattern].
class AgentTool {
  final String id;
  final String name;
  final String description;
  final String syntaxExample;
  final RegExp pattern;
  final bool requiresApproval;
  final bool defaultEnabled;

  /// True when the tool came from a JSON file in the workspace or the global
  /// app-support tools dir. Used by the UI to badge the entry; the executor
  /// itself does not care.
  final bool isExternal;

  /// Returns the textual feedback for the LLM. The runner invokes this with
  /// a [ToolInvocation] that exposes workspace context, an [approver] for
  /// gated tools, and an [attachImage] side-channel for tools that want to
  /// hand binary content (base64 PNG/JPEG) into the next API turn.
  final Future<String> Function(ToolInvocation inv) execute;

  const AgentTool({
    required this.id,
    required this.name,
    required this.description,
    required this.syntaxExample,
    required this.pattern,
    required this.execute,
    this.requiresApproval = false,
    this.defaultEnabled = true,
    this.isExternal = false,
  });
}

class ToolInvocation {
  final RegExpMatch match;
  final String? workspaceDir;
  final Future<bool> Function(String label, String detail) approver;
  final bool allowWritesOutsideWorkspace;

  /// Side-channel for tools that produce image output (e.g. SNAPSHOT_URL).
  /// The base64-encoded PNG/JPEG ends up on the next user-feedback message
  /// so the multimodal model receives it on the next turn.
  final void Function(String base64) attachImage;

  /// Optional callback for live output from long-running tools. When set,
  /// the tool can push incremental chunks (stdout/stderr lines) as they
  /// arrive, so the UI shows progress in real time.
  final void Function(String chunk)? onOutput;

  ToolInvocation({
    required this.match,
    required this.workspaceDir,
    required this.approver,
    required this.attachImage,
    this.allowWritesOutsideWorkspace = false,
    this.onOutput,
  });
}

/// All tools available to the agent. Built-ins are declared statically;
/// runtime tools come from JSON files via [ExternalToolLoader].
///
/// Order matters for matching — most specific patterns are declared first
/// (e.g. CREATE_FILE before READ_FILE because both contain "_FILE").
class ToolRegistry {
  ToolRegistry._();

  static String? _resolvePath(
    ToolInvocation inv,
    String rawPath, {
    required bool forWrite,
  }) {
    final workspace = inv.workspaceDir;
    if (workspace == null) return null;
    final resolved = p.normalize(
      p.isAbsolute(rawPath) ? rawPath : p.join(workspace, rawPath),
    );
    if (!forWrite || inv.allowWritesOutsideWorkspace) return resolved;
    final root = p.normalize(workspace);
    if (p.equals(resolved, root) || p.isWithin(root, resolved)) {
      return resolved;
    }
    return null;
  }

  static String _outsideWorkspaceBlocked(String toolName, String path) {
    return '$toolName $path: Error: writing outside the active workspace is '
        'blocked by Settings → Rules → Allow agent writes outside workspace.';
  }

  static final List<AgentTool> _builtin = [
    AgentTool(
      id: 'create_file',
      name: 'CREATE_FILE',
      description: 'Create or overwrite a file with the given content.',
      syntaxExample:
          '<<<CREATE_FILE: filename.ext>>>\nfile contents go here\n<<<END_FILE>>>',
      pattern: RegExp(
        r'<<<CREATE_FILE:\s*(.*?)\s*>>>\n(.*?)\n?<<<END_FILE>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final content = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'CREATE_FILE $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('CREATE_FILE', fileName);
        }
        try {
          final f = File(filePath);
          await f.parent.create(recursive: true);
          await f.writeAsString(content);
          return 'CREATE_FILE $fileName: Success';
        } catch (e) {
          return 'CREATE_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'edit_file',
      name: 'EDIT_FILE',
      description:
          'Edit an existing file by replacing a specific text block with new '
          'content. Safer than CREATE_FILE for targeted edits because it '
          'preserves surrounding code. The SEARCH block must match the file '
          'exactly (including whitespace/indentation).',
      syntaxExample:
          '<<<EDIT_FILE: filename.ext>>>\n<<<SEARCH>>>\nexact text to find\n<<<REPLACE>>>\nreplacement text\n<<<END_EDIT>>>',
      pattern: RegExp(
        r'<<<EDIT_FILE:\s*(.*?)\s*>>>\n<<<SEARCH>>>\n(.*?)\n<<<REPLACE>>>\n(.*?)\n<<<END_EDIT>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final search = inv.match.group(2)!;
        final replace = inv.match.group(3)!;
        if (inv.workspaceDir == null) {
          return 'EDIT_FILE $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('EDIT_FILE', fileName);
        }
        try {
          final f = File(filePath);
          if (!await f.exists()) {
            return 'EDIT_FILE $fileName: Error: file does not exist.';
          }
          var content = await f.readAsString();
          if (!content.contains(search)) {
            // Try with normalized line endings in case of \r\n vs \n mismatch
            final normalizedContent = content.replaceAll('\r\n', '\n');
            final normalizedSearch = search.replaceAll('\r\n', '\n');
            if (normalizedContent.contains(normalizedSearch)) {
              content = normalizedContent;
              final result = content.replaceFirst(normalizedSearch, replace);
              await f.writeAsString(result);
              return 'EDIT_FILE $fileName: Success (1 replacement made)';
            }
            return 'EDIT_FILE $fileName: Error: SEARCH block not found in '
                'file. Make sure it matches exactly, including whitespace.';
          }
          final occurrences = RegExp(
            RegExp.escape(search),
          ).allMatches(content).length;
          final result = content.replaceFirst(search, replace);
          await f.writeAsString(result);
          return 'EDIT_FILE $fileName: Success (1 replacement made'
              '${occurrences > 1 ? ', $occurrences total occurrences — only first replaced' : ''})';
        } catch (e) {
          return 'EDIT_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'multi_edit',
      name: 'MULTI_EDIT',
      description:
          'Apply multiple find-replace edits to a single file in one atomic '
          'pass. All SEARCH blocks must match — if any one fails the file is '
          'left untouched (no partial writes). Use this instead of issuing '
          'several EDIT_FILE calls on the same file in one turn — fewer '
          'round trips, safer transactional semantics.',
      syntaxExample:
          '<<<MULTI_EDIT: filename.ext>>>\n<<<SEARCH>>>\nold text 1\n<<<REPLACE>>>\nnew text 1\n<<<NEXT>>>\n<<<SEARCH>>>\nold text 2\n<<<REPLACE>>>\nnew text 2\n<<<END_EDIT>>>',
      pattern: RegExp(
        r'<<<MULTI_EDIT:\s*(.+?)\s*>>>\n(.*?)\n?<<<END_EDIT>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final body = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'MULTI_EDIT $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('MULTI_EDIT', fileName);
        }
        try {
          final f = File(filePath);
          if (!await f.exists()) {
            return 'MULTI_EDIT $fileName: Error: file does not exist.';
          }
          // Split on `<<<NEXT>>>` separators; each chunk holds one
          // SEARCH/REPLACE pair.
          final chunks = body.split(RegExp(r'\n<<<NEXT>>>\n'));
          final edits = <({String search, String replace})>[];
          final chunkRe = RegExp(
            r'<<<SEARCH>>>\n(.*?)\n<<<REPLACE>>>\n(.*?)$',
            dotAll: true,
          );
          for (var i = 0; i < chunks.length; i++) {
            final m = chunkRe.firstMatch(chunks[i]);
            if (m == null) {
              return 'MULTI_EDIT $fileName: Error: chunk ${i + 1} malformed '
                  '(expected <<<SEARCH>>> ... <<<REPLACE>>> ...).';
            }
            edits.add((search: m.group(1)!, replace: m.group(2)!));
          }
          if (edits.isEmpty) {
            return 'MULTI_EDIT $fileName: Error: no SEARCH/REPLACE chunks '
                'found in body.';
          }
          // Atomic: apply all edits to an in-memory copy first;
          // only write back if every SEARCH found its match.
          var content = await f.readAsString();
          for (var i = 0; i < edits.length; i++) {
            final e = edits[i];
            if (content.contains(e.search)) {
              content = content.replaceFirst(e.search, e.replace);
              continue;
            }
            // \r\n vs \n fallback (same trick EDIT_FILE uses).
            final normalizedContent = content.replaceAll('\r\n', '\n');
            final normalizedSearch = e.search.replaceAll('\r\n', '\n');
            if (normalizedContent.contains(normalizedSearch)) {
              content = normalizedContent.replaceFirst(
                normalizedSearch,
                e.replace,
              );
              continue;
            }
            return 'MULTI_EDIT $fileName: Error: edit ${i + 1} SEARCH not '
                'found (file unchanged — no edits applied).';
          }
          await f.writeAsString(content);
          return 'MULTI_EDIT $fileName: Success (${edits.length} edits applied)';
        } catch (e) {
          return 'MULTI_EDIT $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'append_file',
      name: 'APPEND_FILE',
      description:
          'Append content to the end of an existing file. Creates the file if '
          'it does not exist. Useful for adding imports, entries, or log lines '
          'without reading the full file first.',
      syntaxExample:
          '<<<APPEND_FILE: filename.ext>>>\ncontent to append\n<<<END_APPEND>>>',
      pattern: RegExp(
        r'<<<APPEND_FILE:\s*(.*?)\s*>>>\n(.*?)\n?<<<END_APPEND>>>',
        dotAll: true,
      ),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final content = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'APPEND_FILE $fileName: Failed (no workspace open).';
        }
        final filePath = _resolvePath(inv, fileName, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('APPEND_FILE', fileName);
        }
        try {
          final f = File(filePath);
          await f.parent.create(recursive: true);
          await f.writeAsString(content, mode: FileMode.append);
          return 'APPEND_FILE $fileName: Success';
        } catch (e) {
          return 'APPEND_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'move_file',
      name: 'MOVE_FILE',
      description:
          'Move or rename a file or directory. Both paths are relative to '
          'the workspace; the destination parent directory is created if '
          'needed. Refuses if the destination already exists (use '
          'DELETE_FILE first if you really mean to clobber).',
      syntaxExample: '<<<MOVE_FILE: old/path.dart -> new/path.dart>>>',
      pattern: RegExp(r'<<<MOVE_FILE:\s*(.+?)\s*->\s*(.+?)\s*>>>'),
      execute: (inv) async {
        final src = inv.match.group(1)!;
        final dst = inv.match.group(2)!;
        if (inv.workspaceDir == null) {
          return 'MOVE_FILE $src -> $dst: Failed (no workspace open).';
        }
        final srcPath = _resolvePath(inv, src, forWrite: true);
        final dstPath = _resolvePath(inv, dst, forWrite: true);
        if (srcPath == null) {
          return _outsideWorkspaceBlocked('MOVE_FILE', src);
        }
        if (dstPath == null) {
          return _outsideWorkspaceBlocked('MOVE_FILE', dst);
        }
        try {
          final srcType = await FileSystemEntity.type(srcPath);
          if (srcType == FileSystemEntityType.notFound) {
            return 'MOVE_FILE $src -> $dst: Error: source does not exist.';
          }
          final dstType = await FileSystemEntity.type(dstPath);
          if (dstType != FileSystemEntityType.notFound) {
            return 'MOVE_FILE $src -> $dst: Error: destination already '
                'exists.';
          }
          await Directory(p.dirname(dstPath)).create(recursive: true);
          if (srcType == FileSystemEntityType.directory) {
            await Directory(srcPath).rename(dstPath);
            return 'MOVE_FILE $src -> $dst: Success (directory moved)';
          }
          await File(srcPath).rename(dstPath);
          return 'MOVE_FILE $src -> $dst: Success';
        } catch (e) {
          return 'MOVE_FILE $src -> $dst: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'read_file_range',
      name: 'READ_FILE_RANGE',
      description:
          'Read a 1-based inclusive line range from a file. Use this '
          'instead of READ_FILE when you only need a slice of a large file '
          '— saves your context window. Output is line-numbered. START/END '
          'are clamped to the file length, so 1-99999 reads the whole '
          'file safely. NOTE: declared above READ_FILE in the registry so '
          'the more-specific pattern wins on `<<<READ_FILE_RANGE: ...>>>`.',
      syntaxExample: '<<<READ_FILE_RANGE: filename.ext:10-50>>>',
      pattern: RegExp(r'<<<READ_FILE_RANGE:\s*(.+?):(\d+)-(\d+)\s*>>>'),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        final start = int.parse(inv.match.group(2)!);
        final end = int.parse(inv.match.group(3)!);
        if (inv.workspaceDir == null) {
          return 'READ_FILE_RANGE $fileName: Failed (no workspace open).';
        }
        if (start < 1 || end < start) {
          return 'READ_FILE_RANGE $fileName: Error: invalid range '
              '$start-$end.';
        }
        try {
          final filePath = _resolvePath(inv, fileName, forWrite: false);
          if (filePath == null) {
            return 'READ_FILE_RANGE $fileName: Failed (no workspace open).';
          }
          final lines = await File(filePath).readAsLines();
          final fromIdx = (start - 1).clamp(0, lines.length);
          final toIdx = end.clamp(0, lines.length);
          if (fromIdx >= toIdx) {
            return 'READ_FILE_RANGE $fileName: Empty (file has '
                '${lines.length} lines).';
          }
          final slice = lines.sublist(fromIdx, toIdx);
          final numbered = <String>[];
          for (var i = 0; i < slice.length; i++) {
            numbered.add(
              '${(fromIdx + i + 1).toString().padLeft(5)}|${slice[i]}',
            );
          }
          return 'READ_FILE_RANGE $fileName lines $start-$end '
              '(of ${lines.length}):\n${numbered.join('\n')}';
        } catch (e) {
          return 'READ_FILE_RANGE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'read_file',
      name: 'READ_FILE',
      description:
          'Read the contents of a file relative to the workspace. '
          'For files >300 lines prefer READ_FILE_RANGE.',
      syntaxExample: '<<<READ_FILE: filename.ext>>>',
      pattern: RegExp(r'<<<READ_FILE:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final fileName = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'READ_FILE $fileName: Failed (no workspace open).';
        }
        try {
          final filePath = _resolvePath(inv, fileName, forWrite: false);
          if (filePath == null) {
            return 'READ_FILE $fileName: Failed (no workspace open).';
          }
          final c = await File(filePath).readAsString();
          return 'READ_FILE $fileName:\n$c';
        } catch (e) {
          return 'READ_FILE $fileName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'list_dir',
      name: 'LIST_DIR',
      description:
          'List entries in a directory relative to the workspace. Shows file '
          'sizes and marks directories with [DIR].',
      syntaxExample: '<<<LIST_DIR: path/to/dir>>>',
      pattern: RegExp(r'<<<LIST_DIR:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        var dirName = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'LIST_DIR $dirName: Failed (no workspace open).';
        }
        if (dirName == '.' || dirName.isEmpty) dirName = '';
        final dirPath = dirName.isEmpty
            ? inv.workspaceDir!
            : p.join(inv.workspaceDir!, dirName);
        try {
          final entries = await Directory(dirPath).list().toList();
          entries.sort((a, b) {
            final aDir = a is Directory;
            final bDir = b is Directory;
            if (aDir != bDir) return aDir ? -1 : 1;
            return p
                .basename(a.path)
                .toLowerCase()
                .compareTo(p.basename(b.path).toLowerCase());
          });
          final lines = <String>[];
          for (final e in entries) {
            final name = p.basename(e.path);
            if (e is Directory) {
              lines.add('[DIR]  $name/');
            } else if (e is File) {
              try {
                final stat = await e.stat();
                lines.add('       $name  (${_humanSize(stat.size)})');
              } catch (_) {
                lines.add('       $name');
              }
            }
          }
          return 'LIST_DIR ${dirName.isEmpty ? '.' : dirName}:\n${lines.join('\n')}';
        } catch (e) {
          return 'LIST_DIR $dirName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'tree',
      name: 'TREE',
      description:
          'Show the recursive directory tree for a path. Respects common '
          'ignore patterns (node_modules, .git, build, etc). Optional depth '
          'limit defaults to 3. Use to understand project structure quickly.',
      syntaxExample: '<<<TREE: path/to/dir>>>',
      pattern: RegExp(r'<<<TREE:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        var dirName = inv.match.group(1)!.trim();
        if (inv.workspaceDir == null) {
          return 'TREE $dirName: Failed (no workspace open).';
        }
        if (dirName == '.' || dirName.isEmpty) dirName = '';
        final dirPath = dirName.isEmpty
            ? inv.workspaceDir!
            : p.join(inv.workspaceDir!, dirName);
        try {
          final buf = StringBuffer();
          var count = 0;
          const maxEntries = 500;
          const maxDepth = 4;

          Future<void> walk(Directory dir, String prefix, int depth) async {
            if (depth > maxDepth || count >= maxEntries) return;
            final entries = await dir.list().toList();
            entries.sort((a, b) {
              final aDir = a is Directory;
              final bDir = b is Directory;
              if (aDir != bDir) return aDir ? -1 : 1;
              return p
                  .basename(a.path)
                  .toLowerCase()
                  .compareTo(p.basename(b.path).toLowerCase());
            });
            for (var i = 0; i < entries.length && count < maxEntries; i++) {
              final e = entries[i];
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              final isLast = i == entries.length - 1;
              final connector = isLast ? '└── ' : '├── ';
              final childPrefix = isLast ? '    ' : '│   ';
              if (e is Directory) {
                buf.writeln('$prefix$connector$name/');
                count++;
                await walk(e, '$prefix$childPrefix', depth + 1);
              } else {
                buf.writeln('$prefix$connector$name');
                count++;
              }
            }
          }

          buf.writeln(dirName.isEmpty ? '.' : dirName);
          count++;
          await walk(Directory(dirPath), '', 0);
          if (count >= maxEntries) {
            buf.writeln('... (truncated at $maxEntries entries)');
          }
          return 'TREE ${dirName.isEmpty ? '.' : dirName}:\n${buf.toString().trimRight()}';
        } catch (e) {
          return 'TREE $dirName: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'search_text',
      name: 'SEARCH_TEXT',
      description:
          'Search for a text pattern across all files in the workspace (or a '
          'subdirectory). Returns matching lines with file paths and line '
          'numbers. Skips binary files and common ignore dirs. Case-insensitive '
          'by default.',
      syntaxExample: '<<<SEARCH_TEXT: search pattern>>>',
      pattern: RegExp(r'<<<SEARCH_TEXT:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final query = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'SEARCH_TEXT $query: Failed (no workspace open).';
        }
        try {
          final results = <String>[];
          final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
          var fileCount = 0;
          var matchCount = 0;
          const maxMatches = 100;

          Future<void> walkDir(Directory dir) async {
            if (matchCount >= maxMatches) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (matchCount >= maxMatches) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                await walkDir(e);
              } else if (e is File) {
                final ext = p.extension(name).toLowerCase();
                if (_binaryExts.contains(ext)) continue;
                try {
                  final stat = await e.stat();
                  if (stat.size > 2 * 1024 * 1024) continue;
                } catch (_) {
                  continue;
                }
                String content;
                try {
                  content = await e.readAsString();
                } catch (_) {
                  continue;
                }
                final lines = content.split('\n');
                var foundInFile = false;
                for (
                  var i = 0;
                  i < lines.length && matchCount < maxMatches;
                  i++
                ) {
                  if (pattern.hasMatch(lines[i])) {
                    if (!foundInFile) {
                      final rel = p.relative(e.path, from: inv.workspaceDir!);
                      results.add('\n$rel:');
                      foundInFile = true;
                      fileCount++;
                    }
                    matchCount++;
                    results.add('  ${i + 1}: ${lines[i].trimRight()}');
                  }
                }
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          if (results.isEmpty) {
            return 'SEARCH_TEXT "$query": No matches found.';
          }
          final truncNote = matchCount >= maxMatches
              ? '\n... (truncated at $maxMatches matches)'
              : '';
          return 'SEARCH_TEXT "$query": $matchCount matches in $fileCount files'
              '${results.join('\n')}$truncNote';
        } catch (e) {
          return 'SEARCH_TEXT $query: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'find_file',
      name: 'FIND_FILE',
      description:
          'Find files by name pattern (substring match, case-insensitive). '
          'Returns relative paths. Use to locate files when you do not know '
          'the exact path.',
      syntaxExample: '<<<FIND_FILE: partial_name>>>',
      pattern: RegExp(r'<<<FIND_FILE:\s*(.*?)\s*>>>'),
      execute: (inv) async {
        final query = inv.match.group(1)!.toLowerCase();
        if (inv.workspaceDir == null) {
          return 'FIND_FILE $query: Failed (no workspace open).';
        }
        try {
          final results = <String>[];
          const maxResults = 50;

          Future<void> walkDir(Directory dir) async {
            if (results.length >= maxResults) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (results.length >= maxResults) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                if (name.toLowerCase().contains(query)) {
                  results.add(
                    '${p.relative(e.path, from: inv.workspaceDir!)}/  [DIR]',
                  );
                }
                await walkDir(e);
              } else {
                if (name.toLowerCase().contains(query)) {
                  results.add(p.relative(e.path, from: inv.workspaceDir!));
                }
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          if (results.isEmpty) {
            return 'FIND_FILE "$query": No matching files found.';
          }
          return 'FIND_FILE "$query": ${results.length} result(s)\n${results.join('\n')}';
        } catch (e) {
          return 'FIND_FILE $query: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'glob',
      name: 'GLOB',
      description:
          'Find files matching a glob pattern. More powerful than FIND_FILE '
          '(which only does substring). Patterns are relative to the '
          'workspace: `**` matches any depth, `*` matches one path '
          'segment, `?` matches a single character. Examples: '
          '`lib/**/*.dart`, `test/*_test.dart`, `**/Dockerfile`. Returns '
          'workspace-relative paths sorted alphabetically.',
      syntaxExample: '<<<GLOB: lib/**/*.dart>>>',
      pattern: RegExp(r'<<<GLOB:\s*(.+?)\s*>>>'),
      execute: (inv) async {
        final pat = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'GLOB $pat: Failed (no workspace open).';
        }
        final regex = _globToRegExp(pat);
        try {
          final results = <String>[];
          const maxResults = 200;

          Future<void> walkDir(Directory dir) async {
            if (results.length >= maxResults) return;
            List<FileSystemEntity> entries;
            try {
              entries = await dir.list().toList();
            } catch (_) {
              return;
            }
            for (final e in entries) {
              if (results.length >= maxResults) break;
              final name = p.basename(e.path);
              if (_treeIgnore.contains(name)) continue;
              if (e is Directory) {
                await walkDir(e);
              } else if (e is File) {
                // Forward-slash normalised so glob patterns work
                // identically on Windows and Unix paths.
                final rel = p
                    .relative(e.path, from: inv.workspaceDir!)
                    .replaceAll(r'\', '/');
                if (regex.hasMatch(rel)) results.add(rel);
              }
            }
          }

          await walkDir(Directory(inv.workspaceDir!));
          results.sort();
          if (results.isEmpty) return 'GLOB "$pat": No matches.';
          final cap = results.length >= maxResults
              ? '\n... (truncated at $maxResults)'
              : '';
          return 'GLOB "$pat": ${results.length} match(es)\n'
              '${results.join('\n')}$cap';
        } catch (e) {
          return 'GLOB $pat: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'delete_file',
      name: 'DELETE_FILE',
      description: 'Delete a file or empty directory. Requires user approval.',
      syntaxExample: '<<<DELETE_FILE: path/to/file>>>',
      pattern: RegExp(r'<<<DELETE_FILE:\s*(.*?)\s*>>>'),
      requiresApproval: true,
      execute: (inv) async {
        final target = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'DELETE_FILE $target: Failed (no workspace open).';
        }
        final approved = await inv.approver('DELETE_FILE', target);
        if (!approved) {
          return 'DELETE_FILE $target: Denied by user.';
        }
        final filePath = _resolvePath(inv, target, forWrite: true);
        if (filePath == null) {
          return _outsideWorkspaceBlocked('DELETE_FILE', target);
        }
        try {
          final type = await FileSystemEntity.type(filePath);
          if (type == FileSystemEntityType.file) {
            await File(filePath).delete();
            return 'DELETE_FILE $target: Success (file deleted)';
          } else if (type == FileSystemEntityType.directory) {
            await Directory(filePath).delete(recursive: false);
            return 'DELETE_FILE $target: Success (empty directory deleted)';
          }
          return 'DELETE_FILE $target: Error: path does not exist.';
        } catch (e) {
          return 'DELETE_FILE $target: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_status',
      name: 'GIT_STATUS',
      description:
          'Show `git status` (porcelain + branch) for the workspace. Lists '
          'modified, staged, untracked, and deleted files. Use this before '
          'making changes to understand the working-tree baseline; use it '
          'after to confirm what your edits touched.',
      syntaxExample: '<<<GIT_STATUS>>>',
      pattern: RegExp(r'<<<GIT_STATUS>>>'),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_STATUS: Failed (no workspace open).';
        }
        try {
          final r = await Process.run(
            'git',
            ['status', '--porcelain', '--branch'],
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_STATUS: Error: '
                '${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = r.stdout.toString().trim();
          if (out.isEmpty) return 'GIT_STATUS: clean (no changes).';
          return 'GIT_STATUS:\n$out';
        } on ProcessException catch (e) {
          return 'GIT_STATUS: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_STATUS: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'git_diff',
      name: 'GIT_DIFF',
      description:
          'Show `git diff` for the workspace (unstaged changes). Pass an '
          'optional path to limit the diff to a specific file or '
          'directory. Output is truncated at 64KB if larger — use a '
          'narrower path argument if you need more detail.',
      syntaxExample: '<<<GIT_DIFF>>>  or  <<<GIT_DIFF: lib/widgets/foo.dart>>>',
      pattern: RegExp(r'<<<GIT_DIFF(?::\s*(.+?))?\s*>>>'),
      execute: (inv) async {
        if (inv.workspaceDir == null) {
          return 'GIT_DIFF: Failed (no workspace open).';
        }
        final pathArg = inv.match.group(1)?.trim() ?? '';
        try {
          final args = ['diff'];
          if (pathArg.isNotEmpty) args.addAll(['--', pathArg]);
          final r = await Process.run(
            'git',
            args,
            workingDirectory: inv.workspaceDir,
            runInShell: false,
          );
          if (r.exitCode != 0) {
            final err = r.stderr.toString().trim();
            return 'GIT_DIFF${pathArg.isEmpty ? '' : ' $pathArg'}: '
                'Error: ${err.isEmpty ? "exit ${r.exitCode}" : err}';
          }
          final out = _cap(r.stdout.toString());
          if (out.trim().isEmpty) {
            return 'GIT_DIFF${pathArg.isEmpty ? '' : ' $pathArg'}: '
                'no changes.';
          }
          return 'GIT_DIFF${pathArg.isEmpty ? '' : ' $pathArg'}:\n$out';
        } on ProcessException catch (e) {
          return 'GIT_DIFF: git not available: ${e.message}';
        } catch (e) {
          return 'GIT_DIFF: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'run_cmd',
      name: 'RUN_CMD',
      description:
          'Run a shell command in the workspace. Requires user approval (unless auto-approve is on).',
      syntaxExample: '<<<RUN_CMD: command to run>>>',
      pattern: RegExp(r'<<<RUN_CMD:\s*(.*?)\s*>>>'),
      requiresApproval: true,
      execute: (inv) async {
        final cmd = inv.match.group(1)!;
        if (inv.workspaceDir == null) {
          return 'RUN_CMD $cmd: Failed (no workspace open).';
        }
        final approved = await inv.approver('RUN_CMD', cmd);
        if (!approved) {
          return 'RUN_CMD $cmd: Denied by user.';
        }
        try {
          // Use Process.start for live streaming output instead of
          // Process.run which blocks until the command finishes.
          final process = await Process.start(
            Platform.isWindows ? 'cmd.exe' : 'bash',
            Platform.isWindows ? ['/c', cmd] : ['-c', cmd],
            workingDirectory: inv.workspaceDir,
          );

          final stdoutBuf = StringBuffer();
          final stderrBuf = StringBuffer();

          // Stream stdout to the live output callback.
          final stdoutDone = process.stdout
              .transform(const SystemEncoding().decoder)
              .listen((chunk) {
                stdoutBuf.write(chunk);
                inv.onOutput?.call(chunk);
              })
              .asFuture();

          // Stream stderr to the live output callback.
          final stderrDone = process.stderr
              .transform(const SystemEncoding().decoder)
              .listen((chunk) {
                stderrBuf.write(chunk);
                inv.onOutput?.call(chunk);
              })
              .asFuture();

          // Wait for both streams to finish, then the exit code.
          await Future.wait([stdoutDone, stderrDone]);
          await process.exitCode;

          final stdout = _cap(stdoutBuf.toString());
          final stderr = _cap(stderrBuf.toString());
          return 'RUN_CMD $cmd:\nSTDOUT:\n$stdout\nSTDERR:\n$stderr';
        } catch (e) {
          return 'RUN_CMD $cmd: Error: $e';
        }
      },
    ),
    AgentTool(
      id: 'snapshot_url',
      name: 'SNAPSHOT_URL',
      description:
          'Capture a screenshot of a URL via the in-process WebView2 and feed '
          'the PNG back as an image on the next turn.',
      syntaxExample: '<<<SNAPSHOT_URL: https://example.com>>>',
      pattern: RegExp(r'<<<SNAPSHOT_URL:\s*(.*?)\s*>>>'),
      defaultEnabled: false,
      execute: (inv) async {
        final url = inv.match.group(1)!;
        final result = await SnapshotService.instance.capture(url);
        if (result.ok && result.base64Png != null) {
          inv.attachImage(result.base64Png!);
          final extra = result.savedPath != null
              ? ' Saved a debug copy to ${result.savedPath}.'
              : '';
          return 'SNAPSHOT_URL $url: ${result.message}$extra '
              'The PNG is attached to this message — read it directly.';
        }
        return 'SNAPSHOT_URL $url: Failed — ${result.message}';
      },
    ),
  ];

  /// Directories/files never descended into by TREE, SEARCH_TEXT, FIND_FILE.
  static const _treeIgnore = <String>{
    'node_modules',
    '.git',
    '.dart_tool',
    'build',
    'dist',
    'out',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.turbo',
    '.cache',
    '.parcel-cache',
    '.idea',
    '.vscode',
    '.vscode-test',
    'venv',
    '.venv',
    'env',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    '.tox',
    'target',
    'Pods',
    '.gradle',
    '.expo',
    '.expo-shared',
    '.flutter-plugins',
    '.flutter-plugins-dependencies',
    'coverage',
    '.lumen',
    '.duckoff',
  };

  /// Binary extensions skipped by SEARCH_TEXT.
  static const _binaryExts = <String>{
    '.png',
    '.jpg',
    '.jpeg',
    '.gif',
    '.bmp',
    '.webp',
    '.ico',
    '.svg',
    '.mp3',
    '.wav',
    '.ogg',
    '.flac',
    '.mp4',
    '.mov',
    '.avi',
    '.mkv',
    '.zip',
    '.tar',
    '.gz',
    '.7z',
    '.rar',
    '.bz2',
    '.xz',
    '.exe',
    '.dll',
    '.so',
    '.dylib',
    '.bin',
    '.iso',
    '.pdf',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    '.ppt',
    '.pptx',
    '.ttf',
    '.otf',
    '.woff',
    '.woff2',
    '.eot',
    '.class',
    '.jar',
    '.pyc',
    '.pyo',
    '.o',
    '.obj',
    '.lib',
    '.a',
    '.lock',
  };

  /// Human-readable file size for LIST_DIR output.
  static String _humanSize(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  /// Convert a glob pattern into an anchored `RegExp`. Supports the
  /// three operators agents actually use:
  /// - `**`  : any sequence of segments (including `/`).
  /// - `*`   : any chars within one path segment (no `/`).
  /// - `?`   : exactly one non-`/` character.
  ///
  /// `**/` and `**` are both treated as "any depth"; trailing `/` after
  /// `**` is consumed so `lib/**/*.dart` matches `lib/foo.dart` AND
  /// `lib/a/b/c.dart`. Other regex metacharacters in the input are
  /// escaped — patterns are interpreted as literal text outside the
  /// glob operators above.
  ///
  /// We don't pull in `package:glob` because (a) we only need ~20
  /// lines of converter and (b) the pubspec is already noisy enough.
  static RegExp _globToRegExp(String glob) {
    final buf = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          // ** — consume the second star plus any immediately
          // following `/` so `lib/**/*.dart` matches paths with
          // zero, one, or many intermediate directories.
          i++;
          if (i + 1 < glob.length && glob[i + 1] == '/') i++;
          buf.write('(?:.*)?');
        } else {
          buf.write('[^/]*');
        }
      } else if (c == '?') {
        buf.write('[^/]');
      } else if ('.+()|^\$\\{}[]'.contains(c)) {
        buf.write(r'\');
        buf.write(c);
      } else {
        buf.write(c);
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }

  /// Tools loaded at runtime from disk. Mutable; replaced wholesale by
  /// [replaceRuntime] when the workspace changes.
  static final List<AgentTool> _runtime = [];

  static List<AgentTool> get all =>
      List.unmodifiable([..._builtin, ..._runtime]);

  static List<AgentTool> get builtin => List.unmodifiable(_builtin);

  static List<AgentTool> get runtime => List.unmodifiable(_runtime);

  static AgentTool? byId(String id) {
    for (final t in _builtin) {
      if (t.id == id) return t;
    }
    for (final t in _runtime) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Drop existing runtime tools and replace with [tools]. Any [tools] entry
  /// whose id collides with a built-in is rejected (built-ins always win)
  /// and logged. Duplicate ids within [tools] keep the first occurrence.
  static void replaceRuntime(List<AgentTool> tools) {
    _runtime.clear();
    final seen = <String>{};
    for (final t in tools) {
      if (_builtin.any((b) => b.id == t.id)) {
        debugPrint(
          'External tool "${t.id}" rejected: collides with built-in tool.',
        );
        continue;
      }
      if (!seen.add(t.id)) {
        debugPrint('External tool "${t.id}" rejected: duplicate id.');
        continue;
      }
      _runtime.add(t);
    }
  }

  static void clearRuntime() {
    _runtime.clear();
  }

  /// Internal helper used by [ExternalToolLoader] so it can spawn child
  /// processes through a single hardened path that mirrors RUN_CMD's
  /// quoting/IO handling. Lives here to keep the loader free of platform
  /// special-cases.
  static Future<String> runExternalCommand({
    required String name,
    required List<String> command,
    required String firstArg,
    required ToolInvocation inv,
  }) async {
    if (inv.workspaceDir == null) {
      return '$name $firstArg: Failed (no workspace open).';
    }
    try {
      final ProcessResult res;
      if (Platform.isWindows) {
        // flutter_pty quoting issues are PTY-only; Process.run uses
        // CreateProcess with proper escaping. Wrapping through cmd.exe /c
        // preserves the user's command exactly as authored, including
        // pipes/redirects in the JSON definition.
        final joined = command.map((s) => _quoteForCmd(s)).join(' ');
        res = await Process.run('cmd.exe', [
          '/c',
          joined,
        ], workingDirectory: inv.workspaceDir);
      } else {
        res = await Process.run(
          command.first,
          command.skip(1).toList(),
          workingDirectory: inv.workspaceDir,
        );
      }
      final stdout = _cap(res.stdout?.toString() ?? '');
      final stderr = _cap(res.stderr?.toString() ?? '');
      return '$name $firstArg:\nSTDOUT:\n$stdout\nSTDERR:\n$stderr';
    } catch (e) {
      return '$name $firstArg: Error: $e';
    }
  }

  /// 64KB cap mirrors what most chat UIs can actually display before
  /// turning into glue. Anything longer is almost certainly noise.
  static String _cap(String s) {
    const max = 64 * 1024;
    if (s.length <= max) return s;
    return '${s.substring(0, max)}\n… (truncated)';
  }

  static String _quoteForCmd(String s) {
    if (s.isEmpty) return '""';
    if (RegExp(r'[\s"&|<>^]').hasMatch(s)) {
      return '"${s.replaceAll('"', '\\"')}"';
    }
    return s;
  }

  /// Used in unit tests to round-trip JSON definitions without disk IO.
  /// Public so [ExternalToolLoader] (in its own file) can call it.
  static AgentTool buildExternal(Map<String, dynamic> def) {
    final id = def['id'] as String;
    final name = (def['name'] as String?) ?? id.toUpperCase();
    final description = (def['description'] as String?) ?? '';
    final syntax = (def['syntax'] as String?) ?? '<<<$name: ...>>>';
    final patternStr = def['pattern'] as String;
    final commandRaw = def['command'] as List<dynamic>;
    final command = commandRaw.cast<String>();
    final requiresApproval = def['requiresApproval'] == true;
    final defaultEnabled = def['defaultEnabled'] == true;
    final pattern = RegExp(patternStr, dotAll: true);

    return AgentTool(
      id: id,
      name: name,
      description: description,
      syntaxExample: syntax,
      pattern: pattern,
      requiresApproval: requiresApproval,
      defaultEnabled: defaultEnabled,
      isExternal: true,
      execute: (inv) async {
        final firstArg = inv.match.groupCount >= 1
            ? (inv.match.group(1) ?? '')
            : '';
        if (requiresApproval) {
          final ok = await inv.approver(name, firstArg);
          if (!ok) return '$name $firstArg: Denied by user.';
        }
        final substituted = command
            .map((segment) => _substituteGroups(segment, inv.match))
            .toList();
        return runExternalCommand(
          name: name,
          command: substituted,
          firstArg: firstArg,
          inv: inv,
        );
      },
    );
  }

  static String _substituteGroups(String segment, RegExpMatch m) {
    return segment.replaceAllMapped(RegExp(r'\$(\d+)'), (g) {
      final i = int.parse(g.group(1)!);
      if (i < 0 || i > m.groupCount) return g.group(0)!;
      return m.group(i) ?? '';
    });
  }
}

/// Convenience: encode a `Map<String, dynamic>` of a tool definition the
/// same way the loader does. Handy for tests.
String encodeToolDefinition(Map<String, dynamic> def) => jsonEncode(def);
