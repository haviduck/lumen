import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/chat_controller.dart';
import '../../services/chat_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';

/// Cursor-style tab strip at the top of the chat panel.
///
/// Layout (left → right):
///   [tab 1 ✕] [tab 2 ✕] … [tab n ✕]                [+] [history ⏷]
///
/// - Tabs render the open chat sessions in `ChatController.openTabs`,
///   click to switch active session, middle-click to close,
///   reorderable via long-press drag (mirrors editor and terminal tabs).
/// - The `+` button creates a fresh session as a new tab on the right.
/// - The history button opens a `showFastMenu` listing every persisted
///   chat. Picking one re-opens it as a tab (or just switches to it
///   if it's already open).
/// - On active-tab change, the strip auto-scrolls the active tab into
///   the centre of the visible area via `Scrollable.ensureVisible`
///   with `alignment: 0.5` — same scroll-into-view behaviour you'd
///   expect from VS Code or Cursor when switching tabs.
class ChatTabStrip extends StatefulWidget {
  final ChatController chat;

  const ChatTabStrip({super.key, required this.chat});

  @override
  State<ChatTabStrip> createState() => _ChatTabStripState();
}

class _ChatTabStripState extends State<ChatTabStrip> {
  final ScrollController _scrollCtrl = ScrollController();
  // Per-active-session GlobalKey. We rebuild the key only when the
  // active session id changes so `Scrollable.ensureVisible` always
  // resolves to the current tab's element. Stable across re-renders
  // of the same active tab so we don't churn ensureVisible needlessly.
  String? _lastActiveId;
  GlobalKey _activeKey = GlobalKey();

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _scheduleScrollToActive() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = _activeKey.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        // Centre the active tab in the viewport when possible — the
        // others scoot out to the sides (matches Cursor / VS Code).
        alignment: 0.5,
        duration: DuckMotion.medium,
        curve: DuckMotion.standard,
      );
    });
  }

  void _handleTabWheel(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_scrollCtrl.hasClients) return;

    // Desktop convention: when the pointer is over a horizontal tab strip,
    // the regular wheel scrolls the strip left/right. Trackpads can emit a
    // real horizontal delta (`dx`), so prefer that when present; otherwise
    // map vertical wheel (`dy`) to horizontal movement. Positive wheel-down
    // moves right/forward, negative moves left/back.
    final delta = event.scrollDelta.dx.abs() > 0
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;

    final pos = _scrollCtrl.position;
    final target = (_scrollCtrl.offset + delta * 1.2).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (target == _scrollCtrl.offset) return;
    _scrollCtrl.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    final tabs = chat.openTabs;
    final current = chat.currentSession;

    // Rotate the GlobalKey when the active session changes so the
    // ensureVisible call below targets the correct render object.
    if (current?.id != _lastActiveId) {
      _lastActiveId = current?.id;
      _activeKey = GlobalKey();
      _scheduleScrollToActive();
    }

    return Container(
      height: DuckTheme.tabHeight + 4,
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 6),
          Expanded(
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerSignal: _handleTabWheel,
              child: tabs.isEmpty
                  ? _EmptyTabSlot(onTap: () => _newTab(context))
                  : ReorderableListView.builder(
                      scrollController: _scrollCtrl,
                      scrollDirection: Axis.horizontal,
                      buildDefaultDragHandles: false,
                      itemCount: tabs.length,
                      onReorder: chat.reorderTab,
                      proxyDecorator: (child, index, anim) => Material(
                        color: Colors.transparent,
                        elevation: 0,
                        child: child,
                      ),
                      itemBuilder: (context, i) {
                        final s = tabs[i];
                        final isActive = current?.id == s.id;
                        return ReorderableDragStartListener(
                          // Two keys here serve different purposes: the
                          // ReorderableDragStartListener key is the
                          // stable per-session ValueKey the list uses
                          // for reorder identity; the inner _ChatTab
                          // gets the rotating GlobalKey only when active
                          // so ensureVisible can locate it.
                          key: ValueKey('chat-tab-${s.id}'),
                          index: i,
                          child: _ChatTab(
                            key: isActive ? _activeKey : null,
                            title: _tabTitle(s),
                            isActive: isActive,
                            hasOtherTabs: tabs.length > 1,
                            hasTabsAfter: i < tabs.length - 1,
                            onActivate: () => chat.openSession(s.id),
                            onClose: () => chat.closeTab(s.id),
                            onCloseOthers: () => chat.closeOtherTabs(s.id),
                            onCloseToRight: () => chat.closeTabsToRight(s.id),
                            onCloseAll: () => chat.closeAllTabs(),
                          ),
                        );
                      },
                    ),
            ),
          ),
          _StripIconBtn(
            icon: Icons.add,
            tooltip: S.chatNewSession,
            onTap: () => _newTab(context),
          ),
          const SizedBox(width: 4),
          _HistoryButton(chat: chat),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  static String _tabTitle(ChatSession s) {
    final t = s.title.trim();
    if (t.isEmpty) return S.chatNewSession;
    return t;
  }

  void _newTab(BuildContext context) {
    final wd = context.read<AppState>().currentDirectory;
    widget.chat.newSession(workspacePath: wd);
  }
}

/// Single tab. Mirrors `_EditorTab` / `_TerminalTab` ergonomics: hover
/// reveals the close glyph, middle-click closes, right-click opens a
/// Close / Close Others / Close to the Right / Close All context menu,
/// active = `bgDeeper` (joins sidebar tone), inactive = transparent so
/// the panel's glass tint flows through. Inactive tabs render at ~55%
/// opacity (lifted to ~85% on hover) so the active tab clearly pops
/// without leaning on contrast alone.
class _ChatTab extends StatefulWidget {
  final String title;
  final bool isActive;
  final bool hasOtherTabs;
  final bool hasTabsAfter;
  final VoidCallback onActivate;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseToRight;
  final VoidCallback onCloseAll;

  const _ChatTab({
    super.key,
    required this.title,
    required this.isActive,
    required this.hasOtherTabs,
    required this.hasTabsAfter,
    required this.onActivate,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseToRight,
    required this.onCloseAll,
  });

  @override
  State<_ChatTab> createState() => _ChatTabState();
}

class _ChatTabState extends State<_ChatTab> {
  bool _hover = false;

  Future<void> _showContextMenu(Offset globalPos) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final picked = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPos.dx,
        globalPos.dy,
        overlay.size.width - globalPos.dx,
        overlay.size.height - globalPos.dy,
      ),
      items: [
        const PopupMenuItem<String>(
          value: 'close',
          child: Text(S.tabClose, style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem<String>(
          value: 'closeOthers',
          enabled: widget.hasOtherTabs,
          child: const Text(S.tabCloseOthers, style: TextStyle(fontSize: 12)),
        ),
        PopupMenuItem<String>(
          value: 'closeRight',
          enabled: widget.hasTabsAfter,
          child: const Text(
            S.tabCloseToTheRight,
            style: TextStyle(fontSize: 12),
          ),
        ),
        const PopupMenuItem<String>(
          value: 'closeAll',
          child: Text(S.tabCloseAll, style: TextStyle(fontSize: 12)),
        ),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'close':
        widget.onClose();
        break;
      case 'closeOthers':
        widget.onCloseOthers();
        break;
      case 'closeRight':
        widget.onCloseToRight();
        break;
      case 'closeAll':
        widget.onCloseAll();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final showClose = _hover || widget.isActive;
    final Color bg;
    if (widget.isActive) {
      // Match the chat panel's sidebar surface so the active tab
      // reads as "carved into" the sidebar rather than lifted toward
      // the editor — different from the editor tab strip, where the
      // active tab paints `editorBg` to merge with the canvas below.
      bg = DuckColors.bgDeeper;
    } else if (_hover) {
      bg = DuckColors.bgRaisedHi.withValues(alpha: 0.45);
    } else {
      bg = Colors.transparent;
    }
    // Subtle hairline around the active tab — `glassSeam` (5% white)
    // for parity with every other chrome separator. Inactive tabs
    // have no border so the strip stays quiet.
    final BoxBorder? border = widget.isActive
        ? Border.all(color: DuckColors.glassSeam, width: 0.5)
        : null;
    // Inactive tabs fade to ~55% so the active tab pops without us
    // leaning purely on bg + border contrast. Hovering an inactive
    // tab lifts it to ~85% as a "preview of activation" — same idea
    // as a hover state on a button. Active is always full strength.
    final double tabOpacity = widget.isActive
        ? 1.0
        : (_hover ? 0.85 : 0.55);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Listener(
        onPointerDown: (event) {
          if (event.kind == PointerDeviceKind.mouse &&
              event.buttons == kMiddleMouseButton) {
            widget.onClose();
          }
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (details) =>
              _showContextMenu(details.globalPosition),
          child: InkWell(
            onTap: widget.onActivate,
            hoverColor: Colors.transparent,
            splashColor: Colors.transparent,
            highlightColor: Colors.transparent,
            child: AnimatedContainer(
              duration: DuckMotion.fast,
              curve: DuckMotion.standard,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              constraints: const BoxConstraints(minWidth: 90, maxWidth: 180),
              decoration: BoxDecoration(color: bg, border: border),
              child: AnimatedOpacity(
                duration: DuckMotion.fast,
                curve: DuckMotion.standard,
                opacity: tabOpacity,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.chat_bubble_outline,
                      size: 11,
                      color: widget.isActive
                          ? DuckColors.accentCyan
                          : DuckColors.fgSubtle,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        widget.title,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: widget.isActive
                              ? DuckColors.fgPrimary
                              : DuckColors.fgMuted,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    AnimatedOpacity(
                      duration: DuckMotion.fast,
                      curve: DuckMotion.standard,
                      opacity: showClose ? 1.0 : 0.0,
                      child: IgnorePointer(
                        ignoring: !showClose,
                        child: Tooltip(
                          message: S.chatCloseTab,
                          child: InkWell(
                            onTap: widget.onClose,
                            borderRadius: BorderRadius.circular(2),
                            hoverColor: Colors.transparent,
                            splashColor: Colors.transparent,
                            child: const Padding(
                              padding: EdgeInsets.all(2),
                              child: Icon(
                                Icons.close,
                                size: 13,
                                color: DuckColors.fgMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Placeholder shown when no tabs are open. Click anywhere to start.
class _EmptyTabSlot extends StatelessWidget {
  final VoidCallback onTap;
  const _EmptyTabSlot({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onTap,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              S.chatNoOpenTabs,
              style: TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
            ),
          ),
        ),
      ),
    );
  }
}

class _StripIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _StripIconBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_StripIconBtn> createState() => _StripIconBtnState();
}

class _StripIconBtnState extends State<_StripIconBtn> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hover ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// History dropdown — opens a `showFastMenu` listing every persisted
/// session ordered by `updatedAt` desc. Picking a session calls
/// `openSession`, which adds it as a tab if not already present and
/// makes it the active chat.
class _HistoryButton extends StatefulWidget {
  final ChatController chat;
  const _HistoryButton({required this.chat});

  @override
  State<_HistoryButton> createState() => _HistoryButtonState();
}

class _HistoryButtonState extends State<_HistoryButton> {
  final GlobalKey _key = GlobalKey();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final chat = widget.chat;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: S.chatHistory,
        child: InkWell(
          key: _key,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: () async {
            final sessions = chat.sessions;
            final box = _key.currentContext?.findRenderObject() as RenderBox?;
            if (box == null) return;
            final overlay =
                Overlay.of(context).context.findRenderObject() as RenderBox;
            final pos = box.localToGlobal(
              Offset(0, box.size.height),
              ancestor: overlay,
            );

            final picked = await showFastMenu<String>(
              context: context,
              position: RelativeRect.fromLTRB(
                pos.dx - 200,
                pos.dy + 4,
                overlay.size.width - pos.dx - box.size.width,
                0,
              ),
              items: sessions.isEmpty
                  ? [
                      const PopupMenuItem<String>(
                        enabled: false,
                        child: Text(
                          S.chatHistoryEmpty,
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ]
                  : sessions.map((s) {
                      final current = chat.currentSession?.id == s.id;
                      return PopupMenuItem<String>(
                        value: s.id,
                        height: 32,
                        child: Row(
                          children: [
                            Icon(
                              current ? Icons.check : Icons.chat_bubble_outline,
                              size: 12,
                              color: current
                                  ? DuckColors.accentMint
                                  : DuckColors.fgSubtle,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                s.title.isEmpty ? S.chatNewSession : s.title,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _formatDate(s.updatedAt),
                              style: const TextStyle(
                                fontSize: 10,
                                color: DuckColors.fgSubtle,
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
            );
            if (picked != null) {
              await chat.openSession(picked);
            }
          },
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
            child: Icon(
              Icons.history,
              size: 16,
              color: _hover ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    final now = DateTime.now();
    final diff = now.difference(d);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 7) return '${diff.inDays}d';
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }
}
