import 'package:flutter/material.dart';

/// Core color tokens for Lumen IDE — "Cursor Dark Midnight" palette.
///
/// Derived from the official Cursor Dark Midnight VS Code theme JSON.
/// These are cool blue-gray tones, NOT warm brown/neutral grays.
class DuckColors {
  DuckColors._();

  // ── Surfaces — cool blue-gray midnight tones ──
  static const Color bgDeepest = Color(
    0xFF14171D,
  ); // menu bar / title bar / darkest
  static const Color bgDeeper = Color(
    0xFF191C22,
  ); // sidebar, terminal, panel, tabs-inactive
  static const Color bgBase = Color(0xFF1D2128); // general app bg
  static const Color bgRaised = Color(
    0xFF1E2127,
  ); // editor bg, active tab, main panels
  static const Color bgRaisedHi = Color(0xFF272C36); // hover, focused chrome
  static const Color bgChip = Color(0xFF1E2129); // chips, inputs

  /// Translucent surface for chrome panels.
  static const Color bgGlass = Color(0xC2191C22); // 76% dark midnight
  static const Color bgGlassHi = Color(0xD920242C); // 85% — hero surfaces

  // ── Borders / dividers ──
  static const Color border = Color(0xFF272C36);
  static const Color borderStrong = Color(0xFF434C5E);
  static const Color borderFocus = Color(0xFF88C0D0);

  // ── Glass edge highlights ──
  static const Color glassEdgeHi = Color(0x14FFFFFF); // 8% white
  static const Color glassEdgeLo = Color(0x0AFFFFFF); // 4% white
  static const Color glassSeam = Color(0x0DFFFFFF); // 5% white — panel.border

  // ── Foregrounds — cool blue-gray, NOT warm ──
  static const Color fgPrimary = Color(0xFFD8DEE9);
  static const Color pearlWhite = Color(0xFFECEFF4);
  static const Color fgMuted = Color(0xFF7B88A1);
  static const Color fgSubtle = Color(0xFF4B5163);
  static const Color fgFaint = Color(0xFF3B4252);

  // ── Accents — Nord-inspired cool palette ──
  static const Color accentDuck = Color(0xFFEBCB8B); // warm gold (nord yellow)
  static const Color accentPurple = Color(0xFFB48EAD); // soft purple/magenta
  static const Color accentCyan = Color(
    0xFF88C0D0,
  ); // cool cyan (primary accent)
  static const Color accentMint = Color(0xFF8FBCBB); // teal (nord frost)

  // ── Semantic states ──
  static const Color stateOk = Color(0xFFA3BE8C); // nord green
  static const Color stateWarn = Color(0xFFEBCB8B); // nord yellow
  static const Color stateError = Color(0xFFBF616A); // nord red
  static const Color stateInfo = Color(0xFF81A1C1); // nord blue

  // ── File / folder icons ──
  static const Color folderIcon = Color(0xFFEBCB8B);
  static const Color fileIcon = Color(0xFF81A1C1);

  // ── Code editor ──
  static const Color editorBg = Color(0xFF1E2127);
  static const Color editorGutter = Color(0xFF1E2127);
  static const Color editorLineHighlight = Color(0xFF272930);
  static const Color editorSelection = Color(0x99434C5E);
  // Vertical indent-guide stroke. Keep this quiet like Cursor: visible
  // enough to read scope, but not bright enough to compete with code.
  static const Color editorIndentGuide = Color(0x55434C5E);

  // ── Gradients ──
  static const Gradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFECEFF4), Color(0xFFD8DEE9), Color(0xFF7B88A1)],
  );

  static const Gradient duckGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFFEBCB8B), Color(0xFFD08770)],
  );
}
