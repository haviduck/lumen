import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_persistence_service.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';

/// Detail panel shown when a session is selected in the sessions browser.
/// Uses a `TabBar` with four tabs: Overview, Transcripts, Events, Report.
class CouncilSessionDetailView extends StatefulWidget {
  final CouncilSession session;
  final CouncilSessionSummary summary;

  const CouncilSessionDetailView({
    super.key,
    required this.session,
    required this.summary,
  });

  @override
  State<CouncilSessionDetailView> createState() =>
      _CouncilSessionDetailViewState();
}

class _CouncilSessionDetailViewState extends State<CouncilSessionDetailView>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(),
        const Divider(height: 1, color: DuckColors.border),
        _buildTabBar(),
        const Divider(height: 1, color: DuckColors.border),
        Expanded(
          child: TabBarView(
            controller: _tab,
            children: [
              _OverviewTab(session: widget.session, summary: widget.summary),
              _TranscriptsTab(session: widget.session),
              _EventsTab(session: widget.session),
              _ReportTab(session: widget.session),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHeader() {
    final s = widget.summary;
    return Container(
      color: DuckColors.bgDeeper,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.title.isNotEmpty ? s.title : s.brief,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgPrimary,
                    fontWeight: FontWeight.w800,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_statusLabel(s.status)} · '
                  '${_formatDate(s.startedAt)}'
                  '${s.duration != null ? ' · ${_formatDuration(s.duration!)}' : ''}',
                  style: const TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    return Container(
      color: DuckColors.bgDeeper,
      child: TabBar(
        controller: _tab,
        isScrollable: true,
        tabAlignment: TabAlignment.start,
        indicatorColor: DuckColors.accentCyan,
        indicatorWeight: 2,
        labelColor: DuckColors.fgPrimary,
        unselectedLabelColor: DuckColors.fgMuted,
        labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        unselectedLabelStyle: const TextStyle(fontSize: 13),
        dividerColor: Colors.transparent,
        tabs: const [
          Tab(text: S.councilSessionTabOverview),
          Tab(text: S.councilSessionTabTranscripts),
          Tab(text: S.councilSessionTabEvents),
          Tab(text: S.councilSessionTabReport),
        ],
      ),
    );
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
      default:
        return status[0].toUpperCase() + status.substring(1);
    }
  }

  static String _formatDate(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${l.year}-${two(l.month)}-${two(l.day)} '
        '${two(l.hour)}:${two(l.minute)}';
  }

  static String _formatDuration(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    if (d.inMinutes > 0) {
      return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
    }
    return '${d.inSeconds}s';
  }
}

// ─── Overview Tab ──────────────────────────────────────────────

class _OverviewTab extends StatelessWidget {
  final CouncilSession session;
  final CouncilSessionSummary summary;

  const _OverviewTab({required this.session, required this.summary});

  @override
  Widget build(BuildContext context) {
    final config = session.config;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _SectionCard(
          title: S.councilSessionBriefLabel,
          child: SelectableText(
            config.brief,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: S.councilSessionStatusLabel,
          child: _buildStatusGrid(),
        ),
        const SizedBox(height: 16),
        _SectionCard(
          title: S.councilSessionAgentsLabel,
          child: _buildAgentList(),
        ),
      ],
    );
  }

  Widget _buildStatusGrid() {
    return Column(
      children: [
        _kvRow(S.councilSessionStatusLabel, summary.status),
        _kvRow(
          S.councilSessionRoundsLabel,
          '${summary.roundIndex + 1}',
        ),
        _kvRow(
          S.councilSessionStartedLabel,
          _CouncilSessionDetailViewState._formatDate(summary.startedAt),
        ),
        if (summary.finishedAt != null)
          _kvRow(
            S.councilSessionFinishedLabel,
            _CouncilSessionDetailViewState._formatDate(summary.finishedAt!),
          ),
        if (summary.duration != null)
          _kvRow(
            S.councilSessionDurationLabel,
            _CouncilSessionDetailViewState._formatDuration(summary.duration!),
          ),
      ],
    );
  }

  Widget _kvRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: const TextStyle(
                color: DuckColors.fgMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAgentList() {
    final agents = session.config.allAgents;
    return Column(
      children: [
        for (final agent in agents) _agentRow(agent),
      ],
    );
  }

  Widget _agentRow(CouncilAgent agent) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _agentStatusColor(agent.status),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              agent.name,
              style: const TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            agent.role.name,
            style: const TextStyle(
              color: DuckColors.fgSubtle,
              fontSize: 11,
            ),
          ),
          const SizedBox(width: 12),
          Text(
            agent.model.isNotEmpty ? agent.model : '—',
            style: const TextStyle(
              color: DuckColors.fgSubtle,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  static Color _agentStatusColor(CouncilAgentStatus status) {
    switch (status) {
      case CouncilAgentStatus.done:
        return DuckColors.stateOk;
      case CouncilAgentStatus.error:
        return DuckColors.stateError;
      case CouncilAgentStatus.working:
      case CouncilAgentStatus.askingPool:
      case CouncilAgentStatus.replying:
        return DuckColors.accentCyan;
      default:
        return DuckColors.fgSubtle;
    }
  }
}

// ─── Transcripts Tab ───────────────────────────────────────────

class _TranscriptsTab extends StatefulWidget {
  final CouncilSession session;

  const _TranscriptsTab({required this.session});

  @override
  State<_TranscriptsTab> createState() => _TranscriptsTabState();
}

class _TranscriptsTabState extends State<_TranscriptsTab> {
  String? _expandedAgentId;

  @override
  Widget build(BuildContext context) {
    final agents = widget.session.config.allAgents
        .where((a) => a.transcript.trim().isNotEmpty)
        .toList();

    if (agents.isEmpty) {
      return const Center(
        child: Text(
          S.councilSessionNoTranscript,
          style: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: agents.length,
      itemBuilder: (context, i) {
        final agent = agents[i];
        final expanded = _expandedAgentId == agent.id;
        return _TranscriptCard(
          agent: agent,
          expanded: expanded,
          onToggle: () {
            setState(() {
              _expandedAgentId = expanded ? null : agent.id;
            });
          },
        );
      },
    );
  }
}

class _TranscriptCard extends StatelessWidget {
  final CouncilAgent agent;
  final bool expanded;
  final VoidCallback onToggle;

  const _TranscriptCard({
    required this.agent,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: expanded ? DuckColors.borderStrong : DuckColors.border,
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(DuckTheme.radiusM),
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              child: Row(
                children: [
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_down
                        : Icons.keyboard_arrow_right,
                    size: 18,
                    color: DuckColors.fgMuted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${agent.name} (${agent.role.name})',
                      style: const TextStyle(
                        color: DuckColors.fgPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: S.councilReportCopyPath,
                    iconSize: 16,
                    icon: const Icon(
                      Icons.copy_outlined,
                      color: DuckColors.fgSubtle,
                    ),
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: agent.transcript),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            const Divider(height: 1, color: DuckColors.border),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 500),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(14),
                child: SelectableText(
                  agent.transcript,
                  style: const TextStyle(
                    color: DuckColors.fgSecondary,
                    fontSize: 12,
                    height: 1.55,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Events Tab ────────────────────────────────────────────────

class _EventsTab extends StatelessWidget {
  final CouncilSession session;

  const _EventsTab({required this.session});

  @override
  Widget build(BuildContext context) {
    final events = session.events;
    if (events.isEmpty) {
      return const Center(
        child: Text(
          S.councilSessionNoEvents,
          style: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: events.length,
      itemBuilder: (context, i) => _EventRow(event: events[i], index: i),
    );
  }
}

class _EventRow extends StatelessWidget {
  final CouncilEvent event;
  final int index;

  const _EventRow({required this.event, required this.index});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: index.isEven
            ? DuckColors.bgDeepest.withValues(alpha: 0.3)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: DuckColors.fgSubtle,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: Text(
              _formatTime(event.createdAt),
              style: const TextStyle(
                color: DuckColors.fgSubtle,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: _eventTypeColor(event.type).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              event.type,
              style: TextStyle(
                color: _eventTypeColor(event.type),
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),
          if (event.fromAgentId.isNotEmpty) ...[
            Text(
              event.fromAgentId,
              style: const TextStyle(
                color: DuckColors.accentMint,
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (event.toAgentId.isNotEmpty) ...[
              const Text(
                ' → ',
                style: TextStyle(color: DuckColors.fgSubtle, fontSize: 11),
              ),
              Text(
                event.toAgentId,
                style: const TextStyle(
                  color: DuckColors.accentPurple,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(width: 10),
          ],
          if (event.message.isNotEmpty)
            Expanded(
              child: Text(
                event.message.length > 200
                    ? '${event.message.substring(0, 200)}…'
                    : event.message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: DuckColors.fgMuted,
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            )
          else
            const Spacer(),
        ],
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final l = dt.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}';
  }

  static Color _eventTypeColor(String type) {
    if (type.contains('error') || type.contains('failed')) {
      return DuckColors.stateError;
    }
    if (type.contains('done') || type.contains('completed')) {
      return DuckColors.stateOk;
    }
    if (type.contains('started') || type.contains('arrived')) {
      return DuckColors.accentCyan;
    }
    if (type.contains('user') || type.contains('ping')) {
      return DuckColors.accentDuck;
    }
    if (type.contains('dispatch') || type.contains('task')) {
      return DuckColors.accentPurple;
    }
    return DuckColors.fgMuted;
  }
}

// ─── Report Tab ────────────────────────────────────────────────

class _ReportTab extends StatelessWidget {
  final CouncilSession session;

  const _ReportTab({required this.session});

  @override
  Widget build(BuildContext context) {
    final md = session.reportMarkdown.trim();
    if (md.isEmpty) {
      return const Center(
        child: Text(
          S.councilSessionNoReport,
          style: TextStyle(color: DuckColors.fgMuted, fontSize: 13),
        ),
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
          color: DuckColors.bgDeeper,
          child: Row(
            children: [
              const Icon(
                Icons.description_outlined,
                size: 16,
                color: DuckColors.fgMuted,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  session.reportPath.isNotEmpty
                      ? session.reportPath
                      : S.councilSessionTabReport,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgSubtle,
                    fontSize: 11,
                  ),
                ),
              ),
              IconButton(
                tooltip: S.councilReportCopyPath,
                iconSize: 16,
                icon: const Icon(
                  Icons.copy_outlined,
                  color: DuckColors.fgSubtle,
                ),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: md));
                },
              ),
            ],
          ),
        ),
        const Divider(height: 1, color: DuckColors.border),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: SelectableText(
              md,
              style: const TextStyle(
                color: DuckColors.fgPrimary,
                fontSize: 13,
                height: 1.6,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Shared card ───────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final Widget child;

  const _SectionCard({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.border, width: 0.6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              title,
              style: const TextStyle(
                color: DuckColors.fgMuted,
                fontWeight: FontWeight.w700,
                fontSize: 12,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const Divider(height: 1, color: DuckColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
            child: child,
          ),
        ],
      ),
    );
  }
}
