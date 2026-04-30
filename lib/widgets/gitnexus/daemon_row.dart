import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/gitnexus_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Which long-running GitNexus daemon a [GitNexusDaemonRow] controls.
///
///   - [serve] → `npx gitnexus serve` (HTTP server on `127.0.0.1:4747`).
///               Machine-wide and *adoptable* — see [GitNexusService]
///               for why we only ever want one of these per machine.
///   - [mcp]   → `npx gitnexus mcp` (stdio MCP server). Per-window;
///               most AI hosts spawn their own and ignore this toggle.
enum GitNexusDaemonKind { serve, mcp }

/// Settings-row controller for one of the persistent GitNexus
/// background services. Renders:
///   - title + description text,
///   - status pill (running / starting / stopped / port info),
///   - on/off switch,
///   - inline log tail (capped at the service's 4KB tail window).
///
/// Subscribes directly to the [GitNexusService] `ChangeNotifier` via
/// `ListenableBuilder` so live state changes (process exit, output
/// arrival) refresh this widget without forcing the entire Settings
/// tab to rebuild.
class GitNexusDaemonRow extends StatelessWidget {
  final GitNexusService service;
  final GitNexusDaemonKind kind;
  final bool workspaceOpen;

  const GitNexusDaemonRow({
    super.key,
    required this.service,
    required this.kind,
    required this.workspaceOpen,
  });

  bool _isRunning() => switch (kind) {
        GitNexusDaemonKind.serve => service.serveRunning,
        GitNexusDaemonKind.mcp => service.mcpRunning,
      };

  bool _isStarting() => switch (kind) {
        GitNexusDaemonKind.serve => service.serveStarting,
        GitNexusDaemonKind.mcp => service.mcpStarting,
      };

  String _outputTail() => switch (kind) {
        GitNexusDaemonKind.serve => service.serveOutputTail,
        GitNexusDaemonKind.mcp => service.mcpOutputTail,
      };

  String _title() => switch (kind) {
        GitNexusDaemonKind.serve => S.gitnexusServeTitle,
        GitNexusDaemonKind.mcp => S.gitnexusMcpTitle,
      };

  String _description() => switch (kind) {
        GitNexusDaemonKind.serve => S.gitnexusServeDesc,
        GitNexusDaemonKind.mcp => S.gitnexusMcpDesc,
      };

  String _outputLabel() => switch (kind) {
        GitNexusDaemonKind.serve => S.gitnexusServeOutputLabel,
        GitNexusDaemonKind.mcp => S.gitnexusMcpOutputLabel,
      };

  Color _accent() => switch (kind) {
        GitNexusDaemonKind.serve => DuckColors.accentMint,
        GitNexusDaemonKind.mcp => DuckColors.accentPurple,
      };

  Future<void> _onToggle(bool wanted) async {
    switch (kind) {
      case GitNexusDaemonKind.serve:
        await service.setServeRunning(wanted);
      case GitNexusDaemonKind.mcp:
        await service.setMcpRunning(wanted);
    }
  }

  /// Serve survives without a workspace because it's machine-wide;
  /// mcp still needs a workspace because we run it via `npx` from
  /// the workspace directory and most users only ever want it scoped.
  bool get _requiresWorkspace => kind == GitNexusDaemonKind.mcp;

  /// Machine-wide adopted state only applies to the serve daemon —
  /// mcp is a stdio pipe and can't be adopted across processes.
  bool _isAdopted() =>
      kind == GitNexusDaemonKind.serve && service.serveAdopted;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) {
        final running = _isRunning();
        final starting = _isStarting();
        final adopted = _isAdopted();
        final accent = _accent();
        final canToggle = _requiresWorkspace ? workspaceOpen : true;
        return Container(
          constraints: const BoxConstraints(maxWidth: 820),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            border: Border.all(
              color: running
                  ? accent.withValues(alpha: 0.45)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(top: 6, right: 10),
                    decoration: BoxDecoration(
                      color: running ? accent : DuckColors.fgSubtle,
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _title(),
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: DuckColors.fgPrimary,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _description(),
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: DuckColors.fgMuted,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            _statusPill(running, starting, adopted, accent),
                            if (kind == GitNexusDaemonKind.serve && running)
                              _portPill(service.servePort, adopted),
                          ],
                        ),
                        if (adopted) ...[
                          const SizedBox(height: 8),
                          Text(
                            S.gitnexusServeAdoptedHint,
                            style: const TextStyle(
                              fontSize: 11,
                              color: DuckColors.fgMuted,
                              height: 1.4,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  Switch(
                    value: running || starting,
                    onChanged: canToggle ? _onToggle : null,
                    activeThumbColor: accent,
                  ),
                ],
              ),
              if (!canToggle) ...[
                const SizedBox(height: 8),
                Text(
                  S.gitnexusDaemonNoWorkspace,
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.stateWarn,
                    height: 1.4,
                  ),
                ),
              ],
              if (running || starting || _outputTail().isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  _outputLabel(),
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: DuckColors.fgFaint,
                  ),
                ),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(minHeight: 80),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: DuckColors.bgDeepest,
                    borderRadius: BorderRadius.circular(DuckTheme.radiusS),
                    border: Border.all(
                      color: DuckColors.glassSeam,
                      width: 0.5,
                    ),
                  ),
                  child: SelectableText(
                    _outputTail().isEmpty
                        ? '(no output yet)'
                        : _outputTail(),
                    style: const TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 11,
                      color: DuckColors.fgSubtle,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _statusPill(bool running, bool starting, bool adopted, Color accent) {
    final (label, color) = switch ((running, starting, adopted)) {
      (true, _, true) => (S.gitnexusServeRunningAdoptedLabel, accent),
      (true, _, _) => (S.gitnexusStatusRunning, accent),
      (_, true, _) => (S.gitnexusServeStarting, DuckColors.accentCyan),
      _ => (S.gitnexusServeStopped, DuckColors.fgMuted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10.5,
          fontWeight: FontWeight.w700,
          color: color,
          letterSpacing: 0.4,
        ),
      ),
    );
  }

  Widget _portPill(int port, bool adopted) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Text(
        adopted ? '127.0.0.1:$port · shared' : '127.0.0.1:$port',
        style: const TextStyle(
          fontFamily: DuckTheme.monoFont,
          fontSize: 10.5,
          fontWeight: FontWeight.w600,
          color: DuckColors.fgMuted,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}
