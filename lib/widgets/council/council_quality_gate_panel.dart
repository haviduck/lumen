import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';

/// Compact, dockable panel showing the Excellence-Doctrine quality gate
/// + the Adversarial Critic's findings. Designed to sit in the upper
/// right of the council stage (away from agent sectors) and float over
/// the backdrop without consuming layout width when the gate hasn't
/// been touched yet.
///
/// Three visual states:
///
/// 1. **Idle** — no quality check has run yet, no critique exists. Renders
///    a slim header explaining the gate exists and what unlocks it.
/// 2. **In progress** — at least one gate has been asserted but not all
///    six pass. Six bars fill individually; the Critic findings (if any)
///    are listed as collapsible cards.
/// 3. **Unlocked** — all six gates pass. Header glows mint, "Unlocked"
///    label appears, the unlock animation runs once.
class CouncilQualityGatePanel extends StatefulWidget {
  const CouncilQualityGatePanel({
    super.key,
    required this.gate,
    required this.critique,
  });

  final CouncilQualityGate gate;
  final CouncilCritique? critique;

  @override
  State<CouncilQualityGatePanel> createState() =>
      _CouncilQualityGatePanelState();
}

class _CouncilQualityGatePanelState extends State<CouncilQualityGatePanel>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _unlock;
  bool _expanded = false;
  bool _criticOpen = false;
  bool _wasUnlocked = false;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat(reverse: true);
    _unlock = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (widget.gate.allPassed) {
      _wasUnlocked = true;
    }
  }

  @override
  void didUpdateWidget(CouncilQualityGatePanel old) {
    super.didUpdateWidget(old);
    final unlocked = widget.gate.allPassed;
    if (unlocked && !_wasUnlocked) {
      _unlock.forward(from: 0);
      _wasUnlocked = true;
    } else if (!unlocked) {
      _wasUnlocked = false;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _unlock.dispose();
    super.dispose();
  }

  bool get _hasAnyAttempts => widget.gate.attempts > 0;

  int get _passedCount {
    int n = 0;
    if (widget.gate.artifactsProduced) n++;
    if (widget.gate.adversarialReviewDone) n++;
    if (widget.gate.claimsGrounded) n++;
    if (widget.gate.userAsksResolved) n++;
    if (widget.gate.risksNamed) n++;
    if (widget.gate.enoughPhasesCovered) n++;
    return n;
  }

  @override
  Widget build(BuildContext context) {
    // Idle: no quality check has run AND no critique. Show a compact
    // legend so the user knows the gate exists.
    if (!_hasAnyAttempts && widget.critique == null) {
      return _idleHeader();
    }

    final unlocked = widget.gate.allPassed;
    final passed = _passedCount;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DuckColors.bgRaised.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: unlocked
                ? DuckColors.accentMint.withValues(alpha: 0.6)
                : DuckColors.glassSeam,
            width: 1,
          ),
          boxShadow: unlocked
              ? [
                  BoxShadow(
                    color: DuckColors.accentMint.withValues(alpha: 0.35),
                    blurRadius: 22,
                    spreadRadius: 1,
                  ),
                ]
              : null,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(unlocked: unlocked, passed: passed),
            if (_expanded) _bars(),
            if (widget.critique != null) _criticSection(),
          ],
        ),
      ),
    );
  }

  Widget _idleHeader() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DuckColors.bgRaised.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: DuckColors.glassSeam),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.lock_outline,
                size: 14,
                color: DuckColors.fgMuted.withValues(alpha: 0.7),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  S.councilGateLocked,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header({required bool unlocked, required int passed}) {
    return InkWell(
      onTap: () => setState(() => _expanded = !_expanded),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Row(
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, _) {
                final glow = unlocked ? 0.6 : 0.25 + (_pulse.value * 0.3);
                return Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: unlocked
                        ? DuckColors.accentMint
                        : DuckColors.accentCyan,
                    shape: BoxShape.circle,
                    boxShadow: [
                      BoxShadow(
                        color: (unlocked
                                ? DuckColors.accentMint
                                : DuckColors.accentCyan)
                            .withValues(alpha: glow),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                );
              },
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    S.councilGatePanelTitle,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DuckColors.fgPrimary,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.6,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    unlocked
                        ? S.councilGateUnlocked
                        : S.councilGateProgress(passed, 6),
                    style: TextStyle(
                      fontSize: 10,
                      color: unlocked
                          ? DuckColors.accentMint
                          : DuckColors.fgSecondary,
                      letterSpacing: 0.4,
                    ),
                  ),
                ],
              ),
            ),
            Text(
              S.councilGateAttempts(widget.gate.attempts),
              style: const TextStyle(
                fontSize: 10,
                color: DuckColors.fgMuted,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 6),
            Icon(
              _expanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: DuckColors.fgMuted,
            ),
          ],
        ),
      ),
    );
  }

  Widget _bars() {
    final entries = <_GateRow>[
      _GateRow(S.councilGateArtifacts, widget.gate.artifactsProduced),
      _GateRow(S.councilGateReview, widget.gate.adversarialReviewDone),
      _GateRow(S.councilGateClaims, widget.gate.claimsGrounded),
      _GateRow(S.councilGateUserAsks, widget.gate.userAsksResolved),
      _GateRow(S.councilGateRisks, widget.gate.risksNamed),
      _GateRow(S.councilGatePhases, widget.gate.enoughPhasesCovered),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final e in entries) ...[
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(
                    e.passed ? Icons.check_circle : Icons.radio_button_unchecked,
                    size: 12,
                    color: e.passed
                        ? DuckColors.accentMint
                        : DuckColors.fgMuted.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      e.label,
                      style: TextStyle(
                        fontSize: 11,
                        color: e.passed
                            ? DuckColors.fgPrimary
                            : DuckColors.fgSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: SizedBox(
                height: 3,
                child: LinearProgressIndicator(
                  value: e.passed ? 1.0 : 0.0,
                  backgroundColor:
                      DuckColors.fgMuted.withValues(alpha: 0.12),
                  valueColor: AlwaysStoppedAnimation(
                    e.passed ? DuckColors.accentMint : DuckColors.accentCyan,
                  ),
                ),
              ),
            ),
          ],
          if (widget.gate.summary.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: DuckColors.bgDeepest.withValues(alpha: 0.45),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: DuckColors.glassSeam),
              ),
              child: Text(
                widget.gate.summary,
                style: const TextStyle(
                  fontSize: 10.5,
                  color: DuckColors.fgSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _criticSection() {
    final critique = widget.critique!;
    final blockers = critique.blockerCount;
    final majors = critique.majorCount;
    final minors = critique.attacks.length - blockers - majors;
    final hasBlocker = blockers > 0 && !critique.allBlockingResolved;

    return Container(
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => setState(() => _criticOpen = !_criticOpen),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
              child: Row(
                children: [
                  Icon(
                    hasBlocker
                        ? Icons.warning_amber_rounded
                        : Icons.gavel_outlined,
                    size: 14,
                    color: hasBlocker
                        ? const Color(0xFFFF6D00)
                        : DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.councilCriticTitle,
                          style: const TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgPrimary,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.6,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          critique.attacks.isEmpty
                              ? S.councilCriticEmpty
                              : _criticTally(blockers, majors, minors),
                          style: TextStyle(
                            fontSize: 10,
                            color: hasBlocker
                                ? const Color(0xFFFFAB91)
                                : DuckColors.fgSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _criticOpen ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: DuckColors.fgMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_criticOpen)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (critique.summary.isNotEmpty) ...[
                      Text(
                        critique.summary,
                        style: const TextStyle(
                          fontSize: 11,
                          color: DuckColors.fgPrimary,
                          fontStyle: FontStyle.italic,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 10),
                    ],
                    for (final atk in critique.attacks)
                      _CriticAttackCard(attack: atk),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _criticTally(int b, int m, int min) {
    final parts = <String>[];
    if (b > 0) parts.add(S.councilCriticBlockerLabel(b));
    if (m > 0) parts.add(S.councilCriticMajorLabel(m));
    if (min > 0) parts.add(S.councilCriticMinorLabel(min));
    if (parts.isEmpty) return S.councilCriticEmpty;
    return parts.join(' · ');
  }
}

class _GateRow {
  const _GateRow(this.label, this.passed);
  final String label;
  final bool passed;
}

class _CriticAttackCard extends StatelessWidget {
  const _CriticAttackCard({required this.attack});
  final CouncilCriticAttack attack;

  @override
  Widget build(BuildContext context) {
    final Color severityColor = switch (attack.severity.toLowerCase()) {
      'blocker' => const Color(0xFFFF1744),
      'major' => const Color(0xFFFF6D00),
      _ => DuckColors.fgMuted,
    };
    final String severityLabel = attack.severity.toUpperCase();
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: severityColor.withValues(alpha: 0.55),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1,
                ),
                decoration: BoxDecoration(
                  color: severityColor.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  severityLabel,
                  style: TextStyle(
                    color: severityColor,
                    fontSize: 9,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                attack.id,
                style: const TextStyle(
                  fontSize: 10,
                  color: DuckColors.fgMuted,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const Spacer(),
              if (attack.resolved)
                const Icon(
                  Icons.check_circle,
                  size: 12,
                  color: DuckColors.accentMint,
                ),
            ],
          ),
          const SizedBox(height: 6),
          _kv(S.councilCriticTargetLabel, attack.target),
          const SizedBox(height: 4),
          _kv(S.councilCriticAttackLabel, attack.attack),
          if (attack.acceptance.isNotEmpty) ...[
            const SizedBox(height: 4),
            _kv(S.councilCriticAcceptanceLabel, attack.acceptance),
          ],
          const SizedBox(height: 4),
          Text(
            attack.resolved
                ? S.councilCriticResolved
                : S.councilCriticUnresolved,
            style: TextStyle(
              fontSize: 10,
              color: attack.resolved
                  ? DuckColors.accentMint
                  : DuckColors.fgMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }

  Widget _kv(String label, String value) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: const TextStyle(
              fontSize: 9,
              color: DuckColors.fgMuted,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
          TextSpan(
            text: value,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgPrimary,
              height: 1.35,
            ),
          ),
        ],
      ),
    );
  }
}
