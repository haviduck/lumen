/// Centralized UI strings.
///
/// Per workspace rule: avoid hardcoded text in widgets. All user-facing
/// strings live here so they can be later swapped for a real i18n delegate
/// without rewriting widgets. Keys are grouped by surface.
class S {
  S._();

  // App / common
  static const String appName = 'Lumen';
  static const String tagline = 'With love from Norway';
  static const String save = 'Save';
  static const String cancel = 'Cancel';
  static const String close = 'Close';
  static const String delete = 'Delete';
  static const String rename = 'Rename';
  static const String copy = 'Copy';
  static const String paste = 'Paste';
  static const String confirm = 'Confirm';
  static const String ok = 'OK';
  static const String error = 'Error';
  static const String warning = 'Warning';
  static const String success = 'Success';
  static const String on = 'On';
  static const String off = 'Off';

  // Status bar
  static const String statusAutoApprove = 'auto-approve';
  static const String statusTheme = 'theme';
  static const String statusView = 'view';
  static const String statusWorkspace = 'workspace';
  static const String statusAgent = 'agent';
  static const String statusRecentEdits = 'recent edits';
  static const String statusRecentEditsTooltip =
      'Highlight what the most recent agent turn changed. Auto-clears '
      'when you type or save.';
  static const String statusAgentIdle = 'idle';
  static const String statusAgentThinking = 'thinking';

  // Welcome
  static const String welcomeStart = 'Start';
  static const String welcomeRecent = 'Recent';
  static const String welcomeRecentProjects = 'Recent Workspaces';
  static const String welcomeShortcuts = 'Quick Shortcuts';
  static const String welcomeClose = 'Close Lumen';
  static const String openFolder = 'Open Folder...';
  static const String open = 'Open';
  static const String newProject = 'New Project...';
  static const String noRecentProjects = 'No recent projects';
  static const String removeFromRecent = 'Remove from recent';

  // Menu bar
  static const String menuFile = 'File';
  static const String menuEdit = 'Edit';
  static const String menuView = 'View';
  static const String menuTerminal = 'Terminal';
  static const String menuRun = 'Run';
  static const String menuAgent = 'Agent';
  static const String menuHelp = 'Help';
  static const String menuNewWindow = 'New Window';
  static const String menuOpenFolder = 'Open Folder…';
  static const String menuOpenRecent = 'Open Recent';
  static const String menuNewFile = 'New File';
  static const String menuNewFolder = 'New Folder';
  static const String menuSaveFile = 'Save File';
  static const String menuCloseWorkspace = 'Close Workspace';
  static const String menuSettings = 'Settings…';
  static const String menuLockIde = 'Lock IDE';
  static const String menuBackup = 'Backup Project…';
  static const String menuZenMode = 'Toggle Zen Mode';
  static const String menuSideEye = 'Toggle Side-Eye Mode';
  static const String menuNormalLayout = 'Normal Layout';
  static const String menuNewTerminal = 'New Terminal';
  static const String menuKillTerminal = 'Kill Terminal';
  static const String menuEditRules = 'Edit Workspace Rules';
  static const String menuEditGlobalRules = 'Edit Global Rules';
  static const String menuToggleAutoApprove = 'Auto-approve Tool Calls';
  static const String menuUndo = 'Undo';
  static const String menuRedo = 'Redo';
  static const String menuCut = 'Cut';
  static const String menuCopy = 'Copy';
  static const String menuPaste = 'Paste';
  static const String menuSelectAll = 'Select All';
  static const String menuFind = 'Find in File';
  static const String menuFindReplace = 'Find and Replace';
  static const String menuToggleWordWrap = 'Toggle Word Wrap';
  static const String menuCommandPalette = 'Command Palette…';
  static const String menuQuickOpen = 'Quick Open File…';
  static const String menuGlobalSearch = 'Search in Files…';
  static const String menuAbout = 'About Lumen';
  static const String menuFileExplorerHint =
      'Use right-click in the file explorer.';
  static const String menuBarSearchTooltip = 'Search files';
  static const String explorerScrollTopTooltip = 'Scroll to top';
  static const String explorerOpenTeams = 'Open Microsoft Teams';
  static const String menuBarToggleChat = 'Toggle AI chat panel';

  // Unsaved-changes confirm prompts (dirty tab close).
  // Single-tab variant — `displayName` is the basename for named
  // files or "Untitled" for tabs that have never been saved.
  static String unsavedDialogTitle(String displayName) =>
      'Save changes to $displayName?';
  static const String unsavedDialogBody =
      'Your changes will be lost if you don\'t save them.';
  static const String unsavedDialogSave = 'Save';
  static const String unsavedDialogSaveAs = 'Save As…';
  static const String unsavedDialogDontSave = 'Don\'t Save';
  static const String unsavedDialogUntitledLabel = 'Untitled';
  // Toast surfaced when the user picked Save in a batch close but
  // an untitled tab couldn't be auto-saved (we leave it open
  // instead of guessing a filename).
  static String unsavedBatchUntitledSkipped(int count) => count == 1
      ? '1 untitled tab kept open — save it manually with Save As first.'
      : '$count untitled tabs kept open — save them manually with Save As first.';
  // Batch variant — fired when Close Others / Close to Right /
  // Close All would discard multiple dirty buffers.
  static String unsavedBatchTitle(int count) =>
      'Save changes to $count file${count == 1 ? '' : 's'}?';
  static const String unsavedBatchBody =
      'These files have unsaved changes. They will be lost if you don\'t save.';
  static const String unsavedBatchSaveAll = 'Save All';
  static const String unsavedBatchDontSave = 'Don\'t Save';
  static String unsavedBatchMore(int extra) => '+ $extra more…';

  // Skill generator (new-project skills bootstrap).
  static const String skillsTitle = 'Set up agent skills & tools?';
  static const String skillsBody =
      'Lumen can ask your LLM to generate a starter pack tailored to '
      'this project — a mix of:\n'
      '  • Tools (.lumen/tools/*.json) — shell commands the agent '
      'can invoke (lint, build, test, …).\n'
      '  • Skills (.lumen/skills/*.md) — written conventions the '
      'agent reads and follows (design system, code style, domain '
      'knowledge).\n'
      'The agent picks them up immediately, no restart needed.';
  static const String skillsCheckingLlm = 'Checking LLM connection…';
  static const String skillsGenerating = 'Generating skills…';
  static const String skillsAnalyzing = 'Analyzing project structure…';
  static const String skillsGenerate = 'Generate skills';
  static const String skillsContinue = 'Continue';
  // Per-message copy button on chat bubbles.
  static const String chatMessageCopy = 'Copy message';
  static const String chatMessageCopied = 'Message copied to clipboard';

  // Provider-error card (rendered when a chat turn ends with a
  // recognisable transient/auth/network error from the provider).
  static const String providerErrorOverloaded = 'Provider is overloaded';
  static const String providerErrorOverloadedBody =
      'The model provider returned a "server overloaded" response. '
      'This is usually temporary — wait a few seconds and retry.';
  static const String providerErrorRateLimited = 'Rate limited';
  static const String providerErrorRateLimitedBody =
      'You\'ve hit the provider\'s request rate limit. Wait a moment '
      'before retrying, or switch to a different model.';
  static const String providerErrorServer = 'Provider server error';
  static const String providerErrorServerBody =
      'The provider returned a server-side error (5xx). It\'s likely a '
      'transient outage — retry, or pick another model.';
  static const String providerErrorTimeout = 'No response from provider';
  static const String providerErrorTimeoutBody =
      'The provider stopped streaming before finishing. Retry, or '
      'pick a smaller / faster model.';
  static const String providerErrorAuth = 'Authentication failed';
  static const String providerErrorAuthBody =
      'The provider rejected your API key or token. Check the credential '
      'in Settings → AI/Chat for the relevant provider.';
  static const String providerErrorBadRequest = 'Request rejected';
  static const String providerErrorBadRequestBody =
      'The provider returned 400 Bad Request — the request body was '
      'invalid for this model. This often happens after a model API '
      'change (e.g. a new model expects a different parameter shape). '
      'See the raw error below for the exact field.';
  static const String providerErrorNotFound = 'Model not available';
  static const String providerErrorNotFoundBody =
      'The provider says this model isn\'t accessible to your account. '
      'Pick another model or check your provider settings.';
  static const String providerErrorNetwork = 'Network error';
  static const String providerErrorNetworkBody =
      'Could not reach the provider. Check your connection (or that '
      'the local server is running) and retry.';
  static const String providerErrorUnknown = 'Provider error';
  static const String providerErrorUnknownBody =
      'The model provider returned an unexpected response. Retry, or '
      'check the raw error below.';
  static const String providerErrorRetry = 'Retry last prompt';
  static const String providerErrorShowDetails = 'Show details';
  static const String providerErrorHideDetails = 'Hide details';
  static const String providerErrorOpenSettings = 'Open settings';

  // Stall warning shown above the input strip when a generation has
  // been silent (no chunks) for ~30s.
  static String chatStallWarning(int seconds) =>
      'No tokens for ${seconds}s — the model may be stuck. Use Stop and try the prompt again if it doesn\'t recover.';
  static const String chatStallStop = 'Stop';

  // Per-turn timing footer rendered at the bottom of finished
  // assistant bubbles. Diagnostic plumbing for the Ollama Cloud
  // 182s hard timeout (issue ollama/ollama#15973) and general
  // "why was this turn slow" debugging.
  static String turnTimingTtfb(String duration) => 'TTFB $duration';
  static String turnTimingIters(int count) => '$count iters';
  static String turnTimingLast(String duration) => 'last $duration';
  static const String turnTimingTooltip =
      'Wall-clock time for this turn · time-to-first-byte · iteration '
      'count · last-iteration duration. Diagnostic only.';
  static const String turnTimingWallTooltip =
      'This turn finished within the 175–185s window where Ollama '
      'Cloud has a known hard server-side timeout (issue 15973). '
      'If turns die here repeatedly, the cloud cut you off — split '
      'the work into smaller turns.';

  // Hallucination-halt warning surfaced at the bottom of the
  // assistant message when the loop was halted because the model
  // claimed file ops it never actually invoked as tools.
  // Parameterised so a user with 3 hallucinated paths and a user
  // with 30 see the same shape but different numbers, with a
  // hard cap on the paths preview to keep the warning readable.
  static String chatHallucinationHaltWarning(int count, String pathsPreview) =>
      '\n---\n\n'
      '⚠ **Hallucination detected — stopped this turn.**\n\n'
      'The model claimed to have created or edited $count file(s) '
      '(`$pathsPreview`) but no actual file-mutation tool ran for '
      'them this turn. This is a known failure mode of weaker / '
      'smaller models under reasoning load — the model role-plays '
      'the work instead of invoking the tools.\n\n'
      'What you can do:\n'
      '- Verify the listed paths in your file explorer; if they '
      'don\'t exist on disk, the model fabricated them.\n'
      '- Ask the model again with a focused prompt ("create the '
      'specific file at `path`") so it commits to a tool call.\n'
      '- If this keeps happening, switch to a stronger model — '
      'Qwen Coder, GLM, or Gemini variants tend to obey custom '
      'tool syntax better than thinking-only Ollama models.';

  // Empty-response strip — surfaces after a turn ends with no visible
  // content, no tool calls, no error. Common Ollama failure mode where
  // the stream closes cleanly but the model produced nothing useful.
  static const String chatEmptyResponseTitle =
      'Model returned an empty response';
  static const String chatEmptyResponseBody =
      'The stream closed without any visible output. This sometimes happens with Ollama models when context shifts or the model stalls. Continue to nudge it, or dismiss to send your own follow-up.';
  static const String chatEmptyResponseContinue = 'Continue';
  static const String chatEmptyResponseDismiss = 'Dismiss';

  // Thinking indicator (collapsible reasoning trace).
  static const String thinkingActive = 'Thinking\u2026';
  static const String thinkingDone = 'Thought process';

  // Queued prompts (composed while the agent is still generating).
  static const String chatQueuedHeader = 'Queued';
  static const String chatQueuedHint =
      'Prompts you send while the agent is generating land here and run in order when the current turn finishes.';
  static const String chatQueuedSendNow = 'Send now';
  static const String chatQueuedRemove = 'Remove';
  static const String chatQueuedSendNowTooltip =
      'Stop the current turn and send this prompt right away';
  static const String chatRestoreConfirmTitle = 'Restore file changes?';
  static String chatRestoreFilesTooltip(int count) =>
      count == 1 ? 'Restore 1 file change' : 'Restore $count file changes';
  static String chatRestoreConfirmBody(int count) =>
      'This will revert $count file timeline change(s) made by this assistant message. A pre-restore snapshot is captured first where possible.';

  // Chat rewind (Cursor / Antigravity-style "revert to before this
  // message"). Surfaced on USER bubbles. Restores file changes AND
  // truncates the chat so the LLM never sees the rolled-back turn on
  // the next send.
  static const String chatRewindConfirmTitle = 'Revert chat to this point?';
  static String chatRewindTooltip(int fileCount, int messageCount) {
    final files = fileCount == 0
        ? 'no file changes'
        : (fileCount == 1 ? '1 file change' : '$fileCount file changes');
    final msgs = messageCount == 1 ? '1 message' : '$messageCount messages';
    return 'Revert $files and remove $msgs from the chat';
  }

  static String chatRewindConfirmBody(int fileCount, int messageCount) {
    final files = fileCount == 0
        ? 'No file changes recorded.'
        : (fileCount == 1
              ? '1 file change will be reverted.'
              : '$fileCount file changes will be reverted.');
    final msgs = messageCount == 1 ? '1 message' : '$messageCount messages';
    return '$files $msgs (this prompt and everything after) will be removed from the chat so the next reply starts fresh. A pre-restore snapshot is captured first where possible.';
  }

  static const String chatRewindAction = 'Revert';
  static String chatRewindResultMessage(int messages, String fileSummary) {
    final m = messages == 1 ? '1 message' : '$messages messages';
    return 'Reverted: $fileSummary, removed $m.';
  }

  static const String skillsConfigureTitle = 'What kind of project is this?';
  static const String skillsConfigureBody =
      'Pick one or more archetypes so the generated tools match what '
      'you actually need. You can also add a free-text hint about '
      'your stack, design system, or anything else worth knowing.';
  static const String skillsExtraContextLabel = 'ANYTHING ELSE WORTH KNOWING?';
  static const String skillsExtraContextHint =
      'e.g. "uses Tailwind + shadcn, design tokens in design/tokens.json"';
  static const String skillsSkip = 'Skip';
  static const String skillsDone = 'Done';
  static const String skillsRetry = 'Retry';
  static const String manualSkillTitle = 'Create Agent Skill or Tool';
  static const String manualSkillIntro =
      'Describe one capability for the agent. The LLM will decide '
      'whether you want a TOOL (a shell command — `lint`, `build`, '
      '`test`, route smoke-tests, scaffolds with deterministic '
      'output) saved to .lumen/tools/, or a SKILL (a written '
      'convention — design system rules, code style, domain '
      'knowledge) saved to .lumen/skills/.';
  static const String manualSkillName = 'What do you want the agent to do?';
  static const String manualSkillNameHint =
      'e.g. "Validate routes", "Keep dashboard layout consistent", "Run focused tests"';
  static const String manualSkillDetails = 'Details';
  static const String manualSkillDetailsHint =
      'Describe it in plain language. For tools — known commands, '
      'arguments, safety notes. For skills — design tokens, layout '
      'rules, naming conventions, examples. The LLM will pick the '
      'right shape.';
  static const String manualSkillCreate = 'Create';
  static const String manualSkillNoWorkspace =
      'Open a workspace before creating a skill or tool.';
  static const String skillsNoLlmTitle = 'No LLM connected';
  static const String skillsNoLlmBody =
      'Lumen can auto-generate a starter tool set (build, test, '
      'format, etc.) for new projects when an LLM is configured. '
      'Set one up in Settings and re-open this project to use the '
      'feature later.';
  static const String skillsCreatedHeader = 'Created';
  static const String skillsCreatedToolsLabel = 'Tools (.lumen/tools/*.json)';
  static const String skillsCreatedSkillsLabel = 'Skills (.lumen/skills/*.md)';
  static const String skillsRejectedHeader = 'Skipped (validation failed)';
  static const String skillsErrorHeader = 'Generation failed';

  // Syncthing — about/why blurb in Settings.
  static const String settingsSyncthingAboutTitle = 'About Syncthing';
  static const String settingsSyncthingAboutBody =
      'Syncthing is a free, open-source peer-to-peer file sync tool. '
      'It keeps the same files in sync across your devices over your '
      'local network (or the internet) — no cloud account, no '
      'subscription, nothing leaves your own machines.';
  static const String settingsSyncthingLinkLabel = 'syncthing.net';

  // Ollama onboarding (new-project wizard step). Detects whether the
  // `ollama` CLI is installed and the local API is reachable, and
  // walks the user through download/run/pull/signin if anything is
  // missing.
  static const String ollamaSetupTitle = 'Set up Ollama for local LLMs';
  static const String ollamaSetupBody =
      'Ollama runs open-weights models locally on your machine — '
      'private, offline, no API key. Lumen can use it as a chat '
      'provider alongside any cloud providers you add later.';
  static const String ollamaSetupChecking = 'Checking for Ollama…';
  static const String ollamaSetupCheck = 'Check for Ollama';
  static const String ollamaSetupRetry = 'Retry check';
  static const String ollamaSetupSkip = 'Skip';
  static const String ollamaSetupContinue = 'Continue';
  // States.
  static const String ollamaStateReadyTitle = 'Ollama is ready';
  static const String ollamaStateReadyBody =
      'The Ollama daemon responded on localhost. Lumen will surface '
      'every model you have pulled in the chat picker.';
  static const String ollamaStateInstalledNotRunningTitle =
      'Ollama is installed but not running';
  static const String ollamaStateInstalledNotRunningBody =
      'The `ollama` CLI is on your PATH but the local API at '
      'http://localhost:11434 didn\'t respond. Start the Ollama '
      'desktop app (or run `ollama serve` in a terminal), then hit '
      'Retry check.';
  static const String ollamaStateMissingTitle = 'Ollama is not installed';
  static const String ollamaStateMissingBody =
      'Lumen couldn\'t find the `ollama` CLI on your PATH. Install '
      'it from the link below — it\'s a one-click installer on every '
      'platform — and come back to this wizard when it\'s done.';
  static const String ollamaDownloadLabel = 'ollama.com/download';
  // Post-install / next-step tips.
  static const String ollamaNextStepsTitle = 'Once Ollama is installed';
  static const String ollamaNextStepLocal =
      'Pull a local model from a terminal:';
  static const String ollamaNextStepLocalCmd =
      'ollama pull llama3.1   # or any model you want';
  static const String ollamaNextStepCloudIntro =
      'For Ollama Cloud (turbo / hosted) models you also need to '
      'sign in once with your account so Lumen can reach the cloud '
      'endpoints:';
  static const String ollamaNextStepCloudCmd = 'ollama signin';
  static const String ollamaNextStepCloudHint =
      'Run that in a real terminal — the prompt opens a browser '
      'window for SSO. Lumen can\'t do this for you because the '
      'browser hand-off has to happen against your own session.';
  static const String ollamaCopyCommand = 'Copy';
  static const String ollamaCopiedToast = 'Command copied to clipboard.';

  // LLM providers onboarding (new-project wizard step). Lets a
  // first-time user paste API keys for each cloud provider next to a
  // toggle that enables it. Mirrors the Settings screen but stripped
  // down to the fields that matter on day one.
  static const String llmProvidersTitle = 'Connect LLM providers';
  static const String llmProvidersBody =
      'Lumen aggregates models from multiple providers. Toggle on '
      'the ones you want to use and paste their API keys — you can '
      'always change these later in Settings → AI / Chat.';
  static const String llmProvidersSkip = 'Skip';
  static const String llmProvidersSave = 'Save & continue';
  static const String llmProvidersSavedToast = 'Provider settings saved.';
  static const String llmProvidersOllamaHint =
      'Local daemon AND/OR Ollama Cloud key. Both can run side-by-side '
      '— local models come from your machine, cloud models stream from '
      'ollama.com.';
  static const String llmProvidersOllamaEndpointLabel = 'Local endpoint';
  static const String llmProvidersOllamaCloudKeyLabel = 'Cloud API key';
  static const String llmProvidersOllamaCloudKeyHint =
      'Paste an Ollama Cloud key (optional)…';
  static const String llmProvidersGeminiHint =
      'Get a free API key at aistudio.google.com.';
  static const String llmProvidersClaudeHint =
      'Get an API key at console.anthropic.com.';
  static const String llmProvidersGithubHint =
      'GitHub PAT with the Models: read scope (NOT GitHub Copilot).';
  static const String llmProvidersOpenaiHint =
      'OpenAI placeholder — saved for when the integration ships.';
  static const String llmProvidersApiKeyHint = 'Paste API key…';
  static const String llmProvidersAlreadySetSuffix = ' (already set)';

  // GitNexus onboarding (new-project wizard step).
  static const String gitnexusTitle = 'Set up GitNexus?';
  static const String gitnexusBody =
      'GitNexus builds a knowledge graph of your code that the AI '
      'agent can query to navigate, refactor, and reason about the '
      'project more accurately. Setup runs `npx gitnexus analyze` '
      'in your workspace — no global install, no API key required '
      'for the basic index. We\'ll initialize git first if needed.';
  static const String gitnexusRequirements =
      'Requires Node.js on PATH (for npx). Skip and install later '
      'if you don\'t have it.';
  static const String gitnexusSetUp = 'Set up GitNexus';
  static const String gitnexusSkip = 'Skip';
  static const String gitnexusDone = 'Done';
  static const String gitnexusRetry = 'Retry';
  static const String gitnexusCheckingNode = 'Checking Node.js…';
  static const String gitnexusInitGit = 'Initializing git…';
  static const String gitnexusRunningAnalyze =
      'Running `npx gitnexus analyze` — first run downloads the '
      'package, may take a minute.';
  static const String gitnexusNoNodeTitle = 'Node.js not found';
  static const String gitnexusNoNodeBody =
      'GitNexus runs via `npx`, which needs Node.js on your PATH. '
      'Install Node from nodejs.org and re-open this project to '
      'set up GitNexus then.';
  static const String gitnexusSuccessTitle = 'GitNexus ready';
  static const String gitnexusErrorTitle = 'Setup failed';
  static const String gitnexusAnalyzeNow = 'Analyze now';
  static const String gitnexusReanalyze = 'Re-analyze';
  static const String gitnexusStop = 'Stop';
  static const String gitnexusClean = 'Clean index';
  static const String gitnexusOpenSettings = 'GitNexus settings';
  static const String gitnexusStatusNoWorkspace = 'No workspace open';
  static const String gitnexusStatusNoNode = 'Node.js / npx missing';
  static const String gitnexusStatusNotIndexed = 'Not indexed';
  static const String gitnexusStatusIndexed = 'Indexed';
  static const String gitnexusStatusRunning = 'Indexing…';
  static const String gitnexusStatusFailed = 'Last run failed';
  static const String gitnexusSettingsDesc =
      'Run GitNexus as a hidden background job and inspect the files it installs for agent context.';
  static const String gitnexusMissingNodeHelp =
      'GitNexus runs through npx. Install Node.js from nodejs.org, restart Lumen, then analyze again.';
  static const String gitnexusInstalledFiles = 'Installed context files';
  static const String gitnexusOutput = 'Last output';
  static const String gitnexusAnalyzeOutputLabel = 'Analyze output';
  static const String gitnexusWikiSection = 'Wiki';
  static const String gitnexusWikiTitle = 'Code wiki';
  static const String gitnexusWikiDesc =
      'Generate LLM-powered module documentation from the GitNexus graph. '
      'This may use API credits depending on your GitNexus LLM config.';
  static const String gitnexusWikiGenerate = 'Generate wiki';
  static const String gitnexusWikiStop = 'Stop wiki';
  static const String gitnexusWikiOpenFolder = 'Open wiki folder';
  static const String gitnexusWikiModelLabel = 'Model override';
  static const String gitnexusWikiModelHint = 'leave empty for default';
  static const String gitnexusWikiAuto = 'Auto-regenerate after re-index';
  static const String gitnexusWikiAutoDesc =
      'When enabled, a successful Analyze run automatically starts '
      '`npx gitnexus wiki`. Leave off unless you are comfortable spending '
      'LLM tokens on wiki refreshes.';
  static const String gitnexusWikiOutputLabel = 'Wiki output';
  static const String gitnexusWikiNoWorkspace =
      'Open a workspace before generating a wiki.';
  static const String gitnexusWikiIdle = 'Idle';
  static const String gitnexusWikiRunning = 'Generating...';
  static const String gitnexusWikiGenerated = 'Generated';
  static const String gitnexusWikiFailed = 'Failed';
  static const String gitnexusWikiNoOutput = '(no output yet)';
  static String gitnexusWikiGeneratedAt(String value) => 'Generated $value';

  // Master kill-switch.
  static const String gitnexusMasterToggleTitle = 'Enable GitNexus integration';
  static const String gitnexusMasterToggleDesc =
      'Lets Lumen index this workspace, attach to a running '
      '`gitnexus serve`, and surface the activity-bar icon. Turn this '
      'off to silence GitNexus completely — no port probe, no icon, '
      'no auto-attach. Existing servers started before disabling are '
      'left alone; you can stop them manually.';
  static const String gitnexusDisabledPlaceholder =
      'GitNexus integration is off. No port is probed, the activity-bar '
      'icon is hidden, and the new-project wizard skips the GitNexus '
      'step. Flip the switch above to bring everything back.';

  // Background daemons (gitnexus serve / mcp).
  static const String gitnexusServicesSection = 'Background services';
  static const String gitnexusServicesDesc =
      'Lumen runs `npx gitnexus analyze` as a one-shot indexer when you '
      'set up a project. The serve daemon below is machine-wide — one '
      'instance covers every Lumen window and every indexed repo on '
      'this machine. The MCP toggle is per-window and rarely needed.';
  static const String gitnexusServeTitle = 'HTTP server (gitnexus serve)';
  static const String gitnexusServeDesc =
      'Local HTTP daemon on 127.0.0.1:4747. Serves all indexed '
      'repositories on this machine to the gitnexus.vercel.app web UI. '
      'Shared across every Lumen window — starting it once is enough.';
  static const String gitnexusMcpTitle = 'MCP server (gitnexus mcp)';
  static const String gitnexusMcpDesc =
      'Stdio MCP server, scoped to this Lumen window. Most AI hosts '
      '(Claude Desktop, Cursor) spawn their own on demand, so you '
      'rarely need this toggle. Useful only if you want a warm server '
      'for an external tool that attaches over stdio.';
  static const String gitnexusServeStart = 'Start serve';
  static const String gitnexusServeStop = 'Stop serve';
  static const String gitnexusMcpStart = 'Start MCP server';
  static const String gitnexusMcpStop = 'Stop MCP server';
  static const String gitnexusServeStopped = 'Stopped';
  static const String gitnexusServeStarting = 'Starting…';
  static const String gitnexusServeRunningAdoptedLabel =
      'Running (machine-wide)';
  static const String gitnexusServeAdoptedHint =
      'Started by another Lumen window or external process. Turning '
      'this off here stops the server for every window and any web UI '
      'session connected to it.';
  static const String gitnexusServeStopMachineWide =
      'Stop serve (machine-wide)';
  static const String gitnexusMcpRunningTooltip = 'MCP server running';
  static String gitnexusServeRunningOn(int port) => 'serve · 127.0.0.1:$port';
  static String gitnexusServeRunningOnAdopted(int port) =>
      'serve · 127.0.0.1:$port (shared)';
  static const String gitnexusServeOutputLabel = 'Serve output';
  static const String gitnexusMcpOutputLabel = 'MCP output';
  static const String gitnexusDaemonNoWorkspace =
      'Open a workspace before starting this service.';
  static const String menuOpenMediaFromChat =
      'Open media controls from the chat header.';

  // Command palette / quick open / global search
  static const String paletteHint = 'Type a command or > for help…';
  static const String paletteNoResults = 'No matching commands';
  static const String quickOpenHint = 'Search files by name…';
  static const String quickOpenIndexing = 'Indexing workspace…';
  static const String quickOpenNoResults = 'No matching files';
  static const String globalSearchHint = 'Search across files…';
  static const String globalSearchNoResults = 'No results';
  static const String globalSearchSearching = 'Searching…';
  static const String globalSearchMatches = 'matches';
  static const String globalSearchInFiles = 'in';
  static const String globalSearchFiles = 'files';

  // About
  static const String aboutLegalese = 'Built with Flutter.';

  // Explorer
  static const String explorerNewFolder = 'New Folder';
  static const String explorerNewFile = 'New File';
  static const String explorerRefresh = 'Refresh';
  static const String explorerCopyPath = 'Copy Path';
  static const String explorerCopyRelativePath = 'Copy Relative Path';
  static const String explorerRevealInOs = 'Reveal in File Explorer';
  static const String explorerOpenInTerminal = 'Open in Terminal Here';
  static const String explorerDeleteConfirmTitle = 'Delete?';
  static const String explorerDeleteConfirmBody =
      'This action cannot be undone.';
  // New delete-confirmation dialog (per-kind copy + path display).
  // Title is contextual — "Delete file" vs "Delete folder" — so the
  // user reads exactly what's about to disappear before hitting
  // Enter on the autofocused destructive button.
  static const String explorerDeleteFileTitle = 'Delete file?';
  static const String explorerDeleteFolderTitle = 'Delete folder?';
  static const String explorerDeleteFileBody =
      'This will permanently delete the file from disk.';
  static const String explorerDeleteFolderBody =
      'This will permanently delete the folder and EVERYTHING inside '
      'it — recursively. There is no recycle bin step.';
  static const String explorerDeleteUndoHint =
      'Note: agent-tool edits are tracked in the timeline and can be '
      'restored from there. Deletes through this dialog are not.';
  static const String explorerNewFileTitle = 'New File';
  static const String explorerNewFolderTitle = 'New Folder';
  static const String explorerRenameTitle = 'Rename';
  static const String explorerNamePlaceholder = 'Name';
  static const String explorerMoveDestinationExists =
      'A file or folder with that name already exists in the destination.';
  static const String explorerMoveIntoSelf =
      'Cannot move a folder into itself or one of its subfolders.';
  static const String explorerMoveFailed = 'Move failed';
  static const String explorerCopyIntoSelf =
      'Cannot copy a folder into itself or one of its subfolders.';
  static const String explorerCopiedToClipboard = 'Copied to clipboard.';
  static const String explorerCopyToClipboardFailed =
      'Copied inside Lumen, but the OS clipboard was unavailable.';
  static const String explorerPasteFailed = 'Paste failed';
  static const String explorerUndoNothing = 'Nothing to undo in the explorer.';
  static const String explorerRedoNothing = 'Nothing to redo in the explorer.';
  static const String explorerUndoFailed = 'Explorer undo failed';
  static const String explorerRedoFailed = 'Explorer redo failed';
  static const String explorerUndoMove = 'Undid file move.';
  static const String explorerRedoMove = 'Redid file move.';
  static const String explorerUndoCreate = 'Undid file creation.';
  static const String explorerRedoCreate = 'Redid file creation.';
  static const String explorerUndoCopy = 'Undid file copy.';
  static const String explorerRedoCopy = 'Redid file copy.';
  static const String explorerUndoDestinationExists =
      'Cannot undo because something already exists at the original path.';
  static const String explorerRedoDestinationExists =
      'Cannot redo because something already exists at the destination path.';
  static const String explorerUndoSourceMissing =
      'Cannot undo because the moved item is missing.';
  static const String explorerRedoSourceMissing =
      'Cannot redo because the original item is missing.';

  // Slash commands
  static const String slashHandoffDescription =
      'Write a chat-to-chat handoff so a fresh chat can pick up where you left off.';
  static const String slashHandoffNoWorkspace =
      'Open a workspace before creating a handoff.';
  static const String slashHandoffRuleInstalled =
      'Installed handoff receive rule in .lumen/rules.md';

  static const String slashPushDescription =
      'Stage everything, commit with a message, and push to the remote.';
  static const String slashPushUsage =
      'Usage: /push <commit message> — message is required.';
  static const String slashPushNoWorkspace = 'Open a workspace before pushing.';
  static const String slashPushNotRepo =
      'This workspace is not a git repository.';
  static const String slashPushStarting = 'Pushing…';
  static const String slashPushNothingToCommit =
      'Nothing to commit — working tree is clean.';
  static const String slashPushCommitFailed = 'Commit failed';
  static const String slashPushPushFailed = 'Push failed';
  static const String slashPushDone = 'Pushed.';

  // Editor
  static const String editorNoFileOpen = 'No file open';
  static const String editorSaved = 'Saved';
  static const String editorUnsaved = 'Unsaved changes';
  static const String editorLanguage = 'Language';
  static const String editorAutoDetect = 'Auto-detect';
  static const String editorWordWrap = 'Word Wrap';
  static const String editorFindInFile = 'Find in File';
  static const String editorFindPlaceholder = 'Find';
  static const String editorFindPrevious = 'Previous match';
  static const String editorFindNext = 'Next match';
  static const String editorFindCaseSensitive = 'Match Case';
  static const String editorFindRegex = 'Use Regular Expression';
  static const String editorFindToggleReplace = 'Toggle Replace';
  static const String editorFindClose = 'Close Find';
  static const String editorFindNoResults = 'No results';
  static const String editorReplacePlaceholder = 'Replace';
  static const String editorReplace = 'Replace';
  static const String editorReplaceAll = 'Replace All';
  static const String editorLineCol = 'Ln';
  static const String editorColCol = 'Col';
  static const String editorMarkdownPreview = 'Markdown Preview';
  static const String editorEditMode = 'Edit';
  static const String editorSplitView = 'Split Editor';
  static const String editorUnsplitView = 'Unsplit Editor';
  static const String editorSelectFileForPane =
      'Select a file tab for this pane';

  // Terminal
  static const String terminalHeader = 'TERMINAL';
  static const String terminalNew = 'New Terminal';
  static const String terminalKill = 'Kill Terminal';
  static const String terminalCopyToChat = 'Copy to Chat';
  static const String terminalCopyToChatToast =
      'Terminal output copied to AI chat.';
  static const String terminalNoOutput =
      'No text available to copy from terminal.';
  static const String terminalFallback =
      'PTY unavailable, using basic shell fallback.';
  static const String terminalShell = 'Shell';
  static const String terminalShellSwitched =
      'Switched to a working shell — your previous choice could not start.';
  static const String terminalNoActive = 'No active terminal';
  static const String terminalContextCopy = 'Copy';
  static const String terminalContextPaste = 'Paste';
  static const String terminalContextClear = 'Clear';
  static const String terminalContextCopyToChat = 'Copy to Chat';
  static const String terminalContextOpenUrl = 'Open URL in browser';
  static const String terminalUrlHint = 'Ctrl+Click URLs to open';
  static const String terminalCopyHint =
      'Ctrl+Shift+C copies, Ctrl+Shift+V pastes';
  static const String terminalShellResetDefault = 'Reset to default';
  static const String terminalShellResetDone =
      'Shell preference cleared — using best available shell.';
  static const String terminalSplitView = 'Split Terminal';
  static const String terminalUnsplitView = 'Unsplit Terminal';
  // Agent-spawned terminals (RUN_CMD via the agent terminal bridge).
  // The prefix is concatenated with a truncated command in
  // `AgentTerminalBridge._deriveTitle` so a `npm run dev` invocation
  // surfaces in the tab strip as `agent: npm run dev`.
  static const String terminalAgentPrefix = 'agent: ';

  // Chat
  static const String chatHeader = 'AI ASSISTANT';
  static const String chatPlaceholder = 'Ask the agent to code...';
  static const String chatStop = 'Stop Generation';
  static const String chatAutoApproveOnTooltip =
      'Auto-approve: ON — agent runs every gated command without '
      'asking. Click to require permission per call.';
  static const String chatAutoApproveOffTooltip =
      'Auto-approve: OFF — agent asks before each gated command. '
      'Click to auto-approve all.';
  // Short label for the auto-approve toggle pill in the chat input
  // row. Lower-cased on purpose — this is a chrome control, not a
  // shouting all-caps banner.
  static const String chatAutoApproveLabel = 'auto-approve';

  // Reasoning-effort dial — sits next to the auto-approve pill in the
  // chat composer. Off / Standard / Deep maps to native API knobs on
  // Claude 4+, Gemini 2.5, gpt-5/o-series; on older / local models it
  // falls back to a system-prompt directive.
  static const String chatEffortLabelOff = 'thinking: off';
  static const String chatEffortLabelStandard = 'thinking: standard';
  static const String chatEffortLabelDeep = 'thinking: deep';
  static const String chatEffortLabelOffCompact = 'off';
  static const String chatEffortLabelStandardCompact = 'std';
  static const String chatEffortLabelDeepCompact = 'deep';
  static const String chatEffortTooltipOffNative =
      'Thinking: OFF — model answers without extended reasoning. '
      'Click to cycle.';
  static const String chatEffortTooltipStandardNative =
      'Thinking: STANDARD — model spends a moderate budget on internal '
      'reasoning before replying. Click to cycle.';
  static const String chatEffortTooltipDeepNative =
      'Thinking: DEEP — model spends a large budget on internal '
      'reasoning before replying. Slower, more thorough. Click to cycle.';
  static const String chatEffortTooltipOffPrompt =
      'Thinking: OFF — current model has no native reasoning param, '
      'no prompt nudge added. Click to cycle.';
  static const String chatEffortTooltipStandardPrompt =
      'Thinking: STANDARD (prompt-only) — current model has no native '
      'reasoning param, so this just adds a "be careful" directive to '
      'the system prompt. Click to cycle.';
  static const String chatEffortTooltipDeepPrompt =
      'Thinking: DEEP (prompt-only) — current model has no native '
      'reasoning param, so this just adds a "slow down and verify" '
      'directive to the system prompt. Click to cycle.';

  // Binary preview pane — shown in the editor area when a non-text
  // file is opened (image / audio / video / archive / executable).
  // The pane replaces the code editor for these tabs because
  // readAsString on a JPG throws `Failed to decode data using
  // encoding 'utf-8'` and dumping the exception text into the
  // editor body is hostile.
  static const String binaryPreviewKindImage = 'Image';
  static const String binaryPreviewKindAudio = 'Audio';
  static const String binaryPreviewKindVideo = 'Video';
  static const String binaryPreviewKindBinary = 'Binary file';
  static const String binaryPreviewExplainer =
      'Lumen can\'t render this format inline. Open it in your OS '
      'default app, or reveal it in the file manager.';
  static const String binaryPreviewOpenExternally = 'Open in default app';
  static const String binaryPreviewRevealInOs = 'Reveal in OS';
  static const String binaryPreviewOpenFailed = 'Could not open file';
  static const String binaryPreviewRevealFailed = 'Could not reveal file';
  static const String binaryPreviewImageDecodeFailed = 'Could not decode image';
  static const String chatNewSession = 'New chat';
  static const String chatHistory = 'History';
  static const String chatCloseTab = 'Close tab';
  static const String chatHistoryEmpty = 'No saved chats yet';
  static const String chatNoOpenTabs = 'No chat open. Click + to start.';

  // Empty-state placeholder shown in the chat panel body when every
  // tab has been closed. Replaces the message list + composer with
  // a centered card so the user has a clear "what now?" landing
  // instead of a stranded empty input box.
  static const String chatEmptyHeading = 'No chat open';
  static const String chatEmptySubtitle =
      'Start a new conversation with Lumen — ask about the code in this '
      'workspace, kick off an agent task, or just think out loud.';
  static const String chatEmptyNewChat = 'New chat';
  static const String chatEmptyNewChatTooltip =
      'Open a fresh chat tab in this workspace';
  static const String chatAttachImage = 'Attach Image';
  static const String chatAttachFile = 'Attach File';
  static const String chatSend = 'Send';
  static const String chatModel = 'Model';
  static const String chatModelPanelTitle = 'Select Model';
  static const String chatModelManageTitle = 'Manage Models';
  static const String chatModelViewAll = 'View all models';

  /// Popup-menu entry that re-polls every enabled provider for its
  /// current model list. Useful when the user pulled a new Ollama
  /// model (or ran `ollama signin`) outside the app and doesn't
  /// want to leave the chat panel just to refresh the picker.
  static const String chatModelRefresh = 'Refresh models';

  /// Toast confirmation shown after a successful refresh, with the
  /// post-refresh model count substituted for `%d`.
  static const String chatModelRefreshedToast =
      'Models refreshed (%d available)';
  static const String chatModelProvidersTitle = 'Providers';
  static const String chatModelProviderModelsTitle = 'Provider Models';
  static const String chatModelEnableAll = 'Enable all';
  static const String chatModelDisableAll = 'Disable all';
  static const String chatNoModels = 'No models available';

  /// Short label rendered inline next to a high-hallucination-risk
  /// model in the picker (chip + dropdown row). Kept under 32 chars
  /// so it fits next to the model chip without pushing the composer
  /// chrome around.
  static const String chatModelHallucinationRiskShort = 'May hallucinate tools';

  /// Longer tooltip / banner copy explaining the risk and pointing
  /// the user at known-reliable alternatives. Surfaced on hover of
  /// the warning icon on the model chip and as the popup-menu
  /// tooltip for risky entries.
  static const String chatModelHallucinationRiskTooltip =
      'This model has a known pattern of fabricating tool execution — '
      'emitting fake tool_result blocks or malformed tool syntax. '
      'Lumen detects and aborts the cascade, but agentic tasks may '
      'still fail to complete. For reliable tool use, prefer Claude '
      '(any), GPT-OSS-120b cloud, or Qwen3-Coder-480b cloud.';
  static const String chatOpenAiSettings = 'Open AI / Chat settings';
  static const String chatEditMessage = 'Edit Message';
  static const String chatDeleteMessage = 'Delete Message';
  static const String chatRegenerate = 'Regenerate';
  static const String chatYou = 'You';
  static const String chatAgent = 'Lumen Agent';
  static const String chatMediaPlayer = 'MEDIA PLAYER';
  static const String chatWatchMedia = 'Watch Media';
  static const String chatOpenInBrowser = 'Open in browser';
  static const String chatAddReference = 'Add to Chat';
  static const String chatReferenceAdded = 'Added to chat.';
  static const String chatReferenceMissing = 'Reference no longer exists.';
  static const String chatReferences = 'References';
  static String chatReferencesAttached(int count) =>
      count == 1 ? '1 reference attached' : '$count references attached';
  static const String chatImagePasted = 'Pasted image from clipboard.';
  static const String chatEnterMediaUrl = 'Watch media';
  static const String chatEnterMediaHint = 'YouTube / Twitch / any URL';
  static const String chatPlay = 'Play';

  // Media chrome controls.
  static const String mediaMute = 'Mute';
  static const String mediaUnmute = 'Unmute';
  static const String mediaZoomIn = 'Zoom in';
  static const String mediaZoomOut = 'Zoom out';

  // Watch-media modal — placement chooser.
  static const String mediaPlacementLabel = 'WHERE';
  static const String mediaPlacementChat = 'In chat';
  static const String mediaPlacementChatDesc =
      'Top of chat panel. Scales 16:9 with chat width.';
  static const String mediaPlacementEditor = 'Split editor';
  static const String mediaPlacementEditorDesc =
      'Right of the editor area as a draggable split pane.';
  static const String mediaTeamsForcesChat =
      'Teams is already using the editor split, so this media will open in the chat panel.';

  // Editor tab context menu.
  static const String tabClose = 'Close';
  static const String tabCloseAll = 'Close All';
  static const String tabCloseOthers = 'Close Others';
  static const String tabCloseToTheRight = 'Close to the Right';
  static const String tabSplitLeft = 'Split Left';
  static const String tabSplitRight = 'Split Right';
  static String chatImagesAttached(int count) =>
      count == 1 ? '1 image attached' : '$count images attached';

  // In-chat image lightbox (click any chat image to open).
  static const String imageLightboxCloseTooltip = 'Close';
  static const String imageLightboxResetTooltip = 'Reset zoom';
  static const String imageLightboxOpenHint = 'Click to view full size';

  // Tool approval
  static const String toolApprovalTitle = 'Agent wants to run a command';
  static const String toolApprovalAccept = 'Accept';
  static const String toolApprovalAllowOnce = 'Allow once';
  static const String toolApprovalAllowAlways = 'Allow always';
  static const String toolApprovalAlwaysRun = 'Always run';
  static const String toolApprovalDeny = 'Deny';
  static const String toolApprovalAutoApprovedAll =
      'Auto-approving all tool calls (toggle off in menu).';

  // Per-tool blanket approvals (Settings → AI/Chat).
  static const String settingsAutoApprovedToolsLabel = 'Always-allowed tools';
  static const String settingsAutoApprovedToolsDesc =
      'Tools you\'ve granted blanket approval. Click \u00d7 to revoke '
      'a single tool, or Clear all to reset.';
  static const String settingsAutoApprovedNone =
      'None yet — clicking "Always run" or "Always allow" on an '
      'approval card adds a tool here.';
  static const String settingsAutoApprovedClearAll = 'Clear all';
  static const String settingsAutoApprovedRevoke = 'Revoke';

  // Tool registry / external plugins
  static const String toolsActiveHeader = 'Active Tools';
  static const String toolsBuiltinSection = 'Built-in';
  static const String toolsExternalSection = 'External';
  static const String toolsExternalChip = 'external';
  static const String toolsNoExternal =
      'Drop JSON tool definitions in .lumen/tools/ to add more.';

  // Skills section (instruction-based markdown skills) — distinct
  // from tools above. Tools are commands the agent runs; skills are
  // conventions the agent reads and follows.
  static const String skillsActiveHeader = 'Active Skills';
  static const String skillsToolDistinction =
      'Skills are markdown instruction sets (.lumen/skills/*.md) the '
      'agent reads and follows. They are distinct from tools above '
      '(commands the agent invokes). Toggle off any skill you don\'t '
      'want injected into the system prompt.';
  static const String skillsNoneYet =
      'No skills yet. Drop markdown files in .lumen/skills/ or use '
      '"Create Agent Skill or Tool" to generate one.';
  static const String skillsAlwaysOnLabel = 'always';
  static const String skillsTriggerPrefix = 'Apply when: ';
  static const String skillsOpenInEditor = 'Open file';
  static const String skillsScopeWorkspace = 'workspace';
  static const String skillsScopeGlobal = 'global';
  static const String toolPendingCreate = 'Creating';
  static const String toolPendingEdit = 'Editing';
  static const String toolPendingDelete = 'Deleting';
  static const String toolPendingMove = 'Moving';
  static const String toolPendingRead = 'Reading';
  static const String toolPendingRun = 'Running';
  static const String toolPendingAppend = 'Appending';
  static const String toolPendingSearch = 'Searching';
  static const String toolPendingInspect = 'Inspecting';

  /// Single-line label for a malformed-tool warning card. Surfaced
  /// when the parser detected a tool-shaped block (`<<<EDIT_FILE…>>>`)
  /// but the inner structure rejected the strict per-tool regex.
  static const String toolMalformedLabel = 'Malformed';
  static const String toolMalformedTitle = 'Tool call malformed';
  static String toolMalformedTooltip(String toolName) =>
      'The model emitted $toolName but the call structure is invalid, '
      'so it was not executed. Ask the model to retry — or switch to '
      'a stronger model if it keeps producing the same shape.';

  /// Header label for a collapsed run of consecutive same-action
  /// tool calls — e.g. "Read 12 files", "Searched 5 times". The
  /// `action` argument is the past-tense verb [_actionLabel] would
  /// have produced for a single call.
  static String toolGroupTitle(String action, int count) {
    if (action.toLowerCase() == 'read') {
      return 'Read $count files';
    }
    if (action.toLowerCase() == 'edited') {
      return 'Edited $count files';
    }
    if (action.toLowerCase() == 'created') {
      return 'Created $count files';
    }
    if (action.toLowerCase() == 'listed') {
      return 'Listed $count directories';
    }
    if (action.toLowerCase() == 'searched') {
      return 'Searched $count times';
    }
    if (action.toLowerCase() == 'found') {
      return 'Found across $count queries';
    }
    if (action.toLowerCase() == 'glob') {
      return 'Globbed $count patterns';
    }
    return '$action $count×';
  }

  // Settings
  static const String settingsTitle = 'Settings';
  static const String settingsLlmProvider = 'LLM Provider';
  static const String providerOllama = 'Ollama';
  // Display label for the `ollama-cloud:` provider namespace —
  // models surfaced via the Ollama Cloud API key path. Separate
  // tab from `Ollama` (local daemon) in Model Management so the
  // user can flip whole groups on/off independently.
  static const String providerOllamaCloud = 'Ollama Cloud';
  static const String providerGemini = 'Gemini';
  static const String providerClaude = 'Claude';
  static const String providerGithub = 'GitHub Models';
  static const String providerOpenAI = 'OpenAI';
  static const String settingsEndpointUrl = 'Endpoint URL';
  static const String settingsApiKey = 'API Key';
  static const String settingsSaved = 'Settings saved.';
  static const String settingsAutoApprove = 'Auto-approve agent commands';
  static const String settingsAutoApproveDesc =
      'Skip the confirmation dialog when the agent runs shell commands.';
  static const String settingsTheme = 'Editor Theme';
  static const String settingsFontSize = 'Editor Font Size';
  static const String settingsTabSize = 'Tab Size';
  static const String settingsWordWrap = 'Word Wrap';
  static const String settingsAppearanceSection = 'Appearance';
  static const String settingsReduceMotion = 'Reduce motion';
  static const String settingsReduceMotionDesc =
      'Skip transition animations across menus, dialogs and tabs.';
  static const String settingsReduceTransparency = 'Reduce transparency';
  static const String settingsReduceTransparencyDesc =
      'Replace glassmorphism panels with flat dark surfaces. Easier on weak GPUs and laptops on battery.';

  // Settings view — categories
  static const String settingsCatGeneral = 'General';
  static const String settingsCatEditor = 'Editor';
  static const String settingsCatTheme = 'Theme';
  static const String settingsCatTerminal = 'Terminal';
  static const String settingsCatAI = 'AI / Chat';
  static const String settingsCatModelManagement = 'Model Management';
  static const String settingsCatRules = 'Rules';
  static const String settingsCatGitNexus = 'GitNexus';
  static const String settingsCatKeys = 'Keyboard Shortcuts';
  static const String settingsCatTools = 'Agent Skills & Tools';

  // Settings view — General
  static const String settingsLlmProviderDesc =
      'Enable the backends you want to use. Models from all enabled providers appear in the chat model picker.';
  static const String settingsOllamaSection = 'Ollama';
  static const String settingsOllamaEndpointDesc =
      'Base URL for the local Ollama daemon. Leave default unless '
      'you run ollama on a different host or port.';
  static const String settingsOllamaCloudKeyLabel = 'Cloud API key';
  static const String settingsOllamaCloudKeyDesc =
      'Optional. With a key from ollama.com/settings/keys, Lumen also '
      'fetches cloud models directly from ollama.com — no local '
      'daemon required. Both paths run side-by-side; cloud-tagged '
      'models prefer the API-key route when set.';
  static const String settingsGeminiSection = 'Google Gemini';
  static const String settingsGeminiApiKeyDesc =
      'Get one at aistudio.google.com.';
  static const String settingsClaudeSection = 'Anthropic Claude';
  static const String settingsClaudeApiKeyDesc =
      'API key for Anthropic Claude. Models are fetched from the Anthropic Models API.';
  static const String settingsGithubSection = 'GitHub Models';
  static const String settingsGithubApiKeyDesc =
      'GitHub personal access token with the Models: read permission. This is GitHub Models inference API, NOT GitHub Copilot.';
  static const String settingsGithubOpenTokens = 'Open token settings';
  static const String settingsGithubTestBtn = 'Test connection';
  static const String settingsGithubTestingBtn = 'Testing...';
  static const String settingsGithubOrgLabel = 'Organization (optional)';
  static const String settingsGithubOrgDesc =
      'GitHub org login slug (the URL slug of your organization). When set, inference is billed to your org\'s GitHub Models paid plan and unlocks paid models like gpt-5. Leave blank to use your personal free tier.';
  static const String settingsGithubOrgHint = 'org-login-slug';
  static const String settingsGithubResetHiddenLabel = 'Hidden models';
  static const String settingsGithubResetHiddenDesc =
      'GitHub\'s catalog lists models that aren\'t actually wired to inference yet. When one returns "unavailable_model", Lumen hides it from the picker. Use this to clear that local list (e.g. when GitHub rolls a model out).';
  static const String settingsGithubResetHiddenBtn = 'Reset hidden list';
  static const String settingsGithubResetHiddenDone =
      'Hidden list cleared. Save to refresh the picker.';
  static const String settingsOpenAISection = 'OpenAI';
  static const String settingsOpenAIApiKeyDesc =
      'API key for OpenAI (coming soon).';
  static const String settingsAutoSave = 'Auto-save on focus loss';
  static const String settingsAutoSaveDesc =
      'Automatically save files when the editor loses focus.';
  static const String settingsConfirmClose = 'Confirm before close';
  static const String settingsConfirmCloseDesc =
      'Show a confirmation dialog before closing the workspace.';
  static const String settingsLanguage = 'Language';
  static const String settingsLanguageDesc =
      'Display language for the IDE interface.';

  // Settings view — Editor
  static const String settingsShowLineNumbers = 'Show line numbers';
  static const String settingsShowLineNumbersDesc =
      'Display line numbers in the editor gutter.';
  static const String settingsMinimap = 'Minimap';
  static const String settingsMinimapDesc =
      'Show a minimap overview of the file (coming soon).';
  static const String settingsWordWrapDesc =
      'Wrap long lines instead of horizontal scrolling.';
  static const String settingsFontSizeDesc =
      'Font size for the code editor in pixels.';
  static const String settingsTabSizeDesc =
      'Number of spaces per tab indentation.';

  // Settings view — Theme
  static const String settingsUiMode = 'UI Mode';
  static const String settingsUiModeDesc =
      'Dark mode only for now. More modes coming soon.';

  // Settings view — Terminal
  static const String settingsTermFontSize = 'Terminal font size';
  static const String settingsTermFontSizeDesc =
      'Font size for the integrated terminal.';
  static const String settingsTermShell = 'Shell path';
  static const String settingsTermShellDesc =
      'Override the default shell executable.';
  static const String settingsTermScrollback = 'Scrollback lines';
  static const String settingsTermScrollbackDesc =
      'Number of scrollback lines to keep in terminal buffer.';

  // Settings view — AI / Chat
  static const String settingsToolCompressionToggle =
      'Compress tool results with utility model';
  static const String settingsToolCompressionDesc =
      'Before large tool outputs go back to the main model, summarize '
      'them with a cheaper model to reduce cloud context cost.';
  static const String settingsToolCompressionModel = 'Utility model';
  static const String settingsToolCompressionModelDesc =
      'Model used for tool-output compression. Pick a fast cloud model '
      'you have pulled, such as an Ollama cloud Qwen or Gemma model.';
  static const String settingsToolCompressionNoModel = 'None';
  static const String settingsToolCompressionThreshold =
      'Minimum characters to compress';
  static const String settingsToolCompressionThresholdDesc =
      'Default: 2000. Smaller tool results are sent raw.';
  static const String settingsHistorySummaryToggle =
      'Summarize chat history with utility model';
  static const String settingsHistorySummaryDesc =
      'On long sessions, replace the dropped middle of chat history '
      'with a structured summary written by the utility model above. '
      'Reduces context pressure on the main model. Skipped on Claude '
      '(automatic prompt caching keeps its cost low without this).';
  static const String settingsHistorySummaryMaxChars =
      'Max summary length (chars)';
  static const String settingsHistorySummaryMaxCharsDesc =
      'Default: 1200. Summaries longer than this are rejected and the '
      'plain elision placeholder is used instead.';
  static const String settingsHistorySummaryRefreshDelta =
      'Refresh after N new dropped messages';
  static const String settingsHistorySummaryRefreshDeltaDesc =
      'Default: 10. Lower = fresher summaries, more LLM calls. Higher = '
      'cheaper, but the summary lags behind ongoing work.';
  static const String settingsDefaultModel = 'Default model';
  static const String settingsDefaultModelDesc =
      'Name of the model to use for chat completions.';
  static const String settingsMaxContextTokens = 'Max context tokens';
  static const String settingsMaxContextTokensDesc =
      'Maximum token window for context sent to the model.';
  static const String settingsModelManagementDesc =
      'Enable, disable, and select models per provider. This is the full model manager from the chat picker, fitted into Settings.';
  static const String settingsAgentOutsideWorkspaceWrites =
      'Allow agent writes outside workspace';
  static const String settingsAgentOutsideWorkspaceWritesDesc =
      'When off, built-in file tools cannot create, edit, move, append, or delete outside the active workspace. Reading outside the workspace is still allowed. Shell commands remain separately approval-gated.';
  static const String settingsAgentAutoVerify = 'Auto-verify after edits';
  static const String settingsAgentAutoVerifyDesc =
      'When on, the workspace analyzer (dart analyze, tsc --noEmit, eslint, ruff check) runs once at the end of any turn that edited source files but didn\'t call VERIFY. Errors are fed back as one extra round so the model can fix them before the turn closes. Costs ~2-30s per edit-heavy turn depending on workspace size.';

  // Settings view — Rules
  static const String settingsRulesDesc =
      'Rules are injected into the agent system prompt so every chat starts with your standing instructions.';
  static const String settingsGlobalRulesDesc =
      'Applies to every workspace opened in Lumen.';
  static const String settingsWorkspaceRulesDesc =
      'Applies only to the currently open workspace and is stored in .lumen/rules.md.';
  static const String settingsWorkspaceRulesNoWorkspace =
      'Open a workspace to edit workspace-specific rules.';

  // Settings view — Keyboard shortcuts
  static const String settingsShortcutsReadonly =
      'Keyboard shortcuts are read-only for now. Customization coming soon.';
  static const String settingsShortcutAction = 'Action';
  static const String settingsShortcutBinding = 'Binding';

  // Lock screen
  static const String lockTitle = 'Lumen Locked';
  static const String lockSubtitle = 'Enter your PIN to continue';
  static const String lockEnterPin = 'Enter PIN';
  static const String lockSetPin = 'Set PIN';
  static const String lockConfirmPin = 'Confirm PIN';
  static const String lockMismatch = 'PINs do not match';
  static const String lockWrong = 'Wrong PIN';
  static const String lockNoPin = 'No PIN set yet. Set one to lock.';
  static const String unlock = 'Unlock';
  static const String lockRemovePin = 'Remove PIN';

  // Backup
  static const String backupTitle = 'Backup Project';
  static const String backupCreate = 'Create Backup';
  static const String backupOpen = 'Open Backups Folder';
  static const String backupRunning = 'Backing up project…';
  static const String backupDone = 'Backup created';
  static const String backupFailed = 'Backup failed';
  static const String backupNone = 'No backups yet';
  static const String backupRestore = 'Restore';
  static const String backupOpenInOs = 'Open in OS';
  static const String backupAutomatic = 'Automatic Backups';
  static const String backupAutomaticDesc =
      'Periodically zip your workspace in the background.';
  static const String backupInterval = 'Interval (minutes)';
  static const String backupGitAutoCommit = 'Git auto-commit on backup';
  static const String backupGitAutoCommitDesc =
      'Run git add . && git commit on each successful backup (only if a git repo).';
  static const String backupGitAutoPush = 'Git auto-push after commit';
  static const String backupGitAutoPushDesc =
      'Push to the current upstream after auto-commit. Requires configured remote & credentials.';
  static const String backupGitNotARepo = 'Workspace is not a git repository.';
  static const String backupGitOk = 'git: committed';
  static const String backupGitPushed = 'git: pushed';
  static const String backupGitFailed = 'git step failed';
  static const String backupNoWorkspace = 'No workspace open';
  static const String backupAutoLastRun = 'Last run';
  static const String backupAutoNextRun = 'Next run';
  static const String backupAutoNever = 'never';
  static const String backupAutoRunNow = 'Run now';
  static const String backupAutoIdle = 'Idle';
  static const String backupAutoRunning = 'Running…';
  static const String backupAutoMinutes = 'min';
  static const String backupExistingHeader = 'Existing Backups';
  static const String backupNoWorkspaceLabel = '(no workspace)';

  // Rules
  static const String rulesGlobalTitle = 'Global Rules (.lumen/rules.md)';
  static const String rulesWorkspaceTitle = 'Workspace Rules (.lumen/rules.md)';
  static const String rulesPlaceholder =
      '# Lumen Rules\n\nWrite short, practical project instructions the agent should always follow.';

  // View modes
  static const String viewNormal = 'Normal';
  static const String viewZen = 'Zen Mode';
  static const String viewSideEye = 'Side-Eye Mode';

  // File timeline (per-workspace revision history)
  static const String timelineTitle = 'File Timeline';
  static const String timelineEmpty =
      'No revisions captured yet. Edit, save, or let the agent touch a '
      'file — every change lands here automatically.';
  static const String timelineSelectPrompt =
      'Select a revision on the left to compare it with the current file.';
  static const String timelineDiffEmpty =
      'No differences between this revision and the current file.';
  static const String timelineDiffCurrent = 'CURRENT FILE';
  static const String timelineRestoreAction = 'Restore this version';
  static const String timelineRestoreConfirmTitle = 'Restore this revision?';
  static const String timelineSearchHint = 'Filter by path, tool, or note…';
  static const String timelineScopeOff = 'Active file only';
  static const String timelineFilterAll = 'All';
  static const String timelineFilterAgent = 'Agent';
  static const String timelineFilterUser = 'You';
  static const String timelineFilterExternal = 'External';
  static const String timelineFilterBaseline = 'Baselines';
  static const String timelineGroupToday = 'TODAY';
  static const String timelineGroupYesterday = 'YESTERDAY';
  static const String timelineGroupThisWeek = 'THIS WEEK';
  static const String timelineOpCreate = 'CREATE';
  static const String timelineOpModify = 'MODIFY';
  static const String timelineOpDelete = 'DELETE';
  static const String timelineOpRename = 'RENAME';
  static const String timelineOriginAgent = 'agent';
  static const String timelineOriginUser = 'manual save';
  static const String timelineOriginExternal = 'external change';
  static const String timelineOriginExplorer = 'explorer';
  static const String timelineOriginBaseline = 'baseline';
  static const String timelineOriginOther = 'other';
  static const String timelineFileMissing = 'file no longer exists';
  static const String timelineBinaryNotice =
      'Binary file — content preserved but not shown here. Restore '
      'still works.';
  static const String timelineWhenJustNow = 'just now';
  static const String timelineRailHeader = 'TIMELINE';
  static const String timelineRailAgentEntryGeneric = 'Edited by agent';
  static const String timelineRailUserEntry = 'You saved';
  static const String timelineRailExternalEntry = 'External change';
  static const String timelineRailExplorerEntry = 'Explorer action';
  static const String timelineRailBaselineEntry = 'Baseline captured';
  static const String timelineRailUnknownEntry = 'Captured';
  static const String timelineOpenDialog = 'Open full timeline';
  static const String timelineViewAll = 'View full timeline';
  static const String timelineMenuLabel = 'File Timeline';
  static const String timelineMenuTooltip = 'Browse file revision history';
  static String timelineScopeOn(String label) =>
      label.isEmpty ? 'Active file only' : 'Active file: $label';
  static String timelineRestoreConfirmBody(String path, String when) =>
      'Replace the current contents of $path with the version from $when?\n\n'
      'A pre-restore snapshot is captured first, so you can undo this from '
      'the timeline.';

  // Project-wide "revert to this point in time" — the PhpStorm Local
  // History–style action that lives next to the single-file restore
  // button.
  static const String timelineProjectRevertAction = 'Revert project to here';
  static const String timelineProjectRevertTooltip =
      'Roll the entire project back to this moment in time. '
      'Per-file timestamps and chat history are preserved.';
  static const String timelineProjectRevertConfirmTitle =
      'Revert project to this point?';
  static const String timelineProjectRevertNoChanges =
      'The project already matches this point in time — nothing to do.';
  static const String timelineProjectRevertChangedFiles =
      'Files that will change';
  static const String timelineProjectRevertRecreatedFiles =
      'Files that will be recreated';
  static const String timelineProjectRevertCreatedAfter =
      'Files created after this point';
  static const String timelineProjectRevertUnrestorable =
      'Files whose history was pruned (cannot be restored)';
  static const String timelineProjectRevertKeepNewFiles = 'Keep them';
  static const String timelineProjectRevertDeleteNewFiles = 'Delete them';
  static const String timelineProjectRevertNewFilesPrompt =
      'These files did not exist at the chosen point in time. What should '
      'happen to them?';
  static const String timelineProjectRevertSafetyNote =
      'A pre-revert snapshot of every changed file is captured first, so '
      'you can undo this from the timeline.';

  static String timelineProjectRevertSummary({
    required int changed,
    required int recreated,
    required int createdAfter,
    required int unrestorable,
  }) {
    final parts = <String>[];
    if (changed > 0) {
      parts.add(
        changed == 1 ? '1 file will change' : '$changed files will change',
      );
    }
    if (recreated > 0) {
      parts.add(
        recreated == 1
            ? '1 file will be recreated'
            : '$recreated files will be recreated',
      );
    }
    if (createdAfter > 0) {
      parts.add(
        createdAfter == 1
            ? '1 file was created after this point'
            : '$createdAfter files were created after this point',
      );
    }
    if (unrestorable > 0) {
      parts.add(
        unrestorable == 1
            ? '1 file is no longer restorable'
            : '$unrestorable files are no longer restorable',
      );
    }
    if (parts.isEmpty) return 'No changes.';
    return '${parts.join(', ')}.';
  }

  static String timelineDiffRevision(String when) => 'REVISION · $when';
  static String timelineBinarySizes(int rev, int cur) =>
      'Revision: ${_humanBytes(rev)}  ·  Current: ${_humanBytes(cur)}';
  static String timelineOriginAgentTool(String tool) => 'agent · $tool';
  static String timelineRailAgentEntry(String tool) => 'Agent · $tool';

  static String _humanBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(1)}KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }

  // Settings view — Syncthing
  static const String settingsCatSyncthing = 'Syncthing';
  static const String settingsSyncthingEnable = 'Enable Syncthing integration';
  static const String settingsSyncthingEnableDesc =
      'Connect to a local or remote Syncthing instance for cross-device project sync.';
  static const String settingsSyncthingEndpoint = 'Syncthing URL';
  static const String settingsSyncthingEndpointDesc =
      'Base URL of the Syncthing GUI / API (default: http://localhost:8384).';
  static const String settingsSyncthingApiKey = 'API Key';
  static const String settingsSyncthingApiKeyDesc =
      'REST API key from Syncthing Settings > General. Leave empty if auth is disabled.';
  static const String settingsSyncthingAutoShare = 'Auto-share opened projects';
  static const String settingsSyncthingAutoShareDesc =
      'Automatically register a workspace as a shared folder when you open it.';
  static const String settingsSyncthingStatus = 'Connection status';
  static const String settingsSyncthingReachable = 'Reachable';
  static const String settingsSyncthingUnreachable = 'Unreachable';
  static const String settingsSyncthingAuthOk = 'Authenticated';
  static const String settingsSyncthingAuthFail = 'Auth failed';
  static const String settingsSyncthingDeviceId = 'Device ID';
  static const String settingsSyncthingVersion = 'Version';
  static const String settingsSyncthingFolders = 'Shared Folders';
  static const String settingsSyncthingDevices = 'Known Devices';
  static const String settingsSyncthingNoFolders = 'No shared folders.';
  static const String settingsSyncthingNoDevices = 'No known devices.';
  static const String settingsSyncthingTesting = 'Testing connection\u2026';
  static const String settingsSyncthingTestBtn = 'Test Connection';

  // Syncthing — sharing defaults section.
  static const String settingsSyncthingSharingDefaults = 'Sharing defaults';
  static const String settingsSyncthingSharingDefaultsDesc =
      'Applied to every folder Lumen creates or re-shares. Existing '
      'folders inherit these on the next workspace open.';
  static const String settingsSyncthingAutoAcceptRemote =
      'Auto-accept folders shared FROM other devices';
  static const String settingsSyncthingAutoAcceptRemoteDesc =
      'Off by default. When ON, folders other devices share with this PC '
      'are auto-created under the landing path below. When OFF, they '
      'appear in the Pending panel and you pick the destination.';
  static const String settingsSyncthingIgnorePerms = 'Ignore file permissions';
  static const String settingsSyncthingIgnorePermsDesc =
      'Recommended for code projects (especially across Windows/Linux). '
      'Stops Syncthing fighting over executable bits and ACLs.';
  static const String settingsSyncthingWriteStignore =
      'Seed default .stignore on share';
  static const String settingsSyncthingWriteStignoreDesc =
      'Drops a Lumen ignore template (node_modules, build, .dart_tool, '
      '__pycache__, …) into shared folders that don\u2019t already have one.';
  static const String settingsSyncthingVersioningPreset = 'File versioning';
  static const String settingsSyncthingVersioningPresetDesc =
      'Old / overwritten files go to .stversions on the receiver. '
      'Recommended: Staggered \u2014 best balance of safety and disk use.';
  static const String settingsSyncthingDefaultLandingPath =
      'Default landing path';
  static const String settingsSyncthingDefaultLandingPathDesc =
      'Where Syncthing puts auto-accepted folders on THIS PC. Tilde (~) '
      'expands to your home directory.';

  // Syncthing — pending folders panel.
  static const String settingsSyncthingPendingFolders = 'Pending Folders';
  static const String settingsSyncthingPendingFoldersDesc =
      'Folders other devices want to share with this PC. Pick a local '
      'destination and accept \u2014 or dismiss to ignore.';
  static const String settingsSyncthingNoPendingFolders =
      'No pending folder offers.';
  static const String settingsSyncthingAcceptHere = 'Accept here\u2026';
  static const String settingsSyncthingDismiss = 'Dismiss';
  static const String settingsSyncthingPickDestination = 'Pick destination';
  static const String settingsSyncthingAcceptedToast =
      'Folder accepted. Sync will begin shortly.';
  static const String settingsSyncthingDismissedToast =
      'Folder offer dismissed.';

  // Syncthing — pending devices panel.
  static const String settingsSyncthingPendingDevices = 'Pending Devices';
  static const String settingsSyncthingPendingDevicesDesc =
      'Devices that tried to connect but aren\u2019t paired yet.';
  static const String settingsSyncthingNoPendingDevices =
      'No pending device requests.';
  static const String settingsSyncthingAddDevice = 'Add device';
  static const String settingsSyncthingDeviceName = 'Display name';
  static const String settingsSyncthingDeviceAdded = 'Device added.';
  static const String settingsSyncthingDeviceDismissed =
      'Device request dismissed.';

  // Syncthing — introducer warning.
  static const String settingsSyncthingIntroducerWarningTitle =
      'Introducer loop detected';
  static const String settingsSyncthingIntroducerWarningBody =
      'You have one or more remote devices marked as introducer on this '
      'PC. If those same devices also have you marked as introducer, '
      'Syncthing logs warnings and re-introduction loops can prevent you '
      'from removing devices later. Safe one-click fix:';
  static const String settingsSyncthingIntroducerFixBtn =
      'Disable introducer on this side';
  static const String settingsSyncthingIntroducerFixedToast =
      'Introducer flag cleared on {n} device(s).';

  // Syncthing welcome-screen prompt (was hardcoded).
  static const String syncthingPromptTitle = 'Share with Syncthing?';
  static const String syncthingPromptBody =
      'Syncthing is connected but auto-share is off. Would you like to '
      'share this project with all your devices?';
  static const String syncthingPromptShare = 'Share';
  static const String syncthingPromptCancel = 'No';
  static const String syncthingSharedToast =
      'Project shared with Syncthing devices.';

  // Syncthing — refresh button.
  static const String settingsSyncthingRefreshPending = 'Refresh';

  // ── Process Manager ──
  // The Terminal-menu entry that opens the manager and the
  // surface itself. Strings live here per workspace rule
  // (no hardcoded text in widgets).
  static const String menuProcessManager = 'Process Manager…';
  static const String processManagerTitle = 'Process Manager';

  // Filter chips. Labels are intentionally short so the chip
  // bar wraps cleanly at narrow widths.
  static const String processFilterAll = 'All';
  static const String processFilterNode = 'Node';
  static const String processFilterPython = 'Python';
  static const String processFilterJava = 'Java';
  static const String processFilterWorkspace = 'This workspace';
  static const String processFilterLumen = 'Lumen-spawned';

  // Search + table headers.
  static const String processSearchHint =
      'Search by name, path, or command line\u2026';
  static const String processColPid = 'PID';
  static const String processColName = 'NAME';
  static const String processColMemory = 'MEMORY';
  static const String processColCommand = 'COMMAND';

  // Per-row + bulk actions.
  static const String processKill = 'Kill';
  static const String processRefresh = 'Refresh';
  static const String processAutoRefreshOn = 'Auto-refresh: ON';
  static const String processAutoRefreshOff = 'Auto-refresh: OFF';
  static String processKillAllMatching(int n) => 'Kill all $n matching';
  static const String processKillFailed = 'Failed to kill';
  static String processKillBulkDone(int n) =>
      'Killed $n process${n == 1 ? '' : 'es'}.';
  static String processKillBulkPartial(int ok, int failed) =>
      'Killed $ok, failed $failed. Some processes may need elevated rights.';
  static const String processKillBulkConfirmTitle = 'Kill matching processes?';
  static String processKillBulkConfirmBody(int n) =>
      'You are about to terminate $n process${n == 1 ? '' : 'es'}. '
      'Unsaved work in those processes will be lost.';
  static const String processKillBulkConfirmAction = 'Kill all';

  // Empty / error states.
  static const String processEmpty = 'No processes returned by the OS.';
  static const String processNoMatches =
      'No processes match the current filter.';
  static const String processError = 'Could not list processes';
  static const String processLumenSpawnedTooltip =
      'Spawned by Lumen (or a descendant of one)';

  // Footer stats line. Ordered so the most actionable number
  // ("matched") sits next to the search box visually.
  static String processFooterStats(int total, int matched, int spawned) =>
      '$total processes  ·  $matched matched  ·  $spawned Lumen-spawned';

  // ── Settings view — Remote Access ────────────────────────────
  // The Remote Access feature lets paired phones / tablets talk to
  // this Lumen instance over LAN or Tailscale. v1 is foundation
  // only — the strings below describe a loopback-bound /v1/health
  // server. Pairing / TLS / data API strings will land alongside
  // their respective passes; keep this block focused on what the
  // current build actually surfaces so the panel doesn't lie.
  static const String settingsCatRemoteAccess = 'Remote Access';
  static const String settingsRemoteAccessTitle = 'Remote Access';
  static const String settingsRemoteAccessSubtitle =
      'Let paired devices on your local network or Tailscale connect '
      'to this Lumen instance. Foundation build — pairing, TLS, and '
      'the data API land in upcoming versions.';
  static const String settingsRemoteAccessEnabled = 'Enable remote access';
  static const String settingsRemoteAccessStarting = 'Starting…';
  static const String settingsRemoteAccessDisabled = 'Disabled';
  static const String settingsRemoteAccessNotRunning = 'Not running';
  static const String settingsRemoteAccessRunningOn = 'Running on';
  static const String settingsRemoteAccessInstanceName = 'Instance name';
  static const String settingsRemoteAccessInstanceId = 'Instance ID';
  static const String settingsRemoteAccessHealthHint =
      'Quick check: with this enabled, a curl to '
      'http://<host>:<port>/v1/health should return JSON.';

  // Bind / network exposure
  static const String settingsRemoteAccessBindAll = 'Bind to LAN / Tailscale';
  static const String settingsRemoteAccessBindAllDesc =
      'Listen on every network interface so paired phones, tablets, '
      'and Tailscale peers can reach this Lumen instance. Off by '
      'default: a single click on the master toggle keeps the server '
      'loopback-only.';
  static const String settingsRemoteAccessReachableUrls = 'Reachable on';
  static const String settingsRemoteAccessNoInterfaces =
      'No non-loopback interfaces detected.';

  // Plain-HTTP warning (replaces the prior "foundation notice"
  // string). Load-bearing — the threat model intentionally skips
  // TLS, see knowledgebase § Remote Access.
  static const String settingsRemoteAccessPlainHttpBanner =
      'Plain HTTP, bearer-auth only. Fine over Tailscale (already '
      'encrypted) and over LANs you trust. Don\'t expose on hostile '
      'networks (coffee-shop wifi, public APs) until TLS lands.';

  // Pairing
  static const String settingsRemoteAccessPairing = 'Pair a device';
  static const String settingsRemoteAccessPairingDesc =
      'Generate a one-time 6-digit code that a phone or tablet enters '
      'to pair with this Lumen instance.';
  static const String settingsRemoteAccessShowCode = 'Show pairing code';
  static const String settingsRemoteAccessHideCode = 'Hide pairing code';
  static const String settingsRemoteAccessPairingCodeTitle = 'Pairing code';
  static const String settingsRemoteAccessPairingCodeBody =
      'Enter this code on the device you want to pair. It expires in 60s '
      'and can only be used once.';
  static const String settingsRemoteAccessPairingExpired =
      'Code expired. Generate a new one.';
  static const String settingsRemoteAccessPairingExpiresIn = 'Expires in';
  static const String settingsRemoteAccessPairingComplete =
      'Paired successfully.';

  // Paired devices
  static const String settingsRemoteAccessPairedDevices = 'Paired devices';
  static const String settingsRemoteAccessNoPairedDevices =
      'No paired devices yet.';
  static const String settingsRemoteAccessRevoke = 'Revoke';
  static const String settingsRemoteAccessRevokeAll = 'Revoke all';
  static const String settingsRemoteAccessLastSeen = 'Last seen';
  static const String settingsRemoteAccessNever = 'never';
}
