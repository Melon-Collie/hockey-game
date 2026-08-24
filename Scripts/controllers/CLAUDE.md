# Controllers

Scope: `Scripts/controllers/` — the layer that drives actor bodies from
decisions. Controllers use the domain to decide and reach into infrastructure to
execute; they never reach up. Goalie *math* is pure and lives in
`Scripts/domain/rules/goalie_*.gd`; the doctrine below governs both halves.

## Goalie subsystem map

| File | Owns |
|---|---|
| `goalie_controller.gd` | the tick, state transitions, tuning `@export`s |
| `goalie_state_machine.gd` | stance transitions |
| `goalie_body_config_builder.gd` | pose solve into a shared scratch config |
| `goalie_shot_reaction.gd` | the read pipeline (delays, belief, convergence) |
| `goalie_puck_play.gd` | behind-net trip decision, geometry, phase |
| `goalie_crease_clear.gd` | loose-puck sweep / cover |
| `goalie_slide_behavior.gd` | committed slides and post seals |
| `goalie_world_view.gd` | the perception surface |
| `domain/rules/goalie_behavior_rules.gd` | reads, depth, races (pure) |
| `domain/rules/goalie_save_selection.gd` | block-or-react, as one question |
| `domain/rules/goalie_save_rules.gd` | rebound doctrine |
| `domain/rules/goalie_depth_solver.gd` | depth constraint composition |
| `domain/rules/goalie_stick_rules.gd` | stick geometry and coverage |

### Filter the puck, not the man

The threat the goalie squares to used to be low-passed as a whole — one lerp over
the blended puck/carrier position. A first-order filter has a **permanent**
steady-state error against a constant-velocity target: it settles at trailing by
`speed / k` and no amount of run-up closes it. So the filter charged the
carrier's real translation a trail proportional to his speed — measured at 0.20 s
of it beyond `chest_track_far_distance`, i.e. 1.6 m behind an 8 m/s skate.

That trail then entered the SQUARING error a second time, because the body
rotates toward the tracked threat rather than toward the puck. The two lags
compound, contributing about equally at 8 m, and together left him 26° off square
against a shooter crossing at 8 m/s — with the pads, glove, blocker and five-hole
all posed in that rotated frame.

The fix is that jitter and signal are **separable**, and only one of them needed
filtering. A carrier's BODY does not teleport; it is the smooth part and
low-passing it buys nothing. What wiggles is the puck's OFFSET from him (±1.5 m
of dangle) and the velocity estimate built from it. So the offset and the puck
lead stay inside the filter at exactly their old time constants and the body
rides through raw. Steady state is unchanged — once the offset converges the
blend reproduces the old one exactly — which is why `GoalieBehaviorRules
.compute_threat_position` is fed a jitter-filtered puck rather than re-derived.

Two things that bite:

- **The puck lead must stay inside the filter.** It is built from a raw per-tick
  position difference, so unfiltered it hands the goalie precisely the dangle
  spikes the filter exists to reject.
- **Removing the trail leaves the LEAD unopposed.** `carrier_velocity_lead_time`
  was cancelling the trail in tight (0.12 s of lead against a 0.125 s trail) and
  losing to it at range. With the trail gone the lead is net anticipation
  everywhere — he now plays *ahead* of a moving carrier by that much, which is a
  deliberate, beatable-by-cutback property rather than an accident, but it is a
  different quantity from what the number was chosen for.

`test_goalie_tracking_lag.gd` holds it, and asserts structural properties — trail
proportional to speed, the compounding — rather than pinned numbers, so replacing
a filter with a rate limit fails it rather than passing quietly.

### Delete the copy, don't correct the number

Nothing connects a literal to the collider it was copied from, so every
hand-built replica of the keeper in the planner — pad splay, glove reach, torso
size, the depth chart, the band harness — drifts off the body that actually makes
the saves, silently and without anyone being wrong on purpose. `GoalieAnatomy`
(his dimensions) and `GoalieStickRules` (his stick, split out because the blade
also owns an aim solve) are the single source: anything the planner believes
about the keeper's SHAPE derives from them, so changing the body moves the
planner for free.

### The stick's angle is not a pose choice

The blocker assembly's forward tilt used to be four authored numbers, one per
stance family. It cannot be: shaft, paddle and blade are one rigid piece hanging
a fixed distance below the wrist, so once the pose puts the hand somewhere, the
paddle angle that lands the blade on the ice is *decided* — by that height and by
the stick's lie, and by nothing else. `GoalieStickRules.tilt_for_blade_on_ice`
solves it and `GoalieBodyConfigBuilder._seat_stick_tilt` is the only writer of
`blocker_rot.x`, running last so every modifier that moved the hand — sweeps,
lunge, prelean, elevated reach — gets a stick that follows it.

The upright stances give up their hand HEIGHT to the same constraint. A blade
both flat and on the ice puts the wrist at exactly one place
(`wrist_y_for_flat_blade_on_ice`); standing taller than it is what leaves the
blade resting on its heel, which is the one thing every goalie coach says not to
do and which measured out as the blade presenting its UNDERSIDE to the shooter.

What is left over is a real property of this rig rather than a tuning decision:
the wrist-to-blade lever is 0.92 m where a senior paddle is 0.66, because the
hand is modelled a quarter-metre up the shaft from the paddle's top. That extra
length is why the butterfly still has to lay the paddle over past its lie to
reach the ice, and it is a `Goalie.tscn` change, not a code one.

## What kills a collaborator extraction

**A collaborator may accept any number of inputs written from outside. It must
exclusively own every field it writes itself.**

Measured across the goalie's own collaborators — contested means a field both the
collaborator and the controller assign:

| collaborator | caller-written fields | contested | methods that died |
|---|---|---|---|
| `goalie_puck_play` | 20 | 0 | 0 of 11 |
| `goalie_shot_reaction` | 7 | 2 | 0 of 10 |
| `goalie_slide_behavior` | 13 | 2 | 0 of 13 |
| `goalie_crease_clear` | 37 | 12 | 17 of 27 |

`GoaliePuckPlay` takes the most caller-written fields of any of them and is
perfectly healthy, so "the caller writes to it" is not the problem. Sharing
ownership of one field is. Once the controller writes `_clear.cover_cooldown_timer`
it has re-derived when to write it — the lifecycle — and the collaborator's own
`tick_cover_cooldown` is redundant from that moment. Twelve contested fields
produced seventeen unreachable methods, none of which failed anything.

Copy `GoaliePuckPlay`'s field layout: tuning pushed at config time, geometry set
once at setup, trip state owned outright, and an explicit "requests to the
controller" block read after `advance()`. One per-tick entry point that takes the
world as arguments and clears its own outputs at the top.

## Depth is the A/B/C/D ladder, and it is not compressed inward

The Buckley zones are *situational*, not a distance chart. A is ~2 ft outside the
crease top — challenge a rush, a breakaway, or a clean look and force the shooter
to beat you. B is heels at the crease top, where most shots are faced. C is the
middle of the blue paint, held when a lateral play is live. D is on the post or
tracking behind the net.

At these shot speeds a slot shot leaves almost no lateral reaction window (~0.04 m
of travel in flight), so **cutting the angle by challenging is what makes the
save, not reflexes** — depth pulled inward to look safer is a goalie who cannot
make the save he is standing there to make. The "play conservative on a lateral
threat" read is produced dynamically by the lateral tracking cap and the backdoor
depth cap, never baked into a distance curve.

The anchors are real geometry: the NHL crease top is ~4.5 ft ≈ 1.37 m, which is
`CreaseRules.STRAIGHT_DEPTH`. Depth is gated on a real rink landmark (goal line →
blue line) rather than a tuned distance, because geometry alone would park him at
the challenge ceiling for a puck at the far blue line, where the net subtends
almost nothing.

## Beatable realism

The goalie should look and move like a real goalie while staying deliberately
scorable. **Realism should not produce an unbeatable goalie; it should produce
one who gets beaten the way an NHL goalie gets beaten.** Making him better is
not the failure mode — closing off a way he *ought* to be beatable is, and a
save count alone cannot tell the two apart.

Two recurring traps, both measured:

- **A goalie who pre-commits cannot be read, and being readable is the game.**
  Every change that made him block or commit earlier has measured as *more saves*
  AND *deception ceasing to pay*. Deception paying negatively is the tell. If a
  change produces that signature, it is wrong even when the save count improves.
  Three separate changes have produced it: removing the `not _reaction.reacting`
  gate on the block branch (dot-line beatability 16/288 → 25/288, a cold five-hole
  window opening from nothing to 17 cm, wrong-height deception falling to 4/14
  against a 6/14 baseline); counting `WRISTER_AIM` as a shot declaration in the
  block-or-react launch clock (4/14 across all three deception arms, against 6/14
  telegraphed and 11/14 wrong-height under the read); and the tip doctrine in
  `GoalieSaveSelection`.
- **Blocking concedes the top of the net.** Any path that blocks a shot already
  read as elevated is strictly wrong. The block model has no `impact_y`.

The one sanctioned commit is the **beaten-wide post seal** — and it is sanctioned
because it is not a prediction. Its gate is positional (the puck is already past
his standing sealing reach on the side it went), so it fires on an accomplished
fact rather than a guess about intent, and the goalie pushes into the seal off
the drop as one motion instead of landing square and re-deciding. Onset needs the
puck genuinely moving across; *persistence* deliberately drops that term, because
a puck that settles wide has not un-beaten him. Pulling it back inside the
sealing reach is what un-commits him, and baiting that commit is the counter.

**The goalie can be WRONG, deterministically.** His committed belief about where
a shot is going is the aim he read `read_lag` seconds ago, sampled from the
shooter's published `predicted_shot_velocity`, converging onto the true line over
`read_converge_time` once the puck is in flight. This is not RNG and must not
become RNG — both teams field identical goalies and it has to read that way. The
error is a pure function of what the SHOOTER did with their aim: a stable aim
through the wind-up means the stale sample EQUALS the truth, so a telegraphed
shot is read exactly as well as before, while a late swing against the grain
beats him by exactly the amount the shooter moved the aim. Repeatable, symmetric,
attributable. What falls out with no extra authoring: a long shot converges
before it arrives and is read correctly; an in-tight one does not and beats him;
a screen costs ACCURACY as well as tempo, because there is nothing to converge
with while the puck is hidden; and a deflection resets the read, so a tip in
tight beats him while a tip from distance does not.

**Being unset is DIRECTIONAL, and that is the point.** Momentum he cannot cancel
plus an open trail leg means: shoot against his motion and he cannot get back,
shoot with it and he over-slides. Both are counter-playable, and neither makes a
*set* goalie harder to beat. Loading the cost of being unset onto read latency
instead is the wrong model — latency is not directional — which is why
`move_read_speed_delay` is deliberately small.

**The prime is a permission to move, not a save buff.** The quiet-eye prearm and
the slot-proximity prime only make the limbs START moving; the cold arm read
outlasts a slot shot's flight, so uncredited the goalie never moves at all. The
flat reach-speed cap still bounds how much net he covers, so a corner picked out
of that reach beats him — "pick a corner, don't face a statue" is the in-tight
window this exists to create. A quick-release snap FROM RANGE never earns the
windup prime, which is the real "quick release beats the read" edge.

**The taught response to a clean windup is GET SET — square, stopped, at depth —
not retreat.** Backing in concedes angle exactly when the goalie has his best
look, and a windup is MORE read time, which is why slapshots convert lower than
snap shots. Being set emerges rather than being applied: the charging carrier
glides, so the arc target goes stationary and the movement converges. No depth
concession is applied anywhere; screened windups are handled by the blocking
drop, not by depth.

## Behind-net puck play — the doctrine

**"Stop it, leave it, get back."** The goalie leaves his net ONLY to trap a rim
behind it. He never carries and never passes: the misplay-prone tiers of real
puck handling are deliberately absent, because an AI turnover behind the net is
the most frustrating failure a goalie can produce. A pure stop has no turnover
mode — the only failure available is a bad GO decision, which is exactly what the
races pin.

Everything about the decision is deliberately conservative:

- the forechecker is modelled at **FULL SPRINT from the first instant** (no
  reaction delay, no acceleration ramp) — the fastest opponent physics allows, so
  the pressure clock always UNDER-estimates the time available;
- the goalie's clock counts the **WHOLE trip** — out, the stop beat, and the
  return to his post — before pressure arrives, not just the touch;
- an opponent near the net front **vetoes outright**;
- the race is **re-run every tick** of the trip with a stricter margin (abort
  hysteresis), so a conservative goalie visibly bails early rather than ever
  getting caught out;
- the trip routes around the post via a waypoint — never through the net.

Only the HARD tier plays the puck at all (`puck_play_go_margin` is INF below it);
timid puck play is a real weaker-goalie trait.

## Difficulty

Goalie tuning is bundled per tier in `GoalieSkillProfile`. HARD leaves every
value at the controller's authored default, so HARD is the authored goalie by
construction.

Whenever the bots' shot model reads the same quantity as a goalie knob, the two
must be synced (`AIActionScoring.set_goalie_profile`) or the bots score against a
goalie they do not face. See the AI MIRROR note in `goalie_skill_profile.gd`.

## SkaterController

`SkaterController` delegates to five `RefCounted` collaborators —
`SkaterAimingBehavior`, `SkaterIKCoordinator`, `SkaterPoseCoordinator`,
`SkaterShotPoseCoordinator`, `SkaterSkatingCoordinator`. `GameManager` calls
methods on the controller and never pokes collaborator internals.

**Attributes v4, one line each.** Skating splits into three height-routed
sub-levers, so a small player can be explosive and shifty without owning the top
gear and a big weak skater feels bad in the TURN rather than glued to the ice.
Hands has no lever by constitution — "your hands are you" — so the blade caps
derive from lever geometry rather than a fidelity table: the long lever sweeps
but cannot cut back, the short lever is the scalpel. Shot means "what a charge
buys you, and how fast you can charge it", never the uncharged snap. Stamina is
height-flavoured metabolism with no attribute touching it: small is short
repeatable bursts, big is one long drive then a slow refill. Full detail lives in
`Scripts/domain/state/CLAUDE.md`.

`apply_attributes` is **idempotent**: it captures baseline values on first call
and recomputes from those baselines every time, so repeated applies (the
free-play picker) never compound. Config objects built from `@export`s are cached
here and rebuilt on apply — do not restore per-tick rebuilds for live tuning,
which is not a workflow on this project.

## The gait publishes channels; it never writes body rotations

`SkaterSkatingCoordinator` is the whole procedural gait — no skeleton, no
animation clips, everything derived from replicated velocity plus the intent
byte, so it costs zero network state and a wire-fed remote animates identically
to a locally-simulated one. It runs at RENDER rate (`Skater._process`,
visibility-gated) and is guarded by `not is_replaying` so reconcile replay never
over-spins the phase — which also means it can own no timer, and is why the
celebration window is aged by its callers at physics rate instead.

**It writes leg swing, foot eversion, edge loads and the crouch drop directly
onto `Skater`, and never a torso or lower-body rotation.** Everything rotational
is *published* as a field for `SkaterPoseCoordinator` to sum into one write:
`trunk_pitch_add` / `trunk_roll_add` (torso texture), `stop_yaw_offset` (hockey
stop), `travel_align_yaw` (hip-to-travel alignment, which the pivot also drives
while engaged), `shot_hip_yaw` (shot coil and uncoil), and `pivot_hold`
(authority, which fades the generic facing-lag pump out of the sum). Two writers
tracking one rotation on different clocks is a wobble, not a pose — hence one
summing site rather than five writers. The trunk texture in particular goes onto
the cosmetic torso, helmet and shoulder BONES, never onto the `UpperBody` node,
whose rotation carries the blade markers and is therefore gameplay geometry.

### Pose the hand, not the blade

The tracked path is blade-first: the cursor names a blade position and
`TopHandIK` solves the hand as a consequence. A **held** pose that wants the
blade in tight cannot be authored that way, and the check commit is the worked
example.

`TopHandIK` has two regimes. Inside the stick's resting horizontal reach it goes
CLOSE, which pins the hand's XZ **at the shoulder marker** and varies only its
height — the blade's authored distance stops mattering entirely, and past the
`hand_y_max` ceiling the blade overshoots along the aim line instead of landing
where it was put. Meanwhile the rendered arm roots at the shoulder the trunk
texture has MOVED (`SkaterArmRig._textured_shoulder`), which a lean and a
load-up carry ~0.16 m forward. Put together, the arm roots in FRONT of its own
hand: the shoulder→hand chord points down and back, a mostly-downward elbow pole
projects forward off such a chord, and the forearm folds behind the upper arm.

So a held pose authors the **hand** — where the player actually holds the stick
— and derives the blade one `solve_stick_length()` along the intended bearing.
Authoring both ends over-constrains a rigid stick, and `enforce_rigid_stick`
only shortens an over-long span; an under-long pair draws a visibly short stick.
`test_commit_grip_choke.gd` holds all of it, including the fold direction.

**A pose the trunk texture cannot express does not belong in the gait.** The
texture is one pitch and one roll for the whole shell, so it is symmetric by
construction: any "drop a shoulder" written as roll raises the other shoulder by
exactly as much. The check-commit load-up is therefore split — the gait keeps the
lean and the crouch, and the per-side shoulder geometry lives in
`CheckStanceRules`, eased at PHYSICS rate on the skater
(`Skater._update_commit_stance`) because the loaded blade position reads it and
the blade goes on the wire. Anything else asymmetric belongs on that side of the
line too, not as a new trunk channel.

## The faceoff pose is two poses, and neither is a stride

`FACEOFF_PREP` is one phase but three different things happen in it, and the
bugs all came from treating it as one.

**The walk-in is skating.** While `begin_approach`'s glide is live the skater is
covering ground, so `is_faceoff_ready()` is false and the gait plays an ordinary
stride — a floored crouch and staggered feet laid over a running stride read as
a limp. The ready stance eases in as the glide hands back.

**Set at the dot is two stances, not one.** The players lined up behind the dot
hold a ready stance. The centre taking the draw holds an *address*: knees well
past the skating sit, a base splayed wide under him, feet split fore/aft, chest
folded down over the dot, hands apart on the shaft. `Skater.is_faceoff_center`
selects between the two, and it is *derived* on every peer from the C slot
rather than replicated — every machine already knows every player's slot, and a
cosmetic bit is not worth a wire byte.

The address is spread across the collaborators that own its parts, and the parts
are not independent:

- **The crouch, the splay and the foot split are gait channels**
  (`SkaterSkatingCoordinator`), floored over the speed-driven envelope. The
  splay costs each leg a cosine of vertical span, which the body pays as extra
  drop.
- **The chest fold rides the trunk TEXTURE**, not the torso lean — the lean
  rotates the `UpperBody` node the blade markers hang from, and the blade-first
  IK answers a pitched frame by standing the shaft on end. Bones are mesh only,
  so the chest reads folded while the stick keeps its address. The arm roots
  ride the texture too (`SkaterArmRig._textured_shoulder`), which is what lets
  the fold go deep without tearing the arms off the shoulders.
- **Both ankles flatten** (`SkaterLegRig.set_ankle_flatten`). A sit this deep
  folds the shin far enough back to stand the blades on their heels, and the
  splay puts them on their outside edges; the ankles give the whole chain back.
  A level boot then hangs its blade below the FOOT pivot rather than keeping its
  sole planted, so the crouch owes `_FOOT_FWD`'s vertical share on top.
- **The hands are solved off the FOLDED shoulder**
  (`SkaterIKCoordinator.address_shoulder`), because that is where the arms are
  rooted. This is the one that bites: solved off the marker, the hands land a
  third of a metre behind the shoulder they hang from, and a two-bone IK can
  only answer that by putting the elbow in front of the wrist. The arm reads as
  bending backwards, and no amount of pole tuning fixes it.
- **The stick is choked** for the draw (`Skater.faceoff_choke_m`, sized off the
  build's own stick like the check commit's). The hand rides one stick-length up
  from a blade on the dot, so at full length a body folded this far has to hold
  it at shoulder height with the arm shut. A real centre grips well down the
  shaft, and the shaft keeps its length — `SkaterStickRig` gives back out of the
  butt whatever the grip takes.
- **The top hand's ceiling comes down** (`_address_hand_ceiling`). `TopHandIK`
  answers a puck inside the stick's reach by RAISING the hand and steepening the
  shaft; that is a carry in tight, not an address. The ceiling binds only
  through the countdown — the ease releases it at the drop, so the draw sweep
  itself is unaffected.
- **The bottom hand slides down the shaft** on the same ease
  (`_grip_fraction`) — the short lever a draw is won with.
- **The reach lean stands down** (`SkaterPoseCoordinator._address_share`). It
  measures the hand's reach off the shoulder MARKER, and the address carries the
  hands forward with the chest — so left alone it reads that carry as a reach
  and leans the torso a second time for it, deepening the fold past the authored
  one and handing the blade IK a pitched frame to solve the address in.
- **The dot is laid out from the ADDRESS, not from a standing body**
  (`faceoff_center_distance`): the fold's carry plus the shaft's span at the
  crouched hand height and the choked length. It runs at the whistle, before the
  pose exists, so every term is derived — the drop from
  `SkaterSkatingCoordinator.faceoff_address_drop`, with the live crouch netted
  out so a skater caught mid-stride doesn't get a different dot. The fraction is
  deliberately just PAST 1.0: at the shaft's natural projection the hand comes
  off the body toward the dot (`TopHandIK`'s FAR regime) and the arms open,
  while short of it the hand rides its ceiling and they fold shut.

**Nothing dispatches the state machine while movement is locked**, so no state
can clear itself there — `SHOT_BLOCKING` used to hold its planted legs and wide
block cylinder from the whistle to the drop, because its own exit lives in
`_state_shot_blocking`. The teleport at the head of every approach is where a
locked phase gets cleaned up (`_reset_to_skating_state`), and it has to publish
`skater.current_shot_state` itself for the same reason.

**Every path that poses the body publishes the lower body's yaw**
(`SkaterPoseCoordinator.apply_lower_body_yaw`). The two locked-phase paths
replace `apply_facing` wholesale, and one that skips this leaves the hips frozen
at the last yaw anyone wrote — which is how skaters spent whole countdowns still
turned down the line they skated in on.

## Build once, fill scratch

A per-tick collaborator that produces a compound result should own ONE
long-lived scratch instance and fill it, rather than returning a fresh
`Dictionary` / `Array` / `RefCounted` per call. It is safe exactly when the
consumer reads the result and never stores the reference: `GoalieBodyConfig` is
read and lerped into the parts by `Goalie.apply_body_config`, so one instance
serves both goalies forever and keeps ~150 lines of `Vector3` literals off the
heap per goalie per physics tick.

Where two consumers can interleave, give each its own scratch instead of sharing
one — `RemoteController` keeps `_sample_bracket` separate from `_scratch_bracket`
so a reconcile-time sample cannot clobber the live render bracket. Document the
"consume before the next call" lifetime at the returning function, since that is
the one thing a caller can get wrong.

## Hot path

Everything here runs at 120 Hz × actor count, and reconcile replay re-runs the
per-tick body once per replayed input. Cosmetic-only work belongs in `_process`,
not `_physics_process`. See CLAUDE.md → *Hot-path discipline*.
