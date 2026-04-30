import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/syncthing_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Container for the four Syncthing safety/QoL panels embedded in
/// `SettingsView._buildSyncthing`. Kept modular so `settings_view.dart`
/// doesn't balloon and so each panel can be re-used elsewhere later
/// (e.g. dropped into a future "first-run" wizard).
///
/// Render order (top → bottom):
///
///   1. [SyncthingIntroducerWarning] — yellow warning + one-click fix
///      for the mutual-introducer log-spam state.
///   2. [SyncthingPendingFoldersPanel] — accept folders other devices
///      offer with an explicit local destination path.
///   3. [SyncthingPendingDevicesPanel] — accept device pairing requests.
///
/// Panels accept their data as immutable inputs and report back via
/// callbacks, so the parent widget keeps owning fetch/refresh logic.

class SyncthingIntroducerWarning extends StatelessWidget {
  final List<String> introducerDeviceIds;
  final Future<void> Function() onFix;

  const SyncthingIntroducerWarning({
    super.key,
    required this.introducerDeviceIds,
    required this.onFix,
  });

  @override
  Widget build(BuildContext context) {
    if (introducerDeviceIds.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.stateWarn.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.stateWarn.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: DuckColors.stateWarn,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.settingsSyncthingIntroducerWarningTitle,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  S.settingsSyncthingIntroducerWarningBody,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                Align(
                  alignment: Alignment.centerLeft,
                  child: ElevatedButton.icon(
                    onPressed: onFix,
                    icon: const Icon(Icons.handshake_outlined, size: 14),
                    label: const Text(
                      S.settingsSyncthingIntroducerFixBtn,
                      style: TextStyle(fontSize: 12),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: DuckColors.bgChip,
                      foregroundColor: DuckColors.fgPrimary,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius:
                            BorderRadius.circular(DuckTheme.radiusS),
                        side: const BorderSide(
                          color: DuckColors.glassSeam,
                          width: 0.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Lists `/rest/cluster/pending/folders` results. Each row has an
/// "Accept here…" button that opens a directory picker and POSTs the
/// folder config with an explicit absolute path (the receiver-side
/// fix for the "folder lands inside Syncthing's data dir" bug).
class SyncthingPendingFoldersPanel extends StatelessWidget {
  /// Map shape from `/rest/cluster/pending/folders`:
  /// `{ folderId: { offeredBy: { deviceId: { time, label, ... } } } }`.
  final Map<String, dynamic> pending;
  final Map<String, String> deviceNamesById;
  final AppState state;
  final Future<void> Function() onChanged;

  const SyncthingPendingFoldersPanel({
    super.key,
    required this.pending,
    required this.deviceNamesById,
    required this.state,
    required this.onChanged,
  });

  Future<void> _accept(
    BuildContext context,
    String folderId,
    String label,
    String fromDeviceId,
  ) async {
    final picked = await FilePicker.getDirectoryPath();
    if (picked == null || picked.isEmpty) return;

    final versioning = SyncthingVersioningPresetX.fromKey(
      state.syncthingVersioningPreset,
    ).toJson();

    final ok = await state.syncthing.acceptPendingFolder(
      folderId: folderId,
      label: label,
      path: picked,
      fromDeviceId: fromDeviceId,
      ignorePerms: state.syncthingIgnorePerms,
      versioning: versioning,
    );

    if (!context.mounted) return;
    showDuckToast(
      context,
      ok ? S.settingsSyncthingAcceptedToast : 'Failed to accept folder.',
    );
    if (ok) await onChanged();
  }

  Future<void> _dismiss(
    BuildContext context,
    String folderId,
    String fromDeviceId,
  ) async {
    final ok = await state.syncthing.dismissPendingFolder(
      folderId,
      deviceId: fromDeviceId,
    );
    if (!context.mounted) return;
    showDuckToast(
      context,
      ok ? S.settingsSyncthingDismissedToast : 'Failed to dismiss.',
    );
    if (ok) await onChanged();
  }

  /// Flatten `{folderId: {offeredBy: {devId: meta}}}` into a list of
  /// `(folderId, deviceId, label)` tuples — one row per offer per device.
  List<_PendingFolderRow> _rows() {
    final out = <_PendingFolderRow>[];
    for (final e in pending.entries) {
      final folderId = e.key;
      final offered = (e.value as Map?)?['offeredBy'] as Map?;
      if (offered == null) continue;
      for (final off in offered.entries) {
        final meta = off.value as Map? ?? const {};
        out.add(
          _PendingFolderRow(
            folderId: folderId,
            deviceId: off.key as String,
            label: (meta['label'] as String?) ?? folderId,
            time: meta['time'] as String? ?? '',
          ),
        );
      }
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows();
    if (rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          S.settingsSyncthingNoPendingFolders,
          style: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            S.settingsSyncthingPendingFoldersDesc,
            style: const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
          ),
        ),
        for (final r in rows) _row(context, r),
      ],
    );
  }

  Widget _row(BuildContext context, _PendingFolderRow r) {
    final fromName = deviceNamesById[r.deviceId] ??
        (r.deviceId.length > 10 ? '${r.deviceId.substring(0, 10)}…' : r.deviceId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.cloud_download_outlined,
            size: 16,
            color: DuckColors.accentMint,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'from $fromName  •  id ${r.folderId}',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: DuckTheme.monoFont,
                    color: DuckColors.fgSubtle,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _dismiss(context, r.folderId, r.deviceId),
            style: OutlinedButton.styleFrom(
              foregroundColor: DuckColors.fgMuted,
              side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
            ),
            child: const Text(
              S.settingsSyncthingDismiss,
              style: TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: () =>
                _accept(context, r.folderId, r.label, r.deviceId),
            icon: const Icon(Icons.check, size: 14),
            label: const Text(
              S.settingsSyncthingAcceptHere,
              style: TextStyle(fontSize: 11),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentCyan.withValues(alpha: 0.18),
              foregroundColor: DuckColors.accentCyan,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                side: BorderSide(
                  color: DuckColors.accentCyan.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PendingFolderRow {
  final String folderId;
  final String deviceId;
  final String label;
  final String time;
  const _PendingFolderRow({
    required this.folderId,
    required this.deviceId,
    required this.label,
    required this.time,
  });
}

/// Lists `/rest/cluster/pending/devices` results. "Add device" button
/// pairs the device with a Lumen-friendly default config (introducer
/// off, autoAcceptFolders off — both the safe defaults).
class SyncthingPendingDevicesPanel extends StatelessWidget {
  /// Map shape from `/rest/cluster/pending/devices`:
  /// `{ deviceId: { time, name, address } }`.
  final Map<String, dynamic> pending;
  final AppState state;
  final Future<void> Function() onChanged;

  const SyncthingPendingDevicesPanel({
    super.key,
    required this.pending,
    required this.state,
    required this.onChanged,
  });

  Future<void> _add(
    BuildContext context,
    String deviceId,
    String suggestedName,
  ) async {
    final ctrl = TextEditingController(text: suggestedName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.border, width: 0.5),
        ),
        title: const Text(
          S.settingsSyncthingAddDevice,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              deviceId,
              style: const TextStyle(
                fontSize: 11,
                fontFamily: DuckTheme.monoFont,
                color: DuckColors.fgSubtle,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              S.settingsSyncthingDeviceName,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
            const SizedBox(height: 4),
            TextField(
              controller: ctrl,
              autofocus: true,
              style: const TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text(S.settingsSyncthingAddDevice),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;

    final ok = await state.syncthing.addDevice(
      deviceId: deviceId,
      name: name,
    );
    if (!context.mounted) return;
    showDuckToast(
      context,
      ok ? S.settingsSyncthingDeviceAdded : 'Failed to add device.',
    );
    if (ok) await onChanged();
  }

  Future<void> _dismiss(BuildContext context, String deviceId) async {
    final ok = await state.syncthing.dismissPendingDevice(deviceId);
    if (!context.mounted) return;
    showDuckToast(
      context,
      ok ? S.settingsSyncthingDeviceDismissed : 'Failed to dismiss.',
    );
    if (ok) await onChanged();
  }

  @override
  Widget build(BuildContext context) {
    if (pending.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          S.settingsSyncthingNoPendingDevices,
          style: const TextStyle(fontSize: 12, color: DuckColors.fgSubtle),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            S.settingsSyncthingPendingDevicesDesc,
            style: const TextStyle(fontSize: 12, color: DuckColors.fgMuted),
          ),
        ),
        for (final e in pending.entries)
          _row(context, e.key, (e.value as Map?) ?? const {}),
      ],
    );
  }

  Widget _row(BuildContext context, String deviceId, Map meta) {
    final name = (meta['name'] as String?)?.trim();
    final address = (meta['address'] as String?) ?? '';
    final shown = (name != null && name.isNotEmpty)
        ? name
        : (deviceId.length > 12 ? '${deviceId.substring(0, 12)}…' : deviceId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.devices_other_outlined,
            size: 16,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  shown,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$deviceId  •  $address',
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: DuckTheme.monoFont,
                    color: DuckColors.fgSubtle,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            onPressed: () => _dismiss(context, deviceId),
            style: OutlinedButton.styleFrom(
              foregroundColor: DuckColors.fgMuted,
              side: const BorderSide(color: DuckColors.glassSeam, width: 0.5),
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
            ),
            child: const Text(
              S.settingsSyncthingDismiss,
              style: TextStyle(fontSize: 11),
            ),
          ),
          const SizedBox(width: 6),
          ElevatedButton.icon(
            onPressed: () =>
                _add(context, deviceId, name ?? ''),
            icon: const Icon(Icons.add, size: 14),
            label: const Text(
              S.settingsSyncthingAddDevice,
              style: TextStyle(fontSize: 11),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentCyan.withValues(alpha: 0.18),
              foregroundColor: DuckColors.accentCyan,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                side: BorderSide(
                  color: DuckColors.accentCyan.withValues(alpha: 0.5),
                  width: 0.5,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
