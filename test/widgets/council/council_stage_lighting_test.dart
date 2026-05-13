// Smoke tests for the council stage-lighting overlay.
//
// The lighting overlay reads the active session via Provider.select
// and washes the chamber with a mood-coloured tint. The first thing
// that has to work is the null-session path — the widget can be torn
// down + remounted on every Convene click, so a freshly-built
// `AppState` (no council session yet) must not crash it.
//
// We also exercise the basic mount path to assert the widget renders
// without throwing under the default tint and the default
// AnimationController motion.
//
// Run: `flutter test test/widgets/council/council_stage_lighting_test.dart`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:duckoff/providers/app_state.dart';
import 'package:duckoff/widgets/council/council_stage_lighting.dart';

Widget _wrap({required AppState app}) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ChangeNotifierProvider<AppState>.value(
        value: app,
        child: ColoredBox(
          color: const Color(0xFF000000),
          child: const SizedBox(
            width: 800,
            height: 600,
            child: CouncilStageLighting(),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('stage lighting mounts cleanly with no session attached',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);

    await tester.pumpWidget(_wrap(app: app));
    await tester.pump(const Duration(milliseconds: 16));

    expect(tester.takeException(), isNull,
        reason:
            'A null session (no council convened yet) must not throw — '
            'the lighting widget is mounted at theater build time and '
            'has to survive the empty state.');
    expect(find.byType(CouncilStageLighting), findsOneWidget);
  });

  testWidgets('stage lighting survives multiple frames without throwing',
      (tester) async {
    final app = AppState();
    addTearDown(app.dispose);

    await tester.pumpWidget(_wrap(app: app));
    // Pump enough frames that the breath controller's repeat() takes
    // hold and the post-frame mood transition callback fires at
    // least once.
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
    expect(tester.takeException(), isNull);
  });
}
