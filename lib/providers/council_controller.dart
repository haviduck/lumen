import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../services/anthropic_service.dart';
import '../services/copilot_service.dart';
import '../services/council/council_agent_runner.dart';
import '../services/council/council_models.dart';
import '../services/council/council_persistence_service.dart';
import '../services/council/council_protocol.dart';
import '../services/council/council_task_ledger.dart';
import '../services/council/council_tool_lock.dart';
import '../services/gemini_service.dart';
import '../services/ollama_service.dart';
import '../services/tool_executor.dart';

class CouncilController extends ChangeNotifier {
  CouncilController({
    required this.anthropic,
    required this.copilot,
    required this.gemini,
    required this.ollama,
    required this.persistence,
    required this.isToolAutoApproved,
    this.onReportPersisted,
  });

  final AnthropicService anthropic;
  final CopilotService copilot;
  final GeminiService gemini;
  final OllamaService ollama;
  final CouncilPersistenceService persistence;
  final bool Function(String toolId, String detail) isToolAutoApproved;

  /// Invoked exactly once per council run, AFTER the markdown report has
  /// been successfully written to disk by [persistence.writeReport]. Never
  /// called on abort, error, or transient failures. AppState wires this
  /// to clear the cached wizard brief in prefs so the next council opens
  /// with an empty prompt textbar (Flux/UX brief: "when a council is done
  /// THIS textbar gets cleared").
  final Future<void> Function()? onReportPersisted;

  CouncilSession? _session;
  CouncilSession? get session => _session;
  bool get isActive =>
      _session != null &&
      _session!.status != CouncilStatus.done &&
      _session!.status != CouncilStatus.aborted;

  /// Broadcast stream of every lifecycle event the council emits. Stagecraft
  /// (visual layer) subscribes here for discrete signals — agent_arrived,
  /// link_started/ended, message_sent, agent_thinking_*, reviewer_followup,
  /// awaiting_user_followup, council_round_completed.
  ///
  /// `_event()` writes to both `session.events` (history) and this stream
  /// (live). Never bypass `_event()`.
  final StreamController<CouncilEvent> _eventStream =
      StreamController<CouncilEvent>.broadcast();
  Stream<CouncilEvent> get events => _eventStream.stream;

  bool _theaterVisible = false;
  bool get theaterVisible => _theaterVisible && _session != null;

  String? _workspacePath;
  final CouncilToolLock _toolLock = CouncilToolLock();
  final List<CouncilAgentRunner> _runners = <CouncilAgentRunner>[];
  final List<Future<void>> _dispatches = <Future<void>>[];
  final Map<String, Completer<String>> _userQuestions =
      <String, Completer<String>>{};
  int _activeDispatches = 0;
  int _questionSeq = 0;
  int _linkSeq = 0;
  // Active link ids per (from, to) pair — emitted by link_started, drained
  // by link_ended. Keeps concurrent links between the same pair distinct.
  final Map<String, List<String>> _activeLinks = <String, List<String>>{};
  // Agents that have already emitted `agent_arrived` this run. One-shot.
  final Set<String> _arrivedAgents = <String>{};
  // Per-session task ledger. Owns the planned/dispatched/running/done|failed
  // state machine and powers the report-shipping guard. Recreated on
  // startCouncil; rehydrated from session.tasks on reload.
  CouncilTaskLedger? _ledger;
  CouncilTaskLedger get ledger =>
      _ledger ??= CouncilTaskLedger(onTransition: _onLedgerTransition);
  // Map dispatch-site task ids → ledger task ids so completion/failure
  // callbacks in `_dispatch` can update the right row even for parallel runs.
  final Map<String, String> _taskIdByDispatchKey = <String, String>{};
  Completer<bool>? _roundTwoDecision;
  CouncilAgentRunner? _orchestratorRunner;
  // Pool budget raised from 2 → 6 under the Excellence Doctrine. The
  // review phase wants agents to actually challenge each other; the old
  // ceiling of 2 produced a token-effort review and then a ship.
  static const int _maxPoolExchangesPerSession = 6;
  static const int _maxPoolTargetsPerQuestion = 3;
  final List<String> _queuedSynthesisPings = <String>[];
  int _orchestratorFailureStreak = 0;
  bool _orchestratorFailureEscalated = false;
  // Escalation threshold: only surface to the user after many retries.
  // The orchestrator often self-recovers silently — early escalation
  // just creates noise. 20 retries is the "genuinely broken" signal.
  static const int _orchestratorFailureEscalationThreshold = 20;

  // ===== Excellence Doctrine — budgets =====
  // The council exists to outperform a solo run. Budgets are sized for
  // multi-phase work, not single-wave shipping. Numbers tuned for top-
  // tier models on ambitious briefs; weaker models naturally exit earlier
  // through their own iteration caps.
  static const int _orchestratorMaxIterations = 60;
  static const int _agentMaxIterations = 30;
  static const int _evaluatorMaxIterations = 6;
  // Tool-fire surfaces tracked by the structural quality-gate auto-check.
  // Any agent firing one of these tools (with a write-side effect) counts
  // as "artifacts produced" without the orchestrator having to assert it.
  static const Set<String> _artifactProducingTools = {
    'create_file',
    'edit_file',
    'multi_edit',
    'edit_range',
    'append_file',
    'move_file',
    'copy_file',
    'delete_file',
  };

  /// True when the user is allowed to ping the orchestrator with a
  /// mid-session note. We allow this whenever the council is in a state
  /// where a note can plausibly affect the run.
  ///
  /// - If the orchestrator runner is alive, the note is queued onto its
  ///   message stream and picked up at its next iteration.
  /// - If the runner has already returned (e.g. the orchestrator went
  ///   quiet during `awaitingFollowup`, or finished a wave with nothing
  ///   left to say), the controller resurrects a fresh orchestrator turn
  ///   with a status digest + the note baked in. See [pingOrchestrator].
  ///
  /// Enabled for the whole active run (including synthesizing/followup)
  /// so the user has a steady "talk to orchestrator" channel.
  ///
  /// During `synthesizing`, notes are queued and replayed immediately
  /// after the evaluator pass finishes (to avoid racing `_finishWithReport`).
  bool get canPingOrchestrator {
    final s = _session;
    if (s == null) return false;
    return s.status != CouncilStatus.done && s.status != CouncilStatus.aborted;
  }

  Future<void> startCouncil(CouncilConfig config, String workspacePath) async {
    await abort();
    _workspacePath = workspacePath;
    final normalized = _normalizeConfigTools(config);
    _session = CouncilSession(
      config: normalized,
      status: CouncilStatus.dispatching,
    );
    _theaterVisible = true;
    _arrivedAgents.clear();
    _activeLinks.clear();
    _roundTwoDecision = null;
    _ledger = CouncilTaskLedger(onTransition: _onLedgerTransition);
    _taskIdByDispatchKey.clear();
    _resetOrchestratorFailureWatchdog();
    _event(CouncilEventType.sessionStarted, message: config.brief);
    if (_session!.isPentestMode) {
      _event(CouncilEventType.pentestConspiring);
    }
    notifyListeners();
    await _persist();
    unawaited(_runOrchestrator());
  }

  Future<List<CouncilAgent>> proposeAgentsForBrief({
    required String brief,
    required CouncilAgent orchestrator,
    int? count,
  }) async {
    final targetCount = count ?? _targetAgentCountForBrief(brief);
    final fallback = _fallbackAgentsForBrief(brief, orchestrator.model, count);
    if (brief.trim().isEmpty || orchestrator.model.trim().isEmpty) {
      return fallback;
    }

    final prompt =
        '''
You are designing a compact senior council to ship a real artifact for the brief below. The roster you produce will work in parallel under an orchestrator — choose specialists who genuinely complement each other, not a generic checklist.

Return ONLY JSON. No markdown. Shape:
{
  "agents": [
    {
      "name": "short distinctive name pulled from the brief's domain",
      "role": "pentester|reviewer|researcher|architect|tester|writer|custom",
      "customRole": "specific remit; required when role is custom",
      "mission": "the concrete artifact this agent will produce",
      "rationale": "what unique angle this agent owns for THIS brief"
    }
  ]
}

Rules (the parser enforces several of these):
1. SIZE — $targetCount is the target. 3–8 hard range. Smaller for tight focused asks; larger for ambitious product/platform work.

2. NAMES come from the brief's own vocabulary. Read the brief, extract 3–5 domain nouns, seed the names from them. A brief about "redesign the dashboard onboarding flow" yields names like "Onboarding Choreographer", "Empty-State Stylist", "First-Run Telemetry" — NOT "Architect", "Reviewer", "Tester". Names are short, evocative, and tell the user what they own at a glance.

3. MISSIONS name concrete artifacts. Each mission must name a specific deliverable: a file path, a document, a decision matrix, a diagram, a test suite, a fix list. "Investigate X" / "review Y" / "ensure quality" are NOT missions — they are anti-patterns. Bad: "ensure code quality". Good: "produce `docs/REVIEW.md` with a ranked findings table covering correctness, regression risk, and missing tests".

4. COMPLEMENTARITY — no two agents own the same primary surface. If two agents both want the same file/system/decision, either merge them into one OR pick distinct sub-surfaces. Overlap = duplicate work and confused dispatch.

5. CUSTOM role for anything specific. Built-in role labels (pentester / reviewer / researcher / architect / tester / writer) are coarse — when an agent's real remit is sharper, use `custom` and put the specific remit in `customRole`. Most ambitious briefs will be 50%+ custom roles.

6. PENTESTER only when the brief is genuinely about security / attack surface / threat modeling / hardening / exploitation. Not for "make this pretty" or "refactor". Otherwise the role distorts the council.

7. TESTER when implementation / debugging / correctness validation matters as a first-class concern.

8. ADVERSARIAL FIT — every agent must be capable of meaningfully pushing back on at least one other. If you can't articulate which agent each one would push back against and why, the roster is too soft.

User brief:
$brief
''';

    try {
      final messages = [
        {'role': 'user', 'content': prompt},
      ];
      final split = _splitModel(orchestrator.model);
      if (split.provider == 'github') {
        throw StateError(
          'GitHub Models was removed; please pick another model.',
        );
      }
      final String raw;
      switch (split.provider) {
        case 'claude':
          raw = await anthropic.generateChat(messages, model: split.rawModel);
        case 'copilot':
          raw = await copilot.generateChat(messages, model: split.rawModel);
        case 'gemini':
          raw = await gemini.generateChat(messages, model: split.rawModel);
        case 'ollama-cloud':
          raw = await ollama.generateChat(
            messages,
            model: split.rawModel,
            forceCloud: true,
          );
        case 'ollama':
          raw = await ollama.generateChat(messages, model: split.rawModel);
        default:
          throw StateError(
            'Council propose-agents: unsupported provider "${split.provider}".',
          );
      }
      final parsed = _parseProposedAgents(raw, orchestrator.model);
      return parsed.length >= 2 ? parsed : fallback;
    } catch (_) {
      return fallback;
    }
  }

  void showTheater() {
    if (_session == null) return;
    _theaterVisible = true;
    notifyListeners();
  }

  void hideTheater() {
    _theaterVisible = false;
    notifyListeners();
  }

  Future<void> abort() async {
    // Snapshot runners before clearing — cancel every token first so
    // in-flight streams see `isCancelled` immediately, even for runners
    // that were spawned in pool-reply or evaluator paths.
    final snapshot = List<CouncilAgentRunner>.from(_runners);
    for (final runner in snapshot) {
      runner.token.cancel();
    }
    if (_session != null && isActive) {
      _session!.status = CouncilStatus.aborted;
      _session!.finishedAt = DateTime.now();
      for (final agent in _session!.config.allAgents) {
        if (agent.status != CouncilAgentStatus.done &&
            agent.status != CouncilAgentStatus.error) {
          agent.status = CouncilAgentStatus.idle;
        }
      }
      _event(CouncilEventType.aborted);
      await _persist();
    }
    _runners.clear();
    _dispatches.clear();
    _userQuestions.clear();
    _activeLinks.clear();
    _arrivedAgents.clear();
    _queuedSynthesisPings.clear();
    _ledger?.cancelAll(reason: 'aborted');
    _taskIdByDispatchKey.clear();
    _resetOrchestratorFailureWatchdog();
    _activeDispatches = 0;
    _orchestratorRunner = null;
    final pending = _roundTwoDecision;
    _roundTwoDecision = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    // Complete any pending user-question completers so awaiting code
    // unblocks instead of hanging forever after abort.
    for (final c in _userQuestions.values) {
      if (!c.isCompleted) c.complete('');
    }
    _userQuestions.clear();
    notifyListeners();
  }

  Future<void> answerPendingUserQuestion(
    String answer, {
    List<String> images = const [],
  }) async {
    final question = _session?.pendingUserQuestion;
    if (question == null) return;
    question.userAnswer = answer;
    question.resolved = true;
    _session!.pendingUserQuestion = null;
    _event(
      CouncilEventType.userReply,
      toAgentId: question.fromAgentId,
      message: answer,
    );
    _emitMessage(
      kind: CouncilMessageKind.userReply,
      from: 'user',
      to: question.fromAgentId,
      text: answer,
    );
    _userQuestions.remove(question.id)?.complete(answer);
    // The asking-agent path receives only the string answer through the
    // tool result (council_protocol). Attached images can't ride that
    // channel without a protocol change, so we also splice them into
    // the orchestrator runner as a parallel user-note so they reach
    // the agents in the next iteration. The text answer is intentionally
    // kept on the tool-result path for backward compatibility.
    if (images.isNotEmpty) {
      _orchestratorRunner?.addUserNote(
        'Attachment(s) from user reply to ${question.fromAgentId}: '
        '${answer.isEmpty ? '(no text)' : answer}',
        images: images,
      );
    }
    _session!.status = CouncilStatus.working;
    notifyListeners();
    await _persist();
  }

  /// User confirmed running round two with the reviewer's findings folded in.
  /// Re-runs the orchestrator with the structured followup baked into prompts.
  Future<void> confirmRoundTwo() async {
    final session = _session;
    if (session == null) return;
    final followup = session.reviewerFollowup;
    if (followup == null) return;
    final pending = _roundTwoDecision;
    _roundTwoDecision = null;
    if (pending != null && !pending.isCompleted) pending.complete(true);

    session.roundIndex = followup.roundIndex;
    session.status = CouncilStatus.dispatching;
    _event(
      CouncilEventType.roundTwoStarted,
      message: followup.summary,
      data: {'roundIndex': session.roundIndex},
    );
    notifyListeners();
    await _persist();
    unawaited(_runOrchestrator(roundFollowup: followup));
  }

  /// User declined round two. The council transitions to `done` but the
  /// theater stays open until `closeCouncil()` is invoked explicitly.
  Future<void> declineRoundTwo() async {
    final session = _session;
    if (session == null) return;
    final pending = _roundTwoDecision;
    _roundTwoDecision = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
    session.status = CouncilStatus.done;
    session.finishedAt ??= DateTime.now();
    _event(
      CouncilEventType.councilRoundCompleted,
      data: {'roundIndex': session.roundIndex, 'final': true},
    );
    notifyListeners();
    await _persist();
  }

  /// Explicit user close. The ONLY path that hides the theater post-report.
  /// Auto-close on report generation was removed by design.
  Future<void> closeCouncil() async {
    final session = _session;
    if (session != null) {
      if (session.status != CouncilStatus.aborted &&
          session.status != CouncilStatus.done) {
        session.status = CouncilStatus.done;
        session.finishedAt ??= DateTime.now();
      }
      _event(CouncilEventType.councilClosed);
      await _persist();
    }
    _theaterVisible = false;
    notifyListeners();
  }

  Future<void> _runOrchestrator({
    ReviewerFollowup? roundFollowup,
    String kickNote = '',
  }) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return;

    session.status = CouncilStatus.dispatching;
    session.config.orchestrator.status = CouncilAgentStatus.working;
    _emitArrival(session.config.orchestrator);
    _emitThinkingStarted(session.config.orchestrator);
    notifyListeners();

    final userPrompt = _buildOrchestratorUserPrompt(
      session: session,
      roundFollowup: roundFollowup,
      kickNote: kickNote,
    );

    // Only the very first orchestrator run (fresh start, no kick / no
    // follow-up) gets the brief's image attachments folded into the
    // initial user turn. Resurrection / round-two re-entries reuse the
    // session's existing context and must not re-paste images.
    final isFreshStart =
        kickNote.trim().isEmpty && roundFollowup == null;
    final initialImages = isFreshStart
        ? List<String>.from(session.config.briefImages)
        : const <String>[];

    final runner = CouncilAgentRunner(
      agent: session.config.orchestrator,
      anthropic: anthropic,
      copilot: copilot,
      gemini: gemini,
      ollama: ollama,
      toolExecutor: _toolExecutor(session.config.orchestrator, workspace),
      systemPrompt: CouncilProtocol.orchestratorSystemPrompt(session.config),
      userPrompt: userPrompt,
      userImages: initialImages,
      nativeToolIds: {...CouncilProtocol.orchestratorToolIds},
      onChunk: (chunk) => _appendTranscript(session.config.orchestrator, chunk),
      onCouncilTool: _handleOrchestratorTool,
      onStall: _onAgentStall,
      stallTimeoutSeconds: 90,
      onToolFire: _onAgentToolFire,
    );
    _runners.add(runner);
    _orchestratorRunner = runner;
    notifyListeners();
    var thinkingEnded = false;
    void endThinking() {
      if (thinkingEnded) return;
      thinkingEnded = true;
      _emitThinkingEnded(session.config.orchestrator);
    }
    try {
      final result = await runner.run(maxIterations: _orchestratorMaxIterations);
      endThinking();
      if (result.cancelled) return;
      if (session.status == CouncilStatus.done ||
          session.status == CouncilStatus.awaitingFollowup ||
          session.status == CouncilStatus.aborted) {
        _resetOrchestratorFailureWatchdog();
        return;
      }

      // If we reach here, the orchestrator exited without calling
      // council_report (which sets status to done/awaitingFollowup).
      // This is ALWAYS an incomplete run — the orchestrator either:
      //   - Got wait results and stopped without dispatching wave 2
      //   - Produced synthesis text but forgot to call council_report
      //   - Hit maxIterations without finishing
      // In all cases: re-nudge. council_report is the only legitimate exit.
      final earlyFailureReason = _orchestratorEarlyExitReason(session) ??
          'Orchestrator exited without calling council_report. '
          'Either dispatch follow-up work or finalize via council_report.';
      await _handleOrchestratorFailure(
        session: session,
        reason: earlyFailureReason,
        draftReport: result.content,
      );
    } catch (e) {
      endThinking();
      await _handleOrchestratorFailure(
        session: session,
        reason: 'Orchestrator runner error: $e',
        draftReport: '',
      );
    } finally {
      if (identical(_orchestratorRunner, runner)) {
        _orchestratorRunner = null;
        notifyListeners();
      }
    }
  }

  String? _orchestratorEarlyExitReason(CouncilSession session) {
    // If the orchestrator exits while tasks are still active, that is not a
    // true terminal state; we should nudge it back in instead of failing fast.
    if (ledger.pendingCount > 0 || _activeDispatches > 0) {
      return 'Orchestrator returned early while ${ledger.pendingCount} task(s) are still in flight.';
    }
    // No dispatch at all is usually a no-op drift; attempt silent recovery
    // before declaring a failed run.
    if (!ledger.anyDispatchAttempted) {
      return 'Orchestrator returned without dispatching any agent tasks.';
    }
    return null;
  }

  /// Detects transient API/network errors worth retrying after a delay.
  static bool _isTransientError(String reason) {
    final lower = reason.toLowerCase();
    return lower.contains('500') ||
        lower.contains('502') ||
        lower.contains('503') ||
        lower.contains('504') ||
        lower.contains('internal server error') ||
        lower.contains('bad gateway') ||
        lower.contains('service unavailable') ||
        lower.contains('gateway timeout') ||
        lower.contains('connection reset') ||
        lower.contains('connection refused') ||
        lower.contains('connection closed') ||
        lower.contains('socket') ||
        lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('econnrefused') ||
        lower.contains('network');
  }

  Future<void> _handleOrchestratorFailure({
    required CouncilSession session,
    required String reason,
    required String draftReport,
  }) async {
    _orchestratorFailureStreak++;
    final strikes = _orchestratorFailureStreak;
    final orch = session.config.orchestrator;

    // Backoff for transient API errors — don't hammer a downed service.
    if (_isTransientError(reason)) {
      final delaySecs = (strikes * 5).clamp(5, 30);
      _event(
        CouncilEventType.agentError,
        fromAgentId: orch.id,
        message: 'Transient error, retrying in ${delaySecs}s '
            '(attempt $strikes)...',
      );
      notifyListeners();
      await Future<void>.delayed(Duration(seconds: delaySecs));
      // Bail if session was aborted/done while we waited.
      if (session.status == CouncilStatus.done ||
          session.status == CouncilStatus.aborted) {
        return;
      }
    }

    // First/second strike: silently re-nudge orchestration with richer status.
    if (strikes < _orchestratorFailureEscalationThreshold) {
      session.status = CouncilStatus.working;
      orch.status = CouncilAgentStatus.working;
      notifyListeners();
      await _persist();
      final draft = draftReport.trim();
      final cutoff = draft.length > 400 ? 400 : draft.length;
      final draftSnippet = draft.isEmpty
          ? ''
          : '\n\nLatest orchestrator prose (trimmed):\n'
                '${draft.substring(0, cutoff)}';
      final note = '''
SYSTEM: You exited without calling council_report. Resume now.

Reason: $reason
$draftSnippet

DEFAULT NEXT ACTION: call council_report with a complete markdown synthesis of the work that already returned.

Only dispatch another wave if the original brief explicitly requires a phase you have NOT executed yet (e.g. design wave done → now implementation depending on the design output). Do NOT re-dispatch agents on work that already returned — the dispatch guard will reject identical re-runs.

If a real blocker prevents synthesis, call council_ask_user with a concrete ship-partial / retry-narrower / abort choice. Don't ask process questions like "should I wait" or "ship as they come" — make that call yourself.

You MUST call a tool. No prose-only output.
''';
      unawaited(_runOrchestrator(kickNote: note));
      return;
    }

    // Third strike: escalate to user, but also auto-nudge so the
    // orchestrator can self-recover while the user reads the modal.
    if (_orchestratorFailureEscalated) return;
    _orchestratorFailureEscalated = true;
    orch
      ..status = CouncilAgentStatus.error
      ..lastError = reason;
    _event(
      CouncilEventType.agentError,
      fromAgentId: orch.id,
      message: reason,
      data: {'orchestratorFailureStrikes': strikes},
    );
    notifyListeners();
    await _persist();

    // Fire the user modal and an auto-nudge in parallel. Whichever
    // resolves first wins: if the nudge recovers the orchestrator the
    // modal is dismissed automatically; if the user answers first
    // their directive feeds the re-kick.
    final askFuture = _askUser(
      orch.id,
      CouncilToolCall(
        id: 'orchestrator_fail_$strikes',
        name: CouncilProtocol.askUserToolId,
        arguments: {
          'question': S.councilOrchestratorFailureEscalationQuestion(strikes),
        },
      ),
    );

    // Background: attempt an auto-nudge restart while the user reads
    // the modal. If it succeeds the session moves to working/done and
    // we dismiss the pending question so the modal disappears.
    unawaited(_autoNudgeWhileAskingUser(
      askFuture: askFuture,
      reason: reason,
      draftReport: draftReport,
    ));
  }

  /// Runs alongside the user-facing escalation modal. Kicks the
  /// orchestrator with a rich status nudge; if the orchestrator
  /// recovers (session leaves `awaitingUser`), the pending user
  /// question is auto-dismissed.
  Future<void> _autoNudgeWhileAskingUser({
    required Future<CouncilToolResult> askFuture,
    required String reason,
    required String draftReport,
  }) async {
    final session = _session;
    if (session == null) return;

    final draft = draftReport.trim();
    final cutoff = draft.length > 400 ? 400 : draft.length;
    final draftSnippet = draft.isEmpty
        ? ''
        : '\n\nLatest orchestrator prose (trimmed):\n'
              '${draft.substring(0, cutoff)}';
    final note = '''
Auto-recovery nudge (user has been prompted but orchestrator should try to self-recover).

Last failure signal:
$reason
$draftSnippet

Do NOT finalize yet. Resume orchestration, wait for in-flight work, and continue dispatching/synthesizing as needed.
''';

    // Brief pause so the UI has time to show the modal before the
    // orchestrator restart flips the session status.
    await Future<void>.delayed(const Duration(seconds: 2));
    if (_session == null ||
        _session!.status == CouncilStatus.done ||
        _session!.status == CouncilStatus.aborted) {
      return;
    }

    // Kick the orchestrator — sets status back to dispatching/working.
    session.status = CouncilStatus.working;
    session.config.orchestrator.status = CouncilAgentStatus.working;
    notifyListeners();
    unawaited(_runOrchestrator(kickNote: note));

    // If the orchestrator recovers before the user answers, dismiss
    // the pending question so the modal closes automatically.
    await Future<void>.delayed(const Duration(seconds: 8));
    final q = _session?.pendingUserQuestion;
    if (q != null && _session?.status != CouncilStatus.awaitingUser) {
      _session!.pendingUserQuestion = null;
      _userQuestions.remove(q.id)?.complete(S.councilAutoNudgeRecovered);
      notifyListeners();
    }
  }

  void _resetOrchestratorFailureWatchdog() {
    _orchestratorFailureStreak = 0;
    _orchestratorFailureEscalated = false;
  }

  /// Stall callback shared by all agent runners. Fires when a runner's
  /// stream has been silent for its configured timeout. Returns true to
  /// auto-nudge the runner, false to leave it alone.
  bool _onAgentStall(String agentId, int silentSeconds) {
    final session = _session;
    if (session == null) return false;
    if (session.status == CouncilStatus.aborted ||
        session.status == CouncilStatus.done) {
      return false;
    }
    // Don't report stalls when the session is waiting for user input —
    // the silence is expected and the agent isn't stuck.
    if (session.status == CouncilStatus.awaitingUser ||
        session.status == CouncilStatus.awaitingFollowup) {
      return false;
    }
    // Don't report stalls for agents that are done or awaiting user.
    final agent = session.agentById(agentId);
    if (agent != null &&
        (agent.status == CouncilAgentStatus.done ||
         agent.status == CouncilAgentStatus.awaitingUser ||
         agent.status == CouncilAgentStatus.idle)) {
      return false;
    }
    _event(
      CouncilEventType.agentStalled,
      fromAgentId: agentId,
      message: S.councilAgentStalledMessage(silentSeconds),
      data: {'silentSeconds': silentSeconds},
    );
    notifyListeners();
    return true;
  }

  /// Builds the orchestrator's user-turn prompt for `_runOrchestrator`.
  ///
  /// Three flavors:
  /// - Fresh start: "Begin the Council session now."
  /// - Round two (reviewer follow-up confirmed): the round-two
  ///   addendum from [CouncilProtocol.roundTwoBriefAddendum].
  /// - Resurrection (kick): a status digest of agent transcripts +
  ///   pool exchanges + the user's note, so the resurrected
  ///   orchestrator wakes up with a complete picture rather than
  ///   restarting from scratch.
  ///
  /// When both a round follow-up AND a kick note are present (the
  /// user pings during `awaitingFollowup`), both are included.
  String _buildOrchestratorUserPrompt({
    required CouncilSession session,
    required ReviewerFollowup? roundFollowup,
    required String kickNote,
  }) {
    if (kickNote.trim().isEmpty && roundFollowup == null) {
      final docs = session.config.briefDocs;
      final imageCount = session.config.briefImages.length;
      if (docs.isEmpty && imageCount == 0) {
        return 'Begin the Council session now.';
      }
      final buf = StringBuffer('Begin the Council session now.');
      if (imageCount > 0) {
        buf
          ..writeln()
          ..writeln()
          ..writeln(
            'The user attached $imageCount image${imageCount == 1 ? '' : 's'} '
            'to this brief. They are included as vision inputs on this very '
            'turn — read them as primary context, not decoration.',
          );
      }
      for (final doc in docs) {
        buf
          ..writeln()
          ..writeln()
          ..writeln(
            '<attached-doc filename="${doc.name}" size="${doc.size}">',
          )
          ..writeln(doc.content)
          ..writeln('</attached-doc>');
      }
      return buf.toString();
    }

    final buf = StringBuffer();
    if (kickNote.trim().isNotEmpty) {
      final isSystemNudge = kickNote.trimLeft().startsWith('SYSTEM:');
      if (isSystemNudge) {
        // System nudge — keep it tight and directive. Don't confuse
        // weaker models with "previously-started session" framing.
        buf
          ..writeln(kickNote.trim())
          ..writeln()
          ..writeln('=== Current agent status ===')
          ..writeln(_orchestratorStatusDigest(session));
        // If agents are working, tell the model to wait for them.
        final workingAgents = session.config.agents
            .where((a) => a.status == CouncilAgentStatus.working)
            .toList();
        if (workingAgents.isNotEmpty) {
          buf.writeln(
            '\n${workingAgents.length} agent(s) are still working. '
            'Call council_wait to collect their results, then dispatch '
            'follow-up work or council_report.',
          );
        }
      } else {
        // User ping / resurrection — full context.
        buf
          ..writeln(S.councilOrchestratorKickHeader)
          ..writeln()
          ..writeln(S.councilOrchestratorKickStatusHeading)
          ..writeln(_orchestratorStatusDigest(session))
          ..writeln();
        final poolBlock = _orchestratorPoolDigest(session);
        if (poolBlock.isNotEmpty) {
          buf
            ..writeln(S.councilOrchestratorKickPoolHeading)
            ..writeln(poolBlock)
            ..writeln();
        }
        buf
          ..writeln(S.councilOrchestratorKickNoteHeading)
          ..writeln(kickNote.trim())
          ..writeln()
          ..writeln(S.councilOrchestratorKickInstructions);
      }
    }

    if (roundFollowup != null) {
      if (buf.isNotEmpty) buf.writeln();
      buf
        ..writeln(
          'Begin Council ROUND ${roundFollowup.roundIndex + 1}. The '
          "reviewer's findings below MUST be addressed by the affected "
          'agents. Re-dispatch the relevant agents with the directives '
          'folded in.',
        )
        ..writeln()
        ..writeln(CouncilProtocol.roundTwoBriefAddendum(roundFollowup));
    }

    return buf.toString();
  }

  /// Compact per-agent digest of where the council stands. Used in the
  /// resurrected orchestrator's user prompt so it doesn't have to guess.
  String _orchestratorStatusDigest(CouncilSession session) {
    final lines = <String>[
      'Round: ${session.roundIndex}',
      'Status: ${session.status.name}',
      'Agents:',
    ];
    for (final agent in session.config.agents) {
      final snippet = _summariseTranscript(agent.transcript);
      final task = agent.currentTask.trim().isEmpty
          ? '(no current task)'
          : agent.currentTask.trim();
      lines.add(
        '- ${agent.id} (${agent.name}, ${CouncilProtocol.roleInstruction(agent).split('.').first}): '
        'status=${agent.status.name}, task="$task"'
        '${snippet.isEmpty ? '' : ', last="$snippet"'}',
      );
    }
    return lines.join('\n');
  }

  /// Compact pool-question digest. Empty string when no pool exchanges
  /// have happened yet — keeps the resurrection prompt tight.
  String _orchestratorPoolDigest(CouncilSession session) {
    if (session.poolQuestions.isEmpty) return '';
    final buf = StringBuffer();
    for (final q in session.poolQuestions) {
      final asker = session.agentById(q.fromAgentId)?.name ?? q.fromAgentId;
      buf.writeln('- Q (from $asker): ${q.question}');
      for (final r in q.replies) {
        final replier = session.agentById(r.fromAgentId)?.name ?? r.fromAgentId;
        buf.writeln('    $replier: ${r.answer}');
      }
    }
    return buf.toString().trimRight();
  }

  /// Inject a mid-session note from the user into the orchestrator.
  ///
  /// Two paths:
  /// 1. **Live runner** — the note is queued on the runner's message
  ///    stream and picked up at its next iteration boundary. This is
  ///    the original ping behavior and is the cheapest path.
  /// 2. **Dead runner, alive session** — the orchestrator has returned
  ///    (e.g. it dispatched wave 1 in parallel and had nothing more to
  ///    say, or the council is in `awaitingFollowup`). The note can't
  ///    be queued anywhere, so we resurrect a fresh orchestrator turn
  ///    with a status digest of agent transcripts + pool exchanges +
  ///    the user's note. The orchestrator wakes up, sees what happened
  ///    while it was idle, and decides what to do.
  ///
  /// Path 2 is what makes "the user is the watchdog" honest: the user
  /// can always force the orchestrator to react, even if our protocol
  /// would otherwise have left the council parked.
  ///
  /// No-op when the council is not in a ping-legal state (see
  /// [canPingOrchestrator]) or when the message + attachments are
  /// empty.
  /// True when the user can ping a specific agent. Allowed as long as
  /// the session is running — the note will either be injected into a
  /// live runner OR routed through the orchestrator for re-dispatch.
  bool canPingAgent(String agentId) {
    final s = _session;
    if (s == null) return false;
    if (s.status == CouncilStatus.done || s.status == CouncilStatus.aborted) {
      return false;
    }
    final agent = s.agentById(agentId);
    if (agent == null) return false;
    // Don't allow pinging the orchestrator through this path.
    if (agent.id == s.config.orchestrator.id) return false;
    return true;
  }

  /// Inject a mid-session note targeted at a specific agent.
  ///
  /// Two paths:
  /// 1. **Live runner** — note is queued directly on the agent's
  ///    message stream (picked up at next iteration).
  /// 2. **No live runner** — note is routed through the orchestrator
  ///    as a directive to re-dispatch or address the agent. This is
  ///    the common case since agent runners are short-lived.
  Future<void> pingAgent(
    String agentId,
    String note, {
    List<String> images = const [],
  }) async {
    final session = _session;
    if (session == null) return;
    if (!canPingAgent(agentId)) return;
    final trimmed = note.trim();
    if (trimmed.isEmpty && images.isEmpty) return;

    final eventMessage = images.isEmpty
        ? trimmed
        : '$trimmed [+${images.length} image(s) attached]';
    _event(
      CouncilEventType.userPingedAgent,
      toAgentId: agentId,
      message: eventMessage,
    );

    // Try direct injection into a live runner first.
    final liveRunner = _runners.cast<CouncilAgentRunner?>().firstWhere(
      (r) => r!.agent.id == agentId && !r.token.isCancelled,
      orElse: () => null,
    );
    if (liveRunner != null) {
      liveRunner.addUserNote(trimmed, images: images);
      notifyListeners();
      await _persist();
      return;
    }

    // No live runner — route through the orchestrator so it can
    // re-dispatch the agent with the user's note incorporated.
    final agent = session.agentById(agentId);
    final agentName = agent?.name ?? agentId;
    final orchestratorNote =
        'USER NOTE for $agentName: "$trimmed"\n\n'
        'The user wants to direct this at $agentName specifically. '
        'Re-dispatch $agentName with this note incorporated into their '
        'task, or address it in your next synthesis.';
    await pingOrchestrator(orchestratorNote, images: images);
  }

  Future<void> pingOrchestrator(
    String note, {
    List<String> images = const [],
  }) async {
    final session = _session;
    if (session == null) return;
    if (!canPingOrchestrator) return;
    final trimmed = note.trim();
    if (trimmed.isEmpty && images.isEmpty) return;

    final eventMessage = images.isEmpty
        ? trimmed
        : '$trimmed [+${images.length} image(s) attached]';

    final liveRunner = _orchestratorRunner;
    if (liveRunner != null) {
      liveRunner.addUserNote(trimmed, images: images);
      _event(
        CouncilEventType.userPingedOrchestrator,
        toAgentId: session.config.orchestrator.id,
        message: eventMessage,
      );
      notifyListeners();
      await _persist();
      return;
    }

    _event(
      CouncilEventType.userPingedOrchestrator,
      toAgentId: session.config.orchestrator.id,
      message: eventMessage,
      data: const {'resurrect': true},
    );
    if (session.status == CouncilStatus.synthesizing) {
      final queued = images.isEmpty
          ? trimmed
          : (trimmed.isEmpty
                ? '(user attached ${images.length} image(s) during evaluator pass)'
                : '$trimmed\n\n(plus ${images.length} image(s) attached during evaluator pass)');
      _queuedSynthesisPings.add(queued);
      notifyListeners();
      await _persist();
      return;
    }
    notifyListeners();
    await _persist();
    // Resurrect the orchestrator with a status digest + the user's
    // note. If the session is sitting on a reviewer follow-up (round
    // two pending), pass it along so the orchestrator wakes up with
    // both the reviewer's findings AND the user's note in scope.
    final kickNote = images.isEmpty
        ? trimmed
        : (trimmed.isEmpty
              ? '(user attached ${images.length} image(s); attachments are not '
                    'forwarded on a resurrected orchestrator turn — ask the '
                    'user to resend after this turn if you need to see them)'
              : '$trimmed\n\n(plus ${images.length} image(s) the user '
                    'attached; attachments are not forwarded on a '
                    'resurrected orchestrator turn — ask for a resend if '
                    'you need to see them)');
    unawaited(
      _runOrchestrator(
        roundFollowup: session.reviewerFollowup,
        kickNote: kickNote,
      ),
    );
  }

  ({String provider, String rawModel}) _splitModel(String model) {
    final idx = model.indexOf(':');
    if (idx < 0) return (provider: model, rawModel: model);
    return (
      provider: model.substring(0, idx),
      rawModel: model.substring(idx + 1),
    );
  }

  List<CouncilAgent> _parseProposedAgents(String raw, String model) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) return const <CouncilAgent>[];
    final json =
        jsonDecode(raw.substring(start, end + 1)) as Map<String, dynamic>;
    final agents = (json['agents'] as List?) ?? const [];
    return agents.whereType<Map>().take(8).toList().asMap().entries.map((
      entry,
    ) {
      final data = entry.value.cast<String, dynamic>();
      final role = _roleFromName(data['role'] as String?) ?? RolePreset.custom;
      final customRole = data['customRole'] as String? ?? '';
      final mission = data['mission'] as String? ?? '';
      final rationale = data['rationale'] as String? ?? '';
      return CouncilAgent(
        id: 'agent_${entry.key}',
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? (data['name'] as String).trim()
            : 'Agent ${entry.key + 1}',
        role: role,
        customRole: _joinRoleParts(customRole, mission, rationale),
        model: model,
        enabledTools: kCouncilDefaultTools,
      );
    }).toList();
  }

  String _joinRoleParts(String customRole, String mission, String rationale) {
    final parts = [
      if (customRole.trim().isNotEmpty) customRole.trim(),
      if (mission.trim().isNotEmpty) 'Mission: ${mission.trim()}',
      if (rationale.trim().isNotEmpty) 'Why here: ${rationale.trim()}',
    ];
    return parts.join('\n');
  }

  List<CouncilAgent> _fallbackAgentsForBrief(
    String brief,
    String model,
    int? count,
  ) {
    final b = brief.toLowerCase();
    final targetCount = count ?? _targetAgentCountForBrief(brief);
    final ambitiousIde =
        (b.contains('ide') || b.contains('agentic') || b.contains('cursor')) &&
        (b.contains('masterpiece') ||
            b.contains('above') ||
            b.contains('impactful') ||
            b.contains('complete') ||
            b.contains('unfinished'));
    final specs = ambitiousIde
        ? <({String name, RolePreset role, String customRole})>[
            (
              name: S.councilFallbackProductOps,
              role: RolePreset.custom,
              customRole: S.councilFallbackProductOpsRole,
            ),
            (
              name: S.councilFallbackAgentCore,
              role: RolePreset.custom,
              customRole: S.councilFallbackAgentCoreRole,
            ),
            (
              name: S.councilFallbackCodeCarto,
              role: RolePreset.researcher,
              customRole: S.councilFallbackCodeCartoRole,
            ),
            (
              name: S.councilFallbackFlowDesign,
              role: RolePreset.custom,
              customRole: S.councilFallbackFlowDesignRole,
            ),
            (
              name: S.councilFallbackReliability,
              role: RolePreset.tester,
              customRole: S.councilFallbackReliabilityRole,
            ),
            (
              name: S.councilFallbackPlatform,
              role: RolePreset.custom,
              customRole: S.councilFallbackPlatformRole,
            ),
            (
              name: S.councilFallbackSafety,
              role: RolePreset.pentester,
              customRole: S.councilFallbackSafetyRole,
            ),
            (
              name: S.councilFallbackSkeptic,
              role: RolePreset.reviewer,
              customRole: S.councilFallbackSkepticRole,
            ),
          ]
        : _defaultFallbackSpecs(b);
    return specs.take(targetCount).toList().asMap().entries.map((entry) {
      final spec = entry.value;
      return CouncilAgent(
        id: 'agent_${entry.key}',
        name: spec.name,
        role: spec.role,
        customRole: spec.customRole,
        model: model,
        enabledTools: kCouncilDefaultTools,
      );
    }).toList();
  }

  int _targetAgentCountForBrief(String brief) {
    final b = brief.toLowerCase();
    var score = 0;
    for (final word in [
      'masterpiece',
      'above cursor',
      'agentic',
      'ide',
      'complete',
      'unfinished',
      'many agents',
      'work together',
      'impactful',
      'platform',
      'security',
      'pentest',
      'huge',
    ]) {
      if (b.contains(word)) score++;
    }
    if (score >= 5) return 8;
    if (score >= 3) return 6;
    if (score >= 1) return 5;
    return 4;
  }

  List<({String name, RolePreset role, String customRole})>
  _defaultFallbackSpecs(String briefLower) {
    // Pentester fallback fires only when the brief is unambiguously
    // security/CTF-flavored. Bare "auth" / "secret" leaked into mundane
    // code-review tasks ("review the auth helper for clarity") that
    // didn't actually need an attacker mindset — the lazy-mode prompt
    // already tells the model "include pentester only when... is
    // relevant", so this fallback only catches the safety net case.
    final wantsPentester =
        briefLower.contains('pentest') ||
        briefLower.contains('penetration') ||
        briefLower.contains('threat model') ||
        briefLower.contains('attack surface') ||
        briefLower.contains('red team') ||
        briefLower.contains('exploit') ||
        briefLower.contains('vuln') ||
        briefLower.contains('owasp') ||
        briefLower.contains(' ctf') ||
        briefLower.startsWith('ctf') ||
        briefLower.contains('capture the flag');
    return [
      if (wantsPentester)
        (
          name: _roleName(RolePreset.pentester),
          role: RolePreset.pentester,
          customRole: '',
        ),
      (
        name: _roleName(RolePreset.architect),
        role: RolePreset.architect,
        customRole: '',
      ),
      (
        name: _roleName(RolePreset.reviewer),
        role: RolePreset.reviewer,
        customRole: '',
      ),
      (
        name: _roleName(RolePreset.tester),
        role: RolePreset.tester,
        customRole: '',
      ),
      (
        name: _roleName(RolePreset.researcher),
        role: RolePreset.researcher,
        customRole: '',
      ),
      (
        name: S.councilFallbackSkeptic,
        role: RolePreset.reviewer,
        customRole: S.councilFallbackSkepticRole,
      ),
      (
        name: S.councilFallbackPlatform,
        role: RolePreset.custom,
        customRole: S.councilFallbackPlatformRole,
      ),
      if (briefLower.contains('doc') || briefLower.contains('report'))
        (
          name: _roleName(RolePreset.writer),
          role: RolePreset.writer,
          customRole: '',
        ),
    ];
  }

  CouncilAgent _defaultFinalEvaluator(String model) {
    return CouncilAgent(
      id: 'final_evaluator',
      name: S.councilFinalEvaluator,
      role: RolePreset.reviewer,
      customRole: S.councilFinalEvaluatorRole,
      model: model,
      enabledTools: kCouncilDefaultTools,
    );
  }

  Future<CouncilToolResult> _handleOrchestratorTool(
    CouncilToolCall call,
  ) async {
    switch (call.name) {
      case CouncilProtocol.dispatchToolId:
        return _dispatch(call);
      case CouncilProtocol.waitToolId:
        return _waitForAgents();
      case CouncilProtocol.askUserToolId:
        return _askUser(_session!.config.orchestrator.id, call);
      case CouncilProtocol.phaseToolId:
        return _declarePhase(call);
      case CouncilProtocol.qualityCheckToolId:
        return _runQualityCheck(call);
      case CouncilProtocol.reportToolId:
        final ledgerRefusal = ledger.refusalReasonForReport();
        if (ledgerRefusal != null) {
          _emitDispatchGuardTripped(ledgerRefusal);
          // Actionable, non-shouty feedback. Tells the orchestrator
          // exactly which routes are open instead of just "BLOCKED".
          // If real work didn't land, the right move is usually to
          // surface that to the user via council_ask_user — phantom
          // reports help no one, but neither does a dead-locked loop.
          return CouncilToolResult(
            feedback:
                '$ledgerRefusal\n'
                'Next move: either dispatch a doer agent that actually '
                'produces an artifact, or call council_ask_user to '
                'surface the blocker (timeout, missing intent, '
                'unsupported scope) so the user can pick ship-partial '
                'or abort.',
          );
        }
        // Excellence Doctrine: the quality gate must have passed before
        // council_report becomes legal. If the orchestrator hasn't run
        // the gate yet, refuse and push it to run the gate first; if it
        // ran the gate but some checks failed, refuse and name the
        // failing gates so the orchestrator dispatches the missing
        // work instead of papering over the gap.
        final gateRefusal = _qualityGateRefusal();
        if (gateRefusal != null) {
          _emitDispatchGuardTripped(gateRefusal);
          return CouncilToolResult(feedback: gateRefusal);
        }
        final markdown = call.arguments['markdown'] as String? ?? '';
        await _finishWithReport(markdown);
        return const CouncilToolResult(
          feedback: 'Council report saved.',
          shouldContinue: false,
          finalizesSession: true,
        );
      default:
        return CouncilToolResult(
          feedback: 'Unknown Council tool: ${call.name}',
        );
    }
  }

  /// Handles a `council_phase` declaration from the orchestrator. Updates
  /// the session phase, appends to phase history, emits a `phaseDeclared`
  /// event for the UI, and returns a feedback string nudging the next
  /// natural move within that phase.
  Future<CouncilToolResult> _declarePhase(CouncilToolCall call) async {
    final session = _session;
    if (session == null) {
      return const CouncilToolResult(feedback: 'No active session.');
    }
    final raw = (call.arguments['phase'] as String? ?? '').trim().toLowerCase();
    final rationale = (call.arguments['rationale'] as String? ?? '').trim();
    final phase = _parsePhase(raw);
    if (phase == null) {
      return CouncilToolResult(
        feedback: 'Unknown phase: "$raw". Legal phases: ${CouncilPhase.values.map((p) => p.name).join(', ')}.',
      );
    }
    final previous = session.currentPhase;
    session.currentPhase = phase;
    session.phaseHistory.add(CouncilPhaseEntry(
      phase: phase,
      rationale: rationale,
    ));
    // Structural quality-gate check: phases covered.
    final phaseSet = session.phaseHistory.map((p) => p.phase).toSet();
    session.qualityGate.enoughPhasesCovered = phaseSet.length >= 3;
    _event(
      CouncilEventType.phaseDeclared,
      fromAgentId: session.config.orchestrator.id,
      message: rationale,
      data: {
        'phase': phase.name,
        'rationale': rationale,
        'previousPhase': previous.name,
        'phasesCovered': phaseSet.length,
      },
    );
    notifyListeners();
    await _persist();
    return CouncilToolResult(
      feedback: _phaseGuidance(phase, session),
    );
  }

  /// Handles a `council_quality_check` invocation.
  ///
  /// Flow (Excellence Doctrine Phase B):
  /// 1. On the FIRST call only, synchronously run the Adversarial Critic
  ///    over the session digest. The Critic's findings populate
  ///    `session.critique` and feed into the gate feedback so the
  ///    orchestrator must address (or accept) each blocker / major.
  /// 2. Assert each gate from the orchestrator's call. Two gates are
  ///    structurally overridden: `artifacts_produced` (any artifact-
  ///    producing tool fire counts) and `user_asks_resolved` (no pending
  ///    pool / user question). The orchestrator cannot lie on those.
  /// 3. `adversarial_review_done` is structurally true once the Critic
  ///    has produced at least one attack.
  /// 4. Emit `qualityCheckRan` always; `qualityGatePassed` once on first
  ///    transition to `allPassed`.
  Future<CouncilToolResult> _runQualityCheck(CouncilToolCall call) async {
    final session = _session;
    if (session == null) {
      return const CouncilToolResult(feedback: 'No active session.');
    }
    final gate = session.qualityGate;
    final wasPassing = gate.allPassed;

    // The Critic is one-shot per session. If it hasn't run yet, run it
    // now BEFORE evaluating gates so its findings can populate the
    // adversarial-review gate structurally and feed into the orchestrator
    // feedback. Failures degrade gracefully (logged + skipped) — we
    // never block the gate on Critic infrastructure issues.
    if (session.critique == null) {
      await _runCritic(session);
    }

    // Apply any resolutions the orchestrator declared in this call.
    // Resolutions are sticky — once resolved, an attack stays resolved
    // until a new critique replaces it (which we don't do today).
    final resolvedIds = ((call.arguments['resolved_critic_ids'] as List?) ??
            const [])
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final currentCritique = session.critique;
    if (resolvedIds.isNotEmpty && currentCritique != null) {
      for (final atk in currentCritique.attacks) {
        if (resolvedIds.contains(atk.id)) atk.resolved = true;
      }
      currentCritique.acknowledged = currentCritique.allBlockingResolved;
    }

    // Orchestrator-asserted values. We trust them as INPUTS but override
    // the gates we can verify structurally.
    final critique = session.critique;
    gate
      ..artifactsProduced =
          (call.arguments['artifacts_produced'] == true) || _hasArtifactsProduced(session)
      // Adversarial review is structurally true once the Critic has run
      // and produced at least one attack. The orchestrator's own claim is
      // ignored — the controller owns this gate.
      ..adversarialReviewDone =
          critique != null && critique.attacks.isNotEmpty
      ..claimsGrounded = call.arguments['claims_grounded'] == true
      ..userAsksResolved =
          (call.arguments['user_asks_resolved'] == true) && _allUserAsksResolved(session)
      // `risksNamed` requires that the orchestrator has acknowledged every
      // blocker/major Critic attack (resolved or accepted). The orchestrator
      // can still self-assert it, but if the critique has open blockers,
      // we override to false — the user must see those addressed.
      ..risksNamed = (call.arguments['risks_named'] == true) &&
          (critique == null || critique.allBlockingResolved)
      // Phase coverage is structural — recompute from history.
      ..enoughPhasesCovered =
          session.phaseHistory.map((p) => p.phase).toSet().length >= 3
      ..summary = (call.arguments['summary'] as String? ?? '').trim()
      ..checkedAt = DateTime.now()
      ..attempts = gate.attempts + 1;

    _event(
      CouncilEventType.qualityCheckRan,
      fromAgentId: session.config.orchestrator.id,
      message: gate.summary,
      data: gate.toJson(),
    );
    notifyListeners();
    await _persist();

    if (gate.allPassed && !wasPassing) {
      _event(
        CouncilEventType.qualityGatePassed,
        fromAgentId: session.config.orchestrator.id,
        message: gate.summary,
        data: gate.toJson(),
      );
    }

    final criticBlock = _formatCritiqueForOrchestrator(critique);

    if (gate.allPassed) {
      return CouncilToolResult(
        feedback:
            'Quality gate PASSED on attempt ${gate.attempts}. '
            'council_report is now legal. Synthesize the markdown report '
            'from the agents\' deliverables and ship.\n\n$criticBlock',
      );
    }
    final failing = gate.failingGates.join(', ');
    return CouncilToolResult(
      feedback:
          'Quality gate FAILED. Failing gates: $failing.\n\n$criticBlock\n\n'
          'Address each failing gate before retrying. Concrete moves per gate:\n'
          '• artifacts_produced — dispatch a doer agent on a specific file/edit.\n'
          '• adversarial_review_done — wait for the Adversarial Critic (just '
          'ran above). Already handled structurally.\n'
          '• claims_grounded — re-dispatch agents with "first read X, Y, Z" '
          'in the brief; cite file paths in their replies.\n'
          '• user_asks_resolved — resolve the pending user question.\n'
          '• risks_named — the Critic\'s blocker/major attacks above MUST be '
          'addressed (dispatch a fix) or accepted (named honestly under "Open '
          'Risks"). The orchestrator declaring `risks_named: true` while '
          'unresolved Critic blockers exist is overridden to false.\n'
          '• enough_phases_covered — call council_phase to declare the next '
          'phase, then dispatch into it.\n\n'
          'When you\'ve addressed the gaps, call council_quality_check again. '
          'The Critic does NOT re-run — its findings persist on the session.',
    );
  }

  /// Format the Critic's critique for inclusion in the orchestrator's tool
  /// feedback. Returns a section that the orchestrator can read as a
  /// concrete list of attacks to address or accept.
  String _formatCritiqueForOrchestrator(CouncilCritique? critique) {
    if (critique == null) {
      return '(Critic did not produce findings — running in degraded mode. '
          'Take extra care to surface risks honestly in the report.)';
    }
    if (critique.attacks.isEmpty) {
      return 'Adversarial Critic ran but produced no attacks: '
          '"${critique.summary}". Unusual — proceed with normal rigor.';
    }
    final buf = StringBuffer()
      ..writeln('=== Adversarial Critic findings ===')
      ..writeln(critique.summary);
    for (final a in critique.attacks) {
      final marker = a.isBlocker
          ? '[BLOCKER]'
          : (a.isMajor ? '[MAJOR]' : '[minor]');
      final status = a.resolved ? '(resolved)' : '';
      buf
        ..writeln()
        ..writeln('${a.id} $marker $status')
        ..writeln('  Target: ${a.target}')
        ..writeln('  Attack: ${a.attack}')
        ..writeln('  Acceptance: ${a.acceptance}');
    }
    final blockers = critique.blockerCount;
    final majors = critique.majorCount;
    if (blockers > 0 || majors > 0) {
      buf
        ..writeln()
        ..writeln(
          'Must address or accept (Open Risks): $blockers blocker(s), '
          '$majors major(s). Minor attacks may pass through.',
        );
    }
    return buf.toString();
  }

  /// Run the Adversarial Critic once per session, synchronously, inside
  /// the first quality-check call. Builds a digest of session state,
  /// hits the configured Critic model (final-evaluator model by default),
  /// parses the JSON output, and persists the critique on the session.
  ///
  /// Failure modes (model error, timeout, malformed JSON) are logged via
  /// `criticCompleted` with an empty critique. We never block the gate
  /// on infrastructure issues — degraded mode emits a single attack
  /// flagging the missing critique so the user sees the gap.
  Future<void> _runCritic(CouncilSession session) async {
    final criticModel = session.config.finalEvaluator.model.trim().isEmpty
        ? session.config.orchestrator.model
        : session.config.finalEvaluator.model;

    _event(
      CouncilEventType.criticStarted,
      fromAgentId: session.config.finalEvaluator.id,
      message: S.councilCriticStarted,
      data: {'criticModel': criticModel},
    );
    notifyListeners();

    final digest = _buildCriticDigest(session);
    final prompt = CouncilProtocol.criticSystemPrompt(
      config: session.config,
      sessionDigest: digest,
    );

    String raw;
    try {
      raw = await _generateOneShot(
        model: criticModel,
        messages: [
          {'role': 'system', 'content': prompt},
          {'role': 'user', 'content': 'Attack now. Output JSON only.'},
        ],
      );
    } catch (e) {
      // Degraded mode — record a synthetic critique that flags the failure
      // so the gate sees adversarial_review_done as true but the user knows
      // the Critic didn't really run.
      final critique = CouncilCritique(
        summary: 'Critic failed to run: $e',
        attacks: [
          CouncilCriticAttack(
            id: 'C-degraded',
            target: 'Critic infrastructure',
            attack: 'The Adversarial Critic could not complete its pass '
                '($e). The council shipped without external adversarial '
                'review. Re-run with a working Critic model before trusting '
                'the result.',
            severity: 'major',
            acceptance: 'Re-run the council with a Critic model that '
                'responds. Until then, this is an open risk.',
          ),
        ],
      );
      session.critique = critique;
      _event(
        CouncilEventType.criticCompleted,
        fromAgentId: session.config.finalEvaluator.id,
        message: critique.summary,
        data: {
          ...critique.toJson(),
          'degraded': true,
        },
      );
      notifyListeners();
      await _persist();
      return;
    }

    final critique = _parseCritique(raw);
    session.critique = critique;
    _event(
      CouncilEventType.criticCompleted,
      fromAgentId: session.config.finalEvaluator.id,
      message: critique.summary,
      data: critique.toJson(),
    );
    notifyListeners();
    await _persist();
  }

  /// One-shot non-streaming call to whichever provider the Critic model
  /// belongs to. Mirrors the shape of `proposeAgentsForBrief` so we don't
  /// reinvent provider switching.
  Future<String> _generateOneShot({
    required String model,
    required List<Map<String, dynamic>> messages,
  }) async {
    final split = _splitModel(model);
    switch (split.provider) {
      case 'claude':
        return anthropic.generateChat(messages, model: split.rawModel);
      case 'copilot':
        return copilot.generateChat(messages, model: split.rawModel);
      case 'gemini':
        return gemini.generateChat(messages, model: split.rawModel);
      case 'ollama-cloud':
        return ollama.generateChat(
          messages,
          model: split.rawModel,
          forceCloud: true,
        );
      case 'ollama':
        return ollama.generateChat(messages, model: split.rawModel);
      case 'github':
        throw StateError(
          'GitHub Models was removed; pick another Critic model.',
        );
      default:
        throw StateError(
          'Critic does not support provider "${split.provider}".',
        );
    }
  }

  /// Build the session digest the Critic attacks. Lean and structured —
  /// no streaming junk, no duplication. Phases, gate state, every agent's
  /// last 800 chars of transcript, every pool exchange, and the ledger.
  String _buildCriticDigest(CouncilSession session) {
    final buf = StringBuffer()
      ..writeln('## Brief')
      ..writeln(session.config.brief)
      ..writeln()
      ..writeln('## Phases declared')
      ..writeln(session.phaseHistory.isEmpty
          ? '(none — orchestrator never called council_phase)'
          : session.phaseHistory
              .map((p) => '- ${p.phase.name}: ${p.rationale}')
              .join('\n'))
      ..writeln()
      ..writeln('## Current phase: ${session.currentPhase.name}')
      ..writeln()
      ..writeln('## Quality gate self-assertion (orchestrator-asserted)')
      ..writeln('- artifactsProduced: ${session.qualityGate.artifactsProduced}')
      ..writeln('- adversarialReviewDone: ${session.qualityGate.adversarialReviewDone}')
      ..writeln('- claimsGrounded: ${session.qualityGate.claimsGrounded}')
      ..writeln('- userAsksResolved: ${session.qualityGate.userAsksResolved}')
      ..writeln('- risksNamed: ${session.qualityGate.risksNamed}')
      ..writeln('- enoughPhasesCovered: ${session.qualityGate.enoughPhasesCovered}')
      ..writeln('- orchestrator summary: ${session.qualityGate.summary}')
      ..writeln()
      ..writeln('## Ledger')
      ..writeln('- successCount: ${ledger.successCount}')
      ..writeln('- failureCount: ${ledger.failureCount}')
      ..writeln('- pendingCount: ${ledger.pendingCount}');
    for (final t in ledger.tasks) {
      buf.writeln(
        '  - ${t.agentName} (${t.state.name}): "${t.task}" '
        '${t.lastError == null ? '' : '[error: ${t.lastError}]'}',
      );
    }
    buf
      ..writeln()
      ..writeln('## Agent transcripts (tail)');
    for (final agent in session.config.agents) {
      final transcript = agent.transcript.trim();
      if (transcript.isEmpty) {
        buf.writeln('### ${agent.name}: (empty transcript)');
        continue;
      }
      final tail = transcript.length > 1200
          ? transcript.substring(transcript.length - 1200)
          : transcript;
      buf
        ..writeln('### ${agent.name} (${CouncilProtocol.roleInstruction(agent).split('.').first})')
        ..writeln(tail)
        ..writeln();
    }
    if (session.poolQuestions.isNotEmpty) {
      buf
        ..writeln('## Pool exchanges')
        ..writeln(_orchestratorPoolDigest(session));
    }
    return buf.toString();
  }

  /// Parse the Critic's JSON output. Tolerant of leading/trailing prose
  /// (some models can't help adding "Here is the JSON:") — grabs the
  /// substring from the first `{` to the matching last `}`. Returns a
  /// best-effort critique even on partial parse; a totally malformed
  /// output yields a single synthetic attack noting the failure so the
  /// user sees the gap.
  CouncilCritique _parseCritique(String raw) {
    final start = raw.indexOf('{');
    final end = raw.lastIndexOf('}');
    if (start < 0 || end <= start) {
      return CouncilCritique(
        summary: 'Critic returned malformed output (no JSON object).',
        attacks: [
          CouncilCriticAttack(
            id: 'C-parse',
            target: 'Critic output',
            attack: 'The Critic did not return parseable JSON. Raw output '
                'prefix: "${raw.substring(0, raw.length > 200 ? 200 : raw.length)}".',
            severity: 'major',
            acceptance: 'Re-run with a more JSON-disciplined Critic model.',
          ),
        ],
      );
    }
    try {
      final parsed = jsonDecode(raw.substring(start, end + 1))
          as Map<String, dynamic>;
      final attacks = ((parsed['attacks'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) {
        final d = m.cast<String, dynamic>();
        return CouncilCriticAttack(
          id: (d['id'] as String?)?.trim().isNotEmpty == true
              ? d['id'] as String
              : 'C-${DateTime.now().microsecondsSinceEpoch}',
          target: (d['target'] as String? ?? '').trim(),
          attack: (d['attack'] as String? ?? '').trim(),
          severity: (d['severity'] as String? ?? 'minor').trim().toLowerCase(),
          acceptance: (d['acceptance'] as String? ?? '').trim(),
        );
      }).where((a) => a.target.isNotEmpty && a.attack.isNotEmpty).toList();
      final summary = (parsed['summary'] as String? ?? '').trim();
      return CouncilCritique(
        summary: summary.isEmpty ? 'Critic produced ${attacks.length} attacks.' : summary,
        attacks: attacks,
      );
    } catch (e) {
      return CouncilCritique(
        summary: 'Critic JSON parse failed: $e',
        attacks: [
          CouncilCriticAttack(
            id: 'C-parse',
            target: 'Critic output',
            attack: 'The Critic returned JSON that failed to parse: $e',
            severity: 'major',
            acceptance: 'Re-run the council with a Critic model that '
                'produces clean JSON.',
          ),
        ],
      );
    }
  }

  /// Quality-gate-aware refusal for `council_report`. Returns null when
  /// the gate has passed; otherwise returns a description the orchestrator
  /// gets as tool feedback.
  String? _qualityGateRefusal() {
    final session = _session;
    if (session == null) return null;
    final gate = session.qualityGate;
    if (gate.allPassed) return null;
    if (gate.attempts == 0) {
      return 'BLOCKED — quality gate not yet run.\n\n'
          'Before council_report becomes legal, you must call '
          'council_quality_check and pass all six gates: '
          'artifacts_produced, adversarial_review_done, claims_grounded, '
          'user_asks_resolved, risks_named, enough_phases_covered.\n\n'
          'Run the gate now. Be honest — failing a gate just means more '
          'work, not failure.';
    }
    final failing = gate.failingGates.join(', ');
    return 'BLOCKED — quality gate has not yet passed.\n\n'
        'Failing gates: $failing.\n\n'
        'Dispatch the missing work to address each failing gate, then call '
        'council_quality_check again. council_report will unlock once every '
        'gate is PASS.';
  }

  /// Structural check: any artifact-producing tool fire from any agent
  /// this session counts. Walks the session events because the runner's
  /// onToolFire callback already emits `agentToolFire` for every write.
  bool _hasArtifactsProduced(CouncilSession session) {
    for (final ev in session.events) {
      if (ev.type != CouncilEventType.agentToolFire) continue;
      final toolId = ev.data['toolId'] as String? ?? '';
      if (_artifactProducingTools.contains(toolId)) return true;
    }
    return false;
  }

  /// Structural check: every pool / user question has been resolved (or
  /// none was raised). Pending [_session!.pendingUserQuestion] blocks.
  bool _allUserAsksResolved(CouncilSession session) {
    if (session.pendingUserQuestion != null) return false;
    return session.poolQuestions.every((q) => q.resolved);
  }

  /// Map the raw phase string from the tool call to the enum, tolerant
  /// of common alternates ("design" -> architecture, "implement" -> build).
  CouncilPhase? _parsePhase(String raw) {
    final lower = raw.toLowerCase().trim();
    for (final p in CouncilPhase.values) {
      if (p.name == lower) return p;
    }
    return switch (lower) {
      'design' || 'plan' || 'planning' => CouncilPhase.architecture,
      'implement' || 'implementation' || 'code' || 'coding' => CouncilPhase.build,
      'audit' || 'critique' || 'attack' => CouncilPhase.review,
      'harden' || 'fix' || 'fixing' => CouncilPhase.polish,
      'final' || 'finalize' || 'wrap' => CouncilPhase.ship,
      _ => null,
    };
  }

  /// What the orchestrator should naturally do next given a phase.
  String _phaseGuidance(CouncilPhase phase, CouncilSession session) {
    final phasesSeen = session.phaseHistory.map((p) => p.phase).toSet();
    final reviewedYet = phasesSeen.contains(CouncilPhase.review);
    final builtYet = phasesSeen.contains(CouncilPhase.build);
    return switch (phase) {
      CouncilPhase.discovery =>
        'Phase: DISCOVERY. Dispatch agents to read the project tree and the '
        'specific files / surfaces the brief touches. No edits yet — output '
        'is grounding notes. After agents return, transition to architecture.',
      CouncilPhase.architecture =>
        'Phase: ARCHITECTURE. Dispatch decision work. Each agent owns one '
        'decision artifact (design doc, decision matrix, trade-off table). '
        'Surface DISAGREEMENT — do not paper over conflicting agent opinions. '
        'After agents return, transition to build.',
      CouncilPhase.build =>
        'Phase: BUILD. Dispatch implementation. Each agent OWNS specific files. '
        'Briefs name the file path + the change ("edit `lib/foo.dart` to add the '
        'new route"). No more "design" tasks — only execution. After build '
        'completes, transition to review (do NOT skip).',
      CouncilPhase.review =>
        'Phase: REVIEW. Adversarial. Dispatch reviewers to ATTACK the build '
        'artifacts — find weak claims, missing tests, unproven assumptions, '
        'untested paths. Use pool challenges between agents for falsifiable '
        'cross-checks. After review, transition to polish if findings exist '
        'or directly to ship if review found nothing concrete (rare).',
      CouncilPhase.polish =>
        '${reviewedYet ? '' : 'WARNING: you entered polish without a review phase. Findings will be theoretical. Consider going back to review.\n\n'}'
        'Phase: POLISH. Address every blocker/major review finding. Each '
        'finding gets an owner who produces the concrete fix artifact. After '
        'fixes land, transition to ship and run the quality gate.',
      CouncilPhase.ship =>
        '${builtYet && reviewedYet ? '' : 'WARNING: you entered ship without build+review. This is malpractice on a non-trivial brief.\n\n'}'
        'Phase: SHIP. Run council_quality_check to assert all six gates. '
        'Once every gate is PASS, call council_report with the final markdown.',
    };
  }

  Future<CouncilToolResult> _handleAgentTool(
    CouncilAgent agent,
    CouncilToolCall call,
  ) {
    switch (call.name) {
      case CouncilProtocol.askPoolToolId:
        return _askPool(agent, call);
      case CouncilProtocol.askUserToolId:
        return _askUser(agent.id, call);
      case CouncilProtocol.planSubtasksToolId:
        return _planSubtasks(agent, call);
      case CouncilProtocol.subtaskProgressToolId:
        return _subtaskProgress(agent, call);
      default:
        return Future.value(
          CouncilToolResult(feedback: 'Unknown Council tool: ${call.name}'),
        );
    }
  }

  /// Records an agent's declared subtask plan on the ledger and emits
  /// `agentSubtasksPlanned` so the UI step indicator lights up. Doesn't
  /// change the task state machine — subtasks are a sub-state below
  /// `running`, not a replacement for it.
  Future<CouncilToolResult> _planSubtasks(
    CouncilAgent agent,
    CouncilToolCall call,
  ) async {
    final raw = (call.arguments['subtasks'] as List?) ?? const [];
    final items = raw
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    if (items.isEmpty) {
      return const CouncilToolResult(
        feedback: 'No subtasks provided. List 2-8 concrete, '
            'action-oriented steps.',
      );
    }
    if (items.length > 8) {
      return const CouncilToolResult(
        feedback: 'Too many subtasks (>8). The UI step indicator caps '
            'at 8 — merge related steps and call '
            'council_plan_subtasks again with at most 8 entries.',
      );
    }
    final task = ledger.latestForAgent(agent.id);
    if (task == null) {
      return const CouncilToolResult(
        feedback: 'No active task on the ledger for this agent. Wait '
            'for a dispatch before declaring subtasks.',
      );
    }
    task
      ..subtasks = List<String>.unmodifiable(items)
      ..currentSubtaskIndex = 0
      ..subtaskSummaries = const <String>[]
      ..updatedAt = DateTime.now();
    _event(
      CouncilEventType.agentSubtasksPlanned,
      fromAgentId: agent.id,
      message: items.join(' | '),
      data: {
        'taskId': task.id,
        'subtasks': List<String>.unmodifiable(items),
      },
    );
    notifyListeners();
    await _persist();
    return CouncilToolResult(
      feedback: 'Subtask plan recorded (${items.length} steps). Execute '
          'them in order. After EACH step finishes, call '
          'council_subtask_progress with the 1-based step number and a '
          'one-line summary so the council sees real-time progress.',
    );
  }

  Future<CouncilToolResult> _subtaskProgress(
    CouncilAgent agent,
    CouncilToolCall call,
  ) async {
    final step = (call.arguments['step'] as num?)?.toInt() ?? 0;
    final summary = (call.arguments['summary'] as String? ?? '').trim();
    if (step <= 0) {
      return const CouncilToolResult(
        feedback: 'step must be a 1-based positive integer.',
      );
    }
    final task = ledger.latestForAgent(agent.id);
    if (task == null) {
      return const CouncilToolResult(
        feedback: 'No active task on the ledger for this agent.',
      );
    }
    if (task.subtasks.isEmpty) {
      return const CouncilToolResult(
        feedback: 'No subtask plan declared. Call council_plan_subtasks '
            'first so the council knows the shape of your work.',
      );
    }
    if (step > task.subtasks.length) {
      return CouncilToolResult(
        feedback: 'step $step exceeds the declared '
            '${task.subtasks.length}-step plan. If the plan grew, call '
            'council_plan_subtasks again with the full revised list.',
      );
    }
    // Clamp forward so an out-of-order progress call (skipped step,
    // re-fired completion) keeps the indicator monotonically advancing.
    task.currentSubtaskIndex =
        task.currentSubtaskIndex < step ? step : task.currentSubtaskIndex;
    final summaries = List<String>.from(task.subtaskSummaries);
    while (summaries.length < step) {
      summaries.add('');
    }
    summaries[step - 1] = summary;
    task
      ..subtaskSummaries = List<String>.unmodifiable(summaries)
      ..updatedAt = DateTime.now();
    _event(
      CouncilEventType.agentSubtaskProgress,
      fromAgentId: agent.id,
      message: summary,
      data: {
        'taskId': task.id,
        'step': step,
        'totalSteps': task.subtasks.length,
        'summary': summary,
        'label': task.subtasks[step - 1],
      },
    );
    notifyListeners();
    await _persist();
    final nextStep = step + 1;
    final more = nextStep <= task.subtasks.length;
    return CouncilToolResult(
      feedback: 'Step $step/${task.subtasks.length} recorded. '
          '${more ? "Continue with step $nextStep: ${task.subtasks[nextStep - 1]}" : "All declared subtasks complete — wrap up and return the deliverable."}',
    );
  }

  /// Block until every in-flight parallel dispatch completes, then return
  /// a digest of each agent's final status + transcript tail so the
  /// orchestrator can synthesize before reporting.
  Future<CouncilToolResult> _waitForAgents() async {
    final session = _session;
    if (session == null) {
      return const CouncilToolResult(feedback: 'No active session.');
    }
    if (_dispatches.isEmpty) {
      return const CouncilToolResult(
        feedback: 'No parallel dispatches in flight. '
            'Continue with synthesis or report.',
      );
    }

    session.status = CouncilStatus.working;
    notifyListeners();

    await Future.wait(
      _dispatches.map((f) => f.catchError((_) {})),
    );
    _dispatches.clear();

    final buf = StringBuffer();
    buf.writeln('All dispatched agents have finished. Results:\n');
    for (final agent in session.config.agents) {
      if (agent.status == CouncilAgentStatus.idle &&
          agent.transcript.trim().isEmpty) {
        continue;
      }
      final status = agent.status.name.toUpperCase();
      buf.writeln('--- ${agent.name} ($status) ---');
      final transcript = agent.transcript.trim();
      if (transcript.isEmpty) {
        buf.writeln('(no output)');
      } else {
        buf.writeln(_summariseTranscript(transcript));
      }
      if (agent.lastError.trim().isNotEmpty) {
        buf.writeln('Last error: ${agent.lastError.trim()}');
      }
      buf.writeln();
    }
    // Excellence-Doctrine wait digest. The old digest said "DEFAULT NEXT
    // ACTION: call council_report" — biased the orchestrator toward
    // shipping after one wave. The council is gathered for DEPTH; the
    // default is "move to the next phase," not "ship the first draft."
    final currentPhase = session.currentPhase.name;
    final phasesCovered = session.phaseHistory
        .map((p) => p.phase.name)
        .toSet()
        .length;
    final gate = session.qualityGate;
    final gatesPassed = 6 - gate.failingGates.length;
    buf.writeln(
      'The results above are the agents\' DELIVERABLES — not progress reports, '
      'not "still working" updates. This is what they produced for the brief.\n\n'
      'Current phase: $currentPhase. Phases covered so far: $phasesCovered. '
      'Quality gate: $gatesPassed/6 passing.\n\n'
      'NEXT ACTION DECISION TREE:\n'
      '1. If the current phase is INCOMPLETE (e.g. half the architecture is '
      'sketched, or build is missing review), dispatch the missing work.\n'
      '2. If the current phase is COMPLETE, call council_phase to move to the '
      'next phase, then dispatch into it. Typical order: discovery -> '
      'architecture -> build -> review -> polish -> ship.\n'
      '3. council_report is ONLY legal AFTER council_quality_check returns '
      'all gates PASS. If $gatesPassed/6 are passing right now, the gate is '
      'NOT YET PASSED — keep working.\n'
      '4. If work came back incomplete (errored / blocked / refused), call '
      'council_ask_user with a concrete ship-partial / retry-narrower / abort '
      'choice. Don\'t ask process questions like "should I wait" — own the call.\n'
      '5. Do NOT re-dispatch agents on work that already returned (the dedup '
      'guard rejects identical re-runs). Rephrase the task to name the SPECIFIC '
      'new surface / decision / phase you want addressed.\n\n'
      'The council is gathered for DEPTH. Do not ship after one wave on a '
      'non-trivial brief. You MUST call a tool — typically council_phase or '
      'council_dispatch — to advance the work.',
    );

    return CouncilToolResult(feedback: buf.toString());
  }

  Future<CouncilToolResult> _dispatch(CouncilToolCall call) async {
    final session = _session!;
    final agentId = call.arguments['agentId'] as String? ?? '';
    final task = call.arguments['task'] as String? ?? '';
    final parallel = call.arguments['parallel'] == true;

    // --- Pentest goal extraction ---
    // Priority: explicit `goal` argument on the dispatch call (added to the
    // tool schema). Fallback: parse "GOAL: <text>" from the task text itself,
    // since the CTF doctrine instructs the orchestrator to embed it there.
    if (session.isPentestMode && session.pentestGoal.isEmpty) {
      final goalFromArg = (call.arguments['goal'] as String? ?? '').trim();
      final goalFromText = _extractGoalFromText(task);
      final goal = goalFromArg.isNotEmpty ? goalFromArg : goalFromText;
      if (goal.isNotEmpty) {
        session.pentestGoal = goal;
        _event(CouncilEventType.pentestGoalIdentified, message: goal);
      }
    }

    final agent = session.agentById(agentId);
    if (agent == null || agent.id == session.config.orchestrator.id) {
      return CouncilToolResult(
        feedback: 'No Council agent found for $agentId.',
      );
    }
    if (task.trim().isEmpty) {
      return const CouncilToolResult(feedback: 'Dispatch task was empty.');
    }

    // Refire prevention. Sub-Pro models love to re-dispatch essentially
    // identical work after a wait digest because "make progress" reads as
    // an easier next move than synthesis. The guard catches that pattern
    // structurally so the bug can't recur regardless of how the model
    // reasoned its way to the duplicate dispatch.
    final dedupRefusal = _duplicateTaskRefusal(
      agentId: agentId,
      agentName: agent.name,
      task: task,
    );
    if (dedupRefusal != null) {
      _emitDispatchGuardTripped(dedupRefusal);
      return CouncilToolResult(feedback: dedupRefusal);
    }

    _event(
      CouncilEventType.dispatched,
      fromAgentId: session.config.orchestrator.id,
      toAgentId: agent.id,
      message: task,
      data: {'parallel': parallel, 'roundIndex': session.roundIndex},
    );
    _emitArrival(agent);
    final dispatchLinkId = _emitLinkStarted(
      from: session.config.orchestrator.id,
      to: agent.id,
      kind: CouncilMessageKind.dispatch,
    );
    _emitMessage(
      kind: CouncilMessageKind.dispatch,
      from: session.config.orchestrator.id,
      to: agent.id,
      text: task,
      data: {'linkId': dispatchLinkId, 'parallel': parallel},
    );
    agent.status = CouncilAgentStatus.queued;
    agent.currentTask = task;
    session.status = CouncilStatus.working;
    final taskId = ledger.recordDispatch(
      agentId: agent.id,
      agentName: agent.name,
      task: task,
      runId: session.runId,
      nextIntendedAction: 'spawn agent runner',
    );
    notifyListeners();
    await _persist();

    final future = _runWithDispatchSlot(() => _runAgent(agent, task, taskId))
        .catchError((Object error, StackTrace stackTrace) {
          agent
            ..status = CouncilAgentStatus.error
            ..lastError = '$error';
          _emitLinkEnded(dispatchLinkId, reason: 'error');
          _event(
            CouncilEventType.agentError,
            fromAgentId: agent.id,
            message: '$error',
          );
          // Loud, never-swallowed: ledger transitions to failed and emits
          // a task_state_changed so Signal can surface the error.
          _safeLedgerTransition(
            taskId,
            CouncilTaskState.failed,
            lastError: '$error',
            incrementErrorCount: true,
          );
          notifyListeners();
        })
        .whenComplete(() {
          // Belt-and-braces: ensure the dispatch link is closed exactly once.
          _emitLinkEnded(dispatchLinkId, reason: 'completed');
        });
    if (parallel) {
      _dispatches.add(future);
      unawaited(future);
      final inFlight = _dispatches.length;
      return CouncilToolResult(
        feedback:
            'Dispatched ${agent.name} (parallel). $inFlight task(s) now in flight.\n\n'
            'NEXT: Either dispatch more parallel tasks, or call council_wait '
            'to block until all $inFlight in-flight task(s) complete. '
            'Do NOT call council_report or council_ask_user while tasks are in flight.',
      );
    }

    await future;
    final summary = _summariseTranscript(agent.transcript);
    return CouncilToolResult(
      feedback:
          '${agent.name} completed the task.\n\nResult summary: $summary\n\n'
          'NEXT: Dispatch more work, or call council_report if ALL tasks are done.',
    );
  }

  Future<void> _runWithDispatchSlot(Future<void> Function() run) async {
    while (_activeDispatches >= 3) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
    }
    _activeDispatches++;
    try {
      await run();
    } finally {
      _activeDispatches--;
    }
  }

  Future<void> _runAgent(CouncilAgent agent, String task, String taskId) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return;
    agent.status = CouncilAgentStatus.working;
    _safeLedgerTransition(
      taskId,
      CouncilTaskState.running,
      waitingOn: 'model',
      nextIntendedAction: 'agent streams + tool calls',
    );
    _event(CouncilEventType.agentStarted, toAgentId: agent.id, message: task);
    _emitThinkingStarted(agent);
    notifyListeners();

    const maxRetries = 3;
    CouncilRunResult? result;
    for (var attempt = 1; attempt <= maxRetries; attempt++) {
      final reviewerDirectives = _serialisedReviewerDirectivesFor(agent);
      final runner = CouncilAgentRunner(
        agent: agent,
        anthropic: anthropic,
        copilot: copilot,
        gemini: gemini,
        ollama: ollama,
        toolExecutor: _toolExecutor(agent, workspace),
        systemPrompt: CouncilProtocol.agentSystemPrompt(
          config: session.config,
          agent: agent,
          task: task,
          reviewerDirectives: reviewerDirectives,
        ),
        userPrompt: task,
        nativeToolIds: {...CouncilProtocol.agentToolIds, ...agent.enabledTools},
        onChunk: (chunk) => _appendTranscript(agent, chunk),
        onCouncilTool: (call) => _handleAgentTool(agent, call),
        onStall: _onAgentStall,
        stallTimeoutSeconds: 90,
        onToolFire: _onAgentToolFire,
      );
      _runners.add(runner);
      try {
        result = await runner.run(maxIterations: _agentMaxIterations);
        break; // Success — exit retry loop.
      } catch (e) {
        if (attempt < maxRetries && _isTransientError('$e')) {
          final delaySecs = attempt * 5;
          _event(
            CouncilEventType.agentError,
            fromAgentId: agent.id,
            message: 'Transient error, retrying in ${delaySecs}s '
                '(attempt $attempt/$maxRetries)...',
          );
          notifyListeners();
          agent.transcript = '';
          await Future<void>.delayed(Duration(seconds: delaySecs));
          if (session.status == CouncilStatus.done ||
              session.status == CouncilStatus.aborted) {
            _emitThinkingEnded(agent);
            return;
          }
          continue;
        }
        rethrow; // Non-transient or exhausted retries — let catchError handle it.
      }
    }
    if (result == null) {
      _emitThinkingEnded(agent);
      return;
    }
    if (result.cancelled) {
      _emitThinkingEnded(agent);
      _safeLedgerTransition(
        taskId,
        CouncilTaskState.cancelled,
        lastError: 'agent runner cancelled',
      );
      return;
    }
    _emitThinkingEnded(agent);
    final summary = _summariseTranscript(agent.transcript);
    _safeLedgerTransition(
      taskId,
      CouncilTaskState.done,
    );
    _event(
      CouncilEventType.agentDone,
      fromAgentId: agent.id,
      message: agent.transcript,
      data: {'summary': summary},
    );
    _emitMessage(
      kind: CouncilMessageKind.reply,
      from: agent.id,
      to: session.config.orchestrator.id,
      text: summary,
      data: {'final': true},
    );

    // --- Pentest attack-landed visual event ---
    if (session.isPentestMode && summary.isNotEmpty) {
      final sev = _inferPentestSeverity(summary);
      final label = _extractFindingLabel(summary, sev, agent.name);
      final finding = PentestFinding(
        agentId: agent.id,
        summary: label,
        severity: sev,
        timestamp: DateTime.now(),
      );
      session.pentestFindings.add(finding);
      _event(
        CouncilEventType.pentestAttackLanded,
        fromAgentId: agent.id,
        message: label,
        data: {'severity': sev.name},
      );
    }

    agent
      ..status = CouncilAgentStatus.idle
      ..currentTask = '';
    notifyListeners();
    await _persist();
  }

  /// Merge the evaluator's output into the rich pentest draft.
  /// The draft is the source of truth for findings; the evaluator's
  /// prose is appended as a verification section. Never substitute.
  String _mergePentestReport({
    required String richDraft,
    required String evaluatorOutput,
  }) {
    final evalTrimmed = evaluatorOutput.trim();
    final buf = StringBuffer(richDraft.trimRight());
    buf.writeln();
    buf.writeln();
    buf.writeln('---');
    buf.writeln();
    buf.writeln('## Final Evaluator Verification');
    buf.writeln();
    if (evalTrimmed.isEmpty) {
      buf.writeln('_The final evaluator did not produce verification output. '
          'The findings above are taken directly from the agents and have '
          'not been independently cross-checked._');
    } else if (evalTrimmed.length < 200) {
      // Evaluator phoned it in. Show what it said but flag it.
      buf.writeln('_The final evaluator produced minimal verification. '
          'Findings above are agent-reported and not cross-checked by the '
          'evaluator._');
      buf.writeln();
      buf.writeln('**Evaluator note:**');
      buf.writeln();
      buf.writeln('> $evalTrimmed');
    } else {
      // Substantial evaluator output — strip any duplicated H1 title.
      var clean = evalTrimmed;
      if (clean.startsWith('# ')) {
        final firstNewline = clean.indexOf('\n');
        if (firstNewline > 0) {
          clean = clean.substring(firstNewline + 1).trim();
        }
      }
      buf.writeln(clean);
    }
    return buf.toString();
  }

  /// Build a structured pentest report draft from agent findings,
  /// transcripts, and tasks. This gives the evaluator concrete evidence
  /// to verify rather than forcing it to write from scratch.
  String _enrichPentestDraft(CouncilSession session, String orchestratorDraft) {
    final buf = StringBuffer();
    final goal = session.pentestGoal.isNotEmpty
        ? session.pentestGoal
        : session.config.brief;

    buf.writeln('# Penetration Test Report — $goal');
    buf.writeln();

    // Executive summary from orchestrator
    buf.writeln('## Executive Summary');
    buf.writeln();
    final findings = session.pentestFindings;
    final critical = findings.where((f) => f.severity == PentestSeverity.critical).length;
    final major = findings.where((f) => f.severity == PentestSeverity.major).length;
    final minor = findings.where((f) => f.severity == PentestSeverity.minor).length;
    final info = findings.where((f) => f.severity == PentestSeverity.info).length;
    buf.writeln('- ${findings.length} findings total: '
        '$critical critical, $major major, $minor minor, $info informational.');
    buf.writeln('- ${session.config.agents.length} agents dispatched.');
    if (orchestratorDraft.length > 100) {
      buf.writeln('- Orchestrator notes: ${_summariseTranscript(orchestratorDraft)}');
    }
    buf.writeln();

    // Target & scope
    buf.writeln('## Target & Scope');
    buf.writeln();
    buf.writeln('- Goal: $goal');
    buf.writeln('- Brief: ${session.config.brief}');
    buf.writeln();

    // Findings table — the core deliverable
    buf.writeln('## Findings');
    buf.writeln();
    if (findings.isEmpty) {
      buf.writeln('No findings were reported by agents.');
    } else {
      buf.writeln('| ID | Agent | Severity | Finding | Detail |');
      buf.writeln('|---|---|---|---|---|');
      for (var i = 0; i < findings.length; i++) {
        final f = findings[i];
        final agentName = session.agentById(f.agentId)?.name ?? f.agentId;
        buf.writeln(
          '| F-${(i + 1).toString().padLeft(3, '0')} '
          '| $agentName '
          '| ${f.severity.name.toUpperCase()} '
          '| ${f.summary} '
          '| (see agent transcript) |',
        );
      }
    }
    buf.writeln();

    // Per-agent work log with transcript excerpts
    buf.writeln('## Agent Attack Log');
    buf.writeln();
    for (final agent in session.config.agents) {
      final transcript = agent.transcript.trim();
      final task = agent.currentTask.isNotEmpty
          ? agent.currentTask
          : (session.tasks
                .where((t) => t.agentId == agent.id)
                .map((t) => t.task)
                .join('; '));
      final agentFindings = findings.where((f) => f.agentId == agent.id);
      buf.writeln('### ${agent.name} (${CouncilProtocol.roleInstruction(agent).split('.').first})');
      buf.writeln();
      buf.writeln('**Task:** $task');
      buf.writeln();
      if (agentFindings.isNotEmpty) {
        buf.writeln('**Findings:**');
        for (final f in agentFindings) {
          buf.writeln('- [${f.severity.name.toUpperCase()}] ${f.summary}');
        }
        buf.writeln();
      }
      if (transcript.isNotEmpty) {
        final excerpt = transcript.length > 800
            ? transcript.substring(transcript.length - 800)
            : transcript;
        buf.writeln('**Transcript excerpt:**');
        buf.writeln();
        buf.writeln('> ${excerpt.replaceAll('\n', '\n> ')}');
        buf.writeln();
      }
    }

    // Pool exchanges
    if (session.poolQuestions.isNotEmpty) {
      buf.writeln('## What Changed Because Agents Conspired');
      buf.writeln();
      for (final q in session.poolQuestions) {
        final asker = session.agentById(q.fromAgentId)?.name ?? q.fromAgentId;
        buf.writeln('- **$asker** asked: ${q.question}');
        for (final r in q.replies) {
          final responder = session.agentById(r.fromAgentId)?.name ?? r.fromAgentId;
          buf.writeln('  - **$responder**: ${r.answer}');
        }
      }
      buf.writeln();
    }

    // Remediation placeholder
    buf.writeln('## Remediation Priority Matrix');
    buf.writeln();
    if (findings.isNotEmpty) {
      buf.writeln('| Priority | Finding(s) | Fix | Effort | Risk if Unfixed |');
      buf.writeln('|---|---|---|---|---|');
      var priority = 1;
      for (var i = 0; i < findings.length; i++) {
        final f = findings[i];
        if (f.severity == PentestSeverity.critical ||
            f.severity == PentestSeverity.major) {
          buf.writeln(
            '| $priority | F-${(i + 1).toString().padLeft(3, '0')} '
            '| (evaluator to fill) '
            '| (evaluator to assess) '
            '| ${f.severity.name} risk |',
          );
          priority++;
        }
      }
    }
    buf.writeln();

    // Open vectors
    buf.writeln('## Open Attack Vectors (untested)');
    buf.writeln();
    buf.writeln('(Evaluator: identify vectors that were planned but not tested within session budget.)');
    buf.writeln();

    // Append orchestrator's original draft as appendix
    if (orchestratorDraft.trim().isNotEmpty &&
        orchestratorDraft != '# Council Report\n\nNo final report was produced.') {
      buf.writeln('## Appendix — Orchestrator Draft');
      buf.writeln();
      buf.writeln(orchestratorDraft.trim());
    }

    return buf.toString();
  }

  /// Parse "GOAL: <description>" from the task text. The CTF doctrine
  /// instructs the orchestrator to embed this in the first dispatch.
  static String _extractGoalFromText(String text) {
    final match = RegExp(
      r'GOAL:\s*(.+?)(?:\n|$)',
      caseSensitive: false,
    ).firstMatch(text);
    return match?.group(1)?.trim() ?? '';
  }

  /// Extract a short, readable label for a finding from agent output.
  /// Scans for known vulnerability/risk patterns and returns the first
  /// match as a concise label. Falls back to agent name + severity.
  static String _extractFindingLabel(
    String text,
    PentestSeverity severity,
    String agentName,
  ) {
    final lower = text.toLowerCase();
    // Known vulnerability patterns → short labels
    const patterns = <String, String>{
      'sql injection': 'SQL Injection',
      'sqli': 'SQL Injection',
      'xss': 'Cross-Site Scripting',
      'cross-site scripting': 'Cross-Site Scripting',
      'csrf': 'CSRF',
      'cross-site request': 'CSRF',
      'rce': 'Remote Code Execution',
      'remote code execution': 'Remote Code Execution',
      'command injection': 'Command Injection',
      'auth bypass': 'Auth Bypass',
      'authentication bypass': 'Auth Bypass',
      'privilege escalation': 'Privilege Escalation',
      'path traversal': 'Path Traversal',
      'directory traversal': 'Directory Traversal',
      'ssrf': 'SSRF',
      'server-side request': 'SSRF',
      'open redirect': 'Open Redirect',
      'insecure deserialization': 'Insecure Deserialization',
      'broken access control': 'Broken Access Control',
      'idor': 'IDOR',
      'information disclosure': 'Info Disclosure',
      'info leak': 'Info Leak',
      'sensitive data': 'Data Exposure',
      'hardcoded secret': 'Hardcoded Secret',
      'hardcoded password': 'Hardcoded Password',
      'hardcoded key': 'Hardcoded Key',
      'api key': 'Exposed API Key',
      'weak cipher': 'Weak Cipher',
      'weak encryption': 'Weak Encryption',
      'missing auth': 'Missing Auth',
      'no authentication': 'No Authentication',
      'default credential': 'Default Credentials',
      'default password': 'Default Password',
      'open port': 'Open Port',
      'exposed service': 'Exposed Service',
      'unencrypted': 'Unencrypted Traffic',
      'tls': 'TLS Misconfiguration',
      'ssl': 'SSL Issue',
      'certificate': 'Certificate Issue',
      'cors': 'CORS Misconfiguration',
      'rate limit': 'Missing Rate Limit',
      'brute force': 'Brute Force',
      'dos': 'Denial of Service',
      'denial of service': 'Denial of Service',
      'buffer overflow': 'Buffer Overflow',
      'prototype pollution': 'Prototype Pollution',
      'template injection': 'Template Injection',
      'ssti': 'SSTI',
      'xml external': 'XXE',
      'xxe': 'XXE',
      'file upload': 'File Upload Vuln',
      'unrestricted upload': 'Unrestricted Upload',
      'race condition': 'Race Condition',
      'misconfiguration': 'Misconfiguration',
      'misconfig': 'Misconfiguration',
      'debug endpoint': 'Debug Endpoint',
      'exposed admin': 'Exposed Admin',
      'admin panel': 'Admin Panel Exposed',
      'dns zone transfer': 'DNS Zone Transfer',
      'snmp': 'SNMP Exposure',
      'redis': 'Redis Exposure',
      'mongodb': 'MongoDB Exposure',
      'docker': 'Docker Exposure',
      'kubernetes': 'K8s Exposure',
      'container escape': 'Container Escape',
      'lateral movement': 'Lateral Movement',
      'token': 'Token Vulnerability',
      'session': 'Session Issue',
      'jwt': 'JWT Vulnerability',
    };
    for (final entry in patterns.entries) {
      if (lower.contains(entry.key)) return entry.value;
    }
    return '${agentName} — ${severity.name.toUpperCase()}';
  }

  /// Infer severity from agent output by scanning for keywords.
  PentestSeverity _inferPentestSeverity(String text) {
    final lower = text.toLowerCase();
    if (lower.contains('critical') ||
        lower.contains('rce') ||
        lower.contains('remote code') ||
        lower.contains('injection') ||
        lower.contains('sql injection')) {
      return PentestSeverity.critical;
    }
    if (lower.contains('major') ||
        lower.contains('xss') ||
        lower.contains('auth bypass') ||
        lower.contains('privilege escalation')) {
      return PentestSeverity.major;
    }
    if (lower.contains('minor') ||
        lower.contains('info leak') ||
        lower.contains('misconfiguration')) {
      return PentestSeverity.minor;
    }
    return PentestSeverity.info;
  }

  Future<CouncilToolResult> _askPool(
    CouncilAgent asker,
    CouncilToolCall call,
  ) async {
    final session = _session!;
    final workspace = _workspacePath;
    if (workspace == null) {
      return const CouncilToolResult(feedback: 'No workspace is open.');
    }
    final question = (call.arguments['question'] as String? ?? '').trim();
    if (question.isEmpty) {
      return const CouncilToolResult(feedback: S.councilPoolQuestionEmpty);
    }
    if (_poolExchangeCount() >= _maxPoolExchangesPerSession) {
      return CouncilToolResult(
        feedback: S.councilPoolBudgetExceeded(_maxPoolExchangesPerSession),
      );
    }
    if (!_isSharpPoolQuestion(question)) {
      return CouncilToolResult(
        feedback: S.councilPoolQuestionTooSoft(S.councilPoolFalsifiableHints),
      );
    }
    final rawTargets = call.arguments['targets'];
    final requestedTargets = (rawTargets is List ? rawTargets : const <dynamic>[])
        .whereType<String>()
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList();
    final responders = _selectPoolResponders(
      session: session,
      asker: asker,
      requestedTargets: requestedTargets,
    );
    if (requestedTargets.isNotEmpty && responders.isEmpty) {
      return const CouncilToolResult(feedback: S.councilPoolNoValidTargets);
    }
    if (responders.isEmpty) {
      return const CouncilToolResult(feedback: S.councilPoolNoResponders);
    }
    final entry = CouncilQuestion(
      id: 'pool_${++_questionSeq}',
      fromAgentId: asker.id,
      question: question,
    );
    session.poolQuestions.add(entry);
    session.status = CouncilStatus.awaitingPool;
    asker.status = CouncilAgentStatus.askingPool;
    _event(
      CouncilEventType.askedPool,
      fromAgentId: asker.id,
      message: question,
      data: {
        'requestedTargets': requestedTargets,
        'resolvedTargets': responders.map((a) => a.id).toList(),
        'budget': '${_poolExchangeCount()}/$_maxPoolExchangesPerSession',
      },
    );
    final askLinkId = _emitLinkStarted(
      from: asker.id,
      to: 'pool',
      kind: CouncilMessageKind.askPool,
    );
    _emitMessage(
      kind: CouncilMessageKind.askPool,
      from: asker.id,
      to: 'pool',
      text: question,
      data: {'linkId': askLinkId},
    );
    notifyListeners();
    await _persist();

    // Parallel pool replies. Earlier this loop awaited each responder
    // sequentially — with 3 responders × ~10s each, the asker sat
    // staring at "askingPool" for 30s before getting anything back.
    // Pool replies are short (`maxIterations: 2`) and independent,
    // so we fan them out concurrently. The sibling-status / link /
    // event emissions still happen per reply, just on whichever
    // future settles first. Reply order in `entry.replies` follows
    // the order responders return, not the roster — that's fine:
    // the asker reads them all together via the feedback string.
    final replyFutures = <Future<void>>[];
    for (final agent in responders) {
      final previousStatus = agent.status;
      agent.status = CouncilAgentStatus.replying;
      _emitThinkingStarted(agent);
      final replyLinkId = _emitLinkStarted(
        from: agent.id,
        to: asker.id,
        kind: CouncilMessageKind.poolReply,
      );
      notifyListeners();
      final replyRunner = CouncilAgentRunner(
        agent: agent,
        anthropic: anthropic,
        copilot: copilot,
        gemini: gemini,
        ollama: ollama,
        toolExecutor: _toolExecutor(agent, workspace),
        systemPrompt: CouncilProtocol.poolReplyPrompt(
          config: session.config,
          agent: agent,
          asker: asker,
          question: question,
        ),
        userPrompt: question,
        nativeToolIds: const <String>{},
        onChunk: (_) {},
        onCouncilTool: (_) async => const CouncilToolResult(feedback: ''),
      );
      _runners.add(replyRunner);
      replyFutures.add(() async {
        final result = await replyRunner.run(maxIterations: 2);
        final answer = result.content.trim();
        entry.replies.add(
          CouncilPoolReply(fromAgentId: agent.id, answer: answer),
        );
        agent.status = previousStatus;
        _emitThinkingEnded(agent);
        _event(
          CouncilEventType.poolReply,
          fromAgentId: agent.id,
          toAgentId: asker.id,
          message: answer,
        );
        _emitMessage(
          kind: CouncilMessageKind.poolReply,
          from: agent.id,
          to: asker.id,
          text: answer,
          data: {'linkId': replyLinkId},
        );
        _emitLinkEnded(replyLinkId, reason: 'completed');
        notifyListeners();
        await _persist();
      }());
    }
    await Future.wait(replyFutures);

    _emitLinkEnded(askLinkId, reason: 'completed');
    entry.resolved = true;
    asker.status = CouncilAgentStatus.working;
    session.status = CouncilStatus.working;
    final feedback = StringBuffer(S.councilPoolRepliesHeader)..writeln();
    feedback.writeln(
      S.councilPoolTargetsNote(responders.map((a) => a.id).join(', ')),
    );
    for (final reply in entry.replies) {
      final name =
          session.agentById(reply.fromAgentId)?.name ?? reply.fromAgentId;
      feedback.writeln('- $name: ${reply.answer}');
    }
    notifyListeners();
    await _persist();
    return CouncilToolResult(feedback: feedback.toString());
  }

  Future<CouncilToolResult> _askUser(
    String fromAgentId,
    CouncilToolCall call,
  ) async {
    final question = call.arguments['question'] as String? ?? '';

    // Process-question intercept. The orchestrator on weak models loves to
    // ask "should I wait or ship as they come?" / "should I dispatch now?"
    // / "should I write the report?" — per protocol these are calls the
    // orchestrator owns, not user decisions. Auto-respond with the
    // canonical answer so the run doesn't park on a modal the user
    // shouldn't have to see in the first place. Gated on isOrchestrator
    // so genuine agent-side "I'm blocked" asks still reach the user.
    final isOrchestrator = _session != null &&
        fromAgentId == _session!.config.orchestrator.id;
    if (isOrchestrator) {
      final canonicalAnswer = _canonicalProcessAnswer(question);
      if (canonicalAnswer != null) {
        _event(
          CouncilEventType.askedUser,
          fromAgentId: fromAgentId,
          message: '[auto-answered process question]: $question',
          data: const {'intercepted': true},
        );
        return CouncilToolResult(
          feedback: 'AUTO-ANSWERED (the user should not be asked process '
              'questions — you own these decisions):\n\n$canonicalAnswer',
        );
      }
    }

    final entry = CouncilQuestion(
      id: 'user_${++_questionSeq}',
      fromAgentId: fromAgentId,
      question: question,
    );
    final completer = Completer<String>();
    _userQuestions[entry.id] = completer;
    _session!
      ..pendingUserQuestion = entry
      ..status = CouncilStatus.awaitingUser;
    _session!.agentById(fromAgentId)?.status = CouncilAgentStatus.awaitingUser;
    _event(
      CouncilEventType.askedUser,
      fromAgentId: fromAgentId,
      message: question,
    );
    final linkId = _emitLinkStarted(
      from: fromAgentId,
      to: 'user',
      kind: CouncilMessageKind.askUser,
    );
    _emitMessage(
      kind: CouncilMessageKind.askUser,
      from: fromAgentId,
      to: 'user',
      text: question,
      data: {'linkId': linkId},
    );
    notifyListeners();
    await _persist();
    final answer = await completer.future;
    _emitLinkEnded(linkId, reason: 'completed');
    _session!.agentById(fromAgentId)?.status = CouncilAgentStatus.working;
    return CouncilToolResult(feedback: 'User answered:\n$answer');
  }

  Future<void> _finishWithReport(String markdown) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null) return;
    // THE GUARD: refuse to ship a report when the ledger says no agent
    // produced reportable work. Earlier versions went silent into
    // CouncilStatus.error here, which the user perceived as "stuck"
    // (no path forward, no prompt, just a frozen council). Now we
    // surface the refusal directly to the user via askUser — they
    // become the watchdog and can choose abort / wait-for-retry / etc.
    // The orchestrator's tool-call refusal already nudges it toward
    // using askUser proactively, so reaching this branch usually means
    // the orchestrator did fall over without escalating.
    final refusal = ledger.refusalReasonForReport();
    if (refusal != null) {
      _emitDispatchGuardTripped(refusal);
      final refusalDraft = markdown.trim().isEmpty
          ? '# Council Report\n\nNo final report was produced.'
          : markdown.trim();
      await _persistFailureArtifact(
        session: session,
        reason: refusal,
        draftReport: refusalDraft,
      );
      session.config.orchestrator
        ..status = CouncilAgentStatus.error
        ..lastError = refusal;
      notifyListeners();
      await _persist();
      // Escalate. _askUser flips status to awaitingUser and parks for
      // the user reply. Their answer doesn't auto-route anywhere
      // (orchestrator is no longer running), but it gives the user
      // a clear "this is where it stopped" surface and lets them
      // hit the existing close/abort affordance with full context.
      unawaited(
        _askUser(
          session.config.orchestrator.id,
          CouncilToolCall(
            id: 'report_guard_${++_questionSeq}',
            name: CouncilProtocol.askUserToolId,
            arguments: {
              'question':
                  'The council finished without producing reportable '
                  'work.\n\n$refusal\n\nClose the council and review '
                  'what each agent did, or restart with a tighter '
                  'brief.',
            },
          ),
        ),
      );
      return;
    }
    session.status = CouncilStatus.synthesizing;
    notifyListeners();
    await Future.wait(_dispatches);
    var draftReport = markdown.trim().isEmpty
        ? '# Council Report\n\nNo final report was produced.'
        : markdown.trim();
    // For pentest sessions, enrich the draft with structured findings
    // harvested directly from agent data so the evaluator reviews
    // concrete evidence, not a blank canvas.
    if (session.isPentestMode) {
      draftReport = _enrichPentestDraft(session, draftReport);
    }
    try {
      final evaluatorOutput = await _runFinalEvaluator(draftReport);
      // Split the evaluator output into its two contracted parts: the
      // markdown report (for the user / artifact) and the structured
      // `council_followup` JSON block (for the round-two re-brief loop).
      final split = _splitEvaluatorOutput(evaluatorOutput, draftReport);
      // Pentest mode: the rich draft we built from agent findings IS the
      // report — it contains the findings table, attack log, transcripts,
      // and remediation matrix. The evaluator's output is APPENDED as
      // a verification section, never substituted. This guarantees the
      // user always sees the actual findings even if the evaluator
      // phones it in with a one-line "let me verify" preamble.
      final String report;
      if (session.isPentestMode) {
        report = _mergePentestReport(
          richDraft: draftReport,
          evaluatorOutput: split.markdown,
        );
      } else {
        report = split.markdown;
      }
      final followup = _buildReviewerFollowup(
        raw: split.followupJson,
        summaryFallback:
            'Reviewer produced a report. Review the findings before deciding on round two.',
        roundIndex: session.roundIndex + 1,
      );

      final path = await persistence.writeReport(
        workspacePath: workspace,
        session: session,
        markdown: report,
        summary: followup.summary,
      );
      // Report is now durable on disk. Fire the success-only hook BEFORE
      // emitting the terminal state so any listener that re-opens the
      // wizard on completion sees an already-cleared brief, not a stale
      // one. Swallow callback errors — a prefs write failure must not
      // poison the council finish path.
      final hook = onReportPersisted;
      if (hook != null) {
        try {
          await hook();
        } catch (_) {
          // intentionally silent — callback is best-effort UX cleanup
        }
      }
      session
        ..reportMarkdown = report
        ..reportPath = path
        ..reviewerFollowup = followup
        // KEY: no auto-`done`. Hand off to the user via awaitingFollowup so
        // the council window stays open until they choose round two / close.
        ..status = CouncilStatus.awaitingFollowup;
      session.config.orchestrator.status = CouncilAgentStatus.done;
      for (final agent in session.config.agents) {
        if (agent.status != CouncilAgentStatus.error) {
          agent.status = CouncilAgentStatus.done;
        }
      }
      _event(CouncilEventType.reported, message: path);
      _event(
        CouncilEventType.councilRoundCompleted,
        data: {
          'roundIndex': session.roundIndex,
          'final': false,
          'reportPath': path,
        },
      );
      _event(
        CouncilEventType.reviewerFollowup,
        fromAgentId: session.config.finalEvaluator.id,
        toAgentId: 'user',
        message: followup.summary,
        data: followup.toJson(),
      );
      _emitMessage(
        kind: CouncilMessageKind.followup,
        from: session.config.finalEvaluator.id,
        to: 'user',
        text: followup.summary,
        data: {'reportPath': path, 'weaknessCount': followup.weaknesses.length},
      );
      _event(
        CouncilEventType.awaitingUserFollowup,
        toAgentId: 'user',
        message: followup.summary,
        data: {
          'suggestedRoundTwo': followup.suggestedRoundTwo,
          'weaknessCount': followup.weaknesses.length,
          'reportPath': path,
        },
      );
      _roundTwoDecision = Completer<bool>();
      notifyListeners();
      await _persist();
    } catch (e) {
      final reason = 'Final report pipeline failed: $e';
      _event(
        CouncilEventType.agentError,
        fromAgentId: session.config.finalEvaluator.id,
        message: reason,
      );
      await _persistFailureArtifact(
        session: session,
        reason: reason,
        draftReport: draftReport,
      );
      session.status = CouncilStatus.error;
      session.config.orchestrator
        ..status = CouncilAgentStatus.error
        ..lastError = reason;
      notifyListeners();
      await _persist();
    }
    if (_queuedSynthesisPings.isNotEmpty) {
      final pending = _queuedSynthesisPings.join('\n\n---\n\n');
      _queuedSynthesisPings.clear();
      unawaited(
        _runOrchestrator(
          roundFollowup: session.reviewerFollowup,
          kickNote: pending,
        ),
      );
    }
  }

  Future<void> _persistFailureArtifact({
    required CouncilSession session,
    required String reason,
    required String draftReport,
  }) async {
    final workspace = _workspacePath;
    final report = _buildFailureReportMarkdown(
      session: session,
      reason: reason,
      draftReport: draftReport,
    );
    final summary = 'Council run failed: $reason';
    try {
      final path = await persistence.writeReport(
        workspacePath: workspace,
        session: session,
        markdown: report,
        summary: summary,
      );
      session
        ..reportMarkdown = report
        ..reportPath = path;
      _event(
        CouncilEventType.reported,
        message: path,
        data: {'failed': true, 'reason': reason},
      );
    } catch (e) {
      // Last-resort in-memory fallback so the user still has text to copy
      // in-session even if disk persistence is unavailable.
      session.reportMarkdown = report;
      _event(
        CouncilEventType.agentError,
        fromAgentId: session.config.orchestrator.id,
        message: 'Failed to persist failure report: $e',
      );
    }
  }

  String _buildFailureReportMarkdown({
    required CouncilSession session,
    required String reason,
    required String draftReport,
  }) {
    final b = StringBuffer()
      ..writeln('# Council Report (Failed Run)')
      ..writeln()
      ..writeln('## Failure summary')
      ..writeln(reason)
      ..writeln()
      ..writeln('## Run metadata')
      ..writeln('- Run id: `${session.runId}`')
      ..writeln('- Round: `${session.roundIndex + 1}`')
      ..writeln('- Dispatch success count: `${ledger.successCount}`')
      ..writeln('- Dispatch failure count: `${ledger.failureCount}`')
      ..writeln('- Dispatch pending count: `${ledger.pendingCount}`')
      ..writeln()
      ..writeln('## Last available draft')
      ..writeln(
        draftReport.trim().isEmpty
            ? '_No draft content captured._'
            : draftReport.trim(),
      );
    return b.toString().trim();
  }

  /// Splits the evaluator's output into the user-facing markdown report and
  /// the structured `council_followup` JSON block. The block is matched
  /// non-greedily so a future report containing multiple fenced code blocks
  /// still picks the right one.
  ({String markdown, String followupJson}) _splitEvaluatorOutput(
    String raw,
    String fallback,
  ) {
    final pattern = RegExp(
      r'```\s*council_followup\s*\n([\s\S]*?)```',
      caseSensitive: false,
    );
    final match = pattern.firstMatch(raw);
    if (match == null) {
      return (markdown: raw.trim().isEmpty ? fallback : raw.trim(), followupJson: '');
    }
    final body = match.group(1)?.trim() ?? '';
    final markdown = (raw.substring(0, match.start) + raw.substring(match.end))
        .trim();
    return (
      markdown: markdown.isEmpty ? fallback : markdown,
      followupJson: body,
    );
  }

  ReviewerFollowup _buildReviewerFollowup({
    required String raw,
    required String summaryFallback,
    required int roundIndex,
  }) {
    if (raw.trim().isEmpty) {
      return ReviewerFollowup(
        roundIndex: roundIndex,
        summary: summaryFallback,
        weaknesses: const [],
        perAgentTasks: const {},
        suggestedRoundTwo: false,
        rebriefAddendum: '',
      );
    }
    try {
      final parsed = jsonDecode(raw) as Map<String, dynamic>;
      final summary = (parsed['reviewer_summary'] as String?)?.trim().isNotEmpty == true
          ? (parsed['reviewer_summary'] as String).trim()
          : (parsed['summary'] as String?)?.trim() ?? summaryFallback;
      final directives = (parsed['directives'] as List?) ?? const [];
      final weaknesses = <CouncilWeakness>[];
      final perAgent = <String, List<String>>{};
      final addendumBuf = StringBuffer();
      for (final raw in directives.whereType<Map>()) {
        final d = raw.cast<String, dynamic>();
        final id = (d['id'] as String?) ?? 'W${weaknesses.length + 1}';
        final severity = (d['severity'] as String?) ?? 'minor';
        final area = (d['kind'] as String?) ?? (d['area'] as String?) ?? '';
        final desc = (d['detail'] as String?) ?? (d['description'] as String?) ?? '';
        final summaryLine = (d['summary'] as String?) ?? desc;
        weaknesses.add(CouncilWeakness(
          id: id,
          severity: severity,
          area: area,
          description: desc,
        ));
        final target = (d['target_role'] as String?) ?? '';
        if (target.isNotEmpty && desc.isNotEmpty) {
          perAgent.putIfAbsent(target, () => <String>[]).add('[$id] $summaryLine');
        }
        if (summaryLine.isNotEmpty) {
          addendumBuf.writeln('- [$id | $severity] $summaryLine');
        }
      }
      final blockerOrMajor = weaknesses.any(
        (w) => w.severity == 'blocker' || w.severity == 'major',
      );
      return ReviewerFollowup(
        roundIndex: roundIndex,
        summary: summary,
        weaknesses: weaknesses,
        perAgentTasks: perAgent,
        suggestedRoundTwo: blockerOrMajor || weaknesses.length >= 2,
        rebriefAddendum: addendumBuf.toString(),
      );
    } catch (_) {
      return ReviewerFollowup(
        roundIndex: roundIndex,
        summary: summaryFallback,
        weaknesses: const [],
        perAgentTasks: const {},
        suggestedRoundTwo: false,
        rebriefAddendum: raw.trim(),
      );
    }
  }

  int _poolExchangeCount() {
    return _session?.poolQuestions.length ?? 0;
  }

  bool _isSharpPoolQuestion(String question) {
    final q = question.toLowerCase();
    final bannedSoft = <String>[
      'does this look ok',
      'any thoughts',
      'thoughts?',
      'looks good?',
      'can someone review',
    ];
    if (bannedSoft.any(q.contains)) return false;
    final hasRiskVerb = <String>[
      'fail',
      'fails',
      'failure',
      'break',
      'risk',
      'falsif',
      'invariant',
      'contract',
      'assumption',
      'load-bearing',
      'regress',
      'edge case',
    ].any(q.contains);
    final hasSurface = q.contains('`') ||
        q.contains('/') ||
        q.contains('_') ||
        q.contains('.') ||
        q.contains('symbol') ||
        q.contains('file') ||
        q.contains('path') ||
        q.contains('api');
    return q.contains('?') && hasRiskVerb && hasSurface;
  }

  List<CouncilAgent> _selectPoolResponders({
    required CouncilSession session,
    required CouncilAgent asker,
    required List<String> requestedTargets,
  }) {
    final siblings = session.config.agents
        .where((a) => a.id != asker.id)
        .toList(growable: false);
    if (siblings.isEmpty) return const <CouncilAgent>[];

    if (requestedTargets.isNotEmpty) {
      final byId = <String, CouncilAgent>{for (final a in siblings) a.id: a};
      final selected = <CouncilAgent>[];
      for (final id in requestedTargets) {
        final found = byId[id];
        if (found == null) continue;
        if (selected.any((a) => a.id == found.id)) continue;
        selected.add(found);
      }
      return selected.take(_maxPoolTargetsPerQuestion).toList(growable: false);
    }

    final ranked = [...siblings]..sort(
      (a, b) => _poolRolePriority(a.role).compareTo(_poolRolePriority(b.role)),
    );
    return ranked.take(_maxPoolTargetsPerQuestion).toList(growable: false);
  }

  int _poolRolePriority(RolePreset role) {
    return switch (role) {
      RolePreset.reviewer => 0,
      RolePreset.tester => 1,
      RolePreset.pentester => 2,
      RolePreset.architect => 3,
      RolePreset.researcher => 4,
      RolePreset.writer => 5,
      RolePreset.custom => 6,
    };
  }

  /// Runs the final evaluator with a watchdog that retries when output is
  /// too sparse to be a real report. Two retries max, each with a stronger
  /// nudge. After that, return whatever we got — `_mergePentestReport`
  /// handles the "evaluator phoned it in" case gracefully.
  Future<String> _runFinalEvaluator(String draftReport) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return draftReport;
    var evaluator = session.config.finalEvaluator;
    if (evaluator.model.trim().isEmpty) {
      evaluator = _defaultFinalEvaluator(session.config.orchestrator.model);
    }
    evaluator
      ..status = CouncilAgentStatus.working
      ..currentTask = S.councilFinalEvaluatorTask;
    _emitArrival(evaluator);
    _emitThinkingStarted(evaluator);
    _event(
      CouncilEventType.evaluatorStarted,
      toAgentId: evaluator.id,
      message: evaluator.currentTask,
    );
    notifyListeners();

    const maxAttempts = 3;
    String lastOutput = '';
    String? lastFailReason;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      final isRetry = attempt > 1;
      final userPrompt = isRetry
          ? _evaluatorRetryPrompt(
              attempt: attempt,
              previousOutput: lastOutput,
              reason: lastFailReason ?? 'output too sparse',
              draftReport: draftReport,
            )
          : 'OUTPUT THE REPORT NOW. Your very first line of output must be '
              'the ```council_followup JSON block (Part 1), immediately '
              'followed by the markdown report (Part 2). '
              'Do NOT narrate, plan, or think out loud. Do NOT write '
              '"Let me review..." or "I\'ll start by..." — those are not '
              'the report. Start with ```council_followup on line 1.';

      // Reset transcript on retry so we don't fold prior attempts together.
      if (isRetry) {
        evaluator.transcript = '';
      }

      final runner = CouncilAgentRunner(
        agent: evaluator,
        anthropic: anthropic,
        copilot: copilot,
        gemini: gemini,
        ollama: ollama,
        toolExecutor: _toolExecutor(evaluator, workspace),
        systemPrompt: CouncilProtocol.finalEvaluatorSystemPrompt(
          config: session.config,
          draftReport: draftReport,
        ),
        userPrompt: userPrompt,
        nativeToolIds: evaluator.enabledTools,
        onChunk: (chunk) => _appendTranscript(evaluator, chunk),
        onCouncilTool: (_) async => const CouncilToolResult(
          feedback: 'The final evaluator should produce prose only.',
        ),
        onToolFire: _onAgentToolFire,
      );
      _runners.add(runner);
      CouncilRunResult result;
      try {
        result = await runner.run(maxIterations: _evaluatorMaxIterations);
      } catch (e) {
        if (_isTransientError('$e') && attempt < maxAttempts) {
          final delaySecs = attempt * 5;
          _event(
            CouncilEventType.agentError,
            fromAgentId: evaluator.id,
            message: 'Transient error, retrying in ${delaySecs}s...',
          );
          notifyListeners();
          await Future<void>.delayed(Duration(seconds: delaySecs));
          lastFailReason = 'transient API error: $e';
          evaluator.transcript = '';
          continue;
        }
        _emitThinkingEnded(evaluator);
        evaluator.status = CouncilAgentStatus.error;
        _event(
          CouncilEventType.evaluatorDone,
          fromAgentId: evaluator.id,
          message: draftReport,
        );
        return draftReport;
      }

      if (result.cancelled) {
        _emitThinkingEnded(evaluator);
        evaluator.status = CouncilAgentStatus.error;
        _event(
          CouncilEventType.evaluatorDone,
          fromAgentId: evaluator.id,
          message: draftReport,
        );
        return draftReport;
      }

      lastOutput = evaluator.transcript.trim();
      final failReason = _evaluatorOutputFailureReason(lastOutput);
      if (failReason == null) {
        // Substantial output — accept it.
        _emitThinkingEnded(evaluator);
        evaluator.status = CouncilAgentStatus.done;
        _event(
          CouncilEventType.evaluatorDone,
          fromAgentId: evaluator.id,
          message: evaluator.transcript,
          data: {'attempts': attempt},
        );
        _emitMessage(
          kind: CouncilMessageKind.review,
          from: evaluator.id,
          to: 'pool',
          text: _summariseTranscript(evaluator.transcript),
        );
        notifyListeners();
        return lastOutput;
      }

      // Output failed quality gate — retry with stronger nudge.
      lastFailReason = failReason;
      _event(
        CouncilEventType.agentError,
        fromAgentId: evaluator.id,
        message: 'Evaluator watchdog: attempt $attempt rejected — $failReason',
        data: {'attempt': attempt, 'reason': failReason},
      );
    }

    // All retries exhausted. Return whatever we got — merge step will
    // wrap it appropriately so the user still gets the rich draft.
    _emitThinkingEnded(evaluator);
    evaluator.status = lastOutput.isEmpty
        ? CouncilAgentStatus.error
        : CouncilAgentStatus.done;
    _event(
      CouncilEventType.evaluatorDone,
      fromAgentId: evaluator.id,
      message: lastOutput.isEmpty ? draftReport : evaluator.transcript,
      data: {
        'attempts': maxAttempts,
        'watchdogTripped': true,
        'lastFailReason': lastFailReason,
      },
    );
    notifyListeners();
    return lastOutput;
  }

  /// Quality gate for evaluator output. Returns null when output is
  /// substantial enough to ship as a report, or a failure reason string
  /// when the evaluator phoned it in.
  static String? _evaluatorOutputFailureReason(String output) {
    final trimmed = output.trim();
    if (trimmed.length < 200) {
      return 'output too short (${trimmed.length} chars; minimum 200)';
    }
    // Must have at least 2 section headings to be a real report.
    final headingCount = RegExp(r'^#{1,3} ', multiLine: true)
        .allMatches(trimmed)
        .length;
    if (headingCount < 2) {
      return 'no report structure (found $headingCount headings; need ≥2)';
    }
    // Hedging/narration detection — regardless of length. If the first
    // 300 chars are narration ("let me...", "I'll...") without starting
    // the actual report format, it's a failed attempt.
    final first300 = trimmed.substring(
      0, trimmed.length < 300 ? trimmed.length : 300,
    ).toLowerCase();
    const hedges = [
      'let me verify',
      'let me start',
      'let me review',
      'let me carefully',
      'let me first',
      'let me analyze',
      'let me examine',
      'i need to verify',
      'i need to review',
      'i\'ll start',
      'i will start',
      'i\'ll begin',
      'i\'ll review',
      'i\'ll analyze',
      'the user wants me to',
      'i should produce',
      'i need to produce',
    ];
    if (hedges.any(first300.contains) &&
        !first300.contains('```council_followup')) {
      return 'narration/preamble instead of report (starts with hedging)';
    }
    return null;
  }

  /// Build a stronger user prompt for evaluator retry attempts.
  String _evaluatorRetryPrompt({
    required int attempt,
    required String previousOutput,
    required String reason,
    required String draftReport,
  }) {
    final preview = previousOutput.length > 300
        ? previousOutput.substring(0, 300)
        : previousOutput;
    return '''
WATCHDOG RETRY $attempt/3 — REJECTED: $reason.

Your previous output started with:
"""
$preview
"""

That is NOT a report. That is narration. You were programmatically rejected.

MANDATORY FORMAT — your output must start EXACTLY like this:
```council_followup
{"round": 2, "reviewer_summary": "...", "directives": [...], "must_not_redo": [...]}
```

Immediately followed by the full markdown report (Part 2) starting with a # heading.

Rules:
1. FIRST LINE of output = ```council_followup — no text before it.
2. Part 2 must fill EVERY section from the report template in your system prompt.
3. Include ALL findings from the draft. Mark unverified ones `verified? = no`.
4. Output must be at least 1500 characters total.
5. NO narration, NO "let me", NO "I will", NO meta-commentary.

The draft report and agent transcripts are in your system prompt. You have everything. Produce the deliverable NOW.
''';
  }

  ToolExecutor _toolExecutor(CouncilAgent agent, String workspace) {
    return ToolExecutor(
      workspaceDir: workspace,
      enabledTools: agent.enabledTools.isEmpty ? null : agent.enabledTools,
      councilToolLock: _toolLock,
      approver: (toolId, label, detail) async {
        return isToolAutoApproved(toolId, detail);
      },
    );
  }

  void _appendTranscript(CouncilAgent agent, String chunk) {
    final clean = _cleanTranscriptChunk(chunk);
    if (clean.isEmpty) return;
    agent.transcript += clean;
    _event(
      CouncilEventType.agentChunk,
      fromAgentId: agent.id,
      message: clean,
    );
    _detectAndEmitPeerMentions(agent, clean);
    notifyListeners();
  }

  /// Scan a freshly streamed chunk for peer-agent name references and
  /// emit one `agentPeerMention` event per unique peer found. The
  /// discourse layer subscribes to these to draw a short-lived
  /// "mention tether" arc from the speaker to the mentioned peer.
  ///
  /// Design notes:
  ///   • Per-(speaker, peer) debounce window so a long transcript
  ///     that mentions the same peer 10 times in one chunk doesn't
  ///     spam the stage. We re-fire only after [_peerMentionCooldown]
  ///     so an organic re-reference still surfaces.
  ///   • Match is on word-boundary `\bName\b`, case-insensitive. The
  ///     orchestrator and the speaker themselves are excluded — we
  ///     don't want a card-to-itself tether, and the orchestrator
  ///     gets its own visualisation via the traffic layer.
  ///   • Empty or short (<3 char) names are skipped so we don't
  ///     match noise like a stray "Q".
  void _detectAndEmitPeerMentions(CouncilAgent speaker, String chunk) {
    final session = _session;
    if (session == null) return;
    final orchestratorId = session.config.orchestrator.id;
    final now = DateTime.now();
    final foundIds = <String>{};
    final lower = chunk.toLowerCase();
    for (final candidate in session.config.agents) {
      if (candidate.id == speaker.id) continue;
      if (candidate.id == orchestratorId) continue;
      final name = candidate.name.trim();
      if (name.length < 3) continue;
      final pattern = RegExp(
        r'\b' + RegExp.escape(name.toLowerCase()) + r'\b',
      );
      if (pattern.hasMatch(lower)) {
        foundIds.add(candidate.id);
      }
    }
    if (foundIds.isEmpty) return;

    final speakerCooldowns = _peerMentionLastFired.putIfAbsent(
      speaker.id,
      () => <String, DateTime>{},
    );
    final fresh = <String>[];
    for (final id in foundIds) {
      final last = speakerCooldowns[id];
      if (last != null && now.difference(last) < _peerMentionCooldown) continue;
      speakerCooldowns[id] = now;
      fresh.add(id);
    }
    if (fresh.isEmpty) return;
    _event(
      CouncilEventType.agentPeerMention,
      fromAgentId: speaker.id,
      data: {'mentions': fresh},
    );
  }

  /// Per-speaker → per-peer last-emission timestamp. Bounded by the
  /// agent roster (≤ a handful of entries), no need to age out.
  final Map<String, Map<String, DateTime>> _peerMentionLastFired = {};
  static const Duration _peerMentionCooldown = Duration(seconds: 6);

  String _cleanTranscriptChunk(String chunk) {
    return chunk.replaceAll(
      RegExp(r'<!--\s*LUMEN_THINK_(START|END)\s*-->', caseSensitive: false),
      '',
    );
  }

  /// Refire guard. Returns a refusal string when [task] is essentially a
  /// re-dispatch of work [agentId] already completed in this session, else
  /// null. Uses Jaccard similarity over normalized word sets — cheap,
  /// deterministic, no model call. The 0.78 threshold catches genuine
  /// duplicates ("redo the auth audit") while letting through legitimate
  /// follow-ups that share vocabulary with the prior task ("now implement
  /// the auth fixes you proposed").
  ///
  /// Lives here, not in the ledger, because the message refers to the
  /// agent's actual transcript (so the orchestrator gets the prior result
  /// inline and can synthesize from it instead of re-running the work).
  String? _duplicateTaskRefusal({
    required String agentId,
    required String agentName,
    required String task,
  }) {
    final ledgerInstance = _ledger;
    if (ledgerInstance == null) return null;
    final priorDone = ledgerInstance.tasks
        .where((t) => t.agentId == agentId && t.state == CouncilTaskState.done)
        .toList();
    if (priorDone.isEmpty) return null;

    CouncilTask? bestMatch;
    var bestScore = 0.0;
    for (final prior in priorDone) {
      final score = _taskSimilarity(prior.task, task);
      if (score > bestScore) {
        bestScore = score;
        bestMatch = prior;
      }
    }
    // Excellence Doctrine softening: raised 0.78 -> 0.88. The lower
    // threshold was too aggressive, refusing legitimate phase-follow-up
    // work ("design the auth UI" then "build the auth UI" share 70%+
    // vocabulary and got blocked). 0.88 still catches true paraphrases.
    const threshold = 0.88;
    if (bestScore < threshold || bestMatch == null) return null;

    // Phase-aware bypass: if the prior task and the new one are in
    // different phases (e.g. discovery -> build, architecture -> build,
    // review -> polish), the work is NOT a re-fire. Phases shift the
    // verb prefix even when the noun stays the same.
    if (_isCrossPhaseFollowup(prior: bestMatch.task, fresh: task)) {
      return null;
    }

    final agent = _session?.agentById(agentId);
    final priorTranscript = (agent?.transcript ?? '').trim();
    final priorSummary = priorTranscript.isEmpty
        ? '(no transcript captured for the prior run — check the inspector)'
        : _summariseTranscript(priorTranscript);

    return 'BLOCKED — refire of completed work.\n\n'
        '$agentName already completed an essentially identical task in this '
        'session (similarity ${(bestScore * 100).toInt()}%).\n\n'
        'PRIOR TASK BRIEF:\n${bestMatch.task}\n\n'
        'PRIOR RESULT (summary):\n$priorSummary\n\n'
        'Do NOT re-run this. Pick one:\n'
        '• Move to the next phase via council_phase, then dispatch genuinely '
        'new work for that phase (a different verb on the same surface IS '
        'legitimate — "design X" -> "build X" -> "review X" -> "polish X").\n'
        '• Dispatch GENUINELY NEW work — a different surface, a follow-up '
        'phase, an explicit refinement. Rephrase the task so the novelty is '
        'unambiguous (don\'t just paraphrase the original brief).\n'
        '• If you think the prior result is wrong, route a council_ask_pool '
        'question to a peer to challenge it — don\'t silently redo the work.';
  }

  /// Returns true when [prior] and [fresh] differ by a phase-shift verb
  /// (e.g. "design"/"plan" -> "implement"/"build" -> "review"/"audit" ->
  /// "polish"/"harden"). The simple heuristic: tokenize both, check if a
  /// phase-verb from each set differs. False positives are fine — they
  /// just mean an edge case slips through dedup, which is recoverable.
  /// False negatives (blocking legitimate phase work) are NOT fine.
  static bool _isCrossPhaseFollowup({
    required String prior,
    required String fresh,
  }) {
    const phaseVerbs = <Set<String>>[
      {'discover', 'discovery', 'map', 'read', 'understand', 'explore', 'survey'},
      {'design', 'plan', 'architect', 'sketch', 'decide', 'propose'},
      {'build', 'implement', 'create', 'write', 'add', 'wire', 'ship'},
      {'review', 'audit', 'attack', 'critique', 'challenge', 'verify', 'test'},
      {'polish', 'harden', 'fix', 'refine', 'address', 'resolve', 'patch'},
    ];
    Set<int> phasesPresent(String text) {
      final tokens = text.toLowerCase().split(RegExp(r'\W+'));
      final result = <int>{};
      for (var i = 0; i < phaseVerbs.length; i++) {
        if (tokens.any(phaseVerbs[i].contains)) result.add(i);
      }
      return result;
    }
    final priorPhases = phasesPresent(prior);
    final freshPhases = phasesPresent(fresh);
    if (priorPhases.isEmpty || freshPhases.isEmpty) return false;
    // Cross-phase if the dominant phase verb shifts.
    return !priorPhases.containsAll(freshPhases) ||
        !freshPhases.containsAll(priorPhases);
  }

  /// Jaccard similarity over normalized word sets. Symmetric, in [0..1].
  /// Empty inputs (or all-stopword inputs) return 0.
  double _taskSimilarity(String a, String b) {
    final wordsA = _normalizedTaskWords(a);
    final wordsB = _normalizedTaskWords(b);
    if (wordsA.isEmpty || wordsB.isEmpty) return 0.0;
    final intersection = wordsA.intersection(wordsB).length;
    final union = wordsA.union(wordsB).length;
    return union == 0 ? 0.0 : intersection / union;
  }

  /// Tokenize a task brief into a normalized comparable word set. Lowercased,
  /// punctuation/whitespace split, common English stopwords filtered, very
  /// short tokens (< 2 chars) dropped so that connectives don't dominate
  /// the similarity score. Keeps `/`, `.`, `_`, `-` inside tokens so file
  /// paths like `lib/foo/bar.dart` survive as a single signal-rich token.
  static final Set<String> _kTaskStopwords = {
    'a', 'an', 'the', 'and', 'or', 'but', 'in', 'on', 'at', 'to', 'for', 'of',
    'with', 'by', 'from', 'as', 'is', 'are', 'was', 'were', 'be', 'been',
    'being', 'have', 'has', 'had', 'do', 'does', 'did', 'will', 'would',
    'should', 'could', 'may', 'might', 'must', 'shall', 'can', 'this', 'that',
    'these', 'those', 'first', 'then', 'also', 'please', 'your', 'you', 'it',
    'its', 'we', 'our', 'us', 'they', 'their', 'them', 'so', 'if', 'when',
    'where', 'which', 'while', 'into', 'onto', 'out', 'over', 'under', 'than',
    'task', 'agent', 'work', 'use', 'make', 'create', 'add', 'apply', 'now',
    'next', 'before', 'after', 'within', 'across', 'between',
  };

  Set<String> _normalizedTaskWords(String task) {
    final lower = task.toLowerCase();
    return lower
        .split(RegExp(r'[^a-z0-9_./\-]+'))
        .where((w) => w.length > 1 && !_kTaskStopwords.contains(w))
        .toSet();
  }

  /// Detects orchestrator process-questions and returns the canonical
  /// answer the orchestrator should have produced itself. Returns null
  /// when the question is a legitimate user-facing ask (intent,
  /// credentials, risk acceptance, reviewer-blocker decisions).
  ///
  /// We over-favor returning null here — false negatives just mean the
  /// user sees a modal they could have skipped, which is recoverable.
  /// False positives would silently swallow a real user-input prompt,
  /// which is much worse.
  static String? _canonicalProcessAnswer(String question) {
    final q = question.toLowerCase();
    final hasQuestionMark = q.contains('?');
    if (!hasQuestionMark) return null;

    // Ship-as-they-come vs wait-for-all. Same canonical answer (wait, then
    // synthesize once everyone returns) — that part of the doctrine
    // didn't change.
    final shipsAsCome = q.contains('ship') &&
        (q.contains('as they') ||
            q.contains('as it') ||
            q.contains('come in') ||
            q.contains('incrementally') ||
            q.contains('one by one'));
    final waitForAll = q.contains('wait') &&
        (q.contains('all') || q.contains('finish') || q.contains('done'));
    final seqVsPar = q.contains('sequential') && q.contains('parallel');
    if (shipsAsCome || waitForAll || seqVsPar) {
      return 'Default: dispatch independent threads in parallel, then call '
          'council_wait for the wave. Synthesize once every agent has '
          'returned, not incrementally as each one finishes. This is the '
          'canonical flow — proceed without asking.';
    }

    // "Should I dispatch / dispatch now / dispatch next".
    if (q.contains('dispatch') &&
        (q.contains('should i') ||
            q.contains('shall i') ||
            q.contains('do i') ||
            q.contains('now') ||
            q.contains('next'))) {
      return 'Yes. Identify the independent threads in the brief and '
          'dispatch them in parallel via council_dispatch. You own '
          'dispatch decisions — do not ask permission.';
    }

    // EXCELLENCE DOCTRINE — flipped from prior version:
    // "Should I write/ship/finalize the report" is no longer auto-answered
    // toward ship. Push the orchestrator back to the gate + phase flow.
    if (q.contains('report') &&
        (q.contains('should i') ||
            q.contains('shall i') ||
            q.contains('do i') ||
            q.contains('write') ||
            q.contains('finalize') ||
            q.contains('ship')) &&
        !q.contains('round two') &&
        !q.contains('round 2')) {
      return 'Not yet — by default. council_report is gated on '
          'council_quality_check passing all six gates. Steps before report:\n'
          '1. Run council_quality_check honestly. If gates fail, address them.\n'
          '2. If you have not progressed through review + polish phases, do so '
          'before considering ship. The council exists for DEPTH; one-wave '
          'shipping is not the default on non-trivial briefs.\n'
          '3. Only after a passing gate (and a real review + polish pass) is '
          'council_report the right move. The user expects rigor here.';
    }

    // "How should I organize / approach / structure the work" — flipped
    // toward phase-driven depth.
    if ((q.contains('how should i') ||
            q.contains('what approach') ||
            q.contains('which approach') ||
            q.contains('how do i organize') ||
            q.contains('how to organize')) &&
        !q.contains('credential') &&
        !q.contains('risk') &&
        !q.contains('access')) {
      return 'Use the phase spine: discovery -> architecture -> build -> '
          'review -> polish -> ship. Declare each phase via council_phase '
          'before dispatching into it. Independent threads within a phase '
          'run parallel; phases run sequentially. You own this call — that is '
          'the job.';
    }

    // "Should I keep going" / "is there more work" / "am I done" — flipped
    // hard. The whole POINT of the council is depth; the auto-answer here
    // is "yes, keep going."
    if (q.contains('should i keep') ||
        q.contains('is there more') ||
        q.contains('any more work') ||
        q.contains('am i done') ||
        q.contains('done yet') ||
        q.contains('enough work') ||
        q.contains('is this enough') ||
        q.contains('shall i stop')) {
      return 'Almost certainly yes — keep going. The council was gathered for '
          'DEPTH. Default move: advance to the next phase (council_phase), '
          'dispatch work into it, and run council_quality_check before '
          'considering ship. If every gate is genuinely PASS and you are in '
          'the ship phase, then ship — otherwise, more work.';
    }

    // "Is this ok" / "look ok" / "proceed" style permission asks.
    if ((q.contains('is this ok') ||
            q.contains('looks ok') ||
            q.contains('look good') ||
            q.contains('look ok') ||
            q.contains('any objection') ||
            q.contains('any concerns') ||
            q.contains('any thoughts') ||
            q.contains('continue') ||
            q.contains('proceed')) &&
        !q.contains('risk') &&
        !q.contains('destructive') &&
        !q.contains('delete') &&
        !q.contains('credential') &&
        !q.contains('production')) {
      return 'Yes, proceed. Don\'t ask for permission on non-destructive, '
          'non-risk-acceptance, non-credential moves — make the call and '
          'continue. The user is reading the final report, not approving '
          'each step.';
    }

    return null;
  }

  /// Emit an `agentToolFire` event for the activity bubble layer. Wired
  /// to `CouncilAgentRunner.onToolFire` so the moment a tool is identified
  /// (read_file / edit_file / run_cmd / ...) the bubble flashes the
  /// structured "currently doing X" signal — file path, command, etc.
  /// Replaces the prior model of leaking raw stream chunks as bubble text.
  ///
  /// We deliberately skip emitting for council protocol tools (dispatch /
  /// wait / ask_pool / ask_user / report) — those have dedicated event
  /// surfaces (`dispatched`, `askedPool`, `askedUser`, `reported`) that
  /// the bubble layer already handles. The runner already gates the
  /// callback for non-council tools.
  void _onAgentToolFire(
    String agentId,
    String toolId,
    Map<String, dynamic> arguments,
  ) {
    final primary = _primaryToolArg(toolId, arguments);
    final data = <String, dynamic>{'toolId': toolId};
    if (primary != null) data['primaryArg'] = primary;
    _event(
      CouncilEventType.agentToolFire,
      fromAgentId: agentId,
      message: primary == null ? toolId : '$toolId: $primary',
      data: data,
    );
  }

  /// Extract the user-facing "primary" argument for a tool — the bit that
  /// goes into the speech bubble flash so the user reads "Reading
  /// `lib/foo.dart`" instead of just "read_file". Returns null when the
  /// tool has no useful primary arg (e.g. `git_status` takes none).
  static String? _primaryToolArg(String toolId, Map<String, dynamic> args) {
    String? str(String key) {
      final v = args[key];
      if (v is String && v.trim().isNotEmpty) return v.trim();
      return null;
    }

    switch (toolId) {
      case 'read_file':
      case 'create_file':
      case 'append_file':
      case 'edit_file':
      case 'multi_edit':
      case 'edit_range':
      case 'list_dir':
      case 'tree':
        return str('path') ?? str('directory');
      case 'move_file':
      case 'copy_file':
        return str('source') ?? str('path') ?? str('from');
      case 'delete_file':
        return str('path');
      case 'find_file':
      case 'glob':
        return str('pattern') ?? str('name') ?? str('query');
      case 'search_text':
        return str('query') ?? str('pattern');
      case 'run_cmd':
      case 'verify':
        return str('cmd') ?? str('command');
      case 'check_url':
      case 'web_fetch':
        return str('url');
      case 'web_search':
        return str('query');
      case 'git_diff':
      case 'git_log':
      case 'git_blame':
        return str('path');
      case 'git_status':
        return null;
      case 'save_memory':
        return str('scope');
      default:
        // Best-effort fallback so new tools land with some signal.
        return str('path') ??
            str('cmd') ??
            str('command') ??
            str('query') ??
            str('pattern') ??
            str('url');
    }
  }

  /// Cheap, in-band summary for `agent_done.summary`. Pool consensus: do NOT
  /// add an extra LLM call. Use the tail of the transcript so the speech
  /// bubble shows the agent's own last words. Caps at ~600 chars.
  String _summariseTranscript(String transcript) {
    final t = transcript.trim();
    if (t.isEmpty) return '';
    const cap = 600;
    if (t.length <= cap) return t;
    final tail = t.substring(t.length - cap);
    final firstNl = tail.indexOf('\n');
    return (firstNl > 0 && firstNl < cap ~/ 4) ? tail.substring(firstNl + 1) : tail;
  }

  String _serialisedReviewerDirectivesFor(CouncilAgent agent) {
    final session = _session;
    if (session == null) return '';
    final followup = session.reviewerFollowup;
    if (followup == null) return '';
    if (session.roundIndex == 0) return '';
    final directives = followup.perAgentTasks[agent.id] ?? const <String>[];
    if (directives.isEmpty && followup.rebriefAddendum.trim().isEmpty) {
      return '';
    }
    final buf = StringBuffer()
      ..writeln(jsonEncode({
        'round': session.roundIndex + 1,
        'reviewer_summary': followup.summary,
        'directives': followup.weaknesses
            .where(
              (w) =>
                  followup.perAgentTasks[agent.id]?.any(
                    (t) => t.contains(w.id),
                  ) ??
                  false,
            )
            .map((w) => {
                  'id': w.id,
                  'severity': w.severity,
                  'kind': w.area,
                  'detail': w.description,
                  'target_role': agent.id,
                })
            .toList(),
        'must_not_redo': const <String>[],
      }))
      ..writeln()
      ..writeln(followup.rebriefAddendum);
    return buf.toString();
  }

  // ---------- Lifecycle event emitters ----------

  void _emitArrival(CouncilAgent agent) {
    if (_arrivedAgents.contains(agent.id)) return;
    _arrivedAgents.add(agent.id);
    _event(
      CouncilEventType.agentArrived,
      fromAgentId: agent.id,
      message: agent.name,
      data: {'role': agent.role.name, 'customRole': agent.customRole},
    );
  }

  void _emitThinkingStarted(CouncilAgent agent) {
    _event(CouncilEventType.agentThinkingStarted, fromAgentId: agent.id);
  }

  void _emitThinkingEnded(CouncilAgent agent) {
    _event(CouncilEventType.agentThinkingEnded, fromAgentId: agent.id);
  }

  void _emitMessage({
    required String kind,
    required String from,
    required String to,
    required String text,
    Map<String, dynamic>? data,
  }) {
    final merged = <String, dynamic>{'kind': kind};
    if (data != null) merged.addAll(data);
    _event(
      CouncilEventType.messageSent,
      fromAgentId: from,
      toAgentId: to,
      message: text,
      data: merged,
    );
  }

  String _emitLinkStarted({
    required String from,
    required String to,
    required String kind,
  }) {
    final id = 'link_${++_linkSeq}';
    _activeLinks.putIfAbsent('$from->$to', () => <String>[]).add(id);
    _event(
      CouncilEventType.linkStarted,
      fromAgentId: from,
      toAgentId: to,
      data: {'linkId': id, 'kind': kind},
    );
    return id;
  }

  void _emitLinkEnded(String linkId, {String reason = 'completed'}) {
    String? key;
    for (final entry in _activeLinks.entries) {
      if (entry.value.contains(linkId)) {
        key = entry.key;
        break;
      }
    }
    if (key == null) return; // already ended (idempotent)
    final list = _activeLinks[key]!..remove(linkId);
    if (list.isEmpty) _activeLinks.remove(key);
    final parts = key.split('->');
    _event(
      CouncilEventType.linkEnded,
      fromAgentId: parts.isNotEmpty ? parts[0] : '',
      toAgentId: parts.length > 1 ? parts[1] : '',
      data: {'linkId': linkId, 'reason': reason},
    );
  }

  void _event(
    String type, {
    String fromAgentId = '',
    String toAgentId = '',
    String message = '',
    Map<String, dynamic>? data,
  }) {
    final session = _session;
    final mergedData = <String, dynamic>{
      if (session != null) 'runId': session.runId,
      if (session != null) 'roundIndex': session.roundIndex,
      if (data != null) ...data,
    };
    final event = CouncilEvent(
      type: type,
      fromAgentId: fromAgentId,
      toAgentId: toAgentId,
      message: message,
      data: mergedData,
    );
    session?.events.add(event);
    if (!_eventStream.isClosed) _eventStream.add(event);
  }

  /// Bridge from ledger transitions to the public council event stream.
  /// Persists the ledger snapshot back onto the session so a reload can
  /// rehydrate without losing pending dispatches.
  void _onLedgerTransition(CouncilTask task) {
    final session = _session;
    if (session != null) {
      session.tasks
        ..clear()
        ..addAll(_ledger?.tasks ?? const []);
    }
    _event(
      CouncilEventType.taskStateChanged,
      fromAgentId: task.agentId,
      message: task.task,
      data: task.toJson(),
    );
  }

  /// Wraps [CouncilTaskLedger.transition] so an illegal-transition exception
  /// in some unforeseen control path cannot crash the controller. Illegal
  /// transitions are surfaced as a guard-tripped event rather than swallowed.
  void _safeLedgerTransition(
    String taskId,
    CouncilTaskState next, {
    String? lastError,
    String? waitingOn,
    String? nextIntendedAction,
    bool incrementErrorCount = false,
  }) {
    try {
      ledger.transition(
        taskId,
        next,
        lastError: lastError,
        waitingOn: waitingOn,
        nextIntendedAction: nextIntendedAction,
        incrementErrorCount: incrementErrorCount,
      );
    } on LedgerTransitionError catch (e) {
      _emitDispatchGuardTripped(
        'Illegal ledger transition for $taskId: ${e.reason} '
        '(${e.from.name} -> ${e.to.name})',
      );
    }
  }

  /// LOUD failure surface. Never swallowed. Drives the UI's red-banner
  /// "dispatch guard tripped" state so the user sees exactly why the
  /// council refused to ship.
  void _emitDispatchGuardTripped(String reason) {
    _event(
      CouncilEventType.dispatchGuardTripped,
      message: reason,
      data: {
        'successCount': ledger.successCount,
        'failureCount': ledger.failureCount,
        'pendingCount': ledger.pendingCount,
        'errorCountByAgent': ledger.errorCountByAgent,
      },
    );
    // Mirror onto agentError on the orchestrator for legacy panels that
    // already render agentError as a red badge.
    final orchId = _session?.config.orchestrator.id ?? '';
    if (orchId.isNotEmpty) {
      _event(
        CouncilEventType.agentError,
        fromAgentId: orchId,
        message: reason,
      );
    }
  }

  @override
  void dispose() {
    _eventStream.close();
    super.dispose();
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    await persistence.saveSession(session);
  }

  /// Ensures every council participant always has the canonical writable
  /// toolkit. This protects against stale drafts/sessions that may still
  /// carry legacy read-only tool sets.
  CouncilConfig _normalizeConfigTools(CouncilConfig config) {
    CouncilAgent ensure(CouncilAgent agent) {
      final merged = <String>{...kCouncilDefaultTools, ...agent.enabledTools};
      return agent.copyWith(enabledTools: merged);
    }

    return CouncilConfig(
      id: config.id,
      title: config.title,
      brief: config.brief,
      orchestrator: ensure(config.orchestrator),
      agents: config.agents.map(ensure).toList(growable: false),
      finalEvaluator: ensure(config.finalEvaluator),
      createdAt: config.createdAt,
    );
  }
}

/// Full Council toolkit. Council agents need real write + execution access,
/// otherwise they can only "design" without producing artifacts. Approval
/// gating still happens through the chat auto-approve / per-tool allowlist.
///
/// Public so the wizard / any future Council surface can share the same
/// canonical toolset and not silently drift.
const Set<String> kCouncilDefaultTools = {
  // Read & discover
  'read_file',
  'list_dir',
  'tree',
  'search_text',
  'find_file',
  'glob',
  // Write
  'create_file',
  'edit_file',
  'multi_edit',
  'edit_range',
  'append_file',
  'move_file',
  'copy_file',
  'delete_file',
  // Execute & verify
  'run_cmd',
  'verify',
  'check_url',
  // Git context
  'git_status',
  'git_diff',
  'git_log',
  'git_blame',
  // Web
  'web_search',
  'web_fetch',
};

RolePreset? _roleFromName(String? name) {
  if (name == null) return null;
  for (final role in RolePreset.values) {
    if (role.name == name) return role;
  }
  return null;
}

String _roleName(RolePreset role) {
  return switch (role) {
    RolePreset.pentester => S.councilRolePentester,
    RolePreset.reviewer => S.councilRoleReviewer,
    RolePreset.researcher => S.councilRoleResearcher,
    RolePreset.architect => S.councilRoleArchitect,
    RolePreset.tester => S.councilRoleTester,
    RolePreset.writer => S.councilRoleWriter,
    RolePreset.custom => S.councilRoleCustom,
  };
}
