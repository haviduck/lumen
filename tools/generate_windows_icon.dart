import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

/// Regenerate the Windows `.ico` from `assets/images/lumen_logo.png`.
///
/// The logo PNG is the single source-of-truth icon asset. It contains
/// the dark rounded-square tile with the flame mark — fully opaque,
/// no transparency issues on Windows.
///
/// Any residual alpha (e.g. anti-aliased outer edges) is flattened
/// onto a dark fill (#0B1120) before encoding so that Windows never
/// composites against white in the title bar / taskbar / Alt-Tab.
///
/// This script:
///   1. Loads the logo source.
///   2. Flattens alpha onto the dark background colour.
///   3. Center-crops to a square.
///   4. Resizes into standard ICO frame sizes (16–256).
///   5. Writes a multi-frame ICO to `windows/runner/resources/app_icon.ico`.
///
/// Re-run after editing `lumen_logo.png`:
///   `dart run tools/generate_windows_icon.dart`
void main() {
  final sourceFile = File('assets/images/lumen_logo.png');
  if (!sourceFile.existsSync()) {
    throw StateError(
      'Logo source missing: ${sourceFile.path}.\n'
      'Restore from git or regenerate the asset.',
    );
  }
  final outFile = File('windows/runner/resources/app_icon.ico');

  final source = decodePng(sourceFile.readAsBytesSync());
  if (source == null) {
    throw StateError('Could not decode ${sourceFile.path}');
  }

  final flattened = _flattenAlpha(source);
  final square = _centerCropSquare(flattened);

  final frames = <Image>[];
  for (final size in const [16, 20, 24, 32, 48, 64, 128, 256]) {
    frames.add(
      copyResize(
        square,
        width: size,
        height: size,
        interpolation: Interpolation.cubic,
      ),
    );
  }

  final ico = Image.from(frames.first);
  for (final frame in frames.skip(1)) {
    ico.addFrame(frame);
  }
  outFile.writeAsBytesSync(encodeIco(ico));

  final kb = (outFile.lengthSync() / 1024).toStringAsFixed(1);
  // ignore: avoid_print
  print(
    'Wrote ${outFile.path} (${kb}KB, ${frames.length} frames: '
    '${frames.map((f) => '${f.width}').join('/')}).',
  );
}

/// Composite every pixel over a solid dark background (#0B1120),
/// eliminating any alpha channel. This prevents Windows from showing
/// white where the ICO has transparent/semi-transparent pixels.
Image _flattenAlpha(Image src) {
  const bgR = 0x0B;
  const bgG = 0x11;
  const bgB = 0x20;

  final out = Image(width: src.width, height: src.height);
  for (int y = 0; y < src.height; y++) {
    for (int x = 0; x < src.width; x++) {
      final pixel = src.getPixel(x, y);
      final a = pixel.a.toInt();
      if (a == 255) {
        out.setPixelRgba(x, y, pixel.r.toInt(), pixel.g.toInt(),
            pixel.b.toInt(), 255);
      } else if (a == 0) {
        out.setPixelRgba(x, y, bgR, bgG, bgB, 255);
      } else {
        final af = a / 255.0;
        final r = (pixel.r.toInt() * af + bgR * (1 - af)).round();
        final g = (pixel.g.toInt() * af + bgG * (1 - af)).round();
        final b = (pixel.b.toInt() * af + bgB * (1 - af)).round();
        out.setPixelRgba(x, y, r, g, b, 255);
      }
    }
  }
  return out;
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
