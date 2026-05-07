/// Maps verbose model identifiers to short, human-readable labels for
/// compact UI surfaces (council agent cards, status pills, anywhere a
/// 200-px sliver has to fit a model id without ellipsising into "claud…").
///
/// Examples:
///   `claude-opus-4.6`            → `opus 4.6`
///   `claude:claude-opus-4-7`     → `opus 4.7`
///   `copilot:claude-sonnet-4-6`  → `sonnet 4.6`
///   `gpt-5.5`                    → `gpt 5.5`
///   `gpt-4.1`                    → `gpt 4.1`
///   `openai:gpt-4o`              → `gpt 4o`
///   `gemini-2.5-pro`             → `gemini 2.5 pro`
///   `claude:llama3:8b`           → `llama3 8b`        (provider stripped)
///   `llama3:8b`                  → `llama3:8b`        (no provider — kept whole)
///   ``                           → `—`
///
/// Why a free function (not a widget): every consumer wraps the label
/// in its own chrome (chip, tooltip, pill) with different colour and
/// size constraints. Forcing a `CompactModelLabel` widget would either
/// duplicate that chrome or accept ten styling parameters; a pure
/// `String → String` mapper keeps the call sites trivial.
library;

const Set<String> _knownProviders = {
  'anthropic',
  'azure',
  'claude',
  'cohere',
  'copilot',
  'deepseek',
  'gemini',
  'google',
  'groq',
  'mistral',
  'ollama',
  'openai',
  'openrouter',
  'together',
  'xai',
};

const List<String> _claudeFamilies = ['opus', 'sonnet', 'haiku'];

String compactModelLabel(String fullId) {
  final trimmed = fullId.trim();
  if (trimmed.isEmpty) return '—';

  // Strip a leading provider prefix, but ONLY if the token before the
  // first colon is in the known-providers set. Otherwise keep the
  // whole id intact so Ollama tags like `llama3:8b` aren't mauled.
  String id = trimmed;
  final colon = id.indexOf(':');
  if (colon > 0) {
    final prefix = id.substring(0, colon).toLowerCase();
    if (_knownProviders.contains(prefix)) {
      id = id.substring(colon + 1);
    }
  }
  if (id.isEmpty) return trimmed;

  final lower = id.toLowerCase();

  // Anthropic: pull the family + the first numeric version chunk.
  for (final fam in _claudeFamilies) {
    final idx = lower.indexOf(fam);
    if (idx >= 0) {
      final tail = id.substring(idx + fam.length);
      final ver = _firstVersionToken(tail);
      return ver.isEmpty ? fam : '$fam $ver';
    }
  }

  // OpenAI gpt-* family.
  if (lower.startsWith('gpt')) {
    final tail = id.substring(3);
    final ver = _firstVersionToken(tail);
    return ver.isEmpty ? 'gpt' : 'gpt $ver';
  }

  // Gemini family — keep the trailing qualifier (pro / flash / nano)
  // because Gemini ids only differentiate variants by that suffix.
  if (lower.startsWith('gemini')) {
    final tail = id.substring(6);
    final ver = _firstVersionToken(tail);
    final qual = _trailingQualifier(tail);
    final base = ver.isEmpty ? 'gemini' : 'gemini $ver';
    return qual.isEmpty ? base : '$base $qual';
  }

  // Fallback: replace dashes with spaces so unknown vendors still look
  // tidier than `mixtral-8x7b-instruct-v0.1`.
  if (id.length <= 18) return id;
  // Last-resort truncate so we never blow the chip width.
  return '${id.substring(0, 17)}…';
}

/// Pull the first contiguous version-like token from [tail]. Treats
/// `-`, `.`, `_` as version separators. Output uses `.` as the
/// separator so `claude-opus-4-6` and `claude-opus-4.6` collapse to
/// the same `4.6` label.
String _firstVersionToken(String tail) {
  final m = RegExp(
    r'(\d+(?:[.\-_]\d+)*[a-z]?)',
    caseSensitive: false,
  ).firstMatch(tail);
  if (m == null) return '';
  return m.group(1)!.replaceAll(RegExp(r'[\-_]'), '.');
}

/// Pull a trailing alphanumeric qualifier like `pro`, `flash`, `mini`,
/// `nano`, `o`, `turbo` if present. Used for Gemini variants where
/// the suffix carries semantic weight.
String _trailingQualifier(String tail) {
  final m = RegExp(
    r'[\-_]([a-z]{2,8})\s*$',
    caseSensitive: false,
  ).firstMatch(tail);
  if (m == null) return '';
  final word = m.group(1)!.toLowerCase();
  const allow = {'pro', 'flash', 'mini', 'nano', 'turbo', 'lite', 'air'};
  return allow.contains(word) ? word : '';
}
