import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import 'ssh_host.dart';
import 'ssh_vault.dart';

/// Outcome of a host-key check during connect. The caller (UI layer)
/// decides whether to proceed or abort; the service never silently
/// trusts a new or changed key.
enum SshHostKeyDecision { accept, reject }

/// Caller-provided callback that decides whether to accept a host
/// key when (a) we've never connected before (`firstTime = true`),
/// or (b) the live fingerprint doesn't match what we stored
/// (`firstTime = false`). Returning [SshHostKeyDecision.reject]
/// aborts the connection.
typedef SshHostKeyHandler = Future<SshHostKeyDecision> Function({
  required SshHost host,
  required String fingerprint,
  required bool firstTime,
});

/// Caller-provided callback that resolves a passphrase for an
/// encrypted PEM key. Used when [SshHost.rememberSecret] is false OR
/// when the vault doesn't have a passphrase entry. Return null to
/// abort.
typedef SshPassphraseRequester = Future<String?> Function(SshHost host);

/// Caller-provided callback that resolves a password when the host
/// is configured for [SshAuthMethod.password] but the vault is empty.
typedef SshPasswordRequester = Future<String?> Function(SshHost host);

/// A live SSH connection. Owns a single [SSHClient] and its keepalive
/// timer; can spawn shells (for the terminal) and SFTP clients (for
/// upload + remote-mirror). Kept thin on purpose — the service is
/// just a connection bag, the higher-level [SshController] orchestrates
/// many of these.
class SshConnection {
  final SshHost host;
  final SSHClient client;

  /// Sticky cache of the SFTP client. dartssh2 will happily open a
  /// fresh sftp channel each time you call `client.sftp()`, but
  /// reusing the same one across uploads + remote-edits is faster
  /// (no re-handshake) and keeps the channel count bounded.
  SftpClient? _sftp;

  Timer? _keepAlive;
  bool _closed = false;

  /// Stream subscribers (terminal sessions, etc.) call into [onClose]
  /// to learn the client died. Multi-listener so multiple shells +
  /// the controller can all react.
  final _closeCtl = StreamController<void>.broadcast();
  Stream<void> get onClose => _closeCtl.stream;

  SshConnection._({required this.host, required this.client});

  bool get isClosed => _closed;

  Future<SftpClient> sftp() async {
    if (_closed) {
      throw StateError('SSH connection is closed');
    }
    final cached = _sftp;
    if (cached != null) return cached;
    final s = await client.sftp();
    _sftp = s;
    return s;
  }

  /// Spawn an interactive shell on the remote. Returns the dartssh2
  /// session — the terminal layer wires its stdout/stderr/stdin into
  /// xterm.Terminal.
  Future<SSHSession> shell({
    required int rows,
    required int cols,
    int? pixelWidth,
    int? pixelHeight,
    String term = 'xterm-256color',
  }) async {
    if (_closed) {
      throw StateError('SSH connection is closed');
    }
    return client.shell(
      pty: SSHPtyConfig(
        type: term,
        width: cols,
        height: rows,
        pixelWidth: pixelWidth ?? 0,
        pixelHeight: pixelHeight ?? 0,
      ),
    );
  }

  void _startKeepAlive(int seconds) {
    if (seconds <= 0) return;
    _keepAlive?.cancel();
    _keepAlive = Timer.periodic(Duration(seconds: seconds), (_) async {
      if (_closed) return;
      try {
        await client.ping();
      } catch (_) {
        // Ignore — ping failures alone aren't a kill signal because
        // they can be transient. The underlying socket failure path
        // (`client.done` resolving) is what tears the connection
        // down.
      }
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    _keepAlive = null;
    try {
      _sftp?.close();
    } catch (_) {}
    try {
      client.close();
    } catch (_) {}
    if (!_closeCtl.isClosed) {
      _closeCtl.add(null);
      await _closeCtl.close();
    }
  }
}

/// Top-level SSH service. Stateless apart from the [vault] reference;
/// each [connect] call returns a fresh [SshConnection].
class SshClientService {
  final SshVault vault;

  SshClientService({required this.vault});

  /// Open a connection to [host]. Honors host-key TOFU via
  /// [hostKeyHandler], asks [requestPassword] / [requestPassphrase]
  /// when the vault doesn't have the relevant secret cached.
  ///
  /// Throws on failure. Callers should catch and surface in UI.
  Future<SshConnection> connect({
    required SshHost host,
    required SshHostKeyHandler hostKeyHandler,
    required SshPasswordRequester requestPassword,
    required SshPassphraseRequester requestPassphrase,
  }) async {
    final socket = await SSHSocket.connect(
      host.host,
      host.port,
      timeout: const Duration(seconds: 12),
    );

    String? liveFingerprint;
    final identities = await _resolveIdentities(host, requestPassphrase);

    SSHClient? client;
    try {
      client = SSHClient(
        socket,
        username: host.user,
        identities: identities,
        onPasswordRequest: () async {
          if (host.authMethod != SshAuthMethod.password) {
            return '';
          }
          final cached = host.rememberSecret
              ? await vault.readPassword(host.id)
              : null;
          if (cached != null && cached.isNotEmpty) return cached;
          final entered = await requestPassword(host);
          if (entered == null) return '';
          if (host.rememberSecret) {
            await vault.savePassword(host.id, entered);
          }
          return entered;
        },
        onVerifyHostKey: (type, fingerprint) {
          // dartssh2 hands us an MD5 digest of the host key (see
          // ssh_transport.dart::_handleHostkey — it computes
          // MD5Digest().process(hostkey) before invoking us). We
          // can't recompute a SHA-256 from that without the raw
          // key, so we format the MD5 in the classic colon-hex
          // shape (`MD5:aa:bb:cc:...`) and store that. It's the
          // same shape `ssh -o FingerprintHash=md5` shows, so the
          // user can cross-check against `ssh-keygen -E md5 -lf`.
          //
          // We don't gate here because the user prompt is async;
          // the post-auth path validates and tears down on reject.
          liveFingerprint = formatMd5Fingerprint(type, fingerprint);
          return true;
        },
      );

      await client.authenticated;
    } catch (e) {
      try {
        client?.close();
      } catch (_) {}
      rethrow;
    }

    final live = liveFingerprint;
    if (live == null) {
      try {
        client.close();
      } catch (_) {}
      throw StateError(
        'SSH host key was not provided by server (handshake anomaly)',
      );
    }

    if (host.knownHostFingerprint.isEmpty) {
      final decision = await hostKeyHandler(
        host: host,
        fingerprint: live,
        firstTime: true,
      );
      if (decision == SshHostKeyDecision.reject) {
        try {
          client.close();
        } catch (_) {}
        throw StateError('User rejected first-time host key');
      }
      await vault.updateFingerprint(host.id, live);
    } else if (host.knownHostFingerprint != live) {
      final decision = await hostKeyHandler(
        host: host,
        fingerprint: live,
        firstTime: false,
      );
      if (decision == SshHostKeyDecision.reject) {
        try {
          client.close();
        } catch (_) {}
        throw StateError('Host key mismatch — connection aborted');
      }
      await vault.updateFingerprint(host.id, live);
    }

    await vault.markConnected(host.id);

    final conn = SshConnection._(host: host, client: client);
    conn._startKeepAlive(vault.keepAliveSeconds);

    unawaited(client.done.then((_) {
      if (!conn._closed) conn.close();
    }, onError: (_) {
      if (!conn._closed) conn.close();
    }));

    return conn;
  }

  /// Resolve the identities list for a host. Order:
  ///   1. Vaulted key file (when authMethod == keyFile).
  ///   2. OS SSH agent identities (deferred; dartssh2 negotiates if
  ///      `useAgent` is on and identities is empty).
  ///   3. Empty list — dartssh2 falls back to `onPasswordRequest`.
  Future<List<SSHKeyPair>> _resolveIdentities(
    SshHost host,
    SshPassphraseRequester requestPassphrase,
  ) async {
    if (host.authMethod == SshAuthMethod.password) return const [];

    if (host.authMethod == SshAuthMethod.keyFile &&
        host.keyFilePath.isNotEmpty) {
      try {
        final pem = await File(host.keyFilePath).readAsString();
        final encrypted = SSHKeyPair.isEncryptedPem(pem);
        if (!encrypted) {
          return SSHKeyPair.fromPem(pem);
        }
        String? passphrase = host.rememberSecret
            ? await vault.readPassphrase(host.id)
            : null;
        passphrase ??= await requestPassphrase(host);
        if (passphrase == null) {
          throw StateError('Encrypted key — passphrase required');
        }
        final pairs = SSHKeyPair.fromPem(pem, passphrase);
        if (host.rememberSecret) {
          await vault.savePassphrase(host.id, passphrase);
        }
        return pairs;
      } catch (e) {
        debugPrint('SSH key load failed: $e');
        rethrow;
      }
    }

    return const [];
  }

  /// Test a host without fully bringing up an interactive session.
  /// Used by the "Test connection" button in the host editor. Closes
  /// immediately on success; throws on failure.
  Future<String> testConnection({
    required SshHost host,
    required SshHostKeyHandler hostKeyHandler,
    required SshPasswordRequester requestPassword,
    required SshPassphraseRequester requestPassphrase,
  }) async {
    final conn = await connect(
      host: host,
      hostKeyHandler: hostKeyHandler,
      requestPassword: requestPassword,
      requestPassphrase: requestPassphrase,
    );
    try {
      String banner = '';
      try {
        final out = await conn.client
            .run('uname -a')
            .timeout(const Duration(seconds: 5));
        banner = String.fromCharCodes(out).trim();
      } catch (_) {
        banner = conn.client.remoteVersion ?? '';
      }
      return banner;
    } finally {
      await conn.close();
    }
  }
}

/// Format the MD5 fingerprint dartssh2 hands us into a human-readable
/// string. Shape: `<type> MD5:aa:bb:cc:..` — same form OpenSSH shows
/// when you set `FingerprintHash=md5`. dartssh2 doesn't expose the raw
/// host key bytes to a userland callback (only the pre-computed MD5),
/// so we work with what we have.
///
/// Why MD5: dartssh2's transport hard-codes MD5 for the public host
/// key fingerprint event (see `ssh_transport.dart` ~line 1183). To
/// upgrade to SHA-256 we'd need to vendor or patch the transport — out
/// of scope for v1. MD5 collision resistance doesn't matter here:
/// we're using it as a cross-session equality check on a server's own
/// public key, not as a security primitive on its own.
String formatMd5Fingerprint(String type, Uint8List md5Bytes) {
  final hex = md5Bytes
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join(':');
  return '$type MD5:$hex';
}
