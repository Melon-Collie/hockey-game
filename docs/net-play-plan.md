# Net Play — Design Doc

Status: **A1 / A2 / B1 IMPLEMENTED** (one net, iron strips, legality emergent).
**A3 and Part C outstanding.** Part C is still a sketch written to be argued
with; §10's remaining open questions are live.

Scope: everything that happens inside about two metres of the crease —
wraparounds, jams and stuffs, behind-the-net carries, and the stick poses that
go with them. Not the shot model (`docs/elevation-rework-plan.md`) and not the
goalie's read (`Scripts/controllers/CLAUDE.md`).

All constants are STARTING VALUES for playtest tuning. The shapes, the
invariants, and the ordering are the design.

---

## 1. The diagnosis — there are two nets

The area has never felt right, and the reason is not tuning. **A loose puck and
a carried puck collide with two different nets**, and the player crosses between
them constantly around the crease.

`PuckGeometryCollision` (loose puck) models the real cage, carefully:

- posts and crossbar as pipes at their true `NET_POST_RADIUS` 0.030, ringing at
  `POST_RESTITUTION` 0.55;
- side twine as vertical planes at the post line, `NET_HALF_WIDTH` 0.915 —
  `_cavity_half_width` carries an explicit comment that widening these to
  `NET_BACK_HALF_WIDTH` was a **bug**, because "the real cage doesn't flare";
- the back mesh as one plane leaning ~21°, `_back_depth_at_height` tapering it
  from `NET_DEPTH` 1.02 at the ice to `NET_TOP_DEPTH` 0.559 under the bar;
- twine at `NET_RESTITUTION` 0.05, so the puck dies in it rather than bouncing.

`NetClampRules` (the blade, and the carried puck pinned to it) models one
axis-aligned box, `NET_HALF_WIDTH + NET_PUCK_BUFFER` wide and
`NET_DEPTH + NET_PUCK_BUFFER` deep, flat at every height, with no pipes and no
restitution — teleport the contact to the nearest solid face, and strip the puck
because the contact moved.

Where those two disagree:

| Surface | Loose puck sees | Blade / carried puck sees | Gap |
|---|---|---|---|
| Side twine | 0.915 | **1.015** | 10 cm outside the visible mesh |
| Back twine at the ice | 1.02 | 1.12 | 10 cm |
| Back twine at y = 0.6 m | ~0.79 | **1.12** | **33 cm** |
| Posts | pipes, ring at 0.55 | nothing — a box corner | — |

The side row is the sharpest: the buffer puts the blade's side wall at 1.015,
which is within half a centimetre of the 1.02 trapezoid flare that the loose-puck
model was explicitly fixed to stop using. The buffer quietly reintroduces the
exact geometry that was removed as wrong.

**Consequence:** around the net you are hitting an invisible wall up to a third
of a metre outside the twine, and being dispossessed by it. That is the feel
problem. It reads as "the net is buggy" because from the player's side it is
indistinguishable from one.

Two structural faults sit underneath it:

1. **`NetClampRules` does two unrelated jobs.** It is the blade's *collision
   surface* and it is the *goal-legality gate* (the `allow_front` / mouth-column
   machinery). Because a mistake in the second job is a degenerate goal, the
   whole rule is tuned as aggressively as the legality job demands — and the
   collision job inherits that aggression. The pose can't be made good without
   touching the guarantee, so it never has been.

2. **The blade is a point against the net and a segment against the boards.**
   `Skater.clamp_blade_to_walls` tests heel *and* toe and adopts the larger
   correction. `clamp_blade_from_net` tests one point (mid-blade). The net is the
   single place on the ice where the difference between heel and toe decides
   goals.

---

## 2. Part A — one net

**Delete the second net.** This is not a new system; it is removing a duplicate.

### 2.1 What the blade collides with

The blade resolves against the same surfaces `PuckGeometryCollision` already
defines, as a **segment** (heel → toe), with two materials:

- **Pipes** (posts, crossbar) — hard. A blade segment against a post cylinder
  ejects flush, exactly at the drawn radius, no buffer beyond the blade's own
  half-thickness. The stick stops on iron where the player can see iron.
  **A carried puck driven into a pipe is stripped** (§2.5).
- **Twine** (sides, back, top) — soft. The segment may **penetrate** to
  `blade_mesh_penetration_m` (start: 0.12) against a spring-like resistance, and
  is stopped there. It is not teleported to a face and the puck is **not**
  stripped for touching mesh.

A stick reaching for the puck from behind the net therefore resolves as *your
blade is buried in twine and can do nothing* — which is what physically happens,
and which reads correctly — instead of *a box confiscated your puck*.

That split gives the player one learnable rule for the whole area: **iron takes
it, mesh just stops you.** Both halves are visible from outside — you can see
which surface you hit — which is the property the current single box lacks
entirely.

New pure rule, mirroring the existing one so the two stay reviewable side by
side:

```
Scripts/domain/rules/net_blade_collision.gd   # segment vs pipes + twine
```

It shares `PuckGeometryCollision`'s geometry helpers (`_cavity_half_width`,
`_back_depth_at_height`, the post/crossbar circles). Those move to file scope or
a small shared `NetGeometry` rule so both consumers read one definition of where
the net is — that shared definition is the deliverable, not the file layout.

### 2.2 The buffer

`NET_PUCK_BUFFER` (0.10) is a lie told to the player to paper over the blade
being a point. Once the blade is a segment against real geometry, it is not
needed for the blade.

**Do not shrink it globally.** It has three consumers with genuinely different
needs:

| Consumer | Today | Should be |
|---|---|---|
| `NetClampRules` (blade) | 0.10 | gone — real geometry + blade half-thickness |
| `GameRules.push_out_of_net` (skater bodies) | passed a body radius | unchanged — bodies legitimately need a fat exclusion |
| `GameRules.is_over_net_footprint` | 0.10 | unchanged — it is a coarse "is this over the net" query |

So the constant survives; the blade stops reading it.

### 2.3 Call sites

`NetClampRules.clamp_out_of_net` has six callers, and they split cleanly along
the Part B line. The four **pose** sites all route through one wrapper
(`SkaterIKCoordinator.clamp_blade_from_net`), so the switch is a one-line change
plus the new rule:

| Caller | Becomes |
|---|---|
| `SkaterIKCoordinator` :410 — tracked path | `NetBladeCollision` — pose only |
| `SkaterShotPoseCoordinator` :85 — slapper wind-up | `NetBladeCollision` — pose only |
| `SkaterShotPoseCoordinator` :223 — wrister follow-through | `NetBladeCollision` — pose only |
| `SkaterShotPoseCoordinator` :313 — slapper follow-through | `NetBladeCollision` — pose only |
| `SkaterController._clamp_carry_pin_from_net` | becomes pin **collision** (§3.2) |
| `SkaterController._clamp_slapshot_pin_from_net` | merges into the same pin collision — the stricter/looser split stops existing |

The wrapper is why the pose sites already pass `allow_front = has_puck` and the
pin sites pass it explicitly — the legality flag is threaded through four call
sites that have no business knowing about it. In §3 the flag stops existing
entirely, so all six sites become plain collision against one shared geometry.

### 2.4 Interaction with the reach work already shipped

The boards-as-reachable-set change (`TopHandIK.max_blade_reach`,
`GameRules.ray_to_rink_inner`) is the same idea one obstacle earlier, and the net
should join it: a cast from the shoulder that stops at the *pipes* would keep the
blade from ever targeting through a post, leaving the collision above with
almost nothing to correct. Worth doing, but **after** §2.1 — the ray needs one
agreed net geometry to cast against, which is what §2.1 produces.

`TopHandIK.hand_for_clamped_blade` already handles whatever the collision does
move: blade authoritative, arm inside ROM, stick length yields. No change needed.

### 2.5 Ringing iron strips the puck

Decided: yes. A wraparound that clangs the post loses the puck, and that reads as
earned rather than confiscated, because the player can see and hear exactly what
beat them.

The important detail is *how* it comes off. Not `_do_release` with a generic
`goalie_strip_power` shove — the puck should leave along its **own reflection off
the pipe**, which `PuckGeometryCollision.resolve_posts` already computes:
eject flush against the cylinder, reflect the into-post component at
`POST_RESTITUTION` 0.55, keep the tangential (pipes are near-frictionless). So
the strip velocity is not a new number to tune; it is the collision the loose
puck would have had, which is the whole thesis of this document applied to the
one case where the puck stops being carried.

Consequences worth stating:

- It gives the goalie's post seal a free ally at exactly the moment it should
  have one, without buffing the goalie's *reads* at all — the doctrine
  constraint in §5.3 is untouched, because iron is not a save.
- The rebound is live (0.55 off the pipe), so a ring is a loose puck in a
  dangerous area, not a whistle. Ringing iron should create a scramble.
- It applies to the jam too: prying against the post and catching pipe ends the
  jam and squirts the puck.

Twine remains non-stripping, so the asymmetry does real work — it makes *which
part of the net you attack* a decision, where today every part of it behaves
identically.

---

## 3. Part B — there is no legality, only collision

*Earlier drafts of this section split legality out of the blade rule and rehomed
it on the carried puck. That was too timid. The correct version is stronger:*

**If the puck and the blade both collide with the net properly, legality is not a
separate concept at all.** A puck inside the cage is inside the cage because it
got there — the mouth is the only opening, so any continuous path in went through
it. There is nothing left to adjudicate.

### 3.1 The codebase already argues this

`GoalDetectionRules`' bent-path fallback (which exists so a post-and-in scores
rather than being locked out by the freshness guard) is justified in exactly
these terms:

> If the puck's center finished this tick fully inside the net CAVITY, **the only
> continuous route there from in front of the line is through the mouth** — the
> posts, bar, side/top netting and back mesh are all solid — so award the goal on
> the endpoint.

The emergence argument is already load-bearing for free pucks. And directly above
it sits the confession of why it can't be used for carried ones:

> A CARRIED puck stops here: it is pinned to the blade (**teleported every tick,
> not collision-constrained**), so the cavity fallback's core assumption … does
> not hold for it.

```gdscript
if carried:
    return false
```

That is the whole story. **`NetClampRules`, `allow_front`, the mouth column, and
`_clamp_pinned_puck_from_net` all exist to compensate for one fact: the pinned
puck is a teleported point, not a collider.** Fix that fact and every one of them
is redundant.

Direction is emergent too, for the same reason it already is:
`crossed_into_net` rejects a fresh crossing when `prev_depth >= puck_radius`, so
a puck fed across from behind the line can never satisfy the edge condition. No
rule required.

### 3.2 The one thing that must be built

**The pinned puck becomes a collider.** Swept against the same net geometry as
everything else, using its own previous position — not a legality test, the
identical collision a loose puck gets.

| Surface | Pinned puck |
|---|---|
| Twine | presses into the compliant mesh; past `carry_net_squeeze_threshold` the pin breaks and the puck is lost |
| Pipes | stripped, off the pipe's own reflection (§2.5) |

The twine case is deliberately the same shape as the boards' existing
`wall_squeeze_threshold` — you press, the surface gives, and past a point you
can't hold it any more. One concept, two obstacles.

A note on a distinction that will otherwise cause confusion, since both take a
`prev` and look alike:

- `NetClampRules._entered_via_front(prev, …)` asks *"did you get here
  legitimately?"* — a **history** question. Deleted.
- `PuckGeometryCollision.resolve_net_panels(prev, …)` asks *"which side of this
  plane were you on?"* — a **sweep** question. Kept, and extended to the pin.

Only the second is collision. Only the second survives.

### 3.3 What this deletes

- `Scripts/domain/rules/net_clamp_rules.gd` — the whole file
- `allow_front` threaded through four blade-pose call sites that have no business
  knowing about it
- `_entered_via_front` and the mouth-column confinement
- `_prev_carry_pin` / `_has_prev_carry_pin` cross-tick state on `SkaterController`
- the asymmetry where `_clamp_slapshot_pin_from_net` is *stricter* than
  `_clamp_carry_pin_from_net` (`allow_front` false vs true) — physically
  unjustifiable, purely an artifact of approximating legality per-caller
- `if carried: return false` in `GoalDetectionRules`

That last one is a **bug fix, not just a simplification**. Today a legitimate
carried tuck that clips the post on the way in cannot score, because carried
pucks are locked out of the bent-path fallback. That lockout is a cost currently
being paid for the pin not being a collider, and it disappears with it.

### 3.4 What retiring the mouth column buys

`NetClampRules._resolve` confines a legal occupant to `|x| <= mouth_hw`, and the
caller strips the puck the instant that clamp binds. So the boundary between
"I stuffed it" and "I lost it" is a sub-centimetre lateral threshold evaluated on
a blade that may be travelling several metres per second — a coin flip with a
float compare for a referee.

It also *caused* the bug it is famous for fixing. The wraparound own-goal (a
blade sweeping across the goal-line plane right at the post registering as a
legal front entry, then roaming the box) was possible only because the legality
abstraction's "mouth" was a buffer-expanded box wider than the physical opening —
so a strip of "mouth" existed exactly where a post is. **With real geometry that
strip does not exist: there is a post there, and you hit it.** The bug is deleted
along with the abstraction that created it.

### 3.5 Two boundaries to keep clear

**Physical legality is emergent; rule legality is not.** High-sticking and
distinct-kicking-motion are not derivable from collision. They also do not exist
in this game today — there is no such rule anywhere in `Scripts/`. If either is
ever wanted, it is a rules layer sitting on the goal *event*, never a collision
concern. Keeping that line clean is what stops §3 being re-muddied in a year.

**Emergence holds in the host's continuous simulation.** A reconcile snap is a
discontinuity, not a sweep, so the "only continuous route" argument does not
survive one. This is fine because only the host decides goals and the host never
snaps its own authoritative puck — but it is an invariant, not an accident, and
it is the reason `GoalDetectionRules` must stay host-only.

---

## 4. What Part A + B buy

- The net you hit is the net you see, at every height.
- Posts ring. Ringing iron on a wraparound attempt is one of the best feelings in
  hockey and is currently impossible for a carried puck.
- Reaching from behind fails by being *stuffed in the mesh*, not by confiscation.
- No sub-centimetre coin flip deciding stuffs.
- The strip-on-contact rule shrinks to what it should be: you lose the puck when
  the **puck** is stopped by the net or the goalie, not when your **stick**
  brushes geometry.
- The wall-pin threshold retune already deferred on the boards side
  (`wall_squeeze_threshold`) gets a matching, honest baseline here.
- A carried tuck deflected in off the post finally scores — the
  `if carried: return false` lockout goes away (§3.3).
- **Net code shrinks.** A whole rules file, a threaded flag, two cross-tick state
  vars, and a special case in the goal detector are deleted, and nothing replaces
  them but geometry that already existed. The correctness argument gets shorter
  too: "the mouth is the only opening" is checkable by inspection in a way that
  "did the swept segment enter through the buffer-expanded mouth column" never
  was.

And it should be said plainly: **this only stops the area feeling bad.** It does
not make it good. That is Part C.

---

## 5. Part C — the jam, as an actual contest

*This section is a sketch, written to be reacted to.*

The real problem with around-the-net play, once the geometry stops lying, is that
**the net is the antagonist.** You lose pucks to collision surfaces. Geometry is
an unsatisfying opponent — it does not read, does not vary, and cannot be beaten
twice the same way. Down there the antagonist should be *the goalie's seal and
the defender on your back*.

Today a wraparound and a stuff are the same event: get a pinned puck past a
plane. They should be different plays.

### 5.1 The two plays

**Wraparound** — a race. You carry around the post along the ice; the contest is
your speed and angle against the goalie's post seal arriving first. This one
mostly *works* once §2 lands, because it is already a race and the machinery
exists: `GoalieSlideBehavior.post_seal_depth` (0.10), `seal_inset` (0.38), the
RVH stance family (`rvh_depth`, `rvh_post_pad_angle`, `rvh_swap_deadband_m`).
What it needs is for the geometry to stop deciding it.

**Jam / stuff** — a leverage contest, not a race. You are stopped at the post
with the puck against the pad, prying. Right now this has no mechanic at all.

### 5.2 The jam mechanic

While the carried puck is in contact with the goalie's pad or skate inside the
post region, holding the stick into it enters a **jam**: a per-tick push whose
outcome is resolved from quantities the player and the bots can both physically
see. Per `Scripts/domain/ai/CLAUDE.md`, this must be a grounded model, not a
shaped curve and not a roll.

Inputs, all already available:

| Quantity | Source |
|---|---|
| Seal gap — is the goalie actually sealed to the post, or short of it? | `GoalieSlideBehavior` seal target vs. live pose |
| Stance | `GoalieStateMachine` (RVH / VH / butterfly / standing) |
| Stick coverage at the ice | `GoalieStickRules` |
| Your leverage — body between puck and defender, angle to the post | skater transform vs. post position |
| Pressure — is a defender tying you up? | body-check commit / contact state |
| Puck position relative to the goal line | `get_carry_target_global()` |

Resolution shape (deliberately not a probability): the jam **advances the puck**
along the line at a rate set by leverage minus resistance. A gap in the seal is a
real gap the puck moves into; a sealed pad with the stick down is a wall the puck
does not move through, and holding into it just burns time while the defender
arrives. So the play resolves *visibly and continuously*, and both a goalie who
sealed late and a defender who arrived late are legible as the reason it went in.

The counterplay is the goalie's, and it already exists: seal earlier, or get the
paddle down. Which means the jam does not need a new goalie behaviour — it needs
the existing seal state to *matter*.

### 5.3 The doctrine constraint

`Scripts/controllers/CLAUDE.md` is explicit: realism additions may only open
scoring windows, never buff a set goalie into a brick wall, and *deception paying
negatively is the tell that a change is wrong*. The jam must be measured against
that before it ships. Specifically: if the jam makes a well-sealed goalie
unbeatable at the post, the model is wrong even if the save count looks good —
because the counterplay to a good seal is supposed to be *not jamming*, and that
choice has to keep paying.

---

## 6. Invariants that must not break

1. **No degenerate goals.** Unchanged as a guarantee, but it is now *emergent*
   rather than *enforced*: the mouth is the only opening, so any continuous path
   into the cavity went through it. `GoalDetectionRules` keeps its own geometry
   (whole-puck swept crossing inside the tightened mouth, freshness edge for
   direction); the one change to it is lifting `if carried: return false`, which
   is only safe once §3.2 has made the pin a collider. **Those two land
   together or not at all** — lifting the lockout without the pin collision
   reopens exactly the phantom "in from the back, on the stick" goal its comment
   describes.
2. **Determinism.** All of this is on the 120 Hz path and inside reconcile
   replay. Pure value math, no allocation, no cross-tick state that is not
   reset at reconcile entry — the same discipline as
   `SkaterIKCoordinator.reset_blade_smoothing`.
3. **One net geometry.** After Part A there must be exactly one definition of
   where the twine and pipes are. A second one reappearing is the bug this whole
   document is about.
4. **Host authority.** Strips and jam advancement are host-decided and
   replicated, like every other dispossession.
5. **The bots read the same net.** `AIActionScoring` prices net-front chances;
   whatever the jam resolves from, the bots must read the same quantities or
   they will plan against a net they do not face — the AI MIRROR rule in
   `goalie_skill_profile.gd`.
6. **Emergence is a property of the host's continuous simulation.** A reconcile
   snap is a discontinuity, not a sweep, so "the only continuous route" does not
   survive one. This is why `GoalDetectionRules` must stay host-only — it is an
   invariant now, not merely how it happens to be wired.
7. **Physical legality only.** Rule legality (high stick, distinct kicking
   motion) is not derivable from collision and does not exist in this game. If
   ever added it belongs on the goal *event*, never in the collision layer.

---

## 7. Staging

Each stage is independently shippable and independently revertible.

| Stage | Content | Risk |
|---|---|---|
| **A1** | ✅ Shared net geometry (`NetGeometry`); `NetBladeCollision` (segment vs pipes + twine); all four blade call sites switched | low — pose only |
| **A2** | ✅ Buffer off the blade path; posts ring; iron strips the carried puck off its own reflection (§2.5) | low |
| **B1** | The pinned puck becomes a swept collider; `NetClampRules` deleted whole (`allow_front`, mouth column, `_prev_carry_pin`); `if carried: return false` lifted from `GoalDetectionRules` | **medium — this is the own-goal surface**; gate on the wraparound regression battery below |
| **A3** | Net folded into the reach cast alongside the boards. **Deliberately held**: its whole benefit is leaving the collision less to correct, so landing it in the same change would make the A1/A2/B1 playtest harder to attribute. Cheap to add after. | low |
| **C1** | Jam contest — not started | design pass; own playtest cycle |

B1 is the one to be careful with, and it is also the one that unlocks everything
else. It should land alone, with the regression set green, and be playtested
before C1 is started.

---

## 8. Considered and set aside

**Just shrink `NET_PUCK_BUFFER`.** Treats the symptom. The blade would still be a
point against a flat box with no posts, the back wall would still be 33 cm out at
height, and legality would still be fused to collision. It also breaks the two
consumers that legitimately want a fat exclusion.

**Give the net real engine collision for the stick.** The blade is IK-driven and
must stay so — it is reconciled, replayed, and lag-compensated. Analytic geometry
is the only option that survives replay, which is why `PuckGeometryCollision`
is analytic too.

**Make the stuff a dice roll on contact.** Fails the grounded-model rule, and
worse, it is unreadable: the player cannot see why they lost, so they cannot get
better at it. The whole point of §5.2 is that the outcome is continuous and its
cause is visible.

**Let the blade pass through side mesh from behind.** Tempting for feel, since it
kills the "hard wall" complaint outright. Rejected: it is exactly the wraparound
own-goal that `NetClampRules`' header documents, and it is not what happens in
real hockey — the mesh does stop your stick. Compliance (§2.1) gets the feel
benefit without the exploit.

---

## 9. Test plan

Pure rules, so most of this is unit-testable headless.

**Geometry parity** — `NetBladeCollision` and `PuckGeometryCollision` must agree
about where every surface is, at a sweep of heights. This is the test that stops
the two nets diverging again, and it is the most valuable test in the set.

**Wraparound regression (gates B1)** — the load-bearing battery, because B1
removes an explicit guard and relies on emergence instead. Seeded blade-and-puck
paths around both posts, from both sides, at a range of speeds:
- legal front-mouth tuck scores;
- carried tuck deflected in off the post scores (the case the `carried` lockout
  currently refuses);
- reach from directly behind does not;
- blade sweeping *across* the post at the goal-line plane does not — this is the
  own-goal the mouth column was added for, and it must stay dead **for a
  different reason**: there is now a post in that strip and the sweep hits it;
- lateral drag inside the cage presses the side twine and does not pass;
- a pinned puck driven at the side mesh from outside is stopped, and past the
  squeeze threshold is lost — never passed through.

The bot angles are the adversary here. `GoalDetectionRules` notes phantom
"in from the back, on the stick" goals came "usually on a bot, whose angles are
exact", so the battery should be driven from bot-precision paths, not
hand-picked ones.

**Iron strips, twine does not** — a carried puck driven into a post comes off
along the pipe reflection (`resolve_posts`) with a live rebound, and the same
carry driven into side or back mesh is stopped without a strip. The asymmetry is
the learnable rule, so it gets a test rather than being left to tuning.

**Segment vs point** — cases where the heel is legal and the toe is not, and the
reverse. These have no coverage today because the blade is a point.

**Jam determinism** — same inputs, same advancement, replayed.

**Existing suites that must stay green** — `test_game_rules_net_pushout.gd`,
`test_rink_geometry_mirrors.gd`, `test_physics_constant_mirrors.gd`,
`test_top_hand_ik.gd`, `test_native_ik_parity.gd`.

---

## 10. Open questions

1. **Blade penetration depth into twine** — 0.12 m is a guess. It wants to be
   deep enough to read as "buried in the mesh" and shallow enough that it never
   reaches a puck on the other side. Playtest.
   `carry_net_squeeze_threshold` (§3.2) is unset for the same reason, and the two
   want tuning together: they are the same physical story told about the stick
   and about the puck.
2. **Jam vs. the body-check commit** — a defender arriving mid-jam should end it.
   Whether that is the existing stagger/knockdown path or something specific to
   the scrum is unresolved.

Resolved:

- **Does a post ring strip a carried puck?** Yes — §2.5. Off the pipe's own
  reflection, not a generic shove.
- **Does the jam need its own input?** No. Holding the existing carry into
  contact is the jam; the situation selects the mechanic. Nothing new to bind,
  nothing new to teach, and it keeps the jam continuous with ordinary carrying
  rather than a mode you enter.
- **Does legality need its own rule at all?** No — §3. If the puck and the blade
  both collide properly, a puck in the net got there legitimately by
  construction.
