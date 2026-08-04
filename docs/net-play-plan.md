# Net Play — Design Doc

Status: **PROPOSED** — nothing here is built. Part A is a spec; Part C is a
sketch written to be argued with.

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
- **Twine** (sides, back, top) — soft. The segment may **penetrate** to
  `blade_mesh_penetration_m` (start: 0.12) against a spring-like resistance, and
  is stopped there. It is not teleported to a face and the puck is **not**
  stripped for touching mesh.

A stick reaching for the puck from behind the net therefore resolves as *your
blade is buried in twine and can do nothing* — which is what physically happens,
and which reads correctly — instead of *a box confiscated your puck*.

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
| `SkaterController._clamp_carry_pin_from_net` | keeps the legality rule (§3) |
| `SkaterController._clamp_slapshot_pin_from_net` | keeps the legality rule (§3) |

The wrapper is why the pose sites already pass `allow_front = has_puck` and the
pin sites pass it explicitly — the legality flag is threaded through four call
sites that have no business knowing about it. That thread disappears in §3.

### 2.4 Interaction with the reach work already shipped

The boards-as-reachable-set change (`TopHandIK.max_blade_reach`,
`GameRules.ray_to_rink_inner`) is the same idea one obstacle earlier, and the net
should join it: a cast from the shoulder that stops at the *pipes* would keep the
blade from ever targeting through a post, leaving the collision above with
almost nothing to correct. Worth doing, but **after** §2.1 — the ray needs one
agreed net geometry to cast against, which is what §2.1 produces.

`TopHandIK.hand_for_clamped_blade` already handles whatever the collision does
move: blade authoritative, arm inside ROM, stick length yields. No change needed.

---

## 3. Part B — collision is not legality

Split the two jobs `NetClampRules` currently fuses.

**The blade just collides.** No `allow_front`, no `prev` path argument, no mouth
column, no concept of legality at all. It is a surface.

**The puck owns legality.** A degenerate goal is a statement about *the puck
crossing the line*, not about where a stick is. That test stays exactly where it
already lives and works — `SkaterController._clamp_carry_pin_from_net`, on
`Skater.get_carry_target_global()` — and becomes the **only** place it lives:

> A carried puck may be inside the goal volume only if its own swept path entered
> through the mouth opening. Otherwise it is knocked loose.

That is the current `allow_front` rule, unchanged in substance, applied to the
object it is actually about. `GoalDetectionRules` (host-only swept centre
crossing, `HockeyGoal.goal_scored`) is untouched throughout.

**Why this is the important half:** it decouples feel from safety. Today, every
softening of the blade rule is a potential own-goal exploit, so nobody softens
it. After the split, §2 can be tuned freely — the guarantee does not run through
it.

### 3.1 What this retires: the mouth column

`NetClampRules._resolve` confines a legal occupant to `|x| <= mouth_hw` and the
caller strips the puck the instant that clamp binds. So the boundary between
"I stuffed it" and "I lost it" is a sub-centimetre lateral threshold evaluated
on a blade that may be travelling several metres per second.

That is not skill expression; it is a coin flip with a float compare for a
referee. It exists only because the blade rule was carrying the legality job —
the column is what stopped a blade that got in legally from then roaming the box
and dragging the puck through the side mesh.

Once the puck owns legality, the column is unnecessary: the puck's own path is
tested every tick, so a puck dragged sideways into the side twine is stopped by
the twine, as a puck. The blade goes wherever the mesh lets it.

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

1. **No degenerate goals.** The puck's swept path across the goal-line plane
   through the mouth opening remains the only legal entry. `GoalDetectionRules`
   is untouched.
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

---

## 7. Staging

Each stage is independently shippable and independently revertible.

| Stage | Content | Risk |
|---|---|---|
| **A1** | Shared net geometry; `NetBladeCollision` (segment vs pipes + twine); blade call sites switched | low — pose only |
| **A2** | Buffer removed from the blade path; posts ring | low |
| **B1** | Legality moved wholly onto the carried puck; `allow_front` / mouth column deleted from the blade rule | **medium — this is the own-goal surface**; gate on the wraparound regression tests below |
| **A3** | Net folded into the reach cast alongside the boards | low |
| **C1** | Jam contest | design pass; own playtest cycle |

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

**Wraparound regression (gates B1)** — a seeded battery of blade-and-puck paths
around both posts, from both sides, at a range of speeds:
- legal front-mouth tuck scores;
- reach from directly behind does not;
- blade sweeping *across* the post at the goal-line plane does not (this is the
  own-goal bug the mouth column was added for — it must stay dead without it);
- lateral drift inside the cage presses the side twine and does not pass.

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
2. **Does a jam need a distinct input**, or is holding the existing carry into
   contact enough? Preference: no new button — the situation should select the
   mechanic.
3. **Should a post ring off the carried puck strip it?** Leaning yes: hitting
   iron on a wraparound losing you the puck is correct and feels earned, unlike
   the current mesh strip.
4. **Jam vs. the body-check commit** — a defender arriving mid-jam should end it.
   Whether that is the existing stagger/knockdown path or something specific to
   the scrum is unresolved.
