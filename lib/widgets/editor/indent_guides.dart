import 'dart:math';

import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

/// Vertical indent-guide overlay for `re_editor`.
///
/// `re_editor 0.8.0` exposes no painting hooks (no `backgroundBuilder`,
/// no per-line decoration callback), so we layer this on top of the
/// editor inside a `Stack` and sync to the controller's scroll
/// position manually. The overlay is `IgnorePointer` so taps fall
/// through to the editor body.
///
/// The gutter offset (where code column 0 actually paints) is computed
/// **internally** by mirroring re_editor's own layout math: line-number
/// width = TextPainter measurement of `'0' × max(3, digitCount)` at the
/// line-number text style, plus the chunk-indicator width, plus the
/// separator width, plus re_editor's `_kDefaultPadding.left`. The
/// overlay listens to the editing controller, so the gutter width
/// auto-updates when the line count crosses a digit boundary
/// (9 → 10, 99 → 100, …) without the parent needing to rebuild.
///
/// **Limits / known imperfections** (failure mode is graceful — guides
/// just become slightly visually off, never broken):
/// - Tabs are counted as `indentSize` spaces. If the file mixes
///   tabs of a different width the guides will be off by a few px
///   on tabbed lines.
/// - Char width is measured by laying out a single space glyph;
///   for monospace fonts that's correct, but ligatures / variable
///   glyph metrics in the editor font would drift the alignment.
class IndentGuidesOverlay extends StatefulWidget {
  /// Editing controller — read for `codeLines` (line text per index)
  /// and listened to so guides re-paint when the file changes.
  final CodeLineEditingController controller;

  /// Scroll controller — used to read vertical / horizontal scroll
  /// offsets so the guides stay aligned to the code while the user
  /// scrolls, and listened to for repaint triggers.
  final CodeScrollController scrollController;

  /// Editor font size in logical pixels — used to measure char width
  /// (via `TextPainter`) and as a multiplier for line height.
  final double fontSize;

  /// Multiplier on `fontSize` for line height. Should match the
  /// `CodeEditorStyle.fontHeight` passed to the editor.
  final double fontHeight;

  /// Editor font family — passed into the `TextPainter` measure so
  /// the char width matches the actual rendered font.
  final String? fontFamily;

  /// Indent step in characters (4 spaces by default in `re_editor`'s
  /// `CodeLineOptions`). Tabs are treated as one indent of this size.
  final int indentSize;

  /// Width of `DefaultCodeChunkIndicator(width: …)` from the parent's
  /// `indicatorBuilder`. We default to the same `20` the editor pane
  /// uses today; pass a different value if the indicator is replaced.
  final double chunkIndicatorWidth;

  /// Width of the `sperator` widget passed to `CodeEditor`. The pane
  /// currently uses a 1px `Container`; default matches.
  final double separatorWidth;

  /// re_editor 0.8.0 wraps the code field in a `Padding` of
  /// `EdgeInsets.all(5)` (`_kDefaultPadding`). The horizontal value
  /// shifts the code column right by 5px relative to the gutter; the
  /// default here reflects the package default.
  final double codeFieldPadding;

  /// Effective top padding of `CodeEditor`'s `_CodeField`. This is
  /// normally 5px, but `re_editor` adds the find bar's preferred
  /// height while in find/replace mode.
  final double topPadding;

  /// Cursor's `editorIndentGuide.background` is `#434c5eb3`
  /// (rgb 67/76/94 at 70% alpha). Pass that as the default; pass
  /// `editorIndentGuide.activeBackground` colour for the active
  /// guide if a future iteration adds active-line tracking.
  final Color color;

  const IndentGuidesOverlay({
    super.key,
    required this.controller,
    required this.scrollController,
    required this.fontSize,
    required this.fontHeight,
    required this.indentSize,
    required this.color,
    this.fontFamily,
    this.chunkIndicatorWidth = 20,
    this.separatorWidth = 1,
    this.codeFieldPadding = 5,
    this.topPadding = 5,
  });

  @override
  State<IndentGuidesOverlay> createState() => _IndentGuidesOverlayState();
}

class _IndentGuidesOverlayState extends State<IndentGuidesOverlay> {
  // Measured width of a single space glyph in the editor font. This
  // is the unit-of-indent we use to position the vertical lines —
  // for a monospace font it equals the width of every glyph.
  double _charWidth = 0;

  // Minimum digit count re_editor uses for the line-number column
  // (`_kDefaultMinNumberCount` in the package; not exported, so we
  // mirror it here). 3 means even a 1-line file gets a column wide
  // enough for "999".
  static const int _kMinNumberCount = 3;

  @override
  void initState() {
    super.initState();
    _measureCharWidth();
    widget.controller.addListener(_onControllerChange);
    widget.scrollController.verticalScroller.addListener(_onScrollChange);
    widget.scrollController.horizontalScroller.addListener(_onScrollChange);
  }

  @override
  void didUpdateWidget(IndentGuidesOverlay old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
    }
    if (old.scrollController != widget.scrollController) {
      old.scrollController.verticalScroller.removeListener(_onScrollChange);
      old.scrollController.horizontalScroller.removeListener(_onScrollChange);
      widget.scrollController.verticalScroller.addListener(_onScrollChange);
      widget.scrollController.horizontalScroller.addListener(_onScrollChange);
    }
    if (old.fontSize != widget.fontSize ||
        old.fontHeight != widget.fontHeight ||
        old.fontFamily != widget.fontFamily) {
      _measureCharWidth();
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChange);
    widget.scrollController.verticalScroller.removeListener(_onScrollChange);
    widget.scrollController.horizontalScroller.removeListener(_onScrollChange);
    super.dispose();
  }

  void _measureCharWidth() {
    final tp = TextPainter(
      text: TextSpan(
        text: ' ',
        style: TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    _charWidth = tp.width;
    tp.dispose();
  }

  /// Compute the live gutter offset by mirroring re_editor's layout.
  /// Cheap (one TextPainter per call); called only on each repaint
  /// so the cost is negligible compared to the indent-guide loop
  /// itself.
  double _gutterOffset() {
    final lineCount = widget.controller.codeLines.length;
    final digitCount = max(_kMinNumberCount, lineCount.toString().length);
    final tp = TextPainter(
      text: TextSpan(
        text: '0' * digitCount,
        style: TextStyle(
          // Line numbers render one px smaller than body text — same
          // convention `_EditorPaneState`'s indicatorBuilder uses.
          fontSize: widget.fontSize - 1,
          fontFamily: widget.fontFamily,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lineNumWidth = tp.width;
    tp.dispose();
    return lineNumWidth +
        widget.chunkIndicatorWidth +
        widget.separatorWidth +
        widget.codeFieldPadding;
  }

  double _preferredLineHeight() {
    final tp = TextPainter(
      text: TextSpan(
        text: '0',
        style: TextStyle(
          fontSize: widget.fontSize,
          fontFamily: widget.fontFamily,
          height: widget.fontHeight,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final height = tp.preferredLineHeight;
    tp.dispose();
    return height;
  }

  void _onControllerChange() {
    if (!mounted) return;
    // Cheap repaint — `setState` with no body is the supported
    // way to force `CustomPaint` to re-evaluate when the
    // controller-derived inputs (codeLines) change.
    setState(() {});
  }

  void _onScrollChange() {
    if (!mounted) return;
    setState(() {});
  }

  double _readVerticalScroll() {
    return widget.scrollController.verticalScroller.hasClients
        ? widget.scrollController.verticalScroller.offset
        : 0;
  }

  double _readHorizontalScroll() {
    return widget.scrollController.horizontalScroller.hasClients
        ? widget.scrollController.horizontalScroller.offset
        : 0;
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _IndentGuidesPainter(
          codeLines: widget.controller.codeLines,
          lineHeight: _preferredLineHeight(),
          charWidth: _charWidth,
          indentSize: widget.indentSize,
          gutterOffset: _gutterOffset(),
          topPadding: widget.topPadding,
          verticalScroll: _readVerticalScroll(),
          horizontalScroll: _readHorizontalScroll(),
          color: widget.color,
        ),
      ),
    );
  }
}

class _IndentGuidesPainter extends CustomPainter {
  final CodeLines codeLines;
  final double lineHeight;
  final double charWidth;
  final int indentSize;
  final double gutterOffset;
  final double topPadding;
  final double verticalScroll;
  final double horizontalScroll;
  final Color color;

  _IndentGuidesPainter({
    required this.codeLines,
    required this.lineHeight,
    required this.charWidth,
    required this.indentSize,
    required this.gutterOffset,
    required this.topPadding,
    required this.verticalScroll,
    required this.horizontalScroll,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (charWidth <= 0 || codeLines.length == 0 || indentSize <= 0) return;

    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.0
      ..isAntiAlias = false; // crisp 1px verticals — AA softens to 2px

    // Visible-line range based on the current vertical scroll offset
    // and the painter's height. We pad ±1 line so a partial line at
    // the top/bottom of the viewport still gets its guides drawn.
    final viewportTopLine = (verticalScroll - topPadding) / lineHeight;
    final firstVisible = (viewportTopLine.floor() - 1).clamp(
      0,
      codeLines.length - 1,
    );
    final lastVisible =
        ((viewportTopLine + size.height / lineHeight).ceil() + 1).clamp(
          0,
          codeLines.length,
        );

    final visualIndentSize = _inferVisualIndentSize(firstVisible, lastVisible);
    final indentPx = visualIndentSize * charWidth;
    final guideLevelsByLine = <int, int>{};
    int maxGuideLevel = 0;
    for (int i = firstVisible; i < lastVisible; i++) {
      final guideLevel = _guideLevelForLine(i, visualIndentSize);
      if (guideLevel <= 0) continue;
      guideLevelsByLine[i] = guideLevel;
      maxGuideLevel = max(maxGuideLevel, guideLevel);
    }

    for (int level = 1; level <= maxGuideLevel; level++) {
      int? runStart;
      for (int i = firstVisible; i < lastVisible; i++) {
        final inScope = (guideLevelsByLine[i] ?? 0) >= level;
        if (inScope) {
          runStart ??= i;
          continue;
        }
        if (runStart != null) {
          _drawGuideRun(
            canvas: canvas,
            size: size,
            paint: paint,
            level: level,
            startLine: runStart,
            endLineExclusive: i,
            indentPx: indentPx,
          );
          runStart = null;
        }
      }
      if (runStart != null) {
        _drawGuideRun(
          canvas: canvas,
          size: size,
          paint: paint,
          level: level,
          startLine: runStart,
          endLineExclusive: lastVisible,
          indentPx: indentPx,
        );
      }
    }
  }

  void _drawGuideRun({
    required Canvas canvas,
    required Size size,
    required Paint paint,
    required int level,
    required int startLine,
    required int endLineExclusive,
    required double indentPx,
  }) {
    final yTop = topPadding + (startLine * lineHeight) - verticalScroll;
    final yBottom =
        topPadding + (endLineExclusive * lineHeight) - verticalScroll;
    if (yBottom < 0 || yTop > size.height) return;

    // Position at the START of the indent column, not the end —
    // this matches Cursor / VS Code, which paint the guide at
    // each indent boundary on the LEFT of the upcoming text.
    final x = gutterOffset + (level * indentPx) - horizontalScroll;
    // Crop to viewport horizontally — the guide would otherwise
    // paint over the line-number gutter when scrolled hard right.
    if (x < gutterOffset - 0.5 || x > size.width) return;
    canvas.drawLine(
      Offset(x, yTop.clamp(0, size.height)),
      Offset(x, yBottom.clamp(0, size.height)),
      paint,
    );
  }

  int _guideLevelForLine(int index, int visualIndentSize) {
    final indentLevel = _indentLevelForLine(index, visualIndentSize);
    if (indentLevel <= 0) return 0;
    // Cursor-style guides emphasize parent scopes more than the
    // current text edge. A line indented one level still gets the
    // root scope guide; deeper lines omit their deepest boundary,
    // which keeps nested literals from turning into a barcode.
    return max(1, indentLevel - 1);
  }

  int _indentLevelForLine(int index, int visualIndentSize) {
    final text = codeLines[index].text;
    if (text.trim().isEmpty) {
      return _blankLineIndentLevel(index, visualIndentSize);
    }

    // Count leading whitespace; treat tabs as one indent step
    // each (cf. the class-doc note on tab handling).
    int leadingSpaces = 0;
    for (final ch in text.codeUnits) {
      if (ch == 0x20) {
        leadingSpaces++;
      } else if (ch == 0x09) {
        leadingSpaces += visualIndentSize;
      } else {
        break;
      }
    }
    return leadingSpaces ~/ visualIndentSize;
  }

  int _blankLineIndentLevel(int index, int visualIndentSize) {
    int? previous;
    for (int i = index - 1; i >= 0; i--) {
      if (codeLines[i].text.trim().isEmpty) continue;
      previous = _indentLevelForLine(i, visualIndentSize);
      break;
    }
    if (previous == null) return 0;

    int? next;
    for (int i = index + 1; i < codeLines.length; i++) {
      if (codeLines[i].text.trim().isEmpty) continue;
      next = _indentLevelForLine(i, visualIndentSize);
      break;
    }
    if (next == null) return 0;
    return min(previous, next);
  }

  int _inferVisualIndentSize(int firstVisible, int lastVisible) {
    var best = 0;
    for (int i = firstVisible; i < lastVisible; i++) {
      final spaces = _leadingSpaceCount(codeLines[i].text);
      if (spaces <= 0) continue;
      best = best == 0 ? spaces : _gcd(best, spaces);
    }
    if (best >= 2) return best.clamp(2, 8);
    return indentSize;
  }

  int _leadingSpaceCount(String text) {
    var leadingSpaces = 0;
    for (final ch in text.codeUnits) {
      if (ch == 0x20) {
        leadingSpaces++;
      } else if (ch == 0x09) {
        leadingSpaces += indentSize;
      } else {
        break;
      }
    }
    return leadingSpaces;
  }

  int _gcd(int a, int b) {
    while (b != 0) {
      final t = b;
      b = a % b;
      a = t;
    }
    return a.abs();
  }

  @override
  bool shouldRepaint(covariant _IndentGuidesPainter old) {
    return old.codeLines != codeLines ||
        old.verticalScroll != verticalScroll ||
        old.horizontalScroll != horizontalScroll ||
        old.lineHeight != lineHeight ||
        old.charWidth != charWidth ||
        old.gutterOffset != gutterOffset ||
        old.color != color;
  }
}
