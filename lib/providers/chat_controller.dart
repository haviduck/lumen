import 'dart:async';
import 'dart:io';
import 'dart:math' show Random;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../l10n/strings.dart';
import '../services/agent_terminal_bridge.dart';
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
import 'chat/hallucination_detector.dart';
import 'chat/history_compressor.dart';
import 'chat/history_summarizer.dart';

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
  r'<<<(?:CREATE_FILE|EDIT_FILE|MULTI_EDIT|EDIT_RANGE|APPEND_FILE):.*?>>>'
  r'.*?'
  r'<<<END_(?:FILE|EDIT|APPEND)>>>'
  r'|'
  r'<<<(?!(?:CREATE_FILE|EDIT_FILE|MULTI_EDIT|EDIT_RANGE|APPEND_FILE):)'
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

/// Opener and closer markers for multi-line file tools. Used by the
/// auto-continue gate to detect the failure mode where a model (most
/// often glm-5.1:cloud and other smaller Ollama-hosted models) emits
/// an opening `<<<CREATE_FILE: path>>>` marker and prose narration but
/// never the file body or matching `<<<END_FILE>>>` close. Without a
/// complete block the executor fires nothing and the iteration ends
/// with text but no work — this trips a specific nudge instead of
/// silently producing a useless turn.
final RegExp _kOpenFileToolRe = RegExp(
  r'<<<(?:CREATE_FILE|EDIT_FILE|MULTI_EDIT|EDIT_RANGE|APPEND_FILE):',
);
final RegExp _kCloseFileToolRe = RegExp(r'<<<END_(?:FILE|EDIT|APPEND)>>>');

/// Regex matching thinking blocks in live/persisted message content.
/// Used by the UI to detect and render collapsible thinking sections.
/// The segment parser also uses it to separate thinking from prose.
final RegExp kThinkingBlockRe = RegExp(
  r'<!-- LUMEN_THINKING -->\n([\s\S]*?)\n<!-- /LUMEN_THINKING -->',
);

/// Assemble the live-message draft including an optional thinking
/// section. The thinking block is wrapped in HTML comments that the
/// segment parser / message bubble knows how to render as a
/// collapsible "Thinking…" indicator.
///
/// [isThinking] true means the model is still in its reasoning phase
/// — the UI should show an animated indicator. When false and
/// [thinkContent] is non-empty, the UI collapses the section.
String _draftWithThinking(
  String aggregated,
  String content,
  String thinkContent,
  bool isThinking,
) {
  final parts = <String>[];
  if (aggregated.isNotEmpty) parts.add(aggregated);
  if (thinkContent.isNotEmpty) {
    // Wrap thinking in markers the UI can parse. The `active` attr
    // tells the renderer whether to show the spinner or collapse.
    final attr = isThinking ? ' active' : '';
    parts.add('<!-- LUMEN_THINKING$attr -->\n$thinkContent\n<!-- /LUMEN_THINKING -->');
  } else if (isThinking) {
    // Thinking just started, no content yet — emit empty block with
    // active flag so the UI shows "Thinking…" immediately.
    parts.add('<!-- LUMEN_THINKING active -->\n<!-- /LUMEN_THINKING -->');
  }
  if (content.isNotEmpty) parts.add(content);
  return parts.join('\n\n');
}

/// Module-private RNG used by [_generateMarkerNonce]. Kept around as
/// a single instance (rather than a fresh `Random()` per call) to
/// amortise the seed cost across the lifetime of the process. We
/// don't need crypto strength here: the nonce defends against a
/// model in real-time mimicking a token it hasn't seen, and a
/// 32-bit space is wildly more than the model can plausibly guess
/// while generating tokens at hundreds-per-second.
final Random _markerNonceRng = Random();

/// Per-turn random nonce for the executor's `<!-- LUMEN_TOOL:... -->`
/// markers. Returns 8 hex chars (≈32 bits of randomness). Generated
/// fresh in `_runGenerationLoop` for every assistant turn and
/// stamped onto:
///   - `ToolExecutor.markerNonce` (so real markers carry it),
///   - `streamingToolPreview(..., markerNonce: ...)` (so pending
///     markers carry it AND the impersonation strip pass knows
///     which markers in the live buffer are "real / from a
///     previous iteration of this turn" vs "the model just
///     emitted this in mimicry"),
///   - `PersistedMessage.toolMarkerNonce` (so the chat parser
///     validates renders against it).
///
/// Per-turn, NOT per-session: a per-session nonce would let the
/// model copy a verbatim nonce from earlier conversation history
/// and re-inject it as a "successful" mimicry. Per-turn means the
/// only valid nonce is one the model has not had access to in
/// any previous chunk it was trained on or saw streamed back.
String _generateMarkerNonce() {
  // Two `nextInt(1 << 16)` calls with a bit-shift give us 32 bits
  // — Dart's `Random.nextInt(max)` requires `max <= 1 << 32` and
  // some platforms historically wobbled at the high end of that
  // range, so two 16-bit chunks composed are the portable pattern.
  final hi = _markerNonceRng.nextInt(1 << 16);
  final lo = _markerNonceRng.nextInt(1 << 16);
  final v = (hi << 16) | lo;
  return v.toRadixString(16).padLeft(8, '0');
}

/// Compute the storage key used to record a "blanket approval" for
/// a specific tool invocation in `_autoApprovedTools`.
///
/// Rule:
///  - For `run_cmd`, return `run_cmd:<binary>` — the binary name is
///    the first whitespace-separated token of `detail`. Empty /
///    blank `detail` falls back to the bare `run_cmd` id (treats
///    it as "all run_cmd" — the most permissive interpretation,
///    which matches the user's likely intent if they somehow
///    triggered "Always" on a no-arg run_cmd).
///  - For every other tool, return the bare tool id. Tools like
///    `delete_file` / `edit_file` don't gain useful granularity
///    from per-argument keys — the gate is all-or-nothing for the
///    permission concept they represent.
///
/// Top-level (not a method) so it can be reused by the approval
/// card without touching `ChatController` instance state. Pure
/// function: same inputs → same key, no I/O, no side effects.
///
/// Cursor / VS Code's terminal-trust list works on the same first-
/// token granularity ("trust npm" vs "trust each individual npm
/// install command"). Full-command keying was considered but
/// rejected as too granular — every flag variation would create a
/// new entry and the gate would still fire constantly.
String commandApprovalKey(String toolId, String detail) {
  if (toolId != 'run_cmd') return toolId;
  final trimmed = detail.trim();
  if (trimmed.isEmpty) return toolId;
  // First whitespace-separated token. `RegExp(r'\s')` covers
  // spaces / tabs / newlines (an agent that wraps a multi-line
  // command in one detail string still gets a sensible key).
  final firstToken = trimmed.split(RegExp(r'\s+')).first;
  if (firstToken.isEmpty) return toolId;
  return '$toolId:$firstToken';
}

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
  final String sessionId;
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
    required this.sessionId,
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
    'edit_range',
    'append_file',
    'move_file',
    'copy_file',
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

  /// Bridge that lets `RUN_CMD` spawn agent commands as real PTY-backed
  /// terminal sessions instead of orphan `Process.start` invocations.
  /// Long-running commands get promoted to visible tabs in the
  /// terminal pane. Optional so tests / non-IDE callers can run
  /// without a terminal pane mounted; production wiring in
  /// `AppState` always supplies one. See
  /// `services/agent_terminal_bridge.dart` for the full lifetime
  /// model.
  final AgentTerminalBridge? agentTerminals;

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
    this.agentTerminals,
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
  final Set<String> _generatingSessionIds = <String>{};
  final Map<String, CancellationToken> _cancelTokens =
      <String, CancellationToken>{};

  // ---- live (in-flight) session refs ----
  // Maps sessionId → the in-memory ChatSession reference that
  // `_runGenerationLoop` is actively mutating. Populated at the top of
  // the loop, cleared in `finally`. The reason this exists at all:
  // tab activation paths (`openSession`, `closeTab`, …) used to
  // unconditionally reload the session from disk, which loses any
  // mid-stream content (`<!-- LUMEN_THINKING -->` markers, partial
  // prose, in-progress tool segments) that the loop wrote in-memory
  // but hasn't yet persisted at iteration boundaries. Worse, the
  // disk-load returns a NEW `ChatSession` instance — so `_current`
  // ends up pointing at a stale copy while the streaming loop keeps
  // mutating an orphaned reference invisible to the UI. Switching
  // tabs and switching back made the live thinking badge / tool
  // segments / streaming cursor vanish until the turn finished.
  //
  // `_resolveSessionForActivation` consults this map first so we
  // hand the activator the SAME reference the loop is writing to,
  // keeping the UI consistent across tab switches mid-generation.
  final Map<String, ChatSession> _liveSessions = <String, ChatSession>{};
  final Map<String, PendingApproval> _pendingApprovals =
      <String, PendingApproval>{};
  bool _autoApprove = false;

  // ---- generation timing (stall detection) ----
  // These maps are keyed by session id so multiple chat tabs can stream
  // independently. Each `_lastChunkAt` entry ticks every time a streaming
  // chunk arrives (or when an iteration boundary completes). The chat panel
  // reads the active session's values to render elapsed / silence badges.
  //
  // Why two timestamps not one: total elapsed is a poor stall signal
  // (a hard prompt on a thinking model legitimately takes minutes),
  // but inter-chunk silence IS — a model that's still streaming
  // tokens is not stuck, just slow. The UI badges on silence, not
  // total elapsed.
  final Map<String, DateTime> _generationStartedAtBySession =
      <String, DateTime>{};
  final Map<String, DateTime> _lastChunkAtBySession = <String, DateTime>{};

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
  // Per-approval blanket grants — distinct from `_autoApprove`
  // (the global "approve everything" master switch). Driven by the
  // approval card's "Always run" / "Allow always" dropdown.
  //
  // **Two key shapes** live in this set:
  //   - **Bare tool id** (e.g. `delete_file`) — legacy/coarse
  //     semantics: "always allow this whole tool, regardless of
  //     argument". Used for non-shell tools where the per-call
  //     argument doesn't add useful trust granularity (the gate
  //     was always all-or-nothing for them anyway).
  //   - **Tool id + argument fingerprint** (e.g. `run_cmd:npm`)
  //     — finer-grained, used for `run_cmd` so the user can
  //     "always allow npm" without granting blanket permission to
  //     run *any* shell command. The fingerprint is the first
  //     whitespace-separated token of the command (the binary
  //     name). See `commandApprovalKey` for the rule.
  //
  // The gate check (`_approveCommandForSession`) consults BOTH
  // shapes — so a stale bare `run_cmd` entry from a prior code
  // version still works, and a fresh `run_cmd:git` only grants
  // git. Cleared individually from Settings → AI/Chat.
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

  bool get isGenerating {
    final id = _current?.id;
    return id != null && _generatingSessionIds.contains(id);
  }

  bool isSessionGenerating(String id) => _generatingSessionIds.contains(id);

  PendingApproval? get pendingApproval {
    final id = _current?.id;
    return id == null ? null : _pendingApprovals[id];
  }

  bool get autoApprove => _autoApprove;

  /// Time the current generation has been running, or `null` when
  /// not generating. UI uses this for elapsed-time labels next to
  /// the streaming indicator.
  Duration? get generationElapsed {
    final id = _current?.id;
    final start = id == null ? null : _generationStartedAtBySession[id];
    if (start == null) return null;
    return DateTime.now().difference(start);
  }

  /// Wall-clock time since the last streamed chunk arrived, or
  /// `null` when not generating. The chat panel uses this to badge
  /// "model has been silent for X seconds" once it crosses a
  /// threshold — a stall signal that's robust even when the model
  /// is just slow.
  Duration? get silenceDuration {
    final id = _current?.id;
    if (id == null || !_generatingSessionIds.contains(id)) return null;
    final last = _lastChunkAtBySession[id];
    if (last == null) return null;
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
    if (!_lastTurnLooksEmpty || isGenerating || _current == null) return;
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
      !isGenerating && _lastUserMessageForRetry != null;

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
      // Two parallel Ollama surfaces, each with its own provider
      // namespace so the model-management panel renders them as
      // distinct tabs and the user can flip whole groups on/off:
      //
      //   1. Local daemon (`baseUrl`) → `ollama:<name>`. Includes
      //      anything the user `ollama pull`'d, even `*-cloud`
      //      entries added via `ollama signin` SSO (those proxy
      //      through the local daemon to Ollama's cloud).
      //   2. Cloud API key (`https://ollama.com/api/tags`) →
      //      `ollama-cloud:<name>`. Direct Bearer-auth path, no
      //      local daemon required.
      //
      // **Dedupe rule.** When BOTH paths are configured we drop
      // any `*-cloud`/`*:cloud` entries from the local list — the
      // dedicated cloud namespace already exposes them, and
      // listing the same model in both tabs (under different
      // routes that produce identical output) is just confusing.
      // Pure local models (no cloud suffix) stay regardless. Users
      // who haven't configured a cloud key keep the legacy SSO-
      // proxy path untouched.
      try {
        final localModels = await ollama.getModels();
        final cloudModels = await ollama.getCloudModels();
        final hasCloud = ollama.hasCloudApiKey && cloudModels.isNotEmpty;
        for (final m in localModels) {
          if (hasCloud && OllamaService.isCloudModel(m)) continue;
          all.add('ollama:$m');
        }
        for (final m in cloudModels) {
          all.add('ollama-cloud:$m');
        }
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

    // Single source-of-truth sort. Sorting the full prefixed name
    // (`provider:rawModel`) keeps each provider's models contiguous
    // because every entry from a given provider shares its prefix —
    // the per-provider `_providers(...)` order in `ai_chat.dart` /
    // `model_management_panel.dart` then arranges the *groups*, and
    // this sort handles the *within-group* order so models read in
    // alphabetical name order under each tab without any consumer
    // needing to re-sort. Case-insensitive so `Llama` and `llama`
    // collate naturally.
    all.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return all;
  }

  /// True if at least one enabled provider is reachable.
  Future<bool> isReachable() async {
    final enabled = (await prefs.getEnabledProviders()).toSet();
    if (enabled.contains('Ollama')) {
      // Either path counts as Ollama-reachable: local daemon up OR
      // cloud key configured. Without the cloud branch a user with
      // only an API key (no local Ollama installed) would be
      // misreported as "no providers ready" by callers like the
      // first-run heuristic.
      if (ollama.hasCloudApiKey) return true;
      if (await ollama.isReachable()) return true;
    }
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
      // Both `ollama` and `ollama-cloud` map to the same enabled-
      // provider toggle in Settings — the namespace split is for
      // display / routing only.
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
      case 'ollama-cloud':
        return ollama.generateChat(
          messages,
          model: rawModel,
          token: token,
          forceCloud: true,
        );
      case 'ollama':
      default:
        return ollama.generateChat(messages, model: rawModel, token: token);
    }
  }

  /// Returns a structured summary of [droppedSpan] using the configured
  /// utility model, or `null` if summarization is disabled, the
  /// model isn't set, the routed big model is Anthropic (cache-prefix
  /// concern — see `chat_controller.dart` § history pruning), the
  /// cached summary is still fresh, or the small model failed.
  ///
  /// On success, persists the new summary onto [session] so a chat
  /// reopened later doesn't re-pay the round-trip.
  ///
  /// Cache logic:
  ///   - hit: `cachedDropped` within `refreshDelta` of `droppedCount`
  ///     → reuse `session.cachedHistorySummary` verbatim.
  ///   - miss / first run: invoke the small model on the full dropped
  ///     span, validate, store on the session.
  ///
  /// Never throws. The caller treats `null` as "use the deterministic
  /// elision placeholder".
  Future<String?> _maybeSummarizeHistory({
    required ChatSession session,
    required List<PersistedMessage> droppedSpan,
    required int droppedCount,
    required String routedProvider,
    CancellationToken? token,
  }) async {
    if (routedProvider == 'claude') return null;

    final enabled = await prefs.getHistorySummaryEnabled();
    if (!enabled) return null;

    final model = (await prefs.getToolCompressionModel()).trim();
    if (model.isEmpty) return null;

    final maxChars = await prefs.getHistorySummaryMaxChars();
    final refreshDelta = await prefs.getHistorySummaryRefreshDelta();

    final cached = session.cachedHistorySummary;
    final cachedDropped = session.cachedHistorySummaryDroppedCount;
    if (cached != null &&
        cachedDropped != null &&
        droppedCount - cachedDropped < refreshDelta) {
      return cached;
    }

    if (droppedSpan.isEmpty) return null;

    final summary = await HistorySummarizer.summarize(
      droppedMessages: droppedSpan,
      generate: (messages, {required String model}) =>
          generateUtilityText(messages, model: model, token: token),
      model: model,
      maxChars: maxChars,
    );

    if (summary == null) return null;

    // Persist the new cache so a chat reopened later (or after an
    // app restart) doesn't re-pay this round-trip. Best-effort —
    // a save failure shouldn't block returning the summary we
    // already produced for this turn.
    session.cachedHistorySummary = summary;
    session.cachedHistorySummaryDroppedCount = droppedCount;
    try {
      await persistence.saveSession(session);
    } catch (e) {
      debugPrint('history-summary persist failed: $e');
    }

    return summary;
  }

  Future<String> _compressToolFeedback(
    String rawFeedback, {
    CancellationToken? token,
  }) async {
    final enabled = await prefs.getToolCompressionEnabled();
    final model = (await prefs.getToolCompressionModel()).trim();
    final threshold = await prefs.getToolCompressionThreshold();
    final effectiveThreshold = threshold <= 0 ? 2000 : threshold;
    if (!enabled || model.isEmpty || rawFeedback.length <= effectiveThreshold) {
      return rawFeedback;
    }

    try {
      final compressed = await generateUtilityText(
        [
          {
            'role': 'system',
            'content':
                'Compress this tool output for an AI coding assistant. '
                'Preserve all file paths, line numbers, code snippets, '
                'error messages, and key facts. Remove redundancy and '
                'verbose formatting. Be concise but lose no actionable detail.',
          },
          {'role': 'user', 'content': rawFeedback},
        ],
        model: model,
        token: token,
      ).timeout(const Duration(seconds: 45));
      final trimmed = compressed.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('Error:') ||
          trimmed.length >= rawFeedback.length) {
        return rawFeedback;
      }
      return '[compressed by $model]\n$trimmed';
    } catch (_) {
      return rawFeedback;
    }
  }

  /// Pick up to three registered tool names that resemble [unknown]
  /// for the `NearMissShape.unknownTool` nudge. The model invented a
  /// tool name; the nudge is far more useful when it can say "you
  /// probably meant `X` or `Y`" than when it just says "see the
  /// system prompt" and the model loops on the same wrong guess.
  ///
  /// The similarity test is intentionally simple and tolerant:
  ///   - shared prefix of length ≥ 3 (`COPY` ↔ `COPY_FILE`),
  ///   - either name is a substring of the other (`READ` ↔
  ///     `READ_FILE`),
  ///   - share any underscore-separated token of length ≥ 3 so
  ///     `LIST_FILES` matches `LIST_DIR`, `FIND_FILE` matches
  ///     `FIND_FILE_RANGE`, `GREP` matches `SEARCH_TEXT` (no — they
  ///     share no token; that's correct, the candidates list will
  ///     be empty and the nudge falls back to "re-read the system
  ///     prompt").
  ///
  /// No Levenshtein because the false-positive radius is too wide
  /// at this length range (5–20 chars). The token-based test
  /// produces zero matches when the model invented something
  /// genuinely unrelated, which is the right behaviour — better an
  /// empty list than a misleading "you meant `EDIT_FILE`?" when the
  /// model wrote `<<<RUN_TESTS: …>>>`.
  static List<String> _suggestSimilarTools(
    String unknown,
    Set<String> known,
  ) {
    if (unknown.isEmpty || known.isEmpty) return const <String>[];
    final tokensU = unknown.split('_').where((t) => t.length >= 3).toSet();
    final hits = <String>[];
    for (final k in known) {
      if (k == unknown) continue;
      // Substring either direction.
      if (k.contains(unknown) || unknown.contains(k)) {
        hits.add(k);
        continue;
      }
      // Shared 3-char prefix on the first segment.
      final first = k.split('_').first;
      final firstU = unknown.split('_').first;
      if (first.length >= 3 && firstU.length >= 3 &&
          first.substring(0, 3) == firstU.substring(0, 3)) {
        hits.add(k);
        continue;
      }
      // Any shared underscore-separated token.
      final tokensK = k.split('_').where((t) => t.length >= 3).toSet();
      if (tokensK.intersection(tokensU).isNotEmpty) {
        hits.add(k);
      }
    }
    // Stable order, capped at 3 — long lists noise the nudge.
    hits.sort();
    return hits.take(3).toList();
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
      // `ollama` and `ollama-cloud` are both gated by the single
      // 'Ollama' provider toggle — the namespace split is purely
      // for picker grouping and route selection.
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
      case 'ollama-cloud':
        // Cloud-namespace models always go through ollama.com with
        // Bearer auth, regardless of any name-suffix heuristic.
        yield* ollama.generateChatStream(
          messages,
          model: rawModel,
          token: token,
          forceCloud: true,
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
      case 'ollama-cloud':
        return ollama.summarizeTitle(
          firstMessage,
          model: rawModel,
          forceCloud: true,
        );
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
    final resolved = await _resolveSessionForActivation(id);
    if (resolved != null) {
      _current = resolved;
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

  /// Resolve [id] to a `ChatSession` for activation as `_current`.
  ///
  /// Prefers the in-flight streaming reference from [_liveSessions]
  /// when one exists — disk-loading mid-stream returns stale content
  /// (the LUMEN_THINKING / LUMEN_TOOL markers and partial prose live
  /// only in-memory until the iteration boundary persists them) and
  /// orphans the loop's mutations from the UI for the rest of the
  /// turn. Without this preference, switching to another tab and
  /// back made thinking badges, tool cards, and the streaming
  /// cursor vanish until the model finished and we re-loaded.
  ///
  /// On the disk-load fallback we also overwrite `_sessions[idx]`
  /// with the freshly loaded instance so any subsequent generation
  /// run on this session points at the same reference the activator
  /// just handed out — i.e. `_current === _sessions[idx]` again.
  Future<ChatSession?> _resolveSessionForActivation(String id) async {
    final live = _liveSessions[id];
    if (live != null) return live;
    final loaded = await persistence.loadSession(id);
    if (loaded != null) {
      final idx = _sessions.indexWhere((s) => s.id == id);
      if (idx >= 0) _sessions[idx] = loaded;
    }
    return loaded;
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
        final resolved = await _resolveSessionForActivation(nextId);
        if (resolved != null) {
          _current = resolved;
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
      final resolved = await _resolveSessionForActivation(keepId);
      if (resolved != null) {
        _current = resolved;
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
      final resolved = await _resolveSessionForActivation(pivotId);
      if (resolved != null) {
        _current = resolved;
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

  Future<void> _persistSession(ChatSession session) async {
    session.updatedAt = DateTime.now();
    await persistence.saveSession(session);
    final idx = _sessions.indexWhere((s) => s.id == session.id);
    if (idx >= 0) {
      _sessions[idx] = session;
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
    if (isGenerating) {
      cancelGeneration();
      var waited = 0;
      while (isGenerating && waited < 40) {
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
  Future<bool> _approveCommandForSession(
    String sessionId,
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
    // Check both the per-argument key (e.g. `run_cmd:npm`) AND the
    // bare tool id. The richer key is the modern path — added by
    // the approval strip's "Always" dropdown — and lets the user
    // grant trust to a specific shell binary without unlocking
    // every shell command. The bare-id check stays for back-compat
    // with any pre-existing `run_cmd` entries from earlier builds
    // and for non-shell tools where per-arg granularity isn't a
    // thing (delete_file, edit_file, etc. still key by id alone).
    final cmdKey = commandApprovalKey(toolId, detail);
    if (_autoApprovedTools.contains(cmdKey) ||
        (cmdKey != toolId && _autoApprovedTools.contains(toolId))) {
      _recordSilentApproval(toolId, detail, reason: 'always-allow this tool');
      return true;
    }
    final c = Completer<bool>();
    final pending = PendingApproval(
      toolId: toolId,
      label: label,
      detail: detail,
      completer: c,
    );
    _pendingApprovals[sessionId] = pending;
    notifyListeners();
    final result = await c.future;
    if (identical(_pendingApprovals[sessionId], pending)) {
      _pendingApprovals.remove(sessionId);
    }
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
    final id = _current?.id;
    final p = id == null ? null : _pendingApprovals[id];
    if (p == null) return;
    if (!p.completer.isCompleted) p.completer.complete(approved);
  }

  /// Add or remove a key from the blanket-approval set.
  ///
  /// `key` may be a bare tool id (`delete_file`) or a tool-id +
  /// argument fingerprint (`run_cmd:npm`). The Settings revoke
  /// chip and the silent-approval audit toast call this with
  /// whatever key they want gone — the function doesn't try to
  /// expand bare ids into all matching rich keys (so revoking
  /// `run_cmd` from Settings doesn't accidentally also revoke
  /// `run_cmd:npm`, and vice versa). Persisted immediately.
  Future<void> setToolAutoApproved(String key, bool approved) async {
    final changed = approved
        ? _autoApprovedTools.add(key)
        : _autoApprovedTools.remove(key);
    if (!changed) return;
    await prefs.setAutoApprovedTools(_autoApprovedTools.toList());
    notifyListeners();
  }

  /// Convenience wrapper: register a per-command blanket approval
  /// for a specific tool invocation. Computes the storage key via
  /// `commandApprovalKey(toolId, detail)` and forwards to
  /// [setToolAutoApproved]. Used by the approval strip's "Always"
  /// dropdown so the call site doesn't have to duplicate the
  /// key-derivation rule.
  Future<void> setCommandAutoApproved(
    String toolId,
    String detail, {
    bool approved = true,
  }) async {
    final key = commandApprovalKey(toolId, detail);
    await setToolAutoApproved(key, approved);
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
    final id = _current?.id;
    if (id == null) return;
    _cancelGenerationForSession(id);
  }

  void _cancelGenerationForSession(String id) {
    _cancelTokens[id]?.cancel();
    final pending = _pendingApprovals[id];
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(false);
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
    if (_generatingSessionIds.contains(entry.sessionId)) {
      _cancelGenerationForSession(entry.sessionId);
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
    if (isGenerating || _current == null) return;
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
    final currentSessionId = _current?.id;
    if (currentSessionId != null &&
        _generatingSessionIds.contains(currentSessionId)) {
      _enqueuePrompt(
        sessionId: currentSessionId,
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
    required String sessionId,
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
        sessionId: sessionId,
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
  /// Replays into the session captured when the prompt was queued, so
  /// switching tabs while a background run finishes never moves a queued
  /// follow-up into the wrong chat.
  Future<void> _drainPromptQueue() async {
    if (_promptQueue.isEmpty) return;
    final next = _promptQueue.first;
    if (_generatingSessionIds.contains(next.sessionId)) return;
    final sessionIdx = _sessions.indexWhere((s) => s.id == next.sessionId);
    if (sessionIdx < 0) {
      _promptQueue.removeAt(0);
      notifyListeners();
      unawaited(Future.microtask(_drainPromptQueue));
      return;
    }
    final session = _sessions[sessionIdx];
    _promptQueue.removeAt(0);
    notifyListeners();

    final userMsg = PersistedMessage(
      role: 'user',
      content: next.text,
      imagesBase64: List<String>.from(next.imagesBase64),
      references: List<ChatReference>.from(next.references),
      displayContent: next.displayText,
    );
    session.messages.add(userMsg);
    if (session.messages.length == 1) {
      final titleSeed = next.displayText?.trim().isNotEmpty == true
          ? next.displayText!.trim()
          : next.text.trim();
      session.title = persistence.deriveTitleFromMessage(titleSeed);
      unawaited(_summarizeTitleInBackground(session, titleSeed));
    }
    await _persistSession(session);
    _lastUserMessageForRetry = userMsg;
    _lastTurnLooksEmpty = false;
    _emptyTurnWorkspacePath = null;
    _emptyTurnActiveFilePath = null;
    _emptyTurnOpenFilePaths = null;

    await _runGenerationLoop(
      targetSession: session,
      workspacePath: next.workspacePath,
      activeFilePath: next.activeFilePath,
      openFilePaths: next.openFilePaths,
    );
  }

  String _contentWithReferences(PersistedMessage message) {
    // Persisted assistant content carries `<!-- LUMEN_TOOL:... -->`
    // markers (the executor's friendly rewrite of real tool calls),
    // `<!-- LUMEN_THINKING -->` blocks, and `<!-- LUMEN_ERR -->`
    // chips. The chat UI parses them into widgets so the user
    // never sees the raw form.
    //
    // **We deliberately send markers verbatim to every model.** An
    // earlier iteration of this code rewrote markers to friendly
    // prose ("(Edited file: foo.py)") on the theory that weaker
    // models mimicking the marker shape was the failure mode worth
    // fixing. That was wrong on its face — *all* LLMs mimic
    // patterns they see in context, and the friendly-prose form is
    // a worse pattern to mimic because the chat panel can't
    // recognise the resulting prose as a tool card and surfaces it
    // as bare text (Ollama "weird text reads") or as past-tense
    // narration without an actual tool firing (Claude
    // "(Created file: foo.py)" hallucination). The marker form is
    // syntactically distinct enough that the
    // [HallucinationDetector.detectNearMissTool] htmlComment shape
    // catches mimicry at runtime; the auto-continue gate then
    // nudges the model back to `<<<TOOL: arg>>>` syntax. Trust the
    // detection layer; don't introduce new mimicable patterns.
    if (message.references.isEmpty) return message.content;

    // The composer inserts `@<label>` into the textarea when a user
    // right-clicks "Add to chat" / drops a file. That's purely a
    // VISUAL cue — no model is trained to interpret `@<path>` as a
    // file fetch directive (it shapes like a Twitter handle), and
    // smaller cloud Ollama models (gemma, glm, qwen) routinely
    // either ignore it, hallucinate that they read the file, or
    // loop trying to figure out what `@` means. Replace each
    // attached reference's `@<label>` token with `\`<label>\``
    // (backtick-wrapped path) before sending — that's natural
    // prose every model handles cleanly.
    var bodyText = message.content;
    for (final ref in message.references) {
      bodyText = bodyText.replaceAll(ref.inlineToken, '`${ref.label}`');
    }

    final buffer = StringBuffer(bodyText.trimRight());
    if (buffer.isNotEmpty) buffer.writeln();
    for (final ref in message.references) {
      buffer.writeln();
      buffer.writeln(_renderReferenceForModel(ref));
    }
    return buffer.toString().trimRight();
  }

  /// Maximum size (bytes) of a single attached file we inline into
  /// the model-bound message. Above this we emit a reference-only
  /// stub with size info and a `READ_FILE` hint so the model knows
  /// the right tool/range to call.
  ///
  /// 16 KB ≈ ~4k tokens — cheap enough that a few attachments don't
  /// blow a 32 KB context, large enough to cover most source files.
  static const int _kReferenceInlineCapBytes = 16 * 1024;

  /// Maximum number of immediate-children entries we list for a
  /// folder reference. Beyond this we collapse the rest into a
  /// "...N more entries" line and nudge towards `<<<TREE: …>>>`.
  static const int _kReferenceFolderEntryCap = 30;

  /// Folder/file basenames we suppress from folder reference
  /// listings — these are noise (vendored deps, build outputs,
  /// tooling caches) that almost never represent intent and would
  /// drown signal entries.
  static const Set<String> _kReferenceFolderNoise = <String>{
    'node_modules',
    '.git',
    '.dart_tool',
    'build',
    'dist',
    '.next',
    '.nuxt',
    '.venv',
    'venv',
    '__pycache__',
    '.idea',
    '.vscode',
    '.gradle',
    'target',
    '.cache',
    '.parcel-cache',
    '.turbo',
  };

  /// Render a single attached reference (file or folder) as the
  /// model-bound attachment block. Small text files inline with a
  /// safe code fence; large/binary files become reference-only
  /// stubs with size info and an explicit tool hint; folders list
  /// their direct children up to a cap.
  String _renderReferenceForModel(ChatReference ref) {
    if (ref.kind == ChatReferenceKind.folder) {
      return _renderFolderReference(ref);
    }
    return _renderFileReference(ref);
  }

  String _renderFileReference(ChatReference ref) {
    final label = ref.label;
    final pathHint = ref.workspaceRelativePath ?? ref.path;
    final file = File(ref.path);
    if (!file.existsSync()) {
      return 'Attached file `$label`: no longer exists at the time of send.';
    }
    int size;
    try {
      size = file.lengthSync();
    } catch (e) {
      return 'Attached file `$label`: stat failed ($e). '
          'Try `<<<READ_FILE: $pathHint>>>` if you need to inspect it.';
    }
    if (size == 0) {
      return 'Attached file `$label`: empty (0 bytes).';
    }
    if (size > _kReferenceInlineCapBytes) {
      return 'Attached file `$label` '
          '(${_humanSize(size)}, over ${_humanSize(_kReferenceInlineCapBytes)} '
          'inline cap — use `<<<READ_FILE: $pathHint>>>` for the whole file '
          'or `<<<READ_FILE: $pathHint:1-200>>>` for a range).';
    }
    String content;
    try {
      content = file.readAsStringSync();
    } on FileSystemException catch (e) {
      return 'Attached file `$label`: read failed (${e.message}). '
          'Try `<<<READ_FILE: $pathHint>>>` if you need to inspect it.';
    } on FormatException {
      return 'Attached file `$label` (${_humanSize(size)}): '
          'binary or non-UTF-8 — use `<<<READ_FILE: $pathHint>>>` if a '
          'range read makes sense, otherwise treat it as opaque.';
    } catch (e) {
      return 'Attached file `$label`: read failed ($e). '
          'Try `<<<READ_FILE: $pathHint>>>` if you need to inspect it.';
    }
    final lineCount = '\n'.allMatches(content).length +
        (content.isEmpty || content.endsWith('\n') ? 0 : 1);
    final fence = _safeFenceFor(content);
    final lang = _languageHintFor(label);
    final body = content.endsWith('\n') ? content : '$content\n';
    return 'Attached file `$label` ($lineCount lines, ${_humanSize(size)}):\n'
        '$fence$lang\n'
        '$body'
        '$fence';
  }

  String _renderFolderReference(ChatReference ref) {
    final label = ref.label;
    final pathHint = ref.workspaceRelativePath ?? ref.path;
    final dir = Directory(ref.path);
    if (!dir.existsSync()) {
      return 'Attached folder `$label`: no longer exists at the time of send.';
    }
    final shown = <String>[];
    var totalEntries = 0;
    var noiseSkipped = 0;
    try {
      for (final entry in dir.listSync(followLinks: false)) {
        totalEntries++;
        final base = p.basename(entry.path);
        if (_kReferenceFolderNoise.contains(base)) {
          noiseSkipped++;
          continue;
        }
        if (shown.length >= _kReferenceFolderEntryCap) continue;
        if (entry is Directory) {
          shown.add('  $base/');
        } else {
          shown.add('  $base');
        }
      }
    } catch (e) {
      return 'Attached folder `$label`: list failed ($e). '
          'Try `<<<TREE: $pathHint>>>` to inspect it.';
    }
    if (totalEntries == 0) {
      return 'Attached folder `$label`: empty.';
    }
    shown.sort();
    final overflow = totalEntries - shown.length - noiseSkipped;
    final overflowLine = overflow > 0
        ? '\n  ... ($overflow more entries; use `<<<TREE: $pathHint>>>` to inspect deeply)'
        : '';
    final noiseLine = noiseSkipped > 0
        ? '\n  ... ($noiseSkipped noise entries hidden: '
            'node_modules / .git / build / etc.)'
        : '';
    if (shown.isEmpty) {
      // Everything was noise — say so explicitly so the model
      // doesn't think the folder is empty.
      return 'Attached folder `$label`: $totalEntries entries, all filtered '
          'as build/cache noise (node_modules, .git, build, etc.). '
          'Use `<<<TREE: $pathHint>>>` if you need to see them anyway.';
    }
    return 'Attached folder `$label` ($totalEntries direct entries):\n'
        '${shown.join('\n')}$overflowLine$noiseLine';
  }

  /// Pick a fence length (3+ backticks) that won't be closed by
  /// content inside [body]. Required when attached content is a
  /// markdown file with embedded code fences of its own.
  String _safeFenceFor(String body) {
    final re = RegExp(r'`{3,}');
    var maxRun = 2;
    for (final m in re.allMatches(body)) {
      final len = m.group(0)!.length;
      if (len > maxRun) maxRun = len;
    }
    return '`' * (maxRun + 1);
  }

  String _languageHintFor(String label) {
    final ext = p.extension(label).toLowerCase().replaceFirst('.', '');
    if (ext.isEmpty) return '';
    // Whitelist common ones; for everything else just emit the
    // extension and let the model figure it out.
    const known = <String>{
      'dart', 'py', 'js', 'jsx', 'ts', 'tsx', 'json', 'yaml', 'yml',
      'toml', 'md', 'html', 'css', 'scss', 'sh', 'bash', 'zsh',
      'ps1', 'rb', 'go', 'rs', 'java', 'kt', 'kts', 'swift', 'c',
      'cc', 'cpp', 'h', 'hpp', 'cs', 'php', 'sql', 'xml', 'svg',
      'lua', 'r', 'pl', 'ex', 'exs', 'erl', 'hs', 'fs', 'clj',
      'cljs', 'edn', 'graphql', 'proto', 'cmake', 'makefile',
      'dockerfile', 'gitignore', 'env', 'ini',
    };
    return known.contains(ext) ? ext : ext;
  }

  String _humanSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      final kb = bytes / 1024.0;
      return '${kb.toStringAsFixed(kb >= 10 ? 0 : 1)} KB';
    }
    if (bytes < 1024 * 1024 * 1024) {
      final mb = bytes / (1024.0 * 1024.0);
      return '${mb.toStringAsFixed(mb >= 10 ? 0 : 1)} MB';
    }
    final gb = bytes / (1024.0 * 1024.0 * 1024.0);
    return '${gb.toStringAsFixed(gb >= 10 ? 0 : 1)} GB';
  }

  /// Run the streaming generation loop against [targetSession] or the
  /// active `_current` session. Caller is responsible for ensuring the
  /// most-recent message in the session is the user prompt to
  /// respond to (either freshly added by `sendMessage`, or the
  /// pre-existing last-user-message in the case of `retryLastTurn`).
  Future<void> _runGenerationLoop({
    ChatSession? targetSession,
    String? workspacePath,
    String? activeFilePath,
    List<String>? openFilePaths,
  }) async {
    final session = targetSession ?? _current;
    if (session == null) return;
    final sessionId = session.id;
    if (_generatingSessionIds.contains(sessionId)) return;
    final modelForTurn = session.model ?? _selectedModel;

    final cancelToken = CancellationToken();
    _generatingSessionIds.add(sessionId);
    _cancelTokens[sessionId] = cancelToken;
    _generationStartedAtBySession[sessionId] = DateTime.now();
    _lastChunkAtBySession[sessionId] = DateTime.now();
    // Publish the live reference so tab activation paths
    // (`openSession`, `closeTab`, …) hand back THIS instance instead
    // of disk-reloading a stale copy mid-stream. Also sync
    // `_sessions[idx]` to the same reference — _persistSession
    // already does this at the end of the turn, but doing it up
    // front means anything that walks `_sessions` during the turn
    // sees the live content too (e.g. history dropdown, tab strip).
    _liveSessions[sessionId] = session;
    final liveSessionsIdx = _sessions.indexWhere((s) => s.id == sessionId);
    if (liveSessionsIdx >= 0 &&
        !identical(_sessions[liveSessionsIdx], session)) {
      _sessions[liveSessionsIdx] = session;
    }
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

    // ── Per-turn timing instrumentation (hoisted) ─────────────
    // Same hoist rationale as `throttleTimer` / `capturedTurnId`
    // above: declared out here so the catch{} / finally{} blocks
    // can record timing on the error path too. The 182s wall
    // failure mode usually goes through the error path, so this
    // hoist is the difference between "we have data on the
    // failure" and "we don't".
    final turnStartedAt = DateTime.now();
    int? firstByteLatencyMs;
    int iterationCount = 0;
    int? lastIterationDurationMs;
    DateTime iterationStartedAt = turnStartedAt;
    // ── Hallucination / near-miss state ───────────────────────
    // Accumulated across the WHOLE turn. A model that claims
    // "Created foo.dart" (no tool ran) once might be a recap; the
    // same model claiming three different non-existent file ops
    // in one iteration is hallucinating and burning the user's
    // tokens on fiction. Once `hallucinatedPaths.length` crosses
    // [HallucinationDetector.defaultHallucinationThreshold] inside
    // a single iteration, the loop halts with a warning. Reset
    // per iteration via `iterationHallucinationCount`.
    final hallucinatedPathsAccumulated = <String>[];
    bool halluHaltTriggered = false;

    // Per-turn random hex token baked into every real
    // `<!-- LUMEN_TOOL:... -->` marker the executor emits during
    // this turn (and into the `pending` markers the streaming
    // preview emits while the model is still typing). The chat
    // panel validates each marker's trailing nonce against the
    // message's stored `toolMarkerNonce` and silently drops
    // anything that doesn't match — that's the renderer-side
    // defense against weak Ollama models latching onto the
    // marker shape they see in conversation history and emitting
    // fake "Created"/"Edited" cards with no real tool firing.
    // Fresh value per turn (not per session) so the model can
    // never re-inject a nonce it saw in earlier history: this
    // turn's nonce is, by construction, one the model has not
    // observed. 8 hex chars (32 bits) is plenty — the model
    // would have to guess in real time during generation.
    //
    // Hoisted ABOVE the try{} so the `catch (e)` block at the
    // bottom can stamp the same nonce on the error-path
    // `PersistedMessage` it emits, keeping the per-message
    // nonce semantics consistent across happy and sad paths.
    final turnMarkerNonce = _generateMarkerNonce();

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
      final (selectedProvider, selectedRawModel) = _splitModel(modelForTurn);
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

## Interpreting short user replies
When the user replies with one word or a very short phrase
("continue", "go", "next", "more", "keep going", "and?",
"yes", "ok", "do it"), they are asking you to make PROGRESS
on the ORIGINAL task. Do NOT interpret these as "repeat my
previous tool with different arguments" or "continue the
read I started". Reread the latest substantive user message
— the one that established the actual task — and pick the
next concrete action toward completing it. If the original
task is genuinely finished, ask the user what they want next
instead of inventing more work.

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
- **NEVER write `<tool_result>...</tool_result>` blocks yourself.**
  Those messages appear ONLY in subsequent turns, generated by Lumen
  AFTER a real tool has actually run. If you write `<tool_result>`
  content in your own response, no tool has run — you are
  hallucinating execution. Lumen detects this and cuts your stream.
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

**Common syntax mistakes — DO NOT MAKE THESE:**
- WRONG: `<LIST_DIR: .>` (single angle brackets — XML style)
- WRONG: `<list_dir>...</list_dir>` (XML closing tag)
- WRONG: ``` ```LIST_DIR``` ``` (markdown code fence)
- WRONG: `[LIST_DIR: .]` (square brackets)
- WRONG: `<!-- LUMEN_TOOL:list_dir|.|ok -->` (HTML comment marker —
  this is an INTERNAL Lumen display token the chat UI uses AFTER a
  tool runs; emitting it yourself does NOT call a tool)
- RIGHT: `<<<LIST_DIR: .>>>` (EXACTLY three `<` and three `>` on each side)

Tool calls written in any of the wrong forms WILL NOT EXECUTE. The IDE's
parser is strict — it only matches three-bracket syntax. If you find
yourself writing single-bracket tags or HTML-comment markers out of
habit, stop and fix the syntax before continuing.

**Anti-hallucination rule (critical):**
- A file you describe as "Created", "Wrote", "Added", "Edited",
  "Updated", "Modified", or "Saved" MUST have been touched by an
  actual `<<<CREATE_FILE: ...>>>` / `<<<EDIT_FILE: ...>>>` /
  `<<<MULTI_EDIT: ...>>>` / `<<<APPEND_FILE: ...>>>` tool call in
  THIS turn or a previous turn. Never claim file ops you did not
  invoke as tools.
- If you are about to write "Created `src/foo.tsx`" but you have
  not actually emitted a CREATE_FILE block for it, STOP. Either
  emit the tool call now, or describe it as planned ("I will
  create `src/foo.tsx`") instead of claimed ("Created
  `src/foo.tsx`"). The IDE checks claims against actually-fired
  tools; persistent hallucinated claims will halt the turn.

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
      // last N, and replace the omitted middle with EITHER a
      // structured LLM-generated summary (opt-in via Settings → AI /
      // Chat → "Summarize chat history with utility model") OR a
      // single synthetic user note. The summary path uses the same
      // small model configured for tool-result compression — see
      // `lib/providers/chat/history_summarizer.dart`.
      //
      // Layered fallback: cached summary → fresh summary on cache
      // miss → deterministic one-line placeholder on any failure
      // (model unset, timeout, malformed output, summary too long).
      // Worst case is "feature did nothing", never "broke chat".
      //
      // Anthropic carve-out: Claude has automatic prompt caching
      // keyed on prefix stability. Re-summarizing rewrites the
      // middle of history and blows the cache prefix every turn,
      // costing more than the elision approach saves. So we skip
      // summarization on Claude entirely — the deterministic
      // placeholder keeps the prefix stable.
      final historyMessages = session.messages;
      Iterable<PersistedMessage> historyToSend;
      if (historyMessages.length <= _kHistoryKeepRecent) {
        historyToSend = historyMessages;
      } else {
        final first = historyMessages.first;
        final tail = historyMessages.sublist(
          historyMessages.length - _kHistoryKeepRecent,
        );
        final droppedCount = historyMessages.length - 1 - tail.length;
        final droppedSpan = historyMessages.sublist(
          1,
          historyMessages.length - _kHistoryKeepRecent,
        );

        final summaryText = await _maybeSummarizeHistory(
          session: session,
          droppedSpan: droppedSpan,
          droppedCount: droppedCount,
          routedProvider: selectedProvider,
          token: cancelToken,
        );

        final placeholderContent = summaryText != null
            ? '(... earlier context elided: $droppedCount messages '
                  'were summarized below. Treat the summary as a '
                  'recap of work already done; do NOT redo any '
                  'actions it describes.)\n\n$summaryText'
            : '(... earlier context elided: $droppedCount messages '
                  'between the original user message and the recent '
                  'window were dropped to keep token usage bounded. '
                  'If you need them, ask the user.)';
        final placeholder = PersistedMessage(
          role: 'user',
          content: placeholderContent,
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
        approver: (toolId, label, detail) =>
            _approveCommandForSession(sessionId, toolId, label, detail),
        enabledTools: _enabledTools,
        recorder: tlRecorder,
        allowWritesOutsideWorkspace: allowOutsideWrites,
        // Hand the per-turn cancel token down so RUN_CMD (and any
        // future long-running tool) can abort a hung subprocess
        // when the user clicks Stop. Without this, Stop only
        // interrupts the LLM stream — a `npm start` already in
        // flight will keep blocking the executor's await forever.
        cancelToken: cancelToken,
        // Route agent-spawned commands through the terminal-pane
        // bridge when wired (production always wires one). The
        // executor passes this through to every `ToolInvocation` —
        // `RUN_CMD` uses it to spawn a hidden PTY session that
        // gets promoted to a visible tab on detach (long-running
        // commands like `npm run dev`). When the bridge is null
        // (tests / non-IDE callers) `RUN_CMD` falls back to its
        // legacy `Process.start` path.
        agentTerminalLauncher: agentTerminals == null
            ? null
            : ({
                required String command,
                required String workingDirectory,
                void Function(String stripped)? onOutput,
              }) async {
                final shellId = await prefs.getTerminalShellId();
                return agentTerminals!.start(
                  command: command,
                  workingDirectory: workingDirectory,
                  preferredShellId: shellId,
                  onOutput: onOutput,
                );
              },
        // Wire `WEB_SEARCH` / `WEB_FETCH` to Ollama Cloud's web
        // tooling endpoints (https://docs.ollama.com/capabilities/web-search).
        // When the user has no cloud API key set, the closure
        // still routes through `OllamaService` — its `webSearch` /
        // `webFetch` methods throw a `StateError` with a "set the
        // key in Settings" message that the tool body surfaces to
        // the agent verbatim. We deliberately wire the closures
        // unconditionally rather than `null`-ing them out without
        // a key: that way the failure surface is the same in both
        // places (the tool feedback string) instead of one path
        // returning "tool not available" and another saying "key
        // missing".
        webSearch: ollama.webSearch,
        webFetch: ollama.webFetch,
      );
      executor.markerNonce = turnMarkerNonce;

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
      session.messages.add(
        PersistedMessage(
          role: 'assistant',
          content: '',
          toolMarkerNonce: turnMarkerNonce,
        ),
      );
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
          toolMarkerNonce: turnMarkerNonce,
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

      // **Hallucinated `<tool_result>` cut.** The assistant should
      // never emit `<tool_result>` in its own stream — those blocks
      // are user-role messages we inject AFTER a real tool runs.
      // When a model (most often DeepSeek-family / smaller Qwen
      // variants) starts mimicking the framing, it's because it
      // just hallucinated tool execution and is about to fabricate
      // tool output (fake bedrock IDs, invented file listings,
      // imagined project structure, …) and continue based on what
      // those imagined results "said". Cutting at the first
      // appearance of `<tool_result>` aborts the cascade before any
      // hallucinated content lands, then the auto-continue gate
      // injects a corrective nudge so the model gets one shot to
      // emit a real `<<<TOOL>>>` call instead.
      //
      // `hallucinationCutAt` is the buffer offset where the literal
      // string `<tool_result>` first appeared. `hallucinationDetected`
      // is the flag the auto-continue gate keys off so it can build
      // a hallucination-specific nudge instead of the generic empty/
      // truncation ones.
      int? hallucinationCutAt;
      bool hallucinationDetected = false;

      // **Auto-continue** — fires up to [_maxAutoContinues] times per
      // user turn when the model either (a) produced empty content
      // with no tool calls ("just stops responding" failure mode
      // common with cloud Ollama models) or (b) was cut at the
      // provider's output token cap. We synthesize a brief continue
      // prompt and re-enter the loop so the model gets a real
      // recovery attempt. Bounded to prevent infinite silent loops
      // — after exhausting retries, the empty-response strip
      // surfaces so the user can intervene.
      const int maxAutoContinues = 3;
      int autoContinueCount = 0;

      while (keepLooping && i < maxIters && !cancelToken.isCancelled) {
        i++;
        firstToolEnd = null;
        hallucinationCutAt = null;
        hallucinationDetected = false;
        final iterBuf = StringBuffer();
        // **Runaway-loop guards** (set during streaming, checked
        // post-stream). Two trips:
        //
        //   1. **Total marker explosion** — > 80 `<<<` even if some
        //      are forming valid blocks. This catches MULTI_EDITs
        //      with absurd hunk counts (legit max ~16 hunks ≈ 50
        //      markers; >80 means the model is duplicating).
        //
        //   2. **Repeated RUN_CMD spam** — > 12 `<<<RUN_CMD:` markers.
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
        // **Wire-payload compression.** `apiMessages` is our canonical
        // per-turn working state — we keep it uncompressed so internal
        // logic (auto-continue framing, single-tool cut, executor
        // feedback) stays straightforward. But what we SEND to the
        // model is a compressed view: stale `<tool_result>` blocks get
        // their inner content elided to a one-line stub so a long
        // agentic turn doesn't inflate every iteration's prompt with
        // file dumps from earlier reads. See `history_compressor.dart`
        // for the rationale.
        //
        // Skipped on Claude because Anthropic's automatic prompt
        // caching keys on prefix stability — eliding tool_results
        // shifts the elision boundary forward each iteration and
        // would invalidate cache hits past that point. Claude also
        // handles long contexts gracefully on its own. Other
        // providers (Ollama, Gemini, GitHub Models) all benefit
        // because they re-prefill from scratch every turn.
        final wireMessages = selectedProvider == 'claude'
            ? apiMessages
            : HistoryCompressor.compressForWire(apiMessages);
        // **Thinking-phase tracking.** Thinking models (Qwen 3,
        // DeepSeek R1, etc.) yield reasoning tokens wrapped in
        // LUMEN_THINK_START / LUMEN_THINK_END markers. Those tokens
        // are NOT executable (no tool calls, no user-facing prose),
        // so they go into a separate buffer. The live UI renders
        // them as a collapsible "Thinking…" indicator so the user
        // sees activity instead of dead air.
        final thinkBuf = StringBuffer();
        bool inThinkPhase = false;

        // Stream this iteration's response into iterBuf, updating
        // the live message's content each chunk.
        iterationStartedAt = DateTime.now();
        await for (final chunk in _generateChatStream(
          wireMessages,
          model: modelForTurn,
          token: cancelToken,
          effort: effort,
        )) {
          if (cancelToken.isCancelled) break;

          // Stall detector: refresh the last-chunk timestamp on
          // EVERY chunk (including thinking) so the stall-warning
          // strip knows the model is still alive.
          _lastChunkAtBySession[sessionId] = DateTime.now();
          // First-byte stamp: any chunk counts as "model is doing
          // something". One-shot per turn.
          firstByteLatencyMs ??= DateTime.now()
              .difference(turnStartedAt)
              .inMilliseconds;

          // ── Thinking-marker state machine ──
          if (chunk == OllamaService.thinkStartMarker) {
            inThinkPhase = true;
            updateLive(_draftWithThinking(
              aggregated, iterBuf.toString(), thinkBuf.toString(), true,
            ));
            continue;
          }
          if (chunk == OllamaService.thinkEndMarker) {
            inThinkPhase = false;
            updateLive(_draftWithThinking(
              aggregated, iterBuf.toString(), thinkBuf.toString(), false,
            ));
            continue;
          }
          if (inThinkPhase) {
            thinkBuf.write(chunk);
            updateLive(_draftWithThinking(
              aggregated, iterBuf.toString(), thinkBuf.toString(), true,
            ));
            continue;
          }

          // ── Normal content chunk (non-thinking) ──
          final bufLenBeforeChunk = iterBuf.length;
          iterBuf.write(chunk);

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
            break;
          }

          // **Hallucinated `<tool_result>` detection.**
          if (hallucinationCutAt == null) {
            const needle = '<tool_result>';
            final overlap = needle.length - 1;
            final scanFrom = bufLenBeforeChunk >= overlap
                ? bufLenBeforeChunk - overlap
                : 0;
            final hIdx = buffered.indexOf(needle, scanFrom);
            if (hIdx >= 0) {
              hallucinationCutAt = hIdx;
              hallucinationDetected = true;
              break;
            }
          }

          // Total-explosion / RUN_CMD trip.
          if (markerCount > 80 || runCmdCount > 12) {
            runawayDetected = true;
            runawayReason =
                '"<<<" markers $markerCount× / "<<<RUN_CMD:" '
                '$runCmdCount× exceeded the per-response cap.';
            break;
          }

          // The live message shows previous-iterations aggregated +
          // current iteration's running buffer + thinking section,
          // separated by blank lines.
          updateLive(_draftWithThinking(
            aggregated, iterBuf.toString(), thinkBuf.toString(), false,
          ));
        }
        if (cancelToken.isCancelled) {
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
        // Cut at the first complete tool call OR at the hallucinated
        // `<tool_result>` opener, whichever fired the stream break.
        // Only one of `firstToolEnd` / `hallucinationCutAt` can be
        // non-null in a given iteration (we break on either), so a
        // simple null-coalesce picks the right boundary without
        // needing a min() over both.
        final cutAt = firstToolEnd ?? hallucinationCutAt;
        final executableRaw = cutAt == null
            ? cleanedRaw
            : cleanedRaw.substring(0, cutAt).trimRight();
        // Run the executor on the raw text. `processedResponse` has
        // tool-call syntax rewritten to friendly placeholders.
        final pass = await executor.run(executableRaw);
        firedAcrossTurn.addAll(pass.firedTools);
        // End-of-iteration timing stamp. Includes both streaming
        // wall-clock AND executor wall-clock (tool runs). That's
        // the right boundary because the user perceives both as
        // the same "the agent is working" phase, and a slow tool
        // (e.g. a `verify` that runs `dart analyze`) is a real
        // contributor to per-iteration latency.
        iterationCount += 1;
        lastIterationDurationMs = DateTime.now()
            .difference(iterationStartedAt)
            .inMilliseconds;

        // ── Misbehaviour detection (per-iteration) ──────────────
        // Two complementary checks. Both are pure parsers (see
        // `lib/providers/chat/hallucination_detector.dart`) and
        // must run on EVERY iteration so they catch failure modes
        // even when the auto-continue gate doesn't trigger.
        //
        // 1. Hallucinated file-op claims: model wrote past-tense
        //    "Created `foo`" / "Edited `bar`" but no
        //    create/edit/multi_edit/append tool actually fired
        //    for that path during the turn. Accumulated across
        //    iterations; halts the turn when a single iteration
        //    contributes >= threshold new claims.
        // 2. Near-miss tool syntax: zero fired tools AND the text
        //    contains `<TOOL_NAME: arg>` (single brackets) for a
        //    known tool. Means the model wrote a tool with the
        //    wrong outer syntax and needs a correction nudge.
        //    Wired into the auto-continue gate as a 5th trigger.
        final firedFilePaths = firedAcrossTurn
            .where((f) => HallucinationDetector.isFileMutationTool(f.id))
            .map((f) => f.firstArg)
            .toList(growable: false);
        final newHallucinations =
            HallucinationDetector.detectHallucinatedClaims(
              assistantText: pass.processedResponse,
              firedFilePaths: firedFilePaths,
            );
        hallucinatedPathsAccumulated.addAll(newHallucinations);

        ({String name, NearMissShape shape})? nearMissTool;
        bool intentWithoutAction = false;
        if (!pass.hasToolCalls) {
          final knownNames = <String>{
            for (final t in ToolRegistry.all)
              if (_enabledTools.contains(t.id)) t.id.toUpperCase(),
          };
          nearMissTool = HallucinationDetector.detectNearMissTool(
            assistantText: executableRaw,
            knownToolNames: knownNames,
          );
          // Only check intent-without-action when no near-miss
          // was found — a near-miss means the model TRIED to
          // call a tool, and the dedicated branch in the
          // auto-continue gate gives a more specific nudge.
          if (nearMissTool == null && executableRaw.trim().isNotEmpty) {
            intentWithoutAction =
                HallucinationDetector.detectIntentWithoutAction(executableRaw);
          }
        }

        // Halt the loop when a single iteration produced enough
        // hallucinated claims to look like a runaway role-play
        // session. Defer the visible warning + persistence to the
        // post-loop block so it lands ONCE in `aggregated` instead
        // of competing with auto-continue / auto-verify text.
        if (newHallucinations.length >=
            HallucinationDetector.defaultHallucinationThreshold) {
          halluHaltTriggered = true;
          keepLooping = false;
        }

        if (aggregated.isNotEmpty) aggregated += '\n\n';
        // Persist the thinking section in the displayed message so
        // the user can expand it post-stream. Only on the first
        // iteration that actually produced thinking content (later
        // iterations in the same turn rarely think again, and
        // duplicating the collapsed block would be noisy).
        final thinkStr = thinkBuf.toString();
        if (thinkStr.isNotEmpty) {
          aggregated +=
              '<!-- LUMEN_THINKING -->\n$thinkStr\n<!-- /LUMEN_THINKING -->\n\n';
        }
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
          final toolFeedback = await _compressToolFeedback(
            pass.toolFeedback,
            token: cancelToken,
          );
          final feedback = <String, dynamic>{
            'role': 'user',
            'content':
                '<tool_result>\n${toolFeedback.trimRight()}\n'
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
              !cancelToken.isCancelled &&
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
            final clean =
                fb.contains('no analyzer errors') ||
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
          } else if (autoContinueCount < maxAutoContinues &&
              i < maxIters &&
              (wasTruncated ||
                  hallucinationDetected ||
                  nearMissTool != null ||
                  intentWithoutAction ||
                  executableRaw.trim().isEmpty ||
                  (_kOpenFileToolRe.hasMatch(executableRaw) &&
                      !_kCloseFileToolRe.hasMatch(executableRaw)))) {
            // ── Auto-continue gate ────────────────────────────────
            // Four triggers, bounded to [_maxAutoContinues] recovery
            // attempts per turn:
            //
            //   1. **Truncation** — the upstream API cut the stream
            //      at the model's output token cap. Continue from
            //      where it left off.
            //
            //   2. **Hallucinated `<tool_result>`** — the model
            //      started fabricating tool execution. We cut the
            //      stream before any imagined output landed; tell
            //      it that no tool ran and what the real syntax is.
            //
            //   3. **Empty** — the model emitted nothing useful
            //      (the cloud-Ollama "just stops" exhaustion
            //      pattern). Nudge it to either commit to a tool
            //      call or explain what it needs.
            //
            //   4. **Incomplete file-tool block** — the model
            //      opened `<<<CREATE_FILE: ...>>>` (or EDIT_FILE /
            //      MULTI_EDIT / APPEND_FILE) but never emitted the
            //      matching `<<<END_FILE>>>` (or END_EDIT /
            //      END_APPEND). Common with smaller Ollama-hosted
            //      models (glm-5.1:cloud and similar) that narrate
            //      "Now creating X" with the opener but skip the
            //      body and close, leaving the executor with
            //      nothing to fire. This case used to be caught by
            //      the closeless-babble guard before it was
            //      removed for false-positiving on legitimate
            //      Claude multi-tool output — Claude always closes
            //      its blocks, so this targeted check is safe.
            //
            // Each gets a reason-specific nudge so the model has
            // concrete guidance instead of a generic "try again".
            final hasIncompleteFileTool =
                _kOpenFileToolRe.hasMatch(executableRaw) &&
                !_kCloseFileToolRe.hasMatch(executableRaw);
            autoContinueCount++;
            final String reason;
            final String nudge;
            if (hallucinationDetected) {
              reason = 'hallucinated tool_result';
              nudge =
                  'I cut your stream because you started writing a '
                  '`<tool_result>` block. NO tool has actually run. '
                  'Those messages come ONLY from Lumen, in '
                  'subsequent turns, AFTER a real tool executes — '
                  'never from you. To actually invoke a tool, '
                  'output exactly `<<<TOOL_NAME: args>>>` (three '
                  'angle brackets each side, no slash, no closing '
                  'tag), one tool per response, then STOP and wait '
                  'for the real `<tool_result>` to come back. Do '
                  'not narrate or simulate tool output yourself.';
            } else if (nearMissTool != null) {
              final hit = nearMissTool;
              final toolName = hit.name;
              reason = 'tool syntax near-miss ($toolName, '
                  '${hit.shape.name})';
              switch (hit.shape) {
                case NearMissShape.xmlStyle:
                  nudge =
                      'You wrote `<$toolName: ...>` (single '
                      'angle brackets — XML style). NO tool '
                      'ran. Lumen\'s parser requires EXACTLY '
                      'three angle brackets on each side: '
                      '`<<<$toolName: args>>>`. Re-emit the '
                      'same invocation with three brackets each '
                      'side, one tool per response, then STOP '
                      'and wait for the real `<tool_result>`.';
                case NearMissShape.doubleBracket:
                  nudge =
                      'You wrote `<<$toolName: ...>>` (TWO '
                      'angle brackets each side). NO tool ran. '
                      'Lumen\'s parser requires EXACTLY THREE '
                      'angle brackets on each side: '
                      '`<<<$toolName: args>>>`. Add one more '
                      '`<` and one more `>` and re-emit, one '
                      'tool per response, then STOP and wait '
                      'for the real `<tool_result>`.';
                case NearMissShape.malformedClose:
                  nudge =
                      'You opened the tool correctly with '
                      '`<<<$toolName:` (three `<`) but the '
                      'CLOSING brackets were short — only one '
                      'or two `>` instead of three. NO tool '
                      'ran. The close MUST be exactly `>>>` '
                      '(three angle brackets). Re-emit the '
                      'invocation with the proper close: '
                      '`<<<$toolName: args>>>`, then STOP and '
                      'wait for the real `<tool_result>`.';
                case NearMissShape.htmlComment:
                  // `LUMEN_TOOL` is the sentinel returned by the
                  // detector when the marker had no parseable tool
                  // id; render a generic version then. Otherwise
                  // we have the actual tool the model probably
                  // meant to call.
                  final isGeneric = toolName == 'LUMEN_TOOL';
                  final example = isGeneric
                      ? '<<<TOOL_NAME: args>>>'
                      : '<<<$toolName: args>>>';
                  nudge =
                      'You wrote `<!-- LUMEN_TOOL ... -->` (an '
                      'HTML comment). NO tool ran. That marker '
                      'is an INTERNAL display token Lumen '
                      'generates AFTER your tool actually '
                      'executes — the chat UI rewrites real '
                      'tool calls into it for rendering. It is '
                      'NOT a tool-call syntax. To actually '
                      'invoke a tool, emit `$example` (three '
                      'angle brackets each side, no HTML '
                      'comment, no slash, one tool per '
                      'response), then STOP and wait for the '
                      'real `<tool_result>`.';
                case NearMissShape.unknownTool:
                  // Build a short list of registered tools whose
                  // name resembles the unknown one — close
                  // substring match or shared prefix. Cheap; the
                  // nudge is far more actionable than "see the
                  // system prompt" because the model often loops
                  // on the same wrong name otherwise.
                  //
                  // Recomputing the enabled-tool set here rather
                  // than capturing the `knownNames` from the
                  // detection site keeps `knownNames` scoped to
                  // the detector call (where it's actually used)
                  // and avoids leaking it into the wider
                  // continuation-decision block.
                  final enabledNames = <String>{
                    for (final t in ToolRegistry.all)
                      if (_enabledTools.contains(t.id))
                        t.id.toUpperCase(),
                  };
                  final candidates = _suggestSimilarTools(
                    toolName,
                    enabledNames,
                  );
                  final suggestionLine = candidates.isEmpty
                      ? 'Re-read the tool list in the system prompt.'
                      : 'Closest registered tools: ${candidates.join(', ')}.';
                  nudge =
                      'You called `<<<$toolName: …>>>` but '
                      '$toolName is not a registered tool — NO '
                      'tool ran. Lumen only dispatches the tool '
                      'names listed in your system prompt. '
                      '$suggestionLine If none fits, ask the user '
                      'instead of inventing tools. Re-emit ONE '
                      'real tool call, then STOP and wait for the '
                      'real `<tool_result>`.';
              }
            } else if (intentWithoutAction) {
              reason = 'intent without action';
              nudge =
                  'You committed to an action ("Let me read…", '
                  '"I\'ll check…", or similar) but never actually '
                  'invoked the tool. Saying you will do something '
                  'is not the same as doing it — the IDE only '
                  'sees a tool call when you emit '
                  '`<<<TOOL_NAME: args>>>` in your response, with '
                  'three angle brackets each side. Either emit '
                  'the tool call you committed to NOW, one tool '
                  'per response, then stop and wait for the '
                  '`<tool_result>` — or, if you genuinely don\'t '
                  'know what to call, ask the user a concrete '
                  'question. Do not narrate intent with no '
                  'follow-through.';
            } else if (hasIncompleteFileTool) {
              reason = 'incomplete tool block';
              nudge =
                  'You opened a multi-line tool block '
                  '(CREATE_FILE / EDIT_FILE / MULTI_EDIT / '
                  'EDIT_RANGE / APPEND_FILE) but never emitted the matching '
                  'close marker (`<<<END_FILE>>>`, '
                  '`<<<END_EDIT>>>`, or `<<<END_APPEND>>>`). No '
                  'file was created or edited. Each multi-line '
                  'tool needs THREE parts on separate lines: '
                  'opening marker, the body content, then the '
                  'matching close marker. Re-emit ONE complete '
                  'tool block — opening, body, AND close — in '
                  'this response, then stop and wait for the '
                  'tool_result. Do not narrate "now creating X" '
                  'without the close marker; that produces nothing.';
            } else if (wasTruncated) {
              reason = 'truncation';
              nudge =
                  'Your previous response was cut at the output '
                  'token cap before you finished. Continue from '
                  'where you left off. Prefer EDIT_FILE / '
                  'MULTI_EDIT over CREATE_FILE so you do not '
                  'have to retype content you already produced.';
            } else {
              reason = thinkStr.isNotEmpty ? 'thinking but no output' : 'empty';
              nudge = thinkStr.isNotEmpty
                  ? 'You reasoned internally but produced no visible '
                    'output. Your thinking was received — now commit to '
                    'an action: emit the appropriate tool call '
                    '(one per response, then wait for <tool_result>), '
                    'or provide a brief answer. Do not stay silent after '
                    'thinking.'
                  : 'Your previous response had no content. Either '
                    'complete the task with the appropriate tool '
                    'call (one per response, then wait for '
                    '<tool_result>), or briefly say what you need '
                    'from me to proceed. Do not stay silent.';
            }
            // Only persist a non-empty assistant turn — Anthropic
            // 400s on empty assistant content and Gemini's
            // alternating-roles merge gets confused. The empty
            // case skips this and just adds back-to-back user
            // turns (the merge logic in those services handles
            // consecutive same-role).
            if (executableRaw.trim().isNotEmpty) {
              apiMessages.add({'role': 'assistant', 'content': executableRaw});
            }
            apiMessages.add({'role': 'user', 'content': nudge});
            if (aggregated.isNotEmpty) aggregated += '\n\n';
            final remaining = maxAutoContinues - autoContinueCount;
            aggregated +=
                '_(auto-continued — $reason. '
                '${remaining > 0 ? 'Attempt $autoContinueCount/$maxAutoContinues.' : 'Final attempt.'})_';
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

      // ── Hallucination halt warning ────────────────────────────
      // If [halluHaltTriggered] flipped during the loop, append a
      // user-facing warning so the chat panel surfaces a clear
      // explanation. Distinct shape from provider-errors and
      // empty-response strips because the failure is the model's
      // *behaviour*, not the connection. Showing the actual
      // claimed-but-missing paths matters: it lets the user
      // verify ("yep, those files don't exist") instead of
      // trusting an opaque warning.
      if (halluHaltTriggered) {
        final paths = hallucinatedPathsAccumulated.toSet().toList()..sort();
        final preview = paths.length <= 4
            ? paths.join(', ')
            : '${paths.take(4).join(', ')} (+${paths.length - 4} more)';
        if (aggregated.isNotEmpty) aggregated += '\n\n';
        aggregated += S.chatHallucinationHaltWarning(paths.length, preview);
        updateLive(aggregated, forceNotify: true);
        debugPrint(
          '[hallucination-halt] sessionId=$sessionId '
          'count=${paths.length} '
          'paths=${paths.take(8).join(", ")}',
        );
      }

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
      if (!cancelToken.isCancelled && firedAcrossTurn.isEmpty) {
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
      if (!cancelToken.isCancelled &&
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

      // Stamp final timing onto the live assistant message so the
      // bubble can render the dim footer and `_persistSession`
      // writes the timing fields to disk. This is the ONLY mutation
      // path that includes the timing fields; `updateLive` keeps
      // them null during streaming so an interrupted/crashed turn
      // doesn't surface partial numbers as if they were final.
      final liveCurrent = session.messages[liveIdx];
      session.messages[liveIdx] = PersistedMessage(
        id: liveCurrent.id,
        role: liveCurrent.role,
        content: liveCurrent.content,
        timestamp: liveCurrent.timestamp,
        imagesBase64: liveCurrent.imagesBase64,
        references: liveCurrent.references,
        displayContent: liveCurrent.displayContent,
        totalDurationMs: DateTime.now()
            .difference(turnStartedAt)
            .inMilliseconds,
        firstByteLatencyMs: firstByteLatencyMs,
        iterationCount: iterationCount > 0 ? iterationCount : null,
        lastIterationDurationMs: lastIterationDurationMs,
        toolMarkerNonce: liveCurrent.toolMarkerNonce ?? turnMarkerNonce,
      );
      debugPrint(
        '[turn-timing] sessionId=$sessionId '
        'total=${DateTime.now().difference(turnStartedAt).inMilliseconds}ms '
        'ttfb=${firstByteLatencyMs ?? -1}ms '
        'iters=$iterationCount '
        'lastIter=${lastIterationDurationMs ?? -1}ms '
        'cancelled=${cancelToken.isCancelled}',
      );

      session.updatedAt = DateTime.now();
      await _persistSession(session);

      // Append a one-line entry to the chat's tasks.md so the next
      // turn can see what we just did. Best-effort: if the chat
      // didn't actually do anything (no tools, the response was a
      // pure-text Q&A or a clarifying question), skip the append —
      // a "nothing happened" line in the log is just noise.
      // Cancellation aborts the append too: a stopped turn isn't
      // "completed" by any reasonable definition.
      if (!cancelToken.isCancelled && firedAcrossTurn.isNotEmpty) {
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
      // Even on the error path we record timing, because that's
      // where it's MOST diagnostic ("did the turn die at exactly
      // 182s? then it's the cloud wall, not a local bug").
      session.messages.add(
        PersistedMessage(
          role: 'assistant',
          content: ProviderError.marker(err),
          totalDurationMs: DateTime.now()
              .difference(turnStartedAt)
              .inMilliseconds,
          firstByteLatencyMs: firstByteLatencyMs,
          iterationCount: iterationCount > 0 ? iterationCount : null,
          lastIterationDurationMs: lastIterationDurationMs,
          toolMarkerNonce: turnMarkerNonce,
        ),
      );
      debugPrint(
        '[turn-timing:error] sessionId=$sessionId '
        'total=${DateTime.now().difference(turnStartedAt).inMilliseconds}ms '
        'ttfb=${firstByteLatencyMs ?? -1}ms '
        'iters=$iterationCount '
        'lastIter=${lastIterationDurationMs ?? -1}ms '
        'err=$e',
      );
      await _persistSession(session);
    } finally {
      _generatingSessionIds.remove(sessionId);
      _cancelTokens.remove(sessionId);
      _pendingApprovals.remove(sessionId);
      _generationStartedAtBySession.remove(sessionId);
      _lastChunkAtBySession.remove(sessionId);
      // Drop the live ref. By now `_persistSession` has flushed the
      // final content to disk, so future `openSession` calls can
      // safely fall back to the disk-load path.
      _liveSessions.remove(sessionId);
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
