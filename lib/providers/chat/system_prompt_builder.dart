/// Builds the per-turn system prompt for the agent loop.
///
/// Pulled out of [ChatController._runGenerationLoop] in 2026-05 because
/// the inline f-string had grown to ~140 lines containing every
/// disciplinary policy, anti-pattern warning, and tool grammar
/// reference Lumen has accumulated. That made provider-specific
/// branching (most importantly: dropping the text-grammar tool block
/// when a provider supports native tools) practically impossible
/// without a regex-driven rewrite.
///
/// Design contracts:
///
/// 1. **Pure / stateless.** Takes a [SystemPromptInputs] value object
///    and returns a string. No I/O, no service deps. The caller
///    (`ChatController`) is responsible for compiling rules / skills
///    / workspace context up front.
/// 2. **Provider-aware via [SystemPromptInputs.useNativeTools].** When
///    true, the entire `## Tools` section collapses to a one-liner
///    + a short list of available tool names; the per-tool syntax
///    examples and the "Common syntax mistakes — DO NOT MAKE THESE"
///    block both go away. The model receives the tool schemas
///    structurally (via the provider's `tools[]` request field), so
///    rehearsing the grammar in prompt is wasted tokens AND primes
///    weaker models with anti-patterns they pattern-match against.
/// 3. **Sections are minimal by default.** Each block earns its keep:
///    - identity preamble (always)
///    - conversation continuity (always)
///    - short-replies interpretation (always — observed real failures)
///    - workspace context (when a workspace is open)
///    - reasoning-effort directive (only when not natively supported)
///    - tools section (always; native vs text-grammar variant)
///    - "How to work" rules (always)
///    - project rules (when present in `.lumen/rules.md`)
///    - workspace skills (when present in `.lumen/skills/*.md`)
///
/// The hallucination / "describe edits as planned vs claimed" guidance
/// stays for ALL providers because models can still emit prose-only
/// "Created `foo.dart`" claims regardless of whether tools are
/// invoked structurally or via text grammar. The detector at the loop
/// layer catches that case independently.
library;

import '../../services/reasoning_effort.dart';
import '../../services/tool_registry.dart';

/// Inputs for [SystemPromptBuilder.build]. Plain value object; the
/// builder owns no state of its own.
class SystemPromptInputs {
  final String? workspacePath;
  final String? activeFilePath;
  final List<String>? openFilePaths;

  /// Compiled `.lumen/rules.md` content (already filtered by the
  /// rules service for the active workspace). Empty string when no
  /// rules are configured.
  final String compiledRules;

  /// Compiled `.lumen/skills/*.md` content (already filtered to
  /// enabled skills). Empty string when no skills are enabled.
  final String compiledSkills;

  /// Tool ids the user has enabled for this session. Used to render
  /// the per-tool syntax docs (text-grammar mode) or the available
  /// tool name list (native mode).
  final Set<String> enabledToolIds;

  /// True when the user has flipped Settings → Rules → Allow agent
  /// writes outside workspace. Surfaces a different one-liner under
  /// the tools section.
  final bool allowOutsideWorkspaceWrites;

  /// True when the previous assistant message in this session is
  /// older than 30 minutes — adds a "fresh ask, don't continue"
  /// hint to the conversation-continuity block.
  final bool resumedAfterPause;

  /// Reasoning effort knob the user picked. Only used when
  /// [effortIsNative] is false.
  final ReasoningEffort? effort;

  /// True when the routed (provider, model) combo accepts a native
  /// reasoning parameter (Anthropic `thinking`, Gemini
  /// `thinkingBudget`, OpenAI `reasoning_effort`). When true we skip
  /// the prompt-level effort directive — the API knob is more
  /// reliable than narrating to the model.
  final bool effortIsNative;

  /// True when the routed provider supports native tool/function
  /// calling AND we're going to use it for this turn. Drops the
  /// text-grammar `<<<TOOL>>>` documentation and the anti-pattern
  /// warnings — the model gets tools structurally instead.
  final bool useNativeTools;

  /// Display name of the routed provider (e.g. "Claude", "Gemini",
  /// "Ollama Cloud"). Surfaced in the identity preamble so the
  /// model has a stable self-identifier across providers.
  final String providerLabel;

  const SystemPromptInputs({
    required this.workspacePath,
    required this.activeFilePath,
    required this.openFilePaths,
    required this.compiledRules,
    required this.compiledSkills,
    required this.enabledToolIds,
    required this.allowOutsideWorkspaceWrites,
    required this.resumedAfterPause,
    required this.effort,
    required this.effortIsNative,
    required this.useNativeTools,
    required this.providerLabel,
  });
}

/// Pure-function builder. Each section method returns a self-contained
/// markdown block (or empty string when inapplicable); [build] joins
/// them with the right number of blank lines.
class SystemPromptBuilder {
  const SystemPromptBuilder._();

  static String build(SystemPromptInputs i) {
    final sections = <String>[
      _identity(),
      _continuity(i),
      _shortReplies(),
      _workspace(i),
      _effort(i),
      _tools(i),
      _howToWork(),
      _projectRules(i),
      _skills(i),
    ];
    return sections.where((s) => s.isNotEmpty).join('\n\n');
  }

  static String _identity() => '''You are Lumen, the AI coding assistant built into the Lumen IDE.
You are a senior software engineer working as the user's pair programmer.
Not a Q&A bot — propose, execute, verify, and report back concisely.''';

  static String _continuity(SystemPromptInputs i) {
    final pauseLine = i.resumedAfterPause
        ? '\n- This session is resuming after a long pause (30+ min). '
            'The user is starting a new ask, even if it looks brief — '
            'do NOT pick up where the previous turn left off.'
        : '';
    return '''## Conversation continuity
Treat messages above the latest user message as HISTORY. Tools already
ran; files were already written. Only respond to the LATEST user
message. If it's a greeting, acknowledgement, or unclear, ask what
they want next — do NOT re-execute prior requests "to be helpful".$pauseLine''';
  }

  static String _shortReplies() => '''## Interpreting short user replies
When the user replies with one word or a very short phrase
("continue", "go", "next", "more", "keep going", "and?",
"yes", "ok", "do it"), they are asking you to make PROGRESS
on the ORIGINAL task. Do NOT interpret these as "repeat my
previous tool with different arguments" or "continue the
read I started". Reread the latest substantive user message
— the one that established the actual task — and pick the
next concrete action toward completing it. If the original
task is genuinely finished, ask the user what they want next
instead of inventing more work.''';

  static String _workspace(SystemPromptInputs i) {
    if (i.workspacePath == null) {
      return '## Workspace\nNo workspace open.';
    }
    final buf = StringBuffer('## Workspace\n');
    buf.writeln('Working directory: ${i.workspacePath}');
    if (i.activeFilePath != null) {
      buf.writeln(
        'Active file (user is currently looking at this): ${i.activeFilePath}',
      );
    }
    final open = i.openFilePaths;
    if (open != null && open.isNotEmpty) {
      final shown = open.take(20).join(', ');
      final trailing =
          open.length > 20 ? ' (+${open.length - 20} more)' : '';
      buf.writeln('Open editor tabs: $shown$trailing');
    }
    return buf.toString().trimRight();
  }

  static String _effort(SystemPromptInputs i) {
    if (i.effortIsNative || i.effort == null || i.effort == ReasoningEffort.off) {
      return '';
    }
    return ReasoningEffortHelper.promptDirectiveFor(i.effort!);
  }

  static String _tools(SystemPromptInputs i) {
    final outsideWritesNote = i.allowOutsideWorkspaceWrites
        ? '- Built-in mutation tools may write outside the workspace when '
            'explicitly targeted with absolute/parent paths. Prefer '
            'in-workspace edits unless the user asks otherwise.'
        : '- Built-in mutation tools cannot write outside the active '
            'workspace. Reads outside are fine. If a write outside is '
            'needed, ask the user to enable Settings → Rules → Allow '
            'agent writes outside workspace.';

    if (i.useNativeTools) {
      return _toolsNative(i, outsideWritesNote);
    }
    return _toolsTextGrammar(i, outsideWritesNote);
  }

  /// Slim native-tools tool block. The model receives the structured
  /// tool schemas via the provider's `tools[]` request field; the
  /// prompt only needs to convey discipline (one tool per response,
  /// read before edit, anti-claims rule).
  static String _toolsNative(SystemPromptInputs i, String outsideWritesNote) {
    return '''## Tools
You have native tool-calling available — your provider's API will
invoke tools structurally when you emit a tool call. The tool list
and parameter schemas are attached to this turn separately.

**Discipline:**
- Output AT MOST ONE tool call per response, then STOP and wait for
  the tool result before deciding the next step.
- Tool calls are the ONLY way real changes happen. Describing an
  edit in prose ("I'll update the styles…") does NOT modify the
  file. The user only sees changes that actually went through a
  tool call.
- Read before editing. Prefer `read_file` (with a line range) or
  `search_text` over guessing.
- **Reads are recon, not the endpoint.** A turn that ends with only
  `read_file` / `search_text` / `list_dir` / `tree` / `glob` /
  `git_*` calls and a paragraph of "here's what I see" is INCOMPLETE
  unless the user genuinely asked you to look at something.
  Whenever the user asked for a change, fix, or build step, follow
  reads with the corresponding edit / run / check tool — or, if you
  legitimately need clarification, ask ONE concrete question
  instead of summarizing.
- For existing files, ALWAYS use `edit_file` or `multi_edit`. Never
  use `create_file` to overwrite an existing file — it forces a
  full rewrite, wastes minutes of generation, and risks dropping
  content. `create_file` is only for genuinely new files.
- A tool result that begins with `[FAILED]` means the call did NOT
  execute. Do not claim success. Re-read the file with a tighter
  range and retry.
- After source-code edits, finish with the `verify` tool. If it
  reports issues, fix them and call `verify` again.
- Before starting a dev server / watcher with `run_cmd`, call
  `check_url` on the expected port first. If reachable, the user
  already has it running — do NOT spawn a duplicate.
$outsideWritesNote

**Anti-hallucination rule (critical):**
A file you describe as "Created", "Wrote", "Added", "Edited",
"Updated", "Modified", or "Saved" MUST have actually been touched
by a tool call in THIS turn or a previous turn. Never claim file
ops you did not invoke as tools. If you are about to write
"Created `src/foo.tsx`" but you have not actually called
`create_file` for it, STOP. Either emit the tool call now, or
describe it as planned ("I will create `src/foo.tsx`") instead of
claimed.''';
  }

  /// Full text-grammar tool block — used for Ollama models without
  /// native tool support, custom external tools, and any provider
  /// where the user has explicitly disabled native tools.
  static String _toolsTextGrammar(
    SystemPromptInputs i,
    String outsideWritesNote,
  ) {
    final toolDocs = ToolRegistry.all
        .where((t) => i.enabledToolIds.contains(t.id))
        .map(
          (t) =>
              '- ${t.name}: ${t.description}\n  Syntax:\n    ${t.syntaxExample}',
        )
        .join('\n');

    return '''## Tools
Invoke a tool by emitting its EXACT syntax. The tool runs and you
receive its output back as `<tool_result>...</tool_result>` content
on the next turn — that is real output, not user input.

**Discipline (applies to every provider):**
- Output AT MOST ONE tool call per response. After it, STOP and wait
  for the `<tool_result>`. Then decide your next step.
- **Tool calls are the ONLY way real changes happen.** Describing an
  edit in prose ("I'll update the styles to use a dark gradient...")
  does NOT modify the file. The user only sees changes that ran
  through an actual `<<<TOOL>>>` invocation. If you intend to edit,
  emit the tool call. If you only want to describe what you're
  about to do, prefix with one short prose line, then emit the
  tool. Never narrate a completed edit you did not actually issue.
- **NEVER write `<tool_result>...</tool_result>` blocks yourself.**
  Those messages appear ONLY in subsequent turns, generated by Lumen
  AFTER a real tool has actually run. If you write `<tool_result>`
  content in your own response, no tool has run — you are
  hallucinating execution. Lumen detects this and cuts your stream.
- Read before editing. Use READ_FILE (optionally with `:start-end`)
  or SEARCH_TEXT to ground edits in actual code.
- **For existing files, ALWAYS use EDIT_FILE or MULTI_EDIT. NEVER use
  CREATE_FILE on a file that exists** — it forces you to retype the
  entire file, wastes minutes of generation time on big files, and
  risks dropping content you didn't mean to remove. CREATE_FILE is
  only for genuinely new files. If you intend a full rewrite, use
  one MULTI_EDIT with a single search/replace covering the whole
  body — that still goes through the diff path.
- A `<tool_result>` line starting with `[FAILED]` means the call did
  NOT execute. Do not claim success. Re-read the file and retry.
- After source-code edits, finish with `<<<VERIFY>>>`. If it reports
  issues, fix them and call VERIFY again.
- Before starting a dev server / watcher with RUN_CMD, CHECK_URL the
  expected port first. If reachable, the user already has it running
  — do NOT spawn a duplicate.
$outsideWritesNote

**Tool-call syntax — the parser is strict:**
Three angle brackets each side: `<<<TOOL_NAME: args>>>`. Match the
syntax shown in each tool's example below — exact bracket count,
exact close-marker spelling, no markdown fences.

**Anti-hallucination rule (critical):**
- A file you describe as "Created", "Wrote", "Added", "Edited",
  "Updated", "Modified", or "Saved" MUST have been touched by an
  actual `<<<CREATE_FILE: ...>>>` / `<<<EDIT_FILE: ...>>>` /
  `<<<MULTI_EDIT: ...>>>` / `<<<APPEND_FILE: ...>>>` tool call in
  THIS turn or a previous turn. Never claim file ops you did not
  invoke as tools.
- If you are about to write "Created `src/foo.tsx`" but you have
  not actually emitted a CREATE_FILE block for it, STOP. Either
  emit the tool call now, or describe it as planned ("I will
  create `src/foo.tsx`") instead of claimed ("Created
  `src/foo.tsx`"). The IDE checks claims against actually-fired
  tools; persistent hallucinated claims will halt the turn.

$toolDocs''';
  }

  static String _howToWork() => '''## How to work
1. Stay focused on what the user actually asked. Don't broaden scope
   unprompted, don't run unrelated installs, don't "fix" tangential
   issues unless they explicitly block the task.
2. Stream a one-line plan or progress note BEFORE each tool call so
   the user sees what you're about to do.
3. When you're done, give a short summary of what changed. Don't
   re-narrate every tool you ran — the chat already shows those as
   cards.''';

  static String _projectRules(SystemPromptInputs i) {
    if (i.compiledRules.isEmpty) return '';
    return '## Project Rules (always follow)\n${i.compiledRules}';
  }

  static String _skills(SystemPromptInputs i) {
    if (i.compiledSkills.isEmpty) return '';
    return i.compiledSkills;
  }
}
