import 'package:flutter/material.dart';

import '../../services/chat_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Visual pill rendering of a [ChatChip] used by the composer's
/// chip strip and (potentially) by message bubbles after send.
///
/// History: an earlier sketch tried to render chips as `WidgetSpan`s
/// inline with a `\uFFFC` placeholder in the controller's `text`.
/// The council pool falsified that across seven agents
/// (flutter#30688, IME composing-range corruption, Nerd Font paste
/// collisions). The composite-widget approach renders chips as
/// first-class siblings of the `TextField` — the controller's text
/// stays plain, and chip metadata lives in a parallel list.
class ChatChipPill extends StatelessWidget {
  final ChatChip chip;
  final VoidCallback onRemove;

  /// Compact mode is used inside the composer's chip strip where
  /// vertical density matters; non-compact is for message-bubble
  /// re-renders.
  final bool compact;

  const ChatChipPill({
    super.key,
    required this.chip,
    required this.onRemove,
    this.compact = true,
  });

  IconData get _icon {
    switch (chip.kind) {
      case ChatChipKind.file:
        return Icons.description_outlined;
      case ChatChipKind.folder:
        return Icons.folder_outlined;
      case ChatChipKind.codeRange:
        return Icons.code;
      case ChatChipKind.terminalSelection:
        return Icons.terminal;
      case ChatChipKind.doc:
        return Icons.article_outlined;
    }
  }

  Color get _accent {
    switch (chip.kind) {
      case ChatChipKind.folder:
        return DuckColors.accentDuck;
      case ChatChipKind.terminalSelection:
        return DuckColors.accentMint;
      case ChatChipKind.codeRange:
        return DuckColors.accentCyan;
      default:
        return DuckColors.accentCyan;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tooltipMsg =
        chip.snippet ?? (chip.path.isNotEmpty ? chip.path : chip.label);
    final fontSize = compact ? 11.0 : 12.0;
    final iconSize = compact ? 11.0 : 12.0;
    return Tooltip(
      message: tooltipMsg,
      waitDuration: const Duration(milliseconds: 400),
      child: Container(
        padding: EdgeInsets.only(
          left: compact ? 6 : 8,
          right: 2,
          top: compact ? 1 : 2,
          bottom: compact ? 1 : 2,
        ),
        decoration: BoxDecoration(
          color: DuckColors.bgChip,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: Border.all(
            color: _accent.withValues(alpha: 0.6),
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_icon, size: iconSize, color: _accent),
            const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 220),
              child: Text(
                chip.label,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: TextStyle(
                  fontSize: fontSize,
                  color: DuckColors.fgPrimary,
                  height: 1.1,
                ),
              ),
            ),
            const SizedBox(width: 2),
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(
                  Icons.close,
                  size: 10,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
