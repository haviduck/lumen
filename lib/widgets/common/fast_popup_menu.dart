import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// A drop-in replacement for [showMenu] that appears instantly — no 300ms
/// grow animation. Uses a custom [PopupRoute] with zero transition duration,
/// but reuses Flutter's built-in popup menu items/layout so the theme and
/// behavior stay consistent.
///
/// Usage (identical to `showMenu` minus unused params):
/// ```dart
/// final picked = await showFastMenu<String>(
///   context: context,
///   position: RelativeRect.fromLTRB(x, y, right, 0),
///   items: [...],
/// );
/// ```
Future<T?> showFastMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<PopupMenuEntry<T>> items,
  bool useRootNavigator = false,
}) {
  final nav = Navigator.of(context, rootNavigator: useRootNavigator);
  return nav.push<T>(_InstantPopupRoute<T>(
    position: position,
    items: _compactItems<T>(items),
    capturedThemes: InheritedTheme.capture(from: context, to: nav.context),
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  ));
}

/// Recreate each [PopupMenuItem] in [items] with a tighter height +
/// padding so right-click / context menus don't have huge vertical
/// gaps. Default `PopupMenuItem.height` is `kMinInteractiveDimension`
/// (48 px) which is overkill for our compact dark menus — drop it
/// to 30 and pull the inner padding down to match. Leave dividers
/// alone.
///
/// Done at the `showFastMenu` boundary rather than per-callsite so
/// the fix is global without touching the dozen-plus places that
/// build menu items.
List<PopupMenuEntry<T>> _compactItems<T>(List<PopupMenuEntry<T>> items) {
  return items.map<PopupMenuEntry<T>>((item) {
    if (item is PopupMenuItem<T>) {
      return PopupMenuItem<T>(
        value: item.value,
        enabled: item.enabled,
        onTap: item.onTap,
        height: 30,
        padding: item.padding ??
            const EdgeInsets.symmetric(horizontal: 12, vertical: 0),
        mouseCursor: item.mouseCursor,
        labelTextStyle: item.labelTextStyle,
        child: item.child,
      );
    }
    return item;
  }).toList(growable: false);
}

class _InstantPopupRoute<T> extends PopupRoute<T> {
  _InstantPopupRoute({
    required this.position,
    required this.items,
    required this.capturedThemes,
    required this.barrierLabel,
  });

  final RelativeRect position;
  final List<PopupMenuEntry<T>> items;
  final CapturedThemes capturedThemes;

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Duration get reverseTransitionDuration => Duration.zero;

  @override
  bool get barrierDismissible => true;

  @override
  Color? get barrierColor => null;

  @override
  final String barrierLabel;

  @override
  Widget buildPage(BuildContext ctx, Animation<double> anim, Animation<double> secAnim) {
    return capturedThemes.wrap(_InstantPopupBody<T>(route: this));
  }
}

class _InstantPopupBody<T> extends StatelessWidget {
  const _InstantPopupBody({required this.route});
  final _InstantPopupRoute<T> route;

  @override
  Widget build(BuildContext context) {
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      removeBottom: true,
      removeLeft: true,
      removeRight: true,
      child: CustomSingleChildLayout(
        delegate: _MenuLayout(route.position),
        // The widget tree below is structurally load-bearing:
        //
        //   Container(solid bgRaised + border + shadow)
        //     └ ClipRRect (so ink ripples respect the rounded corners)
        //       └ Material(type: transparency)   ← hosts InkWell ink
        //         └ Theme(hover/focus/splash overrides)
        //           └ items
        //
        // Why this order matters: PopupMenuItem renders an `InkWell`
        // internally, which paints hover / focus / splash on the
        // nearest `Material` ancestor. If the Container with the
        // solid `bgRaised` color sits BELOW the Material in z-order
        // (i.e. is a parent of the Material) the ink draws on top of
        // the bg and is visible. The previous arrangement had Material
        // wrapping Container — Material's ink layer was drawn FIRST
        // and the Container's opaque bg was painted over it, silently
        // hiding every hover effect. Don't re-invert this nesting.
        child: Container(
          decoration: BoxDecoration(
            color: DuckColors.bgRaised,
            borderRadius: BorderRadius.circular(6),
            // Match the rest of our chrome: 0.5px hairline at
            // `border` (#272C36) instead of the previous 1px
            // `#2d3139` which read bright on the deep-dark
            // surface (the user-flagged "white border").
            border: Border.all(
              color: DuckColors.border,
              width: 0.5,
            ),
            boxShadow: const [
              BoxShadow(
                color: Color(0x60000000),
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Material(
              type: MaterialType.transparency,
              child: Theme(
                // `PopupMenuItem` renders an `InkWell` internally for
                // hover / focus / splash, which all fall back to the
                // inherited theme. Flutter's dark default for
                // `hoverColor` is `Colors.white.withOpacity(0.04)` —
                // invisible against our `bgRaised` (#1E2127) surface.
                // Override those tokens so right-click context menus
                // and the GitNexus dropdown actually show a hover
                // state. Applied via `Theme.copyWith` so every
                // callsite of `showFastMenu` benefits without
                // per-item plumbing.
                data: Theme.of(context).copyWith(
                  hoverColor: DuckColors.bgRaisedHi,
                  focusColor: DuckColors.bgRaisedHi,
                  highlightColor:
                      DuckColors.bgRaisedHi.withValues(alpha: 0.6),
                  splashColor:
                      DuckColors.bgRaisedHi.withValues(alpha: 0.4),
                  popupMenuTheme: PopupMenuThemeData(
                    color: DuckColors.bgRaised,
                    surfaceTintColor: Colors.transparent,
                    textStyle: const TextStyle(
                      fontSize: 12,
                      color: DuckColors.fgPrimary,
                    ),
                    labelTextStyle: WidgetStateProperty.all(
                      const TextStyle(
                        fontSize: 12,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                  ),
                ),
                child: ConstrainedBox(
                  // Dropdown is wider than the previous 56-step
                  // `IntrinsicWidth`. 200px reads more like a real
                  // menu and gives labels room to breathe; the
                  // intrinsic width still grows past this for
                  // longer items.
                  constraints: const BoxConstraints(minWidth: 200),
                  child: IntrinsicWidth(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: ListBody(
                        children: route.items.toList(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuLayout extends SingleChildLayoutDelegate {
  _MenuLayout(this.position);
  final RelativeRect position;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints.loose(Size(
      constraints.biggest.width - 16,
      constraints.biggest.height - 16,
    ));
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    double x = position.left;
    double y = position.top;
    if (x + childSize.width > size.width - 8) {
      x = size.width - childSize.width - 8;
    }
    if (y + childSize.height > size.height - 8) {
      y = size.height - childSize.height - 8;
    }
    return Offset(x.clamp(8.0, size.width - 8.0), y.clamp(8.0, size.height - 8.0));
  }

  @override
  bool shouldRelayout(_MenuLayout old) => position != old.position;
}
