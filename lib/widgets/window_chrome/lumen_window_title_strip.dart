import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../theme/app_colors.dart';
import 'window_controls.dart';

/// Slim window-drag strip for surfaces that don't have their own menu
/// bar (welcome screen, lock screen, etc.). Provides the only way to
/// move the window once the OS title bar is hidden — paired with
/// `LumenWindowControls` for minimize / maximize-restore / close.
///
/// Dimensions: same 30 px height as `DuckMenuBar`, so the welcome
/// panel's net vertical chrome cost matches what we'd have with the
/// IDE shell. Transparent background by default so it sits cleanly
/// above the ambient gradient that paints behind everything.
///
/// Drag is handled by `DragToMoveArea`, which already wires
/// double-click-to-toggle-maximize (see window_manager 0.5.x source).
/// The trailing window controls cluster is `LumenWindowControls`.
class LumenWindowTitleStrip extends StatelessWidget {
  /// Optional leading widget — usually the app name + glyph so the
  /// strip carries some branding rhythm. Pass `null` (the default) for
  /// a pure drag strip.
  final Widget? leading;

  /// Optional override for the strip height. Defaults to 30 to match
  /// the menu bar.
  final double height;

  const LumenWindowTitleStrip({
    super.key,
    this.leading,
    this.height = 30,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: DragToMoveArea(
              child: Container(
                color: Colors.transparent,
                height: height,
              ),
            ),
          ),
          LumenWindowControls(height: height),
        ],
      ),
    );
  }
}

/// Minimal leading-cluster preset for the welcome panel: a tiny
/// `Lumen` lozenge that doubles as a visual anchor and a place for the
/// app name. Kept here (not in `welcome_screen.dart`) so other small
/// surfaces with a title strip can reuse it.
class LumenTitleStripBrand extends StatelessWidget {
  final String label;
  const LumenTitleStripBrand({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w500,
              color: DuckColors.fgMuted,
            ),
          ),
        ],
      ),
    );
  }
}
