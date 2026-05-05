import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/gitnexus_service.dart';
import '../services/github_models_service.dart';
import '../services/syncthing_service.dart';
import '../services/tool_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'agent_skills/agent_skills_list.dart';
import 'common/duck_toast.dart';
import 'editor/editor_themes.dart';
import 'gitnexus/daemon_row.dart';
import 'gitnexus/wiki_row.dart';
import 'manual_skill_dialog.dart';
import 'ai_chat/model_management_panel.dart';
import 'remote_access/remote_access_panel.dart';
import 'syncthing/syncthing_panels.dart';

/// Full settings view that renders inside the editor tab area, replacing
/// the old floating `SettingsDialog`. Mirrors the VS Code/Cursor settings
/// layout: sidebar on the left, content panel on the right.
class SettingsView extends StatefulWidget {
  const SettingsView({super.key});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

enum _SettingsCategory {
  general,
  editor,
  theme,
  terminal,
  aiChat,
  modelManagement,
  rules,
  gitnexus,
  syncthing,
  remoteAccess,
  tools,
  keys,
}

class _SettingsViewState extends State<SettingsView> {
  _SettingsCategory _active = _SettingsCategory.general;

  // Cached mutable copies — written back on save.
  late Set<String> _enabledProviders;
  late TextEditingController _ollamaEndpointCtrl;
  late TextEditingController _ollamaApiKeyCtrl;
  late TextEditingController _geminiKeyCtrl;
  late TextEditingController _claudeKeyCtrl;
  late TextEditingController _githubKeyCtrl;
  late TextEditingController _githubOrgCtrl;
  bool _githubTesting = false;
  String? _githubTestMessage;
  bool? _githubTestOk;
  late TextEditingController _openaiKeyCtrl;

  // API key visibility toggles
  bool _showOllamaKey = false;
  bool _showGeminiKey = false;
  bool _showClaudeKey = false;
  bool _showGithubKey = false;
  bool _showOpenaiKey = false;
  bool _showStApiKey = false;

  late String _editorTheme;
  late double _fontSize;
  late int _tabSize;
  late bool _wordWrap;
  late bool _autoApprove;
  late bool _reduceMotion;
  late bool _reduceTransparency;
  late bool _allowAgentOutsideWorkspaceWrites;
  late bool _autoVerifyAfterEdits;
  late bool _toolCompressionEnabled;
  late String _toolCompressionModel;
  late TextEditingController _toolCompressionThresholdCtrl;
  late bool _historySummaryEnabled;
  late TextEditingController _historySummaryMaxCharsCtrl;
  late TextEditingController _historySummaryRefreshDeltaCtrl;
  late bool _gitnexusAutoWiki;
  late TextEditingController _gitnexusWikiModelCtrl;
  late TextEditingController _globalRulesCtrl;
  late TextEditingController _workspaceRulesCtrl;
  bool _rulesLoaded = false;
  int _seenSettingsOpenRevision = -1;

  // Syncthing
  late bool _stEnabled;
  late TextEditingController _stEndpointCtrl;
  late TextEditingController _stApiKeyCtrl;
  late bool _stAutoShare;
  late bool _stAutoAcceptRemote;
  late bool _stIgnorePerms;
  late bool _stWriteStignore;
  late String _stVersioningPreset;
  late TextEditingController _stLandingPathCtrl;
  bool? _stReachable;
  bool? _stAuthOk;
  String? _stDeviceId;
  String? _stVersion;
  List<Map<String, dynamic>> _stFolders = [];
  List<Map<String, dynamic>> _stDevices = [];
  bool _stTesting = false;
  // Pending folders / devices fetched on Test Connection so the user
  // can accept them with explicit destination paths instead of relying
  // on `autoAcceptFolders` (which silently dropped folders into
  // Syncthing's data dir before this rewrite).
  Map<String, dynamic> _stPendingFolders = {};
  Map<String, dynamic> _stPendingDevices = {};
  // Local-side introducer flags. Non-empty means we have at least one
  // remote device marked as introducer — relevant if both sides did
  // the same, which produces the "Remote is an introducer to us, and
  // we are to them" log spam.
  List<String> _stOurIntroducers = [];

  static _SettingsCategory _categoryFromKey(String key) {
    return switch (key) {
      'editor' => _SettingsCategory.editor,
      'theme' => _SettingsCategory.theme,
      'terminal' => _SettingsCategory.terminal,
      'aiChat' => _SettingsCategory.aiChat,
      'models' => _SettingsCategory.modelManagement,
      'rules' => _SettingsCategory.rules,
      'gitnexus' => _SettingsCategory.gitnexus,
      'syncthing' => _SettingsCategory.syncthing,
      'remoteAccess' => _SettingsCategory.remoteAccess,
      'tools' => _SettingsCategory.tools,
      'keys' => _SettingsCategory.keys,
      _ => _SettingsCategory.general,
    };
  }

  Future<void> _loadRules() async {
    final a = context.read<AppState>();
    final global = await a.rules.readGlobal();
    final workspace = a.currentDirectory == null
        ? ''
        : await a.rules.readWorkspace(a.currentDirectory!);
    if (!mounted) return;
    setState(() {
      _globalRulesCtrl.text = global;
      _workspaceRulesCtrl.text = workspace;
      _rulesLoaded = true;
    });
  }

  @override
  void initState() {
    super.initState();
    final a = context.read<AppState>();
    _enabledProviders = Set<String>.from(a.enabledProviders);
    _ollamaEndpointCtrl = TextEditingController(text: a.ollamaEndpoint);
    _ollamaApiKeyCtrl = TextEditingController(text: a.ollamaApiKey);
    _geminiKeyCtrl = TextEditingController(text: a.geminiApiKey);
    _claudeKeyCtrl = TextEditingController(text: a.anthropicApiKey);
    _githubKeyCtrl = TextEditingController(text: a.githubModelsApiKey);
    _githubOrgCtrl = TextEditingController(text: a.githubModelsOrganization);
    _openaiKeyCtrl = TextEditingController(text: a.openaiApiKey);
    _editorTheme = a.editorTheme;
    _fontSize = a.editorFontSize;
    _tabSize = a.editorTabSize;
    _wordWrap = a.wordWrap;
    _autoApprove = a.chat.autoApprove;
    _reduceMotion = a.reduceMotion;
    _reduceTransparency = a.reduceTransparency;
    _allowAgentOutsideWorkspaceWrites = a.allowAgentOutsideWorkspaceWrites;
    _autoVerifyAfterEdits = a.autoVerifyAfterEdits;
    _toolCompressionEnabled = a.toolCompressionEnabled;
    _toolCompressionModel = a.toolCompressionModel;
    _toolCompressionThresholdCtrl = TextEditingController(
      text: a.toolCompressionThreshold.toString(),
    );
    _historySummaryEnabled = a.historySummaryEnabled;
    _historySummaryMaxCharsCtrl = TextEditingController(
      text: a.historySummaryMaxChars.toString(),
    );
    _historySummaryRefreshDeltaCtrl = TextEditingController(
      text: a.historySummaryRefreshDelta.toString(),
    );
    _gitnexusAutoWiki = a.gitnexusAutoWiki;
    _gitnexusWikiModelCtrl = TextEditingController(text: a.gitnexusWikiModel);
    _globalRulesCtrl = TextEditingController();
    _workspaceRulesCtrl = TextEditingController();
    _active = _categoryFromKey(a.settingsInitialCategory);
    _seenSettingsOpenRevision = a.settingsOpenRevision;
    // Syncthing
    _stEnabled = a.syncthingEnabled;
    _stEndpointCtrl = TextEditingController(text: a.syncthing.baseUrl);
    _stApiKeyCtrl = TextEditingController(text: a.syncthing.apiKey);
    _stAutoShare = a.syncthingAutoShare;
    _stAutoAcceptRemote = a.syncthingAutoAcceptRemote;
    _stIgnorePerms = a.syncthingIgnorePerms;
    _stWriteStignore = a.syncthingWriteStignore;
    _stVersioningPreset = a.syncthingVersioningPreset;
    _stLandingPathCtrl = TextEditingController(
      text: a.syncthingDefaultLandingPath,
    );
    _loadRules();
  }

  @override
  void dispose() {
    _ollamaEndpointCtrl.dispose();
    _ollamaApiKeyCtrl.dispose();
    _geminiKeyCtrl.dispose();
    _claudeKeyCtrl.dispose();
    _githubKeyCtrl.dispose();
    _githubOrgCtrl.dispose();
    _openaiKeyCtrl.dispose();
    _toolCompressionThresholdCtrl.dispose();
    _historySummaryMaxCharsCtrl.dispose();
    _historySummaryRefreshDeltaCtrl.dispose();
    _gitnexusWikiModelCtrl.dispose();
    _globalRulesCtrl.dispose();
    _workspaceRulesCtrl.dispose();
    _stEndpointCtrl.dispose();
    _stApiKeyCtrl.dispose();
    _stLandingPathCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final a = context.read<AppState>();
    await a.updateProviderSettings(
      enabledProviders: _enabledProviders,
      ollamaEndpoint: _ollamaEndpointCtrl.text,
      ollamaApiKey: _ollamaApiKeyCtrl.text,
      geminiApiKey: _geminiKeyCtrl.text,
      anthropicApiKey: _claudeKeyCtrl.text,
      githubModelsApiKey: _githubKeyCtrl.text,
      githubModelsOrganization: _githubOrgCtrl.text,
      openaiApiKey: _openaiKeyCtrl.text,
    );
    await a.updateEditorSettings(
      theme: _editorTheme,
      fontSize: _fontSize,
      tabSize: _tabSize,
      wordWrap: _wordWrap,
    );
    await a.chat.setAutoApprove(_autoApprove);
    await a.setReduceMotion(_reduceMotion);
    await a.setReduceTransparency(_reduceTransparency);
    await a.setAllowAgentOutsideWorkspaceWrites(
      _allowAgentOutsideWorkspaceWrites,
    );
    await a.setAutoVerifyAfterEdits(_autoVerifyAfterEdits);
    final parsedCompressionThreshold = int.tryParse(
      _toolCompressionThresholdCtrl.text.trim(),
    );
    await a.updateToolCompressionSettings(
      enabled: _toolCompressionEnabled,
      model: _toolCompressionModel,
      threshold:
          parsedCompressionThreshold == null || parsedCompressionThreshold <= 0
          ? 2000
          : parsedCompressionThreshold,
    );
    final parsedHistoryMaxChars = int.tryParse(
      _historySummaryMaxCharsCtrl.text.trim(),
    );
    final parsedHistoryRefreshDelta = int.tryParse(
      _historySummaryRefreshDeltaCtrl.text.trim(),
    );
    await a.updateHistorySummarySettings(
      enabled: _historySummaryEnabled,
      maxChars:
          parsedHistoryMaxChars == null || parsedHistoryMaxChars <= 0
          ? 1200
          : parsedHistoryMaxChars,
      refreshDelta:
          parsedHistoryRefreshDelta == null || parsedHistoryRefreshDelta <= 0
          ? 10
          : parsedHistoryRefreshDelta,
    );
    await a.updateGitNexusWikiSettings(
      autoWiki: _gitnexusAutoWiki,
      wikiModel: _gitnexusWikiModelCtrl.text,
    );
    if (_rulesLoaded) {
      await a.rules.writeGlobal(_globalRulesCtrl.text);
    }
    if (_rulesLoaded && a.currentDirectory != null) {
      await a.rules.writeWorkspace(
        a.currentDirectory!,
        _workspaceRulesCtrl.text,
      );
    }
    await a.updateSyncthingSettings(
      enabled: _stEnabled,
      endpoint: _stEndpointCtrl.text,
      apiKey: _stApiKeyCtrl.text,
      autoShare: _stAutoShare,
      autoAcceptRemote: _stAutoAcceptRemote,
      ignorePerms: _stIgnorePerms,
      writeStignore: _stWriteStignore,
      versioningPreset: _stVersioningPreset,
      defaultLandingPath: _stLandingPathCtrl.text.trim(),
    );
    if (!mounted) return;
    showDuckToast(context, S.settingsSaved);
  }

  Future<void> _openGithubTokenPage() async {
    const url =
        'https://github.com/settings/personal-access-tokens/new?description=Lumen%20-%20GitHub%20Models';
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [url]);
      } else {
        await Process.start('xdg-open', [url]);
      }
    } catch (_) {}
  }

  Future<void> _testGithubConnection() async {
    final token = _githubKeyCtrl.text.trim();
    setState(() {
      _githubTesting = true;
      _githubTestMessage = null;
      _githubTestOk = null;
    });
    final svc = GitHubModelsService(
      apiKey: token,
      organization: _githubOrgCtrl.text.trim(),
    );
    final result = await svc.testConnection();
    if (!mounted) return;
    setState(() {
      _githubTesting = false;
      _githubTestOk = result.ok;
      _githubTestMessage = result.message;
    });
  }

  @override
  Widget build(BuildContext context) {
    final requestedRevision = context.select<AppState, int>(
      (s) => s.settingsOpenRevision,
    );
    if (requestedRevision != _seenSettingsOpenRevision) {
      final state = context.read<AppState>();
      _seenSettingsOpenRevision = requestedRevision;
      _active = _categoryFromKey(state.settingsInitialCategory);
    }
    return Container(
      color: DuckColors.bgDeeper,
      child: Row(
        children: [
          // ── Sidebar ──────────────────────────────────────────
          Container(
            width: 180,
            color: DuckColors.bgRaised,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    S.settingsTitle.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.0,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.fgSubtle,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _sidebarItem(S.settingsCatGeneral, _SettingsCategory.general),
                _sidebarItem(S.settingsCatEditor, _SettingsCategory.editor),
                _sidebarItem(S.settingsCatTheme, _SettingsCategory.theme),
                _sidebarItem(S.settingsCatTerminal, _SettingsCategory.terminal),
                _sidebarItem(S.settingsCatAI, _SettingsCategory.aiChat),
                _sidebarItem(
                  S.settingsCatModelManagement,
                  _SettingsCategory.modelManagement,
                ),
                _sidebarItem(S.settingsCatRules, _SettingsCategory.rules),
                _sidebarItem(S.settingsCatGitNexus, _SettingsCategory.gitnexus),
                _sidebarItem(
                  S.settingsCatSyncthing,
                  _SettingsCategory.syncthing,
                ),
                _sidebarItem(
                  S.settingsCatRemoteAccess,
                  _SettingsCategory.remoteAccess,
                ),
                _sidebarItem(S.settingsCatTools, _SettingsCategory.tools),
                _sidebarItem(S.settingsCatKeys, _SettingsCategory.keys),
                const Spacer(),
              ],
            ),
          ),
          // Divider
          Container(width: 1, color: DuckColors.glassSeam),
          // ── Content panel ────────────────────────────────────
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 20, 32, 0),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _saveButton(),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(32, 16, 32, 0),
                  child: Divider(height: 1, color: DuckColors.glassSeam),
                ),
                Expanded(
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 24,
                      ),
                      child: _buildContent(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _saveButton() {
    return ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: DuckColors.accentCyan,
        foregroundColor: DuckColors.bgDeepest,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
      ),
      onPressed: _save,
      child: const Text(
        S.save,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _sidebarItem(String label, _SettingsCategory cat) {
    final isActive = _active == cat;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        onTap: () => setState(() => _active = cat),
        hoverColor: DuckColors.bgRaisedHi.withValues(alpha: 0.4),
        splashColor: Colors.transparent,
        highlightColor: Colors.transparent,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: isActive ? DuckColors.accentCyan : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: isActive ? DuckColors.fgPrimary : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    switch (_active) {
      case _SettingsCategory.general:
        return _buildGeneral();
      case _SettingsCategory.editor:
        return _buildEditor();
      case _SettingsCategory.theme:
        return _buildTheme();
      case _SettingsCategory.terminal:
        return _buildTerminal();
      case _SettingsCategory.aiChat:
        return _buildAiChat();
      case _SettingsCategory.modelManagement:
        return _buildModelManagement();
      case _SettingsCategory.rules:
        return _buildRules();
      case _SettingsCategory.gitnexus:
        return _buildGitNexus();
      case _SettingsCategory.syncthing:
        return _buildSyncthing();
      case _SettingsCategory.remoteAccess:
        return const RemoteAccessPanel();
      case _SettingsCategory.tools:
        return _buildTools();
      case _SettingsCategory.keys:
        return _buildKeys();
    }
  }

  // ── General ──────────────────────────────────────────────────

  Widget _buildGeneral() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatGeneral),
        const SizedBox(height: 16),
        _settingRow(
          label: S.settingsLlmProvider,
          description: S.settingsLlmProviderDesc,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final p in const [
                S.providerOllama,
                S.providerGemini,
                S.providerClaude,
                S.providerGithub,
                S.providerOpenAI,
              ])
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: Checkbox(
                          value: _enabledProviders.contains(p),
                          onChanged: (v) {
                            setState(() {
                              if (v == true) {
                                _enabledProviders.add(p);
                              } else if (_enabledProviders.length > 1) {
                                _enabledProviders.remove(p);
                              }
                            });
                          },
                          activeColor: DuckColors.accentCyan,
                          side: const BorderSide(color: DuckColors.fgMuted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        p,
                        style: const TextStyle(
                          fontSize: 13,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsOllamaSection),
        _settingRow(
          label: S.settingsEndpointUrl,
          description: S.settingsOllamaEndpointDesc,
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: _ollamaEndpointCtrl,
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ),
        _settingRow(
          label: S.settingsOllamaCloudKeyLabel,
          description: S.settingsOllamaCloudKeyDesc,
          child: _apiKeyField(
            controller: _ollamaApiKeyCtrl,
            visible: _showOllamaKey,
            onToggle: (v) => _showOllamaKey = v,
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsGeminiSection),
        _settingRow(
          label: S.settingsApiKey,
          description: S.settingsGeminiApiKeyDesc,
          child: _apiKeyField(
            controller: _geminiKeyCtrl,
            visible: _showGeminiKey,
            onToggle: (v) => _showGeminiKey = v,
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsClaudeSection),
        _settingRow(
          label: S.settingsApiKey,
          description: S.settingsClaudeApiKeyDesc,
          child: _apiKeyField(
            controller: _claudeKeyCtrl,
            visible: _showClaudeKey,
            onToggle: (v) => _showClaudeKey = v,
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsGithubSection),
        _settingRow(
          label: S.settingsApiKey,
          description: S.settingsGithubApiKeyDesc,
          child: SizedBox(
            width: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _githubKeyCtrl,
                  obscureText: !_showGithubKey,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _showGithubKey
                            ? Icons.visibility_off
                            : Icons.visibility,
                        size: 18,
                        color: DuckColors.fgMuted,
                      ),
                      onPressed: () =>
                          setState(() => _showGithubKey = !_showGithubKey),
                      tooltip: _showGithubKey ? 'Hide' : 'Show',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        side: const BorderSide(
                          color: DuckColors.glassSeam,
                          width: 0.5,
                        ),
                      ),
                      icon: const Icon(Icons.open_in_new, size: 14),
                      label: const Text(
                        S.settingsGithubOpenTokens,
                        style: TextStyle(fontSize: 11.5),
                      ),
                      onPressed: _openGithubTokenPage,
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        side: const BorderSide(
                          color: DuckColors.glassSeam,
                          width: 0.5,
                        ),
                      ),
                      icon: _githubTesting
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline, size: 14),
                      label: Text(
                        _githubTesting
                            ? S.settingsGithubTestingBtn
                            : S.settingsGithubTestBtn,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onPressed: _githubTesting ? null : _testGithubConnection,
                    ),
                  ],
                ),
                if (_githubTestMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _githubTestMessage!,
                    style: TextStyle(
                      fontSize: 11,
                      color: _githubTestOk == true
                          ? DuckColors.stateOk
                          : DuckColors.stateError,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        _settingRow(
          label: S.settingsGithubOrgLabel,
          description: S.settingsGithubOrgDesc,
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: _githubOrgCtrl,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                hintText: S.settingsGithubOrgHint,
                hintStyle: TextStyle(fontSize: 12),
              ),
            ),
          ),
        ),
        _settingRow(
          label: S.settingsGithubResetHiddenLabel,
          description: S.settingsGithubResetHiddenDesc,
          child: SizedBox(
            width: 320,
            child: Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  side: const BorderSide(
                    color: DuckColors.glassSeam,
                    width: 0.5,
                  ),
                ),
                icon: const Icon(Icons.refresh, size: 14),
                label: const Text(
                  S.settingsGithubResetHiddenBtn,
                  style: TextStyle(fontSize: 11.5),
                ),
                onPressed: () async {
                  final a = context.read<AppState>();
                  await a.resetGithubUnavailableModels();
                  if (!mounted) return;
                  showDuckToast(context, S.settingsGithubResetHiddenDone);
                },
              ),
            ),
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsOpenAISection),
        _settingRow(
          label: S.settingsApiKey,
          description: S.settingsOpenAIApiKeyDesc,
          child: _apiKeyField(
            controller: _openaiKeyCtrl,
            visible: _showOpenaiKey,
            onToggle: (v) => _showOpenaiKey = v,
          ),
        ),
        _divider(),
        _settingRow(
          label: S.settingsAutoSave,
          description: S.settingsAutoSaveDesc,
          child: _placeholder(),
        ),
        _settingRow(
          label: S.settingsConfirmClose,
          description: S.settingsConfirmCloseDesc,
          child: _placeholder(),
        ),
      ],
    );
  }

  // ── Editor ──────────────────────────────────────────────────

  Widget _buildEditor() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatEditor),
        const SizedBox(height: 16),
        _settingRow(
          label: S.settingsFontSize,
          description: S.settingsFontSizeDesc,
          child: SizedBox(
            width: 260,
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    min: 10,
                    max: 24,
                    divisions: 28,
                    value: _fontSize,
                    label: _fontSize.toStringAsFixed(1),
                    onChanged: (v) => setState(() => _fontSize = v),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _fontSize.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                    fontFamily: DuckTheme.monoFont,
                  ),
                ),
              ],
            ),
          ),
        ),
        _settingRow(
          label: S.settingsTabSize,
          description: S.settingsTabSizeDesc,
          child: SizedBox(
            width: 100,
            child: DropdownButtonFormField<int>(
              initialValue: _tabSize,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: const [2, 4, 8]
                  .map((n) => DropdownMenuItem(value: n, child: Text('$n')))
                  .toList(),
              onChanged: (v) => setState(() => _tabSize = v ?? _tabSize),
            ),
          ),
        ),
        _settingToggle(
          label: S.settingsWordWrap,
          description: S.settingsWordWrapDesc,
          value: _wordWrap,
          onChanged: (v) => setState(() => _wordWrap = v),
        ),
        _settingToggle(
          label: S.settingsShowLineNumbers,
          description: S.settingsShowLineNumbersDesc,
          value: true,
          onChanged: (_) {},
        ),
        _settingToggle(
          label: S.settingsMinimap,
          description: S.settingsMinimapDesc,
          value: false,
          onChanged: (_) {},
        ),
      ],
    );
  }

  // ── Theme ──────────────────────────────────────────────────

  Widget _buildTheme() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatTheme),
        const SizedBox(height: 16),
        _settingRow(
          label: S.settingsTheme,
          description: 'Color theme for the code editor.',
          child: SizedBox(
            width: 220,
            child: DropdownButtonFormField<String>(
              initialValue: _editorTheme,
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: EditorThemes.names
                  .map(
                    (id) => DropdownMenuItem(
                      value: id,
                      child: Text(
                        EditorThemes.prettyName(id),
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) =>
                  setState(() => _editorTheme = v ?? _editorTheme),
            ),
          ),
        ),
        _divider(),
        _sectionLabel(S.settingsAppearanceSection),
        _settingToggle(
          label: S.settingsReduceTransparency,
          description: S.settingsReduceTransparencyDesc,
          value: _reduceTransparency,
          onChanged: (v) => setState(() => _reduceTransparency = v),
        ),
        _settingToggle(
          label: S.settingsReduceMotion,
          description: S.settingsReduceMotionDesc,
          value: _reduceMotion,
          onChanged: (v) => setState(() => _reduceMotion = v),
        ),
        _settingRow(
          label: S.settingsUiMode,
          description: S.settingsUiModeDesc,
          child: SizedBox(
            width: 140,
            child: DropdownButtonFormField<String>(
              initialValue: 'Dark',
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
              items: const ['Dark']
                  .map(
                    (m) => DropdownMenuItem(
                      value: m,
                      child: Text(m, style: const TextStyle(fontSize: 13)),
                    ),
                  )
                  .toList(),
              onChanged: (_) {},
            ),
          ),
        ),
      ],
    );
  }

  // ── Terminal ──────────────────────────────────────────────────

  Widget _buildTerminal() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatTerminal),
        const SizedBox(height: 16),
        _settingRow(
          label: S.settingsTermFontSize,
          description: S.settingsTermFontSizeDesc,
          child: _placeholder(),
        ),
        _settingRow(
          label: S.settingsTermShell,
          description: S.settingsTermShellDesc,
          child: _placeholder(),
        ),
        _settingRow(
          label: S.settingsTermScrollback,
          description: S.settingsTermScrollbackDesc,
          child: _placeholder(),
        ),
      ],
    );
  }

  // ── AI / Chat ──────────────────────────────────────────────────

  Widget _buildAiChat() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatAI),
        const SizedBox(height: 16),
        _settingToggle(
          label: S.settingsAutoApprove,
          description: S.settingsAutoApproveDesc,
          value: _autoApprove,
          onChanged: (v) => setState(() => _autoApprove = v),
        ),
        // Per-tool blanket approvals — populated by clicking
        // "Always run" / "Always allow" on the in-chat approval
        // card. Listens to ChatController via Consumer because we
        // mutate the set directly through the controller (no local
        // _state mirror), so this section needs to rebuild
        // immediately on revoke.
        Consumer<AppState>(
          builder: (context, state, _) {
            final approved = state.chat.autoApprovedTools.toList()..sort();
            return _settingRow(
              label: S.settingsAutoApprovedToolsLabel,
              description: S.settingsAutoApprovedToolsDesc,
              child: SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (approved.isEmpty)
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: DuckColors.bgChip,
                          border: Border.all(
                            color: DuckColors.glassSeam,
                            width: 0.5,
                          ),
                          borderRadius: BorderRadius.circular(
                            DuckTheme.radiusS,
                          ),
                        ),
                        child: const Text(
                          S.settingsAutoApprovedNone,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: DuckColors.fgSubtle,
                          ),
                        ),
                      )
                    else ...[
                      Wrap(
                        alignment: WrapAlignment.end,
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final id in approved)
                            _ApprovedToolChip(
                              toolId: id,
                              onRevoke: () =>
                                  state.chat.setToolAutoApproved(id, false),
                            ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextButton.icon(
                        icon: const Icon(Icons.close, size: 14),
                        label: const Text(S.settingsAutoApprovedClearAll),
                        onPressed: () => state.chat.clearAutoApprovedTools(),
                        style: TextButton.styleFrom(
                          foregroundColor: DuckColors.fgMuted,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
        _settingToggle(
          label: S.settingsToolCompressionToggle,
          description: S.settingsToolCompressionDesc,
          value: _toolCompressionEnabled,
          onChanged: (v) => setState(() => _toolCompressionEnabled = v),
        ),
        Consumer<AppState>(
          builder: (context, state, _) {
            final models = state.chat.availableModels.toSet().toList()..sort();
            final modelOptions = <String>['', ...models];
            if (_toolCompressionModel.isNotEmpty &&
                !modelOptions.contains(_toolCompressionModel)) {
              modelOptions.add(_toolCompressionModel);
            }
            final selectedModel = modelOptions.contains(_toolCompressionModel)
                ? _toolCompressionModel
                : '';
            return _settingRow(
              label: S.settingsToolCompressionModel,
              description: S.settingsToolCompressionModelDesc,
              child: SizedBox(
                width: 320,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    DropdownButtonFormField<String>(
                      initialValue: selectedModel,
                      decoration: const InputDecoration(
                        contentPadding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                      ),
                      items: [
                        for (final model in modelOptions)
                          DropdownMenuItem(
                            value: model,
                            child: Text(
                              model.isEmpty
                                  ? S.settingsToolCompressionNoModel
                                  : model,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                      ],
                      onChanged: (v) =>
                          setState(() => _toolCompressionModel = v ?? ''),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _toolCompressionThresholdCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: S.settingsToolCompressionThreshold,
                        helperText: S.settingsToolCompressionThresholdDesc,
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        _settingToggle(
          label: S.settingsHistorySummaryToggle,
          description: S.settingsHistorySummaryDesc,
          value: _historySummaryEnabled,
          onChanged: (v) => setState(() => _historySummaryEnabled = v),
        ),
        _settingRow(
          label: S.settingsHistorySummaryMaxChars,
          description: S.settingsHistorySummaryMaxCharsDesc,
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: _historySummaryMaxCharsCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ),
        _settingRow(
          label: S.settingsHistorySummaryRefreshDelta,
          description: S.settingsHistorySummaryRefreshDeltaDesc,
          child: SizedBox(
            width: 320,
            child: TextField(
              controller: _historySummaryRefreshDeltaCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(fontSize: 13),
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ),
        _settingRow(
          label: S.settingsDefaultModel,
          description: S.settingsDefaultModelDesc,
          child: _placeholder(),
        ),
        _settingRow(
          label: S.settingsMaxContextTokens,
          description: S.settingsMaxContextTokensDesc,
          child: _placeholder(),
        ),
      ],
    );
  }

  Widget _buildModelManagement() {
    return Consumer<AppState>(
      builder: (context, state, _) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(S.settingsCatModelManagement),
            const SizedBox(height: 8),
            const Text(
              S.settingsModelManagementDesc,
              style: TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 560,
              child: Container(
                decoration: BoxDecoration(
                  color: DuckColors.bgRaised,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                  border: Border.all(color: DuckColors.border, width: 0.5),
                ),
                child: ModelManagementPanel(chat: state.chat),
              ),
            ),
          ],
        );
      },
    );
  }

  // ── Rules ──────────────────────────────────────────────────

  Widget _buildRules() {
    final workspace = context.watch<AppState>().currentDirectory;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatRules),
        const SizedBox(height: 8),
        Text(
          S.settingsRulesDesc,
          style: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
        ),
        const SizedBox(height: 16),
        _settingToggle(
          label: S.settingsAgentOutsideWorkspaceWrites,
          description: S.settingsAgentOutsideWorkspaceWritesDesc,
          value: _allowAgentOutsideWorkspaceWrites,
          onChanged: (v) =>
              setState(() => _allowAgentOutsideWorkspaceWrites = v),
        ),
        _settingToggle(
          label: S.settingsAgentAutoVerify,
          description: S.settingsAgentAutoVerifyDesc,
          value: _autoVerifyAfterEdits,
          onChanged: (v) => setState(() => _autoVerifyAfterEdits = v),
        ),
        _divider(),
        if (!_rulesLoaded)
          const Padding(
            padding: EdgeInsets.only(top: 24),
            child: CircularProgressIndicator(color: DuckColors.accentCyan),
          )
        else ...[
          _rulesEditorCard(
            title: S.rulesGlobalTitle,
            description: S.settingsGlobalRulesDesc,
            controller: _globalRulesCtrl,
          ),
          const SizedBox(height: 18),
          _rulesEditorCard(
            title: S.rulesWorkspaceTitle,
            description: workspace == null
                ? S.settingsWorkspaceRulesNoWorkspace
                : S.settingsWorkspaceRulesDesc,
            controller: _workspaceRulesCtrl,
            enabled: workspace != null,
          ),
        ],
      ],
    );
  }

  Widget _rulesEditorCard({
    required String title,
    required String description,
    required TextEditingController controller,
    bool enabled = true,
  }) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 820),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            description,
            style: const TextStyle(fontSize: 11.5, color: DuckColors.fgSubtle),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 230,
            child: TextField(
              controller: controller,
              enabled: enabled,
              maxLines: null,
              expands: true,
              textAlignVertical: TextAlignVertical.top,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 12.5,
                color: DuckColors.fgPrimary,
              ),
              decoration: InputDecoration(
                hintText: S.rulesPlaceholder,
                filled: true,
                fillColor: DuckColors.bgChip,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(color: DuckColors.border),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(color: DuckColors.border),
                ),
                disabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(color: DuckColors.glassSeam),
                ),
                contentPadding: const EdgeInsets.all(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── GitNexus ──────────────────────────────────────────────────

  Widget _buildGitNexus() {
    return Consumer<AppState>(
      builder: (context, state, _) {
        final gitnexus = state.gitnexus;
        final enabled = state.gitnexusEnabled;
        // Master kill-switch sits at the top. When off, the rest of
        // the panel collapses to a one-paragraph placeholder so the
        // user gets a clean "this integration is disabled" view
        // instead of a parade of greyed-out controls. Re-enabling
        // brings everything back live without a restart — the
        // service resumes its probe loop on the next
        // setEnabled(true).
        if (!enabled) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionHeader(S.settingsCatGitNexus),
              const SizedBox(height: 8),
              Text(
                S.gitnexusSettingsDesc,
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgSubtle,
                ),
              ),
              const SizedBox(height: 16),
              _gitnexusMasterToggle(state, enabled),
              const SizedBox(height: 18),
              _gitnexusOffPlaceholder(),
            ],
          );
        }
        final files = gitnexus.installedFiles();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _sectionHeader(S.settingsCatGitNexus),
            const SizedBox(height: 8),
            Text(
              S.gitnexusSettingsDesc,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
            ),
            const SizedBox(height: 16),
            _gitnexusMasterToggle(state, enabled),
            const SizedBox(height: 16),
            _GitNexusStatusCard(service: gitnexus),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton.icon(
                  icon: const Icon(Icons.account_tree_outlined, size: 16),
                  label: const Text(S.gitnexusAnalyzeNow),
                  onPressed:
                      gitnexus.isRunning || state.currentDirectory == null
                      ? null
                      : () => gitnexus.analyze(),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text(S.gitnexusReanalyze),
                  onPressed:
                      gitnexus.isRunning || state.currentDirectory == null
                      ? null
                      : () => gitnexus.analyze(force: true),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text(S.gitnexusStop),
                  onPressed: gitnexus.isRunning ? gitnexus.stop : null,
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text(S.gitnexusClean),
                  onPressed:
                      gitnexus.isRunning || state.currentDirectory == null
                      ? null
                      : gitnexus.clean,
                ),
              ],
            ),
            if (gitnexus.status == GitNexusStatus.noNode) ...[
              const SizedBox(height: 14),
              _warningBox(S.gitnexusMissingNodeHelp),
            ],
            const SizedBox(height: 22),
            _sectionLabel(S.gitnexusWikiSection),
            const SizedBox(height: 6),
            GitNexusWikiRow(
              service: gitnexus,
              workspaceOpen: state.currentDirectory != null,
              autoWiki: _gitnexusAutoWiki,
              modelController: _gitnexusWikiModelCtrl,
              onAutoWikiChanged: (v) => setState(() => _gitnexusAutoWiki = v),
            ),
            const SizedBox(height: 22),
            // ── Background services (serve / mcp daemons) ─────────
            _sectionLabel(S.gitnexusServicesSection),
            const SizedBox(height: 6),
            Text(
              S.gitnexusServicesDesc,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 12),
            GitNexusDaemonRow(
              service: gitnexus,
              workspaceOpen: state.currentDirectory != null,
              kind: GitNexusDaemonKind.serve,
            ),
            const SizedBox(height: 10),
            GitNexusDaemonRow(
              service: gitnexus,
              workspaceOpen: state.currentDirectory != null,
              kind: GitNexusDaemonKind.mcp,
            ),
            const SizedBox(height: 22),
            _sectionLabel(S.gitnexusInstalledFiles),
            const SizedBox(height: 8),
            for (final f in files) _gitnexusFileRow(f),
            const SizedBox(height: 18),
            _sectionLabel(S.gitnexusAnalyzeOutputLabel),
            const SizedBox(height: 8),
            _gitnexusOutputBox(gitnexus.outputTail),
          ],
        );
      },
    );
  }

  /// Master enable/disable row for the GitNexus integration. Sits at
  /// the top of the GitNexus settings tab so the kill-switch is the
  /// first thing the user sees. The body explicitly tells the user
  /// what "off" actually does (no probe, no icon, no auto-attach) so
  /// the trade-off is visible at decision time, not after the fact.
  Widget _gitnexusMasterToggle(AppState state, bool enabled) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: enabled
              ? DuckColors.accentDuck.withValues(alpha: 0.40)
              : DuckColors.glassSeam,
          width: 0.5,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  S.gitnexusMasterToggleTitle,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: DuckColors.fgPrimary,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  S.gitnexusMasterToggleDesc,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.fgMuted,
                    height: 1.45,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: enabled,
            onChanged: (v) => state.setGitNexusEnabled(v),
            activeThumbColor: DuckColors.accentDuck,
          ),
        ],
      ),
    );
  }

  /// Shown when the GitNexus master switch is off — keeps the panel
  /// from looking broken / empty without dragging back the controls
  /// the user just disabled.
  Widget _gitnexusOffPlaceholder() {
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: const Text(
        S.gitnexusDisabledPlaceholder,
        style: TextStyle(fontSize: 12, color: DuckColors.fgMuted, height: 1.5),
      ),
    );
  }

  Widget _gitnexusOutputBox(String text) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 820, minHeight: 140),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: SelectableText(
        text.isEmpty ? '(no output yet)' : text,
        style: const TextStyle(
          fontFamily: DuckTheme.monoFont,
          fontSize: 11,
          color: DuckColors.fgSubtle,
          height: 1.35,
        ),
      ),
    );
  }

  Widget _warningBox(String text) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DuckColors.stateWarn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.stateWarn.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 12,
          color: DuckColors.fgMuted,
          height: 1.4,
        ),
      ),
    );
  }

  Widget _gitnexusFileRow(GitNexusInstalledFile file) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        children: [
          Icon(
            file.exists
                ? Icons.check_circle_outline
                : Icons.radio_button_unchecked,
            size: 14,
            color: file.exists ? DuckColors.accentMint : DuckColors.fgSubtle,
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 170,
            child: Text(
              file.label,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgPrimary),
            ),
          ),
          Expanded(
            child: Text(
              file.path,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 11,
                color: DuckColors.fgSubtle,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Syncthing ──────────────────────────────────────────────────

  Future<void> _testSyncthingConnection() async {
    setState(() {
      _stTesting = true;
      _stReachable = null;
      _stAuthOk = null;
      _stDeviceId = null;
      _stVersion = null;
      _stFolders = [];
      _stDevices = [];
      _stPendingFolders = {};
      _stPendingDevices = {};
      _stOurIntroducers = [];
    });

    // Use a temporary service instance with the current form values
    // (the user may not have saved yet).
    final svc = SyncthingService(
      baseUrl: _stEndpointCtrl.text.trim(),
      apiKey: _stApiKeyCtrl.text.trim(),
    );

    final reachable = await svc.isReachable();
    if (!mounted) return;
    setState(() => _stReachable = reachable);

    if (!reachable) {
      setState(() => _stTesting = false);
      return;
    }

    final authOk = await svc.ping();
    if (!mounted) return;
    setState(() => _stAuthOk = authOk);

    if (authOk) {
      final status = await svc.systemStatus();
      final folders = await svc.listFolders();
      final devices = await svc.listDevices();
      final pendingFolders = await svc.pendingFolders();
      final pendingDevices = await svc.pendingDevices();
      if (!mounted) return;
      setState(() {
        _stDeviceId = status?['myID'] as String?;
        _stVersion = status?['version'] as String?;
        _stFolders = folders;
        _stDevices = devices;
        _stPendingFolders = pendingFolders;
        _stPendingDevices = pendingDevices;
        _stOurIntroducers = devices
            .where((d) => d['introducer'] == true)
            .map((d) => (d['deviceID'] as String?) ?? '')
            .where((id) => id.isNotEmpty)
            .toList();
      });
    }

    setState(() => _stTesting = false);
  }

  Future<void> _refreshPendingPanels() async {
    final a = context.read<AppState>();
    final pf = await a.syncthing.pendingFolders();
    final pd = await a.syncthing.pendingDevices();
    final devs = await a.syncthing.listDevices();
    if (!mounted) return;
    setState(() {
      _stPendingFolders = pf;
      _stPendingDevices = pd;
      _stDevices = devs;
      _stOurIntroducers = devs
          .where((d) => d['introducer'] == true)
          .map((d) => (d['deviceID'] as String?) ?? '')
          .where((id) => id.isNotEmpty)
          .toList();
    });
  }

  Widget _buildSyncthing() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatSyncthing),
        const SizedBox(height: 16),
        // Background blurb — what Syncthing is + the why-Lumen-uses-it
        // quip. Sits at the top of the panel so users encountering
        // Syncthing for the first time aren't dropped straight into
        // endpoint / API-key fields.
        _SyncthingAbout(),
        const SizedBox(height: 18),
        _settingToggle(
          label: S.settingsSyncthingEnable,
          description: S.settingsSyncthingEnableDesc,
          value: _stEnabled,
          onChanged: (v) => setState(() => _stEnabled = v),
        ),
        if (_stEnabled) ...[
          _settingRow(
            label: S.settingsSyncthingEndpoint,
            description: S.settingsSyncthingEndpointDesc,
            child: SizedBox(
              width: 320,
              child: TextField(
                controller: _stEndpointCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'http://localhost:8384',
                ),
              ),
            ),
          ),
          _settingRow(
            label: S.settingsSyncthingApiKey,
            description: S.settingsSyncthingApiKeyDesc,
            child: SizedBox(
              width: 320,
              child: TextField(
                controller: _stApiKeyCtrl,
                obscureText: !_showStApiKey,
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'optional',
                  suffixIcon: IconButton(
                    icon: Icon(
                      _showStApiKey ? Icons.visibility_off : Icons.visibility,
                      size: 18,
                      color: DuckColors.fgMuted,
                    ),
                    onPressed: () =>
                        setState(() => _showStApiKey = !_showStApiKey),
                    tooltip: _showStApiKey ? 'Hide' : 'Show',
                  ),
                ),
              ),
            ),
          ),
          _settingToggle(
            label: S.settingsSyncthingAutoShare,
            description: S.settingsSyncthingAutoShareDesc,
            value: _stAutoShare,
            onChanged: (v) => setState(() => _stAutoShare = v),
          ),
          _divider(),
          // Test connection button
          Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Row(
              children: [
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: DuckColors.bgChip,
                    foregroundColor: DuckColors.fgPrimary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      side: const BorderSide(
                        color: DuckColors.border,
                        width: 0.5,
                      ),
                    ),
                  ),
                  onPressed: _stTesting ? null : _testSyncthingConnection,
                  child: Text(
                    _stTesting
                        ? S.settingsSyncthingTesting
                        : S.settingsSyncthingTestBtn,
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(width: 16),
                if (_stReachable != null)
                  _statusChip(
                    _stReachable!
                        ? S.settingsSyncthingReachable
                        : S.settingsSyncthingUnreachable,
                    _stReachable!,
                  ),
                if (_stAuthOk != null) ...[
                  const SizedBox(width: 8),
                  _statusChip(
                    _stAuthOk!
                        ? S.settingsSyncthingAuthOk
                        : S.settingsSyncthingAuthFail,
                    _stAuthOk!,
                  ),
                ],
              ],
            ),
          ),
          // Status info
          if (_stDeviceId != null) ...[
            _infoRow(S.settingsSyncthingDeviceId, _stDeviceId!),
          ],
          if (_stVersion != null) ...[
            _infoRow(S.settingsSyncthingVersion, _stVersion!),
          ],

          // ── Sharing defaults (safety-critical) ────────────────
          _divider(),
          _sectionLabel(S.settingsSyncthingSharingDefaults),
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              S.settingsSyncthingSharingDefaultsDesc,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.4,
              ),
            ),
          ),
          _settingRow(
            label: S.settingsSyncthingDefaultLandingPath,
            description: S.settingsSyncthingDefaultLandingPathDesc,
            child: SizedBox(
              width: 320,
              child: TextField(
                controller: _stLandingPathCtrl,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(hintText: '~/Lumen-Sync'),
              ),
            ),
          ),
          _settingRow(
            label: S.settingsSyncthingVersioningPreset,
            description: S.settingsSyncthingVersioningPresetDesc,
            child: SizedBox(
              width: 320,
              child: DropdownButtonFormField<String>(
                initialValue: _stVersioningPreset,
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                ),
                items: SyncthingVersioningPreset.values
                    .map(
                      (p) => DropdownMenuItem(
                        value: p.key,
                        child: Text(
                          p.label,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (v) => setState(
                  () => _stVersioningPreset = v ?? _stVersioningPreset,
                ),
              ),
            ),
          ),
          _settingToggle(
            label: S.settingsSyncthingIgnorePerms,
            description: S.settingsSyncthingIgnorePermsDesc,
            value: _stIgnorePerms,
            onChanged: (v) => setState(() => _stIgnorePerms = v),
          ),
          _settingToggle(
            label: S.settingsSyncthingWriteStignore,
            description: S.settingsSyncthingWriteStignoreDesc,
            value: _stWriteStignore,
            onChanged: (v) => setState(() => _stWriteStignore = v),
          ),
          _settingToggle(
            label: S.settingsSyncthingAutoAcceptRemote,
            description: S.settingsSyncthingAutoAcceptRemoteDesc,
            value: _stAutoAcceptRemote,
            onChanged: (v) => setState(() => _stAutoAcceptRemote = v),
          ),

          // ── Live cluster panels (only meaningful after Test Connection) ──
          if (_stAuthOk == true) ...[
            _divider(),

            // Mutual-introducer warning + one-click fix.
            SyncthingIntroducerWarning(
              introducerDeviceIds: _stOurIntroducers,
              onFix: () async {
                final fixed = await context
                    .read<AppState>()
                    .syncthingClearAllIntroducers();
                if (!mounted) return;
                showDuckToast(
                  context,
                  S.settingsSyncthingIntroducerFixedToast.replaceAll(
                    '{n}',
                    '$fixed',
                  ),
                );
                await _refreshPendingPanels();
              },
            ),

            // Pending folders panel.
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _sectionLabel(S.settingsSyncthingPendingFolders),
                TextButton.icon(
                  onPressed: _refreshPendingPanels,
                  icon: const Icon(Icons.refresh, size: 14),
                  label: const Text(
                    S.settingsSyncthingRefreshPending,
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
            SyncthingPendingFoldersPanel(
              pending: _stPendingFolders,
              deviceNamesById: {
                for (final d in _stDevices)
                  if (d['deviceID'] is String)
                    d['deviceID'] as String:
                        (d['name'] as String?) ?? (d['deviceID'] as String),
              },
              state: context.read<AppState>(),
              onChanged: _refreshPendingPanels,
            ),

            // Pending devices panel.
            _sectionLabel(S.settingsSyncthingPendingDevices),
            SyncthingPendingDevicesPanel(
              pending: _stPendingDevices,
              state: context.read<AppState>(),
              onChanged: _refreshPendingPanels,
            ),
          ],

          // ── Existing folders / devices (read-only summary) ────
          if (_stFolders.isNotEmpty) ...[
            _divider(),
            _sectionLabel(S.settingsSyncthingFolders),
            for (final f in _stFolders) _folderRow(f),
          ] else if (_stAuthOk == true) ...[
            _divider(),
            _sectionLabel(S.settingsSyncthingFolders),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                S.settingsSyncthingNoFolders,
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
          ],
          if (_stDevices.isNotEmpty) ...[
            _divider(),
            _sectionLabel(S.settingsSyncthingDevices),
            for (final d in _stDevices) _deviceRow(d),
          ] else if (_stAuthOk == true) ...[
            _divider(),
            _sectionLabel(S.settingsSyncthingDevices),
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                S.settingsSyncthingNoDevices,
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _statusChip(String label, bool ok) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: ok
            ? DuckColors.stateOk.withValues(alpha: 0.15)
            : DuckColors.stateError.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: ok
              ? DuckColors.stateOk.withValues(alpha: 0.4)
              : DuckColors.stateError.withValues(alpha: 0.4),
          width: 0.5,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: ok ? DuckColors.stateOk : DuckColors.stateError,
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: DuckTheme.monoFont,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _folderRow(Map<String, dynamic> f) {
    final id = f['id'] ?? '';
    final label = f['label'] ?? id;
    final path = f['path'] ?? '';
    final paused = f['paused'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            paused ? Icons.pause_circle_outline : Icons.folder_outlined,
            size: 14,
            color: paused ? DuckColors.fgSubtle : DuckColors.accentMint,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$label',
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                Text(
                  path,
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: DuckTheme.monoFont,
                    color: DuckColors.fgSubtle,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _deviceRow(Map<String, dynamic> d) {
    final name = d['name'] ?? '';
    final id = (d['deviceID'] ?? '') as String;
    final short = id.length > 12 ? '${id.substring(0, 12)}...' : id;
    final paused = d['paused'] == true;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Icon(
            paused ? Icons.pause_circle_outline : Icons.devices_outlined,
            size: 14,
            color: paused ? DuckColors.fgSubtle : DuckColors.accentCyan,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name.isNotEmpty ? name : short,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                if (name.isNotEmpty)
                  Text(
                    short,
                    style: const TextStyle(
                      fontSize: 11,
                      fontFamily: DuckTheme.monoFont,
                      color: DuckColors.fgSubtle,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Tools ──────────────────────────────────────────────────

  Widget _buildTools() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatTools),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.auto_awesome, size: 16),
            label: const Text(S.manualSkillTitle),
            onPressed: () => showManualSkillDialog(context),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.bgChip,
              foregroundColor: DuckColors.fgPrimary,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
          ),
        ),
        const SizedBox(height: 22),
        // ── Tools (commands the agent invokes) ─────────────────────
        _sectionLabel(S.toolsActiveHeader),
        const SizedBox(height: 6),
        for (final t in ToolRegistry.all) ...[_toolRow(t)],
        if (ToolRegistry.runtime.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              S.toolsNoExternal,
              style: const TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
            ),
          ),
        const SizedBox(height: 22),
        // ── Skills (instruction-based markdown) ────────────────────
        _sectionLabel(S.skillsActiveHeader),
        const SizedBox(height: 6),
        Text(
          S.skillsToolDistinction,
          style: const TextStyle(
            fontSize: 11.5,
            color: DuckColors.fgMuted,
            height: 1.45,
          ),
        ),
        const SizedBox(height: 12),
        const AgentSkillsList(),
      ],
    );
  }

  Widget _toolRow(AgentTool t) {
    final enabled = context.read<AppState>().chat.enabledTools.contains(t.id);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        t.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ),
                    if (t.isExternal) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: DuckColors.bgChip,
                          borderRadius: BorderRadius.circular(
                            DuckTheme.radiusS,
                          ),
                          border: Border.all(
                            color: DuckColors.glassSeam,
                            width: 0.5,
                          ),
                        ),
                        child: const Text(
                          S.toolsExternalChip,
                          style: TextStyle(
                            fontSize: 9,
                            letterSpacing: 0.5,
                            color: DuckColors.accentCyan,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  t.description,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: (_) {
              context.read<AppState>().chat.toggleTool(t.id);
              setState(() {});
            },
            activeThumbColor: DuckColors.accentCyan,
          ),
        ],
      ),
    );
  }

  // ── Keyboard Shortcuts ──────────────────────────────────────

  Widget _buildKeys() {
    const shortcuts = <String, String>{
      'New Window': 'Ctrl+Shift+N',
      'Save File': 'Ctrl+S',
      'Undo': 'Ctrl+Z',
      'Redo': 'Ctrl+Y / Ctrl+Shift+Z',
      'Cut': 'Ctrl+X',
      'Copy': 'Ctrl+C',
      'Paste': 'Ctrl+V',
      'Select All': 'Ctrl+A',
      'Find in File': 'Ctrl+F',
      'Find and Replace': 'Ctrl+H',
      'Command Palette': 'Ctrl+Shift+P',
      'Search in Files': 'Ctrl+Shift+F',
      'New Terminal': 'Ctrl+`',
      'Open Folder': 'Ctrl+O',
      'Terminal Copy': 'Ctrl+Shift+C',
      'Terminal Paste': 'Ctrl+Shift+V',
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatKeys),
        const SizedBox(height: 8),
        Text(
          S.settingsShortcutsReadonly,
          style: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
        ),
        const SizedBox(height: 16),
        // Header row
        Row(
          children: [
            SizedBox(
              width: 200,
              child: Text(
                S.settingsShortcutAction.toUpperCase(),
                style: const TextStyle(
                  fontSize: 10,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
            Text(
              S.settingsShortcutBinding.toUpperCase(),
              style: const TextStyle(
                fontSize: 10,
                letterSpacing: 0.8,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgSubtle,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Divider(height: 1, color: DuckColors.border),
        const SizedBox(height: 4),
        for (final e in shortcuts.entries) _shortcutRow(e.key, e.value),
      ],
    );
  }

  Widget _shortcutRow(String action, String binding) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 200,
            child: Text(
              action,
              style: const TextStyle(fontSize: 13, color: DuckColors.fgPrimary),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.border, width: 0.5),
            ),
            child: Text(
              binding,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: DuckTheme.monoFont,
                color: DuckColors.fgMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Shared helpers ──────────────────────────────────────────

  Widget _sectionHeader(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w600,
        color: DuckColors.fgSubtle,
      ),
    );
  }

  Widget _sectionLabel(String label) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(
        label.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          letterSpacing: 1.0,
          fontWeight: FontWeight.w600,
          color: DuckColors.fgSubtle,
        ),
      ),
    );
  }

  Widget _apiKeyField({
    required TextEditingController controller,
    required bool visible,
    required ValueChanged<bool> onToggle,
  }) {
    return SizedBox(
      width: 320,
      child: TextField(
        controller: controller,
        obscureText: !visible,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          suffixIcon: IconButton(
            icon: Icon(
              visible ? Icons.visibility_off : Icons.visibility,
              size: 18,
              color: DuckColors.fgMuted,
            ),
            onPressed: () => setState(() => onToggle(!visible)),
            tooltip: visible ? 'Hide' : 'Show',
          ),
        ),
      ),
    );
  }

  Widget _settingRow({
    required String label,
    required String description,
    required Widget child,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          child,
        ],
      ),
    );
  }

  Widget _settingToggle({
    required String label,
    required String description,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 24),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: DuckColors.accentCyan,
          ),
        ],
      ),
    );
  }

  Widget _divider() {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 8),
      child: Divider(height: 1, color: DuckColors.border),
    );
  }

  /// Placeholder for settings that aren't wired up yet.
  Widget _placeholder() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: const Text(
        'Coming soon',
        style: TextStyle(
          fontSize: 11,
          fontStyle: FontStyle.italic,
          color: DuckColors.fgSubtle,
        ),
      ),
    );
  }
}

/// Small chip rendering one auto-approved tool. Shows the tool's
/// human name (uppercased id) plus an X button that revokes that
/// single tool. Used in the Settings → AI/Chat list — see
/// `Consumer<AppState>` block above the default-model row.
class _ApprovedToolChip extends StatelessWidget {
  final String toolId;
  final VoidCallback onRevoke;
  const _ApprovedToolChip({required this.toolId, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    final name = toolId.toUpperCase();
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: const TextStyle(
              fontFamily: DuckTheme.monoFont,
              fontSize: 11,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: S.settingsAutoApprovedRevoke,
            child: InkWell(
              onTap: onRevoke,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 12, color: DuckColors.fgSubtle),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Background blurb at the top of the Settings → Syncthing panel.
/// Two short paragraphs (what / why) plus a clickable `syncthing.net`
/// link. The link uses the same `Process.start` browser-launch
/// pattern as `MediaController.openInBrowser` — no `url_launcher`
/// dependency since we already have the platform-launch idiom in the
/// codebase.
class _SyncthingAbout extends StatelessWidget {
  const _SyncthingAbout();

  static const _url = 'https://syncthing.net';

  Future<void> _open() async {
    try {
      if (Platform.isWindows) {
        await Process.start('cmd', ['/c', 'start', '', _url]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [_url]);
      } else {
        await Process.start('xdg-open', [_url]);
      }
    } catch (_) {
      // Best-effort — if no handler is registered for http(s),
      // there's nothing the IDE can do beyond surface the URL,
      // which the label already does.
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── About paragraph ────────────────────────────────────
          const Text(
            S.settingsSyncthingAboutTitle,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 6),
          // RichText so the URL is inline and clickable, not a
          // separate "Open syncthing.net" button.
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontSize: 12,
                height: 1.5,
                color: DuckColors.fgMuted,
              ),
              children: [
                const TextSpan(text: S.settingsSyncthingAboutBody),
                const TextSpan(text: ' '),
                TextSpan(
                  text: S.settingsSyncthingLinkLabel,
                  style: const TextStyle(
                    color: DuckColors.accentCyan,
                    decoration: TextDecoration.underline,
                  ),
                  recognizer: TapGestureRecognizer()..onTap = _open,
                ),
                const TextSpan(text: '.'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _GitNexusStatusCard extends StatelessWidget {
  final GitNexusService service;
  const _GitNexusStatusCard({required this.service});

  @override
  Widget build(BuildContext context) {
    final (label, color, icon) = switch (service.status) {
      GitNexusStatus.noWorkspace => (
        S.gitnexusStatusNoWorkspace,
        DuckColors.fgSubtle,
        Icons.folder_off_outlined,
      ),
      GitNexusStatus.noNode => (
        S.gitnexusStatusNoNode,
        DuckColors.stateWarn,
        Icons.warning_amber_outlined,
      ),
      GitNexusStatus.notIndexed => (
        S.gitnexusStatusNotIndexed,
        DuckColors.fgMuted,
        Icons.account_tree_outlined,
      ),
      GitNexusStatus.indexed => (
        S.gitnexusStatusIndexed,
        DuckColors.accentDuck,
        Icons.check_circle_outline,
      ),
      GitNexusStatus.running => (
        S.gitnexusStatusRunning,
        DuckColors.stateWarn,
        Icons.sync,
      ),
      GitNexusStatus.failed => (
        S.gitnexusStatusFailed,
        DuckColors.stateError,
        Icons.error_outline,
      ),
    };
    return Container(
      constraints: const BoxConstraints(maxWidth: 820),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  service.workspacePath ?? S.gitnexusStatusNoWorkspace,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: DuckTheme.monoFont,
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ],
            ),
          ),
          if (service.isRunning)
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: DuckColors.stateWarn,
              ),
            ),
        ],
      ),
    );
  }
}
