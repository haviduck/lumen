# Convene the Council — Acceptance Gauntlet

**Run order:** automated tests first (`flutter test test/widgets/council/`), then walk the manual checklist below. Total wall-time target: ≤ 10 min.

**Baseline before doer changes (record date of run):**
- `flutter analyze`: 12 issues, 1 in `lib/widgets/council/` (`library_private_types_in_public_api` at `council_speech_bubbles.dart:132`).
- `flutter test test/council/council_task_ledger_test.dart`: 9/9 pass.
- Speech bubble background today: `DuckColors.bgDeepest.withValues(alpha: 0.30)` (translucent — must become opaque).
- Council files containing `Colors.green` / `Colors.lightGreen`: **0 today**. (If grep finds any after the overhaul, FAIL.)

A regression in any of the above without a stated reason = doers broke the floor.

---

## Automated gates (must be green)

```
flutter analyze
flutter test test/council/
flutter test test/widgets/council/
```

Pass criteria:
- `flutter analyze` reports **≤ 12 issues** AND **0 new issues in `lib/widgets/council/`** beyond the baseline `library_private_types_in_public_api` (or that one is also gone — bonus).
- All council tests pass.
- The two new widget tests in `test/widgets/council/` pass:
  - `council_no_green_test.dart` — fails if any green color literal lands in council source.
  - `council_speech_bubble_opacity_test.dart` — fails if the bubble background is translucent.

---

## Manual checklist

Tester walks each row, marks PASS / FAIL / N/A, attaches a screenshot or short clip on FAIL.

### R1 — Modal feels premium (objective proxies, ≥ 4 of 5 must pass)

| # | Proxy | Pass criterion (measurable) |
|---|---|---|
| 1.1 | Spacing rhythm | All vertical gaps inside the modal are multiples of a single base unit (4 or 8 px). Inspect with Flutter Inspector ruler. **No** raw values like 7, 13, 22. |
| 1.2 | Type scale ratio | At most 4 distinct font sizes in the modal. Adjacent sizes have a ratio in `[1.125, 1.414]` (modular scale). No size used only once except the title. |
| 1.3 | Motion timing presence | Open/close uses a curve that is **not** `Curves.linear` and a duration **between 180–420 ms**. Verify by reading the `AnimatedFoo`/`Tween` in source (grep `duration:` inside `council_wizard_dialog.dart`) and by eye — no instant snap, no sluggish drag. |
| 1.4 | Depth/shadow layers | Modal surface has **≥ 2** distinct elevations visible (e.g. backdrop scrim + card shadow + inner pressed states). Default `Dialog` widget with stock `elevation: 24` only = FAIL. |
| 1.5 | No default Material chrome | No visible `Material` ripple splashes on bespoke buttons; no default `AppBar`; no stock `Switch`/`Checkbox` shapes. Inspector tree shows custom widgets (e.g. `_PremiumButton`, custom `InkResponse` with overridden `splashColor`). |

### R2 — Per-agent model quick actions

| # | Action | Steps | Pass criterion |
|---|---|---|---|
| 2.1 | Preset apply | Open Convene → click a preset (e.g. "Cheap & fast"). | Every visible agent row updates to the preset's model within one frame. No flicker. |
| 2.2 | Bulk apply | Select 3+ agents, choose "Apply to selected". | Only selected rows change. Unselected rows untouched (verify by noting their model before/after). |
| 2.3 | Keyboard shortcut | With the model picker focused, press the documented shortcut (e.g. `Cmd/Ctrl+1..9`). | Correct preset applies. Shortcut overlay or tooltip lists the binding. |
| 2.4 | Override visual state | After preset applied, manually change ONE agent's model. | That agent's row gets a distinct visual marker (e.g. dot, ring, "overridden" chip). Markers persist until the user clicks "reset to preset". Must be distinguishable in greyscale (don't rely on color alone). |
| 2.5 | Persistence | Close & re-open Convene without restarting app. | Last-applied selections (preset + overrides) are restored. |

### R3 — Network lines: pulses correlated to real talk events

Definition of **correlated**: a pulse origin-to-target visibly starts within **300 ms** of the dispatch tool call timestamp logged by the controller, AND a return pulse starts within 300 ms of the responder's first stream chunk. Idle (no run in progress) ⇒ **no** pulses on the line — only the ambient mesh.

| # | Step | Pass criterion |
|---|---|---|
| 3.1 | Open Convene with no run active. Watch network for 10 s. | Mesh shimmer OK; **no** directional pulses between agent nodes. |
| 3.2 | Trigger a run with 2+ agents. Open dev console / log overlay. | For each `council_dispatch` event, a pulse appears on the matching origin→target edge within 300 ms. Count in log == count of pulses (off-by-one allowed for last-frame race). |
| 3.3 | Same run, observe responses. | Reverse-direction pulse fires within 300 ms of first response chunk per agent. |
| 3.4 | Cancel the run mid-flight. | In-flight pulses fade out within 1 s; no new pulses begin. |

### R4 — Agent panel bottom panel animation tied to real state

| # | Step | Pass criterion |
|---|---|---|
| 4.1 | Agent in `idle` | Bottom panel animation is calm/static OR a low-frequency ambient (≤ 1 Hz). |
| 4.2 | Agent transitions to `thinking` | Animation visibly changes within 1 frame of state change (different shape, frequency, or color energy). |
| 4.3 | Agent transitions to `streaming` | Distinct third state, visibly different from both idle and thinking. |
| 4.4 | Scroll the panel offscreen | Animation **pauses** (verify via DevTools timeline: no paint work for that subtree, OR `Visibility` / `TickerMode` short-circuits the controller). |
| 4.5 | Scroll back on | Animation resumes within 1 frame; no jump to "frame 0" — phase preserved or smooth re-entry. |

### R5 — Speech bubbles: dark, opaque, WCAG AA

| # | Check | Pass criterion |
|---|---|---|
| 5.1 | Background opacity | Eye-dropper or Inspector: background color alpha == `0xFF` (255). Automated gate: `council_speech_bubble_opacity_test.dart` passes. |
| 5.2 | Background luminance | Background is dark (relative luminance < 0.2). |
| 5.3 | WCAG AA contrast | Body text vs background contrast ratio **≥ 4.5:1**; small/secondary text ≥ 3:1 only if it is decorative. Use a contrast checker on a screenshot. |
| 5.4 | No bleed-through | Place a bubble over a bright area of the canvas — content behind must NOT influence the bubble's perceived color. |

### R6 — Bubbles never overlap agent panels (HARD invariant)

Stress cases — both must pass:

| # | Scenario | Steps | Pass criterion |
|---|---|---|---|
| 6.1 | Small viewport | Resize window to ~900×600. Trigger a run with all agents speaking. | No bubble's bounding rect intersects any agent panel's bounding rect at any frame. Min visible gap ≥ 4 px. Verify with screen-record + frame stepping if needed. |
| 6.2 | Many simultaneous bubbles | Force ≥ 5 agents to speak at once (use a fan-out prompt). | Same invariant. Bubbles reflow / stack / re-anchor, but never cover a panel. |
| 6.3 | Drag panel during speech | While a bubble is animating in, drag its origin panel. | Bubble re-anchors to panel; never overlaps it during the drag. |
| 6.4 | Window resize during speech | Drag the OS window edge during an active run. | No overlap at any intermediate size. |

If a violation is observed, capture: window size, agent count, frame screenshot, console log slice.

### R7 — Dark blue, not green

| # | Check | Pass criterion |
|---|---|---|
| 7.1 | Visual sweep | Open Convene, theater, agent inspector, speech bubbles. **No green accents** anywhere on the council surface. Status colors (success/error) explicitly excluded ONLY if they live outside the council widgets. |
| 7.2 | Source grep | `grep -nE 'Colors\.(green\|lightGreen)\|0xFF[0-9A-F]{0,2}[8-F][0-9A-F]{0,2}[0-9A-F]{2}' lib/widgets/council/` — manually inspect any hit. Automated gate: `council_no_green_test.dart` passes. |
| 7.3 | Panel base color | Agent panel background is in the dark-blue family (hue ~210–240°). Eye-dropper a panel; `H` should be in that range. |

---

## Severity

- **Blocker:** any FAIL in R5.1, R6.*, R7.1, or any automated gate.
- **Major:** any FAIL in R2.*, R3.*, R4.4 (offscreen pause).
- **Polish:** R1.* (premium proxies). At most one may FAIL for sign-off.
