import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'timeline_models.dart';

/// Per-workspace foolproof file revision history.
///
/// **Goal**: never lose a meaningful version of a file. Captures every
/// plausible mutation source — agent tool ops, manual saves, external
/// FS writes, explorer actions — into a content-addressed blob store
/// plus an append-only journal. Restorable per-revision. Built ready
/// for the next-step "click a chat message → restore everything since"
/// feature: every agent-origin entry carries `(sessionId, turnId,
/// messageId)` correlation IDs so a future `restoreToMessage` flow
/// can group + revert in one go.
///
/// **Storage layout**
/// ```
/// <app-support>/lumen/timeline/<workspaceHash>/
///   meta.json              workspace metadata + schema version
///   journal.ndjson         append-only NDJSON of TimelineEntry rows
///   objects/<aa>/<full-hash>.gz   gzip'd content blobs (content-addressed)
/// ```
///
/// `<workspaceHash>` is `sha256(lower(path).replace('\\','/'))[..16]`,
/// matching the convention `PreferencesService` uses for chat tab
/// buckets so all per-workspace caches share a key shape.
///
/// **Capture flow (general)**
///   1. Caller invokes `recordWrite(absPath, origin: ..., tool: ...)`.
///   2. We hash the file. If hash equals the last journal entry's
///      `newHash` for the same `relPath`, we suppress (no-op write).
///   3. We resolve `prevHash` from the in-memory `_headByPath` map
///      (kept in sync with the journal on init).
///   4. We persist the blob if it isn't already on disk, then append
///      a single line to `journal.ndjson`.
///   5. We `notifyListeners()` so any mounted timeline UI redraws.
///
/// **Foolproofness**
///   - Hard ignore set drops events under `.git`, `node_modules`,
///     `build`, etc. (same set the rest of the IDE uses).
///   - Files >maxBytes (default 4 MB) are skipped — we don't want
///     200MB build outputs in the timeline.
///   - One pending capture per (path, hash) tuple is in flight at a
///     time so a 250ms FS event burst doesn't multiply into N
///     identical journal entries.
///   - Errors during capture log + suppress; the timeline is a
///     quality-of-life feature, never the cause of a crash.
///
/// **Pruning**
///   - Per-file rolling cap: `maxRevisionsPerFile` (default 200).
///   - Per-workspace age cap: `maxAge` (default 30 days).
///   - Per-workspace size cap: `maxBytes` (default 200 MB).
///   - Sweep on init + every hour while running.
///   - GC sweep walks the journal, computes the live blob set,
///     deletes orphan blobs.
///
/// Diff support is text-only by design — binary blobs restore but
/// don't render side-by-side.
class TimelineService extends ChangeNotifier {
  /// Hash truncation matches `PreferencesService._wsKey` so we can
  /// reuse it as a cross-feature workspace key without re-deriving.
  static const int _wsHashLen = 16;

  /// Path segments we never capture revisions for. Mirror of the IDE-
  /// wide ignore set used by `_fsWatcherIgnore` / `_treeIgnore` —
  /// kept here as its own copy so this service stays free of
  /// upstream imports (only `path` + `archive` + `crypto` /
  /// `path_provider` /  Flutter foundation).
  static const Set<String> _ignoreSegs = <String>{
    '.git',
    '.dart_tool',
    'node_modules',
    'build',
    'dist',
    'out',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.turbo',
    '.cache',
    '.parcel-cache',
    '.vscode',
    '.vscode-test',
    '.idea',
    '.gradle',
    'venv',
    '.venv',
    'env',
    '__pycache__',
    '.pytest_cache',
    '.mypy_cache',
    '.tox',
    'target',
    'Pods',
    '.expo',
    '.expo-shared',
    '.flutter-plugins-dependencies',
    '.flutter-plugins',
    'coverage',
    // We DO snapshot `.lumen` since user rules / tools are exactly
    // the kind of thing they'll regret losing. We deliberately
    // ignore our own `.lumen/timeline` mirror under workspace
    // (it doesn't live there today, but if a future build ever
    // moves snapshots into the workspace this guards against
    // capturing our own captures).
    '.lumen-timeline-recursion-guard',
  };

  /// Hard cap on file size (bytes). Anything bigger is skipped — too
  /// large to hash + gzip + diff cheaply, and almost certainly an
  /// asset / build output the user doesn't want in revision history.
  static const int _maxFileBytes = 4 * 1024 * 1024;

  /// Per-file revision cap. After this many revisions, pruning drops
  /// the oldest non-baseline entries until we're back under the cap.
  /// Baselines are sticky — they're our only "original anchor".
  static const int _maxRevisionsPerFile = 200;

  /// Workspace-wide quotas applied during pruning. Tuned to keep an
  /// active mid-size project (Lumen itself, ~500 source files,
  /// dozens of saves/day) comfortably under a couple hundred MB
  /// over a month.
  static const Duration _maxAge = Duration(days: 30);
  static const int _maxWorkspaceBytes = 200 * 1024 * 1024;
  static const Duration _pruneInterval = Duration(hours: 1);

  /// FNV-style random suffix length for new entry ids.
  static const int _idSuffixLen = 6;

  // ── service state ─────────────────────────────────────────────
  String? _workspacePath;
  Directory? _root;
  File? _journalFile;
  Directory? _objectsDir;

  /// In-memory cache of the journal — newest first. Kept in step
  /// with `journal.ndjson` writes. Bounded only by the prune
  /// schedule.
  final List<TimelineEntry> _entries = <TimelineEntry>[];

  /// Quick lookup of the most recent entry per file (newest first).
  /// `_headByPath[rel]` returns the entry that established the
  /// current state, used to compute `prevHash` and to suppress
  /// no-op writes (`newHash == head.newHash`).
  final Map<String, TimelineEntry> _headByPath = <String, TimelineEntry>{};

  /// Set of (path,newHash) pairs whose capture is currently in
  /// flight. Prevents 250ms FS event bursts from spawning N parallel
  /// hash-and-write tasks for the same content.
  final Set<String> _inFlight = <String>{};

  /// Workspace-relative paths the agent recorder has claimed
  /// exclusively for the current tool invocation. Guards against the
  /// FS-watcher → `recordWrite(origin: fsEvent)` racing the agent's
  /// `recordWrite(origin: agentTool)` for the same write. Without
  /// this, on Windows the OS often delivers the FS notification
  /// faster than the recorder can grab the `_inFlight` slot — the
  /// fsEvent entry wins, the agentTool call returns null, and the
  /// "recent edits" tracker can't find the entry by `(turnId, origin
  /// == agentTool)`. See `recordWrite` for the enforcement and
  /// `TimelineRecorder.beforeTool` / `afterTool` for the lifecycle.
  final Set<String> _agentReserved = <String>{};

  Timer? _pruneTimer;
  bool _initInFlight = false;

  // ── chat context plumbing ─────────────────────────────────────
  // The chat controller drops these in / out around each tool pass
  // so agent-origin entries can be grouped per chat message in the
  // future restore feature. Cleared explicitly by `clearChatContext`
  // when the agent run is done; subsequent unrelated FS events
  // never inherit stale chat IDs.
  String? _ctxSessionId;
  String? _ctxTurnId;
  String? _ctxMessageId;

  /// True when the service is mounted to a workspace and ready to
  /// accept `recordWrite` calls.
  bool get isReady => _workspacePath != null && _root != null;

  /// Read-only newest-first snapshot of every entry currently held
  /// in memory. Returned as an unmodifiable view.
  List<TimelineEntry> get entries => List.unmodifiable(_entries);

  String? get workspacePath => _workspacePath;

  /// Mount [workspacePath] as the active workspace. Loading the
  /// journal is best-effort — corrupt lines are skipped, missing
  /// files are treated as "fresh history". Idempotent: rebinding to
  /// the same workspace short-circuits.
  ///
  /// Pass `null` to detach (used by `closeWorkspace`).
  Future<void> bindToWorkspace(String? workspacePath) async {
    if (_workspacePath == workspacePath) return;
    if (_initInFlight) return;
    _initInFlight = true;
    try {
      _entries.clear();
      _headByPath.clear();
      _inFlight.clear();
      _pruneTimer?.cancel();
      _pruneTimer = null;

      _workspacePath = workspacePath;
      _root = null;
      _journalFile = null;
      _objectsDir = null;

      if (workspacePath == null || workspacePath.isEmpty) {
        notifyListeners();
        return;
      }

      final base = await getApplicationSupportDirectory();
      final wsKey = _wsKeyFor(workspacePath);
      final root = Directory(p.join(base.path, 'lumen', 'timeline', wsKey));
      if (!await root.exists()) {
        await root.create(recursive: true);
      }
      _root = root;
      _journalFile = File(p.join(root.path, 'journal.ndjson'));
      _objectsDir = Directory(p.join(root.path, 'objects'));
      if (!await _objectsDir!.exists()) {
        await _objectsDir!.create(recursive: true);
      }

      await _writeMetaIfMissing(root, workspacePath);
      await _loadJournal();
      _pruneTimer = Timer.periodic(_pruneInterval, (_) => _runPruneSafe());
      // Run an initial prune asynchronously — don't block bind, the
      // sweep can take a second on a large journal.
      unawaited(_runPruneSafe());
      notifyListeners();
    } catch (e, st) {
      debugPrint('TimelineService.bindToWorkspace failed: $e\n$st');
    } finally {
      _initInFlight = false;
    }
  }

  /// Set the ambient chat correlation IDs. Called by `ChatController`
  /// **before** dispatching a tool pass to the executor; cleared via
  /// `clearChatContext` once the pass completes (whether success,
  /// error, or cancellation). Recorded on every captured entry from
  /// here on regardless of `origin` — the timeline UI ignores chat
  /// fields on non-agent entries, but keeping them for e.g. an
  /// `fsEvent` that fires *during* a tool run gives the future
  /// per-message restore feature a fuller picture of "everything
  /// touched in this turn".
  void setChatContext({String? sessionId, String? turnId, String? messageId}) {
    _ctxSessionId = sessionId;
    _ctxTurnId = turnId;
    _ctxMessageId = messageId;
  }

  void clearChatContext() {
    _ctxSessionId = null;
    _ctxTurnId = null;
    _ctxMessageId = null;
  }

  /// Reserve [absPath] for the agent recorder. Any non-`agentTool`
  /// recordWrite for this path while reserved is silently skipped —
  /// see the `_agentReserved` field doc for the race this guards
  /// against. Idempotent. Pass-through no-op when the path is
  /// outside the workspace (the recorder only ever calls this with
  /// in-workspace paths anyway).
  void reserveForAgent(String absPath) {
    if (!isReady) return;
    final ws = _workspacePath!;
    if (!_isUnder(ws, absPath)) return;
    _agentReserved.add(_normalizeRel(_relTo(ws, absPath)));
  }

  /// Release a previous [reserveForAgent] for [absPath]. Always
  /// call this after `recordWrite(origin: agentTool, ...)` returns
  /// (use `try`/`finally` in the recorder so an exception during the
  /// write doesn't leak a permanent reservation).
  void releaseForAgent(String absPath) {
    if (!isReady) return;
    final ws = _workspacePath!;
    if (!_isUnder(ws, absPath)) return;
    _agentReserved.remove(_normalizeRel(_relTo(ws, absPath)));
  }

  // ── public capture API ────────────────────────────────────────

  /// Capture the current contents of [absPath] as a new revision.
  /// Suppressed when the file's hash equals the previous head — we
  /// don't fill the timeline with no-op writes.
  ///
  /// Returns the new entry id when persisted, or null when skipped
  /// (ignored path, file too big, identical content, missing file
  /// in a non-`delete` flow, etc.).
  Future<String?> recordWrite(
    String absPath, {
    required TimelineOrigin origin,
    String? tool,
    String? note,
  }) async {
    if (!isReady) return null;
    final ws = _workspacePath!;
    if (!_isUnder(ws, absPath)) return null;
    final rel = _relTo(ws, absPath);
    if (_isIgnored(rel)) return null;
    // Race guard: when the agent recorder has reserved this path,
    // suppress non-agentTool writes so the recorder's `agentTool`
    // capture wins the journal slot. Without this, on Windows the
    // FS watcher's recordWrite often races ahead of the recorder
    // (because `ReadDirectoryChangesW` notifies extremely fast)
    // and the entry lands as `fsEvent`, breaking the recent-edits
    // tracker's `origin == agentTool` filter.
    if (origin != TimelineOrigin.agentTool &&
        _agentReserved.contains(_normalizeRel(rel))) {
      return null;
    }

    final file = File(absPath);
    if (!await file.exists()) {
      // The mutation was actually a delete — recordDelete is the
      // proper surface for that. Caller should have routed there.
      return null;
    }

    Uint8List bytes;
    try {
      final stat = await file.stat();
      if (stat.size > _maxFileBytes) return null;
      bytes = await file.readAsBytes();
    } catch (e) {
      debugPrint('TimelineService.recordWrite read failed for $rel: $e');
      return null;
    }

    final newHash = _hashBytes(bytes);
    final head = _headByPath[rel];
    if (head != null &&
        head.newHash == newHash &&
        head.op != TimelineOp.delete) {
      return null;
    }

    final flightKey = '$rel|$newHash';
    if (!_inFlight.add(flightKey)) return null;
    try {
      final kind = _detectKind(bytes);
      await _persistBlob(newHash, bytes);
      final op = head == null || head.op == TimelineOp.delete
          ? TimelineOp.create
          : TimelineOp.modify;
      final entry = TimelineEntry(
        id: _newId(),
        when: DateTime.now(),
        relPath: rel,
        op: op,
        origin: origin,
        tool: tool,
        sessionId: _ctxSessionId,
        turnId: _ctxTurnId,
        messageId: _ctxMessageId,
        newHash: newHash,
        newSize: bytes.length,
        newKind: kind,
        prevHash: head?.newHash ?? '',
        prevSize: head?.newSize ?? 0,
        renamedFrom: null,
        note: note,
      );
      await _appendEntry(entry);
      return entry.id;
    } finally {
      _inFlight.remove(flightKey);
    }
  }

  /// Capture a delete. We snapshot the prior content as a blob first
  /// so the file can still be restored from the timeline — a delete
  /// without a final blob would be a one-way door.
  Future<String?> recordDelete(
    String absPath, {
    required TimelineOrigin origin,
    String? tool,
    String? note,
  }) async {
    if (!isReady) return null;
    final ws = _workspacePath!;
    if (!_isUnder(ws, absPath)) return null;
    final rel = _relTo(ws, absPath);
    if (_isIgnored(rel)) return null;

    // If the file is still on disk (delete pre-snapshot) capture the
    // current bytes so the user has the most recent version. If it's
    // already gone, fall back to whatever the head entry pointed to.
    final file = File(absPath);
    String prevHashUsed = '';
    int prevSizeUsed = 0;
    TimelineKind prevKindUsed = TimelineKind.text;

    if (await file.exists()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.length <= _maxFileBytes) {
          prevHashUsed = _hashBytes(bytes);
          prevSizeUsed = bytes.length;
          prevKindUsed = _detectKind(bytes);
          await _persistBlob(prevHashUsed, bytes);
        }
      } catch (_) {
        /* fall through to head fallback */
      }
    }
    if (prevHashUsed.isEmpty) {
      final head = _headByPath[rel];
      if (head == null || head.op == TimelineOp.delete) return null;
      prevHashUsed = head.newHash;
      prevSizeUsed = head.newSize;
      prevKindUsed = head.newKind;
    }

    final entry = TimelineEntry(
      id: _newId(),
      when: DateTime.now(),
      relPath: rel,
      op: TimelineOp.delete,
      origin: origin,
      tool: tool,
      sessionId: _ctxSessionId,
      turnId: _ctxTurnId,
      messageId: _ctxMessageId,
      newHash: '',
      newSize: 0,
      newKind: TimelineKind.text,
      prevHash: prevHashUsed,
      prevSize: prevSizeUsed,
      renamedFrom: null,
      note: note,
    );
    // We slot prevKind into the kind field of the *previous* entry
    // implicitly; nothing to do with `prevKindUsed` except keep it
    // in scope for clarity.
    // ignore: unused_local_variable
    final _ = prevKindUsed;
    await _appendEntry(entry);
    return entry.id;
  }

  /// Emit a rename entry from `srcAbs` to `dstAbs`. The destination's
  /// content is hashed (after the move it's the same bytes, just at
  /// a new path) so renames also produce a normal modify-style head
  /// entry on the destination — meaning `restoreToRevision` on a
  /// renamed file works without special casing.
  Future<String?> recordRename(
    String srcAbs,
    String dstAbs, {
    required TimelineOrigin origin,
    String? tool,
    String? note,
  }) async {
    if (!isReady) return null;
    final ws = _workspacePath!;
    if (!_isUnder(ws, srcAbs) && !_isUnder(ws, dstAbs)) return null;
    final relFrom = _relTo(ws, srcAbs);
    final relTo = _relTo(ws, dstAbs);
    if (_isIgnored(relTo)) return null;

    final file = File(dstAbs);
    if (!await file.exists()) return null;
    Uint8List bytes;
    try {
      final stat = await file.stat();
      if (stat.size > _maxFileBytes) return null;
      bytes = await file.readAsBytes();
    } catch (_) {
      return null;
    }
    final newHash = _hashBytes(bytes);
    final kind = _detectKind(bytes);
    await _persistBlob(newHash, bytes);
    final priorHead = _headByPath[relFrom];

    final entry = TimelineEntry(
      id: _newId(),
      when: DateTime.now(),
      relPath: relTo,
      op: TimelineOp.rename,
      origin: origin,
      tool: tool,
      sessionId: _ctxSessionId,
      turnId: _ctxTurnId,
      messageId: _ctxMessageId,
      newHash: newHash,
      newSize: bytes.length,
      newKind: kind,
      prevHash: priorHead?.newHash ?? '',
      prevSize: priorHead?.newSize ?? 0,
      renamedFrom: relFrom,
      note: note,
    );
    await _appendEntry(entry);

    // Also drop a `delete` row for the source so its history is
    // visibly closed out and a future scan-for-orphans pass doesn't
    // try to baseline the now-missing path.
    final srcDelete = TimelineEntry(
      id: _newId(),
      when: DateTime.now(),
      relPath: relFrom,
      op: TimelineOp.delete,
      origin: origin,
      tool: tool,
      sessionId: _ctxSessionId,
      turnId: _ctxTurnId,
      messageId: _ctxMessageId,
      newHash: '',
      newSize: 0,
      newKind: TimelineKind.text,
      prevHash: priorHead?.newHash ?? '',
      prevSize: priorHead?.newSize ?? 0,
      renamedFrom: null,
      note: 'renamed to $relTo',
    );
    await _appendEntry(srcDelete);
    return entry.id;
  }

  /// Capture a baseline if we've never seen this file before. Cheap
  /// no-op when a head entry already exists for the path. Used by
  /// the editor on file-open: the first time we look at a file we
  /// want at least one anchor in history before any modification.
  Future<void> ensureBaseline(String absPath) async {
    if (!isReady) return;
    final ws = _workspacePath!;
    if (!_isUnder(ws, absPath)) return;
    final rel = _relTo(ws, absPath);
    if (_isIgnored(rel)) return;
    if (_headByPath.containsKey(rel)) return;
    await recordWrite(
      absPath,
      origin: TimelineOrigin.baseline,
      note: 'Initial state',
    );
  }

  // ── retrieval ─────────────────────────────────────────────────

  /// All entries for [relPath] in newest-first order. Returns empty
  /// when the file has never been seen.
  List<TimelineEntry> entriesForPath(String relPath) {
    final norm = _normalizeRel(relPath);
    return _entries.where((e) => e.relPath == norm).toList(growable: false);
  }

  /// Latest entry for [relPath], or null.
  TimelineEntry? headFor(String relPath) {
    return _headByPath[_normalizeRel(relPath)];
  }

  /// Lookup a single entry by id. Used by the diff view / restore
  /// dialog after the rail / list emits an id.
  TimelineEntry? entryById(String id) {
    for (final e in _entries) {
      if (e.id == id) return e;
    }
    return null;
  }

  /// Agent-origin entries tied to a chat assistant message. New builds tag
  /// entries with `PersistedMessage.id`; older builds used
  /// `<sessionId>@<assistant-timestamp-micros>`, passed as [legacyMessageId].
  List<TimelineEntry> entriesForMessage(
    String messageId, {
    String? legacyMessageId,
  }) {
    return _entries
        .where(
          (e) =>
              e.origin == TimelineOrigin.agentTool &&
              (e.messageId == messageId ||
                  (legacyMessageId != null && e.messageId == legacyMessageId)),
        )
        .toList(growable: false);
  }

  /// Read a blob from disk. Returns null when the blob is missing
  /// (pruned out of band, manual deletion, IO error). Callers must
  /// handle null gracefully.
  Future<Uint8List?> readBlob(String hash) async {
    if (hash.isEmpty || _objectsDir == null) return null;
    final file = _blobFileFor(hash);
    if (!await file.exists()) return null;
    try {
      final compressed = await file.readAsBytes();
      final out = const GZipDecoder().decodeBytes(compressed);
      return Uint8List.fromList(out);
    } catch (e) {
      debugPrint('TimelineService.readBlob failed for $hash: $e');
      return null;
    }
  }

  /// Build the data the diff view needs: current file (or null if
  /// deleted) + the contents of the entry's `newHash` (or
  /// `prevHash` when the entry itself is a delete — that's the
  /// state of the file just before it disappeared).
  Future<TimelineSnapshotPair?> buildPair(TimelineEntry entry) async {
    if (!isReady) return null;
    final ws = _workspacePath!;
    final abs = p.join(ws, entry.relPath.replaceAll('/', p.separator));

    Uint8List? currentBytes;
    TimelineKind currentKind = TimelineKind.text;
    int currentSize = 0;
    String? currentText;
    final f = File(abs);
    if (await f.exists()) {
      try {
        currentBytes = await f.readAsBytes();
        currentSize = currentBytes.length;
        currentKind = _detectKind(currentBytes);
        if (currentKind == TimelineKind.text) {
          currentText = utf8.decode(currentBytes, allowMalformed: true);
        }
      } catch (_) {}
    }

    final revHash = entry.op == TimelineOp.delete
        ? entry.prevHash
        : entry.newHash;
    Uint8List? revBytes;
    TimelineKind revKind = TimelineKind.text;
    int revSize = entry.op == TimelineOp.delete
        ? entry.prevSize
        : entry.newSize;
    String? revText;
    if (revHash.isNotEmpty) {
      revBytes = await readBlob(revHash);
      if (revBytes != null) {
        revKind = _detectKind(revBytes);
        if (revKind == TimelineKind.text) {
          revText = utf8.decode(revBytes, allowMalformed: true);
        }
      }
    }

    return TimelineSnapshotPair(
      currentKind: currentBytes == null ? TimelineKind.text : currentKind,
      currentText: currentText,
      currentSize: currentSize,
      revisionKind: revBytes == null ? revKind : revKind,
      revisionText: revText,
      revisionSize: revSize,
    );
  }

  // ── restore ───────────────────────────────────────────────────

  /// Write the contents of [entry]'s revision back to disk. For
  /// `delete` entries this restores the file's prior state at the
  /// path it lived at; for `rename` entries this restores at the
  /// destination path (the entry's `relPath`).
  ///
  /// Returns the message string produced — surfaced via toast.
  Future<TimelineRestoreResult> restoreToRevision(TimelineEntry entry) async {
    if (!isReady) {
      return const TimelineRestoreResult(
        ok: false,
        message: 'Timeline not bound to a workspace.',
      );
    }
    final ws = _workspacePath!;
    final abs = p.join(ws, entry.relPath.replaceAll('/', p.separator));
    final hash = entry.op == TimelineOp.delete ? entry.prevHash : entry.newHash;
    if (hash.isEmpty) {
      return TimelineRestoreResult(
        ok: false,
        message: 'No content snapshot for ${entry.relPath}.',
      );
    }
    final bytes = await readBlob(hash);
    if (bytes == null) {
      return TimelineRestoreResult(
        ok: false,
        message: 'Stored content for ${entry.relPath} is missing on disk.',
      );
    }
    try {
      // Capture the pre-restore state first — restoring is itself a
      // mutation worth remembering, so the user can undo the undo.
      // origin = explorer because the user clicked through a UI
      // affordance; the chat-context plumbing is null here so this
      // doesn't get wrongly attributed to a chat message.
      await _safeCaptureBeforeRestore(abs);
      final f = File(abs);
      await f.parent.create(recursive: true);
      await f.writeAsBytes(bytes, flush: true);
      // Record the restore as its own entry so the timeline shows it
      // (otherwise the user would see a mysterious modify entry from
      // the FS watcher with no clue who caused it).
      await recordWrite(
        abs,
        origin: TimelineOrigin.explorer,
        note: 'Restored to revision ${entry.id}',
      );
      return TimelineRestoreResult(
        ok: true,
        message: 'Restored ${entry.relPath} to ${_humanWhen(entry.when)}.',
      );
    } catch (e) {
      return TimelineRestoreResult(ok: false, message: 'Restore failed: $e');
    }
  }

  /// Revert every agent file operation associated with a chat assistant
  /// message. This is the bulk companion to [restoreToRevision].
  ///
  /// The entries are already newest-first in `_entries`; applying that order
  /// naturally walks the tool changes backwards. `create` deletes the created
  /// file, `modify` restores `prevHash`, `delete` restores `prevHash`, and
  /// `rename` removes the destination and restores the previous source blob.
  Future<TimelineBulkRestoreResult> restoreMessageChanges(
    String messageId, {
    String? legacyMessageId,
  }) async {
    if (!isReady) {
      return const TimelineBulkRestoreResult(
        ok: false,
        message: 'Timeline not bound to a workspace.',
      );
    }
    final entries = entriesForMessage(
      messageId,
      legacyMessageId: legacyMessageId,
    );
    if (entries.isEmpty) {
      return const TimelineBulkRestoreResult(
        ok: false,
        message: 'No file changes were recorded for this message.',
      );
    }

    final touched = <String>{};
    final failures = <String>[];
    for (final entry in entries) {
      try {
        await _revertEntry(entry);
        touched.add(entry.relPath);
        if (entry.renamedFrom != null) touched.add(entry.renamedFrom!);
      } catch (e) {
        failures.add('${entry.relPath}: $e');
      }
    }
    notifyListeners();
    if (failures.isNotEmpty) {
      return TimelineBulkRestoreResult(
        ok: false,
        message:
            'Restored ${entries.length - failures.length}/${entries.length} timeline change(s). Failed: ${failures.join('; ')}',
        touchedRelPaths: touched.toList(growable: false),
      );
    }
    return TimelineBulkRestoreResult(
      ok: true,
      message: 'Restored ${entries.length} timeline change(s).',
      touchedRelPaths: touched.toList(growable: false),
    );
  }

  Future<void> _revertEntry(TimelineEntry entry) async {
    final ws = _workspacePath!;
    final abs = p.join(ws, entry.relPath.replaceAll('/', p.separator));

    Future<void> snapshotIfPresent(String targetAbs) async {
      final f = File(targetAbs);
      if (await f.exists()) {
        await recordWrite(
          targetAbs,
          origin: TimelineOrigin.explorer,
          note: 'Pre-chat-restore snapshot',
        );
      }
    }

    switch (entry.op) {
      case TimelineOp.create:
        await snapshotIfPresent(abs);
        final type = await FileSystemEntity.type(abs);
        if (type == FileSystemEntityType.file) {
          await File(abs).delete();
          await recordDelete(
            abs,
            origin: TimelineOrigin.explorer,
            note: 'Chat restore removed created file',
          );
        } else if (type == FileSystemEntityType.directory) {
          await Directory(abs).delete(recursive: true);
        }
        return;
      case TimelineOp.modify:
        await snapshotIfPresent(abs);
        if (entry.prevHash.isEmpty) {
          if (await File(abs).exists()) await File(abs).delete();
          return;
        }
        await _writeBlobToPath(
          entry.prevHash,
          abs,
          note: 'Chat restore reverted modification',
        );
        return;
      case TimelineOp.delete:
        if (entry.prevHash.isEmpty) return;
        await _writeBlobToPath(
          entry.prevHash,
          abs,
          note: 'Chat restore restored deleted file',
        );
        return;
      case TimelineOp.rename:
        await snapshotIfPresent(abs);
        final dstType = await FileSystemEntity.type(abs);
        if (dstType == FileSystemEntityType.file) {
          await File(abs).delete();
        } else if (dstType == FileSystemEntityType.directory) {
          await Directory(abs).delete(recursive: true);
        }
        final from = entry.renamedFrom;
        if (from != null && entry.prevHash.isNotEmpty) {
          final fromAbs = p.join(ws, from.replaceAll('/', p.separator));
          await _writeBlobToPath(
            entry.prevHash,
            fromAbs,
            note: 'Chat restore reverted rename',
          );
        }
        return;
    }
  }

  Future<void> _writeBlobToPath(
    String hash,
    String absPath, {
    required String note,
  }) async {
    final bytes = await readBlob(hash);
    if (bytes == null) {
      throw StateError('stored content blob is missing ($hash)');
    }
    final f = File(absPath);
    await f.parent.create(recursive: true);
    await f.writeAsBytes(bytes, flush: true);
    await recordWrite(absPath, origin: TimelineOrigin.explorer, note: note);
  }

  Future<void> _safeCaptureBeforeRestore(String abs) async {
    try {
      final f = File(abs);
      if (await f.exists()) {
        await recordWrite(
          abs,
          origin: TimelineOrigin.explorer,
          note: 'Pre-restore snapshot',
        );
      }
    } catch (_) {}
  }

  // ── internals: persistence ────────────────────────────────────

  Future<void> _appendEntry(TimelineEntry entry) async {
    final f = _journalFile;
    if (f == null) return;
    final line = '${jsonEncode(entry.toJson())}\n';
    try {
      await f.writeAsString(line, mode: FileMode.append, flush: true);
      _entries.insert(0, entry);
      // Update head only when the entry IS the new head for its
      // path — a rename's source-side delete isn't a head update
      // for the rename target.
      _headByPath[entry.relPath] = entry;
      notifyListeners();
    } catch (e) {
      debugPrint('TimelineService journal append failed: $e');
    }
  }

  Future<void> _loadJournal() async {
    final f = _journalFile;
    if (f == null) return;
    if (!await f.exists()) return;
    try {
      final raw = await f.readAsString();
      if (raw.isEmpty) return;
      final lines = raw.split('\n');
      // Walk newest-first: append to a temp list, sort at the end.
      // Files can reach tens of thousands of lines — a stable sort
      // of N entries is still trivially fast vs the IO cost.
      final loaded = <TimelineEntry>[];
      for (final line in lines) {
        if (line.trim().isEmpty) continue;
        Map<String, dynamic> obj;
        try {
          obj = jsonDecode(line) as Map<String, dynamic>;
        } catch (_) {
          continue;
        }
        final e = TimelineEntry.tryFromJson(obj);
        if (e != null) loaded.add(e);
      }
      loaded.sort((a, b) => b.when.compareTo(a.when));
      _entries
        ..clear()
        ..addAll(loaded);
      _headByPath.clear();
      for (final e in loaded) {
        _headByPath.putIfAbsent(e.relPath, () => e);
      }
    } catch (e) {
      debugPrint('TimelineService journal load failed: $e');
    }
  }

  Future<void> _writeMetaIfMissing(Directory root, String workspace) async {
    final meta = File(p.join(root.path, 'meta.json'));
    if (await meta.exists()) return;
    final body = <String, dynamic>{
      'schema': TimelineEntry.schemaVersion,
      'workspace': workspace,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    await meta.writeAsString(jsonEncode(body));
  }

  File _blobFileFor(String hash) {
    final dir = _objectsDir!;
    final shard = hash.substring(0, 2);
    return File(p.join(dir.path, shard, '$hash.gz'));
  }

  Future<void> _persistBlob(String hash, Uint8List bytes) async {
    final file = _blobFileFor(hash);
    if (await file.exists()) return;
    await file.parent.create(recursive: true);
    final compressed = const GZipEncoder().encode(bytes);
    await file.writeAsBytes(compressed, flush: true);
  }

  // ── internals: helpers ────────────────────────────────────────

  static String _wsKeyFor(String path) {
    final norm = path.toLowerCase().replaceAll('\\', '/');
    final digest = sha256.convert(utf8.encode(norm)).toString();
    return digest.substring(0, _wsHashLen);
  }

  String _hashBytes(Uint8List bytes) {
    return sha256.convert(bytes).toString();
  }

  TimelineKind _detectKind(Uint8List bytes) {
    final n = bytes.length < 8192 ? bytes.length : 8192;
    var skip = 0;
    if (n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) {
      skip = 3;
    } else if (n >= 2 &&
        ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
            (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
      // UTF-16 BOMs: not text we can safely diff line-by-line, so
      // treat as binary even though they're "text" technically.
      return TimelineKind.binary;
    }
    for (var i = skip; i < n; i++) {
      if (bytes[i] == 0) return TimelineKind.binary;
    }
    return TimelineKind.text;
  }

  String _newId() {
    final ts = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final rng = Random();
    final buf = StringBuffer();
    for (var i = 0; i < _idSuffixLen; i++) {
      buf.writeCharCode(97 + rng.nextInt(26));
    }
    return 'rev_${ts}_$buf';
  }

  bool _isUnder(String workspaceAbs, String fileAbs) {
    final w = p.normalize(workspaceAbs);
    final f = p.normalize(fileAbs);
    final rel = p.relative(f, from: w);
    return !rel.startsWith('..') && !p.isAbsolute(rel);
  }

  String _relTo(String workspace, String fileAbs) {
    final rel = p.relative(fileAbs, from: workspace).replaceAll(r'\', '/');
    return rel;
  }

  String _normalizeRel(String rel) {
    return rel.replaceAll(r'\', '/');
  }

  bool _isIgnored(String rel) {
    final segs = rel.split('/');
    for (final s in segs) {
      if (_ignoreSegs.contains(s)) return true;
    }
    return false;
  }

  // ── pruning ──────────────────────────────────────────────────

  Future<void> _runPruneSafe() async {
    try {
      await _runPrune();
    } catch (e) {
      debugPrint('TimelineService prune failed: $e');
    }
  }

  Future<void> _runPrune() async {
    if (!isReady) return;
    final cutoffAge = DateTime.now().subtract(_maxAge);

    // 1. Group by file and trim per-file rolling cap (keep the
    //    oldest baseline + the most recent _maxRevisionsPerFile-1).
    // 2. Drop entries older than cutoffAge regardless of file.
    // 3. If the workspace blob bytes still exceeds _maxWorkspaceBytes,
    //    drop oldest entries (paired with their orphan blobs in the
    //    GC pass below) until we're back under quota.
    final byPath = <String, List<TimelineEntry>>{};
    for (final e in _entries) {
      byPath.putIfAbsent(e.relPath, () => <TimelineEntry>[]).add(e);
    }

    final keep = <String>{};
    for (final list in byPath.values) {
      // Already newest-first thanks to _entries ordering.
      // Keep newest N, plus the oldest baseline (if any) so we
      // always have an "original" anchor.
      final kept = <TimelineEntry>[];
      for (final e in list) {
        if (e.when.isBefore(cutoffAge)) continue;
        kept.add(e);
        if (kept.length >= _maxRevisionsPerFile) break;
      }
      // Salvage oldest baseline if it would be culled.
      final baseline = list.lastWhere(
        (e) => e.origin == TimelineOrigin.baseline,
        orElse: () => list.last,
      );
      if (!kept.any((e) => e.id == baseline.id)) kept.add(baseline);
      for (final e in kept) {
        keep.add(e.id);
      }
    }

    if (keep.length == _entries.length) {
      // No journal change needed; still GC orphan blobs.
      await _gcOrphanBlobs();
      return;
    }

    // Rewrite the journal atomically. NDJSON makes this trivial.
    final f = _journalFile;
    if (f == null) return;
    final keptEntries = _entries.where((e) => keep.contains(e.id)).toList()
      ..sort((a, b) => a.when.compareTo(b.when));
    final tmp = File('${f.path}.tmp');
    final sink = tmp.openWrite();
    try {
      for (final e in keptEntries) {
        sink.write(jsonEncode(e.toJson()));
        sink.write('\n');
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
    _entries
      ..clear()
      ..addAll(keptEntries.reversed);
    _headByPath.clear();
    for (final e in _entries) {
      _headByPath.putIfAbsent(e.relPath, () => e);
    }
    notifyListeners();
    await _gcOrphanBlobs();
    await _enforceWorkspaceSize();
  }

  Future<void> _gcOrphanBlobs() async {
    final dir = _objectsDir;
    if (dir == null || !await dir.exists()) return;
    final live = <String>{};
    for (final e in _entries) {
      if (e.newHash.isNotEmpty) live.add(e.newHash);
      if (e.prevHash.isNotEmpty) live.add(e.prevHash);
    }
    await for (final shard in dir.list()) {
      if (shard is! Directory) continue;
      await for (final blob in shard.list()) {
        if (blob is! File) continue;
        final name = p.basenameWithoutExtension(blob.path);
        if (!live.contains(name)) {
          try {
            await blob.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _enforceWorkspaceSize() async {
    final dir = _objectsDir;
    if (dir == null || !await dir.exists()) return;
    int total = 0;
    final blobSizes = <String, int>{};
    await for (final shard in dir.list()) {
      if (shard is! Directory) continue;
      await for (final blob in shard.list()) {
        if (blob is! File) continue;
        try {
          final s = await blob.stat();
          total += s.size;
          blobSizes[p.basenameWithoutExtension(blob.path)] = s.size;
        } catch (_) {}
      }
    }
    if (total <= _maxWorkspaceBytes) return;

    // Drop oldest non-baseline entries until under quota. The
    // journal is reverse-sorted (newest first); we walk from the
    // end and drop, then GC orphan blobs at the close.
    final journal = List<TimelineEntry>.from(_entries.reversed);
    final keepIds = _entries.map((e) => e.id).toSet();
    int idx = 0;
    while (total > _maxWorkspaceBytes && idx < journal.length) {
      final e = journal[idx++];
      if (e.origin == TimelineOrigin.baseline) continue;
      keepIds.remove(e.id);
      final blob = _blobFileFor(e.newHash);
      if (await blob.exists()) {
        try {
          final s = await blob.stat();
          total -= s.size;
          await blob.delete();
        } catch (_) {}
      }
    }
    final remaining = _entries.where((e) => keepIds.contains(e.id)).toList();
    if (remaining.length == _entries.length) return;

    final f = _journalFile;
    if (f == null) return;
    final ordered = List<TimelineEntry>.from(remaining)
      ..sort((a, b) => a.when.compareTo(b.when));
    final tmp = File('${f.path}.tmp');
    final sink = tmp.openWrite();
    try {
      for (final e in ordered) {
        sink.write(jsonEncode(e.toJson()));
        sink.write('\n');
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (await f.exists()) await f.delete();
    await tmp.rename(f.path);
    _entries
      ..clear()
      ..addAll(ordered.reversed);
    _headByPath.clear();
    for (final e in _entries) {
      _headByPath.putIfAbsent(e.relPath, () => e);
    }
    notifyListeners();
  }

  static String _humanWhen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inSeconds < 5) return 'just now';
    if (diff.inSeconds < 60) return '${diff.inSeconds}s ago';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return t.toLocal().toString().substring(0, 16);
  }

  @override
  void dispose() {
    _pruneTimer?.cancel();
    _pruneTimer = null;
    super.dispose();
  }
}

class TimelineRestoreResult {
  final bool ok;
  final String message;
  const TimelineRestoreResult({required this.ok, required this.message});
}

class TimelineBulkRestoreResult {
  final bool ok;
  final String message;
  final List<String> touchedRelPaths;
  const TimelineBulkRestoreResult({
    required this.ok,
    required this.message,
    this.touchedRelPaths = const [],
  });
}
