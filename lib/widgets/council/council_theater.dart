import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_agent_sector.dart';
import 'council_backdrop.dart';
import 'council_blackboard.dart';
import 'council_header_bar.dart';
import 'council_orchestrator_ping_panel.dart';
import 'council_report_viewer.dart';
import 'council_speech_bubbles.dart';
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
  final CouncilStageAnchors _anchors = CouncilStageAnchors();
  bool _pingOpen = false;
  // When true, the report viewer is docked as a right-side panel inside
  // the theater (NOT as a modal dialog). This is the "council doesn't
  // go away when report is clicked" guarantee — both surfaces stay
  // mounted, so mid-council chat (ping panel) keeps working. Cleared by
  // the report panel's × button. Auto-cleared if the session changes
  // out from under us (new council started, or session disposed).
  bool _reportOpen = false;
  String? _reportSessionId;

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
    _anchors.dispose();
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
    // If the user starts a fresh council, drop any docked report from a
    // previous session — its path may be stale and the new run hasn't
    // produced one yet.
    if (_reportSessionId != null && _reportSessionId != session.config.id) {
      _reportOpen = false;
      _reportSessionId = null;
    }
    final reportAvailable = session.reportPath.isNotEmpty;
    final showReportPanel = _reportOpen && reportAvailable;

    return DecoratedBox(
      decoration: const BoxDecoration(color: DuckColors.bgBase),
      child: Column(
        children: [
          CouncilHeaderBar(
            controller: controller,
            onPingOrchestrator: controller.canPingOrchestrator
                ? () => setState(() => _pingOpen = true)
                : null,
            onOpenReport: !reportAvailable
                ? null
                : () {
                    // INLINE dock — never `showDialog`. The council
                    // theater stays mounted underneath, the ping panel
                    // remains usable, mid-council chat keeps working.
                    // This is the "council DOESN'T GO AWAY" guarantee.
                    setState(() {
                      _reportOpen = true;
                      _reportSessionId = session.config.id;
                    });
                  },
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final wide = constraints.maxWidth >= 980;
                final stageContent = _buildStageStack(controller, session);
                if (!showReportPanel) return stageContent;
                if (wide) {
                  // Side-by-side: council compresses to ~40% on the
                  // left, report fills 60% on the right. Picked over
                  // a slide-over because the user explicitly wants
                  // the council remaining "visible/peelable" — a
                  // slide-over hides too much, a stacked sheet is
                  // worse. Split is the only layout where the live
                  // agent timeline + ping affordance stay actionable
                  // while the report is on screen.
                  return Row(
                    children: [
                      Expanded(flex: 4, child: stageContent),
                      const VerticalDivider(
                        width: 1,
                        thickness: 1,
                        color: DuckColors.glassSeam,
                      ),
                      Expanded(
                        flex: 6,
                        child: _buildReportPanel(session),
                      ),
                    ],
                  );
                }
                // Narrow viewport: stack the report over the council
                // as a full-width sheet. Council remains mounted (its
                // controllers + ping state survive) — only its paint
                // is hidden. Closing the report restores it instantly.
                return Stack(
                  children: [
                    Positioned.fill(child: stageContent),
                    Positioned.fill(child: _buildReportPanel(session)),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReportPanel(CouncilSession session) {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: CouncilReportViewer(
        markdownPath: session.reportPath,
        title: session.config.title.isNotEmpty ? session.config.title : null,
        agentRoster: [for (final a in session.config.allAgents) a.name],
        savedAt: session.finishedAt ?? DateTime.now(),
        embedded: true,
        onClose: () => setState(() => _reportOpen = false),
      ),
    );
  }

  Widget _buildStageStack(
    CouncilController controller,
    CouncilSession session,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Blackboards mount only when the viewport has the width to spare.
        // Below this threshold the orbital stage cannot survive 2× ~280px
        // chrome stolen from its layout, so we fall back to bubbles-only
        // and let the evaluator's verdict still surface in chat.
        final bool wideEnough = constraints.maxWidth >= 1280;
        final double panelW = wideEnough
            ? constraints.maxWidth.clamp(1280.0, 1920.0) * 0.18
            : 0;
        final bool blackboardsMounted = wideEnough;
        return Stack(
          children: [
            Positioned.fill(
              left: panelW,
              right: panelW,
              child: _CouncilStage(
                session: session,
                pulse: _pulse,
                anchors: _anchors,
                canPingOrchestrator: controller.canPingOrchestrator,
                evaluatorOnBlackboard: blackboardsMounted,
                onTapOrchestrator: controller.canPingOrchestrator
                    ? () => setState(() => _pingOpen = true)
                    : null,
              ),
            ),
            Positioned.fill(
              left: panelW,
              right: panelW,
              child: CouncilSpeechBubblesLayer(
                session: session,
                anchors: _anchors,
                evaluatorOnBlackboard: blackboardsMounted,
              ),
            ),
            if (blackboardsMounted)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                width: panelW,
                child: CouncilLeftBlackboard(session: session),
              ),
            if (blackboardsMounted)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: panelW,
                child: CouncilBlackboard(
                  session: session,
                  onOpenReport: session.reportPath.isNotEmpty
                      ? () => setState(() => _reportOpen = true)
                      : null,
                ),
              ),
            if (session.pendingUserQuestion != null)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: DuckColors.bgDeepest.withValues(alpha: 0.38),
                  ),
                ),
              ),
            if (session.pendingUserQuestion != null)
              CouncilUserPromptPanel(
                controller: controller,
                question: session.pendingUserQuestion!,
              ),
            if (_pingOpen)
              CouncilOrchestratorPingPanel(
                controller: controller,
                onClose: () => setState(() => _pingOpen = false),
              ),
          ],
        );
      },
    );
  }
}

class _CouncilStage extends StatelessWidget {
  final CouncilSession session;
  final Animation<double> pulse;
  final CouncilStageAnchors anchors;
  final bool canPingOrchestrator;
  final bool evaluatorOnBlackboard;
  final VoidCallback? onTapOrchestrator;

  const _CouncilStage({
    required this.session,
    required this.pulse,
    required this.anchors,
    required this.canPingOrchestrator,
    required this.evaluatorOnBlackboard,
    required this.onTapOrchestrator,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final center = Offset(size.width / 2, size.height / 2);
        // More breathing room: smaller cards, larger orbital radius.
        final cardW = math.min(248.0, math.max(208.0, size.width * 0.20));
        final cardH = math.min(208.0, math.max(176.0, size.height * 0.26));
        final radius = math
            .min(size.width * 0.42, size.height * 0.42)
            .clamp(180.0, 380.0);
        final agents = _visibleAgents(session);

        // Compute layout once and publish anchors so bubbles + traffic
        // align perfectly with cards.
        final layout = <String, Rect>{};
        final orchestratorRect = Rect.fromLTWH(
          center.dx - cardW / 2,
          center.dy - cardH / 2,
          cardW,
          cardH,
        );
        layout[session.config.orchestrator.id] = orchestratorRect;
        for (var i = 0; i < agents.length; i++) {
          final angle = -math.pi / 2 + (math.pi * 2 * i / agents.length);
          final raw = Offset(
            center.dx + math.cos(angle) * radius,
            center.dy + math.sin(angle) * radius,
          );
          final left = (raw.dx - cardW / 2).clamp(
            14.0,
            size.width - cardW - 14,
          );
          final top = (raw.dy - cardH / 2).clamp(
            14.0,
            size.height - cardH - 14,
          );
          layout[agents[i].id] = Rect.fromLTWH(left, top, cardW, cardH);
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          anchors.update(layout);
        });

        // Background is lifted OUT of the pulse AnimatedBuilder so
        // its repaints don't drag the entire stage subtree (every
        // agent card + traffic layer) into a rebuild every pulse
        // tick. It owns its own controller + RepaintBoundary.
        return Stack(
          children: [
            Positioned.fill(
              child: CouncilDiagonalBackdrop(agentCount: agents.length),
            ),
            Positioned.fill(
              child: AnimatedBuilder(
                animation: pulse,
                builder: (context, child) {
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: RepaintBoundary(
                          child: CouncilTrafficLayer(
                            agents: agents,
                            orchestrator: session.config.orchestrator,
                            events: session.events,
                            pulse: pulse,
                            anchors: anchors,
                            mutedAgentIds: evaluatorOnBlackboard
                                ? {session.config.finalEvaluator.id}
                                : const <String>{},
                          ),
                        ),
                      ),
                      _positioned(
                        layout[session.config.orchestrator.id]!,
                        _OrchestratorTapTarget(
                          canPing: canPingOrchestrator,
                          onTap: onTapOrchestrator,
                          child: CouncilAgentSector(
                            agent: session.config.orchestrator,
                            isOrchestrator: true,
                          ),
                        ),
                      ),
                      for (final agent in agents)
                        _positioned(
                          layout[agent.id]!,
                          CouncilAgentSector(agent: agent),
                        ),
                    ],
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _positioned(Rect rect, Widget child) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 480),
      curve: Curves.easeOutCubic,
      left: rect.left,
      top: rect.top,
      width: rect.width,
      height: rect.height,
      child: child,
    );
  }

  List<CouncilAgent> _visibleAgents(CouncilSession session) {
    final evaluator = session.config.finalEvaluator;
    // When the left blackboard is mounted it owns the evaluator's surface;
    // keeping the evaluator in the orbital ring would double-render its
    // status + transcript (Skeptic flag, round-two ruling).
    if (evaluatorOnBlackboard) {
      return [...session.config.agents];
    }
    final showEvaluator =
        session.status == CouncilStatus.synthesizing ||
        session.status == CouncilStatus.done ||
        evaluator.transcript.trim().isNotEmpty ||
        evaluator.status != CouncilAgentStatus.idle;
    return [...session.config.agents, if (showEvaluator) evaluator];
  }
}

class _OrchestratorTapTarget extends StatelessWidget {
  final bool canPing;
  final VoidCallback? onTap;
  final Widget child;

  const _OrchestratorTapTarget({
    required this.canPing,
    required this.onTap,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (!canPing || onTap == null) return child;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: child,
      ),
    );
  }
}

// `_CouncilAtmospherePainter` was the source of the "starfish" artifact
// (concentric rings + radial mint nodes with pulsing purple stroke rings).
// It has been replaced by `CouncilDiagonalBackdrop` in council_backdrop.dart,
// which owns its own AnimationController + RepaintBoundary so the bg drift
// no longer rebuilds the entire stage subtree on every pulse tick.
