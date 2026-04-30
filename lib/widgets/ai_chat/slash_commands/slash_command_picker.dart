import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../theme/app_colors.dart';
import '../../../theme/app_theme.dart';
import 'slash_command.dart';

/// Floating autocomplete popup that sits above the chat composer when
/// the user types `/` at the start of the input. Filters as they type,
/// supports keyboard navigation, and reports the picked command back
/// to the host via [onPick].
///
/// Lives inside an [Overlay] entry managed by the chat panel — see
/// [SlashCommandPickerController]. The widget itself is dumb: it
/// renders the filtered list and exposes a controller for the host to
/// drive selection/navigation in response to keystrokes the host
/// intercepts in its `Focus.onKeyEvent`.
class SlashCommandPicker extends StatelessWidget {
  final List<SlashCommand> commands;
  final int highlightedIndex;
  final ValueChanged<SlashCommand> onPick;

  const SlashCommandPicker({
    super.key,
    required this.commands,
    required this.highlightedIndex,
    required this.onPick,
  });

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) {
      return _EmptyState();
    }
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: DuckColors.bgGlassHi,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.border),
          boxShadow: DuckTheme.shadowSoft,
        ),
        constraints: const BoxConstraints(maxHeight: 220),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          child: ListView.builder(
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: commands.length,
            itemBuilder: (context, i) {
              final cmd = commands[i];
              final highlighted = i == highlightedIndex;
              return _CommandRow(
                command: cmd,
                highlighted: highlighted,
                onTap: () => onPick(cmd),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final SlashCommand command;
  final bool highlighted;
  final VoidCallback onTap;

  const _CommandRow({
    required this.command,
    required this.highlighted,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        color: highlighted
            ? DuckColors.bgRaisedHi
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(
              command.icon,
              size: 14,
              color: highlighted
                  ? DuckColors.accentCyan
                  : DuckColors.fgMuted,
            ),
            const SizedBox(width: 8),
            Text(
              '/${command.name}',
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: highlighted
                    ? DuckColors.fgPrimary
                    : DuckColors.fgPrimary,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                command.description,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgMuted,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: DuckColors.bgGlassHi,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.border),
        ),
        child: const Text(
          'No matching commands',
          style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
        ),
      ),
    );
  }
}

/// Outcome flags returned by the host to the picker controller after
/// the host intercepts a key event. Lets the controller decide whether
/// the keystroke should bubble (e.g. `Enter` on an empty picker still
/// sends the message).
enum SlashKeyHandling { handled, ignored }

/// Lightweight state holder consumed by the chat panel. Owns the
/// filtered list + highlighted index, surfaces an `OverlayEntry` for
/// the picker positioned above the composer, and exposes intent
/// helpers (`up`, `down`, `pick`, `close`) the host invokes from its
/// keyboard handler.
class SlashCommandPickerController extends ChangeNotifier {
  /// Layer link used by the host's [CompositedTransformTarget] (the
  /// composer box) so the picker can paint above it via a
  /// [CompositedTransformFollower]. Centralises positioning math.
  final LayerLink layerLink = LayerLink();

  bool _open = false;
  String _query = '';
  int _highlight = 0;
  List<SlashCommand> _filtered = const [];
  OverlayEntry? _overlay;

  bool get isOpen => _open;
  String get query => _query;
  int get highlightedIndex => _highlight;
  List<SlashCommand> get filtered => _filtered;
  SlashCommand? get highlighted =>
      _filtered.isEmpty ? null : _filtered[_highlight.clamp(0, _filtered.length - 1)];

  /// Update picker state from the latest composer text. Returns `true`
  /// when the picker should be visible after this update. Idempotent —
  /// safe to call on every keystroke.
  bool updateFromInput(String rawText, {required BuildContext overlayContext}) {
    final parsed = SlashCommandInput.tryParse(rawText);
    if (parsed == null) {
      close();
      return false;
    }
    _query = parsed.name;
    _filtered = SlashCommandRegistry.filter(_query);
    _highlight = _filtered.isEmpty ? 0 : _highlight.clamp(0, _filtered.length - 1);

    if (!_open) {
      _show(overlayContext);
    } else {
      _overlay?.markNeedsBuild();
    }
    notifyListeners();
    return true;
  }

  void up() {
    if (!_open || _filtered.isEmpty) return;
    _highlight = (_highlight - 1 + _filtered.length) % _filtered.length;
    _overlay?.markNeedsBuild();
    notifyListeners();
  }

  void down() {
    if (!_open || _filtered.isEmpty) return;
    _highlight = (_highlight + 1) % _filtered.length;
    _overlay?.markNeedsBuild();
    notifyListeners();
  }

  /// Returns the currently highlighted command (if any) and closes the
  /// picker. The host runs the command; the picker just hands it over.
  SlashCommand? pickHighlighted() {
    final cmd = highlighted;
    close();
    return cmd;
  }

  /// Close the picker. Safe to call when already closed.
  void close() {
    if (!_open) return;
    _overlay?.remove();
    _overlay = null;
    _open = false;
    _query = '';
    _filtered = const [];
    _highlight = 0;
    notifyListeners();
  }

  void _show(BuildContext overlayContext) {
    final overlay = Overlay.of(overlayContext, rootOverlay: true);
    _overlay = OverlayEntry(builder: _buildOverlay);
    overlay.insert(_overlay!);
    _open = true;
  }

  Widget _buildOverlay(BuildContext context) {
    return Positioned(
      width: 360,
      child: CompositedTransformFollower(
        link: layerLink,
        showWhenUnlinked: false,
        // Anchor: bottom-left of the composer; the picker grows upward
        // so the most-relevant first command sits closest to the input.
        targetAnchor: Alignment.topLeft,
        followerAnchor: Alignment.bottomLeft,
        offset: const Offset(0, -6),
        child: SlashCommandPicker(
          commands: _filtered,
          highlightedIndex: _highlight,
          onPick: (cmd) {
            // Host listens via `pickedFromTap` — but we also stash it
            // so the controller can surface it on demand.
            _lastTapPick = cmd;
            close();
            for (final l in _tapListeners) {
              l(cmd);
            }
          },
        ),
      ),
    );
  }

  /// Last command the user clicked. Cleared when the picker closes
  /// after a non-tap interaction (keyboard pick or escape).
  SlashCommand? _lastTapPick;
  SlashCommand? get lastTapPick => _lastTapPick;

  final List<ValueChanged<SlashCommand>> _tapListeners = [];

  /// Subscribe to taps in the picker. Hosts use this to send the
  /// expanded message immediately when the user clicks a command.
  void addTapListener(ValueChanged<SlashCommand> l) => _tapListeners.add(l);
  void removeTapListener(ValueChanged<SlashCommand> l) =>
      _tapListeners.remove(l);

  /// Convert keyboard intent to a controller action while the picker
  /// is open. Returns `handled` when the controller consumed the key
  /// (host should swallow it), `ignored` otherwise.
  SlashKeyHandling onKey(KeyEvent event) {
    if (!_open) return SlashKeyHandling.ignored;
    if (event is! KeyDownEvent) return SlashKeyHandling.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      down();
      return SlashKeyHandling.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      up();
      return SlashKeyHandling.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      close();
      return SlashKeyHandling.handled;
    }
    return SlashKeyHandling.ignored;
  }

  @override
  void dispose() {
    close();
    _tapListeners.clear();
    super.dispose();
  }
}
