import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Quiet footer rendered directly below the streaming assistant
/// bubble that surfaces "the model is silent" once the streaming
/// chunks have stopped landing for a while.
///
/// Uses **inter-chunk silence** as the stall metric, NOT total
/// elapsed time. A reasoning model can legitimately think for
/// minutes; what matters is whether tokens are still arriving. The
/// chat controller updates `_lastChunkAt` on every chunk; this
/// widget polls `controller.silenceDuration` once per second and
/// renders an escalating, intentionally muted hint.
///
/// **Three escalating stages.** Below 60s of silence the strip is
/// hidden entirely — the streaming progress bar is enough. After
/// that the copy escalates without changing layout:
///
///   - >=60s  → "This is taking longer than usual" (no icon, no Stop)
///   - >=90s  → "Still thinking"                   (no icon, no Stop)
///   - >=120s → "This chat may be frozen…" + a subtle underlined
///              `Stop` link that calls [ChatController.cancelGeneration]
///
/// The Stop control is intentionally a low-key text link, not a
/// red bordered chip — the earlier 30s timer + red chip felt
/// alarmist on legitimately slow local models and trained users to
/// tune it out. The replacement reads as a footer of the streaming
/// bubble above it, in the same calm-pass spirit as the
/// queued-prompts strip and approval card reshapes.
///
/// The hint is *advisory* — it doesn't auto-stop generation. The
/// 3-minute hard idle timeout in the streaming services takes care
/// of genuinely dead connections. This is the early heads-up so
/// the user can decide to Stop and retry rather than wait the
/// full 3 minutes.
class StallWarningStrip extends StatefulWidget {
  final ChatController controller;

  const StallWarningStrip({
    super.key,
    required this.controller,
  });

  // Stage thresholds — tuned together with the strings in
  // [S.chatStallTakingLonger] / [S.chatStallStillThinking] /
  // [S.chatStallFrozen]. Below `_stage1` the strip is hidden.
  static const Duration _stage1 = Duration(seconds: 60);
  static const Duration _stage2 = Duration(seconds: 90);
  static const Duration _stage3 = Duration(seconds: 120);

  @override
  State<StallWarningStrip> createState() => _StallWarningStripState();
}

class _StallWarningStripState extends State<StallWarningStrip> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChange);
    _onControllerChange();
  }

  @override
  void didUpdateWidget(covariant StallWarningStrip old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_onControllerChange);
      widget.controller.addListener(_onControllerChange);
      _onControllerChange();
    }
  }

  void _onControllerChange() {
    if (widget.controller.isGenerating) {
      _ensureTicker();
    } else {
      _stopTicker();
      if (mounted) setState(() {});
    }
  }

  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  @override
  void dispose() {
    _stopTicker();
    widget.controller.removeListener(_onControllerChange);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final silence = widget.controller.silenceDuration;
    if (silence == null || silence < StallWarningStrip._stage1) {
      return const SizedBox.shrink();
    }

    // Stage selection. Frozen wins over still-thinking wins over
    // taking-longer; only the frozen stage shows the Stop affordance.
    final String text;
    final bool showStop;
    if (silence >= StallWarningStrip._stage3) {
      text = S.chatStallFrozen;
      showStop = true;
    } else if (silence >= StallWarningStrip._stage2) {
      text = S.chatStallStillThinking;
      showStop = false;
    } else {
      text = S.chatStallTakingLonger;
      showStop = false;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            text,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
              fontStyle: FontStyle.italic,
            ),
          ),
          if (showStop) ...[
            const SizedBox(width: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: InkWell(
                onTap: widget.controller.cancelGeneration,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                  child: Text(
                    S.chatStallStop,
                    style: const TextStyle(
                      fontSize: 11,
                      color: DuckColors.fgMuted,
                      decoration: TextDecoration.underline,
                      decorationColor: DuckColors.fgMuted,
                    ),
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
