import 'dart:io';

import 'package:flutter/material.dart';

import '../../../l10n/strings.dart';
import '../../../services/handoff_service.dart';
import '../../common/duck_toast.dart';
import 'slash_command.dart';

/// `/handoff` — composes a structured "what I was doing / what's
/// next" artifact from the current chat context and saves it under
/// `.lumen/handoff/`. The next chat picks it up via the rule installed
/// in `.lumen/rules.md`.
///
/// Auto-summarized: the agent uses recent chat turns + open files to
/// fill in the body. The user types nothing besides `/handoff`.
class HandoffCommand extends SlashCommand {
  @override
  String get name => 'handoff';

  @override
  String get description => S.slashHandoffDescription;

  @override
  IconData get icon => Icons.handshake_outlined;

  @override
  Future<SlashCommandResult> run(SlashCommandContext ctx) async {
    final workspace = ctx.appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) {
      showDuckToast(ctx.buildContext, S.slashHandoffNoWorkspace);
      return SlashCommandResult.noop;
    }

    final ruleNewlyInstalled = await HandoffService.ensureRuleInstalled(
      workspace,
    );
    if (ruleNewlyInstalled && ctx.buildContext.mounted) {
      showDuckToast(ctx.buildContext, S.slashHandoffRuleInstalled);
    }

    final filename = HandoffService.filenameFor(_titleHint(ctx));
    final relPath = HandoffService.relativePathFor(filename);
    final nowIso = HandoffService.formatTimestamp(DateTime.now());

    final activeFile = ctx.appState.activeFile?.path;
    final openFiles = ctx.appState.openFiles
        .map((f) => _basename(f.path))
        .where((name) => name.isNotEmpty)
        .toList();

    final argsHint = ctx.args.trim();
    final argsLine = argsHint.isEmpty
        ? ''
        : '\nUser-provided focus hint: "$argsHint". Anchor the handoff '
              'around this if it conflicts with the chat history, prefer '
              'this hint.\n';

    final activeLine = activeFile == null
        ? '- Active file: (none open)'
        : '- Active file: ${_basename(activeFile)}';
    final openLine = openFiles.isEmpty
        ? '- Open files: (none)'
        : '- Open files: ${openFiles.join(", ")}';

    final prompt = _buildPrompt(
      relPath: relPath,
      nowIso: nowIso,
      activeLine: activeLine,
      openLine: openLine,
      argsLine: argsLine,
    );

    return SlashCommandResult(textToSend: prompt);
  }

  String _titleHint(SlashCommandContext ctx) {
    final args = ctx.args.trim();
    if (args.isNotEmpty) return args;
    final active = ctx.appState.activeFile?.path;
    if (active != null) return 'continue ${_basename(active)}';
    return 'session handoff';
  }

  String _basename(String path) {
    final sep = path.contains('\\') && !path.contains('/') ? '\\' : Platform.pathSeparator;
    final i = path.lastIndexOf(sep);
    return i < 0 ? path : path.substring(i + 1);
  }

  String _buildPrompt({
    required String relPath,
    required String nowIso,
    required String activeLine,
    required String openLine,
    required String argsLine,
  }) {
    return '''/handoff — write a chat-to-chat handoff for the next session.

Compose a structured handoff summarizing what we have been working on in
*this* chat so a fresh agent can pick up without me re-explaining it.
Save it as a single file using the CREATE_FILE tool at this exact path:

    $relPath

Workspace context:
$activeLine
$openLine
$argsLine
The file MUST start with this YAML front-matter (verbatim shape — only
fill in the title; keep the other lines exactly as shown):

<<<CREATE_FILE: $relPath>>>
---
title: "<one short sentence, no leading verb-noun jargon>"
created_at: $nowIso
status: pending
received_at: null
---

## Current state
<2-5 sentences: what we were doing, where we are right now, what is
broken / blocked / mid-flight.>

## Next steps
<bullet list. Each bullet is a concrete action the next chat should
take. Order matters — first bullet is the next concrete move.>

## Context you need
<bullet list of files, services, or decisions the next chat should
load before doing anything. Reference paths exactly.>

## Don't redo
<bullet list of things we already tried or considered and rejected,
so the next chat does not loop on them. If nothing applies, write
"- Nothing to flag.">
<<<END_FILE>>>

After writing the file, reply with one short sentence confirming the
handoff was created and the filename. Do not summarize the body back
to me — the file IS the summary.''';
  }
}
