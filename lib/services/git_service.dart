import 'dart:io';

import 'package:path/path.dart' as p;

/// Thin wrapper around the `git` CLI. Uses `Process.run` (not
/// `Process.start`) so we always get the full stdout/stderr pair and never
/// leave a hung child process behind. Every method returns a record so
/// callers can render a status line without parsing exit codes themselves.
///
/// Git availability is not assumed — if the binary is missing on PATH the
/// `Process.run` calls throw `ProcessException`, which we surface as a
/// human-readable failure rather than crashing the scheduler.
class GitService {
  /// Cheap repo check: a `.git` directory at the workspace root covers the
  /// common case and avoids spawning a subprocess. Fall back to
  /// `git rev-parse --is-inside-work-tree` for sub-directories or worktrees
  /// where the marker isn't where we expect.
  Future<bool> isRepo(String workspacePath) async {
    if (workspacePath.isEmpty) return false;
    if (await Directory(p.join(workspacePath, '.git')).exists()) return true;
    if (await File(p.join(workspacePath, '.git')).exists()) return true;
    try {
      final r = await Process.run(
        'git',
        ['rev-parse', '--is-inside-work-tree'],
        workingDirectory: workspacePath,
        runInShell: false,
      );
      if (r.exitCode != 0) return false;
      return r.stdout.toString().trim() == 'true';
    } on ProcessException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Stage everything and commit. A clean tree (`nothing to commit`) is
  /// treated as a benign no-op so callers don't have to special-case it.
  Future<({bool ok, String message})> autoCommit(
    String workspacePath, {
    required String message,
  }) async {
    try {
      final addRes = await Process.run(
        'git',
        ['add', '-A'],
        workingDirectory: workspacePath,
        runInShell: false,
      );
      if (addRes.exitCode != 0) {
        final err = addRes.stderr.toString().trim();
        return (
          ok: false,
          message: err.isNotEmpty ? err : 'git add failed',
        );
      }

      final commitRes = await Process.run(
        'git',
        ['commit', '-m', message, '--allow-empty-message'],
        workingDirectory: workspacePath,
        runInShell: false,
      );
      if (commitRes.exitCode == 0) {
        return (ok: true, message: 'committed');
      }

      final combined =
          '${commitRes.stdout}\n${commitRes.stderr}'.toLowerCase();
      if (combined.contains('nothing to commit') ||
          combined.contains('no changes added to commit') ||
          combined.contains('working tree clean')) {
        return (ok: true, message: 'no changes');
      }

      final err = commitRes.stderr.toString().trim();
      final out = commitRes.stdout.toString().trim();
      return (
        ok: false,
        message: err.isNotEmpty ? err : (out.isNotEmpty ? out : 'git commit failed'),
      );
    } on ProcessException catch (e) {
      return (ok: false, message: 'git not available: ${e.message}');
    } catch (e) {
      return (ok: false, message: 'git error: $e');
    }
  }

  Future<({bool ok, String message})> push(String workspacePath) async {
    try {
      final r = await Process.run(
        'git',
        ['push'],
        workingDirectory: workspacePath,
        runInShell: false,
      );
      if (r.exitCode == 0) {
        return (ok: true, message: 'pushed');
      }
      final err = r.stderr.toString().trim();
      final out = r.stdout.toString().trim();
      return (
        ok: false,
        message: err.isNotEmpty ? err : (out.isNotEmpty ? out : 'git push failed'),
      );
    } on ProcessException catch (e) {
      return (ok: false, message: 'git not available: ${e.message}');
    } catch (e) {
      return (ok: false, message: 'git error: $e');
    }
  }

  Future<String> currentBranch(String workspacePath) async {
    try {
      final r = await Process.run(
        'git',
        ['rev-parse', '--abbrev-ref', 'HEAD'],
        workingDirectory: workspacePath,
        runInShell: false,
      );
      if (r.exitCode != 0) return '';
      return r.stdout.toString().trim();
    } on ProcessException {
      return '';
    } catch (_) {
      return '';
    }
  }
}
