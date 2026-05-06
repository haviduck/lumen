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
/// renders the timer + Stop chip when silence crosses [warnAfter].
///
/// The warning is *advisory* — it doesn't auto-stop generation. The
/// 3-minute hard idle timeout in the streaming services takes care
/// of genuinely dead connections. This is the early heads-up so the
/// user can decide to Stop and retry rather than wait the full 3
/// minutes.
///
/// Visual treatment is intentionally muted (no panel band, no left
/// stripe, mono-ish small text) so it reads as a footer of the
/// streaming bubble above it — same calm-pass spirit as the
/// queued-prompts strip and approval card reshapes.
class StallWarningStrip extends StatefulWidget {
  final ChatController controller;

  /// How long the stream must be silent before the warning shows.
  /// Tuned to ~30s — short enough to be useful before the 3min idle
  /// timeout fires, long enough that legitimately-slow inter-token
  /// gaps on heavy local models don't trigger spurious warnings.
  final Duration warnAfter;

  const StallWarningStrip({
    super.key,
    required this.controller,
    this.warnAfter = const Duration(seconds: 30),
  });

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
    if (silence == null || silence < widget.warnAfter) {
      return const SizedBox.shrink();
    }
    final seconds = silence.inSeconds;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 14),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.hourglass_top_outlined,
            size: 12,
            color: DuckColors.stateWarn,
          ),
          const SizedBox(width: 6),
          Text(
            S.chatStallSilence(seconds),
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
            ),
          ),
          const SizedBox(width: 12),
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: InkWell(
              onTap: widget.controller.cancelGeneration,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: DuckColors.stateError.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  border: Border.all(
                    color: DuckColors.stateError.withValues(alpha: 0.3),
                    width: 0.5,
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.stop,
                      size: 10,
                      color: DuckColors.stateError,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      S.chatStallStop,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.stateError,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
