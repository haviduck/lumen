import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../services/skill_generator.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

/// Skill-generator UX. Three states the dialog cycles through:
///
/// 1. **Offer** — initial. Explains what skills are and asks
///    "generate or skip?". If the LLM probe fails immediately we
///    flip to the no-LLM informational variant instead.
/// 2. **Generating** — busy spinner with phase label
///    ("checking LLM" → "analyzing project" → "generating skills").
/// 3. **Result** — shows the list of created tool ids + any
///    rejection reasons + a Done button. Errors flow through the
///    same surface with the error message in red.
///
/// Only fires automatically right after the welcome screen creates a
/// new project. The path-arg is the workspace root that just got
/// created — needed because the skill generator writes into
/// `<workspace>/.lumen/tools/`.
///
/// Returns when the user dismisses (Skip on offer, Done on result,
/// or barrier-dismiss). Doesn't block the new project from opening.
Future<void> showSkillGeneratorDialog(
  BuildContext context, {
  required String workspacePath,
}) async {
  await showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    builder: (ctx) => _SkillGeneratorDialog(workspacePath: workspacePath),
  );
}

/// Dialog steps. `offering` is the welcome / pitch screen.
/// `configuring` is the new questionnaire — project archetype chips +
/// optional free-text. We chose chips over a single dropdown so the
/// user can express the common "this is a dashboard backed by an
/// API" case (multi-select), and over a dialog hierarchy so the
/// answer is always 1 click + an optional sentence.
enum _DialogPhase { offering, configuring, checking, generating, result, noLlm }

class _SkillGeneratorDialog extends StatefulWidget {
  final String workspacePath;
  const _SkillGeneratorDialog({required this.workspacePath});

  @override
  State<_SkillGeneratorDialog> createState() => _SkillGeneratorDialogState();
}

class _SkillGeneratorDialogState extends State<_SkillGeneratorDialog> {
  _DialogPhase _phase = _DialogPhase.offering;
  String _busyLabel = '';
  SkillGenerationResult? _result;

  /// User-picked archetypes from the configuration screen. Plural —
  /// see SkillProjectKind for the matrix and why multi-select wins.
  final Set<SkillProjectKind> _selectedKinds = <SkillProjectKind>{};

  /// Free-text "anything else worth knowing?" hint. Threaded into
  /// the LLM prompt as `ADDITIONAL CONTEXT FROM USER`.
  final TextEditingController _extraCtrl = TextEditingController();

  @override
  void dispose() {
    _extraCtrl.dispose();
    super.dispose();
  }

  Future<void> _startGenerate() async {
    setState(() {
      _phase = _DialogPhase.checking;
      _busyLabel = S.skillsCheckingLlm;
    });

    final appState = context.read<AppState>();
    final reachable = await appState.chat.isReachable();
    if (!mounted) return;

    if (!reachable) {
      setState(() => _phase = _DialogPhase.noLlm);
      return;
    }

    final gen = SkillGenerator(
      generateChat: appState.chat.generateUtilityText,
      isReadyCheck: appState.chat.isReachable,
      model: appState.chat.selectedModel,
    );

    setState(() {
      _phase = _DialogPhase.generating;
      _busyLabel = S.skillsAnalyzing;
    });

    // Tiny pause so the "analyzing" label is actually visible — the
    // LLM call itself takes seconds, but if the project is empty
    // the analysis half is sub-frame and looks like a flicker.
    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) return;
    setState(() => _busyLabel = S.skillsGenerating);

    final result = await gen.generate(
      widget.workspacePath,
      kinds: _selectedKinds.toList(),
      extraContext: _extraCtrl.text,
    );
    if (!mounted) return;

    if (result.createdTools.isNotEmpty || result.createdSkills.isNotEmpty) {
      // Reload runtime tools and skills so the agent picks them up
      // immediately on the next prompt — no workspace re-open needed.
      try {
        if (result.createdTools.isNotEmpty) {
          await appState.chat.reloadExternalTools(widget.workspacePath);
        }
        if (result.createdSkills.isNotEmpty) {
          await appState.workspaceSkills.reload(widget.workspacePath);
        }
      } catch (_) {}
      if (!mounted) return;
      final tools = result.createdTools.length;
      final skills = result.createdSkills.length;
      final parts = <String>[];
      if (tools > 0) parts.add('$tools tool${tools == 1 ? '' : 's'}');
      if (skills > 0) parts.add('$skills skill${skills == 1 ? '' : 's'}');
      showDuckToast(context, '${parts.join(' + ')} ready in .lumen/.');
    }

    setState(() {
      _phase = _DialogPhase.result;
      _result = result;
    });
  }

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
          child: switch (_phase) {
            _DialogPhase.offering => _buildOffer(),
            _DialogPhase.configuring => _buildConfigure(),
            _DialogPhase.checking || _DialogPhase.generating => _buildBusy(),
            _DialogPhase.noLlm => _buildNoLlm(),
            _DialogPhase.result => _buildResult(_result!),
          },
        ),
      ),
    );
  }

  Widget _buildOffer() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(icon: Icons.auto_awesome, title: S.skillsTitle),
        const SizedBox(height: 12),
        const Text(
          S.skillsBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: DuckColors.fgMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              child: const Text(S.skillsSkip),
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              icon: const Icon(Icons.arrow_forward, size: 16),
              label: const Text(S.skillsContinue),
              // From the offer screen we move to the configuration
              // step (project-type chips + free-text). Generation
              // doesn't kick off until the user clicks Generate
              // there — gives them control over what archetypes
              // bias the model.
              onPressed: () =>
                  setState(() => _phase = _DialogPhase.configuring),
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
    );
  }

  Widget _buildConfigure() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(icon: Icons.tune, title: S.skillsConfigureTitle),
        const SizedBox(height: 10),
        const Text(
          S.skillsConfigureBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 14),
        // Chip grid — multi-select. Wrapping naturally so the dialog
        // doesn't grow horizontally for users who pick a wide stack.
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: SkillProjectKind.values.map((k) {
            final selected = _selectedKinds.contains(k);
            return _KindChip(
              label: k.label,
              selected: selected,
              onTap: () {
                setState(() {
                  if (selected) {
                    _selectedKinds.remove(k);
                  } else {
                    _selectedKinds.add(k);
                  }
                });
              },
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        const Text(
          S.skillsExtraContextLabel,
          style: TextStyle(
            fontSize: 11,
            letterSpacing: 0.6,
            color: DuckColors.fgSubtle,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        TextField(
          controller: _extraCtrl,
          maxLines: 3,
          minLines: 2,
          style: const TextStyle(fontSize: 12.5, color: DuckColors.fgPrimary),
          decoration: InputDecoration(
            isDense: true,
            hintText: S.skillsExtraContextHint,
            hintStyle: const TextStyle(fontSize: 12, color: DuckColors.fgFaint),
            filled: true,
            fillColor: DuckColors.bgChip,
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
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: DuckColors.fgMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              child: const Text(S.skillsSkip),
            ),
            const SizedBox(width: 6),
            ElevatedButton.icon(
              icon: const Icon(Icons.bolt, size: 18),
              label: const Text(S.skillsGenerate),
              // No archetype is allowed — we pass `unknown` and let
              // the model pick from manifest signals only. Worse
              // results than with hints, but better than the user
              // bouncing off a forced-choice screen.
              onPressed: _startGenerate,
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
    );
  }

  Widget _buildBusy() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        const _DialogHeader(icon: Icons.auto_awesome, title: S.skillsTitle),
        const SizedBox(height: 18),
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: DuckColors.accentCyan,
          ),
        ),
        const SizedBox(height: 14),
        Text(
          _busyLabel,
          style: const TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 6),
      ],
    );
  }

  Widget _buildNoLlm() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _DialogHeader(
          icon: Icons.cloud_off_outlined,
          title: S.skillsNoLlmTitle,
        ),
        const SizedBox(height: 12),
        const Text(
          S.skillsNoLlmBody,
          style: TextStyle(
            fontSize: 12.5,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              style: TextButton.styleFrom(
                foregroundColor: DuckColors.fgMuted,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
              child: const Text(S.ok),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildResult(SkillGenerationResult result) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _DialogHeader(
          icon: result.ok ? Icons.check_circle_outline : Icons.error_outline,
          title: result.ok ? S.skillsCreatedHeader : S.skillsErrorHeader,
          accent: result.ok ? DuckColors.accentMint : DuckColors.stateError,
        ),
        const SizedBox(height: 12),
        if (result.error != null) ...[
          Text(
            result.error!,
            style: const TextStyle(
              fontSize: 12.5,
              color: DuckColors.fgMuted,
              height: 1.5,
            ),
          ),
          if (result.rawSnippet != null) ...[
            const SizedBox(height: 12),
            _RawSnippetBox(snippet: result.rawSnippet!),
          ],
        ] else ...[
          if (result.createdTools.isNotEmpty) ...[
            _CreatedKindLabel(
              icon: Icons.terminal,
              label: 'Tools (.lumen/tools/*.json)',
              accent: DuckColors.accentCyan,
            ),
            ...result.createdTools.map(
              (id) => _CreatedRow(id: id, accent: DuckColors.accentCyan),
            ),
          ],
          if (result.createdSkills.isNotEmpty) ...[
            if (result.createdTools.isNotEmpty) const SizedBox(height: 8),
            _CreatedKindLabel(
              icon: Icons.menu_book_outlined,
              label: 'Skills (.lumen/skills/*.md)',
              accent: DuckColors.accentMint,
            ),
            ...result.createdSkills.map(
              (id) => _CreatedRow(id: id, accent: DuckColors.accentMint),
            ),
          ],
        ],
        if (result.rejected.isNotEmpty) ...[
          const SizedBox(height: 14),
          const Text(
            S.skillsRejectedHeader,
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.6,
              color: DuckColors.fgSubtle,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          ...result.rejected.map(
            (entry) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Text(
                '• $entry',
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgFaint,
                  fontFamily: DuckTheme.monoFont,
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 18),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (result.error != null) ...[
              TextButton(
                onPressed: _startGenerate,
                style: TextButton.styleFrom(
                  foregroundColor: DuckColors.accentCyan,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                ),
                child: const Text(S.skillsRetry),
              ),
              const SizedBox(width: 6),
            ],
            ElevatedButton(
              onPressed: () => Navigator.of(context).pop(),
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
              child: const Text(S.skillsDone),
            ),
          ],
        ),
      ],
    );
  }
}

class _DialogHeader extends StatelessWidget {
  final IconData icon;
  final String title;
  final Color accent;
  const _DialogHeader({
    required this.icon,
    required this.title,
    this.accent = DuckColors.accentCyan,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: accent),
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

/// Chip used in the configuration step. Selected state uses the
/// cyan-accent fill matching the rest of the dialog's "active /
/// primary" affordances; unselected has a faint outline so the chips
/// don't look like buttons before the user touches them.
class _KindChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _KindChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: selected
                ? DuckColors.accentCyan.withValues(alpha: 0.18)
                : DuckColors.bgChip,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected ? DuckColors.accentCyan : DuckColors.glassSeam,
              width: selected ? 1 : 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: selected ? DuckColors.accentCyan : DuckColors.fgPrimary,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _CreatedKindLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color accent;
  const _CreatedKindLabel({
    required this.icon,
    required this.label,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 4),
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

class _CreatedRow extends StatelessWidget {
  final String id;
  final Color accent;
  const _CreatedRow({required this.id, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1.5),
      child: Row(
        children: [
          Icon(Icons.check, size: 14, color: accent),
          const SizedBox(width: 8),
          Text(
            id,
            style: const TextStyle(
              fontSize: 12.5,
              color: DuckColors.fgPrimary,
              fontFamily: DuckTheme.monoFont,
            ),
          ),
        ],
      ),
    );
  }
}

class _RawSnippetBox extends StatelessWidget {
  final String snippet;
  const _RawSnippetBox({required this.snippet});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: SingleChildScrollView(
        child: Text(
          snippet,
          style: const TextStyle(
            fontFamily: DuckTheme.monoFont,
            fontSize: 11,
            color: DuckColors.fgSubtle,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
