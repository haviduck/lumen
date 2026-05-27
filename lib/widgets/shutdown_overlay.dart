import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';

/// Centred "Shutting down…" card shown while [AppCloseGuard] tears
/// down terminals / Copilot bridge / flushes the usage log.
///
/// Lives in its own file because the guard is otherwise pure
/// control-flow and pulling visual styling into it would make both
/// harder to read. The card itself is dumb — it just renders the
/// label fed via [step]. The guard updates the label as each
/// cleanup phase starts so the user can see what's actually
/// happening instead of staring at a frozen window for the duration
/// of the (sometimes multi-second) Copilot dispose.
///
/// Lifetime: inserted into the root navigator's overlay just before
/// the cleanup loop starts and never explicitly removed —
/// `windowManager.destroy()` tears down the whole isolate
/// immediately after the cleanup finishes, so the overlay dies
/// with the rest of the UI. A short-lived close (no terminals, no
/// bridge, instant log flush) skips this overlay entirely; see
/// `AppCloseGuard._closeForReal` for the gating logic.
class ShutdownOverlay extends StatelessWidget {
  /// Current cleanup phase label — e.g. "Closing terminals…",
  /// "Stopping Copilot bridge…", "Saving token usage log…". When
  /// null, the overlay falls back to the generic "Shutting down…"
  /// title-only state.
  final String? step;

  const ShutdownOverlay({super.key, required this.step});

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        // Slightly darker than `bgGlass` so the card pops against
        // whatever screen was active behind it. Not full black —
        // the user should still recognise their workspace through
        // it for the final visual fade-out.
        color: Colors.black.withValues(alpha: 0.55),
        alignment: Alignment.center,
        child: Container(
          width: 280,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
          decoration: BoxDecoration(
            color: DuckColors.bgDeeper,
            borderRadius: BorderRadius.circular(DuckTheme.radiusL),
            border: Border.all(color: DuckColors.border, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DuckColors.accentCyan,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    S.shutdownTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.fgPrimary,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              AnimatedSwitcher(
                duration: DuckMotion.fast,
                child: Text(
                  step ?? S.shutdownGenericStep,
                  key: ValueKey<String?>(step),
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.fgMuted,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
