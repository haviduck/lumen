import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';

/// Preset date ranges for the usage panel.
enum UsageRange {
  today,
  last7,
  last30,
  last90,
  allTime;

  /// Inclusive lower bound, in LOCAL time. `null` for "all time" so
  /// the aggregator falls back to "first entry's day".
  DateTime? since(DateTime now) {
    switch (this) {
      case UsageRange.today:
        return DateTime(now.year, now.month, now.day);
      case UsageRange.last7:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 6));
      case UsageRange.last30:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 29));
      case UsageRange.last90:
        return DateTime(now.year, now.month, now.day)
            .subtract(const Duration(days: 89));
      case UsageRange.allTime:
        return null;
    }
  }

  DateTime until(DateTime now) =>
      DateTime(now.year, now.month, now.day, 23, 59, 59);

  String get label => switch (this) {
        UsageRange.today => S.llmUsageRangeToday,
        UsageRange.last7 => S.llmUsageRangeLast7,
        UsageRange.last30 => S.llmUsageRangeLast30,
        UsageRange.last90 => S.llmUsageRangeLast90,
        UsageRange.allTime => S.llmUsageRangeAllTime,
      };
}

/// Filter bar above the dashboard — date range pills + model /
/// provider dropdowns + reset/refresh actions. Pure presentation;
/// emits changes via [onChanged] callbacks.
class UsageFilterBar extends StatelessWidget {
  final UsageRange range;
  final String? modelFilter;
  final String? providerFilter;
  final String? workspaceFilter;
  final List<String> availableModels;
  final List<String> availableProviders;
  final List<String> availableWorkspaces;
  final ValueChanged<UsageRange> onRangeChanged;
  final ValueChanged<String?> onModelChanged;
  final ValueChanged<String?> onProviderChanged;
  final ValueChanged<String?> onWorkspaceChanged;
  final VoidCallback onReset;
  final VoidCallback onRefresh;
  final bool refreshing;

  const UsageFilterBar({
    super.key,
    required this.range,
    required this.modelFilter,
    required this.providerFilter,
    required this.workspaceFilter,
    required this.availableModels,
    required this.availableProviders,
    required this.availableWorkspaces,
    required this.onRangeChanged,
    required this.onModelChanged,
    required this.onProviderChanged,
    required this.onWorkspaceChanged,
    required this.onReset,
    required this.onRefresh,
    required this.refreshing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.border, width: 0.5),
        ),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Range pills cluster.
          Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.border, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final r in UsageRange.values)
                  _RangePill(
                    label: r.label,
                    selected: r == range,
                    onTap: () => onRangeChanged(r),
                  ),
              ],
            ),
          ),
          _DropdownButton(
            icon: Icons.smart_toy_outlined,
            label: modelFilter ?? S.llmUsageFilterAllModels,
            onTap: () => _pickModel(context),
          ),
          _DropdownButton(
            icon: Icons.dns_outlined,
            label: providerFilter == null
                ? S.llmUsageFilterAllProviders
                : _providerLabel(providerFilter!),
            onTap: () => _pickProvider(context),
          ),
          _DropdownButton(
            icon: Icons.folder_outlined,
            label: workspaceFilter == null
                ? S.llmUsageFilterAllProjects
                : _workspaceLabel(workspaceFilter!),
            onTap: () => _pickWorkspace(context),
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: refreshing ? Icons.refresh : Icons.refresh,
            label: S.llmUsageRefresh,
            onTap: refreshing ? null : onRefresh,
          ),
          _ActionButton(
            icon: Icons.delete_outline,
            label: S.llmUsageReset,
            onTap: onReset,
            danger: true,
          ),
        ],
      ),
    );
  }

  Future<void> _pickModel(BuildContext context) async {
    final position = _relativeRectFor(context);
    final picked = await showFastMenu<String?>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String?>>[
        _menuRow(value: null, label: S.llmUsageFilterAllModels,
            selected: modelFilter == null),
        if (availableModels.isNotEmpty) const PopupMenuDivider(),
        for (final m in availableModels)
          _menuRow(value: m, label: m, selected: modelFilter == m),
      ],
    );
    onModelChanged(picked);
  }

  Future<void> _pickProvider(BuildContext context) async {
    final position = _relativeRectFor(context);
    final picked = await showFastMenu<String?>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String?>>[
        _menuRow(
          value: null,
          label: S.llmUsageFilterAllProviders,
          selected: providerFilter == null,
        ),
        if (availableProviders.isNotEmpty) const PopupMenuDivider(),
        for (final p in availableProviders)
          _menuRow(
            value: p,
            label: _providerLabel(p),
            selected: providerFilter == p,
          ),
      ],
    );
    onProviderChanged(picked);
  }

  Future<void> _pickWorkspace(BuildContext context) async {
    final position = _relativeRectFor(context);
    final picked = await showFastMenu<String?>(
      context: context,
      position: position,
      items: <PopupMenuEntry<String?>>[
        _menuRow(
          value: null,
          label: S.llmUsageFilterAllProjects,
          selected: workspaceFilter == null,
        ),
        if (availableWorkspaces.isNotEmpty) const PopupMenuDivider(),
        for (final w in availableWorkspaces)
          _menuRow(
            value: w,
            label: _workspaceLabel(w),
            selected: workspaceFilter == w,
          ),
      ],
    );
    onWorkspaceChanged(picked);
  }

  RelativeRect _relativeRectFor(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (box == null || overlay == null) {
      return RelativeRect.fill;
    }
    final topLeft = box.localToGlobal(Offset.zero, ancestor: overlay);
    return RelativeRect.fromLTRB(
      topLeft.dx,
      topLeft.dy + box.size.height,
      overlay.size.width - topLeft.dx - box.size.width,
      0,
    );
  }

  PopupMenuItem<String?> _menuRow({
    required String? value,
    required String label,
    required bool selected,
  }) {
    return PopupMenuItem<String?>(
      value: value,
      child: Row(
        children: [
          SizedBox(
            width: 14,
            child: selected
                ? const Icon(Icons.check, size: 12,
                    color: DuckColors.accentCyan)
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  static String _workspaceLabel(String path) {
    final sep = RegExp(r'[\\/]');
    final parts = path.split(sep);
    return parts.isNotEmpty ? parts.last : path;
  }

  static String _providerLabel(String p) {
    return switch (p) {
      'claude' => 'Claude',
      'copilot' => 'GitHub Copilot',
      'gemini' => 'Gemini',
      'ollama' => 'Ollama',
      'ollama-cloud' => 'Ollama Cloud',
      _ => p,
    };
  }
}

class _RangePill extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _RangePill({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS - 1),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _DropdownButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _DropdownButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.border, width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 12, color: DuckColors.fgMuted),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 180),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ),
              const SizedBox(width: 3),
              const Icon(
                Icons.expand_more,
                size: 13,
                color: DuckColors.fgMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool danger;
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final fg = danger ? DuckColors.stateError : DuckColors.fgPrimary;
    final disabled = onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      child: Opacity(
        opacity: disabled ? 0.5 : 1,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.border, width: 0.5),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 12, color: fg),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(fontSize: 11, color: fg),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
