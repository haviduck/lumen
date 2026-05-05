import 'dart:io';

import 'package:flutter/foundation.dart';

/// One executable shell candidate.
class ShellSpec {
  /// Stable key, persisted in prefs.
  final String id;

  /// Display name (e.g. "PowerShell 7 (pwsh)").
  final String label;

  /// What we hand to the PTY/Process.start. On Windows this may be
  /// `cmd.exe` if the underlying shell lives at a path that contains
  /// spaces — see [ShellDiscovery] for why.
  final String executable;

  /// Args passed to [executable]. May include a quoted path to the real
  /// shell when [executable] is a launcher (e.g. `cmd.exe /c`).
  final List<String> startupArgs;

  const ShellSpec({
    required this.id,
    required this.label,
    required this.executable,
    this.startupArgs = const [],
  });

  ShellSpec copyWith({
    String? executable,
    List<String>? startupArgs,
  }) {
    return ShellSpec(
      id: id,
      label: label,
      executable: executable ?? this.executable,
      startupArgs: startupArgs ?? this.startupArgs,
    );
  }

  /// Build the full argument vector for executing a single one-shot
  /// command in this shell — e.g. agent-spawned `RUN_CMD` invocations
  /// that should still surface as a real terminal tab when long-running.
  ///
  /// We append the shell's "execute then exit" flag plus the command
  /// to [startupArgs] so any cmd.exe-wrapping (see [_wrapWithCmd]) or
  /// `-NoLogo`/`-NoProfile` flags stay in front. The cmd.exe wrapper
  /// is transparent: `cmd.exe /c "<real-shell>" -NoLogo -Command <cmd>`
  /// gets reparsed by cmd as `<real-shell> -NoLogo -Command <cmd>`,
  /// which is exactly the invocation we'd run if there were no spaces
  /// in the path.
  List<String> commandArgs(String command) {
    switch (id) {
      case 'pwsh':
      case 'powershell':
        return [...startupArgs, '-Command', command];
      case 'cmd':
        // Plain cmd: `/c <cmd>` is the canonical one-shot form.
        // startupArgs is empty for the unwrapped case.
        return [...startupArgs, '/c', command];
      case 'zsh':
      case 'bash':
      case 'sh':
        return [...startupArgs, '-c', command];
      default:
        // POSIX-ish convention; if a future shell needs different
        // flags this default keeps it from silently misfiring —
        // it'll surface as a startup error in the agent terminal
        // and the user can pick a different shell.
        return [...startupArgs, '-c', command];
    }
  }
}

/// Probes the host for available shells. Order = priority.
///
/// Windows has three sharp edges this class smooths over:
///
/// 1. **App Execution Alias stubs.** A bare `pwsh.exe` on PATH frequently
///    resolves to a 0-byte stub under
///    `~\AppData\Local\Microsoft\WindowsApps\` that re-launches the MSIX
///    package. Inside flutter_pty's ConPTY this self-invocation breaks
///    with "Processing -File '…pwsh.exe' failed because the file does not
///    have a '.ps1' extension". We therefore reject any 0-byte file and
///    any path under `WindowsApps\`.
///
/// 2. **Path-with-space + `flutter_pty` 0.4.2.** flutter_pty's
///    `build_command` (src/flutter_pty_win.c) concatenates `executable`
///    and `args` with raw spaces and passes the result as `lpCommandLine`
///    with `lpApplicationName=NULL` to `CreateProcessW`. Windows then
///    treats whitespace in the exe path as an argument separator, so
///    `C:\Program Files\PowerShell\7\pwsh.exe -NoLogo` is parsed as
///    `argv = ["C:\\Program", "Files\\PowerShell\\7\\pwsh.exe", "-NoLogo"]`.
///    pwsh sees the second token as a `-File` argument and rejects it
///    because it isn't a `.ps1`. We work around this by rewriting any
///    space-containing executable into
///    `C:\Windows\System32\cmd.exe /c "<real-path>" <args>` — `cmd.exe`
///    is a real PE binary at a no-space path, so `CreateProcessW` parses
///    it cleanly, and `cmd.exe /c` passes the quoted real path through
///    to its child intact.
///
/// 3. **PowerShell 5.1 `8009001d`.** On a small fraction of machines with
///    a damaged .NET Framework, `powershell.exe` (5.1) fails to load its
///    managed runtime under ConPTY. [TerminalSession] watches the early
///    output for that signature and auto-falls-back to the next
///    candidate.
class ShellDiscovery {
  ShellDiscovery._();

  /// Always present on every modern Windows install. We rely on this
  /// being at a no-space path for the cmd.exe-wrapping workaround.
  static const String _windowsCmdPath = r'C:\Windows\System32\cmd.exe';

  static const Map<String, List<String>> _windowsFallbackPaths = {
    'pwsh.exe': [
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      r'C:\Program Files (x86)\PowerShell\7\pwsh.exe',
    ],
    'powershell.exe': [
      r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
      r'C:\Windows\SysWOW64\WindowsPowerShell\v1.0\powershell.exe',
    ],
    'cmd.exe': [
      _windowsCmdPath,
      r'C:\Windows\SysWOW64\cmd.exe',
    ],
  };

  static const List<ShellSpec> _windowsCandidates = [
    ShellSpec(
      id: 'pwsh',
      label: 'PowerShell 7 (pwsh)',
      executable: 'pwsh.exe',
      startupArgs: ['-NoLogo'],
    ),
    ShellSpec(
      id: 'powershell',
      label: 'Windows PowerShell',
      executable: 'powershell.exe',
      startupArgs: ['-NoLogo', '-NoProfile'],
    ),
    ShellSpec(
      id: 'cmd',
      label: 'Command Prompt',
      executable: 'cmd.exe',
      startupArgs: [],
    ),
  ];

  static const List<ShellSpec> _unixCandidates = [
    ShellSpec(id: 'zsh', label: 'Zsh', executable: 'zsh'),
    ShellSpec(id: 'bash', label: 'Bash', executable: 'bash'),
    ShellSpec(id: 'sh', label: 'POSIX sh', executable: 'sh'),
  ];

  /// All resolvable shells, in priority order.
  static Future<List<ShellSpec>> available() async {
    final candidates =
        Platform.isWindows ? _windowsCandidates : _unixCandidates;
    final found = <ShellSpec>[];
    for (final c in candidates) {
      final spec = await _resolveSpec(c);
      if (spec != null) found.add(spec);
    }
    return found;
  }

  /// Resolve a single candidate by stable id (or `null` if missing).
  static Future<ShellSpec?> byId(String id) async {
    final list = Platform.isWindows ? _windowsCandidates : _unixCandidates;
    for (final c in list) {
      if (c.id != id) continue;
      return _resolveSpec(c);
    }
    return null;
  }

  /// Best resolvable shell on this host. Falls back to a never-resolved
  /// `cmd.exe`/`sh` placeholder so callers always get *something*.
  static Future<ShellSpec> bestAvailable() async {
    final list = await available();
    if (list.isNotEmpty) return list.first;
    return Platform.isWindows
        ? _windowsCandidates.last
        : _unixCandidates.last;
  }

  /// Heuristic: does the recent terminal output look like a fatal startup
  /// failure that warrants auto-switching shells? Covers PS 5.1's
  /// `8009001d` managed-runtime failure and a couple of pwsh self-invoke
  /// errors that historically appeared when the WindowsApps stub was
  /// running under ConPTY.
  static bool looksLikeFatalShellError(String output) {
    final lower = output.toLowerCase();
    if (lower.contains('8009001d')) return true;
    if (lower.contains('loading managed windows powershell failed')) return true;
    if (lower.contains("the term '' is not recognized")) return true;
    // pwsh complaining that it was handed a non-.ps1 file — almost
    // always means the WindowsApps stub or an unquoted exe path got
    // forwarded to itself as a `-File` argument.
    if (lower.contains("does not have a '.ps1' extension")) return true;
    if (lower.contains('powershell.exe : ') &&
        lower.contains('managed') &&
        lower.contains('error')) {
      return true;
    }
    return false;
  }

  /// Resolve [base] to a launchable [ShellSpec] (with cmd.exe wrapping if
  /// the underlying path contains a space on Windows). Returns `null` if
  /// the executable can't be located.
  static Future<ShellSpec?> _resolveSpec(ShellSpec base) async {
    final resolved = await _resolveExecutable(base.executable);
    if (resolved == null) return null;
    if (Platform.isWindows && resolved.contains(' ')) {
      return _wrapWithCmd(base, resolved);
    }
    return base.copyWith(executable: resolved);
  }

  /// Rewrite a space-containing exe path into `cmd.exe /c "<exe>" <args>`.
  /// See class doc for the full reasoning. The wrapped spec retains the
  /// original `id`/`label`, so the UI still presents the underlying
  /// shell to the user — `cmd.exe` is just the launcher.
  static ShellSpec _wrapWithCmd(ShellSpec base, String resolvedPath) {
    return ShellSpec(
      id: base.id,
      label: base.label,
      executable: _windowsCmdPath,
      startupArgs: ['/c', '"$resolvedPath"', ...base.startupArgs],
    );
  }

  static Future<String?> _resolveExecutable(String exe) async {
    if (Platform.isWindows) {
      // 1. Hardcoded well-known install paths first. These bypass the
      //    Microsoft Store / WindowsApps execution-alias indirection.
      for (final path
          in _windowsFallbackPaths[exe.toLowerCase()] ?? const <String>[]) {
        if (await _isUsableExecutable(path)) return path;
      }

      // 2. PATH search, skipping App Execution Alias stubs and 0-byte
      //    files.
      final viaPath = await _whereResolveSkippingStubs(exe);
      if (viaPath != null) return viaPath;

      // 3. For pwsh specifically, query the MSIX package via plain
      //    Process.run (no PTY = no 8009001d) to find a Microsoft Store
      //    install. Version-proof.
      if (exe.toLowerCase() == 'pwsh.exe') {
        return _resolvePwshFromAppx();
      }

      return null;
    }

    try {
      final result = await Process.run('which', [exe], runInShell: false);
      if (result.exitCode == 0) {
        final out = (result.stdout as String).trim();
        if (out.isNotEmpty) {
          return out.split(RegExp(r'\r?\n')).first.trim();
        }
      }
    } catch (e) {
      debugPrint('shell-discovery probe failed for $exe: $e');
    }
    return null;
  }

  /// True if [path] points to a real, non-empty file we can launch.
  /// Specifically rejects 0-byte App Execution Alias stubs.
  static Future<bool> _isUsableExecutable(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return false;
      final stat = await file.stat();
      if (stat.size == 0) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Run `where <exe>` and return the first result that is not an App
  /// Execution Alias stub and is a real, non-empty binary.
  static Future<String?> _whereResolveSkippingStubs(String exe) async {
    try {
      final result = await Process.run('where', [exe], runInShell: false);
      if (result.exitCode != 0) return null;
      final raw = (result.stdout as String).trim();
      if (raw.isEmpty) return null;
      final candidates = raw
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty);
      for (final candidate in candidates) {
        if (_looksLikeAppExecutionAlias(candidate)) continue;
        if (await _isUsableExecutable(candidate)) return candidate;
      }
    } catch (e) {
      debugPrint('shell-discovery `where` probe failed for $exe: $e');
    }
    return null;
  }

  static bool _looksLikeAppExecutionAlias(String path) {
    final normalized = path.toLowerCase().replaceAll('/', r'\');
    return normalized.contains(r'\appdata\local\microsoft\windowsapps\');
  }

  /// Find a Microsoft Store MSIX install of pwsh by asking Windows
  /// PowerShell 5.1 for the AppX install location. PS 5.1 runs fine
  /// under `Process.run` even on machines where it crashes inside
  /// ConPTY, so this is safe to call as a fallback discovery step.
  static Future<String?> _resolvePwshFromAppx() async {
    try {
      final result = await Process.run(
        'powershell.exe',
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-AppxPackage -Name Microsoft.PowerShell '
              '-ErrorAction SilentlyContinue).InstallLocation',
        ],
        runInShell: false,
      );
      if (result.exitCode != 0) return null;
      final installDir = (result.stdout as String)
          .trim()
          .split(RegExp(r'\r?\n'))
          .map((s) => s.trim())
          .firstWhere((s) => s.isNotEmpty, orElse: () => '');
      if (installDir.isEmpty) return null;
      final pwshPath = '$installDir\\pwsh.exe';
      if (await _isUsableExecutable(pwshPath)) return pwshPath;
    } catch (e) {
      debugPrint('shell-discovery AppX probe failed: $e');
    }
    return null;
  }
}
