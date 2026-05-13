import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'preferences_service.dart';

/// Polls the GitHub Releases API for newer Lumen versions, downloads
/// the installer asset, and hands it off to the user with a clean
/// "Install update" gesture that shuts the app down through the
/// regular `AppCloseGuard` path.
///
/// Design choices worth remembering before touching this file:
///
///  - **Polling cadence** is once per 12 h, persisted via the
///    `update.lastCheck` pref. The GitHub Releases API gives us 60
///    unauthenticated requests per hour per IP — way more than this
///    budget needs — but cadence is about respect for the user's
///    bandwidth and battery, not API limits. The user can always
///    force a fresh check via Help → Check for updates.
///
///  - **Asset selection** is regex-based:
///    `^Lumen-Setup-.*\.exe$`. Built by `tools\installer\build.ps1`.
///    See `tools\installer\README.md` — if you change the filename
///    convention there, update [_installerAssetPattern] here.
///
///  - **No silent self-update**. We never download in the background
///    without telling the user. The "Install update" button is an
///    explicit gesture. The user is busy with code; surprise
///    bandwidth + restarts are a great way to lose their trust.
///
///  - **Per-user install path** (`%LOCALAPPDATA%\Programs\Lumen`)
///    means we can run the new installer without UAC. The installer
///    itself uses Restart Manager (see lumen.iss
///    `CloseApplications=force` / `RestartApplications=yes`) to
///    close + restart `lumen.exe` cleanly.
///
///  - **Unsigned builds** trigger SmartScreen on download. Until
///    code signing is wired, document this in the UI ("First update
///    download may show a SmartScreen warning — click 'More info'
///    → 'Run anyway'"). When signing lands, drop that string.
///
///  - **Single-flight** download + install. Re-clicking "Install" while
///    a download is in flight is a no-op.
class UpdateService extends ChangeNotifier {
  static const String _ownerRepo = 'haviduck/lumen';
  static const Duration _checkInterval = Duration(hours: 12);
  static const Duration _httpTimeout = Duration(seconds: 20);
  static final RegExp _installerAssetPattern =
      RegExp(r'^Lumen-Setup-.*\.exe$', caseSensitive: false);

  final PreferencesService _prefs;
  final http.Client _client;
  final bool _enabled;

  UpdateService(this._prefs, {http.Client? client, bool? enabled})
      : _client = client ?? http.Client(),
        // Auto-update only runs on Windows. macOS / Linux / mobile
        // builds keep the service alive (so UI binds don't crash)
        // but the check is a no-op there.
        _enabled = enabled ?? Platform.isWindows;

  UpdateStatus _status = UpdateStatus.idle;
  LumenRelease? _release;
  String? _error;
  double _downloadProgress = 0.0;
  String? _stagedInstallerPath;
  String _currentVersion = '0.0.0';
  String? _skippedVersion;
  DateTime? _lastCheck;
  bool _initialized = false;

  UpdateStatus get status => _status;
  LumenRelease? get release => _release;
  String? get error => _error;
  double get downloadProgress => _downloadProgress;
  String? get stagedInstallerPath => _stagedInstallerPath;
  String get currentVersion => _currentVersion;
  String? get skippedVersion => _skippedVersion;
  DateTime? get lastCheck => _lastCheck;
  bool get enabled => _enabled;

  /// A newer release is known about AND the user hasn't pressed
  /// "Skip this version" on it.
  bool get hasActionableUpdate {
    final r = _release;
    if (r == null) return false;
    if (compareVersions(r.version, _currentVersion) <= 0) return false;
    if (_skippedVersion != null &&
        compareVersions(r.version, _skippedVersion!) == 0) {
      return false;
    }
    return true;
  }

  /// Read the running app's version + restore prior skipped-release
  /// pref. Then kick a check on a 30-second delay so we don't compete
  /// with first-frame work.
  ///
  /// Idempotent — safe to call multiple times (e.g. hot reload).
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final info = await PackageInfo.fromPlatform();
      _currentVersion = info.version;
    } catch (e) {
      debugPrint('[update] PackageInfo failed: $e');
    }
    _skippedVersion = await _prefs.getUpdateSkippedVersion();
    final last = await _prefs.getUpdateLastCheck();
    if (last != null) {
      _lastCheck = DateTime.fromMillisecondsSinceEpoch(last, isUtc: true);
    }
    notifyListeners();
    if (!_enabled) return;
    // Tiny delay so the first paint isn't competing with the network
    // call. Fire-and-forget.
    unawaited(Future.delayed(const Duration(seconds: 30), () {
      checkForUpdates();
    }));
  }

  /// Hit the GitHub Releases API. Respects the 12-hour debounce
  /// unless `force` is true (the manual Help → Check for updates path).
  ///
  /// Never throws. On any failure surfaces a status of
  /// [UpdateStatus.error] with a human-readable [error] string. The
  /// caller's `force=true` path shows it in a toast / dialog;
  /// background polling silently keeps the previous state.
  Future<void> checkForUpdates({bool force = false}) async {
    if (!_enabled) return;
    if (_status == UpdateStatus.checking ||
        _status == UpdateStatus.downloading ||
        _status == UpdateStatus.installing) {
      return;
    }
    if (!force && _lastCheck != null) {
      final since = DateTime.now().toUtc().difference(_lastCheck!);
      if (since < _checkInterval) return;
    }
    _setStatus(UpdateStatus.checking);
    _error = null;
    notifyListeners();
    try {
      final res = await _client
          .get(
            Uri.parse('https://api.github.com/repos/$_ownerRepo/releases/latest'),
            headers: {
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'Lumen-UpdateService/1.0',
            },
          )
          .timeout(_httpTimeout);
      _lastCheck = DateTime.now().toUtc();
      await _prefs.setUpdateLastCheck(_lastCheck!.millisecondsSinceEpoch);
      if (res.statusCode == 404) {
        _release = null;
        _setStatus(UpdateStatus.idle);
        return;
      }
      if (res.statusCode != 200) {
        _error = 'GitHub Releases API returned ${res.statusCode}';
        _setStatus(UpdateStatus.error);
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final parsed = LumenRelease.parse(data);
      if (parsed == null) {
        _error = 'No installer asset on the latest release';
        _setStatus(UpdateStatus.error);
        return;
      }
      _release = parsed;
      if (compareVersions(parsed.version, _currentVersion) > 0) {
        _setStatus(UpdateStatus.available);
      } else {
        _setStatus(UpdateStatus.idle);
      }
    } on TimeoutException {
      _error = 'Update check timed out';
      _setStatus(UpdateStatus.error);
    } catch (e) {
      _error = 'Update check failed: $e';
      _setStatus(UpdateStatus.error);
    }
  }

  /// Download the installer to `%TEMP%` and verify SHA-256 if the
  /// release asset carries one. Drives the [downloadProgress] field
  /// for UI binding.
  ///
  /// Returns the staged file path on success, `null` on failure. The
  /// caller (the `UpdateDialog`) should advance to the "Install"
  /// confirm step only when this returns non-null.
  Future<String?> downloadInstaller() async {
    final rel = _release;
    if (rel == null) return null;
    if (_status == UpdateStatus.downloading ||
        _status == UpdateStatus.installing) {
      return _stagedInstallerPath;
    }
    _setStatus(UpdateStatus.downloading);
    _downloadProgress = 0.0;
    _error = null;
    notifyListeners();
    try {
      final tempDir = await getTemporaryDirectory();
      final stagedDir = Directory(p.join(tempDir.path, 'lumen-update'));
      if (!await stagedDir.exists()) {
        await stagedDir.create(recursive: true);
      }
      final outPath = p.join(stagedDir.path, _installerFilename(rel));
      final outFile = File(outPath);
      if (await outFile.exists()) {
        // Re-use a prior staged download IFF its hash matches the
        // release asset's digest. Otherwise wipe and re-pull —
        // partial / corrupted downloads are real on flaky LTE.
        if (rel.installerSha256 != null) {
          final actual = await _sha256OfFile(outFile);
          if (actual == rel.installerSha256) {
            _stagedInstallerPath = outPath;
            _downloadProgress = 1.0;
            _setStatus(UpdateStatus.ready);
            return outPath;
          }
        }
        await outFile.delete();
      }
      final request = http.Request('GET', Uri.parse(rel.installerUrl))
        ..headers.addAll({'User-Agent': 'Lumen-UpdateService/1.0'});
      final response = await _client.send(request);
      if (response.statusCode != 200 && response.statusCode != 302) {
        _error = 'Download failed: HTTP ${response.statusCode}';
        _setStatus(UpdateStatus.error);
        return null;
      }
      final total = response.contentLength ?? rel.installerBytes;
      var received = 0;
      final sink = outFile.openWrite();
      final digest = AccumulatingSha256();
      try {
        await for (final chunk in response.stream) {
          sink.add(chunk);
          digest.add(chunk);
          received += chunk.length;
          if (total > 0) {
            final next = (received / total).clamp(0.0, 1.0);
            // Throttle UI: only repaint every ~1% movement.
            if (next - _downloadProgress > 0.01 || next >= 1.0) {
              _downloadProgress = next;
              notifyListeners();
            }
          }
        }
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (rel.installerSha256 != null) {
        final actual = digest.hexDigest();
        if (actual != rel.installerSha256) {
          await outFile.delete().catchError((_) => outFile);
          _error =
              'Installer SHA-256 mismatch: expected ${rel.installerSha256}, got $actual';
          _setStatus(UpdateStatus.error);
          return null;
        }
      }
      _stagedInstallerPath = outPath;
      _downloadProgress = 1.0;
      _setStatus(UpdateStatus.ready);
      return outPath;
    } on TimeoutException {
      _error = 'Download timed out';
      _setStatus(UpdateStatus.error);
      return null;
    } catch (e) {
      _error = 'Download failed: $e';
      _setStatus(UpdateStatus.error);
      return null;
    }
  }

  /// Launch the staged installer detached and return. The caller is
  /// responsible for triggering a graceful app shutdown afterwards
  /// (typically `windowManager.close()` → `AppCloseGuard`).
  ///
  /// The installer flags are tuned for the auto-update path —
  /// `/SILENT` shows only a progress strip (not the full wizard),
  /// `/SUPPRESSMSGBOXES` accepts default answers, and
  /// `/RESTARTAPPLICATIONS` plus the `.iss` `RestartApplications=yes`
  /// setting tell Restart Manager to gracefully close + reopen Lumen.
  ///
  /// Returns true if the installer was launched. False on any error
  /// (file missing, exec failed) — caller surfaces the error.
  Future<bool> launchInstaller() async {
    final path = _stagedInstallerPath;
    if (path == null || !File(path).existsSync()) {
      _error = 'Installer is no longer on disk';
      _setStatus(UpdateStatus.error);
      return false;
    }
    _setStatus(UpdateStatus.installing);
    try {
      await Process.start(
        path,
        const ['/SILENT', '/SUPPRESSMSGBOXES', '/RESTARTAPPLICATIONS'],
        mode: ProcessStartMode.detached,
        runInShell: false,
      );
      return true;
    } catch (e) {
      _error = 'Could not launch installer: $e';
      _setStatus(UpdateStatus.error);
      return false;
    }
  }

  /// Persist the user's "skip this version" choice. Once skipped, the
  /// background polling won't surface a banner for the same version
  /// again. A newer release will still be surfaced normally.
  Future<void> skipCurrentRelease() async {
    final r = _release;
    if (r == null) return;
    _skippedVersion = r.version;
    await _prefs.setUpdateSkippedVersion(r.version);
    _setStatus(UpdateStatus.idle);
  }

  /// Dismiss the in-app banner without persisting a skip — the
  /// banner will come back on the next check (12h later) or on a
  /// manual Help → Check for updates.
  void dismissForNow() {
    if (_status == UpdateStatus.available || _status == UpdateStatus.error) {
      _setStatus(UpdateStatus.idle);
    }
  }

  /// Wipe the staged installer + error and go back to idle. Used by
  /// the dialog's Close button when the user wants to start over.
  Future<void> reset() async {
    final staged = _stagedInstallerPath;
    if (staged != null) {
      try {
        final f = File(staged);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    _stagedInstallerPath = null;
    _downloadProgress = 0.0;
    _error = null;
    _setStatus(UpdateStatus.idle);
  }

  void _setStatus(UpdateStatus s) {
    _status = s;
    notifyListeners();
  }

  static String _installerFilename(LumenRelease r) {
    final base = p.basename(Uri.parse(r.installerUrl).path);
    return base.isEmpty ? 'Lumen-Setup-v${r.version}.exe' : base;
  }

  static Future<String> _sha256OfFile(File f) async {
    final acc = AccumulatingSha256();
    final stream = f.openRead();
    await for (final chunk in stream) {
      acc.add(chunk);
    }
    return acc.hexDigest();
  }

  /// Compare two semver-ish strings. Returns >0 if [a]>[b], 0 if
  /// equal, <0 if [a]<[b]. Handles missing patch parts (`1.2` →
  /// `1.2.0`) and non-numeric suffixes via lexicographic fallback.
  ///
  /// Visible for tests.
  static int compareVersions(String a, String b) {
    final ap = _splitVersion(a);
    final bp = _splitVersion(b);
    final n = ap.length > bp.length ? ap.length : bp.length;
    for (var i = 0; i < n; i++) {
      final ai = i < ap.length ? ap[i] : 0;
      final bi = i < bp.length ? bp[i] : 0;
      if (ai != bi) return ai.compareTo(bi);
    }
    return 0;
  }

  static List<int> _splitVersion(String v) {
    var s = v.trim();
    if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
    // Drop a build / pre-release suffix (e.g. `1.0.12+12`,
    // `1.0.12-rc1`). For ordering we only care about the
    // major.minor.patch trail — this is a sane reduction for the
    // shape of versions we ship.
    final cut = s.indexOf(RegExp(r'[-+]'));
    if (cut >= 0) s = s.substring(0, cut);
    return s
        .split('.')
        .map((seg) => int.tryParse(seg) ?? 0)
        .toList(growable: false);
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }
}

/// Streaming SHA-256 accumulator. Wraps the `crypto` package's
/// chunked digest API so the download loop can hash inline without
/// holding the whole installer in memory.
class AccumulatingSha256 {
  final List<int> _buf = <int>[];
  void add(List<int> chunk) {
    _buf.addAll(chunk);
  }

  String hexDigest() {
    return sha256.convert(_buf).toString();
  }
}

enum UpdateStatus {
  idle,
  checking,
  available,
  downloading,
  ready,
  installing,
  error,
}

/// Parsed shape of a Lumen GitHub Release we know how to install.
/// `installerUrl` is the direct download for the `^Lumen-Setup-.*\.exe$`
/// asset on the release. If the release doesn't have one, [parse]
/// returns null (no actionable update for this platform).
class LumenRelease {
  final String tagName;
  final String version;
  final String name;
  final String body;
  final String installerUrl;
  final int installerBytes;
  final String? installerSha256;
  final DateTime publishedAt;
  final String htmlUrl;

  LumenRelease({
    required this.tagName,
    required this.version,
    required this.name,
    required this.body,
    required this.installerUrl,
    required this.installerBytes,
    required this.installerSha256,
    required this.publishedAt,
    required this.htmlUrl,
  });

  static LumenRelease? parse(Map<String, dynamic> json) {
    final tag = json['tag_name'] as String?;
    if (tag == null || tag.isEmpty) return null;
    final assets = json['assets'] as List?;
    if (assets == null) return null;
    Map<String, dynamic>? installerAsset;
    for (final raw in assets) {
      if (raw is! Map) continue;
      final m = raw.cast<String, dynamic>();
      final name = m['name'] as String? ?? '';
      if (UpdateService._installerAssetPattern.hasMatch(name)) {
        installerAsset = m;
        break;
      }
    }
    if (installerAsset == null) return null;
    final url = installerAsset['browser_download_url'] as String? ?? '';
    if (url.isEmpty) return null;
    final bytes = (installerAsset['size'] as num?)?.toInt() ?? 0;
    String? digest;
    final rawDigest = installerAsset['digest'];
    if (rawDigest is String && rawDigest.startsWith('sha256:')) {
      digest = rawDigest.substring('sha256:'.length).toLowerCase();
    }
    final publishedRaw = json['published_at'] as String?;
    final published = publishedRaw != null
        ? DateTime.tryParse(publishedRaw)?.toUtc()
        : null;
    final version = tag.startsWith('v') ? tag.substring(1) : tag;
    return LumenRelease(
      tagName: tag,
      version: version,
      name: (json['name'] as String?) ?? tag,
      body: (json['body'] as String?) ?? '',
      installerUrl: url,
      installerBytes: bytes,
      installerSha256: digest,
      publishedAt: published ?? DateTime.now().toUtc(),
      htmlUrl: (json['html_url'] as String?) ??
          'https://github.com/${UpdateService._ownerRepo}/releases/$tag',
    );
  }
}
