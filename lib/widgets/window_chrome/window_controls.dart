import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';

/// Replicates the right-cluster of a native Win32 caption — three slim
/// buttons (minimize / maximize-restore / close) that drive
/// `windowManager` directly.
///
/// Designed to slot into a 30 px ribbon (matches `DuckMenuBar` height)
/// alongside menu items + a `DragToMoveArea`. Width-per-button is 44
/// (close-ish to Microsoft's 46 px guideline but trimmer so the row
/// reads as IDE chrome rather than a system caption).
///
/// Rest icons paint at `fgMuted` and brighten to `fgPrimary` on hover;
/// the close button's hover is the standard Windows red wash so muscle
/// memory still works. Listens to `WindowListener` so the maximize
/// glyph swaps to a restore glyph when the window is maximized.
///
/// Width-per-button: 44 px (close-ish to Microsoft's 46 px guideline
/// but trimmer so the row reads as IDE chrome rather than a system
/// caption).
class LumenWindowControls extends StatefulWidget {
  /// Slim variant used inside `DuckMenuBar` and the welcome strip —
  /// 44 x 30. The default footprint matches the menu bar height so the
  /// ribbon stays exactly the same vertical chrome cost as before
  /// (with the native title bar gone, this is the net space win).
  const LumenWindowControls({super.key, this.buttonWidth = 44, this.height = 30});

  final double buttonWidth;
  final double height;

  @override
  State<LumenWindowControls> createState() => _LumenWindowControlsState();
}

class _LumenWindowControlsState extends State<LumenWindowControls>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximizedState();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximizedState() async {
    try {
      final v = await windowManager.isMaximized();
      if (mounted && v != _isMaximized) setState(() => _isMaximized = v);
    } catch (_) {
      // window_manager not usable on this host — degrade silently;
      // buttons still render but the toggle won't reflect state.
    }
  }

  @override
  void onWindowMaximize() => _syncMaximizedState();

  @override
  void onWindowUnmaximize() => _syncMaximizedState();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _CaptionButton(
          width: widget.buttonWidth,
          height: widget.height,
          tooltip: S.windowMinimize,
          iconBuilder: (color) => CustomPaint(
            size: const Size(10, 10),
            painter: _MinimizePainter(color),
          ),
          onTap: () => windowManager.minimize(),
        ),
        _CaptionButton(
          width: widget.buttonWidth,
          height: widget.height,
          tooltip: _isMaximized ? S.windowRestore : S.windowMaximize,
          iconBuilder: (color) => CustomPaint(
            size: const Size(10, 10),
            painter: _isMaximized
                ? _RestorePainter(color)
                : _MaximizePainter(color),
          ),
          onTap: () async {
            if (_isMaximized) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _CaptionButton(
          width: widget.buttonWidth,
          height: widget.height,
          tooltip: S.windowClose,
          isClose: true,
          iconBuilder: (color) => CustomPaint(
            size: const Size(10, 10),
            painter: _ClosePainter(color),
          ),
          // Routes through `windowManager.close()` which the
          // `AppCloseGuard` intercepts (it owns `setPreventClose(true)`).
          // That guard runs the unsaved-changes flow before the window
          // actually destroys — same path as Alt+F4 / the old native
          // X. Don't shortcut to `windowManager.destroy()` here; it
          // would bypass the guard and drop dirty buffers.
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }
}

typedef _IconBuilder = Widget Function(Color color);

class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.width,
    required this.height,
    required this.tooltip,
    required this.iconBuilder,
    required this.onTap,
    this.isClose = false,
  });

  final double width;
  final double height;
  final String tooltip;
  final _IconBuilder iconBuilder;
  final VoidCallback onTap;
  final bool isClose;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // Hover wash mirrors the OS conventions so the buttons still
    // "feel" native even though they're Flutter-painted:
    //   - min/max: subtle bgRaisedHi lift (same as BrightIconButton)
    //   - close:   Windows-red on hover, glyph forced to white for
    //              contrast against the wash
    final Color bg;
    final Color fg;
    if (widget.isClose) {
      bg = _hover
          ? const Color(0xFFC42B1C) // Windows close-hover red
          : Colors.transparent;
      fg = _hover ? Colors.white : DuckColors.fgMuted;
    } else {
      bg = _hover
          ? DuckColors.bgRaisedHi.withValues(alpha: 0.62)
          : Colors.transparent;
      fg = _hover ? DuckColors.fgPrimary : DuckColors.fgMuted;
    }

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: widget.width,
            height: widget.height,
            color: bg,
            alignment: Alignment.center,
            child: widget.iconBuilder(fg),
          ),
        ),
      ),
    );
  }
}

// ---- Glyph painters -------------------------------------------------
//
// Hand-drawn so we get the same crisp 1-pixel lines as Windows' own
// caption glyphs at 100% DPI, without depending on the Material icon
// font (whose `minimize` / `crop_square` glyphs are slightly off-centre
// and stroke-fatter than a native caption). Each painter draws into a
// 10x10 box so the glyph reads cleanly at any DPI scale.

class _MinimizePainter extends CustomPainter {
  _MinimizePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final y = size.height / 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
  }

  @override
  bool shouldRepaint(_MinimizePainter old) => old.color != color;
}

class _MaximizePainter extends CustomPainter {
  _MaximizePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    final rect = Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1);
    canvas.drawRect(rect, paint);
  }

  @override
  bool shouldRepaint(_MaximizePainter old) => old.color != color;
}

class _RestorePainter extends CustomPainter {
  _RestorePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    // Two overlapping rectangles — same glyph the native Windows
    // restore button uses to signal "restore to previous size."
    final front = Rect.fromLTWH(0.5, 2.5, size.width - 3, size.height - 3);
    canvas.drawRect(front, paint);
    final path = Path()
      ..moveTo(2.5, 2.5)
      ..lineTo(2.5, 0.5)
      ..lineTo(size.width - 0.5, 0.5)
      ..lineTo(size.width - 0.5, size.height - 2.5)
      ..lineTo(size.width - 2.5, size.height - 2.5);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_RestorePainter old) => old.color != color;
}

class _ClosePainter extends CustomPainter {
  _ClosePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    canvas.drawLine(
      const Offset(0, 0),
      Offset(size.width, size.height),
      paint,
    );
    canvas.drawLine(
      Offset(size.width, 0),
      Offset(0, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ClosePainter old) => old.color != color;
}
