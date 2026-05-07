import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../l10n/strings.dart';
import '../../services/council/council_models.dart';
import '../../services/council/council_protocol.dart';
import '../../services/council/council_task_ledger.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/duck_toast.dart';

/// Floating inspection panel for a single Council member.
///
/// Spawned by clicking on an agent card in the orbital ring. Shows the
/// full transcript, ledger task history, and pool exchanges that
/// involve this agent, in a copyable read-only surface that hovers
/// above the council theater. Closes via the × button or by tapping
/// the dimmed scrim outside the panel.
///
/// Animation: scrim fades in (220ms easeOut), panel scales 0.92 → 1.00
/// with a matching opacity ramp. Reverse on close.
class CouncilAgentInspector extends StatefulWidget {
  final CouncilSession session;
  final CouncilAgent agent;
  final VoidCallback onClose;

  const CouncilAgentInspector({
    super.key,
    required this.session,
    required this.agent,
    required this.onClose,
  });

  @override
  State<CouncilAgentInspector> createState() => _CouncilAgentInspectorState();
}

class _CouncilAgentInspectorState extends State<CouncilAgentInspector>
    with SingleTickerProviderStateMixin {
  // Why composited transitions rather than `AnimatedBuilder` rebuilding
  // the whole Stack every tick:
  //
  // The previous version called setState (via AnimatedBuilder) on every
  // animation frame. That re-inflates the entire subtree — including
  // the MouseRegion / SelectionArea / Tooltip widgets inside. Each
  // re-inflation re-registers the MouseTrackerAnnotation. When mouse
  // tracking is mid-update during one of those frames, Flutter trips
  // `!_debugDuringDeviceUpdate` and spams the console (the bug the
  // user filed). FadeTransition + ScaleTransition mutate compositor
  // values directly without rebuilding their child, so MouseRegions
  // are stable across the entrance animation.
  late final AnimationController _enter;
  late final Animation<double> _scrim;
  late final Animation<double> _scale;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 220),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _scrim = CurvedAnimation(parent: _enter, curve: Curves.easeOut);
    _scale = Tween<double>(begin: 0.94, end: 1.0).animate(
      CurvedAnimation(parent: _enter, curve: Curves.easeOutCubic),
    );
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    await _enter.reverse();
    if (!mounted) return;
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _close,
              child: FadeTransition(
                opacity: _scrim,
                child: const ColoredBox(
                  color: Color(0x8C000000),
                ),
              ),
            ),
          ),
          Center(
            child: FadeTransition(
              opacity: _enter,
              child: ScaleTransition(
                scale: _scale,
                child: _InspectorCard(
                  session: widget.session,
                  agent: widget.agent,
                  onClose: _close,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InspectorCard extends StatelessWidget {
  final CouncilSession session;
  final CouncilAgent agent;
  final VoidCallback onClose;

  const _InspectorCard({
    required this.session,
    required this.agent,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final w = (media.size.width * 0.78).clamp(420.0, 880.0);
    final h = (media.size.height * 0.82).clamp(360.0, 720.0);

    final accent = _accentForStatus(agent.status, isOrchestrator: _isOrchestrator);

    final tasks = _tasksForAgent();
    final pool = _poolForAgent();
    final transcript = agent.transcript.trim();

    return Material(
      color: Colors.transparent,
      child: Container(
        width: w,
        height: h,
        decoration: BoxDecoration(
          color: DuckColors.bgRaised,
          borderRadius: BorderRadius.circular(DuckTheme.radiusL),
          border: Border.all(
            color: accent.withValues(alpha: 0.42),
            width: 0.8,
          ),
          boxShadow: [
            BoxShadow(
              color: accent.withValues(alpha: 0.18),
              blurRadius: 30,
              spreadRadius: 1,
            ),
            ...DuckTheme.shadowSoft,
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Header(
              agent: agent,
              isOrchestrator: _isOrchestrator,
              accent: accent,
              onClose: onClose,
            ),
            const Divider(
              height: 1,
              thickness: 1,
              color: DuckColors.glassSeam,
            ),
            Expanded(
              child: SelectionArea(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                  children: [
                    _MetaSection(agent: agent),
                    const SizedBox(height: 18),
                    _SectionHeader(
                      label: S.councilInspectorTranscriptLabel,
                      action: transcript.isEmpty
                          ? null
                          : _CopyAction(
                              text: transcript,
                              tooltip:
                                  S.councilInspectorCopyTranscriptTooltip,
                            ),
                    ),
                    const SizedBox(height: 8),
                    _TranscriptBlock(text: transcript),
                    const SizedBox(height: 22),
                    _SectionHeader(
                      label: S.councilInspectorTasksLabel(tasks.length),
                    ),
                    const SizedBox(height: 8),
                    _TasksList(tasks: tasks),
                    const SizedBox(height: 22),
                    _SectionHeader(
                      label:
                          S.councilInspectorPoolLabel(pool.length),
                    ),
                    const SizedBox(height: 8),
                    _PoolList(pool: pool, agentId: agent.id, session: session),
                    if (agent.lastError.trim().isNotEmpty) ...[
                      const SizedBox(height: 22),
                      _SectionHeader(
                        label: S.councilInspectorLastErrorLabel,
                      ),
                      const SizedBox(height: 8),
                      _ErrorBlock(text: agent.lastError),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  bool get _isOrchestrator => session.config.orchestrator.id == agent.id;

  List<CouncilTask> _tasksForAgent() {
    return [
      for (final t in session.tasks)
        if (t.agentId == agent.id) t,
    ]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  List<CouncilQuestion> _poolForAgent() {
    return [
      for (final q in session.poolQuestions)
        if (q.fromAgentId == agent.id ||
            q.replies.any((r) => r.fromAgentId == agent.id))
          q,
    ];
  }

  static Color _accentForStatus(
    CouncilAgentStatus status, {
    required bool isOrchestrator,
  }) {
    if (status == CouncilAgentStatus.error) return DuckColors.stateError;
    if (status == CouncilAgentStatus.done) return DuckColors.accentCyan;
    if (isOrchestrator) return DuckColors.accentPurple;
    return DuckColors.accentCyan;
  }
}

class _Header extends StatelessWidget {
  final CouncilAgent agent;
  final bool isOrchestrator;
  final Color accent;
  final VoidCallback onClose;

  const _Header({
    required this.agent,
    required this.isOrchestrator,
    required this.accent,
    required this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final role = isOrchestrator
        ? S.councilOrchestrator
        : CouncilProtocol.roleInstruction(agent);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 38,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.85),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: DuckColors.fgPrimary,
                          fontWeight: FontWeight.w800,
                          fontSize: 16,
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _StatusChip(status: agent.status, accent: accent),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  role,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: DuckColors.fgMuted,
                    fontSize: 11.5,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: S.councilInspectorClose,
            onPressed: onClose,
            icon: const Icon(
              Icons.close_rounded,
              size: 20,
              color: DuckColors.fgMuted,
            ),
          ),
        ],
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final CouncilAgentStatus status;
  final Color accent;

  const _StatusChip({required this.status, required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: accent.withValues(alpha: 0.45),
          width: 0.6,
        ),
      ),
      child: Text(
        _label(status),
        style: TextStyle(
          color: accent.withValues(alpha: 0.95),
          fontSize: 9.6,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.85,
        ),
      ),
    );
  }

  String _label(CouncilAgentStatus s) {
    return switch (s) {
      CouncilAgentStatus.idle => 'IDLE',
      CouncilAgentStatus.queued => 'QUEUED',
      CouncilAgentStatus.working => 'WORKING',
      CouncilAgentStatus.askingPool => 'POOL',
      CouncilAgentStatus.awaitingUser => 'WAITING',
      CouncilAgentStatus.replying => 'REPLYING',
      CouncilAgentStatus.done => 'DONE',
      CouncilAgentStatus.error => 'ERROR',
    };
  }
}

class _MetaSection extends StatelessWidget {
  final CouncilAgent agent;

  const _MetaSection({required this.agent});

  @override
  Widget build(BuildContext context) {
    final task = agent.currentTask.trim();
    final model = agent.model.trim().isEmpty ? '—' : agent.model;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MetaRow(label: S.councilInspectorMetaModel, value: model),
          const SizedBox(height: 6),
          _MetaRow(
            label: S.councilInspectorMetaTask,
            value: task.isEmpty ? S.councilInspectorMetaTaskNone : task,
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final String label;
  final String value;
  const _MetaRow({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: DuckColors.fgSubtle,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.7,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 12,
              height: 1.32,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final Widget? action;

  const _SectionHeader({required this.label, this.action});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 2,
          height: 12,
          color: DuckColors.accentCyan.withValues(alpha: 0.85),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
            ),
          ),
        ),
        ?action,
      ],
    );
  }
}

class _CopyAction extends StatelessWidget {
  final String text;
  final String tooltip;

  const _CopyAction({required this.text, required this.tooltip});

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkResponse(
        radius: 16,
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: text));
          if (context.mounted) {
            showDuckToast(context, S.councilInspectorCopied);
          }
        },
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(
            Icons.copy_outlined,
            size: 14,
            color: DuckColors.fgMuted,
          ),
        ),
      ),
    );
  }
}

/// Transcript renderer with stream-debounced markdown.
///
/// **Why MarkdownBody and not Markdown / CouncilReportView:**
/// the inspector body is itself a `ListView`, so the transcript is
/// rendered into an unbounded-height slot. `Markdown` (and therefore
/// `CouncilReportView`, which wraps `Markdown`) is implemented as
/// its own scrolling `ListView` — embedding one inside another gives
/// the inner viewport unbounded height. Result: layout silently
/// collapses to zero (the original "blank panel" bug), with downstream
/// damage spilling into the rendering pipeline. `MarkdownBody` is the
/// non-scrolling, shrink-wrapping primitive — same one the chat
/// bubbles use — and slots into a parent ListView correctly.
///
/// **Why this is stateful:**
/// the parent inspector rebuilds on every `AppState.notifyListeners()`
/// tick (the runner fires per streamed token). Re-running the markdown
/// parser on a continuously-growing string at token rate stalls the
/// main isolate, and any half-streamed ` ``` ` fence throws layout
/// exceptions. We snapshot the transcript and only re-parse when the
/// stream has been quiet for [_settleDelay], OR when [_maxStaleness]
/// has elapsed. Inspector chrome (status, tasks, pool) keeps updating
/// live — only the heavy markdown is throttled.
class _TranscriptBlock extends StatefulWidget {
  final String text;
  const _TranscriptBlock({required this.text});

  /// Strip Lumen's stream-internal markers from a raw transcript so the
  /// markdown renderer doesn't paint them as content. The markers are
  /// stable across the chat and council code paths:
  ///   - `<!-- LUMEN_THINKING ... -->...<!-- /LUMEN_THINKING -->` —
  ///     reasoning blocks; useful in the chat (collapsible) but here
  ///     they'd just be noise. Stripped wholesale.
  ///   - `<!-- LUMEN_TOOL:<base64> -->` — single-line marker pointing to
  ///     a recorded tool call; renders as nothing in the chat too.
  ///   - `<!-- LUMEN_ERR:... -->` and `<!-- LUMEN_TRUNCATED:... -->` —
  ///     stream-internal sentinels.
  /// Anything else passes through verbatim so the agent's prose +
  /// fenced code + headings render properly.
  static String _sanitize(String input) {
    var s = input;
    s = s.replaceAll(
      RegExp(r'<!-- LUMEN_THINKING[^>]*-->[\s\S]*?<!-- /LUMEN_THINKING -->'),
      '',
    );
    s = s.replaceAll(RegExp(r'<!-- LUMEN_TOOL:[^>]*-->'), '');
    s = s.replaceAll(RegExp(r'<!-- LUMEN_ERR:[^>]*-->'), '');
    s = s.replaceAll(RegExp(r'<!-- LUMEN_TRUNCATED:[^>]*-->'), '');

    s = s.replaceAll(
      RegExp(
        r'<<<(?:EDIT_FILE|CREATE_FILE|MULTI_EDIT|APPEND_FILE|EDIT_RANGE):\s*.*?>>>[\s\S]*?<<<END_(?:FILE|EDIT|APPEND)>>>',
        dotAll: true,
      ),
      '[tool call]',
    );
    s = s.replaceAll(
      RegExp(r'<<<[A-Z_]+(?::\s*[^>]*)?\s*>>>'),
      '[tool call]',
    );
    s = s.replaceAll(
      RegExp(r'<tool_result>[\s\S]*?</tool_result>', dotAll: true),
      '',
    );
    s = s.replaceAll(RegExp(r'^\[FAILED\]\s*', multiLine: true), '');

    s = s.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return s.trim();
  }

  /// Drop any markdown that ends mid-fenced-block. An odd number of
  /// ` ``` ` markers means the stream is currently inside a code
  /// block — handing that to the markdown parser mid-flight produces
  /// TextPainter / layout exceptions on the half-formed fence. We
  /// render the prose UP TO the unterminated fence and show a subtle
  /// "streaming" line; the next settle replaces it with a balanced
  /// render.
  static String _trimUnclosedFence(String input) {
    var fences = 0;
    var lastFenceStart = -1;
    final lines = input.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trimLeft().startsWith('```')) {
        fences++;
        lastFenceStart = i;
      }
    }
    if (fences.isEven) return input;
    return lines.sublist(0, lastFenceStart).join('\n').trimRight();
  }

  @override
  State<_TranscriptBlock> createState() => _TranscriptBlockState();
}

class _TranscriptBlockState extends State<_TranscriptBlock> {
  static const Duration _settleDelay = Duration(milliseconds: 350);
  static const Duration _maxStaleness = Duration(milliseconds: 1200);

  Timer? _settleTimer;
  String _settledRaw = '';
  String _settledClean = '';
  DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    final raw = widget.text;
    _settledRaw = raw;
    _settledClean = _TranscriptBlock._sanitize(
      _TranscriptBlock._trimUnclosedFence(raw),
    );
    _lastFlush = DateTime.now();
  }

  @override
  void didUpdateWidget(covariant _TranscriptBlock old) {
    super.didUpdateWidget(old);
    if (widget.text == old.text) return;
    if (widget.text == _settledRaw) return;
    final now = DateTime.now();
    if (now.difference(_lastFlush) >= _maxStaleness) {
      _flush(widget.text);
      return;
    }
    _settleTimer?.cancel();
    _settleTimer = Timer(_settleDelay, () {
      if (!mounted) return;
      _flush(widget.text);
    });
  }

  void _flush(String raw) {
    _settleTimer?.cancel();
    final balanced = _TranscriptBlock._trimUnclosedFence(raw);
    final cleaned = _TranscriptBlock._sanitize(balanced);
    if (!mounted) return;
    setState(() {
      _settledRaw = raw;
      _settledClean = cleaned;
      _lastFlush = DateTime.now();
    });
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final raw = widget.text;
    if (raw.isEmpty) {
      return Text(
        S.councilInspectorTranscriptEmpty,
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 12),
      );
    }
    final streaming = raw != _settledRaw;
    if (_settledClean.isEmpty) {
      return Text(
        S.councilInspectorTranscriptEmpty,
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 12),
      );
    }
    return RepaintBoundary(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: DuckColors.bgDeepest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(color: DuckColors.glassSeam, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // KeyedSubtree forces a clean subtree only when the
            // snapshot LENGTH actually changed, so identical settled
            // snapshots don't re-parse the markdown AST.
            KeyedSubtree(
              key: ValueKey<int>(_settledClean.length),
              child: MarkdownBody(
                data: _settledClean,
                // SelectionArea above (in the inspector card) owns
                // selection — keeping `selectable: false` here
                // prevents flutter_markdown_plus from wrapping every
                // text run in its own SelectableText, which would
                // fight the SelectionArea's drag.
                selectable: false,
                shrinkWrap: true,
                fitContent: true,
                extensionSet: md.ExtensionSet.gitHubFlavored,
                builders: <String, MarkdownElementBuilder>{
                  'pre': _TranscriptCodeBuilder(),
                },
                styleSheet: _transcriptStyleSheet(),
              ),
            ),
            if (streaming)
              const Padding(
                padding: EdgeInsets.fromLTRB(0, 6, 0, 0),
                child: _StreamingHint(),
              ),
          ],
        ),
      ),
    );
  }

  MarkdownStyleSheet _transcriptStyleSheet() {
    return MarkdownStyleSheet(
      h1: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 16,
        height: 1.3,
        fontWeight: FontWeight.w800,
      ),
      h2: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 14.5,
        height: 1.3,
        fontWeight: FontWeight.w800,
      ),
      h3: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 13,
        height: 1.35,
        fontWeight: FontWeight.w700,
      ),
      p: const TextStyle(
        color: DuckColors.fgPrimary,
        fontSize: 12.5,
        height: 1.5,
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
        fontSize: 11.5,
        color: DuckColors.accentCyan,
        backgroundColor: Color(0xFF11161E),
      ),
      codeblockPadding: EdgeInsets.zero,
      codeblockDecoration: const BoxDecoration(),
      blockquoteDecoration: BoxDecoration(
        color: const Color(0xFF11161E),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: const Border(
          left: BorderSide(color: DuckColors.accentPurple, width: 3),
        ),
      ),
      blockquotePadding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      blockquote: const TextStyle(
        color: DuckColors.fgSecondary,
        fontSize: 12,
        fontStyle: FontStyle.italic,
        height: 1.45,
      ),
      listBullet: const TextStyle(
        color: DuckColors.accentMint,
        fontSize: 12.5,
        fontWeight: FontWeight.w700,
      ),
      tableHead: const TextStyle(
        color: DuckColors.fgPrimary,
        fontWeight: FontWeight.w800,
      ),
      tableBody: const TextStyle(
        color: DuckColors.fgSecondary,
        fontSize: 12,
        height: 1.45,
      ),
    );
  }
}

/// Custom `<pre>` builder for the transcript: renders fenced code in
/// a quiet panel with a copy chip. Stays compact (no language pill /
/// outline) since the inspector is small. Mermaid blocks intentionally
/// fall through to plain code rendering — the inspector is not the
/// place for diagram canvases (the report viewer is).
class _TranscriptCodeBuilder extends MarkdownElementBuilder {
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
    final code = inner.textContent.trimRight();
    return _TranscriptCodeBlock(code: code);
  }
}

class _TranscriptCodeBlock extends StatefulWidget {
  final String code;
  const _TranscriptCodeBlock({required this.code});

  @override
  State<_TranscriptCodeBlock> createState() => _TranscriptCodeBlockState();
}

class _TranscriptCodeBlockState extends State<_TranscriptCodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    showDuckToast(context, S.chatMessageCopied);
    Future.delayed(const Duration(milliseconds: 1300), () {
      if (!mounted) return;
      setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0E14),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(color: DuckColors.glassSeam, width: 0.5),
      ),
      clipBehavior: Clip.hardEdge,
      child: Stack(
        children: [
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(10, 9, 36, 9),
            child: SelectableText(
              widget.code,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 11.5,
                color: DuckColors.fgPrimary,
                height: 1.45,
              ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: Tooltip(
              message: _copied
                  ? S.chatCodeBlockCopied
                  : S.chatCodeBlockCopy,
              child: InkResponse(
                radius: 14,
                onTap: _copy,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    _copied ? Icons.check : Icons.copy_outlined,
                    size: 13,
                    color: _copied
                        ? DuckColors.accentMint
                        : DuckColors.fgMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StreamingHint extends StatelessWidget {
  const _StreamingHint();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 10,
          height: 10,
          child: CircularProgressIndicator(
            strokeWidth: 1.4,
            valueColor: AlwaysStoppedAnimation(
              DuckColors.accentCyan.withValues(alpha: 0.7),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          S.councilInspectorTranscriptStreaming,
          style: const TextStyle(
            color: DuckColors.fgMuted,
            fontSize: 10.5,
            fontStyle: FontStyle.italic,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }
}

class _TasksList extends StatelessWidget {
  final List<CouncilTask> tasks;
  const _TasksList({required this.tasks});

  @override
  Widget build(BuildContext context) {
    if (tasks.isEmpty) {
      return Text(
        S.councilInspectorTasksEmpty,
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 12),
      );
    }
    return Column(
      children: [
        for (final t in tasks) ...[
          _TaskRow(task: t),
          const SizedBox(height: 6),
        ],
      ],
    );
  }
}

class _TaskRow extends StatelessWidget {
  final CouncilTask task;
  const _TaskRow({required this.task});

  @override
  Widget build(BuildContext context) {
    final color = _stateColor(task.state);
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: color.withValues(alpha: 0.32),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _stateIcon(task.state),
                size: 14,
                color: color,
              ),
              const SizedBox(width: 6),
              Text(
                task.state.name.toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.8,
                ),
              ),
              const Spacer(),
              Text(
                'attempt ${task.attempts}/${task.maxAttempts}',
                style: const TextStyle(
                  color: DuckColors.fgSubtle,
                  fontSize: 10,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            task.task,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 12,
              height: 1.34,
            ),
          ),
          if ((task.lastError ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              task.lastError!.trim(),
              style: const TextStyle(
                color: DuckColors.stateError,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Color _stateColor(CouncilTaskState s) {
    return switch (s) {
      CouncilTaskState.done => DuckColors.accentCyan,
      CouncilTaskState.failed => DuckColors.stateError,
      CouncilTaskState.timeout => DuckColors.stateError,
      CouncilTaskState.cancelled => DuckColors.fgMuted,
      CouncilTaskState.running => DuckColors.accentCyan,
      CouncilTaskState.dispatched => DuckColors.accentDuck,
      CouncilTaskState.planned => DuckColors.fgMuted,
    };
  }

  IconData _stateIcon(CouncilTaskState s) {
    return switch (s) {
      CouncilTaskState.done => Icons.check_circle_outline,
      CouncilTaskState.failed => Icons.error_outline,
      CouncilTaskState.timeout => Icons.timer_off_outlined,
      CouncilTaskState.cancelled => Icons.cancel_outlined,
      CouncilTaskState.running => Icons.bolt_outlined,
      CouncilTaskState.dispatched => Icons.send_outlined,
      CouncilTaskState.planned => Icons.radio_button_unchecked,
    };
  }
}

class _PoolList extends StatelessWidget {
  final List<CouncilQuestion> pool;
  final String agentId;
  final CouncilSession session;

  const _PoolList({
    required this.pool,
    required this.agentId,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    if (pool.isEmpty) {
      return Text(
        S.councilInspectorPoolEmpty,
        style: const TextStyle(color: DuckColors.fgMuted, fontSize: 12),
      );
    }
    return Column(
      children: [
        for (final q in pool) ...[
          _PoolEntry(question: q, agentId: agentId, session: session),
          const SizedBox(height: 8),
        ],
      ],
    );
  }
}

class _PoolEntry extends StatelessWidget {
  final CouncilQuestion question;
  final String agentId;
  final CouncilSession session;

  const _PoolEntry({
    required this.question,
    required this.agentId,
    required this.session,
  });

  @override
  Widget build(BuildContext context) {
    final asker =
        session.agentById(question.fromAgentId)?.name ?? question.fromAgentId;
    final iAmAsker = question.fromAgentId == agentId;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.bgDeepest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.accentPurple.withValues(alpha: 0.28),
          width: 0.6,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.forum_outlined,
                size: 14,
                color: DuckColors.accentPurple,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  iAmAsker
                      ? S.councilInspectorPoolAsked
                      : S.councilInspectorPoolFrom(asker),
                  style: const TextStyle(
                    color: DuckColors.accentPurple,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.7,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            question.question,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 12,
              height: 1.34,
            ),
          ),
          for (final reply in question.replies)
            if (iAmAsker || reply.fromAgentId == agentId) ...[
              const SizedBox(height: 6),
              _PoolReply(reply: reply, session: session),
            ],
        ],
      ),
    );
  }
}

class _PoolReply extends StatelessWidget {
  final CouncilPoolReply reply;
  final CouncilSession session;

  const _PoolReply({required this.reply, required this.session});

  @override
  Widget build(BuildContext context) {
    final from = session.agentById(reply.fromAgentId)?.name ?? reply.fromAgentId;
    return Container(
      margin: const EdgeInsets.only(left: 12, top: 2),
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
      decoration: BoxDecoration(
        color: DuckColors.accentMint.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.accentMint.withValues(alpha: 0.3),
          width: 0.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            from.toUpperCase(),
            style: const TextStyle(
              color: DuckColors.accentMint,
              fontSize: 9.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.7,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            reply.answer,
            style: const TextStyle(
              color: DuckColors.fgPrimary,
              fontSize: 11.5,
              height: 1.34,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  final String text;
  const _ErrorBlock({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: DuckColors.stateError.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(DuckTheme.radiusM),
        border: Border.all(
          color: DuckColors.stateError.withValues(alpha: 0.4),
          width: 0.7,
        ),
      ),
      child: Text(
        text.trim(),
        style: const TextStyle(
          color: DuckColors.stateError,
          fontSize: 12,
          height: 1.32,
        ),
      ),
    );
  }
}
