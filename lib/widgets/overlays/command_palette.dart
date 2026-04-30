import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/command_catalog.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// VS-Code-style command palette. Type to filter, arrow keys to navigate,
/// Enter to run. Only commands whose `isEnabled(state)` returns true are
/// runnable — disabled ones still appear, dimmed, so users can discover
/// them.
class CommandPalette extends StatefulWidget {
  final VoidCallback onClose;
  const CommandPalette({super.key, required this.onClose});

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final List<IdeCommand> _all = CommandCatalog.build();
  List<IdeCommand> _filtered = const [];
  int _selected = 0;

  @override
  void initState() {
    super.initState();
    _filtered = _all;
    _input.addListener(_recomputeFilter);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inputFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _recomputeFilter() {
    final q = _input.text.trim().toLowerCase();
    setState(() {
      if (q.isEmpty) {
        _filtered = _all;
      } else {
        _filtered = _all.where((c) {
          final hay = '${c.title} ${c.category ?? ''} ${c.id}'.toLowerCase();
          return hay.contains(q) || _subseq(q, hay);
        }).toList();
      }
      _selected = 0;
    });
  }

  static bool _subseq(String needle, String haystack) {
    int i = 0;
    for (int j = 0; i < needle.length && j < haystack.length; j++) {
      if (needle.codeUnitAt(i) == haystack.codeUnitAt(j)) i++;
    }
    return i == needle.length;
  }

  void _move(int delta) {
    if (_filtered.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _filtered.length - 1);
    });
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    final approxRow = 38.0;
    final target = (_selected * approxRow);
    final viewport = _scroll.position.viewportDimension;
    final offset = _scroll.offset;
    if (target < offset) {
      _scroll.jumpTo(target);
    } else if (target + approxRow > offset + viewport) {
      _scroll.jumpTo(target + approxRow - viewport);
    }
  }

  void _runSelected() {
    if (_filtered.isEmpty) return;
    final cmd = _filtered[_selected];
    final state = context.read<AppState>();
    if (!cmd.isEnabled(state)) return;
    widget.onClose();
    Future.microtask(() {
      if (!mounted) return;
      cmd.run(context);
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
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
              _runSelected();
              return null;
            },
          ),
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _PaletteInput(
              controller: _input,
              focusNode: _inputFocus,
              hint: S.paletteHint,
              icon: Icons.terminal_outlined,
            ),
            Flexible(
              child: _filtered.isEmpty
                  ? const _EmptyState(text: S.paletteNoResults)
                  : ListView.builder(
                      controller: _scroll,
                      padding: EdgeInsets.zero,
                      itemCount: _filtered.length,
                      itemBuilder: (ctx, i) {
                        final cmd = _filtered[i];
                        final enabled = cmd.isEnabled(state);
                        return _CommandRow(
                          command: cmd,
                          selected: i == _selected,
                          enabled: enabled,
                          onTap: () {
                            if (!enabled) return;
                            setState(() => _selected = i);
                            _runSelected();
                          },
                          onHover: () {
                            if (i == _selected) return;
                            setState(() => _selected = i);
                          },
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

class _PaletteInput extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final IconData icon;
  const _PaletteInput({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        // Transparent so the host's glass tint shows through.
        border: Border(bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: DuckColors.fgSubtle),
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

class _CommandRow extends StatelessWidget {
  final IdeCommand command;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _CommandRow({
    required this.command,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? DuckColors.fgPrimary : DuckColors.fgFaint;
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
          child: Row(
            children: [
              Icon(command.icon, size: 14, color: enabled ? DuckColors.fgMuted : DuckColors.fgFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Row(
                  children: [
                    if (command.category != null) ...[
                      Text(
                        '${command.category}: ',
                        style: const TextStyle(
                          fontSize: 12.5,
                          color: DuckColors.fgSubtle,
                        ),
                      ),
                    ],
                    Flexible(
                      child: Text(
                        command.title,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: fg),
                      ),
                    ),
                  ],
                ),
              ),
              if (command.shortcut != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: DuckColors.bgChip,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                  ),
                  child: Text(
                    command.shortcut!,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: DuckColors.fgSubtle,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState({required this.text});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Text(
        text,
        style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 13),
      ),
    );
  }
}
