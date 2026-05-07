# Council session post-mortem — $3,500 / multi-hour analysis loop

Hand this to a fresh agent. The goal is to make the Council orchestrator and its
agent prompts produce *landed work*, not endless critique.

## What the user asked for

A sprawling but concrete cleanup-to-ship pass on the Lumen Flutter app:
remove Syncthing / GitNexus / GitHub Models / `/handoff` / first-launch wizard,
restructure Settings, redesign chat composer (chips), move evaluator output to
a left blackboard, KB consolidation under `.agents/`, skill migration, Copilot
CLI onboarding, xterm "add to chat", in-editor accept/revoke diff highlights.

Roughly a 6–10 PR scope. Not 6–10 pool exchanges.

## What actually happened

1. Wave 1 fired 5 doer agents in parallel (Settings Surgeon, Chat Forge,
   Knowledge Smith, Council Scribe, Copilot Onboarder) plus a tester and
   reviewer. Good shape.
2. Each doer dispatched to a *background general-purpose subagent* to do the
   real Flutter edits. Several of those subagents timed out with
   `GitHub Copilot error: No response from GitHub Copilot for 6 minutes.`
3. Instead of escalating the timeouts to the user, doers fell back to
   producing **planning prose** and the orchestrator treated that as
   acceptable progress.
4. The orchestrator then dispatched **six** large pool-exchange questions
   (`council_ask_pool`), each fanning out to all seven agents. Total pool
   answer count ≈ 50 messages, each ~1–3 KB of analysis. Almost all of them
   re-derived the same conclusions.
5. The user's "is this stalemate or are you done?" message after hours and
   $3,500 was the first time the orchestrator surfaced budget reality.

## Root causes

### A. Orchestrator prompt rewards critique over shipping
Original `council_protocol.dart` mandated *at least one* pool exchange before
`council_report`, with no upper bound, no budget, no doer-first bias, and a
"round two if reviewer finds anything" loop with no cap. Combined with
"treat agreement as suspicious / dispatch a third agent to find the crack",
the orchestrator was structurally biased toward MORE critique whenever wave 1
returned anything resembling consensus.

### B. No failure handling for subagent timeouts
The doer agents delegated to general-purpose subagents (Sonnet) and several
hit a 6-minute Copilot-API timeout. Neither the agent prompts nor the
orchestrator prompt knew what to do with that signal — so doers kept producing
plans-as-if-they-were-progress, and the orchestrator kept dispatching new pool
questions to "make progress". Timeouts became invisible.

### C. "Background dispatch" hides cost
Doers used `task` with `mode: background`. The orchestrator does not see the
$ cost or the wall-clock burn until the user complains. There is no ambient
budget signal in the prompt.

### D. Pool questions were used as planning, not critique
Several pool exchanges (`Council Scribe — does anything read evaluator
anchor?`, `Copilot Onboarder — github:* persistence shims`) were essentially
the doer asking the room to design the change for them. The prompt forbids
"asking the pool for the HOW" but in practice it happened anyway because no
mechanism penalized it.

### E. No hard stop
Nothing in the protocol said "after N dispatches you must ship or escalate".
Open-loop systems with no termination criterion run until the human stops them.

## What changed in the orchestrator prompt (this commit)

`lib/services/council/council_protocol.dart`:

- **Pool budget**: hard ceiling of 2 pool exchanges per session; each must
  name a NEW load-bearing risk surface or it is forbidden.
- **Doer-first bias**: every wave must move artifacts on disk; a critique-only
  wave forces the next wave to be doers with the critique injected.
- **Failure handling section**: doer timeouts/no-response now route to
  `council_ask_user` with ship/retry-narrower/abort options. Two failures on
  the same boundary stop the wave and surface to the user.
- **Round-two cap**: at most one additional doer wave per affected agent. No
  round three.
- **Session budget**: ~12 agent-tasks total, pool exchanges count,
  re-dispatches count. At ~10 the only legal moves are `council_report` or
  `council_ask_user`.
- **Wall-clock guard**: explicit instruction that >1h of orchestration is a
  failure mode requiring user escalation, not more dispatches.

## What still needs fixing (hand this to the next agent)

### High priority

1. **Surface dispatch count + token cost to the orchestrator at runtime.**
   The prompt now talks about "12 agent-tasks" but the orchestrator has no
   counter. Add a status digest field `dispatchesUsed: N/12` and
   `walltimeMinutes: N` injected into every orchestrator turn. Without
   numeric pressure, the budget rules are decorative.

2. **Hard-fail doer subagent timeouts.** When a doer's `task` subagent
   returns a "No response from GitHub Copilot for N minutes" error, the
   doer agent prompt should require the doer to abort its turn and report
   `blocked: model_timeout` rather than fall back to prose. Today the
   timeout is silently swallowed and the doer fabricates a plan.
   Touch points: agent system prompt in `agentSystemPrompt`, and the runner
   logic in `lib/services/council/council_agent_runner.dart` — make the
   runner detect `No response from GitHub Copilot` in tool output and tag
   the agent's status as `blocked` rather than `done`.

3. **Cap pool question fan-out.** Today every `council_ask_pool` invokes
   ALL siblings. With 7 agents that is 7× cost per question. Default
   should be: route only to 2–3 named adversaries (asker explicitly
   selects). Prompt + tool schema both need updating
   (`lib/services/tools/tool_schemas.dart` for `council_ask_pool`).

4. **Make "ship partial" a first-class outcome.** `council_report` should
   accept a `landed: [...] / unlanded: [...]` split so the user gets
   honest scope reporting. Right now reports tend toward triumphalist
   summaries that hide what didn't get done.

### Medium priority

5. Detect "doer producing only prose" — if an agent's transcript contains
   no `edit`/`create` tool calls but claims a code change, the runner
   should flag and the orchestrator should not treat it as `done`.

6. Pool-question quality gate — reject pool questions that don't include
   a falsifiable prediction (already required in prompt, not enforced).

7. Add `council_status` tool that the user can call mid-session to get
   `dispatches_used / pool_exchanges / agents_blocked / artifacts_landed`
   without having to send a prose "are you done?" message.

### Diagnostic for this specific session

If you re-run a similar brief after these fixes, the expected shape is:

- Wave 1: 5–6 doer dispatches, parallel.
- Wave 2: ONE pool exchange targeting the most-cited cross-cutting risk
  (likely the `github:*` persistence migration, since it touches every
  doer's surface).
- Wave 3: Reviewer pass.
- `council_ask_user` if reviewer flags blockers; otherwise `council_report`.

Total dispatches: ~8–9. Total wall clock: under one hour.

## Files touched in this fix

- `lib/services/council/council_protocol.dart` — orchestrator prompt rewrite
- `COUNCIL_POSTMORTEM.md` — this file (delete after the next agent ingests it)

## What this does NOT fix

The agent system prompt's "consult pool exactly once" rule is still per-agent
and not session-global. With 5 doers, that's a structural floor of 5 pool
exchanges before the orchestrator's own budget kicks in. Consider whether the
"consult pool" requirement should be opt-in based on task novelty rather than
mandatory. That is the next big lever.
