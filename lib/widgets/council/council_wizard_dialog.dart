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
/// 2026 redesign: the previous wizard was a 4-step horizontal Stepper
/// with stacked form fields — visually it read as "settings dialog".
/// This pass replaces the stepper with a single composed surface so
/// the user sees the *whole* council they are convening (brief,
/// orchestrator, roster) at one glance. Stepwise navigation made the
/// modal feel cheap; eliminating it is the load-bearing visual move.
///
/// State / persistence / drop handling / lazy-roster generation are
/// preserved unchanged — only the visual shell and agent card chrome
/// were rebuilt. See `widgets/council/wizard/wizard_tokens.dart` for
/// the centralised tokens that drive this surface.
Future<void> showCouncilWizard(BuildContext context) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.62),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, a, b) => const CouncilWizardDialog(),
    transitionBuilder: (_, anim, b, child) {
      // Open transition: gentle rise + fade + scale, easeOutCubic.
      // Pulled out of `Dialog`'s default fade so we own the curve.
      final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: curved,
        child: Transform.translate(
          offset: Offset(0, (1 - curved.value) * 14),
          child: Transform.scale(
            scale: 0.97 + (0.03 * curved.value),
            child: child,
          ),
        ),
      );
    },
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
  final CouncilPasteAttachments _images = CouncilPasteAttachments();
  final _ConveneDocs _docs = _ConveneDocs();
  final ScrollController _scroll = ScrollController();
  bool _loadedLastConfig = false;
  bool _lazyGenerating = false;
  bool _dropHover = false;
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

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final models = appState.chat.availableModels.where(_isCouncilModel).toList()
      ..sort();
    for (final agent in [..._agents, _orchestrator]) {
      agent.model ??= models.isEmpty ? null : models.first;
    }

    final canStart = models.isNotEmpty &&
        _brief.text.trim().isNotEmpty &&
        _agents.length >= 2 &&
        !_lazyGenerating;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 880, maxHeight: 760),
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
                    _Hero(
                      modelCount: models.length,
                      onClose: () => Navigator.of(context).pop(),
                    ),
                    if (models.isEmpty)
                      const _GateBanner(message: S.councilModelGateBanner),
                    Expanded(
                      child: Scrollbar(
                        controller: _scroll,
                        thumbVisibility: false,
                        child: SingleChildScrollView(
                          controller: _scroll,
                          padding: const EdgeInsets.fromLTRB(
                            WizardTokens.s24,
                            WizardTokens.s20,
                            WizardTokens.s24,
                            WizardTokens.s20,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _BriefSection(
                                title: _title,
                                brief: _brief,
                                images: _images,
                                docs: _docs,
                                dropHover: _dropHover,
                                onPickDocs: _pickDocs,
                                canGenerate: models.isNotEmpty &&
                                    _brief.text.trim().isNotEmpty,
                                isGenerating: _lazyGenerating,
                                onGenerate: () => _generateLazyRoster(models),
                              ),
                              const SizedBox(height: WizardTokens.s28),
                              _OrchestratorSection(
                                draft: _orchestrator,
                                models: models,
                                onChanged: () => setState(() {}),
                              ),
                              const SizedBox(height: WizardTokens.s28),
                              _RosterSection(
                                agents: _agents,
                                models: models,
                                onChanged: () => setState(() {}),
                              ),
                              const SizedBox(height: WizardTokens.s24),
                              _ReviewSummary(
                                title: _title.text,
                                brief: _brief.text,
                                imageCount: _images.length,
                                docs: _docs.docs,
                                agents: _agents,
                                orchestrator: _orchestrator,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    _Footer(
                      canStart: canStart,
                      onStart: () => _start(appState),
                      onCancel: () => Navigator.of(context).pop(),
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
      });
      // After the new roster lands, glide the scroll to the roster
      // section so the user sees what was generated without hunting.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        _scroll.animateTo(
          _scroll.position.maxScrollExtent * 0.55,
          duration: const Duration(milliseconds: 360),
          curve: Curves.easeOutCubic,
        );
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
        // Hairline gradient on the sheet background reads as light
        // raking across midnight — the load-bearing depth move that
        // separates this sheet from "container with shadow".
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1F232C),
            Color(0xFF181B22),
          ],
        ),
        borderRadius: BorderRadius.circular(WizardTokens.radiusXL),
        border: Border.all(
          color: dropHover
              ? DuckColors.accentCyan.withValues(alpha: 0.55)
              : DuckColors.glassEdgeHi,
          width: dropHover ? 1.0 : 0.6,
        ),
        boxShadow: WizardTokens.sheetShadow(),
      ),
      child: Stack(
        children: [
          // Subtle top corner glow — purple→cyan, very low alpha.
          // Reads as a "spotlight" on the title block without ever
          // becoming the loudest thing on the screen.
          Positioned.fill(
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(-0.7, -1.2),
                    radius: 1.4,
                    colors: [
                      DuckColors.accentPurple.withValues(alpha: 0.10),
                      DuckColors.accentCyan.withValues(alpha: 0.04),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.45, 1.0],
                  ),
                ),
              ),
            ),
          ),
          // Drop-zone overlay — only when actively hovering files.
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
                        BorderRadius.circular(WizardTokens.radiusXL),
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
//  HERO
// ─────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  final int modelCount;
  final VoidCallback onClose;

  const _Hero({required this.modelCount, required this.onClose});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s28,
        WizardTokens.s24,
        WizardTokens.s16,
        WizardTokens.s20,
      ),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Mark — concentric ring reading as a council node.
          _BrandMark(),
          const SizedBox(width: WizardTokens.s16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'CONVENE',
                      style: WizardTokens.eyebrow.copyWith(
                        color: DuckColors.accentCyan,
                      ),
                    ),
                    const SizedBox(width: WizardTokens.s8),
                    Container(
                      width: 1,
                      height: 9,
                      color: DuckColors.glassSeam,
                    ),
                    const SizedBox(width: WizardTokens.s8),
                    WizardPill(
                      label: 'PROTECTED',
                      color: DuckColors.accentPurple,
                      icon: Icons.shield_outlined,
                    ),
                    if (modelCount > 0) ...[
                      const SizedBox(width: WizardTokens.s6),
                      WizardPill(
                        label: '$modelCount MODEL${modelCount == 1 ? '' : 'S'}',
                        color: DuckColors.accentMint,
                        icon: Icons.memory,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 6),
                Text('The Council', style: WizardTokens.display(context)),
                const SizedBox(height: 4),
                Text(
                  S.councilModalProtected,
                  style: WizardTokens.subtitle(context),
                ),
              ],
            ),
          ),
          const SizedBox(width: WizardTokens.s12),
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

class _BrandMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            DuckColors.accentPurple.withValues(alpha: 0.30),
            DuckColors.accentCyan.withValues(alpha: 0.18),
          ],
        ),
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.45),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: DuckColors.accentPurple.withValues(alpha: 0.18),
            blurRadius: 18,
            spreadRadius: -2,
          ),
        ],
      ),
      child: const Stack(
        alignment: Alignment.center,
        children: [
          Icon(Icons.hub_outlined, size: 22, color: DuckColors.pearlWhite),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  GATE BANNER
// ─────────────────────────────────────────────────────────────────────

class _GateBanner extends StatelessWidget {
  final String message;

  const _GateBanner({required this.message});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        WizardTokens.s14,
        WizardTokens.s24,
        0,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: WizardTokens.s12,
        vertical: WizardTokens.s10,
      ),
      decoration: BoxDecoration(
        color: DuckColors.accentPurple.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.warning_amber_outlined,
            color: DuckColors.accentPurple,
            size: 16,
          ),
          const SizedBox(width: WizardTokens.s8),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(
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
//  BRIEF SECTION
// ─────────────────────────────────────────────────────────────────────

class _BriefSection extends StatelessWidget {
  final TextEditingController title;
  final TextEditingController brief;
  final CouncilPasteAttachments images;
  final _ConveneDocs docs;
  final bool dropHover;
  final VoidCallback onPickDocs;
  final bool canGenerate;
  final bool isGenerating;
  final VoidCallback onGenerate;

  const _BriefSection({
    required this.title,
    required this.brief,
    required this.images,
    required this.docs,
    required this.dropHover,
    required this.onPickDocs,
    required this.canGenerate,
    required this.isGenerating,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WizardEyebrow(
          label: 'BRIEF',
          trailing: brief.text.trim().isNotEmpty
              ? WizardPill(
                  label: 'READY',
                  color: DuckColors.stateOk,
                  icon: Icons.check_circle_outline,
                )
              : WizardPill(
                  label: 'AWAITING INTENT',
                  color: DuckColors.fgMuted,
                ),
        ),
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
        // The brief composer is the focal element — give it the most
        // visual weight on this screen.
        Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(WizardTokens.radiusM),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: CouncilComposerField(
            controller: brief,
            attachments: images,
            minLines: 6,
            maxLines: 11,
            hintText: S.councilBriefHint,
          ),
        ),
        const SizedBox(height: WizardTokens.s10),
        _DocAttachmentBar(
          docs: docs,
          dropHover: dropHover,
          onPickDocs: onPickDocs,
        ),
        const SizedBox(height: WizardTokens.s14),
        _LazyModeCard(
          canGenerate: canGenerate,
          isGenerating: isGenerating,
          onGenerate: onGenerate,
        ),
      ],
    );
  }
}

class _LazyModeCard extends StatelessWidget {
  final bool canGenerate;
  final bool isGenerating;
  final VoidCallback onGenerate;

  const _LazyModeCard({
    required this.canGenerate,
    required this.isGenerating,
    required this.onGenerate,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s14,
        WizardTokens.s12,
        WizardTokens.s10,
        WizardTokens.s12,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            DuckColors.accentPurple.withValues(alpha: 0.14),
            DuckColors.accentCyan.withValues(alpha: 0.06),
          ],
        ),
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.32),
          width: 0.6,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: DuckColors.accentPurple.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(WizardTokens.radiusS),
              border: Border.all(
                color: DuckColors.accentPurple.withValues(alpha: 0.45),
                width: 0.6,
              ),
            ),
            child: const Icon(
              Icons.auto_awesome,
              size: 14,
              color: DuckColors.accentPurple,
            ),
          ),
          const SizedBox(width: WizardTokens.s10),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.councilLazyModeTitle,
                  style: TextStyle(
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 12.5,
                    letterSpacing: 0.1,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  S.councilLazyModeBody,
                  style: TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 11.5,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: WizardTokens.s10),
          ElevatedButton.icon(
            onPressed: canGenerate && !isGenerating ? onGenerate : null,
            icon: isGenerating
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.6),
                  )
                : const Icon(Icons.auto_awesome, size: 13),
            label: Text(
              isGenerating
                  ? S.councilLazyModeWorking
                  : S.councilLazyModeGenerate,
              style: const TextStyle(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  ORCHESTRATOR
// ─────────────────────────────────────────────────────────────────────

class _OrchestratorSection extends StatelessWidget {
  final _DraftAgent draft;
  final List<String> models;
  final VoidCallback onChanged;

  const _OrchestratorSection({
    required this.draft,
    required this.models,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const WizardEyebrow(label: 'ORCHESTRATOR  ·  CHAIRS THE SESSION'),
        _StaggeredFade(
          delay: const Duration(milliseconds: 60),
          child: WizardAgentCard(
            nameController: draft.name,
            role: draft.role,
            onRoleChanged: (r) {
              draft.role = r;
              onChanged();
            },
            selectedModel: draft.model,
            availableModels: models,
            onModelChanged: (m) {
              draft.model = m;
              onChanged();
            },
            customRoleController: draft.customRole,
            onChanged: onChanged,
            isOrchestrator: true,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  ROSTER
// ─────────────────────────────────────────────────────────────────────

class _RosterSection extends StatelessWidget {
  final List<_DraftAgent> agents;
  final List<String> models;
  final VoidCallback onChanged;

  const _RosterSection({
    required this.agents,
    required this.models,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        WizardEyebrow(
          label: 'ROSTER  ·  ${agents.length} AGENT${agents.length == 1 ? '' : 'S'}',
          trailing: TextButton.icon(
            onPressed: () {
              agents.add(
                _DraftAgent(
                  name: '${S.councilRoleResearcher} ${agents.length + 1}',
                  role: RolePreset.researcher,
                ),
              );
              onChanged();
            },
            icon: const Icon(Icons.add, size: 14),
            label: const Text(
              S.councilAddAgent,
              style: TextStyle(fontSize: 11.5),
            ),
            style: TextButton.styleFrom(
              foregroundColor: DuckColors.fgPrimary,
              padding: const EdgeInsets.symmetric(
                horizontal: WizardTokens.s10,
                vertical: 4,
              ),
              minimumSize: const Size(0, 26),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            // Two columns when there is room, single column when the
            // sheet is constrained narrower than ~640. Avoid a 3-col
            // grid — a council of 4-6 agents reads better paired.
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
                    child: _StaggeredFade(
                      delay: Duration(milliseconds: 80 + i * 45),
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
                            : () {
                                agents[i].dispose();
                                agents.removeAt(i);
                                onChanged();
                              },
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  REVIEW SUMMARY (inline, not a separate step)
// ─────────────────────────────────────────────────────────────────────

class _ReviewSummary extends StatelessWidget {
  final String title;
  final String brief;
  final int imageCount;
  final List<CouncilBriefDoc> docs;
  final List<_DraftAgent> agents;
  final _DraftAgent orchestrator;

  const _ReviewSummary({
    required this.title,
    required this.brief,
    required this.imageCount,
    required this.docs,
    required this.agents,
    required this.orchestrator,
  });

  @override
  Widget build(BuildContext context) {
    final hasContent = title.isNotEmpty ||
        brief.trim().isNotEmpty ||
        imageCount > 0 ||
        docs.isNotEmpty;
    if (!hasContent && agents.isEmpty) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s14,
        WizardTokens.s12,
        WizardTokens.s14,
        WizardTokens.s12,
      ),
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
        border: Border.all(
          color: DuckColors.glassSeam,
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.summarize_outlined,
                size: 12,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: WizardTokens.s6),
              Text(
                'BEFORE THEY CONVENE',
                style: WizardTokens.eyebrow,
              ),
            ],
          ),
          const SizedBox(height: WizardTokens.s8),
          Wrap(
            spacing: WizardTokens.s10,
            runSpacing: WizardTokens.s6,
            children: [
              if (imageCount > 0)
                _SummaryChip(
                  icon: Icons.image_outlined,
                  label: '$imageCount image${imageCount == 1 ? '' : 's'}',
                ),
              if (docs.isNotEmpty)
                _SummaryChip(
                  icon: Icons.description_outlined,
                  label: '${docs.length} doc${docs.length == 1 ? '' : 's'}',
                ),
              _SummaryChip(
                icon: Icons.account_tree_outlined,
                label:
                    '${agents.length} agent${agents.length == 1 ? '' : 's'} + 1 orchestrator',
              ),
              if (brief.trim().isNotEmpty)
                _SummaryChip(
                  icon: Icons.notes_outlined,
                  label: '${brief.trim().split(RegExp(r"\s+")).length} words',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryChip extends StatelessWidget {
  final IconData icon;
  final String label;

  const _SummaryChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 11, color: DuckColors.fgSubtle),
        const SizedBox(width: 5),
        Text(
          label,
          style: const TextStyle(
            color: DuckColors.fgMuted,
            fontSize: 11.5,
          ),
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
        borderRadius: BorderRadius.circular(WizardTokens.radiusM),
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
//  FOOTER
// ─────────────────────────────────────────────────────────────────────

class _Footer extends StatelessWidget {
  final bool canStart;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  const _Footer({
    required this.canStart,
    required this.onStart,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(
        WizardTokens.s24,
        WizardTokens.s14,
        WizardTokens.s16,
        WizardTokens.s16,
      ),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DuckColors.glassSeam)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Color(0x00000000),
            Color(0x33000000),
          ],
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              canStart
                  ? 'Ready to convene.'
                  : 'Provide a brief and at least 2 agents.',
              style: TextStyle(
                color: canStart
                    ? DuckColors.stateOk
                    : DuckColors.fgSubtle,
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: onCancel,
            style: TextButton.styleFrom(
              foregroundColor: DuckColors.fgMuted,
            ),
            child: const Text(S.cancel),
          ),
          const SizedBox(width: WizardTokens.s8),
          _PrimaryStartButton(
            enabled: canStart,
            onPressed: onStart,
          ),
        ],
      ),
    );
  }
}

class _PrimaryStartButton extends StatelessWidget {
  final bool enabled;
  final VoidCallback onPressed;

  const _PrimaryStartButton({
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: enabled ? 1.0 : 0.55,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(WizardTokens.radiusS),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: DuckColors.accentCyan.withValues(alpha: 0.35),
                    blurRadius: 18,
                    spreadRadius: -2,
                    offset: const Offset(0, 4),
                  ),
                ]
              : const [],
        ),
        child: ElevatedButton.icon(
          onPressed: enabled ? onPressed : null,
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
              borderRadius: BorderRadius.circular(WizardTokens.radiusS),
            ),
            textStyle: const TextStyle(
              fontWeight: FontWeight.w800,
              fontSize: 12.5,
              letterSpacing: 0.4,
            ),
          ),
          icon: const Icon(Icons.east, size: 15),
          label: const Text(S.councilStart),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  STAGGERED REVEAL (no new packages — TweenAnimationBuilder)
// ─────────────────────────────────────────────────────────────────────

class _StaggeredFade extends StatelessWidget {
  final Widget child;
  final Duration delay;

  const _StaggeredFade({required this.child, this.delay = Duration.zero});

  @override
  Widget build(BuildContext context) {
    final reduceMotion =
        MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (reduceMotion) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeOutCubic,
      // Push the value through a delayed mapping by clamping early
      // ticks to 0 — avoids a separate FutureBuilder/Timer.
      builder: (context, t, child) {
        final delayMs = delay.inMilliseconds;
        // Re-shape t so the first `delayMs / 420` portion sits at 0.
        final start = (delayMs / 420).clamp(0.0, 1.0);
        final v = t < start ? 0.0 : (t - start) / (1 - start);
        return Opacity(
          opacity: v.clamp(0.0, 1.0),
          child: Transform.translate(
            offset: Offset(0, (1 - v) * 8),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────
//  DRAFT AGENT (state model — preserved verbatim from old wizard)
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
      borderRadius: BorderRadius.circular(WizardTokens.radiusM),
      borderSide: const BorderSide(color: DuckColors.border, width: 0.6),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WizardTokens.radiusM),
      borderSide: const BorderSide(color: DuckColors.border, width: 0.6),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(WizardTokens.radiusM),
      borderSide: const BorderSide(color: DuckColors.accentCyan, width: 1.0),
    ),
  );
}
