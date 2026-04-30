import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/app_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_theme.dart';
import 'common/duck_toast.dart';

/// Full-window blur overlay that prompts for the configured PIN.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key});

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final TextEditingController _pinCtrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _pinCtrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _attempt() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final ok = await context.read<AppState>().unlock(_pinCtrl.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!ok) {
        _error = S.lockWrong;
        _pinCtrl.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
              child: Container(color: Colors.black.withValues(alpha: 0.45)),
            ),
          ),
          Center(
            child: SizedBox(
              width: 360,
              child: _LockCardSurface(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        gradient: DuckColors.brandGradient,
                        shape: BoxShape.circle,
                        boxShadow: DuckTheme.shadowGlow,
                      ),
                      child: const Icon(
                        Icons.lock,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    const SizedBox(height: 14),
                    const Text(
                      S.lockTitle,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    const Text(
                      S.lockSubtitle,
                      style: TextStyle(color: DuckColors.fgMuted, fontSize: 12),
                    ),
                    const SizedBox(height: 20),
                    TextField(
                      controller: _pinCtrl,
                      focusNode: _focus,
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 16, letterSpacing: 8),
                      decoration: const InputDecoration(
                        hintText: S.lockEnterPin,
                      ),
                      onSubmitted: (_) => _attempt(),
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: DuckColors.stateError,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _busy ? null : _attempt,
                        child: _busy
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text(S.unlock),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockCardSurface extends StatelessWidget {
  final Widget child;

  const _LockCardSurface({required this.child});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(28),
        decoration: BoxDecoration(
          color: DuckColors.bgGlassHi,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(color: DuckColors.glassEdgeHi, width: 0.5),
          boxShadow: DuckTheme.shadowSoft,
        ),
        child: child,
      ),
    );
  }
}

/// Dialog for setting / changing / clearing the lock PIN.
class PinSetupDialog extends StatefulWidget {
  const PinSetupDialog({super.key});

  @override
  State<PinSetupDialog> createState() => _PinSetupDialogState();
}

class _PinSetupDialogState extends State<PinSetupDialog> {
  final _pinCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _pinCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    return AlertDialog(
      title: const Text(S.lockSetPin),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FutureBuilder<bool>(
              future: state.hasPin(),
              builder: (context, snapshot) {
                final hasPin = snapshot.data ?? false;
                return Column(
                  children: [
                    if (hasPin)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: TextButton.icon(
                          onPressed: () async {
                            await state.clearPin();
                            if (!context.mounted) return;
                            Navigator.pop(context);
                          },
                          icon: const Icon(Icons.lock_open, size: 14),
                          label: const Text(S.lockRemovePin),
                        ),
                      ),
                    TextField(
                      controller: _pinCtrl,
                      decoration: const InputDecoration(
                        labelText: S.lockSetPin,
                      ),
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: _confirmCtrl,
                      decoration: const InputDecoration(
                        labelText: S.lockConfirmPin,
                      ),
                      obscureText: true,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          _error!,
                          style: const TextStyle(color: DuckColors.stateError),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text(S.cancel),
        ),
        ElevatedButton(
          onPressed: () async {
            if (_pinCtrl.text.isEmpty) return;
            if (_pinCtrl.text != _confirmCtrl.text) {
              setState(() => _error = S.lockMismatch);
              return;
            }
            await state.setPin(_pinCtrl.text);
            if (!context.mounted) return;
            Navigator.pop(context);
            showDuckToast(context, S.success);
          },
          child: const Text(S.save),
        ),
      ],
    );
  }
}
