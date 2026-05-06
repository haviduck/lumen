import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

Future<void> showCouncilWizard(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const CouncilWizardDialog(),
  );
}

class CouncilWizardDialog extends StatefulWidget {
  const CouncilWizardDialog({super.key});

  @override
  State<CouncilWizardDialog> createState() => _CouncilWizardDialogState();
}

class _CouncilWizardDialogState extends State<CouncilWizardDialog> {
  final TextEditingController _title = TextEditingController();
  final TextEditingController _brief = TextEditingController();
  int _step = 0;
  bool _loadedLastConfig = false;
  bool _lazyGenerating = false;
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
      _brief.text = json['brief'] as String? ?? '';
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

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final models = appState.chat.availableModels.where(_isCouncilModel).toList()
      ..sort();
    for (final agent in [..._agents, _orchestrator]) {
      agent.model ??= models.isEmpty ? null : models.first;
    }

    return Dialog(
      backgroundColor: DuckColors.bgRaised,
      insetPadding: const EdgeInsets.all(32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
        child: Column(
          children: [
            const _Header(),
            const _InfoBanner(message: S.councilModalProtected),
            if (models.isEmpty)
              const _GateBanner(message: S.councilModelGateBanner),
            Expanded(
              child: Stepper(
                currentStep: _step,
                type: StepperType.horizontal,
                controlsBuilder: (context, details) => const SizedBox.shrink(),
                onStepTapped: (i) => setState(() => _step = i),
                steps: [
                  Step(
                    title: const Text(S.councilWizardStepBrief),
                    isActive: _step == 0,
                    content: _BriefStep(
                      title: _title,
                      brief: _brief,
                      canGenerate:
                          models.isNotEmpty && _brief.text.trim().isNotEmpty,
                      isGenerating: _lazyGenerating,
                      onGenerate: () => _generateLazyRoster(models),
                    ),
                  ),
                  Step(
                    title: const Text(S.councilWizardStepAgents),
                    isActive: _step == 1,
                    content: _AgentsStep(
                      agents: _agents,
                      models: models,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  Step(
                    title: const Text(S.councilWizardStepOrchestrator),
                    isActive: _step == 2,
                    content: _AgentEditor(
                      draft: _orchestrator,
                      models: models,
                      onChanged: () => setState(() {}),
                    ),
                  ),
                  Step(
                    title: const Text(S.councilWizardStepReview),
                    isActive: _step == 3,
                    content: _ReviewStep(
                      title: _title.text,
                      brief: _brief.text,
                      agents: _agents,
                      orchestrator: _orchestrator,
                    ),
                  ),
                ],
              ),
            ),
            _Footer(
              step: _step,
              canStart:
                  models.isNotEmpty &&
                  _brief.text.trim().isNotEmpty &&
                  _agents.length >= 2 &&
                  !_lazyGenerating,
              onBack: _step == 0 ? null : () => setState(() => _step--),
              onNext: _step == 3 ? null : () => setState(() => _step++),
              onStart: () => _start(appState),
            ),
          ],
        ),
      ),
    );
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
        _step = 1;
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(S.councilLazyModeDone)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text(S.councilLazyModeFailed)));
    } finally {
      if (mounted) setState(() => _lazyGenerating = false);
    }
  }

  bool _isCouncilModel(String model) {
    if (model.startsWith('claude:')) return true;
    if (!model.startsWith('copilot:')) return false;
    return model.substring('copilot:'.length).toLowerCase().contains('claude');
  }

  void _start(AppState appState) {
    final workspace = appState.currentDirectory;
    if (workspace == null || workspace.isEmpty) return;
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
        enabledTools: const {
          'read_file',
          'search_text',
          'glob',
          'web_search',
          'web_fetch',
        },
      ),
      agents: [
        for (var i = 0; i < _agents.length; i++) _agents[i].toAgent('agent_$i'),
      ],
    );
    unawaited(
      appState.prefs.setCouncilLastConfigJson(
        jsonEncode({
          'title': _title.text.trim(),
          'brief': _brief.text.trim(),
          'orchestrator': _orchestrator.toJson(),
          'agents': _agents.map((a) => a.toJson()).toList(),
        }),
      ),
    );
    Navigator.of(context).pop();
    appState.council.startCouncil(config, workspace);
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: const Row(
        children: [
          Icon(Icons.hub_outlined, color: DuckColors.accentPurple),
          SizedBox(width: 10),
          Text(
            S.councilWizardTitle,
            style: TextStyle(
              color: DuckColors.fgPrimary,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
        ],
      ),
    );
  }
}

class _GateBanner extends StatelessWidget {
  final String message;

  const _GateBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.accentPurple.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            color: DuckColors.accentPurple,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: DuckColors.fgPrimary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoBanner extends StatelessWidget {
  final String message;

  const _InfoBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: DuckColors.accentCyan.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentCyan.withValues(alpha: 0.24),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.lock_outline,
            size: 14,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: DuckColors.fgMuted, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

class _BriefStep extends StatelessWidget {
  final TextEditingController title;
  final TextEditingController brief;
  final bool canGenerate;
  final bool isGenerating;
  final VoidCallback onGenerate;

  const _BriefStep({
    required this.title,
    required this.brief,
    required this.canGenerate,
    required this.isGenerating,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(
          controller: title,
          style: const TextStyle(color: DuckColors.fgPrimary),
          decoration: _inputDecoration(S.councilSessionTitleLabel),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: brief,
          minLines: 8,
          maxLines: 12,
          style: const TextStyle(color: DuckColors.fgPrimary),
          decoration: _inputDecoration(
            S.councilBriefLabel,
            hint: S.councilBriefHint,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                DuckColors.accentPurple.withValues(alpha: 0.10),
                DuckColors.accentCyan.withValues(alpha: 0.06),
              ],
            ),
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border.all(
              color: DuckColors.accentPurple.withValues(alpha: 0.26),
            ),
          ),
          child: Row(
            children: [
              const Icon(Icons.auto_awesome, color: DuckColors.accentPurple),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.councilLazyModeTitle,
                      style: TextStyle(
                        color: DuckColors.fgPrimary,
                        fontWeight: FontWeight.w800,
                        fontSize: 12,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      S.councilLazyModeBody,
                      style: TextStyle(color: DuckColors.fgMuted, fontSize: 11),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              ElevatedButton.icon(
                onPressed: canGenerate && !isGenerating ? onGenerate : null,
                icon: isGenerating
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.hub_outlined, size: 15),
                label: Text(
                  isGenerating
                      ? S.councilLazyModeWorking
                      : S.councilLazyModeGenerate,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AgentsStep extends StatelessWidget {
  final List<_DraftAgent> agents;
  final List<String> models;
  final VoidCallback onChanged;

  const _AgentsStep({
    required this.agents,
    required this.models,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (final agent in agents)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _AgentEditor(
                    draft: agent,
                    models: models,
                    onChanged: onChanged,
                  ),
                ),
                IconButton(
                  tooltip: S.councilRemoveAgent,
                  onPressed: agents.length <= 2
                      ? null
                      : () {
                          agent.dispose();
                          agents.remove(agent);
                          onChanged();
                        },
                  icon: const Icon(Icons.close, color: DuckColors.fgMuted),
                ),
              ],
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              agents.add(
                _DraftAgent(
                  name: '${S.councilRoleResearcher} ${agents.length + 1}',
                  role: RolePreset.researcher,
                ),
              );
              onChanged();
            },
            icon: const Icon(Icons.add),
            label: const Text(S.councilAddAgent),
          ),
        ),
      ],
    );
  }
}

class _AgentEditor extends StatelessWidget {
  final _DraftAgent draft;
  final List<String> models;
  final VoidCallback onChanged;

  const _AgentEditor({
    required this.draft,
    required this.models,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: draft.name,
                  style: const TextStyle(color: DuckColors.fgPrimary),
                  onChanged: (_) => onChanged(),
                  decoration: _inputDecoration(S.councilAgentNameLabel),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<RolePreset>(
                  initialValue: draft.role,
                  dropdownColor: DuckColors.bgRaisedHi,
                  decoration: _inputDecoration(S.councilAgentRoleLabel),
                  items: [
                    for (final role in RolePreset.values)
                      DropdownMenuItem(
                        value: role,
                        child: Text(_roleLabel(role)),
                      ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    draft.role = value;
                    onChanged();
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            initialValue: models.contains(draft.model) ? draft.model : null,
            dropdownColor: DuckColors.bgRaisedHi,
            decoration: _inputDecoration(S.councilAgentModelLabel),
            items: [
              for (final model in models)
                DropdownMenuItem(value: model, child: Text(model)),
            ],
            onChanged: (value) {
              draft.model = value;
              onChanged();
            },
          ),
          if (draft.role == RolePreset.custom) ...[
            const SizedBox(height: 10),
            TextField(
              controller: draft.customRole,
              maxLines: 3,
              style: const TextStyle(color: DuckColors.fgPrimary),
              onChanged: (_) => onChanged(),
              decoration: _inputDecoration(S.councilCustomRoleLabel),
            ),
          ],
        ],
      ),
    );
  }
}

class _ReviewStep extends StatelessWidget {
  final String title;
  final String brief;
  final List<_DraftAgent> agents;
  final _DraftAgent orchestrator;

  const _ReviewStep({
    required this.title,
    required this.brief,
    required this.agents,
    required this.orchestrator,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ReviewLine(label: S.councilSessionTitleLabel, value: title),
        _ReviewLine(label: S.councilBriefLabel, value: brief),
        _ReviewLine(
          label: S.councilOrchestrator,
          value: '${orchestrator.name.text} · ${orchestrator.model ?? ''}',
        ),
        for (final agent in agents)
          _ReviewLine(
            label: _roleLabel(agent.role),
            value: '${agent.name.text} · ${agent.model ?? ''}',
          ),
      ],
    );
  }
}

class _ReviewLine extends StatelessWidget {
  final String label;
  final String value;

  const _ReviewLine({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        '$label: $value',
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 12),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  final int step;
  final bool canStart;
  final VoidCallback? onBack;
  final VoidCallback? onNext;
  final VoidCallback onStart;

  const _Footer({
    required this.step,
    required this.canStart,
    required this.onBack,
    required this.onNext,
    required this.onStart,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Row(
        children: [
          TextButton(onPressed: onBack, child: const Text(S.councilBack)),
          const Spacer(),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(S.cancel),
          ),
          const SizedBox(width: 8),
          if (step < 3)
            ElevatedButton(onPressed: onNext, child: const Text(S.councilNext))
          else
            ElevatedButton.icon(
              onPressed: canStart ? onStart : null,
              icon: const Icon(Icons.hub_outlined),
              label: const Text(S.councilStart),
            ),
        ],
      ),
    );
  }
}

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
      enabledTools: const {
        'read_file',
        'search_text',
        'glob',
        'web_search',
        'web_fetch',
      },
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

InputDecoration _inputDecoration(String label, {String? hint}) {
  return InputDecoration(
    labelText: label,
    hintText: hint,
    labelStyle: const TextStyle(color: DuckColors.fgMuted),
    hintStyle: const TextStyle(color: DuckColors.fgSubtle),
    filled: true,
    fillColor: DuckColors.bgDeeper,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      borderSide: const BorderSide(color: DuckColors.border),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      borderSide: const BorderSide(color: DuckColors.border),
    ),
  );
}

String _roleLabel(RolePreset role) {
  return switch (role) {
    RolePreset.pentester => S.councilRolePentester,
    RolePreset.reviewer => S.councilRoleReviewer,
    RolePreset.researcher => S.councilRoleResearcher,
    RolePreset.architect => S.councilRoleArchitect,
    RolePreset.tester => S.councilRoleTester,
    RolePreset.writer => S.councilRoleWriter,
    RolePreset.custom => S.councilRoleCustom,
  };
}
