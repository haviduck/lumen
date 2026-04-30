import 'dart:io';

import 'package:path/path.dart' as p;

/// Small `.gitignore` matcher for UI affordances.
///
/// This is intentionally not a full git-compatible engine. It covers the
/// project-root `.gitignore` cases the file explorer needs to badge visible
/// rows:
/// - comments / blank lines ignored
/// - `!pattern` negation, last matching pattern wins
/// - trailing `/` means directories only
/// - leading `/` anchors to workspace root
/// - bare names like `node_modules` match any path segment
/// - globs: `*`, `?`, and `**`
///
/// Git itself has more edge cases (escaped spaces, bracket classes, nested
/// .gitignore files, etc.). Do not use this for destructive decisions; it is
/// only for showing the "ignored" badge in the explorer.
class GitIgnoreMatcher {
  final String workspacePath;
  final List<_GitIgnorePattern> _patterns;

  const GitIgnoreMatcher._({
    required this.workspacePath,
    required List<_GitIgnorePattern> patterns,
  }) : _patterns = patterns;

  factory GitIgnoreMatcher.empty(String workspacePath) {
    return GitIgnoreMatcher._(workspacePath: workspacePath, patterns: const []);
  }

  factory GitIgnoreMatcher.load(String workspacePath) {
    final file = File(p.join(workspacePath, '.gitignore'));
    if (!file.existsSync()) return GitIgnoreMatcher.empty(workspacePath);
    final patterns = <_GitIgnorePattern>[];
    for (final rawLine in file.readAsLinesSync()) {
      final parsed = _GitIgnorePattern.tryParse(rawLine);
      if (parsed != null) patterns.add(parsed);
    }
    return GitIgnoreMatcher._(workspacePath: workspacePath, patterns: patterns);
  }

  bool get hasPatterns => _patterns.isNotEmpty;

  bool isIgnored(String absolutePath, {required bool isDirectory}) {
    if (_patterns.isEmpty) return false;
    final rel = p
        .relative(absolutePath, from: workspacePath)
        .replaceAll(r'\', '/');
    if (rel.isEmpty || rel == '.' || rel.startsWith('../')) return false;

    var ignored = false;
    for (final pattern in _patterns) {
      if (pattern.matches(rel, isDirectory: isDirectory)) {
        ignored = !pattern.negated;
      }
    }
    return ignored;
  }
}

class _GitIgnorePattern {
  final String pattern;
  final bool negated;
  final bool anchored;
  final bool directoryOnly;
  final bool hasSlash;
  final RegExp regex;

  const _GitIgnorePattern({
    required this.pattern,
    required this.negated,
    required this.anchored,
    required this.directoryOnly,
    required this.hasSlash,
    required this.regex,
  });

  static _GitIgnorePattern? tryParse(String rawLine) {
    var line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) return null;

    var negated = false;
    if (line.startsWith('!')) {
      negated = true;
      line = line.substring(1).trim();
    }
    if (line.isEmpty) return null;

    final directoryOnly = line.endsWith('/');
    line = line.replaceAll(RegExp(r'/+$'), '');

    final anchored = line.startsWith('/');
    if (anchored) line = line.replaceAll(RegExp(r'^/+'), '');
    if (line.isEmpty) return null;

    final hasSlash = line.contains('/');
    return _GitIgnorePattern(
      pattern: line,
      negated: negated,
      anchored: anchored,
      directoryOnly: directoryOnly,
      hasSlash: hasSlash,
      regex: _globToRegExp(line),
    );
  }

  bool matches(String relPath, {required bool isDirectory}) {
    final rel = relPath.replaceAll(r'\', '/');
    if (directoryOnly && !isDirectory && !rel.startsWith('$pattern/')) {
      return false;
    }

    if (anchored || hasSlash) {
      return regex.hasMatch(rel) || rel.startsWith('$pattern/');
    }

    final segments = rel.split('/');
    for (var i = 0; i < segments.length; i++) {
      final segment = segments[i];
      if (regex.hasMatch(segment)) return true;
      // Bare directory names ignore everything below that directory.
      if (i < segments.length - 1 && regex.hasMatch(segment)) return true;
    }
    return false;
  }

  static RegExp _globToRegExp(String glob) {
    final buf = StringBuffer('^');
    for (var i = 0; i < glob.length; i++) {
      final c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
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
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString());
  }
}
