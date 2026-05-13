import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'llm_providers_setup_dialog.dart';
import 'ollama_cloud_key_prompt_dialog.dart';
import 'ollama_setup_dialog.dart';
import 'skill_generator_dialog.dart';
import 'window_chrome/lumen_window_title_strip.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  Future<void> _openFolder(BuildContext context) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    final state = context.read<AppState>();
    final isNewProject = await state.setDirectory(dir);
    if (!navigator.mounted) return;
    // First-time-opened folders run the trimmed onboarding wizard
    // (Ollama → cloud key → providers → skills). GitNexus and
    // Syncthing wizard steps were retired — GitNexus stays available
    // via the gitnexus tools/CLI, Syncthing via Settings → Sync.
    if (isNewProject) {
      await _runNewProjectWizard(navigator.context, state, dir);
    }
  }

  /// Step wizard for the very first time a folder is opened.
  /// Same sequence used by `_createNewProject`. Skippable per-step.
  /// Each `context.mounted` guard handles the case where the user
  /// bails by closing the app mid-wizard — the next dialog is
  /// suppressed cleanly.
  ///
  /// Step order (each step is independently skippable):
  ///
  ///   1. **Ollama setup** — first-run only. Detects whether the
  ///      `ollama` CLI is installed and the daemon is reachable;
  ///      shows download/run/pull/signin instructions when not.
  ///   2. **Ollama Cloud key prompt** — first-run only AND no
  ///      Ollama Cloud key set yet. Narrow single-field dialog that
  ///      offers to seed an Ollama Cloud key specifically because
  ///      the next step (skill generation) is dramatically better
  ///      with a frontier-tier cloud model. Skipping is fine — the
  ///      skill generator falls back to whatever model is selected.
  ///   3. **LLM providers** — first-run only. Lets the user paste
  ///      API keys for cloud providers (Gemini, Claude, GitHub
  ///      Models, OpenAI) so the rest of the wizard (skill
  ///      generator) actually has an LLM to call.
  ///   4. **Skill generator** — asks an LLM to bootstrap
  ///      `.agents/tools/` and `.agents/skills/` for this project.
  ///      When an Ollama Cloud key is set the generator forces a
  ///      frontier cloud model regardless of the user's currently
  ///      selected chat model. See `pickSkillModel` in
  ///      `services/skill_model_picker.dart`.
  ///
  /// Steps 1, 2, and 3 only fire when `_isLumenFirstRun` returns
  /// true so repeat users (who already have at least one provider
  /// working) don't get nagged on every new project. Step 4 always
  /// offers — it's a per-workspace concern, not a per-installation
  /// one. The previous GitNexus and Syncthing wizard steps were
  /// removed; both features remain available outside the wizard.
  ///
  /// **Why a dedicated Ollama Cloud step instead of folding it into
  /// the LLM providers grid.** The full LLM providers dialog is a
  /// dense 4-card grid; on a brand-new install the user will see
  /// it anyway. The dedicated Ollama-cloud prompt fires *before*
  /// that grid for a single, narrow reason (seeding a cloud key
  /// specifically for the skill generator) and is much faster to
  /// dismiss when the user just wants to skim through. Two prompts
  /// is fine because they have different intents — one is "do you
  /// want a strong skill-generator model?", the other is "what
  /// providers do you want enabled long-term?".
  Future<void> _runNewProjectWizard(
    BuildContext context,
    AppState state,
    String path,
  ) async {
    final firstRun = await _isLumenFirstRun(state);
    if (context.mounted && firstRun) {
      await showOllamaSetupDialog(context);
    }
    // Re-read state.ollamaApiKey lazily on every guard so a key
    // pasted in the previous step (or via Syncthing-restored prefs)
    // suppresses this prompt without us needing to thread the
    // updated value through.
    if (context.mounted &&
        firstRun &&
        state.ollamaApiKey.isEmpty) {
      await showOllamaCloudKeyPromptDialog(context);
    }
    if (context.mounted && firstRun) {
      await showLlmProvidersSetupDialog(context);
    }
    if (context.mounted) {
      await showSkillGeneratorDialog(context, workspacePath: path);
    }
  }

  /// Heuristic for "is this the user's first time using Lumen?". We
  /// say yes when *no* provider looks usable — every cloud API key
  /// is empty AND the local Ollama daemon doesn't respond. Any one
  /// of those being truthy is enough evidence that the user has
  /// already configured Lumen at some point, and we skip the
  /// onboarding-style steps to avoid nagging repeat users every
  /// time they open a new project.
  Future<bool> _isLumenFirstRun(AppState state) async {
    final hasAnyKey = state.geminiApiKey.isNotEmpty ||
        state.anthropicApiKey.isNotEmpty ||
        state.openaiApiKey.isNotEmpty ||
        // An Ollama Cloud key is just as much "the user has configured
        // a provider" as any other key — treat it the same so cloud-
        // only Ollama users don't get re-prompted with onboarding
        // every project open.
        state.ollamaApiKey.isNotEmpty;
    if (hasAnyKey) return false;
    final ollamaUp = await state.ollamaService.isReachable();
    return !ollamaUp;
  }

  /// "New Project" entry point. We deliberately do NOT prompt for a
  /// name + parent combo anymore — the previous two-step flow (name
  /// dialog → parent picker) was confusing because Lumen has no
  /// independent "project name" concept; project identity is the
  /// folder path, and the displayed name is just the folder's
  /// basename. Letting the OS file picker do all of it (incl. its
  /// built-in "New folder" affordance) is one fewer dialog and
  /// matches how every other native IDE-ish app on this platform
  /// behaves.
  ///
  /// Always runs the wizard regardless of whether the folder is
  /// already in recents — clicking "New Project" implies the user
  /// wants the onboarding flow, even if they happened to pick a
  /// folder Lumen has seen before.
  Future<void> _createNewProject(BuildContext context) async {
    final dir = await FilePicker.getDirectoryPath();
    if (dir == null || !context.mounted) return;
    final navigator = Navigator.of(context);
    final state = context.read<AppState>();
    await state.setDirectory(dir);
    if (navigator.mounted) {
      await _runNewProjectWizard(navigator.context, state, dir);
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();

    // Welcome panel as a self-contained splash: the entire window IS
    // the card. No outer padding, no ambient bezel showing through —
    // an earlier iteration mounted the card inside a `Stack` with
    // `AmbientBackground` + 12 px padding, which left a visible dark
    // border around the rounded card. Windows 11's DWM auto-rounds
    // the window corners for us; the card surface fills the entire
    // window so the user sees the splash and nothing else.
    //
    // The title strip (drag + min/max/close) is the FIRST row of the
    // card so the OS-caption replacement still rides at the top edge
    // of the visible surface.
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: _WelcomeCardSurface(
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const LumenWindowTitleStrip(),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 16, 22, 22),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/images/lumen_logo.png',
                          width: 44,
                          height: 44,
                          filterQuality: FilterQuality.high,
                        ),
                        const SizedBox(width: 10),
                        const Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.appName,
                                style: TextStyle(
                                  fontSize: 36,
                                  height: 0.95,
                                  fontWeight: FontWeight.w200,
                                  letterSpacing: 4,
                                  color: DuckColors.pearlWhite,
                                ),
                              ),
                              SizedBox(height: 6),
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
                        ),
                      ],
                    ),
                    const SizedBox(height: 22),
                    const Text(S.welcomeStart, style: DuckTheme.titleS),
                    const SizedBox(height: 10),
                    _Action(
                      icon: Icons.folder_open,
                      label: S.openFolder,
                      onTap: () => _openFolder(context),
                    ),
                    const SizedBox(height: 4),
                    _Action(
                      icon: Icons.create_new_folder,
                      label: S.newProject,
                      onTap: () => _createNewProject(context),
                    ),
                    const SizedBox(height: 16),
                    Flexible(
                      child: _RecentWorkspacesPanel(appState: appState),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single card surface that hosts the welcome content. The native
/// window is sized to this card's footprint (`WindowChrome.welcomeSize`)
/// and Windows 11's DWM auto-rounds the window corners, so the surface
/// here is the entire visible splash — no outer bezel, no rounded-card-
/// inside-rectangular-window leak. Background uses `bgDeepest` to match
/// the IDE shell's `DuckMenuBar` tint so the welcome→workspace
/// transition feels continuous.
class _WelcomeCardSurface extends StatelessWidget {
  final Widget child;

  const _WelcomeCardSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF14171D), // bgDeepest — matches title-bar tint
      child: child,
    );
  }
}

// (The old per-screen `_BackgroundDecor` was extracted to
// `widgets/common/ambient_background.dart` and is now shared between the
// welcome screen and the IDE shell.)
//
// `_WelcomeFocusPanel` ("Local-first workspace" copy block) was removed
// when the welcome screen was reshaped into a small panel-sized window.
// Static info-only chrome doesn't earn pixels at that footprint; if the
// onboarding nudge needs to come back, do it as a one-time tooltip on
// the Open Folder action, NOT as a permanent panel.

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

// `_promptSyncthingIfNeeded` was removed when the project wizard's
// Syncthing step retired. Sharing is configured via Settings → Sync.
