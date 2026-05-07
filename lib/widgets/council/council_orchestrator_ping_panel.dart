import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/council_controller.dart';
import '../../services/model_capabilities.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'council_paste_field.dart';

/// Modal-style overlay for sending a mid-session note to the orchestrator.
///
/// Surfaced from the orchestrator card in the Council theater. The text
/// the user submits is queued on the orchestrator's
/// [CouncilAgentRunner] and is appended as a fresh user turn at the
/// next iteration boundary, prompting the orchestrator to bake the note
/// into the plan and re-dispatch agents with revised directives if
/// needed.
class CouncilOrchestratorPingPanel extends StatefulWidget {
  final CouncilController controller;
  final VoidCallback onClose;

  const CouncilOrchestratorPingPanel({
    super.key,
    required this.controller,
    required this.onClose,
  });

  @override
  State<CouncilOrchestratorPingPanel> createState() =>
      _CouncilOrchestratorPingPanelState();
}

class _CouncilOrchestratorPingPanelState
    extends State<CouncilOrchestratorPingPanel> {
  final TextEditingController _note = TextEditingController();
  final FocusNode _focus = FocusNode();
  final CouncilPasteAttachments _attachments = CouncilPasteAttachments();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _note.dispose();
    _focus.dispose();
    _attachments.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _note.text.trim();
    final imgs = _attachments.images;
    if ((text.isEmpty && imgs.isEmpty) || _sending) return;
    // Warn (don't block) when the orchestrator's bound model can't see
    // images. Council fans out across providers; the orchestrator is
    // the one we can check synchronously here, and it's the agent that
    // first reads the user note.
    if (imgs.isNotEmpty) {
      final orch = widget.controller.session?.config.orchestrator.model;
      if (orch != null) {
        final colon = orch.indexOf(':');
        final provider = colon > 0 ? orch.substring(0, colon) : orch;
        final raw = colon > 0 ? orch.substring(colon + 1) : orch;
        final canSee = ModelCapabilities.supportsVision(
          provider: provider,
          rawModel: raw,
        );
        if (!canSee && mounted) {
          showDuckToast(context, S.councilPingOrchestratorVisionWarn);
        }
      }
    }
    final imagesSnapshot = _attachments.takeAll();
    setState(() => _sending = true);
    try {
      await widget.controller.pingOrchestrator(text, images: imagesSnapshot);
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text(S.councilPingOrchestratorSent)),
      );
      widget.onClose();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canPing = widget.controller.canPingOrchestrator;
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.onClose,
              child: ColoredBox(
                color: DuckColors.bgDeepest.withValues(alpha: 0.32),
              ),
            ),
          ),
          Center(
            child: Material(
              color: Colors.transparent,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Container(
                  margin: const EdgeInsets.all(24),
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        Color(0xFF2A2D38),
                        DuckColors.bgRaised,
                        DuckColors.bgDeeper,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(DuckTheme.radiusL),
                    border: Border.all(
                      color: DuckColors.accentCyan,
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: DuckColors.accentCyan.withValues(alpha: 0.20),
                        blurRadius: 36,
                        spreadRadius: 1,
                      ),
                      ...DuckTheme.shadowSoft,
                    ],
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              S.councilPingOrchestratorTitle,
                              style: TextStyle(
                                color: DuckColors.fgPrimary,
                                fontWeight: FontWeight.w800,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: S.close,
                            onPressed: widget.onClose,
                            iconSize: 18,
                            color: DuckColors.fgMuted,
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        canPing
                            ? S.councilPingOrchestratorBody
                            : S.councilPingOrchestratorUnavailable,
                        style: const TextStyle(
                          color: DuckColors.fgMuted,
                          fontSize: 12,
                          height: 1.35,
                        ),
                      ),
                      const SizedBox(height: 12),
                      CouncilComposerField(
                        controller: _note,
                        focusNode: _focus,
                        attachments: _attachments,
                        enabled: canPing && !_sending,
                        minLines: 4,
                        maxLines: 8,
                        hintText: S.councilPingOrchestratorHint,
                        onSubmit: _send,
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: ElevatedButton.icon(
                          onPressed: canPing && !_sending ? _send : null,
                          icon: _sending
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Icon(Icons.send, size: 15),
                          label: const Text(S.councilPingOrchestratorSend),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
