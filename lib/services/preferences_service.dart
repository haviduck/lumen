import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Single point of contact for `SharedPreferences`. Anything that wants to
/// persist a setting goes through here so keys stay in one place.
class PreferencesService {
  static const String _kProvider = 'llmProvider';
  static const String _kEndpoint = 'ollamaEndpoint';
  static const String _kApiKey = 'apiKey'; // legacy shared key
  // Ollama Cloud API key (https://ollama.com/settings/keys). When set,
  // chat requests for cloud-tagged models go directly to
  // https://ollama.com with `Authorization: Bearer <key>` instead of
  // proxying through the local daemon. Empty = legacy behaviour
  // (cloud models work IFF the user ran `ollama signin` and pulled
  // them locally).
  static const String _kOllamaApiKey = 'ollama.apiKey';
  static const String _kGeminiApiKey = 'gemini.apiKey';
  static const String _kAnthropicApiKey = 'anthropic.apiKey';
  static const String _kGithubModelsApiKey = 'githubModels.apiKey';
  static const String _kGithubModelsOrg = 'githubModels.organization';
  static const String _kGithubUnavailableModels =
      'githubModels.unavailableModels';
  static const String _kOpenaiApiKey = 'openai.apiKey';
  static const String _kEnabledProviders = 'llm.enabledProviders';
  static const String _kAutoApprove = 'agent.autoApproveCommands';
  static const String _kEditorTheme = 'editor.theme';
  static const String _kEditorFontSize = 'editor.fontSize';
  static const String _kEditorTabSize = 'editor.tabSize';
  static const String _kEditorWordWrap = 'editor.wordWrap';
  static const String _kViewMode = 'view.mode';
  static const String _kLockPinHash = 'lock.pinHash';
  static const String _kCurrentSessionId = 'chat.currentSessionId';
  // Selected chat model (prefixed: `ollama:foo` / `gemini:foo`).
  // Persisted so restarts don't silently flip routing to whatever
  // happens to be `_availableModels.first` after the next reload.
  static const String _kSelectedModel = 'chat.selectedModel';
  static const String _kEnabledChatModels = 'chat.enabledModels';
  static const String _kKnownChatModels = 'chat.knownModels';
  static const String _kToolCompressionEnabled = 'chat.toolCompression.enabled';
  static const String _kToolCompressionModel = 'chat.toolCompression.model';
  static const String _kToolCompressionThreshold =
      'chat.toolCompression.threshold';
  // History-summary keys. The summarizer reuses
  // `_kToolCompressionModel` so users only configure one "small model"
  // for both tool-output compression and chat-history summarization.
  // The two features are independently toggleable so a user can opt
  // into one without the other.
  //
  // `refreshDelta` is the cache-staleness threshold in messages: once
  // the dropped-history count exceeds the cached value by this much,
  // we re-summarize. Larger = cheaper (fewer LLM calls), smaller =
  // fresher summaries. Default 10 means a long agentic session
  // re-summarizes every ~10 elided messages, not every turn.
  //
  // `maxChars` caps the summary body. If the small model returns
  // something longer (verbose model, ignored the prompt), we fall
  // back to the existing one-line elision placeholder rather than
  // ship a 4 KB "summary" that's worse than the placeholder it
  // replaced.
  static const String _kHistorySummaryEnabled = 'chat.historySummary.enabled';
  static const String _kHistorySummaryMaxChars = 'chat.historySummary.maxChars';
  static const String _kHistorySummaryRefreshDelta =
      'chat.historySummary.refreshDelta';
  static const String _kTerminalShell = 'terminal.shell';
  static const String _kAutoBackupEnabled = 'autoBackup.enabled';
  static const String _kAutoBackupIntervalMinutes =
      'autoBackup.intervalMinutes';
  static const String _kAutoBackupGitAutoCommit = 'autoBackup.gitAutoCommit';
  static const String _kAutoBackupGitAutoPush = 'autoBackup.gitAutoPush';
  static const String _kReduceMotion = 'ui.reduceMotion';
  static const String _kReduceTransparency = 'ui.reduceTransparency';
  static const String _kRecentEditsHighlight = 'editor.recentEditsHighlight';
  static const String _kEditorThemeMigratedToNord =
      'editor.themeMigratedToNord';
  static const String _kEditorThemeMigratedToLumenMidnight =
      'editor.themeMigratedToLumenMidnight';
  static const String _kSyncthingEnabled = 'syncthing.enabled';
  static const String _kSyncthingEndpoint = 'syncthing.endpoint';
  static const String _kSyncthingApiKey = 'syncthing.apiKey';
  static const String _kSyncthingAutoShare = 'syncthing.autoShareProjects';
  // Per-receiver behaviour toggles. All default to safe values:
  //   autoAcceptRemote = false  — no silent folder creation on this PC
  //   ignorePerms      = true   — code projects on Windows hate +x diffs
  //   versioningPreset = staggered — recommended retention for code
  //   defaultLandingPath = ~/Lumen-Sync — base for any folders Syncthing
  //     does end up auto-creating; explicitly override the upstream `~`
  //     so files never land inside Syncthing's data directory.
  //   defaultIgnoresWritten = false — one-shot guard so we only seed the
  //     server-side default ignore patterns once per install.
  //   writeStignore = true — drop the Lumen .stignore on first share
  static const String _kSyncthingAutoAcceptRemote =
      'syncthing.autoAcceptRemote';
  static const String _kSyncthingIgnorePerms = 'syncthing.ignorePerms';
  static const String _kSyncthingVersioningPreset =
      'syncthing.versioningPreset';
  static const String _kSyncthingDefaultLandingPath =
      'syncthing.defaultLandingPath';
  static const String _kSyncthingDefaultIgnoresWritten =
      'syncthing.defaultIgnoresWritten';
  static const String _kSyncthingWriteStignore = 'syncthing.writeStignore';
  // Remote Access — opt-in HTTP server that lets paired devices talk to
  // this Lumen instance over LAN / Tailscale. Off by default on every
  // install; enabling brings up `LumenServer` (see
  // `lib/services/remote/lumen_server.dart`). v1 binds to 127.0.0.1 only
  // and exposes nothing sensitive; pairing/TLS/data API gated by future
  // pref keys (`remoteAccess.boundHost`, etc.) before the bind opens up.
  static const String _kRemoteAccessEnabled = 'remoteAccess.enabled';
  // Sticky port: persisted so a stable URL survives app restarts (much
  // nicer for manual `curl` testing). The server tries this port
  // first on boot and falls back to OS-chosen on bind failure (another
  // Lumen install holding it, port already taken, etc.). Stored as
  // int; absent / <=0 means "OS picks fresh."
  static const String _kRemoteAccessLastPort = 'remoteAccess.lastPort';
  // Sub-toggle for opening the bind to the local network (and any
  // overlay networks like Tailscale). Default false: a single click
  // on the master toggle leaves the server loopback-only. Two clicks
  // opt in to LAN exposure. Bearer auth is required on every non-
  // public route regardless of the bind, so flipping this on with
  // zero paired devices leaves an unreachable server (which is the
  // default-deny posture we want).
  static const String _kRemoteAccessBindAll = 'remoteAccess.bindAll';
  static const String _kOpenTabIds = 'chat.openTabIds';
  static const String _kChatHidden = 'ui.chatHidden';
  static const String _kAgentAllowOutsideWorkspaceWrites =
      'agent.allowOutsideWorkspaceWrites';
  // When true (default), `_runGenerationLoop` runs the workspace
  // analyzer (Dart / Flutter / Node / Python) once at the end of any
  // turn that touched source files but never called VERIFY itself.
  // Errors found are fed back as one extra tool-feedback round so the
  // model can fix them before the turn closes — see
  // `chat_controller.dart` § auto-verify and `tool_registry.dart`
  // § verify tool. The setting is workspace-agnostic; the verify
  // tool itself decides whether the workspace has a runnable
  // analyzer (no analyzer = no-op).
  static const String _kAgentAutoVerifyAfterEdits =
      'agent.autoVerifyAfterEdits';
  // List of tool ids the user has clicked "Always allow" on. Each
  // entry bypasses the approval card per-tool — distinct from the
  // global `agent.autoApproveCommands` flag, which is a master
  // override across every gated tool.
  static const String _kAutoApprovedTools = 'agent.autoApprovedTools';
  // Set of `WorkspaceSkill.id`s the user has explicitly enabled.
  // `null` (no value persisted) means "fall back to each skill's
  // `defaultEnabled` flag" — same shape as `_kEnabledChatModels`.
  // Empty list is meaningfully different from null: it means the
  // user has actively disabled every skill.
  static const String _kEnabledSkills = 'agent.enabledSkillIds';
  static const String _kKnownSkills = 'agent.knownSkillIds';
  // Master kill-switch for the GitNexus integration. When false:
  //   - GitNexusService skips its 10 s probe loop (no HTTP traffic
  //     to 127.0.0.1:4747).
  //   - Activity-bar icon is hidden.
  //   - Settings panel collapses to just the toggle + a one-paragraph
  //     explainer.
  //   - The new-project wizard skips the GitNexus onboarding step.
  // Default true so existing installs are unaffected; users who never
  // installed Node or never want the integration can turn it off and
  // forget about it.
  static const String _kGitNexusEnabled = 'gitnexus.enabled';
  static const String _kGitNexusAutoWiki = 'gitnexus.autoWiki';
  static const String _kGitNexusWikiModel = 'gitnexus.wikiModel';

  Future<SharedPreferences> get _p => SharedPreferences.getInstance();

  Future<String> getProvider() async =>
      (await _p).getString(_kProvider) ?? 'Ollama';
  Future<void> setProvider(String v) async =>
      (await _p).setString(_kProvider, v);

  Future<List<String>> getEnabledProviders() async =>
      (await _p).getStringList(_kEnabledProviders) ?? ['Ollama'];
  Future<void> setEnabledProviders(List<String> v) async =>
      (await _p).setStringList(_kEnabledProviders, v);

  Future<String> getEndpoint() async =>
      (await _p).getString(_kEndpoint) ?? 'http://localhost:11434';
  Future<void> setEndpoint(String v) async =>
      (await _p).setString(_kEndpoint, v);

  Future<String> getApiKey() async => (await _p).getString(_kApiKey) ?? '';
  Future<void> setApiKey(String v) async => (await _p).setString(_kApiKey, v);

  Future<String> getOllamaApiKey() async =>
      (await _p).getString(_kOllamaApiKey) ?? '';
  Future<void> setOllamaApiKey(String v) async =>
      (await _p).setString(_kOllamaApiKey, v.trim());

  Future<String> getGeminiApiKey() async =>
      (await _p).getString(_kGeminiApiKey) ?? '';
  Future<void> setGeminiApiKey(String v) async =>
      (await _p).setString(_kGeminiApiKey, v);

  Future<String> getAnthropicApiKey() async =>
      (await _p).getString(_kAnthropicApiKey) ?? '';
  Future<void> setAnthropicApiKey(String v) async =>
      (await _p).setString(_kAnthropicApiKey, v);

  Future<String> getGithubModelsApiKey() async =>
      (await _p).getString(_kGithubModelsApiKey) ?? '';
  Future<void> setGithubModelsApiKey(String v) async =>
      (await _p).setString(_kGithubModelsApiKey, v);

  Future<String> getGithubModelsOrganization() async =>
      (await _p).getString(_kGithubModelsOrg) ?? '';
  Future<void> setGithubModelsOrganization(String v) async =>
      (await _p).setString(_kGithubModelsOrg, v.trim());

  Future<List<String>> getGithubUnavailableModels() async =>
      (await _p).getStringList(_kGithubUnavailableModels) ?? const <String>[];
  Future<void> setGithubUnavailableModels(List<String> v) async =>
      (await _p).setStringList(_kGithubUnavailableModels, v);

  Future<String> getOpenaiApiKey() async =>
      (await _p).getString(_kOpenaiApiKey) ?? '';
  Future<void> setOpenaiApiKey(String v) async =>
      (await _p).setString(_kOpenaiApiKey, v);

  Future<bool> getAutoApprove() async =>
      (await _p).getBool(_kAutoApprove) ?? false;
  Future<void> setAutoApprove(bool v) async =>
      (await _p).setBool(_kAutoApprove, v);

  /// Per-tool blanket approvals. Order isn't significant; storing
  /// as a list because `SharedPreferences` doesn't have a Set type
  /// and tools are persisted by id (snake_case strings).
  Future<List<String>> getAutoApprovedTools() async =>
      (await _p).getStringList(_kAutoApprovedTools) ?? const <String>[];
  Future<void> setAutoApprovedTools(List<String> ids) async =>
      (await _p).setStringList(_kAutoApprovedTools, ids);

  Future<List<String>?> getEnabledChatModels() async =>
      (await _p).getStringList(_kEnabledChatModels);
  Future<void> setEnabledChatModels(List<String> ids) async =>
      (await _p).setStringList(_kEnabledChatModels, ids);
  Future<List<String>?> getKnownChatModels() async =>
      (await _p).getStringList(_kKnownChatModels);
  Future<void> setKnownChatModels(List<String> ids) async =>
      (await _p).setStringList(_kKnownChatModels, ids);

  Future<bool> getToolCompressionEnabled() async =>
      (await _p).getBool(_kToolCompressionEnabled) ?? false;
  Future<void> setToolCompressionEnabled(bool v) async =>
      (await _p).setBool(_kToolCompressionEnabled, v);

  Future<String> getToolCompressionModel() async =>
      (await _p).getString(_kToolCompressionModel) ?? '';
  Future<void> setToolCompressionModel(String v) async =>
      (await _p).setString(_kToolCompressionModel, v.trim());

  Future<int> getToolCompressionThreshold() async =>
      (await _p).getInt(_kToolCompressionThreshold) ?? 2000;
  Future<void> setToolCompressionThreshold(int v) async =>
      (await _p).setInt(_kToolCompressionThreshold, v);

  Future<bool> getHistorySummaryEnabled() async =>
      (await _p).getBool(_kHistorySummaryEnabled) ?? false;
  Future<void> setHistorySummaryEnabled(bool v) async =>
      (await _p).setBool(_kHistorySummaryEnabled, v);

  Future<int> getHistorySummaryMaxChars() async =>
      (await _p).getInt(_kHistorySummaryMaxChars) ?? 1200;
  Future<void> setHistorySummaryMaxChars(int v) async =>
      (await _p).setInt(_kHistorySummaryMaxChars, v);

  Future<int> getHistorySummaryRefreshDelta() async =>
      (await _p).getInt(_kHistorySummaryRefreshDelta) ?? 10;
  Future<void> setHistorySummaryRefreshDelta(int v) async =>
      (await _p).setInt(_kHistorySummaryRefreshDelta, v);

  /// Skill ids the user has explicitly toggled on. `null` means
  /// "no preference yet — fall back to each skill's defaultEnabled".
  /// Returns null specifically; callers should treat empty list as
  /// "user disabled every skill".
  Future<Set<String>?> getEnabledSkillIds() async {
    final raw = (await _p).getStringList(_kEnabledSkills);
    if (raw == null) return null;
    return raw.toSet();
  }

  Future<void> setEnabledSkillIds(Iterable<String> ids) async {
    await (await _p).setStringList(_kEnabledSkills, ids.toList()..sort());
  }

  Future<Set<String>?> getKnownSkillIds() async {
    final raw = (await _p).getStringList(_kKnownSkills);
    if (raw == null) return null;
    return raw.toSet();
  }

  Future<void> setKnownSkillIds(Iterable<String> ids) async {
    await (await _p).setStringList(_kKnownSkills, ids.toList()..sort());
  }

  /// When false (default), built-in file mutation tools reject absolute paths
  /// and `..` traversal that would write outside the active workspace. Reads
  /// are still allowed outside the workspace. Shell commands remain separately
  /// approval-gated and cannot be perfectly sandboxed from Dart.
  Future<bool> getAgentAllowOutsideWorkspaceWrites() async =>
      (await _p).getBool(_kAgentAllowOutsideWorkspaceWrites) ?? false;
  Future<void> setAgentAllowOutsideWorkspaceWrites(bool v) async =>
      (await _p).setBool(_kAgentAllowOutsideWorkspaceWrites, v);

  /// Default-on: end-of-turn verify runs after any edit-heavy turn
  /// where the model didn't call VERIFY itself. False positives are
  /// rare (a Flutter project always has `dart analyze`; a Node project
  /// always has `tsc --noEmit` if `tsconfig.json` exists; the verify
  /// tool gracefully no-ops in workspaces without an analyzer), so
  /// defaulting to on costs a few seconds for the common case in
  /// exchange for catching the type errors smaller local models
  /// routinely miss.
  Future<bool> getAgentAutoVerifyAfterEdits() async =>
      (await _p).getBool(_kAgentAutoVerifyAfterEdits) ?? true;
  Future<void> setAgentAutoVerifyAfterEdits(bool v) async =>
      (await _p).setBool(_kAgentAutoVerifyAfterEdits, v);

  Future<String> getEditorTheme() async {
    final p = await _p;
    // Two stacked one-shot migrations, idempotent and ordered:
    //
    //   1. one-dark-pro → nord    (gated by `editor.themeMigratedToNord`)
    //   2. nord → lumen-midnight  (gated by
    //      `editor.themeMigratedToLumenMidnight`)
    //
    // Each step only touches users still on the *previous default* —
    // anyone who actively chose a different theme after a migration
    // ran is honoured (the flag prevents us from bouncing them back
    // through the same migration). Migrations chain: a user installed
    // before any of this had `one-dark-pro` and ends up on
    // `lumen-midnight` after both flags get set on the same launch.
    final migrated1 = p.getBool(_kEditorThemeMigratedToNord) ?? false;
    if (!migrated1) {
      final stored = p.getString(_kEditorTheme);
      if (stored == null || stored == 'one-dark-pro') {
        await p.setString(_kEditorTheme, 'nord');
      }
      await p.setBool(_kEditorThemeMigratedToNord, true);
    }
    final migrated2 = p.getBool(_kEditorThemeMigratedToLumenMidnight) ?? false;
    if (!migrated2) {
      final stored = p.getString(_kEditorTheme);
      if (stored == null || stored == 'nord') {
        await p.setString(_kEditorTheme, 'lumen-midnight');
      }
      await p.setBool(_kEditorThemeMigratedToLumenMidnight, true);
    }
    return p.getString(_kEditorTheme) ?? 'lumen-midnight';
  }

  Future<void> setEditorTheme(String v) async =>
      (await _p).setString(_kEditorTheme, v);

  Future<double> getEditorFontSize() async =>
      (await _p).getDouble(_kEditorFontSize) ?? 13.5;
  Future<void> setEditorFontSize(double v) async =>
      (await _p).setDouble(_kEditorFontSize, v);

  Future<int> getEditorTabSize() async =>
      (await _p).getInt(_kEditorTabSize) ?? 2;
  Future<void> setEditorTabSize(int v) async =>
      (await _p).setInt(_kEditorTabSize, v);

  Future<bool> getWordWrap() async =>
      (await _p).getBool(_kEditorWordWrap) ?? false;
  Future<void> setWordWrap(bool v) async =>
      (await _p).setBool(_kEditorWordWrap, v);

  Future<String> getViewMode() async =>
      (await _p).getString(_kViewMode) ?? 'normal';
  Future<void> setViewMode(String v) async =>
      (await _p).setString(_kViewMode, v);

  // Whether the AI chat sidebar is collapsed (zero-width) in normal
  // view mode. Independent of `viewMode` because the user wants a
  // quick toggle without leaving normal layout (Zen mode hides the
  // explorer too, which is too aggressive for a focus moment).
  Future<bool> getChatHidden() async =>
      (await _p).getBool(_kChatHidden) ?? false;
  Future<void> setChatHidden(bool v) async =>
      (await _p).setBool(_kChatHidden, v);

  Future<String> getCurrentSessionId() async =>
      (await _p).getString(_kCurrentSessionId) ?? '';
  Future<void> setCurrentSessionId(String v) async =>
      (await _p).setString(_kCurrentSessionId, v);

  /// Restore the previously-selected chat model. Returns empty when
  /// never set — caller should fall through to its own default
  /// (typically `_availableModels.first`).
  Future<String> getSelectedModel() async =>
      (await _p).getString(_kSelectedModel) ?? '';
  Future<void> setSelectedModel(String v) async =>
      (await _p).setString(_kSelectedModel, v);

  /// IDs of the chat sessions the user currently has open as tabs.
  /// Persisted via `setStringList` so order is preserved (browser-tab-style:
  /// the leftmost tab is the first element). Stale IDs (sessions deleted
  /// outside this process) are filtered out by the caller, not here.
  ///
  /// **Legacy global key** — used for the pre-workspace-scoping era and as
  /// a fallback bucket when no workspace is open (Welcome screen, freshly
  /// closed workspace). New code should prefer
  /// `getOpenTabIdsForWorkspace` / `setOpenTabIdsForWorkspace`.
  Future<List<String>> getOpenTabIds() async =>
      (await _p).getStringList(_kOpenTabIds) ?? const <String>[];
  Future<void> setOpenTabIds(List<String> ids) async =>
      (await _p).setStringList(_kOpenTabIds, ids);

  // -------------------------------------------------------------
  //   Per-workspace chat tab persistence
  // -------------------------------------------------------------
  // Per the IDE convention every other editor follows (Cursor, VSCode,
  // JetBrains): chat tabs belong to a project, not to the app globally.
  // Open project A → see A's tabs. Switch to B → see B's tabs. Close
  // workspace → fall back to the legacy global key (so the Welcome
  // screen still has a coherent surface). The path is hashed (sha256
  // truncated to 16 hex chars) to keep keys short and avoid encoding
  // concerns with arbitrary path characters; lowercase-normalize first
  // so Windows path-casing variants like `C:\` vs `c:\` don't accidentally
  // create distinct buckets for the same physical folder.
  //
  // We don't migrate legacy keys forward — the user opens a project,
  // gets a clean slate (or sessions matching that workspace, which
  // ChatController.bindToWorkspace surfaces as tabs). Their old "global"
  // tabs are still reachable via the chat history menu and remain in
  // the session archive on disk; nothing is lost.
  String _wsKey(String? path) {
    if (path == null || path.isEmpty) return '_global';
    final norm = path.toLowerCase().replaceAll('\\', '/');
    final digest = sha256.convert(utf8.encode(norm)).toString();
    return digest.substring(0, 16);
  }

  Future<List<String>> getOpenTabIdsForWorkspace(String? path) async {
    final p = await _p;
    final stored = p.getStringList('$_kOpenTabIds.${_wsKey(path)}');
    if (stored != null) return stored;
    // **Legacy fallback** — only the `_global` bucket inherits from
    // the pre-scoping global key, so users upgrading from an older
    // build don't lose their tabs the next time they land on the
    // Welcome screen. Workspace-specific buckets always start empty
    // (the user just opened that project for the first time under
    // the new system → ChatController.bindToWorkspace seeds a fresh
    // session). The fallback only fires *once* per bucket: after
    // `setOpenTabIdsForWorkspace` writes the `_global` key, the
    // legacy key is never consulted again.
    if (path == null || path.isEmpty) {
      return p.getStringList(_kOpenTabIds) ?? const <String>[];
    }
    return const <String>[];
  }

  Future<void> setOpenTabIdsForWorkspace(String? path, List<String> ids) async {
    await (await _p).setStringList('$_kOpenTabIds.${_wsKey(path)}', ids);
  }

  Future<String> getCurrentSessionIdForWorkspace(String? path) async {
    final p = await _p;
    final stored = p.getString('$_kCurrentSessionId.${_wsKey(path)}');
    if (stored != null) return stored;
    // Legacy fallback for the `_global` bucket only — same rationale
    // as `getOpenTabIdsForWorkspace`. Returns empty string for
    // workspace-specific buckets so the caller's "no prior chat
    // here, seed a new one" path runs.
    if (path == null || path.isEmpty) {
      return p.getString(_kCurrentSessionId) ?? '';
    }
    return '';
  }

  Future<void> setCurrentSessionIdForWorkspace(String? path, String v) async {
    await (await _p).setString('$_kCurrentSessionId.${_wsKey(path)}', v);
  }

  Future<String?> getTerminalShellId() async =>
      (await _p).getString(_kTerminalShell);
  Future<void> setTerminalShellId(String? id) async {
    final p = await _p;
    if (id == null || id.isEmpty) {
      await p.remove(_kTerminalShell);
    } else {
      await p.setString(_kTerminalShell, id);
    }
  }

  // Automatic backup scheduler
  Future<bool> getAutoBackupEnabled() async =>
      (await _p).getBool(_kAutoBackupEnabled) ?? false;
  Future<void> setAutoBackupEnabled(bool v) async =>
      (await _p).setBool(_kAutoBackupEnabled, v);

  Future<int> getAutoBackupIntervalMinutes() async =>
      (await _p).getInt(_kAutoBackupIntervalMinutes) ?? 30;
  Future<void> setAutoBackupIntervalMinutes(int v) async =>
      (await _p).setInt(_kAutoBackupIntervalMinutes, v);

  Future<bool> getAutoBackupGitAutoCommit() async =>
      (await _p).getBool(_kAutoBackupGitAutoCommit) ?? false;
  Future<void> setAutoBackupGitAutoCommit(bool v) async =>
      (await _p).setBool(_kAutoBackupGitAutoCommit, v);

  Future<bool> getAutoBackupGitAutoPush() async =>
      (await _p).getBool(_kAutoBackupGitAutoPush) ?? false;
  Future<void> setAutoBackupGitAutoPush(bool v) async =>
      (await _p).setBool(_kAutoBackupGitAutoPush, v);

  // UI accessibility / performance escape hatches. Both default off so the
  // glass aesthetic is opt-out, not opt-in.
  Future<bool> getReduceMotion() async =>
      (await _p).getBool(_kReduceMotion) ?? false;
  Future<void> setReduceMotion(bool v) async =>
      (await _p).setBool(_kReduceMotion, v);

  Future<bool> getReduceTransparency() async =>
      (await _p).getBool(_kReduceTransparency) ?? false;
  Future<void> setReduceTransparency(bool v) async =>
      (await _p).setBool(_kReduceTransparency, v);

  // "Last turn" recent-edit highlights in the editor — a subtle line
  // background showing what the most recent agent turn changed. Default
  // ON: per the design discussion, it solves the vibecoding problem
  // because it auto-clears as soon as the user types or the next turn
  // runs. Toggle lives in the status bar.
  Future<bool> getRecentEditsHighlight() async =>
      (await _p).getBool(_kRecentEditsHighlight) ?? true;
  Future<void> setRecentEditsHighlight(bool v) async =>
      (await _p).setBool(_kRecentEditsHighlight, v);

  // PIN handling — never store the plaintext.
  String _hashPin(String pin) {
    final bytes = utf8.encode('duckoff:$pin');
    return sha256.convert(bytes).toString();
  }

  Future<bool> hasPin() async {
    final h = (await _p).getString(_kLockPinHash);
    return h != null && h.isNotEmpty;
  }

  Future<void> setPin(String pin) async {
    await (await _p).setString(_kLockPinHash, _hashPin(pin));
  }

  Future<void> clearPin() async {
    await (await _p).remove(_kLockPinHash);
  }

  Future<bool> verifyPin(String pin) async {
    final stored = (await _p).getString(_kLockPinHash);
    if (stored == null || stored.isEmpty) return false;
    return stored == _hashPin(pin);
  }

  // --- GitNexus ---
  Future<bool> getGitNexusEnabled() async =>
      (await _p).getBool(_kGitNexusEnabled) ?? true;
  Future<void> setGitNexusEnabled(bool v) async =>
      (await _p).setBool(_kGitNexusEnabled, v);

  Future<bool> getGitNexusAutoWiki() async =>
      (await _p).getBool(_kGitNexusAutoWiki) ?? false;
  Future<void> setGitNexusAutoWiki(bool v) async =>
      (await _p).setBool(_kGitNexusAutoWiki, v);

  Future<String> getGitNexusWikiModel() async =>
      (await _p).getString(_kGitNexusWikiModel) ?? '';
  Future<void> setGitNexusWikiModel(String v) async =>
      (await _p).setString(_kGitNexusWikiModel, v.trim());

  // --- Syncthing ---
  Future<bool> getSyncthingEnabled() async =>
      (await _p).getBool(_kSyncthingEnabled) ?? false;
  Future<void> setSyncthingEnabled(bool v) async =>
      (await _p).setBool(_kSyncthingEnabled, v);

  Future<String> getSyncthingEndpoint() async =>
      (await _p).getString(_kSyncthingEndpoint) ?? 'http://localhost:8384';
  Future<void> setSyncthingEndpoint(String v) async =>
      (await _p).setString(_kSyncthingEndpoint, v);

  Future<String> getSyncthingApiKey() async =>
      (await _p).getString(_kSyncthingApiKey) ?? '';
  Future<void> setSyncthingApiKey(String v) async =>
      (await _p).setString(_kSyncthingApiKey, v);

  Future<bool> getSyncthingAutoShare() async =>
      (await _p).getBool(_kSyncthingAutoShare) ?? true;
  Future<void> setSyncthingAutoShare(bool v) async =>
      (await _p).setBool(_kSyncthingAutoShare, v);

  /// Whether Lumen should flip `autoAcceptFolders=true` on every remote
  /// device. Off by default — explicit accept (via the pending-folders
  /// panel) is the safe path.
  Future<bool> getSyncthingAutoAcceptRemote() async =>
      (await _p).getBool(_kSyncthingAutoAcceptRemote) ?? false;
  Future<void> setSyncthingAutoAcceptRemote(bool v) async =>
      (await _p).setBool(_kSyncthingAutoAcceptRemote, v);

  Future<bool> getSyncthingIgnorePerms() async =>
      (await _p).getBool(_kSyncthingIgnorePerms) ?? true;
  Future<void> setSyncthingIgnorePerms(bool v) async =>
      (await _p).setBool(_kSyncthingIgnorePerms, v);

  /// One of: `none | trashcan | simple | staggered`. Default
  /// `staggered` (recommended for code projects).
  Future<String> getSyncthingVersioningPreset() async =>
      (await _p).getString(_kSyncthingVersioningPreset) ?? 'staggered';
  Future<void> setSyncthingVersioningPreset(String v) async =>
      (await _p).setString(_kSyncthingVersioningPreset, v);

  /// Base path for any folders Syncthing auto-accepts on this PC.
  /// Defaults to `~/Lumen-Sync`. Pushed to Syncthing's
  /// `defaults.folder.path` whenever the integration is enabled.
  Future<String> getSyncthingDefaultLandingPath() async =>
      (await _p).getString(_kSyncthingDefaultLandingPath) ?? '~/Lumen-Sync';
  Future<void> setSyncthingDefaultLandingPath(String v) async =>
      (await _p).setString(_kSyncthingDefaultLandingPath, v);

  /// One-shot guard so the server-side `defaults/ignores` only get seeded
  /// once. After the first push the user owns them in Syncthing's GUI.
  Future<bool> getSyncthingDefaultIgnoresWritten() async =>
      (await _p).getBool(_kSyncthingDefaultIgnoresWritten) ?? false;
  Future<void> setSyncthingDefaultIgnoresWritten(bool v) async =>
      (await _p).setBool(_kSyncthingDefaultIgnoresWritten, v);

  /// Whether to drop the Lumen `.stignore` template into newly-shared
  /// folders that don't already have one.
  Future<bool> getSyncthingWriteStignore() async =>
      (await _p).getBool(_kSyncthingWriteStignore) ?? true;
  Future<void> setSyncthingWriteStignore(bool v) async =>
      (await _p).setBool(_kSyncthingWriteStignore, v);

  // --- Remote Access (Lumen mobile companion) ---
  /// Master switch for the embedded HTTP server. Off by default —
  /// flipping this on starts a local server bound to 127.0.0.1; later
  /// passes will open the bind to the LAN once pairing/TLS land.
  Future<bool> getRemoteAccessEnabled() async =>
      (await _p).getBool(_kRemoteAccessEnabled) ?? false;
  Future<void> setRemoteAccessEnabled(bool v) async =>
      (await _p).setBool(_kRemoteAccessEnabled, v);

  /// Last successfully-bound port for the Remote Access server.
  /// Returns `null` when no port has been recorded yet (fresh install
  /// or never enabled), in which case the server lets the OS pick.
  Future<int?> getRemoteAccessLastPort() async {
    final v = (await _p).getInt(_kRemoteAccessLastPort);
    if (v == null || v <= 0 || v > 65535) return null;
    return v;
  }

  Future<void> setRemoteAccessLastPort(int port) async {
    if (port <= 0 || port > 65535) return;
    await (await _p).setInt(_kRemoteAccessLastPort, port);
  }

  /// Whether the server should bind to all interfaces (LAN + overlay
  /// networks like Tailscale) instead of loopback-only. Default false
  /// — explicit second toggle prevents a single click from opening a
  /// port to the network.
  Future<bool> getRemoteAccessBindAll() async =>
      (await _p).getBool(_kRemoteAccessBindAll) ?? false;
  Future<void> setRemoteAccessBindAll(bool v) async =>
      (await _p).setBool(_kRemoteAccessBindAll, v);
}
