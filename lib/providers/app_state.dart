import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../services/agent_terminal_bridge.dart';
import '../services/anthropic_service.dart';
import '../services/auto_backup_scheduler.dart';
import '../services/backup_service.dart';
import '../services/chat_persistence_service.dart';
import '../services/copilot_service.dart';
import '../services/file_kind.dart';
import '../services/gemini_service.dart';
import '../services/gitnexus_service.dart';
import '../services/github_models_service.dart';
import '../services/ide_actions.dart';
import '../services/lumen_process_tracker.dart';
import '../services/ollama_service.dart';
import '../services/preferences_service.dart';
import '../services/recent_edits_tracker.dart';
import '../services/remote/lumen_server.dart';
import '../services/rules_service.dart';
import '../services/ssh/ssh_remote_file_service.dart';
import '../services/syncthing_service.dart';
import '../services/timeline_models.dart';
import '../services/timeline_service.dart';
import '../services/workspace_service.dart';
import '../services/workspace_skills_service.dart';
import 'chat_controller.dart';
import 'ssh_controller.dart';

enum DuckViewMode { normal, zen, sideEye }

/// Compatibility shim for the old `ChatMessage` symbol so any leftover
/// imports keep compiling. New code should use `PersistedMessage` from
/// `chat_persistence_service.dart`.
typedef ChatMessage = PersistedMessage;

/// Owns workspace, open files, settings, view mode and lock state.
/// Chat lives in `ChatController`. Both are exposed via Provider.
class AppState extends ChangeNotifier {
  /// Sentinel file path used when the Settings view is opened as a virtual
  /// tab in the editor area. No real file exists at this path — the editor
  /// detects it and renders `SettingsView` instead of a code pane.
  static const String settingsSentinel = '__settings__';

  /// Sentinel file path for the process manager virtual tab. Same
  /// pattern as `settingsSentinel`: a fake path that the editor pane
  /// detects and routes to `ProcessManagerView` instead of trying to
  /// open a code editor.
  static const String processManagerSentinel = '__process_manager__';

  /// Prefix for untitled (unsaved) tabs created with Ctrl+T.
  static const String untitledPrefix = '__untitled__';

  /// Returns `true` when the given path is the settings sentinel.
  static bool isSettingsTab(String? path) => path == settingsSentinel;

  /// Returns `true` when the given path is the process manager sentinel.
  static bool isProcessManagerTab(String? path) =>
      path == processManagerSentinel;

  /// Returns `true` when the given path is an untitled (unsaved) tab.
  static bool isUntitledTab(String? path) =>
      path != null && path.startsWith(untitledPrefix);

  int _untitledCounter = 0;

  final OllamaService _ollamaService = OllamaService();
  final GeminiService _geminiService = GeminiService();
  final AnthropicService _anthropicService = AnthropicService();
  final GitHubModelsService _githubModelsService = GitHubModelsService();
  final CopilotService _copilotService = CopilotService();
  // Public read-only handles so features outside the chat flow can
  // reach the configured clients without re-deriving from prefs.
  OllamaService get ollamaService => _ollamaService;
  GeminiService get geminiService => _geminiService;
  AnthropicService get anthropicService => _anthropicService;
  GitHubModelsService get githubModelsService => _githubModelsService;
  CopilotService get copilotService => _copilotService;
  final WorkspaceService _workspaceService = WorkspaceService();
  final PreferencesService prefs = PreferencesService();
  final ChatPersistenceService _persistence = ChatPersistenceService();
  final RulesService rules = RulesService();
  final IdeActions ideActions = IdeActions();
  // Tracks PIDs that Lumen explicitly spawned (terminal PTYs, agent
  // tool processes) so the process manager can offer a
  // "Lumen-spawned" filter that's actually accurate. See
  // `services/lumen_process_tracker.dart` for the descendant-walk
  // logic. Owned here because the lifetime is workspace-independent
  // — terminals can outlive a workspace switch.
  final LumenProcessTracker lumenProcesses = LumenProcessTracker();
  // Bridge between agent-spawned `RUN_CMD` invocations and the
  // visible terminal pane. The chat controller hands the bridge a
  // launcher closure (see `tool_executor.dart`); long-running
  // commands get promoted to real terminal tabs the user can see
  // and kill via tab close. Lives here (not in `chat`) because the
  // terminal pane needs to subscribe to it independent of chat
  // lifetime, and it shares the `lumenProcesses` tracker for PID
  // visibility.
  late final AgentTerminalBridge agentTerminals = AgentTerminalBridge(
    processes: lumenProcesses,
  );
  final BackupService backups = BackupService();
  final SyncthingService syncthing = SyncthingService();
  final GitNexusService gitnexus = GitNexusService();
  final WorkspaceSkillsService workspaceSkills = WorkspaceSkillsService();
  // Optional embedded HTTP server used by the Remote Access feature
  // (paired phones / tablets connect over LAN / Tailscale). Off by
  // default; toggled on via Settings → Remote Access. Constructed
  // here so widgets can listen via `Consumer<AppState>` and reach
  // `state.remote`. The server itself is a `ChangeNotifier` so the
  // settings panel uses `AnimatedBuilder` against it for live
  // status updates without piping every change through AppState.
  //
  // Read closures rather than direct AppState wiring keep the
  // server's dependency surface narrow — see `lumen_routes.dart`
  // § LumenRemoteDeps. They're evaluated per request so a workspace
  // switch surfaces immediately without listener plumbing.
  late final LumenServer remote = LumenServer(
    prefs: prefs,
    persistence: _persistence,
    currentDirectory: () => _currentDirectory,
    recentProjects: () => List.unmodifiable(_recentProjects),
    // Lazy on purpose: `chat` is `late final` and constructed in
    // the AppState constructor body, so the `LumenServer` field
    // initializer can't reach it directly. The closure is only
    // dereferenced when a mutating REST route fires, which is
    // strictly after `_bootstrap` has run `chat.init()`.
    chatController: () => chat,
  );
  // Per-workspace foolproof file revision history. Mounted by
  // `setDirectory` and detached by `closeWorkspace`; capture hooks
  // (manual save, FS watcher, agent tool ops) all funnel into this
  // single service, which serialises writes through a content-
  // addressed blob store. See `services/timeline_service.dart` for
  // the full design and `.agents/timeline.md` for the cross-feature
  // contract.
  final TimelineService timeline = TimelineService();

  // "Last turn" agent-edit highlight tracker. Owned here so the
  // editor pane (consumer) and the chat controller (writer) share a
  // single instance without provider plumbing. Bound per-workspace by
  // `setDirectory` / `closeWorkspace`. See
  // `services/recent_edits_tracker.dart` for the design.
  late final RecentEditsTracker recentEdits = RecentEditsTracker(prefs);

  late final ChatController chat;
  late final AutoBackupScheduler autoBackup;

  // Optional reference to the workspace-wide [SshController]. Wired
  // by `main.dart` after both providers exist via [bindSsh] so the
  // save path can route remote-mirror buffers through SFTP and the
  // editor tab strip can render `host:path` suffixes. Null until
  // bound — every code path here treats it as opt-in (no SSH ⇒ no
  // remote-aware behaviour, just normal local saves).
  SshController? _ssh;
  SshController? get ssh => _ssh;

  /// Caller-provided closure that prompts the user when a remote save
  /// would overwrite changes the remote made since download. Set by
  /// main.dart so any save path (Ctrl+S, menu, save-all) uses the
  /// same UX without each call site reimplementing the prompt.
  /// Default: "cancel on conflict" — safer than silent overwrite.
  SshConflictResolver _sshConflictResolver =
      ({
        required RemoteFileOrigin origin,
        required int? currentSize,
        required int? currentMtime,
      }) async => false;

  /// Caller-provided closure that prompts the user when a `lumen-grab`
  /// download is about to overwrite an existing file in the project.
  /// Set by main.dart for the same reason as [_sshConflictResolver].
  /// Default: "cancel on collision" — safer than silent overwrite,
  /// and the user can always re-run the grab after deleting / moving
  /// the existing file.
  SshGrabConflictResolver _sshGrabConflictResolver =
      ({
        required String existingLocalPath,
        required String remotePath,
        required String hostLabel,
      }) async => SshGrabConflictDecision.cancel;

  void bindSsh(
    SshController controller, {
    SshConflictResolver? conflictResolver,
    SshGrabConflictResolver? grabConflictResolver,
  }) {
    _ssh = controller;
    if (conflictResolver != null) {
      _sshConflictResolver = conflictResolver;
    }
    if (grabConflictResolver != null) {
      _sshGrabConflictResolver = grabConflictResolver;
    }
  }

  // Workspace
  String? _currentDirectory;
  final List<File> _openFiles = [];
  File? _activeFile;
  final Map<String, String> _fileContents = {};
  final Map<String, String> _savedFileContents = {};
  final Map<String, String> _fileLanguageOverrides = {};
  List<String> _recentProjects = [];

  // ---- File explorer auto-refresh ----
  // Bumped every time the explorer needs to discard cached
  // directory listings and re-read from disk. The explorer's
  // `_FileTree` widget watches this via `didUpdateWidget` and
  // calls `_loadChildren()` when it changes — `notifyListeners()`
  // alone isn't enough because `_FileTree` caches `_children` in
  // its State and only reloads on explicit input change.
  int _fileExplorerRefreshTick = 0;
  int get fileExplorerRefreshTick => _fileExplorerRefreshTick;

  // Filesystem watcher that drives auto-refresh. Recreated on every
  // `setDirectory` and torn down on `closeWorkspace` / dispose.
  // Uses `Directory.watch(recursive: true)` which on Windows binds
  // to `ReadDirectoryChangesW` under the hood.
  StreamSubscription<FileSystemEvent>? _fsWatcher;
  // Coalesces bursts of FS events (npm install can fire thousands
  // in a few hundred ms) into a single refresh so we don't melt the
  // explorer with rapid `listSync` calls.
  Timer? _fsRefreshDebounce;

  /// Directories whose internal churn we don't care about — build
  /// outputs, dependency caches, IDE metadata. Filtering on the
  /// event side rather than the OS side because Windows
  /// `ReadDirectoryChangesW` doesn't accept exclude lists; receiving
  /// + discarding is cheap (debounced anyway).
  static const Set<String> _fsWatcherIgnore = <String>{
    'node_modules',
    '.git',
    '.gitnexus',
    '.dart_tool',
    'build',
    'dist',
    'out',
    '.next',
    '.nuxt',
    '.svelte-kit',
    '.turbo',
    '.cache',
    '.parcel-cache',
    'venv',
    '.venv',
    '__pycache__',
    '.idea',
    '.vscode',
    'target',
    'Pods',
    '.gradle',
    '.flutter-plugins-dependencies',
    '.expo',
    '.expo-shared',
  };

  // LLM provider settings — multiple providers can be enabled at once.
  Set<String> _enabledProviders = {'Ollama'};
  String _ollamaEndpoint = 'http://localhost:11434';
  // Optional Ollama Cloud key. When non-empty, the chat controller
  // also fetches `https://ollama.com/api/tags` for cloud-only models
  // and routes any `*-cloud`/`*:cloud` chat to the cloud endpoint
  // with Bearer auth — so users without a local daemon can still use
  // hosted Ollama models, and users with both keep the cloud path
  // even if they haven't `ollama signin`'d locally.
  String _ollamaApiKey = '';
  String _geminiApiKey = '';
  String _anthropicApiKey = '';
  String _githubModelsApiKey = '';
  String _githubModelsOrganization = '';
  String _copilotApiKey = '';
  bool _copilotUseLoggedInUser = true;
  String _openaiApiKey = '';
  bool _toolCompressionEnabled = false;
  String _toolCompressionModel = '';
  int _toolCompressionThreshold = 2000;
  // Chat-history summarization. Reuses `_toolCompressionModel` for
  // the small-model choice (one user-facing "small model" setting,
  // two consumers — see preferences_service.dart for rationale).
  bool _historySummaryEnabled = false;
  int _historySummaryMaxChars = 1200;
  int _historySummaryRefreshDelta = 10;

  // Editor settings
  // Default to `lumen-midnight` — bespoke theme tuned to the IDE chrome
  // with deliberate hue spread (purple keywords, cyan functions, gold
  // types, green strings, orange numbers, dim italic comments). Earlier
  // defaults (`one-dark-pro` originally, then `nord`) get migrated up
  // by `PreferencesService.getEditorTheme` so existing users see the
  // upgrade — anyone who actively chose a different theme is left alone.
  String _editorTheme = 'lumen-midnight';
  double _editorFontSize = 13.5;
  int _editorTabSize = 2;
  bool _wordWrap = false;

  // View / lock
  DuckViewMode _viewMode = DuckViewMode.normal;
  bool _isLocked = false;

  // UI accessibility / GPU escape hatches (drive `DuckGlass` and
  // `DuckMotion` so users on weak GPUs / on battery can opt out without
  // the IDE losing functionality).
  bool _reduceMotion = false;
  bool _reduceTransparency = false;
  bool _allowAgentOutsideWorkspaceWrites = false;
  // When true, the chat controller runs the workspace analyzer (dart
  // analyze / tsc --noEmit / ruff check) once at the end of any turn
  // that touched source files but didn't call VERIFY itself. See
  // `_kAgentAutoVerifyAfterEdits` for the rationale.
  bool _autoVerifyAfterEdits = true;

  // Quick AI-chat panel collapse — independent of `viewMode`. The
  // user wants a one-click toggle without leaving normal layout
  // (Zen mode hides explorer + chat together; this only hides the
  // chat). Persisted so the IDE re-opens with the same chat
  // visibility the user last picked.
  bool _chatHidden = false;
  String _settingsInitialCategory = 'general';
  int _settingsOpenRevision = 0;

  // Syncthing cross-device sync — see `services/syncthing_service.dart`
  // and `.agents/knowledgebase.md` § Syncthing for the full architecture.
  bool _syncthingEnabled = false;
  bool _syncthingAutoShare = true;
  // Off by default. The blanket-`autoAcceptFolders=true` flow we used to
  // run silently dropped folders into the receiver's Syncthing data
  // directory because `defaults.folder.path` wasn't set there. The
  // pending-folders panel is the safe replacement; this toggle exists
  // only for power users who explicitly opt in.
  bool _syncthingAutoAcceptRemote = false;
  bool _syncthingIgnorePerms = true;
  bool _syncthingWriteStignore = true;
  String _syncthingVersioningPreset = 'staggered';
  String _syncthingDefaultLandingPath = '~/Lumen-Sync';

  // GitNexus integration master switch — see `_kGitNexusEnabled`
  // doc in `PreferencesService` for the full off-state contract.
  bool _gitnexusEnabled = true;
  bool _gitnexusAutoWiki = false;
  String _gitnexusWikiModel = '';

  String? get currentDirectory => _currentDirectory;
  List<File> get openFiles => _openFiles;
  File? get activeFile => _activeFile;
  String get fileContent =>
      _activeFile != null ? (_fileContents[_activeFile!.path] ?? '') : '';
  String fileContentFor(String path) => _fileContents[path] ?? '';
  bool isFileDirty(String path) =>
      _fileContents[path] != null &&
      _savedFileContents[path] != null &&
      _fileContents[path] != _savedFileContents[path];
  String? languageOverrideFor(String path) => _fileLanguageOverrides[path];

  List<String> get recentProjects => _recentProjects;

  Set<String> get enabledProviders => _enabledProviders;
  String get ollamaEndpoint => _ollamaEndpoint;
  String get ollamaApiKey => _ollamaApiKey;
  String get geminiApiKey => _geminiApiKey;
  String get anthropicApiKey => _anthropicApiKey;
  String get githubModelsApiKey => _githubModelsApiKey;
  String get githubModelsOrganization => _githubModelsOrganization;
  String get copilotApiKey => _copilotApiKey;
  bool get copilotUseLoggedInUser => _copilotUseLoggedInUser;
  String get openaiApiKey => _openaiApiKey;
  bool get toolCompressionEnabled => _toolCompressionEnabled;
  String get toolCompressionModel => _toolCompressionModel;
  int get toolCompressionThreshold => _toolCompressionThreshold;
  bool get historySummaryEnabled => _historySummaryEnabled;
  int get historySummaryMaxChars => _historySummaryMaxChars;
  int get historySummaryRefreshDelta => _historySummaryRefreshDelta;
  bool isProviderEnabled(String p) => _enabledProviders.contains(p);

  String get editorTheme => _editorTheme;
  double get editorFontSize => _editorFontSize;
  int get editorTabSize => _editorTabSize;
  bool get wordWrap => _wordWrap;

  DuckViewMode get viewMode => _viewMode;
  bool get isLocked => _isLocked;

  bool get reduceMotion => _reduceMotion;
  bool get reduceTransparency => _reduceTransparency;
  bool get allowAgentOutsideWorkspaceWrites =>
      _allowAgentOutsideWorkspaceWrites;
  bool get autoVerifyAfterEdits => _autoVerifyAfterEdits;
  bool get chatHidden => _chatHidden;
  String get settingsInitialCategory => _settingsInitialCategory;
  int get settingsOpenRevision => _settingsOpenRevision;

  bool get syncthingEnabled => _syncthingEnabled;
  bool get syncthingAutoShare => _syncthingAutoShare;
  bool get syncthingAutoAcceptRemote => _syncthingAutoAcceptRemote;
  bool get syncthingIgnorePerms => _syncthingIgnorePerms;
  bool get syncthingWriteStignore => _syncthingWriteStignore;
  String get syncthingVersioningPreset => _syncthingVersioningPreset;
  String get syncthingDefaultLandingPath => _syncthingDefaultLandingPath;

  bool get gitnexusEnabled => _gitnexusEnabled;
  bool get gitnexusAutoWiki => _gitnexusAutoWiki;
  String get gitnexusWikiModel => _gitnexusWikiModel;

  // Per-workspace one-shot for the empty-editor duck mischief gag.
  // Pre-loaded by `setDirectory` so the `_DuckMischief` widget can
  // read it synchronously on mount and decide whether to play the
  // full animation or skip straight to the static "quip + button"
  // layout. See `PreferencesService._kDuckMischiefPlayed` for the
  // full rationale.
  bool _duckMischiefPlayed = false;
  bool get duckMischiefPlayedForCurrentProject => _duckMischiefPlayed;
  // Dev affordance — bumped by `replayDuckMischief()` so the
  // `_DuckMischief` widget keyed off this value tears down and
  // re-mounts, which is the only way to get the gag to play
  // again from the same empty-editor surface (otherwise the
  // controller has already finished and `initState` is the only
  // entry point that reads the played-flag).
  int _duckMischiefReplayTick = 0;
  int get duckMischiefReplayTick => _duckMischiefReplayTick;

  AppState() {
    chat = ChatController(
      ollama: _ollamaService,
      gemini: _geminiService,
      anthropic: _anthropicService,
      github: _githubModelsService,
      copilot: _copilotService,
      persistence: _persistence,
      rules: rules,
      prefs: prefs,
      timeline: timeline,
      recentEdits: recentEdits,
      skills: workspaceSkills,
      agentTerminals: agentTerminals,
    );
    autoBackup = AutoBackupScheduler(
      backups: backups,
      prefs: prefs,
      // Resolve workspace at fire-time — the user can switch projects
      // between scheduler ticks, so we must not capture it at construction.
      workspacePathProvider: () async => _currentDirectory,
    );
    // Bridge gitnexus notifications into AppState so widgets that
    // read `state.gitnexus` via `Consumer<AppState>` rebuild when
    // analyze finishes / serve toggles / mcp toggles. Without this
    // the activity-bar icon and the GitNexus settings panel only
    // refresh on whatever unrelated AppState change happens to fire
    // next, which made "I clicked analyze and the icon didn't move"
    // a real complaint.
    gitnexus.addListener(_onGitnexusChanged);
    _bootstrap();
  }

  void _onGitnexusChanged() {
    // GitNexus produces high-frequency updates while streaming
    // analyze stdout; bouncing every chunk through `notifyListeners`
    // would rebuild every Consumer<AppState> listener (which is a
    // lot). Cheap rate-limit: only forward when generating the
    // forward at most every ~120ms. End states (process exit, status
    // flip) come through naturally because the trailing call always
    // fires after the timer elapses.
    if (_gitnexusForwardScheduled) return;
    _gitnexusForwardScheduled = true;
    Future.delayed(const Duration(milliseconds: 120), () {
      _gitnexusForwardScheduled = false;
      notifyListeners();
    });
  }

  bool _gitnexusForwardScheduled = false;

  Future<void> _bootstrap() async {
    await _loadSettings();
    await _loadRecentProjects();
    await recentEdits.init();
    await chat.init();
    await autoBackup.init();
    await chat.reloadExternalTools(_currentDirectory);
    // Remote Access is opt-in and disabled by default. `init` reads
    // the persisted toggle and only spawns the HttpServer if it was
    // previously enabled — so a fresh install never opens a port.
    // Kept last in bootstrap because the network bind is the slowest
    // step and we don't want it to delay UI-affecting work above.
    await remote.init();
    // Attach the live-event bus to the chat controller AFTER its own
    // init has settled. The bus listens to `notifyListeners()` and
    // diffs state into semantic events for `/v1/stream` clients.
    // Detached in `dispose` via `remote.dispose()` (which calls
    // `eventBus.disposeBus()` internally).
    remote.eventBus.attach(chat);
  }

  @override
  void dispose() {
    _fsWatcher?.cancel();
    _fsRefreshDebounce?.cancel();
    autoBackup.dispose();
    timeline.dispose();
    gitnexus.removeListener(_onGitnexusChanged);
    gitnexus.dispose();
    unawaited(_copilotService.dispose());
    remote.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    _enabledProviders = (await prefs.getEnabledProviders()).toSet();
    _ollamaEndpoint = await prefs.getEndpoint();
    _ollamaApiKey = await prefs.getOllamaApiKey();
    _geminiApiKey = await prefs.getGeminiApiKey();
    _anthropicApiKey = await prefs.getAnthropicApiKey();
    _githubModelsApiKey = await prefs.getGithubModelsApiKey();
    _githubModelsOrganization = await prefs.getGithubModelsOrganization();
    _copilotApiKey = await prefs.getCopilotApiKey();
    _copilotUseLoggedInUser = await prefs.getCopilotUseLoggedInUser();
    _openaiApiKey = await prefs.getOpenaiApiKey();
    _toolCompressionEnabled = await prefs.getToolCompressionEnabled();
    _toolCompressionModel = await prefs.getToolCompressionModel();
    _toolCompressionThreshold = await prefs.getToolCompressionThreshold();
    _historySummaryEnabled = await prefs.getHistorySummaryEnabled();
    _historySummaryMaxChars = await prefs.getHistorySummaryMaxChars();
    _historySummaryRefreshDelta = await prefs.getHistorySummaryRefreshDelta();
    _ollamaService.baseUrl = _ollamaEndpoint;
    _ollamaService.apiKey = _ollamaApiKey;
    _geminiService.apiKey = _geminiApiKey;
    _anthropicService.apiKey = _anthropicApiKey;
    _githubModelsService.apiKey = _githubModelsApiKey;
    _githubModelsService.organization = _githubModelsOrganization;
    _copilotService.apiKey = _copilotApiKey;
    _copilotService.useLoggedInUser = _copilotUseLoggedInUser;
    _githubModelsService.unavailableModels
      ..clear()
      ..addAll(await prefs.getGithubUnavailableModels());
    _githubModelsService.onUnavailableModelDiscovered = (id) async {
      // Persist immediately, then refresh the model picker so the dead
      // model disappears without the user having to open Settings and
      // hit Save. Fired during streaming, so we run async and don't
      // block the error-rendering pipeline.
      await prefs.setGithubUnavailableModels(
        _githubModelsService.unavailableModels.toList(),
      );
      await chat.reloadModels(enabledProviders: _enabledProviders);
      notifyListeners();
    };
    _copilotService.unavailableModels
      ..clear()
      ..addAll(await prefs.getCopilotUnavailableModels());
    _copilotService.onUnavailableModelDiscovered = (id) async {
      await prefs.setCopilotUnavailableModels(
        _copilotService.unavailableModels.toList(),
      );
      await chat.reloadModels(enabledProviders: _enabledProviders);
      notifyListeners();
    };
    _editorTheme = await prefs.getEditorTheme();
    _editorFontSize = await prefs.getEditorFontSize();
    _editorTabSize = await prefs.getEditorTabSize();
    _wordWrap = await prefs.getWordWrap();
    final view = await prefs.getViewMode();
    _viewMode = DuckViewMode.values.firstWhere(
      (v) => v.name == view,
      orElse: () => DuckViewMode.normal,
    );
    _isLocked = await prefs.hasPin();
    _reduceMotion = await prefs.getReduceMotion();
    _reduceTransparency = await prefs.getReduceTransparency();
    _allowAgentOutsideWorkspaceWrites = await prefs
        .getAgentAllowOutsideWorkspaceWrites();
    _autoVerifyAfterEdits = await prefs.getAgentAutoVerifyAfterEdits();
    _chatHidden = await prefs.getChatHidden();
    _gitnexusEnabled = await prefs.getGitNexusEnabled();
    _gitnexusAutoWiki = await prefs.getGitNexusAutoWiki();
    _gitnexusWikiModel = await prefs.getGitNexusWikiModel();
    gitnexus.setWikiPreferences(
      autoWikiAfterAnalyze: _gitnexusAutoWiki,
      model: _gitnexusWikiModel,
    );
    await gitnexus.setEnabled(_gitnexusEnabled);
    _syncthingEnabled = await prefs.getSyncthingEnabled();
    _syncthingAutoShare = await prefs.getSyncthingAutoShare();
    _syncthingAutoAcceptRemote = await prefs.getSyncthingAutoAcceptRemote();
    _syncthingIgnorePerms = await prefs.getSyncthingIgnorePerms();
    _syncthingWriteStignore = await prefs.getSyncthingWriteStignore();
    _syncthingVersioningPreset = await prefs.getSyncthingVersioningPreset();
    _syncthingDefaultLandingPath = await prefs.getSyncthingDefaultLandingPath();
    final stEndpoint = await prefs.getSyncthingEndpoint();
    final stApiKey = await prefs.getSyncthingApiKey();
    syncthing.configure(baseUrl: stEndpoint, apiKey: stApiKey);
    // Push our safety defaults into the local Syncthing instance once
    // it's reachable. Idempotent — re-runs are cheap.
    if (_syncthingEnabled) {
      unawaited(_syncthingApplySafetyDefaults());
    }
    notifyListeners();
  }

  Future<void> setReduceMotion(bool v) async {
    _reduceMotion = v;
    await prefs.setReduceMotion(v);
    notifyListeners();
  }

  Future<void> setReduceTransparency(bool v) async {
    _reduceTransparency = v;
    await prefs.setReduceTransparency(v);
    notifyListeners();
  }

  Future<void> setAllowAgentOutsideWorkspaceWrites(bool v) async {
    _allowAgentOutsideWorkspaceWrites = v;
    await prefs.setAgentAllowOutsideWorkspaceWrites(v);
    notifyListeners();
  }

  Future<void> setAutoVerifyAfterEdits(bool v) async {
    if (_autoVerifyAfterEdits == v) return;
    _autoVerifyAfterEdits = v;
    await prefs.setAgentAutoVerifyAfterEdits(v);
    notifyListeners();
  }

  Future<void> setChatHidden(bool v) async {
    if (_chatHidden == v) return;
    _chatHidden = v;
    await prefs.setChatHidden(v);
    notifyListeners();
  }

  Future<void> toggleChatHidden() => setChatHidden(!_chatHidden);

  Future<void> updateProviderSettings({
    required Set<String> enabledProviders,
    required String ollamaEndpoint,
    required String ollamaApiKey,
    required String geminiApiKey,
    required String anthropicApiKey,
    required String githubModelsApiKey,
    required String githubModelsOrganization,
    required String copilotApiKey,
    required bool copilotUseLoggedInUser,
    required String openaiApiKey,
  }) async {
    _enabledProviders = enabledProviders;
    _ollamaEndpoint = ollamaEndpoint;
    _ollamaApiKey = ollamaApiKey.trim();
    _geminiApiKey = geminiApiKey;
    _anthropicApiKey = anthropicApiKey;
    _githubModelsApiKey = githubModelsApiKey;
    _githubModelsOrganization = githubModelsOrganization.trim();
    _copilotApiKey = copilotApiKey.trim();
    _copilotUseLoggedInUser = copilotUseLoggedInUser;
    _openaiApiKey = openaiApiKey;
    _ollamaService.baseUrl = _ollamaEndpoint;
    _ollamaService.apiKey = _ollamaApiKey;
    _geminiService.apiKey = _geminiApiKey;
    _anthropicService.apiKey = _anthropicApiKey;
    _githubModelsService.apiKey = _githubModelsApiKey;
    _githubModelsService.organization = _githubModelsOrganization;
    _copilotService.apiKey = _copilotApiKey;
    _copilotService.useLoggedInUser = _copilotUseLoggedInUser;
    await prefs.setEnabledProviders(enabledProviders.toList());
    await prefs.setEndpoint(ollamaEndpoint);
    await prefs.setOllamaApiKey(_ollamaApiKey);
    await prefs.setGeminiApiKey(geminiApiKey);
    await prefs.setAnthropicApiKey(anthropicApiKey);
    await prefs.setGithubModelsApiKey(githubModelsApiKey);
    await prefs.setGithubModelsOrganization(_githubModelsOrganization);
    await prefs.setCopilotApiKey(_copilotApiKey);
    await prefs.setCopilotUseLoggedInUser(_copilotUseLoggedInUser);
    await prefs.setOpenaiApiKey(openaiApiKey);
    await chat.reloadModels(enabledProviders: _enabledProviders);
    notifyListeners();
  }

  Future<void> updateToolCompressionSettings({
    required bool enabled,
    required String model,
    required int threshold,
  }) async {
    _toolCompressionEnabled = enabled;
    _toolCompressionModel = model.trim();
    _toolCompressionThreshold = threshold;
    await prefs.setToolCompressionEnabled(enabled);
    await prefs.setToolCompressionModel(_toolCompressionModel);
    await prefs.setToolCompressionThreshold(threshold);
    notifyListeners();
  }

  Future<void> updateHistorySummarySettings({
    required bool enabled,
    required int maxChars,
    required int refreshDelta,
  }) async {
    _historySummaryEnabled = enabled;
    _historySummaryMaxChars = maxChars <= 0 ? 1200 : maxChars;
    _historySummaryRefreshDelta = refreshDelta <= 0 ? 10 : refreshDelta;
    await prefs.setHistorySummaryEnabled(enabled);
    await prefs.setHistorySummaryMaxChars(_historySummaryMaxChars);
    await prefs.setHistorySummaryRefreshDelta(_historySummaryRefreshDelta);
    notifyListeners();
  }

  /// Clears the locally-cached set of GitHub Models that previously
  /// returned `400 unavailable_model`. Use this after GitHub rolls out
  /// a model that was previously gated, so it reappears in the picker
  /// on the next Save.
  Future<void> resetGithubUnavailableModels() async {
    _githubModelsService.unavailableModels.clear();
    await prefs.setGithubUnavailableModels(const <String>[]);
    await chat.reloadModels(enabledProviders: _enabledProviders);
    notifyListeners();
  }

  Future<void> updateEditorSettings({
    String? theme,
    double? fontSize,
    int? tabSize,
    bool? wordWrap,
  }) async {
    if (theme != null) {
      _editorTheme = theme;
      await prefs.setEditorTheme(theme);
    }
    if (fontSize != null) {
      _editorFontSize = fontSize;
      await prefs.setEditorFontSize(fontSize);
    }
    if (tabSize != null) {
      _editorTabSize = tabSize;
      await prefs.setEditorTabSize(tabSize);
    }
    if (wordWrap != null) {
      _wordWrap = wordWrap;
      await prefs.setWordWrap(wordWrap);
    }
    notifyListeners();
  }

  void setViewMode(DuckViewMode mode) {
    _viewMode = mode;
    prefs.setViewMode(mode.name);
    notifyListeners();
  }

  void toggleZenMode() {
    setViewMode(
      _viewMode == DuckViewMode.zen ? DuckViewMode.normal : DuckViewMode.zen,
    );
  }

  void toggleSideEyeMode() {
    setViewMode(
      _viewMode == DuckViewMode.sideEye
          ? DuckViewMode.normal
          : DuckViewMode.sideEye,
    );
  }

  // --- Lock ---
  Future<void> lockNow() async {
    if (await prefs.hasPin()) {
      _isLocked = true;
      notifyListeners();
    }
  }

  Future<bool> unlock(String pin) async {
    final ok = await prefs.verifyPin(pin);
    if (ok) {
      _isLocked = false;
      notifyListeners();
    }
    return ok;
  }

  Future<void> setPin(String pin) async {
    await prefs.setPin(pin);
    notifyListeners();
  }

  Future<void> clearPin() async {
    await prefs.clearPin();
    _isLocked = false;
    notifyListeners();
  }

  Future<bool> hasPin() => prefs.hasPin();

  // --- Workspace ---
  Future<void> _loadRecentProjects() async {
    _recentProjects = await _workspaceService.getRecentProjects();
    notifyListeners();
  }

  Future<void> openFile(File file) async {
    if (!_openFiles.any((f) => f.path == file.path)) {
      _openFiles.add(file);
      // Detect by extension first. Images / audio / video / known
      // binary formats are routed straight to BinaryPreviewPane in
      // the editor, so we DO NOT readAsString — a JPG decoded as
      // utf-8 throws `FileSystemException: Failed to decode data
      // using encoding 'utf-8'` and the user previously saw that
      // exception text dumped into the editor body. Stuffing an
      // empty string into the cache is fine: the editor pane never
      // looks at it for binary kinds.
      final kind = FileKindDetector.detect(file.path);
      if (kind == FileKind.text) {
        try {
          final content = await file.readAsString();
          _fileContents[file.path] = content;
          _savedFileContents[file.path] = content;
        } catch (_) {
          // False-positive on text detection — extension says text
          // (or no extension) but the bytes don't decode as utf-8.
          // Most likely a binary file the heuristic missed; leave
          // the cache empty so BinaryPreviewPane still renders a
          // generic preview instead of the noisy error string.
          _fileContents[file.path] = '';
          _savedFileContents[file.path] = '';
        }
      } else {
        _fileContents[file.path] = '';
        _savedFileContents[file.path] = '';
      }
    }
    _activeFile = _openFiles.firstWhere((f) => f.path == file.path);
    // Fire-and-forget: ensure the timeline has at least a baseline
    // entry for any TEXT file the user has visibly opened. Cheap
    // when already baselined; the alternative — relying solely on
    // FS events for the first capture — means a first-time edit
    // lands with an empty `prevHash` and the diff view has nothing
    // to compare against. Skipped for binary/media kinds because
    // the timeline diff view is text-only and storing baseline
    // blobs of large media files would balloon the timeline cache.
    if (FileKindDetector.isText(file.path)) {
      unawaited(timeline.ensureBaseline(file.path));
    }
    notifyListeners();
  }

  /// Opens the settings view as a virtual tab in the editor area.
  void openSettingsTab({String category = 'general'}) {
    _settingsInitialCategory = category;
    _settingsOpenRevision++;
    final sentinel = File(settingsSentinel);
    if (!_openFiles.any((f) => f.path == settingsSentinel)) {
      _openFiles.add(sentinel);
      _fileContents[settingsSentinel] = '';
      _savedFileContents[settingsSentinel] = '';
    }
    _activeFile = _openFiles.firstWhere((f) => f.path == settingsSentinel);
    notifyListeners();
  }

  /// Opens the process manager as a virtual tab. Mirrors
  /// `openSettingsTab` exactly: we materialise a sentinel `File`
  /// under [processManagerSentinel] so the editor pane's tab strip
  /// has something to render, and the editor switches to
  /// `ProcessManagerView` when the active path matches the
  /// sentinel. Re-opening focuses the existing tab instead of
  /// stacking duplicates.
  void openProcessManagerTab() {
    final sentinel = File(processManagerSentinel);
    if (!_openFiles.any((f) => f.path == processManagerSentinel)) {
      _openFiles.add(sentinel);
      _fileContents[processManagerSentinel] = '';
      _savedFileContents[processManagerSentinel] = '';
    }
    _activeFile = _openFiles.firstWhere(
      (f) => f.path == processManagerSentinel,
    );
    notifyListeners();
  }

  /// Opens a new untitled (unsaved) tab in the editor.
  void openUntitledTab() {
    _untitledCounter++;
    final path = '$untitledPrefix$_untitledCounter';
    final sentinel = File(path);
    _openFiles.add(sentinel);
    _fileContents[path] = '';
    _savedFileContents[path] = '';
    _activeFile = sentinel;
    notifyListeners();
  }

  /// Materialise an untitled tab to a real file on disk.
  /// Moves the content from the sentinel path to the real path,
  /// swaps the tab entry, and writes to disk.
  Future<bool> saveUntitledAs(String untitledPath, String realPath) async {
    final content = _fileContents[untitledPath] ?? '';
    try {
      final realFile = File(realPath);
      await realFile.writeAsString(content);
      // Swap the tab: remove old sentinel, insert real file at same position.
      final index = _openFiles.indexWhere((f) => f.path == untitledPath);
      if (index >= 0) {
        _openFiles[index] = realFile;
      }
      _fileContents.remove(untitledPath);
      _savedFileContents.remove(untitledPath);
      _fileContents[realPath] = content;
      _savedFileContents[realPath] = content;
      if (_activeFile?.path == untitledPath) {
        _activeFile = realFile;
      }
      notifyListeners();
      return true;
    } catch (e) {
      debugPrint('Error saving untitled as $realPath: $e');
      return false;
    }
  }

  void closeFile(File file) {
    _openFiles.removeWhere((f) => f.path == file.path);
    _fileContents.remove(file.path);
    _savedFileContents.remove(file.path);
    _fileLanguageOverrides.remove(file.path);
    // Drop the remote-mirror provenance entry too. The on-disk
    // mirror file itself stays — re-opening the same remote path
    // re-downloads (cheap on small files) but spares us cache-eviction
    // bookkeeping. `clearCache` from Settings is the heavy hammer.
    _ssh?.remoteFiles.forget(file.path);
    if (_activeFile?.path == file.path) {
      _activeFile = _openFiles.isNotEmpty ? _openFiles.last : null;
    }
    notifyListeners();
  }

  void setActiveFile(File file) {
    _activeFile = file;
    notifyListeners();
  }

  /// Reorder the open-files list. Mirrors `ReorderableListView`'s
  /// `(oldIndex, newIndex)` contract: when the destination is past the
  /// source, Flutter passes `newIndex` one step too high to account for
  /// the about-to-be-removed source. Adjust before splicing.
  void reorderOpenFile(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _openFiles.length) return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (newIndex < 0 || newIndex >= _openFiles.length) return;
    final f = _openFiles.removeAt(oldIndex);
    _openFiles.insert(newIndex, f);
    notifyListeners();
  }

  void updateFileContent(String content) {
    if (_activeFile != null) {
      updateFileContentFor(_activeFile!.path, content);
    }
  }

  void updateFileContentFor(String path, String content) {
    if (_fileContents.containsKey(path)) {
      _fileContents[path] = content;
      notifyListeners();
    }
  }

  /// Re-sync an open file's editor buffer to a known on-disk
  /// content snapshot. Used by the timeline restore flow: after
  /// `restoreToRevision` writes the blob back to disk, the open
  /// editor tab's `_fileContents[path]` is still the pre-restore
  /// buffer. Without this call the user sees the OLD content in
  /// the tab plus a "modified" dirty indicator, even though the
  /// file on disk matches `content` exactly. We update both the
  /// live and the "saved" maps so `isFileDirty` returns false
  /// post-restore.
  void resyncOpenFileFromDisk(String path, String content) {
    if (!_fileContents.containsKey(path)) return;
    _fileContents[path] = content;
    _savedFileContents[path] = content;
    notifyListeners();
  }

  void overrideLanguage(String path, String langId) {
    _fileLanguageOverrides[path] = langId;
    notifyListeners();
  }

  Future<void> saveFile() async {
    if (_activeFile != null) {
      await saveFileByPath(_activeFile!.path);
    }
  }

  Future<void> saveFileByPath(String path) async {
    final file = _openFiles.cast<File?>().firstWhere(
      (f) => f?.path == path,
      orElse: () => null,
    );
    if (file == null) return;

    final pendingContent = _fileContents[path];
    if (pendingContent == null) return;

    // SSH remote-mirror buffers ride a separate save path: SFTP
    // upload + conflict-detect + snapshot refresh. The local cache
    // file under `<appSupport>/lumen/ssh-mirror/...` is updated by
    // the service itself once the upload succeeds — we still call
    // the local writeAsString below as a defence-in-depth so the
    // local cache is in sync even if the service somehow skipped
    // its own write. No timeline entry for remote-mirror saves
    // (the timeline is workspace-scoped and these files live
    // outside the workspace).
    final remoteService = _ssh?.remoteFiles;
    if (remoteService != null && remoteService.isRemoteMirror(path)) {
      final result = await remoteService.saveIfRemote(
        localPath: path,
        content: pendingContent,
        resolveConflict: _sshConflictResolver,
      );
      if (result == null) {
        // The service decided this isn't a mirror after all (race
        // with `forget` from a tab close). Fall through to the
        // local-only write.
      } else {
        switch (result.outcome) {
          case SshSaveOutcome.succeeded:
            _savedFileContents[path] = pendingContent;
            try {
              await file.writeAsString(pendingContent);
            } catch (_) {}
            recentEdits.invalidate(path);
            notifyListeners();
            return;
          case SshSaveOutcome.cancelled:
            // User explicitly chose not to overwrite. Don't mark the
            // buffer clean; the dirty dot stays so the user knows
            // the local has unsaved changes.
            return;
          case SshSaveOutcome.failed:
            debugPrint('SSH save failed: ${result.errorMessage}');
            return;
        }
      }
    }

    try {
      await file.writeAsString(pendingContent);
      _savedFileContents[path] = pendingContent;
      // Capture the manual save in the revision timeline. Awaited
      // (cheap: just a hash + maybe blob write + journal append)
      // so the timeline rail repaint observed via `notifyListeners`
      // sees the new entry on the same frame as the "Saved" badge.
      await timeline.recordWrite(
        path,
        origin: TimelineOrigin.userSave,
        note: 'Manual save',
      );
      // The user just made a deliberate "this is mine now" gesture —
      // drop the recent-agent-edit highlights for this file so they
      // don't paint forever even though the user has clearly taken
      // ownership. Matches the design contract: "save = clear".
      recentEdits.invalidate(path);
      notifyListeners();
    } catch (e) {
      debugPrint('Error saving file: $e');
    }
  }

  /// Open a remote file via the bound [SshController]'s
  /// [SshRemoteFileService]. Downloads to the local mirror cache,
  /// adds the mirror file to [openFiles], and focuses it.
  ///
  /// Throws when no SSH controller is bound, when no live connection
  /// exists for [hostId], or when the SFTP open / download fails.
  /// Caller (the activity-bar / Remote pane) is responsible for
  /// turning those throws into user-facing toasts.
  Future<void> openRemoteFile({
    required String hostId,
    required String remotePath,
  }) async {
    final controller = _ssh;
    if (controller == null) {
      throw StateError('SSH controller not bound');
    }
    final session = controller.findSessionForHost(hostId);
    final conn = session?.connection;
    if (conn == null) {
      throw StateError('No active SSH connection for host $hostId');
    }
    final mirror = await controller.remoteFiles.open(
      conn: conn,
      remotePath: remotePath,
    );
    // Open the mirror through the regular file path; the timeline
    // does NOT baseline remote-mirror files (their absolute path
    // sits outside the workspace, so timeline.ensureBaseline would
    // be a no-op anyway, but spelling it out keeps reviewer
    // intent unambiguous).
    await openFile(mirror);
  }

  /// Download a remote file into the open workspace via SFTP. The
  /// counterpart to [openRemoteFile] (which opens a *mirrored* file
  /// for save-back) — `grabRemoteFile` is a one-shot copy with no
  /// save-back channel, no in-memory mirror tracking. Triggered by
  /// the bundled `lumen-grab <file>` shell helper (the bridge in
  /// main.dart subscribes to [SshController.onLumenGrabRequest]).
  ///
  /// Conflict resolution: if a file already exists at the resolved
  /// local path, the bound [_sshGrabConflictResolver] decides what
  /// to do (replace / keep-both with `(1)` suffix / cancel). The
  /// resolver is set in [bindSsh] and shows the prompt UI; this
  /// method only consumes its decision.
  ///
  /// On success: refreshes the file explorer so the new file shows
  /// up in the tree, returns the absolute local path. On `cancel`:
  /// returns null. Throws on hard failures (no project open, no
  /// connection, SFTP error, file too large).
  Future<String?> grabRemoteFile({
    required String hostId,
    required String remotePath,
  }) async {
    final controller = _ssh;
    if (controller == null) {
      throw StateError('SSH controller not bound');
    }
    final session = controller.findSessionForHost(hostId);
    final conn = session?.connection;
    if (conn == null) {
      throw StateError('No active SSH connection for host $hostId');
    }
    final root = _currentDirectory;
    if (root == null || root.isEmpty) {
      throw StateError('No workspace open — cannot grab into project');
    }

    // Refuse oversized files for the same reason `openRemoteFile`
    // does (avoid a 500 MB log accidentally hanging the IDE on a
    // single SFTP call). Same threshold; if grab needs to scale up
    // later we can split the cap.
    final sftp = await conn.sftp();
    final attrs = await sftp.stat(remotePath);
    final size = attrs.size;
    if (size != null && size > kSshRemoteFileMaxBytes) {
      raiseRemoteFileTooLarge(size);
    }

    final basename = p.basename(remotePath);
    if (basename.isEmpty || basename == '/' || basename == '.') {
      throw StateError('Invalid remote path: $remotePath');
    }
    final candidate = p.join(root, basename);

    var finalPath = candidate;
    if (await File(candidate).exists()) {
      final decision = await _sshGrabConflictResolver(
        existingLocalPath: candidate,
        remotePath: remotePath,
        hostLabel: session?.host.displayName ?? hostId,
      );
      switch (decision) {
        case SshGrabConflictDecision.cancel:
          return null;
        case SshGrabConflictDecision.replace:
          // Land on the same path; SFTP open with truncate below.
          finalPath = candidate;
        case SshGrabConflictDecision.keepBoth:
          finalPath = await _firstAvailableSibling(candidate);
      }
    }

    // Stream-download. Same `closeDestination: true` contract as
    // `openRemoteFile`: dartssh2 flushes + closes the IOSink on the
    // success and throw paths.
    final localFile = File(finalPath);
    await localFile.parent.create(recursive: true);
    final sink = localFile.openWrite();
    try {
      await sftp.download(remotePath, sink, closeDestination: true);
    } catch (_) {
      try {
        await sink.close();
      } catch (_) {}
      rethrow;
    }

    refreshDirectory();
    return finalPath;
  }

  /// Resolves a non-colliding path next to [originalPath] by
  /// appending ` (N)` before the extension, with N incrementing
  /// until we find a free slot. Mirrors macOS Finder's "Keep Both"
  /// suffix style — `report.txt` → `report (1).txt`,
  /// `report (1).txt` already in use → `report (2).txt`, …
  /// Caps at 999 to avoid an infinite loop on a degenerate dir.
  Future<String> _firstAvailableSibling(String originalPath) async {
    final dir = p.dirname(originalPath);
    final ext = p.extension(originalPath);
    final stem = p.basenameWithoutExtension(originalPath);
    for (var i = 1; i <= 999; i++) {
      final next = p.join(dir, '$stem ($i)$ext');
      if (!await File(next).exists()) {
        return next;
      }
    }
    throw StateError('Too many sibling collisions for $originalPath');
  }

  Future<String> restoreTimelineChangesForMessage(
    String messageId, {
    String? legacyMessageId,
  }) async {
    final result = await timeline.restoreMessageChanges(
      messageId,
      legacyMessageId: legacyMessageId,
    );
    await _resyncTouchedPaths(result.touchedRelPaths);
    return result.message;
  }

  /// Project-wide "revert to this point in time" entry point. Wraps
  /// [TimelineService.restoreToPointInTime] with the editor + explorer
  /// resync that matches the per-message restore path. Returns the
  /// service's result so the UI can show counts + the toast text.
  Future<TimelineBulkRestoreResult> revertProjectToPointInTime(
    DateTime when, {
    bool deleteFilesCreatedAfter = false,
  }) async {
    final result = await timeline.restoreToPointInTime(
      when,
      deleteFilesCreatedAfter: deleteFilesCreatedAfter,
    );
    await _resyncTouchedPaths(result.touchedRelPaths);
    return result;
  }

  /// Cursor / Antigravity-style "revert to before this message" applied
  /// at chat scope. Truncates the active session at [index] (so the
  /// pivot message and every message after it are gone) and restores
  /// every agent file change tied to the dropped assistant messages
  /// in one chronological pass. Returns the [ChatRevertOutcome] so
  /// callers can pre-fill the composer / show a contextual toast.
  ///
  /// This is the user-bubble surface for revert; the assistant-bubble
  /// surface still routes through [restoreTimelineChangesForMessage]
  /// because that one is "undo just this turn's file changes" (no
  /// chat truncation), which Cursor surfaces as the assistant-bubble
  /// "Restore" affordance.
  Future<ChatRevertOutcome> revertChatToBeforeMessage(int index) async {
    final outcome = await chat.revertToBeforeMessage(index, timeline);
    await _resyncTouchedPaths(outcome.touchedRelPaths);
    return outcome;
  }

  Future<void> _resyncTouchedPaths(List<String> rels) async {
    final ws = _currentDirectory;
    if (ws == null || rels.isEmpty) return;
    for (final rel in rels) {
      final abs = p.join(ws, rel.replaceAll('/', p.separator));
      final file = File(abs);
      if (await file.exists()) {
        try {
          resyncOpenFileFromDisk(abs, await file.readAsString());
        } catch (_) {
          // Binary or unreadable file; leave any open editor tab alone.
        }
      } else {
        noteEntityDeleted(abs);
      }
    }
    refreshDirectory();
  }

  /// Update editor bookkeeping after a file or folder has been moved on disk.
  ///
  /// The explorer's internal drag/drop uses `File.rename` /
  /// `Directory.rename` directly for the actual filesystem move. Any open
  /// editor tabs still point at the old absolute path unless we rewrite the
  /// in-memory structures here. For a file move we remap exactly that file;
  /// for a folder move we remap every open tab under the moved folder.
  ///
  /// This is deliberately bookkeeping-only: it assumes the disk move already
  /// succeeded. If the caller invokes it before the rename, an open tab could
  /// briefly point to a file that doesn't exist.
  void noteEntityMoved(String oldPath, String newPath) {
    String norm(String value) => p.normalize(value);
    final oldNorm = norm(oldPath);
    final newNorm = norm(newPath);

    String remapPath(String path) {
      final pathNorm = norm(path);
      if (pathNorm == oldNorm) return newNorm;
      if (p.isWithin(oldNorm, pathNorm)) {
        final rel = p.relative(pathNorm, from: oldNorm);
        return p.join(newNorm, rel);
      }
      return path;
    }

    void moveMapKey(Map<String, String> map, String from, String to) {
      final value = map.remove(from);
      if (value != null) map[to] = value;
    }

    var changed = false;
    for (var i = 0; i < _openFiles.length; i++) {
      final oldFilePath = _openFiles[i].path;
      final mapped = remapPath(oldFilePath);
      if (mapped == oldFilePath) continue;
      _openFiles[i] = File(mapped);
      moveMapKey(_fileContents, oldFilePath, mapped);
      moveMapKey(_savedFileContents, oldFilePath, mapped);
      moveMapKey(_fileLanguageOverrides, oldFilePath, mapped);
      if (_activeFile?.path == oldFilePath) _activeFile = File(mapped);
      changed = true;
    }

    if (changed) notifyListeners();
  }

  /// Update editor bookkeeping after a file or folder has been deleted on disk.
  ///
  /// File-explorer deletes can remove a folder containing multiple open tabs.
  /// Those tabs must disappear immediately instead of pointing at paths that no
  /// longer exist. For a file delete this removes exactly that file; for a
  /// folder delete it removes every open tab below that folder.
  void noteEntityDeleted(String path) {
    final root = p.normalize(path);
    final before = _openFiles.length;
    _openFiles.removeWhere((f) {
      final filePath = p.normalize(f.path);
      final remove = filePath == root || p.isWithin(root, filePath);
      if (remove) {
        _fileContents.remove(f.path);
        _savedFileContents.remove(f.path);
        _fileLanguageOverrides.remove(f.path);
      }
      return remove;
    });
    if (_activeFile != null) {
      final activePath = p.normalize(_activeFile!.path);
      if (activePath == root || p.isWithin(root, activePath)) {
        _activeFile = _openFiles.isNotEmpty ? _openFiles.last : null;
      }
    }
    if (_openFiles.length != before) notifyListeners();
  }

  /// Open [path] as the workspace.
  ///
  /// Returns `true` if [path] had **never been opened before** (not in
  /// the persisted recent-projects list at the moment this method
  /// was called) — call sites use the return value to drive the
  /// new-project wizard (skill generator + GitNexus + Syncthing
  /// prompt). The check is done *before* `addRecentProject`, so the
  /// very first open of a project always returns `true` exactly once.
  ///
  /// Side effects (in order):
  ///   1. Editor state cleared (open files, contents, active file).
  ///   2. Filesystem watcher rebound to the new path.
  ///   3. Recent-projects list updated.
  ///   4. **Chat tabs swapped** to this project's bucket via
  ///      `chat.bindToWorkspace(path)` — see ChatController for the
  ///      per-workspace scoping rules. Brand-new projects get a
  ///      fresh empty chat tab automatically.
  ///   5. Listeners notified.
  ///   6. Syncthing auto-share runs in the background if enabled.
  Future<bool> setDirectory(String path) async {
    // Snapshot the recents list BEFORE addRecentProject mutates it —
    // case-insensitive normalize matches the same lower/forward-slash
    // canonicalization PreferencesService uses for tab buckets, so
    // Windows path-casing variants don't make the same folder look
    // "new" twice.
    String norm(String p) => p.toLowerCase().replaceAll('\\', '/');
    final isNewProject = !_recentProjects.map(norm).contains(norm(path));

    _currentDirectory = path;
    _openFiles.clear();
    _fileContents.clear();
    _savedFileContents.clear();
    _fileLanguageOverrides.clear();
    _activeFile = null;
    // Pre-load the per-workspace duck mischief flag so `_DuckMischief`
    // (which mounts as soon as the editor area renders with no open
    // files) can read it synchronously without flashing the static
    // "quip + button" layout before the animation kicks in.
    _duckMischiefPlayed = await prefs.getDuckMischiefPlayedForWorkspace(path);
    _restartFileWatcher(path);
    // Mount the per-workspace revision timeline. Bind is awaited so
    // any subsequent file open / save lands in the right journal,
    // not the previous workspace's. Heavy lifting (journal load,
    // initial prune sweep) happens off-thread inside the service.
    await timeline.bindToWorkspace(path);
    recentEdits.bindWorkspace(path);
    await gitnexus.bindWorkspace(path);
    await _workspaceService.addRecentProject(path);
    await _loadRecentProjects();
    // Per-project chat tabs: persist the previous workspace's tab
    // state, then load this one's (or seed a fresh tab if it's the
    // first time the project is opened under the scoped scheme).
    await chat.bindToWorkspace(path);
    // Pre-load workspace skills so the Settings UI can render them
    // immediately (the chat path also reloads on every send, but
    // settings-first opens don't go through that path).
    unawaited(workspaceSkills.reload(path));
    notifyListeners();
    _syncthingAutoShareIfNeeded(path);
    return isNewProject;
  }

  /// Returns `true` if Syncthing is enabled, auto-share is OFF, and the
  /// folder at [path] is not already registered — i.e. we should ask the
  /// user if they want to share it.
  Future<bool> shouldPromptSyncthingShare(String path) async {
    if (!_syncthingEnabled || _syncthingAutoShare) return false;
    try {
      return !(await syncthing.isFolderRegistered(path));
    } catch (_) {
      return false;
    }
  }

  /// Manually trigger Syncthing sharing for a path (user accepted the prompt).
  void syncthingShareManually(String path) {
    final prev = _syncthingAutoShare;
    _syncthingAutoShare = true; // temporarily enable so the helper runs
    _syncthingAutoShareIfNeeded(path);
    _syncthingAutoShare = prev; // restore
  }

  /// Refreshes the file explorer without nuking open files.
  ///
  /// Bumps `_fileExplorerRefreshTick` so cached `_FileTree._children`
  /// in the explorer's State get invalidated — `notifyListeners`
  /// alone wouldn't trigger a reload because Flutter reuses the
  /// existing State across rebuilds when the widget identity / key
  /// doesn't change.
  void refreshDirectory() {
    _fileExplorerRefreshTick++;
    notifyListeners();
  }

  /// Re-read [path] from disk and refresh the open editor's buffer.
  /// Called from the FS watcher when a tracked open file is modified
  /// externally (typically by the agent's `edit_file` / `create_file`
  /// / `multi_edit` / `append_file` tools). Caller is responsible for
  /// gating on `!isFileDirty(path)` so user edits-in-progress aren't
  /// clobbered.
  Future<void> _resyncOpenBufferFromDisk(String path) async {
    try {
      final f = File(path);
      if (!await f.exists()) return;
      final content = await f.readAsString();
      // Idempotent — comparing first avoids a no-op notifyListeners
      // every time the FS watcher echoes a write that already matches
      // our in-memory state (common when our own save just landed).
      if (_fileContents[path] == content) return;
      _fileContents[path] = content;
      _savedFileContents[path] = content;
      notifyListeners();
    } catch (e) {
      // Swallow — read failures (file deleted between event + read,
      // permission flap, encoding) shouldn't crash the FS event loop.
      // The user can still close + reopen the file as the manual
      // escape hatch.
      debugPrint('AppState._resyncOpenBufferFromDisk failed for $path: $e');
    }
  }

  /// (Re)bind the recursive filesystem watcher to [path]. Called
  /// from `setDirectory` (new workspace), `closeWorkspace` (path =
  /// null, tears it down), and `dispose`.
  ///
  /// Errors are swallowed because the watcher is a quality-of-life
  /// feature — manual refresh button still works if the OS refuses
  /// the watch (e.g. on a read-only mount or a path with too many
  /// subdirs to bind on Windows).
  void _restartFileWatcher(String? path) {
    _fsWatcher?.cancel();
    _fsWatcher = null;
    _fsRefreshDebounce?.cancel();
    _fsRefreshDebounce = null;
    if (path == null) return;
    try {
      final dir = Directory(path);
      if (!dir.existsSync()) return;
      _fsWatcher = dir
          .watch(events: FileSystemEvent.all, recursive: true)
          .listen(
            _onFsEvent,
            onError: (Object e) {
              // Logging only — the explorer manual-refresh button
              // still works without the watcher.
              debugPrint('AppState fs watcher error: $e');
            },
            cancelOnError: false,
          );
    } catch (e) {
      debugPrint('AppState fs watcher init failed: $e');
    }
  }

  void _onFsEvent(FileSystemEvent event) {
    final cwd = _currentDirectory;
    if (cwd == null) return;
    // Drop events under build / dependency dirs — they fire
    // constantly during npm install / pub get / etc., and the
    // explorer doesn't show them anyway (those dirs are in the
    // tree-walk ignore set used by the agent's TREE / SEARCH
    // tools too).
    final relPath = p.relative(event.path, from: cwd);
    final segments = relPath.split(RegExp(r'[/\\]'));
    if (segments.any(_fsWatcherIgnore.contains)) return;

    // Forward each interesting event to the timeline. The service
    // dedupes by `(path, hash)` so a write that the agent recorder
    // already captured in-process won't double-log when the OS
    // delivers the matching FS event a few ms later. Events for
    // directories are skipped — the timeline only tracks files.
    // We don't await these — they hash + gzip + maybe append and
    // we don't want a slow disk to hold up the explorer refresh
    // debounce below.
    if (event is FileSystemModifyEvent || event is FileSystemCreateEvent) {
      if (FileSystemEntity.isFileSync(event.path)) {
        unawaited(
          timeline.recordWrite(
            event.path,
            origin: TimelineOrigin.fsEvent,
            note: 'External change detected',
          ),
        );
        // Re-read the file into `_fileContents` so the open editor
        // tab visibly updates after the agent (or any external
        // process) writes. Without this the editor pane keeps
        // showing the stale buffer until the user manually
        // close + re-opens the tab. Conflict avoidance: skip the
        // resync when the buffer is dirty so we never silently
        // discard the user's in-progress edits — the user's
        // typing wins, the agent's write is on disk only until
        // they save (and overwrite it themselves).
        if (_fileContents.containsKey(event.path) && !isFileDirty(event.path)) {
          unawaited(_resyncOpenBufferFromDisk(event.path));
        }
      }
    } else if (event is FileSystemDeleteEvent) {
      unawaited(
        timeline.recordDelete(
          event.path,
          origin: TimelineOrigin.fsEvent,
          note: 'External delete detected',
        ),
      );
    } else if (event is FileSystemMoveEvent) {
      final dst = event.destination;
      if (dst != null && FileSystemEntity.isFileSync(dst)) {
        unawaited(
          timeline.recordRename(
            event.path,
            dst,
            origin: TimelineOrigin.fsEvent,
            note: 'External rename detected',
          ),
        );
      }
    }

    // Debounce: bursts of events (creating a 1k-file project,
    // a git checkout, a build run) should fold into one refresh
    // ~250 ms after the last event lands. Without this the
    // explorer would `listSync` per file, freezing the UI.
    _fsRefreshDebounce?.cancel();
    _fsRefreshDebounce = Timer(
      const Duration(milliseconds: 250),
      refreshDirectory,
    );
  }

  Future<void> removeRecentProject(String path) async {
    await _workspaceService.removeRecentProject(path);
    await _loadRecentProjects();
  }

  /// Called once by `_DuckMischief` after the empty-editor mascot gag
  /// finishes its in-flight performance for the current workspace. Flips
  /// the in-memory cache AND persists the per-workspace pref so the
  /// next time this project is opened (now or after an app restart) the
  /// gag is skipped and the static "quip + button" layout is shown
  /// directly. Intentionally does NOT `notifyListeners` — the widget
  /// already knows the gag is finishing and a notify here would just
  /// trigger an extra rebuild for no visible change.
  Future<void> markDuckMischiefPlayedForCurrentProject() async {
    if (_duckMischiefPlayed) return;
    _duckMischiefPlayed = true;
    await prefs.setDuckMischiefPlayedForWorkspace(_currentDirectory, true);
  }

  /// Dev / debugging affordance. Clears the per-workspace played flag
  /// AND bumps `duckMischiefReplayTick` so the `_DuckMischief` widget
  /// (keyed off that tick) tears down and re-mounts. If the empty
  /// editor surface is currently visible, the gag plays immediately;
  /// if files are open, it plays the next time the user lands on the
  /// empty editor. Wired into the Command Palette as `dev.replayDuck`
  /// — not exposed via the menu bar because it's an animation-replay,
  /// not a user-facing feature.
  Future<void> replayDuckMischief() async {
    _duckMischiefPlayed = false;
    _duckMischiefReplayTick++;
    await prefs.setDuckMischiefPlayedForWorkspace(_currentDirectory, false);
    notifyListeners();
  }

  Future<void> closeWorkspace() async {
    _currentDirectory = null;
    _openFiles.clear();
    _fileContents.clear();
    _savedFileContents.clear();
    _fileLanguageOverrides.clear();
    _activeFile = null;
    // No workspace = no duck gag (the welcome screen takes over). Reset
    // to the default so a stale `true` from the previous project doesn't
    // bleed into the next setDirectory call before its preload runs.
    _duckMischiefPlayed = false;
    _restartFileWatcher(null); // tear down the recursive watcher
    await timeline.bindToWorkspace(null);
    recentEdits.bindWorkspace(null);
    await gitnexus.bindWorkspace(null);
    // Swap chat tabs back to the no-workspace bucket — leaving a
    // project's tabs mounted while the workspace is closed would
    // make the chat panel show project-specific history on the
    // Welcome screen, which is misleading.
    await chat.bindToWorkspace(null);
    unawaited(workspaceSkills.reload(null));
    notifyListeners();
  }

  // --- Chat convenience pass-throughs (so legacy widgets keep working) ---

  Future<void> sendChatMessage(String message) async {
    await chat.sendMessage(
      message,
      workspacePath: _currentDirectory,
      activeFilePath: _activeFile?.path,
      openFilePaths: _openFiles.map((f) => f.path).toList(),
    );
  }

  void appendTerminalOutputToChat(String text) {
    chat.appendTerminalOutput(text, workspacePath: _currentDirectory);
  }

  // --- GitNexus integration master switch ---

  /// Persist and apply the GitNexus master toggle. When `enabled` is
  /// false, [GitNexusService.setEnabled] tears down its probe loop
  /// and stops any owned daemon (see service docs for what happens
  /// to externally-owned orphans). Settings UI rebuilds via
  /// `notifyListeners`; the activity-bar icon checks this flag and
  /// hides itself when off.
  Future<void> setGitNexusEnabled(bool enabled) async {
    if (_gitnexusEnabled == enabled) return;
    _gitnexusEnabled = enabled;
    await prefs.setGitNexusEnabled(enabled);
    await gitnexus.setEnabled(enabled);
    notifyListeners();
  }

  Future<void> updateGitNexusWikiSettings({
    required bool autoWiki,
    required String wikiModel,
  }) async {
    final normalizedModel = wikiModel.trim();
    _gitnexusAutoWiki = autoWiki;
    _gitnexusWikiModel = normalizedModel;
    await prefs.setGitNexusAutoWiki(autoWiki);
    await prefs.setGitNexusWikiModel(normalizedModel);
    gitnexus.setWikiPreferences(
      autoWikiAfterAnalyze: autoWiki,
      model: normalizedModel,
    );
    notifyListeners();
  }

  // --- Syncthing cross-device sync ---

  /// Persist and apply Syncthing connection + safety settings in one shot.
  Future<void> updateSyncthingSettings({
    required bool enabled,
    required String endpoint,
    required String apiKey,
    required bool autoShare,
    bool? autoAcceptRemote,
    bool? ignorePerms,
    bool? writeStignore,
    String? versioningPreset,
    String? defaultLandingPath,
  }) async {
    _syncthingEnabled = enabled;
    _syncthingAutoShare = autoShare;
    if (autoAcceptRemote != null) _syncthingAutoAcceptRemote = autoAcceptRemote;
    if (ignorePerms != null) _syncthingIgnorePerms = ignorePerms;
    if (writeStignore != null) _syncthingWriteStignore = writeStignore;
    if (versioningPreset != null) {
      _syncthingVersioningPreset = versioningPreset;
    }
    if (defaultLandingPath != null) {
      _syncthingDefaultLandingPath = defaultLandingPath;
    }

    syncthing.configure(baseUrl: endpoint, apiKey: apiKey);
    await prefs.setSyncthingEnabled(enabled);
    await prefs.setSyncthingEndpoint(endpoint);
    await prefs.setSyncthingApiKey(apiKey);
    await prefs.setSyncthingAutoShare(autoShare);
    if (autoAcceptRemote != null) {
      await prefs.setSyncthingAutoAcceptRemote(autoAcceptRemote);
    }
    if (ignorePerms != null) {
      await prefs.setSyncthingIgnorePerms(ignorePerms);
    }
    if (writeStignore != null) {
      await prefs.setSyncthingWriteStignore(writeStignore);
    }
    if (versioningPreset != null) {
      await prefs.setSyncthingVersioningPreset(versioningPreset);
    }
    if (defaultLandingPath != null) {
      await prefs.setSyncthingDefaultLandingPath(defaultLandingPath);
    }

    notifyListeners();

    if (enabled) {
      // Re-apply safety defaults whenever the user touches Settings,
      // not just at boot. Fire-and-forget — the UI doesn't block.
      unawaited(_syncthingApplySafetyDefaults());
    }

    // If the user just enabled Syncthing while a project is already open,
    // auto-share it now rather than waiting for the next setDirectory call.
    if (_currentDirectory != null) {
      _syncthingAutoShareIfNeeded(_currentDirectory!);
    }
  }

  /// Pushes Lumen's safety defaults into the local Syncthing instance:
  ///
  ///   1. `defaults.folder.path` ← user's [syncthingDefaultLandingPath]
  ///      (default `~/Lumen-Sync`). Fixes the "auto-accepted folder
  ///      lands inside Syncthing's data dir as a relative path" bug.
  ///   2. `defaults/ignores` ← Lumen's `.stignore` template (one-shot,
  ///      gated by [PreferencesService.getSyncthingDefaultIgnoresWritten]).
  ///   3. `autoAcceptFolders` ← respects [syncthingAutoAcceptRemote]
  ///      on every remote device. Default OFF — the pending-folders
  ///      panel is the safe accept path.
  ///
  /// All three steps swallow errors; if Syncthing is unreachable
  /// nothing happens and the UI doesn't surface a failure.
  Future<void> _syncthingApplySafetyDefaults() async {
    try {
      // 1. Default folder path.
      final landing = _syncthingDefaultLandingPath.trim();
      if (landing.isNotEmpty) {
        final current = await syncthing.getDefaultFolder();
        final currentPath = (current?['path'] as String? ?? '').trim();
        if (currentPath != landing) {
          final ok = await syncthing.patchDefaultFolder({'path': landing});
          debugPrint(
            ok
                ? '[Syncthing] defaults.folder.path → "$landing"'
                : '[Syncthing] failed to patch defaults.folder.path',
          );
        }
      }

      // 2. Default ignores — one-shot.
      final alreadyWritten = await prefs.getSyncthingDefaultIgnoresWritten();
      if (!alreadyWritten) {
        final ok = await syncthing.setDefaultIgnores(kLumenDefaultStignore);
        if (ok) {
          await prefs.setSyncthingDefaultIgnoresWritten(true);
          debugPrint('[Syncthing] Seeded defaults/ignores');
        }
      }

      // 3. Reconcile autoAcceptFolders on every remote device.
      await _syncthingReconcileAutoAccept();
    } catch (e) {
      debugPrint('[Syncthing] safety defaults error: $e');
    }
  }

  /// Fire-and-forget: if Syncthing is enabled + autoShare is on, ensure
  /// the workspace is a shared folder with ALL devices attached and
  /// configured according to the current safety defaults (ignorePerms,
  /// versioning preset, .stignore template).
  void _syncthingAutoShareIfNeeded(String path) {
    if (!_syncthingEnabled || !_syncthingAutoShare) return;
    () async {
      try {
        final id = SyncthingService.folderIdFromPath(path);
        final label = path
            .replaceAll('\\', '/')
            .split('/')
            .where((s) => s.isNotEmpty)
            .last;

        final versioning = SyncthingVersioningPresetX.fromKey(
          _syncthingVersioningPreset,
        ).toJson();

        final already = await syncthing.isFolderRegistered(path);
        if (already) {
          final folderId = await syncthing.folderIdForPath(path);
          if (folderId != null) {
            // Reattach all devices and re-stamp our safety defaults so
            // the user can flip preferences and have them propagate
            // without manually editing each folder.
            final devices = (await syncthing.listDevices())
                .map((d) => {'deviceID': d['deviceID'] as String? ?? ''})
                .where((d) => (d['deviceID'] ?? '').isNotEmpty)
                .toList();
            final patch = <String, dynamic>{
              'devices': devices,
              'ignorePerms': _syncthingIgnorePerms,
              // ignore: use_null_aware_elements
              if (versioning != null) 'versioning': versioning,
            };
            final ok = await syncthing.patchFolder(folderId, patch);
            debugPrint(
              ok
                  ? '[Syncthing] Re-applied defaults to "$label"'
                  : '[Syncthing] Failed to patch "$label"',
            );
            unawaited(_syncthingMaybeWriteStignore(folderId, path));
          }
        } else {
          final ok = await syncthing.addFolder(
            id: id,
            path: path,
            label: label,
            ignorePerms: _syncthingIgnorePerms,
            versioning: versioning,
          );
          debugPrint(
            ok
                ? '[Syncthing] Auto-shared folder "$label" (id=$id)'
                : '[Syncthing] Failed to auto-share "$label"',
          );
          if (ok) {
            unawaited(_syncthingMaybeWriteStignore(id, path));
          }
        }

        await _syncthingReconcileAutoAccept();
      } catch (e) {
        debugPrint('[Syncthing] Auto-share error: $e');
      }
    }();
  }

  /// Drops the Lumen `.stignore` template into [folderId] iff the user
  /// has opted into stignore seeding AND the folder doesn't already
  /// have an ignore file (to avoid stomping user customisations).
  Future<void> _syncthingMaybeWriteStignore(
    String folderId,
    String fsPath,
  ) async {
    if (!_syncthingWriteStignore) return;
    try {
      final existing = await syncthing.folderIgnores(folderId);
      if (existing == null) return;
      // Empty list means "no .stignore file" — fine to seed. A non-empty
      // list means the user already has patterns; leave them alone.
      if (existing.isNotEmpty) return;
      final ok = await syncthing.setFolderIgnores(
        folderId,
        kLumenDefaultStignore,
      );
      debugPrint(
        ok
            ? '[Syncthing] Seeded .stignore in "$folderId"'
            : '[Syncthing] Failed to seed .stignore in "$folderId"',
      );
    } catch (e) {
      debugPrint('[Syncthing] _syncthingMaybeWriteStignore error: $e');
    }
  }

  /// Sets `autoAcceptFolders` on every remote device to match
  /// [syncthingAutoAcceptRemote]. Skips devices already in the desired
  /// state. Default OFF — the pending-folders panel is the safe accept
  /// path; we used to default this ON which caused folders to land in
  /// Syncthing's data directory on the receiver.
  Future<void> _syncthingReconcileAutoAccept() async {
    try {
      final status = await syncthing.systemStatus();
      final localId = status?['myID'] as String?;
      final devices = await syncthing.listDevices();
      for (final d in devices) {
        final did = d['deviceID'] as String? ?? '';
        if (did.isEmpty || did == localId) continue;
        final current = d['autoAcceptFolders'] == true;
        if (current == _syncthingAutoAcceptRemote) continue;
        await syncthing.enableAutoAccept(
          did,
          enabled: _syncthingAutoAcceptRemote,
        );
        debugPrint(
          '[Syncthing] autoAcceptFolders=$_syncthingAutoAcceptRemote on $did',
        );
      }
    } catch (e) {
      debugPrint('[Syncthing] autoAccept reconcile error: $e');
    }
  }

  /// Detects pairs of devices that are mutually flagged as introducer
  /// (the "Remote is an introducer to us, and we are to them" warning).
  /// Returns a list of remote `deviceID`s that we are introducer to AND
  /// that are introducer to us — i.e., the ones the user should
  /// down-flag on this side to break the loop.
  ///
  /// This is heuristic: Syncthing only exposes our own device entries
  /// over REST, so we can read whether *we've* marked them as
  /// introducer. The "they marked us as introducer" half comes from
  /// the live warning log; for that we expose a one-shot fix that
  /// just clears the flag on our side (always safe).
  Future<List<String>> syncthingMutualIntroducerCandidates() async {
    final out = <String>[];
    try {
      final devices = await syncthing.listDevices();
      for (final d in devices) {
        if (d['introducer'] == true) {
          final did = d['deviceID'] as String? ?? '';
          if (did.isNotEmpty) out.add(did);
        }
      }
    } catch (e) {
      debugPrint('[Syncthing] mutualIntroducer error: $e');
    }
    return out;
  }

  /// One-shot fix: clears `introducer` on every remote device on our
  /// side. Safe under all circumstances — at worst, you lose the
  /// auto-propagation of new device IDs from those introducers, which
  /// you can re-enable per device later.
  Future<int> syncthingClearAllIntroducers() async {
    var fixed = 0;
    try {
      final devices = await syncthing.listDevices();
      for (final d in devices) {
        if (d['introducer'] != true) continue;
        final did = d['deviceID'] as String? ?? '';
        if (did.isEmpty) continue;
        if (await syncthing.setIntroducer(did, enabled: false)) {
          fixed++;
        }
      }
    } catch (e) {
      debugPrint('[Syncthing] clearAllIntroducers error: $e');
    }
    return fixed;
  }
}
