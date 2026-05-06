/// Typed exit-reason model for the per-iteration body of the agent
/// generation loop.
///
/// Pulled out of [ChatController._runGenerationLoop] in 2026-05 because
/// the iteration body had grown to track ~9 partially-overlapping
/// flags (`runawayDetected`, `halluHaltTriggered`,
/// `hallucinationDetected`, `cutOnFirstTool`, `wasTruncated`, etc.)
/// and the post-loop "what just happened?" reasoning was scattered
/// across three branches with implicit precedence. A single typed
/// outcome makes the post-loop code one switch.
///
/// Pure types only — no controller / service deps. Intentionally
/// kept dep-free so the detector pipeline + nudge builder can
/// import this without dragging in flutter_foundation.
library;

/// Why the streaming-and-execute body of one iteration ended.
/// Ordered roughly by precedence the controller applies — when
/// multiple conditions fire the controller picks the one earliest
/// in this list (cancellation always wins, then runaway, then
/// hallucination-halt, then explicit cut, then natural stop).
enum IterationOutcome {
  /// User clicked Stop. Loop exits, no auto-continue, no halt warning.
  cancelled,

  /// `>80 markers` / `>12 RUN_CMD` runaway guard tripped. Iteration's
  /// tool calls are NOT executed, conversation loop ends with a
  /// "_(loop guard tripped)_" footer.
  runawayMarkers,

  /// Hallucination threshold (≥3 fake "Created/Edited X" claims
  /// within a single iteration) reached. Loop ends with a banner
  /// listing the claimed-but-missing paths.
  hallucinatedClaims,

  /// Stream cut at the first complete `<<<TOOL>>>...<<<END>>>` block
  /// in text-grammar mode, or at the first `tool_use` block in
  /// native-tools mode. Executor runs the cut chunk, next iteration
  /// gets the tool_result.
  cutOnFirstTool,

  /// Stream cut at the first `<tool_result>` impostor (model
  /// fabricating tool execution). Auto-continue gate fires with
  /// the impostor-specific nudge.
  hallucinatedToolResult,

  /// Provider stream signalled `done_reason: length` /
  /// `stop_reason: max_tokens` / `finish_reason: length`. Auto-
  /// continue fires with a "continue from where you left off" nudge.
  truncated,

  /// Iteration produced no executable content at all. Auto-continue
  /// fires (or, if exhausted, the empty-response strip surfaces
  /// post-loop).
  empty,

  /// Iteration produced thinking tokens but no visible content.
  /// Auto-continue with a "you reasoned but produced nothing" nudge.
  thinkingNoOutput,

  /// Model wrote a tool-shaped string with the wrong outer syntax
  /// (single brackets, doubled brackets, missing close, HTML
  /// comment, unknown tool name). Auto-continue with a
  /// shape-specific nudge.
  nearMissTool,

  /// Model committed to an action ("Let me read…", "I'll check…")
  /// but never invoked the tool. Auto-continue with a "saying you
  /// will is not doing" nudge.
  intentWithoutAction,

  /// Model emitted a multi-line file-tool opener but never the
  /// matching close marker. Auto-continue with an "emit the close
  /// marker too" nudge.
  incompleteFileTool,

  /// Tool calls fired and ran successfully. Iteration loop
  /// continues with their tool_results in the next prompt.
  toolsExecuted,

  /// Model's reply contained no tool calls and no retry-worthy
  /// signal. Loop ends cleanly.
  done,
}

/// Auto-continue reason — exactly the subset of [IterationOutcome]
/// values that trigger a retry. Used by the nudge builder. The
/// remaining outcomes either end the loop (cancelled / done /
/// hallucinatedClaims / runawayMarkers) or transition to the next
/// iteration with tool feedback (toolsExecuted / cutOnFirstTool).
enum RetryReason {
  truncation,
  hallucinatedToolResult,
  empty,
  thinkingNoOutput,
  nearMissTool,
  intentWithoutAction,
  incompleteFileTool,
}

/// Maps an [IterationOutcome] back to the [RetryReason] that should
/// drive the next-iteration nudge, or null when the outcome is
/// terminal (loop ends).
RetryReason? retryReasonFor(IterationOutcome o) {
  switch (o) {
    case IterationOutcome.truncated:
      return RetryReason.truncation;
    case IterationOutcome.hallucinatedToolResult:
      return RetryReason.hallucinatedToolResult;
    case IterationOutcome.empty:
      return RetryReason.empty;
    case IterationOutcome.thinkingNoOutput:
      return RetryReason.thinkingNoOutput;
    case IterationOutcome.nearMissTool:
      return RetryReason.nearMissTool;
    case IterationOutcome.intentWithoutAction:
      return RetryReason.intentWithoutAction;
    case IterationOutcome.incompleteFileTool:
      return RetryReason.incompleteFileTool;
    case IterationOutcome.cancelled:
    case IterationOutcome.runawayMarkers:
    case IterationOutcome.hallucinatedClaims:
    case IterationOutcome.cutOnFirstTool:
    case IterationOutcome.toolsExecuted:
    case IterationOutcome.done:
      return null;
  }
}

/// Short tag emitted in `_(auto-continued — <tag>. Attempt N/M.)_`
/// footers and in the `[turn-timing]` debugPrint. Stable across UI
/// languages — i18n only the prose nudge, not the tag.
String retryTag(RetryReason r) {
  switch (r) {
    case RetryReason.truncation:
      return 'truncation';
    case RetryReason.hallucinatedToolResult:
      return 'hallucinated tool_result';
    case RetryReason.empty:
      return 'empty';
    case RetryReason.thinkingNoOutput:
      return 'thinking but no output';
    case RetryReason.nearMissTool:
      return 'tool syntax near-miss';
    case RetryReason.intentWithoutAction:
      return 'intent without action';
    case RetryReason.incompleteFileTool:
      return 'incomplete tool block';
  }
}
