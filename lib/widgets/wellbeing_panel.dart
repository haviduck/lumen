import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/work_session_tracker.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';

/// Subtle, kind notification that slides down from the top of the IDE
/// when the user has crossed the late-night active-work threshold (see
/// [WorkSessionTracker]). One-shot per day — closing it (via the X,
/// auto-dismiss, or the click-anywhere catcher) tells the tracker to
/// stay quiet until tomorrow's local rollover.
///
/// The panel is intentionally light on interaction surface: no
/// buttons, no actions, no "snooze for 1 hour" UX. The whole point is
/// to land softly, say its piece, and disappear. The user is tired —
/// don't give them a decision tree.
///
/// Mounted as a `Positioned` child at the top of the IDE shell Stack
/// in `main.dart::_IdeShell`. Lives above all chrome (menu bar,
/// editor, terminal, chat) because slide-from-the-top means it
/// physically enters from above the menu bar.
class WellbeingPanel extends StatefulWidget {
  const WellbeingPanel({super.key});

  @override
  State<WellbeingPanel> createState() => _WellbeingPanelState();
}

class _WellbeingPanelState extends State<WellbeingPanel>
    with SingleTickerProviderStateMixin {
  // How long the panel stays on screen once fully slid in. Tuned to
  // ~22s so a tired user can actually read it without rushing — the
  // three lines + tagline are slow-read territory, not glance-and-go
  // toast copy. Shorter than this and the message lands as
  // condescending ("you saw it, right?"); longer and it overstays.
  static const Duration _holdDuration = Duration(seconds: 22);

  // Slide-in and slide-out both ride this controller. Forward = down
  // (entering from above the menu bar), reverse = back up + out.
  late final AnimationController _slide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  Timer? _autoDismiss;
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _syncFromTracker());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncFromTracker();
  }

  /// Reflects the tracker's `shouldShowPanel` flag into our local
  /// `_showing` state, kicking off the slide animation and the
  /// hold timer on the false→true edge. The reverse direction is
  /// driven by `_close()` (user dismiss / auto-dismiss), not by the
  /// tracker — the tracker's flag goes false as a *result* of close,
  /// not the cause.
  void _syncFromTracker() {
    final tracker = context.read<WorkSessionTracker>();
    if (tracker.shouldShowPanel && !_showing) {
      setState(() => _showing = true);
      final reduceMotion = context.read<AppState>().reduceMotion;
      if (reduceMotion) {
        _slide.value = 1.0;
      } else {
        _slide.forward(from: 0);
      }
      _autoDismiss?.cancel();
      _autoDismiss = Timer(_holdDuration, _close);
    }
  }

  Future<void> _close() async {
    if (!_showing) return;
    _autoDismiss?.cancel();
    _autoDismiss = null;
    final reduceMotion = mounted ? context.read<AppState>().reduceMotion : true;
    if (reduceMotion) {
      _slide.value = 0;
    } else {
      await _slide.reverse();
    }
    if (!mounted) return;
    setState(() => _showing = false);
    // Tell the tracker we're done — this flips `shouldShowPanel`
    // false and persists `wellbeingLastShownDay = today` so we don't
    // re-surface on the next 30s tick.
    context.read<WorkSessionTracker>().dismissPanel();
  }

  @override
  void dispose() {
    _autoDismiss?.cancel();
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch the tracker so a freshly-set shouldShowPanel triggers a
    // build that lets `didChangeDependencies` / post-frame callback
    // pick it up. Reading the hours value here too so the body line
    // reflects the actual count when the panel surfaces.
    final tracker = context.watch<WorkSessionTracker>();
    if (tracker.shouldShowPanel && !_showing) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _syncFromTracker();
      });
    }
    if (!_showing) return const SizedBox.shrink();
    final hours = tracker.todayActive.inHours;

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Align(
          alignment: Alignment.topCenter,
          child: AnimatedBuilder(
            animation: _slide,
            builder: (context, child) {
              final t = Curves.easeOutCubic.transform(_slide.value);
              return Transform.translate(
                offset: Offset(0, -130 * (1 - t)),
                child: Opacity(opacity: t, child: child),
              );
            },
            child: Container(
              margin: const EdgeInsets.only(top: 12),
              constraints: const BoxConstraints(maxWidth: 540),
              child: DuckGlass.hero(
                radius: DuckTheme.radiusL,
                borderColor: DuckColors.glassEdgeHi,
                boxShadow: [
                  // Slightly warmer / longer shadow than the default
                  // soft preset — the panel sits free-floating above
                  // the menu bar with no surface to rest on, so it
                  // needs a bit more lift to read as a separate plane.
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.55),
                    blurRadius: 28,
                    spreadRadius: -4,
                    offset: const Offset(0, 14),
                  ),
                  BoxShadow(
                    color: DuckColors.accentDuck.withValues(alpha: 0.08),
                    blurRadius: 22,
                    spreadRadius: -6,
                  ),
                ],
                padding: const EdgeInsets.fromLTRB(18, 14, 10, 16),
                child: _WellbeingContent(
                  hours: hours,
                  onClose: _close,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _WellbeingContent extends StatelessWidget {
  final int hours;
  final VoidCallback onClose;
  const _WellbeingContent({required this.hours, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(top: 1),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: DuckColors.accentDuck.withValues(alpha: 0.14),
            border: Border.all(
              color: DuckColors.accentDuck.withValues(alpha: 0.32),
              width: 0.6,
            ),
          ),
          child: const Icon(
            Icons.nightlight_round,
            size: 15,
            color: DuckColors.accentDuck,
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                S.wellbeingTitle,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.1,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.wellbeingBody1Fmt(hours),
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 12,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.wellbeingBody2,
                style: const TextStyle(
                  color: DuckColors.fgSecondary,
                  fontSize: 12,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                S.wellbeingBody3,
                style: const TextStyle(
                  color: DuckColors.fgSecondary,
                  fontSize: 12,
                  height: 1.5,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                S.wellbeingGoodLuck,
                style: const TextStyle(
                  color: DuckColors.accentMint,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  fontStyle: FontStyle.italic,
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Tooltip(
          message: S.wellbeingClose,
          child: SizedBox(
            width: 26,
            height: 26,
            child: IconButton(
              onPressed: onClose,
              padding: EdgeInsets.zero,
              splashRadius: 14,
              iconSize: 14,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(),
              icon: const Icon(
                Icons.close,
                color: DuckColors.fgMuted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
