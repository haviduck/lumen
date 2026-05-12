// Static-source guard: speech bubble background must be opaque.
// Rationale: speech bubble backgrounds need opacity = 1.0 so the
// narration text stays readable over the council canvas (traffic
// mesh, backdrop atmosphere, agent transcript wells). The previous
// regression was `DuckColors.bgDeepest.withValues(alpha: 0.30)` as
// the bubble fill — this test locks that and any other translucent
// fill out of the bubble surface.
//
// 2026-05 redesign moved the visual surface to
// `activity_bubble_card.dart` (the per-agent activity card that
// replaced the old streamed-snippet bubbles). The markers stayed
// with the actual DecoratedBox that paints the bubble fill.
//
// Strategy: parse activity_bubble_card.dart and forbid translucent
// alpha values inside the contiguous block that builds the main
// bubble surface. We bound the scan to marker comments
// ("// BUBBLE_BG_BEGIN") and ("// BUBBLE_BG_END") that MUST wrap
// the bubble's DecoratedBox. Without the markers the test fails —
// that failure forces the doers to declare which lines are the
// bubble bg, which is itself the contract.
//
// Run: `flutter test test/widgets/council/council_speech_bubble_opacity_test.dart`
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = 'lib/widgets/council/speech/activity_bubble_card.dart';
  const beginMarker = '// BUBBLE_BG_BEGIN';
  const endMarker = '// BUBBLE_BG_END';

  test('speech bubble background block is fully opaque', () {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path missing');

    final src = file.readAsStringSync();
    final beginIdx = src.indexOf(beginMarker);
    final endIdx = src.indexOf(endMarker);

    expect(
      beginIdx >= 0 && endIdx > beginIdx,
      isTrue,
      reason:
          'Bubble background block must be wrapped with $beginMarker / '
          '$endMarker comments in $path so this test can scope its '
          'opacity assertion. (Without the markers we cannot prove which '
          'BoxDecoration is the bubble fill.)',
    );

    final block = src.substring(beginIdx, endIdx);

    final translucentWithValues = RegExp(
      r'\.withValues\(\s*alpha:\s*0?\.\d+',
    );
    final translucentWithOpacity = RegExp(
      r'\.withOpacity\(\s*0?\.\d+',
    );
    final hexAlphaLiteral = RegExp(r'Color\(\s*0x([0-9a-fA-F]{2})');

    final violations = <String>[];

    if (translucentWithValues.hasMatch(block)) {
      violations.add(
        'translucent .withValues(alpha: <1.0) inside bubble bg block',
      );
    }
    if (translucentWithOpacity.hasMatch(block)) {
      violations.add(
        'translucent .withOpacity(<1.0) inside bubble bg block',
      );
    }
    for (final m in hexAlphaLiteral.allMatches(block)) {
      final alpha = int.parse(m.group(1)!, radix: 16);
      if (alpha < 0xFF) {
        violations.add(
          'Color(0x${m.group(1)}...) has alpha < 0xFF inside bubble bg block',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Bubble background must be fully opaque (alpha == 1.0). '
          'Violations: ${violations.join('; ')}',
    );
  });
}
