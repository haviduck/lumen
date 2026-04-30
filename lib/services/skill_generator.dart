import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'lumen_workspace_config.dart';
import 'tool_registry.dart';

typedef SkillChatGenerator =
    Future<String> Function(
      List<Map<String, dynamic>> messages, {
      String? model,
    });

/// One artifact in the generator's output. Wraps either a JSON tool
/// definition (command-shaped capability) or a markdown skill body
/// (instruction-shaped capability) so callers can dispatch on
/// `kind` without re-parsing.
///
/// **Tool vs Skill — the rule:** a *tool* IS-A shell command the
/// agent invokes via `<<<NAME: arg>>>` syntax. A *skill* is a
/// markdown document of conventions/instructions the agent reads
/// and follows. Tools execute; skills inform. Same generator, two
/// outputs.
class GeneratedArtifact {
  final String id;
  final String kind; // 'tool' | 'skill'
  final String? name;
  final String? description;
  final Map<String, dynamic>? toolJson; // present when kind == 'tool'
  final String? skillMarkdown; // present when kind == 'skill'
  final String? skillTrigger; // optional; from frontmatter
  bool get isTool => kind == 'tool';
  bool get isSkill => kind == 'skill';

  const GeneratedArtifact._({
    required this.id,
    required this.kind,
    required this.name,
    required this.description,
    required this.toolJson,
    required this.skillMarkdown,
    required this.skillTrigger,
  });

  factory GeneratedArtifact.tool({
    required String id,
    required String name,
    required String description,
    required Map<String, dynamic> json,
  }) {
    return GeneratedArtifact._(
      id: id,
      kind: 'tool',
      name: name,
      description: description,
      toolJson: json,
      skillMarkdown: null,
      skillTrigger: null,
    );
  }

  factory GeneratedArtifact.skill({
    required String id,
    required String name,
    required String description,
    required String body,
    String? trigger,
  }) {
    return GeneratedArtifact._(
      id: id,
      kind: 'skill',
      name: name,
      description: description,
      toolJson: null,
      skillMarkdown: body,
      skillTrigger: trigger,
    );
  }
}

/// Outcome of a generation pass. Carries both tool ids and skill
/// ids that were successfully written, so the caller (the manual
/// dialog or the new-project wizard) can render the result honestly.
class SkillGenerationResult {
  /// Tool ids written to `.lumen/tools/`.
  final List<String> createdTools;

  /// Skill ids written to `.lumen/skills/`.
  final List<String> createdSkills;

  /// Entries the LLM proposed but were rejected at validation.
  /// Each entry is `"<id>: <reason>"`.
  final List<String> rejected;

  /// Set when the whole pipeline failed (LLM unreachable, response
  /// not parseable, etc). When non-null, [createdTools] /
  /// [createdSkills] are expected to be empty.
  final String? error;

  /// Truncated raw LLM response, for debug display when [error] set.
  final String? rawSnippet;

  const SkillGenerationResult({
    this.createdTools = const [],
    this.createdSkills = const [],
    this.rejected = const [],
    this.error,
    this.rawSnippet,
  });

  /// Back-compat alias — older call sites refer to the combined
  /// "stuff that got created" list.
  List<String> get created => [...createdTools, ...createdSkills];

  bool get ok =>
      error == null && (createdTools.isNotEmpty || createdSkills.isNotEmpty);
}

class CustomSkillRequest {
  final String name;
  final String details;

  const CustomSkillRequest({required this.name, required this.details});
}

/// One of the broad project archetypes the user can pick in the skill
/// dialog. The model uses this to bias the generated tools/skills toward
/// the stack's idiomatic workflow.
enum SkillProjectKind {
  webApp,
  dashboard,
  mobileApp,
  desktopApp,
  backendApi,
  cliTool,
  library,
  game,
  mlData,
  devops,
  unknown,
}

extension SkillProjectKindLabel on SkillProjectKind {
  String get label => switch (this) {
    SkillProjectKind.webApp => 'Web app / SaaS',
    SkillProjectKind.dashboard => 'Dashboard / admin UI',
    SkillProjectKind.mobileApp => 'Mobile app',
    SkillProjectKind.desktopApp => 'Desktop app',
    SkillProjectKind.backendApi => 'Backend / API',
    SkillProjectKind.cliTool => 'CLI tool',
    SkillProjectKind.library => 'Library / SDK',
    SkillProjectKind.game => 'Game',
    SkillProjectKind.mlData => 'ML / Data / Notebooks',
    SkillProjectKind.devops => 'DevOps / Infra',
    SkillProjectKind.unknown => 'Other / not sure',
  };

  String get promptHint => switch (this) {
    SkillProjectKind.webApp =>
      'web frontend tooling — bundlers, linters, type checks, dev server, route audit. Skills for design system + accessibility.',
    SkillProjectKind.dashboard =>
      'dashboard tooling — chart libs, design-token sync, component lints. Skills for layout / spacing / data-density conventions.',
    SkillProjectKind.mobileApp =>
      'mobile tooling — emulator launchers, signing, screenshot tests. Skills for navigation patterns + platform conventions.',
    SkillProjectKind.desktopApp =>
      'desktop tooling — packaging, signing, native build. Skills for window-state / native-menu conventions.',
    SkillProjectKind.backendApi =>
      'backend tooling — migrations, seeders, OpenAPI checks, request tracing. Skills for endpoint naming + error-response shape.',
    SkillProjectKind.cliTool =>
      'CLI tooling — install dry-runs, --help validation, exit-code matrix. Skills for argument-parsing conventions.',
    SkillProjectKind.library =>
      'library tooling — API doc gen, public-API diff, semver lint. Skills for stability guarantees + deprecation policy.',
    SkillProjectKind.game =>
      'game tooling — asset pipeline, frame-time profile, save-file dump. Skills for ECS / scene-graph conventions.',
    SkillProjectKind.mlData =>
      'ML / data tooling — dataset stats, notebook strip-output, eval. Skills for experiment naming + reproducibility.',
    SkillProjectKind.devops =>
      'infra tooling — terraform plan, kubectl shortcuts, log tails. Skills for env-promotion + secret-handling conventions.',
    SkillProjectKind.unknown =>
      'general dev tooling — let manifest files drive the choice.',
  };
}

/// LLM-backed bootstrap for a workspace's `.lumen/tools/` (commands)
/// AND `.lumen/skills/` (instructions). The LLM decides per-artifact
/// whether the user's request is tool-shaped or skill-shaped.
///
/// Flow:
///   1. Detect project type (top-level entries + manifest file
///      previews).
///   2. Combine with user-supplied archetype hints + free-text.
///   3. Ask the LLM for a JSON envelope: `{"artifacts": [...]}`
///      where each artifact is either `{"kind":"tool", ...}` or
///      `{"kind":"skill", ...}`.
///   4. Parse, validate, write tool JSONs to `.lumen/tools/` and
///      skill markdown to `.lumen/skills/`.
class SkillGenerator {
  final SkillChatGenerator generateChat;
  final Future<bool> Function() isReadyCheck;
  final String model;

  SkillGenerator({
    required this.generateChat,
    required this.isReadyCheck,
    required this.model,
  });

  Future<bool> isReady() => isReadyCheck();

  Future<SkillGenerationResult> generate(
    String workspacePath, {
    List<SkillProjectKind> kinds = const [],
    String extraContext = '',
  }) async {
    try {
      final context = await _buildProjectContext(workspacePath);
      final effectiveKinds = kinds.isEmpty
          ? const [SkillProjectKind.unknown]
          : kinds;
      final prompt = _buildPrompt(
        projectContext: context,
        kinds: effectiveKinds,
        extraContext: extraContext.trim(),
      );

      final response = await generateChat([
        {'role': 'system', 'content': _systemInstructions},
        {'role': 'user', 'content': prompt},
      ], model: model);

      return _parseValidateAndWrite(response, workspacePath);
    } catch (e, st) {
      debugPrint('SkillGenerator.generate failed: $e\n$st');
      return SkillGenerationResult(error: 'Unexpected error: $e');
    }
  }

  Future<SkillGenerationResult> generateCustom(
    String workspacePath, {
    required CustomSkillRequest request,
  }) async {
    try {
      final context = await _buildProjectContext(workspacePath);
      final prompt = _buildCustomPrompt(
        projectContext: context,
        request: request,
      );
      final response = await generateChat([
        {'role': 'system', 'content': _systemInstructions},
        {'role': 'user', 'content': prompt},
      ], model: model);
      return _parseValidateAndWrite(response, workspacePath);
    } catch (e, st) {
      debugPrint('SkillGenerator.generateCustom failed: $e\n$st');
      return SkillGenerationResult(error: 'Unexpected error: $e');
    }
  }

  // ── prompt construction ─────────────────────────────────────────────

  static const String _systemInstructions =
      'You configure capabilities for the Lumen IDE\'s coding agent. '
      'You produce two kinds of artifacts: TOOLS (shell commands the '
      'agent invokes) and SKILLS (markdown instruction sets the agent '
      'reads and follows). Reply with ONLY a JSON object — no prose, '
      'no markdown fences, no preamble or postamble.';

  /// Shared block describing the artifact schema + the
  /// tool-vs-skill decision rule. Reused by `_buildPrompt` (multi)
  /// and `_buildCustomPrompt` (single) so the rules don't drift.
  static String get _schemaAndRules => r'''
ARTIFACT KINDS (this is the most important rule)
You produce a JSON object: {"artifacts": [...]}.
Each entry is EITHER a tool OR a skill.

CHOOSE TOOL when the user wants the agent to RUN something:
- run tests, lint, typecheck, build, deploy, format
- start a dev server, run a migration, hit an endpoint
- scaffold a file with a deterministic output
- inspect git / disk / process state
Tool schema (every field required):
  {
    "kind": "tool",
    "id": "snake_case_unique_id",
    "name": "UPPER_SNAKE_CASE",
    "description": "What it does, when to use it. 1-2 sentences.",
    "syntax": "<<<NAME: arg>>> or <<<NAME>>> when no arg",
    "pattern": "<<<NAME:\\s*(.*?)\\s*>>>",
    "command": ["binary", "arg1", "$1"],
    "requiresApproval": true,
    "defaultEnabled": false
  }

CHOOSE SKILL when the user wants the agent to FOLLOW conventions:
- design system / UI consistency / styling rules
- code style / naming / file organization
- domain knowledge / project conventions
- architectural patterns / "how we structure X here"
- review checklists / what to avoid
Skills are READ, not invoked. They become part of the system prompt.
Skill schema (every field required):
  {
    "kind": "skill",
    "id": "snake_case_unique_id",
    "name": "Short Title Case label, like a doc heading",
    "description": "1-line summary shown in the manage UI.",
    "trigger": "Plain-language description of WHEN the agent should apply this. e.g. 'When creating dashboard pages or styling components.' Or 'always' for unconditional.",
    "body": "Full markdown body the agent reads. Use ## subheadings, bullet lists, DO/DONT pairs, code blocks for example fragments. NO frontmatter inside this field — Lumen wraps it. Do not write '## Workspace skills' — Lumen adds the header."
  }

DECISION HEURISTIC
- "Generate / scaffold / make a thing" with hardcoded structure → SKILL
  (so the agent can vary the output to fit the project, not a rigid template).
- "Run / check / lint / format / build / test / hit URL" → TOOL.
- "Be consistent / follow this style / match this design / always do X" → SKILL.
- "How do I X in this repo" answers / domain rules → SKILL.

RULES (apply to both kinds)
- Output ONLY the JSON object {"artifacts": [...]}. No prose. No markdown fences.
- "id" must be snake_case, unique within the response.
- DO NOT duplicate built-in agent tool ids:
  create_file, edit_file, multi_edit, append_file, move_file, read_file,
  read_file_range, list_dir, tree, search_text, find_file, glob,
  delete_file, git_status, git_diff, run_cmd, verify.

TOOL-ONLY RULES
- "pattern" must be a valid regex with capture groups for any args.
- "command" is the OS-level command. Use $1, $2... to refer to regex
  capture groups; escape literal dollars as $$.
- requiresApproval: true for ANY command that mutates state, builds,
  installs, deploys, runs servers, sends network requests, or modifies
  files. Read-only inspection commands can be false.
- defaultEnabled: true for read-only / inspection tools, false for
  mutating ones (so the user opts in deliberately the first time).
- DO NOT generate a tool whose body is a giant inline `node -e ...`
  or `python -c ...` script that hardcodes a stack the user did not
  specify. If the request needs hardcoded React/Vue/etc. structure,
  that is a SKILL, not a tool.
- DO NOT generate UI / design / "writing" tools — they need an LLM,
  not a shell command. Make those a SKILL instead.

SKILL-ONLY RULES
- "body" should be 4-30 markdown lines. Concrete and actionable, not
  generic. Reference real concepts the agent will see in the project.
- Prefer DO / DON'T pairs over abstract principles.
- If you reference design tokens / component names / file paths,
  use the user's project context where possible. Do not invent
  framework details the project clearly does not use.
''';

  String _buildPrompt({
    required String projectContext,
    required List<SkillProjectKind> kinds,
    required String extraContext,
  }) {
    final kindLines = kinds
        .map((k) => '- ${k.label}: ${k.promptHint}')
        .join('\n');
    final userHints = extraContext.isEmpty ? '(none provided)' : extraContext;
    return '''
USER INTENT
The user is starting work on this project and chose the following
archetype(s) — bias your picks toward what these stacks typically need:

$kindLines

ADDITIONAL CONTEXT FROM USER
$userHints

PROJECT CONTEXT
$projectContext

$_schemaAndRules

REQUIRED OUTPUT
A JSON object with an "artifacts" array of 3-7 entries, mixed tools
and skills as appropriate for the project. A dashboard project, for
example, might get 1-2 tools (lint, build) and 1-2 skills (design
system conventions, accessibility checklist). Quality over quantity.

Begin.
''';
  }

  String _buildCustomPrompt({
    required String projectContext,
    required CustomSkillRequest request,
  }) {
    return '''
USER REQUEST
The user wants ONE focused capability for the Lumen agent.

Their idea: ${request.name}
Their details: ${request.details.trim().isEmpty ? '(none provided)' : request.details.trim()}

PROJECT CONTEXT
$projectContext

$_schemaAndRules

REQUIRED OUTPUT
A JSON object with an "artifacts" array containing EXACTLY ONE entry
— pick tool or skill based on the decision heuristic above.

EXAMPLE OUTPUTS (for shape reference only, do NOT copy content)

Skill example:
{
  "artifacts": [
    {
      "kind": "skill",
      "id": "dashboard_design",
      "name": "Dashboard Design Conventions",
      "description": "Layout, spacing, and component patterns for consistent dashboard pages.",
      "trigger": "When creating, styling, or refactoring dashboard pages or admin UI.",
      "body": "## Layout\\n- Sidebar: 240px, collapses to 56px below 1024px.\\n- Header: 56px, sticky.\\n- Content: max-width 1280px, 24px gutter.\\n\\n## Components\\n- Stat cards use the existing `<StatCard>` component, not new chrome.\\n- Charts: prefer Recharts. Always provide an empty state.\\n\\n## Don\\u2019t\\n- Don\\u2019t introduce new accent colours; reuse design tokens in design/tokens.json."
    }
  ]
}

Tool example:
{
  "artifacts": [
    {
      "kind": "tool",
      "id": "check_route",
      "name": "CHECK_ROUTE",
      "description": "Smoke-test one HTTP route and report the response status.",
      "syntax": "<<<CHECK_ROUTE: /api/health>>>",
      "pattern": "<<<CHECK_ROUTE:\\\\s*(.*?)\\\\s*>>>",
      "command": ["curl", "-i", "http://localhost:5000\$1"],
      "requiresApproval": true,
      "defaultEnabled": false
    }
  ]
}

Begin.
''';
  }

  // ── project introspection ───────────────────────────────────────────

  Future<String> _buildProjectContext(String workspacePath) async {
    final buf = StringBuffer();
    buf.writeln('Project root: $workspacePath');
    buf.writeln('');

    try {
      final dir = Directory(workspacePath);
      final entries = await dir.list().take(40).toList();
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1 : 1;
        return p
            .basename(a.path)
            .toLowerCase()
            .compareTo(p.basename(b.path).toLowerCase());
      });
      buf.writeln('Top-level entries:');
      for (final e in entries) {
        final name = p.basename(e.path);
        buf.writeln(e is Directory ? '  [DIR] $name/' : '        $name');
      }
    } catch (e) {
      buf.writeln('  (failed to list workspace: $e)');
    }

    const manifests = <String>[
      'pubspec.yaml',
      'package.json',
      'Cargo.toml',
      'go.mod',
      'requirements.txt',
      'pyproject.toml',
      'setup.py',
      'pom.xml',
      'build.gradle',
      'build.gradle.kts',
      'CMakeLists.txt',
      'Dockerfile',
      'Makefile',
      'composer.json',
      'Gemfile',
    ];
    for (final manifest in manifests) {
      final f = File(p.join(workspacePath, manifest));
      if (!await f.exists()) continue;
      try {
        final content = await f.readAsString();
        final preview = content.split('\n').take(50).join('\n');
        buf.writeln('');
        buf.writeln('--- $manifest (first 50 lines) ---');
        buf.writeln(preview);
      } catch (_) {}
    }
    return buf.toString();
  }

  // ── response parsing / validation ───────────────────────────────────

  /// Pull the JSON object envelope (`{"artifacts":[...]}`) out of
  /// the LLM response. Tolerates markdown fences and prose prefixes.
  /// Falls back to a bare JSON array (legacy tool-only shape) so old
  /// LLMs that ignore the new schema still produce something usable.
  String? _extractJsonEnvelope(String response) {
    final trimmed = response.trim();
    final fence = RegExp(
      r'```(?:json)?\s*(\{[\s\S]*?\}|\[[\s\S]*?\])\s*```',
      caseSensitive: false,
    ).firstMatch(trimmed);
    if (fence != null) return fence.group(1);
    final obj = RegExp(r'\{[\s\S]*\}').firstMatch(trimmed);
    if (obj != null) return obj.group(0);
    final arr = RegExp(r'\[[\s\S]*\]').firstMatch(trimmed);
    return arr?.group(0);
  }

  Future<SkillGenerationResult> _parseValidateAndWrite(
    String response,
    String workspacePath,
  ) async {
    final raw = _extractJsonEnvelope(response);
    if (raw == null) {
      return SkillGenerationResult(
        error: 'LLM response did not contain JSON.',
        rawSnippet: _truncate(response, 600),
      );
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (e) {
      return SkillGenerationResult(
        error: 'Could not parse LLM response as JSON: $e',
        rawSnippet: _truncate(response, 600),
      );
    }

    // Normalise to a List<dynamic> of artifact entries. Two accepted
    // shapes: {"artifacts": [...]} or [...] (legacy tool-only).
    List<dynamic> entries;
    if (decoded is Map<String, dynamic> && decoded['artifacts'] is List) {
      entries = decoded['artifacts'] as List<dynamic>;
    } else if (decoded is List) {
      entries = decoded;
    } else {
      return SkillGenerationResult(
        error: 'LLM response must be a JSON object with "artifacts" array.',
        rawSnippet: _truncate(response, 600),
      );
    }

    final createdTools = <String>[];
    final createdSkills = <String>[];
    final rejected = <String>[];

    await LumenWorkspaceConfig.ensureDir(workspacePath);
    final toolsDir = LumenWorkspaceConfig.toolsDir(workspacePath);
    final skillsDir = LumenWorkspaceConfig.skillsDir(workspacePath);

    final builtinIds = ToolRegistry.builtin
        .map((t) => t.id.toLowerCase())
        .toSet();

    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) {
        rejected.add('(non-object): not a JSON object');
        continue;
      }
      // Default to tool when "kind" is missing — preserves
      // back-compat with old prompts that produced bare tool JSON.
      final kind = (entry['kind'] as String? ?? 'tool').toLowerCase();
      final id = entry['id'];
      if (id is! String || id.isEmpty) {
        rejected.add('(missing id): "id" field absent or empty');
        continue;
      }
      if (kind == 'tool' && builtinIds.contains(id.toLowerCase())) {
        rejected.add('$id: collides with built-in tool');
        continue;
      }

      switch (kind) {
        case 'tool':
          final reason = _validateTool(entry);
          if (reason != null) {
            rejected.add('$id: $reason');
            continue;
          }
          try {
            if (!await toolsDir.exists()) {
              await toolsDir.create(recursive: true);
            }
            final file = File(p.join(toolsDir.path, '$id.json'));
            // Strip the "kind" field — `ExternalToolLoader` uses
            // its own schema and doesn't expect it.
            final clean = Map<String, dynamic>.of(entry)..remove('kind');
            final encoder = const JsonEncoder.withIndent('  ');
            await file.writeAsString(encoder.convert(clean));
            createdTools.add(id);
          } catch (e) {
            rejected.add('$id: tool write failed - $e');
          }
        case 'skill':
          final reason = _validateSkill(entry);
          if (reason != null) {
            rejected.add('$id: $reason');
            continue;
          }
          try {
            if (!await skillsDir.exists()) {
              await skillsDir.create(recursive: true);
            }
            final file = File(p.join(skillsDir.path, '$id.md'));
            await file.writeAsString(_renderSkillFile(entry));
            createdSkills.add(id);
          } catch (e) {
            rejected.add('$id: skill write failed - $e');
          }
        default:
          rejected.add(
            '$id: unknown kind "$kind" (expected "tool" or "skill")',
          );
      }
    }

    if (createdTools.isEmpty && createdSkills.isEmpty) {
      return SkillGenerationResult(
        error: 'LLM returned ${entries.length} candidate(s), all rejected.',
        rejected: rejected,
        rawSnippet: _truncate(response, 600),
      );
    }
    return SkillGenerationResult(
      createdTools: createdTools,
      createdSkills: createdSkills,
      rejected: rejected,
    );
  }

  /// Render a skill entry to its on-disk markdown form. YAML-ish
  /// frontmatter (`---`) carries metadata; the `body` field becomes
  /// the markdown body. `WorkspaceSkillsService` reads exactly this
  /// shape on the next reload.
  static String _renderSkillFile(Map<String, dynamic> entry) {
    final id = entry['id'] as String;
    final name = (entry['name'] as String?)?.trim() ?? id;
    final trigger = (entry['trigger'] as String?)?.trim();
    final body = (entry['body'] as String? ?? '').trimRight();
    final description = (entry['description'] as String?)?.trim();
    final buf = StringBuffer();
    buf.writeln('---');
    buf.writeln('id: $id');
    buf.writeln('name: ${_yamlEscape(name)}');
    if (trigger != null && trigger.isNotEmpty && trigger.toLowerCase() != 'always') {
      buf.writeln('trigger: ${_yamlEscape(trigger)}');
    }
    if (description != null && description.isNotEmpty) {
      buf.writeln('description: ${_yamlEscape(description)}');
    }
    buf.writeln('---');
    buf.writeln('');
    buf.writeln(body);
    buf.writeln('');
    return buf.toString();
  }

  static String _yamlEscape(String v) {
    if (v.contains('\n') || v.contains('"') || v.contains(':')) {
      final escaped = v.replaceAll('\\', r'\\').replaceAll('"', r'\"');
      return '"$escaped"';
    }
    return v;
  }

  /// Validates a tool entry against the shape `ExternalToolLoader`
  /// will accept on next reload. Returns null on success, error
  /// string otherwise.
  String? _validateTool(Map<String, dynamic> def) {
    for (final required in const [
      'id',
      'name',
      'description',
      'syntax',
      'pattern',
      'command',
      'requiresApproval',
      'defaultEnabled',
    ]) {
      if (def[required] == null) return 'missing tool field "$required"';
    }
    final id = def['id'];
    if (id is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      return '"id" must be snake_case';
    }
    final cmd = def['command'];
    if (cmd is! List || cmd.isEmpty) {
      return '"command" must be a non-empty array';
    }
    for (final s in cmd) {
      if (s is! String) return '"command" entries must be strings';
    }
    final patStr = def['pattern'];
    if (patStr is! String || patStr.isEmpty) return '"pattern" missing';
    try {
      RegExp(patStr);
    } catch (e) {
      return 'invalid regex: $e';
    }
    if (def['requiresApproval'] is! bool) return '"requiresApproval" not bool';
    if (def['defaultEnabled'] is! bool) return '"defaultEnabled" not bool';
    return null;
  }

  String? _validateSkill(Map<String, dynamic> def) {
    for (final required in const ['id', 'name', 'description', 'body']) {
      if (def[required] == null) return 'missing skill field "$required"';
    }
    final id = def['id'];
    if (id is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(id)) {
      return '"id" must be snake_case';
    }
    final body = def['body'];
    if (body is! String || body.trim().isEmpty) {
      return '"body" must be a non-empty markdown string';
    }
    if (body.length > 8000) {
      return '"body" too long (>${8000} chars) — split into smaller skills';
    }
    final name = def['name'];
    if (name is! String || name.trim().isEmpty) return '"name" must be non-empty';
    return null;
  }

  static String _truncate(String s, int max) {
    if (s.length <= max) return s;
    return '${s.substring(0, max)}…';
  }
}
