import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/wiki_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'markdown_preview.dart';

/// Two-tier wiki view used as the editor pane for the wiki sentinel tab.
///
/// **Listing mode** (default): shows all wiki pages as cards with title,
/// snippet, and last-modified. Header has New Page, Generate Wiki, and
/// search. Clicking a card switches to page-editor mode.
///
/// **Page-editor mode**: breadcrumb back-button, edit/preview toggle,
/// save, delete, summarize — same affordances as the old single-file
/// KnowledgeBaseView but scoped to one `.agents/wiki/<slug>.md` page.
class WikiView extends StatefulWidget {
  const WikiView({super.key});

  @override
  State<WikiView> createState() => _WikiViewState();
}

class _WikiViewState extends State<WikiView> {
  String? _workspacePath;
  bool _loading = true;
  List<WikiPage> _pages = [];
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();

  // Page editor state
  WikiPage? _activePage;
  final _editCtrl = TextEditingController();
  final _editScroll = ScrollController();
  _PageMode _pageMode = _PageMode.edit;
  bool _pageDirty = false;
  String _pageOnDisk = '';
  bool _saving = false;
  bool _generating = false;

  // External-write listener
  VoidCallback? _writeListener;

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      if (mounted) setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
    _editCtrl.addListener(_onEditChanged);
    _loadPages();

    _writeListener = () {
      if (mounted && _activePage == null) _loadPages();
    };
    WikiService.writes.addListener(_writeListener!);
  }

  void _onEditChanged() {
    final dirty = _editCtrl.text != _pageOnDisk;
    if (dirty != _pageDirty && mounted) {
      setState(() => _pageDirty = dirty);
    }
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _editCtrl.removeListener(_onEditChanged);
    _editCtrl.dispose();
    _editScroll.dispose();
    if (_writeListener != null) {
      WikiService.writes.removeListener(_writeListener!);
    }
    super.dispose();
  }

  // ------------------------------------------------------------------
  // Data loading
  // ------------------------------------------------------------------

  Future<void> _loadPages() async {
    final ws = context.read<AppState>().currentDirectory;
    if (ws == null) {
      setState(() => _loading = false);
      return;
    }
    _workspacePath = ws;

    // Auto-migrate from old knowledgebase on first open
    final migrated = await WikiService.migrateFromKnowledgebase(ws);
    if (migrated > 0 && mounted) {
      showDuckToast(context, S.wikiMigrated);
    }

    final pages = await WikiService.listPages(ws);
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _loading = false;
    });
  }

  Future<void> _openPage(WikiPage page) async {
    final content = await WikiService.readPage(_workspacePath!, page.slug);
    if (!mounted) return;
    setState(() {
      _activePage = page;
      _pageOnDisk = content;
      _editCtrl.text = content;
      _pageDirty = false;
      _pageMode = _PageMode.edit;
    });
  }

  void _backToList() {
    setState(() {
      _activePage = null;
      _pageOnDisk = '';
      _editCtrl.text = '';
      _pageDirty = false;
    });
    _loadPages();
  }

  // ------------------------------------------------------------------
  // Page CRUD
  // ------------------------------------------------------------------

  Future<void> _createPage() async {
    final ws = _workspacePath;
    if (ws == null) return;

    var slug = S.wikiNewPageSlug;
    var n = 1;
    final existing = _pages.map((p) => p.slug).toSet();
    while (existing.contains(slug)) {
      slug = '${S.wikiNewPageSlug}-${++n}';
    }

    final path = await WikiService.writePage(ws, slug, S.wikiNewPageDefaultTitle);
    if (path == null) {
      if (mounted) showDuckToast(context, S.wikiSaveFailed);
      return;
    }
    if (mounted) showDuckToast(context, S.wikiCreated);
    await _loadPages();
    final created = _pages.firstWhere(
      (p) => p.slug == slug,
      orElse: () => _pages.first,
    );
    await _openPage(created);
  }

  Future<void> _savePage() async {
    final ws = _workspacePath;
    final page = _activePage;
    if (ws == null || page == null) return;

    setState(() => _saving = true);
    final path = await WikiService.writePage(ws, page.slug, _editCtrl.text);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (path != null) {
        _pageOnDisk = _editCtrl.text;
        _pageDirty = false;
      }
    });
    showDuckToast(context, path != null ? S.wikiSaved : S.wikiSaveFailed);
  }

  Future<void> _deletePage() async {
    final ws = _workspacePath;
    final page = _activePage;
    if (ws == null || page == null) return;

    final confirmed = await showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
        title: Text(
          S.wikiDeletePageTitle,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: DuckColors.fgPrimary),
        ),
        content: Text(
          S.wikiDeletePageBody(page.title),
          style: const TextStyle(fontSize: 13, color: DuckColors.fgMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(S.cancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: DuckColors.stateWarn,
              foregroundColor: Colors.black,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(S.delete),
          ),
        ],
      ),
    );

    if (confirmed != true) return;
    final ok = await WikiService.deletePage(ws, page.slug);
    if (!mounted) return;
    showDuckToast(context, ok ? S.wikiDeleted : S.wikiDeleteFailed);
    if (ok) _backToList();
  }

  // ------------------------------------------------------------------
  // Generate wiki
  // ------------------------------------------------------------------

  Future<void> _generateWiki() async {
    final ws = _workspacePath;
    if (ws == null) return;

    final appState = context.read<AppState>();
    if (!await appState.chat.isReachable()) {
      if (!mounted) return;
      showDuckToast(context, S.wikiGenerateNoModel);
      return;
    }

    setState(() => _generating = true);
    try {
      final tree = await _buildWorkspaceTree(ws);
      final samples = await _collectKeySamples(ws);

      final messages = WikiService.buildGenerateMessages(
        treeOutput: tree,
        fileSamples: samples,
      );
      final raw = await appState.chat.generateUtilityText(messages);
      if (!mounted) return;

      final pages = _parseGeneratedPages(raw.trim());
      if (pages.isEmpty) {
        showDuckToast(context, S.wikiGenerateFailed);
        return;
      }

      for (final entry in pages) {
        await WikiService.writePage(ws, entry.slug, entry.content);
      }
      if (!mounted) return;
      showDuckToast(context, S.wikiGenerateSuccess);
      await _loadPages();
    } catch (e) {
      if (!mounted) return;
      debugPrint('WikiView._generateWiki: $e');
      showDuckToast(context, S.wikiGenerateFailed);
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  Future<String> _buildWorkspaceTree(String ws) async {
    final buf = StringBuffer();
    final rootDir = Directory(ws);
    await _walkTree(rootDir, ws, buf, 0, maxDepth: 4);
    return buf.toString();
  }

  static const _ignoreDirs = {
    '.git', '.lumen', 'node_modules', '.dart_tool', 'build',
    '__pycache__', '.venv', 'venv', '.idea', '.vs', '.vscode',
    'dist', 'target', '.agents',
  };

  Future<void> _walkTree(
    Directory dir,
    String root,
    StringBuffer buf,
    int depth, {
    int maxDepth = 4,
  }) async {
    if (depth > maxDepth) return;
    try {
      final entries = await dir.list().toList();
      entries.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      for (final entity in entries) {
        final name = p.basename(entity.path);
        if (name.startsWith('.') && depth == 0 && _ignoreDirs.contains(name)) continue;
        if (_ignoreDirs.contains(name)) continue;

        final indent = '  ' * depth;
        if (entity is Directory) {
          buf.writeln('$indent$name/');
          await _walkTree(entity, root, buf, depth + 1, maxDepth: maxDepth);
        } else if (entity is File) {
          buf.writeln('$indent$name');
        }
      }
    } catch (_) {}
  }

  Future<Map<String, String>> _collectKeySamples(String ws) async {
    final samples = <String, String>{};
    final candidates = [
      'README.md', 'readme.md', 'README.rst',
      'pubspec.yaml', 'package.json', 'Cargo.toml', 'pyproject.toml',
      'requirements.txt', 'go.mod', 'pom.xml', 'build.gradle',
      'Makefile', 'CMakeLists.txt', 'docker-compose.yml', 'Dockerfile',
      '.lumen/rules.md',
    ];

    for (final name in candidates) {
      final f = File(p.join(ws, name));
      if (await f.exists()) {
        try {
          final content = await f.readAsString();
          final trimmed = content.length > 3000
              ? '${content.substring(0, 3000)}\n... (truncated)'
              : content;
          samples[name] = trimmed;
        } catch (_) {}
      }
      if (samples.length >= 5) break;
    }
    return samples;
  }

  List<({String slug, String content})> _parseGeneratedPages(String raw) {
    var cleaned = raw;
    final fenceMatch = RegExp(r'^```[a-zA-Z]*\n').firstMatch(cleaned);
    if (fenceMatch != null && cleaned.endsWith('```')) {
      cleaned = cleaned.substring(fenceMatch.end, cleaned.length - 3).trim();
    }

    try {
      final decoded = jsonDecode(cleaned);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .where((m) => m['slug'] is String && m['content'] is String)
            .map((m) => (
                  slug: m['slug'] as String,
                  content: m['content'] as String,
                ))
            .toList();
      }
    } catch (e) {
      debugPrint('WikiView._parseGeneratedPages: JSON parse failed: $e');
    }
    return [];
  }

  // ------------------------------------------------------------------
  // Summarize (per-page, same as old KB)
  // ------------------------------------------------------------------

  Future<void> _summarizePage() async {
    final ws = _workspacePath;
    final page = _activePage;
    if (ws == null || page == null) return;

    final body = _editCtrl.text.trim();
    if (body.isEmpty) return;

    final appState = context.read<AppState>();
    if (!await appState.chat.isReachable()) {
      if (!mounted) return;
      showDuckToast(context, S.wikiGenerateNoModel);
      return;
    }

    try {
      final messages = [
        {
          'role': 'system',
          'content':
              'You are compacting a wiki page. Produce a SHORTER markdown '
              'page with the same shape. Preserve every concrete fact. '
              'Output markdown ONLY — no commentary.'
        },
        {
          'role': 'user',
          'content':
              'Compact this wiki page, returning markdown only:\n\n'
              '```markdown\n$body\n```',
        },
      ];
      final summarized = await appState.chat.generateUtilityText(messages);
      if (!mounted) return;
      final cleaned = _stripModelPreamble(summarized.trim());
      if (cleaned.isNotEmpty) {
        setState(() {
          _editCtrl.text = cleaned;
        });
      }
    } catch (e) {
      if (!mounted) return;
      debugPrint('WikiView._summarizePage: $e');
    }
  }

  String _stripModelPreamble(String s) {
    var out = s.trim();
    final fence = RegExp(r'^```[a-zA-Z0-9_+-]*\n');
    final match = fence.firstMatch(out);
    if (match != null && out.endsWith('```')) {
      out = out.substring(match.end, out.length - 3).trimRight();
    }
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

  // ------------------------------------------------------------------
  // Build
  // ------------------------------------------------------------------

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
          S.wikiNoWorkspace,
          style: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      );
    }

    if (_activePage != null) {
      return _buildPageEditor();
    }

    return _buildListing();
  }

  // ------------------------------------------------------------------
  // Listing mode
  // ------------------------------------------------------------------

  Widget _buildListing() {
    final filtered = _searchQuery.isEmpty
        ? _pages
        : _pages.where((p) {
            return p.title.toLowerCase().contains(_searchQuery) ||
                p.slug.toLowerCase().contains(_searchQuery) ||
                p.snippet.toLowerCase().contains(_searchQuery);
          }).toList();

    return Container(
      color: DuckColors.editorBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildListingHeader(),
          const Divider(height: 0.5, color: DuckColors.glassSeam),
          Expanded(
            child: filtered.isEmpty ? _buildEmptyState() : _buildPageGrid(filtered),
          ),
        ],
      ),
    );
  }

  Widget _buildListingHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
      child: Row(
        children: [
          const Icon(Icons.menu_book_outlined, size: 16, color: DuckColors.accentDuck),
          const SizedBox(width: 8),
          const Text(
            S.wikiTitle,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            S.wikiPageCount(_pages.length),
            style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
          ),
          const Spacer(),
          SizedBox(
            width: 200,
            child: TextField(
              controller: _searchCtrl,
              style: const TextStyle(fontSize: 12, color: DuckColors.fgPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: S.wikiSearch,
                hintStyle: const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
                prefixIcon: const Icon(Icons.search, size: 14, color: DuckColors.fgMuted),
                contentPadding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                filled: true,
                fillColor: DuckColors.bgChip,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  borderSide: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: _generating ? null : _generateWiki,
            icon: _generating
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.auto_awesome, size: 14),
            label: Text(
              _generating ? S.wikiGenerating : S.wikiGenerateWiki,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: _createPage,
            icon: const Icon(Icons.add, size: 14),
            label: const Text(S.wikiNewPage, style: TextStyle(fontSize: 12)),
            style: FilledButton.styleFrom(
              backgroundColor: DuckColors.accentMint,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: const Size(0, 32),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.menu_book_outlined,
            size: 48,
            color: DuckColors.fgMuted.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          const Text(
            S.wikiEmptyTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            S.wikiEmptySubtitle,
            style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: _generating ? null : _generateWiki,
                icon: _generating
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.5),
                      )
                    : const Icon(Icons.auto_awesome, size: 14),
                label: Text(
                  _generating ? S.wikiGenerating : S.wikiGenerateWiki,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _createPage,
                icon: const Icon(Icons.add, size: 14),
                label: const Text(S.wikiNewPage, style: TextStyle(fontSize: 12)),
                style: FilledButton.styleFrom(
                  backgroundColor: DuckColors.accentMint,
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  minimumSize: const Size(0, 32),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPageGrid(List<WikiPage> pages) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = constraints.maxWidth > 900
            ? 3
            : constraints.maxWidth > 550
                ? 2
                : 1;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 2.4,
          ),
          itemCount: pages.length,
          itemBuilder: (context, index) => _WikiPageCard(
            page: pages[index],
            onTap: () => _openPage(pages[index]),
          ),
        );
      },
    );
  }

  // ------------------------------------------------------------------
  // Page editor mode
  // ------------------------------------------------------------------

  Widget _buildPageEditor() {
    return Container(
      color: DuckColors.editorBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildPageEditorHeader(),
          const Divider(height: 0.5, color: DuckColors.glassSeam),
          Expanded(
            child: _pageMode == _PageMode.edit
                ? _buildPageEditBody()
                : _buildPagePreviewBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildPageEditorHeader() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, size: 16, color: DuckColors.fgMuted),
            tooltip: S.wikiBackToList,
            onPressed: _backToList,
            splashRadius: 14,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          const SizedBox(width: 4),
          const Icon(Icons.menu_book_outlined, size: 14, color: DuckColors.accentDuck),
          const SizedBox(width: 6),
          InkWell(
            onTap: _backToList,
            child: const Text(
              S.wikiTitle,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          ),
          const SizedBox(width: 4),
          const Text('/', style: TextStyle(fontSize: 12, color: DuckColors.fgMuted)),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              _activePage!.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          if (_pageDirty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: DuckColors.stateWarn.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
              child: const Text(
                'unsaved',
                style: TextStyle(fontSize: 10.5, color: DuckColors.stateWarn),
              ),
            ),
          const Spacer(),
          _PageModeToggle(
            mode: _pageMode,
            onChanged: (m) => setState(() => _pageMode = m),
          ),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: _summarizePage,
            icon: const Icon(Icons.auto_fix_high, size: 14),
            label: const Text(S.wikiSummarize, style: TextStyle(fontSize: 12)),
          ),
          const SizedBox(width: 6),
          TextButton.icon(
            onPressed: _deletePage,
            icon: const Icon(Icons.delete_outline, size: 14),
            label: const Text(S.delete, style: TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(foregroundColor: DuckColors.stateWarn),
          ),
          const SizedBox(width: 6),
          FilledButton(
            onPressed: (!_pageDirty || _saving) ? null : _savePage,
            style: FilledButton.styleFrom(
              backgroundColor: DuckColors.accentMint,
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              minimumSize: const Size(0, 32),
            ),
            child: _saving
                ? const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Text(S.save, style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _buildPageEditBody() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: TextField(
        controller: _editCtrl,
        scrollController: _editScroll,
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
          hintText: '# Page Title\n\nWrite your content here…',
          hintStyle: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildPagePreviewBody() {
    return MarkdownPreview(text: _editCtrl.text);
  }
}

// ====================================================================
// Supporting widgets
// ====================================================================

enum _PageMode { edit, preview }

class _PageModeToggle extends StatelessWidget {
  final _PageMode mode;
  final ValueChanged<_PageMode> onChanged;
  const _PageModeToggle({required this.mode, required this.onChanged});

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
          for (final m in _PageMode.values)
            InkWell(
              onTap: () => onChanged(m),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: mode == m ? DuckColors.bgRaisedHi : Colors.transparent,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                ),
                child: Text(
                  m == _PageMode.edit ? S.wikiEdit : S.wikiPreview,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: mode == m ? DuckColors.fgPrimary : DuckColors.fgMuted,
                    fontWeight: mode == m ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _WikiPageCard extends StatefulWidget {
  final WikiPage page;
  final VoidCallback onTap;
  const _WikiPageCard({required this.page, required this.onTap});

  @override
  State<_WikiPageCard> createState() => _WikiPageCardState();
}

class _WikiPageCardState extends State<_WikiPageCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final page = widget.page;
    final ago = _timeAgo(page.lastModified);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _hovered ? DuckColors.bgRaisedHi : DuckColors.bgRaised,
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border.all(
              color: _hovered
                  ? DuckColors.accentMint.withValues(alpha: 0.3)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.description_outlined, size: 14, color: DuckColors.accentMint),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      page.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: Text(
                  page.snippet,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.fgMuted,
                    height: 1.45,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text(
                    S.wikiLastModified(ago),
                    style: const TextStyle(fontSize: 10, color: DuckColors.fgMuted),
                  ),
                  const Spacer(),
                  Text(
                    '${page.slug}.md',
                    style: const TextStyle(
                      fontSize: 10,
                      color: DuckColors.fgMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  static String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
