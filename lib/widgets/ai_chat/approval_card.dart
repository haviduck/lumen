import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Pending-approval surface docked above the chat input, modelled
/// after Cursor / VS Code's terminal-permission prompts:
///
/// ```
/// ┌──────────────────────────────────────────────────────────┐
/// │ ● Run command  npm install …          ⌃▽ Deny  Always  ✓ │
/// └──────────────────────────────────────────────────────────┘
/// ```
///
/// Single row by default — short commands fit comfortably without
/// stealing height from the conversation. Multi-line / long
/// commands are reachable via the chevron, which expands a mono-
/// font detail block. Layout is intentionally chrome-grade
/// (toolbar-tier hierarchy, not card-tier): warning-yellow left
/// rail, condensed text size, no rounded card outline. Earlier
/// versions used a heavyweight `bgRaisedHi` rounded card that
/// felt like a popup interrupting the chat.
///
/// Naming kept as `approval_card.dart` for git-history continuity
/// even though the export is now `ApprovalStrip` — old name was
/// already exported from `ai_chat/` so renaming the file would
/// churn imports across unrelated files.
class ApprovalStrip extends StatefulWidget {
  final ChatController controller;
  final PendingApproval approval;

  const ApprovalStrip({
    super.key,
    required this.controller,
    required this.approval,
  });

  @override
  State<ApprovalStrip> createState() => _ApprovalStripState();
}

class _ApprovalStripState extends State<ApprovalStrip> {
  bool _expanded = false;

  bool get _multiline => widget.approval.detail.contains('\n');
  String get _firstLine => widget.approval.detail.split('\n').first;

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    final controller = widget.controller;
    return Container(
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
          // Yellow-rail left edge — same affordance the silent-
          // approval audit banner uses, so "I need to make a
          // decision" surfaces have a consistent visual language.
          left: BorderSide(color: DuckColors.stateWarn, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.shield_outlined,
                    size: 13, color: DuckColors.stateWarn),
                const SizedBox(width: 8),
                // Tool label (e.g. RUN_CMD) — small uppercase,
                // doesn't compete with the command text for
                // attention.
                Text(
                  approval.label,
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: DuckColors.stateWarn,
                  ),
                ),
                const SizedBox(width: 10),
                // Inline command preview, mono font, ellipsis.
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _multiline
                        ? () => setState(() => _expanded = !_expanded)
                        : null,
                    child: Text(
                      _firstLine,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 12,
                        color: DuckColors.fgPrimary,
                        height: 1.3,
                      ),
                    ),
                  ),
                ),
                if (_multiline) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => setState(() => _expanded = !_expanded),
                    borderRadius:
                        BorderRadius.circular(DuckTheme.radiusS),
                    child: Padding(
                      padding: const EdgeInsets.all(3),
                      child: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 14,
                        color: DuckColors.fgSubtle,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 8),
                _StripButton(
                  label: S.toolApprovalDeny,
                  onTap: () => controller.respondToApproval(false),
                  tone: _StripButtonTone.danger,
                ),
                const SizedBox(width: 4),
                _StripButton(
                  label: approval.toolId == 'run_cmd'
                      ? S.toolApprovalAlwaysRun
                      : S.toolApprovalAllowAlways,
                  onTap: () async {
                    await controller.setToolAutoApproved(
                      approval.toolId,
                      true,
                    );
                    controller.respondToApproval(true);
                  },
                  tone: _StripButtonTone.muted,
                ),
                const SizedBox(width: 4),
                _StripButton(
                  label: S.toolApprovalAllowOnce,
                  onTap: () => controller.respondToApproval(true),
                  tone: _StripButtonTone.primary,
                ),
              ],
            ),
          ),
          // Expanded multi-line preview — same mono styling but
          // stripped of clutter (no inset card / no border) so it
          // reads as continuous chrome rather than a nested popup.
          if (_expanded && _multiline) ...[
            const Divider(
              height: 1,
              thickness: 0.5,
              color: DuckColors.glassSeam,
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 8, 12, 10),
              constraints: const BoxConstraints(maxHeight: 220),
              child: SingleChildScrollView(
                child: SelectableText(
                  approval.detail,
                  style: const TextStyle(
                    fontFamily: DuckTheme.monoFont,
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

enum _StripButtonTone { danger, muted, primary }

/// Compact pill-style button used inside the approval strip.
/// Consciously NOT a Material `TextButton` / `ElevatedButton` because
/// those bake in vertical padding that bloats the strip's height.
/// We need ~24px tall to keep the strip toolbar-feeling.
class _StripButton extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  final _StripButtonTone tone;
  const _StripButton({
    required this.label,
    required this.onTap,
    required this.tone,
  });

  @override
  State<_StripButton> createState() => _StripButtonState();
}

class _StripButtonState extends State<_StripButton> {
  bool _hover = false;

  ({Color fg, Color bg, Color hoverBg}) get _palette {
    switch (widget.tone) {
      case _StripButtonTone.danger:
        return (
          fg: DuckColors.stateError,
          bg: Colors.transparent,
          hoverBg: DuckColors.stateError.withValues(alpha: 0.10),
        );
      case _StripButtonTone.muted:
        return (
          fg: DuckColors.fgMuted,
          bg: Colors.transparent,
          hoverBg: DuckColors.bgRaisedHi,
        );
      case _StripButtonTone.primary:
        return (
          fg: DuckColors.bgDeepest,
          bg: DuckColors.accentCyan,
          hoverBg: DuckColors.accentCyan,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = _palette;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? p.hoverBg : p.bg,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: widget.tone == _StripButtonTone.primary
                  ? FontWeight.w600
                  : FontWeight.w500,
              color: p.fg,
            ),
          ),
        ),
      ),
    );
  }
}
