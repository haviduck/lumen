// Lock-in tests for the Adversarial Critic models (Excellence Doctrine
// Phase B).
//
// The Critic's findings live on `session.critique` and are persisted
// across IDE restarts via `CouncilPersistenceService`. If the JSON
// round-trip silently drops `resolved`, `severity`, or the attacks
// list, the gate logic will incorrectly let a session ship while
// blocker findings are still open. These tests pin that.
//
// Run: `flutter test test/council/council_critique_test.dart`
import 'package:flutter_test/flutter_test.dart';
import 'package:duckoff/services/council/council_models.dart';

void main() {
  group('CouncilCriticAttack', () {
    test('severity flags are case-insensitive', () {
      final blocker = CouncilCriticAttack(
        id: 'C-001',
        target: 't',
        attack: 'a',
        severity: 'BLOCKER',
      );
      expect(blocker.isBlocker, isTrue);
      expect(blocker.isMajor, isFalse);

      final major = CouncilCriticAttack(
        id: 'C-002',
        target: 't',
        attack: 'a',
        severity: 'Major',
      );
      expect(major.isMajor, isTrue);
      expect(major.isBlocker, isFalse);
    });

    test('JSON round-trip preserves every field including resolved', () {
      final original = CouncilCriticAttack(
        id: 'C-007',
        target: 'lib/foo/bar.dart claim about caching',
        attack: 'Cache invalidation never fires on session refresh.',
        severity: 'blocker',
        acceptance: 'Show a passing test that proves invalidation runs.',
        resolved: true,
      );
      final round = CouncilCriticAttack.fromJson(original.toJson());
      expect(round.id, 'C-007');
      expect(round.target, original.target);
      expect(round.attack, original.attack);
      expect(round.severity, 'blocker');
      expect(round.acceptance, original.acceptance);
      expect(round.resolved, isTrue);
    });
  });

  group('CouncilCritique', () {
    test('allBlockingResolved is false when any blocker is open', () {
      final c = CouncilCritique(
        summary: 's',
        attacks: [
          CouncilCriticAttack(
            id: 'C-1',
            target: 't',
            attack: 'a',
            severity: 'blocker',
          ),
          CouncilCriticAttack(
            id: 'C-2',
            target: 't',
            attack: 'a',
            severity: 'major',
            resolved: true,
          ),
          CouncilCriticAttack(
            id: 'C-3',
            target: 't',
            attack: 'a',
            severity: 'minor',
          ),
        ],
      );
      expect(c.blockerCount, 1);
      expect(c.majorCount, 1);
      expect(c.allBlockingResolved, isFalse);
    });

    test('allBlockingResolved ignores unresolved minors', () {
      final c = CouncilCritique(
        summary: 's',
        attacks: [
          CouncilCriticAttack(
            id: 'C-1',
            target: 't',
            attack: 'a',
            severity: 'blocker',
            resolved: true,
          ),
          CouncilCriticAttack(
            id: 'C-2',
            target: 't',
            attack: 'a',
            severity: 'major',
            resolved: true,
          ),
          CouncilCriticAttack(
            id: 'C-3',
            target: 't',
            attack: 'a',
            severity: 'minor',
          ),
        ],
      );
      expect(c.allBlockingResolved, isTrue);
    });

    test('JSON round-trip preserves attacks + acknowledged + summary', () {
      final c = CouncilCritique(
        summary: 'Council shipped too fast.',
        acknowledged: true,
        attacks: [
          CouncilCriticAttack(
            id: 'C-1',
            target: 'phase history',
            attack: 'Only 2 phases declared on a 4-deliverable brief.',
            severity: 'blocker',
            acceptance: 'Declare and execute build + review phases.',
          ),
        ],
      );
      final round = CouncilCritique.fromJson(c.toJson());
      expect(round.summary, 'Council shipped too fast.');
      expect(round.acknowledged, isTrue);
      expect(round.attacks, hasLength(1));
      expect(round.attacks.single.id, 'C-1');
      expect(round.attacks.single.severity, 'blocker');
      expect(round.attacks.single.isBlocker, isTrue);
    });
  });

  group('CouncilQualityGate', () {
    test('allPassed only when every gate is true', () {
      final gate = CouncilQualityGate()
        ..artifactsProduced = true
        ..adversarialReviewDone = true
        ..claimsGrounded = true
        ..userAsksResolved = true
        ..risksNamed = true
        ..enoughPhasesCovered = true;
      expect(gate.allPassed, isTrue);
      expect(gate.failingGates, isEmpty);

      gate.risksNamed = false;
      expect(gate.allPassed, isFalse);
      expect(gate.failingGates, contains('risks_named'));
    });
  });

  group('CouncilSession (phase + critique persistence)', () {
    test('phase + critique survive JSON round-trip', () {
      final session = CouncilSession(
        config: CouncilConfig(
          id: 'cfg-1',
          title: 't',
          brief: 'b',
          orchestrator: CouncilAgent(
            id: 'orch',
            name: 'Orch',
            role: RolePreset.architect,
            model: 'm',
          ),
          agents: const [],
          finalEvaluator: CouncilAgent(
            id: 'eval',
            name: 'Eval',
            role: RolePreset.reviewer,
            model: 'm',
          ),
        ),
      )
        ..currentPhase = CouncilPhase.review
        ..phaseHistory.addAll([
          CouncilPhaseEntry(
            phase: CouncilPhase.discovery,
            rationale: 'kickoff',
          ),
          CouncilPhaseEntry(
            phase: CouncilPhase.build,
            rationale: 'main impl',
          ),
        ])
        ..critique = CouncilCritique(
          summary: 'verdict',
          attacks: [
            CouncilCriticAttack(
              id: 'C-x',
              target: 't',
              attack: 'a',
              severity: 'major',
            ),
          ],
        );
      session.qualityGate
        ..artifactsProduced = true
        ..attempts = 2;

      final json = session.toJson();
      final round = CouncilSession.fromJson(json);

      expect(round.currentPhase, CouncilPhase.review);
      expect(round.phaseHistory, hasLength(2));
      expect(round.phaseHistory.first.phase, CouncilPhase.discovery);
      expect(round.critique, isNotNull);
      expect(round.critique!.attacks, hasLength(1));
      expect(round.critique!.attacks.single.severity, 'major');
      expect(round.qualityGate.artifactsProduced, isTrue);
      expect(round.qualityGate.attempts, 2);
    });
  });
}
