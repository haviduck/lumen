import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'lumen_workspace_config.dart';

/// File-based handoff system: lets a chat write a structured "what I was
/// doing / what's next" artifact under `.lumen/handoff/<slug>.md` so a
/// fresh chat can pick up where the previous one left off.
///
/// The slash-command (`/handoff`) writes the file via the agent's
/// `CREATE_FILE` tool. The receiving rule lives in `.lumen/rules.md`
/// and is auto-installed on first use so the next chat actually checks
/// the directory at session start.
///
/// Status lifecycle: `pending` → `received`. We deliberately keep this
/// minimal — no queue/supersede choreography, just status updates.
class HandoffService {
  static const String _handoffDirName = 'handoff';

  /// Marker comment used to detect whether the receive rule is already
  /// installed in `.lumen/rules.md`. Idempotent — the file is only
  /// appended to once per workspace, no matter how many handoffs are
  /// written.
  static const String ruleMarker = '<!-- LUMEN_HANDOFF_RULE -->';

  /// Front-matter section appended to a handoff file so the receiving
  /// rule can parse status without a YAML dep. Keep it strict and
  /// boring — markdown-parser-tolerant.
  static const String frontMatterFence = '---';

  /// Rule block that gets auto-installed into `.lumen/rules.md` on
  /// first `/handoff`. The marker comment makes the install idempotent.
  static const String ruleBlock =
      '''$ruleMarker
## Handoffs (chat-to-chat continuity)

At the start of every chat, list the contents of `.lumen/handoff/` (if it
exists). For every file whose YAML front-matter has `status: pending`:

1. Read the full file (front-matter + body).
2. Acknowledge it to the user in one sentence ("Picking up handoff: <title>").
3. Update the file in place — change `status: pending` to `status: received`
   and set `received_at` to the current ISO-8601 timestamp. Use the
   `EDIT_FILE` tool with a SEARCH block that matches the existing
   `status: pending` line and the existing `received_at: null` line.
4. Begin work on whatever the handoff describes.

If multiple handoffs are pending, process them oldest first (filenames
sort chronologically). Don't ask permission to begin — the handoff is
the permission.''';

  /// Returns the workspace's handoff directory (does not create it).
  static Directory dir(String workspacePath) {
    return Directory(
      p.join(workspacePath, LumenWorkspaceConfig.dirName, _handoffDirName),
    );
  }

  /// Workspace-relative path used inside `<<<CREATE_FILE: ...>>>`
  /// blocks. Forward slashes always — the tool registry normalizes.
  static String relativePathFor(String filename) {
    return '${LumenWorkspaceConfig.dirName}/$_handoffDirName/$filename';
  }

  /// Build a filesystem-safe filename for a new handoff:
  /// `<YYYYMMDD-HHmmss>-<slug>.md`. Slug is derived from [title].
  static String filenameFor(String title, {DateTime? now}) {
    final ts = _timestampSlug(now ?? DateTime.now());
    final slug = _slugify(title);
    final safeSlug = slug.isEmpty ? 'handoff' : slug;
    return '$ts-$safeSlug.md';
  }

  /// Format a [DateTime] as the ISO-8601 string we put into
  /// front-matter `created_at` / `received_at`. Local timezone offset
  /// preserved so the user can read it without mental gymnastics.
  static String formatTimestamp(DateTime dt) => dt.toIso8601String();

  /// Lists every handoff file in `.lumen/handoff/`, newest first.
  /// Safe to call when the directory does not exist (returns empty).
  static Future<List<HandoffFile>> list(String workspacePath) async {
    final d = dir(workspacePath);
    if (!await d.exists()) return const <HandoffFile>[];
    final entries = <HandoffFile>[];
    await for (final entity in d.list()) {
      if (entity is! File) continue;
      if (!entity.path.toLowerCase().endsWith('.md')) continue;
      try {
        final raw = await entity.readAsString();
        entries.add(HandoffFile.parse(entity, raw));
      } catch (e) {
        debugPrint('HandoffService.list: skipping ${entity.path}: $e');
      }
    }
    entries.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return entries;
  }

  /// Returns the count of handoffs currently in `pending` status.
  /// Useful for a status-bar badge later.
  static Future<int> pendingCount(String workspacePath) async {
    final all = await list(workspacePath);
    return all.where((h) => h.status == HandoffStatus.pending).length;
  }

  /// Append the receive rule to `.lumen/rules.md` if it isn't already
  /// present. Idempotent via [ruleMarker]. Returns `true` if the rule
  /// was newly installed (so callers can show a toast).
  static Future<bool> ensureRuleInstalled(String workspacePath) async {
    try {
      await LumenWorkspaceConfig.ensureDir(workspacePath);
      final file = LumenWorkspaceConfig.rulesFile(workspacePath);
      final existing = await file.exists() ? await file.readAsString() : '';
      if (existing.contains(ruleMarker)) return false;
      final separator = existing.isEmpty || existing.endsWith('\n\n')
          ? ''
          : (existing.endsWith('\n') ? '\n' : '\n\n');
      await file.writeAsString('$existing$separator$ruleBlock\n', mode: FileMode.write);
      return true;
    } catch (e) {
      debugPrint('HandoffService.ensureRuleInstalled: $e');
      return false;
    }
  }

  // ── Internal helpers ──

  static String _timestampSlug(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    final l = dt.toLocal();
    return '${l.year}${two(l.month)}${two(l.day)}-${two(l.hour)}${two(l.minute)}${two(l.second)}';
  }

  static String _slugify(String input) {
    final lowered = input.trim().toLowerCase();
    final replaced = lowered.replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    final trimmed = replaced.replaceAll(RegExp(r'^-+|-+$'), '');
    return trimmed.length > 40 ? trimmed.substring(0, 40) : trimmed;
  }
}

enum HandoffStatus { pending, received, unknown }

/// In-memory view of a parsed handoff file. The body is everything
/// after the closing `---` fence; we keep it as-is so callers can
/// re-render or display it without re-parsing.
class HandoffFile {
  final File file;
  final String title;
  final DateTime createdAt;
  final DateTime? receivedAt;
  final HandoffStatus status;
  final String body;

  HandoffFile({
    required this.file,
    required this.title,
    required this.createdAt,
    required this.receivedAt,
    required this.status,
    required this.body,
  });

  /// Parse a raw markdown string with YAML-ish front-matter.
  /// Tolerant — missing fields fall back to sensible defaults so a
  /// half-malformed handoff still shows up in the list.
  factory HandoffFile.parse(File file, String raw) {
    final lines = raw.split('\n');
    String title = p.basenameWithoutExtension(file.path);
    DateTime createdAt = file.statSync().modified;
    DateTime? receivedAt;
    HandoffStatus status = HandoffStatus.unknown;
    int bodyStart = 0;

    if (lines.isNotEmpty && lines.first.trim() == HandoffService.frontMatterFence) {
      var i = 1;
      while (i < lines.length && lines[i].trim() != HandoffService.frontMatterFence) {
        final line = lines[i];
        final colon = line.indexOf(':');
        if (colon > 0) {
          final key = line.substring(0, colon).trim();
          final value = _stripQuotes(line.substring(colon + 1).trim());
          switch (key) {
            case 'title':
              if (value.isNotEmpty) title = value;
              break;
            case 'created_at':
              final parsed = DateTime.tryParse(value);
              if (parsed != null) createdAt = parsed;
              break;
            case 'received_at':
              if (value.isNotEmpty && value != 'null') {
                receivedAt = DateTime.tryParse(value);
              }
              break;
            case 'status':
              status = _statusFromString(value);
              break;
          }
        }
        i++;
      }
      bodyStart = i + 1;
    }

    final body = bodyStart >= lines.length
        ? ''
        : lines.sublist(bodyStart).join('\n').trimLeft();

    return HandoffFile(
      file: file,
      title: title,
      createdAt: createdAt,
      receivedAt: receivedAt,
      status: status,
      body: body,
    );
  }

  static String _stripQuotes(String v) {
    if (v.length >= 2) {
      final first = v[0];
      final last = v[v.length - 1];
      if ((first == '"' && last == '"') || (first == "'" && last == "'")) {
        return v.substring(1, v.length - 1);
      }
    }
    return v;
  }

  static HandoffStatus _statusFromString(String v) {
    switch (v.toLowerCase()) {
      case 'pending':
        return HandoffStatus.pending;
      case 'received':
        return HandoffStatus.received;
      default:
        return HandoffStatus.unknown;
    }
  }
}
