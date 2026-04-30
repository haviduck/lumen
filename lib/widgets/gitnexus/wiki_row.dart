import 'dart:io';

import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/gitnexus_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

class GitNexusWikiRow extends StatelessWidget {
  final GitNexusService service;
  final bool workspaceOpen;
  final bool autoWiki;
  final TextEditingController modelController;
  final ValueChanged<bool> onAutoWikiChanged;

  const GitNexusWikiRow({
    super.key,
    required this.service,
    required this.workspaceOpen,
    required this.autoWiki,
    required this.modelController,
    required this.onAutoWikiChanged,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final running = service.wikiRunning;
        final canRun = workspaceOpen && !running;
        final (statusLabel, statusColor) = _status();
        return Container(
          constraints: const BoxConstraints(maxWidth: 820),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            border: Border.all(
              color: running
                  ? DuckColors.accentCyan.withValues(alpha: 0.45)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 6, right: 10),
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          S.gitnexusWikiTitle,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: DuckColors.fgPrimary,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          S.gitnexusWikiDesc,
                          style: TextStyle(
                            fontSize: 11.5,
                            color: DuckColors.fgMuted,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _statusPill(statusLabel, statusColor),
                            if (service.lastWikiAt != null)
                              _statusPill(
                                S.gitnexusWikiGeneratedAt(
                                  _formatDate(service.lastWikiAt!),
                                ),
                                DuckColors.fgMuted,
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (!workspaceOpen) ...[
                const SizedBox(height: 8),
                const Text(
                  S.gitnexusWikiNoWorkspace,
                  style: TextStyle(
                    fontSize: 11,
                    color: DuckColors.stateWarn,
                    height: 1.4,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 260,
                    child: TextField(
                      controller: modelController,
                      style: const TextStyle(fontSize: 12.5),
                      decoration: const InputDecoration(
                        labelText: S.gitnexusWikiModelLabel,
                        hintText: S.gitnexusWikiModelHint,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(child: _autoToggle()),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton.icon(
                    icon: running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.article_outlined, size: 16),
                    label: const Text(S.gitnexusWikiGenerate),
                    onPressed: canRun
                        ? () =>
                              service.generateWiki(model: modelController.text)
                        : null,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.stop, size: 16),
                    label: const Text(S.gitnexusWikiStop),
                    onPressed: running ? service.stopWiki : null,
                  ),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.folder_open_outlined, size: 16),
                    label: const Text(S.gitnexusWikiOpenFolder),
                    onPressed: workspaceOpen ? _openWikiFolder : null,
                  ),
                ],
              ),
              if (running || service.wikiOutputTail.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  S.gitnexusWikiOutputLabel,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: DuckColors.fgFaint,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 80),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DuckColors.bgDeepest,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                  ),
                  child: SelectableText(
                    service.wikiOutputTail.isEmpty
                        ? S.gitnexusWikiNoOutput
                        : service.wikiOutputTail,
                    style: const TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 11,
                      color: DuckColors.fgSubtle,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _autoToggle() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: const [
              Text(
                S.gitnexusWikiAuto,
                style: TextStyle(fontSize: 12.5, color: DuckColors.fgPrimary),
              ),
              SizedBox(height: 3),
              Text(
                S.gitnexusWikiAutoDesc,
                style: TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgMuted,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        Switch(
          value: autoWiki,
          onChanged: onAutoWikiChanged,
          activeThumbColor: DuckColors.accentCyan,
        ),
      ],
    );
  }

  (String, Color) _status() {
    return switch (service.wikiStatus) {
      GitNexusWikiStatus.idle => (S.gitnexusWikiIdle, DuckColors.fgSubtle),
      GitNexusWikiStatus.running => (
        S.gitnexusWikiRunning,
        DuckColors.accentCyan,
      ),
      GitNexusWikiStatus.generated => (
        S.gitnexusWikiGenerated,
        DuckColors.accentMint,
      ),
      GitNexusWikiStatus.failed => (
        S.gitnexusWikiFailed,
        DuckColors.stateError,
      ),
    };
  }

  Widget _statusPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Future<void> _openWikiFolder() async {
    final workspace = service.workspacePath;
    if (workspace == null || workspace.isEmpty) return;
    final path =
        '$workspace${Platform.pathSeparator}.gitnexus'
        '${Platform.pathSeparator}wiki';
    try {
      if (Platform.isWindows) {
        await Process.start('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.start('open', [path]);
      } else {
        await Process.start('xdg-open', [path]);
      }
    } catch (_) {
      // Best-effort folder reveal; the path is still visible in installed files.
    }
  }

  String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}
