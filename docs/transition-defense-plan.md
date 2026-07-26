# Transition defense (TRANS_OD) — reground

Status: **design, not yet implemented.** Supersedes the TRANS_OD sections of
`docs/5v5-ai-plan.md` (§2 TRANS_OD, and the defensive half of §5); the O-zone,
forecheck, breakout and D-zone designs in that doc are unchanged.

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

### 3v3 — the same three layers, compressed

| Slot | Job |
|---|---|
| `RUSH_D1` | Owns the carrier. Same behavior module as 5v5. |
| `TRACK_PUCK` | The backchecker who can catch the carrier — attacks from behind. If nobody can catch him, degrades to `TRACK_MID`. |
| `TRACK_MID` | Middle lane, circle tops. The second man / trailer. |

3v3 has no D pair, so `RUSH_D2`'s mid-ice job collapses into `TRACK_MID`, and on a
`DOWN_ONE` read `RUSH_D1` itself plays the pass (which is what the existing lane fan
already does well — see §8).

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

---

## 9. Rush continuation across the blue line

The rush does not end at the blue line. `RUSH_D1` **keeps the carrier** until a
rush-over predicate fires:

- the puck goes below our goal line, **or**
- we gain possession (PossessionTracker's ESTABLISHED bar, same one offside voiding uses),
  **or**
- the attack stalls — carrier closing speed ≈ 0 on the threat axis for a confirmation
  beat.

Then the team hands to DZONE zone coverage and `RUSH_D1` becomes the strong-side zone D.
No re-election at the line, no target discontinuity, and the rendezvous clamp in
`pressure.gd` loses the failure it was patching.

---

## 10. Ledger

**Dies**
- `AIRoleContain` — replaced by `RUSH_D1`'s behavior module.
- `gap_for_pace` and the pace-driven gap.
- `has_support_behind` as a positioning gate (superseded by `numbers`; may survive as a
  tiebreak).
- TRANS_OD's dependence on the threat partition.
- The crease-top retreat floor.

**Reused as-is**
- The soonest-to-arrive election machinery + hysteresis, both files.
- `AIZoneCoverage` soft-lock + boundary release — extended up-ice into transition lanes.
- CONTAIN's **odd-man lane fan** (`contain.gd:378`). This part is good: it derives 2-on-1
  doctrine from the evaluators rather than scripting it, and the research agrees with it
  (play the pass ~92% of the time, goalie takes the shooter). It moves onto `RUSH_D1`
  under the `DOWN_ONE` read, where the numbers read tells it *when* to apply instead of it
  inferring that from receiver danger alone.
- The threat partition, for DZONE.
- The counter-channel model, for offensive pinch decisions (§8).

**New**
- `Scripts/domain/ai/rush_read.gd` + GUT tests.
- `Scripts/domain/ai/role_behaviors/rush_d.gd` (RUSH_D1/D2).
- `Scripts/domain/ai/role_behaviors/track.gd` (TRACK_PUCK / TRACK_MID).
- Tracking-mode dispatch branch in the agent state machine.
- Rush-over predicate + continuation.

---

## 11. Phasing

Each phase is independently shippable and independently testable against
`tests/unit/ai/rush_sim_harness.gd`, which already exists.

- **A — `AIRushRead`, published but unread.** Pure module + tests. No behavior change.
  Lets us assert the read is right (numbers, attacker filtering, tracking classification)
  before anything depends on it.
- **B — Retreat floors + attacker filtering.** Raise the floors (§8), restrict the threat
  set. Smallest diff, and it should visibly fix symptom 1 on its own. Ship and playtest
  before continuing.
- **C — Gap ladder + gap-up + angling** on the existing CONTAIN. Fixes symptom 3 without
  restructuring roles yet.
- **D — Layered roles + tracking mode.** The structural change; fixes symptom 2.
  3v3 and 5v5 land together (they share the behavior modules).
- **E — Rush continuation** across the blue line. Fixes the residue of symptom 4.

B and C are worth playtesting on their own — if the floors and the ladder land most of
the feel, D can be scoped down.

---

## 12. Open questions

1. **`DOWN_ONE` lateral concession vs. the existing lane fan.** The fan already finds the
   pass lane from evaluators. Does the numbers read *gate* it (cheap, explicit) or just
   *bias* it (keeps everything emergent)? Leaning gate — the research is unambiguous that
   this is a mode switch, not a gradient.
2. **Does `TRACK_PUCK` get body checks?** Recommend yes; it is the most satisfying
   backcheck outcome in hockey and currently structurally impossible. Risk is bots taking
   run-at-the-carrier angles instead of tracking lanes — mitigate by requiring goal-side
   before the check commit is allowed.
3. **3v3 `RUSH_D2`.** Currently folded into `TRACK_MID`. With only three skaters, is a
   dedicated second layer worth it, or does the compressed three-role set hold?
4. **Cognition tiers.** Which of these become difficulty knobs? `backpressure_s` awareness
   and the gap-up trigger are natural Easy/Hard splits (`plays_rush_pass_lanes` is the
   precedent).
5. **Does `numbers` want hysteresis?** It is a discrete count driving a discrete posture,
   so a body crossing the puck line could flip the whole team's aggression mid-rush.
   Probably needs the same enter/hold margin pattern as `retrieval_read`.

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
