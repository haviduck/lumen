import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/anthropic_service.dart';
import '../services/github_models_service.dart';
import '../services/chat_persistence_service.dart';
import '../services/external_tool_loader.dart';
import '../services/gemini_service.dart';
import '../services/ollama_service.dart';
import '../services/preferences_service.dart';
import '../services/provider_error.dart';
import '../services/reasoning_effort.dart';
import '../services/rules_service.dart';
import '../services/timeline_recorder.dart';
import '../services/recent_edits_tracker.dart';
import '../services/timeline_service.dart';
import '../services/tool_executor.dart';
import '../services/tool_registry.dart';
import '../services/workspace_skills_service.dart';

/// In-flight approval request shown to the user.
///
/// `toolId` is carried so the "Allow always" button on the approval
/// card can register a per-tool blanket approval instead of flipping
/// the global auto-approve. `label` is the human-readable tool name
/// (e.g. `RUN_CMD`) — the card uses it for the contextual button
/// label ("Always run" for `run_cmd`, "Always allow" otherwise).
class PendingApproval {
  final String toolId;
  final String label;
  final String detail;
  final Completer<bool> completer;
  PendingApproval({
    required this.toolId,
    required this.label,
    required this.detail,
    required this.completer,
  });
}

/// Audit-trail entry for a tool run that bypassed the approval card
/// (because of the master `_autoApprove` flag or a per-tool blanket
/// in `_autoApprovedTools`). Surfaced via
/// `ChatController.recentSilentApprovals` so the user can see what
/// ran without their per-call consent and revoke the rule that
/// caused it. `reason` is human-readable ("auto-approve all" or
/// "always-allow this tool"), suitable for direct display.
class SilentApproval {
  final String toolId;
  final String detail;
  final String reason;
  final DateTime when;
  const SilentApproval({
    required this.toolId,
    required this.detail,
    required this.reason,
    required this.when,
  });
}

/// User prompt that was composed while a generation was already in
/// flight. Held in `ChatController._promptQueue` and drained when the
/// current turn finishes (or sent immediately via
/// `sendQueuedPromptNow`, which cancels the in-flight turn first).
///
/// Carries everything `sendMessage` would normally read fresh from
/// `AppState` so the queue entry remains valid even if the user
/// switches workspace or active file before the queue drains. Without
/// this snapshot, a queued prompt would silently apply *current*
/// workspace context at drain time, which is surprising.
class QueuedPrompt {
  final String id;
  final String text;
  final List<String> imagesBase64;
  final List<ChatReference> references;
  final String? workspacePath;
  final String? activeFilePath;
  final List<String> openFilePaths;
  final DateTime queuedAt;

  QueuedPrompt({
    required this.id,
    required this.text,
    required this.imagesBase64,
    required this.references,
    required this.workspacePath,
    required this.activeFilePath,
    required this.openFilePaths,
    required this.queuedAt,
  });
}

/// Owns chat sessions, message generation, tool execution, multimodal
/// payloads, persistence, cancellation and approval prompts.
class ChatController extends ChangeNotifier {
  /// Hard cap on tool-use iterations per user request. Hoisted to a
  /// class-level constant so the system prompt can advertise the limit
  /// to the model (`$maxIters` interpolation) and the generation loop
  /// can enforce it from the same source of truth.
  static const int maxIters = 5;

  final OllamaService ollama;
  final GeminiService gemini;
  final AnthropicService anthropic;
  final GitHubModelsService github;
  final ChatPersistenceService persistence;
  final RulesService rules;
  final PreferencesService prefs;

  /// Loader for `.lumen/skills/*.md` instruction-based skills.
  /// Optional so non-IDE callers (tests) can construct without
  /// forcing a skills mount. Production wiring in `AppState` always
  /// supplies one. When present, `_runGenerationLoop` reloads the
  /// active workspace's skills on every send and injects them into
  /// the system prompt under `## Workspace skills`.
  final WorkspaceSkillsService? skills;

  /// Per-workspace file revision timeline. Optional so non-IDE
  /// callers (tests) can build a controller without forcing a
  /// timeline mount, but the production wiring in `AppState` always
  /// passes one through. Used to:
  ///   - tag every tool-origin entry with chat correlation IDs
  ///     (`sessionId` / `turnId` / `messageId`) before each tool
  ///     pass so the future per-message restore can group them;
  ///   - hand the executor a `TimelineRecorder` per pass.
  final TimelineService? timeline;

  /// Optional "recent agent edits" tracker. When supplied, the chat
  /// controller wipes it at turn-start and re-populates it at turn-end
  /// from the timeline entries the turn produced. Optional so tests
  /// can omit it; production wiring in `AppState` always supplies one.
  final RecentEditsTracker? _recentEdits;

  ChatController({
    required this.ollama,
    required this.gemini,
    required this.anthropic,
    required this.github,
    required this.persistence,
    required this.rules,
    required this.prefs,
    this.timeline,
    RecentEditsTracker? recentEdits,
    this.skills,
    ExternalToolLoader? toolLoader,
  }) : _recentEdits = recentEdits,
       _toolLoader = toolLoader ?? ExternalToolLoader();

  final ExternalToolLoader _toolLoader;

  /// Last workspace we loaded external tools for. Used so we don't re-walk
  /// disk on every send — it's wasteful and produces churn in the tool
  /// registry that the toggle UI has to redraw past.
  String? _toolsLoadedFor;
  bool _toolsLoadInFlight = false;

  // ---- session state ----
  // `_sessions` is the full archive of chats persisted on disk.
  // `_openTabIds` is the *subset* the user currently has open as tabs in
  // the chat panel — Cursor-style: closing a tab keeps the chat in
  // history, opening from history makes it a tab again. Order is
  // preserved (browser-tab convention: leftmost is index 0).
  //
  // **Per-workspace scoping** — `_currentWorkspace` is the path of the
  // workspace whose tab state is currently mounted. `null` means the
  // legacy / "no workspace open" bucket (Welcome screen). All
  // `_openTabIds` mutations persist to *this* workspace's key via
  // `_persistOpenTabs()`; switching workspaces flows through
  // `bindToWorkspace(path)` which saves the old key, loads the new,
  // and seeds a fresh tab when the new workspace has no prior chats.
  final List<ChatSession> _sessions = [];
  final List<String> _openTabIds = [];
  ChatSession? _current;
  String? _currentWorkspace;

  /// Sessions visible to the chat-history menu. **Strict per-workspace
  /// scoping** — orphan / legacy sessions DO NOT bleed into other
  /// workspaces' history.
  ///
  /// - When `_currentWorkspace` is non-null: only sessions whose
  ///   `workspacePath` exactly matches are visible. Pre-upgrade
  ///   chats with no workspace (`workspacePath == null`) are
  ///   reachable from the no-workspace view (Welcome screen with no
  ///   project open) — see closeWorkspace.
  /// - When `_currentWorkspace` is null: all sessions are visible
  ///   (the "global archive" view used on the Welcome screen).
  ///
  /// Order matches `_sessions` order (`updatedAt` descending — set by
  /// `ChatPersistenceService.listSessions`).
  ///
  /// Earlier versions of this getter included null-workspace orphans
  /// in every workspace's history "so users don't lose access". That
  /// turned every project's history into a polluted dumping ground;
  /// the user can still get to orphans by closing the workspace.
  List<ChatSession> get sessions {
    if (_currentWorkspace == null) {
      return List.unmodifiable(_sessions);
    }
    return List.unmodifiable(
      _sessions.where((s) => s.workspacePath == _currentWorkspace),
    );
  }

  ChatSession? get currentSession => _current;
  String? get currentWorkspace => _currentWorkspace;
  List<PersistedMessage> get messages => _current?.messages ?? const [];

  /// Sessions currently open as tabs, in tab-strip order. Falls back to
  /// skipping any tab id whose session has gone missing from `_sessions`
  /// (deleted out from under us, or persistence corrupted) — defensive,
  /// so the UI never tries to render a tab without a backing session.
  List<ChatSession> get openTabs {
    final out = <ChatSession>[];
    for (final id in _openTabIds) {
      final s = _sessions.where((e) => e.id == id);
      if (s.isNotEmpty) out.add(s.first);
    }
    return List.unmodifiable(out);
  }

  // ---- generation state ----
  bool _isGenerating = false;
  CancellationToken? _cancelToken;
  PendingApproval? _pendingApproval;
  bool _autoApprove = false;

  // ---- generation timing (stall detection) ----
  // `_generationStartedAt` is set when a turn begins streaming and
  // cleared in `finally{}`. `_lastChunkAt` ticks every time a
  // streaming chunk arrives (or when an iteration boundary completes).
  // The chat panel reads these to render an escalating "model has
  // been silent" badge — see `generationElapsed` / `silenceDuration`.
  //
  // Why two timestamps not one: total elapsed is a poor stall signal
  // (a hard prompt on a thinking model legitimately takes minutes),
  // but inter-chunk silence IS — a model that's still streaming
  // tokens is not stuck, just slow. The UI badges on silence, not
  // total elapsed.
  DateTime? _generationStartedAt;
  DateTime? _lastChunkAt;

  // ---- last-prompt cache (for the retry chip on provider errors) ----
  // The retry chip on `ProviderErrorCard` re-supplies workspace
  // context fresh from `AppState`, so we don't bother caching paths
  // here — only the user-message reference matters for `canRetryLastTurn`.
  PersistedMessage? _lastUserMessageForRetry;

  // ---- prompt queue (composed while generating) ----
  // Send-while-generating no longer silently fails — the user's text
  // lands here as a `QueuedPrompt`, the chat panel surfaces it in a
  // visible strip, and the controller drains the queue when the
  // current turn finishes. Each entry carries its own workspace
  // snapshot (see QueuedPrompt) so a queued prompt run after the
  // user switched workspaces still resolves to the original context.
  final List<QueuedPrompt> _promptQueue = <QueuedPrompt>[];
  int _nextQueueId = 0;
  // Per-tool blanket approvals — distinct from `_autoApprove`
  // (the global "approve everything" master switch). Driven by the
  // approval card's "Allow always" / "Always run" button: clicking
  // it adds *only this tool's id* here, so future calls of the
  // same tool skip the prompt without affecting any other gated
  // tool. Cleared individually from Settings.
  final Set<String> _autoApprovedTools = <String>{};

  /// Ring buffer of recent **silently-approved** tool runs. Populated
  /// from `_approveCommand` whenever an approval gate is bypassed
  /// without showing the user the approval card — i.e. the global
  /// `_autoApprove` master switch is on, OR the tool is in the
  /// `_autoApprovedTools` per-tool set. Capped at 30 entries so the
  /// list doesn't grow unbounded over a long session.
  ///
  /// Surfaced via the `recentSilentApprovals` getter — the UI shows
  /// these so the user can audit "wait, why did that just run?" and
  /// revoke the approval that caused it.
  final List<SilentApproval> _silentApprovals = <SilentApproval>[];
  static const int _silentApprovalCap = 30;
  String _selectedModel = 'llama3';
  List<String> _availableModels = ['llama3'];
  final Set<String> _enabledModels = <String>{};
  final Set<String> _enabledTools = ToolRegistry.all
      .where((t) => t.defaultEnabled)
      .map((t) => t.id)
      .toSet();

  bool get isGenerating => _isGenerating;
  PendingApproval? get pendingApproval => _pendingApproval;
  bool get autoApprove => _autoApprove;

  /// Time the current generation has been running, or `null` when
  /// not generating. UI uses this for elapsed-time labels next to
  /// the streaming indicator.
  Duration? get generationElapsed {
    final start = _generationStartedAt;
    if (start == null) return null;
    return DateTime.now().difference(start);
  }

  /// Wall-clock time since the last streamed chunk arrived, or
  /// `null` when not generating. The chat panel uses this to badge
  /// "model has been silent for X seconds" once it crosses a
  /// threshold — a stall signal that's robust even when the model
  /// is just slow.
  Duration? get silenceDuration {
    final last = _lastChunkAt;
    if (last == null || !_isGenerating) return null;
    return DateTime.now().difference(last);
  }

  /// Read-only view of the user's queued prompts (entries that landed
  /// while a generation was still in flight). Order = drain order =
  /// queue order — head runs first when the current turn finishes.
  List<QueuedPrompt> get queuedPrompts => List.unmodifiable(_promptQueue);

  /// True when a retry of the last turn is meaningful — i.e. there
  /// is a remembered last user message and we are NOT currently
  /// generating. The chat-side error card uses this to gate its
  /// Retry chip.
  bool get canRetryLastTurn =>
      !_isGenerating && _lastUserMessageForRetry != null;

  /// Read-only view of the tool ids the user has permanently
  /// approved via the "Allow always" button. Settings renders this
  /// as a list with X-to-revoke per entry.
  Set<String> get autoApprovedTools => Set.unmodifiable(_autoApprovedTools);

  /// Most-recent-first list of silently-approved tool runs (those
  /// that bypassed the approval card via auto-approve / always-allow).
  /// UI uses this to audit "what just ran without asking me?".
  List<SilentApproval> get recentSilentApprovals =>
      List.unmodifiable(_silentApprovals);
  String get selectedModel => _selectedModel;
  List<String> get availableModels => _availableModels;
  Set<String> get enabledModels => Set.unmodifiable(_enabledModels);
  List<String> get pickerModels {
    final enabled = _availableModels.where(_enabledModels.contains).toList();
    return List.unmodifiable(enabled);
  }

  Set<String> get enabledTools => _enabledTools;

  // ---- pending image attachments for the next message ----
  final List<String> _pendingImages = []; // base64
  List<String> get pendingImages => List.unmodifiable(_pendingImages);
  final List<ChatReference> _pendingReferences = <ChatReference>[];
  List<ChatReference> get pendingReferences =>
      List.unmodifiable(_pendingReferences);
  final List<String> _pendingComposerInsertions = <String>[];

  List<String> consumePendingComposerInsertions() {
    if (_pendingComposerInsertions.isEmpty) return const <String>[];
    final out = List<String>.from(_pendingComposerInsertions);
    _pendingComposerInsertions.clear();
    return out;
  }

  // Media playback is now owned by `MediaController` (see
  // `providers/media_controller.dart`). The previous `requestMediaUrl`
  // / `consumeMediaUrl` queueing pattern existed because `_AiChatState`
  // owned the `WebviewController`; it doesn't anymore — both the chat
  // panel and the editor area consume `MediaController` directly via
  // `Consumer<MediaController>`.

  // ---- init ----
  Future<void> init() async {
    _autoApprove = await prefs.getAutoApprove();
    _autoApprovedTools
      ..clear()
      ..addAll(await prefs.getAutoApprovedTools());
    // Restore the previously-selected model BEFORE fetching the
    // current model list, so we can compare against the (possibly
    // changed) available list deliberately rather than falling to
    // whatever happens to be first. Without this, restart would
    // silently flip the routing every time `_availableModels.first`
    // happened to be a different provider than the user picked.
    final savedSelectedModel = await prefs.getSelectedModel();
    if (savedSelectedModel.isNotEmpty) {
      _selectedModel = savedSelectedModel;
    }
    _availableModels = await _fetchModels();
    await _loadEnabledModelsForCurrentAvailability();
    await _ensureSelectedModelUsable();
    _sessions
      ..clear()
      ..addAll(await persistence.listSessions());

    // Restore open-tab state for the **no-workspace bucket**
    // (`_currentWorkspace == null`). This is the boot state — once
    // `AppState.setDirectory` lands, it'll call `bindToWorkspace(path)`
    // which swaps in the project-specific tab list. Filter out stale
    // ids whose sessions no longer exist on disk, then seed a single
    // tab if the user has any sessions but no tab state yet (back-compat
    // for installs that predated tab persistence entirely).
    final storedTabs = await prefs.getOpenTabIdsForWorkspace(null);
    final knownIds = _sessions.map((s) => s.id).toSet();
    _openTabIds
      ..clear()
      ..addAll(storedTabs.where(knownIds.contains));

    final lastId = await prefs.getCurrentSessionIdForWorkspace(null);
    if (lastId.isNotEmpty) {
      final loaded = await persistence.loadSession(lastId);
      _current = loaded;
      if (loaded != null && !_openTabIds.contains(loaded.id)) {
        _openTabIds.add(loaded.id);
      }
    }
    if (_openTabIds.isEmpty && _sessions.isNotEmpty) {
      _openTabIds.add(_sessions.first.id);
      _current ??= _sessions.first;
      await _persistCurrentSessionId(_current!.id);
    }
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Persist the current `_openTabIds` to the bucket for whichever
  /// workspace is mounted right now. Per-workspace scoping is the
  /// reason we don't reach for the legacy global key here.
  Future<void> _persistOpenTabs() =>
      prefs.setOpenTabIdsForWorkspace(_currentWorkspace, _openTabIds);

  /// Persist the active session id under the current workspace's
  /// bucket. Empty string clears it.
  Future<void> _persistCurrentSessionId(String id) =>
      prefs.setCurrentSessionIdForWorkspace(_currentWorkspace, id);

  /// Walks `<workspace>/.lumen/tools/` plus the global app-support tools
  /// dir and replaces the runtime portion of [ToolRegistry]. Cached per
  /// workspace path; pass `force: true` to bypass the cache (used by a
  /// future "Reload Tools" command if we ever add one).
  Future<void> reloadExternalTools(
    String? workspacePath, {
    bool force = false,
  }) async {
    if (!force && _toolsLoadedFor == workspacePath) return;
    if (_toolsLoadInFlight) return;
    _toolsLoadInFlight = true;
    try {
      final tools = await _toolLoader.loadAll(workspacePath: workspacePath);
      ToolRegistry.replaceRuntime(tools);
      _toolsLoadedFor = workspacePath;
      // Newly-discovered tools that ship `defaultEnabled: true` should be
      // on for the user without forcing them to flip switches; we never
      // touch IDs the user has explicitly set, so this is additive only
      // for first-time-seen ids.
      for (final t in tools) {
        if (t.defaultEnabled) _enabledTools.add(t.id);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('reloadExternalTools failed: $e');
    } finally {
      _toolsLoadInFlight = false;
    }
  }

  Future<void> reloadModels({Set<String>? enabledProviders}) async {
    _availableModels = await _fetchModels(enabledProviders: enabledProviders);
    await _loadEnabledModelsForCurrentAvailability();
    await _ensureSelectedModelUsable();
    notifyListeners();
  }

  Future<void> _loadEnabledModelsForCurrentAvailability() async {
    final stored = await prefs.getEnabledChatModels();
    final known = await prefs.getKnownChatModels();
    if (stored == null) {
      _enabledModels
        ..clear()
        ..addAll(_availableModels);
      await prefs.setEnabledChatModels(_enabledModels.toList()..sort());
      await prefs.setKnownChatModels(_availableModels.toList()..sort());
      return;
    }

    // If we have an enabled list but no known-model list, this is an upgrade
    // from the earlier implementation. Treat all currently available models as
    // known so models intentionally absent from `stored` remain disabled.
    final knownSet = known == null ? _availableModels.toSet() : known.toSet();
    _enabledModels
      ..clear()
      ..addAll(stored.where(_availableModels.contains));
    // Newly discovered models start enabled, but only truly new models.
    // Previously we compared only against the enabled list, which meant
    // deliberately disabled models were re-enabled on reload.
    for (final model in _availableModels) {
      if (!knownSet.contains(model)) _enabledModels.add(model);
    }
    if (_enabledModels.isEmpty && _availableModels.isNotEmpty) {
      _enabledModels.add(_availableModels.first);
    }
    await prefs.setEnabledChatModels(_enabledModels.toList()..sort());
    await prefs.setKnownChatModels(_availableModels.toList()..sort());
  }

  Future<void> _ensureSelectedModelUsable() async {
    final usable = pickerModels;
    if (usable.isNotEmpty && !usable.contains(_selectedModel)) {
      _selectedModel = usable.first;
      await prefs.setSelectedModel(_selectedModel);
    }
  }

  /// Fetch models from all enabled providers, prefixed with provider tag.
  /// e.g. "claude:claude-sonnet-4-6", "gemini:gemini-2.5-pro",
  /// "ollama:llama3".
  Future<List<String>> _fetchModels({Set<String>? enabledProviders}) async {
    final enabled =
        enabledProviders ?? (await prefs.getEnabledProviders()).toSet();
    final all = <String>[];

    if (enabled.contains('Ollama')) {
      try {
        final models = await ollama.getModels();
        all.addAll(models.map((m) => 'ollama:$m'));
      } catch (_) {}
    }
    if (enabled.contains('Gemini')) {
      try {
        final models = await gemini.getModels();
        all.addAll(models.map((m) => 'gemini:$m'));
      } catch (_) {}
    }
    if (enabled.contains('Claude')) {
      try {
        final models = await anthropic.getModels();
        all.addAll(models.map((m) => 'claude:$m'));
      } catch (_) {}
    }
    if (enabled.contains('GitHub Models')) {
      try {
        final models = await github.getModels();
        all.addAll(models.map((m) => 'github:$m'));
      } catch (_) {}
    }
    // OpenAI placeholder — add when implemented.
    return all;
  }

  /// True if at least one enabled provider is reachable.
  Future<bool> isReachable() async {
    final enabled = (await prefs.getEnabledProviders()).toSet();
    if (enabled.contains('Ollama') && await ollama.isReachable()) return true;
    if (enabled.contains('Gemini') && await gemini.isReachable()) return true;
    if (enabled.contains('Claude') && await anthropic.isReachable()) {
      return true;
    }
    if (enabled.contains('GitHub Models') && await github.isReachable()) {
      return true;
    }
    return false;
  }

  /// Non-streaming utility generation for internal IDE flows that need a
  /// one-shot LLM result (skill/tool generation, titles, etc.) while still
  /// honoring the user's selected provider/model.
  Future<String> generateUtilityText(
    List<Map<String, dynamic>> messages, {
    String? model,
    CancellationToken? token,
  }) async {
    final routedModel = model ?? _selectedModel;
    final (provider, rawModel) = _splitModel(routedModel);
    final enabled = (await prefs.getEnabledProviders()).toSet();
    final providerName = switch (provider) {
      'gemini' => 'Gemini',
      'claude' => 'Claude',
      'github' => 'GitHub Models',
      _ => 'Ollama',
    };
    if (!enabled.contains(providerName)) {
      return 'Error: model "$routedModel" routes to $providerName, but '
          '$providerName is disabled in Settings -> AI/Chat.';
    }
    switch (provider) {
      case 'gemini':
        return gemini.generateChat(messages, model: rawModel, token: token);
      case 'claude':
        return anthropic.generateChat(messages, model: rawModel, token: token);
      case 'github':
        return github.generateChat(messages, model: rawModel, token: token);
      case 'ollama':
      default:
        return ollama.generateChat(messages, model: rawModel, token: token);
    }
  }

  /// Splits a prefixed model string into (provider, rawModel).
  static (String, String) _splitModel(String model) {
    final idx = model.indexOf(':');
    if (idx > 0) return (model.substring(0, idx), model.substring(idx + 1));
    // Legacy / unprefixed — assume Ollama.
    return ('ollama', model);
  }

  /// Route streaming chat generation through the right backend based on
  /// model prefix. Yields incremental text chunks.
  ///
  /// Defensive guard: if the routed provider isn't currently enabled
  /// in `prefs.getEnabledProviders()`, refuse to call it and yield a
  /// clear error string then end the stream. Without this check, a
  /// stale `_selectedModel` (e.g. user disabled Gemini in Settings
  /// but the model picker hadn't rebuilt yet) would silently fire a
  /// request to a disabled provider — manifesting to the user as
  /// "I picked Ollama, why am I getting a Gemini API error?".
  Stream<String> _generateChatStream(
    List<Map<String, dynamic>> messages, {
    required String model,
    CancellationToken? token,
    ReasoningEffort? effort,
  }) async* {
    final (provider, rawModel) = _splitModel(model);
    final enabled = (await prefs.getEnabledProviders()).toSet();
    final providerName = switch (provider) {
      'gemini' => 'Gemini',
      'claude' => 'Claude',
      'github' => 'GitHub Models',
      _ => 'Ollama',
    };
    if (!enabled.contains(providerName)) {
      yield 'Error: model "$model" routes to $providerName, but '
          '$providerName is disabled in Settings → AI/Chat. Enable '
          'it or switch to a model from an enabled provider.';
      return;
    }
    switch (provider) {
      case 'gemini':
        yield* gemini.generateChatStream(
          messages,
          model: rawModel,
          token: token,
          effort: effort,
        );
        return;
      case 'claude':
        yield* anthropic.generateChatStream(
          messages,
          model: rawModel,
          token: token,
          effort: effort,
        );
        return;
      case 'github':
        yield* github.generateChatStream(
          messages,
          model: rawModel,
          token: token,
          effort: effort,
        );
        return;
      case 'ollama':
      default:
        // Ollama has no native reasoning param; the prompt-suffix
        // fallback for [effort] is injected by `sendMessage` directly
        // into the system prompt before this is called.
        yield* ollama.generateChatStream(
          messages,
          model: rawModel,
          token: token,
        );
        return;
    }
  }

  /// Route title summarization through the right backend.
  Future<String> _summarizeTitle(
    String firstMessage, {
    required String model,
  }) async {
    final (provider, rawModel) = _splitModel(model);
    switch (provider) {
      case 'gemini':
        return gemini.summarizeTitle(firstMessage, model: rawModel);
      case 'claude':
        return anthropic.summarizeTitle(firstMessage, model: rawModel);
      case 'github':
        return github.summarizeTitle(firstMessage, model: rawModel);
      case 'ollama':
      default:
        return ollama.summarizeTitle(firstMessage, model: rawModel);
    }
  }

  void setModel(String model) {
    if (!_enabledModels.contains(model) && _availableModels.contains(model)) {
      _enabledModels.add(model);
      unawaited(prefs.setEnabledChatModels(_enabledModels.toList()..sort()));
    }
    _selectedModel = model;
    // Persist immediately (fire-and-forget) so a restart doesn't
    // lose the user's deliberate selection.
    unawaited(prefs.setSelectedModel(model));
    if (_current != null) {
      _current!.model = model;
      _persistCurrent();
    }
    notifyListeners();
  }

  Future<void> setModelEnabled(String model, bool enabled) async {
    if (!_availableModels.contains(model)) return;
    if (enabled) {
      _enabledModels.add(model);
    } else {
      if (_enabledModels.length <= 1 && _enabledModels.contains(model)) return;
      _enabledModels.remove(model);
      if (_selectedModel == model && pickerModels.isNotEmpty) {
        _selectedModel = pickerModels.first;
        await prefs.setSelectedModel(_selectedModel);
      }
    }
    await prefs.setEnabledChatModels(_enabledModels.toList()..sort());
    notifyListeners();
  }

  Future<void> setProviderModelsEnabled(String provider, bool enabled) async {
    final models = _availableModels
        .where((m) => _providerOfModel(m) == provider)
        .toList(growable: false);
    if (models.isEmpty) return;
    if (enabled) {
      _enabledModels.addAll(models);
    } else {
      final remaining = _enabledModels.difference(models.toSet());
      if (remaining.isEmpty) return; // Never leave the picker empty.
      _enabledModels
        ..clear()
        ..addAll(remaining);
      if (!_enabledModels.contains(_selectedModel) && pickerModels.isNotEmpty) {
        _selectedModel = pickerModels.first;
        await prefs.setSelectedModel(_selectedModel);
      }
    }
    await prefs.setEnabledChatModels(_enabledModels.toList()..sort());
    notifyListeners();
  }

  static String _providerOfModel(String model) {
    final idx = model.indexOf(':');
    return idx > 0 ? model.substring(0, idx) : 'ollama';
  }

  Future<void> setAutoApprove(bool v) async {
    _autoApprove = v;
    await prefs.setAutoApprove(v);
    notifyListeners();
  }

  /// Set the per-session reasoning effort dial. No-ops when there is
  /// no active session (Welcome screen state — first user message
  /// will create one with the default `standard` effort, then this
  /// can be re-applied if desired).
  ///
  /// The value is persisted with the session JSON via `_persistCurrent`,
  /// not in `PreferencesService` — the dial is per-chat so different
  /// sessions can run at different levels (the model picker has the
  /// same shape).
  Future<void> setReasoningEffort(ReasoningEffort effort) async {
    if (_current == null) return;
    if (_current!.reasoningEffort == effort) return;
    _current!.reasoningEffort = effort;
    await _persistCurrent();
    notifyListeners();
  }

  /// Read-only accessor — returns the current session's effort or
  /// [ReasoningEffort.standard] when there is no session yet.
  ReasoningEffort get reasoningEffort =>
      _current?.reasoningEffort ?? ReasoningEffort.standard;

  /// True when the currently selected model accepts a real native
  /// reasoning param (Anthropic `thinking`, OpenAI `reasoning_effort`,
  /// Gemini `thinkingConfig`). False means the dial falls back to a
  /// system-prompt directive only — useful UI hint so the composer
  /// pill can flag "prompt-only" mode honestly instead of pretending
  /// the toggle does something it doesn't.
  bool get reasoningEffortIsNativeForCurrentModel {
    final (provider, rawModel) = _splitModel(_selectedModel);
    return ReasoningEffortHelper.modelSupportsNative(
      provider: provider,
      rawModel: rawModel,
    );
  }

  void toggleTool(String id) {
    if (_enabledTools.contains(id)) {
      _enabledTools.remove(id);
    } else {
      _enabledTools.add(id);
    }
    notifyListeners();
  }

  /// Mount [path] as the active workspace for chat purposes. Saves
  /// the previous workspace's tab state, then loads (or seeds) the
  /// new workspace's tabs.
  ///
  /// Behaviour matrix for [path]:
  ///
  /// 1. Workspace has prior tab state (open tabs + current id) →
  ///    load and restore it. Stale tab ids (sessions deleted on
  ///    disk) are filtered out the same way `init()` does.
  ///
  /// 2. Workspace has no prior tab state but has *sessions in the
  ///    archive* matching this workspace's `workspacePath` → open
  ///    the most-recent matching session as the only tab. (User
  ///    closed all tabs last time but their chats still belong to
  ///    this project; they'd want to see them.)
  ///
  /// 3. Workspace is brand-new (no tabs, no sessions) → seed a
  ///    fresh empty session via `newSession(workspacePath: path)`.
  ///    User lands on a clean tab tied to this project.
  ///
  /// In all branches the tools registry is reloaded for the new
  /// workspace (`reloadExternalTools(path)`) — the chat is now
  /// scoped to a project, so the project's `.lumen/tools/` dir
  /// should be honoured. Idempotent: a same-workspace rebind is a
  /// no-op (e.g. AppState.setDirectory called twice with the same
  /// path doesn't waste a session.)
  Future<void> bindToWorkspace(String? path) async {
    if (_currentWorkspace == path) return;
    // Save the OUTGOING workspace's state under its own key before
    // we switch — otherwise it's lost.
    await _persistOpenTabs();
    if (_current != null) {
      await _persistCurrentSessionId(_current!.id);
    }

    _currentWorkspace = path;

    // Load this workspace's persisted tabs + active session.
    //
    // **Defensive filter** — drop any persisted tab id whose session
    // belongs to a *different* workspace. Per-workspace persistence
    // prevents this in normal flow, but legacy / pre-scoping data
    // could land cross-workspace ids in a bucket and we don't want
    // those to surface as tabs in the "wrong" project. Null
    // workspacePath (orphan chats from before the schema field
    // existed) are kept — the user adopted them by tabbing them.
    final wsTabs = await prefs.getOpenTabIdsForWorkspace(path);
    final byId = {for (final s in _sessions) s.id: s};
    bool tabBelongsHere(String id) {
      final s = byId[id];
      if (s == null) return false; // session gone from disk
      // When binding to a real workspace, drop tabs owned by a
      // different non-null workspace.
      if (path != null && s.workspacePath != null && s.workspacePath != path) {
        return false;
      }
      return true;
    }

    _openTabIds
      ..clear()
      ..addAll(wsTabs.where(tabBelongsHere));

    final wsCurrent = await prefs.getCurrentSessionIdForWorkspace(path);
    ChatSession? next;
    if (wsCurrent.isNotEmpty && tabBelongsHere(wsCurrent)) {
      next = await persistence.loadSession(wsCurrent);
      if (next != null && !_openTabIds.contains(next.id)) {
        _openTabIds.add(next.id);
      }
    }

    // Branch 2 / 3: no tabs persisted → look for archived sessions
    // matching this workspace, else seed a fresh tab. We DON'T
    // auto-mount every matching archived session (could be dozens
    // for an old project) — just the most recent. The rest stay
    // accessible via the history menu.
    if (_openTabIds.isEmpty) {
      final matching = _sessions.where((s) => s.workspacePath == path).toList();
      if (matching.isNotEmpty) {
        // _sessions is already sorted updatedAt-desc by listSessions.
        next = matching.first;
        _openTabIds.add(next.id);
      } else {
        // newSession mutates _openTabIds, _current, _sessions, and
        // persists everything itself — let it do the work.
        await newSession(workspacePath: path);
        next = _current;
      }
    }

    _current = next;
    await _persistOpenTabs();
    if (_current != null) {
      await _persistCurrentSessionId(_current!.id);
    } else {
      await _persistCurrentSessionId('');
    }
    // Reload external tools for the new workspace's `.lumen/tools/`.
    await reloadExternalTools(path);
    notifyListeners();
  }

  // ---- session ops ----
  Future<void> newSession({String? workspacePath}) async {
    final s = ChatSession(
      id: persistence.generateId(),
      title: 'New chat',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
      workspacePath: workspacePath,
      model: _selectedModel,
      messages: [],
    );
    _current = s;
    _sessions.insert(0, s);
    // New sessions always become a fresh tab on the right end of the
    // strip — same convention as a browser opening a new tab.
    _openTabIds.add(s.id);
    await persistence.saveSession(s);
    await _persistCurrentSessionId(s.id);
    await _persistOpenTabs();
    notifyListeners();
  }

  Future<void> openSession(String id) async {
    final loaded = await persistence.loadSession(id);
    if (loaded != null) {
      _current = loaded;
      // Ensure the session has a tab — opening from history (or any
      // non-tab path) should bring it into the tab strip so the user
      // can switch back to it without re-opening.
      if (!_openTabIds.contains(id)) {
        _openTabIds.add(id);
      }
      await _persistCurrentSessionId(id);
      await _persistOpenTabs();
      notifyListeners();
    }
  }

  Future<void> deleteSession(String id) async {
    await persistence.deleteSession(id);
    _sessions.removeWhere((s) => s.id == id);
    _openTabIds.remove(id);
    if (_current?.id == id) {
      _current = _openTabIds.isNotEmpty
          ? _sessions.firstWhere(
              (s) => s.id == _openTabIds.last,
              orElse: () => _sessions.isNotEmpty ? _sessions.first : _current!,
            )
          : (_sessions.isNotEmpty ? _sessions.first : null);
      await _persistCurrentSessionId(_current?.id ?? '');
    }
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Close a tab without deleting the underlying chat. The session
  /// stays on disk and can be re-opened from the history dropdown.
  /// If the closed tab was the active one, focus moves to the
  /// neighbour to its right (or left if it was the last tab). If all
  /// tabs are closed `_current` becomes null — the next user message
  /// auto-creates a fresh session via `sendMessage` /
  /// `appendUserText`, so this is a safe terminal state.
  Future<void> closeTab(String id) async {
    final closingActive = _current?.id == id;
    final idx = _openTabIds.indexOf(id);
    if (idx < 0) return;
    _openTabIds.removeAt(idx);

    if (closingActive) {
      if (_openTabIds.isEmpty) {
        _current = null;
        await _persistCurrentSessionId('');
      } else {
        // Prefer the tab to the right of the one we closed; fall back
        // to the new last tab when we just closed the rightmost.
        final nextIdx = idx >= _openTabIds.length
            ? _openTabIds.length - 1
            : idx;
        final nextId = _openTabIds[nextIdx];
        final loaded = await persistence.loadSession(nextId);
        if (loaded != null) {
          _current = loaded;
          await _persistCurrentSessionId(nextId);
        }
      }
    }
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Close every open tab except [keepId]. The kept tab becomes the
  /// active one (loaded from disk if not already current). No-op if
  /// [keepId] isn't currently open. Bulk variant of `closeTab`: one
  /// persist + one notify rather than N.
  Future<void> closeOtherTabs(String keepId) async {
    if (!_openTabIds.contains(keepId)) return;
    if (_openTabIds.length <= 1) return;
    _openTabIds
      ..clear()
      ..add(keepId);
    if (_current?.id != keepId) {
      final loaded = await persistence.loadSession(keepId);
      if (loaded != null) {
        _current = loaded;
        await _persistCurrentSessionId(keepId);
      }
    }
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Close every tab to the right of [pivotId] in the strip. If the
  /// currently-active tab is among the removed ones, focus snaps back
  /// to [pivotId]. No-op if [pivotId] is the last tab or not present.
  Future<void> closeTabsToRight(String pivotId) async {
    final pivotIdx = _openTabIds.indexOf(pivotId);
    if (pivotIdx < 0) return;
    if (pivotIdx >= _openTabIds.length - 1) return;
    final removed = _openTabIds.sublist(pivotIdx + 1);
    _openTabIds.removeRange(pivotIdx + 1, _openTabIds.length);
    if (_current != null && removed.contains(_current!.id)) {
      final loaded = await persistence.loadSession(pivotId);
      if (loaded != null) {
        _current = loaded;
        await _persistCurrentSessionId(pivotId);
      }
    }
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Close every open tab. Sessions are NOT deleted — they remain in
  /// `_sessions` (and therefore the history dropdown). `_current`
  /// becomes null; the next user message will auto-seed a new session
  /// the same way it does after the last tab is closed via `closeTab`.
  Future<void> closeAllTabs() async {
    if (_openTabIds.isEmpty) return;
    _openTabIds.clear();
    _current = null;
    await _persistCurrentSessionId('');
    await _persistOpenTabs();
    notifyListeners();
  }

  /// Drag-to-reorder for the tab strip. Mirrors `ReorderableListView`'s
  /// `(oldIndex, newIndex)` contract.
  Future<void> reorderTab(int oldIndex, int newIndex) async {
    if (oldIndex < 0 || oldIndex >= _openTabIds.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= _openTabIds.length) return;
    final id = _openTabIds.removeAt(oldIndex);
    _openTabIds.insert(newIndex, id);
    await _persistOpenTabs();
    notifyListeners();
  }

  Future<void> renameSession(String id, String title) async {
    final s = _sessions.firstWhere((e) => e.id == id, orElse: () => _current!);
    s.title = title;
    s.updatedAt = DateTime.now();
    await persistence.saveSession(s);
    notifyListeners();
  }

  Future<void> clearCurrent() async {
    if (_current == null) return;
    _current!.messages.clear();
    _current!.updatedAt = DateTime.now();
    await persistence.saveSession(_current!);
    notifyListeners();
  }

  Future<void> _persistCurrent() async {
    if (_current == null) return;
    _current!.updatedAt = DateTime.now();
    await persistence.saveSession(_current!);
    final idx = _sessions.indexWhere((s) => s.id == _current!.id);
    if (idx >= 0) {
      _sessions[idx] = _current!;
      _sessions.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    }
  }

  // ---- attachments ----
  void addPendingImage(String base64) {
    _pendingImages.add(base64);
    notifyListeners();
  }

  void clearPendingImages() {
    _pendingImages.clear();
    notifyListeners();
  }

  void removePendingImageAt(int index) {
    if (index < 0 || index >= _pendingImages.length) return;
    _pendingImages.removeAt(index);
    notifyListeners();
  }

  bool addPendingReference(String path, {String? workspacePath}) {
    final type = FileSystemEntity.typeSync(path);
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      return false;
    }
    final normalizedPath = p.normalize(path);
    final normalizedWorkspace = workspacePath == null
        ? null
        : p.normalize(workspacePath);
    String? rel;
    if (normalizedWorkspace != null &&
        (p.equals(normalizedPath, normalizedWorkspace) ||
            p.isWithin(normalizedWorkspace, normalizedPath))) {
      rel = p
          .relative(normalizedPath, from: normalizedWorkspace)
          .replaceAll(r'\', '/');
      if (rel == '.') rel = p.basename(normalizedWorkspace);
    }
    final ref = ChatReference(
      path: normalizedPath,
      workspaceRelativePath: rel,
      kind: type == FileSystemEntityType.directory
          ? ChatReferenceKind.folder
          : ChatReferenceKind.file,
    );
    final exists = _pendingReferences.any(
      (r) => p.equals(p.normalize(r.path), normalizedPath),
    );
    if (!exists) {
      _pendingReferences.add(ref);
    }
    _pendingComposerInsertions.add(ref.inlineToken);
    notifyListeners();
    return true;
  }

  void removePendingReference(ChatReference ref) {
    final before = _pendingReferences.length;
    _pendingReferences.removeWhere((r) => p.equals(r.path, ref.path));
    if (_pendingReferences.length != before) notifyListeners();
  }

  void clearPendingReferences() {
    _pendingReferences.clear();
    notifyListeners();
  }

  // ---- message ops ----
  Future<void> editMessage(int index, String newContent) async {
    if (_current == null) return;
    if (index < 0 || index >= _current!.messages.length) return;
    final old = _current!.messages[index];
    _current!.messages[index] = PersistedMessage(
      id: old.id,
      role: old.role,
      content: newContent,
      imagesBase64: old.imagesBase64,
      references: old.references,
      timestamp: old.timestamp,
    );
    await _persistCurrent();
    notifyListeners();
  }

  Future<void> deleteMessage(int index) async {
    if (_current == null) return;
    if (index < 0 || index >= _current!.messages.length) return;
    _current!.messages.removeAt(index);
    await _persistCurrent();
    notifyListeners();
  }

  Future<void> appendUserText(String text) async {
    if (_current == null) await newSession();
    _current!.messages.add(PersistedMessage(role: 'user', content: text));
    await _persistCurrent();
    notifyListeners();
  }

  // ---- approval flow ----

  /// Gate a tool call. Returns true if the user (or a stored
  /// preference) approves, false if denied / cancelled.
  ///
  /// Order of checks:
  /// 1. Global `_autoApprove` — master "trust everything" switch.
  /// 2. Per-tool `_autoApprovedTools` — populated by clicking
  ///    "Allow always" on a previous prompt of this tool.
  /// 3. Otherwise: surface an `ApprovalStrip` (chrome dock above
  ///    the chat input) and await the user.
  Future<bool> _approveCommand(
    String toolId,
    String label,
    String detail,
  ) async {
    // **Audit trail** — when an approval gate is bypassed silently
    // (master `_autoApprove` flag OR per-tool blanket via
    // `_autoApprovedTools`), record it so the user can see what
    // ran without their consent. The list is exposed on the
    // controller as `recentSilentApprovals` and consumed by a
    // chat-side toast / settings panel — addresses the bug report
    // where `npm install` ran "without auto-approve being on": the
    // user had clicked "Always run" on a previous RUN_CMD and
    // forgot. Now they can SEE that the silent approval is still
    // in effect.
    if (_autoApprove) {
      _recordSilentApproval(toolId, detail, reason: 'auto-approve all');
      return true;
    }
    if (_autoApprovedTools.contains(toolId)) {
      _recordSilentApproval(toolId, detail, reason: 'always-allow this tool');
      return true;
    }
    final c = Completer<bool>();
    _pendingApproval = PendingApproval(
      toolId: toolId,
      label: label,
      detail: detail,
      completer: c,
    );
    notifyListeners();
    final result = await c.future;
    _pendingApproval = null;
    notifyListeners();
    return result;
  }

  /// Append a silent-approval entry to the ring buffer, evicting the
  /// oldest if we'd exceed the cap. Notifies listeners so any UI
  /// surface that displays this audit trail can update.
  void _recordSilentApproval(
    String toolId,
    String detail, {
    required String reason,
  }) {
    _silentApprovals.insert(
      0,
      SilentApproval(
        toolId: toolId,
        detail: detail,
        reason: reason,
        when: DateTime.now(),
      ),
    );
    while (_silentApprovals.length > _silentApprovalCap) {
      _silentApprovals.removeLast();
    }
    notifyListeners();
  }

  void respondToApproval(bool approved) {
    final p = _pendingApproval;
    if (p == null) return;
    if (!p.completer.isCompleted) p.completer.complete(approved);
  }

  /// Add or remove a tool from the per-tool blanket-approval set.
  /// Called from the approval card's "Allow always" button (add) and
  /// from Settings (remove). Persisted immediately.
  Future<void> setToolAutoApproved(String toolId, bool approved) async {
    final changed = approved
        ? _autoApprovedTools.add(toolId)
        : _autoApprovedTools.remove(toolId);
    if (!changed) return;
    await prefs.setAutoApprovedTools(_autoApprovedTools.toList());
    notifyListeners();
  }

  /// Wipe every per-tool approval at once. Settings exposes this as
  /// a "Clear all" button so the user doesn't have to revoke
  /// individually after they've granted blanket approval to several.
  Future<void> clearAutoApprovedTools() async {
    if (_autoApprovedTools.isEmpty) return;
    _autoApprovedTools.clear();
    await prefs.setAutoApprovedTools(const <String>[]);
    notifyListeners();
  }

  // ---- generation ----
  void cancelGeneration() {
    _cancelToken?.cancel();
    if (_pendingApproval != null && !_pendingApproval!.completer.isCompleted) {
      _pendingApproval!.completer.complete(false);
    }
  }

  /// Remove a queued prompt without running it. Idempotent — silently
  /// no-ops if the id isn't present anymore (already drained, or
  /// already removed). Notifies on every attempt so the UI redraws.
  void removeQueuedPrompt(String id) {
    final before = _promptQueue.length;
    _promptQueue.removeWhere((q) => q.id == id);
    if (_promptQueue.length != before) notifyListeners();
  }

  /// Skip the queue order: cancel the in-flight generation, drop
  /// every queued entry that was ahead of [id], and run [id] next.
  /// Used by the "Send now" button on a queued prompt entry.
  ///
  /// We don't *immediately* dispatch — the cancellation has to
  /// propagate through the streaming loop and the `finally{}` drains
  /// whichever queue head is present at that moment. So the strategy
  /// is: reorder the queue so [id] is at index 0, drop everything
  /// before it, then cancel. The drain step (in `_drainPromptQueue`)
  /// will pick [id] up.
  void sendQueuedPromptNow(String id) {
    final idx = _promptQueue.indexWhere((q) => q.id == id);
    if (idx < 0) return;
    final entry = _promptQueue.removeAt(idx);
    // Drop anything that was queued ahead of the now-promoted entry —
    // the user explicitly asked for THIS one to run next, not the
    // stale ones in front of it. The dropped ones can be re-typed
    // if the user still wants them.
    _promptQueue.removeRange(0, 0); // no-op, kept for clarity
    _promptQueue.insert(0, entry);
    if (_isGenerating) {
      cancelGeneration();
    } else {
      // Idle path: drain ourselves (the in-flight branch flows
      // through the existing finally{} drain).
      unawaited(_drainPromptQueue());
    }
    notifyListeners();
  }

  /// Re-run the most-recent failed turn. Intended for the Retry chip
  /// on a provider-error card.
  ///
  /// Mechanic: we identify the *failed assistant message* (the last
  /// one in the session that's marked as ending in a recognisable
  /// provider error) and delete it. The user message immediately
  /// before it stays — the model will see it again as the latest
  /// user turn. We then run the same generation loop. No new user
  /// message is appended.
  ///
  /// [workspacePath] / [activeFilePath] / [openFilePaths] are
  /// re-supplied by the caller (the chat panel reads them from
  /// `AppState`) — we don't try to reuse the cached
  /// `_lastWorkspacePath` here because the user may have switched
  /// workspaces between the failure and the retry click.
  Future<void> retryLastTurn({
    String? workspacePath,
    String? activeFilePath,
    List<String>? openFilePaths,
  }) async {
    if (_isGenerating || _current == null) return;
    final session = _current!;
    if (session.messages.isEmpty) return;
    // Walk backward to the last assistant message and check it
    // ended in a marker. If it did, drop it.
    int trailingAssistantIdx = -1;
    for (int i = session.messages.length - 1; i >= 0; i--) {
      if (session.messages[i].role == 'assistant') {
        trailingAssistantIdx = i;
        break;
      }
    }
    if (trailingAssistantIdx >= 0) {
      session.messages.removeAt(trailingAssistantIdx);
      await _persistCurrent();
    }
    // Re-run the generation loop. No new user message — the existing
    // one becomes the latest turn from the model's perspective.
    await _runGenerationLoop(
      workspacePath: workspacePath,
      activeFilePath: activeFilePath,
      openFilePaths: openFilePaths,
    );
  }

  Future<void> sendMessage(
    String text, {
    String? workspacePath,
    String? activeFilePath,
    List<String>? openFilePaths,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty &&
        _pendingImages.isEmpty &&
        _pendingReferences.isEmpty) {
      return;
    }

    // ── send-while-generating: enqueue ────────────────────────────
    // Earlier this was a silent no-op which felt broken — users type
    // follow-ups during a long generation expecting them to be
    // remembered, not dropped. Now we capture the prompt + its
    // workspace context as a `QueuedPrompt`; the chat panel renders
    // an above-input strip with delete / send-now controls; the
    // controller drains the head when the current turn finishes.
    if (_isGenerating) {
      _enqueuePrompt(
        text: trimmed,
        images: List<String>.from(_pendingImages),
        references: List<ChatReference>.from(_pendingReferences),
        workspacePath: workspacePath,
        activeFilePath: activeFilePath,
        openFilePaths: openFilePaths ?? const [],
      );
      _pendingImages.clear();
      _pendingReferences.clear();
      notifyListeners();
      return;
    }

    if (_current == null) {
      await newSession(workspacePath: workspacePath);
    }
    final session = _current!;
    if (session.workspacePath == null && workspacePath != null) {
      session.workspacePath = workspacePath;
    }
    // Cheap (cached) on every message; only re-walks disk when the
    // workspace actually changes.
    await reloadExternalTools(workspacePath);

    final attachedImages = List<String>.from(_pendingImages);
    final attachedReferences = List<ChatReference>.from(_pendingReferences);
    _pendingImages.clear();
    _pendingReferences.clear();

    final userMsg = PersistedMessage(
      role: 'user',
      content: trimmed,
      imagesBase64: attachedImages,
      references: attachedReferences,
    );
    session.messages.add(userMsg);
    session.updatedAt = DateTime.now();

    if (session.messages.length == 1) {
      session.title = persistence.deriveTitleFromMessage(trimmed);
      unawaited(_summarizeTitleInBackground(session, trimmed));
    }
    await _persistCurrent();

    // Cache the user message for the retry chip — workspace context
    // is re-read from AppState on retry, no need to cache it here.
    _lastUserMessageForRetry = userMsg;

    await _runGenerationLoop(
      workspacePath: workspacePath,
      activeFilePath: activeFilePath,
      openFilePaths: openFilePaths,
    );
  }

  /// Enqueue a user prompt that arrived while a generation was in
  /// flight. Returns the assigned id so the UI can target the entry
  /// for delete / send-now actions.
  String _enqueuePrompt({
    required String text,
    required List<String> images,
    required List<ChatReference> references,
    required String? workspacePath,
    required String? activeFilePath,
    required List<String> openFilePaths,
  }) {
    final id = 'q_${++_nextQueueId}';
    _promptQueue.add(
      QueuedPrompt(
        id: id,
        text: text,
        imagesBase64: List.unmodifiable(images),
        references: List.unmodifiable(references),
        workspacePath: workspacePath,
        activeFilePath: activeFilePath,
        openFilePaths: List.unmodifiable(openFilePaths),
        queuedAt: DateTime.now(),
      ),
    );
    return id;
  }

  /// Drain the head of the queue if there is one and we're idle.
  /// Called from `_runGenerationLoop`'s `finally{}` and from
  /// `sendQueuedPromptNow` when the user reorders into idle.
  ///
  /// Re-uses the public `sendMessage` so the queued entry walks the
  /// same path as a freshly-typed prompt — no special-cased branch
  /// for queued vs. live, fewer surprises.
  Future<void> _drainPromptQueue() async {
    if (_isGenerating) return;
    if (_promptQueue.isEmpty) return;
    final next = _promptQueue.removeAt(0);
    notifyListeners();
    // Re-prime pending images from the snapshot — `sendMessage`
    // expects to read `_pendingImages` for attachment.
    _pendingImages
      ..clear()
      ..addAll(next.imagesBase64);
    _pendingReferences
      ..clear()
      ..addAll(next.references);
    await sendMessage(
      next.text,
      workspacePath: next.workspacePath,
      activeFilePath: next.activeFilePath,
      openFilePaths: next.openFilePaths,
    );
  }

  String _contentWithReferences(PersistedMessage message) {
    if (message.references.isEmpty) return message.content;
    final buffer = StringBuffer(message.content.trim());
    if (buffer.isNotEmpty) buffer.writeln('\n');
    buffer.writeln('Attached workspace references:');
    for (final ref in message.references) {
      final kind = ref.kind == ChatReferenceKind.folder ? 'folder' : 'file';
      final label = ref.workspaceRelativePath ?? ref.path;
      buffer.writeln('- [$kind] $label');
      buffer.writeln('  absolute path: ${ref.path}');
    }
    buffer.writeln(
      'Use these as relevant context. Inspect them with file tools before making claims about their contents.',
    );
    return buffer.toString().trimRight();
  }

  /// Run the streaming generation loop against the current
  /// `_current` session. Caller is responsible for ensuring the
  /// most-recent message in the session is the user prompt to
  /// respond to (either freshly added by `sendMessage`, or the
  /// pre-existing last-user-message in the case of `retryLastTurn`).
  Future<void> _runGenerationLoop({
    String? workspacePath,
    String? activeFilePath,
    List<String>? openFilePaths,
  }) async {
    if (_current == null) return;
    final session = _current!;
    if (_isGenerating) return;

    _isGenerating = true;
    _cancelToken = CancellationToken();
    _generationStartedAt = DateTime.now();
    _lastChunkAt = DateTime.now();
    notifyListeners();

    // Recover the latest user message + its trimmed text — used for
    // the tasks log, time-gap detection, etc.
    PersistedMessage? latestUser;
    for (int i = session.messages.length - 1; i >= 0; i--) {
      if (session.messages[i].role == 'user') {
        latestUser = session.messages[i];
        break;
      }
    }
    final trimmed = latestUser?.content.trim() ?? '';

    // Throttle timer for live streaming notifyListeners — hoisted
    // out of the try{} so the catch/finally blocks can null it out
    // safely if generation explodes mid-stream. See updateLive()
    // below for the full throttling rationale.
    Timer? throttleTimer;

    // Hoisted out of try{} so the finally{} block can hand it to
    // `_recentEdits.noteTurnComplete` after the turn finishes (or
    // partially finishes — even a cancelled turn produced timeline
    // entries we want to highlight).
    String? capturedTurnId;

    try {
      String workspaceContext = 'No workspace open.';
      if (workspacePath != null) {
        try {
          final dir = Directory(workspacePath);
          final entries = dir.listSync().take(50).toList();
          entries.sort((a, b) {
            final aDir = a is Directory;
            final bDir = b is Directory;
            if (aDir != bDir) return aDir ? -1 : 1;
            return a.path
                .split(Platform.pathSeparator)
                .last
                .toLowerCase()
                .compareTo(
                  b.path.split(Platform.pathSeparator).last.toLowerCase(),
                );
          });
          final names = entries
              .map(
                (e) =>
                    '${e is Directory ? "[DIR] " : ""}${e.path.split(Platform.pathSeparator).last}',
              )
              .join('\n  ');
          final ctxBuf = StringBuffer();
          ctxBuf.writeln('Workspace: $workspacePath');
          ctxBuf.writeln('Root contents:\n  $names');
          if (activeFilePath != null) {
            ctxBuf.writeln(
              'Active file (user is currently editing): $activeFilePath',
            );
          }
          if (openFilePaths != null && openFilePaths.isNotEmpty) {
            ctxBuf.writeln(
              'Open files in editor tabs: ${openFilePaths.join(', ')}',
            );
          }
          workspaceContext = ctxBuf.toString().trimRight();
        } catch (e) {
          workspaceContext = 'Error reading workspace: $e';
        }
      }

      final compiledRules = await rules.compileForPrompt(workspacePath);
      // Reload + compile workspace skills (`.lumen/skills/*.md`) for
      // injection under `## Workspace skills`. Best-effort: a parse
      // failure logs and yields an empty block.
      String compiledSkills = '';
      if (skills != null) {
        try {
          await skills!.reload(workspacePath);
          final enabled = await prefs.getEnabledSkillIds();
          compiledSkills = skills!.compileForPrompt(enabledIds: enabled);
        } catch (e) {
          debugPrint('skills compileForPrompt failed: $e');
        }
      }
      final toolDocs = ToolRegistry.all
          .where((t) => _enabledTools.contains(t.id))
          .map(
            (t) =>
                '- ${t.name}: ${t.description}\n  Syntax:\n    ${t.syntaxExample}',
          )
          .join('\n');
      final allowOutsideWorkspaceWrites = await prefs
          .getAgentAllowOutsideWorkspaceWrites();

      // ─────────────────────────────────────────────────────────
      //   Conversation continuity — anti "redo previous prompt"
      //   bias.
      // ─────────────────────────────────────────────────────────
      // Two real-world bug reports drove this:
      //   1. User asks for X, agent does X, conversation ends. Hours
      //      later they say "hi" and the model picks up X again from
      //      scratch because the long history makes it look unfinished.
      //   2. User asks a follow-up like "what was that file again?"
      //      and the model treats it as "rebuild the file" because
      //      the conversation context is dominated by the original
      //      request.
      //
      // Three layered defences:
      //   A. **Continuity rule** in the system prompt itself —
      //      explicit "messages above the latest user message are
      //      HISTORY" instruction.
      //   B. **Tasks log injection** — pull the per-chat
      //      `<id>.tasks.md` into the prompt (last 30 entries) so
      //      the model has a concrete "what's already done" list.
      //   C. **Time-gap escalation** — if the most recent prior
      //      assistant message is more than 30 minutes old (relative
      //      to *now*, not the just-added user msg), prepend a
      //      louder "this conversation resumed after a long pause"
      //      note. Models are dramatically worse at honouring (A)
      //      alone after a session resume.
      String tasksLog = '';
      try {
        final raw = await persistence.loadTasks(session.id);
        if (raw.trim().isNotEmpty) {
          // Trim to the last ~30 task lines so we don't blow tokens
          // on a chat that's been going for weeks. Header / comment
          // lines are filtered out — only the actual `- [x] ...`
          // entries are useful in-prompt.
          final entries = raw
              .split('\n')
              .where((line) => line.startsWith('- ['))
              .toList();
          final tail = entries.length > 30
              ? entries.sublist(entries.length - 30)
              : entries;
          if (tail.isNotEmpty) {
            tasksLog = tail.join('\n');
          }
        }
      } catch (_) {
        /* tasks read is best-effort */
      }

      // Time-gap detection: previous assistant message age. We look
      // at the most recent assistant message that exists BEFORE the
      // current latest-user-message — its age vs. now signals a
      // resumed-after-pause turn. Walking backward from the end
      // works for both the sendMessage path (user msg was just
      // appended) and the retryLastTurn path (failed assistant got
      // removed; user msg now sits at the tail with the prior
      // assistant earlier in history).
      bool resumedAfterPause = false;
      for (int j = session.messages.length - 2; j >= 0; j--) {
        final m = session.messages[j];
        if (m.role == 'assistant') {
          final age = DateTime.now().difference(m.timestamp);
          resumedAfterPause = age > const Duration(minutes: 30);
          break;
        }
      }

      final continuityBlock = '''
## Conversation continuity (read this first)
Messages above the most recent user message are HISTORY. Tools have
already executed; files have already been written; work has already
been done in those turns. Treat that history as **completed**.

- Only respond to the LATEST user message.
- If the latest message is a greeting, acknowledgement, or unclear,
  ASK what the user wants to do next. Do NOT re-execute prior
  requests "to be helpful".
- Re-attempt prior work ONLY when the user explicitly asks
  ("redo X", "try again", "the file is missing — rebuild it").
${resumedAfterPause ? '- **Session resumed after a long pause** — the previous reply was sent over 30 minutes ago. Be especially careful not to pick up where the prior turn left off. The user is starting a new ask, even if it looks brief.\n' : ''}${tasksLog.isNotEmpty ? '\n### Already completed in this conversation\nDo NOT redo any of these unless the user explicitly asks. They are HISTORICAL.\n\n$tasksLog\n' : ''}''';

      // **Reasoning effort prompt fallback** — when the active model
      // doesn't accept a native reasoning param (Ollama, older OpenAI
      // chat models, Claude Haiku, Gemini 2.0), inject a system-prompt
      // directive instead. When native IS supported, we trust the API
      // knob and skip the suffix to avoid double-incentivising
      // verbosity (the model is already thinking harder; nagging it
      // into being thorough on top of that just burns tokens).
      final effort = session.reasoningEffort;
      final (selectedProvider, selectedRawModel) = _splitModel(_selectedModel);
      final effortIsNative = ReasoningEffortHelper.modelSupportsNative(
        provider: selectedProvider,
        rawModel: selectedRawModel,
      );
      final effortBlock = (!effortIsNative && effort != ReasoningEffort.off)
          ? '${ReasoningEffortHelper.promptDirectiveFor(effort)}\n'
          : '';

      final systemPrompt =
          '''You are Lumen, the AI coding assistant built into the Lumen IDE.
You are an expert software engineer working as the user's pair programmer.
Not a Q&A bot — propose plans, execute, verify, and report back.
$continuityBlock
$effortBlock## Workspace
Working directory: ${workspacePath ?? 'None'}
$workspaceContext

## Workspace conventions
This project may follow Lumen IDE conventions. Check whether these dirs
exist (TREE on the workspace root) before assuming they don't:
- `.lumen/rules.md` — workspace-specific rules. Already merged into
  the "Project Rules" section below if present; do NOT re-read it.
- `.lumen/tools/*.json` — external agent tools auto-loaded into your
  toolbox; you'll see them in the tool list above without doing anything.
- `.lumen/skills/*.md` — instruction-based **skills** (design system
  guides, code conventions, domain knowledge). Already injected into
  the "Workspace skills" section below if present; do NOT re-read
  them. Skills are READ-ONLY context — do not try to invoke a skill
  with `<<<>>>`. To CREATE a new skill, write a markdown file with
  YAML frontmatter (`---\nname:\ntrigger:\n---`) into
  `.lumen/skills/`.
- `.agents/knowledgebase.md` — concise project knowledge maintained
  by you and previous agents. READ it when starting any non-trivial
  task if it exists. If it is missing and the task reveals useful
  durable context, CREATE it. UPDATE it after big completions
  (architecture shifts, new conventions, gotchas worth remembering).
  Keep entries short, practical, and agent-oriented: facts future
  agents need, no narrative fluff or changelog noise.
- `.agents/master_development_plan.md` — long-term roadmap, if present.
- `.agents/remaining.md` — outstanding TODOs the user is tracking.
For any non-trivial task, your first move on a fresh chat is usually
TREE on `.agents/` and `.lumen/` (when they exist) to load context.
The user expects you to be aware of accumulated project context, not
start from zero each turn.

## Workspace write boundary
${allowOutsideWorkspaceWrites ? 'The user has allowed built-in file mutation tools to write outside the active workspace when they explicitly target an absolute or parent-traversal path. Still prefer workspace-local edits unless the user asks otherwise.' : 'Built-in file mutation tools are configured to reject writes outside the active workspace. You may read outside the workspace for context, but do not create, edit, move, append, or delete files outside the workspace. If you need to do that, ask the user to enable Settings → Rules → Allow agent writes outside workspace for the task.'}

## Your tools
To use a tool, output its EXACT syntax in your response. You will receive
the tool's output as feedback in the next message and can continue from there.
You may chain multiple tool calls in a single response. You have up to
$maxIters iterations of tool use per request.

$toolDocs

## How to work
1. **Explore before editing.** When the user asks about code, errors, or
   anything workspace-related, examine relevant files first. Use TREE for
   structure, GLOB / FIND_FILE to locate, READ_FILE_RANGE for big-file
   slices (cheaper than full READ_FILE), SEARCH_TEXT for usages. Never
   guess file paths or contents — look them up.
2. **Surgical edits.** Prefer EDIT_FILE over CREATE_FILE for changes to
   existing files. When you have several edits to the SAME file, batch
   them with MULTI_EDIT — atomic, fewer round trips, no partial state.
   Only use CREATE_FILE for new files or full rewrites.
3. **Refactor safely.** Use MOVE_FILE for renames / relocations.
   Update import sites afterward (SEARCH_TEXT for the old name).
4. **Verify changes.** After non-trivial edits use GIT_STATUS to see
   exactly what touched the working tree, GIT_DIFF to inspect the
   actual changes. READ_FILE the result if a critical edit needs
   confirming.
5. **Be proactive.** If you notice related issues (unused imports,
   inconsistent naming, missing error handling) while working on the
   user's request, mention them and offer to fix — don't silently
   leave them or surprise-fix them.
6. **Don't apologise** about inability to do things. You have powerful
   tools. Use them.
7. **Stay responsive.** Stream a short prose progress line BEFORE
   firing a tool call so the user can see what you're about to do.
   Don't open with a dozen tool calls in silence — that reads as
   "the model is stuck" even when it's working. Between tool
   iterations, write a one-line summary of what you got back before
   firing the next batch.

${compiledRules.isNotEmpty ? '## Project Rules (always follow)\n$compiledRules\n' : ''}${compiledSkills.isNotEmpty ? '\n$compiledSkills\n' : ''}''';

      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
      ];
      for (final m in session.messages) {
        final entry = <String, dynamic>{
          'role': m.role,
          'content': _contentWithReferences(m),
        };
        if (m.imagesBase64.isNotEmpty) {
          entry['images'] = m.imagesBase64;
        }
        apiMessages.add(entry);
      }

      // Hand the executor a TimelineRecorder when a workspace is
      // mounted so every file-touching agent op (CREATE_FILE,
      // EDIT_FILE, MULTI_EDIT, APPEND_FILE, MOVE_FILE, DELETE_FILE)
      // gets a journal entry tagged with the current chat context.
      // Read-only tools (READ_FILE, GLOB, GIT_DIFF, …) are
      // intentionally excluded inside the recorder; nothing to
      // capture.
      final tlRecorder = (timeline != null && timeline!.isReady)
          ? TimelineRecorder(timeline: timeline!, workspaceDir: workspacePath)
          : null;
      final allowOutsideWrites = await prefs
          .getAgentAllowOutsideWorkspaceWrites();
      final executor = ToolExecutor(
        workspaceDir: workspacePath,
        approver: _approveCommand,
        enabledTools: _enabledTools,
        recorder: tlRecorder,
        allowWritesOutsideWorkspace: allowOutsideWrites,
      );

      // Derive a stable `turnId` for this user request. Used to tag
      // every file revision the agent produces during the turn so
      // the next-step "click chat message → restore everything
      // since" feature can group them. `messageId` is set later,
      // once the live assistant placeholder is appended (see below
      // — `timeline?.setChatContext` runs there with the
      // placeholder's timestamp, then cleared in finally{}).
      final turnSeedTs =
          (latestUser?.timestamp ?? DateTime.now()).microsecondsSinceEpoch;
      final turnId =
          'turn_${turnSeedTs.toRadixString(36)}'
          '_${persistence.generateId().substring(0, 5)}';
      capturedTurnId = turnId;

      // Streaming generation loop.
      //
      // We add a single "live" assistant message up front and SWAP
      // it at the same index as chunks arrive from the provider.
      // (PersistedMessage is immutable by design — its `content`
      // field is final — so we replace the whole instance per
      // update rather than mutating in place.) Every swap
      // notifies listeners so the UI re-renders the message body
      // progressively (visible token-by-token output, like every
      // serious chat UI). After each iteration's stream completes,
      // we run the tool executor on the raw text — that step
      // rewrites tool-call syntax (`<<<EDIT_FILE: ...>>>`) into the
      // friendly placeholder strings (`*(Edited file: foo.dart)*`),
      // so the message momentarily shows raw tags during streaming
      // and then snaps to the cleaned-up version once the executor
      // finishes. Acceptable trade — the alternative is buffering
      // until done, which is exactly what we're getting away from.
      String aggregated = '';
      bool keepLooping = true;
      int i = 0;
      // Aggregated across all iterations of this user-turn so the
      // tasks.md entry can summarise everything the model touched
      // in one line, regardless of how many tool-feedback rounds
      // it took. We dedupe by tool id (no point listing edit_file
      // 14 times if the model edited 14 different things in the
      // same file — the file path lands in the args list anyway).
      final firedAcrossTurn = <FiredTool>[];
      session.messages.add(PersistedMessage(role: 'assistant', content: ''));
      final liveIdx = session.messages.length - 1;
      // Mount the chat context onto the timeline. Every file
      // revision the executor produces while this is set will be
      // tagged with `(sessionId, turnId, messageId)`. Clearing
      // happens in `finally{}` so unrelated FS events landing
      // moments later do NOT inherit these IDs (the timeline
      // service docs that only agent-origin entries should carry
      // chat fields, and the recorder respects that).
      final liveMsgId = session.messages[liveIdx].id;
      timeline?.setChatContext(
        sessionId: session.id,
        turnId: turnId,
        messageId: liveMsgId,
      );
      // Wipe the previous turn's "recent edits" highlights *before* the
      // new turn writes anything — otherwise the editor briefly shows
      // last turn's tints alongside the new ones until noteTurnComplete
      // populates fresh data.
      _recentEdits?.clear();
      // Helper: swap the live message at `liveIdx` with one carrying
      // the latest content. Keeps timestamp stable so message
      // ordering doesn't drift mid-stream.
      //
      // **Throttled notify**: chat panels rebuild the entire
      // ListView on every notifyListeners. With streaming, chunks
      // arrive faster than 60Hz on a fast model — naively notifying
      // per chunk = 100+ full rebuilds per response = jank, dropped
      // frames, scroll fights. We throttle to ~30fps via
      // `_streamingNotifyTimer`: the live message swap is
      // unconditional, but `notifyListeners` only fires every 33ms
      // at most. A `forceNotify=true` flag is used at iteration
      // boundaries (executor snap, completion) to flush immediately.
      final originalTs = session.messages[liveIdx].timestamp;
      final liveId = session.messages[liveIdx].id;
      void updateLive(String content, {bool forceNotify = false}) {
        session.messages[liveIdx] = PersistedMessage(
          id: liveId,
          role: 'assistant',
          content: content,
          timestamp: originalTs,
        );
        if (forceNotify) {
          throttleTimer?.cancel();
          throttleTimer = null;
          notifyListeners();
          return;
        }
        // Already a notify pending — let it fire and pick up the
        // new content. Don't schedule another.
        if (throttleTimer != null && throttleTimer!.isActive) return;
        throttleTimer = Timer(const Duration(milliseconds: 33), () {
          throttleTimer = null;
          notifyListeners();
        });
      }

      notifyListeners();

      while (keepLooping && i < maxIters && !_cancelToken!.isCancelled) {
        i++;
        final iterBuf = StringBuffer();
        // **Runaway-loop guard** (set during streaming, checked
        // post-stream). Some models (nemotron-3-super:cloud has been
        // observed; deepseek-r1 sometimes too) get stuck in a
        // cycle producing the same 4-6 tool calls hundreds of times
        // in a single response. We can't trust that maxIters alone
        // protects us — the loop happens INSIDE one iteration's
        // stream — so we cap two ways:
        //   - Total `<<<` markers in this iteration. > 50 means at
        //     least 25 tool-call open/close brackets, which is way
        //     past anything a coherent task needs.
        //   - `<<<RUN_CMD:` count. > 12 means the model is just
        //     hammering the shell; no legitimate single-turn task
        //     needs that many.
        // Either trip → abort streaming, do NOT run the executor on
        // the iteration's content (the destructive tools never
        // fire), and end the conversation loop cleanly so the user
        // can re-prompt with corrective context.
        bool runawayDetected = false;
        int markerCount = 0;
        int runCmdCount = 0;
        // Stream this iteration's response into iterBuf, updating
        // the live message's content each chunk.
        await for (final chunk in _generateChatStream(
          apiMessages,
          model: _selectedModel,
          token: _cancelToken,
          effort: effort,
        )) {
          if (_cancelToken!.isCancelled) break;
          iterBuf.write(chunk);
          // Stall detector: refresh the last-chunk timestamp so the
          // chat panel can read `silenceDuration` and surface a
          // "model has been silent for X seconds" badge. Throttling
          // here is unnecessary — `DateTime.now()` is cheap, and the
          // UI ticker already runs at 1Hz so finer granularity
          // wouldn't be visible anyway.
          _lastChunkAt = DateTime.now();

          // Cheap incremental counters — count occurrences in the
          // chunk, not in the whole buffer (which would be
          // quadratic across the stream). Safe because `<<<` and
          // `<<<RUN_CMD:` cannot span chunk boundaries in
          // practice (HTTP chunks are >= 1KB; markers are <= 14B).
          markerCount += '<<<'.allMatches(chunk).length;
          runCmdCount += '<<<RUN_CMD:'.allMatches(chunk).length;
          if (markerCount > 50 || runCmdCount > 12) {
            runawayDetected = true;
            break; // breaks await-for; the async generator's
            // finally{} closes the http client.
          }

          // The live message shows previous-iterations aggregated +
          // current iteration's running buffer, separated by a
          // blank line. Matches the post-loop formatting below.
          final draft = aggregated.isEmpty
              ? iterBuf.toString()
              : '$aggregated\n\n${iterBuf.toString()}';
          updateLive(draft);
        }
        if (_cancelToken!.isCancelled) {
          aggregated += '${aggregated.isEmpty ? '' : '\n\n'}_(stopped)_';
          updateLive(aggregated, forceNotify: true);
          break;
        }
        if (runawayDetected) {
          // Don't run the executor — the iteration's content is a
          // tool-spam loop; we've seen RUN_CMD repeated 12+ times
          // or `<<<` 50+ times. Append a clear notice so the user
          // understands what happened and end the conversation
          // (the model can't recover from this on its own —
          // re-feeding it the loop just reinforces it).
          if (aggregated.isNotEmpty) aggregated += '\n\n';
          aggregated +=
              '_(loop detected — the model started repeating tool '
              'calls (`<<<RUN_CMD:` $runCmdCount× / `<<<` $markerCount×). '
              'Generation aborted before any of this iteration\'s tools '
              'ran. Try a smaller scope, a different model, or a '
              'follow-up like "stop trying to recreate flask_app, the '
              'directory already exists".)_';
          updateLive(aggregated, forceNotify: true);
          break;
        }
        final raw = iterBuf.toString();
        // Run the executor on the raw text. `processedResponse` has
        // tool-call syntax rewritten to friendly placeholders.
        final pass = await executor.run(raw);
        firedAcrossTurn.addAll(pass.firedTools);
        if (aggregated.isNotEmpty) aggregated += '\n\n';
        aggregated += pass.processedResponse.trim();
        // Snap the live message to the cleaned-up version. Force
        // notify so the executor's "raw → friendly" rewrite is
        // visible immediately, not on the next throttle tick.
        updateLive(aggregated, forceNotify: true);

        if (pass.hasToolCalls) {
          // For the model's history, send the RAW (unprocessed)
          // assistant text — the model needs to see its own tool
          // calls verbatim so the next turn's context lines up.
          apiMessages.add({'role': 'assistant', 'content': raw});
          final feedback = <String, dynamic>{
            'role': 'user',
            'content': 'Tool Feedback:\n${pass.toolFeedback}',
          };
          // Tools (currently SNAPSHOT_URL) can hand binary content
          // forward through the executor. Forwarding it on the user
          // feedback turn is what the multimodal model will see.
          if (pass.imageAttachments.isNotEmpty) {
            feedback['images'] = pass.imageAttachments;
          }
          apiMessages.add(feedback);
        } else {
          keepLooping = false;
        }
      }

      // The live message IS the final message — no separate add at
      // the end (was the pre-streaming behaviour). Just persist.
      // Cancel any pending throttle tick so we don't fire after
      // the generating flag has flipped (would render once with a
      // stale "still streaming" indicator visible).
      throttleTimer?.cancel();
      throttleTimer = null;

      // ── provider-error rewriting ─────────────────────────────────
      // If the turn ended with a recognisable provider failure
      // (Ollama 503 overloaded, Anthropic 529 rate limit, network
      // exception, …) and no real tool work happened, swap the raw
      // error text for a structured `<!-- LUMEN_ERR -->` marker.
      // The chat panel parses that into a friendly card with a
      // Retry chip via `parseChatSegments` /  `ProviderErrorCard`.
      // Skipped when a tool fired this turn (rare but possible for
      // a partial success; in that case we want the prose visible
      // for context, the retry chip would lose tool-side state).
      if (!_cancelToken!.isCancelled && firedAcrossTurn.isEmpty) {
        final err = ProviderError.tryParse(aggregated);
        if (err != null) {
          aggregated = ProviderError.marker(err);
          updateLive(aggregated, forceNotify: true);
        }
      }

      session.updatedAt = DateTime.now();
      await _persistCurrent();

      // Append a one-line entry to the chat's tasks.md so the next
      // turn can see what we just did. Best-effort: if the chat
      // didn't actually do anything (no tools, the response was a
      // pure-text Q&A or a clarifying question), skip the append —
      // a "nothing happened" line in the log is just noise.
      // Cancellation aborts the append too: a stopped turn isn't
      // "completed" by any reasonable definition.
      if (!_cancelToken!.isCancelled && firedAcrossTurn.isNotEmpty) {
        final entry = _formatTaskEntry(
          userText: trimmed,
          firedTools: firedAcrossTurn,
        );
        await persistence.appendTaskEntry(session.id, entry);
      }
    } catch (e) {
      throttleTimer?.cancel();
      throttleTimer = null;
      // Wrap the exception in the same provider-error marker the
      // happy path uses so the chat panel surfaces a Retry chip
      // instead of dumping the stack trace into a regular bubble.
      final err =
          ProviderError.tryParse('Error during generation: $e') ??
          ProviderError(
            kind: ProviderErrorKind.unknown,
            rawDetail: 'Error during generation: $e',
          );
      session.messages.add(
        PersistedMessage(role: 'assistant', content: ProviderError.marker(err)),
      );
      await _persistCurrent();
    } finally {
      _isGenerating = false;
      _cancelToken = null;
      _generationStartedAt = null;
      _lastChunkAt = null;
      // Always clear the timeline's chat context so anything that
      // writes to disk *after* the agent run completes (a FS event
      // arriving late, the user manually saving a file, etc.) is
      // NOT tagged with the just-finished turn's correlation IDs.
      // Capture per-file line ranges for the recent-edits overlay
      // BEFORE clearing chat context — `noteTurnComplete` queries
      // `timeline.entries` by `turnId`, so the IDs need to still be
      // recorded on the entries (they are; we're just freezing the
      // ambient context for *future* writes here).
      if (_recentEdits != null && timeline != null && capturedTurnId != null) {
        // Fire-and-forget: blob diffs are off the hot path, the editor
        // overlay listens to the tracker so it'll repaint when ready.
        unawaited(_recentEdits.noteTurnComplete(capturedTurnId, timeline!));
      }
      timeline?.clearChatContext();
      notifyListeners();
      // Drain the queued-prompts head if anything landed during
      // this turn. Defer one micro-task so listeners observe the
      // generating-flag flip before the next turn re-flips it.
      if (_promptQueue.isNotEmpty) {
        unawaited(Future.microtask(_drainPromptQueue));
      }
    }
  }

  /// Build a one-line entry for `<chat-id>.tasks.md` summarising the
  /// just-completed turn. Format:
  ///
  ///     2026-04-29 14:32 — User: "fix scroll bug" — tools: edit_file (chat_controller.dart, ai_chat.dart), git_status
  ///
  /// Deterministic (no LLM round-trip). `userText` is truncated to
  /// 96 chars so a paragraph-long question doesn't blow the line.
  /// Tool args are deduplicated and capped at 4 per tool to keep
  /// the entry readable on a long edit-heavy turn.
  String _formatTaskEntry({
    required String userText,
    required List<FiredTool> firedTools,
  }) {
    final ts = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final stamp =
        '${ts.year}-${two(ts.month)}-${two(ts.day)} ${two(ts.hour)}:${two(ts.minute)}';
    final cleanUser = userText
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final shortUser = cleanUser.length > 96
        ? '${cleanUser.substring(0, 96)}…'
        : cleanUser;
    // Group args by tool id so the same tool isn't listed many times.
    final byTool = <String, List<String>>{};
    final order = <String>[];
    for (final f in firedTools) {
      if (!byTool.containsKey(f.id)) {
        order.add(f.id);
        byTool[f.id] = <String>[];
      }
      final list = byTool[f.id]!;
      // Skip empty args + dedupe — saves space when the same file
      // gets touched in multiple matched edit blocks.
      final arg = f.firstArg.trim();
      if (arg.isNotEmpty && !list.contains(arg)) {
        list.add(arg);
      }
    }
    final toolsBuf = StringBuffer();
    for (var idx = 0; idx < order.length; idx++) {
      if (idx > 0) toolsBuf.write(', ');
      final id = order[idx];
      final args = byTool[id]!;
      toolsBuf.write(id);
      if (args.isNotEmpty) {
        final shown = args.length > 4
            ? [...args.take(4), '+${args.length - 4} more']
            : args;
        toolsBuf.write(' (${shown.join(', ')})');
      }
    }
    return '$stamp — User: "$shortUser" — tools: $toolsBuf';
  }

  Future<void> _summarizeTitleInBackground(
    ChatSession s,
    String firstMsg,
  ) async {
    try {
      final summary = await _summarizeTitle(firstMsg, model: _selectedModel);
      if (s.id == _current?.id) {
        s.title = summary;
        await _persistCurrent();
        notifyListeners();
      }
    } catch (_) {}
  }

  /// Used when terminal output is forwarded to chat.
  Future<void> appendTerminalOutput(
    String text, {
    String? workspacePath,
  }) async {
    final t = text.trim();
    if (t.isEmpty) return;
    if (_current == null) {
      await newSession(workspacePath: workspacePath);
    }
    _current!.messages.add(
      PersistedMessage(
        role: 'user',
        content:
            'Here is some output from the terminal:\n```\n$t\n```\nWhat does this mean or what should I do?',
      ),
    );
    await _persistCurrent();
    notifyListeners();
  }
}
