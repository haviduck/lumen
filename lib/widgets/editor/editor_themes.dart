import 'package:flutter/material.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/monokai-sublime.dart';
import 'package:re_highlight/styles/night-owl.dart';
import 'package:re_highlight/styles/nord.dart';
import 'package:re_highlight/styles/shades-of-purple.dart';
import 'package:re_highlight/styles/vs2015.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/tokyo-night-dark.dart';
import 'package:re_highlight/styles/panda-syntax-dark.dart';
import '../../theme/app_colors.dart';
import 'lumen_midnight_theme.dart';

/// Registry of selectable code-editor color themes.
class EditorThemes {
  EditorThemes._();

  /// `lumen-midnight` is the bespoke theme tuned to the rest of the
  /// IDE chrome — it sits at the top of the registry so it shows up
  /// first in the Settings dropdown, and is the default for new
  /// installs (existing users on `nord` are migrated by
  /// `PreferencesService.getEditorTheme`).
  static final Map<String, Map<String, TextStyle>> _themes = {
    'lumen-midnight': LumenMidnightTheme.theme,
    'one-dark-pro': atomOneDarkTheme,
    'monokai-sublime': monokaiSublimeTheme,
    'night-owl': nightOwlTheme,
    'nord': nordTheme,
    'shades-of-purple': shadesOfPurpleTheme,
    'vs2015': vs2015Theme,
    'github-dark': githubDarkTheme,
    'tokyo-night': tokyoNightDarkTheme,
    'panda-syntax': pandaSyntaxDarkTheme,
  };

  static List<String> get names => _themes.keys.toList();

  static Map<String, TextStyle> resolve(String name) {
    final theme = Map<String, TextStyle>.of(
      _themes[name] ?? LumenMidnightTheme.theme,
    );
    final root = theme['root'] ?? const TextStyle();
    theme['root'] = root.copyWith(
      color: root.color ?? DuckColors.fgPrimary,
      backgroundColor: DuckColors.editorBg,
    );
    return theme;
  }

  static String prettyName(String id) {
    return id
        .split('-')
        .map((s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1))
        .join(' ');
  }
}
