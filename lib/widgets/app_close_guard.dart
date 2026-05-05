import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import 'common/duck_toast.dart';
import 'editor/unsaved_changes_dialog.dart';

/// Wraps the root navigator and intercepts the native window-close
/// intent so the user gets a Save / Don't Save / Cancel prompt before
/// losing unsaved buffer state.
///
/// All close affordances funnel through here:
/// - The OS-level title bar X (any layout)
/// - Alt+F4 / Cmd+Q
/// - The welcome panel's in-card close button
///   (`WindowChrome.close()` → `windowManager.close()`)
///
/// Mechanism: on mount, we flip `windowManager.setPreventClose(true)`
/// and register a `WindowListener`. Every native close attempt fires
/// `onWindowClose` instead of actually closing. Once the user has
/// chosen Save All / Don't Save (or there were no dirty buffers),
/// we drop the prevent-flag and call `windowManager.destroy()` —
/// `destroy()` skips the close-event handler so we don't recurse.
///
/// The dirty-buffer flow mirrors the existing tab-close "Close All"
/// path in `widgets/editor/editor.dart::_closeBatch`: untitled tabs
/// in a Save All batch can't be auto-saved (we'd need a save-as
/// picker per tab); when any are present we toast the user and
/// abort the close so they can save manually first.
class AppCloseGuard extends StatefulWidget {
  final Widget child;
  const AppCloseGuard({super.key, required this.child});

  @override
  State<AppCloseGuard> createState() => _AppCloseGuardState();
}

class _AppCloseGuardState extends State<AppCloseGuard> with WindowListener {
  // Re-entrancy guard. Some platforms can re-fire `onWindowClose`
  // (or the user can mash the X button mid-dialog); without this the
  // batch dialog would stack on itself.
  bool _prompting = false;

  @override
  void initState() {
    super.initState();
    if (_isWindowManagerSupported) {
      windowManager.addListener(this);
      // Fire-and-forget — failure means the plugin isn't usable on
      // this host, in which case the OS owns close anyway.
      unawaited(windowManager.setPreventClose(true));
    }
  }

  @override
  void dispose() {
    if (_isWindowManagerSupported) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    if (_prompting) return;
    _handleClose();
  }

  Future<void> _handleClose() async {
    _prompting = true;
    try {
      final state = context.read<AppState>();
      final dirty = state.openFiles
          .where((f) => state.isFileDirty(f.path))
          .toList(growable: false);

      if (dirty.isEmpty) {
        await _closeForReal();
        return;
      }

      if (!mounted) return;
      final choice = await showBatchUnsavedChangesDialog(
        context,
        dirtyFiles: dirty,
      );
      if (!mounted) return;

      switch (choice) {
        case BatchUnsavedChangesChoice.cancel:
          return;
        case BatchUnsavedChangesChoice.discardAll:
          await _closeForReal();
          return;
        case BatchUnsavedChangesChoice.saveAll:
          final keptUntitled = <File>[];
          for (final f in dirty) {
            if (AppState.isUntitledTab(f.path)) {
              keptUntitled.add(f);
              continue;
            }
            await state.saveFileByPath(f.path);
          }
          if (!mounted) return;
          if (keptUntitled.isNotEmpty) {
            // Same contract as `_closeBatch`: refuse to silently
            // discard untitled buffers when the user picked
            // "Save All". The toast points them at Save As; they
            // can re-trigger the close once handled.
            showDuckToast(
              context,
              S.unsavedBatchUntitledSkipped(keptUntitled.length),
            );
            return;
          }
          await _closeForReal();
          return;
      }
    } finally {
      _prompting = false;
    }
  }

  Future<void> _closeForReal() async {
    if (!_isWindowManagerSupported) return;
    await windowManager.setPreventClose(false);
    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) => widget.child;

  static bool get _isWindowManagerSupported {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.linux;
  }
}
