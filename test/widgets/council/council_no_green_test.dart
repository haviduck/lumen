// Static-source guard: forbids green color literals in lib/widgets/council/.
// Rationale: Requirement #7 says agent panels are dark blue, not green. A
// human eye-sweep is unreliable across themes and lighting; this test fails
// loudly the moment any green token sneaks back in via copy-paste from older
// branches.
//
// Strategy: scan every .dart file under lib/widgets/council/ for known green
// vectors (Colors.green*, Colors.lightGreen*, and hex literals whose green
// channel dominates by a clear margin). False-positive rate is the trade —
// dominance threshold is intentionally strict so neutral teals/cyans (the
// allowed accent family) survive.
//
// Run: `flutter test test/widgets/council/council_no_green_test.dart`
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no green color literals in lib/widgets/council/', () {
    final dir = Directory('lib/widgets/council');
    expect(dir.existsSync(), isTrue,
        reason: 'council widget dir missing — repo layout changed?');

    final offenders = <String>[];

    final namedGreen = RegExp(
      r'\bColors\.(green|lightGreen)(?:Accent)?\b',
    );
    final hexLiteral = RegExp(r'0x([0-9a-fA-F]{8})\b');

    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Strip line comments so commented-out experiments don't fail us.
        final code = line.split('//').first;

        if (namedGreen.hasMatch(code)) {
          offenders.add('${entity.path}:${i + 1}: ${line.trim()}');
          continue;
        }

        for (final m in hexLiteral.allMatches(code)) {
          final argb = int.parse(m.group(1)!, radix: 16);
          final r = (argb >> 16) & 0xFF;
          final g = (argb >> 8) & 0xFF;
          final b = argb & 0xFF;
          // "Green" = green channel meaningfully dominates BOTH others
          // and is itself bright enough to read as green on screen.
          // Threshold: g >= 140, g - r >= 40, g - b >= 40.
          // This rejects e.g. 0xFF22CC44 (clear green) but allows
          // teal/cyan accents (where b is close to or above g) and
          // dark blues (where g is dim).
          if (g >= 140 && (g - r) >= 40 && (g - b) >= 40) {
            offenders.add(
              '${entity.path}:${i + 1}: green-dominant hex 0x'
              '${argb.toRadixString(16).toUpperCase().padLeft(8, '0')} '
              'in: ${line.trim()}',
            );
          }
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'Council surface must be dark-blue family, not green. Offenders:\n'
          '${offenders.join('\n')}',
    );
  });
}
