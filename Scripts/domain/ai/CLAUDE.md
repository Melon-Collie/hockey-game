# Bot AI — design rules

Scope: `Scripts/domain/ai/` (scoring, role behaviors, skill profiles) and its
consumers in `Scripts/ai/`. Read this before changing how a bot *decides*
anything; the per-file comments cover how each piece works.

## Evaluators model perception, never feel

Every multiplier in the utility scoring must be a quantity the bot can
physically **see** — the open-net angle a shooter can hit, a defender's reach
vs. the puck's flight time, the goal mouth's projected width — not a curve
shaped to feel right (`1 - x/K`). A grounded model generalizes to situations
nobody tuned and stays honest when an upstream number moves; a magic curve is a
model you haven't built yet.

When a behavior is wrong, fix the **model** — give it the perception it's
missing. Do not bolt on a corrective multiplier or a hard positional gate: those
compensate for a model that isn't seeing something, and they rot.

Constants in an evaluator must be physical measurements (a reaction delay, a
reach, a body width), not shape parameters. *Feel* tunables — staging offsets,
difficulty knobs, how the game should play — are legitimately hand-picked; the
line is evaluation vs. feel, not "numbers are bad".

## One currency across the carrier's compete

SHOOT, PASS and CARRY are compared numerically, so all three must price the shot
through the value seam (`AIShotValue` / `score_shoot_value`). Leaving one leg on
the hole geometry — which saturates at 1.0 while the seam tops out near 0.45 from
any real spot — makes that leg win outright, and a hold priced in the wrong model
is a permanent veto on the other two rather than a mispriced hold. The hole
geometry is still the truth for *executing* a committed shot (aim, loft, power);
it is not the ranking currency.

The giveaway bars (`SHOT_MIN_VALUE` 0.05, `PASS_MIN_VALUE` 0.02) are scale-bound
to that seam — an honest NHL-calibrated goal probability where a clean mid-slot
look is ~0.12. They are not transferable to the hole-geometry score, which would
read them as a twentieth as strict.

## Difficulty rides three independent axes

`BotSkillProfile` splits every tier knob onto one of three axes. Keeping them
separate is what makes tiers tunable without a rebalance cascade:

| axis | what it changes | knobs |
|---|---|---|
| **PRECISION** | how sharp the bot is | reaction delay, dispatch cadence, aim/timing error, settle doubt |
| **PACE** | how much time and space a human gets | pursuit standoff, anticipation lead, check aggression |
| **COGNITION** | which reads exist in its model at all | the bool gates |

Precision only shows up on the bot's *finish*. Pace is what a human feels on
**every** possession, which is why the two are separate dials — reach for pace
when a tier feels oppressive, precision when it finishes too well.

The pace knobs further split by what a lower tier concedes: standoff and
anticipation concede **space** (positioning); check aggression concedes
**threat** (physicality).

Two things deliberately outside the table. **Aim slew is not a tier knob** — a
bot slews its cursor at its real Hands blade speed (`AISkaterCaps.blade_speed`),
so execution difficulty rides the bot's attribute build rather than a
per-difficulty override. And **`dispatch_period_ticks` is the one knob that is
not tick-independent**: every other one is denominated in seconds, so it is the
one that has to be rescaled linearly if the sim rate ever moves off 120 Hz.

Tuning order, when a tier is wrong: reach for shot error first — it moves goals
without making bots look drunk. If a tier plays like a pushover, raise the
precision knobs back toward Hard and let the pace knobs keep it beatable; if it
still feels superhuman, soften pace (standoff up, anticipation and aggression
down) before touching precision. If it makes plays a human wouldn't SEE rather
than plays it executes too well, that is settle doubt — raise the frac for a
higher bar, the τ for a longer one.

### Hesitation is a raised bar, never a timer

A lower tier is less sure of a puck it has just gained. That is expressed as
**settle doubt** (`BotSkillProfile.settle_penalty_frac`): a decaying fraction by
which a fresh carrier handicaps its own read of every ACTIVE option against that
option's *giveaway bar* — the thing that says what a release has to be worth to
be worth the puck. An obvious play out-values a raised bar on the first tick; a
marginal one waits for the doubt to drain. So the bot deliberates over close
calls and is decisive on clear ones, which is what makes a tier read as *less
sure* rather than *laggier*.

Charge it against the **bar**, never against the carry it competes with. The
stand-still carry candidate is by construction worth the same as firing from
where the bot stands, so a handicap inside the fire-vs-carry compete can only be
a uniform delay — it holds the doorstep tap-in exactly as hard as the hopeless
point shot. That is the flat "may not commit for N seconds" gate this replaced,
and it is what "obvious choices still fast" is a rule against.

### The rule that keeps cognition gates honest

A gate may only remove an **input** the evaluator consumes (perception — the
lower tier scores with less information) or remove an **option** from the
compete (repertoire — the play simply isn't considered).

A gate must **never** corrupt a shared evaluator per tier. No difficulty-scaled
fudge factors inside the scoring, no tier-aware constants in the models. This is
what lets one set of evaluators serve every tier and stay unit-testable.

Normal and Hard deliberately run **all gates open** — they are the same player
separated only by continuous tuning, so the gap reads as "sharper" rather than
"knows moves the other doesn't". Easy is where gates close.

## A defensive stand is a moving frame, not a spot

Everything a defensive role computes — the gap ladder's stand, the angling
shade, a cover point, a backchecker's hip — RIDES an opponent and sweeps toward
our net at his pace. So the role publishes the stand's own velocity
(`RoleDecision.target_velocity`) and the steering flies the route in that frame
(`AISteering`, moving-frame pursuit): the commanded velocity is the stand's plus
a closing term that is spent by the time you arrive, so an approach ends
*matched* to the play rather than stopped in front of it.

The distinction is not cosmetic. Flown as a parked point, the trip has one shape
regardless of distance — sprint at the spot, brake to a stop on it — so a
defender could only defend from ice he was already standing on. Measured on the
real stack, one who began a rush 20 m from his stand met the carrier at 10.8 m/s
of relative speed; one already in the frame met him at 1.3 m/s. Same role, same
ladder, same stand.

Two consequences worth knowing before touching this area:

- **Do not bound a route by placing the stand defensively.** Three successive
  models tried it (a step-up plan, then an approach-speed limit, both now
  retired for a live carrier) because an ice-frame seek could only reach a spot
  by charging it. The route regulates its own approach — by the same physics, in
  the frame where it means something, continuously rather than once per dispatch
  — so a placement bound on top is two controllers on one axis, and it measured
  as one: the stand landed within 0.3 m of wherever the defender already stood
  and he never closed on anybody.
- **A ride velocity is a commitment with no terminating condition.** A stand only
  gets one when the role really produced a stand. A degenerate "hold where you
  are" fallback that also rides a man does not hold — it matches his velocity
  forever, and it walked a pressurer out through the end boards behind his own
  net. `AISteering.is_rideable_anchor` is the structural backstop; the role is
  still expected not to publish one it did not earn.

Both halves are pinned by `tests/unit/ai/test_defensive_routing.gd` (share of
time in shape, and whether a defence pair gets blown by) and
`test_rush_gap_discipline.gd` (up-ice speed and excursion at the meet). Those
measure the BODY over multi-second rushes, which is the only honest home for a
claim about a route — a single dispatch cannot see one.

## DZONE is a shape, not a location

The raw possession table flips to DZONE the instant the puck crosses our blue
line with an opponent carrying. Slotting on that alone re-slots still-
backchecking forwards onto zone posts and dissolves the backcheck at the line, so
the brain holds the rush/recovery shape until the bodies the coverage assumes
have arrived (`AIRushRead.coverage_ready`, gated by
`AIPossessionState.coverage_read`). Get back, get set, THEN take your man.

Three rules keep the gate honest:

- **Parity, not everybody**, capped at the bodies we have. Requiring every body
  is the mirror image of the last-man bug — instead of five bots each deciding
  they are the last man back, four home bots wait on a fifth who is late. A team
  genuinely a man short would never satisfy it at all.
- **Bots only.** A loafing human must not inflate a requirement he will not
  satisfy, nor count toward the cap. The bots' structure is ready when THEIR
  bodies are home.
- **No coverage clause, and no time floor.** Asking whether men are already
  covered is a MAN-coverage test gating entry into a ZONE, and a correctly
  executed zone fails it — so the gate could never be satisfied by the shape it
  gates, and a time floor would end up doing all the work. A home-ness predicate
  is monotone in the recovery it waits on: the rush roles themselves bring
  everyone home, so it clears on its own and needs no bound.

The gate is asymmetric on purpose. Becoming UNSET is instant — the accounting is
false the moment a man is unaccounted for — while leaving coverage takes a
sustained stretch, because a body straddling the blue line to pressure the point
is not a broken structure.

## The defensive verbs

A defensive role should read as *pick who is mine, call a verb, add my extras*.
Three verbs exist as shared code; the roles compose them.

| verb | seam | callers |
|---|---|---|
| **cover a threat** — take the ice between him and our net, in the feed lane, riding him | `AIRoleHelpers.cover_threat` | MARK, the 5v5 zone soft-lock, TRACK_MID, RUSH_D2 |
| **close the carrier** — read his approach, hold the ladder's gap, angle him off the middle | `read_carrier_approach` + `carrier_stand` | PRESSURE, RUSH_D1, and the read alone for TRACK_PUCK |
| **go get the puck** — race it, or hold the pre-contain stand when somebody else has won it | `AIRoleHelpers.chase_puck` | CHASE |

`AICarrierApproach` is the carrier half's subject: his position and velocity, the
line he retreats us down, the route he has left, and his pace along it. Three
roles derived those five from scratch with three different degenerate-case
guards; they now share one read filled into caller-owned scratch.

Two things deliberately do NOT go through the second verb. **TRACK_PUCK takes
the hip, unangled** — a backchecker is behind the play and catching up, so he has
no inside to take and shading one would only lengthen the chase; he shares the
read and places his own target. And **PRESSURE cannot simply call a verb that
fills the decision**, because its argmax sits between the stand and the answer:
it consumes `carrier_stand` as the ring's centre and `inside_dir` /
`inside_shade_m` as a floor on the candidates, then sets the target itself.

A loose puck is not a fourth subject — it is a carrier nobody is holding. Both
of the first two verbs already reach it through `resolve_defensive_play_ref`,
which answers with the puck when no one carries, so PRESSURE closes a loose puck
on the ladder and TRACK_PUCK takes its hip with no special case. `chase_puck` is
the same idea from the other side: its DECLINE branch is the closing verb
applied to the puck (`fill_approach` on the puck, then `carrier_stand`), which
is what makes the pre-contain point exactly the stand RUSH_D1 will want when
possession flips rather than merely a similar one.

The election of WHICH body runs the race is not part of the verb and stays in
`AILoosePuckChase` / `GameManager` — the verb answers "do I go", the election
answers "am I the one who may".

Still unfactored: **hold a post** — the per-role fallbacks and their anchor
constants. The open question is whether it should be a verb at all: if the
assigner always names a man, the carrier, or the puck, there is no fourth state
and the constants go with it.

### The three facts a station reads, and the one that stays unread

**CONTROL** (`AIRushRead.pressure_eta_s`) drives NEITHER the hold decision nor
the station leash, and must not be wired to either. Contested control with nobody
behind you gives a retreat nothing to cover, so it cannot send bodies home; and
shrinking the leash under pressure turns an outer bound into an attractor that
drags a POINT into the corner. The pressure-dependent "give close support under
heavy pressure" belongs to SUPPORT's own positioning, which already prices
pressure. CONTROL stays published and unread rather than mis-wired. **SUPPORT**
(`has_support_behind`) and **NUMBERS** (an attacker behind my stand) are the two
that bind.

The D-vs-forward asymmetry needs **no per-position appetite scalar** — it emerges
from who is physically rearmost. In an O-zone cycle the POINTS are the rearmost
bodies (~9 m from our blue line), so they read no support and respect any man who
gets behind them: they ARE the last layer. F3's high-slot float sits ~8 m further
up-ice, reads the points as support, and holds.

And when the read says back off, the target is **not home**. Better a 3-on-2 than
a pinch that becomes a 3-on-1: backing off restores a NUMBERS LAYER and then
stops.

### The play-connection leash

`pull_into_play` is the bound nothing else supplies. Every other bound pulls a
station toward home, so without it no term can ever say "you have left the
attack" — it is what makes the support triangle CONTRACT under pressure instead
of stretching. It is denominated in a FLIGHT TIME rather than metres, because the
literature defines support by whether a pass is on. It applies only while WE
possess and only to a HOLDING station: clamping a legitimate recovery back
up-ice toward the puck would undo the coverage the numbers read just called for.

## Covering a man is one behavior, and the role only chooses WHO

`AIRoleHelpers.cover_threat` is the whole of it: take the ice between him and
our net, from inside the lane the puck would be fed to him through, riding him.
Every off-puck defensive role in the game calls it and differs *only* in which
man it names — MARK and the five 5v5 zone roles from the threat partition,
TRACK_MID from whoever entered its lane, RUSH_D2 from whoever is driving the
middle. **Man defense and zone defense are the same behavior under different
assigners**, so a new coverage scheme is a new answer to "who is mine", never
new positioning code.

Since the zone roles joined the partition it is not even a different assigner:
`TeamBrain` matches every man-covering body at once, and a zone role's AREA
enters as ELIGIBILITY — which men it may be handed — rather than as a private
search. That is not bookkeeping. Five independent argmaxes over deliberately
OVERLAPPING areas double-covered somebody on 61% of D-zone ticks, so the same
five bodies reached only 1.98 distinct attackers per tick and left the best
uncovered man at 0.064 finish danger; one matching reaches 2.64 and leaves
0.022. Its remaining hole is a man standing in NOBODY's area — eligibility
cannot reach him however free a defender is, which is the fallback-assigner
question rather than this one.

The seam is also what makes the frame rule above enforceable rather than
aspirational. When the four sites were four copies, each drifted its own way:
three led their man *and* rode him (the double-count the ladder was fixed for,
and it covers from further off the faster he skates), the fourth — the 5v5 in-zone
soft-lock, which is the most common defensive stand in a 5v5 game — rode nothing
at all and flew every pickup as a trip to a parked spot. Position and velocity now
come from one snapshot entry, so a stand cannot ride a body its geometry isn't
built on.

## The gap ladder is one ladder, and both puck-owners read it

`AIRoleRushD` (the rush gap) and `AIRolePressure` (the in-zone puck pressurer)
size the same gap off the same function, `AIRoleRushD.ladder_gap_m` — ~3 stick
lengths at their blue line, 2 at the red line, 1 stick at ours, and inside our own
zone "1 stick / contact: you are on him" (`docs/transition-defense-plan.md` §6).
This is what makes the TRANS_DEFENSE → DZONE re-election stop being a geometry
discontinuity, which §2.5 of that plan names as a defect in its own right: *the D
who gapped a carrier through the neutral zone keeps him into the zone; there is no
handoff at the line.*

PRESSURE held a fixed one-stick stand-off measured off the carrier's LED position
for a long time, which is not the same thing: the lead is proportional to his
pace, so the real cushion came out at 3+ sticks against a rush — §2.4's defect
("the correct gap for the offensive blue line, applied at the defensive blue
line") surviving in the one role that never got the fix. A defender holding it
retreated at the carrier's speed indefinitely and could be walked to his own goal
line by a player who simply skated at him.

Three things had to be true together, and each is load-bearing:

- **No anticipation lead in the anchor.** The lead existed because the anchor used
  to be a parked point that had to be aimed ahead of a moving man. The route now
  carries the man's velocity as a feed-forward, so leading as well double-counts
  his motion and inflates the frame-relative gap by `pace × lookahead`.
- **The ladder is a FLOOR on the gap, not just where the ring is centred.** The
  score is "how much does my body deflate his options", which improves
  monotonically as you close, so an unconstrained argmax collapses onto the man
  every time — the fixed lead was quietly preventing that. Clamp candidates out
  onto the gap ring rather than filtering them, or the set empties exactly when it
  has closed and the bot falls through to standing still.
- **The last-man approach bound is retired for a live carrier**, exactly as it was
  for RUSH_D1 and for the same reason. It names a stand at wherever the body
  already is, so a pressurer being walked backwards is forbidden from closing on
  the man walking him. A loose puck keeps it.

The house-gate floor that was tried first is gone: with the ladder the defender
settles at the tops of the circles anyway, as a consequence of gapping rather than
as a clamp, and the floor only widened the gap past what the ladder asked for.

### The ladder has a domain: the carrier has to be coming at us

It measures ice remaining before he reaches our blue line, which is a RETREAT
quantity — how much room he has to beat you with speed before there is nothing
behind you. Deep in the ATTACKING zone that quantity is at its maximum and means
nothing, and PRESSURE is also the forecheck's F1, who is not managing a gap at
all. Unbounded there the ladder saturates at its 3-stick ceiling, held as a hard
floor by the gap clamp, so the forechecker cannot close even in principle: his
poke jab reaches ~1.9 m, leaving a committed body check as the only engagement,
which the easiest tier disables outright.

The domain read is the shared `AIRoleRushD.should_gap_up`, not a zone test. Its
"closing < 3 m/s" trigger is satisfied by construction by a D retrieving behind
his own goal line, so the two carrier-owning roles agree at the TRANS_DEFENSE →
DZONE handoff exactly as they already do on the ladder itself.

## Determinism

Bot decisions must be replay-safe: same situation, same difficulty, same
behavior, every time. The **only** RNG anywhere in the bot is per-release
execution sampling — hands, never decision dice — seeded per bot and sampled
once per release, then held through the windup.

Domain AI files stay engine-free (no Godot APIs, no `tr()`), so the whole
decision layer is unit-testable headless.

**Tie-break on peer id, never on iteration order.** `AIThreatAssignment` and
`AIRoleSlots` both do, because `WorldSnapshot`'s dictionaries follow peer
REGISTRATION order. A symmetric geometry — two markers and two men mirrored about
x = 0, i.e. the faceoff net front — scores bit-identically, so without the
explicit tie-break the winner depends on who joined the session first and a
mid-session rejoin flips a standing assignment. Hysteresis cannot damp it: both
matchings score the same, so the retain branch holds forever.

## The goalie is tiered, but only ever as a weaker goalie

`GoalieSkillProfile` is the goalie's counterpart to `BotSkillProfile`: one bundle
of knobs per difficulty, applied by `GoalieController.setup()` onto its
`@export`s and selected per match from the lobby. Hard is every value at the
controller's authored default, so applying it is a no-op by construction
(`test_goalie_profile_mirrors.gd` holds that).

Every lever in it must be a trait a real weaker goalie actually has, so a lower
tier still reads as a goalie — tracks the play, squares up, drops butterfly —
who gives up the net and can't rob you, never as a dumb one. The knobs fall in
two groups and a tier needs both, or the ladder is only reaction latency: read
latencies (when he starts moving) and positioning / save levers (how much net he
concedes standing still).

**The skater AI's goalie model is a MIRROR, not a second tier.** The read model
the bots score against — leg and arm delays, drop time, lateral accel ramp, arm
deploy — lives as static vars on `AIActionScoring` and is synced from the match's
profile by `set_goalie_profile`. A new tiered goalie knob the shot model also
reads must be added there too, or the bots go on scoring against the Hard
goalie while the net in front of them is an Easy one.

---

## The models in detail

Every multiplier in the utility scoring is meant to be a piece of data the bot can physically **"see,"** and each evaluation is a model built from those quantities — not a hand-tuned curve shaped to feel right. The models do the work: a grounded model generalizes to situations no one tuned and stays honest when an upstream number changes. Concretely:

- **Shot danger** (`open_net_danger`) — the open net across the goalie holes (top/bottom corners + five-hole), each scored as the net it clears past the goalie's reaction-gated, height-appropriate cover. The goalie occludes as a **body, not a paper cutout**: each band's cover is a disc of that radius (he squares to the puck, so he presents his cover half-width perpendicular to the sightline from any bearing), and the covered interval is the disc's **tangent cone** from the shooter's eye — for a frontal shooter this reduces to the old net-plane projection, but from a sharp angle his *depth* walls the cross-crease lane, which is what zeroes the hopeless side-of-net fire. A corner only scores what remains after the puck's **clean-entry inset** off the pipe (post radius + puck radius, the same inset the aim point buys — a HARD geometric requirement, subtracted outright); the shooter's own execution spread (`aim_spread_rad`) then **softens** that window to a partial make (`_soft_make_angle` — `window²/(window+spread)`, which asymptotes to `window − spread` for a wide window and reduces to exact geometry at spread 0) rather than hard-cutting it. This is the "aim good, shot off → the goalie makes saves" model: a window comparable to the wobble still scores, so the bot **takes** the shot and gets **saved** on the ones that miss, instead of the old certain-make-only cut that declined every shot the goalie could reach (leaving the keeper with no save to make — its misses all clanked iron). The aim sits at the window **centre** (`DEFAULT_CORNER_BIAS = 0`, synchronized with the centred-aim make-prob the score integrates) so the wobble splits a taken shot into goals / goalie saves / posts symmetrically instead of throwing the whole tail onto the pipe. Per-tier, the shot scatter (`shot_aim_error_rad`) is a SELECTIVITY dial, not a save dial: the shot-outcome sim (`tests/unit/ai/test_shot_sim.gd`) showed a wider spread demands a wider window under the make-probability model, so the bot shoots LESS and buries a HIGHER fraction — bumping it does not "trim" a tier's scoring by feeding the goalie. Without the inset a fully-deployed goalie left a few-cm un-hittable "sliver" open at any range that out-scored working closer (the launch-it-from-the-point bug). The five-hole pays the same honesty as the puck's **diameter** against its gap, then the same soft partial-make against the shooter's spread (without the fit, razor five-holes the hand can't thread out-scored real corners through the flat-loft tie-break, the "five-hole happy" bug): what scores is the clearance, so the standing ~0.16–0.20 m slot is the razor-thin look it really is and the live five-hole is the down goalie's slide leak. **HIGH holes ride the manual angle ladder** (`docs/elevation-rework-plan.md` v3): every shot fires at FULL pace (the bot's committed `bot_wrister_power_t` is always 1.0) and the bot PICKS THE RUNG — the elevated level whose set-angle arc arrives highest inside the top band without missing high (`_best_high_rung` over `AISkaterCaps.loft_tans`, the bot's own per-gear ladder), the same read a practiced human makes, so the bot flies the identical arc the live release produces. The band has a floor (the **pad-top seam**, `GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M` 0.86 m — in tight only a steep ladder has a rung that gets up in time, the roofing gradient), a ceiling (`HIGH_BAND_CEILING_M` ≈ the scoring cavity's top — at range steep rungs would sail, and bots never deliberately miss high), and a STANDING keeper's plane bar (`GoalieStickRules.PADDLE_HEIGHT_M`; a down goalie's paddle is on the ice and bars nothing). **The rung read is HEIGHT-RESOLVED and reads his POSTURE.** The ladder aims its three rungs at goalie-posture landmarks (LOW over the butterfly pad 0.41 m, MID at the armpit 0.70 m, HIGH upstairs 0.99 m — plan doc §1), and the hole model resolves them the same way, split down one seam: **shape picks the rung, the race scores it.** `_best_high_rung` selects on `GoalieAnatomy.structural_cover_half_width_at` — pads/trunk/head only, no reaction term — because cover needs a `t_read` that needs a pace that needs a rung, and resolving that circularity by guessing would make the choice depend on its own answer. `_cover_at_height(y, …)` then races the hands, the butterfly drop and the lateral push at the CHOSEN height. Both halves come off one `_hole_rung` read per hole (`_rung_pace` / `_rung_arrival` derive from it), so the score, the loft and the aim cannot describe different shots. The eligibility floor is **his pad top, not a fixed seam** — standing that IS the old 0.86 m constant, but once he is down the pads collapse to 0.28 m and the 0.28–0.86 band becomes real targets; likewise `_delay_at_height` charges the ARM read for a puck over his pads, so a keeper sealed at butterfly hand height (0.49 m) must physically lift to meet an armpit shot and usually cannot. Consequences: the standing read is bit-identical to the two-band model (no calibration moved), and in tight — where the league ladder cannot reach the standing seam at all — dropping the keeper now changes the answer from FLAT to an elevated rung, which is exactly the shot the old model was blind to. `HOLE_COUNT` stays 5; the rung loop already iterated all three. One deliberate holdover: above the standing seam the structural cover is still floored by `HOLE_BAND_CORE[HIGH]` (0.40), which was measured for that band and which the raw collider list under-represents (shoulders and arm roots are not colliders) — replacing it is its own change. The stick's vertical extent is likewise untouched (it still floors cover everywhere below the seam though the blade is 0.07 m tall), because narrowing it makes the in-tight flat shot better and `test_goalie_low_cover.gd` pins the current behavior against measured live-keeper results. The live goalie needs NO change: it stops pucks with its real body boxes, so the armpit and over-pad lanes were already physically correct. A **down** goalie still concedes the arm extension (his glove starts at the pads; the butterfly's defining trade). A release on/behind the **goal line scores 0** and is never clamped into a phantom in-front spot (the wraparound is a carry, not a shot). Distance, angle, and coverage all *emerge* from the geometry — there are no distance/angle curves. The five-hole is a physical between-the-legs gap, so it foreshortens with range like any target and opens only when the goalie is caught moving (`goalie_unsettled_factor`), which itself **fades over the shot's flight time** because the goalie re-settles before a long shot arrives — this is what kills cross-ice shots at a mid-slide goalie. (No armpit/body-side hole: it only opens when the goalie commits his arm elsewhere, a condition the model can't see, so a static seam would be a phantom target — dropped until a real arm-commitment model exists.) The best hole is the score, and the **same** hole drives the shot's loft and aim (`best_shot_loft` / `best_shot_aim`; pace is always full), so what the bot scores, elevates for, and aims at are one shot. The goalie's modeled behavior (freeze-on-shot, leg-vs-arm reaction split, glove reach out to `glove_max_x_outward`) is kept in lockstep with the live `GoalieController`: the baselines are shared `GameRules` constants, and the difficulty-varied reads (leg/arm delays, butterfly drop, lateral-accel ramp, arm deploy) are static vars on `AIActionScoring`, synced to the match's `GoalieSkillProfile` via `set_goalie_profile` where `GameManager` selects the tier — so the bots score their shots against the goalie they actually face, on every difficulty. The whole model is pinned by an ordering-calibration table in `test_ai_action_scoring.gd`. The shoot-now and carry-candidate evals both read the keeper through **react-then-push** (`predict_goalie_pos` from his *actual* position toward the release's arc-square, over everything the play gives him — carry time + charge + flight — with his real read delay and the `lateral_accel` **push ramp**; pushes accelerate onto the edge, they never snap to speed) and, on the depth axis, through the **rush backflow** (`planned_goalie_depth`): he gives ground down the live keeper's own chart / backflow curve (`GoalieBehaviorRules.target_depth_for_puck_distance` / `rush_retreat_depth`) as the play closes on him. That half used to be missing — the planner held his depth frozen wherever it happened to be — and because the coverage model is a **tangent cone** off his body, a keeper pinned out at challenge depth appears to GROW as the shooter closes: a doorstep release read as a fully covered net, so the in-zone gradient pointed *away* from the goal, no drive or cut could out-score standing still, and the compete fell through to whatever was safest (the bail-out back pass). The correction is deliberately **retreat-only** — it may pull him in, never push him out — because his live depth is replicated truth set by a lot the planner can't see (post seals, backdoor caps, lateral-pressure pull, recoveries), so a static read returns it unchanged and only an approach moves him. Any normal-pace play gives the push time to arrive square (long-range and wide-angle looks stay dead), but a **hard lateral cut in tight is an arc race his ramp genuinely loses** — the doorstep drive-side window. That is what makes a 1v1 against an aggressive challenge terminate in a lateral drive + shot instead of a stalled carry, and it prices lateral playmaking generally: cutting across the crease can out-score standing still exactly when the cut physically beats the push.
- **Carry safety** (`reach_clearance` / `best_evade_point`) — a reachable-set pursuit-evasion model. Each skater is a bounded-accel body: over a short horizon its stick can touch anywhere within (½·A·(T−reaction)² + stick) of its **momentum-projected** position. So a hard charger's reach rides downrange to where you *were* — the space he vacates is clear (beat him by letting him overshoot) — while a contained/jockeying defender's disk stays on you (real containment) and a stick on the puck stays a strip threat. Two seam reads share one sampler: the **max-clearance seam** (`best_evade_point`) is the honest "can I keep the puck at all" evadability read, and the **objective-directed seam** (`best_evade_point_toward`) is the playmaking one — lexicographic in the same currencies, it takes the *safe* envelope sample (clearance ≥ a blade of air, `EVADE_SAFE_CLEAR_MIN_M`) with the most **progress toward the live carry anchor**, falling back to pure max clearance only when nothing safe exists. The directed seam is what the poke-evade deke latches and what enters the carry-candidate compete, so the bot beats its man *on the way to its spot* instead of being herded to wherever is emptiest. Handling envelope width rides the shared blade caps (uniform under attributes v4 — the stick-length gear stage re-differentiates it), threading tighter seams. This replaced a proximity model (`puck_safety`) that floored *every* close defender to "dangerous" — it couldn't tell an evadable charger from a stick on the puck. The **boards bound the seam search**: the handling envelope is intersected with the playing surface (off-surface samples are rejected via `board_gap_m` — the puck can't be handled through a wall; a wall alone strips nothing, so the clearance primitive stays defender-only), which makes the wall-pincer emerge — pinned against the boards, half the envelope is illegal, the best legal seam runs *along* the wall, and its clearance from the sealing defender is honestly small, so a wall-pinned carrier's evadability collapses and it moves the puck before it dies there. The same reach model gates the carrier's **body steering**: with the puck, opponent repel is threat-gated and route-around (`AISteering._carrier_threat_repel`) — each defender repels from the closest point of his momentum-swept reach (a beaten man exerts nothing; a charger sweeping through the carrier's spot produces a perpendicular *sidestep*, since his body is still a collision even when the puck is safe), and the summed force loses any component opposing the anchor direction, so pressure bends the carry line but can never reverse it (retreat is the carry *deliberation's* call, never a reflex — this killed the old raw-proximity corral where any defender within 4 m out-muscled the anchor pull and herded the carrier backwards). The model also drives **blade-level puck protection** (`best_handle_protect_point` + the carrier's `protect_offset`/`protect_gain` mirror): the state machine swings the carry mouse from the presented-forward spot toward the protected seam of the handling envelope alone — body between puck and checker — weighted by the **safety the shield buys** (seam clearance − forward clearance). HOW MUCH and WHERE are two seams: the weight reads the MAX-clearance point, but the AIM reads the **directed** one (`_best_clear_point` with the presented-forward spot as objective, exactly like `best_evade_point_toward`). Aiming with max clearance was a bug — it is the point diametrically opposite the checker, and a checker only makes shielding necessary by being in FRONT, so the puck went to the BACK hip whenever the shield engaged and stayed there while the man was live (measured: 120–180° off the carry line at full gain against any defender the carrier was skating toward — the "slips through traffic, then keeps carrying it behind him" look, and a puck on the back hip is on neither a shot nor a pass). Directed, the seam grades with the checker's bearing (180° → 90° → 0° as he steps off the line) so the shield goes exactly as deep as it must, and the max-clearance fallback restores the full far-hip shield under a real jam where nothing in the envelope is safe, so it engages exactly to the degree shielding helps (necessity: the forward puck is covered; ability: a safer seam exists) with no hand-tuned pressure floor, and never against a defender the carrier's body already screens — a **beaten/behind man is filtered out** (`PROTECT_SCREEN_BEHIND_M`, projected to the evasion horizon) so the carrier squares to the net the instant it clears its man instead of shielding a trailing checker. The discrete poke-evade moment picks between three committed maneuvers, by what each answers: a **brake check** (`prefers_brake_check` — real brake key held for the evasion horizon, exit direction on the stick) against COMMITTED pressure, when the checker's sweep flies past the physically-stopped puck (`brake_stop_point`, v²/2a) and the threat-gated repel then lets the carrier burst straight past him; a **fake-then-cut deke** (`deke_cut_side`) against PATIENT containment — the one pressure the other maneuvers can't answer, since both only exploit commitment the defender makes on his own. The deke *manufactures* the commitment: the eval runs the reachable-set model against the defender's post-bite state (he reads the fake for the reaction window, then matches it at his real per-build accel, loading wrong-way momentum his cut-side reach can't unwind), and fires only when the cut side is covered NOW but clear of everyone after the bite — self-calibrating (an agile defender bites harder, so you *can* deke the good defender; a pylon barely moves, but him you simply beat). Execution is a two-phase committed window (fake ~0.3 s / cut ~0.2 s, the exact durations the eval priced) with the carry cursor selling the fake WITH the puck and snapping across for the cut — the toe-drag look emerges from the blade-chases-cursor mechanic — triggered both off imminent pokes and by a dedicated **containment trigger** (a patient container never closes fast enough to register as a poke, which is why stalemates used to stand still); and the **cut** latched toward the directed seam (past the man, cutback included) for clearance that already exists. The carry mouse is also clamped a blade-length inside the boards (`CARRY_BLADE_WALL_MARGIN_M`) — the blade IK chases it, and a target at the kickplate slammed the stick into the wall and knocked the carried puck loose. Seam/protect/brake reads are gated by the `protects_the_puck` cognition tier (`BotSkillProfile` — Hard/Normal shield, Easy carries naively presented so a newcomer's poke-check works).
- **Pass lanes** (`lane_clear`) — reach-vs-flight-time reachability: a defender blocks iff they can get a stick onto the puck's path before it passes. Faster pucks thread better for free (less time to close). The **saucer** variant (`lane_clear_saucer`) is the same model under the LOW loft's real flight kinematics: during the over window (fixed 2.2 m/s vertical launch above the `PUCK_AIRBORNE_HEIGHT_M` blade plane) a defender's reach collapses to their body radius — sticks fly under it, only a torso blocks — while on either side of the window (just off the blade, or landed) full stick reach applies. Airborne carry = launch speed × hang time, and the flip must land with runway before the tape (`saucer_max_launch_speed` — an airborne arrival flies over the receiver's grounded blade), so the carrier scores each receiver twice — flat at the magnet pace vs. saucer at min(magnet, receivability bound) — and lets EV decide (`_pass_variant_ev`, saucer paying `SAUCER_EXTRA_MISS_PROB` for the landing): a close-quarters contested feed becomes a genuinely *soft* flip over the mid-lane stick, and below ~6.5 m no legal saucer exists at all. **Receiver commitment** is priced into the same completion model as an execution-miss term: a receiver mid-cut curves off the straight-line lead by the exact tangent-deviation of its heading arc (`receiver_heading_uncertainty_m` = R·(1−cos ω·t), from the smoothed per-skater turn rate `WorldSnapshot.heading_omega_by_peer` the host shares off `AIAccelerationTracker`), and those metres add to the passer's own aim spread in `pass_miss_prob` — so a feed into a hard pivot reads as the low-percentage giveaway it is and the carrier waits for the receiver to come out of the turn, while a settled receiver (ω→0) pays nothing and the quick feed is unaffected. It is a running estimate (confidence built over time), gated by the `reads_receiver_commitment` cognition tier (Hard/Normal read it; Easy is blind and chucks feeds at turning players).
- **Reception geometry** (`AITrajectory.solve_reception_gate`) — where a loose puck comes into a receiver's reach, solved on the puck's REAL path (ice friction + rounded-corner board caroms, the same integration the chase election and the shadow-puck comparator use) rather than the straight ray off its current velocity. In open ice the two agree, which is why the ray survived so long; on a **rim** they do not, and both lies decide the play — the arrival time is measured along a chord instead of around the carom arc, and the incoming direction is the *pre*-carom one, so the receiver squared his blade ~90° off the line the puck actually arrives on. (Clamping the phantom ray back onto the ice, the previous fix, corrected neither.) One walk per receiver feeds all three consumers — the side-stand stance, the timing gate, and the parked blade aim — and each step is tested as a **segment**, so the walk stays coarse enough to run per-tick while the ray/circle root gives the exact sub-step crossing. It also answers "is this coming to me" by whether the path ever **closes**, not by a dot product against the current velocity: a rim running away down the far wall is closing, it just has a corner to turn first, which is why the setup used to start a corner late. Boards-hugging gates are then played as a **wall kill** (`_wall_kill_aim`): the stance side is forced to the rink-inward normal (the other side is inside the glass) and the blade target is pushed ONTO the wall surface, corners included — a blade parked out on the path line leaves exactly the gap the puck squirts through, which is the retrieval a real player makes by putting his stick on the boards and letting it come.
- **Loose-puck retrieval is two reads, not one** (`AILoosePuckChase`) — the **election** answers "who runs the race" and names exactly one chaser per team (momentum-aware intercept, incumbent hysteresis, sprint-aware caps, and the friction + board-aware path walk for EVERY loose puck — the walk used to be gated above 4 m/s, which on 0.05-friction ice left a 3.9 m/s roller, one that travels 9.5 m inside the race horizon, elected off a straight-line lead capped at 1.95 m that runs through the boards; race times are then solved to the sub-step so bots inside one 0.25 s walk step of each other resolve on geometry rather than falling through to the peer-id tie-break); the **incidental reach band** (`puck_comes_to_reach`) answers "is this puck coming to *me*" and is not the election's business at all. A single election is right for a puck 15 m away and wrong for one whose own path runs through a bot's stick — losing the race by 0.3 s is no reason to hold your station while the puck slides past your skates, which is the most visible way an off-puck bot reads as broken. The band is reach + one stride, gated by the bot's calibrated ETA against the puck's own time to the crossing point, so it self-narrows with puck speed (a slapper crossing 3 m away in 0.1 s is nobody's incidental pickup) and stays "extend the stick", never a second chaser abandoning his job. Segment-wise along the walk, because at rim speeds the 0.25 s samples step clean over a body the puck passes a metre from. It overrides the one-timer camp and the race-lost decline (inside your own reach there is no race to lose — you contest it), and yields only to a **dead** puck (the goalie-smother `-1` election) or to a **teammate already first to it** (below).
- **Teammates don't stab at each other's puck** (`AILoosePuckChase.teammate_first_to_puck`) — the contested-pickup rule is symmetric by design and stays that way: two blades on the same loose puck means nobody is awarded it and the puck squirts free, which is right for opponents and right for a genuine jam (three sticks whacking at it in the crease *should* leave it loose; the faceoff draw is the same rule). What was wrong is that our own two bots manufactured jams — converging on a loose puck, both getting a stick on it, and mutually denying each other with a reattach cooldown on both blades. That read as two players arriving together and both missing. The fix is upstream of the contest, never in it: when a teammate's blade is nearer the puck (and near enough to actually be taking it), the second bot takes his stick off — the same pull-back the post-strip engagement cooldown uses — and the reach band above declines to fire. Deadlock-free by construction: yielding requires the *other* blade to be nearer by more than `YIELD_MARGIN_M`, which cannot hold in both directions, so two bots can never both yield and leave the puck sitting.
- **Race commitment is per-path, not per-position** (`loose_puck_race_lost`) — a chaser declines a race an opponent has already won, but only to an opponent actually *running* it: on the puck, closing on the point he'd meet it at, or standing where the puck's own predicted line runs through his contest band (the downstream interceptor who legitimately waits still). The ETA model prices everyone's hypothetical sprint-from-now, so without the commitment test a flat-footed body 15 m off a rim's line vetoed the chase — and with both teams declining on phantom winners, the puck sat between two staring teams while our chaser *retreated* to the pre-contain point. Fast pucks used to skip this test on the theory that momentum encodes commitment; it doesn't — `path_intercept_time` asks whether a body *could* be there, never whether it is going. A lost race is then only *declined* when declining buys something: the decline exists to keep a body between the collector and our net, which is worth a chaser only when there isn't already one. `_has_containment_behind` answers that with **two reads OR'd**, because each is structurally unobtainable in the regime the other covers — a teammate qualifies if he is GOAL-SIDE of the pickup, *or* if he can reach the **house gate** (`AIZoneCoverage.HOUSE_TOP_DEPTH_M` off our own goal line) inside `AIRushRead.LATE_MAN_WINDOW_S`. The goal-side half is the forecheck: refusing it is why a dumped-in puck was collected with nobody within 20 m — measured at **100%** of the loose window with zero chasers on a routine dump-in. The house half closes the mirror hole, which is not symmetric with it: when the puck is the DEEPEST object in our own end — rimmed into our corner or around behind our own goal line — **no teammate can be goal-side of it**, so the valve read "nobody is covering" when the truth was "everybody is covering, the puck is just behind us", and since the election makes only ONE bot per team eligible, that single unearned decline was a whole-team no-show (measured: 93 of 98 idle ticks, puck loose 0.8 s at 8.1 m/s, nearest man 13.4 m and closing, all three bots in OFF_PUCK). Re-phrasing containment as a race — *can a teammate beat the collector home?* — does **not** fix it and must not be tried again: the race runs to `best_opp_meet`, and when the puck caroms behind our own goal line that point IS our net, so the collector is already home and nobody beats him there. Any guard measured against the PICKUP dies that way; the house read measures against OUR NET, which is why it survives. Doctrine behind it (researched): "don't chase" means don't pursue a puck CARRIER into a low-danger area and turn your back on the slot — a LOOSE puck in our end is always pressured, *the nearest player pressures and everyone else adjusts so the house stays covered*. So the question is never "may I go?" but "if I go, is the house still covered?", a numbers read. The case the decline was built for survives it: the genuine last man, mates caught up-ice, has nobody who can hold the house and still declines to cover the net front. Bounded by `tests/unit/ai/test_loose_puck_engagement.gd`, which asserts the aggregate ("did *anybody* go?") over multi-second sims, since every individual bot's decision in that failure is defensible and only the team-level total shows it.
- **Dumps are searched RELEASES, priced where the puck stops** (`AIActionScoring.dump_clear_candidates` / `solve_dump_in` over `AITrajectory.puck_release_landing`) — not a hand-placed target with the giveaway priced at it. At any pace the bot can produce the puck out-slides the rink several times over (the softest wrister runs 102 m, the quick pass 200 m, against a 59.7 m surface), so an aim point is a place the puck passes through at speed; pricing the concession there understated it wherever the aim was far from our net, which is why a clear read cheap enough to beat carries that had real space. The landing solve is CLOSED FORM — between board contacts the motion is a straight line under constant deceleration, so each leg is exact arithmetic and only the contacts need solving — because the stepped walk is ~1 µs/step and a full runout is ~270 steps, the same cost class as the whole `controlled_space` fan. Board geometry mirrors `clamp_to_rink_inner` including the corner **arcs**: a rim into the corner is the delivery this exists to price. The two dumps are different errands. The **DZ clear** enumerates the launches it is LEGAL to make and takes the one we concede LEAST by. Two doctrine filters say what a clear is, and they are filters rather than penalties no price can outvote: a launch that reaches their goal line starts an icing race we have no reason to run, and a launch that comes to rest inside our own zone did not clear anything however certainly we would win it. Among the survivors the RACE decides, because depth cannot: fired at the fixed quick-pass pace from a pinned corner every legal landing is deep (the softest release the bot can make out-slides the rink twice over), so which deep spot is right is entirely a question of who gets there first, and the clear rims to the wall our posted man can actually win. Depth survives only as the tie-break between clears that cost the same. The old objective — nearest their blue line — ranked candidates in METRES while `_best_dump` priced the winner in CONCESSION, so the search could hand over a spot we had no chance at while a spot we would win outright sat one bearing away. It stays a pure concession (no gain term), so its value still cannot exceed zero: paying it for the race it wins was measured to make a clear score positive outright and beat CARRYING where a clean regroup existed, and that is a different change from letting it rank its own candidates by the number it reports. The **NZ dump-in** is offensive — get it deep, win it back — and is scored on the race to the resting spot, with no icing branch at all, because it is only offered past the red line and icing needs a release from our own half. Its search runs **bearing x PACE**, and the winning pace is carried out to the release: bearing alone cannot place a dump, because every pace the bot can produce out-slides the rink several times over, so at a fixed hot pace the only deliveries that die in the zone are the ones banked steeply enough to shed 40-60% on contact and a centre chip squares off the end boards and comes BACK to neutral ice. That is why it fires **FLAT on the charged wrister** rather than as a one-tick quick pass (the clear keeps that): a charged release normalizes `(dir.x, tan, dir.z)` at its power, so any loft spends pace going up and the puck's ground speed stops being the number the ladder solved the runout from. The **keeper is a body in the race** (`keeper_collects_first` - his real puck-play build against a skater's, no margin term, untiered): without him the doorstep - the spot `position_potential` rates highest on the whole rink - read as a free recovery and the search aimed there. The whole gain is then **realization-discounted** like every other future-value read, which is what makes dump-vs-carry an even compete rather than a deep spot's raw value against a near spot's realized one; the chase clock is momentum-honest `time_to_arrive` (it was `distance / max_speed`, an instant full-speed sprint worth about a second over a routine chase, and worth it in exactly one direction) — and so is the recovery PROBABILITY beside it (`chase_recovery`), which stayed a raw-distance race long after the clock was fixed: one function, two clocks. It is now an ARRIVAL race, nearest by ETA rather than by metres, with the contest band expressed as the TIME a stride buys at reference pace (`CHASE_CONTEST_MARGIN_S`) — the same physical measurement the metre form named, in the currency the race is actually run in. A metre band is only a contest band at the range a metre means something; over the 30–40 m a clear travels, two metres is a rounding error, so the distance race saturated to 0 or 1 on essentially every placement and the whole concession became a step function of who happened to be standing marginally nearer. Both dump searches keep it affordable with EXACT prunes rather than budgets — the clear stops pricing the moment a free candidate exists (every concession term carries the loss probability as a factor, so a certain recovery concedes exactly zero and nothing dearer can win), the dump-in skips any candidate whose win-outright ceiling already loses, and `_first_arrival` skips any chaser whose bare `distance / speed cap` is already beaten; the compete sees the carrier's **drive-in** credit, not just his next second; and there is deliberately **no third giveaway bar for the dump**. A shot clears `SHOT_MIN_VALUE` and a pass `PASS_MIN_VALUE` because each is a RELEASE chosen on its merits, and a release that merely ties the carry must not win; the dump is not chosen on merits at all but is a **residual** — what is left when the strip-point-priced carry has non-positive EV, there is no drive-in to skate into, and no qualified fire exists. Never score the dump and enter it in the value compete: that asks a dumped puck's whole future to be commensurable with a carry's next beat in one currency at every point on the rink, and it is not — the dump reaches a spot the carry is forbidden to name (its credit is horizon-capped), so it out-scores an OPEN carrier on an EMPTY RINK, it wins by being the SAFE play whenever the carry is contested even though a failed entry and a dump-in cost within a hair of each other, and the softest release on the ladder keeps winning because its landing solve puts the puck in the slot. Ordering, not comparison. In our own zone the drive-in gets no vote for the same reason: it is benefit-only, so it is positive for any carrier with a sliver of a lane and would veto every clear a pinned bot ever wanted to make; past centre it earns its vote back, because there the alternative is an offensive dump-in and a free entry must never be flung away. **Icing is a RACE, not a distance**: `GameStateMachine.check_icing_for_loose_puck` runs the hybrid race when the puck reaches the goal line, so legality is bought by the PATH — a steep bank into the near boards sheds 46–62% where a glancing rim sheds ~7%, and the carom lengthens the route, so the puck dies in neutral ice and no race is run. Loft does NOT buy clock (a chip's hang time is frictionless, so it arrives marginally sooner); it buys passage over sticks. The 5v5 two-leg rim pricing is retired rather than ported — it existed to price a bank the release could not execute, and a searched release makes the distinction meaningless. Bounded by `test_puck_release_landing.gd` (cross-validated against the stepped integrator: 0.25 m open ice, 0.6 m one carom, 2.5 m laterally through a corner multi-carom, which is the closed form's honest weak case) and the dump fixtures in `test_role_carrier.gd`.

- **Last-man discipline is universal, and every station now answers it the same way** — the three-fact read on `AIRushRead` (control / support behind / numbers), never a private per-station race. *Stations that hold forward ice while WE possess* — the 5v5 points, the forecheck line pair, F3, the high slot, the trailing valve — go through `offensive_station_target`: hold the forward stand, or fall back to the defensive home post. There is no intermediate stand. *The two NEUTRAL shapes* — 3v3 FLANK and 5v5 DBACK — go through `neutral_station_target`, the same read with a different concession: a slow loose puck is not a rush, so giving up the stand restores a **numbers layer** (`numbers_floor`, floored at the house gate) instead of sending the body to a post. NEUTRAL also demands a **second clause the others do not** (`home_layer_behind_me`): somebody home behind me, and not merely nobody past me. `may_hold_forward_stand` is an OR, so the reactive half alone lets the genuine last man hold his forward stand whenever nobody has ALREADY beaten him — which in a loose-puck race is everybody, because both teams are converging and nobody is behind anybody yet. Three bodies then arrive within a few metres of the same puck with no layer at all, and the man gets behind them *because* they all stepped up. The clause is antisymmetric (strictly deeper, by a cover envelope, with the elected chaser excluded — he is committed to the puck and holds nothing), so exactly one body draws the layer and no two can each appoint the other; 3v3's layer stand is then the same blue-line post 5v5's back pair already holds. PRESSURE's last-man step-up is the one thing apart (`settable_stand_depth`, a rendezvous clamp on how far a challenge may lunge). The **counter-channel race** these replaced is gone: a per-station conjunction over every attacker's outlet/retrieve channels, sampled at five path stations, which. It survived longest in NEUTRAL, where the puck is loose by definition and every attacker was still priced an OUTLET channel as a max-speed pass nobody was in a position to throw. Resurrecting a graded race needs a reason the shared read cannot serve, and a measurement — NEUTRAL is ~0.1% of live play.
- **Pressure** (`_opponent_density`) — distance falloff × forward-cone (cube of cosine): defenders behind or beside the play pressure far less than those in front.
- **Positional value** — a two-regime value map split at the attacking **blue line** (`in_offensive_zone`), gated on the **carrier's** position, not the candidate's. *While the carrier is in the offensive zone*, every (valve-guaranteed in-zone) candidate is priced by the value seam (`score_shoot_value` → `AIShotValue`) — xG is a strictly better read than any positional proxy once a goalie is in play, so `position_potential` is never consulted there. There is **no possession floor**: the flat `OZ_POSSESSION_VALUE` additive that used to sit under this read is retired. It existed because the old five-hole currency went dead-FLAT when no shot was available — every candidate returning the same constant, the argmax falling through to turnover cost, the carrier orbiting the perimeter. A smooth xG surface does not go flat (a spot with no shot *right now* still scores by its distance and angle), so the gradient is real and needs no anti-noise constant standing in for one. Behind the goal line every shot is a hard 0 by construction, so a candidate back there is worth only the pass OPTION it opens — which is the right answer: that ice has no value of its own, it is worth the play it sets up. Rink-side walkout spots need nothing special; just outside the post is a genuinely high-value look on the seam. Candidates also price the **pass OPTION** they open (`_candidate_pass_option`: cached per-teammate spot values × the lane from the candidate, discounted as a future action) — credited as the *improvement* over the same read at the current spot, so a lane already open belongs to the live pass (fire wins ties) and repositioning earns option value only where it genuinely reopens something —. A **carry CONTINUATION** credit (a second speculative leg to the slot) used to sit alongside the pass option and is **gone** — it existed only because the five-hole currency went flat in the zone, leaving the cut-in and the perimeter escape reading the same so the safety gradient alone picked the orbit. The seam's one-ply surface already separates them by the same margin the two-ply read used to manufacture (2.2x vs 2.1x on the spun-off fixture), so the whole second leg was inert; see the removal commit for the measurement. Paired with the **retreat ring** (5 back-arc candidates at 2× the local step — the committed peel-out no other candidate represented), this is what un-pacifies a contained carrier: backing out to reopen a lane now out-values grinding on the defender, a walled-off entry regroups with possession instead of dumping, and the clears/dumps recede to true last resorts. The **net is a carry/blade obstacle** (`carry_path_blocked_by_net` / `net_safe_blade_target`): a carry candidate whose straight route crosses either cage prunes, two **post-walkout** candidates appear whenever the carrier is behind a goal line (the natural wraparound approach in the OZ, where the goalie's RVH/VH post seals are the counter), and the carry cursor is swung around the nearer post whenever its chord crosses a frame, so the blade never reaches through the mesh (stick-on-net contact dislodges the carried puck — the old behind-the-net giveaway in both zones). Behind-the-goal-line ice is **playable** in the candidate rings for a carrier already back there (`AIRoleCarrier._candidate_ice_legal` — off-surface and in-cage samples still reject, and the route check still prunes anything through the mesh). Without that the walkouts were the *only* representable moves back there, so under pressure — where both read unsafe — the compete fell to stand-still and the bot planted itself on the end wall until it was stripped; the lateral walk behind the cage was missing from the search, not mis-valued in it. *While the carrier is outside*, every candidate — including the entry target across the line — is priced by `position_potential`: the goal mouth's projected width from the bearing (`cos θ`, real foreshortening), times a whole-rink closeness gradient and the pressure cone. The two scales **never need to be compared**, so no bridging floor is required: because of offsides a bot in the zone never evaluates an out-of-zone spot, and the only in-vs-out decision inside this scoring is the choice to carry into the zone (the dump-and-chase is real but lives in `_best_dump`, which competes against the raw carry in its own currency rather than asking a candidate to price out-of-zone ice). That choice is made entirely in `position_potential` currency, whose closeness gradient climbs from the blue line toward the slot, so an in-zone target out-scores staying out and the carrier drives in — then flips to pure xG the instant it crosses. **One-way valve:** a carrier already in the zone prunes any carry candidate or pass receiver that would leave it (`_score_move_candidate` / `_compute_best_pass`) — establishing the zone is worth keeping. The blue-line valve is a legitimately hand-set *tactical* choice (zone control is a rule of the game, not a perception to ground); inside the zone, xG alone decides where to go. The valve is **buffered on both sides** because the offside puck-line is the true blue line while these decisions are made in body positions: carry candidates may not retreat within `OZ_RETREAT_LINE_BUFFER_M` of the line (the pass windup sweeps the carried puck a stick's reach behind the body — a carrier parked *on* the line dragged the puck out mid-windup and landed the whole team offside on the pass), and a pass target's intercept lead must sit `OZ_RECEIVE_LINE_BUFFER_M` inside it (a tape hugging the line loses the zone on routine reception slop, and is a genuinely hard catch-while-staying-onside read for humans too — those blue-line feeds are excluded as targets, not just discounted).
- **Controlled space** (`controlled_space` / `control_at`) — "how much room do I have to operate", as a measured quantity. A staggered 2×7 fan of carry *paths* across the forward cone, each priced by the same `carry_safety` a real carry candidate gets and reached at the same momentum-honest `time_to_arrive`, area-weighted (polar element ∝ r) and forward-projected (`cos θ`, the same foreshortening `position_potential` uses). Off-surface samples leave both sums rather than reading as pressure — a wall doesn't strip the puck, it removes options. This replaced a single netward ray through `carry_lane_clearance` as the carrier's forward-pressure discount (`FORWARD_PRESSURE_*`), which was a corridor-occupancy test with no clock (a defender 3 m ahead and one 8 m ahead both returned 0.556, and the carrier's own pace changed nothing — a carrier with one man 7 m up-ice and the whole width of the rink open read its space as exactly **0.000**), a cliff at the reach boundary (0.556 at 1.0 m off the ray vs 1.000 at 2.0 m — 45 cm deciding whether the puck went cross-ice, the neutral-zone "why did he pass that?" bug), and a one-path answer discounting an eight-direction search. Both sides of the carry-vs-pass compete read it, each at their own velocity and build, so momentum is never a term — it falls out of the honest arrival time (driving at the objective takes straight-ahead control 0.101 → 1.000). Fan density was measured against a 5×9 reference: angular resolution buys accuracy, radial does not, and staggering alternate rings by half an angular step doubles the effective bearings for free. Known residual: a **two-man wall met at speed reads ~0.2 optimistic** — a `min` over defenders cannot count bodies, and the dense reference is only 0.04 better, so this is the asymmetric model's structural blind spot rather than an undersampling one. True pitch control (a normalized partition over every skater, competing hazards) fixes it and was rejected on cost.
- **Field-derived carry candidates** — the forward half of the carry search is *generated* from the space fan's per-bearing profile (a free by-product of the discount above: `controlled_space` fills `out_bearing_control`, `AIRoleCarrier._best_carry` ranks bearings by control × forward projection and takes the best `CARRY_FIELD_BEARINGS`, each at two fractions of the planning beat). It replaced the forward polar cardinals and the whole committed-cut ring, retiring two defects: a **fixed radius** (candidates sat 3 m out, 6 m for the cut ring, no matter the carrier's pace — so a bot at 9 m/s chose between spots 0.33 s away while re-deciding every 33 ms, and nothing sampled the range where a zone entry is actually decided) and **blind bearings** (eight fixed spokes spend most samples on directions the field already knows are walled, and none on the seam between two of them). The radius is now one `CARRY_PLAN_BEAT_S` of travel at real speed, which reduces to the old 3 m local step at a standstill and reaches the blue line at a full stride — the geometry the cut ring was hand-placed to catch. Rearward/lateral cardinals stay a fixed local ring (`_REAR_ANGLES`) because the space fan deliberately looks only where the carrier is trying to go, and the committed peel-out remains the safety-gated retreat ring.
