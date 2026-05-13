import 'dart:async';

import 'package:flutter/foundation.dart';

import 'preferences_service.dart';

/// Tracks how long the user has been *actively* working in Lumen across
/// the current local day, and decides when the "are you alright?"
/// well-being panel should slide down.
///
/// "Active" is the hybrid of two signals:
///  - the window is focused (we ignore time spent in other apps), AND
///  - any input event landed within [_idleThreshold] of the current
///    tick (we ignore stretches where the IDE is open but untouched —
///    dinner breaks, AFK afternoons, etc).
///
/// Both conditions are checked once per [_tickInterval]; each tick
/// that satisfies both adds `_tickInterval.inSeconds` to today's
/// counter. The counter is persisted via [PreferencesService] keyed
/// by local-date `YYYY-MM-DD`, with stale day rows pruned on init
/// and on midnight rollover.
///
/// The panel surfaces when ALL of these are true:
///  - today's active time ≥ [_wellbeingThreshold] (default 9 h);
///  - the local clock is inside the "late" band
///    ([_lateStartHour]..24 or 00..[_lateEndHour], inclusive); and
///  - the panel hasn't already been shown today.
///
/// Once the user dismisses the panel (or auto-dismiss fires),
/// `wellbeingLastShownDay` is written so we stay quiet until
/// tomorrow. This is intentional — a kind nudge once per day is a
/// kind nudge; the same panel three times a night is nagging.
class WorkSessionTracker extends ChangeNotifier {
  /// How often we re-check focus + idle and persist accumulated time.
  /// 30 s is a balance: tight enough that a 9h-threshold is accurate
  /// to within half a minute, loose enough not to hammer the disk.
  static const Duration _tickInterval = Duration(seconds: 30);

  /// After this much input silence, we stop counting. 5 min keeps
  /// "thinking while staring at the screen" inside the window
  /// (occasional mouse moves are enough) while excluding "left for
  /// lunch" patterns.
  static const Duration _idleThreshold = Duration(minutes: 5);

  /// Active-time bar for surfacing the panel. 9 h matches the user's
  /// brief; if you tune this later, also tune the [_lateStartHour]
  /// floor — a 9h day that started at 06:00 ends at 15:00 and isn't
  /// "late" by anyone's definition.
  static const Duration _wellbeingThreshold = Duration(hours: 9);

  /// Inclusive start of the late band (local hour, 24h). 22:00.
  static const int _lateStartHour = 22;

  /// Exclusive end of the late band. We consider 22:00..04:59 late;
  /// at 05:00 we stop, the morning belongs to the user.
  static const int _lateEndHour = 5;

  final PreferencesService _prefs;

  Timer? _timer;
  DateTime _lastInteraction = DateTime.now();
  bool _windowFocused = true;
  String _today = _dayKey(DateTime.now());
  int _todaySeconds = 0;
  bool _shownToday = false;
  bool _shouldShowPanel = false;
  bool _initialized = false;

  WorkSessionTracker(this._prefs);

  /// Today's accumulated active time. Updated on every tick that
  /// counts; readers should `context.watch` (the tracker is a
  /// [ChangeNotifier]) to refresh on rollover.
  Duration get todayActive => Duration(seconds: _todaySeconds);

  /// `true` while the panel should be on screen. Goes back to
  /// `false` the instant [dismissPanel] is called.
  bool get shouldShowPanel => _shouldShowPanel;

  /// Hydrate from preferences and start ticking. Idempotent — extra
  /// calls are no-ops, so this is safe to invoke from the provider
  /// `create:` callback.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    final today = _dayKey(DateTime.now());
    _today = today;
    _todaySeconds = await _prefs.getDailyActiveSeconds(today);
    final lastShown = await _prefs.getWellbeingLastShownDay();
    _shownToday = lastShown == today;
    // Keep today + yesterday on disk for the "did I just cross
    // midnight mid-session?" edge case; everything older is gone.
    final yesterday = _dayKey(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    await _prefs.pruneDailyActiveDays({today, yesterday});
    _timer = Timer.periodic(_tickInterval, (_) => _tick());
    notifyListeners();
  }

  /// Bumped on every observed input event. Cheap — just stamps a
  /// `DateTime.now()` field, no setState / no notify. The tick loop
  /// reads it later.
  void recordInteraction() {
    _lastInteraction = DateTime.now();
  }

  /// Tells the tracker whether the OS window currently has focus.
  /// Flipping back to focused also resets the idle clock — focusing
  /// the window is itself an interaction.
  void setWindowFocused(bool focused) {
    _windowFocused = focused;
    if (focused) _lastInteraction = DateTime.now();
  }

  /// Hides the panel for the rest of today. Writes
  /// `wellbeingLastShownDay = today` so a restart later this evening
  /// won't re-surface it.
  void dismissPanel() {
    if (!_shouldShowPanel) return;
    _shouldShowPanel = false;
    _shownToday = true;
    // Best-effort persistence; failure here only costs us a re-show
    // if the user restarts during the same late-night session.
    _prefs.setWellbeingLastShownDay(_today);
    notifyListeners();
  }

  Future<void> _tick() async {
    final now = DateTime.now();
    final today = _dayKey(now);

    // Local-midnight rollover. Reset the counter, re-evaluate the
    // "already shown today?" guard against the fresh date, and prune
    // disk.
    if (today != _today) {
      _today = today;
      _todaySeconds = 0;
      _shouldShowPanel = false;
      _shownToday = (await _prefs.getWellbeingLastShownDay()) == today;
      final yesterday = _dayKey(now.subtract(const Duration(days: 1)));
      await _prefs.pruneDailyActiveDays({today, yesterday});
      notifyListeners();
    }

    final idle = now.difference(_lastInteraction);
    final counts = _windowFocused && idle < _idleThreshold;
    if (counts) {
      _todaySeconds += _tickInterval.inSeconds;
      await _prefs.setDailyActiveSeconds(_today, _todaySeconds);
      // Don't notify on every tick — the displayed `todayActive`
      // only really matters when the panel surfaces, and a notify-
      // per-30s would invalidate every widget context.watch on the
      // tracker. We notify on threshold crossings and rollover only.
    }

    if (!_shownToday && !_shouldShowPanel) {
      final hour = now.hour;
      final isLate = hour >= _lateStartHour || hour < _lateEndHour;
      if (isLate && _todaySeconds >= _wellbeingThreshold.inSeconds) {
        _shouldShowPanel = true;
        notifyListeners();
      }
    }
  }

  static String _dayKey(DateTime dt) {
    final l = dt.toLocal();
    final y = l.year.toString().padLeft(4, '0');
    final m = l.month.toString().padLeft(2, '0');
    final d = l.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
