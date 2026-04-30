import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/workspace_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/ambient_background.dart';
import 'common/duck_toast.dart';
import 'gitnexus_dialog.dart';
import 'skill_generator_dialog.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  Future<void> _openFolder(BuildContext context) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    final state = context.read<AppState>();
    final isNewProject = await state.setDirectory(dir);
    if (!navigator.mounted) return;
    // First-time-opened folders go through the same wizard the
    // "Create new project" flow uses — skills + GitNexus + Syncthing.
    // Each step is skippable so the user can bail at any point.
    // Already-known projects skip straight to the (idempotent)
    // Syncthing prompt only.
    if (isNewProject) {
      await _runNewProjectWizard(navigator.context, state, dir);
    } else if (navigator.mounted) {
      await _promptSyncthingIfNeeded(navigator.context, state, dir);
    }
  }

  /// Step wizard for the very first time a folder is opened.
  /// Same sequence used by `_createNewProject`. Skippable per-step.
  /// Each `context.mounted` guard handles the case where the user
  /// bails by closing the app mid-wizard — the next dialog is
  /// suppressed cleanly.
  Future<void> _runNewProjectWizard(
    BuildContext context,
    AppState state,
    String path,
  ) async {
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

  Future<void> _createNewProject(BuildContext context) async {
    final result = await showDialog<({String name, String parent})>(
      context: context,
      builder: (_) => const _NewProjectDialog(),
    );
    if (result == null || !context.mounted) return;

    final navigator = Navigator.of(context);
    final svc = WorkspaceService();
    final newPath = await svc.createNewProject(result.parent, result.name);
    if (newPath != null && context.mounted) {
      final state = context.read<AppState>();
      await state.setDirectory(newPath);
      // Newly-created projects always trigger the wizard. We don't
      // gate this on `setDirectory`'s `isNewProject` return because
      // a freshly-created folder is by definition new — and using
      // the same wizard helper as `_openFolder` keeps the two paths
      // in sync if the steps ever change.
      if (navigator.mounted) {
        await _runNewProjectWizard(navigator.context, state, newPath);
      }
    } else if (context.mounted) {
      showDuckToast(context, S.welcomeFailedToCreate);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          // Welcome uses a slightly stronger ambient (1.0) since it's the
          // only thing on screen and has no chrome competing with it.
          const Positioned.fill(child: AmbientBackground(intensity: 1.0)),
          Center(
            child: SizedBox(
              width: 720,
              child: _WelcomeCardSurface(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/images/lumen_logo.png',
                          width: 50,
                          height: 50,
                          filterQuality: FilterQuality.high,
                        ),
                        const SizedBox(width: 10),
                        const Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.appName,
                              style: TextStyle(
                                fontSize: 44,
                                height: 0.9,
                                fontWeight: FontWeight.w200,
                                letterSpacing: 4,
                                color: DuckColors.pearlWhite,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              S.tagline,
                              style: TextStyle(
                                color: DuckColors.fgMuted,
                                fontSize: 11,
                                letterSpacing: 1.2,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                S.welcomeStart,
                                style: DuckTheme.titleS,
                              ),
                              const SizedBox(height: 14),
                              _Action(
                                icon: Icons.folder_open,
                                label: S.openFolder,
                                onTap: () => _openFolder(context),
                              ),
                              const SizedBox(height: 6),
                              _Action(
                                icon: Icons.create_new_folder,
                                label: S.newProject,
                                onTap: () => _createNewProject(context),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 32),
                        const Expanded(child: _WelcomeFocusPanel()),
                      ],
                    ),
                    const SizedBox(height: 28),
                    _RecentWorkspacesPanel(appState: appState),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WelcomeCardSurface extends StatelessWidget {
  final Widget child;

  const _WelcomeCardSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: DuckColors.bgGlassHi,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(color: DuckColors.glassEdgeHi, width: 0.5),
          boxShadow: DuckTheme.shadowSoft,
        ),
        child: child,
      ),
    );
  }
}

// (The old per-screen `_BackgroundDecor` was extracted to
// `widgets/common/ambient_background.dart` and is now shared between the
// welcome screen and the IDE shell.)

class _WelcomeFocusPanel extends StatelessWidget {
  const _WelcomeFocusPanel();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.38),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.folder_special_outlined,
                size: 16,
                color: DuckColors.accentCyan,
              ),
              SizedBox(width: 8),
              Text(S.welcomeFocusTitle, style: DuckTheme.titleS),
            ],
          ),
          SizedBox(height: 10),
          Text(
            S.welcomeFocusBody,
            style: TextStyle(
              color: DuckColors.fgMuted,
              fontSize: 12,
              height: 1.45,
            ),
          ),
        ],
      ),
    );
  }
}

class _Action extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Action({required this.icon, required this.label, required this.onTap});

  @override
  State<_Action> createState() => _ActionState();
}

class _ActionState extends State<_Action> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.instant,
        curve: DuckMotion.standard,
        decoration: BoxDecoration(
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        ),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                Icon(widget.icon, color: DuckColors.pearlWhite, size: 18),
                const SizedBox(width: 12),
                Text(
                  widget.label,
                  style: const TextStyle(
                    fontWeight: FontWeight.w500,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RecentWorkspacesPanel extends StatelessWidget {
  final AppState appState;

  const _RecentWorkspacesPanel({required this.appState});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.48),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.history, size: 15, color: DuckColors.fgMuted),
              SizedBox(width: 8),
              Text(S.welcomeRecentProjects, style: DuckTheme.titleS),
            ],
          ),
          const SizedBox(height: 10),
          if (appState.recentProjects.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 4),
              child: Text(
                S.noRecentProjects,
                style: TextStyle(color: DuckColors.fgSubtle, fontSize: 12),
              ),
            )
          else
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 150),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: appState.recentProjects.length,
                itemBuilder: (context, index) {
                  final path = appState.recentProjects[index];
                  return _RecentRow(
                    path: path,
                    onTap: () => appState.setDirectory(path),
                    onRemove: () => appState.removeRecentProject(path),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _RecentRow extends StatefulWidget {
  final String path;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  const _RecentRow({
    required this.path,
    required this.onTap,
    required this.onRemove,
  });

  @override
  State<_RecentRow> createState() => _RecentRowState();
}

class _RecentRowState extends State<_RecentRow> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        decoration: BoxDecoration(
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        margin: const EdgeInsets.only(bottom: 4),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.history, size: 14, color: DuckColors.fgSubtle),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.path,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DuckColors.accentCyan,
                      fontSize: 12,
                    ),
                  ),
                ),
                // Always present to prevent layout shift on hover.
                Opacity(
                  opacity: _hover ? 1.0 : 0.0,
                  child: IgnorePointer(
                    ignoring: !_hover,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 14),
                      onPressed: widget.onRemove,
                      tooltip: S.removeFromRecent,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 22,
                        minHeight: 22,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Stateful dialog for creating a new project.
/// User enters a name, hits Create, folder picker opens for location.
class _NewProjectDialog extends StatefulWidget {
  const _NewProjectDialog();

  @override
  State<_NewProjectDialog> createState() => _NewProjectDialogState();
}

class _NewProjectDialogState extends State<_NewProjectDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a project name.');
      return;
    }
    // Open folder picker for where to create the project.
    final parent = await FilePicker.getDirectoryPath();
    if (parent == null) return;
    if (!mounted) return;
    Navigator.pop(context, (name: name, parent: parent));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: const Text(
        S.welcomeNewProjectTitle,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      content: SizedBox(
        width: 340,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                hintText: 'my-project',
                labelText: S.welcomeProjectName,
                isDense: true,
                border: const OutlineInputBorder(),
                errorText: _error,
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _create(),
            ),
            const SizedBox(height: 8),
            const Text(
              "You'll pick the folder location next.",
              style: TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(S.cancel),
        ),
        TextButton(onPressed: _create, child: const Text(S.welcomeCreate)),
      ],
    );
  }
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
        S.syncthingPromptTitle,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
      ),
      content: const Text(
        S.syncthingPromptBody,
        style: TextStyle(fontSize: 12.5, color: DuckColors.fgMuted),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text(S.syncthingPromptCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text(S.syncthingPromptShare),
        ),
      ],
    ),
  );

  if (accepted == true) {
    state.syncthingShareManually(path);
    if (context.mounted) {
      showDuckToast(context, S.syncthingSharedToast);
    }
  }
}
