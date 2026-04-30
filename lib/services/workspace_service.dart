import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart';

class WorkspaceService {
  static const String _recentProjectsKey = 'recent_projects';

  /// Load recent projects from SharedPreferences
  Future<List<String>> getRecentProjects() async {
    final prefs = await SharedPreferences.getInstance();
    final List<String>? recent = prefs.getStringList(_recentProjectsKey);
    return recent ?? [];
  }

  /// Add a project path to the top of recent projects
  Future<void> addRecentProject(String path) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> recent = prefs.getStringList(_recentProjectsKey) ?? [];
    
    // Remove if exists to re-insert at the top
    recent.remove(path);
    recent.insert(0, path);

    // Keep only last 10
    if (recent.length > 10) {
      recent = recent.sublist(0, 10);
    }
    
    await prefs.setStringList(_recentProjectsKey, recent);
  }

  /// Remove a project path from recent projects
  Future<void> removeRecentProject(String path) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> recent = prefs.getStringList(_recentProjectsKey) ?? [];
    recent.remove(path);
    await prefs.setStringList(_recentProjectsKey, recent);
  }

  /// Create a new project directory
  Future<String?> createNewProject(String parentDir, String projectName) async {
    try {
      final newDir = Directory('$parentDir${Platform.pathSeparator}$projectName');
      if (!await newDir.exists()) {
        await newDir.create(recursive: true);
        await addRecentProject(newDir.path);
        return newDir.path;
      }
      return null; // Directory already exists
    } catch (e) {
      debugPrint('Error creating project: $e');
      return null;
    }
  }
}
