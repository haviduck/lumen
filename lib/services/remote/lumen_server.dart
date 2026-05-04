import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

import '../../providers/chat_controller.dart';
import '../chat_persistence_service.dart';
import '../preferences_service.dart';
import 'lumen_auth_middleware.dart';
import 'lumen_event_bus.dart';
import 'lumen_pairing_service.dart';
import 'lumen_routes.dart';

/// In-process HTTP server that exposes Lumen to paired remote devices
/// (phones, tablets) over LAN or Tailscale.
///
/// **Status: foundation only.** v1 ships an unauthenticated `/v1/health`
/// endpoint bound to `127.0.0.1` so we can validate the lifecycle, the
/// settings toggle, and the protocol shape end-to-end before adding the
/// data API, TLS, pairing, and bearer auth in follow-up passes.
///
/// **Don't expose this to `0.0.0.0` until pairing/bearer auth land** —
/// the data endpoints would leak chat history and provider keys
/// otherwise. The current bind is loopback-only by design; callers
/// (settings UI) MUST NOT add a "bind to LAN" toggle before the auth
/// pass has shipped.
///
/// Lifetime is bound to [AppState]: constructed once, started/stopped
/// by toggling [setEnabled], disposed when the IDE shuts down. The
/// pref `remoteAccess.enabled` decides whether the server boots on
/// app start.
class LumenServer extends ChangeNotifier {
  LumenServer({
    required this.prefs,
    required this.persistence,
    required this.currentDirectory,
    required this.recentProjects,
    required this.chatController,
  }) {
    // The pairing service is a child notifier of this server — when
    // the user pairs/revokes a device the settings panel should
    // re-render. We forward the notification so a single
    // `AnimatedBuilder(animation: state.remote, ...)` covers both
    // server lifecycle changes and pairing changes without making
    // the panel subscribe to two notifiers.
    pairing.addListener(notifyListeners);
  }

  final PreferencesService prefs;
  // Deps the route layer needs. Held as fields rather than a single
  // `LumenRemoteDeps` aggregate so the call site (AppState) can pass
  // simple constructor args; we assemble the aggregate on demand
  // inside `_buildRouter`. Read closures are evaluated per request,
  // so a workspace switch surfaces immediately.
  final ChatPersistenceService persistence;
  final String? Function() currentDirectory;
  final List<String> Function() recentProjects;
  // Lazy reference to the chat controller. Only mutating routes
  // dereference this — the read API never touches it. Held as a
  // closure so the deps aggregate can be assembled before the
  // controller's `init` has run; v1 callers pass `() => appState.chat`
  // and the resolution happens per-request.
  final ChatController Function() chatController;
  // Live-event fan-out. Constructed eagerly so `/v1/stream` can
  // accept connections even before a `ChatController` has been
  // attached — the client just won't see any state diffs until
  // [eventBus.attach] runs from `AppState._bootstrap`. Exposed so
  // the owning [AppState] can call `attach`/`detach` without
  // reaching through a private field.
  final LumenEventBus eventBus = LumenEventBus();

  HttpServer? _httpServer;
  bool _enabled = false;
  bool _bindAll = false;
  bool _starting = false;
  String? _lastError;
  String _instanceId = '';
  // Sticky-port memory. We try this port first on each [_start] so the
  // URL the user copy-pasted last session still works after an IDE
  // restart. Falls back to OS-chosen (port 0) if the bind fails — the
  // collision case is real (another Lumen install on the same machine,
  // a transient dev server holding the slot). Persisted via the
  // `remoteAccess.lastPort` pref key.
  int? _preferredPort;
  // Pairing + bearer-auth backend. Constructed eagerly so the
  // settings UI can list paired devices even before the HTTP server
  // boots, and so a "Show pairing code" click works whether or not
  // the bind has happened yet (the routes use the same instance).
  // Init runs once via [init] alongside server boot.
  final LumenPairingService pairing = LumenPairingService();

  /// Persisted across sessions. Mirrors `prefs.remoteAccess.enabled` —
  /// the prefs read happens in [init].
  bool get enabled => _enabled;

  /// When true, the server binds to all interfaces (LAN + Tailscale)
  /// instead of loopback. Persisted as `remoteAccess.bindAll`.
  /// Defaulted to `false` so a single click on the master toggle
  /// keeps the server local-only; flipping this on is an explicit
  /// second decision. Bearer auth still gates every non-public
  /// route either way — opening the bind without paired devices
  /// gives you a server nothing can talk to.
  bool get bindAll => _bindAll;

  /// True while a start/stop cycle is in flight. UI should disable the
  /// toggle and show a spinner.
  bool get isBusy => _starting;

  /// True once the server is accepting connections. Independent of
  /// [enabled] for one frame around [setEnabled] toggles.
  bool get isRunning => _httpServer != null;

  /// Resolved bind address — only meaningful while [isRunning].
  /// `127.0.0.1` when `bindAll` is false; `0.0.0.0` when true.
  /// `0.0.0.0` is reachable on every local interface; the Settings
  /// panel composes user-friendly URLs (LAN IP, Tailscale IP) from
  /// the resolved port + the OS's interface list when bound to all.
  String? get boundHost => _httpServer?.address.address;

  /// Resolved port — only meaningful while [isRunning]. The server
  /// binds to port `0` (OS-chosen) so two Lumen installs on the same
  /// machine can run side-by-side without a port-conflict toggle.
  int? get boundPort => _httpServer?.port;

  /// Last failure surfaced to the user (cleared on the next successful
  /// start). The settings panel renders this inline rather than via a
  /// transient toast so the user can copy-paste it.
  String? get lastError => _lastError;

  /// Stable per-install identifier. 16 random bytes hex-encoded,
  /// generated on first run and persisted under the app support dir
  /// next to chat data. Lets paired clients detect "the hostname is
  /// the same but the underlying instance changed" (machine reimage,
  /// Lumen reinstall) and force a re-pair.
  String get instanceId => _instanceId;

  /// Friendly name shown to remote clients during pairing. v1 returns
  /// the OS hostname; a future pref will let the user override it
  /// (e.g. `"Camille's desk"`).
  String get instanceName => Platform.localHostname;

  /// Read pref + instance id, then auto-start if the user previously
  /// enabled the feature. Errors during auto-start surface via
  /// [lastError] rather than throwing — we don't want a stale
  /// network-bind failure to block the IDE from booting.
  Future<void> init() async {
    _instanceId = await _loadOrCreateInstanceId();
    _preferredPort = await prefs.getRemoteAccessLastPort();
    _enabled = await prefs.getRemoteAccessEnabled();
    _bindAll = await prefs.getRemoteAccessBindAll();
    // Pairing service init reads the on-disk paired-devices file.
    // Cheap (single small JSON read) and only matters if the server
    // ends up running, but we always do it so the settings UI's
    // device list works even before the toggle flips on.
    await pairing.init();
    notifyListeners();
    if (_enabled) {
      unawaited(_start());
    }
  }

  /// Toggle the LAN/Tailscale bind. Restarts the underlying server
  /// when the value changes and the server is currently running, so
  /// the new bind takes effect without the user round-tripping the
  /// master toggle.
  Future<void> setBindAll(bool value) async {
    if (_bindAll == value) return;
    _bindAll = value;
    await prefs.setRemoteAccessBindAll(value);
    notifyListeners();
    if (isRunning) {
      await _stop();
      await _start();
    }
  }

  /// Toggle the server. Persists the new value and starts/stops the
  /// underlying [HttpServer] accordingly. Idempotent — calling with
  /// the current value is a no-op.
  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await prefs.setRemoteAccessEnabled(value);
    notifyListeners();
    if (value) {
      await _start();
    } else {
      await _stop();
    }
  }

  Future<void> _start() async {
    if (_httpServer != null || _starting) return;
    _starting = true;
    _lastError = null;
    notifyListeners();
    try {
      // Pipeline order is load-bearing:
      //   1. CORS headers — applied to every response (and short-
      //      circuits OPTIONS preflights).
      //   2. Bearer auth — default-deny gate. Routes listed in
      //      `lumenBearerAuth`'s public set bypass; everything else
      //      is rejected with 401 if no valid token is presented.
      //      Auth is applied AFTER CORS so the preflight OPTIONS
      //      isn't blocked (browsers send those without auth headers).
      //   3. Router — the routes themselves.
      // Don't reorder without reading both middleware docstrings.
      final handler = shelf.Pipeline()
          .addMiddleware(_corsHeaders())
          .addMiddleware(lumenBearerAuth(pairing: pairing))
          .addHandler(_buildRouter().call);
      // Bind address depends on the user's `bindAll` choice:
      //   - false (default): `loopbackIPv4` — only this machine can
      //     reach the server.
      //   - true: `anyIPv4` — every interface, including the
      //     Tailscale virtual interface and local LAN. Bearer auth
      //     stays the gate; opening the bind without paired devices
      //     leaves an unreachable server, which IS the safe default.
      // Sticky-port: try the previously-bound port first so the URL
      // is stable across IDE restarts; fall back to OS-chosen (port
      // 0) on any bind failure.
      final InternetAddress bindAddr =
          _bindAll ? InternetAddress.anyIPv4 : InternetAddress.loopbackIPv4;
      HttpServer? server;
      final preferred = _preferredPort;
      if (preferred != null && preferred > 0) {
        try {
          server = await shelf_io.serve(handler, bindAddr, preferred);
        } catch (_) {
          // Port collision (another Lumen, dev server, etc). Fall
          // through to the port-0 path below.
        }
      }
      server ??= await shelf_io.serve(handler, bindAddr, 0);
      _httpServer = server;
      // Persist the resolved port if it changed (or wasn't recorded
      // before). Async-but-fire-and-forget — we don't want pref
      // serialisation latency to delay the bind callback.
      if (server.port != _preferredPort) {
        _preferredPort = server.port;
        unawaited(prefs.setRemoteAccessLastPort(server.port));
      }
    } catch (e) {
      _lastError = e.toString();
      _httpServer = null;
    } finally {
      _starting = false;
      notifyListeners();
    }
  }

  Future<void> _stop() async {
    final s = _httpServer;
    _httpServer = null;
    notifyListeners();
    if (s != null) {
      // `force: false` waits for in-flight requests; v1 endpoints are
      // sync and trivial so this is effectively immediate.
      await s.close(force: false);
    }
  }

  Router _buildRouter() {
    return buildLumenRouter(
      LumenRemoteDeps(
        persistence: persistence,
        currentDirectory: currentDirectory,
        recentProjects: recentProjects,
        instanceId: () => instanceId,
        instanceName: () => instanceName,
        eventBus: eventBus,
        chatController: chatController,
        pairing: pairing,
      ),
    );
  }

  /// Permissive CORS so a desktop browser tab pointed at
  /// `http://127.0.0.1:<port>/v1/health` can confirm the server is up
  /// without a CORS preflight failure. Pre-auth this is fine because
  /// loopback-only bind already restricts who can hit it.
  shelf.Middleware _corsHeaders() {
    return (inner) {
      return (req) async {
        if (req.method == 'OPTIONS') {
          return shelf.Response.ok('', headers: _corsHeadersMap);
        }
        final res = await inner(req);
        return res.change(headers: {...res.headers, ..._corsHeadersMap});
      };
    };
  }

  static const Map<String, String> _corsHeadersMap = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'GET,POST,PUT,DELETE,OPTIONS',
    'access-control-allow-headers': 'authorization,content-type',
  };

  Future<String> _loadOrCreateInstanceId() async {
    try {
      final dir = await getApplicationSupportDirectory();
      final file = File(p.join(dir.path, 'remote_instance_id'));
      if (await file.exists()) {
        final v = (await file.readAsString()).trim();
        if (_looksLikeInstanceId(v)) return v;
      }
      final id = _generateInstanceId();
      try {
        await file.writeAsString(id);
      } catch (_) {
        // Non-fatal: we'll regenerate next launch. The id is only
        // load-bearing for "have I seen this install before?" — losing
        // it just forces a re-pair, no data corruption.
      }
      return id;
    } catch (_) {
      // path_provider can fail under exotic conditions (no support
      // dir resolvable). Surface a stable per-process id so the
      // health endpoint still returns something parseable.
      return _generateInstanceId();
    }
  }

  static bool _looksLikeInstanceId(String s) =>
      s.length == 32 && RegExp(r'^[0-9a-f]{32}$').hasMatch(s);

  static String _generateInstanceId() {
    // Random.secure() backed by the OS CSPRNG on every supported
    // Flutter target. 16 bytes hex-encoded → 32-char id. Plenty of
    // entropy for a "this install" identifier; the security-sensitive
    // tokens (pairing, bearer) generate their own random bytes in the
    // auth pass.
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  void dispose() {
    // Fire-and-forget close — we're inside framework dispose and can't
    // await. The OS reclaims the socket either way; we just want to
    // be polite about in-flight responses. The bus also closes its
    // sockets and detaches from the chat controller so dangling
    // notifications don't reach a disposed sink.
    pairing.removeListener(notifyListeners);
    pairing.dispose();
    eventBus.disposeBus();
    unawaited(_stop());
    super.dispose();
  }
}
