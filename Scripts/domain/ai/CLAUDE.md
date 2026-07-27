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

## Difficulty rides three independent axes

`BotSkillProfile` splits every tier knob onto one of three axes. Keeping them
separate is what makes tiers tunable without a rebalance cascade:

| axis | what it changes | knobs |
|---|---|---|
| **PRECISION** | how sharp the bot is | reaction delay, dispatch cadence, aim/timing error, settle beat |
| **PACE** | how much time and space a human gets | pursuit standoff, anticipation lead, check aggression |
| **COGNITION** | which reads exist in its model at all | the bool gates |

Precision only shows up on the bot's *finish*. Pace is what a human feels on
**every** possession, which is why the two are separate dials — reach for pace
when a tier feels oppressive, precision when it finishes too well.

The pace knobs further split by what a lower tier concedes: standoff and
anticipation concede **space** (positioning); check aggression concedes
**threat** (physicality).

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

## Determinism

Bot decisions must be replay-safe: same situation, same difficulty, same
behavior, every time. The **only** RNG anywhere in the bot is per-release
execution sampling — hands, never decision dice — seeded per bot and sampled
once per release, then held through the windup.

Domain AI files stay engine-free (no Godot APIs, no `tr()`), so the whole
decision layer is unit-testable headless.

## The goalie is not tiered

Goalie behavior stays consistent across difficulties, and the skater AI's
goalie-slide prediction in `AIActionScoring` stays in lockstep with the live
goalie regardless of tier. Don't add a difficulty branch to either side.
