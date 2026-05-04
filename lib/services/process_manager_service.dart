import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One row in the process manager table.
class ProcessInfo {
  final int pid;
  final int? ppid;
  final String name;
  final String? executablePath;
  final String? commandLine;
  final int? memoryBytes;

  ProcessInfo({
    required this.pid,
    required this.name,
    this.ppid,
    this.executablePath,
    this.commandLine,
    this.memoryBytes,
  });

  /// Lower-case haystack used by the search box and preset filters.
  /// Built lazily — process listings can be ~500 entries on a busy
  /// Windows box and we re-filter on every keystroke.
  late final String _haystack = [
    name,
    executablePath ?? '',
    commandLine ?? '',
  ].join(' ').toLowerCase();

  String get haystack => _haystack;
}

/// Result of a kill attempt — kept structured so the UI can decide
/// between toast/error inline. Stderr from `taskkill` / `kill` is
/// surfaced verbatim because the OS reasons (access denied, no such
/// process, etc.) are usually the actually-useful debug signal.
class KillResult {
  final int pid;
  final bool ok;
  final String? message;
  const KillResult({required this.pid, required this.ok, this.message});
}

/// Thin wrapper around the OS process tools.
///
/// On Windows we shell out to PowerShell + `Get-CimInstance Win32_Process`
/// because that's the only built-in that gives the parent-PID and
/// CommandLine columns we need for the workspace / Lumen-spawned
/// filters. `tasklist` is faster but doesn't expose either field.
///
/// On Unix we use `ps` with explicit columns. macOS and Linux differ
/// slightly on `ps` flags but the BSD-style `-axww -o pid=,ppid=,...`
/// invocation works on both.
///
/// Both backends return a fully-populated `List<ProcessInfo>`. CPU%
/// is intentionally skipped — sampling it requires two snapshots and
/// per-instance perf counters on Windows, which would push the
/// listing latency past 2s.
class ProcessManagerService {
  ProcessManagerService._();

  /// Snapshot every process visible to the current user.
  static Future<List<ProcessInfo>> list() async {
    if (Platform.isWindows) {
      return _listWindows();
    }
    return _listUnix();
  }

  /// Best-effort kill. On Windows uses `taskkill /PID <pid>` (or
  /// `/F` for force); on Unix uses SIGTERM → SIGKILL.
  ///
  /// Returns a structured result instead of throwing so the caller
  /// can render the OS reason inline (`Access is denied`, etc.).
  static Future<KillResult> kill(int pid, {bool force = true}) async {
    try {
      if (Platform.isWindows) {
        final args = <String>['/PID', '$pid', if (force) '/F'];
        final r = await Process.run('taskkill', args, runInShell: false);
        if (r.exitCode == 0) {
          return KillResult(pid: pid, ok: true);
        }
        final msg = (r.stderr is String && (r.stderr as String).isNotEmpty)
            ? (r.stderr as String).trim()
            : (r.stdout is String ? (r.stdout as String).trim() : '');
        return KillResult(pid: pid, ok: false, message: msg.isEmpty ? 'taskkill exit ${r.exitCode}' : msg);
      } else {
        final signal = force ? '-9' : '-15';
        final r = await Process.run('kill', [signal, '$pid']);
        if (r.exitCode == 0) {
          return KillResult(pid: pid, ok: true);
        }
        final msg = (r.stderr as String?)?.trim() ?? '';
        return KillResult(pid: pid, ok: false, message: msg.isEmpty ? 'kill exit ${r.exitCode}' : msg);
      }
    } catch (e) {
      return KillResult(pid: pid, ok: false, message: '$e');
    }
  }

  // ── Windows ──────────────────────────────────────────────────────────

  // Pinning OutputEncoding to UTF-8 inside the script body is
  // required: PowerShell otherwise emits whatever the console
  // codepage is (often cp1252 on en-US, cp936 on zh-CN), and Dart
  // decoding that as UTF-8 corrupts non-ASCII paths/window titles.
  // `ConvertTo-Json -Depth 3` keeps the payload structurally simple
  // — depth 1 cuts off nested PSObject metadata we don't want anyway.
  static const String _winScript = r'''
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'SilentlyContinue'
Get-CimInstance Win32_Process |
  Select-Object ProcessId, ParentProcessId, Name, CommandLine, ExecutablePath, WorkingSetSize |
  ConvertTo-Json -Compress -Depth 3
''';

  static Future<List<ProcessInfo>> _listWindows() async {
    final r = await Process.run(
      'powershell.exe',
      const [
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        _winScript,
      ],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
      runInShell: false,
    );
    if (r.exitCode != 0) {
      throw ProcessException(
        'powershell.exe',
        const ['Get-CimInstance Win32_Process'],
        (r.stderr as String?) ?? 'powershell exit ${r.exitCode}',
        r.exitCode,
      );
    }
    final raw = (r.stdout as String).trim();
    if (raw.isEmpty) return const [];
    final decoded = jsonDecode(raw);
    // ConvertTo-Json emits a single object when the result has 1
    // element; coerce to a list either way.
    final entries = decoded is List ? decoded : [decoded];
    final out = <ProcessInfo>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final pid = (e['ProcessId'] as num?)?.toInt();
      if (pid == null) continue;
      out.add(
        ProcessInfo(
          pid: pid,
          ppid: (e['ParentProcessId'] as num?)?.toInt(),
          name: (e['Name'] as String?) ?? '?',
          executablePath: e['ExecutablePath'] as String?,
          commandLine: e['CommandLine'] as String?,
          memoryBytes: (e['WorkingSetSize'] as num?)?.toInt(),
        ),
      );
    }
    return out;
  }

  // ── Unix (macOS / Linux) ─────────────────────────────────────────────

  // `-axww` is the BSD flavor that works on macOS *and* Linux
  // (procps accepts BSD-style without `-` too, but macOS's `ps`
  // requires the leading dash). The trailing `=` on each `-o`
  // column suppresses the header row, giving us a clean
  // whitespace-split format.
  static Future<List<ProcessInfo>> _listUnix() async {
    final r = await Process.run(
      'ps',
      const ['-axww', '-o', 'pid=,ppid=,rss=,comm=,args='],
      stdoutEncoding: utf8,
    );
    if (r.exitCode != 0) {
      throw ProcessException(
        'ps',
        const ['-axww', '-o', 'pid=,ppid=,rss=,comm=,args='],
        (r.stderr as String?) ?? 'ps exit ${r.exitCode}',
        r.exitCode,
      );
    }
    final out = <ProcessInfo>[];
    for (final line in const LineSplitter().convert(r.stdout as String)) {
      final trimmed = line.trimLeft();
      if (trimmed.isEmpty) continue;
      // Hand-roll the split: pid/ppid/rss are the first three
      // whitespace-separated tokens, then comm is one token, then
      // args is "the rest of the line" (which may itself contain
      // arbitrary whitespace).
      final parts = trimmed.split(RegExp(r'\s+'));
      if (parts.length < 5) continue;
      final pid = int.tryParse(parts[0]);
      final ppid = int.tryParse(parts[1]);
      final rss = int.tryParse(parts[2]); // KB on Linux, KB on macOS
      final comm = parts[3];
      // Re-join the remainder as args so binaries with spaces in
      // their path don't get their command line shredded.
      final argsIdx = trimmed.indexOf(comm) + comm.length;
      final args = argsIdx < trimmed.length
          ? trimmed.substring(argsIdx).trimLeft()
          : '';
      if (pid == null) continue;
      out.add(
        ProcessInfo(
          pid: pid,
          ppid: ppid,
          name: comm.split('/').last,
          executablePath: comm,
          commandLine: args.isEmpty ? null : args,
          memoryBytes: rss != null ? rss * 1024 : null,
        ),
      );
    }
    return out;
  }
}
