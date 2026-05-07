import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// One contiguous diff hunk inside [filePath]. Represents an
/// agent-applied edit that the user has not yet accepted or revoked.
///
/// Stored line ranges are 1-based inclusive against the *current*
/// (post-edit) file content — so [newLineStart..newLineEnd] is the
/// region the editor overlay paints. [originalText] is the bytes
/// that were there *before* the edit, kept so revoke can restore.
///
/// Hunks survive editor tab close + reopen via JSON persistence at
/// `<workspace>/.lumen/pending_hunks.json` — the editor reads its
/// hunks for [filePath] every time it mounts.
class PendingHunk {
  final String id;
  final String filePath;

  /// 1-based inclusive line range in the *post-edit* file.
  final int newLineStart;
  final int newLineEnd;

  /// 1-based inclusive line range in the *pre-edit* file. Used by
  /// [PendingHunksService.revoke] to splice the original lines back
  /// in. May equal new range for pure modifications.
  final int oldLineStart;
  final int oldLineEnd;

  /// Verbatim pre-edit text that occupied [oldLineStart..oldLineEnd].
  /// Used by revoke to restore content. Does NOT include the trailing
  /// newline of the last line — splicing logic adds it back.
  final String originalText;

  /// Verbatim post-edit text that now occupies
  /// [newLineStart..newLineEnd]. Used to verify the hunk is still
  /// applicable when the user later accepts/revokes.
  final String newText;

  /// added | removed | modified — drives the highlight tint.
  final HunkKind kind;

  /// Display label surfaced in the chat bubble ("edited foo.dart, 3 hunks").
  final DateTime appliedAt;

  /// Optional id of the chat message that produced this hunk; lets
  /// the chat bubble link back to "the X edits this turn made".
  final String? sourceMessageId;

  const PendingHunk({
    required this.id,
    required this.filePath,
    required this.newLineStart,
    required this.newLineEnd,
    required this.oldLineStart,
    required this.oldLineEnd,
    required this.originalText,
    required this.newText,
    required this.kind,
    required this.appliedAt,
    this.sourceMessageId,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'file': filePath,
    'nls': newLineStart,
    'nle': newLineEnd,
    'ols': oldLineStart,
    'ole': oldLineEnd,
    'orig': originalText,
    'new': newText,
    'kind': kind.name,
    'at': appliedAt.toIso8601String(),
    if (sourceMessageId != null) 'src': sourceMessageId,
  };

  factory PendingHunk.fromJson(Map<String, dynamic> j) => PendingHunk(
    id: j['id'] as String,
    filePath: j['file'] as String,
    newLineStart: (j['nls'] as num).toInt(),
    newLineEnd: (j['nle'] as num).toInt(),
    oldLineStart: (j['ols'] as num).toInt(),
    oldLineEnd: (j['ole'] as num).toInt(),
    originalText: (j['orig'] ?? '') as String,
    newText: (j['new'] ?? '') as String,
    kind: HunkKind.values.firstWhere(
      (k) => k.name == j['kind'],
      orElse: () => HunkKind.modified,
    ),
    appliedAt: DateTime.tryParse(j['at'] as String? ?? '') ?? DateTime.now(),
    sourceMessageId: j['src'] as String?,
  );
}

enum HunkKind { added, removed, modified }

/// Single source of truth for "which hunks are pending in this
/// workspace". UI overlays subscribe via [ChangeNotifier]; the tool
/// executor records hunks via [recordHunks] right after applying an
/// edit; the editor's gutter buttons call [accept] / [revoke].
///
/// Persistence: JSON file at `<workspace>/.lumen/pending_hunks.json`,
/// rewritten on every mutation. Survives app restart and editor-tab
/// close/reopen.
class PendingHunksService extends ChangeNotifier {
  PendingHunksService();

  String? _workspacePath;
  final List<PendingHunk> _hunks = <PendingHunk>[];
  Timer? _flushTimer;

  Future<void> bindWorkspace(String? workspacePath) async {
    if (_workspacePath == workspacePath) return;
    _workspacePath = workspacePath;
    _hunks.clear();
    if (workspacePath != null) {
      await _load();
    }
    notifyListeners();
  }

  /// All hunks for [filePath] (absolute), sorted top-to-bottom by
  /// [PendingHunk.newLineStart]. The editor overlay walks this list
  /// to paint highlights and the gutter actions.
  List<PendingHunk> hunksFor(String filePath) {
    final norm = p.normalize(filePath);
    return _hunks
        .where((h) => p.equals(p.normalize(h.filePath), norm))
        .toList()
      ..sort((a, b) => a.newLineStart.compareTo(b.newLineStart));
  }

  /// Total count of pending files (used by chat-bubble summary).
  int get pendingFileCount =>
      _hunks.map((h) => p.normalize(h.filePath)).toSet().length;

  int get pendingHunkCount => _hunks.length;

  /// Record a batch of hunks from an agent-applied edit. Called
  /// from `tool_executor.dart` after `Edit`/`Write`/`Patch` tools
  /// successfully write the new bytes to disk.
  ///
  /// TODO(council/chat-forge): wire `tool_executor.applyEdit` to
  /// call this with a pre-image diff. The hook lives in
  /// `_dispatch` — easiest is to capture original bytes before
  /// write, run a line-level diff after, then push hunks here.
  /// Paths the diff-decoration system must NEVER decorate. Synthetic
  /// editor tabs (knowledge base, settings) live as fake `File`
  /// instances backed by sentinel paths — agent edits to those panes
  /// are not real disk writes and must not produce accept/revoke UI.
  static const Set<String> _ignoredPaths = <String>{
    '__knowledge_base__',
    '__settings__',
  };

  Future<void> recordHunks(List<PendingHunk> hunks) async {
    if (hunks.isEmpty) return;
    final filtered = hunks
        .where((h) => !_ignoredPaths.contains(h.filePath))
        .toList(growable: false);
    if (filtered.isEmpty) return;
    _hunks.addAll(filtered);
    notifyListeners();
    _scheduleFlush();
  }

  /// Accept a single hunk: drop it from the pending list. Disk
  /// already holds the new content (the tool executor wrote it),
  /// so accept is purely "stop highlighting".
  Future<void> accept(String hunkId) async {
    final idx = _hunks.indexWhere((h) => h.id == hunkId);
    if (idx < 0) return;
    _hunks.removeAt(idx);
    notifyListeners();
    _scheduleFlush();
  }

  /// Revoke a single hunk: splice [PendingHunk.originalText] back
  /// over [newLineStart..newLineEnd] on disk and drop the hunk.
  ///
  /// Best-effort: if the file has been modified out from under us
  /// such that [PendingHunk.newText] is no longer present at the
  /// recorded range, we abort the revoke and leave the hunk in
  /// place (a future run can offer a manual diff view).
  Future<bool> revoke(String hunkId) async {
    final idx = _hunks.indexWhere((h) => h.id == hunkId);
    if (idx < 0) return false;
    final h = _hunks[idx];
    final f = File(h.filePath);
    if (!await f.exists()) {
      _hunks.removeAt(idx);
      notifyListeners();
      _scheduleFlush();
      return false;
    }
    final raw = await f.readAsString();
    final lineEnding = raw.contains('\r\n') ? '\r\n' : '\n';
    final lines = raw.split(RegExp(r'\r?\n'));
    final ls = h.newLineStart - 1;
    final le = h.newLineEnd; // exclusive in 0-based slice
    if (ls < 0 || le > lines.length || ls > le) return false;
    // Verify newText still lives there (fuzzy: trim-equal so trailing
    // whitespace tweaks don't block revoke).
    final actual = lines.sublist(ls, le).join(lineEnding);
    if (actual.trim() != h.newText.trim()) {
      // Drift detected — file changed since the hunk was recorded.
      // Don't blindly overwrite, but drop the hunk so the user
      // isn't stuck staring at a stale band forever.
      _hunks.removeAt(idx);
      notifyListeners();
      _scheduleFlush();
      return false;
    }
    final restored = [
      ...lines.sublist(0, ls),
      ...h.originalText.split(RegExp(r'\r?\n')),
      ...lines.sublist(le),
    ].join(lineEnding);
    await f.writeAsString(restored);
    _hunks.removeAt(idx);
    notifyListeners();
    _scheduleFlush();
    return true;
  }

  /// Accept all pending hunks for [filePath] (used by the editor's
  /// "accept all" gutter button — not yet wired into UI; available
  /// for future surface).
  Future<void> acceptAllForFile(String filePath) async {
    final norm = p.normalize(filePath);
    final before = _hunks.length;
    _hunks.removeWhere(
      (h) => p.equals(p.normalize(h.filePath), norm),
    );
    if (_hunks.length != before) {
      notifyListeners();
      _scheduleFlush();
    }
  }

  // --- persistence -------------------------------------------------------

  String? get _storePath {
    final ws = _workspacePath;
    if (ws == null) return null;
    return p.join(ws, '.lumen', 'pending_hunks.json');
  }

  Future<void> _load() async {
    final sp = _storePath;
    if (sp == null) return;
    final f = File(sp);
    if (!await f.exists()) return;
    try {
      final raw = await f.readAsString();
      final list = (jsonDecode(raw) as List).cast<dynamic>();
      _hunks
        ..clear()
        ..addAll(list.map((e) => PendingHunk.fromJson(Map<String, dynamic>.from(e as Map))));
    } catch (_) {
      // Corrupt store — start fresh rather than crash.
      _hunks.clear();
    }
  }

  void _scheduleFlush() {
    _flushTimer?.cancel();
    _flushTimer = Timer(const Duration(milliseconds: 250), _flush);
  }

  Future<void> _flush() async {
    final sp = _storePath;
    if (sp == null) return;
    final dir = Directory(p.dirname(sp));
    if (!await dir.exists()) await dir.create(recursive: true);
    final tmp = File('$sp.tmp');
    await tmp.writeAsString(jsonEncode(_hunks.map((h) => h.toJson()).toList()));
    await tmp.rename(sp);
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }
}
