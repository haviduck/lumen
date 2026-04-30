import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// User's response to an unsaved-changes confirm prompt. Distinct
/// values per scenario so the caller can branch cleanly without
/// re-checking the buffer state. `cancel` covers both explicit
/// Cancel button taps AND dismissing via Esc / scrim — in both
/// cases the close should NOT proceed.
enum UnsavedChangesChoice {
  /// Save (or Save As, for untitled tabs) and then close.
  save,

  /// Discard the buffer and close without saving.
  discard,

  /// Abort the close — leave the tab open exactly as-is.
  cancel,
}

/// Show a single-file unsaved-changes confirm prompt before closing
/// a dirty tab. Returns [UnsavedChangesChoice.cancel] when the user
/// dismisses via Esc / scrim — the safe default.
///
/// For untitled tabs (no on-disk path yet) the primary action label
/// flips to "Save As…" — the caller is responsible for routing to
/// the save-as picker when that variant is returned. We can't show
/// the picker here because path-prompt UI is owned by the menu_bar
/// flow and we don't want to duplicate it.
Future<UnsavedChangesChoice> showUnsavedChangesDialog(
  BuildContext context, {
  required File file,
}) async {
  final isUntitled = AppState.isUntitledTab(file.path);
  final displayName =
      isUntitled ? S.unsavedDialogUntitledLabel : p.basename(file.path);
  final result = await showDialog<UnsavedChangesChoice>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: Text(
        S.unsavedDialogTitle(displayName),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      content: const Text(
        S.unsavedDialogBody,
        style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, UnsavedChangesChoice.cancel),
          child: const Text(S.cancel),
        ),
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, UnsavedChangesChoice.discard),
          style: TextButton.styleFrom(
            foregroundColor: DuckColors.stateError,
          ),
          child: const Text(S.unsavedDialogDontSave),
        ),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, UnsavedChangesChoice.save),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.accentCyan,
            foregroundColor: DuckColors.bgDeepest,
          ),
          child: Text(
            isUntitled
                ? S.unsavedDialogSaveAs
                : S.unsavedDialogSave,
          ),
        ),
      ],
    ),
  );
  return result ?? UnsavedChangesChoice.cancel;
}

/// User's response to a *batch* unsaved-changes confirm prompt
/// (Close Others / Close to Right / Close All when multiple dirty
/// tabs are about to close). Mirrors [UnsavedChangesChoice] but
/// the verbs are pluralised in the UI and "Save All" applies to
/// every named dirty tab in the batch. Untitled tabs in a batch
/// save are routed individually by the caller.
enum BatchUnsavedChangesChoice {
  saveAll,
  discardAll,
  cancel,
}

/// Show a batch unsaved-changes confirm prompt listing every dirty
/// file in the closing batch. Returns [BatchUnsavedChangesChoice.cancel]
/// when dismissed via Esc / scrim.
///
/// [dirtyFiles] is the full list — the dialog truncates rendering at
/// 8 entries with a "+N more" tail so a "Close All" of 30 dirty tabs
/// doesn't produce a wall-of-text dialog the user can't read.
Future<BatchUnsavedChangesChoice> showBatchUnsavedChangesDialog(
  BuildContext context, {
  required List<File> dirtyFiles,
}) async {
  if (dirtyFiles.isEmpty) return BatchUnsavedChangesChoice.discardAll;

  const int previewCap = 8;
  final preview = dirtyFiles.take(previewCap).toList();
  final remaining = dirtyFiles.length - preview.length;

  final result = await showDialog<BatchUnsavedChangesChoice>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        side: const BorderSide(color: DuckColors.border, width: 0.5),
      ),
      title: Text(
        S.unsavedBatchTitle(dirtyFiles.length),
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              S.unsavedBatchBody,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
            const SizedBox(height: 12),
            for (final f in preview)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1),
                child: Row(
                  children: [
                    const Icon(
                      Icons.circle,
                      size: 6,
                      color: DuckColors.stateWarn,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        AppState.isUntitledTab(f.path)
                            ? S.unsavedDialogUntitledLabel
                            : p.basename(f.path),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 12,
                          color: DuckColors.fgPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (remaining > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 14),
                child: Text(
                  S.unsavedBatchMore(remaining),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () =>
              Navigator.pop(ctx, BatchUnsavedChangesChoice.cancel),
          child: const Text(S.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(
            ctx,
            BatchUnsavedChangesChoice.discardAll,
          ),
          style: TextButton.styleFrom(
            foregroundColor: DuckColors.stateError,
          ),
          child: const Text(S.unsavedBatchDontSave),
        ),
        ElevatedButton(
          onPressed: () =>
              Navigator.pop(ctx, BatchUnsavedChangesChoice.saveAll),
          style: ElevatedButton.styleFrom(
            backgroundColor: DuckColors.accentCyan,
            foregroundColor: DuckColors.bgDeepest,
          ),
          child: const Text(S.unsavedBatchSaveAll),
        ),
      ],
    ),
  );
  return result ?? BatchUnsavedChangesChoice.cancel;
}
