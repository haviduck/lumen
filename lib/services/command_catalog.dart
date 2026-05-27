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
        id: 'file.newFile',
        title: S.menuNewFile,
        icon: Icons.note_add_outlined,
        shortcut: 'Ctrl+N',
        category: 'File',
        // `newFile` falls back to a toast when no workspace is open,
        // so we mirror the menu's enablement rule rather than letting
        // the palette dispatch into the toast path.
        enabled: (s) => s.currentDirectory != null,
        run: (ctx) => handleMenuAction(ctx, 'newFile'),
      ),
      IdeCommand(
        id: 'file.newTab',
        title: S.menuNewTab,
        icon: Icons.tab_outlined,
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'newTab'),
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
        id: 'file.lock',
        title: S.menuLockIde,
        icon: Icons.lock_outline,
        category: 'File',
        run: (ctx) => handleMenuAction(ctx, 'lock'),
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
        // The menu greys this out when no workspace is open;
        // mirror that here so a stray Ctrl+P → "close" doesn't
        // dispatch a no-op.
        enabled: (s) => s.currentDirectory != null,
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
        id: 'edit.findReplace',
        title: S.menuFindReplace,
        icon: Icons.find_replace,
        shortcut: 'Ctrl+H',
        category: 'Edit',
        enabled: (s) => s.ideActions.hasEditor,
        run: (ctx) => handleMenuAction(ctx, 'findReplace'),
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
        id: 'view.focusExplorer',
        title: S.menuFocusExplorer,
        icon: Icons.folder_outlined,
        category: 'View',
        run: (ctx) => handleMenuAction(ctx, 'focusExplorer'),
      ),
      IdeCommand(
        id: 'view.timeline',
        title: S.menuTimeline,
        icon: Icons.timeline,
        category: 'View',
        // Same enablement as the menu — the timeline tracks files,
        // which needs a workspace to be open.
        enabled: (s) => s.currentDirectory != null,
        run: (ctx) => handleMenuAction(ctx, 'timeline'),
      ),
      IdeCommand(
        id: 'view.wiki',
        title: S.menuOpenWiki,
        icon: Icons.menu_book_outlined,
        category: 'View',
        // `openKnowledgeBaseTab` lives directly on `AppState` — it
        // isn't routed through `handleMenuAction` because no menu
        // item points at it (the file-explorer ambient button does).
        // We invoke the state method directly so the palette
        // doesn't depend on a menu case being added.
        run: (ctx) => ctx.read<AppState>().openKnowledgeBaseTab(),
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
        id: 'terminal.processManager',
        title: S.menuProcessManager,
        icon: Icons.memory_outlined,
        category: 'Terminal',
        run: (ctx) => handleMenuAction(ctx, 'processManager'),
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
        id: 'agent.llmUsage',
        title: S.menuViewTokenUsage,
        icon: Icons.bar_chart_outlined,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'llmUsage'),
      ),
      IdeCommand(
        id: 'agent.councilReports',
        title: S.councilReportsMenuItem,
        icon: Icons.article_outlined,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'councilReports'),
      ),
      IdeCommand(
        id: 'agent.councilSessions',
        title: S.councilSessionsMenuItem,
        icon: Icons.forum_outlined,
        category: 'Agent',
        run: (ctx) => handleMenuAction(ctx, 'councilSessions'),
      ),
      IdeCommand(
        id: 'help.about',
        title: S.menuAbout,
        icon: Icons.info_outline,
        category: 'Help',
        run: (ctx) => handleMenuAction(ctx, 'about'),
      ),
      IdeCommand(
        id: 'help.checkForUpdates',
        title: S.menuCheckForUpdates,
        icon: Icons.system_update_alt_outlined,
        category: 'Help',
        run: (ctx) => handleMenuAction(ctx, 'checkForUpdates'),
      ),
      IdeCommand(
        id: 'help.welcomeSetup',
        title: S.menuWelcomeSetup,
        icon: Icons.flag_outlined,
        category: 'Help',
        run: (ctx) => handleMenuAction(ctx, 'welcomeSetup'),
      ),

      // Settings categories — each opens the in-editor Settings tab
      // focused on a specific panel. The `category: 'Settings'` tag
      // makes them group together in the unified search and the
      // `Open Settings:` prefix means typing the panel name (e.g.
      // "theme", "ssh", "rules") jumps straight to it.
      IdeCommand(
        id: 'settings.general',
        title: 'Open Settings: ${S.settingsCatGeneral}',
        icon: Icons.tune,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(),
      ),
      IdeCommand(
        id: 'settings.editor',
        title: 'Open Settings: ${S.settingsCatEditor}',
        icon: Icons.edit_note,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'editor'),
      ),
      IdeCommand(
        id: 'settings.theme',
        title: 'Open Settings: ${S.settingsCatTheme}',
        icon: Icons.palette_outlined,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'theme'),
      ),
      IdeCommand(
        id: 'settings.terminal',
        title: 'Open Settings: ${S.settingsCatTerminal}',
        icon: Icons.terminal,
        category: 'Settings',
        run: (ctx) =>
            ctx.read<AppState>().openSettingsTab(category: 'terminal'),
      ),
      IdeCommand(
        id: 'settings.ai',
        title: 'Open Settings: ${S.settingsCatAI}',
        icon: Icons.auto_awesome_outlined,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'aiChat'),
      ),
      IdeCommand(
        id: 'settings.models',
        title: 'Open Settings: ${S.settingsCatModelManagement}',
        icon: Icons.memory,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'models'),
      ),
      IdeCommand(
        id: 'settings.rules',
        title: 'Open Settings: ${S.settingsCatRules}',
        icon: Icons.rule,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'rules'),
      ),
      IdeCommand(
        id: 'settings.remoteAccess',
        title: 'Open Settings: ${S.settingsCatRemoteAccess}',
        icon: Icons.cell_tower,
        category: 'Settings',
        run: (ctx) =>
            ctx.read<AppState>().openSettingsTab(category: 'remoteAccess'),
      ),
      IdeCommand(
        id: 'settings.ssh',
        title: 'Open Settings: ${S.settingsCatSsh}',
        icon: Icons.lan_outlined,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'ssh'),
      ),
      IdeCommand(
        id: 'settings.tools',
        title: 'Open Settings: ${S.settingsCatTools}',
        icon: Icons.extension_outlined,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'tools'),
      ),
      IdeCommand(
        id: 'settings.keys',
        title: 'Open Settings: ${S.settingsCatKeys}',
        icon: Icons.keyboard_outlined,
        category: 'Settings',
        run: (ctx) => ctx.read<AppState>().openSettingsTab(category: 'keys'),
      ),
    ];
  }
}
