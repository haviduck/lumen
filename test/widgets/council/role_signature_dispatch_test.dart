// Role-signature dispatch test.
//
// Locks the contract introduced by the 2026-05 visual-identity pass:
// every RolePreset value (plus the orchestrator override) returns a
// non-null CustomPainter, and the returned painter TYPE differs across
// roles. Without this guard, accidentally collapsing the switch to a
// single fallback (e.g. `case _: return CustomRoleSignaturePainter(...)`)
// would silently undo the whole pass — every card would look the same
// again. This test makes that regression loud at the first run.
//
// Two assertions per role:
//   1. The painter is non-null.
//   2. Any two roles' painters are of different runtime types.
//
// The orchestrator override is verified separately — passing
// `isOrchestrator: true` with any RolePreset must yield the
// orchestrator signature, not the role's own painter.
//
// Run: `flutter test test/widgets/council/role_signature_dispatch_test.dart`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duckoff/services/council/council_models.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_architect.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_custom.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_orchestrator.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_pentester.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_researcher.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_reviewer.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_tester.dart';
import 'package:duckoff/widgets/council/role_signatures/role_signature_writer.dart';

void main() {
  CustomPainter make(RolePreset role, {bool isOrchestrator = false}) {
    return buildRoleSignaturePainter(
      role: role,
      active: true,
      idleT: 0.5,
      accent: const Color(0xFF88C0D0),
      isOrchestrator: isOrchestrator,
      currentPhase: CouncilPhase.build,
    );
  }

  test('every role returns a non-null painter', () {
    for (final role in RolePreset.values) {
      final painter = make(role);
      expect(painter, isNotNull, reason: '$role must return a painter');
    }
    final orchestrator = make(RolePreset.custom, isOrchestrator: true);
    expect(
      orchestrator,
      isNotNull,
      reason: 'orchestrator must return a painter',
    );
  });

  test('each role maps to its expected painter type', () {
    // Strict mapping — one painter type per role + orchestrator.
    expect(make(RolePreset.pentester), isA<PentesterRoleSignaturePainter>());
    expect(make(RolePreset.reviewer), isA<ReviewerRoleSignaturePainter>());
    expect(make(RolePreset.researcher), isA<ResearcherRoleSignaturePainter>());
    expect(make(RolePreset.architect), isA<ArchitectRoleSignaturePainter>());
    expect(make(RolePreset.tester), isA<TesterRoleSignaturePainter>());
    expect(make(RolePreset.writer), isA<WriterRoleSignaturePainter>());
    expect(make(RolePreset.custom), isA<CustomRoleSignaturePainter>());
    expect(
      make(RolePreset.custom, isOrchestrator: true),
      isA<OrchestratorRoleSignaturePainter>(),
    );
  });

  test('distinct roles produce distinct painter runtime types', () {
    // The whole point of the visual-identity pass is that no two roles
    // share a painter type. Build the cross-product of role pairs and
    // assert types differ. Catches accidental dispatch collapses
    // (`return CustomRoleSignaturePainter(...)` on every branch) that
    // would compile, return non-null, and silently regress the UI.
    final painters = <RolePreset, CustomPainter>{
      for (final role in RolePreset.values) role: make(role),
    };
    final entries = painters.entries.toList();
    for (var i = 0; i < entries.length; i++) {
      for (var j = i + 1; j < entries.length; j++) {
        expect(
          entries[i].value.runtimeType,
          isNot(entries[j].value.runtimeType),
          reason:
              'roles ${entries[i].key} and ${entries[j].key} returned the '
              'same painter type (${entries[i].value.runtimeType}). Each '
              'role must paint a distinct background texture.',
        );
      }
    }
  });

  test('isOrchestrator overrides the role-specific painter', () {
    // The orchestrator signature is the conductor surface — passing
    // `isOrchestrator: true` must yield the orchestrator painter
    // regardless of the agent's nominal role. Without this rule, a
    // user-created custom orchestrator would render with the custom
    // signature instead of the command-center vibe.
    for (final role in RolePreset.values) {
      final painter = make(role, isOrchestrator: true);
      expect(
        painter,
        isA<OrchestratorRoleSignaturePainter>(),
        reason:
            'orchestrator override must beat role=$role; got '
            '${painter.runtimeType}',
      );
    }
  });

  test('shouldRepaint returns false when nothing changed', () {
    // Repaint hygiene — burning CPU on identical frames was the
    // landmine the original `_DigitalGridPainter` avoided via its
    // own shouldRepaint. The split painters must keep that promise.
    for (final role in RolePreset.values) {
      final a = make(role);
      final b = make(role);
      // ignore: invalid_use_of_protected_member
      expect(
        a.shouldRepaint(b),
        isFalse,
        reason:
            '$role painter shouldRepaint must return false when nothing '
            'changed; otherwise it will burn frames on static cards.',
      );
    }
    final orchA = make(RolePreset.custom, isOrchestrator: true);
    final orchB = make(RolePreset.custom, isOrchestrator: true);
    // ignore: invalid_use_of_protected_member
    expect(orchA.shouldRepaint(orchB), isFalse);
  });
}
