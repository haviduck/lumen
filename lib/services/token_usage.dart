/// Cross-provider token-accounting types.
///
/// Each provider service (Anthropic, GitHub Copilot bridge, Gemini,
/// Ollama Cloud, …) reports its own slightly different usage shape:
/// Anthropic ships `input_tokens` + `cache_read_input_tokens` +
/// `output_tokens` on `message_start` / `message_delta` SSE frames,
/// the Copilot SDK emits `session.usage_info` (context-window totals)
/// and `assistant.usage` (per-LLM-call breakdown including
/// reasoning/cache splits), Gemini reports `usageMetadata` on the
/// final chunk, Ollama returns `prompt_eval_count` / `eval_count`.
///
/// [TokenUsage] is the unified shape we forward into [ChatController]
/// so the rest of the app — and the live token-counter chip in the
/// composer — doesn't need to care which provider produced the data.
/// Fields are all optional because no single provider reports every
/// dimension; the accumulator in [ChatSession] adds non-null values
/// and leaves null ones untouched.
library;

/// Where a usage report originated. Used to disambiguate which counter
/// to update — most reports are incremental ("this turn just used N
/// more tokens") but Copilot also emits a "current context window"
/// snapshot that we treat as authoritative for the displayed
/// "tokens in context" gauge.
enum TokenUsageKind {
  /// Incremental: add the numbers in this report to the session's
  /// running totals (the usual case — one API call just completed).
  delta,

  /// Snapshot of the current context window state. The `contextWindow`
  /// / `tokenLimit` fields override the session's stored values rather
  /// than accumulating. Only Copilot emits this today (via
  /// `session.usage_info`). For everyone else we approximate the
  /// context-window state from the running input-token total.
  contextSnapshot,
}

class TokenUsage {
  /// Distinguish "another turn happened, add these numbers" from
  /// "the current context window now holds N tokens".
  final TokenUsageKind kind;

  /// Plain input tokens consumed by this call (system + history +
  /// user message + tool definitions). Excludes anything served from
  /// prompt cache — Anthropic and Copilot both bill those separately.
  final int? inputTokens;

  /// User-visible output tokens (assistant message + tool_use args).
  /// Does NOT include extended-thinking / reasoning tokens; those
  /// land in [reasoningTokens] when the provider exposes them.
  final int? outputTokens;

  /// Tokens served from the provider's prompt cache. Anthropic
  /// `cache_read_input_tokens`, Copilot
  /// `assistant.usage.cacheReadTokens`. These are billed at a
  /// fraction of the regular input rate, which is the whole reason
  /// we surface them separately.
  final int? cacheReadTokens;

  /// Tokens written to the cache during this call (Anthropic
  /// `cache_creation_input_tokens`, Copilot
  /// `assistant.usage.cacheWriteTokens`). Billed slightly above
  /// regular input but the next turn's matching prefix reads back
  /// for ~10x cheaper.
  final int? cacheWriteTokens;

  /// Extended-thinking / chain-of-thought tokens. Anthropic surfaces
  /// these through the `thinking` content blocks; Copilot reports
  /// them as `assistant.usage.reasoningTokens`. Visible to the user
  /// in the chip's tooltip so they can see when the model is
  /// burning silent budget on reasoning.
  final int? reasoningTokens;

  /// Current size of the model's full context window (system + tools
  /// + history + tool definitions). Populated by `contextSnapshot`
  /// reports and used to drive the "X% of context used" gauge.
  final int? contextWindowTokens;

  /// Maximum context size the routed model accepts. Used as the
  /// denominator for the percent-of-window display.
  final int? tokenLimit;

  /// Model id this usage block applies to. Useful when the model
  /// switches mid-session (e.g. user toggles from sonnet to opus
  /// between turns) so the chip can label the snapshot correctly.
  final String? model;

  const TokenUsage({
    this.kind = TokenUsageKind.delta,
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.reasoningTokens,
    this.contextWindowTokens,
    this.tokenLimit,
    this.model,
  });

  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      cacheReadTokens == null &&
      cacheWriteTokens == null &&
      reasoningTokens == null &&
      contextWindowTokens == null &&
      tokenLimit == null;
}

/// Per-session running totals. Persisted on `ChatSession` so a long
/// chat that's already burned N tokens keeps that number visible
/// across app restarts.
///
/// Treated as additive: every [TokenUsage] with kind=delta gets folded
/// in via [merge]. Context-window snapshots OVERWRITE the
/// [contextWindowTokens] / [tokenLimit] fields (those reflect "right
/// now", not "ever").
class SessionTokenStats {
  int inputTokens;
  int outputTokens;
  int cacheReadTokens;
  int cacheWriteTokens;
  int reasoningTokens;
  int? contextWindowTokens;
  int? tokenLimit;

  SessionTokenStats({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
    this.contextWindowTokens,
    this.tokenLimit,
  });

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cacheReadTokens == 0 &&
      cacheWriteTokens == 0 &&
      reasoningTokens == 0 &&
      contextWindowTokens == null;

  /// Total chargeable tokens (input + output + cache-write reasoning).
  /// Cache reads are EXCLUDED because they're billed at a fraction —
  /// surfacing them in the headline number would overstate the cost.
  /// They're still visible in the tooltip breakdown.
  int get billedTotal =>
      inputTokens + outputTokens + cacheWriteTokens + reasoningTokens;

  /// Fraction of the model's context window currently in use, in
  /// [0.0, 1.0]. Null if we don't know the snapshot or the limit.
  double? get contextUtilization {
    final ctx = contextWindowTokens;
    final lim = tokenLimit;
    if (ctx == null || lim == null || lim <= 0) return null;
    return (ctx / lim).clamp(0.0, 1.0);
  }

  /// Fold a single provider report into the running totals. Returns
  /// `true` when anything actually changed (so the caller can skip
  /// `notifyListeners` if a noop).
  bool merge(TokenUsage u) {
    var changed = false;
    if (u.kind == TokenUsageKind.delta) {
      if ((u.inputTokens ?? 0) > 0) {
        inputTokens += u.inputTokens!;
        changed = true;
      }
      if ((u.outputTokens ?? 0) > 0) {
        outputTokens += u.outputTokens!;
        changed = true;
      }
      if ((u.cacheReadTokens ?? 0) > 0) {
        cacheReadTokens += u.cacheReadTokens!;
        changed = true;
      }
      if ((u.cacheWriteTokens ?? 0) > 0) {
        cacheWriteTokens += u.cacheWriteTokens!;
        changed = true;
      }
      if ((u.reasoningTokens ?? 0) > 0) {
        reasoningTokens += u.reasoningTokens!;
        changed = true;
      }
    }
    if (u.contextWindowTokens != null &&
        u.contextWindowTokens != contextWindowTokens) {
      contextWindowTokens = u.contextWindowTokens;
      changed = true;
    }
    if (u.tokenLimit != null && u.tokenLimit != tokenLimit) {
      tokenLimit = u.tokenLimit;
      changed = true;
    }
    return changed;
  }

  Map<String, dynamic> toJson() => {
    'in': inputTokens,
    'out': outputTokens,
    'cr': cacheReadTokens,
    'cw': cacheWriteTokens,
    'rsn': reasoningTokens,
    if (contextWindowTokens != null) 'ctx': contextWindowTokens,
    if (tokenLimit != null) 'lim': tokenLimit,
  };

  factory SessionTokenStats.fromJson(Map<String, dynamic> j) {
    return SessionTokenStats(
      inputTokens: (j['in'] as num?)?.toInt() ?? 0,
      outputTokens: (j['out'] as num?)?.toInt() ?? 0,
      cacheReadTokens: (j['cr'] as num?)?.toInt() ?? 0,
      cacheWriteTokens: (j['cw'] as num?)?.toInt() ?? 0,
      reasoningTokens: (j['rsn'] as num?)?.toInt() ?? 0,
      contextWindowTokens: (j['ctx'] as num?)?.toInt(),
      tokenLimit: (j['lim'] as num?)?.toInt(),
    );
  }
}

/// Callback signature handed to provider services so they can stream
/// usage reports back to [ChatController] without coupling to its
/// type. Implementations should be cheap — they typically just call
/// `stats.merge(u)` + `notifyListeners()`.
typedef TokenUsageCallback = void Function(TokenUsage usage);
