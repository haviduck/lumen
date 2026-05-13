import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/command_catalog.dart';
import '../../services/file_index.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Lumen's unified search — replaces the separate Quick Open and
/// Command Palette overlays with one entry point that finds files,
/// commands, settings, and features inline.
///
/// Results are bucketed by source ([Commands], [Settings], [Files])
/// with section headers between buckets; arrow keys navigate the flat
/// list of selectable rows regardless of section. The Commands bucket
/// includes Settings entries (they're modeled as commands with
/// `category: 'Settings'`) but the section header splits them out so
/// the user reads two distinct groups.
///
/// Activate behaviour by row kind:
/// - **Command / Settings** — runs `IdeCommand.run` (closes overlay
///   first so any dialog/route the command opens stacks correctly).
/// - **File** — calls `AppState.openFile` for the absolute path.
///
/// Title-bar pill (`menu_bar.dart::_TitleBarSearchPill`), `Ctrl+P`,
/// and `Ctrl+Shift+P` all route through `IdeActions.openUnifiedSearch`
/// → this widget. The legacy `openQuickOpen` and `openCommandPalette`
/// callbacks redirect here too so existing call sites keep working.
class UnifiedSearch extends StatefulWidget {
  final FileIndex index;
  final VoidCallback onClose;
  const UnifiedSearch({super.key, required this.index, required this.onClose});

  @override
  State<UnifiedSearch> createState() => _UnifiedSearchState();
}

enum _ResultKind { command, settings, file }

class _Result {
  final _ResultKind kind;
  final IdeCommand? command;
  final FileEntry? file;
  const _Result.command(IdeCommand this.command)
      : kind = _ResultKind.command,
        file = null;
  const _Result.settings(IdeCommand this.command)
      : kind = _ResultKind.settings,
        file = null;
  const _Result.file(FileEntry this.file)
      : kind = _ResultKind.file,
        command = null;
}

class _UnifiedSearchState extends State<UnifiedSearch> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  // CommandCatalog is split inside the search: any IdeCommand with
  // `category == 'Settings'` is surfaced as a Settings row instead of
  // a Command row. One catalog, two visual buckets — keeps the
  // settings entries discoverable as commands too.
  final List<IdeCommand> _commands = CommandCatalog.build()
      .where((c) => c.category != 'Settings')
      .toList();
  final List<IdeCommand> _settings = CommandCatalog.build()
      .where((c) => c.category == 'Settings')
      .toList();
  List<_Result> _results = const [];
  int _selected = 0;

  // Per-bucket caps. Tight enough that a single-letter query doesn't
  // flood the overlay with 60 file matches; the file bucket is the
  // biggest concession because files are the most populous source.
  static const int _kMaxCommands = 8;
  static const int _kMaxSettings = 8;
  static const int _kMaxFiles = 20;

  @override
  void initState() {
    super.initState();
    _input.addListener(_recompute);
    _refresh();
    if (widget.index.isBuilding) {
      widget.index.build().then((_) {
        if (mounted) _refresh();
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

  void _recompute() => _refresh();

  void _refresh() {
    final raw = _input.text.trim();
    final state = context.read<AppState>();

    final cmdMatches = _matchCommands(raw, _commands, _kMaxCommands, state);
    final settingsMatches =
        _matchCommands(raw, _settings, _kMaxSettings, state);

    // Files only shown once the user has typed at least one character.
    // Empty-query state is for command/settings discovery — surfacing
    // every file in the index would drown the catalog rows.
    final fileMatches = raw.isEmpty
        ? const <FileEntry>[]
        : widget.index.search(raw, limit: _kMaxFiles);

    setState(() {
      _results = [
        for (final c in cmdMatches) _Result.command(c),
        for (final s in settingsMatches) _Result.settings(s),
        for (final f in fileMatches) _Result.file(f),
      ];
      _selected = 0;
    });
  }

  static List<IdeCommand> _matchCommands(
    String q,
    List<IdeCommand> source,
    int limit,
    AppState state,
  ) {
    if (q.isEmpty) {
      // Empty-query: top-of-list discovery slice. Filter to enabled
      // so a disabled `Undo` (no editor open) doesn't squat one of
      // the precious 8 visible slots.
      return source.where((c) => c.isEnabled(state)).take(limit).toList();
    }
    final ql = q.toLowerCase();
    final scored = <_ScoredCommand>[];
    for (final c in source) {
      final score = _scoreCommand(ql, c);
      if (score > 0) scored.add(_ScoredCommand(c, score));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.cmd).toList();
  }

  static int _scoreCommand(String ql, IdeCommand c) {
    final title = c.title.toLowerCase();
    final cat = (c.category ?? '').toLowerCase();
    final id = c.id.toLowerCase();
    if (title.contains(ql)) {
      // Substring match — boost when the prefix lines up so typing
      // "set" picks "Open Settings: …" before "Reset …".
      return 100 + (title.startsWith(ql) ? 30 : 0);
    }
    if (cat.contains(ql)) return 60;
    if (id.contains(ql)) return 50;
    if (_subseq(ql, title)) return 30;
    if (_subseq(ql, '$title $cat $id')) return 10;
    return 0;
  }

  static bool _subseq(String needle, String haystack) {
    int i = 0;
    for (int j = 0; i < needle.length && j < haystack.length; j++) {
      if (needle.codeUnitAt(i) == haystack.codeUnitAt(j)) i++;
    }
    return i == needle.length;
  }

  void _move(int delta) {
    if (_results.isEmpty) return;
    setState(() {
      _selected = (_selected + delta).clamp(0, _results.length - 1);
    });
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scroll.hasClients) return;
    // The body uses a sliver-aware mix of rows + section headers;
    // approximating row height for jump-to-visible is good enough.
    // Section headers are 22 px, rows 38 px; a uniform 40 px keeps
    // the math forgiving (over-scrolls slightly on adjacent-row moves).
    const approxRow = 40.0;
    final target = _selected * approxRow;
    final off = _scroll.offset;
    final viewport = _scroll.position.viewportDimension;
    if (target < off) _scroll.jumpTo(target);
    if (target + approxRow > off + viewport) {
      _scroll.jumpTo(target + approxRow - viewport);
    }
  }

  void _activate() {
    if (_results.isEmpty) return;
    final r = _results[_selected];
    widget.onClose();
    final state = context.read<AppState>();
    Future.microtask(() async {
      if (!mounted) return;
      switch (r.kind) {
        case _ResultKind.command:
        case _ResultKind.settings:
          final cmd = r.command!;
          if (cmd.isEnabled(state)) cmd.run(context);
          break;
        case _ResultKind.file:
          await context.read<AppState>().openFile(File(r.file!.absolutePath));
          break;
      }
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
              hint: S.unifiedSearchHint,
            ),
            if (widget.index.isBuilding)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: LinearProgressIndicator(minHeight: 2),
              ),
            Flexible(
              child: _results.isEmpty ? _empty() : _resultsList(state),
            ),
          ],
        ),
      ),
    );
  }

  Widget _empty() {
    final isBuilding = widget.index.isBuilding;
    final text = isBuilding
        ? S.quickOpenIndexing
        : (_input.text.trim().isEmpty
              ? S.unifiedSearchEmptyHint
              : S.unifiedSearchNoResults);
    return Padding(
      padding: const EdgeInsets.all(28),
      child: Text(
        text,
        style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 13),
      ),
    );
  }

  Widget _resultsList(AppState state) {
    // Build a flat slice of widgets where the first row of each
    // section is preceded by a section header. The selectable index
    // counter (`selectableIdx`) only advances on result rows so up/down
    // navigation stays sane.
    final children = <Widget>[];
    _ResultKind? lastKind;
    int selectableIdx = 0;
    for (int i = 0; i < _results.length; i++) {
      final r = _results[i];
      if (r.kind != lastKind) {
        children.add(_sectionHeader(r.kind));
        lastKind = r.kind;
      }
      final isSelected = selectableIdx == _selected;
      children.add(_row(r, isSelected, selectableIdx, state));
      selectableIdx++;
    }
    return ListView(
      controller: _scroll,
      padding: EdgeInsets.zero,
      children: children,
    );
  }

  Widget _sectionHeader(_ResultKind kind) {
    final label = switch (kind) {
      _ResultKind.command => S.unifiedSearchSectionCommands,
      _ResultKind.settings => S.unifiedSearchSectionSettings,
      _ResultKind.file => S.unifiedSearchSectionFiles,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 12, 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.0,
              color: DuckColors.fgSubtle,
            ),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Divider(
              height: 1,
              thickness: 0.5,
              color: DuckColors.glassSeam,
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(_Result r, bool selected, int selectableIdx, AppState state) {
    return _ResultRow(
      result: r,
      selected: selected,
      enabled: r.kind == _ResultKind.file
          ? true
          : (r.command?.isEnabled(state) ?? true),
      onTap: () {
        setState(() => _selected = selectableIdx);
        _activate();
      },
      onHover: () {
        if (selectableIdx == _selected) return;
        setState(() => _selected = selectableIdx);
      },
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

class _ScoredCommand {
  final IdeCommand cmd;
  final int score;
  const _ScoredCommand(this.cmd, this.score);
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
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: DuckColors.fgSubtle),
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

class _ResultRow extends StatelessWidget {
  final _Result result;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _ResultRow({
    required this.result,
    required this.selected,
    required this.enabled,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final fg = enabled ? DuckColors.fgPrimary : DuckColors.fgFaint;
    final iconColor = enabled ? DuckColors.fgMuted : DuckColors.fgFaint;
    return MouseRegion(
      onEnter: (_) => onHover(),
      child: InkWell(
        onTap: enabled ? onTap : null,
        child: Container(
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
          child: Row(
            children: [
              Icon(_iconFor(result), size: 14, color: iconColor),
              const SizedBox(width: 10),
              Expanded(child: _label(fg)),
              if (result.kind != _ResultKind.file &&
                  result.command?.shortcut != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: DuckColors.bgChip,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    border:
                        Border.all(color: DuckColors.glassSeam, width: 0.5),
                  ),
                  child: Text(
                    result.command!.shortcut!,
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

  IconData _iconFor(_Result r) {
    switch (r.kind) {
      case _ResultKind.command:
      case _ResultKind.settings:
        return r.command!.icon;
      case _ResultKind.file:
        return Icons.description;
    }
  }

  Widget _label(Color fg) {
    switch (result.kind) {
      case _ResultKind.command:
      case _ResultKind.settings:
        final cmd = result.command!;
        return Row(
          children: [
            if (cmd.category != null && result.kind == _ResultKind.command) ...[
              Text(
                '${cmd.category}: ',
                style: const TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ],
            Flexible(
              child: Text(
                cmd.title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: fg),
              ),
            ),
          ],
        );
      case _ResultKind.file:
        final f = result.file!;
        return Row(
          children: [
            Text(
              f.name,
              style: TextStyle(fontSize: 13, color: fg),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                f.relativePath,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
          ],
        );
    }
  }
}
