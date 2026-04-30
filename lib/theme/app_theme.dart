import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Single source of truth for animation durations & curves across Lumen.
///
/// Tune *one* constant and every `AnimatedContainer` / `AnimatedSwitcher` /
/// `AnimatedOpacity` in the IDE responds in step. Keeps the app cohesive
/// instead of drifting per-widget.
///
/// Scale (deliberately on the snappy end of the macOS/Windows desktop spec):
///  - [instant] : 90 ms — micro-feedback (hover/focus tints, ripples).
///  - [fast]    : 140 ms — list selections, small panel chrome swaps.
///  - [medium]  : 200 ms — layout transitions (panel collapse, dialog open).
///  - [slow]    : 340 ms — identity / brand reveals (welcome card, gradients).
///
/// Curves bias toward `easeOutCubic` for state changes (decelerate into
/// rest) and `easeOutBack` only for the welcome/dialog entrance where the
/// little overshoot reads as intentional polish.
class DuckMotion {
  DuckMotion._();

  static const Duration instant = Duration(milliseconds: 90);
  static const Duration fast = Duration(milliseconds: 140);
  static const Duration medium = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 340);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve emphasized = Curves.easeOutBack;

  /// Returns `Duration.zero` when the user has opted into reduced motion
  /// (preference-driven), otherwise the requested duration. Callers should
  /// resolve this once per build via `DuckMotion.resolve(state.reduceMotion, …)`.
  static Duration resolve(bool reduce, Duration d) =>
      reduce ? Duration.zero : d;
}

/// Centralized typography, sizing & ThemeData for Lumen IDE.
class DuckTheme {
  DuckTheme._();

  // Typography scale
  static const String monoFont = 'Consolas';
  static const String uiFont = 'Inter';

  static const TextStyle titleS = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w700,
    letterSpacing: 0.6,
    color: DuckColors.fgMuted,
  );

  static const TextStyle bodyM = TextStyle(
    fontSize: 13,
    color: DuckColors.fgPrimary,
  );

  static const TextStyle bodyS = TextStyle(
    fontSize: 12,
    color: DuckColors.fgMuted,
  );

  static const TextStyle code = TextStyle(
    fontFamily: monoFont,
    fontSize: 13,
    height: 1.45,
    color: DuckColors.fgPrimary,
  );

  // Sizing tokens
  static const double headerHeight = 36;
  static const double tabHeight = 32;
  static const double rowHeight = 26;
  static const double radiusS = 4;
  static const double radiusM = 8;
  static const double radiusL = 12;

  // Shadows
  static List<BoxShadow> get shadowSoft => [
    BoxShadow(
      color: Colors.black.withValues(alpha: 0.45),
      blurRadius: 18,
      offset: const Offset(0, 6),
    ),
  ];

  static List<BoxShadow> get shadowGlow => [
    BoxShadow(
      color: DuckColors.accentCyan.withValues(alpha: 0.18),
      blurRadius: 28,
      spreadRadius: -2,
      offset: const Offset(0, 4),
    ),
  ];

  static ThemeData build() {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: DuckColors.bgBase,
      fontFamily: uiFont,
      colorScheme: const ColorScheme.dark(
        primary: DuckColors.accentCyan,
        secondary: DuckColors.accentMint,
        surface: DuckColors.bgRaised,
        outline: DuckColors.border,
        onPrimary: Colors.white,
        onSurface: DuckColors.fgPrimary,
        error: DuckColors.stateError,
      ),
      dividerColor: DuckColors.glassSeam,
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: DuckColors.bgRaisedHi,
          borderRadius: BorderRadius.circular(radiusS),
          border: Border.all(color: DuckColors.glassEdgeHi, width: 0.5),
        ),
        textStyle: const TextStyle(fontSize: 11, color: DuckColors.fgPrimary),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        waitDuration: const Duration(milliseconds: 350),
      ),
      iconTheme: const IconThemeData(color: DuckColors.fgMuted, size: 16),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.hovered)) {
              return DuckColors.fgPrimary;
            }
            return DuckColors.fgMuted;
          }),
          overlayColor: WidgetStateProperty.all(
            DuckColors.bgRaisedHi.withValues(alpha: 0.6),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: DuckColors.bgChip,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusS),
          borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusS),
          borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusS),
          borderSide: const BorderSide(
            color: DuckColors.borderFocus,
            width: 1.2,
          ),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        hintStyle: const TextStyle(color: DuckColors.fgSubtle, fontSize: 13),
        isDense: true,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusL),
        ),
        elevation: 0,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: DuckColors.bgRaisedHi,
        contentTextStyle: const TextStyle(
          color: DuckColors.fgPrimary,
          fontSize: 12,
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusS),
          side: const BorderSide(color: DuckColors.glassEdgeHi, width: 0.5),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        // Solid, no alpha. Was previously `bgGlass` at 78% alpha, which
        // bled the ambient background through and made hover targets
        // hard to read. Border is the real-gray `DuckColors.border`
        // (#272C36 — one step lighter than `bgRaised`), not the
        // white-with-alpha `glassEdgeHi` that produced a "halo" look.
        color: DuckColors.bgRaised,
        surfaceTintColor: Colors.transparent,
        elevation: 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusM),
          side: const BorderSide(color: DuckColors.border, width: 0.5),
        ),
        textStyle: const TextStyle(color: DuckColors.fgPrimary, fontSize: 13),
      ),
      // Top-level `MenuBar` / `SubmenuButton` / `MenuAnchor` styling.
      // Material 3 uses these widgets (not `PopupMenuButton`) for the
      // top File / Edit / View menu, so the popupMenuTheme above does
      // **not** affect them — `menuTheme` does. Same solid `bgRaised`
      // surface + real-gray border so behaviour matches across all
      // menu surfaces in the IDE.
      menuTheme: MenuThemeData(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(DuckColors.bgRaised),
          surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
          shadowColor: WidgetStateProperty.all(
            Colors.black.withValues(alpha: 0.6),
          ),
          elevation: WidgetStateProperty.all(12),
          shape: WidgetStateProperty.all(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(radiusM),
              side: const BorderSide(color: DuckColors.border, width: 0.5),
            ),
          ),
        ),
      ),
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: DuckColors.accentCyan,
        linearTrackColor: DuckColors.bgChip,
      ),
    );
    return base;
  }
}
