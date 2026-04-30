import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../services/recent_edits_tracker.dart';

/// Subtle full-line tint behind code lines that the most recent agent
/// turn touched. Layered into the editor's `Stack` between
/// `CodeEditor` and `IndentGuidesOverlay` so the indent guides still
/// paint on top, and `IgnorePointer` so taps fall through to the
/// editor body.
///
/// Listens to:
///  - the [tracker] for new turn data / invalidations,
///  - the [scrollController] so highlights track the viewport.
///
/// Inactive (no tracked lines for [absolutePath]) → returns a zero-cost
/// `SizedBox.shrink()` so it adds no paint cost when the feature is
/// disabled or the file isn't in the recent-edits map.
class RecentEditsOverlay extends StatefulWidget {
  final RecentEditsTracker tracker;
  final CodeScrollController scrollController;

  /// Absolute path of the file shown in the editor — keyed against
  /// `tracker.linesFor(...)`. Untitled / Settings sentinel paths are
  /// safe; they just yield null (no highlights).
  final String absolutePath;

  /// `editorFontSize × fontHeight` — same product the editor uses for
  /// each visible line's height.
  final double fontSize;

  /// Same value passed to `CodeEditorStyle.fontHeight`.
  final double fontHeight;

  /// Same font family passed to `CodeEditorStyle.fontFamily`.
  final String? fontFamily;

  /// Mirrors `IndentGuidesOverlay.codeFieldPadding`. re_editor wraps
  /// the code field in `EdgeInsets.all(5)` by default; first line's
  /// background tints would float 5px above the actual line text
  /// without this.
  final double topPadding;

  /// Highlight tint. Defaults to `accentCyan @ 6% alpha` — barely
  /// perceptible on the dark editor background but enough to pick
  /// out a recently-edited block at a glance.
  final Color color;

  const RecentEditsOverlay({
    super.key,
    required this.tracker,
    required this.scrollController,
    required this.absolutePath,
    required this.fontSize,
    required this.fontHeight,
    this.fontFamily,
    this.topPadding = 5,
    required this.color,
  });

  @override
  State<RecentEditsOverlay> createState() => _RecentEditsOverlayState();
}

class _RecentEditsOverlayState extends State<RecentEditsOverlay> {
  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_onTrackerChange);
    widget.scrollController.verticalScroller.addListener(_onScrollChange);
  }

  @override
  void didUpdateWidget(RecentEditsOverlay old) {
    super.didUpdateWidget(old);
    if (old.tracker != widget.tracker) {
      old.tracker.removeListener(_onTrackerChange);
      widget.tracker.addListener(_onTrackerChange);
    }
    if (old.scrollController != widget.scrollController) {
      old.scrollController.verticalScroller.removeListener(_onScrollChange);
      widget.scrollController.verticalScroller.addListener(_onScrollChange);
    }
  }

  @override
  void dispose() {
    widget.tracker.removeListener(_onTrackerChange);
    widget.scrollController.verticalScroller.removeListener(_onScrollChange);
    super.dispose();
  }

  void _onTrackerChange() {
    if (!mounted) return;
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

  @override
  Widget build(BuildContext context) {
    final lines = widget.tracker.linesFor(widget.absolutePath);
    if (lines == null || lines.isEmpty) return const SizedBox.shrink();
    return IgnorePointer(
      child: CustomPaint(
        size: Size.infinite,
        painter: _RecentEditsPainter(
          lines: lines,
          lineHeight: _preferredLineHeight(),
          topPadding: widget.topPadding,
          verticalScroll: _readVerticalScroll(),
          color: widget.color,
        ),
      ),
    );
  }
}

class _RecentEditsPainter extends CustomPainter {
  final Set<int> lines;
  final double lineHeight;
  final double topPadding;
  final double verticalScroll;
  final Color color;

  _RecentEditsPainter({
    required this.lines,
    required this.lineHeight,
    required this.topPadding,
    required this.verticalScroll,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (lines.isEmpty) return;
    final paint = Paint()..color = color;

    // Cull off-viewport line indices via floor/ceil bounds. Iterating
    // every tracked line every paint would be O(N) for the whole tracked
    // set; for a vibe-coded file with thousands of "recent" lines that's
    // wasteful. Compute viewport line range once, intersect.
    final firstVisible =
        ((verticalScroll - topPadding) / lineHeight).floor() - 1;
    final lastVisible =
        ((verticalScroll + size.height - topPadding) / lineHeight).ceil() + 1;

    for (final line in lines) {
      if (line < firstVisible || line > lastVisible) continue;
      final yTop = topPadding + (line * lineHeight) - verticalScroll;
      if (yTop + lineHeight < 0 || yTop > size.height) continue;
      // Full-width strip — paints across the gutter area too. The gutter
      // is slightly transparent so the tint reads softer there, which
      // is fine; it lets the eye trace a horizontal band continuously
      // from gutter to code without a hard edge at the separator.
      canvas.drawRect(Rect.fromLTWH(0, yTop, size.width, lineHeight), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _RecentEditsPainter old) {
    return old.lines != lines ||
        old.verticalScroll != verticalScroll ||
        old.lineHeight != lineHeight ||
        old.topPadding != topPadding ||
        old.color != color;
  }
}
