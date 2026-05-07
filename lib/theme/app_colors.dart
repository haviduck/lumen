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
  // Secondary body text — visibly dimmer than [fgPrimary] but still
  // fully readable on the dark surfaces. Lands closer to [fgMuted]
  // than [fgPrimary] (~28% luminance drop from primary). Used for
  // the assistant reply prose so a glance at the chat distinguishes
  // user-typed text (bright [fgPrimary]) from model replies
  // (dimmed). Tuned iteratively against Cursor's chat reference —
  // a 7% drop read as a no-op, 22% was the right direction but
  // still too close to primary; the current value is the one that
  // actually carries the user/model visual hierarchy.
  static const Color fgSecondary = Color(0xFF9CA6B7);
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

  // ── Council theming — Nord-integrated, IDE chrome family ──
  //
  // Used by the Convene the Council modal: agent panels, speech
  // bubbles, traffic / network lines. Surfaces sit on the same
  // neutral ramp as the rest of the IDE (bgDeepest / bgDeeper /
  // bgRaised) instead of a saturated navy ramp — that fixes the
  // "blue/red gradient too much" reading. Accents are Nord frost
  // (stateInfo / accentCyan) — same tokens the IDE uses for its
  // own active chrome, so the council reads as part of the IDE
  // rather than a separate themed dialog.
  //
  // Coordination contract for sibling agents (e.g. traffic-line
  // painter): `councilAccent` is the canonical glow source. Pull
  // it directly — do not re-derive a hue.
  // Dark BLUE ramp restored 2026-05. The previous Nord-neutral grey
  // ramp made the council read as "more IDE chrome" rather than the
  // dedicated AI-visualization surface the user wanted. The new ramp
  // is a deep midnight navy: still dark enough not to fight the
  // editor, saturated enough to feel like its own room.
  static const Color councilBase = Color(0xFF080D1C); // deep navy floor
  static const Color councilSurface = Color(0xFF0E1530); // navy raised
  static const Color councilSurfaceHi = Color(0xFF131C3D); // navy raised hi
  static const Color councilBorder = Color(0xFF1F2A52); // navy hairline
  static const Color councilAccent = Color(0xFF7AA2D9); // bright frost
  static const Color councilAccentHi = Color(0xFF9CC4F0); // peak highlight
  static const Color councilAccentDim = Color(0xFF4E6FA8); // dim polar
  static const Color councilBubbleBg = Color(
    0xFF0C1226,
  ); // quoted utterance surface — sits between base and surface

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
