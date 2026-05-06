import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_agent_sector.dart';
import 'council_blackboard.dart';
import 'council_header_bar.dart';
import 'council_pool_panel.dart';
import 'council_traffic_layer.dart';
import 'council_user_prompt_panel.dart';

class CouncilTheater extends StatefulWidget {
  const CouncilTheater({super.key});

  @override
  State<CouncilTheater> createState() => _CouncilTheaterState();
}

class _CouncilTheaterState extends State<CouncilTheater>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    )..repeat();
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final controller = appState.council;
    final session = controller.session;
    if (session == null) {
      return const Center(
        child: Text(
          S.councilTitle,
          style: TextStyle(color: DuckColors.fgMuted),
        ),
      );
    }

    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.18),
          radius: 1.12,
          colors: [Color(0x33272C36), DuckColors.bgBase, DuckColors.bgDeepest],
        ),
      ),
      child: Column(
        children: [
          CouncilHeaderBar(
            controller: controller,
            onOpenReport: session.reportPath.isEmpty
                ? null
                : () {
                    appState.openFile(File(session.reportPath));
                    controller.hideTheater();
                  },
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _CouncilStage(session: session, pulse: _pulse),
                      ),
                      if (session.pendingUserQuestion != null)
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: DuckColors.bgDeepest.withValues(
                                alpha: 0.38,
                              ),
                            ),
                          ),
                        ),
                      if (session.pendingUserQuestion != null)
                        CouncilUserPromptPanel(
                          controller: controller,
                          question: session.pendingUserQuestion!,
                        ),
                    ],
                  ),
                ),
                SizedBox(
                  width: 320,
                  child: CouncilBlackboard(
                    session: session,
                    onOpenReport: session.reportPath.isEmpty
                        ? null
                        : () {
                            appState.openFile(File(session.reportPath));
                            controller.hideTheater();
                          },
                  ),
                ),
              ],
            ),
          ),
          CouncilPoolPanel(session: session),
        ],
      ),
    );
  }
}

class _CouncilStage extends StatelessWidget {
  final CouncilSession session;
  final Animation<double> pulse;

  const _CouncilStage({required this.session, required this.pulse});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final center = Offset(size.width / 2, size.height / 2);
        final cardW = math.min(280.0, math.max(220.0, size.width * 0.23));
        final cardH = math.min(230.0, math.max(190.0, size.height * 0.28));
        final radius = math.min(size.width, size.height) * 0.34;
        final agents = _visibleAgents(session);
        final securityMode = _isSecurityScenario(session);

        return AnimatedBuilder(
          animation: pulse,
          builder: (context, child) {
            return Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CouncilAtmospherePainter(
                      pulse: pulse.value,
                      agentCount: agents.length,
                    ),
                  ),
                ),
                if (securityMode)
                  Positioned.fill(
                    child: _SecurityGoalLayer(pulse: pulse.value),
                  ),
                Positioned.fill(
                  child: CouncilTrafficLayer(
                    agents: agents,
                    orchestrator: session.config.orchestrator,
                    events: session.events,
                    pulse: pulse,
                  ),
                ),
                Positioned(
                  left: securityMode ? 24 : center.dx - cardW / 2,
                  top: securityMode
                      ? center.dy - cardH / 2
                      : center.dy - cardH / 2,
                  width: cardW,
                  height: cardH,
                  child: CouncilAgentSector(
                    agent: session.config.orchestrator,
                    isOrchestrator: true,
                  ),
                ),
                for (var i = 0; i < agents.length; i++)
                  securityMode
                      ? _positionedSecurityAgent(
                          index: i,
                          count: agents.length,
                          width: cardW,
                          height: cardH,
                          agent: agents[i],
                          bounds: size,
                        )
                      : _positionedAgent(
                          center: center,
                          radius: radius,
                          index: i,
                          count: agents.length,
                          width: cardW,
                          height: cardH,
                          agent: agents[i],
                          bounds: size,
                        ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _positionedAgent({
    required Offset center,
    required double radius,
    required int index,
    required int count,
    required double width,
    required double height,
    required CouncilAgent agent,
    required Size bounds,
  }) {
    final angle = -math.pi / 2 + (math.pi * 2 * index / count);
    final raw = Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
    final left = (raw.dx - width / 2).clamp(10.0, bounds.width - width - 10);
    final top = (raw.dy - height / 2).clamp(10.0, bounds.height - height - 10);
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: CouncilAgentSector(agent: agent),
    );
  }

  Widget _positionedSecurityAgent({
    required int index,
    required int count,
    required double width,
    required double height,
    required CouncilAgent agent,
    required Size bounds,
  }) {
    final lanes = math.max(count, 1);
    final usableH = math.max(1.0, bounds.height - height - 28);
    final top = 14 + (usableH * (index + 0.5) / lanes) - height / 2;
    final wave = index.isEven ? 0.30 : 0.45;
    final left = (bounds.width * wave).clamp(12.0, bounds.width - width - 18);
    return Positioned(
      left: left,
      top: top.clamp(12.0, bounds.height - height - 12),
      width: width,
      height: height,
      child: CouncilAgentSector(agent: agent),
    );
  }

  List<CouncilAgent> _visibleAgents(CouncilSession session) {
    final evaluator = session.config.finalEvaluator;
    final showEvaluator =
        session.status == CouncilStatus.synthesizing ||
        session.status == CouncilStatus.done ||
        evaluator.transcript.trim().isNotEmpty ||
        evaluator.status != CouncilAgentStatus.idle;
    return [...session.config.agents, if (showEvaluator) evaluator];
  }

  bool _isSecurityScenario(CouncilSession session) {
    final brief = session.config.brief.toLowerCase();
    return brief.contains('pentest') ||
        brief.contains('pen test') ||
        brief.contains('sectest') ||
        brief.contains('sec test') ||
        brief.contains('security test') ||
        brief.contains('vulnerability') ||
        session.config.agents.any((a) => a.role == RolePreset.pentester);
  }
}

class _SecurityGoalLayer extends StatelessWidget {
  final double pulse;

  const _SecurityGoalLayer({required this.pulse});

  @override
  Widget build(BuildContext context) {
    const goals = [
      S.councilSecurityGoalMap,
      S.councilSecurityGoalEntry,
      S.councilSecurityGoalExploit,
      S.councilSecurityGoalEvidence,
      S.councilSecurityGoalRemediate,
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        return Stack(
          children: [
            for (var i = 0; i < goals.length; i++)
              Positioned(
                right: 20,
                top: (h - 48) * (i + 0.5) / goals.length,
                width: 170,
                height: 44,
                child: _GoalNode(
                  label: goals[i],
                  active: i == ((pulse * goals.length).floor() % goals.length),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _GoalNode extends StatelessWidget {
  final String label;
  final bool active;

  const _GoalNode({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 260),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: active ? 0.86 : 0.64),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: active ? DuckColors.accentMint : DuckColors.borderStrong,
          width: active ? 1.2 : 0.7,
        ),
        boxShadow: active
            ? [
                BoxShadow(
                  color: DuckColors.accentMint.withValues(alpha: 0.16),
                  blurRadius: 18,
                ),
              ]
            : null,
      ),
      child: Row(
        children: [
          Icon(
            active ? Icons.adjust : Icons.radio_button_unchecked,
            size: 14,
            color: active ? DuckColors.accentMint : DuckColors.fgSubtle,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: active ? DuckColors.fgPrimary : DuckColors.fgMuted,
                fontSize: 11,
                fontWeight: active ? FontWeight.w800 : FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CouncilAtmospherePainter extends CustomPainter {
  final double pulse;
  final int agentCount;

  _CouncilAtmospherePainter({required this.pulse, required this.agentCount});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final shortest = math.min(size.width, size.height);
    final radius = shortest * 0.34;
    final haloPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          DuckColors.accentCyan.withValues(alpha: 0.18),
          DuckColors.accentPurple.withValues(alpha: 0.055),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: shortest * 0.48));
    canvas.drawCircle(center, shortest * 0.48, haloPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = DuckColors.borderStrong.withValues(alpha: 0.26);
    final activeRingPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = DuckColors.accentCyan.withValues(alpha: 0.16);
    for (var i = 0; i < 4; i++) {
      final breathe = math.sin((pulse * math.pi * 2) + i * 0.7) * 2.5;
      final r = radius * (0.45 + i * 0.23) + breathe;
      canvas.drawCircle(center, r, i == 2 ? activeRingPaint : ringPaint);
    }

    if (agentCount == 0) return;
    final nodePaint = Paint()
      ..color = DuckColors.accentMint.withValues(alpha: 0.72);
    for (var i = 0; i < agentCount; i++) {
      final angle = -math.pi / 2 + (math.pi * 2 * i / agentCount);
      final p = Offset(
        center.dx + math.cos(angle) * radius,
        center.dy + math.sin(angle) * radius,
      );
      canvas.drawCircle(p, 3.5, nodePaint);
      canvas.drawCircle(
        p,
        11 + math.sin((pulse * math.pi * 2) + i) * 0.8,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8
          ..color = DuckColors.accentPurple.withValues(alpha: 0.22),
      );
    }

    final scanPaint = Paint()
      ..strokeWidth = 0.7
      ..color = DuckColors.accentMint.withValues(alpha: 0.055);
    final step = 42.0;
    final offset = pulse * step * 0.82;
    for (var x = -step + offset; x < size.width; x += step) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x + size.height * 0.35, size.height),
        scanPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CouncilAtmospherePainter oldDelegate) {
    return oldDelegate.pulse != pulse || oldDelegate.agentCount != agentCount;
  }
}
