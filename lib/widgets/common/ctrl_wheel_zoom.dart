import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps an IDE pane so `Ctrl + mouse-wheel` bumps that pane's text
/// size up or down — same gesture VS Code, Cursor and Sublime use for
/// quick readability tweaks.
///
/// The mechanic worth flagging: Flutter dispatches pointer-signal
/// events along the hit-test path leaf-to-root. The first widget to
/// call `PointerSignalResolver.register` for an event wins and other
/// callbacks are dropped — so a naive outer `Listener` ALWAYS loses
/// against an inner `Scrollable` (which always registers for scroll
/// events). To win the race we mount a translucent `Listener` on top
/// of the panel inside a `Stack`. Stack hit-tests its children in
/// reverse paint order (top z first); the top child registers its
/// pointer-signal callback BEFORE the scrollable beneath has been
/// visited, so Ctrl+wheel reliably zooms without scrolling. Without
/// Ctrl held we don't register at all and the scrollable handles the
/// event normally.
///
/// [onZoom] receives `+1` for wheel-up (zoom in) and `-1` for
/// wheel-down (zoom out). Trackpad pinches synthesize PointerScroll
/// events on Windows and route through the same path.
class CtrlWheelZoom extends StatelessWidget {
  const CtrlWheelZoom({
    super.key,
    required this.child,
    required this.onZoom,
  });

  final Widget child;
  final void Function(int direction) onZoom;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        Positioned.fill(
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerSignal: (event) {
              if (event is! PointerScrollEvent) return;
              if (!HardwareKeyboard.instance.isControlPressed) return;
              GestureBinding.instance.pointerSignalResolver.register(
                event,
                (PointerSignalEvent resolved) {
                  if (resolved is! PointerScrollEvent) return;
                  final dy = resolved.scrollDelta.dy;
                  if (dy == 0) return;
                  onZoom(dy < 0 ? 1 : -1);
                },
              );
            },
            child: const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
