import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/council_controller.dart';
import '../../services/council/council_models.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'council_paste_field.dart';

class CouncilUserPromptPanel extends StatefulWidget {
  final CouncilController controller;
  final CouncilQuestion question;

  const CouncilUserPromptPanel({
    super.key,
    required this.controller,
    required this.question,
  });

  @override
  State<CouncilUserPromptPanel> createState() => _CouncilUserPromptPanelState();
}

class _CouncilUserPromptPanelState extends State<CouncilUserPromptPanel> {
  final TextEditingController _answer = TextEditingController();
  final CouncilPasteAttachments _attachments = CouncilPasteAttachments();

  @override
  void dispose() {
    _answer.dispose();
    _attachments.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _answer.text.trim();
    final imgs = _attachments.takeAll();
    if (text.isEmpty && imgs.isEmpty) return;
    widget.controller.answerPendingUserQuestion(text, images: imgs);
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 18,
      top: 88,
      width: 360,
      child: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF30313A),
                DuckColors.bgRaised,
                DuckColors.bgDeeper,
              ],
            ),
            borderRadius: BorderRadius.circular(DuckTheme.radiusL),
            border: Border.all(color: DuckColors.accentPurple, width: 1.2),
            boxShadow: [
              BoxShadow(
                color: DuckColors.accentPurple.withValues(alpha: 0.24),
                blurRadius: 34,
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
                  Container(
                    width: 30,
                    height: 30,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          DuckColors.accentCyan,
                          DuckColors.accentPurple,
                        ],
                      ),
                    ),
                    child: const Icon(
                      Icons.record_voice_over_outlined,
                      size: 17,
                      color: DuckColors.bgDeepest,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    S.councilAskUserHeader,
                    style: TextStyle(
                      color: DuckColors.fgPrimary,
                      fontWeight: FontWeight.w800,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.question.question,
                style: const TextStyle(
                  color: DuckColors.fgPrimary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              CouncilComposerField(
                controller: _answer,
                attachments: _attachments,
                minLines: 3,
                maxLines: 6,
                hintText: S.councilUserAnswerHint,
                onSubmit: _submit,
              ),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _submit,
                  icon: const Icon(Icons.send, size: 15),
                  label: const Text(S.councilSubmitAnswer),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
