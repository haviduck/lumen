import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../widgets/menu_bar.dart';

/// One entry in the Command Palette. [run] is invoked synchronously when
/// the user picks the command — the palette closes itself first so any
/// dialog/route opened by the command stacks correctly.
class IdeCommand {
  final String id;
  final String title;
  final String? subtitle;
  final IconData icon;
  final String? shortcut;
  final void Function(BuildContext context) run;
  final bool Function(AppState state)? enabled;
  final String? category;

  const IdeCommand({
    required this.id,
    required this.title,
    required this.icon,
    required this.run,
    this.subtitle,
    this.shortcut,
    this.enabled,
    this.category,
  });

  bool isEnabled(AppState state) => enabled?.call(state) ?? true;
}

/// Builds the list of commands shown in the palette. Most commands route
/// through [handleMenuAction] so behavior stays in lockstep with the menu
/// bar — adding a new menu action automatically gives it the same keyboard
/// shortcut and palette entry without duplicate logic.
class CommandCatalog {
  static List<IdeCommand> build() {
    return [
      IdeCommand(
        id: 'file.newWindow',
        title: S.menuNewWindow,
        icon: Icons.open_in_new,
        shortcut: 'Ctrl+Shift+N',
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'newWindow'),
      ),
      IdeCommand(
        id: 'file.open',
        title: S.menuOpenFolder,
        icon: Icons.folder_open,
        shortcut: 'Ctrl+O',
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'open'),
      ),
      IdeCommand(
        id: 'file.save',
        title: S.menuSaveFile,
        icon: Icons.save,
        shortcut: 'Ctrl+S',
        category: 'File',
        enabled: (s) => s.activeFile != null,
        run: (ctx) => handleMenuAction(ctx, 'save'),
      ),
      IdeCommand(
        id: 'file.quickOpen',
        title: S.menuQuickOpen,
        icon: Icons.bolt,
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'quickOpen'),
      ),
      IdeCommand(
        id: 'file.backup',
        title: S.menuBackup,
        icon: Icons.archive,
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'backup'),
      ),
      IdeCommand(
        id: 'agent.createSkill',
        title: S.manualSkillTitle,
        icon: Icons.auto_awesome,
        category: 'Agent',
        enabled: (s) => s.currentDirectory != null,
        run: (ctx) => handleMenuAction(ctx, 'createSkill'),
      ),
      IdeCommand(
        id: 'file.closeWorkspace',
        title: S.menuCloseWorkspace,
        icon: Icons.close,
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'closeWorkspace'),
      ),
      IdeCommand(
        id: 'edit.undo',
        title: S.menuUndo,
        icon: Icons.undo,
        shortcut: 'Ctrl+Z',
        category: 'Edit',
        enabled: (s) => s.ideActions.hasEditor,
        run: (ctx) => handleMenuAction(ctx, 'undo'),
      ),
      IdeCommand(
        id: 'edit.redo',
        title: S.menuRedo,
        icon: Icons.redo,
        shortcut: 'Ctrl+Shift+Z',
        category: 'Edit',
        enabled: (s) => s.ideActions.hasEditor,
        run: (ctx) => handleMenuAction(ctx, 'redo'),
      ),
      IdeCommand(
        id: 'edit.find',
        title: S.menuFind,
        icon: Icons.search,
        shortcut: 'Ctrl+F',
        category: 'Edit',
        enabled: (s) => s.ideActions.hasEditor,
        run: (ctx) => handleMenuAction(ctx, 'find'),
      ),
      IdeCommand(
        id: 'edit.globalSearch',
        title: S.menuGlobalSearch,
        icon: Icons.travel_explore,
        shortcut: 'Ctrl+Shift+F',
        category: 'Edit',
        run: (ctx) => handleMenuAction(ctx, 'globalSearch'),
      ),
      IdeCommand(
        id: 'view.zen',
        title: S.menuZenMode,
        icon: Icons.center_focus_strong,
        category: 'View',
        run: (ctx) => handleMenuAction(ctx, 'zen'),
      ),
      IdeCommand(
        id: 'view.sideEye',
        title: S.menuSideEye,
        icon: Icons.remove_red_eye,
        category: 'View',
        run: (ctx) => handleMenuAction(ctx, 'sideEye'),
      ),
      IdeCommand(
        id: 'view.normal',
        title: S.menuNormalLayout,
        icon: Icons.dashboard,
        category: 'View',
        run: (ctx) => handleMenuAction(ctx, 'normal'),
      ),
      IdeCommand(
        id: 'view.toggleWordWrap',
        title: S.editorWordWrap,
        icon: Icons.wrap_text,
        category: 'View',
        run: (ctx) {
          final s = ctx.read<AppState>();
          s.updateEditorSettings(wordWrap: !s.wordWrap);
        },
      ),
      IdeCommand(
        id: 'terminal.new',
        title: S.menuNewTerminal,
        icon: Icons.add,
        shortcut: 'Ctrl+`',
        category: 'Terminal',
        enabled: (s) => s.ideActions.hasTerminal,
        run: (ctx) => handleMenuAction(ctx, 'newTerm'),
      ),
      IdeCommand(
        id: 'terminal.kill',
        title: S.menuKillTerminal,
        icon: Icons.cancel,
        category: 'Terminal',
        enabled: (s) => s.ideActions.hasTerminal,
        run: (ctx) => handleMenuAction(ctx, 'killTerm'),
      ),
      IdeCommand(
        id: 'agent.newChat',
        title: S.chatNewSession,
        icon: Icons.add_comment_outlined,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'newChat'),
      ),
      IdeCommand(
        id: 'agent.rulesWorkspace',
        title: S.menuEditRules,
        icon: Icons.rule_folder,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'rulesWorkspace'),
      ),
      IdeCommand(
        id: 'agent.rulesGlobal',
        title: S.menuEditGlobalRules,
        icon: Icons.rule,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'rulesGlobal'),
      ),
      IdeCommand(
        id: 'agent.toggleAutoApprove',
        title: S.menuToggleAutoApprove,
        icon: Icons.flash_on,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'autoApprove'),
      ),
      IdeCommand(
        id: 'help.about',
        title: S.menuAbout,
        icon: Icons.info_outline,
        category: 'Help',
        run: (ctx) => handleMenuAction(ctx, 'about'),
      ),
    ];
  }
}
