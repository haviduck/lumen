import 'dart:async';

import 'package:flutter/material.dart';

import '../../../l10n/strings.dart';
import '../../../services/git_service.dart';
import '../../common/duck_toast.dart';
import 'slash_command.dart';

/// `/push <message>` — runs `git add -A`, `git commit -m <message>`,
/// and `git push` against the active workspace, deterministically
/// (no LLM in the loop). Failures and successes are surfaced via
/// toasts so the chat thread stays clean.
///
/// Argument parsing is forgiving: bare `/push fix the bug` works,
/// `/push "fix the bug"` also works. Quotes are stripped only when
/// they wrap the entire message — embedded quotes are preserved so
/// the user can pass commit messages containing them.
///
/// The actual git work is fired-and-forgotten so the chat input
/// unblocks immediately. Status updates are toast-only because the
/// output is short and the action is deliberately low-ceremony.
class PushCommand extends SlashCommand {
  final GitService _git;

  PushCommand({GitService? git}) : _git = git ?? GitService();

  @override
  String get name => 'push';

  @override
  String get description => S.slashPushDescription;

  @override
  IconData get icon => Icons.cloud_upload_outlined;

  @override
  Future<SlashCommandResult> run(SlashCommandContext ctx) async {
    final workspace = ctx.appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) {
      _toast(ctx, S.slashPushNoWorkspace);
      return SlashCommandResult.noop;
    }

    final message = _extractMessage(ctx.args);
    if (message.isEmpty) {
      _toast(ctx, S.slashPushUsage);
      return SlashCommandResult.noop;
    }

    final isRepo = await _git.isRepo(workspace);
    if (!ctx.buildContext.mounted) return SlashCommandResult.noop;
    if (!isRepo) {
      _toast(ctx, S.slashPushNotRepo);
      return SlashCommandResult.noop;
    }

    // Fire-and-forget the actual pipeline so the input box unblocks
    // immediately. Push can take 30+ seconds on a slow remote — we
    // shouldn't make the user stare at a frozen composer.
    unawaited(_runPipeline(ctx, workspace, message));
    _toast(ctx, S.slashPushStarting);
    return const SlashCommandResult(textToSend: null, clearComposer: true);
  }

  /// Run add → commit → push sequentially, toasting at each
  /// failure boundary and once at the end on full success. We deliberately
  /// do NOT toast every step on a happy path — for a 1-second pipeline
  /// the cascade of "Added", "Committed", "Pushed" is more annoying
  /// than informative.
  Future<void> _runPipeline(
    SlashCommandContext ctx,
    String workspace,
    String message,
  ) async {
    final commit = await _git.autoCommit(workspace, message: message);
    if (!ctx.buildContext.mounted) return;
    if (!commit.ok) {
      _toast(ctx, '${S.slashPushCommitFailed}: ${commit.message}');
      return;
    }
    if (commit.message == 'no changes') {
      _toast(ctx, S.slashPushNothingToCommit);
      return;
    }

    final push = await _git.push(workspace);
    if (!ctx.buildContext.mounted) return;
    if (!push.ok) {
      _toast(ctx, '${S.slashPushPushFailed}: ${push.message}');
      return;
    }
    _toast(ctx, S.slashPushDone);
  }

  /// Strip a single pair of wrapping quotes if (and only if) the
  /// entire arg string is wrapped in matching quotes. Single and
  /// double quotes are both accepted.
  String _extractMessage(String rawArgs) {
    final trimmed = rawArgs.trim();
    if (trimmed.length >= 2) {
      final first = trimmed[0];
      final last = trimmed[trimmed.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return trimmed.substring(1, trimmed.length - 1).trim();
      }
    }
    return trimmed;
  }

  void _toast(SlashCommandContext ctx, String msg) {
    if (!ctx.buildContext.mounted) return;
    showDuckToast(ctx.buildContext, msg);
  }
}
