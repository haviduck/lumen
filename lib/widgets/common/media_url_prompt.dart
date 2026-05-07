import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/media_controller.dart';
import '../../providers/ssh_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../side_panes_column.dart';
import 'duck_glass.dart';

/// Unified media hub prompt — controls both watch-media URLs and Teams.
///
/// Wired through `MediaController.play(url)` directly (the previous
/// `ChatController.requestMediaUrl` queueing pattern was deleted —
/// it existed because `_AiChatState` owned the webview, which it
/// no longer does).
Future<void> showMediaUrlPrompt(
  BuildContext context, {
  MediaPromptMode initialMode = MediaPromptMode.watch,
}) async {
  final media = context.read<MediaController>();
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => _MediaUrlDialog(
      initialWatchUrl: media.url ?? '',
      initialTeamsUrl: media.teamsUrl ?? 'teams.cloud.microsoft',
      initialMode: initialMode,
    ),
  );
}

enum MediaPromptMode { watch, teams }

class _MediaUrlDialog extends StatefulWidget {
  final String initialWatchUrl;
  final String initialTeamsUrl;
  final MediaPromptMode initialMode;
  const _MediaUrlDialog({
    required this.initialWatchUrl,
    required this.initialTeamsUrl,
    required this.initialMode,
  });

  @override
  State<_MediaUrlDialog> createState() => _MediaUrlDialogState();
}

class _MediaUrlDialogState extends State<_MediaUrlDialog> {
  late final TextEditingController _watchCtrl;
  late final TextEditingController _teamsCtrl;
  late final FocusNode _watchFocus;
  late final FocusNode _teamsFocus;
  late MediaPromptMode _mode;

  bool get _isWatchMode => _mode == MediaPromptMode.watch;

  @override
  void initState() {
    super.initState();
    _watchCtrl = TextEditingController(text: widget.initialWatchUrl);
    _teamsCtrl = TextEditingController(text: widget.initialTeamsUrl);
    _watchFocus = FocusNode();
    _teamsFocus = FocusNode();
    _mode = widget.initialMode;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_isWatchMode ? _watchFocus : _teamsFocus).requestFocus();
    });
  }

  @override
  void dispose() {
    _watchCtrl.dispose();
    _teamsCtrl.dispose();
    _watchFocus.dispose();
    _teamsFocus.dispose();
    super.dispose();
  }

  void _setMode(MediaPromptMode next) {
    if (_mode == next) return;
    setState(() => _mode = next);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_isWatchMode ? _watchFocus : _teamsFocus).requestFocus();
    });
  }

  Future<void> _submitWatch() async {
    final url = _watchCtrl.text.trim();
    if (url.isEmpty) return;
    final media = context.read<MediaController>();
    Navigator.of(context).pop();
    await media.play(url);
  }

  Future<void> _submitTeams() async {
    final media = context.read<MediaController>();
    Navigator.of(context).pop();
    await media.playTeams(_teamsCtrl.text.trim());
  }

  Future<void> _submitActive() async {
    if (_isWatchMode) {
      await _submitWatch();
      return;
    }
    await _submitTeams();
  }

  @override
  Widget build(BuildContext context) {
    final accent = _isWatchMode
        ? DuckColors.accentCyan
        : DuckColors.accentPurple;
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 520,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.video_settings_outlined,
                    size: 18,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    S.mediaHubTitle,
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
              const SizedBox(height: 4),
              const Text(
                S.mediaHubSubtitle,
                style: TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgSubtle,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                S.mediaHubSourceLabel,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  color: DuckColors.fgMuted,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _ModeChip(
                      selected: _isWatchMode,
                      icon: Icons.smart_display_outlined,
                      label: S.mediaHubWatchTab,
                      onTap: () => _setMode(MediaPromptMode.watch),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ModeChip(
                      selected: !_isWatchMode,
                      icon: Icons.groups_outlined,
                      label: S.mediaHubTeamsTab,
                      onTap: () => _setMode(MediaPromptMode.teams),
                      accent: DuckColors.accentPurple,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              _UrlField(
                controller: _isWatchMode ? _watchCtrl : _teamsCtrl,
                focus: _isWatchMode ? _watchFocus : _teamsFocus,
                hintText: _isWatchMode
                    ? S.chatEnterMediaHint
                    : S.mediaHubTeamsHint,
                leadingIcon: _isWatchMode
                    ? Icons.link_rounded
                    : Icons.language_rounded,
                onSubmit: _submitActive,
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: DuckColors.bgChip.withValues(alpha: 0.7),
                  border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.auto_fix_high_rounded,
                      size: 13,
                      color: DuckColors.fgSubtle,
                    ),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        S.mediaHubAutoSchemeHint,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: DuckColors.fgMuted,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (_isWatchMode) ...[
                const SizedBox(height: 14),
                Consumer2<MediaController, SshController>(
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
              ],
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
                    icon: Icon(
                      _isWatchMode
                          ? Icons.play_arrow_rounded
                          : Icons.groups_rounded,
                      size: 18,
                    ),
                    label: Text(
                      _isWatchMode ? S.chatPlay : S.mediaHubOpenTeams,
                    ),
                    onPressed: _submitActive,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: accent,
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

class _ModeChip extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color accent;
  const _ModeChip({
    required this.selected,
    required this.icon,
    required this.label,
    required this.onTap,
    this.accent = DuckColors.accentCyan,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        curve: DuckMotion.standard,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: selected
              ? accent.withValues(alpha: 0.12)
              : DuckColors.bgChip.withValues(alpha: 0.55),
          border: Border.all(
            color: selected ? accent : DuckColors.glassSeam,
            width: selected ? 1 : 0.5,
          ),
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: selected ? accent : DuckColors.fgMuted),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: selected ? DuckColors.fgPrimary : DuckColors.fgMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _UrlField extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focus;
  final String hintText;
  final IconData leadingIcon;
  final VoidCallback onSubmit;
  const _UrlField({
    required this.controller,
    required this.focus,
    required this.hintText,
    required this.leadingIcon,
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
          Icon(widget.leadingIcon, size: 15, color: DuckColors.fgSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: widget.controller,
              focusNode: widget.focus,
              style: const TextStyle(fontSize: 13, color: DuckColors.fgPrimary),
              decoration: InputDecoration(
                hintText: widget.hintText,
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
          Icon(Icons.info_outline, size: 13, color: DuckColors.fgSubtle),
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
