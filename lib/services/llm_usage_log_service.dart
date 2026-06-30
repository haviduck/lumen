/// Per-prompt LLM usage log + aggregation queries.
///
/// Drives the "View token usage" tab. Every Lumen agent-loop iteration
/// that produces a model response logs ONE [LlmUsageEntry] here with
/// the routed provider, model id, the four token buckets, and the
/// originating session id + title (so a future "open this chat"
/// affordance has a stable hook).
///
/// Storage is an append-only NDJSON file under app-support
/// (`llm_usage.ndjson`). NDJSON because:
///   - append-only writes are O(1); we don't read-modify-write the
///     entire history every turn,
///   - line-orientation makes recovery from a half-written tail
///     trivial (the parser just drops the malformed line),
///   - load-time scans are simple `transform(LineSplitter())` which
///     never needs the whole file in RAM at once (relevant only at
///     ~tens of MB; the rotation threshold below keeps us well under
///     that in practice).
///
/// Rotation: at 5 MB the file is renamed to
/// `llm_usage.ndjson.<timestamp>.bak` and a fresh log starts. The
/// aggregator transparently reads the bak files too so charts /
/// totals never lose history. The user can hand-delete bak files for
/// a manual purge — the rotation isn't size-bounded.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'token_usage.dart';

class LlmUsageEntry {
  /// Wall-clock time the prompt completed (UTC on the wire,
  /// converted to local for display by the UI).
  final DateTime timestamp;

  /// Provider id matching `ChatController._splitModel`'s first slot:
  /// `claude`, `copilot`, `gemini`, `ollama`, `ollama-cloud`.
  final String provider;

  /// Provider-stripped model id (e.g. `claude-sonnet-4-6`, `gpt-5`,
  /// `glm-5.1`). Null only for the (rare) provider report that
  /// arrives with no model identifier — we keep the entry so the
  /// prompt-count stays accurate, surface as "(unknown)" in the UI.
  final String? model;

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  /// Originating chat session — useful for future "open the chat
  /// this came from" jumps. The id is the same one used by
  /// `ChatPersistenceService`. Null on tool-call follow-up turns
  /// where the controller couldn't capture a session reference.
  final String? sessionId;

  /// Pretty session title at log time. Persisted alongside the id so
  /// the aggregator can still show a label even if the underlying
  /// session has since been deleted from disk.
  final String? sessionTitle;

  /// Workspace directory path at log time. Used for per-project
  /// filtering in the usage dashboard. Stored as the full path;
  /// the UI extracts the basename for display.
  final String? workspace;

  const LlmUsageEntry({
    required this.timestamp,
    required this.provider,
    required this.model,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.sessionId,
    this.sessionTitle,
    this.workspace,
  });

  /// Total chargeable tokens — input + output + cache-write +
  /// reasoning. Same formula as the in-chat token chip's headline.
  /// Cache reads are excluded because they bill at a fraction (kept
  /// visible in the breakdown).
  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;

  Map<String, dynamic> toJson() => {
    't': timestamp.toUtc().toIso8601String(),
    'p': provider,
    if (model != null) 'm': model,
    if (inputTokens != 0) 'in': inputTokens,
    if (outputTokens != 0) 'out': outputTokens,
    if (cacheReadTokens != 0) 'cr': cacheReadTokens,
    if (cacheWriteTokens != 0) 'cw': cacheWriteTokens,
    if (reasoningTokens != 0) 'rsn': reasoningTokens,
    if (sessionId != null) 'sid': sessionId,
    if (sessionTitle != null) 'st': sessionTitle,
    if (workspace != null) 'ws': workspace,
  };

  static LlmUsageEntry? tryFromJson(Map<String, dynamic> j) {
    final tRaw = j['t'];
    if (tRaw is! String) return null;
    final ts = DateTime.tryParse(tRaw);
    if (ts == null) return null;
    int asInt(Object? v) => v is num ? v.toInt() : 0;
    return LlmUsageEntry(
      timestamp: ts.toLocal(),
      provider: (j['p'] as String?) ?? 'unknown',
      model: j['m'] as String?,
      inputTokens: asInt(j['in']),
      outputTokens: asInt(j['out']),
      cacheReadTokens: asInt(j['cr']),
      cacheWriteTokens: asInt(j['cw']),
      reasoningTokens: asInt(j['rsn']),
      sessionId: j['sid'] as String?,
      sessionTitle: j['st'] as String?,
      workspace: j['ws'] as String?,
    );
  }
}

/// Aggregated counters for one filter slice (a date range, optionally
/// scoped to a model + provider). Plain value object; the UI reads
/// these fields directly.
class LlmUsageAggregate {
  final int promptCount;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  /// Per-day buckets keyed by `YYYY-MM-DD` (local time). Sorted
  /// ascending. Empty days in the requested range are PRESENT with
  /// zeroed totals so the chart can render a continuous timeline
  /// without the UI having to fill gaps itself.
  final List<LlmUsageDayBucket> dailyBuckets;

  /// Per-model breakdown sorted by `billedTotal` descending.
  final List<LlmUsageModelRow> byModel;

  /// Per-provider breakdown sorted by `billedTotal` descending.
  final List<LlmUsageProviderRow> byProvider;

  const LlmUsageAggregate({
    required this.promptCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.reasoningTokens,
    required this.dailyBuckets,
    required this.byModel,
    required this.byProvider,
  });

  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;

  static const LlmUsageAggregate empty = LlmUsageAggregate(
    promptCount: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadTokens: 0,
    cacheWriteTokens: 0,
    reasoningTokens: 0,
    dailyBuckets: [],
    byModel: [],
    byProvider: [],
  );
}

class LlmUsageDayBucket {
  /// Local-time day key, `YYYY-MM-DD`.
  final String day;
  final int promptCount;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  const LlmUsageDayBucket({
    required this.day,
    this.promptCount = 0,
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;
}

class LlmUsageModelRow {
  final String provider;
  final String model;
  final int promptCount;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  const LlmUsageModelRow({
    required this.provider,
    required this.model,
    required this.promptCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.reasoningTokens,
  });

  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;
}

class LlmUsageProviderRow {
  final String provider;
  final int promptCount;
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  const LlmUsageProviderRow({
    required this.provider,
    required this.promptCount,
    required this.inputTokens,
    required this.outputTokens,
    required this.cacheReadTokens,
    required this.cacheWriteTokens,
    required this.reasoningTokens,
  });

  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;
}

/// Filter input for [LlmUsageLogService.aggregate]. `null` fields are
/// open ("any"); non-null fields restrict to matching entries.
class LlmUsageFilter {
  /// Inclusive lower bound. `null` = unbounded.
  final DateTime? since;

  /// Inclusive upper bound. `null` = unbounded.
  final DateTime? until;

  /// Restrict to this provider only. `null` = any.
  final String? provider;

  /// Restrict to this model only. `null` = any.
  final String? model;

  /// Restrict to this workspace path only. `null` = any (global).
  /// Set to [LlmUsageLogService.untaggedWorkspace] to match entries
  /// logged before per-project tagging was added.
  final String? workspace;

  const LlmUsageFilter({
    this.since,
    this.until,
    this.provider,
    this.model,
    this.workspace,
  });

  bool matches(LlmUsageEntry e) {
    if (since != null && e.timestamp.isBefore(since!)) return false;
    if (until != null && e.timestamp.isAfter(until!)) return false;
    if (provider != null && e.provider != provider) return false;
    if (model != null && e.model != model) return false;
    if (workspace != null) {
      if (workspace == LlmUsageLogService.untaggedWorkspace) {
        if (e.workspace != null) return false;
      } else {
        if (e.workspace != workspace) return false;
      }
    }
    return true;
  }
}

/// Singleton-ish service: one instance per process, owned by
/// `AppState`. Exposes a [ChangeNotifier]-style listener so the
/// "View token usage" tab can rebuild on every log without polling.
class LlmUsageLogService extends ChangeNotifier {
  static const String _logFileName = 'llm_usage.ndjson';
  static const int _rotateThresholdBytes = 5 * 1024 * 1024;

  /// Sentinel value used in the workspace dropdown for entries logged
  /// before per-project tagging was added (v1.0.22). The filter
  /// translates this to "match entries where workspace is null".
  static const String untaggedWorkspace = '__untagged__';

  Future<Directory> _resolveDir() async {
    final support = await getApplicationSupportDirectory();
    return support;
  }

  Future<File> _resolveActiveFile() async {
    final dir = await _resolveDir();
    return File(p.join(dir.path, _logFileName));
  }

  /// In-memory write queue. NDJSON appends are fast but each one is
  /// still a syscall; coalescing means a tool-loop iteration that
  /// produces ~5 usage events back-to-back hits the disk once.
  /// Flushed by a 300 ms debounce timer OR explicitly by [flush].
  final List<LlmUsageEntry> _pending = <LlmUsageEntry>[];
  Timer? _flushTimer;
  bool _flushing = false;

  /// Record a single prompt's usage. Cheap & sync from the caller's
  /// POV — the actual disk write happens on a debounced background
  /// timer. Listeners are notified immediately so the usage tab
  /// re-aggregates without waiting for the flush.
  void log(LlmUsageEntry entry) {
    if (entry.inputTokens == 0 &&
        entry.outputTokens == 0 &&
        entry.cacheReadTokens == 0 &&
        entry.cacheWriteTokens == 0 &&
        entry.reasoningTokens == 0) {
      return;
    }
    _pending.add(entry);
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(flush());
    });
    notifyListeners();
  }

  /// Force-write any buffered entries to disk. Called by
  /// `AppCloseGuard` on the close path so a partial-shutdown doesn't
  /// drop a turn's worth of accounting.
  Future<void> flush() async {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    final batch = List<LlmUsageEntry>.from(_pending);
    _pending.clear();
    try {
      final file = await _resolveActiveFile();
      await file.parent.create(recursive: true);
      final sink = file.openWrite(mode: FileMode.append);
      for (final e in batch) {
        sink.writeln(jsonEncode(e.toJson()));
      }
      await sink.flush();
      await sink.close();
      // Rotate after each flush so the next session starts fresh
      // once we've crossed the threshold. Cheap stat — runs on the
      // existing flush path, not from the hot logging code path.
      await _maybeRotate(file);
    } catch (e, st) {
      debugPrint('[LlmUsageLog] flush failed: $e\n$st');
      // Re-insert at the head so the next flush retries (best-
      // effort; if disk is dying we don't want unbounded growth
      // either — cap at the rotate threshold).
      if (_pending.length < 5000) {
        _pending.insertAll(0, batch);
      }
    } finally {
      _flushing = false;
    }
  }

  Future<void> _maybeRotate(File active) async {
    try {
      final stat = await active.stat();
      if (stat.size < _rotateThresholdBytes) return;
      final ts = DateTime.now().toUtc().toIso8601String().replaceAll(
        RegExp(r'[:.]'),
        '-',
      );
      final rotatedPath = '${active.path}.$ts.bak';
      await active.rename(rotatedPath);
      // Touch a fresh active so the next append doesn't have to
      // create the file mid-stream.
      await active.create();
    } catch (e) {
      debugPrint('[LlmUsageLog] rotate failed: $e');
    }
  }

  Future<List<File>> _resolveAllFiles() async {
    final dir = await _resolveDir();
    if (!await dir.exists()) return const [];
    final out = <File>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (name == _logFileName || name.startsWith('$_logFileName.')) {
        out.add(entity);
      }
    }
    return out;
  }

  /// Load every entry currently on disk. Lightweight — NDJSON
  /// parsed line-by-line, malformed lines skipped silently.
  Future<List<LlmUsageEntry>> loadAll() async {
    // Ensure pending entries are reflected in subsequent reads.
    await flush();
    final files = await _resolveAllFiles();
    final entries = <LlmUsageEntry>[];
    for (final f in files) {
      try {
        final raw = await f.readAsString();
        for (final line in const LineSplitter().convert(raw)) {
          if (line.isEmpty) continue;
          try {
            final j = jsonDecode(line) as Map<String, dynamic>;
            final e = LlmUsageEntry.tryFromJson(j);
            if (e != null) entries.add(e);
          } catch (_) {
            // Skip malformed line — a half-written tail or a
            // future-version line with an unparseable type.
          }
        }
      } catch (e) {
        debugPrint('[LlmUsageLog] read failed for ${f.path}: $e');
      }
    }
    entries.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    return entries;
  }

  /// Aggregate entries matching [filter] into a single
  /// [LlmUsageAggregate]. The [filter.since] / [filter.until] window
  /// also drives [LlmUsageAggregate.dailyBuckets] — empty days inside
  /// the window are filled with zero rows so the chart can render a
  /// continuous timeline.
  Future<LlmUsageAggregate> aggregate(LlmUsageFilter filter) async {
    final all = await loadAll();
    final matched = all.where(filter.matches).toList();

    int prompts = 0, inT = 0, outT = 0, crT = 0, cwT = 0, rsnT = 0;
    final perModel = <String, _RowAcc>{};
    final perProvider = <String, _RowAcc>{};
    final perDay = <String, _RowAcc>{};

    for (final e in matched) {
      prompts++;
      inT += e.inputTokens;
      outT += e.outputTokens;
      crT += e.cacheReadTokens;
      cwT += e.cacheWriteTokens;
      rsnT += e.reasoningTokens;

      final modelKey = '${e.provider}::${e.model ?? '(unknown)'}';
      (perModel[modelKey] ??= _RowAcc()).add(e);
      (perProvider[e.provider] ??= _RowAcc()).add(e);
      final dayKey = _dayKey(e.timestamp);
      (perDay[dayKey] ??= _RowAcc()).add(e);
    }

    // Daily buckets — fill empty days inside the requested window.
    final since = filter.since;
    final until = filter.until;
    final orderedDays = <LlmUsageDayBucket>[];
    if (since != null && until != null) {
      DateTime cursor = DateTime(since.year, since.month, since.day);
      final lastDay = DateTime(until.year, until.month, until.day);
      while (!cursor.isAfter(lastDay)) {
        final key = _dayKey(cursor);
        final acc = perDay[key];
        orderedDays.add(
          LlmUsageDayBucket(
            day: key,
            promptCount: acc?.prompts ?? 0,
            inputTokens: acc?.input ?? 0,
            outputTokens: acc?.output ?? 0,
            cacheReadTokens: acc?.cacheRead ?? 0,
            cacheWriteTokens: acc?.cacheWrite ?? 0,
            reasoningTokens: acc?.reasoning ?? 0,
          ),
        );
        cursor = cursor.add(const Duration(days: 1));
      }
    } else {
      final keys = perDay.keys.toList()..sort();
      for (final k in keys) {
        final acc = perDay[k]!;
        orderedDays.add(
          LlmUsageDayBucket(
            day: k,
            promptCount: acc.prompts,
            inputTokens: acc.input,
            outputTokens: acc.output,
            cacheReadTokens: acc.cacheRead,
            cacheWriteTokens: acc.cacheWrite,
            reasoningTokens: acc.reasoning,
          ),
        );
      }
    }

    final modelRows = perModel.entries.map((e) {
      final parts = e.key.split('::');
      final provider = parts.first;
      final model = parts.length > 1 ? parts.sublist(1).join('::') : '';
      final acc = e.value;
      return LlmUsageModelRow(
        provider: provider,
        model: model,
        promptCount: acc.prompts,
        inputTokens: acc.input,
        outputTokens: acc.output,
        cacheReadTokens: acc.cacheRead,
        cacheWriteTokens: acc.cacheWrite,
        reasoningTokens: acc.reasoning,
      );
    }).toList();
    modelRows.sort((a, b) => b.billedTotal.compareTo(a.billedTotal));

    final providerRows = perProvider.entries.map((e) {
      final acc = e.value;
      return LlmUsageProviderRow(
        provider: e.key,
        promptCount: acc.prompts,
        inputTokens: acc.input,
        outputTokens: acc.output,
        cacheReadTokens: acc.cacheRead,
        cacheWriteTokens: acc.cacheWrite,
        reasoningTokens: acc.reasoning,
      );
    }).toList();
    providerRows.sort((a, b) => b.billedTotal.compareTo(a.billedTotal));

    return LlmUsageAggregate(
      promptCount: prompts,
      inputTokens: inT,
      outputTokens: outT,
      cacheReadTokens: crT,
      cacheWriteTokens: cwT,
      reasoningTokens: rsnT,
      dailyBuckets: orderedDays,
      byModel: modelRows,
      byProvider: providerRows,
    );
  }

  /// Convenience helper — distinct model / provider values seen in
  /// the log, for the filter dropdowns. Both lists are sorted by
  /// recency-of-last-use descending (newest first) so the user's
  /// current model floats to the top of the picker.
  Future<({List<String> models, List<String> providers, List<String> workspaces})>
  distinctFilters() async {
    final entries = await loadAll();
    final lastSeenModel = <String, DateTime>{};
    final lastSeenProvider = <String, DateTime>{};
    final lastSeenWorkspace = <String, DateTime>{};
    bool hasUntagged = false;
    for (final e in entries) {
      if (e.model != null) {
        final cur = lastSeenModel[e.model!];
        if (cur == null || e.timestamp.isAfter(cur)) {
          lastSeenModel[e.model!] = e.timestamp;
        }
      }
      final cur = lastSeenProvider[e.provider];
      if (cur == null || e.timestamp.isAfter(cur)) {
        lastSeenProvider[e.provider] = e.timestamp;
      }
      if (e.workspace != null) {
        final wsCur = lastSeenWorkspace[e.workspace!];
        if (wsCur == null || e.timestamp.isAfter(wsCur)) {
          lastSeenWorkspace[e.workspace!] = e.timestamp;
        }
      } else {
        hasUntagged = true;
      }
    }
    final models = lastSeenModel.keys.toList()
      ..sort((a, b) => lastSeenModel[b]!.compareTo(lastSeenModel[a]!));
    final providers = lastSeenProvider.keys.toList()
      ..sort((a, b) => lastSeenProvider[b]!.compareTo(lastSeenProvider[a]!));
    final workspaces = lastSeenWorkspace.keys.toList()
      ..sort((a, b) => lastSeenWorkspace[b]!.compareTo(lastSeenWorkspace[a]!));
    if (hasUntagged) {
      workspaces.add(untaggedWorkspace);
    }
    return (models: models, providers: providers, workspaces: workspaces);
  }

  /// Wipe the entire history — bak files included. Called from the
  /// "Reset log" button in the usage tab. Returns the number of
  /// files removed.
  Future<int> reset() async {
    _pending.clear();
    _flushTimer?.cancel();
    final files = await _resolveAllFiles();
    var removed = 0;
    for (final f in files) {
      try {
        await f.delete();
        removed++;
      } catch (e) {
        debugPrint('[LlmUsageLog] delete failed for ${f.path}: $e');
      }
    }
    notifyListeners();
    return removed;
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  static String _dayKey(DateTime t) {
    final l = t.toLocal();
    final y = l.year.toString().padLeft(4, '0');
    final m = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }
}

class _RowAcc {
  int prompts = 0;
  int input = 0;
  int output = 0;
  int cacheRead = 0;
  int cacheWrite = 0;
  int reasoning = 0;

  void add(LlmUsageEntry e) {
    prompts++;
    input += e.inputTokens;
    output += e.outputTokens;
    cacheRead += e.cacheReadTokens;
    cacheWrite += e.cacheWriteTokens;
    reasoning += e.reasoningTokens;
  }
}

/// Helper to translate a `TokenUsage` callback into a `LlmUsageEntry`
/// for the controller. Accumulates deltas across one Lumen-loop
/// iteration; the controller flushes via [build] when the iteration
/// finishes.
class IterationUsageAccumulator {
  int inputTokens = 0;
  int outputTokens = 0;
  int cacheReadTokens = 0;
  int cacheWriteTokens = 0;
  int reasoningTokens = 0;
  String? model;

  void add(TokenUsage u) {
    if (u.kind != TokenUsageKind.delta) return;
    if (u.inputTokens != null) inputTokens += u.inputTokens!;
    if (u.outputTokens != null) outputTokens += u.outputTokens!;
    if (u.cacheReadTokens != null) cacheReadTokens += u.cacheReadTokens!;
    if (u.cacheWriteTokens != null) cacheWriteTokens += u.cacheWriteTokens!;
    if (u.reasoningTokens != null) reasoningTokens += u.reasoningTokens!;
    model ??= u.model;
  }

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cacheReadTokens == 0 &&
      cacheWriteTokens == 0 &&
      reasoningTokens == 0;

  LlmUsageEntry? build({
    required String provider,
    required String? fallbackModel,
    required String? sessionId,
    required String? sessionTitle,
    String? workspace,
  }) {
    if (isEmpty) return null;
    return LlmUsageEntry(
      timestamp: DateTime.now(),
      provider: provider,
      model: model ?? fallbackModel,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadTokens: cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens,
      reasoningTokens: reasoningTokens,
      sessionId: sessionId,
      sessionTitle: sessionTitle,
      workspace: workspace,
    );
  }
}
