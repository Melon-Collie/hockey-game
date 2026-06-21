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
| **A** | **Host eats inputs unevenly** — `RemoteController._drive_from_input` pops one input/tick gated by timestamp and repeats `_fallback_input` on gaps. | *Smaller than first thought.* A repeated input has zero `intent_delta`, so `charge_tracking.gd:48` adds **no** charge (and `prev_intent_pos` tracking means the next real input still measures the full delta) — fallback repeats are charge-neutral. Residual effect is only on per-tick **body position** (below). |
| **B** | ~~`delta` mismatch~~ — **NOT REAL.** Both host and client feed `_process_input` the `_physics_process` delta, which Godot fixes at the physics timestep (1/120) regardless of frame rate. Already identical. | None. |
| **F** | **Prediction lead** — the host simulates the shooter's body slightly behind the client's predicted body, so `TopHandIK.project_blade` clamps the same cursor against a slightly different body-relative position. | The real remaining host↔client charge/blade divergence. Continuous (Step 1 smooths it); **Step 4** removes it by making the host's value the one that matters. |
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

**Hard requirement:** charge must be gated by *reachable blade-travel space* — a
blade pinned at the ROM edge builds no charge. Mouse-position-based charge keeps
accruing against dead space past the reach limit (tried before, rejected). So the
ROM coupling stays; the question is only *which* blade reading charge uses.

- **Fork 1 — charge from the fully-simulated blade (current).** Reads
  `get_blade_position()` = smoothed + on/off-axis-capped + ROM-clamped +
  wall-clamped. The smoothing layer is stateful and delta/position-sensitive, so
  it won't replay cleanly. Leans on cross-machine float determinism of the *whole*
  blade pipeline — **not guaranteed.** (This is what diverges today.)
- **Fork 2 — charge from raw mouse position.** Exactly deterministic, but
  **breaks the ROM space-gate** — the cursor keeps moving past reach and charge
  keeps building. Rejected on the core feel requirement.
- **Fork 3 — charge from the ROM-clamped *target* blade.** Read the closed-form
  `TopHandIK.project_blade` result (`target_blade_world`,
  `skater_ik_coordinator.gd:115`), computed every tick *before* any smoothing,
  instead of the speed-capped smoothed blade.

**Recommendation: Fork 3.** It is strictly better than both:

- **Keeps the space-gate** — the target pins at the ROM edge, so cursor-past-reach
  → zero target travel → no charge. Same feel as today.
- **Drops the non-determinism** — `project_blade` is a pure closed-form clamp of
  (mouse-relative-to-body, ROM config); no stateful smoothing to diverge or
  replay. The determinism story stops depending on float-exact trig over a long
  integration and becomes simply *"both sides clamp the same mouse to the same
  ROM."*
- **Bonus:** also fixes the original forehand-left bug directly — the speed-cap no
  longer starves charge on lateral sweeps, because charge reads the reachable
  target, not the lagging capped blade.

This is the same change first floated for the live bug, now doing double duty as
the determinism foundation.

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
  categorical flip at any single charge value. For determinism consistency,
  `player_to_blade` should use the ROM-clamped *target* (Fork 3), not the smoothed
  blade — so the whole shot reads from the same deterministic source.

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

### Step 2 — Charge from the ROM-clamped target + deterministic reconcile (leak C, Fork 3)
- Charge source (`skater_controller._update_wrister_charge`): read the closed-form
  ROM-clamped target (`target_blade_world`) instead of `get_blade_position()` (the
  smoothed/capped blade). Keeps the ROM space-gate; sheds the smoothing coupling.
  (Needs `target_blade_world` exposed from `apply_blade_from_mouse`, which computes
  it but doesn't currently surface it.)
- Reconcile (`local_controller.gd`): drop the unconditional host-charge import
  (line 513). With the source now deterministic, charge can be snapped to the
  server baseline + replayed forward like `stamina` (retire the save/restore
  band-aid) — decided alongside Step 4.
- **Fixes the live bug fully** (no more host-charge yank, no speed-cap starvation).
- **Decided:** charge is distance-across-reach, **no rate element** — a fast flick
  across the ROM fills the bar fast (the visual blade lags behind, capped). This
  is the intended "fast flick" feel; do not add a per-tick rate cap.

### Step 3 — ~~Deterministic host sim (leaks A, B)~~ — MOSTLY UNNECESSARY
Re-examined after Steps 1–2 landed: leak B was never real (deltas already equal),
and leak A's fallback repeats are charge-neutral (zero `intent_delta` → no charge),
so an input jitter buffer buys **nothing for the shot**. The only residual shot
divergence is prediction lead (leak F), which a buffer doesn't address. A jitter
buffer remains a *general* movement-determinism nicety (fewer position reconciles
under jitter), but it's risky, online-only to verify, and out of scope for shot
fidelity. **Skip unless Step 4 testing shows input-cadence divergence.**

### Step 4 — Host derives the shot (authority) — RESHAPED BY FINDINGS

**Status:** chose option **C** (input-stream-driven, RPC-free end state), landed in
steps. **C-step 1 DONE** behind `HOST_AUTHORITATIVE_REMOTE_SHOTS` (default OFF):
host fires its own derived shot from the RemoteController's input-stream release,
live blade as origin. **C-step 2a DONE (no wire change):** the host-derived release
is fully input-native — it **approximates** the shooter's interp_delay from the rtt
it already measures plus one broadcast interval (the two dominant terms of
`_compute_target_interpolation_delay`, dropping only the adaptive jitter cushion).
interp_delay is *not* derivable from the timestamp (orthogonal: when-shot vs
view-staleness), but the rtt approximation is close enough for beatable goalies and
avoids threading metadata through the wire — so **no `PROTOCOL_VERSION` bump**.
**C-step 2b DONE (regular shots):** the `release_puck` RPC + `send_puck_release` +
the `HOST_AUTHORITATIVE_REMOTE_SHOTS` toggle are **deleted**. `_on_remote_derived_release`
→ `_fire_remote_shot` (renamed from the old RPC handler) is now the *only* path a
remote human's wrister/slapper fires; the client predicts locally and sends nothing.
Committed to the host-authoritative path (fix-forward, not revert).
**STILL PENDING — one-timers** (left on the legacy `release_puck_one_timer` RPC on
purpose): their wiring is ambiguous — `one_timer_release_requested` is connected for
*all* controllers, so on the host the remote's RemoteController emit may already run
the host firing branch *and* the RPC fires. Untangling that blind risks breaking a
working path; the current behavior (does it double-path today?) must be confirmed
before applying the same input-stream treatment.

**Finding:** the host *already* derives the authoritative shot. A remote human's
`RemoteController` runs `_process_input` → shot state machine → `_release_wrister`,
computing host-derived direction/power from its own replayed charge + ROM-target
blade, and emits `puck_release_requested`. But that signal is **only connected for
`is_local` and `is_bot`** (`game_manager.gd:1631,1640`), so for remote humans it
goes into the void (`_do_release` guards only `is_replaying`, not host). The host
then fires the client's RPC params (`on_remote_puck_release`, trust-but-clamp)
instead. So Step 4 = *use the shot the host already computes*, not build it.

**Complication 1 — release timing.** The host-derived shot fires when
`_drive_from_input` reaches the release input (host-time ≈ release +
`INPUT_LEAD_SEC` ≈ 25 ms). The immediate `release_puck` RPC arrives at ≈ release +
rtt/2 — *earlier* on fast links, later on slow ones. Whichever fires must be the
single authoritative release; the other becomes a no-op / metadata-only.

**Complication 2 — lag-comp lives on the RPC path.** `on_remote_puck_release`
carries `host_timestamp` + `interp_delay_ms` and uses them for goalie rewind
(fair shooter-view geometry), goalie reaction back-date, shot crediting, and the
shot-sound fan-out. The input-stream release has the `host_timestamp` but not
`interp_delay_ms`. Moving authority to the host-derived shot means threading that
lag-comp context to wherever the shot actually fires.

**Proposed shape (behind a default-OFF toggle, `HOST_AUTHORITATIVE_REMOTE_SHOTS`):**
- Connect remote-human `puck_release_requested` on the host to a handler that
  fires the authoritative puck from host-derived dir/power + the host's **live**
  blade contact as origin (no client origin, no buffer rewind — the live blade at
  the release tick *is* the authoritative point).
- The immediate `release_puck` RPC, when the toggle is on, **stashes** its
  lag-comp metadata (`host_timestamp`, `interp_delay_ms`, `rtt_ms`) per shooter
  and does eligibility validation, but does **not** fire. The host-derived handler
  consumes the stash. v1 limitation: on slow links where the input-stream release
  precedes the RPC, lag-comp falls back to last-known/default interp delay.
- Extract the fire body (sanitize/clamp + goalie rewind + release + crediting +
  sound) into one helper both paths call, so the toggle-off path is byte-identical
  to today.
- Shooter still predicts locally (`notify_local_release`), unchanged. With Step 1
  continuity, the host-derived vs. client-predicted residual (prediction lead,
  leak F) lands in the puck reconcile's soft-blend zone instead of snapping.

**Untestable headless.** Needs host+client online A/B (toggle off vs on) under
induced latency — watch for double-release, wrong origin, goalie-save timing.

### Step 5 — Verify & tune
- Confirm three-zone thresholds (`trajectory_soft_blend_threshold` 0.3,
  `trajectory_hard_snap_threshold` 1.5) are right for the now-small residual.
- Online soak: forehand-left wristers under latency, fast cross-ice one-timers,
  charged vs. tapped shots, all under induced jitter/loss.

## Risks / open questions

- **Cross-machine float determinism** — Fork 3 reduces charge to a closed-form ROM
  clamp (no long trig integration), so the dominant risk is gone. The blade
  *position* still feeds origin via trig; Step 4 derives origin on the host so the
  client's predicted origin only needs to be *close* (smoothable), not exact.
- **Host derives shot ~`INPUT_LEAD_SEC` late** on its own timeline (it fires when
  its sim reaches tick T). Fine for the shooter (predicted locally) and spectators
  (interpolated in the past); confirm it doesn't delay the host-local goalie
  reaction (the existing `clamp_back_date` lag-comp already addresses this).
- **Feel shift from Fork 3** — charge becomes distance-across-reach rather than
  blade-speed-limited time. Keeps the ROM gate; the fast-flick fill is **intended**
  (decided — no rate element).
- **Protocol** — removing trusted shot params / `shot_charge` on the wire is a
  `PROTOCOL_VERSION` bump. Can defer (leave fields unused) to avoid churn.

## Can't verify headless

GUT covers the pure rule changes (Step 1 continuity, Step 2 charge math). The
prediction/authority behavior (Steps 3–4) needs a real host+client online session
under induced latency — describe the test matrix, hand to a local session.
