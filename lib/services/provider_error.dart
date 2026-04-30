/// Provider-side error classification + chat marker grammar.
///
/// **Why this exists** — every LLM service in `lib/services/` (Ollama,
/// Gemini, Anthropic, GitHub Models, …) yields its error condition as
/// part of the response stream, in a free-form string like:
///
///     Error: Ollama returned 503 {"error":"Server overloaded …"}
///     Anthropic API error (529): rate_limit_error
///     Error connecting to Gemini: SocketException …
///
/// Without a classifier the chat panel just renders that raw text in a
/// regular bubble, which (a) looks scary, (b) buries the actionable bit
/// (retry / fix credentials), (c) reads as "the model said this" when it
/// was actually the transport layer.
///
/// `ProviderError.tryParse` runs over the final assistant content right
/// before persistence and decides whether the turn ended in a
/// recognisable provider failure. If yes, the chat controller swaps the
/// raw text for a structured `<!-- LUMEN_ERR:<kind>|<encoded-detail> -->`
/// marker that the chat panel renders as a friendly card with a Retry
/// chip. Same pattern as the `LUMEN_TOOL` markers — markdown ignores
/// HTML comments so the failure mode is "user sees nothing" not "leaked
/// custom syntax".
///
/// Detection is intentionally pattern-based, not exhaustive:
///   - We hit the *common* transient cases (overloaded, rate limited,
///     5xx, network, timeout, auth, model-not-found).
///   - Anything we don't recognise ends up as `unknown` so it still
///     gets the retry chip — the user can decide.
library;

import '../l10n/strings.dart';

/// Kind of provider-side failure. Drives the friendly title / body shown
/// in the chat-side error card and which buttons are surfaced.
enum ProviderErrorKind {
  overloaded,
  rateLimited,
  serverError,
  timeout,
  unauthorized,
  /// HTTP 400 — request body invalid for this model (wrong parameter
  /// shape, removed field, etc.). Distinct from `unauthorized` because
  /// the user CAN'T fix this in Settings — it's a client-code bug
  /// surfaced as an Anthropic / OpenAI / Gemini schema mismatch. The
  /// raw error text is what the user / agent needs to see, so the
  /// card auto-expands details for this kind.
  badRequest,
  notFound,
  network,
  unknown,
}

/// Parsed result of trying to extract a `ProviderError` from the
/// final raw text of an assistant turn.
class ProviderError {
  final ProviderErrorKind kind;
  final String rawDetail;

  /// True when retrying the same prompt is reasonable — i.e. the
  /// failure was transient (overloaded, rate-limited, 5xx, timeout,
  /// network). False for auth / not-found, where retrying without
  /// changes will just fail again.
  bool get retryable => switch (kind) {
    ProviderErrorKind.overloaded => true,
    ProviderErrorKind.rateLimited => true,
    ProviderErrorKind.serverError => true,
    ProviderErrorKind.timeout => true,
    ProviderErrorKind.network => true,
    ProviderErrorKind.unknown => true,
    ProviderErrorKind.unauthorized => false,
    // 400s are client-code bugs (wrong field shape, deprecated param);
    // retrying the same body fails the same way. The user wants to
    // see the actual error and either change models or wait for a
    // Lumen update.
    ProviderErrorKind.badRequest => false,
    ProviderErrorKind.notFound => false,
  };

  String get title => switch (kind) {
    ProviderErrorKind.overloaded => S.providerErrorOverloaded,
    ProviderErrorKind.rateLimited => S.providerErrorRateLimited,
    ProviderErrorKind.serverError => S.providerErrorServer,
    ProviderErrorKind.timeout => S.providerErrorTimeout,
    ProviderErrorKind.unauthorized => S.providerErrorAuth,
    ProviderErrorKind.badRequest => S.providerErrorBadRequest,
    ProviderErrorKind.notFound => S.providerErrorNotFound,
    ProviderErrorKind.network => S.providerErrorNetwork,
    ProviderErrorKind.unknown => S.providerErrorUnknown,
  };

  String get body => switch (kind) {
    ProviderErrorKind.overloaded => S.providerErrorOverloadedBody,
    ProviderErrorKind.rateLimited => S.providerErrorRateLimitedBody,
    ProviderErrorKind.serverError => S.providerErrorServerBody,
    ProviderErrorKind.timeout => S.providerErrorTimeoutBody,
    ProviderErrorKind.unauthorized => S.providerErrorAuthBody,
    ProviderErrorKind.badRequest => S.providerErrorBadRequestBody,
    ProviderErrorKind.notFound => S.providerErrorNotFoundBody,
    ProviderErrorKind.network => S.providerErrorNetworkBody,
    ProviderErrorKind.unknown => S.providerErrorUnknownBody,
  };

  const ProviderError({required this.kind, required this.rawDetail});

  /// Try to extract a `ProviderError` from a body of assistant text.
  ///
  /// Heuristic order matters — more specific patterns first, then
  /// fall through to broad ones. Returns `null` when nothing matches,
  /// meaning the controller should treat the turn as ordinary content.
  ///
  /// **Empty / cancelled / runaway-loop notices** are NOT treated as
  /// provider errors — they have their own, different UX (the
  /// `_(stopped)_` / `_(loop detected …)_` italic notices). We only
  /// fire when the controller would otherwise render something the
  /// user has to read raw.
  static ProviderError? tryParse(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty) return null;

    // Skip our own internal italic notices — they're not provider
    // errors, they're controller-side acknowledgements.
    if (trimmed.startsWith('_(') && trimmed.endsWith(')_')) return null;

    // Idle-timeout markers come from the streaming services as a
    // distinctive italic line at the END of an otherwise-normal
    // response. We *only* treat them as a provider error when they
    // are the WHOLE response (no real content before).
    final timeoutMatch = _idleTimeoutRe.firstMatch(trimmed);
    if (timeoutMatch != null) {
      final body = trimmed.substring(0, timeoutMatch.start).trim();
      if (body.isEmpty) {
        return ProviderError(
          kind: ProviderErrorKind.timeout,
          rawDetail: timeoutMatch.group(0) ?? trimmed,
        );
      }
      // Real partial content followed by a timeout note — not a
      // pure provider failure, leave the chat panel to render it
      // as usual prose.
      return null;
    }

    // Status-code aware patterns. Most of our services format errors
    // as `... returned <code>` or `... API error (<code>)`. We
    // extract the first 3-digit HTTP-like number we see and let it
    // drive the kind; this handles every provider in one regex pass.
    final code = _extractStatusCode(trimmed);
    if (code != null) {
      // Scope detection to messages that announce themselves as an
      // error — otherwise a model that legitimately writes the
      // string "503" in prose would get classified as a 503 outage.
      if (_looksLikeErrorPreamble(trimmed)) {
        if (code == 503) {
          return ProviderError(
            kind: ProviderErrorKind.overloaded,
            rawDetail: trimmed,
          );
        }
        if (code == 429) {
          return ProviderError(
            kind: ProviderErrorKind.rateLimited,
            rawDetail: trimmed,
          );
        }
        if (code >= 500 && code < 600) {
          return ProviderError(
            kind: ProviderErrorKind.serverError,
            rawDetail: trimmed,
          );
        }
        if (code == 401 || code == 403) {
          return ProviderError(
            kind: ProviderErrorKind.unauthorized,
            rawDetail: trimmed,
          );
        }
        if (code == 404) {
          return ProviderError(
            kind: ProviderErrorKind.notFound,
            rawDetail: trimmed,
          );
        }
        if (code == 408 || code == 504) {
          return ProviderError(
            kind: ProviderErrorKind.timeout,
            rawDetail: trimmed,
          );
        }
        // 400 = malformed request body. Distinct from 401/403 because
        // the user can't fix it in Settings — Lumen sent the wrong
        // shape. Telling them "Authentication failed" sends them
        // chasing a non-existent credential bug (see the Opus 4.7
        // adaptive-thinking migration: legacy `thinking.type.enabled`
        // returns 400 even though API key is fine).
        if (code == 400) {
          return ProviderError(
            kind: ProviderErrorKind.badRequest,
            rawDetail: trimmed,
          );
        }
        // Other 4xx — fall through to `badRequest` rather than auth.
        // 405/409/410/422 are all "caller sent something wrong",
        // not "credentials rejected".
        if (code >= 400 && code < 500) {
          return ProviderError(
            kind: ProviderErrorKind.badRequest,
            rawDetail: trimmed,
          );
        }
      }
    }

    // String-pattern fallbacks (case-insensitive). These catch
    // provider-specific phrases that don't include the status code
    // verbatim, e.g. "Server overloaded", "rate_limit_error", etc.
    final lower = trimmed.toLowerCase();
    if (_overloadedPhrases.any(lower.contains)) {
      return ProviderError(
        kind: ProviderErrorKind.overloaded,
        rawDetail: trimmed,
      );
    }
    if (_rateLimitPhrases.any(lower.contains)) {
      return ProviderError(
        kind: ProviderErrorKind.rateLimited,
        rawDetail: trimmed,
      );
    }
    if (_authPhrases.any(lower.contains)) {
      return ProviderError(
        kind: ProviderErrorKind.unauthorized,
        rawDetail: trimmed,
      );
    }
    if (_notFoundPhrases.any(lower.contains)) {
      return ProviderError(
        kind: ProviderErrorKind.notFound,
        rawDetail: trimmed,
      );
    }
    if (_networkPhrases.any(lower.contains)) {
      return ProviderError(
        kind: ProviderErrorKind.network,
        rawDetail: trimmed,
      );
    }

    // The "Error connecting to <provider>" / generic "Error: ..."
    // preamble — pure transport failure, treat as network.
    if (_genericErrorPreamble.hasMatch(trimmed)) {
      return ProviderError(
        kind: ProviderErrorKind.network,
        rawDetail: trimmed,
      );
    }

    // Lastly: provider name + the word "error" somewhere — a
    // catch-all so we don't render a raw provider error string.
    if (_genericProviderError.hasMatch(trimmed)) {
      return ProviderError(
        kind: ProviderErrorKind.unknown,
        rawDetail: trimmed,
      );
    }

    return null;
  }

  // ── marker grammar ──────────────────────────────────────────────
  // Same shape as the LUMEN_TOOL marker so the parser can be a
  // single-pass switch. The arg slot carries `<kind>` and the detail
  // is percent-encoded into the second slot so it can contain `|`,
  // `-->`, newlines, etc. without breaking field parsing.

  /// Build the chat marker that the panel parses into a card.
  static String marker(ProviderError err) {
    final encoded = Uri.encodeComponent(err.rawDetail);
    return '\n<!-- LUMEN_ERR:${err.kind.name}|$encoded -->\n';
  }

  /// Marker matcher for the chat segment parser.
  static final RegExp markerRegExp = RegExp(
    r'<!--\s*LUMEN_ERR:([a-z_]+)\|([^|]*)\s*-->',
    multiLine: true,
  );

  static ProviderError? fromMarkerMatch(Match m) {
    final kindName = m.group(1) ?? '';
    final detail = Uri.decodeComponent(m.group(2) ?? '');
    final kind = ProviderErrorKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => ProviderErrorKind.unknown,
    );
    return ProviderError(kind: kind, rawDetail: detail);
  }

  // ── helpers ─────────────────────────────────────────────────────

  /// Recover the friendly text for paste-to-other-app on copy. Same
  /// shape `tool_segments.dart::stripMarkersForCopy` uses for tool
  /// markers — the `<!-- LUMEN_ERR -->` HTML-comment shouldn't leak
  /// into the user's clipboard.
  static String friendlyTextFor(ProviderError err) {
    return '[${err.title}] ${err.rawDetail}';
  }
}

bool _looksLikeErrorPreamble(String s) {
  final lower = s.toLowerCase();
  return lower.startsWith('error:') ||
      lower.startsWith('error ') ||
      lower.contains('api error') ||
      lower.contains('returned ') ||
      lower.contains('error connecting') ||
      lower.contains('error from') ||
      lower.contains('models error') ||
      lower.contains('failed:') ||
      lower.contains('error during generation');
}

int? _extractStatusCode(String s) {
  // Match the FIRST 3-digit code attached to typical preambles. We
  // lean conservative — e.g. `returned 503`, `error (529)`,
  // `status code 502`. Avoids false positives on prose like
  // "in 1995" by requiring an HTTP-status-like context word.
  final m = _statusCodeRe.firstMatch(s);
  if (m == null) return null;
  return int.tryParse(m.group(1) ?? '');
}

final RegExp _statusCodeRe = RegExp(
  r'(?:returned|status\s*code|error\s*\(|API error\s*\(|http[/\s]|code:\s*)\s*(\d{3})\b',
  caseSensitive: false,
);

final RegExp _idleTimeoutRe = RegExp(
  r'_\(generation paused[^_]*?\)_',
  caseSensitive: false,
);

final RegExp _genericErrorPreamble = RegExp(
  r'^Error connecting to|^Error from\b|^Error during generation:',
  caseSensitive: false,
);

final RegExp _genericProviderError = RegExp(
  r'(ollama|gemini|anthropic|claude|github models|openai)\b.*\berror\b',
  caseSensitive: false,
);

const _overloadedPhrases = <String>[
  'overloaded',
  'capacity',
  'try again later',
  'service unavailable',
  'temporarily unavailable',
  '"overloaded"',
];

const _rateLimitPhrases = <String>[
  'rate limit',
  'rate_limit',
  'rate-limit',
  'too many requests',
  'quota exceeded',
  'requests per minute',
];

const _authPhrases = <String>[
  'no anthropic api key',
  'no gemini api key',
  'no github models token',
  'no openai api key',
  'invalid api key',
  'invalid token',
  'authentication failed',
  'unauthorized',
  'permission denied',
  'no access to model',
  'forbidden',
];

const _notFoundPhrases = <String>[
  'model not found',
  'unknown model',
  'unavailable_model',
  'model_not_found',
  'no such model',
];

const _networkPhrases = <String>[
  'socketexception',
  'connection refused',
  'connection reset',
  'connection timed out',
  'network is unreachable',
  'failed host lookup',
  'no address associated with hostname',
  'handshakeexception',
  'clientexception',
];
