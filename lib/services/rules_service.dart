import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'handoff_service.dart';
import 'lumen_workspace_config.dart';

/// Reads/writes `.lumen/rules.md` at both global and workspace scope.
/// Rules are silently injected into the system prompt so the agent
/// follows project conventions automatically.
class RulesService {
  static const String _globalDefaultStub = '''# Lumen Rules

Write project-specific instructions, coding standards, or context the agent
should always follow. Bullet points or short paragraphs work well.

## Style
- 

## Architecture notes
- 

## Don't
- 
''';

  static const String _workspaceDefaultStub = '''# Lumen Workspace Rules

These rules are created automatically for new workspaces. Keep additions short,
practical, and specific to this project.

## Design and UI
- Prefer shared styling primitives for common UI: buttons, cards, inputs,
  layout spacing, typography, empty states, status pills, and navigation.
- Do not create separate page-specific CSS for basic elements unless the page
  truly needs a local variation. Add reusable/global classes first, then layer
  page-specific modifiers only where needed.
- Avoid generic LLM design tropes: too many decorative icons, purple/blue
  gradient sameness, glass effects everywhere, and repetitive "AI dashboard"
  layouts. Match the product's existing visual language and choose restraint
  when unsure.

## Code Quality
- Keep code modular. Prefer small components/services/helpers over large files
  that mix unrelated behavior.
- If a cleaner refactor, missing guard, useful test, or obvious quality-of-life
  improvement is directly adjacent to the user's request, make it when the risk
  is low and explain it briefly afterward.

## Working With The User
- Act as a thoughtful IDE partner. If the user asks for something ambiguous or
  likely to cause long-term maintenance pain, make a reasonable call or point
  out the trade-off instead of blindly following the first wording.
- The user may not know which standard IDE conveniences or project hygiene steps
  are missing. When a small addition would make the result more complete, add it
  and mention it.

## Servers and long-running processes
- Do not start webservers, dev servers, watchers, or other long-running
  processes unless the user explicitly asks for it. Many of these are
  auth-gated, bind to ports the user may already be using, or interfere with
  the user's own running stack. Suggest the command and let the user run it.
- One-shot commands that exit on their own (build, test, lint, format,
  install) are fine to invoke directly when the task calls for them.

## Python and environment-bound interpreters
- Do not run Python scripts (`python foo.py`, `python -m something`,
  `pytest`, `python -c`, helpers that shell out to a Python entry point)
  unless the user explicitly asks for it. The agent does not know which
  interpreter the user wants — conda env, venv, `pyenv`, poetry/pdm/hatch
  shell, or system Python — and picking wrong installs into the wrong
  environment, fails on missing dependencies, or silently runs the wrong
  Python version. Suggest the command (with any activation step) and let the
  user run it.
- The same caution applies to other runtimes whose behavior depends on a
  per-project environment: Ruby behind `bundle exec`, Node behind `nvm`/`fnm`,
  Java behind `sdkman`, etc. When in doubt, propose the command rather than
  running it.
''';

  static const String _knowledgebaseRuleBlock =
      '''<!-- LUMEN_KNOWLEDGEBASE_RULE -->
## Knowledgebase (cross-chat memory)

A shared knowledgebase lives at `.lumen/knowledgebase.md`. It is the only
persistent memory between separate chat sessions in this workspace.

**At the start of every chat:**
- Read `.lumen/knowledgebase.md` if it exists. Use it as context for the
  current session — it describes architecture, conventions, recent changes,
  and things that previous sessions learned the hard way.

**After completing non-trivial work:**
- Update `.lumen/knowledgebase.md` with anything a future chat session would
  benefit from knowing: new patterns introduced, architectural decisions made,
  pitfalls discovered, conventions established, or important file locations.
- Keep it concise and scannable (bullets, short sections). Remove stale entries
  when they no longer apply.
- Do not duplicate information already in rules.md — the knowledgebase is for
  evolving project knowledge, not static policy.

If the file does not exist yet, create it on your first meaningful contribution
to the workspace.
''';

  /// Workspace stub for brand-new workspaces — same body as
  /// [_workspaceDefaultStub] plus the chat-handoff receive rule and
  /// the knowledgebase rule so the system works out of the box.
  /// Existing workspaces get the handoff rule auto-appended on first
  /// `/handoff` via [HandoffService.ensureRuleInstalled].
  static String get workspaceDefaultStub =>
      '$_workspaceDefaultStub\n${HandoffService.ruleBlock}\n\n$_knowledgebaseRuleBlock\n';

  /// Marker comment for the knowledgebase rule block. Used to detect
  /// whether the block is already present — idempotent append.
  static const String knowledgebaseRuleMarker = '<!-- LUMEN_KNOWLEDGEBASE_RULE -->';

  /// Append the knowledgebase rule block to an existing workspace
  /// rules file if not already present. Returns true when newly
  /// installed (so callers can log or toast).
  static Future<bool> ensureKnowledgebaseRuleInstalled(
      String workspacePath) async {
    try {
      await LumenWorkspaceConfig.ensureDir(workspacePath);
      final file = LumenWorkspaceConfig.rulesFile(workspacePath);
      final existing = await file.exists() ? await file.readAsString() : '';
      if (existing.contains(knowledgebaseRuleMarker)) return false;
      final separator = existing.isEmpty || existing.endsWith('\n\n')
          ? ''
          : (existing.endsWith('\n') ? '\n' : '\n\n');
      await file.writeAsString(
        '$existing$separator$_knowledgebaseRuleBlock\n',
        mode: FileMode.write,
      );
      return true;
    } catch (e) {
      debugPrint('RulesService.ensureKnowledgebaseRuleInstalled: $e');
      return false;
    }
  }

  Future<File> globalRulesFile() async {
    final base = await getApplicationSupportDirectory();
    await LumenWorkspaceConfig.ensureDir(base.path);
    final f = LumenWorkspaceConfig.rulesFile(base.path);
    if (!await f.exists()) await f.writeAsString(_globalDefaultStub);
    return f;
  }

  File workspaceRulesFile(String workspacePath) {
    return LumenWorkspaceConfig.rulesFile(workspacePath);
  }

  Future<File> ensureWorkspaceRulesFile(String workspacePath) async {
    await LumenWorkspaceConfig.ensureDir(workspacePath);
    final f = workspaceRulesFile(workspacePath);
    if (!await f.exists()) await f.writeAsString(workspaceDefaultStub);
    return f;
  }

  Future<String> readGlobal() async {
    try {
      final f = await globalRulesFile();
      return await f.readAsString();
    } catch (e) {
      debugPrint('Failed to read global rules: $e');
      return '';
    }
  }

  Future<void> writeGlobal(String content) async {
    final f = await globalRulesFile();
    await f.writeAsString(content);
  }

  Future<String> readWorkspace(String workspacePath) async {
    try {
      final f = await ensureWorkspaceRulesFile(workspacePath);
      // Auto-install knowledgebase rule for existing workspaces that
      // predate the feature. Idempotent — no-ops if already present.
      await ensureKnowledgebaseRuleInstalled(workspacePath);
      return await f.readAsString();
    } catch (e) {
      debugPrint('Failed to read workspace rules: $e');
      return '';
    }
  }

  Future<void> writeWorkspace(String workspacePath, String content) async {
    final f = await ensureWorkspaceRulesFile(workspacePath);
    await f.writeAsString(content);
  }

  /// Build the merged rules block to inject into the system prompt.
  /// Returns empty string if neither file has content.
  Future<String> compileForPrompt(String? workspacePath) async {
    final buf = StringBuffer();
    final g = (await readGlobal()).trim();
    if (g.isNotEmpty && g != _globalDefaultStub.trim()) {
      buf.writeln('### Global Rules');
      buf.writeln(g);
    }
    if (workspacePath != null) {
      final w = (await readWorkspace(workspacePath)).trim();
      if (w.isNotEmpty && w != _globalDefaultStub.trim()) {
        buf.writeln('### Workspace Rules');
        buf.writeln(w);
      }
    }
    return buf.toString().trim();
  }
}
