import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'ssh_host_dialog.dart';

/// Full-screen vault management. Lists vaulted hosts; lets the user
/// add, edit, and delete. Also surfaces "Import from ~/.ssh/config".
Future<void> showSshVaultDialog(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => const _SshVaultDialog(),
  );
}

class _SshVaultDialog extends StatelessWidget {
  const _SshVaultDialog();

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    final hosts = [...ssh.vault.hosts]
      ..sort((a, b) =>
          a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase()));

    return Dialog(
      backgroundColor: DuckColors.bgRaised,
      insetPadding: const EdgeInsets.all(40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640, maxHeight: 600),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 16, 8),
              child: Row(
                children: [
                  const Text(
                    S.sshVaultTitle,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 18),
                    color: DuckColors.fgMuted,
                  ),
                ],
              ),
            ),
            Expanded(
              child: hosts.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      itemBuilder: (ctx, i) => _HostRow(host: hosts[i]),
                      separatorBuilder: (_, _) => const Divider(
                        color: DuckColors.glassSeam,
                        height: 1,
                        thickness: 0.5,
                      ),
                      itemCount: hosts.length,
                    ),
            ),
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(
                    color: DuckColors.glassSeam,
                    width: 0.5,
                  ),
                ),
              ),
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _importFromSshConfig(context),
                    icon: const Icon(Icons.download, size: 14),
                    label: const Text(S.sshVaultImportConfig),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: DuckColors.fgPrimary,
                      side: const BorderSide(
                        color: DuckColors.glassSeam,
                        width: 0.6,
                      ),
                    ),
                  ),
                  const Spacer(),
                  ElevatedButton.icon(
                    onPressed: () async {
                      await showSshHostEditorDialog(context);
                    },
                    icon: const Icon(Icons.add, size: 14),
                    label: const Text(S.sshAddHost),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _importFromSshConfig(BuildContext context) async {
    final ssh = context.read<SshController>();
    try {
      final imported = await SshConfigImporter.importFromUserConfig();
      if (imported.isEmpty) {
        if (context.mounted) {
          showDuckToast(context, S.sshVaultImportConfigNone);
        }
        return;
      }
      var added = 0;
      for (final h in imported) {
        // Skip exact duplicates by `(user, host, port)` so a re-run
        // of the importer doesn't pile up entries.
        final dup = ssh.vault.hosts.any((existing) =>
            existing.user == h.user &&
            existing.host == h.host &&
            existing.port == h.port);
        if (dup) continue;
        await ssh.addHost(h);
        added++;
      }
      if (context.mounted) {
        showDuckToast(context, S.sshVaultImportConfigDoneFmt(added));
      }
    } catch (_) {
      if (context.mounted) {
        showDuckToast(context, S.sshVaultImportConfigFailed);
      }
    }
  }
}

class _HostRow extends StatefulWidget {
  final SshHost host;
  const _HostRow({required this.host});

  @override
  State<_HostRow> createState() => _HostRowState();
}

class _HostRowState extends State<_HostRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: DuckMotion.fast,
        curve: DuckMotion.standard,
        color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            const Icon(
              Icons.dns_outlined,
              size: 14,
              color: DuckColors.fgMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.host.displayName,
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                  Text(
                    widget.host.addressLine,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: DuckColors.fgFaint,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
            ),
            _AuthBadge(method: widget.host.authMethod),
            const SizedBox(width: 12),
            IconButton(
              tooltip: S.sshEditHost,
              icon: const Icon(Icons.edit_outlined, size: 14),
              onPressed: () => showSshHostEditorDialog(
                context,
                existing: widget.host,
              ),
            ),
            IconButton(
              tooltip: S.sshDeleteHost,
              icon: const Icon(Icons.delete_outline, size: 14),
              onPressed: () => _confirmDelete(context),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: Text(S.sshDeleteHost),
        content: const Text(
          S.sshHostDeleteConfirm,
          style: TextStyle(fontSize: 12.5, color: DuckColors.fgPrimary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.stateError,
            ),
            child: const Text(S.delete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    if (!context.mounted) return;
    await context.read<SshController>().removeHost(widget.host.id);
  }
}

class _AuthBadge extends StatelessWidget {
  final SshAuthMethod method;
  const _AuthBadge({required this.method});

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (method) {
      SshAuthMethod.keyFile => (S.sshHostAuthKeyFile, DuckColors.accentCyan),
      SshAuthMethod.password => (S.sshHostAuthPassword, DuckColors.accentDuck),
      SshAuthMethod.agent => (S.sshHostAuthAgent, DuckColors.accentMint),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        border: Border.all(color: color.withValues(alpha: 0.45), width: 0.5),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.dns_outlined,
              size: 32,
              color: DuckColors.fgFaint,
            ),
            const SizedBox(height: 12),
            const Text(
              S.sshVaultEmpty,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                color: DuckColors.fgMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
