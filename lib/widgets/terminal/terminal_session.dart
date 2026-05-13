import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_pty/flutter_pty.dart';
import 'package:xterm/xterm.dart';

import '../../services/shell_discovery.dart';

/// A single terminal session.
///
/// Tries `flutter_pty.Pty.start` for a real ConPTY-backed shell. If PTY init
/// throws, or if the spawned shell reports a fatal startup error within
/// roughly a second (e.g. PowerShell 5.1's `8009001d` managed-runtime
/// failure), we transparently retry with a safer shell — typically
/// `cmd.exe` on Windows.
///
/// The final escape hatch is `Process.start` line-mode (no PTY), used only
/// when *all* candidate shells refuse to start under PTY.
class TerminalSession {
  final String id;
  String title;
  final String workingDirectory;
  late final Terminal terminal;
  late final TerminalController controller;
  late final FocusNode focusNode;
  late final ScrollController scrollController;

  /// Attached to this session's `TerminalView` so the URL ctrl+click
  /// hook in `TerminalPane` can reach `RenderTerminal.getCellOffset(...)`
  /// and convert raw pointer positions to absolute buffer cells.
  ///
  /// **Why this exists:** xterm 4.0.0's public `TerminalView.onTapUp`
  /// callback is dead code. The package's gesture detector declares an
  /// `onTapUp` field but never wires it into the `TapGestureRecognizer`
  /// (the recognizer's `onTapUp` is hardcoded to an internal handler
  /// that only invokes `onSingleTapUp`, which `TerminalView` never sets).
  /// `onSecondaryTapUp` IS wired through, which is why right-click works
  /// fine but primary-click callbacks silently no-op. Earlier
  /// implementations of "ctrl+click to open URLs" relied on `onTapUp`
  /// and never fired. The terminal pane now wraps the view in a raw
  /// `Listener` and uses this key to access xterm's render object.
  final GlobalKey<TerminalViewState> viewKey = GlobalKey<TerminalViewState>();

  /// Callback fired when the session ends up using a different shell than
  /// the one originally requested (auto-fallback).
  final void Function(ShellSpec shell, String reason)? onShellSwitched;

  /// Fired with the OS-level child PID once the shell process is
  /// actually live (PTY or fallback path). The process manager's
  /// `LumenProcessTracker` listens here so the "Lumen-spawned"
  /// filter chip is accurate. Optional so tests / unit harnesses
  /// can omit it.
  final void Function(int pid)? onPidStarted;

  /// Fired when the session is disposed so the tracker can drop
  /// the PID. Paired with [onPidStarted].
  final void Function(int pid)? onPidEnded;

  Pty? _pty;
  Process? _proc;
  int? _trackedPid;
  bool _disposed = false;
  bool _usingFallback = false;
  ShellSpec? _activeShell;
  final StringBuffer _earlyOutput = StringBuffer();
  Timer? _earlyWatchdog;

  /// Set when this session is an agent-spawned one-shot command (RUN_CMD)
  /// rather than an interactive shell. The pane uses this to render a
  /// distinct icon/label, and the start path runs the command directly
  /// via the chosen shell's `commandArgs(...)` instead of dropping the
  /// user into an interactive prompt.
  final String? _agentCommand;

  /// Optional callback fired with each output chunk *after* ANSI
  /// escape codes have been stripped — i.e. the model-friendly view.
  /// xterm still sees the raw bytes so the human terminal renders
  /// colors and cursor moves correctly.
  final void Function(String stripped)? _onAgentOutput;

  /// Resolves with the child process's exit code when the agent
  /// command finishes. Null in shell mode.
  Completer<int?>? _agentExitCompleter;

  bool get usingFallback => _usingFallback;
  ShellSpec? get activeShell => _activeShell;

  /// True when this session was spawned to run a single agent command
  /// (vs an interactive shell). The terminal pane uses this to badge
  /// the tab and route close-tab events through the agent bridge.
  bool get isAgent => _agentCommand != null;

  /// The original command line the agent asked us to run. Useful for
  /// tab labels and tooltips. Null in shell mode.
  String? get agentCommand => _agentCommand;

  /// Future that completes with the exit code of the agent process.
  /// Null in shell mode. Resolves with `null` if the session was
  /// disposed before the process ever started.
  Future<int?>? get agentExitCode => _agentExitCompleter?.future;

  TerminalSession({
    required this.id,
    required this.title,
    required this.workingDirectory,
    this.onShellSwitched,
    this.onPidStarted,
    this.onPidEnded,
  })  : _agentCommand = null,
        _onAgentOutput = null {
    terminal = Terminal();
    controller = TerminalController();
    focusNode = FocusNode(debugLabel: title);
    scrollController = ScrollController();
  }

  /// Build a session that runs a single command through the user's
  /// preferred shell instead of starting an interactive shell. This
  /// is the entry point used by the agent terminal bridge for
  /// `RUN_CMD` invocations: same xterm widget, same PID-tracking
  /// hooks, same kill semantics — just spawned via
  /// `shell.commandArgs(command)` so it exits when the command does
  /// (or stays alive for daemon-style commands until killed).
  ///
  /// [onAgentOutput] receives ANSI-stripped chunks for the model.
  /// [agentExitCompleter] resolves with the exit code; the bridge
  /// uses it to wire `RUN_CMD`'s race against `whenCancelled` /
  /// `softTimeout` / `readyDetected`.
  TerminalSession.agent({
    required this.id,
    required this.title,
    required this.workingDirectory,
    required String command,
    this.onPidStarted,
    this.onPidEnded,
    void Function(String stripped)? onAgentOutput,
  })  : _agentCommand = command,
        _onAgentOutput = onAgentOutput,
        onShellSwitched = null {
    terminal = Terminal();
    controller = TerminalController();
    focusNode = FocusNode(debugLabel: title);
    scrollController = ScrollController();
    _agentExitCompleter = Completer<int?>();
  }

  /// Start the session. If [preferredShellId] is given we try that one first;
  /// otherwise we use [ShellDiscovery.bestAvailable].
  ///
  /// In agent mode (constructed via [TerminalSession.agent]) we use only
  /// the preferred shell with [ShellSpec.commandArgs] — running the same
  /// command across multiple fallback shells would either re-execute it
  /// (bad: side effects twice) or leak state. If PTY init fails for that
  /// one shell we still drop to the [Process.start] fallback so the
  /// command runs *somewhere*.
  Future<void> start({String? preferredShellId}) async {
    final available = await ShellDiscovery.available();
    final ordered = <ShellSpec>[];

    if (preferredShellId != null) {
      final pref = available.firstWhere(
        (s) => s.id == preferredShellId,
        orElse: () => available.isNotEmpty
            ? available.first
            : ShellSpec(
                id: 'fallback',
                label: 'Fallback shell',
                executable: Platform.isWindows ? 'cmd.exe' : 'sh',
              ),
      );
      ordered.add(pref);
      for (final s in available) {
        if (s.id != pref.id) ordered.add(s);
      }
    } else {
      ordered.addAll(available);
    }

    if (ordered.isEmpty) {
      ordered.add(
        ShellSpec(
          id: 'fallback',
          label: 'Fallback shell',
          executable: Platform.isWindows ? 'cmd.exe' : 'sh',
        ),
      );
    }

    // Agent mode: single-shot through the user's preferred shell only.
    // Don't iterate fallbacks — the command might have side effects and
    // running it twice on a fallback retry is worse than failing loudly.
    if (isAgent) {
      _activeShell = ordered.first;
      final ok = await _attemptPty(ordered.first, isLastCandidate: true);
      if (!ok && !(_agentExitCompleter?.isCompleted ?? true)) {
        // PTY/Process fallback both failed and never resolved the
        // exit completer. Resolve with null so callers don't deadlock.
        _agentExitCompleter?.complete(null);
      }
      return;
    }

    for (var i = 0; i < ordered.length; i++) {
      if (_disposed) return;
      final shell = ordered[i];
      _activeShell = shell;
      final isLastCandidate = i == ordered.length - 1;
      final ok = await _attemptPty(shell, isLastCandidate: isLastCandidate);
      if (ok) {
        if (preferredShellId != null && shell.id != preferredShellId) {
          onShellSwitched?.call(
            shell,
            'requested shell unavailable or unstable',
          );
        }
        return;
      }
    }
  }

  Future<bool> _attemptPty(
    ShellSpec shell, {
    required bool isLastCandidate,
  }) async {
    _earlyOutput.clear();
    _earlyWatchdog?.cancel();

    // Agent mode: run a single command through the chosen shell using
    // its `commandArgs(...)` (e.g. `/c <cmd>`, `-Command <cmd>`,
    // `-c <cmd>`). Shell mode keeps the existing interactive
    // [startupArgs] path.
    final args = isAgent
        ? shell.commandArgs(_agentCommand!)
        : shell.startupArgs;

    try {
      _pty = Pty.start(
        shell.executable,
        arguments: args,
        workingDirectory: workingDirectory,
        // CRITICAL: pass the full parent environment. `flutter_pty`
        // 0.4.2 does NOT auto-inherit `Platform.environment` when
        // omitted — the child gets a near-empty env. Without
        // `SystemRoot` / `WINDIR` in particular, Node 22 crashes on
        // startup with `Assertion failed: ncrypto::CSPRNG(nullptr, 0)`
        // because `BCryptGenRandom` can't locate the Windows crypto
        // DLLs (`bcryptprimitives.dll`). Plenty of other Windows
        // tools (npm cache writes, Vite temp files, anything calling
        // `%USERPROFILE%`) also break in the same env-stripped state.
        // Passing `Platform.environment` makes the PTY child see the
        // same env as the parent flutter process, which is the same
        // env the user gets in regular PowerShell.
        environment: Platform.environment,
        columns: terminal.viewWidth,
        rows: terminal.viewHeight,
      );
      // Right after the FFI call succeeded is the only moment we
      // can be sure of the child's identity. Hand the PID off to
      // the process-manager tracker so descendant tooling
      // (npm/node/python spawned inside this shell) can be
      // flagged as Lumen-spawned. Failures here are swallowed —
      // bookkeeping should never abort a terminal start.
      _announcePid(_pty?.pid);
    } catch (e) {
      terminal.write(
        '\x1b[33m[PTY init failed for ${shell.label}: $e]\x1b[0m\r\n',
      );
      if (isLastCandidate) {
        await _startProcessFallback(shell);
        return true;
      }
      return false;
    }

    final completer = Completer<bool>();
    bool decidedSuccess = false;

    _pty!.output.cast<List<int>>().transform(const Utf8Decoder()).listen((
      data,
    ) {
      terminal.write(data);
      // Agent mode: tee an ANSI-stripped copy to the model-facing
      // callback so RUN_CMD's ready-pattern / error-string scanners
      // see plain text instead of `\x1b[31m` color escapes.
      if (isAgent && _onAgentOutput != null) {
        try {
          _onAgentOutput(_stripAnsi(data));
        } catch (e) {
          debugPrint('agent-output tee error: $e');
        }
      }
      if (!decidedSuccess) {
        _earlyOutput.write(data);
        // Fatal-error sniffing only applies to interactive shell
        // sessions where we can fall back to a different candidate.
        // In agent mode there's only one shell and the command's
        // own stderr is its own business — let it through.
        if (!isAgent &&
            ShellDiscovery.looksLikeFatalShellError(_earlyOutput.toString())) {
          terminal.write(
            '\r\n\x1b[33m[Detected fatal ${shell.label} startup error — '
            'switching shell…]\x1b[0m\r\n',
          );
          try {
            _pty?.kill();
          } catch (_) {}
          _earlyWatchdog?.cancel();
          if (!completer.isCompleted) completer.complete(false);
        }
      }
    }, onError: (e, _) => terminal.write('\r\n[pty stream error: $e]\r\n'));

    // Agent mode: forward exit code to the completer so callers can
    // race it against cancel / soft-timeout futures.
    if (isAgent) {
      _pty!.exitCode.then((code) {
        if (_agentExitCompleter != null &&
            !_agentExitCompleter!.isCompleted) {
          _agentExitCompleter!.complete(code);
        }
      }).catchError((_) {
        if (_agentExitCompleter != null &&
            !_agentExitCompleter!.isCompleted) {
          _agentExitCompleter!.complete(null);
        }
      });
    }

    terminal.onOutput = (data) {
      if (_disposed) return;
      try {
        _pty!.write(const Utf8Encoder().convert(data));
      } catch (e) {
        debugPrint('pty write error: $e');
      }
    };

    terminal.onResize = (w, h, pw, ph) {
      try {
        _pty!.resize(h, w);
      } catch (_) {}
    };

    // Watchdog: if no fatal pattern surfaces within 1.2s, treat as healthy.
    _earlyWatchdog = Timer(const Duration(milliseconds: 1200), () {
      if (!completer.isCompleted) {
        decidedSuccess = true;
        _earlyOutput.clear();
        completer.complete(true);
      }
    });

    return completer.future;
  }

  Future<void> _startProcessFallback(ShellSpec shell) async {
    _usingFallback = true;
    terminal.write(
      '\x1b[2m[Using line-mode fallback for ${shell.label} — '
      'no full TTY support]\x1b[0m\r\n\r\n',
    );
    try {
      // Same args resolution as the PTY path: agent commands take
      // `commandArgs(cmd)`, interactive shells take `startupArgs`.
      final args = isAgent
          ? shell.commandArgs(_agentCommand!)
          : shell.startupArgs;
      _proc = await Process.start(
        shell.executable,
        args,
        workingDirectory: workingDirectory,
        runInShell: false,
        // `Process.start` defaults to `includeParentEnvironment: true`
        // already, but stating it explicitly here documents the
        // requirement and matches the `Pty.start` call above.
        // Same Node-22-CSPRNG class of crashes will hit if env is
        // empty — see the long comment on the PTY path.
        includeParentEnvironment: true,
      );
      _announcePid(_proc?.pid);

      // Agent mode: tee ANSI-stripped output to the agent callback.
      // Process.start gives us stdout/stderr separately so we feed
      // both into the same callback (the agent doesn't distinguish
      // streams — it just wants the text, same as the PTY path).
      _proc!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            terminal.write('$line\r\n');
            if (isAgent && _onAgentOutput != null) {
              try {
                _onAgentOutput('${_stripAnsi(line)}\n');
              } catch (e) {
                debugPrint('agent-output tee error: $e');
              }
            }
          });
      _proc!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            terminal.write('\x1b[31m$line\x1b[0m\r\n');
            if (isAgent && _onAgentOutput != null) {
              try {
                _onAgentOutput('${_stripAnsi(line)}\n');
              } catch (e) {
                debugPrint('agent-output tee error: $e');
              }
            }
          });

      // Forward fallback-process exit to the agent completer.
      if (isAgent) {
        unawaited(
          _proc!.exitCode.then((code) {
            if (_agentExitCompleter != null &&
                !_agentExitCompleter!.isCompleted) {
              _agentExitCompleter!.complete(code);
            }
          }),
        );
      }

      final inputBuffer = StringBuffer();
      terminal.onOutput = (data) {
        if (_disposed) return;
        for (final ch in data.runes) {
          final c = String.fromCharCode(ch);
          if (c == '\r' || c == '\n') {
            final cmd = inputBuffer.toString();
            inputBuffer.clear();
            terminal.write('\r\n');
            try {
              _proc!.stdin.writeln(cmd);
            } catch (_) {}
          } else if (ch == 0x7f || ch == 0x08) {
            if (inputBuffer.isNotEmpty) {
              final remainder = inputBuffer.toString();
              inputBuffer.clear();
              inputBuffer.write(remainder.substring(0, remainder.length - 1));
              terminal.write('\b \b');
            }
          } else {
            inputBuffer.write(c);
            terminal.write(c);
          }
        }
      };
    } catch (e) {
      terminal.write(
        '\x1b[31m[Failed to start fallback shell ${shell.label}: $e]\x1b[0m\r\n',
      );
      // Don't strand the completer — caller is awaiting it.
      if (isAgent &&
          _agentExitCompleter != null &&
          !_agentExitCompleter!.isCompleted) {
        _agentExitCompleter!.complete(null);
      }
    }
  }

  /// Best-effort graceful kill for agent sessions: write Ctrl+C into
  /// the PTY first so ConPTY broadcasts SIGINT to the foreground
  /// process group (which is what kills `node`/`python`/etc. spawned
  /// by `npm`/`pwsh`/`bash` — `Process.killPid` only terminates the
  /// shell wrapper and leaves grandchildren orphaned, the exact bug
  /// behind the "I have to taskkill node every time" complaint).
  /// Then waits up to [graceWindow] before falling through to a hard
  /// kill via `_pty.kill()` / `_proc.kill()`.
  Future<void> killAgent({
    Duration graceWindow = const Duration(milliseconds: 500),
  }) async {
    if (!isAgent) return;
    if (_agentExitCompleter?.isCompleted ?? true) {
      // Already exited (or never started). Nothing to do.
      _hardKill();
      return;
    }
    // Ctrl+C to the PTY = SIGINT to the foreground process group.
    try {
      _pty?.write(Uint8List.fromList([0x03]));
    } catch (_) {}
    // Race the grace window vs. a clean exit.
    try {
      await _agentExitCompleter!.future.timeout(graceWindow);
      _hardKill(); // No-op if everything has already torn down.
      return;
    } on TimeoutException {
      // Fall through to hard-kill.
    } catch (_) {
      // Future itself errored — hard kill anyway.
    }
    _hardKill();
  }

  /// Generalised graceful shutdown that works for BOTH interactive and
  /// agent sessions. Writes Ctrl+C into the PTY (broadcasts SIGINT to
  /// the foreground process group, which is the only way to take down
  /// long-running grandchildren spawned via the shell — `Process.killPid`
  /// alone would orphan `node`/`python`/etc.), waits [graceWindow], and
  /// then unconditionally hard-kills. Always followed by a [dispose] in
  /// the caller; this method does NOT release the focus/scroll
  /// controllers.
  ///
  /// The agent variant ([killAgent]) is preserved for callers that
  /// specifically want to race the agent exit completer (RUN_CMD's
  /// soft-timeout / cancel path). For "I just want this terminal dead
  /// before I tear down the workspace", use this method.
  Future<void> terminate({
    Duration graceWindow = const Duration(milliseconds: 250),
  }) async {
    if (_disposed) return;
    try {
      _pty?.write(Uint8List.fromList([0x03]));
    } catch (_) {}
    // For agent sessions we have a real exit completer to race against,
    // so we get an early return on clean exit. For interactive sessions
    // there's nothing to await on — just sleep the grace window and
    // hard-kill.
    if (isAgent && !(_agentExitCompleter?.isCompleted ?? true)) {
      try {
        await _agentExitCompleter!.future.timeout(graceWindow);
      } on TimeoutException {
        // Fall through to hard-kill.
      } catch (_) {
        // Completer errored — hard kill anyway.
      }
    } else {
      await Future<void>.delayed(graceWindow);
    }
    _hardKill();
  }

  /// Final-resort kill. Called by [killAgent] after the grace window
  /// and unconditionally by [dispose]. Idempotent — safe to call when
  /// the process has already exited.
  void _hardKill() {
    try {
      _pty?.kill();
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _earlyWatchdog?.cancel();
    _hardKill();
    if (_agentExitCompleter != null && !_agentExitCompleter!.isCompleted) {
      _agentExitCompleter!.complete(null);
    }
    if (_trackedPid != null) {
      try {
        onPidEnded?.call(_trackedPid!);
      } catch (_) {}
      _trackedPid = null;
    }
    focusNode.dispose();
    scrollController.dispose();
  }

  /// Strip ANSI escape sequences from PTY output so the agent's
  /// view (regex-based ready/error scanners, tool_result text) sees
  /// plain text instead of `\x1b[31m`/`\x1b]0;…\x07` noise. xterm
  /// itself still gets the raw bytes for color rendering.
  ///
  /// Matches:
  ///  - CSI sequences `ESC [ <params> <intermediate> <final>` (most
  ///    color/cursor codes);
  ///  - OSC sequences `ESC ] <text> (BEL | ESC \)` (window titles,
  ///    hyperlinks);
  ///  - One-byte ESC sequences (`ESC =`, `ESC >`, `ESC c`, etc.).
  ///
  /// Note: chunk-local — a sequence split across stream chunks may
  /// leak a stray escape byte. In practice PTY drivers flush whole
  /// sequences; callers that need bullet-proof stripping can buffer
  /// and call this on accumulated text.
  static final RegExp _ansiCsi = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
  static final RegExp _ansiOsc = RegExp(
    r'\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)',
  );
  static final RegExp _ansiSimple = RegExp(r'\x1B[=>cDEHMNOZ78]');

  static String _stripAnsi(String s) {
    return s
        .replaceAll(_ansiOsc, '')
        .replaceAll(_ansiCsi, '')
        .replaceAll(_ansiSimple, '');
  }

  /// Hand a freshly-known child PID to the optional tracker
  /// callbacks. Centralised so both the PTY and `Process.start`
  /// fallback paths use the same plumbing — and so the eventual
  /// `dispose` knows which PID it owns.
  void _announcePid(int? pid) {
    if (pid == null || pid <= 0) return;
    _trackedPid = pid;
    try {
      onPidStarted?.call(pid);
    } catch (_) {}
  }
}
