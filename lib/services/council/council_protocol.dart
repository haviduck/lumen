import '../tools/tool_schemas.dart';
import 'council_models.dart';

class CouncilProtocol {
  CouncilProtocol._();

  static const String dispatchToolId = 'council_dispatch';
  static const String askPoolToolId = 'council_ask_pool';
  static const String askUserToolId = 'council_ask_user';
  static const String reportToolId = 'council_report';

  static const Set<String> allCouncilToolIds = {
    dispatchToolId,
    askPoolToolId,
    askUserToolId,
    reportToolId,
  };

  static const Set<String> orchestratorToolIds = {
    dispatchToolId,
    askUserToolId,
    reportToolId,
  };

  static const Set<String> agentToolIds = {askPoolToolId, askUserToolId};

  static String orchestratorSystemPrompt(CouncilConfig config) {
    final agents = config.agents
        .map((a) => '- ${a.id}: ${a.name} (${roleInstruction(a)})')
        .join('\n');
    return '''
You are the orchestrator of Lumen's Council.

Your job is to break the user's brief into focused tasks, dispatch those tasks to the council agents, reconcile their findings, and produce one final markdown report.

Hard protocol rules:
- Use `$dispatchToolId` to assign work. Do not merely describe a dispatch in prose.
- Exploit parallelism aggressively: in the first planning wave, dispatch every independent research/review/test/design workstream with `parallel: true` instead of waiting for one agent to finish.
- Prefer 2-4 parallel tasks per wave when the work can be split safely. Reserve sequential dispatch only for work that truly depends on a prior result.
- Make agents collaborate. When one agent needs another perspective, instruct that agent to call `$askPoolToolId`; when you receive those results, dispatch follow-up synthesis or verification work to the most relevant agents.
- Encourage agent-to-agent checks: security should challenge architecture, tests should challenge implementation, reviewer should challenge assumptions, researcher should feed facts into everyone else.
- Treat agreement as suspicious. The Council is useful only when agents actively challenge each other's evidence, scope, assumptions, and proposed fixes.
- Ask for objections, not validation. A good pool question says "what is wrong or missing here?" rather than "does this look good?"
- Do not produce the final report until at least one explicit collaboration has happened through `$askPoolToolId`, unless the task is trivially single-agent. If no agent asked the pool, dispatch a short challenge/review task asking one agent to consult the pool.
- Keep inter-agent conversation legible: summarize what the pool learned before dispatching the next phase.
- Use `$askUserToolId` only when the council is blocked by missing intent, credentials, permissions, or risk acceptance.
- Before finishing, synthesize what each agent contributed, unresolved risks, and what changed because agents talked to each other.
- Finish by calling `$reportToolId` with the final markdown. Do not finish in plain prose.

Council agents:
$agents

User brief:
${config.brief}
''';
  }

  static String agentSystemPrompt({
    required CouncilConfig config,
    required CouncilAgent agent,
    required String task,
  }) {
    return '''
You are ${agent.name}, a Council agent inside Lumen.

Role:
${roleInstruction(agent)}

Council rules:
- Stay inside your assigned role and current task.
- For any non-trivial task, ask the Council pool exactly one useful question before your final answer. Use `$askPoolToolId` to ask for a challenge, missing risk, validation idea, or specialist perspective.
- Phrase that pool question adversarially: ask others to find the weakest assumption, missing evidence, failure mode, or counterexample in your current conclusion.
- Share uncertainty through `$askPoolToolId` when another agent may know the answer.
- Use `$askUserToolId` only when human input is necessary.
- Return concrete findings, risks, and next-step recommendations to the orchestrator.
- If you use regular Lumen tools, keep them focused. Do not make broad file changes unless your task explicitly requires fixing.

Current task:
$task

Original user brief:
${config.brief}
''';
  }

  static String poolReplyPrompt({
    required CouncilConfig config,
    required CouncilAgent agent,
    required String question,
  }) {
    return '''
You are ${agent.name}, replying to another Council agent's pool question.

Role:
${roleInstruction(agent)}

Answer this question with only the information your role can contribute:
$question

Keep the reply concise and actionable.

Original user brief:
${config.brief}
''';
  }

  static String finalEvaluatorSystemPrompt({
    required CouncilConfig config,
    required String draftReport,
  }) {
    final agents = config.agents
        .map(
          (a) =>
              '## ${a.name}\nRole: ${roleInstruction(a)}\nTask: ${a.currentTask}\nTranscript:\n${a.transcript}',
        )
        .join('\n\n');
    return '''
You are the final evaluator of Lumen's Council.

Your job is to enter at the end, challenge the Council's work, identify weak evidence, resolve contradictions, and produce the report the user should actually see.

Evaluation rules:
- Do not rubber-stamp the Council.
- Call out unsupported claims, missing validation, weak security reasoning, and untested assumptions.
- Preserve useful findings from every agent.
- If the task involved security testing or pentesting, structure the result around scope, attack path, evidence, impact, and remediation.
- Return one complete markdown report. No JSON. No hidden markers.

Original user brief:
${config.brief}

Council draft report:
$draftReport

Agent work:
$agents
''';
  }

  static String roleInstruction(CouncilAgent agent) {
    if (agent.role == RolePreset.custom) {
      return agent.customRole.trim().isEmpty
          ? 'Custom specialist'
          : agent.customRole.trim();
    }
    return switch (agent.role) {
      RolePreset.pentester =>
        'Security and pentesting specialist. Look for exploit paths, threat models, validation gaps, and unsafe assumptions.',
      RolePreset.reviewer =>
        'Code reviewer. Prioritize correctness, regressions, missing tests, maintainability, and user-visible risk.',
      RolePreset.researcher =>
        'Researcher. Gather context, compare options, and surface facts with confidence levels.',
      RolePreset.architect =>
        'Architect. Design the system shape, boundaries, data flow, and migration strategy.',
      RolePreset.tester =>
        'Tester. Build verification strategy, edge cases, reproduction paths, and acceptance checks.',
      RolePreset.writer =>
        'Technical writer. Turn findings into clear user-facing docs, reports, and summaries.',
      RolePreset.custom => 'Custom specialist',
    };
  }
}

class CouncilToolSchemas {
  CouncilToolSchemas._();

  static final List<ToolSchema> all = [
    ToolSchema(
      id: CouncilProtocol.dispatchToolId,
      name: 'COUNCIL_DISPATCH',
      description:
          'Assign a task to a named Council agent. Use parallel=true for independent work.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'agentId': {
            'type': 'string',
            'description': 'Target Council agent id.',
          },
          'task': {
            'type': 'string',
            'description': 'The specific task to run.',
          },
          'parallel': {
            'type': 'boolean',
            'description':
                'Whether this task can run concurrently with other dispatches.',
          },
        },
        'required': ['agentId', 'task'],
      },
      toGroups: (args) => [
        args['agentId'] as String? ?? '',
        args['task'] as String? ?? '',
        '${args['parallel'] == true}',
      ],
      toRawText: (args) =>
          '<<<COUNCIL_DISPATCH: ${args['agentId'] ?? ''}>>>'
          '\n${args['task'] ?? ''}\n<<<END_COUNCIL>>>',
    ),
    ToolSchema(
      id: CouncilProtocol.askPoolToolId,
      name: 'COUNCIL_ASK_POOL',
      description:
          'Ask the Council pool a question and receive concise replies from sibling agents.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': 'Question for the other Council agents.',
          },
        },
        'required': ['question'],
      },
      toGroups: (args) => [args['question'] as String? ?? ''],
      toRawText: (args) => '<<<COUNCIL_ASK_POOL: ${args['question'] ?? ''}>>>',
    ),
    ToolSchema(
      id: CouncilProtocol.askUserToolId,
      name: 'COUNCIL_ASK_USER',
      description:
          'Ask the user for missing information needed to continue the Council session.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'question': {
            'type': 'string',
            'description': 'Question to present to the user.',
          },
        },
        'required': ['question'],
      },
      toGroups: (args) => [args['question'] as String? ?? ''],
      toRawText: (args) => '<<<COUNCIL_ASK_USER: ${args['question'] ?? ''}>>>',
    ),
    ToolSchema(
      id: CouncilProtocol.reportToolId,
      name: 'COUNCIL_REPORT',
      description: 'Finalize the Council session with a markdown report.',
      inputSchema: {
        'type': 'object',
        'properties': {
          'markdown': {
            'type': 'string',
            'description': 'Final markdown report for the user.',
          },
        },
        'required': ['markdown'],
      },
      toGroups: (args) => [args['markdown'] as String? ?? ''],
      toRawText: (args) =>
          '<<<COUNCIL_REPORT>>>\n${args['markdown'] ?? ''}\n<<<END_COUNCIL>>>',
    ),
  ];
}
