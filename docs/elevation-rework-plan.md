# Elevation Rework — Design Doc (issue #585)

Status: **v3 (manual angle ladder) IMPLEMENTED** — the §1 ladder values are
the live playtest tuning surface.
Supersedes the elevation half of `docs/attributes-v4-plan.md` §5.2.

Version history (full writeups in git):
- **v1** — power-scaled vertical speed with per-gear lift ceilings. Set aside:
  it still derived height from speed, when the real-life controlled variable
  is launch angle.
- **v2** — the adaptive solve (HIGH auto-arrives top-shelf at the faced goal
  plane, clamped by a per-gear toe cap). Implemented through the AI layer,
  then set aside after playtest: with the vertical axis solved and cursor aim
  absolute, an open corner is a deposit, not a contest — "sniping corners
  left and right." The calibration skill belongs to the PLAYER.
- **v3 (this doc)** — four manual levels, per-gear set-angle ladders, missing
  high as a real outcome, and the levels doubling as deflect modes.
- **v3.1 (2026-08 re-spacing)** — the model is unchanged; the ladder VALUES
  were re-derived. Playtest reported "always shooting one tick of elevation,
  not a lot of opportunities to roof it," and the arithmetic agreed: past
  ~4.5 m LOW was the only rung still under the bar at full pace, so the level
  was not a live choice anywhere real shots come from.
- **v3.2 (2026-08 posture vocabulary — CURRENT)** — v3.1 aimed every rung at
  the STANDING pad seam (0.86 m), which is the wrong target: "over the pads"
  in play means over the LEG pads with the keeper in butterfly, and those top
  out at 0.28 m. Re-anchored so **the level names the SHOT and the gear names
  the RANGE** — each level clears a goalie-posture landmark, each gear places
  the same three shots at its own home range. See §1 and §1.1.

All constants below are STARTING VALUES for playtest tuning; the shapes and
invariants are the design.

## 1. The model — a ladder of contact points, no solve

Elevation is a player-selected LOFT LEVEL (scroll, 0–3), fictionalized as the
contact point on the blade (heel → toe). Each level is a **set launch angle**
from the gear's ladder — no target-height solve, no position input, no
vertical-speed caps. Arrival height is emergent from angle × charge × range,
and **missing high is the price of greed**: the player is the calibrated
shooter now, or isn't yet.

Per-gear ladders (degrees; tan enters the release math):

| level (contact) | M88 | M92 | M28 |
|---|---|---|---|
| 0 FLAT (heel) | 0 | 0 | 0 |
| 1 LOW (mid-blade) | 5.0 | 5.5 | 6.4 |
| 2 MID (toe-side) | 6.9 | 8.2 | 10.0 |
| 3 HIGH (toe) | 8.9 | 11.0 | 13.6 |

**The level names the SHOT; the gear names the RANGE.** Every level targets a
goalie-posture landmark — absolute heights off the ice, from `GoalieAnatomy`'s
equipment boxes, not fractions of the net:

| level | target | what it beats |
|---|---|---|
| FLAT | ice | five-hole on a standing keeper; through traffic for tips |
| LOW | 0.41 m | over the butterfly pad (0.28), **under** his hands (0.49) |
| MID | 0.70 m | the armpit — **over** his committed hands, under the seam |
| HIGH | 0.99 m | upstairs — over the standing pad seam (0.86), under the bar |

and each gear places those same three shots at its own HOME RANGE:

| gear | home | identity |
|---|---|---|
| M88 | 8.5 m | the range blade — peaks in the high slot / long range |
| M92 | 6.0 m | the all-rounder — three shots from the slot out to long range |
| M28 | 4.5 m | the close blade — peaks in the slot, owns the crease |

Distinct shots available per zone (counting FLAT), which is the design target
"great in your range, competent one range away":

| gear | Crease 0–3 | Slot 3–6 | High Slot 6–9 | Long 9–12 | Point 12+ |
|---|---|---|---|---|---|
| M28 | 2 | **4** | 3 | 2 | 2 |
| M92 | 2 | 3 | 3 | 3 | 2 |
| M88 | 2 | 3 | **4** | **4** | 2 |

Consequences accepted deliberately:

- **Nobody roofs the 2 m doorstep**, and that is the right shape: at the crease
  the shot you want is over the *butterfly* pad, and the M28 delivers exactly
  that (MID 0.34 m, HIGH 0.47 m, both clearing the 0.28 m pad). The crease
  does not need the top half of the net.
- **The point is a put-it-on-net zone, not a menu zone.** Every gear has two
  shots there. The whole cavity is a ~3.4° window at 19 m (§1.1), so no ladder
  could do better.
- **A weak build's M88 LOW lands under the pad** (0.26 m) — the one cell in
  the whole build × gear × rung × shot-type matrix that loses a shot. The
  range blade in the hands of the body least suited to it; accepted rather
  than distorting the anchor.
- **Missing high is still real** — a rung fired two zones past its home sails
  (M28 MID from 9 m arrives 1.21 m). What changed is that greed is now a
  rung-vs-range mistake rather than a power mistake.

## 1.1 Why the rungs are anchored to posture and zone

Three structural facts set what any set-angle ladder can do. All three are
consequences of arrival ≈ `d·tan θ − (g d²/2v²)·sec² θ`.

1. **The angular budget spanning the whole net shrinks as ~1/d** — 29° at 2 m,
   10.7° at 6 m, **3.4° at the point**. So the number of distinct shot types
   that can exist at a distance is set by physics, not tuning: many in tight,
   essentially one at range. This is why a gear must own a zone, and why the
   point gets no menu.
2. **Build variance lives entirely in the gravity drop** (`~d²/v²`). The ±17%
   shot-power spread moves arrival by ±60 cm when a band sits at 15–22 m, but
   only ±3–12 cm at these 4.5–8.5 m home ranges. Anchoring the fans close in
   made the system build-tolerant as a side effect — which is why no power
   normalization is applied, and why builds change your shot without ruining
   it. Same reason the SLAPPER needs no separate ladder: its extra pace costs
   ~5 cm of drop at home range, so the rungs ride one notch higher and the
   level still means what it means.
3. **A rung is widest when its apex lands in the target band**, since the arc
   then cruises that height over a long run of distance rather than slicing
   through it. This is what made v3's 8° LOW a "god rung" against the standing
   seam, and it is why v3.1's ladders — all aimed at that same seam — still
   collapsed to one useful rung per gear.

What v3.2 fixes over v3.1 is the TARGET, not the spacing. v3.1 aimed every
rung at the standing pad seam (0.86 m). But the keeper is in butterfly for
most in-tight shots, and his leg pads then top out at **0.28 m** — the pad box
is 0.28 m wide (11", the real NHL spec) and rolls flat, which
`GoalieAnatomy.BUTTERFLY_PAD_HALF_WIDTH_M` (0.42 = half the 0.84 long axis)
confirms. So the shot players actually take — over the pad, under or over the
hands — sat *below* every rung v3.1 authored, and the 0.40–0.85 m band that
v3.1 dismissed as "the keeper's chest" is in fact the armpit seam, which
`AIActionScoring` already models as opening when a hand is committed low.
- Nothing in the ladder approaches 45°, so `ShotMechanics.MAX_LOFT_RATIO`
  becomes a pure anti-forgery guard and the host clamp headroom widens.
- The flip clear is the steepest rung at soft pace — no special case.

Quick passes are UNCHANGED: the fixed vertical-speed table (LOW 2.2 = the
saucer, MID/HIGH 4.65 = the flip) — pass mechanics stay calibrated and
position-free, per v2's reasoning (the original adaptive system died on
passes; the pass/shot split is a hard input split).

## 2. Wire and input

Four levels fit the existing 2-bit elevation field (0..3) — no codec layout
change. `ShotMechanics` renumbers: FLAT 0, LOW 1, **MID 2 (new)**, HIGH 3;
`InputState.MAX_ELEVATION_LEVEL` follows. PROTOCOL_VERSION bumps anyway:
mixed-version peers would simulate different arcs from identical inputs.

## 3. The levels double as DEFLECT MODES

The old deflect model picked up-vs-down by blade-vs-puck geometry at HIGH
(the "fiddly based on position thing"). Four levels carry the intent
explicitly — the level names the deflection you're playing for, and the
blade's lift height follows the level:

| level | blade lift (pivot) | deflect intent |
|---|---|---|
| FLAT | on the ice | ground puck stays on the ground (redirect along the ice) |
| LOW | on the ice | ground puck deflects UP — the money tip |
| MID | ~0.35 m | airborne puck deflects UP — roof the rising shot |
| HIGH | ~0.52 m (current `blade_lift_height`) | airborne puck bats DOWN — the high-feed knockdown at the net mouth |

- The up/down sign comes from the LEVEL, not from `puck_y − blade_y`; the
  geometry deadband dies. Deliberate and natural deflects still run the same
  physics (`PuckCollisionRules.deflect_velocity` decomposition unchanged);
  only the loft-sign selection (`deflect_loft_speed`) changes.
- Reach planes: FLAT/LOW play the ice; MID plays the low air (~0.35 pivot);
  HIGH plays the high air (~0.52 pivot, reaching ~1.05) — still the
  stick-lift gesture level.
- Anti-cheese check: a saucer pass apexes ~0.21–0.26 m, still under MID's
  0.35 m pivot — camping MID can't cheese saucers (marginally; verify in the
  deflect tests).
- Bot tipper (finisher): shooter FLAT → tipper LOW (lift it); shooter
  elevated → tipper HIGH (reach the high feed, bat it down at the mouth) —
  same blade heights as the old behavior, now with explicit intent.

## 4. HUD

Chevrons go to three (LOW 1 / MID 2 / HIGH 3, FLAT none) in the existing
style. Noted for later: at four levels the chevron readout is at its limit —
a proper elevation indicator (e.g. the contact-point tell: the carried puck
visibly riding heel→toe) is the eventual replacement.

## 5. Knock-ons (delta from the v2 implementation)

### 5.1 Release math (`ShotMechanics`)

`shot_loft_y` becomes a ladder lookup: `(level, tan_low, tan_mid, tan_high)`
→ y ratio, clamped by `MAX_LOFT_RATIO`. Power no longer enters (set angles);
`dist_to_goal_plane`, the target height, and the LOW vy ceiling are deleted —
**trajectory is again a pure function of (level, gear), position-free.**
Configs carry the three tans; `PlayerAttributes` gains the three `_CURVE_LOFT_*_DEG`
tables + accessors (replacing the toe-cap table); `SkaterController.apply_attributes`
wires them. GameRules keeps M92's ladder as the league defaults.

### 5.2 AI (`action_scoring`)

The bot becomes a RUNG-PICKER: for a HIGH-band hole, iterate its three
elevated rungs, keep those whose full-pace arrival at the net lands in
[pad-top seam, cavity top ≈ 1.18] (and clears a standing keeper's paddle at
his plane; a down goalie's paddle stays no bar), and take the highest legal
arrival. The chosen rung IS `best_shot_loft`'s answer for that hole (the
`HOLE_BAND_LOFT` constant dies); no legal rung → band structurally closed.
Bots still fire full pace; `AISkaterCaps`/`RoleContext` thread the ladder
(three tans) instead of one toe cap. Note the point snipe: from 13–21 m the
legal rung is LOW — the bot's top-shelf shot from range rides the mid-blade,
exactly like the human's.

### 5.3 Deflects (`PuckCollisionRules` / `Puck` / controller)

`deflect_loft_speed` signs by level (§3); blade lift maps FLAT/LOW → ice,
MID → 0.35, HIGH → `blade_lift_height`; the scoop pose scales `level / 3`.
Deflect calibration tests re-pinned to the mode table.

### 5.4 Unchanged from v2

Over-bar physics (crossbar/top-panel/behind-net) is live code; goal detection
already rejects above-cavity; shot-on-net margins already classify over-bar.
The crossbar crown/post-span corner gap (0.815 vs 0.915) is HOT again now
that launched shots can cross above the bar near the posts — model the
corner arcs this phase or next. The goalie over-bar reaction gate (§v2 5.3)
still wanted: he must not save pucks that were sailing.

### 5.5 Tests

Ladder tests replace the solve tests in `test_shot_mechanics` (per-gear
rungs, band arithmetic at fixed charge, never-sail M88, host-clamp grid);
blade-lever calibration pins ladder ordering per rung; rung-picker tests in
`test_ai_action_scoring`; deflect-mode tests in `test_puck_collision_rules`;
AI calibration suites re-pinned (the parked pending in
`test_real_goalie_shot_outcomes` stays parked until the goalie high-game
pass). Benchmarks after (rung iteration is 3× the v2 solve — still trivial).

## 6. Open items after this lands

1. Playtest the ladder values (§1 table is the tuning surface).
2. The goalie high-game complement (pre-arm read) if mastered static snipes
   still feel free — issue #597.
3. The contact-point visual tell — LANDED, reworked after playtest to the
   wind-up-only, blade-moves form (`Skater._aim_seat_offset_u`, issue #596):
   during a wrister wind-up the BLADE seats the frozen puck heel→toe per the
   level (mesh channel; the puck never leaves the cursor), joined by a toe
   drag that rolls the face closed over the puck. A plain carry shows no
   seat — the read matters when a shooter has committed, which is also when
   the goalie pre-arm will consume it. The chevrons still ship alongside;
   whether they shrink to a local-only affordance or retire outright is a
   playtest call now that the level is readable off a wound-up blade.
4. Crossbar corner-arc collision + drill-target audit — issue #598.
