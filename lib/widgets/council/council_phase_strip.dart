import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// Horizontal strip rendering the Excellence-Doctrine phases. Mounted
/// directly under the council header. Reads `session.currentPhase` +
/// `session.phaseHistory` to render six nodes connected by a track:
///
/// • completed phases — solid mint, soft glow
/// • current phase — cyan, pulsing scale + halo
/// • pending phases — dim raised
///
/// The strip is informational, not interactive. It exists so the user can
/// see at a glance whether the orchestrator is still in discovery vs.
/// shipping prematurely.
class CouncilPhaseStrip extends StatefulWidget {
  const CouncilPhaseStrip({
    super.key,
    required this.currentPhase,
    required this.phaseHistory,
    this.compact = false,
  });

  final CouncilPhase currentPhase;
  final List<CouncilPhaseEntry> phaseHistory;
  final bool compact;

  @override
  State<CouncilPhaseStrip> createState() => _CouncilPhaseStripState();
}

class _CouncilPhaseStripState extends State<CouncilPhaseStrip>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;

  /// One-shot edge-trigger that paints a "light sweep" along the
  /// just-completed track segment when a new phase is entered. Picks
  /// up the same vocabulary as the full-stage phase transition
  /// overlay: a beat, not a tick.
  late final AnimationController _trackSweep;

  /// Last seen phase-history length — drives the edge trigger for
  /// [_trackSweep] on the first build after a transition lands.
  int _seenHistoryLength = 0;

  /// Index of the destination phase for the active sweep (the one
  /// just entered). -1 when dormant.
  int _sweepDestinationIndex = -1;

  static const _phasesInOrder = <CouncilPhase>[
    CouncilPhase.discovery,
    CouncilPhase.architecture,
    CouncilPhase.build,
    CouncilPhase.review,
    CouncilPhase.polish,
    CouncilPhase.ship,
  ];

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);
    _trackSweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _seenHistoryLength = widget.phaseHistory.length;
  }

  @override
  void didUpdateWidget(covariant CouncilPhaseStrip old) {
    super.didUpdateWidget(old);
    _maybeFireSweep();
  }

  /// Detects a fresh phase entry on the history and fires the track
  /// sweep targeting the new phase's preceding track segment.
  void _maybeFireSweep() {
    if (widget.phaseHistory.length <= _seenHistoryLength) return;
    _seenHistoryLength = widget.phaseHistory.length;
    final destIdx = _phasesInOrder.indexOf(widget.currentPhase);
    if (destIdx <= 0) return;
    _sweepDestinationIndex = destIdx;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _trackSweep.forward(from: 0);
    });
  }

  @override
  void dispose() {
    _pulse.dispose();
    _trackSweep.dispose();
    super.dispose();
  }

  String _labelFor(CouncilPhase phase) {
    switch (phase) {
      case CouncilPhase.discovery:
        return S.councilPhaseDiscovery;
      case CouncilPhase.architecture:
        return S.councilPhaseArchitecture;
      case CouncilPhase.build:
        return S.councilPhaseBuild;
      case CouncilPhase.review:
        return S.councilPhaseReview;
      case CouncilPhase.polish:
        return S.councilPhasePolish;
      case CouncilPhase.ship:
        return S.councilPhaseShip;
    }
  }

  String? _rationaleFor(CouncilPhase phase) {
    // Last rationale wins — phases can be re-declared.
    CouncilPhaseEntry? hit;
    for (final entry in widget.phaseHistory) {
      if (entry.phase == phase) hit = entry;
    }
    return hit?.rationale;
  }

  @override
  Widget build(BuildContext context) {
    // Belt-and-braces: if a transition landed before didUpdateWidget
    // ran (state change inside a microtask), the build-time check fires
    // the sweep so we never silently skip a phase transition.
    if (widget.phaseHistory.length > _seenHistoryLength) {
      _maybeFireSweep();
    }
    final visited = widget.phaseHistory.map((p) => p.phase).toSet();
    final currentIndex = _phasesInOrder.indexOf(widget.currentPhase);

    return Container(
      height: widget.compact ? 44 : 56,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgRaised,
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 1),
        ),
      ),
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulse, _trackSweep]),
        builder: (context, _) {
          return Row(
            children: [
              for (var i = 0; i < _phasesInOrder.length; i++) ...[
                _PhaseNode(
                  label: _labelFor(_phasesInOrder[i]),
                  rationale: _rationaleFor(_phasesInOrder[i]),
                  state: _stateFor(i, currentIndex, visited),
                  pulse: _pulse.value,
                  compact: widget.compact,
                ),
                if (i < _phasesInOrder.length - 1)
                  Expanded(
                    child: _PhaseTrack(
                      reached: i < currentIndex ||
                          visited.contains(_phasesInOrder[i + 1]),
                      pulse: _pulse.value,
                      // Track segment between node i and node i+1 is
                      // the "approach" to phase i+1. We only sweep
                      // the segment immediately preceding the freshly
                      // entered phase — the others stay calm.
                      sweepProgress: _sweepDestinationIndex == i + 1
                          ? _trackSweep.value
                          : 0.0,
                    ),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }

  _PhaseState _stateFor(int index, int currentIndex, Set<CouncilPhase> visited) {
    final phase = _phasesInOrder[index];
    if (phase == widget.currentPhase) return _PhaseState.current;
    if (visited.contains(phase)) return _PhaseState.completed;
    if (index < currentIndex) return _PhaseState.completed;
    return _PhaseState.pending;
  }
}

enum _PhaseState { completed, current, pending }

class _PhaseNode extends StatelessWidget {
  const _PhaseNode({
    required this.label,
    required this.rationale,
    required this.state,
    required this.pulse,
    required this.compact,
  });

  final String label;
  final String? rationale;
  final _PhaseState state;
  final double pulse;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final isCurrent = state == _PhaseState.current;
    final isCompleted = state == _PhaseState.completed;

    final Color dot = switch (state) {
      _PhaseState.current => DuckColors.accentCyan,
      _PhaseState.completed => DuckColors.accentMint,
      _PhaseState.pending => DuckColors.fgMuted.withValues(alpha: 0.45),
    };
    final Color textColor = switch (state) {
      _PhaseState.current => DuckColors.fgPrimary,
      _PhaseState.completed => DuckColors.fgSecondary,
      _PhaseState.pending => DuckColors.fgMuted,
    };
    final double scale = isCurrent ? 1.0 + (pulse * 0.18) : 1.0;
    final double glowAlpha = isCurrent ? 0.28 + (pulse * 0.32) : (isCompleted ? 0.18 : 0.0);

    final tooltip = rationale ?? '';

    final dotWidget = Transform.scale(
      scale: scale,
      child: Container(
        width: compact ? 12 : 14,
        height: compact ? 12 : 14,
        decoration: BoxDecoration(
          color: dot,
          shape: BoxShape.circle,
          boxShadow: glowAlpha == 0.0
              ? null
              : [
                  BoxShadow(
                    color: dot.withValues(alpha: glowAlpha),
                    blurRadius: isCurrent ? 14 : 6,
                    spreadRadius: isCurrent ? 2 : 0,
                  ),
                ],
        ),
      ),
    );

    final node = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dotWidget,
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            color: textColor,
            fontSize: compact ? 11 : 12,
            fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w500,
            letterSpacing: 0.4,
          ),
        ),
      ],
    );

    if (tooltip.isEmpty) return node;
    return Tooltip(
      message: tooltip,
      preferBelow: true,
      waitDuration: const Duration(milliseconds: 400),
      child: node,
    );
  }
}

class _PhaseTrack extends StatelessWidget {
  const _PhaseTrack({
    required this.reached,
    required this.pulse,
    this.sweepProgress = 0.0,
  });

  final bool reached;
  final double pulse;

  /// 0..1 — when non-zero, paints a short bright highlight sweeping
  /// across the track. Fires for ~1.5s after the orchestrator enters
  /// the destination phase this track precedes, then returns to 0.
  /// Mirrors the full-stage cinema beat with a small local accent.
  final double sweepProgress;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: SizedBox(
        height: 2,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: reached
                            ? [
                                DuckColors.accentMint.withValues(alpha: 0.65),
                                DuckColors.accentCyan.withValues(
                                  alpha: 0.55 + (pulse * 0.25),
                                ),
                              ]
                            : [
                                DuckColors.fgMuted.withValues(alpha: 0.15),
                                DuckColors.fgMuted.withValues(alpha: 0.15),
                              ],
                      ),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                if (sweepProgress > 0.001 && sweepProgress < 1.0)
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _PhaseTrackSweepPainter(
                        progress: sweepProgress,
                        accent: DuckColors.accentCyan,
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Paints a short bright highlight that travels across the track when
/// a new phase is entered. Cheap one-pass linear gradient stripe, only
/// rendered while the parent has set sweepProgress > 0.
class _PhaseTrackSweepPainter extends CustomPainter {
  _PhaseTrackSweepPainter({required this.progress, required this.accent});

  final double progress;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 2 || size.height < 1) return;
    final eased = Curves.easeInOutCubic.transform(progress.clamp(0.0, 1.0));
    const stripeW = 56.0;
    final x = -stripeW + (size.width + stripeW * 2) * eased;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: 0.95),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(x, 0, stripeW, size.height));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, 0, stripeW, size.height),
        const Radius.circular(2),
      ),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _PhaseTrackSweepPainter old) {
    return old.progress != progress || old.accent != accent;
  }
}
