// Smoke helper for the Remote Access pairing flow. Use it on Windows
// before an Android client exists, or any time you want to drive the
// REST + WS surface from a fresh device-identity.
//
// Usage from project root:
//
//   # 1. In Lumen, Settings → Remote Access → "Show pairing code".
//   # 2. Run with the displayed code:
//   dart run tool/remote_pair.dart <host> <port> <code> [deviceName]
//
// Example:
//   dart run tool/remote_pair.dart 100.93.12.4 7891 482910 "Test box"
//
// On success the script:
//   1. POSTs `/v1/pair/initiate` with the code.
//   2. Persists the bearer token at `tool/.lumen_remote_token` so
//      follow-up runs (or any tool you write) can read it.
//   3. Calls `GET /v1/health`, `GET /v1/projects`, and
//      `GET /v1/pair/devices` with the bearer to prove the auth
//      pipeline works end-to-end.
//   4. Opens a `/v1/stream` WebSocket with `?token=` so you see
//      events flow live; Ctrl-C exits cleanly.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:web_socket_channel/io.dart';

const _tokenFile = 'tool/.lumen_remote_token';

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'Usage: dart run tool/remote_pair.dart <host> <port> <code> [deviceName]',
    );
    exit(64);
  }
  final host = args[0];
  final port = int.tryParse(args[1]) ?? 0;
  final code = args[2];
  final deviceName = args.length > 3 ? args[3] : 'Pairing smoke';

  if (port <= 0 || port > 65535) {
    stderr.writeln('Invalid port: ${args[1]}');
    exit(64);
  }

  final base = 'http://$host:$port';
  final client = HttpClient();

  String token;
  try {
    final pairResp = await _post(client, '$base/v1/pair/initiate', {
      'code': code,
      'deviceName': deviceName,
    });
    if (pairResp.statusCode != 200) {
      stderr.writeln('Pair failed: HTTP ${pairResp.statusCode}');
      stderr.writeln(pairResp.body);
      exit(1);
    }
    final body = jsonDecode(pairResp.body) as Map<String, dynamic>;
    token = body['token'] as String;
    stdout.writeln('Paired ✓');
    stdout.writeln('  device id   : ${body['device']?['id']}');
    stdout.writeln('  instance    : ${body['instanceName']} '
        '(${body['instanceId']})');
    stdout.writeln('  token (head): ${token.substring(0, 12)}…');
    await File(_tokenFile).writeAsString(token);
    stdout.writeln('  token saved : $_tokenFile');
  } catch (e) {
    stderr.writeln('Pair request failed: $e');
    exit(1);
  }

  // ── Smoke the auth pipeline with a couple of authed reads ──
  for (final probe in ['/v1/health', '/v1/projects', '/v1/pair/devices']) {
    final resp = await _get(client, '$base$probe', token);
    final preview = resp.body.length > 200
        ? '${resp.body.substring(0, 200)}…'
        : resp.body;
    stdout.writeln('GET $probe → ${resp.statusCode} $preview');
  }

  // ── Sanity check: hit a privileged route WITHOUT the token ──
  final unauth = await _get(client, '$base/v1/projects', null);
  stdout.writeln('GET /v1/projects (no token) → ${unauth.statusCode} '
      '${unauth.body}');

  client.close();

  // ── Tail the stream with the token via query param ──
  // Native clients can attach `Authorization` on the WS upgrade
  // (we'd use `IOWebSocketChannel.connect(uri, headers: ...)`) but
  // the `?token=` fallback is exactly what a browser-style client
  // would do, so exercise it here.
  final wsUri =
      Uri.parse('ws://$host:$port/v1/stream?token=${Uri.encodeQueryComponent(token)}');
  stdout.writeln('Tailing $wsUri (Ctrl-C to exit)…');
  final ch = IOWebSocketChannel.connect(wsUri);
  ProcessSignal.sigint.watch().listen((_) {
    stdout.writeln('\nClosing socket…');
    ch.sink.close();
    exit(0);
  });
  final encoder = const JsonEncoder.withIndent('  ');
  await for (final raw in ch.stream) {
    if (raw is! String) {
      stdout.writeln('<binary frame> (${raw.runtimeType})');
      continue;
    }
    try {
      stdout.writeln('--- ${DateTime.now().toIso8601String()} ---');
      stdout.writeln(encoder.convert(jsonDecode(raw)));
    } catch (_) {
      stdout.writeln('!! non-json frame: $raw');
    }
  }
}

class _Resp {
  _Resp(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

Future<_Resp> _post(
  HttpClient client,
  String url,
  Map<String, dynamic> body,
) async {
  final req = await client.postUrl(Uri.parse(url));
  req.headers.contentType = ContentType.json;
  req.write(jsonEncode(body));
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  return _Resp(resp.statusCode, text);
}

Future<_Resp> _get(HttpClient client, String url, String? token) async {
  final req = await client.getUrl(Uri.parse(url));
  if (token != null) {
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
  }
  final resp = await req.close();
  final text = await resp.transform(utf8.decoder).join();
  return _Resp(resp.statusCode, text);
}
