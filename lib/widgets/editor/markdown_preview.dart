import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Read-only Markdown rendering of the editor's current buffer. Used as a
/// drop-in replacement for the `CodeField` when the user toggles the
/// markdown preview button on a `.md` file.
class MarkdownPreview extends StatelessWidget {
  final String text;
  const MarkdownPreview({super.key, required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DuckColors.editorBg,
      child: Markdown(
        data: text,
        selectable: true,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
        styleSheet: MarkdownStyleSheet(
          h1: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
          h2: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
          ),
          h3: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
          h4: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
          p: const TextStyle(
            color: DuckColors.fgPrimary,
            fontSize: 14,
            height: 1.5,
          ),
          a: const TextStyle(
            color: DuckColors.accentCyan,
            decoration: TextDecoration.underline,
          ),
          em: const TextStyle(
            color: DuckColors.fgPrimary,
            fontStyle: FontStyle.italic,
          ),
          strong: const TextStyle(
            color: DuckColors.fgPrimary,
            fontWeight: FontWeight.w700,
          ),
          listBullet: const TextStyle(color: DuckColors.fgMuted, fontSize: 14),
          code: const TextStyle(
            fontFamily: DuckTheme.monoFont,
            fontSize: 12.5,
            color: DuckColors.accentCyan,
            backgroundColor: DuckColors.bgDeeper,
          ),
          codeblockPadding: const EdgeInsets.all(14),
          codeblockDecoration: BoxDecoration(
            color: DuckColors.bgDeepest,
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border.all(color: DuckColors.glassSeam, width: 0.5),
          ),
          blockquoteDecoration: BoxDecoration(
            color: DuckColors.bgDeeper,
            borderRadius: BorderRadius.circular(DuckTheme.radiusS),
            border: const Border(
              left: BorderSide(color: DuckColors.accentMint, width: 3),
            ),
          ),
          blockquotePadding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          tableHead: const TextStyle(
            color: DuckColors.fgPrimary,
            fontWeight: FontWeight.w600,
          ),
          tableBody: const TextStyle(color: DuckColors.fgMuted, fontSize: 13),
          tableBorder: TableBorder.all(color: DuckColors.glassSeam, width: 0.5),
          tableCellsPadding: const EdgeInsets.symmetric(
            horizontal: 10,
            vertical: 6,
          ),
          horizontalRuleDecoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: DuckColors.glassSeam, width: 0.5),
            ),
          ),
        ),
      ),
    );
  }
}
