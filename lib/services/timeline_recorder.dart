import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'timeline_models.dart';
import 'timeline_service.dart';
import 'tool_registry.dart';

/// Bridge between [ToolExecutor] and [TimelineService].
///
/// **Why a separate class?** The executor doesn't know about the
/// timeline (and shouldn't — it's already busy parsing markers and
/// dispatching invocations); the timeline doesn't know about agent
/// tools (and shouldn't — agent ops are just one of several
/// origins). The recorder is the only place that maps "tool just ran
/// against file X" → "capture revision for file X with the right
/// metadata".
///
/// **Pre/post snapshots.** For every file-touching tool we:
///   1. `beforeTool(...)` — if the file already exists, ensure we
///      have a baseline so the diff has something to compare to.
///      If it doesn't exist (CREATE_FILE, MOVE_FILE destination),
///      we capture nothing pre — the post-snapshot will be a
///      `create` op with empty `prevHash`.
///   2. `afterTool(...)` — the executor has now written or deleted
///      the file. Hash + persist + emit a journal entry tagged
///      with the chat correlation IDs that were live on the
///      service before this pass.
///
/// **Cooperation with the FS watcher.** The recursive
/// `Directory.watch` in `AppState` will *also* fire on the tool's
/// write and call `recordWrite`. The timeline service deduplicates
/// based on `(rel, newHash)` — if our `afterTool` capture lands
/// first (and it usually does, because we run synchronously after
/// `tool.execute` returns), the FS-event path becomes a no-op.
/// Either way the entry gets the better metadata exactly once.
class TimelineRecorder {
  final TimelineService timeline;
  final String? workspaceDir;

  /// Tool ids whose execution touches files in a way the timeline
  /// must capture. Read-only / inspection tools are intentionally
  /// excluded (no point in tracking GIT_DIFF as if it changed
  /// something).
  static const Set<String> _captureToolIds = <String>{
    'create_file',
    'edit_file',
    'multi_edit',
    'edit_range',
    'append_file',
    'move_file',
    'copy_file',
    'delete_file',
  };

  TimelineRecorder({
    required this.timeline,
    required this.workspaceDir,
  });

  bool isCapturedTool(String toolId) => _captureToolIds.contains(toolId);

  /// Hook fired by [ToolExecutor] right before invoking a tool's
  /// `execute` body. Pre-snapshots any file the tool will modify so
  /// the post-snapshot has a diffable predecessor on disk, and
  /// **reserves** every target path against the FS watcher so the
  /// post-write race (FS notification arriving before our
  /// `recordWrite` claims the `_inFlight` slot) can't strip the
  /// `agentTool` origin from the captured entry. Reservations are
  /// released in `afterTool`'s `finally` so an exception in the tool
  /// body or our recordWrite doesn't permanently lock the path.
  Future<void> beforeTool(AgentTool tool, RegExpMatch match) async {
    if (!timeline.isReady) return;
    if (!isCapturedTool(tool.id)) return;
    final ws = workspaceDir;
    if (ws == null) return;
    try {
      final paths = _resolveTargets(tool.id, match, ws);
      // Reserve BEFORE ensuring the baseline — the FS watcher only
      // races us once the *agent's* write hits disk, which can't
      // happen until `tool.execute` runs after this. Reserving
      // first means any racing fsEvent capture for that path is
      // suppressed; the agent's afterTool capture wins.
      //
      // The baseline call itself goes through
      // `recordWrite(origin: baseline)` and would be blocked by
      // the same reservation guard if it weren't explicitly
      // exempted in `TimelineService.recordWrite`. Without that
      // exemption the baseline is silently dropped, the head stays
      // null, and the agent's post-edit recordWrite is mis-tagged
      // as `create` instead of `modify` — which makes the
      // per-message restore feature *delete* the file the user
      // only wanted to roll back. See `recordWrite` for the
      // explicit baseline exemption.
      for (final abs in [...paths.before, ...paths.after]) {
        timeline.reserveForAgent(abs);
      }
      for (final abs in paths.before) {
        await timeline.ensureBaseline(abs);
      }
    } catch (e) {
      debugPrint('TimelineRecorder.beforeTool failed: $e');
    }
  }

  /// Hook fired immediately after the tool's `execute` returns.
  /// Reads disk state and emits the journal entry. Errors are
  /// logged + swallowed because the timeline is a quality-of-life
  /// feature and a capture failure must never bubble up to the
  /// user as a tool error.
  Future<void> afterTool(
    AgentTool tool,
    RegExpMatch match,
    String result,
  ) async {
    if (!timeline.isReady) return;
    if (!isCapturedTool(tool.id)) return;
    final ws = workspaceDir;
    if (ws == null) return;
    final paths = _resolveTargets(tool.id, match, ws);
    final ok = !_isFailedToolResult(result);
    try {
      if (!ok) return;
      switch (tool.id) {
        case 'delete_file':
          {
            for (final abs in paths.before) {
              await timeline.recordDelete(
                abs,
                origin: TimelineOrigin.agentTool,
                tool: tool.id,
                note: 'Deleted via tool: ${tool.id}',
              );
            }
            break;
          }
        case 'move_file':
          {
            if (paths.before.length == 1 && paths.after.length == 1) {
              await timeline.recordRename(
                paths.before.first,
                paths.after.first,
                origin: TimelineOrigin.agentTool,
                tool: tool.id,
                note: 'Renamed via tool: ${tool.id}',
              );
            }
            break;
          }
        default:
          {
            for (final abs in paths.after) {
              await timeline.recordWrite(
                abs,
                origin: TimelineOrigin.agentTool,
                tool: tool.id,
                note: _noteForTool(tool.id),
              );
            }
          }
      }
    } catch (e) {
      debugPrint('TimelineRecorder.afterTool failed for ${tool.id}: $e');
    } finally {
      // Release every reserved path. Done in `finally` so a thrown
      // tool error or recordWrite hiccup never leaks a permanent
      // reservation that would block all future fsEvent captures
      // for that file. Idempotent — `releaseForAgent` no-ops on a
      // path that wasn't reserved.
      for (final abs in [...paths.before, ...paths.after]) {
        timeline.releaseForAgent(abs);
      }
    }
  }

  /// Convert a tool's regex match into the absolute paths we need to
  /// snapshot. The matrix mirrors `tool_registry.dart`'s declared
  /// pattern groups — keep this in sync if a tool's group order
  /// changes.
  _TargetPaths _resolveTargets(
    String toolId,
    RegExpMatch match,
    String workspaceDir,
  ) {
    String? rel;
    String? relTarget;
    switch (toolId) {
      case 'create_file':
      case 'edit_file':
      case 'multi_edit':
      case 'append_file':
      case 'delete_file':
        rel = match.groupCount >= 1 ? match.group(1)?.trim() : null;
        break;
      case 'edit_range':
        // Group 1 is `file:start-end`; the timeline only cares about
        // the file part. Strip the trailing `:N-M` if present so the
        // baseline / capture is keyed off the actual path.
        final raw = match.groupCount >= 1 ? match.group(1)?.trim() : null;
        if (raw != null) {
          final m = RegExp(r'^(.*):\d+-\d+$').firstMatch(raw);
          rel = m != null ? m.group(1)!.trim() : raw;
        }
        break;
      case 'move_file':
      case 'copy_file':
        rel = match.groupCount >= 1 ? match.group(1)?.trim() : null;
        relTarget = match.groupCount >= 2 ? match.group(2)?.trim() : null;
        break;
      default:
        rel = null;
    }

    final before = <String>[];
    final after = <String>[];

    // Source-side baseline. Only meaningful for tools that *modify*
    // (or remove) the source — copy doesn't, so the source isn't a
    // "before" target for the timeline.
    if (rel != null && rel.isNotEmpty && toolId != 'copy_file') {
      before.add(p.join(workspaceDir, rel));
    }

    if (toolId == 'move_file') {
      if (relTarget != null && relTarget.isNotEmpty) {
        after.add(p.join(workspaceDir, relTarget));
      }
    } else if (toolId == 'copy_file') {
      // For a copy, the destination is the only path that gains a
      // new revision. Two carve-outs:
      //   - We only track *file* copies. Directory copies can fan
      //     out to hundreds of created files; emitting a journal
      //     entry per file would drown the per-message restore UI
      //     and balloon the timeline DB. Falling back to "no
      //     entry" keeps the rest of the timeline honest — the
      //     user can still revert manually by deleting the new
      //     dir, which is the same shape the copy created.
      //   - The destination check uses sync IO on the source,
      //     because `_resolveTargets` itself is sync. The source
      //     is still on disk after the copy (unlike move), so
      //     this works equally well from `beforeTool` and
      //     `afterTool`.
      if (rel != null && rel.isNotEmpty &&
          relTarget != null && relTarget.isNotEmpty) {
        final srcAbs = p.join(workspaceDir, rel);
        final srcType = FileSystemEntity.typeSync(srcAbs);
        if (srcType == FileSystemEntityType.file) {
          after.add(p.join(workspaceDir, relTarget));
        }
      }
    } else if (rel != null && rel.isNotEmpty && toolId != 'delete_file') {
      after.add(p.join(workspaceDir, rel));
    }
    return _TargetPaths(before: before, after: after);
  }

  /// Tool execute() returns a status string with `Error:` / `Failed`
  /// / `Denied` markers when something went wrong. We don't want to
  /// emit a phantom "modify" revision when the tool actually didn't
  /// touch the file — so on a non-OK result, skip capture entirely.
  /// (In the rare case a tool partially wrote then errored, the FS
  /// watcher will still pick up the partial write and log it as
  /// `fsEvent` origin.)
  bool _isFailedToolResult(String result) {
    return result.contains('Error:') ||
        result.contains('Failed') ||
        result.contains('Denied');
  }

  String _noteForTool(String toolId) {
    switch (toolId) {
      case 'create_file':
        return 'Created via tool: create_file';
      case 'edit_file':
        return 'Edited via tool: edit_file';
      case 'multi_edit':
        return 'Edited via tool: multi_edit';
      case 'edit_range':
        return 'Edited via tool: edit_range';
      case 'append_file':
        return 'Appended via tool: append_file';
      case 'move_file':
        return 'Renamed via tool: move_file';
      case 'copy_file':
        return 'Copied via tool: copy_file';
      case 'delete_file':
        return 'Deleted via tool: delete_file';
    }
    return 'Tool: $toolId';
  }
}

class _TargetPaths {
  final List<String> before;
  final List<String> after;
  const _TargetPaths({required this.before, required this.after});
}

