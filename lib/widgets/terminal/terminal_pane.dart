import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/shell_discovery.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';
import 'terminal_session.dart';

/// Manages multiple terminal tabs, each backed by a `TerminalSession`.
/// Lazily creates a session for the current workspace on first build.
class TerminalPane extends StatefulWidget {
  const TerminalPane({super.key});

  @override
  State<TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<TerminalPane> {
  final List<TerminalSession> _sessions = [];
  // In normal mode this is the active terminal. In split mode it is
  // the left pane's terminal; [_secondaryIndex] is the right pane's.
  int _activeIndex = 0;
  int? _secondaryIndex;
  int _focusedPane = 0;
  bool _splitView = false;
  String? _initializedFor;

  // Cursor state for ctrl+hover-on-URL. True when the mouse is currently
  // over a URL inside `_termHoveredSession` AND ctrl is held. The
  // `MouseRegion.cursor` property reads this each rebuild, so flipping
  // it via `setState` swaps the Windows arrow for the standard
  // hand-pointer (`SystemMouseCursors.click`) — same affordance VS Code
  // and Cursor use to signal "this is followable".
  bool _terminalCtrlHoverOverUrl = false;
  TerminalSession? _termHoveredSession;
  Offset? _termHoverPos;

  List<ShellSpec> _availableShells = [];
  String? _preferredShellId;
  bool _shellsLoaded = false;

  // Click-detection state for the URL ctrl+click handler. We can't use
  // `TerminalView.onTapUp` because it's dead code in xterm 4.0.0
  // (declared on the gesture detector but never wired into the
  // TapGestureRecognizer — see `TerminalSession.viewKey` for the long
  // explanation). Instead a raw `Listener` tracks pointer-down state and
  // decides "this was a click, not a drag" on pointer-up.
  Offset? _termDownPos;
  Duration? _termDownTime;
  int? _termDownPointer;
  static const double _kTermClickSlopPx = 5.0;
  static const Duration _kTermClickMaxDuration = Duration(milliseconds: 500);
  static const Duration _kTermSelectionAutoScrollTick = Duration(
    milliseconds: 33,
  );

  TerminalSession? _termSelectionSession;
  int? _termSelectionPointer;
  CellOffset? _termSelectionBaseCell;
  Offset? _termSelectionStartGlobal;
  Offset? _termSelectionLastGlobal;
  bool _termSelectionDragging = false;
  Timer? _termSelectionAutoScrollTimer;

  bool get _useHardwareKeyboardOnly {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.macOS);
  }

  @override
  void initState() {
    super.initState();
    _loadShells();
    // Global handler so pressing/releasing ctrl flips the cursor even if
    // the mouse hasn't moved. `MouseRegion.onHover` only fires on motion,
    // so without this the hand cursor would lag behind the modifier
    // until the next mouse move.
    HardwareKeyboard.instance.addHandler(_onHardwareKeyEvent);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().ideActions.registerTerminalActions(
        onNewTerminal: () {
          final wd = context.read<AppState>().currentDirectory;
          if (wd != null) _addSession(wd);
        },
        onKillActive: () {
          if (_sessions.isNotEmpty) _killSession(_focusedSessionIndex);
        },
      );
    });
  }

  Future<void> _loadShells() async {
    final state = context.read<AppState>();
    final available = await ShellDiscovery.available();
    final stored = await state.prefs.getTerminalShellId();
    String? preferred = stored;
    if (preferred != null && !available.any((s) => s.id == preferred)) {
      preferred = null; // stored shell no longer present
    }
    preferred ??= available.isNotEmpty ? available.first.id : null;
    if (!mounted) return;
    setState(() {
      _availableShells = available;
      _preferredShellId = preferred;
      _shellsLoaded = true;
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onHardwareKeyEvent);
    _stopTermSelectionAutoScroll();
    try {
      context.read<AppState>().ideActions.unregisterTerminalActions();
    } catch (_) {
      // context might be unmounted during shutdown; safe to ignore.
    }
    for (final s in _sessions) {
      s.dispose();
    }
    super.dispose();
  }

  /// HardwareKeyboard handler: when ctrl is pressed or released we
  /// re-evaluate the cursor for the session currently under the mouse.
  /// Returning `false` lets the event continue propagating to focused
  /// widgets (terminal input, editor shortcuts, etc.) — we're only
  /// observing.
  bool _onHardwareKeyEvent(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.control) {
      _recomputeCtrlUrlCursor();
    }
    return false;
  }

  /// Recompute whether the cursor should show the hand affordance.
  /// Called from `MouseRegion.onHover` (mouse moved), `MouseRegion.onExit`
  /// (mouse left the terminal), and `_onHardwareKeyEvent` (ctrl
  /// pressed/released without mouse movement).
  void _recomputeCtrlUrlCursor() {
    if (!mounted) return;
    final s = _termHoveredSession;
    final pos = _termHoverPos;
    bool next = false;
    if (s != null && pos != null) {
      final ctrl = HardwareKeyboard.instance.isControlPressed;
      if (ctrl) {
        next = _hasUrlAtLocalPos(s, pos);
      }
    }
    if (next != _terminalCtrlHoverOverUrl) {
      setState(() => _terminalCtrlHoverOverUrl = next);
    }
  }

  /// Reuse the same render-object access trick the click handler uses,
  /// but only return whether the cell falls inside a URL match — no
  /// trim, no launch. Kept lightweight because it runs on every hover
  /// pixel.
  bool _hasUrlAtLocalPos(TerminalSession s, Offset localPos) {
    final state = s.viewKey.currentState;
    if (state == null) return false;
    try {
      final dynamic render = (state as dynamic).renderTerminal;
      if (render == null) return false;
      final CellOffset cell = render.getCellOffset(localPos);
      final lines = s.terminal.buffer.lines;
      if (cell.y < 0 || cell.y >= lines.length) return false;
      final lineText = lines[cell.y].getText();
      for (final match in _urlPattern.allMatches(lineText)) {
        if (cell.x >= match.start && cell.x < match.end) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  Future<void> _addSession(String wd, {String? shellOverride}) async {
    final session = TerminalSession(
      id: 'term_${DateTime.now().microsecondsSinceEpoch}',
      title: 'Terminal ${_sessions.length + 1}',
      workingDirectory: wd,
      onShellSwitched: (shell, reason) async {
        if (!mounted) return;
        // Intentionally do NOT persist the fallback as the new preferred
        // shell. The user's chosen shell stays their intent; the fallback is
        // only this session's working substitute. Otherwise a transient
        // failure (e.g. PowerShell 5.1 ConPTY 8009001d) permanently locks
        // the IDE into cmd.
        showDuckToast(context, '${S.terminalShellSwitched} (${shell.label})');
      },
    );
    _sessions.add(session);
    setState(() {
      final newIndex = _sessions.length - 1;
      if (_splitView && _focusedPane == 1) {
        _secondaryIndex = newIndex;
      } else {
        _activeIndex = newIndex;
      }
    });
    await session.start(preferredShellId: shellOverride ?? _preferredShellId);
    _focusActiveSession();
    if (mounted) setState(() {});
  }

  int get _focusedSessionIndex {
    if (_splitView && _focusedPane == 1 && _secondaryIndex != null) {
      return _secondaryIndex!.clamp(0, _sessions.length - 1);
    }
    return _activeIndex.clamp(0, _sessions.isEmpty ? 0 : _sessions.length - 1);
  }

  void _focusActiveSession() {
    if (!mounted || _sessions.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _sessions.isEmpty) return;
      _sessions[_focusedSessionIndex].focusNode.requestFocus();
    });
  }

  void _killSession(int index) {
    if (index < 0 || index >= _sessions.length) return;
    _sessions[index].dispose();
    setState(() {
      _sessions.removeAt(index);
      if (_sessions.isEmpty) {
        _activeIndex = 0;
        _secondaryIndex = null;
        _splitView = false;
        _focusedPane = 0;
      } else {
        if (index == _activeIndex) {
          _activeIndex = index.clamp(0, _sessions.length - 1);
        } else if (index < _activeIndex) {
          _activeIndex -= 1;
        } else {
          _activeIndex = _activeIndex.clamp(0, _sessions.length - 1);
        }
        if (_secondaryIndex != null) {
          if (_secondaryIndex == index) {
            _secondaryIndex = _firstNonActiveIndex();
          } else if (_secondaryIndex! > index) {
            _secondaryIndex = _secondaryIndex! - 1;
          }
        }
        if (_secondaryIndex == _activeIndex) {
          _secondaryIndex = _firstNonActiveIndex();
        }
        if (_secondaryIndex == null) _splitView = false;
        if (!_splitView || _secondaryIndex == null) _focusedPane = 0;
      }
    });
  }

  /// Drag-to-reorder. Mirrors `ReorderableListView`'s
  /// `(oldIndex, newIndex)` contract; we fix up `_activeIndex` so the
  /// visual focus follows the dragged tab if it was the active one, and
  /// stays put if a different tab was being moved.
  void _reorderSession(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _sessions.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= _sessions.length) return;
    setState(() {
      final s = _sessions.removeAt(oldIndex);
      _sessions.insert(newIndex, s);
      if (_activeIndex == oldIndex) {
        _activeIndex = newIndex;
      } else if (oldIndex < _activeIndex && newIndex >= _activeIndex) {
        _activeIndex -= 1;
      } else if (oldIndex > _activeIndex && newIndex <= _activeIndex) {
        _activeIndex += 1;
      }
      if (_secondaryIndex == oldIndex) {
        _secondaryIndex = newIndex;
      } else if (_secondaryIndex != null &&
          oldIndex < _secondaryIndex! &&
          newIndex >= _secondaryIndex!) {
        _secondaryIndex = _secondaryIndex! - 1;
      } else if (_secondaryIndex != null &&
          oldIndex > _secondaryIndex! &&
          newIndex <= _secondaryIndex!) {
        _secondaryIndex = _secondaryIndex! + 1;
      }
    });
  }

  int? _firstNonActiveIndex() {
    for (var i = 0; i < _sessions.length; i++) {
      if (i != _activeIndex) return i;
    }
    return null;
  }

  void _selectTerminalTab(int index) {
    if (index < 0 || index >= _sessions.length) return;
    setState(() {
      if (_splitView) {
        if (index == _activeIndex) {
          _focusedPane = 0;
        } else if (index == _secondaryIndex) {
          _focusedPane = 1;
        } else if (_focusedPane == 1) {
          _secondaryIndex = index;
        } else {
          _activeIndex = index;
        }
      } else {
        _activeIndex = index;
        _focusedPane = 0;
      }
    });
    _focusActiveSession();
  }

  void _focusSplitPane(int pane) {
    if (!_splitView || _focusedPane == pane) {
      _focusActiveSession();
      return;
    }
    setState(() => _focusedPane = pane);
    _focusActiveSession();
  }

  Future<void> _toggleSplitTerminals(String wd) async {
    if (_splitView) {
      setState(() {
        if (_focusedPane == 1 && _secondaryIndex != null) {
          _activeIndex = _secondaryIndex!;
        }
        _splitView = false;
        _secondaryIndex = null;
        _focusedPane = 0;
      });
      _focusActiveSession();
      return;
    }

    if (_sessions.length < 2) {
      setState(() {
        _splitView = true;
        _focusedPane = 1;
      });
      await _addSession(wd);
    } else {
      setState(() {
        _secondaryIndex = _firstNonActiveIndex();
        _splitView = _secondaryIndex != null;
        if (_splitView) _focusedPane = 1;
      });
    }
    _focusActiveSession();
  }

  Future<void> _changeShell(String id, String wd) async {
    final state = context.read<AppState>();
    await state.prefs.setTerminalShellId(id);
    setState(() {
      _preferredShellId = id;
      _splitView = false;
      _secondaryIndex = null;
      _focusedPane = 0;
    });
    if (_sessions.isNotEmpty) {
      _sessions[_activeIndex].dispose();
      _sessions.removeAt(_activeIndex);
    }
    await _addSession(wd, shellOverride: id);
  }

  /// Clear the persisted shell preference and respawn the active terminal
  /// using `ShellDiscovery.bestAvailable()`. Useful when an earlier
  /// auto-fallback locked the user into `cmd.exe` and a richer shell has
  /// since become discoverable (e.g. after the cmd-wrapping fix landed).
  Future<void> _resetShellPreference(String wd) async {
    final state = context.read<AppState>();
    await state.prefs.setTerminalShellId(null);
    final fallback = _availableShells.isNotEmpty
        ? _availableShells.first.id
        : null;
    setState(() {
      _preferredShellId = fallback;
      _splitView = false;
      _secondaryIndex = null;
      _focusedPane = 0;
    });
    if (_sessions.isNotEmpty) {
      _sessions[_activeIndex].dispose();
      _sessions.removeAt(_activeIndex);
    }
    await _addSession(wd, shellOverride: fallback);
    if (mounted) {
      showDuckToast(context, S.terminalShellResetDone);
    }
  }

  Widget _buildTerminalView(
    BuildContext context,
    AppState appState,
    TerminalSession s,
    bool autofocus,
  ) {
    final terminalView = TerminalView(
      s.terminal,
      key: s.viewKey,
      controller: s.controller,
      scrollController: s.scrollController,
      focusNode: s.focusNode,
      autofocus: autofocus,
      textStyle: TerminalStyle(
        fontFamily: DuckTheme.monoFont,
        fontSize: appState.editorFontSize - 0.5,
      ),
      theme: const TerminalTheme(
        cursor: Color(0xFF8FBCBB),
        selection: Color(0x55434C5E),
        foreground: Color(0xFFD8DEE9),
        // Body matches the sidebar tone (`bgDeeper`) — Cursor's
        // pattern: terminal section, file explorer, and chat panel
        // all share the same background family. Hard-coded inline
        // because `TerminalTheme` is `const`.
        background: Color(0xFF191C22),
        black: Color(0xFF272C36),
        red: Color(0xFFBF616A),
        green: Color(0xFFA3BE8C),
        yellow: Color(0xFFEBCB8B),
        blue: Color(0xFF81A1C1),
        magenta: Color(0xFF7D7C9B),
        cyan: Color(0xFF88C0D0),
        white: Color(0xFFE5E9F0),
        brightBlack: Color(0xFF4C566A),
        brightRed: Color(0xFFBF616A),
        brightGreen: Color(0xFFA3BE8C),
        brightYellow: Color(0xFFEBCB8B),
        brightBlue: Color(0xFF81A1C1),
        brightMagenta: Color(0xFFB48EAD),
        brightCyan: Color(0xFF8FBCBB),
        brightWhite: Color(0xFFECEFF4),
        searchHitBackground: Color(0x6688C0D0),
        searchHitBackgroundCurrent: Color(0xCC88C0D0),
        searchHitForeground: Color(0xFF191C22),
      ),
      backgroundOpacity: 0,
      hardwareKeyboardOnly: _useHardwareKeyboardOnly,
      padding: const EdgeInsets.all(8),
      // NOTE: `onTapUp` is intentionally NOT wired here. xterm 4.0.0's
      // primary-tap callback never fires (the gesture detector declares
      // the field but doesn't bind it to the TapGestureRecognizer — see
      // `TerminalSession.viewKey` for the full explanation). Ctrl+click
      // URL handling is implemented via the raw `Listener` below, which
      // converts pointer positions to buffer cells through xterm's render
      // object. `onSecondaryTapUp` IS wired correctly upstream, so the
      // right-click context menu works without this workaround.
      // Right-click ergonomics:
      //  - Selection present: copy-and-clear (no menu).
      //  - No selection: open the context menu.
      onSecondaryTapUp: (details, offset) {
        final selection = s.controller.selection;
        if (selection != null) {
          final text = s.terminal.buffer.getText(selection);
          Clipboard.setData(ClipboardData(text: text));
          s.controller.clearSelection();
          return;
        }
        _showContextMenu(context, details.globalPosition, s, appState);
      },
      // Terminal-convention keybindings:
      //  - Ctrl+Shift+C copies the selection.
      //  - Ctrl+Shift+V pastes from clipboard.
      onKeyEvent: (focusNode, event) {
        if (event is KeyDownEvent) {
          final ctrl = HardwareKeyboard.instance.isControlPressed;
          final shift = HardwareKeyboard.instance.isShiftPressed;
          if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.keyC) {
            if (s.controller.selection != null) {
              final text = s.terminal.buffer.getText(s.controller.selection!);
              Clipboard.setData(ClipboardData(text: text));
              s.controller.clearSelection();
              return KeyEventResult.handled;
            }
          }
          if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.keyV) {
            Clipboard.getData(Clipboard.kTextPlain).then((data) {
              if (data != null && data.text != null) {
                s.terminal.paste(data.text!);
              }
            });
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
    );

    return MouseRegion(
      cursor: _terminalCtrlHoverOverUrl
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onHover: (e) {
        _termHoveredSession = s;
        _termHoverPos = e.localPosition;
        _recomputeCtrlUrlCursor();
      },
      onExit: (_) {
        if (identical(_termHoveredSession, s)) {
          _termHoveredSession = null;
          _termHoverPos = null;
          _recomputeCtrlUrlCursor();
        }
      },
      // `HitTestBehavior.translucent` lets xterm's internal gesture
      // recognizers still receive the same events (focus, selection,
      // cursor positioning) — we're only watching for "ctrl + click on
      // a URL" without taking the gesture away from the terminal.
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) => _onTerminalPointerDown(s, e),
        onPointerMove: (e) => _onTerminalPointerMove(s, e),
        onPointerSignal: (e) => _onTerminalPointerSignal(s, e),
        onPointerUp: (e) => _onTerminalPointerUp(s, e),
        onPointerCancel: (_) => _resetTermPointerState(),
        child: terminalView,
      ),
    );
  }

  void _onTerminalPointerDown(TerminalSession s, PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if (e.buttons != kPrimaryMouseButton) return;
    _termDownPos = e.localPosition;
    _termDownTime = e.timeStamp;
    _termDownPointer = e.pointer;
    _termSelectionSession = s;
    _termSelectionPointer = e.pointer;
    _termSelectionBaseCell = _cellAtGlobalPosition(s, e.position);
    _termSelectionStartGlobal = e.position;
    _termSelectionLastGlobal = e.position;
    _termSelectionDragging = false;
  }

  void _onTerminalPointerMove(TerminalSession s, PointerMoveEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if (_termSelectionPointer != e.pointer ||
        !identical(_termSelectionSession, s)) {
      return;
    }
    _termSelectionLastGlobal = e.position;
    final start = _termSelectionStartGlobal;
    if (!_termSelectionDragging && start != null) {
      _termSelectionDragging =
          (e.position - start).distance > _kTermClickSlopPx;
    }
    if (_termSelectionDragging) {
      _scheduleFixedAnchorSelectionUpdate(s);
      _updateTermSelectionAutoScroll(s);
    }
  }

  void _onTerminalPointerSignal(TerminalSession s, PointerSignalEvent e) {
    if (!_termSelectionDragging || !identical(_termSelectionSession, s)) {
      return;
    }
    if (e is PointerScrollEvent) {
      _termSelectionLastGlobal = e.position;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_termSelectionSession, s)) return;
        _updateFixedAnchorSelection(s);
      });
    }
  }

  void _onTerminalPointerUp(TerminalSession s, PointerUpEvent e) {
    if (e.kind != PointerDeviceKind.mouse) {
      _resetTermPointerState();
      return;
    }
    if (_termDownPos == null || _termDownPointer != e.pointer) {
      _resetTermPointerState();
      return;
    }
    final delta = (e.localPosition - _termDownPos!).distance;
    final dt = e.timeStamp - (_termDownTime ?? e.timeStamp);
    final localPos = e.localPosition;
    _resetTermPointerState();
    if (delta > _kTermClickSlopPx) return;
    if (dt > _kTermClickMaxDuration) return;
    // Match VS Code / Cursor / Windows Terminal convention: URL navigation
    // is gated behind ctrl. Plain click stays a plain click so cursor
    // positioning + selection-start in the terminal still feel native.
    if (!HardwareKeyboard.instance.isControlPressed) return;
    _openUrlAtLocalPos(s, localPos);
  }

  void _resetTermPointerState() {
    _resetTermClick();
    _termSelectionSession = null;
    _termSelectionPointer = null;
    _termSelectionBaseCell = null;
    _termSelectionStartGlobal = null;
    _termSelectionLastGlobal = null;
    _termSelectionDragging = false;
    _stopTermSelectionAutoScroll();
  }

  void _resetTermClick() {
    _termDownPos = null;
    _termDownTime = null;
    _termDownPointer = null;
  }

  void _scheduleFixedAnchorSelectionUpdate(TerminalSession s) {
    scheduleMicrotask(() {
      if (!mounted || !identical(_termSelectionSession, s)) return;
      _updateFixedAnchorSelection(s);
    });
  }

  void _updateFixedAnchorSelection(TerminalSession s) {
    final base = _termSelectionBaseCell;
    final global = _termSelectionLastGlobal;
    if (base == null || global == null) return;

    final extent = _cellAtGlobalPosition(s, global);
    if (extent == null) return;

    // Match xterm's inclusive character-drag behavior while preserving the
    // original buffer cell as the fixed selection anchor across scrolls.
    final adjustedExtent = extent.x >= base.x
        ? CellOffset(extent.x + 1, extent.y)
        : extent;
    s.controller.setSelection(
      s.terminal.buffer.createAnchorFromOffset(base),
      s.terminal.buffer.createAnchorFromOffset(adjustedExtent),
    );
  }

  CellOffset? _cellAtGlobalPosition(TerminalSession s, Offset globalPosition) {
    final state = s.viewKey.currentState;
    if (state == null) return null;
    try {
      final dynamic render = (state as dynamic).renderTerminal;
      if (render == null) return null;
      final Offset local = render.globalToLocal(globalPosition) as Offset;
      return render.getCellOffset(local) as CellOffset;
    } catch (_) {
      return null;
    }
  }

  void _updateTermSelectionAutoScroll(TerminalSession s) {
    if (!_termSelectionDragging || !identical(_termSelectionSession, s)) {
      _stopTermSelectionAutoScroll();
      return;
    }
    if (_termSelectionScrollOverflow(s) == 0) {
      _stopTermSelectionAutoScroll();
      return;
    }
    _termSelectionAutoScrollTimer ??= Timer.periodic(
      _kTermSelectionAutoScrollTick,
      (_) => _tickTermSelectionAutoScroll(),
    );
  }

  void _tickTermSelectionAutoScroll() {
    final s = _termSelectionSession;
    if (s == null || !_termSelectionDragging) {
      _stopTermSelectionAutoScroll();
      return;
    }
    final overflow = _termSelectionScrollOverflow(s);
    if (overflow == 0 || !s.scrollController.hasClients) {
      _stopTermSelectionAutoScroll();
      return;
    }

    final position = s.scrollController.position;
    final lineHeight = _terminalLineHeight(s);
    final speed = (overflow.abs() / 24).clamp(0.6, 6.0);
    final next = (position.pixels + overflow.sign * lineHeight * speed).clamp(
      position.minScrollExtent,
      position.maxScrollExtent,
    );
    if (next != position.pixels) {
      s.scrollController.jumpTo(next);
    }
    _updateFixedAnchorSelection(s);
  }

  double _termSelectionScrollOverflow(TerminalSession s) {
    final global = _termSelectionLastGlobal;
    final state = s.viewKey.currentState;
    if (global == null || state == null) return 0;
    try {
      final dynamic render = (state as dynamic).renderTerminal;
      if (render == null) return 0;
      final Offset local = render.globalToLocal(global) as Offset;
      final Size size = render.size as Size;
      if (local.dy < 0) return local.dy;
      if (local.dy > size.height) return local.dy - size.height;
      return 0;
    } catch (_) {
      return 0;
    }
  }

  double _terminalLineHeight(TerminalSession s) {
    final state = s.viewKey.currentState;
    if (state == null) return 16;
    try {
      final dynamic render = (state as dynamic).renderTerminal;
      return render.lineHeight as double;
    } catch (_) {
      return 16;
    }
  }

  void _stopTermSelectionAutoScroll() {
    _termSelectionAutoScrollTimer?.cancel();
    _termSelectionAutoScrollTimer = null;
  }

  /// Resolve the local pointer position to a `CellOffset` via xterm's
  /// `RenderTerminal`, then hand it to `_openUrlAtCell`. We can't reach
  /// `RenderTerminal` through public types — `xterm/lib/ui.dart` exports
  /// `TerminalView` and `TerminalViewState` but NOT `RenderTerminal` or
  /// `render.dart` itself. The getter `TerminalViewState.renderTerminal`
  /// is public on a public class though, so we can call it via dynamic
  /// dispatch and forward to `getCellOffset(Offset)`, which returns the
  /// absolute buffer row index that `terminal.buffer.lines[y]` expects.
  bool _openUrlAtLocalPos(TerminalSession s, Offset localPos) {
    final state = s.viewKey.currentState;
    if (state == null) return false;
    try {
      final dynamic render = (state as dynamic).renderTerminal;
      if (render == null) return false;
      final CellOffset cell = render.getCellOffset(localPos);
      return _openUrlAtCell(s, cell);
    } catch (e) {
      debugPrint('Terminal URL ctrl+click: failed to resolve cell: $e');
      return false;
    }
  }

  Widget _buildSplitPane(
    BuildContext context,
    AppState appState,
    int pane,
    int sessionIndex,
  ) {
    final focused = _focusedPane == pane;
    final session = _sessions[sessionIndex];
    return Listener(
      behavior: HitTestBehavior.translucent,
      // `TerminalView` owns its own gesture/focus handling, so a parent
      // GestureDetector can lose the gesture arena and only the header click
      // updates `_focusedPane`. A raw pointer listener fires before the child
      // consumes the event, making clicks inside the terminal body switch the
      // visual focus just like clicking the pane header.
      onPointerDown: (_) => _focusSplitPane(pane),
      child: Column(
        children: [
          Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: focused ? DuckColors.bgRaised : DuckColors.bgDeeper,
              border: Border(
                top: BorderSide(
                  color: focused ? DuckColors.accentCyan : Colors.transparent,
                  width: 1.5,
                ),
                bottom: const BorderSide(
                  color: DuckColors.glassSeam,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 12,
                  color: focused ? DuckColors.accentCyan : DuckColors.fgSubtle,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    session.title + (session.usingFallback ? ' *' : ''),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: focused
                          ? DuckColors.fgPrimary
                          : DuckColors.fgMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: _buildTerminalView(context, appState, session, focused),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        final wd = appState.currentDirectory;

        if (wd != null && _initializedFor != wd && _shellsLoaded) {
          _initializedFor = wd;
          for (final s in _sessions) {
            s.dispose();
          }
          _sessions.clear();
          _activeIndex = 0;
          _secondaryIndex = null;
          _splitView = false;
          _focusedPane = 0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _addSession(wd);
          });
        }

        if (wd == null) {
          return Container(color: DuckColors.bgDeeper);
        }

        return Column(
          children: [
            _TerminalTabBar(
              sessions: _sessions,
              primaryIndex: _activeIndex,
              secondaryIndex: _secondaryIndex,
              focusedIndex: _focusedSessionIndex,
              shells: _availableShells,
              preferredShellId: _preferredShellId,
              onSelect: _selectTerminalTab,
              onClose: _killSession,
              onReorder: _reorderSession,
              onNew: () => _addSession(wd),
              splitView: _splitView,
              onToggleSplit: () => _toggleSplitTerminals(wd),

              onChangeShell: (id) => _changeShell(id, wd),
              onResetShell: () => _resetShellPreference(wd),
            ),
            Expanded(
              child: Container(
                // `bgDeeper` matches the sidebar surfaces (file
                // explorer + chat panel) — Cursor convention: the
                // terminal section sits at the same elevation as the
                // sidebars, with the editor canvas as the only raised
                // surface. The tab strip above also tints to
                // `bgDeeper` so the panel still reads as one
                // continuous slab.
                color: DuckColors.bgDeeper,
                child: _sessions.isEmpty
                    ? const Center(
                        child: Text(
                          S.terminalNoActive,
                          style: TextStyle(
                            color: DuckColors.fgSubtle,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : _splitView &&
                          _secondaryIndex != null &&
                          _secondaryIndex! < _sessions.length
                    ? MultiSplitViewTheme(
                        data: MultiSplitViewThemeData(
                          dividerThickness: 1,
                          dividerHandleBuffer: 8,
                          dividerPainter: DividerPainters.background(
                            color: DuckColors.glassSeam,
                            highlightedColor: DuckColors.accentCyan.withValues(
                              alpha: 0.4,
                            ),
                          ),
                        ),
                        child: MultiSplitView(
                          axis: Axis.horizontal,
                          initialAreas: [
                            Area(
                              flex: 0.5,
                              builder: (context, area) => _buildSplitPane(
                                context,
                                appState,
                                0,
                                _activeIndex,
                              ),
                            ),
                            Area(
                              flex: 0.5,
                              builder: (context, area) => _buildSplitPane(
                                context,
                                appState,
                                1,
                                _secondaryIndex!,
                              ),
                            ),
                          ],
                        ),
                      )
                    : IndexedStack(
                        index: _activeIndex,
                        children: _sessions.asMap().entries.map((entry) {
                          final i = entry.key;
                          final s = entry.value;
                          return _buildTerminalView(
                            context,
                            appState,
                            s,
                            i == _activeIndex,
                          );
                        }).toList(),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _showContextMenu(
    BuildContext context,
    Offset position,
    TerminalSession session,
    AppState appState,
  ) async {
    final selection = session.controller.selection;
    final hasSelection = selection != null;
    // If the user has a URL highlighted, the "Open URL" item gets
    // promoted to the top of the menu. This is the discoverability
    // surface for Ctrl+Click — users who don't know about the
    // shortcut still find the action by selecting + right-clicking.
    final selectionUrl = _urlInSelection(session);

    final value = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx + 1,
        position.dy + 1,
      ),
      items: [
        if (selectionUrl != null) ...[
          PopupMenuItem(
            value: 'openUrl',
            child: Row(
              children: const [
                Icon(Icons.open_in_new, size: 16),
                SizedBox(width: 8),
                Text(S.terminalContextOpenUrl),
              ],
            ),
          ),
          const PopupMenuDivider(),
        ],
        PopupMenuItem(
          value: 'copy',
          enabled: hasSelection,
          child: Row(
            children: const [
              Icon(Icons.copy, size: 16),
              SizedBox(width: 8),
              Text(S.terminalContextCopy),
            ],
          ),
        ),
        PopupMenuItem(
          value: 'paste',
          child: Row(
            children: const [
              Icon(Icons.paste, size: 16),
              SizedBox(width: 8),
              Text(S.terminalContextPaste),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'copyToChat',
          child: Row(
            children: const [
              Icon(Icons.forum_outlined, size: 16),
              SizedBox(width: 8),
              Text(S.terminalContextCopyToChat),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'clear',
          child: Row(
            children: const [
              Icon(Icons.clear, size: 16),
              SizedBox(width: 8),
              Text(S.terminalContextClear),
            ],
          ),
        ),
      ],
    );

    if (value == 'openUrl') {
      if (selectionUrl != null) await _launchUrl(selectionUrl);
    } else if (value == 'copy') {
      final text = session.terminal.buffer.getText(selection!);
      await Clipboard.setData(ClipboardData(text: text));
      session.controller.clearSelection();
    } else if (value == 'paste') {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (data != null && data.text != null) {
        session.terminal.paste(data.text!);
      }
    } else if (value == 'copyToChat') {
      if (!context.mounted) return;
      _copyToChat(context, appState);
    } else if (value == 'clear') {
      session.terminal.buffer.clear();
    }
  }

  /// URL pattern for ctrl+click detection in terminal output.
  /// Matches `http://` and `https://` schemes; deliberately conservative
  /// on terminating chars so a URL followed by punctuation in prose
  /// (e.g. `see http://foo.bar/baz.`) doesn't swallow the trailing
  /// punctuation. Trailing `.,;:!?)>]}"'` is trimmed in
  /// `_extractUrlAtCell` after the regex match.
  static final RegExp _urlPattern = RegExp(
    r'https?://[^\s<>()\[\]{}"'
    "'"
    r'`]+',
    caseSensitive: false,
  );

  /// Walk the line at `offset.y`, find a URL substring containing the
  /// click column, trim trailing punctuation, and launch it. Silent
  /// no-op if the click didn't land on a URL — preserves the user's
  /// muscle memory for ctrl+click in non-URL areas (no ghost
  /// browser launches).
  bool _openUrlAtCell(TerminalSession s, CellOffset offset) {
    final lines = s.terminal.buffer.lines;
    if (offset.y < 0 || offset.y >= lines.length) return false;
    final lineText = lines[offset.y].getText();
    for (final match in _urlPattern.allMatches(lineText)) {
      // `match.end` is exclusive — accept clicks strictly inside the
      // URL span, otherwise an adjacent click wraps to the wrong URL.
      if (offset.x >= match.start && offset.x < match.end) {
        var url = match[0]!;
        const trailing = '.,;:!?)>]}"\'`';
        while (url.isNotEmpty && trailing.contains(url[url.length - 1])) {
          url = url.substring(0, url.length - 1);
        }
        if (url.isNotEmpty) {
          _launchUrl(url);
          return true;
        }
        return false;
      }
    }
    return false;
  }

  /// Cross-platform URL launch — same pattern `MediaController.openInBrowser`
  /// uses. On Windows, `cmd /c start "" <url>` invokes the registered
  /// http(s) handler; the empty `""` is the mandatory window-title
  /// argument so URLs containing spaces don't get treated as a title.
  Future<void> _launchUrl(String url) async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (e) {
      debugPrint('Failed to open URL "$url": $e');
    }
  }

  /// Best-effort URL extraction from a selection. Returns the FIRST
  /// URL that appears in the selected text, or null if none found.
  /// Used by the right-click "Open URL" menu item.
  String? _urlInSelection(TerminalSession s) {
    final selection = s.controller.selection;
    if (selection == null) return null;
    final text = s.terminal.buffer.getText(selection);
    final match = _urlPattern.firstMatch(text);
    if (match == null) return null;
    var url = match[0]!;
    const trailing = '.,;:!?)>]}"\'`';
    while (url.isNotEmpty && trailing.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url.isEmpty ? null : url;
  }

  void _copyToChat(BuildContext context, AppState appState) {
    if (_sessions.isEmpty) return;
    final s = _sessions[_activeIndex];
    String text = '';
    final selection = s.controller.selection;
    if (selection != null) {
      text = s.terminal.buffer.getText(selection);
    } else {
      final lines = s.terminal.buffer.lines;
      final start = lines.length > 50 ? lines.length - 50 : 0;
      final sb = StringBuffer();
      for (int i = start; i < lines.length; i++) {
        sb.writeln(lines[i].toString());
      }
      text = sb.toString();
    }
    if (text.trim().isEmpty) {
      showDuckToast(context, S.terminalNoOutput);
      return;
    }
    appState.appendTerminalOutputToChat(text);
    showDuckToast(context, S.terminalCopyToChatToast);
  }
}

class _TerminalTabBar extends StatelessWidget {
  final List<TerminalSession> sessions;
  final int primaryIndex;
  final int? secondaryIndex;
  final int focusedIndex;
  final List<ShellSpec> shells;
  final String? preferredShellId;
  final ValueChanged<int> onSelect;
  final ValueChanged<int> onClose;
  final void Function(int oldIndex, int newIndex) onReorder;
  final VoidCallback onNew;
  final bool splitView;
  final VoidCallback onToggleSplit;
  final ValueChanged<String> onChangeShell;
  final VoidCallback onResetShell;

  const _TerminalTabBar({
    required this.sessions,
    required this.primaryIndex,
    required this.secondaryIndex,
    required this.focusedIndex,
    required this.shells,
    required this.preferredShellId,
    required this.onSelect,
    required this.onClose,
    required this.onReorder,
    required this.onNew,
    required this.splitView,
    required this.onToggleSplit,
    required this.onChangeShell,
    required this.onResetShell,
  });

  @override
  Widget build(BuildContext context) {
    return DuckGlass(
      tint: DuckColors.bgDeeper,
      border: const Border(
        bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: SizedBox(
        height: 30,
        child: Row(
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text(S.terminalHeader, style: DuckTheme.titleS),
            ),
            Expanded(
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                itemCount: sessions.length,
                onReorder: onReorder,
                proxyDecorator: (child, index, anim) => Material(
                  color: Colors.transparent,
                  elevation: 0,
                  child: child,
                ),
                itemBuilder: (context, i) {
                  final s = sessions[i];
                  final isFocused = i == focusedIndex;
                  final isMounted =
                      i == primaryIndex ||
                      (secondaryIndex != null && i == secondaryIndex);
                  return ReorderableDragStartListener(
                    key: ValueKey(s.id),
                    index: i,
                    child: _TerminalTab(
                      title: s.title + (s.usingFallback ? ' *' : ''),
                      isFocused: isFocused,
                      isMounted: isMounted,
                      onActivate: () => onSelect(i),
                      onClose: () => onClose(i),
                    ),
                  );
                },
              ),
            ),
            if (shells.isNotEmpty)
              _ShellPicker(
                shells: shells,
                current: preferredShellId,
                onChanged: onChangeShell,
                onReset: onResetShell,
              ),

            IconButton(
              icon: Icon(
                splitView ? Icons.fullscreen_exit : Icons.view_column_outlined,
                size: 14,
              ),
              tooltip: splitView ? S.terminalUnsplitView : S.terminalSplitView,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onToggleSplit,
            ),
            IconButton(
              icon: const Icon(Icons.add, size: 14),
              tooltip: S.terminalNew,
              padding: const EdgeInsets.all(6),
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: onNew,
            ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

class _ShellPicker extends StatelessWidget {
  /// Sentinel value used by the popup menu to mean "clear the persisted
  /// shell preference and restart with the best available shell". Picked
  /// to never collide with a real [ShellSpec.id].
  static const String _kResetSentinel = '__reset_default__';

  final List<ShellSpec> shells;
  final String? current;
  final ValueChanged<String> onChanged;
  final VoidCallback onReset;

  const _ShellPicker({
    required this.shells,
    required this.current,
    required this.onChanged,
    required this.onReset,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.terminalShell,
      child: PopupMenuButton<String>(
        tooltip: '',
        position: PopupMenuPosition.under,
        onSelected: (value) {
          if (value == _kResetSentinel) {
            onReset();
          } else {
            onChanged(value);
          }
        },
        itemBuilder: (ctx) => [
          ...shells.map(
            (s) => PopupMenuItem<String>(
              value: s.id,
              height: 30,
              child: Row(
                children: [
                  Icon(
                    s.id == current ? Icons.check : Icons.terminal,
                    size: 12,
                    color: s.id == current
                        ? DuckColors.accentMint
                        : DuckColors.fgSubtle,
                  ),
                  const SizedBox(width: 8),
                  Text(s.label, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
          const PopupMenuDivider(),
          PopupMenuItem<String>(
            value: _kResetSentinel,
            height: 30,
            child: Row(
              children: const [
                Icon(Icons.refresh, size: 12, color: DuckColors.fgSubtle),
                SizedBox(width: 8),
                Text(
                  S.terminalShellResetDefault,
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
        ],
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: DuckColors.bgRaised,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.terminal, size: 11, color: DuckColors.fgMuted),
              const SizedBox(width: 4),
              Text(
                _labelForId(current) ?? S.terminalShell,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: DuckColors.fgMuted,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.arrow_drop_down,
                size: 12,
                color: DuckColors.fgSubtle,
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _labelForId(String? id) {
    if (id == null) return null;
    for (final s in shells) {
      if (s.id == id) return s.label;
    }
    return null;
  }
}

/// Single terminal tab. Mirrors `_EditorTab`: hover lift, middle-click
/// closes, animated tint transitions for liveness. The accent stripe on
/// active sits on the **top** edge so it points at the chrome above
/// (consistent with editor tabs).
class _TerminalTab extends StatefulWidget {
  final String title;
  final bool isFocused;
  final bool isMounted;
  final VoidCallback onActivate;
  final VoidCallback onClose;
  const _TerminalTab({
    required this.title,
    required this.isFocused,
    required this.isMounted,
    required this.onActivate,
    required this.onClose,
  });

  @override
  State<_TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<_TerminalTab> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // The whole terminal panel sits on `bgDeeper` (matches the
    // sidebar surfaces). Active tabs stay transparent so the parent
    // glass tint shows through and reads as the same slab as the
    // body. Active vs inactive is communicated by the cyan icon +
    // `fgPrimary` text below — no background lift needed.
    final Color tabColor;
    if (widget.isFocused) {
      tabColor = DuckColors.bgRaisedHi.withValues(alpha: 0.35);
    } else if (widget.isMounted) {
      tabColor = DuckColors.bgChip.withValues(alpha: 0.55);
    } else if (_hover) {
      tabColor = DuckColors.bgRaisedHi.withValues(alpha: 0.45);
    } else {
      tabColor = Colors.transparent;
    }
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
        child: InkWell(
          onTap: widget.onActivate,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(color: tabColor),
            child: Row(
              children: [
                Icon(
                  Icons.terminal,
                  size: 12,
                  color: widget.isFocused
                      ? DuckColors.accentCyan
                      : widget.isMounted
                      ? DuckColors.accentMint
                      : DuckColors.fgSubtle,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.title,
                  style: TextStyle(
                    fontSize: 11,
                    color: widget.isFocused
                        ? DuckColors.fgPrimary
                        : DuckColors.fgMuted,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: widget.onClose,
                  child: const Icon(
                    Icons.close,
                    size: 11,
                    color: DuckColors.fgSubtle,
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
