# Elevation Rework — Design Doc (issue #585)

Status: **agreed-design draft, v2 (contact-point model)** — implementation
follows the CLAUDE.md workflow: this doc is the plan; deviations get discussed
first. v1 (power-scaled vertical speed with per-gear lift ceilings) is in git
history; it was set aside because it still derived height from speed, when the
real-life controlled variable is launch angle. Supersedes the elevation half of
`docs/attributes-v4-plan.md` §5.2.

All constants below are STARTING VALUES for playtest tuning; the shapes and
invariants are the design.

## 1. The problem

The current model (`ShotMechanics.loft_y`, `shot_mechanics.gd:336-344`): each
loft level is a **fixed vertical launch speed** independent of shot power
(LOW 2.2, HIGH 4.65 m/s — `game_rules.gd:480-481`), so every HIGH shot apexes
~5 cm under the crossbar. The blade-curve face cap (26/31/45°) binds only below
~6.6–10.6 m/s — at or under the 10 m/s wrister floor — so:

- **The M28's identity — roofing in tight — lives entirely below real shot
  pace** (the min roofing distances ~2.2/3.7/4.5 m are the apex distances of
  ~15 mph muffins).
- **Steepness never differentiates at pace**: every blade flies the identical
  arc on every real shot.
- Elevation carries no risk and no read beyond range/charge; the AI hand-fakes
  a sail risk that cannot occur (`LOFT_TIE_FRAC`, `action_scoring.gd:470-474`).

Prior art: the game's *original* elevation was an adaptive solve to a target
height at the goal line. It roofed beautifully in tight but was retired
because it made saucer/elevated passes impossible and produced unbounded
weird arcs on misses (`shot_mechanics.gd:34-37`). #340/#363 then showed that
any fixed-speed model either can't roof or sails routine point shots
(`skater_controller.gd:595-610`). This rework brings the adaptive solve back
with those failures specifically closed off.

## 2. The model — elevation is where the puck sits on the blade

Real-life grounding: a shooter's controlled variable is **launch angle**, set
by face/wrist roll at release — and on strong-curve blades the dominant input
is **where the puck contacts the blade**: heel shots go low regardless of
snap, mid-blade rolls go medium, toe shots go upstairs (on an open toe,
"the rafters"). The loft level is fictionalized as that contact point:

| Level | Contact | Behavior |
|---|---|---|
| FLAT | heel | unchanged — along the ice, the hard easy release |
| LOW | mid-blade, partial roll | a **set launch angle** `θ_low ≈ 8°` — the saucer at pass pace, a mid-net rising shot at pace |
| HIGH | toe | an **adaptive solve**: launch angle chosen so the arc crosses the attacking goal plane at target height `H ≈ 1.05 m` (top shelf), clamped to the blade's **toe cap** |

This models the shooter's calibration skill (a real shooter solves the angle
by feel every time), and the modal "P28 experience" from play reports — pick
the contact point, then commit attention to power and lateral aim — is
literally this input scheme.

### 2.1 The HIGH solve

Given release speed `p`, distance `d` to the attacking goal plane along the
shot's XZ direction, target `H`:

```
tan θ = (p² − √(p⁴ − g·(g·d² + 2·H·p²))) / (g·d)      (flat root)
θ     = clamp(θ, 0, toe_cap_gear)
```

- **Discriminant < 0 (unreachable — soft pace at long range)** → clamp at the
  toe cap: the maximum lob. The defensive flip clear falls out of the math.
- **Goal plane selection**: the plane the shot direction faces (sign of the
  direction's z). Near-parallel (cross-ice) → unreachable → toe-cap lob,
  which is the honest reading of "flicked it high with nothing to solve
  toward."
- **Misses are bounded**: worst case is the toe cap (45°), never the
  near-vertical degeneracies that made the old adaptive system's misses fly
  absurdly. An in-tight roof attempt that misses climbs steeply and hits the
  glass behind — which is what that miss really does.

### 2.2 The toe caps — the primary gear lever

The per-gear cap is **what the toe of the pattern gives a toe-released
shot**, not the blade's static face angle (a P88's face is ~26°, but its toe
gives you almost nothing — the cap describes the toe):

| Gear | toe cap | min roofing distance @ 18 m/s (~40 mph) | @ 25 m/s |
|---|---|---|---|
| M88 | 15° | ~6.4 m | ~4.6 m |
| M92 | 22° | ~3.0 m | ~2.8 m |
| M28 | 45° | ~1.1 m | ~1.1 m |

(Min roofing distance = closest range from which the solved angle for `H`
fits under the cap.) The identity triangle finally exists at real pace: M28
roofs from anywhere including the doorstep, M92 from the slot in, M88 needs
the high slot. Two emergent properties, both realistic and both inverted
from the current model:

- **Pace helps you roof**: harder shots need shallower angles, so charging
  up lets the closed blades roof from closer. Snap it hard to go upstairs in
  tight — instead of today's "only a muffin roofs in tight."
- **HIGH is the solved intent; LOW keeps the emergent read.** A HIGH shot
  arrives at `H` whenever solvable, at any charge — pace buys flight time
  against the goalie's deploy, not height. LOW's fixed roll is the level
  where "where does this arrive" remains a range/charge read (at full charge
  from the point an 8° LOW arc arrives top-shelf-ish itself; backed off, mid
  net; soft, a saucer). The old model's celebrated skill lives on in LOW.

### 2.3 LOW as a set angle

`θ_low = 8°` (tan ≈ 0.1405):

- At pass pace (14 m/s): apex ~0.21 m — the saucer, marginally flatter than
  today's 0.26 m; still clears stick blades (0.07 m), still lands and slides,
  still far below the lifted-blade pivot (0.55 m) so the deflect anti-cheese
  argument and `blade_lift_height`'s floor (`skater_controller.gd:189-208`)
  hold.
- At pace: a mid-net rising shot (over the pads from the slot) — the third
  band between FLAT and HIGH that the fixed 2.2 m/s never was (a full-power
  LOW today arrives essentially flat).
- **8° is chosen so LOW can never sail**: apex at max wrister power (33) is
  ~1.09 m, under the bar. The alternative 9° matches today's saucer apex
  exactly but opens an 11–23 m over-the-bar band at full charge — see open
  question 1.

### 2.4 Quick passes stay on the fixed-speed table

The quick-pass button keeps today's fixed vertical speeds (LOW 2.2 /
HIGH 4.65): a saucer pass and a flip pass are *pass* mechanics, calibrated
into reception and deflection, and must not solve toward a net that isn't
their target (the exact failure that killed the original adaptive system).
The pass/shot split already exists as a hard input split
(`release_wrister`'s `is_quick_pass`, separate buttons) — the two math paths
sit on opposite sides of a boundary the codebase already enforces. Wristers
and slappers get the new model; quick passes are bit-exact.

### 2.5 What this deliberately gives up

- **Missing high on an on-net HIGH shot mostly disappears** (the solve
  targets under the bar). The risk outcome moves to: in-tight steep misses
  flying up the glass, toe-cap lobs from unreachable range, and (if 9° is
  chosen) full-charge LOW from the point. Accepted: the substance of #585
  was that roofing didn't exist, not that sailing didn't.
- **Trajectory stops being position-free.** Position enters *only* as
  distance-to-goal-plane along the shot direction. Deterministic from
  replicated release state on every peer; the "same gesture, same arc,
  anywhere" invariant is repealed and its doc statements rewritten (§5.6).
- **Every HIGH arrival is at `H`**, so the goalie's high read is
  height-deterministic and top-corner play is an x-aim-vs-glove contest.
  Accepted for readability — and offset by the optional contact-point tell
  (§5.7).

## 3. Considered and declined

- **v1 of this doc (power-scaled v_y, per-gear lift ceilings)**: kept height
  coupled to speed — the thing the real mechanism doesn't do — and priced
  roofing at range as a sail lottery. Git history has the full writeup.
- **Fixed launch angle for HIGH** (apex ∝ p²): unusable from range at any
  angle steep enough to roof in tight; also the shape the deflection model
  measured and rejected (`puck.gd:64-67`).
- **Re-leaning saucer quality against the M28** (real P28s sauce badly —
  puck-position sensitivity we don't simulate): declined; the saucer is a
  core pass mechanic and stays uniform. The M28's passing tax remains
  reception (−7%) and slap (−3%). Recorded so it isn't re-proposed cold.
- **Deflections**: unchanged entirely. The tip model's fixed launch speed
  was chosen *because* the tipper doesn't control incoming pace
  (`puck.gd:64-67`); that reasoning is untouched by this rework.

## 4. Why this is a grounded model

The solve is the shooter's own calibration — the thing ten thousand reps
build — executed by the player-character, with the blade's toe as the
mechanical limit. The clamp produces the roofing gradient with no positional
special-casing: in tight the required angle is steep, and either your toe
gives it (M28) or it doesn't (M88). Feel tunables (`H`, `θ_low`, the three
toe caps) are legitimately hand-picked; the *shape* — solve to intent, clamp
at hardware — is the design.

## 5. Knock-ons

### 5.1 Release math (`Scripts/domain/rules/shot_mechanics.gd`)

- `loft_y` is superseded for wristers/slappers by a solve taking
  `(power, level, toe_tan, dist_to_goal_plane)`; quick passes keep the
  `_loft_vy` fixed-speed path. Configs gain `loft_tan_low`, `toe_tan_max`;
  `H` is a `GameRules` constant beside the net geometry it references.
- The release seam gains one input: the caller supplies the distance to the
  faced goal plane (`SkaterController` at release; bots from their state).
  The function stays pure — position enters only through that scalar.
- `SkaterController.apply_attributes` wires `curve_toe_tan()` (renamed/new
  accessor + table in `player_attributes.gd`, replacing `curve_loft_tan`'s
  role in shots; the 45° `MAX_LOFT_RATIO` guard remains the universal bound).
- Host anti-cheat: `ShotReleaseRules.MAX_DIRECTION_Y = 0.75` needs no change
  (toe cap 45° normalizes to ~0.707).

### 5.2 AI shot model (`Scripts/domain/ai/action_scoring.gd`) — gets simpler

The entire arrival-honesty apparatus existed to answer "what height does a
fixed-speed arc reach at this range × pace" — a question the new model
answers by construction.

- `_high_band_horizontal_speed` (`:282-328`) and the pace inversion in
  `best_shot_power_t` (`:1499-1534`) are **deleted**. A HIGH hole is live iff
  the solved angle from here at shooting pace fits under the bot's toe cap
  (`AISkaterCaps.loft_tan_max` → renamed `toe_tan_max`) — the same clamp the
  human feels. Arrival height is `H` (above the 0.86 pad-top seam by
  construction); a clamped shot's arrival is computed directly from the
  clamped arc.
- HIGH shots fire at **full pace** (arrival fixed; faster only shrinks the
  goalie's deploy window — and shrinks the clamp distance). This is a large
  behavioral shift: the old model's "reaching the band takes ≥ ~0.25 s of
  arc, so a set keeper's glove gets its full deploy — set-keeper top corners
  shut everywhere" story is gone. Expect the beatability sweeps to blow the
  HIGH bands open; the goalie's high game gets retuned against it (§5.3).
- The HIGH band gains a top edge in `_band_cover` reasoning only insofar as
  arrivals are now at `H` — the band model itself (two bands, seam floor)
  survives; `LOFT_TIE_FRAC`'s fake risk premium is retired with the pace
  solve. Bots still shoot only FLAT and HIGH (LOW remains a pass/human
  tool); revisit a third band only if playtest shows mid-net value.
- `dump_loft_hang_s` (`:5485-5494`) / `solve_dump_clear` / `solve_dump_in`:
  hang time becomes `f(level, power, toe cap, d)` via the same solve
  (unreachable → toe-cap lob is precisely the AI's clear). Saucer paths
  (`saucer_hang_time_s`, `lane_clear_saucer`) key off the quick-pass fixed
  table — unchanged.
- `trajectory.gd:338-379` (`is_puck_airborne`, gate "launch vy ≥ ~2 m/s"):
  a soft-sweep LOW wrister at 8° launches below 2 m/s — re-derive the gate
  from launch angle × pace or lower the threshold; verify reception/deflect
  planning against it.
- `finisher.gd:161-196` keys off `elevation_level > 0` — unchanged.
- Benchmarks run before/after phase 2 anyway, but the expected delta is
  *negative* cost (a closed-form solve replaces the windowed inversion).

### 5.3 Goalie

- **Over-bar reaction gate** (`goalie_behavior_rules.gd:76-117`,
  `detect_shot_into`): still added — projected `impact_y` above ~1.45 m at
  his plane → not a shot on him. Less load-bearing than under v1 (on-net
  HIGH shots don't sail) but toe-cap lobs and in-tight steep misses pass
  over his net, and with `react_hand_y_max = 1.55` he can currently *catch a
  puck that was going over* — the free-save the beatable-realism doctrine
  forbids. Mirrors the existing lateral gate.
- **The high-game retune is the big item.** Full-pace HIGH arrivals at a
  known height `H` change the top-shelf race entirely: the arm-reaction
  delay, glove deploy, and `_band_cover`'s HIGH hand model
  (`action_scoring.gd:393-438`) get re-calibrated against the sweeps with
  the beatable-realism signature as the acceptance test — deception must
  keep paying, set-keeper top corners should be *hard but real*, and the
  height-determinism of `H` is the goalie's compensating read.

### 5.4 Physics / world

Deflections and rebounds already put pucks above the bar, so this layer is
live code (`puck_geometry_collision.gd:12-16`); goal detection already
rejects above-cavity crossings and keeps bar-down goals
(`goal_detection_rules.gd:111-114, 139`); shot-on-net/Corsi margins already
classify over-bar (`shot_on_net_rules.gd`). Remaining items:

- In-tight misses now routinely fly the glass behind the net: the net-stuck
  whistle (`game_manager.gd:630-660`) and behind-net board play get more
  traffic — existing behavior, verify feel.
- The crossbar solve spans `NET_CROWN_HALF_WIDTH` 0.815 vs the 0.915 post
  line — the top-corner bend is unmodeled. Lower priority than under v1
  (on-net shots don't cross up there) but tips/misses can; keep as a
  phase-3 nicety.

### 5.5 Tests

Per `tests/CLAUDE.md`, calibration tables are pinned measurements — the
implementation commits state that the new numbers are intended.

- **Rewritten contracts**:
  - `test_shot_mechanics.gd:401-414` (fixed-vy-across-power) → replaced by:
    arrival-at-`H` property over a solvable (range × power × gear) grid;
    clamp behavior at/below the toe cap; unreachable → toe-cap lob;
    quick-pass releases bit-exact against the old table.
  - `test_shot_mechanics.gd:617-628` (face never binds at pace) → inverted:
    per-gear arcs *differ* at pace; min-roofing-distance ordering
    M28 < M92 < M88 at fixed pace, shrinking with pace.
  - `test_shot_mechanics.gd:649-669` (roofing gradient) → re-pinned at the
    new gradient (~1.1 / 3.0 / 6.4 m @ 18 m/s).
  - `test_blade_lever_calibration.gd:148-167` (crossbar ceiling pinned for
    every curve) → new invariants: LOW's 8° apex stays under the bar at max
    power for every gear; the HIGH solve never targets above the cavity;
    toe caps ordered; quick-pass table gear-invariant.
- **New pins**: max honest `direction.y` < 0.75 across the gear × power ×
  level × distance grid; goalie over-bar gate; `is_puck_airborne` under the
  8° soft saucer; "position enters only via d" (two releases at equal d,
  different world positions, identical `ShotResult`).
- **Re-pins**: high-band reachability tests (`test_ai_action_scoring.gd:
  601-628` — both are statements about the deleted pace solve), beatability
  goal maps, shot-value calibration grid, slot truth, angle sweep (its
  documented arrival-height artefact disappears with the solve), butterfly
  arrival table, real-goalie outcome tables. The sweep deltas are the
  acceptance evidence for §5.3's retune.
- **Benchmarks**: `-gdir=res://benchmarks` before/after phase 2.

### 5.6 Docs to update at implementation

`docs/gameplay-design.md:25` (the loft paragraph — rewritten around contact
points and the solve), `ARCHITECTURE.md` elevation section,
`Scripts/domain/ai/CLAUDE.md` shot-danger bullet (arrival-honesty story
replaced by the clamp story), `Scripts/domain/state/CLAUDE.md` blade-curve
bullet, `player_attributes.gd` curve doc-block (face angle → toe cap),
`skater_controller.gd:595-610` doc-block, `docs/attributes-v4-plan.md` §5.2
superseded pointer. The "trajectory is never a function of position"
statements are amended, not deleted: position enters only as
distance-to-goal-plane.

### 5.7 Optional companion: the contact-point tell

If the level is where the puck sits on the blade, the carried puck can
visibly ride heel / mid / toe with the selected level (the scoop pose
already eases with level — `skater.gd:1169` — and the carry anchor exists).
A defender or goalie who watches the blade sees the toe carry and knows
upstairs is coming: honest, physical deception counterplay, and the
compensating read for `H`-determinism. Small, separable, user-testable —
proposed as a follow-up issue rather than part of the core rework.

## 6. Phasing

1. **Domain mechanics** — the solve + config fields, `PlayerAttributes` toe
   table/accessor, controller wiring (release-point → goal-plane distance),
   quick-pass path preservation, mechanics tests. Human-feel-testable
   immediately; bots mis-model their own shots until phase 2 (acceptable on
   the branch).
2. **AI** — delete the pace solve, clamp-based hole read at full pace,
   dump/clear hang re-derivation, airborne gate, calibration re-pins,
   benchmarks.
3. **Goalie + world** — over-bar gate, the high-game retune against the
   sweeps, net-stuck/behind-net feel check, (optional) crossbar corner arcs.
4. **Docs + drills audit + tuning** — tutorial HIGH prompts, accuracy-drill
   targets (LOW-calibrated, re-verify against 8°), per-gear cap tuning pass.

## 7. Open questions (for review before phase 1)

1. **θ_low = 8° vs 9°**: 8° (recommended) keeps LOW un-sailable at any
   charge, saucer apex drops 0.26 → ~0.21 m. 9° preserves today's saucer
   exactly but a full-charge LOW sails from 11–23 m — arguably a fair risk
   read on a chosen-elevation shot; it does reintroduce #363-style surprise.
2. **Toe caps 15° / 22° / 45°**: sets the roofing gradient at pace
   (~6.4 / 3.0 / 1.1 m @ 40 mph). Playtest lever.
3. **H = 1.05 m**: how tight under the cavity top (~1.18 m) the solve aims.
   Higher = sniping the paint under the bar; lower = safer margin off the
   goalie's glove arc.
4. **Goalie high-game retune scope** (§5.3): accept up-front that the
   set-keeper-shuts-the-top story changes, and the retune targets
   "hard but real" rather than restoring it.
5. **The contact-point tell** (§5.7): file as follow-up issue?

## 8. Out-of-scope flags (found while researching, not part of this rework)

- `test_shot_mechanics.gd:606-613` hard-codes closed = 23° "from
  PlayerAttributes._CURVE_FACE_ANGLE_DEG", but the shipped table is 26°
  (`player_attributes.gd:287`) — the test's local constants drifted from the
  table they claim to mirror (its 5.20 m pin is the 23° value; the shipped
  26° gives ~4.5 m, which is what the docs quote). Harmless today, but the
  pins misdocument the game. Moot for the sections this rework rewrites;
  flagged in case any survive.
- `docs/attributes-v4-plan.md` §5.2 likewise still reads 23°/5.2 m.
