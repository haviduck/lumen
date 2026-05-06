import 'dart:convert';

/// How a host authenticates against the remote SSH server.
///
/// - [password]: classic username + password. Password lives in the
///   secure store keyed by [SshHost.id], never in the JSON metadata.
/// - [keyFile]: PEM key file on disk, optionally encrypted with a
///   passphrase. The file path is stored in metadata; the passphrase
///   (when "remember in vault" is on) lives in the secure store.
/// - [agent]: defer auth to the OS SSH agent (Windows OpenSSH agent /
///   Pageant / ssh-agent). No secret to store in our vault — the agent
///   owns key material. Lumen calls into the agent via dartssh2 when
///   the host's identities list is empty AND `useAgent` is on.
enum SshAuthMethod { password, keyFile, agent }

/// A single vaulted SSH host.
///
/// All non-secret fields ride here as JSON in shared_preferences. The
/// secret tail (password, key passphrase) lives in
/// `flutter_secure_storage` keyed by `ssh.host.<id>.<secretKind>`. Two
/// stores let us survive a corrupt vault store without leaking secrets,
/// and survive a corrupt secrets store without losing the host list.
///
/// `id` is a stable URL-safe slug derived once at creation time and
/// never reused for a different host. The Remote-mirror service uses
/// it as a directory name under `<appSupport>/lumen/ssh-mirror/<id>/`,
/// so renaming a host is a label change only — the cache survives.
class SshHost {
  final String id;
  final String label;
  final String host;
  final int port;
  final String user;
  final SshAuthMethod authMethod;

  /// Absolute path to a PEM key on disk. Only meaningful for
  /// [SshAuthMethod.keyFile]. Empty otherwise.
  final String keyFilePath;

  /// Whether the user wants the password / passphrase stored in the
  /// vault. When false, we prompt every connect.
  final bool rememberSecret;

  /// Stored host-key fingerprint (TOFU). Empty until the first
  /// successful connect. On reconnect, dartssh2's `hostKeyHandler`
  /// compares the live fingerprint against this string and prompts
  /// the user when they differ.
  final String knownHostFingerprint;

  /// When this host was last successfully connected to. Drives the
  /// "Recent" group at the top of the activity-bar fast menu. Null
  /// until the first connect. Mutable across re-saves; we update via
  /// [copyWith].
  final DateTime? lastConnectedAt;

  /// Last `cwd` the user uploaded to via the drag-drop dialog. Used
  /// as the default destination on the next upload so repeat
  /// "drop the same kind of file in the same place" flows are one
  /// Enter away. Null until first upload.
  final String? lastUploadDir;

  const SshHost({
    required this.id,
    required this.label,
    required this.host,
    required this.port,
    required this.user,
    required this.authMethod,
    this.keyFilePath = '',
    this.rememberSecret = true,
    this.knownHostFingerprint = '',
    this.lastConnectedAt,
    this.lastUploadDir,
  });

  /// User-facing display name. Falls back to `user@host:port` if the
  /// label is empty so the activity-bar menu and tab strip never show
  /// a blank entry.
  String get displayName {
    if (label.trim().isNotEmpty) return label;
    return '$user@$host:$port';
  }

  /// Friendly subtitle for menu rows: shows the technical address
  /// even when a label is set, so power users with multiple labelled
  /// jump hosts can still pick the right machine at a glance.
  String get addressLine => '$user@$host:$port';

  SshHost copyWith({
    String? label,
    String? host,
    int? port,
    String? user,
    SshAuthMethod? authMethod,
    String? keyFilePath,
    bool? rememberSecret,
    String? knownHostFingerprint,
    DateTime? lastConnectedAt,
    String? lastUploadDir,
  }) {
    return SshHost(
      id: id,
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      authMethod: authMethod ?? this.authMethod,
      keyFilePath: keyFilePath ?? this.keyFilePath,
      rememberSecret: rememberSecret ?? this.rememberSecret,
      knownHostFingerprint: knownHostFingerprint ?? this.knownHostFingerprint,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      lastUploadDir: lastUploadDir ?? this.lastUploadDir,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'host': host,
        'port': port,
        'user': user,
        'auth': authMethod.name,
        'keyFilePath': keyFilePath,
        'rememberSecret': rememberSecret,
        'knownHostFingerprint': knownHostFingerprint,
        'lastConnectedAt': lastConnectedAt?.toIso8601String(),
        'lastUploadDir': lastUploadDir,
      };

  static SshHost? fromJson(Map<String, dynamic> json) {
    final id = json['id'] as String?;
    final host = json['host'] as String?;
    final user = json['user'] as String?;
    if (id == null || host == null || user == null) return null;
    SshAuthMethod auth;
    switch (json['auth'] as String?) {
      case 'password':
        auth = SshAuthMethod.password;
        break;
      case 'agent':
        auth = SshAuthMethod.agent;
        break;
      case 'keyFile':
      default:
        auth = SshAuthMethod.keyFile;
    }
    final lastConnRaw = json['lastConnectedAt'] as String?;
    DateTime? lastConn;
    if (lastConnRaw != null) {
      try {
        lastConn = DateTime.parse(lastConnRaw);
      } catch (_) {}
    }
    return SshHost(
      id: id,
      label: (json['label'] as String?) ?? '',
      host: host,
      port: (json['port'] as int?) ?? 22,
      user: user,
      authMethod: auth,
      keyFilePath: (json['keyFilePath'] as String?) ?? '',
      rememberSecret: (json['rememberSecret'] as bool?) ?? true,
      knownHostFingerprint:
          (json['knownHostFingerprint'] as String?) ?? '',
      lastConnectedAt: lastConn,
      lastUploadDir: json['lastUploadDir'] as String?,
    );
  }

  /// Generate a stable URL-safe slug for use as the host id. Mixes the
  /// label (when set), `user@host:port`, and a millisecond timestamp
  /// so two hosts with identical labels still get distinct ids and the
  /// cache directories never collide.
  static String generateId({
    required String label,
    required String user,
    required String host,
    required int port,
  }) {
    final base = label.trim().isNotEmpty
        ? label.trim()
        : '$user@$host:$port';
    final slug = base
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
    return slug.isEmpty ? 'host-$ts' : '$slug-$ts';
  }
}

/// JSON envelope for the host list. Bumps `version` so we can migrate
/// in place if the shape changes.
class SshHostListEnvelope {
  static const int currentVersion = 1;

  final int version;
  final List<SshHost> hosts;

  const SshHostListEnvelope({
    required this.version,
    required this.hosts,
  });

  String encode() => jsonEncode({
        'version': version,
        'hosts': hosts.map((h) => h.toJson()).toList(),
      });

  static SshHostListEnvelope decode(String raw) {
    if (raw.trim().isEmpty) {
      return const SshHostListEnvelope(version: currentVersion, hosts: []);
    }
    try {
      final parsed = jsonDecode(raw);
      if (parsed is! Map<String, dynamic>) {
        return const SshHostListEnvelope(version: currentVersion, hosts: []);
      }
      final list = (parsed['hosts'] as List<dynamic>?) ?? const [];
      final hosts = <SshHost>[];
      for (final item in list) {
        if (item is Map<String, dynamic>) {
          final h = SshHost.fromJson(item);
          if (h != null) hosts.add(h);
        }
      }
      return SshHostListEnvelope(
        version: (parsed['version'] as int?) ?? currentVersion,
        hosts: hosts,
      );
    } catch (_) {
      return const SshHostListEnvelope(version: currentVersion, hosts: []);
    }
  }
}
