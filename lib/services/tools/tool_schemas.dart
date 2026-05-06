/// JSON schemas for Lumen agent tools, used by every native
/// tool-calling provider (Anthropic `tools[]`, Gemini
/// `function_declarations`, OpenAI/GitHub Models `tools[].function`,
/// Ollama `tools[]`).
///
/// **Bridge contract.** Lumen's existing tool implementations in
/// `tool_registry.dart` are written against text-grammar regex
/// matches: each tool body calls `inv.match.group(N)` to extract
/// arguments. Rather than duplicating every tool implementation for
/// the native path, this module produces a [Match]-shaped adapter
/// from a JSON args map so the SAME tool bodies handle both paths.
/// See [ToolExecutor.runNativeToolCall].
///
/// Why not a parallel `executeFromArgs(Map)` on each tool? Two
/// reasons:
///
/// 1. ~25 tool bodies × ~30 lines each = ~750 lines of duplicate
///    plumbing for zero behavioural difference.
/// 2. The synthetic match is also the foundation for a future
///    "agent emits text grammar; we parse that into JSON; then we
///    run the native path" debug mode without re-implementing
///    anything.
///
/// **Description discipline.** Schema descriptions are intentionally
/// short and POSITIVE — they describe what the tool does, not what
/// the model should NOT do. Anti-pattern warnings (the "DO NOT MAKE
/// THESE" block in the legacy prompt) live in the system prompt
/// builder under `## Tools` and ONLY when text-grammar mode is
/// active. Native tools don't get those warnings; the schema is
/// the contract.
library;

import 'tool_match_adapter.dart';

/// JSON-schema entry for one tool. Keep this struct dep-free —
/// [ToolRegistry] / provider services / the executor all need it.
class ToolSchema {
  final String id;
  final String name; // upper-snake, matches AgentTool.name
  final String description;
  final Map<String, dynamic> inputSchema;

  /// Translates a parsed JSON args map into the ordered list of
  /// regex-capture-group strings the corresponding tool body
  /// expects. Returns `[group1, group2, ...]` — group(0) is always
  /// the synthesized full text and is computed by
  /// [SyntheticMatch] separately.
  ///
  /// Each entry can be null when the original regex would have
  /// produced a null capture (e.g. an optional second positional
  /// arg). The tool body's null checks already handle these.
  final List<String?> Function(Map<String, dynamic> args) toGroups;

  /// Build the synthetic full-match text for the [SyntheticMatch.group(0)]
  /// fallback. Tool bodies rarely consult group(0) but a few do
  /// (the executor's `_friendlyReplacement` uses it for
  /// `replaceAll`). We synthesize a plausible-looking
  /// `<<<TOOL: args>>>` so debugging output stays readable.
  final String Function(Map<String, dynamic> args) toRawText;

  const ToolSchema({
    required this.id,
    required this.name,
    required this.description,
    required this.inputSchema,
    required this.toGroups,
    required this.toRawText,
  });
}

/// Common JSON-schema fragments. Tools share these to keep the
/// schema definitions DRY and consistent across providers.
const _objectSchema = 'object';
const _stringSchema = 'string';
const _intSchema = 'integer';

Map<String, dynamic> _strProp(String desc) => <String, dynamic>{
  'type': _stringSchema,
  'description': desc,
};
Map<String, dynamic> _intProp(String desc) => <String, dynamic>{
  'type': _intSchema,
  'description': desc,
};
Map<String, dynamic> _boolProp(String desc) => <String, dynamic>{
  'type': 'boolean',
  'description': desc,
};

/// All canonical Lumen tool schemas. Descriptions are tuned for
/// native tool-calling — short, positive, no scolding. The
/// system prompt's discipline rules cover meta-policy (read
/// before edit, one tool per turn, etc.).
class ToolSchemas {
  ToolSchemas._();

  static final List<ToolSchema> all = <ToolSchema>[
    // ── File mutation ────────────────────────────────────────
    ToolSchema(
      id: 'create_file',
      name: 'CREATE_FILE',
      description:
          'Create a NEW file with the given content. Refuses to '
          'overwrite an existing file unless overwrite=true. Prefer '
          'edit_file / multi_edit for changes to existing files.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative path of the new file.'),
          'content': _strProp('Full file contents as a single string.'),
          'overwrite': _boolProp(
            'Optional. When true, replaces an existing file. Default false.',
          ),
        },
        'required': ['path', 'content'],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        final content = (args['content'] as String?) ?? '';
        final overwrite = args['overwrite'] == true;
        // Original regex group 1 is the (optionally-`:overwrite`-suffixed) path.
        return [overwrite ? '$path:overwrite' : path, content];
      },
      toRawText: (args) {
        final path = (args['path'] as String?) ?? '';
        final overwrite = args['overwrite'] == true;
        final suffix = overwrite ? ':overwrite' : '';
        return '<<<CREATE_FILE: $path$suffix>>>\n${args['content'] ?? ''}\n<<<END_FILE>>>';
      },
    ),
    ToolSchema(
      id: 'edit_file',
      name: 'EDIT_FILE',
      description:
          'Edit an existing file by replacing one specific text block. '
          'The search string must match the file EXACTLY (whitespace '
          'and indentation included) and uniquely. For multiple edits '
          'in one file, use multi_edit instead.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative path of the file to edit.'),
          'search': _strProp(
            'The exact text to find. Must match the file byte-for-byte and '
            'occur exactly once.',
          ),
          'replace': _strProp('The replacement text.'),
        },
        'required': ['path', 'search', 'replace'],
      },
      toGroups: (args) => [
        (args['path'] as String?) ?? '',
        (args['search'] as String?) ?? '',
        (args['replace'] as String?) ?? '',
      ],
      toRawText: (args) =>
          '<<<EDIT_FILE: ${args['path'] ?? ''}>>>\n'
          '<<<SEARCH>>>\n${args['search'] ?? ''}\n'
          '<<<REPLACE>>>\n${args['replace'] ?? ''}\n'
          '<<<END_EDIT>>>',
    ),
    ToolSchema(
      id: 'multi_edit',
      name: 'MULTI_EDIT',
      description:
          'Apply multiple search/replace edits to one file in a single '
          'tool call. Each edit\'s search must match the file exactly '
          'and uniquely at the time it is applied (later edits see the '
          'output of earlier ones).',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative path of the file to edit.'),
          'edits': {
            'type': 'array',
            'description': 'Ordered list of search/replace pairs to apply.',
            'items': {
              'type': _objectSchema,
              'properties': {
                'search': _strProp('Exact text to find for this edit.'),
                'replace': _strProp('Replacement text for this edit.'),
              },
              'required': ['search', 'replace'],
            },
          },
        },
        'required': ['path', 'edits'],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        // Original regex captures: group(1)=path, group(2)=body containing
        // alternating SEARCH/REPLACE/NEXT markers. Re-synthesize the body
        // exactly so the existing parser handles it.
        final edits = (args['edits'] as List?) ?? const [];
        final buf = StringBuffer();
        for (var i = 0; i < edits.length; i++) {
          final e = edits[i] as Map<String, dynamic>;
          if (i > 0) buf.writeln('<<<NEXT>>>');
          buf.writeln('<<<SEARCH>>>');
          buf.writeln(e['search'] ?? '');
          buf.writeln('<<<REPLACE>>>');
          buf.writeln(e['replace'] ?? '');
        }
        return [path, buf.toString().trimRight()];
      },
      toRawText: (args) {
        final path = (args['path'] as String?) ?? '';
        final edits = (args['edits'] as List?) ?? const [];
        final body = StringBuffer();
        for (var i = 0; i < edits.length; i++) {
          final e = edits[i] as Map<String, dynamic>;
          if (i > 0) body.writeln('<<<NEXT>>>');
          body.writeln('<<<SEARCH>>>');
          body.writeln(e['search'] ?? '');
          body.writeln('<<<REPLACE>>>');
          body.writeln(e['replace'] ?? '');
        }
        return '<<<MULTI_EDIT: $path>>>\n$body<<<END_EDIT>>>';
      },
    ),
    ToolSchema(
      id: 'edit_range',
      name: 'EDIT_RANGE',
      description:
          'Replace a contiguous line range in a file with new content. '
          'Use when you know the exact 1-based line numbers (from a '
          'preceding read_file) and want to overwrite that span.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative file path.'),
          'start_line': _intProp('First line to replace (1-based, inclusive).'),
          'end_line': _intProp('Last line to replace (1-based, inclusive).'),
          'content': _strProp(
            'New content for that range. Newlines preserved literally.',
          ),
        },
        'required': ['path', 'start_line', 'end_line', 'content'],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        final start = args['start_line'];
        final end = args['end_line'];
        return ['$path:$start-$end', (args['content'] as String?) ?? ''];
      },
      toRawText: (args) =>
          '<<<EDIT_RANGE: ${args['path'] ?? ''}:${args['start_line']}-${args['end_line']}>>>\n'
          '${args['content'] ?? ''}\n'
          '<<<END_EDIT>>>',
    ),
    ToolSchema(
      id: 'append_file',
      name: 'APPEND_FILE',
      description:
          'Append content to the end of an existing file. Creates the '
          'file if it doesn\'t exist.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative file path.'),
          'content': _strProp('Content to append. Newlines preserved.'),
        },
        'required': ['path', 'content'],
      },
      toGroups: (args) => [
        (args['path'] as String?) ?? '',
        (args['content'] as String?) ?? '',
      ],
      toRawText: (args) =>
          '<<<APPEND_FILE: ${args['path'] ?? ''}>>>\n${args['content'] ?? ''}\n<<<END_APPEND>>>',
    ),
    ToolSchema(
      id: 'move_file',
      name: 'MOVE_FILE',
      description: 'Rename or move a file within the workspace.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'src': _strProp('Source workspace-relative path.'),
          'dst': _strProp('Destination workspace-relative path.'),
        },
        'required': ['src', 'dst'],
      },
      toGroups: (args) => [
        (args['src'] as String?) ?? '',
        (args['dst'] as String?) ?? '',
      ],
      toRawText: (args) =>
          '<<<MOVE_FILE: ${args['src'] ?? ''} -> ${args['dst'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'copy_file',
      name: 'COPY_FILE',
      description:
          'Copy a file or directory tree to a new location within the '
          'workspace.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'src': _strProp('Source workspace-relative path.'),
          'dst': _strProp('Destination workspace-relative path.'),
        },
        'required': ['src', 'dst'],
      },
      toGroups: (args) => [
        (args['src'] as String?) ?? '',
        (args['dst'] as String?) ?? '',
      ],
      toRawText: (args) =>
          '<<<COPY_FILE: ${args['src'] ?? ''} -> ${args['dst'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'delete_file',
      name: 'DELETE_FILE',
      description:
          'Delete a file or empty directory from the workspace. '
          'Requires user approval.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {'path': _strProp('Workspace-relative path to delete.')},
        'required': ['path'],
      },
      toGroups: (args) => [(args['path'] as String?) ?? ''],
      toRawText: (args) => '<<<DELETE_FILE: ${args['path'] ?? ''}>>>',
    ),

    // ── File / workspace inspection ──────────────────────────
    ToolSchema(
      id: 'read_file',
      name: 'READ_FILE',
      description:
          'Read a file\'s contents (whole file or a line range). For '
          'large files, prefer specifying start_line and end_line to '
          'avoid loading megabytes you don\'t need.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative file path.'),
          'start_line': _intProp(
            'Optional 1-based start line. Inclusive. Omit for whole-file read.',
          ),
          'end_line': _intProp(
            'Optional 1-based end line. Inclusive. Omit for whole-file read.',
          ),
        },
        'required': ['path'],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        final start = args['start_line'];
        final end = args['end_line'];
        if (start != null && end != null) {
          return ['$path:$start-$end'];
        }
        return [path];
      },
      toRawText: (args) {
        final path = (args['path'] as String?) ?? '';
        final start = args['start_line'];
        final end = args['end_line'];
        return start != null && end != null
            ? '<<<READ_FILE: $path:$start-$end>>>'
            : '<<<READ_FILE: $path>>>';
      },
    ),
    ToolSchema(
      id: 'list_dir',
      name: 'LIST_DIR',
      description:
          'List immediate children of a directory (files and subdirs). '
          'Use tree for nested layout instead.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp(
            'Workspace-relative directory path. "." or empty = workspace root.',
          ),
        },
        'required': ['path'],
      },
      toGroups: (args) => [(args['path'] as String?) ?? '.'],
      toRawText: (args) => '<<<LIST_DIR: ${args['path'] ?? '.'}>>>',
    ),
    ToolSchema(
      id: 'tree',
      name: 'TREE',
      description:
          'Render a recursive directory tree (depth-limited, with '
          'common build-output dirs filtered out).',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp(
            'Workspace-relative starting directory. "." for workspace root.',
          ),
        },
        'required': ['path'],
      },
      toGroups: (args) => [(args['path'] as String?) ?? '.'],
      toRawText: (args) => '<<<TREE: ${args['path'] ?? '.'}>>>',
    ),
    ToolSchema(
      id: 'search_text',
      name: 'SEARCH_TEXT',
      description:
          'Search file contents for a substring or regex pattern. '
          'Backed by ripgrep — fast even on large repos.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'query': _strProp(
            'Text or pattern to find. Treated as a literal substring '
            'unless regex=true.',
          ),
          'regex': _boolProp('Optional. When true, treat query as a regex.'),
          'glob': _strProp(
            'Optional file glob to limit the search (e.g. "lib/**/*.dart").',
          ),
          'context': _intProp(
            'Optional number of context lines to show around each match.',
          ),
        },
        'required': ['query'],
      },
      toGroups: (args) {
        final q = (args['query'] as String?) ?? '';
        final flags = <String>[];
        if (args['regex'] == true) flags.add(':re');
        final glob = args['glob'] as String?;
        if (glob != null && glob.isNotEmpty) flags.add(':glob=$glob');
        final ctx = args['context'];
        if (ctx is int) flags.add(':context=$ctx');
        return [flags.isEmpty ? q : '$q ${flags.join(' ')}'];
      },
      toRawText: (args) {
        final q = (args['query'] as String?) ?? '';
        final flags = <String>[];
        if (args['regex'] == true) flags.add(':re');
        final glob = args['glob'] as String?;
        if (glob != null && glob.isNotEmpty) flags.add(':glob=$glob');
        final ctx = args['context'];
        if (ctx is int) flags.add(':context=$ctx');
        final body = flags.isEmpty ? q : '$q ${flags.join(' ')}';
        return '<<<SEARCH_TEXT: $body>>>';
      },
    ),
    ToolSchema(
      id: 'find_file',
      name: 'FIND_FILE',
      description:
          'Find files by partial name match (case-insensitive substring '
          'over file basenames). For glob patterns, use glob.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'query': _strProp('Substring of the filename to search for.'),
        },
        'required': ['query'],
      },
      toGroups: (args) => [(args['query'] as String?) ?? ''],
      toRawText: (args) => '<<<FIND_FILE: ${args['query'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'glob',
      name: 'GLOB',
      description:
          'Find files matching a glob pattern (** for recursive, * for '
          'one path segment, ? for one char).',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'pattern': _strProp('Glob pattern, e.g. "lib/**/*.dart".'),
        },
        'required': ['pattern'],
      },
      toGroups: (args) => [(args['pattern'] as String?) ?? ''],
      toRawText: (args) => '<<<GLOB: ${args['pattern'] ?? ''}>>>',
    ),

    // ── Git ──────────────────────────────────────────────────
    ToolSchema(
      id: 'git_status',
      name: 'GIT_STATUS',
      description: 'Show the workspace\'s git status (branch + porcelain).',
      inputSchema: {
        'type': _objectSchema,
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
      toGroups: (args) => const <String?>[],
      toRawText: (_) => '<<<GIT_STATUS>>>',
    ),
    ToolSchema(
      id: 'git_diff',
      name: 'GIT_DIFF',
      description:
          'Show a git diff. Optional revision argument: "staged" for '
          '--cached, a git revision (e.g. "HEAD~1"), or omit for '
          'unstaged changes.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'revision': _strProp(
            'Optional. "staged" for --cached, or a git revision spec.',
          ),
        },
        'required': <String>[],
      },
      toGroups: (args) => [args['revision'] as String?],
      toRawText: (args) {
        final rev = args['revision'] as String?;
        return rev == null || rev.isEmpty
            ? '<<<GIT_DIFF>>>'
            : '<<<GIT_DIFF: $rev>>>';
      },
    ),
    ToolSchema(
      id: 'git_log',
      name: 'GIT_LOG',
      description:
          'Show recent git commits. Optional path arg restricts to '
          'commits touching that file/dir; n controls count (default 20).',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp(
            'Optional file or directory path to scope the log to.',
          ),
          'n': _intProp('Optional commit count cap. Default 20.'),
        },
        'required': <String>[],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        final n = args['n'];
        final flags = n is int ? ':n=$n' : '';
        if (path.isEmpty && flags.isEmpty) return const <String?>[null];
        return ['$path${flags.isEmpty ? '' : ' $flags'}'];
      },
      toRawText: (args) {
        final path = (args['path'] as String?) ?? '';
        final n = args['n'];
        final flags = n is int ? ' :n=$n' : '';
        if (path.isEmpty && flags.isEmpty) return '<<<GIT_LOG>>>';
        return '<<<GIT_LOG: $path$flags>>>';
      },
    ),
    ToolSchema(
      id: 'git_blame',
      name: 'GIT_BLAME',
      description:
          'Show git blame for a file or specific line range. '
          'Optional start_line/end_line scope the blame.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'path': _strProp('Workspace-relative file path.'),
          'start_line': _intProp(
            'Optional first line to blame (1-based, inclusive).',
          ),
          'end_line': _intProp(
            'Optional last line to blame (1-based, inclusive).',
          ),
        },
        'required': ['path'],
      },
      toGroups: (args) {
        final path = (args['path'] as String?) ?? '';
        final s = args['start_line'];
        final e = args['end_line'];
        if (s is int && e is int) {
          return [path, '$s', '$e'];
        }
        return [path, null, null];
      },
      toRawText: (args) {
        final path = (args['path'] as String?) ?? '';
        final s = args['start_line'];
        final e = args['end_line'];
        return s is int && e is int
            ? '<<<GIT_BLAME: $path:$s-$e>>>'
            : '<<<GIT_BLAME: $path>>>';
      },
    ),

    // ── Execution / verification ─────────────────────────────
    ToolSchema(
      id: 'check_url',
      name: 'CHECK_URL',
      description:
          'Probe a URL or local port for reachability. Accepts full '
          'URLs, host:port pairs, and bare port numbers (defaults to '
          'localhost). Use BEFORE starting a dev server to avoid '
          'spawning a duplicate.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'url': _strProp(
            'URL, host:port, or bare port number (e.g. 3000, '
            'localhost:5173, https://example.com).',
          ),
        },
        'required': ['url'],
      },
      toGroups: (args) => [(args['url'] as String?) ?? ''],
      toRawText: (args) => '<<<CHECK_URL: ${args['url'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'run_cmd',
      name: 'RUN_CMD',
      description:
          'Execute a shell command in the workspace. Long-running '
          'commands (dev servers, watchers) detach into a visible '
          'terminal-pane tab. Requires user approval.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'command': _strProp(
            'The exact command line to run (no shell function-style '
            'wrapping, just the bare command as you would type it).',
          ),
        },
        'required': ['command'],
      },
      toGroups: (args) => [(args['command'] as String?) ?? ''],
      toRawText: (args) => '<<<RUN_CMD: ${args['command'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'verify',
      name: 'VERIFY',
      description:
          'Run the workspace\'s analyzer / type-checker and report any '
          'errors. No-op when the workspace has no recognized analyzer.',
      inputSchema: {
        'type': _objectSchema,
        'properties': <String, dynamic>{},
        'required': <String>[],
      },
      toGroups: (args) => const <String?>[],
      toRawText: (_) => '<<<VERIFY>>>',
    ),

    // ── Web (Ollama Cloud-backed) ────────────────────────────
    ToolSchema(
      id: 'web_search',
      name: 'WEB_SEARCH',
      description:
          'Search the public web via Ollama Cloud and return ranked '
          'results (title, URL, content snippet). Requires Ollama '
          'Cloud API key.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'query': _strProp('Search query.'),
          'max_results': _intProp(
            'Optional result count cap (1..10, default 5).',
          ),
        },
        'required': ['query'],
      },
      toGroups: (args) {
        final q = (args['query'] as String?) ?? '';
        final n = args['max_results'];
        return [n is int ? '$q :max=$n' : q];
      },
      toRawText: (args) {
        final q = (args['query'] as String?) ?? '';
        final n = args['max_results'];
        return n is int
            ? '<<<WEB_SEARCH: $q :max=$n>>>'
            : '<<<WEB_SEARCH: $q>>>';
      },
    ),
    ToolSchema(
      id: 'web_fetch',
      name: 'WEB_FETCH',
      description:
          'Fetch a single web page via Ollama Cloud and return its '
          'extracted text content. Requires Ollama Cloud API key.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'url': _strProp('Full URL to fetch (https:// is auto-prepended).'),
        },
        'required': ['url'],
      },
      toGroups: (args) => [(args['url'] as String?) ?? ''],
      toRawText: (args) => '<<<WEB_FETCH: ${args['url'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'council_dispatch',
      name: 'COUNCIL_DISPATCH',
      description:
          'Assign a task to a named Council agent. Use parallel=true for independent work.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'agentId': _strProp('Target Council agent id.'),
          'task': _strProp('Specific task for that agent.'),
          'parallel': _boolProp('Whether the task can run concurrently.'),
        },
        'required': ['agentId', 'task'],
      },
      toGroups: (args) => [
        (args['agentId'] as String?) ?? '',
        (args['task'] as String?) ?? '',
        '${args['parallel'] == true}',
      ],
      toRawText: (args) =>
          '<<<COUNCIL_DISPATCH: ${args['agentId'] ?? ''}>>>\n'
          '${args['task'] ?? ''}\n<<<END_COUNCIL>>>',
    ),
    ToolSchema(
      id: 'council_ask_pool',
      name: 'COUNCIL_ASK_POOL',
      description:
          'Ask sibling Council agents a concise question and receive their replies.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'question': _strProp('Question for the other Council agents.'),
        },
        'required': ['question'],
      },
      toGroups: (args) => [(args['question'] as String?) ?? ''],
      toRawText: (args) => '<<<COUNCIL_ASK_POOL: ${args['question'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'council_ask_user',
      name: 'COUNCIL_ASK_USER',
      description:
          'Ask the user for missing information needed to continue the Council session.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'question': _strProp('Question to present to the user.'),
        },
        'required': ['question'],
      },
      toGroups: (args) => [(args['question'] as String?) ?? ''],
      toRawText: (args) => '<<<COUNCIL_ASK_USER: ${args['question'] ?? ''}>>>',
    ),
    ToolSchema(
      id: 'council_report',
      name: 'COUNCIL_REPORT',
      description: 'Finalize the Council session with a markdown report.',
      inputSchema: {
        'type': _objectSchema,
        'properties': {
          'markdown': _strProp('Final markdown report for the user.'),
        },
        'required': ['markdown'],
      },
      toGroups: (args) => [(args['markdown'] as String?) ?? ''],
      toRawText: (args) =>
          '<<<COUNCIL_REPORT>>>\n${args['markdown'] ?? ''}\n<<<END_COUNCIL>>>',
    ),
  ];

  static final Map<String, ToolSchema> _byId = {for (final s in all) s.id: s};

  static ToolSchema? byId(String id) => _byId[id];

  /// Build a Match-shaped adapter for [tool] from a parsed JSON
  /// args map. Used by [ToolExecutor.runNativeToolCall] to dispatch
  /// the existing tool body without rewriting it.
  static SyntheticMatch matchFor(ToolSchema schema, Map<String, dynamic> args) {
    final groups = schema.toGroups(args);
    final raw = schema.toRawText(args);
    return SyntheticMatch(rawText: raw, groups: groups);
  }
}
