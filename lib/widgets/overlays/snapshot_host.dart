import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../services/snapshot_service.dart';

/// Off-stage Webview host for the SNAPSHOT_URL tool.
///
/// Mounting strategy: this is a tiny invisible widget that lives inside the
/// chat panel (`AiChat`). On `initState` it registers a [SnapshotImpl] with
/// [SnapshotService.instance]. When the SNAPSHOT_URL tool fires, the impl:
///   1. Inserts an [OverlayEntry] containing an off-stage `Webview` widget
///      into the nearest `Overlay` (provided by the IDE Scaffold).
///   2. Loads the URL, waits for `LoadingState.navigationCompleted`, then
///      gives the renderer 800ms to actually paint the first frame —
///      navigationCompleted fires before the texture has anything in it.
///   3. Captures via `RenderRepaintBoundary.toImage`, encodes PNG, base64s
///      and returns. Persists a debug copy to disk too.
///   4. Removes the overlay entry.
///
/// The WebviewController is created lazily per-capture and disposed after.
/// We don't cache it — webview_windows controllers occasionally lock up
/// when reused for a navigation to a totally different origin, and the
/// per-capture init cost is in the same order of magnitude as the network
/// fetch we're about to do anyway.
class SnapshotHost extends StatefulWidget {
  const SnapshotHost({super.key});

  @override
  State<SnapshotHost> createState() => _SnapshotHostState();
}

class _SnapshotHostState extends State<SnapshotHost> {
  late final SnapshotImpl _impl;

  @override
  void initState() {
    super.initState();
    _impl = _capture;
    SnapshotService.instance.registerImpl(_impl);
  }

  @override
  void dispose() {
    SnapshotService.instance.unregisterImpl(_impl);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Future<SnapshotResult> _capture(
    String url, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    if (!Platform.isWindows) {
      return const SnapshotResult(
        ok: false,
        message: 'webview_windows is Windows-only; SNAPSHOT_URL is unsupported '
            'on this platform.',
      );
    }
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) {
      return const SnapshotResult(
        ok: false,
        message: 'No Overlay available — IDE shell not yet mounted.',
      );
    }

    final controller = WebviewController();
    final boundaryKey = GlobalKey();
    OverlayEntry? entry;
    final readyForCapture = Completer<void>();
    final navCompleted = Completer<void>();
    StreamSubscription<LoadingState>? loadingSub;
    StreamSubscription? errorSub;

    try {
      await controller.initialize().timeout(const Duration(seconds: 15));
    } catch (e) {
      controller.dispose();
      final hint = e.toString().toLowerCase().contains('webview2')
          ? ' Install the Microsoft Edge WebView2 Runtime and retry.'
          : '';
      return SnapshotResult(
        ok: false,
        message: 'WebView2 init failed: $e.$hint',
      );
    }

    loadingSub = controller.loadingState.listen((state) {
      if (state == LoadingState.navigationCompleted &&
          !navCompleted.isCompleted) {
        navCompleted.complete();
      }
    });
    errorSub = controller.onLoadError.listen((status) {
      if (!navCompleted.isCompleted) {
        navCompleted.completeError(StateError('navigation error: $status'));
      }
    });

    try {
      entry = OverlayEntry(
        builder: (_) {
          // 1280x800 matches the constraint we want to feed the model;
          // putting it offscreen keeps it from flashing into the user's
          // viewport for the second or two it lives.
          return Positioned(
            left: -2000,
            top: -2000,
            width: 1280,
            height: 800,
            child: IgnorePointer(
              child: RepaintBoundary(
                key: boundaryKey,
                child: SizedBox(
                  width: 1280,
                  height: 800,
                  child: Webview(controller),
                ),
              ),
            ),
          );
        },
      );
      overlay.insert(entry);

      // The Webview widget reports its surface size in a postFrameCallback,
      // which only runs after the entry is mounted. Without this delay
      // loadUrl can be issued before the renderer knows its viewport size,
      // leading to 0x0 captures.
      await Future<void>.delayed(const Duration(milliseconds: 80));

      await controller.loadUrl(url);

      await navCompleted.future.timeout(timeout, onTimeout: () {
        throw TimeoutException(
          'navigation did not complete within ${timeout.inSeconds}s',
        );
      });

      // navigationCompleted fires before the first frame paints into the
      // shared D3D texture — measured ~600ms on this machine. 800ms is a
      // safe-ish floor for sites that finish layout immediately; richer
      // SPAs may still produce partially-rendered captures, which is an
      // acceptable trade-off vs. bolting a polling JS shim into every
      // page.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      readyForCapture.complete();

      final boundary = boundaryKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        return const SnapshotResult(
          ok: false,
          message: 'Boundary detached before capture.',
        );
      }
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) {
        return const SnapshotResult(
          ok: false,
          message: 'toByteData returned null (texture not yet rasterised).',
        );
      }
      final png = bytes.buffer.asUint8List();
      final saved = await SnapshotService.persistDebugCopy(png);
      return SnapshotResult(
        ok: true,
        message: 'Captured ${png.length ~/ 1024}KB at 1280x800.',
        base64Png: SnapshotService.encodeBase64(png),
        savedPath: saved,
      );
    } on TimeoutException catch (e) {
      return SnapshotResult(ok: false, message: e.message ?? 'timeout');
    } catch (e) {
      return SnapshotResult(ok: false, message: 'capture failed: $e');
    } finally {
      await loadingSub.cancel();
      await errorSub.cancel();
      entry?.remove();
      try {
        await controller.dispose();
      } catch (_) {
        // dispose throws if initialize never resolved; we don't care here.
      }
    }
  }
}
