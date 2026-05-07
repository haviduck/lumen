import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import 'council_agent_inspector.dart';
import 'council_agent_sector.dart';
import 'council_backdrop.dart';
import 'council_blackboard.dart';
import 'council_header_bar.dart';
import 'council_orchestrator_ping_panel.dart';
import 'council_report_viewer.dart';
import 'council_speech_bubbles.dart';
import 'council_traffic_layer.dart';
import 'council_user_prompt_panel.dart';
import 'network_controller.dart';

class CouncilTheater extends StatefulWidget {
  const CouncilTheater({super.key});

  @override
  State<CouncilTheater> createState() => _CouncilTheaterState();
}

class _CouncilTheaterState extends State<CouncilTheater>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;
  final CouncilStageAnchors _anchors = CouncilStageAnchors();
  final NetworkController _network = NetworkController();
  bool _pingOpen = false;
  // When true, the report viewer is docked as a right-side panel inside
  // the theater (NOT as a modal dialog). This is the "council doesn't
  // go away when report is clicked" guarantee — both surfaces stay
  // mounted, so mid-council chat (ping panel) keeps working. Cleared by
  // the report panel's × button. Auto-cleared if the session changes
  // out from under us (new council started, or session disposed).
  bool _reportOpen = false;
  String? _reportSessionId;
  String? _inspectAgentId;

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
    _network.dispose();
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
        // Right blackboard mounts only when the viewport has width to spare.
        final bool wideEnough = constraints.maxWidth >= 1280;
        final double panelW = wideEnough
            ? constraints.maxWidth.clamp(1280.0, 1920.0) * 0.18
            : 0;
        final bool blackboardMounted = wideEnough;
        return Stack(
          children: [
            Positioned.fill(
              left: 0,
              right: panelW,
              child: _CouncilStage(
                session: session,
                pulse: _pulse,
                anchors: _anchors,
                network: _network,
                onTapAgent: (agentId) =>
                    setState(() => _inspectAgentId = agentId),
              ),
            ),
            Positioned.fill(
              left: 0,
              right: panelW,
              child: CouncilSpeechBubblesLayer(
                session: session,
                anchors: _anchors,
              ),
            ),
            if (blackboardMounted)
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: panelW,
                child: CouncilBlackboard(
                  session: session,
                  onOpenReport: !session.reportPath.isNotEmpty
                      ? null
                      : () {
                          setState(() {
                            _reportOpen = true;
                            _reportSessionId = session.config.id;
                          });
                        },
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
            if (_inspectAgentId != null &&
                session.agentById(_inspectAgentId!) != null)
              CouncilAgentInspector(
                key: ValueKey('council-inspect-$_inspectAgentId'),
                session: session,
                agent: session.agentById(_inspectAgentId!)!,
                onClose: () => setState(() => _inspectAgentId = null),
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
  final NetworkController network;
  final void Function(String agentId)? onTapAgent;

  const _CouncilStage({
    required this.session,
    required this.pulse,
    required this.anchors,
    required this.network,
    required this.onTapAgent,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        final agents = _visibleAgents(session);

        // ── Stage Director composition ─────────────────────────────────
        // HOW: wide ellipse with a 50° dead-wedge at top AND bottom so
        // the agent ring NEVER pokes into the header / footer safe zones.
        // Cards therefore cluster on the LEFT and RIGHT wings. This:
        //   • uses the horizontal axis aggressively (rx ≫ ry),
        //   • leaves the vertical centre column for the orchestrator,
        //   • leaves the top + bottom of the canvas EMPTY so Drift can
        //     drift bubbles outward past the ring without clipping.
        // Cards are smaller (vertical budget is tight) but every card has
        // ≥ 28px gap to its neighbour at the worst-case packing.
        const safePadTop = 28.0;
        const safePadBottom = 28.0;
        const safePadSide = 24.0;
        final safeZone = Rect.fromLTRB(
          safePadSide,
          safePadTop,
          size.width - safePadSide,
          size.height - safePadBottom,
        );
        final center = safeZone.center;

        // Cards: shrunk to fit the ring without overlap.  Width scales
        // with viewport so wide screens get bigger, presentable cards;
        // height stays modest because vertical room is the scarce axis.
        final cardW = math.min(236.0, math.max(196.0, size.width * 0.18));
        final cardH = math.min(196.0, math.max(168.0, size.height * 0.24));

        // Ring radii.  rx is intentionally ~1.55× ry so cards splay
        // sideways instead of stacking above / below the orchestrator.
        // Both radii respect the safe zone minus a half-card pad so a
        // card centred on the ring fits entirely inside safeZone.
        final maxRx = (safeZone.width / 2) - cardW / 2 - 8;
        final maxRy = (safeZone.height / 2) - cardH / 2 - 8;
        final rx = math.max(180.0, maxRx);
        final ry = math.max(120.0, math.min(maxRy, rx / 1.55));

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

        // Skip a 50° wedge at TOP and BOTTOM so cards never invade the
        // header / footer safe zones.  Agents are distributed across the
        // remaining 310° split into LEFT (right→bottom→left, swept down)
        // and RIGHT (top→right→bottom, swept up) wings.  For 9 agents
        // this yields ~5 per wing with healthy lateral spacing.
        final n = agents.length;
        if (n > 0) {
          const deadWedge = math.pi * 50 / 180; // 50° gap at top + bottom
          final usable = math.pi * 2 - deadWedge * 2;
          // Start just right of "12 o'clock + half-wedge", sweep clockwise.
          final start = -math.pi / 2 + deadWedge / 2;
          for (var i = 0; i < n; i++) {
            // Two arcs separated by the bottom wedge: half the agents on
            // the right arc (start → start+usable/2), then the bottom
            // wedge is skipped, then the left arc.
            double t;
            if (n == 1) {
              t = 0.5;
            } else {
              t = i / (n - 1);
            }
            // Inject the bottom dead-wedge in the middle of the sweep.
            final angle = (t < 0.5)
                ? start + (t * 2) * (usable / 2)
                : start + (usable / 2) + deadWedge + ((t - 0.5) * 2) * (usable / 2);

            final raw = Offset(
              center.dx + math.cos(angle) * rx,
              center.dy + math.sin(angle) * ry,
            );
            final left = (raw.dx - cardW / 2).clamp(
              safePadSide,
              size.width - cardW - safePadSide,
            );
            final top = (raw.dy - cardH / 2).clamp(
              safePadTop,
              size.height - cardH - safePadBottom,
            );
            layout[agents[i].id] = Rect.fromLTWH(left, top, cardW, cardH);
          }
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          anchors.update(
            layout,
            safeZone: safeZone,
            ringCenter: center,
            ringRadii: Size(rx, ry),
          );
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
                            network: network,
                          ),
                        ),
                      ),
                      _positioned(
                        layout[session.config.orchestrator.id]!,
                        _AgentTapTarget(
                          // Orchestrator card click opens the inspector,
                          // matching every other council card. Ping is now
                          // the header-bar button only — the user wants
                          // unconditional access to the inspector when
                          // the orchestrator is erroring.
                          onTap: onTapAgent == null
                              ? null
                              : () =>
                                    onTapAgent!(session.config.orchestrator.id),
                          child: CouncilAgentSector(
                            agent: session.config.orchestrator,
                            isOrchestrator: true,
                            spawnDelayMs: 0,
                          ),
                        ),
                      ),
                      for (var i = 0; i < agents.length; i++)
                        _positioned(
                          layout[agents[i].id]!,
                          _AgentTapTarget(
                            onTap: onTapAgent == null
                                ? null
                                : () => onTapAgent!(agents[i].id),
                            child: CouncilAgentSector(
                              key: ValueKey('agent-${agents[i].id}'),
                              agent: agents[i],
                              // Stagger from the orchestrator outward: cards
                              // closer to "12 o'clock" of the sweep arrive
                              // first, latest cards land ~720ms after.
                              spawnDelayMs: 120 + i * 80,
                            ),
                          ),
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
    final showEvaluator =
        session.status == CouncilStatus.synthesizing ||
        session.status == CouncilStatus.done ||
        evaluator.transcript.trim().isNotEmpty ||
        evaluator.status != CouncilAgentStatus.idle;
    return [...session.config.agents, if (showEvaluator) evaluator];
  }
}

/// Click on a regular agent card → open the floating inspector for them.
class _AgentTapTarget extends StatelessWidget {
  final VoidCallback? onTap;
  final Widget child;

  const _AgentTapTarget({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
    if (onTap == null) return child;
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
