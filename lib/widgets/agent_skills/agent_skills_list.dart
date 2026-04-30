import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/workspace_skills_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Settings panel section that lists `WorkspaceSkill` entries
/// loaded from `.lumen/skills/` and the global app-support skills
/// dir, with per-skill enable/disable toggles.
///
/// Skills are instruction-based markdown — the agent reads them
/// before responding. Distinct from the "Active Tools" list above
/// in the same Settings page (those are command tools the agent
/// *invokes*).
///
/// Subscribes to the `WorkspaceSkillsService` `ChangeNotifier` via
/// `ListenableBuilder` so a skill written by the generator (or a
/// user edit) refreshes this list without forcing the entire
/// Settings tab to rebuild.
class AgentSkillsList extends StatefulWidget {
  const AgentSkillsList({super.key});

  @override
  State<AgentSkillsList> createState() => _AgentSkillsListState();
}

class _AgentSkillsListState extends State<AgentSkillsList> {
  Set<String>? _enabledIdsOverride;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadEnabled();
  }

  Future<void> _loadEnabled() async {
    final prefs = context.read<AppState>().prefs;
    final ids = await prefs.getEnabledSkillIds();
    if (!mounted) return;
    setState(() {
      _enabledIdsOverride = ids;
      _loading = false;
    });
  }

  bool _isEnabled(WorkspaceSkill skill) {
    if (_enabledIdsOverride == null) return skill.defaultEnabled;
    return _enabledIdsOverride!.contains(skill.id);
  }

  /// Toggle one skill. Materialises the override set on first
  /// touch (so we stop falling back to `defaultEnabled` for
  /// every skill afterwards — the user's toggle is now authoritative).
  Future<void> _toggle(WorkspaceSkill skill, bool wanted) async {
    final prefs = context.read<AppState>().prefs;
    final all = context.read<AppState>().workspaceSkills.all;
    Set<String> next;
    if (_enabledIdsOverride == null) {
      // First-touch materialisation: start from current
      // defaultEnabled state for every loaded skill, then apply
      // this single toggle. After this point the override IS the
      // source of truth.
      next = {for (final s in all) if (s.defaultEnabled) s.id};
    } else {
      next = Set<String>.of(_enabledIdsOverride!);
    }
    if (wanted) {
      next.add(skill.id);
    } else {
      next.remove(skill.id);
    }
    setState(() => _enabledIdsOverride = next);
    await prefs.setEnabledSkillIds(next);
    // Also update the known set so newly-added skills get the
    // default treatment instead of looking deliberately disabled.
    final knownIds = {for (final s in all) s.id};
    await prefs.setKnownSkillIds(knownIds);
  }

  Future<void> _openSkillFile(WorkspaceSkill skill) async {
    try {
      await context.read<AppState>().openFile(File(skill.filePath));
      if (!mounted) return;
      // Settings is a tab in the editor — opening a file from here
      // navigates away. Pop the route only if we're inside a dialog;
      // when settings is mounted as an editor tab the openFile call
      // already swapped the active tab.
    } catch (_) {/* best-effort */}
  }

  @override
  Widget build(BuildContext context) {
    final service = context.read<AppState>().workspaceSkills;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final skills = service.all;
        if (_loading) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 1.5),
              ),
            ),
          );
        }
        if (skills.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: DuckColors.bgChip,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.5),
            ),
            child: Text(
              S.skillsNoneYet,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.45,
              ),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final skill in skills)
              _SkillRow(
                key: ValueKey(skill.id),
                skill: skill,
                enabled: _isEnabled(skill),
                onToggle: (v) => _toggle(skill, v),
                onOpenFile: () => _openSkillFile(skill),
              ),
          ],
        );
      },
    );
  }
}

class _SkillRow extends StatelessWidget {
  final WorkspaceSkill skill;
  final bool enabled;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpenFile;
  const _SkillRow({
    super.key,
    required this.skill,
    required this.enabled,
    required this.onToggle,
    required this.onOpenFile,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: DuckColors.bgChip,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 3, right: 10),
            child: Icon(
              Icons.menu_book_outlined,
              size: 14,
              color: DuckColors.accentMint,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        skill.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ),
                    const SizedBox(width: 6),
                    _ScopeChip(
                      label: skill.isWorkspaceLocal
                          ? S.skillsScopeWorkspace
                          : S.skillsScopeGlobal,
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${S.skillsTriggerPrefix}${skill.trigger ?? S.skillsAlwaysOnLabel}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    InkWell(
                      onTap: onOpenFile,
                      borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 2,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.edit_note,
                              size: 12,
                              color: DuckColors.fgSubtle,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              S.skillsOpenInEditor,
                              style: const TextStyle(
                                fontSize: 10.5,
                                color: DuckColors.fgSubtle,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          Switch(
            value: enabled,
            onChanged: onToggle,
            activeThumbColor: DuckColors.accentMint,
          ),
        ],
      ),
    );
  }
}

class _ScopeChip extends StatelessWidget {
  final String label;
  const _ScopeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 9.5,
          letterSpacing: 0.4,
          color: DuckColors.accentCyan,
        ),
      ),
    );
  }
}
