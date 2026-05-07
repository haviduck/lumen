import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

import '../../services/pending_hunks_service.dart';
import '../../theme/app_colors.dart';

/// Stack-layered overlay (peer of [RecentEditsOverlay]) that paints
/// per-hunk tints and a tiny gutter widget per hunk with ✓ accept
/// and ↺ revoke actions.
///
/// Layered ABOVE [RecentEditsOverlay] in the editor `Stack` so a
/// fresh agent edit reads as cyan recent-edit + green/yellow/red
/// pending-hunk band on the same line — the "agent did this AND it
/// is awaiting your call" signal Cursor uses.
class PendingHunksOverlay extends StatefulWidget {
  final PendingHunksService service;
  final CodeScrollController scrollController;
  final String absolutePath;
  final double fontSize;
  final double fontHeight;
  final String? fontFamily;
  final double topPadding;

  const PendingHunksOverlay({
    super.key,
    required this.service,
    required this.scrollController,
    required this.absolutePath,
    required this.fontSize,
    required this.fontHeight,
    this.fontFamily,
    this.topPadding = 5,
  });

  @override
  State<PendingHunksOverlay> createState() => _PendingHunksOverlayState();
}

class _PendingHunksOverlayState extends State<PendingHunksOverlay> {
  @override
  void initState() {
    super.initState();
    widget.service.addListener(_repaint);
    widget.scrollController.verticalScroller.addListener(_repaint);
  }

  @override
  void didUpdateWidget(PendingHunksOverlay old) {
    super.didUpdateWidget(old);
    if (old.service != widget.service) {
      old.service.removeListener(_repaint);
      widget.service.addListener(_repaint);
    }
    if (old.scrollController != widget.scrollController) {
      old.scrollController.verticalScroller.removeListener(_repaint);
      widget.scrollController.verticalScroller.addListener(_repaint);
    }
  }

  @override
  void dispose() {
    widget.service.removeListener(_repaint);
    widget.scrollController.verticalScroller.removeListener(_repaint);
    super.dispose();
  }

  void _repaint() {
    if (!mounted) return;
    setState(() {});
  }

  double _scroll() => widget.scrollController.verticalScroller.hasClients
      ? widget.scrollController.verticalScroller.offset
      : 0.0;

  double _lineHeight() {
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
    final h = tp.preferredLineHeight;
    tp.dispose();
    return h;
  }

  Color _bandFor(HunkKind k) {
    switch (k) {
      case HunkKind.added:
        return const Color(0xFF6BCB7A).withValues(alpha: 0.18);
      case HunkKind.removed:
        return const Color(0xFFE06C75).withValues(alpha: 0.16);
      case HunkKind.modified:
        return const Color(0xFFE5C07B).withValues(alpha: 0.16);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hunks = widget.service.hunksFor(widget.absolutePath);
    if (hunks.isEmpty) return const SizedBox.shrink();
    final lineH = _lineHeight();
    final scroll = _scroll();
    return Stack(
      fit: StackFit.expand,
      children: [
        // Bands behind the code — IgnorePointer so taps fall through.
        IgnorePointer(
          child: CustomPaint(
            size: Size.infinite,
            painter: _HunkBandsPainter(
              hunks: hunks,
              lineHeight: lineH,
              topPadding: widget.topPadding,
              scroll: scroll,
              bandFor: _bandFor,
            ),
          ),
        ),
        // Gutter action chips — one per hunk, anchored to the right
        // edge of the code area so they don't crowd the gutter.
        ...hunks.map((h) {
          final yTop = widget.topPadding +
              (h.newLineStart - 1) * lineH -
              scroll;
          final visible = yTop > -lineH;
          if (!visible) return const SizedBox.shrink();
          return Positioned(
            right: 6,
            top: yTop,
            height: lineH,
            child: _HunkActionChip(
              hunk: h,
              service: widget.service,
            ),
          );
        }),
      ],
    );
  }
}

class _HunkBandsPainter extends CustomPainter {
  final List<PendingHunk> hunks;
  final double lineHeight;
  final double topPadding;
  final double scroll;
  final Color Function(HunkKind) bandFor;

  _HunkBandsPainter({
    required this.hunks,
    required this.lineHeight,
    required this.topPadding,
    required this.scroll,
    required this.bandFor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final h in hunks) {
      final paint = Paint()..color = bandFor(h.kind);
      final yTop = topPadding + (h.newLineStart - 1) * lineHeight - scroll;
      final lines = (h.newLineEnd - h.newLineStart + 1).clamp(1, 100000);
      final height = lines * lineHeight;
      if (yTop + height < 0 || yTop > size.height) continue;
      canvas.drawRect(Rect.fromLTWH(0, yTop, size.width, height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _HunkBandsPainter old) =>
      old.hunks != hunks ||
      old.scroll != scroll ||
      old.lineHeight != lineHeight ||
      old.topPadding != topPadding;
}

class _HunkActionChip extends StatelessWidget {
  final PendingHunk hunk;
  final PendingHunksService service;
  const _HunkActionChip({required this.hunk, required this.service});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          color: DuckColors.bgChip.withValues(alpha: 0.92),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: DuckColors.border, width: 0.5),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Tooltip(
              message: 'Accept hunk',
              child: InkWell(
                onTap: () => service.accept(hunk.id),
                borderRadius: BorderRadius.circular(3),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.check,
                    size: 12,
                    color: Color(0xFF6BCB7A),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 2),
            Tooltip(
              message: 'Revoke hunk',
              child: InkWell(
                onTap: () => service.revoke(hunk.id),
                borderRadius: BorderRadius.circular(3),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(
                    Icons.undo,
                    size: 12,
                    color: Color(0xFFE06C75),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
