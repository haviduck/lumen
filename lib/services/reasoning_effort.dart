/// How much "thinking" the model should do before its first user-visible
/// token. Three-level dial exposed in the chat composer next to
/// auto-approve. Per chat session (like the model picker), defaults to
/// [ReasoningEffort.standard] on new sessions and on legacy sessions
/// loaded from disk that pre-date this field.
///
/// Two distinct mechanisms are in play, picked based on the active model:
///
/// 1. **Native reasoning APIs** when supported. Each frontier provider
///    has a real API knob that allocates internal "thinking" tokens
///    before the model emits user-visible output:
///      - Anthropic (Claude Opus 4+, Sonnet 4+): `thinking.budget_tokens`
///      - OpenAI / GitHub Models (gpt-5 family, o-series): `reasoning_effort`
///      - Google Gemini (2.5 family): `generationConfig.thinkingConfig.thinkingBudget`
///    These actually change how the model works — slower + more expensive,
///    measurably more careful.
///
/// 2. **Prompt-suffix fallback** for providers/models without a native
///    knob (older OpenAI models, Claude Haiku, Gemini 2.0). A short
///    directive is appended to the system prompt instructing the model
///    to be more thorough. Less effective than (1) but better than
///    nothing — and that's the entire reason this enum/helper exists
///    rather than a plain prompt-suffix toggle: hiding the
///    implementation behind one Off/Standard/Deep dial gives consistent
///    UX regardless of provider.
///
/// **Ollama / Ollama Cloud is no longer in the prompt-suffix path.**
/// As of v1.4.x, Ollama auto-enables thinking server-side for capable
/// models (per https://docs.ollama.com/capabilities/thinking — "Thinking
/// is enabled by default in the CLI and API for supported models") and
/// we deliberately omit `think` from the wire payload. The composer
/// pill is hidden on Ollama models (see
/// `ChatController.reasoningEffortPillApplicableForCurrentModel`) and
/// `ChatController._runGenerationLoop` forces `effort = null` for
/// Ollama turns so a stale value carried over from a Claude/Gemini
/// turn doesn't leak into the Ollama prompt. [modelSupportsNative]
/// still returns `false` for Ollama (it really doesn't take a native
/// param) — the suppression happens one layer up.
///
/// The composer pill picks the right mechanism automatically — see
/// [ReasoningEffortHelper.modelSupportsNative] and
/// [ReasoningEffortHelper.promptDirectiveFor].
enum ReasoningEffort {
  off,
  standard,
  deep,
}

/// Stable serialisation tokens for persistence. Don't rename — these
/// land in `<session>.json` on disk.
extension ReasoningEffortIds on ReasoningEffort {
  String get id => switch (this) {
        ReasoningEffort.off => 'off',
        ReasoningEffort.standard => 'standard',
        ReasoningEffort.deep => 'deep',
      };
}

ReasoningEffort reasoningEffortFromId(String? id) => switch (id) {
      'off' => ReasoningEffort.off,
      'deep' => ReasoningEffort.deep,
      _ => ReasoningEffort.standard,
    };

class ReasoningEffortHelper {
  /// True if [rawModel] (provider-stripped, e.g. `claude-sonnet-4-6`,
  /// not `claude:claude-sonnet-4-6`) accepts a native reasoning param
  /// on its provider's API. Used by services to know whether to add
  /// API params, and by the controller to decide whether to emit the
  /// prompt-suffix fallback.
  ///
  /// Conservative on purpose — when in doubt, return false and let
  /// the prompt-suffix path handle it. False positives here would mean
  /// sending an API param the model rejects, which surfaces as a 400
  /// to the user; false negatives just mean we leave a knob unused.
  static bool modelSupportsNative({
    required String provider,
    required String rawModel,
  }) {
    final lower = rawModel.toLowerCase();
    switch (provider) {
      case 'claude':
        // Extended thinking lives on Claude Opus 4+ and Sonnet 4+.
        // Haiku does not support it. Older 3.x models don't either.
        if (lower.contains('haiku')) return false;
        return lower.contains('opus-4') ||
            lower.contains('sonnet-4') ||
            lower.contains('opus-5') ||
            lower.contains('sonnet-5');
      case 'gemini':
        // 2.5 family ships thinkingConfig. 2.0 doesn't.
        return lower.contains('2.5');
      case 'github':
      case 'openai':
        // gpt-5 family + o-series accept reasoning_effort. Older
        // chat models (gpt-4o, gpt-4.1) don't. The provider id may
        // include a publisher prefix on GitHub Models
        // (`openai/gpt-5-mini`); we just substring-match.
        if (lower.contains('gpt-5')) return true;
        if (lower.contains('o1-') ||
            lower.contains('o3-') ||
            lower.contains('o4-')) {
          return true;
        }
        return false;
      case 'ollama':
      default:
        return false;
    }
  }

  /// Prompt-suffix block to inject into the system prompt when the
  /// active model has no native reasoning knob. Empty string for
  /// [ReasoningEffort.off] and (by caller convention) for native-supporting
  /// models — when both can run, we trust the native knob and skip the
  /// suffix to avoid double-incentivising verbosity.
  static String promptDirectiveFor(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.off:
        return '';
      case ReasoningEffort.standard:
        return '''
## Reasoning effort: standard
Take a moment before answering. Briefly think through the request,
identify obvious risks or edge cases, and verify your answer is
internally consistent before producing it. If you make file changes,
double-check that any SEARCH text exists in the file BEFORE you emit
the EDIT_FILE block — wrong SEARCH = wasted round trip.''';
      case ReasoningEffort.deep:
        return '''
## Reasoning effort: deep
Slow down and think carefully before answering. Specifically:
- Restate the user's goal in your head and confirm it before acting.
- Consider at least two approaches and pick the better one with a
  one-sentence justification.
- Spot-check assumptions (file paths, existing code, library APIs)
  with reads/searches BEFORE editing — don't guess.
- After substantive edits, run GIT_STATUS / GIT_DIFF and skim the
  result. If something looks off, fix it BEFORE replying.
- For non-trivial tasks, briefly summarize what you did and what
  could still be wrong so the user can sanity-check.''';
    }
  }

  /// OpenAI / GitHub Models style `reasoning_effort` value. Matches
  /// the public API ("low" | "medium" | "high"). Returns null for
  /// [ReasoningEffort.off] — caller should omit the field entirely.
  static String? openAiEffortValue(ReasoningEffort effort) {
    return switch (effort) {
      ReasoningEffort.off => null,
      ReasoningEffort.standard => 'medium',
      ReasoningEffort.deep => 'high',
    };
  }

  /// Anthropic `thinking.budget_tokens` — **legacy** explicit-budget
  /// shape used by Opus 4.0 / 4.5 / 4.6 and Sonnet 4.0 / 4.5 / 4.6.
  /// Returns null for [off] (caller should omit the `thinking` block
  /// entirely). Min budget is 1024 per Anthropic's docs; we pick
  /// comfortable defaults that are well under the model's `max_tokens`
  /// ceiling so the response itself doesn't get starved.
  ///
  /// **Do not use this for Opus 4.7+** — those models require the
  /// adaptive shape (see [usesAdaptiveThinking] /
  /// [anthropicAdaptiveEffort]). Sending `thinking.type.enabled` to
  /// Opus 4.7 returns a 400.
  static int? anthropicBudget(ReasoningEffort effort) {
    return switch (effort) {
      ReasoningEffort.off => null,
      ReasoningEffort.standard => 4096,
      ReasoningEffort.deep => 16384,
    };
  }

  /// True when [rawModel] uses Anthropic's **adaptive** extended-thinking
  /// API (`thinking: {type: "adaptive"}` + `output_config.effort`),
  /// introduced with Claude Opus 4.7 (April 2026). The legacy
  /// `thinking.type.enabled` + `budget_tokens` shape is rejected with a
  /// 400 on these models.
  ///
  /// Match list is intentionally explicit rather than "anything past
  /// 4.6" — Anthropic's model-id versioning is non-monotonic enough
  /// (Sonnet 4.5 shipped between Opus 4.5 and Opus 4.6) that a
  /// substring on `>= 4.7` is a footgun. Add new families here as they
  /// land. Conservative on uncertainty: an unknown model gets the
  /// legacy shape, which still works on every pre-4.7 Claude.
  static bool usesAdaptiveThinking({required String rawModel}) {
    final lower = rawModel.toLowerCase();
    if (lower.contains('haiku')) return false;
    return lower.contains('opus-4-7') ||
        lower.contains('opus-5') ||
        lower.contains('sonnet-4-7') ||
        lower.contains('sonnet-5');
  }

  /// Anthropic adaptive `output_config.effort` value. Returns null for
  /// [off] — caller should also omit the `thinking` block in that case
  /// to get the model's natural baseline behaviour without paying
  /// for any extended-thinking tokens.
  ///
  /// The mapping reflects what the dial *means* to the user:
  ///   - standard → `medium` ("the model uses moderate thinking; may
  ///     skip thinking for simple queries"). Anthropic's recommended
  ///     default-tradeoff for Opus 4.7 workloads.
  ///   - deep     → `xhigh` ("always thinks deeply with extended
  ///     exploration", Opus 4.7-only). `high` is already the model's
  ///     baseline, so picking `high` for the user's "Deep" toggle
  ///     would be a no-op.
  static String? anthropicAdaptiveEffort(ReasoningEffort effort) {
    return switch (effort) {
      ReasoningEffort.off => null,
      ReasoningEffort.standard => 'medium',
      ReasoningEffort.deep => 'xhigh',
    };
  }

  /// Gemini `thinkingConfig.thinkingBudget`. -1 = dynamic (model picks
  /// the budget itself), 0 = disabled, positive = explicit cap.
  ///
  /// We use -1 for [deep] so Gemini sizes the budget itself — the
  /// absolute budget caps differ per model (32k on 2.5-pro, 24k on
  /// 2.5-flash) and we don't ship per-model logic just for this.
  /// Returns null when the field should be omitted entirely (e.g.
  /// 2.5-pro can't disable thinking, so [off] returns null there;
  /// callers must check both [modelSupportsNative] and the model id
  /// before applying).
  static int? geminiBudget(ReasoningEffort effort, {required String rawModel}) {
    final lower = rawModel.toLowerCase();
    switch (effort) {
      case ReasoningEffort.off:
        // gemini-2.5-pro can't be told 0 — minimum is 128. Skip the
        // field on pro for "off" (model's natural baseline) instead
        // of 400-erroring.
        if (lower.contains('pro')) return null;
        return 0;
      case ReasoningEffort.standard:
        return 4096;
      case ReasoningEffort.deep:
        return -1;
    }
  }
}
