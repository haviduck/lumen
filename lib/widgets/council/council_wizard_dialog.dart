import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../common/duck_toast.dart';
import 'council_paste_field.dart';
import 'wizard/wizard_agent_card.dart';
import 'wizard/wizard_tokens.dart';

/// Convene-the-Council modal.
///
/// 2026-05 redesign back to a focused step wizard. Two steps
/// (Brief → Team) with a calm step indicator and a per-step content
/// area. The council is triggered directly from the Team step.
Future<void> showCouncilWizard(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, a, b) => const CouncilWizardDialog(),
    transitionBuilder: (_, anim, b, child) {
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: Transform.translate(
          offset: Offset(0, (1 - curved.value) * 12),
          child: Transform.scale(
            scale: 0.98 + (0.02 * curved.value),
            child: child,
          ),
        ),
      );
    },
  );
}

const int _stepBrief = 0;
const int _stepTeam = 1;
const int _stepCount = 2;

class CouncilWizardDialog extends StatefulWidget {
  const CouncilWizardDialog({super.key});

  @override
  State<CouncilWizardDialog> createState() => _CouncilWizardDialogState();
}

class _CouncilWizardDialogState extends State<CouncilWizardDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _brief = TextEditingController();
  final CouncilPasteAttachments _images = CouncilPasteAttachments();
  final _ConveneDocs _docs = _ConveneDocs();
  final ScrollController _scroll = ScrollController();
  bool _loadedLastConfig = false;
  bool _lazyGenerating = false;
  bool _dropHover = false;
  int _step = _stepBrief;
  late List<_DraftAgent> _agents;
  late _DraftAgent _orchestrator;

  @override
  void initState() {
    super.initState();
    _agents = [
      _DraftAgent(name: S.councilRolePentester, role: RolePreset.pentester),
      _DraftAgent(name: S.councilRoleReviewer, role: RolePreset.reviewer),
      _DraftAgent(name: S.councilRoleArchitect, role: RolePreset.architect),
      _DraftAgent(name: S.councilRoleTester, role: RolePreset.tester),
    ];
    _orchestrator = _DraftAgent(
      name: S.councilOrchestrator,
      role: RolePreset.architect,
    );
    _title.addListener(_refresh);
    _brief.addListener(_refresh);
    _images.addListener(_refresh);
    _docs.addListener(_refresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedLastConfig) return;
    _loadedLastConfig = true;
    _loadLastConfig();
  }

  @override
  void dispose() {
    _title.dispose();
    _brief.dispose();
    _images.dispose();
    _docs.dispose();
    _scroll.dispose();
    for (final agent in _agents) {
      agent.dispose();
    }
    _orchestrator.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  Future<void> _loadLastConfig() async {
    final raw = await context.read<AppState>().prefs.getCouncilLastConfigJson();
    if (raw.trim().isEmpty || !mounted) return;
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      _title.text = json['title'] as String? ?? '';
      // Intentionally NOT restoring `brief`: the user's complaint was
      // that every time the modal opens the previous brief is sitting
      // there. Title / agents / orchestrator pick are sticky UX (saves
      // retyping the same team name); the brief is per-session intent
      // and must start blank on every open.
      final agents = (json['agents'] as List?) ?? const [];
      final loadedAgents = agents
          .whereType<Map>()
          .map((a) => _DraftAgent.fromJson(a.cast<String, dynamic>()))
          .toList();
      final orchestrator = json['orchestrator'] is Map
          ? _DraftAgent.fromJson(
              (json['orchestrator'] as Map).cast<String, dynamic>(),
            )
          : null;
      setState(() {
        if (loadedAgents.length >= 2) {
          for (final agent in _agents) {
            agent.dispose();
          }
          _agents = loadedAgents;
        }
        if (orchestrator != null) {
          _orchestrator.dispose();
          _orchestrator = orchestrator;
        }
      });
    } catch (_) {
      // Ignore stale drafts; the wizard defaults are always usable.
    }
  }

  bool _stepValid(int step, List<String> models) {
    switch (step) {
      case _stepBrief:
        return models.isNotEmpty && _brief.text.trim().isNotEmpty;
      case _stepTeam:
        return _agents.length >= 2;
      default:
        return true;
    }
  }

  void _goNext() {
    if (_step >= _stepCount - 1) return;
    setState(() => _step++);
    _scrollToTop();
  }

  void _goBack() {
    if (_step <= 0) return;
    setState(() => _step--);
    _scrollToTop();
  }

  void _scrollToTop() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final models = appState.chat.availableModels.toList()..sort();
    for (final agent in [..._agents, _orchestrator]) {
      agent.model ??= models.isEmpty ? null : models.first;
    }

    final canStart = models.isNotEmpty &&
        _brief.text.trim().isNotEmpty &&
        _agents.length >= 2 &&
        !_lazyGenerating;
    final canAdvance = _stepValid(_step, models) && !_lazyGenerating;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 660),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Material(
            color: Colors.transparent,
            child: DropTarget(
              onDragEntered: (_) => setState(() => _dropHover = true),
              onDragExited: (_) => setState(() => _dropHover = false),
              onDragDone: (detail) async {
                setState(() => _dropHover = false);
                for (final f in detail.files) {
                  await _ingestDroppedFile(f.path);
                }
              },
              child: _Sheet(
                dropHover: _dropHover,
                child: Column(
                  children: [
                    _Header(
                      onClose: () => Navigator.of(context).pop(),
                      models: models,
                      selectedModel: _orchestrator.model,
                      onModelChanged: (m) => _applyModelToAll(m),
                    ),
                    _StepIndicator(step: _step),
                    if (models.isEmpty) const _GateBanner(),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 200),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, anim) {
                          return FadeTransition(
                            opacity: anim,
                            child: SlideTransition(
                              position: Tween<Offset>(
                                begin: const Offset(0.04, 0),
                                end: Offset.zero,
                              ).animate(anim),
                              child: child,
                            ),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey(_step),
                          child: Scrollbar(
                            controller: _scroll,
                            thumbVisibility: false,
                            child: SingleChildScrollView(
                              controller: _scroll,
                              padding: const EdgeInsets.fromLTRB(
                                WizardTokens.s24,
                                WizardTokens.s18,
                                WizardTokens.s24,
                                WizardTokens.s18,
                              ),
                              child: switch (_step) {
                                _stepBrief => _BriefStep(
                                    title: _title,
                                    brief: _brief,
                                    images: _images,
                                    docs: _docs,
                                    dropHover: _dropHover,
                                    onPickDocs: _pickDocs,
                                  ),
                                _stepTeam => _TeamStep(
                                    orchestrator: _orchestrator,
                                    agents: _agents,
                                    models: models,
                                    onChanged: () => setState(() {}),
                                    onAddAgent: _addAgent,
                                    onRemoveAgent: _removeAgent,
                                  ),
                                _ => const SizedBox.shrink(),
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                    _Footer(
                      step: _step,
                      stepCount: _stepCount,
                      canAdvance: canAdvance,
                      canStart: canStart,
                      isGenerating: _lazyGenerating,
                      onCancel: () => Navigator.of(context).pop(),
                      onBack: _step == 0 ? null : _goBack,
                      onNext: _step >= _stepCount - 1
                          ? null
                          : _step == _stepBrief
                              ? () => _generateLazyRoster(models)
                              : _goNext,
                      onStart: () => _start(appState),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _applyModelToAll(String model) {
    setState(() {
      _orchestrator.model = model;
      for (final agent in _agents) {
        agent.model = model;
      }
    });
  }

  void _addAgent() {
    setState(() {
      _agents.add(
        _DraftAgent(
          name: '${S.councilRoleResearcher} ${_agents.length + 1}',
          role: RolePreset.researcher,
        ),
      );
    });
  }

  void _removeAgent(int index) {
    if (index < 0 || index >= _agents.length) return;
    setState(() {
      _agents[index].dispose();
      _agents.removeAt(index);
    });
  }

  Future<void> _generateLazyRoster(List<String> models) async {
    if (_lazyGenerating || models.isEmpty || _brief.text.trim().isEmpty) {
      return;
    }
    _orchestrator.model ??= models.first;
    setState(() => _lazyGenerating = true);
    final appState = context.read<AppState>();
    try {
      final proposed = await appState.council.proposeAgentsForBrief(
        brief: _brief.text.trim(),
        orchestrator: _orchestrator.toAgent('orchestrator'),
      );
      if (!mounted) return;
      setState(() {
        for (final agent in _agents) {
          agent.dispose();
        }
        _agents = proposed.map(_DraftAgent.fromAgent).toList();
        _step = _stepTeam;
      });
      _scrollToTop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(S.councilLazyModeDone)));
    } catch (_) {
      if (!mounted) return;
      // Advance to Team anyway with the existing default roster so
      // the user is never stuck on the Brief step.
      setState(() => _step = _stepTeam);
      _scrollToTop();
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(S.councilLazyModeFailed)));
    } finally {
      if (mounted) setState(() => _lazyGenerating = false);
    }
  }

  Future<void> _ingestDroppedFile(String path) async {
    if (path.isEmpty) return;
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.directory) {
        if (mounted) {
          showDuckToast(context, S.councilWizardDocFolderSkipped);
        }
        return;
      }
      final lower = path.toLowerCase();
      if (_ConveneDocs.isImageExt(lower)) {
        final raw = await file.readAsBytes();
        _images.add(base64Encode(raw));
        return;
      }
      if (!_ConveneDocs.isAcceptedDocExt(lower)) {
        if (mounted) {
          showDuckToast(
            context,
            S.councilWizardDocUnsupported(p.basename(path)),
          );
        }
        return;
      }
      if (stat.size > _ConveneDocs.maxBytes) {
        if (mounted) {
          showDuckToast(
            context,
            S.councilWizardDocTooLarge(p.basename(path)),
          );
        }
        return;
      }
      final content = await file.readAsString().catchError((_) => '');
      _docs.add(
        CouncilBriefDoc(
          name: p.basename(path),
          size: stat.size,
          content: content,
        ),
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Convene drop ingest failed: $e');
    }
  }

  Future<void> _pickDocs() async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: _ConveneDocs.acceptedExtensions,
      allowMultiple: true,
      withData: false,
    );
    if (result == null) return;
    for (final f in result.files) {
      final path = f.path;
      if (path == null) continue;
      await _ingestDroppedFile(path);
    }
  }

  void _start(AppState appState) {
    final workspace = appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) return;
    final imagesSnapshot = _images.takeAll();
    final docsSnapshot = _docs.takeAll();
    final config = CouncilConfig(
      id: 'council_${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
      title: _title.text.trim().isEmpty ? S.councilTitle : _title.text.trim(),
      brief: _brief.text.trim(),
      orchestrator: _orchestrator.toAgent('orchestrator'),
      finalEvaluator: CouncilAgent(
        id: 'final_evaluator',
        name: S.councilFinalEvaluator,
        role: RolePreset.reviewer,
        customRole: S.councilFinalEvaluatorRole,
        model: _orchestrator.model ?? '',
        enabledTools: kCouncilDefaultTools,
      ),
      agents: [
        for (var i = 0; i < _agents.length; i++) _agents[i].toAgent('agent_$i'),
      ],
      briefImages: imagesSnapshot,
      briefDocs: docsSnapshot,
    );
    // Persist team / orchestrator picks for next time, but never persist
    // the brief itself — every Convene starts with an empty textarea.
    unawaited(
      appState.prefs.setCouncilLastConfigJson(
        jsonEncode({
          'title': _title.text.trim(),
          'brief': '',
          'orchestrator': _orchestrator.toJson(),
          'agents': _agents.map((a) => a.toJson()).toList(),
        }),
      ),
    );
    _brief.clear();
    Navigator.of(context).pop();
    appState.council.startCouncil(config, workspace);
  }
}

// ─────────────────────────────────────────────────────────────────────
//  SHEET
// ─────────────────────────────────────────────────────────────────────

class _Sheet extends StatelessWidget {
  final Widget child;
  final bool dropHover;

  const _Sheet({required this.child, required this.dropHover});

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(WizardTokens.radiusL),
        border: Border.all(
          color: dropHover
              ? DuckColors.accentCyan.withValues(alpha: 0.55)
              : DuckColors.glassEdgeHi,
          width: dropHover ? 1.0 : 0.6,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 40,
            spreadRadius: -8,
            offset: const Offset(0, 18),
          ),
        ],
      ),
      child: Stack(
        children: [
          if (dropHover)
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: DuckColors.accentCyan.withValues(alpha: 0.04),
                    border: Border.all(
                      color: DuckColors.accentCyan.withValues(alpha: 0.5),
                      width: 1.2,
                    ),
                    borderRadius:
                        BorderRadius.circular(WizardTokens.radiusL),
                  ),
                ),
              ),
            ),
          child,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  HEADER
// ─────────────────────────────────────────────────────────────────────

class _Header extends StatelessWidget {
  final VoidCallback onClose;
  final List<String> models;
  final String? selectedModel;
  final ValueChanged<String> onModelChanged;

  const _Header({
    required this.onClose,
    required this.models,
    required this.selectedModel,
    required this.onModelChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        WizardTokens.s18,
        WizardTokens.s12,
        WizardTokens.s14,
      ),
      child: Row(
        children: [
          Text(
            S.councilWizardTitle,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
            ),
          ),
          const Spacer(),
          if (models.isNotEmpty)
            Flexible(
              child: _CompactModelPicker(
                models: models,
                selected: selectedModel ?? models.first,
                onChanged: onModelChanged,
              ),
            ),
          const SizedBox(width: 4),
          IconButton(
            tooltip: S.cancel,
            onPressed: onClose,
            visualDensity: VisualDensity.compact,
            icon: const Icon(
              Icons.close,
              size: 18,
              color: DuckColors.fgMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _CompactModelPicker extends StatelessWidget {
  final List<String> models;
  final String selected;
  final ValueChanged<String> onChanged;

  const _CompactModelPicker({
    required this.models,
    required this.selected,
    required this.onChanged,
  });

  String _shortLabel(String model) {
    final idx = model.indexOf(':');
    return idx >= 0 ? model.substring(idx + 1) : model;
  }

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      onSelected: onChanged,
      initialValue: selected,
      tooltip: S.councilAgentModelLabel,
      position: PopupMenuPosition.under,
      constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
      ),
      color: DuckColors.bgRaised,
      itemBuilder: (_) => [
        for (final m in models)
          PopupMenuItem<String>(
            value: m,
            height: 34,
            child: Row(
              children: [
                if (m == selected)
                  const Padding(
                    padding: EdgeInsets.only(right: 8),
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: DuckColors.accentCyan,
                    ),
                  )
                else
                  const SizedBox(width: 22),
                Expanded(
                  child: Text(
                    _shortLabel(m),
                    style: TextStyle(
                      fontSize: 12,
                      color: m == selected
                          ? DuckColors.accentCyan
                          : DuckColors.fgPrimary,
                      fontFamily: 'monospace',
                      fontFamilyFallback: const [
                        'Consolas',
                        'Menlo',
                        'Courier New',
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: DuckColors.bgDeeper.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(WizardTokens.radiusS),
          border: Border.all(color: DuckColors.border, width: 0.6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.memory,
              size: 13,
              color: DuckColors.fgMuted,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                _shortLabel(selected),
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgPrimary,
                  fontFamily: 'monospace',
                  fontFamilyFallback: [
                    'Consolas',
                    'Menlo',
                    'Courier New',
                  ],
                ),
              ),
            ),
            const SizedBox(width: 4),
            const Icon(
              Icons.unfold_more,
              size: 13,
              color: DuckColors.fgSubtle,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  STEP INDICATOR
// ─────────────────────────────────────────────────────────────────────

class _StepIndicator extends StatelessWidget {
  final int step;

  const _StepIndicator({required this.step});

  @override
  Widget build(BuildContext context) {
    const labels = [
      S.councilWizardStepBrief,
      S.councilWizardStepTeam,
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        0,
        WizardTokens.s24,
        WizardTokens.s14,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            _StepDot(
              index: i,
              label: labels[i],
              state: i < step
                  ? _StepDotState.done
                  : i == step
                      ? _StepDotState.active
                      : _StepDotState.future,
            ),
            if (i < labels.length - 1)
              Expanded(
                child: Container(
                  height: 1,
                  margin: const EdgeInsets.symmetric(
                    horizontal: WizardTokens.s10,
                  ),
                  color: i < step
                      ? DuckColors.accentCyan.withValues(alpha: 0.45)
                      : DuckColors.glassSeam,
                ),
              ),
          ],
        ],
      ),
    );
  }
}

enum _StepDotState { done, active, future }

class _StepDot extends StatelessWidget {
  final int index;
  final String label;
  final _StepDotState state;

  const _StepDot({
    required this.index,
    required this.label,
    required this.state,
  });

  @override
  Widget build(BuildContext context) {
    final Color circleColor;
    final Color textColor;
    final Color labelColor;
    final Widget inner;
    switch (state) {
      case _StepDotState.done:
        circleColor = DuckColors.accentCyan.withValues(alpha: 0.18);
        textColor = DuckColors.accentCyan;
        labelColor = DuckColors.fgMuted;
        inner = const Icon(
          Icons.check,
          size: 12,
          color: DuckColors.accentCyan,
        );
        break;
      case _StepDotState.active:
        circleColor = DuckColors.accentCyan;
        textColor = DuckColors.bgDeepest;
        labelColor = DuckColors.fgPrimary;
        inner = Text(
          '${index + 1}',
          style: TextStyle(
            color: textColor,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        );
        break;
      case _StepDotState.future:
        circleColor = Colors.transparent;
        textColor = DuckColors.fgSubtle;
        labelColor = DuckColors.fgSubtle;
        inner = Text(
          '${index + 1}',
          style: TextStyle(
            color: textColor,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        );
        break;
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: circleColor,
            shape: BoxShape.circle,
            border: Border.all(
              color: state == _StepDotState.future
                  ? DuckColors.border
                  : DuckColors.accentCyan.withValues(alpha: 0.6),
              width: 0.8,
            ),
          ),
          child: inner,
        ),
        const SizedBox(width: WizardTokens.s8),
        Text(
          label,
          style: TextStyle(
            color: labelColor,
            fontSize: 12,
            fontWeight: state == _StepDotState.active
                ? FontWeight.w700
                : FontWeight.w500,
            letterSpacing: 0.1,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  GATE BANNER
// ─────────────────────────────────────────────────────────────────────

class _GateBanner extends StatelessWidget {
  const _GateBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        WizardTokens.s12,
        WizardTokens.s24,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: WizardTokens.s12,
        vertical: WizardTokens.s10,
      ),
      decoration: BoxDecoration(
        color: DuckColors.stateWarn.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        border: Border.all(
          color: DuckColors.stateWarn.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: const Row(
        children: [
          Icon(
            Icons.warning_amber_outlined,
            color: DuckColors.stateWarn,
            size: 16,
          ),
          SizedBox(width: WizardTokens.s8),
          Expanded(
            child: Text(
              S.councilModelGateBanner,
              style: TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  STEP 1 · BRIEF
// ─────────────────────────────────────────────────────────────────────

class _BriefStep extends StatelessWidget {
  final TextEditingController title;
  final TextEditingController brief;
  final CouncilPasteAttachments images;
  final _ConveneDocs docs;
  final bool dropHover;
  final VoidCallback onPickDocs;

  const _BriefStep({
    required this.title,
    required this.brief,
    required this.images,
    required this.docs,
    required this.dropHover,
    required this.onPickDocs,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: title,
          style: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.1,
          ),
          decoration: _wizardInputDecoration(
            S.councilSessionTitleLabel,
            isDense: true,
          ),
        ),
        const SizedBox(height: WizardTokens.s14),
        CouncilComposerField(
          controller: brief,
          attachments: images,
          minLines: 7,
          maxLines: 11,
          hintText: S.councilBriefHint,
        ),
        const SizedBox(height: WizardTokens.s10),
        _DocAttachmentBar(
          docs: docs,
          dropHover: dropHover,
          onPickDocs: onPickDocs,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  DOC ATTACHMENT BAR
// ─────────────────────────────────────────────────────────────────────

class _DocAttachmentBar extends StatelessWidget {
  final _ConveneDocs docs;
  final bool dropHover;
  final VoidCallback onPickDocs;

  const _DocAttachmentBar({
    required this.docs,
    required this.dropHover,
    required this.onPickDocs,
  });

  @override
  Widget build(BuildContext context) {
    final list = docs.docs;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s12,
        WizardTokens.s8,
        WizardTokens.s8,
        WizardTokens.s8,
      ),
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        border: Border.all(
          color: dropHover
              ? DuckColors.accentCyan.withValues(alpha: 0.65)
              : DuckColors.border,
          width: dropHover ? 1.0 : 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                dropHover
                    ? Icons.file_download_outlined
                    : Icons.description_outlined,
                size: 14,
                color: dropHover
                    ? DuckColors.accentCyan
                    : DuckColors.fgMuted,
              ),
              const SizedBox(width: WizardTokens.s8),
              Expanded(
                child: Text(
                  dropHover
                      ? S.councilWizardDropHint
                      : list.isEmpty
                          ? S.councilWizardAttachDocsHint
                          : S.councilWizardDocsAttached(list.length),
                  style: TextStyle(
                    fontSize: 11.5,
                    color: dropHover
                        ? DuckColors.accentCyan
                        : DuckColors.fgMuted,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: onPickDocs,
                style: TextButton.styleFrom(
                  foregroundColor: DuckColors.fgPrimary,
                  padding: const EdgeInsets.symmetric(
                    horizontal: WizardTokens.s10,
                    vertical: 4,
                  ),
                  minimumSize: const Size(0, 26),
                  textStyle: const TextStyle(fontSize: 11),
                ),
                icon: const Icon(Icons.attach_file, size: 13),
                label: const Text(S.councilWizardPickDocs),
              ),
            ],
          ),
          if (list.isNotEmpty) ...[
            const SizedBox(height: WizardTokens.s8),
            Wrap(
              spacing: WizardTokens.s6,
              runSpacing: WizardTokens.s6,
              children: [
                for (var i = 0; i < list.length; i++)
                  _DocChip(
                    doc: list[i],
                    onRemove: () => docs.removeAt(i),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _DocChip extends StatelessWidget {
  final CouncilBriefDoc doc;
  final VoidCallback onRemove;

  const _DocChip({required this.doc, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 5, 4, 5),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(WizardTokens.radiusS),
        border: Border.all(color: DuckColors.border, width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _iconForDoc(doc.name),
            size: 12,
            color: DuckColors.accentMint,
          ),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              doc.name,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          const SizedBox(width: 6),
          Text(
            _formatBytes(doc.size),
            style: const TextStyle(
              fontSize: 10,
              color: DuckColors.fgSubtle,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(999),
            child: const Padding(
              padding: EdgeInsets.all(3),
              child: Icon(Icons.close, size: 11, color: DuckColors.fgMuted),
            ),
          ),
        ],
      ),
    );
  }

  static IconData _iconForDoc(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.pdf')) return Icons.picture_as_pdf_outlined;
    if (lower.endsWith('.md')) return Icons.notes_outlined;
    if (lower.endsWith('.txt')) return Icons.subject_outlined;
    return Icons.code_outlined;
  }

  static String _formatBytes(int b) {
    if (b < 1024) return '${b}B';
    if (b < 1024 * 1024) return '${(b / 1024).toStringAsFixed(0)}KB';
    return '${(b / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

// ─────────────────────────────────────────────────────────────────────
//  STEP 2 · TEAM
// ─────────────────────────────────────────────────────────────────────

class _TeamStep extends StatelessWidget {
  final _DraftAgent orchestrator;
  final List<_DraftAgent> agents;
  final List<String> models;
  final VoidCallback onChanged;
  final VoidCallback onAddAgent;
  final ValueChanged<int> onRemoveAgent;

  const _TeamStep({
    required this.orchestrator,
    required this.agents,
    required this.models,
    required this.onChanged,
    required this.onAddAgent,
    required this.onRemoveAgent,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WizardAgentCard(
          nameController: orchestrator.name,
          role: orchestrator.role,
          onRoleChanged: (r) {
            orchestrator.role = r;
            onChanged();
          },
          selectedModel: orchestrator.model,
          availableModels: models,
          onModelChanged: (m) {
            orchestrator.model = m;
            onChanged();
          },
          customRoleController: orchestrator.customRole,
          onChanged: onChanged,
          isOrchestrator: true,
        ),
        const SizedBox(height: WizardTokens.s18),
        LayoutBuilder(
          builder: (context, constraints) {
            // Two columns above ~620 — 4–6 agents read better paired
            // than crammed into a triple-column.
            final twoCol = constraints.maxWidth >= 620;
            const gap = WizardTokens.s12;
            final cardWidth = twoCol
                ? (constraints.maxWidth - gap) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < agents.length; i++)
                  SizedBox(
                    width: cardWidth,
                    child: WizardAgentCard(
                      nameController: agents[i].name,
                      role: agents[i].role,
                      indexLabel: i + 1,
                      onRoleChanged: (r) {
                        agents[i].role = r;
                        onChanged();
                      },
                      selectedModel: agents[i].model,
                      availableModels: models,
                      onModelChanged: (m) {
                        agents[i].model = m;
                        onChanged();
                      },
                      customRoleController: agents[i].customRole,
                      onChanged: onChanged,
                      onRemove: agents.length <= 2
                          ? null
                          : () => onRemoveAgent(i),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: WizardTokens.s12),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: onAddAgent,
            icon: const Icon(Icons.add, size: 14),
            label: const Text(
              S.councilAddAgent,
              style: TextStyle(fontSize: 12),
            ),
            style: TextButton.styleFrom(
              foregroundColor: DuckColors.fgPrimary,
              padding: const EdgeInsets.symmetric(
                horizontal: WizardTokens.s12,
                vertical: 6,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  FOOTER
// ─────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final int step;
  final int stepCount;
  final bool canAdvance;
  final bool canStart;
  final bool isGenerating;
  final VoidCallback onCancel;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final VoidCallback onStart;

  const _Footer({
    required this.step,
    required this.stepCount,
    required this.canAdvance,
    required this.canStart,
    this.isGenerating = false,
    required this.onCancel,
    required this.onBack,
    required this.onNext,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    final isLastStep = step >= stepCount - 1;
    final isBrief = step == _stepBrief;
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        WizardTokens.s12,
        WizardTokens.s16,
        WizardTokens.s14,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: DuckColors.fgMuted,
            ),
            child: const Text(S.cancel),
          ),
          const Spacer(),
          if (onBack != null) ...[
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(Icons.chevron_left, size: 16),
              label: const Text(S.councilBack),
              style: TextButton.styleFrom(
                foregroundColor: DuckColors.fgPrimary,
              ),
            ),
            const SizedBox(width: WizardTokens.s8),
          ],
          if (!isLastStep)
            ElevatedButton.icon(
              onPressed: canAdvance && !isGenerating ? onNext : null,
              icon: isBrief
                  ? (isGenerating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.6,
                            color: DuckColors.fgPrimary,
                          ),
                        )
                      : const Icon(Icons.auto_awesome, size: 15))
                  : const Icon(Icons.chevron_right, size: 16),
              label: Text(
                isGenerating ? S.councilLazyModeWorking : S.councilNext,
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isBrief
                    ? DuckColors.accentCyan
                    : DuckColors.bgChip,
                foregroundColor: isBrief
                    ? DuckColors.bgDeepest
                    : DuckColors.fgPrimary,
                disabledBackgroundColor: isBrief
                    ? DuckColors.accentCyan.withValues(alpha: 0.25)
                    : DuckColors.bgChip.withValues(alpha: 0.4),
                disabledForegroundColor: DuckColors.fgSubtle,
                padding: const EdgeInsets.symmetric(
                  horizontal: WizardTokens.s14,
                  vertical: WizardTokens.s10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(WizardTokens.radiusS),
                ),
                elevation: 0,
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: canStart ? onStart : null,
              icon: const Icon(Icons.east, size: 16),
              label: const Text(S.councilStart),
              style: ElevatedButton.styleFrom(
                backgroundColor: DuckColors.accentCyan,
                foregroundColor: DuckColors.bgDeepest,
                disabledBackgroundColor:
                    DuckColors.accentCyan.withValues(alpha: 0.25),
                disabledForegroundColor: DuckColors.fgSubtle,
                padding: const EdgeInsets.symmetric(
                  horizontal: WizardTokens.s16,
                  vertical: WizardTokens.s12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius:
                      BorderRadius.circular(WizardTokens.radiusS),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12.5,
                  letterSpacing: 0.4,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  CONVENE DOCS MODEL (preserved)
// ─────────────────────────────────────────────────────────────────────

/// Lightweight ChangeNotifier for document attachments. Kept distinct
/// from CouncilPasteAttachments which is image-only and shared with
/// the orchestrator-ping panel.
class _ConveneDocs extends ChangeNotifier {
  static const int maxBytes = 1024 * 1024;
  static const List<String> acceptedExtensions = [
    'md', 'txt', 'pdf',
    'dart', 'ts', 'tsx', 'js', 'jsx', 'py', 'go', 'rs', 'rb',
    'java', 'kt', 'swift', 'cs', 'cpp', 'c', 'h', 'hpp',
    'json', 'yaml', 'yml', 'toml', 'xml', 'html', 'css', 'scss',
    'sh', 'ps1', 'sql',
  ];

  static bool isAcceptedDocExt(String pathLower) {
    final dot = pathLower.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = pathLower.substring(dot + 1);
    return acceptedExtensions.contains(ext);
  }

  static bool isImageExt(String pathLower) {
    return pathLower.endsWith('.png') ||
        pathLower.endsWith('.jpg') ||
        pathLower.endsWith('.jpeg') ||
        pathLower.endsWith('.webp') ||
        pathLower.endsWith('.gif');
  }

  final List<CouncilBriefDoc> _docs = <CouncilBriefDoc>[];

  List<CouncilBriefDoc> get docs => List.unmodifiable(_docs);
  int get length => _docs.length;
  bool get isEmpty => _docs.isEmpty;
  bool get isNotEmpty => _docs.isNotEmpty;

  void add(CouncilBriefDoc doc) {
    _docs.add(doc);
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _docs.length) return;
    _docs.removeAt(index);
    notifyListeners();
  }

  void clear() {
    if (_docs.isEmpty) return;
    _docs.clear();
    notifyListeners();
  }

  List<CouncilBriefDoc> takeAll() {
    final out = List<CouncilBriefDoc>.from(_docs);
    _docs.clear();
    notifyListeners();
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────
//  DRAFT AGENT (state model — preserved verbatim)
// ─────────────────────────────────────────────────────────────────────

class _DraftAgent {
  _DraftAgent({required String name, required this.role})
      : name = TextEditingController(text: name);

  final TextEditingController name;
  final TextEditingController customRole = TextEditingController();
  RolePreset role;
  String? model;

  factory _DraftAgent.fromJson(Map<String, dynamic> json) {
    final agent = _DraftAgent(
      name: json['name'] as String? ?? '',
      role: _roleFromName(json['role'] as String?) ?? RolePreset.researcher,
    );
    agent.customRole.text = json['customRole'] as String? ?? '';
    agent.model = json['model'] as String?;
    return agent;
  }

  factory _DraftAgent.fromAgent(CouncilAgent source) {
    final agent = _DraftAgent(name: source.name, role: source.role);
    agent.customRole.text = source.customRole;
    agent.model = source.model;
    return agent;
  }

  Map<String, dynamic> toJson() => {
        'name': name.text,
        'role': role.name,
        'customRole': customRole.text,
        'model': model,
      };

  CouncilAgent toAgent(String id) {
    return CouncilAgent(
      id: id,
      name: name.text.trim().isEmpty ? id : name.text.trim(),
      role: role,
      customRole: customRole.text.trim(),
      model: model ?? '',
      enabledTools: kCouncilDefaultTools,
    );
  }

  void dispose() {
    name.dispose();
    customRole.dispose();
  }
}

RolePreset? _roleFromName(String? name) {
  if (name == null) return null;
  for (final role in RolePreset.values) {
    if (role.name == name) return role;
  }
  return null;
}

InputDecoration _wizardInputDecoration(String label, {bool isDense = false}) {
  return InputDecoration(
    labelText: label,
    labelStyle: const TextStyle(
      color: DuckColors.fgMuted,
      fontSize: 12,
    ),
    floatingLabelStyle: const TextStyle(
      color: DuckColors.accentCyan,
      fontSize: 11.5,
      fontWeight: FontWeight.w600,
    ),
    filled: true,
    fillColor: DuckColors.bgDeeper.withValues(alpha: 0.7),
    isDense: isDense,
    contentPadding: const EdgeInsets.symmetric(
      horizontal: WizardTokens.s12,
      vertical: WizardTokens.s12,
    ),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WizardTokens.radiusS),
      borderSide: const BorderSide(color: DuckColors.border, width: 0.6),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WizardTokens.radiusS),
      borderSide: const BorderSide(color: DuckColors.border, width: 0.6),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WizardTokens.radiusS),
      borderSide: const BorderSide(color: DuckColors.accentCyan, width: 1.0),
    ),
  );
}
