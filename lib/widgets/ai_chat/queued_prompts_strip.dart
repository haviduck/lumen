import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Above-input strip listing prompts the user composed while a
/// generation was in flight.
///
/// Each entry exposes:
///   - the original prompt text (truncated to two lines),
///   - a "Send now" button that cancels the in-flight turn and runs
///     this prompt next (skipping any earlier queue entries),
///   - a delete button that drops the entry without running it.
///
/// Drains automatically through `ChatController._drainPromptQueue`
/// when the current turn finishes; this widget doesn't trigger the
/// drain itself, just renders + relays user actions.
///
/// Hidden when the queue is empty so the chat layout doesn't gain
/// an empty band of chrome on a quiet panel.
class QueuedPromptsStrip extends StatelessWidget {
  final ChatController controller;
  const QueuedPromptsStrip({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final queue = controller.queuedPrompts;
    if (queue.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
          left: BorderSide(color: DuckColors.accentDuck, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.schedule_outlined,
                size: 12,
                color: DuckColors.accentDuck,
              ),
              const SizedBox(width: 6),
              Text(
                '${S.chatQueuedHeader} (${queue.length})',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: DuckColors.fgPrimary,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  S.chatQueuedHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: DuckColors.fgFaint,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final entry in queue)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _QueuedPromptRow(
                key: ValueKey(entry.id),
                prompt: entry,
                onRemove: () => controller.removeQueuedPrompt(entry.id),
                onSendNow: () => controller.sendQueuedPromptNow(entry.id),
              ),
            ),
        ],
      ),
    );
  }
}

class _QueuedPromptRow extends StatefulWidget {
  final QueuedPrompt prompt;
  final VoidCallback onRemove;
  final VoidCallback onSendNow;
  const _QueuedPromptRow({
    super.key,
    required this.prompt,
    required this.onRemove,
    required this.onSendNow,
  });

  @override
  State<_QueuedPromptRow> createState() => _QueuedPromptRowState();
}

class _QueuedPromptRowState extends State<_QueuedPromptRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = widget.prompt;
    final hasImages = p.imagesBase64.isNotEmpty;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
        decoration: BoxDecoration(
          color: _hover ? DuckColors.bgRaisedHi : DuckColors.bgChip,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (hasImages) ...[
              const Icon(
                Icons.attach_file,
                size: 11,
                color: DuckColors.accentMint,
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(
                p.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgPrimary,
                  height: 1.35,
                ),
              ),
            ),
            const SizedBox(width: 6),
            _QueueAction(
              icon: Icons.flash_on_outlined,
              tooltip: S.chatQueuedSendNowTooltip,
              accent: DuckColors.accentCyan,
              onTap: widget.onSendNow,
              label: S.chatQueuedSendNow,
            ),
            const SizedBox(width: 4),
            _QueueAction(
              icon: Icons.close,
              tooltip: S.chatQueuedRemove,
              accent: DuckColors.fgMuted,
              onTap: widget.onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

class _QueueAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final String? label;
  final Color accent;
  final VoidCallback onTap;
  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.accent,
    required this.onTap,
    this.label,
  });

  @override
  State<_QueueAction> createState() => _QueueActionState();
}

class _QueueActionState extends State<_QueueAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            padding: EdgeInsets.symmetric(
              horizontal: widget.label == null ? 4 : 7,
              vertical: 3,
            ),
            decoration: BoxDecoration(
              color: _hover
                  ? widget.accent.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 12, color: widget.accent),
                if (widget.label != null) ...[
                  const SizedBox(width: 4),
                  Text(
                    widget.label!,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w600,
                      color: widget.accent,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
