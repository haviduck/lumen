import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Full-screen image viewer used by the chat panel for any inline
/// image (snapshot bubble screenshots, pasted images, file-picked
/// attachments). Pinch / scroll-wheel zoom via [InteractiveViewer],
/// click-outside-to-dismiss, ESC-to-dismiss.
///
/// **Why a custom dialog instead of `package:photo_view`:** we already
/// have `InteractiveViewer` from Flutter SDK and the chat doesn't
/// need swipe-between-images, gallery indicators, or custom hero
/// transitions. Pulling in a 200KB package for one screen of pan/zoom
/// is overkill.
///
/// **Decode strategy:** image bytes are decoded once on entry from the
/// supplied base64 and held as a `Uint8List` in state. `Image.memory`
/// is then passed those bytes — Flutter caches the decoded ui.Image
/// in the central image cache keyed by hash, so re-opening the same
/// snapshot is instant.
class ImageLightbox extends StatefulWidget {
  /// Base64-encoded PNG/JPEG bytes (no data: prefix).
  final String base64Image;

  /// Optional caption shown in the top-left chrome (e.g. the URL the
  /// snapshot was taken of). Hidden when null/empty.
  final String? caption;

  const ImageLightbox({super.key, required this.base64Image, this.caption});

  /// Show the lightbox over the current navigator. Returns when the
  /// user dismisses (no result).
  static Future<void> show(
    BuildContext context, {
    required String base64Image,
    String? caption,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierDismissible: true,
        barrierColor: Colors.black.withValues(alpha: 0.78),
        barrierLabel: S.imageLightboxCloseTooltip,
        pageBuilder: (_, __, ___) =>
            ImageLightbox(base64Image: base64Image, caption: caption),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 140),
      ),
    );
  }

  @override
  State<ImageLightbox> createState() => _ImageLightboxState();
}

class _ImageLightboxState extends State<ImageLightbox> {
  final TransformationController _xform = TransformationController();
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    // Grab keyboard focus so ESC dismisses without a click first.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _xform.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _resetZoom() {
    _xform.value = Matrix4.identity();
  }

  void _close() {
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
      _close();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(widget.base64Image);
    } catch (_) {
      bytes = null;
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _close,
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: GestureDetector(
                  onTap: () {/* swallow taps on the image itself */},
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.92,
                      maxHeight: MediaQuery.of(context).size.height * 0.86,
                    ),
                    child: bytes == null
                        ? const Icon(
                            Icons.broken_image_outlined,
                            size: 64,
                            color: DuckColors.fgMuted,
                          )
                        : InteractiveViewer(
                            transformationController: _xform,
                            minScale: 0.8,
                            maxScale: 6,
                            child: Image.memory(
                              bytes,
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.medium,
                            ),
                          ),
                  ),
                ),
              ),
            ),
            if (widget.caption != null && widget.caption!.isNotEmpty)
              Positioned(
                left: 16,
                top: 16,
                child: _LightboxChip(child: Text(
                  widget.caption!,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                )),
              ),
            Positioned(
              right: 16,
              top: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _LightboxIconButton(
                    icon: Icons.zoom_out_map,
                    tooltip: S.imageLightboxResetTooltip,
                    onTap: _resetZoom,
                  ),
                  const SizedBox(width: 6),
                  _LightboxIconButton(
                    icon: Icons.close,
                    tooltip: S.imageLightboxCloseTooltip,
                    onTap: _close,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LightboxChip extends StatelessWidget {
  final Widget child;
  const _LightboxChip({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: child,
    );
  }
}

class _LightboxIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _LightboxIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: DuckColors.border, width: 0.5),
            ),
            child: Icon(icon, size: 16, color: DuckColors.fgPrimary),
          ),
        ),
      ),
    );
  }
}
