import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'council_models.dart';

/// One report on disk: the markdown file and (optionally) its JSON sidecar.
///
/// Sidecar parsing is deliberately tolerant — a missing or corrupt `.json`
/// must never blank the browser dialog. Per-file failures are isolated and
/// surfaced via [sidecarOk].
class CouncilReportEntry {
  final String markdownPath;
  final String? sidecarPath;
  final String title;
  final String summary;
  final List<String> agentRoster;
  final DateTime savedAt;
  final String runId;
  final int sizeBytes;
  final bool sidecarOk;

  const CouncilReportEntry({
    required this.markdownPath,
    required this.sidecarPath,
    required this.title,
    required this.summary,
    required this.agentRoster,
    required this.savedAt,
    required this.runId,
    required this.sizeBytes,
    required this.sidecarOk,
  });

  String get fileName => p.basename(markdownPath);
}

/// Lightweight metadata extracted from a persisted session JSON without
/// deserializing the full event/transcript payload.
class CouncilSessionSummary {
  final String filePath;
  final String id;
  final String title;
  final String brief;
  final String status;
  final int roundIndex;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final List<String> agentNames;
  final int eventCount;
  final bool hasReport;

  const CouncilSessionSummary({
    required this.filePath,
    required this.id,
    required this.title,
    required this.brief,
    required this.status,
    required this.roundIndex,
    required this.startedAt,
    this.finishedAt,
    required this.agentNames,
    required this.eventCount,
    required this.hasReport,
  });

  Duration? get duration =>
      finishedAt != null ? finishedAt!.difference(startedAt) : null;

  static CouncilSessionSummary fromJson(
    Map<String, dynamic> json,
    String filePath,
  ) {
    final config =
        (json['config'] as Map?)?.cast<String, dynamic>() ?? const {};
    final agents = (config['agents'] as List?) ?? const [];
    final agentNames = <String>[
      if (config['orchestrator'] is Map)
        (config['orchestrator'] as Map)['name'] as String? ?? 'Orchestrator',
      for (final a in agents)
        if (a is Map) a['name'] as String? ?? '',
      if (config['finalEvaluator'] is Map)
        (config['finalEvaluator'] as Map)['name'] as String? ?? 'Evaluator',
    ];
    final events = (json['events'] as List?) ?? const [];
    final report = json['reportMarkdown'] as String? ?? '';
    return CouncilSessionSummary(
      filePath: filePath,
      id: config['id'] as String? ?? p.basenameWithoutExtension(filePath),
      title: (config['title'] as String?)?.trim().isNotEmpty == true
          ? (config['title'] as String).trim()
          : (config['brief'] as String? ?? '').trim(),
      brief: config['brief'] as String? ?? '',
      status: json['status'] as String? ?? 'idle',
      roundIndex: (json['roundIndex'] as num?)?.toInt() ?? 0,
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? '')
              ?.toLocal() ??
          DateTime.now(),
      finishedAt:
          DateTime.tryParse(json['finishedAt'] as String? ?? '')?.toLocal(),
      agentNames: agentNames.where((n) => n.isNotEmpty).toList(),
      eventCount: events.length,
      hasReport: report.trim().isNotEmpty,
    );
  }
}

/// Persistence + retrieval for council artifacts.
///
/// Two stores:
///  - **Sessions** (state snapshots) live under
///    `<applicationSupport>/chat_sessions/councils/<id>.json` (unchanged).
///  - **Reports** (the artifact users keep) live under
///    `<applicationDocuments>/Lumen/CouncilReports/`. Each run produces a
///    `<utc-iso-ms>-<slug>-<rand4>.md` plus a sibling `.json` sidecar.
///
/// Filename grammar resists same-second collisions (ms precision + 4-hex
/// suffix), empty slugs from non-ASCII titles (slug fallback), Windows
/// MAX_PATH (slug capped at 60 chars), and Windows reserved names. Writes
/// are atomic via `*.tmp` + `rename`, with a startup sweep that removes
/// stale tmp files left by a crash mid-run.
class CouncilPersistenceService {
  Directory? _sessionRoot;
  Directory? _reportRoot;
  bool _sweptStaleTmp = false;
  static final _rand = math.Random.secure();

  // ---------- Session snapshots (unchanged behaviour) ----------

  Future<Directory> _ensureSessionRoot() async {
    if (_sessionRoot != null) return _sessionRoot!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'chat_sessions', 'councils'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _sessionRoot = dir;
    return dir;
  }

  Future<void> saveSession(CouncilSession session) async {
    final root = await _ensureSessionRoot();
    final file = File(p.join(root.path, '${session.config.id}.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );
  }

  Future<CouncilSession?> loadSession(String id) async {
    final root = await _ensureSessionRoot();
    final file = File(p.join(root.path, '$id.json'));
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return CouncilSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  /// Lightweight summary for the sessions browser. Avoids deserializing
  /// the full event / transcript payload — just enough for the list tile.
  Future<List<CouncilSessionSummary>> listSessions() async {
    final root = await _ensureSessionRoot();
    final entries = <CouncilSessionSummary>[];
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      if (!entity.path.endsWith('.json')) continue;
      try {
        final raw = await entity.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        entries.add(CouncilSessionSummary.fromJson(json, entity.path));
      } catch (_) {
        // Single corrupt file must not blank the whole list.
      }
    }
    entries.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    return entries;
  }

  /// Delete a persisted session file. Returns `true` on success.
  Future<bool> deleteSession(String filePath) async {
    try {
      final f = File(filePath);
      if (await f.exists()) await f.delete();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------- Report library (browseable artifacts) ----------

  /// Where reports live on disk. Surfaced so the menu / viewer can show it.
  Future<Directory> reportsDirectory() async => _ensureReportRoot();

  Future<Directory> _ensureReportRoot() async {
    if (_reportRoot != null) return _reportRoot!;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory(p.join(docs.path, 'Lumen', 'CouncilReports'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _activateReportRoot(dir);
      return dir;
    } catch (_) {
      // Documents can be unavailable/locked on some setups (OneDrive/KFM,
      // enterprise policies). Fall back to app-support so reports still
      // persist and the reports menu remains useful.
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'Lumen', 'CouncilReports'));
      if (!await dir.exists()) await dir.create(recursive: true);
      _activateReportRoot(dir);
      return dir;
    }
  }

  void _activateReportRoot(Directory dir) {
    _reportRoot = dir;
    if (_sweptStaleTmp) return;
    _sweptStaleTmp = true;
    // Fire-and-forget; never let a sweep failure break a save.
    unawaited(_sweepStaleTmp(dir));
  }

  Future<void> _sweepStaleTmp(Directory dir) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        if (!entity.path.endsWith('.tmp')) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(cutoff)) {
            await entity.delete();
          }
        } catch (_) {
          // File-locked or vanished — skip.
        }
      }
    } catch (_) {
      // Directory listing error is non-fatal; reports still save.
    }
  }

  /// Persist a council run as a `.md` + `.json` pair. Returns the absolute
  /// markdown path. Safe to call concurrently.
  Future<String> writeReport({
    required CouncilSession session,
    required String markdown,
    String? workspacePath,
    String? summary,
  }) async {
    final now = DateTime.now().toUtc();
    final stamp = _stamp(now);
    final titleSrc = session.config.title.trim().isNotEmpty
        ? session.config.title
        : session.config.brief;
    final slug = _slug(titleSrc);
    final rand = _rand4();
    final base = '$stamp-$slug-$rand';
    final sidecarData = <String, dynamic>{
      'schema': 1,
      'runId': session.runId,
      'title': titleSrc,
      'brief': session.config.brief,
      'summary': summary ?? _deriveSummary(markdown),
      'savedAt': now.toIso8601String(),
      'startedAt': session.startedAt.toUtc().toIso8601String(),
      'roundIndex': session.roundIndex,
      'agentRoster': [
        for (final a in session.config.allAgents)
          {'id': a.id, 'name': a.name, 'role': a.role.name, 'model': a.model},
      ],
    };

    Future<String> writePair(Directory root) async {
      final mdPath = p.join(root.path, '$base.md');
      final jsonPath = p.join(root.path, '$base.json');
      final sidecar = <String, dynamic>{
        ...sidecarData,
        'markdownFile': p.basename(mdPath),
      };
      await _atomicWriteBytes(
        jsonPath,
        utf8.encode(const JsonEncoder.withIndent('  ').convert(sidecar)),
      );
      await _atomicWriteBytes(mdPath, utf8.encode(markdown));
      return mdPath;
    }

    try {
      final root = await _ensureReportRoot();
      final mdPath = await writePair(root);
      // Best-effort workspace mirror — preserves prior behavior.
      if (workspacePath != null && workspacePath.isNotEmpty) {
        try {
          final mirrorDir = Directory(p.join(workspacePath, '.lumen', 'council'));
          if (!await mirrorDir.exists()) {
            await mirrorDir.create(recursive: true);
          }
          await File(
            p.join(mirrorDir.path, '$base.md'),
          ).writeAsBytes(utf8.encode(markdown));
        } catch (_) {
          // Mirror is optional. Don't surface — canonical save succeeded.
        }
      }
      return mdPath;
    } catch (_) {
      // Canonical root failed. Fall back to workspace-local persistence so
      // the run still lands as an artifact.
      if (workspacePath == null || workspacePath.isEmpty) rethrow;
      final mirrorDir = Directory(p.join(workspacePath, '.lumen', 'council'));
      if (!await mirrorDir.exists()) {
        await mirrorDir.create(recursive: true);
      }
      final mdPath = await writePair(mirrorDir);
      _activateReportRoot(mirrorDir);
      return mdPath;
    }
  }

  /// Atomic-ish write: bytes → `*.tmp` → `rename`. Retries on Windows file
  /// locks (e.g. user has the file open in Word/VSCode and is forcing an
  /// overwrite, which shouldn't happen for fresh stamps but does for
  /// near-collisions).
  Future<void> _atomicWriteBytes(String finalPath, List<int> bytes) async {
    final tmp = File('$finalPath.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    var attempt = 0;
    while (true) {
      try {
        await tmp.rename(finalPath);
        return;
      } on FileSystemException catch (_) {
        attempt++;
        if (attempt >= 3) {
          // Last-ditch fallback: copy + delete — works even when a strict
          // rename can't overwrite. If the destination is locked, append
          // a numeric suffix so we never silently drop the report.
          try {
            await tmp.copy(finalPath);
            await tmp.delete();
            return;
          } catch (_) {
            final alt = _withSuffix(finalPath, '.${_rand4()}');
            await tmp.copy(alt);
            try {
              await tmp.delete();
            } catch (_) {}
            return;
          }
        }
        await Future<void>.delayed(Duration(milliseconds: 100 * attempt));
      }
    }
  }

  /// Browseable list, newest first. Tolerates corrupt sidecars.
  Future<List<CouncilReportEntry>> listReports() async {
    final root = await _ensureReportRoot();
    final entries = <CouncilReportEntry>[];
    await for (final entity in root.list()) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.md')) continue;
      if (path.endsWith('.md.tmp')) continue;
      try {
        entries.add(await _parseEntry(entity));
      } catch (_) {
        // Single bad file can't take the whole list down.
      }
    }
    entries.sort((a, b) => b.savedAt.compareTo(a.savedAt));
    return entries;
  }

  Future<CouncilReportEntry> _parseEntry(File md) async {
    final stat = await md.stat();
    final base = p.basenameWithoutExtension(md.path);
    final sidecar = File(p.join(p.dirname(md.path), '$base.json'));
    var sidecarOk = false;
    String title = base;
    String summary = '';
    List<String> roster = const [];
    String runId = '';
    DateTime savedAt = stat.modified;
    if (await sidecar.exists()) {
      try {
        final raw = await sidecar.readAsString();
        final json = jsonDecode(raw) as Map<String, dynamic>;
        title = (json['title'] as String?)?.trim().isNotEmpty == true
            ? (json['title'] as String).trim()
            : base;
        summary = (json['summary'] as String?)?.trim() ?? '';
        runId = (json['runId'] as String?) ?? '';
        savedAt =
            DateTime.tryParse((json['savedAt'] as String?) ?? '')?.toLocal() ??
                stat.modified;
        final r = json['agentRoster'];
        if (r is List) {
          roster = [
            for (final a in r)
              if (a is Map && a['name'] is String) a['name'] as String,
          ];
        }
        sidecarOk = true;
      } catch (_) {
        // fall through to filename-derived metadata
      }
    }
    if (summary.isEmpty) {
      summary = await _firstHeadingOrLine(md);
    }
    return CouncilReportEntry(
      markdownPath: md.path,
      sidecarPath: sidecarOk ? sidecar.path : null,
      title: title,
      summary: summary,
      agentRoster: roster,
      savedAt: savedAt,
      runId: runId,
      sizeBytes: stat.size,
      sidecarOk: sidecarOk,
    );
  }

  Future<String> _firstHeadingOrLine(File md) async {
    try {
      final raw = await md.readAsString();
      for (final line in raw.split('\n')) {
        final t = line.trim();
        if (t.isEmpty) continue;
        return t.replaceFirst(RegExp(r'^#+\s*'), '');
      }
    } catch (_) {}
    return '';
  }

  /// Read the markdown body. Returns empty string if the file is gone.
  Future<String> readMarkdown(String path) async {
    final f = File(path);
    if (!await f.exists()) return '';
    return f.readAsString();
  }

  /// Delete a report (markdown + sidecar). Errors are swallowed and a
  /// boolean returned so the UI can show a non-fatal toast.
  Future<bool> deleteReport(CouncilReportEntry entry) async {
    var ok = true;
    try {
      final f = File(entry.markdownPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      ok = false;
    }
    final sidecar = entry.sidecarPath ??
        p.join(
          p.dirname(entry.markdownPath),
          '${p.basenameWithoutExtension(entry.markdownPath)}.json',
        );
    try {
      final f = File(sidecar);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Sidecar delete failure is non-fatal.
    }
    return ok;
  }

  /// Open the OS file manager with [path] selected.
  Future<void> revealInOs(String path) async {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', path]);
    } else {
      await Process.start('xdg-open', [p.dirname(path)]);
    }
  }

  // ---------- Filename helpers ----------

  static String _stamp(DateTime utc) {
    String two(int n) => n.toString().padLeft(2, '0');
    String three(int n) => n.toString().padLeft(3, '0');
    return '${utc.year}${two(utc.month)}${two(utc.day)}T'
        '${two(utc.hour)}${two(utc.minute)}${two(utc.second)}'
        '${three(utc.millisecond)}Z';
  }

  static String _rand4() {
    const hex = '0123456789abcdef';
    final buf = StringBuffer();
    for (var i = 0; i < 4; i++) {
      buf.write(hex[_rand.nextInt(16)]);
    }
    return buf.toString();
  }

  static const Set<String> _winReserved = {
    'con', 'prn', 'aux', 'nul',
    'com1', 'com2', 'com3', 'com4', 'com5',
    'com6', 'com7', 'com8', 'com9',
    'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5',
    'lpt6', 'lpt7', 'lpt8', 'lpt9',
  };

  static String _slug(String input) {
    final cleaned = input
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isEmpty || _winReserved.contains(cleaned)) return 'council';
    return cleaned.length <= 60 ? cleaned : cleaned.substring(0, 60);
  }

  static String _deriveSummary(String markdown) {
    // First non-empty, non-heading line — capped.
    for (final raw in markdown.split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith('#')) continue;
      if (line.startsWith('```')) continue;
      return line.length > 220 ? '${line.substring(0, 217)}…' : line;
    }
    // Fall back to the first heading.
    for (final raw in markdown.split('\n')) {
      final line = raw.trim();
      if (line.startsWith('#')) {
        final stripped = line.replaceFirst(RegExp(r'^#+\s*'), '');
        return stripped.length > 220
            ? '${stripped.substring(0, 217)}…'
            : stripped;
      }
    }
    return '';
  }

  static String _withSuffix(String path, String suffix) {
    final ext = p.extension(path);
    final base = p.basenameWithoutExtension(path);
    final dir = p.dirname(path);
    return p.join(dir, '$base$suffix$ext');
  }
}
