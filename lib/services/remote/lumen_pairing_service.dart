import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Pairing + bearer-auth backend for Remote Access.
///
/// **Threat model (deliberate scope):**
/// Plain HTTP, single-user-multiple-devices, expected over LAN or
/// Tailscale. NOT designed for hostile networks (coffee-shop wifi,
/// public APs). The bearer token is the only authentication;
/// transport encryption is the network layer's job (Tailscale gives
/// us WireGuard, LAN does not). If you ever need to roam onto an
/// untrusted network, layer TLS in front of this — see deferred
/// PR 5.5 in `.agents/knowledgebase.md`.
///
/// **What this owns:**
/// - Generation + lifetime of single-use pairing codes (6 digits,
///   60s TTL, in-memory only).
/// - Persistent registry of paired devices on disk
///   (`<appSupport>/remote_paired_devices.json`).
/// - Token-hash lookup used by the auth middleware.
///
/// **What this does NOT own:**
/// - HTTP routing — see `lumen_routes.dart`.
/// - The bind decision (loopback vs anyIPv4) — see `lumen_server.dart`.
/// - WebSocket transport — see `lumen_event_bus.dart`.
///
/// **`ChangeNotifier`** so the Settings panel can reactively render
/// the pairing modal countdown and the paired-devices list.
class LumenPairingService extends ChangeNotifier {
  /// Pairing codes are 6 numeric digits — short enough to type on a
  /// phone, long enough that a 60s window plus single-use makes
  /// brute-forcing impractical (1M space, single attempt only).
  static const int _kCodeLength = 6;

  /// Pairing codes expire after this duration. Short enough that an
  /// abandoned modal doesn't leave a weakening attack window; long
  /// enough that a phone user can read + type without rushing.
  static const Duration _kCodeTtl = Duration(seconds: 60);

  /// Bearer tokens are 32 bytes (256 bits) of OS CSPRNG output,
  /// base64url-encoded (43 chars, no padding). Plenty of entropy.
  static const int _kTokenBytes = 32;

  PendingPairing? _pending;
  final List<PairedDevice> _devices = [];
  bool _loaded = false;
  Timer? _expiryTimer;

  // Hash → device-id index, rebuilt on every devices mutation. This
  // is what the auth middleware queries on every request, so it must
  // be O(1).
  Map<String, String> _hashIndex = const {};

  /// Loaded paired devices. Public to drive the Settings UI list.
  /// Returns an unmodifiable copy so callers can't mutate the
  /// internal list and bypass `_save`.
  List<PairedDevice> get devices => List.unmodifiable(_devices);

  /// True between [generateCode] and the moment a phone consumes the
  /// code (or the TTL expires). The Settings UI uses this to render
  /// the live modal.
  PendingPairing? get pendingPairing => _pending;

  /// Read paired devices from disk. Idempotent — safe to call from
  /// multiple boot paths.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final f = await _devicesFile();
      if (await f.exists()) {
        final raw = await f.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        final list = (json['devices'] as List?) ?? const [];
        _devices.clear();
        for (final e in list) {
          if (e is! Map) continue;
          try {
            _devices.add(PairedDevice.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {
            // Skip malformed entries rather than fail the whole load.
            // A corrupted device entry shouldn't lock anyone out.
          }
        }
        _rebuildIndex();
      }
    } catch (e) {
      debugPrint('LumenPairingService: failed to load paired devices: $e');
    }
    notifyListeners();
  }

  /// Mint a fresh pairing code. Replaces any existing pending code
  /// (so clicking "Show pairing code" again rotates the value).
  /// Returns the code in plaintext for display in the desktop UI.
  PendingPairing generateCode() {
    _expiryTimer?.cancel();
    final rng = Random.secure();
    // 6-digit zero-padded numeric. Numeric so it types easily on
    // a phone keyboard; the entropy is bounded by the 60s + single-
    // use guarantees, not by the alphabet.
    final n = rng.nextInt(1000000);
    final code = n.toString().padLeft(_kCodeLength, '0');
    final expiresAt = DateTime.now().add(_kCodeTtl);
    _pending = PendingPairing(code: code, expiresAt: expiresAt);
    _expiryTimer = Timer(_kCodeTtl, () {
      // Tick once after TTL to clear and notify; auto-expiry without
      // an external trigger keeps the UI honest.
      if (_pending != null && DateTime.now().isAfter(_pending!.expiresAt)) {
        _pending = null;
        notifyListeners();
      }
    });
    notifyListeners();
    return _pending!;
  }

  /// Cancel the pending code without consuming it. Used when the
  /// user closes the pairing modal manually.
  void cancelCode() {
    if (_pending == null) return;
    _expiryTimer?.cancel();
    _pending = null;
    notifyListeners();
  }

  /// Consume the pending code and register a new device. Returns
  /// the freshly-minted bearer token in plaintext (the caller, an
  /// HTTP route, hands it to the device once and never again — only
  /// the SHA-256 hash lives on disk).
  ///
  /// Throws [PairingError] on every failure path so the route can
  /// translate into the right HTTP status. Distinct error codes for
  /// distinct failures so the Android client can render a useful
  /// message instead of a generic "pairing failed."
  Future<PairingResult> consumeCode({
    required String code,
    required String deviceName,
  }) async {
    final normalized = code.trim();
    if (normalized.isEmpty) {
      throw PairingError('missing_code', 'No pairing code provided.');
    }
    final pending = _pending;
    if (pending == null) {
      throw PairingError('no_pending_code',
          'No pairing code is active. Generate one in Settings → Remote Access.');
    }
    if (DateTime.now().isAfter(pending.expiresAt)) {
      _pending = null;
      _expiryTimer?.cancel();
      notifyListeners();
      throw PairingError(
          'expired_code', 'The pairing code has expired. Generate a new one.');
    }
    if (pending.code != normalized) {
      throw PairingError('invalid_code', 'Pairing code does not match.');
    }
    // Code valid → consume single-use immediately, BEFORE we mint
    // the token, so a concurrent retry races into `no_pending_code`
    // rather than handing out two tokens for one code.
    _pending = null;
    _expiryTimer?.cancel();

    final token = _generateToken();
    final tokenHash = _sha256B64(token);
    final device = PairedDevice(
      id: _generateDeviceId(),
      name: _sanitizeDeviceName(deviceName),
      tokenHash: tokenHash,
      createdAt: DateTime.now(),
      lastSeenAt: DateTime.now(),
    );
    _devices.add(device);
    _rebuildIndex();
    await _save();
    notifyListeners();
    return PairingResult(token: token, device: device);
  }

  /// Validate an incoming bearer token. Returns the matching
  /// device id on success, null on failure. Does NOT update
  /// `lastSeenAt` — call [touchDevice] explicitly when you want
  /// liveness tracking to fire (we keep that decision in the
  /// middleware so token validation stays cheap and read-only).
  String? deviceIdForToken(String token) {
    if (token.isEmpty) return null;
    return _hashIndex[_sha256B64(token)];
  }

  /// Bump `lastSeenAt` for a device. Throttled internally to once
  /// per minute per device so we don't write the file on every
  /// authenticated request.
  Future<void> touchDevice(String deviceId) async {
    final idx = _devices.indexWhere((d) => d.id == deviceId);
    if (idx < 0) return;
    final d = _devices[idx];
    final now = DateTime.now();
    if (now.difference(d.lastSeenAt) < const Duration(minutes: 1)) return;
    _devices[idx] = d.copyWith(lastSeenAt: now);
    await _save();
    // No notifyListeners — settings UI doesn't need to rebuild on
    // every minute-tick of last-seen.
  }

  /// Remove a paired device. Returns true if it was present.
  Future<bool> revokeDevice(String deviceId) async {
    final before = _devices.length;
    _devices.removeWhere((d) => d.id == deviceId);
    if (_devices.length == before) return false;
    _rebuildIndex();
    await _save();
    notifyListeners();
    return true;
  }

  /// Remove all paired devices. Useful "panic button" if the user
  /// thinks a token has been compromised.
  Future<void> revokeAll() async {
    if (_devices.isEmpty) return;
    _devices.clear();
    _rebuildIndex();
    await _save();
    notifyListeners();
  }

  // ── internals ────────────────────────────────────────────────

  void _rebuildIndex() {
    _hashIndex = {for (final d in _devices) d.tokenHash: d.id};
  }

  Future<File> _devicesFile() async {
    final base = await getApplicationSupportDirectory();
    return File(p.join(base.path, 'remote_paired_devices.json'));
  }

  Future<void> _save() async {
    try {
      final f = await _devicesFile();
      final body = jsonEncode({
        'devices': _devices.map((d) => d.toJson()).toList(),
      });
      await f.writeAsString(body);
    } catch (e) {
      debugPrint('LumenPairingService: failed to save paired devices: $e');
    }
  }

  static String _sha256B64(String input) {
    final h = sha256.convert(utf8.encode(input));
    return base64Url.encode(h.bytes).replaceAll('=', '');
  }

  static String _generateToken() {
    final rng = Random.secure();
    final bytes = List<int>.generate(_kTokenBytes, (_) => rng.nextInt(256));
    return base64Url.encode(bytes).replaceAll('=', '');
  }

  static String _generateDeviceId() {
    // Same shape as the install id (32 hex chars) for visual
    // consistency in the settings list. Distinct random space
    // (16 bytes / Random.secure).
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// Trim, cap length at 64 chars, drop control characters. The
  /// device name shows up in the desktop settings UI verbatim;
  /// don't let a remote client smuggle terminal escapes or 10KB of
  /// emoji into a label.
  static String _sanitizeDeviceName(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return 'Unnamed device';
    final filtered = trimmed.replaceAll(
      RegExp(r'[\x00-\x1f\x7f]'),
      '',
    );
    if (filtered.length <= 64) return filtered;
    return filtered.substring(0, 64);
  }

  @override
  void dispose() {
    _expiryTimer?.cancel();
    super.dispose();
  }
}

class PendingPairing {
  PendingPairing({required this.code, required this.expiresAt});
  final String code;
  final DateTime expiresAt;

  Duration get remaining {
    final r = expiresAt.difference(DateTime.now());
    return r.isNegative ? Duration.zero : r;
  }
}

@immutable
class PairedDevice {
  const PairedDevice({
    required this.id,
    required this.name,
    required this.tokenHash,
    required this.createdAt,
    required this.lastSeenAt,
  });

  final String id;
  final String name;
  final String tokenHash;
  final DateTime createdAt;
  final DateTime lastSeenAt;

  PairedDevice copyWith({
    String? id,
    String? name,
    String? tokenHash,
    DateTime? createdAt,
    DateTime? lastSeenAt,
  }) {
    return PairedDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      tokenHash: tokenHash ?? this.tokenHash,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'tokenHash': tokenHash,
        'createdAt': createdAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
      };

  /// JSON shape sent to the client (no `tokenHash` exposed — that's
  /// internal storage detail).
  Map<String, dynamic> toClientJson() => {
        'id': id,
        'name': name,
        'createdAt': createdAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
      };

  factory PairedDevice.fromJson(Map<String, dynamic> j) {
    return PairedDevice(
      id: j['id'] as String,
      name: (j['name'] ?? 'Unnamed device') as String,
      tokenHash: j['tokenHash'] as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      lastSeenAt: DateTime.parse(j['lastSeenAt'] as String),
    );
  }
}

class PairingResult {
  PairingResult({required this.token, required this.device});
  final String token;
  final PairedDevice device;
}

/// Structured pairing failure. The string [code] maps 1:1 to the
/// `error` field the route returns — translate into HTTP status at
/// the route boundary, not here.
class PairingError implements Exception {
  PairingError(this.code, this.message);
  final String code;
  final String message;

  @override
  String toString() => 'PairingError($code): $message';
}
