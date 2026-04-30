import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Above-input strip that surfaces after a turn ended cleanly without
/// any visible content, tool calls, or error — i.e. the Ollama "stream
/// closed but model produced nothing" failure mode.
///
/// Behaviour intentionally mirrors `StallWarningStrip` but the trigger
/// is post-completion rather than mid-stream:
///  - `StallWarningStrip` fires when chunks have *stopped arriving*
///    while [ChatController.isGenerating] is true.
///  - This widget fires when [ChatController.lastTurnLooksEmpty] is
///    true while [ChatController.isGenerating] is false. The strip
///    hides itself the moment the user starts a new turn or
///    dismisses it.
///
/// We deliberately do NOT auto-retry. Silent infinite continues hide
/// genuine "the model is broken on this prompt" signal — the user
/// should see the empty result, decide whether to nudge or rephrase,
/// and click. Two-button design (Continue / Dismiss) so the user
/// stays in control on every empty turn.
class EmptyResponseStrip extends StatelessWidget {
  final ChatController controller;

  const EmptyResponseStrip({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        if (controller.isGenerating || !controller.lastTurnLooksEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          decoration: const BoxDecoration(
            color: DuckColors.bgDeeper,
            border: Border(
              top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              left: BorderSide(color: DuckColors.accentCyan, width: 2),
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.auto_awesome_outlined,
                size: 14,
                color: DuckColors.accentCyan,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      S.chatEmptyResponseTitle,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const Text(
                      S.chatEmptyResponseBody,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: DuckColors.fgMuted,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              _ActionButton(
                label: S.chatEmptyResponseDismiss,
                onPressed: controller.dismissEmptyResponseHint,
                emphasised: false,
              ),
              const SizedBox(width: 6),
              _ActionButton(
                label: S.chatEmptyResponseContinue,
                // No need to thread workspace context — the controller
                // captured it at the moment the empty turn ended.
                onPressed: controller.continueLastTurn,
                emphasised: true,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final String label;
  final VoidCallback onPressed;
  final bool emphasised;

  const _ActionButton({
    required this.label,
    required this.onPressed,
    required this.emphasised,
  });

  @override
  Widget build(BuildContext context) {
    final bg = emphasised
        ? DuckColors.accentCyan.withValues(alpha: 0.16)
        : DuckColors.bgChip;
    final fg =
        emphasised ? DuckColors.accentCyan : DuckColors.fgMuted;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: emphasised
                  ? DuckColors.accentCyan.withValues(alpha: 0.4)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: fg,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}
