import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Maps file extensions to accent icon colors for the file explorer.
/// Inspired by VS Code / Cursor's file icon coloring.
class FileIconColors {
  FileIconColors._();

  static Color forFileName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return _extColors[ext] ?? DuckColors.fgSubtle;
  }

  static IconData iconForFileName(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return _extIcons[ext] ?? Icons.description;
  }

  // ── Extension → Color map ──
  // Grouped by language family for maintenance clarity.
  static const Map<String, Color> _extColors = {
    // Dart / Flutter
    'dart':       Color(0xFF56B6C2),  // teal-cyan

    // Web
    'html':       Color(0xFFE06C75),  // coral red
    'htm':        Color(0xFFE06C75),
    'css':        Color(0xFF56B6C2),  // teal
    'scss':       Color(0xFFCC6699),  // pink
    'sass':       Color(0xFFCC6699),
    'less':       Color(0xFF56B6C2),

    // JavaScript / TypeScript
    'js':         Color(0xFFEBCB8B),  // gold
    'jsx':        Color(0xFF61AFEF),  // blue
    'ts':         Color(0xFF3178C6),  // TS blue
    'tsx':        Color(0xFF61AFEF),

    // Python
    'py':         Color(0xFF4B8BBE),  // python blue
    'pyw':        Color(0xFF4B8BBE),
    'ipynb':      Color(0xFFE06C75),

    // Rust / Go / C family
    'rs':         Color(0xFFDEA584),  // rust orange
    'go':         Color(0xFF00ADD8),  // go cyan
    'c':          Color(0xFF61AFEF),  // blue
    'h':          Color(0xFFB48EAD),  // purple
    'cpp':        Color(0xFF61AFEF),
    'hpp':        Color(0xFFB48EAD),
    'cs':         Color(0xFF68217A),  // C# purple

    // Java / Kotlin / Swift
    'java':       Color(0xFFE06C75),  // red
    'kt':         Color(0xFFA97BFF),  // kotlin purple
    'kts':        Color(0xFFA97BFF),
    'swift':      Color(0xFFE06C75),

    // Ruby / PHP / Perl
    'rb':         Color(0xFFE06C75),
    'php':        Color(0xFF777BB4),  // php lavender
    'pl':         Color(0xFF56B6C2),

    // Shell / scripts
    'sh':         Color(0xFFA3BE8C),  // green
    'bash':       Color(0xFFA3BE8C),
    'zsh':        Color(0xFFA3BE8C),
    'ps1':        Color(0xFF56B6C2),
    'bat':        Color(0xFFA3BE8C),
    'cmd':        Color(0xFFA3BE8C),

    // Config / data
    'json':       Color(0xFFEBCB8B),  // gold
    'yaml':       Color(0xFFE06C75),  // red
    'yml':        Color(0xFFE06C75),
    'toml':       Color(0xFFE06C75),
    'xml':        Color(0xFFE06C75),
    'ini':        Color(0xFF7B88A1),
    'env':        Color(0xFFEBCB8B),

    // Markdown / docs
    'md':         Color(0xFF61AFEF),  // blue
    'mdx':        Color(0xFF61AFEF),
    'txt':        Color(0xFF7B88A1),  // gray
    'rst':        Color(0xFF7B88A1),

    // Git
    'gitignore':  Color(0xFFE06C75),

    // Docker
    'dockerfile': Color(0xFF3178C6),

    // SQL
    'sql':        Color(0xFFEBCB8B),

    // Images
    'png':        Color(0xFFA3BE8C),
    'jpg':        Color(0xFFA3BE8C),
    'jpeg':       Color(0xFFA3BE8C),
    'gif':        Color(0xFFA3BE8C),
    'svg':        Color(0xFFEBCB8B),
    'ico':        Color(0xFFA3BE8C),
    'webp':       Color(0xFFA3BE8C),

    // Lock / generated
    'lock':       Color(0xFF5C6370),  // dim — not important
    'g.dart':     Color(0xFF5C6370),
    'freezed.dart': Color(0xFF5C6370),

    // Pub / build
    'iml':        Color(0xFF5C6370),
    'arb':        Color(0xFF61AFEF),
  };

  // ── Extension → Icon map (optional overrides) ──
  static const Map<String, IconData> _extIcons = {
    'dart':   Icons.flutter_dash,
    'md':     Icons.article,
    'json':   Icons.data_object,
    'yaml':   Icons.settings_suggest,
    'yml':    Icons.settings_suggest,
    'lock':   Icons.lock_outline,
    'gitignore': Icons.visibility_off,
    'png':    Icons.image,
    'jpg':    Icons.image,
    'jpeg':   Icons.image,
    'gif':    Icons.image,
    'svg':    Icons.image,
    'webp':   Icons.image,
    'ico':    Icons.image,
  };
}
