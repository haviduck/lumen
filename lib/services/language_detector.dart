import 'package:re_highlight/re_highlight.dart' show Mode;
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';

/// Maps file extensions / content heuristics to a `re_highlight` language Mode
/// usable by `re_editor`. Returns `null` when nothing fits and
/// the editor should render as plain text.
class LanguageDetector {
  LanguageDetector._();

  static final Map<String, ({String id, Mode mode})> _byExt = {
    'dart': (id: 'dart', mode: langDart),
    'js': (id: 'javascript', mode: langJavascript),
    'mjs': (id: 'javascript', mode: langJavascript),
    'cjs': (id: 'javascript', mode: langJavascript),
    'jsx': (id: 'javascript', mode: langJavascript),
    'ts': (id: 'typescript', mode: langTypescript),
    'tsx': (id: 'typescript', mode: langTypescript),
    'py': (id: 'python', mode: langPython),
    'rb': (id: 'ruby', mode: langRuby),
    'go': (id: 'go', mode: langGo),
    'rs': (id: 'rust', mode: langRust),
    'java': (id: 'java', mode: langJava),
    'kt': (id: 'kotlin', mode: langKotlin),
    'kts': (id: 'kotlin', mode: langKotlin),
    'swift': (id: 'swift', mode: langSwift),
    'cs': (id: 'csharp', mode: langCsharp),
    'cpp': (id: 'cpp', mode: langCpp),
    'cc': (id: 'cpp', mode: langCpp),
    'cxx': (id: 'cpp', mode: langCpp),
    'c': (id: 'cpp', mode: langCpp),
    'h': (id: 'cpp', mode: langCpp),
    'hpp': (id: 'cpp', mode: langCpp),
    'php': (id: 'php', mode: langPhp),
    'sh': (id: 'bash', mode: langBash),
    'bash': (id: 'bash', mode: langBash),
    'zsh': (id: 'bash', mode: langBash),
    'ps1': (id: 'bash', mode: langBash),
    'json': (id: 'json', mode: langJson),
    'yml': (id: 'yaml', mode: langYaml),
    'yaml': (id: 'yaml', mode: langYaml),
    'md': (id: 'markdown', mode: langMarkdown),
    'markdown': (id: 'markdown', mode: langMarkdown),
    'sql': (id: 'sql', mode: langSql),
    'css': (id: 'css', mode: langCss),
    'scss': (id: 'scss', mode: langScss),
    'sass': (id: 'scss', mode: langScss),
    'less': (id: 'css', mode: langCss),
    'html': (id: 'xml', mode: langXml),
    'htm': (id: 'xml', mode: langXml),
    'xml': (id: 'xml', mode: langXml),
    'svg': (id: 'xml', mode: langXml),
  };

  /// All language IDs the user can manually select.
  static List<String> get allLanguageIds {
    final ids = _byExt.values.map((e) => e.id).toSet().toList()..sort();
    return ['plain', ...ids];
  }

  static Mode? modeForId(String id) {
    if (id == 'plain') return null;
    for (final v in _byExt.values) {
      if (v.id == id) return v.mode;
    }
    return null;
  }

  /// Best-effort detection from path + first 2KB of content.
  static ({String id, Mode? mode}) detect(String path, String content) {
    final ext = path.toLowerCase().split('.').last;
    final byExt = _byExt[ext];
    if (byExt != null) return (id: byExt.id, mode: byExt.mode);

    final head = content.length > 2048 ? content.substring(0, 2048) : content;
    final firstLine = head.split('\n').first.trim();

    if (firstLine.startsWith('#!')) {
      if (firstLine.contains('python')) return (id: 'python', mode: langPython);
      if (firstLine.contains('node')) return (id: 'javascript', mode: langJavascript);
      if (firstLine.contains('bash') || firstLine.contains('sh')) {
        return (id: 'bash', mode: langBash);
      }
      if (firstLine.contains('ruby')) return (id: 'ruby', mode: langRuby);
    }

    if (head.contains('<?php')) return (id: 'php', mode: langPhp);
    if (head.startsWith('{') || head.startsWith('[')) {
      final trimmed = head.trim();
      if (trimmed.endsWith('}') || trimmed.endsWith(']') || trimmed.length > 50) {
        return (id: 'json', mode: langJson);
      }
    }
    if (head.startsWith('<')) return (id: 'xml', mode: langXml);

    return (id: 'plain', mode: null);
  }
}
