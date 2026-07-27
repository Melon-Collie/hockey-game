# Netcode: forward-prediction target architecture & plan

Status: **design agreed, staged implementation in progress.** This doc is the
agreed design (per CLAUDE.md workflow — treat it as the plan; ask before
deviating). It captures the target the netcode is moving toward and the order
we get there. Deep invariants for the *current* system live in
`Scripts/networking/CLAUDE.md`; this doc is where we're going and
why, not a re-description of what's shipped.

## The problem we're solving

The current stack is a well-executed authoritative-host model: the local player
is predicted + reconciled; every other entity (remote skaters, loose puck,
goalie) is interpolated **a full `interp_delay` in the past** (`render ==
rewind`, lead 0). That past-rendering is the dominant *feel* cost:

- Remote **skaters** read less threatening than they are — you under-read
  closing speed, and get poke-checked by a stick that, on your screen, hasn't
  arrived yet.
- The **loose puck** trails the skaters, so a pass looks like it lags the play.
- The **goalie** shows a gap that the present-time goalie has already closed.

The gold standard is Rocket League / Valorant, **not** rollback (this isn't a
deterministic-lockstep game — Jolt physics on the puck rules that out; see
"Why not rollback"). The goal: pull every entity toward *present* to kill the
past-rendering, **without** breaking lag-comp claim validation (`render ==
rewind`) and **without** reintroducing ghost saves.

## The governing principle

> **Predict motion. Never re-derive a decision.**

You can safely forward-predict anything whose near future is a *continuous
function of momentum you can see*: a skater body (inertia), a sliding puck
(velocity + friction), a goalie's lateral push. You must **not** locally
re-derive anything whose future is a *decision*: the puck's Jolt bounces, or the
goalie AI's save selection. A decision re-run on a client with slightly
different inputs doesn't drift — it *flips*, and near a shot that flip is a
ghost save / phantom goal. Decisions stay host-authoritative; only motion is
extrapolated.

This line is the spine of the whole plan. Every per-entity choice below is an
application of it.

## Why not rollback

Full-world rollback (GGPO lineage) needs (a) every player's inputs on every
machine and (b) a bit-deterministic simulation. We have neither, and (b) is
fatal: the puck is a Jolt `RigidBody3D` whose state can't be losslessly
snapshotted/restored or reproduced cross-machine. The skater *body* is
hand-integrated GDScript (deterministic, cheap to run forward) — which is
exactly why the plan can forward-integrate skaters but not roll back the puck.
A client can only reconcile entities whose *inputs* it has; a client has only
its own. So: predict-self + extrapolate-others-forward + lag-comp claims is the
ceiling for this stack, and it's the Rocket League / Valorant family.

## Target architecture, per entity

### Local skater — unchanged
Predict + reconcile against the host ack. Already correct.

### Remote skaters — input-broadcast + client forward-integration
- Put each skater's **input/intent** (movement vector, sprint, brake, aim) on
  the wire alongside (or more often than) full state.
- Clients **forward-integrate** every remote skater from the last authoritative
  snapshot using the *same* hand-integrator, rendering them at/near present
  instead of a full `interp_delay` behind. Safe because skater movement is
  momentum-based (inertial — can't stop/cut instantly), so extrapolation is
  accurate.
- **Preserve `render ≈ rewind`:** the host holds every player's inputs, so it
  runs the *same* forward-integration to reconstruct what the client rendered
  and rewinds claims (pickup/poke/hit) to the **predicted** instant, not the
  raw-past instant. Bit-perfect determinism is *not* required (`sin`/`cos` in
  facing isn't identical cross-libm) — host and client land close, and the
  authoritative correction snaps out the residual. A few cm of mismatch at
  present beats 80 ms of honest past.
- **Residual (accept):** the blade **poke thrust** is the one non-inertial
  skater motion — it extrapolates imperfectly. Body closing reads true (most of
  the bad feeling gone); the thrust itself can still surprise by a frame or two.
  This is the irreducible core, and it's why body checks go server-driven
  (below) rather than staying client-predicted.

This is more than "predict one step" — it's "clients run a shared skater sim
between keyframes." Scope it that way; the one-step version leaves most of the
past-ness on the table and still breaks the claim invariant.

### Loose puck — conditional forward lead
Only the **loose + interpolating** mode trails today. The others are already
present-ish: carried-puck rides the (now forward-predicted) carrier's blade
automatically via `get_carry_target_global`; the shooter's puck is
trajectory-predicted. So this is a narrow surface.

- **Lead the loose puck** to the shared present instant (dead-reckon by velocity
  + `ICE_FRICTION`) **only in the clean regime** — no board/blade/goalie/net in
  the projected path.
- **Drop the lead (trail, `render == rewind`)** the moment a bounce/contest is
  imminent. This **extends the existing board-aware `_crosses_board` gate** from
  "boards" to "any imminent contact." Reasons it must drop:
  1. The host can't cheaply reconstruct the puck's led instant — its near future
     is Jolt collisions the client doesn't predict (unlike the deterministic
     skater body). So `render == rewind` for the puck only holds when the path
     is clear.
  2. The puck is fast — a wrong lead is a multi-metre snap. Clean-lane slides are
     the safe case; near-body is exactly the contested-pickup case where
     trailing is *correct*.
- **Gate the optimistic pickup pin off while leading** — reuse the existing
  handoff-slew pin suppression (`try_provisional_pickup` already gates off when
  the puck renders ahead of rewind). Pin allowed while trailing (contest regime,
  render == rewind holds), suppressed while leading (clean regime — nobody's
  contesting there anyway).

### Goalie — host-only AI, render-lead only, **never** local AI
The goalie AI stays **host-only** (see `ARCHITECTURE.md` invariant — client AI
caused ghost saves/phantom goals). This is not up for re-litigation; the
rationale is the governing principle:

- The goalie's save selection is a **decision** at a discrete threshold
  (drop/don't, glove/blocker, RVH/VH), evaluated at the moment of a close shot —
  max input uncertainty (fast puck near a body, the one place forward-prediction
  is *least* accurate) — producing the max-stakes output (save vs goal). Running
  it locally doesn't remove latency; it *converts* tolerable timing latency into
  intolerable **disagreement** with the authority.
- The AI is **not a function of the puck alone**: it reads screen state (other
  skaters), the pre-armed windup read (observation history), caught-moving/unset
  (its own prior decisions), backdoor/one-timer threats, and multi-second
  commit/reaction timers. Fixing the puck read fixes one input of many; the
  others can't be reproduced client-side. "On-net = deterministic" is also false
  — tips/deflections/screens change an on-net puck's line (Jolt + `deflect_velocity`),
  and those are the highest-value goalie moments.
- **What we do instead:** optionally **pose-lead the goalie's render** off the
  broadcast velocity (dead-reckon position forward through motion it's already
  committed to — no local decisions) **for spectators** (coherence with led
  skaters/puck, no fairness cost). For the **shooter, keep the goalie at the
  rewind instant** — the shot is already lag-comp-judged against the goalie the
  shooter saw, so leading it would make them aim at a hole the host won't
  evaluate against. The goalie being slightly behind on the shooter's screen is
  *correct*, not a bug.
- **Residual (accept):** pose-leading through a butterfly **drop** mistimes the
  pose by a frame or two (a drop is a sudden host-commanded change, not inertia)
  — a bounded wobble, **never** a phantom goal.

## Bandwidth

Order matters — the levers interact, and the naive order makes things worse.

1. **Forward-integration first (above).** It decouples render-time from snapshot
   rate: clients simulate between keyframes off inputs instead of interpolating
   between snapshots. This is what makes the rate drop *free on the feel axis*.
2. **Then drop the broadcast rate** (120 → 60-64 Hz). Linear ~2× saving, trivial
   (the dead `set_broadcast_rate()` knob is waiting). **On its own** a rate drop
   *worsens* past-ness (bigger `broadcast_interval` term in `interp_delay`) — so
   it must come *after* forward-integration, not before. 60-64, not 30 (30 adds
   ~25 ms of interp delay).
3. **Then delta-encode positions against a velocity baseline**, when egress is
   metered (i.e. dedicated). Note the correction to intuition: "hockey is always
   moving so deltas don't help" conflates two things. *Dirty-flagging* (send only
   changed fields) — yes, constant motion defeats it. *Delta-encoding* the
   **residual** against a velocity-predicted baseline — smooth, fast, inertial
   motion compresses *well* (sub-cm per-tick residual → ~4-6 bits/axis vs ~16-24
   absolute). Real 2-3× on top of quantization, but complex (per-client baseline
   ACK tracking + keyframe recovery on loss). Medium-term, egress-driven.

## Dedicated server (hybrid, for release)

- **What it fixes:** host advantage (everyone symmetric), the **host-cheat
  surface** (host claims currently skip every clamp/rewind — the single biggest
  integrity win, makes ranked meaningful), **identity** (validate the Steam auth
  session ticket instead of the client-sent `steam_id`), and host-loss (server
  outlives any player).
- **What it does NOT fix:** client-authored claim cheating (P0/P1 below still
  apply — the server still eats client-sent claim stamps and blades), the
  client-side prediction gaps, or reconcile cost. A dedicated server is not an
  anti-cheat checkbox.
- **The new bill:** your 120 Hz full-state broadcast becomes *your* egress +
  compute — which is exactly what justifies the rate-drop + delta-encode work.
- **Cheap to adopt here:** the transport is already a drop-in `MultiplayerPeer`;
  the offline/host session already runs the full sim (`is_offline_mode` gates
  only broadcast/ping/upload); the spectator path already proves
  host-without-local-skater. The seam to build is a "pure server" mode (peer 1,
  zero local skaters, no camera/HUD/input, broadcast on, auth-ticket gate) +
  match lifecycle. Consider dropping the Steam relay for direct UDP to a known
  server IP.
- **Recommendation:** **hybrid** — route ranked/matchmade to dedicated, keep
  casual/free-play/friends on P2P host. Ranked gets integrity; casual keeps
  costing nothing and survives a lapsed server budget.

## 5v5 (untested at scale)

Size the whole plan against **headless 5v5 with 10 bots** before pricing a
server instance — the two costs scale differently:
- **Bandwidth scales with human count** (bots are host-simulated, no
  connection). Worst case = 10 humans: ~1.5× packet size × up to ~1.7×
  downstream streams ≈ 4-5 Mbit/s egress/match at 120 Hz uncompressed. Makes the
  rate-drop + delta-encode **non-optional**, not nice-to-have.
- **Compute scales with bot count** (10 skater AIs + 5v5 zone-coverage — the
  worst-tick spike already flirts with the 8.3 ms budget at 6 AI). A bot-heavy
  5v5 is cheap on bandwidth, expensive on CPU. Benchmark it — that number
  decides matches-per-core.

## Sequenced plan (ROI order)

Each architecture stage (2+) needs local playtesting between stages — the game
can't run headless, so networking feel is verified on the developer's machine.

1. **Independent bug/anti-cheat batch** (free, headlessly testable, no
   architecture dependency — do first):
   - **P0** — claim-stamp plausibility trusts a client-self-reported ping and
     goes *unbounded* when none is reported. Two parts, both landed: (a)
     **host-measure per-peer RTT** — `report_ping` (client self-report) replaced
     by a host-initiated `host_ping`/`host_pong` round trip the host times +
     EMA-smooths into `_peer_ping_ms`, which `get_peer_ping_ms` backs;
     `PROTOCOL_VERSION` 34→35. Wire-touching — needs a live-session / net-sim
     check that measured RTT tracks the link. (b) **no-sample bound** —
     `LagCompRewind.is_claim_stamp_plausible` no longer returns `true` when
     `peer_rtt_ms <= 0`; a conservative default RTT bounds the age instead.
   - **P1** — blade reach clamp bounds *distance* but not *plausibility*
     (`lag_comp_rewind.gd:89`); add a blade-history continuity check so a
     modified client can't synthesize an always-max-reach, always-catch blade.
   - **`shot_charge` save/restore** across reconcile replay — mutated in replay
     (`skater_controller.gd` `_update_slapper_charge`) but not in the
     save/restore set (`local_controller.gd`); replicated + feeds the goalie
     read.
   - **`_sample_historical_others` allocation** — fresh `Array` + per-remote
     `Dictionary` per replayed tick (`game_manager.gd`), in the bad-network hot
     path CLAUDE.md forbids. Memoize/scratch-reuse.
2. **Body checks → server-driven.** Delete client-side check-collision
   prediction; play the hit from the host-authoritative `body_check_landed` +
   impulse injection. Nothing to mispredict → no snap. Cost: ~½-RTT before you
   feel a check you delivered (reads as weight, not lag).
3. **Remote skater input-broadcast + forward-integration** + host rewind to the
   predicted instant. *(Built on the experimental branch.)* The movement
   intent is already on the wire (v15/v16/v28, lossless for keyboard's 8-way
   input — no PROTOCOL bump). `SkaterMovementRules.integrate_forward` is the
   shared primitive; `RemoteController` (render) and **every carrier-anchored
   claim resolver** — hit, poke, stick-lift — reconstruct the identical
   prediction host-side via `LagCompRewind.forward_predict_skater`
   (same fraction/decay constants, intent quantized through the wire codec so
   raw bot intent matches what clients decoded, rewind snapshots carry the
   intent fields), so render == rewind holds at any lead. Gated by
   `Constants.REMOTE_FORWARD_PREDICT_FRACTION`, **set to 1.0 (full present) on
   this experimental branch** for the Steam playtest — dial toward 0.5 / 0.0 if
   remotes overshoot on hard cuts. The loose-puck pickup rewind needs no
   migration while the puck lead is parked (see stage 4).
4. **Conditional puck lead** *(built on the experimental branch)* +
   **goalie spectator pose-lead** *(deferred — see below)*.
   - *Puck lead:* **DELETED (Phase 4a).** The blade-eased conditional lead was
     built, parked at fraction 0 (its collapse regresses render time
     non-monotonically on fast incoming pucks), and then superseded outright by
     Phase-3 client puck prediction — the loose puck now renders at ~host
     present via the shared analytic sim, with claims validated at the stamp,
     which is strictly better than any eased lead. The machinery was removed
     rather than left dormant.
   - *Goalie pose-lead — DEFERRED.* Lower value (spectator-only cosmetic) and a
     real footgun: the shooter's shot is already lag-comp'd against the goalie
     they saw, so leading the goalie for the shooter would make them aim at a
     goalie the host won't judge against — worse, not better. A safe version has
     to suppress the lead whenever the local player is aiming/charging, which is
     fiddly state logic for a cosmetic gain. Revisit only if the skater+puck lead
     feels good and the goalie's past-ness still reads badly.
5. **Rate drop** (now free on feel) **+ delta-encode** (when egress-metered).
6. **Pure-server-mode + Steam auth ticket + hybrid dedicated for ranked.**

## What this does not fix (honest residuals)

- Blade-poke thrust extrapolates imperfectly (stage 3 residual).
- Goalie butterfly-drop pose timing (stage 4 residual, spectator-only).
- Puck-vs-goalie save is a spectator-visual mismatch (puck led, goalie at rewind
  for the shooter) — not a fairness issue.
- Reconcile cost is client-side and RTT-scaling regardless of any server work.
