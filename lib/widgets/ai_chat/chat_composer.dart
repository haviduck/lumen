import 'package:flutter/material.dart';

import '../../services/chat_chip.dart';
import '../../theme/app_colors.dart';
import 'chat_chip.dart';
import 'chip_text_editing_controller.dart';

/// `Wrap` of [ChatChipPill]s rendered ABOVE the composer's plain
/// `TextField`. Listens to [controller]'s chip list (a parallel
/// model alongside the text) and rebuilds when chips are added /
/// removed.
///
/// Why this shape (composite widget, not in-band markers): the
/// council pool falsified seven different in-band approaches
/// (`\uFFFC`, PUA pairs, JSON sentinels) across paste / IME /
/// Nerd-Font collision modes. A separate widget strip is the only
/// design that survives those falsifications: the text stream stays
/// plain, the slash-command picker sees clean offsets, and chip
/// removal is a list mutation rather than a multi-codepoint splice.
class ChatComposerChipsStrip extends StatefulWidget {
  final ChipTextEditingController controller;

  /// Highlight border drawn while a draggable hovers over the strip
  /// (the parent is responsible for the `DragTarget` itself).
  final bool dragHighlighted;

  const ChatComposerChipsStrip({
    super.key,
    required this.controller,
    this.dragHighlighted = false,
  });

  @override
  State<ChatComposerChipsStrip> createState() => _ChatComposerChipsStripState();
}

class _ChatComposerChipsStripState extends State<ChatComposerChipsStrip> {
  @override
  void initState() {
    super.initState();
    widget.controller.addChipListener(_onChange);
  }

  @override
  void didUpdateWidget(ChatComposerChipsStrip old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, widget.controller)) {
      old.controller.removeChipListener(_onChange);
      widget.controller.addChipListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.controller.removeChipListener(_onChange);
    super.dispose();
  }

  void _onChange() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chips = widget.controller.chips;
    if (chips.isEmpty && !widget.dragHighlighted) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: widget.dragHighlighted
                ? DuckColors.accentMint
                : DuckColors.glassSeam,
            width: widget.dragHighlighted ? 1.0 : 0.5,
          ),
        ),
      ),
      child: chips.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              child: Text(
                'Drop file, code or terminal selection',
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgSubtle,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          : Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (var i = 0; i < chips.length; i++)
                  ChatChipPill(
                    key: ValueKey('chip-${chips[i].id}'),
                    chip: chips[i],
                    onRemove: () => widget.controller.removeChipAt(i),
                  ),
              ],
            ),
    );
  }
}

/// Sentinel used by knowledge-base drags so the diff-decoration
/// controller can ignore "edits" applied to the synthetic KB file.
/// Kept in sync with `AppState.knowledgeBaseSentinel`.
const String kKnowledgeBaseChipPath = '__knowledge_base__';

/// Build a [ChatChip] for the knowledge-base entry. Used by the KB
/// tab's drag source so the composer's [DragTarget] receives a
/// first-class chip (no string-path round-trip).
ChatChip knowledgeBaseChip() {
  return ChatChip(
    id: 'kb-${DateTime.now().microsecondsSinceEpoch}',
    kind: ChatChipKind.doc,
    label: 'knowledge base',
    path: kKnowledgeBaseChipPath,
  );
}
