/// LLM-driven summarization of the "dropped middle" of a long chat
/// session, used in place of the deterministic one-line elision
/// placeholder when the user has opted in via Settings → AI / Chat.
///
/// Why this exists: hour-long agentic sessions produce 100+ messages
/// that the model needs to *remember* (decisions made, files touched,
/// dead ends ruled out). The pre-existing `_kHistoryKeepRecent`
/// pruning in `chat_controller.dart` keeps the first user message
/// plus the last 40 messages and replaces the omitted middle with a
/// one-line "X messages elided" stub. That bound the token budget but
/// the model lost everything in between.
///
/// On Ollama-hosted models with smaller context windows this hurts
/// more than the token-cost savings help — the model re-reads files
/// it already touched, re-asks questions already answered, etc. With
/// a "small model" option (the existing `chat.toolCompression.model`
/// setting is reused for this), we can pay a cheap LLM round-trip to
/// turn the dropped span into a structured 4-section summary instead.
///
/// **Strategy** (intentionally conservative):
///   1. Format the dropped messages (everything between the first
///      user message and the kept tail) as labelled snippets.
///   2. Ask the small model for a fixed-shape markdown response with
///      four sections: Decisions, Files touched, Errors / dead-ends,
///      Open questions. No prose preamble, no postamble.
///   3. If the result is empty, looks like an error, exceeds
///      [maxChars], or doesn't contain at least the section headers,
///      return null. Caller falls back to the existing one-line
///      placeholder. **Never ship a worse summary than the placeholder.**
///
/// Stateless / pure: caller owns caching (`ChatSession.cachedHistorySummary`).
/// The `Generate` callback is provider-agnostic — typically wired to
/// `ChatController.generateUtilityText`.
library;

import 'dart:async';

import '../../services/chat_persistence_service.dart';

/// Small-model invoker. Returns the generated text. Errors should be
/// surfaced as a returned string starting with `Error:` (mirrors the
/// shape of `ChatController.generateUtilityText`) rather than thrown,
/// but [HistorySummarizer.summarize] also catches thrown exceptions
/// (timeouts, network failures, …) and treats them as "no summary".
typedef HistoryGenerate =
    Future<String> Function(
      List<Map<String, dynamic>> messages, {
      required String model,
    });

class HistorySummarizer {
  /// Hard upper bound on how many dropped messages we send to the
  /// summarizer in a single round-trip. Past this, we sample (keep
  /// the first ~third and last ~third) so the small model isn't
  /// itself buried in 200K of context. Safety net — most sessions
  /// won't hit this.
  static const int _maxMessagesPerCall = 80;

  /// Inner-content cap per message before we truncate with an
  /// `… [truncated]` marker. Keeps the summarizer prompt bounded
  /// when the dropped span contains big tool_result dumps.
  static const int _maxCharsPerMessage = 400;

  /// Round-trip ceiling. The summarizer is on the critical path of a
  /// turn — if the small model is unhealthy we don't want to stall
  /// the chat. On timeout, [summarize] returns null and the caller
  /// uses the elision placeholder.
  static const Duration _summaryTimeout = Duration(seconds: 30);

  /// Required section headers in the response. If any is missing,
  /// the result is treated as a malformed summary and rejected.
  static const List<String> _requiredHeaders = <String>[
    '## Decisions',
    '## Files touched',
    '## Errors',
    '## Open',
  ];

  /// Produces a structured summary of [droppedMessages] using
  /// [generate] (typically `chat.generateUtilityText`).
  ///
  /// - [model]: full `provider:rawModel` id of the small model. If
  ///   empty, returns null without an LLM call (caller falls back
  ///   to elision).
  /// - [maxChars]: hard cap on the returned summary body. Summaries
  ///   larger than this are rejected — a too-long summary defeats
  ///   the point.
  ///
  /// Never throws; returns `null` on any failure path.
  static Future<String?> summarize({
    required List<PersistedMessage> droppedMessages,
    required HistoryGenerate generate,
    required String model,
    required int maxChars,
  }) async {
    if (model.trim().isEmpty) return null;
    if (droppedMessages.isEmpty) return null;

    final formatted = _formatDroppedMessages(droppedMessages);
    if (formatted.isEmpty) return null;

    try {
      final raw = await generate(
        [
          {'role': 'system', 'content': _systemPrompt(maxChars)},
          {'role': 'user', 'content': _userPrompt(formatted)},
        ],
        model: model,
      ).timeout(_summaryTimeout);

      final cleaned = _postProcess(raw, maxChars: maxChars);
      return cleaned;
    } catch (_) {
      return null;
    }
  }

  static String _systemPrompt(int maxChars) =>
      '''You are a chat-context summarizer for an AI coding assistant.
You are given a span of chat history that has been elided from the
working window of a long pair-programming session. Your job is to
produce a STRUCTURED summary so the next turn of the main coding
agent remembers what was decided, what was tried, and what is still
open — without re-reading every message.

Output rules (FOLLOW EXACTLY):
- Output PLAIN MARKDOWN with EXACTLY these four section headers, in
  this order, no extras, no preamble, no closing remarks:

    ## Decisions
    ## Files touched
    ## Errors / dead-ends
    ## Open questions

- Each section is a bullet list (use `- `). If a section has no
  content, write `- (none)` so the headers stay verifiable.
- Be terse. Whole summary MUST be under $maxChars characters.
- Reference files by exact path (relative paths are fine — quote
  them as `path/to/file.ext`).
- Do NOT invent or speculate. Only summarize what is in the elided
  span.
- Do NOT include `<tool_result>` tags, code fences, XML, or YAML.
- Do NOT echo the user's prompt or the original task.''';

  static String _userPrompt(String formatted) =>
      '''Elided chat span (oldest first):

$formatted

Produce the four-section summary now. No preamble.''';

  /// Render messages compactly: role, optional truncated body, in a
  /// stable shape the small model can scan. Tool-result blocks are
  /// kept (they're often the most informative entries) but bounded.
  static String _formatDroppedMessages(List<PersistedMessage> messages) {
    final sample = messages.length <= _maxMessagesPerCall
        ? messages
        : _sampleEnds(messages, _maxMessagesPerCall);

    final buf = StringBuffer();
    for (var i = 0; i < sample.length; i++) {
      final m = sample[i];
      final body = _shorten(m.content);
      buf
        ..writeln('--- [${i + 1}] role=${m.role} ---')
        ..writeln(body)
        ..writeln();
    }
    return buf.toString().trimRight();
  }

  static String _shorten(String s) {
    final trimmed = s.trim();
    if (trimmed.length <= _maxCharsPerMessage) return trimmed;
    final head = trimmed.substring(0, _maxCharsPerMessage);
    final remaining = trimmed.length - head.length;
    return '$head\n… [truncated $remaining chars]';
  }

  /// Keep first third + last third when the dropped span exceeds the
  /// per-call cap. Beginning anchors the original task, end anchors
  /// the most recent state — middle is statistically most redundant.
  static List<PersistedMessage> _sampleEnds(
    List<PersistedMessage> all,
    int cap,
  ) {
    if (all.length <= cap) return all;
    final keepHead = (cap * 0.4).floor();
    final keepTail = cap - keepHead;
    final head = all.sublist(0, keepHead);
    final tail = all.sublist(all.length - keepTail);
    return [
      ...head,
      PersistedMessage(
        role: 'system',
        content:
            '(... ${all.length - keepHead - keepTail} messages between '
            'were sampled out for the summarizer)',
      ),
      ...tail,
    ];
  }

  /// Validate + trim the small model's output. Returns `null` for
  /// any output we wouldn't want the main model to see.
  static String? _postProcess(String raw, {required int maxChars}) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;

    if (trimmed.startsWith('Error:')) return null;

    if (trimmed.length > maxChars) return null;

    for (final header in _requiredHeaders) {
      if (!trimmed.contains(header)) return null;
    }

    if (trimmed.contains('<tool_result>')) return null;

    return trimmed;
  }
}
