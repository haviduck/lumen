import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../services/model_capabilities.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../council/compact_model_label.dart';

/// Outcome of the popover. The caller resolves this into the right
/// action (pick, refresh, open the manage dialog, or no-op on cancel)
/// without each call site having to re-implement the matching logic.
sealed class ModelPickerResult {
  const ModelPickerResult();
}

/// User selected a model. [model] is the full provider-prefixed id
/// (e.g. `claude:claude-opus-4-7`); routing relies on the prefix.
class ModelPickerPicked extends ModelPickerResult {
  final String model;
  const ModelPickerPicked(this.model);
}

/// User asked for a fresh poll of every enabled provider (parity with
/// the old "Refresh models" menu entry).
class ModelPickerRefresh extends ModelPickerResult {
  const ModelPickerRefresh();
}

/// User asked to open the full Manage Models surface (the legacy
/// "View all models" entry — the side-by-side provider/model panel).
class ModelPickerManage extends ModelPickerResult {
  const ModelPickerManage();
}

/// User dismissed the popover without picking anything. Distinct from
/// `null` so callers can opt to no-op vs. trigger fallback behaviour.
class ModelPickerDismissed extends ModelPickerResult {
  const ModelPickerDismissed();
}

/// Anchor + render the inline model picker as an overlay attached to
/// [link]. The host wraps its trigger chip in a
/// [CompositedTransformTarget] paired with [link] and calls this
/// function on tap; the popover positions itself above the chip,
/// matching the IDE's "open upward" convention for composer chrome.
///
/// [enabledModels] is the user-curated subset surfaced by the picker
/// (i.e. `ChatController.pickerModels`). [allModels] is the broader
/// `availableModels` list — passed so the per-provider counts in the
/// filter chips can show "5/12" (enabled-vs-total) rather than just
/// the curated count.
///
/// Returns a non-null result describing what the user did.
Future<ModelPickerResult> showModelPickerPopover({
  required BuildContext context,
  required LayerLink link,
  required String selectedModel,
  required List<String> enabledModels,
  required List<String> allModels,
}) {
  final overlay = Overlay.of(context, rootOverlay: true);
  final completer = Completer<ModelPickerResult>();
  late OverlayEntry entry;
  entry = OverlayEntry(
    builder: (ctx) => _ModelPickerOverlay(
      link: link,
      selectedModel: selectedModel,
      enabledModels: enabledModels,
      allModels: allModels,
      onResult: (result) {
        if (!completer.isCompleted) completer.complete(result);
        entry.remove();
      },
    ),
  );
  overlay.insert(entry);
  return completer.future;
}

// ─────────────────────────────────────────────────────────────────────
//  Overlay
// ─────────────────────────────────────────────────────────────────────

class _ModelPickerOverlay extends StatefulWidget {
  final LayerLink link;
  final String selectedModel;
  final List<String> enabledModels;
  final List<String> allModels;
  final ValueChanged<ModelPickerResult> onResult;

  const _ModelPickerOverlay({
    required this.link,
    required this.selectedModel,
    required this.enabledModels,
    required this.allModels,
    required this.onResult,
  });

  @override
  State<_ModelPickerOverlay> createState() => _ModelPickerOverlayState();
}

class _ModelPickerOverlayState extends State<_ModelPickerOverlay>
    with SingleTickerProviderStateMixin {
  // Width tuned to fit the longest realistic compact label plus the
  // full provider:model id without ellipsis. Anything narrower
  // ellipsises the raw id on rows, which is the one piece of info the
  // user came to the menu to disambiguate.
  static const double _kWidth = 440;
  static const double _kMaxBodyHeight = 340;
  static const double _kFooterHeight = 38;

  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'ModelPickerSearch');
  final FocusNode _listFocus = FocusNode(debugLabel: 'ModelPickerList');
  final ScrollController _scroll = ScrollController();

  late final AnimationController _enter = AnimationController(
    vsync: this,
    duration: DuckMotion.fast,
  );

  String? _providerFilter; // null = All
  int _highlight = 0;
  // Cache the row-by-row flat list so keyboard navigation, scroll-into-
  // view, and tap handlers all agree on the same indexing.
  List<_PickerRow> _flatRows = const [];

  @override
  void initState() {
    super.initState();
    _enter.forward();
    _rebuildRows();
    final idx = _flatRows.indexWhere(
      (r) => r is _ModelEntry && r.model == widget.selectedModel,
    );
    // Fall back to the first model entry (skipping any leading
    // provider header) when the currently selected model isn't in
    // the enabled list — keeps the highlight on something actionable
    // so Enter immediately picks a real model.
    _highlight = idx >= 0 ? idx : _firstModelIndex();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _enter.dispose();
    _search.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  // ── Data plumbing ──────────────────────────────────────────────────

  String _providerOf(String fullId) {
    final i = fullId.indexOf(':');
    return i > 0 ? fullId.substring(0, i) : 'ollama';
  }

  /// Stable canonical ordering — same as Model Management's sidebar,
  /// so a user who memorised "Ollama is on top" in one surface gets
  /// the same in the other.
  static const _kProviderOrder = [
    'ollama',
    'ollama-cloud',
    'claude',
    'gemini',
    'copilot',
    'openai',
  ];

  int _providerSortKey(String p) {
    final i = _kProviderOrder.indexOf(p);
    return i == -1 ? 999 : i;
  }

  /// All providers that show up in the enabled-models list, in
  /// canonical order. Unknown providers (third-party plugin) sort
  /// last by alpha.
  List<String> get _providers {
    final set = <String>{for (final m in widget.enabledModels) _providerOf(m)};
    return set.toList()
      ..sort((a, b) {
        final ai = _providerSortKey(a);
        final bi = _providerSortKey(b);
        if (ai != bi) return ai.compareTo(bi);
        return a.compareTo(b);
      });
  }

  int _enabledCountFor(String provider) =>
      widget.enabledModels.where((m) => _providerOf(m) == provider).length;

  int _totalCountFor(String provider) =>
      widget.allModels.where((m) => _providerOf(m) == provider).length;

  List<String> _matches() {
    final q = _search.text.trim().toLowerCase();
    return widget.enabledModels.where((m) {
      if (_providerFilter != null && _providerOf(m) != _providerFilter) {
        return false;
      }
      if (q.isEmpty) return true;
      // Match on full id AND on the compact label so typing "opus"
      // finds `claude:claude-opus-4-7` even though the substring isn't
      // contiguous in the raw id.
      return m.toLowerCase().contains(q) ||
          compactModelLabel(m).toLowerCase().contains(q);
    }).toList()
      ..sort((a, b) {
        final pa = _providerSortKey(_providerOf(a));
        final pb = _providerSortKey(_providerOf(b));
        if (pa != pb) return pa.compareTo(pb);
        return compactModelLabel(a).compareTo(compactModelLabel(b));
      });
  }

  void _rebuildRows() {
    final matches = _matches();
    final searching = _search.text.trim().isNotEmpty;
    // Flat search results — single ungrouped list so the keyboard
    // ↑↓ flow doesn't skip over invisible "section heads".
    if (searching || _providerFilter != null) {
      _flatRows = [for (final m in matches) _ModelEntry(m)];
      return;
    }
    // Group by provider with header rows. Keyboard nav still works
    // because we mark headers with `_HeaderRow` and `_advanceHighlight`
    // skips them.
    final rows = <_PickerRow>[];
    String? current;
    for (final m in matches) {
      final p = _providerOf(m);
      if (p != current) {
        rows.add(_HeaderRow(p, _enabledCountFor(p), _totalCountFor(p)));
        current = p;
      }
      rows.add(_ModelEntry(m));
    }
    _flatRows = rows;
  }

  void _onSearchChanged(String _) {
    setState(() {
      _rebuildRows();
      _highlight = _firstModelIndex();
    });
  }

  int _firstModelIndex() {
    for (var i = 0; i < _flatRows.length; i++) {
      if (_flatRows[i] is _ModelEntry) return i;
    }
    return 0;
  }

  void _advanceHighlight(int delta) {
    if (_flatRows.isEmpty) return;
    var i = _highlight;
    for (var step = 0; step < _flatRows.length; step++) {
      i = (i + delta).clamp(0, _flatRows.length - 1);
      if (_flatRows[i] is _ModelEntry) {
        setState(() => _highlight = i);
        _ensureVisible(i);
        return;
      }
      if (i == 0 && delta < 0) break;
      if (i == _flatRows.length - 1 && delta > 0) break;
    }
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    // Approximation: header ~22px, model row ~38px. Good enough to
    // keep the highlight in view without measuring every row.
    var offset = 0.0;
    for (var i = 0; i < index; i++) {
      offset += _flatRows[i] is _HeaderRow ? 26.0 : 40.0;
    }
    const viewportPadding = 60.0;
    final viewport = _scroll.position.viewportDimension;
    final maxScroll = _scroll.position.maxScrollExtent;
    if (offset < _scroll.offset + viewportPadding) {
      _scroll.animateTo(
        (offset - viewportPadding).clamp(0.0, maxScroll),
        duration: DuckMotion.instant,
        curve: DuckMotion.standard,
      );
    } else if (offset > _scroll.offset + viewport - viewportPadding) {
      _scroll.animateTo(
        (offset - viewport + viewportPadding + 40).clamp(0.0, maxScroll),
        duration: DuckMotion.instant,
        curve: DuckMotion.standard,
      );
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent) return KeyEventResult.ignored;
    final k = ev.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      widget.onResult(const ModelPickerDismissed());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _advanceHighlight(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _advanceHighlight(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageDown) {
      _advanceHighlight(5);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp) {
      _advanceHighlight(-5);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      final row = _highlight < _flatRows.length ? _flatRows[_highlight] : null;
      if (row is _ModelEntry) {
        widget.onResult(ModelPickerPicked(row.model));
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _pickProvider(String? p) {
    setState(() {
      _providerFilter = p;
      _rebuildRows();
      _highlight = _firstModelIndex();
    });
  }

  @override
  Widget build(BuildContext context) {
    final providers = _providers;
    final totalEnabled = widget.enabledModels.length;
    final visible = _flatRows.whereType<_ModelEntry>().length;
    final searching = _search.text.trim().isNotEmpty;

    return AnimatedBuilder(
      animation: _enter,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_enter.value);
        return Stack(
          children: [
            // Scrim — opaque so outside taps dismiss without leaking
            // through to whatever sits beneath. Important: with
            // `translucent`, a tap on the picker chip itself would
            // both dismiss the popover AND re-fire the chip's onTap
            // (reopening it), producing a frame-flicker. Opaque
            // absorbs the gesture; the user's next click triggers
            // whatever they meant to click.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => widget.onResult(const ModelPickerDismissed()),
              ),
            ),
            Positioned(
              width: _kWidth,
              child: CompositedTransformFollower(
                link: widget.link,
                showWhenUnlinked: false,
                // Open upward — composer chip lives at the bottom of
                // the chat panel; popping above keeps it from being
                // clipped by the panel's lower edge. The 8px gap
                // mirrors the wizard's anchor offset.
                targetAnchor: Alignment.topLeft,
                followerAnchor: Alignment.bottomLeft,
                offset: const Offset(0, -8),
                child: Opacity(
                  opacity: t,
                  child: Transform.translate(
                    offset: Offset(0, (1 - t) * 6),
                    child: child,
                  ),
                ),
              ),
            ),
          ],
        );
      },
      child: _Surface(
        // Glassy raised panel; matches the agent quick picker's
        // shadow stack so the two pickers feel like siblings.
        child: Focus(
          autofocus: false,
          onKeyEvent: _onKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(
                totalEnabled: totalEnabled,
                searching: searching,
                visible: visible,
                onManage: () => widget.onResult(const ModelPickerManage()),
                onRefresh: () => widget.onResult(const ModelPickerRefresh()),
              ),
              _SearchField(
                controller: _search,
                focusNode: _searchFocus,
                onChanged: _onSearchChanged,
                onSubmit: () {
                  final row = _highlight < _flatRows.length
                      ? _flatRows[_highlight]
                      : null;
                  if (row is _ModelEntry) {
                    widget.onResult(ModelPickerPicked(row.model));
                  }
                },
                onEscape: () =>
                    widget.onResult(const ModelPickerDismissed()),
              ),
              if (providers.length > 1)
                _ProviderChipBar(
                  providers: providers,
                  selected: _providerFilter,
                  totalEnabled: totalEnabled,
                  enabledCountFor: _enabledCountFor,
                  totalCountFor: _totalCountFor,
                  onPick: _pickProvider,
                ),
              Focus(
                focusNode: _listFocus,
                child: _Body(
                  rows: _flatRows,
                  highlight: _highlight,
                  selected: widget.selectedModel,
                  scroll: _scroll,
                  maxHeight: _kMaxBodyHeight,
                  onPick: (m) => widget.onResult(ModelPickerPicked(m)),
                  onHover: (i) => setState(() => _highlight = i),
                ),
              ),
              const SizedBox(
                height: _kFooterHeight,
                child: _Footer(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Row types — header (provider eyebrow) or model entry
// ─────────────────────────────────────────────────────────────────────

sealed class _PickerRow {
  const _PickerRow();
}

class _HeaderRow extends _PickerRow {
  final String provider;
  final int enabled;
  final int total;
  const _HeaderRow(this.provider, this.enabled, this.total);
}

class _ModelEntry extends _PickerRow {
  final String model;
  const _ModelEntry(this.model);
}

// ─────────────────────────────────────────────────────────────────────
//  Surface — the popover background card
// ─────────────────────────────────────────────────────────────────────

class _Surface extends StatelessWidget {
  final Widget child;
  const _Surface({required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(color: DuckColors.border, width: 0.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 32,
              offset: const Offset(0, 16),
            ),
            BoxShadow(
              color: DuckColors.accentCyan.withValues(alpha: 0.08),
              blurRadius: 36,
              spreadRadius: -10,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: child,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Header (title + count + manage/refresh inline actions)
// ─────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final int totalEnabled;
  final int visible;
  final bool searching;
  final VoidCallback onManage;
  final VoidCallback onRefresh;
  const _Header({
    required this.totalEnabled,
    required this.visible,
    required this.searching,
    required this.onManage,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final countLabel = searching
        ? '$visible / $totalEnabled'
        : S.chatModelCountLabel(totalEnabled);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.auto_awesome,
            size: 13,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 8),
          const Text(
            S.chatModelPopoverTitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: DuckColors.bgDeeper,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Text(
              countLabel,
              style: const TextStyle(
                fontSize: 10,
                color: DuckColors.fgMuted,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          const Spacer(),
          _HeaderIconAction(
            icon: Icons.refresh,
            tooltip: S.chatModelRefresh,
            onTap: onRefresh,
          ),
          const SizedBox(width: 2),
          _HeaderIconAction(
            icon: Icons.tune,
            tooltip: S.chatModelManageAll,
            onTap: onManage,
          ),
        ],
      ),
    );
  }
}

class _HeaderIconAction extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderIconAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_HeaderIconAction> createState() => _HeaderIconActionState();
}

class _HeaderIconActionState extends State<_HeaderIconAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DuckMotion.instant,
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hover ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Search field
// ─────────────────────────────────────────────────────────────────────

class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;
  final VoidCallback onEscape;
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.onChanged,
    required this.onSubmit,
    required this.onEscape,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 10, 8),
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final hasText = value.text.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              color: DuckColors.bgDeeper,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Row(
              children: [
                const SizedBox(width: 10),
                const Icon(
                  Icons.search,
                  size: 13,
                  color: DuckColors.fgMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    onChanged: onChanged,
                    onSubmitted: (_) => onSubmit(),
                    cursorColor: DuckColors.accentCyan,
                    cursorWidth: 1.0,
                    cursorHeight: 14,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DuckColors.fgPrimary,
                    ),
                    decoration: const InputDecoration(
                      hintText: S.chatModelSearchHint,
                      hintStyle: TextStyle(
                        fontSize: 12.5,
                        color: DuckColors.fgSubtle,
                      ),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                if (hasText)
                  Tooltip(
                    message: S.chatModelClearSearch,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        controller.clear();
                        onChanged('');
                        focusNode.requestFocus();
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Icon(
                          Icons.close,
                          size: 12,
                          color: DuckColors.fgMuted,
                        ),
                      ),
                    ),
                  ),
                const SizedBox(width: 4),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Provider filter chip bar (horizontal scroll)
// ─────────────────────────────────────────────────────────────────────

class _ProviderChipBar extends StatelessWidget {
  final List<String> providers;
  final String? selected;
  final int totalEnabled;
  final int Function(String) enabledCountFor;
  final int Function(String) totalCountFor;
  final ValueChanged<String?> onPick;
  const _ProviderChipBar({
    required this.providers,
    required this.selected,
    required this.totalEnabled,
    required this.enabledCountFor,
    required this.totalCountFor,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 30,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
        children: [
          _Chip(
            label: S.chatModelFilterAll,
            count: totalEnabled,
            color: DuckColors.accentCyan,
            active: selected == null,
            onTap: () => onPick(null),
            isAll: true,
          ),
          for (final p in providers) ...[
            const SizedBox(width: 6),
            _Chip(
              label: _prettyProviderName(p),
              count: enabledCountFor(p),
              total: totalCountFor(p),
              color: _providerAccent(p),
              active: selected == p,
              onTap: () => onPick(p),
            ),
          ],
        ],
      ),
    );
  }
}

class _Chip extends StatefulWidget {
  final String label;
  final int count;
  final int? total;
  final Color color;
  final bool active;
  final bool isAll;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.count,
    this.total,
    required this.color,
    required this.active,
    required this.onTap,
    this.isAll = false,
  });

  @override
  State<_Chip> createState() => _ChipState();
}

class _ChipState extends State<_Chip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.active;
    final color = widget.color;
    final bg = active
        ? color.withValues(alpha: 0.16)
        : _hover
            ? DuckColors.bgRaisedHi
            : DuckColors.bgDeeper;
    final border = active
        ? color.withValues(alpha: 0.55)
        : DuckColors.glassSeam;
    final fg = active ? DuckColors.fgPrimary : DuckColors.fgMuted;
    final countLabel = widget.total == null || widget.isAll
        ? '${widget.count}'
        : '${widget.count}/${widget.total}';
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DuckMotion.instant,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: border, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!widget.isAll) ...[
                Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: color,
                  ),
                ),
                const SizedBox(width: 7),
              ] else ...[
                Icon(
                  Icons.dashboard_outlined,
                  size: 11,
                  color: active ? color : fg,
                ),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  color: fg,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: DuckColors.bgDeepest.withValues(alpha: 0.7),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  countLabel,
                  style: const TextStyle(
                    fontSize: 9.5,
                    color: DuckColors.fgSubtle,
                    fontFeatures: [FontFeature.tabularFigures()],
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

// ─────────────────────────────────────────────────────────────────────
//  Body — list of provider-grouped (or flat) rows
// ─────────────────────────────────────────────────────────────────────

class _Body extends StatelessWidget {
  final List<_PickerRow> rows;
  final int highlight;
  final String selected;
  final ScrollController scroll;
  final double maxHeight;
  final ValueChanged<String> onPick;
  final ValueChanged<int> onHover;
  const _Body({
    required this.rows,
    required this.highlight,
    required this.selected,
    required this.scroll,
    required this.maxHeight,
    required this.onPick,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight, minHeight: 120),
        child: const _EmptyState(),
      );
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: Scrollbar(
        controller: scroll,
        thumbVisibility: false,
        child: ListView.builder(
          controller: scroll,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: rows.length,
          itemBuilder: (context, i) {
            final row = rows[i];
            if (row is _HeaderRow) {
              return _ProviderHeader(
                provider: row.provider,
                enabled: row.enabled,
                total: row.total,
              );
            }
            row as _ModelEntry;
            final highlighted = i == highlight;
            return _ModelTile(
              model: row.model,
              selected: row.model == selected,
              highlighted: highlighted,
              onTap: () => onPick(row.model),
              onHover: (h) {
                if (h) onHover(i);
              },
            );
          },
        ),
      ),
    );
  }
}

class _ProviderHeader extends StatelessWidget {
  final String provider;
  final int enabled;
  final int total;
  const _ProviderHeader({
    required this.provider,
    required this.enabled,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    final color = _providerAccent(provider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 4),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _prettyProviderName(provider).toUpperCase(),
            style: const TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
              color: DuckColors.fgSubtle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Container(
              height: 0.5,
              color: DuckColors.glassSeam,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$enabled/$total',
            style: const TextStyle(
              fontSize: 9.5,
              color: DuckColors.fgSubtle,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final String model;
  final bool selected;
  final bool highlighted;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;
  const _ModelTile({
    required this.model,
    required this.selected,
    required this.highlighted,
    required this.onTap,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final provider = _providerOf(model);
    final raw = _rawModelName(model);
    final color = _providerAccent(provider);
    final compact = compactModelLabel(model);
    final hasVision = ModelCapabilities.supportsVision(
      provider: provider,
      rawModel: raw,
    );

    final bg = highlighted
        ? color.withValues(alpha: 0.10)
        : Colors.transparent;
    final showSelectedHairline = selected;

    return MouseRegion(
      onEnter: (_) => onHover(true),
      onExit: (_) => onHover(false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: DuckMotion.instant,
          margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: showSelectedHairline
                ? Border.all(
                    color: color.withValues(alpha: 0.55),
                    width: 0.6,
                  )
                : null,
          ),
          child: Row(
            children: [
              _ProviderBadge(provider: provider, color: color),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            compact,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: selected
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              color: DuckColors.fgPrimary,
                            ),
                          ),
                        ),
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.check_circle,
                            size: 12,
                            color: color,
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      raw,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: const TextStyle(
                        fontSize: 10.5,
                        color: DuckColors.fgSubtle,
                        fontFamily: DuckTheme.monoFont,
                      ),
                    ),
                  ],
                ),
              ),
              if (hasVision) ...[
                const SizedBox(width: 8),
                _CapabilityTag(
                  icon: Icons.image_outlined,
                  label: S.chatModelCapabilityVision,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderBadge extends StatelessWidget {
  final String provider;
  final Color color;
  const _ProviderBadge({required this.provider, required this.color});

  @override
  Widget build(BuildContext context) {
    final initial = _providerInitial(provider);
    return Container(
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.6),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
          height: 1.0,
        ),
      ),
    );
  }
}

class _CapabilityTag extends StatelessWidget {
  final IconData icon;
  final String label;
  const _CapabilityTag({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: label,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
        decoration: BoxDecoration(
          color: DuckColors.bgDeepest.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        ),
        child: Icon(icon, size: 11, color: DuckColors.fgMuted),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Empty state — shown when search yields zero results
// ─────────────────────────────────────────────────────────────────────

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: DuckColors.bgDeeper,
                shape: BoxShape.circle,
                border: Border.all(color: DuckColors.glassSeam, width: 0.5),
              ),
              alignment: Alignment.center,
              child: const Icon(
                Icons.search_off,
                size: 16,
                color: DuckColors.fgMuted,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              S.chatModelNoMatches,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
            ),
            const SizedBox(height: 2),
            const Text(
              S.chatModelNoMatchesHint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11, color: DuckColors.fgMuted),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Footer — keyboard hint
// ─────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeepest,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: const [
          Icon(Icons.keyboard_outlined, size: 11, color: DuckColors.fgSubtle),
          SizedBox(width: 6),
          Expanded(
            child: Text(
              S.chatModelKeyboardHint,
              style: TextStyle(fontSize: 10, color: DuckColors.fgSubtle),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  Provider visual identity helpers
// ─────────────────────────────────────────────────────────────────────

/// Provider id → display name. Falls back to the raw id so unknown
/// vendors (e.g. user-installed via a plugin) still render readably.
String _prettyProviderName(String p) {
  return switch (p) {
    'ollama' => S.providerOllama,
    'ollama-cloud' => S.providerOllamaCloud,
    'gemini' => S.providerGemini,
    'claude' => S.providerClaude,
    'copilot' => S.providerCopilot,
    'openai' => S.providerOpenAI,
    _ => p,
  };
}

/// Provider id → single uppercase letter for the corner badge.
/// `ollama-cloud` collapses to `O` (same family as local Ollama)
/// because the popover already distinguishes them via the provider
/// chip-bar above.
String _providerInitial(String p) {
  return switch (p) {
    'ollama' => 'O',
    'ollama-cloud' => 'O',
    'claude' => 'C',
    'gemini' => 'G',
    'copilot' => 'gh',
    'openai' => 'AI',
    _ => p.isEmpty ? '?' : p.substring(0, 1).toUpperCase(),
  };
}

/// Provider id → accent colour for the badge / filter chip / row
/// highlight. Tokens chosen from the Nord-derived chrome family so
/// the popover doesn't introduce a brand-new palette.
///
///  - `ollama`/`ollama-cloud`  → soft purple (Nord 15)
///  - `claude`                 → warm gold (Nord 13) — Anthropic's
///                               own brand tone reads as warm
///  - `gemini`                 → frost blue (Nord 10)
///  - `copilot`                → frost teal (Nord 7)
///  - `openai`                 → frost green (Nord 14)
Color _providerAccent(String p) {
  return switch (p) {
    'ollama' => DuckColors.accentPurple,
    'ollama-cloud' => DuckColors.accentPurple,
    'claude' => DuckColors.accentDuck,
    'gemini' => DuckColors.stateInfo,
    'copilot' => DuckColors.accentMint,
    'openai' => DuckColors.stateOk,
    _ => DuckColors.accentCyan,
  };
}

String _providerOf(String fullId) {
  final i = fullId.indexOf(':');
  return i > 0 ? fullId.substring(0, i) : 'ollama';
}

String _rawModelName(String fullId) {
  final i = fullId.indexOf(':');
  return i > 0 ? fullId.substring(i + 1) : fullId;
}
