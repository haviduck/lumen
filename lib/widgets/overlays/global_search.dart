import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/file_index.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Search across every text file in the workspace. Uses [FileIndex] for
/// the file list and [TextSearch] for matching. Results are streamed in so
/// the user sees the first matches before the whole repo is scanned.
class GlobalSearch extends StatefulWidget {
  final FileIndex index;
  final VoidCallback onClose;
  const GlobalSearch({super.key, required this.index, required this.onClose});

  @override
  State<GlobalSearch> createState() => _GlobalSearchState();
}

class _FileGroup {
  final String absolutePath;
  final String relativePath;
  final List<TextMatch> matches = [];
  _FileGroup(this.absolutePath, this.relativePath);
}

class _GlobalSearchState extends State<GlobalSearch> {
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();
  final ScrollController _scroll = ScrollController();
  bool _caseSensitive = false;
  bool _isRegex = false;

  Timer? _debounce;
  StreamSubscription<TextMatch>? _running;
  final Map<String, _FileGroup> _groups = {};
  final List<TextMatch> _flatList = [];
  int _selected = 0;
  int _matchCount = 0;
  int _fileCount = 0;
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(_onQueryChanged);
    if (widget.index.isBuilding) {
      widget.index.build().then((_) {
        if (mounted && _input.text.isNotEmpty) _kick();
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _running?.cancel();
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 200), _kick);
  }

  void _kick() {
    _running?.cancel();
    setState(() {
      _groups.clear();
      _flatList.clear();
      _matchCount = 0;
      _fileCount = 0;
      _selected = 0;
    });
    final q = _input.text;
    if (q.isEmpty) {
      setState(() => _searching = false);
      return;
    }
    if (!widget.index.isReady) return;
    setState(() => _searching = true);
    final search = TextSearch(widget.index);
    final stream = search.search(
      q,
      caseSensitive: _caseSensitive,
      isRegex: _isRegex,
    );
    _running = stream.listen(
      (m) {
        final group = _groups.putIfAbsent(
          m.absolutePath,
          () {
            _fileCount++;
            return _FileGroup(m.absolutePath, m.relativePath);
          },
        );
        group.matches.add(m);
        _flatList.add(m);
        _matchCount++;
        if (mounted) setState(() {});
      },
      onDone: () {
        if (mounted) setState(() => _searching = false);
      },
      onError: (_) {
        if (mounted) setState(() => _searching = false);
      },
    );
  }

  void _move(int delta) {
    if (_flatList.isEmpty) return;
    setState(() => _selected = (_selected + delta).clamp(0, _flatList.length - 1));
  }

  void _activate() {
    if (_flatList.isEmpty) return;
    final m = _flatList[_selected];
    widget.onClose();
    Future.microtask(() async {
      if (!mounted) return;
      await context.read<AppState>().openFile(File(m.absolutePath));
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
            _SearchBar(
              controller: _input,
              focusNode: _focus,
              caseSensitive: _caseSensitive,
              isRegex: _isRegex,
              onToggleCase: () {
                setState(() => _caseSensitive = !_caseSensitive);
                _kick();
              },
              onToggleRegex: () {
                setState(() => _isRegex = !_isRegex);
                _kick();
              },
            ),
            _SummaryBar(
              matches: _matchCount,
              files: _fileCount,
              searching: _searching,
            ),
            Flexible(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_input.text.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          S.globalSearchHint,
          style: TextStyle(color: DuckColors.fgSubtle, fontSize: 13),
        ),
      );
    }
    if (_flatList.isEmpty && !_searching) {
      return const Padding(
        padding: EdgeInsets.all(28),
        child: Text(
          S.globalSearchNoResults,
          style: TextStyle(color: DuckColors.fgSubtle, fontSize: 13),
        ),
      );
    }
    int runningIndex = 0;
    final List<Widget> children = [];
    for (final group in _groups.values) {
      children.add(_FileHeader(group: group));
      for (final m in group.matches) {
        final idx = runningIndex;
        children.add(MouseRegion(
          onEnter: (_) {
            if (idx != _selected) setState(() => _selected = idx);
          },
          child: InkWell(
            onTap: () {
              setState(() => _selected = idx);
              _activate();
            },
            child: _MatchRow(match: m, selected: idx == _selected),
          ),
        ));
        runningIndex++;
      }
    }
    return ListView(
      controller: _scroll,
      padding: EdgeInsets.zero,
      children: children,
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

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool caseSensitive;
  final bool isRegex;
  final VoidCallback onToggleCase;
  final VoidCallback onToggleRegex;

  const _SearchBar({
    required this.controller,
    required this.focusNode,
    required this.caseSensitive,
    required this.isRegex,
    required this.onToggleCase,
    required this.onToggleRegex,
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
          const Icon(Icons.travel_explore, size: 16, color: DuckColors.accentCyan),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: S.globalSearchHint,
                isDense: true,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: EdgeInsets.symmetric(vertical: 8),
                hintStyle: TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 14,
                ),
              ),
              style: const TextStyle(color: DuckColors.fgPrimary, fontSize: 14),
            ),
          ),
          _ToggleChip(
            label: 'Aa',
            active: caseSensitive,
            tooltip: 'Match case',
            onTap: onToggleCase,
          ),
          const SizedBox(width: 6),
          _ToggleChip(
            label: '.*',
            active: isRegex,
            tooltip: 'Regular expression',
            onTap: onToggleRegex,
          ),
        ],
      ),
    );
  }
}

class _ToggleChip extends StatelessWidget {
  final String label;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;
  const _ToggleChip({
    required this.label,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: active ? DuckColors.accentPurple.withValues(alpha: 0.18) : DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: active ? DuckColors.accentPurple : DuckColors.glassSeam,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontFamily: DuckTheme.monoFont,
              color: active ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _SummaryBar extends StatelessWidget {
  final int matches;
  final int files;
  final bool searching;
  const _SummaryBar({
    required this.matches,
    required this.files,
    required this.searching,
  });

  @override
  Widget build(BuildContext context) {
    if (matches == 0 && !searching) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: const BoxDecoration(
        color: Color(0x33000000),
        border: Border(bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5)),
      ),
      child: Row(
        children: [
          if (searching)
            const SizedBox(
              width: 11,
              height: 11,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
          if (searching) const SizedBox(width: 8),
          Text(
            '$matches ${S.globalSearchMatches} ${S.globalSearchInFiles} $files ${S.globalSearchFiles}',
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

class _FileHeader extends StatelessWidget {
  final _FileGroup group;
  const _FileHeader({required this.group});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.description, size: 13, color: DuckColors.fileIcon),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              group.relativePath,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgMuted,
              ),
            ),
          ),
          Text(
            '${group.matches.length}',
            style: const TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
          ),
        ],
      ),
    );
  }
}

class _MatchRow extends StatelessWidget {
  final TextMatch match;
  final bool selected;
  const _MatchRow({required this.match, required this.selected});

  @override
  Widget build(BuildContext context) {
    final line = match.lineContent;
    final pre = line.substring(0, match.matchStart);
    final hit = line.substring(match.matchStart, match.matchEnd);
    final post = line.substring(match.matchEnd);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 4),
      color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 38,
            child: Text(
              '${match.lineNumber}',
              style: const TextStyle(
                fontSize: 11,
                fontFamily: DuckTheme.monoFont,
                color: DuckColors.fgFaint,
              ),
            ),
          ),
          Expanded(
            child: RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              text: TextSpan(
                style: const TextStyle(
                  fontSize: 12,
                  fontFamily: DuckTheme.monoFont,
                  color: DuckColors.fgPrimary,
                ),
                children: [
                  TextSpan(text: pre),
                  TextSpan(
                    text: hit,
                    style: const TextStyle(
                      backgroundColor: DuckColors.editorSelection,
                      color: DuckColors.fgPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  TextSpan(text: post),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
