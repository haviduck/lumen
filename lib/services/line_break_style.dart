/// Line-ending detection + coercion. Shared between the editor pane
/// (matches `re_editor`'s `CodeLineEditingController` to the file's
/// actual line endings so the dirty-state heuristic doesn't flap on
/// CRLF files) and the agent's file-mutation tools (preserves the
/// original file's line endings on every write so the repo doesn't
/// silently get CRLF-laundered into LF every time the model edits).
///
/// Why a custom enum instead of re-using `re_editor`'s `TextLineBreak`:
/// `tool_registry.dart` is below the Flutter UI layer and shouldn't
/// pull in `re_editor` just for an enum constant. The editor side
/// translates this to `TextLineBreak` at the call site.
library;

/// Closed enum of line-ending styles we handle. `lf` is the safe
/// default for empty / single-line / unknown content.
enum LineBreakStyle {
  /// Windows-style `\r\n`. Default on most Windows-authored files
  /// when git's `core.autocrlf=true` (the platform default) is in
  /// effect.
  crlf,

  /// Classic Mac-style lone `\r`. Vanishingly rare in modern repos
  /// — supported here only so we don't silently destroy the line
  /// endings of any file that happens to use it.
  cr,

  /// Unix-style `\n`. Most cross-platform repos and the canonical
  /// default for source-controlled code.
  lf,
}

extension LineBreakStyleValue on LineBreakStyle {
  /// The literal characters that separate lines in this style.
  /// Used by [coerceLineBreakStyle] when re-encoding.
  String get value {
    switch (this) {
      case LineBreakStyle.crlf:
        return '\r\n';
      case LineBreakStyle.cr:
        return '\r';
      case LineBreakStyle.lf:
        return '\n';
    }
  }
}

/// Detect the predominant line-ending style of [content].
///
/// Counts CRLF, lone-CR, and lone-LF separately (so a CRLF is not
/// also counted as an LF). The style with the highest count wins.
/// Ties favour CRLF over LF (most common Windows-source-tree case)
/// and LF over CR (CR is essentially extinct).
///
/// Empty / single-line content returns [LineBreakStyle.lf] — the
/// safest default since the file has no line endings to preserve
/// and LF is the canonical cross-platform choice.
LineBreakStyle detectLineBreakStyle(String content) {
  if (content.isEmpty) return LineBreakStyle.lf;
  // CRLF first because we need to subtract its contribution from
  // the lone-LF and lone-CR counters below.
  final crlf = '\r\n'.allMatches(content).length;
  // Lone-LF = total LF minus the LFs that paired with a preceding CR.
  // Lone-CR = total CR minus the CRs that paired with a following LF.
  final totalLf = '\n'.allMatches(content).length;
  final totalCr = '\r'.allMatches(content).length;
  final loneLf = totalLf - crlf;
  final loneCr = totalCr - crlf;
  // Strict majority wins. Ties resolved by the documented tie-break
  // order (CRLF > LF > CR) to keep behaviour deterministic.
  if (crlf >= loneLf && crlf >= loneCr && crlf > 0) {
    return LineBreakStyle.crlf;
  }
  if (loneCr > loneLf) return LineBreakStyle.cr;
  return LineBreakStyle.lf;
}

/// Re-encode [text]'s line endings to [style], normalizing through
/// LF first so any input — pure CRLF, pure CR, pure LF, or any mix
/// thereof — produces a consistently-encoded output.
///
/// The two-pass design (normalize-to-LF then expand-to-target) is
/// intentional: a naive single pass like
/// `text.replaceAll('\n', '\r\n')` would corrupt input that already
/// contained CRLF (turning `\r\n` into `\r\r\n`), which can happen
/// when an agent tool's REPLACE block carries different line endings
/// than the file body.
String coerceLineBreakStyle(String text, LineBreakStyle style) {
  if (text.isEmpty) return text;
  final lf = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  switch (style) {
    case LineBreakStyle.crlf:
      return lf.replaceAll('\n', '\r\n');
    case LineBreakStyle.cr:
      return lf.replaceAll('\n', '\r');
    case LineBreakStyle.lf:
      return lf;
  }
}
