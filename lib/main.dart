import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:re_editor/re_editor.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';

import 'l10n/strings.dart';
import 'providers/app_state.dart';
import 'providers/media_controller.dart';
import 'providers/ssh_controller.dart';
import 'services/ide_actions.dart';
import 'services/language_detector.dart';
import 'services/recent_edits_tracker.dart';
import 'services/ssh/ssh_remote_file_service.dart';
import 'services/window_chrome.dart';
import 'widgets/common/duck_toast.dart';
import 'widgets/ssh/ssh_grab_conflict_dialog.dart';
import 'widgets/ssh/ssh_remote_conflict_dialog.dart';
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
        // SshController is also root-level, parallel to
        // MediaController. Owns all live SSH sessions + the host
        // vault. `init()` is async (loads SharedPreferences for the
        // host list); we kick it off here and the `_SshAppStateBridge`
        // widget below waits for `ready` before binding to AppState.
        ChangeNotifierProvider(create: (_) => SshController()..init()),
      ],
      child: const _SshAppStateBridge(child: LumenApp()),
    ),
  );
}

/// One-shot bridge that wires the [SshController] into [AppState] as
/// soon as the controller's vault has finished loading. Lives between
/// the providers and the rest of the tree so the binding happens
/// exactly once on cold start, with the [BuildContext] of a top-level
/// widget so the conflict-resolver dialog can attach to the root
/// Navigator. Never rebuilds after the binding settles.
class _SshAppStateBridge extends StatefulWidget {
  final Widget child;
  const _SshAppStateBridge({required this.child});

  @override
  State<_SshAppStateBridge> createState() => _SshAppStateBridgeState();
}

class _SshAppStateBridgeState extends State<_SshAppStateBridge> {
  bool _bound = false;
  StreamSubscription<SshLumenEditRequest>? _lumenEditSub;
  StreamSubscription<SshLumenGrabRequest>? _lumenGrabSub;

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    if (!_bound && ssh.ready) {
      // Bind on the next frame — `bindSsh` calls into AppState which
      // can `notifyListeners`; doing it inside `build` is illegal.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final appState = context.read<AppState>();
        appState.bindSsh(
          ssh,
          conflictResolver:
              ({
                required RemoteFileOrigin origin,
                required int? currentSize,
                required int? currentMtime,
              }) async {
                // The dialog needs a context with a Navigator above it.
                // Walking up to `Overlay` keeps the dialog above the IDE
                // shell even when a save is triggered from a deeply
                // nested widget tree.
                return showSshRemoteConflictDialog(
                  context,
                  origin: origin,
                  currentSize: currentSize,
                  currentMtime: currentMtime,
                );
              },
          grabConflictResolver:
              ({
                required String existingLocalPath,
                required String remotePath,
                required String hostLabel,
              }) async {
                return showSshGrabConflictDialog(
                  context,
                  existingLocalPath: existingLocalPath,
                  remotePath: remotePath,
                  hostLabel: hostLabel,
                );
              },
        );
        // Subscribe to the `lumen-edit` stream once. Each event
        // means a remote shell helper just emitted an OSC 1337
        // `LumenEdit=<path>` payload; we open the file via the
        // standard remote-mirror path. Idempotent re-opens for the
        // same path are fine — `AppState.openRemoteFile` ends up
        // calling `openFile` which de-dupes by path.
        //
        // Toast on failure uses the bridge's own context post-await.
        // We use `context.mounted` (BuildContext extension) rather
        // than the State's `mounted` getter so the analyzer can
        // statically link the guard to this exact context — that's
        // what makes `use_build_context_synchronously` shut up. The
        // bridge mounts once near the root and lives for the app's
        // lifetime, so this is essentially a permanent listener;
        // the `mounted` guard is defence in depth.
        final overlayContext = context;
        _lumenEditSub = ssh.onLumenEditRequest.listen((req) async {
          try {
            await appState.openRemoteFile(
              hostId: req.hostId,
              remotePath: req.remotePath,
            );
          } catch (e) {
            if (!overlayContext.mounted) return;
            showDuckToast(
              overlayContext,
              isRemoteFileTooLarge(e)
                  ? S.sshRemoteFileTooLarge
                  : '${S.error}: $e',
            );
          }
        });
        // Mirror subscription for `lumen-grab`. Same context capture
        // + post-await `mounted` pattern as the edit listener — see
        // the comment above for why `context.mounted` is the only
        // form of guard the analyzer accepts here. On success we
        // toast with the resolved local filename so the user knows
        // exactly where the file landed (especially relevant when
        // "Keep both" produced a `(N)` suffix they didn't pick).
        _lumenGrabSub = ssh.onLumenGrabRequest.listen((req) async {
          try {
            final localPath = await appState.grabRemoteFile(
              hostId: req.hostId,
              remotePath: req.remotePath,
            );
            if (!overlayContext.mounted) return;
            if (localPath == null) {
              // User picked "Cancel" in the conflict dialog — silent
              // is fine, no toast clutter for an explicit no-op.
              return;
            }
            showDuckToast(
              overlayContext,
              S.sshGrabSuccessFmt(p.basename(localPath)),
            );
          } catch (e) {
            if (!overlayContext.mounted) return;
            showDuckToast(
              overlayContext,
              isRemoteFileTooLarge(e) ? S.sshGrabTooLarge : '${S.error}: $e',
            );
          }
        });
        setState(() => _bound = true);
      });
    }
    return widget.child;
  }

  @override
  void dispose() {
    _lumenEditSub?.cancel();
    _lumenGrabSub?.cancel();
    super.dispose();
  }
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
    // v1.5: side-panes (SSH/Teams/Watch) are mounted INSIDE the
    // editor area now (see `editor.dart::build`), so the IDE shell
    // no longer needs to watch SSH/Media at this level. The editor
    // self-decides whether to allocate a right slot. Removing the
    // watch here also avoids spurious re-runs of
    // `_LayoutForMode.didUpdateWidget` when SSH/Media flip — the
    // root layout is genuinely orthogonal to side-pane state in
    // v1.5.
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
  const _LayoutForMode({
    required this.mode,
    required this.chatHidden,
  });

  @override
  State<_LayoutForMode> createState() => _LayoutForModeState();
}

class _LayoutForModeState extends State<_LayoutForMode> {
  static const double _chatOptimalWidth = 340;
  static const double _chatMinWidth = 260;
  static const double _chatSnapThreshold = 24;
  // Floor on the (Editor + Terminal) workbench column. Without
  // this, the chat divider could be dragged so far left that the
  // editor disappears entirely with no way to recover (the
  // divider becomes invisible too once its handle has zero width
  // to live on). 480 px is enough to comfortably show a code line
  // at 96-char width plus the editor gutter, and still leaves the
  // user a usable column on a 1080p secondary monitor.
  static const double _workbenchMinWidth = 480;

  MultiSplitViewController? _root;
  MultiSplitViewController? _centerVertical;
  Axis _rootAxis = Axis.horizontal;

  // Index of the chat divider in the root area list. v1.5 layout
  // simplified back to [Explorer | Workbench | Chat?] — the
  // side-panes Area is gone (moved INSIDE the editor area in
  // `editor.dart`), so the chat divider is always at index 1
  // when chat is visible. Kept as a recorded field rather than a
  // bare constant so the chrome helpers stay readable and
  // future layout reshuffles don't have to chase a magic number.
  int _chatAreaIndex = -1;
  int _chatDividerIndex = -1;

  @override
  void initState() {
    super.initState();
    _rebuildControllers();
  }

  @override
  void didUpdateWidget(covariant _LayoutForMode oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Rebuild whenever the mode or the chat-hidden flag changes
    // — both feed into which `Area`s the root `MultiSplitView`
    // ends up holding, and `MultiSplitViewController.areas` can't
    // be mutated after construction without surprises, so a fresh
    // controller is the cleanest path. (multi_split_view 3.6.1
    // specifically: any attempt to swap the areas list on an
    // existing controller is silently ignored.)
    if (oldWidget.mode != widget.mode ||
        oldWidget.chatHidden != widget.chatHidden) {
      _rebuildControllers();
    }
  }

  void _rebuildControllers() {
    switch (widget.mode) {
      case DuckViewMode.normal:
        // Council theater used to swap out the entire (Editor +
        // Terminal) area as a workbench-level overlay when running.
        // That locked the user out of every other surface — code
        // tabs, settings, terminal, file explorer interactions —
        // until the council finished. v2 layout: council renders
        // as an editor tab via the `__council_theater__` sentinel
        // path (see `AppState.openCouncilTheaterTab` and the
        // `editor.dart` pane router). The orchestration logic is
        // unchanged; only the mounting surface moved.
        _centerVertical = MultiSplitViewController(
          areas: [
            Area(flex: 0.72, builder: (c, a) => const Editor()),
            Area(flex: 0.28, builder: (c, a) => const TerminalPane()),
          ],
        );
        _rootAxis = Axis.horizontal;
        // Layout from L→R is: [Explorer] [Editor+Terminal] [Chat?]
        //
        // SSH / Teams / Watch (the "side panes") used to live as a
        // 4th Area here in v1.4. v1.5 moved them INSIDE the
        // editor area as a horizontal split inside the workbench
        // top half, so the terminal still spans the full
        // workbench width below them. The reasoning is two-fold:
        // (a) the editor + side panes read as a single unit
        // again, matching the user's mental model from v1.0–v1.3;
        // (b) the terminal stops being half-width when SSH is
        // open, which was a frequent footgun.
        final areas = <Area>[
          Area(size: 240, min: 220, builder: (c, a) => const FileExplorer()),
          Area(
            flex: 1,
            // `min:` floors the workbench column so dragging the
            // chat divider left can't make the editor vanish.
            min: _workbenchMinWidth,
            builder: (c, a) => MultiSplitView(
              axis: Axis.vertical,
              controller: _centerVertical!,
            ),
          ),
        ];
        if (!widget.chatHidden) {
          _chatAreaIndex = areas.length;
          // Divider N sits BETWEEN areas N and N+1; the chat
          // divider is the one immediately before the chat area.
          _chatDividerIndex = areas.length - 1;
          areas.add(
            Area(
              size: _chatOptimalWidth,
              min: _chatMinWidth,
              builder: (c, a) => const AiChat(),
            ),
          );
        } else {
          _chatAreaIndex = -1;
          _chatDividerIndex = -1;
        }
        _root = MultiSplitViewController(areas: areas);
        break;
      case DuckViewMode.zen:
        _centerVertical = MultiSplitViewController(areas: const []);
        _rootAxis = Axis.horizontal;
        _chatAreaIndex = -1;
        _chatDividerIndex = -1;
        _root = MultiSplitViewController(
          areas: [Area(flex: 1, builder: (c, a) => const Editor())],
        );
        break;
      case DuckViewMode.sideEye:
        _centerVertical = MultiSplitViewController(areas: const []);
        _rootAxis = Axis.horizontal;
        _chatAreaIndex = -1;
        _chatDividerIndex = -1;
        _root = MultiSplitViewController(
          areas: [Area(flex: 1, builder: (c, a) => const AiChat())],
        );
        break;
    }
  }

  void _snapChatSidebarIfNearOptimal(int dividerIndex) {
    if (widget.mode != DuckViewMode.normal || widget.chatHidden) return;
    // v1.5: chat divider is always at index 1 when chat is
    // visible (no side-panes Area between workbench and chat
    // anymore). `_chatDividerIndex` is recorded by
    // `_rebuildControllers` to keep this resilient to future
    // layout reshuffles.
    if (_chatDividerIndex < 0 || dividerIndex != _chatDividerIndex) return;
    if (_root == null || _chatAreaIndex < 0) return;
    if (_root!.areasCount <= _chatAreaIndex) return;
    final chatArea = _root!.getArea(_chatAreaIndex);
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
        widget.mode == DuckViewMode.normal &&
        !widget.chatHidden &&
        index == _chatDividerIndex;
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
