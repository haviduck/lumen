import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../l10n/strings.dart';
import '../../services/chat_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'tool_segments.dart';

/// Single chat bubble in the AI chat panel.
///
/// **Selection model** — bubbles intentionally do NOT use
/// `SelectableText` or `MarkdownBody.selectable: true` anymore. Selection
/// is owned by a `SelectionArea` higher up in the tree (see
/// `ai_chat.dart::_buildMessageList`) so the user can Ctrl+drag across
/// MULTIPLE bubbles and Ctrl+C the whole range. Inner `selectable`
/// widgets compete with `SelectionArea` and break cross-widget drag.
///
/// **Floating copy button** — `MouseRegion` flips an internal `_hover`
/// flag; the button fades in (`AnimatedOpacity`) at the top-right of
/// the bubble. Click copies `message.content` (raw text — not the
/// rendered markdown) to the clipboard. We feed the raw text rather
/// than the friendly placeholders so the user gets the full ground-truth
/// payload (useful for forwarding agent output to other tools).
class MessageBubble extends StatefulWidget {
  final PersistedMessage message;
  final bool isUser;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final VoidCallback? onRestore;
  final int restoreChangeCount;

  /// Set to `true` for the assistant message that is currently
  /// being streamed in. Enables:
  /// - Animated cursor block (▎) at the message tail.
  /// - Code-fence "balancing" — if the partial markdown ends in an
  ///   open ` ``` ` block we close it virtually, so partial code
  ///   renders as a code block instead of leaking into prose
  ///   styling mid-stream.
  final bool isStreaming;

  const MessageBubble({
    super.key,
    required this.message,
    required this.isUser,
    this.onEdit,
    this.onDelete,
    this.onRestore,
    this.restoreChangeCount = 0,
    this.isStreaming = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hover = false;

  Future<void> _copy() async {
    // Strip the structured `<!-- LUMEN_TOOL:... -->` markers and
    // restore the friendly plain-text rendering — paste-to-other-app
    // shouldn't dump HTML comments at the user.
    final clean = stripMarkersForCopy(widget.message.content);
    await Clipboard.setData(ClipboardData(text: clean));
    if (!mounted) return;
    showDuckToast(context, S.chatMessageCopied);
  }

  /// If the streaming content currently has an unclosed ` ``` `
  /// fence, append a virtual closing fence so the partial code
  /// block actually renders as a code block. Without this, an
  /// unclosed fence makes the markdown parser swallow everything
  /// after as raw text and the user watches their code being
  /// "typed" in default prose styling.
  ///
  /// Counts triple-backtick *runs* (not individual backticks). An
  /// odd count means we're currently inside a fence.
  String _renderableContent() {
    final content = widget.isStreaming
        ? streamingToolPreview(widget.message.content)
        : widget.message.content;
    if (!widget.isStreaming) return content;
    final fenceCount = RegExp(r'```').allMatches(content).length;
    if (fenceCount.isOdd) {
      // Newline guard: if the unclosed fence is on the same line
      // as the trailing chunk (e.g. mid-token), prepending a
      // newline before the closing fence keeps the parser happy.
      final needsNewline = !content.endsWith('\n');
      return '$content${needsNewline ? '\n' : ''}```';
    }
    return content;
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.isUser ? _buildUserMessage() : _buildAgentMessage();
    return MouseRegion(
      onEnter: (_) {
        if (!_hover) setState(() => _hover = true);
      },
      onExit: (_) {
        if (_hover) setState(() => _hover = false);
      },
      child: Stack(
        children: [
          body,
          // Floating copy chip — top-right corner, fades in on hover.
          // `IgnorePointer` when hidden so it doesn't intercept
          // selection drags begun outside the bubble. The chip is
          // intentionally NOT inside a SelectionArea boundary
          // (Stack child after `body`) so clicks on it don't end up
          // counted as a selection drag start in the area above.
          Positioned(
            top: 4,
            right: 4,
            child: IgnorePointer(
              ignoring: !_hover,
              child: AnimatedOpacity(
                opacity: _hover ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.onRestore != null &&
                        widget.restoreChangeCount > 0) ...[
                      _RestoreChip(
                        count: widget.restoreChangeCount,
                        onTap: widget.onRestore!,
                      ),
                      const SizedBox(width: 4),
                    ],
                    _CopyChip(onTap: _copy),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserMessage() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xFF1e2229),
        border: Border(
          left: BorderSide(color: DuckColors.accentCyan, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message.imagesBase64.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.message.imagesBase64.map((b64) {
                try {
                  return ClipRRect(
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    child: Image.memory(
                      base64Decode(b64),
                      width: 96,
                      height: 96,
                      fit: BoxFit.cover,
                    ),
                  );
                } catch (_) {
                  return const SizedBox.shrink();
                }
              }).toList(),
            ),
            const SizedBox(height: 6),
          ],
          if (widget.message.references.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.message.references
                  .map((ref) => _MessageReferenceChip(reference: ref))
                  .toList(),
            ),
            const SizedBox(height: 6),
          ],
          // Plain Text — selection is delegated to the upstream
          // SelectionArea so the user can drag across bubbles.
          if (widget.message.content.trim().isNotEmpty)
            Padding(
              // Right-padded so the floating copy chip doesn't overlap
              // the text on short messages.
              padding: const EdgeInsets.only(right: 28),
              child: Text(
                widget.message.content,
                style: const TextStyle(
                  fontSize: 13,
                  color: DuckColors.fgPrimary,
                  height: 1.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildAgentMessage() {
    // Parse the body into prose + tool segments. Prose chunks render
    // through `MarkdownBody`; tool segments render as the structured
    // cards / badges in `tool_segments.dart`. Earlier the tool calls
    // landed as italic-text placeholders (`*(Edited file: foo)*`)
    // alongside prose; now they're chrome — clickable cards for file
    // ops, terminal-styled cards for commands, pill badges for
    // read-only inspection.
    final segments = parseChatSegments(_renderableContent());
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 28, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final seg in segments)
            if (seg is ProseSegment)
              _buildProse(seg.text)
            else if (seg is ToolSegment)
              SelectionContainer.disabled(child: ToolSegmentView(segment: seg))
            else if (seg is ProviderErrorSegment)
              SelectionContainer.disabled(
                child: ProviderErrorCard(error: seg.error),
              ),
          if (widget.isStreaming) ...[
            const SizedBox(height: 2),
            const _StreamingCursor(),
          ],
        ],
      ),
    );
  }

  Widget _buildProse(String text) {
    // selectable=false — SelectionArea above owns selection and we
    // want unified cross-bubble drag. With `selectable: true`,
    // MarkdownBody wraps everything in SelectableText, breaks
    // SelectionArea's drag handling at the bubble boundary.
    return MarkdownBody(
      data: text,
      selectable: false,
      styleSheet: MarkdownStyleSheet(
        p: const TextStyle(
          fontSize: 13,
          color: DuckColors.fgPrimary,
          height: 1.5,
        ),
        code: const TextStyle(
          fontFamily: DuckTheme.monoFont,
          fontSize: 12,
          backgroundColor: DuckColors.bgDeeper,
          color: DuckColors.accentCyan,
        ),
        codeblockPadding: const EdgeInsets.all(10),
        codeblockDecoration: BoxDecoration(
          color: DuckColors.bgDeepest,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        ),
        blockquoteDecoration: BoxDecoration(
          color: DuckColors.bgDeeper,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: const Border(
            left: BorderSide(color: DuckColors.accentMint, width: 3),
          ),
        ),
      ),
    );
  }
}

class _MessageReferenceChip extends StatelessWidget {
  final ChatReference reference;

  const _MessageReferenceChip({required this.reference});

  @override
  Widget build(BuildContext context) {
    final isFolder = reference.kind == ChatReferenceKind.folder;
    return Container(
      constraints: const BoxConstraints(maxWidth: 260),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isFolder ? Icons.folder_outlined : Icons.description_outlined,
            size: 13,
            color: isFolder ? DuckColors.accentDuck : DuckColors.accentCyan,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              reference.label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _RestoreChip extends StatefulWidget {
  final int count;
  final VoidCallback onTap;
  const _RestoreChip({required this.count, required this.onTap});

  @override
  State<_RestoreChip> createState() => _RestoreChipState();
}

class _RestoreChipState extends State<_RestoreChip> {
  bool _innerHover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.chatRestoreFilesTooltip(widget.count),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _innerHover = true),
        onExit: (_) => setState(() => _innerHover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: _innerHover
                  ? DuckColors.bgRaisedHi.withValues(alpha: 0.9)
                  : DuckColors.bgDeeper.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.restore,
                  size: 13,
                  color: DuckColors.accentDuck,
                ),
                const SizedBox(width: 4),
                Text(
                  '${widget.count}',
                  style: const TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
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

/// Small floating button shown at the top-right of every chat bubble
/// on hover. Subtle to keep the chat visual hierarchy quiet — slightly
/// translucent surface, hairline border, mint icon. Same shape and
/// affordance as similar tiny chrome elements elsewhere (terminal
/// title-row icon buttons, media pane chrome controls).
class _CopyChip extends StatefulWidget {
  final VoidCallback onTap;
  const _CopyChip({required this.onTap});

  @override
  State<_CopyChip> createState() => _CopyChipState();
}

class _CopyChipState extends State<_CopyChip> {
  bool _innerHover = false;
  bool _justCopied = false;

  void _onTap() {
    widget.onTap();
    setState(() => _justCopied = true);
    // Briefly swap to a check icon so the user gets non-toast
    // feedback at the click site too. 1.4s is enough to register
    // without making the hover behaviour feel sticky.
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (mounted) setState(() => _justCopied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.chatMessageCopy,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _innerHover = true),
        onExit: (_) => setState(() => _innerHover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: _onTap,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _innerHover
                  ? DuckColors.bgRaisedHi.withValues(alpha: 0.9)
                  : DuckColors.bgDeeper.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Icon(
              _justCopied ? Icons.check : Icons.content_copy_outlined,
              size: 13,
              color: _justCopied ? DuckColors.accentMint : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Blinking 1Hz block cursor, shown at the tail of a message
/// that's still streaming. Subtle but unmistakable signal that
/// "more is coming". Costs one TickerProvider per visible bubble
/// (only the live one), which is fine.
class _StreamingCursor extends StatefulWidget {
  const _StreamingCursor();

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(
        begin: 0.25,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)),
      child: Container(
        width: 7,
        height: 14,
        decoration: BoxDecoration(
          color: DuckColors.accentMint,
          borderRadius: BorderRadius.circular(1.5),
        ),
      ),
    );
  }
}
