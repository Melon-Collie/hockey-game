# Elevation Rework — Design Doc (issue #585)

Status: **agreed design, v3 (manual angle ladder)** — implementation follows
the CLAUDE.md workflow: this doc is the plan; deviations get discussed first.
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
| 1 LOW (mid-blade) | 7 | 8 | 8.5 |
| 2 MID (toe-side) | 15.5 | 17.5 | 19 |
| 3 HIGH (toe) | 21 | 24 | 28 |

(Retuned from the original 14/15/16 MID and 22/26/30 HIGH: HIGH came down a
touch and MID up to chase its band end, collapsing the "awkward middle" dead
ring just outside the doorstep to slivers that fill at honest pace. Costs:
doorstep floors moved out to ~2.24/1.93/1.62 m, and M92's mid-range gap
(~4.0–8.5 m) fills at slightly softer MID pace.)

Top-shelf bands at full wrister charge (33 m/s), over-the-bar beyond them:

| level | M88 | M92 | M28 |
|---|---|---|---|
| LOW | ~0.8–0.9 m arrival from the point — **never sails** (max-slap apex ~1.23 m = iron at worst) | ~13–21 m: the textbook point snipe | ~10–14 m; clips iron beyond ~14 |
| MID | ~3.3–4.6 m (and from range at slapper pace) | ~2.9–4.0 m | ~2.6–3.6 m |
| HIGH | ~2.3–3.2 m | ~2.0–2.7 m | ~1.7–2.3 m |

Backing off the charge slides every band toward the net; each blade's HIGH is
a distinct "roof pocket" rather than strictly better/worse. The identities:

- **M88** — the flattest ladder: physically cannot put a puck over the glass
  (its worst outcome is a crossbar ping), cannot roof the true doorstep.
  The safe blade. No clamp needed — the safety emerges from the table.
- **M92** — the all-rounder owns the textbook top-shelf point snipe (LOW 8°).
- **M28** — the steepest ladder at every rung: the only blade that roofs from
  the crease at pace (30° from 2 m arrives ~1.13 m), and the worst at range
  (every band sits closest to the net; LOW clips the bar from the deep
  point). The close-range weapon.

Consequences accepted deliberately:

- **A max-charge point slapper at LOW sails for M92/M28** — the fully-wound
  point bomb wants FLAT or an eased charge. Elevation at max power is the
  risky choice; that's the language of the whole model.
- **A mastered player still hits a learned band from a clean look.** Manual
  elevation makes sniping earned and self-punishing under pressure; if
  static-look snipes remain too free after playtest, the goalie's high game
  (pre-arm read of the visible toe carry) returns as a *complement*, not a
  competing design.
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
   still feel free.
3. The contact-point visual tell (puck rides heel→toe) — replaces chevrons
   eventually, makes the level readable to the defense.
4. Crossbar corner-arc collision if not done in this pass.
5. Docs pass: gameplay-design.md, ARCHITECTURE.md elevation + deflect
   sections, area CLAUDE.mds, tutorial/drill audit (tutorial steps reference
   LOW tips / HIGH lobs — remap to the new modes).

## 7. Out-of-scope flags (carried from earlier phases)

- `docs/attributes-v4-plan.md` §5.2 still describes the 23°/5.2 m face-angle
  model (twice superseded).
