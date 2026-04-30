import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';
import 'package:multi_split_view/multi_split_view.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/media_controller.dart';
import '../../services/file_kind.dart';
import '../../services/language_detector.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';
import '../common/media_pane_chrome.dart';
import '../menu_bar.dart';
import '../settings_view.dart';
import 'autocomplete_overlay.dart';
import 'binary_preview.dart';
import 'editor_themes.dart';
import 'indent_guides.dart';
import 'markdown_preview.dart';
import 'recent_edits_overlay.dart';

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

  void _closeFile(AppState appState, File file) {
    setState(() {
      if (_primaryPath == file.path) _primaryPath = null;
      if (_secondaryPath == file.path) _secondaryPath = null;
    });
    appState.closeFile(file);
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

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, appState, child) {
        _syncPaneAssignments(appState);

        final focusedPath = _focusedPath;
        final isMarkdown = _isMarkdownFile(appState, focusedPath);
        final showingPreview =
            focusedPath != null && _markdownPreviewing.contains(focusedPath);

        final emptyEditor =
            appState.openFiles.isEmpty || appState.activeFile == null;

        Widget editorBody = emptyEditor
            ? Container(
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
                child: const Center(child: _DuckQuip()),
              )
            : Column(
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
                                highlightedColor: DuckColors.accentCyan
                                    .withValues(alpha: 0.4),
                              ),
                            ),
                            child: MultiSplitView(
                              axis: Axis.horizontal,
                              initialAreas: [
                                Area(
                                  flex: 0.5,
                                  builder: (context, area) =>
                                      _buildPane(appState, 0, _primaryPath),
                                ),
                                Area(
                                  flex: 0.5,
                                  builder: (context, area) =>
                                      _buildPane(appState, 1, _secondaryPath),
                                ),
                              ],
                            ),
                          )
                        : _buildPane(appState, 0, _primaryPath),
                  ),
                ],
              );

        // Teams owns the editor-side media slot when active, while normal
        // watch-media can still render in chat. If Teams is not active, the
        // user may opt normal media into the editor split as before.
        return Consumer<MediaController>(
          builder: (context, media, _) {
            final editorSlot = media.hasTeams
                ? MediaSlot.teams
                : MediaSlot.watch;
            final showMediaInEditor =
                media.hasTeams ||
                (media.hasMedia && media.placement == MediaPlacement.editor);
            if (!showMediaInEditor) return editorBody;
            return MultiSplitViewTheme(
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
                  Area(flex: 0.6, builder: (_, _) => editorBody),
                  Area(
                    flex: 0.4,
                    builder: (_, _) =>
                        _EditorMediaPane(media: media, slot: editorSlot),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  // ── Tab context menu actions ──────────────────────────────────────────

  void _closeOthers(AppState appState, File anchor) {
    final keep = anchor.path;
    final toClose = appState.openFiles
        .where((f) => f.path != keep)
        .toList(growable: false);
    for (final f in toClose) {
      _closeFile(appState, f);
    }
  }

  void _closeFilesAfter(AppState appState, File anchor) {
    final files = appState.openFiles;
    final idx = files.indexWhere((f) => f.path == anchor.path);
    if (idx < 0) return;
    final toClose = files.sublist(idx + 1).toList(growable: false);
    for (final f in toClose) {
      _closeFile(appState, f);
    }
  }

  void _closeAll(AppState appState) {
    final files = appState.openFiles.toList(growable: false);
    for (final f in files) {
      _closeFile(appState, f);
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

/// Editor-placement media pane — header chrome + the shared
/// `MediaController.webview`. Lives inside a `MultiSplitView` next
/// to the editor body, so its width is whatever the user dragged
/// the divider to.
///
/// **Layout rules:**
/// - For aspect-locked media (YouTube / Twitch) the webview is wrapped
///   in `AspectRatio(16/9)` inside `Center`. The pane fills with black
///   (`bgDeepest`) and the player letterboxes when the pane's aspect
///   doesn't match 16:9. Without this, YouTube's player tries to
///   fill an arbitrary-shaped pane and the actual video becomes
///   tiny / cropped depending on the user's split ratio.
/// - For arbitrary URLs (news, streams, anything embeddable) the
///   webview just fills the pane — those pages flow freely and
///   benefit from the full real estate. Use the chrome's zoom +/-
///   to fit the page contents to the pane size.
class _EditorMediaPane extends StatelessWidget {
  final MediaController media;
  final MediaSlot slot;
  const _EditorMediaPane({required this.media, required this.slot});

  @override
  Widget build(BuildContext context) {
    final body = media.isAspectLockedFor(slot)
        ? Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: Webview(media.webviewFor(slot)),
            ),
          )
        : Webview(media.webviewFor(slot));
    return Container(
      color: DuckColors.bgDeepest,
      child: Column(
        children: [
          MediaPaneChrome(media: media, slot: slot),
          Expanded(child: body),
        ],
      ),
    );
  }
}

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
  static const double _findBarHeight = 42;
  static const double _replaceBarHeight = 76;

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
                          _EditorFindBar(controller: controller),
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

  const _EditorFindBar({required this.controller});

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size.fromHeight(value.replaceMode ? 76 : 42);
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
              width: 360,
              padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
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
                  if (value.replaceMode) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Expanded(
                          child: _FindInput(
                            controller: controller.replaceInputController,
                            focusNode: controller.replaceInputFocusNode,
                            hint: S.editorReplacePlaceholder,
                            onSubmitted: (_) => controller.replaceMatch(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: controller.replaceMatch,
                          child: const Text(S.editorReplace),
                        ),
                        TextButton(
                          onPressed: controller.replaceAllMatches,
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
                  final isUntitled = AppState.isUntitledTab(file.path);
                  final fileName = isSettings
                      ? S.settingsTitle
                      : isUntitled
                      ? 'Untitled-${file.path.replaceAll(AppState.untitledPrefix, '')}'
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
                      isSettings: isSettings,
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

class _DuckQuip extends StatelessWidget {
  const _DuckQuip();

  static final _rng = Random();
  static const _quips = [
    'A duck walked into a code review.\nNobody noticed until it shipped to prod.',
    'Your posture right now would make\na chiropractor weep with joy... at the billing opportunity.',
    'Fun fact: ducks have three eyelids.\nYou have zero excuses not to blink more.',
    'That keyboard cost less than lunch.\nYour wrists can tell.',
    'Somewhere, a fanny pack is waiting\nfor you to ironically bring it back.',
    'Ducks sleep with one eye open.\nYou should too, during deployments.',
    'Sit up straight.\nThis message will self-destruct... your back won\'t.',
    'A group of ducks is called a raft.\nA group of developers is called a standup... allegedly.',
    'Your mechanical keyboard doesn\'t\nmake you type better. It just makes everyone else type angrier.',
    'Fanny packs: because cargo shorts\nweren\'t embarrassing enough.',
    'Duck quacks don\'t echo.\nNeither does good code in a monolith.',
    'You\'ve been sitting for how long?\nEven the office chair is concerned.',
    'Pro tip: rubber duck debugging works\nbetter if you actually talk to it.',
    'Your \'ergonomic\' setup is just\na laptop on a stack of old textbooks.',
    'Ducks can fly at 50 mph.\nYour deploy pipeline wishes.',
    'That energy drink won\'t fix your\narchitecture decisions.',
    'Open a file already.\nThe duck is getting impatient.',
    'A fanny pack has more storage\nthan your free-tier database.',
    'Ducks have been around for 40 million years.\nYour node_modules folder just feels that old.',
    'Your neck is at a 45-degree angle.\nThat\'s not a feature, it\'s a bug.',
    'The \'D\' in IDE stands for duck.\nLook it up. Actually don\'t.',
    'Somewhere a senior dev is refactoring\ncode you wrote at 3am. They\'re not happy.',
    'Ducks molt all their flight feathers at once.\nKind of like your repo after a rebase gone wrong.',
    'Your keyboard has more crumbs\nthan a bakery floor.',
    'Fanny packs are just utility belts\nfor people who gave up.',
    'A mallard\'s quack can express\nmore emotion than your commit messages.',
    'Hydrate. Even ducks know this.\nThey literally live in water.',
    'Your monitor brightness is set to\n\'surface of the sun\'. Your retinas filed a complaint.',
    'Ducks have regional accents.\nYour code has regional disasters.',
    'That cheap keyboard will outlive\nyour motivation. Open a file. Do something.',
  ];

  @override
  Widget build(BuildContext context) {
    final quip = _quips[_rng.nextInt(_quips.length)];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48),
      child: Text(
        quip,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: DuckColors.fgFaint,
          fontSize: 13,
          height: 1.6,
          fontStyle: FontStyle.italic,
        ),
      ),
    );
  }
}
