import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'about_dialog.dart' as about;
import 'backup_dialog.dart';
import 'common/bright_icon_button.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';
import 'common/media_url_prompt.dart';
import 'gitnexus_dialog.dart';
import 'llm_providers_setup_dialog.dart';
import 'lock_screen.dart';
import 'manual_skill_dialog.dart';
import 'ollama_setup_dialog.dart';
import 'skill_generator_dialog.dart';

class DuckMenuBar extends StatelessWidget {
  const DuckMenuBar({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final actions = state.ideActions;

    return DuckGlass(
      tint: const Color(0xE614171D), // bgDeepest at ~90% — darkest surface
      // Subtle 0.5px hairlines on top AND bottom: top reads as the seam
      // between the native Windows title bar and our chrome; bottom seams
      // the menu bar to the workbench below.
      border: const Border(
        top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: SizedBox(
        // 30px (was 28). User asked for "slightly bigger, maybe 2px"
        // — enough to give the brighter right-cluster icons breathing
        // room without making the bar feel like a toolbar.
        height: 30,
        child: Row(
          children: [
            UnconstrainedBox(
              constrainedAxis: Axis.vertical,
              alignment: Alignment.centerLeft,
              child: MenuBar(
                style: MenuStyle(
                  backgroundColor: WidgetStateProperty.all(Colors.transparent),
                  elevation: WidgetStateProperty.all(0),
                  padding: WidgetStateProperty.all(
                    const EdgeInsets.symmetric(horizontal: 8),
                  ),
                  visualDensity: VisualDensity.compact,
                ),
                children: [
                  _submenu(context, S.menuFile, [
                    _itemWithShortcut(
                      context,
                      'newWindow',
                      S.menuNewWindow,
                      'Ctrl+Shift+N',
                    ),
                    _menuDivider,
                    _itemWithShortcut(
                      context,
                      'open',
                      S.menuOpenFolder,
                      'Ctrl+O',
                    ),
                    _itemWithShortcut(
                      context,
                      'newFile',
                      S.menuNewFile,
                      'Ctrl+N',
                      enabled: state.currentDirectory != null,
                    ),
                    _item(context, 'newFolder', S.menuNewFolder),
                    _itemWithShortcut(
                      context,
                      'save',
                      S.menuSaveFile,
                      'Ctrl+S',
                      enabled: actions.hasEditor,
                    ),
                    _menuDivider,
                    _item(
                      context,
                      'backup',
                      S.menuBackup,
                      enabled: state.currentDirectory != null,
                    ),
                    _item(context, 'settings', S.menuSettings),
                    _item(context, 'lock', S.menuLockIde),
                    _menuDivider,
                    _item(
                      context,
                      'closeWorkspace',
                      S.menuCloseWorkspace,
                      enabled: state.currentDirectory != null,
                    ),
                  ]),
                  _submenu(context, S.menuEdit, [
                    _itemWithShortcut(
                      context,
                      'undo',
                      S.menuUndo,
                      'Ctrl+Z',
                      enabled: actions.hasEditor,
                    ),
                    _itemWithShortcut(
                      context,
                      'redo',
                      S.menuRedo,
                      'Ctrl+Y',
                      enabled: actions.hasEditor,
                    ),
                    _menuDivider,
                    _itemWithShortcut(
                      context,
                      'cut',
                      S.menuCut,
                      'Ctrl+X',
                      enabled: actions.hasEditor,
                    ),
                    _itemWithShortcut(
                      context,
                      'copy',
                      S.menuCopy,
                      'Ctrl+C',
                      enabled: actions.hasEditor,
                    ),
                    _itemWithShortcut(
                      context,
                      'paste',
                      S.menuPaste,
                      'Ctrl+V',
                      enabled: actions.hasEditor,
                    ),
                    _menuDivider,
                    _itemWithShortcut(
                      context,
                      'selectAll',
                      S.menuSelectAll,
                      'Ctrl+A',
                      enabled: actions.hasEditor,
                    ),
                    _menuDivider,
                    _itemWithShortcut(
                      context,
                      'find',
                      S.menuFind,
                      'Ctrl+F',
                      enabled: actions.hasEditor,
                    ),
                    _itemWithShortcut(
                      context,
                      'findReplace',
                      S.menuFindReplace,
                      'Ctrl+H',
                      enabled: actions.hasEditor,
                    ),
                    _menuDivider,
                    _item(
                      context,
                      'toggleWordWrap',
                      S.menuToggleWordWrap,
                      enabled: actions.hasEditor,
                    ),
                  ]),
                  _submenu(context, S.menuView, [
                    _itemWithShortcut(
                      context,
                      'commandPalette',
                      S.menuCommandPalette,
                      'Ctrl+Shift+P',
                      enabled: actions.hasOverlays,
                    ),
                    _item(
                      context,
                      'quickOpen',
                      S.menuQuickOpen,
                      enabled: actions.hasOverlays,
                    ),
                    _itemWithShortcut(
                      context,
                      'globalSearch',
                      S.menuGlobalSearch,
                      'Ctrl+Shift+F',
                      enabled: actions.hasOverlays,
                    ),
                    _menuDivider,
                    _itemWithShortcut(
                      context,
                      'normal',
                      S.menuNormalLayout,
                      'Ctrl+1',
                    ),
                    _itemWithShortcut(context, 'zen', S.menuZenMode, 'Ctrl+2'),
                    _itemWithShortcut(
                      context,
                      'sideEye',
                      S.menuSideEye,
                      'Ctrl+3',
                    ),
                  ]),
                  _submenu(context, S.menuTerminal, [
                    _itemWithShortcut(
                      context,
                      'newTerm',
                      S.menuNewTerminal,
                      'Ctrl+`',
                      enabled: actions.hasTerminal,
                    ),
                    _item(
                      context,
                      'killTerm',
                      S.menuKillTerminal,
                      enabled: actions.hasTerminal,
                    ),
                  ]),
                  _submenu(context, S.menuAgent, [
                    _item(
                      context,
                      'createSkill',
                      S.manualSkillTitle,
                      enabled: state.currentDirectory != null,
                    ),
                    _menuDivider,
                    _item(context, 'autoApprove', S.menuToggleAutoApprove),
                    _menuDivider,
                    _item(
                      context,
                      'rulesWorkspace',
                      S.menuEditRules,
                      enabled: state.currentDirectory != null,
                    ),
                    _item(context, 'rulesGlobal', S.menuEditGlobalRules),
                  ]),
                  _submenu(context, S.menuHelp, [
                    _item(context, 'about', S.menuAbout),
                  ]),
                ],
              ),
            ),

            const Spacer(),

            // AI-chat sidebar toggle — always visible regardless of
            // whether the chat panel is currently shown or hidden.
            // Single static icon; tooltip is the only contextual
            // signal. Sits LEFT of the settings cog because it's a
            // workspace-layout control, settings is configuration.
            // `view_sidebar_outlined` (two-column layout glyph)
            // reads as "controls a side panel"; an earlier
            // iteration used `chat_outlined` (a chat-bubble icon)
            // which read as "open a chat" rather than "toggle the
            // sidebar".
            BrightIconButton(
              icon: Icons.view_sidebar_outlined,
              tooltip: S.menuBarToggleChat,
              onTap: () => state.toggleChatHidden(),
            ),
            const SizedBox(width: 10),
          ],
        ),
      ),
    );
  }

  Widget _submenu(BuildContext context, String label, List<Widget> children) {
    return SubmenuButton(
      menuStyle: _popupStyle,
      style: _buttonStyle,
      menuChildren: children,
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w400,
          color: DuckColors.fgMuted,
        ),
      ),
    );
  }

  /// Menu item without a leading icon. Per design call: dropdown rows in
  /// the top menu bar are pure text rows — VS Code style — to keep them
  /// dense and unambiguous. Icons here previously cluttered the rhythm.
  Widget _item(
    BuildContext context,
    String action,
    String label, {
    bool enabled = true,
  }) {
    return MenuItemButton(
      style: _itemStyle,
      onPressed: enabled ? () => handleMenuAction(context, action) : null,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: enabled ? DuckColors.fgPrimary : DuckColors.fgFaint,
        ),
      ),
    );
  }

  /// Menu item with a right-aligned keyboard shortcut hint.
  Widget _itemWithShortcut(
    BuildContext context,
    String action,
    String label,
    String shortcut, {
    bool enabled = true,
  }) {
    return MenuItemButton(
      style: _itemStyle,
      onPressed: enabled ? () => handleMenuAction(context, action) : null,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: enabled ? DuckColors.fgPrimary : DuckColors.fgFaint,
            ),
          ),
          const SizedBox(width: 24),
          Text(
            shortcut,
            style: TextStyle(
              fontSize: 11,
              color: enabled ? DuckColors.fgSubtle : DuckColors.fgFaint,
            ),
          ),
        ],
      ),
    );
  }

  // Section separator inside a dropdown. We pin `color` explicitly to
  // `DuckColors.border` (#272C36) instead of letting `Divider` inherit
  // `Theme.of(context).dividerColor` — that's `glassSeam` (5% white
  // alpha), which on a previously-translucent menu surface read as
  // tasteful, but on the new SOLID `bgRaised` surface read as an
  // obvious bright white line. Same gray as the dropdown's outer
  // border so the dividers match the chrome.
  static const Widget _menuDivider = Divider(
    height: 9,
    thickness: 0.5,
    color: DuckColors.border,
  );

  static final ButtonStyle _buttonStyle =
      MenuItemButton.styleFrom(
        foregroundColor: DuckColors.fgMuted,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        minimumSize: const Size(0, 30),
        visualDensity: VisualDensity.compact,
      ).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused) ||
              states.contains(WidgetState.pressed)) {
            return DuckColors.bgRaisedHi.withValues(alpha: 0.62);
          }
          return Colors.transparent;
        }),
        shape: WidgetStateProperty.all(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
        ),
      );

  static final ButtonStyle _itemStyle =
      MenuItemButton.styleFrom(
        // More breathing room than VS Code's typical menu density —
        // the user has flagged "too tight" twice now. Vertical
        // padding 11 + min row height 36 lands closer to a Cursor /
        // native-Windows menu feel; min width 220 keeps labels
        // unambiguous and gives shortcut hints space to live.
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        minimumSize: const Size(220, 36),
        visualDensity: VisualDensity.standard,
      ).copyWith(
        backgroundColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.hovered) ||
              states.contains(WidgetState.focused)) {
            return DuckColors.bgRaisedHi.withValues(alpha: 0.55);
          }
          return Colors.transparent;
        }),
      );

  // Top-menu-bar dropdown chrome.
  //
  // The dropdown surface is intentionally **solid** (no alpha): the
  // ambient blobs blurring through a translucent menu were distracting
  // and made hover targets read as ambiguous. Background is
  // `bgRaised` — same family as the editor canvas, slightly lifted
  // from the menu bar itself (`bgDeepest`) so the menu reads as a
  // panel that's "popped out".
  //
  // The border is `DuckColors.border` (#272C36) — a real gray one
  // step lighter than the bg, **not** the previous `glassEdgeHi`
  // (white-at-8%-alpha, which read as a halo over the translucent
  // surface). The 0.5px width keeps it as a hairline rule rather
  // than a frame.
  //
  // **Not `static final` on purpose.** Hot reload re-evaluates instance
  // getters but treats `static final` initializers as already-run
  // constants — meaning prior tweaks to this surface didn't take
  // effect on hot-reload, only on hot-restart. As a getter, every
  // build picks up the latest token values immediately.
  MenuStyle get _popupStyle => MenuStyle(
    backgroundColor: WidgetStateProperty.all(DuckColors.bgRaised),
    surfaceTintColor: WidgetStateProperty.all(Colors.transparent),
    shadowColor: WidgetStateProperty.all(Colors.black.withValues(alpha: 0.6)),
    elevation: WidgetStateProperty.all(12),
    // Vertical 8 (was 6): the bigger min-height items above need a
    // bit more headroom against the rounded corners, otherwise the
    // first/last items felt clipped.
    padding: WidgetStateProperty.all(const EdgeInsets.symmetric(vertical: 8)),
    shape: WidgetStateProperty.all(
      RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
    ),
  );
}

Future<void> handleMenuAction(BuildContext context, String action) async {
  final state = context.read<AppState>();
  final actions = state.ideActions;
  switch (action) {
    case 'newWindow':
      try {
        await Process.start(Platform.resolvedExecutable, const <String>[]);
      } catch (e) {
        if (context.mounted) {
          showDuckToast(context, '${S.error}: $e');
        }
      }
      break;
    case 'open':
      final dir = await FilePicker.getDirectoryPath();
      if (dir != null) {
        final isNewProject = await state.setDirectory(dir);
        if (!context.mounted) break;
        // First time opening this folder → run the same wizard the
        // welcome screen runs (skills + GitNexus + Syncthing). Known
        // folders just get the (idempotent) Syncthing prompt so we
        // don't pester the user with onboarding on every re-open.
        if (isNewProject) {
          await _runNewProjectWizardFromMenu(context, state, dir);
        } else {
          await _promptSyncthingIfNeeded(context, state, dir);
        }
      }
      break;
    case 'newFile':
      if (state.currentDirectory != null) {
        final name = await _promptNewFileName(context);
        if (name != null && name.isNotEmpty && context.mounted) {
          try {
            final file = File(
              '${state.currentDirectory}${Platform.pathSeparator}$name',
            );
            await file.create(recursive: false);
            state.refreshDirectory();
            await state.openFile(file);
          } catch (e) {
            if (context.mounted) showDuckToast(context, 'Error: $e');
          }
        }
      }
      break;
    case 'newFolder':
      showDuckToast(context, S.menuFileExplorerHint);
      break;
    case 'newTab':
      state.openUntitledTab();
      break;
    case 'save':
      // Untitled tabs need a "Save As" prompt before writing to disk.
      if (AppState.isUntitledTab(state.activeFile?.path)) {
        final name = await _promptNewFileName(context);
        if (name != null && name.isNotEmpty && context.mounted) {
          final dir = state.currentDirectory ?? '.';
          final realPath = '$dir${Platform.pathSeparator}$name';
          final ok = await state.saveUntitledAs(
            state.activeFile!.path,
            realPath,
          );
          if (context.mounted) {
            if (!ok) showDuckToast(context, 'Failed to save file.');
            if (ok) state.refreshDirectory();
          }
        }
      } else {
        await state.saveFile();
      }
      break;
    case 'backup':
      if (!context.mounted) return;
      showDialog(context: context, builder: (_) => const BackupDialog());
      break;
    case 'settings':
      // Open settings as a tab in the editor area instead of a dialog.
      state.openSettingsTab();
      break;
    case 'lock':
      if (!context.mounted) return;
      if (await state.hasPin()) {
        await state.lockNow();
      } else if (context.mounted) {
        showDialog(context: context, builder: (_) => const PinSetupDialog());
      }
      break;
    case 'closeWorkspace':
      await state.closeWorkspace();
      break;
    case 'undo':
      actions.undo();
      break;
    case 'redo':
      actions.redo();
      break;
    case 'cut':
      actions.cut();
      break;
    case 'copy':
      actions.copy();
      break;
    case 'paste':
      actions.paste();
      break;
    case 'selectAll':
      actions.selectAll();
      break;
    case 'find':
      actions.find();
      break;
    case 'findReplace':
      actions.findReplace();
      break;
    case 'toggleWordWrap':
      await state.updateEditorSettings(wordWrap: !state.wordWrap);
      break;
    case 'commandPalette':
      actions.openCommandPalette();
      break;
    case 'quickOpen':
      actions.openQuickOpen();
      break;
    case 'globalSearch':
      actions.openGlobalSearch();
      break;
    case 'focusExplorer':
      actions.focusFileExplorer();
      break;
    case 'normal':
      state.setViewMode(DuckViewMode.normal);
      break;
    case 'zen':
      state.toggleZenMode();
      break;
    case 'sideEye':
      state.toggleSideEyeMode();
      break;
    case 'newTerm':
      actions.newTerminal();
      break;
    case 'killTerm':
      actions.killActiveTerminal();
      break;
    case 'createSkill':
      if (!context.mounted) return;
      await showManualSkillDialog(context);
      break;
    case 'autoApprove':
      await state.chat.setAutoApprove(!state.chat.autoApprove);
      break;
    case 'rulesWorkspace':
      state.openSettingsTab(category: 'rules');
      break;
    case 'rulesGlobal':
      state.openSettingsTab(category: 'rules');
      break;
    case 'about':
      if (!context.mounted) return;
      showDialog(context: context, builder: (_) => const about.AboutDialog());
      break;
    // Watch-media URL prompt — dispatched from the file explorer
    // activity-bar's media icon. Kept reachable via the action
    // dispatcher so future entry points (command palette, keyboard
    // shortcut) can route through here too.
    case 'youtube':
      if (!context.mounted) return;
      await showMediaUrlPrompt(context);
      break;
  }
}

Future<String?> _promptNewFileName(BuildContext context) async {
  String name = '';
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: const Text(
        'New File',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      content: SizedBox(
        width: 320,
        child: TextField(
          autofocus: true,
          style: const TextStyle(fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'filename.dart',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: (v) => name = v,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text(S.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, name),
          child: const Text('Create'),
        ),
      ],
    ),
  );
}

/// New-project wizard sequence used by the menu bar's "Open Folder"
/// when the chosen folder is being opened for the first time. Mirrors
/// `welcome_screen.dart::_runNewProjectWizard` step-for-step — keep
/// the two in sync if you change either. Each dialog has its own
/// Skip / Cancel button so the user can bail at any point;
/// `context.mounted` guards bridge the gap if they close the app
/// mid-flow.
Future<void> _runNewProjectWizardFromMenu(
  BuildContext context,
  AppState state,
  String path,
) async {
  final firstRun = await _isLumenFirstRun(state);
  if (context.mounted && firstRun) {
    await showOllamaSetupDialog(context);
  }
  if (context.mounted && firstRun) {
    await showLlmProvidersSetupDialog(context);
  }
  if (context.mounted) {
    await showSkillGeneratorDialog(context, workspacePath: path);
  }
  if (context.mounted && state.gitnexusEnabled) {
    await showGitNexusOnboardingDialog(context, workspacePath: path);
  }
  if (context.mounted) {
    await _promptSyncthingIfNeeded(context, state, path);
  }
}

/// First-run heuristic shared with `welcome_screen.dart`. True when
/// no provider has any credential set AND Ollama isn't reachable —
/// i.e. the user has nothing configured. Used to gate the onboarding
/// steps (Ollama setup, LLM providers) so repeat users don't see
/// them on every new project.
Future<bool> _isLumenFirstRun(AppState state) async {
  final hasAnyKey = state.geminiApiKey.isNotEmpty ||
      state.anthropicApiKey.isNotEmpty ||
      state.githubModelsApiKey.isNotEmpty ||
      state.openaiApiKey.isNotEmpty;
  if (hasAnyKey) return false;
  final ollamaUp = await state.ollamaService.isReachable();
  return !ollamaUp;
}

/// Shows a one-time prompt asking if the user wants to share this project
/// with Syncthing. Only fires when Syncthing is enabled, auto-share is OFF,
/// and the folder isn't already registered.
Future<void> _promptSyncthingIfNeeded(
  BuildContext context,
  AppState state,
  String path,
) async {
  final shouldPrompt = await state.shouldPromptSyncthingShare(path);
  if (!shouldPrompt || !context.mounted) return;

  final accepted = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: const Text(
        'Share with Syncthing?',
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      content: const Text(
        'Syncthing is connected but auto-share is off. '
        'Would you like to share this project with all your devices?',
        style: TextStyle(fontSize: 12.5, color: DuckColors.fgMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('No'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Share'),
        ),
      ],
    ),
  );

  if (accepted == true) {
    state.syncthingShareManually(path);
    if (context.mounted) {
      showDuckToast(context, 'Project shared with Syncthing devices.');
    }
  }
}
