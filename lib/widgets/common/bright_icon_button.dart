import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Cursor-style sidebar / toolbar icon button.
///
/// Outlined glyph on a transparent chip; hover lifts both the bg
/// (`bgRaisedHi @ 0.62 alpha`) and the icon colour (rest →
/// `fgPrimary`) over `DuckMotion.fast`. Disabled state drops to
/// `fgFaint` and skips the lift, mirroring how menu-bar dropdown
/// items disable themselves.
///
/// **Rest colour is `fgMuted`, not `fgPrimary`.** Earlier this widget
/// painted glyphs at full pearl-white intensity which read as too
/// strong against the muted chrome — Cursor's sidebar / activity bar
/// uses the same "muted by default, brighten on hover" pattern. The
/// effect is visually equivalent to lowering CSS `font-weight` from
/// 600 to 400. (Material's legacy icon font has no stroke-weight
/// axis, so colour intensity is the only knob; the variable
/// Material Symbols font would give us real stroke weight but
/// switching the entire icon set is out of scope here.)
///
/// Used by:
/// - `DuckMenuBar` right cluster (settings cog)
/// - `FileExplorer` activity-bar strip (settings, search, media,
///   teams, history, vibe-check)
///
/// When tweaking visuals (icon size, hover alpha, padding), update
/// here exactly once — both call sites pick up the change.
class BrightIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool enabled;

  /// Override the default icon size. Most call sites should keep the
  /// default — bumping it here breaks the bar's visual rhythm.
  final double iconSize;

  const BrightIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.iconSize = 16,
  });

  @override
  State<BrightIconButton> createState() => _BrightIconButtonState();
}

class _BrightIconButtonState extends State<BrightIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final Color color;
    if (!widget.enabled) {
      color = DuckColors.fgFaint;
    } else {
      color = _hover ? DuckColors.fgPrimary : DuckColors.fgMuted;
    }
    final hoverable = widget.enabled;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: hoverable
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) {
          if (hoverable) setState(() => _hover = true);
        },
        onExit: (_) {
          if (_hover) setState(() => _hover = false);
        },
        child: GestureDetector(
          onTap: widget.enabled ? widget.onTap : null,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: _hover
                  ? DuckColors.bgRaisedHi.withValues(alpha: 0.62)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Icon(widget.icon, size: widget.iconSize, color: color),
          ),
        ),
      ),
    );
  }
}
