import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/skill_generator.dart';
import '../services/skill_model_picker.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

Future<void> showManualSkillDialog(BuildContext context) async {
  final workspace = context.read<AppState>().currentDirectory;
  if (workspace == null) {
    showDuckToast(context, S.manualSkillNoWorkspace);
    return;
  }
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (_) => _ManualSkillDialog(workspacePath: workspace),
  );
}

enum _ManualSkillPhase { form, generating, result, noLlm }

class _ManualSkillDialog extends StatefulWidget {
  final String workspacePath;
  const _ManualSkillDialog({required this.workspacePath});

  @override
  State<_ManualSkillDialog> createState() => _ManualSkillDialogState();
}

class _ManualSkillDialogState extends State<_ManualSkillDialog> {
  final _ideaCtrl = TextEditingController();
  final _detailsCtrl = TextEditingController();
  _ManualSkillPhase _phase = _ManualSkillPhase.form;
  SkillGenerationResult? _result;

  @override
  void dispose() {
    _ideaCtrl.dispose();
    _detailsCtrl.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final idea = _ideaCtrl.text.trim();
    if (idea.isEmpty) return;

    setState(() => _phase = _ManualSkillPhase.generating);
    final appState = context.read<AppState>();
    if (!await appState.chat.isReachable()) {
      if (!mounted) return;
      setState(() => _phase = _ManualSkillPhase.noLlm);
      return;
    }

    // Force a frontier cloud model when an Ollama Cloud key is set
    // (same rule the new-project wizard uses — see
    // [pickSkillModel] for the full rationale). Skill generation
    // is one-off JSON work; the chat-streaming model is rarely
    // the right choice here.
    final pickedModel = await pickSkillModel(appState);
    if (!mounted) return;

    final gen = SkillGenerator(
      generateChat: appState.chat.generateUtilityText,
      isReadyCheck: appState.chat.isReachable,
      model: pickedModel,
    );
    final result = await gen.generateCustom(
      widget.workspacePath,
      request: CustomSkillRequest(name: idea, details: _detailsCtrl.text),
    );
    if (!mounted) return;

    if (result.createdTools.isNotEmpty || result.createdSkills.isNotEmpty) {
      // Refresh both runtimes — tools reload from `.lumen/tools/`,
      // skills reload from `.lumen/skills/` and re-compile into the
      // next system prompt.
      if (result.createdTools.isNotEmpty) {
        await appState.chat.reloadExternalTools(
          widget.workspacePath,
          force: true,
        );
      }
      if (result.createdSkills.isNotEmpty) {
        await appState.workspaceSkills.reload(widget.workspacePath);
      }
      if (!mounted) return;
      showDuckToast(context, _summaryToast(result));
    }
    setState(() {
      _result = result;
      _phase = _ManualSkillPhase.result;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 600,
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
          child: switch (_phase) {
            _ManualSkillPhase.form => _buildForm(),
            _ManualSkillPhase.generating => _buildBusy(),
            _ManualSkillPhase.noLlm => _buildNoLlm(),
            _ManualSkillPhase.result => _buildResult(_result!),
          },
        ),
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(),
        const SizedBox(height: 12),
        const Text(
          S.manualSkillIntro,
          style: TextStyle(
            color: DuckColors.fgMuted,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        _Field(
          label: S.manualSkillName,
          child: _TextBox(controller: _ideaCtrl, hint: S.manualSkillNameHint),
        ),
        _Field(
          label: S.manualSkillDetails,
          child: _TextBox(
            controller: _detailsCtrl,
            hint: S.manualSkillDetailsHint,
            maxLines: 5,
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(S.cancel),
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.auto_awesome, size: 16),
              label: const Text(S.manualSkillCreate),
              onPressed: _create,
              style: ElevatedButton.styleFrom(
                backgroundColor: DuckColors.accentCyan,
                foregroundColor: DuckColors.bgDeepest,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildBusy() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(),
        SizedBox(height: 22),
        CircularProgressIndicator(color: DuckColors.accentCyan),
        SizedBox(height: 14),
        Text(S.skillsGenerating, style: TextStyle(color: DuckColors.fgMuted)),
      ],
    );
  }

  Widget _buildNoLlm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _Header(icon: Icons.cloud_off_outlined),
        const SizedBox(height: 12),
        const Text(
          S.skillsNoLlmBody,
          style: TextStyle(
            color: DuckColors.fgMuted,
            fontSize: 12.5,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(S.ok),
          ),
        ),
      ],
    );
  }

  Widget _buildResult(SkillGenerationResult result) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: result.ok ? Icons.check_circle_outline : Icons.error_outline,
          accent: result.ok ? DuckColors.accentMint : DuckColors.stateError,
        ),
        const SizedBox(height: 14),
        if (result.error != null)
          Text(result.error!, style: const TextStyle(color: DuckColors.fgMuted))
        else ...[
          if (result.createdTools.isNotEmpty) ...[
            const _CreatedSubheader(
              label: 'Tools (.lumen/tools/*.json)',
              accent: DuckColors.accentCyan,
              icon: Icons.terminal,
            ),
            ...result.createdTools.map(
              (id) => Text(
                id,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontFamily: DuckTheme.monoFont,
                ),
              ),
            ),
          ],
          if (result.createdSkills.isNotEmpty) ...[
            if (result.createdTools.isNotEmpty) const SizedBox(height: 10),
            const _CreatedSubheader(
              label: 'Skills (.lumen/skills/*.md)',
              accent: DuckColors.accentMint,
              icon: Icons.menu_book_outlined,
            ),
            ...result.createdSkills.map(
              (id) => Text(
                id,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontFamily: DuckTheme.monoFont,
                ),
              ),
            ),
          ],
        ],
        if (result.rejected.isNotEmpty) ...[
          const SizedBox(height: 10),
          ...result.rejected.map(
            (r) => Text(
              '- $r',
              style: const TextStyle(
                color: DuckColors.fgSubtle,
                fontSize: 11,
                fontFamily: DuckTheme.monoFont,
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(S.skillsDone),
          ),
        ),
      ],
    );
  }

  String _summaryToast(SkillGenerationResult result) {
    final tools = result.createdTools.length;
    final skills = result.createdSkills.length;
    final parts = <String>[];
    if (tools > 0) parts.add('$tools tool${tools == 1 ? '' : 's'}');
    if (skills > 0) parts.add('$skills skill${skills == 1 ? '' : 's'}');
    if (parts.isEmpty) return 'Nothing created.';
    return '${parts.join(' + ')} ready in .lumen/.';
  }
}

class _CreatedSubheader extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color accent;
  const _CreatedSubheader({
    required this.label,
    required this.icon,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4, top: 2),
      child: Row(
        children: [
          Icon(icon, size: 12, color: accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              color: accent,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final IconData icon;
  final Color accent;
  const _Header({
    this.icon = Icons.auto_awesome,
    this.accent = DuckColors.accentCyan,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: accent),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            S.manualSkillTitle,
            style: TextStyle(
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

class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  const _Field({required this.label, required this.child});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.7,
              color: DuckColors.fgSubtle,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 5),
          child,
        ],
      ),
    );
  }
}

class _TextBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final int maxLines;
  const _TextBox({
    required this.controller,
    required this.hint,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
      style: const TextStyle(color: DuckColors.fgPrimary, fontSize: 12.5),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: DuckColors.fgFaint, fontSize: 12),
        filled: true,
        fillColor: DuckColors.bgChip,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          borderSide: const BorderSide(color: DuckColors.accentCyan),
        ),
      ),
    );
  }
}
