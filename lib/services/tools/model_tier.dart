/// Capability-tier classifier for routed (provider, model) pairs.
///
/// Lumen's tool surface is large (~25 tools, several with multi-hunk
/// bodies). Strong frontier models (Claude Opus 4.7, GPT-5, Gemini
/// 2.5 Pro, GPT-OSS 120B, Qwen3-Coder 480B) handle every tool
/// reliably. Smaller / older models — especially local 7-13B Ollama
/// models — struggle with the more complex tools (MULTI_EDIT with
/// nested SEARCH/REPLACE blocks, long EDIT_FILE bodies) and tend to
/// loop on near-misses. The fix is **not** to make the parser more
/// lenient; it's to reduce the surface that fits the model's
/// reliable working set.
///
/// We don't need a precise model-by-model lookup table. Heuristics
/// over (provider, raw model name) + the Ollama capability cache
/// give us 95% of the right answer and degrade gracefully for
/// unknown models.
///
/// **Tiers (high → low):**
/// - **Pro** — full 25-tool surface. Frontier hosted models, large
///   cloud Ollama (gpt-oss:120b, qwen3-coder:480b, deepseek-v3.1:671b).
/// - **Standard** — 12-tool curated subset. Mid-size capable models
///   (local 30-70B with tools support, GPT-4o-mini-class).
/// - **Lite** — 8-tool subset, MULTI_EDIT replaced with EDIT_FILE
///   only. Small tool-capable models (8-13B Llama / Qwen).
/// - **Legacy** — 6-tool minimum, text-grammar fallback path. Models
///   without the `tools` capability (Gemma 2, very old Llama, etc.).
library;

/// Classification verdict for a (provider, model) pair.
class ModelTier {
  final ModelTierLevel level;

  /// Tool ids permitted at this tier. The chat controller intersects
  /// this with `_enabledTools` so user toggles still apply.
  final Set<String> allowedToolIds;

  const ModelTier._(this.level, this.allowedToolIds);

  /// All registered tools — Pro tier surface.
  static const _pro = <String>{
    'create_file',
    'edit_file',
    'multi_edit',
    'edit_range',
    'append_file',
    'move_file',
    'copy_file',
    'delete_file',
    'read_file',
    'list_dir',
    'tree',
    'search_text',
    'find_file',
    'glob',
    'git_status',
    'git_diff',
    'git_log',
    'git_blame',
    'check_url',
    'run_cmd',
    'verify',
    'web_search',
    'web_fetch',
  };

  static const _standard = <String>{
    'create_file',
    'edit_file',
    'multi_edit',
    'append_file',
    'delete_file',
    'read_file',
    'list_dir',
    'tree',
    'search_text',
    'glob',
    'git_status',
    'git_diff',
    'check_url',
    'run_cmd',
    'verify',
  };

  static const _lite = <String>{
    'create_file',
    'edit_file',
    'append_file',
    'read_file',
    'list_dir',
    'search_text',
    'glob',
    'run_cmd',
    'verify',
  };

  static const _legacy = <String>{
    'create_file',
    'edit_file',
    'read_file',
    'list_dir',
    'search_text',
    'run_cmd',
  };

  static const ModelTier pro = ModelTier._(ModelTierLevel.pro, _pro);
  static const ModelTier standard = ModelTier._(
    ModelTierLevel.standard,
    _standard,
  );
  static const ModelTier lite = ModelTier._(ModelTierLevel.lite, _lite);
  static const ModelTier legacy = ModelTier._(ModelTierLevel.legacy, _legacy);

  /// Classify a (provider, raw model, capabilities) tuple.
  ///
  /// [capabilities] is the result of [OllamaService.getModelCapabilities]
  /// for Ollama-routed models, empty for hosted providers (which
  /// always support tools natively at the API level — the tier
  /// decision there is purely about the model's reasoning capacity).
  ///
  /// The classifier is deliberately tolerant: unknown Ollama models
  /// land at Standard if `capabilities.contains('tools')`, Legacy
  /// otherwise. Frontier hosted models default to Pro. Mini /
  /// haiku / nano variants drop to Standard because they routinely
  /// trip on MULTI_EDIT.
  static ModelTier classify({
    required String provider,
    required String rawModel,
    required Set<String> capabilities,
  }) {
    final m = rawModel.toLowerCase();
    switch (provider) {
      case 'claude':
        // Opus / Sonnet 4.x → Pro. Haiku → Standard.
        if (m.contains('haiku')) return standard;
        return pro;
      case 'gemini':
        if (m.contains('flash-lite') || m.contains('nano')) return standard;
        if (m.contains('flash')) return pro; // 2.5 Flash handles all tools.
        return pro;
      case 'copilot':
        // OpenAI-shaped catalog. mini / nano → Standard, rest → Pro.
        if (m.contains('mini') || m.contains('nano')) return standard;
        if (m.startsWith('openai/') || m.startsWith('xai/')) return pro;
        return pro;
      case 'ollama-cloud':
        // Cloud namespace covers a mix of true flagships
        // (gpt-oss:120b, qwen3-coder:480b, deepseek-v3.1:671b) AND
        // smaller mid-size models that ollama.com has started
        // hosting (e.g. gemma4:31b). Old assumption was "cloud =
        // flagship" → blanket Pro; reality says we still need the
        // param-count tier here. Models without an explicit `:Nb`
        // suffix default to Pro because the only such names today
        // ARE the flagship cloud-only entries (no installed-tag
        // ambiguity that local has).
        final cloudParams = _extractParamBillion(m);
        if (cloudParams == null) return pro;
        if (cloudParams >= 60) return pro;
        if (cloudParams >= 20) return standard;
        return lite;
      case 'ollama':
      default:
        if (!capabilities.contains('tools')) return legacy;
        // Tool-capable local models. Tier on parameter-count
        // heuristic in the model name — Ollama tags follow
        // `<family>:<paramCount>b` (e.g. `qwen2.5:7b`,
        // `llama3.1:70b`) so we can read the size off the tag
        // for most models.
        final params = _extractParamBillion(m);
        if (params == null) return standard;
        if (params >= 60) return pro;
        if (params >= 20) return standard;
        return lite;
    }
  }

  /// Extracts the parameter count (in billions) from an Ollama
  /// model tag like `qwen2.5:7b`, `llama3.1:70b`, `deepseek-r1:32b`.
  /// Returns null when the tag doesn't carry a `:Nb` suffix.
  static double? _extractParamBillion(String rawModel) {
    final m = RegExp(r':(\d+(?:\.\d+)?)b\b').firstMatch(rawModel);
    if (m == null) return null;
    return double.tryParse(m.group(1)!);
  }
}

enum ModelTierLevel { pro, standard, lite, legacy }
