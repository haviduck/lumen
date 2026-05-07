import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../services/skill_importer.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Modal dialog that fetches a skill markdown from GitHub (or any
/// raw URL), shows a preview, and writes it to
/// `<workspace>/.agents/skills/<slug>/SKILL.md` on confirm.
///
/// One-shot only — no caching of the source repo, no "update from
/// upstream" affordance. The brief explicitly leaves cache+update as
/// a v1.1 follow-up; a fetched skill is just a file the user owns
/// after import (they can edit it freely without losing changes).
class SkillImportDialog extends StatefulWidget {
  const SkillImportDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (_) => const SkillImportDialog(),
    );
  }

  @override
  State<SkillImportDialog> createState() => _SkillImportDialogState();
}

class _SkillImportDialogState extends State<SkillImportDialog> {
  final TextEditingController _input = TextEditingController();
  final TextEditingController _slug = TextEditingController();
  final SkillImporter _importer = SkillImporter();

  bool _busy = false;
  String? _error;
  SkillImportResult? _preview;

  @override
  void dispose() {
    _input.dispose();
    _slug.dispose();
    _importer.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    final src = _input.text.trim();
    if (src.isEmpty) {
      setState(() => _error = 'Paste a GitHub URL or owner/repo first.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _preview = null;
    });
    try {
      final result = await _importer.fetch(src);
      if (!mounted) return;
      setState(() {
        _preview = result;
        _slug.text = result.slug;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  Future<void> _confirm() async {
    final preview = _preview;
    if (preview == null) return;
    final app = context.read<AppState>();
    final ws = app.currentDirectory;
    if (ws == null) {
      setState(() => _error = 'Open a workspace before importing skills.');
      return;
    }
    setState(() => _busy = true);
    try {
      await _importer.commit(
        workspacePath: ws,
        result: preview,
        overrideSlug: _slug.text,
      );
      await app.workspaceSkills.refresh();
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported "${preview.repoLabel}"')),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    return Dialog(
      backgroundColor: DuckColors.bgDeeper,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 600),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Import Skill',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.fgPrimary,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                'Paste a GitHub repo (owner/repo), a blob/tree URL, or a '
                'raw .md link. Lumen will look for SKILL.md / skill.md / '
                'README.md when only a repo is given.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgMuted,
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _input,
                autofocus: true,
                style: const TextStyle(fontSize: 12.5),
                decoration: const InputDecoration(
                  hintText: 'anthropics/skills  or  https://github.com/owner/repo/blob/main/SKILL.md',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onSubmitted: (_) => _busy ? null : _fetch(),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : _fetch,
                    icon: const Icon(Icons.cloud_download_outlined, size: 14),
                    label: const Text('Fetch'),
                  ),
                  const SizedBox(width: 8),
                  if (_busy)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.stateError,
                  ),
                ),
              ],
              if (preview != null) ...[
                const SizedBox(height: 14),
                Text(
                  'Source: ${preview.repoLabel}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _slug,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    labelText: 'Folder name (slug)',
                    helperText: 'Written to .agents/skills/<slug>/SKILL.md',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  height: 220,
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: DuckColors.bgDeepest,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    border: Border.all(
                      color: DuckColors.glassSeam,
                      width: 0.5,
                    ),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      preview.rawMarkdown,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: DuckColors.fgMuted,
                        height: 1.4,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: (_busy || preview == null) ? null : _confirm,
                    child: const Text('Import'),
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
