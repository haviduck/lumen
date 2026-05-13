// Data model for the per-workspace file revision timeline.
//
// Every mutation to a tracked file (agent tool, user save, FS event,
// explorer action, baseline snapshot on first sight) is captured as a
// TimelineEntry. Entries reference content-addressed blobs by sha256
// so that re-saving the same content is free, and so the same revision
// can be referenced from multiple journals (e.g. a "delete" entry
// referencing the prior content blob so the file can still be
// restored).
//
// This file holds only the data classes; the actual capture / storage /
// restore logic lives in `timeline_service.dart`. Keeping the shapes here
// makes the model trivially serialisable for tests and for future external
// tooling that wants to read Lumen's revision log without pulling Flutter in.

/// Why a revision was captured. The classification matters for the
/// timeline UI (filter chips), for restore safety ("never silently
/// restore something the user manually saved"), and as a contract for
/// the per-chat-message restore feature: only entries whose
/// `origin == agentTool` get tied to a `(sessionId, turnId, messageId)`
/// triple via the chat-context plumbing in `TimelineService`.
enum TimelineOrigin {
  /// Saved through the editor's `saveFileByPath` (Ctrl+S, save-on-close,
  /// etc.). The user explicitly chose to persist this state.
  userSave,

  /// An agent tool wrote the file (CREATE_FILE, EDIT_FILE, MULTI_EDIT,
  /// APPEND_FILE, MOVE_FILE, DELETE_FILE). Carries `tool` + the chat
  /// `sessionId` / `turnId` / `messageId` so the future
  /// "restore from this chat message" feature can group these.
  agentTool,

  /// External filesystem write detected via the recursive
  /// `Directory.watch`. Anything outside Lumen — `git checkout`, a
  /// formatter, another editor, build output — lands here.
  fsEvent,

  /// Triggered by the file explorer's UI (rename, delete, drop).
  explorer,

  /// First time the timeline has seen this file in this workspace.
  /// Captured lazily before the first non-baseline modification so we
  /// always have an "empty/original" anchor to diff against and
  /// restore to.
  baseline,

  /// Catch-all for unexpected sources. Should not appear in healthy
  /// runs; surfaced in the UI as "Other" so corruption is visible
  /// rather than silently filtered out.
  unknown,
}

/// What happened to the file in this entry. `modify` covers both
/// content edits and metadata-only writes (we don't distinguish — if
/// the hash changed it's a modify; if it didn't, the entry is
/// suppressed before it lands).
enum TimelineOp { create, modify, delete, rename }

/// Whether a captured blob is text or binary. We don't refuse to
/// snapshot binaries — they restore just fine — but the diff UI shows
/// "binary content (N bytes)" instead of trying to render them as
/// text. Detection is a null-byte sniff over the first 8KB; cheap,
/// correct enough for source trees, never fooled by UTF-16 BOMs in
/// practice (we strip those before sniffing).
enum TimelineKind { text, binary }

/// One row in the timeline journal.
///
/// **Compact intentionally** — workspaces with thousands of saves
/// across weeks need this to deserialise cheaply. Heavy fields (the
/// content itself) live in the blob store and are referenced by
/// [newHash] / [prevHash].
class TimelineEntry {
  /// Schema version. Bump when the on-disk shape changes; the loader
  /// drops entries with an unknown `v` rather than crash.
  static const int schemaVersion = 1;

  /// Stable id (`rev_<microseconds>_<rand>`). Used as the ground-truth
  /// pointer the timeline UI passes around.
  final String id;

  /// When the mutation was captured (server time).
  final DateTime when;

  /// Workspace-relative path with forward slashes. Always normalised
  /// — Windows `\` is collapsed to `/` so journals are
  /// platform-portable and so the same file under different path
  /// casings doesn't fragment its history. Casing is preserved on
  /// the segments themselves.
  final String relPath;

  final TimelineOp op;
  final TimelineOrigin origin;

  /// Tool id when [origin] is [TimelineOrigin.agentTool]. Null
  /// otherwise. Snake-case, mirrors `AgentTool.id` so the UI can
  /// look up display metadata directly.
  final String? tool;

  /// Chat correlation IDs. Populated by `TimelineRecorder` from the
  /// ambient chat context that `ChatController` sets on the service
  /// before each tool pass. All three are nullable because:
  ///   - `sessionId` is only set during agent runs (other origins
  ///      don't have a chat to attribute to);
  ///   - `turnId` may be absent if the agent runs are pre-update;
  ///   - `messageId` is the *latest* assistant message at the moment
  ///      of capture, used by the future per-message restore — it
  ///      resolves at restore time via `(sessionId, turnId)` if
  ///      `messageId` itself isn't stable yet.
  final String? sessionId;
  final String? turnId;
  final String? messageId;

  /// sha256 of the current contents, hex. Empty string on `delete`.
  final String newHash;

  /// Byte size of the current contents. Zero on `delete`.
  final int newSize;

  /// Whether the new contents were stored as text or binary.
  final TimelineKind newKind;

  /// sha256 of the file's contents BEFORE this entry. Empty string
  /// when the file didn't exist (a `create` entry's prevHash is
  /// always ''). Stored alongside [newHash] so the diff view can
  /// look up "previous + current" without walking the journal back.
  final String prevHash;

  final int prevSize;

  /// Source path on a `rename` op (workspace-relative, slash-normalised).
  /// Null on every other op.
  final String? renamedFrom;

  /// Free-form short label. Surfaced as a tooltip in the rail / table.
  /// Used today for "Auto-save" / "Edited via tool: edit_file" / etc.
  final String? note;

  const TimelineEntry({
    required this.id,
    required this.when,
    required this.relPath,
    required this.op,
    required this.origin,
    required this.newHash,
    required this.newSize,
    required this.newKind,
    required this.prevHash,
    required this.prevSize,
    this.tool,
    this.sessionId,
    this.turnId,
    this.messageId,
    this.renamedFrom,
    this.note,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': schemaVersion,
    'id': id,
    'ts': when.toUtc().toIso8601String(),
    'rel': relPath,
    'op': op.name,
    'origin': origin.name,
    if (tool != null) 'tool': tool,
    if (sessionId != null) 'sessionId': sessionId,
    if (turnId != null) 'turnId': turnId,
    if (messageId != null) 'messageId': messageId,
    'newHash': newHash,
    'newSize': newSize,
    'newKind': newKind.name,
    'prevHash': prevHash,
    'prevSize': prevSize,
    if (renamedFrom != null) 'renamedFrom': renamedFrom,
    if (note != null) 'note': note,
  };

  /// Returns `null` when [json] can't be parsed safely. The journal
  /// loader treats null as "skip this line" — a single corrupt
  /// entry must never poison the whole history.
  static TimelineEntry? tryFromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v is! int || v != schemaVersion) return null;
      final id = json['id'] as String?;
      final ts = DateTime.tryParse(json['ts'] as String? ?? '');
      final rel = json['rel'] as String?;
      if (id == null || ts == null || rel == null) return null;
      final op = TimelineOp.values
          .where((e) => e.name == json['op'])
          .firstOrNull();
      final origin =
          TimelineOrigin.values
              .where((e) => e.name == json['origin'])
              .firstOrNull() ??
          TimelineOrigin.unknown;
      final kind =
          TimelineKind.values
              .where((e) => e.name == json['newKind'])
              .firstOrNull() ??
          TimelineKind.text;
      if (op == null) return null;
      return TimelineEntry(
        id: id,
        when: ts.toLocal(),
        relPath: rel,
        op: op,
        origin: origin,
        tool: json['tool'] as String?,
        sessionId: json['sessionId'] as String?,
        turnId: json['turnId'] as String?,
        messageId: json['messageId'] as String?,
        newHash: (json['newHash'] as String?) ?? '',
        newSize: (json['newSize'] as int?) ?? 0,
        newKind: kind,
        prevHash: (json['prevHash'] as String?) ?? '',
        prevSize: (json['prevSize'] as int?) ?? 0,
        renamedFrom: json['renamedFrom'] as String?,
        note: json['note'] as String?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Durable index for "one assistant turn touched these timeline entries".
///
/// The journal remains the source of truth for content and ordering. This
/// manifest is a recovery index: even if the chat bubble that originally
/// owned the edits is removed by chat rewind, the turn still appears in
/// the timeline and can be restored by [entryIds].
class TimelineTurnManifest {
  static const int schemaVersion = 1;

  final String turnId;
  final String sessionId;
  final String messageId;
  final DateTime startedAt;
  final DateTime endedAt;
  final String userPromptPreview;
  final List<String> entryIds;

  const TimelineTurnManifest({
    required this.turnId,
    required this.sessionId,
    required this.messageId,
    required this.startedAt,
    required this.endedAt,
    required this.userPromptPreview,
    required this.entryIds,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': schemaVersion,
    'turnId': turnId,
    'sessionId': sessionId,
    'messageId': messageId,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'endedAt': endedAt.toUtc().toIso8601String(),
    'userPromptPreview': userPromptPreview,
    'entryIds': entryIds,
  };

  static TimelineTurnManifest? tryFromJson(Map<String, dynamic> json) {
    try {
      final v = json['v'];
      if (v is! int || v != schemaVersion) return null;
      final turnId = json['turnId'] as String?;
      final sessionId = json['sessionId'] as String?;
      final messageId = json['messageId'] as String?;
      final startedAt = DateTime.tryParse(json['startedAt'] as String? ?? '');
      final endedAt = DateTime.tryParse(json['endedAt'] as String? ?? '');
      if (turnId == null ||
          sessionId == null ||
          messageId == null ||
          startedAt == null ||
          endedAt == null) {
        return null;
      }
      final ids = ((json['entryIds'] as List?) ?? const <Object?>[])
          .whereType<String>()
          .where((id) => id.isNotEmpty)
          .toList(growable: false);
      return TimelineTurnManifest(
        turnId: turnId,
        sessionId: sessionId,
        messageId: messageId,
        startedAt: startedAt.toLocal(),
        endedAt: endedAt.toLocal(),
        userPromptPreview: (json['userPromptPreview'] as String?) ?? '',
        entryIds: ids,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Tiny helper because `firstOrNull` on a filtered iterable isn't on
/// `WhereIterable` directly. Avoids pulling `package:collection` for
/// one call site.
extension _FirstOrNull<T> on Iterable<T> {
  T? firstOrNull() {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}

/// Pair returned by the timeline service when the diff UI asks for
/// the "current vs revision" view. `current` is null when the file
/// has been deleted; `revision` is null when the entry refers to the
/// pre-existence state of the file (i.e. the revision predates the
/// file, which can't happen today but is reserved for a future
/// "restore through a delete" path).
class TimelineSnapshotPair {
  final TimelineKind currentKind;
  final String? currentText;
  final int currentSize;
  final TimelineKind revisionKind;
  final String? revisionText;
  final int revisionSize;
  const TimelineSnapshotPair({
    required this.currentKind,
    required this.currentText,
    required this.currentSize,
    required this.revisionKind,
    required this.revisionText,
    required this.revisionSize,
  });
}
