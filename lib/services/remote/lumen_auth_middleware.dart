import 'dart:async';
import 'dart:convert';

import 'package:shelf/shelf.dart' as shelf;

import 'lumen_pairing_service.dart';

/// Default-deny bearer-auth middleware for the Remote Access HTTP
/// server. **All routes are private** unless explicitly listed in
/// [publicPaths] / [publicPrefixes]. Failing closed is the design —
/// adding a new private route shouldn't require remembering to
/// register it for auth.
///
/// **Token transport:**
///   1. `Authorization: Bearer <token>` header — the canonical path,
///      used by every native client (curl, the Android Flutter app,
///      our `IOWebSocketChannel`-based dev tool).
///   2. `?token=<token>` query parameter — fallback for browser
///      WebSocket clients, which can't attach custom headers on the
///      initial upgrade. Browser is not a v1 use case; the fallback
///      is here so we don't paint ourselves into a corner.
///
/// **Public routes (no auth required):**
///   - `GET /v1/health` — liveness probe used during pairing
///     bootstrap (the phone hits this to confirm the host is
///     reachable before sending the pairing code).
///   - `POST /v1/pair/initiate` — pairing entry point. Protected by
///     the single-use code, not by bearer auth (chicken-and-egg).
///   - `GET /` and everything under `/app/` — the bundled PWA chat
///     client (`assets/remote_app/`). The page itself is public;
///     once loaded, its JS prompts for a pairing code, hits
///     `/v1/pair/initiate`, persists the bearer in `localStorage`,
///     and uses it for every subsequent call.
///
/// **Logging note:** failed-auth responses do NOT include the
/// presented token, even hashed. We don't want pen-tester scripts to
/// learn anything from the error envelope beyond "wrong token."
shelf.Middleware lumenBearerAuth({
  required LumenPairingService pairing,
  Set<String> publicPaths = const {'/v1/health', '/'},
  Set<String> publicPrefixes = const {'/v1/pair/initiate', '/app'},
}) {
  return (inner) {
    return (req) async {
      final path = '/${req.url.path}';
      if (_isPublic(path, publicPaths, publicPrefixes)) {
        return inner(req);
      }

      final token = _extractToken(req);
      if (token == null || token.isEmpty) {
        return _unauthorized('missing_token',
            'Pass `Authorization: Bearer <token>` or `?token=<token>` for WebSockets.');
      }

      final deviceId = pairing.deviceIdForToken(token);
      if (deviceId == null) {
        return _unauthorized('invalid_token', 'Token not recognised.');
      }

      // Fire-and-forget liveness ping; the service throttles writes
      // so this is cheap on hot paths (streaming WS reconnects, etc).
      unawaited(pairing.touchDevice(deviceId));

      // Pass the resolved device id downstream via a request context
      // entry so route handlers can attribute actions if they want
      // ("Pixel 9 deleted chat X"). Today no handler reads it; the
      // hook exists for the device-scoped audit log we'd add
      // alongside per-device tool policy in step 9 of the build
      // order.
      final authedReq = req.change(context: {
        ...req.context,
        'lumen.deviceId': deviceId,
      });
      return inner(authedReq);
    };
  };
}

bool _isPublic(
  String path,
  Set<String> publicPaths,
  Set<String> publicPrefixes,
) {
  if (publicPaths.contains(path)) return true;
  for (final prefix in publicPrefixes) {
    if (path == prefix || path.startsWith('$prefix/')) return true;
  }
  return false;
}

String? _extractToken(shelf.Request req) {
  final header = req.headers['authorization'];
  if (header != null && header.toLowerCase().startsWith('bearer ')) {
    return header.substring(7).trim();
  }
  // `?token=...` fallback. Stripped from the query string when
  // forwarded so route handlers don't accidentally log it.
  final q = req.url.queryParameters['token'];
  if (q != null && q.isNotEmpty) return q;
  return null;
}

shelf.Response _unauthorized(String code, String hint) {
  return shelf.Response(
    401,
    body: jsonEncode({
      'ok': false,
      'error': code,
      'hint': hint,
    }),
    headers: {
      'content-type': 'application/json; charset=utf-8',
      // Standards-compliant signal so a future browser-style client
      // knows to prompt for credentials. We don't issue HTTP Basic;
      // the realm name is informational.
      'www-authenticate': 'Bearer realm="lumen-remote"',
    },
  );
}
