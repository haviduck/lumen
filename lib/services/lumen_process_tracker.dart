import 'dart:io';

import 'package:flutter/foundation.dart';

import 'process_manager_service.dart';

/// Tracks PIDs that Lumen explicitly spawned (PTY shells, agent
/// tool processes, anything we own a `Process` handle on) so the
/// process manager UI can offer a "Lumen-spawned" filter that's
/// actually accurate instead of guessing by name.
///
/// Two-layer model:
///
/// 1. **Direct PIDs** — registered with `register(pid)` by the
///    component that started the process. These are guaranteed
///    ours.
/// 2. **Descendants** — derived on demand from a current process
///    snapshot by walking `ppid` back up to any direct PID. These
///    are *probably* ours but can be racy if a tool re-parents
///    itself with `detached: true`.
///
/// The class is a `ChangeNotifier` so the manager UI rebuilds the
/// "Lumen-spawned" chip count when a new terminal is opened or
/// killed.
class LumenProcessTracker extends ChangeNotifier {
  final Set<int> _direct = <int>{};

  /// PIDs the IDE explicitly spawned (terminals, agent tools, etc).
  Set<int> get direct => Set.unmodifiable(_direct);

  /// Register a freshly spawned PID. Safe to call with a stale or
  /// already-exited PID — the tracker just keeps the entry until
  /// something explicitly removes it.
  void register(int? pid) {
    if (pid == null || pid <= 0) return;
    if (_direct.add(pid)) notifyListeners();
  }

  /// Drop a PID we no longer care about (typically because the
  /// owning Pty/Process exited).
  void unregister(int? pid) {
    if (pid == null) return;
    if (_direct.remove(pid)) notifyListeners();
  }

  /// Defence-in-depth sweep: hard-kill every PID we currently track.
  /// Called from `AppState.shutdownAllTerminals` on the app-close path
  /// after the bridge + pane have already had their graceful Ctrl+C
  /// pass — anything still tracked at this point is either a session
  /// that escaped both the agent bridge and the visible pane, or a
  /// grandchild whose parent shell didn't propagate SIGINT down. We
  /// favour an aggressive cleanup over leaving renegade `node`/`python`
  /// processes squatting on ports / file handles after Lumen closes.
  ///
  /// Best-effort: `Process.killPid` returning `false` (already dead
  /// PID, permission denied, etc.) is silent. Always clears the
  /// tracker set so a subsequent boot doesn't carry stale PIDs.
  void killAllTracked() {
    if (_direct.isEmpty) return;
    final snapshot = _direct.toList(growable: false);
    for (final pid in snapshot) {
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {}
    }
    _direct.clear();
    notifyListeners();
  }

  /// Expand the direct set into the *transitive* set of "everything
  /// that descends from anything we spawned" given a fresh process
  /// listing. Walks the `ppid` graph upward — O(N) per process. The
  /// snapshot itself is what the caller already paid for to render
  /// the table, so this is essentially free on top of it.
  Set<int> expand(List<ProcessInfo> snapshot) {
    if (_direct.isEmpty) return const <int>{};
    // Index by pid so we can hop up to parents in O(1).
    final byPid = <int, ProcessInfo>{
      for (final p in snapshot) p.pid: p,
    };
    final result = <int>{..._direct};
    for (final p in snapshot) {
      // Ascend until we either hit a direct PID (=> include this
      // process), hit pid 0/4 (system root on Windows; init on
      // Unix), or break a cycle. The visited guard isn't strictly
      // necessary on a sane OS but `Win32_Process` has been known
      // to report cyclic ppid chains during fast process churn.
      var cursor = p;
      final visited = <int>{};
      while (true) {
        if (_direct.contains(cursor.pid)) {
          result.add(p.pid);
          break;
        }
        final parent = cursor.ppid;
        if (parent == null || parent == 0 || !visited.add(parent)) break;
        final next = byPid[parent];
        if (next == null) break;
        cursor = next;
      }
    }
    return result;
  }
}
