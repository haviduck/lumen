/// Data model + narration logic for the per-agent activity bubble.
///
/// Pure (Flutter-free) types live here so they can be unit-tested
/// without spinning a binding, and so the narration pipeline can be
/// reasoned about independently of the rendering layer.
library;

import '../../../l10n/strings.dart';
import '../../../services/council/council_models.dart';
import '../../../services/council/council_task_ledger.dart';

/// Semantic kind for a transient event flash. Drives the eyebrow
/// label colour and the icon. New event types should map to one of
/// these to keep the visual vocabulary tight.
enum FlashKind {
  dispatch,
  askPool,
  poolReply,
  askUser,
  userReply,
  userPing,
  done,
  error,
  stalled,
  // Structured "currently doing X" signal triggered by a tool fire
  // (read_file / edit_file / run_cmd / web_search / ...). Surfaces the
  // file path or command being worked on without leaking raw model
  // narration into the bubble.
  tool,
  // Subtask plan + step completion flashes. `subtaskPlan` fires once
  // when the agent declares its plan (short, mostly informational).
  // `subtaskProgress` fires after each step — these are the bubble's
  // main "alive" signal during a long task.
  subtaskPlan,
  subtaskProgress,
}

/// A short-lived overlay note on top of the persistent status line.
/// The bubble UI displays the flash text in place of the primary
/// narration until [expiresAt] passes.
class ActivityFlash {
  final String text;
  final FlashKind kind;
  final DateTime expiresAt;

  const ActivityFlash({
    required this.text,
    required this.kind,
    required this.expiresAt,
  });

  bool isExpired(DateTime now) => !now.isBefore(expiresAt);
}

/// Severity tier for the primary narration. Drives the accent colour
/// used by the bubble UI without exposing colour constants to this
/// pure layer.
enum NarrationTone { idle, working, awaiting, alert, success }

/// Composed result of running the narration pipeline for a single
/// agent at a single frame. The bubble UI consumes this directly.
class AgentNarration {
  /// Primary status text. First-person, human voice, ≤ 110 chars.
  final String primary;

  /// Optional secondary line (e.g. "Next: …"). Empty if not useful.
  final String secondary;

  /// Status pill label ("WORKING", "ASKING POOL", …).
  final String statusLabel;

  /// Driving tone — UI maps to colour, icon, border treatment.
  final NarrationTone tone;

  /// True when the agent has produced a chunk recently enough that
  /// the UI should run a typing-indicator pulse.
  final bool streaming;

  /// True when the bubble should auto-fade out (terminal state,
  /// linger window expired). Drives `Opacity` ramp on the host card.
  final bool fading;

  const AgentNarration({
    required this.primary,
    required this.secondary,
    required this.statusLabel,
    required this.tone,
    required this.streaming,
    required this.fading,
  });
}

/// Per-agent live state held by the speech bubbles layer between
/// frames. Tracks chunk timestamps and the currently displayed flash.
class AgentLiveState {
  AgentLiveState({required this.agentId});

  final String agentId;

  /// Most recent chunk delta timestamp. Used to gate the typing
  /// indicator (active if within ~1.5s of the last chunk).
  DateTime? lastChunkAt;

  /// Currently displayed flash overlay (null = no active flash).
  ActivityFlash? flash;

  /// First time we saw this agent in a non-idle state. Drives the
  /// entrance animation timing on the bubble card.
  DateTime? firstActiveAt;

  /// When the agent finished — used to keep the bubble on stage for
  /// a short linger window before fading out.
  DateTime? doneAt;

  /// When the agent erred — used to keep an error bubble visible
  /// longer than a normal flash so the user can react.
  DateTime? erroredAt;
}

/// How long a flash overlay stays on top of the primary line, by kind.
const Map<FlashKind, Duration> kFlashDurations = <FlashKind, Duration>{
  FlashKind.dispatch: Duration(seconds: 4),
  // 2026-05 (voice-panel redesign): pool chatter calmed down. The voice
  // section is now a permanent surface on every agent card, so the
  // ask/reply flash competes with the structural narration. 3.5s reads
  // as "register, then yield" rather than "dominate the panel". Update
  // here is paired with the discourse-layer dial-down in
  // council_discourse_layer.dart — together they're the "calmer pool"
  // pass the user asked for.
  FlashKind.askPool: Duration(milliseconds: 3500),
  FlashKind.poolReply: Duration(milliseconds: 3500),
  FlashKind.askUser: Duration(seconds: 12),
  FlashKind.userReply: Duration(seconds: 6),
  FlashKind.userPing: Duration(seconds: 6),
  FlashKind.done: Duration(seconds: 6),
  FlashKind.error: Duration(seconds: 12),
  FlashKind.stalled: Duration(seconds: 8),
  // Tool flashes are short — they get replaced quickly by the next
  // tool fire on an active agent. 3.5s reads as "currently doing X"
  // without lingering long enough to lie about the state.
  FlashKind.tool: Duration(milliseconds: 3500),
  // Subtask plan is informational; gives the eye a beat to see the
  // shape of the work but yields quickly to the actual primary line
  // (which is now "Step 1/N: <label>" courtesy of narrateAgent).
  FlashKind.subtaskPlan: Duration(seconds: 3),
  // Step-complete flashes get a slightly longer linger than tool
  // flashes — they're the agent's own "I just shipped this" moments
  // and we want the user to register them.
  FlashKind.subtaskProgress: Duration(seconds: 5),
};

/// Linger window for the bubble after the agent reports done before
/// it fades off the stage entirely.
const Duration kDoneLinger = Duration(seconds: 9);

/// Time after the last chunk during which the typing indicator stays
/// lit. Picked to look "alive" without strobing on idle.
const Duration kStreamingHoldover = Duration(milliseconds: 1400);

/// Max length of free-form text pulled out of event payloads. Keep
/// the activity bubble compact — the inspector view exposes the full
/// stream.
const int kFlashSnippetMax = 140;
const int kPrimaryLineMax = 110;
const int kSecondaryLineMax = 80;

/// Strip the markdown patterns that leak through model narration and
/// look ugly inside a single-line speech bubble:
///   • `**bold**` and `__bold__` → bare text (the #1 user complaint —
///     literal asterisks showing up as `**Deliverable**`).
///   • Leading `#` / `##` / `###` heading hashes.
///   • Leading bullet markers (`- `, `* `, `• `) and ordered-list
///     prefixes (`1. `, `2. `).
///   • Stray block-fence markers `~~~` and `<!-- ... -->` HTML comments.
///
/// We deliberately KEEP backticks (`like_this`) — they carry useful
/// "this is a code surface" signal and render fine inline. Single `_`
/// and `*` are also left alone so file paths (`my_file.dart`) and glob
/// patterns (`*.dart`) survive the trip.
String stripMarkdownEmphasis(String s) {
  if (s.isEmpty) return s;
  var out = s;
  // Bold: non-greedy so adjacent **X** **Y** doesn't collapse.
  out = out.replaceAllMapped(
    RegExp(r'\*\*(.+?)\*\*', dotAll: true),
    (m) => m.group(1) ?? '',
  );
  out = out.replaceAllMapped(
    RegExp(r'__(.+?)__', dotAll: true),
    (m) => m.group(1) ?? '',
  );
  // HTML comments (e.g. `<!-- LUMEN_THINK_END -->`) that occasionally
  // bleed through provider response sanitisation.
  out = out.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
  // Heading hashes — only at line start. `#tag` in prose stays.
  out = out.replaceAllMapped(
    RegExp(r'^(\s*)#{1,6}\s+', multiLine: true),
    (m) => m.group(1) ?? '',
  );
  // Bullet / ordered-list prefixes at line start. Bullets show up a lot
  // in agent narration because models default to lists; pulling them
  // off makes the snippet read as a sentence rather than a fragment.
  out = out.replaceAllMapped(
    RegExp(r'^(\s*)(?:[-*\u2022]\s+|\d+\.\s+)', multiLine: true),
    (m) => m.group(1) ?? '',
  );
  return out;
}

String clampSnippet(String s, int max) {
  // Strip markdown emphasis BEFORE collapsing whitespace so the
  // length budget reflects what the user actually sees, and so
  // leftover bullet/heading markers don't strand themselves at the
  // front of the snippet.
  final stripped = stripMarkdownEmphasis(s);
  final clean = stripped.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (clean.length <= max) return clean;
  return '${clean.substring(0, max - 1)}…';
}

/// Compose the agent's first-person narration for the current frame.
///
/// Priority (high → low):
///   1. Active flash overlay (recent newsworthy event).
///   2. Error / stuck state.
///   3. Awaiting user / awaiting pool.
///   4. Asking pool, replying, dispatching, synthesizing.
///   5. Working — pulls task description from the latest task ledger
///      entry or `agent.currentTask` as fallback.
///   6. Done / aborted / idle.
AgentNarration narrateAgent({
  required CouncilAgent agent,
  required CouncilTask? latestTask,
  required AgentLiveState live,
  required bool isOrchestrator,
  required DateTime now,
}) {
  final streaming = live.lastChunkAt != null &&
      now.difference(live.lastChunkAt!) < kStreamingHoldover;
  final fading = live.doneAt != null &&
      now.difference(live.doneAt!) > kDoneLinger;

  // 1) Active flash overlay wins. Status pill keeps reflecting truth.
  final flash = live.flash;
  if (flash != null && !flash.isExpired(now)) {
    final tone = _flashTone(flash.kind);
    return AgentNarration(
      primary: flash.text,
      secondary: _statusSecondary(agent, latestTask, isOrchestrator),
      statusLabel: _statusLabel(agent.status, isOrchestrator),
      tone: tone,
      streaming: streaming && flash.kind != FlashKind.done && flash.kind != FlashKind.error,
      fading: fading,
    );
  }

  // 2) Error.
  if (agent.status == CouncilAgentStatus.error) {
    final err = (latestTask?.lastError ?? agent.lastError).trim();
    return AgentNarration(
      primary: err.isEmpty
          ? S.councilActivityStuck(S.councilAgentNoErrorDetail)
          : S.councilActivityStuck(clampSnippet(err, kPrimaryLineMax - 8)),
      secondary: '',
      statusLabel: S.councilStatusError.toUpperCase(),
      tone: NarrationTone.alert,
      streaming: false,
      fading: false,
    );
  }

  // 3) Awaiting user / awaiting pool.
  if (agent.status == CouncilAgentStatus.awaitingUser) {
    return AgentNarration(
      primary: S.councilActivityAwaitingUser,
      secondary: _waitingOnLine(latestTask),
      statusLabel: S.councilStatusAwaitingUser.toUpperCase(),
      tone: NarrationTone.awaiting,
      streaming: false,
      fading: false,
    );
  }
  if (latestTask?.waitingOn != null &&
      latestTask!.waitingOn!.toLowerCase().contains('pool')) {
    return AgentNarration(
      primary: S.councilActivityAwaitingPool,
      secondary: _nextActionLine(latestTask),
      statusLabel: S.councilStatusAwaitingPool.toUpperCase(),
      tone: NarrationTone.awaiting,
      streaming: streaming,
      fading: false,
    );
  }

  // 4) Asking pool / replying / dispatching / synthesizing.
  if (agent.status == CouncilAgentStatus.askingPool) {
    return AgentNarration(
      primary: S.councilActivityAskingPool,
      secondary: _nextActionLine(latestTask),
      statusLabel: S.councilAgentStatusAskingPool.toUpperCase(),
      tone: NarrationTone.working,
      streaming: streaming,
      fading: false,
    );
  }
  if (agent.status == CouncilAgentStatus.replying) {
    return AgentNarration(
      primary: S.councilActivityReplying,
      secondary: _nextActionLine(latestTask),
      statusLabel: S.councilAgentStatusReplying.toUpperCase(),
      tone: NarrationTone.working,
      streaming: streaming,
      fading: false,
    );
  }

  // 5) Working — strongest "alive" signal, so we narrate richly.
  if (agent.status == CouncilAgentStatus.working) {
    // Subtask-aware branch: when the agent has declared a plan via
    // `council_plan_subtasks`, the bubble narrates real-time step
    // progress instead of a single static "Working on: <brief>" line.
    // This is the most useful "alive" signal we have — it reads as
    // ground truth, not as cosmetic motion.
    final subtasks = latestTask?.subtasks ?? const <String>[];
    if (subtasks.isNotEmpty) {
      final total = subtasks.length;
      final doneRaw = latestTask?.currentSubtaskIndex ?? 0;
      final done = doneRaw < 0 ? 0 : (doneRaw > total ? total : doneRaw);
      final currentIdx = done >= total ? total : done + 1;
      final currentLabel = subtasks[(currentIdx - 1).clamp(0, total - 1)];
      final summaries = latestTask?.subtaskSummaries ?? const <String>[];
      final lastSummary =
          done > 0 && summaries.length >= done ? summaries[done - 1] : '';
      final primary = S.councilActivityStepOf(
        currentIdx,
        total,
        clampSnippet(currentLabel, kPrimaryLineMax - 18),
      );
      final task = (latestTask?.task ?? agent.currentTask).trim();
      final secondary = lastSummary.isNotEmpty
          ? S.councilActivityJustDid(
              clampSnippet(lastSummary, kSecondaryLineMax - 12))
          : (task.isEmpty ? '' : clampSnippet(task, kSecondaryLineMax));
      return AgentNarration(
        primary: primary,
        secondary: secondary,
        statusLabel: S.councilStatusWorking.toUpperCase(),
        tone: NarrationTone.working,
        streaming: streaming,
        fading: false,
      );
    }
    final task = (latestTask?.task ?? agent.currentTask).trim();
    final primary = task.isEmpty
        ? (isOrchestrator
            ? S.councilActivityCoordinating
            : S.councilActivityThinking)
        : S.councilActivityWorkingOn(clampSnippet(task, kPrimaryLineMax - 12));
    return AgentNarration(
      primary: primary,
      secondary: _nextActionLine(latestTask),
      statusLabel: S.councilStatusWorking.toUpperCase(),
      tone: NarrationTone.working,
      streaming: streaming,
      fading: false,
    );
  }

  // 6) Queued / done / idle.
  if (agent.status == CouncilAgentStatus.queued) {
    return AgentNarration(
      primary: S.councilActivityQueued,
      secondary: '',
      statusLabel: S.councilAgentStatusQueued.toUpperCase(),
      tone: NarrationTone.idle,
      streaming: false,
      fading: false,
    );
  }
  if (agent.status == CouncilAgentStatus.done) {
    return AgentNarration(
      primary: S.councilActivityDone,
      secondary: '',
      statusLabel: S.councilStatusDone.toUpperCase(),
      tone: NarrationTone.success,
      streaming: false,
      fading: fading,
    );
  }
  return AgentNarration(
    primary: S.councilActivityIdle,
    secondary: '',
    statusLabel: S.councilStatusIdle.toUpperCase(),
    tone: NarrationTone.idle,
    streaming: streaming,
    fading: fading,
  );
}

NarrationTone _flashTone(FlashKind kind) {
  switch (kind) {
    case FlashKind.error:
    case FlashKind.stalled:
      return NarrationTone.alert;
    case FlashKind.askUser:
    case FlashKind.userReply:
    case FlashKind.userPing:
      return NarrationTone.awaiting;
    case FlashKind.done:
    case FlashKind.subtaskProgress:
      // Each step-done is a tiny success moment — same green-leaning
      // tone as the final `done` flash so the user reads it as a
      // win, not just generic activity.
      return NarrationTone.success;
    case FlashKind.askPool:
    case FlashKind.poolReply:
    case FlashKind.dispatch:
    case FlashKind.tool:
    case FlashKind.subtaskPlan:
      return NarrationTone.working;
  }
}

String _statusLabel(CouncilAgentStatus s, bool isOrchestrator) {
  switch (s) {
    case CouncilAgentStatus.idle:
      return S.councilStatusIdle.toUpperCase();
    case CouncilAgentStatus.queued:
      return S.councilAgentStatusQueued.toUpperCase();
    case CouncilAgentStatus.working:
      return S.councilStatusWorking.toUpperCase();
    case CouncilAgentStatus.askingPool:
      return S.councilAgentStatusAskingPool.toUpperCase();
    case CouncilAgentStatus.awaitingUser:
      return S.councilStatusAwaitingUser.toUpperCase();
    case CouncilAgentStatus.replying:
      return S.councilAgentStatusReplying.toUpperCase();
    case CouncilAgentStatus.done:
      return S.councilStatusDone.toUpperCase();
    case CouncilAgentStatus.error:
      return S.councilStatusError.toUpperCase();
  }
}

String _statusSecondary(
    CouncilAgent agent, CouncilTask? task, bool isOrchestrator) {
  final task0 = (task?.task ?? agent.currentTask).trim();
  if (task0.isNotEmpty) {
    return clampSnippet(task0, kSecondaryLineMax);
  }
  return '';
}

String _waitingOnLine(CouncilTask? t) {
  final w = t?.waitingOn?.trim();
  if (w == null || w.isEmpty) return '';
  return S.councilActivityWaitingOn(clampSnippet(w, kSecondaryLineMax - 12));
}

String _nextActionLine(CouncilTask? t) {
  final next = t?.nextIntendedAction?.trim();
  if (next == null || next.isEmpty) return '';
  return S.councilActivityNextUp(clampSnippet(next, kSecondaryLineMax - 6));
}

/// Maps an `agentToolFire` event onto a flash text. Returns null when
/// the tool isn't user-interesting (e.g. the council protocol tools
/// have their own dedicated flashes, so this layer would never see
/// them here anyway — but the null-return keeps the contract honest).
///
/// The text comes from `S.councilFlash*` constants so it stays in the
/// i18n pipeline. Path/cmd/url is clamped to fit the bubble width.
String? _toolFireFlashText(CouncilEvent event) {
  final toolId = (event.data['toolId'] as String?)?.trim() ?? '';
  final primary =
      (event.data['primaryArg'] as String?)?.trim() ?? '';
  final clampedPrimary = primary.isEmpty
      ? ''
      : clampSnippet(primary, kFlashSnippetMax - 16);
  switch (toolId) {
    case 'read_file':
      return clampedPrimary.isEmpty ? null : S.councilFlashReading(clampedPrimary);
    case 'edit_file':
    case 'multi_edit':
    case 'edit_range':
      return clampedPrimary.isEmpty ? null : S.councilFlashEditing(clampedPrimary);
    case 'create_file':
    case 'append_file':
    case 'move_file':
    case 'copy_file':
    case 'delete_file':
      return clampedPrimary.isEmpty ? null : S.councilFlashWriting(clampedPrimary);
    case 'list_dir':
    case 'tree':
    case 'find_file':
    case 'glob':
      return clampedPrimary.isEmpty
          ? S.councilFlashExploring('.')
          : S.councilFlashExploring(clampedPrimary);
    case 'search_text':
      return clampedPrimary.isEmpty ? null : S.councilFlashSearching(clampedPrimary);
    case 'run_cmd':
    case 'verify':
      return clampedPrimary.isEmpty ? null : S.councilFlashRunning(clampedPrimary);
    case 'web_search':
      return S.councilFlashWebSearch;
    case 'web_fetch':
    case 'check_url':
      return clampedPrimary.isEmpty ? null : S.councilFlashWebFetch(clampedPrimary);
    case 'git_status':
    case 'git_diff':
    case 'git_log':
    case 'git_blame':
      return S.councilFlashGitInspect;
    default:
      // Unknown tool — show the tool name itself rather than swallowing
      // the signal. Keeps the activity surface honest when new tools
      // are added without explicit flash mapping.
      return toolId.isEmpty ? null : S.councilFlashUsingTool(toolId);
  }
}

/// Map a Council event onto a flash, or null if the event doesn't
/// produce a user-visible activity bubble flash. Pure function so
/// the bubble layer can dispatch events without re-implementing the
/// mapping at the call-site.
///
/// `selfAgentId` is the agent the bubble belongs to — we only build a
/// flash when the event semantically targets that agent.
ActivityFlash? flashForEvent({
  required CouncilEvent event,
  required String selfAgentId,
  required DateTime now,
}) {
  Duration durFor(FlashKind k) => kFlashDurations[k] ?? const Duration(seconds: 5);
  ActivityFlash make(FlashKind k, String text) => ActivityFlash(
        text: clampSnippet(text, kFlashSnippetMax),
        kind: k,
        expiresAt: now.add(durFor(k)),
      );

  switch (event.type) {
    case CouncilEventType.askedPool:
      if (event.fromAgentId == selfAgentId) {
        return make(
          FlashKind.askPool,
          S.councilFlashAskedPool(event.message),
        );
      }
      break;
    case CouncilEventType.poolReply:
      if (event.fromAgentId == selfAgentId) {
        return make(
          FlashKind.poolReply,
          S.councilFlashPoolReply(event.message),
        );
      }
      break;
    case CouncilEventType.askedUser:
      if (event.fromAgentId == selfAgentId) {
        return make(
          FlashKind.askUser,
          S.councilFlashAskedUser(event.message),
        );
      }
      break;
    case CouncilEventType.userReply:
      final anchor =
          event.toAgentId.isNotEmpty ? event.toAgentId : event.fromAgentId;
      if (anchor == selfAgentId) {
        return make(
          FlashKind.userReply,
          S.councilFlashUserReply(event.message),
        );
      }
      break;
    case CouncilEventType.userPingedOrchestrator:
    case CouncilEventType.userPingedAgent:
      final anchor =
          event.toAgentId.isNotEmpty ? event.toAgentId : event.fromAgentId;
      if (anchor == selfAgentId) {
        return make(
          FlashKind.userPing,
          S.councilFlashUserPing(event.message),
        );
      }
      break;
    case CouncilEventType.agentDone:
    case CouncilEventType.evaluatorDone:
      if (event.fromAgentId == selfAgentId) {
        return make(FlashKind.done, S.councilFlashFinished);
      }
      break;
    case CouncilEventType.agentError:
      if (event.fromAgentId == selfAgentId) {
        final msg = event.message.isEmpty
            ? S.councilAgentNoErrorDetail
            : event.message;
        return make(FlashKind.error, S.councilFlashError(msg));
      }
      break;
    case CouncilEventType.agentStalled:
      if (event.fromAgentId == selfAgentId) {
        return make(FlashKind.stalled, S.councilFlashStalled);
      }
      break;
    case CouncilEventType.dispatched:
      if (event.toAgentId == selfAgentId) {
        return make(FlashKind.dispatch, S.councilFlashDispatchSelf);
      }
      if (event.fromAgentId == selfAgentId && event.toAgentId.isNotEmpty) {
        return make(
          FlashKind.dispatch,
          S.councilFlashDispatchOut(event.toAgentId),
        );
      }
      break;
    case CouncilEventType.agentToolFire:
      if (event.fromAgentId != selfAgentId) break;
      final text = _toolFireFlashText(event);
      if (text == null) break;
      return make(FlashKind.tool, text);
    case CouncilEventType.agentSubtasksPlanned:
      if (event.fromAgentId != selfAgentId) break;
      final raw = event.data['subtasks'];
      final total = raw is List ? raw.length : 0;
      if (total <= 0) break;
      return make(FlashKind.subtaskPlan, S.councilFlashSubtasksPlanned(total));
    case CouncilEventType.agentSubtaskProgress:
      if (event.fromAgentId != selfAgentId) break;
      final step = (event.data['step'] as num?)?.toInt() ?? 0;
      final total = (event.data['totalSteps'] as num?)?.toInt() ?? 0;
      final summary = (event.data['summary'] as String? ?? '').trim();
      if (step <= 0 || total <= 0) break;
      return make(
        FlashKind.subtaskProgress,
        S.councilFlashSubtaskDone(step, total, summary),
      );
  }
  return null;
}
