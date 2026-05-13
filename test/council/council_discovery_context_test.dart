import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/providers/council_controller.dart';
import 'package:lumen/services/anthropic_service.dart';
import 'package:lumen/services/copilot_service.dart';
import 'package:lumen/services/council/council_agent_runner.dart';
import 'package:lumen/services/council/council_models.dart';
import 'package:lumen/services/council/council_persistence_service.dart';
import 'package:lumen/services/council/council_protocol.dart';
import 'package:lumen/services/gemini_service.dart';
import 'package:lumen/services/ollama_service.dart';

void main() {
  group('Council discovery context', () {
    test('round-trips through CouncilSession JSON', () {
      final session = CouncilSession(
        config: _config(),
        discoveryContext: 'Read lib/foo.dart; main constraint is bar.',
      );

      final round = CouncilSession.fromJson(session.toJson());

      expect(
        round.discoveryContext,
        'Read lib/foo.dart; main constraint is bar.',
      );
    });

    test(
      'agent prompt includes digest only when discoveryContext is present',
      () {
        final config = _config();
        final agent = config.agents.first;

        final withoutDigest = CouncilProtocol.agentSystemPrompt(
          config: config,
          agent: agent,
          task: 'Design the narrow change.',
        );
        expect(
          withoutDigest,
          isNot(contains("Orchestrator's discovery digest")),
        );

        final withDigest = CouncilProtocol.agentSystemPrompt(
          config: config,
          agent: agent,
          task: 'Design the narrow change.',
          discoveryContext:
              'Grounded surface: lib/providers/council_controller.dart',
        );
        expect(withDigest, contains("Orchestrator's discovery digest"));
        expect(
          withDigest,
          contains('Grounded surface: lib/providers/council_controller.dart'),
        );
        expect(withDigest, contains('Do NOT re-read files'));
      },
    );

    test('parallel and repeated discovery dispatches are refused', () {
      final session = CouncilSession(config: _config());

      expect(
        CouncilController.discoveryDispatchRefusalForTest(
          session: session,
          parallel: true,
        ),
        contains('parallel discovery waves are blocked'),
      );
      expect(
        CouncilController.discoveryDispatchRefusalForTest(
          session: session,
          parallel: false,
        ),
        isNull,
      );

      session.events.add(
        CouncilEvent(type: CouncilEventType.dispatched, message: 'scout once'),
      );
      expect(
        CouncilController.discoveryDispatchRefusalForTest(
          session: session,
          parallel: false,
        ),
        contains('at most one sequential scout dispatch'),
      );

      session.currentPhase = CouncilPhase.architecture;
      expect(
        CouncilController.discoveryDispatchRefusalForTest(
          session: session,
          parallel: true,
        ),
        isNull,
      );
    });

    test(
      'leaving discovery captures orchestrator transcript tail once',
      () async {
        final config = _config();
        config.orchestrator.transcript =
            '${List.filled(2100, 'x').join()}\n'
            'Grounded: lib/services/council/council_protocol.dart';
        final session = CouncilSession(config: config);
        final controller = CouncilController(
          anthropic: AnthropicService(),
          copilot: CopilotService(),
          gemini: GeminiService(),
          ollama: OllamaService(),
          persistence: _NoopPersistenceService(),
          isToolAutoApproved: (_, _) => true,
        )..attachSessionForTest(session);

        await controller.declarePhaseForTest(
          CouncilToolCall(
            id: 'phase-1',
            name: CouncilProtocol.phaseToolId,
            arguments: {
              'phase': 'architecture',
              'rationale': 'Discovery is grounded enough to design.',
            },
          ),
        );

        expect(session.currentPhase, CouncilPhase.architecture);
        expect(session.discoveryContext.length, lessThanOrEqualTo(2000));
        expect(
          session.discoveryContext,
          contains('Grounded: lib/services/council/council_protocol.dart'),
        );

        session.config.orchestrator.transcript = 'new transcript';
        await controller.declarePhaseForTest(
          CouncilToolCall(
            id: 'phase-2',
            name: CouncilProtocol.phaseToolId,
            arguments: {'phase': 'build', 'rationale': 'Design complete.'},
          ),
        );
        expect(
          session.discoveryContext,
          contains('Grounded: lib/services/council/council_protocol.dart'),
        );
      },
    );
  });
}

CouncilConfig _config() {
  return CouncilConfig(
    id: 'council-discovery-test',
    title: 'Discovery test',
    brief: 'Improve council discovery speed.',
    orchestrator: CouncilAgent(
      id: 'orchestrator',
      name: 'Orchestrator',
      role: RolePreset.architect,
      model: 'claude:test',
    ),
    agents: [
      CouncilAgent(
        id: 'agent_0',
        name: 'Architect',
        role: RolePreset.architect,
        model: 'claude:test',
      ),
    ],
  );
}

class _NoopPersistenceService extends CouncilPersistenceService {
  @override
  Future<void> saveSession(CouncilSession session) async {}
}
