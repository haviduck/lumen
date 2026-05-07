// Static-source guard: speech bubble background must be opaque.
// Rationale: Requirement #5 demands speech bubble backgrounds with
// opacity = 1.0 so text is readable over any canvas content. Today the
// source uses `DuckColors.bgDeepest.withValues(alpha: 0.30)` for the
// bubble fill (council_speech_bubbles.dart, ~line 875) — that's the
// regression we're locking out.
//
// Strategy: parse council_speech_bubbles.dart and forbid translucent
// alpha values inside the contiguous block that builds the main bubble
// surface (the BoxDecoration / gradient feeding the bubble container).
// We bound the scan to marker comments ("// BUBBLE_BG_BEGIN") and
// ("// BUBBLE_BG_END") that the doers MUST add around the bubble's
// background decoration. Without the markers the test fails — that
// failure forces the doers to declare which lines are the bubble bg,
// which is itself the contract.
//
// Run: `flutter test test/widgets/council/council_speech_bubble_opacity_test.dart`
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = 'lib/widgets/council/council_speech_bubbles.dart';
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
