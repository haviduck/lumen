import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart';
import 'package:xterm/xterm.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../providers/ssh_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'ssh_remote_file_browser_dialog.dart';
import 'ssh_session_picker.dart';
import 'ssh_upload_dialog.dart';

/// "Remote" pane — sits in the editor right-slot's vertical split as
/// the SSH counterpart to the Teams/media pane. Renders a tab strip
/// for multiple connected SSH hosts and an `xterm.TerminalView` for
/// the active session. Supports drag-and-drop file upload (from the
/// OS or the file explorer) into the active session's host.
///
/// **Why it lives here, not in `TerminalPane`**: terminal pane is the
/// canonical home for *local* shells. SSH is conceptually a different
/// surface — different connection lifecycle, different ergonomics
/// (you stay focused on it longer), different drop semantics (drop
/// = upload, not the local "drop = open file in editor"). Splitting
/// the panes also lets the user see local + remote side-by-side
/// during pair-debugging. See `.agents/knowledgebase.md` § SSH.
class RemotePane extends StatefulWidget {
  const RemotePane({super.key});

  @override
  State<RemotePane> createState() => _RemotePaneState();
}

class _RemotePaneState extends State<RemotePane> {
  /// True while the user is mid-drag with files from the OS desktop /
  /// Explorer. Drives the cyan drop overlay. Updated by
  /// super_drag_and_drop's `onDropEnter` / `onDropLeave`.
  bool _osDragging = false;

  /// True while the user is mid-drag from Lumen's own file explorer
  /// (or any other in-app `Draggable<String>` carrying an absolute
  /// path payload). Updated by the inner `DragTarget<String>`. Kept
  /// separate from `_osDragging` because the two systems fire
  /// independent enter/exit events and we don't want one stream to
  /// stomp the other's overlay state if the user drags from the
  /// explorer to the terminal area mid-OS-drag (rare but possible
  /// when juggling external tools).
  bool _internalDragging = false;

  bool get _showDropOverlay => _osDragging || _internalDragging;

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshController>();

    return Container(
      color: DuckColors.bgDeepest,
      child: Column(
        children: [
          _RemotePaneChrome(ssh: ssh),
          Expanded(
            child: ssh.sessions.isEmpty
                ? const _RemoteEmptyState()
                : _buildBody(ssh),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(SshController ssh) {
    final activeId = ssh.activeSessionId;
    final active = activeId == null
        ? ssh.sessions.first
        : ssh.sessions.firstWhere(
            (s) => s.id == activeId,
            orElse: () => ssh.sessions.first,
          );

    // Two independent drop systems, layered:
    //
    //   OUTER  — `super_drag_and_drop` `DropRegion` for OS-level
    //            drops (Explorer / Finder / GNOME Files / archive
    //            viewers like WinRAR). Native drag protocol via the
    //            Win32 / Cocoa / GTK IDropTarget shim; separate from
    //            Flutter's in-app pointer system.
    //   INNER  — Flutter `DragTarget<String>` for in-app drags from
    //            Lumen's file explorer (`_TolerantDraggable<String>`
    //            carries `widget.file.path`). This is plain-ass
    //            Flutter pointer-based drag, never sees OS DnD events.
    //
    // They CAN'T conflict because the underlying systems are
    // disjoint, but rendering-wise we share one cyan drop overlay
    // gated on `_showDropOverlay = _osDragging || _internalDragging`.
    return DropRegion(
      // Only accept items that resolve to a real on-disk path.
      // The SSH upload path needs a local file to scp/sftp — we
      // explicitly do NOT extract virtual files here because the
      // user's intent ("upload this archive entry to the host")
      // would silently lose the archive context (the dropped entry
      // is just one file, not the whole archive). If that's wanted
      // later, fall back to a temp-file extract like the chat
      // composer does and route through `_handleDroppedFiles`.
      formats: const [Formats.fileUri],
      hitTestBehavior: HitTestBehavior.opaque,
      onDropOver: (event) {
        for (final item in event.session.items) {
          if (item.canProvide(Formats.fileUri)) return DropOperation.copy;
        }
        return DropOperation.none;
      },
      onDropEnter: (_) => setState(() => _osDragging = true),
      onDropLeave: (_) => setState(() => _osDragging = false),
      onPerformDrop: (event) async {
        setState(() => _osDragging = false);
        final paths = <String>[];
        final pendingReads = <Completer<void>>[];
        for (final item in event.session.items) {
          if (!item.canProvide(Formats.fileUri)) continue;
          final reader = item.dataReader;
          if (reader == null) continue;
          final completer = Completer<void>();
          pendingReads.add(completer);
          reader.getValue<Uri>(
            Formats.fileUri,
            (uri) {
              if (uri != null) paths.add(uri.toFilePath());
              if (!completer.isCompleted) completer.complete();
            },
            onError: (e) {
              debugPrint('[Lumen ssh-drop] read failed: $e');
              if (!completer.isCompleted) completer.complete();
            },
          );
        }
        // Wait for every fileUri to resolve before kicking off the
        // upload. Unlike the file-explorer drop, here we DO need the
        // full path list up front — the upload dialog is one modal
        // covering ALL dropped files, not a per-file ingestion.
        await Future.wait(pendingReads.map((c) => c.future));
        if (paths.isEmpty) return;
        await _handleDroppedFiles(ssh, active, paths);
      },
      child: DragTarget<String>(
        // We accept any path payload; the file-vs-dir branch is in
        // `_handleDroppedFiles` so the user gets a friendly toast
        // rather than a silent "directory drops aren't supported"
        // failure.
        onWillAcceptWithDetails: (_) {
          if (!_internalDragging) {
            setState(() => _internalDragging = true);
          }
          return true;
        },
        onLeave: (_) {
          if (_internalDragging) {
            setState(() => _internalDragging = false);
          }
        },
        onAcceptWithDetails: (details) async {
          setState(() => _internalDragging = false);
          await _handleDroppedFiles(ssh, active, [details.data]);
        },
        builder: (context, candidate, rejected) {
          return Stack(
            children: [
              Positioned.fill(child: _SessionTerminalView(entry: active)),
              if (_showDropOverlay)
                Positioned.fill(
                  child: IgnorePointer(
                    child: Container(
                      decoration: BoxDecoration(
                        color: DuckColors.accentCyan.withValues(alpha: 0.10),
                        border: Border.all(
                          color: DuckColors.accentCyan,
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: DuckColors.bgRaisedHi,
                          borderRadius:
                              BorderRadius.circular(DuckTheme.radiusM),
                          border: Border.all(
                            color: DuckColors.accentCyan,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              S.sshPaneDropHintFmt(active.host.displayName),
                              style: const TextStyle(
                                fontSize: 12.5,
                                color: DuckColors.fgPrimary,
                              ),
                            ),
                            // Show the resolved upload destination as
                            // a sub-line so users can see where the
                            // drop will land before they release. Pulls
                            // OSC-7-reported cwd if known, else the
                            // host's lastUploadDir, else $HOME guess.
                            const SizedBox(height: 4),
                            Text(
                              _resolveDestPreview(active),
                              style: const TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: DuckColors.fgMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// Best-known destination for "drop this file here" — read from
  /// the live session's OSC-7-reported cwd first (so users who have
  /// `cd`'d into a subdirectory see THAT path, not their home), then
  /// the host's persisted `lastUploadDir`, then a `$HOME/<user>`
  /// guess as last-ditch.
  static String _resolveDestPreview(SshSessionEntry entry) {
    final cwd = entry.lastKnownCwd;
    if (cwd != null && cwd.isNotEmpty) return cwd;
    final last = entry.host.lastUploadDir;
    if (last != null && last.isNotEmpty) return last;
    return '/home/${entry.host.user}/';
  }

  Future<void> _handleDroppedFiles(
    SshController ssh,
    SshSessionEntry session,
    List<String> paths,
  ) async {
    // Walk the dropped paths. Files become single-item plan entries;
    // directories get walked recursively and produce one plan item
    // per file, with `remoteRelativePath` preserving the dir layout.
    // Symlinks are skipped (no loop chasing). The dialog shows count
    // + total size so the user can bail before launching a 50k-file
    // node_modules upload by accident.
    final plan = await SshUploadPlan.fromPaths(paths);
    if (!mounted) return;
    if (plan.items.isEmpty) {
      // Either everything was unreadable, or the user dropped an
      // empty folder. Toast something concrete rather than silent.
      showDuckToast(
        context,
        plan.skippedSymlinks > 0 || plan.skippedUnreadable > 0
            ? S.sshUploadSkippedAllFmt(
                plan.skippedSymlinks,
                plan.skippedUnreadable,
              )
            : S.sshUploadFailed,
      );
      return;
    }
    await showSshUploadDialog(
      context,
      ssh: ssh,
      host: session.host,
      plan: plan,
      // Defaults to the session's OSC-7-reported cwd if known so the
      // dialog opens pre-pointed at "where the user is right now".
      preferredDestination: session.lastKnownCwd,
    );
  }
}

/// Chrome strip above the body: title + tab strip + actions.
class _RemotePaneChrome extends StatelessWidget {
  final SshController ssh;
  const _RemotePaneChrome({required this.ssh});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 30,
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const Icon(
            Icons.dns_outlined,
            size: 13,
            color: DuckColors.accentCyan,
          ),
          const SizedBox(width: 6),
          const Text(
            S.sshPaneTitle,
            style: TextStyle(
              fontSize: 10.5,
              letterSpacing: 0.6,
              color: DuckColors.fgMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: _TabStrip(ssh: ssh)),
          const SizedBox(width: 6),
          // Wrap in Builder so the dropdown anchors to the `+`
          // button's RenderBox specifically. Without this, the
          // dropdown would compute its position from the entire
          // chrome row's context — anchoring relative to the
          // pane's top-left edge, not the icon the user clicked.
          Builder(
            builder: (btnCtx) => _ChromeIconButton(
              icon: Icons.add,
              tooltip: S.sshPaneNewSession,
              onTap: () => showSshSessionPicker(btnCtx),
            ),
          ),
          if (ssh.sessions.isNotEmpty) ...[
            _ChromeIconButton(
              icon: Icons.folder_open_outlined,
              tooltip: S.sshOpenRemoteFile,
              onTap: () {
                final session = ssh.sessions.firstWhere(
                  (s) => s.id == ssh.activeSessionId,
                  orElse: () => ssh.sessions.first,
                );
                showSshRemoteFileBrowser(
                  context,
                  ssh: ssh,
                  hostId: session.host.id,
                );
              },
            ),
            // Shell helpers (`lumen-edit`, `lumen-grab`, OSC 7) are
            // now auto-injected by `SshController._runConnect` ~250ms
            // after each session connects, so the manual "install
            // helpers" icon + dialog has been retired. See
            // `autoInstallShellHelpersOneLiner` in
            // `ssh_terminal_pre_processor.dart` for the snippet
            // and the rationale (idempotent, bash/zsh-guarded,
            // single-line to keep echo noise minimal).
            _ChromeIconButton(
              icon: Icons.refresh,
              tooltip: S.sshPaneReconnect,
              onTap: () {
                final id = ssh.activeSessionId;
                if (id != null) {
                  ssh.reconnect(id);
                }
              },
            ),
            // Visual separator before the destructive "close all
            // sessions" button so it doesn't blend into the action
            // row. The pane itself disappears when the last session
            // closes (hasEditorMounted == hasSessions), so this is
            // also the "hide the SSH split" affordance.
            //
            // Note: a "Clear screen" button used to live here that
            // wrote `\x1bc\x1b[3J` to the active terminal, but the
            // sequences hit `xterm` 4.x's parser as no-ops on our
            // build — the button looked active but did nothing.
            // Removed v1.4.1 rather than carrying a dead control;
            // users can clear with `Ctrl+L` / `clear` in the shell.
            const SizedBox(width: 4),
            Container(
              width: 0.5,
              height: 14,
              color: DuckColors.glassSeam,
            ),
            const SizedBox(width: 4),
            _ChromeIconButton(
              icon: Icons.close,
              tooltip: S.sshPaneClosePane,
              danger: true,
              onTap: () => _confirmCloseAll(context, ssh),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _confirmCloseAll(
    BuildContext context,
    SshController ssh,
  ) async {
    if (ssh.sessions.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          side: const BorderSide(color: DuckColors.border, width: 0.5),
        ),
        title: const Text(
          S.sshPaneClosePaneConfirmTitle,
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        content: const Text(
          S.sshPaneClosePaneConfirmBody,
          style: TextStyle(fontSize: 12.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(S.cancel),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: DuckColors.stateError,
              foregroundColor: DuckColors.fgPrimary,
            ),
            child: const Text(S.sshPaneClosePane),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await ssh.closeAllSessions();
    }
  }
}

class _ChromeIconButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  /// When true, hover state tints with the error accent so the button
  /// reads as a destructive action (currently only "Close pane").
  final bool danger;
  const _ChromeIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.danger = false,
  });

  @override
  State<_ChromeIconButton> createState() => _ChromeIconButtonState();
}

class _ChromeIconButtonState extends State<_ChromeIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.danger
        ? DuckColors.stateError.withValues(alpha: 0.18)
        : DuckColors.bgRaisedHi.withValues(alpha: 0.62);
    final hoverFg = widget.danger ? DuckColors.stateError : DuckColors.fgPrimary;
    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: DuckMotion.fast,
            curve: DuckMotion.standard,
            margin: const EdgeInsets.symmetric(horizontal: 1),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            decoration: BoxDecoration(
              color: _hover ? hoverBg : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Icon(
              widget.icon,
              size: 14,
              color: _hover ? hoverFg : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _TabStrip extends StatelessWidget {
  final SshController ssh;
  const _TabStrip({required this.ssh});

  @override
  Widget build(BuildContext context) {
    if (ssh.sessions.isEmpty) {
      return const SizedBox.shrink();
    }
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final s in ssh.sessions)
            _SessionTab(
              ssh: ssh,
              entry: s,
              active: s.id == ssh.activeSessionId,
            ),
        ],
      ),
    );
  }
}

class _SessionTab extends StatefulWidget {
  final SshController ssh;
  final SshSessionEntry entry;
  final bool active;
  const _SessionTab({
    required this.ssh,
    required this.entry,
    required this.active,
  });

  @override
  State<_SessionTab> createState() => _SessionTabState();
}

class _SessionTabState extends State<_SessionTab> {
  bool _hover = false;

  Color get _accent {
    switch (widget.entry.state) {
      case SshSessionState.connecting:
        return DuckColors.accentCyan;
      case SshSessionState.connected:
        return DuckColors.accentMint;
      case SshSessionState.disconnected:
        return DuckColors.fgSubtle;
      case SshSessionState.failed:
        return DuckColors.stateError;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => widget.ssh.setActiveSession(widget.entry.id),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: widget.active
                ? DuckColors.bgRaisedHi
                : _hover
                    ? DuckColors.bgChip.withValues(alpha: 0.6)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(
              color: widget.active
                  ? DuckColors.accentCyan.withValues(alpha: 0.45)
                  : DuckColors.glassSeam,
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 6),
                decoration: BoxDecoration(
                  color: _accent,
                  shape: BoxShape.circle,
                ),
              ),
              Text(
                widget.entry.host.displayName,
                style: TextStyle(
                  fontSize: 11.5,
                  color: widget.active
                      ? DuckColors.fgPrimary
                      : DuckColors.fgMuted,
                ),
              ),
              const SizedBox(width: 6),
              // Per-tab close — sized + colored to be obviously
              // clickable (the original size:12 fgSubtle X was easy
              // to miss on the chrome bar; users assumed there was
              // no way to close a session). Hover state pops the
              // error accent so the click target is unambiguous.
              _TabCloseButton(
                onTap: () => widget.ssh.closeSession(widget.entry.id),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Compact per-tab close X. Stays muted at rest, pops the error
/// accent on hover so it doesn't disappear into the tab chrome.
class _TabCloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _TabCloseButton({required this.onTap});

  @override
  State<_TabCloseButton> createState() => _TabCloseButtonState();
}

class _TabCloseButtonState extends State<_TabCloseButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: S.sshPaneCloseSession,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: _hover
                  ? DuckColors.stateError.withValues(alpha: 0.22)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            ),
            child: Icon(
              Icons.close,
              size: 13,
              color: _hover ? DuckColors.stateError : DuckColors.fgMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps an `xterm.TerminalView` for a single SSH session. Same
/// shape as the terminal pane's `_buildTerminalView` minus the
/// ctrl-click URL plumbing (added later if users ask). Uses the
/// AppState's editor font size so the SSH terminal scales with the
/// rest of the IDE.
class _SessionTerminalView extends StatefulWidget {
  final SshSessionEntry entry;
  const _SessionTerminalView({required this.entry});

  @override
  State<_SessionTerminalView> createState() => _SessionTerminalViewState();
}

class _SessionTerminalViewState extends State<_SessionTerminalView> {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppState>();
    final entry = widget.entry;

    return TerminalView(
      entry.terminal,
      controller: entry.termCtrl,
      // `autofocus: true` so the very first session attaches focus
      // to the terminal — without this, characters typed before the
      // user has clicked anywhere are dropped on the floor.
      autofocus: true,
      // CRITICAL: hardware-keyboard-only path. xterm 4.x's default
      // "CustomTextEdit" path routes printable characters through
      // Flutter's IME / TextInput connection, which on Windows
      // desktop only opens after an explicit `requestKeyboard()`
      // tap on the terminal AND can race with other open
      // TextInputConnections (the chat panel, the code editor). The
      // observed symptom was Ctrl+C working (it's resolved by
      // CtrlInputHandler against HardwareKeyboard) but plain
      // letters being eaten because the IME never delivered them.
      // The hardware-only path uses `keyEvent.character` directly,
      // sidestepping IME entirely. Trade-off: no IME composition for
      // CJK input, but for a desktop SSH pane that's the right call.
      hardwareKeyboardOnly: true,
      textStyle: TerminalStyle(
        fontFamily: DuckTheme.monoFont,
        fontSize: appState.editorFontSize - 0.5,
      ),
      theme: const TerminalTheme(
        cursor: Color(0xFF8FBCBB),
        selection: Color(0x55434C5E),
        foreground: Color(0xFFD8DEE9),
        background: Color(0xFF191C22),
        black: Color(0xFF272C36),
        red: Color(0xFFBF616A),
        green: Color(0xFFA3BE8C),
        yellow: Color(0xFFEBCB8B),
        blue: Color(0xFF81A1C1),
        magenta: Color(0xFF7D7C9B),
        cyan: Color(0xFF88C0D0),
        white: Color(0xFFE5E9F0),
        brightBlack: Color(0xFF4C566A),
        brightRed: Color(0xFFBF616A),
        brightGreen: Color(0xFFA3BE8C),
        brightYellow: Color(0xFFEBCB8B),
        brightBlue: Color(0xFF81A1C1),
        brightMagenta: Color(0xFFB48EAD),
        brightCyan: Color(0xFF8FBCBB),
        brightWhite: Color(0xFFECEFF4),
        searchHitBackground: Color(0x6688C0D0),
        searchHitBackgroundCurrent: Color(0xCC88C0D0),
        searchHitForeground: Color(0xFF191C22),
      ),
      backgroundOpacity: 0,
      padding: const EdgeInsets.all(8),
      onSecondaryTapUp: (details, offset) {
        // Right-click: copy if there's a selection, else paste from
        // clipboard. Standard terminal-ish right-click ergonomics.
        final selection = entry.termCtrl.selection;
        if (selection != null) {
          final text = entry.terminal.buffer.getText(selection);
          Clipboard.setData(ClipboardData(text: text));
          entry.termCtrl.clearSelection();
          return;
        }
        Clipboard.getData(Clipboard.kTextPlain).then((data) {
          if (data?.text != null) {
            entry.terminal.paste(data!.text!);
          }
        });
      },
      onKeyEvent: (focusNode, event) {
        if (event is KeyDownEvent) {
          final ctrl = HardwareKeyboard.instance.isControlPressed;
          final shift = HardwareKeyboard.instance.isShiftPressed;
          if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.keyC) {
            final sel = entry.termCtrl.selection;
            if (sel != null) {
              final text = entry.terminal.buffer.getText(sel);
              Clipboard.setData(ClipboardData(text: text));
              entry.termCtrl.clearSelection();
              return KeyEventResult.handled;
            }
          }
          if (ctrl && shift && event.logicalKey == LogicalKeyboardKey.keyV) {
            Clipboard.getData(Clipboard.kTextPlain).then((data) {
              if (data?.text != null) {
                entry.terminal.paste(data!.text!);
              }
            });
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
    );
  }
}

class _RemoteEmptyState extends StatelessWidget {
  const _RemoteEmptyState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.dns_outlined,
            size: 32,
            color: DuckColors.fgFaint,
          ),
          const SizedBox(height: 10),
          const Text(
            S.sshPaneNoSessions,
            style: TextStyle(
              fontSize: 12.5,
              color: DuckColors.fgMuted,
            ),
          ),
          const SizedBox(height: 14),
          Builder(
            builder: (btnCtx) => OutlinedButton.icon(
              onPressed: () => showSshSessionPicker(btnCtx),
              icon: const Icon(Icons.add, size: 14),
              label: const Text(S.sshPaneNewSession),
              style: OutlinedButton.styleFrom(
                foregroundColor: DuckColors.fgPrimary,
                side: BorderSide(
                  color: DuckColors.glassSeam,
                  width: 0.6,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

