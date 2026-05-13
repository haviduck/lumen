import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';

/// Session-scoped "don't show the drag-out prompt again" flag.
///
/// Stored as a top-level mutable boolean (not in `AppState`, not in
/// `SharedPreferences`) ON PURPOSE — the user picked "don't ask again
/// THIS SESSION", not "ever". On app restart we reset to `false` so a
/// fresh launch gets the prompt back. Survives workspace switches
/// because dragging a file out of one workspace and another in the
/// same session is the same gesture from the user's perspective.
///
/// Read+write only from this file. If you ever need persisted behaviour
/// flip the mechanism over to `PreferencesService` (and rename the
/// callsite — `session` is the lie that justifies the global).
bool _dragOutSkipForSession = false;

/// Public reset for tests (not used at runtime).
@visibleForTesting
void debugResetDragOutSession() {
  _dragOutSkipForSession = false;
}

/// Shows the drag-out confirmation prompt (if not already skipped for
/// the session) and returns `true` if the user confirmed the drag.
///
/// Called from `DragItemWidget.dragItemProvider` — returning `false`
/// causes the provider to yield `null`, which super_drag_and_drop
/// interprets as "abort drag". So the OS drag never starts for a
/// cancelled prompt; the cursor stays put.
///
/// We deliberately show the dialog SYNCHRONOUSLY in the drag-item
/// callback. super_drag_and_drop's native side waits for the future
/// to complete before it hands off to the Win32 `DoDragDrop` loop,
/// so there's no race between "user is thinking about the prompt"
/// and "OS already has the drag in flight". The drag image just
/// pauses until the future resolves.
Future<bool> maybeAskBeforeDragOut(
  BuildContext context, {
  required String name,
  required bool isDirectory,
}) async {
  if (_dragOutSkipForSession) return true;

  final result = await showDialog<bool>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    barrierDismissible: true,
    builder: (ctx) => _DragOutPromptDialog(
      name: name,
      isDirectory: isDirectory,
    ),
  );

  return result == true;
}

class _DragOutPromptDialog extends StatefulWidget {
  final String name;
  final bool isDirectory;

  const _DragOutPromptDialog({
    required this.name,
    required this.isDirectory,
  });

  @override
  State<_DragOutPromptDialog> createState() => _DragOutPromptDialogState();
}

class _DragOutPromptDialogState extends State<_DragOutPromptDialog> {
  bool _skipThisSession = false;

  void _confirm() {
    if (_skipThisSession) {
      _dragOutSkipForSession = true;
    }
    Navigator.of(context).pop(true);
  }

  void _cancel() {
    Navigator.of(context).pop(false);
  }

  @override
  Widget build(BuildContext context) {
    final body = widget.isDirectory
        ? S.dragOutPromptBodyFolderFmt(widget.name)
        : S.dragOutPromptBodyFileFmt(widget.name);

    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissIntent: CallbackAction<_DismissIntent>(
            onInvoke: (_) {
              _cancel();
              return null;
            },
          ),
        },
        child: Dialog(
          backgroundColor: Colors.transparent,
          elevation: 0,
          shape: const RoundedRectangleBorder(),
          child: DuckGlass.hero(
            borderColor: DuckColors.borderStrong,
            child: Container(
              width: 440,
              padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color:
                              DuckColors.accentCyan.withValues(alpha: 0.12),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: DuckColors.accentCyan
                                .withValues(alpha: 0.35),
                            width: 0.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.drag_indicator,
                          size: 16,
                          color: DuckColors.accentCyan,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          S.dragOutPromptTitle,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: DuckColors.fgPrimary,
                          ),
                        ),
                      ),
                      MouseRegion(
                        cursor: SystemMouseCursors.click,
                        child: InkWell(
                          onTap: _cancel,
                          borderRadius:
                              BorderRadius.circular(DuckTheme.radiusS),
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.close,
                              size: 14,
                              color: DuckColors.fgSubtle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  // Path card — same shape as `_DeleteConfirmDialog`
                  // so the "this is the thing the operation affects"
                  // affordance reads the same across the IDE.
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
                    decoration: BoxDecoration(
                      color: DuckColors.bgChip,
                      borderRadius:
                          BorderRadius.circular(DuckTheme.radiusM),
                      border: Border.all(
                        color: DuckColors.glassSeam,
                        width: 0.5,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          widget.isDirectory
                              ? Icons.folder_outlined
                              : Icons.insert_drive_file_outlined,
                          size: 16,
                          color: widget.isDirectory
                              ? DuckColors.folderIcon
                              : DuckColors.fileIcon,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            widget.name,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: DuckColors.fgPrimary,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    body,
                    style: const TextStyle(
                      fontSize: 12,
                      color: DuckColors.fgMuted,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 14),
                  // "Don't ask again this session" checkbox.
                  // Compact, left-aligned, muted styling so it reads
                  // as a power-user toggle, not a default-on prompt.
                  // Clicking the label also toggles (label is wrapped
                  // in an InkWell sharing the same handler).
                  _SessionSkipCheckbox(
                    value: _skipThisSession,
                    onChanged: (v) =>
                        setState(() => _skipThisSession = v ?? false),
                  ),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: _cancel,
                        style: TextButton.styleFrom(
                          foregroundColor: DuckColors.fgMuted,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                        ),
                        child: const Text(S.dragOutPromptCancel),
                      ),
                      const SizedBox(width: 6),
                      ElevatedButton.icon(
                        autofocus: true,
                        icon: const Icon(Icons.north_east, size: 14),
                        label: const Text(S.dragOutPromptConfirm),
                        onPressed: _confirm,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: DuckColors.accentCyan,
                          foregroundColor: DuckColors.bgDeepest,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius:
                                BorderRadius.circular(DuckTheme.radiusS),
                          ),
                          textStyle: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}

class _SessionSkipCheckbox extends StatelessWidget {
  final bool value;
  final ValueChanged<bool?> onChanged;
  const _SessionSkipCheckbox({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: InkWell(
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        onTap: () => onChanged(!value),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: Checkbox(
                  value: value,
                  onChanged: onChanged,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  side: const BorderSide(
                    color: DuckColors.borderStrong,
                    width: 0.5,
                  ),
                  fillColor: WidgetStateProperty.resolveWith((states) {
                    if (states.contains(WidgetState.selected)) {
                      return DuckColors.accentCyan;
                    }
                    return Colors.transparent;
                  }),
                  checkColor: DuckColors.bgDeepest,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                S.dragOutPromptSkipSession,
                style: TextStyle(
                  fontSize: 11.5,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
