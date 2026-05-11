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
  static const int _maxPoolExchangesPerSession = 2;
  static const int _maxPoolTargetsPerQuestion = 3;
  final List<String> _queuedSynthesisPings = <String>[];
  int _orchestratorFailureStreak = 0;
  bool _orchestratorFailureEscalated = false;
  // After this many silent nudges, escalate to the user. Lowered from
  // 3 → 2 in 2026-05 — three retries felt like the council was running
  // forever even when the work was clearly stuck, and the user had no
  // way to see what was wrong until the last strike. Two retries is
  // plenty for legit "model briefly lost focus" recoveries; anything
  // beyond that, the user wants to know.
  static const int _orchestratorFailureEscalationThreshold = 2;

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
You are designing a compact expert council to tackle the user's brief below.

Return ONLY JSON. No markdown. Shape:
{
  "agents": [
    {
      "name": "short distinctive name",
      "role": "pentester|reviewer|researcher|architect|tester|writer|custom",
      "customRole": "deep specialist remit; required when role is custom",
      "mission": "what this agent must uncover or improve",
      "rationale": "why this role is needed for THIS brief"
    }
  ]
}

How to think about the team:
- Read the user's brief carefully and design a roster that actually fits it. The user knows their own problem; your job is to translate that into the smallest team of complementary specialists who can ship a real artifact for what they asked.
- Team size is 3–8. About $targetCount is a starting point — go smaller for tight focused asks, larger for ambitious product/platform/agentic-system work.
- Pick sharp, complementary specialists. "Architect / Reviewer / Tester" alone is rarely the right roster for anything interesting.
- Use the `custom` role when a built-in label would understate what the agent actually owns. Custom roles get a `customRole` describing the specific remit.
- Every agent has a distinct mission and is capable of pushing back on at least one other agent.
- Include a pentester / red-team role only when the brief is genuinely about security, attack surface, threat modeling, auth, secrets, exploitation, or hardening. Don't add one for "make this pretty" or "refactor this code".
- Include a tester or QA-shaped role when implementation, debugging, or correctness validation matters.
- Names are short, distinctive, and useful in a visual dashboard.

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
      final result = await runner.run(maxIterations: 24);
      endThinking();
      if (result.cancelled) return;
      if (session.status == CouncilStatus.done ||
          session.status == CouncilStatus.awaitingFollowup ||
          session.status == CouncilStatus.aborted) {
        _resetOrchestratorFailureWatchdog();
        return;
      }

      final earlyFailureReason = _orchestratorEarlyExitReason(session);
      if (earlyFailureReason != null) {
        await _handleOrchestratorFailure(
          session: session,
          reason: earlyFailureReason,
          draftReport: result.content,
        );
        return;
      }

      _resetOrchestratorFailureWatchdog();
      await _finishWithReport(result.content);
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

  Future<void> _handleOrchestratorFailure({
    required CouncilSession session,
    required String reason,
    required String draftReport,
  }) async {
    _orchestratorFailureStreak++;
    final strikes = _orchestratorFailureStreak;
    final orch = session.config.orchestrator;

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
Orchestrator watchdog nudge ($strikes/$_orchestratorFailureEscalationThreshold).

Last failure signal:
$reason
$draftSnippet

Do NOT finalize yet. Resume orchestration, wait for in-flight work, and continue dispatching/synthesizing as needed.
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
  ///
  /// Emits a `agentError`-level event so the UI shows the stall, and
  /// nudges the runner with a continuation prompt. After 3 auto-nudges
  /// the runner stops nudging and the user can ping manually.
  bool _onAgentStall(String agentId, int silentSeconds) {
    final session = _session;
    if (session == null) return false;
    if (session.status == CouncilStatus.aborted ||
        session.status == CouncilStatus.done) {
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
  /// True when the user is allowed to ping a specific agent. Only
  /// agents with a live runner (currently executing) can be pinged.
  /// Also checks agent status — a runner may linger in [_runners]
  /// after its [run()] loop exits, but the note queue would never
  /// be drained so pinging it is a no-op black hole.
  bool canPingAgent(String agentId) {
    final s = _session;
    if (s == null) return false;
    if (s.status == CouncilStatus.done || s.status == CouncilStatus.aborted) {
      return false;
    }
    final agent = s.agentById(agentId);
    if (agent == null) return false;
    if (agent.status == CouncilAgentStatus.done ||
        agent.status == CouncilAgentStatus.error ||
        agent.status == CouncilAgentStatus.idle) {
      return false;
    }
    return _runners.any(
      (r) => r.agent.id == agentId && !r.token.isCancelled,
    );
  }

  /// Inject a mid-session note into a specific agent's runner. The
  /// note is queued on the runner's message stream and picked up at
  /// its next iteration boundary. No-op if the agent has no live
  /// runner (use [canPingAgent] to check beforehand).
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

    final runner = _runners.firstWhere(
      (r) => r.agent.id == agentId && !r.token.isCancelled,
      orElse: () => throw StateError('No live runner for $agentId'),
    );

    runner.addUserNote(trimmed, images: images);
    final eventMessage = images.isEmpty
        ? trimmed
        : '$trimmed [+${images.length} image(s) attached]';
    _event(
      CouncilEventType.userPingedAgent,
      toAgentId: agentId,
      message: eventMessage,
    );
    notifyListeners();
    await _persist();
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
        // The "must have one pool exchange before report" gate that
        // used to live here was removed — it forced the orchestrator
        // to dispatch fake collaboration tasks just to satisfy the
        // gate, even when the work was mechanical and shippable.
        // Pool is now genuinely opt-in: agents call it when they
        // actually have a load-bearing question for a peer; otherwise
        // they ship and the orchestrator reports.
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

  Future<CouncilToolResult> _handleAgentTool(
    CouncilAgent agent,
    CouncilToolCall call,
  ) {
    switch (call.name) {
      case CouncilProtocol.askPoolToolId:
        return _askPool(agent, call);
      case CouncilProtocol.askUserToolId:
        return _askUser(agent.id, call);
      default:
        return Future.value(
          CouncilToolResult(feedback: 'Unknown Council tool: ${call.name}'),
        );
    }
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
    buf.writeln(
      'Proceed to synthesize findings and produce the final report '
      'via council_report, or dispatch a follow-up wave if gaps remain.',
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
      return CouncilToolResult(
        feedback:
            'Started ${agent.name} on: $task\n\nContinue coordinating the Council. If this work may benefit from another role, dispatch a companion task or have the agent use council_ask_pool before final synthesis.',
      );
    }

    await future;
    return CouncilToolResult(
      feedback:
          '${agent.name} finished this task.\n\n${agent.transcript}\n\nBefore final report, consider whether another agent should challenge or verify these findings through a pool question or follow-up dispatch.',
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
    );
    _runners.add(runner);
    final result = await runner.run();
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
          : 'Evaluate the Council now and produce the final report. '
              'You MUST output the complete structured report — not a '
              'preamble, not a one-liner. Begin the report immediately.';

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
      );
      _runners.add(runner);
      final result = await runner.run(maxIterations: 4);

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
  ///
  /// Heuristics (any one trips):
  /// - Empty or near-empty (< 200 chars).
  /// - No section headings (no `##` markers).
  /// - Output is shorter than 600 chars AND contains hedging phrases
  ///   like "let me verify", "i need to", "i'll start by" without
  ///   actually producing the report content.
  static String? _evaluatorOutputFailureReason(String output) {
    final trimmed = output.trim();
    if (trimmed.length < 200) {
      return 'output too short (${trimmed.length} chars; minimum 200)';
    }
    if (!trimmed.contains('##')) {
      return 'no markdown section headings found';
    }
    if (trimmed.length < 600) {
      final lower = trimmed.toLowerCase();
      const hedges = [
        'let me verify',
        'let me start by',
        'i need to verify',
        'i\'ll start',
        'i will start',
        'let me first',
        'i\'ll begin',
      ];
      if (hedges.any(lower.contains)) {
        return 'hedging preamble without report body '
            '(${trimmed.length} chars)';
      }
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
WATCHDOG RETRY $attempt/3.

Your previous attempt was REJECTED. Reason: $reason.

Previous output (first 300 chars):
"""
$preview
"""

This is unacceptable. The user is waiting for a complete pentest report. You have ALL the data you need in the draft below — findings, agent transcripts, severity assessments. Your job is NOT to re-investigate. Your job is to PRODUCE THE REPORT NOW.

Strict requirements for this attempt:
1. Begin output with `# ` (markdown H1 title) — no preamble, no "let me", no "I need to".
2. Include EVERY section heading from the report template: Executive Summary, Target & Scope, Attack Tree, Findings (with subsections per severity), Exploit Chains, Agent Attack Log, What Changed Because Agents Conspired, Remediation Priority Matrix, Open Attack Vectors.
3. Findings table MUST contain every finding from the draft. If you can't verify one, mark `verified? = no` with a reason — do NOT delete it.
4. Output must be at least 1500 characters. The draft you were given is already well-structured; you are ENRICHING it with verification, chains, and remediation, not summarizing it.
5. Output the report directly — no meta commentary, no "here is the report:", no fenced markdown wrapper.

Produce the full report now. No preamble.
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
    notifyListeners();
  }

  String _cleanTranscriptChunk(String chunk) {
    return chunk.replaceAll(
      RegExp(r'<!--\s*LUMEN_THINK_(START|END)\s*-->', caseSensitive: false),
      '',
    );
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
