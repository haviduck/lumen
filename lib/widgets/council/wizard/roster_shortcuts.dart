import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'model_tier.dart';

/// Lightweight controller for the agent roster's model assignments.
/// Owned by whoever stands up the agents-step shell (currently being
/// rebuilt by agent_0); the roster passes one of these to
/// [RosterShortcuts] so keyboard chords and the preset bar can drive
/// every agent without leaking the underlying draft-agent type.
///
/// The controller is intentionally generic over the agent identity:
/// it stores models keyed by an opaque `String` agentId so the wizard
/// shell can keep its own `_DraftAgent` (or whatever replaces it) as
/// the source of truth and bridge through `getModel` / `setModel`.
class CouncilRosterController extends ChangeNotifier {
  CouncilRosterController({
    required List<String> agentIds,
    required List<String> models,
    required String? Function(String agentId) getModel,
    required void Function(String agentId, String model) setModel,
  })  : _agentIds = List<String>.from(agentIds),
        _models = List<String>.from(models),
        _getModel = getModel,
        _setModel = setModel;

  List<String> _agentIds;
  List<String> _models;
  final String? Function(String agentId) _getModel;
  final void Function(String agentId, String model) _setModel;
  String? _focusedAgentId;
  final Map<String, FocusNode> _focusNodes = {};

  List<String> get agentIds => List.unmodifiable(_agentIds);
  List<String> get models => List.unmodifiable(_models);
  String? get focusedAgentId => _focusedAgentId;

  /// Current preset tier if every agent agrees, otherwise null.
  ModelTier? get activeTier =>
      activeTierFor(_agentIds.map((id) => _getModel(id)));

  /// Refresh the underlying agent / model lists. Call when the wizard
  /// adds / removes agents or the available-model list changes.
  void update({List<String>? agentIds, List<String>? models}) {
    var changed = false;
    if (agentIds != null && !_listEquals(agentIds, _agentIds)) {
      _agentIds = List<String>.from(agentIds);
      // Reap orphaned focus nodes.
      final keep = _agentIds.toSet();
      final dropped =
          _focusNodes.keys.where((k) => !keep.contains(k)).toList();
      for (final k in dropped) {
        _focusNodes.remove(k)?.dispose();
      }
      changed = true;
    }
    if (models != null && !_listEquals(models, _models)) {
      _models = List<String>.from(models);
      changed = true;
    }
    if (changed) notifyListeners();
  }

  FocusNode focusNodeFor(String agentId) {
    return _focusNodes.putIfAbsent(agentId, () {
      final node = FocusNode(debugLabel: 'AgentModelChip:$agentId');
      node.addListener(() {
        if (node.hasFocus) {
          _focusedAgentId = agentId;
        } else if (_focusedAgentId == agentId) {
          _focusedAgentId = null;
        }
      });
      return node;
    });
  }

  /// Apply a tier to every agent in the roster.
  void applyPreset(ModelTier tier) {
    final m = pickModelForTier(tier, _models);
    if (m == null) return;
    for (final id in _agentIds) {
      _setModel(id, m);
    }
    notifyListeners();
  }

  /// Pin the focused agent's model to every other agent. If no row is
  /// focused, the first agent is treated as the source.
  void fillDownFromFocused() {
    final source = _focusedAgentId ??
        (_agentIds.isEmpty ? null : _agentIds.first);
    if (source == null) return;
    final m = _getModel(source);
    if (m == null || m.isEmpty) return;
    applyToAll(m);
  }

  /// Pin a model to every agent (used by the picker's "Apply to all").
  void applyToAll(String model) {
    for (final id in _agentIds) {
      _setModel(id, model);
    }
    notifyListeners();
  }

  /// Direct setter forwarded to the host shell.
  void setModelFor(String agentId, String model) {
    _setModel(agentId, model);
    notifyListeners();
  }

  String? modelFor(String agentId) => _getModel(agentId);

  @override
  void dispose() {
    for (final n in _focusNodes.values) {
      n.dispose();
    }
    _focusNodes.clear();
    super.dispose();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class _ApplyPresetIntent extends Intent {
  final ModelTier tier;
  const _ApplyPresetIntent(this.tier);
}

class _FillDownIntent extends Intent {
  const _FillDownIntent();
}

/// Wrap the agents-step content in this widget to install the
/// council-wide keyboard chords:
///
/// | Chord            | Action                                   |
/// | ---------------- | ---------------------------------------- |
/// | Ctrl/⌘ + 1       | Apply Fast preset to every agent         |
/// | Ctrl/⌘ + 2       | Apply Balanced preset to every agent     |
/// | Ctrl/⌘ + 3       | Apply Premium preset to every agent      |
/// | Ctrl/⌘ + D       | Fill the focused row's model down to all |
///
/// Per-row chords (↑/↓ cycle, Enter/Space open, Esc close) live on
/// each [AgentModelQuickPicker] itself — they only fire while a chip
/// has focus, so they never collide with text fields.
class RosterShortcuts extends StatelessWidget {
  final CouncilRosterController controller;
  final Widget child;

  const RosterShortcuts({
    super.key,
    required this.controller,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      child: Shortcuts(
        shortcuts: <ShortcutActivator, Intent>{
          const SingleActivator(LogicalKeyboardKey.digit1, control: true):
              const _ApplyPresetIntent(ModelTier.fast),
          const SingleActivator(LogicalKeyboardKey.digit1, meta: true):
              const _ApplyPresetIntent(ModelTier.fast),
          const SingleActivator(LogicalKeyboardKey.digit2, control: true):
              const _ApplyPresetIntent(ModelTier.balanced),
          const SingleActivator(LogicalKeyboardKey.digit2, meta: true):
              const _ApplyPresetIntent(ModelTier.balanced),
          const SingleActivator(LogicalKeyboardKey.digit3, control: true):
              const _ApplyPresetIntent(ModelTier.premium),
          const SingleActivator(LogicalKeyboardKey.digit3, meta: true):
              const _ApplyPresetIntent(ModelTier.premium),
          const SingleActivator(LogicalKeyboardKey.keyD, control: true):
              const _FillDownIntent(),
          const SingleActivator(LogicalKeyboardKey.keyD, meta: true):
              const _FillDownIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            _ApplyPresetIntent: CallbackAction<_ApplyPresetIntent>(
              onInvoke: (intent) {
                controller.applyPreset(intent.tier);
                return null;
              },
            ),
            _FillDownIntent: CallbackAction<_FillDownIntent>(
              onInvoke: (_) {
                controller.fillDownFromFocused();
                return null;
              },
            ),
          },
          child: child,
        ),
      ),
    );
  }
}
