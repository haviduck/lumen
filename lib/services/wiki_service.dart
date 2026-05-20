import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'kb_service.dart';
import 'lumen_workspace_config.dart';

/// A single wiki page on disk.
@immutable
class WikiPage {
  final String slug;
  final String title;
  final String filePath;
  final DateTime lastModified;
  final int sizeBytes;
  final String snippet;

  const WikiPage({
    required this.slug,
    required this.title,
    required this.filePath,
    required this.lastModified,
    required this.sizeBytes,
    this.snippet = '',
  });
}

/// Payload published on [WikiService.writes] after a wiki page is
/// created, updated, or deleted. Carries enough context for listeners
/// to refresh without a follow-up disk scan.
@immutable
class WikiWriteEvent {
  final String workspacePath;
  final String slug;
  final DateTime at;
  const WikiWriteEvent({
    required this.workspacePath,
    required this.slug,
    required this.at,
  });
}

/// Read/write/list/migrate support for the project wiki — the
/// directory of markdown files at `<workspace>/.agents/wiki/`.
///
/// Each `.md` file under the wiki dir is a standalone page. The slug
/// is the filename without extension (`architecture.md` -> `architecture`).
/// Page titles are derived from the first H1 heading if present,
/// otherwise from the slug.
class WikiService {
  /// Broadcast notifier for wiki write events. Static so non-instance
  /// callers (tool_registry, agent file tools) can publish without a
  /// service handle.
  static final ValueNotifier<WikiWriteEvent?> writes =
      ValueNotifier<WikiWriteEvent?>(null);

  static void _emit(String workspacePath, String slug) {
    writes.value = WikiWriteEvent(
      workspacePath: workspacePath,
      slug: slug,
      at: DateTime.now(),
    );
  }

  /// Resolved wiki directory path (no existence guarantee).
  static String dirPathFor(String workspacePath) =>
      p.normalize(LumenWorkspaceConfig.wikiDir(workspacePath).path);

  /// Resolved path for a specific page (no existence guarantee).
  static String pagePathFor(String workspacePath, String slug) =>
      p.normalize(p.join(dirPathFor(workspacePath), '$slug.md'));

  /// Whether [filePath] falls under the wiki directory for [workspacePath].
  static bool isWikiFile(String workspacePath, String filePath) {
    final wikiRoot = dirPathFor(workspacePath);
    final normalized = p.normalize(filePath);
    return p.isWithin(wikiRoot, normalized) && normalized.endsWith('.md');
  }

  /// List all wiki pages sorted by last-modified (newest first).
  static Future<List<WikiPage>> listPages(String workspacePath) async {
    final dir = LumenWorkspaceConfig.wikiDir(workspacePath);
    if (!await dir.exists()) return const [];

    final pages = <WikiPage>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.md')) continue;

      final slug = name.substring(0, name.length - 3);
      try {
        final stat = await entity.stat();
        final content = await entity.readAsString();
        pages.add(WikiPage(
          slug: slug,
          title: _extractTitle(content, slug),
          filePath: p.normalize(entity.path),
          lastModified: stat.modified,
          sizeBytes: stat.size,
          snippet: _extractSnippet(content),
        ));
      } catch (e) {
        debugPrint('WikiService.listPages: skipping $name: $e');
      }
    }

    pages.sort((a, b) => b.lastModified.compareTo(a.lastModified));
    return pages;
  }

  /// Read a single page's content. Returns empty string if missing.
  static Future<String> readPage(String workspacePath, String slug) async {
    try {
      final f = File(pagePathFor(workspacePath, slug));
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      debugPrint('WikiService.readPage($slug): $e');
      return '';
    }
  }

  /// Write (create or update) a wiki page. Returns the resolved file
  /// path on success, null on failure.
  static Future<String?> writePage(
    String workspacePath,
    String slug,
    String content,
  ) async {
    try {
      await LumenWorkspaceConfig.ensureWikiDir(workspacePath);
      final f = File(pagePathFor(workspacePath, slug));
      await f.writeAsString(content);
      _emit(workspacePath, slug);
      return f.path;
    } catch (e) {
      debugPrint('WikiService.writePage($slug): $e');
      return null;
    }
  }

  /// Delete a wiki page. Returns true on success.
  static Future<bool> deletePage(String workspacePath, String slug) async {
    try {
      final f = File(pagePathFor(workspacePath, slug));
      if (await f.exists()) {
        await f.delete();
        _emit(workspacePath, slug);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('WikiService.deletePage($slug): $e');
      return false;
    }
  }

  /// Rename a wiki page (slug change). Returns the new path on success.
  static Future<String?> renamePage(
    String workspacePath,
    String oldSlug,
    String newSlug,
  ) async {
    try {
      final oldFile = File(pagePathFor(workspacePath, oldSlug));
      if (!await oldFile.exists()) return null;
      final newPath = pagePathFor(workspacePath, newSlug);
      await oldFile.rename(newPath);
      _emit(workspacePath, newSlug);
      return newPath;
    } catch (e) {
      debugPrint('WikiService.renamePage($oldSlug -> $newSlug): $e');
      return null;
    }
  }

  /// Hook for non-[writePage] writers (the agent's generic file tools
  /// in `tool_registry.dart`). Call after any `writeAsString` whose
  /// target *might* be under the wiki directory; this method is a
  /// no-op when [filePath] does not resolve to a wiki page.
  static void maybeNotifyExternalWrite(
    String workspacePath,
    String filePath,
  ) {
    if (!isWikiFile(workspacePath, filePath)) return;
    final slug = p.basenameWithoutExtension(filePath);
    _emit(workspacePath, slug);
  }

  // ------------------------------------------------------------------
  // Migration from single-file knowledgebase
  // ------------------------------------------------------------------

  /// One-shot migration: if `.agents/knowledgebase.md` exists and
  /// `.agents/wiki/` is empty or absent, splits the KB by H2
  /// headings into separate wiki pages. Falls back to a single
  /// `overview.md` if parsing yields nothing useful.
  ///
  /// Returns the number of pages created, or 0 if migration was
  /// skipped (wiki already has content, or no KB file).
  static Future<int> migrateFromKnowledgebase(String workspacePath) async {
    final wikiDir = LumenWorkspaceConfig.wikiDir(workspacePath);
    if (await wikiDir.exists()) {
      final existing = await wikiDir
          .list()
          .where((e) => e is File && e.path.endsWith('.md'))
          .length;
      if (existing > 0) return 0;
    }

    final kbContent = await KbService.read(workspacePath);
    if (kbContent.trim().isEmpty) return 0;

    await LumenWorkspaceConfig.ensureWikiDir(workspacePath);

    final sections = _splitByHeadings(kbContent);
    if (sections.isEmpty) {
      await writePage(workspacePath, 'overview', kbContent);
      return 1;
    }

    var count = 0;
    for (final entry in sections.entries) {
      await writePage(workspacePath, entry.key, entry.value);
      count++;
    }
    return count;
  }

  /// Split markdown content by H2 (`## `) headings into a map of
  /// slug -> content. Preamble before the first H2 goes into `overview`.
  static Map<String, String> _splitByHeadings(String markdown) {
    final lines = markdown.split('\n');
    final result = <String, String>{};
    var currentSlug = 'overview';
    var currentLines = <String>[];

    for (final line in lines) {
      if (line.startsWith('## ')) {
        if (currentLines.isNotEmpty) {
          final body = currentLines.join('\n').trim();
          if (body.isNotEmpty) result[currentSlug] = body;
        }
        final heading = line.substring(3).trim();
        currentSlug = _slugify(heading);
        currentLines = ['# $heading', ''];
      } else if (line.startsWith('# ') && currentLines.isEmpty) {
        currentLines.add(line);
      } else {
        currentLines.add(line);
      }
    }

    if (currentLines.isNotEmpty) {
      final body = currentLines.join('\n').trim();
      if (body.isNotEmpty) result[currentSlug] = body;
    }

    return result;
  }

  /// Convert a heading string to a filename-safe slug.
  static String _slugify(String heading) {
    return heading
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\s_-]'), '')
        .replaceAll(RegExp(r'\s+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
  }

  /// Extract the page title from the first H1 heading, falling back
  /// to a humanized version of the slug.
  static String _extractTitle(String content, String fallbackSlug) {
    final match = RegExp(r'^# (.+)$', multiLine: true).firstMatch(content);
    if (match != null) return match.group(1)!.trim();
    return fallbackSlug
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .replaceAllMapped(
          RegExp(r'(^|\s)(\w)'),
          (m) => '${m.group(1)}${m.group(2)!.toUpperCase()}',
        );
  }

  /// Extract a short plaintext snippet (first ~150 chars of body
  /// text, skipping headings and blank lines).
  static String _extractSnippet(String content) {
    final lines = content.split('\n');
    final body = StringBuffer();
    for (final line in lines) {
      if (line.startsWith('#')) continue;
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final clean = trimmed.startsWith('- ') ? trimmed.substring(2) : trimmed;
      if (body.isNotEmpty) body.write(' ');
      body.write(clean);
      if (body.length >= 150) break;
    }
    final s = body.toString();
    return s.length > 150 ? '${s.substring(0, 147)}...' : s;
  }

  // ------------------------------------------------------------------
  // Generate wiki prompt
  // ------------------------------------------------------------------

  static const String generateSystemPrompt =
      '''You are generating a project wiki from a codebase analysis.

Analyze the provided workspace tree and file samples, then produce a set of
focused wiki pages. Each page covers one topic.

OUTPUT FORMAT — return a single JSON array. Each element:
{
  "slug": "filename-without-extension",
  "title": "Human Readable Title",
  "content": "Full markdown body of the page (use # Title as first line)"
}

RULES:
- Produce 3–8 pages depending on project complexity.
- Common topics: architecture, setup, conventions, api, data-model, testing,
  deployment. Only create pages that have real content to fill.
- Each page starts with `# Title` matching the title field.
- Content should be concise, scannable (bullets, short paragraphs), and
  factual — only state what the code actually shows.
- Do NOT invent facts. If you can't determine something from the provided
  context, omit it rather than guessing.
- Output the JSON array ONLY — no commentary, no fences, no preface.''';

  /// Build messages for the generate-wiki utility call. [treeOutput]
  /// is a `tree` or `find` listing of the workspace, and [fileSamples]
  /// is a map of path -> content for key files the caller selected.
  static List<Map<String, dynamic>> buildGenerateMessages({
    required String treeOutput,
    required Map<String, String> fileSamples,
  }) {
    final samplesBlock = fileSamples.entries
        .map((e) => '--- ${e.key} ---\n${e.value}')
        .join('\n\n');

    return [
      {'role': 'system', 'content': generateSystemPrompt},
      {
        'role': 'user',
        'content':
            'Generate a wiki for this project.\n\n'
            'WORKSPACE TREE:\n```\n$treeOutput\n```\n\n'
            'KEY FILES:\n$samplesBlock',
      },
    ];
  }
}
