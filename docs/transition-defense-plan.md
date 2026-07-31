# Transition defense (TRANS_OD) — reground

Status: **implemented** for 5v5 and 3v3. Phases A–E landed; playtest pending. Supersedes the TRANS_OD sections of
`docs/5v5-ai-plan.md` (§2 TRANS_OD, and the defensive half of §5); the O-zone,
forecheck and breakout designs in that doc are unchanged, and its D-zone design is
unchanged *in content* but now gated on coverage readiness (§9).

**Scope.** 5v5 was built first (the hard problem, and the one with a real structure to
get right); 3v3 then reused the same behavior modules with a three-slot election, and
needed no changes to them. See §5.2.

### Decisions banked

- **`TRACK_PUCK` may body check** — same commit logic as every other checker
  (`AIBodyCheck.evaluate`, only genuinely separating hits), with the extra gate that it
  must already be goal-side of the carrier. A backchecker who catches a carrier from
  behind is a legitimate hit; hunting one from up-ice is not.
- **3v3 runs the compressed three-role set** (`RUSH_D1` / `TRACK_PUCK` / `TRACK_MID`),
  no dedicated `RUSH_D2`. Two bodies on the puck is affordable because transition is
  bounded — see §5.2.
- **`numbers` gets hysteresis** — enter/hold margins on the same pattern as
  `AIPossessionState.retrieval_read`, so one body crossing the puck line can't flip the
  whole team's aggression mid-rush.
- **DZONE entry is gated on coverage readiness** (§9) — the team stays in the rush /
  recovery shape until the coverage it would switch to actually makes sense.

Research appendix at the bottom. The uncomfortable finding up front: the rush-defense
doctrine in `docs/5v5-ai-plan.md:542` is **already correct and already in the repo** —
the implementation drifted off it one local fix at a time. This document is not new
research so much as a return to it, with the structural change that makes it
implementable.

---

## 1. Symptoms

Reported from play, in the developer's words:

1. **Bots park at their own goal line while the play is up-ice toward the offensive
   zone.** Not on a rush — during ordinary offensive possession.
2. **No backcheck urgency.** A human can collect the puck in the neutral zone and skate
   past bots that are "lazily marking men." Nobody hurries home to stop the puck.
3. **No gap-up on the 1-on-1.** Defenders sag off a carrier they should be standing up.
4. **A bot stuck deep (1) defends badly** — bad routes, beaten easily.

These read as four bugs in three states (OZONE/TRANS_DO, TRANS_OD, DZONE). They are one
bug.

---

## 2. Root causes

### 2.1 The race-home read is a conjunctive worst-case veto, evaluated per player

`AIRoleHelpers.fill_counter_channels` + `race_home_feasible` + `most_forward_feasible`
(`role_helpers.gd:723–1163`) is the bound on nearly every defensive station: CONTAIN's
advance clamp, the O-zone points' keep-in, the forecheck D pair, DVALVE, DBACK, FLANK.

A stand is feasible only if it contains **every channel of every opponent**:

- every opponent gets two channels (outlet feed + retrieval), including their D standing
  40 m away behind their own blue line;
- each outlet is priced at the **hardest legal feed on the rink**
  (`DEFAULT_WRISTER_POWER_MAX_M_S`);
- the counter racer **sprints**; the defender must arrive **set**, with closing speed
  killed, at some station on the path;
- and it is an **AND over all channels** — one uncontainable channel collapses the whole
  stand.

When it fails, `most_forward_feasible` bisects down the retreat line toward
`_race_home_stand` — the crease top. So: worst-case threat model × conjunction × a floor
at the crease = **symptom 1**.

Each of the five bots computes this independently and gets the same answer, so they all
retreat together. The model has no way to say *"someone is covering that; it isn't
yours."*

### 2.2 `has_support_behind` makes every bot the last man back

`role_helpers.gd:997` is a raw depth scan: is any teammate deeper in z than me? On a
rush everyone is up-ice, so **every** defender reads `false`, and every defender takes
the conservative branch:

- CONTAIN skips the blue-line stand (`contain.gd:211`) — the aggressive read almost never
  fires on a real rush, which is exactly when it was designed to fire;
- CONTAIN applies the last-man rendezvous clamp (`contain.gd:320`), which only ever makes
  the gap **deeper** (`gap = maxf(gap, settable)`);
- PRESSURE applies the same clamp (`pressure.gd:157`).

Five last men back is zero defense. This is the load-bearing failure: **there is no
team-level allocation of defensive responsibility**, so responsibility is claimed by
everyone and discharged by no one.

### 2.3 TRANS_OD's structure is man-marking, with no urgency gradient

- The threat partition (`threat_assignment.gd`) hands each MARK a distinct man. A marker
  20 m up-ice still runs the `cover_man_target` argmax and *steers* to it — there is no
  "sprint home through the middle first, pick up second." That is the visible laziness in
  symptom 2.
- The partition **excludes the carrier** on the assumption CONTAIN owns him
  (`team_brain.gd:266–268`). When CONTAIN can't (3v3 has no feasibility check at all;
  5v5 defers via the deadline at `role_slots_5v5.gd:181`), nobody is on the puck.
- **There is no concept of a backchecker attacking the carrier from behind.** Real F1
  tracks the puck carrier the length of the ice and takes his hands. `AIRoleChase` is
  NEUTRAL-only; `evaluate_body_check` is pressurers-only.
- 5v5's TRANS_OD is one spec (`CONTAIN`) plus a four-man `MARK` remainder — the thinnest
  state in the table, against DZONE's five researched zone roles.

### 2.4 Gap is a function of pace, and every clamp is one-directional

`AIRoleContain.gap_for_pace` = `clamp(1.6 + closing × 0.5, 1.6, 6.0)`.

Doctrine is a **distance ladder**, not a pace function: ~3 sticks at the offensive blue
line → 2 at the red line → **1 stick at your own blue line**. The code's 6.0 m cap is
almost exactly 3 stick lengths — *the correct gap for the offensive blue line, applied at
the defensive blue line.* At speed the bot holds an O-zone gap all the way to its own
net.

Then every modifier pushes it deeper: the rendezvous clamp raises it, the blue-line stand
that would lower it is gated off (2.2), and the won-race tightening requires being 2.5 m
goal-side of the carrier **and every unmarked trailer** (`contain.gd:270–277`) — rarely
true. There is no term anywhere that says *close the gap*. Symptom 3.

And there is no **gap-up trigger** — the read that a real defender lives on: the carrier's
speed advantage is gone (he received the puck standing, put his head down, got pushed to
the wall, decelerated), so attack. Modern coaching is explicit that you defend by
**skating forward**, not by absorbing.

### 2.5 The blue line is a geometry discontinuity

TRANS_OD → DZONE re-elects: CONTAIN (a gap point on the carrier→net line) becomes
PRESSURE (a cut-off argmax over a polar ring). The body that had a gap gets handed a
target 6 m up-ice and charges it. `pressure.gd:139–154` documents this exact failure and
patches it with the same rendezvous clamp. In real hockey the D who gapped a carrier
through the neutral zone **keeps him into the zone**; there is no handoff at the line.
Contributes to symptom 4.

---

## 3. The reframe

> The current model asks each bot **"can I personally contain every possible counter?"**
> The answer is almost always no, and the response to no is *retreat*.
>
> The new model asks the team **"how many are back, who owns the puck, who owns the
> middle?"** and hands each bot **one job in one layer**.

Real transition defense is layered and allocated, and the aggression of the whole
structure is set by one number: **numbers back**. Nobody on a real backcheck is
individually solving a worst-case interception problem; they are filling a lane in a
three-layer structure whose depth is set by the count.

Three structural changes follow:

1. **One shared perception object** (`AIRushRead`), computed once per brain tick, that
   every transition role reads — replacing five independent paranoia calculations.
2. **Layered roles** (puck / middle / back), replacing man-marking as the primary read.
3. **Tracking as a distinct mode**, so a bot that is behind the play sprints instead of
   positioning.

---

## 4. `AIRushRead` — the shared read

New pure module `Scripts/domain/ai/rush_read.gd`, computed in `TeamBrain._compute_tick`
alongside the threat partition, published on `TeamBrainView`. Everything below is a
quantity a real player can see.

```
class AIRushRead:
    mode: RUSH | REGROUP | NONE
    threat_axis: Vector3        # puck → our net, normalized
    attackers: Array[int]       # peers genuinely in the rush
    entry_eta_s: float          # time until the puck reaches our blue line
    inside: Array[int]          # our peers already goal-side of the puck
    tracking: Array[int]        # up-ice, but can get goal-side before the circle tops
    beaten: Array[int]          # cannot
    numbers: EVEN_OR_UP | DOWN_ONE | DOWN_TWO_PLUS
    backpressure_s: float       # ETA of the nearest tracker to the carrier's hip
```

**`attackers` is the fix for symptom 1.** An opponent counts only if he is *involved*:
goal-side of the puck, or level with it and carrying net-ward velocity on the threat
axis. Their stay-home D behind his own blue line is not a rush threat and should not
appear in anyone's math. Today he does, at max feed speed, in a conjunction.

**`numbers` is the fix for the five-last-men problem.** One count, shared. It sets the
whole structure's aggression:

| numbers | posture |
|---|---|
| `EVEN_OR_UP` | **Stand up at the line.** Tighten the gap a rung, deny the entry, D2 steps up on the second man. |
| `DOWN_ONE` | Classic odd-man: puck defender **plays the pass**, stays in the middle, stick in the lane; goalie takes the shooter. Give ground *laterally into the seam*, not *deeper*. |
| `DOWN_TWO_PLUS` | Concede depth to the circle-top line, protect the house, everybody funnels middle. Never deeper than the circle tops. |

**`backpressure_s` is the repo's own documented doctrine** (`5v5-ai-plan.md:548`): a
backchecker within ~1–2 s of the carrier lets the D tighten and stand up. It is a real
measurement, it already exists conceptually, and nothing reads it today.

**`mode`** splits the state that is currently conflated:

- **RUSH** — the puck is coming at us with attackers ahead of or with it.
- **REGROUP** — they hold the puck in the neutral zone but it is going away from us, or
  their attackers aren't ahead of it. Posture is the **NZ stand at our own blue line**
  (the 1-2-2 shape), *not* a retreat. This is the second half of symptom 1: bots
  currently retreat during a regroup because the state machine can't tell a regroup from
  a rush.

---

## 5. Layered roles

TRANS_OD's slot set becomes layers. Branching 3v3 / 5v5, with precedent
(`AIRoleSlots` vs `AIRoleSlots5`).

### 5v5 — the researched five

| Slot | Group | Job |
|---|---|---|
| `RUSH_D1` | D | Strong-side D. Owns the carrier. Gap ladder, angle him off the middle, persist across the blue line. |
| `RUSH_D2` | D | Weak-side D. Holds **mid-ice** — the mid-lane drive is fed to D2. On `DOWN_ONE`, this is the man in the passing lane. |
| `TRACK_PUCK` | F | F1 back. Tracks the **carrier** through mid-ice all the way to the net, then low support. Attacks his hands when he gets there. |
| `TRACK_MID` ×2 | F | F2/F3. Back through **mid-ice**, stop just inside the **tops of the circles**, sticks on the ice. Pick up whoever enters their lane. |

Election targets are lane recovery points, not men. Group-scoped as today, with the same
cross-fill for a short group.

### 5.2 3v3 — the same three layers, compressed

3v3 runs the **same behavior modules**, elected into three slots:

| Slot | Job |
|---|---|
| `RUSH_D1` | Owns the carrier — soonest to our net, the same metric CONTAIN used. |
| `TRACK_PUCK` | Runs the carrier down from behind. |
| `TRACK_MID` | The centre lane (no side split — there is no pair to split around). |

`RUSH_D2`'s mid-ice layer folds into `TRACK_MID`. The modules needed no changes:
they read only universal context (`rush_read`, `strong_x`, `self_blade_reach`,
`defending_goal_pos`) — the F/D split lives entirely in the 5v5 *election*, never in
the behavior.

**Two bodies on the puck is correct here.** It is not the old "PRESSURE +
BACKCHECK both engage forward" failure `role_slots.gd`'s header warns about:
`RUSH_D1` is in FRONT holding a gap and `TRACK_PUCK` is BEHIND running him down —
one rush defended from both ends, not two bodies taking bad angles from the same
side. And it is affordable because **transition is bounded**: the moment the attack
becomes a settled three-man threat needing a body on each man, the puck is in our
zone and DZONE's coverage owns it. TRANS_OD's job is to kill the rush, not to solve
coverage.

**The coverage gate (§9) applies to 3v3 as well.** The worry that it would leave
two-on-the-puck under-covering inside our own zone compares TRANS_OD's three roles
against DZONE's *nominal* coverage (PRESSURE + MARK×2 = all three men). But that
coverage is the very fiction §9 exists to expose: with the bodies not home, a MARK
computes a cover position from 20 m up-ice and escorts. The gate holds the rush
shape exactly while somebody is still on the way home, and in that state sprinting
home strictly beats walking to a post.

And the shapes **converge by construction**: RUSH_D1 is home already, TRACK_PUCK
chases to the net, TRACK_MID stops at the circle tops — so the rush roles themselves
bring all three into the house, satisfy the predicate, and hand off to man coverage.
There is no state where a defender double-covers the puck while a man he owns is
threatening: a threatening man in 3v3 is central, and the lone mid tracker owns the
whole middle. Both team sizes behave the same way.

### Why lanes beat men here

Man-marking is correct **below the dots in the D-zone** (the repo's hybrid, `§3` of the
5v5 plan) and wrong in transition. Through the neutral zone the priority is the **middle
lane**, not any particular body: you take away the middle, force the play outside, and
pick up whoever enters your ice. The soft-lock machinery for exactly this already exists
and is proven — `AIZoneCoverage.most_dangerous_man_in_area` with boundary hysteresis. The
change is to **extend it up the ice**, with three transition lanes instead of five zone
areas.

The threat partition doesn't die — it keeps running for DZONE. It simply stops being
TRANS_OD's primary structure.

---

## 6. Gap control, regrounded

Replace `gap_for_pace` with a **ladder on ice remaining**, at three real landmarks:

```
sticks(d) = clamp(1 + d / (BLUE_LINE_Z * 2), 1, 3)      # d = carrier's distance to OUR blue line
gap_m     = sticks(d) * BLADE_REACH_M
```

- carrier at their blue line → 3 sticks
- carrier at the red line → 2 sticks
- carrier at our blue line → **1 stick**
- carrier inside our zone → 1 stick / contact; you are on him

`BLADE_REACH_M` is the honest physical unit and it is already attribute-scaled per build,
so a long-stick defender legitimately plays a slightly wider gap.

Modifiers, in this order:

1. **Numbers** — `EVEN_OR_UP` tightens one rung; `DOWN_TWO_PLUS` loosens one rung but
   never past 3 sticks. `DOWN_ONE` does **not** loosen the gap: it rotates the stand
   laterally into the pass lane. Odd-man defense is a *lateral* concession, not a
   *depth* concession — this is the single most common way the current model goes wrong.
2. **Backpressure** — `backpressure_s < ~1.5` tightens one rung and re-enables the
   blue-line stand.
3. **Pace** — a small correction for a carrier genuinely flying, capped at half a stick.
   Demoted from the driver to a modifier.

### The gap-up trigger (new)

The concept the developer named as missing. A defender attacks — closes to stick range on
an angle, skating forward — when the carrier's speed advantage is gone:

- his closing speed on the threat axis has dropped below what we can match moving
  forward, **or**
- he has just received the puck and is not yet up to speed, **or**
- he has been steered inside ~2 m of the wall (no room to beat us wide).

Every input is directly observable. This is "defend by skating forward" — the modern
doctrine — and it is what makes a 1-on-1 feel contested instead of conceded.

### Angling (new)

`RUSH_D1`'s target is not on the carrier→net line. It is offset to the **inside**, so the
retreat path steers the carrier off the middle and toward the wall. Today PRESSURE has a
goal-side *filter* but no *force-outside objective*, and CONTAIN sits dead on the retreat
line. Take away the middle, give the outside.

---

## 7. Tracking mode — where urgency comes from

A peer classified `tracking` **does not run positional argmax at all.** Its dispatch is:

- target = its lane's recovery point (mid-ice, at the rush's depth) — not a man, not a
  cover anchor;
- **sprint forced** (the body-check-commit path already does this,
  `skater_agent_state_machine.gd:2150`), not the gap-gated `_resolve_sprint`;
- no arrival brake, no anti-crowd filter, no incumbent hysteresis — all of which exist to
  make a *stationary post* stable and all of which read as dithering when you are behind
  the play;
- converts to its layer's coverage behavior on the tick it crosses **goal-side of the
  puck**.

That hard mode switch is the whole of symptom 2. Real backcheckers sprint until they are
back, *then* pick up. Bots currently interpolate between the two and do neither.

`TRACK_PUCK` is the exception worth calling out: it tracks the **carrier's hip**, not a
lane point, and when it arrives it is allowed to attack the puck (poke / stick-lift, and
`evaluate_body_check` should be opened to it — a backchecker catching a carrier from
behind is a legitimate hit, and it is currently forbidden by policy at
`role_helpers.gd:487`).

---

## 8. Retreat floors, and what happens to the counter-channel model

**Defensive stations stop calling it.** `RUSH_D1/D2`, `TRACK_*`, FLANK, DBACK take their
depth from their layer, bounded by `numbers`. Hard floor for any field skater in
transition: the **top of the circles** (`AIZoneCoverage.HOUSE_TOP_DEPTH_M`, 10.7 m off the
goal line) — the depth the research names explicitly, and ~11 m shallower than today's
crease-top floor. Below that line is in-zone coverage's business, not transition's.

**Offensive stations keep it, with two repairs.** For the O-zone points, DP pair, SUPPORT
exposure and the carrier's `counter_rush_cost`, "can I get back if this goes wrong?" is
genuinely the question being asked, and the model answers it well. But:

- **restrict the threat set** to genuine counter threats (the `AIRushRead.attackers`
  filter), not every opponent at max feed speed — this alone should lift most of symptom
  1's offensive half;
- **raise the retreat floor** from the crease to `AIZoneCoverage.defensive_anchor` — a
  defenseman's home is the dot lane at **his own blue line**. A D who can't hold his pinch
  retreats to his blue line, not to the goal line. He is a defenseman, not a second
  goalie.

Keeping the model where it earns its keep and removing it where it doesn't is the whole
change; it is a good pinch evaluator and a bad positioning primitive.

> **Superseded — the model is gone entirely.** §13.2 (written later in the same effort)
> found that the pinch is not a race simulation either, and the offensive stations moved
> to `offensive_station_target`. That left the two NEUTRAL shapes (3v3 FLANK, 5v5 DBACK)
> as its only consumers, and they have since moved to `neutral_station_target` — the same
> categorical read, conceding a numbers layer instead of a post. `fill_counter_channels`,
> `race_home_feasible`, `most_forward_feasible`, `collect_counter_threats`, `ThreatSet`
> and the station grid are deleted.
>
> What decided it: NEUTRAL is ~0.1% of live play (five clean bot-vs-bot samples), so the
> two survivors were paying a per-station conjunction over every attacker's channels for
> a shape almost nobody is ever in; and in NEUTRAL the puck is loose by definition, so
> every attacker was priced an OUTLET channel as a max-speed feed that no one was in a
> position to throw. Neither defect is fixable without rebuilding the model into the
> shared read it was already superseded by.
>
> One behavior genuinely changed with it: at our own blue line, under the enforced
> ruleset, nobody can legally be behind the DBACK pair while the puck is out of our zone,
> so the shared read never bounds that stand — the offside rule IS the bound. The old
> model routed such a lurker's channel through a tag-up at the line and sagged the pair
> for him. `test_role_defenseman.gd` pins both halves (holds under enforced offsides,
> sags with the rule off).

---

## 9. Coverage readiness — the transition → DZONE handoff

The current handoff is **a line on the ice**. `AIPossessionState.compute` flips to DZONE
the instant the puck crosses our blue line with the opponent carrying, and
`AIRoleSlots5` immediately re-slots all five bots into the five zone areas.

That means three bots who are 25 m up-ice, mid-backcheck, stop backchecking and start
skating to **zone posts**. The structure they're joining assumes five bodies are home; it
is being run by two. This is a large part of symptoms 2 and 4 — the backcheck visibly
dissolves at the blue line, and the bots that *are* home get no help because their
teammates are filling formation anchors instead of coming back through the middle.

Real hockey has an explicit readiness concept: *get back, get set, then take your man.*
Coverage is something you're **in** or **not in**, and it isn't decided by where the puck
is.

### The predicate

Coverage is set when **every attacker is accounted for and the puck has a pressurer**:

- each `AIRushRead.attackers` entry has one of our peers **goal-side of him** and within
  a coverage envelope of his lead point, **and**
- the carrier has a defender engaged or within about a stick of engaging.

That is the coaching read ("everybody's got a man, somebody's on the puck") and it is the
exact shape of the already-proven `AIRoleContain._teammate_home_on` primitive — which
gets promoted out of `contain.gd` into `AIRushRead` and reused for both purposes.

### The gate

The brain **upgrades** its raw possession-state result, same seam and same shape as the
the (since-removed) `RETRIEVAL` upgrade — see docs/breakout-plan.md Phase A:

```
if raw_state == DZONE and not coverage_read(rush_read, was_set):
    state = <rush/recovery shape>       # stay in transition
```

with enter/hold margins so the boundary can't flicker (`COVERAGE_SET_ENTER` /
`COVERAGE_SET_HOLD`, hysteresis in the same direction as `retrieval_read`: harder to
declare set than to stay set).

Symmetrically, once set the team **holds** coverage until the rush-over conditions
genuinely fail — a re-entering rush after a failed clear shouldn't dump a set structure
back into scramble mode over one bad read.

### What runs while not set

Not a separate state — the same layered roles from §5, with their depth allowance
tightened because the puck is already in our zone: `TRACK_*` sprint their lanes to the
house rather than to the circle tops, and `RUSH_D1` keeps the carrier. This is
recovery/scramble defense, and it is genuinely the same structure as rush defense with a
shorter field, which is why it does not need its own state.

### Rush continuation falls out of this

The original §9 concern — `RUSH_D1` keeping the carrier across the blue line rather than
being re-elected into PRESSURE — is now just a consequence: while coverage isn't set, the
state never flips, so nothing re-elects and there is no target discontinuity. When it
does flip, `RUSH_D1` becomes the strong-side zone D (the `_hysteresis_class` continuity
map already pairs those two, `role_slots_5v5.gd:536`), so the same body keeps the same
man through the rename.

The rush-over predicate still exists for the *other* direction — deciding the rush is
dead when the puck goes below our goal line, we establish possession, or the attack
stalls — because those are what let a set structure stay set.

### The predicate: home-ness, not man-coverage (revised)

**As first shipped this was wrong, and the risk below is exactly how it went wrong.** The
predicate asked "does every attacker have one of ours goal-side within a cover envelope,
and is somebody engaged on the carrier?" That is a description of **man** coverage — and
5v5 DZONE runs a hybrid **zone**, which covers ice rather than bodies by definition. So a
*correctly executed* zone failed the gate. Measured against `AIZoneCoverage`'s own anchors
for a settled cycle (carrier on the strong half-wall):

| clause | what the zone actually does | verdict |
|---|---|---|
| a body ≤4 m goal-side of every man | `ZONE_W_WEAK` sags to the high slot, ~8 m off the weak winger | fails |
| a body engaged on the carrier | `ZONE_W_STRONG` pressures the half-wall from **up-ice** — correct hockey, not "goal-side" | fails |

The gate could never be satisfied by the shape it gates entry into, which made the time
floor below the *only* path into the zone: every cycle spent its first 4 s in the rush
shape and entered coverage when the timer expired, not when the team was set.

The predicate is now **home-ness at parity** (`AIRushRead._coverage_ready`): as many of
our bodies have arrived inside our defensive zone as there are attackers to cover, capped
at the bodies we have. Doctrine sets both halves.

**Where — the blue line.** "The transition from backcheck to defensive zone coverage
happens at the blue line — as you enter your defensive zone you identify your coverage
responsibility." It is also the structure's own footprint: every zone anchor sits ≤11 m
off the goal line, well inside our zone's ~19 m, so a correct shape passes by construction
rather than by tuning. Pinned by `test_a_real_zone_shape_reads_as_set`, which stands the
bots on the real anchors.

**How many — parity, not everybody.** Doctrine keys the end of backcheck urgency on
NUMBERS: F2 "backchecks aggressively until numerical parity is achieved, and then protects
the house"; F3 "skates hard to even the numbers if the team is outnumbered". The first
implementation required EVERY body, which was **the mirror image of the bug this document
exists to fix** — instead of five bots each concluding it was the last man back, it made
four home bots wait on a late fifth. A team-level all-or-nothing driven by the worst
individual, either way. Once the numbers are even the home bodies set up and the late man
joins as a layer, which the soonest-to-arrive election delivers for free: the bodies
already home win the important jobs and the straggler inherits the leftover.

**Capped at the bodies we have.** You cannot be asked to produce a defender that does not
exist. Without the cap, being genuinely a man short makes parity unreachable and the read
permanently false — the failure the deleted guard existed for.

Those two together keep the read **monotone** in the recovery it waits on: arrivals only
raise the count and the bar never rises. That is what makes the time floor unnecessary
rather than load-bearing. `test_there_is_no_time_fallback` pins that no elapsed time
overrides it.

**Bots only** (`bot_peers`; empty counts every teammate). Load-bearing in *both* terms
now: a loafing human must not inflate the requirement he will not satisfy, nor raise the
bodies-we-have cap. Waiting on a body you cannot steer is the same "individual worst-case"
reasoning this whole read replaced.

### Residual risk from parity (watch in playtest)

Parity releases bodies into coverage while some are still 20 m up-ice, so their *route*
now matters. Measured: 5v5 is fine — `ZONE_W_STRONG` / `ZONE_W_WEAK` anchor at depth
9.9 / 10.2 m, i.e. the tops of the circles, which is exactly where doctrine parks a
returning F2/F3, and the zone's soft-lock only claims men inside its own area. **3v3 is
the exposure**: DZONE there is `PRESSURE + MARK`, and a MARK 20 m up-ice steers to a cover
position beside his man rather than home through mid-ice (root cause §2.3). Sprint itself
is not the issue — `BotSprintRules` gates on gap (`GAP_ENGAGE_M` 6 m), so a distant bot
sprints either way. If symptom 2 resurfaces in 3v3, the fix is MARK's route, not the gate.

Retained: the leave-coverage hysteresis (`COVERAGE_HOLD_TICKS`), instant on the way in.
A body straddling the blue line to pressure the point is not a broken structure.

---

## 10. Ledger

**Died** (deleted)
- `AIRoleContain` + `test_role_contain.gd` — replaced by `AIRoleRushD`. `Slot.CONTAIN`
  is gone from the enum, along with its dispatch case, reactive-slot entry, poke-gate
  entry and debug label.
- `gap_for_pace` and the pace-driven gap — replaced by `AIRoleRushD.ladder_gap_m`, which
  `AIRoleChase`'s lost-race pre-contain shares (that sharing is deliberate: the declining
  chaser plants where `RUSH_D1` will want him).
- `ThreatSet.CONTAIN_TRAILERS` — `contain.gd` was its only producer.
- TRANS_OD's dependence on the threat partition (still live for DZONE).
- The crease-top retreat floor.

**Survived, contrary to the original plan**
- `has_support_behind` and `settable_stand_depth` — still `PRESSURE`'s own last-man
  step-up discipline once the zone is gained. The rush side no longer needs them because
  the gap ladder is bounded by construction, but the in-zone cut-off still is not.

**Reused as-is**
- The soonest-to-arrive election machinery + hysteresis, both files.
- `AIZoneCoverage` soft-lock + boundary release — extended up-ice into transition lanes.
- CONTAIN's **odd-man lane fan** (`contain.gd:378`). This part is good: it derives 2-on-1
  doctrine from the evaluators rather than scripting it, and the research agrees with it
  (play the pass ~92% of the time, goalie takes the shooter). It moves onto `RUSH_D1`
  under the `DOWN_ONE` read, where the numbers read tells it *when* to apply instead of it
  inferring that from receiver danger alone.
- The threat partition, for DZONE.
- ~~The counter-channel model, for offensive pinch decisions (§8).~~ Superseded by §13.2
  and since deleted outright — see the note at the end of §8.

**New**
- `Scripts/domain/ai/rush_read.gd` + GUT tests.
- `Scripts/domain/ai/role_behaviors/rush_d.gd` (RUSH_D1/D2).
- `Scripts/domain/ai/role_behaviors/track.gd` (TRACK_PUCK / TRACK_MID).
- Tracking-mode dispatch branch in the agent state machine.
- Rush-over predicate + continuation.

---

## 11. Phasing

The full rewrite is committed to; the phases are implementation order, not a menu. Each
is independently testable against `tests/unit/ai/rush_sim_harness.gd`, which already
exists, and each ends at a green suite so a regression is bisectable to one phase.

- **A — `AIRushRead`.** Pure module + GUT tests, published on the brain and `TeamBrainView`
  but read by nobody. Asserts the perception (attacker filtering, numbers + hysteresis,
  tracking classification, coverage predicate) before anything depends on it. No behavior
  change.
- **B — Retreat floors + attacker filtering.** Raise the floors (§8), restrict the
  counter-channel threat set to `AIRushRead.attackers`. Smallest behavioral diff; targets
  symptom 1 including its offensive half.
- **C — Gap ladder + gap-up + angling.** Lands on `RUSH_D1`'s new module. Targets
  symptom 3.
- **D — Layered roles + tracking mode.** 5v5 slot set, `rush_d.gd` / `track.gd`, the
  tracking dispatch branch, `TRACK_PUCK`'s goal-side-gated check. Targets symptom 2.
  3v3 keeps its existing path (§5.2).
- **E — Coverage readiness gate** (§9) + the rush-over predicate. Targets symptom 4 and
  the backcheck-dissolves-at-the-blue-line failure.

Playtest checkpoints after **B** and after **D** — those are the two points where the
feel should visibly move, and E's gate is the piece most likely to need tuning against
what the first two reveal.

---

## 12. Open questions

Resolved items moved to **Decisions banked** at the top.

1. **`DOWN_ONE` lateral concession vs. the existing lane fan.** The fan already finds the
   pass lane from evaluators. Does the numbers read *gate* it (cheap, explicit) or just
   *bias* it (keeps everything emergent)? Leaning gate — the research is unambiguous that
   this is a mode switch, not a gradient. Decide during phase C against the harness.
2. **Cognition tiers.** Which of these become difficulty knobs? `backpressure_s` awareness
   and the gap-up trigger are natural Easy/Hard splits (`plays_rush_pass_lanes` is the
   precedent). Deferred to after the structure is playing well.
3. ~~**Coverage-gate latch risk**~~ — **resolved, see §9.** The gate was unsatisfiable by
   the zone it gated and the time floor was carrying it. Predicate regrounded on
   home-ness; the floor is deleted. Nothing here is left to tune: the bar is the blue
   line, and the two properties that replaced the guard (satisfiable, monotone) are
   pinned by test rather than watched in play.
4. ~~**Latch risk at 3v3 specifically**~~ — moot with the latch gone, and the premise was
   backwards anyway: 3v3 DZONE is `[PRESSURE, MARK]`, real man coverage, so the *old*
   man-shaped predicate matched 3v3's shape honestly and it was **5v5** that could never
   satisfy it.

---

## 13. Offensive positioning — the other half of symptom 1

Symptom 1 has two halves. §8 fixed the neutral-zone stations; the O-zone half is
still live, and the reported behavior is exactly the two failure modes the coaching
literature names: **"too spread out leads to isolated puck carriers"** and **"a common
mistake is to float far away from the puck in an effort to be 'open' instead of finding
angles of support."**

### 13.1 Root causes

**(a) The bound is applied at P(turnover) = 1.** `race_home_feasible` answers a
conditional — *"if the puck were turned over right now, could I contain the counter?"* —
and the offensive stations treat `false` as binding. A D holding the offensive blue line
with clean possession 40 m away retreats as though the puck were already lost.

The grounded turnover read **already exists and is already used**: `support.gd:123`
computes `turnover_prior = 1.0 - AIActionScoring.carry_safety(...)`. SUPPORT prices its
counter risk by the real probability; the points, the DP pair, HIGH_SLOT and DVALVE never
consult it. That asymmetry is the bug.

**(b) §8's attacker filter is inert during offensive possession.** An opponent is admitted
if he reaches our net within `rush_eta + LATE_MAN_WINDOW_S`; with the puck deep in their
end `rush_eta` is the ~6 s hypothetical lug the length of the ice, so essentially every
opponent qualifies. §8 helped the short-`rush_eta` neutral-zone stations and did nothing
for the O-zone points. (Correcting the claim in §11 phase B.)

**(c) The floor is far too deep.** `station_retreat_floor` for a D is the dot lane at his
OWN blue line — from a point stand at the offensive blue line, a ~17 m retreat landing him
30+ m from the play.

**(d) Nothing bounds a station from being too far from the play.** Every bound pulls
toward home; there is no forward bound anywhere in the role behaviors.

**(e) "Struggles to pick up a man" follows from (a)–(d)**, plus an interaction with §9: a
body stranded in the NZ during a cycle is neither in the rush structure nor in coverage
when possession flips, and the readiness gate correctly holds the whole team in the rush
shape while he is still on the way home. One stranded bot prolongs the scramble for everyone.

### 13.2 The real pinch read is not a race simulation

This is the finding that changes the design. The counter-channel model was retained in §8
on the grounds that it is "a good pinch evaluator." The research says the pinch is read
from three coarse, categorical facts — none of which is a counter-path simulation:

1. **Control.** *"The only time a defenseman should be standing on the offensive blue line
   is when his team has complete control of the puck."*
2. **Support behind.** *"A defenceman can only pinch when they have a supporting player in
   position to back them up should the puck/player get past them"* — reading whether there
   is an **F3 high** is what alters the decision.
3. **Numbers.** *"The first rule defensemen are taught is to count numbers — how many
   opponents are in front of them and if any are behind them."*

And the retreat **trigger** is *"the other team gains clear possession and is moving out of
the zone with multiple passing options."* Not "I might theoretically be beaten home."

So the fine-grained race simulation is not just expensive here — it is **systematically
more pessimistic than the read coaches actually teach**, which is why it strands bodies.
Offensive stations stop calling it.

### 13.3 The retreat target is numbers, not home

*"It's better to stay safe with a 3 on 2, rather than pinch and end up with a 3 on 1, 2 on
0 or breakaway."*

The accepted outcome of backing off is **3-on-2 — a preserved numbers layer, not arrival at
your own net.** That is the direct grounding for (c): the deep end of the retreat is the
position that restores the numbers, and `AIRushRead.numbers` already measures exactly that.
A D who has restored even-ish numbers has done his job and must stop retreating.

### 13.4 Support distance is pressure-dependent, and defined by passing options

*"Give close support to a teammate if they are under heavy pressure."* Support distance is
a function of pressure on the carrier — **the same input as the turnover read**, so one
perception drives both the D's hold/bail and the supporters' spacing.

The literature expresses support geometrically, not numerically: the **triangle** —
*"forwards should work to maintain a triangle, which provides multiple passing options with
multiple angles on the net"*, a *"framework flexible to contract or expand."* No source
gives a distance in feet. Support is defined by **whether a pass is on**, which validates
the formalization: **you are in the play iff the carrier could feed you.** Measurable from
`expected_pass_speed` / the launch ceiling, no invented radius.

### 13.5 Design

**A. `pressure_eta_s` on `AIRushRead`** — seconds until the puck is contested (the
nearest opponent's momentum-aware ETA to it; 0 when it is already theirs or loose).

*Revised during implementation.* The plan called for `1 - carry_safety` as a 0..1
imminence. Measured, that is a **step function**, not a gradient: it answers the
CARRIER's question ("can I be poked right now?") over a 0.4 s evade horizon, reading 0
until an opponent is ~1 m away and 1 after. There is nothing in it to threshold, and its
horizon is far too late for a defenseman 40 m away. Publishing a TIME instead lets each
consumer compare against its own notice period, which is where a threshold belongs.

Second revision: `pressure_eta_s` drives **neither** the hold decision nor the leash — see
the note in §13.5 B/D. It is published and currently unread. That is deliberate rather
than an oversight; the two places it seemed to belong both turned out to misbehave.

**B. Offensive stations replace the race-home bound with the real pinch read.** Two ways
to lose the forward stand, and neither is "control is contested":

- they have it **and** it is coming at us (`Mode.RUSH` — a bottled carrier reads REGROUP,
  and forechecking a bottled carrier is exactly right), or
- somebody is **behind** us and nobody is covering for us (`has_support_behind`, which
  survived §10).

Which body counts as "support behind" falls out of the geometry rather than being named.
During an O-zone cycle the **points are the rearmost bodies** (~9 m off our blue line);
F3's high-slot float sits ~8 m further up-ice. So the points read no support and respect
any man who gets behind them (correct — they *are* the last layer), while F3 reads the
points as his support and holds his float (correct — the layer behind him is home). The
turnover-conscious forward is `HIGH_SLOT` / `F3_HIGH`, the designated first man back;
`SUPPORT` / `TRAILER` already prices turnover risk natively via `counter_rush_cost` and is
untouched by §13.

*Contested control deliberately does not send a station home on its own.* Backing off with
nobody behind you is precisely the out-of-the-play failure being fixed — the retreat buys
no coverage and costs the attack a body.

"Behind me" needs real separation: a defending winger *covering* the point sits level with
a D and must not read as a man who has beaten him. The grounded span is the **cover
envelope** (a goal-side stand plus a stick), with an extra stick of hysteresis while
holding.

**C. The retreat floor becomes numbers-restoring, not home.** Back off only as far as
restores the numbers layer, then stop. Replaces `station_retreat_floor` on the offensive
stations (it stays correct for the NZ ones).

**D. A play-connection bound — the forward floor that does not exist today.** No offensive
station may sit outside feedable range of the puck (a pass flight time, not an invented
radius). This is the explicit "nobody completely out of the play".

Two scoping rules, both learned the hard way:
- It applies only while **we** possess — the leash is about being a live passing OPTION,
  and there is none when the puck is theirs or loose. A forechecker standing off a bottled
  carrier is doing his job.
- It applies only to a **holding** station, never to a retreat. Clamping a recovery back
  up-ice toward the puck undoes the coverage the numbers read just called for.
- It is a hard OUTER bound and nothing else. Shrinking it under pressure (to express
  "close support") converts it into an attractor that drags a point into the corner.

**E. ~~The points get an above-the-puck-style discipline.~~** Subsumed by D. The points'
problem is being too far BEHIND the puck, and the feedability bound is the correct
expression of that; a separate margin would be a second mechanism for one job.

### 13.6 Open

- **Appetite split — not needed.** The D-vs-forward asymmetry the doctrine describes
  emerges from geometry: the points are the rearmost layer so they read no support and
  respect men behind them, while F3 reads the points as support and holds. No scalar.
- **Pressure-dependent support distance.** `pressure_eta_s` is published and unread. The
  natural home is SUPPORT's own positioning, which already prices pressure via
  `turnover_prior`; the stations are the wrong consumer.
- **"Take the player or take the puck."** The pinch's own success condition (*"if a chip or
  middle-bump pass beats you easily, a pinch is a poor option"*) is a further read we do
  not model at all. Out of scope here; worth noting as the next layer of pinch quality.

---

## Appendix — research

Extends the rush-defense section of `docs/5v5-ai-plan.md:542`, which was already correct.

**Gap control**
- Gap ladder: ~3 stick lengths at the offensive blue line → 2 at the red line → **1 stick
  at the defensive blue line**. Tight gap is "one to one and a half stick lengths."
- "Stand up at the line, stay inside the dots."
- Modern doctrine is to **defend by skating forward** — surfing, lateral positioning,
  dictating the rush — rather than absorbing pressure and backing in. Best defensemen
  "kill the rush early."
- Backpressure: a backchecker within ~1–2 s of the carrier lets the D tighten the gap and
  stand up. Without it, default conservative — concede the entry, steer wide.

**Backcheck lanes**
- F1 backchecks all the way to the net **through mid-ice**, then moves into low-zone
  support.
- F2 and F3 come back **through mid-ice** and stop **just inside the tops of the circles**,
  sticks on the ice.
- Strong-side D takes the carrier; weak-side D holds mid-ice — the mid-lane drive is "fed
  to D2."
- The first backchecker tracks through the middle and takes the trailer.

**Odd-man rushes**
- 2-on-1: the defenseman takes away the **pass**, stays in the **middle**, keeps the stick
  blade on the ice in the lane, and forces a low-percentage shot while buying time for
  backcheckers. The goalie plays the puck/shooter.
- Quantified as roughly **play the pass ~92% / play the shooter ~8%** — but giving the
  shooter too much space turns the 2-on-1 into a breakaway, which is the failure mode of
  a purely lateral read.

**Neutral zone structure**
- 1-2-2 is the modern NHL default: F1 dictates the side, F2/F3 form the second layer, D
  pair holds the line inside the dots.
- On a regroup the defending team sets up **at its own blue line** and denies the entry —
  it does not retreat toward its net.

Sources:
- [Ice Hockey Systems — Defending by Skating Forward: Surfing, Gap Control, and Dictating the Rush](https://www.icehockeysystems.com/education/player-development/defending-skating-forward-surfing-gap-control-and-dictating-rush)
- [The Coaches Site — 3 Drills to Teach Gap Control With Your Defensemen](https://members.thecoachessite.com/article/3-drills-to-teach-gap-control-with-your-defensemen)
- [The Coaches Site — Keys to Defending Your Blue Line & Entrance into Your Own End](https://members.thecoachessite.com/article/keys-to-defending-your-blue-line-entrance-into-your-own-end-of-the-rink)
- [Minnesota Hockey — Tearse: Understanding Gap Control](https://minnesotahockeymag.com/tearse-understanding-gap-control/)
- [Sandbar Hockey — How to Improve Gap Control as an Ice Hockey Defenseman](https://sandbarhockey.com/blogs/news/how-to-improve-gap-control-as-an-ice-hockey-defenseman)
- [WHL / Portland Winterhawks — Defensive Concepts and Systems: Back Check (PDF)](https://cdn.whl.ca/archive/whl.uploads/app/uploads/portland_winterhawks/2018/02/02113207/Defensive-Concepts-and-Systems.pdf)
- [The Coaches Site — F3 Positioning When Tracking](https://members.thecoachessite.com/article/f3-poistioning-when-tracking)
- [The Coaches Site — Explained: 1-2-2 Neutral Zone Forecheck](https://members.thecoachessite.com/article/explained-1-2-2-neutral-zone-forecheck)
- [Pure Hockey — How to Defend a Two-on-One Rush in Hockey](https://blog.purehockey.com/hockey-drills-training-tips/how-to-defend-a-two-on-one-rush-in-hockey/)
- [puck++ — Game Theory and Defending Against a 2-on-1](https://puckplusplus.com/2017/12/16/game-theory-and-defending-against-a-2-on-1/)
- [Let's Play Hockey — Russo: Golden Rules for Defensemen](https://letsplayhockey.com/russo-golden-rules-for-defensemen/)
</content>
</invoke>

### Offensive positioning (drives §13)

**The pinch / hold-the-line read**
- *"The only time a defenseman should be standing on the offensive blue line is when his
  team has complete control of the puck."*
- *"As a general rule, a defenceman can only pinch when they have a supporting player in
  position to back them up should the puck/player get past them"*; reading whether there is
  an **F3 high** alters the decision, and with F3 support *"there is a lower risk if the
  pinch down does not work."*
- *"The first rule defensemen are taught is to count numbers — how many opponents are in
  front of them and if any are behind them."*
- Retreat trigger: *"if the other team gains clear possession of the puck, and is moving out
  of the zone with multiple passing options — retreat."*
- Retreat outcome: *"better to stay safe with a 3 on 2, rather than pinch and end up with a
  3 on 1, 2 on 0 or breakaway."* — the target is a preserved numbers layer, not reaching
  your own net.
- Pinch success condition: *"take the player or take the puck"*; if a chip or middle-bump
  pass beats you easily, the pinch is a poor option.
- **F3 fills**: F3 stays high above the circles to back up a pinching D; if the D goes in,
  the forward covering that point goes with him.

**Support and spacing**
- Named failure modes: *"too spread out leads to isolated puck carriers"*; *"a common
  mistake is to float far away from the puck in an effort to be 'open' instead of finding
  angles of support"*; *"players hurry up the ice and end up in there all by themselves."*
- *"Give close support to a teammate if they are under heavy pressure"* — support distance
  is pressure-dependent.
- The **triangle**: winger on the wall, centre in the slot, D at the line; *"multiple
  passing options with multiple angles on the net"*, a framework that **contracts or
  expands** with the situation.
- No source specifies support distance in feet — support is defined by whether a **pass is
  on**, which is why §13.4 formalizes "in the play" as feedability rather than a radius.

Sources:
- [How To Hockey — Defensemen's Guide to the Pinch](https://howtohockey.com/defensemens-guide-to-the-pinch/)
- [How To Hockey — How to Play Defense: Roles and Responsibilities](https://howtohockey.com/how-to-play-defense-roles-responsibilities/)
- [Hockey IQ Newsletter — Defense: How to Read the Pinch](https://hockeysarsenal.substack.com/p/how-to-reach-the-pinch)
- [Ice Hockey Systems — Establish Puck Possession in the Offensive Zone](https://www.icehockeysystems.com/blog/coaching-tips/establish-puck-possession-offensive-zone)
- [USA Hockey — Creating Offense with Zone Entries and Puck Support](https://www.usahockey.com/news_article/show/775908-creating-offense-with-zone-entries-and-puck-support)
- [The Coaches Site — Triangulation: Complete the Triangle to Support the Puck](https://members.thecoachessite.com/video/triangulation-complete-the-triangle-to-support-the-puck)
- [Ice Hockey Systems — Offensive Zone: Low-to-High Rotating Triangle](https://www.icehockeysystems.com/hockey-systems/offensive-zone-low-high-rotating-triangle)
- [Beer League Tips — Basic Offensive Zone Structure](https://beerleaguetips.com/article/offensive-zone-structure/)
- [Ice Hockey Systems — 2-1-2 Forecheck with F3 High (Buffalo Sabres)](https://www.icehockeysystems.com/coaching-clip/2-1-2-forecheck-f3-high-buffalo-sabres)
