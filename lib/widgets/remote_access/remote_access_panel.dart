import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/remote/lumen_pairing_service.dart';
import '../../services/remote/lumen_server.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'pairing_dialog.dart';

/// Settings panel for the optional embedded HTTP server.
///
/// Listens directly to the [LumenServer] `ChangeNotifier` (which
/// forwards from the inner `LumenPairingService`) so the live status
/// row, the bind toggle, the paired-devices list, and the pairing
/// dialog all update from a single notifier without piping through
/// `AppState.notifyListeners`. That keeps streaming-chat rebuilds
/// from churning the settings tree, and vice versa.
class RemoteAccessPanel extends StatelessWidget {
  const RemoteAccessPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return AnimatedBuilder(
      animation: state.remote,
      builder: (context, _) => _Body(server: state.remote),
    );
  }
}

class _Body extends StatelessWidget {
  final LumenServer server;
  const _Body({required this.server});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionHeader(S.settingsCatRemoteAccess),
        const SizedBox(height: 16),
        Text(
          S.settingsRemoteAccessSubtitle,
          style: const TextStyle(
            fontSize: 12,
            color: DuckColors.fgMuted,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 20),
        _PlainHttpBanner(),
        const SizedBox(height: 20),
        _toggleRow(context),
        const SizedBox(height: 12),
        _bindAllRow(context),
        const SizedBox(height: 20),
        _statusCard(context),
        if (server.lastError != null) ...[
          const SizedBox(height: 12),
          _errorCard(context),
        ],
        if (server.isRunning && server.bindAll) ...[
          const SizedBox(height: 16),
          _ReachableUrlsCard(port: server.boundPort ?? 0),
        ],
        const SizedBox(height: 24),
        _PairingSection(server: server),
        const SizedBox(height: 24),
        _PairedDevicesSection(pairing: server.pairing),
      ],
    );
  }

  Widget _toggleRow(BuildContext context) {
    return _LabeledSwitch(
      label: S.settingsRemoteAccessEnabled,
      description: S.settingsRemoteAccessHealthHint,
      value: server.enabled,
      busy: server.isBusy,
      onChanged: (v) async => server.setEnabled(v),
    );
  }

  Widget _bindAllRow(BuildContext context) {
    return _LabeledSwitch(
      label: S.settingsRemoteAccessBindAll,
      description: S.settingsRemoteAccessBindAllDesc,
      value: server.bindAll,
      // Restart while busy is jarring; gate on isBusy too.
      busy: server.isBusy,
      onChanged: (v) async => server.setBindAll(v),
    );
  }

  Widget _statusCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _statusDot(),
              const SizedBox(width: 8),
              Text(
                _statusText(),
                style: const TextStyle(
                  fontSize: 12,
                  color: DuckColors.fgPrimary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (server.isRunning) ...[
                const Spacer(),
                _copyHealthUrlButton(context),
              ],
            ],
          ),
          const SizedBox(height: 12),
          _kvRow(S.settingsRemoteAccessInstanceName, server.instanceName),
          const SizedBox(height: 6),
          _kvRow(
            S.settingsRemoteAccessInstanceId,
            server.instanceId,
            mono: true,
          ),
        ],
      ),
    );
  }

  Widget _statusDot() {
    Color c;
    if (server.isBusy) {
      c = DuckColors.stateWarn;
    } else if (server.isRunning) {
      c = DuckColors.stateOk;
    } else if (server.lastError != null) {
      c = DuckColors.stateError;
    } else {
      c = DuckColors.fgSubtle;
    }
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(color: c, shape: BoxShape.circle),
    );
  }

  String _statusText() {
    if (server.isBusy) return S.settingsRemoteAccessStarting;
    if (server.isRunning) {
      // When bound to all, the displayed host is `0.0.0.0` which
      // isn't a real connect target. Show "All interfaces" instead
      // so the user doesn't paste 0.0.0.0 into a phone and wonder
      // why it doesn't work; the per-interface URLs live below in
      // the reachable-URLs card.
      final host = server.bindAll ? 'all interfaces' : server.boundHost;
      return '${S.settingsRemoteAccessRunningOn} $host:${server.boundPort}';
    }
    if (!server.enabled) return S.settingsRemoteAccessDisabled;
    return S.settingsRemoteAccessNotRunning;
  }

  Widget _copyHealthUrlButton(BuildContext context) {
    // Use the *display* host: the loopback URL when bound to
    // loopback, the LAN/Tailscale URL the user picked from the
    // reachable-URLs card otherwise. We don't know which one the
    // user prefers when bound to all, so default to the literal
    // bound host (`0.0.0.0`) and trust the reachable-URLs card to
    // surface useful copies. For loopback we copy the canonical
    // 127.0.0.1 form.
    final host = server.bindAll ? '127.0.0.1' : server.boundHost;
    final url = 'http://$host:${server.boundPort}/v1/health';
    return IconButton(
      icon: const Icon(Icons.copy_outlined, size: 14),
      tooltip: url,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints.tightFor(width: 26, height: 22),
      color: DuckColors.fgMuted,
      onPressed: () async {
        await Clipboard.setData(ClipboardData(text: url));
        if (!context.mounted) return;
        showDuckToast(context, url);
      },
    );
  }

  Widget _kvRow(String key, String value, {bool mono = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 110,
          child: Text(
            key,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgMuted,
              letterSpacing: 0.3,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(
              fontSize: mono ? 11.5 : 12,
              color: DuckColors.fgPrimary,
              fontFamily: mono ? 'monospace' : null,
            ),
          ),
        ),
      ],
    );
  }

  Widget _errorCard(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DuckColors.stateError.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.stateError.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline,
              size: 16, color: DuckColors.stateError),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              server.lastError ?? '',
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgPrimary,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String label) {
    return Text(
      label.toUpperCase(),
      style: const TextStyle(
        fontSize: 11,
        letterSpacing: 1.2,
        fontWeight: FontWeight.w600,
        color: DuckColors.fgSubtle,
      ),
    );
  }
}

/// Reusable label+description+switch row. Used by the master toggle
/// and the bind-to-LAN sub-toggle.
class _LabeledSwitch extends StatelessWidget {
  const _LabeledSwitch({
    required this.label,
    required this.description,
    required this.value,
    required this.busy,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final bool busy;
  final Future<void> Function(bool) onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  description,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          Switch.adaptive(
            value: value,
            onChanged: busy ? null : (v) async => await onChanged(v),
            activeThumbColor: DuckColors.accentCyan,
          ),
        ],
      ),
    );
  }
}

class _PlainHttpBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
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
        children: const [
          Icon(Icons.lock_open_outlined,
              size: 16, color: DuckColors.stateWarn),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              S.settingsRemoteAccessPlainHttpBanner,
              style: TextStyle(
                fontSize: 11.5,
                color: DuckColors.fgPrimary,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Lists every non-loopback IPv4 interface so the user can grab the
/// LAN IP or Tailscale `100.x.y.z` address with one click. We rebuild
/// the list on construct because interface state can change between
/// "enable" clicks (Tailscale restart, wifi swap). Cheap call —
/// `NetworkInterface.list` reads the OS table once.
class _ReachableUrlsCard extends StatefulWidget {
  const _ReachableUrlsCard({required this.port});
  final int port;

  @override
  State<_ReachableUrlsCard> createState() => _ReachableUrlsCardState();
}

class _ReachableUrlsCardState extends State<_ReachableUrlsCard> {
  late Future<List<_InterfaceUrl>> _future;

  @override
  void initState() {
    super.initState();
    _future = _loadInterfaces();
  }

  @override
  void didUpdateWidget(_ReachableUrlsCard old) {
    super.didUpdateWidget(old);
    if (old.port != widget.port) {
      _future = _loadInterfaces();
    }
  }

  Future<List<_InterfaceUrl>> _loadInterfaces() async {
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.IPv4,
      );
      final out = <_InterfaceUrl>[];
      for (final i in ifaces) {
        for (final a in i.addresses) {
          out.add(_InterfaceUrl(name: i.name, address: a.address));
        }
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            S.settingsRemoteAccessReachableUrls,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.6,
              color: DuckColors.fgSubtle,
            ),
          ),
          const SizedBox(height: 10),
          FutureBuilder<List<_InterfaceUrl>>(
            future: _future,
            builder: (context, snap) {
              if (!snap.hasData) {
                return const SizedBox(
                  height: 16,
                  child: LinearProgressIndicator(),
                );
              }
              final data = snap.data!;
              if (data.isEmpty) {
                return const Text(
                  S.settingsRemoteAccessNoInterfaces,
                  style: TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                  ),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final u in data) _UrlRow(iface: u, port: widget.port),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _InterfaceUrl {
  _InterfaceUrl({required this.name, required this.address});
  final String name;
  final String address;
}

class _UrlRow extends StatelessWidget {
  const _UrlRow({required this.iface, required this.port});
  final _InterfaceUrl iface;
  final int port;

  @override
  Widget build(BuildContext context) {
    final url = 'http://${iface.address}:$port';
    final isTailscale = iface.address.startsWith('100.') ||
        iface.name.toLowerCase().contains('tailscale');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          if (isTailscale)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.shield_outlined,
                  size: 13, color: DuckColors.accentCyan),
            ),
          Expanded(
            child: SelectableText(
              url,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 11.5,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            iface.name,
            style: const TextStyle(
              fontSize: 10,
              color: DuckColors.fgSubtle,
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 13),
            tooltip: url,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 22, height: 20),
            color: DuckColors.fgMuted,
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (!context.mounted) return;
              showDuckToast(context, url);
            },
          ),
        ],
      ),
    );
  }
}

class _PairingSection extends StatelessWidget {
  const _PairingSection({required this.server});
  final LumenServer server;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          S.settingsRemoteAccessPairing.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.6,
            color: DuckColors.fgSubtle,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          S.settingsRemoteAccessPairingDesc,
          style: const TextStyle(
            fontSize: 12,
            color: DuckColors.fgMuted,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: ElevatedButton.icon(
            icon: const Icon(Icons.qr_code_2_outlined, size: 16),
            label: const Text(
              S.settingsRemoteAccessShowCode,
              style: TextStyle(fontSize: 12),
            ),
            // Disabled when the server isn't running — pairing
            // without a server up is meaningless and would just
            // confuse the user with an unreachable code.
            onPressed: server.isRunning
                ? () => PairingDialog.show(context, server.pairing)
                : null,
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.accentCyan,
              foregroundColor: DuckColors.bgDeepest,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PairedDevicesSection extends StatelessWidget {
  const _PairedDevicesSection({required this.pairing});
  final LumenPairingService pairing;

  @override
  Widget build(BuildContext context) {
    final devices = pairing.devices;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                S.settingsRemoteAccessPairedDevices.toUpperCase(),
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.6,
                  color: DuckColors.fgSubtle,
                ),
              ),
            ),
            if (devices.isNotEmpty)
              TextButton(
                onPressed: () => _confirmRevokeAll(context),
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  foregroundColor: DuckColors.stateError,
                  textStyle: const TextStyle(fontSize: 11),
                ),
                child: const Text(S.settingsRemoteAccessRevokeAll),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (devices.isEmpty)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: DuckColors.bgRaised.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
              border: Border.all(color: DuckColors.glassSeam, width: 0.6),
            ),
            child: const Text(
              S.settingsRemoteAccessNoPairedDevices,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          )
        else
          for (final d in devices) _DeviceRow(device: d, pairing: pairing),
      ],
    );
  }

  Future<void> _confirmRevokeAll(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(S.settingsRemoteAccessRevokeAll),
        content: const Text(
          'All paired devices will lose access. Each will need to '
          'pair again with a fresh code.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: DuckColors.stateError),
            child: const Text(S.settingsRemoteAccessRevokeAll),
          ),
        ],
      ),
    );
    if (ok == true) {
      await pairing.revokeAll();
    }
  }
}

class _DeviceRow extends StatelessWidget {
  const _DeviceRow({required this.device, required this.pairing});
  final PairedDevice device;
  final LumenPairingService pairing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Row(
        children: [
          const Icon(Icons.smartphone_outlined,
              size: 16, color: DuckColors.fgMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  device.name,
                  style: const TextStyle(
                    fontSize: 13,
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${S.settingsRemoteAccessLastSeen}: '
                  '${_relTime(device.lastSeenAt)}',
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => pairing.revokeDevice(device.id),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: DuckColors.stateError,
              textStyle: const TextStyle(fontSize: 11),
            ),
            child: const Text(S.settingsRemoteAccessRevoke),
          ),
        ],
      ),
    );
  }

  String _relTime(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inSeconds < 60) return '${d.inSeconds}s ago';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    if (d.inDays < 7) return '${d.inDays}d ago';
    return t.toIso8601String().split('T').first;
  }
}
