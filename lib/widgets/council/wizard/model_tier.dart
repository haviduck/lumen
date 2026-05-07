/// Classifies model ids into council "speed tiers" and selects a
/// representative model per tier. Lives next to the wizard widgets
/// because the wizard is the only surface that needs preset semantics
/// — the chat picker exposes the raw list.
///
/// Heuristics intentionally permissive: the council currently filters
/// to Claude variants (haiku/sonnet/opus), but the same labels apply
/// cleanly to gpt / gemini families if that filter loosens later.
library;

enum ModelTier { fast, balanced, premium, unknown }

ModelTier modelTier(String id) {
  final l = id.toLowerCase();
  if (l.contains('haiku') ||
      l.contains('flash') ||
      l.contains('mini') ||
      l.contains('nano') ||
      l.contains('gpt-4.1') ||
      l.contains('gpt 4.1')) {
    return ModelTier.fast;
  }
  if (l.contains('opus') ||
      l.contains('gpt-5.5') ||
      l.contains('gpt 5.5') ||
      l.contains('ultra')) {
    return ModelTier.premium;
  }
  if (l.contains('sonnet') ||
      l.contains('gpt-5') ||
      l.contains('gpt 5') ||
      l.endsWith('-pro') ||
      l.contains('-pro-')) {
    return ModelTier.balanced;
  }
  return ModelTier.unknown;
}

/// Pick the best model id from [models] that matches [tier]; if no
/// exact match exists, fall back to the closest neighbour tier so the
/// preset never disables silently.
String? pickModelForTier(ModelTier tier, List<String> models) {
  if (models.isEmpty) return null;
  String? exact;
  for (final m in models) {
    if (modelTier(m) == tier) {
      exact = m;
      break;
    }
  }
  if (exact != null) return exact;
  const fallback = <ModelTier, List<ModelTier>>{
    ModelTier.fast: [ModelTier.balanced, ModelTier.premium],
    ModelTier.balanced: [ModelTier.fast, ModelTier.premium],
    ModelTier.premium: [ModelTier.balanced, ModelTier.fast],
    ModelTier.unknown: [ModelTier.balanced, ModelTier.premium, ModelTier.fast],
  };
  for (final t in fallback[tier] ?? const <ModelTier>[]) {
    for (final m in models) {
      if (modelTier(m) == t) return m;
    }
  }
  return models.first;
}

/// Returns the single shared tier when every entry of [models] (drop
/// nulls/empties) maps to the same tier; otherwise null. Used by the
/// preset bar to highlight the currently-active preset, and to flag
/// individual rows as "overridden" relative to that preset.
ModelTier? activeTierFor(Iterable<String?> models) {
  final tiers = <ModelTier>{};
  for (final m in models) {
    if (m == null || m.isEmpty) continue;
    tiers.add(modelTier(m));
  }
  if (tiers.length == 1) return tiers.first;
  return null;
}
