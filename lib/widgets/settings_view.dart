import 'package:flutter/material.dart';

import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/copilot_service.dart';
import '../services/tool_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'agent_skills/agent_skills_list.dart';
import 'common/duck_toast.dart';
import 'editor/editor_themes.dart';
import 'editor/theme_preview.dart';
import 'manual_skill_dialog.dart';
import 'ai_chat/model_management_panel.dart';
import 'remote_access/remote_access_panel.dart';
import 'ssh/ssh_settings_panel.dart';

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
  remoteAccess,
  ssh,
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
  late TextEditingController _copilotKeyCtrl;
  late bool _copilotUseLoggedInUser;
  bool _copilotTesting = false;
  bool _copilotLoginLaunching = false;
  String? _copilotTestMessage;
  bool? _copilotTestOk;
  late TextEditingController _openaiKeyCtrl;

  // API key visibility toggles
  bool _showOllamaKey = false;
  bool _showGeminiKey = false;
  bool _showClaudeKey = false;
  bool _showCopilotKey = false;
  bool _showOpenaiKey = false;

  late String _editorTheme;
  late double _fontSize;
  late int _tabSize;
  late bool _wordWrap;
  bool _showLineNumbers = true;
  bool _minimap = false;
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
  late TextEditingController _globalRulesCtrl;
  late TextEditingController _workspaceRulesCtrl;
  bool _rulesLoaded = false;
  int _seenSettingsOpenRevision = -1;

  static _SettingsCategory _categoryFromKey(String key) {
    return switch (key) {
      'editor' => _SettingsCategory.editor,
      'theme' => _SettingsCategory.theme,
      'terminal' => _SettingsCategory.terminal,
      'aiChat' => _SettingsCategory.aiChat,
      'models' => _SettingsCategory.modelManagement,
      'rules' => _SettingsCategory.rules,
      'remoteAccess' => _SettingsCategory.remoteAccess,
      'ssh' => _SettingsCategory.ssh,
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
    _copilotKeyCtrl = TextEditingController(text: a.copilotApiKey);
    _copilotUseLoggedInUser = a.copilotUseLoggedInUser;
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
    _globalRulesCtrl = TextEditingController();
    _workspaceRulesCtrl = TextEditingController();
    _active = _categoryFromKey(a.settingsInitialCategory);
    _seenSettingsOpenRevision = a.settingsOpenRevision;
    _loadRules();
  }

  @override
  void dispose() {
    // Clear any in-flight theme preview so closing Settings without
    // Save reverts the open editor to its persisted theme. Safe even
    // when no preview is set — the setter is a no-op in that case.
    try {
      context.read<AppState>().setPreviewEditorTheme(null);
    } catch (_) {
      // context may already be deactivated mid-dispose on some teardown
      // paths; the preview is non-persisted so dropping the clear is
      // harmless in that case.
    }
    _ollamaEndpointCtrl.dispose();
    _ollamaApiKeyCtrl.dispose();
    _geminiKeyCtrl.dispose();
    _claudeKeyCtrl.dispose();
    _copilotKeyCtrl.dispose();
    _openaiKeyCtrl.dispose();
    _toolCompressionThresholdCtrl.dispose();
    _historySummaryMaxCharsCtrl.dispose();
    _historySummaryRefreshDeltaCtrl.dispose();
    _globalRulesCtrl.dispose();
    _workspaceRulesCtrl.dispose();
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
      copilotApiKey: _copilotKeyCtrl.text,
      copilotUseLoggedInUser: _copilotUseLoggedInUser,
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
      maxChars: parsedHistoryMaxChars == null || parsedHistoryMaxChars <= 0
          ? 1200
          : parsedHistoryMaxChars,
      refreshDelta:
          parsedHistoryRefreshDelta == null || parsedHistoryRefreshDelta <= 0
          ? 10
          : parsedHistoryRefreshDelta,
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
    if (!mounted) return;
    showDuckToast(context, S.settingsSaved);
  }

  Future<void> _testCopilotConnection() async {
    setState(() {
      _copilotTesting = true;
      _copilotTestMessage = null;
      _copilotTestOk = null;
    });
    final svc = CopilotService(
      apiKey: _copilotKeyCtrl.text.trim(),
      useLoggedInUser: _copilotUseLoggedInUser,
    );
    final result = await svc.testConnection();
    await svc.dispose();
    if (!mounted) return;
    setState(() {
      _copilotTesting = false;
      _copilotTestOk = result.ok;
      _copilotTestMessage = result.message;
    });
  }

  Future<void> _openCopilotLoginTerminal() async {
    setState(() {
      _copilotLoginLaunching = true;
      _copilotTestMessage = null;
      _copilotTestOk = null;
    });
    final result = await context
        .read<AppState>()
        .copilotService
        .openLoginTerminal();
    if (!mounted) return;
    setState(() {
      _copilotLoginLaunching = false;
      _copilotTestOk = result.ok;
      _copilotTestMessage = result.message;
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
                _sidebarItem(
                  S.settingsCatRemoteAccess,
                  _SettingsCategory.remoteAccess,
                ),
                _sidebarItem(S.settingsCatSsh, _SettingsCategory.ssh),
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
      case _SettingsCategory.remoteAccess:
        return const RemoteAccessPanel();
      case _SettingsCategory.ssh:
        return const SshSettingsPanel();
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
                S.providerCopilot,
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
        _sectionLabel(S.settingsCopilotSection),
        _settingRow(
          label: S.settingsApiKey,
          description: S.settingsCopilotApiKeyDesc,
          child: SizedBox(
            width: 320,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _apiKeyField(
                  controller: _copilotKeyCtrl,
                  visible: _showCopilotKey,
                  onToggle: (v) => _showCopilotKey = v,
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    S.settingsCopilotUseLoggedInLabel,
                    style: TextStyle(fontSize: 12.5),
                  ),
                  subtitle: const Text(
                    S.settingsCopilotUseLoggedInDesc,
                    style: TextStyle(fontSize: 11, color: DuckColors.fgSubtle),
                  ),
                  value: _copilotUseLoggedInUser,
                  onChanged: (v) => setState(() => _copilotUseLoggedInUser = v),
                  activeThumbColor: DuckColors.accentCyan,
                ),
                const SizedBox(height: 8),
                Text(
                  S.llmProvidersCopilotLoginHint,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                    height: 1.35,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
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
                      icon: _copilotLoginLaunching
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.login, size: 14),
                      label: Text(
                        _copilotLoginLaunching
                            ? S.settingsCopilotLoginLaunchingBtn
                            : S.settingsCopilotLoginBtn,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onPressed: _copilotLoginLaunching
                          ? null
                          : _openCopilotLoginTerminal,
                    ),
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
                      icon: _copilotTesting
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                              ),
                            )
                          : const Icon(Icons.check_circle_outline, size: 14),
                      label: Text(
                        _copilotTesting
                            ? S.settingsCopilotTestingBtn
                            : S.settingsCopilotTestBtn,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                      onPressed: _copilotTesting
                          ? null
                          : _testCopilotConnection,
                    ),
                  ],
                ),
                if (_copilotTestMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _copilotTestMessage!,
                    style: TextStyle(
                      fontSize: 11,
                      color: _copilotTestOk == true
                          ? DuckColors.stateOk
                          : DuckColors.stateError,
                    ),
                  ),
                ],
              ],
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
          value: _showLineNumbers,
          onChanged: (v) => setState(() => _showLineNumbers = v),
        ),
        _settingToggle(
          label: S.settingsMinimap,
          description: S.settingsMinimapDesc,
          value: _minimap,
          onChanged: (v) => setState(() => _minimap = v),
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
          description: S.settingsThemeDesc,
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
              onChanged: (v) {
                if (v == null) return;
                setState(() => _editorTheme = v);
                // Push the candidate to AppState so the open editor +
                // the preview block below repaint with it immediately.
                // The persisted theme only flips on Save; closing
                // Settings without Save reverts (see dispose).
                context.read<AppState>().setPreviewEditorTheme(v);
              },
            ),
          ),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            S.settingsThemePreviewLabel,
            style: const TextStyle(
              fontSize: 11,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgSubtle,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: ThemePreviewBlock(themeId: _editorTheme),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            S.settingsThemePreviewHint,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
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
                      isExpanded: true,
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
  /// Storage key — either a bare tool id (`delete_file`) or a
  /// `toolId:fingerprint` composite (`run_cmd:npm`). The chip
  /// splits the composite for display so the user sees the binary
  /// they granted ("RUN_CMD `npm`") instead of an opaque
  /// concatenated string.
  final String toolId;
  final VoidCallback onRevoke;
  const _ApprovedToolChip({required this.toolId, required this.onRevoke});

  @override
  Widget build(BuildContext context) {
    // Split rich keys on the first `:`. `delete_file` → ['delete_file'].
    // `run_cmd:npm` → ['run_cmd', 'npm']. Anything more exotic
    // (multiple colons) preserves everything after the first `:`
    // as the fingerprint so a hypothetical future scheme that
    // includes colons in fingerprints (e.g. `run_cmd:foo:bar`)
    // still renders sensibly.
    final colonIdx = toolId.indexOf(':');
    final hasFingerprint = colonIdx > 0 && colonIdx < toolId.length - 1;
    final baseId = hasFingerprint ? toolId.substring(0, colonIdx) : toolId;
    final fingerprint = hasFingerprint ? toolId.substring(colonIdx + 1) : '';

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
          // Tool id (uppercase) — same dim affordance as before so
          // the chip's identity reads consistently across bare
          // tool grants and per-command grants.
          Text(
            baseId.toUpperCase(),
            style: const TextStyle(
              fontFamily: DuckTheme.monoFont,
              fontSize: 11,
              color: DuckColors.fgSubtle,
              letterSpacing: 0.4,
            ),
          ),
          // Fingerprint segment (e.g. `npm`) rendered right of the
          // tool id with a brighter colour — this is the actual
          // unit of trust granted, so it earns the visual focus.
          // Hidden for bare-id keys.
          if (fingerprint.isNotEmpty) ...[
            const SizedBox(width: 6),
            Text(
              fingerprint,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 11.5,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
            ),
          ],
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
