import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

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
enum BubbleRestoreScope { assistantTurn, chatRewind, workspaceMismatch }

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
  String? _cachedSegmentsNonce;
  // Cache invalidation also keys on the raw message content
  // because [extractPendingToolBodies] runs over raw, not over the
  // streaming-preview output. Without these two extras the cache
  // would freeze on the first sample of bodies and the "Live
  // preview" region would never update as new tokens stream in.
  String? _cachedSegmentsRawForBodies;
  bool? _cachedSegmentsStreaming;
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
      // Pass the message's per-turn nonce so the preview's
      // pass-0 strip can drop model-emitted impersonation
      // markers and the pass-1/2/3 emitters bake the right
      // nonce into pending/malformed markers (so the parser
      // accepts them as real). Null nonce on legacy messages
      // keeps the pre-binding behavior — every well-formed
      // marker survives.
      final preview = streamingToolPreview(
        raw,
        markerNonce: widget.message.toolMarkerNonce,
      );
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
  ///
  /// While streaming, also walks the raw message content with
  /// [extractPendingToolBodies] and attaches each pending body to
  /// the corresponding `pending` body-shaped [ToolSegment] in
  /// source order. That gives [_FileToolCard] the live bytes to
  /// surface in its expandable "Live preview" region — the user's
  /// tail-on-the-stream view for spotting runaway tool calls
  /// (the "REPLACE REPLACE …" loop class) before the output
  /// budget burns through.
  List<ChatSegment> _segmentsFor(String content) {
    final nonce = widget.message.toolMarkerNonce;
    final raw = widget.message.content;
    final streaming = widget.isStreaming;
    if (_cachedSegmentsSource == content &&
        _cachedSegmentsNonce == nonce &&
        _cachedSegmentsRawForBodies == raw &&
        _cachedSegmentsStreaming == streaming &&
        _cachedSegments != null) {
      return _cachedSegments!;
    }
    // Pass the message's per-turn nonce so the parser drops any
    // `<!-- LUMEN_TOOL:... -->` whose trailing nonce field
    // doesn't match — those are model-emitted impersonations of
    // the marker shape (most common with weak Ollama cloud
    // models, see `tool_segments.dart` library doc). Legacy
    // messages with a null nonce render every well-formed
    // marker as before.
    final segs = parseChatSegments(content, expectedNonce: nonce);
    if (streaming) {
      // Body extraction runs on the *raw* message content
      // because the streaming-preview pipeline already rewrote
      // bodies into compact pending markers. Raw + preview are
      // produced in source order, so a parallel walk over
      // pending body-shaped segments and the extracted bodies
      // gets each body to the right segment without any name
      // matching.
      final bodies = extractPendingToolBodies(raw);
      var bodyIdx = 0;
      void attach(ToolSegment seg) {
        if (!seg.pending) return;
        if (!isBodyShapedToolId(seg.toolId)) return;
        if (bodyIdx >= bodies.length) return;
        seg.pendingBody = bodies[bodyIdx].body;
        bodyIdx++;
      }

      for (final seg in segs) {
        if (seg is ToolSegment) {
          attach(seg);
        } else if (seg is ToolGroupSegment) {
          // Defensive: 3+ consecutive same-status same-kind body-
          // shaped tools could in theory cluster into a group. Walk
          // into the group so the live preview still attaches in
          // source order.
          for (final t in seg.tools) {
            attach(t);
          }
        }
      }
    }
    _cachedSegmentsSource = content;
    _cachedSegmentsNonce = nonce;
    _cachedSegmentsRawForBodies = raw;
    _cachedSegmentsStreaming = streaming;
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
                            widget.restoreFollowupMessages > 0 ||
                            widget.restoreScope ==
                                BubbleRestoreScope.workspaceMismatch)) ...[
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
          // Diagnostic timing footer. Only renders when:
          //   - the turn has actually finished (no streaming cursor
          //     showing — partial timings during streaming would
          //     mislead);
          //   - the persisted message carries timing fields (legacy
          //     messages from before the instrumentation landed
          //     have all-null timing and stay clean).
          if (!widget.isStreaming &&
              widget.message.totalDurationMs != null) ...[
            const SizedBox(height: 4),
            _TurnTimingFooter(message: widget.message),
          ],
        ],
      ),
    );
  }

  Widget _segmentWidget(ChatSegment seg, int index) {
    if (seg is ThinkingSegment) {
      return KeyedSubtree(
        key: ValueKey('think-$index'),
        child: _ThinkingBlock(content: seg.content, isActive: seg.isActive),
      );
    }
    if (seg is ProseSegment) {
      return KeyedSubtree(
        key: ValueKey('prose-$index'),
        child: _buildProse(seg.text),
      );
    }
    if (seg is ToolSegment) {
      return KeyedSubtree(
        key: ValueKey('tool-$index-${seg.toolId}-${seg.firstArg}'),
        child: ToolSegmentView(segment: seg),
      );
    }
    if (seg is ToolGroupSegment) {
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
    //
    // **Fenced code blocks are an exception.** The default `pre`
    // renderer wraps the block in a horizontal `SingleChildScrollView`
    // whose drag-to-scroll gesture eats `SelectionArea`'s drag
    // events — users physically couldn't highlight code to copy it.
    // We override the `pre` builder with `_CodeBlockBuilder` which
    // renders a Container + selectable text + a dedicated copy chip
    // (the affordance every chat UI ships, ChatGPT/Cursor/Claude).
    return MarkdownBody(
      data: text,
      selectable: false,
      builders: <String, MarkdownElementBuilder>{'pre': _CodeBlockBuilder()},
      styleSheet: MarkdownStyleSheet(
        // Assistant reply prose intentionally renders dimmer than
        // user-typed text (which uses [fgPrimary] in
        // `_buildUserMessage`). Same blue-grey hue, ~28% lower
        // luminance — the gap that actually reads on a glance as
        // "model side, not me" without the prose ever feeling
        // unreadable. Code blocks, tool cards, and accents keep
        // their full brightness; only free-form reply prose is
        // dimmed, since that's the part where the user/model
        // contrast carries hierarchy.
        p: const TextStyle(
          fontSize: 13,
          color: DuckColors.fgSecondary,
          height: 1.5,
        ),
        code: const TextStyle(
          fontFamily: DuckTheme.monoFont,
          fontSize: 12,
          backgroundColor: DuckColors.bgDeeper,
          color: DuckColors.accentCyan,
        ),
        // codeblockPadding/Decoration left for parity but `_CodeBlock`
        // owns its own visuals — these only apply if `pre` somehow
        // routes back to the default renderer (e.g. an unexpected
        // pre-without-code element).
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

/// MarkdownElementBuilder for fenced code blocks (`<pre><code>...`).
///
/// Replaces `flutter_markdown_plus`'s default `pre` renderer (which
/// nests a horizontal scroll view that eats `SelectionArea` drag
/// events, leaving users unable to highlight code) with a [_CodeBlock]
/// widget that owns the copy affordance directly. Falls back to
/// nothing (returns `null`) for malformed `pre` elements without a
/// child `code` node — the default renderer will pick those up.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final code = _extractCode(element);
    if (code == null) return null;
    return _CodeBlock(code: code, language: _extractLanguage(element));
  }

  /// Pull the code text out of the `<pre><code>` AST. Walks one level
  /// deep — markdown spec guarantees fenced blocks are exactly
  /// `<pre><code>…text…</code></pre>`. If the structure doesn't match
  /// (some embed widget upstream, malformed input, …), return null
  /// so the default renderer takes over rather than us silently
  /// dropping the block.
  String? _extractCode(md.Element element) {
    final children = element.children;
    if (children == null || children.isEmpty) return null;
    final inner = children.first;
    if (inner is! md.Element || inner.tag != 'code') return null;
    return inner.textContent;
  }

  /// Extract the language hint from the inner `<code>` element's
  /// `class` attribute (markdown writes it as `language-python` for
  /// ` ```python `). Returns null when no class is set or the class
  /// doesn't follow the `language-*` convention — the header strip
  /// is hidden in that case.
  String? _extractLanguage(md.Element element) {
    final children = element.children;
    if (children == null || children.isEmpty) return null;
    final inner = children.first;
    if (inner is! md.Element) return null;
    final cls = inner.attributes['class'];
    if (cls == null) return null;
    const prefix = 'language-';
    if (!cls.startsWith(prefix)) return null;
    final lang = cls.substring(prefix.length).trim();
    return lang.isEmpty ? null : lang;
  }
}

/// Visual + interactive code-block widget. Renders a dark mono panel
/// with an optional language label and a top-right copy chip that
/// flashes "Copied" for ~1.4s when activated.
///
/// **Selection trade-off.** The block's body is a plain `Text` (NOT
/// `SelectableText`) wrapped in a horizontal scroll view so long
/// lines stay on one line. Drag-selection inside is partially eaten
/// by the scroll view (same flutter_markdown_plus bug we couldn't
/// undo without horizontal scroll), but `SelectionArea`'s
/// keyboard-driven select-all + drag-from-outside-the-block still
/// covers it AND the copy chip is the primary affordance. The chip
/// guarantees recovery for any case the selection drag misses.
class _CodeBlock extends StatefulWidget {
  final String code;
  final String? language;

  const _CodeBlock({required this.code, this.language});

  @override
  State<_CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<_CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    // Visual confirmation directly on the chip so the user doesn't
    // have to glance away to a toast. We still toast for parity with
    // the bubble-level Copy chip — accessibility (screen readers) +
    // the toast is the canonical "something happened" signal.
    setState(() => _copied = true);
    showDuckToast(context, S.chatMessageCopied);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Trim a single trailing newline (the markdown parser keeps the
    // closing fence's newline as part of the code text). Visually
    // equivalent, but pasting into another editor won't add the
    // phantom blank line.
    final code = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header strip — language label (left) + copy chip (right).
          // Always rendered so the copy affordance is consistent
          // even on language-less blocks; the language slot collapses
          // to an empty Spacer when unset.
          Container(
            padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                if (widget.language != null) ...[
                  Text(
                    widget.language!.toLowerCase(),
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: DuckColors.fgMuted,
                      fontFamily: DuckTheme.monoFont,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
                const Spacer(),
                _CodeBlockCopyChip(onTap: _copy, copied: _copied),
              ],
            ),
          ),
          // Body. SelectableText keeps drag-select working *inside*
          // the block (a small SelectionArea-incompatible carve-out;
          // SelectableText nested in SelectionArea is supported and
          // wins for the inner region — outer drag-select still
          // works for prose, just not from prose into a code block,
          // which is a sane boundary). Horizontal scroll handles
          // long lines without forcing line-wrap that would mangle
          // indentation-sensitive code (Python, YAML).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 12,
                color: DuckColors.fgPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Compact copy chip rendered in the code-block header. Keeps a tiny
/// hover state so it's visibly interactive without dominating the
/// header strip (mirrors the per-message `_CopyChip` ergonomics, but
/// at code-block scale rather than bubble scale).
class _CodeBlockCopyChip extends StatefulWidget {
  final VoidCallback onTap;
  final bool copied;

  const _CodeBlockCopyChip({required this.onTap, required this.copied});

  @override
  State<_CodeBlockCopyChip> createState() => _CodeBlockCopyChipState();
}

class _CodeBlockCopyChipState extends State<_CodeBlockCopyChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.copied ? S.chatCodeBlockCopied : S.chatCodeBlockCopy;
    final iconColor = widget.copied
        ? DuckColors.accentMint
        : (_hover ? DuckColors.fgPrimary : DuckColors.fgMuted);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 350),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.copied ? Icons.check : Icons.content_copy_outlined,
                  size: 12,
                  color: iconColor,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: iconColor,
                    fontFamily: DuckTheme.monoFont,
                    letterSpacing: 0.3,
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

/// Dim, non-interactive timing footer for finished assistant
/// turns. Renders something like:
///
///     3:02 · TTFB 8.4s · 4 iters · last 2:58
///
/// Surfaces the data needed to diagnose Ollama Cloud's hard 182s
/// timeout (issue ollama/ollama#15973) without adding UI noise to
/// short, fast turns — most one-iteration Q&A turns will read
/// just `2.3s · TTFB 1.1s` and that's it.
///
/// Pure presentation; the source of truth lives on the
/// [PersistedMessage] timing fields populated by
/// `ChatController._runGenerationLoop`.
class _TurnTimingFooter extends StatelessWidget {
  final PersistedMessage message;

  const _TurnTimingFooter({required this.message});

  @override
  Widget build(BuildContext context) {
    final parts = <String>[];
    final total = message.totalDurationMs;
    if (total != null) parts.add(_formatDuration(total));

    final ttfb = message.firstByteLatencyMs;
    if (ttfb != null) parts.add(S.turnTimingTtfb(_formatDuration(ttfb)));

    final iters = message.iterationCount;
    if (iters != null && iters > 1) {
      parts.add(S.turnTimingIters(iters));
    }

    final lastIter = message.lastIterationDurationMs;
    // Only show last-iteration duration when there were multiple
    // iterations AND the last one is meaningfully shorter than the
    // total (otherwise it's redundant — a 1-iter turn has total ==
    // lastIter by definition, and printing both is just noise).
    if (lastIter != null &&
        iters != null &&
        iters > 1 &&
        total != null &&
        (total - lastIter) > 250) {
      parts.add(S.turnTimingLast(_formatDuration(lastIter)));
    }

    if (parts.isEmpty) return const SizedBox.shrink();

    final text = parts.join(' · ');

    // Highlight the 182s-wall failure mode visually so it's easy
    // to spot in a long chat: any turn whose total OR last-iter
    // landed in the 175-185s window gets a faint warning tint.
    // 175ms on either side covers clock jitter, gateway delay,
    // and the actual cliff (which the bug report measured at
    // 182,043ms ±50ms).
    final hitTheWall =
        (total != null && total >= 175000 && total <= 185000) ||
        (lastIter != null && lastIter >= 175000 && lastIter <= 185000);

    return Tooltip(
      message: hitTheWall ? S.turnTimingWallTooltip : S.turnTimingTooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: hitTheWall ? DuckColors.stateWarn : DuckColors.fgMuted,
          fontFamily: DuckTheme.monoFont,
          height: 1.3,
        ),
      ),
    );
  }

  /// Render a duration in human-friendly form. Sub-second uses
  /// one decimal ("0.8s"), under a minute uses no decimal ("12s"),
  /// minute-plus uses `Nm SSs` ("3m 02s"). The minute-plus format
  /// is *deliberately* not `M:SS` — that colon-separated shape
  /// reads exactly like a wallclock time-of-day (15:56 → "3:56
  /// PM?") and confused users into thinking the footer was
  /// showing when the turn happened, not how long it took.
  static String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    if (ms < 10000) {
      final seconds = ms / 1000;
      return '${seconds.toStringAsFixed(1)}s';
    }
    if (ms < 60000) {
      return '${(ms / 1000).round()}s';
    }
    final totalSec = (ms / 1000).round();
    final minutes = totalSec ~/ 60;
    final seconds = totalSec % 60;
    return '${minutes}m ${seconds.toString().padLeft(2, '0')}s';
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
        return S.chatRewindTooltip(widget.count, widget.followupMessageCount);
      case BubbleRestoreScope.workspaceMismatch:
        return S.chatRestoreUnavailableWorkspace;
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
          const Icon(Icons.terminal, size: 12, color: DuckColors.accentCyan),
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

/// Collapsible block showing model reasoning (thinking tokens).
/// While [isActive], renders an animated "Thinking…" indicator.
/// Once complete, collapses to a one-line summary that expands on tap
/// to reveal the full reasoning trace.
class _ThinkingBlock extends StatefulWidget {
  final String content;
  final bool isActive;

  const _ThinkingBlock({required this.content, required this.isActive});

  @override
  State<_ThinkingBlock> createState() => _ThinkingBlockState();
}

class _ThinkingBlockState extends State<_ThinkingBlock>
    with SingleTickerProviderStateMixin {
  bool _expanded = false;
  late final AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hasContent = widget.content.trim().isNotEmpty;
    final clickable = hasContent;
    // 2026-05 visual de-clutter pass: the previous bordered + tinted-bg
    // chip card competed visually with file-tool cards and turned a
    // typical agentic turn ("think → tool → think → tool → …") into a
    // wall of equally-loud chrome. Slim treatment: borderless, no
    // baseline tint, hover lift only — same grammar as the queued-
    // prompts strip rows. Expanded content area unchanged so the
    // user can still read the full reasoning trace.
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: clickable
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              onTap: clickable
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(
                duration: DuckMotion.fast,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.isActive)
                      AnimatedBuilder(
                        animation: _pulseController,
                        builder: (_, child) => Opacity(
                          opacity: 0.4 + 0.6 * _pulseController.value,
                          child: child,
                        ),
                        child: Icon(
                          Icons.psychology,
                          size: 12,
                          color: DuckColors.accentPurple,
                        ),
                      )
                    else
                      Icon(
                        Icons.psychology,
                        size: 12,
                        color: DuckColors.fgFaint,
                      ),
                    const SizedBox(width: 5),
                    Text(
                      widget.isActive ? S.thinkingActive : S.thinkingDone,
                      style: TextStyle(
                        fontSize: 11,
                        color: widget.isActive
                            ? DuckColors.accentPurple
                            : DuckColors.fgSubtle,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                    if (hasContent && !widget.isActive) ...[
                      const SizedBox(width: 2),
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 12,
                        color: DuckColors.fgFaint,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (_expanded && hasContent)
            Padding(
              padding: const EdgeInsets.only(top: 4, left: 4),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                constraints: const BoxConstraints(maxHeight: 200),
                decoration: BoxDecoration(
                  color: DuckColors.bgDeepest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  border: Border.all(
                    color: DuckColors.fgSubtle.withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
                child: SingleChildScrollView(
                  child: Text(
                    widget.content,
                    style: TextStyle(
                      fontSize: 11,
                      color: DuckColors.fgMuted,
                      fontFamily: DuckTheme.monoFont,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
