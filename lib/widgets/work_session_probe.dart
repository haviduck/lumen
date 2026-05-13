import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../services/work_session_tracker.dart';

/// Feeds the global [WorkSessionTracker] two streams of evidence that
/// the user is *actually here* and *actually working*:
///
/// 1. Pointer events on any descendant of this widget — `onPointerDown`,
///    `onPointerMove`, `onPointerHover`, and `onPointerSignal` (scroll)
///    all count. The `Listener` sits at the very top of the IDE tree
///    so every pane forwards its events through it on the way up.
/// 2. Native window focus/blur events from `window_manager`. Blurring
///    the window pauses counting; focusing resumes it AND bumps the
///    idle clock (focusing is itself an interaction).
///
/// Keyboard events are listened to globally via
/// `HardwareKeyboard.instance.addHandler` so input on focused leaf
/// widgets (terminal, editor, chat composer) still registers — the
/// `Listener` widget above us catches pointer/scroll but not key
/// events that have already been claimed by a deeper focus node.
///
/// Probe failures degrade gracefully — if `window_manager` isn't
/// available (test runs, unusual host), the tracker still ticks; it
/// just never gets a focus signal, which means it assumes the window
/// is always focused. That's the right side to err on for a kind
/// late-night nudge.
class WorkSessionProbe extends StatefulWidget {
  final Widget child;
  const WorkSessionProbe({super.key, required this.child});

  @override
  State<WorkSessionProbe> createState() => _WorkSessionProbeState();
}

class _WorkSessionProbeState extends State<WorkSessionProbe>
    with WindowListener {
  bool _windowManagerBound = false;
  bool _keyboardBound = false;

  bool get _supportsWindowManager =>
      !kIsWeb && (Platform.isWindows || Platform.isMacOS || Platform.isLinux);

  @override
  void initState() {
    super.initState();
    if (_supportsWindowManager) {
      try {
        windowManager.addListener(this);
        _windowManagerBound = true;
      } catch (_) {
        // Plugin missing on this host — fine, the tracker assumes
        // focused-by-default.
      }
    }
    HardwareKeyboard.instance.addHandler(_onKey);
    _keyboardBound = true;
    // Seed the tracker with one synthetic interaction so the first
    // tick after launch counts. Without this, a user who never
    // touches the mouse during the first 30s wouldn't register.
    scheduleMicrotask(() {
      if (!mounted) return;
      context.read<WorkSessionTracker>().recordInteraction();
    });
  }

  @override
  void dispose() {
    if (_windowManagerBound) {
      try {
        windowManager.removeListener(this);
      } catch (_) {
        // Best-effort cleanup; nothing meaningful we can do on
        // teardown failure.
      }
      _windowManagerBound = false;
    }
    if (_keyboardBound) {
      HardwareKeyboard.instance.removeHandler(_onKey);
      _keyboardBound = false;
    }
    super.dispose();
  }

  bool _onKey(KeyEvent _) {
    // Never absorb the event — we are an observer, not a handler.
    final tracker = _trackerOrNull();
    tracker?.recordInteraction();
    return false;
  }

  @override
  void onWindowFocus() {
    _trackerOrNull()?.setWindowFocused(true);
  }

  @override
  void onWindowBlur() {
    _trackerOrNull()?.setWindowFocused(false);
  }

  WorkSessionTracker? _trackerOrNull() {
    if (!mounted) return null;
    try {
      return context.read<WorkSessionTracker>();
    } catch (_) {
      // Provider not in scope yet (very early tree builds). Skip.
      return null;
    }
  }

  void _onPointer(PointerEvent _) {
    _trackerOrNull()?.recordInteraction();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onPointer,
      onPointerMove: _onPointer,
      onPointerHover: _onPointer,
      onPointerSignal: _onPointer,
      child: widget.child,
    );
  }
}
