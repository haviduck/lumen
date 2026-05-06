import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/media_controller.dart';
import '../../providers/ssh_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../side_panes_column.dart';
import 'duck_glass.dart';

/// Watch-media prompt — pretty glass dialog with URL field +
/// placement chips + play button. Replaces the old plain
/// `AlertDialog` from the menu bar / explorer activity bar.
///
/// Wired through `MediaController.play(url)` directly (the previous
/// `ChatController.requestMediaUrl` queueing pattern was deleted —
/// it existed because `_AiChatState` owned the webview, which it
/// no longer does).
Future<void> showMediaUrlPrompt(BuildContext context) async {
  final media = context.read<MediaController>();
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => _MediaUrlDialog(initialUrl: media.url ?? ''),
  );
}

class _MediaUrlDialog extends StatefulWidget {
  final String initialUrl;
  const _MediaUrlDialog({required this.initialUrl});

  @override
  State<_MediaUrlDialog> createState() => _MediaUrlDialogState();
}

class _MediaUrlDialogState extends State<_MediaUrlDialog> {
  late final TextEditingController _ctrl;
  late final FocusNode _focus;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: widget.initialUrl);
    _focus = FocusNode()..requestFocus();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    final media = context.read<MediaController>();
    // v1.4: previously forced placement to chat when Teams was
    // active because the editor right-slot could only host one
    // webview. The new `SidePanesColumn` stacks SSH / Teams /
    // Watch vertically with no exclusivity, so we leave the user's
    // chosen placement alone here.
    Navigator.of(context).pop();
    await media.play(url);
  }

  @override
  Widget build(BuildContext context) {
    // Match the working pattern from `settings_dialog` /
    // `backup_dialog`:
    // - Dialog: `shape: const RoundedRectangleBorder()` so the
    //   default rounded shape doesn't double-clip the BackdropFilter
    //   inside `DuckGlass.hero`.
    // - DuckGlass.hero with `borderColor: borderStrong` (not the
    //   default luminous glass edge — better for dialog-class
    //   surfaces).
    // - Inner Container with **explicit width**: an earlier
    //   iteration used `ConstrainedBox(maxWidth: 480)` which (a)
    //   under-constrained the Column (only set a max) and (b)
    //   tripped the Windows backdrop-filter blank-rectangle quirk
    //   that the knowledgebase flags for the welcome / lock screens.
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 480,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Header row — leading icon + title + close button.
              Row(
                children: [
                  const Icon(
                    Icons.ondemand_video_outlined,
                    size: 18,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    S.chatWatchMedia,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () => Navigator.of(context).pop(),
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(
                        Icons.close,
                        size: 14,
                        color: DuckColors.fgSubtle,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // URL input — pill-shaped chip surface with cyan focus.
              _UrlField(controller: _ctrl, focus: _focus, onSubmit: _submit),
              const SizedBox(height: 14),
              Consumer2<MediaController, SshController>(
                // v1.5: when SSH or Teams is currently using the
                // editor side stack, the user's "side" placement
                // for watch-media gets overridden to chat (see
                // `SidePanesColumn.watchForcedToChat`). The chip
                // chooser still surfaces both options so the
                // user's persisted preference is visible — we
                // just add an inline notice explaining that the
                // editor-placement option will defer to chat
                // until SSH/Teams steps aside. Without this
                // notice the user would set "side" and watch the
                // video appear in chat, with no clue why.
                builder: (context, media, ssh, _) {
                  final forced = SidePanesColumn.watchForcedToChat(
                    ssh: ssh,
                    media: media,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        S.mediaPlacementLabel,
                        style: TextStyle(
                          fontSize: 11,
                          letterSpacing: 0.6,
                          color: DuckColors.fgMuted,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 8),
                      const _PlacementChips(),
                      if (forced) ...[
                        const SizedBox(height: 8),
                        const _ForcedToChatNotice(),
                      ],
                    ],
                  );
                },
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: DuckColors.fgMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: const Text(S.cancel),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.play_arrow_rounded, size: 18),
                    label: const Text(S.chatPlay),
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DuckColors.accentCyan,
                      foregroundColor: DuckColors.bgDeepest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UrlField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final VoidCallback onSubmit;
  const _UrlField({
    required this.controller,
    required this.focus,
    required this.onSubmit,
  });

  @override
  State<_UrlField> createState() => _UrlFieldState();
}

class _UrlFieldState extends State<_UrlField> {
  @override
  void initState() {
    super.initState();
    widget.focus.addListener(_onFocusChange);
  }

  @override
  void dispose() {
    widget.focus.removeListener(_onFocusChange);
    super.dispose();
  }

  void _onFocusChange() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final focused = widget.focus.hasFocus;
    return AnimatedContainer(
      duration: DuckMotion.fast,
      curve: DuckMotion.standard,
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: focused ? DuckColors.accentCyan : DuckColors.glassSeam,
          width: focused ? 1 : 0.5,
        ),
        boxShadow: focused ? DuckTheme.shadowGlow : null,
      ),
      child: Row(
        children: [
          const SizedBox(width: 12),
          const Icon(Icons.link_rounded, size: 15, color: DuckColors.fgSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focus,
              style: const TextStyle(fontSize: 13, color: DuckColors.fgPrimary),
              decoration: const InputDecoration(
                hintText: S.chatEnterMediaHint,
                hintStyle: TextStyle(fontSize: 13, color: DuckColors.fgFaint),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                fillColor: Colors.transparent,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 12),
              ),
              onSubmitted: (_) => widget.onSubmit(),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _PlacementChips extends StatelessWidget {
  const _PlacementChips();

  @override
  Widget build(BuildContext context) {
    return Consumer<MediaController>(
      builder: (context, media, _) => Row(
        children: [
          _PlacementChip(
            icon: Icons.chat_bubble_outline,
            label: S.mediaPlacementChat,
            description: S.mediaPlacementChatDesc,
            selected: media.placement == MediaPlacement.chat,
            onTap: () => media.setPlacement(MediaPlacement.chat),
          ),
          const SizedBox(width: 8),
          _PlacementChip(
            icon: Icons.vertical_split_rounded,
            label: S.mediaPlacementEditor,
            description: S.mediaPlacementEditorDesc,
            selected: media.placement == MediaPlacement.editor,
            onTap: () => media.setPlacement(MediaPlacement.editor),
          ),
        ],
      ),
    );
  }
}

class _PlacementChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;
  const _PlacementChip({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  State<_PlacementChip> createState() => _PlacementChipState();
}

class _PlacementChipState extends State<_PlacementChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final borderColor = selected
        ? DuckColors.accentCyan
        : (_hover ? DuckColors.borderStrong : DuckColors.glassSeam);
    final bgColor = selected
        ? DuckColors.accentCyan.withValues(alpha: 0.10)
        : (_hover
              ? DuckColors.bgRaisedHi.withValues(alpha: 0.4)
              : DuckColors.bgChip);
    return Expanded(
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 11),
            decoration: BoxDecoration(
              color: bgColor,
              border: Border.all(color: borderColor, width: selected ? 1 : 0.5),
              borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      widget.icon,
                      size: 14,
                      color: selected
                          ? DuckColors.accentCyan
                          : DuckColors.fgMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: selected
                            ? DuckColors.fgPrimary
                            : DuckColors.fgMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  widget.description,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline notice rendered under the placement chips when SSH or
/// Teams is currently occupying the editor's side stack — in that
/// case the user's "side" placement gets overridden to chat (see
/// `SidePanesColumn.watchForcedToChat`). Surfacing the override
/// keeps the dialog honest: the chip stays selectable so the
/// preference can be set, but the user knows the video will land
/// in chat right now.
class _ForcedToChatNotice extends StatelessWidget {
  const _ForcedToChatNotice();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: const Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 13,
            color: DuckColors.fgSubtle,
          ),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              S.mediaTeamsForcesChat,
              style: TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgMuted,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
