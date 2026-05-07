// Regression tests for the Council dispatch guard.
//
// Pre-fix behaviour: the controller could call _finishWithReport after the
// orchestrator produced a plan with zero dispatches. There was no central
// state to assert against, so the only way to catch the regression was an
// end-to-end run with two network providers.
//
// These tests pin the invariant at the data layer:
//   1. A ledger with no recorded dispatches MUST refuse a report.
//   2. A ledger where every dispatch failed MUST refuse a report.
//   3. A ledger with one done task MUST allow the report.
//   4. State transitions outside the allowed set MUST throw.
//   5. Retry cap MUST be enforced.
//
// Run: `flutter test test/council/council_task_ledger_test.dart`
import 'package:flutter_test/flutter_test.dart';
import 'package:duckoff/services/council/council_task_ledger.dart';

void main() {
  group('CouncilTaskLedger.refusalReasonForReport', () {
    test('phantom plan: refuses when no dispatch was ever recorded', () {
      final ledger = CouncilTaskLedger();
      // This is the exact failure mode the user hit: orchestrator ran,
      // no dispatch tool calls, runner returned, controller wanted to ship.
      expect(ledger.anyDispatchAttempted, isFalse);
      expect(ledger.hasSuccessfulTask, isFalse);
      final reason = ledger.refusalReasonForReport();
      expect(reason, isNotNull);
      expect(reason, contains('never invoked council_dispatch'));
    });

    test('all-fail run: refuses when dispatches happened but none reached done',
        () {
      final ledger = CouncilTaskLedger();
      final id = ledger.recordDispatch(
        agentId: 'a1',
        agentName: 'Forge',
        task: 'do the thing',
      );
      ledger.transition(id, CouncilTaskState.running);
      ledger.transition(id, CouncilTaskState.failed,
          lastError: 'model unavailable', incrementErrorCount: true);
      final reason = ledger.refusalReasonForReport();
      expect(reason, isNotNull);
      expect(reason, contains('zero reached done'));
      expect(ledger.failureCount, 1);
    });

    test('happy path: allows report when at least one task is done', () {
      final ledger = CouncilTaskLedger();
      final id = ledger.recordDispatch(
        agentId: 'a1',
        agentName: 'Forge',
        task: 'do the thing',
      );
      ledger.transition(id, CouncilTaskState.running);
      ledger.transition(id, CouncilTaskState.done);
      expect(ledger.refusalReasonForReport(), isNull);
      expect(ledger.successCount, 1);
    });

    test('race: refuses while a task is still in flight', () {
      final ledger = CouncilTaskLedger();
      final a = ledger.recordDispatch(
          agentId: 'a1', agentName: 'A', task: 't1');
      final b = ledger.recordDispatch(
          agentId: 'a2', agentName: 'B', task: 't2');
      ledger.transition(a, CouncilTaskState.running);
      ledger.transition(a, CouncilTaskState.done);
      ledger.transition(b, CouncilTaskState.running);
      // b is still running. Even though a is done, the report must wait.
      final reason = ledger.refusalReasonForReport();
      expect(reason, isNotNull);
      expect(reason, contains('still in flight'));
    });
  });

  group('CouncilTaskLedger transitions', () {
    test('illegal transition throws LedgerTransitionError', () {
      final ledger = CouncilTaskLedger();
      final id =
          ledger.recordDispatch(agentId: 'a', agentName: 'A', task: 't');
      ledger.transition(id, CouncilTaskState.running);
      ledger.transition(id, CouncilTaskState.done);
      // done is terminal — cannot regress.
      expect(
        () => ledger.transition(id, CouncilTaskState.running),
        throwsA(isA<LedgerTransitionError>()),
      );
    });

    test('retry cap is enforced', () {
      final ledger = CouncilTaskLedger();
      final id =
          ledger.recordDispatch(agentId: 'a', agentName: 'A', task: 't');
      // attempt 1
      ledger.transition(id, CouncilTaskState.running);
      ledger.transition(id, CouncilTaskState.failed,
          lastError: 'boom', incrementErrorCount: true);
      // attempt 2 (the only allowed retry under default maxAttempts=2)
      ledger.transition(id, CouncilTaskState.dispatched);
      ledger.transition(id, CouncilTaskState.running);
      ledger.transition(id, CouncilTaskState.failed,
          lastError: 'boom2', incrementErrorCount: true);
      // attempt 3 must be blocked.
      expect(
        () => ledger.transition(id, CouncilTaskState.dispatched),
        throwsA(isA<LedgerTransitionError>()),
      );
    });

    test('onTransition fires for every state change with full payload', () {
      final captured = <Map<String, dynamic>>[];
      final ledger = CouncilTaskLedger(
        onTransition: (t) => captured.add(t.toJson()),
      );
      final id = ledger.recordDispatch(
        agentId: 'a',
        agentName: 'A',
        task: 't',
        nextIntendedAction: 'spawn runner',
      );
      ledger.transition(id, CouncilTaskState.running, waitingOn: 'model');
      ledger.transition(id, CouncilTaskState.done);
      // recordDispatch fires twice (planned, then dispatched), then running, done = 4 events.
      expect(captured.length, 4);
      // Schema: every event payload must carry these keys for Signal.
      for (final e in captured) {
        expect(e.containsKey('taskId'), isTrue);
        expect(e.containsKey('agentId'), isTrue);
        expect(e.containsKey('state'), isTrue);
        expect(e.containsKey('errorCount'), isTrue);
        expect(e.containsKey('attempts'), isTrue);
      }
      expect(captured.last['state'], 'done');
      expect(captured.last['waitingOn'], isNull); // cleared on terminal
    });
  });

  group('CouncilTaskLedger bookkeeping', () {
    test('errorCountByAgent aggregates across tasks for same agent', () {
      final ledger = CouncilTaskLedger();
      final t1 =
          ledger.recordDispatch(agentId: 'a', agentName: 'A', task: 't1');
      final t2 =
          ledger.recordDispatch(agentId: 'a', agentName: 'A', task: 't2');
      ledger.transition(t1, CouncilTaskState.running);
      ledger.transition(t1, CouncilTaskState.failed,
          lastError: 'x', incrementErrorCount: true);
      ledger.transition(t2, CouncilTaskState.running);
      ledger.transition(t2, CouncilTaskState.failed,
          lastError: 'y', incrementErrorCount: true);
      expect(ledger.errorCountByAgent['a'], 2);
    });

    test('cancelAll moves every non-terminal task to cancelled', () {
      final ledger = CouncilTaskLedger();
      final t1 =
          ledger.recordDispatch(agentId: 'a', agentName: 'A', task: 't1');
      final t2 =
          ledger.recordDispatch(agentId: 'b', agentName: 'B', task: 't2');
      ledger.transition(t2, CouncilTaskState.running);
      ledger.transition(t2, CouncilTaskState.done);
      ledger.cancelAll(reason: 'aborted');
      expect(ledger.findById(t1)!.state, CouncilTaskState.cancelled);
      // t2 was already done — must not regress.
      expect(ledger.findById(t2)!.state, CouncilTaskState.done);
    });
  });
}
