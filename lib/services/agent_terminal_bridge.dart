import 'dart:async';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../widgets/terminal/terminal_session.dart';
import 'lumen_process_tracker.dart';

/// Surfaces agent-spawned commands (`RUN_CMD`) as real `TerminalSession`s
/// inside the existing terminal pane.
///
/// **Why this exists.** Before this bridge, `RUN_CMD` shelled out via
/// `Process.start('cmd.exe', ['/c', cmd])` directly, captured stdout,
/// and on soft-timeout / ready-detect simply *abandoned* the process —
/// no PID tracking, no kill handle, no visibility. Long-running dev
/// servers (`npm run dev`, `vite`, `python -m http.server`) leaked as
/// orphans and the user had to `taskkill node` from outside Lumen.
///
/// **What the bridge does.** Exposes a single `start(...)` entry point
/// that spawns an `TerminalSession.agent(...)` (PTY-backed,
/// PID-tracked) and returns an [AgentRunHandle]. The handle:
///   - tees ANSI-stripped chunks to the caller's `onOutput` for the
///     model's view (ready-pattern detection still works);
///   - exposes `exitCode` / `kill()` for the executor's existing race
///     against soft-timeout / cancel / ready-detect;
///   - has `promoteToVisible()` which pushes the underlying session
///     into the bridge's [visibleSessions] list. The terminal pane
///     listens to the bridge and merges any new entries into its tab
///     bar — so the moment a dev server is detected as long-running,
///     it pops up as a real terminal tab the user can see, type into
///     (e.g. press `r` to hot-reload Vite), and close to kill.
///
/// **Lifetime.** Hidden sessions are bridge-owned: if the process
/// exits before promotion, the bridge disposes and never bothers the
/// pane. Promoted sessions are pane-owned: when the user closes the
/// tab, the pane disposes the session and calls
/// [handleSessionRemoved] so the bridge drops its reference.
///
/// **Threading.** Pure Dart, single-threaded; the only async surfaces
/// are `start` (awaits PTY init) and the listeners. Notifications fire
/// on the same isolate that called `promoteToVisible`.
class AgentTerminalBridge extends ChangeNotifier {
  AgentTerminalBridge({required this.processes});

  /// Process tracker so PIDs spawned through the bridge show up in
  /// the Process Manager's "Lumen-spawned" filter — same as
  /// manually-opened terminals.
  final LumenProcessTracker processes;

  final List<TerminalSession> _visible = [];
  final Set<AgentRunHandle> _live = <AgentRunHandle>{};

  /// Sessions promoted to be shown as tabs. The terminal pane mirrors
  /// this list into its own `_sessions`.
  List<TerminalSession> get visibleSessions => List.unmodifiable(_visible);

  /// Spawn an agent command via [TerminalSession.agent]. The session
  /// stays hidden (not in [visibleSessions]) until either:
  ///   - [AgentRunHandle.promoteToVisible] is called (typically by
  ///     `RUN_CMD` on ready-detect / soft-timeout), or
  ///   - the process exits — in which case the bridge silently
  ///     disposes the session without ever showing a tab.
  ///
  /// The caller is responsible for:
  ///   - listening to [AgentRunHandle.exitCode],
  ///   - calling [AgentRunHandle.kill] on user cancel,
  ///   - calling [AgentRunHandle.dispose] when finished if the
  ///     session was *not* promoted.
  Future<AgentRunHandle> start({
    required String command,
    required String workingDirectory,
    String? preferredShellId,
    void Function(String stripped)? onOutput,
    String? title,
  }) async {
    final id = 'agent_term_${DateTime.now().microsecondsSinceEpoch}';
    final session = TerminalSession.agent(
      id: id,
      title: title ?? _deriveTitle(command),
      workingDirectory: workingDirectory,
      command: command,
      onAgentOutput: onOutput,
      onPidStarted: processes.register,
      onPidEnded: processes.unregister,
    );

    final handle = AgentRunHandle._(this, session);
    _live.add(handle);

    // Kick start asynchronously and let any startup error surface
    // through the session's normal failure path (which already
    // resolves the agent exit completer with `null`).
    unawaited(session.start(preferredShellId: preferredShellId));

    // Auto-cleanup: when the process exits naturally and the handle
    // was never promoted, the bridge silently disposes the session
    // (no tab ever appeared). Promoted sessions stay until the pane
    // closes them.
    unawaited(
      session.agentExitCode!.then((_) {
        if (handle._disposed) return;
        if (!handle._promoted) {
          handle.dispose();
        }
      }),
    );

    return handle;
  }

  /// Called by the terminal pane after a user-initiated tab close
  /// for an agent session. The bridge drops its reference and
  /// notifies (so any other listeners can re-sync). The pane is
  /// responsible for actually disposing the session — the bridge
  /// already lost ownership at promotion time.
  void handleSessionRemoved(TerminalSession session) {
    final removed = _visible.remove(session);
    AgentRunHandle? handle;
    for (final h in _live) {
      if (identical(h._session, session)) {
        handle = h;
        break;
      }
    }
    if (handle != null) {
      _live.remove(handle);
    }
    if (removed) notifyListeners();
  }

  void _promote(AgentRunHandle handle) {
    if (handle._promoted) return;
    handle._promoted = true;
    _visible.add(handle._session);
    notifyListeners();
  }

  void _disposeHandle(AgentRunHandle handle) {
    if (handle._disposed) return;
    handle._disposed = true;
    _live.remove(handle);
    if (!handle._promoted) {
      // Hidden session — bridge owns the lifetime, so dispose it
      // properly (kills any straggler process, drops PID tracker
      // entry).
      try {
        handle._session.dispose();
      } catch (_) {}
    }
    // No notifyListeners for hidden sessions — there was never a
    // visible tab to remove.
  }

  /// Build a human-friendly tab title from the command. Caps the
  /// total length so the tab strip doesn't get pushed off-screen by
  /// a one-liner with inline JSON. The full command surfaces as the
  /// tab's tooltip (see `terminal_pane.dart::_TerminalTab.tooltip`).
  String _deriveTitle(String command) {
    var trimmed = command.trim();
    if (trimmed.length > 28) trimmed = '${trimmed.substring(0, 28)}…';
    return '${S.terminalAgentPrefix}$trimmed';
  }

  @override
  void dispose() {
    for (final h in _live.toList()) {
      try {
        h._session.dispose();
      } catch (_) {}
    }
    _live.clear();
    _visible.clear();
    super.dispose();
  }
}

/// Per-invocation handle returned by [AgentTerminalBridge.start].
/// Wraps the underlying [TerminalSession] and exposes the surface
/// `RUN_CMD` cares about (output stream, exit code, kill, promote)
/// without leaking the entire session API to the executor.
class AgentRunHandle {
  AgentRunHandle._(this._bridge, this._session);

  final AgentTerminalBridge _bridge;
  final TerminalSession _session;

  bool _promoted = false;
  bool _disposed = false;

  /// True after [promoteToVisible] has been called. Once promoted,
  /// the underlying session is owned by the terminal pane.
  bool get isPromoted => _promoted;

  /// The PTY-backed terminal session. Exposed for the pane to render;
  /// callers building on the bridge should NOT invoke `dispose()`
  /// directly — go through [AgentRunHandle.dispose] / `kill()` /
  /// `bridge.handleSessionRemoved`.
  TerminalSession get session => _session;

  /// Resolves with the child process's exit code when the command
  /// finishes. Returns `null` if the process was killed before any
  /// exit code could be observed (e.g. PTY init failed entirely).
  Future<int?> get exitCode =>
      _session.agentExitCode ?? Future.value(null);

  /// Promote this session to a visible tab in the terminal pane.
  /// Called by `RUN_CMD` when the soft-timeout or ready-detect
  /// branch wins — at that moment the user almost certainly wants
  /// the running process to be visible and killable.
  void promoteToVisible() => _bridge._promote(this);

  /// Best-effort graceful kill: writes Ctrl+C into the PTY (so the
  /// foreground process group dies, not just the shell wrapper) and
  /// hard-kills after a brief grace window. Idempotent.
  Future<void> kill() async {
    if (_disposed) return;
    try {
      await _session.killAgent();
    } catch (_) {}
  }

  /// Drop bridge bookkeeping for this run. Disposes the underlying
  /// session ONLY if it was never promoted — promoted sessions are
  /// owned by the pane. Idempotent.
  void dispose() => _bridge._disposeHandle(this);
}
