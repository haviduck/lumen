import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'providers/app_state.dart';
import 'providers/media_controller.dart';
import 'services/ide_actions.dart';
import 'services/language_detector.dart';
import 'services/recent_edits_tracker.dart';
import 'services/window_chrome.dart';
import 'theme/app_colors.dart';
import 'theme/app_theme.dart';
import 'widgets/ai_chat/ai_chat.dart';
import 'widgets/app_close_guard.dart';
import 'widgets/common/ambient_background.dart';
import 'widgets/common/duck_glass.dart';
import 'widgets/common/fast_popup_menu.dart';
import 'widgets/editor/editor.dart';
import 'widgets/file_explorer/file_explorer.dart';
import 'widgets/lock_screen.dart';
import 'widgets/menu_bar.dart';
import 'widgets/overlays/overlay_host.dart';
import 'widgets/terminal/terminal_pane.dart';
import 'widgets/welcome_screen.dart';

Future<void> main() async {
  // Native-window setup BEFORE the framework binds to a surface size.
  // `WindowChrome.bootstrap` configures the window for the welcome
  // panel (~700x560, centred). Later, `RootScreen` calls
  // `enterWorkspaceLayout` to maximise once the user opens a project.
  // Idempotent + graceful on unsupported hosts; never crashes boot.
  WidgetsFlutterBinding.ensureInitialized();
  await WindowChrome.bootstrap();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        // MediaController lives at the root because both the chat
        // panel and the editor area render the same `Webview()` —
        // whichever one is currently selected as the placement —
        // and we need a single shared `WebviewController` so the
        // video doesn't reload on every placement swap.
        ChangeNotifierProvider(create: (_) => MediaController()),
      ],
      child: const LumenApp(),
    ),
  );
}

class LumenApp extends StatelessWidget {
  const LumenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: S.appName,
      debugShowCheckedModeBanner: false,
      theme: DuckTheme.build(),
      // `AppCloseGuard` sits inside the MaterialApp Navigator (so it
      // can `showDialog`) and below the AppState `Provider` (so it
      // can read open files / dirty state). It owns
      // `windowManager.setPreventClose(true)` for the whole app
      // lifetime — every native close attempt routes through its
      // unsaved-changes prompt before the window actually destroys.
      home: const AppCloseGuard(child: RootScreen()),
    );
  }
}

class RootScreen extends StatelessWidget {
  const RootScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, child) {
        final Widget body;
        final bool wantWelcome = state.currentDirectory == null;
        if (wantWelcome) {
          body = const WelcomeScreen();
        } else {
          body = const _IdeShell();
        }
        // Native-window size follows macro-state: small panel-sized
        // window for the welcome screen, maximised for the IDE shell.
        // We schedule the transition as a post-frame callback so the
        // resize / maximise IPC never lands inside Flutter's build
        // phase. `WindowChrome` is internally idempotent — repeat
        // post-frame calls during the same macro-state short-circuit
        // before talking to `window_manager`.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (wantWelcome) {
            WindowChrome.enterWelcomeLayout();
          } else {
            WindowChrome.enterWorkspaceLayout();
          }
        });
        return Stack(children: [body, if (state.isLocked) const LockScreen()]);
      },
    );
  }
}

class _IdeShell extends StatelessWidget {
  const _IdeShell();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return _GlobalShortcuts(
      child: OverlayHost(
        child: Scaffold(
          // The shell stacks the ambient radial background underneath the
          // panels so every glass surface has something interesting to
          // blur. `Scaffold.backgroundColor` is transparent so the ambient
          // layer shows through cleanly.
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              const Positioned.fill(child: AmbientBackground()),
              Column(
                children: [
                  const DuckMenuBar(),
                  Expanded(
                    child: _LayoutForMode(
                      mode: state.viewMode,
                      chatHidden: state.chatHidden,
                    ),
                  ),
                  const _StatusBar(),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps the IDE shell in `Shortcuts` + `Actions` so the standard VS-Code
/// hotkeys reach the menu dispatcher. Each intent maps to the same string
/// the menu bar uses, so there is exactly one action implementation.
class _GlobalShortcuts extends StatelessWidget {
  final Widget child;
  const _GlobalShortcuts({required this.child});

  static final _shortcuts = <ShortcutActivator, Intent>{
    const SingleActivator(LogicalKeyboardKey.keyS, control: true):
        const _MenuIntent('save'),
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true):
        const _MenuIntent('undo'),
    const SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
        const _MenuIntent('redo'),
    const SingleActivator(LogicalKeyboardKey.keyY, control: true):
        const _MenuIntent('redo'),
    const SingleActivator(LogicalKeyboardKey.keyF, control: true):
        const _MenuIntent('find'),
    const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true):
        const _MenuIntent('globalSearch'),
    const SingleActivator(LogicalKeyboardKey.keyH, control: true):
        const _MenuIntent('findReplace'),
    const SingleActivator(LogicalKeyboardKey.keyP, control: true, shift: true):
        const _MenuIntent('commandPalette'),
    const SingleActivator(LogicalKeyboardKey.keyN, control: true, shift: true):
        const _MenuIntent('newWindow'),
    const SingleActivator(LogicalKeyboardKey.keyN, control: true):
        const _MenuIntent('newFile'),
    const SingleActivator(LogicalKeyboardKey.keyT, control: true):
        const _MenuIntent('newTab'),
    const SingleActivator(LogicalKeyboardKey.keyO, control: true):
        const _MenuIntent('open'),
    const SingleActivator(LogicalKeyboardKey.backquote, control: true):
        const _MenuIntent('newTerm'),
    const SingleActivator(LogicalKeyboardKey.digit1, control: true):
        const _MenuIntent('normal'),
    const SingleActivator(LogicalKeyboardKey.digit2, control: true):
        const _MenuIntent('zen'),
    const SingleActivator(LogicalKeyboardKey.digit3, control: true):
        const _MenuIntent('sideEye'),
  };

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: _shortcuts,
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MenuIntent: CallbackAction<_MenuIntent>(
            onInvoke: (intent) {
              handleMenuAction(context, intent.actionId);
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          canRequestFocus: false,
          skipTraversal: true,
          child: child,
        ),
      ),
    );
  }
}

class _MenuIntent extends Intent {
  final String actionId;
  const _MenuIntent(this.actionId);
}

class _LayoutForMode extends StatefulWidget {
  final DuckViewMode mode;
  // Whether the AI chat sidebar is collapsed. Only respected in
  // `DuckViewMode.normal` — `zen` already hides chat, `sideEye`
  // *is* the chat-only layout so toggling chat-hidden there would
  // produce an empty workspace.
  final bool chatHidden;
  const _LayoutForMode({required this.mode, required this.chatHidden});

  @override
  State<_LayoutForMode> createState() => _LayoutForModeState();
}

class _LayoutForModeState extends State<_LayoutForMode> {
  static const double _chatOptimalWidth = 340;
  static const double _chatMinWidth = 260;
  static const double _chatSnapThreshold = 24;

  MultiSplitViewController? _root;
  MultiSplitViewController? _centerVertical;
  Axis _rootAxis = Axis.horizontal;

  @override
  void initState() {
    super.initState();
    _rebuildControllers();
  }

  @override
  void didUpdateWidget(covariant _LayoutForMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild whenever the mode OR the chat-hidden flag changes —
    // both feed into which `Area`s the root `MultiSplitView` ends
    // up holding, and `MultiSplitViewController.areas` can't be
    // mutated after construction without surprises, so a fresh
    // controller is the cleanest path.
    if (oldWidget.mode != widget.mode ||
        oldWidget.chatHidden != widget.chatHidden) {
      _rebuildControllers();
    }
  }

  void _rebuildControllers() {
    switch (widget.mode) {
      case DuckViewMode.normal:
        _centerVertical = MultiSplitViewController(
          areas: [
            Area(flex: 0.72, builder: (c, a) => const Editor()),
            Area(flex: 0.28, builder: (c, a) => const TerminalPane()),
          ],
        );
        _rootAxis = Axis.horizontal;
        _root = MultiSplitViewController(
          areas: [
            Area(size: 240, min: 220, builder: (c, a) => const FileExplorer()),
            Area(
              flex: 1,
              builder: (c, a) => MultiSplitView(
                axis: Axis.vertical,
                controller: _centerVertical!,
              ),
            ),
            // Chat sidebar — omitted entirely when `chatHidden` is
            // true so the editor + terminal column expands to fill
            // the freed width. Toggle lives in the menu bar.
            if (!widget.chatHidden)
              Area(
                size: _chatOptimalWidth,
                min: _chatMinWidth,
                builder: (c, a) => const AiChat(),
              ),
          ],
        );
        break;
      case DuckViewMode.zen:
        _centerVertical = MultiSplitViewController(areas: const []);
        _rootAxis = Axis.horizontal;
        _root = MultiSplitViewController(
          areas: [Area(flex: 1, builder: (c, a) => const Editor())],
        );
        break;
      case DuckViewMode.sideEye:
        _centerVertical = MultiSplitViewController(areas: const []);
        _rootAxis = Axis.horizontal;
        _root = MultiSplitViewController(
          areas: [Area(flex: 1, builder: (c, a) => const AiChat())],
        );
        break;
    }
  }

  void _snapChatSidebarIfNearOptimal(int dividerIndex) {
    if (widget.mode != DuckViewMode.normal || widget.chatHidden) return;
    // Root layout in normal mode is: explorer | workbench | chat.
    // Divider 1 is the workbench/chat divider.
    if (dividerIndex != 1 || _root == null || _root!.areasCount < 3) return;
    final chatArea = _root!.getArea(2);
    final current = chatArea.size;
    if (current == null) return;
    if ((current - _chatOptimalWidth).abs() <= _chatSnapThreshold) {
      chatArea.size = _chatOptimalWidth;
    }
  }

  Widget _rootDividerBuilder(
    Axis axis,
    int index,
    bool resizable,
    bool dragging,
    bool highlighted,
    MultiSplitViewThemeData themeData,
  ) {
    final isChatDivider =
        widget.mode == DuckViewMode.normal && !widget.chatHidden && index == 1;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        DividerWidget(
          axis: axis,
          index: index,
          themeData: themeData,
          resizable: resizable,
          dragging: dragging,
          highlighted: highlighted,
        ),
        if (isChatDivider)
          Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: highlighted || dragging ? 7 : 5,
              height: highlighted || dragging ? 34 : 26,
              decoration: BoxDecoration(
                color:
                    (highlighted || dragging
                            ? DuckColors.accentCyan
                            : DuckColors.fgSubtle)
                        .withValues(
                          alpha: highlighted || dragging ? 0.85 : 0.42,
                        ),
                borderRadius: BorderRadius.circular(99),
                boxShadow: highlighted || dragging
                    ? [
                        BoxShadow(
                          color: DuckColors.accentCyan.withValues(alpha: 0.28),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    // Hot reload can preserve this State after adding controller fields, so
    // guard against an existing instance that never ran the new initState.
    if (_root == null) {
      _rebuildControllers();
    }
    return MultiSplitViewTheme(
      data: MultiSplitViewThemeData(
        dividerThickness: 1,
        dividerHandleBuffer: 8,
        dividerPainter: DividerPainters.background(
          color: DuckColors.glassSeam,
          highlightedColor: DuckColors.accentCyan.withValues(alpha: 0.4),
        ),
      ),
      child: MultiSplitView(
        axis: _rootAxis,
        controller: _root!,
        dividerBuilder: _rootDividerBuilder,
        onDividerDragEnd: _snapChatSidebarIfNearOptimal,
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final chat = state.chat;
    return DuckGlass(
      tint: const Color(0xE614171D), // match title/status bar darkness
      border: const Border(
        top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (state.currentDirectory != null) ...[
              const Icon(
                Icons.folder_open,
                size: 11,
                color: DuckColors.folderIcon,
              ),
              const SizedBox(width: 4),
              Text(
                '${S.statusWorkspace}: ${state.currentDirectory!.split(RegExp(r'[\\/]')).last}',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgMuted,
                ),
              ),
              const SizedBox(width: 14),
            ],
            Icon(
              chat.isGenerating
                  ? Icons.auto_awesome
                  : Icons.auto_awesome_outlined,
              size: 11,
              color: chat.isGenerating
                  ? DuckColors.accentMint
                  : DuckColors.fgSubtle,
            ),
            const SizedBox(width: 4),
            Text(
              '${S.statusAgent}: ${chat.isGenerating ? S.statusAgentThinking : S.statusAgentIdle}',
              style: TextStyle(
                fontSize: 11.5,
                color: chat.isGenerating
                    ? DuckColors.accentMint
                    : DuckColors.fgMuted,
              ),
            ),
            if (state.activeFile != null &&
                state.isFileDirty(state.activeFile!.path)) ...[
              const SizedBox(width: 14),
              const Icon(Icons.circle, size: 11, color: DuckColors.accentDuck),
              const SizedBox(width: 4),
              const Text(
                S.editorUnsaved,
                style: TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
              ),
            ],
            const Spacer(),
            const _LineColumnIndicator(),
            const SizedBox(width: 12),
            const _LanguageIndicator(),
            const SizedBox(width: 12),
            const _RecentEditsToggle(),
            if (chat.autoApprove) ...[
              const SizedBox(width: 12),
              const Icon(Icons.flash_on, size: 11, color: DuckColors.stateWarn),
              const SizedBox(width: 4),
              const Text(
                S.statusAutoApprove,
                style: TextStyle(fontSize: 11.5, color: DuckColors.stateWarn),
              ),
            ],
            const SizedBox(width: 12),
            Text(
              '${S.statusTheme}: ${state.editorTheme}',
              style: const TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
            ),
            const SizedBox(width: 12),
            Text(
              '${S.statusView}: ${state.viewMode.name}',
              style: const TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
            ),
          ],
        ),
      ),
    );
  }
}

/// Live "Ln 23, Col 5" indicator that tracks the registered active editor's
/// selection. Hides itself when no editor is mounted.
class _LineColumnIndicator extends StatefulWidget {
  const _LineColumnIndicator();

  @override
  State<_LineColumnIndicator> createState() => _LineColumnIndicatorState();
}

class _LineColumnIndicatorState extends State<_LineColumnIndicator> {
  CodeLineEditingController? _watching;
  IdeActions? _watchingActions;
  int _line = 1;
  int _column = 1;

  void _onEditorChanged() {
    final c = _watching;
    if (c == null) return;
    final sel = c.selection;
    // re_editor uses 0-based line index, display as 1-based
    final line = sel.baseIndex + 1;
    final col = sel.baseOffset + 1;
    if (line != _line || col != _column) {
      setState(() {
        _line = line;
        _column = col;
      });
    }
  }

  void _syncSubscription(IdeActions actions) {
    final next = actions.activeEditor;
    if (identical(next, _watching)) return;
    _watching?.removeListener(_onEditorChanged);
    _watching = next;
    _watching?.addListener(_onEditorChanged);
    _onEditorChanged();
  }

  void _onActionsChanged() {
    final a = _watchingActions;
    if (a == null) return;
    _syncSubscription(a);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final actions = context.read<AppState>().ideActions;
    if (!identical(actions, _watchingActions)) {
      _watchingActions?.removeListener(_onActionsChanged);
      _watchingActions = actions;
      _watchingActions!.addListener(_onActionsChanged);
      _syncSubscription(actions);
    }
  }

  @override
  void dispose() {
    _watching?.removeListener(_onEditorChanged);
    _watchingActions?.removeListener(_onActionsChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_watching == null) return const SizedBox.shrink();
    return Text(
      '${S.editorLineCol} $_line, ${S.editorColCol} $_column',
      style: const TextStyle(fontSize: 11.5, color: DuckColors.fgMuted),
    );
  }
}

class _LanguageIndicator extends StatelessWidget {
  const _LanguageIndicator();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final active = state.activeFile;
    if (active == null) return const SizedBox.shrink();

    final key = GlobalKey();
    final detected = LanguageDetector.detect(
      active.path,
      state.fileContentFor(active.path),
    );
    final langId = state.languageOverrideFor(active.path) ?? detected.id;

    return Tooltip(
      message: S.editorLanguage,
      child: InkWell(
        key: key,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        onTap: () async {
          final box = key.currentContext?.findRenderObject() as RenderBox?;
          if (box == null) return;
          final overlay =
              Overlay.of(context).context.findRenderObject() as RenderBox;
          final pos = box.localToGlobal(Offset.zero, ancestor: overlay);
          final picked = await showFastMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(
              pos.dx,
              pos.dy - 260,
              overlay.size.width - pos.dx - box.size.width,
              overlay.size.height - pos.dy,
            ),
            items: [
              const PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  S.editorAutoDetect,
                  style: TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
                ),
              ),
              ...LanguageDetector.allLanguageIds.map(
                (id) => PopupMenuItem<String>(
                  value: id,
                  child: Row(
                    children: [
                      if (id == langId)
                        const Icon(
                          Icons.check,
                          size: 14,
                          color: DuckColors.accentMint,
                        )
                      else
                        const SizedBox(width: 14),
                      const SizedBox(width: 6),
                      Text(id),
                    ],
                  ),
                ),
              ),
            ],
          );
          if (picked != null) {
            state.overrideLanguage(active.path, picked);
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
          decoration: BoxDecoration(
            color: DuckColors.bgChip.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.code, size: 11, color: DuckColors.fgSubtle),
              const SizedBox(width: 4),
              Text(
                langId,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Status-bar pill that toggles the editor's "Recent agent edits"
/// highlight. Watches `appState.recentEdits` directly (it's a
/// `ChangeNotifier`), persists the state through the tracker's own
/// preference accessor — no extra plumbing through `AppState`. The
/// pill mirrors `_LanguageIndicator`'s visual treatment so the status
/// bar's right cluster reads as a row of related controls.
class _RecentEditsToggle extends StatefulWidget {
  const _RecentEditsToggle();

  @override
  State<_RecentEditsToggle> createState() => _RecentEditsToggleState();
}

class _RecentEditsToggleState extends State<_RecentEditsToggle> {
  RecentEditsTracker? _tracker;

  void _onTrackerChange() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = context.read<AppState>().recentEdits;
    if (!identical(next, _tracker)) {
      _tracker?.removeListener(_onTrackerChange);
      _tracker = next;
      _tracker!.addListener(_onTrackerChange);
    }
  }

  @override
  void dispose() {
    _tracker?.removeListener(_onTrackerChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tracker = _tracker;
    if (tracker == null) return const SizedBox.shrink();
    final on = tracker.enabled;
    return Tooltip(
      message: S.statusRecentEditsTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: () => tracker.setEnabled(!on),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: DuckColors.bgChip.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  on ? Icons.history_edu : Icons.history_edu_outlined,
                  size: 11,
                  color: on ? DuckColors.accentCyan : DuckColors.fgSubtle,
                ),
                const SizedBox(width: 4),
                Text(
                  S.statusRecentEdits,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: on ? DuckColors.fgPrimary : DuckColors.fgMuted,
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
