// Static-source guard: voice panel background must be opaque.
// Rationale: the agent voice panel's narration surface needs
// opacity = 1.0 so primary narration text stays readable over the
// card chrome (digital grid + scan line + cadence spectrum). The
// previous regression was `DuckColors.bgDeepest.withValues(alpha: 0.30)`
// as the bubble fill — this test locks that and any other translucent
// fill out of the speech surface.
//
// 2026-05 redesign #2 (voice-panel integration): the floating bubble
// surface (`activity_bubble_card.dart`) was retired entirely. The
// speech surface now lives inside each agent card via
// `agent_voice_panel.dart`. The opacity contract moved with it; the
// markers wrap the new DecoratedBox that paints the voice panel fill.
//
// Strategy: parse `agent_voice_panel.dart` and forbid translucent
// alpha values inside the contiguous block that builds the voice
// surface. We bound the scan to marker comments
// ("// VOICE_BG_BEGIN") and ("// VOICE_BG_END") that MUST wrap the
// voice panel's DecoratedBox. Without the markers the test fails —
// that failure forces the doers to declare which lines are the
// voice bg, which is itself the contract.
//
// Run: `flutter test test/widgets/council/council_speech_bubble_opacity_test.dart`
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const path = 'lib/widgets/council/speech/agent_voice_panel.dart';
  const beginMarker = '// VOICE_BG_BEGIN';
  const endMarker = '// VOICE_BG_END';

  test('agent voice panel background block is fully opaque', () {
    final file = File(path);
    expect(file.existsSync(), isTrue, reason: '$path missing');

    final src = file.readAsStringSync();
    final beginIdx = src.indexOf(beginMarker);
    final endIdx = src.indexOf(endMarker);

    expect(
      beginIdx >= 0 && endIdx > beginIdx,
      isTrue,
      reason:
          'Voice panel background block must be wrapped with $beginMarker / '
          '$endMarker comments in $path so this test can scope its '
          'opacity assertion. (Without the markers we cannot prove which '
          'BoxDecoration is the voice fill.)',
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
        'translucent .withValues(alpha: <1.0) inside voice bg block',
      );
    }
    if (translucentWithOpacity.hasMatch(block)) {
      violations.add(
        'translucent .withOpacity(<1.0) inside voice bg block',
      );
    }
    for (final m in hexAlphaLiteral.allMatches(block)) {
      final alpha = int.parse(m.group(1)!, radix: 16);
      if (alpha < 0xFF) {
        violations.add(
          'Color(0x${m.group(1)}...) has alpha < 0xFF inside voice bg block',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Voice panel background must be fully opaque (alpha == 1.0). '
          'Violations: ${violations.join('; ')}',
    );
  });
}
