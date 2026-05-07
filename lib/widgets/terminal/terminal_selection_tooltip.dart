import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import '../../services/chat_chip.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'terminal_session.dart';

/// Floating "Add to chat" tooltip that appears whenever the user
/// has an active selection inside [session].
///
/// Wraps the terminal view in a [Stack] sibling — [TerminalPane]
/// inserts this overlay above the `TerminalView`. Listens to
/// [TerminalSession.controller] (xterm's `TerminalController` is a
/// `ChangeNotifier`, fired on every selection change), and when the
/// selection is non-null + non-empty surfaces a small chip-shaped
/// floating bar.
///
/// On tap → builds a [ChatChip.terminal] referencing
/// `terminalId:lineStart-lineEnd` with the selected text as the
/// snippet, and invokes [onAddToChat]. The parent translates that
/// into `chatController.addPendingChip(...)`.
///
/// Dismisses on:
///   - selection cleared (xterm fires controller.clearSelection())
///   - Esc key (handled by the wrapping `Focus`)
///   - outside click (consumer of this widget can wrap in a
///     `TapRegion` if it cares; current design just lets the next
///     selection-clear hide the tooltip naturally)
class TerminalSelectionTooltip extends StatefulWidget {
  final TerminalSession session;
  final void Function(ChatChip chip) onAddToChat;

  const TerminalSelectionTooltip({
    super.key,
    required this.session,
    required this.onAddToChat,
  });

  @override
  State<TerminalSelectionTooltip> createState() =>
      _TerminalSelectionTooltipState();
}

class _TerminalSelectionTooltipState extends State<TerminalSelectionTooltip> {
  late final FocusNode _escFocus = FocusNode(skipTraversal: true);

  @override
  void initState() {
    super.initState();
    widget.session.controller.addListener(_onChange);
  }

  @override
  void didUpdateWidget(TerminalSelectionTooltip old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.controller.removeListener(_onChange);
      widget.session.controller.addListener(_onChange);
    }
  }

  @override
  void dispose() {
    widget.session.controller.removeListener(_onChange);
    _escFocus.dispose();
    super.dispose();
  }

  void _onChange() {
    if (!mounted) return;
    setState(() {});
  }

  BufferRange? get _sel => widget.session.controller.selection;

  String _selectedText() =>
      widget.session.terminal.buffer.getText(_sel!).trimRight();

  ({int start, int end}) _lineRange() {
    final s = _sel!;
    // BufferRange in xterm 4 exposes `.begin.y` and `.end.y` as
    // 0-based absolute buffer line indices. Convert to 1-based for
    // user-facing labels (matches what code-range chips use).
    final ys = (s.begin.y + 1);
    final ye = (s.end.y + 1);
    return (start: ys < ye ? ys : ye, end: ys < ye ? ye : ys);
  }

  void _addToChat() {
    final sel = _sel;
    if (sel == null) return;
    final text = _selectedText();
    if (text.isEmpty) return;
    final r = _lineRange();
    final chip = ChatChip.terminal(
      terminalId: widget.session.id,
      lineStart: r.start,
      lineEnd: r.end,
      snippet: text.length > 800 ? '${text.substring(0, 800)}…' : text,
    );
    widget.onAddToChat(chip);
    // Drop the selection so the tooltip dismisses cleanly.
    widget.session.controller.clearSelection();
  }

  @override
  Widget build(BuildContext context) {
    final sel = _sel;
    if (sel == null) return const SizedBox.shrink();
    final text = widget.session.terminal.buffer.getText(sel);
    if (text.trim().isEmpty) return const SizedBox.shrink();
    final r = _lineRange();
    final lineCount = r.end - r.start + 1;

    return Positioned(
      right: 14,
      bottom: 14,
      child: Focus(
        focusNode: _escFocus,
        autofocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            widget.session.controller.clearSelection();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Material(
          color: Colors.transparent,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              borderRadius: BorderRadius.circular(DuckTheme.radiusM),
              border: Border.all(
                color: DuckColors.accentMint.withValues(alpha: 0.6),
              ),
              boxShadow: DuckTheme.shadowGlow,
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.terminal,
                  size: 13,
                  color: DuckColors.accentMint,
                ),
                const SizedBox(width: 6),
                Text(
                  '$lineCount line${lineCount == 1 ? '' : 's'} selected',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: _addToChat,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: DuckColors.accentMint.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.add_comment_outlined,
                          size: 12,
                          color: DuckColors.accentMint,
                        ),
                        SizedBox(width: 5),
                        Text(
                          'Add to chat',
                          style: TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgPrimary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
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
