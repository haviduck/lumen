import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

/// Second step in the new-project wizard (after Ollama): show every
/// LLM provider Lumen knows about with an enable toggle and (where
/// relevant) an API-key field. Designed for first-time users who
/// just installed Lumen and have nothing configured yet — repeat
/// users see this skipped automatically by the wizard's gating
/// heuristic.
///
/// State management is intentionally local: we read the current
/// values from `AppState` once on init, mutate the local copy as
/// the user types, and write everything back through
/// `AppState.updateProviderSettings` on Save. That mirrors the
/// pattern Settings → AI / Chat already uses, so the chat picker
/// reloads with the new providers immediately on dismiss.
///
/// Skip is always available — Lumen still works; the user just
/// has to configure providers manually in Settings later.
Future<void> showLlmProvidersSetupDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const _LlmProvidersSetupDialog(),
  );
}

class _LlmProvidersSetupDialog extends StatefulWidget {
  const _LlmProvidersSetupDialog();

  @override
  State<_LlmProvidersSetupDialog> createState() =>
      _LlmProvidersSetupDialogState();
}

class _LlmProvidersSetupDialogState extends State<_LlmProvidersSetupDialog> {
  // Local mirror of AppState's provider settings so cancelling
  // (Skip / barrier dismiss) doesn't accidentally persist edits.
  final Set<String> _enabled = <String>{};
  late final TextEditingController _ollamaEndpointCtrl;
  late final TextEditingController _ollamaApiKeyCtrl;
  late final TextEditingController _geminiCtrl;
  late final TextEditingController _claudeCtrl;
  late final TextEditingController _githubCtrl;
  late final TextEditingController _githubOrgCtrl;
  late final TextEditingController _copilotCtrl;
  late final TextEditingController _openaiCtrl;
  bool _copilotUseLoggedInUser = true;

  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final state = context.read<AppState>();
    _enabled.addAll(state.enabledProviders);
    _ollamaEndpointCtrl = TextEditingController(text: state.ollamaEndpoint);
    _ollamaApiKeyCtrl = TextEditingController(text: state.ollamaApiKey);
    _geminiCtrl = TextEditingController(text: state.geminiApiKey);
    _claudeCtrl = TextEditingController(text: state.anthropicApiKey);
    _githubCtrl = TextEditingController(text: state.githubModelsApiKey);
    _githubOrgCtrl = TextEditingController(
      text: state.githubModelsOrganization,
    );
    _copilotCtrl = TextEditingController(text: state.copilotApiKey);
    _copilotUseLoggedInUser = state.copilotUseLoggedInUser;
    _openaiCtrl = TextEditingController(text: state.openaiApiKey);
  }

  @override
  void dispose() {
    _ollamaEndpointCtrl.dispose();
    _ollamaApiKeyCtrl.dispose();
    _geminiCtrl.dispose();
    _claudeCtrl.dispose();
    _githubCtrl.dispose();
    _githubOrgCtrl.dispose();
    _copilotCtrl.dispose();
    _openaiCtrl.dispose();
    super.dispose();
  }

  void _toggle(String id, bool? v) {
    setState(() {
      if (v == true) {
        _enabled.add(id);
      } else {
        _enabled.remove(id);
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final state = context.read<AppState>();
    await state.updateProviderSettings(
      enabledProviders: _enabled.toSet(),
      ollamaEndpoint: _ollamaEndpointCtrl.text.trim(),
      ollamaApiKey: _ollamaApiKeyCtrl.text.trim(),
      geminiApiKey: _geminiCtrl.text.trim(),
      anthropicApiKey: _claudeCtrl.text.trim(),
      githubModelsApiKey: _githubCtrl.text.trim(),
      githubModelsOrganization: _githubOrgCtrl.text.trim(),
      copilotApiKey: _copilotCtrl.text.trim(),
      copilotUseLoggedInUser: _copilotUseLoggedInUser,
      openaiApiKey: _openaiCtrl.text.trim(),
    );
    if (!mounted) return;
    showDuckToast(context, S.llmProvidersSavedToast);
    Navigator.of(context).pop();
  }

  void _close() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 600,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Header(
                icon: Icons.power_outlined,
                title: S.llmProvidersTitle,
              ),
              const SizedBox(height: 12),
              const Text(
                S.llmProvidersBody,
                style: TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              // Capped vertical scroll so a small monitor doesn't
              // get a dialog taller than the viewport. The padding
              // value matches DuckGlass.hero's internal radius so
              // the scrollbar doesn't ride the edge.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ProviderCard(
                        id: 'Ollama',
                        label: S.providerOllama,
                        hint: S.llmProvidersOllamaHint,
                        enabled: _enabled.contains('Ollama'),
                        onToggle: (v) => _toggle('Ollama', v),
                        body: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _LabeledField(
                              label: S.llmProvidersOllamaEndpointLabel,
                              controller: _ollamaEndpointCtrl,
                              obscure: false,
                            ),
                            const SizedBox(height: 8),
                            _LabeledField(
                              label: S.llmProvidersOllamaCloudKeyLabel,
                              controller: _ollamaApiKeyCtrl,
                              obscure: true,
                              hintText: S.llmProvidersOllamaCloudKeyHint,
                            ),
                          ],
                        ),
                      ),
                      _ProviderCard(
                        id: 'Gemini',
                        label: S.providerGemini,
                        hint: S.llmProvidersGeminiHint,
                        enabled: _enabled.contains('Gemini'),
                        onToggle: (v) => _toggle('Gemini', v),
                        body: _ApiKeyField(controller: _geminiCtrl),
                      ),
                      _ProviderCard(
                        id: 'Claude',
                        label: S.providerClaude,
                        hint: S.llmProvidersClaudeHint,
                        enabled: _enabled.contains('Claude'),
                        onToggle: (v) => _toggle('Claude', v),
                        body: _ApiKeyField(controller: _claudeCtrl),
                      ),
                      _ProviderCard(
                        id: 'GitHub Models',
                        label: S.providerGithub,
                        hint: S.llmProvidersGithubHint,
                        enabled: _enabled.contains('GitHub Models'),
                        onToggle: (v) => _toggle('GitHub Models', v),
                        body: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _ApiKeyField(controller: _githubCtrl),
                            const SizedBox(height: 8),
                            _LabeledField(
                              label: S.settingsGithubOrgLabel,
                              controller: _githubOrgCtrl,
                              obscure: false,
                              hintText: S.settingsGithubOrgHint,
                            ),
                          ],
                        ),
                      ),
                      _ProviderCard(
                        id: 'GitHub Copilot',
                        label: S.providerCopilot,
                        hint: S.llmProvidersCopilotHint,
                        enabled: _enabled.contains('GitHub Copilot'),
                        onToggle: (v) => _toggle('GitHub Copilot', v),
                        body: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _ApiKeyField(controller: _copilotCtrl),
                            const SizedBox(height: 8),
                            SwitchListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                S.llmProvidersCopilotUseLoggedIn,
                                style: TextStyle(fontSize: 12),
                              ),
                              value: _copilotUseLoggedInUser,
                              onChanged: (v) =>
                                  setState(() => _copilotUseLoggedInUser = v),
                              activeThumbColor: DuckColors.accentCyan,
                            ),
                          ],
                        ),
                      ),
                      _ProviderCard(
                        id: 'OpenAI',
                        label: S.providerOpenAI,
                        hint: S.llmProvidersOpenaiHint,
                        enabled: _enabled.contains('OpenAI'),
                        onToggle: (v) => _toggle('OpenAI', v),
                        body: _ApiKeyField(controller: _openaiCtrl),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : _close,
                    style: TextButton.styleFrom(
                      foregroundColor: DuckColors.fgMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: const Text(S.llmProvidersSkip),
                  ),
                  const SizedBox(width: 6),
                  ElevatedButton.icon(
                    icon: _saving
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: DuckColors.bgDeepest,
                            ),
                          )
                        : const Icon(Icons.check, size: 16),
                    label: const Text(S.llmProvidersSave),
                    onPressed: _saving ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DuckColors.accentCyan,
                      foregroundColor: DuckColors.bgDeepest,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      ),
                      textStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderCard extends StatelessWidget {
  final String id;
  final String label;
  final String hint;
  final bool enabled;
  final ValueChanged<bool?> onToggle;
  final Widget body;

  const _ProviderCard({
    required this.id,
    required this.label,
    required this.hint,
    required this.enabled,
    required this.onToggle,
    required this.body,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(
          color: enabled ? DuckColors.accentCyan : DuckColors.glassSeam,
          width: enabled ? 1 : 0.5,
        ),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Checkbox(
                value: enabled,
                onChanged: onToggle,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                activeColor: DuckColors.accentCyan,
                checkColor: DuckColors.bgDeepest,
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.only(left: 32, bottom: 8),
            child: Text(
              hint,
              style: const TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgSubtle,
                height: 1.4,
              ),
            ),
          ),
          // The body fades a touch when the provider is disabled so
          // the user understands that fields are still editable but
          // not currently active.
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 140),
              opacity: enabled ? 1.0 : 0.6,
              child: body,
            ),
          ),
        ],
      ),
    );
  }
}

class _ApiKeyField extends StatelessWidget {
  final TextEditingController controller;
  const _ApiKeyField({required this.controller});

  @override
  Widget build(BuildContext context) {
    return _LabeledField(
      label: S.settingsApiKey,
      controller: controller,
      obscure: true,
    );
  }
}

class _LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final bool obscure;
  final String? hintText;
  const _LabeledField({
    required this.label,
    required this.controller,
    required this.obscure,
    this.hintText,
  });

  @override
  Widget build(BuildContext context) {
    final hadValueOnInit = controller.text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          // Tag pre-existing values so users editing this dialog
          // know the field already has something stored. Helpful
          // because we obscure API keys — a blank-looking field
          // could be misread as "nothing saved here".
          hadValueOnInit ? '$label${S.llmProvidersAlreadySetSuffix}' : label,
          style: const TextStyle(
            fontSize: 11,
            letterSpacing: 0.4,
            color: DuckColors.fgSubtle,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: false,
          style: const TextStyle(fontSize: 12.5, color: DuckColors.fgPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: hintText ?? S.llmProvidersApiKeyHint,
            hintStyle: const TextStyle(fontSize: 12, color: DuckColors.fgFaint),
            filled: true,
            fillColor: DuckColors.bgRaised,
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 10,
              vertical: 8,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              borderSide: const BorderSide(
                color: DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              borderSide: const BorderSide(
                color: DuckColors.glassSeam,
                width: 0.5,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              borderSide: const BorderSide(
                color: DuckColors.accentCyan,
                width: 1,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  final IconData icon;
  final String title;
  const _Header({required this.icon, required this.title});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: DuckColors.accentCyan),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
        ),
      ],
    );
  }
}
