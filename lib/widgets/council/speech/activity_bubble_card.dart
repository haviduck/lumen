/// The visual surface for a single agent's activity bubble.
///
/// Renders the persistent narration card driven by [AgentNarration].
/// Text content is animated via [AnimatedSwitcher] so status changes
/// cross-fade smoothly. A breathing border conveys "alive"; a typing
/// indicator runs when chunks are flowing; an event-flash sweep
/// reinforces newsworthy transitions.
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../../../l10n/strings.dart';
import '../../../theme/app_colors.dart';
import 'activity_models.dart';

/// CSS-class style mixin: shared global text style for the primary
/// narration line. Per-bubble overrides happen via the [tone] field
/// in [AgentNarration], not by replacing the style wholesale.
const TextStyle kActivityPrimaryText = TextStyle(
  color: DuckColors.fgPrimary,
  fontSize: 13,
  height: 1.36,
  fontWeight: FontWeight.w500,
  letterSpacing: 0.05,
);

const TextStyle kActivitySecondaryText = TextStyle(
  color: DuckColors.fgMuted,
  fontSize: 11,
  height: 1.32,
  fontWeight: FontWeight.w500,
);

/// Width contract for an activity column (consumed by the layer's
/// placement algorithm as well — see `_columnWidth` there).
const double kActivityBubbleWidth = 288;

/// Which side of the agent card the bubble sits on. Drives the
/// speech-bubble tail orientation.
enum BubbleAnchorSide { right, left, above, below }

class ActivityBubbleCard extends StatefulWidget {
  const ActivityBubbleCard({
    super.key,
    required this.narration,
    required this.agentLabel,
    required this.side,
    required this.breathT,
  });

  final AgentNarration narration;
  final String agentLabel;
  final BubbleAnchorSide side;

  /// Shared 0..1 breathing phase pumped from the layer's ticker. Lets
  /// every bubble pulse in sync (cheaper than per-card tickers).
  final double breathT;

  @override
  State<ActivityBubbleCard> createState() => _ActivityBubbleCardState();
}

class _ActivityBubbleCardState extends State<ActivityBubbleCard>
    with TickerProviderStateMixin {
  // Entrance: bubble materializes out of the agent card edge.
  late final AnimationController _enter;
  // Event flash sweep: a hairline of accent paints across the top
  // edge whenever a new flash overlay takes the primary line.
  late final AnimationController _flashSweep;
  // Alert shake: short horizontal jitter when an error flash arrives.
  late final AnimationController _shake;

  AgentNarration? _lastNarration;

  @override
  void initState() {
    super.initState();
    _enter = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 340),
    )..forward();
    _flashSweep = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 720),
    );
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _lastNarration = widget.narration;
  }

  @override
  void didUpdateWidget(covariant ActivityBubbleCard old) {
    super.didUpdateWidget(old);
    final next = widget.narration;
    final prev = _lastNarration;
    if (prev == null || prev.primary != next.primary || prev.tone != next.tone) {
      _flashSweep.forward(from: 0);
      if (next.tone == NarrationTone.alert &&
          (prev?.tone ?? NarrationTone.idle) != NarrationTone.alert) {
        _shake.forward(from: 0);
      }
      _lastNarration = next;
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    _flashSweep.dispose();
    _shake.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([_enter, _flashSweep, _shake]),
      builder: (context, _) {
        final eEase = Curves.easeOutCubic.transform(_enter.value);
        final scale = 0.94 + 0.06 * eEase;
        final opacity =
            (widget.narration.fading ? (1.0 - 0.45) : 1.0) * eEase;
        final shake = _shake.isAnimating
            ? math.sin(_shake.value * math.pi * 6) * 4 * (1 - _shake.value)
            : 0.0;
        return Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(shake, 0),
            child: Transform.scale(
              scale: scale,
              alignment: _scaleAnchorForSide(widget.side),
              child: _buildShell(context),
            ),
          ),
        );
      },
    );
  }

  Widget _buildShell(BuildContext context) {
    final accent = _accentFor(widget.narration.tone);
    final isAlert = widget.narration.tone == NarrationTone.alert;
    final breathing = _isBreathingTone(widget.narration.tone);
    // Border alpha gently breathes on active states. Stays steady
    // when idle / done / fading so finished cards read as quiet.
    final borderAlphaBase = isAlert ? 0.78 : 0.42;
    final borderAlpha = breathing
        ? borderAlphaBase + 0.18 * widget.breathT
        : borderAlphaBase;
    final borderWidth = isAlert ? 1.2 : 0.9;

    return ConstrainedBox(
      constraints:
          const BoxConstraints(maxWidth: kActivityBubbleWidth, minWidth: 180),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              // BUBBLE_BG_BEGIN — bubble surface FILL must be fully
              // opaque (alpha == 1.0) so narration text is readable
              // over any council canvas content. The opacity test
              // (test/widgets/council/council_speech_bubble_opacity_test.dart)
              // scans inside these markers and rejects any
              // .withValues(alpha: <1), .withOpacity(<1), or
              // Color(0x__...) where the alpha byte is < 0xFF.
              // The border (translucent for "alive" breathing) and
              // shadow stack (necessarily translucent) sit OUTSIDE
              // the markers on purpose.
              color: DuckColors.councilBubbleBg,
              borderRadius: BorderRadius.circular(10),
              // BUBBLE_BG_END
              border: Border.all(
                color: accent.withValues(alpha: borderAlpha),
                width: borderWidth,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: isAlert ? 0.22 : 0.10),
                  blurRadius: isAlert ? 18 : 12,
                  spreadRadius: -2,
                ),
                const BoxShadow(
                  color: Color(0xB3000000),
                  blurRadius: 18,
                  spreadRadius: -4,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            child: _buildBody(accent),
          ),
          // Flash sweep — a thin accent hairline that travels across
          // the top edge for the first ~700ms of a content change.
          if (_flashSweep.isAnimating)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _FlashSweepPainter(
                    t: _flashSweep.value,
                    accent: accent,
                  ),
                ),
              ),
            ),
          // Speech-bubble tail — small triangle on the card-facing edge.
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _TailPainter(side: widget.side, accent: accent),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(Color accent) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildEyebrow(accent),
          const SizedBox(height: 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 320),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, 0.18),
                  end: Offset.zero,
                ).animate(anim),
                child: child,
              ),
            ),
            child: Text(
              widget.narration.primary,
              key: ValueKey(widget.narration.primary),
              softWrap: true,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: kActivityPrimaryText,
            ),
          ),
          if (widget.narration.secondary.isNotEmpty) ...[
            const SizedBox(height: 4),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 280),
              child: Text(
                widget.narration.secondary,
                key: ValueKey(widget.narration.secondary),
                softWrap: true,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: kActivitySecondaryText,
              ),
            ),
          ],
          if (widget.narration.streaming) ...[
            const SizedBox(height: 6),
            _TypingPulse(accent: accent, t: widget.breathT),
          ],
          const SizedBox(height: 6),
          _buildHintRow(),
        ],
      ),
    );
  }

  Widget _buildEyebrow(Color accent) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Tone glyph — a small filled square with a halo. Picked over
        // a Material icon so the bubble keeps its custom voice.
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: accent,
            borderRadius: BorderRadius.circular(2),
            boxShadow: [
              BoxShadow(
                color: accent.withValues(alpha: 0.55),
                blurRadius: 6,
              ),
            ],
          ),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            widget.agentLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: accent.withValues(alpha: 0.96),
              fontSize: 10.6,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.85,
            ),
          ),
        ),
        const SizedBox(width: 8),
        _StatusChip(
          label: widget.narration.statusLabel,
          accent: accent,
        ),
      ],
    );
  }

  Widget _buildHintRow() {
    return Opacity(
      opacity: 0.55,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.touch_app_outlined,
            size: 10,
            color: DuckColors.fgMuted,
          ),
          const SizedBox(width: 4),
          Text(
            S.councilActivityTapToInspect,
            style: const TextStyle(
              color: DuckColors.fgMuted,
              fontSize: 9.6,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.65,
            ),
          ),
        ],
      ),
    );
  }

  Alignment _scaleAnchorForSide(BubbleAnchorSide side) {
    switch (side) {
      case BubbleAnchorSide.right:
        return Alignment.centerLeft;
      case BubbleAnchorSide.left:
        return Alignment.centerRight;
      case BubbleAnchorSide.above:
        return Alignment.bottomCenter;
      case BubbleAnchorSide.below:
        return Alignment.topCenter;
    }
  }

  bool _isBreathingTone(NarrationTone t) {
    return t == NarrationTone.working ||
        t == NarrationTone.awaiting ||
        t == NarrationTone.alert;
  }

  Color _accentFor(NarrationTone tone) {
    switch (tone) {
      case NarrationTone.idle:
        return DuckColors.councilAccentDim;
      case NarrationTone.working:
        return DuckColors.accentCyan;
      case NarrationTone.awaiting:
        return DuckColors.accentDuck;
      case NarrationTone.alert:
        return DuckColors.stateError;
      case NarrationTone.success:
        return DuckColors.accentMint;
    }
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label, required this.accent});
  final String label;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.13),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: accent.withValues(alpha: 0.45),
          width: 0.7,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: accent.withValues(alpha: 0.96),
          fontSize: 9.0,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.7,
        ),
      ),
    );
  }
}

/// 3 dots that fade in/out in sequence to indicate the agent is
/// actively streaming tokens. Reuses the shared breath phase from
/// the bubbles layer so we don't spin a per-card ticker.
class _TypingPulse extends StatelessWidget {
  const _TypingPulse({required this.accent, required this.t});
  final Color accent;
  final double t;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < 3; i++) ...[
          _Dot(
            opacity: _dotOpacity(t, i),
            accent: accent,
          ),
          if (i < 2) const SizedBox(width: 4),
        ],
        const SizedBox(width: 8),
        Text(
          S.councilActivityStreaming,
          style: TextStyle(
            color: accent.withValues(alpha: 0.80),
            fontSize: 9.4,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.7,
          ),
        ),
      ],
    );
  }

  double _dotOpacity(double t, int i) {
    // Travelling pulse: each dot peaks at its phase offset.
    final phase = (t * 3 - i / 1.6) % 1.0;
    final wave = (math.sin(phase * math.pi).clamp(0.0, 1.0)).toDouble();
    return 0.25 + 0.75 * wave;
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.opacity, required this.accent});
  final double opacity;
  final Color accent;
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 6,
      height: 6,
      decoration: BoxDecoration(
        color: accent.withValues(alpha: opacity),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

class _FlashSweepPainter extends CustomPainter {
  _FlashSweepPainter({required this.t, required this.accent});
  final double t;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width < 4 || size.height < 4) return;
    final eased = Curves.easeInOutQuad.transform(t.clamp(0.0, 1.0));
    final w = 48.0;
    final x = -w + (size.width + w * 2) * eased;
    final paint = Paint()
      ..shader = LinearGradient(
        colors: [
          accent.withValues(alpha: 0.0),
          accent.withValues(alpha: 0.85),
          accent.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.5, 1.0],
      ).createShader(Rect.fromLTWH(x, 0, w, 2.4));
    canvas.drawRect(Rect.fromLTWH(x, 0, w, 2.4), paint);
  }

  @override
  bool shouldRepaint(covariant _FlashSweepPainter old) =>
      old.t != t || old.accent != accent;
}

class _TailPainter extends CustomPainter {
  _TailPainter({required this.side, required this.accent});
  final BubbleAnchorSide side;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    // Tail is small and tucked just outside the bubble rect, on the
    // side that faces the originating agent card. Paint both a fill
    // (matches bubble surface) and a 1px stroke (matches border) so
    // the tail reads as part of the chassis.
    final path = Path();
    const tailDepth = 7.0;
    const tailHalf = 5.0;
    final cy = math.min(size.height * 0.5, 26.0);
    switch (side) {
      case BubbleAnchorSide.right:
        // Tail points LEFT toward the agent card (which is to the left).
        path.moveTo(0, cy - tailHalf);
        path.lineTo(-tailDepth, cy);
        path.lineTo(0, cy + tailHalf);
        break;
      case BubbleAnchorSide.left:
        // Tail points RIGHT toward the agent card.
        path.moveTo(size.width, cy - tailHalf);
        path.lineTo(size.width + tailDepth, cy);
        path.lineTo(size.width, cy + tailHalf);
        break;
      case BubbleAnchorSide.above:
        // Tail points DOWN toward the agent card (below).
        path.moveTo(size.width / 2 - tailHalf, size.height);
        path.lineTo(size.width / 2, size.height + tailDepth);
        path.lineTo(size.width / 2 + tailHalf, size.height);
        break;
      case BubbleAnchorSide.below:
        // Tail points UP toward the agent card (above).
        path.moveTo(size.width / 2 - tailHalf, 0);
        path.lineTo(size.width / 2, -tailDepth);
        path.lineTo(size.width / 2 + tailHalf, 0);
        break;
    }
    final fill = Paint()..color = DuckColors.councilBubbleBg;
    final stroke = Paint()
      ..color = accent.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.9;
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _TailPainter old) =>
      old.side != side || old.accent != accent;
}
