/// Council Task Ledger
/// ====================
/// Pure state-machine + bookkeeping for every agent task the orchestrator
/// dispatches in a council run. This module is *Flutter-free on purpose*
/// so it can be unit-tested without spinning a binding, and so the same
/// invariants can be replayed against a persisted session on reload.
///
/// Why this exists
/// ---------------
/// Last regression: orchestrator produced a plan (prose) but never invoked
/// `council_dispatch`, the runner returned, `_finishWithReport` ran, and a
/// phantom report shipped with zero agents having executed. The user's #1
/// complaint: "planned but nothing happened". The ledger makes that
/// failure mode *impossible to silently recur* — every dispatch is recorded,
/// every transition is observable, and the report tool refuses to fire if
/// no task ever reached `done`.
///
/// Event schema (Signal — bind to this, do not guess)
/// --------------------------------------------------
/// Emitted on `CouncilController.events` with type
/// `CouncilEventType.taskStateChanged`. Event `data` payload:
/// ```
/// {
///   "taskId":               String,        // stable id, persists across reloads
///   "agentId":              String,        // CouncilAgent.id this task is bound to
///   "agentName":            String,        // human label for UI
///   "state":                String,        // CouncilTaskState.name
///   "previousState":        String?,       // null on first transition
///   "errorCount":           int,           // total failures observed for this task
///   "lastError":            String?,       // most recent error message, or null
///   "waitingOn":            String?,       // human reason ("pool", "user", "model", "tool:edit", null)
///   "nextIntendedAction":   String?,       // what the controller will do next, if any
///   "task":                 String,        // the dispatched task brief
///   "createdAt":            String,        // ISO-8601
///   "updatedAt":            String,        // ISO-8601
///   "attempts":             int,           // 1-based; >1 means a retry happened
///   "maxAttempts":          int            // ledger-enforced cap (default 2)
/// }
/// ```
/// Signal renders per-agent panels by grouping the latest event per
/// (agentId, taskId). For an agent with N tasks across a run, show the
/// latest task plus a small badge with `errorCount` summed across all
/// tasks for that agent. `waitingOn` powers the "waiting on X" hint;
/// `nextIntendedAction` powers the "next action Y" hint.
library;

import 'dart:async';

/// Explicit state machine. Every task starts as `planned` and ends in
/// exactly one terminal state (`done`, `failed`, `timeout`, `cancelled`).
enum CouncilTaskState {
  planned,
  dispatched,
  running,
  done,
  failed,
  timeout,
  cancelled,
}

const Set<CouncilTaskState> kTerminalTaskStates = {
  CouncilTaskState.done,
  CouncilTaskState.failed,
  CouncilTaskState.timeout,
  CouncilTaskState.cancelled,
};

/// Allowed transitions. The ledger refuses anything not in this map so
/// callers can't silently regress a task from `done` back to `running`.
const Map<CouncilTaskState, Set<CouncilTaskState>> kAllowedTransitions = {
  CouncilTaskState.planned: {
    CouncilTaskState.dispatched,
    CouncilTaskState.cancelled,
  },
  CouncilTaskState.dispatched: {
    CouncilTaskState.running,
    CouncilTaskState.failed,
    CouncilTaskState.timeout,
    CouncilTaskState.cancelled,
  },
  CouncilTaskState.running: {
    CouncilTaskState.done,
    CouncilTaskState.failed,
    CouncilTaskState.timeout,
    CouncilTaskState.cancelled,
  },
  // Retry path: a failed task can be re-dispatched once (within attempt cap).
  CouncilTaskState.failed: {CouncilTaskState.dispatched},
  CouncilTaskState.timeout: {CouncilTaskState.dispatched},
  CouncilTaskState.done: <CouncilTaskState>{},
  CouncilTaskState.cancelled: <CouncilTaskState>{},
};

class CouncilTask {
  final String id;
  final String agentId;
  final String agentName;
  final String task;
  final DateTime createdAt;
  DateTime updatedAt;
  CouncilTaskState state;
  CouncilTaskState? previousState;
  int errorCount;
  String? lastError;
  String? waitingOn;
  String? nextIntendedAction;
  int attempts;
  final int maxAttempts;

  CouncilTask({
    required this.id,
    required this.agentId,
    required this.agentName,
    required this.task,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.state = CouncilTaskState.planned,
    this.previousState,
    this.errorCount = 0,
    this.lastError,
    this.waitingOn,
    this.nextIntendedAction,
    this.attempts = 0,
    this.maxAttempts = 2,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  bool get isTerminal => kTerminalTaskStates.contains(state);

  Map<String, dynamic> toJson() => {
        'taskId': id,
        'agentId': agentId,
        'agentName': agentName,
        'task': task,
        'state': state.name,
        'previousState': previousState?.name,
        'errorCount': errorCount,
        'lastError': lastError,
        'waitingOn': waitingOn,
        'nextIntendedAction': nextIntendedAction,
        'attempts': attempts,
        'maxAttempts': maxAttempts,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static CouncilTask fromJson(Map<String, dynamic> json) {
    CouncilTaskState parseState(String? n, CouncilTaskState fallback) {
      for (final s in CouncilTaskState.values) {
        if (s.name == n) return s;
      }
      return fallback;
    }

    return CouncilTask(
      id: json['taskId'] as String? ?? '',
      agentId: json['agentId'] as String? ?? '',
      agentName: json['agentName'] as String? ?? '',
      task: json['task'] as String? ?? '',
      state: parseState(json['state'] as String?, CouncilTaskState.planned),
      previousState: json['previousState'] is String
          ? parseState(json['previousState'] as String, CouncilTaskState.planned)
          : null,
      errorCount: (json['errorCount'] as num?)?.toInt() ?? 0,
      lastError: json['lastError'] as String?,
      waitingOn: json['waitingOn'] as String?,
      nextIntendedAction: json['nextIntendedAction'] as String?,
      attempts: (json['attempts'] as num?)?.toInt() ?? 0,
      maxAttempts: (json['maxAttempts'] as num?)?.toInt() ?? 2,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? ''),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
    );
  }
}

/// Reason a transition was rejected by the ledger.
class LedgerTransitionError implements Exception {
  final String taskId;
  final CouncilTaskState from;
  final CouncilTaskState to;
  final String reason;
  const LedgerTransitionError({
    required this.taskId,
    required this.from,
    required this.to,
    required this.reason,
  });

  @override
  String toString() =>
      'LedgerTransitionError($taskId: ${from.name} -> ${to.name}: $reason)';
}

/// Central reducer. The controller owns one of these per session. The
/// ledger fires a callback on every state change so the controller can
/// translate it into a `CouncilEvent` of type `taskStateChanged`.
class CouncilTaskLedger {
  CouncilTaskLedger({
    List<CouncilTask>? initialTasks,
    void Function(CouncilTask task)? onTransition,
  })  : _tasks = List<CouncilTask>.from(initialTasks ?? const []),
        _onTransition = onTransition;

  final List<CouncilTask> _tasks;
  final void Function(CouncilTask task)? _onTransition;
  int _seq = 0;

  List<CouncilTask> get tasks => List.unmodifiable(_tasks);

  /// True iff at least one task reached `done`. The report-guard hinges
  /// on this. If false at finish-time, the orchestrator has produced a
  /// phantom plan and the council MUST refuse to ship a report.
  bool get hasSuccessfulTask =>
      _tasks.any((t) => t.state == CouncilTaskState.done);

  /// True iff at least one dispatch was attempted. Distinguishes
  /// "orchestrator hung up before producing anything" from
  /// "orchestrator dispatched but every agent failed".
  bool get anyDispatchAttempted => _tasks.isNotEmpty;

  int get successCount =>
      _tasks.where((t) => t.state == CouncilTaskState.done).length;
  int get failureCount => _tasks
      .where((t) =>
          t.state == CouncilTaskState.failed ||
          t.state == CouncilTaskState.timeout)
      .length;
  int get pendingCount => _tasks.where((t) => !t.isTerminal).length;

  /// Per-agent error totals. Used by Signal for the "this agent had N
  /// errors" badge across the run, not just the latest task.
  Map<String, int> get errorCountByAgent {
    final out = <String, int>{};
    for (final t in _tasks) {
      if (t.errorCount > 0) {
        out[t.agentId] = (out[t.agentId] ?? 0) + t.errorCount;
      }
    }
    return out;
  }

  CouncilTask? findById(String taskId) {
    for (final t in _tasks) {
      if (t.id == taskId) return t;
    }
    return null;
  }

  CouncilTask? latestForAgent(String agentId) {
    CouncilTask? latest;
    for (final t in _tasks) {
      if (t.agentId != agentId) continue;
      if (latest == null || t.updatedAt.isAfter(latest.updatedAt)) {
        latest = t;
      }
    }
    return latest;
  }

  /// Records a brand-new dispatch. Returns the task id.
  String recordDispatch({
    required String agentId,
    required String agentName,
    required String task,
    String runId = '',
    String? nextIntendedAction,
  }) {
    final id = 't_${runId}_${++_seq}_${DateTime.now().millisecondsSinceEpoch}';
    final t = CouncilTask(
      id: id,
      agentId: agentId,
      agentName: agentName,
      task: task,
      state: CouncilTaskState.planned,
      attempts: 1,
      nextIntendedAction: nextIntendedAction,
    );
    _tasks.add(t);
    _emit(t);
    transition(id, CouncilTaskState.dispatched,
        waitingOn: 'dispatch-slot',
        nextIntendedAction: 'invoke agent runner');
    return id;
  }

  /// Apply a transition. Throws [LedgerTransitionError] if illegal.
  void transition(
    String taskId,
    CouncilTaskState next, {
    String? lastError,
    String? waitingOn,
    String? nextIntendedAction,
    bool incrementErrorCount = false,
  }) {
    final t = findById(taskId);
    if (t == null) {
      throw LedgerTransitionError(
        taskId: taskId,
        from: CouncilTaskState.planned,
        to: next,
        reason: 'unknown task id',
      );
    }
    final allowed = kAllowedTransitions[t.state] ?? const {};
    if (!allowed.contains(next)) {
      throw LedgerTransitionError(
        taskId: taskId,
        from: t.state,
        to: next,
        reason: 'illegal transition',
      );
    }
    // Retry path: re-dispatching a previously failed task increments attempts
    // and is capped by maxAttempts. Caller MUST call retry() instead of
    // raw transition() to express intent — but if they don't, we still cap.
    if ((t.state == CouncilTaskState.failed ||
            t.state == CouncilTaskState.timeout) &&
        next == CouncilTaskState.dispatched) {
      if (t.attempts >= t.maxAttempts) {
        throw LedgerTransitionError(
          taskId: taskId,
          from: t.state,
          to: next,
          reason: 'retry cap exceeded (${t.attempts}/${t.maxAttempts})',
        );
      }
      t.attempts += 1;
    }
    t
      ..previousState = t.state
      ..state = next
      ..updatedAt = DateTime.now();
    if (lastError != null) t.lastError = lastError;
    if (waitingOn != null) t.waitingOn = waitingOn.isEmpty ? null : waitingOn;
    if (nextIntendedAction != null) {
      t.nextIntendedAction =
          nextIntendedAction.isEmpty ? null : nextIntendedAction;
    }
    if (incrementErrorCount) t.errorCount += 1;
    if (kTerminalTaskStates.contains(next)) {
      // Terminal states clear "waiting on" — there is nothing to wait for.
      t.waitingOn = null;
      if (next == CouncilTaskState.done) t.nextIntendedAction = null;
    }
    _emit(t);
  }

  /// Cancel every non-terminal task. Used on abort.
  void cancelAll({String reason = 'aborted'}) {
    for (final t in _tasks) {
      if (t.isTerminal) continue;
      t
        ..previousState = t.state
        ..state = CouncilTaskState.cancelled
        ..lastError = reason
        ..waitingOn = null
        ..nextIntendedAction = null
        ..updatedAt = DateTime.now();
      _emit(t);
    }
  }

  /// THE GUARD. Call this immediately before shipping a final report.
  /// Returns null if the report is allowed; otherwise returns a
  /// human-readable refusal reason that MUST be surfaced loudly to the UI.
  ///
  /// Refusal cases (in priority order):
  /// 1. Orchestrator produced no dispatches at all → phantom plan.
  /// 2. Dispatches exist but none reached `done` → all-fail run; user
  ///    must explicitly decide ship-partial / abort, not silent ship.
  /// 3. Pending tasks still in flight → race; await first.
  String? refusalReasonForReport() {
    if (!anyDispatchAttempted) {
      return 'Refusing to ship report: orchestrator produced a plan but '
          'never invoked council_dispatch. Zero agents executed. '
          'Re-run dispatch or abort explicitly.';
    }
    if (!hasSuccessfulTask) {
      return 'Refusing to ship report: $failureCount dispatch(es) failed '
          'and zero reached done. Surface the failures to the user; '
          'do not paper over them with a synthesised report.';
    }
    if (pendingCount > 0) {
      return 'Refusing to ship report: $pendingCount task(s) still in '
          'flight. Await completion or cancel before reporting.';
    }
    return null;
  }

  void _emit(CouncilTask t) {
    final cb = _onTransition;
    if (cb != null) cb(t);
  }
}

/// Convenience helper for callers that want to apply a timeout to an
/// in-flight task and have the ledger automatically transition it.
///
/// Pattern:
/// ```
/// await ledger.runWithTimeout(
///   taskId,
///   timeout: const Duration(minutes: 5),
///   work: () => _runAgent(agent, task),
/// );
/// ```
extension CouncilTaskLedgerTimeout on CouncilTaskLedger {
  Future<void> runWithTimeout(
    String taskId, {
    required Duration timeout,
    required Future<void> Function() work,
  }) async {
    try {
      await work().timeout(timeout);
    } on TimeoutException catch (e) {
      transition(
        taskId,
        CouncilTaskState.timeout,
        lastError: 'task exceeded ${timeout.inSeconds}s budget: $e',
        incrementErrorCount: true,
      );
      rethrow;
    }
  }
}
