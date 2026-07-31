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

- **GAP 2b — no rim exists anywhere in the model (playtest-confirmed:
  "the dump does fire sometimes, but it's not a rim").** Two halves:
  - *Pricing*: `_best_dump`'s own-zone clear has `gain` hardcoded 0 — only
    the soft dump-and-chase earns recovery value. Priced as pure loss
    (`−concede`), it can only win when retention is HOPELESS (dump >
    honest raw carry) *and* no pass beats it — a window that rarely opens,
    and when it does, what fires is a giveaway, not a delivery. The model
    is missing what a rim actually is: a **bank pass with a receiver** —
    the half-wall winger racing to the wall touch.
  - *Execution*: even the dump that does fire is a straight lofted flight
    to a spot (the HIGH chip at the fixed quick pace — see the
    `_dump_target` doc in the state machine). Nothing ever aims ALONG the
    boards and lets the corner reflections carry the puck around — the
    signature rim flight. The physics supports it (real board restitution;
    `AITrajectory` can predict the wrap); no release ever produces it.
  A corollary: the wall W never receives rim touches today because rims
  never happen — and the O-zone POINT roles have never needed a rim read
  (see Phase C.3), which becomes a hole the moment rims are real.

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

### Phase A — Retrieval posture (RETRIEVAL state) — landed, then REMOVED

**Removed after measurement.** The design below shipped and was later deleted;
it is kept as the record of what was tried and why it was reversed, so nobody
rebuilds it without new evidence.

What it was supposed to buy: outlets already standing at their posts by the time
the retriever touches the puck, so the breakout is choreographed during the
retrieval rather than after pickup.

What it actually cost, measured four ways (two breakout-harness runs and both
arms of a live bot-vs-bot A/B, ~2 min per arm):

- **It never gated a breakout.** Roughly 60% of BREAKOUT entries came straight
  from DZONE without passing through RETRIEVAL at all, and with the shape
  disabled the same breakouts still happened — team 0 reached BREAKOUT 12 times
  in each arm, team 1 reached it *more* often without it (8 -> 15 entries).
- **It was the dominant source of shape churn.** `DZONE <-> RETRIEVAL` alone was
  ~35 of a team's ~105 shape transitions per two minutes. Disabling it cut total
  transitions 25-38% and roughly doubled how long a team held its D-zone shape
  (mean spell 0.74 s -> 1.90 s for one team, 0.99 s -> 1.44 s for the other).
  Since DZONE and RETRIEVAL have disjoint slot sets, every flip re-slotted all
  five bots between zone coverage and breakout posts — and D-zone coverage
  cannot work if the shape it depends on is being rebuilt twice a second.
- **No outcome benefit, ever.** Clean-exit rate was never worse without it in
  any of the four measurements, and never significantly better with it. The live
  arms were 37.5% vs 44.8% clean (n=24 vs 29, p ~ 0.59) — directionally against
  the shape, not conclusive either way.

Margin tuning was ruled out first: a sweep of `RETRIEVAL_ENTER_MARGIN_S` /
`RETRIEVAL_HOLD_MARGIN_S` across five settings moved harness cough-ups by at most
2/30 and never beat the baseline, so the problem was never *when* to posture.

Resurrecting it needs a mechanism that does not re-slot the whole team on a race
read that flips twice a second — e.g. staging the outlets WITHOUT leaving the
defensive shape, so there is nothing to flip back from.

---

Original design, for reference:

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

### Phase B — The carrier's missing escape candidates (GAP 2) — landed

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
2. **The rim family — rim-as-a-bank-pass (fixes GAP 2b).** Rims stop being
   zero-gain concessions and become PASSES whose lane is the boards wrap:
   - Receiver: the wall player up the rim's path (the half-wall W on the
     forward rim; the trailing partner / wall mate on the REVERSE rim back
     the way the play came).
   - Flight: aimed ALONG the boards — flat, hard, hugging the wall — with
     the wrap emerging from the real board reflections; predicted with
     `AITrajectory`'s bounce simulation, and executed as a new release aim
     mode (the current dump chip's straight lofted flight cannot produce
     a rim — the aim geometry is the missing execution half).
   - Completion: the wall-touch race at the receiver's meet point — the
     same contested-pickup / chase-race primitives the dump already prices,
     now with OUR wall post as the favourite instead of nobody.
   - Value: the receiver's spot value at the meet point (the wall W's
     second-touch options are what make it worth more than a giveaway).
   The panic clear (`gain = 0` chip) survives as the true last resort;
   the rim-to-the-winger out-prices it whenever the wall post is manned —
   which Phase A guarantees it is.
3. **Over as a developing feed.** `_developing_outlet_feed` watches
   `BREAKOUT_D2`'s route, so a pressured carrier can pay a protected beat
   for the D-to-D the same way he already can for a developing wall outlet.
   The hold self-terminates the instant the live pass matches it (existing
   contract). **Scope note (pended):** the representable Over is the
   IN-FRONT lane — across the top of the zone over the slot box's upper
   edge, or wide of it. The BEHIND-NET Over stays unrepresentable: the
   pass model's own-goal-risk zeros (lead past our goal line +
   net-blocker + slot-crossing) forbid it, and relaxing them honestly
   needs an own-goal-risk model (a missed behind-net bank near our own
   cage) — a follow-up, not a drive-by.

### Phase C — Wall play, both sides (GAP 3 + the rim's defensive complement) — landed

1. `AIRoleBreakout` STRONG becomes a **post-holder**: the primary station is
   the strong half-wall at the hash marks (boards inset, facing up-ice);
   the lane × potential argmax only *adjusts along the wall* (low ↔ high)
   rather than swinging into the mid-seam by default. The mid-seam column
   survives as the explicit "wall is the carrier's own wheel route" case.
   And the receiving half of the rim contract: when a rim commits toward
   his wall, the W attacks the meet point along the boards
   (arrive-at-speed, blade to the wall line) instead of holding the post.
2. **Second touch**: when the wall W receives under a pinch, his own carrier
   compete must generate the glass-out — the Phase B rim aimed up the wall
   past the pinching D. The chip-to-C is already representable (a soft
   short pass — no work).
3. **O-zone point rim coverage (keep-ins).** The defensive complement —
   without it, real rims are free zone clears, because the POINT stations
   hold the line OFF the wall and a board-hugging clear sails past them.
   When a rim/clear is travelling up the strong wall (a live read off the
   puck's board-hugging flight — position near the boards + velocity along
   them, the same classification the W's meet-the-rim read uses), the
   strong-side point steps to the boards to hold the line: body/blade on
   the wall lane at the blue line, priced as the intercept race (rim
   flight time to the line vs the D's step) with the researched pinch
   support gate (#23's DP valve — the weak D slides to cover the middle;
   if the rim beats the step, bail up-ice rather than get sealed). This is
   the real keep-in point skill, and it rides the existing pinch/valve
   machinery rather than new structure.

### Phase D — Measure, calibrate, pin — instrument landed

Same methodology as the duel harness (#27):

- **Breakout scenario harness**: staged retrievals against the live
  forecheck (dump-in corner retrieval, rimmed puck, D-to-D under 1-2-2 and
  2-1-2 pressure shapes, in both modes). Metrics per scenario: clean-exit %
  (controlled possession crosses our blue line), cough-up % (turnover in
  our zone within N seconds of retrieval), time-to-exit distribution — and,
  once Phase C.3 lands, the mirrored O-zone metric: keep-in % (rims/clears
  up the wall the point D holds at the line vs escapes).
- Baseline discipline: the instrument (`benchmarks/test_breakout_harness.gd`,
  `-gselect=breakout`) is the before/after gauge; `main` comparisons run in a
  worktree (patch the RETRIEVAL trace line out for pre-rework code).
- **Instrument v2** (first iteration of the Phase D loop): organic staging —
  every trial begins as live play (the opponents CARRY through a warmup, both
  teams settle into brain-made shapes with real velocities) before the
  trigger event; deterministic jitter (18 trials); per-trial TRACES
  (RETRIEVAL engagement, first touch, the first release's committed decision
  + compete scores, from the duel harness's enriched release records). Two
  harness bugs the traces caught: the duel harness had NO BOARDS (dumped
  pucks left the world — every dump scenario unwinnable) and its snapshot
  never published the chase election (`closest_to_puck_by_team`) — so no bot
  could enter CHASE on a loose DZONE puck and RETRIEVAL could never fire.
  Both fixed in the harness (production was never affected — GameManager
  publishes the enrichment).
- **v2 tables** (18 trials, organic staging):
  * `main`:  clean 2, clear 3, cough 13 | retrieval 0/18, 5 exits mean 4.0 s
  * branch:  clean 2, clear 0, cough 16 | retrieval 15/18, 2 exits mean 3.2 s
  Aggregate still noise-level at n=18; the ROBUST cross-branch findings are
  the two model indictments the traces confirmed at scale:
  1. **First-pass completion is over-priced at the desperation margin.** The
     retriever's first release fires at pass EV ~0.02–0.16 and almost always
     dies. Next iteration: the calibration probe — record scored completion
     vs actual outcome per release across many trials, re-derive the lane /
     release-contest constants from the measured curve (the #27 method).
     Once honest, protect/wheel/rim should out-compete the coin-flip pass.
  2. ~~The retrieval race read is net-blind~~ — **LANDED as the net-aware
     ETA**: `time_to_arrive` itself now routes around the cage when the
     straight segment crosses it (four corner waypoints — both posts, the
     back alley, the front lip — each priced as two calibrated direct legs;
     a near-free z-gate keeps open ice bit-identical, and endpoints INSIDE
     the frame box keep the direct model — race-home reads target the net
     center as their home proxy). Every consumer inherits honest routing:
     chase elections, the RETRIEVAL race read, station races. Pinned in
     test_time_to_arrive_calibration (open-ice identity, cross-cage cost
     bounds, alley traverse, the honest behind-net race loss).
  3. ~~Behind-net chase execution~~ — **RESOLVED (iteration 3), in two
     parts.** The chaser-path trace EXONERATED the execution layer: the
     elected chaser charged at full stride on an honest route and correctly
     read a race the forecheck had already won — because the instrument's
     teleported dump skipped the flight, spotting the forecheck a free head
     start equal to the whole flight time. **Instrument v3** restores real
     dumps: fired from the warm carrier's live position (his own release
     moment IS the trigger when he moves it first), a CHIP variant in the
     duel harness (airborne = untouchable for the hang, landing speed loss —
     the over-traffic dump a flat 2D fire can't stage), rims wrapping the
     real corner arc, flight-length launch grace, and release-aware exit
     classification (a controlled PASS in flight across the line is clean).
  4. **The rim race exposed a real model hole — LANDED as the path race.**
     With real rims staged, the elected chaser dithered CHASE↔OFF_PUCK at
     walking pace while the rim rode the zone: `loose_puck_race_lost` (and
     the election's coarse lead) raced ETAs to the puck's CURRENT position,
     so the dumper tail-chasing the rim a metre back "won" a race the puck
     itself outruns, while the far-side skater whose true intercept is where
     the wrap comes to him read as hopeless and declined. Fast pucks
     (> 4 m/s) now race on the friction + board-aware predicted path
     (`AILoosePuckChase.race_trajectory` — memoized per puck state, one walk
     per tick shared by every consumer; `path_intercept_time` with an exact
     dist/v_max prune): the election, the brain's RETRIEVAL read, and the
     race-lost decline all inherit it from the same seam, so they can never
     disagree. Pinned in test_loose_puck_chase (rim elects the downstream
     skater over the tail-chaser; parked-in-path intercept reads the puck's
     arrival, not the skate distance; race-lost A/B with settled-puck
     control). Effect in the harness: the elected chaser commits from the
     first sample, the election hands off cleanly across the wrap, and the
     far-side D intercepts at the wall. ai_perf A/B'd same-session: within
     noise after memoization. (The container-duel pin was converted to
     check resolution LIVE — the winning carrier now collects his own dump
     behind the net-less harness goal line and wraps up-ice, and the
     defender's honest path-intercept counters; the final-frame assert was
     pinning the missing net, not the duel.)
  5. **Calibration probe v1 landed** (release-fate attribution in the
     harness): completed/fired by scored pass EV. First thin read (13
     fires): ev[0–.05) 2/5, ev[.05–.10) 0/4, ev[.10–.20) 3/4 — roughly
     EV-ordered; grow the trial matrix before deriving constants from it.
     (v3 staging changed the mix — n still too thin to fit.)
- **v3 table** (18 trials, real dump flights): clean 6, clear 1, cough 11,
  timeout 0 | retrieval 18/18, 7 exits mean 4.8 s. Behind-net trials now
  play the intended sequence end-to-end: rim wraps the corner arc, the
  chaser commits immediately, first touch is OURS in 4/6 (one clean exit
  via a behind-net CARRY pickup → BreakD2 — the wheel country working).
  6. ~~DZ wall-kill~~ — **RESOLVED (iteration 4) as arrival slack, no new
     behavior needed.** The per-teammate kill-time trace showed the missing
     wall-kill was not a positioning or role gap: the elected chaser HAD
     makeable reads (kill ~1.0–1.8 s) and chased — but every intercept was
     solved ZERO-SLACK (earliest point where ETA ≤ T exactly), so steering
     aimed the body at a dead heat with a 13 m/s rim; any execution slop
     missed by a hair, re-solved to a new dead-heat point further along,
     and missed again — a sliding-intercept treadmill (kill reads hovering
     1–2 s for three straight seconds while the rim stayed ahead). Real
     players cut to a point FURTHER along and arrive early, set in the
     lane. The grounded quantity is the reception setup time
     (`AILoosePuckChase.KILL_SETUP_MARGIN_S` 0.25 s — blade to the gate +
     a beat): fast-puck intercepts now require that arrival slack, in both
     the path-race read (`path_intercept_time`) and the SM's chase aim
     (`_lead_intercept`, fast pucks only — slow-puck chases keep the exact
     test and converge as before). Effect: behind-net first touch OURS
     7/10 with wall-kills at 1.8–1.9 s (was 3.6 s chasing the wrap), and
     the treadmill wrap-outs are near-gone.
- **v4 table** (30 trials — JITTERS 5 + a per-jitter warmup stagger, since
  an identical warmup across jitters made "n trials" ≈ n/3 independent
  samples): clean 11/30, clear 2/30, cough 17/30, timeout 0 | retrieval
  30/30, 13 exits mean 4.9 s. (main baseline on the old 18-trial matrix:
  clean 2/18, retrieval 0/18.)
- **Probe scoping note (iteration 4):** at 16 fires the completion curve
  reads ev[0–.05) 3/6, ev[.05–.10) 3/6, ev[.10–.20) 0/4 — sub-0.10-EV
  breakout passes complete ~50% while the compete prices the rim-out at
  −0.3..−0.5, so a coin-flip pass in our own slot area outcompetes a
  guaranteed neutral clear (the residual behind-net coughs are all
  post-retrieval first-pass deaths now). Two things gate the recalibration:
  (a) n is still far too thin to fit, and (b) breakout first-passes sample
  only the desperation corner of the pass distribution — fitting GLOBAL
  lane/release-contest constants from them would overfit that regime. The
  probe should accumulate across the other live instruments (rush/shot
  harnesses fire passes too) before constants move; the cheaper nearer-term
  lever is the DUMP side of that compete (does a clear's neutral-reset
  value deserve −0.5 under a committed forecheck?).
- **The clear re-grounded (iteration 5 — the "neutral clear is quite good
  under pressure" decision):** decomposing the live compete's −0.5 dump
  scores found TWO model lies stacked:
  1. **The rim was priced as a chord.** From a behind-net/corner origin the
     straight line to the center-boards target threads the middle of our
     zone (blocked, loss point in front of our net); the real rim rides
     the boards. `_best_dump` now routes the delivery origin → wall
     waypoint at the origin's depth → target, two lane-priced legs (the
     chip keeps the chord — air ignores boards). Same fix family as the
     net-aware ETA: price the route, not the fiction.
  2. **The threat surface's positional floor delocalized every concede.**
     `threat_surface_shoot = max(score_shoot, position_potential)` — the
     positional fallback is right for MARK's gradient and WRONG for
     absolute turnover pricing: it floors possession-against-us at
     ~0.25–0.55 EVERYWHERE (measured: 0.457 at center boards, 0.246 at
     THEIR high slot), so conceding at the safest spot on the ice read
     like half a slot chance. New `threat_local_shoot` /
     `turnover_cost_local` (score_shoot branch only, no floor) price the
     5v5 own-zone clear's concessions, paired with counter_rush_cost
     carrying the future-danger half — which sees the covering set the
     breakout posts provide, so a clear against a committed forecheck
     reads nearly free exactly when doctrine says it is. Every loss mode
     (lane pick AND target concede) pays both halves — a locally-cheap
     pinch pick still charges the in-zone possession it hands over
     (pinned by the camped-wall chip test). Measured: the live-moment
     clear −0.492 → −0.035; clears now FIRE (DUMP↝out first releases).
     Scoped 5v5+own-zone with the rest of the rim family; MARK's gradient
     surface and the 3v3 ordering untouched. The pass/carry failure
     branches still ride the flat floor — recalibrating THOSE against the
     probe is the standing global item.
- **Outcome taxonomy upgraded (cough danger):** "cough-up" lumped a
  doorstep scramble giveaway with a re-entry against five set defenders —
  blind to exactly what the clear doctrine trades on. Each cough row now
  carries the LOCAL shot threat at the concede moment. First read splits
  perfectly on the doctrine line: every clear-first cough concedes at
  dgr 0.00 (set-defense re-entry), every desperation-pass death at
  dgr 1.00 (dead on a stick in our slot); race-loss coughs 0.00–0.03.
  Mean 0.224 over 17. Raw clean/cough counts are no longer the headline
  metric for clear-heavy strategies — danger-weighted reading required.
  Remaining dgr 1.00 rows are 0.07-EV passes still narrowly outbidding
  the ~0.0 clear — the pass-side probe calibration will settle that
  ordering.
- **Live retune measured (534f534 merged from main):** the home-plate slot
  veto (2.75 × 6.0, was 2.0 × 5.0) + behind-net blade cradle. Same-day
  30-trial A/B: clean 11→13, cough 17→15 — and the row-level shift is the
  point: the m+1 j0 behind-net retrieval that fired a 0.05-EV slot feed
  (cough) now finds a 0.22-EV BreakStrong feed (clean exit) once the cheap
  cross-slot option is hard-vetoed. Residual coughs split between honest
  race losses (their forecheck first to the landing spot on some jitters)
  and low-EV NON-slot feeds (0.03–0.08 wall/D2 lanes) that still
  out-compete the −0.36..−0.50 dump — the dump/clear valuation question
  above is unchanged. Interaction note: the widened rect reaches the
  BREAKOUT_D2 post's net-front station (0, goal−1.0) — most direct feeds
  to a PARKED D2 now veto (feeds to a moving D2 still land), so D2's value
  shifts toward carry-reversal / handoff / second-wave body. The Over-watch
  pin restaged its lane above the deeper rect's edge (the watch prices the
  future feed through the same veto, so the old lane honestly reads dead).
- **Sprint-aware race reads (iteration 6, branch claude/sprint-aware-eta):**
  every AI race read was Speed-attribute-BLIND by construction — cruise
  speed is near-uniform by design (the attribute doc puts Speed's separation
  in the sprint ceiling, `sprint_ceiling_mult` 1.07→1.16), the body sprints
  its races (`_resolve_sprint`), and the reads priced cruise (~0.3 s off on
  a 3 s race — larger than the RETRIEVAL and kill-setup margins). New
  `BotSprintRules.race_speed`: the read-side sprint model — the body's own
  engage gates (lockout, stamina floor, sprint engage gap) + the pool's
  sustainable burst (t_burst = stamina/drain) collapsed to the exact
  two-phase distance-weighted cap. One seam (`AILoosePuckChase.race_vmax`)
  feeds the election, `best_intercept_time` (RETRIEVAL), and
  `loose_puck_race_lost` (which gained `self_pid` so its own side is
  stamina-read too); the SM chase walk races at the same cap
  (`_lead_intercept` vmax override). `AISkaterCaps.sprint_speed_mult` is
  plumbed from the controller (league default fallback — a capless league
  body sprints). The duel harness gained a REAL sprint plant (StaminaRules
  gate/drain/lockout + the movement model's sprint multipliers at league
  tuning) so reads and instrument stay in parity — a sprint-pricing read
  against a sprint-less plant would recreate the treadmill artifact class.
  Approximations (documented on race_speed): ramp charged at normal thrust
  (sprint's ×1.2 bump ignored — conservative), turn gate ignored (races
  priced straight), carriers never sprint-read (race consumers are
  loose-puck reads; breakaway sprint pricing is future work if carry races
  ever consume it). Pins: race_speed model (cap / gates / two-phase blend),
  burner-vs-plodder election flip, gassed-vs-fresh race flip. Harness with
  the sprint plant: clean 6 / clear 10 / cough 14, 16 exits (was 13), mean
  cough danger 0.212 — the forecheck arrives hotter too, so more
  retrievals resolve as rim-outs; reads and bodies agree (no treadmill
  rows, no timeouts). Follow-on candidates: counter-rush fastest-opponent
  leg and station/race-home reads (backchecking sprints there too).

## 4. Non-goals

- **No scripted set plays** — candidates + posture only; EV picks.
- **No goalie puck-handling tiers** — the tier-1 stop-and-leave stays; rims
  behind our net remain the D's to retrieve (by design, see the goalie doc).
- **No human positional inference** — humans slot into the same structure
  via their lobby position, nothing more.
- **No forecheck nerfs.** The forecheck is praised; the breakout earns its
  exits honestly or the scenario metrics say we're not done.

## 5. Decisions (settled with the developer)

1. **5v5-exclusive.** All of it — RETRIEVAL, the rim family, wheel, wall
   post, point keep-ins — gates on the team-size seam. Rationale: rims and
   dump-ins are genuinely uncommon in real 3v3, where possession is the
   whole game — the honest 3v3 read is to keep the puck, and 3v3's shipped
   tuning stays untouched by construction. Port later only if playtest
   asks for it.
2. **Retrieval margin**: start at one reaction time (~0.25 s) of ETA
   advantage to enter RETRIEVAL; calibrate against the harness cough-up
   metric.
3. ~~Rim receiver expectations~~ — **answered by playtest**: the W never
   gets rim touches because rims never fire at all (GAP 2b). With
   rim-as-a-pass landing in Phase B, Phase C's wall post gains a "meet the
   rim" read by default: when a rim commits toward his wall, the W attacks
   the meet point along the boards (arrive-at-speed, blade to the wall
   line) instead of holding the post — the receiving half of the same
   bank-pass contract.
