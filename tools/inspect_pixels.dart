import 'dart:io';
import 'package:image/image.dart';

void main() {
  final img = decodePng(File('assets/images/lumen_logo_clean.png').readAsBytesSync())!;
  print('Size: ${img.width}x${img.height}, channels: ${img.numChannels}');

  final spots = [
    (0, 0, 'top-left corner'),
    (10, 10, 'near corner'),
    (img.width ~/ 2, 10, 'top center'),
    (img.width ~/ 2, img.height ~/ 2, 'dead center'),
    (img.width - 1, img.height - 1, 'bottom-right corner'),
    (img.width ~/ 4, img.height ~/ 4, 'quarter'),
  ];

  for (final (x, y, label) in spots) {
    final p = img.getPixel(x, y);
    print('  $label ($x,$y): R=${p.r.toInt()} G=${p.g.toInt()} B=${p.b.toInt()} A=${p.a.toInt()}');
  }

  // Count transparent vs opaque
  var transparent = 0;
  var opaque = 0;
  var semi = 0;
  for (final p in img) {
    final a = p.a.toInt();
    if (a == 0) {
      transparent++;
    } else if (a == 255) {
      opaque++;
    } else {
      semi++;
    }
  }
  final total = img.width * img.height;
  print('\nAlpha stats:');
  print('  Transparent (a=0): $transparent (${(transparent * 100 / total).toStringAsFixed(1)}%)');
  print('  Opaque (a=255): $opaque (${(opaque * 100 / total).toStringAsFixed(1)}%)');
  print('  Semi-transparent: $semi (${(semi * 100 / total).toStringAsFixed(1)}%)');
}
