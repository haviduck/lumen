import 'package:flutter/material.dart';

import '../../../services/council/council_models.dart';
import '../../../theme/app_colors.dart';
import '../compact_model_label.dart';
import 'wizard_tokens.dart';

/// A single agent in the convened roster.
///
/// Visual contract:
///   • Thin role-coloured top rail (2px) — colour-codes the slot at a
///     glance without bathing the whole card in role colour.
///   • Header row: role icon + name (editable inline via TextField with
///     no decoration so it reads as title text, not a form input).
///   • Role chip on the right (PopupMenuButton) — tap to change.
///   • Footer row: monospace short model label (always visible) plus a
///     **slot for agent_1's quick-action picker** — see slot contract
///     below. If [modelSlot] is null we render a built-in dropdown so
///     the card stays usable in isolation.
///   • Optional remove button as a small ghost icon top-right; hidden
///     for the orchestrator and when [onRemove] is null.
///
/// Slot contract for agent_1 (per-agent model quick-actions):
///   • [modelSlot] is rendered inside a [SizedBox] whose height is
///     [WizardTokens.agentCardModelSlotHeight] (36 logical px) and
///     whose width is the full card body width minus
///     [WizardTokens.s12] horizontal padding on each side.
///   • The slot child OWNS the model identity for this agent; the
///     card does NOT also call [onModelChanged] when [modelSlot] is
///     non-null. That callback / [availableModels] remain only for
///     the fallback dropdown.
///   • The slot must remain interactive when the rest of the card is
///     tapped — the card's outer `Material`/`InkWell` is intentionally
///     scoped to chrome only, never wrapping the slot.
///   • If agent_1's picker grows taller than 36px the card grows by
///     exactly that delta — it must NEVER scroll inside the slot,
///     because the wizard scroll view already owns vertical scroll.
class WizardAgentCard extends StatelessWidget {
  final TextEditingController nameController;
  final RolePreset role;
  final ValueChanged<RolePreset> onRoleChanged;
  final String? selectedModel;
  final List<String> availableModels;
  final ValueChanged<String?> onModelChanged;

  /// Per-agent model picker slot — owned by agent_1. See class docs.
  final Widget? modelSlot;

  final TextEditingController? customRoleController;
  final VoidCallback? onRemove;
  final VoidCallback onChanged;
  final bool isOrchestrator;
  final int? indexLabel;

  const WizardAgentCard({
    super.key,
    required this.nameController,
    required this.role,
    required this.onRoleChanged,
    required this.selectedModel,
    required this.availableModels,
    required this.onModelChanged,
    required this.onChanged,
    this.modelSlot,
    this.customRoleController,
    this.onRemove,
    this.isOrchestrator = false,
    this.indexLabel,
  });

  @override
  Widget build(BuildContext context) {
    final accent = WizardRolePalette.colorFor(role);

    return Container(
      decoration: BoxDecoration(
        color: isOrchestrator
            ? DuckColors.bgGlassHi
            : DuckColors.bgChip.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(WizardTokens.radiusL),
        border: Border.all(
          color: isOrchestrator
              ? accent.withValues(alpha: 0.32)
              : DuckColors.border,
          width: isOrchestrator ? 0.8 : 0.6,
        ),
        boxShadow: WizardTokens.cardShadow(
          accent: isOrchestrator ? accent : null,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Thin coloured top rail — the load-bearing tactical accent.
          Container(
            height: 2,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.0),
                  accent.withValues(alpha: 0.85),
                  accent.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              WizardTokens.s12,
              WizardTokens.s10,
              WizardTokens.s8,
              WizardTokens.s10,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Header(
                  accent: accent,
                  role: role,
                  nameController: nameController,
                  isOrchestrator: isOrchestrator,
                  indexLabel: indexLabel,
                  onChanged: onChanged,
                  onRoleChanged: onRoleChanged,
                  onRemove: onRemove,
                ),
                if (role == RolePreset.custom &&
                    customRoleController != null) ...[
                  const SizedBox(height: WizardTokens.s10),
                  TextField(
                    controller: customRoleController,
                    maxLines: 2,
                    style: const TextStyle(
                      color: DuckColors.fgPrimary,
                      fontSize: 12,
                    ),
                    onChanged: (_) => onChanged(),
                    decoration: InputDecoration(
                      hintText: 'Custom role description…',
                      hintStyle: const TextStyle(
                        color: DuckColors.fgSubtle,
                        fontSize: 11.5,
                      ),
                      isDense: true,
                      filled: true,
                      fillColor: DuckColors.bgDeeper,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(WizardTokens.radiusS),
                        borderSide: BorderSide(
                          color: accent.withValues(alpha: 0.25),
                          width: 0.6,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(WizardTokens.radiusS),
                        borderSide: BorderSide(
                          color: accent.withValues(alpha: 0.25),
                          width: 0.6,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(WizardTokens.radiusS),
                        borderSide: BorderSide(
                          color: accent.withValues(alpha: 0.6),
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: WizardTokens.s10),
                // Model slot — agent_1's territory.
                _ModelSlot(
                  accent: accent,
                  selectedModel: selectedModel,
                  availableModels: availableModels,
                  onModelChanged: onModelChanged,
                  custom: modelSlot,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final Color accent;
  final RolePreset role;
  final TextEditingController nameController;
  final bool isOrchestrator;
  final int? indexLabel;
  final VoidCallback onChanged;
  final ValueChanged<RolePreset> onRoleChanged;
  final VoidCallback? onRemove;

  const _Header({
    required this.accent,
    required this.role,
    required this.nameController,
    required this.isOrchestrator,
    required this.indexLabel,
    required this.onChanged,
    required this.onRoleChanged,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: accent.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(WizardTokens.radiusS),
            border: Border.all(
              color: accent.withValues(alpha: 0.35),
              width: 0.6,
            ),
          ),
          child: Icon(
            WizardRolePalette.iconFor(role),
            size: 16,
            color: accent,
          ),
        ),
        const SizedBox(width: WizardTokens.s10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  if (indexLabel != null) ...[
                    Text(
                      indexLabel!.toString().padLeft(2, '0'),
                      style: WizardTokens.eyebrow.copyWith(
                        color: DuckColors.fgSubtle,
                      ),
                    ),
                    const SizedBox(width: WizardTokens.s6),
                  ],
                  if (isOrchestrator)
                    Padding(
                      padding: const EdgeInsets.only(right: WizardTokens.s6),
                      child: WizardPill(
                        label: 'ORCHESTRATOR',
                        color: accent,
                        solid: true,
                      ),
                    ),
                ],
              ),
              if (indexLabel != null || isOrchestrator)
                const SizedBox(height: 2),
              SizedBox(
                height: 22,
                child: TextField(
                  controller: nameController,
                  onChanged: (_) => onChanged(),
                  style: WizardTokens.agentName,
                  cursorColor: accent,
                  cursorWidth: 1.2,
                  decoration: const InputDecoration(
                    isCollapsed: true,
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.zero,
                    hintText: 'Name…',
                    hintStyle: TextStyle(
                      color: DuckColors.fgSubtle,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: WizardTokens.s8),
        _RoleMenu(role: role, accent: accent, onRoleChanged: onRoleChanged),
        if (onRemove != null) ...[
          const SizedBox(width: 2),
          IconButton(
            tooltip: 'Remove agent',
            onPressed: onRemove,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            padding: EdgeInsets.zero,
            icon: const Icon(
              Icons.close,
              size: 14,
              color: DuckColors.fgSubtle,
            ),
          ),
        ],
      ],
    );
  }
}

class _RoleMenu extends StatelessWidget {
  final RolePreset role;
  final Color accent;
  final ValueChanged<RolePreset> onRoleChanged;

  const _RoleMenu({
    required this.role,
    required this.accent,
    required this.onRoleChanged,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<RolePreset>(
      tooltip: 'Change role',
      position: PopupMenuPosition.under,
      color: DuckColors.bgRaisedHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        side: const BorderSide(color: DuckColors.border),
      ),
      onSelected: onRoleChanged,
      itemBuilder: (_) => [
        for (final r in RolePreset.values)
          PopupMenuItem<RolePreset>(
            value: r,
            height: 34,
            child: Row(
              children: [
                Icon(
                  WizardRolePalette.iconFor(r),
                  size: 14,
                  color: WizardRolePalette.colorFor(r),
                ),
                const SizedBox(width: 8),
                Text(
                  WizardRolePalette.labelFor(r),
                  style: WizardTokens.pillLabel.copyWith(
                    color: r == role
                        ? DuckColors.fgPrimary
                        : DuckColors.fgMuted,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: WizardTokens.s8,
          vertical: 5,
        ),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(WizardTokens.radiusS),
          border: Border.all(
            color: accent.withValues(alpha: 0.4),
            width: 0.6,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              WizardRolePalette.labelFor(role),
              style: WizardTokens.pillLabel.copyWith(color: accent),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.expand_more,
              size: 12,
              color: accent.withValues(alpha: 0.7),
            ),
          ],
        ),
      ),
    );
  }
}

class _ModelSlot extends StatelessWidget {
  final Color accent;
  final String? selectedModel;
  final List<String> availableModels;
  final ValueChanged<String?> onModelChanged;
  final Widget? custom;

  const _ModelSlot({
    required this.accent,
    required this.selectedModel,
    required this.availableModels,
    required this.onModelChanged,
    required this.custom,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: WizardTokens.agentCardModelSlotHeight,
      child: custom ??
          _FallbackModelPicker(
            accent: accent,
            selectedModel: selectedModel,
            availableModels: availableModels,
            onModelChanged: onModelChanged,
          ),
    );
  }
}

/// Fallback model picker used when agent_1's slot widget is not yet
/// wired in. Visually consistent with what agent_1 should aim for so
/// the seam isn't jarring during their iteration.
class _FallbackModelPicker extends StatelessWidget {
  final Color accent;
  final String? selectedModel;
  final List<String> availableModels;
  final ValueChanged<String?> onModelChanged;

  const _FallbackModelPicker({
    required this.accent,
    required this.selectedModel,
    required this.availableModels,
    required this.onModelChanged,
  });

  @override
  Widget build(BuildContext context) {
    final compact = compactModelLabel(selectedModel ?? '');
    return PopupMenuButton<String>(
      tooltip: 'Change model',
      position: PopupMenuPosition.under,
      color: DuckColors.bgRaisedHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        side: const BorderSide(color: DuckColors.border),
      ),
      onSelected: (m) => onModelChanged(m),
      itemBuilder: (_) => [
        for (final m in availableModels)
          PopupMenuItem<String>(
            value: m,
            height: 32,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  compactModelLabel(m),
                  style: WizardTokens.pillLabel.copyWith(
                    color: m == selectedModel
                        ? accent
                        : DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  m,
                  style: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: WizardTokens.s10,
          vertical: WizardTokens.s8,
        ),
        decoration: BoxDecoration(
          color: DuckColors.bgDeeper,
          borderRadius: BorderRadius.circular(WizardTokens.radiusS),
          border: Border.all(
            color: DuckColors.border,
            width: 0.6,
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.memory, size: 12, color: accent),
            const SizedBox(width: 6),
            Text(
              'MODEL',
              style: WizardTokens.eyebrow.copyWith(
                color: DuckColors.fgSubtle,
                fontSize: 9,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 1,
              height: 10,
              color: DuckColors.glassSeam,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                compact,
                overflow: TextOverflow.ellipsis,
                style: WizardTokens.pillLabel.copyWith(
                  color: DuckColors.fgPrimary,
                  fontSize: 11.5,
                ),
              ),
            ),
            Icon(
              Icons.expand_more,
              size: 14,
              color: DuckColors.fgMuted,
            ),
          ],
        ),
      ),
    );
  }
}
