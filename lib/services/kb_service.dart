import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'lumen_workspace_config.dart';

/// Read/write/migrate/summarize support for the workspace knowledgebase
/// — the single markdown file at `<workspace>/.agents/knowledgebase.md`
/// that survives across chat sessions and is read into every agent's
/// system prompt.
///
/// Storage shape (single canonical file under `.agents/`):
///
/// ```text
/// <workspace>/
///   .agents/
///     knowledgebase.md     <-- KB lives here
///     skills/              <-- (Skills system, separate)
/// ```
///
/// Migration: workspaces created before the `.agents/` move stored
/// the file at `<workspace>/.lumen/knowledgebase.md`. [ensureFile]
/// detects a stale legacy copy and moves it across on first read.
/// Idempotent — only runs when the canonical path is missing.
class KbService extends ChangeNotifier {
  /// Returns the canonical KB file for [workspacePath], creating
  /// `.agents/` if needed and migrating from `.lumen/knowledgebase.md`
  /// when applicable. Does NOT create the markdown file itself; the
  /// "no file → empty buffer" affordance is handled by [read].
  static Future<File> ensureFile(String workspacePath) async {
    await LumenWorkspaceConfig.ensureAgentsDir(workspacePath);
    final canonical = LumenWorkspaceConfig.knowledgebaseFile(workspacePath);
    if (await canonical.exists()) return canonical;
    final legacy = LumenWorkspaceConfig.legacyKnowledgebaseFile(workspacePath);
    if (await legacy.exists()) {
      try {
        await legacy.rename(canonical.path);
        debugPrint(
          'KbService: migrated ${legacy.path} → ${canonical.path}',
        );
        return canonical;
      } catch (e) {
        debugPrint('KbService: rename failed ($e), falling back to copy');
        try {
          await legacy.copy(canonical.path);
          // Best-effort: leave the legacy file as a backup. The
          // rules-text rewrite in `RulesService` flips agents to the
          // new path; the legacy file becomes dead weight on disk
          // but never causes a wrong-content read.
          return canonical;
        } catch (e2) {
          debugPrint('KbService: copy also failed: $e2');
          return legacy;
        }
      }
    }
    return canonical;
  }

  /// Returns the KB markdown body for [workspacePath]. Empty string
  /// when no file exists yet (first-run / brand-new workspace) — UI
  /// renders an empty editor with a placeholder, save creates the file.
  static Future<String> read(String workspacePath) async {
    try {
      final f = await ensureFile(workspacePath);
      if (!await f.exists()) return '';
      return await f.readAsString();
    } catch (e) {
      debugPrint('KbService.read failed: $e');
      return '';
    }
  }

  /// Writes [content] to the canonical KB file, creating parents as
  /// needed. Returns the resolved file path on success, null on
  /// failure (callers can surface a toast).
  static Future<String?> write(String workspacePath, String content) async {
    try {
      final f = await ensureFile(workspacePath);
      if (!await f.parent.exists()) {
        await f.parent.create(recursive: true);
      }
      await f.writeAsString(content);
      return f.path;
    } catch (e) {
      debugPrint('KbService.write failed: $e');
      return null;
    }
  }

  /// Path the KB *would* live at, regardless of existence. Useful
  /// for headers / "open in editor" affordances that don't want to
  /// trigger a migration side-effect.
  static String pathFor(String workspacePath) =>
      p.normalize(LumenWorkspaceConfig.knowledgebaseFile(workspacePath).path);

  /// Deterministic system prompt used by the "Summarize" action.
  /// Pinned in code (not user-editable) so the compression contract
  /// is stable across model swaps. Keep this short — verbose prompts
  /// get edited away by lossy models.
  static const String summarizeSystemPrompt = '''You are compacting a project knowledgebase.

The input is a markdown file used as cross-chat memory: rules, project facts,
architectural decisions, conventions, recent learnings. Produce a SHORTER
markdown file with the same shape.

HARD RULES:
- Preserve every concrete fact, file path, command, and convention.
- Preserve any user preferences, dislikes, or "always do X / never do Y" rules.
- Preserve all section headings the user authored. You may merge sections only
  when their content is genuinely redundant.
- Drop only: duplicates, stale TODOs that have shipped, narrative filler,
  redundant restatements.
- Output is markdown ONLY — no commentary, no "Here is the summary:" preface.
- Do NOT invent facts or paraphrase aggressively. When unsure, keep the
  original wording.
- Target roughly 50-65% of the input length.''';

  /// Threshold check used by chat turns to decide whether the auto-
  /// summarize banner should fire. Pure function — does NOT call the
  /// model. The actual summarize action lives in the UI layer because
  /// it requires user confirm + diff preview before overwriting.
  static bool exceedsThreshold(String content, int thresholdChars) {
    if (thresholdChars < 2000) return false;
    return content.length > thresholdChars;
  }

  /// Build the user-message payload for [generateUtilityText]. Wraps
  /// the body in a fenced block so the model can't be tricked by KB
  /// content into thinking it's outside the prompt.
  static List<Map<String, dynamic>> buildSummarizeMessages(String body) {
    return [
      {'role': 'system', 'content': summarizeSystemPrompt},
      {
        'role': 'user',
        'content':
            'Compact the following knowledgebase, returning markdown only:\n\n'
            '```markdown\n$body\n```',
      },
    ];
  }
}
