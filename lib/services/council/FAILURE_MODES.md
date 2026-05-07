# Council Failure Modes

Tracking record of every "looked like it worked, didn't actually" failure
mode the council orchestrator has exhibited, and the specific guard that
now prevents silent recurrence. **If you find a new way for the council
to silently no-op, add it here AND add a test in
`test/council/`.**

---

## FM-001 — Phantom plan: orchestrator produced a plan but no agents executed

**Symptom (user-visible):** "you planned but nothing happened." Council
window opens, orchestrator streams a tidy plan, evaluator runs, a report
is written to disk. Zero agent transcripts. User sees a "Council Report"
that synthesises nothing because nothing was synthesised.

**Root cause:** `CouncilAgentRunner` exits its iteration loop in two
ways:
1. The model emits a `council_dispatch` / `council_report` tool call.
2. The model emits prose only, the tool executor finds no tool calls,
   and the runner returns the final prose as `CouncilRunResult.content`.

Path 2 is legal for terminal "I am done thinking" turns, but the
orchestrator has no enforcement that **at least one** dispatch happened
before that exit. `_runOrchestrator` then calls `_finishWithReport(result.content)`,
which previously had no guard, wrote a report, and the run "succeeded".

**Fix landed:**
- `CouncilTaskLedger` (lib/services/council/council_task_ledger.dart) is
  the single source of truth for every dispatched task. Explicit state
  machine: `planned → dispatched → running → done|failed|timeout|cancelled`.
- `_dispatch` records every dispatch into the ledger. `_runAgent` drives
  transitions to `running` / `done`. The catchError path drives `failed`
  and increments `errorCount`.
- `_finishWithReport` calls `ledger.refusalReasonForReport()` first. If
  zero tasks reached `done`, the report is REFUSED, the session goes to
  `CouncilStatus.error`, and a `dispatch_guard_tripped` event fires
  (mirrored as `agent_error` on the orchestrator for legacy panels).
- The `council_report` tool itself is gated the same way, so an
  orchestrator that tries to fast-path to `report` after only producing
  prose gets a BLOCKED tool result feeding back into its message stream
  ("you MUST invoke council_dispatch on at least one agent...").

**Regression test:** `test/council/council_task_ledger_test.dart`
`refusalReasonForReport` returns the phantom-plan refusal when the
ledger has never recorded a dispatch. Pre-fix: nothing checked this.

---

## FM-002 — Dispatched but every agent failed

**Symptom:** Agents start, every one errors out (model unavailable, tool
exec exception). Previously the orchestrator could still call
`council_report` and ship a "no findings" report.

**Fix landed:** `refusalReasonForReport()` requires at least one task in
state `done`, not merely "any dispatch attempted". A run where every
dispatch failed is loud now: `dispatchGuardTripped` event with
`failureCount > 0`, `successCount == 0`. Orchestrator must escalate via
`council_ask_user` (per protocol) or abort.

---

## FM-003 — Race: report shipped while a parallel dispatch was still running

**Symptom:** Orchestrator dispatches three agents in parallel, agent A
finishes, orchestrator races into `council_report` before B and C land.
Report omits B/C work.

**Fix landed:** `refusalReasonForReport()` also refuses while
`pendingCount > 0`. The orchestrator's `_finishWithReport` already
awaits `_dispatches` before generating the evaluator pass; this guard
catches the case where a future-list bookkeeping bug lets a task slip
the await.

---

## FM-004 — Silent retry storm

**Symptom:** A failing agent is re-dispatched indefinitely.

**Fix landed:** `CouncilTaskLedger` enforces `maxAttempts` (default 2)
per task. A third dispatch on the same task throws
`LedgerTransitionError` with reason `retry cap exceeded`, which
`_safeLedgerTransition` surfaces as a `dispatch_guard_tripped`. Loud,
not silent.

---

## FM-005 — Crash mid-run loses pending tasks

**Symptom:** Process exits while two agents are mid-run; on reload, the
session shows `working` forever with no way to resume.

**Fix landed:** Ledger snapshot is persisted into `CouncilSession.tasks`
on every transition. A reload rehydrates the ledger with the last known
state of every task, so the UI can display "running" tasks as
`timeout` / `cancelled` after a startup sweep (controller can call
`ledger.cancelAll(reason: 'process restart')` if it detects stale
running rows from a previous PID — left as a follow-up; the data is
there, the policy is not yet wired).

---

## Event schema (single source of truth)

The structured event the UI subscribes to is documented in
`lib/services/council/council_task_ledger.dart` (header comment, "Event
schema" section). Type is `CouncilEventType.taskStateChanged`. Signal
binds to that — do NOT invent new event types at the call-site, add
them to `CouncilEventType` first.
