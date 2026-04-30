import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_glass.dart';
import 'common/duck_toast.dart';

class RulesEditor extends StatefulWidget {
  final bool global;
  const RulesEditor({super.key, required this.global});

  @override
  State<RulesEditor> createState() => _RulesEditorState();
}

class _RulesEditorState extends State<RulesEditor> {
  final TextEditingController _ctrl = TextEditingController();
  bool _loaded = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final state = context.read<AppState>();
    String content;
    if (widget.global) {
      content = await state.rules.readGlobal();
    } else {
      final ws = state.currentDirectory;
      content = ws == null ? '' : await state.rules.readWorkspace(ws);
    }
    if (!mounted) return;
    setState(() {
      _ctrl.text = content;
      _loaded = true;
    });
  }

  Future<void> _save() async {
    final state = context.read<AppState>();
    setState(() => _saving = true);
    if (widget.global) {
      await state.rules.writeGlobal(_ctrl.text);
    } else {
      final ws = state.currentDirectory;
      if (ws != null) await state.rules.writeWorkspace(ws, _ctrl.text);
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showDuckToast(context, S.success);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      shape: const RoundedRectangleBorder(),
      child: DuckGlass.hero(
        borderColor: DuckColors.borderStrong,
        child: Container(
          width: 700,
          height: 540,
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.rule,
                    size: 18,
                    color: DuckColors.accentPurple,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    widget.global ? S.rulesGlobalTitle : S.rulesWorkspaceTitle,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const Divider(),
              Expanded(
                child: _loaded
                    ? TextField(
                        controller: _ctrl,
                        maxLines: null,
                        expands: true,
                        style: const TextStyle(
                          fontFamily: DuckTheme.monoFont,
                          fontSize: 13,
                          color: DuckColors.fgPrimary,
                        ),
                        decoration: const InputDecoration(
                          hintText: S.rulesPlaceholder,
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.all(12),
                        ),
                      )
                    : const Center(child: CircularProgressIndicator()),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Spacer(),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text(S.cancel),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _saving ? null : _save,
                    child: Text(_saving ? '...' : S.save),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
