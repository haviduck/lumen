import 'package:flutter/material.dart';

import '../../services/chat_chip.dart';

/// Chip-aware companion to the chat composer's `TextEditingController`.
///
/// **Composite-widget design** (replaces the earlier in-band marker
/// approach): chips are NOT encoded into [TextEditingController.text].
/// Plain text stays plain — no PUA codepoints, no `\uFFFC`, no JSON
/// sentinels. Chip metadata lives in a parallel ordered list and the
/// composer renders a `Wrap` of pill widgets ABOVE the `TextField`.
///
/// Why this shape: the council pool falsified every in-band variant
/// across seven attack vectors —
///   - flutter#30688 IME composing-range corruption when the range
///     straddled a placeholder codepoint,
///   - Nerd Font glyphs colliding with PUA marker pairs at U+E000+,
///   - paste normalisation being unable to distinguish "user pasted
///     a real placeholder" from "framework re-emitted our marker",
///   - undo/redo stacks producing chip-list desync when the
///     framework restored a TextEditingValue from before a chip
///     insertion,
///   - copy/paste of a span containing a chip producing literal
///     U+FFFC glyphs in unrelated apps,
///   - slash-command-picker offsets going wrong when chips appeared
///     between the `/` and the cursor,
///   - voice-dictation engines on Windows IMM dropping placeholder
///     codepoints silently mid-stream.
///
/// The composite-widget approach survives all of them by keeping the
/// text stream clean and chip identity in a sibling list. Backspace
/// no longer atomically removes a chip — chip removal is via the X
/// button on the pill (or the parent strip's drag-out gesture).
class ChipTextEditingController extends TextEditingController {
  ChipTextEditingController({super.text});

  final List<ChatChip> _chips = <ChatChip>[];
  final List<VoidCallback> _chipListeners = <VoidCallback>[];

  /// Snapshot of the current chip list (caller must not mutate).
  List<ChatChip> get chips => List.unmodifiable(_chips);

  bool get hasChips => _chips.isNotEmpty;

  /// Append [chip] to the chip list. Idempotent on [ChatChip.id].
  /// Chips render out-of-band via `ChatComposerChipsStrip` so the
  /// caret, slash-command picker offsets, and IME composing range
  /// are all unaffected.
  void addChip(ChatChip chip) {
    if (_chips.any((c) => c.id == chip.id)) return;
    _chips.add(chip);
    _notifyChips();
  }

  /// Remove the chip at [index] — driven by the X button on the
  /// pill widget.
  void removeChipAt(int index) {
    if (index < 0 || index >= _chips.length) return;
    _chips.removeAt(index);
    _notifyChips();
  }

  /// Drop all chips without touching [text].
  void clearChips() {
    if (_chips.isEmpty) return;
    _chips.clear();
    _notifyChips();
  }

  /// Drop chips AND text — used by the composer when a message is
  /// successfully sent.
  void clearAll() {
    _chips.clear();
    clear();
    _notifyChips();
  }

  /// Subscribe to chip-list mutations. The strip widget uses this so
  /// it can rebuild without subscribing to the noisier text-change
  /// stream.
  void addChipListener(VoidCallback listener) {
    _chipListeners.add(listener);
  }

  void removeChipListener(VoidCallback listener) {
    _chipListeners.remove(listener);
  }

  void _notifyChips() {
    for (final l in List<VoidCallback>.from(_chipListeners)) {
      l();
    }
    notifyListeners();
  }

  /// Serialise the current composer state into ordered
  /// `[MessageSegment]`s. Wire shape committed to (ratified by the
  /// council pool): `[ChipSegment*, TextSegment]` — every chip
  /// emitted first as a self-describing block, then the prose text.
  /// Inline ordering of chips relative to caret is intentionally
  /// dropped: each chip's `renderForModel` block is self-contained
  /// (`<file path=…/>`, `<terminal …>…</terminal>`), so the model
  /// receives full structured context without textual interleaving.
  List<MessageSegment> toSegments() {
    final out = <MessageSegment>[];
    for (final c in _chips) {
      out.add(ChipSegment(c));
    }
    if (text.isNotEmpty) out.add(TextSegment(text));
    return out;
  }

  @override
  void dispose() {
    _chipListeners.clear();
    super.dispose();
  }
}
