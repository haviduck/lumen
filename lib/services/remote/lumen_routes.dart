import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_web_socket/shelf_web_socket.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../providers/chat_controller.dart';
import '../chat_persistence_service.dart';
import 'lumen_event_bus.dart';
import 'lumen_pairing_service.dart';
import 'lumen_static_assets.dart';

/// Read-only data the route layer needs from the rest of the app.
///
/// Kept as a narrow aggregate so the routes never reach into
/// [AppState] directly — that would bake in coupling we'd have to
/// unpick when the API surface grows (PR 3 streams, PR 4 mutations,
/// PR 5 auth). Read closures are evaluated **per request**, so a
/// workspace switch or a recent-projects mutation surfaces on the
/// next call without any notification plumbing.
class LumenRemoteDeps {
  LumenRemoteDeps({
    required this.persistence,
    required this.currentDirectory,
    required this.recentProjects,
    required this.instanceId,
    required this.instanceName,
    required this.eventBus,
    required this.chatController,
    required this.pairing,
  });

  final ChatPersistenceService persistence;
  final String? Function() currentDirectory;
  final List<String> Function() recentProjects;
  final String Function() instanceId;
  final String Function() instanceName;
  // Shared event bus that fans out chat-controller diffs to every
  // connected WebSocket client. The /v1/stream route wraps each
  // accepted connection in [WebSocketChannel] and registers it on
  // the bus; the bus does the rest.
  final LumenEventBus eventBus;
  // Lazy accessor so the deps object can be built before the
  // controller has finished `init` (e.g. during `_buildRouter`),
  // and so a swap to a remote-mode controller in step 6 of the
  // build order doesn't have to thread through every call site.
  // Mutating routes resolve the controller per-request.
  final ChatController Function() chatController;
  // Pairing + bearer-auth state. Owned by AppState, persists paired
  // devices across restarts. Used by the auth middleware (token →
  // device id lookup) and the pairing routes (code consume + device
  // list / revoke).
  final LumenPairingService pairing;
}

/// Sentinel project id used for chats whose `workspacePath` is null
/// (i.e. created with no workspace open). Reserved at the bytes level
/// because base64url ids never match this exact string.
const String kRemoteNoneProjectId = '__none__';

/// Build the v1 router. All routes are read-only, all loopback-only,
/// all unauthenticated for now — the bind constraint lives on
/// `LumenServer` and the auth pass lands later. See knowledgebase
/// § Remote Access for the full follow-up plan.
Router buildLumenRouter(LumenRemoteDeps deps) {
  final r = Router();

  // Health probe. Unauthenticated by design — paired clients hit
  // this before anything else to confirm reachability and re-pair
  // detection (see `LumenServer.instanceId` doc).
  r.get('/v1/health', (shelf.Request req) {
    return _ok({
      'ok': true,
      'instanceId': deps.instanceId(),
      'instanceName': deps.instanceName(),
      'protocolVersion': 1,
      'app': 'lumen',
    });
  });

  // ── Pairing ──────────────────────────────────────────────────
  // Public-by-design entry point: a phone has no bearer token yet,
  // so this route can't require one. The single-use 6-digit code
  // is the only gate. The user generates a code in Settings →
  // Remote Access; the phone POSTs it here within 60s; we mint a
  // long-lived bearer and hand it back ONCE.
  r.post('/v1/pair/initiate', (shelf.Request req) async {
    final body = await _readJson(req);
    if (body == null) return _badRequest('invalid_json', const {});
    final code = (body['code'] as String?)?.trim() ?? '';
    final deviceName = (body['deviceName'] as String?) ?? '';
    try {
      final result = await deps.pairing.consumeCode(
        code: code,
        deviceName: deviceName,
      );
      return _ok({
        'ok': true,
        'token': result.token,
        'device': result.device.toClientJson(),
        'instanceId': deps.instanceId(),
        'instanceName': deps.instanceName(),
        'protocolVersion': 1,
      });
    } on PairingError catch (e) {
      // Map domain errors to specific status codes — clients render
      // distinct messages for "no pending code" vs "wrong code" vs
      // "expired" so the user knows what to fix.
      switch (e.code) {
        case 'no_pending_code':
        case 'expired_code':
          return _conflict(e.code, {'message': e.message});
        case 'invalid_code':
          return shelf.Response(
            401,
            body: jsonEncode({
              'ok': false,
              'error': e.code,
              'message': e.message,
            }),
            headers: const {'content-type': 'application/json; charset=utf-8'},
          );
        case 'missing_code':
          return _badRequest(e.code, {'message': e.message});
      }
      return _serverError('pair_failed', {'message': e.message});
    }
  });

  // Authenticated: list paired devices. The Settings UI uses this
  // to render the manage-devices list, but it's also useful from a
  // device that wants to confirm it's still paired without trying a
  // privileged call first.
  r.get('/v1/pair/devices', (shelf.Request req) {
    return _ok({
      'devices': [
        for (final d in deps.pairing.devices) d.toClientJson(),
      ],
    });
  });

  // Authenticated: revoke a paired device (yourself or another).
  // Idempotent — 404 only if the id was never paired in the first
  // place, otherwise 200 with `removed: true|false` so a client
  // that double-clicks doesn't get a confusing error.
  r.delete('/v1/pair/devices/<deviceId>',
      (shelf.Request req, String deviceId) async {
    if (!deps.pairing.devices.any((d) => d.id == deviceId)) {
      return _notFound('device_not_found', {'deviceId': deviceId});
    }
    final removed = await deps.pairing.revokeDevice(deviceId);
    return _ok({'ok': true, 'removed': removed, 'deviceId': deviceId});
  });

  // List projects the desktop knows about, with chat counts. The
  // "project" concept here is intentionally loose — Lumen's source
  // of truth is `workspacePath` on each `ChatSession`, plus the
  // recent-projects pref. We unify those into a single list:
  //
  //   1. The currently-open workspace, pinned first when present.
  //   2. Recent workspaces from prefs.
  //   3. Any workspace seen on a stored chat that wasn't covered
  //      above (handles "I have an old chat for a project I never
  //      re-opened on this machine").
  //   4. A `__none__` pseudo-project for chats with null
  //      `workspacePath`, but only when at least one such chat
  //      exists.
  r.get('/v1/projects', (shelf.Request req) async {
    final sessions = await deps.persistence.listSessions();
    return _ok({
      'projects': _buildProjectList(deps, sessions),
    });
  });

  // List chats scoped to a specific project id. The project id
  // is the base64url-encoded normalised path (or `__none__`),
  // and the filter is path-equality with the same normalisation
  // used at encode time so case / separator differences don't
  // split a project across rows.
  r.get('/v1/projects/<id>/chats', (shelf.Request req, String id) async {
    final sessions = await deps.persistence.listSessions();
    final List<ChatSession> filtered;
    if (id == kRemoteNoneProjectId) {
      filtered = sessions.where((s) => s.workspacePath == null).toList();
    } else {
      final path = _decodeProjectId(id);
      if (path.isEmpty) {
        return _badRequest('invalid_project_id', {'id': id});
      }
      filtered = sessions
          .where((s) => _samePath(s.workspacePath, path))
          .toList();
    }
    return _ok({
      'projectId': id,
      'chats': filtered.map(_chatSummary).toList(),
    });
  });

  // Return one full session (including all messages). The shape
  // matches `ChatSession.toJson()` exactly — no envelope, no
  // re-projection. This means a future Android client can re-use
  // the same `ChatSession.fromJson` factory the desktop already
  // ships, no schema drift.
  r.get('/v1/chats/<chatId>', (shelf.Request req, String chatId) async {
    final session = await deps.persistence.loadSession(chatId);
    if (session == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    return _ok(session.toJson());
  });

  // ── Mutating routes ──────────────────────────────────────────
  // Every mutation hits the live `ChatController` via
  // `deps.chatController()`. Because the controller drives the
  // desktop UI directly, **POST /v1/chats/{id}/messages auto-
  // switches the desktop's active chat**. There's no "send to
  // chat X without changing my active tab" mode in the v1
  // protocol — that's a session-queuing change to the controller
  // itself and is deliberately deferred.
  //
  // Tool-execution context (workspace, active file, open files)
  // comes from the desktop, not the request. We don't accept those
  // in the body even when `sendMessage` would technically take
  // them — letting a remote client claim a workspace different
  // from what the desktop has open is a footgun that this PR is
  // not the place to introduce.

  // Create a new chat. `workspacePath` defaults to whatever the
  // desktop currently has open — phones almost always want "a
  // fresh chat in the workspace I'm looking at," not a workspace-
  // less chat. Pass an empty string to opt out and create a
  // null-workspace chat explicitly (rare; mostly useful for
  // pre-workspace bootstrap flows).
  r.post('/v1/chats', (shelf.Request req) async {
    final body = await _readJson(req);
    if (body == null) return _badRequest('invalid_json', const {});
    final chat = deps.chatController();
    final raw = body['workspacePath'];
    final String? workspacePath;
    if (raw is String) {
      workspacePath = raw.isEmpty ? null : raw;
    } else {
      // Field absent (or wrong type): fall back to current.
      workspacePath = chat.currentWorkspace;
    }
    await chat.newSession(workspacePath: workspacePath);
    final created = chat.currentSession;
    if (created == null) {
      // Shouldn't happen — `newSession` always installs `_current`.
      // If it does we fail loud rather than handing back a 200 with
      // a missing chat.
      return _serverError('new_session_failed', const {});
    }
    return _ok(created.toJson());
  });

  // Set this chat as the desktop's active tab. Idempotent — a
  // no-op when already current. Use this when the phone wants
  // to "navigate" to a chat without sending a message yet.
  r.post('/v1/chats/<chatId>/select',
      (shelf.Request req, String chatId) async {
    final chat = deps.chatController();
    if (chat.currentSession?.id == chatId) {
      return _ok({'ok': true, 'chatId': chatId, 'alreadyActive': true});
    }
    final exists = await deps.persistence.loadSession(chatId);
    if (exists == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    await chat.openSession(chatId);
    return _ok({'ok': true, 'chatId': chatId, 'alreadyActive': false});
  });

  // Send a user message to the given chat. Auto-selects it as
  // the desktop's active chat first. If the controller is mid-
  // generation the prompt is queued (same behavior as typing
  // into the desktop composer during a stream).
  //
  // CRITICAL: `ChatController.sendMessage` awaits the **full**
  // `_runGenerationLoop` (see chat_controller.dart line 1854),
  // which can take 30s+ on a long Opus response. Awaiting it
  // here would hold this HTTP request hostage for the whole
  // generation AND block any cancel issued from the same TCP
  // connection. We deliberately fire-and-forget so the route
  // returns immediately and the client can issue a cancel via a
  // separate request. Progress is observable on `/v1/stream`
  // (`message_added` → `message_delta` → `message_complete`).
  r.post('/v1/chats/<chatId>/messages',
      (shelf.Request req, String chatId) async {
    final body = await _readJson(req);
    if (body == null) return _badRequest('invalid_json', const {});
    final text = body['text'] as String?;
    if (text == null || text.trim().isEmpty) {
      return _badRequest('empty_text', const {
        'hint': 'Body must include a non-empty `text` field.',
      });
    }
    final displayText = body['displayText'] as String?;

    final chat = deps.chatController();
    final exists = await deps.persistence.loadSession(chatId);
    if (exists == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    if (chat.currentSession?.id != chatId) {
      await chat.openSession(chatId);
    }
    final wasGenerating = chat.isGenerating;
    // Intentional `unawaited` — see CRITICAL comment above. Don't
    // change this back to `await` without restructuring the
    // controller's API surface. The `queued` field reflects state
    // at submission time (whether sendMessage ended up enqueueing
    // because gen was already running), not state at response
    // time.
    unawaited(chat.sendMessage(
      text,
      workspacePath: chat.currentWorkspace,
      displayText: displayText,
    ));
    return _ok({
      'ok': true,
      'chatId': chatId,
      'queued': wasGenerating,
    });
  });

  // Cancel any in-flight generation for the given chat. Only the
  // active chat can be generating (controller invariant), so a
  // cancel against any other chat id is a 409.
  r.post('/v1/chats/<chatId>/cancel',
      (shelf.Request req, String chatId) async {
    final chat = deps.chatController();
    if (chat.currentSession?.id != chatId) {
      return _conflict('not_active_chat', {
        'chatId': chatId,
        'activeChatId': chat.currentSession?.id,
      });
    }
    final wasGenerating = chat.isGenerating;
    chat.cancelGeneration();
    return _ok({
      'ok': true,
      'chatId': chatId,
      'wasGenerating': wasGenerating,
    });
  });

  // Rename a chat. The chat does NOT need to be active. Empty or
  // whitespace-only titles are rejected so a phone client can't
  // accidentally blank a chat out — the desktop would just show
  // an empty tab, which is jarring.
  r.post('/v1/chats/<chatId>/rename',
      (shelf.Request req, String chatId) async {
    final body = await _readJson(req);
    if (body == null) return _badRequest('invalid_json', const {});
    final title = (body['title'] as String?)?.trim();
    if (title == null || title.isEmpty) {
      return _badRequest('empty_title', const {
        'hint': 'Body must include a non-empty `title` field.',
      });
    }
    final chat = deps.chatController();
    final exists = await deps.persistence.loadSession(chatId);
    if (exists == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    await chat.renameSession(chatId, title);
    return _ok({'ok': true, 'chatId': chatId, 'title': title});
  });

  // Delete a chat. The chat does NOT need to be active. The
  // controller handles the "you just deleted the active chat"
  // case internally — it picks a successor or seeds a fresh
  // empty session. Either way, watching `/v1/stream` for
  // `chat_deleted` + `state_changed` tells the client what
  // landed.
  r.delete('/v1/chats/<chatId>',
      (shelf.Request req, String chatId) async {
    final chat = deps.chatController();
    final exists = await deps.persistence.loadSession(chatId);
    if (exists == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    await chat.deleteSession(chatId);
    return _ok({'ok': true, 'deletedId': chatId});
  });

  // ── Model management (read-only + per-chat selection) ────
  // Phone clients use these to surface a model picker. Catalog
  // changes (provider keys, enabled-models toggle) stay desktop-
  // only — the v1 phone surface is "view + pick from already-
  // enabled list" which matches the desktop composer's picker.

  r.get('/v1/models', (shelf.Request req) {
    final chat = deps.chatController();
    return _ok({
      'selected': chat.selectedModel,
      // `available`: every model the controller currently sees
      // across configured providers. Useful for diagnostics.
      'available': chat.availableModels,
      // `enabled`: subset the user has explicitly enabled. This
      // is what the desktop composer's picker shows; phones
      // should display this list.
      'enabled': chat.enabledModels.toList()..sort(),
    });
  });

  // Set model for a specific chat. Mirrors the desktop's behavior:
  // selecting a model in the composer updates BOTH the global
  // `_selectedModel` AND the current session's model. We auto-
  // select the chat first so `controller.setModel` operates
  // against the right session — same single-active-chat invariant
  // that POST /messages uses.
  r.post('/v1/chats/<chatId>/model',
      (shelf.Request req, String chatId) async {
    final body = await _readJson(req);
    if (body == null) return _badRequest('invalid_json', const {});
    final model = (body['model'] as String?)?.trim();
    if (model == null || model.isEmpty) {
      return _badRequest('empty_model', const {
        'hint': 'Body must include a non-empty `model` field.',
      });
    }
    if (model.startsWith('github:')) {
      return _badRequest('removed_provider', const {
        'hint': 'GitHub Models was removed; pick another provider.',
      });
    }
    final chat = deps.chatController();
    if (!chat.availableModels.contains(model)) {
      // Reject unknown models loud — silently coercing to
      // selectedModel would mask configuration bugs (provider
      // disabled, model name typo on the phone) that the user
      // needs to see.
      return _badRequest('unknown_model', {'model': model});
    }
    final exists = await deps.persistence.loadSession(chatId);
    if (exists == null) {
      return _notFound('chat_not_found', {'chatId': chatId});
    }
    if (chat.currentSession?.id != chatId) {
      await chat.openSession(chatId);
    }
    chat.setModel(model);
    return _ok({'ok': true, 'chatId': chatId, 'model': model});
  });

  // Live event stream. One WebSocket per client; the server
  // broadcasts every diff coming out of `LumenEventBus` (chat
  // create/update/delete, message add/delta/complete,
  // state_changed). Clients can ignore unknown `kind`s — the
  // protocol is forward-compatible.
  //
  // No subscription params for v1; clients receive every event.
  // The auth pass introduces device-scoped filtering. Inbound
  // frames from the client are read and discarded — keeping the
  // sink alive but reserving the inbound path for future
  // commands (subscribe-to-chat, ack, etc).
  r.get(
    '/v1/stream',
    webSocketHandler((WebSocketChannel ch, _) {
      deps.eventBus.addClient(ch);
      ch.stream.listen(
        (_) {
          // Drain inbound frames; protocol is server→client only
          // in v1. A future PR adds typed inbound commands.
        },
        onDone: () => deps.eventBus.removeClient(ch),
        onError: (_) => deps.eventBus.removeClient(ch),
        cancelOnError: true,
      );
    }),
  );

  // ── Bundled Remote Access PWA ─────────────────────────────
  // The phone-friendly chat client lives in `assets/remote_app/`.
  // We serve it from `/app/...` so users can just browse to
  // `http://<lumen-host>:<port>/` (which we redirect to `/app/`)
  // and get the pairing screen → projects → chats → chat flow.
  // These routes are unauthenticated; the loaded JS handles
  // pairing + bearer persistence itself.
  r.get('/', redirectRootToApp);
  r.get('/app',
      (shelf.Request req) => shelf.Response.found('/app/'));
  r.get('/app/',
      (shelf.Request req) async => serveRemoteAppAsset('index.html'));
  r.get('/app/<rest|.*>',
      (shelf.Request req, String rest) async => serveRemoteAppAsset(rest));

  // Catch-all 404 with hint. Helps confused clients (and curl
  // typos) get a clear "this URL is wrong" instead of an empty
  // body. Must be registered last — `shelf_router` resolves
  // first-match-wins.
  r.all('/<ignored|.*>', (shelf.Request req) {
    return _notFound('unknown_route', {'path': req.url.path});
  });

  return r;
}

List<Map<String, dynamic>> _buildProjectList(
  LumenRemoteDeps deps,
  List<ChatSession> sessions,
) {
  final seenNorm = <String>{};
  final out = <Map<String, dynamic>>[];

  void addProject(String path, {bool isCurrent = false}) {
    final n = _normPath(path);
    if (n.isEmpty || seenNorm.contains(n)) return;
    seenNorm.add(n);
    final chats = sessions
        .where((s) => s.workspacePath != null &&
            _normPath(s.workspacePath!) == n)
        .toList();
    out.add(_projectRow(path, chats, isCurrent: isCurrent));
  }

  final current = deps.currentDirectory();
  if (current != null && current.isNotEmpty) {
    addProject(current, isCurrent: true);
  }
  for (final r in deps.recentProjects()) {
    if (r.isEmpty) continue;
    addProject(r);
  }
  for (final s in sessions) {
    final wp = s.workspacePath;
    if (wp == null || wp.isEmpty) continue;
    addProject(wp);
  }

  final orphans = sessions.where((s) => s.workspacePath == null).toList();
  if (orphans.isNotEmpty) {
    out.add({
      'id': kRemoteNoneProjectId,
      'name': '(No workspace)',
      'path': null,
      'isCurrent': false,
      'chatCount': orphans.length,
      'lastUsedAt': orphans
          .map((s) => s.updatedAt)
          .reduce((a, b) => a.isAfter(b) ? a : b)
          .toIso8601String(),
    });
  }

  return out;
}

Map<String, dynamic> _projectRow(
  String path,
  List<ChatSession> chats, {
  required bool isCurrent,
}) {
  final base = p.basename(p.normalize(path));
  return {
    'id': _encodeProjectId(path),
    'name': base.isEmpty ? path : base,
    'path': path,
    'isCurrent': isCurrent,
    'chatCount': chats.length,
    'lastUsedAt': chats.isEmpty
        ? null
        : chats
            .map((s) => s.updatedAt)
            .reduce((a, b) => a.isAfter(b) ? a : b)
            .toIso8601String(),
  };
}

Map<String, dynamic> _chatSummary(ChatSession s) {
  // NOTE: deliberately no `messageCount` field here. `listSessions()`
  // reads the on-disk index, which `ChatPersistenceService._rebuildIndex`
  // writes with `'messages': const []` so listing stays cheap (one
  // file read instead of N). Surfacing `s.messages.length` from a
  // listing context would always return 0 and lie to the client.
  // The full session response (`GET /v1/chats/{id}`) carries the
  // real messages, so a curious phone client can compute the count
  // there. Don't add `messageCount` back without first extending
  // the index format — and that's a `chat_persistence_service.dart`
  // change with its own impact analysis.
  return {
    'id': s.id,
    'title': s.title,
    'model': s.model,
    'createdAt': s.createdAt.toIso8601String(),
    'updatedAt': s.updatedAt.toIso8601String(),
    'workspacePath': s.workspacePath,
  };
}

shelf.Response _ok(Object body) {
  return shelf.Response.ok(
    jsonEncode(body),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

shelf.Response _notFound(String code, Map<String, dynamic> extra) {
  return shelf.Response.notFound(
    jsonEncode({'ok': false, 'error': code, ...extra}),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

shelf.Response _badRequest(String code, Map<String, dynamic> extra) {
  return shelf.Response.badRequest(
    body: jsonEncode({'ok': false, 'error': code, ...extra}),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

shelf.Response _conflict(String code, Map<String, dynamic> extra) {
  return shelf.Response(
    409,
    body: jsonEncode({'ok': false, 'error': code, ...extra}),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

shelf.Response _serverError(String code, Map<String, dynamic> extra) {
  return shelf.Response.internalServerError(
    body: jsonEncode({'ok': false, 'error': code, ...extra}),
    headers: const {'content-type': 'application/json; charset=utf-8'},
  );
}

/// Read and JSON-decode the request body. Returns `null` when the
/// body is empty (POST with no body is treated as `{}`) or when
/// it doesn't parse as a JSON object — the route handler turns
/// that into `400 invalid_json`. Non-object roots (arrays, scalars)
/// also return `null` so handlers can dot-access fields without
/// type juggling.
Future<Map<String, dynamic>?> _readJson(shelf.Request req) async {
  final raw = await req.readAsString();
  if (raw.trim().isEmpty) return <String, dynamic>{};
  try {
    final parsed = jsonDecode(raw);
    if (parsed is Map<String, dynamic>) return parsed;
    if (parsed is Map) return Map<String, dynamic>.from(parsed);
    return null;
  } catch (_) {
    return null;
  }
}

/// Normalised path key for project equality. Lowercased + forward
/// slashes so a Windows path (`C:\foo\bar`) matches the same
/// workspace re-resolved as `C:/foo/bar`.
String _normPath(String path) =>
    p.normalize(path).replaceAll('\\', '/').toLowerCase();

/// Encode a workspace path as a URL-safe project id. Base64url
/// without padding so the id round-trips through path segments and
/// stays statelessly decodable. No confidentiality intent — the id
/// is reversible. Encoded over the *normalised* path so a chat
/// indexed under `C:\foo\bar` and a recent-project entry of
/// `C:/foo/bar` produce the same id.
String _encodeProjectId(String path) {
  final norm = p.normalize(path).replaceAll('\\', '/');
  return base64Url.encode(utf8.encode(norm)).replaceAll('=', '');
}

/// Decode a project id back to its (normalised) workspace path.
/// Returns the empty string on garbage input — callers translate
/// that into a 400 [_badRequest] rather than crashing the route.
String _decodeProjectId(String id) {
  if (id == kRemoteNoneProjectId) return '';
  final pad = (4 - id.length % 4) % 4;
  final padded = id + ('=' * pad);
  try {
    return utf8.decode(base64Url.decode(padded));
  } catch (_) {
    return '';
  }
}

bool _samePath(String? a, String? b) {
  if (a == null || b == null) return false;
  return _normPath(a) == _normPath(b);
}
