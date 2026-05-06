import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/media_controller.dart';
import '../../providers/ssh_controller.dart';
import '../../services/file_kind.dart';
import '../../services/language_detector.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';
import '../menu_bar.dart';
import '../process_manager/process_manager_view.dart';
import '../settings_view.dart';
import '../side_panes_column.dart';
import '../common/duck_toast.dart';
import 'autocomplete_overlay.dart';
import 'binary_preview.dart';
import 'editor_themes.dart';
import 'indent_guides.dart';
import 'markdown_preview.dart';
import 'recent_edits_overlay.dart';
import 'unsaved_changes_dialog.dart';

class Editor extends StatefulWidget {
  const Editor({super.key});

  @override
  State<Editor> createState() => _EditorState();
}

class _EditorState extends State<Editor> {
  String? _primaryPath;
  String? _secondaryPath;
  int _focusedPane = 0;
  final Set<String> _markdownPreviewing = {};
  bool _splitView = false;

  @override
  void dispose() {
    super.dispose();
  }

  void _syncPaneAssignments(AppState appState) {
    final active = appState.activeFile;
    if (active == null) {
      _primaryPath = null;
      _secondaryPath = null;
      return;
    }

    final openPaths = appState.openFiles.map((f) => f.path).toSet();
    if (_primaryPath != null && !openPaths.contains(_primaryPath)) {
      _primaryPath = null;
    }
    if (_secondaryPath != null && !openPaths.contains(_secondaryPath)) {
      _secondaryPath = null;
    }

    if (_primaryPath == null) {
      _primaryPath = active.path;
    } else if (!_splitView &&
        _primaryPath != active.path &&
        openPaths.contains(active.path)) {
      _primaryPath = active.path;
    } else if (_splitView &&
        _primaryPath != active.path &&
        _secondaryPath != active.path &&
        openPaths.contains(active.path)) {
      if (_focusedPane == 1) {
        _secondaryPath = active.path;
      } else {
        _primaryPath = active.path;
      }
    }
  }

  void _activateFile(AppState appState, File file) {
    setState(() {
      if (_splitView && _focusedPane == 1) {
        _secondaryPath = file.path;
      } else {
        _primaryPath = file.path;
      }
    });
    appState.setActiveFile(file);
  }

  /// Close a single tab. If the buffer has unsaved changes, prompt
  /// the user (Save / Don't Save / Cancel) before destroying state.
  ///
  /// Returns true if the file was closed, false if the user cancelled
  /// or if the save attempt failed and we kept the tab open. Callers
  /// that loop over multiple files (Close Others / Close All) check
  /// the return value and abort the rest of the batch on a cancel —
  /// "Cancel" should mean "stop closing things", not "skip this one
  /// and move on".
  Future<bool> _closeFile(AppState appState, File file) async {
    if (appState.isFileDirty(file.path)) {
      final choice = await showUnsavedChangesDialog(context, file: file);
      if (!mounted) return false;
      switch (choice) {
        case UnsavedChangesChoice.cancel:
          return false;
        case UnsavedChangesChoice.save:
          final saved = await _saveBeforeClose(appState, file);
          if (!mounted) return false;
          if (!saved) return false;
        case UnsavedChangesChoice.discard:
          break;
      }
    }
    setState(() {
      if (_primaryPath == file.path) _primaryPath = null;
      if (_secondaryPath == file.path) _secondaryPath = null;
    });
    appState.closeFile(file);
    return true;
  }

  /// Save handler used by the close-confirm flow. Routes named files
  /// through `saveFileByPath` and untitled files through a save-as
  /// name prompt (mirrors menu_bar's File → Save behaviour for
  /// untitled tabs). Returns true on success — false either
  /// represents a write error or the user dismissing the save-as
  /// prompt without picking a name. Caller treats false as "abort
  /// the close, leave the tab open".
  Future<bool> _saveBeforeClose(AppState appState, File file) async {
    if (AppState.isUntitledTab(file.path)) {
      final name = await _promptSaveAsName();
      if (name == null || name.trim().isEmpty) return false;
      final dir = appState.currentDirectory ?? '.';
      final realPath = '$dir${Platform.pathSeparator}${name.trim()}';
      final ok = await appState.saveUntitledAs(file.path, realPath);
      if (!mounted) return ok;
      if (!ok) {
        showDuckToast(context, S.error);
        return false;
      }
      appState.refreshDirectory();
      return true;
    }
    await appState.saveFileByPath(file.path);
    return !appState.isFileDirty(file.path);
  }

  Future<String?> _promptSaveAsName() async {
    String name = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.border, width: 0.5),
        ),
        title: const Text(
          S.unsavedDialogSaveAs,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        content: SizedBox(
          width: 320,
          child: TextField(
            autofocus: true,
            style: const TextStyle(fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'filename.dart',
              isDense: true,
              border: OutlineInputBorder(),
            ),
            onChanged: (v) => name = v,
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, name),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentCyan,
              foregroundColor: DuckColors.bgDeepest,
            ),
            child: const Text(S.unsavedDialogSave),
          ),
        ],
      ),
    );
  }

  void _toggleSplitView(AppState appState) {
    setState(() {
      if (_splitView) {
        _splitView = false;
        _secondaryPath = null;
        _focusedPane = 0;
      } else {
        _splitView = true;
        _focusedPane = 1;
        _secondaryPath = null;
      }
    });
  }

  String? get _focusedPath => _focusedPane == 1 ? _secondaryPath : _primaryPath;

  String _languageIdFor(AppState appState, String path) {
    final override = appState.languageOverrideFor(path);
    final detected = LanguageDetector.detect(
      path,
      appState.fileContentFor(path),
    );
    return override ?? detected.id;
  }

  bool _isMarkdownFile(AppState appState, String? path) {
    if (path == null) return false;
    final langId = _languageIdFor(appState, path);
    return langId == 'markdown' ||
        path.toLowerCase().endsWith('.md') ||
        path.toLowerCase().endsWith('.markdown');
  }

  Widget _buildPane(AppState appState, int paneIndex, String? path) {
    final focused = _focusedPane == paneIndex;
    if (path == null) {
      return _EmptyEditorPane(
        focused: focused,
        onTap: () => setState(() => _focusedPane = paneIndex),
      );
    }
    // Settings sentinel — render the full settings panel instead of a code editor.
    if (AppState.isSettingsTab(path)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
        child: const SettingsView(),
      );
    }
    // Process manager sentinel — same pattern as settings: a
    // virtual tab whose content is its own widget tree, not a
    // code buffer. Routed before the binary/text branches so a
    // file literally named `__process_manager__` (extremely
    // unlikely in practice) couldn't accidentally hijack the UI.
    if (AppState.isProcessManagerTab(path)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
        child: const ProcessManagerView(),
      );
    }

    // Binary / media files — image, audio, video, archives, fonts,
    // executables, etc. Don't try to render these in the code editor;
    // route to BinaryPreviewPane which uses Image.file for images and
    // an "Open externally" card for everything else. Untitled tabs
    // have no extension so they fall through to the text path.
    final kind = FileKindDetector.detect(path);
    if (kind != FileKind.text && !path.startsWith(AppState.untitledPrefix)) {
      return BinaryPreviewPane(
        key: ValueKey('binary-pane-$paneIndex-$path'),
        file: File(path),
        kind: kind,
        onFocus: () {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
      );
    }

    final isMarkdown = _isMarkdownFile(appState, path);
    final showingPreview = isMarkdown && _markdownPreviewing.contains(path);
    return _EditorPane(
      key: ValueKey('editor-pane-$paneIndex-$path'),
      appState: appState,
      path: path,
      focused: focused,
      showingPreview: showingPreview,
      onFocus: () {
        setState(() => _focusedPane = paneIndex);
        final file = appState.openFiles.firstWhere((f) => f.path == path);
        appState.setActiveFile(file);
      },
    );
  }

  // Default + minimum width for the side-panes slot when it's
  // mounted next to the IDE body. Mirrors the v1.4 root-layout
  // sizing so the muscle-memory width is preserved across the
  // v1.4 → v1.5 lift-back-into-editor.
  static const double _sidePanesOptimalWidth = 380;
  static const double _sidePanesMinWidth = 260;
  static const double _ideBodyMinWidth = 360;

  @override
  Widget build(BuildContext context) {
    // v1.5 layout: the editor is `_buildIdeBody` (tab bar + editor
    // pane(s)) PLUS — when SSH / Teams / Watch are live — a
    // resizable side stack to its right. Terminal still spans the
    // full workbench width below (it's a sibling Area in the outer
    // vertical split owned by `_LayoutForMode`, not nested
    // here).
    //
    // History: v1.0–v1.3 had a similar setup but the right slot
    // was a single Area that could only host one of SSH or Teams
    // at a time. v1.4 lifted SSH/Teams/Watch out into a separate
    // full-height column at the root, which gave them coexistence
    // but detached the column from the workbench visually. v1.5
    // brings them back into the editor area as a real
    // vertical-stack side pane (`SidePanesColumn`), so the
    // workbench reads as a single unit again while preserving
    // multi-pane coexistence. Terminal keeps full-workbench width
    // because the side-stack lives only in the top half of the
    // workbench's vertical split.
    final ssh = context.watch<SshController>();
    final media = context.watch<MediaController>();
    final showSidePanes = SidePanesColumn.shouldMount(ssh: ssh, media: media);

    if (!showSidePanes) {
      return _buildIdeBody(context);
    }

    // multi_split_view 3.6.1 captured-closure landmine — same one
    // documented in v1.1's editor refactor and v1.4's
    // `SidePanesColumn`. The Area builders MUST be tear-offs of
    // instance methods (or const widget references), never inline
    // lambdas that close over per-build state, because
    // `initialAreas` is consumed once at mount and the captured
    // closure is the only one that ever fires for that area's
    // lifetime. The ValueKey on the MultiSplitView (constant for
    // the duration of "side panes are mounted") forces a fresh
    // mount when the side-pane visibility flag flips, sidestepping
    // the same trap from the other direction.
    return MultiSplitView(
      key: const ValueKey('editor-with-side-panes'),
      axis: Axis.horizontal,
      initialAreas: [
        Area(
          flex: 1,
          min: _ideBodyMinWidth,
          builder: _buildIdeBodyArea,
        ),
        Area(
          size: _sidePanesOptimalWidth,
          min: _sidePanesMinWidth,
          builder: _buildSidePanesArea,
        ),
      ],
    );
  }

  Widget _buildIdeBodyArea(BuildContext context, Area area) {
    return _buildIdeBody(context);
  }

  Widget _buildSidePanesArea(BuildContext context, Area area) {
    return const SidePanesColumn();
  }

  /// The "IDE body" — tab bar + active pane(s). Reads `AppState`
  /// fresh via `context.watch` so it stays reactive whether it's
  /// rendered directly or as the left half of the Teams/YouTube
  /// split.
  Widget _buildIdeBody(BuildContext context) {
    final appState = context.watch<AppState>();
    _syncPaneAssignments(appState);

    final focusedPath = _focusedPath;
    final isMarkdown = _isMarkdownFile(appState, focusedPath);
    final showingPreview =
        focusedPath != null && _markdownPreviewing.contains(focusedPath);

    final emptyEditor =
        appState.openFiles.isEmpty || appState.activeFile == null;

    if (emptyEditor) {
      return Container(
        // Even with no file open, paint the editor area at
        // `editorBg` (== Cursor's `editor.background`) so it
        // reads as a different surface from the sidebars.
        // Cursor's `editorGroup.emptyBackground` is actually
        // sidebar-color (`#191c22`) — matching that exactly
        // made the empty state visually merge with the file
        // explorer / chat panel, which the user (rightly)
        // flagged as confusing on the side-by-side
        // comparison. We diverge here on purpose.
        color: DuckColors.editorBg,
        // Keyed off `duckMischiefReplayTick` so the dev-only
        // `Replay duck mischief` palette command (which bumps the
        // tick) forces a fresh mount and re-runs the gag from the
        // top — without the key, the controller is already at 1.0
        // and `initState` doesn't re-fire on a notify.
        child: _DuckMischief(
          key: ValueKey(appState.duckMischiefReplayTick),
        ),
      );
    }

    return Column(
      children: [
        _EditorTabBar(
          appState: appState,
          onActivate: (file) => _activateFile(appState, file),
          onClose: (file) => _closeFile(appState, file),
          onCloseOthers: (file) => _closeOthers(appState, file),
          onCloseToRight: (file) => _closeFilesAfter(appState, file),
          onCloseAll: () => _closeAll(appState),
          onSplitLeft: (file) => _splitToPane(appState, file, 0),
          onSplitRight: (file) => _splitToPane(appState, file, 1),
          splitView: _splitView,
          onToggleSplitView: () => _toggleSplitView(appState),
          showingMarkdownPreview: showingPreview,
          isMarkdownFile: isMarkdown,
          onFind: () => appState.ideActions.find(),
          onToggleMarkdownPreview: () {
            if (focusedPath == null) return;
            setState(() {
              if (showingPreview) {
                _markdownPreviewing.remove(focusedPath);
              } else {
                _markdownPreviewing.add(focusedPath);
              }
            });
          },
        ),
        Expanded(
          child: _splitView
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
                      // Tear-offs again — same captured-closure
                      // hazard as the outer Teams split.
                      Area(flex: 0.5, builder: _buildPaneArea0),
                      Area(flex: 0.5, builder: _buildPaneArea1),
                    ],
                  ),
                )
              : _buildPane(appState, 0, _primaryPath),
        ),
      ],
    );
  }

  Widget _buildPaneArea0(BuildContext context, Area area) {
    final appState = context.watch<AppState>();
    return _buildPane(appState, 0, _primaryPath);
  }

  Widget _buildPaneArea1(BuildContext context, Area area) {
    final appState = context.watch<AppState>();
    return _buildPane(appState, 1, _secondaryPath);
  }

  // ── Tab context menu actions ──────────────────────────────────────────

  Future<void> _closeOthers(AppState appState, File anchor) async {
    final keep = anchor.path;
    final toClose = appState.openFiles
        .where((f) => f.path != keep)
        .toList(growable: false);
    await _closeBatch(appState, toClose);
  }

  Future<void> _closeFilesAfter(AppState appState, File anchor) async {
    final files = appState.openFiles;
    final idx = files.indexWhere((f) => f.path == anchor.path);
    if (idx < 0) return;
    final toClose = files.sublist(idx + 1).toList(growable: false);
    await _closeBatch(appState, toClose);
  }

  Future<void> _closeAll(AppState appState) async {
    final files = appState.openFiles.toList(growable: false);
    await _closeBatch(appState, files);
  }

  /// Shared batch-close path used by Close Others / Close to Right /
  /// Close All. Three-stage flow:
  ///
  ///   1. Partition the batch into clean and dirty.
  ///   2. If any are dirty, ask once with the batch dialog
  ///      (`Save All` / `Don't Save` / `Cancel`).
  ///   3. Close everything in `toClose` (clean files first, then the
  ///      dirty ones honouring the user's choice).
  ///
  /// "Save All" writes named dirty buffers via `saveFileByPath`; any
  /// dirty UNTITLED tabs in the batch are left open afterwards (we
  /// don't want a sequential save-as picker firing N times for a
  /// "Close All" of 6 untitled scratch buffers). The user is told
  /// via toast what happened. Use Save As manually first if you
  /// want untitled tabs persisted.
  ///
  /// Cancel aborts the entire batch — clean files in the batch are
  /// also kept open. This is intentional: the user clicked Cancel,
  /// they want everything as-is.
  Future<void> _closeBatch(AppState appState, List<File> toClose) async {
    if (toClose.isEmpty) return;
    final dirty = toClose
        .where((f) => appState.isFileDirty(f.path))
        .toList(growable: false);
    final clean = toClose
        .where((f) => !appState.isFileDirty(f.path))
        .toList(growable: false);

    var keepUntitled = <File>[];

    if (dirty.isNotEmpty) {
      final choice = await showBatchUnsavedChangesDialog(
        context,
        dirtyFiles: dirty,
      );
      if (!mounted) return;
      switch (choice) {
        case BatchUnsavedChangesChoice.cancel:
          return;
        case BatchUnsavedChangesChoice.saveAll:
          for (final f in dirty) {
            if (AppState.isUntitledTab(f.path)) {
              // Skip — sequential save-as pickers would be hostile
              // UX. Track separately so the toast is accurate even
              // when an untitled save-as somewhere in the batch
              // succeeded via a different path.
              keepUntitled.add(f);
              continue;
            }
            await appState.saveFileByPath(f.path);
          }
          if (!mounted) return;
        case BatchUnsavedChangesChoice.discardAll:
          break;
      }
    }

    setState(() {
      for (final f in toClose) {
        if (keepUntitled.any((u) => u.path == f.path)) continue;
        if (_primaryPath == f.path) _primaryPath = null;
        if (_secondaryPath == f.path) _secondaryPath = null;
      }
    });

    final closeOrder = [
      ...clean,
      ...dirty.where((d) => !keepUntitled.any((u) => u.path == d.path)),
    ];
    for (final f in closeOrder) {
      appState.closeFile(f);
    }
    if (keepUntitled.isNotEmpty && mounted) {
      showDuckToast(
        context,
        S.unsavedBatchUntitledSkipped(keepUntitled.length),
      );
    }
  }

  /// Move `file` into pane index `target` (0 = left/primary,
  /// 1 = right/secondary). If we're not yet in split view, enable it
  /// first. Used by the tab right-click `Split Left` / `Split Right`
  /// actions.
  void _splitToPane(AppState appState, File file, int target) {
    setState(() {
      _splitView = true;
      _focusedPane = target;
      if (target == 0) {
        _primaryPath = file.path;
      } else {
        _secondaryPath = file.path;
      }
    });
    appState.setActiveFile(file);
  }
}

/// A single code editor pane (one tab's worth of `re_editor`).
///
/// `_EditorState` owns one or two of these depending on
/// `_splitView`: pane 0 is always the primary, pane 1 only exists
/// when the user has split. The pane handles its own
/// `CodeLineEditingController` lifecycle — including registering
/// with the IDE action bridge while focused so menu-bar
/// undo/redo/find/copy/paste hit the right buffer.
class _EditorPane extends StatefulWidget {
  final AppState appState;
  final String path;
  final bool focused;
  final bool showingPreview;
  final VoidCallback onFocus;

  const _EditorPane({
    super.key,
    required this.appState,
    required this.path,
    required this.focused,
    required this.showingPreview,
    required this.onFocus,
  });

  @override
  State<_EditorPane> createState() => _EditorPaneState();
}

class _EditorPaneState extends State<_EditorPane> {
  CodeLineEditingController? _controller;
  CodeFindController? _findController;
  // Owned by us so the `IndentGuidesOverlay` can listen to scroll
  // offsets — `re_editor` will create one internally if you don't
  // pass one, but then there's no public handle for the overlay to
  // sync against.
  late final CodeScrollController _scrollController;
  String? _path;
  String? _languageId;
  bool _pushingText = false;

  @override
  void initState() {
    super.initState();
    _scrollController = CodeScrollController();
    _findController = CodeFindController(CodeLineEditingController());
    _ensureController();
  }

  @override
  void didUpdateWidget(covariant _EditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    _ensureController();
    if (widget.focused && !oldWidget.focused && _controller != null) {
      _registerEditorActions();
    } else if (!widget.focused && oldWidget.focused && _controller != null) {
      widget.appState.ideActions.unregisterEditor(_controller!);
    }
  }

  @override
  void dispose() {
    final controller = _controller;
    if (controller != null) {
      try {
        widget.appState.ideActions.unregisterEditor(controller);
      } catch (_) {}
      controller.dispose();
    }
    _findController?.removeListener(_onFindControllerChange);
    _findController?.dispose();
    // `CodeScrollController` doesn't have a `.dispose()` — it just
    // composes two `ScrollController`s that we have to dispose
    // individually.
    _scrollController.verticalScroller.dispose();
    _scrollController.horizontalScroller.dispose();
    super.dispose();
  }

  /// Approximate the width of `re_editor`'s indicator gutter (line
  // Note: gutter-width measurement used to live here as
  // `_approximateGutterWidth()`. It now lives inside
  // `IndentGuidesOverlay` itself so that the value re-measures the
  // moment `controller.codeLines` length crosses a digit boundary
  // (9 → 10, 99 → 100, …) — the parent doesn't listen to the editing
  // controller, so a value owned by the parent went stale across
  // those boundaries. See `indent_guides.dart::_gutterOffset`.
  static const double _codeFieldPadding = 5;
  static const double _findBarHeight = 70;
  static const double _replaceBarHeight = 104;

  double get _effectiveCodeFieldTopPadding {
    final find = _findController?.value;
    if (find == null) return _codeFieldPadding;
    return _codeFieldPadding +
        (find.replaceMode ? _replaceBarHeight : _findBarHeight);
  }

  void _onFindControllerChange() {
    if (!mounted) return;
    setState(() {});
  }

  void _ensureController() {
    final content = widget.appState.fileContentFor(widget.path);
    final override = widget.appState.languageOverrideFor(widget.path);
    final detected = LanguageDetector.detect(widget.path, content);
    final langId = override ?? detected.id;

    if (_path != widget.path || _languageId != langId || _controller == null) {
      final old = _controller;
      if (old != null) {
        widget.appState.ideActions.unregisterEditor(old);
        old.removeListener(_pushControllerTextToState);
        old.dispose();
      }
      _controller = CodeLineEditingController.fromText(content);
      _controller!.addListener(_pushControllerTextToState);

      // Re-create find controller with the new editing controller.
      _findController?.removeListener(_onFindControllerChange);
      _findController?.dispose();
      _findController = CodeFindController(_controller!);
      _findController!.addListener(_onFindControllerChange);

      if (widget.focused) {
        _registerEditorActions();
      }
      _path = widget.path;
      _languageId = langId;
    } else if (!_pushingText && _controller!.text != content) {
      _controller!.text = content;
    }
  }

  void _pushControllerTextToState() {
    final controller = _controller;
    if (controller == null || _pushingText) return;
    if (controller.text != widget.appState.fileContentFor(widget.path)) {
      _pushingText = true;
      widget.appState.updateFileContentFor(widget.path, controller.text);
      _pushingText = false;
      // The inner block ONLY fires for user-driven edits — programmatic
      // writes from `_ensureController` set `controller.text == state
      // .content` first, so the != check above short-circuits and we
      // never reach this point. So this is the right hook to "the user
      // typed something in this file" → drop recent-agent-edit
      // highlights for it (line numbers have shifted; cached set is
      // stale; the user has clearly taken ownership of this file). See
      // `services/recent_edits_tracker.dart` for the full contract.
      widget.appState.recentEdits.invalidate(widget.path);
    }
  }

  /// Register all editor actions (undo/redo/find/findReplace/cut/copy/paste/selectAll)
  /// with the IDE action bridge so the menu bar can dispatch to the active editor.
  void _registerEditorActions() {
    final c = _controller;
    if (c == null) return;
    widget.appState.ideActions.registerEditor(
      c,
      onFind: () => _findController?.findMode(),
      onFindReplace: () => _findController?.replaceMode(),
      onCut: () => c.cut(),
      onCopy: () => c.copy(),
      // re_editor's paste() reads the system clipboard internally
      // (`Clipboard.getData` → `replaceSelection`); no manual arg.
      onPaste: () => c.paste(),
      onSelectAll: () => c.selectAll(),
    );
  }

  CodeHighlightTheme? _buildHighlightTheme() {
    final override = widget.appState.languageOverrideFor(widget.path);
    final detected = LanguageDetector.detect(
      widget.path,
      widget.appState.fileContentFor(widget.path),
    );
    final langId = override ?? detected.id;
    final mode = LanguageDetector.modeForId(langId) ?? detected.mode;

    if (mode == null) return null;

    final themeMap = EditorThemes.resolve(widget.appState.editorTheme);

    return CodeHighlightTheme(
      languages: {langId: CodeHighlightThemeMode(mode: mode)},
      theme: themeMap,
    );
  }

  CodeAutocompletePromptsBuilder _buildAutocompletePrompts() {
    final override = widget.appState.languageOverrideFor(widget.path);
    final detected = LanguageDetector.detect(
      widget.path,
      widget.appState.fileContentFor(widget.path),
    );
    final langId = override ?? detected.id;
    return DefaultCodeAutocompletePromptsBuilder(
      language: LanguageDetector.modeForId(langId) ?? detected.mode,
    );
  }

  @override
  Widget build(BuildContext context) {
    _ensureController();
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => widget.onFocus(),
      child: widget.showingPreview
          ? MarkdownPreview(text: widget.appState.fileContentFor(widget.path))
          : CodeAutocomplete(
              viewBuilder: (context, notifier, onSelected) {
                return EditorAutocompleteList(
                  notifier: notifier,
                  onSelected: onSelected,
                );
              },
              promptsBuilder: _buildAutocompletePrompts(),
              child: Container(
                color: DuckColors.editorBg,
                child: Stack(
                  children: [
                    CodeEditor(
                      controller: _controller!,
                      scrollController: _scrollController,
                      findController: _findController,
                      // `re_editor` registers Ctrl+S internally as
                      // `CodeShortcutSaveIntent`, but the package's
                      // built-in action table has no handler for that
                      // intent. Result: while the editor has focus,
                      // Ctrl+S is consumed before Lumen's app-level
                      // Shortcuts can see it, and nothing saves. Route
                      // the editor-local intent back through the same
                      // central menu dispatcher used by File > Save so
                      // untitled tabs still get the Save-As prompt and
                      // normal files go through AppState.saveFile().
                      shortcutOverrideActions: {
                        CodeShortcutSaveIntent:
                            CallbackAction<CodeShortcutSaveIntent>(
                              onInvoke: (_) {
                                unawaited(handleMenuAction(context, 'save'));
                                return null;
                              },
                            ),
                      },
                      findBuilder: (context, controller, readOnly) =>
                          _EditorFindBar(
                            controller: controller,
                            editingController: _controller!,
                          ),
                      wordWrap: widget.appState.wordWrap,
                      style: CodeEditorStyle(
                        fontSize: widget.appState.editorFontSize,
                        fontFamily: DuckTheme.monoFont,
                        fontHeight: 1.45,
                        backgroundColor: DuckColors.editorBg,
                        textColor: DuckColors.fgPrimary,
                        codeTheme: _buildHighlightTheme(),
                        cursorColor: DuckColors.accentCyan,
                        selectionColor: DuckColors.editorSelection,
                      ),
                      indicatorBuilder:
                          (
                            context,
                            editingController,
                            chunkController,
                            notifier,
                          ) {
                            return Row(
                              children: [
                                DefaultCodeLineNumber(
                                  controller: editingController,
                                  notifier: notifier,
                                  textStyle: TextStyle(
                                    fontFamily: DuckTheme.monoFont,
                                    fontSize:
                                        widget.appState.editorFontSize - 1,
                                    color: DuckColors.fgFaint,
                                  ),
                                  focusedTextStyle: TextStyle(
                                    fontFamily: DuckTheme.monoFont,
                                    fontSize:
                                        widget.appState.editorFontSize - 1,
                                    color: DuckColors.fgMuted,
                                  ),
                                ),
                                DefaultCodeChunkIndicator(
                                  width: 20,
                                  controller: chunkController,
                                  notifier: notifier,
                                ),
                              ],
                            );
                          },
                      sperator: Container(
                        width: 1,
                        color: DuckColors.glassSeam,
                      ),
                    ),
                    // Recent-edits highlight overlay — full-width line
                    // tints behind code that the most recent agent turn
                    // touched. Painted UNDER the indent guides so the
                    // guides remain crisp at all times. Self-renders
                    // nothing when the file isn't tracked.
                    Positioned.fill(
                      child: RecentEditsOverlay(
                        tracker: widget.appState.recentEdits,
                        scrollController: _scrollController,
                        absolutePath: widget.path,
                        fontSize: widget.appState.editorFontSize,
                        fontHeight: 1.45,
                        fontFamily: DuckTheme.monoFont,
                        topPadding: _effectiveCodeFieldTopPadding,
                        // Cyan @ 8% alpha — visible on the dark editor
                        // bg without competing with syntax colours. If
                        // the user complains it's hard to see, the
                        // alpha is the knob (don't change the hue —
                        // cyan is Lumen's "agent" accent everywhere
                        // else, e.g. tool cards in chat).
                        color: DuckColors.accentCyan.withValues(alpha: 0.08),
                      ),
                    ),
                    // Indent-guide overlay — paints vertical lines at
                    // each indent step, scroll-synced via the shared
                    // `_scrollController`. `IgnorePointer` inside the
                    // overlay so taps fall through to the editor.
                    Positioned.fill(
                      child: IndentGuidesOverlay(
                        controller: _controller!,
                        scrollController: _scrollController,
                        fontSize: widget.appState.editorFontSize,
                        fontHeight: 1.45,
                        fontFamily: DuckTheme.monoFont,
                        indentSize: _controller!.options.indentSize,
                        codeFieldPadding: _codeFieldPadding,
                        topPadding: _effectiveCodeFieldTopPadding,
                        color: DuckColors.editorIndentGuide,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _EditorFindBar extends StatelessWidget implements PreferredSizeWidget {
  final CodeFindController controller;
  final CodeLineEditingController editingController;

  const _EditorFindBar({
    required this.controller,
    required this.editingController,
  });

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size.fromHeight(value.replaceMode ? 104 : 70);
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();

    final result = value.result;
    final total = result?.matches.length ?? 0;
    final index = total == 0 || result == null ? 0 : result.index + 1;
    final countLabel = value.option.pattern.isEmpty
        ? ''
        : total == 0
        ? S.editorFindNoResults
        : '$index/$total';

    return CodeEditorTapRegion(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.only(top: 8, right: 18),
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: 460,
              padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
              decoration: BoxDecoration(
                color: DuckColors.bgRaised,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(color: DuckColors.borderStrong, width: 0.5),
                boxShadow: DuckTheme.shadowSoft,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _FindInput(
                          controller: controller.findInputController,
                          focusNode: controller.findInputFocusNode,
                          hint: S.editorFindPlaceholder,
                          onSubmitted: (_) => controller.nextMatch(),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 54,
                        child: Text(
                          countLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontSize: 11,
                            color: total == 0 && value.option.pattern.isNotEmpty
                                ? DuckColors.stateError
                                : DuckColors.fgMuted,
                          ),
                        ),
                      ),
                      _FindIconButton(
                        icon: Icons.keyboard_arrow_up,
                        tooltip: S.editorFindPrevious,
                        onTap: controller.previousMatch,
                      ),
                      _FindIconButton(
                        icon: Icons.keyboard_arrow_down,
                        tooltip: S.editorFindNext,
                        onTap: controller.nextMatch,
                      ),
                      _FindToggleButton(
                        label: 'Aa',
                        tooltip: S.editorFindCaseSensitive,
                        active: value.option.caseSensitive,
                        onTap: controller.toggleCaseSensitive,
                      ),
                      _FindToggleButton(
                        label: '.*',
                        tooltip: S.editorFindRegex,
                        active: value.option.regex,
                        onTap: controller.toggleRegex,
                      ),
                      _FindIconButton(
                        icon: Icons.close,
                        tooltip: S.editorFindClose,
                        onTap: controller.close,
                      ),
                    ],
                  ),
                  const SizedBox(height: 5),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: _ReplaceDisclosure(
                      expanded: value.replaceMode,
                      onTap: controller.toggleMode,
                    ),
                  ),
                  if (value.replaceMode) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: _FindInput(
                            controller: controller.replaceInputController,
                            focusNode: controller.replaceInputFocusNode,
                            hint: S.editorReplacePlaceholder,
                            onSubmitted: (_) => _replaceMatch(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: _replaceMatch,
                          child: const Text(S.editorReplace),
                        ),
                        TextButton(
                          onPressed: _replaceAllMatches,
                          child: const Text(S.editorReplaceAll),
                        ),
                      ],
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

  void _replaceMatch() {
    final value = controller.value;
    final result = value?.result;
    if (value == null || result == null || result.dirty) return;

    final selection = controller.currentMatchSelection;
    final option = value.option;
    final regExp = option.regExp;
    if (selection == null || regExp == null) return;

    var replacement = controller.replaceInputController.text;
    if (option.regex) {
      final selectedText = _selectedText(selection);
      final match = regExp.firstMatch(selectedText);
      if (match == null ||
          match.start != 0 ||
          match.end != selectedText.length) {
        return;
      }
      replacement = _expandReplacement(replacement, match);
    }

    editingController.replaceSelection(replacement, selection);
  }

  void _replaceAllMatches() {
    final value = controller.value;
    final result = value?.result;
    if (value == null ||
        result == null ||
        result.matches.isEmpty ||
        result.dirty) {
      return;
    }

    final regExp = value.option.regExp;
    if (regExp == null) return;

    final replacement = controller.replaceInputController.text;
    final nextText = editingController.text.replaceAllMapped(
      regExp,
      (match) => value.option.regex
          ? _expandReplacement(replacement, match)
          : replacement,
    );
    if (nextText == editingController.text) return;
    editingController.text = nextText;
  }

  String _selectedText(CodeLineSelection selection) {
    final lines = editingController.codeLines;
    final lineBreak = editingController.options.lineBreak.value;
    if (selection.isSameLine) {
      return lines[selection.startIndex].substring(
        selection.startOffset,
        selection.endOffset,
      );
    }

    final buffer = StringBuffer();
    for (var i = selection.startIndex; i <= selection.endIndex; i++) {
      final line = lines[i];
      if (i == selection.startIndex) {
        buffer.write(line.substring(selection.startOffset));
      } else if (i == selection.endIndex) {
        buffer.write(line.substring(0, selection.endOffset));
      } else {
        buffer.write(line.text);
      }
      if (i < selection.endIndex) buffer.write(lineBreak);
    }
    return buffer.toString();
  }

  String _expandReplacement(String replacement, Match match) {
    return replacement.replaceAllMapped(
      RegExp(r'\\([\\$])|\$(\d+)|\$\{(\d+)\}'),
      (token) {
        final escaped = token.group(1);
        if (escaped != null) return escaped;
        final indexText = token.group(2) ?? token.group(3);
        if (indexText == null) return token.group(0)!;
        final index = int.tryParse(indexText);
        if (index == null || index > match.groupCount) return '';
        return match.group(index) ?? '';
      },
    );
  }
}

class _FindInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final ValueChanged<String> onSubmitted;

  const _FindInput({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 26,
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        onSubmitted: onSubmitted,
        style: const TextStyle(fontSize: 12, color: DuckColors.fgPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 7,
          ),
          filled: true,
          fillColor: DuckColors.bgDeeper,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            borderSide: const BorderSide(color: DuckColors.glassSeam),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            borderSide: const BorderSide(color: DuckColors.glassSeam),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            borderSide: const BorderSide(color: DuckColors.accentCyan),
          ),
        ),
      ),
    );
  }
}

class _ReplaceDisclosure extends StatelessWidget {
  final bool expanded;
  final VoidCallback onTap;

  const _ReplaceDisclosure({required this.expanded, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.editorFindToggleReplace,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            decoration: BoxDecoration(
              color: expanded
                  ? DuckColors.accentCyan.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(
                color: expanded
                    ? DuckColors.accentCyan.withValues(alpha: 0.35)
                    : DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  expanded ? Icons.keyboard_arrow_down : Icons.chevron_right,
                  size: 15,
                  color: expanded ? DuckColors.accentCyan : DuckColors.fgMuted,
                ),
                const SizedBox(width: 4),
                Text(
                  S.editorReplace,
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: expanded
                        ? DuckColors.accentCyan
                        : DuckColors.fgMuted,
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

class _FindIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _FindIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: DuckColors.fgMuted),
          ),
        ),
      ),
    );
  }
}

class _FindToggleButton extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool active;
  final VoidCallback onTap;

  const _FindToggleButton({
    required this.label,
    required this.tooltip,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
            decoration: BoxDecoration(
              color: active
                  ? DuckColors.accentCyan.withValues(alpha: 0.16)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: active ? DuckColors.accentCyan : DuckColors.fgMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyEditorPane extends StatelessWidget {
  final bool focused;
  final VoidCallback onTap;

  const _EmptyEditorPane({required this.focused, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: Colors.transparent,
      splashColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: Container(
        color: DuckColors.editorBg,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: focused
                  ? DuckColors.bgRaisedHi.withValues(alpha: 0.32)
                  : DuckColors.bgChip.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(
                color: focused ? DuckColors.accentCyan : DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            child: const Text(
              S.editorSelectFileForPane,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          ),
        ),
      ),
    );
  }
}

class _EditorTabBar extends StatelessWidget {
  final AppState appState;
  final ValueChanged<File> onActivate;
  final ValueChanged<File> onClose;
  final ValueChanged<File> onCloseOthers;
  final ValueChanged<File> onCloseToRight;
  final VoidCallback onCloseAll;
  final ValueChanged<File> onSplitLeft;
  final ValueChanged<File> onSplitRight;
  final bool splitView;
  final VoidCallback onToggleSplitView;
  final bool showingMarkdownPreview;
  final bool isMarkdownFile;
  final VoidCallback onToggleMarkdownPreview;
  final VoidCallback onFind;

  const _EditorTabBar({
    required this.appState,
    required this.onActivate,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseToRight,
    required this.onCloseAll,
    required this.onSplitLeft,
    required this.onSplitRight,
    required this.splitView,
    required this.onToggleSplitView,
    required this.showingMarkdownPreview,
    required this.isMarkdownFile,
    required this.onToggleMarkdownPreview,
    required this.onFind,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: SizedBox(
        height: DuckTheme.tabHeight + 4,
        child: Row(
          children: [
            // ── Scrollable tabs ──
            Expanded(
              child: ReorderableListView.builder(
                scrollDirection: Axis.horizontal,
                buildDefaultDragHandles: false,
                itemCount: appState.openFiles.length,
                onReorder: (oldIndex, newIndex) =>
                    appState.reorderOpenFile(oldIndex, newIndex),
                proxyDecorator: (child, index, anim) => Material(
                  color: Colors.transparent,
                  elevation: 0,
                  child: child,
                ),
                itemBuilder: (context, index) {
                  final file = appState.openFiles[index];
                  final isSettings = AppState.isSettingsTab(file.path);
                  final isProcessMgr = AppState.isProcessManagerTab(file.path);
                  final isUntitled = AppState.isUntitledTab(file.path);
                  // Remote-mirror tabs render as `<basename>  <host>:<path>`
                  // so the user sees what they're editing AND where it
                  // came from. The local mirror path under
                  // `<appSupport>/lumen/ssh-mirror/...` is meaningless
                  // to humans — surfacing the remote address instead
                  // makes the tab self-documenting.
                  final remoteOrigin =
                      appState.ssh?.remoteFiles.originFor(file.path);
                  final fileName = isSettings
                      ? S.settingsTitle
                      : isProcessMgr
                      ? S.processManagerTitle
                      : isUntitled
                      ? 'Untitled-${file.path.replaceAll(AppState.untitledPrefix, '')}'
                      : remoteOrigin != null
                      ? '${remoteOrigin.remotePath.split('/').last}  ·  ${remoteOrigin.hostLabel}'
                      : file.path.split(Platform.pathSeparator).last;
                  final isActive = appState.activeFile?.path == file.path;
                  final isDirty = appState.isFileDirty(file.path);
                  return ReorderableDragStartListener(
                    key: ValueKey(file.path),
                    index: index,
                    child: _EditorTab(
                      fileName: fileName,
                      isActive: isActive,
                      isDirty: isDirty,
                      // `isSettings` is currently the "virtual tab,
                      // suppress the file-icon" flag — both the
                      // Settings and Process Manager sentinels qualify.
                      // Renaming would touch every call site; the
                      // boolean intent is identical.
                      isSettings: isSettings || isProcessMgr,
                      onActivate: () => onActivate(file),
                      onClose: () => onClose(file),
                      onCloseOthers: () => onCloseOthers(file),
                      onCloseToRight: () => onCloseToRight(file),
                      onCloseAll: onCloseAll,
                      onSplitLeft: () => onSplitLeft(file),
                      onSplitRight: () => onSplitRight(file),
                      // Disable "Close to the right" when this is the
                      // last tab so the menu doesn't show enabled
                      // options that do nothing.
                      hasTabsAfter: index < appState.openFiles.length - 1,
                      hasOtherTabs: appState.openFiles.length > 1,
                    ),
                  );
                },
              ),
            ),
            // ── Right-side action buttons (moved from toolbar) ──
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ToolbarButton(
                    icon: Icons.search,
                    tooltip: S.editorFindInFile,
                    onTap: onFind,
                  ),
                  const SizedBox(width: 4),
                  _ToolbarButton(
                    icon: splitView
                        ? Icons.fullscreen_exit
                        : Icons.view_column_outlined,
                    tooltip: splitView
                        ? S.editorUnsplitView
                        : S.editorSplitView,
                    onTap: onToggleSplitView,
                  ),
                  if (isMarkdownFile) ...[
                    const SizedBox(width: 4),
                    _ToolbarButton(
                      icon: showingMarkdownPreview
                          ? Icons.edit_note
                          : Icons.article_outlined,
                      tooltip: showingMarkdownPreview
                          ? S.editorEditMode
                          : S.editorMarkdownPreview,
                      onTap: onToggleMarkdownPreview,
                    ),
                  ],
                  const SizedBox(width: 4),
                  _ToolbarOverflow(appState: appState),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single editor tab.
///
/// Mouse interactions:
/// - Left-click activates the tab.
/// - Middle-click closes the tab — VS Code default.
/// - Right-click opens the context menu (close, close others,
///   close to the right, close all, split left, split right) via
///   `showFastMenu`.
///
/// Active tabs paint `editorBg` so they read as joined to the editor
/// canvas; inactive ones stay transparent so the panel's glass tint
/// shows.
class _EditorTab extends StatefulWidget {
  final String fileName;
  final bool isActive;
  final bool isDirty;
  final bool isSettings;
  final VoidCallback onActivate;
  final VoidCallback onClose;
  final VoidCallback onCloseOthers;
  final VoidCallback onCloseToRight;
  final VoidCallback onCloseAll;
  final VoidCallback onSplitLeft;
  final VoidCallback onSplitRight;
  // True when there are more tabs after this one in the open-files
  // list — drives the "Close to the Right" enabled state.
  final bool hasTabsAfter;
  // True when more than one tab is open — drives "Close Others".
  final bool hasOtherTabs;

  const _EditorTab({
    required this.fileName,
    required this.isActive,
    required this.isDirty,
    this.isSettings = false,
    required this.onActivate,
    required this.onClose,
    required this.onCloseOthers,
    required this.onCloseToRight,
    required this.onCloseAll,
    required this.onSplitLeft,
    required this.onSplitRight,
    required this.hasTabsAfter,
    required this.hasOtherTabs,
  });

  @override
  State<_EditorTab> createState() => _EditorTabState();
}

class _EditorTabState extends State<_EditorTab> {
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
        const PopupMenuDivider(height: 6),
        const PopupMenuItem<String>(
          value: 'splitLeft',
          child: Text(S.tabSplitLeft, style: TextStyle(fontSize: 12)),
        ),
        const PopupMenuItem<String>(
          value: 'splitRight',
          child: Text(S.tabSplitRight, style: TextStyle(fontSize: 12)),
        ),
      ],
    );
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
      case 'splitLeft':
        widget.onSplitLeft();
        break;
      case 'splitRight':
        widget.onSplitRight();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tabColor = widget.isActive ? DuckColors.editorBg : Colors.transparent;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
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
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(color: tabColor),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!widget.isSettings) ...[
                    Icon(
                      Icons.description,
                      size: 13,
                      color: widget.isActive
                          ? DuckColors.fileIcon
                          : DuckColors.fgFaint,
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    widget.fileName,
                    style: TextStyle(
                      color: widget.isActive
                          ? DuckColors.fgPrimary
                          : DuckColors.fgMuted,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (widget.isDirty) ...[
                    Container(
                      width: 7,
                      height: 7,
                      decoration: const BoxDecoration(
                        color: DuckColors.accentDuck,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  InkWell(
                    onTap: widget.onClose,
                    hoverColor: Colors.transparent,
                    splashColor: Colors.transparent,
                    highlightColor: Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(
                        Icons.close,
                        size: 12,
                        color: DuckColors.fgSubtle,
                      ),
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

// _EditorToolbar removed — buttons moved into _EditorTabBar's right side.

class _ToolbarButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _ToolbarButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          onTap: onTap,
          hoverColor: Colors.transparent,
          splashColor: Colors.transparent,
          highlightColor: Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Icon(icon, size: 14, color: DuckColors.fgMuted),
          ),
        ),
      ),
    );
  }
}

class _ToolbarOverflow extends StatelessWidget {
  final AppState appState;
  const _ToolbarOverflow({required this.appState});

  @override
  Widget build(BuildContext context) {
    final GlobalKey key = GlobalKey();
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        key: key,
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        onTap: () async {
          final box = key.currentContext?.findRenderObject() as RenderBox?;
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
              pos.dx - 120,
              pos.dy,
              overlay.size.width - pos.dx,
              0,
            ),
            items: [
              PopupMenuItem(
                value: 'find',
                child: Row(
                  children: const [
                    Icon(Icons.search, size: 14, color: DuckColors.fgMuted),
                    SizedBox(width: 8),
                    Text(S.editorFindInFile, style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'wrap',
                child: Row(
                  children: [
                    Icon(
                      appState.wordWrap ? Icons.wrap_text : Icons.notes,
                      size: 14,
                      color: DuckColors.fgMuted,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${S.editorWordWrap}: ${appState.wordWrap ? S.on : S.off}',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'save',
                child: Row(
                  children: const [
                    Icon(Icons.save, size: 14, color: DuckColors.fgMuted),
                    SizedBox(width: 8),
                    Text(S.save, style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),
            ],
          );
          if (!context.mounted || picked == null) return;
          switch (picked) {
            case 'find':
              appState.ideActions.find();
              break;
            case 'wrap':
              appState.updateEditorSettings(wordWrap: !appState.wordWrap);
              break;
            case 'save':
              appState.saveFile();
              break;
          }
        },
        child: const Padding(
          padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Icon(Icons.more_horiz, size: 16, color: DuckColors.fgMuted),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Empty-editor mischief: an always-shown anatidaephobia flavor line + a
// one-shot Haviduck cameo, gated PER PROJECT.
//
// **First visit to a workspace** (`AppState.duckMischiefPlayedForCurrentProject`
// is false): the stage starts EMPTY (no button), a smaller duck waddles in
// along the bottom edge of the stage, pauses at the center, JUMPS straight
// up — at the apex of the jump the Create New File button materializes
// directly above him, as if hurled into place — lands, pivots, declares
// "I AM THE REBELLION" in a comic speech bubble, then waddles back out
// the left edge. The button he just threw stays put forever after — the
// duck literally placed the empty state's only interactive affordance.
// On gag completion `markDuckMischiefPlayedForCurrentProject` is called,
// flipping the per-workspace pref so every subsequent visit to this
// project skips straight to the static layout.
//
// **Subsequent visits** (pref is true): no animation, no stage. We render
// the quip and the Create New File button stacked tightly, with a small
// gap. Same compact button as the animated path, just sitting there.
//
// The flag is per-workspace (hashed via PreferencesService._wsKey) — open
// project A, see the gag once, then open project B and see it again
// because B has its own pref slot. Closing/reopening A skips it.
//
// The Haviduck.gif is right-facing natively, so:
//   - walk-in (left → center): no flip
//   - walk-out (center → off-screen left): horizontally flipped so the duck
//     still faces its direction of travel.
//
// The `_shoutMs` phase between the flip and the walk-out is intentional —
// the duck stops in place while the speech bubble fades in so the rebellion
// line registers BEFORE the duck starts moving again.
// ---------------------------------------------------------------------------

class _DuckMischief extends StatefulWidget {
  const _DuckMischief({super.key});

  @override
  State<_DuckMischief> createState() => _DuckMischiefState();
}

class _DuckMischiefState extends State<_DuckMischief>
    with SingleTickerProviderStateMixin {
  // Phase durations (ms). Sum = totalMs. Tweak any of these in isolation;
  // the timing helper below uses cumulative boundaries derived from these.
  static const int _initialMs = 2500; // calm: just flavor line, empty stage
  static const int _walkInMs = 4500; // duck enters from left along the floor
  static const int _jumpMs = 760; // vertical jump, button materializes at apex
  static const int _settleMs = 500; // beat after the duck lands
  static const int _flipMs = 220; // duck pivots to face left
  static const int _shoutMs = 1000; // duck stationary, bubble fades in
  static const int _walkOutMs = 4000; // duck waddles out (slow waddle)

  static const int _totalMs = _initialMs +
      _walkInMs +
      _jumpMs +
      _settleMs +
      _flipMs +
      _shoutMs +
      _walkOutMs;

  late final AnimationController _ctrl;
  // Decided once on mount from `AppState.duckMischiefPlayedForCurrentProject`.
  // Null only during the initial frame between `initState` and the first
  // build, which never actually paints because we set it synchronously
  // below.
  bool _shouldAnimate = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: _totalMs),
    );
    // Sync read in initState — `Provider.of(listen: false)` (== context.read)
    // is documented as safe here because `_DuckMischief` is always mounted
    // below the AppState provider in the tree.
    final state = context.read<AppState>();
    _shouldAnimate = !state.duckMischiefPlayedForCurrentProject;
    if (_shouldAnimate) {
      _ctrl
        ..addStatusListener(_onStatus)
        ..forward();
    }
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      // Mark played AFTER the gag finishes so a user who closes/reopens
      // the project mid-animation still gets to see it next time.
      // Fire-and-forget — the pref write is one shared-prefs setter,
      // failures are non-recoverable and not user-visible.
      // ignore: discarded_futures
      context.read<AppState>().markDuckMischiefPlayedForCurrentProject();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onNewFile() {
    context.read<AppState>().openUntitledTab();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Always-shown flavor line — the literal definition of what
            // the duck gag below performs (when it performs at all).
            const Text(
              S.editorEmptyAnatidaephobia,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DuckColors.fgFaint,
                fontSize: 13,
                height: 1.4,
                fontStyle: FontStyle.italic,
              ),
            ),
            // Tighter gap between quip and button than the original
            // 28px — both the animated stage (where the button settles
            // mid-stage) and the static layout (where the button sits
            // immediately under the quip) read as one cohesive unit
            // rather than a quip floating disconnected at the top.
            const SizedBox(height: 14),
            if (_shouldAnimate)
              _DuckStage(ctrl: _ctrl, onNewFile: _onNewFile)
            else
              SizedBox(
                width: _DuckStage.buttonW,
                height: _DuckStage.buttonH,
                child: _EmptyStateActionButton(
                  icon: Icons.note_add_outlined,
                  label: S.editorEmptyCreateNewFile,
                  accent: DuckColors.accentDuck,
                  onTap: _onNewFile,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Horizontal "stage" that hosts the eventual centered Create New File
/// button (above) and the animated duck overlay (walking along the floor
/// of the stage). Sized in pixels — large enough to give the duck room
/// to enter / exit and to clear vertical space for the jump apex without
/// overflowing into the file explorer or chat sidebars.
class _DuckStage extends StatelessWidget {
  const _DuckStage({
    required this.ctrl,
    required this.onNewFile,
  });

  final AnimationController ctrl;
  final VoidCallback onNewFile;

  // Public so the static (skip-mode) layout in `_DuckMischiefState.build`
  // can mount a button with the exact same footprint as the animated one.
  static const double buttonW = 200.0;
  static const double buttonH = 46.0;

  // Smaller duck sprite than the v1 gag (was 88) — the new walk-on-the-
  // floor framing benefits from a less imposing mascot, and the button
  // ends up at the duck's eye level rather than the duck eclipsing it.
  static const double _duckSize = 56.0;
  // Button row sits in the upper portion of the stage, bubble nestles
  // between button and duck head, duck walks across the bottom.
  static const double _stageH = 150.0;
  // Vertical sin-arc apex of the jump — how high (in px) the duck rises
  // above its resting baseline at jumpProgress == 0.5. Tall enough that
  // the duck reaches the bottom edge of the (centered) button row.
  // Public so `_MischiefTiming.jumpDy` can read it without a back-channel.
  static const double jumpApexPx = 38.0;
  // Pixels of clearance between the duck's feet and the bottom of the
  // stage — keeps the sprite from kissing the editor background's
  // bottom edge.
  static const double _floorPad = 4.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: _stageH,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stageW = constraints.maxWidth;
          // Single button is centered, so the duck stops at the stage
          // center too. Subtract half the sprite width so the duck's
          // body is centered under the button.
          final stopLeft = (stageW - _duckSize) / 2;
          // Duck baseline (top of sprite when standing on the floor).
          // The jump motion subtracts an extra `jumpDy` from this.
          final duckBaselineTop = _stageH - _duckSize - _floorPad;

          return AnimatedBuilder(
            animation: ctrl,
            builder: (context, _) {
              final t = (ctrl.value * _DuckMischiefState._totalMs).round();
              final timing = _MischiefTiming.at(t);
              final duckLeft = timing.duckLeft(
                stageW: stageW,
                duckSize: _duckSize,
                stopLeft: stopLeft,
              );
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  // Create New File button — invisible until the duck
                  // jumps and "throws" it into place at the jump apex.
                  // Anchored to the upper portion of the stage (the duck
                  // walks along the floor below it).
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 4,
                    height: buttonH,
                    child: Center(
                      child: SizedBox(
                        width: buttonW,
                        height: buttonH,
                        child: Transform.scale(
                          scale: timing.buttonScale,
                          child: Opacity(
                            opacity: timing.buttonOpacity,
                            child: IgnorePointer(
                              // Until the throw actually lands, the
                              // button isn't real — don't accept clicks
                              // on the invisible/animating ghost.
                              ignoring: timing.buttonOpacity < 0.5,
                              child: _EmptyStateActionButton(
                                icon: Icons.note_add_outlined,
                                label: S.editorEmptyCreateNewFile,
                                accent: DuckColors.accentDuck,
                                onTap: onNewFile,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),

                  // Duck — walks along the floor, jumps straight up at
                  // center to throw the button into place, lands, exits.
                  Positioned(
                    left: duckLeft,
                    // Subtract jumpDy so larger values raise the duck.
                    top: duckBaselineTop - timing.jumpDy,
                    width: _duckSize,
                    height: _duckSize,
                    child: Opacity(
                      opacity: timing.duckOpacity,
                      // Sprite is right-facing natively — flip on the
                      // X axis when walking back to the left.
                      child: Transform.flip(
                        flipX: timing.duckFacingLeft,
                        child: Image.asset(
                          'assets/Haviduck.gif',
                          fit: BoxFit.contain,
                          gaplessPlayback: true,
                          filterQuality: FilterQuality.none,
                        ),
                      ),
                    ),
                  ),

                  // Speech bubble — only during the shout + walk-out,
                  // anchored above the duck and following its X. Sits
                  // in the gap between the (already-placed) button and
                  // the duck's head, tail pointing down to the duck.
                  if (timing.bubbleOpacity > 0.01)
                    Positioned(
                      left: duckLeft +
                          _duckSize / 2 -
                          _SpeechBubble.estimatedHalfWidth,
                      top: duckBaselineTop - 48,
                      child: Opacity(
                        opacity: timing.bubbleOpacity,
                        child: const _SpeechBubble(
                          text: S.editorEmptyDuckRebellion,
                        ),
                      ),
                    ),
                ],
              );
            },
          );
        },
      ),
    );
  }

}

/// Pure timing helper. Given the elapsed time (ms since the controller
/// started), it returns every animatable value the stage needs: duck X /
/// facing direction / opacity, button materialization (scale / fade),
/// duck jump dy, and speech-bubble fade.
///
/// All easing lives in this class so the build method stays declarative.
class _MischiefTiming {
  _MischiefTiming({
    required this.duckPhase,
    required this.duckProgress,
    required this.duckFacingLeft,
    required this.duckOpacity,
    required this.jumpProgress,
    required this.bubbleOpacity,
  });

  // Cumulative phase boundaries, derived from `_DuckMischiefState`.
  // _b1: end of initial calm (empty stage).
  // _b2: end of walk-in.
  // _b3: end of jump (button is fully materialized at apex, duck is
  //      back on the floor).
  // _b4: end of post-landing settle (still facing right).
  // _b5: end of pivot/flip (now facing left).
  // _b6: end of stationary shout (bubble fully visible).
  // _b7: end of walk-out (= total).
  static const int _b1 = _DuckMischiefState._initialMs;
  static const int _b2 = _b1 + _DuckMischiefState._walkInMs;
  static const int _b3 = _b2 + _DuckMischiefState._jumpMs;
  static const int _b4 = _b3 + _DuckMischiefState._settleMs;
  static const int _b5 = _b4 + _DuckMischiefState._flipMs;
  static const int _b6 = _b5 + _DuckMischiefState._shoutMs;
  static const int _b7 = _b6 + _DuckMischiefState._walkOutMs;

  final _DuckPhase duckPhase;
  // Progress within the current duck phase (0..1).
  final double duckProgress;
  final bool duckFacingLeft;
  final double duckOpacity;
  // Jump progress (0..1). 0 before jump, 1 after the duck lands. The
  // button materializes around p=0.45 (apex of the jump).
  final double jumpProgress;
  final double bubbleOpacity;

  factory _MischiefTiming.at(int t) {
    final _DuckPhase phase;
    final double progress;
    final bool facingLeft;
    if (t < _b1) {
      phase = _DuckPhase.idle;
      progress = 0;
      facingLeft = false;
    } else if (t < _b2) {
      phase = _DuckPhase.walkingIn;
      progress = ((t - _b1) / _DuckMischiefState._walkInMs).clamp(0.0, 1.0);
      facingLeft = false;
    } else if (t < _b4) {
      // Stationary at center across jump + settle (still facing right).
      // The jump's vertical motion is applied separately via `jumpDy`
      // so the duck appears to leap and land without changing phase.
      phase = _DuckPhase.atButton;
      progress = 0;
      facingLeft = false;
    } else if (t < _b6) {
      // Pivot + stationary shout — duck holds position facing left so
      // the speech bubble has time to register before the walk-out.
      phase = _DuckPhase.atButton;
      progress = 0;
      facingLeft = true;
    } else if (t < _b7) {
      phase = _DuckPhase.walkingOut;
      progress = ((t - _b6) / _DuckMischiefState._walkOutMs).clamp(0.0, 1.0);
      facingLeft = true;
    } else {
      phase = _DuckPhase.gone;
      progress = 1;
      facingLeft = true;
    }

    // Jump progress: 0 before jump, 0..1 across jump window, 1 after.
    final double jumpP;
    if (t < _b2) {
      jumpP = 0;
    } else if (t < _b3) {
      jumpP = ((t - _b2) / _DuckMischiefState._jumpMs).clamp(0.0, 1.0);
    } else {
      jumpP = 1;
    }

    // Speech bubble: fades in across the front ~45% of the stationary
    // shout phase, holds full through the rest of the shout AND the
    // entire walk-out, then fades out only as the duck nears the off-
    // screen left edge. The duck and the bubble exit together so the
    // "I AM THE REBELLION" line lands while the duck is still visible.
    final double bubble;
    if (t < _b5) {
      bubble = 0;
    } else if (t < _b6) {
      final p = (t - _b5) / _DuckMischiefState._shoutMs;
      bubble = (p / 0.45).clamp(0.0, 1.0);
    } else if (t < _b7) {
      final p = (t - _b6) / _DuckMischiefState._walkOutMs;
      if (p < 0.8) {
        bubble = 1;
      } else {
        bubble = (1.0 - (p - 0.8) / 0.2).clamp(0.0, 1.0);
      }
    } else {
      bubble = 0;
    }

    return _MischiefTiming(
      duckPhase: phase,
      duckProgress: progress,
      duckFacingLeft: facingLeft,
      duckOpacity: phase == _DuckPhase.idle || phase == _DuckPhase.gone
          ? 0.0
          : 1.0,
      jumpProgress: jumpP,
      bubbleOpacity: bubble,
    );
  }

  /// Computed duck X (top-left of the sprite) within the stage.
  double duckLeft({
    required double stageW,
    required double duckSize,
    required double stopLeft,
  }) {
    final offstageLeft = -duckSize - 24;
    switch (duckPhase) {
      case _DuckPhase.idle:
      case _DuckPhase.gone:
        return offstageLeft;
      case _DuckPhase.walkingIn:
        return _lerp(offstageLeft, stopLeft, _easeOut(duckProgress));
      case _DuckPhase.atButton:
        return stopLeft;
      case _DuckPhase.walkingOut:
        return _lerp(stopLeft, offstageLeft, _easeIn(duckProgress));
    }
  }

  /// Vertical jump motion. Sin-arc peaks at p=0.5 (~+38px ABOVE the
  /// resting baseline) and returns to 0 at p=1 — duck leaps straight
  /// up to "throw" the button into place, then lands. Caller subtracts
  /// this from the duck's resting `top` (positive jumpDy = higher on
  /// screen). Zero outside the jump window.
  double get jumpDy {
    if (jumpProgress <= 0 || jumpProgress >= 1) return 0;
    return _DuckStage.jumpApexPx * sin(pi * jumpProgress);
  }

  /// Button opacity. Hidden until the jump nears its apex (p≈0.45),
  /// then fades up to 1.0 over the remainder of the jump window. After
  /// the duck lands the button stays fully visible — the duck literally
  /// threw it into place, so it doesn't disappear when the duck leaves.
  double get buttonOpacity {
    if (jumpProgress < 0.45) return 0;
    if (jumpProgress < 1) {
      return ((jumpProgress - 0.45) / 0.55).clamp(0.0, 1.0);
    }
    return 1;
  }

  /// Button scale. Pops in oversized at the jump apex, settles to 1.0
  /// by the end of the jump window. Ease-out so the bounce feels like
  /// it's losing energy rather than ramping linearly.
  double get buttonScale {
    if (jumpProgress < 0.45) return 1.4;
    if (jumpProgress < 1) {
      final p = (jumpProgress - 0.45) / 0.55;
      return _lerp(1.4, 1.0, _easeOut(p));
    }
    return 1;
  }
}

enum _DuckPhase { idle, walkingIn, atButton, walkingOut, gone }

double _lerp(double a, double b, double t) => a + (b - a) * t;
double _easeOut(double t) => 1 - (1 - t) * (1 - t);
double _easeIn(double t) => t * t;

/// Compact comic speech bubble with a tail pointing down toward the
/// duck. Renders the rebellion line in a heavier, slightly tilted
/// font so it reads as a shout. Uses chip-surface colors so it sits
/// on top of the editor background without screaming.
class _SpeechBubble extends StatelessWidget {
  const _SpeechBubble({required this.text});

  final String text;

  // Rough width estimate used by the stage to horizontally center the
  // bubble over the duck. Doesn't need to be exact — speech bubbles
  // look fine slightly off-axis.
  static const double estimatedHalfWidth = 86.0;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: const _SpeechBubblePainter(),
      child: Container(
        constraints: const BoxConstraints(minWidth: 140, maxWidth: 220),
        padding: const EdgeInsets.fromLTRB(14, 9, 14, 13),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6,
            height: 1.15,
          ),
        ),
      ),
    );
  }
}

class _SpeechBubblePainter extends CustomPainter {
  const _SpeechBubblePainter();

  @override
  void paint(Canvas canvas, Size size) {
    const radius = 12.0;
    const tailH = 8.0;
    final body = Rect.fromLTWH(0, 0, size.width, size.height - tailH);
    final rrect = RRect.fromRectAndRadius(body, const Radius.circular(radius));

    final fill = Paint()
      ..color = DuckColors.bgRaisedHi
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = DuckColors.borderStrong
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawRRect(rrect, fill);

    // Triangle tail centered on the bubble, pointing down toward the
    // duck below. Drawn before the stroke so the tail shares the body
    // outline cleanly.
    final tailMidX = size.width / 2;
    final tail = Path()
      ..moveTo(tailMidX - 9, body.bottom - 0.5)
      ..lineTo(tailMidX, size.height)
      ..lineTo(tailMidX + 9, body.bottom - 0.5)
      ..close();
    canvas.drawPath(tail, fill);

    // Outline: bubble + tail as one continuous contour, with the small
    // segment of the bubble bottom UNDER the tail not stroked so the
    // tail appears to "merge" into the bubble.
    final outline = Path()
      // top-left arc start
      ..moveTo(0, radius)
      ..arcToPoint(const Offset(radius, 0), radius: const Radius.circular(radius))
      ..lineTo(size.width - radius, 0)
      ..arcToPoint(
        Offset(size.width, radius),
        radius: const Radius.circular(radius),
      )
      ..lineTo(size.width, body.bottom - radius)
      ..arcToPoint(
        Offset(size.width - radius, body.bottom),
        radius: const Radius.circular(radius),
      )
      // right side of tail base
      ..lineTo(tailMidX + 9, body.bottom)
      // tail point
      ..lineTo(tailMidX, size.height)
      // back up to left side of tail base
      ..lineTo(tailMidX - 9, body.bottom)
      ..lineTo(radius, body.bottom)
      ..arcToPoint(
        Offset(0, body.bottom - radius),
        radius: const Radius.circular(radius),
      )
      ..close();
    canvas.drawPath(outline, stroke);
  }

  @override
  bool shouldRepaint(covariant _SpeechBubblePainter oldDelegate) => false;
}

/// Compact action button used in the empty editor state. Mirrors the
/// welcome screen's `_Action` styling but renders inside a fixed-size
/// slot so the stage layout (and the duck's stop position) can be
/// computed deterministically.
class _EmptyStateActionButton extends StatefulWidget {
  const _EmptyStateActionButton({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_EmptyStateActionButton> createState() =>
      _EmptyStateActionButtonState();
}

class _EmptyStateActionButtonState extends State<_EmptyStateActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hover ? DuckColors.bgRaisedHi : DuckColors.bgChip;
    final border = _hover
        ? widget.accent.withValues(alpha: 0.6)
        : DuckColors.borderStrong;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.instant,
        curve: DuckMotion.standard,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 1),
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(widget.icon, color: widget.accent, size: 17),
                  const SizedBox(width: 9),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: DuckColors.fgPrimary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
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
