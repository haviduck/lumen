// Phase transition overlay smoke + edge-trigger tests.
//
// The overlay is a one-shot cinematic beat that fires when a session's
// `phaseHistory` grows. Pin three behaviours:
//
//   1. With an empty `phaseHistory`, the overlay mounts cleanly and
//      paints nothing (no headline, no throw).
//   2. Appending a transition to `phaseHistory` and rebuilding does
//      not throw and surfaces the destination phase label.
//   3. The overlay is `IgnorePointer: true` so it can never steal
//      clicks from the modal overlays mounted above it.
//
// We avoid asserting on transient frame state (particle radius, etc.)
// — those are visual details that would make the test brittle.
//
// Run: `flutter test test/widgets/council/council_phase_transition_overlay_test.dart`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duckoff/l10n/strings.dart';
import 'package:duckoff/services/council/council_models.dart';
import 'package:duckoff/widgets/council/council_phase_transition_overlay.dart';

CouncilAgent _mkAgent(String id, String name, {RolePreset? role}) =>
    CouncilAgent(
      id: id,
      name: name,
      role: role ?? RolePreset.researcher,
      model: 'm',
    );

CouncilSession _mkSession() {
  final orch = _mkAgent('orch', 'Maya', role: RolePreset.architect);
  final a1 = _mkAgent('a1', 'Linus');
  final cfg = CouncilConfig(
    id: 'sess-1',
    title: 'transition test',
    brief: 'design a thing',
    orchestrator: orch,
    agents: [a1],
  );
  return CouncilSession(config: cfg);
}

Widget _wrap(Widget child) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(900, 600)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Material(
        color: const Color(0xFF000000),
        child: SizedBox(
          width: 900,
          height: 600,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('mounts cleanly with empty phaseHistory', (tester) async {
    final session = _mkSession();
    expect(session.phaseHistory, isEmpty);

    await tester.pumpWidget(_wrap(
      CouncilPhaseTransitionOverlay(session: session),
    ));
    await tester.pump();

    // Headline is absent in the dormant state.
    expect(find.text(S.councilPhaseDiscovery.toUpperCase()), findsNothing);
    expect(find.text(S.councilPhaseBuild.toUpperCase()), findsNothing);
  });

  testWidgets(
      'appending a transition triggers the overlay and renders the phase label',
      (tester) async {
    final session = _mkSession();

    await tester.pumpWidget(_wrap(
      CouncilPhaseTransitionOverlay(session: session),
    ));
    await tester.pump();

    // Append the transition and rebuild the widget — the overlay
    // detects the new entry via didUpdateWidget.
    session.phaseHistory.add(
      CouncilPhaseEntry(
        phase: CouncilPhase.build,
        rationale: 'Sub-waves spread; foundations need pouring.',
        declaredAt: DateTime.now(),
      ),
    );
    await tester.pumpWidget(_wrap(
      CouncilPhaseTransitionOverlay(session: session),
    ));
    // First pump fires the postFrameCallback that drives `forward`.
    await tester.pump();
    // Second pump lets the controller make progress past zero so the
    // headline is mounted (controller value > 0 after a few frames).
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text(S.councilPhaseBuild.toUpperCase()), findsWidgets,
        reason: 'destination phase label should appear in caps');
  });

  testWidgets('overlay is IgnorePointer so it does not eat taps',
      (tester) async {
    final session = _mkSession();
    session.phaseHistory.add(
      CouncilPhaseEntry(
        phase: CouncilPhase.review,
        rationale: 'Adversarial wave engaged.',
        declaredAt: DateTime.now(),
      ),
    );

    int tapCount = 0;
    await tester.pumpWidget(_wrap(
      Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => tapCount++,
              child: const SizedBox.expand(),
            ),
          ),
          Positioned.fill(
            child: CouncilPhaseTransitionOverlay(session: session),
          ),
        ],
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    await tester.tap(find.byType(Stack), warnIfMissed: false);
    await tester.pump();
    expect(tapCount, 1,
        reason: 'overlay must never block the underlying tap target');
  });
}
