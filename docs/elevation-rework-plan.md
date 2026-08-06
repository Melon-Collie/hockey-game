# Elevation — Design Doc (issue #585)

Status: **IMPLEMENTED.** The §1 ladder table is the live playtest tuning
surface. Supersedes the elevation half of `docs/attributes-v4-plan.md` §5.2.

This doc describes the design as it stands. Earlier iterations (power-scaled
vertical speed; an adaptive target-height solve; two rounds of ladder
re-spacing) are in git history and are not summarized here — the only piece
worth carrying forward is *why the solve was rejected*, which is §1.2.

## 1. The model — a ladder of contact points, no solve

Elevation is a player-selected LOFT LEVEL (scroll, 0–3), fictionalized as the
contact point on the blade (heel → toe). Each level is a **set launch angle**
from the gear's ladder — no target-height solve, no position input, no
vertical-speed caps. Arrival height is emergent from angle × charge × range.

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

Distinct shots available per zone (counting FLAT) — the design target is
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

## 1.1 Why the rungs are anchored to posture and zone

Three structural facts set what any set-angle ladder can do. All are
consequences of arrival ≈ `d·tan θ − (g d²/2v²)·sec² θ`.

1. **The angular budget spanning the whole net shrinks as ~1/d** — 29° at 2 m,
   10.7° at 6 m, **3.4° at the point**. The number of distinct shot types that
   can exist at a distance is therefore set by physics, not tuning: many in
   tight, essentially one at range. This is why a gear must own a zone, and
   why the point gets no menu.
2. **Build variance lives entirely in the gravity drop** (`~d²/v²`). The ±17%
   shot-power spread moves arrival by ±60 cm when a band sits at 15–22 m, but
   only ±3–12 cm at these 4.5–8.5 m home ranges. Anchoring the fans close in
   made the system build-tolerant as a side effect — which is why **no power
   normalization is applied**, and why builds change your shot without ruining
   it. Same reason **the slapper needs no separate ladder**: its extra pace
   costs ~5 cm of drop at home range, so the rungs ride one notch higher and
   the level still means what it means.
3. **A rung is widest when its apex lands in the target band**, since the arc
   then cruises that height over a long run of distance instead of slicing
   through it. Corollary: a ladder whose rungs all target the same height
   collapses to one useful rung per gear, because only one angle can have its
   apex there at a given pace.

The posture targets come from the keeper's real equipment. He is in butterfly
for most in-tight shots, and his leg pads then top out at **0.28 m** — the pad
box is 0.28 m wide (11", the real NHL spec) and rolls flat, which
`GoalieAnatomy.BUTTERFLY_PAD_HALF_WIDTH_M` (0.42 = half the 0.84 long axis)
confirms. The 0.40–0.85 m band above that is the armpit seam, which
`AIActionScoring` already models as opening when a hand is committed low.

## 1.2 What is design, and what is just true

The ladder table produces a lot of properties. Only some of them are things
the design is *for*; the rest are consequences that happen to hold at the
current numbers. Confusing the two is how a previous iteration acquired
constraints nobody had asked for — a doc sentence became a test, and the test
then blocked changes it was never meant to govern.

**Load-bearing — change these only on purpose:**

- The four posture targets (ice / 0.41 / 0.70 / 0.99 m) and the fact that they
  are absolute heights tied to goalie equipment.
- Per-gear home ranges, and "great in your range, competent one range away".
- **No solve.** Elevation must not aim itself at a height. An adaptive solve
  was tried and rejected: with the vertical axis solved and cursor aim
  absolute, an open corner becomes a deposit rather than a contest, and it
  cannot be made to work for passes, which do not aim at the net at all. The
  level is a set angle, full stop.
- Quick passes stay on the fixed vertical-speed table, gear-invariant.

**Incidental — true today, not requirements:**

- No rung sails on a wrister; no LOW rung sails even off a max slapper.
- Any per-blade character sketch beyond its home range ("the safe blade", "the
  point snipe", and similar).
- The specific zone counts in the §1 table, as opposed to their shape.

Tests exist for several of the incidental properties. They are **drift
detectors**, in the `tests/CLAUDE.md` "pinned measurements" sense: a failure
asks *"did this change on purpose?"*, not *"you broke a rule."*

## 2. Wire and input

Four levels fit the 2-bit elevation field (0..3): FLAT 0, LOW 1, MID 2,
HIGH 3, with `InputState.MAX_ELEVATION_LEVEL` following `ShotMechanics`.
Peers on different ladder values simulate different arcs from identical
inputs, so any ladder change is a `PROTOCOL_VERSION` bump.

## 3. The levels double as DEFLECT MODES

The level names the deflection you are playing for, and the blade's lift
height follows it:

| level | blade lift (pivot) | deflect intent |
|---|---|---|
| FLAT | on the ice | ground puck stays on the ground (redirect along the ice) |
| LOW | on the ice | ground puck deflects UP — the money tip |
| MID | ~0.35 m | airborne puck deflects UP — roof the rising shot |
| HIGH | ~0.52 m (`blade_lift_height`) | airborne puck bats DOWN — the high-feed knockdown at the net mouth |

- The up/down sign comes from the LEVEL, not from `puck_y − blade_y`.
  Deliberate and natural deflects run the same physics
  (`PuckCollisionRules.deflect_velocity`); only the loft-sign selection
  (`deflect_loft_speed`) reads the level.
- Reach planes: FLAT/LOW play the ice; MID the low air (~0.35 pivot); HIGH the
  high air (~0.52 pivot, reaching ~1.05).
- A saucer pass apexes ~0.21–0.26 m, under MID's 0.35 m pivot, so camping MID
  cannot cheese saucers.
- Bot tipper (finisher): shooter FLAT → tipper LOW (lift it); shooter elevated
  → tipper HIGH (reach the high feed, bat it down at the mouth).

## 4. HUD

Chevrons: LOW 1 / MID 2 / HIGH 3, FLAT none. At four levels the chevron
readout is at its limit. The contact-point visual tell (issue #596) has landed
alongside it: during a wrister wind-up the BLADE seats the frozen puck
heel→toe per the level, joined by a toe drag that rolls the face closed over
the puck. A plain carry shows no seat — the read matters once a shooter has
committed. Whether the chevrons shrink to a local-only affordance or retire is
a playtest call.

## 5. Where this lives in code

| piece | location |
|---|---|
| Release math (`shot_loft_y`, the ladder lookup) | `Scripts/domain/rules/shot_mechanics.gd` |
| Per-gear ladders + accessors | `PlayerAttributes._CURVE_LOFT_*_DEG` |
| League defaults (M92's ladder) | `GameRules.DEFAULT_LOFT_TAN_*` |
| Wiring onto the controller | `SkaterController.apply_attributes` |
| Bot rung choice | `AIActionScoring._best_high_rung`, fed by `AISkaterCaps.loft_tans` |
| Deflect sign + blade lift | `PuckCollisionRules.deflect_loft_speed`, `Puck`, `SkaterController` |

Trajectory is a pure function of (level, gear) — position-free, power-free.
Nothing in the ladder approaches 45°, so `ShotMechanics.MAX_LOFT_RATIO` is a
pure anti-forgery guard that never touches an honest shot.

## 6. Open items

1. The HIGH band's structural floor above the standing seam is still the
   measured `HOLE_BAND_CORE[HIGH]` (0.40) rather than real geometry — the
   collider list has no shoulders or arm roots, so the boxes under-represent
   him there. Grounding it needs those added to `GoalieAnatomy` first.
2. The keeper's stick still floors cover everywhere below the seam, though the
   blade is 0.07 m tall and an elevated puck clears it. Narrowing it to the
   blade's real height makes the in-tight flat shot better and moves
   `test_goalie_low_cover.gd`, which pins measured live-keeper results.
3. Crossbar corner-arc collision + drill-target audit — issue #598. The
   crown/post-span gap (0.815 vs 0.915) matters now that launched shots can
   cross above the bar near the posts.
4. The goalie over-bar reaction gate: he must not save pucks that were
   sailing.
5. The goalie high-game complement (pre-arm read of the visible toe carry) if
   static-look snipes feel too free — issue #597.
