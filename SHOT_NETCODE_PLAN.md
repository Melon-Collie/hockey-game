# Server-Authoritative Shooting — Implementation Plan

Status: **proposal, for review.** No code written yet.

## Goal

Make shooting **fully server-authoritative** with **no felt lag and no "weird bounces."**
The shot the client releases must be byte-for-byte the shot the host fires — not
because the client *sends* it, but because both machines **derive the same shot
from the same inputs**. The host never trusts a client-supplied direction/power.

## Why it bounces today (root cause)

The client already predicts the shot locally and fires a predicted puck
immediately. The bounce is the predicted puck getting yanked onto the host's
*different* authoritative trajectory. So the entire problem is:
**the client's predicted shot diverges from the host's, on a discrete event that
can't be smoothed away.**

There are five divergence sources. The first is the amplifier; the rest are the
sources of the disagreement it amplifies.

| # | Leak | Effect |
|---|------|--------|
| **D** | **Quick-shot cliff** — `shot_mechanics.release_wrister` switches at `quick_shot_threshold` (0.15 m) between two *different* direction bases (player→blade vs. cursor-drag) and two *different* power formulas (fixed `quick_shot_power` vs. charged lerp). | A sub-mm charge disagreement flips the shot **direction** → the puck redirects in flight → "weird bounce." Also the mechanism of the live forehand-left bug. |
| **C** | **Charge reconciled wrong** — `LocalController.reconcile` saves/restores `charge_distance` and then **unconditionally imports the host's value** (`local_controller.gd:513`). | Local charge gets yanked to the host's lagged, choppy value every broadcast. Source of the live bug and the old "rubber-banded charge" feel. |
| **A** | **Host eats inputs unevenly** — `RemoteController._drive_from_input` pops one input/tick gated by timestamp and repeats `_fallback_input` on gaps. | Under jitter the host simulates a *different input sequence* than the client did → different charge/blade → different shot. |
| **B** | **`delta` mismatch** — host passes its frame `delta` (`remote_controller.gd:125`); client uses `input.delta`. The blade speed cap (`max_blade_speed * delta`) and charge depend on it. | Per-tick blade travel differs between host and client. |
| **E** | **Origin is trusted, not derived** — host fires from the **client-sent** origin, clamped to stick reach (`game_manager.gd:2056`, `ShotReleaseRules.clamp_origin`). Docs note the host *can't* reconstruct it because the release pose is buffered ~`INPUT_LEAD_SEC` in the future relative to the immediate release RPC. | Not authoritative; and a wrong origin makes the puck jump at t=0 regardless of direction. |

## Target architecture

1. **Release is an input.** "Shoot released at tick T" already rides in the input
   stream. No separate trusted-params RPC is needed for authority.
2. **Host derives the shot.** When the host's simulation of the shooter reaches
   tick T (driven by the buffered input stream in `_drive_from_input`), it runs
   `release_wrister` / `release_slapper` **itself**, from its own deterministic
   charge + blade, and fires the authoritative puck. This is the authority: the
   shot is just another consequence of the input stream.
3. **Client predicts locally** exactly as now (instant feel) — fires a predicted
   puck on release.
4. **They match** because (A,B,C) make the per-tick sim deterministic and (D)
   makes the shot continuous, so any residual is a *small* difference the
   existing puck reconcile (three-zone, `puck_controller.apply_state`) blends
   away instead of hard-snapping.

This is the Source/Overwatch model: inputs up, authoritative sim on the server,
client prediction that matches because the sim is deterministic. Aim travels as
an input (legitimate — it's the player's control), the host *uses* it; the host
*derives* the rest.

## Fork decision: how charge becomes deterministic

- **Fork 1 — deterministic blade sim.** Keep charge coupled to the simulated
  blade (ROM-gated, speed-cap-gated — the recent feel). Requires the *entire*
  blade pipeline (smoothing, on/off-axis cap, ROM clamp) to be bit-reproducible
  on host and client. Leans on cross-machine float determinism of `sin/cos/atan2`
  — **not guaranteed**, so leak D's continuity becomes load-bearing insurance.
- **Fork 2 — charge from replicated inputs.** Derive charge magnitude from the
  mouse stream (already byte-identical on the wire) + a small replicated state,
  **not** from the smoothed blade. Charge becomes *exactly* deterministic with no
  float risk, at the cost of some blade-coupled feel (the "fast lateral sweep
  builds less charge" texture).

**Recommendation: Fork 2 + continuity (D).** It computes the shot from quantities
that are already identical on both machines, which is the only way to *guarantee*
"client shot == host shot" rather than hope a long trig-heavy integration matches.

## Defining "continuous shot" (leak D, numeric)

Replace the hard branch in `ShotMechanics.release_wrister` with a continuous blend
over a transition band, e.g. charge_t in `[t0, t1] = [0.15, 0.30]` of
`max_wrister_charge_distance`:

- **Power:** anchor the wrister curve so `power(0) == quick_shot_power`, then lerp
  up to `max_wrister_power`. No step at the boundary. (Today `quick_shot_power`
  and `min_wrister_power` can differ → a jump.)
- **Direction:** `dir = slerp(player_to_blade, cursor_drag, w)` where
  `w = smoothstep(t0, t1, charge_t)`. Low charge → player→blade (stable when the
  drag vector is too short to be meaningful); rising charge → cursor-drag. No
  categorical flip at any single charge value.

Result: the tap-vs-charge *feel* is preserved (a tap still fires player→blade at
snap power; a deliberate drag still aims where you dragged at charged power), but
a tiny charge disagreement now produces a tiny shot disagreement.

## Work plan (sequenced, each step independently shippable + testable)

### Step 1 — Kill the cliff (leak D)
- `shot_mechanics.gd`: continuous power + direction blend as above. Update
  `test_shot_mechanics.gd` (boundary continuity assertions).
- **Ships value immediately:** turns the live forehand-left bug and the bounces
  from a categorical flip into a mild, smoothable nudge — even before the
  determinism work.

### Step 2 — Charge is client-local-predicted + deterministic (leak C, Fork 2)
- `local_controller.gd`: drop the unconditional import (line 513). Snap charge to
  the server baseline + replay forward like `stamina` (remove the save/restore
  band-aid once replay is deterministic), OR keep charge purely local-predicted
  for now — decide alongside Step 4.
- Charge tracker (`charge_tracking.gd` / `skater_aiming_behavior.gd`): derive
  magnitude from the replicated mouse stream rather than the smoothed blade.
- **Fixes the live bug fully** (no more host-charge yank).

### Step 3 — Deterministic host sim (leaks A, B)
- `remote_controller.gd`: input jitter buffer deep enough that the host always has
  the next real input — `_fallback_input` becomes the rare genuine-starvation
  case, not a per-jitter contaminant. Pass `input.delta` (or a canonical fixed
  tick delta) into `_process_input`, not the host frame delta.
- Use one fixed sim delta for the blade cap + charge on both sides.

### Step 4 — Host derives the shot (leaks E + authority)
- `remote_controller._drive_from_input`: on the release-input tick, run
  `release_wrister`/`release_slapper` from the host's own sim; derive origin from
  the host's blade. Fire the authoritative puck here.
- `game_manager.on_remote_puck_release`: the client params become a *predicted
  hint* (or are removed); the host no longer trusts direction/power/origin —
  it derives them. Keep eligibility gates.
- Validate against the existing puck reconcile: with Steps 1–3, host-derived and
  client-predicted shots should agree to within the soft-blend zone (< 0.3 m), so
  the puck converges without a hard snap.

### Step 5 — Verify & tune
- Confirm three-zone thresholds (`trajectory_soft_blend_threshold` 0.3,
  `trajectory_hard_snap_threshold` 1.5) are right for the now-small residual.
- Online soak: forehand-left wristers under latency, fast cross-ice one-timers,
  charged vs. tapped shots, all under induced jitter/loss.

## Risks / open questions

- **Cross-machine float determinism** (Fork 1 risk) — sidestepped by Fork 2 for
  charge, but the blade *position* still feeds origin; Step 4 derives origin on
  the host so the client's predicted origin only needs to be *close* (smoothable),
  not exact.
- **Host derives shot ~`INPUT_LEAD_SEC` late** on its own timeline (it fires when
  its sim reaches tick T). Fine for the shooter (predicted locally) and spectators
  (interpolated in the past); confirm it doesn't delay the host-local goalie
  reaction (the existing `clamp_back_date` lag-comp already addresses this).
- **Feel cost of Fork 2** — losing some blade-coupled charge texture. Tunable;
  decide how much of that texture to reconstruct from input-space.
- **Protocol** — removing trusted shot params / `shot_charge` on the wire is a
  `PROTOCOL_VERSION` bump. Can defer (leave fields unused) to avoid churn.

## Can't verify headless

GUT covers the pure rule changes (Step 1 continuity, Step 2 charge math). The
prediction/authority behavior (Steps 3–4) needs a real host+client online session
under induced latency — describe the test matrix, hand to a local session.
