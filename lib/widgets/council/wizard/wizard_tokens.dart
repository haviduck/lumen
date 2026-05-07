import 'package:flutter/material.dart';

import '../../../services/council/council_models.dart';
import '../../../theme/app_colors.dart';

/// Centralised visual tokens for the Convene-the-Council wizard.
///
/// The wizard intentionally diverges from the rest of Lumen chrome in a
/// few places (larger display type, role-coded accents, monospace
/// eyebrows). Those divergences live here so they are reusable across
/// every wizard sub-widget and easy to retune in one pass.
class WizardTokens {
  WizardTokens._();

  // ── Spacing rhythm ──
  // 4px grid, but the wizard uses a sparser cadence than dense IDE
  // chrome — section gaps lean on 24/32 to give the composition room
  // to breathe without leaving cards stranded on a vast empty canvas.
  static const double s2 = 2;
  static const double s4 = 4;
  static const double s6 = 6;
  static const double s8 = 8;
  static const double s10 = 10;
  static const double s12 = 12;
  static const double s14 = 14;
  static const double s16 = 16;
  static const double s18 = 18;
  static const double s20 = 20;
  static const double s24 = 24;
  static const double s28 = 28;
  static const double s32 = 32;

  // ── Radii ──
  static const double radiusXL = 20;
  static const double radiusL = 14;
  static const double radiusM = 10;
  static const double radiusS = 6;
  static const double radiusHair = 2;

  // ── Slot contract for per-agent model-picker (owned by agent_1) ──
  // The agent card reserves a fixed-height footer row for the quick
  // model-picker. agent_1 must paint inside this height so cards stay
  // a uniform vertical rhythm in the 2-col grid.
  static const double agentCardModelSlotHeight = 36;

  // ── Typography ──
  static TextStyle display(BuildContext context) => const TextStyle(
        fontSize: 26,
        height: 1.05,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.6,
        color: DuckColors.pearlWhite,
      );

  static TextStyle subtitle(BuildContext context) => const TextStyle(
        fontSize: 12.5,
        height: 1.45,
        color: DuckColors.fgMuted,
        letterSpacing: 0.05,
      );

  // Eyebrow / section labels — monospaced, uppercased, wide tracking.
  static const TextStyle eyebrow = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
    fontSize: 10,
    fontWeight: FontWeight.w700,
    letterSpacing: 1.6,
    color: DuckColors.fgMuted,
  );

  static const TextStyle pillLabel = TextStyle(
    fontFamily: 'monospace',
    fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
    fontSize: 10.5,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.4,
  );

  static const TextStyle agentName = TextStyle(
    color: DuckColors.fgPrimary,
    fontWeight: FontWeight.w700,
    fontSize: 13.5,
    letterSpacing: -0.1,
  );

  static const TextStyle bodyLabel = TextStyle(
    color: DuckColors.fgMuted,
    fontSize: 11.5,
    height: 1.4,
  );

  // ── Shadows ──
  static List<BoxShadow> sheetShadow() => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: 60,
          spreadRadius: -8,
          offset: const Offset(0, 24),
        ),
        BoxShadow(
          color: DuckColors.accentPurple.withValues(alpha: 0.07),
          blurRadius: 80,
          spreadRadius: -16,
          offset: const Offset(0, 0),
        ),
        BoxShadow(
          color: DuckColors.accentCyan.withValues(alpha: 0.05),
          blurRadius: 36,
          offset: const Offset(0, 8),
        ),
      ];

  static List<BoxShadow> cardShadow({Color? accent}) => [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.28),
          blurRadius: 14,
          offset: const Offset(0, 6),
        ),
        if (accent != null)
          BoxShadow(
            color: accent.withValues(alpha: 0.10),
            blurRadius: 22,
            spreadRadius: -6,
            offset: const Offset(0, 0),
          ),
      ];
}

/// Tactical role colour mapping. Each preset gets a distinct accent so
/// a glance at the roster reads as colour-coded slots, not a wall of
/// identical cards. Colours pulled from the existing Nord palette so
/// they coexist with the Council theater.
class WizardRolePalette {
  WizardRolePalette._();

  static Color colorFor(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => DuckColors.stateError,
      RolePreset.reviewer => DuckColors.accentCyan,
      RolePreset.researcher => DuckColors.accentPurple,
      RolePreset.architect => DuckColors.stateInfo,
      RolePreset.tester => DuckColors.stateOk,
      RolePreset.writer => DuckColors.accentDuck,
      RolePreset.custom => DuckColors.accentMint,
    };
  }

  static IconData iconFor(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => Icons.gpp_maybe_outlined,
      RolePreset.reviewer => Icons.fact_check_outlined,
      RolePreset.researcher => Icons.travel_explore_outlined,
      RolePreset.architect => Icons.account_tree_outlined,
      RolePreset.tester => Icons.science_outlined,
      RolePreset.writer => Icons.edit_note_outlined,
      RolePreset.custom => Icons.tune,
    };
  }

  static String labelFor(RolePreset role) {
    return switch (role) {
      RolePreset.pentester => 'PENTESTER',
      RolePreset.reviewer => 'REVIEWER',
      RolePreset.researcher => 'RESEARCHER',
      RolePreset.architect => 'ARCHITECT',
      RolePreset.tester => 'TESTER',
      RolePreset.writer => 'WRITER',
      RolePreset.custom => 'CUSTOM',
    };
  }
}

/// Small helper used by every wizard surface to render a section
/// eyebrow (uppercase mono label + thin rule).
class WizardEyebrow extends StatelessWidget {
  final String label;
  final Widget? trailing;

  const WizardEyebrow({super.key, required this.label, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: WizardTokens.s10),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 1,
            color: DuckColors.fgSubtle.withValues(alpha: 0.6),
          ),
          const SizedBox(width: WizardTokens.s8),
          Text(label, style: WizardTokens.eyebrow),
          const SizedBox(width: WizardTokens.s10),
          Expanded(
            child: Container(
              height: 1,
              color: DuckColors.glassSeam,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: WizardTokens.s10),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Status pill — monospace label inside a thin-bordered chip.
class WizardPill extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  final bool solid;

  const WizardPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
    this.solid = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WizardTokens.s8,
        vertical: 3,
      ),
      decoration: BoxDecoration(
        color: solid
            ? color.withValues(alpha: 0.18)
            : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        border: Border.all(
          color: color.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: WizardTokens.pillLabel.copyWith(color: color),
          ),
        ],
      ),
    );
  }
}
