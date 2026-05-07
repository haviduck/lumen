import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'reasoning_effort.dart';

enum ChatReferenceKind { file, folder }

class ChatReference {
  final String path;
  final String? workspaceRelativePath;
  final ChatReferenceKind kind;

  const ChatReference({
    required this.path,
    required this.kind,
    this.workspaceRelativePath,
  });

  String get label => workspaceRelativePath ?? p.basename(path);
  String get inlineToken => '@$label';

  Map<String, dynamic> toJson() => {
    'path': path,
    'rel': workspaceRelativePath,
    'kind': kind.name,
  };

  factory ChatReference.fromJson(Map<String, dynamic> j) {
    final rawKind = j['kind'] as String?;
    return ChatReference(
      path: (j['path'] ?? '') as String,
      workspaceRelativePath: j['rel'] as String?,
      kind: rawKind == ChatReferenceKind.folder.name
          ? ChatReferenceKind.folder
          : ChatReferenceKind.file,
    );
  }
}

/// On-disk chat session model.
class ChatSession {
  final String id;
  String title;
  final DateTime createdAt;
  DateTime updatedAt;
  String? workspacePath;
  String? model;

  /// Per-session "how much should the model think" dial. Surfaced as
  /// the Off/Standard/Deep pill in the chat composer, persisted here
  /// so each chat keeps its own value (you might want a quick "fast"
  /// chat for one-off tweaks and a "deep" chat for refactoring). New
  /// sessions seed with [ReasoningEffort.standard]; legacy sessions
  /// loaded from disk that pre-date this field also default there
  /// (see [fromJson]).
  ReasoningEffort reasoningEffort;
  List<PersistedMessage> messages;

  /// LLM-generated summary of dropped-middle history, persisted across
  /// reloads so a long session that's already paid the summarization
  /// cost doesn't re-summarize after an app restart. `null` means
  /// "no cached summary" — either the session is short enough that
  /// summarization never ran, or summarization is disabled, or the
  /// last attempt fell back to the deterministic elision placeholder.
  ///
  /// Refreshed by `ChatController._maybeSummarizeHistory` when the
  /// dropped span has grown beyond
  /// `chat.historySummary.refreshDelta` messages since the cached
  /// summary was produced. See `lib/providers/chat/history_summarizer.dart`.
  String? cachedHistorySummary;

  /// Number of dropped (non-tail, non-first-user) messages folded
  /// into [cachedHistorySummary]. Used as the cache key — when the
  /// current dropped count exceeds this by `refreshDelta`, the
  /// cache is stale and the summarizer re-runs. `null` whenever
  /// [cachedHistorySummary] is `null`.
  int? cachedHistorySummaryDroppedCount;

  ChatSession({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.workspacePath,
    this.model,
    this.reasoningEffort = ReasoningEffort.standard,
    required this.messages,
    this.cachedHistorySummary,
    this.cachedHistorySummaryDroppedCount,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'workspacePath': workspacePath,
    'model': model,
    'reasoningEffort': reasoningEffort.id,
    'messages': messages.map((m) => m.toJson()).toList(),
    if (cachedHistorySummary != null) 'historySummary': cachedHistorySummary,
    if (cachedHistorySummaryDroppedCount != null)
      'historySummaryDropped': cachedHistorySummaryDroppedCount,
  };

  factory ChatSession.fromJson(Map<String, dynamic> j) {
    var rawModel = j['model'] as String?;
    if (rawModel != null && rawModel.startsWith('github:')) {
      rawModel = null;
    }
    return ChatSession(
      id: j['id'] as String,
      title: (j['title'] ?? 'Untitled') as String,
      createdAt: DateTime.parse(j['createdAt'] as String),
      updatedAt: DateTime.parse(j['updatedAt'] as String),
      workspacePath: j['workspacePath'] as String?,
      model: rawModel,
      reasoningEffort: reasoningEffortFromId(j['reasoningEffort'] as String?),
      messages: ((j['messages'] as List?) ?? const [])
          .map((e) => PersistedMessage.fromJson(e as Map<String, dynamic>))
          .toList(),
      cachedHistorySummary: j['historySummary'] as String?,
      cachedHistorySummaryDroppedCount: (j['historySummaryDropped'] as num?)
          ?.toInt(),
    );
  }
}

class PersistedMessage {
  final String id;
  final String role; // 'user' | 'assistant' | 'system' | 'tool'
  final String content;
  final List<String> imagesBase64; // attached images (multimodal)
  final List<ChatReference> references; // attached file/folder references
  final DateTime timestamp;

  /// Optional short label rendered in the chat bubble *instead of*
  /// [content]. The model still receives the full [content] — only
  /// the UI presentation changes. Currently set by slash commands
  /// (e.g. `/handoff`) so the user sees a tidy `/handoff` chip
  /// instead of the multi-paragraph prompt the agent actually reads.
  final String? displayContent;

  /// Wall-clock duration of the entire turn that produced this
  /// message, in milliseconds. Set on assistant messages only,
  /// populated by `ChatController._runGenerationLoop` just before
  /// the message is persisted. `null` for legacy messages stored
  /// before timing was added, for user messages, and for messages
  /// where the loop crashed before the timing stamp ran.
  ///
  /// Diagnostic-only — used by the chat bubble's small footer and
  /// by debug logs to pinpoint whether a turn hit Ollama Cloud's
  /// 182s hard timeout (issue #15973) vs. a local-network glitch
  /// vs. a model that just "stopped" mid-iteration.
  final int? totalDurationMs;

  /// Time-to-first-byte for this turn, in milliseconds — measured
  /// from the moment the controller began the first iteration's
  /// stream to the first non-empty chunk it received (any chunk
  /// counts, including the LUMEN_THINK_START sentinel; "first
  /// activity" is the right signal for diagnosis). `null` if no
  /// chunk ever arrived, on user messages, or on legacy data.
  final int? firstByteLatencyMs;

  /// Number of model passes ("iterations") that ran inside the
  /// agent loop for this turn. A simple Q&A is 1; a tool-heavy
  /// turn that read a file then edited it then verified is 4.
  /// Combined with [totalDurationMs] tells you whether the wall
  /// time was spent on one slow pass vs. many fast passes.
  final int? iterationCount;

  /// Wall-clock duration of the LAST iteration only, in
  /// milliseconds. The single most useful number for diagnosing
  /// the 182s cloud timeout: if total=240s but last=180s, the
  /// last iteration is what hit the wall and that's where the
  /// fix has to land.
  final int? lastIterationDurationMs;

  /// Per-message random hex string baked into every real
  /// `<!-- LUMEN_TOOL:... -->` marker the executor emits while
  /// producing this message. The chat-side renderer
  /// (`tool_segments.dart::parseChatSegments`) only renders a
  /// marker as a real tool card when the marker's trailing nonce
  /// equals this field; markers without a nonce or with a
  /// mismatching one are treated as model-emitted impersonation
  /// (the failure mode where weak Ollama models latch onto the
  /// HTML-comment shape they see in history and emit fake
  /// "Created"/"Edited" chips with no real tool firing) and are
  /// stripped from the rendered output.
  ///
  /// `null` for two cases:
  ///   1. **Legacy messages** persisted before nonce-binding
  ///      shipped — their markers don't carry a nonce field, the
  ///      renderer keeps the pre-binding behavior (accept any
  ///      well-formed marker as real).
  ///   2. **Non-assistant messages** (user, system, tool) which
  ///      never contain executor markers in the first place.
  ///
  /// New assistant turns generate a fresh nonce in
  /// `ChatController._runGenerationLoop` and stamp it here before
  /// persisting. The nonce is intentionally per-message (not
  /// per-session): a per-session nonce would let the model copy
  /// the value out of conversation history and re-inject it as a
  /// successful mimicry; a per-message nonce changes every turn
  /// so the only valid nonce is one the model has never seen.
  final String? toolMarkerNonce;

  PersistedMessage({
    String? id,
    required this.role,
    required this.content,
    this.imagesBase64 = const [],
    this.references = const [],
    this.displayContent,
    DateTime? timestamp,
    this.totalDurationMs,
    this.firstByteLatencyMs,
    this.iterationCount,
    this.lastIterationDurationMs,
    this.toolMarkerNonce,
  }) : timestamp = timestamp ?? DateTime.now(),
       id = id ?? _generateId();

  Map<String, dynamic> toJson() => {
    'id': id,
    'role': role,
    'content': content,
    'images': imagesBase64,
    'references': references.map((r) => r.toJson()).toList(),
    if (displayContent != null) 'display': displayContent,
    'ts': timestamp.toIso8601String(),
    if (totalDurationMs != null) 'durationMs': totalDurationMs,
    if (firstByteLatencyMs != null) 'ttfbMs': firstByteLatencyMs,
    if (iterationCount != null) 'iters': iterationCount,
    if (lastIterationDurationMs != null)
      'lastIterMs': lastIterationDurationMs,
    if (toolMarkerNonce != null) 'toolNonce': toolMarkerNonce,
  };

  factory PersistedMessage.fromJson(Map<String, dynamic> j) {
    final ts = DateTime.tryParse((j['ts'] ?? '') as String) ?? DateTime.now();
    return PersistedMessage(
      id: j['id'] as String? ?? _legacyId(j['role'] as String? ?? '', ts),
      role: j['role'] as String,
      content: (j['content'] ?? '') as String,
      imagesBase64: ((j['images'] as List?) ?? const [])
          .map((e) => e as String)
          .toList(),
      references: ((j['references'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => ChatReference.fromJson(Map<String, dynamic>.from(e)))
          .where((r) => r.path.isNotEmpty)
          .toList(),
      displayContent: j['display'] as String?,
      timestamp: ts,
      totalDurationMs: (j['durationMs'] as num?)?.toInt(),
      firstByteLatencyMs: (j['ttfbMs'] as num?)?.toInt(),
      iterationCount: (j['iters'] as num?)?.toInt(),
      lastIterationDurationMs: (j['lastIterMs'] as num?)?.toInt(),
      toolMarkerNonce: j['toolNonce'] as String?,
    );
  }

  static String _generateId() {
    final micros = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'msg_$micros';
  }

  static String _legacyId(String role, DateTime timestamp) {
    final micros = timestamp.microsecondsSinceEpoch.toRadixString(36);
    return 'legacy_${role}_$micros';
  }
}

/// Stores chat sessions as individual JSON files in the user's app support
/// directory, plus an index file for fast listing.
class ChatPersistenceService {
  static const String _indexFileName = 'sessions_index.json';

  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'chat_sessions'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  Future<File> _sessionFile(String id) async {
    final root = await _ensureRoot();
    return File(p.join(root.path, '$id.json'));
  }

  Future<File> _indexFile() async {
    final root = await _ensureRoot();
    return File(p.join(root.path, _indexFileName));
  }

  /// Per-chat task log. Lives next to the session JSON as
  /// `<id>.tasks.md`. Plain markdown for grep/edit/git friendliness;
  /// `ChatController` reads this and injects it into the system
  /// prompt so the model can see what's already been completed in
  /// this conversation. Auto-appended to after every successful turn
  /// (deterministic, no LLM round-trip).
  ///
  /// Why a separate file vs. embedding in the JSON: the file can be
  /// hand-edited (user can correct or strip a misclassified entry),
  /// version-controlled if the user copies it into the workspace,
  /// and grows independently of the session JSON's parse cost.
  Future<File> _tasksFile(String id) async {
    final root = await _ensureRoot();
    return File(p.join(root.path, '$id.tasks.md'));
  }

  /// Read the tasks markdown for a chat. Returns empty string when
  /// the file doesn't exist yet — callers treat that as "no prior
  /// work logged".
  Future<String> loadTasks(String id) async {
    try {
      final f = await _tasksFile(id);
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      debugPrint('Failed to load tasks for $id: $e');
      return '';
    }
  }

  /// Append a single completed-turn entry to the tasks file. Creates
  /// the file with a `# Chat Tasks` header on first write so the
  /// document opens cleanly in markdown previewers. Each entry is a
  /// task-list line:
  ///
  ///     - [x] 2026-04-29 14:32 — User: "fix scroll bug" — tools: edit_file, multi_edit
  ///
  /// Caller is responsible for forming [entry] without the leading
  /// `- [x]` / newline.
  Future<void> appendTaskEntry(String id, String entry) async {
    try {
      final f = await _tasksFile(id);
      final exists = await f.exists();
      final buf = StringBuffer();
      if (!exists) {
        buf.writeln('# Chat Tasks');
        buf.writeln();
        buf.writeln(
          '<!-- Auto-maintained by Lumen. One entry per completed turn. -->',
        );
        buf.writeln(
          '<!-- The agent reads this on every turn so prior requests are not re-executed. -->',
        );
        buf.writeln(
          '<!-- Edit by hand if an entry is wrong; the agent will respect your edits. -->',
        );
        buf.writeln();
      }
      buf.writeln('- [x] $entry');
      await f.writeAsString(buf.toString(), mode: FileMode.append);
    } catch (e) {
      debugPrint('Failed to append task entry for $id: $e');
    }
  }

  /// Best-effort cleanup when a session is deleted. Doesn't throw —
  /// missing file is fine.
  Future<void> deleteTasks(String id) async {
    try {
      final f = await _tasksFile(id);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<List<ChatSession>> listSessions() async {
    try {
      final f = await _indexFile();
      if (!await f.exists()) return [];
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return [];
      final data = jsonDecode(raw) as List<dynamic>;
      return data
          .map((e) => ChatSession.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (e) {
      debugPrint('Failed to list chat sessions: $e');
      return [];
    }
  }

  Future<ChatSession?> loadSession(String id) async {
    try {
      final f = await _sessionFile(id);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return ChatSession.fromJson(j);
    } catch (e) {
      debugPrint('Failed to load session $id: $e');
      return null;
    }
  }

  Future<void> saveSession(ChatSession session) async {
    final f = await _sessionFile(session.id);
    await f.writeAsString(jsonEncode(session.toJson()));
    await _rebuildIndex();
  }

  Future<void> deleteSession(String id) async {
    final f = await _sessionFile(id);
    if (await f.exists()) {
      await f.delete();
    }
    // Tasks log is per-session; nuke it alongside.
    await deleteTasks(id);
    await _rebuildIndex();
  }

  Future<void> _rebuildIndex() async {
    final root = await _ensureRoot();
    final List<Map<String, dynamic>> entries = [];
    await for (final e in root.list()) {
      if (e is File &&
          e.path.endsWith('.json') &&
          p.basename(e.path) != _indexFileName) {
        try {
          final j = jsonDecode(await e.readAsString()) as Map<String, dynamic>;
          entries.add({
            'id': j['id'],
            'title': j['title'],
            'createdAt': j['createdAt'],
            'updatedAt': j['updatedAt'],
            'workspacePath': j['workspacePath'],
            'model': j['model'],
            'reasoningEffort': j['reasoningEffort'],
            'messages': const [],
          });
        } catch (_) {
          /* skip corrupt */
        }
      }
    }
    final f = await _indexFile();
    await f.writeAsString(jsonEncode(entries));
  }

  String generateId() {
    final r = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    return 'sess_$r';
  }

  String deriveTitleFromMessage(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (cleaned.isEmpty) return 'New chat';
    return cleaned.length > 48 ? '${cleaned.substring(0, 48)}…' : cleaned;
  }
}
