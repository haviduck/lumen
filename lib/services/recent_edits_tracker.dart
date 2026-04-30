import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'preferences_service.dart';
import 'timeline_models.dart';
import 'timeline_service.dart';

/// "Recent agent edits" tracker — feeds the per-line cyan tint the editor
/// paints to show what the most recent agent turn changed.
///
/// **Why "last turn" and not "all-time agent edits":** when a user is
/// vibecoding, every line in a file might be agent-written. A persistent
/// "AI authored this" badge would tint the entire file forever and the
/// signal would degenerate into noise. This tracker holds a transient
/// snapshot of *only the most recent agent turn* for each file the turn
/// touched. Highlights auto-clear when:
///   - the user types in that file (we hook `_pushControllerTextToState`
///     which only runs on user-driven changes — programmatic writes
///     during file load match `state.content` and short-circuit, so
///     reloading an agent-written file does NOT clear the highlights);
///   - the user saves that file;
///   - the next agent turn starts (we wipe everything before re-populating).
///
/// **Coordinate system:** keys are absolute filesystem paths so they
/// match what `AppState.activeFile.path` yields directly. Values are
/// 0-based line indices in the *post-edit* version of the file (matches
/// `re_editor`'s `CodeLineEditingController.codeLines` indexing).
///
/// **Diff algorithm:** prefix + suffix trim. Walks both versions from
/// the start until lines diverge, then from the end. Everything in
/// between in the post-edit version is flagged. Cheap — O(N) — and
/// optimal for contiguous edits, which dominate agent edit patterns
/// (SEARCH/REPLACE blocks, MULTI_EDIT batches, append-only writes). For
/// the rare non-contiguous edit, this over-marks the bracketing range
/// as one block. Failure mode is "more lines highlighted than strictly
/// changed", never "wrong lines highlighted" — graceful.
class RecentEditsTracker extends ChangeNotifier {
  RecentEditsTracker(this._prefs);

  final PreferencesService _prefs;

  bool _enabled = true;
  String? _workspacePath;

  /// Map of absolute path → 0-based line indices in the post-edit
  /// version. Populated by [noteTurnComplete], pruned by [invalidate].
  final Map<String, Set<int>> _byFile = <String, Set<int>>{};

  bool get enabled => _enabled;

  /// Load the persisted toggle state. Default is ON — option 1 from the
  /// design conversation: "Last turn" highlights live by default and the
  /// user can toggle them off in the status bar.
  Future<void> init() async {
    _enabled = await _prefs.getRecentEditsHighlight();
  }

  /// Bind to a workspace. Wipes per-workspace state on every change so
  /// highlights from project A don't leak into project B.
  void bindWorkspace(String? path) {
    if (_workspacePath == path) return;
    _workspacePath = path;
    if (_byFile.isNotEmpty) {
      _byFile.clear();
      notifyListeners();
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_enabled == value) return;
    _enabled = value;
    await _prefs.setRecentEditsHighlight(value);
    // Wipe in-memory state on disable — disabling shouldn't leave the
    // last turn cached for the moment the user re-enables. They want
    // to see *the next* turn after re-enabling, not yesterday's stale
    // one.
    if (!value && _byFile.isNotEmpty) {
      _byFile.clear();
    }
    notifyListeners();
  }

  /// Returns the 0-based line indices for [absolutePath] that the most
  /// recent agent turn touched, or `null` when nothing's tracked / the
  /// feature is disabled. The editor overlay reads this on every paint.
  Set<int>? linesFor(String absolutePath) {
    if (!_enabled) return null;
    return _byFile[absolutePath];
  }

  /// True when [absolutePath] has any tracked lines. Cheaper than
  /// [linesFor] for use in widgets that just want to know whether to
  /// mount the overlay.
  bool hasLinesFor(String absolutePath) {
    if (!_enabled) return false;
    final s = _byFile[absolutePath];
    return s != null && s.isNotEmpty;
  }

  /// Drop tracked lines for [absolutePath]. Called when the user types
  /// in the file (line numbers have shifted, the cached set is stale)
  /// or saves it.
  void invalidate(String absolutePath) {
    if (_byFile.remove(absolutePath) != null) {
      notifyListeners();
    }
  }

  /// Wipe everything. Called at the start of each agent turn so the
  /// previous turn's highlights don't bleed into the new one.
  void clear() {
    if (_byFile.isEmpty) return;
    _byFile.clear();
    notifyListeners();
  }

  /// Walk the timeline for entries tagged with [turnId], diff each
  /// entry's `prevHash` blob against its `newHash` blob, and store the
  /// resulting line indices keyed by absolute path. Skips delete
  /// entries (no lines to highlight on a deletion). Skips when the
  /// feature is disabled — saves the timeline IO cost for users who've
  /// turned the highlight off.
  Future<void> noteTurnComplete(String turnId, TimelineService timeline) async {
    // Diagnostic logging — kept under `assert` so it strips in
    // release builds. Cheap, lets us spot which gate closes the
    // door when a turn finishes and no highlights appear.
    assert(() {
      debugPrint(
        '[RecentEditsTracker] noteTurnComplete: enabled=$_enabled '
        'workspace=$_workspacePath turnId=$turnId',
      );
      return true;
    }());
    if (!_enabled) return;
    if (_workspacePath == null) return;
    final ws = _workspacePath!;

    // Wipe previous turn's lines first — this is a fresh capture.
    _byFile.clear();

    final agentEntries = timeline.entries.where(
      (e) =>
          e.turnId == turnId &&
          e.origin == TimelineOrigin.agentTool &&
          e.op != TimelineOp.delete &&
          e.newKind == TimelineKind.text,
    );

    assert(() {
      final all = timeline.entries.length;
      final matched = agentEntries.length;
      debugPrint(
        '[RecentEditsTracker] entries: total=$all '
        'matched-this-turn=$matched',
      );
      return true;
    }());

    for (final entry in agentEntries) {
      final lines = await _diffLines(timeline, entry);
      if (lines.isEmpty) continue;
      final abs = p.join(ws, entry.relPath.replaceAll('/', p.separator));
      _byFile.putIfAbsent(abs, () => <int>{}).addAll(lines);
      assert(() {
        debugPrint(
          '[RecentEditsTracker]   ${entry.relPath} → '
          '${lines.length} line(s) at $abs',
        );
        return true;
      }());
    }
    notifyListeners();
  }

  Future<List<int>> _diffLines(
    TimelineService timeline,
    TimelineEntry entry,
  ) async {
    final newBytes = await timeline.readBlob(entry.newHash);
    if (newBytes == null) return const [];
    final newText = utf8.decode(newBytes, allowMalformed: true);
    final newLines = _editorCodeLines(newText);
    if (newLines.isEmpty) return const [];

    // Create / no previous version → every line is "new".
    if (entry.prevHash.isEmpty) {
      return List<int>.generate(newLines.length, (i) => i);
    }

    final prevBytes = await timeline.readBlob(entry.prevHash);
    if (prevBytes == null) {
      // Pruned blob — fall back to "all lines new" so the user still
      // sees something. Worse failure mode than "exact diff" but
      // strictly informative.
      return List<int>.generate(newLines.length, (i) => i);
    }
    final prevText = utf8.decode(prevBytes, allowMalformed: true);
    final prevLines = _editorCodeLines(prevText);

    int head = 0;
    final headMax = math.min(prevLines.length, newLines.length);
    while (head < headMax && prevLines[head] == newLines[head]) {
      head++;
    }

    int tail = 0;
    while (tail < prevLines.length - head &&
        tail < newLines.length - head &&
        prevLines[prevLines.length - 1 - tail] ==
            newLines[newLines.length - 1 - tail]) {
      tail++;
    }

    final start = head;
    final end = newLines.length - tail; // exclusive
    if (end <= start) return const [];
    return List<int>.generate(end - start, (i) => start + i);
  }

  /// Mirrors `re_editor`'s `String.codeLines` extension exactly enough
  /// for line-index parity: normalize CRLF/CR to LF, then preserve the
  /// trailing empty line that `String.split('\n')` keeps.
  List<String> _editorCodeLines(String text) {
    if (text.isEmpty) return const [''];
    return text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  }
}
