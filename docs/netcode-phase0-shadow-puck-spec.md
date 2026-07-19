# Phase 0 spec: shadow-puck divergence harness (determinism go/no-go)

Status: **spec, ready to build.** Phase 0 of the deterministic-puck migration
(`netcode-determinism-migration.md`). This is the cheap, high-information step that
gates the whole project: it answers *can an analytic puck sim match Jolt's feel?*
with **measured data**, before a single line of gameplay changes.

## The question Phase 0 answers

For a client to predict-and-reconcile the puck (the RL-family model), the analytic
sim it runs must track the host's authoritative Jolt puck **within the SmoothDamp
correction budget** — i.e. close enough that reconciliation is a gentle blend, not a
snap. Phase 0 produces the number: *how far does the analytic sim drift from Jolt
over a real shot, and specifically at a board bounce?*

- **Go:** divergence stays small (see thresholds) and bounces match angle closely →
  the AAA-tier client-predicted puck is reachable → proceed to Phase 1.
- **No-go:** bounces diverge in a way tuning can't close (Jolt is doing something the
  analytic reflect can't capture) → stop, having spent a harness, not a rewrite. The
  pragmatic stage-4 lead stands.

## Rim-arounds: match where Jolt is good, BEAT where Jolt is bad

Board caroms off the straight walls are the "match Jolt" case (Jolt is fine there).
**Rim-arounds — the puck sent hard around the curved end-boards behind the net, a
core hockey play — are the opposite: Jolt is BROKEN there.** With the current
trimesh geometry the puck jitters, takes wrong caroms, and can squeeze its center
past the boundary in the rounded corners and **fall out of the arena** — which is the
whole reason the `board_rescue_velocity` / containment-teleport hack (C1) exists.

So for rim-arounds the success criterion **inverts**: we are not trying to reproduce
Jolt, we are trying to be *correct where Jolt isn't*. And the analytic model is very
likely the fix, not merely an equal:
- `GameRules.clamp_to_rink_inner` does exact **rounded-rectangle** projection, so the
  curved corners are real geometry, not a trimesh approximation.
- `AITrajectory` reflects about the **inward normal at the contact point** — its own
  doc-comment notes the old axis-aligned-rectangle reflection produced "phantom corner
  ice and caroms off walls that aren't there," which the corner-aware version already
  fixed for the AI.
- A puck analytically clamped to the boundary **cannot leave it** — the escape-and-
  rescue failure mode is structurally impossible, so the C1 backstop retires (it
  becomes the primary, correct path).

This means Phase 0 has TWO deliverables, not one:
1. **Straight caroms** — measured *against Jolt* (match it; go/no-go thresholds below).
2. **Rim-arounds** — measured *on their own merits* (containment + a smooth,
   hockey-plausible curved path), NOT against Jolt, because Jolt's rim-around is the
   bug we're replacing. Comparing to Jolt here is meaningless — Jolt + the C1 hack IS
   the thing that "absolutely sucks."

If the analytic rim-around is smooth and contained (very likely, given the AI already
rides it), that's a strong *independent* reason to migrate even if straight caroms
were merely a wash — determinism fixes a live physics bug, not just the netcode.

## The key finding: the sim already exists

`Scripts/domain/ai/trajectory.gd` (`AITrajectory`) already forward-simulates the
puck analytically and is **already relied upon to match Jolt** — the AI uses it for
pass-lead, chase intercepts, pass-in-flight reception, and rebound prediction. Its
`_step` (single source of truth, pure, value-type, no alloc) does exactly the Phase-0
physics:
- **Coulomb ice friction** — `decel = GameRules.PUCK_ICE_DECEL_M_S2`, velocity
  decelerated opposite its direction, clamped at 0 (`trajectory.gd:113-126`).
- **Board reflection at the rounded-corner contact** — `bounce = GameRules.PUCK_BOARD_BOUNCE`
  (0.4, matching `Physics/boards.tres`), reflecting the outward velocity component
  about the inward normal from `clamp_to_rink_inner` (`trajectory.gd:100-111`).

Its own doc-comment: *"Applies Coulomb ice friction and board reflection so the
projected trajectory matches Jolt's actual resolution of a freely sliding puck."*
The AI plays well on top of it, so it's already approximately right — Phase 0 turns
that implicit assumption into a **measured** one, over real shots, at bounce
resolution, to confirm it's tight enough for a *predicted* (not just AI-estimated)
puck.

**Consequence:** Phase 0 is mostly *harness + measurement*, not sim-building. The
sim is `AITrajectory.predict_puck` / `_step`.

## Scope (deliberately narrow)

**In:** the freely-sliding, grounded loose puck — translation + friction + **board**
bounces, including **rim-arounds** (hard puck around the curved end-boards). Straight
caroms are the puck-feel signature (measured vs Jolt); rim-arounds are the case Jolt
gets *wrong* (measured on their own merits — see above). Both ride the same
`AITrajectory` path, so both are testable in Phase 0.

**Out (measured in later phases, each its own prototype):**
- **Gravity / airborne loft** — `AITrajectory` is XZ-only; loft shots/saucer passes
  aren't modeled. Add a Y channel (`vy -= GRAVITY_M_S2·dt`, land at
  `PUCK_AIRBORNE_HEIGHT_M`, reuse `ShotMechanics.loft_y`) in a Phase-2 prototype.
- **Goalie / net / pipe collision** — not in `AITrajectory`. The goalie is *moving
  geometry* (the hard part); Phase 2. Net panels + goal pipes are static and simpler.
- **Carried puck / pickup** — unchanged; possession stays host-arbitrated.

Keeping Phase 0 to boards+friction is the point: it tests the highest-value,
already-written path cheaply, and the go/no-go on the *whole* migration rides mostly
on the board-carom result.

## Harness design: `PuckShadowComparator`

A host-only, dev-gated `RefCounted` that runs a shadow puck alongside the real one
and logs divergence. **Never drives the real puck** — pure measurement.

```
class_name PuckShadowComparator  # Scripts/game/ (dev tooling, like network_sim)
# Host-only. Gated behind a dev flag (mirror NetworkSimManager's enable pattern);
# compiled out of cost on release by an early return when disabled.

var _shadow_pos: Vector3
var _shadow_vel: Vector3
var _mode: int            # FREE_RUN or PER_TICK_STEP
var _free_run_elapsed: float
# accounting
var _div_sum: float; var _div_n: int; var _div_max: float
var _post_bounce_div_max: float   # divergence in the N ticks after a board contact
```

Two comparison modes (run both across a session; they answer different questions):

1. **`PER_TICK_STEP`** — each tick, seed the shadow from Jolt's *current* authoritative
   state, step it ONE tick via `AITrajectory` `_step`, compare to Jolt's *next* state.
   Isolates **per-interaction modeling error** — tells you *which* thing diverges
   (friction rate? bounce angle?) without accumulation masking it.
2. **`FREE_RUN`** — seed the shadow once (at a shot/pass release, or on a periodic
   re-seed when the puck goes loose), then free-run it via `AITrajectory` and compare
   to Jolt every tick until the puck is caught/whistled/re-seeded. Measures
   **accumulated drift over a whole flight** — the number that actually decides
   whether a predicted puck reconciles gently. This is the headline metric.

Wiring (host, per physics tick, after Jolt integrates the puck): call
`comparator.tick(real_pos, real_vel, airborne, board_contact_this_tick, dt)` from the
puck's host tick (`Puck._physics_process` / `_integrate_forces` seam, host-only). A
`board_contact_this_tick` flag (already detectable — the puck's `body_entered`
classifies board hits, `puck.gd:_on_body_entered`) lets the comparator bucket
post-bounce divergence separately.

Re-seed policy for FREE_RUN: seed on loose-puck entry (release/strip/drop) and on a
hard re-seed if divergence exceeds a large cap (so one bad bounce doesn't poison the
rest of the session's stats). Log each seed→resolve as one "flight" record.

## Metrics & log sink

Per tick (when enabled): `|shadow_pos − jolt_pos|`, `|shadow_vel − jolt_vel|`,
tagged `free_flight` vs `post_bounce` (first ~6 ticks after a board contact — the
window where a wrong reflection angle shows up).

Aggregates per flight and per session:
- **Free-flight drift** — max/avg positional divergence during straight slides
  (should be tiny; friction-rate mismatch shows here).
- **Post-bounce divergence max** — the headline. A wrong carom angle diverges fast;
  this is the go/no-go driver.
- **Bounce-angle error** — at each board contact, the angle between the shadow's
  post-bounce velocity and Jolt's. The most feel-relevant single number.

Sinks (dev-only):
- **CSV to `user://puck_shadow/`** (rolling, like the net-session mirror): one row per
  tick or per flight, for offline analysis. Primary deliverable.
- **Live F-overlay** (optional): current + session-max divergence, so the dev sees it
  spike on a bad bounce in real time.
- **Ghost puck** (optional, highest feel-value): a translucent `MeshInstance3D` at
  `_shadow_pos` so the dev *sees* both pucks after a carom. The scene node is the
  user's to add (per the .tscn-editing rule); the harness just writes its transform.

## Go/no-go thresholds (calibrate against the SmoothDamp budget)

The reconcile smoother (`PuckController` `position_smooth_time = 0.06`,
`_SMOOTH_SNAP_DIST = 2.0`) defines "gentle correction." Provisional gates (tune once
real data lands):
- **Free-flight drift < ~5 cm** over a full slide → friction model is fine (expected;
  `AITrajectory` already nails constant-decel).
- **Post-bounce max divergence < ~0.25 m** and **bounce-angle error < ~5°**, settling
  back toward free-flight drift within the post-bounce window → matchable by tuning
  `PUCK_BOARD_BOUNCE` / the reflection; **GO**.
- **Post-bounce divergence in the metre range or bounce-angle error > ~15°**, not
  closing with restitution tuning → Jolt is resolving the carom with something the
  analytic reflect can't reproduce (contact manifold, sub-tick timing) → **NO-GO** for
  a naive swept-disc; escalate (swept sub-stepping, or accept the pragmatic lead).

**Rim-around track (measured on its own merits, NOT vs Jolt):**
- **Containment** — over a session of hard rim-arounds, the analytic puck NEVER leaves
  the boundary (the `board_rescue_velocity` escape/teleport never has to fire). Binary
  and decisive: if it's contained by construction, the live "falls out of the arena"
  bug is fixed.
- **Curve quality** — the puck follows a smooth, continuous path along the rounded
  corner (no jitter, no stall, no phantom wall-hit), and exits at a hockey-plausible
  angle. Judged visually against the ghost puck + a trace log of the corner segment.
- A **GO on containment + curve here is an independent reason to migrate**, even if
  straight caroms were only a wash vs Jolt — it retires the C1 hack and fixes a real
  gameplay bug.

## Effort & sequence

Small — the sim exists (`AITrajectory`), so this is: the comparator class (~a
day), the host-tick wiring + board-contact flag (already detected), the CSV sink,
and a session of shooting pucks at boards to collect data. Optional ghost/overlay add
polish. No gameplay risk (measurement only, dev-gated, host-only).

Sequence: **playtest stages 3/4 first** (independent, reversible), **then run
Phase 0** — collect a session of board caroms, read the divergence report, make the
go/no-go call. The whole "is the AAA puck worth it" question resolves in that report.

## Deliverable

A short divergence report from a real shooting session: free-flight drift, post-bounce
max divergence, bounce-angle error distribution, and the GO/NO-GO call against the
thresholds above — plus, if GO, which parameter (`PUCK_BOARD_BOUNCE`, friction) needs
what nudge to tighten the match for Phase 1.
