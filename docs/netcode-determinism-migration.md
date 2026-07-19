# Netcode: deterministic puck — the shooter → Rocket-League family migration

Status: **design / scoping.** This is the ceiling-raising path: it moves the puck
from the netcode family the game is in today (shooter-style *claim + server
rewind*) into the family Rocket League is in (*deterministic predict + reconcile*).
Everything else in `netcode-forward-prediction-plan.md` polishes within the current
family; this doc changes the family. Read that doc first for the forward-prediction
work this builds on.

## The honest ambition (and its limit)

Earlier review framed the netcode as "excellent for the stack, not AAA." This is
the single change that actually contests that — but be precise about *which* axis
it moves:

- **It raises the puck-fidelity + netcode-architecture axis to the AAA tier.** The
  puck — the defining object, and the one the opening review called "the weakest
  client-side story" — stops being interpolated-in-the-past-with-hacks and becomes
  a real client-predicted, server-reconciled object like RL's ball.
- **It also fixes a live gameplay physics bug.** Rim-arounds (the puck sent hard
  around the curved end-boards — a core hockey play) are broken under Jolt today:
  jitter, wrong caroms, and the puck squeezing past the boundary in the rounded
  corners and *falling out of the arena* (the reason the `board_rescue_velocity`
  containment hack exists). An analytically-clamped puck **cannot leave a boundary
  it's clamped to**, so the migration retires that hack and makes rim-arounds correct
  by construction. This is a gameplay win independent of the netcode one — see the
  Phase-0 spec's rim-around track.
- **It does NOT, by itself, make the game AAA.** The other axes from that review are
  untouched: participant-host P2P (host advantage, no host migration, a host that
  can cheat), no delta compression, 120 Hz bandwidth. Those are stages 5–6 and a
  dedicated-server decision. Determinism is **necessary-but-not-sufficient**, and
  it's the highest-leverage *structural* upgrade available on this stack — partly
  because it also makes a dedicated server easier later (a deterministic sim is
  cleaner to run headless and to validate authoritatively). One axis, the biggest.

## The two families (why this is a family change, not a feature)

- **Rewind-based lag comp — where the game is today.** The client authors a *claim*
  ("I picked up," "I hit," "I poked"), and the host **rewinds its recorded world to
  reconstruct what the client saw** and arbitrates. Works *without* determinism —
  which is exactly why the game uses it. All of `LagCompRewind`, the pickup/poke/
  hit/stick-lift claim resolvers, the puck's interpolate-in-the-past + conditional
  lead + handoff-slew machinery, and the shooter-trajectory-prediction special case
  are consequences of being in this family for a non-deterministic puck.
- **Deterministic predict + reconcile — where Rocket League is.** Every client runs
  the *same deterministic sim* forward (own object + ball + others); the server runs
  it authoritatively; they **agree by construction**, and small divergences are
  smoothed. No server-rewind-to-validate, because there's no claim to validate — the
  shared sim already produced the same answer.

The stage-3/4 forward-prediction work makes the *render* RL-like (remotes and the
loose puck extrapolated toward present). But the *validation* is still shooter-style
(the host reconstructs the client's predicted render to judge a claim — see the
render == rewind coupling). This migration changes the validation model itself, for
the puck.

**Why we're stuck in the shooter family:** the puck is a Jolt `RigidBody3D`, and
Jolt is non-deterministic across machines and its collisions aren't reconstructable
client-side. So "both sides run the same sim and agree" is unavailable, and the game
falls back to claims + rewind. Remove the non-determinism and the RL family opens up.

## What the audit found: Jolt is a thin shell

A full sweep of `Scripts/` + `*.tscn` for physics-engine API (see the inventory that
produced this doc). The headline: **~90% of gameplay physics is already
engine-independent analytic code**, and most of the Jolt-dependent paths sit next to
analytic "backstops" that would simply become the primary path. Specifically:

**Already analytic (no Jolt) — the bulk of the game:** pickup / deflect / poke /
strip / body-block / body-check / contested draws (swept-segment distance tests in
`PuckInteractionRules` / `PuckCollisionRules` / `SkaterCollisionRules`), goal
detection (`GoalDetectionRules` swept plane test — Jolt Area3D sensor was
deliberately removed), board containment (`GameRules.clamp_to_rink_inner`), net
exclusion (`push_out_of_net`), skater-vs-skater (`Skater._resolve_player_collisions`),
mouse aim (analytic ray-plane at y=0, not a physics raycast). **Zero** physics
raycasts or shape queries anywhere. The **goalie is not a physics body** at all
(`Node3D`, kinematically posed).

**Load-bearing Jolt — the entire migration scope (the "A-list"):**
1. **Puck translation** — advancing `linear_velocity → position` at 120 Hz. Trivial
   (`pos += v·dt`). Every hand-authored interaction already just *writes*
   `linear_velocity`; Jolt only propagates it.
2. **Puck gravity / ballistic arc** — airborne loft shots and saucer passes
   (`vy -= g·dt`, land at ice height). The one genuinely non-trivial integration. No
   spin (angular velocity is locked/zeroed — nothing to reproduce there).
3. **Puck-vs-static restitution** — bounces off boards (`bounce 0.4`), goal pipes
   (`0.55`), net panels (`0.05`), goalie pads (`0.2`) / stick (`0.4`). The meatiest
   piece — but board *escapes* (`PuckCollisionRules.board_rescue_velocity`) and
   controlled saves (`GoalieSaveRules` deaden, applied in `_integrate_forces`) are
   **already analytic**; this is extending existing analytic reflection to be the
   primary path.
4. **CCD** for fast shots — a swept test, which you need anyway once collision is
   analytic.
5. **Skater `move_and_slide`** — whose *only* real Jolt collision is
   skater-vs-goalie-body (`StaticBody3D`) and the tutorial wall. Ice is a no-op under
   the Y-lock; skater-vs-skater / boards / net are already analytic.

Existing analytic backstops that become the primary path: `board_rescue_velocity`
(C1), the save deaden (C2), the grounded-puck Y-pin + height/speed clamps (C3), the
skater analytic containment/contact (C4). The migration is largely *promoting
backstops to front-line*, not writing from scratch.

## Target: an analytic swept-disc puck sim

Replace Jolt's puck with a deterministic swept-disc simulation on the ice plane
(plus a Y channel for loft):

- **Per tick:** integrate velocity (existing `ICE_FRICTION` / `PUCK_ICE_DECEL_M_S2`)
  + gravity when airborne (the existing loft solve, `ShotMechanics.loft_y`) → build
  the swept segment `prev → curr` → test against static geometry → reflect with the
  per-surface restitution → resolve. CCD falls out for free (the sim *is* swept).
- **Geometry, reusing what exists:**
  - Boards: `clamp_to_rink_inner` gives the boundary (rounded corners exact);
    `board_rescue_velocity` gives the reflection. Already written.
  - Loft / gravity: the shot loft solve already models the arc.
  - Save response: `GoalieSaveRules` already produces the deaden/steer/rebound.
  - New geometry to author: goal-pipe cylinders, net-panel planes, and — the hard one
    — the goalie's pad/glove/blocker/body **oriented boxes**, which *move* every frame
    as the goalie poses.

**The determinism bar is "reconcilable agreement," not bit-lockstep.** RL itself uses
floats and is not bit-deterministic across platforms — it relies on the sim agreeing
closely and *smoothing* the residual. We target the same: identical analytic ops in
the same order agree on-platform, and diverge only slightly cross-platform (simple
plane reflections, bounded), well within the existing SmoothDamp's correction budget.
We are **not** signing up for fixed-point or a lockstep rewrite. (This is also why
`sin`/`cos`/`sqrt` cross-libm differences — fatal to true lockstep — are fine here.)

## What it changes in the netcode

Once the loose puck is a deterministic sim both sides run:

- **Client-side puck prediction becomes real.** Every client runs the swept-disc sim
  forward from the last authoritative state and reconciles — exactly the
  predict-and-reconcile the *local skater* already does, now for the puck. The puck
  renders at present on every client natively.
- **A large amount of puck-specific netcode machinery goes away.** The
  interpolate-in-the-past + `extrapolation_lead_fraction` + `_blade_lead_scale` gate
  + handoff-slew + shooter-only-trajectory-prediction special-casing all exist to
  paper over "the client can't simulate the puck." When it can, they collapse into
  one predict+reconcile path. The stage-4 conditional puck lead is a *stepping stone
  that this replaces*, not a permanent fixture.
- **The loose puck leaves the claim/rewind family; discrete possession stays in it.**
  Puck *position* becomes deterministic-agreed, so render == rewind for the puck is
  trivial. But *possession* events — pickup grants, contested draws, strips — are
  still discrete authority decisions and stay host-arbitrated (this is where hockey
  differs from RL: RL has no "carry"). Clean split: the loose puck is the RL-ball
  analog (deterministic); the carry/pickup layer is unchanged.

## The hard parts (in order of risk)

1. **Puck *feel* re-tuning — the real cost, not code volume.** The puck's bounce feel
   *is* the game, and today it comes from Jolt's restitution solver. Analytic bounces
   must *match that feel*, not merely be correct. This is a tuning project. **Mitigation:**
   the shadow-prototype phase below A/Bs analytic-vs-Jolt trajectories *before* any
   switch, and restitution/friction are tuned to match, not guessed.
2. **The goalie is moving geometry.** Puck-vs-boards is disc-vs-static (easy).
   Puck-vs-goalie is disc-vs-*moving oriented boxes* (pads/glove reposition per frame).
   The trickiest new collision. But the *response* is already analytic (`GoalieSaveRules`);
   only the contact *detection geometry* is new. **Mitigation:** do it last, after the
   static-geometry feel is proven.
3. **Regression blast radius.** The puck is the core object; the migration touches
   everything that reads it. **Mitigation:** phased, with Jolt kept as a live
   shadow/comparison during development, and heavy playtesting at each gate.

## Phased plan (each phase playtested; no big-bang)

- **Phase 0 — shadow prototype (cheap, de-risks everything). ✅ COMPLETE — GO.** Ran
  the analytic sim (`AITrajectory.step_puck`, already extracted) alongside Jolt via
  `PuckShadowComparator` and measured divergence over a live board/rim session. Result:
  free-flight exact (0.000 m), carom-angle error 0.2–0.3° over ~2000 bounces, worst
  bounce error ~15 cm (a non-accumulating sub-tick timing phase), and Jolt lost the
  puck 3× on rim-arounds where the analytic model can't. The board/rim feel matches and
  the rim bug is fixed. Full result in `netcode-phase0-shadow-puck-spec.md`. **Gravity/
  loft and the goalie remain untested — Phase 2 is the real risk.**
- **Phase 1 — switch loose-puck integration + board bounces to analytic** (host and
  client), Jolt still present for comparison. A/B feel. This is the feel-matching gate.
- **Phase 2 — add pipes + net + goalie-part collision** (the moving-geometry work).
- **Phase 3 — client-side puck prediction + reconcile** (the RL-family payoff): every
  client predicts the loose puck; remove interpolate/lead/handoff-slew for it.
- **Phase 4 — simplify.** Delete the now-dead Jolt puck config and the puck-specific
  netcode special-cases. The puck's netcode is now the skater's: predict + reconcile.

## Recommendation

- **Do the pragmatic stages 3/4 first** (already on the branch) for near-term playtest
  wins — they're independent and reversible, and they teach us how forward-prediction
  feels before the bigger bet.
- **Then run Phase 0.** It's the highest-information, lowest-cost step: a shadow sim +
  a trajectory-divergence log tells you whether the AAA-tier puck is reachable on this
  geometry *before* committing to the migration. The whole "is this worth it" question
  resolves in Phase 0.
- Everything past Phase 0 is gated on the feel matching. If it does, this is the change
  that earns the "this could be AAA" claim for the puck. If it doesn't, you've spent a
  prototype, not a rewrite, and the pragmatic lead stands.

## What still separates this from AAA (so the claim stays honest)

Even with a deterministic, RL-family puck, the AAA gap the opening review named is
only *partly* closed. Still open, and independent of this doc:
- **Dedicated servers** (participant-host means host advantage, no host migration, a
  cheatable authority). Determinism *helps* here but doesn't deliver it.
- **Delta compression + rate** (stage 5) — bandwidth is still 120 Hz full-state.
- **Anti-cheat** beyond the claim clamps — a deterministic client sim is, if anything,
  *easier* to cheat locally (the client knows the whole sim), so authority + validation
  discipline matters more, not less.

Determinism buys the puck-fidelity and netcode-architecture tier. The rest of AAA is
the dedicated-server decision. Both together are the real thing; this is the half that
raises the ceiling.
