import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Status enum reflects the **index** state of the active workspace
/// (i.e. the analyze job's outcome). Background daemons (`serve`,
/// `mcp`) have their own independent flags (`serveRunning` /
/// `mcpRunning`) — they are machine-wide so they don't reflect any
/// single workspace's status.
enum GitNexusStatus {
  noWorkspace,
  noNode,
  notIndexed,
  indexed,
  running, // analyze in flight
  failed,
}

enum GitNexusWikiStatus { idle, running, generated, failed }

/// Who started the serve daemon currently observable on
/// [kGitNexusServePort].
///
///   - [none]    — nothing reachable on the port.
///   - [owned]   — this Lumen window spawned it; we hold the [Process]
///                 handle and `process.exitCode` will tell us when it
///                 dies.
///   - [adopted] — another Lumen window or an external `npx gitnexus
///                 serve` is bound to the port. We don't have the
///                 process handle, only the URL. The UI shows it the
///                 same as [owned] so multi-window UX is consistent;
///                 stopping it requires PID-by-port lookup.
enum DaemonOwnership { none, owned, adopted }

/// Default port the `gitnexus serve` HTTP server binds to. Hard-coded
/// for now — the gitnexus.vercel.app web UI auto-detects this exact
/// address, so changing it would silently break that integration.
const int kGitNexusServePort = 4747;

/// Cadence at which the service re-probes the serve port. Picks up
/// changes made by other Lumen windows (start / stop) without any
/// IPC. 10 s is comfortably below human attention span and well
/// below any HTTP cost worth caring about.
const Duration _kProbeInterval = Duration(seconds: 10);

/// Per-attempt timeout for a probe HTTP GET. We race IPv4 + IPv6 in
/// parallel, so worst-case wall time is one timeout window.
const Duration _kProbeTimeout = Duration(milliseconds: 1500);

/// Manages GitNexus subprocesses against a Lumen workspace. Four
/// distinct lifecycles, different ownership models — read
/// carefully before changing anything:
///
///   1. **analyze** (workspace-scoped, one-shot).
///      `npx gitnexus analyze` in the active workspace, builds
///      `.gitnexus/`, exits. Killed on `bindWorkspace` because it's
///      tied to a single workspace. The icon's primary `status`
///      reflects this job (running / indexed / failed).
///
///   2. **wiki** (workspace-scoped, one-shot).
///      `npx gitnexus wiki` in the active workspace, generates
///      LLM-backed docs from the existing graph, exits. Killed on
///      `bindWorkspace` because it is tied to a single workspace.
///      May be auto-triggered after analyze only when the user opts in.
///
///   3. **serve** (machine-wide, long-running, *adoptable*).
///      `npx gitnexus serve` on `127.0.0.1:4747`. Serves the
///      **global** indexed-repo registry — NOT a single workspace —
///      so a single instance per machine is correct, and starting
///      one from window B while window A already runs one is wrong.
///      This service detects an existing daemon (probe `GET
///      /api/repos`), adopts it instead of spawning a duplicate, and
///      surfaces the same on/off control across every Lumen window.
///      Survives workspace switches AND Lumen-window close (we don't
///      kill it in `dispose`) — that's intentional. If the user
///      wants it gone they flip the switch off.
///
///   4. **mcp** (per-window, long-running, *not* adoptable).
///      `npx gitnexus mcp` (stdio). Pipes don't cross process
///      boundaries cleanly so adoption doesn't apply. Most AI hosts
///      (Claude Desktop, Cursor) spawn their own on demand; this
///      toggle is a niche convenience for users wiring stdio to an
///      external tool. Killed on `dispose` because there's no
///      legitimate way for another window to inherit a stdio pipe.
class GitNexusService extends ChangeNotifier {
  String? _workspacePath;
  bool _hasNpx = false;

  // ── analyze (one-shot, workspace-scoped) ──────────────────────────
  Process? _analyzeProcess;
  GitNexusStatus _status = GitNexusStatus.noWorkspace;
  DateTime? _lastRunAt;
  int? _lastExitCode;
  String _analyzeOutput = '';
  bool _autoWikiAfterAnalyze = false;
  String _wikiModel = '';

  // ── wiki (one-shot, workspace-scoped) ─────────────────────────────
  Process? _wikiProcess;
  GitNexusWikiStatus _wikiStatus = GitNexusWikiStatus.idle;
  DateTime? _lastWikiAt;
  int? _wikiExitCode;
  String _wikiOutput = '';

  // ── serve daemon (HTTP server, machine-wide, adoptable) ───────────
  Process? _serveProcess;
  DaemonOwnership _serveOwnership = DaemonOwnership.none;
  String _serveOutput = '';
  int? _serveExitCode;
  bool _serveStartInFlight = false;

  // ── mcp daemon (stdio MCP server, per-window) ─────────────────────
  Process? _mcpProcess;
  String _mcpOutput = '';
  int? _mcpExitCode;
  bool _mcpStartInFlight = false;

  // ── multi-window discovery ────────────────────────────────────────
  Timer? _probeTimer;
  bool _probeInFlight = false;

  // ── master kill-switch ────────────────────────────────────────────
  /// When false, the entire GitNexus integration goes dark: no probe
  /// loop, no spawn, no analyze, no UI surfaces. Defaults to true so
  /// existing installs are unaffected. Flipped via `setEnabled` from
  /// `AppState`, persisted by `PreferencesService.setGitNexusEnabled`.
  bool _enabled = true;
  bool get enabled => _enabled;

  GitNexusService() {
    _startProbeLoop();
  }

  void _startProbeLoop() {
    _probeTimer?.cancel();
    if (!_enabled) return;
    // Kick the cross-window heartbeat. Light HTTP poll picks up
    // changes made by other Lumen windows without any IPC machinery.
    _probeTimer = Timer.periodic(
      _kProbeInterval,
      (_) => _probeServeAndUpdate(),
    );
    // First probe runs after construction so the icon is correct on
    // app start even before a workspace is bound (e.g. a previous
    // session left a serve running — we want the indicator green
    // immediately, not 10 s later).
    scheduleMicrotask(_probeServeAndUpdate);
  }

  /// Master toggle. When flipped to false:
  ///   - cancels the probe timer (no more :4747 traffic from Lumen),
  ///   - drops adopted state so the UI shows "off" instead of "shared",
  ///   - kills any owned daemon so disabling the integration actually
  ///     means nothing GitNexus-related is running on our behalf.
  /// External orphans (started by a previous session before the user
  /// disabled the integration) are intentionally left alone — we
  /// won't reach into the OS to kill processes the user told us to
  /// forget about. They can stop those manually if they care.
  Future<void> setEnabled(bool wanted) async {
    if (_enabled == wanted) return;
    _enabled = wanted;
    if (!wanted) {
      _probeTimer?.cancel();
      _probeTimer = null;
      await stop();
      await stopWiki();
      await stopServe();
      await stopMcp();
      _serveOwnership = DaemonOwnership.none;
      notifyListeners();
    } else {
      _startProbeLoop();
      notifyListeners();
    }
  }

  // ── public API ────────────────────────────────────────────────────
  String? get workspacePath => _workspacePath;
  GitNexusStatus get status => _status;
  GitNexusWikiStatus get wikiStatus => _wikiStatus;

  /// True while the analyze (one-shot indexer) job is running. Kept
  /// under the legacy `isRunning` name because every call site that
  /// already exists treats "running" as "indexer in flight".
  bool get isRunning => _analyzeProcess != null;

  /// True while *some* `gitnexus serve` is reachable on
  /// [kGitNexusServePort], regardless of who spawned it. Owned and
  /// adopted both count — the UI presents them the same.
  bool get serveRunning => _serveOwnership != DaemonOwnership.none;

  /// True only when this window owns the serve process handle.
  bool get serveOwned => _serveOwnership == DaemonOwnership.owned;

  /// True when the serve daemon is reachable but was started by
  /// another Lumen window or an external `npx gitnexus serve`. The
  /// UI uses this to show "machine-wide" labelling and to warn that
  /// stopping it affects every other window.
  bool get serveAdopted => _serveOwnership == DaemonOwnership.adopted;

  /// True while the persistent stdio MCP server is up in this window.
  bool get mcpRunning => _mcpProcess != null;
  bool get wikiRunning => _wikiProcess != null;

  /// True briefly between toggle-on and process-spawned. Used by the
  /// settings UI to render a transient spinner so the toggle doesn't
  /// look frozen while npx is still resolving the first time.
  bool get serveStarting => _serveStartInFlight && !serveRunning;
  bool get mcpStarting => _mcpStartInFlight && !mcpRunning;

  bool get hasNpx => _hasNpx;
  DateTime? get lastRunAt => _lastRunAt;
  DateTime? get lastWikiAt => _lastWikiAt;
  int? get lastExitCode => _lastExitCode;
  int? get wikiLastExitCode => _wikiExitCode;
  int? get serveLastExitCode => _serveExitCode;
  int? get mcpLastExitCode => _mcpExitCode;
  int get servePort => kGitNexusServePort;
  bool get autoWikiAfterAnalyze => _autoWikiAfterAnalyze;
  String get wikiModel => _wikiModel;

  /// Tail of the analyze job's combined stdout/stderr. Capped at
  /// ~16 KB internally with a stable end window.
  String get outputTail => _tail(_analyzeOutput, 4000);
  String get wikiOutputTail => _tail(_wikiOutput, 4000);
  String get serveOutputTail => _tail(_serveOutput, 4000);
  String get mcpOutputTail => _tail(_mcpOutput, 4000);

  void setWikiPreferences({
    required bool autoWikiAfterAnalyze,
    required String model,
  }) {
    final normalizedModel = model.trim();
    if (_autoWikiAfterAnalyze == autoWikiAfterAnalyze &&
        _wikiModel == normalizedModel) {
      return;
    }
    _autoWikiAfterAnalyze = autoWikiAfterAnalyze;
    _wikiModel = normalizedModel;
    notifyListeners();
  }

  Future<void> bindWorkspace(String? path) async {
    if (_workspacePath == path) return;
    // Analyze is workspace-scoped — kill it on switch. serve and mcp
    // are intentionally NOT touched here:
    //   - serve is machine-wide (it reads the global indexed-repo
    //     registry, not any single workspace), so killing it on
    //     workspace switch creates the exact "port in use after
    //     orphan" UX bug this whole adoption pipeline exists to fix.
    //   - mcp is per-window but doesn't bind to any workspace path
    //     either; nothing changes for it on a workspace swap.
    await stop();
    await stopWiki();
    _workspacePath = path;
    _analyzeOutput = '';
    _wikiOutput = '';
    _lastExitCode = null;
    _wikiExitCode = null;
    _wikiStatus = GitNexusWikiStatus.idle;
    await refreshStatus();
    // Re-probe so the icon picks up an externally-running serve as
    // soon as a workspace opens.
    unawaited(_probeServeAndUpdate());
  }

  Future<void> refreshStatus() async {
    final ws = _workspacePath;
    if (ws == null || ws.isEmpty) {
      _status = GitNexusStatus.noWorkspace;
      notifyListeners();
      return;
    }
    if (_analyzeProcess != null) {
      _status = GitNexusStatus.running;
      notifyListeners();
      return;
    }
    _hasNpx = await _probeNpx();
    if (!_hasNpx) {
      _status = GitNexusStatus.noNode;
      notifyListeners();
      return;
    }
    _status = await Directory(p.join(ws, '.gitnexus')).exists()
        ? GitNexusStatus.indexed
        : GitNexusStatus.notIndexed;
    notifyListeners();
  }

  // ── analyze ───────────────────────────────────────────────────────
  Future<void> analyze({bool force = false}) async {
    if (!_enabled) return;
    final ws = _workspacePath;
    if (ws == null || ws.isEmpty || _analyzeProcess != null) return;
    _hasNpx = await _probeNpx();
    if (!_hasNpx) {
      _status = GitNexusStatus.noNode;
      _appendAnalyze(
        'Node.js / npx was not found on PATH.\n'
        'Install Node.js from https://nodejs.org/ and restart Lumen.',
      );
      notifyListeners();
      return;
    }

    _status = GitNexusStatus.running;
    _lastRunAt = DateTime.now();
    _lastExitCode = null;
    _analyzeOutput = '';
    notifyListeners();

    try {
      await _ensureGitRepo(ws);
      final args = ['gitnexus', 'analyze', if (force) '--force'];
      _appendAnalyze('> npx ${args.join(' ')}\n');
      final process = await Process.start(
        'npx',
        args,
        workingDirectory: ws,
        runInShell: true,
      );
      _analyzeProcess = process;
      notifyListeners();

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendAnalyze);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendAnalyze);

      final code = await process.exitCode;
      _analyzeProcess = null;
      _lastExitCode = code;
      _status = code == 0 ? GitNexusStatus.indexed : GitNexusStatus.failed;
      notifyListeners();
      if (code == 0 && _autoWikiAfterAnalyze && _wikiProcess == null) {
        unawaited(generateWiki());
      }
    } catch (e) {
      _analyzeProcess = null;
      _lastExitCode = -1;
      _status = GitNexusStatus.failed;
      _appendAnalyze('\nFailed to launch GitNexus: $e\n');
      notifyListeners();
    }
  }

  Future<void> stop() async {
    final proc = _analyzeProcess;
    if (proc == null) return;
    _appendAnalyze('\n> stop requested\n');
    proc.kill();
    _analyzeProcess = null;
    _status = GitNexusStatus.failed;
    notifyListeners();
  }

  Future<void> clean() async {
    final ws = _workspacePath;
    if (ws == null || ws.isEmpty || _analyzeProcess != null) return;
    try {
      final dir = Directory(p.join(ws, '.gitnexus'));
      if (await dir.exists()) await dir.delete(recursive: true);
      _appendAnalyze('\nDeleted .gitnexus index.\n');
      await refreshStatus();
    } catch (e) {
      _status = GitNexusStatus.failed;
      _appendAnalyze('\nFailed to clean GitNexus index: $e\n');
      notifyListeners();
    }
  }

  // ── wiki ─────────────────────────────────────────────────────────
  Future<void> generateWiki({String? model, bool force = false}) async {
    if (!_enabled) return;
    final ws = _workspacePath;
    if (ws == null || ws.isEmpty || _wikiProcess != null) return;
    _hasNpx = await _probeNpx();
    if (!_hasNpx) {
      _wikiStatus = GitNexusWikiStatus.failed;
      _appendWiki(
        'Node.js / npx was not found on PATH.\n'
        'Install Node.js from https://nodejs.org/ and restart Lumen.',
      );
      notifyListeners();
      return;
    }

    _wikiStatus = GitNexusWikiStatus.running;
    _lastWikiAt = DateTime.now();
    _wikiExitCode = null;
    _wikiOutput = '';
    notifyListeners();

    try {
      await _ensureGitRepo(ws);
      final effectiveModel = (model ?? _wikiModel).trim();
      final args = [
        'gitnexus',
        'wiki',
        if (force) '--force',
        if (effectiveModel.isNotEmpty) ...['--model', effectiveModel],
      ];
      _appendWiki('> npx ${args.join(' ')}\n');
      final process = await Process.start(
        'npx',
        args,
        workingDirectory: ws,
        runInShell: true,
      );
      _wikiProcess = process;
      notifyListeners();

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendWiki);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendWiki);

      final code = await process.exitCode;
      _wikiProcess = null;
      _wikiExitCode = code;
      _wikiStatus = code == 0
          ? GitNexusWikiStatus.generated
          : GitNexusWikiStatus.failed;
      notifyListeners();
    } catch (e) {
      _wikiProcess = null;
      _wikiExitCode = -1;
      _wikiStatus = GitNexusWikiStatus.failed;
      _appendWiki('\nFailed to launch GitNexus wiki: $e\n');
      notifyListeners();
    }
  }

  Future<void> stopWiki() async {
    final proc = _wikiProcess;
    if (proc == null) return;
    _appendWiki('\n> stop requested\n');
    proc.kill();
    _wikiProcess = null;
    _wikiStatus = GitNexusWikiStatus.failed;
    notifyListeners();
  }

  // ── serve daemon (adoptable) ──────────────────────────────────────
  /// Toggle target — flips the daemon to the requested state. Used by
  /// a switch in Settings so the on/off semantics are explicit.
  Future<void> setServeRunning(bool wanted) async {
    if (wanted) {
      await startServe();
    } else {
      await stopServe();
    }
  }

  Future<void> startServe() async {
    if (!_enabled) return;
    if (_serveProcess != null || _serveStartInFlight) return;

    // Adoption-first: if anything already serves the port, we attach
    // to it instead of trying to spawn a duplicate that would fail
    // with EADDRINUSE. Probe is cheap (sub-second) and handles the
    // common case where another Lumen window — or a previous
    // session's orphan — is already up.
    if (await _probeServe()) {
      if (_serveOwnership != DaemonOwnership.adopted) {
        _serveOwnership = DaemonOwnership.adopted;
        _appendServe(
          '> attached to existing GitNexus server on '
          '127.0.0.1:$kGitNexusServePort (started by another window '
          'or external process)\n',
        );
        notifyListeners();
      }
      return;
    }

    _hasNpx = await _probeNpx();
    if (!_hasNpx) {
      _appendServe(
        'Node.js / npx was not found on PATH. Install Node.js '
        'from https://nodejs.org/ and restart Lumen.\n',
      );
      notifyListeners();
      return;
    }
    _serveStartInFlight = true;
    _serveExitCode = null;
    _appendServe('> npx gitnexus serve\n');
    notifyListeners();
    try {
      final process = await Process.start(
        'npx',
        const ['gitnexus', 'serve'],
        // Working dir is irrelevant — gitnexus serves the global
        // registry, not the cwd. We pass the workspace anyway so
        // npx resolves consistently with analyze. Null is fine when
        // no workspace is open.
        workingDirectory: _workspacePath,
        runInShell: true,
      );
      _serveProcess = process;
      _serveOwnership = DaemonOwnership.owned;
      _serveStartInFlight = false;
      notifyListeners();

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendServe);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendServe);

      // Daemons run forever — don't await exitCode here, just
      // observe it in the background so we can flip ownership back
      // when the process dies (crash, user kills it via Task
      // Manager, etc.).
      unawaited(
        process.exitCode.then((code) {
          if (_serveProcess == process) {
            _serveProcess = null;
            _serveOwnership = DaemonOwnership.none;
          }
          _serveExitCode = code;
          _appendServe('\n> serve exited with code $code\n');
          notifyListeners();
          // Re-probe — maybe another window's serve is now what's
          // serving and we should adopt it instead of staying off.
          scheduleMicrotask(_probeServeAndUpdate);
        }),
      );
    } catch (e) {
      _serveProcess = null;
      _serveOwnership = DaemonOwnership.none;
      _serveStartInFlight = false;
      _appendServe('\nFailed to launch gitnexus serve: $e\n');
      // Spawn failed — usually port-in-use by something we couldn't
      // talk to in the probe (e.g. hung gitnexus, unrelated app).
      // Surface PID + process name so the user can act on it.
      final blocker = await _findPidByPort(kGitNexusServePort);
      if (blocker.pid != null) {
        _appendServe(
          'Port $kGitNexusServePort is in use by '
          '${blocker.processName ?? "unknown process"} '
          '(PID ${blocker.pid}). Stop that process and try again.\n',
        );
      }
      notifyListeners();
    }
  }

  Future<void> stopServe() async {
    // Owned: kill our process. The exitCode listener will flip
    // ownership and re-probe so the UI re-syncs naturally if some
    // other window's serve was also up.
    final proc = _serveProcess;
    if (proc != null) {
      _appendServe('\n> stop requested (owned by this window)\n');
      proc.kill();
      _serveProcess = null;
      _serveOwnership = DaemonOwnership.none;
      _serveStartInFlight = false;
      notifyListeners();
      return;
    }

    // Adopted: we don't have the process handle, so we ask the OS
    // to kill it by PID-by-port. This is intentionally a hammer —
    // it stops the GitNexus server for every Lumen window AND any
    // gitnexus.vercel.app web UI session on this machine, because
    // the server is machine-wide. The UI labels the toggle
    // accordingly so the user opts into that with eyes open.
    if (_serveOwnership == DaemonOwnership.adopted) {
      final blocker = await _findPidByPort(kGitNexusServePort);
      if (blocker.pid == null) {
        _appendServe(
          '\n> stop requested but could not locate the serve PID '
          '(is it actually running?)\n',
        );
        _serveOwnership = DaemonOwnership.none;
        notifyListeners();
        unawaited(_probeServeAndUpdate());
        return;
      }
      _appendServe(
        '\n> stopping machine-wide gitnexus serve '
        '(PID ${blocker.pid}'
        '${blocker.processName != null ? ", ${blocker.processName}" : ""})\n',
      );
      final killed = await _killPid(blocker.pid!);
      if (killed) {
        _serveOwnership = DaemonOwnership.none;
      } else {
        _appendServe(
          '> taskkill exit was non-zero — the server may still '
          'be running. You may need to stop it manually.\n',
        );
      }
      notifyListeners();
      // Re-probe shortly so the icon catches up either way.
      scheduleMicrotask(_probeServeAndUpdate);
      return;
    }

    _serveStartInFlight = false;
  }

  // ── mcp daemon (per-window, not adoptable) ────────────────────────
  Future<void> setMcpRunning(bool wanted) async {
    if (wanted) {
      await startMcp();
    } else {
      await stopMcp();
    }
  }

  Future<void> startMcp() async {
    if (!_enabled) return;
    if (_mcpProcess != null || _mcpStartInFlight) return;
    _hasNpx = await _probeNpx();
    if (!_hasNpx) {
      _appendMcp(
        'Node.js / npx was not found on PATH. Install Node.js '
        'from https://nodejs.org/ and restart Lumen.\n',
      );
      notifyListeners();
      return;
    }
    _mcpStartInFlight = true;
    _mcpOutput = '';
    _mcpExitCode = null;
    _appendMcp('> npx gitnexus mcp\n');
    notifyListeners();
    try {
      final process = await Process.start(
        'npx',
        const ['gitnexus', 'mcp'],
        workingDirectory: _workspacePath,
        runInShell: true,
      );
      _mcpProcess = process;
      _mcpStartInFlight = false;
      notifyListeners();

      process.stdout
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendMcp);
      process.stderr
          .transform(const Utf8Decoder(allowMalformed: true))
          .listen(_appendMcp);

      unawaited(
        process.exitCode.then((code) {
          if (_mcpProcess == process) {
            _mcpProcess = null;
          }
          _mcpExitCode = code;
          _appendMcp('\n> mcp exited with code $code\n');
          notifyListeners();
        }),
      );
    } catch (e) {
      _mcpProcess = null;
      _mcpStartInFlight = false;
      _appendMcp('\nFailed to launch gitnexus mcp: $e\n');
      notifyListeners();
    }
  }

  Future<void> stopMcp() async {
    final proc = _mcpProcess;
    if (proc == null) {
      _mcpStartInFlight = false;
      return;
    }
    _appendMcp('\n> stop requested\n');
    proc.kill();
    _mcpProcess = null;
    _mcpStartInFlight = false;
    notifyListeners();
  }

  // ── installed-context-files probe ─────────────────────────────────
  List<GitNexusInstalledFile> installedFiles() {
    final ws = _workspacePath;
    if (ws == null || ws.isEmpty) return const [];
    final entries = <({String label, String path})>[
      (label: 'Knowledge graph index', path: p.join(ws, '.gitnexus')),
      (label: 'Workspace rules', path: p.join(ws, '.lumen', 'rules.md')),
      (label: 'Workspace tools', path: p.join(ws, '.lumen', 'tools')),
      (
        label: 'Agent knowledgebase',
        path: p.join(ws, '.agents', 'knowledgebase.md'),
      ),
      (label: 'GitNexus wiki', path: p.join(ws, '.gitnexus', 'wiki')),
      (label: 'Claude context', path: p.join(ws, 'CLAUDE.md')),
      (label: 'Agent context', path: p.join(ws, 'AGENTS.md')),
    ];
    return entries
        .map(
          (e) => GitNexusInstalledFile(
            label: e.label,
            path: e.path,
            exists:
                FileSystemEntity.typeSync(e.path) !=
                FileSystemEntityType.notFound,
          ),
        )
        .toList(growable: false);
  }

  // ── adoption probe + os helpers ───────────────────────────────────

  /// Re-probes the serve port and updates ownership/state if it
  /// changed. Owned state is never overridden by probe results — we
  /// trust [Process.exitCode] to flip ownership on death so a
  /// transient probe failure doesn't cause flapping.
  Future<void> _probeServeAndUpdate() async {
    if (!_enabled) return;
    if (_probeInFlight) return;
    if (_serveProcess != null) {
      return; // owned: probe can't tell us anything new
    }
    _probeInFlight = true;
    try {
      final alive = await _probeServe();
      final wasOwnership = _serveOwnership;
      if (alive && _serveOwnership == DaemonOwnership.none) {
        _serveOwnership = DaemonOwnership.adopted;
        _appendServe(
          '> detected external GitNexus server on '
          '127.0.0.1:$kGitNexusServePort, attached\n',
        );
      } else if (!alive && _serveOwnership == DaemonOwnership.adopted) {
        _serveOwnership = DaemonOwnership.none;
        _appendServe('> external GitNexus server is no longer reachable\n');
      }
      if (wasOwnership != _serveOwnership) {
        notifyListeners();
      }
    } finally {
      _probeInFlight = false;
    }
  }

  /// HTTP `GET /api/repos` against [kGitNexusServePort], racing IPv4
  /// and IPv6. gitnexus on Windows often binds only `::1` (Node
  /// `app.listen` quirk), so we have to try both — a single
  /// `127.0.0.1` probe would falsely report "not running" against a
  /// healthy IPv6-only daemon.
  Future<bool> _probeServe([int port = kGitNexusServePort]) async {
    final results = await Future.wait([
      _probeOne('127.0.0.1', port),
      _probeOne('::1', port),
    ]);
    return results.any((r) => r);
  }

  Future<bool> _probeOne(String host, int port) async {
    HttpClient? client;
    try {
      client = HttpClient();
      client.connectionTimeout = _kProbeTimeout;
      final req = await client
          .getUrl(
            Uri(scheme: 'http', host: host, port: port, path: '/api/repos'),
          )
          .timeout(_kProbeTimeout);
      final resp = await req.close().timeout(_kProbeTimeout);
      await resp.drain<void>();
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      client?.close(force: true);
    }
  }

  /// PID-by-port lookup using `netstat -ano` on Windows. Returns
  /// `(null, null)` on non-Windows, which is fine because Lumen is a
  /// Windows desktop app — adoption-stop on macOS/Linux can be added
  /// when the build targets them.
  Future<({int? pid, String? processName})> _findPidByPort(int port) async {
    if (!Platform.isWindows) {
      return (pid: null, processName: null);
    }
    try {
      final result = await Process.run('netstat', const [
        '-ano',
        '-p',
        'TCP',
      ], runInShell: true).timeout(const Duration(seconds: 5));
      for (final line in const LineSplitter().convert(
        result.stdout.toString(),
      )) {
        final trimmed = line.trim();
        if (!trimmed.startsWith('TCP')) continue;
        if (!trimmed.contains('LISTENING')) continue;
        final parts = trimmed.split(RegExp(r'\s+'));
        if (parts.length < 5) continue;
        final localAddr = parts[1];
        if (!localAddr.endsWith(':$port')) continue;
        final pid = int.tryParse(parts.last);
        if (pid == null) continue;
        String? name;
        try {
          final proc = await Process.run('tasklist', [
            '/FI',
            'PID eq $pid',
            '/FO',
            'CSV',
            '/NH',
          ], runInShell: true).timeout(const Duration(seconds: 5));
          final m = RegExp(
            r'^"([^"]+)"',
          ).firstMatch(proc.stdout.toString().trim());
          name = m?.group(1);
        } catch (_) {
          // tasklist is best-effort — PID alone is enough for the
          // user to act on.
        }
        return (pid: pid, processName: name);
      }
    } catch (_) {
      // netstat failure isn't worth surfacing — caller already has a
      // generic "couldn't locate PID" message path.
    }
    return (pid: null, processName: null);
  }

  Future<bool> _killPid(int pid) async {
    if (!Platform.isWindows) return false;
    try {
      final result = await Process.run('taskkill', [
        '/F',
        '/PID',
        '$pid',
      ], runInShell: true).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ── helpers ───────────────────────────────────────────────────────
  Future<bool> _probeNpx() async {
    try {
      final result = await Process.run('npx', const [
        '--version',
      ], runInShell: true).timeout(const Duration(seconds: 8));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _ensureGitRepo(String ws) async {
    if (await Directory(p.join(ws, '.git')).exists()) return;
    final probe = await Process.run(
      'git',
      const ['rev-parse', '--is-inside-work-tree'],
      workingDirectory: ws,
      runInShell: true,
    );
    if (probe.exitCode == 0 && probe.stdout.toString().trim() == 'true') {
      return;
    }
    _appendAnalyze('> git init\n');
    final init = await Process.run(
      'git',
      const ['init'],
      workingDirectory: ws,
      runInShell: true,
    );
    _appendAnalyze(init.stdout.toString());
    _appendAnalyze(init.stderr.toString());
    if (init.exitCode != 0) {
      throw StateError('git init failed with exit ${init.exitCode}');
    }
  }

  void _appendAnalyze(String chunk) {
    if (chunk.isEmpty) return;
    _analyzeOutput += chunk;
    if (_analyzeOutput.length > 16000) {
      _analyzeOutput = _analyzeOutput.substring(_analyzeOutput.length - 16000);
    }
    notifyListeners();
  }

  void _appendWiki(String chunk) {
    if (chunk.isEmpty) return;
    _wikiOutput += chunk;
    if (_wikiOutput.length > 16000) {
      _wikiOutput = _wikiOutput.substring(_wikiOutput.length - 16000);
    }
    notifyListeners();
  }

  void _appendServe(String chunk) {
    if (chunk.isEmpty) return;
    _serveOutput += chunk;
    if (_serveOutput.length > 16000) {
      _serveOutput = _serveOutput.substring(_serveOutput.length - 16000);
    }
    notifyListeners();
  }

  void _appendMcp(String chunk) {
    if (chunk.isEmpty) return;
    _mcpOutput += chunk;
    if (_mcpOutput.length > 16000) {
      _mcpOutput = _mcpOutput.substring(_mcpOutput.length - 16000);
    }
    notifyListeners();
  }

  static String _tail(String text, int max) {
    if (text.length <= max) return text;
    return '...\n${text.substring(text.length - max)}';
  }

  @override
  void dispose() {
    _probeTimer?.cancel();
    // Only kill the workspace-scoped one-shot and the per-window
    // mcp pipe. The serve daemon is intentionally left running so it
    // can be adopted by the next Lumen window — killing it here is
    // exactly what created the orphan/port-conflict UX bug this
    // service was rewritten to avoid. Users can stop it explicitly
    // via the Settings toggle when they actually mean to.
    _analyzeProcess?.kill();
    _wikiProcess?.kill();
    _mcpProcess?.kill();
    super.dispose();
  }
}

class GitNexusInstalledFile {
  final String label;
  final String path;
  final bool exists;
  const GitNexusInstalledFile({
    required this.label,
    required this.path,
    required this.exists,
  });
}
