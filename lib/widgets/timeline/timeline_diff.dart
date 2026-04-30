import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';

/// Side-by-side diff view used inside [TimelineDialog].
///
/// Pure presentation widget — owns no service references. Receives
/// the revision text on the left and the current file text on the
/// right, computes a line-level LCS diff, and paints two scrollable
/// columns whose vertical scrolls are kept in sync.
///
/// **Diff strategy.** Line-level LCS via the textbook DP table.
/// O(N×M) time/space — fine for the under-4MB / few-thousand-line
/// files the timeline service captures, and trivially correct (no
/// fancy heuristics that mis-align unrelated edits). For files
/// outside that envelope we'd switch to a Myers / patience diff,
/// but the timeline service already refuses to snapshot bigger
/// files so we'll never hit that path here.
///
/// **Synchronised scrolling.** Both panes share a single
/// `ScrollController` — they always show the same row range. Tried
/// the two-controllers + listener trick first, it produced visible
/// jitter when the two sides have wildly different line lengths
/// (one column overscrolls before the other catches up). Sharing
/// is fine because we paint matching rows side-by-side at the same
/// vertical offset.
class TimelineDiffView extends StatefulWidget {
  /// Heading on the left pane (e.g. "Revision 2026-04-29 14:32").
  final String revisionLabel;

  /// Heading on the right pane (e.g. "Current file").
  final String currentLabel;

  /// Text from the older revision. Null indicates "this revision
  /// represents the file not existing yet" — for now treated the
  /// same as empty string.
  final String? revisionText;

  /// Current text on disk. Null indicates the file no longer
  /// exists (delete entry, or a rename source). Rendered as an
  /// empty pane with a "(file deleted)" caption.
  final String? currentText;

  const TimelineDiffView({
    super.key,
    required this.revisionLabel,
    required this.currentLabel,
    required this.revisionText,
    required this.currentText,
  });

  @override
  State<TimelineDiffView> createState() => _TimelineDiffViewState();
}

class _TimelineDiffViewState extends State<TimelineDiffView> {
  late ScrollController _controller;
  late List<_DiffRow> _rows;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
    _rows = _computeRows();
  }

  @override
  void didUpdateWidget(covariant TimelineDiffView old) {
    super.didUpdateWidget(old);
    if (old.revisionText != widget.revisionText ||
        old.currentText != widget.currentText) {
      setState(() {
        _rows = _computeRows();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  List<_DiffRow> _computeRows() {
    return _diffLines(
      (widget.revisionText ?? '').split('\n'),
      (widget.currentText ?? '').split('\n'),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DiffHeader(
          left: widget.revisionLabel,
          right: widget.currentLabel,
          leftMissing: widget.revisionText == null,
          rightMissing: widget.currentText == null,
        ),
        Expanded(
          child: _DiffBody(
            controller: _controller,
            rows: _rows,
            leftMissing: widget.revisionText == null,
            rightMissing: widget.currentText == null,
          ),
        ),
      ],
    );
  }
}

class _DiffHeader extends StatelessWidget {
  final String left;
  final String right;
  final bool leftMissing;
  final bool rightMissing;
  const _DiffHeader({
    required this.left,
    required this.right,
    required this.leftMissing,
    required this.rightMissing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: _DiffHeaderCell(label: left, missing: leftMissing),
          ),
          Container(
            width: 0.5,
            height: 18,
            color: DuckColors.glassSeam,
          ),
          Expanded(
            child: _DiffHeaderCell(label: right, missing: rightMissing),
          ),
        ],
      ),
    );
  }
}

class _DiffHeaderCell extends StatelessWidget {
  final String label;
  final bool missing;
  const _DiffHeaderCell({required this.label, required this.missing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Text(
        missing ? '$label  (${S.timelineFileMissing})' : label,
        style: TextStyle(
          color: missing ? DuckColors.fgSubtle : DuckColors.fgMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _DiffBody extends StatelessWidget {
  final ScrollController controller;
  final List<_DiffRow> rows;
  final bool leftMissing;
  final bool rightMissing;
  const _DiffBody({
    required this.controller,
    required this.rows,
    required this.leftMissing,
    required this.rightMissing,
  });

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            S.timelineDiffEmpty,
            style: const TextStyle(color: DuckColors.fgSubtle, fontSize: 12),
          ),
        ),
      );
    }
    return Container(
      color: DuckColors.editorBg,
      child: Scrollbar(
        controller: controller,
        thumbVisibility: true,
        child: ListView.builder(
          controller: controller,
          itemCount: rows.length,
          itemExtent: 18,
          itemBuilder: (ctx, i) => _DiffRowView(
            row: rows[i],
            leftMissing: leftMissing,
            rightMissing: rightMissing,
          ),
        ),
      ),
    );
  }
}

class _DiffRowView extends StatelessWidget {
  final _DiffRow row;
  final bool leftMissing;
  final bool rightMissing;
  const _DiffRowView({
    required this.row,
    required this.leftMissing,
    required this.rightMissing,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: _DiffCell(
            text: row.left,
            tone: row.kind == _DiffKind.removed || row.kind == _DiffKind.changed
                ? _Tone.removed
                : _Tone.unchanged,
            empty: leftMissing && row.left == null,
          ),
        ),
        Container(width: 0.5, color: DuckColors.glassSeam),
        Expanded(
          child: _DiffCell(
            text: row.right,
            tone: row.kind == _DiffKind.added || row.kind == _DiffKind.changed
                ? _Tone.added
                : _Tone.unchanged,
            empty: rightMissing && row.right == null,
          ),
        ),
      ],
    );
  }
}

enum _Tone { unchanged, added, removed }

class _DiffCell extends StatelessWidget {
  final String? text;
  final _Tone tone;
  final bool empty;
  const _DiffCell({required this.text, required this.tone, required this.empty});

  @override
  Widget build(BuildContext context) {
    final bg = switch (tone) {
      _Tone.added => DuckColors.stateOk.withValues(alpha: 0.10),
      _Tone.removed => DuckColors.stateError.withValues(alpha: 0.12),
      _Tone.unchanged => Colors.transparent,
    };
    final fg = switch (tone) {
      _Tone.added => DuckColors.stateOk,
      _Tone.removed => DuckColors.stateError,
      _Tone.unchanged => DuckColors.fgPrimary,
    };
    return Container(
      color: bg,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: text == null
          ? const SizedBox.shrink()
          : Text(
              text!.isEmpty ? ' ' : text!,
              style: TextStyle(
                color: fg,
                fontFamily: 'monospace',
                fontFamilyFallback: const ['Consolas', 'Menlo', 'monospace'],
                fontSize: 12,
                height: 1.4,
              ),
              overflow: TextOverflow.clip,
              softWrap: false,
              maxLines: 1,
            ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────
//   Diff engine — line-level LCS.
// ─────────────────────────────────────────────────────────────────

enum _DiffKind { same, added, removed, changed }

class _DiffRow {
  final String? left;
  final String? right;
  final _DiffKind kind;
  const _DiffRow({required this.left, required this.right, required this.kind});
}

/// Standard LCS diff. Returns rows in display order.
///
/// Matched lines produce `same` rows with both sides populated.
/// Deletions populate `left` only (`right` null), insertions populate
/// `right` only. Adjacent removed/added pairs are folded into a
/// single `changed` row so the side-by-side view doesn't drift —
/// without folding, a one-line edit becomes a two-row red/green
/// staircase that's hard to read.
List<_DiffRow> _diffLines(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  // Zero-padding row makes the boundary cases trivial.
  final dp = List.generate(n + 1, (_) => List.filled(m + 1, 0));
  for (var i = 1; i <= n; i++) {
    for (var j = 1; j <= m; j++) {
      if (a[i - 1] == b[j - 1]) {
        dp[i][j] = dp[i - 1][j - 1] + 1;
      } else {
        dp[i][j] = dp[i - 1][j] >= dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
      }
    }
  }
  // Walk back to produce a list of (op, a-line, b-line) tuples in
  // forward order.
  final ops = <_DiffRow>[];
  var i = n;
  var j = m;
  final stack = <_DiffRow>[];
  while (i > 0 && j > 0) {
    if (a[i - 1] == b[j - 1]) {
      stack.add(_DiffRow(
        left: a[i - 1],
        right: b[j - 1],
        kind: _DiffKind.same,
      ));
      i--;
      j--;
    } else if (dp[i - 1][j] >= dp[i][j - 1]) {
      stack.add(_DiffRow(
        left: a[i - 1],
        right: null,
        kind: _DiffKind.removed,
      ));
      i--;
    } else {
      stack.add(_DiffRow(
        left: null,
        right: b[j - 1],
        kind: _DiffKind.added,
      ));
      j--;
    }
  }
  while (i > 0) {
    stack.add(_DiffRow(
      left: a[i - 1],
      right: null,
      kind: _DiffKind.removed,
    ));
    i--;
  }
  while (j > 0) {
    stack.add(_DiffRow(
      left: null,
      right: b[j - 1],
      kind: _DiffKind.added,
    ));
    j--;
  }
  ops.addAll(stack.reversed);

  // Coalesce adjacent removed+added pairs into a `changed` row so
  // a one-line edit reads as a single side-by-side row instead of
  // a staircase.
  final folded = <_DiffRow>[];
  var k = 0;
  while (k < ops.length) {
    final cur = ops[k];
    if (cur.kind == _DiffKind.removed &&
        k + 1 < ops.length &&
        ops[k + 1].kind == _DiffKind.added) {
      folded.add(_DiffRow(
        left: cur.left,
        right: ops[k + 1].right,
        kind: _DiffKind.changed,
      ));
      k += 2;
      continue;
    }
    if (cur.kind == _DiffKind.added &&
        k + 1 < ops.length &&
        ops[k + 1].kind == _DiffKind.removed) {
      folded.add(_DiffRow(
        left: ops[k + 1].left,
        right: cur.right,
        kind: _DiffKind.changed,
      ));
      k += 2;
      continue;
    }
    folded.add(cur);
    k++;
  }
  return folded;
}
