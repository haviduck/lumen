// Smoke + rendering shape tests for the integrated voice panel
// introduced in the 2026-05 council redesign. The voice panel is the
// in-card replacement for the old floating bubble layer; these tests
// pin its basic contract:
//
//   1. Renders the agent name in the eyebrow row (uppercase).
//   2. Renders the narrateAgent primary line (here "Idle." for an
//      agent in idle state — the narration pipeline is verified more
//      extensively by the pure-function tests under test/council/).
//   3. Falls back gracefully when no session is attached — the panel
//      depends on `context.select<AppState, CouncilSession?>` for the
//      task ledger and pool-questions list, and a null session must
//      not crash. (The voice panel can be torn down + remounted as
//      the user opens/closes a council, so this is real.)
//
// Anything beyond these reduces to the narration pipeline. We don't
// re-test narrateAgent here — it's pure-function tested elsewhere.
//
// Run: `flutter test test/widgets/council/agent_voice_panel_test.dart`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:lumen/providers/app_state.dart';
import 'package:lumen/services/council/council_models.dart';
import 'package:lumen/widgets/council/speech/agent_voice_panel.dart';

CouncilAgent _mkAgent(String id, String name) => CouncilAgent(
      id: id,
      name: name,
      role: RolePreset.researcher,
      model: 'm',
    );

Widget _wrap({
  required AppState app,
  required CouncilAgent agent,
  bool isOrchestrator = false,
}) {
  return MediaQuery(
    data: const MediaQueryData(),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: Material(
          color: const Color(0xFF000000),
          child: SizedBox(
            width: 300,
            child: AgentVoicePanel(
              agent: agent,
              isOrchestrator: isOrchestrator,
              breathT: 0.5,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('voice panel renders agent name + idle narration line',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);

    final agent = _mkAgent('a1', 'Maya');
    await tester.pumpWidget(_wrap(app: app, agent: agent));
    // Two pumps: first paints, second triggers postFrameCallback
    // which subscribes to controller events.
    await tester.pump();

    expect(find.text(agent.name.toUpperCase()), findsOneWidget,
        reason: 'eyebrow must show the agent name in uppercase');
    expect(find.text('Idle.'), findsOneWidget,
        reason: 'idle agents should render the canonical "Idle." line');
  });

  testWidgets('voice panel mounts cleanly with no session attached',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);

    final agent = _mkAgent('a1', 'Linus');
    await tester.pumpWidget(_wrap(app: app, agent: agent));
    await tester.pump();

    // The panel must survive a null session — no exception, no
    // missing text. The mention + targeting chip code paths
    // short-circuit silently in this branch.
    expect(find.text(agent.name.toUpperCase()), findsOneWidget);
  });

  testWidgets('orchestrator label falls back to councilOrchestrator when name is blank',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);

    final orch = CouncilAgent(
      id: 'orch',
      name: '',
      role: RolePreset.architect,
      model: 'm',
    );
    await tester.pumpWidget(_wrap(app: app, agent: orch, isOrchestrator: true));
    await tester.pump();

    // Orchestrator with no display name should still get a non-empty
    // eyebrow label — used the i18n fallback so we can spot when the
    // string source moved.
    expect(find.text('ORCHESTRATOR'), findsOneWidget);
  });
}
