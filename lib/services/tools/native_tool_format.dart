/// Provider-neutral helpers for native tool calling.
///
/// Lumen's chat history list is the canonical state — every provider
/// service translates from this neutral shape into its native
/// request format. The translation itself is per-provider (different
/// services have different tool_use envelope shapes), but the
/// in-memory message list, the streaming markers, and the
/// `tools[]` schema preparation are uniform.
///
/// Message-shape conventions (extending the existing
/// `{role, content, images?}` format used by [ChatController]):
///
/// - **Assistant turn that called a tool natively:**
///   ```dart
///   {
///     'role': 'assistant',
///     'content': '<the prose preceding the tool call>',
///     'tool_use': {
///       'id': '<provider-supplied id, or synthesized>',
///       'name': '<tool id, e.g. read_file>',
///       'arguments': { /* JSON args */ },
///     },
///   }
///   ```
/// - **Tool-result reply:**
///   ```dart
///   {
///     'role': 'tool',
///     'tool_use_id': '<matches assistant.tool_use.id>',
///     'content': '<textual feedback the executor produced>',
///   }
///   ```
///
/// The controller's text-grammar path emits assistant turns as plain
/// `{role: 'assistant', content: '<text including <<<TOOL>>>'}`
/// and tool_result as `{role: 'user', content: '<tool_result>...</tool_result>'}`.
/// Both paths can coexist in one chat history; per-provider builders
/// dispatch on the presence of `tool_use` / `role == 'tool'` to
/// pick the right output shape.
library;

import 'dart:convert';

import 'tool_schemas.dart';

/// Stream-marker emitted by a provider service when it has parsed a
/// complete native tool_use block. The marker carries the JSON
/// payload the controller needs to dispatch the call.
///
/// Format: `<!-- LUMEN_NATIVE_TOOL_USE:<base64-utf8-json> -->\n`
///
/// Why a marker in a `Stream<String>` rather than a typed event:
/// changing the stream interface from `String` to a sealed event
/// type would ripple through 4 provider services + the
/// controller's throttle / aggregate / detector logic. Keeping
/// the marker in the same stream lets all that logic stay
/// text-based; the controller only needs an extra parse on each
/// chunk.
///
/// Base64 of UTF-8 JSON because:
/// - Markdown safely ignores HTML comments
/// - The payload can contain newlines, brackets, anything
/// - Round-tripping through `dart:convert` is cheap
class NativeToolUseMarker {
  /// Sentinel prefix. Same shape as the existing thinking / truncated
  /// markers so the controller's marker-detection logic can extend
  /// uniformly.
  static const String prefix = '<!-- LUMEN_NATIVE_TOOL_USE:';
  static const String suffix = ' -->';

  /// Build the marker text from a parsed tool_use block. Caller is
  /// responsible for ensuring [name] is a registered tool id.
  static String build({
    required String id,
    required String name,
    required Map<String, dynamic> arguments,
  }) {
    final payload = {'id': id, 'name': name, 'arguments': arguments};
    final encoded = base64.encode(utf8.encode(jsonEncode(payload)));
    return '\n$prefix$encoded$suffix\n';
  }

  /// Try to extract a NativeToolUse block from arbitrary text. Returns
  /// null when the text doesn't contain a complete marker. Used by
  /// the controller's chunk parser when streaming.
  static NativeToolUse? tryParse(String haystack) {
    final start = haystack.indexOf(prefix);
    if (start < 0) return null;
    final end = haystack.indexOf(suffix, start + prefix.length);
    if (end < 0) return null;
    final encoded = haystack.substring(start + prefix.length, end);
    try {
      final json = utf8.decode(base64.decode(encoded));
      final obj = jsonDecode(json) as Map<String, dynamic>;
      return NativeToolUse(
        id: (obj['id'] as String?) ?? '',
        name: (obj['name'] as String?) ?? '',
        arguments:
            (obj['arguments'] as Map?)?.cast<String, dynamic>() ?? const {},
        markerStart: start,
        markerEnd: end + suffix.length,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Parsed native tool_use block extracted from a stream chunk.
class NativeToolUse {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  /// Marker offsets inside the haystack passed to
  /// [NativeToolUseMarker.tryParse]. Caller uses these to splice
  /// the marker out of the visible content.
  final int markerStart;
  final int markerEnd;

  const NativeToolUse({
    required this.id,
    required this.name,
    required this.arguments,
    required this.markerStart,
    required this.markerEnd,
  });
}

/// Provider-neutral shapes for the `tools[]` request field. Each
/// service translates from this list into its native shape:
/// - Anthropic: `tools: [{name, description, input_schema}]`
/// - OpenAI / GitHub Models / Ollama (post-0.3.0): `tools: [{type:
///   "function", function: {name, description, parameters}}]`
/// - Gemini: `tools: [{function_declarations: [{name, description,
///   parameters}]}]` — single outer entry containing all decls.
class NativeToolDefinitions {
  /// Build Anthropic `tools[]`. The LAST entry gets a
  /// `cache_control: {type: 'ephemeral'}` marker so Anthropic's
  /// prompt cache covers the entire tools block (caching is
  /// positional from the top of the prompt up to the marker).
  /// On a warm cache this turns a multi-thousand-token prefill
  /// into a near-zero-cost lookup, which is the single biggest
  /// per-turn latency win for Claude. Other providers ignore
  /// the field; we only emit it on the Anthropic shape.
  static List<Map<String, dynamic>> forAnthropic(Set<String> enabledIds) {
    final list = <Map<String, dynamic>>[
      for (final s in ToolSchemas.all)
        if (enabledIds.contains(s.id))
          {
            'name': s.id,
            'description': s.description,
            'input_schema': s.inputSchema,
          },
    ];
    if (list.isNotEmpty) {
      list.last = {
        ...list.last,
        'cache_control': {'type': 'ephemeral'},
      };
    }
    return list;
  }

  static List<Map<String, dynamic>> forOpenAi(Set<String> enabledIds) {
    return [
      for (final s in ToolSchemas.all)
        if (enabledIds.contains(s.id))
          {
            'type': 'function',
            'function': {
              'name': s.id,
              'description': s.description,
              'parameters': s.inputSchema,
            },
          },
    ];
  }

  static Map<String, dynamic> forGemini(Set<String> enabledIds) {
    final decls = <Map<String, dynamic>>[
      for (final s in ToolSchemas.all)
        if (enabledIds.contains(s.id))
          {
            'name': s.id,
            'description': s.description,
            'parameters': s.inputSchema,
          },
    ];
    return {'function_declarations': decls};
  }
}
