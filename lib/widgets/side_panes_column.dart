import 'package:flutter/material.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../providers/media_controller.dart';
import '../providers/ssh_controller.dart';
import '../theme/app_colors.dart';
import 'common/media_pane_chrome.dart';
import 'ssh/remote_pane.dart';

/// Vertical stack hosting SSH ("Remote"), Teams, and watch-media as a
/// single side pane mounted to the RIGHT of the code editor (above
/// the terminal). Sits inside the editor's horizontal split — see
/// `widgets/editor/editor.dart::_EditorState.build`.
///
/// Architectural history (read before refactoring):
///
/// - **v1.0–v1.3:** SSH / Teams shared the editor's right slot, but
///   only one could mount at a time (right-slot was a single Area).
/// - **v1.4:** Lifted out into a full-height side column at the IDE
///   root layout level so SSH / Teams / Watch could coexist as a
///   vertical stack. Trade-off: the editor lost its full height
///   whenever ANY pane was open, and the column read as a separate
///   skinny strip detached from the workbench.
/// - **v1.5 (current):** Lifted back DOWN into the editor area, this
///   time as a real vertical-stack widget rather than a single-Area
///   right slot. SSH / Teams stack on top of each other; the
///   terminal still spans the full workbench width below. Watch
///   media's "side" placement also lives here, BUT only when nothing
///   else is occupying the slot — when SSH or Teams is active, watch
///   is forced into the chat panel via [watchForcedToChat] (the
///   user's explicit ask: "YouTube alongside SSH/Teams is too much").
///
/// Visibility — this widget assumes its parent has already gated on
/// `shouldMount(...)` returning true; it does NOT short-circuit to
/// `SizedBox.shrink()` itself because the parent's
/// `MultiSplitViewController` decides whether to allocate an Area at
/// all, and `multi_split_view` 3.6.1's `initialAreas` is consumed
/// once. See `editor.dart::_buildIdeBody` — it remounts the
/// horizontal split (via a ValueKey on the active-pane signature)
/// whenever the visible-pane set changes.
class SidePanesColumn extends StatelessWidget {
  const SidePanesColumn({super.key});

  /// True when watch-media's "side" placement is currently being
  /// overridden because something more important (SSH or Teams) is
  /// already living in the side stack.
  ///
  /// Consumers:
  /// - [SidePanesColumn] itself excludes watch when this is true.
  /// - `ai_chat.dart` renders watch in the chat panel when this is
  ///   true (regardless of `media.placement`).
  /// - `media_url_prompt.dart` disables the editor-placement chip
  ///   and shows a hint when this is true.
  ///
  /// Intentional non-symmetry: SSH and Teams DON'T have a similar
  /// "forced-to-chat" rule because they're not chat-mountable — they
  /// only ever live in the side stack. Watch is the only multi-home
  /// surface, hence the special-case.
  static bool watchForcedToChat({
    required SshController ssh,
    required MediaController media,
  }) {
    return ssh.hasSessions || media.hasTeams;
  }

  /// Pure helper — true when the side pane has at least one body to
  /// render. Used by `editor.dart` to decide whether to add the
  /// right-slot Area to the editor's horizontal split. Centralised
  /// here so every callsite agrees on what counts as "live".
  ///
  /// Watch-media counts ONLY when `placement == editor` AND nothing
  /// is forcing it to chat. This way the user's "side" preference is
  /// preserved when SSH/Teams aren't around, but yields gracefully
  /// when they are.
  static bool shouldMount({
    required SshController ssh,
    required MediaController media,
  }) {
    final showSsh = ssh.hasSessions;
    final showTeams = media.hasTeams;
    final showWatch = media.hasMedia &&
        media.placement == MediaPlacement.editor &&
        !watchForcedToChat(ssh: ssh, media: media);
    return showSsh || showTeams || showWatch;
  }

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    final media = context.watch<MediaController>();

    final showSsh = ssh.hasSessions;
    final showTeams = media.hasTeams;
    // Watch is suppressed in the side stack whenever SSH/Teams are
    // also active — see [watchForcedToChat] for the rationale. This
    // is the only enforcement point for that rule on the side-stack
    // side; the chat-panel side reads the same helper to decide
    // whether to mount its own watch view.
    final showWatch = media.hasMedia &&
        media.placement == MediaPlacement.editor &&
        !watchForcedToChat(ssh: ssh, media: media);

    // Same multi_split_view 3.6.1 landmine as editor.dart's outer
    // horizontal split: `initialAreas` is consumed once at mount,
    // so when the active-pane count changes we MUST remount the
    // inner split. The ValueKey, derived from the active-pane
    // signature, forces a fresh State and therefore a fresh
    // controller.
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
      // mount/unmount churn of an inner MultiSplitView when only
      // one surface is live. Keeps the very common "just SSH"
      // case zero-overhead.
      if (showSsh) return const _RemoteSlot();
      if (showTeams) return _MediaSlotPane(media: media, slot: MediaSlot.teams);
      return _MediaSlotPane(media: media, slot: MediaSlot.watch);
    }

    final flex = 1.0 / activeKeys.length;
    // Note: `multi_split_view` 3.6.1's `Area` has `min:` only when
    // a concrete `size:` is set — flex-sized areas can't be
    // floored. The 80px tall pane that you'd otherwise want as a
    // safety floor is enforced visually by the chrome strip
    // inside each pane (RemotePane / MediaPaneChrome are at least
    // ~26px each), so collapsing past usefulness still shows you
    // which pane you're shrinking.
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
/// Lifted verbatim from the v1.0–v1.3 `_EditorMediaPane` private
/// class in `editor.dart` — the editor no longer mounts media
/// itself, so this widget is now the only consumer of
/// `MediaController.webviewFor(slot)` from the side-stack side.
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
