import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../ollama_setup_dialog.dart';

/// Inline banner that surfaces ABOVE the chat composer when the
/// currently selected chat model is a LOCAL Ollama model
/// (`ollama:*`, not `ollama-cloud:*`) and the Ollama daemon is not
/// responding to `/api/tags`.
///
/// The point of this widget is **discoverability**: the underlying
/// failure mode — sending a message and getting an
/// "Error connecting to Ollama" turn back — is functional but tells
/// users nothing about what to DO. This strip gives them three
/// affordances:
///
///   1. **Start Ollama** — opens the same setup dialog the welcome
///      screen / Help → Setup uses; gives copy-paste-able commands
///      plus the download link.
///   2. **Switch model** — surfaced as a hint, not a button, because
///      the model picker lives right next to the strip; pointing at
///      it is cheaper than duplicating the picker here.
///   3. **Hide** — sticky dismiss for the current session. The strip
///      comes back on the next reachability flap or next app launch.
///
/// **Polling cadence.** When the strip wants to display, we probe
/// reachability every 12 seconds — Ollama is local, so re-checking
/// is cheap, and quick recovery (user starts the daemon, banner
/// disappears within 12s) is the right UX. When the strip is not
/// shown (cloud model, non-Ollama provider, daemon already
/// reachable), the ticker is disabled — zero ongoing cost.
class OllamaReachabilityStrip extends StatefulWidget {
  const OllamaReachabilityStrip({super.key});

  @override
  State<OllamaReachabilityStrip> createState() =>
      _OllamaReachabilityStripState();
}

class _OllamaReachabilityStripState extends State<OllamaReachabilityStrip> {
  static const Duration _pollInterval = Duration(seconds: 12);

  bool _reachable = true;
  bool _hiddenThisSession = false;
  bool _probing = false;
  Timer? _ticker;
  String _lastModel = '';

  @override
  void initState() {
    super.initState();
    // Kick a first probe on the next frame — we read the chat
    // controller in didChangeDependencies, so we can't touch state
    // synchronously here.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeProbe());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = context.read<AppState>();
    final model = state.chat.selectedModel;
    if (model != _lastModel) {
      _lastModel = model;
      // Reset session-hide when the user picks a different model —
      // the dismiss applies to the current "I picked Ollama but it
      // isn't running" decision, not a forever-hide.
      _hiddenThisSession = false;
      _maybeProbe();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  bool _isLocalOllama(String model) {
    // Strict prefix match. `ollama-cloud:` is a separate provider
    // namespace (Ollama Cloud direct via API key) — those requests
    // skip the local daemon entirely, so a missing local daemon
    // shouldn't surface a banner for them.
    return model.startsWith('ollama:');
  }

  Future<void> _maybeProbe() async {
    if (!mounted) return;
    final state = context.read<AppState>();
    final model = state.chat.selectedModel;
    if (!_isLocalOllama(model)) {
      _ticker?.cancel();
      _ticker = null;
      if (mounted && !_reachable) {
        setState(() => _reachable = true);
      }
      return;
    }
    if (_probing) return;
    _probing = true;
    try {
      final ok = await state.ollamaService.isReachable();
      if (!mounted) return;
      if (ok != _reachable) {
        setState(() => _reachable = ok);
      } else {
        // No-op state change — still bump so the visual ticker
        // sub-states (e.g. last-checked) update. Cheap.
      }
      _ensureTicker();
    } finally {
      _probing = false;
    }
  }

  void _ensureTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_pollInterval, (_) => _maybeProbe());
  }

  void _hideForSession() {
    setState(() => _hiddenThisSession = true);
    _ticker?.cancel();
    _ticker = null;
  }

  Future<void> _openSetup() async {
    await showOllamaSetupDialog(context);
    if (!mounted) return;
    // Re-probe immediately after the dialog closes — user likely
    // just started the daemon. No need to wait the full 12s.
    _maybeProbe();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final model = state.chat.selectedModel;
    if (!_isLocalOllama(model)) return const SizedBox.shrink();
    if (_hiddenThisSession) return const SizedBox.shrink();
    if (_reachable) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.fromLTRB(0, 0, 0, 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: DuckColors.stateWarn.withValues(alpha: 0.10),
        border: Border.all(
          color: DuckColors.stateWarn.withValues(alpha: 0.45),
          width: 0.6,
        ),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Icon(
            Icons.cloud_off_outlined,
            size: 14,
            color: DuckColors.stateWarn,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  S.ollamaReachableBannerTitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  S.ollamaReachableBannerBodyFmt(_stripPrefix(model)),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.fgMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          TextButton(
            onPressed: _openSetup,
            style: TextButton.styleFrom(
              foregroundColor: DuckColors.accentCyan,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              textStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: const Text(S.ollamaReachableBannerOpenSetup),
          ),
          IconButton(
            tooltip: S.ollamaReachableBannerDismiss,
            iconSize: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
            icon: const Icon(Icons.close, color: DuckColors.fgSubtle),
            onPressed: _hideForSession,
          ),
        ],
      ),
    );
  }

  String _stripPrefix(String fullModel) {
    final i = fullModel.indexOf(':');
    if (i < 0) return fullModel;
    return fullModel.substring(i + 1);
  }
}
