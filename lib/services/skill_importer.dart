import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'lumen_workspace_config.dart';

/// One-shot fetch + write for skill markdown sourced from GitHub
/// (or any raw URL). Lives next to `WorkspaceSkillsService` rather
/// than inside it so the loader stays free of network concerns.
///
/// Accepted inputs (resolved by [resolveCandidates]):
///   - `owner/repo`                            → tries SKILL.md, skill.md, README.md at HEAD
///   - `https://github.com/owner/repo`         → same as above
///   - `https://github.com/owner/repo/blob/<ref>/path/to/SKILL.md`
///   - `https://github.com/owner/repo/tree/<ref>/dir`  → tries `<dir>/SKILL.md`
///   - `https://raw.githubusercontent.com/...` → fetched directly
///   - any `https://…` ending in `.md`        → fetched directly
///
/// On success returns a [SkillImportResult] with the resolved repo
/// label, the raw markdown, a slug, and the destination path the
/// caller can preview before committing the write via [commit].
class SkillImporter {
  SkillImporter({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// Expand a user-typed source into one or more raw URLs to try in
  /// order. The first one that returns 200 wins.
  static List<_Candidate> resolveCandidates(String input) {
    final raw = input.trim();
    if (raw.isEmpty) return const [];

    // Direct raw URL.
    if (raw.startsWith('https://raw.githubusercontent.com/')) {
      return [_Candidate(rawUrl: raw, repoLabel: _repoLabelFromRaw(raw))];
    }
    // Generic markdown URL.
    if (raw.startsWith('http') && raw.endsWith('.md')) {
      return [_Candidate(rawUrl: raw, repoLabel: Uri.tryParse(raw)?.host ?? raw)];
    }

    // GitHub blob URL → translate to raw.
    final blob = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/blob/([^/]+)/(.+)$',
    ).firstMatch(raw);
    if (blob != null) {
      final owner = blob.group(1)!;
      final repo = blob.group(2)!;
      final ref = blob.group(3)!;
      final path = blob.group(4)!;
      return [
        _Candidate(
          rawUrl: 'https://raw.githubusercontent.com/$owner/$repo/$ref/$path',
          repoLabel: '$owner/$repo',
          subPath: path,
        ),
      ];
    }

    // GitHub tree URL → try common skill filenames inside it.
    final tree = RegExp(
      r'^https?://github\.com/([^/]+)/([^/]+)/tree/([^/]+)(?:/(.*))?$',
    ).firstMatch(raw);
    if (tree != null) {
      final owner = tree.group(1)!;
      final repo = tree.group(2)!;
      final ref = tree.group(3)!;
      final dir = tree.group(4) ?? '';
      final base = 'https://raw.githubusercontent.com/$owner/$repo/$ref';
      return _commonNames
          .map((n) => _Candidate(
                rawUrl: dir.isEmpty ? '$base/$n' : '$base/$dir/$n',
                repoLabel: '$owner/$repo',
                subPath: dir.isEmpty ? n : '$dir/$n',
              ))
          .toList();
    }

    // Plain `owner/repo` or full repo URL.
    final repoOnly = RegExp(
      r'^(?:https?://github\.com/)?([^/\s]+)/([^/\s]+?)(?:\.git)?/?$',
    ).firstMatch(raw);
    if (repoOnly != null) {
      final owner = repoOnly.group(1)!;
      final repo = repoOnly.group(2)!;
      // HEAD resolves to the repo's default branch on raw.githubusercontent.
      final base = 'https://raw.githubusercontent.com/$owner/$repo/HEAD';
      return _commonNames
          .map((n) => _Candidate(
                rawUrl: '$base/$n',
                repoLabel: '$owner/$repo',
                subPath: n,
              ))
          .toList();
    }

    return const [];
  }

  /// Walk through [resolveCandidates] and return the first one that
  /// fetches OK and parses as a non-empty markdown document.
  Future<SkillImportResult> fetch(String input) async {
    final candidates = resolveCandidates(input);
    if (candidates.isEmpty) {
      throw const SkillImportException(
        'Could not parse the source — paste a GitHub repo URL '
        '(owner/repo) or a raw .md link.',
      );
    }

    Object? lastError;
    for (final c in candidates) {
      try {
        final res = await _client
            .get(Uri.parse(c.rawUrl))
            .timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) {
          lastError = 'HTTP ${res.statusCode}';
          continue;
        }
        final body = res.body;
        if (body.trim().isEmpty) {
          lastError = 'empty body';
          continue;
        }
        final slug = _slugFromCandidate(c, body);
        return SkillImportResult(
          repoLabel: c.repoLabel,
          sourceUrl: c.rawUrl,
          slug: slug,
          rawMarkdown: body,
        );
      } catch (e) {
        lastError = e;
        debugPrint('SkillImporter: ${c.rawUrl} → $e');
      }
    }
    throw SkillImportException(
      'No skill markdown found at that source (last error: $lastError).',
    );
  }

  /// Persist the imported skill under
  /// `<workspace>/.agents/skills/<slug>/SKILL.md`. Stamps an
  /// `imported_from:` frontmatter line if the source markdown does
  /// not already carry one — that is what powers the "imported from"
  /// badge in the skills list.
  ///
  /// Returns the path that was written so the UI can refresh +
  /// announce success.
  Future<File> commit({
    required String workspacePath,
    required SkillImportResult result,
    String? overrideSlug,
  }) async {
    final slug = (overrideSlug == null || overrideSlug.trim().isEmpty)
        ? result.slug
        : _sanitiseSlug(overrideSlug);
    await LumenWorkspaceConfig.ensureAgentsDir(workspacePath);
    final dir = Directory(
      p.join(LumenWorkspaceConfig.skillsDir(workspacePath).path, slug),
    );
    await dir.create(recursive: true);
    final outFile = File(p.join(dir.path, 'SKILL.md'));
    final content = _stampImportedFrom(
      result.rawMarkdown,
      repoLabel: result.repoLabel,
      sourceUrl: result.sourceUrl,
    );
    await outFile.writeAsString(content);
    return outFile;
  }

  void dispose() => _client.close();

  // ─── helpers ──────────────────────────────────────────────────

  static const _commonNames = [
    'SKILL.md',
    'skill.md',
    'Skill.md',
    'README.md',
  ];

  static String _repoLabelFromRaw(String rawUrl) {
    final m = RegExp(
      r'^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/',
    ).firstMatch(rawUrl);
    if (m == null) return rawUrl;
    return '${m.group(1)}/${m.group(2)}';
  }

  static String _slugFromCandidate(_Candidate c, String body) {
    // Prefer the H1 of the doc; fall back to the file name.
    final h1 = RegExp(r'^#\s+(.+)$', multiLine: true).firstMatch(body);
    final raw = h1?.group(1) ?? c.subPath ?? c.repoLabel;
    return _sanitiseSlug(raw);
  }

  static String _sanitiseSlug(String s) {
    final base = s
        .toLowerCase()
        .replaceAll(RegExp(r'\.[a-z0-9]+$'), '')
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return base.isEmpty ? 'imported-skill' : base;
  }

  /// If the source already has frontmatter, inject `imported_from:`
  /// and `source_url:` keys (when missing) without touching anything
  /// else. If it has none, prepend a minimal frontmatter block. The
  /// existing frontmatter parser in `WorkspaceSkillsService` reads
  /// any of `source` / `source_repo` / `imported_from` for the
  /// badge, so we use `imported_from:` for clarity.
  static String _stampImportedFrom(
    String md, {
    required String repoLabel,
    required String sourceUrl,
  }) {
    if (md.startsWith('---')) {
      final endIdx = md.indexOf('\n---', 3);
      if (endIdx > 0) {
        final fm = md.substring(3, endIdx);
        final hasImported = RegExp(
          r'^\s*(imported_from|source_repo|source)\s*:',
          multiLine: true,
        ).hasMatch(fm);
        if (hasImported) return md;
        final stamped = '---'
            '${fm.endsWith('\n') ? fm : '$fm\n'}'
            'imported_from: $repoLabel\n'
            'source_url: $sourceUrl\n'
            '${md.substring(endIdx)}';
        return stamped;
      }
    }
    return '---\n'
        'imported_from: $repoLabel\n'
        'source_url: $sourceUrl\n'
        '---\n\n$md';
  }
}

class _Candidate {
  final String rawUrl;
  final String repoLabel;
  final String? subPath;
  const _Candidate({
    required this.rawUrl,
    required this.repoLabel,
    this.subPath,
  });
}

@immutable
class SkillImportResult {
  final String repoLabel;
  final String sourceUrl;
  final String slug;
  final String rawMarkdown;
  const SkillImportResult({
    required this.repoLabel,
    required this.sourceUrl,
    required this.slug,
    required this.rawMarkdown,
  });
}

class SkillImportException implements Exception {
  final String message;
  const SkillImportException(this.message);
  @override
  String toString() => message;
}
