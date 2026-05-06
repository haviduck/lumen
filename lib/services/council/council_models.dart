import '../../l10n/strings.dart';

enum CouncilStatus {
  idle,
  dispatching,
  working,
  awaitingUser,
  awaitingPool,
  synthesizing,
  done,
  aborted,
  error,
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
    return CouncilAgent(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      role:
          _enumByName(RolePreset.values, json['role'] as String?) ??
          RolePreset.custom,
      customRole: json['customRole'] as String? ?? '',
      model: json['model'] as String? ?? '',
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

class CouncilConfig {
  final String id;
  final String title;
  final String brief;
  final CouncilAgent orchestrator;
  final List<CouncilAgent> agents;
  final CouncilAgent finalEvaluator;
  final DateTime createdAt;

  CouncilConfig({
    required this.id,
    required this.title,
    required this.brief,
    required this.orchestrator,
    required List<CouncilAgent> agents,
    CouncilAgent? finalEvaluator,
    DateTime? createdAt,
  }) : agents = List.unmodifiable(agents),
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

class CouncilSession {
  final CouncilConfig config;
  CouncilStatus status;
  final DateTime startedAt;
  DateTime? finishedAt;
  String reportMarkdown;
  String reportPath;
  final List<CouncilEvent> events;
  final List<CouncilQuestion> poolQuestions;
  CouncilQuestion? pendingUserQuestion;

  CouncilSession({
    required this.config,
    this.status = CouncilStatus.idle,
    DateTime? startedAt,
    this.finishedAt,
    this.reportMarkdown = '',
    this.reportPath = '',
    List<CouncilEvent>? events,
    List<CouncilQuestion>? poolQuestions,
    this.pendingUserQuestion,
  }) : startedAt = startedAt ?? DateTime.now(),
       events = List<CouncilEvent>.from(events ?? const []),
       poolQuestions = List<CouncilQuestion>.from(poolQuestions ?? const []);

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
    'status': status.name,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'reportMarkdown': reportMarkdown,
    'reportPath': reportPath,
    'events': events.map((e) => e.toJson()).toList(),
    'poolQuestions': poolQuestions.map((q) => q.toJson()).toList(),
    'pendingUserQuestion': pendingUserQuestion?.toJson(),
  };

  static CouncilSession fromJson(Map<String, dynamic> json) {
    return CouncilSession(
      config: CouncilConfig.fromJson(
        (json['config'] as Map?)?.cast<String, dynamic>() ??
            const <String, dynamic>{},
      ),
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
    );
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
