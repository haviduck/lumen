import 'process_manager_service.dart';

/// Built-in preset filters surfaced as chip buttons in the process
/// manager. Each preset is a pure predicate over a `ProcessInfo`
/// plus a context bag (workspace path, lumen-spawned PID set) so
/// the UI never has to bake business logic into widget code.
enum ProcessFilterPreset {
  all,
  node,
  python,
  java,
  workspace,
  lumen,
}

/// Loose name-substring sets for the language-runtime presets.
/// Lower-case, matched against `ProcessInfo.haystack` (name + exe
/// path + command line concatenated) so matches survive whether
/// the binary is `node.exe`, `npm.cmd → node ...`, or just
/// `node` on Unix.
class _PresetMatchers {
  static const node = <String>[
    'node.exe',
    'node ',
    '\\node\\',
    '/node/',
    'npm',
    'pnpm',
    'yarn',
    'bun',
    'deno',
    'vite',
    'next',
    'esbuild',
    'tsc',
  ];
  static const python = <String>[
    'python.exe',
    'python3',
    'python ',
    'pythonw',
    'pip',
    'uvicorn',
    'gunicorn',
    'jupyter',
    'conda',
  ];
  static const java = <String>[
    'java.exe',
    'java ',
    '\\jdk\\',
    '/jdk/',
    'javaw',
    'gradle',
    'maven ',
    'mvn ',
    'kotlin',
  ];
}

/// Inputs that vary between callers — the workspace folder is
/// per-session, the lumen-tracked set is mutable. Pulled out so
/// the predicate function stays pure.
class ProcessFilterContext {
  final String? workspacePath;
  final Set<int> lumenSpawned;

  const ProcessFilterContext({
    required this.workspacePath,
    required this.lumenSpawned,
  });
}

class ProcessFilters {
  ProcessFilters._();

  /// Tests whether the given process matches the preset under the
  /// supplied context. Used both for filtering the table and for
  /// computing the per-chip count badge.
  static bool matches(
    ProcessFilterPreset preset,
    ProcessInfo p,
    ProcessFilterContext ctx,
  ) {
    switch (preset) {
      case ProcessFilterPreset.all:
        return true;
      case ProcessFilterPreset.node:
        return _anyContains(p.haystack, _PresetMatchers.node);
      case ProcessFilterPreset.python:
        return _anyContains(p.haystack, _PresetMatchers.python);
      case ProcessFilterPreset.java:
        return _anyContains(p.haystack, _PresetMatchers.java);
      case ProcessFilterPreset.workspace:
        final ws = ctx.workspacePath?.toLowerCase();
        if (ws == null || ws.isEmpty) return false;
        // Match either the raw form ("c:\users\...") or normalized
        // forward-slash form ("c:/users/...") — node tooling
        // routinely rewrites argv paths to forward slashes on
        // Windows, and ConvertTo-Json round-trips them as-is.
        final wsFwd = ws.replaceAll('\\', '/');
        final hay = p.haystack;
        return hay.contains(ws) || (wsFwd != ws && hay.contains(wsFwd));
      case ProcessFilterPreset.lumen:
        return ctx.lumenSpawned.contains(p.pid);
    }
  }

  static bool _anyContains(String haystack, List<String> needles) {
    for (final n in needles) {
      if (haystack.contains(n)) return true;
    }
    return false;
  }
}
