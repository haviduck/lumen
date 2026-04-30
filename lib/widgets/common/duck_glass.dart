import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Glassmorphism container — Lumen's universal chrome surface.
///
/// Wraps a child in `BackdropFilter(blur)` over a translucent tint with a
/// luminous edge highlight. Use this on every chrome surface (menu bar,
/// status bar, panels, dialogs, overlays) **except the editor canvas** —
/// the `CodeField` body must stay opaque so syntax colours don't tint.
///
/// Two intensity tiers:
///  - `DuckGlass(...)` : subtle chrome (sigma 18, translucent tint).
///  - `DuckGlass.hero(...)` : dialog-class surfaces (sigma 28, denser
///    tint, soft shadow by default).
///
/// **Glass edge treatment.** Instead of a flat gray `Border.all`, the
/// glass uses a gradient-like edge: top/left edges get a bright highlight
/// (`Colors.white` at ~8%), bottom/right stay near-invisible. This sells
/// the "pane of frosted glass catching light from above-left" illusion
/// that the reference images show.
///
/// **Performance.** `BackdropFilter` is GPU-cheap on desktop GPUs but
/// stacks badly when nested. Use one per panel, never inside scroll
/// children. When the user has flipped `AppState.reduceTransparency`
/// (Settings → Reduce Transparency), this widget collapses to a flat
/// `bgRaised` container with no blur at all — same shape, same shadow.
class DuckGlass extends StatelessWidget {
  final Widget child;

  /// Override the blur sigma. Default 18 for chrome, 28 for hero.
  final double? blurSigma;

  /// Override the tint colour. Defaults to `bgGlass` (or `bgGlassHi` for
  /// hero). Pass an explicit colour to taste a panel differently.
  final Color? tint;

  /// Single-colour border override. Ignored if [border] is set.
  /// Pass `Colors.transparent` for chrome that shouldn't have visible edges.
  final Color? borderColor;

  /// Corner radius. Defaults to 0 — most chrome surfaces hug their parent
  /// edges. Dialogs / overlays should pass `DuckTheme.radiusL`.
  final double radius;

  /// Optional drop shadow (use `DuckTheme.shadowSoft` for hero surfaces).
  final List<BoxShadow>? boxShadow;

  /// Padding inside the glass surface.
  final EdgeInsetsGeometry? padding;

  /// Optional border (overrides `borderColor` if set). Use for partial
  /// borders like `Border(top: ...)`.
  final BoxBorder? border;

  /// Treat as a hero surface — bigger blur, higher tint alpha.
  final bool _hero;

  const DuckGlass({
    super.key,
    required this.child,
    this.blurSigma,
    this.tint,
    this.borderColor,
    this.border,
    this.radius = 0,
    this.boxShadow,
    this.padding,
  }) : _hero = false;

  /// Hero variant — for dialog content, the welcome card, command palette
  /// surfaces. Larger blur, denser tint, soft shadow by default.
  const DuckGlass.hero({
    super.key,
    required this.child,
    this.blurSigma,
    this.tint,
    this.borderColor,
    this.border,
    this.radius = DuckTheme.radiusL,
    this.boxShadow,
    this.padding,
  }) : _hero = true;

  @override
  Widget build(BuildContext context) {
    final reduce = context.select<AppState, bool>((s) => s.reduceTransparency);

    final effectiveTint =
        tint ?? (_hero ? DuckColors.bgGlassHi : DuckColors.bgGlass);
    final effectiveBlur = blurSigma ?? (_hero ? 28.0 : 18.0);
    final effectiveShadow = boxShadow ?? (_hero ? DuckTheme.shadowSoft : null);
    final shape = radius == 0
        ? null
        : BorderRadius.all(Radius.circular(radius));

    // --- Reduced-transparency fallback: flat container. ---
    if (reduce) {
      return Container(
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          border: _resolveEdgeBorder(opaque: true),
          borderRadius: shape,
          boxShadow: effectiveShadow,
        ),
        padding: padding,
        clipBehavior: shape == null ? Clip.none : Clip.antiAlias,
        child: child,
      );
    }

    // --- Full glass path: BackdropFilter + translucent tint + glow edge. ---
    final filtered = BackdropFilter(
      filter: ImageFilter.blur(sigmaX: effectiveBlur, sigmaY: effectiveBlur),
      child: Container(
        decoration: BoxDecoration(
          // Translucent tint over the blurred content.
          color: effectiveTint,
          // Luminous edge: top/left catch the light, bottom/right stay dim.
          border: _resolveEdgeBorder(opaque: false),
          borderRadius: shape,
        ),
        padding: padding,
        child: child,
      ),
    );

    Widget out = shape == null
        ? ClipRect(child: filtered)
        : ClipRRect(borderRadius: shape, child: filtered);

    if (effectiveShadow != null) {
      out = DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: shape,
          boxShadow: effectiveShadow,
        ),
        child: out,
      );
    }
    return out;
  }

  /// Resolves the border. Priority:
  /// 1. Explicit [border] (e.g. `Border(top: ...)`).
  /// 2. Explicit [borderColor] wrapped in `Border.all`.
  /// 3. Default luminous glass edge (non-opaque) or subtle gray (opaque).
  BoxBorder _resolveEdgeBorder({required bool opaque}) {
    if (border != null) return border!;
    if (borderColor != null) {
      return Border.all(color: borderColor!, width: 0.5);
    }
    if (opaque) {
      return Border.all(color: DuckColors.border, width: 1);
    }
    // Glass edge: luminous highlight top/left, near-invisible bottom/right.
    return const Border(
      top: BorderSide(color: DuckColors.glassEdgeHi, width: 0.5),
      left: BorderSide(color: DuckColors.glassEdgeHi, width: 0.5),
      bottom: BorderSide(color: DuckColors.glassEdgeLo, width: 0.5),
      right: BorderSide(color: DuckColors.glassEdgeLo, width: 0.5),
    );
  }
}
