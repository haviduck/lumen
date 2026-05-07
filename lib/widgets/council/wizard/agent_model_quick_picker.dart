import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../compact_model_label.dart';
import 'model_tier.dart';
import 'wizard_tokens.dart';

/// Per-agent model quick picker. Built to slot into [WizardAgentCard]'s
/// model slot at [WizardTokens.agentCardModelSlotHeight] (36 logical px),
/// matching the visual language of `_FallbackModelPicker` in
/// `wizard_agent_card.dart` (icons.memory glyph + "MODEL" eyebrow + thin
/// separator + compact label + caret) so agent_0's seam is invisible.
///
/// What this adds over the fallback popup-menu:
///   • A real focus ring (accent-coloured) so keyboard users see where
///     they are while Tab-cycling between agents.
///   • Direct ↑/↓ cycling on the chip itself — no popover needed for
///     the common 2–4 model case.
///   • Searchable popover (autofocus search) that opens only when the
///     model list is wider than 6 entries OR the user explicitly hits
///     Enter/Space.
///   • An override dot: when [activePresetTier] is set and this row's
///     tier diverges, the dot fills accent — visual feedback that the
///     row is "off-preset".
///   • Inline "Apply to all agents" action inside the popover so a
///     power user can pin a single row's choice across the roster
///     without leaving the keyboard.
class AgentModelQuickPicker extends StatefulWidget {
  final String? value;
  final List<String> models;
  final ValueChanged<String> onChanged;
  final VoidCallback? onApplyToAll;
  final ModelTier? activePresetTier;
  final FocusNode? focusNode;
  final Color? accent;
  final String? semanticsLabel;

  const AgentModelQuickPicker({
    super.key,
    required this.value,
    required this.models,
    required this.onChanged,
    this.onApplyToAll,
    this.activePresetTier,
    this.focusNode,
    this.accent,
    this.semanticsLabel,
  });

  @override
  State<AgentModelQuickPicker> createState() => _AgentModelQuickPickerState();
}

class _AgentModelQuickPickerState extends State<AgentModelQuickPicker> {
  late final FocusNode _focus =
      widget.focusNode ?? FocusNode(debugLabel: 'AgentModelChip');
  final LayerLink _link = LayerLink();
  OverlayEntry? _overlay;

  @override
  void dispose() {
    _hidePopover();
    if (widget.focusNode == null) _focus.dispose();
    super.dispose();
  }

  void _cycle(int delta) {
    if (widget.models.isEmpty) return;
    final i = widget.models.indexOf(widget.value ?? '');
    final base = i < 0 ? 0 : i;
    final next = (base + delta) % widget.models.length;
    final wrapped = next < 0 ? next + widget.models.length : next;
    widget.onChanged(widget.models[wrapped]);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _cycle(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _cycle(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.space) {
      _togglePopover();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape && _overlay != null) {
      _hidePopover();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _togglePopover() {
    if (_overlay == null) {
      _showPopover();
    } else {
      _hidePopover();
    }
  }

  void _showPopover() {
    final overlayState = Overlay.of(context, rootOverlay: true);
    final accent = widget.accent ?? DuckColors.accentCyan;
    _overlay = OverlayEntry(
      builder: (_) => _PickerPopover(
        link: _link,
        models: widget.models,
        value: widget.value,
        accent: accent,
        onPick: (m) {
          widget.onChanged(m);
          _hidePopover();
          _focus.requestFocus();
        },
        onApplyToAll: widget.onApplyToAll == null
            ? null
            : () {
                widget.onApplyToAll!();
                _hidePopover();
                _focus.requestFocus();
              },
        onDismiss: () {
          _hidePopover();
          _focus.requestFocus();
        },
      ),
    );
    overlayState.insert(_overlay!);
    setState(() {});
  }

  void _hidePopover() {
    _overlay?.remove();
    _overlay = null;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final v = widget.value;
    final accent = widget.accent ?? DuckColors.accentCyan;
    final overridden = widget.activePresetTier != null &&
        v != null &&
        v.isNotEmpty &&
        modelTier(v) != widget.activePresetTier;

    return CompositedTransformTarget(
      link: _link,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: Builder(
          builder: (context) {
            final hasFocus = Focus.of(context).hasFocus;
            return Semantics(
              button: true,
              label: widget.semanticsLabel ?? 'Model',
              value: compactModelLabel(v ?? ''),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(WizardTokens.radiusS),
                  onTap: () {
                    _focus.requestFocus();
                    _togglePopover();
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 120),
                    height: WizardTokens.agentCardModelSlotHeight,
                    padding: const EdgeInsets.symmetric(
                      horizontal: WizardTokens.s10,
                      vertical: WizardTokens.s8,
                    ),
                    decoration: BoxDecoration(
                      color: DuckColors.bgDeeper,
                      borderRadius: BorderRadius.circular(WizardTokens.radiusS),
                      border: Border.all(
                        color: hasFocus
                            ? accent.withValues(alpha: 0.75)
                            : DuckColors.border,
                        width: hasFocus ? 1.0 : 0.6,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.memory, size: 12, color: accent),
                        const SizedBox(width: 6),
                        Text(
                          'MODEL',
                          style: WizardTokens.eyebrow.copyWith(
                            color: DuckColors.fgSubtle,
                            fontSize: 9,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 1,
                          height: 10,
                          color: DuckColors.glassSeam,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            compactModelLabel(v ?? ''),
                            overflow: TextOverflow.ellipsis,
                            style: WizardTokens.pillLabel.copyWith(
                              color: DuckColors.fgPrimary,
                              fontSize: 11.5,
                            ),
                          ),
                        ),
                        if (overridden)
                          Tooltip(
                            message: 'Overridden vs council preset',
                            child: Container(
                              width: 6,
                              height: 6,
                              margin: const EdgeInsets.only(right: 6),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: accent,
                              ),
                            ),
                          ),
                        Icon(
                          _overlay == null
                              ? Icons.expand_more
                              : Icons.expand_less,
                          size: 14,
                          color: DuckColors.fgMuted,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _PickerPopover extends StatefulWidget {
  final LayerLink link;
  final List<String> models;
  final String? value;
  final Color accent;
  final ValueChanged<String> onPick;
  final VoidCallback? onApplyToAll;
  final VoidCallback onDismiss;

  const _PickerPopover({
    required this.link,
    required this.models,
    required this.value,
    required this.accent,
    required this.onPick,
    required this.onApplyToAll,
    required this.onDismiss,
  });

  @override
  State<_PickerPopover> createState() => _PickerPopoverState();
}

class _PickerPopoverState extends State<_PickerPopover> {
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode(debugLabel: 'PickerSearch');
  final FocusNode _listFocus = FocusNode(debugLabel: 'PickerList');
  int _highlight = 0;

  bool get _showSearch => widget.models.length > 6;

  @override
  void initState() {
    super.initState();
    final initial = widget.models.indexOf(widget.value ?? '');
    if (initial >= 0) _highlight = initial;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_showSearch) {
        _searchFocus.requestFocus();
      } else {
        _listFocus.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _listFocus.dispose();
    super.dispose();
  }

  List<String> get _filtered {
    final q = _search.text.trim().toLowerCase();
    if (q.isEmpty) return widget.models;
    return widget.models.where((m) {
      return m.toLowerCase().contains(q) ||
          compactModelLabel(m).toLowerCase().contains(q);
    }).toList();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent) return KeyEventResult.ignored;
    final list = _filtered;
    if (ev.logicalKey == LogicalKeyboardKey.escape) {
      widget.onDismiss();
      return KeyEventResult.handled;
    }
    if (list.isEmpty) return KeyEventResult.ignored;
    if (ev.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() => _highlight = (_highlight + 1).clamp(0, list.length - 1));
      return KeyEventResult.handled;
    }
    if (ev.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() => _highlight = (_highlight - 1).clamp(0, list.length - 1));
      return KeyEventResult.handled;
    }
    if (ev.logicalKey == LogicalKeyboardKey.enter ||
        ev.logicalKey == LogicalKeyboardKey.numpadEnter) {
      widget.onPick(list[_highlight.clamp(0, list.length - 1)]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final list = _filtered;
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: widget.onDismiss,
          ),
        ),
        Positioned(
          width: 320,
          child: CompositedTransformFollower(
            link: widget.link,
            showWhenUnlinked: false,
            offset: const Offset(0, WizardTokens.agentCardModelSlotHeight + 4),
            child: Material(
              color: Colors.transparent,
              child: Focus(
                onKeyEvent: _onKey,
                child: Container(
                  decoration: BoxDecoration(
                    color: DuckColors.bgRaisedHi,
                    borderRadius:
                        BorderRadius.circular(WizardTokens.radiusM),
                    border: Border.all(color: DuckColors.glassSeam),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 28,
                        offset: const Offset(0, 14),
                      ),
                      BoxShadow(
                        color: widget.accent.withValues(alpha: 0.10),
                        blurRadius: 32,
                        spreadRadius: -8,
                      ),
                    ],
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_showSearch)
                        Padding(
                          padding: const EdgeInsets.all(WizardTokens.s8),
                          child: TextField(
                            controller: _search,
                            focusNode: _searchFocus,
                            style: const TextStyle(
                              color: DuckColors.fgPrimary,
                              fontSize: 13,
                            ),
                            cursorColor: widget.accent,
                            decoration: InputDecoration(
                              isDense: true,
                              hintText: 'Search models',
                              hintStyle: const TextStyle(
                                color: DuckColors.fgSubtle,
                                fontSize: 13,
                              ),
                              prefixIcon: Icon(
                                Icons.search,
                                size: 16,
                                color: widget.accent.withValues(alpha: 0.8),
                              ),
                              prefixIconConstraints: const BoxConstraints(
                                minWidth: 32,
                                minHeight: 16,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                vertical: 8,
                              ),
                              filled: true,
                              fillColor: DuckColors.bgDeeper,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  WizardTokens.radiusS,
                                ),
                                borderSide: const BorderSide(
                                  color: DuckColors.border,
                                ),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  WizardTokens.radiusS,
                                ),
                                borderSide: const BorderSide(
                                  color: DuckColors.border,
                                ),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(
                                  WizardTokens.radiusS,
                                ),
                                borderSide: BorderSide(
                                  color: widget.accent.withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            onChanged: (_) => setState(() => _highlight = 0),
                          ),
                        ),
                      Focus(
                        focusNode: _listFocus,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 280),
                          child: list.isEmpty
                              ? const Padding(
                                  padding: EdgeInsets.symmetric(
                                    horizontal: 12,
                                    vertical: 16,
                                  ),
                                  child: Text(
                                    'No models match',
                                    style: TextStyle(
                                      color: DuckColors.fgSubtle,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  shrinkWrap: true,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 4,
                                  ),
                                  itemCount: list.length,
                                  itemBuilder: (_, i) {
                                    final m = list[i];
                                    final selected = m == widget.value;
                                    final highlighted = i == _highlight;
                                    return InkWell(
                                      onTap: () => widget.onPick(m),
                                      onHover: (hovering) {
                                        if (hovering) {
                                          setState(() => _highlight = i);
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: WizardTokens.s12,
                                          vertical: WizardTokens.s8,
                                        ),
                                        color: highlighted
                                            ? widget.accent
                                                .withValues(alpha: 0.12)
                                            : Colors.transparent,
                                        child: Row(
                                          children: [
                                            Icon(
                                              selected
                                                  ? Icons.check
                                                  : Icons.circle_outlined,
                                              size: 14,
                                              color: selected
                                                  ? widget.accent
                                                  : DuckColors.fgSubtle,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Text(
                                                compactModelLabel(m),
                                                style: WizardTokens.pillLabel
                                                    .copyWith(
                                                  color: DuckColors.fgPrimary,
                                                  fontSize: 12,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 8),
                                            ConstrainedBox(
                                              constraints: const BoxConstraints(
                                                maxWidth: 150,
                                              ),
                                              child: Text(
                                                m,
                                                style: const TextStyle(
                                                  color: DuckColors.fgSubtle,
                                                  fontSize: 10.5,
                                                ),
                                                overflow:
                                                    TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    );
                                  },
                                ),
                        ),
                      ),
                      if (widget.onApplyToAll != null) ...[
                        const Divider(
                          height: 1,
                          color: DuckColors.glassSeam,
                        ),
                        InkWell(
                          onTap: widget.onApplyToAll,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: WizardTokens.s12,
                              vertical: WizardTokens.s10,
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.flash_on,
                                  size: 14,
                                  color: widget.accent,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  'Apply to all agents',
                                  style: WizardTokens.pillLabel.copyWith(
                                    color: DuckColors.fgPrimary,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
