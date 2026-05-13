// Unit tests for `DeepseekV4Handler` — the defensive-routing layer
// that enforces a Think-High floor and ships anti-hallucination
// directives whenever DeepSeek V4 is the active model.
//
// What's pinned here:
//
//   1. Detection covers every variant V4 actually ships under (direct
//      API ids, legacy aliases inside the migration window, Ollama
//      Cloud tags, community param-count tags, the `-cloud` proxy
//      suffix Ollama uses for cloud pulls).
//   2. Non-V4 ids never false-positive — V3.x, qwen3-coder, gpt-5,
//      claude-opus-* all stay out.
//   3. Pill coercion: only `Off` is lifted to `Standard`; the higher
//      tiers pass through untouched.
//   4. Thinking-payload shape matches the OpenAI-compatible wire
//      format DeepSeek's docs publish (`{thinking: {type,
//      budget_tokens?}, reasoning_effort}`).
//   5. Budget scaling — Pro variant accepts the larger deep budget,
//      Flash is clamped because the marginal accuracy gain doesn't
//      justify the extra spend.
//
// Pure-Dart suite (no Flutter binding) so it runs as part of the
// fast service test pass.

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/deepseek_v4_handler.dart';
import 'package:lumen/services/reasoning_effort.dart';

void main() {
  group('DeepseekV4Handler.isDeepseekV4', () {
    test('direct DeepSeek API ids', () {
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4-pro'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4-flash'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4'), isTrue);
    });

    test('case-insensitive + whitespace tolerant', () {
      expect(DeepseekV4Handler.isDeepseekV4('DeepSeek-V4-Pro'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('  deepseek-v4-flash  '), isTrue);
    });

    test('legacy aliases that currently point to V4', () {
      // Per DeepSeek's docs (until 2026-07-24 cutover), `deepseek-chat`
      // routes to V4-Flash non-thinking and `deepseek-reasoner` routes
      // to V4-Flash thinking. The floor needs to apply during the
      // migration window.
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-chat'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-reasoner'), isTrue);
    });

    test('Ollama Cloud tag variants', () {
      expect(
        DeepseekV4Handler.isDeepseekV4('deepseek-v4-pro:1.6t-cloud'),
        isTrue,
      );
      expect(
        DeepseekV4Handler.isDeepseekV4('deepseek-v4-flash:284b-cloud'),
        isTrue,
      );
      expect(
        DeepseekV4Handler.isDeepseekV4('deepseek-v4-pro:1.6t'),
        isTrue,
      );
    });

    test('community param-count rehosts', () {
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4:49b'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4:13b'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v4:1.6t'), isTrue);
    });

    test('NON-V4 DeepSeek models stay out', () {
      // V3.x is good behaviour — no floor, no abstention prompt.
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-v3.1:671b'), isFalse);
      expect(
        DeepseekV4Handler.isDeepseekV4('deepseek-v3.2:671b-cloud'),
        isFalse,
      );
      // R1 is a separate reasoning family pre-V4. Different mode set.
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-r1:32b'), isFalse);
      // V2 coder is a code model from the V2 era.
      expect(DeepseekV4Handler.isDeepseekV4('deepseek-coder-v2:33b'), isFalse);
    });

    test('completely unrelated models stay out', () {
      expect(DeepseekV4Handler.isDeepseekV4('gpt-5'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4('claude-opus-4-7'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4('qwen3-coder:480b'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4('gpt-oss:120b'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4('llama3.1:70b'), isFalse);
    });

    test('empty / whitespace-only', () {
      expect(DeepseekV4Handler.isDeepseekV4(''), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4('   '), isFalse);
    });
  });

  group('DeepseekV4Handler.isDeepseekV4Pro', () {
    test('canonical Pro ids', () {
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4-pro'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4Pro('DeepSeek-V4-Pro'), isTrue);
      expect(
        DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4-pro:1.6t-cloud'),
        isTrue,
      );
    });

    test('Pro param-count rehosts (1.6T total / 49B active)', () {
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4:1.6t'), isTrue);
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4:49b'), isTrue);
    });

    test('Flash variant is NOT Pro', () {
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4-flash'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4:13b'), isFalse);
      expect(DeepseekV4Handler.isDeepseekV4Pro('deepseek-v4:284b'), isFalse);
    });
  });

  group('DeepseekV4Handler.coercedEffort + floorCoerced', () {
    test('Off is lifted to Standard', () {
      expect(
        DeepseekV4Handler.coercedEffort(ReasoningEffort.off),
        ReasoningEffort.standard,
      );
      expect(DeepseekV4Handler.floorCoerced(ReasoningEffort.off), isTrue);
    });

    test('Standard passes through', () {
      expect(
        DeepseekV4Handler.coercedEffort(ReasoningEffort.standard),
        ReasoningEffort.standard,
      );
      expect(
        DeepseekV4Handler.floorCoerced(ReasoningEffort.standard),
        isFalse,
      );
    });

    test('Deep passes through', () {
      expect(
        DeepseekV4Handler.coercedEffort(ReasoningEffort.deep),
        ReasoningEffort.deep,
      );
      expect(DeepseekV4Handler.floorCoerced(ReasoningEffort.deep), isFalse);
    });
  });

  group('DeepseekV4Handler.thinkingPayload', () {
    test('coding + standard → Think High @ 8192 on any variant', () {
      final pro = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.standard,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-pro',
      );
      expect(pro, isNotNull);
      expect(pro!['thinking'], <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': 8192,
      });
      expect(pro['reasoning_effort'], 'medium');

      final flash = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.standard,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-flash',
      );
      expect(flash!['thinking'], <String, dynamic>{
        'type': 'enabled',
        'budget_tokens': 8192,
      });
    });

    test('coding + deep — Pro gets 32K, Flash clamped to 16K', () {
      final pro = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.deep,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-pro',
      );
      final proThinking = pro!['thinking'] as Map<String, dynamic>;
      expect(proThinking['budget_tokens'], 32768);
      expect(pro['reasoning_effort'], 'high');

      final flash = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.deep,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-flash',
      );
      final flashThinking = flash!['thinking'] as Map<String, dynamic>;
      expect(flashThinking['budget_tokens'], 16384);
    });

    test('general turns use a tighter budget than coding', () {
      final coding = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.standard,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-pro',
      );
      final general = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.standard,
        taskKind: DeepseekV4TaskKind.general,
        rawModel: 'deepseek-v4-pro',
      );
      final cBudget = (coding!['thinking'] as Map)['budget_tokens'] as int;
      final gBudget = (general!['thinking'] as Map)['budget_tokens'] as int;
      expect(gBudget, lessThan(cBudget));
    });

    test('explicit Off pass-through returns disabled-thinking payload', () {
      // The handler honours an explicit Off when the caller bypasses
      // [coercedEffort]. Used as an escape hatch for cost-bounded
      // probes — production controller path always coerces first.
      final payload = DeepseekV4Handler.thinkingPayload(
        effort: ReasoningEffort.off,
        taskKind: DeepseekV4TaskKind.coding,
        rawModel: 'deepseek-v4-pro',
      );
      expect(payload, isNotNull);
      expect(payload!['thinking'], <String, dynamic>{'type': 'disabled'});
      expect(payload.containsKey('reasoning_effort'), isFalse);
    });
  });

  group('DeepseekV4Handler.antiHallucinationDirective', () {
    test('default returns a non-empty system prompt block', () {
      final block = DeepseekV4Handler.antiHallucinationDirective();
      expect(block.trim().isNotEmpty, isTrue);
      // Hard requirements — these substrings ARE the contract. If any
      // future edit removes them the model loses its abstention
      // permission and we're back to confabulation by default.
      expect(block.toLowerCase(), contains('abstention'));
      expect(block.toLowerCase(), contains('phantom'));
      // Permission-to-abstain language — matches either "don't know"
      // or "do not know" phrasing so a minor wording refresh doesn't
      // break the contract.
      final lower = block.toLowerCase();
      expect(
        lower.contains("don't know") || lower.contains('do not know'),
        isTrue,
        reason: 'expected explicit permission-to-abstain language',
      );
    });

    test('disabled flag returns empty string', () {
      expect(
        DeepseekV4Handler.antiHallucinationDirective(enabled: false),
        '',
      );
    });
  });

  group('ReasoningEffortHelper integration', () {
    test('modelSupportsNative is true for V4 regardless of provider', () {
      // V4 has a real `thinking` knob whatever transport carries it,
      // so the prompt-suffix fallback must be suppressed.
      expect(
        ReasoningEffortHelper.modelSupportsNative(
          provider: 'ollama-cloud',
          rawModel: 'deepseek-v4-pro:1.6t-cloud',
        ),
        isTrue,
      );
      expect(
        ReasoningEffortHelper.modelSupportsNative(
          provider: 'ollama',
          rawModel: 'deepseek-v4-flash',
        ),
        isTrue,
      );
      // Hypothetical future direct provider — still V4, still native.
      expect(
        ReasoningEffortHelper.modelSupportsNative(
          provider: 'deepseek',
          rawModel: 'deepseek-v4-pro',
        ),
        isTrue,
      );
    });

    test('non-V4 models keep the existing per-provider answer', () {
      // V3.1 on Ollama Cloud is a non-thinking-knob model — still false.
      expect(
        ReasoningEffortHelper.modelSupportsNative(
          provider: 'ollama-cloud',
          rawModel: 'deepseek-v3.1:671b',
        ),
        isFalse,
      );
      // Claude Opus 4.7 retains native support (the existing rule).
      expect(
        ReasoningEffortHelper.modelSupportsNative(
          provider: 'claude',
          rawModel: 'claude-opus-4-7',
        ),
        isTrue,
      );
    });
  });
}
