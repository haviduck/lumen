/// Stream pre-processor that sits between dartssh2 and the xterm
/// `Terminal` widget for an SSH session. Two jobs:
///
/// 1. **Cwd capture (OSC 7).** Many shells emit
///    `ESC ] 7 ; file://<host>/<absolute-path> BEL`
///    on every prompt when their `PROMPT_COMMAND` (bash) /
///    `precmd` (zsh) / fish-side equivalent is configured to do so.
///    This is the "tell the terminal where the shell is currently
///    living" convention — see VS Code's terminal, GNOME Terminal,
///    Konsole, iTerm2, Windows Terminal. The pre-processor catches
///    those and exposes the current cwd so the upload dialog and
///    the "drop file here = upload" flow can default to the user's
///    actual shell directory instead of `$HOME`. Users whose shell
///    isn't configured for OSC 7 fall back to the legacy "$HOME
///    probe" behaviour transparently.
///
/// 2. **`lumen-edit` hijack (OSC 1337 + custom payload).** When the
///    user runs the bundled `lumen-edit` shell helper, it emits
///    `ESC ] 1337 ; LumenEdit=<absolute-path> BEL` (iTerm2-style
///    namespace, custom payload key). The pre-processor strips the
///    sequence so the terminal never renders it, and fires
///    [LumenEditHandler] with the path so [SshController] can route
///    it to the remote-mirror open path. The user gets `lumen-edit
///    foo.txt` → file pops up in the editor magic.
///
/// Both sequences are stripped from the byte stream before xterm
/// sees them. xterm 4.x's `EscapeParser` does silently drop
/// unknown OSC sequences in practice, but we strip anyway so a
/// future xterm version that decides to render unknown OSCs as
/// printable garbage doesn't leak our control bytes into the user's
/// terminal output.
///
/// Sequence-spanning chunk safety: dartssh2's stdout/stderr streams
/// emit byte chunks of arbitrary size and a single OSC sequence can
/// straddle a chunk boundary. The pre-processor keeps a small
/// carry-over buffer per stream (separate for stdout and stderr) so
/// `ESC ] 7 ; file://…` split mid-payload still gets reassembled.
/// We never carry over more than [_maxCarry] bytes — if a sequence
/// runs that long without a terminator we treat it as malformed
/// and flush the buffer to the terminal so the user can see what
/// the shell sent.
library;

import 'dart:convert';

/// Called whenever an OSC 7 cwd report is parsed out of the stream.
/// `cwd` is the URL-decoded absolute path (no `file://` prefix, no
/// hostname segment).
typedef SshCwdHandler = void Function(String cwd);

/// Called whenever a `lumen-edit` OSC payload is parsed.
typedef LumenEditHandler = void Function(String absolutePath);

/// Called whenever a `lumen-grab` OSC payload is parsed. Counterpart
/// to [LumenEditHandler]: where `lumen-edit` opens a remote file in
/// the editor, `lumen-grab` downloads it into the open workspace.
typedef LumenGrabHandler = void Function(String absolutePath);

/// Keeps state for a single SSH session's pre-processing. One
/// instance per [SshSessionEntry]; not reusable across sessions.
class SshTerminalPreProcessor {
  final SshCwdHandler? onCwd;
  final LumenEditHandler? onLumenEdit;
  final LumenGrabHandler? onLumenGrab;

  /// Carry-over buffers for stdout and stderr. Held as [String]s
  /// because the surrounding code already decodes UTF-8 before we
  /// see the bytes — operating on Dart code units (==UTF-16 here,
  /// post-decode) keeps the regex below simple. Carry-over only
  /// triggers when a partial sequence is suspected at the tail of
  /// a chunk; otherwise we pass the chunk through untouched.
  String _carryStdout = '';
  String _carryStderr = '';

  /// Hard cap on carry-over to defend against pathological input
  /// (e.g. a remote process emitting an infinite OSC opener and
  /// never terminating). 4 KiB is plenty for any sane cwd or path.
  static const int _maxCarry = 4096;

  SshTerminalPreProcessor({this.onCwd, this.onLumenEdit, this.onLumenGrab});

  /// Process a chunk from `SSHSession.stdout`. Returns the cleaned
  /// chunk to forward to `Terminal.write`.
  String processStdout(String chunk) => _process(chunk, _CarryStream.stdout);

  /// Process a chunk from `SSHSession.stderr`. Same handling as
  /// stdout — kept as a separate channel only because the carry-over
  /// buffer must NOT interleave with stdout (otherwise a partial
  /// sequence on one stream could swallow an unrelated prefix on
  /// the other).
  String processStderr(String chunk) => _process(chunk, _CarryStream.stderr);

  String _process(String chunk, _CarryStream stream) {
    final carryGet = stream == _CarryStream.stdout
        ? () => _carryStdout
        : () => _carryStderr;
    final carrySet = stream == _CarryStream.stdout
        ? (String v) => _carryStdout = v
        : (String v) => _carryStderr = v;

    var working = carryGet() + chunk;
    carrySet('');

    // Walk through and pull out any complete sequences. We rebuild
    // the cleaned output by appending the bytes between matches.
    final out = StringBuffer();
    var cursor = 0;
    while (cursor < working.length) {
      final escIdx = working.indexOf('\u001b]', cursor);
      if (escIdx < 0) {
        // No more potential sequences in this segment.
        out.write(working.substring(cursor));
        cursor = working.length;
        break;
      }
      // Append everything up to the ESC.
      out.write(working.substring(cursor, escIdx));
      // Look for the terminator: BEL (0x07) or ST (ESC \\).
      final belIdx = working.indexOf('\u0007', escIdx);
      final stIdx = working.indexOf('\u001b\\', escIdx);
      // Pick the earliest valid terminator, skipping the ESC at escIdx.
      int? termEnd;
      // Both terminators must be AFTER the opener, not at it.
      if (belIdx > escIdx && (stIdx < 0 || belIdx < stIdx)) {
        termEnd = belIdx + 1;
      } else if (stIdx > escIdx) {
        termEnd = stIdx + 2;
      }
      if (termEnd == null) {
        // Sequence is incomplete. Stash from `escIdx` onwards as the
        // next chunk's carry-over; emit nothing further for now.
        final remainder = working.substring(escIdx);
        if (remainder.length <= _maxCarry) {
          carrySet(remainder);
          cursor = working.length;
          break;
        }
        // Pathologically long unterminated sequence — flush as-is
        // so the user sees what the remote sent. Don't carry.
        out.write(remainder);
        cursor = working.length;
        break;
      }
      // We have a complete OSC sequence: working[escIdx..termEnd].
      final fullSequence = working.substring(escIdx, termEnd);
      final consumed = _maybeHandle(fullSequence);
      if (!consumed) {
        // Unknown / non-magic OSC — pass through to xterm intact.
        out.write(fullSequence);
      }
      cursor = termEnd;
    }
    return out.toString();
  }

  /// Returns true when the sequence is one of the magic ones we
  /// strip; false otherwise (so the caller forwards it untouched).
  bool _maybeHandle(String fullSequence) {
    // Strip the leading `ESC ]` + the trailing terminator (BEL or
    // ESC \\), leaving the payload only.
    var payload = fullSequence;
    if (payload.startsWith('\u001b]')) {
      payload = payload.substring(2);
    }
    if (payload.endsWith('\u0007')) {
      payload = payload.substring(0, payload.length - 1);
    } else if (payload.endsWith('\u001b\\')) {
      payload = payload.substring(0, payload.length - 2);
    }
    // OSC 7 — `7;file://hostname/path`
    if (payload.startsWith('7;')) {
      final body = payload.substring(2);
      final fileUrl = body.startsWith('file://') ? body.substring(7) : body;
      // Strip the optional `<hostname>` between the `//` and the
      // first `/`. If there's no leading slash we can't be sure it's
      // a usable absolute path — bail rather than guess.
      final firstSlash = fileUrl.indexOf('/');
      if (firstSlash < 0) return true; // malformed; drop
      final encodedPath = fileUrl.substring(firstSlash);
      try {
        final decoded = Uri.decodeFull(encodedPath);
        onCwd?.call(decoded);
      } catch (_) {
        // Bad percent-encoding from the shell — drop silently.
      }
      return true;
    }
    // OSC 1337 — iTerm2 namespace. Multiple keys ride in this
    // namespace (`SetMark`, `CursorShape`, …); we only act on the
    // `LumenEdit=` / `LumenGrab=` payloads we ourselves emit from
    // the bundled shell helpers. Anything else passes back through
    // to xterm. xterm 4.x doesn't render OSC 1337 either, so the
    // pass-through is effectively a "drop on the floor" — but
    // staying conservative keeps the door open for a future xterm
    // release that DOES handle some.
    if (payload.startsWith('1337;')) {
      final body = payload.substring(5);
      const editKey = 'LumenEdit=';
      const grabKey = 'LumenGrab=';
      if (body.startsWith(editKey)) {
        final path = body.substring(editKey.length);
        if (path.isNotEmpty) {
          onLumenEdit?.call(path);
        }
        return true;
      }
      if (body.startsWith(grabKey)) {
        final path = body.substring(grabKey.length);
        if (path.isNotEmpty) {
          onLumenGrab?.call(path);
        }
        return true;
      }
      return false;
    }
    return false;
  }

  /// Reset both carry-over buffers. Called when the underlying
  /// session is torn down so a new session reusing the same
  /// pre-processor (in tests) doesn't inherit stale state.
  void reset() {
    _carryStdout = '';
    _carryStderr = '';
  }
}

enum _CarryStream { stdout, stderr }

/// Convenience: produces the bytes for the `lumen-edit` shell helper
/// installation snippet. Kept here so the helper-install dialog and
/// any future `--print-helper` CLI mode share a single source. The
/// snippet is shell-portable across bash/zsh; fish users would need
/// a function-syntax variant which we don't ship today.
String lumenEditShellSnippet() {
  return [
    '# Lumen IDE — open a remote file in your local Lumen editor.',
    '# Save in editor → SFTP-uploaded back to this host. Add this to',
    '# ~/.bashrc / ~/.zshrc to make `lumen-edit <file>` available in',
    '# every shell, OR paste once for the current session only.',
    'lumen-edit() {',
    '  if [ -z "\$1" ]; then',
    '    echo "usage: lumen-edit <file>" >&2',
    '    return 1',
    '  fi',
    '  local target',
    '  target=\$(realpath "\$1" 2>/dev/null || readlink -f "\$1" 2>/dev/null || echo "\$1")',
    '  case "\$target" in',
    '    /*) ;;',
    '    *)  target="\$PWD/\$target" ;;',
    '  esac',
    '  printf "\\033]1337;LumenEdit=%s\\a" "\$target"',
    '}',
  ].join('\n');
}

/// Counterpart to [lumenEditShellSnippet]: defines `lumen-grab <file>`
/// which prints an OSC 1337 `LumenGrab=` payload. Lumen's pre-processor
/// catches it and downloads the remote file into the open workspace
/// (with a Replace / Keep both / Cancel prompt on filename collision).
/// Same bash/zsh portability footnote as [lumenEditShellSnippet].
String lumenGrabShellSnippet() {
  return [
    '# Lumen IDE — download a remote file into the open Lumen workspace.',
    "# Use for the inverse of `lumen-edit`: when you've produced something",
    "# remotely (build artefact, generated file, log) and want it pulled",
    "# down into your project so you can commit / archive / inspect it.",
    'lumen-grab() {',
    '  if [ -z "\$1" ]; then',
    '    echo "usage: lumen-grab <file>" >&2',
    '    return 1',
    '  fi',
    '  local target',
    '  target=\$(realpath "\$1" 2>/dev/null || readlink -f "\$1" 2>/dev/null || echo "\$1")',
    '  case "\$target" in',
    '    /*) ;;',
    '    *)  target="\$PWD/\$target" ;;',
    '  esac',
    '  printf "\\033]1337;LumenGrab=%s\\a" "\$target"',
    '}',
  ].join('\n');
}

/// PROMPT_COMMAND snippet for users who want OSC 7 cwd reporting
/// (so the upload dialog auto-fills the dir they're `cd`'d into).
/// Wrapped in a function so re-running the snippet is idempotent.
/// Same bash/zsh portability footnote as [lumenEditShellSnippet].
String osc7PromptSnippet() {
  return [
    '# Lumen IDE — report cwd to the host terminal on every prompt.',
    '# Without this, dropping files into the SSH pane uploads to',
    "# \$HOME by default. With this, drops go to wherever you're",
    "# currently `cd`'d.",
    '_lumen_osc7() { printf "\\033]7;file://%s%s\\a" "\$HOSTNAME" "\$PWD"; }',
    '# bash:',
    'PROMPT_COMMAND="_lumen_osc7;\$PROMPT_COMMAND"',
    '# zsh: add `_lumen_osc7` to your `precmd_functions` array instead.',
  ].join('\n');
}

/// Renders all shipped helpers as a single block for the "Copy all"
/// button in the helpers dialog. Order matches the dialog's visual
/// order so a paste into `~/.bashrc` produces the same layout.
String allShellHelpers() {
  return [
    lumenEditShellSnippet(),
    '',
    lumenGrabShellSnippet(),
    '',
    osc7PromptSnippet(),
  ].join('\n');
}

/// Rendered as bytes for piping into a shell session as input
/// (e.g. an "Install for this session" button that types the helper
/// into the active terminal). UTF-8.
List<int> shellHelperBytes() => utf8.encode('${allShellHelpers()}\n');
