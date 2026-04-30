import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';

/// IDE shell's bottom layer. Extremely subtle radial blobs on the dark base,
/// behind every panel.
///
/// For Dark Midnight the blobs use cool blue-gray washes, not warm or aquatic.
class AmbientBackground extends StatelessWidget {
  final double intensity;

  const AmbientBackground({super.key, this.intensity = 0.55});

  @override
  Widget build(BuildContext context) {
    final coolAlpha   = (0.07 * intensity).clamp(0.0, 1.0);
    final frostAlpha  = (0.05 * intensity).clamp(0.0, 1.0);
    final depthAlpha  = (0.09 * intensity).clamp(0.0, 1.0);

    return IgnorePointer(
      child: Container(
        color: DuckColors.bgBase,
        child: Stack(
          children: [
            // Cool blue-gray top-left vignette.
            Positioned(
              top: -260,
              left: -220,
              child: _Blob(
                size: 720,
                color: const Color(0xFF1E2127).withValues(alpha: coolAlpha),
              ),
            ),
            // Faint frost accent on the right edge.
            Positioned(
              top: 170,
              right: -150,
              child: _Blob(
                size: 380,
                color: const Color(0xFF81A1C1).withValues(alpha: frostAlpha),
              ),
            ),
            // Dark depth lower-left.
            Positioned(
              bottom: -190,
              left: -150,
              child: _Blob(
                size: 520,
                color: const Color(0xFF14171D).withValues(alpha: depthAlpha),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  const _Blob({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color, color.withValues(alpha: 0), Colors.transparent],
          stops: const [0.0, 0.6, 1.0],
        ),
      ),
    );
  }
}
