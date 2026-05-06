import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/tool_registry.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';
import 'editor/editor_themes.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key});

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late Set<String> _enabledProviders;
  late TextEditingController _ollamaEndpointCtrl;
  late TextEditingController _geminiKeyCtrl;
  late TextEditingController _claudeKeyCtrl;
  late TextEditingController _openaiKeyCtrl;
  late String _theme;
  late double _fontSize;
  late int _tabSize;
  late bool _wordWrap;
  late bool _autoApprove;
  late bool _reduceMotion;
  late bool _reduceTransparency;

  @override
  void initState() {
    super.initState();
    final a = context.read<AppState>();
    _enabledProviders = Set<String>.from(a.enabledProviders);
    _ollamaEndpointCtrl = TextEditingController(text: a.ollamaEndpoint);
    _geminiKeyCtrl = TextEditingController(text: a.geminiApiKey);
    _claudeKeyCtrl = TextEditingController(text: a.anthropicApiKey);
    _openaiKeyCtrl = TextEditingController(text: a.openaiApiKey);
    _theme = a.editorTheme;
    _fontSize = a.editorFontSize;
    _tabSize = a.editorTabSize;
    _wordWrap = a.wordWrap;
    _autoApprove = a.chat.autoApprove;
    _reduceMotion = a.reduceMotion;
    _reduceTransparency = a.reduceTransparency;
  }

  @override
  void dispose() {
    _ollamaEndpointCtrl.dispose();
    _geminiKeyCtrl.dispose();
    _claudeKeyCtrl.dispose();
    _openaiKeyCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Transparent so DuckGlass.hero supplies the surface; the dialog
    // theme's default backgroundColor would otherwise paint a flat
    // bgRaised behind the blur.
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.settings,
                    size: 18,
                    color: DuckColors.accentPurple,
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    S.settingsTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 620),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _section(S.settingsLlmProvider),
                      const SizedBox(height: 4),
                      for (final p in const [
                        S.providerOllama,
                        S.providerGemini,
                        S.providerClaude,
                        S.providerGithub,
                        S.providerCopilot,
                        S.providerOpenAI,
                      ])
                        Row(
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
                                side: const BorderSide(
                                  color: DuckColors.fgMuted,
                                ),
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
                      const SizedBox(height: 12),
                      _section(S.settingsOllamaSection),
                      TextField(controller: _ollamaEndpointCtrl),
                      const SizedBox(height: 10),
                      _section(S.settingsGeminiSection),
                      TextField(controller: _geminiKeyCtrl, obscureText: true),
                      const SizedBox(height: 10),
                      _section(S.settingsClaudeSection),
                      TextField(controller: _claudeKeyCtrl, obscureText: true),
                      const SizedBox(height: 10),
                      _section(S.settingsOpenAISection),
                      TextField(controller: _openaiKeyCtrl, obscureText: true),
                      const SizedBox(height: 16),
                      _section(S.settingsTheme),
                      DropdownButtonFormField<String>(
                        initialValue: _theme,
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
                        onChanged: (v) => setState(() => _theme = v ?? _theme),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _section(S.settingsFontSize),
                                Slider(
                                  min: 10,
                                  max: 22,
                                  divisions: 24,
                                  value: _fontSize,
                                  label: _fontSize.toStringAsFixed(1),
                                  onChanged: (v) =>
                                      setState(() => _fontSize = v),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _section(S.settingsTabSize),
                                DropdownButtonFormField<int>(
                                  initialValue: _tabSize,
                                  items: const [2, 4, 8]
                                      .map(
                                        (n) => DropdownMenuItem(
                                          value: n,
                                          child: Text('$n'),
                                        ),
                                      )
                                      .toList(),
                                  onChanged: (v) =>
                                      setState(() => _tabSize = v ?? _tabSize),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          S.settingsWordWrap,
                          style: TextStyle(fontSize: 13),
                        ),
                        value: _wordWrap,
                        onChanged: (v) => setState(() => _wordWrap = v),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          S.settingsAutoApprove,
                          style: TextStyle(fontSize: 13),
                        ),
                        subtitle: const Text(
                          S.settingsAutoApproveDesc,
                          style: TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgSubtle,
                          ),
                        ),
                        value: _autoApprove,
                        onChanged: (v) => setState(() => _autoApprove = v),
                      ),
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      _section(S.toolsActiveHeader),
                      for (final t in ToolRegistry.all)
                        SwitchListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          title: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  t.name,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
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
                          subtitle: Text(
                            t.description,
                            style: const TextStyle(fontSize: 11),
                          ),
                          value: context
                              .read<AppState>()
                              .chat
                              .enabledTools
                              .contains(t.id),
                          onChanged: (_) {
                            context.read<AppState>().chat.toggleTool(t.id);
                            setState(() {});
                          },
                        ),
                      if (ToolRegistry.runtime.isEmpty) ...[
                        const SizedBox(height: 8),
                        const Text(
                          S.toolsNoExternal,
                          style: TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgSubtle,
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      const Divider(),
                      const SizedBox(height: 8),
                      _section(S.settingsAppearanceSection),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          S.settingsReduceTransparency,
                          style: TextStyle(fontSize: 13),
                        ),
                        subtitle: const Text(
                          S.settingsReduceTransparencyDesc,
                          style: TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgSubtle,
                          ),
                        ),
                        value: _reduceTransparency,
                        onChanged: (v) =>
                            setState(() => _reduceTransparency = v),
                      ),
                      SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          S.settingsReduceMotion,
                          style: TextStyle(fontSize: 13),
                        ),
                        subtitle: const Text(
                          S.settingsReduceMotionDesc,
                          style: TextStyle(
                            fontSize: 11,
                            color: DuckColors.fgSubtle,
                          ),
                        ),
                        value: _reduceMotion,
                        onChanged: (v) => setState(() => _reduceMotion = v),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(S.cancel),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () async {
                      final a = context.read<AppState>();
                      await a.updateProviderSettings(
                        githubModelsApiKey: a.githubModelsApiKey,
                        githubModelsOrganization: a.githubModelsOrganization,
                        copilotApiKey: a.copilotApiKey,
                        copilotUseLoggedInUser: a.copilotUseLoggedInUser,
                        enabledProviders: _enabledProviders,
                        ollamaEndpoint: _ollamaEndpointCtrl.text,
                        ollamaApiKey: a.ollamaApiKey,
                        geminiApiKey: _geminiKeyCtrl.text,
                        anthropicApiKey: _claudeKeyCtrl.text,
                        openaiApiKey: _openaiKeyCtrl.text,
                      );
                      await a.updateEditorSettings(
                        theme: _theme,
                        fontSize: _fontSize,
                        tabSize: _tabSize,
                        wordWrap: _wordWrap,
                      );
                      await a.chat.setAutoApprove(_autoApprove);
                      await a.setReduceMotion(_reduceMotion);
                      await a.setReduceTransparency(_reduceTransparency);
                      if (!context.mounted) return;
                      showDuckToast(context, S.settingsSaved);
                      Navigator.pop(context);
                    },
                    child: const Text(S.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(String label) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(label, style: DuckTheme.titleS),
    );
  }
}
