import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_glass.dart';
import '../common/duck_toast.dart';
import 'council_report_viewer.dart';

/// Dialog listing every saved council report, newest first.
class CouncilReportsBrowser extends StatefulWidget {
  const CouncilReportsBrowser({super.key});

  @override
  State<CouncilReportsBrowser> createState() => _CouncilReportsBrowserState();
}

class _CouncilReportsBrowserState extends State<CouncilReportsBrowser> {
  late Future<List<CouncilReportEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CouncilReportEntry>> _load() {
    return context.read<AppState>().council.persistence.listReports();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
    });
  }

  Future<void> _delete(CouncilReportEntry entry) async {
    final svc = context.read<AppState>().council.persistence;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(S.councilReportDeleteTitle),
        content: Text(entry.title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text(S.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text(S.delete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await svc.deleteReport(entry);
    if (!mounted) return;
    if (!ok) showDuckToast(context, S.councilReportDeleteFailed);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(36),
      backgroundColor: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720, maxHeight: 720),
        child: DuckGlass(
          tint: const Color(0xF014171D),
          border: Border.all(color: DuckColors.borderStrong, width: 0.6),
          radius: DuckTheme.radiusL,
          child: Column(
            children: [
              _buildHeader(context),
              const Divider(height: 1, color: DuckColors.glassSeam),
              Expanded(child: _buildList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [DuckColors.accentCyan, DuckColors.accentPurple],
              ),
            ),
            child: const Icon(
              Icons.library_books_outlined,
              size: 17,
              color: DuckColors.bgDeepest,
            ),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Text(
              S.councilReportsBrowserTitle,
              style: TextStyle(
                color: DuckColors.fgPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 16,
              ),
            ),
          ),
          IconButton(
            tooltip: S.councilReportsRefresh,
            icon: const Icon(Icons.refresh, color: DuckColors.fgMuted),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: S.councilReportsRevealFolder,
            icon: const Icon(
              Icons.folder_open_outlined,
              color: DuckColors.fgMuted,
            ),
            onPressed: () async {
              final svc = context.read<AppState>().council.persistence;
              final dir = await svc.reportsDirectory();
              await svc.revealInOs(dir.path);
            },
          ),
          IconButton(
            tooltip: S.close,
            icon: const Icon(Icons.close, color: DuckColors.fgMuted),
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildList() {
    return FutureBuilder<List<CouncilReportEntry>>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(
            child: SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final items = snap.data ?? const <CouncilReportEntry>[];
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(36),
              child: Text(
                S.councilReportsBrowserEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(color: DuckColors.fgMuted, height: 1.55),
              ),
            ),
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 18),
          itemCount: items.length,
          separatorBuilder: (_, i) => const SizedBox(height: 8),
          itemBuilder: (context, i) =>
              _ReportTile(entry: items[i], onDelete: () => _delete(items[i])),
        );
      },
    );
  }
}

class _ReportTile extends StatelessWidget {
  final CouncilReportEntry entry;
  final VoidCallback onDelete;

  const _ReportTile({required this.entry, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        onTap: () => showCouncilReportEntryViewer(context, entry),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
          decoration: BoxDecoration(
            color: DuckColors.bgDeepest.withValues(alpha: 0.62),
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            border: Border.all(color: DuckColors.border, width: 0.6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 6,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(3),
                  color: entry.sidecarOk
                      ? DuckColors.accentMint.withValues(alpha: 0.7)
                      : const Color(0xFFD9A441).withValues(alpha: 0.6),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            entry.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: DuckColors.fgPrimary,
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Text(
                          _formatDate(entry.savedAt),
                          style: const TextStyle(
                            color: DuckColors.fgSubtle,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    if (entry.summary.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        entry.summary,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgMuted,
                          fontSize: 12,
                          height: 1.4,
                        ),
                      ),
                    ],
                    if (entry.agentRoster.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        entry.agentRoster.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgSubtle,
                          fontSize: 11,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              IconButton(
                tooltip: S.delete,
                icon: const Icon(
                  Icons.delete_outline,
                  size: 18,
                  color: DuckColors.fgSubtle,
                ),
                onPressed: onDelete,
              ),
            ],
          ),
        ),
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

Future<void> showCouncilReportsBrowser(BuildContext context) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (_) => const CouncilReportsBrowser(),
  );
}
