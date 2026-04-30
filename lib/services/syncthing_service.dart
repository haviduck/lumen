import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Client for the Syncthing REST API.
///
/// Communicates with a local (or remote) Syncthing instance over HTTP.
/// Authentication is via `X-API-Key` header. If the user leaves the API key
/// blank and Syncthing is configured without auth (common for localhost),
/// the header is simply omitted.
///
/// Key endpoints used (see `https://docs.syncthing.net/dev/rest.html`):
///   GET    /rest/noauth/health             - unauthenticated liveness probe
///   GET    /rest/system/ping               - authenticated ping
///   GET    /rest/system/status             - device ID, version, uptime
///   GET    /rest/system/version            - version-only endpoint
///   GET    /rest/config/folders            - list all shared folders
///   POST   /rest/config/folders            - add or replace a folder
///   GET    /rest/config/folders/{id}       - get a specific folder config
///   PATCH  /rest/config/folders/{id}       - patch fields on a folder
///   DELETE /rest/config/folders/{id}       - remove a folder
///   GET    /rest/config/devices            - list all known devices
///   POST   /rest/config/devices            - add or replace a device
///   PATCH  /rest/config/devices/{id}       - patch fields on a device
///   GET    /rest/config/defaults/folder    - default folder template
///   PATCH  /rest/config/defaults/folder    - patch the default template
///   GET    /rest/config/defaults/ignores   - default `.stignore` patterns
///   PUT    /rest/config/defaults/ignores   - replace default `.stignore`
///   GET    /rest/db/status?folder={id}     - sync completion for a folder
///   GET    /rest/db/ignores?folder={id}    - per-folder ignore patterns
///   POST   /rest/db/ignores?folder={id}    - replace per-folder patterns
///   GET    /rest/cluster/pending/folders   - folders offered by remotes
///   DELETE /rest/cluster/pending/folders   - dismiss a pending folder
///   GET    /rest/cluster/pending/devices   - devices that tried to connect
///   DELETE /rest/cluster/pending/devices   - dismiss a pending device
class SyncthingService {
  String _baseUrl;
  String _apiKey;

  SyncthingService({
    String baseUrl = 'http://localhost:8384',
    String apiKey = '',
  })  : _baseUrl = baseUrl.trimRight(),
        _apiKey = apiKey;

  void configure({required String baseUrl, required String apiKey}) {
    _baseUrl = baseUrl.trimRight();
    _apiKey = apiKey;
  }

  String get baseUrl => _baseUrl;
  String get apiKey => _apiKey;

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_apiKey.isNotEmpty) 'X-API-Key': _apiKey,
      };

  // ── Health (no-auth) ─────────────────────────────────────────────

  Future<bool> isReachable() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/rest/noauth/health'))
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── Authenticated ping ──────────────────────────────────────────

  Future<bool> ping() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/rest/system/ping'), headers: _headers)
          .timeout(const Duration(seconds: 3));
      return r.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  // ── System status ───────────────────────────────────────────────

  Future<Map<String, dynamic>?> systemStatus() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/rest/system/status'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] systemStatus error: $e');
    }
    return null;
  }

  // ── Folders ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listFolders() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/rest/config/folders'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[Syncthing] listFolders error: $e');
    }
    return [];
  }

  Future<bool> isFolderRegistered(String path) async {
    final folders = await listFolders();
    final normalised = _normalisePath(path);
    return folders.any((f) => _normalisePath(f['path'] ?? '') == normalised);
  }

  Future<String?> folderIdForPath(String path) async {
    final folders = await listFolders();
    final normalised = _normalisePath(path);
    for (final f in folders) {
      if (_normalisePath(f['path'] ?? '') == normalised) {
        return f['id'] as String?;
      }
    }
    return null;
  }

  Future<Map<String, dynamic>?> getFolder(String folderId) async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/config/folders/$folderId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] getFolder error: $e');
    }
    return null;
  }

  /// Adds (or replaces) a folder. Sane defaults for code projects:
  /// `sendreceive`, fs watcher on, `ignorePerms` configurable, optional
  /// versioning. Pass `extraOverrides` to inject anything else (e.g.
  /// receive-encrypted).
  Future<bool> addFolder({
    required String id,
    required String path,
    required String label,
    bool ignorePerms = false,
    Map<String, dynamic>? versioning,
    List<Map<String, String>>? deviceOverride,
    Map<String, dynamic>? extraOverrides,
  }) async {
    try {
      final devices = deviceOverride ??
          (await listDevices())
              .map((d) => {'deviceID': d['deviceID'] as String? ?? ''})
              .where((d) => (d['deviceID'] ?? '').isNotEmpty)
              .toList();

      final body = <String, dynamic>{
        'id': id,
        'path': path,
        'label': label,
        'type': 'sendreceive',
        'fsWatcherEnabled': true,
        'fsWatcherDelayS': 10,
        'rescanIntervalS': 3600,
        'ignorePerms': ignorePerms,
        // ignore: use_null_aware_elements
        if (versioning != null) 'versioning': versioning,
        'devices': devices,
        ...?extraOverrides,
      };
      final r = await http
          .post(
            Uri.parse('$_baseUrl/rest/config/folders'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] addFolder error: $e');
      return false;
    }
  }

  /// PATCHes only the given fields on an existing folder. Use this for
  /// targeted edits (e.g. relocating `path` after the user picks a real
  /// destination, or attaching new devices).
  Future<bool> patchFolder(
    String folderId,
    Map<String, dynamic> patch,
  ) async {
    try {
      final r = await http
          .patch(
            Uri.parse('$_baseUrl/rest/config/folders/$folderId'),
            headers: _headers,
            body: jsonEncode(patch),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] patchFolder error: $e');
      return false;
    }
  }

  Future<bool> ensureFolderShared(String folderId) async {
    try {
      final devices = (await listDevices())
          .map((d) => {'deviceID': d['deviceID'] as String? ?? ''})
          .where((d) => (d['deviceID'] ?? '').isNotEmpty)
          .toList();
      return await patchFolder(folderId, {'devices': devices});
    } catch (e) {
      debugPrint('[Syncthing] ensureFolderShared error: $e');
      return false;
    }
  }

  Future<bool> deleteFolder(String folderId) async {
    try {
      final r = await http
          .delete(
            Uri.parse('$_baseUrl/rest/config/folders/$folderId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] deleteFolder error: $e');
      return false;
    }
  }

  // ── Per-folder ignore patterns (.stignore) ──────────────────────

  /// Returns the active `.stignore` patterns for [folderId], one line per
  /// list entry. Returns `null` on error.
  Future<List<String>?> folderIgnores(String folderId) async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/db/ignores?folder=$folderId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        final ignore = (body['ignore'] as List?)?.cast<String>();
        return ignore ?? <String>[];
      }
    } catch (e) {
      debugPrint('[Syncthing] folderIgnores error: $e');
    }
    return null;
  }

  /// Replaces the `.stignore` content for [folderId]. The old file is
  /// preserved as `.stignore.bak` by Syncthing.
  Future<bool> setFolderIgnores(String folderId, List<String> lines) async {
    try {
      final r = await http
          .post(
            Uri.parse('$_baseUrl/rest/db/ignores?folder=$folderId'),
            headers: _headers,
            body: jsonEncode({'ignore': lines}),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] setFolderIgnores error: $e');
      return false;
    }
  }

  // ── Devices ─────────────────────────────────────────────────────

  Future<List<Map<String, dynamic>>> listDevices() async {
    try {
      final r = await http
          .get(Uri.parse('$_baseUrl/rest/config/devices'), headers: _headers)
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return (jsonDecode(r.body) as List).cast<Map<String, dynamic>>();
      }
    } catch (e) {
      debugPrint('[Syncthing] listDevices error: $e');
    }
    return [];
  }

  Future<bool> patchDevice(
    String deviceId,
    Map<String, dynamic> patch,
  ) async {
    try {
      final r = await http
          .patch(
            Uri.parse('$_baseUrl/rest/config/devices/$deviceId'),
            headers: _headers,
            body: jsonEncode(patch),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] patchDevice error: $e');
      return false;
    }
  }

  Future<bool> enableAutoAccept(String deviceId, {bool enabled = true}) =>
      patchDevice(deviceId, {'autoAcceptFolders': enabled});

  /// Sets `introducer` to [enabled] on a remote device entry. Used to
  /// break mutual-introducer loops (warning: "Remote is an introducer to
  /// us, and we are to them").
  Future<bool> setIntroducer(String deviceId, {required bool enabled}) =>
      patchDevice(deviceId, {'introducer': enabled});

  /// Adds (or replaces) a device entry. Used by the "accept pending
  /// device" flow.
  Future<bool> addDevice({
    required String deviceId,
    required String name,
    String compression = 'metadata',
    bool autoAcceptFolders = false,
    bool introducer = false,
    List<String>? addresses,
  }) async {
    try {
      final body = <String, dynamic>{
        'deviceID': deviceId,
        'name': name,
        'addresses': addresses ?? ['dynamic'],
        'compression': compression,
        'introducer': introducer,
        'autoAcceptFolders': autoAcceptFolders,
        'paused': false,
      };
      final r = await http
          .post(
            Uri.parse('$_baseUrl/rest/config/devices'),
            headers: _headers,
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] addDevice error: $e');
      return false;
    }
  }

  // ── Defaults (folder template + ignores) ────────────────────────

  /// Returns the default folder template (the values applied to any
  /// auto-accepted or freshly-created folder). The `path` field is the
  /// receiver-side `defaultFolderPath` — what every auto-accepted folder
  /// uses as its base directory.
  Future<Map<String, dynamic>?> getDefaultFolder() async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/config/defaults/folder'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] getDefaultFolder error: $e');
    }
    return null;
  }

  /// Patches the default folder template. The most useful field here is
  /// `path` — set this on the *receiver* to control where auto-accepted
  /// folders land.
  Future<bool> patchDefaultFolder(Map<String, dynamic> patch) async {
    try {
      final r = await http
          .patch(
            Uri.parse('$_baseUrl/rest/config/defaults/folder'),
            headers: _headers,
            body: jsonEncode(patch),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] patchDefaultFolder error: $e');
      return false;
    }
  }

  /// Default ignore patterns applied to any newly-accepted folder
  /// (Syncthing 1.19+). Returns an empty list if not supported.
  Future<List<String>> getDefaultIgnores() async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/config/defaults/ignores'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        final body = jsonDecode(r.body) as Map<String, dynamic>;
        return (body['lines'] as List?)?.cast<String>() ?? <String>[];
      }
    } catch (e) {
      debugPrint('[Syncthing] getDefaultIgnores error: $e');
    }
    return <String>[];
  }

  Future<bool> setDefaultIgnores(List<String> lines) async {
    try {
      final r = await http
          .put(
            Uri.parse('$_baseUrl/rest/config/defaults/ignores'),
            headers: _headers,
            body: jsonEncode({'lines': lines}),
          )
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] setDefaultIgnores error: $e');
      return false;
    }
  }

  // ── Pending folders / devices ───────────────────────────────────

  /// Folders offered by remote devices that haven't been accepted yet.
  /// Map shape: `{ folderId: { offeredBy: { deviceId: { time, label, ... } } } }`.
  Future<Map<String, dynamic>> pendingFolders() async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/cluster/pending/folders'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] pendingFolders error: $e');
    }
    return {};
  }

  /// Dismiss a pending folder offer (optionally only from a specific
  /// remote device).
  Future<bool> dismissPendingFolder(String folderId, {String? deviceId}) async {
    try {
      final params = <String, String>{
        'folder': folderId,
        // ignore: use_null_aware_elements
        if (deviceId != null) 'device': deviceId,
      };
      final uri =
          Uri.parse('$_baseUrl/rest/cluster/pending/folders').replace(
        queryParameters: params,
      );
      final r = await http
          .delete(uri, headers: _headers)
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] dismissPendingFolder error: $e');
      return false;
    }
  }

  /// Devices that tried to connect but aren't yet configured.
  /// Map shape: `{ deviceId: { time, name, address } }`.
  Future<Map<String, dynamic>> pendingDevices() async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/cluster/pending/devices'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] pendingDevices error: $e');
    }
    return {};
  }

  Future<bool> dismissPendingDevice(String deviceId) async {
    try {
      final uri =
          Uri.parse('$_baseUrl/rest/cluster/pending/devices').replace(
        queryParameters: {'device': deviceId},
      );
      final r = await http
          .delete(uri, headers: _headers)
          .timeout(const Duration(seconds: 5));
      return r.statusCode == 200;
    } catch (e) {
      debugPrint('[Syncthing] dismissPendingDevice error: $e');
      return false;
    }
  }

  /// Convenience: accept a pending folder with an explicit local [path].
  /// This is the safe alternative to `autoAcceptFolders: true` — the user
  /// always picks where files land.
  Future<bool> acceptPendingFolder({
    required String folderId,
    required String label,
    required String path,
    required String fromDeviceId,
    bool ignorePerms = false,
    Map<String, dynamic>? versioning,
  }) async {
    final devices = <Map<String, String>>[
      {'deviceID': fromDeviceId},
    ];
    return addFolder(
      id: folderId,
      label: label,
      path: path,
      ignorePerms: ignorePerms,
      versioning: versioning,
      deviceOverride: devices,
    );
  }

  // ── DB status (sync completion) ──────────────────────────────────

  Future<Map<String, dynamic>?> folderStatus(String folderId) async {
    try {
      final r = await http
          .get(
            Uri.parse('$_baseUrl/rest/db/status?folder=$folderId'),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 5));
      if (r.statusCode == 200) {
        return jsonDecode(r.body) as Map<String, dynamic>;
      }
    } catch (e) {
      debugPrint('[Syncthing] folderStatus error: $e');
    }
    return null;
  }

  // ── Helpers ─────────────────────────────────────────────────────

  /// Normalise a path for comparison (lowercase, forward slashes, no trailing slash).
  static String _normalisePath(String p) {
    return p
        .replaceAll('\\', '/')
        .toLowerCase()
        .replaceAll(RegExp(r'/$'), '');
  }

  /// Generate a stable, short folder ID from a path.
  /// Uses the last directory component, lowercased, with non-alphanumeric
  /// chars replaced by hyphens. Falls back to a hash if the result is empty.
  static String folderIdFromPath(String path) {
    final name = path
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .last;
    final clean = name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return clean.isNotEmpty ? clean : 'lumen-${path.hashCode.abs()}';
  }
}

/// Versioning strategies as named presets. Used in Settings → Syncthing
/// to pick the default for newly-shared folders, and at share time to
/// stamp the strategy onto the folder config.
enum SyncthingVersioningPreset {
  none,
  trashcan,
  simple,
  staggered,
}

extension SyncthingVersioningPresetX on SyncthingVersioningPreset {
  /// Persisted key (used in `PreferencesService`).
  String get key => switch (this) {
        SyncthingVersioningPreset.none => 'none',
        SyncthingVersioningPreset.trashcan => 'trashcan',
        SyncthingVersioningPreset.simple => 'simple',
        SyncthingVersioningPreset.staggered => 'staggered',
      };

  /// Human-readable label for UI.
  String get label => switch (this) {
        SyncthingVersioningPreset.none => 'None (no version history)',
        SyncthingVersioningPreset.trashcan =>
          'Trash can (keep deletes for 30 days)',
        SyncthingVersioningPreset.simple => 'Simple (5 versions per file)',
        SyncthingVersioningPreset.staggered =>
          'Staggered (recommended for code)',
      };

  /// Versioning JSON applied to a folder config. `null` for [none].
  Map<String, dynamic>? toJson() => switch (this) {
        SyncthingVersioningPreset.none => null,
        SyncthingVersioningPreset.trashcan => {
            'type': 'trashcan',
            'params': {'cleanoutDays': '30'},
            'cleanupIntervalS': 3600,
          },
        SyncthingVersioningPreset.simple => {
            'type': 'simple',
            'params': {'keep': '5'},
            'cleanupIntervalS': 3600,
          },
        SyncthingVersioningPreset.staggered => {
            'type': 'staggered',
            'params': {
              // 1 hour, 1 day, 30 days, 365 days  →
              // keep 1 per hour for an hour, 1 per day for a day, etc.
              'maxAge': '${365 * 24 * 3600}',
              'cleanInterval': '3600',
              'versionsPath': '',
            },
            'cleanupIntervalS': 3600,
          },
      };

  static SyncthingVersioningPreset fromKey(String? key) {
    return switch (key) {
      'trashcan' => SyncthingVersioningPreset.trashcan,
      'simple' => SyncthingVersioningPreset.simple,
      'staggered' => SyncthingVersioningPreset.staggered,
      _ => SyncthingVersioningPreset.none,
    };
  }
}

/// Default `.stignore` patterns Lumen writes when it shares a code project.
///
/// Skips build artefacts, dependency caches, IDE state, and OS junk.
/// Notably does **NOT** skip `.lumen/` or `.agents/` — those are
/// project-shared and the user explicitly wants them mirrored across
/// devices (workspace skills, knowledgebase, agent rules).
const List<String> kLumenDefaultStignore = <String>[
  '// Lumen default ignore patterns. Edit freely.',
  '// Dependency / build directories',
  'node_modules',
  '.pnpm-store',
  'bower_components',
  'vendor',
  'build',
  'dist',
  'out',
  'target',
  '.next',
  '.nuxt',
  '.svelte-kit',
  '.dart_tool',
  '.flutter-plugins',
  '.flutter-plugins-dependencies',
  '.gradle',
  '.idea',
  '.vscode',
  '__pycache__',
  '.pytest_cache',
  '.mypy_cache',
  '.tox',
  '.venv',
  'venv',
  'env',
  '.cache',
  '.parcel-cache',
  '.turbo',
  '*.pyc',
  '*.pyo',
  // Logs / temp / OS
  '*.log',
  '*.tmp',
  '*.swp',
  '*.swo',
  '.DS_Store',
  'Thumbs.db',
  'desktop.ini',
  // Syncthing internals — should never sync.
  '.stversions',
  '.stfolder',
];
