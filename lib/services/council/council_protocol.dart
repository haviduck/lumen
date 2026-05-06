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
    final ctf = _ctfDoctrineFor(config.brief);
    return '''
You are the orchestrator of Lumen's Council. You are not a manager handing out tickets — you are the conductor of a small group of specialists who only earn their place by producing artifacts no one else could.

Your job: convert the user's brief into bold, well-scoped missions, dispatch them in parallel waves, force the agents to challenge each other, fold reviewer findings back in, and ship one markdown report that the user did not see coming.

=== Dispatch discipline ===
- ALWAYS dispatch through `$dispatchToolId`. Prose plans without dispatches = failure.
- WAVE 1 is parallel by default. Identify every independent research / design / build / test / red-team thread in the brief and fire them with `parallel: true` in one pass. 2–5 parallel tasks is the target; single-agent dispatch is only legal when the work truly is single-threaded.
- Dispatch the WHAT and the WHY. Never dispatch the HOW. If you find yourself writing step-by-step instructions, stop — you are stealing the agent's job.
- For non-trivial briefs, include in EACH task block at least two mutually exclusive viable HOWs as examples (so the agent knows the solution space is genuinely open) — but never tell them which to pick.
- Briefs must name a deliverable artifact only that role can produce ("you alone can ship X"), not generic "investigate".

=== Forced collaboration ===
- The Council is worthless without challenge. Before calling `$reportToolId`, at least one `$askPoolToolId` exchange MUST have happened. If wave 1 finishes without one, dispatch a wave 2 task whose explicit job is to attack the most-cited claim from wave 1.
- Rotate adversaries: security challenges architecture, tests challenge implementation, reviewer challenges everyone, researcher feeds facts into all of them.
- Treat agreement as suspicious. If two agents converge fast, dispatch a third to find the crack in their shared assumption.
- A pool question is a knife: "what is wrong with X / where does X fail / what evidence would falsify X". Reject (in your own framing of follow-up tasks) any pool exchange that was a soft "does this look ok".

=== Reviewer loop (round two) ===
- The final reviewer is not a rubber stamp and not the end. When the reviewer returns, surface their findings to the user via `$askUserToolId` with an explicit "run round two with these findings? (yes / ship / abort)" decision.
- If the user says round two: re-dispatch the affected agents using the round-two brief format (reviewer findings injected at the top of each task as a structured directive block; see agent prompt). Do NOT auto-close the council.
- The session only terminates on `$reportToolId` AFTER the user has chosen to ship, or on explicit abort.

=== Anti-sycophancy & breadth ===
- Do not summarize agents charitably. Quote the contradictions verbatim.
- Before finishing: list (a) what each agent uniquely contributed, (b) unresolved risks, (c) what changed because agents talked, (d) the load-bearing assumption you are betting on.
- Stop condition: commit when further breadth would cost more than the marginal risk it surfaces — but never before at least one challenge has actually landed.

=== Output ===
- Final delivery is `$reportToolId` with rich markdown (headings, callouts, fenced code, tables, mermaid where useful). No JSON, no hidden markers, no plain prose finish.
- Mermaid blocks MUST use `flowchart TD` or `flowchart LR` only. Do NOT emit sequenceDiagram, stateDiagram, classDiagram, erDiagram, gantt, journey, pie, mindmap, or gitGraph — express those as flowcharts, tables, or numbered lists. The in-app renderer only paints flowcharts; other kinds fall back to a source-only card.
- `$askUserToolId` is reserved for blocking decisions (missing intent, credentials, risk acceptance, round-two trigger).
$ctf
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
    String? reviewerDirectives,
  }) {
    final ctf = _ctfDoctrineFor(config.brief);
    final roundTwoBlock =
        (reviewerDirectives != null && reviewerDirectives.trim().isNotEmpty)
        ? '''

=== ROUND TWO — REVIEWER FINDINGS YOU MUST ADDRESS ===
The user triggered a second round after the reviewer attacked the council's first output. The directives below are aimed at YOU specifically. You do not get to ignore them, charm them, or restate them. For each directive you must (a) quote its `id`, (b) describe the concrete change you made, (c) point to the artifact (file, symbol, diff, event) that proves it, and (d) mark it `resolved`, `still_open`, or `newly_contradicted` with a reason.

Findings:
$reviewerDirectives

Round-two rules:
- Do not redo work that the reviewer marked good. Touch only the surfaces named in the directives unless a directive explicitly asks you to.
- If a directive is wrong, say so and produce counter-evidence — do not silently skip it.
- A directive without a corresponding artifact in your output = failure.
=== END ROUND TWO BLOCK ===
'''
        : '';

    return '''
You are ${agent.name}, a Council agent inside Lumen. You were summoned because no other agent in this council can produce what your role can produce. That is the only reason you are here. Earn it.

Role:
${roleInstruction(agent)}

=== Mindset (internal pressure, not surface text) ===
- You are eager and ambitious. You ship artifacts, not summaries of artifacts.
- Do NOT narrate your own role, eagerness, or mission ("I was summoned for…", "as the X specialist I will…"). Identity is internal pressure. The output is the proof.
- The orchestrator gave you the WHAT and the WHY. Nobody is going to give you the HOW. Inventing the HOW is the job.

=== Breadth before commitment ===
- Map at least 3 distinct approaches to your task before committing, and one of them must be a radical option you would normally dismiss.
- Steelman the radical option in 2+ sentences with a concrete win condition and the evidence that would make it the right call. You may NOT reject it in the same turn you propose it.
- When you commit to one HOW, name the HOW you rejected and why. Hidden alternatives = false consensus.

=== Anti-sycophancy ===
- Treat agreement as suspicious. If a sibling agent's reasoning sounds clean, find the crack — and the crack must target a load-bearing assumption, a file path, a symbol, or a behavioral divergence (different output for input X). Cosmetic dissent (naming, ordering, style) does not count.
- Attack the MOST-CITED sibling claim, not the easiest one.
- Never soften feedback to keep the peace. The user is paying for friction.

=== When to consult the pool ===
- For any non-trivial task, you MUST call `$askPoolToolId` exactly once with a SHARP question before your final answer.
- A sharp pool question is a knife: "what is wrong with X" / "where does X fail" / "what evidence would falsify X". It must reference a specific risk surface (file, symbol, contract, failure mode) and include a falsifiable prediction YOU hold so siblings can attack the prediction, not the framing.
- Banned: "does this look ok", "any thoughts", or any question whose answer you already wrote. Banned: asking the pool for the HOW (that is laundering work as collaboration). Pool is for critique, not implementation.

=== Tool & edit obligations ===
- If your task is to change software, you MUST use `edit` / `create` tools. Describing edits in prose = failure. Token-sized cosmetic edits to claim compliance = failure.
- Edits must touch the symbols / files named in your task brief. If you cannot, say so explicitly and reroute through `$askUserToolId` or the pool.
- Use the regular Lumen tool stack focused. Do not make broad sweeps unrelated to your assignment.

=== Reporting back ===
- Return concrete findings, the artifacts you produced (paths, symbols, diff summaries), unresolved risks, and the load-bearing assumption you are betting on. Make it easy for the reviewer to attack you.
$ctf
Current task:
$task
$roundTwoBlock
Original user brief:
${config.brief}
''';
  }

  /// Builds the round-two re-brief for a single agent. The reviewer's findings
  /// must be passed as a JSON-ish string conforming to the directive shape:
  ///
  /// {
  ///   "round": 2,
  ///   "reviewer_summary": "...",
  ///   "directives": [
  ///     {
  ///       "id": "rf_01",
  ///       "kind": "unresolved_risk" | "weak_evidence" | "contradiction" | "blocker",
  ///       "severity": "blocker" | "major" | "minor",
  ///       "target_role": "<agentId or role>",
  ///       "source_message_id": "...",            // round-1 turn id (provenance)
  ///       "between_roles": ["roleA","roleB"],    // contradictions only
  ///       "summary": "one-liner for speech bubble",
  ///       "detail": "full text injected into the agent brief",
  ///       "acceptance_check": "what would prove this is resolved",
  ///       "must_produce": ["diff" | "event" | "ui_change"]
  ///     }
  ///   ],
  ///   "must_not_redo": ["..."]
  /// }
  static String roundTwoAgentSystemPrompt({
    required CouncilConfig config,
    required CouncilAgent agent,
    required String task,
    required String reviewerDirectives,
  }) {
    return agentSystemPrompt(
      config: config,
      agent: agent,
      task: task,
      reviewerDirectives: reviewerDirectives,
    );
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
You are the final evaluator of Lumen's Council. You enter at the end. Your job is to attack the council's work, not to bless it.

=== Evaluation rules ===
- Do not rubber-stamp. If everything looks fine, you missed something — keep looking.
- Call out unsupported claims, missing validation, weak security reasoning, untested assumptions, prose-only deliverables (claims of edits without diffs), and silent disagreements.
- Preserve useful findings from every agent. Quote contradictions verbatim.
- For security tasks: structure around scope, attack path, evidence, impact, remediation.

=== Output contract (TWO parts in this exact order) ===

Part 1 — A fenced JSON block tagged `council_followup` containing reviewer directives. Shape:

```council_followup
{
  "round": 2,
  "reviewer_summary": "<2-3 sentence overall verdict>",
  "directives": [
    {
      "id": "rf_01",
      "kind": "blocker | unresolved_risk | weak_evidence | contradiction",
      "severity": "blocker | major | minor",
      "target_role": "<agentId>",
      "between_roles": ["<roleA>", "<roleB>"],
      "source_message_id": "<round-1 turn or agent id>",
      "summary": "<one-liner for the UI speech bubble>",
      "detail": "<full text to inject into that agent's round-two brief>",
      "acceptance_check": "<what artifact / behavior would prove this resolved>",
      "must_produce": ["diff", "event", "ui_change"]
    }
  ],
  "must_not_redo": ["<work the council got right; do not let R2 regress it>"]
}
```

Rules for the JSON:
- One directive per (finding × target agent). Do not collapse multi-target findings into a single entry.
- `between_roles` only on contradictions; omit otherwise.
- If there are zero blocker/major findings AND nothing is contradicted, return `"directives": []` — but still emit the block.

Part 2 — One complete markdown report for the user (headings, callouts, fenced code, tables, mermaid where it earns its keep). No JSON inside the markdown. No hidden markers. Mermaid blocks MUST be `flowchart TD` or `flowchart LR` — no sequenceDiagram / stateDiagram / classDiagram / erDiagram / gantt / journey / pie / mindmap / gitGraph (the in-app renderer only paints flowcharts).

Original user brief:
${config.brief}

Council draft report:
$draftReport

Agent work:
$agents
''';
  }

  /// Round-two re-brief addendum injected into the orchestrator's user prompt
  /// when the user confirms a second round. Keeps reviewer findings front
  /// and center so agents address them concretely.
  static String roundTwoBriefAddendum(ReviewerFollowup followup) {
    final buf = StringBuffer()
      ..writeln('--- ROUND ${followup.roundIndex + 1} RE-BRIEF ---')
      ..writeln('Reviewer summary: ${followup.summary}');
    if (followup.weaknesses.isNotEmpty) {
      buf.writeln('Weaknesses to address:');
      for (final w in followup.weaknesses) {
        buf.writeln(
          '  - [${w.id} | ${w.severity} | ${w.area}] ${w.description}',
        );
      }
    }
    if (followup.perAgentTasks.isNotEmpty) {
      buf.writeln('Per-agent tasks:');
      followup.perAgentTasks.forEach((agentId, tasks) {
        buf.writeln('  $agentId:');
        for (final t in tasks) {
          buf.writeln('    - $t');
        }
      });
    }
    if (followup.rebriefAddendum.trim().isNotEmpty) {
      buf
        ..writeln('Reviewer directive:')
        ..writeln(followup.rebriefAddendum.trim());
    }
    buf.writeln(
      'Do NOT defend round one. Re-dispatch the affected agents with weakness IDs cited.',
    );
    return buf.toString();
  }

  /// Returns a CTF-attitude doctrine block when the brief is shaped like
  /// a testing, security, pentest, audit, or capture-the-flag mission;
  /// empty string otherwise. Both the orchestrator and the role agents
  /// inject this so they treat the council as a red-team unit rather
  /// than a pure design discussion.
  ///
  /// Detection is intentionally generous (covers casual phrasings like
  /// "sectest" and "pen test" alongside formal ones like "threat model"
  /// and "OWASP"). False positives here are cheap — the doctrine is
  /// only attitudinal, it does not change protocol shape.
  static String _ctfDoctrineFor(String brief) {
    final b = brief.toLowerCase();
    const triggers = <String>[
      'test',
      'tests',
      'sectest',
      'security test',
      'pentest',
      'pen test',
      'penetration',
      'pentesting',
      'ctf',
      'capture the flag',
      'exploit',
      'vulnerability',
      'vulnerabilit',
      'vuln',
      'fuzz',
      'fuzzing',
      'audit',
      'hardening',
      'harden',
      'threat model',
      'red team',
      'attack surface',
      'owasp',
    ];
    if (!triggers.any(b.contains)) return '';
    return '''

=== CTF attitude (active because this brief is testing / security / CTF flavored) ===
- Treat this like a Capture-The-Flag mission. Every finding is a flag, and every flag needs proof, not "potential issue" hand-waving.
- Think like an attacker, not a defender. Default question is "how do I break this?" before "how do I document it?".
- Map the attack surface first: every entry point, every trust boundary, every assumption. Enumerate before you exploit.
- Chain weaknesses. A small input quirk + a permissive parser + an over-broad permission is a finding; each in isolation is noise.
- For each candidate flag, produce: target (file/symbol/endpoint), input/payload, expected behavior, observed behavior, severity (blocker/major/minor), reproduction path, and one suggested mitigation.
- Bias hard for repro: a working PoC, a failing test, or a script the next person can run. Prose without a repro is weak evidence.
- Prioritise by exploit likelihood x blast radius, not by aesthetics or feature parity.
- Assume no permission boundary, validation, or auth check holds until you have either broken it or formally proved it. Write the test that proves it either way.
- When the brief says "tests" or "testing": include real adversarial tests (negative inputs, boundary conditions, race conditions, fuzz seeds, malformed payloads), not just happy-path coverage.
- When the brief says "security": prefer one fully-chained, repro-able exploit over five vague "could be vulnerable" notes.
=== End CTF block ===
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
