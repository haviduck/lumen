import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Above-input strip listing prompts the user composed while a
/// generation was in flight.
///
/// Each entry exposes:
///   - the original prompt text (single line, ellipsized),
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
///
/// **Visual weight is intentionally low.** An earlier version of
/// this strip painted a distinct `bgDeeper` band with a 2px
/// accent-coloured left stripe, a bold caps-letter "Queued (N)"
/// header, a hint sentence, and per-entry chip cards (chip bg +
/// border + 2 lines of text + icon-and-label "Send now" CTA). It
/// drew the eye too aggressively for what is a passive informational
/// list — the queue should feel like a quiet pre-input list, not
/// a banner alert. The current layout sits inline above the input
/// with no panel chrome, dim single-line rows, and icon-only
/// actions that surface their verbose labels through tooltips.
class QueuedPromptsStrip extends StatelessWidget {
  final ChatController controller;
  const QueuedPromptsStrip({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    final queue = controller.queuedPrompts;
    if (queue.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final entry in queue)
            _QueuedPromptRow(
              key: ValueKey(entry.id),
              prompt: entry,
              onRemove: () => controller.removeQueuedPrompt(entry.id),
              onSendNow: () => controller.sendQueuedPromptNow(entry.id),
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
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          // No baseline background — the row reads as a passive
          // list entry on the existing chat surface. A very light
          // `bgRaisedHi` lift on hover signals interactivity
          // without making the row demand attention at rest.
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Tiny leading dot — pure visual rhythm marker so the
            // eye reads the strip as a list of items rather than
            // free-floating text. 4px circle in `fgFaint` sits on
            // the boundary of perceptible without contributing
            // chrome weight.
            Container(
              width: 4,
              height: 4,
              decoration: const BoxDecoration(
                color: DuckColors.fgFaint,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            // Mint paperclip glyph when the queued prompt carries
            // attached images — keeps the existing affordance from
            // the previous design without a chip card around it.
            // Same colour as the attachment strip so the visual
            // language is consistent across the input area.
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
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgMuted,
                  height: 1.3,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Icon-only actions — labels live in tooltips. The bolt
            // icon for "send now" carries the existing semantic
            // (cancel-current-turn-and-run-this-next), but stripped
            // of the cyan-tinted pill background it used to sit in.
            // Hover state on each action does the colour work.
            _QueueAction(
              icon: Icons.flash_on_outlined,
              tooltip: '${S.chatQueuedSendNow} — ${S.chatQueuedSendNowTooltip}',
              hoverAccent: DuckColors.accentCyan,
              onTap: widget.onSendNow,
            ),
            _QueueAction(
              icon: Icons.close,
              tooltip: S.chatQueuedRemove,
              hoverAccent: DuckColors.fgPrimary,
              onTap: widget.onRemove,
            ),
          ],
        ),
      ),
    );
  }
}

/// Bare icon-only action button used on the queue rows.
///
/// Default state is intentionally near-invisible (`fgFaint`); the
/// row's hover state pushes a parent background lift behind it,
/// and this button's own hover bumps the icon to its `hoverAccent`
/// colour. Two layers of subtle feedback let the user discover the
/// actions when they're inspecting a row, without the actions
/// shouting for attention when they're not.
class _QueueAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color hoverAccent;
  final VoidCallback onTap;
  const _QueueAction({
    required this.icon,
    required this.tooltip,
    required this.hoverAccent,
    required this.onTap,
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
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Icon(
              widget.icon,
              size: 12,
              color: _hover ? widget.hoverAccent : DuckColors.fgFaint,
            ),
          ),
        ),
      ),
    );
  }
}
