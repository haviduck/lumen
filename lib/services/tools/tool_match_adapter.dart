/// `Match` adapter for the native tool-calling bridge.
///
/// Lumen's tool implementations (`tool_registry.dart`) are written
/// against [RegExpMatch] instances and reach for `match.group(N)`
/// to extract args. The native tool-calling path, however, gets
/// arguments as a parsed JSON map — there's no underlying string
/// to regex against.
///
/// Rather than rewriting every tool body to take a `Map<String, dynamic>`,
/// we synthesize a [Match] from the JSON args using each tool's
/// [ToolSchema.toGroups] mapping. This adapter implements the
/// [Match] interface with a fixed group list so existing tool
/// bodies work unchanged.
///
/// Note: implements [Match], NOT [RegExpMatch]. `RegExpMatch` adds a
/// `pattern` field whose value would have to be a real RegExp; we
/// don't have one. Tool bodies only consume the [Match] API
/// (`group`, `groupCount`, `[]`), so this is sufficient.
library;

/// Synthetic [Match] backed by an args-derived group list. Read-only.
class SyntheticMatch implements Match {
  /// Reconstructed full-match text — what `group(0)` returns. Tool
  /// bodies rarely consult this, but the executor's
  /// `_friendlyReplacement` does (for `replaceAll`), so we synthesize
  /// a plausible `<<<TOOL: …>>>` to keep that path readable.
  final String rawText;

  /// Groups in regex-capture order (the [Match] API exposes these
  /// as 1-indexed via `group(1)`, `group(2)`, …). Each entry can
  /// be null when the original regex would have produced a null
  /// capture (optional groups).
  final List<String?> _groups;

  SyntheticMatch({required this.rawText, required List<String?> groups})
      : _groups = groups;

  @override
  String? group(int idx) {
    if (idx == 0) return rawText;
    if (idx < 1 || idx > _groups.length) return null;
    return _groups[idx - 1];
  }

  @override
  String? operator [](int idx) => group(idx);

  @override
  int get groupCount => _groups.length;

  @override
  List<String?> groups(List<int> ids) {
    return [for (final i in ids) group(i)];
  }

  @override
  int get start => 0;

  @override
  int get end => rawText.length;

  @override
  String get input => rawText;

  /// Synthetic [Pattern] — the Match interface requires one. We can't
  /// reconstruct the original regex from JSON args; instead we
  /// expose a sentinel pattern that would match the [rawText]
  /// exactly if anyone ever tried to use it. In practice, tool
  /// bodies never read `match.pattern`, so this is purely
  /// interface-completeness.
  @override
  Pattern get pattern => RegExp(RegExp.escape(rawText));
}
