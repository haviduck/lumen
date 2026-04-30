import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// SNAPSHOT_URL delivery decision (intentional, documented).
///
/// We deliver captures **inline** on the next API turn via the executor's
/// new `imageAttachments` side-channel (see `ToolPassResult`), AND save a
/// debug copy to disk under `<app-support>/snapshots/<ts>.png`.
///
/// Why inline:
/// - The whole point of the tool is "let the multimodal model see the page".
///   Saving to disk and emitting a path requires the agent to call READ_FILE,
///   which only returns text — useless for binary PNG. The agent would just
///   loop helplessly.
/// - The chat controller already plumbs `images: [base64...]` on user
///   messages for multimodal Ollama, so reusing that channel is one extra
///   field on `ToolPassResult` and one if-statement in the chat loop.
///
/// The disk copy is a quality-of-life thing: lets the user inspect captures
/// in Explorer, and is a sanity check while developing.
class SnapshotResult {
  final bool ok;
  final String message;
  final String? base64Png;
  final String? savedPath;

  const SnapshotResult({
    required this.ok,
    required this.message,
    this.base64Png,
    this.savedPath,
  });
}

/// Function signature provided by [SnapshotHost] when it mounts. The host
/// owns the actual `webview_windows` controller and knows how to insert an
/// off-stage Webview into the IDE shell's overlay; the service is just a
/// dumb singleton bridge so the tool executor can find it.
typedef SnapshotImpl = Future<SnapshotResult> Function(
  String url, {
  Duration timeout,
});

/// Singleton bridge between [SnapshotHost] (which lives in the widget tree)
/// and tool execution code (which has no BuildContext). The host registers
/// a [SnapshotImpl] in `initState`; the SNAPSHOT_URL tool calls
/// [capture] which delegates.
class SnapshotService {
  SnapshotService._();
  static final SnapshotService instance = SnapshotService._();

  SnapshotImpl? _impl;

  void registerImpl(SnapshotImpl impl) {
    _impl = impl;
  }

  void unregisterImpl(SnapshotImpl impl) {
    if (identical(_impl, impl)) _impl = null;
  }

  bool get isRegistered => _impl != null;

  Future<SnapshotResult> capture(
    String url, {
    Duration timeout = const Duration(seconds: 25),
  }) async {
    final impl = _impl;
    if (impl == null) {
      return const SnapshotResult(
        ok: false,
        message:
            'Snapshot host not mounted. Open the AI chat once so the '
            'in-process WebView can attach, then retry.',
      );
    }
    try {
      return await impl(url, timeout: timeout);
    } catch (e) {
      return SnapshotResult(ok: false, message: 'capture threw: $e');
    }
  }

  /// Persists a freshly-captured PNG under
  /// `<app-support>/snapshots/<unix-ms>.png`. Returns the full path on
  /// success, `null` on any IO failure (we never want a disk error to
  /// fail the whole capture).
  static Future<String?> persistDebugCopy(Uint8List png) async {
    try {
      final dir = await getApplicationSupportDirectory();
      final out = Directory(p.join(dir.path, 'snapshots'));
      await out.create(recursive: true);
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = p.join(out.path, '$ts.png');
      await File(path).writeAsBytes(png, flush: true);
      return path;
    } catch (e) {
      debugPrint('SnapshotService.persistDebugCopy failed: $e');
      return null;
    }
  }

  /// Convenience for tests / future callers that already have raw bytes.
  static String encodeBase64(Uint8List bytes) => base64Encode(bytes);
}
