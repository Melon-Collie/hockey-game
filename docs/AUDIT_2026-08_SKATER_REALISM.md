# Skater Bot AI Realism Audit — August 2026

A behavior-by-behavior audit of the **skater** AI against real hockey doctrine and against this
repo's own design records. Scope is `Scripts/domain/ai/**` and `Scripts/ai/**` — the possession
state machine, the slot elections, every role behavior module, the shared verbs, and the per-bot
state machine. **The goalie is out of scope** (covered by `docs/AUDIT_2026-07_GOALIE_REALISM.md`);
goalie-facing *skater* reads (shot value, feed-keeper prediction) are in scope only where they
change what a skater does.

The reference points are, in order of authority:
1. This repo's own design records — `docs/transition-defense-plan.md`, `docs/5v5-ai-plan.md`,
   `docs/breakout-plan.md`, `docs/gameplay-design.md`, `Scripts/domain/ai/CLAUDE.md`. Several
   findings are **the code disagreeing with its own plan**, which is the highest-confidence kind.
2. Standard coaching doctrine for gap control, forechecking, D-zone coverage and breakouts, as
   already cited inside those plans.

**Verdict legend**
- ✅ **Matches** — behavior aligns with real doctrine
- ⚠️ **Partial** — right idea, wrong number or missing a piece
- ❌ **Diverges** — behavior contradicts the doctrine it cites
- ➖ **Absent** — a real behavior with no counterpart in the model

---

## 1. Executive summary

The skater AI is structurally in far better shape than the usual sports-game bot. Almost
everything is a grounded perception model rather than a tuned curve: the reachable-set carry
safety, reach-vs-flight-time pass lanes, the shared numbers/backpressure rush read, the man/zone
unification behind one `cover_threat` verb, the moving-frame defensive stand, the closed-form
dump landing solve. §7 lists ~20 behaviors that match real doctrine outright, several of them
better than the commercial games do it.

The gaps cluster in three places, and they are not evenly distributed. **Defending in our own
zone and through the neutral zone is good. Forechecking is where the model breaks down** — it
reuses rush-defense machinery in a zone where "ice remaining" is meaningless, and it puts both
defencemen 9 m deeper than the design of record says. **And the offensive zone has no shot-volume
game**: nothing in the model rewards a point shot, so the two roles built to take one never do.

| # | Finding | Verdict | Priority |
|---|---------|---------|----------|
| F1 | Gap ladder computes **2 / 1.5 / 1** sticks where its own doctrine (and its own constant) says **3 / 2 / 1** — the divisor is 2× too big | ❌ | P1 |
| F2 | The **forechecker holds a rush gap**: F1 stands ~5.4 m off the carrier deep in the offensive zone and structurally cannot close | ❌ | P1 |
| F3 | **Both defencemen pinch to the top of the circles** on every forecheck — the plan says hold the blue line and explicitly lists "no D pinch" as a v1 non-goal | ❌ | P1 |
| F4 | Bots **never block shots**. `block_held` is hardcoded false; the mechanic, the physics and the stat all exist | ➖ | P1 |
| F5 | Bots **never lift a stick**. The plan names stick-lift as a backchecker's tool; only the FINISHER raises a blade, and only to tip | ➖ | P2 |
| F6 | **No point-shot / rebound cycle.** The shot bar bans anything past the top of the circles, and nothing prices a second chance — so the walk-the-line point roles have no shot to walk into | ⚠️ | P1 (feel) |
| F7 | The FINISHER's depth cap makes **2 of its 6 named stations unreachable at every rush factor** (weak dot, high slot) — dead candidates, and no low support in 3v3 | ⚠️ | P2 |
| F8 | No **plain slapshot from carry** — one-timers only (deliberate, documented) | ➖ | note |
| F9 | No **line changes, penalties, or goalie pull** — absent at the game level, not the bot level | ➖ | note |

F1–F3 are all in the same family: a defensive-distance model written for a rush, applied where
the rush concept doesn't hold.

---

## 2. F1 — The gap ladder is a third tighter than the doctrine it cites

**Verdict ❌ · P1 · `Scripts/domain/ai/role_behaviors/rush_d.gd:190`**

```gdscript
static func _ladder_sticks(threat_pos: Vector3, own_goal_dir: float) -> float:
	var ice_to_line: float = maxf(
			GameRules.BLUE_LINE_Z - own_goal_dir * threat_pos.z, 0.0)
	return clampf(GAP_MIN_STICKS + ice_to_line / (GameRules.BLUE_LINE_Z * 2.0),
			GAP_MIN_STICKS, GAP_MAX_STICKS)
```

The header, `docs/transition-defense-plan.md` §6, `Scripts/domain/ai/CLAUDE.md` and
`GAP_MAX_STICKS = 3.0` all state the same ladder: **~3 sticks at their blue line → 2 at the red
line → 1 at ours.** The formula produces something else. With `BLUE_LINE_Z = 7.29`:

| carrier at | `ice_to_line` | sticks computed | doctrine | gap (stick = `BLADE_REACH_M` 1.80 m) |
|---|---|---|---|---|
| their blue line | 14.58 | **2.00** | 3 | 3.6 m (want 5.4 m) |
| red line | 7.29 | **1.50** | 2 | 2.7 m (want 3.6 m) |
| our blue line | 0.00 | **1.00** | 1 | 1.8 m ✓ |

The two ends are pinned correctly and the *middle of the ramp is half as steep as it should be*.
The divisor should be `BLUE_LINE_Z`, not `BLUE_LINE_Z * 2.0`: `1 + ice/BLUE_LINE_Z` reproduces
3 / 2 / 1 exactly. As written, `GAP_MAX_STICKS = 3` is unreachable from the base ladder — only the
`DOWN_TWO_PLUS` rung can ever get there — so the clamp that is supposed to be the doctrine's
ceiling is dead in the common case.

The bug is inherited from the plan, not introduced against it: `transition-defense-plan.md:289`
writes the same formula and then tabulates 3 / 2 / 1 beneath it, which only holds if `d` at their
blue line were `4 × BLUE_LINE_Z`. The plan's author read `BLUE_LINE_Z` as a zone depth rather than
as a distance from centre ice. The code implemented the formula faithfully and inherited the error.

**Blast radius.** `ladder_gap_m` is deliberately shared, so the same 33% is missing everywhere:
- `AIRoleRushD._gap_for` — the rush gap itself.
- `AIRolePressure` (`pressure.gd:147`) — the in-zone pressurer *and* the forecheck's F1 (F2).
- `AIRoleTrack._hip_gap` (`track.gd:162`) — the cap on how much depth a backchecker gives up.
- `AIRoleChase`'s lost-race pre-contain stand.

**Why it matters on the ice.** A 3.6 m gap at the far blue line against a carrier at 8 m/s is
0.45 s of reaction — inside the reaction delay of every tier below Hard. A D gapped that tight at
the offensive blue line gets beaten to the outside with speed, which is the exact failure gap
control exists to prevent, and it is the one regime the `gap_up` trigger deliberately does *not*
cover (it fires when the carrier's speed advantage is **gone**).

**Note before fixing:** the tests do not pin the magnitude. `test_role_pressure.gd:346` asserts
against `ladder_gap_m` itself (so it follows any change), and
`test_the_ladder_tightens_as_the_carrier_gets_deeper` only asserts far > near. Widening the ladder
will move `test_rush_gap_discipline.gd` and `test_defensive_routing.gd` body measurements, which is
the right place to re-measure it — those are the honest home for the claim.

---

## 3. F2 — The forechecker holds a rush gap and cannot close

**Verdict ❌ · P1 · `pressure.gd:147` + `pressure.gd:271-298`**

`FORECHECK`'s F1 dispatches straight into `AIRolePressure` (`skater_agent_state_machine.gd:2477`).
PRESSURE sizes its stand-off with the *rush* ladder — and in the offensive zone "ice remaining to
our blue line" is at its maximum, so the ladder saturates:

| forecheck situation | `own_dir · z` | sticks | stand-off |
|---|---|---|---|
| opposing D behind his own net | ≈ −25 | 3.0 (clamped) | **5.4 m** |
| opposing D on his half-wall | ≈ −20 | 2.87 | **5.2 m** |
| carrier at their blue line | −7.29 | 2.0 | 3.6 m |

And the gap is a **hard floor**, not a preference. `pressure.gd:281-298` clamps every candidate
*out* onto the gap ring rather than filtering it:

```gdscript
var min_gap_sq: float = gap * gap
...
if gd_sq < min_gap_sq:
	c = Vector3(carrier_pos.x + gx * k, 0.0, carrier_pos.z + gz * k)
```

That clamp is exactly right for a rush (it stops the argmax collapsing onto the man) and exactly
wrong here. The consequences compound:

- **The poke jab can never fire.** `_poke_jab_reach` is `stick + blade + POKE_RADIUS` ≈ 1.9 m
  (`skater_agent_state_machine.gd:518`). At a 5.4 m stand-off the forechecker is three times too
  far to ever put a stick on the puck.
- **The only way F1 ever engages is a committed body check.** `AIBodyCheck.CHECK_RANGE_M` is 6.0 m,
  so a hit is *just* reachable from the ring — but it needs a predicted separating impulse of 1.6
  (`body_check.gd:63`), a light build often can't clear it, and Easy's `check_aggression = 0`
  disables it outright. Below Hard, the forechecker circles at five metres and never touches
  anybody.
- **`pursuit_standoff_m` adds on top** (`pressure.gd:149`), so easier tiers forecheck from even
  further out.
- The difficulty knob meant to make lower tiers *less* physical instead removes the team's only
  remaining way to force a turnover in the offensive zone.

**What real forechecking is.** Gap control is a *retreating* concept — you are managing the space
between you and a man coming at your net. F1 is doing the opposite job: closing on a man with
nowhere to go, taking away D-to-D, forcing the puck up the wall, finishing the check. The repo's
own research says so (`5v5-ai-plan.md:534`: *F1 "the dog": arc inside-out, take away D-to-D*).
`forecheck.gd`'s header describes an aggressive press and accepts the risk of being caught deep —
but the body it dispatches to never presses.

**Sketch of a fix.** The gap ladder should be keyed on the *defensive* premise it was written for.
Two clean options, in preference order:
1. Give `AIRolePressure` a **pursuit** branch: when the play reference is in the *attacking* zone
   (or more precisely when `AIRushRead.mode != RUSH` and the puck is not threatening our net), the
   stand-off collapses to contact/poke range and the argmax picks the *bearing* only — which is
   the same division of labour the ladder already uses, with a distance that means something here.
2. Or ladder on "ice remaining **to the puck's own goal line**" when we are the attacking team, so
   the same monotone shape produces contact depth deep in their end.

Either way, the inside-shade angling (`inside_dir` / `inside_shade_m`) is already correct for a
forecheck and should stay — arcing inside-out *is* the doctrine.

---

## 4. F3 — Both defencemen pinch to the circle tops on every forecheck

**Verdict ❌ · P1 · `defenseman.gd:50, 78-81, 213-222`**

```gdscript
const DP_PINCH_DEPTH_M: float = 10.7   # top of the end-zone circles
...
AIRoleSlots.Slot.DP_STRONG: return _decide_line_hold(ctx, ctx.strong_x * DP_STRONG_LANE_X_M)
AIRoleSlots.Slot.DP_WEAK:   return _decide_line_hold(ctx, -ctx.strong_x * DP_WEAK_LANE_X_M)
```

`_decide_line_hold` puts the stand at `GOAL_LINE_Z - 10.7` — the tops of the circles, **8.8 m
inside the offensive blue line** — and both defencemen get the identical treatment. There is no
strong/weak asymmetry and no per-pinch trigger; the only bound is the shared pinch read, which in
`FORECHECK` reads `REGROUP` (they are bottled) and therefore **holds** (`role_helpers.gd:1018`).
So the standing forecheck shape is: three forwards deep, plus both D at the circle tops, and nobody
between the play and our net.

This contradicts four separate records:

| record | says |
|---|---|
| `docs/5v5-ai-plan.md:302` | "**FORECHECK line-hold** (DP_STRONG / DP_WEAK): hold the **offensive blue line** inside the dots" |
| `docs/5v5-ai-plan.md:40, 175` | "No deliberate D **pinch** behavior… no down-the-wall pinch in v1" (§ non-goals) |
| `docs/5v5-ai-plan.md:538` (research) | "The two D hold the offensive blue line inside the dots; **strong-side D pinches on a puck he can win**" |
| `role_slots.gd:86-87` (the slot enum's own comment) | `DP_STRONG` / `DP_WEAK` — "D: **offensive blue line**, strong side, inside the dots" |

It also contradicts the election that assigns the slot: `role_slots_5v5.gd:319-326` races the pair
to `opp_blue_z + own_dir * 0.5` — half a metre on the **neutral-zone side of the line**. The
election puts them at the line; the behavior then sends them 9.2 m deeper. Nothing pins the pinch
depth in tests (`test_role_forecheck.gd` and `test_point_holds_the_line.gd` cover F3 and the
O-zone points, not the D pair), which is why the drift went unnoticed.

**Real doctrine.** In a 1-2-2 the D pair *is* the back layer. A pinch is a situational read — my
winger has the wall, the puck is coming to me, I have a forward covering — and the weak-side D is
the one man who categorically does not pinch. Pinching both, unconditionally, converts every
failed forecheck into an odd-man rush the other way.

**Fix.** Restore the plan: the pair's stand is the blue line inside the dots. If a pinch is wanted,
it belongs as an explicit, *strong-side-only* read with a "can I win this puck" gate — which is
exactly what `_wall_rim_keepin` (`defenseman.gd:175`) already does correctly for O-zone rims, and
is the right model to copy.

---

## 5. F4 — Bots never block shots

**Verdict ➖ · P1 · `Scripts/ai/skater_agent.gd:136`**

```gdscript
input.block_held = false
```

That is the only reference to `block_held` in the entire AI layer. Nothing ever sets it true.

Everything else in the shot-block pipeline exists and works:
- `SkaterStateMachine.State.SHOT_BLOCKING` (`skater_state_machine.gd:11, 276`) with a pose
  (`skater_pose_coordinator.gd:141`),
- puck resolution against a blocking body (`puck_controller.gd:517, 582`),
- the goalie's world view knows a blocker screens differently (`goalie_world_view.gd:86`),
- and `shots_blocked` / `shot_attempts_blocked` are tracked career stats
  (`player_stats.gd:7, 57`).

So a human can block shots, the game counts them, and the bots simply never do. In a real D-zone
that is not a garnish — it is a primary defensive action, and the single most common way a
point shot dies.

There is an asymmetry worth naming: `AIActionScoring.lane_clear` already prices a defender's
**stick** in the shot lane, so the *shooter* believes lanes get blocked. The *defender* has no
corresponding action. The model is half-built.

**Fix sketch.** This wants to be a small committed maneuver like the poke jab, not a continuous
flag: a defender with no man to cover, goal-side of a shooter inside the house, with the shot lane
crossing his own body inside a reachable window, commits `block_held` for a short window and eats
the recovery cost. It should ride a cognition gate (`BotSkillProfile`) — a beginner tier that
doesn't block shots is a legitimate difficulty axis.

---

## 6. F5 — Bots never lift a stick

**Verdict ➖ · P2**

`input.stick_lift_held` is set in exactly one place (`skater_agent_state_machine.gd:2217`, from
`RoleDecision.lift_blade`), and `lift_blade` is set in exactly one place: `finisher.gd:169`, to
raise the blade so an *elevated incoming shot* can be tipped. It is never used defensively.

The game's own design says the two are the same gesture — *"The raised HIGH blade is also what
hooks under an opponent's shaft, so **stick-lift is the same gesture***"
(`docs/gameplay-design.md:18`) — and the transition plan explicitly assigns it to the backchecker:
*"when it arrives it is allowed to attack the puck (poke / **stick-lift**…)"*
(`transition-defense-plan.md:352`).

`AIRoleTrack._decide_puck` implements the arrival — the tracker rides the carrier's hip, aims the
blade at him (`track.gd:127-129`) and may finish a check once goal-side — but its only takeaway is
the poke jab. Catching a carrier from behind and lifting his stick is the canonical backcheck
takeaway and it is missing.

Same shape of fix as the poke jab: a discrete, committed, cooldown-gated maneuver on
`AIRoleTrack` / `AIRolePressure` when goal-side and inside blade range of the carrier's stick.

---

## 7. F6 — The offensive zone has no shot-volume game

**Verdict ⚠️ · P1 for feel · `carrier.gd:57`, `action_scoring.gd:2353`**

Three things are individually defensible and jointly remove a whole third of real offensive hockey.

1. **The shot bar bans the point shot.** `SHOT_MIN_VALUE = 0.05`, denominated in NHL-calibrated
   xG, and the constant's own comment says what it bans: *"nothing from beyond the top of the
   circles unless traffic, a screen, or a displaced keeper lifts it."* A clean point shot from
   ~18 m is xG ≈ 0.02–0.03. It never clears the bar.
2. **Nothing prices the second chance.** The rebound term was deleted; `action_scoring.gd:2353`
   records that its input "is always empty on this family". Tracked as issue **#577**.
3. **Low-to-high therefore has no payoff either.** A pass is scored `lane × xG(receiver)`
   (`score_pass_value`, `action_scoring.gd:2321`), so a feed to a point man scores ≈ 0.02 —
   sitting exactly on `PASS_MIN_VALUE = 0.02`. The pass that sets up the point shot is as
   marginal as the shot itself.

The behavioral consequence is what makes this worth a finding rather than a duplicate of #577:
`AIRoleDefenseman._decide_point` runs a **walk-the-line argmax whose entire objective function is
`lane_clear(candidate → net)`** — "could I get my point shot through from here?"
(`defenseman.gd:149-151`). Two roles per team spend every offensive-zone possession optimizing for
a shot the carrier model will never let them take. The O-zone resolves only as carry-to-slot, seam
pass, or dump; there is no shoot-for-a-rebound, no traffic-and-recover, no sustained cycle built on
shot volume.

Deflections *do* exist and are modelled well (`tip_ev` at `action_scoring.gd:2148`, and the
carrier's `_shot_sample_is_tip` commit path at `carrier.gd:1652`), but only when a teammate is
already standing **on** the shot
line — which the FINISHER's TIP/SCREEN STATION does reach. So the tip half is built and the
rebound half is not.

**Recommendation.** This is #577's fix, but the acceptance criterion should be behavioral, not just
numerical: *a 5v5 O-zone possession with a net-front man should sometimes resolve as a point shot.*
Until then, consider whether the walk-the-line objective should be honest about the fact that
nothing consumes it.

---

## 8. F7 — Two of the FINISHER's six stations are unreachable

**Verdict ⚠️ · P2 · `finisher.gd:261-292, 339-346`**

The named-station candidate set is good geography — net crash, backdoor, bumper, weak dot, high
slot, tip/screen. But the depth gate directly beneath it is:

```gdscript
var depth_cap: float = stage_dist            # lerp(SLOT_DIST_M 5.0, RUSH_NET_DRIVE_DIST_M 2.5, rush)
...
if absf(c.z - goal_z) > depth_cap:
	continue
```

`stage_dist ∈ [2.5, 5.0]`, so at **every** rush factor:

| station | depth off goal line | survives? |
|---|---|---|
| net crash / search centre | 2.5–5.0 | ✓ |
| backdoor | 1.5 | ✓ |
| bumper | 5.0 | ✓ at rest only |
| tip/screen station | ≤ 2.5 | ✓ |
| **weak dot** | **6.10** | ✗ never |
| **high slot** | **9.5** | ✗ never |

The cap's rationale is sound and explicitly flagged as a *feel* decision ("on a rush the second
attacker drives the net"), but it was written against the rush end of the range and it also bites
at the set-cycle end, where the doc says the finisher should be staging the cross-seam one-timer.
The weak-dot and high-slot candidates are dead code.

**In 5v5 this is mild** — `HIGH_SLOT` is its own role, and `NET_FRONT` should be net-front. **In
3v3 it is a real shape problem**: `FINISHER` is the only net-side threat, `SUPPORT` is pinned to
the high post 3 m inside the blue line (`support.gd:66`), and the FINISHER is capped inside 5 m of
the goal line. A 3v3 carrier working the corner has a man in the crease and a man at the blue line
and **nothing in between** — no low support, no weak-dot one-timer office, which is a staple of the
3v3 game this project defaults to.

**Fix options:** cap on the *rush* term only (`lerpf(INF, RUSH_NET_DRIVE_DIST_M, rush)` in
spirit — i.e. apply the cap only above some rush factor), or make the cap team-size-aware, or
delete the two candidates the cap can never admit. All three are honest; the second is the one that
matches what the constants say they are for.

---

## 9. Deliberate limitations (noted, not findings)

**F8 — no plain slapshot from carry.** `SkaterAgentStateMachine.State` has `SHOOT_PRESSED`
(wrister) and `ONE_TIMER_PRESSED` (slapper). `docs/gameplay-design.md:23` states the design
outright: *"the one-timer is their only slapper."* Worth knowing what it costs: the point blast — a
D winding one up from the line with traffic — is unavailable to bots by construction, which
compounds F6. If F6 is ever addressed, this becomes the natural delivery for it.

**F9 — no shifts, penalties, or goalie pull.** There are no penalties in the game, no bench, and no
extra-attacker logic anywhere in `Scripts/`. Stamina and sprint lockout exist and are correctly
threaded through every race read (`BotSprintRules.race_speed`), but there is no shift-management
concept — which is correct for one-player-per-machine 3v3/5v5 and not a bot-AI gap.

**Faceoffs are handled, correctly, without special-casing.** A D-zone draw resolves as `DZONE` via
the loose-puck-in-own-zone override (`possession_state.gd:142`), the alignment is the researched
NHL wall-and-stack (`game_rules.gd:664-686`), and the draw itself falls out of the ordinary chase
election — the centre on the dot wins it on ETA, and the contested-pickup rule deliberately still
fires for the jam (`loose_puck_chase.gd:240`). No finding.

---

## 10. Validated behaviors

These were checked against doctrine and hold up. Listing them because an audit that only reports
faults misrepresents the system.

**Structure and shape**
- ✅ The six-state possession table (`possession_state.gd`) splits on both possession *and* puck
  zone, and the header's argument for why collapsing either pair inverts the behavior is correct.
- ✅ **Coverage readiness** — "get back, get set, then take your man" is modelled explicitly, with
  the right asymmetry (easy to become set, hard to stop being set) and a monotone predicate that
  needs no fallback timer (`possession_state.gd:50-86`, `rush_read.gd:409`).
- ✅ Parity rather than everybody as the readiness bar, capped at the bodies we have, counting
  **bots only** — all three are correct reads of the doctrine they cite.
- ✅ Man defense and zone defense unified behind one `cover_threat` verb with the area entering as
  *eligibility* in a single matching (`team_brain.gd:366-493`). The measured 61%-double-cover
  defect this replaced is the kind of thing five independent argmaxes always produce.
- ✅ The 5v5 F/D group scoping with cross-fill is the right way to get "a D activates, a forward
  covers his point" as emergent rather than scripted (`role_slots_5v5.gd`).
- ✅ RUSH_D1's feasibility deadline — a D who cannot get goal-side in time defers the slot so the
  backchecking third man picks up the rush (`role_slots_5v5.gd:197-210`). That is real, and most
  games don't model it.

**Defending**
- ✅ A defensive stand is a **moving frame**, not a spot, and the route is flown in that frame.
  The measured 10.8 m/s vs 1.3 m/s relative-speed difference at the meet is the whole argument.
- ✅ Odd-man doctrine falls out of the evaluators rather than being scripted: the goalie is in both
  terms of RUSH_D1's lane fan, so "goalie takes the shooter, I take the pass" emerges
  (`rush_d.gd:388`). `DOWN_ONE` concedes **laterally, never deeper** — exactly right.
- ✅ Backcheckers **sprint until home, then pick up** — no argmax while recovering
  (`track.gd:169-187`). The lane-ownership pickup bound (post depth + cover envelope) correctly
  stops a tracker chasing a trailer 37 m up-ice.
- ✅ TRACK_PUCK takes the hip **unangled** — a backchecker has no inside to take. Correct, and a
  subtle read most implementations get wrong.
- ✅ Checks are gated on being goal-side (`track.gd:60`), and the last-man gap defender never hunts
  hits. Both are real discipline.
- ✅ The house gate (top of the circles) as the floor for every field skater — past it you
  duplicate the goalie.
- ✅ D-zone breathing anchors that collapse toward the house and extend to the points, and the
  strong winger stepping into the **shot lane** rather than chasing the point man
  (`zone_coverage.gd:159-168`).

**With the puck**
- ✅ Carry safety as a reachable-set pursuit-evasion model, with the momentum projection that makes
  "beat him by letting him overshoot" fall out rather than being scripted.
- ✅ Puck protection aimed at the **directed** seam rather than max clearance — the far-hip bug this
  fixed is a real failure mode and the diagnosis (a shield only matters when the checker is in
  front) is exactly right.
- ✅ The boards bounding the handling envelope, so the wall pincer emerges and a pinned carrier
  moves it before he dies there.
- ✅ Saucer passes priced under real flight kinematics, with the landing-runway bound.
- ✅ Receiver-commitment pricing — a feed into a hard pivot reads as the giveaway it is.
- ✅ Dump-ins searched as **releases** and priced where the puck **stops**, with icing as a race
  rather than a distance. The "a launch that dies in our own zone cleared nothing" filter is
  doctrine expressed as a filter, which is right.
- ✅ The blue-line valve buffered on **both** sides, including the windup dragging the puck back
  across the line during a pass. That is a real thing that happens to real players.
- ✅ Offside honesty in the off-puck roles: OUTLET's velocity-corrected filter, WIDE_L/R holding
  NZ-side until the puck crosses, and the ghosted tag-up sprint.
- ✅ The OZ points stand a **full puck-handling radius** inside the line (`POINT_INSET_M = 2.0`) so
  a reception's cushion can't un-onside the attack. Exactly the right reason for the number.

**Difficulty**
- ✅ Three independent axes (precision / pace / cognition) with the rule that a gate may only remove
  an *input* or an *option*, never corrupt a shared evaluator. This is the correct architecture for
  tiering and it is rare.
- ✅ Settle doubt as a **raised bar** rather than a timer — obvious plays stay instant, close calls
  deliberate. That reads as a human, and the reasoning for why the handicap goes against the bar
  and not against the carry is sound.

---

## 11. Suggested order of work

1. **F3** (both D pinch) — smallest diff, largest behavioral change, and it is a straight
   restoration of the design of record. One constant and a strong-side gate.
2. **F2** (forechecker's gap) — needs a real decision about what PRESSURE's stand-off means in the
   attacking zone, but the fix is local to one role.
3. **F1** (ladder divisor) — one character, but it moves every defensive body measurement, so it
   wants the harness runs (`test_rush_gap_discipline.gd`, `test_defensive_routing.gd`) before and
   after. Fix the plan doc's table in the same change.
4. **F4** (shot blocking) — new behavior, but the mechanic and physics already exist; the poke jab
   is the template.
5. **F7** (finisher depth cap) — small, and it matters most in the default 3v3 mode.
6. **F5** (stick lift) and **F6** (#577, rebounds) — larger, and F6 in particular wants logged
   shot data rather than a guess.
