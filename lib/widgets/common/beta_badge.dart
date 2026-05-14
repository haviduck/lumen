import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';

/// Compact, reusable "BETA" pill used to mark in-development features.
///
/// Visual contract:
///   • Tiny pill (~16 px tall) with an outline + light tinted fill.
///   • Uppercase letterspaced label, 9.5 px, weight 800.
///   • Warm `accentDuck` palette by default — communicates
///     "construction tape" without literally being yellow-and-black.
///   • Tooltip-by-default explaining what BETA means here, so the
///     user can hover for context without consuming chrome real-estate.
///
/// Usage:
///   ```dart
///   Row(children: [
///     Text(S.councilTitle, ...),
///     SizedBox(width: 8),
///     BetaBadge(),
///   ])
///   ```
///
/// Per the project's user-rule on i18n, all label/tooltip text routes
/// through [S]; the default ("BETA") lives in
/// `lib/l10n/strings.dart::S.councilBetaBadgeLabel`. Pass an explicit
/// [label] / [tooltip] to override at a callsite — e.g. for a future
/// "ALPHA" or "PREVIEW" callsite — but prefer adding a sibling
/// strings constant so the chrome stays translatable.
class BetaBadge extends StatelessWidget {
  const BetaBadge({
    super.key,
    this.label = S.councilBetaBadgeLabel,
    this.tooltip = S.councilBetaBadgeTooltip,
    this.color = DuckColors.accentDuck,
    this.height = 16.0,
  });

  /// Pill text. Should already be uppercase — the badge does NOT
  /// re-uppercase at render time so callers retain control.
  final String label;

  /// Hover tooltip text. Empty disables the tooltip entirely (use the
  /// raw badge with no tooltip wrap).
  final String tooltip;

  /// Accent colour for fill / border / text. Defaults to
  /// `DuckColors.accentDuck` (warm gold) which reads as "under
  /// construction" without competing with the cyan active-chrome
  /// accent the IDE uses elsewhere.
  final Color color;

  /// Pill height. Default 16 px keeps the badge from disturbing the
  /// host row's cross-axis baseline at a 13–16 px title font.
  final double height;

  @override
  Widget build(BuildContext context) {
    final pill = Container(
      height: height,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: color.withValues(alpha: 0.55),
          width: 0.7,
        ),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.clip,
        style: TextStyle(
          color: color,
          fontSize: 9.5,
          fontWeight: FontWeight.w800,
          letterSpacing: 1.1,
          height: 1.0,
        ),
      ),
    );
    if (tooltip.isEmpty) return pill;
    return Tooltip(message: tooltip, child: pill);
  }
}

/// Standing "under construction" advisory strip. Used at the top of
/// feature wizards / surfaces that are still being built so the user
/// understands the rough-edge contract before they commit time.
///
/// Visual: thin row with a construction icon, a bold title, and a
/// muted body paragraph. Same `accentDuck` accent as [BetaBadge] so
/// the two read as a pair. Does NOT auto-dismiss — a permanent
/// reminder while the feature is in beta. The caller can wrap in
/// [Visibility]/[Offstage] if a per-session dismiss is needed; we
/// deliberately don't bake one in (every dismiss button on a beta
/// surface ends up being clicked once and then the warning vanishes
/// forever).
class UnderConstructionStrip extends StatelessWidget {
  const UnderConstructionStrip({
    super.key,
    this.title = S.councilUnderConstructionTitle,
    this.body = S.councilUnderConstructionBody,
    this.color = DuckColors.accentDuck,
    this.padding = const EdgeInsets.fromLTRB(14, 8, 14, 8),
  });

  final String title;
  final String body;
  final Color color;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border(
          bottom: BorderSide(
            color: color.withValues(alpha: 0.32),
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              Icons.construction_outlined,
              size: 14,
              color: color,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 11,
                  height: 1.35,
                ),
                children: [
                  TextSpan(
                    text: '$title — ',
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.2,
                    ),
                  ),
                  TextSpan(text: body),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
