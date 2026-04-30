import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/media_controller.dart';
import '../../services/gitnexus_service.dart';
import '../../services/gitignore_matcher.dart';
import '../../services/timeline_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/bright_icon_button.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';
import '../common/fast_popup_menu.dart';
import '../common/media_url_prompt.dart';
import '../menu_bar.dart';
import '../timeline/timeline_dialog.dart';
import '../timeline/timeline_rail.dart';
import 'file_icon_colors.dart';

class FileExplorer extends StatefulWidget {
  const FileExplorer({super.key});

  @override
  State<FileExplorer> createState() => _FileExplorerState();
}

enum _ExplorerClipboardMode { copy, cut }

class _ExplorerCopyIntent extends Intent {
  const _ExplorerCopyIntent();
}

class _ExplorerCutIntent extends Intent {
  const _ExplorerCutIntent();
}

class _ExplorerPasteIntent extends Intent {
  const _ExplorerPasteIntent();
}

class _ExplorerDeleteIntent extends Intent {
  const _ExplorerDeleteIntent();
}

class _ExplorerUndoIntent extends Intent {
  const _ExplorerUndoIntent();
}

class _ExplorerRedoIntent extends Intent {
  const _ExplorerRedoIntent();
}

enum _ExplorerOperationKind { create, copy, move }

class _ExplorerOperation {
  final _ExplorerOperationKind kind;
  final String from;
  final String to;
  final bool isDirectory;

  const _ExplorerOperation._({
    required this.kind,
    required this.from,
    required this.to,
    required this.isDirectory,
  });

  const _ExplorerOperation.create(String path, {required bool isDirectory})
    : this._(
        kind: _ExplorerOperationKind.create,
        from: '',
        to: path,
        isDirectory: isDirectory,
      );

  const _ExplorerOperation.copy(
    String source,
    String path, {
    required bool isDirectory,
  }) : this._(
         kind: _ExplorerOperationKind.copy,
         from: source,
         to: path,
         isDirectory: isDirectory,
       );

  const _ExplorerOperation.move(
    String from,
    String to, {
    required bool isDirectory,
  }) : this._(
         kind: _ExplorerOperationKind.move,
         from: from,
         to: to,
         isDirectory: isDirectory,
       );
}

class _ExplorerOperationException implements Exception {
  final String message;
  const _ExplorerOperationException(this.message);

  @override
  String toString() => message;
}

class _FileExplorerState extends State<FileExplorer> {
  bool _isDragging = false;
  bool _treeCollapsed = false;
  String? _selectedPath;
  String? _clipboardPath;
  _ExplorerClipboardMode? _clipboardMode;
  final List<_ExplorerOperation> _undoStack = <_ExplorerOperation>[];
  final List<_ExplorerOperation> _redoStack = <_ExplorerOperation>[];
  final FocusNode _focusNode = FocusNode(debugLabel: 'FileExplorer');
  GitIgnoreMatcher? _gitignoreMatcher;
  String? _gitignoreWorkspace;
  int? _gitignoreRefreshTick;

  // ── External drag-drop (from Windows Explorer / Finder / etc.) ──
  // Path of the folder currently under the OS-level drag cursor.
  // Null means the cursor is hovering somewhere on the panel that
  // isn't a registered folder row → drop falls through to the
  // workspace root, matching the prior behaviour.
  //
  // The cursor-tracking approach is deliberate: `desktop_drop` only
  // raises events on the outer `DropTarget` (per-row DropTargets
  // don't reliably bubble on Windows OLE drag), so we hit-test the
  // global cursor position against folder GlobalKeys we collect
  // from each `_FileTree` mount. The deepest matching folder wins
  // so dropping inside `src/components/` lands there, not in `src/`.
  String? _externalDropFolder;
  final Map<String, GlobalKey> _folderHitKeys = <String, GlobalKey>{};
  // Owned scroll controller so the menu bar's "jump to explorer"
  // action can call `animateTo(0)` without the explorer needing to
  // expose its inner widget tree. Same controller drives the existing
  // `SingleChildScrollView` below.
  final ScrollController _scrollController = ScrollController();
  // Pulses on for ~280ms when `IdeActions.focusFileExplorer` fires —
  // outer panel borders flip to `accentCyan`, decay back to default.
  // Visual confirmation that the click landed even when the tree was
  // already at the top (so the scroll animation is a no-op).
  bool _focusPulse = false;
  Timer? _focusPulseTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().ideActions.registerFileExplorerActions(
        onFocus: _onFocusRequested,
      );
    });
  }

  @override
  void dispose() {
    _focusPulseTimer?.cancel();
    _focusNode.dispose();
    _scrollController.dispose();
    // Best-effort unregister — if the widget tree is being torn down
    // we may not have a usable BuildContext, hence the try/catch.
    try {
      context.read<AppState>().ideActions.unregisterFileExplorerActions();
    } catch (_) {}
    super.dispose();
  }

  void _selectPath(String path) {
    if (_selectedPath == path) {
      if (!_focusNode.hasFocus) _focusNode.requestFocus();
      return;
    }
    setState(() => _selectedPath = path);
    _focusNode.requestFocus();
  }

  Future<void> _copySelected() async {
    final path = _selectedPath;
    if (path == null ||
        !FileSystemEntity.isFileSync(path) &&
            !FileSystemEntity.isDirectorySync(path)) {
      return;
    }
    setState(() {
      _clipboardPath = path;
      _clipboardMode = _ExplorerClipboardMode.copy;
    });
    final copiedToOs = await Pasteboard.writeFiles([path]);
    if (!mounted) return;
    _toast(
      context,
      copiedToOs
          ? S.explorerCopiedToClipboard
          : S.explorerCopyToClipboardFailed,
    );
  }

  void _cutSelected() {
    final path = _selectedPath;
    if (path == null ||
        !FileSystemEntity.isFileSync(path) &&
            !FileSystemEntity.isDirectorySync(path)) {
      return;
    }
    setState(() {
      _clipboardPath = path;
      _clipboardMode = _ExplorerClipboardMode.cut;
    });
    _toast(context, S.menuCut);
  }

  /// Decide which clipboard source to paste from. **OS clipboard
  /// wins when it has files** — the user's most recent action in
  /// any app should win. Falls through to the internal clipboard
  /// only when the OS clipboard has no files (so the in-app
  /// Cut/Paste workflow still works when the user hasn't Ctrl+C'd
  /// anywhere else).
  ///
  /// Reads the OS clipboard once here, then forwards the result to
  /// [_pasteOsClipboardInto] to avoid a second read.
  Future<void> _routePaste(Directory target) async {
    List<String> osFiles = const [];
    try {
      osFiles = await Pasteboard.files();
    } catch (e) {
      debugPrint('Pasteboard.files() failed: $e');
    }
    debugPrint(
      '[Lumen paste] os=${osFiles.length} internal=${_clipboardPath ?? "<none>"} target=${target.path}',
    );
    if (osFiles.isNotEmpty) {
      if (!mounted) return;
      await _pasteOsClipboardInto(target, preReadFiles: osFiles);
      return;
    }
    if (_clipboardPath != null) {
      await _pasteInto(target);
    }
  }

  /// Read file paths off the OS clipboard (CF_HDROP on Windows,
  /// NSPasteboardTypeFileURL on macOS, `text/uri-list` on Linux X11)
  /// and copy each one into [destination]. Used when the user has
  /// done Cut/Copy in an external file manager (Windows Explorer,
  /// Finder, Nautilus) and then Ctrl+V in Lumen.
  ///
  /// Always treats the operation as COPY — even if the source app
  /// flagged the clipboard as "cut" (`CFSTR_PREFERREDDROPEFFECT =
  /// DROPEFFECT_MOVE`). Reading and respecting that flag is doable
  /// but lossy across processes; "I lost a file" is a worse failure
  /// than "I have to delete the original myself", and the Cursor /
  /// VS Code precedent is also copy-only here.
  ///
  /// Empty clipboard / no files → silent no-op (no nag toast). The
  /// user is interacting with Ctrl+V freely and a "nothing to paste"
  /// toast every time they hit it for normal text-paste reasons in a
  /// non-explorer focus would be infuriating; we already gate on
  /// explorer-focus via the local `Shortcuts` block, but defensive.
  Future<void> _pasteOsClipboardInto(
    Directory destination, {
    List<String>? preReadFiles,
  }) async {
    List<String> files;
    if (preReadFiles != null) {
      files = preReadFiles;
    } else {
      try {
        files = await Pasteboard.files();
      } catch (e) {
        debugPrint('Pasteboard.files() failed: $e');
        return;
      }
      if (files.isEmpty) return;
      // `mounted` defense after the Pasteboard async — if the
      // explorer was unmounted while we awaited the OS clipboard
      // read (rare but possible: workspace switched mid-Ctrl+V),
      // bail rather than touching `context`.
      if (!mounted) return;
    }

    final appState = context.read<AppState>();
    final pasted = <String>[];
    for (final source in files) {
      if (!FileSystemEntity.isFileSync(source) &&
          !FileSystemEntity.isDirectorySync(source)) {
        continue;
      }
      try {
        // Refuse pasting a folder into itself or any descendant —
        // same guard as the in-app cut/copy path. Without this a
        // user copying their workspace root in Windows Explorer and
        // then Ctrl+V'ing into a subfolder would create an infinite
        // recursion.
        if (FileSystemEntity.isDirectorySync(source) &&
            (p.equals(source, destination.path) ||
                p.isWithin(source, destination.path))) {
          if (mounted) _toast(context, S.explorerCopyIntoSelf);
          continue;
        }
        final dest = _uniquePastePath(destination, source);
        if (FileSystemEntity.isDirectorySync(source)) {
          _copyDirectory(Directory(source), Directory(dest));
        } else {
          await File(source).copy(dest);
          await appState.timeline.recordWrite(
            dest,
            origin: TimelineOrigin.explorer,
            note: 'Pasted from OS clipboard',
          );
        }
        _recordExplorerOperation(
          _ExplorerOperation.copy(
            source,
            dest,
            isDirectory: FileSystemEntity.isDirectorySync(dest),
          ),
        );
        pasted.add(dest);
      } catch (e) {
        if (mounted) {
          _toast(context, '${S.explorerPasteFailed}: $e');
        }
      }
    }
    if (pasted.isEmpty) return;
    appState.refreshDirectory();
    setState(() => _selectedPath = pasted.last);
  }

  Future<void> _pasteInto(Directory destination) async {
    final source = _clipboardPath;
    final mode = _clipboardMode;
    if (source == null || mode == null) return;
    if (!FileSystemEntity.isFileSync(source) &&
        !FileSystemEntity.isDirectorySync(source)) {
      setState(() {
        _clipboardPath = null;
        _clipboardMode = null;
      });
      return;
    }

    try {
      final name = p.basename(source);
      if (mode == _ExplorerClipboardMode.cut) {
        final dest = p.join(destination.path, name);
        if (p.equals(source, dest)) return;
        if (FileSystemEntity.isDirectorySync(source) &&
            (p.equals(source, destination.path) ||
                p.isWithin(source, destination.path))) {
          _toast(context, S.explorerMoveIntoSelf);
          return;
        }
        if (FileSystemEntity.typeSync(dest) != FileSystemEntityType.notFound) {
          _toast(context, S.explorerMoveDestinationExists);
          return;
        }
        final appState = context.read<AppState>();
        if (FileSystemEntity.isDirectorySync(source)) {
          await Directory(source).rename(dest);
        } else {
          await appState.timeline.ensureBaseline(source);
          await File(source).rename(dest);
          await appState.timeline.recordRename(
            source,
            dest,
            origin: TimelineOrigin.explorer,
            note: 'Moved in file explorer',
          );
        }
        _recordExplorerOperation(
          _ExplorerOperation.move(
            source,
            dest,
            isDirectory: FileSystemEntity.isDirectorySync(dest),
          ),
        );
        appState.noteEntityMoved(source, dest);
        appState.refreshDirectory();
        setState(() {
          _selectedPath = dest;
          _clipboardPath = null;
          _clipboardMode = null;
        });
        return;
      }

      final dest = _uniquePastePath(destination, source);
      final appState = context.read<AppState>();
      if (FileSystemEntity.isDirectorySync(source)) {
        if (p.equals(source, destination.path) ||
            p.isWithin(source, destination.path)) {
          _toast(context, S.explorerCopyIntoSelf);
          return;
        }
        _copyDirectory(Directory(source), Directory(dest));
      } else {
        await File(source).copy(dest);
        await appState.timeline.recordWrite(
          dest,
          origin: TimelineOrigin.explorer,
          note: 'Copied in file explorer',
        );
      }
      _recordExplorerOperation(
        _ExplorerOperation.copy(
          source,
          dest,
          isDirectory: FileSystemEntity.isDirectorySync(dest),
        ),
      );
      appState.refreshDirectory();
      setState(() => _selectedPath = dest);
    } catch (e) {
      if (mounted) _toast(context, '${S.explorerPasteFailed}: $e');
    }
  }

  String _uniquePastePath(Directory destination, String sourcePath) {
    final basename = p.basename(sourcePath);
    final ext = p.extension(basename);
    final stem = ext.isEmpty ? basename : p.basenameWithoutExtension(basename);
    String candidateName(int i) {
      if (i == 0) return basename;
      final suffix = i == 1 ? ' - Copy' : ' - Copy $i';
      return ext.isEmpty ? '$stem$suffix' : '$stem$suffix$ext';
    }

    var i = 0;
    while (true) {
      final candidate = p.join(destination.path, candidateName(i));
      if (FileSystemEntity.typeSync(candidate) ==
          FileSystemEntityType.notFound) {
        return candidate;
      }
      i++;
    }
  }

  Future<void> _deleteSelected() async {
    final path = _selectedPath;
    if (path == null) return;
    await _deletePath(path);
  }

  Future<void> _deletePath(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) {
      setState(() {
        if (_selectedPath == path) _selectedPath = null;
        if (_clipboardPath == path) {
          _clipboardPath = null;
          _clipboardMode = null;
        }
      });
      return;
    }

    final ok = await _confirmDelete(context, path);
    if (!mounted || ok != true) return;

    try {
      final appState = context.read<AppState>();
      await _recordDeleteSnapshots(path, type);

      if (type == FileSystemEntityType.directory) {
        await Directory(path).delete(recursive: true);
      } else {
        await File(path).delete();
      }

      appState.noteEntityDeleted(path);
      appState.refreshDirectory();
      setState(() {
        if (_selectedPath == path || p.isWithin(path, _selectedPath ?? '')) {
          _selectedPath = null;
        }
        if (_clipboardPath == path || p.isWithin(path, _clipboardPath ?? '')) {
          _clipboardPath = null;
          _clipboardMode = null;
        }
      });
    } catch (e) {
      if (mounted) _toast(context, '${S.error}: $e');
    }
  }

  Future<void> _addPathToChat(AppState appState, String path) async {
    final ok = appState.chat.addPendingReference(
      path,
      workspacePath: appState.currentDirectory,
    );
    if (!ok) {
      if (mounted) _toast(context, S.chatReferenceMissing);
      return;
    }
    await appState.setChatHidden(false);
    if (mounted) _toast(context, S.chatReferenceAdded);
  }

  void _recordExplorerOperation(_ExplorerOperation op) {
    _undoStack.add(op);
    if (_undoStack.length > 100) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  Future<void> _undoExplorerOperation() async {
    if (_undoStack.isEmpty) {
      _toast(context, S.explorerUndoNothing);
      return;
    }
    final op = _undoStack.removeLast();
    try {
      await _applyExplorerOperation(op, undo: true);
      _redoStack.add(op);
      if (mounted) _toast(context, _undoMessage(op));
    } catch (e) {
      _undoStack.add(op);
      if (mounted) _toast(context, '${S.explorerUndoFailed}: $e');
    }
  }

  Future<void> _redoExplorerOperation() async {
    if (_redoStack.isEmpty) {
      _toast(context, S.explorerRedoNothing);
      return;
    }
    final op = _redoStack.removeLast();
    try {
      await _applyExplorerOperation(op, undo: false);
      _undoStack.add(op);
      if (mounted) _toast(context, _redoMessage(op));
    } catch (e) {
      _redoStack.add(op);
      if (mounted) _toast(context, '${S.explorerRedoFailed}: $e');
    }
  }

  Future<void> _applyExplorerOperation(
    _ExplorerOperation op, {
    required bool undo,
  }) async {
    final appState = context.read<AppState>();
    switch (op.kind) {
      case _ExplorerOperationKind.create:
        final target = op.to;
        if (undo) {
          await _deleteCreatedOrCopiedEntity(target);
          appState.noteEntityDeleted(target);
          if (_selectedPath == target ||
              p.isWithin(target, _selectedPath ?? '')) {
            setState(() => _selectedPath = null);
          }
        } else {
          if (FileSystemEntity.typeSync(target) !=
              FileSystemEntityType.notFound) {
            throw const _ExplorerOperationException(
              S.explorerRedoDestinationExists,
            );
          }
          if (op.isDirectory) {
            await Directory(target).create();
          } else {
            await File(target).create(recursive: true);
          }
          setState(() => _selectedPath = target);
        }
        break;
      case _ExplorerOperationKind.copy:
        final target = op.to;
        if (undo) {
          await _deleteCreatedOrCopiedEntity(target);
          appState.noteEntityDeleted(target);
          if (_selectedPath == target ||
              p.isWithin(target, _selectedPath ?? '')) {
            setState(() => _selectedPath = null);
          }
        } else {
          if (FileSystemEntity.typeSync(op.from) ==
              FileSystemEntityType.notFound) {
            throw const _ExplorerOperationException(
              S.explorerRedoSourceMissing,
            );
          }
          if (FileSystemEntity.typeSync(target) !=
              FileSystemEntityType.notFound) {
            throw const _ExplorerOperationException(
              S.explorerRedoDestinationExists,
            );
          }
          if (op.isDirectory) {
            _copyDirectory(Directory(op.from), Directory(target));
          } else {
            await File(op.from).copy(target);
          }
          setState(() => _selectedPath = target);
        }
        break;
      case _ExplorerOperationKind.move:
        final source = undo ? op.to : op.from;
        final destination = undo ? op.from : op.to;
        if (FileSystemEntity.typeSync(source) ==
            FileSystemEntityType.notFound) {
          throw _ExplorerOperationException(
            undo ? S.explorerUndoSourceMissing : S.explorerRedoSourceMissing,
          );
        }
        if (FileSystemEntity.typeSync(destination) !=
            FileSystemEntityType.notFound) {
          throw _ExplorerOperationException(
            undo
                ? S.explorerUndoDestinationExists
                : S.explorerRedoDestinationExists,
          );
        }
        if (op.isDirectory) {
          await Directory(source).rename(destination);
        } else {
          await File(source).rename(destination);
        }
        appState.noteEntityMoved(source, destination);
        setState(() => _selectedPath = destination);
        break;
    }
    appState.refreshDirectory();
  }

  Future<void> _deleteCreatedOrCopiedEntity(String path) async {
    final type = FileSystemEntity.typeSync(path);
    if (type == FileSystemEntityType.notFound) return;
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
      return;
    }
    await File(path).delete();
  }

  String _undoMessage(_ExplorerOperation op) {
    switch (op.kind) {
      case _ExplorerOperationKind.create:
        return S.explorerUndoCreate;
      case _ExplorerOperationKind.copy:
        return S.explorerUndoCopy;
      case _ExplorerOperationKind.move:
        return S.explorerUndoMove;
    }
  }

  String _redoMessage(_ExplorerOperation op) {
    switch (op.kind) {
      case _ExplorerOperationKind.create:
        return S.explorerRedoCreate;
      case _ExplorerOperationKind.copy:
        return S.explorerRedoCopy;
      case _ExplorerOperationKind.move:
        return S.explorerRedoMove;
    }
  }

  Future<void> _recordDeleteSnapshots(
    String path,
    FileSystemEntityType type,
  ) async {
    final timeline = context.read<AppState>().timeline;
    if (type == FileSystemEntityType.file) {
      await timeline.recordDelete(
        path,
        origin: TimelineOrigin.explorer,
        note: 'Deleted in file explorer',
      );
      return;
    }
    if (type != FileSystemEntityType.directory) return;
    try {
      await for (final entity in Directory(
        path,
      ).list(recursive: true, followLinks: false)) {
        if (entity is File) {
          await timeline.recordDelete(
            entity.path,
            origin: TimelineOrigin.explorer,
            note: 'Deleted in file explorer',
          );
        }
      }
    } catch (e) {
      debugPrint('Failed to snapshot deleted folder contents: $e');
    }
  }

  void _onFocusRequested() {
    if (!mounted) return;
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: DuckMotion.medium,
        curve: DuckMotion.standard,
      );
    }
    setState(() => _focusPulse = true);
    _focusPulseTimer?.cancel();
    _focusPulseTimer = Timer(const Duration(milliseconds: 320), () {
      if (!mounted) return;
      setState(() => _focusPulse = false);
    });
  }

  /// Force-route the watch-media `MediaController` to the editor
  /// split placement and load Microsoft Teams. Bypasses the URL
  /// prompt — the user explicitly asked for a one-click Teams
  /// shortcut, and the Teams web app only fits the editor split
  /// (the chat panel's 16:9 clamp is too cramped for a productivity
  /// app's UI). Doesn't persist the placement override; only this
  /// session is forced to `editor` until the user changes it from
  /// the modal.
  Future<void> _openTeams(BuildContext context) async {
    final media = context.read<MediaController>();
    await media.playTeams();
  }

  void _copyDirectory(Directory source, Directory destination) {
    destination.createSync(recursive: true);
    for (final entity in source.listSync(recursive: false)) {
      if (entity is Directory) {
        final newDir = Directory(
          '${destination.absolute.path}${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}',
        );
        _copyDirectory(entity, newDir);
      } else if (entity is File) {
        entity.copySync(
          '${destination.absolute.path}${Platform.pathSeparator}${entity.path.split(Platform.pathSeparator).last}',
        );
      }
    }
  }

  Future<String?> _promptName(
    BuildContext context,
    String title, {
    String initial = '',
  }) async {
    final ctrl = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: S.explorerNamePlaceholder,
          ),
          onSubmitted: (_) => Navigator.pop(ctx, ctrl.text.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text(S.ok),
          ),
        ],
      ),
    );
  }

  Future<void> _handleNewFile(
    BuildContext context,
    AppState appState,
    Directory parent,
  ) async {
    final name = await _promptName(context, S.explorerNewFileTitle);
    if (name == null || name.isEmpty) return;
    try {
      final f = File('${parent.path}${Platform.pathSeparator}$name');
      await f.create(recursive: false);
      _recordExplorerOperation(
        _ExplorerOperation.create(f.path, isDirectory: false),
      );
      appState.refreshDirectory();
      await appState.openFile(f);
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '${S.error}: $e');
    }
  }

  Future<void> _handleNewFolder(
    BuildContext context,
    AppState appState,
    Directory parent,
  ) async {
    final name = await _promptName(context, S.explorerNewFolderTitle);
    if (name == null || name.isEmpty) return;
    try {
      final dir = Directory('${parent.path}${Platform.pathSeparator}$name');
      await dir.create();
      _recordExplorerOperation(
        _ExplorerOperation.create(dir.path, isDirectory: true),
      );
      appState.refreshDirectory();
    } catch (e) {
      if (!context.mounted) return;
      _toast(context, '${S.error}: $e');
    }
  }

  void _toast(BuildContext context, String msg) {
    showDuckToast(context, msg);
  }

  /// `_FileTree` calls this from `initState` to publish a hit-test
  /// key for its folder row. The key is bound to the row's outer
  /// `Container` (NOT the whole subtree) so cursor hits on expanded
  /// children don't get attributed to the parent folder.
  void _registerFolderHit(String path, GlobalKey key) {
    _folderHitKeys[path] = key;
  }

  void _unregisterFolderHit(String path, GlobalKey key) {
    // Guard: if a different `_FileTree` re-registered the same path
    // (folder removed and re-added by a refresh tick), don't yank
    // the newer registration on the older one's dispose.
    if (_folderHitKeys[path] == key) {
      _folderHitKeys.remove(path);
    }
  }

  /// Walk every registered folder row, find the deepest one whose
  /// rendered rectangle contains [globalPos]. Returns null when the
  /// cursor isn't over any folder (e.g. it's over a file row, the
  /// activity bar, or empty space below the tree).
  ///
  /// Cost: O(visible folders), one `findRenderObject` + offset math
  /// per entry. Trees with thousands of expanded folders would feel
  /// it, but normal projects sit at <100 visible nodes — well under
  /// a frame budget at 60fps even on cold caches.
  String? _hitTestFolder(Offset globalPos) {
    String? best;
    int bestDepth = -1;
    _folderHitKeys.forEach((path, key) {
      final ctx = key.currentContext;
      if (ctx == null) return;
      final rb = ctx.findRenderObject();
      if (rb is! RenderBox || !rb.hasSize) return;
      final origin = rb.localToGlobal(Offset.zero);
      final rect = origin & rb.size;
      if (rect.contains(globalPos)) {
        // Deeper paths (more separators) win so child folders
        // beat their containing parent. Using path length is a
        // cheap proxy for depth that doesn't allocate a List.
        final depth = path.length;
        if (depth > bestDepth) {
          best = path;
          bestDepth = depth;
        }
      }
    });
    return best;
  }

  /// Copy a single dropped file/folder into [destDir]. Lifted out of
  /// the inline `onDragDone` callback so it can be reused for the
  /// per-folder drop path. Errors are caught and logged — one bad
  /// entry shouldn't abort the rest of the batch.
  ///
  /// Uses [_uniquePastePath] so an existing file with the same name
  /// is never silently overwritten — duplicates land as
  /// `name - Copy.ext`, `name - Copy 2.ext`, etc. Without this,
  /// dropping `report.pdf` twice into the same folder LOOKS like a
  /// no-op (second drop overwrites the first byte-for-byte) and
  /// reads as "the file explorer is broken / cached the previous
  /// drop". Matches the safety convention the in-app cut/copy/paste
  /// path already uses.
  void _copyDroppedEntry(String sourcePath, String destDir) {
    final destination = Directory(destDir);
    final dest = _uniquePastePath(destination, sourcePath);
    try {
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        _copyDirectory(Directory(sourcePath), Directory(dest));
      } else {
        File(sourcePath).copySync(dest);
      }
      _recordExplorerOperation(
        _ExplorerOperation.copy(
          sourcePath,
          dest,
          isDirectory: FileSystemEntity.isDirectorySync(dest),
        ),
      );
      debugPrint('[Lumen drop] $sourcePath -> $dest');
    } catch (e) {
      debugPrint('[Lumen drop] FAILED $sourcePath -> $dest: $e');
    }
  }

  GitIgnoreMatcher _matcherFor(AppState appState) {
    final workspace = appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) {
      return GitIgnoreMatcher.empty('');
    }
    if (_gitignoreMatcher == null ||
        _gitignoreWorkspace != workspace ||
        _gitignoreRefreshTick != appState.fileExplorerRefreshTick) {
      _gitignoreWorkspace = workspace;
      _gitignoreRefreshTick = appState.fileExplorerRefreshTick;
      _gitignoreMatcher = GitIgnoreMatcher.load(workspace);
    }
    return _gitignoreMatcher!;
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyC, control: true):
            _ExplorerCopyIntent(),
        SingleActivator(LogicalKeyboardKey.keyX, control: true):
            _ExplorerCutIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, control: true):
            _ExplorerPasteIntent(),
        SingleActivator(LogicalKeyboardKey.delete): _ExplorerDeleteIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true):
            _ExplorerUndoIntent(),
        SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
            _ExplorerRedoIntent(),
        SingleActivator(LogicalKeyboardKey.keyY, control: true):
            _ExplorerRedoIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _ExplorerCopyIntent: CallbackAction<_ExplorerCopyIntent>(
            onInvoke: (_) {
              _copySelected();
              return null;
            },
          ),
          _ExplorerCutIntent: CallbackAction<_ExplorerCutIntent>(
            onInvoke: (_) {
              _cutSelected();
              return null;
            },
          ),
          _ExplorerPasteIntent: CallbackAction<_ExplorerPasteIntent>(
            onInvoke: (_) {
              final current = context.read<AppState>().currentDirectory;
              if (current == null) return null;
              final selected = _selectedPath;
              final target =
                  selected != null && FileSystemEntity.isDirectorySync(selected)
                  ? Directory(selected)
                  : Directory(current);
              // **OS clipboard wins when it has files.** The user's
              // mental model is "I just Ctrl+C'd in [other app],
              // Ctrl+V should paste THAT". The previous priority
              // (internal first) made stale `_clipboardPath` values
              // (set by an old context-menu Copy, never cleared
              // because the user never hit Ctrl+V in the explorer
              // again) silently win over fresh external copies.
              //
              // Internal clipboard is consulted only when the OS
              // clipboard has nothing — covers the "Cut in Lumen,
              // Paste in Lumen" workflow that Cursor's right-click
              // Paste menu also uses. The right-click "Paste" menu
              // item still calls `_pasteInto` directly, bypassing
              // this Ctrl+V routing, so the user can always force
              // the internal clipboard if they need to.
              //
              // External paste is always treated as COPY (never
              // delete the source even if the user did Ctrl+X in
              // the OS file manager): a remote file manager's "cut"
              // semantics are too lossy to trust across processes,
              // and "I lost a file" beats "I typed Ctrl+V and now
              // I have to delete the original myself".
              _routePaste(target);
              return null;
            },
          ),
          _ExplorerDeleteIntent: CallbackAction<_ExplorerDeleteIntent>(
            onInvoke: (_) {
              _deleteSelected();
              return null;
            },
          ),
          _ExplorerUndoIntent: CallbackAction<_ExplorerUndoIntent>(
            onInvoke: (_) {
              _undoExplorerOperation();
              return null;
            },
          ),
          _ExplorerRedoIntent: CallbackAction<_ExplorerRedoIntent>(
            onInvoke: (_) {
              _redoExplorerOperation();
              return null;
            },
          ),
        },
        child: Focus(
          focusNode: _focusNode,
          child: Consumer<AppState>(
            builder: (context, appState, child) {
              if (appState.currentDirectory == null) {
                return Container(color: DuckColors.bgRaised);
              }

              final dir = Directory(appState.currentDirectory!);
              final gitignore = _matcherFor(appState);
              final rootName = dir.path
                  .split(Platform.pathSeparator)
                  .last
                  .toUpperCase();

              return DropTarget(
                onDragEntered: (_) => setState(() {
                  _isDragging = true;
                  // Reset stale value at the START of a fresh drag
                  // (in case the previous drag ended without a drop
                  // and left the folder cached).
                  _externalDropFolder = null;
                }),
                // **Don't clear `_externalDropFolder` here.** On
                // Windows, `desktop_drop` fires `onDragExited`
                // BEFORE `onDragDone` when the user releases the
                // mouse — Win32's `IDropTarget::Drop` routes
                // through DragLeave → Drop semantics. Clearing the
                // hovered folder on exit makes onDragDone read
                // null and fall back to the workspace root —
                // which was the "drops always land in root" bug.
                // Only the panel-border highlight (`_isDragging`)
                // is cleared on exit; folder-row highlight is
                // gated below on both `_isDragging == true` AND a
                // matching path so a stale `_externalDropFolder`
                // can't paint a ghost highlight after the drag is
                // gone.
                onDragExited: (_) => setState(() => _isDragging = false),
                // Hit-test the folder under the cursor on every
                // movement so the highlight tracks live with the
                // drag. setState is cheap because we only repaint
                // when the resolved folder actually changes.
                onDragUpdated: (details) {
                  final next = _hitTestFolder(details.globalPosition);
                  if (next != _externalDropFolder) {
                    setState(() => _externalDropFolder = next);
                  }
                },
                onDragDone: (detail) {
                  // Pin the destination BEFORE clearing UI state
                  // (otherwise the setState below races the read).
                  final destDir =
                      _externalDropFolder ?? appState.currentDirectory!;
                  // Diagnostic: tells us at a glance whether
                  // `desktop_drop` is delivering a fresh file list
                  // per drop or stuck on a cached one. If a second
                  // drop logs the SAME source as the first, that's
                  // a package-level bug and we'd need to vendor the
                  // plugin or upgrade. So far we've only seen
                  // silent-overwrite-mistaken-for-cache, hence the
                  // unique-name fix in `_copyDroppedEntry`.
                  debugPrint(
                    '[Lumen drop] dest=$destDir files=${detail.files.map((f) => f.path).toList()}',
                  );
                  setState(() {
                    _isDragging = false;
                    _externalDropFolder = null;
                  });
                  for (final file in detail.files) {
                    _copyDroppedEntry(file.path, destDir);
                  }
                  appState.refreshDirectory();
                },
                child: DuckGlass(
                  border: _isDragging
                      ? Border.all(
                          color: DuckColors.accentPurple.withValues(alpha: 0.5),
                          width: 1,
                        )
                      : (_focusPulse
                            ? Border.all(
                                color: DuckColors.accentCyan.withValues(
                                  alpha: 0.7,
                                ),
                                width: 1,
                              )
                            : null),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Cursor-style activity-bar strip — sits above the
                      // workspace-name row so the cluster reads as the
                      // top-of-sidebar nav. Folder = scroll-to-top focus,
                      // search = Quick Open, media = watch-media URL prompt.
                      _ExplorerActivityBar(
                        onSettings: () => handleMenuAction(context, 'settings'),
                        onSearch: () => appState.ideActions.openQuickOpen(),
                        onMedia: () => showMediaUrlPrompt(context),
                        onTeams: () => _openTeams(context),
                        onTimeline: () => showTimelineDialog(context),
                      ),
                      _ExplorerHeader(
                        workspaceName: rootName,
                        collapsed: _treeCollapsed,
                        onToggle: () =>
                            setState(() => _treeCollapsed = !_treeCollapsed),
                        onNewFile: () => _handleNewFile(context, appState, dir),
                        onNewFolder: () =>
                            _handleNewFolder(context, appState, dir),
                        // The title row is "selected" when the user
                        // has explicitly clicked it OR when nothing
                        // is selected at all (so the implicit fallback
                        // matches the visible signal). Tapping any
                        // other row clears the title selection.
                        selected:
                            _selectedPath == null || _selectedPath == dir.path,
                        onSelect: () => _selectPath(dir.path),
                      ),
                      if (!_treeCollapsed)
                        Expanded(
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onSecondaryTapDown: (details) {
                              _showEmptyAreaMenu(
                                context,
                                appState,
                                dir,
                                details.globalPosition,
                              );
                            },
                            child: SingleChildScrollView(
                              controller: _scrollController,
                              child: Padding(
                                padding: const EdgeInsets.only(bottom: 20),
                                child: _FileTree(
                                  directory: dir,
                                  isRoot: true,
                                  refreshTick: appState.fileExplorerRefreshTick,
                                  selectedPath: _selectedPath,
                                  onSelect: _selectPath,
                                  gitignore: gitignore,
                                  onContextMenu: _showItemContextMenu,
                                  onContextMenuFolder: _showFolderContextMenu,
                                  onExplorerOperation: _recordExplorerOperation,
                                  // Highlight only while a drag is
                                  // actively in flight — the raw
                                  // `_externalDropFolder` value
                                  // PERSISTS past `onDragExited` (so
                                  // `onDragDone` can read it on
                                  // Windows where exit fires first),
                                  // but the visual highlight must
                                  // not.
                                  externalDropFolder: _isDragging
                                      ? _externalDropFolder
                                      : null,
                                  onRegisterFolderHit: _registerFolderHit,
                                  onUnregisterFolderHit: _unregisterFolderHit,
                                ),
                              ),
                            ),
                          ),
                        ),
                      // Pinned bottom rail — file revision history for the
                      // active editor file. Self-collapses to nothing when
                      // there's no active file or no revisions captured
                      // yet (e.g. fresh workspace), so it never adds blank
                      // chrome under the tree.
                      const TimelineRail(),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showEmptyAreaMenu(
    BuildContext context,
    AppState appState,
    Directory dir,
    Offset position,
  ) async {
    _focusNode.requestFocus();
    final result = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: 'newFile',
          child: _MenuLabel(label: S.explorerNewFile),
        ),
        const PopupMenuItem(
          value: 'newFolder',
          child: _MenuLabel(label: S.explorerNewFolder),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'reveal',
          child: _MenuLabel(label: S.explorerRevealInOs),
        ),
        const PopupMenuItem(
          value: 'refresh',
          child: _MenuLabel(label: S.explorerRefresh),
        ),
        if (_clipboardPath != null) const PopupMenuDivider(),
        if (_clipboardPath != null)
          const PopupMenuItem(
            value: 'paste',
            child: _MenuLabel(label: S.paste),
          ),
      ],
    );
    if (!context.mounted || result == null) return;
    switch (result) {
      case 'newFile':
        await _handleNewFile(context, appState, dir);
        break;
      case 'newFolder':
        await _handleNewFolder(context, appState, dir);
        break;
      case 'reveal':
        _revealInOs(dir.path);
        break;
      case 'refresh':
        appState.refreshDirectory();
        break;
      case 'paste':
        await _pasteInto(dir);
        break;
    }
  }

  Future<void> _showFolderContextMenu(
    BuildContext context,
    Directory dir,
    Offset position,
  ) async {
    final appState = context.read<AppState>();
    _selectPath(dir.path);
    final isRoot = dir.path == appState.currentDirectory;

    final result = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: 'newFile',
          child: _MenuLabel(label: S.explorerNewFile),
        ),
        const PopupMenuItem(
          value: 'newFolder',
          child: _MenuLabel(label: S.explorerNewFolder),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'reveal',
          child: _MenuLabel(label: S.explorerRevealInOs),
        ),
        const PopupMenuItem(
          value: 'terminal',
          child: _MenuLabel(label: S.explorerOpenInTerminal),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'addToChat',
          child: _MenuLabel(label: S.chatAddReference),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'copyPath',
          child: _MenuLabel(label: S.explorerCopyPath),
        ),
        const PopupMenuItem(
          value: 'copyRelPath',
          child: _MenuLabel(label: S.explorerCopyRelativePath),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'copy',
          child: _MenuLabel(label: S.copy),
        ),
        if (!isRoot)
          const PopupMenuItem(
            value: 'cut',
            child: _MenuLabel(label: S.menuCut),
          ),
        if (_clipboardPath != null)
          const PopupMenuItem(
            value: 'paste',
            child: _MenuLabel(label: S.paste),
          ),
        if (!isRoot) const PopupMenuDivider(),
        if (!isRoot)
          const PopupMenuItem(
            value: 'rename',
            child: _MenuLabel(label: S.rename),
          ),
        if (!isRoot)
          const PopupMenuItem(
            value: 'delete',
            child: _MenuLabel(label: S.delete, danger: true),
          ),
      ],
    );
    if (!context.mounted || result == null) return;

    switch (result) {
      case 'newFile':
        await _handleNewFile(context, appState, dir);
        break;
      case 'newFolder':
        await _handleNewFolder(context, appState, dir);
        break;
      case 'reveal':
        _revealInOs(dir.path);
        break;
      case 'terminal':
        _openTerminalAt(dir.path);
        break;
      case 'addToChat':
        await _addPathToChat(appState, dir.path);
        break;
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: dir.path));
        if (context.mounted) _toast(context, S.explorerCopyPath);
        break;
      case 'copyRelPath':
        final rel = _relTo(appState.currentDirectory!, dir.path);
        await Clipboard.setData(ClipboardData(text: rel));
        if (context.mounted) _toast(context, S.explorerCopyRelativePath);
        break;
      case 'copy':
        await _copySelected();
        break;
      case 'cut':
        _cutSelected();
        break;
      case 'paste':
        await _pasteInto(dir);
        break;
      case 'rename':
        final newName = await _promptName(
          context,
          S.explorerRenameTitle,
          initial: dir.path.split(Platform.pathSeparator).last,
        );
        if (newName == null || newName.isEmpty) return;
        try {
          final parts = dir.path.split(Platform.pathSeparator)..removeLast();
          final source = dir.path;
          final dest =
              parts.join(Platform.pathSeparator) +
              Platform.pathSeparator +
              newName;
          await dir.rename(dest);
          _recordExplorerOperation(
            _ExplorerOperation.move(source, dest, isDirectory: true),
          );
          appState.noteEntityMoved(source, dest);
          appState.refreshDirectory();
        } catch (e) {
          if (context.mounted) _toast(context, '${S.error}: $e');
        }
        break;
      case 'delete':
        await _deletePath(dir.path);
        break;
    }
  }

  Future<void> _showItemContextMenu(
    BuildContext context,
    File file,
    Offset position,
  ) async {
    final appState = context.read<AppState>();
    _selectPath(file.path);

    // Resolve a workspace-relative path for the timeline entry's
    // pre-scope. `_relTo` returns the absolute path back when the
    // file isn't under the workspace (defensive — shouldn't happen
    // from the explorer, which only lists workspace files), so we
    // gate the menu item on the workspace existing rather than on
    // the relative path itself being non-empty.
    final workspaceOpen = appState.currentDirectory != null;

    final result = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        position.dx,
        position.dy,
      ),
      items: [
        const PopupMenuItem(
          value: 'open',
          child: _MenuLabel(label: S.open),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'reveal',
          child: _MenuLabel(label: S.explorerRevealInOs),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'copyPath',
          child: _MenuLabel(label: S.explorerCopyPath),
        ),
        const PopupMenuItem(
          value: 'copyRelPath',
          child: _MenuLabel(label: S.explorerCopyRelativePath),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'addToChat',
          child: _MenuLabel(label: S.chatAddReference),
        ),
        if (workspaceOpen) const PopupMenuDivider(),
        if (workspaceOpen)
          const PopupMenuItem(
            value: 'timeline',
            child: _MenuLabel(label: S.timelineMenuLabel),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'copy',
          child: _MenuLabel(label: S.copy),
        ),
        const PopupMenuItem(
          value: 'cut',
          child: _MenuLabel(label: S.menuCut),
        ),
        if (_clipboardPath != null)
          const PopupMenuItem(
            value: 'paste',
            child: _MenuLabel(label: S.paste),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: 'rename',
          child: _MenuLabel(label: S.rename),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: _MenuLabel(label: S.delete, danger: true),
        ),
      ],
    );
    if (!context.mounted || result == null) return;

    switch (result) {
      case 'open':
        await appState.openFile(file);
        break;
      case 'reveal':
        _revealInOs(file.path);
        break;
      case 'addToChat':
        await _addPathToChat(appState, file.path);
        break;
      case 'copyPath':
        await Clipboard.setData(ClipboardData(text: file.path));
        if (context.mounted) _toast(context, S.explorerCopyPath);
        break;
      case 'copyRelPath':
        final rel = _relTo(appState.currentDirectory!, file.path);
        await Clipboard.setData(ClipboardData(text: rel));
        if (context.mounted) _toast(context, S.explorerCopyRelativePath);
        break;
      case 'timeline':
        // Pre-scope the dialog to this file's history. Forward-slash
        // normalisation matches the convention `TimelineService`
        // stores `relPath` in — without it Windows back-slashes
        // would never match the entries on the right side of the
        // dialog's filter.
        final rel = _relTo(
          appState.currentDirectory!,
          file.path,
        ).replaceAll(r'\', '/');
        if (!context.mounted) return;
        await showTimelineDialog(context, relPath: rel);
        break;
      case 'copy':
        await _copySelected();
        break;
      case 'cut':
        _cutSelected();
        break;
      case 'paste':
        await _pasteInto(file.parent);
        break;
      case 'rename':
        final newName = await _promptName(
          context,
          S.explorerRenameTitle,
          initial: file.path.split(Platform.pathSeparator).last,
        );
        if (newName == null || newName.isEmpty) return;
        try {
          final parts = file.path.split(Platform.pathSeparator)..removeLast();
          final source = file.path;
          final dest =
              parts.join(Platform.pathSeparator) +
              Platform.pathSeparator +
              newName;
          await file.rename(dest);
          _recordExplorerOperation(
            _ExplorerOperation.move(source, dest, isDirectory: false),
          );
          appState.noteEntityMoved(source, dest);
          appState.refreshDirectory();
        } catch (e) {
          if (context.mounted) _toast(context, '${S.error}: $e');
        }
        break;
      case 'delete':
        await _deletePath(file.path);
        break;
    }
  }

  /// Confirmation dialog shown before any user-initiated delete from
  /// the file explorer (context menu, Delete-key shortcut, root /
  /// folder context menus).
  ///
  /// Replaces the earlier plain `AlertDialog` (Material defaults
  /// rendered as a bright white card on the dark theme) with a
  /// `_DeleteConfirmDialog` matching the project's `DuckGlass.hero`
  /// modal aesthetic. Three meaningful behavioural improvements over
  /// the old one:
  ///
  /// 1. **Path is shown** — the user sees the file/folder name +
  ///    parent dir before confirming. The old prompt just said
  ///    "Delete?" with zero context, which is the kind of vague
  ///    confirmation people muscle-click "OK" through.
  /// 2. **File vs folder copy diverges** — folder deletes get a
  ///    louder "everything inside it — recursively" warning since
  ///    the blast radius is much bigger.
  /// 3. **Enter confirms, Escape cancels** — the destructive button
  ///    is autofocused so a user who's already mentally committed
  ///    to deleting can hit Enter without reaching for the mouse.
  ///    Same keyboard convention as system dialogs.
  Future<bool?> _confirmDelete(BuildContext context, String path) {
    final isDirectory =
        FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
    final workspace = context.read<AppState>().currentDirectory;
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => _DeleteConfirmDialog(
        path: path,
        isDirectory: isDirectory,
        workspaceRoot: workspace,
      ),
    );
  }

  void _revealInOs(String path) {
    if (Platform.isWindows) {
      Process.start('explorer.exe', ['/select,', path]);
    } else if (Platform.isMacOS) {
      Process.start('open', ['-R', path]);
    } else {
      Process.start('xdg-open', [
        FileSystemEntity.isDirectorySync(path)
            ? path
            : Directory(path).parent.path,
      ]);
    }
  }

  void _openTerminalAt(String path) {
    if (Platform.isWindows) {
      Process.start('cmd.exe', [
        '/c',
        'start',
        'powershell',
        '-NoExit',
        '-WorkingDirectory',
        path,
      ]);
    } else if (Platform.isMacOS) {
      Process.start('open', ['-a', 'Terminal', path]);
    } else {
      Process.start('x-terminal-emulator', [], workingDirectory: path);
    }
  }

  String _relTo(String root, String full) {
    final r = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    if (full.startsWith(r)) return full.substring(r.length);
    return full;
  }
}

/// Workspace-root header: a chevron + the project name, with the
/// Activity-bar strip that sits at the very top of the file
/// explorer panel, above the workspace-name row. Mirrors Cursor's
/// pattern of putting workspace-navigation icons (files / search /
/// extras) immediately under the title bar.
///
/// Three actions, all delegated up to `_FileExplorerState`:
/// - **folder**  → `onFocus` — animates the explorer's scroll
///   controller back to offset 0 and pulses the panel border to
///   `accentCyan` for ~320ms (the same `_onFocusRequested` action
///   that's still reachable through `IdeActions.focusFileExplorer`
///   for command-palette / future shortcut bindings).
/// - **search**  → `onSearch` — opens Quick Open via the
///   shared overlay. Doesn't switch panels, just opens the
///   palette over the workbench.
/// - **media**   → `onMedia` — opens the watch-media URL prompt
///   from `widgets/common/media_url_prompt.dart`; on confirm,
///   `MediaController.play` loads the URL into the shared webview
///   and the chat / editor panel renders it depending on the
///   user's `MediaPlacement` preference.
///
/// Visual rules: 34px tall, `glassSeam` 0.5px hairline along the
/// bottom (seams with `_ExplorerHeader` below), no top border (it
/// already inherits the explorer panel's outer chrome). Icons go
/// through `BrightIconButton` so the styling matches the menu bar's
/// settings cog exactly. Don't add a label/title here — Cursor's
/// equivalent strip is icon-only and the user explicitly asked for
/// the same.
class _ExplorerActivityBar extends StatelessWidget {
  final VoidCallback onSettings;
  final VoidCallback onSearch;
  final VoidCallback onMedia;
  final VoidCallback onTeams;
  final VoidCallback onTimeline;

  const _ExplorerActivityBar({
    required this.onSettings,
    required this.onSearch,
    required this.onMedia,
    required this.onTeams,
    required this.onTimeline,
  });

  @override
  Widget build(BuildContext context) {
    // Each tile is button + trailing seam (the seam after the last
    // button is suppressed below). A 0.5px `glassSeam` line at ~30%
    // height feels like a hairline divider rather than a hard
    // border — matches the menu bar's seams and the file tree's
    // active-row stripe in restraint.
    final tiles = <Widget>[
      BrightIconButton(
        icon: Icons.settings_outlined,
        tooltip: S.menuSettings,
        onTap: onSettings,
      ),
      BrightIconButton(
        icon: Icons.search,
        tooltip: S.menuBarSearchTooltip,
        onTap: onSearch,
      ),
      BrightIconButton(
        icon: Icons.ondemand_video_outlined,
        tooltip: S.chatWatchMedia,
        onTap: onMedia,
      ),
      // Teams shortcut — one click loads `teams.cloud.microsoft`
      // into the editor split. Sits between the watch-media icon
      // and the timeline/history controls, grouped with productivity nav.
      BrightIconButton(
        icon: Icons.groups_outlined,
        tooltip: S.explorerOpenTeams,
        onTap: onTeams,
      ),
      // File revision timeline — opens the floating diff panel
      // pre-scoped to the active file when one is open. Mounted
      // here (not on the menu bar) because revision history is a
      // workspace-nav concept; the menu bar carries IDE-config
      // affordances only.
      BrightIconButton(
        icon: Icons.history,
        tooltip: S.timelineMenuTooltip,
        onTap: onTimeline,
      ),
      // Watch the master switch here at construction time so when the
      // user disables GitNexus we don't leave a dangling separator
      // hairline pointing at empty space (the row's seam-between-tiles
      // pattern doesn't know about a self-hidden tile).
      if (context.select<AppState, bool>((s) => s.gitnexusEnabled))
        const _GitNexusStatusButton(),
    ];

    return Container(
      height: 34,
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            tiles[i],
            if (i < tiles.length - 1) const _ActivityBarSeam(),
          ],
        ],
      ),
    );
  }
}

/// Subtle vertical hairline that separates icon tiles in the
/// explorer activity bar. Same `glassSeam` colour the menu bar
/// uses for its top/bottom hairlines so the chrome reads as one
/// material; 12px tall against the 34px bar so it occupies the
/// middle third only and never visually competes with the icons.
class _ActivityBarSeam extends StatelessWidget {
  const _ActivityBarSeam();

  @override
  Widget build(BuildContext context) {
    return Container(width: 0.5, height: 14, color: DuckColors.glassSeam);
  }
}

class _GitNexusStatusButton extends StatefulWidget {
  const _GitNexusStatusButton();

  @override
  State<_GitNexusStatusButton> createState() => _GitNexusStatusButtonState();
}

class _GitNexusStatusButtonState extends State<_GitNexusStatusButton> {
  final GlobalKey _key = GlobalKey();
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AppState>(
      builder: (context, state, _) {
        // Master switch off → no GitNexus icon at all. We deliberately
        // collapse the slot rather than render a "disabled" icon to
        // honour the user's "I don't want to see this integration"
        // intent. The activity-bar `Row` already handles missing
        // tiles via its mainAxisAlignment.spaceEvenly layout, so
        // shrinking to zero is safe.
        if (!state.gitnexusEnabled) return const SizedBox.shrink();
        final service = state.gitnexus;
        final color = _statusColor(service.status, _hover);
        // A running daemon (serve / mcp) deserves a distinct
        // affordance from "indexed and idle". Each daemon's bottom-
        // right dot is positioned independently so both can show at
        // once when the user has both daemons up. Colour map:
        //   - serve dot → mint  (HTTP server, "data flowing")
        //   - mcp dot   → purple ("AI host integration")
        final daemonDots = <Widget>[];
        if (service.serveRunning) {
          daemonDots.add(
            const Positioned(
              right: 4,
              bottom: 3,
              child: _DaemonDot(color: DuckColors.accentMint),
            ),
          );
        }
        if (service.mcpRunning) {
          daemonDots.add(
            const Positioned(
              right: 4,
              top: 3,
              child: _DaemonDot(color: DuckColors.accentPurple),
            ),
          );
        }
        return Tooltip(
          message: _tooltipFor(service),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hover = true),
            onExit: (_) => setState(() => _hover = false),
            child: GestureDetector(
              key: _key,
              onTap: () => _showMenu(context, service),
              child: AnimatedContainer(
                duration: DuckMotion.fast,
                curve: DuckMotion.standard,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                decoration: BoxDecoration(
                  color: _hover
                      ? DuckColors.bgRaisedHi.withValues(alpha: 0.62)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.center,
                  children: [
                    // While the analyze indexer is running, render a
                    // tiny progress ring instead of the static icon.
                    // Same outer footprint so the activity-bar layout
                    // doesn't shift mid-run.
                    if (service.isRunning)
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.6,
                          color: DuckColors.accentCyan,
                        ),
                      )
                    else
                      Icon(Icons.account_tree_outlined, size: 16, color: color),
                    ...daemonDots,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Tooltip composes status + active daemons so a glance reveals
  /// the full state without opening the menu. Adopted serve renders
  /// with a "(shared)" suffix so the user knows it's machine-wide
  /// without having to open Settings.
  String _tooltipFor(GitNexusService service) {
    final parts = <String>[S.gitnexusTitle, _statusLabel(service.status)];
    if (service.serveRunning) {
      parts.add(
        service.serveAdopted
            ? S.gitnexusServeRunningOnAdopted(service.servePort)
            : S.gitnexusServeRunningOn(service.servePort),
      );
    }
    if (service.mcpRunning) {
      parts.add(S.gitnexusMcpRunningTooltip);
    }
    return parts.join(' · ');
  }

  Future<void> _showMenu(BuildContext context, GitNexusService service) async {
    final box = _key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(
      Offset(0, box.size.height),
      ancestor: overlay,
    );
    final picked = await showFastMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        pos.dx - 160,
        pos.dy + 4,
        overlay.size.width - pos.dx - box.size.width,
        0,
      ),
      items: [
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            _statusLabel(service.status),
            style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
          ),
        ),
        const PopupMenuDivider(),
        if (service.isRunning)
          const PopupMenuItem<String>(
            value: 'stop',
            child: Text(S.gitnexusStop),
          )
        else ...[
          const PopupMenuItem<String>(
            value: 'analyze',
            child: Text(S.gitnexusAnalyzeNow),
          ),
          const PopupMenuItem<String>(
            value: 'reanalyze',
            child: Text(S.gitnexusReanalyze),
          ),
        ],
        const PopupMenuDivider(),
        // Toggle for the machine-wide serve daemon. When the running
        // instance was started by another window (adopted), the
        // label spells out that stopping it affects every Lumen
        // window — no surprise side-effects from a one-click action.
        // The mcp toggle intentionally lives only in Settings now:
        // it's per-window stdio that almost no one needs because AI
        // hosts spawn their own.
        PopupMenuItem<String>(
          value: 'toggle-serve',
          child: Row(
            children: [
              const _DaemonDot(color: DuckColors.accentMint),
              const SizedBox(width: 8),
              Text(
                !service.serveRunning
                    ? S.gitnexusServeStart
                    : service.serveAdopted
                    ? S.gitnexusServeStopMachineWide
                    : S.gitnexusServeStop,
              ),
            ],
          ),
        ),
        const PopupMenuDivider(),
        const PopupMenuItem<String>(
          value: 'settings',
          child: Text(S.gitnexusOpenSettings),
        ),
      ],
    );
    if (!context.mounted || picked == null) return;
    switch (picked) {
      case 'stop':
        await service.stop();
        break;
      case 'analyze':
        await service.analyze();
        break;
      case 'reanalyze':
        await service.analyze(force: true);
        break;
      case 'toggle-serve':
        await service.setServeRunning(!service.serveRunning);
        break;
      case 'settings':
        context.read<AppState>().openSettingsTab(category: 'gitnexus');
        break;
    }
  }

  Color _statusColor(GitNexusStatus status, bool hover) {
    // `running` used to share `stateWarn` (#EBCB8B) with `indexed`'s
    // `accentDuck`, which is the same hex value — the user couldn't
    // tell mid-run from idle-and-indexed at a glance. The active
    // running state is now drawn as a `CircularProgressIndicator`
    // upstream (so the colour here is unused on `running`, but kept
    // for completeness in case the icon falls back). Indexed stays
    // gold so the steady-state remains the brand colour the user
    // recognises.
    return switch (status) {
      GitNexusStatus.indexed => DuckColors.accentDuck,
      GitNexusStatus.running => DuckColors.accentCyan,
      GitNexusStatus.failed => DuckColors.stateError,
      GitNexusStatus.noNode => DuckColors.stateWarn,
      GitNexusStatus.notIndexed =>
        hover ? DuckColors.fgPrimary : DuckColors.fgMuted,
      GitNexusStatus.noWorkspace =>
        hover ? DuckColors.fgPrimary : DuckColors.fgMuted,
    };
  }

  String _statusLabel(GitNexusStatus status) {
    return switch (status) {
      GitNexusStatus.noWorkspace => S.gitnexusStatusNoWorkspace,
      GitNexusStatus.noNode => S.gitnexusStatusNoNode,
      GitNexusStatus.notIndexed => S.gitnexusStatusNotIndexed,
      GitNexusStatus.indexed => S.gitnexusStatusIndexed,
      GitNexusStatus.running => S.gitnexusStatusRunning,
      GitNexusStatus.failed => S.gitnexusStatusFailed,
    };
  }
}

/// Tiny circular pip rendered over the GitNexus icon to signal an
/// active background daemon (serve / mcp). 6×6 with a 1px outline so
/// it reads against either dark or hover-lifted chrome backgrounds.
class _DaemonDot extends StatelessWidget {
  final Color color;
  const _DaemonDot({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: DuckColors.bgDeeper, width: 1),
      ),
    );
  }
}

/// Workspace-root header. The whole row is tappable — clicking toggles the
/// tree collapse/expand exactly like a real folder row. New-file / new-folder
/// actions are always visible on the right (explicit user preference: don't
/// hide them behind hover). Manual refresh is intentionally not shown here;
/// the filesystem watcher keeps the explorer current, and the context menu
/// still has Refresh as an escape hatch.
class _ExplorerHeader extends StatefulWidget {
  final String workspaceName;
  final bool collapsed;
  final VoidCallback onToggle;
  final VoidCallback onNewFile;
  final VoidCallback onNewFolder;

  /// True when the workspace root is the selected paste target —
  /// either no folder is selected, or the user explicitly clicked
  /// the title row. Adds the same 2px `accentCyan` left-edge stripe
  /// that file rows use for the active editor file, so the user can
  /// see at a glance where Ctrl+V will land.
  final bool selected;

  /// Called when the user clicks the workspace name (NOT the
  /// chevron, which still toggles collapse via [onToggle]). Lets
  /// the explorer set `_selectedPath = workspaceRoot` so that
  /// Ctrl+V on an external clipboard pastes into the project root
  /// with explicit visual feedback rather than the implicit "no
  /// selection = root" fallback.
  final VoidCallback onSelect;

  const _ExplorerHeader({
    required this.workspaceName,
    required this.collapsed,
    required this.onToggle,
    required this.onNewFile,
    required this.onNewFolder,
    required this.selected,
    required this.onSelect,
  });

  @override
  State<_ExplorerHeader> createState() => _ExplorerHeaderState();
}

class _ExplorerHeaderState extends State<_ExplorerHeader> {
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        mouseCursor: SystemMouseCursors.click,
        // Tapping the title row both selects the root (so Ctrl+V
        // pastes here) AND toggles collapse — same compound
        // behaviour Cursor's workspace-root row uses. Single tap,
        // two side effects: `_selectedPath = workspaceRoot`
        // becomes the destination and the tree open/closed state
        // flips. Users who want to ONLY toggle without changing
        // selection can still hit the chevron-only zone visually,
        // but in practice the row is treated as one control.
        onTap: () {
          widget.onSelect();
          widget.onToggle();
        },
        hoverColor: Colors.transparent,
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Container(
          height: 28,
          // 2px accentCyan left stripe when this row is the paste
          // target. Trimming the leading padding to compensate so
          // the chevron stays in the same x-position whether
          // selected or not.
          padding: EdgeInsets.only(left: widget.selected ? 8 : 10, right: 8),
          decoration: widget.selected
              ? const BoxDecoration(
                  border: Border(
                    left: BorderSide(color: DuckColors.accentCyan, width: 2),
                  ),
                )
              : null,
          child: Row(
            children: [
              Icon(
                widget.collapsed
                    ? Icons.keyboard_arrow_right
                    : Icons.keyboard_arrow_down,
                size: 14,
                color: DuckColors.fgSubtle,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  widget.workspaceName,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                    color: widget.selected
                        ? DuckColors.fgPrimary
                        : DuckColors.fgMuted,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _IconBtn(
                    icon: Icons.create_new_folder,
                    tooltip: S.explorerNewFolder,
                    onTap: widget.onNewFolder,
                  ),
                  _IconBtn(
                    icon: Icons.note_add,
                    tooltip: S.explorerNewFile,
                    onTap: widget.onNewFile,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({
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
          mouseCursor: SystemMouseCursors.click,
          onTap: onTap,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 14, color: DuckColors.fgMuted),
          ),
        ),
      ),
    );
  }
}

class _FileTree extends StatefulWidget {
  final Directory directory;
  final bool isRoot;
  final int level;

  /// Bumped by `AppState.refreshDirectory()` (manual refresh button
  /// + filesystem watcher debounce). When this changes between
  /// rebuilds, `didUpdateWidget` re-runs `_loadChildren()` so the
  /// cached `_children` listing matches disk again. Without this
  /// the State holds onto its stale listing across the rebuild
  /// even though `notifyListeners` fired upstream.
  final int refreshTick;
  final String? selectedPath;
  final void Function(String path) onSelect;
  final GitIgnoreMatcher gitignore;
  final void Function(BuildContext context, File file, Offset position)
  onContextMenu;
  final void Function(BuildContext context, Directory dir, Offset position)
  onContextMenuFolder;
  final void Function(_ExplorerOperation operation) onExplorerOperation;

  /// Path of the folder under the OS-level external drag cursor.
  /// `null` when no external drag is in flight, or the cursor is on
  /// a non-folder area. Each `_FileTree` compares this against its
  /// own directory path to know whether to highlight the row.
  final String? externalDropFolder;

  /// `_FileExplorerState` registry callbacks. Each `_FileTreeState`
  /// publishes a hit-test GlobalKey for its row so the root
  /// `DropTarget` can resolve the cursor position to a folder path.
  final void Function(String path, GlobalKey key)? onRegisterFolderHit;
  final void Function(String path, GlobalKey key)? onUnregisterFolderHit;

  const _FileTree({
    required this.directory,
    required this.onContextMenu,
    required this.onContextMenuFolder,
    required this.onExplorerOperation,
    required this.refreshTick,
    required this.selectedPath,
    required this.onSelect,
    required this.gitignore,
    this.isRoot = false,
    this.level = 0,
    this.externalDropFolder,
    this.onRegisterFolderHit,
    this.onUnregisterFolderHit,
  });

  @override
  State<_FileTree> createState() => _FileTreeState();
}

class _FileTreeState extends State<_FileTree> {
  bool _expanded = false;
  List<FileSystemEntity> _children = [];
  bool _hover = false;
  bool _dragOver = false;

  /// Hit-test key bound to the folder ROW container only — NOT to
  /// the whole subtree. Without this distinction, a cursor over an
  /// expanded child would be attributed to the parent folder during
  /// hit-test and the wrong folder would highlight.
  final GlobalKey _hitKey = GlobalKey();

  /// The path the row is currently registered under. Stored
  /// separately from `widget.directory.path` so that on
  /// `didUpdateWidget` (path change) we can deregister the OLD path
  /// before registering the new one — otherwise a stale entry would
  /// linger forever in `_FileExplorerState._folderHitKeys`.
  String? _registeredPath;

  @override
  void initState() {
    super.initState();
    if (widget.isRoot) _expanded = true;
    _loadChildren();
    _registerHit();
  }

  void _registerHit() {
    if (widget.isRoot) return;
    final path = widget.directory.path;
    widget.onRegisterFolderHit?.call(path, _hitKey);
    _registeredPath = path;
  }

  void _unregisterHit() {
    final path = _registeredPath;
    if (path == null) return;
    widget.onUnregisterFolderHit?.call(path, _hitKey);
    _registeredPath = null;
  }

  @override
  void dispose() {
    _unregisterHit();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _FileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload on path change OR refresh-tick change. Tick change
    // = manual refresh button or fs watcher fired in AppState.
    if (oldWidget.directory.path != widget.directory.path ||
        oldWidget.refreshTick != widget.refreshTick) {
      _loadChildren();
    }
    if (oldWidget.directory.path != widget.directory.path) {
      _unregisterHit();
      _registerHit();
    }
  }

  void _loadChildren() {
    try {
      if (widget.directory.existsSync()) {
        _children = widget.directory.listSync()
          ..sort((a, b) {
            if (a is Directory && b is File) return -1;
            if (a is File && b is Directory) return 1;
            return a.path.toLowerCase().compareTo(b.path.toLowerCase());
          });
      }
    } catch (_) {}
  }

  bool _canAcceptDrop(String sourcePath) {
    final name = sourcePath.split(Platform.pathSeparator).last;
    final destPath = '${widget.directory.path}${Platform.pathSeparator}$name';
    if (p.equals(sourcePath, destPath)) return false;
    // Don't allow dropping a folder into itself or a descendant.
    if (FileSystemEntity.isDirectorySync(sourcePath) &&
        (p.equals(sourcePath, widget.directory.path) ||
            p.isWithin(sourcePath, widget.directory.path))) {
      return false;
    }
    // Refuse clobber moves. Native explorers often ask whether to
    // overwrite/merge; Lumen should be conservative until that UI exists.
    if (FileSystemEntity.typeSync(destPath) != FileSystemEntityType.notFound) {
      return false;
    }
    return true;
  }

  /// Move a file-system entity into this folder.
  Future<void> _acceptDrop(String sourcePath) async {
    final name = sourcePath.split(Platform.pathSeparator).last;
    final destPath = '${widget.directory.path}${Platform.pathSeparator}$name';
    if (p.equals(sourcePath, destPath)) return;
    // Don't allow dropping a folder into itself or a descendant.
    if (FileSystemEntity.isDirectorySync(sourcePath) &&
        (p.equals(sourcePath, widget.directory.path) ||
            p.isWithin(sourcePath, widget.directory.path))) {
      showDuckToast(context, S.explorerMoveIntoSelf);
      return;
    }
    if (FileSystemEntity.typeSync(destPath) != FileSystemEntityType.notFound) {
      showDuckToast(context, S.explorerMoveDestinationExists);
      return;
    }
    try {
      final appState = context.read<AppState>();
      if (FileSystemEntity.isDirectorySync(sourcePath)) {
        await Directory(sourcePath).rename(destPath);
      } else {
        await appState.timeline.ensureBaseline(sourcePath);
        await File(sourcePath).rename(destPath);
        await appState.timeline.recordRename(
          sourcePath,
          destPath,
          origin: TimelineOrigin.explorer,
          note: 'Moved in file explorer',
        );
      }
      widget.onExplorerOperation(
        _ExplorerOperation.move(
          sourcePath,
          destPath,
          isDirectory: FileSystemEntity.isDirectorySync(destPath),
        ),
      );
      appState.noteEntityMoved(sourcePath, destPath);
      appState.refreshDirectory();
    } catch (e) {
      debugPrint('Move failed: $e');
      if (mounted) showDuckToast(context, '${S.explorerMoveFailed}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isRoot) {
      return DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          final src = details.data;
          return _canAcceptDrop(src);
        },
        onAcceptWithDetails: (details) => _acceptDrop(details.data),
        builder: (context, candidateData, rejectedData) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _children
                .map(
                  (c) => c is Directory
                      ? _FileTree(
                          directory: c,
                          level: widget.level + 1,
                          refreshTick: widget.refreshTick,
                          selectedPath: widget.selectedPath,
                          onSelect: widget.onSelect,
                          gitignore: widget.gitignore,
                          onContextMenu: widget.onContextMenu,
                          onContextMenuFolder: widget.onContextMenuFolder,
                          onExplorerOperation: widget.onExplorerOperation,
                          externalDropFolder: widget.externalDropFolder,
                          onRegisterFolderHit: widget.onRegisterFolderHit,
                          onUnregisterFolderHit: widget.onUnregisterFolderHit,
                        )
                      : _FileItemRow(
                          file: c as File,
                          level: widget.level + 1,
                          selected: widget.selectedPath == c.path,
                          onSelect: widget.onSelect,
                          ignored: widget.gitignore.isIgnored(
                            c.path,
                            isDirectory: false,
                          ),
                          onContextMenu: widget.onContextMenu,
                        ),
                )
                .toList(),
          );
        },
      );
    }

    final dirName = widget.directory.path.split(Platform.pathSeparator).last;
    final selected = widget.selectedPath == widget.directory.path;
    final ignored = widget.gitignore.isIgnored(
      widget.directory.path,
      isDirectory: true,
    );

    // Wrap the folder row in both Draggable (so it can be moved) and
    // DragTarget (so items can be dropped into it). Uses the tolerant
    // draggable with an 8px movement threshold so a click-and-twitch
    // doesn't fire an accidental folder move — see the
    // `_TolerantDraggable` doc at the bottom of this file.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _TolerantDraggable<String>(
          data: widget.directory.path,
          allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
          feedback: Material(
            color: Colors.transparent,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: DuckColors.bgRaisedHi,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                border: Border.all(color: DuckColors.accentCyan, width: 0.5),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.keyboard_arrow_right,
                    size: 13,
                    color: DuckColors.fgSubtle,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    dirName,
                    style: const TextStyle(
                      fontSize: 11,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.3,
            child: _buildFolderRow(
              dirName,
              selected: selected,
              ignored: ignored,
            ),
          ),
          child: DragTarget<String>(
            onWillAcceptWithDetails: (details) {
              final src = details.data;
              if (!_canAcceptDrop(src)) return false;
              setState(() => _dragOver = true);
              return true;
            },
            onLeave: (_) => setState(() => _dragOver = false),
            onAcceptWithDetails: (details) {
              setState(() => _dragOver = false);
              _acceptDrop(details.data);
            },
            builder: (context, candidateData, rejectedData) {
              // Three highlight sources, OR'd together:
              //   - `_dragOver` / `candidateData.isNotEmpty`: internal
              //     in-tree drag of another file/folder onto this row.
              //   - `widget.externalDropFolder == directory.path`:
              //     an OS-level drag (from Windows Explorer / Finder)
              //     is currently hovering this folder. Shares the
              //     same purple accent so the user can't tell which
              //     drag system fired the highlight, just that the
              //     drop target is this folder.
              // The `KeyedSubtree` binds the row's hit-test GlobalKey
              // — bound here (NOT the whole subtree) so cursor
              // hits on expanded children don't get attributed to
              // the parent folder.
              final externalHover =
                  widget.externalDropFolder == widget.directory.path;
              return KeyedSubtree(
                key: _hitKey,
                child: _buildFolderRow(
                  dirName,
                  selected: selected,
                  ignored: ignored,
                  highlight:
                      _dragOver || candidateData.isNotEmpty || externalHover,
                ),
              );
            },
          ),
        ),
        if (_expanded)
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _children
                .map(
                  (c) => c is Directory
                      ? _FileTree(
                          directory: c,
                          level: widget.level + 1,
                          refreshTick: widget.refreshTick,
                          selectedPath: widget.selectedPath,
                          onSelect: widget.onSelect,
                          gitignore: widget.gitignore,
                          onContextMenu: widget.onContextMenu,
                          onContextMenuFolder: widget.onContextMenuFolder,
                          onExplorerOperation: widget.onExplorerOperation,
                          externalDropFolder: widget.externalDropFolder,
                          onRegisterFolderHit: widget.onRegisterFolderHit,
                          onUnregisterFolderHit: widget.onUnregisterFolderHit,
                        )
                      : _FileItemRow(
                          file: c as File,
                          level: widget.level + 1,
                          selected: widget.selectedPath == c.path,
                          onSelect: widget.onSelect,
                          ignored: widget.gitignore.isIgnored(
                            c.path,
                            isDirectory: false,
                          ),
                          onContextMenu: widget.onContextMenu,
                        ),
                )
                .toList(),
          ),
      ],
    );
  }

  Widget _buildFolderRow(
    String dirName, {
    bool selected = false,
    bool ignored = false,
    bool highlight = false,
  }) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          widget.onSelect(widget.directory.path);
          widget.onContextMenuFolder(
            context,
            widget.directory,
            details.globalPosition,
          );
        },
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: () {
            widget.onSelect(widget.directory.path);
            setState(() {
              _expanded = !_expanded;
              if (_expanded) _loadChildren();
            });
          },
          child: Container(
            color: highlight
                ? DuckColors.accentCyan.withValues(alpha: 0.15)
                : (selected
                      ? DuckColors.bgChip
                      : (_hover ? DuckColors.bgRaisedHi : Colors.transparent)),
            padding: EdgeInsets.only(
              left: 8.0 + (widget.level * 12.0),
              right: 8.0,
              top: 3,
              bottom: 3,
            ),
            child: Row(
              children: [
                Icon(
                  _expanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 14,
                  color: highlight
                      ? DuckColors.accentCyan
                      : DuckColors.fgSubtle,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    dirName,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DuckColors.fgPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (ignored) const _GitIgnoredBadge(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GitIgnoredBadge extends StatelessWidget {
  const _GitIgnoredBadge();

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.explorerGitIgnoredTooltip,
      child: Container(
        width: 14,
        height: 14,
        margin: const EdgeInsets.only(left: 8),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DuckColors.accentDuck.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(
            color: DuckColors.accentDuck.withValues(alpha: 0.45),
            width: 0.5,
          ),
        ),
        child: const Text(
          S.explorerGitIgnoredBadge,
          style: TextStyle(
            color: DuckColors.accentDuck,
            fontSize: 9,
            height: 1.0,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _FileItemRow extends StatefulWidget {
  final File file;
  final int level;
  final bool selected;
  final bool ignored;
  final void Function(String path) onSelect;
  final void Function(BuildContext context, File file, Offset position)
  onContextMenu;

  const _FileItemRow({
    required this.file,
    required this.level,
    required this.selected,
    required this.ignored,
    required this.onSelect,
    required this.onContextMenu,
  });

  @override
  State<_FileItemRow> createState() => _FileItemRowState();
}

class _FileItemRowState extends State<_FileItemRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final fileName = widget.file.path.split(Platform.pathSeparator).last;
    final appState = context.watch<AppState>();
    final isActive = appState.activeFile?.path == widget.file.path;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      // Tolerant draggable — 8px movement threshold so quick clicks
      // (especially click-and-release with hand twitch) don't kick
      // off an accidental file move. See `_TolerantDraggable` doc.
      child: _TolerantDraggable<String>(
        data: widget.file.path,
        allowedButtonsFilter: (buttons) => buttons == kPrimaryButton,
        feedback: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: DuckColors.bgRaisedHi,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.accentCyan, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  FileIconColors.iconForFileName(fileName),
                  size: 13,
                  color: FileIconColors.forFileName(fileName),
                ),
                const SizedBox(width: 6),
                Text(
                  fileName,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
        childWhenDragging: Opacity(
          opacity: 0.3,
          child: _buildRow(fileName, isActive, appState),
        ),
        child: _buildRow(fileName, isActive, appState),
      ),
    );
  }

  Widget _buildRow(String fileName, bool isActive, AppState appState) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onSecondaryTapDown: (details) {
          widget.onSelect(widget.file.path);
          widget.onContextMenu(context, widget.file, details.globalPosition);
        },
        child: InkWell(
          mouseCursor: SystemMouseCursors.click,
          onTap: () {
            widget.onSelect(widget.file.path);
            appState.openFile(widget.file);
          },
          child: Container(
            // Active file gets a 2px accentCyan stripe down its leading
            // edge — clear "this is the open file" signal on top of the
            // existing subtle bg lift. Greys are unchanged.
            decoration: BoxDecoration(
              color: isActive
                  ? DuckColors.bgChip
                  : (widget.selected
                        ? DuckColors.bgRaisedHi.withValues(alpha: 0.7)
                        : (_hover
                              ? DuckColors.bgRaisedHi
                              : Colors.transparent)),
              border: isActive
                  ? const Border(
                      left: BorderSide(color: DuckColors.accentCyan, width: 2),
                    )
                  : null,
            ),
            padding: EdgeInsets.only(
              left: (isActive ? 22.0 : 24.0) + (widget.level * 12.0),
              right: 8.0,
              top: 3,
              bottom: 3,
            ),
            child: Row(
              children: [
                Icon(
                  FileIconColors.iconForFileName(fileName),
                  size: 13,
                  color: FileIconColors.forFileName(fileName),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    fileName,
                    style: TextStyle(
                      fontSize: 12.5,
                      color: isActive
                          ? DuckColors.fgPrimary
                          : DuckColors.fgMuted,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.ignored) const _GitIgnoredBadge(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuLabel extends StatelessWidget {
  final String label;
  final bool danger;
  const _MenuLabel({required this.label, this.danger = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: TextStyle(
        fontSize: 13,
        color: danger ? DuckColors.stateError : DuckColors.fgPrimary,
      ),
    );
  }
}

/// Glass delete-confirmation dialog matching the project's
/// `DuckGlass.hero` modal aesthetic (see `media_url_prompt`,
/// `backup_dialog`, `manual_skill_dialog` for the same pattern).
///
/// Renders:
/// - Header: red trash icon + contextual title ("Delete file?" /
///   "Delete folder?") + close button.
/// - Body: the file/folder name in mono, parent dir below it as a
///   muted hint (relative to workspace root when possible). Then a
///   contextual description — folder deletes get a louder
///   "recursive, everything inside" warning.
/// - Footer note about the timeline (agent edits are recoverable;
///   manual deletes through this dialog are NOT).
/// - Action row: Cancel (text button) + Delete (destructive
///   `stateError`-tinted ElevatedButton, **autofocus: true** so
///   pressing Enter in the dialog confirms without a mouse click).
///
/// Escape dismisses via Material's default dialog route handling.
class _DeleteConfirmDialog extends StatelessWidget {
  final String path;
  final bool isDirectory;
  final String? workspaceRoot;

  const _DeleteConfirmDialog({
    required this.path,
    required this.isDirectory,
    required this.workspaceRoot,
  });

  String get _name => p.basename(path);

  /// Parent dir display string. Prefers a workspace-relative path
  /// (`src/components/`) over the full absolute one
  /// (`C:\Users\me\proj\src\components\`) because the relative form
  /// is shorter, more readable, and consistent with how the rest of
  /// Lumen identifies files in chat / timeline / status messages.
  String get _parentDisplay {
    final parent = p.dirname(path);
    if (workspaceRoot != null && p.isWithin(workspaceRoot!, parent)) {
      return p.relative(parent, from: workspaceRoot!);
    }
    if (workspaceRoot != null && p.equals(workspaceRoot!, parent)) {
      // File sits directly in workspace root — show the workspace
      // name instead of an empty string ("./" reads as confusing).
      return p.basename(workspaceRoot!);
    }
    return parent;
  }

  @override
  Widget build(BuildContext context) {
    final title = isDirectory
        ? S.explorerDeleteFolderTitle
        : S.explorerDeleteFileTitle;
    final body = isDirectory
        ? S.explorerDeleteFolderBody
        : S.explorerDeleteFileBody;

    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 460,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── Header ─────────────────────────────────
              Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: DuckColors.stateError.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: DuckColors.stateError.withValues(alpha: 0.35),
                        width: 0.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.delete_outline,
                      size: 16,
                      color: DuckColors.stateError,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                  ),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(false),
                      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close,
                          size: 14,
                          color: DuckColors.fgSubtle,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              // ── Path card ──────────────────────────────
              // The thing being deleted. Mono filename + dim parent
              // directory below — same shape as the file-tool cards
              // in the chat panel so users learn ONE "this is a
              // file path" affordance across the IDE.
              Container(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                decoration: BoxDecoration(
                  color: DuckColors.bgChip,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                  border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                ),
                child: Row(
                  children: [
                    Icon(
                      isDirectory
                          ? Icons.folder_outlined
                          : Icons.insert_drive_file_outlined,
                      size: 16,
                      color: isDirectory
                          ? DuckColors.folderIcon
                          : DuckColors.fileIcon,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _name,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: DuckColors.fgPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            _parentDisplay,
                            style: const TextStyle(
                              fontSize: 11,
                              color: DuckColors.fgSubtle,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 14),
              // ── Body ───────────────────────────────────
              Text(
                body,
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.explorerDeleteUndoHint,
                style: const TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgSubtle,
                  height: 1.4,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(height: 18),
              // ── Footer actions ─────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    style: TextButton.styleFrom(
                      foregroundColor: DuckColors.fgMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: const Text(S.cancel),
                  ),
                  const SizedBox(width: 6),
                  // **autofocus + Material's default keyboard
                  // activation** — Enter while this dialog is open
                  // confirms the delete without needing a mouse
                  // click. This is the part the user explicitly
                  // asked for; ButtonStyleButton's built-in
                  // ActivateIntent handler maps Enter to onPressed
                  // when the button has focus.
                  ElevatedButton.icon(
                    autofocus: true,
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text(S.delete),
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DuckColors.stateError,
                      foregroundColor: DuckColors.bgDeepest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Drag activation tolerance ───────────────────────────────────────
//
// File-explorer rows used to start a drag the moment the cursor moved
// even one logical pixel — Flutter's default Draggable wires through
// `ImmediateMultiDragGestureRecognizer`, which uses
// `kPrecisePointerHitSlop = 1.0` for mouse pointers. That makes
// click-and-twitch combinations (the user clicks a file, hand moves a
// pixel during release) silently kick off a move. Users would see a
// file vanish into the wrong sibling folder and read the resulting
// "destination exists / no-op" toast as a bug.
//
// The fix is a movement threshold, not a time delay — replicating
// Windows Explorer's behaviour (drag starts after ~6-10 logical px).
// `LongPressDraggable` was rejected because it adds a hold-then-drag
// feel that the IDE explicitly does NOT want; the original choice of
// `Draggable` over `LongPressDraggable` was deliberate.
//
// `_TolerantDraggable<T>` overrides `Draggable.createRecognizer` to
// return `_TolerantMultiDragGestureRecognizer`, which only accepts
// the gesture once the pointer's accumulated delta exceeds [slop]
// pixels. Behaviour:
//
// - Click + release         → InkWell tap fires (open file). No drag.
// - Click + 1-7px wiggle    → InkWell tap fires. No drag.
// - Click + sustained drag  → drag starts as soon as the threshold
//                             is crossed; feels nearly identical to
//                             the previous "immediate" recognizer for
//                             deliberate drags.
// - Right-click             → Unaffected (allowedButtonsFilter still
//                             filters to kPrimaryButton).
//
// 8.0 logical px chosen empirically: kTouchSlop is 18px (touch
// screens, more tolerance), kPrecisePointerHitSlop is 1px (mouse,
// surgical precision). 8px sits between — well above hand twitch but
// below "I'm starting to drag this".

class _TolerantDraggable<T extends Object> extends Draggable<T> {
  final double slop;

  const _TolerantDraggable({
    super.key,
    required super.child,
    required super.feedback,
    super.data,
    super.childWhenDragging,
    super.feedbackOffset,
    super.dragAnchorStrategy,
    super.maxSimultaneousDrags,
    super.onDragStarted,
    super.onDragUpdate,
    super.onDraggableCanceled,
    super.onDragEnd,
    super.onDragCompleted,
    super.allowedButtonsFilter,
    this.slop = 8.0,
  });

  @override
  MultiDragGestureRecognizer createRecognizer(
    GestureMultiDragStartCallback onStart,
  ) {
    return _TolerantMultiDragGestureRecognizer(
      slop: slop,
      allowedButtonsFilter: allowedButtonsFilter,
    )..onStart = onStart;
  }
}

class _TolerantMultiDragGestureRecognizer extends MultiDragGestureRecognizer {
  _TolerantMultiDragGestureRecognizer({
    super.debugOwner,
    super.allowedButtonsFilter,
    required this.slop,
  });

  final double slop;

  @override
  MultiDragPointerState createNewPointerState(PointerDownEvent event) {
    return _TolerantPointerState(
      event.position,
      event.kind,
      gestureSettings,
      slop,
    );
  }

  @override
  String get debugDescription => 'tolerant multidrag';
}

class _TolerantPointerState extends MultiDragPointerState {
  _TolerantPointerState(
    super.initialPosition,
    super.kind,
    super.deviceGestureSettings,
    this.slop,
  );

  final double slop;

  @override
  void checkForResolutionAfterMove() {
    final delta = pendingDelta;
    if (delta == null) return;
    if (delta.distanceSquared > slop * slop) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void accepted(GestureMultiDragStartCallback starter) {
    starter(initialPosition);
  }
}
