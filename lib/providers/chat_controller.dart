import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../l10n/strings.dart';
import '../services/anthropic_service.dart';
import '../services/github_models_service.dart';
import '../services/chat_persistence_service.dart';
import '../services/external_tool_loader.dart';
import '../services/gemini_service.dart';
import '../services/model_capabilities.dart';
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

/// Matches a single COMPLETE Lumen tool-call block in a streaming
/// buffer. Used by the agent loop to enforce single-tool-per-iteration
/// discipline on **every** provider — none of the provider services
/// (`anthropic_service.dart`, `gemini_service.dart`,
/// `github_models_service.dart`, `ollama_service.dart`) actually use
/// native function/tool calling APIs. They all just stream plain text
/// containing `<<<TOOL: args>>>` markers which the executor regex-parses.
///
/// Without single-tool truncation, a model can stream
/// `<<<EDIT_FILE>>>...` then `<<<RUN_CMD: …>>>` in one response, and the
/// executor will run all of them sequentially with no chance for the
/// model to react to earlier tool results before deciding the next
/// step — i.e. cascading hallucination on what those tools returned.
///
/// Two shapes:
///   1. **Multi-line block** — `<<<EDIT_FILE: foo.dart>>>` … `<<<END_EDIT>>>`
///      and the CREATE_FILE / MULTI_EDIT / APPEND_FILE variants.
///   2. **Single-line tool** — `<<<TOOL_NAME: args>>>`. The negative
///      lookahead excludes multi-line openers so we don't break
///      streaming on their *opening* `>>>` (which would orphan the
///      file body that follows).
///
/// The tool-name set deliberately mirrors the salvage regex in
/// `tool_executor.dart` rather than importing it — keeps the
/// dependency arrow pointing the right way (controller → executor,
/// not back). If a fifth multi-line tool appears, sync both lists.
///
/// Pre-existing limitation: this matcher (like the executor's own
/// pattern) is code-fence-blind. A model that writes
/// `<<<EDIT_FILE: …>>>` inside a markdown code block will trip both.
/// Not regressing anything; if this becomes a real problem the fix
/// belongs at the executor layer (strip fenced ranges before
/// matching).
///
/// Lazy `.*?>>>` rather than `[^>]*>>>` because legitimate args carry
/// `>` characters — `<<<RUN_CMD: ls > out.txt>>>`, redirects in
/// `git diff > file`, etc. Lazy quantifier finds the *first* closing
/// `>>>` triplet which is the right boundary in practice; a tool arg
/// that itself contains `>>>` is pathological and matches the
/// executor's own behaviour anyway.
final RegExp _kCompleteToolCall = RegExp(
  r'<<<(?:CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):.*?>>>'
  r'.*?'
  r'<<<END_(?:FILE|EDIT|APPEND)>>>'
  r'|'
  r'<<<(?!(?:CREATE_FILE|EDIT_FILE|MULTI_EDIT|APPEND_FILE):)'
  r'[A-Z_]+:.*?>>>',
  dotAll: true,
);

/// Find the end-offset of the first complete tool-call block in
/// [buffer], optionally restricted to scanning from [start] onward.
///
/// `start` is a perf knob, not a correctness knob: callers track the
/// position of the first `<<<` opener they've ever seen in the
/// growing stream buffer and pass it here, so this scan skips the
/// preamble prose. `allMatches(buffer, start)` is equivalent to
/// scanning the whole buffer when `start <= firstOpenerOffset`
/// because the regex requires `<<<` and there can be no match before
/// the first opener by definition. Saves quadratic work on streams
/// with long preambles.
///
/// Uses `allMatches(buffer, start).iterator` rather than
/// `firstMatch` because Dart's `RegExp.firstMatch` doesn't take a
/// start index — `allMatches` does, and the iterator is lazy so we
/// only materialise the first hit.
int? _firstCompleteToolCallEnd(String buffer, [int start = 0]) {
  if (start < 0) start = 0;
  if (start >= buffer.length) return null;
  final it = _kCompleteToolCall.allMatches(buffer, start).iterator;
  return it.moveNext() ? it.current.end : null;
}

/// Hidden marker yielded by every provider service when the upstream
/// API signals the response was cut at the model's output token cap.
/// (Ollama `done_reason:length`, Anthropic `stop_reason:max_tokens`,
/// Gemini `finishReason:MAX_TOKENS`, OpenAI / GitHub Models
/// `finish_reason:length`.) The controller scans for this marker
/// post-streaming, strips it from the assistant content, and treats
/// the iteration as "model wants to continue" — auto-continuing once
/// per turn instead of leaving the user hanging at the strip.
///
/// Tolerant of whitespace inside the comment so a yield that lands
/// across a chunk boundary still matches.
final RegExp _kTruncatedLengthRe = RegExp(
  r'<!--\s*LUMEN_TRUNCATED:length\s*-->\s*',
);

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

  /// Optional short label shown in the user bubble — see
  /// [PersistedMessage.displayContent]. Forwarded through the queue
  /// so a `/handoff` enqueued during generation still renders as a
  /// chip when it's eventually drained.
  final String? displayText;

  QueuedPrompt({
    required this.id,
    required this.text,
    required this.imagesBase64,
    required this.references,
    required this.workspacePath,
    required this.activeFilePath,
    required this.openFilePaths,
    required this.queuedAt,
    this.displayText,
  });
}

/// Outcome of [ChatController.revertToBeforeMessage]. Bundles the
/// timeline restore result and the chat-side state changes so the
/// caller can both show a single coherent toast AND drive UI side
/// effects (pre-fill the composer, resync open editor buffers).
class ChatRevertOutcome {
  /// True when there were file changes and they all restored cleanly,
  /// OR when the revert was chat-only (no file changes to undo). Only
  /// false when the timeline failed mid-restore.
  final bool ok;

  /// Human-readable summary surfaced to the user as a toast.
  final String message;

  /// Workspace-relative paths whose on-disk content changed during
  /// the restore. Caller resyncs any matching open editor buffers and
  /// closes tabs whose underlying file got deleted.
  final List<String> touchedRelPaths;

  /// How many chat messages were dropped (the pivot message + every
  /// message after it). Used in the toast for context.
  final int removedMessageCount;

  /// True when the revert also dropped pending queued prompts. The UI
  /// surfaces this so the user knows the queue was wiped (queued
  /// prompts are composer-side state from before the revert and would
  /// otherwise leak across a fresh re-send).
  final bool droppedQueuedPrompts;

  /// Pre-fill text for the composer when the user clicked revert on
  /// their own bubble. Null for assistant-bubble reverts (Cursor only
  /// pre-fills the prompt that was the boundary of the revert).
  final String? composerPrefill;

  const ChatRevertOutcome._({
    required this.ok,
    required this.message,
    required this.touchedRelPaths,
    required this.removedMessageCount,
    required this.droppedQueuedPrompts,
    required this.composerPrefill,
  });

  const ChatRevertOutcome._empty({required this.ok, required this.message})
    : touchedRelPaths = const <String>[],
      removedMessageCount = 0,
      droppedQueuedPrompts = false,
      composerPrefill = null;
}

/// Owns chat sessions, message generation, tool execution, multimodal
/// payloads, persistence, cancellation and approval prompts.
class ChatController extends ChangeNotifier {
  /// Hard cap on tool-use iterations per user request. Hoisted to a
  /// class-level constant so the generation loop can enforce it from
  /// a single source of truth. (We intentionally do NOT advertise this
  /// number to the model anymore — telling the agent "you have 25
  /// iterations" makes weaker models pad the work to fit the budget.
  /// Better to let them stop when the task is done.)
  ///
  /// Was 5. Raised to 25 because text-protocol single-tool-per-response
  /// (every provider in this codebase) means a real "redesign this
  /// component" task wants ~10–15 tool calls (recon → reads → edits →
  /// VERIFY → fix → re-VERIFY). The cancel button + runaway-loop guard
  /// + per-tool approval are the actual safety net; the iteration cap
  /// is just a backstop for genuinely runaway models.
  static const int maxIters = 25;

  /// How many recent messages to always send verbatim in the API
  /// payload. Beyond this, the middle of the conversation is replaced
  /// with a one-line ellipsis marker so token cost on long sessions
  /// stays bounded. The first user message is always kept too — the
  /// original ask is load-bearing context for any follow-up turn.
  ///
  /// 40 picked empirically: a turn with 8 tool calls expands to
  /// ~16 messages (assistant + tool_result pair per call), so 40
  /// covers ~2.5 full turns of recent activity. Below that and the
  /// model loses thread on multi-step tasks; above and Claude /
  /// cloud Ollama prompt tokens balloon on hour-long sessions.
  static const int _kHistoryKeepRecent = 40;

  /// Tool ids that count as "edited the workspace this turn" for the
  /// purposes of the auto-verify gate (see `_runGenerationLoop` →
  /// auto-verify). Kept in sync with the file-mutation tools in
  /// `ToolRegistry`. read_file / read_file_range / list_dir / tree
  /// / search_text / glob / find_file / git_status / git_diff /
  /// check_url are intentionally excluded — they cannot have
  /// introduced lint or type errors. run_cmd is also
  /// excluded because what it changed is opaque from this side
  /// (could be a server start, a test run, or a destructive shell
  /// op); the trade-off is that an unattended `cargo build` won't
  /// trigger auto-verify, but the alternative — auto-verifying after
  /// every shell call — would slow the loop on every dev session
  /// the agent ever runs.
  static const Set<String> _editToolIds = {
    'create_file',
    'edit_file',
    'multi_edit',
    'append_file',
    'move_file',
    'delete_file',
  };

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

  // ---- empty-response detection (Ollama "model just stops" guard) ----
  // Set in `_runGenerationLoop` finally{} when the just-finished turn
  // produced effectively no aggregated content and fired no tools and
  // wasn't cancelled / errored. This is the "Ollama silently emits
  // done:true with empty content" failure mode the user reported —
  // the stream closes cleanly, `isGenerating` flips to false, the
  // streaming progress bar disappears, and there is nothing visible
  // on screen because the live assistant message has zero body.
  // Surfaced via `lastTurnLooksEmpty`; the chat panel renders
  // `EmptyResponseStrip` while the flag is true, offering a Continue
  // button that calls `continueLastTurn()`. We do NOT auto-retry —
  // a silent infinite loop hides genuine "the model is broken on
  // this prompt" signal. Cleared in `sendMessage`, `retryLastTurn`,
  // `continueLastTurn`, and via `dismissEmptyResponseHint()`.
  //
  // Reset condition: any new generation start clears it; we set it
  // only at the *end* of a turn, never partway.
  bool _lastTurnLooksEmpty = false;
  // Workspace context captured at the time the empty turn ended so
  // `continueLastTurn()` re-runs against the same workspace the
  // empty turn was attempted in (the user may have switched
  // workspaces between the empty response and clicking Continue).
  String? _emptyTurnWorkspacePath;
  String? _emptyTurnActiveFilePath;
  List<String>? _emptyTurnOpenFilePaths;

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

  /// True when the most recently completed turn ended with no visible
  /// content, no tool calls, no cancellation, and no provider error —
  /// i.e. the Ollama "stream closed but nothing happened" failure
  /// mode. The chat panel shows an "empty response — continue?"
  /// strip while this is set so the user can nudge the model with
  /// one click instead of typing a follow-up by hand.
  bool get lastTurnLooksEmpty => _lastTurnLooksEmpty;

  /// Clear the "empty response" hint without sending a new prompt.
  /// Used by the dismiss button on `EmptyResponseStrip`.
  void dismissEmptyResponseHint() {
    if (!_lastTurnLooksEmpty) return;
    _lastTurnLooksEmpty = false;
    _emptyTurnWorkspacePath = null;
    _emptyTurnActiveFilePath = null;
    _emptyTurnOpenFilePaths = null;
    notifyListeners();
  }

  /// Re-run the generation loop after the previous turn returned
  /// empty. Sends a synthetic "Continue." user message visibly into
  /// the chat (so the user knows what got nudged) and re-uses the
  /// workspace context captured at the time the empty turn ended.
  ///
  /// No-op when not in the empty-response state, when already
  /// generating, or when the chat session was somehow cleared.
  /// We keep it bounded by treating the empty-flag as one-shot —
  /// it gets cleared on entry, so a second empty response in a
  /// row prompts the user again rather than auto-retrying forever.
  Future<void> continueLastTurn() async {
    if (!_lastTurnLooksEmpty || _isGenerating || _current == null) return;
    final ws = _emptyTurnWorkspacePath;
    final active = _emptyTurnActiveFilePath;
    final open = _emptyTurnOpenFilePaths;
    _lastTurnLooksEmpty = false;
    _emptyTurnWorkspacePath = null;
    _emptyTurnActiveFilePath = null;
    _emptyTurnOpenFilePaths = null;
    notifyListeners();
    await sendMessage(
      'Continue. If the previous task is complete, say so explicitly '
      'and stop. Do not redo prior work.',
      workspacePath: ws,
      activeFilePath: active,
      openFilePaths: open,
      displayText: 'Continue',
    );
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

  /// True when the currently selected model can accept inline image
  /// inputs. Used to suppress the chat composer's image-attach
  /// affordance for text-only models so the user doesn't paste an
  /// image the model will silently ignore.
  bool get currentModelSupportsVision {
    final (provider, rawModel) = _splitModel(_selectedModel);
    return ModelCapabilities.supportsVision(
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

  /// Cursor / Antigravity-style "revert to before this message".
  ///
  /// Truncates the active session at [index] (so the message at
  /// [index] *and* every message after it are removed) and restores
  /// every agent file change tied to the assistant messages that are
  /// being dropped. Returns a [_RevertOutcome] describing what
  /// happened so the caller (AppState / UI) can show a toast and
  /// resync open editor buffers.
  ///
  /// Cancels in-flight generation first — reverting *while* a turn is
  /// streaming is exactly the moment users want this feature most
  /// (the agent went off the rails, kill it). We wait briefly for the
  /// generation loop to finalise its `finally{}` block so the persist
  /// race between this truncation and the streaming chunk persist
  /// doesn't reintroduce a half-killed message.
  ///
  /// Returns the gathered ids + truncated user message text so the UI
  /// can pre-fill the composer (matching Cursor's "edit and re-send"
  /// affordance — clicking revert on your own bubble lets you tweak
  /// the prompt and try again).
  Future<ChatRevertOutcome> revertToBeforeMessage(
    int index,
    TimelineService? timeline,
  ) async {
    if (_current == null) {
      return const ChatRevertOutcome._empty(
        ok: false,
        message: 'No active chat session.',
      );
    }
    final session = _current!;
    if (index < 0 || index >= session.messages.length) {
      return const ChatRevertOutcome._empty(
        ok: false,
        message: 'Message index out of range.',
      );
    }

    // Cancel any in-flight generation. Wait briefly for the loop to
    // settle so the streaming persist doesn't race our truncation.
    if (_isGenerating) {
      cancelGeneration();
      var waited = 0;
      while (_isGenerating && waited < 40) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        waited++;
      }
    }

    // Snapshot the user message we're rewinding to (its text feeds
    // the composer pre-fill). We capture this BEFORE truncation
    // because we'll mutate the messages list below.
    final pivotMessage = session.messages[index];
    final pivotIsUser = pivotMessage.role == 'user';
    final composerPrefill = pivotIsUser
        ? (pivotMessage.displayContent != null &&
                  pivotMessage.displayContent!.trim().isNotEmpty
              ? pivotMessage.displayContent!
              : pivotMessage.content)
        : null;

    // Gather messageIds for every assistant message being removed —
    // those are the only entries the timeline tagged with chat
    // correlation. Also build the legacy `<sessionId>@<micros>` ids
    // for older journals that pre-date `PersistedMessage.id`.
    final removed = session.messages.sublist(index);
    final messageIds = <String>{};
    final legacyIds = <String>{};
    for (final m in removed) {
      if (m.role != 'assistant') continue;
      messageIds.add(m.id);
      legacyIds.add('${session.id}@${m.timestamp.microsecondsSinceEpoch}');
    }

    // Restore file changes. Empty set is fine — the timeline returns
    // an "ok: false, no changes" result we just translate into a
    // chat-only revert message.
    TimelineBulkRestoreResult? timelineResult;
    if (timeline != null && (messageIds.isNotEmpty || legacyIds.isNotEmpty)) {
      timelineResult = await timeline.restoreMessagesChanges(
        messageIds,
        legacyMessageIds: legacyIds,
      );
    }

    // Truncate the chat. The session-list ordering / persisted JSON
    // and the in-memory `messages` are the single source of truth for
    // what the LLM will see on the next turn (api messages are built
    // freshly each send), so this one mutation is enough.
    session.messages.removeRange(index, session.messages.length);
    await _persistCurrent();

    // Drop transient prompt queue / pending images / references too —
    // those are composer-side state from BEFORE the revert; leaving
    // them dangling would surprise the user when their next send
    // includes leftover attachments from a different intent.
    final hadQueue = _promptQueue.isNotEmpty;
    _promptQueue.clear();
    notifyListeners();

    final fileSummary = timelineResult == null
        ? 'no file changes recorded'
        : timelineResult.message.toLowerCase().replaceFirst('.', '');
    return ChatRevertOutcome._(
      ok: timelineResult?.ok ?? true,
      message: S.chatRewindResultMessage(removed.length, fileSummary),
      touchedRelPaths: timelineResult?.touchedRelPaths ?? const <String>[],
      removedMessageCount: removed.length,
      droppedQueuedPrompts: hadQueue,
      composerPrefill: composerPrefill,
    );
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
    // A retry abandons whatever the prior empty-response hint was
    // about — the failed assistant message is being removed below,
    // so the strip would dangle on stale state.
    _lastTurnLooksEmpty = false;
    _emptyTurnWorkspacePath = null;
    _emptyTurnActiveFilePath = null;
    _emptyTurnOpenFilePaths = null;
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
    String? displayText,
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
        displayText: displayText,
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
      displayContent: displayText,
    );
    session.messages.add(userMsg);
    session.updatedAt = DateTime.now();

    if (session.messages.length == 1) {
      // Title derives from the *display* text when the message is a
      // hidden-prompt slash command — otherwise the chat would be
      // titled with a wall of agent instructions instead of "/handoff".
      final titleSeed = displayText?.trim().isNotEmpty == true
          ? displayText!.trim()
          : trimmed;
      session.title = persistence.deriveTitleFromMessage(titleSeed);
      unawaited(_summarizeTitleInBackground(session, titleSeed));
    }
    await _persistCurrent();

    // Cache the user message for the retry chip — workspace context
    // is re-read from AppState on retry, no need to cache it here.
    _lastUserMessageForRetry = userMsg;
    // Sending a new prompt always clears any leftover empty-response
    // hint — that flag describes the *previous* turn, and we are
    // replacing the previous turn's outcome with a new request.
    _lastTurnLooksEmpty = false;
    _emptyTurnWorkspacePath = null;
    _emptyTurnActiveFilePath = null;
    _emptyTurnOpenFilePaths = null;

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
    String? displayText,
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
        displayText: displayText,
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
      displayText: next.displayText,
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
      // Tight workspace context. We deliberately do NOT dump a 50-entry
      // root listing anymore — most of those slots are noise (`build/`,
      // `.dart_tool/`, `.gitnexus/`, …) and the model can `<<<TREE: .>>>`
      // if it actually needs to see the layout. Active file + open tabs
      // are the bits the user genuinely wants the agent to be aware of
      // ("redesign the sidebar" implicitly means the file the user is
      // looking at).
      String workspaceContext = 'No workspace open.';
      if (workspacePath != null) {
        final ctxBuf = StringBuffer();
        ctxBuf.writeln('Working directory: $workspacePath');
        if (activeFilePath != null) {
          ctxBuf.writeln(
            'Active file (user is currently looking at this): '
            '$activeFilePath',
          );
        }
        if (openFilePaths != null && openFilePaths.isNotEmpty) {
          final shown = openFilePaths.take(20).join(', ');
          final trailing = openFilePaths.length > 20
              ? ' (+${openFilePaths.length - 20} more)'
              : '';
          ctxBuf.writeln('Open editor tabs: $shown$trailing');
        }
        workspaceContext = ctxBuf.toString().trimRight();
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
      // Pref read once up-front. Mid-turn changes don't take effect
      // until the next user message, mirroring how the
      // `allowOutsideWorkspaceWrites` flag is captured. This prevents
      // a Settings save mid-stream from changing behaviour mid-turn.
      final autoVerifyEnabled = await prefs.getAgentAutoVerifyAfterEdits();

      // ─────────────────────────────────────────────────────────
      //   Conversation continuity — anti "redo previous prompt"
      //   bias.
      // ─────────────────────────────────────────────────────────
      // Driven by two real-world bug reports:
      //   1. User asks for X, agent does X, conversation ends. Hours
      //      later they say "hi" and the model picks up X again from
      //      scratch because the long history makes it look unfinished.
      //   2. User asks a follow-up like "what was that file again?"
      //      and the model treats it as "rebuild the file" because
      //      the conversation context is dominated by the original
      //      request.
      //
      // We used to layer THREE defences (continuity rule + tasks-log
      // injection + time-gap escalation). The tasks-log block was
      // counter-productive: dumping the last 30 completed items as
      // "do NOT redo these" still primed weaker models to keep
      // expanding scope, and it bloated every iteration. Dropped it.
      // The continuity rule + an optional time-gap notice is enough.
      bool resumedAfterPause = false;
      for (int j = session.messages.length - 2; j >= 0; j--) {
        final m = session.messages[j];
        if (m.role == 'assistant') {
          final age = DateTime.now().difference(m.timestamp);
          resumedAfterPause = age > const Duration(minutes: 30);
          break;
        }
      }

      // Reasoning-effort prompt fallback for providers/models that
      // don't accept a native reasoning param (Ollama, older OpenAI,
      // Claude Haiku, Gemini 2.0). When native IS supported, we trust
      // the API knob and skip the suffix.
      final effort = session.reasoningEffort;
      final (selectedProvider, selectedRawModel) = _splitModel(_selectedModel);
      final effortIsNative = ReasoningEffortHelper.modelSupportsNative(
        provider: selectedProvider,
        rawModel: selectedRawModel,
      );
      final effortBlock = (!effortIsNative && effort != ReasoningEffort.off)
          ? '${ReasoningEffortHelper.promptDirectiveFor(effort)}\n\n'
          : '';

      // Provider-neutral system prompt. **Every** provider in this
      // codebase uses the same `<<<TOOL>>>` text protocol — we don't
      // call native function/tool APIs anywhere. So discipline rules
      // apply uniformly; there is no "Claude is special" branch.
      final pauseLine = resumedAfterPause
          ? '\n- This session is resuming after a long pause (30+ min). '
                'The user is starting a new ask, even if it looks brief — '
                'do NOT pick up where the previous turn left off.'
          : '';

      final systemPrompt =
          '''You are Lumen, the AI coding assistant built into the Lumen IDE.
You are a senior software engineer working as the user's pair programmer.
Not a Q&A bot — propose, execute, verify, and report back concisely.

## Conversation continuity
Treat messages above the latest user message as HISTORY. Tools already
ran; files were already written. Only respond to the LATEST user
message. If it's a greeting, acknowledgement, or unclear, ask what
they want next — do NOT re-execute prior requests "to be helpful".$pauseLine

## Workspace
$workspaceContext

$effortBlock## Tools
Invoke a tool by emitting its EXACT syntax. The tool runs and you
receive its output back as `<tool_result>...</tool_result>` content
on the next turn — that is real output, not user input.

**Discipline (applies to every provider):**
- Output AT MOST ONE tool call per response. After it, STOP and wait
  for the `<tool_result>`. Then decide your next step.
- **Tool calls are the ONLY way real changes happen.** Describing an
  edit in prose ("I'll update the styles to use a dark gradient...")
  does NOT modify the file. The user only sees changes that ran
  through an actual `<<<TOOL>>>` invocation. If you intend to edit,
  emit the tool call. If you only want to describe what you're
  about to do, prefix with one short prose line, then emit the
  tool. Never narrate a completed edit you did not actually issue.
- Read before editing. Use READ_FILE (optionally with `:start-end`)
  or SEARCH_TEXT to ground edits in actual code.
- **For existing files, ALWAYS use EDIT_FILE or MULTI_EDIT. NEVER use
  CREATE_FILE on a file that exists** — it forces you to retype the
  entire file, wastes minutes of generation time on big files, and
  risks dropping content you didn't mean to remove. CREATE_FILE is
  only for genuinely new files. If you intend a full rewrite, use
  one MULTI_EDIT with a single search/replace covering the whole
  body — that still goes through the diff path.
- A `<tool_result>` line starting with `[FAILED]` means the call did
  NOT execute. Do not claim success. Re-read the file and retry.
- After source-code edits, finish with `<<<VERIFY>>>`. If it reports
  issues, fix them and call VERIFY again.
- Before starting a dev server / watcher with RUN_CMD, CHECK_URL the
  expected port first. If reachable, the user already has it running
  — do NOT spawn a duplicate.
- ${allowOutsideWorkspaceWrites ? 'Built-in mutation tools may write outside the workspace when explicitly targeted with absolute/parent paths. Prefer in-workspace edits unless the user asks otherwise.' : 'Built-in mutation tools cannot write outside the active workspace. Reads outside are fine. If a write outside is needed, ask the user to enable Settings → Rules → Allow agent writes outside workspace.'}

$toolDocs

## How to work
1. Stay focused on what the user actually asked. Don't broaden scope
   unprompted, don't run unrelated installs, don't "fix" tangential
   issues unless they explicitly block the task.
2. Stream a one-line plan or progress note BEFORE each tool call so
   the user sees what you're about to do.
3. When you're done, give a short summary of what changed. Don't
   re-narrate every tool you ran — the chat already shows those as
   cards.
${compiledRules.isNotEmpty ? '\n## Project Rules (always follow)\n$compiledRules\n' : ''}${compiledSkills.isNotEmpty ? '\n$compiledSkills\n' : ''}''';

      final apiMessages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
      ];
      // **Conversation history pruning.** When a long session crosses
      // [_kHistoryKeepRecent] messages, we keep the first user
      // message (the original ask is load-bearing context) plus the
      // last N, and replace the omitted middle with a single
      // synthetic user note. This keeps token cost bounded on
      // hour-long agentic sessions without losing the prompt that
      // started everything OR the recent window the model needs to
      // continue. We don't try to summarise the dropped middle —
      // that would require an LLM round-trip we'd be charging the
      // user for, and the recent window is already the model's
      // working memory.
      final historyMessages = session.messages;
      Iterable<PersistedMessage> historyToSend;
      if (historyMessages.length <= _kHistoryKeepRecent) {
        historyToSend = historyMessages;
      } else {
        final first = historyMessages.first;
        final tail = historyMessages.sublist(
          historyMessages.length - _kHistoryKeepRecent,
        );
        // Synthetic placeholder for the omitted span. Marked clearly
        // so the model knows context was elided rather than the user
        // having actually said this.
        final droppedCount = historyMessages.length - 1 - tail.length;
        final placeholder = PersistedMessage(
          role: 'user',
          content:
              '(... earlier context elided: $droppedCount messages '
              'between the original user message and the recent '
              'window were dropped to keep token usage bounded. '
              'If you need them, ask the user.)',
        );
        historyToSend = [first, placeholder, ...tail];
      }
      for (final m in historyToSend) {
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
        // Hand the per-turn cancel token down so RUN_CMD (and any
        // future long-running tool) can abort a hung subprocess
        // when the user clicks Stop. Without this, Stop only
        // interrupts the LLM stream — a `npm start` already in
        // flight will keep blocking the executor's await forever.
        cancelToken: _cancelToken,
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
      // One-shot per turn — once we auto-verify a turn, we never
      // re-trigger inside the same turn even if the model edits more
      // files in its fix-pass without calling VERIFY itself. The
      // model already saw the auto-verify feedback once; if it
      // ignores VERIFY twice in a row that's a model behaviour
      // problem, not something an extra auto-pass will fix.
      bool autoVerifyAlreadyRan = false;
      int i = 0;
      // Aggregated across all iterations of this user-turn so the
      // tasks.md entry can summarise everything the model touched
      // in one line, regardless of how many tool-feedback rounds
      // it took. We dedupe by tool id (no point listing edit_file
      // 14 times if the model edited 14 different things in the
      // same file — the file path lands in the args list anyway).
      final firedAcrossTurn = <FiredTool>[];
      session.messages.add(PersistedMessage(role: 'assistant', content: ''));
      // Mutable: per-iteration tool image attachments are inserted at
      // this index and bump it forward, so subsequent `updateLive`
      // calls keep targeting the live assistant message at its new
      // position. Closure captures the variable (not the value) so
      // mutating here is enough — see `updateLive` below.
      var liveIdx = session.messages.length - 1;
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

      // **Single-tool-per-iteration mode** — for ALL providers.
      //
      // Reality check on this codebase: NONE of the provider services
      // (`anthropic_service.dart`, `gemini_service.dart`,
      // `github_models_service.dart`, `ollama_service.dart`) actually
      // use native function/tool calling APIs. They all just stream
      // plain text containing `<<<TOOL: args>>>` markers which the
      // executor regex-parses afterwards. So none of them auto-pause
      // when the model emits a tool call — the model can stream
      // call → prose → call → prose, and we'd run all three
      // sequentially with each call's "result" already committed to
      // by the model based on what it *guessed* the previous would
      // return. That's the cascading-hallucination failure mode
      // (visible most often on cloud Ollama models, but the same
      // architecture exists on every provider).
      //
      // Fix: as soon as the first complete tool block lands in the
      // streaming buffer, close the stream. The executor runs that
      // one tool, the real result feeds back, the next iteration
      // starts fresh. Same agent loop, just single-tool discipline
      // enforced at the wire level for every provider.
      //
      // Cost: ~one extra round trip on tasks the model could
      // legitimately chain (`READ_FILE a` + `READ_FILE b` becomes two
      // turns). Worth it; correctness > latency, and chained calls
      // were poisoning the conversation regardless of provider.
      //
      // If we ever switch a specific provider to genuinely native
      // tool calling (Anthropic `tools`, OpenAI `function_call`,
      // Gemini `tools`), revisit this — at that point we'd want to
      // disable the cut for that provider and let the API's own
      // tool-call autopause do the job. Until then: uniform.
      const cutOnFirstTool = true;
      int? firstToolEnd;

      // **Auto-continue** — fires AT MOST ONCE per user turn when the
      // model either (a) produced empty content with no tool calls
      // ("just stops responding" failure mode the user described
      // for cloud Ollama) or (b) was cut at the provider's output
      // token cap (`<!-- LUMEN_TRUNCATED:length -->` marker). We
      // synthesize a brief continue prompt and re-enter the loop so
      // the model gets one real recovery attempt before we surface
      // the user-facing Continue strip. Bounded to one attempt
      // because: (1) the second empty/truncated turn is a real
      // signal something is wrong (model context, prompt confusion,
      // capacity), and silent infinite continues would hide that;
      // (2) the maxIters cap is the ultimate backstop anyway.
      bool autoContinuedThisTurn = false;

      while (keepLooping && i < maxIters && !_cancelToken!.isCancelled) {
        i++;
        firstToolEnd = null;
        final iterBuf = StringBuffer();
        // **Runaway-loop guards** (set during streaming, checked
        // post-stream). Three independent trips:
        //
        //   1. **Closeless babble** (most common with single-tool-cut)
        //      The model emits opening tool markers without ever
        //      producing a closeable block. `cutOnFirstTool` would
        //      have bailed on the first complete tool, so accumulating
        //      many `<<<` with `firstToolEnd` still null = the model
        //      is stuck repeating partial syntax. 8 markers without
        //      a closeable block is plenty (a multi-line tool needs
        //      ≤ 6 markers in normal use).
        //
        //   2. **Total marker explosion** — > 80 `<<<` even if some
        //      are forming valid blocks. This catches MULTI_EDITs
        //      with absurd hunk counts (legit max ~16 hunks ≈ 50
        //      markers; >80 means the model is duplicating).
        //
        //   3. **Repeated RUN_CMD spam** — > 12 `<<<RUN_CMD:` markers.
        //      Mostly defensive now (cutOnFirstTool means we exit on
        //      the first complete RUN_CMD), but cheap to keep as
        //      belt-and-suspenders for partial-block cases.
        //
        // On any trip → abort streaming, do NOT run the executor on
        // the iteration's content (the destructive tools never fire),
        // and end the conversation loop cleanly so the user can
        // re-prompt with corrective context.
        bool runawayDetected = false;
        String runawayReason = '';
        int markerCount = 0;
        int runCmdCount = 0;
        // **Tail-scan offsets for `_firstCompleteToolCallEnd`.**
        //
        // The complete-tool regex is `<<<...>>>...<<<END_*>>>` (multi-
        // line block) or `<<<NAME: ...>>>` (single-line). A complete
        // match cannot start before the FIRST `<<<` we've ever seen,
        // and cannot finish until at least one `>>>` has landed in
        // the buffer.
        //
        // Without these gates, the loop ran a `dotAll` regex over the
        // full growing buffer on every chunk, which is quadratic in
        // the eventual response size. On long EDIT_FILE bodies that
        // showed up as visible UI stutter (the controller is on the
        // UI isolate). With them:
        //   - If the model is still streaming pure prose (no `<<<`
        //     yet), we don't scan at all.
        //   - Once a `<<<` has appeared, we scan starting from that
        //     index forward. Skips re-scanning the preamble on every
        //     subsequent chunk.
        //   - We also wait until at least one `>>>` has appeared,
        //     since no complete call can match before then.
        // Both are correctness-preserving: `firstMatch(buf, start)`
        // is equivalent to `firstMatch(buf)` whenever `start` is
        // ≤ the position of any possible match.
        int firstOpenerOffset = -1;
        bool sawClosingTriple = false;
        // Stream this iteration's response into iterBuf, updating
        // the live message's content each chunk.
        await for (final chunk in _generateChatStream(
          apiMessages,
          model: _selectedModel,
          token: _cancelToken,
          effort: effort,
        )) {
          if (_cancelToken!.isCancelled) break;
          final bufLenBeforeChunk = iterBuf.length;
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

          // Track FIRST opener offset (lowest index of `<<<` ever
          // seen) and whether any `>>>` has arrived. Both are
          // O(chunk.length) so the per-chunk cost stays bounded.
          if (firstOpenerOffset < 0) {
            final idx = chunk.indexOf('<<<');
            if (idx >= 0) firstOpenerOffset = bufLenBeforeChunk + idx;
          }
          if (!sawClosingTriple && chunk.contains('>>>')) {
            sawClosingTriple = true;
          }

          // **Single-tool boundary**. Cheap pre-gates above mean we
          // skip the heavy regex while the model is in pure prose
          // OR has only emitted an opener with no `>>>` yet. When
          // we do scan, we start from the first opener so the
          // preamble is skipped each time.
          final buffered = iterBuf.toString();
          firstToolEnd =
              cutOnFirstTool && firstOpenerOffset >= 0 && sawClosingTriple
              ? _firstCompleteToolCallEnd(buffered, firstOpenerOffset)
              : null;
          if (firstToolEnd != null) {
            // First complete tool call landed. Close the stream so
            // the executor runs ONE tool, feeds the real result back,
            // and the next iteration starts with grounded context.
            // The async generator's finally{} closes the http client;
            // below we truncate the partial buffer to exactly the prose
            // up to and including the first complete tool block.
            break;
          }

          // Trips. Order matters: closeless-babble fires first
          // because it's the diagnostic signal we care about most;
          // the total-explosion / RUN_CMD trips are fallbacks.
          if (markerCount >= 8 && firstToolEnd == null) {
            runawayDetected = true;
            runawayReason =
                'the model emitted $markerCount opening "<<<" markers '
                'without ever forming a complete tool block. This is '
                'the classic "stuck repeating an EDIT_FILE skeleton" '
                'failure mode for cloud models.';
            break;
          }
          if (markerCount > 80 || runCmdCount > 12) {
            runawayDetected = true;
            runawayReason =
                '"<<<" markers $markerCount× / "<<<RUN_CMD:" '
                '$runCmdCount× exceeded the per-response cap.';
            break;
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
          // tool-spam loop. Append a clear, actionable notice so the
          // user understands what happened and end the conversation
          // (the model can't recover from this on its own —
          // re-feeding it the loop just reinforces it).
          if (aggregated.isNotEmpty) aggregated += '\n\n';
          aggregated +=
              '_(loop guard tripped — $runawayReason '
              'Generation aborted before any of this iteration\'s tools '
              'ran. Common rescues: tighten the scope ("just edit X.scss, '
              'leave the rest"), re-prompt with READ_FILE so the model '
              'sees the actual file contents, switch to a stronger model, '
              'or rewind via the message menu and try again.)_';
          updateLive(aggregated, forceNotify: true);
          break;
        }
        final raw = iterBuf.toString();
        // Provider services yield `<!-- LUMEN_TRUNCATED:length -->`
        // when the upstream API tells them the stream was cut at the
        // model's output token cap (Ollama `done_reason:length`,
        // Anthropic `stop_reason:max_tokens`, Gemini
        // `finishReason:MAX_TOKENS`, OpenAI/GitHub `finish_reason:length`).
        // We detect once, strip the marker, and let the auto-continue
        // branch below decide whether to keep the conversation moving.
        final wasTruncated = _kTruncatedLengthRe.hasMatch(raw);
        final cleanedRaw = wasTruncated
            ? raw.replaceAll(_kTruncatedLengthRe, '')
            : raw;
        final executableRaw = firstToolEnd == null
            ? cleanedRaw
            : cleanedRaw.substring(0, firstToolEnd).trimRight();
        // Run the executor on the raw text. `processedResponse` has
        // tool-call syntax rewritten to friendly placeholders.
        final pass = await executor.run(executableRaw);
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
          apiMessages.add({'role': 'assistant', 'content': executableRaw});
          // Tool output is framed as a `<tool_result>` block so the
          // model can clearly distinguish tool output from genuine
          // user input. Smaller / quantized cloud models (Qwen-Coder,
          // Gemma cloud, DeepSeek) routinely treated `Tool Feedback:`
          // as if the user had pasted code and either commented on
          // it or expanded scope; the explicit XML-ish framing is a
          // strong enough signal to fix that without us moving to
          // native tool-calling APIs.
          final feedback = <String, dynamic>{
            'role': 'user',
            'content':
                '<tool_result>\n${pass.toolFeedback.trimRight()}\n'
                '</tool_result>',
          };
          apiMessages.add(feedback);
        } else {
          // ── Auto-verify gate (Issue: "look for errors before done") ──
          // The model thinks it's done. Before letting the loop close,
          // if the user has enabled auto-verify AND this turn edited
          // source files AND the model never called VERIFY itself,
          // synthesise a single VERIFY call.
          //
          // Smart: we only burn another iteration when VERIFY actually
          // found issues. A clean VERIFY (or "no analyzer detected")
          // is recorded visibly in the chat but does NOT round-trip
          // back to the model — pinging the model just to say "all
          // clean, you're done" wastes tokens AND was confusing
          // smaller models into "continuing" the now-complete task.
          //
          // Bounded:
          //   - one auto-verify per turn (`autoVerifyAlreadyRan`)
          //   - skipped when the model already called VERIFY itself
          //   - skipped when the workspace has no edits this turn
          //   - skipped when iteration cap is exhausted
          if (autoVerifyEnabled &&
              !autoVerifyAlreadyRan &&
              !_cancelToken!.isCancelled &&
              i < maxIters &&
              firedAcrossTurn.any((f) => _editToolIds.contains(f.id)) &&
              !firedAcrossTurn.any((f) => f.id == 'verify') &&
              _enabledTools.contains('verify')) {
            autoVerifyAlreadyRan = true;
            const synthetic = '<<<VERIFY>>>';
            final verifyPass = await executor.run(synthetic);
            firedAcrossTurn.addAll(verifyPass.firedTools);
            final processed = verifyPass.processedResponse.trim();
            if (processed.isNotEmpty) {
              if (aggregated.isNotEmpty) aggregated += '\n\n';
              aggregated += processed;
              updateLive(aggregated, forceNotify: true);
            }
            // Heuristic: VERIFY's textual feedback signals "clean"
            // when it ends with "no analyzer errors." or starts
            // with "VERIFY: no analyzer detected" (the two ways
            // the verify body returns "nothing to fix"). Anything
            // else (analyzer issues, timeout, launch failure)
            // round-trips so the model can fix.
            final fb = verifyPass.toolFeedback;
            final clean = fb.contains('no analyzer errors') ||
                fb.contains('no analyzer detected');
            if (clean) {
              keepLooping = false;
            } else {
              apiMessages.add({'role': 'assistant', 'content': synthetic});
              apiMessages.add({
                'role': 'user',
                'content':
                    '<tool_result>\n${fb.trimRight()}\n</tool_result>\n\n'
                    '(VERIFY ran automatically because the turn edited '
                    'source files. The analyzer reported issues — fix '
                    'them, then call VERIFY again to confirm clean.)',
              });
              // Stay in the loop for one more iteration so the model
              // can react to the analyzer output.
            }
          } else if (!autoContinuedThisTurn &&
              i < maxIters &&
              (wasTruncated || executableRaw.trim().isEmpty)) {
            // ── Auto-continue gate ────────────────────────────────
            // The model either truncated mid-thought (output token
            // cap) or returned empty (the "just stops" exhaustion
            // mode on cloud Ollama). Either way we have one free
            // recovery shot before bothering the user — append the
            // partial assistant content (if any), nudge with a
            // reason-specific user message, loop again.
            autoContinuedThisTurn = true;
            final reason = wasTruncated ? 'truncation' : 'empty';
            // Only persist a non-empty assistant turn — Anthropic
            // 400s on empty assistant content and Gemini's
            // alternating-roles merge gets confused. The empty
            // case skips this and just adds back-to-back user
            // turns (the merge logic in those services handles
            // consecutive same-role).
            if (executableRaw.trim().isNotEmpty) {
              apiMessages.add(
                {'role': 'assistant', 'content': executableRaw},
              );
            }
            final nudge = wasTruncated
                ? 'Your previous response was cut at the output '
                    'token cap before you finished. Continue from '
                    'where you left off. Prefer EDIT_FILE / '
                    'MULTI_EDIT over CREATE_FILE so you do not '
                    'have to retype content you already produced.'
                : 'Your previous response had no content. Either '
                    'complete the task with the appropriate tool '
                    'call (one per response, then wait for '
                    '<tool_result>), or briefly say what you need '
                    'from me to proceed. Do not stay silent.';
            apiMessages.add({'role': 'user', 'content': nudge});
            if (aggregated.isNotEmpty) aggregated += '\n\n';
            aggregated +=
                '_(auto-continued — $reason. The model will get '
                'one more attempt.)_';
            updateLive(aggregated, forceNotify: true);
            // keepLooping stays true; next iteration runs.
          } else {
            keepLooping = false;
          }
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

      // ── Empty-response detection (Issue: Ollama "model just stops") ──
      // When the loop ends without cancellation, no tool work, no
      // provider error, and effectively zero textual content, the
      // model emitted a clean `done:true` with nothing useful — the
      // streaming progress bar disappeared and the chat looks frozen.
      // Set the flag so the chat panel can render `EmptyResponseStrip`
      // with a Continue button. Capturing workspace context here means
      // a workspace switch between the empty turn and the user clicking
      // Continue still resolves to the original context.
      //
      // We deliberately match ONLY the truly-zero-content case
      // (`aggregated.trim().isEmpty`). Anything the model produced —
      // even a single-word ack like "Done." or "ok" — counts as a
      // real answer, and surfacing a Continue prompt over the top
      // of a perfectly valid short reply is worse UX than missing
      // the rare "model emitted exactly one whitespace character"
      // failure mode. False negatives are recoverable (user retypes
      // their request); false positives are noisy.
      if (!_cancelToken!.isCancelled &&
          firedAcrossTurn.isEmpty &&
          !aggregated.contains('<!-- LUMEN_ERR') &&
          aggregated.trim().isEmpty) {
        _lastTurnLooksEmpty = true;
        _emptyTurnWorkspacePath = workspacePath;
        _emptyTurnActiveFilePath = activeFilePath;
        _emptyTurnOpenFilePaths = openFilePaths == null
            ? null
            : List<String>.unmodifiable(openFilePaths);
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
