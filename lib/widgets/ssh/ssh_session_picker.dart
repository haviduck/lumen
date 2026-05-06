import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'ssh_helpers_install_prompt.dart';
import 'ssh_host_dialog.dart';
import 'ssh_host_key_prompt.dart';
import 'ssh_password_prompt.dart';
import 'ssh_vault_dialog.dart';

/// Show the SSH host picker as a dropdown anchored to a specific
/// widget — typically the activity-bar SSH icon or the Remote pane's
/// chrome `+` button.
///
/// Anchor placement rules:
/// - Default: align dropdown's left edge with anchor's left edge,
///   open *below* the anchor.
/// - If the dropdown would clip past the right edge of the overlay,
///   shift left so it stays on-screen.
/// - If there's not enough room *below* the anchor, flip and open
///   above instead. (Activity-bar icons live near the top of the
///   IDE so this rarely fires; Remote chrome's `+` is near the top
///   of the right slot, also rarely flips. Defensive code path.)
///
/// Tap-outside dismisses (transparent barrier, `barrierDismissible`
/// true). The picker reuses [SshSessionPickerSheet] for its body so
/// the host list / add / manage UX stays in one place.
Future<void> showSshSessionPicker(BuildContext anchorContext) async {
  final box = anchorContext.findRenderObject() as RenderBox?;
  if (box == null || !box.attached) return;
  final overlayBox = Overlay.of(anchorContext, rootOverlay: true)
      .context
      .findRenderObject() as RenderBox;

  final anchorPos = box.localToGlobal(Offset.zero, ancestor: overlayBox);
  final anchorSize = box.size;
  final overlaySize = overlayBox.size;

  // Final dropdown dimensions. Width is wide enough for typical
  // host labels (`label · user@host:port` + relative timestamp);
  // height caps so a populated vault doesn't shoot off the screen.
  const dropdownW = 340.0;
  const dropdownMaxH = 380.0;
  const gap = 6.0;
  const edgePad = 8.0;

  var left = anchorPos.dx;
  if (left + dropdownW > overlaySize.width - edgePad) {
    left = overlaySize.width - dropdownW - edgePad;
  }
  if (left < edgePad) left = edgePad;

  var top = anchorPos.dy + anchorSize.height + gap;
  // Flip above if the natural below-anchor placement would clip.
  if (top + dropdownMaxH > overlaySize.height - edgePad) {
    final aboveTop = anchorPos.dy - dropdownMaxH - gap;
    if (aboveTop >= edgePad) {
      top = aboveTop;
    } else {
      // Neither below nor above fits cleanly — clamp to overlay
      // bounds and let the inner Column scroll.
      top = (overlaySize.height - dropdownMaxH - edgePad).clamp(
        edgePad,
        overlaySize.height - edgePad,
      );
    }
  }

  await showDialog<void>(
    context: anchorContext,
    barrierColor: Colors.transparent,
    builder: (ctx) {
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            width: dropdownW,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: dropdownMaxH),
              child: Material(
                color: Colors.transparent,
                child: Container(
                  decoration: BoxDecoration(
                    color: DuckColors.bgRaised,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusM),
                    border: Border.all(
                      color: DuckColors.borderStrong,
                      width: 0.5,
                    ),
                    boxShadow: DuckTheme.shadowSoft,
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: const SshSessionPickerSheet(),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

/// Dropdown body for the SSH host picker. Lists vaulted hosts
/// (recently-connected first), with `Add host…` + `Manage hosts…`
/// footer actions. Click a host → connect, or focus the existing
/// live session if there is one.
///
/// Lives as a separate widget (rather than inline inside
/// [showSshSessionPicker]) so the same body can render in tests
/// without the surrounding `showDialog` plumbing.
class SshSessionPickerSheet extends StatelessWidget {
  const SshSessionPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();
    final hosts = _sortHosts(ssh.vault.hosts);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(14, 12, 14, 8),
          child: Text(
            S.sshActivityTooltip,
            style: TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (hosts.isEmpty)
          const Padding(
            padding: EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: Text(
              S.sshNoHosts,
              style: TextStyle(
                fontSize: 12,
                color: DuckColors.fgFaint,
              ),
            ),
          )
        else
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: hosts.length,
              itemBuilder: (ctx, i) => _HostRow(
                host: hosts[i],
                onTap: () => _connectOrFocus(context, ssh, hosts[i]),
              ),
            ),
          ),
        const Divider(
          color: DuckColors.glassSeam,
          height: 1,
          thickness: 0.5,
        ),
        _FooterAction(
          icon: Icons.add,
          label: S.sshAddHost,
          onTap: () async {
            Navigator.of(context).pop();
            await showSshHostEditorDialog(context);
          },
        ),
        _FooterAction(
          icon: Icons.tune,
          label: S.sshManageHosts,
          onTap: () async {
            Navigator.of(context).pop();
            await showSshVaultDialog(context);
          },
        ),
      ],
    );
  }

  static List<SshHost> _sortHosts(List<SshHost> hosts) {
    final copy = [...hosts];
    copy.sort((a, b) {
      final aTs = a.lastConnectedAt?.millisecondsSinceEpoch ?? 0;
      final bTs = b.lastConnectedAt?.millisecondsSinceEpoch ?? 0;
      if (aTs != bTs) return bTs.compareTo(aTs);
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });
    return copy;
  }

  Future<void> _connectOrFocus(
    BuildContext context,
    SshController ssh,
    SshHost host,
  ) async {
    final existing = ssh.findSessionForHost(host.id);
    if (existing != null) {
      ssh.setActiveSession(existing.id);
      Navigator.of(context).pop();
      return;
    }
    // Capture a stable upper context BEFORE the dropdown pops — the
    // closures we hand to `connectToHost` need a Navigator that
    // outlives this dialog. The root navigator from `Overlay.of`
    // always sits above the dropdown's local navigator.
    final rootContext = Navigator.of(context, rootNavigator: true).context;
    Navigator.of(context).pop();

    await ssh.connectToHost(
      host,
      hostKeyHandler: ({
        required host,
        required fingerprint,
        required firstTime,
      }) =>
          showSshHostKeyPrompt(
        rootContext,
        host: host,
        fingerprint: fingerprint,
        firstTime: firstTime,
      ),
      passwordRequester: (host) =>
          showSshPasswordPrompt(rootContext, host: host),
      passphraseRequester: (host) =>
          showSshPasswordPrompt(rootContext, host: host, passphrase: true),
      helpersInstallPrompter: (host) =>
          showSshHelpersInstallPrompt(rootContext, host: host),
    );
  }
}

class _HostRow extends StatefulWidget {
  final SshHost host;
  final VoidCallback onTap;
  const _HostRow({required this.host, required this.onTap});

  @override
  State<_HostRow> createState() => _HostRowState();
}

class _HostRowState extends State<_HostRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          curve: DuckMotion.standard,
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Row(
            children: [
              const Icon(
                Icons.dns_outlined,
                size: 14,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: 10),
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
                    if (widget.host.label.isNotEmpty)
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
              if (widget.host.lastConnectedAt != null)
                Text(
                  _formatTs(widget.host.lastConnectedAt!),
                  style: const TextStyle(
                    fontSize: 10,
                    color: DuckColors.fgFaint,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static String _formatTs(DateTime ts) {
    final now = DateTime.now();
    final diff = now.difference(ts);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${ts.year}-${ts.month.toString().padLeft(2, '0')}-${ts.day.toString().padLeft(2, '0')}';
  }
}

class _FooterAction extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _FooterAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  State<_FooterAction> createState() => _FooterActionState();
}

class _FooterActionState extends State<_FooterAction> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: DuckMotion.fast,
          curve: DuckMotion.standard,
          color: _hover ? DuckColors.bgRaisedHi : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            children: [
              Icon(widget.icon, size: 14, color: DuckColors.fgMuted),
              const SizedBox(width: 10),
              Text(
                widget.label,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.fgPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
