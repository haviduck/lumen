import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show SystemNavigator;
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

/// Owns the native-window size + chrome transitions across Lumen's two
/// macro-states:
///
///   1. **Welcome screen** — small panel-sized window (~700x560), centred
///      on the primary monitor. The welcome panel IS the window; there's
///      no maximised void around it.
///   2. **Workspace open** — maximised window so the IDE shell has room
///      for the editor / terminal / chat panes.
///
/// `bootstrap()` runs ONCE from `main()` before `runApp` and configures
/// the initial chrome (size + min-size + centred). After that, the IDE
/// transitions are driven by `enterWorkspaceLayout` / `enterWelcomeLayout`,
/// which AppState calls when `currentDirectory` flips.
///
/// The C++ runner (`windows/runner/main.cpp`) starts the window at the
/// welcome size with `SW_SHOWNORMAL`, so Lumen never paints a maximised
/// blank background around a tiny centred card. The transitions below
/// take it from there.
class WindowChrome {
  WindowChrome._();

  /// Welcome-screen size. Chosen to fit the panel content tightly: the
  /// branding + Open Folder / New Project / Recent list. Shrinks below
  /// this still works because we set a generous min on the OS side.
  static const Size welcomeSize = Size(700, 560);

  /// Minimum interactive size. Below this the welcome panel starts to
  /// look like a phone notification, but the OS shouldn't refuse the
  /// user's drag — the C++ side floors at (480, 360) and we mirror it
  /// here so window_manager's enforcement matches.
  static const Size minWindowSize = Size(480, 360);

  static bool _initialized = false;
  static bool _isWelcomeLayout = true;

  /// Whether bootstrap() has run successfully. False on platforms that
  /// don't support `window_manager` or when running under a test
  /// harness where `ensureInitialized()` would throw.
  static bool get isReady => _initialized;

  /// Whether we're currently in the welcome-layout (small) state. Used
  /// by the AppState listener to decide whether a transition is needed.
  static bool get isWelcomeLayout => _isWelcomeLayout;

  /// Configures the native window for the welcome screen and shows it.
  /// Call from `main()` after `WidgetsFlutterBinding.ensureInitialized()`
  /// and before `runApp`. Idempotent; safe to call from a hot-restart.
  static Future<void> bootstrap() async {
    if (_initialized) return;
    if (!_isSupported) {
      // Mobile / web: window_manager isn't a thing. Lumen targets
      // Windows desktop today, but the welcome flow itself doesn't
      // care about window chrome — let the rest of the app boot
      // unaltered.
      _initialized = true;
      return;
    }
    try {
      await windowManager.ensureInitialized();
      // We deliberately do NOT call `windowManager.show()` here even
      // though that's the textbook pattern. Lumen's C++ runner
      // (`flutter_window.cpp`) hooks `engine.SetNextFrameCallback`
      // and calls `Win32Window::Show()` only after Flutter renders
      // its first frame. Calling `show()` here would reveal the
      // native HWND before Flutter paints, producing a brief
      // flash of the default Win32 background colour. Let C++ own
      // the first-show timing; we only configure size + position
      // + min ahead of that reveal so the window appears at the
      // correct welcome footprint immediately, no resize jank.
      await windowManager.setMinimumSize(minWindowSize);
      await windowManager.setSize(welcomeSize);
      await windowManager.center();
      _initialized = true;
    } catch (e, st) {
      debugPrint('WindowChrome.bootstrap failed: $e\n$st');
      // Don't crash boot — the C++ side already created a sensibly-
      // sized window, the user just won't get the centred-on-show
      // polish or the welcome→workspace transition.
      _initialized = true;
    }
  }

  /// Switch to the IDE-shell layout. Maximises the window so panes
  /// have room, raises the minimum size so the IDE chrome stays
  /// usable, and brings the window forward in case it lost focus
  /// during workspace setup. Best-effort — failures are logged but
  /// never bubble up to the caller. If the user has manually
  /// resized the window themselves we still maximise on the
  /// welcome→workspace transition; that's the expected behaviour
  /// (the IDE shell wants room) and the user can un-maximise after.
  static Future<void> enterWorkspaceLayout() async {
    if (!_isSupported || !_initialized) return;
    if (!_isWelcomeLayout) return;
    _isWelcomeLayout = false;
    try {
      // Raise the floor so dragging the IDE shell to a tiny strip
      // doesn't break panel layouts. The welcome floor (480x360)
      // is too low for a usable editor + chat side-by-side.
      await windowManager.setMinimumSize(const Size(900, 560));
      final isMaximized = await windowManager.isMaximized();
      if (!isMaximized) {
        await windowManager.maximize();
      }
    } catch (e, st) {
      debugPrint('WindowChrome.enterWorkspaceLayout failed: $e\n$st');
    }
  }

  /// Inverse of [enterWorkspaceLayout] — used if the user closes the
  /// active workspace and returns to the welcome screen. Today there
  /// is no UI affordance for that flow (closing the workspace means
  /// closing the app), but wiring this up keeps the mental model
  /// symmetric for when one lands.
  static Future<void> enterWelcomeLayout() async {
    if (!_isSupported || !_initialized) return;
    if (_isWelcomeLayout) return;
    _isWelcomeLayout = true;
    try {
      await windowManager.setMinimumSize(minWindowSize);
      final isMaximized = await windowManager.isMaximized();
      if (isMaximized) {
        await windowManager.unmaximize();
      }
      await windowManager.setSize(welcomeSize);
      await windowManager.center();
    } catch (e, st) {
      debugPrint('WindowChrome.enterWelcomeLayout failed: $e\n$st');
    }
  }

  /// Closes the application window. Used by the welcome screen's
  /// close (X) affordance — the welcome screen has no native title
  /// bar in this layout to call its own close button, so the panel
  /// owns the close action.
  static Future<void> close() async {
    if (_isSupported && _initialized) {
      try {
        await windowManager.close();
        return;
      } catch (e, st) {
        debugPrint('WindowChrome.close failed: $e\n$st');
      }
    }
    // Fallback: graceful shutdown via the framework's pop. Won't
    // close on every host but is correct on supported targets.
    SystemNavigator.pop();
  }

  static bool get _isSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}
