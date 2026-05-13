import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/chat_controller.dart';
import '../../services/provider_error.dart';
import '../../services/tool_executor.dart';
import '../../services/tool_registry.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Parses an LLM-response body that may contain `<!-- LUMEN_TOOL:... -->`
/// markers (emitted by `ToolExecutor._friendlyReplacement`) into an
/// ordered list of segments. Prose chunks render via `MarkdownBody`;
/// tool segments render as the structured cards / badges in this file.
///
/// Marker grammar (matches the executor's emitter):
///
///     <!-- LUMEN_TOOL:<id>|<percent-encoded-arg>|<status>|<nonce> -->
///
/// `status` is `ok`, `err`, `pending`, or `malformed`. The trailing
/// `<nonce>` field is optional in the regex (legacy markers persisted
/// before nonce-binding shipped don't have it) but every marker the
/// executor currently emits carries one — see
/// `ToolExecutor.markerNonce` and `PersistedMessage.toolMarkerNonce`.
/// The marker is anchored on its own paragraph (newline padding on
/// both sides) so splitting on it produces clean prose chunks
/// without orphan whitespace at the segment boundary.
///
/// **Nonce validation (the impersonation defense).** The same
/// HTML-comment shape the executor writes is something a model can
/// trivially emit verbatim — and weak Ollama models (deepseek,
/// some glm variants under load) do, when they see the markers
/// repeated in conversation history. Without nonce validation the
/// chat panel happily renders the model's fake markers as
/// successful tool cards, creating "Created file: foo.dart" chips
/// for files that were never written. The renderer-side defense is:
/// when [parseChatSegments] is called with `expectedNonce` set, a
/// marker only renders as a real card when its trailing nonce
/// equals that value. Markers with no nonce, an empty nonce, or
/// any other value are silently dropped from the rendered output
/// (the prose around them stays intact; the chip vanishes).
/// Legacy persisted messages stored before nonce-binding shipped
/// pass `expectedNonce: null` and continue rendering pre-binding
/// markers as real cards (forward-compat with old chat history).
///
/// `malformed` is emitted when the tool-shaped block exists in the
/// model's response (opener + closer present) but the inner structure
/// doesn't conform to the strict per-tool regex (e.g. EDIT_FILE
/// without SEARCH/REPLACE). The executor cannot run it, so we surface
/// a warning chip instead of letting the raw body leak through as
/// prose.
sealed class ChatSegment {
  const ChatSegment();
}

class ProseSegment extends ChatSegment {
  final String text;
  const ProseSegment(this.text);
}

/// Model reasoning trace, rendered as a collapsible "Thinking…"
/// section. [isActive] true means the model is still thinking
/// (stream in progress) — shows an animated indicator. When false,
/// the section collapses to a single-line summary the user can expand.
class ThinkingSegment extends ChatSegment {
  final String content;
  final bool isActive;
  const ThinkingSegment({required this.content, this.isActive = false});
}

class ToolSegment extends ChatSegment {
  final String toolId;
  final String firstArg;
  final String status;
  bool get ok => status == 'ok';
  bool get pending => status == 'pending';
  bool get failed => status == 'err';
  bool get malformed => status == 'malformed';

  /// Live body for body-shaped pending tools (CREATE_FILE, EDIT_FILE,
  /// MULTI_EDIT, EDIT_RANGE, APPEND_FILE) — the partial content the
  /// model has streamed between the opener line and the (still
  /// missing) closer line. Populated by [MessageBubble._segmentsFor]
  /// from `extractPendingToolBodies` and shown via the expandable
  /// "Live preview" region on the file-op chip.
  ///
  /// `null` when the tool is settled (`ok` / `err`) or when there's
  /// no body to show (single-line tools like MOVE_FILE / COPY_FILE).
  /// Mutable on purpose: we attach this AFTER `parseChatSegments`
  /// builds the segment list, because the body lives in raw content
  /// (not in the marker the renderer parses). Keeping it off the
  /// marker keeps persisted messages slim — we don't want the body
  /// stored in chat history just so the chip can render it.
  String? pendingBody;

  ToolSegment({
    required this.toolId,
    required this.firstArg,
    required this.status,
    this.pendingBody,
  });
}

/// Cluster of consecutive [ToolSegment]s that share the same
/// action label, tool kind, and final status. Rendered as a single
/// collapsible card so a turn that touched 12 files surfaces as
/// "Read 12 files" rather than 12 stacked rows.
///
/// Grouping happens AFTER raw segment parsing in
/// [parseChatSegments] — see [_groupConsecutiveTools] for the
/// exact bucketing rules. Singletons (groups of 1) and pairs are
/// always passed through as plain [ToolSegment]s; only 3+
/// consecutive same-action calls get grouped, because savings
/// below that threshold don't justify hiding individual paths
/// behind a collapse.
class ToolGroupSegment extends ChatSegment {
  final List<ToolSegment> tools;
  const ToolGroupSegment(this.tools);
}

/// Rendered when the controller swapped a turn's raw error text for a
/// `<!-- LUMEN_ERR:... -->` marker. Drives `_ProviderErrorCard` —
/// surfaces a friendly title/body and a Retry chip that re-runs the
/// last user prompt without losing context.
class ProviderErrorSegment extends ChatSegment {
  final ProviderError error;
  const ProviderErrorSegment(this.error);
}

/// One-pass marker → segment list. Text outside markers becomes
/// `ProseSegment`s; tool markers become `ToolSegment`s; provider-error
/// markers become `ProviderErrorSegment`s. Adjacent prose chunks are
/// NOT merged — splitting on `\n<!-- ... -->\n` already removes the
/// surrounding newlines, so we just trust the regex.
///
/// Both marker families are gathered with a single combined matcher
/// so a chat turn that contains BOTH (rare but possible: the agent
/// fired a tool, the next iteration overloaded the provider) renders
/// in source order — tool card, prose, error card.
///
/// After raw parsing, runs of 3+ consecutive [ToolSegment]s sharing
/// the same action label / kind / status get collapsed into a single
/// [ToolGroupSegment]. This is what turns "10 file reads" into a
/// single expandable "Read 10 files" card instead of a stack of 10.
///
/// `expectedNonce` is the per-message random token from
/// `PersistedMessage.toolMarkerNonce`. When non-null, every
/// `<!-- LUMEN_TOOL:... -->` marker is validated: only markers
/// whose trailing nonce field equals `expectedNonce` are turned
/// into [ToolSegment]s; markers with no nonce, an empty nonce, or
/// a different value are silently elided (the surrounding prose
/// stays). When `expectedNonce` is null (legacy messages
/// persisted before nonce-binding shipped), every well-formed
/// marker renders — that's the only way old chat history keeps
/// its tool chips. See `tool_segments.dart` library doc and
/// `ToolExecutor._friendlyReplacement` for the design rationale.
List<ChatSegment> parseChatSegments(String content, {String? expectedNonce}) {
  final raw = <ChatSegment>[];

  // ── Phase 1: Extract thinking blocks first ──
  // They sit before/between tool markers. We replace them with a
  // placeholder so the tool regex doesn't trip over them, then
  // re-inject as ThinkingSegments at the right positions.
  final thinkRe = RegExp(
    r'<!-- LUMEN_THINKING(\s+active)? -->\n([\s\S]*?)\n<!-- /LUMEN_THINKING -->',
  );
  final thinkMatches = thinkRe.allMatches(content).toList();
  // Replace thinking blocks with unique tokens we can split on later.
  var processed = content;
  for (var t = thinkMatches.length - 1; t >= 0; t--) {
    final m = thinkMatches[t];
    processed = processed.replaceRange(m.start, m.end, '\u0000THINK:$t\u0000');
  }

  // Combined matcher — alternation between LUMEN_TOOL and LUMEN_ERR.
  // Tool fields: group 1 = id, group 2 = arg, group 3 = status,
  // group 4 = optional nonce (null when the marker is in legacy
  // pre-binding shape OR when the model emitted it as
  // impersonation without a nonce field). The nonce capture is
  // hex-only (`[a-f0-9]+`) which both keeps the regex tight AND
  // means a model can't accidentally satisfy the shape with prose
  // that happens to contain pipes.
  // Error fields: group 5 = kind, group 6 = encoded detail.
  final re = RegExp(
    r'<!--\s*LUMEN_TOOL:([a-z_]+)\|([^|]*)\|(ok|err|pending|malformed)(?:\|([a-f0-9]+))?\s*-->'
    r'|'
    r'<!--\s*LUMEN_ERR:([a-z_]+)\|([^|]*)\s*-->'
    r'|'
    r'\x00THINK:(\d+)\x00',
    multiLine: true,
  );
  int cursor = 0;
  for (final m in re.allMatches(processed)) {
    if (m.start > cursor) {
      final prose = processed.substring(cursor, m.start);
      if (prose.trim().isNotEmpty) {
        raw.add(ProseSegment(prose));
      }
    }
    if (m.group(1) != null) {
      // Tool marker. When the message has an `expectedNonce`,
      // only render markers whose trailing nonce field matches
      // it — anything else (no nonce, empty nonce, mismatched
      // value) is model-emitted impersonation and gets dropped
      // entirely (the surrounding prose still renders). Legacy
      // messages with no `expectedNonce` accept every well-formed
      // marker so existing chat history keeps its tool chips.
      final markerNonce = m.group(4);
      final accept = expectedNonce == null
          ? true
          : (markerNonce != null && markerNonce == expectedNonce);
      if (accept) {
        raw.add(
          ToolSegment(
            toolId: m.group(1)!,
            firstArg: Uri.decodeComponent(m.group(2)!),
            status: m.group(3)!,
          ),
        );
      }
      // If !accept, intentionally emit nothing — the marker is
      // silently elided. The existing past-tense claim detector
      // (`HallucinationDetector.detectHallucinatedClaims` in
      // `lib/providers/chat/hallucination_detector.dart`) will
      // catch persistent "Created foo.dart" prose that follows
      // dropped markers and halt the turn with a warning.
    } else if (m.group(5) != null) {
      // Build the ProviderError directly from our captured groups
      // 5 (kind) and 6 (encoded detail). NOT via
      // `ProviderError.fromMarkerMatch(m)`: that helper expects a
      // match from `ProviderError.markerRegExp` where the err
      // fields live in groups 1-2, but our combined alternation
      // here puts them in 5-6 and groups 1-2 hold the (null)
      // tool-marker fields. Inlining keeps the parser robust to
      // further regex renumbering and fixes a latent issue where
      // err cards rendered as kind=`unknown` / empty detail.
      final kindName = m.group(5) ?? '';
      final detailRaw = m.group(6) ?? '';
      final kind = ProviderErrorKind.values.firstWhere(
        (k) => k.name == kindName,
        orElse: () => ProviderErrorKind.unknown,
      );
      final detail = Uri.decodeComponent(detailRaw);
      raw.add(
        ProviderErrorSegment(ProviderError(kind: kind, rawDetail: detail)),
      );
    } else if (m.group(7) != null) {
      final idx = int.parse(m.group(7)!);
      if (idx < thinkMatches.length) {
        final tm = thinkMatches[idx];
        final isActive = tm.group(1) != null;
        final thinkContent = tm.group(2) ?? '';
        raw.add(ThinkingSegment(content: thinkContent, isActive: isActive));
      }
    }
    cursor = m.end;
  }
  if (cursor < processed.length) {
    final tail = processed.substring(cursor);
    if (tail.trim().isNotEmpty) {
      raw.add(ProseSegment(tail));
    }
  }
  return _groupConsecutiveTools(raw);
}

/// Walk a flat segment list and collapse runs of consecutive
/// [ToolSegment]s into [ToolGroupSegment]s when they meet the
/// grouping bar:
///
/// - **Same action label** (`Read`, `Edited`, `Searched`, …). Mixing
///   "Read foo" with "Edited foo" stays as two segments.
/// - **Same `_ToolKind`**. fileOps and inspections never group
///   across boundaries.
/// - **Status is consistent**: pending tools never group with
///   completed ones, errored tools form their own groups so the
///   bad-news count stays visible at a glance.
/// - **Run length ≥ 3**. Two-of-a-kind stays as two cards — the
///   collapsed header + an expand interaction is heavier than just
///   showing the second card.
/// - **Commands (RUN_CMD) never group.** A shell command is
///   meaningful by itself; collapsing them would hide the actual
///   command line.
List<ChatSegment> _groupConsecutiveTools(List<ChatSegment> input) {
  if (input.isEmpty) return input;
  final out = <ChatSegment>[];
  var i = 0;
  while (i < input.length) {
    final seg = input[i];
    if (seg is! ToolSegment || !_groupable(seg)) {
      out.add(seg);
      i++;
      continue;
    }
    final action = _actionLabel(seg);
    final kind = _kindFor(seg.toolId);
    final status = seg.status;
    final batch = <ToolSegment>[seg];
    var j = i + 1;
    while (j < input.length) {
      final next = input[j];
      if (next is! ToolSegment) break;
      if (!_groupable(next)) break;
      if (_kindFor(next.toolId) != kind) break;
      if (next.status != status) break;
      if (_actionLabel(next) != action) break;
      batch.add(next);
      j++;
    }
    if (batch.length >= 3) {
      out.add(ToolGroupSegment(List.unmodifiable(batch)));
    } else {
      out.addAll(batch);
    }
    i = j;
  }
  return out;
}

/// Tools eligible for collapsing into a [ToolGroupSegment]. We
/// keep `command`-kind tools out — RUN_CMD carries meaningful
/// payload that the user wants to scan, not bury.
bool _groupable(ToolSegment seg) {
  final kind = _kindFor(seg.toolId);
  return kind == _ToolKind.fileOp || kind == _ToolKind.inspection;
}

/// Strip markers from a body and replace with the friendly plain-text
/// rendering — used by the per-message Copy chip so paste-to-other-app
/// is readable instead of dumping HTML comments. Both marker families
/// are stripped in one pass.
///
/// Tool markers are matched with the same nonce-aware grammar
/// `parseChatSegments` uses; the trailing `|<nonce>` field is
/// optional so legacy persisted markers still translate to
/// friendly text. The clipboard output is identical for nonce-bound
/// and legacy markers — copy is a presentation concern, not a
/// security one, so we don't filter mismatched-nonce markers
/// here. (If a model fabricates a marker the user copies the
/// chat content of, the copied text echoes the fabrication; the
/// past-tense claim detector handles the in-app warning, the
/// clipboard does not.)
String stripMarkersForCopy(String content) {
  final toolRe = RegExp(
    r'<!--\s*LUMEN_TOOL:([a-z_]+)\|([^|]*)\|(ok|err|pending|malformed)(?:\|[a-f0-9]+)?\s*-->',
    multiLine: true,
  );
  final errRe = ProviderError.markerRegExp;
  var s = content.replaceAllMapped(toolRe, (m) {
    final id = m.group(1)!;
    final arg = Uri.decodeComponent(m.group(2)!);
    final status = m.group(3)!;
    final ok = status == 'ok' || status == 'pending';
    if (status == 'malformed') {
      return '($id `$arg` malformed — not executed)';
    }
    return ToolExecutor.friendlyTextForMarker(id, arg, ok);
  });
  s = s.replaceAllMapped(errRe, (m) {
    final err = ProviderError.fromMarkerMatch(m);
    return err != null ? ProviderError.friendlyTextFor(err) : '';
  });
  // Strip thinking blocks — copy gets the answer, not the trace.
  s = s.replaceAll(
    RegExp(
      r'<!-- LUMEN_THINKING[^>]* -->\n[\s\S]*?\n<!-- /LUMEN_THINKING -->\n*',
    ),
    '',
  );
  return s;
}

/// Render-only cleanup for the live assistant message while it is still
/// streaming. Tool execution still receives the raw model output after the
/// stream completes; this only hides noisy `<<<...>>>` syntax from the UI and
/// swaps it for the same card markers the final executor pass emits.
///
/// Four layered passes, ordered specifically so each catches what
/// the previous missed:
///
/// 0. **Impersonation strip.** Any `<!-- LUMEN_TOOL:... -->`
///    marker in the streaming buffer that lacks the message's
///    [markerNonce] (or carries the wrong one) was emitted by the
///    model itself — the executor hasn't run for this iteration
///    yet, so no real markers exist in the buffer. The stripper
///    drops these inline (replaces with empty string) BEFORE the
///    later passes run, so a fake "Created" chip never flashes
///    in the UI even for a frame. Markers WITH a matching nonce
///    are preserved untouched (those are real markers carried
///    over from a previous iteration's executor pass within the
///    same turn — e.g. iteration 2's streaming buffer is
///    aggregated content that includes iteration 1's real
///    markers).
/// 1. **Per-tool complete-pattern matching.** `tool.pattern.allMatches`
///    on every registered tool. Replaces fully-formed calls with
///    `pending` markers (after the executor runs the post-stream
///    pass these become `ok`/`err`).
/// 2. **Salvage pass for malformed blocks.** Catches the case where
///    BOTH the opener and the closer are present but the inner
///    structure rejected step 1's strict regex (e.g. an EDIT_FILE
///    body without SEARCH/REPLACE markers, or extra blank lines
///    breaking the literal `\n` separators). Without this pass the
///    entire raw body — often hundreds of lines of code — leaks
///    through as prose into the chat. Replaces with a `malformed`
///    marker so the user sees the failed attempt without the dump.
/// 3. **Trailing incomplete openers.** A `<<<EDIT_FILE: …>>>` at the
///    tail of the stream with no closer yet (still typing). Replaces
///    with a `pending` marker so the partial body stays hidden until
///    the close arrives or the stream ends.
///
/// `markerNonce` is the per-message nonce from
/// `PersistedMessage.toolMarkerNonce`. When non-null, pass 0
/// strips fake markers and passes 1-3 stamp the nonce into every
/// `pending` / `malformed` marker they emit so the chat parser
/// (which validates the same nonce) renders them as real cards.
/// When null (legacy / non-chat callers) the function preserves
/// the pre-binding behavior: no impersonation strip and no
/// nonce in the emitted markers.
String streamingToolPreview(String rawContent, {String? markerNonce}) {
  var content = _normalizeForToolPreview(rawContent);

  // ── Pass 0: impersonation strip ───────────────────────────────
  // Drop any `<!-- LUMEN_TOOL:... -->` whose trailing nonce field
  // isn't the message's `markerNonce`. The executor hasn't run
  // for the iteration whose buffer is being previewed (the
  // streaming preview only renders mid-stream, before
  // post-stream `executor.run` rewrites raw `<<<TOOL>>>` blocks
  // into real markers), so any LUMEN_TOOL marker in the input
  // either:
  //   - was emitted directly by the model (impersonation), or
  //   - was carried over verbatim from a PREVIOUS iteration's
  //     executor pass within the same turn — those carry the
  //     same per-message nonce, so they pass the check and stay.
  if (markerNonce != null) {
    final fakeMarkerRe = RegExp(
      r'<!--\s*LUMEN_TOOL:[a-z_]+\|[^|]*\|(?:ok|err|pending|malformed)(?:\|([a-f0-9]+))?\s*-->',
      multiLine: true,
    );
    content = content.replaceAllMapped(fakeMarkerRe, (m) {
      final markerN = m.group(1);
      if (markerN != null && markerN == markerNonce) {
        // Real marker from an earlier iteration in this turn —
        // preserve as-is.
        return m.group(0)!;
      }
      // Empty replacement so the surrounding prose joins
      // seamlessly. We don't replace with a warning chip here —
      // the past-tense claim detector
      // (`HallucinationDetector.detectHallucinatedClaims`) is
      // responsible for surfacing the user-visible warning when
      // the model accumulates fabricated claims; UI noise per
      // single mimicked marker is unhelpful clutter.
      return '';
    });
  }

  for (final tool in ToolRegistry.all) {
    final matches = tool.pattern.allMatches(content).toList();
    for (final match in matches) {
      // Arrow tools (`<<<MOVE_FILE: src -> dst>>>`,
      // `<<<COPY_FILE: src -> dst>>>`) put the destination in
      // group 2. Mirror `ToolExecutor._friendlyReplacement` so
      // the *pending* chip shows the same `src -> dst` string the
      // *settled* chip will show — otherwise the user sees the
      // path flicker from "Copying foo" to "Copied foo -> bar"
      // mid-stream, which reads as a UI bug.
      final isArrow = tool.id == 'move_file' || tool.id == 'copy_file';
      final firstArg = isArrow && match.groupCount >= 2
          ? '${match.group(1) ?? ''} -> ${match.group(2) ?? ''}'
          : ((match.groupCount >= 1 ? match.group(1) : '') ?? '');
      content = content.replaceAll(
        match.group(0)!,
        _toolMarker(tool.id, firstArg, 'pending', markerNonce: markerNonce),
      );
    }
  }

  content = _replaceMalformedBlockTool(content, markerNonce: markerNonce);
  content = _replaceIncompleteBlockTool(content, markerNonce: markerNonce);
  content = _replaceIncompleteInlineTool(content, markerNonce: markerNonce);
  return content;
}

/// Per-pending-tool live body extracted from raw streaming content.
/// Source-order aligned with the body-shaped pending [ToolSegment]s
/// that [parseChatSegments] produces from the corresponding
/// [streamingToolPreview] output, so the caller can attach each body
/// to the right segment by walking both lists in lockstep.
///
/// **Why this exists.** The streaming-preview pipeline collapses
/// in-progress tool bodies into compact `pending` markers — that's
/// what makes the chat render cleanly while a 500-line CREATE_FILE
/// streams in. The downside is that the bytes the model is currently
/// emitting become invisible to the user. When a model goes into a
/// degenerate token loop mid-edit (real failure mode: "REPLACE
/// REPLACE REPLACE…" for 15 minutes on a confused weak model), the
/// only signal is "Editing" stayed pending too long. Surfacing the
/// raw body in an expandable region gives the user a `tail -f` on
/// the live stream so they can see the runaway and stop it before
/// the output budget burns through.
///
/// We extract bodies from raw content (not the preview) because the
/// preview already rewrote them away. The match order is the
/// source-order of openers in raw, which equals the source-order of
/// `pending` markers in the preview (the rewrite preserves
/// position) — so the alignment is by position and the caller can
/// walk both lists in parallel.
class PendingToolBody {
  final String toolId;
  final String body;
  const PendingToolBody({required this.toolId, required this.body});
}

List<PendingToolBody> extractPendingToolBodies(String rawContent) {
  // Body-shaped tools only. Single-line tools (MOVE_FILE,
  // COPY_FILE, READ_FILE, …) finish in one source line — there's
  // nothing to "watch", so they're absent from this map. Keep this
  // table in sync with `RAW_TOOL_BODIES` in `assets/remote_app/app.js`
  // and `_replaceMalformedBlockTool` / `_replaceIncompleteBlockTool`
  // up-file.
  const cfg = <String, ({String toolId, String closer})>{
    'CREATE_FILE': (toolId: 'create_file', closer: 'END_FILE'),
    'EDIT_FILE': (toolId: 'edit_file', closer: 'END_EDIT'),
    'MULTI_EDIT': (toolId: 'multi_edit', closer: 'END_EDIT'),
    'EDIT_RANGE': (toolId: 'edit_range', closer: 'END_EDIT'),
    'APPEND_FILE': (toolId: 'append_file', closer: 'END_APPEND'),
  };

  // Opener regex matches `<<<NAME: arg>>>` for any of the body
  // tools. Group 1 = name. The arg is captured but unused — we
  // already have it on the segment from `parseChatSegments`.
  final names = cfg.keys.join('|');
  final openerRe = RegExp('<<<($names):[^>]*?>>>', multiLine: true);

  final results = <PendingToolBody>[];
  for (final m in openerRe.allMatches(rawContent)) {
    final name = m.group(1)!;
    final entry = cfg[name]!;
    final bodyStart = m.end;
    final closerToken = '<<<${entry.closer}>>>';
    final closerIdx = rawContent.indexOf(closerToken, bodyStart);
    final bodyEnd = closerIdx < 0 ? rawContent.length : closerIdx;
    var body = rawContent.substring(bodyStart, bodyEnd);
    // Strip the single newline that always follows the opener
    // line, but keep blank lines inside the body intact (they're
    // meaningful for indentation / structure preview).
    if (body.startsWith('\r\n')) {
      body = body.substring(2);
    } else if (body.startsWith('\n')) {
      body = body.substring(1);
    }
    // Trim a trailing newline before the closer (or before EOF) so
    // the preview doesn't render a phantom blank tail line.
    if (body.endsWith('\n')) {
      body = body.substring(0, body.length - 1);
    }
    results.add(PendingToolBody(toolId: entry.toolId, body: body));
  }
  return results;
}

/// Tool ids that have a body worth previewing while the call is
/// pending. Single-line tools omitted. Used by [_FileToolCard] to
/// gate the expandable "Live preview" region.
const Set<String> _kBodyShapedToolIds = <String>{
  'create_file',
  'edit_file',
  'multi_edit',
  'edit_range',
  'append_file',
};

/// Public membership test for [_kBodyShapedToolIds]. Used by
/// [MessageBubble._segmentsFor] to decide which pending segments
/// should have their live body attached. Kept as a function rather
/// than exporting the set so callers can't mutate it.
bool isBodyShapedToolId(String toolId) => _kBodyShapedToolIds.contains(toolId);

/// Catch tool-shaped blocks where opener AND closer are both present
/// but step 1's strict per-tool regex rejected them. Replaces the
/// entire span (including the body) with a `malformed` marker so
/// the raw block — which often contains the exact code the model
/// was trying to insert — never reaches `MarkdownBody`.
///
/// **The bug this fixes:** the strict EDIT_FILE pattern requires
/// `<<<EDIT_FILE: x>>>\n<<<SEARCH>>>\n…\n<<<REPLACE>>>\n…\n<<<END_EDIT>>>`.
/// When the model emits an EDIT_FILE that's structurally off (no
/// SEARCH/REPLACE markers, surplus blank lines, or even just
/// `\r\n` line endings the literal `\n` doesn't match), step 1
/// fails. The previous fallback only fired when the closer was
/// missing — so a malformed but "complete-looking" block leaked
/// the entire raw body into the rendered chat as prose. Reported
/// in user feedback as "the model just dumps code into the chat".
String _replaceMalformedBlockTool(String content, {String? markerNonce}) {
  final salvage = RegExp(
    r'<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|EDIT_RANGE|APPEND_FILE):\s*(.*?)\s*>>>'
    r'(?:.*?)'
    r'<<<END_(?:FILE|EDIT|APPEND)>>>',
    dotAll: true,
  );
  return content.replaceAllMapped(salvage, (m) {
    final toolName = m.group(1)!;
    final firstArg = (m.group(2) ?? '').trim();
    final id = _toolIdForName(toolName);
    if (id == null) return m.group(0)!;
    return _toolMarker(id, firstArg, 'malformed', markerNonce: markerNonce);
  });
}

String _toolMarker(
  String toolId,
  String firstArg,
  String status, {
  String? markerNonce,
}) {
  final encoded = Uri.encodeComponent(firstArg);
  final nonceField = markerNonce == null ? '' : '|$markerNonce';
  return '\n<!-- LUMEN_TOOL:$toolId|$encoded|$status$nonceField -->\n';
}

String _normalizeForToolPreview(String input) {
  var s = input
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');
  s = s.replaceAll(RegExp(r'[\u200B\u200C\u200D\uFEFF]'), '');
  const angleMap = {
    '\u00AB': '<',
    '\u00BB': '>',
    '\u276E': '<',
    '\u276F': '>',
    '\uFF1C': '<',
    '\uFF1E': '>',
    '\u2329': '<',
    '\u232A': '>',
    '\u3008': '<',
    '\u3009': '>',
  };
  angleMap.forEach((from, to) {
    s = s.replaceAll(from, to);
  });
  return s;
}

String _replaceIncompleteBlockTool(String content, {String? markerNonce}) {
  final opener = RegExp(
    r'<<<(CREATE_FILE|EDIT_FILE|MULTI_EDIT|EDIT_RANGE|APPEND_FILE):\s*(.*?)\s*>>>',
    dotAll: true,
  );
  final matches = opener.allMatches(content).toList();
  if (matches.isEmpty) return content;

  final match = matches.last;
  final toolName = match.group(1)!;
  final firstArg = match.group(2) ?? '';
  final id = _toolIdForName(toolName);
  if (id == null) return content;

  final tail = content.substring(match.start);
  final hasEnd = switch (toolName) {
    'CREATE_FILE' => tail.contains('<<<END_FILE>>>'),
    'APPEND_FILE' => tail.contains('<<<END_APPEND>>>'),
    _ => tail.contains('<<<END_EDIT>>>'),
  };
  if (hasEnd) return content;

  return '${content.substring(0, match.start)}'
      '${_toolMarker(id, firstArg, 'pending', markerNonce: markerNonce)}';
}

String _replaceIncompleteInlineTool(String content, {String? markerNonce}) {
  final match = RegExp(
    r'<<<([A-Z_]+)(?::\s*([^>\n]*))?$',
    multiLine: false,
  ).firstMatch(content);
  if (match == null) return content;

  final id = _toolIdForName(match.group(1)!);
  if (id == null) return content;
  final firstArg = match.group(2) ?? '';
  return '${content.substring(0, match.start)}'
      '${_toolMarker(id, firstArg, 'pending', markerNonce: markerNonce)}';
}

String? _toolIdForName(String toolName) {
  for (final tool in ToolRegistry.all) {
    if (tool.name == toolName) return tool.id;
  }
  return null;
}

// ─── classification ──────────────────────────────────────────────

/// Classifies tool ids into the three visual buckets the chat panel
/// renders. Add new tools here when adding to ToolRegistry — anything
/// uncategorised falls through to `_inspection` (the safest default
/// since inspection badges are non-destructive in appearance).
enum _ToolKind { fileOp, command, inspection }

_ToolKind _kindFor(String toolId) {
  switch (toolId) {
    case 'create_file':
    case 'edit_file':
    case 'multi_edit':
    case 'edit_range':
    case 'append_file':
    case 'move_file':
    case 'copy_file':
    case 'read_file':
    case 'read_file_range':
    case 'delete_file':
      return _ToolKind.fileOp;
    case 'run_cmd':
      return _ToolKind.command;
    default:
      return _ToolKind.inspection;
  }
}

/// One-line action label per tool — what the *card title* says.
String _actionLabel(ToolSegment segment) {
  if (segment.pending) return _pendingActionLabel(segment.toolId);
  if (segment.malformed) return S.toolMalformedLabel;
  final toolId = segment.toolId;
  final ok = segment.ok;
  if (!ok) {
    switch (toolId) {
      case 'edit_file':
      case 'multi_edit':
      case 'edit_range':
        return 'Edit failed';
      case 'create_file':
        return 'Create failed';
      case 'delete_file':
        return 'Delete failed';
      case 'move_file':
        return 'Move failed';
      case 'copy_file':
        return 'Copy failed';
      case 'read_file':
      case 'read_file_range':
        return 'Read failed';
      case 'run_cmd':
        return 'Command failed';
      case 'append_file':
        return 'Append failed';
      default:
        return 'Failed';
    }
  }
  switch (toolId) {
    case 'create_file':
      return 'Created';
    case 'edit_file':
      return 'Edited';
    case 'multi_edit':
      return 'Multi-edited';
    case 'edit_range':
      return 'Edited range';
    case 'append_file':
      return 'Appended';
    case 'move_file':
      return 'Moved';
    case 'copy_file':
      return 'Copied';
    case 'read_file':
    case 'read_file_range':
      return 'Read';
    case 'delete_file':
      return 'Deleted';
    case 'tree':
      return 'Tree';
    case 'list_dir':
      return 'Listed';
    case 'search_text':
      return 'Searched';
    case 'find_file':
      return 'Found';
    case 'glob':
      return 'Glob';
    case 'git_status':
      return 'git status';
    case 'git_diff':
      return 'git diff';
    case 'run_cmd':
      return 'Ran';
    case 'verify':
      return 'Verified';
    default:
      return toolId;
  }
}

String _pendingActionLabel(String toolId) {
  switch (toolId) {
    case 'create_file':
      return S.toolPendingCreate;
    case 'edit_file':
    case 'multi_edit':
    case 'edit_range':
      return S.toolPendingEdit;
    case 'append_file':
      return S.toolPendingAppend;
    case 'move_file':
      return S.toolPendingMove;
    case 'copy_file':
      return S.toolPendingCopy;
    case 'read_file':
    case 'read_file_range':
      return S.toolPendingRead;
    case 'delete_file':
      return S.toolPendingDelete;
    case 'search_text':
    case 'find_file':
    case 'glob':
      return S.toolPendingSearch;
    case 'run_cmd':
      return S.toolPendingRun;
    default:
      return S.toolPendingInspect;
  }
}

/// File-extension → icon mapping. Falls back to a generic file icon
/// for unknown extensions. Kept small on purpose — we don't need an
/// icon for every language, just enough to make the most common
/// project files distinguishable at a glance.
IconData _iconForFile(String path) {
  final ext = p.extension(path).toLowerCase();
  switch (ext) {
    case '.dart':
    case '.js':
    case '.jsx':
    case '.ts':
    case '.tsx':
    case '.py':
    case '.rb':
    case '.go':
    case '.rs':
    case '.java':
    case '.kt':
    case '.swift':
    case '.c':
    case '.cpp':
    case '.h':
      return Icons.code;
    case '.json':
    case '.yaml':
    case '.yml':
    case '.toml':
    case '.ini':
    case '.conf':
      return Icons.data_object;
    case '.md':
    case '.txt':
    case '.rst':
      return Icons.article_outlined;
    case '.html':
    case '.htm':
    case '.xml':
      return Icons.html;
    case '.css':
    case '.scss':
    case '.sass':
    case '.less':
      return Icons.style;
    case '.png':
    case '.jpg':
    case '.jpeg':
    case '.gif':
    case '.webp':
    case '.svg':
      return Icons.image_outlined;
    default:
      return Icons.insert_drive_file_outlined;
  }
}

// ─── widgets ─────────────────────────────────────────────────────

/// Public dispatcher — picks the right widget per `_ToolKind` and
/// status. Malformed segments are routed to a dedicated warning
/// card regardless of the tool's normal kind: a malformed EDIT_FILE
/// shouldn't render as a clickable file card pretending it landed.
class ToolSegmentView extends StatelessWidget {
  final ToolSegment segment;
  const ToolSegmentView({super.key, required this.segment});

  @override
  Widget build(BuildContext context) {
    if (segment.malformed) {
      return _MalformedToolCard(segment: segment);
    }
    switch (_kindFor(segment.toolId)) {
      case _ToolKind.fileOp:
        return _FileToolCard(segment: segment);
      case _ToolKind.command:
        return _CommandToolCard(segment: segment);
      case _ToolKind.inspection:
        return _InspectionBadge(segment: segment);
    }
  }
}

/// Public dispatcher for grouped tool runs. Renders the collapsed
/// `Read 12 files` summary header; expanding shows each member as
/// the same widget [ToolSegmentView] would have produced for it
/// solo.
class ToolGroupView extends StatefulWidget {
  final ToolGroupSegment group;
  const ToolGroupView({super.key, required this.group});

  @override
  State<ToolGroupView> createState() => _ToolGroupViewState();
}

class _ToolGroupViewState extends State<ToolGroupView> {
  bool _expanded = false;
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // 2026-05 visual de-clutter pass, phase 2: matches the slim row
    // language used by `_FileToolCard` / `_InspectionBadge`. The
    // collapsed header was previously a bordered card with a
    // `_ToolStatusBadge` pill at the end, which read as heavy chrome
    // next to its (now borderless) row siblings. Now: transparent
    // chevron + small icon + slim title row with the count inline.
    // Accent colour on the chevron/icon carries pending/failed
    // status, so no separate badge is needed.
    final tools = widget.group.tools;
    final first = tools.first;
    final kind = _kindFor(first.toolId);
    final accent = first.failed
        ? DuckColors.stateError
        : (first.pending ? DuckColors.accentCyan : DuckColors.fgSubtle);
    final headerIcon = kind == _ToolKind.fileOp
        ? _iconForFileGroup(tools)
        : _iconForInspection(first.toolId);
    final action = _actionLabel(first);
    final isError = !first.pending && !first.ok;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _expanded = !_expanded),
            child: AnimatedContainer(
              duration: DuckMotion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
              child: Row(
                children: [
                  AnimatedRotation(
                    duration: DuckMotion.fast,
                    turns: _expanded ? 0.25 : 0.0,
                    child: const Icon(
                      Icons.chevron_right,
                      size: 11,
                      color: DuckColors.fgMuted,
                    ),
                  ),
                  const SizedBox(width: 4),
                  if (first.pending)
                    const _PendingDot()
                  else
                    Icon(headerIcon, size: 11, color: accent),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      S.toolGroupTitle(action, tools.length),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight:
                            isError ? FontWeight.w600 : FontWeight.w500,
                        color: accent,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedSize(
          duration: DuckMotion.fast,
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(left: 14, top: 1),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (var i = 0; i < tools.length; i++)
                        KeyedSubtree(
                          key: ValueKey(
                            'group-member-${tools[i].toolId}-${tools[i].firstArg}-$i',
                          ),
                          child: ToolSegmentView(segment: tools[i]),
                        ),
                    ],
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ],
    );
  }

  /// Pick a representative icon for a file-group header. Uses the
  /// most common extension in the group; falls back to the generic
  /// "file" glyph when the group spans many extensions.
  IconData _iconForFileGroup(List<ToolSegment> tools) {
    final counts = <IconData, int>{};
    for (final t in tools) {
      final icon = _iconForFile(t.firstArg);
      counts[icon] = (counts[icon] ?? 0) + 1;
    }
    IconData? best;
    var bestCount = 0;
    counts.forEach((icon, count) {
      if (count > bestCount) {
        bestCount = count;
        best = icon;
      }
    });
    return best ?? Icons.insert_drive_file_outlined;
  }
}

/// Shared inspection-icon lookup used by both the singleton
/// [_InspectionBadge] and the grouped [ToolGroupView] header.
IconData _iconForInspection(String toolId) {
  switch (toolId) {
    case 'tree':
      return Icons.account_tree_outlined;
    case 'list_dir':
      return Icons.folder_open_outlined;
    case 'search_text':
      return Icons.search;
    case 'find_file':
    case 'glob':
      return Icons.find_in_page_outlined;
    case 'git_status':
    case 'git_diff':
      return Icons.commit_outlined;
    default:
      return Icons.visibility_outlined;
  }
}

/// Friendly card rendered in place of a raw provider error. Shows
/// the kind / title / body, a Retry chip (only when retryable), and
/// an expandable detail panel for the original raw error string.
///
/// Retry calls [ChatController.retryLastTurn] which deletes the
/// failed assistant message and re-runs the same prompt against the
/// currently-selected model — no new user message is appended.
class ProviderErrorCard extends StatefulWidget {
  final ProviderError error;
  const ProviderErrorCard({super.key, required this.error});

  @override
  State<ProviderErrorCard> createState() => _ProviderErrorCardState();
}

class _ProviderErrorCardState extends State<ProviderErrorCard> {
  bool _showDetails = false;
  bool _retrying = false;

  @override
  void initState() {
    super.initState();
    // Auto-expand details for kinds where the canned body is generic
    // enough that the raw error is what the user actually needs to
    // see. Saves a click on the failure modes that previously
    // rendered as a "barely-visible dark grey square" — the user
    // had to copy the bubble to find out it was a 400.
    final kind = widget.error.kind;
    _showDetails =
        kind == ProviderErrorKind.badRequest ||
        kind == ProviderErrorKind.unknown ||
        kind == ProviderErrorKind.serverError;
  }

  /// One-line excerpt of the raw detail for the always-visible
  /// summary row. Strips the friendly preamble that the controller
  /// added (e.g. `Anthropic API error (400):`) so what remains is
  /// the actually-useful provider-side message.
  String _detailExcerpt(String raw) {
    var s = raw.trim();
    s = s.replaceFirst(
      RegExp(
        r'^(?:Error[:\s]+)?'
        r'(?:Anthropic|Gemini|GitHub Models|GitHub Copilot|OpenAI|Ollama)'
        r'\s*API error\s*\(\d+\)\s*:\s*',
        caseSensitive: false,
      ),
      '',
    );
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (s.length <= 180) return s;
    return '${s.substring(0, 177)}…';
  }

  Future<void> _retry() async {
    if (_retrying) return;
    setState(() => _retrying = true);
    try {
      final state = context.read<AppState>();
      await state.chat.retryLastTurn(
        workspacePath: state.currentDirectory,
        activeFilePath: state.activeFile?.path,
        openFilePaths: state.openFiles.map((f) => f.path).toList(),
      );
    } finally {
      if (mounted) setState(() => _retrying = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final err = widget.error;
    // `badRequest` is the same severity as auth/notFound from the
    // user's perspective ("this won't work, do something") so it
    // shares the red accent rather than the amber one used for
    // transient cases.
    final accent =
        err.kind == ProviderErrorKind.unauthorized ||
            err.kind == ProviderErrorKind.notFound ||
            err.kind == ProviderErrorKind.badRequest
        ? DuckColors.stateError
        : DuckColors.stateWarn;
    final excerpt = _detailExcerpt(err.rawDetail);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: DuckColors.bgDeeper,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border(
            left: BorderSide(color: accent, width: 2),
            top: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
            right: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
            bottom: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_iconFor(err.kind), size: 14, color: accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    err.title,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: DuckColors.fgPrimary,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              err.body,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.4,
              ),
            ),
            // Always-visible one-line excerpt of the actual provider
            // message. Without this the card was a faint warn-bordered
            // rectangle that felt empty unless the user expanded
            // details — Opus 4.7's 400 was the exact failure mode
            // ("dark grey square" per user report). We strip the
            // generic `<Provider> API error (NNN):` preamble so what
            // remains is the substantive bit.
            if (excerpt.isNotEmpty) ...[
              const SizedBox(height: 6),
              SelectableText(
                excerpt,
                style: const TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 11,
                  color: DuckColors.fgPrimary,
                  height: 1.4,
                ),
              ),
            ],
            const SizedBox(height: 8),
            Row(
              children: [
                if (err.retryable)
                  _ErrorChip(
                    icon: Icons.refresh,
                    label: S.providerErrorRetry,
                    accent: DuckColors.accentCyan,
                    onTap: _retrying ? null : _retry,
                    busy: _retrying,
                  ),
                if (err.kind == ProviderErrorKind.unauthorized ||
                    err.kind == ProviderErrorKind.notFound) ...[
                  if (err.retryable) const SizedBox(width: 6),
                  _ErrorChip(
                    icon: Icons.settings_outlined,
                    label: S.providerErrorOpenSettings,
                    accent: DuckColors.fgMuted,
                    onTap: () => context.read<AppState>().openSettingsTab(
                      category: 'general',
                    ),
                  ),
                ],
                const SizedBox(width: 6),
                _ErrorChip(
                  icon: _showDetails ? Icons.expand_less : Icons.expand_more,
                  label: _showDetails
                      ? S.providerErrorHideDetails
                      : S.providerErrorShowDetails,
                  accent: DuckColors.fgMuted,
                  onTap: () => setState(() => _showDetails = !_showDetails),
                ),
              ],
            ),
            if (_showDetails) ...[
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 160),
                decoration: BoxDecoration(
                  color: DuckColors.bgDeepest,
                  borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  border: Border.all(color: DuckColors.glassSeam, width: 0.5),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    err.rawDetail,
                    style: const TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 11,
                      color: DuckColors.fgMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  IconData _iconFor(ProviderErrorKind kind) {
    switch (kind) {
      case ProviderErrorKind.overloaded:
      case ProviderErrorKind.serverError:
        return Icons.cloud_off_outlined;
      case ProviderErrorKind.rateLimited:
        return Icons.speed_outlined;
      case ProviderErrorKind.timeout:
        return Icons.timer_off_outlined;
      case ProviderErrorKind.unauthorized:
        return Icons.lock_outline;
      case ProviderErrorKind.badRequest:
        return Icons.report_gmailerrorred_outlined;
      case ProviderErrorKind.notFound:
        return Icons.help_outline;
      case ProviderErrorKind.network:
        return Icons.wifi_off_outlined;
      case ProviderErrorKind.unknown:
        return Icons.error_outline;
    }
  }
}

class _ErrorChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final Color accent;
  final VoidCallback? onTap;
  final bool busy;
  const _ErrorChip({
    required this.icon,
    required this.label,
    required this.accent,
    required this.onTap,
    this.busy = false,
  });

  @override
  State<_ErrorChip> createState() => _ErrorChipState();
}

class _ErrorChipState extends State<_ErrorChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
          decoration: BoxDecoration(
            color: _hover && !disabled
                ? widget.accent.withValues(alpha: 0.12)
                : DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: _hover && !disabled
                  ? widget.accent.withValues(alpha: 0.55)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.busy)
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.4,
                    color: DuckColors.accentCyan,
                  ),
                )
              else
                Icon(widget.icon, size: 12, color: widget.accent),
              const SizedBox(width: 5),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: disabled ? DuckColors.fgSubtle : widget.accent,
                  letterSpacing: 0.2,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Cursor-style file card. Icon + filename + action label, hover
/// reveals a "click to open" affordance, click opens the file in
/// the editor (resolves relative-to-workspace via `AppState`).
class _FileToolCard extends StatefulWidget {
  final ToolSegment segment;
  const _FileToolCard({required this.segment});

  @override
  State<_FileToolCard> createState() => _FileToolCardState();
}

class _FileToolCardState extends State<_FileToolCard> {
  bool _hover = false;
  bool _bodyExpanded = false;
  final ScrollController _bodyScroll = ScrollController();
  // Tracks whether the user has manually scrolled the body away
  // from the bottom. While "tailing" (at bottom), we auto-scroll on
  // each rebuild so new tokens are always visible. When the user
  // scrolls up to inspect earlier content, we honour that and stop
  // chasing the bottom — they're reading, don't yank them.
  bool _bodyAtBottom = true;

  @override
  void initState() {
    super.initState();
    _bodyScroll.addListener(_onBodyScroll);
  }

  @override
  void dispose() {
    _bodyScroll.removeListener(_onBodyScroll);
    _bodyScroll.dispose();
    super.dispose();
  }

  void _onBodyScroll() {
    if (!_bodyScroll.hasClients) return;
    final pos = _bodyScroll.position;
    final atBottom = pos.pixels >= pos.maxScrollExtent - 4;
    if (atBottom != _bodyAtBottom) {
      setState(() => _bodyAtBottom = atBottom);
    }
  }

  void _scrollBodyToBottomSoon() {
    // Schedule for after the current build so the new content is
    // already laid out. Cheap; no-op when the scrollview isn't
    // attached or the user has scrolled away from bottom.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_bodyScroll.hasClients) return;
      if (!_bodyAtBottom) return;
      _bodyScroll.jumpTo(_bodyScroll.position.maxScrollExtent);
    });
  }

  String _targetPath() {
    final s = widget.segment;
    String relPath = s.firstArg.trim();
    // Strip the trailing `#Lstart[-end]` line-range hint baked into
    // firstArg by `_friendlyReplacement`. Stripped here so the path
    // resolution below sees a clean filename. The line range itself
    // stays accessible via `_lineRange()` for the chip display and
    // the click-to-line jump.
    final hashIdx = relPath.lastIndexOf('#L');
    if (hashIdx > 0) {
      relPath = relPath.substring(0, hashIdx);
    }
    if ((s.toolId == 'move_file' || s.toolId == 'copy_file') &&
        relPath.contains('->')) {
      relPath = relPath.split('->').last.trim();
    }
    // EDIT_RANGE's `firstArg` carries `file:start-end` so the chip
    // can show the range (intentional UX). Strip the trailing
    // `:N-M` here so clicking the chip opens the file itself rather
    // than a non-existent path with the range tacked on.
    if (s.toolId == 'edit_range') {
      final m = RegExp(r'^(.*):\d+-\d+$').firstMatch(relPath);
      if (m != null) relPath = m.group(1)!.trim();
    }
    // Some tools encode line ranges (read_file_range: "path:S-E");
    // chop off everything after the first colon for path resolution.
    final colonIdx = relPath.indexOf(':');
    if (colonIdx > 0) relPath = relPath.substring(0, colonIdx);
    return relPath.trim();
  }

  /// Parsed line range from the `#Lstart[-end]` suffix on firstArg.
  /// Returns null when the marker carries no range (read tools,
  /// errors, legacy markers from before the line-hint plumbing).
  ///
  /// Two return shapes share one parser: single-line edits emit
  /// `#L42` (start == end), multi-line edits emit `#L42-58`. Both
  /// are normalised to a `(start, end)` record where end falls back
  /// to start when the range is collapsed.
  ({int start, int end})? _lineRange() {
    final raw = widget.segment.firstArg;
    final hashIdx = raw.lastIndexOf('#L');
    if (hashIdx < 0) return null;
    final tail = raw.substring(hashIdx + 2);
    final m = RegExp(r'^(\d+)(?:-(\d+))?$').firstMatch(tail);
    if (m == null) return null;
    final start = int.tryParse(m.group(1)!);
    if (start == null) return null;
    final end = int.tryParse(m.group(2) ?? '$start') ?? start;
    return (start: start, end: end);
  }

  Future<void> _openFile(BuildContext context) async {
    final s = widget.segment;
    if (s.pending || s.toolId == 'delete_file') return;
    final relPath = _targetPath();
    if (relPath.isEmpty) return;
    final state = context.read<AppState>();
    final ws = state.currentDirectory;
    if (ws == null) return; // no workspace, nothing to open
    final abs = p.isAbsolute(relPath) ? relPath : p.join(ws, relPath);
    final f = File(abs);
    if (!await f.exists()) return;
    await state.openFile(f);
    state.ideActions.revealFileExplorerPath(f.path);
    // Jump the editor to the touched line range when one is known.
    // The editor needs a frame to mount/swap controllers after the
    // tab change `openFile` triggers, so we retry briefly. 8 × 50ms
    // (~400ms total) is well under "user notices a delay" while
    // covering even slow file-load paths.
    final range = _lineRange();
    if (range != null) {
      await _scrollEditorToLine(state, range.start, range.end);
    }
  }

  /// Reveal the touched line span and highlight it.
  ///
  /// Two things have to happen here that aren't automatic in
  /// `re_editor`:
  ///
  /// 1. **Scroll**. Setting `selection` does NOT move the viewport
  ///    — that's a render-layer concern. We have to call
  ///    `makePositionCenterIfInvisible` to pull the touched line
  ///    into view. `CenterIfInvisible` (vs `Visible`) avoids
  ///    yanking the viewport when the line is already on screen,
  ///    which is the common case right after the agent edits a
  ///    file the user is already looking at.
  ///
  /// 2. **Highlight**. A `CodeLineSelection.collapsed` is just a
  ///    blinking caret — invisible at a glance. We instead set a
  ///    non-collapsed selection from `(start, 0)` to the END of
  ///    the last touched line; the editor renders that span using
  ///    `selectionColor` (themed `DuckColors.editorSelection`),
  ///    matching the "click a stack-trace line" affordance every
  ///    serious IDE shows.
  ///
  /// Inputs are 1-based line numbers from the `#Lstart-end` marker
  /// suffix (matches GitHub's URL convention). Clamped against the
  /// current document length so a stale marker pointing past EOF
  /// (file shrunk after the edit) lands on the last line instead
  /// of throwing.
  Future<void> _scrollEditorToLine(
    AppState state,
    int startLine,
    int endLine,
  ) async {
    for (var i = 0; i < 8; i++) {
      final ed = state.ideActions.activeEditor;
      if (ed != null && ed.lineCount > 0) {
        final maxIdx = ed.lineCount - 1;
        final startIdx = (startLine - 1).clamp(0, maxIdx);
        final endIdx = (endLine - 1).clamp(startIdx, maxIdx);
        final endLineLength = ed.codeLines[endIdx].length;
        ed.selection = CodeLineSelection(
          baseIndex: startIdx,
          baseOffset: 0,
          extentIndex: endIdx,
          extentOffset: endLineLength,
        );
        ed.makePositionCenterIfInvisible(
          CodeLinePosition(index: startIdx, offset: 0),
        );
        return;
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.segment;
    final action = _actionLabel(s);
    final targetPath = _targetPath();
    final icon = _iconForFile(targetPath);
    final filename = targetPath.isEmpty ? s.firstArg : p.basename(targetPath);
    final dir = targetPath.isEmpty ? '' : p.dirname(targetPath);
    final accent = s.pending
        ? DuckColors.accentCyan
        : s.ok
        ? DuckColors.accentMint
        : DuckColors.stateError;
    final openable = !s.pending && s.toolId != 'delete_file';
    // Live body preview gating. Only body-shaped pending tools have
    // a meaningful tail-the-stream view: single-line tools
    // (MOVE_FILE, COPY_FILE, READ_FILE, …) finish in one source
    // line so there's nothing to "watch". Even within body-shaped
    // tools we skip the chevron when the body is empty (the
    // opener has streamed but no body bytes have arrived yet) —
    // showing an empty disclosure is just visual noise.
    final body = s.pendingBody ?? '';
    final hasLiveBody =
        s.pending && _kBodyShapedToolIds.contains(s.toolId) && body.isNotEmpty;
    // Click semantics:
    //   - Settled non-delete file op: open the file (existing UX).
    //   - Pending body-shaped tool with body bytes: toggle the
    //     live preview region. This is the user-visible "tail -f"
    //     for runaway-token-loop diagnosis.
    //   - Otherwise: no-op.
    final cardClickable = openable || hasLiveBody;
    void onTap() {
      if (openable) {
        _openFile(context);
        return;
      }
      if (hasLiveBody) {
        setState(() => _bodyExpanded = !_bodyExpanded);
        if (_bodyExpanded) {
          // Reset the tail-tracking flag so the first frame after
          // expand snaps to the bottom (most recent tokens).
          _bodyAtBottom = true;
          _scrollBodyToBottomSoon();
        }
      }
    }

    if (hasLiveBody && _bodyExpanded) {
      // Auto-tail while the body is expanded and the user hasn't
      // scrolled away. Cheap; no-op when already at bottom.
      _scrollBodyToBottomSoon();
    }

    // 2026-05 visual de-clutter pass: was a bordered card with
    // bgDeeper background, ~36px tall when stacked filename + dir.
    // For a turn that reads 8 files this stacked into a wall of
    // chrome that drowned the assistant's prose. Slim treatment
    // matches `_InspectionBadge` and `_ThinkingBlock`: borderless
    // single-line row, transparent bg, hover lift to bgRaisedHi,
    // path rendered inline as full relative path (no dir/filename
    // split). Click semantics preserved: openable rows open the
    // file in the editor, body-shaped pending rows toggle the
    // streaming `_LiveBodyPanel`. The action label colour + the
    // pending-dot / error tint carry status. Status badge dropped
    // — its info now lives in the action text ("Read failed" /
    // "Edited") and the accent colour.
    final isError = !s.pending && !s.ok;
    return MouseRegion(
      cursor: cardClickable
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: cardClickable ? onTap : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedContainer(
              duration: DuckMotion.fast,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (s.pending)
                    const _PendingDot()
                  else
                    Icon(icon, size: 11, color: accent),
                  const SizedBox(width: 6),
                  Text(
                    action,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isError ? FontWeight.w600 : FontWeight.w500,
                      color: accent,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      // Show the full relative path inline. The
                      // older split-into-filename-and-dir layout
                      // wasted vertical space and forced two lines
                      // for any file outside the workspace root.
                      // Full path also matches what the
                      // `_InspectionBadge` renders so the two
                      // surfaces read consistently.
                      dir.isNotEmpty && dir != '.'
                          ? '$dir/$filename'
                          : filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 11,
                        color: isError
                            ? DuckColors.stateError
                            : DuckColors.fgMuted,
                      ),
                    ),
                  ),
                  // Touched-line-range chip. Edit-shaped tools
                  // populate `#Lstart[-end]` on `firstArg`; we render
                  // it as `· L42` (or `· L42-58`) so the user can see
                  // the touched span at a glance. Click semantics
                  // unchanged from the row — clicking opens the file
                  // and `_openFile` jumps the editor to the start
                  // line.
                  if (_lineRange() case final range?) ...[
                    const SizedBox(width: 6),
                    Text(
                      range.start == range.end
                          ? '· L${range.start}'
                          : '· L${range.start}-${range.end}',
                      style: const TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 10.5,
                        color: DuckColors.fgFaint,
                      ),
                    ),
                  ],
                  if (hasLiveBody)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: AnimatedRotation(
                        turns: _bodyExpanded ? 0.5 : 0.0,
                        duration: DuckMotion.fast,
                        child: const Icon(
                          Icons.expand_more,
                          size: 14,
                          color: DuckColors.accentCyan,
                        ),
                      ),
                    )
                  else if (openable)
                    AnimatedOpacity(
                      duration: DuckMotion.fast,
                      opacity: _hover ? 1.0 : 0.0,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 6),
                        child: Icon(
                          Icons.open_in_new,
                          size: 11,
                          color: DuckColors.accentCyan,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (hasLiveBody && _bodyExpanded)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 6, bottom: 2),
                child: _LiveBodyPanel(
                  body: body,
                  scrollController: _bodyScroll,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The expandable "Live preview" region under a pending body-shaped
/// file-op chip. Renders the partial body the model has streamed
/// so far in monospace, scrollable, capped height — the user's
/// `tail -f` on the in-flight stream so a runaway can be spotted
/// and aborted before the output budget burns through.
///
/// Two design notes worth keeping:
///   - **Capped height.** A 500-line CREATE_FILE body would push
///     the chip half a screen high; that's worse than no preview
///     at all because it pushes the rest of the chat off-screen.
///     180px shows ~12 mono lines, enough to recognise a token
///     loop ("REPLACE REPLACE REPLACE…") at a glance.
///   - **Tail by default, but stop chasing on user scroll.** The
///     parent attaches a [ScrollController] that's tracked by
///     [_FileToolCardState._onBodyScroll]; once the user scrolls
///     up the auto-jump-to-bottom stops until they scroll back
///     down. Same convention as a terminal "follow tail" toggle.
class _LiveBodyPanel extends StatelessWidget {
  final String body;
  final ScrollController scrollController;
  const _LiveBodyPanel({required this.body, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 180),
      decoration: BoxDecoration(
        color: DuckColors.bgBase,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      child: Scrollbar(
        controller: scrollController,
        thumbVisibility: true,
        child: SingleChildScrollView(
          controller: scrollController,
          child: SelectableText(
            body,
            style: const TextStyle(
              fontFamily: DuckTheme.monoFont,
              fontSize: 11,
              height: 1.4,
              color: DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Slim row for shell commands. Matches the visual language of
/// `_FileToolCard` / `_InspectionBadge` — transparent borderless
/// row with hover lift, accent-tinted action label, mono command
/// payload — so a turn that runs a few commands amongst reads /
/// edits reads as one stream instead of mixed-weight chrome.
///
/// 2026-05 visual de-clutter pass, phase 2. The earlier solid
/// `bgDeepest` card + status badge stood out next to its now-borderless
/// siblings and made multi-tool turns look uneven. Stateful only so
/// hover lift works; no other per-instance state.
class _CommandToolCard extends StatefulWidget {
  final ToolSegment segment;
  const _CommandToolCard({required this.segment});

  @override
  State<_CommandToolCard> createState() => _CommandToolCardState();
}

class _CommandToolCardState extends State<_CommandToolCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final accent = segment.pending
        ? DuckColors.accentCyan
        : segment.ok
        ? DuckColors.accentMint
        : DuckColors.stateError;
    final isError = !segment.pending && !segment.ok;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: segment.pending
                  ? const _PendingDot()
                  : Icon(Icons.terminal, size: 11, color: accent),
            ),
            const SizedBox(width: 6),
            Padding(
              padding: const EdgeInsets.only(top: 0.5),
              child: Text(
                _actionLabel(segment),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: isError ? FontWeight.w600 : FontWeight.w500,
                  color: accent,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                segment.firstArg,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: DuckTheme.monoFont,
                  fontSize: 11,
                  color: isError
                      ? DuckColors.stateError
                      : DuckColors.fgMuted,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact pill for read-only inspection ops. Doesn't deserve a full
/// card — these are "the agent looked at something", not "the agent
/// changed something". When 3+ consecutive inspections share the
/// same action, [parseChatSegments] collapses them into a
/// [ToolGroupSegment] and renders the [ToolGroupView] header
/// instead, so a long search-spam turn doesn't blow up the column.
class _InspectionBadge extends StatefulWidget {
  final ToolSegment segment;
  const _InspectionBadge({required this.segment});

  @override
  State<_InspectionBadge> createState() => _InspectionBadgeState();
}

class _InspectionBadgeState extends State<_InspectionBadge> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    // 2026-05 visual de-clutter pass: was a bordered pill with
    // letter-spaced UPPERCASE action label. Eight of those in one turn
    // made the chat read as wall-of-chips and drowned the prose. New
    // form is a borderless, single-line activity row mirroring the
    // queued-prompts strip's `_QueuedPromptRow` grammar — small icon,
    // lowercase action, mono-styled arg, hover lift on
    // `bgRaisedHi`. Status (pending / failed) reads on the accent
    // color of the action label so failures stay scannable.
    //
    // Rendered inside the assistant bubble's Column, full-width
    // constraint. The arg is `Flexible` with ellipsis so a long
    // SEARCH_TEXT query truncates instead of overflowing.
    final accent = segment.pending
        ? DuckColors.accentCyan
        : segment.ok
        ? DuckColors.fgSubtle
        : DuckColors.stateError;
    final isError = !segment.pending && !segment.ok;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (segment.pending)
              const _PendingDot()
            else
              Icon(_iconForInspection(segment.toolId), size: 11, color: accent),
            const SizedBox(width: 6),
            Text(
              _actionLabel(segment),
              style: TextStyle(
                fontSize: 11,
                fontWeight: isError ? FontWeight.w600 : FontWeight.w500,
                color: accent,
                fontStyle: FontStyle.italic,
              ),
            ),
            if (segment.firstArg.isNotEmpty) ...[
              const SizedBox(width: 6),
              Flexible(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(
                    segment.firstArg,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    softWrap: false,
                    style: TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 11,
                      color: isError
                          ? DuckColors.stateError
                          : DuckColors.fgMuted,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Three-dot loading glyph used inside the compact inspection
/// badge instead of a static icon when a tool is still in flight.
/// Cheaper than wrapping the whole badge in a shimmer; the dots
/// occupy the icon slot exactly so layout doesn't shift when a
/// pending inspection completes.
class _PendingDot extends StatefulWidget {
  const _PendingDot();

  @override
  State<_PendingDot> createState() => _PendingDotState();
}

class _PendingDotState extends State<_PendingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 11,
      height: 11,
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (_, _) {
          return CustomPaint(painter: _PendingDotPainter(t: _ctrl.value));
        },
      ),
    );
  }
}

class _PendingDotPainter extends CustomPainter {
  final double t;
  _PendingDotPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    const dotR = 1.2;
    final cy = size.height / 2;
    for (var i = 0; i < 3; i++) {
      final phase = (t + i * 0.18) % 1.0;
      final wave = (phase < 0.5)
          ? Curves.easeInOut.transform(phase * 2)
          : Curves.easeInOut.transform((1 - phase) * 2);
      final alpha = 0.30 + 0.55 * wave;
      paint.color = DuckColors.accentCyan.withValues(alpha: alpha);
      final cx = 1.5 + i * 4.0;
      canvas.drawCircle(Offset(cx, cy), dotR, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PendingDotPainter old) => old.t != t;
}

/// Slim warning row surfaced when the parser detected a tool-shaped
/// block in the model's output but the inner structure rejected the
/// strict per-tool regex. The block will NOT execute — neither here
/// in the UI nor in `ToolExecutor.run` — so we surface a one-line
/// "Malformed" indicator instead of letting the raw body leak into
/// the chat as hundreds of lines of code.
///
/// 2026-05 visual de-clutter pass, phase 2. The earlier card form
/// (bordered, two-line block with a help glyph) read as alarming
/// chrome amongst the now-borderless `_FileToolCard` siblings. The
/// slim row keeps the warn accent so it remains scannable but lines
/// up with the rest of the tool stream. The tooltip still explains
/// what went wrong — hover anywhere on the row.
class _MalformedToolCard extends StatefulWidget {
  final ToolSegment segment;
  const _MalformedToolCard({required this.segment});

  @override
  State<_MalformedToolCard> createState() => _MalformedToolCardState();
}

class _MalformedToolCardState extends State<_MalformedToolCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final segment = widget.segment;
    final tool = ToolRegistry.byId(segment.toolId);
    final toolLabel = tool?.name ?? segment.toolId.toUpperCase();
    final summary = segment.firstArg.trim().isEmpty
        ? toolLabel
        : '$toolLabel: ${segment.firstArg.trim()}';
    return Tooltip(
      message: S.toolMalformedTooltip(toolLabel),
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.warning_amber_rounded,
                size: 11,
                color: DuckColors.stateWarn,
              ),
              const SizedBox(width: 6),
              const Text(
                S.toolMalformedLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: DuckColors.stateWarn,
                  fontStyle: FontStyle.italic,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(
                    fontFamily: DuckTheme.monoFont,
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
