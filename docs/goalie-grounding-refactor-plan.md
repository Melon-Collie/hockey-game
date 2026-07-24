# Goalie Audit — Grounding & Refactor Plan (July 2026)

Companion to `docs/AUDIT_2026-07_GOALIE_REALISM.md` (F1–F15, all shipped). That
audit asked **"does the goalie behave like a real goalie?"** and answered it well.
This one asks two different questions:

1. **Does the goalie *derive* its behavior from world state, or is it hand-tuned?**
   (the same standard the skater bot models are held to — CLAUDE.md → *Grounded
   models over magic-number curves*)
2. **Can the code be detangled** — the #519 god class, and the AI-threading
   conversion that `docs/ai-threading-plan.md` deferred *because* of the tangle.

It also folds in the one thing that post-dates the realism audit: the **wrister
model changed**, and the goalie hasn't been told.

**Scope note:** everything below is static analysis + the headless harnesses. No
gameplay verification was possible in this environment — every feel claim is
flagged as such and needs a local playtest.

---

## 0. Executive summary

The **rules layer is in good shape.** `goalie_behavior_rules.gd` (956 lines) is
almost entirely grounded physics: reachability solves, occlusion geometry, race
clocks, kinematic ramps. Nearly every function reads as real data. The realism
audit's fixes landed as *models*, not curves. That layer needs no rework.

**The controller is where the grounding erodes.** `goalie_controller.gd` is
4078 lines / 204 `@export`s / 103 functions / 91 member vars. It is simultaneously
the tuning bag, the perception layer, the decision layer, the actuation layer,
and the network render path. The magic constants are concentrated there, and so
is the threading blocker.

Three headline findings:

- **§1 — The goalie double-counts the shooter's velocity through the whole
  wrister windup.** During `WRISTER_AIM` the blade is frozen *body-local*, so the
  puck rides the carrier rigidly and `_puck_velocity_est` **is** `carrier.velocity`
  — yet the threat lead adds both, up to a 1.67× over-lead in tight. The slapper
  branch already zeroes the puck lead for exactly this reason, and it matters
  *more* on the wrister, because a slapper shooter is planted and decelerating
  while a wrister shooter can be skating flat out. **A live over-lead on the
  game's most common shot. Highest value, smallest diff.**
- **§2 — The quiet-eye prearm is a step function, and `prime_slot_distance` is
  the bandaid patching its dead zone.** The new wrister makes the honest
  continuous model reachable — which is also the precondition realism-audit F15
  named for raising `reaction_delay` off its sub-human 0.13 s floor. Two
  bandaids delete.
- **§3 — Seven independent models can pull depth; six can trigger the butterfly.
  Nobody owns the composition.** Each was added correctly and tested in
  isolation. The *interaction* is unmodeled, and that is the real source of the
  hand-tuned feel — more than any single constant.

Recommended order: **§1 → §2 → §5 Step 0 (characterization) → refactor → §3.**
§1 and §2 net-*remove* behavior, which makes the refactor smaller.

---

## 1. The wrister-model delta

### 1.1 What actually changed — and what did *not*

The wrister is now a **coil-and-release**: `LMB`-down enters `WRISTER_AIM`, which
**holds the blade at its current body-local pose** while the torso coils toward
the cursor; release fires along **origin→cursor**. Every charge tick publishes
the exact release that would fire *now* (`skater.predicted_shot_velocity`,
`skater_controller.gd:2394`).

**The critical qualifier: the freeze is body-local, not world-anchored, and the
wrister suppresses no locomotion.** `SkaterIKCoordinator.apply_blade_from_mouse`
under `hold_blade` re-resolves `upper_body_to_global(get_blade_position())` every
tick and explicitly carries the smoothed blade along with skater translation
(`_smoothed_blade_world += skater_pos - _prev_skater_pos`). The puck pins to that
blade via `get_carry_target_global()`. So during a wrister windup the shooter
retains **full thrust, steering and sprint** — the origin is frozen *to the body*
and fully mobile *in the world*, and the shooter can steer it.

The slapper is the opposite: `locomotion_suppressed` is true for
`SLAPPER_CHARGE_WITH_PUCK` (`skater_controller.gd:2548`) **and**
`_apply_slapper_velocity_drag` actively bleeds existing velocity toward zero
every tick, with the puck pinned to a fixed skater-local offset. That is a
genuine plant: the origin decelerates to a near-stationary world point.

| Signal | Old wrister (drag-aim) | New wrister (coil-and-release) | Slapper |
|---|---|---|---|
| Dangle jitter on the puck | **yes** — the whole problem | **none** (blade frozen body-local) | none (pinned) |
| Shot origin in world space | jittery *and* mobile | **rigidly rides the carrier** — mobile, steerable | plants and decelerates to ~rest |
| Puck velocity vs. carrier velocity | independent | **identical** (rigid body-local pin) | identical, but ≈ 0 |
| Direction + power intent | inferred from a drag vector | **published** every tick | published (locked at press) |
| Locomotion | free | **free** | suppressed + dragged |
| Commitment | low | low (still cancellable via `slap_pressed`) | high (planted, cancellable) |

So the wrister windup gives the goalie **two** of the three things the slapper
gives him — no jitter, and published intent — but **not** a stationary target.
That asymmetry is what the fixes below have to respect.

### 1.2 W1 — the double-counted lead (the live bug) — ✅ SHIPPED

`_compute_threat_position` (`:1633-1634`) adds two leads:

```gdscript
var lead: Vector3 = carrier.velocity * carrier_velocity_lead_time          # 0.12 s
        + _puck_velocity_est * puck_velocity_lead_time * puck_lead_scale   # 0.08 s
```

The second exists to catch motion the *carrier body* misses — dekes where the
body is still and the puck drags laterally. Its own doc-block (`:1625-1631`)
explains why the slapper zeroes it:

> the puck is pinned to the body and moves WITH it, so `_puck_velocity_est` IS
> the carrier velocity — the two leads then double-count the same body motion
> (~1.67× lead in tight) and OVER-lead a lateral coast, over-committing the
> goalie ahead of the pinned puck and opening the against-the-grain side.

**Every word of that now describes `WRISTER_AIM`** — the blade is rigidly
body-local, so the puck's velocity *is* the carrier's velocity, and there is no
independent dangle left to catch. And the failure is **worse** here than on the
slapper the fix was written for: a slapper shooter is planted and bleeding speed,
so there is little velocity to double-count; a wrister shooter can be skating at
full sprint, so the spurious extra lead is at its maximum exactly when the
goalie can least afford it.

Concretely, at 6 m/s lateral: correct lead 0.72 m, actual lead ~1.20 m in tight
— roughly half a net width of over-commitment, opening the against-the-grain
side. This is the "Colin cheese" seam (`:255-262`) reopened on the wrister.

**Fix.** Gate `puck_lead_scale = 0.0` on "the puck is rigidly pinned to the
body," which is true of both windups:

```gdscript
# skater_state_machine.gd — beside the existing state_has_puck()
static func state_pins_puck(state: int) -> bool:
    return state == State.WRISTER_AIM or state == State.SLAPPER_CHARGE_WITH_PUCK
```

### 1.3 W2 — the chest bias during a windup — ✅ SHIPPED

Same predicate, different consumer. `shooter_weight_slapper_windup = 0.0`
(`:263`, applied `:1613`) exists because "the body-weight bias only exists to
reject stickhandle jitter, which is absent here." During `WRISTER_AIM` the jitter
is likewise absent (frozen blade), so the surviving `shooter_weight_standing =
0.25` bias just displaces the goalie's squaring off the true origin by a quarter
of the frozen carry offset — a real lateral error, since the blade freezes
wherever it happened to be, often well out to the forehand side.

Rename `_reading_slapper_tell` → `_reading_pinned_windup`, gate on
`state_pins_puck`, rename the export to `shooter_weight_pinned_windup`.

**Blast radius:** `GoalieBodyConfigBuilder` reads `inputs.reading_slapper_tell`
(`:360, :389`) for the hands-up pose tell — a wrister windup earning that tell is
correct and desirable. `_is_carrier_at_doorstep` (`:1901`) must keep its
slapper-only gate — see W4.

**Test:** `tests/unit/ai/test_goalie_slapshot_read_headless.gd` covers the
slapper case; parameterize it over both windup states.

### 1.4 W3 — the aim shade: extend, but *weaken* for the wrister

`slapper_aim_shade = 0.7` (`:275`, applied `:3129-3140`) is a shape parameter,
and its doc-block admits it: *"Kept below 1.0 so a well-placed, quick corner
release can still beat him (beatable realism)."* It is also ramped by
`_shot_read_timer / prearm_read_time` — a second fudge stacked on the first.

The reachability quantity is already in the file:
`GoalieBehaviorRules.reachable_lateral_distance(max_speed, accel, t)`. The
grounded shade is "move toward the read crossing as far as the push can
physically carry you in the time you have had":

```
shade_distance = reachable_lateral_distance(t_push_speed, lateral_accel, fixation_time)
target_x = move_toward(target_x, shot_x_at_depth, shade_distance)
```

Then "a quick release beats the shade" is emergent — a 0.1 s windup buys ~7 cm,
a 0.8 s windup buys most of the crease — instead of enforced by `0.7`.

**But extending the shade to the wrister needs a second term the slapper never
needed.** A planted slapper's origin is going nowhere, so shading toward its
predicted crossing is a safe bet. A wrister shooter can *skate the origin
somewhere else entirely* before releasing, so a hard shade is a much worse bet —
and the counter (shade him, then relocate and shoot back against the grain) is
free. The honest bound is the smaller of what the goalie can reach and what the
shooter can still *invalidate*:

```
shade_distance = min(
    reachable_lateral_distance(t_push_speed, lateral_accel, fixation_time),
    # how far the origin itself can still travel before a plausible release
    origin_relocation_bound(carrier_speed, expected_release_window))
```

For the slapper that second term is ~0 (planted, dragged), so the shade stays at
today's strength for free. For a skating wrister shooter it shrinks the shade
automatically. The wrister/slapper difference becomes **emergent from measured
mobility** rather than a per-shot-type special case — which is the point.

Note this bound belongs on the **shade only**, not on the reaction-delay prime —
see §2.3 for why the timing credit survives shooter mobility and the positional
credit does not.

### 1.5 W4 — the doorstep-drop rationale is wrong, and the conclusion is right

`:1884-1887` justified not dropping for a wrister charge with "the player can
hold or cancel a wrister indefinitely."

Cancellability survives (`slap_pressed` aborts, `skater_state_machine.gd`
`_state_wrister_aim`). But the real reason is stronger and was never stated:
**the wrister windup suppresses no locomotion**, so it is a *mobile* threat whose
origin the carrier keeps steering. Dropping to it commits the goalie against a
shot that may not come from where he committed — and the beaten-wide race is very
much live during a wrister windup, because `carrier.velocity` is real.

**Recommendation: keep not dropping.** Only the stated reason changes. Flagged
because a future reader would otherwise inherit "the puck is frozen, so this is a
commit" — which is exactly backwards for the wrister.

---

## 2. The prearm: a step function where quiet-eye is a continuum

### 2.1 The current shape

```
_shot_read_timer accumulates while _is_reading_shot_threat()   (:3643-3649)
    ↓ crosses prearm_read_time = 0.40 s
_prime_linger_timer = prearm_linger                             (:3646-3647)
    ↓ consumed at release
leg_delay = min(leg_delay, prearmed_reaction_delay = 0.07)      (:3847-3849)
```

Below 0.40 s of fixation: **nothing**. Cold read, `reaction_delay = 0.13`,
`arm_reaction_delay = 0.18`. It is a cliff.

That cliff is exactly why `prime_slot_distance = 6.0` exists (`:149`). Its
doc-block (`:134-145`) is an honest confession:

> a real slot goalie is never a frozen statue on a quick release … the cold arm
> read of 0.18 s exceeds a slot shot's ~0.10-0.16 s flight, so uncredited the
> goalie never moves at all

So: a **blanket 6 m proximity prime**, granted with no windup at all, patching the
dead zone under a **0.40 s step threshold**. Two hand-set constants
compensating for the discretization of one continuous phenomenon.

### 2.2 The grounded replacement

Quiet-eye research gives the fixation→preparedness relation *as a continuum*
(Panchuk & Vickers: the save is programmed during the fixation; Clear Sight
Analytics: ~0.5 s of clear sight ≈ 97 % save). Model it as one map:

```gdscript
# GoalieBehaviorRules — new, pure, testable
static func primed_read_delay(cold: float, primed: float,
        fixation_s: float, full_fixation_s: float) -> float:
    return lerpf(cold, primed, clampf(fixation_s / maxf(full_fixation_s, 0.001), 0.0, 1.0))
```

Under the new wrister **every** wrister release has a non-zero fixation (the
freeze is the windup), so the continuum has real signal everywhere:

- 0.05 s snap wrister → ≈ cold read. *The skill window survives — honestly.*
- 0.5 s deliberate wind-up → ≈ fully primed. *The CSA set-and-sighted result.*
- quick pass (no aim state, `:E`) → genuinely zero fixation → cold. **Correct**:
  it is a pass, and the goalie should not be primed for it.

### 2.3 Three credits, invalidated differently — keep the timing, bound the cheat

A windup read pays the goalie in three separate currencies, and conflating them
is what makes "should a mobile wrister prime the goalie?" feel ambiguous:

| Credit | Mechanism | Spatially specific? | Survives the shooter relocating? |
|---|---|---|---|
| **Temporal** — the save is pre-programmed, released ballistically | `leg_delay = min(delay, prearmed_reaction_delay)`; `arm_cut` (`:3847-3849`) | **No** — it's "a shot is coming, now" | **Yes.** Readiness to *go* is direction-agnostic. |
| **Postural** — resting hands move toward the predicted impact | `prelean_*` (`:3521`) | Yes, but cheap to undo | **Mostly** — re-solved every tick off live `predicted_shot_velocity`, so it tracks a relocating shooter, and it adds no save speed |
| **Positional** — the *body* shades toward the predicted crossing | `slapper_aim_shade` (`:3129`) | **Yes**, and expensive to undo | **No.** If the origin moves, the goalie moved the wrong way — worse than not shading |

So the answer to "can the goalie still improve reaction time on a wrister
windup?" is **yes, essentially at full strength.** The temporal credit is what
quiet-eye research actually describes (the response is programmed during the
fixation and executed in <200 ms), and nothing about the shooter skating
invalidates *being ready to move*. It is the **positional** credit — the shade —
that a mobile shooter should be able to invalidate, which is exactly the bound
W3 (§1.4) adds. Same predicate, different strength per currency.

**Correction to an earlier draft of this document.** A prior revision proposed
accruing fixation *weighted by shot-origin stability*, so a skating shooter
granted less temporal credit. That was **double-counting**, the same defect W1
flags: a shooter whose motion forces the goalie to keep re-squaring leaves the
goalie with nonzero planar velocity at release, and `_movement_read_delay()`
(`:3780`) **already** charges for exactly that, computed from the goalie's own
`_velocity_x/_velocity_z` at the release tick. Adding a stability weight would
price the same physical effect twice.

The existing coupling is also more discriminating than the weight would have
been: a shooter skating *straight at* the goalie is radial motion that needs no
re-square, so the goalie stays set and correctly pays nothing — while a shooter
cutting *across* forces the push and correctly pays. Leave the temporal credit on
wall-clock fixation and let the caught-moving penalty do its job.

Consequences:

- **`prime_slot_distance` deletes.** It was compensating for the cliff.
- **`prearm_read_time` becomes `full_fixation_s`** — same number, but now a
  *scale* on a continuous curve rather than a threshold, which is a physical
  reading rather than a gate.
- **Realism-audit F15 unblocks.** The `reaction_delay = 0.13` doc-block
  (`:91-100`) already names the precondition: *"If a literal model is ever
  wanted, raise this toward 0.18 and let the prearm carry the fast reads."* With
  a continuum the prearm can carry them. Raising the cold read 0.13 → 0.18 (the
  measured elite simple-RT floor) and letting fixation buy it back is the honest
  model, and it *widens* the in-tight scoring window on quick releases — which is
  the direction the design wants (beatable realism).

⚠️ **This changes feel and must be playtested.** It is a real difficulty
redistribution: telegraphed shots get harder to score, snap releases get easier.
Suggest landing it behind the existing `GoalieSkillProfile` seam so tiers can be
re-balanced without touching the model.

---

## 3. Composition: the unmodeled layer

This is the finding with the most leverage and the least visibility.

**Seven things can constrain depth**, evaluated in sequence in `_update_depth`
(`:2852-2933`): the Buckley chart → the lateral-pressure pull → the backdoor cap
→ the rush backflow → the `min_challenge_depth` floor (`:3000`, `:3086`) → the
`depth_max_speed` rate cap → the `depth_speed` lerp. Some `min()`, some `max()`,
some `move_toward` with a bypassing rate, in a hand-ordered sequence.

**Six things can trigger the butterfly**: the low-shot release read (`:1670`),
the screen blocking drop (`:1657`), the doorstep slapper (`:1774`), the crease
jam (`:1782`), confirmed beaten-wide (`:1790`), the cross-crease lost race
(`:3624`) — plus `_on_puck_contact` (`:3873`). Priority is `elif` order in one
`match` arm.

Each is individually grounded and individually tested. **The composition is
neither.** There is no place that answers "given all of these at once, what is
the correct depth / save selection?" — the answer is whatever the `elif` order
happens to produce. That is the mechanism by which a codebase full of good models
still feels hand-tuned, and it is why adding the eighth constraint will be harder
than the seventh.

**Refactor target:**

```gdscript
# domain/rules/goalie_depth_solver.gd — pure
# Every constraint expressed as a MAX RADIUS the goalie may hold, plus a rate
# limit. The solve is min() over constraints; the rate is max() over the rate
# demands. Ordering stops being load-bearing.
class DepthConstraints:
    var chart_radius: float          # Buckley chart at threat distance
    var backdoor_cap: float          # re-square race (grounded)
    var lateral_cap: float           # see §4.1 — replaces the magic pull
    var rush_curve: float            # backflow anchor
    var rush_rate: float             # speed-matched retreat rate
    var floor_radius: float          # min_challenge_depth
```

Same for save selection: one `GoalieSaveSelection.decide(view) -> Selection` with
an explicit, documented priority contract, replacing the `elif` chain.

---

## 4. Grounding audit — the constant inventory

### 4.1 Tier 1 — evaluator magic (replace with a model)

| # | Constant / behavior | Where | Why it's a curve, not a model | Grounded replacement |
|---|---|---|---|---|
| G1 | `lateral_pressure_depth_pull = 0.20` m per m/s, `lateral_pressure_max_pull = 0.50` | `:319-320`, `:2886-2903` | Literally "metres of retreat per m/s of deficit" — a slope and a clamp. Realism audit F7 fixed its *input* (carrier vs. puck velocity) but left the curve. | The same race the backdoor cap already solves, with the "shooter" = the carrier's projected lateral position. `backdoor_depth_cap` generalizes to `depth_cap_for_lateral_threat` and G1 folds into it — **two behaviors become one model.** |
| G2 | `slapper_aim_shade = 0.7` + the `_shot_read_timer / prearm_read_time` ramp | `:275`, `:3138` | Admitted fudge ("kept below 1.0 so … can still beat him") | `reachable_lateral_distance` ∧ an origin-relocation bound — see §1.4 |
| G3 | `prearm_read_time` step + `prime_slot_distance = 6.0` | `:147`, `:149` | Threshold + a blanket proximity grant patching the threshold's dead zone | Continuous fixation map — see §2.2 |
| G4 | `net_margin = 3.0` m | `:196` | A 3 m margin on a **0.915 m** half-width net: the goalie starts a full reaction *freeze* (no lateral movement, no cross-crease read — `_move_along_arc:3105`) on shots ~4 m wide of the post. The doc justifies it as "tracking," but the consequence is a commitment far heavier than tracking. | The physical quantity is deflection reachability: a wide shot is a threat iff a stick could plausibly tip it on-net. Derive from `GameRules.DEFAULT_STICK_LENGTH_M` + body half-width, not a round 3.0. Alternatively split the constant: a wide margin for *tracking*, a tight one for *freezing*. |
| G5 | `recovery_proximity_threshold = 2.4` m | `:798` | The comment says "~a couple of stick-lengths" — so derive it: `2 × GameRules.DEFAULT_STICK_LENGTH_M = 2.6`. | Better still: hold the seal while `flight_time_from_puck < recovery_duration + reaction_delay` — the actual question being asked. |
| G6 | `_is_threat_pressing` priority ladder | `:2814-2843` | An ordered heuristic (proximity → jam → speed → direction) with three thresholds | Same as G5: one race — can a shot from where the puck is beat my stand-up? |
| G7 | `prelean_strength = 0.35` | `:745` | "0 = off, 1 = full reach pre-committed" — a dimensionless dial | Bound by recoverability: lean as far as the arm can *come back from* if the aim flips, i.e. `glove_react_max_speed × expected_release_window`. Makes the counter-read (fake the corner) emerge from arm kinematics. |
| G8 | Three imminence gates: `drop_max_time_to_impact = 0.45`, `react_max_time_to_impact = 0.9`, `universal_react_max_time_to_impact = 0.6` | `:117`, `:161`, `:206` | All three doc-blocks justify themselves with the *same sentence*: "passes fire `puck_released` like a shot." They are three hand-tuned windows compensating for one missing classification. | The signal exists at the source — quick pass vs. wrister vs. slapper, and whether `predicted_shot_velocity` was on-net. Plumb shot intent through the release event; three magic gates collapse into one honest read. (Also removes the `_universal_shot_cfg` clone, G12.) |

### 4.2 Tier 2 — derivable or duplicated values

| # | Item | Where | Note |
|---|---|---|---|
| G9 | `0.38` inline, twice | `:3066`, `:3069`, `:3072` | Comment says "outer pad reach (0.88) − 0.50 body inset" — but the file's own pad edge is `pad_local_offset + butterfly_pad_half_width = 0.84`, not 0.88. **The comment has already drifted from the geometry.** Derive it. |
| G10 | `cross_crease_drive_edge = 0.42` | `:672` | Byte-identical duplicate of `pad_local_offset = 0.42` (`:683`); the doc-block even says "Default = pad_local_offset". Two exports that must move together, with nothing enforcing it. |
| G11 | `pad_local_offset = 0.42`, `butterfly_pad_half_width = 0.42` | `:683`, `:693` | These are **collision-geometry facts of `Goalie.tscn`** exposed as editable exports. Editing either silently breaks the post-seal math (`_post_edge_seal_x`) with no error. Should be constants derived from the scene, not tuning. |
| G12 | `_universal_shot_cfg` — a full config clone to defeat one field | `:1357-1363` | Symptom: `ShotDetectionConfig` conflates "is this fast enough to be a shot" with "where does it hit." Split the speed gate out of the geometry solve. |
| G13 | Inline literals with no name | `+0.3` slack (`:2368`, `:2267`); `0.25`/`0.2`/`0.6` trip thresholds (`:2579`, `:2608`, `:2615`, `:2637`); `6.0 * delta` stride ease (`:3062`); `_sweep_lane_cfg.reaction_delay = 0.08` (`:1407`); net-front `1.0` (`:2494`, `:2552`); recovery facing `0.5` scale (`:3360`); slide re-commit `0.05` (`:3274`) | Individually harmless; collectively they are the "hand-tuned" texture. Promote to named consts at minimum. |

### 4.3 What is **already well grounded** (do not touch)

Worth stating explicitly so a future pass doesn't "fix" these:

- The whole of `goalie_behavior_rules.gd` — reachability, occlusion, race clocks,
  kinematic ramps, five-hole geometry. This is the model of what the rest should be.
- `butterfly_drop_speed = 0.20` — motion-capture measured (Brock Univ.).
- `glove_react_max_speed = 5.0` — derived from measured hand speed with the
  flat-vs-peak reasoning written out.
- `lateral_commit_confirm_s = 0.15` — quiet-eye fixation window.
- `screen_max_extra_delay` as a **cap on a computed delay**, not a flat penalty.
- The puck-play go/no-go races — deliberately conservative, and the conservatism
  is expressed as *margins on a real clock*, which is the right shape.
- `move_read_max_delay` — a latency, correctly additive and motion-gated.

---

## 5. Refactor plan (#519)

### 5.1 Why the current shape blocks threading

`docs/ai-threading-plan.md:177-199` deferred the goalie with a precise diagnosis:

> Converting it would need three replicated-state additions … **~100 live-read
> conversions**, and a **decision/mutation split** (the poke / sweep / cover /
> `set_puck_*` are physics mutations that can't run on a worker regardless) — a
> large, feel-critical refactor … The goalie code is also rough enough that a
> threading conversion should ride a broader goalie refactor, if one happens.

That is this document. The blocker is not the goalie's *cost*, it is that
perception, decision, and mutation are interleaved across ~40 methods. The bots
solved this already: `AICoordinator` works because `decide()` reads a frozen
`WorldSnapshot` and writes only an `InputState`. The goalie has no equivalent
seam.

### 5.2 Target decomposition

Split **by phase of the tick**, not by feature — that is what makes it threadable
*and* what makes it testable.

| Component | Layer | Responsibility | Approx. source today |
|---|---|---|---|
| `GoalieWorldView` | domain/state | Plain data: puck pos/vel, carrier team, **pinned-windup state**, `predicted_shot_velocity`, opponent/teammate position arrays, geometry, own kinematics | (new) |
| `GoaliePerception` | application | **The only place that reads live nodes.** Fills the view. ~15 reads replacing ~100 scattered ones. | the `puck.*` / `_skater_getter` reads throughout |
| `GoalieDecision` | **domain, engine-free** | view + memory + tuning → `GoalieIntent` (target state, target x/z/depth, save selection, pose flags, *requested* puck actions) | `_update_state`, `_update_depth`, `_update_position`, `_update_facing`, the trigger predicates |
| `GoalieActuation` | application | Applies intent to nodes; executes requested puck mutations **on the main thread** | `set_goalie_position`, `apply_body_config`, poke/sweep/cover/`set_puck_*` |
| `GoalieDepthSolver` | domain | §3 — constraint min(), rate max() | `_update_depth`'s sequence |
| `GoalieSaveSelection` | domain | §3 — one decision, explicit priority | the `elif` chain in `_update_state` |
| `GoaliePuckPlay` | application | The `_pp_*` behind-net trip — already cohesive | `:2470-2645`, 11 state vars |
| `GoalieCreaseClear` | application | Sweep windup/strike/follow-through + cover + catch lifecycles | `:2157-2463`, ~12 state vars |
| `GoalieTuning` | Resource | The 204 exports | the top 930 lines |

`GoalieTuning` alone fixes three smells: `_apply_skill_profile`'s 17-line manual
field copy (`:1181`), `_configure_collaborators`'s 45-line manual push (`:1277`),
and the fact that "the tuning bag" is currently the same object as "the AI."

### 5.3 Sequencing — each step independently shippable, suite green

**Step 0 — Characterization harness (do this first, always).**
`tests/unit/ai/real_goalie_shot_harness.gd` already drives the *real* controller
against the *real* analytic save loop. Extend it into a recorded **save-rate
matrix** over (range × angle × loft × shot type × windup duration) and commit the
baseline. This is the refactor's safety net and the only way to tell a feel
regression from an intended change. It also gives §1/§2 a measurable before/after.

**Step 1 — `GoalieTuning` resource.** Mechanical, no behavior change. Big
readability win immediately (930 lines out of the controller).

**Step 2 — `GoaliePuckPlay` + `GoalieCreaseClear`.** Mechanical extraction into
the existing `_slide` / `_reaction` collaborator idiom. ~550 lines and ~23 member
vars out.

**Step 3 — `GoalieWorldView` + `GoaliePerception`.** Funnel every live read.
Behavior-identical, purely a data-flow change. **This is the step that pays for
threading**, and it is independently valuable: after it, the decision logic is
testable without a scene.

**Step 4 — `GoalieDecision` split** + `GoalieDepthSolver` / `GoalieSaveSelection`
(§3). The real work, and the only step with genuine behavior risk — which is why
Step 0's matrix must exist first.

**Step 5 — Threading.** Now a small change: three replicated-state additions
(`PuckNetworkState.pickup_locked`, `SkaterNetworkState.predicted_shot_velocity`
+ `team_id`) and moving `GoalieDecision` onto the existing `AICoordinator`
worker. The mutation split already exists from Step 3/4.

### 5.4 Where the feel work fits

Land **§1 (W1/W2) and §2 before Step 3.** They are small, high-value, measurable
against Step 0's matrix, and they *net-delete* behavior — which makes Steps 3–4
smaller. Doing them after a large refactor would make a feel regression
impossible to bisect.

§4's Tier-1 items (G1, G4–G8) are best done **as part of Step 4**, since each one
is a model replacing a curve inside the code being restructured anyway.

---

## 6. Suggested first tranche

Smallest diff with the highest ratio of "goalie reads the world" to "goalie was
told the answer":

1. Step 0 — extend the shot-outcome harness into a committed baseline matrix.
2. ~~W1 — `state_pins_puck`; stop double-counting carrier velocity through a
   wrister windup.~~ **✅ SHIPPED.** Measured at 3.5 m / 2.0 m/s lateral: lead
   0.240 m (carrier only) vs 0.362 m double-counted — a 51 % over-lead removed,
   scaling with carrier speed.
3. ~~W2 — same predicate for the chest bias during a windup.~~ **✅ SHIPPED**
   (`shooter_weight_pinned_windup`).
4. W3 — mobility-bounded aim shade; delete `slapper_aim_shade`. Held back
   deliberately: the shade is gated on the new `_reading_planted_windup`
   (slapper-only) until the origin-relocation bound exists.
5. §2 — continuous fixation map on wall-clock (§2.3: *not* stability-weighted —
   the caught-moving penalty already prices that); delete `prime_slot_distance`;
   optionally raise `reaction_delay` to 0.18 behind the skill-profile seam.
6. G1 — fold the lateral-pressure curve into the backdoor race solve.

Items 2–6 remove **four** hand-tuned constants and one whole behavior, and every
one of them replaces a curve with a quantity the goalie can physically see.
Item 2 is the only one that is unambiguously a defect fix; 3–6 change feel.

All of it needs a local playtest — none of the feel claims here have been
verified in a running game.
