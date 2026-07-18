# Breakout Rework — Design Doc

Status: **scoping / agreed-design draft** (task #32). Implementation follows the
CLAUDE.md workflow: this doc is the plan; deviations get discussed first.

## 1. The problem (playtest report + diagnosis)

Playtest observations (3v3 and 5v5):

- "Transition out of the D-zone is not fantastic. The forecheck is relentless
  and phenomenal. Defenders cough up the puck a lot."
- The pass model is now honest about pressure (the #31 release contest priced
  the forechecker on the carrier's hip), which *revealed* the problem rather
  than causing it: every option the breakout carrier has by the time he has
  the puck is genuinely bad. The fix direction is **earlier structure and more
  real options**, not pricing hacks.

Diagnosed root causes, in code:

- **GAP 1 — no retrieval posture (the structural one).**
  `AIPossessionState.compute` hard-overrides any loose puck in our DZ to
  `DZONE` shape. The breakout slot set (`BREAKOUT_D2` / `BREAKOUT_STRONG` /
  `BREAKOUT_C` / `BREAKOUT_STRETCH`, or 3v3's STRONG/WEAK) only exists once a
  teammate *carries*. So on every dump-in, rim, or won battle, the retrieving
  D reaches the puck with **zero support structure** — wingers are still in
  zone-coverage stations, the C hasn't started his swing — while the
  opponents' `FORECHECK` shape deployed the moment the puck went loose. Real
  breakouts are choreographed **during the retrieval** (the retriever
  shoulder-checks and picks his out *before* touching the puck; the wall
  posts fill while the puck is still travelling). Ours starts at t=0 of
  possession, which is exactly when F1 arrives.

- **GAP 2 — the carrier's escape options don't include the change-of-direction
  family.** The compete's own-zone candidate set today: 8 local cardinals,
  retreat ring (under pressure), 2 wall-exit anchors, slot anchor, evade seam,
  post walkouts (behind the goal line only), and the hard-rim DUMP. What real
  D do under pressure and we cannot represent:
  - **Wheel** — carry *behind the net at speed* and out the far wall. Our
    net-blocker prune (`carry_path_blocked_by_net`) kills every straight
    candidate through the cage, and the walkout pair only exists when already
    behind the goal line — there is no representable "route around the net"
    carry from in front / beside it.
  - **Reverse** — bank/rim the puck back around the boards, against the grain,
    to the trailing partner or weak-side wall. No candidate generates it; the
    change of direction is precisely what beats a committed F1, and the model
    can already see that (the release contest + escape gate would price it
    well) if the option existed.
  - **Over (developing)** — the D-to-D behind the net. `BREAKOUT_D2` stages
    the valve, but the carrier's developing-feed hold
    (`_developing_outlet_feed`) only watches `BREAKOUT_STRONG` / `OUTLET`
    routes — a D2 skating to the net-back is invisible as a *reason to
    protect and wait a beat*, so the carrier never buys the half-second the
    Over needs.

- **GAP 3 — the half-wall winger is a lane-chaser, not a wall post.**
  `AIRoleBreakout` STRONG samples two columns (wall + mid-seam) by
  lane × potential. Under a real forecheck the honest answer to "where is the
  lane cleanest" oscillates and often pulls the W *off* the wall — but the
  researched winger job is to **hold the boards at the hash marks** (body
  open, an outlet that exists *because* the wall is the one protected lane)
  and, on receiving under a pinch, play the **second touch**: chip off the
  glass past the pinching D, touch to the swinging C, or carry. The chip/rim
  "out" as a deliberate second touch exists mechanically (the DUMP's hard
  rim) but nothing ensures the W's compete considers it at the wall.

- **Working already, keep:** the C low swing (`AIRoleBreakoutCenter` —
  researched rules, paces the carrier, below the puck), the stretch W, the
  D2 valve station, dump-with-race pricing, the counter-rush exposure math,
  and the honest release contest. The *nouns* are right; the timing and the
  option set are what's missing.

## 2. Research: how real breakouts work

The retrieval read (before touching the puck):

- The retriever shoulder-checks twice on the way back and classifies the
  pressure: **which side F1 attacks from, and how much time he has**. The
  breakout *type* is chosen before pickup; the touch executes it.
- The other four are moving during the retrieval: wingers to the half-wall
  posts (hash marks, on the boards, facing up-ice), C starts the low swing
  mirroring the puck side, partner D to net-front/net-back for the Over.
- The goalie stops rims behind the net for the D (ours deliberately plays
  tier-1 stop-and-leave only — that stays; see Non-goals).

The five D breakouts, keyed on the pressure read:

| Play | Trigger | Execution |
|---|---|---|
| **Up** | No/late pressure, or F1 angles from the weak side | Turn up-ice on the strong side; first pass to the half-wall W or swinging C. The default; north-south, fastest. |
| **Over** | F1 attacks the strong side hard | D-to-D behind (or in front of) the net to the weak D; the whole flow reverses to the weak wall. Needs the valve *already there* and a beat of protection. |
| **Wheel** | Retriever has a step of speed on F1 | Keep skating — carry behind the net at pace and up the far wall. The net is the screen; F1 can't corner with him. |
| **Reverse** | Hard chase pressure from *behind* on the strong side | Bank/rim the puck back around the boards the way he came, to the trailing partner / strong-wall W now behind the play. Change of direction beats the committed chaser. |
| **Rim** | Pressure everywhere, no clean touch | Hard rim around the glass to the half-wall W (or off the glass and out). Low-percentage but never a slot turnover; the W must win the wall touch. |

Support structure principles:

- **Half-wall W**: boards at the hash marks, chest open to the ice, the
  guaranteed outlet. On receiving: chip out off the glass past a pinching D
  (the second touch that makes the Rim/Up work), touch to the C underneath,
  or carry if the wall is open.
- **C low swing**: the second outlet underneath, times the swing to arrive
  as the first pass is made, takes the middle when F1 overcommits wide.
- **Weak/stretch W**: width and the over-the-top option; on an Over he
  becomes the strong-side wall.
- **Quick-up beats perfect**: the best breakouts move the puck on the first
  clean touch; holding to find the ideal option is how turnovers happen.
  (Our EV compete already embodies this — fire wins ties — once the options
  exist.)

## 3. Design

Philosophy: **no scripted plays.** The EV compete stays the decision-maker;
this rework (a) starts the support structure at the right moment, and (b)
adds the missing candidates so Up/Over/Wheel/Reverse/Rim all *exist* as
things the compete can price. The plays then emerge from honest EV exactly
like the duel behaviors did — and the same harness methodology verifies it.

### Phase A — Retrieval posture (RETRIEVAL state)

The structural fix for GAP 1. `AIPossessionState` gains a **RETRIEVAL**
read carved out of the loose-in-our-DZ override:

- Condition: loose puck in our DZ **and our side clearly wins the race to
  it** — grounded in the same ETA primitives the chase election and race
  reads already use (our best ETA + a margin ≤ their best ETA). "Clearly"
  matters: a contested race stays DZONE (the current behavior is correct
  there — a strip scramble in our slot is defense, not choreography).
  Hysteresis on the margin so DZONE ↔ RETRIEVAL can't flicker at the
  boundary (same pattern as the strong-side hysteresis).
- Team shape in RETRIEVAL: the BREAKOUT slot set, with the race winner in
  the retriever seat (the existing chase behavior — he's just chasing the
  puck) and everyone else taking their breakout posts **now**: wall W, C
  swing spinning up, D2 to the valve, stretch W wide. By the time the
  retriever touches the puck, the Up and Over already exist.
- Both modes get it (the 3v3 BREAKOUT set is STRONG/WEAK + retriever);
  3v3's set is small and identical in spirit, but we verify 3v3 duels and
  feel explicitly before shipping — if it destabilizes shipped 3v3 tuning,
  gate to 5v5 first and revisit.
- Perf: the read is a per-brain-tick (6 Hz) ETA comparison over ≤10 skaters
  using existing primitives — negligible.

### Phase B — The carrier's missing escape candidates (GAP 2)

All three added as *candidates* priced by the existing compete — no new
decision layer:

1. **Wheel routes.** Two waypointed behind-the-net carry candidates
   (mirroring the WALKOUT construction, reversed: in-front → behind → far
   side), exempt from the straight-line net prune the same way walkouts
   are, priced with the real two-leg time so the compete sees the net
   screen honestly: the crossing/strip reads run per leg, and a committed
   F1 chasing from the strong side genuinely cannot cover the far-wall
   exit. The escape-speed gate (already in `reach_clearance`) is what makes
   the wheel price *well* exactly when the retriever has a step — the
   real trigger, for free.
2. **Reverse rim.** A second DUMP variant: hard rim around the *strong*
   boards back the way the play came (target = the trailing wall behind
   the carrier), generated only under chase pressure from ahead-of-the-rim
   direction. Uses `AITrajectory`'s existing board-bounce prediction for
   the flight and the dump's existing race pricing (who reaches the rim
   exit first) — the same machinery, new target geometry.
3. **Over as a developing feed.** Extend `_developing_outlet_feed` to watch
   `BREAKOUT_D2`'s route to the net-back valve, so a pressured carrier can
   pay a protected half-second for the D-to-D the same way he already can
   for a developing wall outlet. The hold self-terminates the instant the
   live pass matches it (existing contract).

### Phase C — Wall-post winger + the second touch (GAP 3)

1. `AIRoleBreakout` STRONG becomes a **post-holder**: the primary station is
   the strong half-wall at the hash marks (boards inset, facing up-ice);
   the lane × potential argmax only *adjusts along the wall* (low ↔ high)
   rather than swinging into the mid-seam by default. The mid-seam column
   survives as the explicit "wall is the carrier's own wheel route" case.
2. **Second touch**: when the wall W receives under a pinch, his own carrier
   compete must generate the glass-out — the existing hard-rim DUMP aimed
   up the wall past the pinching D. Verify the dump candidate generation
   covers "on the wall, pinch incoming" (it prices clearing our zone
   already; the gap, if any, is the aim geometry hugging the boards). The
   chip-to-C is already representable (a soft short pass — no work).

### Phase D — Measure, calibrate, pin

Same methodology as the duel harness (#27):

- **Breakout scenario harness**: staged retrievals against the live
  forecheck (dump-in corner retrieval, rimmed puck, D-to-D under 1-2-2 and
  2-1-2 pressure shapes, in both modes). Metrics per scenario: clean-exit %
  (controlled possession crosses our blue line), cough-up % (turnover in
  our zone within N seconds of retrieval), time-to-exit distribution.
- Baseline BEFORE Phase A lands, re-measure after each phase — the same
  before/after discipline as the perf work, so each phase's contribution is
  measured, not assumed.
- Regression pins: the plays fire under their researched triggers (wheel
  wins when the retriever has a step; over wins when F1 overcommits strong;
  reverse beats the committed chaser; rim never turns over in the slot),
  and the DZONE override still holds contested races.

## 4. Non-goals

- **No scripted set plays** — candidates + posture only; EV picks.
- **No goalie puck-handling tiers** — the tier-1 stop-and-leave stays; rims
  behind our net remain the D's to retrieve (by design, see the goalie doc).
- **No human positional inference** — humans slot into the same structure
  via their lobby position, nothing more.
- **No forecheck nerfs.** The forecheck is praised; the breakout earns its
  exits honestly or the scenario metrics say we're not done.

## 5. Open questions (decide before/during implementation)

1. **3v3 scope**: RETRIEVAL + reverse/wheel candidates for 3v3 too from day
   one, or 5v5-first behind the team-size seam and port after playtest?
2. **Retrieval margin**: how "clearly" must we win the race — one
   reaction-time (~0.25 s) of ETA margin is the grounded starting guess;
   calibrate against the harness cough-up metric.
3. **Rim receiver expectations**: is the half-wall W winning rimmed-puck
   touches reliably enough today (contested-pickup momentum contest), or
   does Phase C need a "meet the rim" micro-behavior on the wall post?
