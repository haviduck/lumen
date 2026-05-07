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
import '../services/tool_executor.dart';

class CouncilController extends ChangeNotifier {
  CouncilController({
    required this.anthropic,
    required this.copilot,
    required this.persistence,
    required this.isToolAutoApproved,
    this.onReportPersisted,
  });

  final AnthropicService anthropic;
  final CopilotService copilot;
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
  bool _collaborationNudgeUsed = false;
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
    _event(CouncilEventType.sessionStarted, message: config.brief);
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
You are designing a compact expert council for a software/technical task.

Return ONLY JSON. No markdown. Shape:
{
  "agents": [
    {
      "name": "short distinctive name",
      "role": "pentester|reviewer|researcher|architect|tester|writer|custom",
      "customRole": "deep specialist remit; required when role is custom",
      "mission": "what this agent must uncover or improve",
      "rationale": "why this role is needed for this brief"
    }
  ]
}

Rules:
- Choose the team size yourself between 3 and 8 agents. For ambitious product/platform prompts, prefer 6-8.
- For this brief, aim for about $targetCount agents unless you can justify fewer.
- Pick sharp, complementary specialist roles. Avoid generic "Architect / Reviewer / Tester" only.
- Prefer custom roles when built-in labels are too blunt.
- Each agent must have a distinct mission and must be capable of pushing back on at least one other agent.
- Include a pentester only when security, threat modeling, auth, secrets, or pentesting is relevant.
- Include a tester whenever implementation or debugging is likely.
- If the user asks to make an IDE, app, product, workflow, or agentic system exceptional, include:
  - product/UX strategy,
  - agent orchestration/context/tools,
  - codebase cartography,
  - interaction design,
  - reliability/testing,
  - performance/platform,
  - security/safety if tools or code execution are involved,
  - a skeptical evaluator or adversarial reviewer.
- Names should be short and useful in a visual dashboard.

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
      final raw = split.provider == 'claude'
          ? await anthropic.generateChat(messages, model: split.rawModel)
          : await copilot.generateChat(messages, model: split.rawModel);
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
    for (final runner in _runners) {
      runner.token.cancel();
    }
    if (_session != null && isActive) {
      _session!.status = CouncilStatus.aborted;
      _session!.finishedAt = DateTime.now();
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
    _activeDispatches = 0;
    _collaborationNudgeUsed = false;
    _orchestratorRunner = null;
    final pending = _roundTwoDecision;
    _roundTwoDecision = null;
    if (pending != null && !pending.isCompleted) pending.complete(false);
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

    final runner = CouncilAgentRunner(
      agent: session.config.orchestrator,
      anthropic: anthropic,
      copilot: copilot,
      toolExecutor: _toolExecutor(session.config.orchestrator, workspace),
      systemPrompt: CouncilProtocol.orchestratorSystemPrompt(session.config),
      userPrompt: userPrompt,
      nativeToolIds: {...CouncilProtocol.orchestratorToolIds},
      onChunk: (chunk) => _appendTranscript(session.config.orchestrator, chunk),
      onCouncilTool: _handleOrchestratorTool,
    );
    _runners.add(runner);
    _orchestratorRunner = runner;
    notifyListeners();
    try {
      final result = await runner.run(maxIterations: 24);
      _emitThinkingEnded(session.config.orchestrator);
      if (!result.cancelled &&
          session.status != CouncilStatus.done &&
          session.status != CouncilStatus.awaitingFollowup) {
        await _finishWithReport(result.content);
      }
    } finally {
      if (identical(_orchestratorRunner, runner)) {
        _orchestratorRunner = null;
        notifyListeners();
      }
    }
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
      return 'Begin the Council session now.';
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
    return [
      if (briefLower.contains('security') ||
          briefLower.contains('pentest') ||
          briefLower.contains('auth') ||
          briefLower.contains('secret'))
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
      case CouncilProtocol.askUserToolId:
        return _askUser(_session!.config.orchestrator.id, call);
      case CouncilProtocol.reportToolId:
        final ledgerRefusal = ledger.refusalReasonForReport();
        if (ledgerRefusal != null) {
          _emitDispatchGuardTripped(ledgerRefusal);
          return CouncilToolResult(
            feedback:
                'BLOCKED: $ledgerRefusal You MUST invoke council_dispatch '
                'on at least one agent (and let it complete) before '
                'council_report. Phantom reports are forbidden.',
          );
        }
        if (!_hasPoolCollaboration() && !_collaborationNudgeUsed) {
          _collaborationNudgeUsed = true;
          return const CouncilToolResult(
            feedback:
                'Before the final report, force one Council collaboration round. Dispatch a short follow-up task to an appropriate agent and explicitly require them to call council_ask_pool for challenge/validation.',
          );
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

  Future<CouncilToolResult> _dispatch(CouncilToolCall call) async {
    final session = _session!;
    final agentId = call.arguments['agentId'] as String? ?? '';
    final task = call.arguments['task'] as String? ?? '';
    final parallel = call.arguments['parallel'] == true;
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
    agent
      ..status = CouncilAgentStatus.idle
      ..currentTask = '';
    notifyListeners();
    await _persist();
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
        toolExecutor: _toolExecutor(agent, workspace),
        systemPrompt: CouncilProtocol.poolReplyPrompt(
          config: session.config,
          agent: agent,
          question: question,
        ),
        userPrompt: question,
        nativeToolIds: const <String>{},
        onChunk: (_) {},
        onCouncilTool: (_) async => const CouncilToolResult(feedback: ''),
      );
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
    }

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
    // executed successfully. This is the explicit fix for "planned but
    // nothing happened" — see services/council/FAILURE_MODES.md.
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
      session.status = CouncilStatus.error;
      session.config.orchestrator
        ..status = CouncilAgentStatus.error
        ..lastError = refusal;
      notifyListeners();
      await _persist();
      return;
    }
    session.status = CouncilStatus.synthesizing;
    notifyListeners();
    await Future.wait(_dispatches);
    final draftReport = markdown.trim().isEmpty
        ? '# Council Report\n\nNo final report was produced.'
        : markdown.trim();
    try {
      final evaluatorOutput = await _runFinalEvaluator(draftReport);
      // Split the evaluator output into its two contracted parts: the
      // markdown report (for the user / artifact) and the structured
      // `council_followup` JSON block (for the round-two re-brief loop).
      final split = _splitEvaluatorOutput(evaluatorOutput, draftReport);
      final report = split.markdown;
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

  bool _hasPoolCollaboration() {
    return _session?.events.any(
          (e) =>
              e.type == CouncilEventType.askedPool ||
              e.type == CouncilEventType.poolReply,
        ) ??
        false;
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

    final runner = CouncilAgentRunner(
      agent: evaluator,
      anthropic: anthropic,
      copilot: copilot,
      toolExecutor: _toolExecutor(evaluator, workspace),
      systemPrompt: CouncilProtocol.finalEvaluatorSystemPrompt(
        config: session.config,
        draftReport: draftReport,
      ),
      userPrompt: 'Evaluate the Council now and produce the final report.',
      nativeToolIds: evaluator.enabledTools,
      onChunk: (chunk) => _appendTranscript(evaluator, chunk),
      onCouncilTool: (_) async => const CouncilToolResult(
        feedback: 'The final evaluator should produce prose only.',
      ),
    );
    _runners.add(runner);
    final result = await runner.run(maxIterations: 4);
    _emitThinkingEnded(evaluator);
    if (result.cancelled || evaluator.transcript.trim().isEmpty) {
      evaluator.status = CouncilAgentStatus.error;
      _event(
        CouncilEventType.evaluatorDone,
        fromAgentId: evaluator.id,
        message: draftReport,
      );
      return draftReport;
    }
    evaluator.status = CouncilAgentStatus.done;
    _event(
      CouncilEventType.evaluatorDone,
      fromAgentId: evaluator.id,
      message: evaluator.transcript,
    );
    _emitMessage(
      kind: CouncilMessageKind.review,
      from: evaluator.id,
      to: 'pool',
      text: _summariseTranscript(evaluator.transcript),
    );
    notifyListeners();
    return evaluator.transcript.trim();
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
