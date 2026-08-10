# AI threading: move bot decisions off the physics thread

Status: **shipped — threading is the only path** (the single-threaded fallback
has been removed). Bot decisions run on a dedicated AI worker thread
(`AICoordinator`). The route there: centralize dispatch (2a) → freeze the brain
view (3a) → split decide/apply (3b) → introduce a **non-blocking** worker (3c) →
move the brain tick onto it as well (3d). The worker handles **skaters +
brains**; the **goalie stays on the main thread** (non-scaling 2 actors, runs in
parallel with the worker). Model A shipped (whole-dispatch, decisions applied a
frame or more late); Model B (live reception re-aim on the main thread) remains
the reserve lever if reception feel needs it. No host tick ever blocks on the
worker — a slow batch just makes bots coast on last frame's decision, so the
frame rate is decoupled from AI cost. (`await_idle()` on the despawn path is the
one blocking call, and it is not on a tick path.) Concurrency safety uses a mutex
on the "batch ready" flag, per-kick copies of the fields the host mutates in
place, and — for the brains — a deferred-write queue plus published read mirrors
(see *Concurrency notes* below; the earlier "no mutex" note is superseded). Perf
is validated in a real/Steam build, not the editor (debug + editor overhead masks
the sim win); watch F3 sim-tick under bot load.

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
[0]  Skater integration             InputStates for tick N
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
  and runs `_process_input` at physics priority −1 (before the skater integrates
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

## Two ordering facts the centralization must respect

The exact per-tick execution order (verified) constrains a behavior-identical
centralization:

- **Bots read the *previous* tick's snapshot; brains read the *current* tick's.**
  Bots dispatch in `AIController._physics_process` at priority **−1**, strictly
  before `GameManager` (autoload, priority 0) rebuilds `current_snapshot` at
  `game_manager.gd:517`. So a bot on tick N reads the snapshot object built on
  tick N−1. The brains tick *inside* `GameManager._physics_process` at `:526`,
  *after* the rebuild, so they see tick N. This one-tick perception asymmetry is
  current behavior. The faithful transform is trivial: in the coordinator,
  dispatch bots reading `current_snapshot` **before** the `:517` overwrite (it
  still holds last tick's build at that point), then rebuild, then tick brains.
  The apply (`_process_input`) still lands at priority-0-autoload, before the
  `Skater` scene node integrates at priority-0-tree-order — so decision→apply→
  integrate ordering is preserved (autoloads run before scene nodes at equal
  priority). Model A collapses this asymmetry uniformly in Phase 3; Phase 2 keeps
  it.

- **The goalie stays on the main thread (decided).** `GoalieController` reads
  **live actor state** (`puck.global_position`, live skater positions), not
  `current_snapshot`, and its decision runs pure `GoalieBehaviorRules` — it
  **never** calls `AIActionScoring`, so it shares none of the per-tick static
  scratch. The `set_goalie_profile` statics are set once at match config
  (`game_manager.gd:860, 4347`), read-only during play. So the goalie has **no
  data-race hazard** with the worker, and it runs on the main thread in parallel
  with the worker anyway — its cost is hidden behind the worker just as the
  worker's is hidden behind physics. Crucially it **does not scale**: always
  exactly 2 goalies, 3v3 or 5v5, so it is not the "more bots = worse" cost.
  Converting it would need three replicated-state additions
  (`PuckNetworkState.pickup_locked`, `SkaterNetworkState.predicted_shot_velocity`
  + `team_id`), ~100 live-read conversions, and a decision/mutation split (the
  poke / sweep / cover / `set_puck_*` are physics mutations that can't run on a
  worker regardless) — a large, feel-critical refactor for a non-scaling,
  already-overlapped cost. **Not worth it now.** The goalie code is also rough
  enough that a threading conversion should ride a broader goalie refactor, if
  one happens before ship. Revisit only if profiling the threaded build shows the
  goalie is a real main-thread cost. Thread-safety alongside the worker is by
  construction: the worker reads only its snapshot *copy* (plain
  `SkaterNetworkState`/`PuckNetworkState` data), never live nodes, so the
  main-thread goalie mutating live nodes can never collide with it.

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
to preserve: the decision→`_process_input`→integration order per skater, and
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

## The brain-state race (Phase 3's one real concurrency hazard)

During dispatch, the agent reads ~10 fields off the live `TeamBrain` in
`_build_role_context` (`skater_agent_state_machine.gd:2158-2236`): `get_slot`,
`strong_x`, `assigned_threat`, `threat_shoot_base_by_opp`,
`team_size`, `position_of`, the three ping targets, and `is_one_timer_ready`.
On the worker, those reads race against **main-thread** brain mutations:
`apply_ping` (RPC-driven, any time), `_force_retick_team_brains` (on carrier
flips, mid-sim), and `exclude/include_skater` (on spawn/despawn). Concurrent
read/write of a Dictionary/field across threads in GDScript is undefined
behavior — a rare heisenberg crash, unacceptable even if infrequent.

The fix is the world-snapshot principle applied to brain output: **freeze
everything the agent reads into plain data (a per-team/per-peer frozen view)
before the agents run.** The worker's agents read the frozen view, never the
live brain.

Phase 3a shipped that with the brains still ticking on main and `build_view`
running at kick time. **Phase 3d moved the brain tick onto the worker as well**
(tick → `build_view` → decide, all inside one batch), because the 6 Hz brain is
force-reticked on every carrier flip and its cost therefore clusters in scrums —
on the worst ticks, which are the ones that set host FPS. The frozen view is
unchanged; what changed is who may touch the live brain and when:

- Every host-raised mutation (`apply_ping`, `_force_retick_team_brains`,
  `exclude/include_skater`) is queued on `AICoordinator` and applied **by the
  main thread** in the idle window before the next kick. Nothing crosses the
  thread boundary; the cost is a deferral of at most a frame or two.
- The two live fields main still reads every frame outside that window — the
  ping-elected chaser (snapshot enrichment) and possession state / coverage
  downgrade (the F6 shape tally) — are published to plain mirrors at kick time.
  Both of their sources are mutated by the worker's tick (`ping_directives` is
  advanced and expired in place), so a live read there was the same hazard.
- `TeamBrain.tick` takes elapsed-since-last-kick, not the frame delta. Kicks are
  skipped while the worker is busy, and a brain seeing only kick frames would
  age its 6 Hz accumulator and its real-time ping expiry slow by exactly the
  frames it missed. The agents' `decide()` delta is summed the same way, for the
  same reason.

## Staged implementation

1. **Baseline** *(done)* — 5v5 benchmark table above captured as the before-table.
2. **Centralize skater dispatch** *(done — committed)* — bots dispatch from one
   host-driven loop in `GameManager._physics_process` via `tick_agent(snapshot,
   delta)`; `PlayerRegistry` caches the bot-controller list; brains then bots run
   against one unified enriched snapshot. Single-threaded, suite green, benchmark
   flat. Goalie stays self-driven on main (see above — final, not a deferral).
   **Needs a user playtest** to confirm bot feel before the live-threading step.
3. **Thread it (Model A), in three sub-steps** so only the last introduces true
   concurrency:
   - **3a — Freeze brain outputs** *(done — committed).* `TeamStrategyView` base
     implemented by the live `TeamBrain` and a frozen `TeamBrainView`;
     `brain.build_view(snapshot)` runs each host frame after the brain tick; the
     agent dispatch reads the view via a `_current_strategy` cache (falling back
     to the live brain when no view is built, i.e. single-threaded unit tests).
     Suite green (+ a focused mirror test), benchmark flat; the duel harness
     builds views so the behavioral AI tests exercise the frozen path. One
     intended shift: cross-agent one-timer readiness is now seen one frame late.
   - **3b — Split decide from apply** *(done — committed).* `tick_agent` now
     orchestrates `begin_tick(delta) -> bool` (main: guards + special modes,
     stamps rule set + host time), `decide(snapshot, delta)` (worker-safe: agent
     against the frozen snapshot + view, no autoloads/nodes), and
     `apply_decision(delta)` (main: `_process_input` + shot state + debug). Called
     back-to-back on main here; suite green. One residual live-brain write inside
     the agent (`set_one_timer_ready`) is left for 3c's collection step.
   - **3c — Introduce the worker** *(done — committed, flag default off).*
     `AICoordinator` owns a persistent `Thread` + two `Semaphore`s.
     `GameManager` hands it the bot list + frozen snapshot each frame; it kicks
     the worker to `decide()` this frame's normal bots and applies last frame's
     decisions (the 1-tick delay buys full overlap with physics). One-timer
     readiness moved off `_set_one_timer_ready` into a main-thread
     `push_one_timer_ready()` collection so `decide()` writes no shared state.
     Worker starts lazily, joined on world teardown + app-exit. No
     double-buffer (results read only after the ready flag, before the next
     kick). Shipped behind a flag that has since been removed — threading is
     now the only path.
   - **3d — Move the brain tick onto the worker too** *(done — committed).*
     `brain.tick` + `build_view` run at the head of each batch instead of on
     main, taking the force-retick spikes off the physics thread. Host-raised
     brain writes are queued and drained on main in the idle window; the two
     fields main still reads live are published to mirrors at kick. Batch delta
     is elapsed-since-last-kick so nothing downstream ages slow when a kick is
     skipped. `await_idle()` added for the despawn path — the one place main
     blocks on the worker, because a controller cannot be freed while `decide()`
     is executing on it. See **The brain-state race** above. Suite green; the
     threaded path can't be exercised headlessly, so it needs an in-game
     playtest watching F3.
4. **Validate & decide** — if reception aim lag is felt, escalate the reception
   re-aim to Model B.

### Concurrency notes (as shipped)

The worker is non-blocking, so main and worker can touch bot/brain state in
overlapping frames. Safety comes from confining every worker read to state that
is stable for the whole batch, and every main write to when the worker is idle:

- **Non-blocking harvest.** A `Mutex` guards a `_result_ready` flag the worker
  sets on completion; main checks it without blocking. If the batch isn't ready,
  main reuses last frame's decision and skips the next kick — a slow worker never
  stalls the host tick. (This supersedes the original blocking `_done.wait()` and
  the "no mutex needed" claim.)
- **InputState:** the worker writes each bot's `_pending_input` during its batch;
  main reads it only in `apply_decision`, which runs only while the worker is idle
  (harvested, before the next kick). No overlap, so no second buffer.
- **Agent stamps are set at kick (worker idle).** Rule set / host time move out
  of the per-frame `begin_tick` into `prep_for_decide`, so nothing the worker
  reads is rewritten mid-batch. A main-only `_stale_pending` flag (not a
  `_pending_input` write) handles the special-mode → normal transition.
- **Live brains belong to the worker.** It ticks them and builds their views
  inside the batch. Main's writes are queued and drained in the idle window
  before the next kick; main's two remaining per-frame reads go through mirrors
  published at kick.
- **Despawn is the one blocking point.** `_worker_bots` holds controller
  references for the length of a batch, and `PlayerRegistry.remove` queue_frees
  the controller — a free that can land mid-batch. No after-the-fact check makes
  that safe, so the despawn paths call `await_idle()` first. Despawns are events,
  not ticks, and the wait is bounded by one batch (and by a give-up timeout, so a
  worker that died inside `decide()` can't hang the game).
- **Snapshot:** fields the host rebuilds fresh each frame (skater_states, the
  teammate caches) are shared by reference; fields it mutates IN PLACE every frame
  (the accel-tracker dicts shared onto the snapshot, the reused carrier-debounce
  puck) are copied into reused per-worker buffers at kick — the worker never reads
  them mid-mutation.
- The `AIActionScoring` static registers stay safe by construction — the single
  sequential worker preserves the one-at-a-time execution order.

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
