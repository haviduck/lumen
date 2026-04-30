import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/file_index.dart';
import '../../theme/app_colors.dart';

/// VS-Code-style quick file picker. Reads from the host-owned
/// [FileIndex]. Enter opens the selected file via [AppState.openFile].
class QuickOpen extends StatefulWidget {
  final FileIndex index;
  final VoidCallback onClose;
  const QuickOpen({super.key, required this.index, required this.onClose});

  @override
  State<QuickOpen> createState() => _QuickOpenState();
}

class _QuickOpenState extends State<QuickOpen> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  List<FileEntry> _results = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _input.addListener(_recompute);
    _refreshFromIndex();
    if (widget.index.isBuilding) {
      widget.index.build().then((_) {
        if (mounted) _refreshFromIndex();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _refreshFromIndex() {
    setState(() {
      _results = widget.index.search(_input.text);
      _selected = 0;
    });
  }

  void _recompute() => _refreshFromIndex();

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(
      () => _selected = (_selected + delta).clamp(0, _results.length - 1),
    );
    if (_scroll.hasClients) {
      const row = 38.0;
      final target = _selected * row;
      final off = _scroll.offset;
      final viewport = _scroll.position.viewportDimension;
      if (target < off) {
        _scroll.jumpTo(target);
      }
      if (target + row > off + viewport) {
        _scroll.jumpTo(target + row - viewport);
      }
    }
  }

  void _activate() {
    if (_results.isEmpty) return;
    final entry = _results[_selected];
    widget.onClose();
    Future.microtask(() async {
      if (!mounted) return;
      await context.read<AppState>().openFile(File(entry.absolutePath));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): _MoveIntent(1),
        SingleActivator(LogicalKeyboardKey.arrowUp): _MoveIntent(-1),
        SingleActivator(LogicalKeyboardKey.enter): _ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.numpadEnter): _ActivateIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _MoveIntent: CallbackAction<_MoveIntent>(
            onInvoke: (i) {
              _move(i.delta);
              return null;
            },
          ),
          _ActivateIntent: CallbackAction<_ActivateIntent>(
            onInvoke: (_) {
              _activate();
              return null;
            },
          ),
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Input(
              controller: _input,
              focusNode: _focus,
              hint: S.quickOpenHint,
            ),
            if (widget.index.isBuilding)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Flexible(
              child: _results.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(28),
                      child: Text(
                        widget.index.isBuilding
                            ? S.quickOpenIndexing
                            : S.quickOpenNoResults,
                        style: const TextStyle(
                          color: DuckColors.fgSubtle,
                          fontSize: 13,
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.zero,
                      itemCount: _results.length,
                      itemBuilder: (ctx, i) {
                        final entry = _results[i];
                        final selected = i == _selected;
                        return MouseRegion(
                          onEnter: (_) {
                            if (i != _selected) {
                              setState(() => _selected = i);
                            }
                          },
                          child: InkWell(
                            onTap: () {
                              setState(() => _selected = i);
                              _activate();
                            },
                            child: Container(
                              height: 38,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              color: selected
                                  ? DuckColors.bgRaisedHi
                                  : Colors.transparent,
                              child: Row(
                                children: [
                                  const Icon(
                                    Icons.description,
                                    size: 13,
                                    color: DuckColors.fileIcon,
                                  ),
                                  const SizedBox(width: 10),
                                  Text(
                                    entry.name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      color: DuckColors.fgPrimary,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      entry.relativePath,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: DuckColors.fgSubtle,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
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

class _MoveIntent extends Intent {
  final int delta;
  const _MoveIntent(this.delta);
}

class _ActivateIntent extends Intent {
  const _ActivateIntent();
}

class _Input extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  const _Input({
    required this.controller,
    required this.focusNode,
    required this.hint,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        // Transparent so the host's glass tint shows through.
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.bolt, size: 16, color: DuckColors.accentDuck),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                hintStyle: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 14,
                ),
              ),
              style: const TextStyle(color: DuckColors.fgPrimary, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
}
