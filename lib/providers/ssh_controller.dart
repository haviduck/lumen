import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../services/ssh/ssh_client_service.dart';
import '../services/ssh/ssh_host.dart';
import '../services/ssh/ssh_remote_file_service.dart';
import '../services/ssh/ssh_terminal_pre_processor.dart';
import '../services/ssh/ssh_vault.dart';

/// Payload emitted by [SshController.onLumenEditRequest] when the
/// terminal stream contains a `LumenEdit=` OSC 1337 sequence (typically
/// produced by the bundled `lumen-edit` shell helper). Listeners route
/// this to the editor's remote-file open path.
class SshLumenEditRequest {
  final String hostId;
  final String remotePath;
  const SshLumenEditRequest({required this.hostId, required this.remotePath});
}

/// Mirror of [SshLumenEditRequest] for `LumenGrab=` payloads. Listeners
/// route this to a "download into the open workspace" handler — the
/// inverse direction of `lumen-edit` (remote → local copy, no save-back
/// channel, no in-memory mirror tracking).
class SshLumenGrabRequest {
  final String hostId;
  final String remotePath;
  const SshLumenGrabRequest({required this.hostId, required this.remotePath});
}

/// Closure invoked by [SshController._runConnect] right after a
/// session reaches `connected`, asking the user whether Lumen should
/// SFTP-upload + source the session-scoped shell helpers
/// (`lumen-edit`, `lumen-grab`, OSC 7 cwd reporting) into the new
/// shell.
///
/// Returning `true` lets the controller proceed with the existing
/// auto-install flow (uploads a self-deleting script to `/tmp` and
/// types `. <path>` into the shell). Returning `false` skips the
/// upload entirely so nothing is left on the remote.
///
/// The closure runs on a context owned by the call site (typically a
/// top-level shell context captured before the picker pops), so it
/// can safely outlive the connect future.
typedef SshHelpersInstallPrompter = Future<bool> Function(SshHost host);

/// State of a single live SSH session in the UI.
enum SshSessionState { connecting, connected, disconnected, failed }

/// One live SSH session. Pairs a [SshConnection] with the xterm
/// [Terminal] that renders its shell. The controller owns the list
/// of these — widgets just consume.
class SshSessionEntry {
  /// Stable id, derived from `<hostId>-<millis>` so multiple sessions
  /// against the same host coexist in the tab strip.
  final String id;
  final SshHost host;

  /// Live xterm terminal. Always non-null; the connection might be
  /// null while connecting/failed but the terminal is created
  /// up-front so the UI can render the spinner banner / failure
  /// message inside it.
  final Terminal terminal;
  final TerminalController termCtrl;

  /// `null` until [SshSessionState.connected]. Cleared when the
  /// session is closed.
  SshConnection? connection;

  /// `null` until the shell channel is opened. Holds the dartssh2
  /// session so window resize calls can reach `resizeTerminal`.
  SSHSession? shell;

  SshSessionState state;
  String? failureMessage;

  /// Output of the dartssh2 shell, terminated cleanly when the user
  /// closes the tab. Used by [SshController.closeSession] to wait on
  /// graceful shutdown.
  StreamSubscription<List<int>>? _stdoutSub;
  StreamSubscription<List<int>>? _stderrSub;
  StreamSubscription<void>? _closeSub;

  /// Last cwd reported via OSC 7 (see [SshTerminalPreProcessor]).
  /// `null` until the shell emits one. The upload dialog and the
  /// internal-drag drop handler read this so "drop a file" lands in
  /// the dir the user is actually `cd`'d into rather than `$HOME`.
  /// Bumped by [_runConnect] via [notifyListeners] so reactive
  /// reads see the live value.
  String? lastKnownCwd;

  /// Pre-processor that strips magic OSCs (cwd report,
  /// `lumen-edit`) before bytes hit xterm. Recreated per session
  /// to keep carry-over state isolated between tabs.
  late final SshTerminalPreProcessor preProcessor;

  SshSessionEntry({
    required this.id,
    required this.host,
    required this.terminal,
    required this.termCtrl,
    required this.state,
  });
}

/// Top-level SSH state. Mounted at the root via Provider, parallel
/// to MediaController. Widgets read `sshController.sessions` to render
/// the Remote pane and the activity-bar host picker.
class SshController extends ChangeNotifier {
  late final SshVault _vault;
  late final SshClientService _clientService;
  late final SshRemoteFileService _remoteFiles;

  bool _ready = false;
  bool get ready => _ready;

  SshVault get vault => _vault;
  SshClientService get clientService => _clientService;
  SshRemoteFileService get remoteFiles => _remoteFiles;

  /// Live sessions. Order matches the Remote pane's tab strip.
  final List<SshSessionEntry> _sessions = [];
  List<SshSessionEntry> get sessions => List.unmodifiable(_sessions);

  /// Currently focused session in the Remote pane. Drives which
  /// terminal is rendered; null = "no session focused" (the pane
  /// shows the empty-state body).
  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;

  /// Convenience: any sessions exist.
  bool get hasSessions => _sessions.isNotEmpty;

  /// True when the editor right-slot should reserve room for the
  /// Remote pane. Today this is just `hasSessions`; if we ever add
  /// a "keep the pane mounted with no sessions" preference we'd plumb
  /// it through here.
  bool get hasEditorMounted => hasSessions;

  /// Cached handlers used for *reconnects* and other "kick off a fresh
  /// connect without going through the picker UI" flows. The widget
  /// that triggers the original connect populates these by passing
  /// them to [connectToHost]; the controller stashes them so a later
  /// `reconnect(id)` call can rerun the auth flow without the caller
  /// having to remember to re-pass closures. Not used as a public
  /// "global bind" — every external connect call MUST pass fresh
  /// closures so the captured BuildContexts are live.
  SshHostKeyHandler? _lastHostKeyHandler;
  SshPasswordRequester? _lastPasswordRequester;
  SshPassphraseRequester? _lastPassphraseRequester;
  SshHelpersInstallPrompter? _lastHelpersInstallPrompter;

  /// Broadcasts whenever the terminal stream contains an OSC 1337
  /// `LumenEdit=<path>` payload — typically produced by the bundled
  /// `lumen-edit` shell helper. The `_SshAppStateBridge` in main.dart
  /// listens and forwards to `AppState.openRemoteFile`. Broadcast so
  /// future consumers (toast on open, recent-remote-edits list) can
  /// subscribe without conflicting with the bridge.
  final _lumenEditCtl = StreamController<SshLumenEditRequest>.broadcast();
  Stream<SshLumenEditRequest> get onLumenEditRequest => _lumenEditCtl.stream;

  /// Sibling stream for `LumenGrab=<path>` payloads. Same broadcast +
  /// bridge pattern as [onLumenEditRequest]; the bridge forwards to
  /// `AppState.grabRemoteFile`. Kept on a separate stream rather than
  /// a tagged union because the listeners' work is materially
  /// different — edit opens an editor tab, grab writes a file to disk
  /// — and conflating the two would make every consumer branch on
  /// the request type.
  final _lumenGrabCtl = StreamController<SshLumenGrabRequest>.broadcast();
  Stream<SshLumenGrabRequest> get onLumenGrabRequest => _lumenGrabCtl.stream;

  Future<void> init() async {
    _vault = await SshVault.load();
    _clientService = SshClientService(vault: _vault);
    _remoteFiles = SshRemoteFileService(
      connectionForHostId: _connectionForHostId,
    );
    _ready = true;
    notifyListeners();
  }

  SshConnection? _connectionForHostId(String hostId) {
    for (final s in _sessions) {
      if (s.host.id == hostId &&
          s.connection != null &&
          !(s.connection?.isClosed ?? true)) {
        return s.connection;
      }
    }
    return null;
  }

  // ── Session lifecycle ────────────────────────────────────────

  /// Connect to a vaulted host. Returns the new session entry. Adds
  /// the entry to [sessions] in the `connecting` state immediately so
  /// the UI can render a loading tab; transitions to `connected` or
  /// `failed` asynchronously.
  ///
  /// The [hostKeyHandler] / [passwordRequester] / [passphraseRequester]
  /// closures are invoked when the connect path needs UI input
  /// (TOFU prompt, password entry, key passphrase). They MUST close
  /// over a `BuildContext` that's still mounted by the time the
  /// connect resolves — typically a top-level shell context, NOT a
  /// dialog/sheet that the user just dismissed.
  ///
  /// [helpersInstallPrompter] is invoked once per successful connect,
  /// asking the user whether Lumen should auto-install the shell
  /// shortcuts (`lumen-edit`, `lumen-grab`, OSC 7 cwd reporting). When
  /// `null` or returning `false`, the install step is skipped
  /// entirely — nothing is uploaded to the remote.
  Future<SshSessionEntry> connectToHost(
    SshHost host, {
    required SshHostKeyHandler hostKeyHandler,
    required SshPasswordRequester passwordRequester,
    required SshPassphraseRequester passphraseRequester,
    SshHelpersInstallPrompter? helpersInstallPrompter,
  }) async {
    _lastHostKeyHandler = hostKeyHandler;
    _lastPasswordRequester = passwordRequester;
    _lastPassphraseRequester = passphraseRequester;
    _lastHelpersInstallPrompter = helpersInstallPrompter;

    final id = '${host.id}-${DateTime.now().millisecondsSinceEpoch}';
    final terminal = Terminal(
      maxLines: 10000,
      // SSH-aware default; the dartssh2 PTY config carries the same
      // value below. Keeping these in sync matters because xterm and
      // the remote shell both consult it for app-level color hints.
    );
    final entry = SshSessionEntry(
      id: id,
      host: host,
      terminal: terminal,
      termCtrl: TerminalController(),
      state: SshSessionState.connecting,
    );
    // Pre-processor handlers close over the entry so OSC 7 reports
    // mutate this specific session's `lastKnownCwd` and `lumen-edit`
    // payloads carry the host id (so the remote-file open path knows
    // which connection to SFTP from). Constructed BEFORE we await
    // anything so the field is non-null by the time `_runConnect`
    // wires the stdout listener.
    entry.preProcessor = SshTerminalPreProcessor(
      onCwd: (cwd) {
        if (entry.lastKnownCwd != cwd) {
          entry.lastKnownCwd = cwd;
          notifyListeners();
        }
      },
      onLumenEdit: (path) {
        if (path.isEmpty) return;
        _lumenEditCtl.add(
          SshLumenEditRequest(hostId: entry.host.id, remotePath: path),
        );
      },
      onLumenGrab: (path) {
        if (path.isEmpty) return;
        _lumenGrabCtl.add(
          SshLumenGrabRequest(hostId: entry.host.id, remotePath: path),
        );
      },
    );
    _sessions.add(entry);
    _activeSessionId ??= id;
    notifyListeners();

    unawaited(_runConnect(
      entry,
      hostKeyHandler: hostKeyHandler,
      passwordRequester: passwordRequester,
      passphraseRequester: passphraseRequester,
      helpersInstallPrompter: helpersInstallPrompter,
    ));
    return entry;
  }

  Future<void> _runConnect(
    SshSessionEntry entry, {
    required SshHostKeyHandler hostKeyHandler,
    required SshPasswordRequester passwordRequester,
    required SshPassphraseRequester passphraseRequester,
    SshHelpersInstallPrompter? helpersInstallPrompter,
  }) async {
    try {
      final conn = await _clientService.connect(
        host: entry.host,
        hostKeyHandler: hostKeyHandler,
        requestPassword: passwordRequester,
        requestPassphrase: passphraseRequester,
      );
      entry.connection = conn;

      final shell = await conn.shell(
        rows: entry.terminal.viewHeight,
        cols: entry.terminal.viewWidth,
      );
      entry.shell = shell;

      // Pipe shell stdout/stderr → xterm; xterm.onOutput → shell.write.
      //
      // Encoding contract:
      // - Shell output (stdout/stderr) arrives as raw UTF-8 bytes
      //   from dartssh2. We decode with `allowMalformed: true` so a
      //   stray binary byte (e.g. from `cat` on a binary file)
      //   degrades to a replacement char rather than crashing the
      //   stream. `String.fromCharCodes` was the previous approach —
      //   that's a UTF-16 view that mangles any multi-byte UTF-8 the
      //   moment a non-ASCII char shows up (think emoji in a prompt,
      //   or CJK in an ls listing).
      // - User input from xterm arrives as a Dart String (UTF-16);
      //   we re-encode to UTF-8 before pushing to the shell.
      //   `data.codeUnits` was the previous approach and has the
      //   exact same multi-byte hazard going the other direction.
      const utf8Decoder = Utf8Decoder(allowMalformed: true);
      // Each chunk runs through the pre-processor before xterm sees it.
      // The pre-processor:
      //   - Captures OSC 7 cwd reports → `entry.lastKnownCwd`.
      //   - Captures OSC 1337 `LumenEdit=` payloads → fires
      //     `_lumenEditCtl` so the bridge in main.dart can open the
      //     file in the editor.
      //   - Strips both kinds of sequences from the forwarded text.
      // Other escape sequences (colors, cursor movement, etc.) are
      // passed through untouched — the pre-processor only knows
      // about the two OSC families above.
      entry._stdoutSub = shell.stdout.listen((chunk) {
        final cleaned =
            entry.preProcessor.processStdout(utf8Decoder.convert(chunk));
        if (cleaned.isNotEmpty) entry.terminal.write(cleaned);
      });
      entry._stderrSub = shell.stderr.listen((chunk) {
        final cleaned =
            entry.preProcessor.processStderr(utf8Decoder.convert(chunk));
        if (cleaned.isNotEmpty) entry.terminal.write(cleaned);
      });
      entry._closeSub = conn.onClose.listen((_) {
        entry.state = SshSessionState.disconnected;
        notifyListeners();
      });

      entry.terminal.onOutput = (data) {
        try {
          shell.write(Uint8List.fromList(utf8.encode(data)));
        } catch (_) {}
      };
      entry.terminal.onResize = (cols, rows, pixelWidth, pixelHeight) {
        try {
          shell.resizeTerminal(cols, rows);
        } catch (_) {}
      };

      entry.state = SshSessionState.connected;
      notifyListeners();

      // Optionally inject the shell helpers (`lumen-edit`,
      // `lumen-grab`, OSC 7 cwd reporting) into the freshly opened
      // session — gated on a per-connect user prompt. When the
      // prompt is null or the user declines, NOTHING is uploaded;
      // the remote stays untouched.
      //
      // When the user accepts, the helpers ride in via a
      // SFTP-uploaded self-deleting script that we then source.
      // The script's last statement `rm -f`s itself, so even if
      // the user disconnects mid-session the file doesn't linger
      // (it's gone the moment the source completed).
      //
      // Why upload + source instead of typing the body inline?
      // dartssh2's shell channel runs in canonical mode — the
      // remote shell echoes every byte we write. Typing the full
      // installer body would dump 30+ lines of "you typed this"
      // noise into the user's freshly opened terminal. Uploading
      // the body to a file and sourcing it means the user only
      // sees ONE short input line (`. /tmp/.lumen-helpers-…sh`)
      // plus the duck banner the script prints on its way out.
      // Banner / motd / first PS1 stay intact (the 250ms delay
      // below lets them flush before our line lands).
      //
      // Why fire-and-forget (`unawaited`)?
      // The `_runConnect` future completes once the connection is
      // ready; callers (the activity-bar fast menu, `connectToHost`)
      // shouldn't block on the install prompt or its follow-on
      // SFTP work. Prompt dismiss / SFTP failure / mid-paste
      // channel close are all caught + swallowed inside
      // `_autoInstallShellHelpers`; the user just doesn't get
      // helpers that session. No error spam.
      unawaited(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        // Bail if the session was closed during the wait window.
        if (entry.shell == null ||
            entry.state != SshSessionState.connected) {
          return;
        }
        // Ask the user. No prompter wired ⇒ skip silently (keeps
        // headless / test paths happy without a default-on opt-in).
        if (helpersInstallPrompter == null) return;
        bool accepted;
        try {
          accepted = await helpersInstallPrompter(entry.host);
        } catch (e) {
          // Prompter blew up (e.g. captured BuildContext was
          // unmounted). Treat as "no" — never inject without an
          // explicit yes.
          debugPrint('[ssh] helpers install prompter threw: $e');
          return;
        }
        if (!accepted) return;
        // Re-check session liveness after the user-interaction
        // window: they may have left the dialog open for a while.
        if (entry.shell == null ||
            entry.state != SshSessionState.connected) {
          return;
        }
        await _autoInstallShellHelpers(entry, conn);
      }());
    } catch (e) {
      entry.state = SshSessionState.failed;
      entry.failureMessage = _humanizeError(e);
      notifyListeners();
      // Drop a banner into xterm so the failure is visible inside the
      // tab even if the user navigates away from any toast.
      entry.terminal
          .write('\r\n\x1b[31mSSH connection failed:\x1b[0m ${entry.failureMessage}\r\n');
    }
  }

  /// Close a session. Cancels stream subs, closes the dartssh2 shell
  /// + connection, removes from the list. Idempotent.
  Future<void> closeSession(String id) async {
    final idx = _sessions.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final entry = _sessions[idx];

    await entry._stdoutSub?.cancel();
    await entry._stderrSub?.cancel();
    await entry._closeSub?.cancel();
    entry._stdoutSub = null;
    entry._stderrSub = null;
    entry._closeSub = null;

    try {
      entry.shell?.close();
    } catch (_) {}
    try {
      await entry.connection?.close();
    } catch (_) {}

    entry.connection = null;
    entry.shell = null;
    entry.state = SshSessionState.disconnected;

    _sessions.removeAt(idx);
    if (_activeSessionId == id) {
      _activeSessionId = _sessions.isNotEmpty ? _sessions.last.id : null;
    }
    notifyListeners();
  }

  /// Close every live session. Used by the Remote pane's
  /// "close pane" chrome button — when the last session goes away
  /// the pane unmounts itself (`hasEditorMounted` flips to false),
  /// so this is the user-facing "hide the SSH split" action.
  /// Idempotent.
  Future<void> closeAllSessions() async {
    final ids = _sessions.map((s) => s.id).toList(growable: false);
    for (final id in ids) {
      await closeSession(id);
    }
  }

  /// Set focused session. No-op if [id] isn't a known session id.
  void setActiveSession(String id) {
    if (!_sessions.any((s) => s.id == id)) return;
    if (_activeSessionId == id) return;
    _activeSessionId = id;
    notifyListeners();
  }

  /// Re-attempt a failed session in place — same host, fresh attempt.
  /// Reuses the most recently provided UI handlers from the original
  /// [connectToHost] call. If those have been GC'd or were never set
  /// (initial connect raced), this no-ops with a banner so the user
  /// knows to reopen via the host picker.
  Future<void> reconnect(String id) async {
    final hk = _lastHostKeyHandler;
    final pwd = _lastPasswordRequester;
    final pph = _lastPassphraseRequester;
    final hip = _lastHelpersInstallPrompter;

    final entry = _sessions.firstWhere(
      (s) => s.id == id,
      orElse: () => throw StateError('Session $id not found'),
    );
    if (hk == null || pwd == null || pph == null) {
      entry.terminal.write(
        '\r\n\x1b[33mNo cached UI handlers — reconnect via the SSH icon.\x1b[0m\r\n',
      );
      return;
    }
    entry.state = SshSessionState.connecting;
    entry.failureMessage = null;
    entry.terminal.write('\r\n\x1b[36mReconnecting...\x1b[0m\r\n');
    notifyListeners();
    await _runConnect(
      entry,
      hostKeyHandler: hk,
      passwordRequester: pwd,
      passphraseRequester: pph,
      helpersInstallPrompter: hip,
    );
  }

  /// Type a string into the active shell of [sessionId] as if the
  /// user had pasted it. Trailing newline is the caller's choice
  /// (no auto-newline so "install for this session" can finish with
  /// `\n` to actually evaluate the snippet, while "type but don't
  /// run" can omit it). No-ops if the session has no live shell.
  Future<void> pasteIntoSession(String sessionId, String text) async {
    final entry = _sessions.firstWhere(
      (s) => s.id == sessionId,
      orElse: () => throw StateError('Session $sessionId not found'),
    );
    final shell = entry.shell;
    if (shell == null) return;
    try {
      shell.write(Uint8List.fromList(utf8.encode(text)));
    } catch (_) {
      // Best-effort — if the shell channel went away mid-paste the
      // user will see the disconnect via the close-stream listener.
    }
  }

  /// SFTP-uploads the helper script body produced by
  /// [autoInstallShellHelpersScript] to a per-session unique path
  /// under `/tmp/`, then types `. <path>` into the interactive
  /// shell. The script self-deletes as its last statement so we
  /// don't leak files into `/tmp` even if the user disconnects
  /// mid-session.
  ///
  /// Failure modes (all silent — no helpers, no error spam):
  /// - SFTP subsystem unavailable on the server → `conn.sftp()`
  ///   throws, caught and debug-logged.
  /// - `/tmp` not writable / quota / readonly mount → `sftp.open`
  ///   throws, caught.
  /// - Channel closes between SFTP write and shell paste →
  ///   `pasteIntoSession`'s own try/catch swallows. The temp file
  ///   stays on disk in that edge case (won't self-delete because
  ///   we never sourced it), but `/tmp` is conventionally cleared
  ///   on reboot.
  Future<void> _autoInstallShellHelpers(
    SshSessionEntry entry,
    SshConnection conn,
  ) async {
    // Random suffix so two Lumen sessions to the same host (or a
    // reconnect arriving before /tmp is swept) can't collide on
    // the helper script's path. microsecondsSinceEpoch in base36
    // is 8–9 chars and unique per process tick.
    final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final remotePath = '/tmp/.lumen-helpers-$suffix.sh';

    final body = autoInstallShellHelpersScript();
    try {
      final sftp = await conn.sftp();
      final file = await sftp.open(
        remotePath,
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.write |
            SftpFileOpenMode.truncate,
      );
      try {
        await file.writeBytes(Uint8List.fromList(utf8.encode(body)));
      } finally {
        await file.close();
      }
    } catch (e) {
      // Most common cause is "no SFTP subsystem on this server"
      // (rsync-only / locked-down hosts) or "/tmp is read-only"
      // on hardened images. Either way the user gets a working
      // shell sans helpers, which is strictly better than dumping
      // 30 lines of installer noise into their terminal.
      debugPrint('[ssh] auto-install helpers SFTP write failed: $e');
      return;
    }

    // Bail if the session closed between SFTP write and now.
    if (entry.shell == null ||
        entry.state != SshSessionState.connected) {
      return;
    }
    await pasteIntoSession(entry.id, '. $remotePath\n');
  }

  /// Find an existing session by host id (returns the first match).
  /// Used by the activity-bar fast menu so clicking a host that's
  /// already connected re-focuses its tab instead of opening a new
  /// session.
  SshSessionEntry? findSessionForHost(String hostId) {
    for (final s in _sessions) {
      if (s.host.id == hostId &&
          s.connection != null &&
          !(s.connection?.isClosed ?? true)) {
        return s;
      }
    }
    return null;
  }

  // ── Vault pass-through ───────────────────────────────────────

  Future<void> addHost(SshHost host) async {
    await _vault.addHost(host);
    notifyListeners();
  }

  Future<void> upsertHost(SshHost host) async {
    await _vault.upsertHost(host);
    notifyListeners();
  }

  Future<void> removeHost(String id) async {
    // Disconnect any open sessions on this host first so we don't
    // leak a dartssh2 client whose backing host record vanished.
    final toClose = _sessions
        .where((s) => s.host.id == id)
        .map((s) => s.id)
        .toList();
    for (final sessionId in toClose) {
      await closeSession(sessionId);
    }
    await _vault.removeHost(id);
    notifyListeners();
  }

  // ── Helpers ──────────────────────────────────────────────────

  static String _humanizeError(Object e) {
    final text = e.toString();
    if (text.contains('SocketException') &&
        text.contains('No address')) {
      return 'Could not resolve host (DNS failure)';
    }
    if (text.contains('SocketException') &&
        text.contains('Connection refused')) {
      return 'Connection refused (sshd not listening?)';
    }
    if (text.contains('TimeoutException')) {
      return 'Connection timed out';
    }
    if (text.contains('Authentication')) {
      return 'Authentication failed';
    }
    if (text.contains('host key')) {
      return text;
    }
    return text;
  }

  @override
  void dispose() {
    for (final s in List<SshSessionEntry>.from(_sessions)) {
      // Best-effort cleanup — we can't await in dispose, so we kick
      // off the closes and let the futures complete after dispose.
      unawaited(closeSession(s.id));
    }
    _lumenEditCtl.close();
    _lumenGrabCtl.close();
    super.dispose();
  }
}

/// Reads the user's `~/.ssh/config` and yields parsed [SshHost]
/// entries. Stops at the first parse failure for a given Host block
/// rather than aborting the whole file — the import dialog reports
/// per-block failures alongside successful imports.
class SshConfigImporter {
  static Future<List<SshHost>> importFromUserConfig() async {
    final file = await _resolveConfigPath();
    if (!await file.exists()) {
      throw FileSystemException('SSH config not found', file.path);
    }
    final text = await file.readAsString();
    return _parse(text);
  }

  static Future<File> _resolveConfigPath() async {
    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '';
    if (home.isEmpty) {
      throw FileSystemException('No HOME / USERPROFILE env var', '');
    }
    return File('$home${Platform.pathSeparator}.ssh${Platform.pathSeparator}config');
  }

  static List<SshHost> _parse(String text) {
    final hosts = <SshHost>[];
    String? currentHost;
    String hostname = '';
    String user = '';
    int port = 22;
    String identityFile = '';

    void flush() {
      if (currentHost == null) return;
      // Skip wildcards — `Host *` blocks define defaults, not real
      // connectable hosts.
      if (currentHost!.contains('*') || currentHost!.contains('?')) {
        currentHost = null;
        return;
      }
      final h = (hostname.isNotEmpty ? hostname : currentHost!).trim();
      if (h.isEmpty) {
        currentHost = null;
        return;
      }
      final usr = (user.isNotEmpty ? user : (Platform.environment['USERNAME'] ??
              Platform.environment['USER'] ??
              ''))
          .trim();
      hosts.add(
        SshHost(
          id: SshHost.generateId(
            label: currentHost!,
            user: usr,
            host: h,
            port: port,
          ),
          label: currentHost!,
          host: h,
          port: port,
          user: usr,
          authMethod:
              identityFile.isNotEmpty ? SshAuthMethod.keyFile : SshAuthMethod.agent,
          keyFilePath: identityFile,
          rememberSecret: true,
        ),
      );
    }

    for (final raw in text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      // OpenSSH config is whitespace-separated, key first token.
      // Quoted values are rare in user configs; we tolerate but don't
      // fully parse them — good-enough import.
      final m = RegExp(r'^(\S+)\s+(.+)$').firstMatch(line);
      if (m == null) continue;
      final key = m.group(1)!.toLowerCase();
      final value = m.group(2)!.trim();
      if (key == 'host') {
        flush();
        currentHost = value;
        hostname = '';
        user = '';
        port = 22;
        identityFile = '';
      } else if (key == 'hostname') {
        hostname = value;
      } else if (key == 'user') {
        user = value;
      } else if (key == 'port') {
        port = int.tryParse(value) ?? 22;
      } else if (key == 'identityfile') {
        // OpenSSH expands ~ — do the same so the path actually exists
        // when we try to read it. Strip any quoting.
        var expanded = value.replaceAll('"', '').replaceAll("'", '');
        if (expanded.startsWith('~')) {
          final home = Platform.environment['USERPROFILE'] ??
              Platform.environment['HOME'] ??
              '';
          expanded = expanded.replaceFirst('~', home);
        }
        identityFile = expanded;
      }
    }
    flush();

    return hosts;
  }
}
