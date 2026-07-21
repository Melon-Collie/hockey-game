# Attributes v4 — Body + Gear ("Your Hands Are You")

Design plan for the fourth iteration of the player build system. Replaces the
height + three-tier (Skating/Skill/Checking, one-strong-one-weak) model with
two permanent **body dials** (height, weight) and four lateral **gear slots**
(skate profile, blade curve, stick flex, stick length), plus a reworked
wrister release model (ROM-distance power gating) that the gear system keys
into. Designed in chat 2026-07-21; this document is the agreed plan per the
CLAUDE.md workflow — implementation sessions should treat it as the design of
record and ask before deviating.

Status: **steps 1–2 (§9 landing order) IMPLEMENTED** — step 1: the
height+weight body plane (plus the weight agility bite via the new
`lateral_grip` movement term, and frame-scaled hitbox width), gear slots
stubbed, prefs v5 migration, protocol v37, re-authored bot roster,
neutral-identity test. Step 2: the second-order blade servo (arrive-law
accel clamp, ships with `max_blade_accel = 0` = disabled — **the inertia
dial is turned in local playtest**), the lever derivation (tip speed ∝
lever, accel cap ∝ 1/lever^k, k export default 1.2), stick length as the
first live gear slot with its picker selector, and the two calibration
curves as GUT tests (traverse flatness ≤8%, reversal seesaw 1.15–1.8×
bounded and monotonic). §6 (wrister gate) landed separately on main.
Remaining: flex/curve gameplay, skate profile, AI/goalie calibration.
Numbers marked `TBD` are authored at implementation time and tuned in
playtest.

---

## 1. Constitution

Three lines, plus the corollary that generates them. Every future lever
proposal must answer "which category is this?" before it gets a table.

1. **Your body is permanent.** Height and weight — continuous, lateral dials.
   What you were born as. No power axis, no budget, no legality validation.
2. **Your gear is a choice.** Four slots, 2–3 discrete options each, every
   option a tradeoff shape with no net power. Swappable between matches,
   latched at puck drop. Visible on the model — opponents read your loadout
   by looking at you.
3. **Your hands are you.** No number in any table scales how faithfully the
   blade tracks the cursor. The skill ceiling of the game is the skill
   ceiling of the player. Mouse-driven blade IK is the one input scheme in
   sports games where this can be literally true, and it is the thing Mitts
   is about.

**The three-category taxonomy.** An attribute/gear lever may scale:

- **Outputs** — shot ceiling, mass, thrust, stamina. The avatar's body doing
  physics. Fair game.
- **Geometry** — reach, stick length, ROM, workspace, lever arm. The shape of
  the instrument the player's hands drive. Fair game: it changes what your
  hands work with, never how faithfully they're heard.
- **Fidelity** — how closely the blade tracks the cursor. **Never for sale.**
  A sub-1.0 hands multiplier is indistinguishable from input lag. (The v3
  `_HANDS` table — the widest table in the file, 0.85–1.24 — was a fidelity
  throttle wearing a stat costume, and is deleted by this design.)

**The input-bandwidth corollary.** Skills expressed through high-bandwidth
input (mouse: puckhandling, passing, shot placement, deflection aim) belong
entirely to the human and get no stat. Skills the input device cannot express
(WASD skating stride quality, slapshot charge) are legitimately
avatar-determined. v4 deliberately leaves skating ability and shot-power
ceiling as pure body+gear quantities — see §8 for the escape hatch.

---

## 2. Why v4 (one paragraph of history)

v3's tier system existed to police power: strong/weak was a zero-sum economy,
`is_legal_build` its cop, and meta-collapse (everyone takes strong Skating)
the crime it could not fully prevent. v4 deletes the power axis instead of
policing it: body dials are lateral (the v3 height dial already proved a free
continuous dial balances), gear is lateral by construction, and hands exit
the stat system entirely (returning to the attributes-1.0 philosophy). With
nothing granting power there is nothing to solve — a build can only be
optimal *for a playstyle*. Every earlier patch proposal (Checking stick/body
fork, Motor-as-fourth-attribute) is mooted by this design.

---

## 3. Body plane (permanent)

Two continuous dials. All-lateral: authored around the v3 *average-tier* rows,
so the multiplier spreads are the current height rows at tier=AVERAGE.
Neutral reference: **6'1" (H3), medium weight** — every multiplier 1.0,
identical to shipped `@export` defaults (same anchoring pattern as v3).

### 3.1 Height (unchanged mechanism, narrower scope)

Continuous in inches, 5'8"–6'7", 5 anchor rows + interpolation — the existing
`_anchor`/`_h`/`_ht` machinery survives as-is.

Keeps: reach / mesh scale / arm ROM (and via ROM, wrister runway
availability — §6), hitbox radius, speed↔agility baseline fork
(the v3 average-tier column: speed hump peaking at 6'1", agility
small-favored), hands↔shot baseline fork *for shot only* (average-tier
`_SHOT` column), stick-length **band center** (§5.4).

Loses to weight: stamina metabolism, mass.
Loses entirely: the `_HANDS` gameplay table (hands influence becomes
geometric — §4).

### 3.2 Weight (new dial)

**Frame-relative via a single BMI band** — one authored interval generates a
plausible pounds range at every height, so implausible bodies (6'6"/160,
BMI ~18.5) are unrepresentable by construction rather than by rule. Band:
**BMI 24.0 (LEAN) → 29.0 (HEAVY)**, five frame anchors interpolated with the
same machinery as height, neutral = 26.5 (the real NHL-average build:
6'1"/201). Displayed lbs = BMI × inches² / 703:

| height | LEAN 24.0 | LIGHT 25.25 | MEDIUM 26.5 | SOLID 27.75 | HEAVY 29.0 |
|--------|-----------|-------------|-------------|-------------|------------|
| 5'8"   | 158 | 166 | 174 | 183 | 191 |
| 5'10"  | 167 | 176 | 185 | 193 | 202 |
| 6'1"   | 182 | 191 | **201** | 210 | 220 |
| 6'4"   | 197 | 207 | 218 | 228 | 238 |
| 6'7"   | 213 | 224 | 235 | 246 | 257 |

Calibration namechecks: McDavid (6'1"/194) = lean-mid; Gaudreau ≈ small-
LIGHT; DeBrincat (5'8"/180) ≈ SOLID; Ovechkin (6'3"/238) = 6'4"-HEAVY
exactly; Chara between SOLID and HEAVY; Tage Thompson (6'6"/218) ≈
tall-LEAN. Floor 24.0 deliberately excludes rare sub-24 outliers; one
const if it ever widens.

**Storage**: weight in lbs (int) on the wire, like height in inches — the
identity stays human-readable and the bot roster reads like hockey cards.
Validation is `coerce_weight(height, lbs)` — a clamp into the band, never a
rejection (the `coerce_height` philosophy). Picker: a lbs slider bounded
for the current height; moving the height slider preserves the frame
fraction and recomputes lbs (a LEAN build stays lean as you grow).
Internally everything normalizes to frame-t for table lookups.

**Mass**: `mass_mult = lbs / 201` (linear in displayed weight), range
0.79–1.28 — a 1.63× spread vs v3's deliberate 1.16×. Intentional: v3 kept
mass minor because Checking carried physical battles; in v4 mass IS the
physical system. Escape hatch if it proves too swingy: compress with an
exponent (`(lbs/201)^p`, p ≤ 1) — physics gives the shape, playtest the
magnitude. Calibrate against `test_body_check_rules` so HEAVY delivers like
v3 strong-Checking and LEAN absorbs like v3 weak-Checking.

Routes (all shapes carried over from existing v3 tables, re-indexed by frame
instead of height/tier — values `TBD`, anchored to v3 spreads):

- **Mass** — absorbs and widens the v3 `_MASS` height table. Feeds check
  delivery and brace through the existing collision resolver
  (`SkaterCollisionRules` reduced-mass math) — checking becomes
  body-emergent, no Checking stat. The v3 `_DELIVERY`/`_BRACE` tables die;
  their felt spread should be reproduced by the mass spread + closing speed,
  which the resolver already folds in. Delivery/brace spread target: a heavy
  frame hits like v3 H5-strong-Checking, a lean frame absorbs like v3
  weak-Checking — verify against `test_body_check_rules` expectations.
- **Accel ↔ momentum** — lean = first-step burst (v3 `_ACCEL` small-favored
  shape), heavy = holds speed through contact (momentum is mass-emergent; do
  not add a separate "momentum" table).
- **Agility bite** (`_AGILITY_F`, lean-favored, multiplies the height
  baseline) — F = mv²/r: heavy turns wide and stops long. This is the
  counterweight that makes the dial a real seesaw (mass 1.28 is a big buy;
  accel alone was too mild a tax). Corner budget (body-only): best 5'8"-lean
  ≈ 1.08, worst 6'7"-heavy ≈ 0.89 — re-check stacked corners when the
  skate-profile gear lean lands. **Glide is exempt**: `agility_glide_mult`
  derives from the height-only agility component, so the tank turns wide but
  still coasts like his mass says he should (top speed also stays
  weight-free — cruise is power-vs-drag, and "holds speed through contact"
  already emerges from mass in the resolver). **Mechanism** (implemented):
  agility scales `lateral_grip` — the movement core decomposes thrust
  against the current motion and scales only the perpendicular component
  (`SkaterMovementRules`, grip 1.0 = exact no-op, standing starts exempt) —
  so the emergent turn radius v²/(grip·a_perp) genuinely widens/tightens
  with the build; facing/brake scaling is the *feel* of quickness, grip is
  the arc itself.
- **Hitbox width** (`_RADIUS_F`) — the radius tracks the visual frame bulk:
  same height, heavier = wider (bigger poke target and net-front screen).
- **Stamina fork** — moves off height: lean = shallow pool / fast regen,
  heavy = deep pool / slow regen (the existing `_STAMINA_DRAIN`/`_STAMINA_REGEN`
  shapes, re-indexed by frame).

### 3.3 Visual tells

Silhouette = body: height drives overall scale + torso/head (existing
tables); weight drives uniform bulk (replaces the per-tier limb tells —
`_THIGH`/`_FOREARM_BULK`/`_SHOULDER_BULK` etc. are deleted or re-indexed by
frame). Gear = rendered equipment: stick length and blade curve are literally
visible on the stick mesh; skate profile and flex get subtler tells (`TBD`,
nice-to-have). The tells become *more* honest than v3: body reads from
silhouette, gear reads from the equipment itself.

---

## 4. The hands system (no hands stat)

`max_blade_speed` stops being an authored stat and becomes **derived from
lever geometry**. The old velocity-cap model never actually differentiated
what "hands" means — a pure velocity cap lets direction reverse instantly, so
v3's widest table was scaling traverse speed while the felt meaning of hands
(reversal quickness, the toe-drag snap) was uniform for everyone.

**Model.** Effective lever `L` = reach (height) × stick-length gear lean.
The blade is a second-order servo chasing the cursor with two caps:

- **Tip-speed cap** `v_max ∝ L` — long lever sweeps faster in m/s. Feeds
  coverage, and blade momentum (`∝ v`) into stick contests: pokes, contested
  pickups, faceoff draws. The sweeping defenseman poke is emergent.
- **Acceleration cap** `a_max ∝ 1/L^k`, `k` a feel tunable in `[1, 2]`
  (raw physics says k=2; reversal time then scales ~L³ across the range,
  which is too brutal — start low, widen only if builds feel samey). Short
  lever = snappy reversals = the dangler. Long lever cannot cut back — which
  is also what keeps long sticks from winning in-tight battles.

**Feel guardrails (non-negotiable):**

1. **Neutral bit-identical**: 6'1" + standard stick reproduces current blade
   behavior exactly. Implement the accel clamp with a value that never binds,
   verify unchanged feel in local testing, then dial in.
2. **No overshoot / no springiness**: clamped-accel or critically damped
   only. The blade must never oscillate past the cursor.
3. **Caps bind only at extremes**: ordinary handling motions must never
   touch either cap on any build. Initial reversal-time spread target: ±10%.

**What replaces the old Hands consumers:**

- Backhand penalty → flat mechanic (the existing 0.75 controller coeff;
  modified only by blade-curve gear, §5.2).
- `carry_speed_mult` → drop the Hands term; keep the Speed term or flatten
  (`TBD` — the real carry cost is the 1.6× sprint drain either way).
- Contests → already read blade velocity; now read the lever-derived value.
  No attribute term, preserving the "contests are emergent" doctrine — and
  purer than v3, since blade speed no longer encodes a bought stat.
- Bots → a bot's "hands" are its control policy (as its skating is), not a
  multiplier humans can't have.

**Fix-by-geometry-only rule**: if playtests show e.g. tall-heavy builds
dangling like Kane and it feels wrong, the fix is more honest geometry
(blade inertia term, lever mass) — never a fidelity table. This is the only
tool in the box, by constitution.

---

## 5. Gear (lateral, discrete, visible)

Four slots × 3 options = 81 loadouts on the body plane. Options are
**discrete and chunky** (like the loft levels), never sliders — legibility
for the picker and for opponents. Everything available day one; no unlocks,
ever. Loadout latched at puck drop like the build. (Between-periods stick
swap is thinkable for v2 — real players do it — but out of scope.)

Rule: a gear option may **reshape a tradeoff curve on a mechanic**; it may
never scalar-multiply an attribute lever with a net-positive total. No
tooltip contains a bare "+".

### 5.1 Skate profile — top-end vs. burst

- **Power**: +top speed / glide, −agility (turn/brake/grip).
- **Balanced**: neutral (≡ shipped defaults).
- **Agility**: +acceleration / first step / cornering, −top speed.

The cornering lever this slot needs **already exists**: `lateral_grip`
(perpendicular thrust authority in `SkaterMovementRules`, added with the
weight agility bite) — the profile lean multiplies it alongside
glide/top-speed, no new mechanism required. Re-check the stacked
body × gear grip corners here (see §3.2 corner budget).

The first step is deliberately assigned to the *agility* profile (rockered
blade = quick starts and cuts; long flat = glide and top end). This is both
the physical truth and the balance fix: as first drafted, power got two goods
(+speed +accel) for one bad and would have been the default pick in a game
where speed is the perennial meta suspect. Stacks with height's speed/agi
fork — the tuning corners are height-extreme × matching lean; check
6'1"+power (fastest thing in the game) and 5'8"+agility (shiftiest)
deliberately.

### 5.2 Blade curve — elevation & release vs. backhand

- **Open**: easier elevation on FLAT/LOW loft (steeper `loft_vertical_speed`
  for the saucer and mid-net game), quicker release (shorter ROM runway —
  §6), worst backhand (deepens the backhand coeff penalty).
- **Balanced**: neutral.
- **Closed**: hardest to elevate, medium release, best backhand (relaxes the
  backhand penalty toward — never past — forehand parity).

**Crossbar constraint (hard)**: HIGH loft's apex ceiling (puck top ~5 cm
under the crossbar's inner edge) is pinned **for every curve**. Open face
may reach that apex *sooner* (steeper arc, shorter distance-to-apex), never
higher. The no-sail guarantee is load-bearing shot feel and survives v4
untouched. → calibration test, §7.

### 5.3 Stick flex — power ceiling vs. release

- **High (stiff)**: +shot power ceiling (wrister + slapper), longer ROM
  runway and slapper wind-up.
- **Medium**: neutral.
- **Low (whippy)**: −power ceiling, shortest runway / fastest wind-up.

Terminology is real-hockey correct (high flex number = stiffer). This slot
rides the coupling the codebase already encodes — slapper wind-up is derived
as `2 − shot_power` so the pair can't drift; flex is a player-facing dial on
that exact curve. Cheapest slot to build. Makes the one-timer spectrum real:
stiff = the wound-up bomb, whippy = the snap one-timer at less pace.

### 5.4 Stick length — sweep vs. snap (the flagship)

- **Long**: +reach / poke radius / tip speed / contest momentum, +inertia
  (slowest reversal).
- **Standard**: neutral (band center set by height — real sticks are cut to
  the body, so this is a *lean* on your height's reach, not a stack).
- **Short**: −reach, snappiest reversal, finest close control.

This is the slot that carries the entire hands identity (§4) — the only
place hands-adjacent choice lives, and the most feel-differentiated slot of
the four. **Build it first.** The reach payoff must be paid for honestly:
reach is the closest thing the game has to raw power (poke radius, IK
coverage, interception), so the inertia and close-control costs of Long must
genuinely bite, and the band is height-relative precisely so max-height +
max-length can't stack absolute reach beyond tuning.

---

## 6. Wrister release model — ROM-distance power gating

**IMPLEMENTED** (main, "Travel-gated wrister ceiling", 2026-07 — designed
separately; recorded here because the gear release levers cash out in it).
As shipped:

Power t = `min(speed_t, wrister_travel_cap_t)` (`ShotMechanics`):

- `speed_t` — the pure mouse-speed model, unchanged. Soft and medium shots
  never hit the ceiling, so the touch game (the reason v3 moved off
  distance) is computed identically to the ungated model.
- `wrister_travel_cap_t` = `clamp(stroke_travel / full_stroke_travel,
  travel_cap_floor, 1.0)` — `stroke_travel` is the stroke's world-space
  blade XZ path length (meters, `ChargeTracking`, variance-break reset,
  per-tick step bounded so forged cursor teleports can't buy the arc).
  Body-space, so DPI/sensitivity/zoom can't buy the ceiling. Floor is 0.4
  of the band (the instant flick-pass / snap tier).

**The gear hook is already open**: `wrister_full_stroke_travel` (@export,
1.0 m base) is rescaled in `apply_attributes` by the build's own sweep
radius (stick length + arm ROM), so height/length set how much ROM you
*have* and the reference stays fair across frames. Blade curve (open) and
stick flex (low) become a per-loadout multiplier on the captured base —
"max power release with less real estate consumed"; stiff flex extends it.
One physical currency, one multiply per slot.

**Evidence economy.** A full-power shot must now emit a tell — a visible
loading gesture the blade pose and per-tick `shot_charge` ramp broadcast and
the goalie's windup-prime read keys on. Quick-release gear beats the goalie
by emitting *less evidence*, not by a stat check. Consequences:

- `shot_charge` (release-now prediction) genuinely ramps through the drag —
  the diegetic stick-flex pose becomes a truthful gauge, matching the
  slapshot philosophy.
- **Runway floor (hard)**: the minimum stacked runway (open + whippy) must
  still be long enough that a max-power release emits a readable tell inside
  the goalie model's calibrated reaction band. → calibration test, §7.
- Bot gesture synthesis: bots **bypass the gate** (stroke_travel = INF —
  their committed power fraction is the whole gesture, wind-up cosmetic),
  so the inverse needs no runway term. Gear for bots therefore only enters
  through the levers bots do use (power ceiling, wind-up time, elevation) —
  simpler than the pre-implementation plan assumed.

---

## 7. Calibration constraints (acceptance tests)

Write these as GUT tests with the feature; they are the design's contract.

1. **Neutral identity**: 6'1" / medium frame / all-balanced gear reproduces
   every shipped `@export` default and current blade behavior exactly.
2. **Crossbar ceiling**: HIGH-loft apex stays under the crossbar's inner
   edge for every curve × flex × power combination.
3. **Runway floor**: min stacked runway ≥ the goalie-readable tell window;
   total release-time band (curve × flex extremes) stays inside the band the
   goalie reaction/prime model is calibrated for (or that model is
   re-calibrated in the same change).
4. **Traverse-time flatness**: time for the blade to cross its own reach
   envelope is ~constant across all heights × stick lengths (the fidelity
   guarantee, stated as an assertion).
5. **Reversal-time seesaw**: blade reversal time varies monotonically with
   lever and stays inside the authored spread (±10% initial) — the tradeoff
   can never silently become a throttle.
6. **Lateral-purity spot checks**: no gear option strictly dominates its
   slot under the AI's own EV models (e.g. `AIActionScoring` shot EV should
   not prefer one flex in all situations).

---

## 8. Deliberately left on the table

- **Skating ability & shot-power ceiling as trained skills.** Same body +
  same gear = identical ceilings (the McDavid/Wotherspoon question). Kept
  off the table by the bandwidth corollary and the Rocket-League argument:
  in PvP, the difference between two players *is the human*. **Escape
  hatch** if playtests demand it: one lateral training-focus seesaw
  (skater-lean / balanced / shooter-lean), zero-sum between exactly these
  two outputs — never a return of tiers. **Trigger signal**: players saying
  "I picked my height for the speed, not the height."
- **Hands stat** — never returns, by constitution. Fix-by-geometry only.
- **Checking stat** — body-emergent (mass + closing speed through the
  existing resolver). The v3-era stick-strength fork proposal is moot: the
  lever model gives the big frame the sweeping poke and the small frame the
  in-tight snap emergently.
- **Stat-gear / unlock progression / a fifth slot** — rejected; see the
  slot rule in §5.
- **Cosmetics** (tape color, helmet, sock stripes) — orthogonal, zero
  balance cost, ship whenever.

---

## 9. Migration & implementation seams

Big-ticket items an implementation session must plan around; order roughly
bottom-up.

- **`PlayerAttributes` rework**: state becomes `{height, frame, profile,
  curve, flex, length}` (6 ints). Table machinery (`_anchor`/`_h`
  interpolation) survives; tier tables deleted or re-indexed per §3. Named
  accessors stay the only public surface. `is_legal_build` collapses to
  range checks (no shape economy to validate).
- **Prefs migration v5** (`attr_scale_version`): deterministic map from v4
  saves — height carries over; frame defaults medium; gear synthesized from
  tiers (proposal: strong Skating → agility profile, strong Skill →
  open curve or short stick by height, strong Checking → long stick;
  weak tiers → the opposing lean; all-average → all-balanced). Exact map
  `TBD` at implementation, but must be deterministic and documented in the
  migration function.
- **Protocol bump** (v36+): join payload 4 ints → 6; host validation =
  range checks.
- **`bot_identities.json` re-authoring**: each bot gets `{height, frame,
  profile, curve, flex, length}` — the roster gets *more* colorful
  ("Pohl: 6'7", 232 lbs, plank flex, long stick").
- **Blade servo** (§4): second-order with accel clamp; deterministic pure
  function of cursor input so reconcile replay is unaffected; cheap enough
  for 120 Hz × actors (a clamp, no allocation).
- **Wrister model** (§6): **already on main** (travel-gated ceiling). Gear
  work is a per-loadout multiplier on `_base_wrister_full_stroke_travel`
  (flex/curve) applied in `apply_attributes`; bots bypass the gate, no
  inverse change needed.
- **AI reads**: `AIActionScoring` shot/pass EV consumes per-player release
  time and elevation ease instead of assuming neutral (grounded-model rule:
  the AI sees the real quantities).
- **Goalie calibration**: verify/extend the reaction + windup-prime bands
  against the new release-time range (§7.3).
- **Picker rebuild**: two sliders (height, frame) + four 3-way gear
  selectors; presets keep working; legality UI simplifies away.
- **Visual**: weight-driven bulk replaces tier limb tells; stick mesh
  renders length + curve — the curve seam **already exists**:
  `StickBladeMeshBuilder.Params` (curve_depth / curve_start_frac /
  toe_round_frac, on main) declares itself the gear hook; open/closed
  curves are a Params preset per option.

Suggested landing order: (1) body-plane rework with gear slots stubbed at
balanced (neutral-identity test green end-to-end, protocol + prefs + bots
migrated), (2) blade servo + stick length, (3) wrister ROM model + flex +
curve, (4) skate profile, (5) AI/goalie calibration pass.

---

## 10. Open questions (user decides before implementation)

1. ~~Frame band width~~ — RESOLVED: single BMI band 24.0–29.0, see §3.2.
2. Starting `k` for the inertia exponent, and the initial reversal spread.
3. Runway numbers: ceiling ramp floor (~60%?), neutral runway length in ROM
   terms, and the compress/extend deltas per gear option.
4. Naming: "blade curve" vs "blade profile"; "power/agility" vs real
   profile jargon.
5. Whether closed curve's backhand relief approaches forehand parity or
   stops well short.
6. v2 candidates to keep visible: between-periods stick swap; training-focus
   seesaw (only on its trigger signal); cosmetics pipeline.
