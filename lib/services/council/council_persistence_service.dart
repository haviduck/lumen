import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'council_models.dart';

class CouncilPersistenceService {
  Directory? _root;

  Future<Directory> _ensureRoot() async {
    if (_root != null) return _root!;
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'chat_sessions', 'councils'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _root = dir;
    return dir;
  }

  Future<void> saveSession(CouncilSession session) async {
    final root = await _ensureRoot();
    final file = File(p.join(root.path, '${session.config.id}.json'));
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(session.toJson()),
    );
  }

  Future<CouncilSession?> loadSession(String id) async {
    final root = await _ensureRoot();
    final file = File(p.join(root.path, '$id.json'));
    if (!await file.exists()) return null;
    final raw = await file.readAsString();
    return CouncilSession.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<String> writeReport({
    required String workspacePath,
    required CouncilSession session,
    required String markdown,
  }) async {
    final dir = Directory(p.join(workspacePath, '.lumen', 'council'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stamp = _stamp(DateTime.now());
    final slug = _slug(
      session.config.title.isEmpty
          ? session.config.brief
          : session.config.title,
    );
    final path = p.join(dir.path, '$stamp-$slug.md');
    final file = File(path);
    await file.writeAsString(markdown);
    return path;
  }

  static String _stamp(DateTime dt) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)}-'
        '${two(dt.hour)}${two(dt.minute)}';
  }

  static String _slug(String input) {
    final lowered = input.toLowerCase();
    final cleaned = lowered
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    if (cleaned.isEmpty) return 'council-report';
    return cleaned.length <= 48 ? cleaned : cleaned.substring(0, 48);
  }
}
