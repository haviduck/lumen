import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

OverlayEntry? _activeToast;
Timer? _toastTimer;

void showDuckToast(BuildContext context, String message) {
  final overlay = Overlay.maybeOf(context);
  if (overlay == null) return;

  _toastTimer?.cancel();
  _activeToast?.remove();

  final entry = OverlayEntry(
    builder: (context) {
      return Positioned(
        left: 14,
        bottom: 34,
        width: 340,
        child: IgnorePointer(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            builder: (context, value, child) {
              return Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - value)),
                  child: child,
                ),
              );
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(DuckTheme.radiusM),
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: DuckColors.bgGlassHi,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                    border: Border.all(
                      color: DuckColors.glassEdgeHi,
                      width: 0.5,
                    ),
                    boxShadow: DuckTheme.shadowSoft,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 9,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.info_outline,
                          size: 14,
                          color: DuckColors.accentCyan,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            message,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: DuckColors.fgPrimary,
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              height: 1.35,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );

  _activeToast = entry;
  overlay.insert(entry);
  _toastTimer = Timer(const Duration(milliseconds: 2600), () {
    if (_activeToast == entry) {
      _activeToast = null;
    }
    entry.remove();
  });
}
