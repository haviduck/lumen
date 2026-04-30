import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Small, discrete pending-approval panel docked above the chat input.
///
/// ```
/// ┌──────────────────────────────────────────────────┐
/// │ ● run_cmd  npm install …          accept · deny  │
/// └──────────────────────────────────────────────────┘
/// ```
///
/// Design rules:
///  - Dark background (deepest tier) so it reads as chrome, not a
///    card / popup. No chunky left rail, no colored fill on the
///    actions — earlier versions used pill buttons that competed
///    with the cyan send button for visual weight.
///  - Actions are plain clickable text links: `accept` (cyan) and
///    `deny` (red). Hover underlines them. No backgrounds.
///  - Single row by default; multi-line commands are reachable via
///    the chevron (expands a mono-font detail block).
///
/// "Always allow" was intentionally dropped from the strip to keep
/// it minimal. Blanket-allow for a tool is still reachable via
/// Settings → AI/Chat → Always-allowed tools.
///
/// Naming kept as `approval_card.dart` for git-history continuity
/// even though the export is `ApprovalStrip`.
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
        color: DuckColors.bgDeepest,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  size: 12,
                  color: DuckColors.stateWarn,
                ),
                const SizedBox(width: 8),
                // Tool label (e.g. RUN_CMD) — small uppercase, doesn't
                // compete with the command text for attention.
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
                      padding: const EdgeInsets.all(2),
                      child: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 13,
                        color: DuckColors.fgSubtle,
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 12),
                _LinkAction(
                  label: S.toolApprovalAccept.toLowerCase(),
                  color: DuckColors.accentCyan,
                  onTap: () => controller.respondToApproval(true),
                ),
                const _LinkSeparator(),
                _LinkAction(
                  label: S.toolApprovalDeny.toLowerCase(),
                  color: DuckColors.stateError,
                  onTap: () => controller.respondToApproval(false),
                ),
              ],
            ),
          ),
          // Expanded multi-line preview — mono styling, no inset card
          // / no border, reads as continuous chrome rather than a
          // nested popup.
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

/// Plain text link with a hover underline. No padding chrome, no
/// background — the strip reads as chrome, not as a button bar.
class _LinkAction extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _LinkAction({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  State<_LinkAction> createState() => _LinkActionState();
}

class _LinkActionState extends State<_LinkAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Text(
          widget.label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: widget.color,
            height: 1.2,
            decoration:
                _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: widget.color,
            decorationThickness: 1.2,
          ),
        ),
      ),
    );
  }
}

class _LinkSeparator extends StatelessWidget {
  const _LinkSeparator();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 8),
      child: Text(
        '·',
        style: TextStyle(
          fontSize: 12,
          color: DuckColors.fgSubtle,
          height: 1.2,
        ),
      ),
    );
  }
}
