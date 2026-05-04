import 'dart:async';

import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart' as shelf;

/// Serve the bundled Remote Access PWA (`assets/remote_app/*`) over
/// HTTP so a phone on the LAN/Tailscale can load the chat client by
/// pointing its browser at the desktop's URL — no app store, no
/// `flutter run`, no APK.
///
/// All files are read from `rootBundle` on every request. That's
/// fine for a v1 client (the bundle is small, the browser caches
/// it, and `rootBundle.load` itself caches by key after the first
/// hit). If we ever start serving large media here, swap to a
/// stream reader + Content-Length / range support.
///
/// Handlers are public-by-design — the loaded JS prompts for a
/// pairing code and stores the bearer in `localStorage` itself.
/// Don't put bearer-only routes through this builder.

const Map<String, String> _mime = {
  '.html': 'text/html; charset=utf-8',
  '.css':  'text/css; charset=utf-8',
  '.js':   'application/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.webmanifest': 'application/manifest+json; charset=utf-8',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.txt':  'text/plain; charset=utf-8',
};

const String _bundlePrefix = 'assets/remote_app';

Future<shelf.Response> serveRemoteAppAsset(String relativePath) async {
  // Defense-in-depth: reject anything with traversal segments
  // before touching the bundle. `rootBundle` won't resolve `..`
  // anyway, but a clear 400 here documents the intent.
  if (relativePath.contains('..') || relativePath.contains('\\')) {
    return shelf.Response.forbidden('forbidden');
  }
  final clean = relativePath.startsWith('/')
      ? relativePath.substring(1)
      : relativePath;
  if (clean.isEmpty) {
    return _readAndServe('index.html');
  }
  return _readAndServe(clean);
}

Future<shelf.Response> _readAndServe(String relative) async {
  final key = '$_bundlePrefix/$relative';
  try {
    final data = await rootBundle.load(key);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final ext = _extOf(relative);
    final type = _mime[ext] ?? 'application/octet-stream';
    return shelf.Response.ok(
      bytes,
      headers: {
        'content-type': type,
        // Aggressive cache for static assets. The bundle changes only
        // on Lumen rebuild; clients can `Ctrl+Shift+R` to override.
        // Don't cache the manifest itself or PWA installs may pin a
        // stale theme color.
        if (ext != '.webmanifest')
          'cache-control': 'public, max-age=300',
      },
    );
  } catch (_) {
    return shelf.Response.notFound('not found');
  }
}

String _extOf(String path) {
  final i = path.lastIndexOf('.');
  if (i < 0) return '';
  return path.substring(i).toLowerCase();
}

/// 302-redirect the bare host (`http://lumen-host:port/`) to
/// `/app/`. Browsers typing in just the IP get the chat client
/// without the user having to remember the path.
shelf.Response redirectRootToApp(shelf.Request req) {
  return shelf.Response.found('/app/');
}
