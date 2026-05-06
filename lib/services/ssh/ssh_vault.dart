import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ssh_host.dart';

/// Two-tier persistence for the SSH host vault.
///
/// **Metadata tier** (`shared_preferences`, key `ssh.vault.hosts`):
/// the JSON-encoded host list — labels, addresses, key file paths,
/// known-host fingerprints. Cheap to read on startup, easy to inspect
/// if anything corrupts.
///
/// **Secrets tier** (`flutter_secure_storage`, OS-keystore-backed —
/// DPAPI on Windows / Keychain on macOS / libsecret on Linux): the
/// per-host secrets, keyed by `ssh.host.<id>.password` /
/// `ssh.host.<id>.passphrase`. Never written to JSON. Survives a
/// SharedPreferences wipe; deleted by [removeHost].
///
/// **Why two tiers**: secrets storage on every platform we ship to has
/// per-key length limits and is an order of magnitude slower than
/// `shared_preferences`. Stuffing the whole vault into the secure
/// store would mean a 50ms+ wait every time the activity-bar dropdown
/// opens. Splitting metadata from secrets keeps the cold path fast and
/// the secret surface narrow.
class SshVault {
  static const String _kHostsKey = 'ssh.vault.hosts';
  static const String _kAgentEnabledKey = 'ssh.vault.useAgent';
  static const String _kKeepAliveKey = 'ssh.vault.keepAliveSeconds';
  static const int _kDefaultKeepAlive = 30;

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  final SharedPreferences _prefs;

  /// In-memory mirror of the host list. Populated by [load], mutated
  /// by add/update/remove, written back via [_persist]. The
  /// `SshController` reads from here for picker rendering and exposes
  /// it via a getter — there's no public setter on this class, so the
  /// list shape is always controlled by the vault.
  List<SshHost> _hosts = const [];

  SshVault._(this._prefs);

  static Future<SshVault> load() async {
    final prefs = await SharedPreferences.getInstance();
    final vault = SshVault._(prefs);
    final raw = prefs.getString(_kHostsKey) ?? '';
    final env = SshHostListEnvelope.decode(raw);
    vault._hosts = List.unmodifiable(env.hosts);
    return vault;
  }

  // ── Metadata API ──────────────────────────────────────────────

  List<SshHost> get hosts => _hosts;

  SshHost? findById(String id) {
    for (final h in _hosts) {
      if (h.id == id) return h;
    }
    return null;
  }

  Future<void> addHost(SshHost host) async {
    final next = [..._hosts, host];
    _hosts = List.unmodifiable(next);
    await _persist();
  }

  /// Replace a host by id. Falls back to add when the id isn't
  /// found, so callers don't have to branch on "create vs update"
  /// — the host editor dialog uses this for both Save flows.
  Future<void> upsertHost(SshHost host) async {
    final next = <SshHost>[];
    var replaced = false;
    for (final h in _hosts) {
      if (h.id == host.id) {
        next.add(host);
        replaced = true;
      } else {
        next.add(h);
      }
    }
    if (!replaced) next.add(host);
    _hosts = List.unmodifiable(next);
    await _persist();
  }

  /// Remove a host AND wipe its secrets.
  Future<void> removeHost(String id) async {
    final next = _hosts.where((h) => h.id != id).toList();
    if (next.length == _hosts.length) return;
    _hosts = List.unmodifiable(next);
    await _persist();
    await _wipeSecrets(id);
  }

  /// Update host-key fingerprint after a successful TOFU. Cheap path
  /// that avoids re-emitting the whole copyWith ladder at call sites.
  Future<void> updateFingerprint(String id, String fingerprint) async {
    final host = findById(id);
    if (host == null) return;
    await upsertHost(host.copyWith(knownHostFingerprint: fingerprint));
  }

  /// Stamp `lastConnectedAt = now` after a successful connect. Drives
  /// the "Recent" group at the top of the activity-bar fast menu.
  Future<void> markConnected(String id) async {
    final host = findById(id);
    if (host == null) return;
    await upsertHost(host.copyWith(lastConnectedAt: DateTime.now()));
  }

  /// Persist the last-used upload destination per host so the
  /// drag-drop dialog can default to it next time.
  Future<void> rememberUploadDir(String id, String dir) async {
    final host = findById(id);
    if (host == null) return;
    if (host.lastUploadDir == dir) return;
    await upsertHost(host.copyWith(lastUploadDir: dir));
  }

  // ── Secret API ────────────────────────────────────────────────

  Future<void> savePassword(String id, String value) async {
    if (value.isEmpty) {
      await _secure.delete(key: _passwordKey(id));
      return;
    }
    await _secure.write(key: _passwordKey(id), value: value);
  }

  Future<String?> readPassword(String id) async {
    return _secure.read(key: _passwordKey(id));
  }

  Future<void> savePassphrase(String id, String value) async {
    if (value.isEmpty) {
      await _secure.delete(key: _passphraseKey(id));
      return;
    }
    await _secure.write(key: _passphraseKey(id), value: value);
  }

  Future<String?> readPassphrase(String id) async {
    return _secure.read(key: _passphraseKey(id));
  }

  Future<void> _wipeSecrets(String id) async {
    await _secure.delete(key: _passwordKey(id));
    await _secure.delete(key: _passphraseKey(id));
  }

  String _passwordKey(String id) => 'ssh.host.$id.password';
  String _passphraseKey(String id) => 'ssh.host.$id.passphrase';

  // ── Settings tier (vault-wide toggles) ────────────────────────

  bool get useAgent => _prefs.getBool(_kAgentEnabledKey) ?? true;
  Future<void> setUseAgent(bool value) async {
    await _prefs.setBool(_kAgentEnabledKey, value);
  }

  int get keepAliveSeconds =>
      _prefs.getInt(_kKeepAliveKey) ?? _kDefaultKeepAlive;
  Future<void> setKeepAliveSeconds(int seconds) async {
    final clamped = seconds < 0 ? 0 : (seconds > 600 ? 600 : seconds);
    await _prefs.setInt(_kKeepAliveKey, clamped);
  }

  // ── Internals ────────────────────────────────────────────────

  Future<void> _persist() async {
    final env = SshHostListEnvelope(
      version: SshHostListEnvelope.currentVersion,
      hosts: _hosts,
    );
    await _prefs.setString(_kHostsKey, env.encode());
  }

  /// Round-trip helper used by tests; not part of the runtime path.
  String debugDumpJson() => jsonEncode(_hosts.map((h) => h.toJson()).toList());
}
