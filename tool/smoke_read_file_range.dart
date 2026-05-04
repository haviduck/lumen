// Standalone smoke test for the streaming range-read path in
// `tool_registry.dart`. Run with:
//
//     dart tool/smoke_read_file_range.dart
//
// Creates a synthetic ~1.5M-line text file (~25 MiB) far past the
// full-read 5 MiB ceiling, then exercises a handful of range-read
// shapes the agent realistically issues. Asserts the returned
// payload matches expectations — useful as a regression guard if
// `_streamReadRange` ever gets refactored.
//
// Lives in `tool/` rather than `test/` because Lumen has no
// `_test.dart` files yet; this is a one-shot dev sanity check, not
// part of a CI suite.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const int _kReadMaxLines = 2000;
const int _kLineNoPad = 6;
const int _kReadMaxBytes = 200 * 1024;

// Replica of `_streamReadRange` in tool_registry.dart. Kept in sync
// by hand because the production code is a private static. If you
// change one, change both.
Future<String> _streamReadRange({
  required String filePath,
  required String fileName,
  required int start,
  required int end,
  required int fileBytes,
}) async {
  const int rangeFileCeilingBytes = 500 * 1024 * 1024;
  if (fileBytes > rangeFileCeilingBytes) {
    final mib = (fileBytes / (1024 * 1024)).toStringAsFixed(1);
    return 'READ_FILE $fileName: Error: file is $mib MiB '
        '(range-read ceiling 500 MiB).';
  }

  final wantSize = end - start + 1;
  final emitMax = wantSize > _kReadMaxLines ? _kReadMaxLines : wantSize;
  final emitEndLine = start + emitMax - 1;

  final buf = StringBuffer();
  var byteBudget = _kReadMaxBytes;
  var lineNo = 0;
  var emitted = 0;
  var byteCapHit = false;

  try {
    final stream = File(filePath)
        .openRead()
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in stream) {
      lineNo++;
      if (lineNo < start) continue;
      if (lineNo > emitEndLine) break;
      final cost = line.length + _kLineNoPad + 2;
      if (cost > byteBudget) {
        byteCapHit = true;
        break;
      }
      byteBudget -= cost;
      buf
        ..write(lineNo.toString().padLeft(_kLineNoPad))
        ..write('|')
        ..writeln(line);
      emitted++;
    }
  } on FormatException {
    return 'READ_FILE $fileName: Error: file is not valid UTF-8.';
  }

  if (emitted == 0) {
    if (byteCapHit) {
      return 'READ_FILE $fileName: Error: line $start exceeds the '
          '${_kReadMaxBytes ~/ 1024} KiB display cap.';
    }
    return 'READ_FILE $fileName: Empty range (file has $lineNo lines).';
  }

  var body = buf.toString();
  if (body.endsWith('\n')) body = body.substring(0, body.length - 1);
  final lastEmittedLine = start + emitted - 1;
  final hitCap =
      byteCapHit || (emitted >= emitMax && lastEmittedLine < end);
  if (hitCap) {
    final reason = byteCapHit
        ? 'byte cap (${_kReadMaxBytes ~/ 1024} KiB)'
        : 'line cap ($_kReadMaxLines)';
    return 'READ_FILE $fileName lines $start-$lastEmittedLine '
        '(requested $start-$end, capped at $reason):\n'
        '$body\n... (continue with '
        '`<<<READ_FILE: $fileName:${lastEmittedLine + 1}-$end>>>`)';
  }
  return 'READ_FILE $fileName lines $start-$lastEmittedLine:\n$body';
}

Future<File> _writeBigFile(int lines) async {
  final dir = Directory.systemTemp.createTempSync('lumen_read_smoke');
  final f = File('${dir.path}/big.txt');
  final sink = f.openWrite();
  for (var i = 1; i <= lines; i++) {
    sink.writeln('line $i: '
        'lorem ipsum dolor sit amet consectetur adipiscing elit '
        'sed do eiusmod tempor incididunt ut labore et dolore magna');
  }
  await sink.flush();
  await sink.close();
  return f;
}

void _check(bool ok, String msg) {
  stdout.writeln('${ok ? 'OK' : 'FAIL'}  $msg');
  if (!ok) exitCode = 1;
}

Future<void> main() async {
  stdout.writeln('Building synthetic 1.5M-line file...');
  final f = await _writeBigFile(1500000);
  final fileBytes = await f.length();
  stdout.writeln(
    'File: ${f.path}  (${(fileBytes / (1024 * 1024)).toStringAsFixed(1)} MiB)',
  );
  stdout.writeln('Above the full-read ceiling (5 MiB), so range-only.\n');

  // 1. Tight range deep in the file.
  var t0 = DateTime.now();
  var out = await _streamReadRange(
    filePath: f.path,
    fileName: 'big.txt',
    start: 1_234_567,
    end: 1_234_572,
    fileBytes: fileBytes,
  );
  var ms = DateTime.now().difference(t0).inMilliseconds;
  _check(
    out.contains('lines 1234567-1234572:') && out.contains('|line 1234567:'),
    'tight range :1234567-1234572 (deep)  [${ms}ms]',
  );

  // 2. Range overshoots the line cap.
  t0 = DateTime.now();
  out = await _streamReadRange(
    filePath: f.path,
    fileName: 'big.txt',
    start: 1,
    end: 9999999,
    fileBytes: fileBytes,
  );
  ms = DateTime.now().difference(t0).inMilliseconds;
  // Line cap is 2000, but the byte cap (200 KiB) trips first on
  // these long lorem ipsum lines (~120 chars × 200 KiB / 130 ≈ 1614
  // emitted lines). Either cap is acceptable; the footer should
  // surface ONE of them.
  final hitsByteCap = out.contains('byte cap');
  final hitsLineCap = out.contains('line cap');
  _check(
    out.contains('capped at') && (hitsByteCap || hitsLineCap),
    'overshoot :1-9999999 trips a cap (${hitsByteCap ? "byte" : "line"})  [${ms}ms]',
  );

  // 3. Range past EOF.
  t0 = DateTime.now();
  out = await _streamReadRange(
    filePath: f.path,
    fileName: 'big.txt',
    start: 9000000,
    end: 9000050,
    fileBytes: fileBytes,
  );
  ms = DateTime.now().difference(t0).inMilliseconds;
  _check(
    out.contains('Empty range') && out.contains('1500000 lines'),
    'past-EOF :9M-9M+50 emits empty + correct total  [${ms}ms]',
  );

  // 4. Single line at the start.
  t0 = DateTime.now();
  out = await _streamReadRange(
    filePath: f.path,
    fileName: 'big.txt',
    start: 1,
    end: 1,
    fileBytes: fileBytes,
  );
  ms = DateTime.now().difference(t0).inMilliseconds;
  _check(
    out.contains('lines 1-1:') && out.contains('     1|line 1:'),
    'single-line :1-1 (head)  [${ms}ms]',
  );

  await f.parent.delete(recursive: true);
  stdout.writeln('\nAll smoke-test cases ran. exitCode=$exitCode');
}
