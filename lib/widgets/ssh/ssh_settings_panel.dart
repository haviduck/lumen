import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'ssh_vault_dialog.dart';

/// Settings → SSH panel. Three controls:
///   - Open vault (jumps into the host management dialog)
///   - Keepalive seconds (numeric, 0 = disabled)
///   - Clear remote-mirror cache (wipes `<appSupport>/lumen/ssh-mirror`)
///
/// Host-level settings (per-host auth, keys, fingerprints) live on
/// the host itself and are managed via the vault dialog. This panel
/// is the home for vault-wide knobs only.
class SshSettingsPanel extends StatefulWidget {
  const SshSettingsPanel({super.key});

  @override
  State<SshSettingsPanel> createState() => _SshSettingsPanelState();
}

class _SshSettingsPanelState extends State<SshSettingsPanel> {
  late TextEditingController _keepAliveCtrl;

  @override
  void initState() {
    super.initState();
    final ssh = context.read<SshController>();
    _keepAliveCtrl = TextEditingController(
      text: ssh.ready ? ssh.vault.keepAliveSeconds.toString() : '30',
    );
  }

  @override
  void dispose() {
    _keepAliveCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    if (!ssh.ready) {
      return const Padding(
        padding: EdgeInsets.all(20),
        child: SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 1.5),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 16, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            S.settingsSshTitle,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            S.settingsSshSubtitle,
            style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
          ),
          const SizedBox(height: 22),
          _Section(
            title: S.sshVaultTitle,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${ssh.vault.hosts.length} host(s)',
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                ),
                ElevatedButton.icon(
                  onPressed: () => showSshVaultDialog(context),
                  icon: const Icon(Icons.tune, size: 14),
                  label: const Text(S.settingsSshOpenVault),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _Section(
            title: S.settingsSshKeepAlive,
            hint: S.settingsSshKeepAliveHint,
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: TextField(
                    controller: _keepAliveCtrl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(isDense: true),
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12.5,
                    ),
                    onSubmitted: (v) async {
                      final messenger = ScaffoldMessenger.maybeOf(context);
                      final n = int.tryParse(v.trim()) ?? 30;
                      await ssh.vault.setKeepAliveSeconds(n);
                      // Use the captured messenger context (still valid even
                      // if `this.context` got deactivated mid-await) to flash
                      // a save confirmation. Falls back to `showDuckToast`
                      // when the messenger is in scope to keep the visual
                      // matching the rest of the app.
                      if (!mounted) return;
                      messenger?.showSnackBar(
                        const SnackBar(
                          duration: Duration(milliseconds: 900),
                          content: Text(S.success),
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Builder(
                  builder: (innerCtx) => TextButton(
                    onPressed: () async {
                      final n =
                          int.tryParse(_keepAliveCtrl.text.trim()) ?? 30;
                      await ssh.vault.setKeepAliveSeconds(n);
                      if (!innerCtx.mounted) return;
                      showDuckToast(innerCtx, S.success);
                    },
                    child: const Text(S.save),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _Section(
            title: S.settingsSshMirrorCacheTitle,
            hint: S.settingsSshMirrorCacheHint,
            child: Align(
              alignment: Alignment.centerLeft,
              child: Builder(
                builder: (innerCtx) => OutlinedButton.icon(
                  onPressed: () async {
                    await ssh.remoteFiles.clearCache();
                    if (!innerCtx.mounted) return;
                    showDuckToast(innerCtx, S.settingsSshMirrorClearedFmt);
                  },
                  icon: const Icon(Icons.delete_sweep_outlined, size: 14),
                  label: const Text(S.settingsSshMirrorClear),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: DuckColors.stateWarn,
                    side: BorderSide(
                      color: DuckColors.stateWarn.withValues(alpha: 0.55),
                      width: 0.6,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String? hint;
  final Widget child;
  const _Section({required this.title, required this.child, this.hint});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.bgChip.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: DuckColors.fgPrimary,
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: 4),
            Text(
              hint!,
              style: const TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgMuted,
                height: 1.35,
              ),
            ),
          ],
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
