import 'dart:async';
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
import 'council_pentest_attack_lines.dart';
import 'council_pentest_goal_panel.dart';
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
  bool _reportOpen = false;
  String? _reportSessionId;
  String? _inspectAgentId;

  // --- Pentest visual state ---
  bool _pentestConspiring = false;
  StreamSubscription<CouncilEvent>? _eventSub;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 5200),
    )..repeat();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _rebindEventStream();
  }

  void _rebindEventStream() {
    final controller = context.read<AppState>().council;
    _eventSub?.cancel();
    _eventSub = controller.events.listen(_onCouncilEvent);
  }

  /// Safe setState that never fires during gesture/mouse processing.
  /// Uses Future.microtask to escape the current synchronous call stack
  /// (gesture handler, stream listener, animation tick) before rebuilding.
  void _safeSetState(VoidCallback fn) {
    Future.microtask(() {
      if (mounted) setState(fn);
    });
  }

  void _onCouncilEvent(CouncilEvent event) {
    switch (event.type) {
      case CouncilEventType.pentestConspiring:
        _safeSetState(() => _pentestConspiring = true);
      case CouncilEventType.pentestGoalIdentified:
        break;
      case CouncilEventType.pentestAttackLanded:
        _safeSetState(() => _pentestConspiring = false);
      case CouncilEventType.sessionStarted:
        _safeSetState(() => _pentestConspiring = false);
      case CouncilEventType.reported:
        final session = context.read<AppState>().council.session;
        if (session != null && session.reportPath.isNotEmpty) {
          _safeSetState(() {
            _reportOpen = true;
            _reportSessionId = session.config.id;
          });
        }
    }
  }

  String? _maxPentestSeverity(CouncilSession session) {
    if (session.pentestFindings.isEmpty) return null;
    const rank = {'critical': 0, 'major': 1, 'minor': 2, 'info': 3};
    var best = 'info';
    for (final f in session.pentestFindings) {
      if ((rank[f.severity.name] ?? 3) < (rank[best] ?? 3)) {
        best = f.severity.name;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _eventSub?.cancel();
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
                ? () => _safeSetState(() => _pingOpen = true)
                : null,
            onOpenReport: !reportAvailable
                ? null
                : () {
                    // INLINE dock — never `showDialog`. The council
                    // theater stays mounted underneath, the ping panel
                    // remains usable, mid-council chat keeps working.
                    // This is the "council DOESN'T GO AWAY" guarantee.
                    _safeSetState(() {
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
        onClose: () => _safeSetState(() => _reportOpen = false),
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
        final isPentest = session.isPentestMode;
        final goalText = session.pentestGoal;
        final mainGoalVisible = isPentest && goalText.isNotEmpty;
        final stageW = constraints.maxWidth - panelW;
        final mainGoalCenter = Offset(stageW / 2, 70);

        // Every finding becomes a target panel. Laid out across the
        // top of the stage (the "target zone" the formation faces).
        final findings = session.pentestFindings;
        final findingLayouts = <int, Offset>{};
        final attackMap = <String, Offset>{};
        if (isPentest && findings.isNotEmpty) {
          const targetPanelW = 180.0;
          final usableW = stageW - 40;
          final n = findings.length;
          for (var i = 0; i < n; i++) {
            final t = n == 1 ? 0.5 : i / (n - 1);
            final x = 20.0 + t * (usableW - targetPanelW);
            final y = i.isEven ? 8.0 : 52.0;
            final center = Offset(x + targetPanelW / 2, y + 45);
            findingLayouts[i] = center;
            attackMap[findings[i].agentId] = center;
          }
        }
        // If no findings yet but conspiring, all agents aim at main goal.
        if (isPentest && findings.isEmpty && mainGoalVisible) {
          for (final a in session.config.agents) {
            attackMap[a.id] = mainGoalCenter;
          }
        }

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
                    _safeSetState(() => _inspectAgentId = agentId),
              ),
            ),
            if (isPentest)
              Positioned.fill(
                left: 0,
                right: panelW,
                child: IgnorePointer(
                  child: CouncilPentestAttackLines(
                    anchors: _anchors,
                    attacks: attackMap,
                    pulse: _pulse,
                    conspiring: _pentestConspiring,
                    mainGoalCenter: mainGoalVisible ? mainGoalCenter : null,
                  ),
                ),
              ),
            // --- Main goal panel — always visible in pentest mode ---
            if (isPentest)
              Positioned(
                left: stageW / 2 - 100,
                top: 16,
                child: _TargetTapHandler(
                  onTap: () => _safeSetState(() =>
                      _inspectAgentId = session.config.orchestrator.id),
                  child: CouncilPentestGoalPanel(
                    goal: goalText.isNotEmpty
                        ? goalText
                        : S.councilPentestGoalLabel,
                    findingCount: session.pentestFindings.length,
                    maxSeverity: _maxPentestSeverity(session),
                    underAttack: session.pentestFindings.isNotEmpty,
                  ),
                ),
              ),
            // --- Per-finding target panels ---
            for (var i = 0; i < findings.length; i++)
              if (findingLayouts.containsKey(i))
                Positioned(
                  left: findingLayouts[i]!.dx - 90,
                  top: findingLayouts[i]!.dy - 30,
                  child: _TargetTapHandler(
                    onTap: () {
                      final agentId = findings[i].agentId;
                      _safeSetState(() => _inspectAgentId = agentId);
                    },
                    child: CouncilPentestGoalPanel(
                      goal: findings[i].summary.length > 60
                          ? '${findings[i].summary.substring(0, 57)}...'
                          : findings[i].summary,
                      findingCount: 1,
                      maxSeverity: findings[i].severity.name,
                      underAttack: true,
                    ),
                  ),
                ),
            if (!isPentest)
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
                          _safeSetState(() {
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
                onClose: () => _safeSetState(() => _pingOpen = false),
              ),
            if (_inspectAgentId != null &&
                session.agentById(_inspectAgentId!) != null)
              CouncilAgentInspector(
                key: ValueKey('council-inspect-$_inspectAgentId'),
                session: session,
                agent: session.agentById(_inspectAgentId!)!,
                onClose: () => _safeSetState(() => _inspectAgentId = null),
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

        final layout = <String, Rect>{};

        if (session.isPentestMode) {
          // ── Pentest formation layout ────────────────────────────────
          // Row-based: offensive/recon agents up front (top, near targets),
          // support roles in the back, orchestrator rear-center commanding.
          final front = <CouncilAgent>[];
          final back = <CouncilAgent>[];
          for (final a in agents) {
            if (_isOffensiveRole(a)) {
              front.add(a);
            } else {
              back.add(a);
            }
          }
          // Leave top ~30% of stage for target panels
          const targetZoneRatio = 0.28;
          final formationTop = safeZone.top + safeZone.height * targetZoneRatio;
          final rowH = cardH + 12;
          final gap = 14.0;

          void layRow(List<CouncilAgent> row, double y) {
            if (row.isEmpty) return;
            final totalW = row.length * cardW + (row.length - 1) * gap;
            var x = center.dx - totalW / 2;
            for (final a in row) {
              layout[a.id] = Rect.fromLTWH(
                x.clamp(safePadSide, size.width - cardW - safePadSide),
                y.clamp(safePadTop, size.height - cardH - safePadBottom),
                cardW,
                cardH,
              );
              x += cardW + gap;
            }
          }

          layRow(front, formationTop);
          layRow(back, formationTop + rowH);
          // Orchestrator rear-center, behind both rows
          layout[session.config.orchestrator.id] = Rect.fromLTWH(
            (center.dx - cardW / 2).clamp(
              safePadSide, size.width - cardW - safePadSide),
            (formationTop + rowH * 2).clamp(
              safePadTop, size.height - cardH - safePadBottom),
            cardW,
            cardH,
          );
        } else {
          // ── Standard elliptical ring layout ───────────────────────
          layout[session.config.orchestrator.id] = Rect.fromLTWH(
            center.dx - cardW / 2,
            center.dy - cardH / 2,
            cardW,
            cardH,
          );
          final n = agents.length;
          if (n > 0) {
            const deadWedge = math.pi * 50 / 180;
            final usable = math.pi * 2 - deadWedge * 2;
            final start = -math.pi / 2 + deadWedge / 2;
            for (var i = 0; i < n; i++) {
              double t;
              if (n == 1) {
                t = 0.5;
              } else {
                t = i / (n - 1);
              }
              final angle = (t < 0.5)
                  ? start + (t * 2) * (usable / 2)
                  : start + (usable / 2) + deadWedge + ((t - 0.5) * 2) * (usable / 2);
              final raw = Offset(
                center.dx + math.cos(angle) * rx,
                center.dy + math.sin(angle) * ry,
              );
              final left = (raw.dx - cardW / 2).clamp(
                safePadSide, size.width - cardW - safePadSide);
              final top = (raw.dy - cardH / 2).clamp(
                safePadTop, size.height - cardH - safePadBottom);
              layout[agents[i].id] = Rect.fromLTWH(left, top, cardW, cardH);
            }
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
                          onTap: onTapAgent == null
                              ? null
                              : () =>
                                    onTapAgent!(session.config.orchestrator.id),
                          child: _maybeWithTicker(
                            session.config.orchestrator,
                            CouncilAgentSector(
                              agent: session.config.orchestrator,
                              isOrchestrator: true,
                              spawnDelayMs: 0,
                            ),
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
                            child: _maybeWithTicker(
                              agents[i],
                              CouncilAgentSector(
                                key: ValueKey('agent-${agents[i].id}'),
                                agent: agents[i],
                                spawnDelayMs: 120 + i * 80,
                              ),
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

  Widget _maybeWithTicker(CouncilAgent agent, Widget card) {
    if (!session.isPentestMode) return card;
    final transcript = agent.transcript.trim();
    if (transcript.isEmpty) return card;
    // Strip tool-call noise, grab the last few meaningful lines
    var cleaned = transcript
        .replaceAll(RegExp(r'<<<[A-Z_]+(?::\s*[^>]*)?\s*>>>'), '')
        .replaceAll(
          RegExp(r'<<<END_(?:FILE|EDIT|APPEND)>>>'),
          '',
        )
        .replaceAll(RegExp(r'<!-- LUMEN_[^>]*-->'), '')
        .replaceAll(RegExp(r'<tool_result>[\s\S]*?</tool_result>'), '')
        .replaceAll(RegExp(r'^\[FAILED\]\s*', multiLine: true), '');
    final lines = cleaned
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('|') && l.length > 3)
        .toList();
    if (lines.isEmpty) return card;
    final tail = lines.length <= 3 ? lines : lines.sublist(lines.length - 3);
    final display = tail.join('\n');

    return Stack(
      clipBehavior: Clip.none,
      children: [
        card,
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: IgnorePointer(
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 14, 10, 8),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.0, 0.25, 1.0],
                  colors: [
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.7),
                    Colors.black.withValues(alpha: 0.92),
                  ],
                ),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
              ),
              child: Text(
                display,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.75),
                  fontSize: 10,
                  height: 1.35,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
      ],
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

  static bool _isOffensiveRole(CouncilAgent agent) {
    if (agent.role == RolePreset.pentester ||
        agent.role == RolePreset.tester) {
      return true;
    }
    if (agent.role == RolePreset.custom) {
      final lower = agent.customRole.toLowerCase();
      return lower.contains('recon') ||
          lower.contains('offensive') ||
          lower.contains('exploit') ||
          lower.contains('attack') ||
          lower.contains('scan') ||
          lower.contains('probe') ||
          lower.contains('red team') ||
          lower.contains('ctf') ||
          lower.contains('pentest') ||
          lower.contains('breach');
    }
    final nameLower = agent.name.toLowerCase();
    return nameLower.contains('recon') ||
        nameLower.contains('exploit') ||
        nameLower.contains('attack') ||
        nameLower.contains('scan') ||
        nameLower.contains('probe') ||
        nameLower.contains('ctf') ||
        nameLower.contains('breach');
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

/// Click on a pentest target panel → open the inspector for the
/// agent who produced that finding (or orchestrator for main goal).
class _TargetTapHandler extends StatelessWidget {
  final VoidCallback onTap;
  final Widget child;

  const _TargetTapHandler({required this.onTap, required this.child});

  @override
  Widget build(BuildContext context) {
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
