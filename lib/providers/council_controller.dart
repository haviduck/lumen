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
import '../services/council/council_tool_lock.dart';
import '../services/tool_executor.dart';

class CouncilController extends ChangeNotifier {
  CouncilController({
    required this.anthropic,
    required this.copilot,
    required this.persistence,
    required this.isToolAutoApproved,
  });

  final AnthropicService anthropic;
  final CopilotService copilot;
  final CouncilPersistenceService persistence;
  final bool Function(String toolId, String detail) isToolAutoApproved;

  CouncilSession? _session;
  CouncilSession? get session => _session;
  bool get isActive =>
      _session != null &&
      _session!.status != CouncilStatus.done &&
      _session!.status != CouncilStatus.aborted;

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

  Future<void> startCouncil(CouncilConfig config, String workspacePath) async {
    await abort();
    _workspacePath = workspacePath;
    _session = CouncilSession(
      config: config,
      status: CouncilStatus.dispatching,
    );
    _theaterVisible = true;
    _event('session_started', message: config.brief);
    notifyListeners();
    await _persist();
    unawaited(_runOrchestrator());
  }

  Future<List<CouncilAgent>> proposeAgentsForBrief({
    required String brief,
    required CouncilAgent orchestrator,
    int count = 4,
  }) async {
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
      "customRole": "only when role is custom"
    }
  ]
}

Rules:
- Create $count agents.
- Pick complementary roles for the user's brief.
- Include a pentester only when security, threat modeling, auth, secrets, or pentesting is relevant.
- Include a tester whenever implementation or debugging is likely.
- Names should be short and useful in a visual dashboard.

User brief:
$brief
''';

    try {
      final messages = [
        {'role': 'user', 'content': prompt},
      ];
      final split = _splitModel(orchestrator.model);
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
      _event('aborted');
      await _persist();
    }
    _runners.clear();
    _dispatches.clear();
    _userQuestions.clear();
    _activeDispatches = 0;
    notifyListeners();
  }

  Future<void> answerPendingUserQuestion(String answer) async {
    final question = _session?.pendingUserQuestion;
    if (question == null) return;
    question.userAnswer = answer;
    question.resolved = true;
    _session!.pendingUserQuestion = null;
    _event('user_reply', toAgentId: question.fromAgentId, message: answer);
    _userQuestions.remove(question.id)?.complete(answer);
    _session!.status = CouncilStatus.working;
    notifyListeners();
    await _persist();
  }

  Future<void> _runOrchestrator() async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return;

    session.status = CouncilStatus.dispatching;
    session.config.orchestrator.status = CouncilAgentStatus.working;
    notifyListeners();

    final runner = CouncilAgentRunner(
      agent: session.config.orchestrator,
      anthropic: anthropic,
      copilot: copilot,
      toolExecutor: _toolExecutor(session.config.orchestrator, workspace),
      systemPrompt: CouncilProtocol.orchestratorSystemPrompt(session.config),
      userPrompt: 'Begin the Council session now.',
      nativeToolIds: {...CouncilProtocol.orchestratorToolIds},
      onChunk: (chunk) => _appendTranscript(session.config.orchestrator, chunk),
      onCouncilTool: _handleOrchestratorTool,
    );
    _runners.add(runner);
    final result = await runner.run(maxIterations: 24);
    if (!result.cancelled && session.status != CouncilStatus.done) {
      await _finishWithReport(result.content);
    }
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
    return agents.whereType<Map>().take(6).toList().asMap().entries.map((
      entry,
    ) {
      final data = entry.value.cast<String, dynamic>();
      final role = _roleFromName(data['role'] as String?) ?? RolePreset.custom;
      return CouncilAgent(
        id: 'agent_${entry.key}',
        name: (data['name'] as String?)?.trim().isNotEmpty == true
            ? (data['name'] as String).trim()
            : 'Agent ${entry.key + 1}',
        role: role,
        customRole: data['customRole'] as String? ?? '',
        model: model,
        enabledTools: _defaultCouncilTools,
      );
    }).toList();
  }

  List<CouncilAgent> _fallbackAgentsForBrief(
    String brief,
    String model,
    int count,
  ) {
    final b = brief.toLowerCase();
    final roles = <RolePreset>[
      if (b.contains('security') ||
          b.contains('pentest') ||
          b.contains('auth') ||
          b.contains('secret'))
        RolePreset.pentester,
      RolePreset.architect,
      RolePreset.reviewer,
      RolePreset.tester,
      if (b.contains('research') || b.contains('compare'))
        RolePreset.researcher,
      if (b.contains('doc') || b.contains('report')) RolePreset.writer,
    ];
    while (roles.length < count) {
      roles.add(RolePreset.researcher);
    }
    return roles.take(count).toList().asMap().entries.map((entry) {
      final role = entry.value;
      return CouncilAgent(
        id: 'agent_${entry.key}',
        name: _roleName(role),
        role: role,
        model: model,
        enabledTools: _defaultCouncilTools,
      );
    }).toList();
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
      'dispatched',
      fromAgentId: session.config.orchestrator.id,
      toAgentId: agent.id,
      message: task,
      data: {'parallel': parallel},
    );
    agent.status = CouncilAgentStatus.queued;
    agent.currentTask = task;
    session.status = CouncilStatus.working;
    notifyListeners();
    await _persist();

    final future = _runWithDispatchSlot(() => _runAgent(agent, task))
        .catchError((Object error, StackTrace stackTrace) {
          agent
            ..status = CouncilAgentStatus.error
            ..lastError = '$error';
          _event('agent_error', fromAgentId: agent.id, message: '$error');
          notifyListeners();
        });
    if (parallel) {
      _dispatches.add(future);
      unawaited(future);
      return CouncilToolResult(feedback: 'Started ${agent.name} on: $task');
    }

    await future;
    return CouncilToolResult(
      feedback: '${agent.name} finished.\n\n${agent.transcript}',
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

  Future<void> _runAgent(CouncilAgent agent, String task) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return;
    agent.status = CouncilAgentStatus.working;
    _event('agent_started', toAgentId: agent.id, message: task);
    notifyListeners();

    final runner = CouncilAgentRunner(
      agent: agent,
      anthropic: anthropic,
      copilot: copilot,
      toolExecutor: _toolExecutor(agent, workspace),
      systemPrompt: CouncilProtocol.agentSystemPrompt(
        config: session.config,
        agent: agent,
        task: task,
      ),
      userPrompt: task,
      nativeToolIds: {...CouncilProtocol.agentToolIds, ...agent.enabledTools},
      onChunk: (chunk) => _appendTranscript(agent, chunk),
      onCouncilTool: (call) => _handleAgentTool(agent, call),
    );
    _runners.add(runner);
    final result = await runner.run();
    if (result.cancelled) return;
    agent.status = CouncilAgentStatus.done;
    _event('agent_done', fromAgentId: agent.id, message: agent.transcript);
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
    final question = call.arguments['question'] as String? ?? '';
    final entry = CouncilQuestion(
      id: 'pool_${++_questionSeq}',
      fromAgentId: asker.id,
      question: question,
    );
    session.poolQuestions.add(entry);
    session.status = CouncilStatus.awaitingPool;
    asker.status = CouncilAgentStatus.askingPool;
    _event('asked_pool', fromAgentId: asker.id, message: question);
    notifyListeners();
    await _persist();

    for (final agent in session.config.agents) {
      if (agent.id == asker.id) continue;
      agent.status = CouncilAgentStatus.replying;
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
      agent.status = CouncilAgentStatus.idle;
      _event(
        'pool_reply',
        fromAgentId: agent.id,
        toAgentId: asker.id,
        message: answer,
      );
      notifyListeners();
      await _persist();
    }

    entry.resolved = true;
    asker.status = CouncilAgentStatus.working;
    session.status = CouncilStatus.working;
    final feedback = StringBuffer('Council pool replies:\n');
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
    _event('asked_user', fromAgentId: fromAgentId, message: question);
    notifyListeners();
    await _persist();
    final answer = await completer.future;
    _session!.agentById(fromAgentId)?.status = CouncilAgentStatus.working;
    return CouncilToolResult(feedback: 'User answered:\n$answer');
  }

  Future<void> _finishWithReport(String markdown) async {
    final session = _session;
    final workspace = _workspacePath;
    if (session == null || workspace == null) return;
    session.status = CouncilStatus.synthesizing;
    notifyListeners();
    await Future.wait(_dispatches);
    final report = markdown.trim().isEmpty
        ? '# Council Report\n\nNo final report was produced.'
        : markdown.trim();
    final path = await persistence.writeReport(
      workspacePath: workspace,
      session: session,
      markdown: report,
    );
    session
      ..reportMarkdown = report
      ..reportPath = path
      ..status = CouncilStatus.done
      ..finishedAt = DateTime.now();
    session.config.orchestrator.status = CouncilAgentStatus.done;
    _event('reported', message: path);
    notifyListeners();
    await _persist();
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
    agent.transcript += chunk;
    _event('agent_chunk', fromAgentId: agent.id, message: chunk);
    notifyListeners();
  }

  void _event(
    String type, {
    String fromAgentId = '',
    String toAgentId = '',
    String message = '',
    Map<String, dynamic>? data,
  }) {
    _session?.events.add(
      CouncilEvent(
        type: type,
        fromAgentId: fromAgentId,
        toAgentId: toAgentId,
        message: message,
        data: data,
      ),
    );
  }

  Future<void> _persist() async {
    final session = _session;
    if (session == null) return;
    await persistence.saveSession(session);
  }
}

const Set<String> _defaultCouncilTools = {
  'read_file',
  'search_text',
  'glob',
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
