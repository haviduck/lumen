import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../l10n/strings.dart';
import '../../services/chat_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import '../common/image_lightbox.dart';
import 'tool_segments.dart';

/// What kind of revert the [_RestoreChip] is offering — drives the
/// tooltip wording and the visible chip label so user-bubble vs
/// assistant-bubble reverts read distinctly.
///
/// - [assistantTurn] is "undo just this turn's file changes" (Cursor's
///   assistant-bubble Restore). Always carries `count > 0` because
///   without changes the chip wouldn't be shown.
/// - [chatRewind] is the user-bubble "rewind chat to right before I
///   sent this" — restores file changes AND truncates the chat. Can
///   be shown with `count == 0` when there are no file changes but
///   subsequent messages still exist to truncate.
enum BubbleRestoreScope { assistantTurn, chatRewind }

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

  /// File-change count surfaced in the [_RestoreChip] when
  /// [onRestore] is non-null. Allowed to be 0 ONLY when
  /// [restoreScope] is [BubbleRestoreScope.chatRewind] — that scope
  /// also reverts subsequent messages, so the chip is meaningful
  /// even with zero file deltas.
  final int restoreChangeCount;
  final BubbleRestoreScope restoreScope;

  /// Number of follow-up messages that will be removed by a
  /// `chatRewind` revert. Zero for assistant-turn reverts. Used in
  /// the tooltip so the user sees "this will also remove N replies"
  /// before clicking.
  final int restoreFollowupMessages;

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
    this.restoreScope = BubbleRestoreScope.assistantTurn,
    this.restoreFollowupMessages = 0,
    this.isStreaming = false,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  bool _hover = false;

  // Render-cache for the renderable preview + parsed segments. Both
  // operations are pure functions of the message content (plus the
  // streaming flag for the preview). The chat panel rebuilds the live
  // bubble at ~30Hz during streaming; without this cache, we'd re-run
  // ~25 full-string regex scans (one per registered tool inside
  // `streamingToolPreview`) and another regex scan inside
  // `parseChatSegments` for *every* rebuild on a growing buffer.
  // That was the main UI-isolate stutter source on fast streams.
  // The cache key is the raw content + streaming flag for the
  // renderable, and the renderable string itself for segments.
  // Identical strings hit by reference equality first (Dart strings
  // are canonicalised when interned but otherwise we rely on the
  // append-only nature of streaming — the new content reference
  // won't match the previous one and we recompute).
  String? _cachedRawForRender;
  bool? _cachedStreamingForRender;
  String? _cachedRenderable;

  String? _cachedSegmentsSource;
  List<ChatSegment>? _cachedSegments;

  Future<void> _copy() async {
    // Strip the structured `<!-- LUMEN_TOOL:... -->` markers and
    // restore the friendly plain-text rendering — paste-to-other-app
    // shouldn't dump HTML comments at the user. For slash-command
    // user bubbles the visible label is the source of truth (the
    // verbose underlying prompt is plumbing the user shouldn't have
    // to paste anywhere).
    final source = widget.isUser && widget.message.displayContent != null
        ? widget.message.displayContent!
        : widget.message.content;
    final clean = stripMarkersForCopy(source);
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
  ///
  /// Memoised on `(rawContent, isStreaming)` so the heavy
  /// `streamingToolPreview` regex sweep doesn't run on every panel
  /// rebuild — only when the content or streaming state actually
  /// changed since the last call.
  String _renderableContent() {
    final raw = widget.message.content;
    final streaming = widget.isStreaming;
    if (_cachedRawForRender == raw &&
        _cachedStreamingForRender == streaming &&
        _cachedRenderable != null) {
      return _cachedRenderable!;
    }

    final String result;
    if (!streaming) {
      result = raw;
    } else {
      final preview = streamingToolPreview(raw);
      final fenceCount = RegExp(r'```').allMatches(preview).length;
      if (fenceCount.isOdd) {
        // Newline guard: if the unclosed fence is on the same line
        // as the trailing chunk (e.g. mid-token), prepending a
        // newline before the closing fence keeps the parser happy.
        final needsNewline = !preview.endsWith('\n');
        result = '$preview${needsNewline ? '\n' : ''}```';
      } else {
        result = preview;
      }
    }

    _cachedRawForRender = raw;
    _cachedStreamingForRender = streaming;
    _cachedRenderable = result;
    return result;
  }

  /// Cached `parseChatSegments` — same memoisation strategy as
  /// [_renderableContent]. The segment parse is cheaper than the
  /// preview but still a full-string regex scan; on a stable bubble
  /// it should be a free read across rebuilds.
  List<ChatSegment> _segmentsFor(String content) {
    if (_cachedSegmentsSource == content && _cachedSegments != null) {
      return _cachedSegments!;
    }
    final segs = parseChatSegments(content);
    _cachedSegmentsSource = content;
    _cachedSegments = segs;
    return segs;
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
                        (widget.restoreChangeCount > 0 ||
                            widget.restoreFollowupMessages > 0)) ...[
                      _RestoreChip(
                        count: widget.restoreChangeCount,
                        scope: widget.restoreScope,
                        followupMessageCount: widget.restoreFollowupMessages,
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
    // `displayContent` overrides `content` for rendering only — the
    // model still receives the full `content`. Currently set by
    // slash commands so the bubble shows e.g. `/handoff` instead of
    // a multi-paragraph instruction prompt.
    final hasDisplayOverride =
        widget.message.displayContent != null &&
        widget.message.displayContent!.trim().isNotEmpty;
    final visibleText = hasDisplayOverride
        ? widget.message.displayContent!
        : widget.message.content;

    // **User-bubble shell.**
    //
    // Cursor / Antigravity-style: a quiet dark card with a hairline
    // border and softened corners. Earlier versions rendered as a
    // hard-edged accent-cyan left bar (vibrant, but stylistically
    // out of step with the rest of the surface chrome and starved
    // the bubble of horizontal space for chip overlays). Switching
    // to a uniform border + radius:
    //   - matches the file-explorer / approval / queued-prompts
    //     panels visually (DuckGlass surface vocabulary);
    //   - leaves clean inner margin for the floating Revert / Copy
    //     chips, which previously tightroped against the bubble's
    //     hard right edge;
    //   - drops a `Color(0xFF1e2229)` literal that violated the
    //     "no raw color literals" theming rule.
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.message.imagesBase64.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: widget.message.imagesBase64.map((b64) {
                Uint8List? decoded;
                try {
                  decoded = base64Decode(b64);
                } catch (_) {
                  return const SizedBox.shrink();
                }
                return _ChatImageThumb(
                  base64Image: b64,
                  decoded: decoded,
                  caption: visibleText.trim().isEmpty
                      ? null
                      : visibleText.trim(),
                );
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
          if (visibleText.trim().isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 28),
              child: hasDisplayOverride
                  ? _SlashCommandLabel(text: visibleText)
                  : Text(
                      visibleText,
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
    // read-only inspection. Runs of 3+ same-action calls collapse
    // into a [ToolGroupSegment] rendered by `ToolGroupView`.
    //
    // **Stable keys** are essential here. Without them, when a
    // chunk arrives mid-stream and the segment list shifts (a new
    // tool just landed at the tail), Flutter recycles the existing
    // `_FileToolCardState` / `_ToolGroupViewState` instances onto
    // different segments — visible as a hover / expanded flicker.
    // Keying by (segment-kind + ordinal index + identifying field)
    // pins each widget to its segment across rebuilds.
    final segments = _segmentsFor(_renderableContent());
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(14, 10, 28, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < segments.length; i++)
            _segmentWidget(segments[i], i),
          if (widget.isStreaming) ...[
            const SizedBox(height: 2),
            const _StreamingCursor(),
          ],
        ],
      ),
    );
  }

  Widget _segmentWidget(ChatSegment seg, int index) {
    if (seg is ProseSegment) {
      return KeyedSubtree(
        key: ValueKey('prose-$index'),
        child: _buildProse(seg.text),
      );
    }
    // Selection model: we do NOT wrap tool/group/error segments in
    // `SelectionContainer.disabled` anymore. We used to, so that
    // cross-bubble drag-select via the outer `SelectionArea`
    // skipped tool cards. But mid-stream rebuilds (every chunk
    // changes segment indices when prose grows / a tool resolves)
    // would unmount a `SelectionContainer.disabled` subtree
    // *between* the SelectionArea delegate's `_flushAdditions` and
    // its `_compareScreenOrder` microtask, blowing up with
    // `Cannot get renderObject of inactive element` (visible
    // first on Opus 4.7 — its first chunk is fast enough that two
    // segment-list rebuilds land in the same frame). The fix is
    // structural: don't introduce SelectionContainers whose shape
    // we can't keep stable across streaming. Side effect: dragging
    // a selection across a bubble now also picks up the small
    // text inside tool cards (status / tool name / file path).
    // Acceptable — copy-paste of a few extra labels is a much
    // smaller papercut than the chat panel crashing.
    if (seg is ToolSegment) {
      return KeyedSubtree(
        key: ValueKey('tool-$index-${seg.toolId}-${seg.firstArg}'),
        child: ToolSegmentView(segment: seg),
      );
    }
    if (seg is ToolGroupSegment) {
      // Group key includes count so adding another member to the
      // tail doesn't invalidate the expand/collapse state
      // pointlessly — but DOES invalidate it when a new group
      // appears at the same index (which is the right behaviour:
      // the user's current expand/collapse choice belongs to the
      // *previous* group, not the new one that took its slot).
      final first = seg.tools.first;
      return KeyedSubtree(
        key: ValueKey(
          'group-$index-${first.toolId}-${first.status}-${seg.tools.length}',
        ),
        child: ToolGroupView(group: seg),
      );
    }
    if (seg is ProviderErrorSegment) {
      return KeyedSubtree(
        key: ValueKey('err-$index-${seg.error.kind}'),
        child: ProviderErrorCard(error: seg.error),
      );
    }
    return const SizedBox.shrink();
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

/// 96x96 chat-bubble image preview that opens [ImageLightbox] on
/// click. Used by both user-sent attachments and tool-injected
/// snapshot bubbles. Shows a soft hover ring and tooltip so the
/// click affordance is discoverable — without it users miss the
/// fact that the thumbnail is interactive.
class _ChatImageThumb extends StatefulWidget {
  final String base64Image;
  final Uint8List decoded;
  final String? caption;

  const _ChatImageThumb({
    required this.base64Image,
    required this.decoded,
    this.caption,
  });

  @override
  State<_ChatImageThumb> createState() => _ChatImageThumbState();
}

class _ChatImageThumbState extends State<_ChatImageThumb> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.imageLightboxOpenHint,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: () => ImageLightbox.show(
            context,
            base64Image: widget.base64Image,
            caption: widget.caption,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(
                color: _hover
                    ? DuckColors.accentCyan.withValues(alpha: 0.7)
                    : DuckColors.border,
                width: _hover ? 1.2 : 0.5,
              ),
              boxShadow: _hover
                  ? [
                      BoxShadow(
                        color: DuckColors.accentCyan.withValues(alpha: 0.18),
                        blurRadius: 6,
                        spreadRadius: 0.5,
                      ),
                    ]
                  : null,
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              child: Image.memory(
                widget.decoded,
                width: 96,
                height: 96,
                fit: BoxFit.cover,
                filterQuality: FilterQuality.medium,
              ),
            ),
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
  final BubbleRestoreScope scope;
  final int followupMessageCount;
  final VoidCallback onTap;
  const _RestoreChip({
    required this.count,
    required this.scope,
    required this.followupMessageCount,
    required this.onTap,
  });

  @override
  State<_RestoreChip> createState() => _RestoreChipState();
}

class _RestoreChipState extends State<_RestoreChip> {
  bool _innerHover = false;

  String _tooltip() {
    switch (widget.scope) {
      case BubbleRestoreScope.assistantTurn:
        return S.chatRestoreFilesTooltip(widget.count);
      case BubbleRestoreScope.chatRewind:
        return S.chatRewindTooltip(
          widget.count,
          widget.followupMessageCount,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // chat-rewind reverts CAN run with zero file-change count (the
    // chat truncation alone is reason enough). In that case we drop
    // the numeric label and show only the icon so the chip doesn't
    // read as "0 changes".
    final showCount = widget.count > 0;
    return Tooltip(
      message: _tooltip(),
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        onEnter: (_) => setState(() => _innerHover = true),
        onExit: (_) => setState(() => _innerHover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            height: 24,
            padding: EdgeInsets.symmetric(horizontal: showCount ? 7 : 5),
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
                if (showCount) ...[
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

/// Compact pill rendering for a user bubble whose visible content is
/// a slash-command label (e.g. `/handoff`) standing in for a much
/// longer prompt that the model receives but the user shouldn't have
/// to scroll past. Visually distinct from a normal user message so it
/// reads as "I invoked a command" rather than "I typed this text".
class _SlashCommandLabel extends StatelessWidget {
  final String text;

  const _SlashCommandLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: DuckColors.bgRaisedHi.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.accentCyan.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.terminal,
            size: 12,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgPrimary,
                fontFamily: DuckTheme.monoFont,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
