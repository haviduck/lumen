import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/process_filters.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Single preset chip in the process manager filter bar.
///
/// Visual states:
///   * selected → filled cyan with dark text
///   * unselected → bg chip with subtle border
///   * hovered → slightly raised
///
/// The trailing badge shows the *count* of matching processes
/// after the rest of the filters apply, so the user can tell at
/// a glance whether "Node" would actually narrow the list before
/// clicking.
class ProcessFilterChip extends StatelessWidget {
  final ProcessFilterPreset preset;
  final bool selected;
  final int count;
  final VoidCallback onTap;

  const ProcessFilterChip({
    super.key,
    required this.preset,
    required this.selected,
    required this.count,
    required this.onTap,
  });

  String get _label {
    switch (preset) {
      case ProcessFilterPreset.all:
        return S.processFilterAll;
      case ProcessFilterPreset.node:
        return S.processFilterNode;
      case ProcessFilterPreset.python:
        return S.processFilterPython;
      case ProcessFilterPreset.java:
        return S.processFilterJava;
      case ProcessFilterPreset.workspace:
        return S.processFilterWorkspace;
      case ProcessFilterPreset.lumen:
        return S.processFilterLumen;
    }
  }

  @override
  Widget build(BuildContext context) {
    final fg = selected ? DuckColors.bgDeepest : DuckColors.fgPrimary;
    final bg = selected ? DuckColors.accentCyan : DuckColors.bgChip;
    final borderColor = selected ? DuckColors.accentCyan : DuckColors.border;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _label,
              style: TextStyle(
                fontSize: 12,
                color: fg,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: selected
                    ? DuckColors.bgDeepest.withValues(alpha: 0.25)
                    : DuckColors.bgRaisedHi,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: selected ? DuckColors.bgDeepest : DuckColors.fgMuted,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
