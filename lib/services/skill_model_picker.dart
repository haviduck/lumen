import 'package:flutter/foundation.dart';

import '../providers/app_state.dart';
import 'ollama_service.dart';

/// Picks the best available model for one-shot **skill / tool
/// generation** runs.
///
/// Skill generation is a single bounded JSON-shaped output — it
/// rewards instruction-following and structured-output reliability
/// far more than streaming speed or local privacy. The user's
/// long-running chat model selection (`AppState.chat.selectedModel`)
/// might be a tiny local Llama tuned for fast iteration; that's the
/// wrong tool for designing workspace skills.
///
/// **Selection rules** (first match wins):
///
/// 1. **Ollama Cloud key set?** Try a hand-tuned preference list of
///    frontier cloud models. The order — Qwen 3 Coder 480B first,
///    then GPT-OSS 120B, then DeepSeek V3.1 — is calibrated for:
///      - **Qwen 3 Coder 480B** is coding-tuned, instruction-strong,
///        JSON-reliable, and the user's stated preference.
///      - **GPT-OSS 120B** is a smaller / faster all-rounder when
///        Qwen isn't in the user's catalog.
///      - **DeepSeek V3.1** is the largest fallback, used only when
///        nothing better is available.
///    The picker queries [OllamaService.getCloudModels] to confirm
///    each candidate is actually present in the user's catalog
///    before locking it in. If none of the preferred models are
///    available but *any* cloud model is, returns the first cloud
///    model — better than dropping all the way back to a local
///    model when the user pasted a cloud key specifically to get
///    cloud generation.
///
/// 2. **No Ollama Cloud key?** Returns the user's currently
///    selected chat model. If they have Gemini / Claude / GitHub
///    configured and one of those models is selected, generation
///    runs through that provider — same path the chat picker
///    already routes. If they're on a small local model that's
///    weak at JSON, the result is on them; we don't second-guess
///    their explicit selection.
///
/// **Format.** The returned string is in `provider:raw` form ready
/// to pass to [ChatController.generateUtilityText] (which splits on
/// the first `:` and routes by provider). For Ollama Cloud the
/// prefix is `ollama-cloud:`, mapping to the cloud-routed code path
/// in [ChatController._fetchModels] / `generateUtilityText`.
///
/// **Caching.** None — this runs at most twice per app session
/// (once in the new-project wizard's skill dialog, once when the
/// user opens the manual skill dialog). The catalog fetch hits the
/// cloud `/api/tags` endpoint with an 8-second timeout; if it
/// stalls, we fall back to the user's selected model so the
/// generator never hangs the wizard.
///
/// Pure async — no widgets touched. Safe to call from any layer.
Future<String> pickSkillModel(AppState state) async {
  final fallback = state.chat.selectedModel;

  if (state.ollamaApiKey.trim().isEmpty) {
    return fallback;
  }

  // Preference order. All three names are the bare cloud catalog
  // identifiers as returned by `OllamaService.getCloudModels`
  // (already stripped of the `-cloud` / `:cloud` suffix). Update
  // this list when Ollama Cloud rolls out new frontier models;
  // the order encodes Lumen's opinion about which makes the best
  // skill-generation engine, not just "biggest first".
  const preferred = <String>[
    'qwen3-coder:480b',
    'gpt-oss:120b',
    'deepseek-v3.1:671b',
  ];

  try {
    final available = await state.ollamaService.getCloudModels();
    if (available.isEmpty) {
      return fallback;
    }
    for (final candidate in preferred) {
      if (available.contains(candidate)) {
        return 'ollama-cloud:$candidate';
      }
    }
    // None of the preferred models present, but the user has a
    // cloud key and some cloud catalog. Better to use whatever
    // cloud model they have than fall back to a local model the
    // user wasn't expecting to run for this. We pick the first
    // entry deterministically; the catalog is small enough
    // (typically <30 models) that "first" is rarely surprising.
    return 'ollama-cloud:${available.first}';
  } catch (e) {
    debugPrint('pickSkillModel: cloud catalog fetch failed: $e');
    return fallback;
  }
}

/// Inspect the picked model and return a short, user-facing label
/// describing what'll be used. The skill dialogs surface this as a
/// muted footer line so the user understands why the generation may
/// take longer than a local-model run, and so a wrong selection is
/// visible before kicking off a multi-second generation.
///
/// Format examples:
///   - `'Qwen 3 Coder 480B (Ollama Cloud)'`
///   - `'GPT-OSS 120B (Ollama Cloud)'`
///   - `'gemini:gemini-2.5-pro'` (raw — provider not in our pretty
///     map)
String describeSkillModel(String pickedModel) {
  if (pickedModel.startsWith('ollama-cloud:')) {
    final raw = pickedModel.substring('ollama-cloud:'.length);
    return '${_prettyOllamaCloudName(raw)} (Ollama Cloud)';
  }
  return pickedModel;
}

String _prettyOllamaCloudName(String raw) {
  switch (raw) {
    case 'qwen3-coder:480b':
      return 'Qwen 3 Coder 480B';
    case 'gpt-oss:120b':
      return 'GPT-OSS 120B';
    case 'deepseek-v3.1:671b':
      return 'DeepSeek V3.1 671B';
    default:
      return raw;
  }
}
