import 'package:flutter/material.dart';

import '../../../l10n/strings.dart';
import '../../../widgets/council/council_wizard_dialog.dart';
import '../../common/duck_toast.dart';
import 'slash_command.dart';

class CouncilCommand extends SlashCommand {
  CouncilCommand({this.alias = 'council'});

  final String alias;

  @override
  String get name => alias;

  @override
  String get description => S.councilSlashDescription;

  @override
  IconData get icon => Icons.hub_outlined;

  @override
  Future<SlashCommandResult> run(SlashCommandContext ctx) async {
    final workspace = ctx.appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) {
      showDuckToast(ctx.buildContext, S.councilNoWorkspace);
      return SlashCommandResult.noop;
    }
    await showCouncilWizard(ctx.buildContext);
    return const SlashCommandResult(textToSend: null);
  }
}
