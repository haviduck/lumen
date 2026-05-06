import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';

/// Read-only, beautifully rendered viewer for a saved council report.
///
/// Loads the markdown from disk (with truncation for huge files) and
/// hands it to [CouncilReportView] for the actual render. Adds the
/// dialog/embedded chrome, header actions (reveal, copy-path, export,
/// close), and the truncation banner.
class CouncilReportViewer extends StatefulWidget {
  final String markdownPath;
  final String? title;
  final String? summary;
  final List<String>? agentRoster;
  final DateTime? savedAt;

  /// When true, render without `Dialog` chrome (no insetPadding, no fixed
  /// max-size constraint) so the viewer can be docked inline as a side
  /// panel of the council theater.
  final bool embedded;
  final VoidCallback? onClose;

  const CouncilReportViewer({
    super.key,
    required this.markdownPath,
    this.title,
    this.summary,
    this.agentRoster,
    this.savedAt,
    this.embedded = false,
    this.onClose,
  });

  @override
  State<CouncilReportViewer> createState() => _CouncilReportViewerState();
}

class _CouncilReportViewerState extends State<CouncilReportViewer> {
  static const int _streamThreshold = 256 * 1024; // 256KB

  String? _content;
  bool _truncated = false;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final f = File(widget.markdownPath);
      if (!await f.exists()) {
        setState(() {
          _error = 'File not found';
          _loading = false;
        });
        return;
      }
      final stat = await f.stat();
      String body;
      if (stat.size > _streamThreshold) {
        final raw = await f.openRead(0, _streamThreshold).fold<List<int>>(
              <int>[],
              (acc, chunk) => acc..addAll(chunk),
            );
        body = String.fromCharCodes(raw);
        _truncated = true;
      } else {
        body = await f.readAsString();
      }
      if (!mounted) return;
      setState(() {
        _content = body;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  Future<void> _reveal() async {
    try {
      final svc = context.read<AppState>().council.persistence;
      await svc.revealInOs(widget.markdownPath);
    } catch (e) {
      if (mounted) showDuckToast(context, '${S.error}: $e');
    }
  }

  Future<void> _copyPath() async {
    await Clipboard.setData(ClipboardData(text: widget.markdownPath));
    if (!mounted) return;
    showDuckToast(context, S.councilReportPathCopied);
  }

  Future<void> _export() async => _reveal();

  @override
  Widget build(BuildContext context) {
    final shell = DuckGlass(
      tint: const Color(0xF014171D),
      border: Border.all(color: DuckColors.borderStrong, width: 0.6),
      radius: widget.embedded ? DuckTheme.radiusM : DuckTheme.radiusL,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildHeader(context),
          const Divider(height: 1, color: DuckColors.glassSeam),
          Expanded(child: _buildBody(context)),
          if (_truncated) _buildTruncatedBanner(),
        ],
      ),
    );
    if (widget.embedded) return shell;
    return Dialog(
      insetPadding: const EdgeInsets.all(28),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 980, maxHeight: 880),
        child: shell,
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    final title = widget.title ?? '';
    final saved = widget.savedAt;
    final roster = widget.agentRoster ?? const <String>[];
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [DuckColors.accentPurple, DuckColors.accentCyan],
              ),
            ),
            child: const Icon(
              Icons.menu_book_outlined,
              size: 19,
              color: DuckColors.bgDeepest,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title.isEmpty ? S.councilReportReady : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 10,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (saved != null)
                      Text(
                        _formatDate(saved),
                        style: const TextStyle(
                          color: DuckColors.fgMuted,
                          fontSize: 11,
                        ),
                      ),
                    if (roster.isNotEmpty)
                      Text(
                        roster.join(' · '),
                        style: const TextStyle(
                          color: DuckColors.fgSubtle,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
          _HeaderAction(
            icon: Icons.folder_open_outlined,
            tooltip: S.councilReportRevealInFolder,
            onTap: _reveal,
          ),
          _HeaderAction(
            icon: Icons.link_outlined,
            tooltip: S.councilReportCopyPath,
            onTap: _copyPath,
          ),
          _HeaderAction(
            icon: Icons.ios_share_outlined,
            tooltip: S.councilReportExport,
            onTap: _export,
          ),
          const SizedBox(width: 6),
          _HeaderAction(
            icon: Icons.close,
            tooltip: S.close,
            onTap: () {
              if (widget.embedded && widget.onClose != null) {
                widget.onClose!();
              } else {
                Navigator.of(context).maybePop();
              }
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '$_error',
            style: const TextStyle(color: DuckColors.stateError),
          ),
        ),
      );
    }
    return CouncilReportView(markdown: _content ?? '');
  }

  Widget _buildTruncatedBanner() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0x33EAB308),
        border: Border(top: BorderSide(color: DuckColors.glassSeam)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.info_outline,
            size: 14,
            color: Color(0xFFD9A441),
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              S.councilReportTruncated,
              style: TextStyle(color: DuckColors.fgPrimary, fontSize: 11.5),
            ),
          ),
          TextButton.icon(
            onPressed: _reveal,
            icon: const Icon(Icons.folder_open_outlined, size: 13),
            label: const Text(S.councilReportRevealInFolder),
          ),
        ],
      ),
    );
  }

  static String _formatDate(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}

class _HeaderAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 22,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Icon(icon, size: 18, color: DuckColors.fgMuted),
        ),
      ),
    );
  }
}

/// Public, read-only markdown renderer for council final reports.
///
/// Drop this into any container (dialog body, side panel, embedded
/// pane) to display a beautifully rendered report. No editor chrome,
/// no `TextField` — text is selectable via `SelectionArea`, code
/// blocks expose a copy chip, and ` ```mermaid ` flowcharts are
/// painted natively by [_MermaidFlowchart] (subset: `flowchart TD/LR/
/// RL/BT`). Other Mermaid kinds gracefully degrade to a labeled
/// "diagram source" card with a copy → `mermaid.live` affordance.
///
/// Reuses `flutter_markdown_plus` (the same pipeline already used by
/// the AI chat bubble) — no parallel renderer.
class CouncilReportView extends StatelessWidget {
  final String markdown;

  const CouncilReportView({super.key, required this.markdown});

  @override
  Widget build(BuildContext context) {
    if (markdown.trim().isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(36),
          child: Text(
            S.councilReportEmpty,
            style: TextStyle(color: DuckColors.fgMuted),
          ),
        ),
      );
    }
    return Container(
      color: const Color(0xFF0E1218),
      child: SelectionArea(
        child: Markdown(
          data: markdown,
          // SelectionArea owns selection so flutter_markdown_plus's own
          // SelectableText widgets don't fight it.
          selectable: false,
          padding: const EdgeInsets.fromLTRB(34, 24, 34, 32),
          extensionSet: md.ExtensionSet.gitHubFlavored,
          builders: {'pre': _CodeBlockBuilder()},
          styleSheet: _styleSheet(),
        ),
      ),
    );
  }

  MarkdownStyleSheet _styleSheet() {
    return MarkdownStyleSheet(
      h1: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 28,
        height: 1.25,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.2,
      ),
      h1Padding: const EdgeInsets.only(top: 6, bottom: 8),
      h2: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 22,
        height: 1.3,
        fontWeight: FontWeight.w800,
      ),
      h2Padding: const EdgeInsets.only(top: 22, bottom: 6),
      h3: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 17,
        height: 1.35,
        fontWeight: FontWeight.w700,
      ),
      h3Padding: const EdgeInsets.only(top: 16, bottom: 4),
      h4: const TextStyle(
        color: DuckColors.fgSecondary,
        fontSize: 15,
        fontWeight: FontWeight.w700,
      ),
      h4Padding: const EdgeInsets.only(top: 12, bottom: 2),
      p: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 14,
        height: 1.6,
      ),
      pPadding: const EdgeInsets.only(bottom: 6),
      listIndent: 22,
      listBullet: const TextStyle(
        color: DuckColors.accentMint,
        fontSize: 14,
        fontWeight: FontWeight.w700,
      ),
      listBulletPadding: const EdgeInsets.only(right: 6),
      checkbox: const TextStyle(
        color: DuckColors.accentMint,
        fontSize: 14,
      ),
      em: const TextStyle(
        color: DuckColors.fgPrimary,
        fontStyle: FontStyle.italic,
      ),
      strong: const TextStyle(
        color: DuckColors.fgPrimary,
        fontWeight: FontWeight.w800,
      ),
      a: const TextStyle(
        color: DuckColors.accentCyan,
        decoration: TextDecoration.underline,
      ),
      code: const TextStyle(
        fontFamily: DuckTheme.monoFont,
        fontSize: 12.5,
        color: DuckColors.accentCyan,
        backgroundColor: Color(0xFF11161E),
      ),
      // The `pre` builder owns fenced-block render; defaults stay neutral.
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFF11161E),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: const Border(
          left: BorderSide(color: DuckColors.accentPurple, width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      blockquote: const TextStyle(
        color: DuckColors.fgSecondary,
        fontStyle: FontStyle.italic,
        height: 1.5,
      ),
      tableHead: const TextStyle(
        color: DuckColors.fgPrimary,
        fontWeight: FontWeight.w800,
      ),
      tableBody: const TextStyle(
        color: DuckColors.fgSecondary,
        fontSize: 13,
        height: 1.45,
      ),
      tableBorder: TableBorder.all(
        color: DuckColors.glassSeam,
        width: 0.5,
      ),
      tableHeadAlign: TextAlign.left,
      tableCellsPadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 8,
      ),
      tableColumnWidth: const IntrinsicColumnWidth(),
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
    );
  }
}

/// Custom `<pre>` builder: routes ` ```mermaid ` blocks to the native
/// flowchart renderer, every other fenced block to [_ReportCodeBlock]
/// (with copy chip + language label). We always own the `pre` slot —
/// returning `null` would defer to the default beige-ish render.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final children = element.children;
    if (children == null || children.isEmpty) return null;
    final inner = children.first;
    if (inner is! md.Element || inner.tag != 'code') return null;
    final cls = inner.attributes['class'] ?? '';
    final lang = cls
        .replaceFirst(RegExp(r'^language-'), '')
        .trim()
        .toLowerCase();
    final source = inner.textContent;
    if (lang == 'mermaid') {
      return _MermaidBlock(source: source);
    }
    return _ReportCodeBlock(code: source, language: lang.isEmpty ? null : lang);
  }
}

/// Code block with header strip (language label + copy chip) matching
/// the AI chat's `_CodeBlock` ergonomics. Body is a horizontal scroll
/// view with `SelectableText` so long lines don't wrap and indent-
/// sensitive code (Python, YAML) survives copy-paste cleanly.
class _ReportCodeBlock extends StatefulWidget {
  final String code;
  final String? language;

  const _ReportCodeBlock({required this.code, this.language});

  @override
  State<_ReportCodeBlock> createState() => _ReportCodeBlockState();
}

class _ReportCodeBlockState extends State<_ReportCodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    showDuckToast(context, S.chatMessageCopied);
    Future.delayed(const Duration(milliseconds: 1400), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final code = widget.code.endsWith('\n')
        ? widget.code.substring(0, widget.code.length - 1)
        : widget.code;

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E14),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(12, 5, 5, 5),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                if (widget.language != null)
                  Text(
                    widget.language!,
                    style: const TextStyle(
                      fontSize: 10.5,
                      color: DuckColors.fgMuted,
                      fontFamily: DuckTheme.monoFont,
                      letterSpacing: 0.3,
                    ),
                  ),
                const Spacer(),
                _CodeCopyChip(onTap: _copy, copied: _copied),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
            child: SelectableText(
              code,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 12,
                color: DuckColors.fgPrimary,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodeCopyChip extends StatefulWidget {
  final VoidCallback onTap;
  final bool copied;
  const _CodeCopyChip({required this.onTap, required this.copied});

  @override
  State<_CodeCopyChip> createState() => _CodeCopyChipState();
}

class _CodeCopyChipState extends State<_CodeCopyChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final label = widget.copied ? S.chatCodeBlockCopied : S.chatCodeBlockCopy;
    final iconColor = widget.copied
        ? DuckColors.accentMint
        : (_hover ? DuckColors.fgPrimary : DuckColors.fgMuted);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: label,
        waitDuration: const Duration(milliseconds: 350),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(DuckTheme.radiusS),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  widget.copied ? Icons.check : Icons.copy_outlined,
                  size: 13,
                  color: iconColor,
                ),
                const SizedBox(width: 5),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    color: iconColor,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
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

// ─────────────────────────────────────────────────────────────────────
//  Mermaid block — native flowchart renderer + graceful source fallback
// ─────────────────────────────────────────────────────────────────────

/// Top-level mermaid block. Tries to parse as a flowchart; on success
/// hands off to [_MermaidFlowchart]. On unsupported diagram kinds
/// (sequenceDiagram, stateDiagram, classDiagram, …) or a parse failure
/// it shows a styled "diagram source" card with a copy → mermaid.live
/// affordance, so the fallback reads as a deliberate artifact, not a
/// broken render.
class _MermaidBlock extends StatelessWidget {
  final String source;
  const _MermaidBlock({required this.source});

  @override
  Widget build(BuildContext context) {
    final parsed = _MermaidParser.tryParse(source);
    if (parsed is _ParsedFlowchart) {
      return _MermaidFlowchart(source: source, diagram: parsed);
    }
    final unsupported = parsed is _ParsedUnsupported ? parsed.kind : null;
    return _MermaidSourceCard(source: source, unsupportedKind: unsupported);
  }
}

class _MermaidSourceCard extends StatelessWidget {
  final String source;
  final String? unsupportedKind;
  const _MermaidSourceCard({required this.source, this.unsupportedKind});

  @override
  Widget build(BuildContext context) {
    final label = unsupportedKind == null
        ? S.councilReportMermaidLabel
        : '${S.councilReportMermaidLabel} · ${unsupportedKind!.toUpperCase()}';
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1622),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.45),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_outlined,
                  size: 15,
                  color: DuckColors.accentPurple,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: DuckColors.accentPurple,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: S.councilReportMermaidCopy,
                  child: InkResponse(
                    radius: 18,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: source));
                      if (context.mounted) {
                        showDuckToast(context, S.councilReportMermaidCopied);
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.copy_outlined,
                        size: 14,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (unsupportedKind != null)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 10, 14, 0),
              child: Text(
                S.councilReportDiagramUnsupported,
                style: TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 11.5,
                  height: 1.4,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: SelectableText(
              source.trim(),
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                color: DuckColors.fgSecondary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Native Mermaid flowchart card. Renders nodes + edges via
/// [CustomPainter] so it picks up theme tokens directly (no webview,
/// no asset bundle, no async layout). Supports the `flowchart TD/TB/
/// BT/LR/RL` subset; the council protocol prompt is constrained to
/// that subset so this covers ~all emitted diagrams.
class _MermaidFlowchart extends StatelessWidget {
  final String source;
  final _ParsedFlowchart diagram;
  const _MermaidFlowchart({required this.source, required this.diagram});

  @override
  Widget build(BuildContext context) {
    final laidOut = _MermaidLayout.compute(diagram);
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1622),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.45),
          width: 0.8,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.account_tree_outlined,
                  size: 15,
                  color: DuckColors.accentPurple,
                ),
                const SizedBox(width: 8),
                Text(
                  '${S.councilReportMermaidLabel} · ${diagram.direction.label}',
                  style: const TextStyle(
                    color: DuckColors.accentPurple,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
                const Spacer(),
                Tooltip(
                  message: S.councilReportMermaidCopy,
                  child: InkResponse(
                    radius: 18,
                    onTap: () async {
                      await Clipboard.setData(ClipboardData(text: source));
                      if (context.mounted) {
                        showDuckToast(context, S.councilReportMermaidCopied);
                      }
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.copy_outlined,
                        size: 14,
                        color: DuckColors.fgMuted,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(
                width: laidOut.size.width,
                height: laidOut.size.height,
                child: CustomPaint(
                  painter: _FlowchartPainter(laidOut),
                  size: laidOut.size,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Mermaid AST ────────────────────────────────────────────────────

enum _FlowDirection {
  td('TD'),
  bt('BT'),
  lr('LR'),
  rl('RL');

  final String label;
  const _FlowDirection(this.label);

  bool get isVertical => this == _FlowDirection.td || this == _FlowDirection.bt;
}

enum _NodeShape { rect, round, stadium, diamond, circle, subroutine, asymmetric }

class _MermaidNode {
  final String id;
  String label;
  _NodeShape shape;
  _MermaidNode(this.id, this.label, this.shape);
}

class _MermaidEdge {
  final String from;
  final String to;
  final String? label;
  final bool dotted;
  final bool thick;
  final bool arrow;
  _MermaidEdge({
    required this.from,
    required this.to,
    this.label,
    this.dotted = false,
    this.thick = false,
    this.arrow = true,
  });
}

abstract class _MermaidParseResult {
  const _MermaidParseResult();
}

class _ParsedFlowchart extends _MermaidParseResult {
  final _FlowDirection direction;
  final Map<String, _MermaidNode> nodes;
  final List<_MermaidEdge> edges;
  _ParsedFlowchart({
    required this.direction,
    required this.nodes,
    required this.edges,
  });
}

class _ParsedUnsupported extends _MermaidParseResult {
  final String kind;
  const _ParsedUnsupported(this.kind);
}

class _ParsedInvalid extends _MermaidParseResult {
  const _ParsedInvalid();
}

// ─── Mermaid parser (flowchart subset) ──────────────────────────────

class _MermaidParser {
  static final _kindRe =
      RegExp(r'^(flowchart|graph)\s+(TD|TB|BT|LR|RL)\b', caseSensitive: false);
  static final _otherKindRe = RegExp(
    r'^(sequenceDiagram|stateDiagram(?:-v2)?|classDiagram|erDiagram|gantt|pie|journey|mindmap|gitGraph|quadrantChart|timeline|requirementDiagram|c4Context|sankey-beta|xychart-beta)\b',
    caseSensitive: false,
  );

  // Edge connector tokens (longest first so prefixes don't shadow).
  static final _edgeConnectors = <String>[
    '====>', '====', '==>', '==',
    '-.->', '-.-',
    '-->', '---',
  ];

  static final _nodeHeadRe = RegExp(
    r'^([A-Za-z0-9_\-]+)\s*(\(\(|\[\[|\(\[|\[\(|\[\/|\[\\|\(|\[|\{|>)?',
  );

  static _MermaidParseResult tryParse(String source) {
    final lines = _stripComments(source);
    if (lines.isEmpty) return const _ParsedInvalid();

    final firstNonBlank = lines.firstWhere(
      (l) => l.trim().isNotEmpty,
      orElse: () => '',
    );
    final kindMatch = _kindRe.firstMatch(firstNonBlank.trim());
    if (kindMatch == null) {
      final other = _otherKindRe.firstMatch(firstNonBlank.trim());
      if (other != null) {
        return _ParsedUnsupported(other.group(1)!.toLowerCase());
      }
      return const _ParsedInvalid();
    }
    final dirToken = kindMatch.group(2)!.toUpperCase();
    final direction = switch (dirToken) {
      'TD' || 'TB' => _FlowDirection.td,
      'BT' => _FlowDirection.bt,
      'LR' => _FlowDirection.lr,
      'RL' => _FlowDirection.rl,
      _ => _FlowDirection.td,
    };

    final nodes = <String, _MermaidNode>{};
    final edges = <_MermaidEdge>[];
    final firstIdx = lines.indexOf(firstNonBlank);

    for (var i = 0; i < lines.length; i++) {
      if (i == firstIdx) continue;
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (line.startsWith('classDef ') ||
          line.startsWith('class ') ||
          line.startsWith('style ') ||
          line.startsWith('linkStyle ') ||
          line.startsWith('click ') ||
          line.startsWith('subgraph ') ||
          line == 'end' ||
          line.startsWith('direction ')) {
        continue;
      }
      try {
        _parseLine(line, nodes, edges);
      } catch (_) {
        // Soft-skip a malformed line; worst case is the source-card fallback.
      }
    }

    if (nodes.isEmpty && edges.isEmpty) return const _ParsedInvalid();

    for (final e in edges) {
      nodes.putIfAbsent(e.from, () => _MermaidNode(e.from, e.from, _NodeShape.rect));
      nodes.putIfAbsent(e.to, () => _MermaidNode(e.to, e.to, _NodeShape.rect));
    }

    return _ParsedFlowchart(
      direction: direction,
      nodes: nodes,
      edges: edges,
    );
  }

  static List<String> _stripComments(String source) {
    final out = <String>[];
    for (final raw in source.split('\n')) {
      final idx = raw.indexOf('%%');
      out.add(idx >= 0 ? raw.substring(0, idx) : raw);
    }
    return out;
  }

  /// Walk a flowchart body line consuming `head [connector head]*`.
  static void _parseLine(
    String line,
    Map<String, _MermaidNode> nodes,
    List<_MermaidEdge> edges,
  ) {
    var cursor = 0;
    String? prevId;
    _ConnectorSpec? pendingConnector;
    var safety = 0;

    while (cursor < line.length && safety++ < 200) {
      final remaining = line.substring(cursor).trimLeft();
      cursor = line.length - remaining.length;
      if (remaining.isEmpty) break;

      if (prevId != null) {
        final conn = _consumeConnector(remaining);
        if (conn != null) {
          pendingConnector = conn.spec;
          cursor += conn.consumed;
          continue;
        }
      }

      final head = _consumeNodeHead(remaining);
      if (head == null) break;
      cursor += head.consumed;
      final node = head.node;
      nodes.putIfAbsent(node.id, () => node);
      final stored = nodes[node.id]!;
      if (node.label != node.id && stored.label == stored.id) {
        stored.label = node.label;
        stored.shape = node.shape;
      }

      if (prevId != null && pendingConnector != null) {
        edges.add(_MermaidEdge(
          from: prevId,
          to: node.id,
          label: pendingConnector.label,
          dotted: pendingConnector.dotted,
          thick: pendingConnector.thick,
          arrow: pendingConnector.arrow,
        ));
      }
      prevId = node.id;
      pendingConnector = null;

      final tail = line.substring(cursor).trimLeft();
      if (tail.startsWith('&')) {
        cursor = line.length - tail.length + 1;
        continue;
      }
    }
  }

  static _NodeHeadConsumption? _consumeNodeHead(String s) {
    final m = _nodeHeadRe.firstMatch(s);
    if (m == null) return null;
    final id = m.group(1)!;
    final open = m.group(2);
    if (open == null) {
      return _NodeHeadConsumption(
        node: _MermaidNode(id, id, _NodeShape.rect),
        consumed: m.end,
      );
    }
    final closeMap = <String, ({String close, _NodeShape shape})>{
      '[': (close: ']', shape: _NodeShape.rect),
      '(': (close: ')', shape: _NodeShape.round),
      '{': (close: '}', shape: _NodeShape.diamond),
      '((': (close: '))', shape: _NodeShape.circle),
      '[[': (close: ']]', shape: _NodeShape.subroutine),
      '([': (close: '])', shape: _NodeShape.stadium),
      '[(': (close: ')]', shape: _NodeShape.stadium),
      '[/': (close: '/]', shape: _NodeShape.asymmetric),
      '[\\': (close: '\\]', shape: _NodeShape.asymmetric),
      '>': (close: ']', shape: _NodeShape.asymmetric),
    };
    final spec = closeMap[open];
    if (spec == null) {
      return _NodeHeadConsumption(
        node: _MermaidNode(id, id, _NodeShape.rect),
        consumed: m.end,
      );
    }
    final closeIdx = s.indexOf(spec.close, m.end);
    if (closeIdx < 0) {
      return _NodeHeadConsumption(
        node: _MermaidNode(id, id, _NodeShape.rect),
        consumed: m.end,
      );
    }
    final inner = s.substring(m.end, closeIdx).trim();
    final stripped = _stripQuotes(inner);
    final label = stripped.isEmpty ? id : stripped;
    return _NodeHeadConsumption(
      node: _MermaidNode(id, label, spec.shape),
      consumed: closeIdx + spec.close.length,
    );
  }

  static _ConnectorConsumption? _consumeConnector(String s) {
    // `-- text -->` style first.
    final tx = RegExp(r'^(--|==|-\.)\s+([^-=|][^-=]*?)\s+(--+>?|==+>?|-\.->|-\.-)')
        .firstMatch(s);
    if (tx != null) {
      final lead = tx.group(1)!;
      final text = tx.group(2)!.trim();
      final tail = tx.group(3)!;
      return _ConnectorConsumption(
        spec: _ConnectorSpec(
          label: text.isEmpty ? null : text,
          dotted: lead == '-.' || tail.contains('.'),
          thick: lead == '==' || tail.startsWith('=='),
          arrow: tail.endsWith('>'),
        ),
        consumed: tx.end,
      );
    }

    for (final tok in _edgeConnectors) {
      if (s.startsWith(tok)) {
        var consumed = tok.length;
        String? label;
        final rest = s.substring(consumed);
        if (rest.startsWith('|')) {
          final close = rest.indexOf('|', 1);
          if (close > 0) {
            label = rest.substring(1, close).trim();
            consumed += close + 1;
          }
        }
        return _ConnectorConsumption(
          spec: _ConnectorSpec(
            label: (label == null || label.isEmpty) ? null : label,
            dotted: tok.contains('.'),
            thick: tok.contains('='),
            arrow: tok.endsWith('>'),
          ),
          consumed: consumed,
        );
      }
    }
    return null;
  }

  static String _stripQuotes(String s) {
    if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }
}

class _NodeHeadConsumption {
  final _MermaidNode node;
  final int consumed;
  _NodeHeadConsumption({required this.node, required this.consumed});
}

class _ConnectorConsumption {
  final _ConnectorSpec spec;
  final int consumed;
  _ConnectorConsumption({required this.spec, required this.consumed});
}

class _ConnectorSpec {
  final String? label;
  final bool dotted;
  final bool thick;
  final bool arrow;
  _ConnectorSpec({
    required this.label,
    required this.dotted,
    required this.thick,
    required this.arrow,
  });
}

// ─── Layout ─────────────────────────────────────────────────────────

class _LaidOutNode {
  final _MermaidNode node;
  final Rect rect;
  final TextPainter painter;
  _LaidOutNode(this.node, this.rect, this.painter);
}

class _LaidOutEdge {
  final _MermaidEdge edge;
  final Offset start;
  final Offset end;
  final Offset c1;
  final Offset c2;
  final TextPainter? labelPainter;
  final Offset? labelPos;
  _LaidOutEdge({
    required this.edge,
    required this.start,
    required this.end,
    required this.c1,
    required this.c2,
    this.labelPainter,
    this.labelPos,
  });
}

class _LaidOutDiagram {
  final List<_LaidOutNode> nodes;
  final List<_LaidOutEdge> edges;
  final Size size;
  final _FlowDirection direction;
  _LaidOutDiagram({
    required this.nodes,
    required this.edges,
    required this.size,
    required this.direction,
  });
}

class _MermaidLayout {
  static const double _nodePadX = 14;
  static const double _nodePadY = 10;
  static const double _gapMain = 56;
  static const double _gapCross = 28;
  static const double _margin = 16;

  static _LaidOutDiagram compute(_ParsedFlowchart d) {
    final order = d.nodes.keys.toList();
    final ranks = <String, int>{for (final id in order) id: 0};
    final outgoing = <String, List<String>>{
      for (final id in order) id: <String>[]
    };
    final incoming = <String, int>{for (final id in order) id: 0};
    for (final e in d.edges) {
      outgoing[e.from]!.add(e.to);
      incoming[e.to] = (incoming[e.to] ?? 0) + 1;
    }
    final queue = <String>[
      for (final id in order) if ((incoming[id] ?? 0) == 0) id
    ];
    final visited = <String>{};
    var safety = 0;
    while (queue.isNotEmpty && safety++ < 10000) {
      final n = queue.removeAt(0);
      if (!visited.add(n)) continue;
      final r = ranks[n]!;
      for (final m in outgoing[n]!) {
        final nr = r + 1;
        if (nr > (ranks[m] ?? 0)) ranks[m] = nr;
        queue.add(m);
      }
    }

    final byRank = <int, List<String>>{};
    for (final id in order) {
      byRank.putIfAbsent(ranks[id]!, () => <String>[]).add(id);
    }
    final maxRank = byRank.keys.fold<int>(0, (a, b) => a > b ? a : b);

    final painters = <String, TextPainter>{};
    final nodeSizes = <String, Size>{};
    for (final n in d.nodes.values) {
      final tp = TextPainter(
        text: TextSpan(
          text: n.label,
          style: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 12.5,
            height: 1.3,
            fontWeight: FontWeight.w600,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 4,
        ellipsis: '…',
      )..layout(maxWidth: 180);
      painters[n.id] = tp;
      var w = tp.width + _nodePadX * 2;
      var h = tp.height + _nodePadY * 2;
      if (n.shape == _NodeShape.circle) {
        final dia = math.max(w, h);
        w = dia;
        h = dia;
      } else if (n.shape == _NodeShape.diamond) {
        w += 14;
        h += 8;
      }
      nodeSizes[n.id] = Size(w, h);
    }

    final reversed =
        d.direction == _FlowDirection.bt || d.direction == _FlowDirection.rl;
    final positions = <String, Rect>{};
    final isVertical = d.direction.isVertical;

    final rankMain = <int, double>{};
    for (var r = 0; r <= maxRank; r++) {
      final ids = byRank[r] ?? const <String>[];
      double m = 0;
      for (final id in ids) {
        final s = nodeSizes[id]!;
        m = math.max(m, isVertical ? s.height : s.width);
      }
      rankMain[r] = m;
    }

    double crossSpan = 0;
    for (var r = 0; r <= maxRank; r++) {
      final ids = byRank[r] ?? const <String>[];
      double sum = 0;
      for (var i = 0; i < ids.length; i++) {
        final s = nodeSizes[ids[i]]!;
        sum += isVertical ? s.width : s.height;
        if (i < ids.length - 1) sum += _gapCross;
      }
      crossSpan = math.max(crossSpan, sum);
    }

    var mainCursor = _margin;
    final rankMainOffset = <int, double>{};
    for (var r = 0; r <= maxRank; r++) {
      rankMainOffset[r] = mainCursor;
      mainCursor += (rankMain[r] ?? 0) + _gapMain;
    }
    final mainTotal = mainCursor - _gapMain + _margin;

    for (var r = 0; r <= maxRank; r++) {
      final effR = reversed ? maxRank - r : r;
      final ids = byRank[effR] ?? const <String>[];
      double sum = 0;
      for (var i = 0; i < ids.length; i++) {
        final s = nodeSizes[ids[i]]!;
        sum += isVertical ? s.width : s.height;
        if (i < ids.length - 1) sum += _gapCross;
      }
      var crossCursor = _margin + (crossSpan - sum) / 2;
      final mainPos = rankMainOffset[r]!;
      for (final id in ids) {
        final s = nodeSizes[id]!;
        Rect rect;
        if (isVertical) {
          rect = Rect.fromLTWH(crossCursor, mainPos, s.width, s.height);
          crossCursor += s.width + _gapCross;
        } else {
          rect = Rect.fromLTWH(mainPos, crossCursor, s.width, s.height);
          crossCursor += s.height + _gapCross;
        }
        positions[id] = rect;
      }
    }

    final canvasW = isVertical ? crossSpan + _margin * 2 : mainTotal;
    final canvasH = isVertical ? mainTotal : crossSpan + _margin * 2;

    final laidNodes = <_LaidOutNode>[
      for (final n in d.nodes.values)
        _LaidOutNode(n, positions[n.id]!, painters[n.id]!)
    ];

    final laidEdges = <_LaidOutEdge>[];
    for (final e in d.edges) {
      final a = positions[e.from];
      final b = positions[e.to];
      if (a == null || b == null) continue;
      final ac = a.center;
      final bc = b.center;

      Offset start, end, c1, c2;
      if (isVertical) {
        final goingDown = bc.dy >= ac.dy;
        start = Offset(ac.dx, goingDown ? a.bottom : a.top);
        end = Offset(bc.dx, goingDown ? b.top : b.bottom);
        final span = (end.dy - start.dy).abs();
        final pull = math.max(24.0, span * 0.45);
        c1 = Offset(start.dx, start.dy + (goingDown ? pull : -pull));
        c2 = Offset(end.dx, end.dy - (goingDown ? pull : -pull));
      } else {
        final goingRight = bc.dx >= ac.dx;
        start = Offset(goingRight ? a.right : a.left, ac.dy);
        end = Offset(goingRight ? b.left : b.right, bc.dy);
        final span = (end.dx - start.dx).abs();
        final pull = math.max(24.0, span * 0.45);
        c1 = Offset(start.dx + (goingRight ? pull : -pull), start.dy);
        c2 = Offset(end.dx - (goingRight ? pull : -pull), end.dy);
      }

      TextPainter? labelTp;
      Offset? labelPos;
      if (e.label != null && e.label!.isNotEmpty) {
        labelTp = TextPainter(
          text: TextSpan(
            text: e.label!,
            style: const TextStyle(
              color: DuckColors.fgMuted,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 2,
          ellipsis: '…',
        )..layout(maxWidth: 140);
        labelPos = Offset(
          (start.dx + end.dx) / 2 - labelTp.width / 2,
          (start.dy + end.dy) / 2 - labelTp.height / 2,
        );
      }

      laidEdges.add(_LaidOutEdge(
        edge: e,
        start: start,
        end: end,
        c1: c1,
        c2: c2,
        labelPainter: labelTp,
        labelPos: labelPos,
      ));
    }

    return _LaidOutDiagram(
      nodes: laidNodes,
      edges: laidEdges,
      size: Size(canvasW, canvasH),
      direction: d.direction,
    );
  }
}

// ─── Painter ────────────────────────────────────────────────────────

class _FlowchartPainter extends CustomPainter {
  final _LaidOutDiagram d;
  _FlowchartPainter(this.d);

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in d.edges) {
      final stroke = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = e.edge.thick ? 2.4 : 1.4
        ..strokeCap = StrokeCap.round
        ..color = DuckColors.accentPurple.withValues(alpha: 0.78);
      final path = Path()
        ..moveTo(e.start.dx, e.start.dy)
        ..cubicTo(
          e.c1.dx, e.c1.dy,
          e.c2.dx, e.c2.dy,
          e.end.dx, e.end.dy,
        );
      if (e.edge.dotted) {
        _drawDashed(canvas, path, stroke, dash: 5, gap: 4);
      } else {
        canvas.drawPath(path, stroke);
      }

      if (e.labelPainter != null && e.labelPos != null) {
        final tp = e.labelPainter!;
        final pos = e.labelPos!;
        final rect = Rect.fromLTWH(
          pos.dx - 6,
          pos.dy - 3,
          tp.width + 12,
          tp.height + 6,
        );
        final rrect = RRect.fromRectAndRadius(
          rect,
          const Radius.circular(DuckTheme.radiusS),
        );
        canvas.drawRRect(
          rrect,
          Paint()..color = const Color(0xF00A0E14),
        );
        canvas.drawRRect(
          rrect,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 0.6
            ..color = DuckColors.glassSeam,
        );
        tp.paint(canvas, pos);
      }

      if (e.edge.arrow) {
        _drawArrowHead(canvas, e.c2, e.end, stroke.color);
      }
    }

    for (final n in d.nodes) {
      _drawNode(canvas, n);
    }
  }

  void _drawNode(Canvas canvas, _LaidOutNode n) {
    final fill = Paint()..color = const Color(0xFF161B26);
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0
      ..color = DuckColors.accentCyan.withValues(alpha: 0.55);

    final r = n.rect;
    switch (n.node.shape) {
      case _NodeShape.rect:
      case _NodeShape.subroutine:
        final rr = RRect.fromRectAndRadius(
          r,
          const Radius.circular(DuckTheme.radiusS),
        );
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
        if (n.node.shape == _NodeShape.subroutine) {
          final inset = r.deflate(4);
          canvas.drawRRect(
            RRect.fromRectAndRadius(inset, const Radius.circular(4)),
            stroke,
          );
        }
        break;
      case _NodeShape.round:
      case _NodeShape.stadium:
        final radius = r.height / 2;
        final rr = RRect.fromRectAndRadius(r, Radius.circular(radius));
        canvas.drawRRect(rr, fill);
        canvas.drawRRect(rr, stroke);
        break;
      case _NodeShape.circle:
        canvas.drawCircle(r.center, r.width / 2, fill);
        canvas.drawCircle(r.center, r.width / 2, stroke);
        break;
      case _NodeShape.diamond:
        final p = Path()
          ..moveTo(r.center.dx, r.top)
          ..lineTo(r.right, r.center.dy)
          ..lineTo(r.center.dx, r.bottom)
          ..lineTo(r.left, r.center.dy)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;
      case _NodeShape.asymmetric:
        final p = Path()
          ..moveTo(r.left + 8, r.top)
          ..lineTo(r.right, r.top)
          ..lineTo(r.right, r.bottom)
          ..lineTo(r.left, r.bottom)
          ..close();
        canvas.drawPath(p, fill);
        canvas.drawPath(p, stroke);
        break;
    }

    final tp = n.painter;
    tp.paint(
      canvas,
      Offset(
        r.left + (r.width - tp.width) / 2,
        r.top + (r.height - tp.height) / 2,
      ),
    );
  }

  void _drawArrowHead(Canvas canvas, Offset from, Offset tip, Color color) {
    final dir = tip - from;
    if (dir.distance < 0.001) return;
    final unit = dir / dir.distance;
    const len = 9.0;
    const wide = 5.0;
    final base = tip - unit * len;
    final perp = Offset(-unit.dy, unit.dx) * wide;
    final p = Path()
      ..moveTo(tip.dx, tip.dy)
      ..lineTo(base.dx + perp.dx, base.dy + perp.dy)
      ..lineTo(base.dx - perp.dx, base.dy - perp.dy)
      ..close();
    canvas.drawPath(p, Paint()..color = color);
  }

  void _drawDashed(
    Canvas canvas,
    Path path,
    Paint paint, {
    required double dash,
    required double gap,
  }) {
    final metrics = path.computeMetrics();
    for (final m in metrics) {
      var dist = 0.0;
      while (dist < m.length) {
        final next = math.min(dist + dash, m.length);
        canvas.drawPath(m.extractPath(dist, next), paint);
        dist = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _FlowchartPainter old) => old.d != d;
}

// ─── Dialog launchers ───────────────────────────────────────────────

Future<void> showCouncilReportViewer(
  BuildContext context, {
  required String markdownPath,
  String? title,
  String? summary,
  List<String>? agentRoster,
  DateTime? savedAt,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => CouncilReportViewer(
      markdownPath: markdownPath,
      title: title,
      summary: summary,
      agentRoster: agentRoster,
      savedAt: savedAt,
    ),
  );
}

Future<void> showCouncilReportEntryViewer(
  BuildContext context,
  CouncilReportEntry entry,
) {
  return showCouncilReportViewer(
    context,
    markdownPath: entry.markdownPath,
    title: entry.title,
    summary: entry.summary,
    agentRoster: entry.agentRoster,
    savedAt: entry.savedAt,
  );
}
