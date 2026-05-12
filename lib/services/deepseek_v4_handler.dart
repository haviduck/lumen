/// DeepSeek V4 model-family handler — defensive routing for a model
/// that ships **catastrophic** defaults for a coding agent.
///
/// ## Why this file exists
///
/// DeepSeek V4 (released April 2026, two open-weight MoE variants:
/// `deepseek-v4-pro` at 1.6T/49B active and `deepseek-v4-flash` at
/// 284B/13B active) has two documented failure modes that hit Lumen
/// hard if we use it like any other model:
///
/// 1. **94% hallucination rate on AA-Omniscience.** The model almost
///    never abstains when uncertain — it confabulates instead. This
///    is a *knowledge-domain* failure mode but it bleeds into code
///    work because the model will happily emit phantom imports,
///    plausible-looking but non-existent API signatures, and
///    invented file paths.
///
/// 2. **Non-Think mode is unusable for coding.** LiveCodeBench Pass@1
///    drops from **93.5% in Think Max** to **56.8% in Non-Think**.
///    Whatever the API's default thinking mode is, "let the model
///    decide" gives us the bad answer most of the time on this
///    family.
///
/// On top of that the model is documented as "highly verbose" with
/// "overthinking" tendencies, especially in heavy code refactoring,
/// so we also rein in the preamble noise.
///
/// ## What this handler does
///
/// * [isDeepseekV4] — detect the model family across every namespacing
///   convention V4 actually ships under (direct API ids, Ollama Cloud
///   tags with size suffixes, the `-cloud` proxy suffix, future
///   third-party rehosts).
/// * [coercedEffort] — enforce a Think-High floor. "Off" is silently
///   coerced to "Standard" when the active model is V4; the controller
///   surfaces a one-line console warn so the user can see why their
///   "no thinking please" dial didn't take.
/// * [thinkingPayload] — the OpenAI-compatible request fragment
///   (`{thinking: {type, budget_tokens?}, reasoning_effort?}`) keyed
///   off the pill setting. Works for both direct DeepSeek API and
///   any provider proxying the OpenAI Chat Completions wire format.
/// * [antiHallucinationDirective] — system-prompt block that gives
///   the model **explicit permission to abstain**. The 94% AA-Omniscience
///   failure is a behavioural choice (no abstention) more than a
///   capability gap, so a permission line + a hard "no phantom imports"
///   rule moves the needle without changing temperature or sampling.
///
/// The handler is intentionally a **pure-Dart helper with no Flutter
/// dependency** so the council unit tests and the chat unit tests can
/// both pull it in without spinning up a widget binding.
library;

import 'reasoning_effort.dart';

/// Categorises whether a turn is "coding work" so the handler can
/// pick the right ceiling. Plumbed in from the chat controller's
/// per-turn context (active file extension, enabled tool surface,
/// prompt content), not auto-detected here — keeping detection out
/// of this file lets the unit tests stay deterministic.
enum DeepseekV4TaskKind {
  /// File edits, code review, refactoring, debugging. Hard floor
  /// is Think High (budget_tokens 8192). Deep escalates to Think
  /// Max (no explicit budget — model uses its 384K output ceiling).
  coding,

  /// Anything else (chat, writing, research, planning). Same hard
  /// floor as coding because Non-Think is the documented unusable
  /// mode regardless of domain, but the budget is tighter
  /// (budget_tokens 4096) since the failure modes are less
  /// catastrophic outside code.
  general,
}

class DeepseekV4Handler {
  DeepseekV4Handler._();

  /// True when [rawModel] is a DeepSeek V4 family member (Pro or
  /// Flash, any variant).
  ///
  /// Patterns we handle (all case-insensitive):
  ///
  /// * **Direct DeepSeek API** (`api.deepseek.com`):
  ///   - `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-v4`
  ///
  /// * **Legacy aliases** that DeepSeek's docs say currently point
  ///   to V4 (until 2026-07-24 cutover):
  ///   - `deepseek-chat` → `deepseek-v4-flash` (non-thinking)
  ///   - `deepseek-reasoner` → `deepseek-v4-flash` (thinking)
  ///   We detect them so the floor + abstention prompt still
  ///   apply during the migration window. Past cutover they hard-fail
  ///   on DeepSeek's side anyway.
  ///
  /// * **Ollama Cloud tags** (when DeepSeek V4 lands there alongside
  ///   the existing `deepseek-v3.1:671b-cloud`):
  ///   - `deepseek-v4-pro:1.6t`, `deepseek-v4-flash:284b`,
  ///   - same with `-cloud` suffix that Ollama's local daemon
  ///     proxies cloud pulls under.
  ///
  /// * **Unprefixed param-count variants** the open-weight release
  ///   makes inevitable on community rehosts:
  ///   - `deepseek-v4:284b`, `deepseek-v4:1.6t`, `deepseek-v4:13b`,
  ///     `deepseek-v4:49b` (active params), etc.
  ///
  /// Conservative on uncertainty: an `deepseek-v3.x` tag returns
  /// false, an unrelated `deepseek-coder-v2:33b` returns false. The
  /// substring is anchored on the literal `deepseek-v4` token so we
  /// don't false-positive on `-v4-style` or `v4o` variants.
  static bool isDeepseekV4(String rawModel) {
    if (rawModel.isEmpty) return false;
    final lower = rawModel.toLowerCase().trim();
    if (lower.contains('deepseek-v4')) return true;
    if (lower == 'deepseek-chat' || lower == 'deepseek-reasoner') return true;
    return false;
  }

  /// True when [rawModel] is specifically the larger Pro variant.
  /// Pro has 1.6T total params (49B active) and a 384K-token output
  /// ceiling that makes Think Max viable for it; Flash maxes out at
  /// 284B (13B active) and Think Max is more expensive than
  /// proportional accuracy gain on Flash. Used by [thinkingPayload]
  /// to scale `budget_tokens` between variants.
  static bool isDeepseekV4Pro(String rawModel) {
    if (rawModel.isEmpty) return false;
    final lower = rawModel.toLowerCase();
    return lower.contains('deepseek-v4-pro') ||
        lower.contains('deepseek-v4:1.6t') ||
        lower.contains('deepseek-v4:49b');
  }

  /// Enforce a Think-High floor for V4. Returns the effective effort
  /// to use on this turn given the user's pill setting [requested].
  ///
  /// Mapping:
  ///   * Off       → Standard (silently coerced; see [floorCoerced])
  ///   * Standard  → Standard
  ///   * Deep      → Deep
  ///
  /// Pure function — the controller decides what to do with
  /// [floorCoerced] separately (warn the user once per session,
  /// surface in the inspector, etc.).
  static ReasoningEffort coercedEffort(ReasoningEffort requested) {
    return switch (requested) {
      ReasoningEffort.off => ReasoningEffort.standard,
      ReasoningEffort.standard => ReasoningEffort.standard,
      ReasoningEffort.deep => ReasoningEffort.deep,
    };
  }

  /// True when [requested] would have been dropped below the floor.
  /// The controller uses this to emit a one-line console warn so the
  /// user understands their dial was overridden.
  static bool floorCoerced(ReasoningEffort requested) =>
      requested == ReasoningEffort.off;

  /// OpenAI-compatible thinking-mode payload keyed off the (coerced)
  /// effort and the task kind. Shape mirrors what `api.deepseek.com`
  /// accepts on `POST /chat/completions`:
  ///
  /// ```jsonc
  /// {
  ///   "thinking": { "type": "enabled", "budget_tokens": 8192 },
  ///   "reasoning_effort": "high"
  /// }
  /// ```
  ///
  /// Caller is responsible for splatting this into `extra_body` (for
  /// the OpenAI SDK shape) or merging it directly into the request
  /// JSON for raw HTTP clients. Returns `null` only when [effort] is
  /// `Off` AND the floor was disabled by the caller (we don't enable
  /// the floor for non-V4 models in this helper — that's the
  /// controller's job via [coercedEffort]).
  ///
  /// Budgets:
  ///   * coding   + standard → 8192   (Think High default)
  ///   * coding   + deep     → 32768  (Think Max-ish; Pro can take more)
  ///   * general  + standard → 4096
  ///   * general  + deep     → 16384
  ///
  /// On Flash variant the deep budget is clamped to 16384 even for
  /// coding, since Flash's 284B params don't extract the same marginal
  /// accuracy from extended reasoning that Pro does. Empirically
  /// (DeepSeek's own benchmark table) Flash gains <2% on coding above
  /// 16K thinking tokens — the extra spend isn't justified.
  static Map<String, dynamic>? thinkingPayload({
    required ReasoningEffort effort,
    required DeepseekV4TaskKind taskKind,
    required String rawModel,
  }) {
    if (effort == ReasoningEffort.off) {
      // Caller should have run [coercedEffort] first. We honour
      // an explicit Off pass-through here as a "really, no thinking"
      // escape hatch for debugging / cost-bounded probes.
      return <String, dynamic>{
        'thinking': <String, dynamic>{'type': 'disabled'},
      };
    }

    final isPro = isDeepseekV4Pro(rawModel);
    final budget = switch ((taskKind, effort)) {
      (DeepseekV4TaskKind.coding, ReasoningEffort.standard) => 8192,
      (DeepseekV4TaskKind.coding, ReasoningEffort.deep) => isPro ? 32768 : 16384,
      (DeepseekV4TaskKind.general, ReasoningEffort.standard) => 4096,
      (DeepseekV4TaskKind.general, ReasoningEffort.deep) => 16384,
      _ => 8192,
    };

    return <String, dynamic>{
      'thinking': <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': budget,
      },
      // `reasoning_effort` is a parallel knob the V4 API accepts;
      // `high` corresponds to extended thinking. The two fields are
      // redundant but DeepSeek's own docs ship both in their Python
      // examples, and some proxies (Ollama Cloud, Anthropic-compat
      // surface) honour one but not the other.
      'reasoning_effort': effort == ReasoningEffort.deep ? 'high' : 'medium',
    };
  }

  /// System-prompt block that gives the model explicit permission to
  /// abstain and bans phantom imports. Injected by the system prompt
  /// builder when [isDeepseekV4] is true. Returns an empty string
  /// when [enabled] is false so the builder can conditionally append
  /// without nullable-string juggling.
  ///
  /// Wording deliberately avoids hedging vocabulary the model would
  /// optimise around ("be more careful", "double-check"). Instead it
  /// names the failure mode (94% hallucination on knowledge gaps)
  /// and gives the model a clear out: "I don't know" is a valid
  /// answer, calling a tool is a better one.
  static String antiHallucinationDirective({bool enabled = true}) {
    if (!enabled) return '';
    return '''

## Model-specific guardrail (DeepSeek V4)
You are running on the DeepSeek V4 family. Two rules override your
default behaviour for this session:

1. **Abstention is allowed and preferred over confabulation.** When
   you do not know something — a file path, an API signature, a
   library version, a project convention — say so explicitly OR call
   a tool to find out. Do NOT invent plausible-looking answers. This
   is the single highest-impact behaviour change for your output
   quality.

2. **No phantom symbols in code.** Every import, function call, type,
   or file path you reference in an edit MUST already exist in the
   workspace or in a library you can verify. If you are not sure it
   exists, read the file or run a search BEFORE writing the code that
   references it. Phantom imports are the #1 hallucination pattern on
   this model family.

3. **Be terse.** Skip the "I'll start by understanding…" preambles.
   Open with the action: read the file, then explain. Long preambles
   correlate with overthinking on heavy refactoring tasks for this
   model.
''';
  }
}
