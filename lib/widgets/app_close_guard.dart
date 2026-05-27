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
import 'shutdown_overlay.dart';

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
    // Tear down every running PTY / node child the IDE spawned BEFORE
    // we ask window_manager to destroy. `destroy()` skips Flutter's
    // framework dispose chain, so anything left running at this point
    // would outlive the parent process (Windows reparents the orphans
    // to PID 0 and they keep squatting on ports / file handles).
    //
    // The shutdown sequence is the same as before, but each step is
    // now gated on a cheap "is there anything to do" check so a
    // welcome-screen close (no terminals ever opened, no Copilot
    // bridge ever started) doesn't wait through up-to-multiple-second
    // timeouts on operations that would be pure no-ops. When any
    // step has real work, we mount a "Shutting down…" overlay so
    // the user gets feedback instead of staring at a frozen window
    // during the cleanup.
    if (!mounted) {
      if (!_isWindowManagerSupported) return;
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
      return;
    }
    final app = context.read<AppState>();

    // What actually needs doing?
    //   - Terminal sweep — has agent bridge sessions OR the
    //     terminal pane is registered (workspace open).
    //   - PID sweep — tracker has at least one direct PID.
    //   - Copilot dispose — bridge subprocess is running.
    //   - Log flush — always cheap; instant when buffer is empty.
    final hasTerminals = app.agentTerminals.hasActiveSessions ||
        app.ideActions.hasTerminal;
    final hasTrackedPids = app.lumenProcesses.hasTrackedPids;
    final hasCopilot = app.copilotService.isActive;
    final realWork = hasTerminals || hasTrackedPids || hasCopilot;

    OverlayEntry? overlayEntry;
    final stepNotifier = ValueNotifier<String?>(null);
    if (realWork) {
      // Mount the overlay on the root navigator so it sits above
      // the welcome screen, the editor pane, the chat panel, every
      // dialog — anything still painting. Held in a local so we
      // can null-guard removal without leaking state when this
      // method exits.
      final overlay = Overlay.maybeOf(context, rootOverlay: true);
      if (overlay != null) {
        overlayEntry = OverlayEntry(
          builder: (_) => ValueListenableBuilder<String?>(
            valueListenable: stepNotifier,
            builder: (_, step, _) => ShutdownOverlay(step: step),
          ),
        );
        overlay.insert(overlayEntry);
        // Give the framework one frame to paint the overlay before
        // we block the UI thread on any cleanup work.
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    }

    if (hasTerminals || hasTrackedPids) {
      stepNotifier.value = S.shutdownStepTerminals;
      try {
        await app.shutdownAllTerminals(killTrackedPids: hasTrackedPids);
      } catch (_) {
        // proceed to destroy regardless
      }
    }
    if (hasCopilot) {
      stepNotifier.value = S.shutdownStepCopilot;
      try {
        await app.copilotService.dispose().timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      } catch (_) {
        // proceed to destroy regardless
      }
    }
    // Always flush the LLM usage log — empty buffers fall through
    // in microseconds, so there's no "skip" branch worth the
    // complexity. If the buffer DID have entries, briefly surface
    // that in the overlay (when one's mounted) so the user knows
    // why their token-usage dashboard might lag for a split second.
    try {
      final pendingFlush = app.llmUsageLog.flush().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      if (realWork) {
        stepNotifier.value = S.shutdownStepUsageLog;
      }
      await pendingFlush;
    } catch (_) {
      // proceed to destroy regardless
    }

    overlayEntry?.remove();
    stepNotifier.dispose();

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
