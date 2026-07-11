# Goalie AI Realism Audit — July 2026

A full behavior-by-behavior audit of the goalie AI against real goaltending teaching and
sports-science data. Every subsystem in `goalie_controller.gd` / `goalie_behavior_rules.gd` and
their collaborators was read end-to-end and compared against sourced coaching doctrine
(USA Hockey Goaltending curriculum, Hockey Canada, InGoal Magazine, GoalieCoaches.com,
Seltytending, Mitch Korn / Rick Heinz material) and measured data (Panchuk & Vickers quiet-eye
studies, Clear Sight Analytics shot tracking, the Brock University butterfly biomechanics study,
NHL shot-type conversion data). Sources are cited inline; the full link list is at the bottom.

**Scope note:** catching the puck and covering/freezing for a whistle are treated as *known,
accepted limitations* per the audit request — they are documented in §8 for completeness but are
not findings. Everything else was fair game.

**Implementation status (2026-07):** the five P1 findings are implemented — F1 (puck-squared
tracking + quiet-eye smoothing via `tracking_speed_far`), F2 (0.20 s grounded butterfly drop,
mirrored in `GOALIE_BUTTERFLY_DROP_S`, plus the pre-armed read `prearmed_reaction_delay` /
`prearm_read_time` that restores anticipation for a set, sighted goalie reading a windup),
F3 (`cross_crease_race_lost` fork: standing drive when the push can arrive set, drop-and-slide
pads-first when the race is lost), F4 (blocking butterfly on fully-screened releases —
`_maybe_arm_screen_block_drop`), F5 (speed-matched rush backflow — `rush_retreat_depth` /
`rush_retreat_rate`). P2/P3 findings remain open.

**Verdict legend:**
- ✅ **Matches** — behavior aligns with real teaching/data
- ⚠️ **Partial** — right idea, wrong number or missing a piece
- ❌ **Diverges** — behavior contradicts real teaching
- ➖ **Absent** — a real-goalie behavior with no counterpart in the model

---

## 1. Executive summary

The goalie is *structurally* far more realistic than a typical game goalie: the depth chart is the
real Buckley Positioning System with correct anchor depths, the set-vs-moving read penalty, the
screen occlusion model, the backdoor depth cap, the committed-slide/bait-the-drop loop, the
stay-up-vs-seal save selection, and the honest cross-crease race all correspond directly to
documented doctrine or tracked NHL data — several of them almost exactly (§7 lists ~20 validated
behaviors). The gaps that remain cluster into five high-impact findings and a tail of
medium/low ones:

| # | Finding | Verdict | Priority |
|---|---------|---------|----------|
| F1 | Angle is set off the carrier's **chest** at range — real goalies square to the **puck**, unanimously | ❌ | P1 |
| F2 | Butterfly drop (0.05 s) is ~5× faster than the measured real drop (~0.25–0.4 s to ice seal) | ❌ | P1 |
| F3 | A standing goalie answers a cross-crease pass **only** with a standing T-push — never a pads-first slide, even when the race is already lost | ⚠️ | P1 |
| F4 | Screens only delay the read; real goalies also **change position** (get tight to the screen) and **change save selection** (blocking butterfly on release) | ⚠️ | P1 |
| F5 | Breakaway/rush retreat is distance-keyed and starts too late (2 m); real retreat is speed-matched backflow timed to the attacker | ⚠️ | P1 |
| F6 | No small down-movement: real goalies knee-shuffle / backside-push 10–40 cm in scrambles; the model's only down move is the full committed slide | ➖ | P2 |
| F7 | Dangle jitter (raw puck velocity) can trigger the lateral-pressure depth retreat — a stationary stickhandler can drag the goalie 0.5 m deeper | ❌ (likely unintended) | P2 |
| F8 | Long-range depth taper (>20 m) sinks the goalie toward the goal line; real goalies hold conservative/base depth when the puck is far out front | ⚠️ | P2 |
| F9 | The head never tracks the puck — "head trajectory" (eyes/head lead every movement) is the core of modern tracking, and the wire already carries `head_yaw` | ➖ | P2 |
| F10 | Recovery rises in place; real recovery loads the far-side leg and rises *moving toward the puck* | ⚠️ | P3 |
| F11 | Poke/lunge has no cost — a real poke is a committed gamble (coaching heuristic: 1 save per 2 goals on breakaway pokes) | ⚠️ | P2 |
| F12 | Pad rebounds ≤28 m/s deaden to a dead drop — modern doctrine is "kick it hard and **wide**"; only chest/glove absorb | ⚠️ | P2 |
| F13 | Slapper windup pulls the goalie **deeper**; real teaching for a clean windup is *get set* (stop), not retreat | ⚠️ | P3 |
| F14 | No VH / Overlap — sharp-angle *shot* threats above the goal line have no high-coverage post stance | ➖ | P3 |
| F15 | Baseline leg read (0.13 s) is below the human simple-RT floor (~0.18–0.20 s) — defensible as baked-in anticipation, but worth documenting as such | ⚠️ | P3 |

Doc drift found along the way: `ARCHITECTURE.md` §Goalie Networking says `rvh_early_angle`
defaults to 60°; the controller ships 80° (`goalie_controller.gd:144`).

---

## 2. Reference model — what the research says

Condensed from the four research sweeps; used as the yardstick throughout §3–§6.

**Positioning.** The depth system in the code *is* the real one: Mike Buckley's Buckley
Positioning System (BPS), adopted by USA Hockey as the "ABCs of Depth" — A ≈ 2 ft above the
crease top for rushes/breakaways, B = heels on the crease top for most shots, C = middle of the
paint when a lateral pass is live (2-on-1, royal road), D = goal line/post for behind-net play.
(Attribution note: BPS is Buckley's, not Brian Daccord's — Daccord founded Stop It Goaltending
where Buckley coached; the code comment at `goalie_controller.gd:18` says "Buckley-style" which
is correct.) Angle is the line **from the puck** to net center; the goalie is on-angle when his
midline bisects it. The canonical coaching *error* is squaring to the shooter's **body**: "the
puck is released at least a foot away from the body, so if your chin is lined up with the
shooter's body, you are off angle" (GoalieCoaches.com). "Play the body, not the puck" is a
*skater-defense* maxim, not goaltending doctrine. Depth, not angle-cheating, is how a live pass
option is respected: a 2-on-1 pulls the goalie from B to C while he keeps playing the shot line.

**Perception & reaction.** Elite whole-body simple reaction ≈ 180–200 ms; the save movement
itself is a pre-programmed ballistic action of <200 ms following a ~1 s quiet-eye fixation on
**the puck and stick blade** (Panchuk & Vickers: fixate puck+blade → save >75%; QE longer on
saves than goals for 8 of 8 goalies). Blocking vs. reacting is the real save-selection split:
inside ~15 ft / with no sightline, reaction is physically impossible (85 mph from 4.6 m ≈ 0.12 s
flight) and goalies pre-commit a blocking butterfly; with clear sight and distance they stay up
and react. Clear Sight Analytics: a goalie with ≥0.5 s of clear, set sight saves ~97%; shots
denying that half-second ("green") produce ~76 % of NHL goals; screened chances convert ~1-in-7
vs ~1-in-34 clean; a royal-road pass raises shooting % from ~8.5 % to ~30 %. Deflections/tips
convert ~16–17 % vs ~9 % for clean wristers. A cross-crease pass (~0.07 s over 2 m) beats any
push (~0.4–0.7 s): a clean back-door one-timer is effectively unsaveable except by anticipation
— which is why goalies pre-concede challenge depth to it.

**Movement.** Vocabulary: shuffle (short, stays square, shot can arrive mid-move), T-push
(long lateral, arrives-and-sets, profiled mid-glide), C-cut telescoping (depth control; backward
C-cuts = rush retreat at the rush's speed), butterfly slide (lateral transit while sealed —
for when a low shot can arrive mid-move), knee shuffle and backside push (small/medium moves
*while down*). Governing rule: **arrive set before the release**. Measured numbers: butterfly
drop velocity 2.07 ± 0.09 m/s (Brock Univ., pro subject) → ~0.25–0.4 s from initiation to ice
seal; post-to-post on feet ≈ 0.5–0.8 s (estimate; no published NHL measurement), down transit
≈ 0.7–1.0 s. Slides are straight and ballistic — steering happens as discrete extra pushes, not
mid-glide corrections. Recovery: eyes find the puck first, far-side leg loads, and the goalie
rises *toward* the destination in one motion; stay down when the rebound is inside ~2 stick
lengths, otherwise recover to feet immediately.

**Post play.** RVH = puck at/below the goal line or dead angle in tight (wraparounds, walkouts,
jams); VH = sharp-angle *shot* threat with pace/distance above the goal line (keeps short-side
top coverage); Overlap = mobile post-adjacent stance when a real shot is still live. The modern
critique is RVH *overuse* — its documented weaknesses are short-side high and the far-side pass.
Wraparounds are ~0.86 % of NHL shots and the least likely shot type to score.

**Saves & rebounds.** Low shots: stick angled to the corner in front of the five-hole; pad
shots: steered/kicked hard and **wide** (modern "active rebounds" — pads are built to fire
pucks to the corner), toe-out in butterfly is real; chest height: absorb and swallow (the one
"no rebound" category); at the post, sealing beats steering — flush pad, no angled faces.
Five-hole: open during T-pushes/transitions, stick-guarded when set; ~14 % of NHL goals.
Loose pucks: cover/freeze under pressure (default), sweep to the corner when there's no time to
gather, leave for the defense only with clear teammate possession. Poke check: situational and
declining; a committed breakaway poke is coached as ~1 save per 2 goals conceded. Paddle-down:
niche scramble/wraparound tool, largely superseded by RVH. Gloves are pre-placed in the *lane*
("box control" — held no higher than the puck's possible under-bar line), which scales with
shot geometry.

---

## 3. Positioning & depth — behavior-by-behavior

### 3.1 Depth chart (BPS zones) — ✅ with two edge caveats

`goalie_controller.gd:33-40`: A=1.75 m, B=1.30 m, C=0.70 m, D=0.10 m (radius from goal center),
zone breaks at 2/8/12/20 m. Against real geometry (crease top = 1.37 m,
`CreaseRules.STRAIGHT_DEPTH`): B at 1.30 puts the heels essentially on the crease top —
textbook. C at 0.70 is the middle of the paint — textbook. A at 1.75 is ~0.4 m above the crease
top, slightly shy of the taught "2 ft (0.6 m) or more" but inside the modern deep-vs-aggressive
band (Lundqvist-style inside-out play rarely goes past the crease top at all). The *dynamic*
C-zone behavior — dropping from B/A to C when a lateral threat is live — is handled by
`backdoor_depth_cap` + `lateral_pressure_depth_pull` rather than baked into the distance curve,
which matches how the real read actually works (depth concession is threat-driven, not
distance-driven). Good.

**Caveat 1 (F8, ⚠️):** `target_depth_for_puck_distance` (`goalie_behavior_rules.gd:139-153`)
tapers C→D as the threat goes from 20 m to 40 m — a puck at center ice walks the goalie back
toward the goal line. Real goalies hold C/B when the puck is far away *in front*; D depth is for
behind-net play. Zero shots matter from 25 m out, so this is mostly a *looks-wrong* issue (the
goalie visibly sags to his goal line during neutral-zone play instead of resting at the crease
top watching the play). **Recommendation:** floor the in-front taper at `depth_conservative`
(or even `depth_base`) and reserve `depth_defensive` for the defensive-zone/RVH paths.

**Caveat 2:** the ≤2 m ramp lerps D→A, i.e. at a threat 2 m from goal center the target radius
is the full aggressive 1.75 m (a 0.25 m gap to the attacker) and only ramps down as the attacker
drives to the net. See F5 (§3.4) — this is the late-retreat half of the breakaway finding.

### 3.2 Arc positioning — ✅

`target_arc_position` places the goalie on the ray from goal center through the threat at the
chart radius, clamped inside the posts, flattening to the goal line for behind-net threats
(`goalie_behavior_rules.gd:234-257`). That is exactly the taught geometry: on-angle = midline on
the puck→net-center line, and set positions at a given depth trace an arc concentric with the
net. The older angle-bisector-at-fixed-depth code this replaced was *less* correct (real
"bisect the angle" and "center on the puck line" are the same thing measured from the puck; the
arc formulation naturally sits shallower on sharp angles, which is the real behavior). The
depth-radius driving Euclidean threat distance (not just Z) is also right.

### 3.3 What the arc points at — F1, ❌ (the biggest doctrinal inversion)

`_compute_threat_position` (`goalie_controller.gd:1157-1196`) aims the whole positioning system
at a **chest-weighted blend**: standing weight 0.40, butterfly 0.60, ramping to
`shooter_weight_far = 0.90` beyond 7 m (`goalie_controller.gd:167-177`). The code comments call
this "play the chest, not the puck" and cite it as a real goalie principle.

The research verdict is unambiguous and unanimous the other way: **goalies square to the puck at
every range.** "It's square to the puck, not the shooter"; the chin-on-body alignment is the
canonical *coaching error*, and the error grows with the puck-to-body offset (GoalieCoaches.com,
Max Hockey Coaching, Seltytending; Panchuk & Vickers' elite goalies fixate the puck and stick
blade, not the torso). "Play the body" is defenseman doctrine (don't bite on dekes), not
goaltending doctrine. The shooter's body is used only as a *pre-release anticipation cue*
(hips/shoulders/blade angle inform where the shot is going), never as the squaring target.

Concretely: with the puck a stick-reach (~0.8–1.0 m) lateral of the carrier's body and
`w = 0.9`, the tracked threat sits ~0.8 m off the true release point; at B-depth (1.3 m radius,
threat at 8 m) the goalie stands ~0.15–0.2 m off-square to the actual shot line — and because
the reaction freeze (`_move_along_arc`, `goalie_controller.gd:1964`) locks position at release,
that error is baked into every save attempt from range. The model gives every shooter a small
standing blade-side hole that a real set goalie would not concede.

**Why it's there:** the comments are explicit — pure puck tracking made the goalie chase
stickhandle jitter (±1.5 m swings) and shuffle into 5-hole shots. That's a real problem, but the
real-world mechanism that solves it is *temporal*, not *spatial*: a goalie's gaze and angle
corrections are smooth and slightly laggy (quiet-eye tracking), so a two-touch dangle doesn't
yank his midline around — but his *set point* is still the puck.

**Recommendation:** keep the anti-jitter, move it to the right axis. Square to the **puck**
(or a short-horizon puck estimate) at all ranges, and get the stability from smoothing/deadband
instead of target substitution:
- Distance-scale the *tracking lerp speed* (slower/laggier at range — currently
  `tracking_speed = 8.0` flat) and/or add a small positional deadband so sub-±0.3 m blade wiggle
  doesn't move the target at all. This is the code-shaped version of the quiet-eye lag.
- Keep a *small* chest weight in close (0.2–0.4) if the 5-hole shuffle exploit resurfaces — in
  tight the offset angle is large and some body bias is a defensible feel compromise — but the
  far weight should go *down*, not up (at range the offset angle is small, so puck-tracking
  costs almost nothing in jitter and buys correct angles). The current values have the gradient
  backwards relative to the real error geometry.
- The pre-release anticipation the body legitimately provides is already modeled elsewhere
  (pre-lean off `predicted_shot_velocity`, slapper tell) — those are the right homes for it.

This also cleans up a second-order artifact: `_update_facing` and the slide pad-coverage check
key off the same blended threat, so the chest weighting currently leaks into facing and slide
commitment too.

### 3.4 Rush / breakaway retreat — F5, ⚠️

There is no dedicated breakaway behavior; retreat is emergent from the depth chart + the
`depth_speed = 4.0` exponential lerp (`goalie_controller.gd:41-46`). Two problems against the
taught model ("start at A, back in **matching the shooter's speed**, arrive at the crease edge
as the shooter hits the hash marks, be near the goal line as he reaches the crease" — Edge Ice
Academy, USA Hockey):

1. **The retreat starts too late.** The chart holds full A-depth (1.75 m) until the threat is
   2 m from goal center, then ramps to D over the last 2 m. A real retreat begins around the
   hash marks (~6–8 m) and is continuous.
2. **The retreat is distance-keyed, not speed-matched.** A slow walk-in and an 8 m/s rush get
   the same target curve; only the lerp's convergence lag differentiates them, and the comment
   at `goalie_controller.gd:41` concedes the lerp only ~63 %-converges against a fast approach —
   i.e. exactly on the plays where timing matters most, the goalie's actual depth is an artifact
   of lerp lag rather than a modeled read. It mostly *works out* (lag ≈ retreat), but it is
   uncontrolled: attacker speed, tick rate, and `depth_speed` conspire to set the gap.

**Recommendation:** make the retreat a grounded model instead of a lerp artifact — inside some
engagement range (e.g. threat < 8 m and closing), set target depth as a function of the
*attacker's closing speed* (backward C-cut matching: retreat rate ≈ closing rate scaled so the
goalie reaches crease-top when the attacker is at ~4–5 m and D-depth as the attacker reaches the
crease). This is one small pure function in `goalie_behavior_rules.gd` and directly implements
the taught timing rule; the depth chart remains the far-field behavior. It also creates the
real counter-dynamics: a shooter who decelerates strands the goalie deep (more net — real), a
speed rush arrives against a goalie already at depth instead of one being dragged by a lerp.

### 3.5 Backdoor-aware depth (anticipatory) — ✅, strongly validated

`backdoor_depth_cap` (`goalie_behavior_rules.gd:599-658`, consumed at
`goalie_controller.gd:1859-1891`) caps challenge depth by the pass-flight vs. re-square race
when a weak-side one-timer man exists. This is precisely the real synthesis — *"play the shot
from a depth that respects the pass"* (B→C shift on a 2-on-1; depth, not angle-cheating, is the
concession) — and the data says the anticipatory read is the *only* real counter to a royal-road
one-timer (pass ~0.07 s vs push ~0.4–0.7 s; >10× danger multiplier). The grounded race
formulation (pass flight + release swing vs. read delay + accel-ramped push) and the fact that
it only ever *repositions* rather than buffing the save are both exactly right. The θ→0
degeneration (shooter on the carrier's line → no cap) is correct geometry.

One refinement worth considering: `pass_speed` assumes the game's quick-shot 14 m/s
(`goalie_controller.gd:229`) — correct in-universe, and honest.

### 3.6 Lateral-pressure depth retreat — F7, ❌ mechanism (likely unintended input)

`_update_depth` (`goalie_controller.gd:1854-1858`) retreats when
`absf(_puck_velocity_est.x) > t_push_speed`. `_puck_velocity_est` is the raw position-derived
**puck** velocity — which, for a *carried* puck, includes stickhandling. The Hands-governed
blade cap is high enough that a stationary dangler can repeatedly exceed 3.8 m/s laterally,
dragging the goalie up to `lateral_pressure_max_pull = 0.5 m` deeper with zero actual lateral
threat. Real goalies do not sink on a stationary stickhandler — depth concession is for
*carrier/pass* lateral motion. The rest of the tracking system already learned this lesson (the
chest blend and the faded puck lead exist precisely to ignore dangle jitter), but this input
bypasses it.

**Recommendation:** key the deficit off carrier body velocity when a carrier exists
(`carrier.velocity.x`), falling back to puck velocity only for loose pucks — one-line change,
and consistent with how `is_beaten_wide` already reads the carrier's real velocity.

### 3.7 Slapper tell — F13, ⚠️ direction questionable

`_reading_slapper_tell` pulls the goalie 0.10 m *deeper* and raises the hands
(`goalie_controller.gd:504, 1847-1848`; pose at `goalie_body_config_builder.gd:288-292`). Hands
up is right. The depth pull is backwards against the primary teaching: on a clean shot with a
visible windup the taught response is **get set** — stop moving, square, hold your depth
(arrive-set doctrine; a windup is *more* read time, which is why slapshots convert lower than
snap shots despite higher speed). Retreating concedes angle exactly when the goalie has his best
look. Backing off is taught for *screened* point shots and tip threats (get depth to see lanes
and play the deflection), not clean windups.

**Recommendation:** replace the unconditional depth pull with "set and freeze" (zero the depth
lerp / lateral motion during the windup — effectively what the reaction freeze already does
post-release, extended to the read) and keep a depth concession only when the shot is also
screened (§4.3) or a tip threat exists in front. Small change, and it removes a modeled behavior
that real coaching would correct.

---

## 4. Perception & reaction

### 4.1 Reaction delays — ✅ structure, ⚠️ one floor note (F15)

Two parallel delays — legs 0.13 s (`DEFAULT_GOALIE_REACTION_DELAY_S`) gating the reflexive drop,
arms 0.18 s (`DEFAULT_GOALIE_ARM_REACTION_DELAY_S`) gating the reach — with screens (+≤0.30 s)
and caught-moving (+≤0.12 s) additive on both (`goalie_shot_reaction.gd`,
`goalie_controller.gd:2448-2483`).

The *structure* matches the science well: the butterfly drop as a pre-programmed ballistic
response and the glove as a slower, target-computed reach mirrors the measured blocking
(pre-planned) vs. reacting (feedback-corrected) dichotomy, and the <200 ms ballistic save
movement from quiet-eye research. One nuance from the literature: raw limb RT studies actually
find *hands* slightly faster than feet — the game's arm>leg latency is justified not by limb
speed but by target computation ("where in the upper net"), which is a fair reading of the
blocking/reacting split; the code comment (`goalie_controller.gd:62-68`) already frames it that
way. Keep.

F15: 0.13 s is below the ~0.18–0.20 s measured elite simple-RT floor. Against this game's shot
speeds (33–47 m/s) that's the difference between "top corners score from 6 m" and "from 8 m",
so it's a legitimate difficulty lever — but it should be understood (and documented) as
*anticipation baked into the base read* rather than a human reaction time. If a more literal
model is ever wanted: raise the base toward 0.18 s and give back the difference via the
pre-lean/quiet-eye pathway (a goalie who has been reading a visible windup for >0.5 s gets the
fast read; a no-tell snap release gets the honest slow one). That would reproduce the CSA
red/green split (set + sighted ≥0.5 s → ~97 % save) with the machinery that already exists
(`_is_reading_shot_threat`, prelean, `_shot_commit_timer`).

### 4.2 Freeze-on-release, resolution events, imminence gates — ✅

Track-until-release then commit-and-read (`_move_along_arc` freeze,
`goalie_controller.gd:1956-1970`; facing freeze at 2154), resolution on discrete events with a
0.25 s processing beat and a fast 0.08 s save-clear, the 0.9 s / 0.45 s / 0.6 s imminence gates
preventing across-the-rink reactions to passes — all consistent with arrive-set doctrine, the
quiet-eye account (fixation → ballistic commitment → outcome processing), and the post-event
slide lockout matches "goalies can't simultaneously process a save and read a new lateral
threat." The universal reaction path (any puck with ≤0.6 s TTI, urgency by time-to-impact
rather than speed — `goalie_behavior_rules.gd:324-361`) correctly covers deflections, bounces,
and tricklers, and the "slow puck at the doorstep is urgent" framing is right.

### 4.3 Screens — F4, ⚠️ (read is grounded; position & save selection missing)

What exists is good: `screen_occlusion_delay` (`goalie_behavior_rules.gd:470-527`) is a genuinely
grounded sightline model (worst screener's along-shot hide time; net-front screens hide the puck
almost the whole flight; own-team screeners count — which matches CSA tracking both). Its
magnitude is defensible against the screened-shot data (1-in-7 vs 1-in-34).

What's missing is that a real goalie's *whole game* changes against a screen, not just his read
latency:

1. **Position:** the near-universal instruction is to get **close to the screen** — up in the
   crease, tight to the traffic, looking over the top (Rick Heinz; "the best way to avoid
   getting beat by a tip is to get as close to the tip as possible"), holding the short-side
   sightline when forced to pick a side (NHL.com Unmasked). The model's goalie holds his normal
   chart depth as if the screen weren't there.
2. **Save selection:** a screened point release is the canonical **blocking** situation — drop
   into the butterfly on/just before release because first sight will come too late to react.
   The model instead reacts *late but normally*: the drop still waits for
   `drop_max_time_to_impact` and the (now-delayed) read, so a screened goalie is just a slow
   version of a clean goalie rather than a goalie who has switched modes.

**Recommendation:** the sightline scan already computes everything needed. (a) When a screener
sits on the goalie↔threat line with a point-shot threat, bias target depth toward the screen
(clamp toward B/crease-top rather than deep retreat — the current model would actually want to
*hold* depth here, which is close to right already; the win is mostly in (b)). (b) On a release
whose screen delay hits its cap (i.e. the goalie genuinely never saw it), skip the reactive read
and commit the blocking butterfly at release + base delay — drop early, eat the top-corner
exposure. That is *both* more realistic and self-balancing: blocking concedes upstairs exactly
like real screens do. (c) Optional polish: a slight crouch/lean pose while screened
(sightline-hunting) sells the behavior visually and telegraphs to the shooter that the screen is
working.

### 4.4 Caught-moving penalty — ✅, strongly validated

`movement_read_penalty` (`goalie_behavior_rules.gd:661-678`): read latency scaling with planar
speed, floored while RECOVERING. This is one of the best-supported mechanics in the whole model
— CSA's set-vs-unset split (~97 % save set vs ~70 % green), rush xG ~1.7×, rebound xG ~2×, and
"shooting against the grain" coaching all say precisely this, and the one-way design (only ever
*adds* delay, never buffs a set goalie) matches the audit's beatable-realism mandate. The 2.5 m/s
reference speed is ~sensible (a full T-push is fully unset; a shuffle partially). Keep as-is.

### 4.5 Pre-lean & shot-commit window — ✅

Reading a visible windup and partially pre-committing hands toward the live aim
(`_apply_prelean`), with a commit window during which the cross-crease anticipation is
suppressed (`_shot_commit_timer`) — both correspond to real behavior: gloves pre-placed in the
*lane* scaled to shot geometry is current "box control" doctrine, and "committed to the shot ⇒
late on the back door" is the real cost structure that makes fake-shot-pass work. The
live-aim-tracking property (a late flick moves the real impact off the lean) reproduces
release-deception research (changed release point beats goalies more than speed). Validated.

---

## 5. Movement & save execution

### 5.1 Upright lateral movement — ✅ numbers check out

Shuffle 2.0 m/s for small corrections (stays square, five-hole nearly closed), T-push 3.8 m/s
above `lateral_threshold` (five-hole opens to 0.10 — real: the T-push opens the five-hole),
accel ramp 14 m/s² from rest with reset-to-rest when set/frozen
(`goalie_controller.gd:48-56, 1986-2011`). Post-to-post from rest ≈ 0.62 s — inside the real
estimated 0.5–0.8 s band. The selection rule (distance-triggered) approximates the real
shuffle-vs-T-push doctrine. The from-rest accel ramp (and the fact that the race math in
`reachable_lateral_distance` honestly includes it) is better-grounded than most sims. ✅

### 5.2 Butterfly drop speed — F2, ❌

`butterfly_drop_speed = 0.05 s` pads-to-floor (`goalie_controller.gd:276`), mirrored by
`AIActionScoring.GOALIE_BUTTERFLY_DROP_S = 0.05`. The only truly *measured* number in the
research set says this is ~5× too fast: drop velocity 2.07 ± 0.09 m/s for a pro goalie (Brock
Univ. motion capture), over a ~0.5–0.7 m hip fall → **~0.25–0.4 s from initiation to ice seal**.
Even granting that pads (the first thing down) seal before the hips finish, ~0.15 s is the
plausible floor for "pads sealed."

Consequences: the five-hole and low corners close near-instantly once the 0.13 s read elapses,
so the low-shot scoring window is thinner than physical reality; visually the drop reads as a
snap rather than a drop; and the bots' five-hole evaluation inherits the same optimism through
the mirrored constant.

**Recommendation:** raise toward 0.15–0.20 s (keeping the existing 3/x lerp convergence), bump
`GOALIE_BUTTERFLY_DROP_S` in lockstep (the code already documents the pairing), and re-tune
`low_shot_threshold` scoring expectations. Note the knock-on: total low-shot denial time becomes
read (0.13) + drop (~0.18) ≈ 0.31 s, which makes clean low shots from inside ~8 m genuinely
dangerous — that matches reality (that's the blocking-save zone; see §4.3's early-drop
recommendation, which is the real compensating behavior).

### 5.3 Butterfly slide — ✅ mechanics, with one real refinement available

Coil (rotate around the planted foot, 0.12 s) → straight ballistic translation (2.8 m/s,
friction decay) → committed destination, no mid-slide correction (`goalie_slide_behavior.gd`).
The research validates nearly every choice: real slides are straight (rotation-before-push is
what makes them straight; arcing is a coached *error*), largely ballistic ("a goalie in a slide
is locked into the momentum of their initial push"), with the head/rotation leading the
translation — which the coil phase models. Max travel ~1.5 m over ~0.96 s sits in the real
0.7–1.0 s down-transit estimate. The commit-and-can't-correct property being the deliberate
realism win (cross-passes beat committed slides) is exactly the real failure mode.

Refinement (ties into F6): real goalies *can chain* — a **backside push** (back leg tucks under
and re-drives from the knees) re-accelerates or redirects after the first slide dies. The model's
equivalent is waiting out `slide_cooldown` (0.20 s) and committing a new slide, which is close in
effect; a slightly longer cooldown before a *direction-reversing* slide (loading the opposite
leg is slower than chaining same-direction) would add texture cheaply.

### 5.4 Down movement tiers — F6, ➖

Real down movement has three tiers: knee shuffle (10–40 cm squared micro-scoots — constant in
scrambles), backside push (medium), full slide (long). The model has only the full committed
slide, gated by `slide_coverage_buffer` past the pad edge — so for threats *inside* the pad span
the down goalie is completely stationary, and for threats just past it he must fire a whole
coil+push+glide cycle. Visible consequences: in crease scrambles the sealed goalie is a statue
between slides (real goalies visibly walk on their knees to stay centered), and small post-ward
tucks (e.g. re-centering 20 cm after a rebound) take a full slide's commitment.

**Recommendation:** add a knee-shuffle mode in BUTTERFLY for sub-pad-edge lateral error: a slow
(~0.5–0.8 m/s) move-toward on `_current_x` toward the arc target while down, five-hole held
closed, no commitment/lockout cost. It reuses the existing arc target and pose; the committed
slide remains the only way to cover real distance, so the bait-the-slide counter is untouched.
This one addition covers the scramble-statue problem, post-tucking, and the RVH-adjacent
micro-adjustments, and it's the single most visible "moves like a real goalie" upgrade available
while down.

### 5.5 Standing cross-crease response — F3, ⚠️

On a detected cross-crease pass, a *standing* goalie always answers on his feet: read delay
0.12 s, then a committed T-push drive (`_update_cross_crease`, `goalie_controller.gd:2336-2380`).
Butterfly slides only ever trigger *from* BUTTERFLY (`_try_commit_slide` is reached only in the
BUTTERFLY branch of `_update_position`). Real save selection on a cross-crease is a time fork:
**stay on feet when you can arrive set; go pads-first slide when the pass has already won the
race or the play is inside the crease/low slot** (arrive-and-seal doctrine, butterfly slides
exist "precisely for this"). The model's standing goalie loses the race standing — honest, and
the right outcome for the shooter — but he loses it in the wrong *posture*: a real beaten goalie
arrives (late) sealed along the ice, taking away the low far-side finish and leaving the top
half, whereas this goalie arrives (late) upright mid-T-push, leaving the bottom of the net open
exactly where real one-timer finishes go.

**Recommendation:** fork on the same race math that already exists (`reachable_lateral_distance`
vs pass flight): if the standing push can arrive ≥ set-margin before the projected one-timer,
keep the current standing drive; if it can't, drop-and-slide toward the far post instead
(enter BUTTERFLY with an immediate slide commit toward the crossing — the infrastructure exists;
`is_beaten_wide` already does drop-on-lost-race for carrier *drives*, this extends the identical
logic to *passes*). Outcome distribution barely changes (the clean one-timer still scores); what
changes is that the near-miss cases produce real-looking desperation pad saves instead of a
goalie jogging across upright.

### 5.6 Recovery — ✅ core, ⚠️ direction (F10)

Min-hold 0.35 s, recovery 0.35 s, held while the puck is within 2.4 m or a jam persists —
the 2.4 m proximity hold is almost exactly the taught "inside ~2 stick lengths, stay down"
rule, and RECOVERING as a vulnerable window that shots/RVH can't fire from matches the real
cost of standing up (rebound xG ~2×; the movement-read floor while recovering is well-supported).
Recovering into READY (not full standing) while the threat persists matches "rise into a ready
stance, not upright." ✅

F10: the model rises in place, then re-tracks. Real recovery is directional — eyes find the
puck, the *far-side* leg loads, and the rise and the move toward the new position are one motion
(USA Hockey Full Recovery). Functionally the difference is a couple tenths of repositioning;
visually it's the difference between a goalie and a person standing up. Cheap approximation:
during RECOVERING, let `_move_along_arc` run at shuffle speed (it currently does run — but from
rest with `_move_speed_current` zeroed at entry; letting recovery inherit a fraction of the
target-ward speed, or simply biasing the recovery pose lean toward the arc target, would sell
it).

### 5.7 Beaten-wide / doorstep / jam save selection — ✅, strongly validated

The trio — `is_beaten_wide` (lost race to the tuck point → drop and post-seal), the
close-range slapshot-windup drop, and `is_crease_jam` (seal on scrambles/slow carriers, stay up
against a driving carrier) — reproduces the real blocking-vs-reacting selection lines remarkably
well: blocking is prescribed for in-tight jams, scrambles, point-blank one-timers; staying up to
force the release is prescribed against a controlled carrier; and the wrister-charge
deliberately-not-a-drop-trigger decision (`goalie_controller.gd:1382-1387`) matches the "don't
drop early / don't be Humpty Dumpty" doctrine, with the early-drop-then-walk-around counter
emerging exactly as shooters are taught to exploit it. The carrier-speed fork on jams
(slow = battle → seal; fast = attack → stay up) is a defensible reading of the same doctrine. ✅

### 5.8 Elevated saves — ✅ with the catching caveat

Arm delay → paced reach (arrive *with* the puck, not before — a nice anti-precognition touch),
5 m/s hand-speed cap grounded against measured explosive hand speed, body lean and shoulder
pitch into the save, blocker as a rigid assembly with yaw-only steering. All consistent with
real save execution; the glove moving low-to-high ("great glove saves arc upward") is even
approximated by the rest pose sitting at 1.19 m with reaches clamped ≥0.50 m. The glove-side /
blocker-side symmetric speed is a documented simplification (real goalies are often faster on
one side) — acceptable. Catching (holding the puck) is the known limitation; `GoalieSaveRules`
killing a glove contact dead (retain 0.0) is the best available proxy.

---

## 6. Post play, rebounds, stick

### 6.1 RVH — ✅ trigger discipline, ➖ VH/Overlap (F14)

RVH triggers only behind the goal line or within 2 m of it at ≥80° off perpendicular
(≈ within 10° of the goal-line plane — a true dead angle), with a swap deadband
(`goalie_behavior_rules.gd:119-134`). Given the modern critique is RVH *overuse* ("don't default
to the post anytime the puck is below the circle"), this conservative gate is on the right side
of current teaching — arguably more disciplined than the average NHL goalie. Butterfly↛RVH
(must recover first) is a real constraint and correctly makes wraparounds a race. Wraparounds
being low-percentage in-game mirrors the NHL data (~0.86 % of shots, lowest-converting type).
The body-roll-into-post pose and back-post swap logic are sound.

F14: there is no VH and no Overlap, so a sharp-angle *shot* threat above the goal line (walkout
from the corner with room to elevate) is played either standing-at-post or (if it crosses the
dead-angle gate) RVH — and RVH's documented weakness is exactly short-side high. In practice the
game's shooters can exploit a sharp-angle high shot the way real shooters exploit lazy RVH. Given
the stance/pose system already supports per-state poses, a VH pose (post pad vertical, back pad
horizontal, more vertical coverage) triggered by "sharp angle + carrier above goal line + shot
threat" would close the model's last post-play hole. Priority P3 — the geometry it defends is a
narrow slice of shots — but it is the canonical missing stance.

Doc drift: `ARCHITECTURE.md` says `rvh_early_angle` default 60; code ships 80.

### 6.2 Rebound control — ✅ architecture, ⚠️ pad deadening (F12)

Pose-based steering (toe-out 12° standing / 18° butterfly) is real — butterfly goalies drop
"toes pointing outward" and the angled faces send low pucks cornerward. The **post-seal
squaring** (`sealed_pad_toe_out` ramping toe-out to 0 as a pad reaches its post,
`goalie_behavior_rules.gd:285-297`) matches the doctrine transition precisely: at the post,
sealing beats steering ("gaps between pad and post" is the canonical short-side failure). The
slot-side pad keeping full toe-out while the sealing pad squares is exactly the right split. ✅

F12: `GoalieSaveRules` deadens *all* pad/blocker saves at ≤28 m/s to a ~dead drop
(`drop_speed = 1.2`), leaving the puck at the goalie's feet for the sweep. Modern doctrine —
and modern pad *equipment design* — is the opposite for mid-pace pads: kick it hard and
**wide** ("active rebounds"; flat stiff pads engineered to fire pucks to the corner), reserving
the dead-kill for chest/glove. The old-school absorb-everything model the code implements
creates exactly the loose-puck-in-the-paint scrambles that real rebound control exists to
prevent — and without a cover mechanic, those scrambles are extra dangerous, partially
compensated by the crease sweep. **Recommendation:** for controlled pad/blocker saves, replace
the dead drop with a *directed* low-energy exit — retain more speed (say 4–8 m/s exit) aimed
along the toe-out sign toward the near corner (the pose already knows the steering direction),
keeping the true dead drop for chest/glove. This converts "puck dies at the feet → sweep"
into "puck steered to the corner off the save," which is both more modern-real and reduces the
model's reliance on the sweep as a cover substitute. The >28 m/s live-kick path is fine (hard
shots genuinely beat pad control).

### 6.3 Loose pucks — ✅ given the no-cover limitation

Real hierarchy: cover under pressure (default) → sweep to corner when no time to gather → leave
for defense with clear teammate possession. With cover excluded by design, the model's sweep
promotion to #1 is the right call, and its parameters are faithful to the real #2 option: swept
from stick reach (1.4 m), only settled pucks (dwell 0.35 s, ≤0.12 m height, ≤4 m/s), corner-ward
with forward bias, never up the middle (`compute_clear_velocity`,
`goalie_behavior_rules.gd:396-429`). Dead-center pucks defaulting to the stick side is a nice
touch. The one real behavior the sweep can't represent — buying a whistle under heavy pressure —
is the acknowledged limitation. When cover eventually exists, the taught trigger is: opponent
within playing distance of the puck + puck within reach → freeze; that maps directly onto the
existing `is_crease_jam` inputs.

### 6.4 Stick: poke, lunge, paddle-down, active blade — ✅ toolkit, ⚠️ cost-free (F11)

The toolkit itself is impressively complete against the real inventory: subtle active-blade
intent (stick in the lane against a nearby carrier), the aggressive standing sweep gated on
*slow* carriers (matching "be aggressive with the stick against dawdlers, stay mild against
speed"), paddle-down in butterfly (its real surviving niche — scrambles/cross-crease/wraps),
and the lunge jab with a cooldown. Paddle-down living only in the down states matches its
modern demotion from default to niche.

F11: real poke checks are committed gambles — the coaching heuristic for breakaway pokes is
~1 save per 2 goals conceded, because a missed poke leaves the goalie out of the play. The
model's poke is cost-free: the 0.25 m blade radius strips deterministically whenever the pose
brings the blade near a carried puck, with no degradation of the goalie's save-readiness during
the attempt, and the lunge jab similarly carries no exposure. The counterweight is that 0.25 m
is *far* shorter than a real committed poke (~arm+stick sudden reach), so the model is
essentially all sweep-poke, no sword-poke — conservative rather than overpowered. Still, the
in-tight deke game would gain a real risk/reward texture from making the lunge a gamble:
**Recommendation:** while `_lunge_active_timer > 0`, apply the movement-read scramble floor (or
suppress the elevated reach) so a carrier who *beats* the jab has a genuinely better shot — the
1:2 heuristic emerges from the geometry instead of being cost-free denial. Optionally extend
lunge reach a bit (real sword pokes reach ~1 m+) so it's a bigger commitment both ways.

### 6.5 Head tracking — F9, ➖

Real tracking is head-led ("Head Trajectory": eyes/nose/chin initiate every movement, the body
follows; head leads into the shot line; eyes find the rebound before the body moves). The model's
head never moves — `head_rot` is set to `Vector3.ZERO` in every pose
(`goalie_body_config_builder.gd`), and `head_yaw` rides the wire (`fill_state`,
`goalie_controller.gd:2613`) but nothing ever writes a non-zero value. This is cosmetic-only
(no gameplay read keys off the head), but it is *the* visual tell of a real goalie, and the
infrastructure (per-state head pose, wire field, client interpolation) is already fully plumbed.
**Recommendation:** drive head yaw toward the raw puck (not the blended threat — the head
tracks the puck even when the body plays a stable target; the divergence between head and chest
is itself realistic) with a fast lerp, clamped ±~60°, in all states including RVH (looking
around the post) and through the reaction freeze (eyes follow the shot). Cheapest
realism-per-line change in this audit.

---

## 7. Validated behaviors (no action needed)

For calibration confidence, the behaviors that checked out against teaching/data:

1. **BPS depth chart anchors** (B at crease top, C mid-paint, A above crease top) — real system, correct geometry.
2. **Arc positioning on the goal-center→threat ray**, shallower on sharp angles, flatten behind goal line.
3. **Backdoor depth cap as a grounded pass-flight vs re-square race** — the only real counter to the royal road, modeled the real way (reposition, never buff).
4. **Caught-moving read penalty** — directly supported by CSA set-vs-green data, rush/rebound xG multipliers.
5. **Screen occlusion as grounded sightline geometry**, own-team screeners included, netfront screens worst.
6. **Freeze-at-release + discrete resolution events + processing beat** — arrive-set doctrine + quiet-eye commitment structure.
7. **Leg-drop reflexive vs arm target-computed split** — matches blocking (pre-programmed) vs reacting (feedback) save science.
8. **Imminence gates** (no reactions/drops to far-away releases; urgency = time-to-impact, not speed).
9. **T-push/shuffle speeds and the from-rest accel ramp** — post-to-post ≈0.62 s sits in the real band; the race math honestly includes the ramp.
10. **Butterfly slide as coil→straight ballistic committed transit** — matches taught mechanics and the real can't-correct weakness.
11. **Stay-down proximity rule (2.4 m ≈ two stick lengths)** and recovery-as-vulnerable-window.
12. **Beaten-wide drop-and-seal on a lost race**; bait-the-drop as the emergent counter.
13. **Jam sealing vs stay-up-against-speed fork**; wrister charge deliberately not a drop trigger (anti-early-drop doctrine).
14. **RVH only at true dead angles / behind net** — on the right side of the modern overuse critique; butterfly↛RVH forcing a recovery window.
15. **Pad toe-out rebound steering + post-seal squaring** (steering yields to sealing at the post — verbatim doctrine).
16. **Five-hole opening during T-push/slide transit, stick-guarded when set** — matches teaching and NHL five-hole goal-share logic.
17. **Crease sweep parameters** (settled pucks only, corner-ward, never up the middle) as the correct no-cover fallback.
18. **Pre-lean/box-control glove placement off the live aim**; deception (late flick) beats the lean by construction.
19. **Shot-commit window suppressing back-door anticipation** — the real cost of committing to a shot read.
20. **Slapper windup as extra read time** (tell respected; one-timer danger comes from the lateral demand, not shot speed — matching conversion data).
21. **Skill tiers degrade real weaker-goalie traits** (depth, arm latency, rebound steering, push ramp) rather than making the goalie dumb.

---

## 8. Known limitations (out of scope, documented for completeness)

- **No catch/cover/freeze** — acknowledged in the audit request. Real hierarchy note for the
  future: cover is the *default* under pressure; the sweep is the real fallback and is modeled
  faithfully (§6.3). `is_crease_jam`'s inputs are the natural cover trigger when the mechanic exists.
- **No behind-net puck handling / dump stopping** — a large distinct real skill set; nothing in
  the current model pretends to it.
- **No desperation saves** (dives, paddle stacks, scorpions) — rare IRL, pure spectacle; noted
  as possible future polish, not a realism gap that changes outcomes.
- **Client-side goalie is a pure interpolator** — networking choice, no realism interaction.

---

## 9. Recommended priority order

**P1 — systematic realism (changes outcomes in common situations):**
1. F1 — square to the puck; move anti-jitter from target substitution to temporal smoothing/deadband.
2. F2 — butterfly drop 0.05 → ~0.15–0.20 s (+ mirror `GOALIE_BUTTERFLY_DROP_S`).
3. F3 — cross-crease: fork standing-drive vs drop-and-slide on the existing race math.
4. F4 — screens: blocking-butterfly on fully-screened releases (+ optional depth-to-screen bias).
5. F5 — speed-matched rush retreat inside ~8 m (replace lerp-lag with a grounded backflow model).

**P2 — visible fidelity / likely-unintended:**
6. F7 — lateral-pressure retreat should read carrier velocity, not raw dangle velocity (small fix).
7. F6 — knee-shuffle micro-movement while down.
8. F9 — drive head yaw at the puck (wire + poses already plumbed).
9. F12 — steer controlled pad saves cornerward instead of dead-dropping them.
10. F11 — make the lunge/poke a real gamble (readiness penalty during the jab).
11. F8 — floor the long-range depth taper at conservative.

**P3 — polish / narrow-slice:**
12. F13 — slapper tell: set-and-freeze instead of retreat (keep retreat for screened points).
13. F10 — directional recovery (rise moving toward the puck).
14. F14 — VH/Overlap stance for sharp-angle shot threats above the goal line.
15. F15 — document 0.13 s base read as baked-in anticipation (or migrate the anticipation to the
    prelean pathway and raise the base toward 0.18 s).
16. Fix `ARCHITECTURE.md` `rvh_early_angle` doc drift (60 vs 80).

---

## 10. Sources

**Positioning/depth:** USA Hockey Goaltending (usahockeygoaltending.com — Positioning, T-Push,
Shuffle, Butterfly, Full Recovery, C-cut, Controlling Rebounds); Seltytending (ABCs of Depth;
Deep vs. Aggressive; Head Trajectory; Basic Goalie Movements); GoalieCoaches.com (Angle vs.
Square; RVH Guide; Royal Road; The Butterfly; glove hand; stick saves); Hockey IQ Newsletter
(Three Axes of Positioning; History of Post Play; Recover to Feet; Save Selections; Visual
Lead); NHL.com (RVH under microscope; Unmasked screen series; sharp-angle shots; Lundqvist
Unmasked; wraparound trends); The Hockey News (High-Contrast Goaltending: Quick vs Lundqvist);
Rick Heinz Goalie Schools (How to Beat the Screen); Edge Ice Academy (Mastering the Breakaway);
Mitch Korn (breakaway play); Andrew Corchis (Bad Angle Goal; Overlap); InGoal Magazine (Jake
Allen VH vs RVH; Jet Greaves screen management; Reverse-VH back foot; Rask shin-on-post;
Crawford RVH failure; Sweden invented the RVH; Reimer/Tallas paddle-down; rebound control).

**Science/data:** Panchuk & Vickers quiet-eye studies (Human Movement Science; Eur. J. Sport
Science 2016 deflection study, PMC/VU full text); Brock University butterfly biomechanics
(*Sports* 10(6):96, 2022, PMC9229902 — 2.07 m/s drop velocity); goalie physiology systematic
review (PMC8439695); Clear Sight Analytics via InGoal/OMHA/Blue Seat Blogs (0.5 s clear-sight
threshold, red ~97 % save, green ~76 % of goals, royal road ~8.5→30 %); Hockey Graphs xG
pre-shot movement model; NHL Special Teams rebound study; Datapunk Hockey shot-type conversion
(tips ~17 %, wraps lowest); Arctic Ice Hockey shot-target visualization (five-hole ~14 % of
goals); Exploratorium Science of Hockey; elite-athlete simple-RT literature (~180–200 ms).

**Save execution/stick:** CrossIceHockey (Blocking vs Reacting; Rebound Control; glove position;
goaltending pitfalls); Hockey Canada butterfly mechanics PDF; Goalie Training Pro (5 Rules of
the Butterfly; slide/crawl drills); Yankton goalie manual (paddle-down; scrambles); Mind The Net
(Beware the Paddle-Down); Coach Nielsen (stick discipline); HockeyMonkey (poke check guide;
deception & quick release); Ice Hockey Systems (blocker save progressions; butterfly slide
progression; recovery progressions); OMHA (Protecting the Post; Preventing the Second Shot;
Royal Road; C-cuts); Steve Davies / Shapshots Hockey (glove position debate); GoalieMonkey
(RVH); Pure Hockey (butterfly technique); All Black Hockey Sticks / Hockey Answered (crease
rules, covering).
