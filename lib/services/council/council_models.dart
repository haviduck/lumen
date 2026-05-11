import '../../l10n/strings.dart';
import 'council_protocol.dart';
import 'council_task_ledger.dart';

enum CouncilStatus {
  idle,
  dispatching,
  working,
  awaitingUser,
  awaitingPool,
  synthesizing,
  awaitingFollowup,
  done,
  aborted,
  error,
}

/// Canonical names for every event the Council emits on its lifecycle bus.
/// Stagecraft (visual layer) and persistence subscribe to these. Adding new
/// event types here is the only sanctioned way to introduce new visual
/// signals — never invent a string at the call-site.
class CouncilEventType {
  CouncilEventType._();

  // Session
  static const sessionStarted = 'session_started';
  static const aborted = 'aborted';
  static const councilRoundCompleted = 'council_round_completed';
  static const awaitingUserFollowup = 'awaiting_user_followup';
  static const councilClosed = 'council_closed';
  static const roundTwoStarted = 'round_two_started';

  // Agent lifecycle
  static const agentArrived = 'agent_arrived';
  static const agentThinkingStarted = 'agent_thinking_started';
  static const agentThinkingEnded = 'agent_thinking_ended';
  static const agentDone = 'agent_done';
  static const agentError = 'agent_error';

  // Stall detection — fired when an agent runner's stream has been
  // silent beyond the configured threshold. The auto-nudge system
  // injects a continuation prompt; this event surfaces the stall in the
  // UI so the user can also manually ping the agent.
  static const agentStalled = 'agent_stalled';

  // Task ledger (see council_task_ledger.dart for schema). Emitted on
  // every state-machine transition: planned -> dispatched -> running ->
  // done|failed|timeout|cancelled. Signal subscribes to render per-agent
  // status, error counts, "waiting on X", and "next action Y".
  static const taskStateChanged = 'task_state_changed';
  // Loud, never-swallowed failure marker raised when the orchestrator
  // produced a plan but no agents executed (or every dispatch failed and
  // it tried to ship a report anyway). The UI MUST render this.
  static const dispatchGuardTripped = 'dispatch_guard_tripped';

  // Communication
  static const messageSent = 'message_sent';
  static const linkStarted = 'link_started';
  static const linkEnded = 'link_ended';
  static const reviewerFollowup = 'reviewer_followup';

  // Legacy (kept for blackboard / traffic widgets that already filter on them)
  static const dispatched = 'dispatched';
  static const agentStarted = 'agent_started';
  static const askedPool = 'asked_pool';
  static const poolReply = 'pool_reply';
  static const askedUser = 'asked_user';
  static const userReply = 'user_reply';
  static const userPingedOrchestrator = 'user_pinged_orchestrator';
  static const userPingedAgent = 'user_pinged_agent';
  static const reported = 'reported';
  static const evaluatorStarted = 'evaluator_started';
  static const evaluatorDone = 'evaluator_done';
  static const agentChunk = 'agent_chunk';

  // Pentest / security-theater visual events
  /// Emitted once when pentest mode detects the goal target from the brief
  /// or orchestrator's first dispatch. Data: { 'goal': '<description>' }.
  static const pentestGoalIdentified = 'pentest_goal_identified';
  /// Emitted when an agent reports a finding that constitutes an "attack"
  /// on the goal. Data: { 'finding': '<summary>', 'severity': 'critical|major|minor' }.
  static const pentestAttackLanded = 'pentest_attack_landed';
  /// Emitted when agents enter the planning / conspiring phase before
  /// dispatching attack waves. Agents visually huddle.
  static const pentestConspiring = 'pentest_conspiring';
}

/// Kind of a `message_sent` event. Drives speech-bubble styling.
class CouncilMessageKind {
  CouncilMessageKind._();
  static const dispatch = 'dispatch';
  static const reply = 'reply';
  static const askPool = 'ask_pool';
  static const poolReply = 'pool_reply';
  static const askUser = 'ask_user';
  static const userReply = 'user_reply';
  static const review = 'review';
  static const followup = 'followup';
}

/// A single weakness raised by the final evaluator. Stable IDs let round-two
/// briefs cite "address W2, W4" instead of paraphrasing prose.
class CouncilWeakness {
  final String id;
  final String severity;
  final String area;
  final String description;

  const CouncilWeakness({
    required this.id,
    required this.severity,
    required this.area,
    required this.description,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'severity': severity,
    'area': area,
    'description': description,
  };

  static CouncilWeakness fromJson(Map<String, dynamic> json) => CouncilWeakness(
    id: json['id'] as String? ?? '',
    severity: json['severity'] as String? ?? 'minor',
    area: json['area'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );
}

/// Structured payload of `reviewer_followup`. Carries everything the
/// orchestrator + briefer need to re-brief a coherent round two without
/// re-parsing prose.
class ReviewerFollowup {
  final int roundIndex;
  final String summary;
  final List<CouncilWeakness> weaknesses;
  final Map<String, List<String>> perAgentTasks;
  final bool suggestedRoundTwo;
  final String rebriefAddendum;

  const ReviewerFollowup({
    required this.roundIndex,
    required this.summary,
    required this.weaknesses,
    required this.perAgentTasks,
    required this.suggestedRoundTwo,
    required this.rebriefAddendum,
  });

  Map<String, dynamic> toJson() => {
    'roundIndex': roundIndex,
    'summary': summary,
    'weaknesses': weaknesses.map((w) => w.toJson()).toList(),
    'perAgentTasks': perAgentTasks,
    'suggestedRoundTwo': suggestedRoundTwo,
    'rebriefAddendum': rebriefAddendum,
  };

  static ReviewerFollowup fromJson(Map<String, dynamic> json) {
    final tasksRaw = (json['perAgentTasks'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{};
    final tasks = <String, List<String>>{};
    tasksRaw.forEach((k, v) {
      if (v is List) {
        tasks[k] = v.whereType<String>().toList();
      }
    });
    return ReviewerFollowup(
      roundIndex: (json['roundIndex'] as num?)?.toInt() ?? 0,
      summary: json['summary'] as String? ?? '',
      weaknesses: ((json['weaknesses'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => CouncilWeakness.fromJson(m.cast<String, dynamic>()))
          .toList(),
      perAgentTasks: tasks,
      suggestedRoundTwo: json['suggestedRoundTwo'] == true,
      rebriefAddendum: json['rebriefAddendum'] as String? ?? '',
    );
  }
}

enum CouncilAgentStatus {
  idle,
  queued,
  working,
  askingPool,
  awaitingUser,
  replying,
  done,
  error,
}

enum RolePreset {
  pentester,
  reviewer,
  researcher,
  architect,
  tester,
  writer,
  custom,
}

class CouncilAgent {
  final String id;
  final String name;
  final RolePreset role;
  final String customRole;
  final String model;
  final Set<String> enabledTools;
  CouncilAgentStatus status;
  String transcript;
  String currentTask;
  String lastError;

  CouncilAgent({
    required this.id,
    required this.name,
    required this.role,
    required this.model,
    this.customRole = '',
    Set<String>? enabledTools,
    this.status = CouncilAgentStatus.idle,
    this.transcript = '',
    this.currentTask = '',
    this.lastError = '',
  }) : enabledTools = Set.unmodifiable(enabledTools ?? const <String>{});

  CouncilAgent copyWith({
    String? id,
    String? name,
    RolePreset? role,
    String? customRole,
    String? model,
    Set<String>? enabledTools,
    CouncilAgentStatus? status,
    String? transcript,
    String? currentTask,
    String? lastError,
  }) {
    return CouncilAgent(
      id: id ?? this.id,
      name: name ?? this.name,
      role: role ?? this.role,
      customRole: customRole ?? this.customRole,
      model: model ?? this.model,
      enabledTools: enabledTools ?? this.enabledTools,
      status: status ?? this.status,
      transcript: transcript ?? this.transcript,
      currentTask: currentTask ?? this.currentTask,
      lastError: lastError ?? this.lastError,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'role': role.name,
    'customRole': customRole,
    'model': model,
    'enabledTools': enabledTools.toList()..sort(),
    'status': status.name,
    'transcript': transcript,
    'currentTask': currentTask,
    'lastError': lastError,
  };

  static CouncilAgent fromJson(Map<String, dynamic> json) {
    var model = json['model'] as String? ?? '';
    // Migration shim: GitHub Models was removed; null out legacy refs.
    if (model.startsWith('github:')) model = '';
    return CouncilAgent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role:
          _enumByName(RolePreset.values, json['role'] as String?) ??
          RolePreset.custom,
      customRole: json['customRole'] as String? ?? '',
      model: model,
      enabledTools: ((json['enabledTools'] as List?) ?? const [])
          .whereType<String>()
          .toSet(),
      status:
          _enumByName(CouncilAgentStatus.values, json['status'] as String?) ??
          CouncilAgentStatus.idle,
      transcript: json['transcript'] as String? ?? '',
      currentTask: json['currentTask'] as String? ?? '',
      lastError: json['lastError'] as String? ?? '',
    );
  }
}

class CouncilBriefDoc {
  final String name;
  final int size;
  final String content;

  const CouncilBriefDoc({
    required this.name,
    required this.size,
    required this.content,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'size': size,
        'content': content,
      };

  static CouncilBriefDoc fromJson(Map<String, dynamic> json) => CouncilBriefDoc(
        name: json['name'] as String? ?? '',
        size: (json['size'] as num?)?.toInt() ?? 0,
        content: json['content'] as String? ?? '',
      );
}

class CouncilConfig {
  final String id;
  final String title;
  final String brief;
  final CouncilAgent orchestrator;
  final List<CouncilAgent> agents;
  final CouncilAgent finalEvaluator;
  final DateTime createdAt;
  /// Base64-encoded JPEG images attached to the brief by the user
  /// (clipboard paste or image-file picker in the Convene modal).
  /// Forwarded to the orchestrator's first user turn as `images` —
  /// vision-capable providers (Anthropic, Gemini, Ollama) decode them
  /// into proper vision blocks; text-only providers silently drop them.
  final List<String> briefImages;
  /// Document attachments (md / txt / code / small PDF text) attached
  /// to the brief. Content is folded into the orchestrator's user
  /// prompt as labeled `<attached-doc>` blocks so every provider sees
  /// them as text regardless of vision support.
  final List<CouncilBriefDoc> briefDocs;

  CouncilConfig({
    required this.id,
    required this.title,
    required this.brief,
    required this.orchestrator,
    required List<CouncilAgent> agents,
    CouncilAgent? finalEvaluator,
    DateTime? createdAt,
    List<String> briefImages = const <String>[],
    List<CouncilBriefDoc> briefDocs = const <CouncilBriefDoc>[],
  })  : agents = List.unmodifiable(agents),
        briefImages = List.unmodifiable(briefImages),
        briefDocs = List.unmodifiable(briefDocs),
        finalEvaluator =
            finalEvaluator ??
            CouncilAgent(
              id: 'final_evaluator',
              name: S.councilFinalEvaluator,
              role: RolePreset.reviewer,
              model: orchestrator.model,
            ),
        createdAt = createdAt ?? DateTime.now();

  List<CouncilAgent> get allAgents => [orchestrator, ...agents, finalEvaluator];

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'brief': brief,
    'orchestrator': orchestrator.toJson(),
    'agents': agents.map((a) => a.toJson()).toList(),
    'finalEvaluator': finalEvaluator.toJson(),
    'createdAt': createdAt.toIso8601String(),
    if (briefImages.isNotEmpty) 'briefImages': briefImages,
    if (briefDocs.isNotEmpty)
      'briefDocs': briefDocs.map((d) => d.toJson()).toList(),
  };

  static CouncilConfig fromJson(Map<String, dynamic> json) {
    return CouncilConfig(
      id: json['id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      brief: json['brief'] as String? ?? '',
      orchestrator: CouncilAgent.fromJson(
        (json['orchestrator'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      agents: ((json['agents'] as List?) ?? const [])
          .whereType<Map>()
          .map((a) => CouncilAgent.fromJson(a.cast<String, dynamic>()))
          .toList(),
      finalEvaluator: json['finalEvaluator'] is Map
          ? CouncilAgent.fromJson(
              (json['finalEvaluator'] as Map).cast<String, dynamic>(),
            )
          : null,
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      briefImages: ((json['briefImages'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
      briefDocs: ((json['briefDocs'] as List?) ?? const [])
          .whereType<Map>()
          .map((m) => CouncilBriefDoc.fromJson(m.cast<String, dynamic>()))
          .toList(),
    );
  }
}

class CouncilQuestion {
  final String id;
  final String fromAgentId;
  final String question;
  final DateTime createdAt;
  final List<CouncilPoolReply> replies;
  String userAnswer;
  bool resolved;

  CouncilQuestion({
    required this.id,
    required this.fromAgentId,
    required this.question,
    DateTime? createdAt,
    List<CouncilPoolReply>? replies,
    this.userAnswer = '',
    this.resolved = false,
  }) : createdAt = createdAt ?? DateTime.now(),
       replies = List<CouncilPoolReply>.from(replies ?? const []);

  Map<String, dynamic> toJson() => {
    'id': id,
    'fromAgentId': fromAgentId,
    'question': question,
    'createdAt': createdAt.toIso8601String(),
    'replies': replies.map((r) => r.toJson()).toList(),
    'userAnswer': userAnswer,
    'resolved': resolved,
  };

  static CouncilQuestion fromJson(Map<String, dynamic> json) {
    return CouncilQuestion(
      id: json['id'] as String? ?? '',
      fromAgentId: json['fromAgentId'] as String? ?? '',
      question: json['question'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      replies: ((json['replies'] as List?) ?? const [])
          .whereType<Map>()
          .map((r) => CouncilPoolReply.fromJson(r.cast<String, dynamic>()))
          .toList(),
      userAnswer: json['userAnswer'] as String? ?? '',
      resolved: json['resolved'] == true,
    );
  }
}

class CouncilPoolReply {
  final String fromAgentId;
  final String answer;
  final DateTime createdAt;

  CouncilPoolReply({
    required this.fromAgentId,
    required this.answer,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'fromAgentId': fromAgentId,
    'answer': answer,
    'createdAt': createdAt.toIso8601String(),
  };

  static CouncilPoolReply fromJson(Map<String, dynamic> json) {
    return CouncilPoolReply(
      fromAgentId: json['fromAgentId'] as String? ?? '',
      answer: json['answer'] as String? ?? '',
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// Severity levels for pentest findings — drive visual urgency.
enum PentestSeverity { critical, major, minor, info }

/// A single finding reported during a pentest/sectest council session.
class PentestFinding {
  final String agentId;
  final String summary;
  final PentestSeverity severity;
  final DateTime timestamp;

  PentestFinding({
    required this.agentId,
    required this.summary,
    this.severity = PentestSeverity.info,
    DateTime? timestamp,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'agentId': agentId,
    'summary': summary,
    'severity': severity.name,
    'timestamp': timestamp.toIso8601String(),
  };

  static PentestFinding fromJson(Map<String, dynamic> json) {
    return PentestFinding(
      agentId: json['agentId'] as String? ?? '',
      summary: json['summary'] as String? ?? '',
      severity: PentestSeverity.values.firstWhere(
        (s) => s.name == json['severity'],
        orElse: () => PentestSeverity.info,
      ),
      timestamp: DateTime.tryParse(json['timestamp'] as String? ?? '') ?? DateTime.now(),
    );
  }
}

class CouncilSession {
  final CouncilConfig config;
  final String runId;
  CouncilStatus status;
  int roundIndex;
  final DateTime startedAt;
  DateTime? finishedAt;
  String reportMarkdown;
  String reportPath;
  ReviewerFollowup? reviewerFollowup;
  final List<CouncilEvent> events;
  final List<CouncilQuestion> poolQuestions;
  CouncilQuestion? pendingUserQuestion;
  // Persisted task ledger snapshot. Rehydrated into a [CouncilTaskLedger]
  // on reload so a crash mid-run can't lose pending dispatches.
  final List<CouncilTask> tasks;

  /// Whether this session is in pentest / security-test mode. Computed from
  /// the brief at construction time. The visual layer uses this to switch
  /// to attack-theater styling (goal panel, attack lines, conspiring FX).
  late final bool isPentestMode = CouncilProtocol.isSecurityBrief(config.brief);

  /// The attack goal/target identified by the orchestrator. Set when a
  /// `pentest_goal_identified` event fires. The visual layer renders a
  /// goal panel with this text.
  String pentestGoal = '';

  /// Pentest findings reported by agents. Each entry is a short summary
  /// used by the visual layer to animate attack-line strikes.
  final List<PentestFinding> pentestFindings = <PentestFinding>[];

  CouncilSession({
    required this.config,
    String? runId,
    this.status = CouncilStatus.idle,
    this.roundIndex = 0,
    DateTime? startedAt,
    this.finishedAt,
    this.reportMarkdown = '',
    this.reportPath = '',
    this.reviewerFollowup,
    List<CouncilEvent>? events,
    List<CouncilQuestion>? poolQuestions,
    this.pendingUserQuestion,
    List<CouncilTask>? tasks,
    this.pentestGoal = '',
  }) : runId = runId ??
            '${config.id}_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
       startedAt = startedAt ?? DateTime.now(),
       events = List<CouncilEvent>.from(events ?? const []),
       poolQuestions = List<CouncilQuestion>.from(poolQuestions ?? const []),
       tasks = List<CouncilTask>.from(tasks ?? const []);

  CouncilAgent? agentById(String id) {
    if (config.orchestrator.id == id) return config.orchestrator;
    if (config.finalEvaluator.id == id) return config.finalEvaluator;
    for (final agent in config.agents) {
      if (agent.id == id) return agent;
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
    'config': config.toJson(),
    'runId': runId,
    'status': status.name,
    'roundIndex': roundIndex,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'reportMarkdown': reportMarkdown,
    'reportPath': reportPath,
    'reviewerFollowup': reviewerFollowup?.toJson(),
    'events': events.map((e) => e.toJson()).toList(),
    'poolQuestions': poolQuestions.map((q) => q.toJson()).toList(),
    'pendingUserQuestion': pendingUserQuestion?.toJson(),
    'tasks': tasks.map((t) => t.toJson()).toList(),
    if (pentestGoal.isNotEmpty) 'pentestGoal': pentestGoal,
    if (pentestFindings.isNotEmpty)
      'pentestFindings': pentestFindings.map((f) => f.toJson()).toList(),
  };

  static CouncilSession fromJson(Map<String, dynamic> json) {
    final session = CouncilSession(
      config: CouncilConfig.fromJson(
        (json['config'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
      runId: json['runId'] as String?,
      roundIndex: (json['roundIndex'] as num?)?.toInt() ?? 0,
      reviewerFollowup: json['reviewerFollowup'] is Map
          ? ReviewerFollowup.fromJson(
              (json['reviewerFollowup'] as Map).cast<String, dynamic>(),
            )
          : null,
      status:
          _enumByName(CouncilStatus.values, json['status'] as String?) ??
          CouncilStatus.idle,
      startedAt:
          DateTime.tryParse(json['startedAt'] as String? ?? '') ??
          DateTime.now(),
      finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
      reportMarkdown: json['reportMarkdown'] as String? ?? '',
      reportPath: json['reportPath'] as String? ?? '',
      events: ((json['events'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => CouncilEvent.fromJson(e.cast<String, dynamic>()))
          .toList(),
      poolQuestions: ((json['poolQuestions'] as List?) ?? const [])
          .whereType<Map>()
          .map((q) => CouncilQuestion.fromJson(q.cast<String, dynamic>()))
          .toList(),
      pendingUserQuestion: json['pendingUserQuestion'] is Map
          ? CouncilQuestion.fromJson(
              (json['pendingUserQuestion'] as Map).cast<String, dynamic>(),
            )
          : null,
      tasks: ((json['tasks'] as List?) ?? const [])
          .whereType<Map>()
          .map((t) => CouncilTask.fromJson(t.cast<String, dynamic>()))
          .toList(),
      pentestGoal: json['pentestGoal'] as String? ?? '',
    );
    final findings = ((json['pentestFindings'] as List?) ?? const [])
        .whereType<Map>()
        .map((f) => PentestFinding.fromJson(f.cast<String, dynamic>()));
    session.pentestFindings.addAll(findings);
    return session;
  }
}

class CouncilEvent {
  final String type;
  final String fromAgentId;
  final String toAgentId;
  final String message;
  final Map<String, dynamic> data;
  final DateTime createdAt;

  CouncilEvent({
    required this.type,
    this.fromAgentId = '',
    this.toAgentId = '',
    this.message = '',
    Map<String, dynamic>? data,
    DateTime? createdAt,
  }) : data = Map.unmodifiable(data ?? const <String, dynamic>{}),
       createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
    'type': type,
    'fromAgentId': fromAgentId,
    'toAgentId': toAgentId,
    'message': message,
    'data': data,
    'createdAt': createdAt.toIso8601String(),
  };

  static CouncilEvent fromJson(Map<String, dynamic> json) {
    return CouncilEvent(
      type: json['type'] as String? ?? '',
      fromAgentId: json['fromAgentId'] as String? ?? '',
      toAgentId: json['toAgentId'] as String? ?? '',
      message: json['message'] as String? ?? '',
      data: (json['data'] as Map?)?.cast<String, dynamic>(),
      createdAt:
          DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

T? _enumByName<T extends Enum>(List<T> values, String? name) {
  if (name == null) return null;
  for (final value in values) {
    if (value.name == name) return value;
  }
  return null;
}
