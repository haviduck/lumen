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
      'You are a senior engineer joining a real project on day one. '
      'Your task: write the SHORT, BATTLE-TESTED CHEATSHEET that a '
      'thoughtful colleague would hand a brand-new contributor. The '
      'audience is Lumen IDE\'s coding agent (an LLM that pair-programs '
      'in this repo). It already knows how to read files, search, run '
      'tests, and use git. You DO NOT teach it programming — you teach '
      'it THIS PROJECT\'s opinionated conventions, the gotchas, the '
      '"every new dev makes this mistake" warnings.\n\n'
      'You produce two kinds of artifacts:\n'
      '  • TOOLS — shell commands the agent invokes via a regex marker.\n'
      '  • SKILLS — markdown instructions the agent reads every turn.\n\n'
      'Quality bar: every artifact you emit must save the agent a '
      'wrong turn it would otherwise take. Generic advice ("write '
      'clean code", "follow conventions") is NOISE — those bytes '
      'pollute every system prompt for the entire life of the '
      'workspace. Better to emit ONE great skill than five mediocre '
      'ones. If you can\'t name a concrete file path, manifest entry, '
      'or framework idiom from the project context, you\'re guessing '
      '— and you should output fewer artifacts.\n\n'
      'Reply with ONLY a JSON object — no prose, no markdown fences, '
      'no preamble or postamble.';

  /// Shared block describing the artifact schema + the
  /// tool-vs-skill decision rule. Reused by `_buildPrompt` (multi)
  /// and `_buildCustomPrompt` (single) so the rules don't drift.
  ///
  /// Heavily revised in 2026-05 — the previous block was schematically
  /// correct but produced bland skills (bullet-point platitudes, no
  /// project grounding, generic triggers). The juice-up encodes the
  /// quality bar in the prompt itself: contrastive GOOD vs BAD
  /// examples, hard rules against vague language, mandatory project
  /// references, trigger discipline, and a self-check pass before
  /// JSON emission. The schema and downstream validation are
  /// unchanged so the parser doesn't drift.
  static String get _schemaAndRules => r'''
ARTIFACT KINDS — TOOL vs SKILL
You produce a JSON object: {"artifacts": [...]}.
Each entry is EITHER a tool OR a skill.

PICK TOOL when the answer is "run a deterministic shell command":
  test runners, linters, formatters, build/typecheck steps,
  migrations, dev servers, git inspection, smoke-test endpoints.

PICK SKILL when the answer is "write something / make a judgement
call / follow a convention":
  design system rules, code style, file/module organization,
  domain vocabulary, architectural patterns, review checklists,
  "we always do X / never do Y here" tribal knowledge,
  framework-idiomatic patterns specific to THIS project.

If the answer involves an LLM doing creative writing or making a
choice, it's a SKILL. Period. Don't make tools whose body is a
giant `node -e ...` or `python -c ...` script — that's just an
LLM-shaped problem dressed up as a shell command.

────────────────────────────────────────────────────────────
SKILL SCHEMA (every field required)
{
  "kind": "skill",
  "id": "snake_case_unique_id",
  "name": "Short Title Case heading",
  "description": "1-line summary shown in the manage UI.",
  "trigger": "Plain-language SPECIFIC condition. NOT 'always' / 'when coding' / 'when relevant'.",
  "body": "Markdown body. Use ## subheadings, DO/DONT pairs, fenced code blocks for fragments. NO YAML frontmatter — Lumen wraps it. Do not write '## Workspace skills' — Lumen adds that header."
}

TRIGGER DISCIPLINE (this is the lever that makes skills useful)
A skill's trigger is the condition under which the agent MUST
re-read it. A trigger like "always" or "when coding" means it
fires on every turn, drowning out the genuinely-applicable rules.
Be precise:
  GOOD: "When editing files under lib/widgets/ai_chat/ or building chat UI."
  GOOD: "When the user asks for a new HTTP route or modifies api/routes.py."
  GOOD: "When generating SQL migrations under db/migrations/."
  BAD:  "always"
  BAD:  "when coding"
  BAD:  "when the user mentions UI"   (too vague)
  BAD:  "when relevant"               (lazy)
At most ONE skill per response may be 'always' (and only if the
content is a project-wide invariant, e.g. "this is a Dart 3 / null-
safe project; never write null-unsafe APIs").

BODY DISCIPLINE
- 4-30 markdown lines. SHORTER IS BETTER. The agent reads this
  every turn it triggers — every line costs token budget.
- Every skill MUST reference at least TWO concrete things from the
  project context: file paths, manifest entries, framework idioms
  the project actually uses, or named conventions visible in the
  manifest previews. If you can't, you're inventing — drop the skill.
- Prefer DO / DON'T pairs over abstract principles.
- Code fragments OK in fenced blocks. Keep them tiny — a
  representative shape, not a full implementation.
- Use the project's own vocabulary. If the manifest says "panels",
  don't write "components". If it says "cards", don't write "tiles".

GOOD vs BAD SKILLS — internalize this contrast before writing

BAD (do NOT emit anything like this):
  name:    "General Best Practices"
  trigger: "always"
  body:    "## Be Consistent\n- Follow conventions.\n- Write clean code.\n- Use meaningful names.\n- Keep functions small."
WHY BAD: every line is true for every project that has ever existed.
Provides zero project-specific signal. Tokens wasted forever.

GOOD (this is the bar):
  name:    "Dashboard layout grid"
  trigger: "When creating, modifying, or styling pages under src/pages/dashboard/."
  body:    "## Layout grid\n- Sidebar: 240px fixed; collapses to 56px below 1024px (see src/components/Sidebar.tsx).\n- Header: 56px sticky; uses tokens from design/tokens.json.\n- Main content: max-width 1280px, 24px gutter.\n\n## Components, not chrome\n- Stat cards: ALWAYS the existing <StatCard> from src/components/StatCard.tsx — never new chrome.\n- Charts: Recharts. Provide an empty state for every chart.\n\n## Don't\n- Don't introduce new accent colors. The four tokens in design/tokens.json are exhaustive."
WHY GOOD: anchored to specific files. Names a real component. Calls
out a specific anti-pattern (introducing new accent colors). The
agent saves a real wrong turn.

────────────────────────────────────────────────────────────
TOOL SCHEMA (every field required)
{
  "kind": "tool",
  "id": "snake_case_unique_id",
  "name": "UPPER_SNAKE_CASE",
  "description": "What it does AND when to use it. 1-2 sentences.",
  "syntax": "<<<NAME: arg>>>  or  <<<NAME>>>  when no arg",
  "pattern": "<<<NAME:\\s*(.*?)\\s*>>>",
  "command": ["binary", "arg1", "$1"],
  "requiresApproval": true,
  "defaultEnabled": false
}

TOOL RULES
- "pattern" must be a valid regex; capture groups for every arg.
- "command" is the OS-level argv. Use $1, $2 … for regex captures.
  Escape literal dollars as $$.
- requiresApproval: true for ANY command that mutates state — builds,
  installs, deploys, runs servers, sends network requests, modifies
  files. Read-only inspection commands can be false.
- defaultEnabled: true ONLY for read-only inspection. Mutating
  tools default off so the user opts in deliberately.
- The agent already has builtins for the boring stuff. DO NOT
  duplicate any of these ids:
    create_file, edit_file, multi_edit, append_file, move_file,
    read_file, read_file_range, list_dir, tree, search_text,
    find_file, glob, delete_file, git_status, git_diff, run_cmd,
    verify.

────────────────────────────────────────────────────────────
ANTI-PATTERNS — REJECT THESE BEFORE EMITTING

Do NOT emit a skill that:
  ✗ has trigger "always" / "when coding" / "when relevant"
    (unless it's a single project-wide invariant)
  ✗ is generic enough to apply to any project (clean code,
    write tests, use meaningful names, prefer composition)
  ✗ paraphrases the framework's own docs (the agent already
    knows React / Flutter / Django basics)
  ✗ explains what built-in agent tools already do
    (don't write "use search_text to find files" — the agent
    knows)
  ✗ has more than 30 body lines — split or trim
  ✗ has fewer than two concrete project references — drop it

Do NOT emit a tool that:
  ✗ inlines a multi-line `node -e` / `python -c` / `bash -c`
    script that hardcodes stack-specific structure (that's a
    SKILL — let the LLM produce idiomatic output)
  ✗ does design / UI / "writing" work (LLM, not shell)
  ✗ requires the user to install a binary the project context
    doesn't already reference
  ✗ duplicates a builtin (see the list above)

────────────────────────────────────────────────────────────
QUANTITY GUIDANCE
Better fewer + great than more + diluted. A typical project
deserves 2-4 high-density skills + 1-2 tools, not 5-7 mediocre
artifacts. If after reviewing the project context you can only
think of ONE great skill, emit one. Lumen will accept it.

────────────────────────────────────────────────────────────
SELF-CHECK BEFORE EMITTING JSON
Walk through every artifact one more time:
  1. Does each skill name at least two concrete things from the
     project context?
  2. Is every trigger specific enough that the agent would NOT
     re-read it on unrelated turns?
  3. Could any skill body be cut by 30%+ without losing signal?
     If yes — cut.
  4. Have I avoided every anti-pattern above?
  5. Is each artifact id unique snake_case, not colliding with
     a builtin tool?
If any answer is no, fix it before emitting. If you cannot fix it,
drop that artifact. Quantity is never a goal.

OUTPUT FORMAT
Reply with ONLY: {"artifacts": [...]}. No prose, no fences, no
explanation. The shape is parsed strictly.
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
The user just opened a fresh project in Lumen. They've told you the
project archetype(s) so you can bias toward what these stacks
typically need:

$kindLines

ADDITIONAL CONTEXT FROM USER
$userHints

PROJECT CONTEXT (top-level entries + manifest previews)
$projectContext

YOUR JOB
Write the cheatsheet for the agent that pair-programs in this repo.
Read the project context above CAREFULLY. Notice the framework, the
file layout, the test runner, the linters, the conventions implied
by manifest entries (e.g. lint rules in pubspec.yaml, scripts in
package.json, dependencies in Cargo.toml). Then ask yourself:
"What are the top 2-4 things a senior contributor would tell a new
hire about THIS project that they wouldn't already know from
reading the framework's docs?"

Those are your skills. Optionally add 1-2 tools for repetitive
shell tasks the agent will need (test, lint, build, dev server).

$_schemaAndRules

REQUIRED OUTPUT
A JSON object {"artifacts": [...]} with 2-5 entries. Quality is
not negotiable — emit fewer if you cannot meet the bar. Do NOT
pad with generic advice; the validator will accept the result
even if you only emit one artifact, but the user is much worse
off with five mediocre entries than two great ones.

Begin.
''';
  }

  String _buildCustomPrompt({
    required String projectContext,
    required CustomSkillRequest request,
  }) {
    return '''
USER REQUEST
The user wants ONE focused capability for the Lumen agent. Their
words below — translate them into the most useful artifact you can.

Their idea: ${request.name}
Their details: ${request.details.trim().isEmpty ? '(none provided)' : request.details.trim()}

PROJECT CONTEXT (top-level entries + manifest previews)
$projectContext

YOUR JOB
Decide whether the request is best served as a TOOL (deterministic
shell command) or a SKILL (instructions the agent reads). Then
build it as a senior engineer would — concrete, anchored to the
project context above, NOT a generic recipe. If the request is
vague, take the most charitable interpretation and ground it in
the actual project rather than inventing a one-size-fits-all
template.

$_schemaAndRules

REQUIRED OUTPUT
A JSON object with an "artifacts" array containing EXACTLY ONE
entry — pick tool or skill based on the decision heuristic above.

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
