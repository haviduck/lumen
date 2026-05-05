import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../providers/chat_controller.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../common/fast_popup_menu.dart';

/// Pending-approval card docked above the chat input.
///
/// ```
/// ┌───────────────────────────────────────────┐
/// │ RUN_CMD                                   │
/// │ npm install some-very-long-package-name   │
/// │                                           │
/// │                       Reject  [Accept ▾]  │
/// └───────────────────────────────────────────┘
/// ```
///
/// Vertical layout — three stacked sections inside one rounded,
/// `bgChip` card with horizontal margin from the chat panel edges.
/// The card visually pairs with the chat input field below it
/// (same `bgChip` surface tier) so the user reads "approval +
/// input" as a single chrome group, not a banner stuck on top.
///
/// Going vertical (vs. the old single-row strip that crammed
/// label + command + buttons onto one line) gives the card clear
/// top and bottom edges — so it visually decouples from the
/// queued-prompts strip above it. The queued strip is single-line
/// passive entries; this is a tall waiting-on-you card. They no
/// longer look like one continuous band of chrome.
///
/// Action layout follows Cursor's split-button pattern:
///  - `Reject` is a plain text-link, dim by default → red on hover.
///  - `Accept ▾` is a split button. Tapping the **label** half
///    accepts THIS request only via `respondToApproval(true)`.
///    Tapping the **chevron** half opens a 2-item menu:
///      - "Allow once"   → accept this request only
///      - "Always run" / "Always allow" (label depends on tool) →
///        register `_autoApprovedTools` via
///        `setCommandAutoApproved(...)` (per-binary granularity
///        for `run_cmd`, e.g. `run_cmd:npm`) then accept this
///        request, so future calls of the same tool/binary bypass
///        the gate. The label flips to "Always run" for
///        `run_cmd` and "Allow always" for everything else.
///
/// Multi-line commands stay reachable via a chevron next to the
/// command — toggles an inline scrollable mono block between the
/// command line and the action row, still inside the card.
///
/// Naming kept as `approval_card.dart` for git-history continuity
/// even though the export is `ApprovalStrip`.
class ApprovalStrip extends StatefulWidget {
  final ChatController controller;
  final PendingApproval approval;

  const ApprovalStrip({
    super.key,
    required this.controller,
    required this.approval,
  });

  @override
  State<ApprovalStrip> createState() => _ApprovalStripState();
}

class _ApprovalStripState extends State<ApprovalStrip> {
  bool _expanded = false;

  bool get _multiline => widget.approval.detail.contains('\n');
  String get _firstLine => widget.approval.detail.split('\n').first;

  /// What this row's "Always" key would actually grant. For
  /// `run_cmd` this is the binary name (first whitespace-separated
  /// token of the command), e.g. `npm` or `git`. For every other
  /// tool, the empty string — there's no per-argument granularity,
  /// so we fall back to a tool-level grant ("always allow this
  /// tool"). The dropdown uses this string to render an honest
  /// "Always run npm" label so the user sees the scope before
  /// committing.
  String get _alwaysFingerprint {
    if (widget.approval.toolId != 'run_cmd') return '';
    final trimmed = widget.approval.detail.trim();
    if (trimmed.isEmpty) return '';
    final firstToken = trimmed.split(RegExp(r'\s+')).first;
    return firstToken;
  }

  /// Human-readable label for the "Always" menu item. Three flavours:
  ///  - `run_cmd` with a concrete binary  → "Always run `npm`"
  ///    (mono fingerprint shown alongside the verb).
  ///  - `run_cmd` with no detectable binary → "Always run" (just
  ///    the existing verb; falls back to the tool-level grant).
  ///  - any other tool → "Allow always" (tool-level grant).
  String get _alwaysLabel => widget.approval.toolId == 'run_cmd'
      ? S.toolApprovalAlwaysRun
      : S.toolApprovalAllowAlways;

  void _acceptOnce() => widget.controller.respondToApproval(true);

  /// "Always" path — register the per-command blanket approval
  /// first so a fast follow-up call of the same binary (already in
  /// flight in the next iteration) hits the auto-approve fast path,
  /// THEN answer the current pending request. Order matters:
  /// flipping the bit after `respondToApproval` would race against
  /// the chat controller's iteration loop.
  Future<void> _acceptAlways() async {
    await widget.controller.setCommandAutoApproved(
      widget.approval.toolId,
      widget.approval.detail,
    );
    if (!mounted) return;
    widget.controller.respondToApproval(true);
  }

  void _reject() => widget.controller.respondToApproval(false);

  @override
  Widget build(BuildContext context) {
    final approval = widget.approval;
    // Vertical card layout — three stacked rows inside one rounded
    // container:
    //   1. Tool label  (small, dim, mono)
    //   2. Command     (mono, prominent, on its own line so a long
    //                  command can take its width without competing
    //                  with the buttons; also wraps to up to 3 lines
    //                  before ellipsing)
    //   3. Action row  (Reject + Accept ▾, right-aligned)
    //
    // Replaces the previous single-row strip layout that crammed
    // label + command + buttons into one line: that read as a
    // dense banner squeezed between the queued-prompts strip and
    // the input field, with no breathing room separating it from
    // either neighbour. Going vertical gives the card a clear top
    // and bottom edge, so it visually decouples from the queued
    // strip above it (the queued strip is single-line passive
    // entries; this one is a tall waiting-on-you card — they no
    // longer look like one continuous band of chrome).
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
      child: Container(
        decoration: BoxDecoration(
          // `bgChip` puts the card on the same surface tier as the
          // input field below — they pair visually as "input area
          // chrome" and the user reads the approval as a
          // pre-input gate, not a banner.
          color: DuckColors.bgChip,
          borderRadius: BorderRadius.circular(DuckTheme.radiusM),
          border: Border.all(
            color: DuckColors.glassSeam,
            width: 0.5,
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Row 1: tool label ─────────────────────────────
            Text(
              approval.label,
              style: const TextStyle(
                fontFamily: DuckTheme.monoFont,
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
                color: DuckColors.fgSubtle,
              ),
            ),
            const SizedBox(height: 6),
            // ── Row 2: command preview ────────────────────────
            // On its own line so the command can use the full card
            // width before truncating. Tap to toggle expansion when
            // the detail is multi-line. Up to 3 lines visible
            // collapsed; expansion shows the full block in a
            // scroll-capped pane below.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _multiline
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      _firstLine,
                      maxLines: _multiline && _expanded ? 1 : 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: DuckTheme.monoFont,
                        fontSize: 12.5,
                        color: DuckColors.fgPrimary,
                        height: 1.4,
                      ),
                    ),
                  ),
                  if (_multiline) ...[
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Icon(
                        _expanded
                            ? Icons.keyboard_arrow_up
                            : Icons.keyboard_arrow_down,
                        size: 14,
                        color: DuckColors.fgSubtle,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // ── Multi-line expansion (between command and buttons) ─
            // Lives INSIDE the card and slots between the command
            // preview and the action row. A subtle top-margin
            // separator (just whitespace, no divider line — the
            // line was visual noise inside what's already a
            // bordered card) keeps the section visually distinct.
            if (_expanded && _multiline) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 220),
                child: SingleChildScrollView(
                  child: SelectableText(
                    approval.detail,
                    style: const TextStyle(
                      fontFamily: DuckTheme.monoFont,
                      fontSize: 12,
                      color: DuckColors.fgMuted,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 10),
            // ── Row 3: action buttons ─────────────────────────
            // Right-aligned. Reject as text-link, Accept as
            // split-button with dropdown. Same Cursor pattern.
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                _RejectLink(onTap: _reject),
                const SizedBox(width: 8),
                _AcceptSplitButton(
                  alwaysLabel: _alwaysLabel,
                  alwaysFingerprint: _alwaysFingerprint,
                  onAcceptOnce: _acceptOnce,
                  onAcceptAlways: _acceptAlways,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Plain text "Reject" action — dim at rest, red on hover. Same
/// near-invisible default state as the queued strip's row actions
/// so the panel reads as calm; the colour only blooms when the
/// user is about to commit. No background / pill chrome.
class _RejectLink extends StatefulWidget {
  final VoidCallback onTap;
  const _RejectLink({required this.onTap});

  @override
  State<_RejectLink> createState() => _RejectLinkState();
}

class _RejectLinkState extends State<_RejectLink> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Text(
            S.toolApprovalDeny,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: _hover ? DuckColors.stateError : DuckColors.fgMuted,
              height: 1.2,
              letterSpacing: 0.2,
            ),
          ),
        ),
      ),
    );
  }
}

/// Cursor-style split button: `[ Accept ▾ ]`.
///
/// Two independent click targets sharing one rounded chip:
///  - **Label half** → `onAcceptOnce`: accept just this call.
///  - **Chevron half** → opens a `showFastMenu` with two entries:
///      - Allow once → `onAcceptOnce`
///      - "Always run" / "Allow always" (per `alwaysLabel`) →
///        `onAcceptAlways`, which the parent uses to register the
///        per-tool blanket approval.
///
/// The two halves are separated by a 0.5px hairline so the affordance
/// is clear without making either half feel like a separate button.
/// Cyan accent at low alpha for the chip background; both halves
/// pick up a slightly stronger tint on hover so the user can
/// preview which half their click will land on.
class _AcceptSplitButton extends StatefulWidget {
  final String alwaysLabel;
  /// Optional binary / argument fingerprint shown inline in the
  /// "Always" menu item so the user can see the exact scope being
  /// granted (e.g. `npm` for a `run_cmd` row). Empty string → menu
  /// item shows just `alwaysLabel` (tool-level grant).
  final String alwaysFingerprint;
  final VoidCallback onAcceptOnce;
  final Future<void> Function() onAcceptAlways;

  const _AcceptSplitButton({
    required this.alwaysLabel,
    required this.alwaysFingerprint,
    required this.onAcceptOnce,
    required this.onAcceptAlways,
  });

  @override
  State<_AcceptSplitButton> createState() => _AcceptSplitButtonState();
}

class _AcceptSplitButtonState extends State<_AcceptSplitButton> {
  // Two hover bits so each half's hover bg is independent — the
  // user wants to see which half their cursor is over BEFORE they
  // click (chevron-half opens a menu, label-half commits the
  // accept; conflating their hover state would make the chevron
  // half feel like dead space).
  bool _hoverLabel = false;
  bool _hoverChevron = false;

  // Bound to the chevron's container — `showFastMenu` needs an
  // anchor `RelativeRect` and we want the menu to drop directly
  // under the chevron, not at the cursor position.
  final GlobalKey _chevronKey = GlobalKey();

  Future<void> _showMenu() async {
    final ctx = _chevronKey.currentContext;
    if (ctx == null) return;
    final RenderBox button = ctx.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    // Position the menu so its top-left aligns with the chevron's
    // bottom-left. RelativeRect.fromRect's "rect" is the area the
    // menu should AVOID — collapsing both points to the chevron's
    // bottom edge gives a clean drop-down anchored beneath it.
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        button.localToGlobal(
          button.size.bottomLeft(Offset.zero),
          ancestor: overlay,
        ),
        button.localToGlobal(
          button.size.bottomRight(Offset.zero),
          ancestor: overlay,
        ),
      ),
      Offset.zero & overlay.size,
    );
    final fp = widget.alwaysFingerprint;
    final picked = await showFastMenu<String>(
      context: context,
      position: position,
      items: [
        PopupMenuItem<String>(
          value: 'once',
          child: Text(
            S.toolApprovalAllowOnce,
            style: const TextStyle(
              fontSize: 12.5,
              color: DuckColors.fgPrimary,
            ),
          ),
        ),
        PopupMenuItem<String>(
          value: 'always',
          // Single-row layout — the menu item height is fixed at
          // 30px by `_compactItems`, so a stacked two-line label
          // would clip. Render the verb in cyan-bold and the
          // fingerprint right after it in mono-dim, both on one
          // line: "Always run  npm". The user reads scope at a
          // glance ("I'm trusting `npm`, not all of run_cmd")
          // without needing a second visual row.
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                widget.alwaysLabel,
                style: const TextStyle(
                  fontSize: 12.5,
                  color: DuckColors.accentCyan,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (fp.isNotEmpty) ...[
                const SizedBox(width: 6),
                Text(
                  fp,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontFamily: DuckTheme.monoFont,
                    color: DuckColors.fgSubtle,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
    if (!mounted) return;
    if (picked == 'once') {
      widget.onAcceptOnce();
    } else if (picked == 'always') {
      await widget.onAcceptAlways();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: DuckColors.accentCyan.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(DuckTheme.radiusS),
        border: Border.all(
          color: DuckColors.accentCyan.withValues(alpha: 0.35),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Label half — accept once.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoverLabel = true),
            onExit: (_) => setState(() => _hoverLabel = false),
            child: GestureDetector(
              onTap: widget.onAcceptOnce,
              behavior: HitTestBehavior.opaque,
              child: Container(
                decoration: BoxDecoration(
                  color: _hoverLabel
                      ? DuckColors.accentCyan.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(DuckTheme.radiusS),
                    bottomLeft: Radius.circular(DuckTheme.radiusS),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  S.toolApprovalAccept,
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: DuckColors.accentCyan,
                    letterSpacing: 0.2,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
          // 0.5px vertical hairline divides the two halves so the
          // affordance is clear.
          Container(
            width: 0.5,
            height: 18,
            color: DuckColors.accentCyan.withValues(alpha: 0.35),
          ),
          // Chevron half — opens the dropdown.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            onEnter: (_) => setState(() => _hoverChevron = true),
            onExit: (_) => setState(() => _hoverChevron = false),
            child: GestureDetector(
              key: _chevronKey,
              onTap: _showMenu,
              behavior: HitTestBehavior.opaque,
              child: Container(
                decoration: BoxDecoration(
                  color: _hoverChevron
                      ? DuckColors.accentCyan.withValues(alpha: 0.18)
                      : Colors.transparent,
                  borderRadius: const BorderRadius.only(
                    topRight: Radius.circular(DuckTheme.radiusS),
                    bottomRight: Radius.circular(DuckTheme.radiusS),
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 4,
                ),
                child: const Icon(
                  Icons.keyboard_arrow_down,
                  size: 14,
                  color: DuckColors.accentCyan,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
