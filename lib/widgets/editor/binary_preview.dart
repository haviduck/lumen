import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../../l10n/strings.dart';
import '../../services/file_kind.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Editor pane stand-in for non-text files (images / audio / video /
/// other binary blobs).
///
/// Why this exists at all: clicking a JPG used to call
/// `File.readAsString()` in `AppState.openFile`, which threw
/// `FileSystemException: Failed to decode data using encoding
/// 'utf-8'`. The error string was then dumped into the editor body —
/// confusing and unactionable. Now we route by extension to one of
/// the previews below:
///
/// - `image` → `_ImagePreview` renders `Image.file(...)` with
///   `BoxFit.contain` so the entire image is visible regardless of
///   viewport size, plus a small info strip (filename + size +
///   pixel dimensions once the image decodes).
/// - `audio` / `video` / `binary` → `_GenericBinaryCard` shows an
///   icon + name + size + an "Open externally" button that hands
///   the file to the OS default app via Windows `cmd /c start`,
///   macOS `open`, or Linux `xdg-open`. Native playback inside
///   Flutter desktop is its own multi-day quagmire (webview_flutter
///   doesn't ship a working Windows player; media_kit + yt-dlp
///   carries massive maintenance tax) and intentionally skipped.
class BinaryPreviewPane extends StatelessWidget {
  final File file;
  final FileKind kind;
  final VoidCallback onFocus;

  const BinaryPreviewPane({
    super.key,
    required this.file,
    required this.kind,
    required this.onFocus,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: (_) => onFocus(),
      child: Container(
        color: DuckColors.editorBg,
        child: kind == FileKind.image
            ? _ImagePreview(file: file)
            : _GenericBinaryCard(file: file, kind: kind),
      ),
    );
  }
}

class _ImagePreview extends StatefulWidget {
  final File file;
  const _ImagePreview({required this.file});

  @override
  State<_ImagePreview> createState() => _ImagePreviewState();
}

class _ImagePreviewState extends State<_ImagePreview> {
  /// Decoded image dimensions. `null` until the image's first frame
  /// resolves (or the load fails). Used only for the info strip — the
  /// actual `Image.file` widget below works without us knowing the
  /// dimensions ahead of time.
  Size? _dimensions;
  Object? _decodeError;
  late final ImageProvider _provider;
  late final ImageStreamListener _listener;
  ImageStream? _stream;

  @override
  void initState() {
    super.initState();
    _provider = FileImage(widget.file);
    _listener = ImageStreamListener(
      (info, _) {
        if (!mounted) return;
        setState(() {
          _dimensions = Size(
            info.image.width.toDouble(),
            info.image.height.toDouble(),
          );
        });
      },
      onError: (e, _) {
        if (!mounted) return;
        setState(() => _decodeError = e);
      },
    );
    _stream = _provider.resolve(const ImageConfiguration());
    _stream!.addListener(_listener);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(widget.file.path);
    final fileSize = _formatSize(widget.file);

    if (_decodeError != null) {
      return _GenericBinaryCard(
        file: widget.file,
        kind: FileKind.image,
        errorOverride: '${S.binaryPreviewImageDecodeFailed}: $_decodeError',
      );
    }

    return Column(
      children: [
        Expanded(
          child: Center(
            child: InteractiveViewer(
              minScale: 0.2,
              maxScale: 8.0,
              clipBehavior: Clip.hardEdge,
              child: Image(
                image: _provider,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                errorBuilder: (_, _, _) {
                  // The stream listener above usually catches this
                  // first, but `Image.errorBuilder` is the visual
                  // fallback if the stream never emits.
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      S.binaryPreviewImageDecodeFailed,
                      style: const TextStyle(color: DuckColors.fgMuted),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
        _PreviewInfoStrip(
          fileName: fileName,
          fileSize: fileSize,
          extra: _dimensions == null
              ? null
              : '${_dimensions!.width.toInt()} × ${_dimensions!.height.toInt()} px',
          file: widget.file,
        ),
      ],
    );
  }
}

class _GenericBinaryCard extends StatelessWidget {
  final File file;
  final FileKind kind;
  final String? errorOverride;
  const _GenericBinaryCard({
    required this.file,
    required this.kind,
    this.errorOverride,
  });

  IconData get _icon => switch (kind) {
        FileKind.audio => Icons.audiotrack_outlined,
        FileKind.video => Icons.movie_outlined,
        FileKind.image => Icons.image_outlined,
        _ => Icons.insert_drive_file_outlined,
      };

  String get _kindLabel => switch (kind) {
        FileKind.audio => S.binaryPreviewKindAudio,
        FileKind.video => S.binaryPreviewKindVideo,
        FileKind.image => S.binaryPreviewKindImage,
        FileKind.binary => S.binaryPreviewKindBinary,
        FileKind.text => S.binaryPreviewKindBinary, // unreachable
      };

  @override
  Widget build(BuildContext context) {
    final fileName = p.basename(file.path);
    final fileSize = _formatSize(file);

    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.all(28),
        margin: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: DuckColors.bgRaisedHi.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(
            color: DuckColors.glassSeam,
            width: 0.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(_icon, size: 24, color: DuckColors.accentMint),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    fileName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: DuckColors.fgPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 34),
              child: Text(
                '$_kindLabel · $fileSize',
                style: const TextStyle(
                  fontSize: 11,
                  color: DuckColors.fgMuted,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              errorOverride ?? S.binaryPreviewExplainer,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: DuckColors.fgMuted,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                _PreviewActionButton(
                  icon: Icons.open_in_new,
                  label: S.binaryPreviewOpenExternally,
                  onTap: () => _openExternally(context, file),
                ),
                const SizedBox(width: 8),
                _PreviewActionButton(
                  icon: Icons.folder_open_outlined,
                  label: S.binaryPreviewRevealInOs,
                  onTap: () => _revealInOs(context, file),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewInfoStrip extends StatelessWidget {
  final String fileName;
  final String fileSize;
  final String? extra;
  final File file;
  const _PreviewInfoStrip({
    required this.fileName,
    required this.fileSize,
    required this.file,
    this.extra,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.image_outlined,
            size: 13,
            color: DuckColors.fgMuted,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.fgMuted,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            fileSize,
            style: const TextStyle(
              fontSize: 11,
              color: DuckColors.fgSubtle,
            ),
          ),
          if (extra != null) ...[
            const SizedBox(width: 12),
            Text(
              extra!,
              style: const TextStyle(
                fontSize: 11,
                color: DuckColors.fgSubtle,
              ),
            ),
          ],
          const Spacer(),
          _MiniIconButton(
            icon: Icons.open_in_new,
            tooltip: S.binaryPreviewOpenExternally,
            onTap: () => _openExternally(context, file),
          ),
          _MiniIconButton(
            icon: Icons.folder_open_outlined,
            tooltip: S.binaryPreviewRevealInOs,
            onTap: () => _revealInOs(context, file),
          ),
        ],
      ),
    );
  }
}

class _PreviewActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _PreviewActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: DuckColors.fgPrimary),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 13, color: DuckColors.fgMuted),
          ),
        ),
      ),
    );
  }
}

String _formatSize(File f) {
  try {
    final bytes = f.lengthSync();
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  } catch (_) {
    return '—';
  }
}

/// Hand the file to the OS default app. On Windows we use
/// `cmd /c start "" "<path>"` (the empty quoted string is `start`'s
/// title argument — without it `start` interprets a quoted path as
/// the title). macOS uses `open`, Linux `xdg-open`. Errors surface
/// as a toast — typically only happens when the path no longer
/// exists or the user has no default handler registered.
Future<void> _openExternally(BuildContext context, File file) async {
  try {
    if (Platform.isWindows) {
      await Process.start('cmd', ['/c', 'start', '', file.path]);
    } else if (Platform.isMacOS) {
      await Process.start('open', [file.path]);
    } else {
      await Process.start('xdg-open', [file.path]);
    }
  } catch (e) {
    if (!context.mounted) return;
    showDuckToast(context, '${S.binaryPreviewOpenFailed}: $e');
  }
}

/// Reveal the file in the OS file manager (Explorer / Finder /
/// Nautilus). Slightly different command on each platform — Windows'
/// `explorer.exe /select,"<path>"` highlights the file in the parent
/// folder; macOS `open -R` is the same; on Linux we just `xdg-open`
/// the parent dir since `--reveal` isn't standard across file
/// managers.
Future<void> _revealInOs(BuildContext context, File file) async {
  try {
    if (Platform.isWindows) {
      await Process.start('explorer.exe', ['/select,${file.path}']);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', file.path]);
    } else {
      await Process.start('xdg-open', [p.dirname(file.path)]);
    }
  } catch (e) {
    if (!context.mounted) return;
    showDuckToast(context, '${S.binaryPreviewRevealFailed}: $e');
  }
}
