import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Patterns that we never want to surface in Quick Open or Global Search.
/// Mirrors the backup hard-ignore set so the IDE feels consistent.
const _hardIgnore = <String>{
  'node_modules', '.git', '.dart_tool', 'build', 'dist', 'out',
  '.next', '.nuxt', '.svelte-kit', '.turbo', '.cache', '.parcel-cache',
  '.idea', '.vscode-test', 'venv', '.venv', 'env', '__pycache__',
  '.pytest_cache', '.mypy_cache', '.tox', 'target', 'Pods',
  '.gradle', '.expo', '.expo-shared',
  '.flutter-plugins', '.flutter-plugins-dependencies', 'coverage',
};

/// Files larger than this are skipped by global search to keep the UI snappy.
/// 2 MiB covers virtually every source file; lockfiles & generated bundles
/// are excluded by extension above.
const int _maxSearchFileSize = 2 * 1024 * 1024;

/// File extensions that are almost always binary or generated and shouldn't
/// be returned by quick-open or global-search even though they live in the
/// repo. We compare the lowercased extension including the dot.
const _binaryExtensions = <String>{
  '.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.ico', '.svg',
  '.mp3', '.wav', '.ogg', '.flac', '.mp4', '.mov', '.avi', '.mkv',
  '.zip', '.tar', '.gz', '.7z', '.rar', '.bz2', '.xz',
  '.exe', '.dll', '.so', '.dylib', '.bin', '.iso',
  '.pdf', '.doc', '.docx', '.xls', '.xlsx', '.ppt', '.pptx',
  '.ttf', '.otf', '.woff', '.woff2', '.eot',
  '.class', '.jar', '.pyc', '.pyo', '.o', '.obj', '.lib', '.a',
};

class FileEntry {
  final String absolutePath;
  final String relativePath;
  final String name;
  FileEntry({
    required this.absolutePath,
    required this.relativePath,
    required this.name,
  });
}

/// Walks the workspace once and caches the result for fast follow-up
/// searches. The walk is cancellable via [CancellationToken]-style flags
/// kept on the index instance so callers can short-circuit.
class FileIndex {
  final String workspacePath;
  final List<FileEntry> _entries = [];
  bool _ready = false;
  bool _building = false;
  Future<void>? _buildFuture;

  FileIndex(this.workspacePath);

  bool get isReady => _ready;
  bool get isBuilding => _building;
  List<FileEntry> get entries => List.unmodifiable(_entries);

  /// Builds (or rebuilds) the index. Multiple concurrent calls share the
  /// same future to avoid duplicate walks.
  Future<void> build() {
    if (_buildFuture != null) return _buildFuture!;
    _buildFuture = _buildInternal().whenComplete(() {
      _buildFuture = null;
    });
    return _buildFuture!;
  }

  Future<void> _buildInternal() async {
    _building = true;
    _ready = false;
    _entries.clear();
    try {
      final root = Directory(workspacePath);
      if (!await root.exists()) return;
      await for (final entity
          in root.list(recursive: true, followLinks: false)) {
        final rel = p
            .relative(entity.path, from: workspacePath)
            .replaceAll(r'\', '/');
        if (_isIgnored(rel)) continue;
        if (entity is File) {
          _entries.add(FileEntry(
            absolutePath: entity.path,
            relativePath: rel,
            name: p.basename(entity.path),
          ));
        }
      }
      _entries.sort((a, b) => a.relativePath
          .toLowerCase()
          .compareTo(b.relativePath.toLowerCase()));
      _ready = true;
    } finally {
      _building = false;
    }
  }

  bool _isIgnored(String relPath) {
    for (final seg in relPath.split('/')) {
      if (_hardIgnore.contains(seg)) return true;
    }
    return false;
  }

  /// Fuzzy search that ranks entries by:
  /// 1. exact substring in name (highest)
  /// 2. exact substring in relative path
  /// 3. characters appear in order in name
  /// 4. characters appear in order in relative path
  /// Returns up to [limit] results, best first.
  List<FileEntry> search(String query, {int limit = 60}) {
    if (!_ready) return const [];
    final q = query.trim().toLowerCase();
    if (q.isEmpty) {
      return _entries.take(limit).toList();
    }
    final scored = <_Scored>[];
    for (final e in _entries) {
      final score = _score(q, e);
      if (score > 0) {
        scored.add(_Scored(e, score));
      }
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.entry).toList();
  }

  static int _score(String q, FileEntry e) {
    final name = e.name.toLowerCase();
    final rel = e.relativePath.toLowerCase();
    if (name == q) return 1000;
    if (name.startsWith(q)) return 900 - (name.length - q.length);
    final nameIdx = name.indexOf(q);
    if (nameIdx >= 0) return 800 - nameIdx;
    final relIdx = rel.indexOf(q);
    if (relIdx >= 0) return 700 - relIdx;
    if (_subsequence(q, name)) return 400;
    if (_subsequence(q, rel)) return 200;
    return 0;
  }

  static bool _subsequence(String needle, String haystack) {
    int i = 0;
    for (int j = 0; i < needle.length && j < haystack.length; j++) {
      if (needle.codeUnitAt(i) == haystack.codeUnitAt(j)) i++;
    }
    return i == needle.length;
  }
}

class _Scored {
  final FileEntry entry;
  final int score;
  _Scored(this.entry, this.score);
}

/// A single match returned by [TextSearch.search].
class TextMatch {
  final String absolutePath;
  final String relativePath;
  final int lineNumber;
  final String lineContent;
  final int matchStart;
  final int matchEnd;

  TextMatch({
    required this.absolutePath,
    required this.relativePath,
    required this.lineNumber,
    required this.lineContent,
    required this.matchStart,
    required this.matchEnd,
  });
}

/// Streams text matches across all files in a [FileIndex]. Skips binaries
/// (by extension), files that fail UTF-8 decoding, and oversized files.
class TextSearch {
  final FileIndex index;
  TextSearch(this.index);

  /// Yields matches one at a time. Caller can break the loop early.
  Stream<TextMatch> search(
    String query, {
    bool caseSensitive = false,
    bool isRegex = false,
    int maxMatchesPerFile = 50,
    int maxTotalMatches = 1000,
  }) async* {
    if (query.isEmpty) return;
    final pattern = _buildPattern(query,
        caseSensitive: caseSensitive, isRegex: isRegex);
    if (pattern == null) return;

    int total = 0;
    for (final entry in index.entries) {
      final ext = p.extension(entry.name).toLowerCase();
      if (_binaryExtensions.contains(ext)) continue;
      try {
        final stat = await File(entry.absolutePath).stat();
        if (stat.size > _maxSearchFileSize) continue;
      } catch (_) {
        continue;
      }
      String content;
      try {
        content = await File(entry.absolutePath).readAsString();
      } catch (_) {
        continue;
      }
      int perFile = 0;
      final lines = content.split('\n');
      for (int i = 0; i < lines.length; i++) {
        for (final m in pattern.allMatches(lines[i])) {
          yield TextMatch(
            absolutePath: entry.absolutePath,
            relativePath: entry.relativePath,
            lineNumber: i + 1,
            lineContent: lines[i],
            matchStart: m.start,
            matchEnd: m.end,
          );
          perFile++;
          total++;
          if (perFile >= maxMatchesPerFile) break;
          if (total >= maxTotalMatches) return;
        }
        if (perFile >= maxMatchesPerFile) break;
        if (total >= maxTotalMatches) return;
      }
    }
  }

  static RegExp? _buildPattern(
    String query, {
    required bool caseSensitive,
    required bool isRegex,
  }) {
    try {
      if (isRegex) {
        return RegExp(query, caseSensitive: caseSensitive);
      }
      return RegExp(RegExp.escape(query), caseSensitive: caseSensitive);
    } catch (_) {
      return null;
    }
  }
}
