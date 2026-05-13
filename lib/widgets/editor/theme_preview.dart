import 'package:flutter/material.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'editor_themes.dart';

/// Compact, non-editable code-block preview that re-highlights a fixed
/// Dart snippet whenever the [themeId] prop changes. Used inside the
/// Settings → Theme section so the user can see a real syntax sample
/// even when no editor tab is open.
///
/// The snippet covers the main token roles a code theme paints —
/// comment, keyword, type, function, string, number, decorator,
/// operator — so a glance at the block tells the user whether the
/// theme tints comments dim enough, keywords boldly enough, etc.
class ThemePreviewBlock extends StatelessWidget {
  const ThemePreviewBlock({super.key, required this.themeId});

  final String themeId;

  static const String _sample =
      '// Lumen — drag a workspace folder in to get started.\n'
      'import \'package:lumen/app.dart\';\n'
      '\n'
      '/// Mounts the IDE shell with the user\'s saved theme.\n'
      'class LumenApp extends StatelessWidget {\n'
      '  const LumenApp({super.key, this.startupTabs = const []});\n'
      '\n'
      '  final List<String> startupTabs;\n'
      '\n'
      '  @override\n'
      '  Widget build(BuildContext context) {\n'
      '    final greeting = "Hello, IDE";\n'
      '    final answer = 42;\n'
      '    return MaterialApp(\n'
      '      title: greeting,\n'
      '      home: Center(child: Text(\'\$greeting · \$answer\')),\n'
      '    );\n'
      '  }\n'
      '}\n';

  @override
  Widget build(BuildContext context) {
    final themeMap = EditorThemes.resolve(themeId);
    final highlight = Highlight()..registerLanguage('dart', langDart);
    final result = highlight.highlight(code: _sample, language: 'dart');
    final renderer = TextSpanRenderer(
      const TextStyle(
        fontFamily: DuckTheme.monoFont,
        fontSize: 12.5,
        height: 1.45,
        color: DuckColors.fgPrimary,
      ),
      themeMap,
    );
    result.render(renderer);
    final span = renderer.span;

    return ClipRRect(
      borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      child: Container(
        decoration: BoxDecoration(
          color: DuckColors.editorBg,
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        constraints: const BoxConstraints(minWidth: double.infinity),
        child: SelectableText.rich(
          span ??
              TextSpan(
                text: _sample,
                style: const TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 12.5,
                  height: 1.45,
                  color: DuckColors.fgPrimary,
                ),
              ),
        ),
      ),
    );
  }
}
