import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

/// Focused, single-purpose dialog that asks the user to paste an
/// Ollama Cloud API key right before the new-project wizard runs the
/// skill generator.
///
/// **Why a dedicated step.** The broader [showLlmProvidersSetupDialog]
/// covers all four providers (Ollama / Gemini / Claude / GitHub) on
/// first run. This narrower prompt fires when the only thing the
/// wizard needs *for the next step* is a strong cloud model: the
/// skill generator works dramatically better with frontier-tier
/// models like Qwen 3 Coder 480B, and pasting an Ollama Cloud key is
/// the single fastest path to one. Keeping this prompt scoped to one
/// field + two buttons matches its single intent — "do you have an
/// Ollama Cloud key for skill generation, yes/no/skip?" — and keeps
/// the cognitive load far below the full provider grid.
///
/// Scope rules (enforced by the caller, not this dialog):
///   - Fired only from the new-project wizard.
///   - Only when [AppState.ollamaApiKey] is empty.
///   - Only on first-run installations (no other provider configured).
///     If the user has Gemini/Claude/etc. set already, the wizard
///     skips this prompt and the skill generator falls back to their
///     [AppState.chat.selectedModel] — that path is handled by the
///     skill-model picker, not by this widget.
///
/// **Persistence.** A pasted key flows through
/// [AppState.updateProviderSettings] using the *current* values for
/// every other field, so the rest of the provider config (any
/// pre-existing endpoint / Gemini / etc.) survives untouched. Skip
/// is non-destructive — closes the dialog and leaves AppState alone.
Future<void> showOllamaCloudKeyPromptDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => const _OllamaCloudKeyPromptDialog(),
  );
}

class _OllamaCloudKeyPromptDialog extends StatefulWidget {
  const _OllamaCloudKeyPromptDialog();

  @override
  State<_OllamaCloudKeyPromptDialog> createState() =>
      _OllamaCloudKeyPromptDialogState();
}

class _OllamaCloudKeyPromptDialogState
    extends State<_OllamaCloudKeyPromptDialog> {
  final TextEditingController _keyCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _keyCtrl.dispose();
    super.dispose();
  }

  Future<void> _useKey() async {
    final key = _keyCtrl.text.trim();
    if (key.isEmpty || _saving) return;
    setState(() => _saving = true);

    final state = context.read<AppState>();
    // Pass-through every other provider field so we don't clobber
    // settings the user might have configured earlier in the same
    // session (e.g. ollamaEndpoint pointing at a remote daemon).
    await state.updateProviderSettings(
      enabledProviders: state.enabledProviders.toSet(),
      ollamaEndpoint: state.ollamaEndpoint,
      ollamaApiKey: key,
      geminiApiKey: state.geminiApiKey,
      anthropicApiKey: state.anthropicApiKey,
      githubModelsApiKey: state.githubModelsApiKey,
      githubModelsOrganization: state.githubModelsOrganization,
      copilotApiKey: state.copilotApiKey,
      copilotUseLoggedInUser: state.copilotUseLoggedInUser,
      openaiApiKey: state.openaiApiKey,
    );
    if (!mounted) return;
    showDuckToast(context, S.ollamaCloudKeySavedToast);
    Navigator.of(context).pop();
  }

  void _skip() => Navigator.of(context).pop();

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 540,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.cloud_outlined,
                    size: 18,
                    color: DuckColors.accentCyan,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      S.ollamaCloudKeyPromptTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              const Text(
                S.ollamaCloudKeyPromptBody,
                style: TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                S.ollamaCloudKeyPromptFieldLabel,
                style: TextStyle(
                  fontSize: 11,
                  letterSpacing: 0.6,
                  color: DuckColors.fgSubtle,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 6),
              TextField(
                controller: _keyCtrl,
                obscureText: true,
                autofocus: true,
                onSubmitted: (_) => _useKey(),
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 12.5,
                  fontFamily: DuckTheme.monoFont,
                ),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: S.ollamaCloudKeyPromptFieldHint,
                  hintStyle: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgFaint,
                  ),
                  filled: true,
                  fillColor: DuckColors.bgChip,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
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
              const SizedBox(height: 8),
              const Text(
                S.ollamaCloudKeyPromptHelper,
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgFaint,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _saving ? null : _skip,
                    style: TextButton.styleFrom(
                      foregroundColor: DuckColors.fgMuted,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                    ),
                    child: const Text(S.ollamaCloudKeyPromptSkip),
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
                    label: const Text(S.ollamaCloudKeyPromptUse),
                    onPressed: _saving ? null : _useKey,
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
