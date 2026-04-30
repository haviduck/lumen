import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

/// Central registry for "global" IDE actions that aren't owned by a single
/// widget — undo/redo/find belong to the editor, new/kill terminal belong
/// to the terminal pane, and the command palette / quick open / global
/// search belong to overlay widgets that may not exist on every layout.
///
/// Widgets that own one of these capabilities register a callback when
/// they mount and clear it when they unmount. The menu bar, keyboard
/// shortcut handlers, and the command palette all dispatch through this
/// bridge so they have a single place to look up "the active editor's
/// undo" or "the terminal pane's new-tab handler".
///
/// This is a lightweight `ChangeNotifier` so the menu bar can rebuild and
/// disable items when their handler isn't currently registered (e.g. there
/// is no editor open).
class IdeActions extends ChangeNotifier {
  // ---- editor ----
  CodeLineEditingController? _editor;
  CodeLineEditingController? get activeEditor => _editor;
  bool get hasEditor => _editor != null;

  /// Optional callbacks for undo/redo/find/findReplace/cut/copy/paste/selectAll
  /// that the editor pane registers.
  VoidCallback? _undo;
  VoidCallback? _redo;
  VoidCallback? _find;
  VoidCallback? _findReplace;
  VoidCallback? _cut;
  VoidCallback? _copy;
  VoidCallback? _paste;
  VoidCallback? _selectAll;

  void registerEditor(
    CodeLineEditingController controller, {
    VoidCallback? onUndo,
    VoidCallback? onRedo,
    VoidCallback? onFind,
    VoidCallback? onFindReplace,
    VoidCallback? onCut,
    VoidCallback? onCopy,
    VoidCallback? onPaste,
    VoidCallback? onSelectAll,
  }) {
    _editor = controller;
    _undo = onUndo;
    _redo = onRedo;
    _find = onFind;
    _findReplace = onFindReplace;
    _cut = onCut;
    _copy = onCopy;
    _paste = onPaste;
    _selectAll = onSelectAll;
    notifyListeners();
  }

  void unregisterEditor(CodeLineEditingController controller) {
    if (identical(_editor, controller)) {
      _editor = null;
      _undo = null;
      _redo = null;
      _find = null;
      _findReplace = null;
      _cut = null;
      _copy = null;
      _paste = null;
      _selectAll = null;
      notifyListeners();
    }
  }

  void undo() => _undo?.call();
  void redo() => _redo?.call();
  void find() => _find?.call();
  void findReplace() => _findReplace?.call();
  void cut() => _cut?.call();
  void copy() => _copy?.call();
  void paste() => _paste?.call();
  void selectAll() => _selectAll?.call();

  // ---- terminal ----
  VoidCallback? _newTerminal;
  VoidCallback? _killActiveTerminal;
  bool get hasTerminal => _newTerminal != null;

  void registerTerminalActions({
    required VoidCallback onNewTerminal,
    required VoidCallback onKillActive,
  }) {
    _newTerminal = onNewTerminal;
    _killActiveTerminal = onKillActive;
    notifyListeners();
  }

  void unregisterTerminalActions() {
    _newTerminal = null;
    _killActiveTerminal = null;
    notifyListeners();
  }

  void newTerminal() => _newTerminal?.call();
  void killActiveTerminal() => _killActiveTerminal?.call();

  // ---- overlay panels (command palette / quick open / global search) ----
  // Registered by the overlay host widget that lives once at the IDE shell
  // level. Set to null when no workspace is open.
  VoidCallback? _openCommandPalette;
  VoidCallback? _openQuickOpen;
  VoidCallback? _openGlobalSearch;

  bool get hasOverlays => _openCommandPalette != null;

  void registerOverlayActions({
    required VoidCallback openCommandPalette,
    required VoidCallback openQuickOpen,
    required VoidCallback openGlobalSearch,
  }) {
    _openCommandPalette = openCommandPalette;
    _openQuickOpen = openQuickOpen;
    _openGlobalSearch = openGlobalSearch;
    notifyListeners();
  }

  void unregisterOverlayActions() {
    _openCommandPalette = null;
    _openQuickOpen = null;
    _openGlobalSearch = null;
    notifyListeners();
  }

  void openCommandPalette() => _openCommandPalette?.call();
  void openQuickOpen() => _openQuickOpen?.call();
  void openGlobalSearch() => _openGlobalSearch?.call();

  // ---- file explorer ----
  // Registered by `FileExplorer` while it's mounted. Lets the menu
  // bar's "jump to explorer" icon scroll the tree to top and flash
  // its border without owning a reference to the widget — same
  // pattern used for the editor / terminal / overlay actions above.
  VoidCallback? _focusFileExplorer;
  bool get hasFileExplorer => _focusFileExplorer != null;

  void registerFileExplorerActions({required VoidCallback onFocus}) {
    _focusFileExplorer = onFocus;
    notifyListeners();
  }

  void unregisterFileExplorerActions() {
    _focusFileExplorer = null;
    notifyListeners();
  }

  void focusFileExplorer() => _focusFileExplorer?.call();
}
