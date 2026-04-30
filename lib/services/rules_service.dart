import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

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
''';

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
    if (!await f.exists()) await f.writeAsString(_workspaceDefaultStub);
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
