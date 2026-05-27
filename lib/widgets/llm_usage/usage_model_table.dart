import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/llm_usage_log_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Per-model breakdown table.
///
/// One row per (provider, model) tuple — Lumen routes models by
/// provider-prefixed id, so `claude-sonnet-4-6` consumed via Copilot
/// is a different billing line than the same name consumed via the
/// direct Anthropic API. Sorted by `billedTotal` descending so the
/// cost-dominant models surface first.
class UsageModelTable extends StatelessWidget {
  final List<LlmUsageModelRow> rows;

  const UsageModelTable({super.key, required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.bgDeeper,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.border, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.table_chart_outlined,
                  size: 14,
                  color: DuckColors.fgMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  S.llmUsageByModelTitle,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    color: DuckColors.fgPrimary,
                    letterSpacing: 0.2,
                  ),
                ),
                const Spacer(),
                Text(
                  S.llmUsageRowCount(rows.length),
                  style: const TextStyle(
                    fontSize: 11,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ],
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Text(
                  S.llmUsageEmpty,
                  style: const TextStyle(
                    fontSize: 12,
                    color: DuckColors.fgMuted,
                  ),
                ),
              ),
            )
          else
            _HeaderRow(),
          for (var i = 0; i < rows.length; i++) _DataRow(row: rows[i], idx: i),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: const Row(
        children: [
          Expanded(flex: 32, child: _HeaderCell(S.llmUsageColModel)),
          Expanded(flex: 12, child: _HeaderCell(S.llmUsageColProvider)),
          Expanded(
            flex: 10,
            child: _HeaderCell(S.llmUsageColPrompts, alignRight: true),
          ),
          Expanded(
            flex: 12,
            child: _HeaderCell(S.chatTokenCounterInputShort, alignRight: true),
          ),
          Expanded(
            flex: 12,
            child: _HeaderCell(S.chatTokenCounterOutputShort, alignRight: true),
          ),
          Expanded(
            flex: 12,
            child: _HeaderCell(S.llmUsageColCache, alignRight: true),
          ),
          Expanded(
            flex: 14,
            child: _HeaderCell(S.llmUsageColBilled, alignRight: true),
          ),
        ],
      ),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  final String label;
  final bool alignRight;
  const _HeaderCell(this.label, {this.alignRight = false});
  @override
  Widget build(BuildContext context) {
    return Text(
      label.toUpperCase(),
      textAlign: alignRight ? TextAlign.right : TextAlign.left,
      style: const TextStyle(
        fontSize: 9.5,
        fontWeight: FontWeight.w600,
        color: DuckColors.fgMuted,
        letterSpacing: 0.6,
      ),
    );
  }
}

class _DataRow extends StatelessWidget {
  final LlmUsageModelRow row;
  final int idx;
  const _DataRow({required this.row, required this.idx});

  @override
  Widget build(BuildContext context) {
    final zebra = idx.isOdd
        ? DuckColors.bgDeeper
        : DuckColors.bgRaised.withValues(alpha: 0.35);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: zebra,
        border: const Border(
          bottom: BorderSide(color: DuckColors.glassSeam, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            flex: 32,
            child: Text(
              row.model.isEmpty ? S.llmUsageUnknownModel : row.model,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: DuckColors.fgPrimary,
              ),
            ),
          ),
          Expanded(
            flex: 12,
            child: _ProviderChip(provider: row.provider),
          ),
          Expanded(
            flex: 10,
            child: _Cell(value: row.promptCount.toString()),
          ),
          Expanded(
            flex: 12,
            child: _Cell(value: _compact(row.inputTokens)),
          ),
          Expanded(
            flex: 12,
            child: _Cell(value: _compact(row.outputTokens)),
          ),
          Expanded(
            flex: 12,
            child: _Cell(
              value: row.cacheReadTokens + row.cacheWriteTokens > 0
                  ? _compact(row.cacheReadTokens + row.cacheWriteTokens)
                  : '—',
              dim: row.cacheReadTokens + row.cacheWriteTokens == 0,
            ),
          ),
          Expanded(
            flex: 14,
            child: _Cell(
              value: _compact(row.billedTotal),
              accent: DuckColors.accentPurple,
              bold: true,
            ),
          ),
        ],
      ),
    );
  }

  static String _compact(int n) {
    if (n < 1000) return n.toString();
    if (n < 10000) return '${(n / 1000).toStringAsFixed(2)}k';
    if (n < 1000000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '${(n / 1000000).toStringAsFixed(2)}M';
  }
}

class _Cell extends StatelessWidget {
  final String value;
  final Color? accent;
  final bool bold;
  final bool dim;
  const _Cell({
    required this.value,
    this.accent,
    this.bold = false,
    this.dim = false,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerRight,
      child: Text(
        value,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: bold ? FontWeight.w600 : FontWeight.w500,
          color: dim
              ? DuckColors.fgSubtle
              : (accent ?? DuckColors.fgPrimary),
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}

class _ProviderChip extends StatelessWidget {
  final String provider;
  const _ProviderChip({required this.provider});

  @override
  Widget build(BuildContext context) {
    final color = _colorFor(provider);
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.45), width: 0.5),
        ),
        child: Text(
          _labelFor(provider),
          style: TextStyle(
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            color: color,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  // Centralised provider → display + accent. Same names as
  // ChatController._splitModel returns. Unknown providers fall back
  // to a neutral muted chip so the table doesn't crash on a future
  // provider id we haven't styled yet.
  static String _labelFor(String p) {
    return switch (p) {
      'claude' => 'Claude',
      'copilot' => 'Copilot',
      'gemini' => 'Gemini',
      'ollama' => 'Ollama',
      'ollama-cloud' => 'Ollama Cloud',
      _ => p,
    };
  }

  static Color _colorFor(String p) {
    return switch (p) {
      'claude' => DuckColors.accentDuck,
      'copilot' => DuckColors.accentCyan,
      'gemini' => DuckColors.accentMint,
      'ollama' => DuckColors.accentPurple,
      'ollama-cloud' => DuckColors.accentPurple,
      _ => DuckColors.fgMuted,
    };
  }
}
