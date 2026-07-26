# Basketball — Design Document

**Status:** early design. This is the record of the founding design conversation, not an
implementation plan. Nothing here has been built.

**Standalone by intent.** This document assumes no knowledge of Mitts. Where a system is
inherited from Mitts, that lineage is noted as a porting hint, but the design is stated on
its own terms so this folder can be lifted into its own repository unchanged.

---

## 1. Premise

A basketball game where nothing is canned. Every outcome — a crossover, a euro step, a
blocked shot, a rebound, a turnover — is produced by a physical simulation you are
continuously steering, not by an animation you triggered and are now watching.

The reference point is 2K, and specifically what's wrong with it: the ball is an output of
the animation system, so every meaningful action is a state you enter and cannot leave for
several hundred milliseconds. The move you picked is the move you get. Here the ball is a
simulated object at all times, your hands are a continuously-controlled contact surface, and
the named moves don't exist as entities — they're just paths the ball and your feet take.

### Pillars

1. **Absolute control of the contact surface. Zero control of the object.**
2. **No animation ever owns your input.** Poses are driven *by* sim state, never the reverse.
3. **The body is the only build.** Height and weight are the sole attributes. Handle,
   shooting, and defense are the player's real skill.
4. **Rules are enforced by physics, not by whistles.** Illegal actions are made impossible
   rather than penalized.

---

## 2. The Core Principle

> You have absolute authority over where your hands are.
> You have no authority over where the ball is.

This is the single idea the whole game hangs on. Your hands go exactly where you point them,
instantly, every frame, with no timing window and nothing to fight. The ball goes wherever
physics sends it — and it *happens* to stay with you because you're placing your hands well.

You lose the ball because a defender's hand was in the space it had to travel through. Never
because you mistimed a bounce. You never fight the input; you're only ever bounded by
momentum and by the ball's flight time.

**Hard invariant: the ball is never parented to a hand bone.** Ever. The ball's position is
always the simulation's. The hand mesh chases it. This one rule is the structural difference
between this game and 2K, where the ball's transform is an animation output.

---

## 3. Controls

### 3.1 Device stance

**Controller-first, mouse and keyboard fully supported.**

This is a deliberate inversion of Mitts, which is KBM-first. Two reasons:

- The dribble is a **body-relative absolute offset that springs to a rest position** — that
  is a thumbstick's native shape. A mouse has no springback and no magnitude bound; driving a
  dribble with one means clamping a world cursor into a body-local disc, which fights the
  device.
- **The shot's target is fixed.** Basketball has one small circle at a known 3D location.
  Precise world aim, where a mouse wins decisively, is worth much less here than in hockey,
  where you're picking corners in a 6'×4' plane.

Market logic agrees — basketball players play with pads.

**Build last-input-wins device arbitration from the first commit.** A single source of truth
that tracks the currently-driving device, with switch thresholds set above the gameplay
deadzones so a resting stick never steals control from a mouse. Control, prompt glyphs, and
menu focus rings all key off that one flag. Mitts retrofitted this successfully; here it is
foundational and should not be retrofitted.

Device arbitration is **local and presentation-time**. What the device *committed* — a shot's
power, an aim direction — is wire data. Keep that line clean in the input struct from day one.

### 3.2 The map

| Input | Meaning |
|---|---|
| **Left stick** | Movement. Repurposed by modifiers (pivot rotation, pass direction, gather steps). |
| **Right stick** | **Where my hands are.** Always. See below. |
| **BRACE** (analog trigger) | Torso rigidity. See §3.4. |
| **Shoot** (hold) | Enter gather with shot intent; release fires. |
| **Pass** (hold) | Enter gather with pass intent; release fires. Direction from left stick. |
| **Jump** | Leave your feet. Hop step, rebound, block, contest. |
| **Loft** (3-level dial) | Arc level for every release — shots and passes alike. |
| **Sprint** | Stamina-gated top-speed burst with a widened turn radius. |

### 3.3 The right stick is always "where my hands are"

This is what makes the control map coherent, and it's the analogue of "the cursor is always
the blade" in Mitts. One meaning, four contexts, no mode switching:

- **Ball in your hands** → your hands hold the ball → it's the dribble (§4).
- **Off-ball on offense** → your hands are your catch surface, your tip on an offensive
  rebound, your target for a feed.
- **On defense** → your hands are your steal, your contest, your block.
- **Under the rim** → your hands are your rebound.
- **During the gather** → the ball is in your hands, so the stick places it: extended away
  from a shot blocker, swung across your body, pulled under.

Off-ball needs no new vocabulary as a result. Cutting is just running (left stick). Sealing,
screening, and boxing out are all brace. Catching, tipping, and rebounding are all hands.

### 3.4 BRACE — one analog trigger, one physical meaning

Brace is **torso rigidity**: how hard you are holding your body's orientation against being
turned. Analog depth is real — light brace holds your angle but a strong drive can still turn
you; full brace is immovable, at a stamina cost. A small guard bracing against a big loses the
contest on mass, and no stat needs to say so.

It produces, contextually, with no modes:

| Context | Result |
|---|---|
| No contact | Facing freezes. The lock. Stay square on a baseline drive; hold an angle while you look for a read; keep your shoulder while recovering on defense. |
| Dribbling into contact | You don't get turned → shield, back-down, retreat dribble. |
| Gathered | Feet are set, left stick rotates you → **pivot**. |
| Gathered with a body on you | → **post-up**; analog depth is how hard you're backing him down. |
| Off-ball on offense | You are a legal wall → **screen** and **post seal**. |
| Off-ball, ball in the air | → **box out**. |
| On defense | Hold your ground → **legal guarding position** (see §9). |

Two guardrails, non-negotiable:

- **Hold, never toggle.** A held brace is self-correcting — release and the facing attractor
  takes you back to square. A toggle strands players facing the wrong way and they will blame
  the game. This is the entire reason a lock is safe where an aim axis was not.
- **Brace must never cancel momentum drift on a shot.** Facing determines whether you can get
  a clean release off at all; *velocity* determines lateral error. If brace canceled drift it
  becomes a mandatory hold-always button and the footwork skill evaporates. Braced and
  drifting baseline should still push the shot baseline — you bought a clean look, not a
  balanced one.

### 3.5 Facing — derived, never aimed

**There is no facing input.** This is the lesson from Mitts, where a facing-driven skating
system was designed and scrapped because there was no good way to control it without fighting
the player's hands.

The diagnosis matters: hockey has no persistent threat direction. The net is behind you half
the time, play flows both ways continuously, the puck is everywhere. There is nothing for
facing to *default* to, so it had to be manually driven, so it fought the hands.

Basketball has a fixed hoop and a halfcourt possession structure. There is always an obvious
forward. So facing is composed from three things you already control:

1. **Attractor.** On offense, torso pulls toward the hoop. On defense, toward your man. That
   is where a real player is squared roughly ninety percent of the time.
2. **Momentum perturbs it.** As you build speed your torso leans toward your movement vector.
   The drive shoulder emerges from the fact that you're driving. This also makes shooting off
   a hard drive naturally off-balance, which is the accuracy model doing its job for free.
3. **Brace overrides it.** §3.4.

**Defensive stance angle gets no input either.** Forcing baseline versus forcing middle is
real defensive skill, but positioning *is* the force — shade a shoulder to his left and you've
geometrically taken away his left. Adding a stance-angle control would repeat the Mitts
mistake.

### 3.6 Camera

**Elevated wide, roughly 50°, framed from behind the offensive end looking at the rim. Static
or near-static in halfcourt 3v3.**

Not over-the-shoulder, and not a steep Mitts-style tilt. The number is the design.

#### Why ~50°

For a camera at elevation θ, a vertical meter projects to screen at `cos θ` and a meter of
depth at `sin θ`:

| Elevation | Vertical retained | Depth retained |
|---|---|---|
| 25° (broadcast) | 91% | 42% |
| **50°** | **64%** | **77%** |
| 70° (Mitts) | 34% | 94% |

At 70° a 1.1 m shot apex reads as ~37 cm of screen movement — marginal, and arc is a real dial
here (floater over the big, lob, bounce pass under the hands). At 50° the same apex reads as
~70 cm while retaining most of the floor. That's the tradeoff this game wants: enough
verticality to read arc, enough floor to read spacing.

**Consequence: the ball's floor shadow is mandatory, not polish.** 50° is very close to the
angle where a meter of height and a meter of depth project to the same screen size
(`cot 50° ≈ 0.84`). Position alone therefore cannot tell you whether the ball is high or
merely far — this is the maximum depth-confusion elevation. The shadow-to-ball gap *is* height
and is the only thing that disambiguates it. The angle also guarantees you can see plenty of
floor for the shadow to land on.

#### What a wide camera buys

- **The skip pass stops being blind.** Directional passing with no auto-aim (§8) only works if
  you can see the target. This resolves the one place where the camera and the 5-out spacing
  premise were pulling against each other.
- **Survey is deleted as a mechanic.** You already have the floor. One fewer input.
- **Off-ball becomes visible**, which matters enormously when you are one of three and off-ball
  is most of your time.
- **Facing stops driving the camera**, decoupling it further. The attractor model in §3.5
  survives unchanged; it simply has no camera consequence.

#### Static camera in halfcourt 3v3

At 50° a halfcourt (47 × 50 ft) fits comfortably in frame, which means the 3v3 camera can be
static or nearly so. This is only available because halfcourt is the first mode, and it's
worth a lot for a skill game:

- **Landmarks live at fixed screen positions.** You learn where the three-point line, the
  elbows, and the corners *are* on screen, the way you learn a fighting game stage. Shot
  distance becomes something you read instantly rather than estimate.
- **Push up is always toward the rim.** No camera-relative remapping ever, for movement or for
  the dribble stick. Push right, the ball goes screen-right. Completely stable muscle memory.
- **The camera never flips.** Both teams attack the same basket, so a possession change
  reorients nothing.
- **The backboard faces you**, which makes bank shots readable as a real option rather than an
  accident.

5v5 fullcourt has to follow the ball. That's a later mode — and starting halfcourt buys a
static camera for the entire period when feel is actually being tuned.

#### The open tension: 1v1 pixel budget

Framing a full halfcourt puts a player at roughly 10% of screen height and a hand at ~1%. The
marquee mechanic is hand-versus-ball at 30 cm of scale. 2K survives this because its dribble
moves are **discrete animations** — you only need to see *that* a move fired. Continuous
control raises the legibility bar.

Working answer: frame somewhat tighter than the whole halfcourt with a gentle pan, hold 50°,
and tighten further during an isolation. That sacrifices some of the static-landmark benefit to
keep most of it. Whether it's enough is a prototype answer, not an argument. See §16.

---

## 4. Dribbling

The marquee mechanic. Right stick sets the ball's target offset from your body.

### The bounce cycle bounds you; it does not time you

You never "miss" a dribble. You point, and the ball takes the shortest path physics allows.

- A **fast stick sweep** produces a tight, low crossover — the shortest legal path.
- A **slow sweep** produces a lazy, high one.

Structurally this is the same second-order servo as the blade in Mitts, with the bounce cycle
standing in for arm inertia. Same guarantee: bounded by physics, never fighting the input.

### Bounce height is a real, physical tradeoff

- **Low pound dribble** → short bounce cycle → more contacts per second → tighter control,
  less ground covered, less exposure.
- **High push dribble** → fewer contacts → more distance per push → transition speed, more
  exposure.

That is the actual in-traffic-versus-open-floor read, and it falls out of the ball physics for
free.

### Everything named is emergent

No trapping, toe drags, hesitations, between-the-legs, or behind-the-back as entities. They
are paths the ball takes when you move the stick a certain way — exactly as a toe drag is just
where the blade went. Crossing the body's centerline *is* the crossover.

### Protection is geometry

Keep the bounce line on the far side of your body from the defender and he physically cannot
reach it. Body-as-obstacle does all the work; no possession stat is consulted.

---

## 5. The Ball

### Deterministic analytic simulation, no physics body

Lead with a deterministic sim rather than retrofitting one (Mitts retrofitted; it was
expensive). Fixed-step, shared literally between host and client. Contacts to write:

- Ballistic integration with gravity
- Sphere vs. plane — floor, backboard
- **Sphere vs. torus — the rim.** This is the soul of the game. Get it right before anything
  else.
- Sphere vs. capsule — bodies, arms
- Sphere vs. palm surface — the contact model below

### The contact model

One normal/tangential decomposition of the incoming velocity against the palm plane. The same
function serves every hand-on-ball event, offense and defense:

- Push down **through** ball center → hard straight dribble
- Push down **off-center** → the ball squirts sideways → crossover
- Push **up** → shot, pass, lob

Same math, different sign. Bobbles, deflections, tips, and strips are all this function with
different geometry.

### Spin

**Model backspin.** It's the difference between touch and a brick. A shot with backspin that
hits the back rim drops; without it, it bounces long. Shooter's roll and in-and-outs stop
being random and become a physical consequence of the release. This is depth 2K structurally
cannot have, and it is nearly free once the ball is analytic.

### Net

Cosmetic verlet net driven off the deterministic ball. Never feeds back into the sim. Huge
feel payoff for zero simulation risk.

### Violations are read off the sim, not detected

- **Carry** — your palm stayed under the ball while it moved upward.
- **Double dribble** — two hands contacted, then a bounce resumed.
- **Goaltending** — a hand intersected the ball on its downward arc above rim height.

---

## 6. Shooting

### The target is fixed, so don't spend precision on aiming

There is one small circle at a known 3D location. Pointing at it is nearly free. The
difficulty must come from everything else.

**Direction** — at the rim, or at a spot on it. Bank shots are emergent because the backboard
is a real surface; aiming at the square instead of the rim is a real option, not a shot type.

**Power = distance.** Under-power hits front rim, over-power hits back iron. The distance-to-
power mapping is the shooting skill you internalize. No meter, no timing bar, no green window.

**Loft dial = arc.** Three levels, applying to every release in the game:

| Level | Shot | Pass |
|---|---|---|
| Flat | Line drive — quick, blockable | Bounce pass, under the hands |
| Normal | Standard arc | Chest pass |
| High | Floater / rainbow, over the big | Lob — and the alley-oop |

**Lateral error comes from your body, not a stat.** This is the load-bearing part. If
direction were purely cursor-to-rim, every miss would be long or short and never left or
right. Instead the shot inherits your momentum: drifting right pushes the ball right.

That makes **footwork the accuracy skill**, which is precisely what shooting is. Jump stops,
squaring up, and catch-and-shoot being easier than a pull-up all emerge, and none of it is
scripted.

### Release geometry comes from height, not a rating

Longer lever, same fork as the blade in Mitts: tip speed scales with lever, inertia cap scales
inversely. So a big **releases from higher (harder to block) but takes longer to get there
(easier to contest in time)**. Guards get quick low releases; bigs get high slow ones. That is
the real distinction, expressed as geometry.

### Shot type is never selected

Where you end up and how you're moving *is* the shot. Eighteen feet out with momentum going
away from the rim is a step-back jumper, and the fade is real fade, so it's genuinely harder.
At the rim moving laterally is a euro finish. Same input, same physics, completely different
shot, decided by footwork rather than by a menu.

---

## 7. The Gather

Euro step, hop step, step-back, spin finish, and up-and-under are not three or five moves.
**They are one mechanic: the two aimed steps you get after picking up your dribble.** 2K makes
each a separate canned animation with its own input because it must. Build the budget and you
get all of them, plus a hundred things that don't have names.

### The shape

Hold **shoot** or **pass** to gather. Both spend your feet identically; the difference is the
*tell*. Then:

- **Left stick spends the steps.** Push left, first step plants left. Push right, second plants
  right. That is a euro step — and you never pressed euro. Step away instead, that's a
  step-back. Both steps the same way is just a hard drive.
- **Right stick places the ball.** Extend it away from the shot blocker, swing it across your
  body, pull it under. This is the half of a euro that 2K bakes into the animation, and it
  should be yours.
- **Release fires** from wherever you ended up.

### Why it feels earned instead of selected

- **Momentum buys step length.** Gather at full speed for a long step; gather standing still
  and you get almost nothing. You genuinely cannot euro from a standstill. The size of the
  move is paid for with the drive that set it up.
- **Planting commits.** Once a foot is down your center of mass is going where you sent it. No
  cancel. That is what makes the defender's decision real — bite on step one and you're dead,
  sit on it and the finish is contested.

### What makes it not 2K

> **The second step is a live read.**

In 2K the euro is a fixed-displacement animation; you commit to the whole thing and the
defender's only counter is to have already been in the right place. Here step one plants, you
*watch the help defender react*, and then you aim step two. Continuous displacement — you can
euro forty centimeters or two meters depending on what you had.

The bound is honest: you cannot step hard left while carrying six meters per second to the
right. Physics says no, same as the dribble servo.

### The other moves come free

- **Hop step** = jump during the gather. Both feet leave, both land together. Buys more lateral
  displacement in one beat but ends your footwork. Real tradeoff, no new system.
- **Spin** = brace-rotating through a step.
- **Up-and-under** = pivot with the ball placed under a raised arm.

### Fakes are free too

You can enter the gather with either intent and switch mid-gather. A **shot gather raises the
ball** and the defender reads it; a pass gather doesn't. So:

- **Pump fake** = start a shot gather, don't release, bring it down.
- **Pass fake** = the mirror.

No fake button, no animation to trigger — the defender is reading your body actually doing the
thing. And the pump fake self-limits without a timer, because bringing the ball back down
costs the beat and lets the closeout re-set.

### Passing out is allowed, and getting stuck is real

You can bail into a pass. The risk is inherent to basketball — players get caught doing this
constantly. **The price is your feet either way**, so bailing leaves you planted and
vulnerable.

Consequences:

- **Leaving your feet is punished by physics, not by a stat.** The canonical basketball
  turnover is jumping with no plan. A pass out of a hop step is a pass from mid-air with zero
  ability to reposition, threading whatever lanes exist at that instant. Nothing needs to code
  an "airborne pass penalty" — you jumped, you can't move, the lanes closed.
- **Trapping becomes real team defense, emergent.** Two defenders converging on a gathered
  player is devastating specifically because he can't dribble out, and none of it is scripted.
  It becomes true the moment the gather has a real cost. This matters enormously in 3v3, where
  it gives the defense a team answer instead of only 1v1.
- **The stuck state always resolves.** Feet locked, no lane, defender's hands on your ball →
  contested pickup → tie-up → jump ball. Never a soft-lock.

---

## 8. Passing

**Directional. Pass button plus left stick. No auto-aim, no target cycling, no assist.**

A stick gives roughly two to three degrees of practical precision, which at eight meters is
about forty centimeters of error — well inside a person. Directional passing is accurate
enough to thread, and it makes **leading a cutter a real skill**, which is one of the best
things in basketball and something no basketball game asks you to do.

- The pass is a **real ball in flight**, so interceptions are physical. A hand in the lane
  takes it. There is no interception roll.
- The **loft dial** applies: bounce pass under the hands, direct chest pass, lob over the top.
- **Alley-oops are emergent.** You don't press "oop." You lob to a spot above the rim and
  somebody jumps to meet it.
- **Catching** reads relative speed and hand angle at contact — a feed to a receiver moving
  away arrives soft, charging into the same feed makes it harder. Bobbles are real.

### Why this needs the wide camera

Directional passing with no assist only works if you can see the target. The skip to the
weak-side corner is the most valuable pass in 5-out spacing, and under an over-the-shoulder
camera it would be a blind throw — which was the strongest argument against that camera and
part of why §3.6 settled where it did. With the floor visible, the skill is aiming and leading,
which is the intent.

---

## 9. Defense

Defense is the mirror of offense, with the same absolute authority. That symmetry *is* the
skill matchup, and it is the thing 2K structurally cannot do because both sides are
animation-gated.

- **Right stick places your hand**, exactly as it places the ball on offense. The 1v1 becomes
  two players moving contact surfaces at each other in a bounded space, resolved
  geometrically.
- **The steal is positional, not a gamble.** You put your hand in the space the ball *must*
  travel through. Because the ball cannot teleport across the handler's body, its path is
  bounded, and therefore attackable. The offensive counter is not committing to a path that's
  already covered. Read, counter-read, zero randomness.
- **Reaching costs a weight shift.** A hand extension carries a small lean, so reaching and
  missing genuinely puts you behind. "Don't reach" becomes emergent rather than a consequence
  of a foul system.
- **Blocking** is a real hand intersecting a real ball in flight. Goaltending is read off the
  ball's arc and height (§5).

### Why the offense ever wins: momentum, not stats

Both players have absolute control and the same reaction time. The offense's edge has to be
structural — it knows its own intent. Two things make that pay:

- **Defensive stance is laterally excellent but forward/backward committed.** Sliding sideways
  is cheap; getting your weight downhill and shedding it is expensive. That's real defensive
  footwork, expressed as an anisotropic thrust profile on the existing momentum model.
- **Reaching leans you.**

Put those together and the ankle-breaker is a **momentum-shed race**: you got the defender's
weight going one way, then moved the ball to the other side faster than he could shed it.
Nothing canned, no trigger, no dice.

### Over-helping is punished by spacing

You cannot double team in 3v3 — there is too much space. Even in 5v5, realistic spacing is
five-out. Brace-as-wall does not seal the paint because a help defender who commits early
gives up his own man. Stamina on brace is the additional lever if it proves necessary; see
§14.

---

## 10. Contact and Rules by Prevention

**The philosophy: illegal actions are impossible, not penalized.** Free throws are bad
gameplay. Whistles are bad gameplay. So in the default ruleset, contact that would be a foul
simply cannot be produced.

### Brace is the foul system

Every defensive foul that matters is the same thing: **you were not set, and you used your
body anyway.** Blocking foul, hacking, moving screen, undercutting. Legal contact is the
mirror: set, braced, vertical, or a clean hand on the ball.

So: **a braced defender is a wall. An unbraced one loses the momentum exchange.**

> "Loses the exchange" is not "no collision." A driver clipping *through* a defender reads as
> a bug regardless of how correct it is. The driver wins the exchange and keeps his line while
> the defender is visibly displaced, spun, knocked off balance. Port the stagger shape from
> Mitts' body checks. It reads as strength, not as missing collision.

What that one rule buys:

| Foul | Why it's impossible |
|---|---|
| Blocking foul | A defender still sliding is not a wall. He can only get moved. |
| Hacking / reaching in | An unbraced arm transfers nothing. You still pay the weight shift for reaching and missing, so the risk/reward survives — you just can't hack. |
| Moving screen | A screener is a braced body. **You cannot brace and move.** |
| Illegal defense on a jumper | Verticality falls out: a braced defender is hard *upward*, so a shooter jumping into him is stopped. That is the actual rule. |

### The one explicit rule

**While an offensive player is airborne, no defender body can push him laterally. Only the
ball is contestable.**

This is the one foul that cannot be handled by "were you set," because a set defender under a
landing shooter is still a foul in real life. It kills the undercut and protects landing
space — the griefiest possible interaction in a physics basketball game.

### And-ones need no free throws

If a braced defender is legal contact, then finishing through him **is** the and-one — you
absorbed the impulse, held your line, and got it off. The bucket is the reward. The interior
scoring fantasy is preserved and nobody ever goes to the line.

### Self-correcting balance

Bracing costs you the ability to slide. A defender who holds brace forever gets walked around
trivially. Set early and you're a wall; set late and you're furniture. That is real help
defense, and it needs no tuning to be true.

### Traveling — prevented in every mode

Two steps, hard budget. When it's spent, your feet lock: shoot or pass. That is a real bind
rather than a whistle, and it teaches the rule physically. The stuck state resolves through
the tie-up (§7). A SIM ruleset may whistle it instead.

### Tie-ups

Two sets of hands on the ball with force is a physical contest — the same math as a contested
loose-ball pickup, with a jump ball or possession arrow on top.

### The SIM ruleset is purely additive

Fouls become whistles on contact the default ruleset makes soft, plus free throws, plus the
bonus. Nothing about the default has to be undone to get there. Same shape as arcade versus
strict rulesets in Mitts.

---

## 11. Player Attributes

**Height and weight are the only attributes. Everything else is earned.**

Ball handling, shooting, defense, passing — identical for every player. That's your actual
skill at the game. There is no rating to buy, no badge to grind, no progression economy.

This fits basketball *better* than hockey: positional identity in basketball is genuinely
physical. A 6'0" guard and a 7'0" center really are different games.

### The central problem: height must be made lateral

**In real basketball, height is close to a free win.** That's why the NBA is tall. Reality
will not hand you laterality here — it has to be built. The good news is the levers are all
real, and all *geometric* rather than multiplicative.

| Lever | Effect |
|---|---|
| **Handle = bounce-cycle length** | A seven-footer's dribble travels further to the floor and back, so his cycle is longer, so he gets fewer control contacts per second. His crossover is slower and the ball spends more time out of his hand. **Guards handle better because they're closer to the ground.** This is probably the most important lateral term in the game, and it is nothing but the ball's flight time. |
| **Release: high but slow** | Longer lever. Releases from higher (harder to block), takes longer to get there (easier to contest in time). |
| **Reach: wide but slow** | Long arms cover a larger steal/contest envelope that is harder to redirect. A big reaching at a quick guard's crossover is a bad trade. |
| **Center of mass** | Low man wins the brace/leverage contest. Keeps a 6'0" guard from being erased in the post — he can't move a big, but he can get under him. |
| **Vertical vs. standing reach** | Impulse over mass: lean and short jumps higher, tall and heavy stands higher. Peak reach converges, which is true in life. The real differentiators become **time to apex** (the quick leaper gets there first) and the fact that a big has his reach available *without jumping*. |

### Weight

Mass (collision outcomes both delivering and absorbing; brace strength is mass-emergent), the
acceleration-versus-momentum fork (lean = first-step burst, heavy = momentum), lateral grip and
turn radius, and stamina metabolism (lean = shallow pool with fast regen; heavy = deep pool
with slow refill).

### Ranges

Retunings of the Mitts system rather than new architecture:

- **Height:** ~5'9" to 7'3" (Mitts: 5'8"–6'7")
- **BMI band:** ~22 to 29, leaner and wider than Mitts' 24–29, so both a 6'0"/175 speed guard
  and a 6'11"/280 bruiser are representable
- **Neutral:** ~6'6" / 215 — the actual league-average frame, and the point where every
  multiplier is 1.0
- **No power economy.** Every axis is lateral. Validation is pure coercion onto the nearest
  legal body; there is no legal-build check.

### Gear

**Shoes.** Traction versus cushion is a real lateral trade — grip for cuts and stops against
energy return for straight-line speed and landing. Structurally the skate-profile slot with a
new name.

### The place laterality is hardest

**Rebounding and rim protection.** When the ball is at ten feet there is no geometric cost to
being tall. The only counters are positioning (box-out beats reach) and time-to-apex, and both
must be strong enough to carry it alone. If the meta collapses to "tallest legal body," this
is where it will happen first. Watch it specifically in playtest.

### The consequence

With nothing earned, **the mechanics are the entire content.** There is no progression curve
to carry a player through the first fifty hours — the dribble, the gather, and the defensive
matchup have to be deep enough to be the whole reason to keep playing.

That is also exactly why it's a real counter-position. "Your body is the only build,
everything else is you" is a hard, legible pitch to the large audience tired of buying VC.

---

## 12. Scope

**3v3 halfcourt first. 5v5 later, once the mechanics are locked.** Same path Mitts took, which
mostly went fine.

Why 3v3 first:

- Two AI teammates instead of nine
- Half a court to build
- No playbooks needed
- It's the format where individual handle and iso creation matter most — which is exactly what
  the game is selling
- Culturally loaded in a good way: blacktop, 3x3 Olympic, And1, NBA Street

5v5 becomes the same kind of second-mode expansion 5v5 hockey was in Mitts.

---

## 13. Technical Direction

### Engine and language

**Godot with .NET.** Better ecosystem for headless testing, and more performant than GDScript.

### Determinism from day one

Lead with a deterministic sim rather than retrofitting one. The host and clients share the
simulation step literally, so bit-exactness matters even though the model is
prediction-and-reconcile rather than lockstep.

- **Transcendentals are the trap.** `+ - * /` and `sqrt` are IEEE-deterministic on .NET/x64,
  but `Math.Sin`, `Math.Cos`, `Math.Pow` and friends are **not** guaranteed bit-identical
  across platforms or runtime versions. Either keep them out of the sim path entirely or ship
  your own implementations. **Decide before the sim exists, not after.**
- **Struct discipline.** C# structs are genuinely stack/inline allocated, so the simulation
  math can be zero-allocation in a way GDScript cannot. Set the rule now: sim types are
  structs, no LINQ anywhere in the tick, no per-tick heap objects.
- The 120 Hz tick multiplies every cost by actor count, and reconcile replay re-runs the
  per-tick body once per replayed input — so a hot-path regression is amplified exactly when
  the network is worst.

### Netcode

Wholesale reuse of the Mitts approach: client-side prediction with input replay, buffered
interpolation, trajectory prediction with reconciliation, lag compensation, transport-agnostic
RPCs. This is the single largest body of proven work being carried over.

### Readability

**A hard floor shadow under the ball is not polish, it's a core system.** Reading a small fast
ball in 3D is genuinely hard — depth perception for "will this pass get picked" and "where is
this rebound landing" is the make-or-break. The floor is always right there: shadow position
gives exact XY, shadow size gives height.

At the chosen 50° elevation this is load-bearing rather than merely helpful, because that angle
projects height and depth at nearly the same screen scale and the shadow is what separates
them (§3.6). Prototype it early — alongside rim physics, not after.

### Procedural locomotion

The promise is **not** "no animation." It's "no animation that owns your input." Poses driven
*by* sim state — momentum, ball position, lean, contact — never driving it. That's an
achievable art problem; "zero animation" is not. See §14 for why this is the top production
risk.

---

## 14. AI Direction

**Rebuild rather than port.** Keep the utility-AI model — evaluators scoring competing actions,
grounded in quantities the actor can physically perceive rather than magic curves. Replace the
domain model entirely.

- **A new expected-points model** ("xG for basketball") — expected points from a position,
  accounting for distance, angle, contest, and the shooter's own release geometry. This is the
  spine the rest of the evaluation hangs from, the way shot-danger scoring is in Mitts.
- **The gather must price "do I have an out."** Not just expected points from a position — a
  bot that picks up its dribble in traffic with no passing lane is making a real, legible
  mistake, and being able to *induce* that mistake is one of the most satisfying things a
  defense can do.
- **Off-ball cutting is the genuinely new problem.** The Mitts scoring architecture prices
  "should I shoot, pass, or carry" well, and that shape ports. It has no concept of *making
  yourself catchable in 1.2 seconds* — and in basketball a player's value is largely in where
  they aren't yet. In 3v3 halfcourt this can probably be approximated with spacing slots. In
  5v5 it becomes the whole AI problem and may argue for a different core abstraction.
- **Directives from pings** port directly: a team-only contextual call-out that bots obey as a
  bounded bias inside the existing role architecture, never as a forced override.

---

## 15. Open Questions

Not blockers for prototyping, but unresolved:

1. **Defensive assignment and player switching.** Do you control one player for a whole
   possession, or switch to the nearest defender? Biggest of the remainder. It's a UX/mode
   question rather than a mechanics one, but it changes how defense actually plays.
2. **The shot's exact input shape.** Hold-and-release with power from hold time, an analog
   push, or something else. The Mitts wrister's mouse-speed model has no direct stick
   analogue.
3. **Pass speed and distance control.** Direction is settled; magnitude is not. Fixed speed
   per loft level, or an analog component?
4. **The off-arm.** Shielding on a drive, the box-out, the post seal. It's a capsule to
   position, so it's nearly free to simulate — but it may be one system too many for the hands
   to manage on top of ball, torso, and movement. Likely automatic (braces toward the nearest
   defender) rather than controlled.
5. **Does brace on the paint need a cost beyond mobility?** Spacing should punish over-help on
   its own. Stamina is the obvious additional lever if it doesn't.

---

## 16. Risks

**Procedural bipedal locomotion is the top production risk** — bigger than the simulation.
Skating hides the legs and can be faked with a stroke warp. Basketball is running, jumping,
landing, pivoting, and constant contact, and the body *is* the gameplay. Defused by the
"driven by, never driving" framing in §13, but it remains the hardest art problem here.

**Ball readability in 3D.** See the floor shadow note in §13. A feel make-or-break, not a
polish item.

**Height meta collapse.** §11. Rebounding and rim protection are where it would start.

**Turnover rate.** Basketball possessions are scarce — roughly a hundred a game, half of them
yours — where a loose puck in hockey is constant texture. If dribbling is genuinely hard, a
mediocre player turns it over on a third of touches and the game is miserable. The design
answer is that a bad contact should be a **loss of advantage, not a loss of possession**: the
ball gets away from your body, killing your drive and letting the defender re-set, but you
usually recover it. The steal must be *earned by the defender's hand being in the right
place*, never granted by the handler's mistake.

**1v1 legibility at camera distance.** §3.6. The whole game is hand-versus-ball at ~30 cm of
scale, viewed from a camera framing most of a halfcourt. 2K tolerates this because its dribble
moves are discrete animations you only need to *notice*; continuous control has to be
*read*. If the defender's hand position isn't legible, the momentum-shed race degrades into
guesswork and the marquee mechanic dies. Watch it the moment the 1v1 is playable.

---

## 17. What to Prototype First

In order, before any further design work:

1. **Rim physics.** Sphere versus torus with spin. Everything downstream is worthless if a
   made shot doesn't feel made.
2. **The dribble contact model** with the bounce-cycle servo, one player, no defense. Does
   moving a stick and watching a ball respond feel good in isolation?
3. **The 1v1** — dribble against a hand-controlled defender. This is the game. If the
   momentum-shed race feels right here, the rest is execution.
4. **The gather** with two aimed steps.

Design further only after (2) and (3) prove out.
