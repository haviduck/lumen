/// Per-model capability flags that the chat layer needs to gate features
/// on. Mirrors the shape of [ReasoningEffortHelper] in
/// `reasoning_effort.dart` deliberately so adding new capabilities later
/// (audio in/out, function-calling, JSON-mode, etc.) follows one
/// consistent pattern: a single `supportsX({provider, rawModel})`
/// static, conservative on uncertainty.
///
/// **Why a separate helper:** the chat composer, the system-prompt
/// builder (`ChatController`), and the tool registry all need to ask
/// the same question ("can the active model see images?"). Putting it
/// next to provider services would mean every caller imports five
/// service files just to ask one question; centralising avoids that.
///
/// **Conservative on purpose:** when in doubt, return false. A false
/// negative just means the user has to manually toggle a feature on
/// for a model we haven't catalogued yet. A false positive means we
/// hand the model an image it can't process — which on most APIs
/// either errors out or, worse, gets silently ignored while the
/// model hallucinates having "seen" something. False negatives are
/// strictly recoverable; false positives are not.
class ModelCapabilities {
  ModelCapabilities._();

  /// True when the model accepts inline image inputs (multimodal
  /// vision). Caller passes the provider tag (e.g. `'claude'`,
  /// `'gemini'`, `'github'`, `'openai'`, `'ollama'`) and the
  /// provider-stripped raw model id (e.g. `'claude-sonnet-4-6'`,
  /// not `'claude:claude-sonnet-4-6'`).
  ///
  /// Used to suppress the chat composer's image-attachment chip on
  /// text-only models so the user doesn't paste an image the model
  /// will silently ignore.
  static bool supportsVision({
    required String provider,
    required String rawModel,
  }) {
    final lower = rawModel.toLowerCase();
    switch (provider) {
      case 'claude':
        // Anthropic: every Claude 3.x and newer is multimodal.
        // 2.x and earlier are text-only but nobody ships those today.
        // Match on the canonical generation tokens to stay
        // future-proof: `claude-3-…`, `claude-sonnet-4-…`,
        // `claude-opus-5-…` etc. all qualify.
        if (lower.contains('claude-3') ||
            lower.contains('opus-4') ||
            lower.contains('sonnet-4') ||
            lower.contains('haiku-4') ||
            lower.contains('opus-5') ||
            lower.contains('sonnet-5') ||
            lower.contains('haiku-5') ||
            lower.contains('opus-4-7') ||
            lower.contains('sonnet-4-6')) {
          return true;
        }
        // Defensive: any newer family name we haven't enumerated
        // probably ships vision too — Anthropic has been
        // multimodal-by-default since 3.0.
        return lower.startsWith('claude-') &&
            !lower.contains('claude-2') &&
            !lower.contains('claude-1');

      case 'gemini':
        // Google: 1.5 + 2.x are all multimodal. The only text-only
        // outliers are the embedding models (`*-embedding-*`) which
        // shouldn't be reaching this path anyway.
        if (lower.contains('embedding')) return false;
        return lower.contains('gemini-1.5') ||
            lower.contains('gemini-2.') ||
            lower.contains('gemini-3.') ||
            // Bare `gemini-pro-vision` etc.
            lower.contains('vision');

      case 'github':
      case 'openai':
        // OpenAI / GitHub Models: gpt-4o family, gpt-4-turbo with
        // vision, gpt-4.1, gpt-5 family, o1/o3/o4 reasoning models
        // (most are multimodal; o1-mini text-only is the exception).
        // GitHub Models prefixes with the publisher
        // (`openai/gpt-4o`), so we substring match.
        if (lower.contains('o1-mini')) return false;
        if (lower.contains('gpt-4o') ||
            lower.contains('gpt-4.1') ||
            lower.contains('gpt-5') ||
            lower.contains('o1-') ||
            lower.contains('o3-') ||
            lower.contains('o4-') ||
            lower.contains('vision')) {
          return true;
        }
        // Microsoft / Mistral / Meta vision-capable entries on
        // GitHub Models; cover the common ones by name.
        if (lower.contains('phi-3.5-vision') ||
            lower.contains('phi-4-multimodal') ||
            lower.contains('llama-3.2') && lower.contains('vision') ||
            lower.contains('pixtral')) {
          return true;
        }
        return false;

      case 'ollama':
        // Ollama: vision support is per-model and we can only guess
        // from the tag. Cover the well-known multimodal families;
        // anything else returns false (user can manually enable the
        // tool from settings if they're running an exotic build).
        if (lower.contains('llava') ||
            lower.contains('bakllava') ||
            lower.contains('moondream') ||
            lower.contains('llama3.2-vision') ||
            lower.contains('llama-3.2-vision') ||
            lower.contains('llama4') ||
            lower.contains('qwen2-vl') ||
            lower.contains('qwen2.5-vl') ||
            lower.contains('qwen3-vl') ||
            lower.contains('minicpm-v') ||
            lower.contains('gemma3') ||
            lower.contains('gemma-3') ||
            lower.contains('mistral-small3.1') ||
            lower.contains('mistral-small-3.1') ||
            lower.contains('-vision') ||
            lower.endsWith(':vision')) {
          return true;
        }
        return false;

      default:
        return false;
    }
  }
}
