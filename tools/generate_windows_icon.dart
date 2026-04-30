import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

/// Regenerate the Windows `.ico` from the dedicated **app-icon** PNG.
///
/// **There are two distinct logo PNGs in this project — don't mix them up:**
///
///   - `assets/images/lumen_logo.png` — the original line-art falcon
///     used by the welcome screen, About dialog, and other places
///     where it renders ≥48px. Beautiful at large sizes.
///   - `assets/images/lumen_app_icon.png` — the SOLID-FILL icon
///     designed specifically for OS use (taskbar, title bar,
///     Alt-Tab). Has its own rounded-square background and a filled
///     silhouette of the falcon so the mark survives 16px scaling.
///
/// The line-art version cannot be the OS icon because thin strokes
/// anti-alias to invisibility at 16/20/24 px. See the knowledgebase
/// `Native Windows title-bar icon` section for the full rationale.
///
/// This script:
///   1. Loads the dedicated icon source.
///   2. Center-crops it to a square (the generator tolerates any
///      input aspect ratio so we can swap source images without
///      pre-cropping).
///   3. Resizes into the standard ICO frame sizes
///      (16/20/24/32/48/64/128/256). No per-frame padding tricks —
///      the source already has the right negative space baked in.
///   4. Writes a multi-frame ICO to `windows/runner/resources/app_icon.ico`.
///
/// Re-run after editing `lumen_app_icon.png`:
///   `dart run tools/generate_windows_icon.dart`
void main() {
  final sourceFile = File('assets/images/lumen_app_icon.png');
  if (!sourceFile.existsSync()) {
    throw StateError(
      'App-icon source missing: ${sourceFile.path}.\n'
      'Generate it (see knowledgebase) or restore from git.',
    );
  }
  final outFile = File('windows/runner/resources/app_icon.ico');

  final source = decodePng(sourceFile.readAsBytesSync());
  if (source == null) {
    throw StateError('Could not decode ${sourceFile.path}');
  }
  final square = _centerCropSquare(source);

  final frames = <Image>[];
  for (final size in const [16, 20, 24, 32, 48, 64, 128, 256]) {
    frames.add(
      copyResize(
        square,
        width: size,
        height: size,
        // `cubic` preserves edge sharpness better than `average` at
        // small sizes; the slight halo it produces is hidden by the
        // rounded-square background.
        interpolation: Interpolation.cubic,
      ),
    );
  }

  final ico = Image.from(frames.first);
  for (final frame in frames.skip(1)) {
    ico.addFrame(frame);
  }
  outFile.writeAsBytesSync(encodeIco(ico));

  // Print a quick summary so the operator can confirm the new ICO
  // landed without poking at the binary.
  final kb = (outFile.lengthSync() / 1024).toStringAsFixed(1);
  // ignore: avoid_print
  print(
    'Wrote ${outFile.path} (${kb}KB, ${frames.length} frames: '
    '${frames.map((f) => '${f.width}').join('/')}).',
  );
}

/// Center-crop [src] to a square using the smaller of the two
/// dimensions. Any extra width/height around the centred square is
/// trimmed. No-op when the input is already square.
Image _centerCropSquare(Image src) {
  final side = math.min(src.width, src.height);
  if (src.width == side && src.height == side) return src;
  final x = ((src.width - side) / 2).round();
  final y = ((src.height - side) / 2).round();
  return copyCrop(src, x: x, y: y, width: side, height: side);
}
