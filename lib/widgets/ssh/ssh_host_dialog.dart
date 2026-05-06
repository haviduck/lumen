import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/ssh_controller.dart';
import '../../services/ssh/ssh_host.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import 'ssh_host_key_prompt.dart';
import 'ssh_password_prompt.dart';

/// Add/edit a single SSH host. Returns the saved host on Save, null
/// on Cancel.
Future<SshHost?> showSshHostEditorDialog(
  BuildContext context, {
  SshHost? existing,
}) async {
  return showDialog<SshHost?>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _SshHostEditorDialog(existing: existing),
  );
}

class _SshHostEditorDialog extends StatefulWidget {
  final SshHost? existing;
  const _SshHostEditorDialog({this.existing});

  @override
  State<_SshHostEditorDialog> createState() => _SshHostEditorDialogState();
}

class _SshHostEditorDialogState extends State<_SshHostEditorDialog> {
  late TextEditingController _label;
  late TextEditingController _host;
  late TextEditingController _port;
  late TextEditingController _user;
  late TextEditingController _password;
  late TextEditingController _passphrase;
  late TextEditingController _keyPath;

  late SshAuthMethod _auth;
  late bool _remember;
  String? _testBanner;
  String? _testError;
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _label = TextEditingController(text: e?.label ?? '');
    _host = TextEditingController(text: e?.host ?? '');
    _port = TextEditingController(text: (e?.port ?? 22).toString());
    _user = TextEditingController(text: e?.user ?? '');
    _password = TextEditingController();
    _passphrase = TextEditingController();
    _keyPath = TextEditingController(text: e?.keyFilePath ?? '');
    _auth = e?.authMethod ?? SshAuthMethod.keyFile;
    _remember = e?.rememberSecret ?? true;
  }

  @override
  void dispose() {
    _label.dispose();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _passphrase.dispose();
    _keyPath.dispose();
    super.dispose();
  }

  Future<void> _pickKeyFile() async {
    final picked = await FilePicker.pickFiles(
      dialogTitle: S.sshHostFieldKeyFilePick,
      type: FileType.any,
      allowMultiple: false,
    );
    if (picked != null && picked.files.isNotEmpty) {
      final path = picked.files.first.path;
      if (path != null) {
        setState(() => _keyPath.text = path);
      }
    }
  }

  String? _validate() {
    if (_label.text.trim().isEmpty &&
        // For "name yourself by user@host" auto-fallback, the label
        // is optional. But if the user nukes label AND the auto-name
        // would be useless (no user), we hard-require the label.
        _user.text.trim().isEmpty) {
      return S.sshHostNameRequired;
    }
    if (_host.text.trim().isEmpty) return S.sshHostHostRequired;
    if (_user.text.trim().isEmpty) return S.sshHostUserRequired;
    if (_auth == SshAuthMethod.keyFile && _keyPath.text.trim().isNotEmpty) {
      if (!File(_keyPath.text.trim()).existsSync()) {
        return S.sshHostKeyMissing;
      }
    }
    return null;
  }

  SshHost _buildHost() {
    final port = int.tryParse(_port.text.trim()) ?? 22;
    final id = widget.existing?.id ??
        SshHost.generateId(
          label: _label.text.trim(),
          user: _user.text.trim(),
          host: _host.text.trim(),
          port: port,
        );
    return SshHost(
      id: id,
      label: _label.text.trim(),
      host: _host.text.trim(),
      port: port,
      user: _user.text.trim(),
      authMethod: _auth,
      keyFilePath: _auth == SshAuthMethod.keyFile
          ? _keyPath.text.trim()
          : '',
      rememberSecret: _remember,
      knownHostFingerprint: widget.existing?.knownHostFingerprint ?? '',
      lastConnectedAt: widget.existing?.lastConnectedAt,
      lastUploadDir: widget.existing?.lastUploadDir,
    );
  }

  Future<void> _testConnection() async {
    final err = _validate();
    if (err != null) {
      setState(() => _testError = err);
      return;
    }
    setState(() {
      _testing = true;
      _testBanner = null;
      _testError = null;
    });

    final ssh = context.read<SshController>();
    final draft = _buildHost();

    // The vault might not have this host yet (we're testing a draft).
    // Stash any user-typed secret into the secure store transiently
    // so the connect path doesn't hit `requestPassword` for a pre-typed
    // password. We clean up if the test fails.
    var stashedPassword = false;
    var stashedPassphrase = false;
    try {
      if (_auth == SshAuthMethod.password && _password.text.isNotEmpty) {
        await ssh.vault.savePassword(draft.id, _password.text);
        stashedPassword = true;
      }
      if (_auth == SshAuthMethod.keyFile && _passphrase.text.isNotEmpty) {
        await ssh.vault.savePassphrase(draft.id, _passphrase.text);
        stashedPassphrase = true;
      }

      // The vault won't know about the draft host yet, so we
      // upsert temporarily for the test, then roll back if the user
      // doesn't end up saving.
      final wasInVault = ssh.vault.findById(draft.id) != null;
      if (!wasInVault) {
        await ssh.vault.upsertHost(draft);
      }

      try {
        final banner = await ssh.clientService.testConnection(
          host: draft,
          hostKeyHandler: ({
            required host,
            required fingerprint,
            required firstTime,
          }) =>
              showSshHostKeyPrompt(
            context,
            host: host,
            fingerprint: fingerprint,
            firstTime: firstTime,
          ),
          requestPassword: (host) => showSshPasswordPrompt(
            context,
            host: host,
          ),
          requestPassphrase: (host) => showSshPasswordPrompt(
            context,
            host: host,
            passphrase: true,
          ),
        );
        if (mounted) {
          setState(() {
            _testBanner = banner.isEmpty ? S.sshHostTestSucceeded : banner;
          });
        }
      } finally {
        if (!wasInVault) {
          // Pull the draft back out unless the user has explicitly
          // saved by the time the test resolves; the Save button
          // path re-upserts on tap.
          await ssh.vault.removeHost(draft.id);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _testError = e.toString());
      }
      // On failure, wipe any stashed transient secrets so they don't
      // hang around in the secure store under a draft id.
      if (stashedPassword) {
        await ssh.vault.savePassword(draft.id, '');
      }
      if (stashedPassphrase) {
        await ssh.vault.savePassphrase(draft.id, '');
      }
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _save() async {
    final err = _validate();
    if (err != null) {
      setState(() => _testError = err);
      return;
    }
    final ssh = context.read<SshController>();
    final host = _buildHost();
    await ssh.upsertHost(host);

    if (_remember) {
      if (_auth == SshAuthMethod.password && _password.text.isNotEmpty) {
        await ssh.vault.savePassword(host.id, _password.text);
      }
      if (_auth == SshAuthMethod.keyFile && _passphrase.text.isNotEmpty) {
        await ssh.vault.savePassphrase(host.id, _passphrase.text);
      }
    }

    if (mounted) Navigator.of(context).pop(host);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: DuckColors.bgRaised,
      title: Text(
        widget.existing == null ? S.sshAddHost : S.sshEditHost,
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Field(
                label: S.sshHostFieldLabel,
                controller: _label,
                hint: 'prod-vm',
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: _Field(
                      label: S.sshHostFieldHost,
                      controller: _host,
                      hint: 'example.com',
                      mono: true,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    flex: 1,
                    child: _Field(
                      label: S.sshHostFieldPort,
                      controller: _port,
                      hint: '22',
                      mono: true,
                      numericOnly: true,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _Field(
                label: S.sshHostFieldUser,
                controller: _user,
                hint: 'root',
                mono: true,
              ),
              const SizedBox(height: 12),
              const Text(
                S.sshHostFieldAuthMethod,
                style: TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgMuted,
                ),
              ),
              const SizedBox(height: 4),
              SegmentedButton<SshAuthMethod>(
                segments: const [
                  ButtonSegment(
                    value: SshAuthMethod.keyFile,
                    label: Text(S.sshHostAuthKeyFile),
                  ),
                  ButtonSegment(
                    value: SshAuthMethod.password,
                    label: Text(S.sshHostAuthPassword),
                  ),
                  ButtonSegment(
                    value: SshAuthMethod.agent,
                    label: Text(S.sshHostAuthAgent),
                  ),
                ],
                selected: {_auth},
                onSelectionChanged: (s) =>
                    setState(() => _auth = s.first),
              ),
              const SizedBox(height: 10),
              if (_auth == SshAuthMethod.keyFile) ...[
                Row(
                  children: [
                    Expanded(
                      child: _Field(
                        label: S.sshHostFieldKeyFile,
                        controller: _keyPath,
                        hint: r'C:\Users\you\.ssh\id_ed25519',
                        mono: true,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 16),
                      child: OutlinedButton(
                        onPressed: _pickKeyFile,
                        child: const Text('...'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                _Field(
                  label: S.sshHostFieldPassphrase,
                  controller: _passphrase,
                  obscure: true,
                ),
              ],
              if (_auth == SshAuthMethod.password) ...[
                _Field(
                  label: S.sshHostFieldPassword,
                  controller: _password,
                  obscure: true,
                ),
              ],
              if (_auth != SshAuthMethod.agent) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Checkbox(
                      value: _remember,
                      onChanged: (v) =>
                          setState(() => _remember = v ?? true),
                    ),
                    const Text(
                      S.sshHostFieldRemember,
                      style: TextStyle(
                        fontSize: 12,
                        color: DuckColors.fgPrimary,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              if (_testing)
                const SizedBox(
                  height: 14,
                  width: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.6,
                    color: DuckColors.accentCyan,
                  ),
                )
              else if (_testBanner != null)
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DuckColors.accentMint.withValues(alpha: 0.10),
                    border: Border.all(
                      color: DuckColors.accentMint.withValues(alpha: 0.45),
                      width: 0.5,
                    ),
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                  ),
                  child: Text(
                    _testBanner!,
                    style: const TextStyle(
                      fontSize: 11.5,
                      fontFamily: 'monospace',
                      color: DuckColors.accentMint,
                    ),
                  ),
                )
              else if (_testError != null)
                Text(
                  _testError!,
                  style: const TextStyle(
                    fontSize: 11.5,
                    color: DuckColors.stateError,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(S.cancel),
        ),
        OutlinedButton(
          onPressed: _testing ? null : _testConnection,
          child: const Text(S.sshHostTestConnection),
        ),
        ElevatedButton(
          onPressed: _testing ? null : _save,
          child: const Text(S.sshHostSave),
        ),
      ],
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final bool mono;
  final bool obscure;
  final bool numericOnly;
  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.mono = false,
    this.obscure = false,
    this.numericOnly = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 11,
            color: DuckColors.fgMuted,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          obscureText: obscure,
          keyboardType:
              numericOnly ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(
            hintText: hint,
            isDense: true,
          ),
          style: TextStyle(
            fontFamily: mono ? 'monospace' : null,
            fontSize: 12.5,
          ),
        ),
      ],
    );
  }
}
