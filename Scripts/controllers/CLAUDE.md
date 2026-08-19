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

## Hot path

Everything here runs at 120 Hz × actor count, and reconcile replay re-runs the
per-tick body once per replayed input. Cosmetic-only work belongs in `_process`,
not `_physics_process`. See CLAUDE.md → *Hot-path discipline*.
