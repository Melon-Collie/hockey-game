# Elevation Rework — Design Doc (issue #585)

Status: **design draft — awaiting Melon's review before implementation.**
Supersedes the elevation half of `docs/attributes-v4-plan.md` §5.2 if adopted.
All constants below are STARTING VALUES for playtest tuning; the shapes and
invariants are the design.

## 1. The problem

The current model (`ShotMechanics.loft_y`, `shot_mechanics.gd:336-344`): each
loft level is a **fixed vertical launch speed** independent of shot power
(LOW 2.2, HIGH 4.65 m/s — `game_rules.gd:480-481`). Two consequences carry the
whole downstream world:

1. **The apex is a hard ceiling.** HIGH peaks at ~1.12 m (puck top ~1.14 m),
   a deliberate ~5 cm under the crossbar's inner edge (1.19 m). Power can
   never put a shot over the bar; it only pushes the apex distance out.
2. **Arrival height is an invertible function of (range, pace)** — which is
   what makes the AI's closed-form HIGH-hole solver possible
   (`action_scoring.gd:282-328`).

The blade-curve gear caps the *launch angle* at the face angle
(M88 26° / M92 31° / M28 45°). But the required launch angle for the full
HIGH v_y is `asin(4.65 / power)` — the face only binds below **6.6 m/s (M28),
9.0 (M92), 10.6 (M88)**, i.e. at or below the 10 m/s wrister floor. The
quoted min roofing distances (~2.2 / 3.7 / 4.5 m) are exactly the apex
distances of those barely-legal releases — a ~15 mph muffin. So in practice:

- **The M28's headline identity — roofing in tight — lives entirely below
  real shot pace.** A shot slow enough to ride the 45° face up is too slow to
  be a real attempt.
- **Steepness never differentiates at pace**: every blade flies the identical
  arc on every real shot (`test_face_angle_never_binds_at_pace` asserts this
  as a feature).
- **Missing high does not exist as an outcome**, so there is no risk premium
  on elevation. The AI even hand-fakes one: `LOFT_TIE_FRAC = 0.85`
  (`action_scoring.gd:470-474`) discounts HIGH shots with the comment "you
  can sail a high shot over the bar" — a risk the physics cannot produce.

Prior art (the trap to avoid): #340 set the apex AT the crossbar (v_y 4.9);
after #363 raised shot power (wrister 24→33, slapper 34→40) the apex distance
moved into common point/slot range and ordinary shots started sailing, so v_y
was walked back to 4.65 (history in `skater_controller.gd:595-610`). Any
rework must not resurrect "routine point shots go over the glass."

## 2. Design goals

1. **Roofing in tight at real pace**, gated by the blade face — the M28's
   upside becomes reachable in a game.
2. **Missing high is a real outcome**, scaled by power and blade — elevation
   at pace carries a risk premium, so steep faces are meaningful and
   dangerous rather than meaningless.
3. **The #363 regression stays dead**: an ordinary HIGH shot at moderate
   charge never sails; the sail risk is bought knowingly (full charge on an
   open face).
4. **The soft game is untouched, bit-exact**: saucer passes, flip clears,
   quick passes, and today's soft-roof face gating are all below the ramp
   threshold and compute identically.
5. **Trajectory stays a pure function of (power, level, face) — never
   position.** Same gesture, same arc, from anywhere on the ice.
6. Bots price the same model they shoot with; the goalie gets no free buff
   from shots that were going over anyway (controllers doctrine: realism may
   only open scoring windows).

Non-goals:

- **LOW and FLAT are unchanged.** The saucer pass is a pass mechanic; its
  fixed 0.26 m apex is calibrated into reception, deflection deadbands, and
  `blade_lift_height`'s floor (`skater_controller.gd:189-208`). No lift ramp.
- **Deflections are unchanged.** The tip model *deliberately rejected*
  pace-proportional loft ("a hard tip sails over the net; a fixed launch
  speed gives a consistent apex" — `puck.gd:64-67`). That reasoning stands:
  the tipper doesn't control the incoming pace, so scaling would randomize
  the outcome. Shots are different — the shooter owns the charge, so
  power-scaled lift is a *read*, not a lottery.
- **No new loft levels, no wire changes.** Still 3 levels in 2 bits;
  the build already replicates the curve gear (6 ints at join).

## 3. Options considered

**A. Raise the fixed apex above the bar (change one constant).** Misses high
become possible, but every blade still flies the identical arc at pace — the
M28 identity stays soft-gated, and the sail window lands uniformly on all
gears (the #363 failure, for everyone). Rejected as incomplete.

**B. Fixed launch *angle* per level (apex ∝ power²).** The physically
"obvious" model. Apex at full wrister would be meters over the net for any
angle steep enough to matter in tight; charge and elevation collapse into one
axis, and every gear needs its own angle table anyway. This is also exactly
the shape the deflection model measured and rejected. Rejected.

**C. Power-scaled v_y with a per-gear lift ceiling (recommended).** Keep the
fixed-v_y floor for everything at pass pace and below; above it, v_y ramps
with power toward a ceiling **set by the blade curve**. The crossbar apex
stops being a universal constant and becomes a *gear property*: the closed
blade keeps (approximately) today's no-sail guarantee, the open blade buys
real lift and real sail risk. The face-angle *tan cap* survives unchanged as
the soft-shot gate and degenerate-input guard.

## 4. The model (option C)

```
vy_high(p) = lerp(VY_BASE, vy_lift_max_gear,
                  clamp((p − P_LIFT_START) / (p_lift_full_gear − P_LIFT_START), 0, 1))
```

- `VY_BASE = 4.65` (today's constant — the floor of the ramp).
- `P_LIFT_START = 14.0` (= quick-pass power): **at or below pass pace the
  model is bit-identical to today** — saucers, flips, quick passes, the
  soft in-tight roof, and all three face-gate distances are untouched.
- Per-gear `(vy_lift_max, p_lift_full)` — how high the blade's lift ceiling
  sits and how fast pace climbs to it:

| Gear | vy_lift_max | p_lift_full | apex at ceiling | character |
|---|---|---|---|---|
| M88 (26°) | 4.85 | 33 | ~1.22 m | **keeps the no-sail guarantee** — apex kisses the bar's underside; the worst outcome is an iron ping. The safe point blade. |
| M92 (31°) | 5.15 | 30 | ~1.37 m | modest over-bar ceiling: never clean-sails below ~22 m/s; at full charge from mid-range (~12–22 m) it goes over — back the charge off or shoot FLAT. |
| M28 (45°) | 7.00 | 18 | ~2.5 m | the lift ramp is steep and tops out at snap-shot pace: **roofs from ~3 m at 36–40 mph** — the real in-tight identity. The tax: HIGH at pace from beyond ~4 m sails; from range this blade shoots FLAT/LOW or throttles way down. |

Worked consequences (approximate — tests pin the exact numbers):

- **M28 in tight**: at 18 m/s (~40 mph), v_y 7.0 → the arc crosses the
  top-shelf band ~3 m out. Today that shot requires 6.6 m/s (15 mph). The
  band is narrow at pace (a steep climb passes the 1.13–1.23 m window in
  well under a meter of travel) — softer pace widens it, continuously down to
  today's soft roof. Roofing in tight is a precision skill shot, not a
  freebie.
- **M92 from the slot**: full-power HIGH still snipes top shelf inside
  ~10 m — *on the rise*, before the arc escapes the cavity. From the point at
  full charge it sails; at ≤ ~18 m/s it can't sail at all (apex under the
  bar). The range/charge read the current model teaches survives — it just
  gains a failure mode at the top of the band instead of a silent clamp.
- **M88 from the point**: today's game, plus the occasional crossbar ping
  (apex now reaches the pipe's underside band). The "no gear may sail"
  guarantee narrows to *this gear* — which is its identity payoff as the
  playmaker/point blade.
- **Slappers share the profile** (same cfg fields, same ramp): a point bomb
  at HIGH on an M92 sails, on an M88 doesn't — consistent with M88's +3%
  slapper lean. (Open question 4 offers a flatter slapper ramp if playtest
  hates this.)
- **The face-angle tan cap is unchanged** (`loft_tan_max`, still min'd with
  the universal 45°): it still flattens the soft steep release per gear, and
  it still bounds every honest direction under
  `ShotReleaseRules.MAX_DIRECTION_Y = 0.75` (45° normalizes to ~0.707) — the
  host's forged-direction clamp needs no change. Steeper v_y at pace *lowers*
  the ratio (`vy/sqrt(p²−vy²)` at M28's ceiling: 7.0 at 18 m/s → ratio ~0.42).

Why this is still a grounded model, not a curve shaped to feel right: the
lift ceiling is the blade's face doing work — an open face converts more
blade speed into vertical impulse before the puck rolls off, a closed face
cannot lift a fast-moving puck no matter the effort. The ramp start at pass
pace is the existing calibrated boundary between "touch" and "shot." The
per-gear numbers are feel tunables (legitimately hand-picked); the *shape* —
floor at today's model, monotone ramp, face-ordered ceilings — is the design.

## 5. Knock-ons and how each is handled

### 5.1 Release math (`Scripts/domain/rules/shot_mechanics.gd`)

- `WristerConfig` / `SlapperConfig` gain `loft_vy_high_max` and
  `loft_lift_full_power` (defaults = base / 33, i.e. ramp disabled → old
  behavior; `loft_vy_high` keeps its name as the base).
- `_loft_vy` takes the power + config and applies the ramp for HIGH only.
  `loft_y` itself is unchanged (still solves the ratio from a v_y and caps at
  the face tan).
- `SkaterController.apply_attributes` (`skater_controller.gd:1193-1195`)
  wires two new `PlayerAttributes` accessors alongside `curve_loft_tan()`:
  `curve_lift_vy_max()` and `curve_lift_full_power()` (new tables in
  `player_attributes.gd` next to `_CURVE_FACE_ANGLE_DEG`).

### 5.2 AI shot model (`Scripts/domain/ai/action_scoring.gd`)

The tightest chokepoint. `_high_band_horizontal_speed` (`:282-328`) and
`best_shot_power_t` (`:1499-1534`) are closed-form inversions of the
`v_y ⟂ power` identity, with an arrival **floor** (pad-top seam 0.86) and no
ceiling — because the crossbar was the physics ceiling. Changes:

- **The HIGH band gets a top**: arrival must land in
  `[PAD_TOP_SEAM, CAVITY_TOP]` where `CAVITY_TOP ≈ NET_HEIGHT − post_r −
  puck_half` (the same bound `goal_detection_rules.gd:139` scores by). The
  solver never picks a pace whose arc crosses the plane above the cavity —
  **bots never deliberately sail**.
- **The closed form becomes a bounded sample**: with `v_y(p)` piecewise-linear,
  arrival height is no longer monotone-invertible in pace. Sample the wrister
  band at a fixed handful of power fractions (6–8), evaluate the arc
  (value-type math, allocation-free), take the fastest sample that arrives
  inside the band and clears the paddle at the goalie's plane. Deterministic,
  hot-path safe — but this multiplies per-hole cost, so **the AI benchmarks
  run before/after** (per-evaluator ranking + host-cost p95/max).
- `AISkaterCaps` gains `lift_vy_max` / `lift_full_power` beside
  `loft_tan_max` (`skater_caps.gd:81-85`), threaded through `RoleContext`
  exactly like `self_loft_tan` — a bot prices its own blade's real lift.
  Defensive reads of opponents keep the existing "assume open face"
  conservatism (now "assume max lift" — same residual, same rationale).
- `LOFT_TIE_FRAC` (`:470-474`) stays — its comment finally becomes true.
- `dump_loft_hang_s` (`:5485-5494`) and `saucer_hang_time_s` (`:1029`) take
  the release pace where the level is HIGH (LOW paths unchanged); callers
  already know their pace.
- `finisher.gd:161-196` (`_last_shooter_is_elevated`) still keys off
  `elevation_level > 0` — unchanged; a level still implies a lofted arc.
- The bearing-only aim spread (`best_shot_aim` has no y channel,
  `:1537-1538`) is accepted as a residual: the solver's band ceiling keeps
  the bot's *intent* under the bar; vertical execution scatter as a modeled
  miss source is future work, not this rework.

### 5.3 Goalie (`Scripts/domain/rules/goalie_behavior_rules.gd`, controllers)

- `detect_shot_into` (`goalie_behavior_rules.gd:76-117`) has a lateral gate
  but **no vertical one** — it would read a clearly-sailing puck as a shot,
  burn the reaction, and (with `react_hand_y_max = 1.55`, above the bar)
  could *catch a puck that was going over* — converting a miss into a save,
  exactly the free goalie buff the controllers doctrine forbids. Add the
  mirror gate: projected `impact_y` above the bar + a margin (~1.45 m) → not
  a shot on him. Marginal-over stays a shot (it can be tipped, and real
  keepers respect it).
- Cover calibration (`react_hand_y_*`, shoulder pitch, the 0.86 seam mirror
  in `_band_cover` `:393-438`) is re-pinned by the sweeps below, not
  re-designed.
- **Net feel check**: the rework makes the goalie's high game *more* readable
  (a baited full-charge M28 from 5 m is a miss, not a save), and the
  beatable-realism signature (deception must keep paying) is the metric to
  watch in the sweep deltas.

### 5.4 Physics / world (already mostly over-bar-safe)

Deflections and rebounds already put pucks above the bar, so this layer is
live code, not new code (`puck_geometry_collision.gd:12-16`):

- Crossbar / top-panel / back-mesh collision: exists and sub-stepped.
  **Known gap that becomes hot**: the crossbar solve spans
  `NET_CROWN_HALF_WIDTH` 0.815 while the posts span 0.915 — the top-corner
  bend region is unmodeled, and a launched shot into it will pass through
  the visual frame. Model the corner arcs (small addition in
  `resolve_crossbar`/`resolve_posts`) in phase 3.
- Goal detection already rejects above-cavity crossings
  (`goal_detection_rules.gd:111-114, 139`) — bar-down stays a goal, over-bar
  stays not one. No change.
- Shot-on-net / Corsi (`shot_on_net_rules.gd`) already classifies over-bar
  margins (0.15 on-net / 0.8 directed) — currently unexercised by launches;
  they become live tuning surfaces, noted, no code change.
- The net-stuck whistle (`game_manager.gd:630-660`) and behind-net board play
  already handle a puck arriving back there. The rink has no glass-height
  out-of-play (perimeter clamp is XZ at any height) — unchanged, same as
  deflections today.

### 5.5 Tests (rewrites, re-pins, new pins)

Per `tests/CLAUDE.md`, the calibration tables are pinned measurements — the
implementation commits state the new numbers are intended.

- **Rewritten contracts**:
  - `test_shot_mechanics.gd:401-414` (`loft_vertical_speed_fixed_across_power`)
    → split: bit-exact fixed at/below `P_LIFT_START`; monotone ramp above;
    per-gear ceiling reached at `p_lift_full`.
  - `test_shot_mechanics.gd:617-628` (`face_angle_never_binds_at_pace`) →
    replaced by a lift-gradient-at-pace test (per-gear arcs now *differ* at
    pace, ordered M88 < M92 < M28).
  - `test_blade_lever_calibration.gd:148-167`
    (`crossbar_ceiling_pinned_for_every_curve`) — the current model's
    constitution — rewritten to the new invariants: LOW v_y identical across
    gears; HIGH ceilings ordered by face; **M88's ceiling stays under the
    clean-sail line** (the no-sail guarantee as a gear property).
- **Re-pins**: roofing gradient (`test_shot_mechanics.gd:649-669`),
  high-band reachability (`test_ai_action_scoring.gd:601-628`), beatability
  goal maps (`test_goalie_exhaustive_beatability.gd`), shot-value calibration
  grid + slot truth + angle sweep, butterfly arrival table, real-goalie
  outcome tables. The sweep deltas are the design's acceptance evidence:
  HIGH cells should *open* in tight for open faces and *close* (miss-high)
  at range+pace.
- **New pins**:
  - per-gear sail-window characterization (distance × power table, the §4
    numbers made exact);
  - M28 in-tight calibration target: reaches the top-shelf band from ≤ ~3.5 m
    at ≥ 16 m/s;
  - soft-game bit-identity: every release at p ≤ 14 produces the identical
    `ShotResult` to the pre-rework model, all gears, all levels;
  - AI solver never selects an above-cavity arrival;
  - host clamp headroom: max honest `direction.y` stays < 0.75 across the
    full gear × power × level grid;
  - goalie over-bar gate: clearly-sailing shot triggers no reaction.
- **Benchmarks**: `-gdir=res://benchmarks` before/after phase 2 (the sampled
  solver is the risk; per-tick p95/max and the evaluator ranking).

### 5.6 Docs to update at implementation

`docs/gameplay-design.md:25` (the "cannot sail it over" paragraph),
`ARCHITECTURE.md` elevation section, `Scripts/domain/ai/CLAUDE.md` shot-danger
bullet ("HIGH holes are arrival-honest… fixed vertical launch speed"),
`Scripts/domain/state/CLAUDE.md` blade-curve bullet,
`player_attributes.gd` curve doc-block, `skater_controller.gd:595-610`
loft-speed doc-block, `docs/attributes-v4-plan.md` §5.2 (superseded pointer).

## 6. Phasing

1. **Domain mechanics** — ShotMechanics ramp + config fields, PlayerAttributes
   tables/accessors, controller wiring, mechanics-level tests (incl. soft-game
   bit-identity). Human-testable feel immediately; bot HIGH shots may sail
   mid-branch (their solver still assumes fixed v_y) — acceptable on the
   feature branch, fixed next phase.
2. **AI re-derivation** — banded sampler with the cavity ceiling, caps
   threading, calibration re-pins, benchmarks.
3. **Goalie + world** — over-bar reaction gate, beatability sweeps re-pin,
   crossbar corner-arc collision.
4. **Docs + drills audit + tuning pass** — tutorial/accuracy-drill targets are
   LOW-calibrated and unaffected, but verify the HIGH prompts; playtest the
   per-gear constants.

## 7. Open questions (for review)

1. **M88's guarantee**: hard no-sail (ceiling under the bar entirely) or the
   proposed "kisses the underside, iron pings possible"? Recommended: the
   ping — it's the feel payoff of the whole rework on the safe blade.
2. **The point-shot feel change** (the biggest one): under this model a
   full-charge HIGH wrister/slapper from range sails on M92/M28 — top-shelf
   from the point becomes "back off the charge," "drop it in falling," or
   "carry an M88." Is that the game we want? (It is the shot the issue asked
   to make real; saying yes here is confirming the cost.)
3. **M28 precision profile**: at pace the top-shelf arrival window is
   narrow (~0.5 m of range at 36 mph, wider softer). Razor-skill-shot as
   proposed, or fatten by lowering `vy_lift_max` / softening the ramp?
4. **Slappers**: share the wrister lift profile (proposed) or run a flatter
   ramp to protect HIGH point bombs on M92?

## 8. Out-of-scope flags (filed while researching, not part of this rework)

- `test_shot_mechanics.gd:606-613` hard-codes closed = 23° "from
  PlayerAttributes._CURVE_FACE_ANGLE_DEG", but the shipped table is 26°
  (`player_attributes.gd:287`) — the test's local constants drifted from the
  table they claim to mirror (its 5.20 m pin is the 23° value; the shipped
  26° gives ~4.5 m, which is what the docs quote). Harmless today (the test
  exercises `loft_y` math, not the table), but the pins misdocument the game.
- `docs/attributes-v4-plan.md` §5.2 likewise still reads 23°/5.2 m.
