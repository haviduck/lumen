// Regression tests for ToolExecutor.looksLikeFailure.
//
// Bug history (two rounds):
//
// Round 1: substring-matched the ENTIRE result for `Error:` / `Failed` /
// `Denied`. Reading any source file whose body contained those strings
// (an error handler, a log, a test fixture, the executor itself) flagged
// the read as a failure. Model received `[FAILED] <file content>` + an
// "action required" nudge, retried the same successful read in a tight
// loop, and hit the 25-iteration agent budget.
//
// Round 1 fix: check first line only (file content starts on line 2+).
//
// Round 2: first-line-only still false-positived because the first line
// embeds the FILE PATH. Filenames like `FailedLoginHandler.dart`,
// `ErrorBoundary.dart`, or `AccessDeniedPage.dart` contain the bare
// keywords. The model entered the same retry loop as round 1.
//
// Round 2 fix: match the STRUCTURAL error pattern `': Error'` /
// `': Failed'` / `': Denied'` — the colon-space before the keyword is
// always present on real failures (`TOOL <path>: Error: <msg>`) and
// never appears inside a filename.
//
// These tests pin both invariants:
//   1. Successful reads of files with keyword-containing BODIES → pass.
//   2. Successful reads of files with keyword-containing NAMES → pass.
//   3. Real header-line failures → flagged.
//   4. Single-line successes (Move/Copy/Delete) → pass.
//   5. Multi-line successes with keywords in body → pass.
//
// Run: `flutter test test/services/tool_executor_failure_detection_test.dart`

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/tool_executor.dart';

void main() {
  group('ToolExecutor.looksLikeFailure — successes that must NOT be flagged',
      () {
    test('READ_FILE of a file whose body contains "Error:" is success', () {
      const result = '''READ_FILE error_handler.dart lines 1-12:
     1|class ErrorHandler {
     2|  void handle(Exception e) {
     3|    // Log every Error: message we get back from the API.
     4|    print('Error: \$e');
     5|  }
     6|}''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse,
          reason: 'Body containing "Error:" must not flip the badge to failed');
    });

    test('READ_FILE of a file whose body contains "Failed" is success', () {
      const result = '''READ_FILE auth_service.dart lines 1-8:
     1|class AuthResult {
     2|  /// Failed login attempts in the last 5 minutes.
     3|  final int failedAttempts;
     4|}''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse);
    });

    test('READ_FILE of a file whose body contains "Denied" is success', () {
      const result = '''READ_FILE acl_check.dart lines 1-4:
     1|enum AccessOutcome { Allowed, Denied, Pending }''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse);
    });

    // ── Round 2 regression: keywords IN THE FILENAME ──
    test('READ_FILE of file named FailedLoginHandler.dart is success', () {
      const result = 'READ_FILE FailedLoginHandler.dart (42 lines):\n'
          '     1|class FailedLoginHandler {}';
      expect(ToolExecutor.looksLikeFailure(result), isFalse,
          reason: '"Failed" in filename must not trigger failure detection');
    });

    test('READ_FILE of file named ErrorBoundary.dart is success', () {
      const result = 'READ_FILE ErrorBoundary.dart (18 lines):\n'
          '     1|class ErrorBoundary extends StatelessWidget {}';
      expect(ToolExecutor.looksLikeFailure(result), isFalse,
          reason: '"Error" in filename must not trigger failure detection');
    });

    test('READ_FILE of file named AccessDeniedPage.dart is success', () {
      const result = 'READ_FILE AccessDeniedPage.dart (30 lines):\n'
          '     1|class AccessDeniedPage extends StatelessWidget {}';
      expect(ToolExecutor.looksLikeFailure(result), isFalse,
          reason: '"Denied" in filename must not trigger failure detection');
    });

    test('READ_FILE of file in a path containing error keywords is success',
        () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE lib/errors/FailedAuth.dart (5 lines):\n'
              '     1|class FailedAuth {}'),
          isFalse);
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE test/denied_access/handler.dart lines 1-10:\n'
              '     1|void main() {}'),
          isFalse);
    });

    test('READ_FILE range of a file with keyword name is success', () {
      const result = 'READ_FILE FailedUploadError.dart lines 10-25:\n'
          '    10|  void retry() {}';
      expect(ToolExecutor.looksLikeFailure(result), isFalse,
          reason: 'Range read of keyword-named file must not be flagged');
    });

    test('READ_FILE empty file is success', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE empty.dart: Empty (0 lines).'),
          isFalse);
    });

    test('LIST_DIR success is not a failure even if a filename contains those '
        'words on lines 2+', () {
      const result = '''LIST_DIR lib/handlers:
error_handler.dart
failed_login_record.dart
permission_denied_dialog.dart''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse);
    });

    test('GIT_DIFF success containing "Error:" / "Failed" in patched lines is '
        'not a failure', () {
      const result = '''GIT_DIFF:
diff --git a/foo.dart b/foo.dart
+    throw Exception('Error: invalid state');
-    return 'Failed';''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse);
    });

    test('RUN_CMD success with STDERR mentioning errors is not a failure '
        '(stderr is body content, not a header)', () {
      const result = '''RUN_CMD ls foo: (12ms)
STDOUT:
foo.dart
STDERR:
ls: warning: Failed to access permissions cache (non-fatal)''';
      expect(ToolExecutor.looksLikeFailure(result), isFalse);
    });

    test('Single-line write successes are not failures', () {
      expect(ToolExecutor.looksLikeFailure('EDIT_FILE foo.dart: Success '
          '(1 replacement made, lines 5-7)'), isFalse);
      expect(ToolExecutor.looksLikeFailure('CREATE_FILE foo.dart: Success '
          '(8 lines)'), isFalse);
      expect(ToolExecutor.looksLikeFailure('MOVE_FILE a -> b: Success'),
          isFalse);
      expect(ToolExecutor.looksLikeFailure('COPY_FILE a -> b: Success'),
          isFalse);
      expect(ToolExecutor.looksLikeFailure('DELETE_FILE foo.dart: '
          'Success (file deleted)'), isFalse);
      expect(ToolExecutor.looksLikeFailure('APPEND_FILE foo.dart: Success '
          '(lines 12-14)'), isFalse);
    });
  });

  group('ToolExecutor.looksLikeFailure — real failures MUST still be flagged',
      () {
    test('READ_FILE missing file', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE nope.dart: Error: file does not exist.'),
          isTrue);
    });

    test('EDIT_FILE SEARCH not found', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'EDIT_FILE foo.dart: Error: SEARCH block not found in body.'),
          isTrue);
    });

    test('CREATE_FILE no workspace', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'CREATE_FILE foo.dart: Failed (no workspace open).'),
          isTrue);
    });

    test('DELETE_FILE denied by user', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'DELETE_FILE foo.dart: Denied by user.'),
          isTrue);
    });

    test('Multi-line failure (Error: header + supporting text)', () {
      const result = '''READ_FILE foo.dart: Error: file is 800 MiB
(range-read ceiling 500 MiB). Use SEARCH_TEXT for content lookup.''';
      expect(ToolExecutor.looksLikeFailure(result), isTrue);
    });

    test('READ_FILE of keyword-named file that actually fails is failure', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE FailedAuth.dart: Error: file does not exist.'),
          isTrue,
          reason: 'Real failure of keyword-named file must still be caught');
    });

    test('READ_FILE binary file is failure', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE image.png: Error: file is not valid UTF-8 '
              '(likely binary). READ_FILE only handles text.'),
          isTrue);
    });

    test('READ_FILE no workspace is failure', () {
      expect(
          ToolExecutor.looksLikeFailure(
              'READ_FILE foo.dart: Failed (no workspace open).'),
          isTrue);
    });
  });
}
