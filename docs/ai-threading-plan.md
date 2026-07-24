# AI threading: move bot decisions off the physics thread

Status: **design proposed, awaiting sign-off.** Per CLAUDE.md workflow this is
the design under review — not yet agreed, not yet implemented. Once signed off it
becomes the plan of record and implementation follows the staged order below.

## The problem

The bot AI is the host's dominant CPU cost, and it scales with bot count — more
bots in a lobby, worse host FPS. The AI perf benchmark
(`benchmarks/test_ai_perf_benchmark.gd`) quantifies it against the **8333 µs**
per-tick budget at 120 Hz (perfect-bot / ~60 Hz dispatch tier — the worst case;
difficulty only lowers it):

| Scenario | Size | AI p95/tick | AI max/tick | % of budget (p95 / max) |
|---|---|---|---|---|
| ozone-cycle | 5v5 | 3906 µs | **10146 µs** | 47% / **122%** |
| nz-rush | 5v5 | 3628 µs | 9904 µs | 44% / 119% |
| loose-neutral | 5v5 | 3287 µs | 8481 µs | 39% / 102% |
| ozone-cycle | 3v3 | 2299 µs | 4549 µs | 28% / 55% |

The headline: in 5v5, on the worst ticks, **AI alone exceeds the entire frame
budget** — before physics for 10 skaters + 2 goalies + puck runs at all. Those
spikes set the host FPS floor ("host FPS is set by the worst tick"), and because
the broadcast cadence is counted in physics ticks (`network_manager.gd`
`_state_tick_divisor`), a dilated host tick sags *every client's* update rate.

Prior AI-perf work (#507 carrier time-slice, #530 allocation churn, the dispatch
LOD / cadence staggering) has attacked this single-threaded — spreading and
shrinking the per-tick cost. Those wins stand and this plan builds on them; but
the ceiling of the single-threaded approach is the physics thread itself. This
plan removes the AI from the physics-critical path entirely.

## The key insight: the AI does not belong on a 120 Hz tick

Bot decisions are already throttled to **6–60 Hz** (TeamBrain ~6 Hz, per-bot full
dispatch ~30–60 Hz, far-play LOD halving it again). A fresh decision is needed
every 2–20 physics ticks, not every tick. So the decision layer has no business
competing with physics inside an 8333 µs window — it just happens to run there
today because dispatch is called inline from each actor's `_physics_process`.

Move the whole decision layer onto **one dedicated worker thread** that runs
concurrently with physics and hands decisions back **one tick later**. The main
thread keeps doing physics; the worker's cost hides behind the physics step. A
10 ms AI burst spread across ~2 physics ticks is invisible on a bot that
re-decides at 6–60 Hz anyway.

Two properties make this safe rather than heroic, and both are already
established in the codebase:

1. **Bounded staleness is pre-approved.** #507 split the carrier compete across
   two dispatches, accepting one-dispatch-late fire scores as "well inside the
   ~135 ms windup the fired-puck lanes price across." A worker returning
   decisions one tick (8.3 ms) late is the same philosophy, an order of magnitude
   tighter.

2. **The decision layer is engine-free.** A sweep of `Scripts/domain/ai/**`
   (and the state-machine layer) for `get_node`, `get_world_3d`, `space_state`,
   `PhysicsDirectSpaceState`, `intersect_ray`, `Engine.`, `.global_position`
   returns **zero matches**. All perception is analytic geometry (reach-vs-flight
   models), not physics-space queries. There is nothing physics-bound tethering
   the AI to the main thread — which is normally the thing that kills game-AI
   threading. The engine-touching work (`_process_input`, blade IK, body
   integration) lives *downstream* of the decision, at the `InputState` boundary,
   and stays on the main thread.

## Why one worker, not per-bot fan-out

The obvious "parallelize across bots with `WorkerThreadPool`" is the **wrong**
design here, for a concrete reason: **sequential-per-bot execution is
load-bearing.** These all exist *because* bot dispatch runs one-at-a-time today:

- `RoleContext` — one reused context per agent, refilled not reallocated
  ("dispatch is sequential per bot, so a single buffer persists").
- The single reused `RoleDecision` instance (#530).
- Shared frozen `EMPTY_VEC3` / `EMPTY_CAPS` read-only arrays (#530).
- The `AIActionScoring` static scratch registers — `feed_keeper_pos` /
  `feed_keeper_unsettled` / `feed_keeper_hands` (`action_scoring.gd:1932`),
  `_scratch_counter_cover` (`:2983`), the `set_goalie_profile` statics (`:477`).
  These are write-on-this-call / read-on-next-call output registers shared across
  agents *and* the TeamBrains' threat memo.

Per-bot fan-out would data-race every one of these and force a broad refactor of
the hottest, most feel-critical code in the game. **A single worker running the
whole dispatch sequentially preserves the exact execution order** — all of that
scratch stays valid, untouched, bit-identical. We move *where* the AI runs, not
*how*. That is the entire safety argument, and it's why this is tractable.

If one worker ever proves insufficient (AI > the available overlap window even
spread across ticks), per-bot fan-out is the escalation — but it pays the
static-scratch refactor then, not now.

## Architecture

Three phases per host tick, two threads:

```
main thread, tick N            worker thread
────────────────────           ─────────────
[−1] collect worker result
     (InputStates from N−1)
     apply via _process_input   ── running: dispatch all bots+goalies
     → SkaterController          ── against snapshot N−1, producing
[0]  Skater.move_and_slide          InputStates for tick N
[+1] puck analytic step
[+2] capture + broadcast
 └─  build+enrich snapshot N,
     post to worker, signal go  ──► wakes, computes N, signals done
```

- **Prep (main):** build the shared `WorldSnapshot` and enrich it (accel tracker,
  carrier reaction-delay debounce) exactly as today (`game_manager.gd:517-525`).
  This is already cheap — it's the *dispatch* that's expensive, not the snapshot.
- **Decide (worker):** run both `TeamBrain.tick`s, every bot's
  `SkaterAgentStateMachine.dispatch`, and both goalie decisions, sequentially,
  against the handed-off snapshot. Output: a result table `{peer_id: InputState}`
  + goalie decisions.
- **Apply (main):** each controller reads its `InputState` from the result table
  and runs `_process_input` at physics priority −1 (before `Skater.move_and_slide`
  at 0), identical to today — just fed a pre-computed input instead of computing
  inline.

### Model choice: whole-dispatch (A), not split (B)

- **Model A (recommended):** the *entire* `dispatch()` runs on the worker,
  including the cheap per-tick blade re-aim. Everything is uniformly one tick
  stale. Simplest; preserves sequential semantics wholesale; the throttle
  architecture already tolerates one-tick input reuse (that's what a skipped
  dispatch tick does). The one feel risk: the per-tick reception blade re-aim
  (`skater_agent_state_machine.gd:1807-1826`, which re-derives the blade target
  from *live* perception every tick so a slow catchable feed doesn't transit an
  idle blade) now reads a one-tick-old snapshot — ≤0.25 m of aim lag on a 30 m/s
  puck, less for slower feeds. Likely imperceptible; validated by playtest.

- **Model B (fallback):** split `dispatch()` — the throttled full-dispatch
  decision (state handlers, the argmax) goes to the worker; the cheap per-tick
  re-aim + press-state convergence stay live on the main thread. Keeps blade aim
  and wrister-charge timing tick-fresh, but requires surgically marshaling the
  "decision result" (cached move vector, cached aim target, role decision, state)
  across the boundary — far more invasive and more failure surface.

Start with A behind a flag. If playtest shows the aim lag hurts reception feel,
escalate the reception re-aim (only) to Model B — keep it live on main reading
the present snapshot, leave the decision on the worker.

## The prerequisite: centralize dispatch (no threading yet)

Today the AI is **not** one loop — it's distributed across each
`AIController._physics_process` (`ai_controller.gd:138`), each
`GoalieController._physics_process`, and the brain loop in
`GameManager._physics_process` (`:526`). You cannot lift a distributed set of
node callbacks onto a thread. So **Phase 1 centralizes** the dispatch into one
host-driven `AICoordinator.tick_all()` that iterates brains → skater agents →
goalies in a defined order, still single-threaded, still on the main thread,
behavior **bit-identical**.

This is valuable independent of threading (it's the clean seam #519's god-class
decomposition wants anyway) and it de-risks the hard part: land the
reorganization first, prove the benchmark and full suite are unchanged, *then*
flip the loop onto a worker as an isolated change. The ordering/timing constraint
to preserve: the decision→`_process_input`→`move_and_slide` order per skater, and
the snapshot-age the agents currently read.

## Threading mechanics (Godot)

- **Persistent worker**, not spawn-per-tick — `Thread.new()` is expensive.
  Started when a match with bots begins, `wait_to_finish()`'d and freed on
  match end / scene teardown / return to menu. A dangling `Thread` at scene free
  is a hard Godot error, so lifecycle is a first-class concern, not an
  afterthought.
- **Handoff:** two `Semaphore`s (main→worker "go", worker→main "done") around a
  double-buffered snapshot-in / results-out. The worker sleeps on "go" when idle.
- **Double-buffer both directions:** the worker reads snapshot buffer A while
  main builds buffer B for next tick; the worker writes result buffer A while main
  applies result buffer B. Ping-pong, so main and worker never touch the same
  buffer. Snapshot objects are already built fresh per tick — this just means a
  second live buffer, no new per-tick allocation in steady state (respecting
  #530).
- **Worker touches zero Node/engine APIs.** Enforced by construction (it runs
  only `dispatch`/`tick`/goalie-decision, all verified engine-free) and guarded
  by an assert/review checklist. Any Node access from the worker is a bug, not a
  tuning question.

## Correctness & safety

- **Spike fallback:** if the worker hasn't finished by the time main needs the
  result (a >8.3 ms burst, or a scheduling hitch), main reuses last tick's
  `InputState` for that skater and does **not** block. Reusing an input for one
  extra tick is exactly what a throttled dispatch already does — free, invisible,
  and it keeps the broadcast cadence from sagging (the failure mode the PR survey
  flagged: a stalled worker must never stall the host tick).
- **AI-off phases:** during goal replay (`is_replay_mode`), faceoff prep,
  celebration, and non-host, the coordinator parks the worker (no "go" signal) —
  the existing per-controller gates (`ai_controller.gd:141,149,154,180`) move into
  the coordinator so the worker is only ever fed live-PLAYING snapshots.
- **Determinism:** unchanged. Bots are host-authoritative and **not** on the
  reconcile replay path (clients predict movement from replicated `InputState`,
  never re-run AI). Sequential worker execution reproduces today's decision order
  exactly, so the static scratch registers stay correct. No cross-peer
  reproducibility is required for AI.
- **The one shared-state hazard to audit:** `_apply_bot_carrier_reaction_delay`
  already copies `puck_state` into `_ai_puck_scratch` to avoid corrupting the
  authoritative ring (`game_manager.gd:4620`). Confirm the snapshot handed to the
  worker is likewise a scratch the main thread won't mutate mid-run (it is, if
  built into the idle double-buffer before the "go" signal).

## What this does *not* touch

- #518 (6 Hz TeamBrain re-partition) — deferred, ~30× smaller than the tick
  paths; the brain runs on the worker now regardless, so its cost is hidden.
- The scoring internals, `RoleContext`, `RoleDecision` reuse, the static
  registers — all preserved by the single-worker sequential design. No refactor.
- Client-side prediction / reconcile / lag-comp — AI is upstream of all of it.

## Staged implementation

1. **Baseline** *(done)* — benchmark numbers above captured as the before-table.
2. **Centralize dispatch** — `AICoordinator.tick_all()`, single-threaded,
   behavior-identical. Gate: full GUT suite green, AI benchmark table unchanged
   (decision cost is only relocated), user playtest confirms feel is identical.
3. **Thread it (Model A)** — persistent worker, double-buffered handoff, spike
   fallback, lifecycle teardown. Flag-gated (`ai_threaded`, default off) so it's
   A/B-toggleable. Gate: suite green; **host-frame telemetry** (below) shows the
   main-thread win; playtest confirms no feel regression, especially reception.
4. **Validate & decide** — if reception aim lag is felt, escalate the reception
   re-aim to Model B. Tune, then flip the flag on by default.

## Validation

Two instruments, because they measure different things:

- **AI perf benchmark** (`-gdir=res://benchmarks`) — measures raw decision cost
  in isolation via the duel harness. Threading *relocates* this cost, doesn't
  shrink it, so the AI-µs table should be ~unchanged. Its job here is a
  regression guard on the centralization refactor (Phase 2).
- **Host-frame health telemetry** — the real proof. `game_manager.gd:481-484`
  already records per-tick wall-clock gap (F3 "Sim rate" mean / "Worst stall"
  max). Under a 5v5 all-hard-bot load, threaded vs not: the main-thread tick gap
  should stop dilating and the worst-stall max should collapse toward the
  physics-only cost. That delta *is* the win, and the benchmark can't show it
  (the duel harness has no real physics thread to hide behind).

## Open questions for sign-off

1. **Model A one-tick uniform staleness** acceptable as the starting point, with
   Model B held in reserve for reception only? (Recommended: yes.)
2. **Worker scope** — skaters + goalies + brains all on the one worker
   (recommended, keeps the static registers single-threaded), vs. leaving goalies
   on main (would reintroduce a static-register sharing hazard).
3. **Flag default** during the beta — ship Phase 3 off-by-default behind
   `ai_threaded` for opt-in testing, flip after a playtest window?
