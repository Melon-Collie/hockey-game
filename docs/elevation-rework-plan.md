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
  was not a live choice anywhere real shots come from. See §1.1.

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
| 1 LOW (mid-blade) | 7 | 8 | 10 |
| 2 MID (toe-side) | 9.5 | 11 | 13.5 |
| 3 HIGH (toe) | 13 | 15.5 | 20 |

Top-shelf bands at full wrister charge (33 m/s), over-the-bar beyond them
(the roof window is arrival in [0.86, 1.18] — the goalie pad seam to the
scoring cavity's top):

| level | M88 | M92 | M28 |
|---|---|---|---|
| LOW | **never roofs** (apex 0.83 m) and **never sails** (max-slap apex 1.21 m = iron at worst) | 8.5–22 m: the textbook point snipe, and still cannot sail on a wrister | 5.8–8.7 m |
| MID | 6.2–9.6 m | 5.0–7.4 m | 3.9–5.5 m |
| HIGH | 4.1–5.8 m | 3.3–4.6 m | 2.5–3.4 m |

Backing off the charge slides every band toward the net. The identities:

- **M88** — the safe blade. Its top shelf lives at 4–9.6 m and it has none
  past that: LOW's 7° apexes under the pad seam, so from the point it is a
  low shot for tips and rebounds. That flatness IS the safety — the same 7°
  keeps a max slapper at crossbar-ping height, so the blade cannot put a puck
  over the glass on any rung it can reach the point with. No clamp needed;
  the property emerges from the table.
- **M92** — the all-rounder, and the only ladder spanning both ends: LOW is
  the textbook point snipe (8.5–22 m), MID owns the slot, HIGH the 3.3–4.6 m
  range. One sliver at ~8 m, which fills off MID at ~27 m/s (0.30 s flight —
  a shot the keeper must still respect).
- **M28** — the steepest ladder at every rung: the close-range weapon, owning
  2.5–8.7 m across its three rungs, with no top shelf from the point at any
  credible pace. The worst at range, as before.

Consequences accepted deliberately:

- **Nobody roofs the 2 m doorstep.** Reserving a rung for the crease is what
  cost every blade its slot elevation, and the doorstep is a rare enough look
  that the trade is worth reversing. The steepest rung in the game (M28 HIGH)
  now arrives ~0.71 m from 2 m — mid-net.
- **A max-charge point slapper at LOW sails for M92/M28** — the fully-wound
  point bomb wants FLAT or an eased charge. Elevation at max power is the
  risky choice; that's the language of the whole model.
- **A mastered player still hits a learned band from a clean look.** Manual
  elevation makes sniping earned and self-punishing under pressure; if
  static-look snipes remain too free after playtest, the goalie's high game
  (pre-arm read of the visible toe carry) returns as a *complement*, not a
  competing design.

## 1.1 Why the rungs are spaced by roof DISTANCE, not by even angle steps

A set angle's arrival is ~`d·tan(angle)`, so the distance a rung tops the
shelf from goes as `1/tan`. Even steps in angle are therefore geometric steps
in distance *the wrong way round*: the v3 ladder's three rungs (8/17.5/24 on
the M92) roofed from ~15 m, ~3.5 m and ~2.4 m — two of the three rungs landed
inside 4 m of ice while everything from 4 to 8.5 m had no rung at all. That
gap is the slot. Playtest felt it as "always one tick": past ~4.5 m at full
pace, MID and HIGH both sailed, so LOW was the only legal rung anywhere real
shots come from, and LOW arrives 0.6–0.8 m there — the keeper's chest.

Two structural facts set what any ladder can do:

1. **A rung is wide exactly when its apex lands in the roof window.** apex =
   `(v·sin θ)² / 2g`, so apex ∈ [0.86, 1.18] means `v·sin θ` ∈ [4.11, 4.81].
   At 33 m/s that is only **7.2°–8.4°** — which is why the M92's 8° LOW was
   the god rung: its whole arc cruises the top shelf, giving it a 13-metre
   band while every steeper rung gets a ~1.5 m one.
2. **Past ~9 m there is only one usable elevated angle at full pace.** Above
   ~8.5° the puck sails; below ~7.2° it never reaches the seam. So no ladder
   can give expression at long range, and a gear must choose where its fan
   sits. That is what makes the ladder a genuine gear identity rather than a
   ±10% scaling of one shape (which is all v3's three near-clone ladders
   were).

The v3.1 spacing follows from those: put each gear's three rungs across the
distances its shooter actually shoots from (3–10 m), and let the gear choose
which end of the rink it owns. The M92 at 6 m goes from `0.68 / OVER / OVER`
to `0.68 / 1.00 / OVER`; at 4 m from `0.49 / 1.18 / OVER` to three distinct
in-net arrivals (`0.49 / 0.70 / 1.03`).
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
