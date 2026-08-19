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

`apply_attributes` is **idempotent**: it captures baseline values on first call
and recomputes from those baselines every time, so repeated applies (the
free-play picker) never compound. Config objects built from `@export`s are cached
here and rebuilt on apply — do not restore per-tick rebuilds for live tuning,
which is not a workflow on this project.

## Hot path

Everything here runs at 120 Hz × actor count, and reconcile replay re-runs the
per-tick body once per replayed input. Cosmetic-only work belongs in `_process`,
not `_physics_process`. See CLAUDE.md → *Hot-path discipline*.
