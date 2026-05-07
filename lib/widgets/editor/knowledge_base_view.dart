import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../services/kb_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'markdown_preview.dart';

/// Editor-tab view of the workspace knowledgebase.
///
/// Layout: a sticky header (title + path + actions) over a body that
/// flips between **Edit** (plain `TextField` over `KbService.read`)
/// and **Preview** (`MarkdownPreview`). Live-edit-with-side-by-side
/// preview was considered and rejected — most KB writes are bursty
/// (paste a paragraph, save) and a side-by-side renderer steals
/// horizontal real estate from the prose pane. The header tab toggle
/// is one click away.
///
/// Save model: explicit. The header shows a "Save" button that
/// flips disabled/enabled based on dirty state. We do NOT auto-save
/// on every keystroke because the file is the agent's persistent
/// memory and silent partial writes during typing would surface as
/// half-baked context in the next chat turn.
///
/// Summarize: opens a confirm dialog with input/output side by side
/// before overwriting. The user MUST click "Replace" — no silent
/// rewrites of a user-editable file (Shipwright's ship-blocker).
class KnowledgeBaseView extends StatefulWidget {
  const KnowledgeBaseView({super.key});

  @override
  State<KnowledgeBaseView> createState() => _KnowledgeBaseViewState();
}

enum _Mode { edit, preview }

class _KnowledgeBaseViewState extends State<KnowledgeBaseView> {
  final _ctrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  final _scroll = ScrollController();

  _Mode _mode = _Mode.edit;
  bool _loading = true;
  bool _saving = false;
  bool _summarizing = false;
  String _onDisk = '';
  String? _resolvedPath;
  String? _workspacePath;

  @override
  void initState() {
    super.initState();
    _load();
    _ctrl.addListener(() {
      if (mounted) setState(() {});
    });
    _searchCtrl.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _searchCtrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  bool get _dirty => _ctrl.text != _onDisk;

  Future<void> _load() async {
    final ws = context.read<AppState>().currentDirectory;
    if (ws == null) {
      setState(() => _loading = false);
      return;
    }
    _workspacePath = ws;
    final body = await KbService.read(ws);
    _resolvedPath = KbService.pathFor(ws);
    if (!mounted) return;
    setState(() {
      _onDisk = body;
      _ctrl.text = body;
      _loading = false;
    });
  }

  Future<void> _save() async {
    final ws = _workspacePath;
    if (ws == null) return;
    setState(() => _saving = true);
    final path = await KbService.write(ws, _ctrl.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (path != null) {
        _onDisk = _ctrl.text;
        _resolvedPath = path;
      }
    });
    if (path != null) {
      showDuckToast(context, 'Knowledgebase saved');
    } else {
      showDuckToast(context, 'Save failed — check log');
    }
  }

  Future<void> _summarize() async {
    final ws = _workspacePath;
    if (ws == null) return;
    final body = _ctrl.text.trim();
    if (body.isEmpty) {
      showDuckToast(context, 'Nothing to summarize yet');
      return;
    }
    final appState = context.read<AppState>();
    if (!await appState.chat.isReachable()) {
      if (!mounted) return;
      showDuckToast(context, 'No reachable model — check Settings → AI/Chat');
      return;
    }
    setState(() => _summarizing = true);
    try {
      final messages = KbService.buildSummarizeMessages(body);
      final summarized = await appState.chat.generateUtilityText(messages);
      if (!mounted) return;
      final cleaned = _stripModelPreamble(summarized.trim());
      if (cleaned.isEmpty || cleaned.startsWith('Error:')) {
        showDuckToast(
          context,
          cleaned.isEmpty ? 'Summarize returned empty' : cleaned,
        );
        return;
      }
      final replace = await _confirmReplace(body, cleaned);
      if (replace == true) {
        setState(() => _ctrl.text = cleaned);
        await _save();
      }
    } catch (e) {
      if (!mounted) return;
      showDuckToast(context, 'Summarize failed: $e');
    } finally {
      if (mounted) setState(() => _summarizing = false);
    }
  }

  /// Strips the most common LLM preambles ("Here is the compacted
  /// knowledgebase:", "```markdown", trailing "```"). The system
  /// prompt forbids them but lossy models still leak; we'd rather
  /// scrub here than surface them in the user's KB.
  String _stripModelPreamble(String s) {
    var out = s.trim();
    // Drop a leading fenced block wrapper if the entire body is one fence.
    final fence = RegExp(r'^```[a-zA-Z0-9_+-]*\n');
    final match = fence.firstMatch(out);
    if (match != null && out.endsWith('```')) {
      out = out.substring(match.end, out.length - 3).trimRight();
    }
    // Drop a single-line preface like "Here is the summary:".
    final firstNl = out.indexOf('\n');
    if (firstNl > 0 && firstNl < 120) {
      final firstLine = out.substring(0, firstNl).toLowerCase();
      if (firstLine.contains('summary') ||
          firstLine.contains('compacted') ||
          firstLine.contains('here is')) {
        out = out.substring(firstNl + 1).trimLeft();
      }
    }
    return out;
  }

  Future<bool?> _confirmReplace(String before, String after) async {
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => Dialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880, maxHeight: 640),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.auto_fix_high,
                      size: 16,
                      color: DuckColors.accentMint,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Replace knowledgebase with summary?',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${before.length} → ${after.length} chars',
                      style: const TextStyle(
                        fontSize: 11,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(child: _DiffPane(label: 'Current', text: before)),
                      const SizedBox(width: 8),
                      Expanded(child: _DiffPane(label: 'Summary', text: after)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(ctx).pop(false),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: DuckColors.accentMint,
                        foregroundColor: Colors.black,
                      ),
                      onPressed: () => Navigator.of(ctx).pop(true),
                      child: const Text('Replace'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: DuckColors.editorBg,
        alignment: Alignment.center,
        child: const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 1.6),
        ),
      );
    }
    if (_workspacePath == null) {
      return Container(
        color: DuckColors.editorBg,
        alignment: Alignment.center,
        child: const Text(
          'Open a workspace to use the knowledgebase.',
          style: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      );
    }
    return Container(
      color: DuckColors.editorBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(),
          const Divider(height: 0.5, color: DuckColors.glassSeam),
          Expanded(
            child: _mode == _Mode.edit ? _buildEditor() : _buildPreview(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    final dirty = _dirty;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          const Icon(
            Icons.menu_book_outlined,
            size: 16,
            color: DuckColors.accentDuck,
          ),
          const SizedBox(width: 8),
          const Text(
            'Knowledgebase',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              _resolvedPath ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.fgMuted,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (dirty)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: DuckColors.stateWarn.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
              child: const Text(
                'unsaved',
                style:
                    TextStyle(fontSize: 10.5, color: DuckColors.stateWarn),
              ),
            ),
          const Spacer(),
          SizedBox(
            width: 200,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search…',
                hintStyle:
                    const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
                prefixIcon: const Icon(
                  Icons.search,
                  size: 14,
                  color: DuckColors.fgMuted,
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                filled: true,
                fillColor: DuckColors.bgChip,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(
                      color: DuckColors.glassSeam, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(
                      color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          _ModeToggle(
            mode: _mode,
            onChanged: (m) => setState(() => _mode = m),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: _summarizing ? null : _summarize,
            icon: _summarizing
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.auto_fix_high, size: 14),
            label: const Text('Summarize',
                style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: (!dirty || _saving) ? null : _save,
            style: FilledButton.styleFrom(
              backgroundColor: DuckColors.accentMint,
              foregroundColor: Colors.black,
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: const Size(0, 32),
            ),
            child: _saving
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Text('Save', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildEditor() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: TextField(
        controller: _ctrl,
        scrollController: _scroll,
        maxLines: null,
        expands: true,
        textAlignVertical: TextAlignVertical.top,
        style: const TextStyle(
          fontSize: 13.5,
          height: 1.55,
          color: DuckColors.fgPrimary,
          fontFamily: 'monospace',
        ),
        decoration: const InputDecoration(
          border: InputBorder.none,
          isCollapsed: true,
          hintText:
              '# Knowledgebase\n\n## Project facts\n- …\n\n## Conventions\n- …\n\n## Recent learnings\n- …',
          hintStyle: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final query = _searchCtrl.text.trim().toLowerCase();
    final body = _ctrl.text;
    if (query.isNotEmpty) {
      // Cheap "search" affordance: filter to sections that match. We
      // don't try to be a real text search highlighter — the user can
      // flip back to Edit and Ctrl-F there.
      final filtered = _filterSections(body, query);
      return MarkdownPreview(text: filtered);
    }
    return MarkdownPreview(text: body);
  }

  String _filterSections(String md, String query) {
    final lines = md.split('\n');
    final sections = <List<String>>[];
    var current = <String>[];
    for (final line in lines) {
      if (line.startsWith('## ') || line.startsWith('# ')) {
        if (current.isNotEmpty) sections.add(current);
        current = [line];
      } else {
        current.add(line);
      }
    }
    if (current.isNotEmpty) sections.add(current);
    final hits = sections
        .where((s) => s.join('\n').toLowerCase().contains(query))
        .toList();
    if (hits.isEmpty) return '_No sections match "$query"._';
    return hits.map((s) => s.join('\n')).join('\n\n');
  }
}

class _ModeToggle extends StatelessWidget {
  final _Mode mode;
  final ValueChanged<_Mode> onChanged;
  const _ModeToggle({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      padding: const EdgeInsets.all(2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final m in _Mode.values)
            InkWell(
              onTap: () => onChanged(m),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: mode == m
                      ? DuckColors.bgRaisedHi
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: Text(
                  m == _Mode.edit ? 'Edit' : 'Preview',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: mode == m
                        ? DuckColors.fgPrimary
                        : DuckColors.fgMuted,
                    fontWeight:
                        mode == m ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DiffPane extends StatelessWidget {
  final String label;
  final String text;
  const _DiffPane({required this.label, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(
                text,
                style: const TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgPrimary,
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
