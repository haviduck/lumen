// Unified chip schema used by THREE surfaces:
//   1. The chat composer  (lib/widgets/ai_chat/chip_text_editing_controller.dart)
//   2. The xterm pane      (lib/widgets/terminal/terminal_selection_tooltip.dart)
//   3. The file explorer   (drag-drop into composer in lib/widgets/ai_chat/ai_chat.dart)
//
// One type so the chip the user drags from the file tree is the SAME type
// the terminal-selection tooltip emits, is the SAME type a `MessageBubble`
// renders inline after send. Keep it small and JSON-roundtrippable —
// chips are serialised into persisted messages via [MessageSegment].
//
// History: two earlier sketches were both falsified by the council
// pool. Sketch A encoded chips in the composer's plain text via PUA
// marker pairs (\uE000<id>\uE001) — Material Icons + Nerd Fonts live
// at U+E000+, so pasting Lumen's own terminal output collided.
// Sketch B used `\uFFFC` (OBJECT REPLACEMENT CHARACTER) as a single-
// codepoint placeholder — falsified across IME corruption
// (flutter#30688), copy/paste leaking literal U+FFFC into other apps,
// undo/redo desync, slash-picker offsets, and Windows IMM voice
// dictation dropping placeholder codepoints. Both were rejected by
// seven sibling agents.
//
// Current design: composite widget. Chips render as a `Wrap` of pill
// widgets ABOVE the composer's `TextField`. The text stream stays
// plain. Chip metadata lives in a parallel ordered list inside
// `ChipTextEditingController._chips`. On send, segments are emitted
// as `[ChipSegment*, TextSegment]` — chips first, prose last.

import 'package:path/path.dart' as p;

enum ChatChipKind {
  /// A file (no line range). Drag-drop from explorer or @-mention.
  file,

  /// A folder reference (recursive listing on the model side).
  folder,

  /// A code range inside a file: [path] + [lineStart..lineEnd].
  codeRange,

  /// A snippet from the embedded xterm: [terminalId] +
  /// [lineStart..lineEnd] + [snippet] preview.
  terminalSelection,

  /// A free-floating attachment (image, doc, knowledgebase entry).
  doc,
}

class ChatChip {
  /// Stable id (uuid-ish). The composer uses this to map a
  /// placeholder character at position N in `text` back to the chip
  /// metadata.  Persisted into [MessageSegment] so reloading a chat
  /// session restores the same chip identity (used by the editor's
  /// pending-hunks overlay to cross-link "this chip came from that
  /// edit hunk", future work).
  final String id;
  final ChatChipKind kind;

  /// User-facing short label rendered inside the pill ("foo.dart",
  /// "foo.dart:42-58", "term-1:14-22").
  final String label;

  /// Absolute or workspace-rooted path. Empty for terminal/doc chips.
  final String path;

  /// Optional workspace-relative path so MessageBubble can render
  /// short labels even when reloaded in a different working dir.
  final String? workspaceRelativePath;

  /// 1-based inclusive line range. Both null for non-ranged chips.
  final int? lineStart;
  final int? lineEnd;

  /// Terminal-session id for [ChatChipKind.terminalSelection].
  final String? terminalId;

  /// Preview snippet (≤4 lines) for terminal selections + doc chips.
  /// Goes into the outbound prompt so the model sees what the user
  /// pointed at without having to re-fetch the terminal buffer.
  final String? snippet;

  const ChatChip({
    required this.id,
    required this.kind,
    required this.label,
    this.path = '',
    this.workspaceRelativePath,
    this.lineStart,
    this.lineEnd,
    this.terminalId,
    this.snippet,
  });

  bool get hasRange => lineStart != null && lineEnd != null;

  /// Plain-text rendering used inside outbound user messages and inside
  /// persisted message bodies after send. Chips become `[label]`-style
  /// refs when the message bubble renders so users can copy meaningful
  /// text out, and the model receives a structured `<chip ...>` block
  /// alongside (see [ChatChip.renderForModel]).
  String get inlineRef {
    switch (kind) {
      case ChatChipKind.file:
      case ChatChipKind.folder:
      case ChatChipKind.doc:
        return '@$label';
      case ChatChipKind.codeRange:
        return '@$label';
      case ChatChipKind.terminalSelection:
        return '⎇$label';
    }
  }

  /// Block emitted into the model-facing prompt. Kept verbose so the
  /// agent doesn't have to ask a follow-up tool call to discover what
  /// the chip pointed at — for terminal selections the snippet is
  /// included verbatim.
  String renderForModel() {
    final buf = StringBuffer();
    switch (kind) {
      case ChatChipKind.file:
        buf.writeln('<file path="${workspaceRelativePath ?? path}" />');
        break;
      case ChatChipKind.folder:
        buf.writeln('<folder path="${workspaceRelativePath ?? path}" />');
        break;
      case ChatChipKind.codeRange:
        buf.writeln(
          '<code path="${workspaceRelativePath ?? path}" '
          'start="$lineStart" end="$lineEnd" />',
        );
        break;
      case ChatChipKind.terminalSelection:
        buf.writeln('<terminal id="$terminalId" start="$lineStart" end="$lineEnd">');
        if (snippet != null) buf.writeln(snippet);
        buf.writeln('</terminal>');
        break;
      case ChatChipKind.doc:
        buf.writeln('<doc path="$path" label="$label">');
        if (snippet != null) buf.writeln(snippet);
        buf.writeln('</doc>');
        break;
    }
    return buf.toString().trimRight();
  }

  /// Convenience constructors used by the three surfaces so we don't
  /// scatter id-generation logic across the codebase.
  factory ChatChip.file({
    required String path,
    String? workspaceRelativePath,
  }) {
    final label = workspaceRelativePath ?? p.basename(path);
    return ChatChip(
      id: _genId(),
      kind: ChatChipKind.file,
      label: label,
      path: path,
      workspaceRelativePath: workspaceRelativePath,
    );
  }

  factory ChatChip.folder({
    required String path,
    String? workspaceRelativePath,
  }) {
    final label = workspaceRelativePath ?? p.basename(path);
    return ChatChip(
      id: _genId(),
      kind: ChatChipKind.folder,
      label: '$label/',
      path: path,
      workspaceRelativePath: workspaceRelativePath,
    );
  }

  factory ChatChip.codeRange({
    required String path,
    required int lineStart,
    required int lineEnd,
    String? workspaceRelativePath,
  }) {
    final base = workspaceRelativePath ?? p.basename(path);
    return ChatChip(
      id: _genId(),
      kind: ChatChipKind.codeRange,
      label: '$base:$lineStart-$lineEnd',
      path: path,
      workspaceRelativePath: workspaceRelativePath,
      lineStart: lineStart,
      lineEnd: lineEnd,
    );
  }

  factory ChatChip.terminal({
    required String terminalId,
    required int lineStart,
    required int lineEnd,
    required String snippet,
  }) {
    return ChatChip(
      id: _genId(),
      kind: ChatChipKind.terminalSelection,
      label: '$terminalId:$lineStart-$lineEnd',
      terminalId: terminalId,
      lineStart: lineStart,
      lineEnd: lineEnd,
      snippet: snippet,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'label': label,
    if (path.isNotEmpty) 'path': path,
    if (workspaceRelativePath != null) 'rel': workspaceRelativePath,
    if (lineStart != null) 'ls': lineStart,
    if (lineEnd != null) 'le': lineEnd,
    if (terminalId != null) 'tid': terminalId,
    if (snippet != null) 'snip': snippet,
  };

  factory ChatChip.fromJson(Map<String, dynamic> j) {
    final rawKind = j['kind'] as String?;
    return ChatChip(
      id: (j['id'] ?? _genId()) as String,
      kind: ChatChipKind.values.firstWhere(
        (k) => k.name == rawKind,
        orElse: () => ChatChipKind.file,
      ),
      label: (j['label'] ?? '') as String,
      path: (j['path'] ?? '') as String,
      workspaceRelativePath: j['rel'] as String?,
      lineStart: (j['ls'] as num?)?.toInt(),
      lineEnd: (j['le'] as num?)?.toInt(),
      terminalId: j['tid'] as String?,
      snippet: j['snip'] as String?,
    );
  }
}

/// Structured wire/storage format for a sent message. Composer
/// serialises ordered chips + plain text → `List<MessageSegment>`
/// on submit. Persisted messages carry the structured shape so
/// reloads re-hydrate chips as first-class entities (no in-band
/// markers ever appear on the wire).
sealed class MessageSegment {
  const MessageSegment();
  Map<String, dynamic> toJson();
  static MessageSegment fromJson(Map<String, dynamic> j) {
    final t = j['t'] as String?;
    if (t == 'chip') return ChipSegment(ChatChip.fromJson(Map<String, dynamic>.from(j['c'] as Map)));
    return TextSegment((j['v'] ?? '') as String);
  }
}

class TextSegment extends MessageSegment {
  final String text;
  const TextSegment(this.text);
  @override
  Map<String, dynamic> toJson() => {'t': 'txt', 'v': text};
}

class ChipSegment extends MessageSegment {
  final ChatChip chip;
  const ChipSegment(this.chip);
  @override
  Map<String, dynamic> toJson() => {'t': 'chip', 'c': chip.toJson()};
}

int _idCounter = 0;
String _genId() {
  _idCounter = (_idCounter + 1) & 0x7fffffff;
  final ts = DateTime.now().microsecondsSinceEpoch;
  return 'c${ts.toRadixString(36)}-${_idCounter.toRadixString(36)}';
}

/// Build segments from a (chips, text) composer snapshot. Wire
/// shape: chips first (each as a self-describing `<file/>`,
/// `<terminal>` block via `renderForModel`), then a single text
/// segment for the prose.
List<MessageSegment> segmentsFrom(String text, List<ChatChip> chips) {
  final out = <MessageSegment>[];
  for (final c in chips) {
    out.add(ChipSegment(c));
  }
  if (text.isNotEmpty) out.add(TextSegment(text));
  return out;
}

/// Render a list of segments to the model-facing prompt string.
/// Each chip emits a self-describing block (`<file path=.../>`,
/// `<terminal ...>...</terminal>`), so the model gets full structured
/// context without depending on textual interleaving with prose.
String renderSegmentsForModel(List<MessageSegment> segments) {
  final buf = StringBuffer();
  for (final s in segments) {
    if (s is TextSegment) buf.write(s.text);
    if (s is ChipSegment) buf.write(s.chip.renderForModel());
  }
  return buf.toString();
}

/// Render segments to the user-bubble plain-text body. Chips become
/// `@label` / `⎇label` refs so copy/paste out of the bubble produces
/// useful text. With the composite-composer wire shape
/// (`[ChipSegment*, TextSegment]`) the refs cluster at the start of
/// the bubble — bubble-side rendering is responsible for laying them
/// out as a leading chip strip rather than inlining the ref string
/// into prose.
String renderSegmentsForBubble(List<MessageSegment> segments) {
  final buf = StringBuffer();
  for (final s in segments) {
    if (s is TextSegment) buf.write(s.text);
    if (s is ChipSegment) buf.write(s.chip.inlineRef);
  }
  return buf.toString();
}
