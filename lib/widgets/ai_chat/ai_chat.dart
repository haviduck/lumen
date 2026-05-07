import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart' as desktop_drop;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/chat_controller.dart';
import '../../providers/media_controller.dart';
import '../../providers/ssh_controller.dart';
import '../../services/chat_persistence_service.dart';
import '../../services/reasoning_effort.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';
import '../common/image_lightbox.dart';
import '../common/media_pane_chrome.dart';
import '../side_panes_column.dart';
import 'approval_card.dart';
import 'chat_tab_strip.dart';
import 'empty_response_strip.dart';
import 'slash_commands/council_command.dart';
import 'message_bubble.dart';
import 'queued_prompts_strip.dart';
import 'slash_commands/push_command.dart';
import 'slash_commands/slash_command.dart';
import 'slash_commands/slash_command_picker.dart';
import 'chat_composer.dart';
import 'chip_text_editing_controller.dart';
import 'stall_warning.dart';

class AiChat extends StatefulWidget {
  const AiChat({super.key});

  @override
  State<AiChat> createState() => _AiChatState();
}

class _ComposerPasteIntent extends Intent {
  const _ComposerPasteIntent();
}

/// Snapshot of "what would the chat-rewind chip on this user bubble
/// actually undo if clicked". Cheap to recompute on every rebuild —
/// the timeline lookup is a linear pass over an in-memory list.
class _ChatRewindData {
  /// Sum of agent-tool timeline entries across every assistant
  /// message at or after the pivot user message. Drives the count
  /// shown in the chip.
  final int fileChangeCount;

  /// Number of messages strictly *after* the pivot user message —
  /// these will be removed alongside the pivot itself when the user
  /// confirms. Surfaced in the tooltip / dialog so the user knows
  /// exactly how much chat history disappears.
  final int followupMessageCount;

  const _ChatRewindData({
    required this.fileChangeCount,
    required this.followupMessageCount,
  });
}

class _AiChatState extends State<AiChat> {
  // Chip-capable composer controller. Replaces the plain
  // `TextEditingController` so files / code-ranges / terminal
  // selections render as inline pill widgets at the caret position
  // (Cursor-style), not as a separate strip above the textarea.
  // See `lib/widgets/ai_chat/chip_text_editing_controller.dart`.
  final ChipTextEditingController _input = ChipTextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode();
  final SlashCommandPickerController _slash = SlashCommandPickerController();
  ChatController? _listenedChat;
  bool _referenceDragOver = false;

  /// Tracks whether the user has scrolled away from the bottom
  /// (e.g. to read history). When `true`, auto-scroll-to-bottom is
  /// suppressed during streaming so we don't yank them back down
  /// every time a chunk arrives. Re-engages when they scroll back
  /// to the bottom (or send a new message — that always snaps).
  ///
  /// 80px tolerance: if you're within 80px of the bottom you're
  /// considered "at the bottom" and updates auto-stick. Anything
  /// further is "reading history" and gets respected.
  bool _userScrolledAway = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _input.addListener(_onComposerTextChanged);
    _slash.addTapListener(_onSlashCommandPicked);
    _registerSlashCommands();
  }

  /// Slash-command registry is process-wide; registering here is
  /// idempotent (later calls overwrite by name) so safe to do on every
  /// `_AiChatState` mount.
  void _registerSlashCommands() {
    SlashCommandRegistry.register(CouncilCommand());
    SlashCommandRegistry.register(CouncilCommand(alias: 'counsil'));
    SlashCommandRegistry.register(PushCommand());
  }

  /// Re-evaluate slash-picker state on every keystroke. Cheap — the
  /// picker controller short-circuits when the input does not start
  /// with `/`.
  void _onComposerTextChanged() {
    if (!mounted) return;
    _slash.updateFromInput(_input.text, overlayContext: context);
  }

  /// Tap-handler bridge: when the user clicks a command in the picker
  /// overlay, route it through the same execution path as a keyboard
  /// pick.
  void _onSlashCommandPicked(SlashCommand cmd) {
    unawaited(_runSlashCommand(cmd));
  }

  /// Execute [cmd], optionally clear the composer, and (if the
  /// command produced expanded text) push it through the normal
  /// `ChatController.sendMessage` pipeline so it walks the same
  /// queue/persist/generation path as a hand-typed message.
  ///
  /// The expanded prompt is sent as the message *content* (so the
  /// model reads it) but the user bubble shows a compact `/cmd`
  /// label via [PersistedMessage.displayContent] — the user is not
  /// forced to scroll past a wall of agent instructions in their own
  /// chat history.
  Future<void> _runSlashCommand(SlashCommand cmd) async {
    if (!mounted) return;
    final appState = context.read<AppState>();
    final chat = appState.chat;
    final raw = _input.text;
    final parsed = SlashCommandInput.tryParse(raw);
    final args = parsed?.args ?? '';
    final ctx = SlashCommandContext(
      buildContext: context,
      chat: chat,
      appState: appState,
      args: args,
    );
    final result = await cmd.run(ctx);
    if (!mounted) return;
    if (result.clearComposer) {
      _input.clear();
    }
    final text = result.textToSend;
    if (text != null && text.isNotEmpty) {
      final display = args.isEmpty ? '/${cmd.name}' : '/${cmd.name} $args';
      chat.sendMessage(
        text,
        workspacePath: appState.currentDirectory,
        activeFilePath: appState.activeFile?.path,
        openFilePaths: appState.openFiles.map((f) => f.path).toList(),
        displayText: display,
      );
      _forceScrollToEnd();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final chat = context.read<AppState>().chat;
    if (identical(_listenedChat, chat)) return;
    _listenedChat?.removeListener(_onChatNotify);
    _listenedChat = chat;
    chat.addListener(_onChatNotify);
    // Initial sync: drain composer insertions and pin the list to
    // the bottom on first mount / tab-switch. Streaming flag is
    // false here intentionally — fresh mounts use the smooth
    // animateTo branch instead of the streaming jumpTo branch.
    _consumeComposerInsertions();
    _autoScrollIfPinned(streaming: false);
  }

  @override
  void dispose() {
    _listenedChat?.removeListener(_onChatNotify);
    _scroll.removeListener(_onScroll);
    _input.removeListener(_onComposerTextChanged);
    _slash.removeTapListener(_onSlashCommandPicked);
    _slash.dispose();
    _input.dispose();
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// Single fan-out callback wired to [ChatController.addListener].
  /// Replaces the older pattern of doing autoscroll work from inside
  /// `build()`.
  ///
  /// Why not in build? `_buildMessageList` used to call
  /// `_autoScrollIfPinned` as a side effect every time the panel
  /// rebuilt — and the panel rebuilds at ~30Hz during streaming
  /// because of the throttled `notifyListeners`. Each call schedules
  /// a `WidgetsBinding.instance.addPostFrameCallback` that fires a
  /// `ScrollController.jumpTo(maxScrollExtent)`. That stacked up
  /// scroll-position writes on top of layout work that was already
  /// expensive (markdown reparse + segment regexes), starving the
  /// raster thread on fast-streaming models. Hooking into the
  /// controller's notify directly fires the autoscroll exactly when
  /// new content actually lands — no per-build overhead.
  void _onChatNotify() {
    if (!mounted) return;
    _consumeComposerInsertions();
    final chat = _listenedChat;
    if (chat == null) return;
    _autoScrollIfPinned(streaming: chat.isGenerating);
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final distFromBottom = pos.maxScrollExtent - pos.pixels;

    // Detect user scrolling UP during streaming. Any upward movement
    // is treated as intent to read history — we disengage auto-scroll
    // immediately (no 80px dead zone) so the scrollbar doesn't fight
    // the user's input with postFrameCallback jumpTo's.
    if (!_userScrolledAway &&
        pos.userScrollDirection == ScrollDirection.forward) {
      // forward = content moving down = user scrolling UP
      setState(() => _userScrolledAway = true);
      return;
    }

    // Re-engage auto-scroll when the user returns close to the bottom.
    final away = distFromBottom > 40;
    if (away != _userScrolledAway) {
      setState(() => _userScrolledAway = away);
    }
  }

  void _consumeComposerInsertions() {
    final chat = _listenedChat;
    if (chat == null) return;
    // Legacy plain-text composer insertions (slash command output,
    // misc programmatic prepends). Kept so non-chip producers still
    // work — but `addPendingReference` no longer pushes here; it
    // routes through `addPendingChip` instead.
    final insertions = chat.consumePendingComposerInsertions();
    for (final token in insertions) {
      _insertReferenceToken(token);
    }
    // Chip insertions: file/folder drops, terminal-selection tooltip,
    // doc/KB drops. Each is appended to the composer's chip list and
    // rendered as a pill above the plain TextField.
    final chipInsertions = chat.consumePendingChipInsertions();
    for (final chip in chipInsertions) {
      _input.addChip(chip);
    }
    if (chipInsertions.isNotEmpty || insertions.isNotEmpty) {
      _focus.requestFocus();
    }
  }

  void _insertReferenceToken(String token) {
    final value = _input.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final safeStart = start < 0
        ? 0
        : (start > text.length ? text.length : start);
    final safeEnd = end < 0 ? 0 : (end > text.length ? text.length : end);
    final low = safeStart < safeEnd ? safeStart : safeEnd;
    final high = safeStart < safeEnd ? safeEnd : safeStart;
    final prefix = low > 0 && !_isWhitespace(text[low - 1]) ? ' ' : '';
    final suffix = high < text.length && !_isWhitespace(text[high]) ? ' ' : '';
    final insertion = '$prefix$token$suffix';
    final nextText = text.replaceRange(low, high, insertion);
    final caret = low + insertion.length;
    _input.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: caret),
    );
    _focus.requestFocus();
  }

  bool _isWhitespace(String char) => RegExp(r'\s').hasMatch(char);

  void _insertTextAtCursor(String insertion) {
    final value = _input.value;
    final text = value.text;
    final selection = value.selection;
    final start = selection.isValid ? selection.start : text.length;
    final end = selection.isValid ? selection.end : text.length;
    final safeStart = start < 0
        ? 0
        : (start > text.length ? text.length : start);
    final safeEnd = end < 0 ? 0 : (end > text.length ? text.length : end);
    final low = safeStart < safeEnd ? safeStart : safeEnd;
    final high = safeStart < safeEnd ? safeEnd : safeStart;
    final nextText = text.replaceRange(low, high, insertion);
    _input.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: low + insertion.length),
    );
    _focus.requestFocus();
  }

  Future<void> _pasteIntoComposer(ChatController chat) async {
    Uint8List? clipboardImage;
    try {
      clipboardImage = await Pasteboard.image;
    } catch (e) {
      debugPrint('Pasteboard.image failed: $e');
    }
    if (clipboardImage != null && clipboardImage.isNotEmpty) {
      _addImageBytes(chat, clipboardImage);
      if (mounted) showDuckToast(context, S.chatImagePasted);
      _focus.requestFocus();
      return;
    }

    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _insertTextAtCursor(text);
  }

  void _addImageBytes(ChatController chat, Uint8List raw) {
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        chat.addPendingImage(base64Encode(raw));
        return;
      }
      final resized = decoded.width > 1280
          ? img.copyResize(decoded, width: 1280)
          : decoded;
      final encoded = img.encodeJpg(resized, quality: 80);
      chat.addPendingImage(base64Encode(encoded));
    } catch (_) {
      chat.addPendingImage(base64Encode(raw));
    }
  }

  Future<void> _attachImage(ChatController chat) async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      final raw =
          f.bytes ??
          (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (raw == null) continue;
      _addImageBytes(chat, raw);
    }
  }

  void _addReferenceToChat(
    ChatController chat,
    String path, {
    String? workspacePath,
  }) {
    final ok = chat.addPendingReference(path, workspacePath: workspacePath);
    if (!ok) {
      showDuckToast(context, S.chatReferenceMissing);
      return;
    }
    showDuckToast(context, S.chatReferenceAdded);
    _focus.requestFocus();
  }

  /// Auto-scroll to the bottom if the user is already near the bottom.
  ///
  /// Two modes, picked by [streaming]:
  /// - `streaming: true` → use `jumpTo` with no delay. Streaming
  ///   chunks arrive at ~30fps; an `animateTo` for each would
  ///   overlap, cancel each other, and jitter visibly. Instant
  ///   jump is the only thing that looks smooth.
  /// - `streaming: false` (new message arrival, send, etc.) →
  ///   `animateTo` after one frame. Smoother for the rare
  ///   "message just landed" case.
  ///
  /// In either mode, **`_userScrolledAway` short-circuits**: if the
  /// user is reading history we do not yank them back to the bottom.
  /// Force-sends (user pressed Send) call `_forceScrollToEnd` instead.
  void _autoScrollIfPinned({required bool streaming}) {
    if (_userScrolledAway) return;
    // Defer to post-frame: the build that just triggered this call
    // hasn't laid out the new content yet, so `maxScrollExtent`
    // would be stale. After the frame, the new chunk's height is
    // measured and scroll jumps to the *real* bottom.
    if (streaming) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients && !_userScrolledAway) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
      return;
    }
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients && !_userScrolledAway) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  /// Scroll to the bottom regardless of `_userScrolledAway` —
  /// called from `send()` because the user just inserted their own
  /// message and almost always wants to see it.
  void _forceScrollToEnd() {
    _userScrolledAway = false;
    Future.delayed(const Duration(milliseconds: 80), () {
      if (_scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _editMessageDialog(ChatController chat, int index) async {
    final msg = chat.messages[index];
    final ctrl = TextEditingController(text: msg.content);
    final saved = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.chatEditMessage),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: ctrl,
            maxLines: 8,
            autofocus: true,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text(S.save),
          ),
        ],
      ),
    );
    if (saved != null) {
      await chat.editMessage(index, saved);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, _) {
        return ChangeNotifierProvider.value(
          value: appState.chat,
          child: Consumer<ChatController>(
            builder: (context, chat, _) {
              return DuckGlass(
                border: const Border(
                  left: BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
                child: Column(
                  children: [
                    // Watch-media renders here whenever the
                    // EFFECTIVE placement is `chat`. That's true
                    // either because the user explicitly chose
                    // chat-placement, OR because SSH/Teams is
                    // currently occupying the side stack and watch
                    // has been forced to the chat panel (see
                    // `SidePanesColumn.watchForcedToChat` for the
                    // rule). The two cases produce the same visual
                    // — the user just sees their video in the
                    // chat panel — so we don't differentiate.
                    Consumer2<MediaController, SshController>(
                      builder: (context, media, ssh, _) {
                        if (!media.hasMedia) {
                          return const SizedBox.shrink();
                        }
                        final forced = SidePanesColumn.watchForcedToChat(
                          ssh: ssh,
                          media: media,
                        );
                        final renderHere =
                            media.placement == MediaPlacement.chat || forced;
                        if (!renderHere) return const SizedBox.shrink();
                        return _buildChatMediaPanel(media);
                      },
                    ),
                    ChatTabStrip(chat: chat),
                    // When every chat tab is closed there's no
                    // session to type into — rendering the
                    // composer below an empty message list reads
                    // as broken. Replace the entire body with a
                    // centered "No chat open" placeholder + a
                    // primary "New chat" button + the model
                    // picker. The user lands somewhere actionable
                    // instead of staring at a stranded text box.
                    if (chat.openTabs.isEmpty)
                      Expanded(
                        child: _EmptyChatPlaceholder(
                          chat: chat,
                          onNewChat: () => chat.newSession(
                            workspacePath: appState.currentDirectory,
                          ),
                        ),
                      )
                    else ...[
                      Expanded(child: _buildMessageList(chat)),
                      // Empty-response strip — surfaces after a
                      // turn ends with no visible content / tools
                      // / errors. Distinct from the stall strip
                      // (stall = mid-stream silence; empty =
                      // post-completion). Two buttons: Continue
                      // (re-prompts the model) and Dismiss.
                      EmptyResponseStrip(controller: chat),
                      // Pending approval strip — docked above the
                      // input, like Cursor's "Run command? [yes/no]"
                      // strip. Only renders when the controller has
                      // a pending request. Stays compact (single
                      // row by default; expandable to show full
                      // multi-line commands).
                      if (chat.pendingApproval != null)
                        ApprovalStrip(
                          controller: chat,
                          approval: chat.pendingApproval!,
                        ),
                      // Audit banner — when the most recent silent
                      // approval is fresh (≤30s), surface a tiny
                      // "X auto-approved by Y" strip so the user
                      // sees what just bypassed the gate.
                      _buildSilentApprovalBanner(chat),
                      // Queued-prompts strip — only renders when
                      // the user has typed follow-ups while the
                      // current generation was still in flight.
                      QueuedPromptsStrip(controller: chat),
                      // Pending file/folder/code/terminal references
                      // now render as inline chips inside the
                      // composer's `TextField` itself (chip schema:
                      // `lib/services/chat_chip.dart`). The strip is
                      // only used for image attachments these days —
                      // images can't be inlined into a text run.
                      if (chat.pendingImages.isNotEmpty)
                        _buildAttachmentStrip(chat),
                      _buildInput(appState, chat),
                    ],
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  /// Render the chat-placement media panel. Shared chrome row +
  /// a `Webview` whose height scales with the chat panel's current
  /// width (clamped between 160px floor / 360px ceiling so the
  /// video can't either disappear or eat the whole panel). When the
  /// user drags the chat panel wider, the embedded video grows
  /// taller proportionally — the "scale the chat bar" behaviour the
  /// user asked for.
  ///
  /// The chrome lives in `widgets/editor/editor.dart` as
  /// `_MediaPaneChrome` so the chat + editor placements share the
  /// same buttons (mute, zoom, open-in-browser, close).
  Widget _buildChatMediaPanel(MediaController media) {
    return Column(
      children: [
        MediaPaneChrome(media: media, height: 24),
        LayoutBuilder(
          builder: (context, constraints) {
            final w = constraints.maxWidth;
            // 16:9 ideal, clamped to keep the chat usable. Floor at
            // 160 so the player is never useless; ceiling at 360 so
            // an over-wide chat panel doesn't drown the message list.
            final h = (w * 9 / 16).clamp(160.0, 360.0);
            return SizedBox(
              width: double.infinity,
              height: h,
              child: Webview(media.webview),
            );
          },
        ),
      ],
    );
  }

  Widget _buildMessageList(ChatController chat) {
    final appState = context.read<AppState>();
    final msgs = chat.messages;
    // Autoscroll is driven by [_onChatNotify] (controller listener)
    // rather than from inside build — keeping side effects out of
    // build was a measurable win on fast streams. See the listener's
    // docstring for the full rationale.
    // SelectionArea wraps the entire list so the user can drag-select
    // across multiple message bubbles and Ctrl+C the whole range.
    // Each `MessageBubble` deliberately uses non-selectable Text /
    // MarkdownBody (selectable=false) so this area governs alone —
    // mixing inner `SelectableText` with `SelectionArea` breaks
    // cross-bubble drag selection.
    return SelectionArea(
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        // Approval is no longer rendered inside the message list — it
        // landed there originally as a "card" but always felt heavy
        // and broke the conversation flow when it appeared. Now it's
        // a chrome strip docked above the input (`ApprovalStrip`),
        // out of the conversation, in keeping with how Cursor / VS
        // Code surface terminal-permission prompts.
        itemCount: msgs.length,
        itemBuilder: (context, index) {
          final m = msgs[index];
          // The "live" message is the LAST assistant message *while*
          // chat.isGenerating. Anything else is finished content.
          final isLast = index == msgs.length - 1;
          final isStreaming =
              chat.isGenerating && isLast && m.role == 'assistant';
          final legacyMessageId =
              '${chat.currentSession?.id}@${m.timestamp.microsecondsSinceEpoch}';

          // Two restore surfaces:
          //  - assistant bubble → "undo just this turn's file changes"
          //    (no chat truncation). Counts entries for THIS message.
          //  - user bubble → Cursor / Antigravity-style "rewind chat
          //    to before I sent this". Counts the union of entries
          //    for every assistant message AT or AFTER this user
          //    message PLUS the number of follow-up messages that
          //    will be removed.
          final BubbleRestoreScope scope;
          final int restoreCount;
          final int followupCount;
          final VoidCallback? onRestore;
          if (m.role == 'user') {
            scope = BubbleRestoreScope.chatRewind;
            final gathered = _gatherChatRewindData(appState, chat, msgs, index);
            restoreCount = gathered.fileChangeCount;
            followupCount = gathered.followupMessageCount;
            // Show the chip when there's *anything* to revert — file
            // changes or just messages. Don't show on the trailing
            // user bubble that has nothing after it (nothing to
            // rewind to).
            final canRewind =
                !isStreaming && (restoreCount > 0 || followupCount > 0);
            onRestore = canRewind
                ? () => _confirmAndRewindChat(appState, index, gathered)
                : null;
          } else {
            scope = BubbleRestoreScope.assistantTurn;
            final entries = appState.timeline.entriesForMessage(
              m.id,
              legacyMessageId: legacyMessageId,
            );
            restoreCount = entries.length;
            followupCount = 0;
            onRestore = entries.isNotEmpty && !isStreaming
                ? () => _restoreMessageChanges(appState, m, legacyMessageId)
                : null;
          }

          // Streaming-only Column wrap: attaches the muted stall
          // footer beneath the live assistant bubble. Skipping the
          // wrap on non-streaming last messages avoids stranding an
          // empty `SizedBox.shrink()` inside an extra Column on
          // every finished turn (the strip short-circuits when
          // silenceDuration is null, which is the case whenever
          // !isGenerating).
          if (isStreaming) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MessageBubble(
                  message: m,
                  isUser: m.role == 'user',
                  isStreaming: isStreaming,
                  restoreChangeCount: restoreCount,
                  restoreScope: scope,
                  restoreFollowupMessages: followupCount,
                  onRestore: onRestore,
                  onEdit: m.role == 'user'
                      ? () => _editMessageDialog(chat, index)
                      : null,
                  onDelete: () => chat.deleteMessage(index),
                ),
                StallWarningStrip(controller: chat),
              ],
            );
          }
          return MessageBubble(
            message: m,
            isUser: m.role == 'user',
            isStreaming: isStreaming,
            restoreChangeCount: restoreCount,
            restoreScope: scope,
            restoreFollowupMessages: followupCount,
            onRestore: onRestore,
            onEdit: m.role == 'user'
                ? () => _editMessageDialog(chat, index)
                : null,
            onDelete: () => chat.deleteMessage(index),
          );
        },
      ),
    );
  }

  /// Compute the data the user-bubble revert chip needs: how many
  /// agent file changes will be reverted, and how many messages will
  /// be removed from the chat. We walk every message at index
  /// `>= userIndex`; assistants contribute file-change entries, the
  /// pivot user message itself contributes only to the truncation
  /// count.
  _ChatRewindData _gatherChatRewindData(
    AppState appState,
    ChatController chat,
    List<PersistedMessage> msgs,
    int userIndex,
  ) {
    var fileChangeCount = 0;
    final followups = msgs.length - userIndex - 1;
    for (var i = userIndex; i < msgs.length; i++) {
      final m = msgs[i];
      if (m.role != 'assistant') continue;
      final legacy =
          '${chat.currentSession?.id}@${m.timestamp.microsecondsSinceEpoch}';
      fileChangeCount += appState.timeline
          .entriesForMessage(m.id, legacyMessageId: legacy)
          .length;
    }
    return _ChatRewindData(
      fileChangeCount: fileChangeCount,
      followupMessageCount: followups,
    );
  }

  /// Confirm + execute a Cursor / Antigravity-style chat rewind.
  /// Truncates the session at [userIndex] (so the pivot user message
  /// AND every message after it are gone), restores all agent file
  /// changes from the dropped messages, pre-fills the composer with
  /// the user's prompt text, and re-focuses it so the user can edit
  /// and re-send in one stroke.
  Future<void> _confirmAndRewindChat(
    AppState appState,
    int userIndex,
    _ChatRewindData data,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(S.chatRewindConfirmTitle),
        content: Text(
          S.chatRewindConfirmBody(
            data.fileChangeCount,
            data.followupMessageCount + 1,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentDuck,
              foregroundColor: DuckColors.bgDeepest,
            ),
            child: const Text(S.chatRewindAction),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final outcome = await appState.revertChatToBeforeMessage(userIndex);
    if (!mounted) return;
    if (outcome.composerPrefill != null) {
      _input.text = outcome.composerPrefill!;
      _input.selection = TextSelection.fromPosition(
        TextPosition(offset: _input.text.length),
      );
      _focus.requestFocus();
    }
    showDuckToast(context, outcome.message);
  }

  Future<void> _restoreMessageChanges(
    AppState appState,
    PersistedMessage message,
    String legacyMessageId,
  ) async {
    final count = appState.timeline
        .entriesForMessage(message.id, legacyMessageId: legacyMessageId)
        .length;
    if (count == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(S.chatRestoreConfirmTitle),
        content: Text(S.chatRestoreConfirmBody(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentDuck,
              foregroundColor: DuckColors.bgDeepest,
            ),
            child: const Text(S.backupRestore),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final msg = await appState.restoreTimelineChangesForMessage(
      message.id,
      legacyMessageId: legacyMessageId,
    );
    if (!mounted) return;
    showDuckToast(context, msg);
  }

  /// Tiny "just auto-approved" banner above the input strip.
  ///
  /// Only renders when there's a silent approval less than 30s old
  /// — long enough for the user to see it land, short enough that
  /// stale entries don't clutter the panel. Click opens settings →
  /// always-allowed tools so the rule can be revoked. Stays
  /// dismissed via the manual `clearAutoApprovedTools` if the user
  /// wants the warning gone immediately.
  Widget _buildSilentApprovalBanner(ChatController chat) {
    if (chat.recentSilentApprovals.isEmpty) return const SizedBox.shrink();
    final latest = chat.recentSilentApprovals.first;
    final age = DateTime.now().difference(latest.when);
    if (age > const Duration(seconds: 30)) return const SizedBox.shrink();
    final detailShort = latest.detail.length > 60
        ? '${latest.detail.substring(0, 60)}…'
        : latest.detail;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
          left: BorderSide(color: DuckColors.stateWarn, width: 2),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.shield_outlined,
            size: 12,
            color: DuckColors.stateWarn,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${latest.toolId} auto-ran (${latest.reason}): $detailShort',
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
          // Revoke this specific tool's blanket approval (no-op if
          // the bypass came from the global `_autoApprove` switch
          // — that's flipped from Settings).
          InkWell(
            onTap: () => chat.setToolAutoApproved(latest.toolId, false),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              child: Text(
                'Revoke',
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.accentCyan,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAttachmentStrip(ChatController chat) {
    // Pending file/folder/code/terminal references render as inline
    // chips inside the composer's `TextField` (chip schema lives in
    // `lib/services/chat_chip.dart`). The strip is now image-only;
    // we still consult `pendingReferences` only to show a count badge
    // when chips have been mirrored from drag-drop, but the visual
    // wrap of reference rows is gone — the chips ARE the UI.
    final refs = const <ChatReference>[];
    final images = chat.pendingImages;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      // Mint left-edge stripe groups this strip visually with markdown
      // blockquotes (which use the same mint accent) — pulls the eye
      // when there are pending attachments without colouring the bg.
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
          left: BorderSide(color: DuckColors.accentMint, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.attach_file,
                size: 12,
                color: DuckColors.accentMint,
              ),
              const SizedBox(width: 6),
              Text(
                [
                  if (chat.pendingImages.isNotEmpty)
                    S.chatImagesAttached(chat.pendingImages.length),
                  if (refs.isNotEmpty) S.chatReferencesAttached(refs.length),
                ].join(' • '),
                style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
              ),
              const Spacer(),
              InkWell(
                onTap: () {
                  chat.clearPendingImages();
                  chat.clearPendingReferences();
                },
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ),
            ],
          ),
          if (images.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: images.asMap().entries.map((entry) {
                final index = entry.key;
                return _PendingImageChip(
                  base64Image: entry.value,
                  onRemove: () => chat.removePendingImageAt(index),
                );
              }).toList(),
            ),
          ],
          if (refs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: refs
                  .map(
                    (ref) => _ReferenceChip(
                      reference: ref,
                      onRemove: () => chat.removePendingReference(ref),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildInput(AppState appState, ChatController chat) {
    void send() {
      final text = _input.text;
      // Slash-command path: intercept BEFORE the empty-input guard so
      // a bare slash command (with no other content) still runs even
      // when there are no pending refs/images. The picker may or may
      // not be open here — pressing Enter always tries to resolve a
      // slash if the input parses as one.
      if (_slash.isOpen) {
        final picked = _slash.pickHighlighted();
        if (picked != null) {
          unawaited(_runSlashCommand(picked));
          return;
        }
      }
      final parsed = SlashCommandInput.tryParse(text);
      if (parsed != null && parsed.name.isNotEmpty) {
        final exact = SlashCommandRegistry.findExact(parsed.name);
        if (exact != null) {
          unawaited(_runSlashCommand(exact));
          return;
        }
      }

      if (text.trim().isEmpty &&
          chat.pendingImages.isEmpty &&
          chat.pendingReferences.isEmpty) {
        return;
      }
      _input.clear();
      chat.sendMessage(
        text,
        workspacePath: appState.currentDirectory,
        activeFilePath: appState.activeFile?.path,
        openFilePaths: appState.openFiles.map((f) => f.path).toList(),
      );
      _forceScrollToEnd();
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Model badge row, above the text box ──
          //
          // Layout: [picker] [Spacer] [settings cog]. The picker
          // self-bounds (its internal LayoutBuilder clamps to 160 px),
          // so we deliberately do NOT wrap it in `Flexible` /
          // `Expanded` here — those would hand the picker half the
          // row width, of which it would only USE 160, leaving a
          // dead chunk between picker and Spacer. The result was a
          // settings cog that drifted to ~70% of the row width
          // instead of hugging the right edge after a panel resize.
          // Plain widget + Spacer puts the cog at the actual right.
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                _ModelPicker(chat: chat),
                const Spacer(),
                Tooltip(
                  message: S.chatOpenAiSettings,
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: InkWell(
                      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      onTap: () => appState.openSettingsTab(category: 'aiChat'),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.settings_outlined,
                          size: 15,
                          color: DuckColors.fgMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // ── Chat input box ──
          DragTarget<String>(
            onWillAcceptWithDetails: (details) {
              final path = details.data;
              final exists =
                  FileSystemEntity.isFileSync(path) ||
                  FileSystemEntity.isDirectorySync(path);
              if (exists) setState(() => _referenceDragOver = true);
              return exists;
            },
            onLeave: (_) => setState(() => _referenceDragOver = false),
            onAcceptWithDetails: (details) {
              setState(() => _referenceDragOver = false);
              _addReferenceToChat(
                chat,
                details.data,
                workspacePath: appState.currentDirectory,
              );
            },
            builder: (context, candidateData, rejectedData) {
              return desktop_drop.DropTarget(
                onDragEntered: (_) => setState(() => _referenceDragOver = true),
                onDragExited: (_) => setState(() => _referenceDragOver = false),
                onDragDone: (details) {
                  setState(() => _referenceDragOver = false);
                  for (final file in details.files) {
                    _addReferenceToChat(
                      chat,
                      file.path,
                      workspacePath: appState.currentDirectory,
                    );
                  }
                },
                child: _buildComposerBox(chat, send),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildComposerBox(ChatController chat, VoidCallback send) {
    return CompositedTransformTarget(
      link: _slash.layerLink,
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        curve: DuckMotion.standard,
        decoration: BoxDecoration(
          color: DuckColors.bgChip,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(
            color: _referenceDragOver
                ? DuckColors.accentMint
                : chat.isGenerating
                ? DuckColors.accentCyan
                : DuckColors.border,
          ),
          boxShadow: chat.isGenerating || _referenceDragOver
              ? DuckTheme.shadowGlow
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ChatComposerChipsStrip(
              controller: _input,
              dragHighlighted: _referenceDragOver,
            ),
            Shortcuts(
              shortcuts: const <ShortcutActivator, Intent>{
                SingleActivator(LogicalKeyboardKey.keyV, control: true):
                    _ComposerPasteIntent(),
              },
              child: Actions(
                actions: <Type, Action<Intent>>{
                  _ComposerPasteIntent: CallbackAction<_ComposerPasteIntent>(
                    onInvoke: (_) {
                      unawaited(_pasteIntoComposer(chat));
                      return null;
                    },
                  ),
                },
                child: Focus(
                  onKeyEvent: (node, event) {
                    if (_slash.onKey(event) == SlashKeyHandling.handled) {
                      return KeyEventResult.handled;
                    }
                    if (event is KeyDownEvent &&
                        event.logicalKey == LogicalKeyboardKey.enter) {
                      if (!HardwareKeyboard.instance.isShiftPressed) {
                        send();
                        return KeyEventResult.handled;
                      }
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    focusNode: _focus,
                    controller: _input,
                    maxLines: 8,
                    minLines: 2,
                    textInputAction: TextInputAction.newline,
                    style: const TextStyle(
                      fontSize: 13,
                      color: DuckColors.fgPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: S.chatPlaceholder,
                      hintStyle: TextStyle(
                        color: DuckColors.fgMuted,
                        fontSize: 13,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      fillColor: Colors.transparent,
                      filled: false,
                      contentPadding: EdgeInsets.fromLTRB(12, 10, 12, 4),
                    ),
                  ),
                ),
              ),
            ),
            // ── Bottom action row: attach + send/stop ──
            Padding(
              padding: const EdgeInsets.only(left: 8, right: 6, bottom: 4),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 230;
                  return Row(
                    children: [
                      Tooltip(
                        message: S.chatAttachImage,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: InkWell(
                            borderRadius: BorderRadius.circular(
                              DuckTheme.radiusS,
                            ),
                            onTap: () => _attachImage(chat),
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.attach_file,
                                size: 15,
                                color: DuckColors.fgMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                      // Reasoning-effort dial — sits between attach
                      // and auto-approve. Cycles Off → Standard →
                      // Deep on tap. Translates to a real native
                      // API param (Anthropic `thinking`, Gemini
                      // `thinkingConfig`, OpenAI `reasoning_effort`)
                      // when the active model supports it; falls
                      // back to a system-prompt directive on
                      // non-Ollama models that lack native support
                      // (Haiku, gpt-4o, Gemini 2.0). The pill flags
                      // which mode is in effect via tooltip wording.
                      //
                      // Hidden entirely on Ollama / Ollama Cloud:
                      // Ollama auto-enables thinking for capable
                      // models server-side (per
                      // https://docs.ollama.com/capabilities/thinking)
                      // and the dial's only effect there would have
                      // been a weak prompt-suffix directive that
                      // small local models routinely ignore. Showing
                      // a control that does nothing real is dishonest
                      // UX — see
                      // `ChatController.reasoningEffortPillApplicableForCurrentModel`.
                      if (chat
                          .reasoningEffortPillApplicableForCurrentModel) ...[
                        const SizedBox(width: 4),
                        _ReasoningEffortPill(
                          effort: chat.reasoningEffort,
                          isNative: chat.reasoningEffortIsNativeForCurrentModel,
                          compact: compact,
                          onCycle: () => chat.setReasoningEffort(
                            _cycleEffort(chat.reasoningEffort),
                          ),
                        ),
                      ],
                      const SizedBox(width: 4),
                      // Auto-approve toggle pill — full label at normal
                      // chat widths; icon-only below ~230px so the
                      // composer never overflows when the sidebar is
                      // intentionally squeezed narrow.
                      Flexible(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _AutoApproveTogglePill(
                            on: chat.autoApprove,
                            compact: compact,
                            onChanged: () =>
                                chat.setAutoApprove(!chat.autoApprove),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      if (chat.isGenerating)
                        Tooltip(
                          message: S.chatStop,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                DuckTheme.radiusS,
                              ),
                              onTap: chat.cancelGeneration,
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.stop_circle,
                                  size: 17,
                                  color: DuckColors.stateError,
                                ),
                              ),
                            ),
                          ),
                        )
                      else
                        Tooltip(
                          message: S.chatSend,
                          child: MouseRegion(
                            cursor: SystemMouseCursors.click,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(
                                DuckTheme.radiusS,
                              ),
                              onTap: send,
                              child: const Padding(
                                padding: EdgeInsets.all(4),
                                child: Icon(
                                  Icons.send,
                                  size: 17,
                                  color: DuckColors.accentCyan,
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ReferenceChip extends StatelessWidget {
  final ChatReference reference;
  final VoidCallback? onRemove;

  const _ReferenceChip({required this.reference, this.onRemove});

  @override
  Widget build(BuildContext context) {
    final isFolder = reference.kind == ChatReferenceKind.folder;
    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.only(left: 8, right: 4, top: 4, bottom: 4),
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
          if (onRemove != null) ...[
            const SizedBox(width: 2),
            InkWell(
              onTap: onRemove,
              borderRadius: BorderRadius.circular(999),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 11, color: DuckColors.fgSubtle),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PendingImageChip extends StatelessWidget {
  final String base64Image;
  final VoidCallback onRemove;

  const _PendingImageChip({required this.base64Image, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(base64Image);
    } catch (_) {
      bytes = null;
    }

    return Tooltip(
      message: S.imageLightboxOpenHint,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: bytes == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Container(
          width: 64,
          height: 64,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.border, width: 0.5),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: bytes == null
                    ? const Icon(
                        Icons.image_not_supported_outlined,
                        size: 18,
                        color: DuckColors.fgSubtle,
                      )
                    : GestureDetector(
                        onTap: () => ImageLightbox.show(
                          context,
                          base64Image: base64Image,
                        ),
                        child: Image.memory(bytes, fit: BoxFit.cover),
                      ),
              ),
              Positioned(
                top: 3,
                right: 3,
                child: InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 12,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModelSelectionPanel extends StatefulWidget {
  final ChatController chat;
  const _ModelSelectionPanel({required this.chat});

  @override
  State<_ModelSelectionPanel> createState() => _ModelSelectionPanelState();
}

class _ModelSelectionPanelState extends State<_ModelSelectionPanel> {
  String? _provider;

  @override
  void initState() {
    super.initState();
    final providers = _providers(widget.chat.availableModels);
    _provider = providers.isNotEmpty ? providers.first : null;
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final providers = _providers(chat.availableModels);
    _provider ??= providers.isNotEmpty ? providers.first : null;
    final provider = _provider;
    final providerModels = provider == null
        ? const <String>[]
        : chat.availableModels
              .where((m) => _providerOf(m) == provider)
              .toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: Container(
        width: 560,
        height: 520,
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(color: DuckColors.borderStrong, width: 0.5),
          boxShadow: DuckTheme.shadowSoft,
        ),
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.auto_awesome,
                    size: 16,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 10),
                  const Text(S.chatModelManageTitle, style: DuckTheme.titleS),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 170,
                    child: _ProviderColumn(
                      providers: providers,
                      selected: provider,
                      onPick: (p) => setState(() => _provider = p),
                      countFor: (p) => chat.availableModels
                          .where((m) => _providerOf(m) == p)
                          .length,
                      enabledCountFor: (p) => chat.availableModels
                          .where(
                            (m) =>
                                _providerOf(m) == p &&
                                chat.enabledModels.contains(m),
                          )
                          .length,
                    ),
                  ),
                  Container(width: 0.5, color: DuckColors.glassSeam),
                  Expanded(
                    child: _ProviderModelsColumn(
                      provider: provider,
                      models: providerModels,
                      selected: chat.selectedModel,
                      enabledModels: chat.enabledModels,
                      onEnableAll: provider == null
                          ? null
                          : () async {
                              await chat.setProviderModelsEnabled(
                                provider,
                                true,
                              );
                              if (mounted) setState(() {});
                            },
                      onDisableAll: provider == null
                          ? null
                          : () async {
                              await chat.setProviderModelsEnabled(
                                provider,
                                false,
                              );
                              if (mounted) setState(() {});
                            },
                      onToggle: (model, enabled) async {
                        await chat.setModelEnabled(model, enabled);
                        if (mounted) setState(() {});
                      },
                      onPick: (m) => Navigator.pop(context, m),
                    ),
                  ),
                ],
              ),
            ),
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(S.close),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static List<String> _providers(List<String> models) {
    final set = <String>{for (final m in models) _providerOf(m)};
    // Keep `ollama-cloud` adjacent to `ollama` — same conceptual
    // provider, two namespaces.
    final order = [
      'ollama',
      'ollama-cloud',
      'gemini',
      'claude',
      'copilot',
      'openai',
    ];
    return set.toList()..sort((a, b) {
      final ai = order.indexOf(a);
      final bi = order.indexOf(b);
      if (ai != -1 || bi != -1) {
        return (ai == -1 ? 999 : ai).compareTo(bi == -1 ? 999 : bi);
      }
      return a.compareTo(b);
    });
  }
}

class _ProviderColumn extends StatelessWidget {
  final List<String> providers;
  final String? selected;
  final ValueChanged<String> onPick;
  final int Function(String provider) countFor;
  final int Function(String provider) enabledCountFor;
  const _ProviderColumn({
    required this.providers,
    required this.selected,
    required this.onPick,
    required this.countFor,
    required this.enabledCountFor,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(S.chatModelProvidersTitle, style: DuckTheme.titleS),
          const SizedBox(height: 8),
          for (final p in providers)
            _ProviderRow(
              provider: p,
              selected: p == selected,
              enabledCount: enabledCountFor(p),
              totalCount: countFor(p),
              onTap: () => onPick(p),
            ),
        ],
      ),
    );
  }
}

class _ProviderModelsColumn extends StatelessWidget {
  final String? provider;
  final List<String> models;
  final String selected;
  final Set<String> enabledModels;
  final Future<void> Function()? onEnableAll;
  final Future<void> Function()? onDisableAll;
  final Future<void> Function(String model, bool enabled) onToggle;
  final ValueChanged<String> onPick;
  const _ProviderModelsColumn({
    required this.provider,
    required this.models,
    required this.selected,
    required this.enabledModels,
    this.onEnableAll,
    this.onDisableAll,
    required this.onToggle,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            provider == null
                ? S.chatModelProviderModelsTitle
                : _prettyProvider(provider!),
            style: DuckTheme.titleS,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton(
                onPressed: onEnableAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                ),
                child: const Text(S.chatModelEnableAll),
              ),
              const SizedBox(width: 6),
              TextButton(
                onPressed: onDisableAll,
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  minimumSize: const Size(0, 28),
                  foregroundColor: DuckColors.fgMuted,
                ),
                child: const Text(S.chatModelDisableAll),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Expanded(
            child: ListView.builder(
              itemCount: models.length,
              itemBuilder: (context, i) {
                final m = models[i];
                return _ModelRow(
                  model: _rawModelName(m),
                  selected: m == selected,
                  enabled: enabledModels.contains(m),
                  showSwitch: true,
                  onPick: enabledModels.contains(m) ? () => onPick(m) : null,
                  onToggle: (v) => onToggle(m, v),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  final String provider;
  final bool selected;
  final int enabledCount;
  final int totalCount;
  final VoidCallback onTap;
  const _ProviderRow({
    required this.provider,
    required this.selected,
    required this.enabledCount,
    required this.totalCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: Border.all(
            color: selected ? DuckColors.accentCyan : Colors.transparent,
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _prettyProvider(provider),
                style: TextStyle(
                  fontSize: 12,
                  color: selected ? DuckColors.fgPrimary : DuckColors.fgMuted,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            Text(
              '$enabledCount/$totalCount',
              style: const TextStyle(fontSize: 10, color: DuckColors.fgSubtle),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelRow extends StatelessWidget {
  final String model;
  final bool selected;
  final bool enabled;
  final bool showSwitch;
  final VoidCallback? onPick;
  final ValueChanged<bool>? onToggle;
  const _ModelRow({
    required this.model,
    required this.selected,
    required this.enabled,
    required this.showSwitch,
    this.onPick,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPick,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? DuckColors.accentCyan.withValues(alpha: 0.10)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          children: [
            Icon(
              selected ? Icons.check_circle : Icons.circle_outlined,
              size: 13,
              color: selected ? DuckColors.accentCyan : DuckColors.fgSubtle,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                model,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: enabled ? DuckColors.fgPrimary : DuckColors.fgSubtle,
                ),
              ),
            ),
            if (showSwitch)
              Transform.scale(
                scale: 0.72,
                child: Switch(
                  value: enabled,
                  onChanged: onToggle,
                  activeThumbColor: DuckColors.accentCyan,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

String _providerOf(String model) {
  final idx = model.indexOf(':');
  return idx > 0 ? model.substring(0, idx) : 'ollama';
}

String _rawModelName(String model) {
  final idx = model.indexOf(':');
  return idx > 0 ? model.substring(idx + 1) : model;
}

String _prettyProvider(String provider) {
  return switch (provider) {
    'ollama' => S.providerOllama,
    'ollama-cloud' => S.providerOllamaCloud,
    'gemini' => S.providerGemini,
    'claude' => S.providerClaude,
    'copilot' => S.providerCopilot,
    'openai' => S.providerOpenAI,
    _ => provider,
  };
}

/// Placeholder shown in the chat panel body when the user has closed
/// every tab. Replaces the message list + composer entirely (rendering
/// an empty composer below an empty message list reads as broken /
/// half-loaded). Provides two actions:
///
/// - **New chat** — calls `chat.newSession(workspacePath: ...)` to
///   spawn a fresh tab in the current workspace. Same path the
///   ChatTabStrip's `+` button takes; we just surface it with more
///   visual weight here because the strip's `+` is easy to miss when
///   the user has just closed their last tab.
/// - **Model picker** — reuses the existing `_ModelPicker` widget so
///   tapping it opens the same compact enabled-models popup that the
///   composer would; "View all models" still lands in the full
///   `_ModelSelectionPanel`. Lets the user adjust the model BEFORE
///   spawning the new chat (otherwise they'd have to spawn → switch
///   → notice the answer's already mid-stream from the wrong model).
class _EmptyChatPlaceholder extends StatelessWidget {
  final ChatController chat;
  final VoidCallback onNewChat;

  const _EmptyChatPlaceholder({required this.chat, required this.onNewChat});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Soft cyan disc + sparkle icon — same accent the
              // streaming-cursor / send-button use, so the empty
              // state visually anchors to the chat panel's primary
              // colour without screaming for attention.
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: DuckColors.accentCyan.withValues(alpha: 0.08),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: DuckColors.accentCyan.withValues(alpha: 0.25),
                    width: 0.5,
                  ),
                ),
                child: const Icon(
                  Icons.auto_awesome_outlined,
                  size: 26,
                  color: DuckColors.accentCyan,
                ),
              ),
              const SizedBox(height: 18),
              const Text(
                S.chatEmptyHeading,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.fgPrimary,
                ),
              ),
              const SizedBox(height: 6),
              const Text(
                S.chatEmptySubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgMuted,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 20),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _NewChatPrimaryButton(onTap: onNewChat),
                  const SizedBox(width: 8),
                  // Reuse the composer's model picker — same dropdown
                  // mechanics, same "(unavailable)" suffix when the
                  // selected model isn't in the current available
                  // list. Wrapping in a tinted Container so it reads
                  // as a sibling button to the primary above instead
                  // of a flat label.
                  _EmptyStateModelPickerWrapper(chat: chat),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NewChatPrimaryButton extends StatelessWidget {
  final VoidCallback onTap;
  const _NewChatPrimaryButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.chatEmptyNewChatTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: DuckColors.accentCyan.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(
                  color: DuckColors.accentCyan.withValues(alpha: 0.45),
                  width: 0.5,
                ),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 14, color: DuckColors.accentCyan),
                  SizedBox(width: 6),
                  Text(
                    S.chatEmptyNewChat,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.accentCyan,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Thin tinted wrapper around `_ModelPicker` so it visually sits
/// next to `_NewChatPrimaryButton` as a sibling action. Without the
/// wrapper the picker reads as flat label text and the button
/// dominates the row.
class _EmptyStateModelPickerWrapper extends StatelessWidget {
  final ChatController chat;
  const _EmptyStateModelPickerWrapper({required this.chat});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.bgRaisedHi.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      child: _ModelPicker(chat: chat),
    );
  }
}

/// Cycle order for the reasoning-effort pill: Off → Standard → Deep
/// → Off. Centralised so the on-tap callback in the composer and any
/// future menu / shortcut share the exact same transition table.
ReasoningEffort _cycleEffort(ReasoningEffort current) {
  switch (current) {
    case ReasoningEffort.off:
      return ReasoningEffort.standard;
    case ReasoningEffort.standard:
      return ReasoningEffort.deep;
    case ReasoningEffort.deep:
      return ReasoningEffort.off;
  }
}

/// Reasoning-effort dial in the chat composer. Tap cycles Off →
/// Standard → Deep → Off; the icon + tint communicate state at a
/// glance. When the active model supports a native reasoning param
/// (Claude 4+, Gemini 2.5, gpt-5/o-series), the dial flips that API
/// knob directly. When it doesn't (Ollama, older OpenAI chat models,
/// Claude Haiku), the dial falls back to a system-prompt directive —
/// the tooltip wording flags this honestly so users can see whether
/// the knob is doing real work or just nudging the prompt.
///
/// Visual states (purple is the Nord accent — distinct from the cyan
/// auto-approve pill so the two pills don't visually merge):
/// - OFF: muted brain glyph, no label tint, no track.
/// - STANDARD: half-tinted brain, soft purple label.
/// - DEEP: solid purple brain + small bolt pip, bold purple label.
class _ReasoningEffortPill extends StatelessWidget {
  final ReasoningEffort effort;
  final bool isNative;
  final bool compact;
  final VoidCallback onCycle;

  const _ReasoningEffortPill({
    required this.effort,
    required this.isNative,
    required this.compact,
    required this.onCycle,
  });

  String _tooltipFor(ReasoningEffort e, bool native) {
    if (native) {
      return switch (e) {
        ReasoningEffort.off => S.chatEffortTooltipOffNative,
        ReasoningEffort.standard => S.chatEffortTooltipStandardNative,
        ReasoningEffort.deep => S.chatEffortTooltipDeepNative,
      };
    }
    return switch (e) {
      ReasoningEffort.off => S.chatEffortTooltipOffPrompt,
      ReasoningEffort.standard => S.chatEffortTooltipStandardPrompt,
      ReasoningEffort.deep => S.chatEffortTooltipDeepPrompt,
    };
  }

  String _label(ReasoningEffort e, bool compact) {
    if (compact) {
      return switch (e) {
        ReasoningEffort.off => S.chatEffortLabelOffCompact,
        ReasoningEffort.standard => S.chatEffortLabelStandardCompact,
        ReasoningEffort.deep => S.chatEffortLabelDeepCompact,
      };
    }
    return switch (e) {
      ReasoningEffort.off => S.chatEffortLabelOff,
      ReasoningEffort.standard => S.chatEffortLabelStandard,
      ReasoningEffort.deep => S.chatEffortLabelDeep,
    };
  }

  @override
  Widget build(BuildContext context) {
    final on = effort != ReasoningEffort.off;
    final deep = effort == ReasoningEffort.deep;
    // Deep saturates fully, Standard sits at 75% so there's a visible
    // step between the two. Off uses fgMuted so it reads as inert.
    final accent = !on
        ? DuckColors.fgMuted
        : (deep
              ? DuckColors.accentPurple
              : DuckColors.accentPurple.withValues(alpha: 0.78));
    final fg = !on ? DuckColors.fgMuted : accent;

    return Tooltip(
      message: _tooltipFor(effort, isNative),
      waitDuration: const Duration(milliseconds: 350),
      child: Material(
        color: Colors.transparent,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: onCycle,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    deep ? Icons.psychology : Icons.psychology_outlined,
                    size: 14,
                    color: accent,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _label(effort, compact),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: deep
                          ? FontWeight.w600
                          : (on ? FontWeight.w500 : FontWeight.w400),
                      color: fg,
                      letterSpacing: 0.2,
                    ),
                  ),
                  if (deep) ...[
                    const SizedBox(width: 4),
                    // Tiny pip at deep level — same convention as the
                    // auto-approve pill's "ON" dot.
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                  if (on && !isNative) ...[
                    const SizedBox(width: 4),
                    // Subtle "prompt-only" hint when the model doesn't
                    // accept a native reasoning param. Outline-style
                    // asterisk so it's noticeable but not loud — the
                    // tooltip carries the full explanation.
                    Text(
                      '*',
                      style: TextStyle(
                        fontSize: 11,
                        height: 1.0,
                        fontWeight: FontWeight.w700,
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact toggle pill used in the chat input row to flip the
/// global auto-approve flag. Why a custom widget rather than
/// `Switch.adaptive` + `Text`:
/// - Material `Switch` is ~50px wide and ~32px tall — far too big
///   for a chrome row that already has a model picker, image
///   attach, send button, etc.
/// - The pill is single-tap to flip and shows BOTH state (the
///   thumb position) and a one-word label, in <100px width.
///
/// Visual states:
/// - OFF: grey track, thumb left, "auto-approve" label muted.
/// - ON:  cyan track, thumb right, "auto-approve" label cyan.
///
/// Note: per-tool blanket approvals (`chat.autoApprovedTools`)
/// remain Settings-only — this pill ONLY controls the global
/// `_autoApprove` master switch. Layering both into one chrome
/// control would invite confusion.
class _AutoApproveTogglePill extends StatelessWidget {
  final bool on;
  final bool compact;
  final VoidCallback onChanged;
  const _AutoApproveTogglePill({
    required this.on,
    this.compact = false,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final accent = on ? DuckColors.accentCyan : DuckColors.fgFaint;
    final fg = on ? DuckColors.accentCyan : DuckColors.fgMuted;
    return Tooltip(
      message: on ? S.chatAutoApproveOnTooltip : S.chatAutoApproveOffTooltip,
      waitDuration: const Duration(milliseconds: 350),
      child: Material(
        color: Colors.transparent,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: InkWell(
            onTap: onChanged,
            borderRadius: BorderRadius.circular(999),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniSwitch(on: on),
                  if (!compact) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        S.chatAutoApproveLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                          color: fg,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                  if (on) ...[
                    SizedBox(width: compact ? 3 : 4),
                    // Tiny "ON" pip when active — gives an extra glance-
                    // detectable signal without bloating the pill when
                    // off (the default safe state).
                    Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Hand-rolled 22×12 switch used inside `_AutoApproveTogglePill`.
/// Animates the thumb position and the track tint together so the
/// state change feels deliberate (not just a colour swap).
class _MiniSwitch extends StatelessWidget {
  final bool on;
  const _MiniSwitch({required this.on});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 140),
      curve: Curves.easeOut,
      width: 22,
      height: 12,
      decoration: BoxDecoration(
        color: on
            ? DuckColors.accentCyan.withValues(alpha: 0.85)
            : DuckColors.bgRaisedHi,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: on ? DuckColors.accentCyan : DuckColors.glassSeam,
          width: 0.5,
        ),
      ),
      child: AnimatedAlign(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.all(1.5),
          child: Container(
            width: 9,
            height: 9,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  final ChatController chat;

  const _ModelPicker({required this.chat});

  /// Strip the `provider:` prefix so the badge displays only the
  /// model name. Underlying `chat.selectedModel` keeps the full
  /// `provider:model` form because routing relies on it; this is
  /// purely a display tweak. Splits on the FIRST colon only so
  /// Ollama tags like `llama3:8b` keep their tag in the visible
  /// label (`llama3:8b`, not `8b` or `llama3`).
  static String _compactModelLabel(String fullId) {
    final idx = fullId.indexOf(':');
    if (idx <= 0 || idx == fullId.length - 1) return fullId;
    return fullId.substring(idx + 1);
  }

  @override
  Widget build(BuildContext context) {
    final key = GlobalKey();
    // Always show the TRUE _selectedModel — never silently swap to
    // `availableModels.first` when stale. The previous version did,
    // which masked the real bug behind the "Ollama selected but
    // Gemini was called" report: the chrome label said
    // "ollama:llama3" while `chat.selectedModel` was actually
    // "gemini:..." under the hood. Now the user sees the truth and
    // the picker label suffixes "(unavailable)" if the model isn't
    // in the current available list.
    final stale =
        !chat.pickerModels.contains(chat.selectedModel) &&
        chat.availableModels.isNotEmpty;
    final compact = _compactModelLabel(chat.selectedModel);
    final model = stale ? '$compact (unavailable)' : compact;
    // Tooltip carries the FULL provider:model so the user can still
    // identify which provider routes the badge — useful when two
    // providers expose models with the same short name (e.g. a
    // llama3 on both Ollama and Groq).
    final tooltipMessage = stale
        ? '${S.chatModel}: ${chat.selectedModel} (unavailable)'
        : '${S.chatModel}: ${chat.selectedModel}';

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.hasBoundedWidth
            ? constraints.maxWidth.clamp(80.0, 160.0)
            : 160.0;
        return Tooltip(
          message: tooltipMessage,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: InkWell(
              key: key,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              onTap: () async {
                final box =
                    key.currentContext?.findRenderObject() as RenderBox?;
                if (box == null) return;
                final overlay =
                    Overlay.of(context).context.findRenderObject() as RenderBox;
                final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
                final picked = await showMenu<String>(
                  context: context,
                  color: DuckColors.bgRaised,
                  elevation: 12,
                  position: RelativeRect.fromLTRB(
                    pos.dx,
                    pos.dy - 8,
                    overlay.size.width - pos.dx - box.size.width,
                    overlay.size.height - pos.dy,
                  ),
                  items: [
                    if (chat.pickerModels.isEmpty)
                      const PopupMenuItem<String>(
                        enabled: false,
                        child: Text(
                          S.chatNoModels,
                          style: TextStyle(fontSize: 12),
                        ),
                      )
                    else
                      for (final m in chat.pickerModels)
                        PopupMenuItem<String>(
                          value: m,
                          child: Row(
                            children: [
                              Icon(
                                Icons.check_circle_outline,
                                size: 14,
                                color: DuckColors.accentMint,
                              ),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  m,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: m == chat.selectedModel
                                        ? FontWeight.w700
                                        : FontWeight.w400,
                                    color: m == chat.selectedModel
                                        ? DuckColors.fgPrimary
                                        : DuckColors.fgMuted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    const PopupMenuDivider(),
                    const PopupMenuItem<String>(
                      value: '__refresh__',
                      child: Row(
                        children: [
                          Icon(
                            Icons.refresh,
                            size: 14,
                            color: DuckColors.accentCyan,
                          ),
                          SizedBox(width: 8),
                          Text(
                            S.chatModelRefresh,
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    const PopupMenuItem<String>(
                      value: '__all__',
                      child: Row(
                        children: [
                          Icon(
                            Icons.tune,
                            size: 14,
                            color: DuckColors.accentCyan,
                          ),
                          SizedBox(width: 8),
                          Text(
                            S.chatModelViewAll,
                            style: TextStyle(fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ],
                );
                if (picked == '__all__') {
                  if (!context.mounted) return;
                  final chosen = await showDialog<String>(
                    context: context,
                    barrierDismissible: false,
                    barrierColor: Colors.black.withValues(alpha: 0.45),
                    builder: (_) => _ModelSelectionPanel(chat: chat),
                  );
                  if (chosen != null) chat.setModel(chosen);
                } else if (picked == '__refresh__') {
                  // Power-user escape hatch: pull models again
                  // without going through Settings → Save. Useful
                  // after `ollama pull` / `ollama signin` outside
                  // the app. Toast confirms the new picker size so
                  // the user knows the refresh actually did
                  // something.
                  await chat.reloadModels();
                  if (!context.mounted) return;
                  final count = chat.pickerModels.length;
                  showDuckToast(
                    context,
                    S.chatModelRefreshedToast.replaceFirst(
                      '%d',
                      count.toString(),
                    ),
                  );
                } else if (picked != null) {
                  chat.setModel(picked);
                }
              },
              child: Container(
                constraints: BoxConstraints(maxWidth: maxWidth),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: DuckColors.bgDeeper,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  border: Border.all(color: DuckColors.border, width: 0.5),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.memory,
                      size: 11,
                      color: DuckColors.fgMuted,
                    ),
                    const SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        model,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Icon(
                      Icons.expand_more,
                      size: 12,
                      color: DuckColors.fgMuted,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
