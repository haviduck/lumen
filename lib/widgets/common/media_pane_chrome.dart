import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/media_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Shared chrome strip for the watch-media panels.
///
/// Used in two places:
/// - The chat panel's `_buildChatMediaPanel` (chat placement).
/// - The editor area's `_EditorMediaPane` (editor split placement).
///
/// Renders the title row + control cluster: mute toggle, zoom
/// (only when the current URL isn't aspect-locked — YouTube /
/// Twitch own their own scale), open-in-browser, close. Tweaks
/// here propagate to both panels.
class MediaPaneChrome extends StatelessWidget {
  final MediaController media;
  final MediaSlot slot;

  /// Container height. Editor pane uses 26 (slightly bigger);
  /// chat pane historically used 24 — both work, but kept as a
  /// per-callsite knob.
  final double height;

  const MediaPaneChrome({
    super.key,
    required this.media,
    this.slot = MediaSlot.watch,
    this.height = 26,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      color: DuckColors.bgDeeper,
      child: Row(
        children: [
          const SizedBox(width: 10),
          const Icon(
            Icons.ondemand_video,
            size: 12,
            color: DuckColors.fgSubtle,
          ),
          const SizedBox(width: 8),
          // Adapts to the loaded URL: "TEAMS" / "YOUTUBE" /
          // "TWITCH" / "MEDIA PLAYER". Driven by
          // `MediaController.displayLabel`. Changing what counts as
          // a recognised host is a one-line tweak there.
          Text(media.displayLabelFor(slot), style: DuckTheme.titleS),
          const Spacer(),
          // Mute toggle — applies to every <video>/<audio> on the
          // current page via a `MediaController.toggleMute`
          // executeScript injection. Re-applied on every nav.
          IconButton(
            icon: Icon(
              media.muted ? Icons.volume_off : Icons.volume_up,
              size: 13,
            ),
            color: media.muted ? DuckColors.accentDuck : null,
            tooltip: media.muted ? S.mediaUnmute : S.mediaMute,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            onPressed: slot == MediaSlot.teams
                ? null
                : () => media.toggleMuteFor(slot),
          ),
          // Zoom +/- — only for free-form pages. Hidden for
          // YouTube / Twitch since the embed owns its own scale.
          if (!media.isAspectLockedFor(slot)) ...[
            IconButton(
              icon: const Icon(Icons.zoom_out, size: 13),
              tooltip: S.mediaZoomOut,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              onPressed: () => media.zoomOutFor(slot),
            ),
            IconButton(
              icon: const Icon(Icons.zoom_in, size: 13),
              tooltip: S.mediaZoomIn,
              padding: const EdgeInsets.all(4),
              constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
              onPressed: () => media.zoomInFor(slot),
            ),
          ],
          IconButton(
            icon: const Icon(Icons.open_in_new, size: 13),
            tooltip: S.chatOpenInBrowser,
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            onPressed: () => media.openInBrowserFor(slot),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 13),
            padding: const EdgeInsets.all(4),
            constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
            onPressed: () => media.closeFor(slot),
          ),
        ],
      ),
    );
  }
}
