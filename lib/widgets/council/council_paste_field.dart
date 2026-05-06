import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:pasteboard/pasteboard.dart';

import '../../l10n/strings.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import '../common/image_lightbox.dart';

/// Shared composer / textarea used by Council prompt panels.
///
/// Mirrors the AI chat composer's paste pipeline byte-for-byte:
///   * `pasteboard` reads the OS clipboard for an image,
///   * `image` package decodes + downscales to <= 1280 px wide and
///     re-encodes JPEG (quality 80),
///   * the base64 string is appended to a pending-images list which
///     submits as `messages[].images: List<String>` — exactly the same
///     shape the chat controller emits and the Anthropic / Gemini /
///     Ollama services consume.
///
/// Extracted so the orchestrator-ping panel and the answer-to-agent
/// panel use one path instead of forking the paste handling.
class CouncilPasteAttachments extends ChangeNotifier {
  final List<String> _images = <String>[];

  List<String> get images => List.unmodifiable(_images);

  bool get isEmpty => _images.isEmpty;
  bool get isNotEmpty => _images.isNotEmpty;
  int get length => _images.length;

  void add(String base64) {
    _images.add(base64);
    notifyListeners();
  }

  void removeAt(int index) {
    if (index < 0 || index >= _images.length) return;
    _images.removeAt(index);
    notifyListeners();
  }

  void clear() {
    if (_images.isEmpty) return;
    _images.clear();
    notifyListeners();
  }

  /// Drain — returns a snapshot and clears the buffer in one step.
  /// Used at submit time so the caller doesn't have to do read-then-clear
  /// and risk losing a paste that landed mid-submit.
  List<String> takeAll() {
    final out = List<String>.from(_images);
    _images.clear();
    notifyListeners();
    return out;
  }
}

class _CouncilComposerPasteIntent extends Intent {
  const _CouncilComposerPasteIntent();
}

/// Shared TextField that supports image paste (Ctrl/Cmd+V) and renders
/// attachment chips above the field. Plain text paste falls through
/// unchanged.
///
/// Behavior:
///   * If an image is on the clipboard → consumed, downscaled, base64
///     queued in [attachments], toast confirms.
///   * Otherwise → plain text is inserted at the caret (default
///     TextField paste behaviour, achieved by letting the system
///     handle paste when no image is present).
///   * `onSubmit` fires on Enter (Shift+Enter newlines, matching the
///     chat composer).
class CouncilComposerField extends StatefulWidget {
  final TextEditingController controller;
  final CouncilPasteAttachments attachments;
  final FocusNode? focusNode;
  final String? hintText;
  final int minLines;
  final int maxLines;
  final bool enabled;
  final VoidCallback? onSubmit;

  const CouncilComposerField({
    super.key,
    required this.controller,
    required this.attachments,
    this.focusNode,
    this.hintText,
    this.minLines = 3,
    this.maxLines = 8,
    this.enabled = true,
    this.onSubmit,
  });

  @override
  State<CouncilComposerField> createState() => _CouncilComposerFieldState();
}

class _CouncilComposerFieldState extends State<CouncilComposerField> {
  late final FocusNode _focus = widget.focusNode ?? FocusNode();
  bool _ownsFocus = false;

  @override
  void initState() {
    super.initState();
    _ownsFocus = widget.focusNode == null;
    widget.attachments.addListener(_onAttachmentsChanged);
  }

  @override
  void dispose() {
    widget.attachments.removeListener(_onAttachmentsChanged);
    if (_ownsFocus) _focus.dispose();
    super.dispose();
  }

  void _onAttachmentsChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _handlePaste() async {
    Uint8List? clipboardImage;
    try {
      clipboardImage = await Pasteboard.image;
    } catch (e) {
      debugPrint('Pasteboard.image failed: $e');
    }
    if (clipboardImage != null && clipboardImage.isNotEmpty) {
      _addImageBytes(clipboardImage);
      if (mounted) showDuckToast(context, S.chatImagePasted);
      _focus.requestFocus();
      return;
    }
    // No image on clipboard — fall through to plain-text paste.
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    _insertTextAtCursor(text);
  }

  void _insertTextAtCursor(String insertion) {
    final v = widget.controller.value;
    final sel = v.selection;
    final base = v.text;
    final start = sel.isValid ? sel.start : base.length;
    final end = sel.isValid ? sel.end : base.length;
    final lo = start < end ? start : end;
    final hi = start < end ? end : start;
    final next = base.replaceRange(lo, hi, insertion);
    widget.controller.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: lo + insertion.length),
    );
    _focus.requestFocus();
  }

  void _addImageBytes(Uint8List raw) {
    // Match ai_chat._addImageBytes byte-for-byte: decode, downscale to
    // <= 1280 px wide, re-encode JPEG q80, base64. Fallback to raw
    // base64 if decode fails so the user still gets *something* on the
    // wire instead of a silent drop.
    try {
      final decoded = img.decodeImage(raw);
      if (decoded == null) {
        widget.attachments.add(base64Encode(raw));
        return;
      }
      final resized = decoded.width > 1280
          ? img.copyResize(decoded, width: 1280)
          : decoded;
      final encoded = img.encodeJpg(resized, quality: 80);
      widget.attachments.add(base64Encode(encoded));
    } catch (_) {
      widget.attachments.add(base64Encode(raw));
    }
  }

  Future<void> _pickImageFile() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    for (final f in result.files) {
      final raw =
          f.bytes ?? (f.path != null ? await File(f.path!).readAsBytes() : null);
      if (raw == null) continue;
      _addImageBytes(raw);
    }
  }

  @override
  Widget build(BuildContext context) {
    final images = widget.attachments.images;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (images.isNotEmpty) ...[
          _AttachmentStrip(
            attachments: widget.attachments,
          ),
          const SizedBox(height: 8),
        ],
        Shortcuts(
          shortcuts: const <ShortcutActivator, Intent>{
            SingleActivator(LogicalKeyboardKey.keyV, control: true):
                _CouncilComposerPasteIntent(),
            SingleActivator(LogicalKeyboardKey.keyV, meta: true):
                _CouncilComposerPasteIntent(),
          },
          child: Actions(
            actions: <Type, Action<Intent>>{
              _CouncilComposerPasteIntent:
                  CallbackAction<_CouncilComposerPasteIntent>(
                onInvoke: (_) {
                  unawaited(_handlePaste());
                  return null;
                },
              ),
            },
            child: Focus(
              onKeyEvent: (node, event) {
                if (widget.onSubmit != null &&
                    event is KeyDownEvent &&
                    event.logicalKey == LogicalKeyboardKey.enter &&
                    !HardwareKeyboard.instance.isShiftPressed) {
                  widget.onSubmit!();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: Stack(
                children: [
                  TextField(
                    controller: widget.controller,
                    focusNode: _focus,
                    minLines: widget.minLines,
                    maxLines: widget.maxLines,
                    enabled: widget.enabled,
                    style: const TextStyle(color: DuckColors.fgPrimary),
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      hintStyle: const TextStyle(color: DuckColors.fgMuted),
                      filled: true,
                      fillColor: DuckColors.bgDeeper,
                      contentPadding: const EdgeInsets.fromLTRB(12, 12, 44, 12),
                      border: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(DuckTheme.radiusM),
                        borderSide: const BorderSide(color: DuckColors.border),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius:
                            BorderRadius.circular(DuckTheme.radiusM),
                        borderSide: const BorderSide(color: DuckColors.border),
                      ),
                    ),
                  ),
                  Positioned(
                    right: 4,
                    bottom: 4,
                    child: Tooltip(
                      message: S.chatAttachImage,
                      child: IconButton(
                        iconSize: 16,
                        splashRadius: 16,
                        color: DuckColors.fgMuted,
                        onPressed: widget.enabled ? _pickImageFile : null,
                        icon: const Icon(Icons.image_outlined),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AttachmentStrip extends StatelessWidget {
  final CouncilPasteAttachments attachments;

  const _AttachmentStrip({required this.attachments});

  @override
  Widget build(BuildContext context) {
    final images = attachments.images;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: const BoxDecoration(
        color: DuckColors.bgDeeper,
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
          left: BorderSide(color: DuckColors.accentMint, width: 2),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.attach_file,
                size: 12,
                color: DuckColors.accentMint,
              ),
              const SizedBox(width: 6),
              Text(
                S.chatImagesAttached(images.length),
                style: const TextStyle(fontSize: 11, color: DuckColors.fgMuted),
              ),
              const Spacer(),
              InkWell(
                onTap: attachments.clear,
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: images.asMap().entries.map((entry) {
              final index = entry.key;
              return _CouncilPendingImageChip(
                base64Image: entry.value,
                onRemove: () => attachments.removeAt(index),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}

class _CouncilPendingImageChip extends StatelessWidget {
  final String base64Image;
  final VoidCallback onRemove;

  const _CouncilPendingImageChip({
    required this.base64Image,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    Uint8List? bytes;
    try {
      bytes = base64Decode(base64Image);
    } catch (_) {
      bytes = null;
    }
    return Tooltip(
      message: S.imageLightboxOpenHint,
      waitDuration: const Duration(milliseconds: 350),
      child: MouseRegion(
        cursor: bytes == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Container(
          width: 56,
          height: 56,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: DuckColors.bgChip,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: Border.all(color: DuckColors.border, width: 0.5),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                child: bytes == null
                    ? const Icon(
                        Icons.image_not_supported_outlined,
                        size: 18,
                        color: DuckColors.fgSubtle,
                      )
                    : GestureDetector(
                        onTap: () => ImageLightbox.show(
                          context,
                          base64Image: base64Image,
                        ),
                        child: Image.memory(bytes, fit: BoxFit.cover),
                      ),
              ),
              Positioned(
                top: 2,
                right: 2,
                child: InkWell(
                  onTap: onRemove,
                  borderRadius: BorderRadius.circular(999),
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.62),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Icon(
                      Icons.close,
                      size: 11,
                      color: DuckColors.fgPrimary,
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
