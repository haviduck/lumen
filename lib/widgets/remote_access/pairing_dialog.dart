import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../services/remote/lumen_pairing_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Modal that shows a freshly-minted 6-digit pairing code with a
/// live countdown, and auto-closes the moment a phone consumes it.
///
/// The dialog reads the live `pendingPairing` off the
/// [LumenPairingService] and rebuilds when the service notifies, so:
///   - Auto-close on consume happens because the service nulls
///     `pendingPairing` inside `consumeCode` and notifies; we observe
///     the transition and close ourselves.
///   - TTL countdown reads the same field — internal 1Hz timer just
///     drives a `setState` so the remaining-time label updates.
///
/// Cancel button calls `pairing.cancelCode()` so the modal dismissing
/// also invalidates the code (no "stale code rotting in memory after
/// the modal closes" failure mode).
class PairingDialog extends StatefulWidget {
  const PairingDialog({super.key, required this.pairing});

  final LumenPairingService pairing;

  static Future<void> show(BuildContext context, LumenPairingService pairing) {
    pairing.generateCode();
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PairingDialog(pairing: pairing),
    );
  }

  @override
  State<PairingDialog> createState() => _PairingDialogState();
}

class _PairingDialogState extends State<PairingDialog> {
  Timer? _ticker;
  bool _wasPending = true;

  @override
  void initState() {
    super.initState();
    widget.pairing.addListener(_onPairingChange);
    // 1Hz tick to drive the countdown re-render. The service
    // already drops `_pending` exactly when TTL expires; this
    // timer is purely visual.
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    widget.pairing.removeListener(_onPairingChange);
    super.dispose();
  }

  void _onPairingChange() {
    final pending = widget.pairing.pendingPairing;
    if (!mounted) return;
    if (_wasPending && pending == null) {
      // Either consumed (a device paired) or expired. Either way
      // dismiss; the panel underneath shows the new device or the
      // "expired" hint.
      _wasPending = false;
      // Surface a friendly toast on consume — distinguishes "phone
      // just paired" from "I clicked cancel" silently.
      // We can't reliably tell the two apart from inside the dialog;
      // showing the toast unconditionally on consume-or-expire is
      // close enough for v1.
      Navigator.of(context, rootNavigator: true).maybePop();
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final pending = widget.pairing.pendingPairing;
    return AlertDialog(
      backgroundColor: DuckColors.bgRaisedHi,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
      ),
      title: const Text(
        S.settingsRemoteAccessPairingCodeTitle,
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              S.settingsRemoteAccessPairingCodeBody,
              style: const TextStyle(
                fontSize: 12,
                color: DuckColors.fgMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            if (pending != null)
              _CodeDisplay(
                code: pending.code,
                onCopy: () async {
                  await Clipboard.setData(ClipboardData(text: pending.code));
                  if (!context.mounted) return;
                  showDuckToast(context, pending.code);
                },
              )
            else
              const _ExpiredOrCompleted(),
            const SizedBox(height: 12),
            if (pending != null) _Countdown(remaining: pending.remaining),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            widget.pairing.cancelCode();
            Navigator.of(context).maybePop();
          },
          child: const Text(S.cancel),
        ),
      ],
    );
  }
}

class _CodeDisplay extends StatelessWidget {
  const _CodeDisplay({required this.code, required this.onCopy});
  final String code;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Row(
        children: [
          Expanded(
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 22,
                letterSpacing: 6,
                fontWeight: FontWeight.w600,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.copy_outlined, size: 16),
            onPressed: onCopy,
            tooltip: S.copy,
            color: DuckColors.fgMuted,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

class _ExpiredOrCompleted extends StatelessWidget {
  const _ExpiredOrCompleted();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DuckColors.bgRaised,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.6),
      ),
      child: Row(
        children: const [
          Icon(Icons.timer_off_outlined, size: 16, color: DuckColors.fgMuted),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              S.settingsRemoteAccessPairingExpired,
              style: TextStyle(fontSize: 12, color: DuckColors.fgMuted),
            ),
          ),
        ],
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  const _Countdown({required this.remaining});
  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    final secs = remaining.inSeconds;
    return Text(
      '${S.settingsRemoteAccessPairingExpiresIn} ${secs}s',
      style: const TextStyle(
        fontSize: 11,
        color: DuckColors.fgSubtle,
      ),
    );
  }
}
