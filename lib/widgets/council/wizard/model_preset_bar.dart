import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../compact_model_label.dart';
import 'model_tier.dart';
import 'wizard_tokens.dart';

/// Council preset bar. Three-button row that broadcasts a model tier
/// across every agent in the roster. Visual language matches the rest
/// of the wizard via [WizardTokens] / [WizardEyebrow] so it sits
/// above the agent grid as a section header, not a foreign bolt-on.
///
/// Active-tier highlighting:
///   • when every agent shares one tier, that preset's button glows
///     accent and the bar reads as "you are on Balanced".
///   • when rows disagree, no preset is active and a "custom" badge
///     appears on the right.
class ModelPresetBar extends StatelessWidget {
  final List<String> models;
  final ModelTier? activeTier;
  final ValueChanged<ModelTier> onApply;

  const ModelPresetBar({
    super.key,
    required this.models,
    required this.activeTier,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final isMac = Theme.of(context).platform == TargetPlatform.macOS;
    final mod = isMac ? '⌘' : 'Ctrl';
    final entries = <_PresetSpec>[
      _PresetSpec(ModelTier.fast, 'Fast', '$mod 1', DuckColors.stateOk),
      _PresetSpec(
        ModelTier.balanced,
        'Balanced',
        '$mod 2',
        DuckColors.accentCyan,
      ),
      _PresetSpec(
        ModelTier.premium,
        'Premium',
        '$mod 3',
        DuckColors.accentPurple,
      ),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: WizardTokens.s12,
        vertical: WizardTokens.s10,
      ),
      decoration: BoxDecoration(
        color: DuckColors.bgChip.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 1,
            color: DuckColors.fgSubtle.withValues(alpha: 0.6),
          ),
          const SizedBox(width: WizardTokens.s8),
          const Text('COUNCIL PRESET', style: WizardTokens.eyebrow),
          const SizedBox(width: WizardTokens.s12),
          for (final spec in entries) ...[
            _PresetButton(
              label: spec.label,
              hint: spec.hint,
              accent: spec.accent,
              active: activeTier == spec.tier,
              model: pickModelForTier(spec.tier, models),
              onTap: () => onApply(spec.tier),
            ),
            const SizedBox(width: WizardTokens.s6),
          ],
          const Spacer(),
          if (activeTier == null) const _CustomBadge(),
          const SizedBox(width: WizardTokens.s6),
          Tooltip(
            message:
                'Tab between agents · ↑/↓ change model · $mod D fill down · Enter open picker',
            child: const Icon(
              Icons.keyboard_outlined,
              size: 14,
              color: DuckColors.fgSubtle,
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetSpec {
  final ModelTier tier;
  final String label;
  final String hint;
  final Color accent;
  const _PresetSpec(this.tier, this.label, this.hint, this.accent);
}

class _PresetButton extends StatelessWidget {
  final String label;
  final String hint;
  final Color accent;
  final bool active;
  final String? model;
  final VoidCallback onTap;
  const _PresetButton({
    required this.label,
    required this.hint,
    required this.accent,
    required this.active,
    required this.model,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final disabled = model == null;
    return Tooltip(
      message: disabled
          ? '$label · no matching model'
          : '$label · ${compactModelLabel(model!)}  ($hint)',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(WizardTokens.radiusS),
          onTap: disabled ? null : onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            padding: const EdgeInsets.symmetric(
              horizontal: WizardTokens.s10,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: active
                  ? accent.withValues(alpha: 0.16)
                  : DuckColors.bgDeeper,
              borderRadius: BorderRadius.circular(WizardTokens.radiusS),
              border: Border.all(
                color: active
                    ? accent.withValues(alpha: 0.7)
                    : DuckColors.border,
                width: active ? 0.8 : 0.6,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 6,
                  height: 6,
                  margin: const EdgeInsets.only(right: WizardTokens.s8),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: active ? accent : accent.withValues(alpha: 0.45),
                  ),
                ),
                Text(
                  label,
                  style: WizardTokens.pillLabel.copyWith(
                    color: disabled
                        ? DuckColors.fgSubtle
                        : (active ? accent : DuckColors.fgPrimary),
                    fontSize: 11,
                  ),
                ),
                const SizedBox(width: WizardTokens.s8),
                Text(
                  hint,
                  style: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 9.5,
                    letterSpacing: 0.6,
                    fontFamily: 'monospace',
                    fontFamilyFallback: ['Consolas', 'Menlo', 'Courier New'],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CustomBadge extends StatelessWidget {
  const _CustomBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper,
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        border: Border.all(color: DuckColors.glassSeam),
      ),
      child: Text(
        'CUSTOM',
        style: WizardTokens.eyebrow.copyWith(
          color: DuckColors.fgSubtle,
          fontSize: 9,
        ),
      ),
    );
  }
}
