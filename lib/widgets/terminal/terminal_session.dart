import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  bool get usingFallback => _usingFallback;
  ShellSpec? get activeShell => _activeShell;

  TerminalSession({
    required this.id,
    required this.title,
    required this.workingDirectory,
    this.onShellSwitched,
    this.onPidStarted,
    this.onPidEnded,
  }) {
    terminal = Terminal();
    controller = TerminalController();
    focusNode = FocusNode(debugLabel: title);
    scrollController = ScrollController();
  }

  /// Start the session. If [preferredShellId] is given we try that one first;
  /// otherwise we use [ShellDiscovery.bestAvailable].
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

    try {
      _pty = Pty.start(
        shell.executable,
        arguments: shell.startupArgs,
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
      if (!decidedSuccess) {
        _earlyOutput.write(data);
        if (ShellDiscovery.looksLikeFatalShellError(_earlyOutput.toString())) {
          // Bail to the next candidate.
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
      _proc = await Process.start(
        shell.executable,
        shell.startupArgs,
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

      _proc!.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => terminal.write('$line\r\n'));
      _proc!.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) => terminal.write('\x1b[31m$line\x1b[0m\r\n'));

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
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _earlyWatchdog?.cancel();
    try {
      _pty?.kill();
    } catch (_) {}
    try {
      _proc?.kill();
    } catch (_) {}
    if (_trackedPid != null) {
      try {
        onPidEnded?.call(_trackedPid!);
      } catch (_) {}
      _trackedPid = null;
    }
    focusNode.dispose();
    scrollController.dispose();
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
