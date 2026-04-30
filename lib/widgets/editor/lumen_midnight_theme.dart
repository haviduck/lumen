import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// Custom syntax-highlight theme tuned to Lumen's Cursor-Dark-Midnight
/// chrome palette.
///
/// Design intent: Nord-derived (so it feels native against the rest
/// of the IDE), but with deliberate hue spread so the editor canvas
/// isn't visually dominated by white identifiers + gray comments —
/// the complaint that motivated this theme. Token roles map roughly:
///
///   Comments        → dim slate, italic (#4C566A)
///   Keywords/flow   → soft purple (#C678DD)            — pulls eye
///   Functions/calls → cool cyan  (#61AFEF)             — bright blue
///   Types/classes   → warm gold  (#E5C07B)             — slightly muted gold
///   Built-ins       → warm gold  (#E5C07B)
///   Strings         → nord green (#98C379)
///   Numbers/literals→ nord orange (#D19A66)
///   Decorators/meta → soft mauve (#B48EAD)             — accentPurple
///   Regex / errors  → coral red  (#E06C75)
///   Operators       → cool blue  (#56B6C2)             — teal
///   Variables       → soft red   (#E06C75)
///   Parameters      → nord orange (#D19A66)
///   Identifiers     → fgPrimary  (#ABB2BF)
///
/// Token names follow highlight.js' canonical class names so that
/// every language `highlight` ships with picks up the right colors.
/// Not every class is mapped — only the ones that meaningfully change
/// the look. Anything unmapped inherits `root` (default foreground).
class LumenMidnightTheme {
  LumenMidnightTheme._();

  // ── Token colors — richer, more present but not neon ──
  static const Color _comment  = Color(0xFF4C566A);  // dimmer slate
  static const Color _keyword  = Color(0xFFC678DD);  // soft purple
  static const Color _string   = Color(0xFF98C379);  // green
  static const Color _number   = Color(0xFFD19A66);  // orange
  static const Color _function = Color(0xFF61AFEF);  // bright blue
  static const Color _type     = Color(0xFFE5C07B);  // warm gold
  static const Color _meta     = Color(0xFFB48EAD);  // mauve
  static const Color _operator = Color(0xFF56B6C2);  // teal
  static const Color _variable = Color(0xFFE06C75);  // soft red
  static const Color _tag      = Color(0xFFE06C75);  // HTML tags

  static const Map<String, TextStyle> theme = {
    'root': TextStyle(
      backgroundColor: DuckColors.editorBg,
      color: Color(0xFFABB2BF),  // slightly warmer than pure fgPrimary
    ),

    // Comments / docs — dim italic so they recede.
    'comment': TextStyle(color: _comment, fontStyle: FontStyle.italic),
    'quote': TextStyle(color: _comment, fontStyle: FontStyle.italic),
    'doctag': TextStyle(color: _meta, fontStyle: FontStyle.italic),

    // Control flow / language keywords.
    'keyword': TextStyle(color: _keyword),
    'selector-tag': TextStyle(color: _keyword),
    'literal': TextStyle(color: _number),
    'subst': TextStyle(color: Color(0xFFABB2BF)),

    // Tags (HTML/XML)
    'tag': TextStyle(color: _tag),

    // Numbers / atomic literals.
    'number': TextStyle(color: _number),
    'symbol': TextStyle(color: _number),
    'bullet': TextStyle(color: _number),

    // Strings + string-adjacent.
    'string': TextStyle(color: _string),
    'meta-string': TextStyle(color: _string),
    'addition': TextStyle(
      color: _string,
      backgroundColor: Color(0x2298C379),
    ),

    // Regex / errors.
    'regexp': TextStyle(color: _variable),
    'deletion': TextStyle(
      color: _variable,
      backgroundColor: Color(0x22E06C75),
    ),

    // Functions, sections, titles.
    'title': TextStyle(color: _function),
    'function': TextStyle(color: _function),
    'name': TextStyle(color: _function),
    'section': TextStyle(color: _function, fontWeight: FontWeight.w500),
    'selector-id': TextStyle(color: _function),

    // Types / classes / built-ins.
    'type': TextStyle(color: _type),
    'class': TextStyle(color: _type),
    'built_in': TextStyle(color: _type),
    'attr': TextStyle(color: _type),
    'attribute': TextStyle(color: _type),
    'selector-class': TextStyle(color: _type),

    // Variables / parameters — accent colored, not default fg.
    'variable': TextStyle(color: _variable),
    'params': TextStyle(color: _number),
    'template-variable': TextStyle(color: _variable),

    // Decorators / annotations / preprocessor.
    'meta': TextStyle(color: _meta),
    'meta-keyword': TextStyle(color: _meta, fontWeight: FontWeight.w500),

    // Operators / punctuation that the grammar tags.
    'operator': TextStyle(color: _operator),
    'punctuation': TextStyle(color: Color(0xFFABB2BF)),

    // Markdown-ish.
    'emphasis': TextStyle(fontStyle: FontStyle.italic),
    'strong': TextStyle(fontWeight: FontWeight.bold),
    'link': TextStyle(
      color: _function,
      decoration: TextDecoration.underline,
    ),
    'code': TextStyle(
      color: _function,
      backgroundColor: DuckColors.bgDeeper,
    ),
  };
}
