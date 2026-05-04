// Tail the /v1/stream WebSocket feed exposed by the Remote Access
// server. Useful for development / smoke testing while the Android
// client and pairing layer don't exist yet.
//
// Run from the project root:
//
//   dart run tool/remote_stream_tail.dart [port] [host]
//
// Defaults: port=7891, host=127.0.0.1.
//
// **Auth:** the server requires a bearer token on every non-public
// route, including `/v1/stream`. This script reads the token saved
// at `tool/.lumen_remote_token` (written by `tool/remote_pair.dart`
// on a successful pair) and forwards it via the `?token=` query
// fallback. If the file isn't present the script falls through and
// you'll get a 401 — pair first.
//
// Each frame is decoded back to a Map<String, dynamic> and re-printed
// indented, so multi-line content (e.g. `message_delta` carrying a
// growing assistant response) is readable in the terminal.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

const _tokenFile = 'tool/.lumen_remote_token';

Future<void> main(List<String> args) async {
  final port = args.isNotEmpty ? args.first : '7891';
  final host = args.length > 1 ? args[1] : '127.0.0.1';

  String? token;
  try {
    final f = File(_tokenFile);
    if (await f.exists()) {
      token = (await f.readAsString()).trim();
      if (token.isEmpty) token = null;
    }
  } catch (_) {
    // Non-fatal: a missing/unreadable token file just means the
    // tail will 401. Surface that as a normal stream error so the
    // operator knows what to fix (run remote_pair.dart first).
  }

  final tokenSegment =
      token == null ? '' : '?token=${Uri.encodeQueryComponent(token)}';
  final uri = Uri.parse('ws://$host:$port/v1/stream$tokenSegment');
  if (token == null) {
    stderr.writeln(
      'WARNING: no token at $_tokenFile — server will reject this '
      'connection with 401. Run tool/remote_pair.dart first.',
    );
  }
  stdout.writeln('Connecting to ws://$host:$port/v1/stream ...');

  IOWebSocketChannel? channel;
  try {
    channel = IOWebSocketChannel.connect(uri);
  } catch (e) {
    stderr.writeln('Failed to open socket: $e');
    exit(1);
  }

  // Ctrl-C cleanly closes the socket so the desktop can drop the
  // client from its set without waiting for a TCP timeout.
  ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\nClosing socket...');
    channel?.sink.close();
    exit(0);
  });

  final encoder = const JsonEncoder.withIndent('  ');
  await for (final raw in channel.stream) {
    if (raw is! String) {
      stdout.writeln('<binary frame> (${raw.runtimeType})');
      continue;
    }
    try {
      final decoded = jsonDecode(raw);
      stdout.writeln('--- ${DateTime.now().toIso8601String()} ---');
      stdout.writeln(encoder.convert(decoded));
    } catch (_) {
      // Malformed JSON should never come from us, but don't crash
      // the tail if it does.
      stdout.writeln('!! non-json frame: $raw');
    }
  }
  stdout.writeln('Stream ended.');
}
