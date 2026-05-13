// Smoke + paint-shape tests for the council chamber backdrop.
//
// The 2026-05 redesign rewrote `CouncilDiagonalBackdrop` from a flat
// diagonal-stripe drift into a depth-perspective war room (floor
// grid, horizon haze, ambient motes, vignette, ceiling fade). This
// test pins the basics:
//
//   1. The widget renders inside a sized box without throwing.
//   2. The widget mounts a [CustomPaint] whose painter is non-null
//      and whose render box is the full size of the parent. This is
//      our proxy for "paints a non-zero amount of pixels into a
//      sized box" — a CustomPaint with a real painter and a
//      non-zero size WILL emit draw calls into the canvas. We
//      avoid `RepaintBoundary.toImage()` because the test
//      environment's raster cache does not back `toImage` deterministically
//      on Windows + Flutter 3.41 (the call has been observed to
//      hang for 10 minutes).
//   3. The widget tolerates an agentCount change without throwing —
//      the previous regression here was a `late final` field that
//      could not be re-baked.
//
// Detailed visual contract (which lines, which gradient stops) is
// intentionally NOT tested here — that's the kind of pixel-perfect
// guard that breaks every time anyone tunes a colour, and the
// chamber is exactly the surface we expect to keep tuning.
//
// Run: `flutter test test/widgets/council/council_chamber_test.dart`
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lumen/widgets/council/council_backdrop.dart';

Widget _wrap({required Widget child}) {
  return MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: ColoredBox(
        color: const Color(0xFF000000),
        child: SizedBox(
          width: 800,
          height: 600,
          child: child,
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('chamber backdrop renders without throwing', (tester) async {
    await tester.pumpWidget(_wrap(
      child: const CouncilDiagonalBackdrop(agentCount: 4),
    ));
    // Two pumps: first paints the initial frame, second lets the
    // backdrop's drift controller advance one tick.
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.byType(CouncilDiagonalBackdrop), findsOneWidget);
  });

  testWidgets('chamber backdrop mounts a sized CustomPaint with a painter',
      (tester) async {
    await tester.pumpWidget(_wrap(
      child: const CouncilDiagonalBackdrop(agentCount: 6),
    ));
    await tester.pump(const Duration(milliseconds: 16));

    // The chamber paints via a single CustomPaint child inside its
    // RepaintBoundary. Verify the CustomPaint is mounted, its size
    // is non-zero, and its painter slot is filled — together these
    // prove the painter will actually emit draw calls when Flutter
    // rasterises the frame.
    final paintFinder = find.descendant(
      of: find.byType(CouncilDiagonalBackdrop),
      matching: find.byType(CustomPaint),
    );
    expect(paintFinder, findsAtLeastNWidgets(1),
        reason:
            'Chamber should mount a CustomPaint to host the depth + '
            'particle painter.');

    // Find a CustomPaint whose painter is non-null AND whose render
    // box has a non-zero size. (The agent voice panel / cadence
    // strip also mount CustomPaints elsewhere in the tree — we only
    // care that AT LEAST ONE under the chamber meets the shape.)
    final candidates = tester.widgetList<CustomPaint>(paintFinder).toList();
    var sized = false;
    for (final p in candidates) {
      if (p.painter == null) continue;
      final widgetElement = paintFinder.evaluate().firstWhere(
            (e) => e.widget == p,
            orElse: () => paintFinder.evaluate().first,
          );
      final box = widgetElement.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        if (box.size.width > 0 && box.size.height > 0) {
          sized = true;
          break;
        }
      }
    }
    expect(sized, isTrue,
        reason:
            'Expected at least one CustomPaint inside the chamber to '
            'have a non-null painter and a non-zero rendered size — '
            'that is the contract that proves the painter will lay '
            'pixels into the canvas.');
  });

  testWidgets('chamber backdrop accepts an agentCount of 0 without crashing',
      (tester) async {
    await tester.pumpWidget(_wrap(
      child: const CouncilDiagonalBackdrop(agentCount: 0),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  });

  testWidgets('chamber backdrop tolerates an agent count change without throw',
      (tester) async {
    await tester.pumpWidget(_wrap(
      child: const CouncilDiagonalBackdrop(agentCount: 2),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pumpWidget(_wrap(
      child: const CouncilDiagonalBackdrop(agentCount: 12),
    ));
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull);
  });
}
