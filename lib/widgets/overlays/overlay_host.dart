import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state.dart';
import '../../services/file_index.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';
import 'command_palette.dart';
import 'global_search.dart';
import 'quick_open.dart';

/// Mounts modal overlays (Command Palette, Quick Open File, Global Search)
/// once at the IDE shell level and exposes "open me" callbacks via
/// [IdeActions]. The actual overlays live as siblings of the regular IDE
/// chrome — they are rendered when their flag is on, and the host owns
/// the `FileIndex` so the work to walk the workspace happens once.
class OverlayHost extends StatefulWidget {
  final Widget child;
  const OverlayHost({super.key, required this.child});

  @override
  State<OverlayHost> createState() => _OverlayHostState();
}

enum _ActiveOverlay { none, commandPalette, quickOpen, globalSearch }

class _OverlayHostState extends State<OverlayHost>
    with SingleTickerProviderStateMixin {
  _ActiveOverlay _active = _ActiveOverlay.none;
  FileIndex? _index;
  String? _indexedFor;
  late final AnimationController _entrance = AnimationController(
    vsync: this,
    duration: DuckMotion.medium,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      context.read<AppState>().ideActions.registerOverlayActions(
            openCommandPalette: () => _open(_ActiveOverlay.commandPalette),
            openQuickOpen: () => _open(_ActiveOverlay.quickOpen),
            openGlobalSearch: () => _open(_ActiveOverlay.globalSearch),
          );
    });
  }

  @override
  void dispose() {
    try {
      context.read<AppState>().ideActions.unregisterOverlayActions();
    } catch (_) {
      // context may be unmounted; safe to ignore.
    }
    _entrance.dispose();
    super.dispose();
  }

  void _open(_ActiveOverlay which) {
    final state = context.read<AppState>();
    final wd = state.currentDirectory;
    if (wd == null) return;
    if (_indexedFor != wd) {
      _index = FileIndex(wd);
      _indexedFor = wd;
      _index!.build();
    }
    setState(() => _active = which);
    if (state.reduceMotion) {
      _entrance.value = 1.0;
    } else {
      _entrance.forward(from: 0);
    }
  }

  void _close() {
    if (_active == _ActiveOverlay.none) return;
    _entrance.value = 0;
    setState(() => _active = _ActiveOverlay.none);
  }

  @override
  Widget build(BuildContext context) {
    final wd = context.watch<AppState>().currentDirectory;
    if (_indexedFor != null && wd != _indexedFor) {
      _index = null;
      _indexedFor = null;
      if (_active != _ActiveOverlay.none) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _close();
        });
      }
    }
    return Stack(
      children: [
        widget.child,
        if (_active != _ActiveOverlay.none) _buildOverlay(),
      ],
    );
  }

  Widget _buildOverlay() {
    final overlay = switch (_active) {
      _ActiveOverlay.commandPalette => CommandPalette(onClose: _close),
      _ActiveOverlay.quickOpen => QuickOpen(
          index: _index!,
          onClose: _close,
        ),
      _ActiveOverlay.globalSearch => GlobalSearch(
          index: _index!,
          onClose: _close,
        ),
      _ActiveOverlay.none => const SizedBox.shrink(),
    };
    return Positioned.fill(
      child: Shortcuts(
        shortcuts: const <ShortcutActivator, Intent>{
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: Actions(
          actions: <Type, Action<Intent>>{
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                _close();
                return null;
              },
            ),
          },
          child: Stack(
            children: [
              // Animated barrier — fades in alongside the dialog.
              FadeTransition(
                opacity: CurvedAnimation(
                  parent: _entrance,
                  curve: DuckMotion.standard,
                ),
                child: ModalBarrier(
                  color: Colors.black.withValues(alpha: 0.45),
                  onDismiss: _close,
                  dismissible: true,
                ),
              ),
              Align(
                alignment: const Alignment(0, -0.5),
                child: ConstrainedBox(
                  constraints:
                      const BoxConstraints(maxWidth: 720, maxHeight: 460),
                  child: Material(
                    color: Colors.transparent,
                    // Scale + fade entrance. The 0.96 → 1.0 scale is small
                    // enough that the eye reads it as "settling in" rather
                    // than zooming.
                    child: AnimatedBuilder(
                      animation: _entrance,
                      builder: (context, child) {
                        final t = CurvedAnimation(
                          parent: _entrance,
                          curve: DuckMotion.standard,
                        ).value;
                        return Opacity(
                          opacity: t,
                          child: Transform.scale(
                            scale: 0.96 + 0.04 * t,
                            child: child,
                          ),
                        );
                      },
                      child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 24),
                        child: DuckGlass.hero(
                          borderColor: DuckColors.borderStrong,
                          child: overlay,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
