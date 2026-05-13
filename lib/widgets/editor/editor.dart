import 'dart:async';
import 'dart:io';

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
import '../../services/line_break_style.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';
import '../menu_bar.dart';
import '../process_manager/process_manager_view.dart';
import '../settings_view.dart';
import '../side_panes_column.dart';
import '../common/duck_toast.dart';
import '../council/council_sessions_browser.dart';
import '../council/council_theater.dart';
import 'autocomplete_overlay.dart';
import 'binary_preview.dart';
import 'editor_themes.dart';
import 'indent_guides.dart';
import 'knowledge_base_view.dart';
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
    // Knowledge Base sentinel — markdown editor + preview + summarize
    // header for the workspace `.agents/knowledgebase.md`. Same
    // virtual-tab pattern as settings/process-manager: routed BEFORE
    // any real-file branch so the literal `__knowledge_base__` path
    // can never hit a code-editor mount.
    if (AppState.isKnowledgeBaseTab(path)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
        child: const KnowledgeBaseView(),
      );
    }
    // Council theater sentinel — full live council UI (orbital ring,
    // agent cards, blackboard, report viewer). Replaces the v1
    // workbench-level overlay that hijacked the entire (Editor +
    // Terminal) area. The orchestration runs in `CouncilController`
    // regardless of whether this tab is currently focused — switch
    // to a code tab and the council keeps running, switch back and
    // you see the live state. Auto-opened by `AppState` whenever
    // `council.theaterVisible` flips from false to true.
    if (AppState.isCouncilTheaterTab(path)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
        child: const CouncilTheater(),
      );
    }
    if (AppState.isCouncilSessionsTab(path)) {
      return GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTapDown: (_) {
          setState(() => _focusedPane = paneIndex);
          final file = appState.openFiles.firstWhere((f) => f.path == path);
          appState.setActiveFile(file);
        },
        child: const CouncilSessionsBrowser(),
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
        child: const _EmptyEditorState(),
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
  // The line-break style the active controller was constructed with.
  // Tracked so [_ensureController] knows when to recreate: a CRLF
  // file flipped to LF (e.g. after an agent tool wrote a normalized
  // result back) needs a fresh controller because `CodeLineOptions`
  // is `final` in `re_editor`. Without this matching, the controller
  // returns text via `lineBreak.value` joins (default LF) which can
  // never equal a CRLF source — and the listener at
  // [_pushControllerTextToState] would then mark the buffer dirty
  // every time the editor re-mounts. See `services/line_break_style.dart`
  // for the detection logic.
  LineBreakStyle? _lineBreak;
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
    // Detect from the actual file content (not the path / language)
    // so the controller's `text` getter joins lines with the SAME
    // separator the file uses. Without this, `re_editor`'s default
    // (`TextLineBreak.lf`) makes every CRLF file appear "dirty" the
    // moment any controller mutation fires the listener — see the
    // doc on [_lineBreak] above.
    final detectedLineBreak = detectLineBreakStyle(content);

    final mustRecreate =
        _path != widget.path ||
        _languageId != langId ||
        _lineBreak != detectedLineBreak ||
        _controller == null;
    if (mustRecreate) {
      final old = _controller;
      if (old != null) {
        widget.appState.ideActions.unregisterEditor(old);
        old.removeListener(_pushControllerTextToState);
        old.dispose();
      }
      _controller = CodeLineEditingController.fromText(
        content,
        CodeLineOptions(lineBreak: _toReEditorLineBreak(detectedLineBreak)),
      );
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
      _lineBreak = detectedLineBreak;
    } else if (!_pushingText && _controller!.text != content) {
      _controller!.text = content;
    }
  }

  /// Bridge to `re_editor`'s `TextLineBreak`. Lives here (and not
  /// inside [LineBreakStyle]) so the lower-level utility doesn't
  /// have to import the Flutter editor package.
  static TextLineBreak _toReEditorLineBreak(LineBreakStyle s) {
    switch (s) {
      case LineBreakStyle.crlf:
        return TextLineBreak.crlf;
      case LineBreakStyle.cr:
        return TextLineBreak.cr;
      case LineBreakStyle.lf:
        return TextLineBreak.lf;
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
    // The seam between tabs and content is painted by inactive tabs
    // themselves so the active tab can sit flush against the editor body
    // (no orphan strip under the active tab).
    return Container(
      decoration: const BoxDecoration(color: DuckColors.bgDeeper),
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
                  final isKb = AppState.isKnowledgeBaseTab(file.path);
                  final isCouncil = AppState.isCouncilTheaterTab(file.path);
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
                      : isCouncil
                      ? S.councilTitle
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
                      // `isSettings` is the "virtual tab, suppress the
                      // generic file-icon" flag for sentinel paths
                      // (settings, process manager, knowledge base,
                      // council theater). The label alone is enough
                      // to identify them, and they aren't real files
                      // so the document icon would lie.
                      isSettings: isSettings || isProcessMgr || isKb || isCouncil,
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
              decoration: BoxDecoration(
                color: tabColor,
                border: widget.isActive
                    ? null
                    : const Border(
                        bottom: BorderSide(
                          color: DuckColors.glassSeam,
                          width: 0.5,
                        ),
                      ),
              ),
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
// Empty-editor surface: a calm "no file open" pane with the always-shown
// `editorEmptyHeadline` line + a single Create New File button. No
// animation, no mascot, no per-workspace state — every visit to the empty
// editor surface looks the same. Previously this hosted a one-shot duck
// waddle / "rebellion" gag from the DuckOff era; removed when the product
// rebranded to Lumen and the gag stopped fitting the calmer visual tone.
// ---------------------------------------------------------------------------

class _EmptyEditorState extends StatelessWidget {
  const _EmptyEditorState();

  // Smaller footprint than the v1 button (was 200 x 46) — at the
  // ghost-button visual weight a slimmer slot reads as more
  // intentional and less "candy bar floating in void".
  static const double _buttonW = 180.0;
  static const double _buttonH = 36.0;

  void _onNewFile(BuildContext context) {
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
            const Text(
              S.editorEmptyHeadline,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: DuckColors.fgFaint,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: _buttonW,
              height: _buttonH,
              child: _EmptyStateActionButton(
                icon: Icons.note_add_outlined,
                label: S.editorEmptyCreateNewFile,
                onTap: () => _onNewFile(context),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ghost button used in the empty editor state. Transparent at rest
/// with a hairline seam border + muted foreground so it blends into
/// the editor background; hover lifts subtly to `bgRaisedHi` with a
/// brighter edge and primary foreground, keeping the affordance
/// discoverable without dominating the calm empty surface.
class _EmptyStateActionButton extends StatefulWidget {
  const _EmptyStateActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  State<_EmptyStateActionButton> createState() =>
      _EmptyStateActionButtonState();
}

class _EmptyStateActionButtonState extends State<_EmptyStateActionButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final bg = _hover ? DuckColors.bgRaisedHi : Colors.transparent;
    final border =
        _hover ? DuckColors.glassEdgeHi : DuckColors.glassSeam;
    final fg = _hover ? DuckColors.fgPrimary : DuckColors.fgMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        curve: DuckMotion.standard,
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(color: border, width: 0.5),
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
                  Icon(widget.icon, color: fg, size: 14),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      widget.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: fg,
                        fontSize: 12,
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
