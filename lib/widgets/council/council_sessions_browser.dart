import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/app_state.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';
import 'council_session_detail_view.dart';

/// Full-tab browser for persisted council sessions. Renders as a
/// master-detail layout: session list on the left, detail view on the
/// right. Opened via the View → Council Sessions menu item.
class CouncilSessionsBrowser extends StatefulWidget {
  const CouncilSessionsBrowser({super.key});

  @override
  State<CouncilSessionsBrowser> createState() => _CouncilSessionsBrowserState();
}

class _CouncilSessionsBrowserState extends State<CouncilSessionsBrowser> {
  late Future<List<CouncilSessionSummary>> _future;
  CouncilSessionSummary? _selected;
  CouncilSession? _loadedSession;
  bool _loadingDetail = false;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<CouncilSessionSummary>> _load() {
    return context.read<AppState>().council.persistence.listSessions();
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load();
      _selected = null;
      _loadedSession = null;
    });
  }

  Future<void> _select(CouncilSessionSummary summary) async {
    if (_selected?.id == summary.id) return;
    setState(() {
      _selected = summary;
      _loadedSession = null;
      _loadingDetail = true;
    });
    final svc = context.read<AppState>().council.persistence;
    final session = await svc.loadSession(summary.id);
    if (!mounted) return;
    setState(() {
      _loadedSession = session;
      _loadingDetail = false;
    });
  }

  Future<void> _delete(CouncilSessionSummary summary) async {
    final svc = context.read<AppState>().council.persistence;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: DuckColors.bgRaised,
        title: const Text(S.councilSessionsDeleteTitle),
        content: Text(summary.title),
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
    final ok = await svc.deleteSession(summary.filePath);
    if (!mounted) return;
    if (!ok) showDuckToast(context, S.councilSessionsDeleteFailed);
    if (_selected?.id == summary.id) {
      _selected = null;
      _loadedSession = null;
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: DuckColors.bgBase,
      child: Row(
        children: [
          SizedBox(
            width: 340,
            child: _buildListPane(),
          ),
          const VerticalDivider(width: 1, color: DuckColors.border),
          Expanded(child: _buildDetailPane()),
        ],
      ),
    );
  }

  Widget _buildListPane() {
    final appState = context.watch<AppState>();
    final hasLiveSession = appState.council.session != null;
    return Column(
      children: [
        _buildListHeader(),
        const Divider(height: 1, color: DuckColors.border),
        if (hasLiveSession) _buildLiveSessionBanner(appState),
        Expanded(child: _buildSessionList()),
      ],
    );
  }

  Widget _buildLiveSessionBanner(AppState appState) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        color: Color(0x1800E5FF),
        border: Border(
          bottom: BorderSide(color: DuckColors.border),
        ),
      ),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: DuckColors.accentCyan,
          side: const BorderSide(color: DuckColors.accentCyan, width: 1),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        icon: const Icon(Icons.visibility_outlined, size: 16),
        label: const Text(
          S.councilOpenLiveSession,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        onPressed: () {
          appState.council.showTheater();
          appState.openCouncilTheaterTab();
        },
      ),
    );
  }

  Widget _buildListHeader() {
    return Container(
      color: DuckColors.bgDeeper,
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [DuckColors.accentCyan, DuckColors.accentPurple],
              ),
            ),
            child: const Icon(
              Icons.groups_outlined,
              size: 15,
              color: DuckColors.bgDeepest,
            ),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              S.councilSessionsTitle,
              style: TextStyle(
                color: DuckColors.fgPrimary,
                fontWeight: FontWeight.w800,
                fontSize: 15,
              ),
            ),
          ),
          IconButton(
            tooltip: S.councilSessionsRefresh,
            iconSize: 18,
            icon: const Icon(Icons.refresh, color: DuckColors.fgMuted),
            onPressed: _refresh,
          ),
        ],
      ),
    );
  }

  Widget _buildSessionList() {
    return FutureBuilder<List<CouncilSessionSummary>>(
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
        final items = snap.data ?? const <CouncilSessionSummary>[];
        if (items.isEmpty) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                S.councilSessionsEmpty,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: DuckColors.fgMuted,
                  height: 1.55,
                  fontSize: 13,
                ),
              ),
            ),
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: items.length,
          itemBuilder: (context, i) {
            final item = items[i];
            final isSelected = _selected?.id == item.id;
            return _SessionTile(
              summary: item,
              selected: isSelected,
              onTap: () => _select(item),
              onDelete: () => _delete(item),
            );
          },
        );
      },
    );
  }

  Widget _buildDetailPane() {
    if (_selected == null) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.groups_outlined, size: 48, color: DuckColors.fgFaint),
            SizedBox(height: 12),
            Text(
              S.councilSessionsTitle,
              style: TextStyle(color: DuckColors.fgSubtle, fontSize: 14),
            ),
          ],
        ),
      );
    }
    if (_loadingDetail) {
      return const Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_loadedSession == null) {
      return const Center(
        child: Text(
          'Session data unavailable.',
          style: TextStyle(color: DuckColors.fgMuted),
        ),
      );
    }
    return CouncilSessionDetailView(
      key: ValueKey(_selected!.id),
      session: _loadedSession!,
      summary: _selected!,
    );
  }
}

class _SessionTile extends StatelessWidget {
  final CouncilSessionSummary summary;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const _SessionTile({
    required this.summary,
    required this.selected,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected ? DuckColors.bgRaisedHi : Colors.transparent,
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        child: InkWell(
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 5,
                  height: 44,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(3),
                    color: _statusColor(summary.status),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        summary.title.isNotEmpty
                            ? summary.title
                            : summary.brief,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgPrimary,
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          Text(
                            _statusLabel(summary.status),
                            style: TextStyle(
                              color: _statusColor(summary.status),
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _formatDate(summary.startedAt),
                            style: const TextStyle(
                              color: DuckColors.fgSubtle,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '${S.councilSessionAgentCount(summary.agentNames.length)}'
                        ' · ${S.councilSessionRoundCount(summary.roundIndex + 1)}'
                        ' · ${summary.eventCount} ${S.councilSessionEventsCount}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgSubtle,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: S.delete,
                  iconSize: 16,
                  icon: const Icon(
                    Icons.delete_outline,
                    color: DuckColors.fgSubtle,
                  ),
                  onPressed: onDelete,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static Color _statusColor(String status) {
    switch (status) {
      case 'done':
        return DuckColors.stateOk;
      case 'error':
        return DuckColors.stateError;
      case 'aborted':
        return DuckColors.stateWarn;
      case 'working':
      case 'dispatching':
      case 'synthesizing':
        return DuckColors.accentCyan;
      default:
        return DuckColors.fgSubtle;
    }
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'done':
        return 'Done';
      case 'error':
        return 'Error';
      case 'aborted':
        return 'Aborted';
      case 'working':
        return 'Working';
      case 'dispatching':
        return 'Dispatching';
      case 'synthesizing':
        return 'Synthesizing';
      case 'awaitingUser':
        return 'Awaiting User';
      case 'awaitingPool':
        return 'Awaiting Pool';
      case 'awaitingFollowup':
        return 'Awaiting Follow-up';
      default:
        return 'Idle';
    }
  }

  static String _formatDate(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }
}
