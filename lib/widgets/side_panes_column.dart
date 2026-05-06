import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../providers/media_controller.dart';
import '../providers/ssh_controller.dart';
import '../theme/app_colors.dart';
import 'common/media_pane_chrome.dart';
import 'ssh/remote_pane.dart';

/// Full-height side column hosting SSH, Teams, and watch-media
/// (YouTube/Twitch/etc.) as a vertical stack. Sits to the LEFT of
/// the AI chat sidebar and to the RIGHT of the (Editor + Terminal)
/// column at the IDE root layout level.
///
/// Architectural note — the v1.0 SSH/Teams split was nested INSIDE
/// the editor pane, which made the editor cramped whenever any
/// remote surface was open. v1.4 lifts the column to a sibling of
/// the editor stack so the editor keeps full height regardless of
/// how many side panes the user has live. See
/// `lib/main.dart::_LayoutForMode` for the wiring.
///
/// Ordering: SSH (top), Teams (middle), Watch-media (bottom). This
/// matches the screenshot the user provided when designing the
/// layout, and roughly groups by "interactive" → "passive": SSH is
/// most-used, Teams holds focus when in a meeting, and watch-media
/// is ambient. If we expose the order as a user preference later,
/// this widget is the one place to thread it through.
///
/// Visibility — this widget assumes its parent has already gated on
/// `shouldMount(...)` returning true; it does NOT short-circuit to
/// `SizedBox.shrink()` itself because the parent's
/// `MultiSplitViewController` decides whether to allocate an Area at
/// all (and `multi_split_view` 3.6.1's `initialAreas` is consumed
/// once). See `_LayoutForMode._rebuildControllers` — it rebuilds
/// the root controller whenever `showSidePanes` flips.
class SidePanesColumn extends StatelessWidget {
  const SidePanesColumn({super.key});

  /// Pure helper — true when the column has at least one active
  /// pane to render. Used by `_IdeShell` to decide whether to ask
  /// `_LayoutForMode` for the Area at all. Centralised here so
  /// every callsite agrees on what counts as "live".
  ///
  /// Note: this intentionally checks `MediaPlacement.editor` for
  /// watch-media — the user explicitly chose to dock it here. When
  /// placement is `chat`, watch-media renders in the AI chat panel
  /// instead and the side column doesn't claim space for it.
  static bool shouldMount({
    required SshController ssh,
    required MediaController media,
  }) {
    final showSsh = ssh.hasSessions;
    final showTeams = media.hasTeams;
    final showWatch =
        media.hasMedia && media.placement == MediaPlacement.editor;
    return showSsh || showTeams || showWatch;
  }

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    final media = context.watch<MediaController>();

    final showSsh = ssh.hasSessions;
    final showTeams = media.hasTeams;
    final showWatch =
        media.hasMedia && media.placement == MediaPlacement.editor;

    // Same multi_split_view 3.6.1 landmine as editor.dart's
    // _buildRightSlot: `initialAreas` is consumed once at mount,
    // so when the active-pane count changes (e.g. user opens
    // Teams while SSH is already up) we MUST remount the inner
    // split. The ValueKey, derived from the active-pane signature,
    // forces a fresh State and therefore a fresh controller.
    final activeKeys = <String>[
      if (showSsh) 'ssh',
      if (showTeams) 'teams',
      if (showWatch) 'watch',
    ];

    if (activeKeys.isEmpty) {
      // Defensive: parent gates on `shouldMount`, so we should
      // never reach here. If we DO (e.g. during a frame where the
      // controllers are between transitions), render an empty
      // sliver so we don't crash the split view.
      return const SizedBox.shrink();
    }

    if (activeKeys.length == 1) {
      // Single-pane shortcut — avoids the divider chrome and the
      // mount/unmount churn of an inner MultiSplitView when the
      // user only has one surface live. Keeps the very common
      // "just SSH" case zero-overhead.
      if (showSsh) return const _RemoteSlot();
      if (showTeams) return _MediaSlotPane(media: media, slot: MediaSlot.teams);
      return _MediaSlotPane(media: media, slot: MediaSlot.watch);
    }

    final flex = 1.0 / activeKeys.length;
    // Note: `multi_split_view` 3.6.1's `Area` has `min:` only when
    // a concrete `size:` is set — flex-sized areas can't be
    // floored. The 80px tall pane that you'd otherwise want as a
    // safety floor is enforced visually by the chrome strip
    // inside each pane (RemotePane / MediaPaneChrome are at
    // least ~26px each), so collapsing past usefulness still
    // shows you which pane you're shrinking.
    final areas = <Area>[
      if (showSsh)
        Area(flex: flex, builder: (_, _) => const _RemoteSlot()),
      if (showTeams)
        Area(
          flex: flex,
          builder: (_, _) =>
              _MediaSlotPane(media: media, slot: MediaSlot.teams),
        ),
      if (showWatch)
        Area(
          flex: flex,
          builder: (_, _) =>
              _MediaSlotPane(media: media, slot: MediaSlot.watch),
        ),
    ];

    return MultiSplitView(
      key: ValueKey('side-panes:${activeKeys.join('|')}'),
      axis: Axis.vertical,
      initialAreas: areas,
    );
  }
}

/// Thin wrapper around `RemotePane` so the Area builder is a
/// stable reference (method tear-offs / `const` widgets don't
/// re-allocate on every parent rebuild — the multi_split_view
/// landmine again).
class _RemoteSlot extends StatelessWidget {
  const _RemoteSlot();

  @override
  Widget build(BuildContext context) => const RemotePane();
}

/// Renders a single Webview-backed media pane (Teams or watch).
///
/// Lifted verbatim from the old `_EditorMediaPane` private class
/// in `editor.dart` — the editor no longer mounts media itself in
/// v1.4, so this widget is now the only consumer of
/// `MediaController.webviewFor(slot)` from the side-panes side.
/// The chat-placement variant continues to live in `ai_chat.dart`.
class _MediaSlotPane extends StatelessWidget {
  final MediaController media;
  final MediaSlot slot;
  const _MediaSlotPane({required this.media, required this.slot});

  @override
  Widget build(BuildContext context) {
    final permissionRequested = slot == MediaSlot.teams
        ? MediaController.handleTeamsPermission
        : null;
    final body = media.isAspectLockedFor(slot)
        ? Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Webview(
                media.webviewFor(slot),
                permissionRequested: permissionRequested,
              ),
            ),
          )
        : Webview(
            media.webviewFor(slot),
            permissionRequested: permissionRequested,
          );
    return Container(
      color: DuckColors.bgDeepest,
      child: Column(
        children: [
          MediaPaneChrome(media: media, slot: slot),
          Expanded(child: body),
        ],
      ),
    );
  }
}
