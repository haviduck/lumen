import 'dart:io';
import 'dart:math' as math;

import 'package:image/image.dart';

/// Strip the dark rounded-square background from the OS-icon source
/// PNG and emit a transparent in-app logo PNG.
///
/// **Why this script exists.** Lumen ships two PNGs that must visually
/// agree (so the OS taskbar/title-bar mark and the in-app About /
/// Welcome mark look like the same brand):
///
///   - `assets/images/lumen_app_icon.png` — the OS-icon source. Has a
///     dark rounded-square tile background with the bulb mark on top.
///     This is the file the `.ico` generator consumes.
///   - `assets/images/lumen_logo.png` — the in-app logo. Same mark,
///     but on a fully transparent background so it can sit on the
///     dark glass surfaces of the welcome screen and About dialog
///     without a competing tile.
///
/// AI image generators are unreliable at honouring "transparent
/// background" (they smuggle a background back in), so we generate the
/// dark-tile version first and derive the transparent version from it
/// by luminance keying. Same source = same proportions, same glow,
/// guaranteed alignment.
///
/// ## Algorithm
///
/// For every pixel:
///   1. Compute luminance L in [0, 1] using the standard Rec.709 mix.
///   2. Map L through a smoothstep from `lowCut` to `highCut`:
///        - L < lowCut    → fully transparent (the dark tile dies).
///        - L > highCut   → fully opaque (the white bulb stays solid).
///        - in-between    → soft alpha so the cool-blue glow halo
///          fades naturally instead of clipping to a hard edge.
///   3. The RGB channel is renormalised by the luminance ratio so the
///      surviving pixels read as their original colour rather than
///      darkening at the edges (the glow keeps its blue, not muddies
///      to grey).
///
/// Re-run after editing `lumen_app_icon.png`:
///   `dart run tools/extract_logo_no_bg.dart`
void main() {
  final sourceFile = File('assets/images/lumen_app_icon.png');
  if (!sourceFile.existsSync()) {
    throw StateError(
      'Logo source missing: ${sourceFile.path}.\n'
      'Place the dark-tile app icon there first.',
    );
  }

  final raw = decodePng(sourceFile.readAsBytesSync());
  if (raw == null) {
    throw StateError('Could not decode ${sourceFile.path}');
  }

  final src = _centerCropSquare(raw);

  // Smoothstep luminance keying: the dark tile (luminance ~0.05–0.10)
  // fades to transparent while the bright flame mark and its blue glow
  // (luminance ~0.15+) survive with their original colour intact.
  // Tune lowCut/highCut if a future icon changes tile darkness or glow
  // intensity — see the doc comment at the top of this file.
  final cleaned = _smoothstepKey(src, lowCut: 0.22, highCut: 0.45);

  final out = _trimTransparent(cleaned, alphaThreshold: 0);

  final outFile = File('assets/images/lumen_logo.png');
  outFile.writeAsBytesSync(encodePng(out));

  _writeDarkGlassPreview(out);

  final kb = (outFile.lengthSync() / 1024).toStringAsFixed(1);
  // ignore: avoid_print
  print(
    'Wrote ${outFile.path} '
    '(${kb}KB, ${out.width}x${out.height}, RGBA, smoothstep-keyed from '
    '${sourceFile.path}).',
  );
}

/// Composite [logo] onto a dark-glass background colour matching the
/// welcome screen / About dialog and write to `tools/_out/`. A
/// debugging aid, not a shipped asset.
void _writeDarkGlassPreview(Image logo) {
  // Match `DuckColors.bgGlassHi` family — the welcome / About
  // surfaces sit close to this. Picking #1B1F26 gives us a
  // representative dark-glass shade without depending on the
  // theme module.
  const bgR = 0x1B, bgG = 0x1F, bgB = 0x26;
  final preview = Image(
    width: logo.width,
    height: logo.height,
    numChannels: 3,
  );
  for (final p in logo) {
    final a = p.a / 255.0;
    final r = (p.r * a + bgR * (1 - a)).round();
    final g = (p.g * a + bgG * (1 - a)).round();
    final b = (p.b * a + bgB * (1 - a)).round();
    preview.setPixelRgb(p.x, p.y, r, g, b);
  }
  final outDir = Directory('tools/_out');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final previewFile = File('tools/_out/lumen_logo_preview_dark_glass.png');
  previewFile.writeAsBytesSync(encodePng(preview));
  // ignore: avoid_print
  print(
    'Wrote ${previewFile.path} (preview-only; safe to delete or '
    'gitignore).',
  );
}

/// Smoothstep luminance keying: pixels below [lowCut] become fully
/// transparent, pixels above [highCut] are fully opaque, and pixels
/// in between get a smoothly interpolated alpha. Original RGB colours
/// are preserved so the blue glow reads correctly on dark surfaces.
Image _smoothstepKey(Image src,
    {required double lowCut, required double highCut}) {
  final out = Image(
    width: src.width,
    height: src.height,
    numChannels: 4,
  );
  for (final p in src) {
    final srcAlpha = p.a / 255.0;
    if (srcAlpha < 0.05) {
      out.setPixelRgba(p.x, p.y, 0, 0, 0, 0);
      continue;
    }
    final r = p.r / 255.0;
    final g = p.g / 255.0;
    final b = p.b / 255.0;
    final lum = 0.2126 * r + 0.7152 * g + 0.0722 * b;

    if (lum <= lowCut) {
      out.setPixelRgba(p.x, p.y, 0, 0, 0, 0);
      continue;
    }
    if (lum >= highCut) {
      out.setPixelRgba(
        p.x,
        p.y,
        (r * 255).round().clamp(0, 255),
        (g * 255).round().clamp(0, 255),
        (b * 255).round().clamp(0, 255),
        (srcAlpha * 255).round().clamp(0, 255),
      );
      continue;
    }

    // Smoothstep interpolation for the transition zone.
    var t = (lum - lowCut) / (highCut - lowCut);
    t = t * t * (3.0 - 2.0 * t); // Hermite smoothstep
    final a = (t * srcAlpha * 255).round().clamp(0, 255);
    out.setPixelRgba(
      p.x,
      p.y,
      (r * 255).round().clamp(0, 255),
      (g * 255).round().clamp(0, 255),
      (b * 255).round().clamp(0, 255),
      a,
    );
  }
  return out;
}

/// Center-crop [src] to a square using the smaller of the two
/// dimensions. Mirrors `tools/generate_windows_icon.dart` so both the
/// OS icon and the in-app logo derive from the same square framing.
Image _centerCropSquare(Image src) {
  final side = math.min(src.width, src.height);
  if (src.width == side && src.height == side) return src;
  final x = ((src.width - side) / 2).round();
  final y = ((src.height - side) / 2).round();
  return copyCrop(src, x: x, y: y, width: side, height: side);
}

/// Crop to the bounding box of visible (non-transparent) content,
/// removing fully-transparent rows/columns from all four edges.
/// Pixels with alpha <= [alphaThreshold] are treated as transparent.
/// Returns the original image if no trimming is possible.
Image _trimTransparent(Image src, {int alphaThreshold = 0}) {
  int top = 0, bottom = src.height - 1;
  int left = 0, right = src.width - 1;

  bool rowEmpty(int y) {
    for (var x = 0; x < src.width; x++) {
      if (src.getPixel(x, y).a > alphaThreshold) return false;
    }
    return true;
  }

  bool colEmpty(int x) {
    for (var y = 0; y < src.height; y++) {
      if (src.getPixel(x, y).a > alphaThreshold) return false;
    }
    return true;
  }

  while (top <= bottom && rowEmpty(top)) top++;
  while (bottom >= top && rowEmpty(bottom)) bottom--;
  while (left <= right && colEmpty(left)) left++;
  while (right >= left && colEmpty(right)) right--;

  if (top > bottom || left > right) return src;

  final w = right - left + 1;
  final h = bottom - top + 1;
  if (w == src.width && h == src.height) return src;
  return copyCrop(src, x: left, y: top, width: w, height: h);
}
