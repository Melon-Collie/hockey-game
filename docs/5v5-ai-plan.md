# 5v5 AI — Design Plan

Status: **design agreed + fleshed out, implementation in progress** on
`claude/5v5-hockey-ai-qkirks`. This is the handoff document per the CLAUDE.md workflow
("design complex AI features first, then implement against the codebase"). Everything
below is the banked design; deviating from it means asking first.

The original agreed design survives intact; this revision **fills in the open details**
(§2 slot specs, §3 zone geometry, §6 exposure math, §7 plumbing) with real-hockey
research — NHL coaching sources, condensed into the tactics appendix at the bottom —
and bank three v1 scope calls made after the original design:

- **OT stays 5v5.** Real NHL OT drops to 3-on-3; mid-game roster changes (benching four
  skaters at the OT transition) are brand-new machinery, deferred as a follow-up.
- **No line changes and no stamina rebalance.** Ten skaters at full intensity all game is
  the accepted v1 fiction, matching the game's arcade posture. The existing stamina pool
  already self-regulates sprint usage.
- **All four phases land in one implementation pass** (one commit per phase), pushed for
  local testing at the end.

## Goal

Add **5v5** as a lobby-selectable game mode that lives **alongside** 3v3, not replacing
it. You pick the mode when you create the lobby. Both modes share the same engine,
physics, networking, and lower-layer AI; they diverge only at the AI **role layer** and
in a handful of size-parametric plumbing spots.

The engine plumbing is the easy part. The real work is AI: 3v3 has no defensemen —
everyone is a puck-chasing rover — and 5v5 is *defined* by the forward/defense split.
That split is the one load-bearing new concept; everything else is additive and hangs
off it in a predictable order.

### Non-goals (v1)

- No change to 3v3 behavior. The 3v3 role path is reused **verbatim** and stays
  regression-safe by construction.
- No positional *inference* for humans — positions are explicit lobby picks (see below).
- The transition-exposure term is **5v5-gated** for v1 (see §6).
- No 3-on-3 OT format for 5v5 matches, no line changes, no fatigue rebalance (above).
- No deliberate D **pinch** behavior in the O-zone (the "D pinches, F3 fills" rotation).
  The election's cross-fill produces the *cover* half for free (a D who ends up deep —
  e.g. wins a loose-puck race — leaves his point to a leftover forward), but nobody
  *initiates* a pinch in v1. Tracked in §10.

## Guiding constraint: additive, mode-latched

Team size is a **match config latched at puck drop**, exactly like online-ness and
ruleset (`ARCADE`/`NHL`/`OFF`) are today. Concretely:

- A `team_size ∈ {3, 5}` value, chosen in the lobby, frozen at drop. It rides the exact
  `rule_set` rail: `LobbySettingsPanel` row → `NetworkManager.pending_team_size` +
  `pending_game_config["team_size"]` → latched into `GameStateMachine.team_size` by
  `apply_config` in `GameManager._spawn_world` → read back via
  `GameManager.get_team_size()`.
- The AI role layer **branches** on team size at one explicit seam: `TeamBrain` carries
  `team_size` and dispatches to the legacy 3v3 election (`AIRoleSlots.assign`,
  untouched) or the new position-aware path (`AIRoleSlots5.assign`, a new file — §2).
- Everything **below** the role layer is shared and size-agnostic — `carrier.gd`,
  `steering.gd`, `action_scoring.gd`'s EV models, `pass_lead`, `shot_aim`,
  `loose_puck_chase`, `body_check`. They never counted bodies and won't start.

```
GameStateMachine.team_size (latched at drop)
        │
        ▼
   TeamBrain (per team, carries team_size + position_by_peer)
        │
        ▼
   team_size == 3 → AIRoleSlots.assign            (legacy, UNTOUCHED)
   team_size == 5 → AIRoleSlots5.assign           (new: group-scoped election)
        │
        ▼
   role_behaviors/*  (carrier, steering, action_scoring — SHARED, size-agnostic)
```

## 1. Positions come from the lobby (the F/D identity layer)

The single new architectural concept. In 3v3, role assignment is **pure kinematics**
("whoever arrives at the slot anchor soonest wins", `_pick_soonest_with_hysteresis`),
and it's position-blind. That works because 3v3 has no player who should stay home even
when he's closest to the puck. 5v5 breaks that: your defenseman is often the nearest body
to the puck, and pure kinematic slotting would vacuum him up-ice as F1, leaving nobody home.

The fix: a **persistent per-peer position** that gates the election. Crucially, the hook
already exists — **`team_slot` IS the position.** The lobby slot grid is already
positional (slot 0 = C, 1 = LW, 2 = RW, driving faceoff alignment); 5v5 extends the
range: **slot 3 = LD, slot 4 = RD**. `PlayerRecord` needs no new field; the brain reads
`position == team_slot`.

- Full 5v5 lineup: **LD, LW, C, RW, RD** (grid display order `[3, 1, 0, 2, 4]`).
- Position → group mapping: **{LD, RD} = D group, {C, LW, RW} = F group.**
- The kinematic soonest-to-arrive election runs **within each group**: the 2 D compete
  for the D-tagged slots; the 3 F compete for the F-tagged slots. Same election
  machinery, scoped. When a group is short (its member is the carrier, or a human
  abandoned his post), leftover slots **cross-fill** from the remaining peers — this is
  what makes "D activates, a forward covers his point" emergent rather than scripted.
- Positions are explicit lobby picks for **humans and bots alike** — not inferred, not
  flex. A human picks their spot like everyone else; bots fill the unselected slots. The
  slot grid guarantees the filled slots per team, so no position is ever uncovered.

### Strong/weak falls out for free

Because the 2 D compete for the 2 D-roles by live positioning, **strong/weak is
emergent**: whichever D is currently on the strong side wins the strong-side-D role, the
other fronts the net. No hard `LD → strong` tag needed. Same for the forwards' 3 roles.
5v5 slots are therefore named **strong/weak where the job is puck-relative** (points,
zone areas) and **L/R where the job is geometric** (rush lanes, neutral-zone flanks).

### L/R as a home-side rest bias (not a discarded tag)

Real D hold their side and only exchange on puck movement. So the L/R label survives the
lobby as a **home-side election bias**: in the soonest-to-arrive election, a peer whose
lobby position matches a slot's current side (LD/LW ↔ anchors at x < 0, RD/RW ↔ x > 0,
C ↔ the central slot) gets a flat arrival-time discount, `POSITION_BIAS_S ≈ 0.35 s`.
Calibration intent: at rest (both D equidistant) the bias always decides — LD takes the
left point; on a genuine cross-ice swing the kinematic advantage exceeds 0.35 s and the
D exchange sides, exactly the real-hockey behavior. This composes with the existing
`HYSTERESIS_PENALTY_S` (0.12 s) stickiness rather than replacing it. The strong-side
sign reuses the brain's hysteretic `strong_x` (`STRONG_SIDE_HYSTERESIS_M`).

### Residual edge (acceptable v1 behavior)

A human who picks C then freelances to the point: the brain still treats them as a forward
(their pick), bots hold D by their picks, and if the human abandons their spot the bots
don't auto-recover (no inference). That's fine and realistic — you picked C, play C.

## 2. New slot sets per possession state (5v5)

The 3v3 slot sets collapse to "one special role + N identical fill roles" — fine at N=2,
braindead at N=4. The 5v5 sets are position-tagged (F/D/ANY). Each state below lists its
slots **in election priority order** (earlier slots elect first, from their group;
leftover slots cross-fill last). Anchors are puck-relative, not static. The tactical
shapes are the researched NHL-standard systems (appendix); geometry uses the rink
constants (`GOAL_LINE_Z = 26.65`, `BLUE_LINE_Z = 7.29`, dots at x = ±6.71, slot depth
5.0, half-width 13.0). "Depth" below = metres from the goal line, into the zone.

| Possession state | 5v5 slots (tag) | System |
|---|---|---|
| **OZONE** | CARRIER + POINT_STRONG (D) + POINT_WEAK (D) + NET_FRONT (F) + HIGH_SLOT (F) | 3 F low / 2 D at the points |
| **FORECHECK** | F1_PRESSURE (F) + F2_STRONG (F) + F2_WEAK (F) + DP_STRONG (D) + DP_WEAK (D) | **1-2-2** |
| **DZONE** | ZONE_D_STRONG (D) + ZONE_D_WEAK (D) + ZONE_C (F) + ZONE_W_STRONG (F) + ZONE_W_WEAK (F) | hybrid zone, soft-lock (§3) |
| **BREAKOUT** | CARRIER + BREAKOUT_D2 (D) + BREAKOUT_STRONG (F) + BREAKOUT_C (F) + BREAKOUT_STRETCH (F) | 5-man breakout |
| **TRANS_OD** | CONTAIN (D) + MARK ×4 | D gap + backcheck through the middle |
| **TRANS_DO** | CARRIER + DVALVE (D) + WIDE_L (F) + WIDE_R (F) + TRAILER (ANY) | rush: wide lanes + trailer + valve |
| **NEUTRAL** | CHASE (ANY, global) + DBACK_L (D) + DBACK_R (D) + FLANK_L (F) + FLANK_R (F) | race + 1-2-2-ish shape |

Per-state specs (behavior module in parentheses; **bold = new code**, others reuse):

- **OZONE** — the standard even-strength 3-low/2-high. NET_FRONT (reuses `AIRoleFinisher`)
  is the crease-edge screen/backdoor man — FINISHER's argmax already lives in that space.
  HIGH_SLOT (**new decide in `AIRoleHighSlot`**, thin) is F3: floats the soft ice between
  the dots at depth ~8–10.7, stays **above the puck** (own-goal-side of it), is the
  one-timer seam option, and is the designated first man back — the same
  race-home-radius sag F3 uses in FORECHECK bounds how deep he sinks. POINT_STRONG /
  POINT_WEAK (**new, `AIRoleDefenseman`, §4**): strong-side point sinks down his wall
  toward the circle top (depth ~10.7–13) as the cycle goes low; weak-side point holds
  just inside the blue line shaded to middle — the researched staggered/diagonal point
  pair. Election: D group fills the points (strong = soonest-to-strong-point), F group
  fills NET_FRONT then HIGH_SLOT; a D **carrier** cross-fills his vacated point with the
  leftover F (the "F3 covers" half of the pinch rotation, emergent).

- **FORECHECK (1-2-2)** — F1_PRESSURE (reuses `AIRolePressure`) attacks the retrieval:
  pressure.gd's goal-side cutoff already angles inside-out (body between puck and
  mid-ice, steering the carrier wall-ward). F2_STRONG (**new-ish: `AIRoleForecheck`
  gains a lane parameter**) takes the strong-side wall lane at half-wall height (the
  first-pass outlet kill: hold ~x = strong wall, depth ~10–14 in their zone, deny the
  half-wall winger). F2_WEAK holds the middle lane at circle-tops-to-blue-line height —
  kills the center outlet and the cross-ice reverse; F2_STRONG/F2_WEAK re-sort when the
  puck changes sides (strong_x flip). DP_STRONG / DP_WEAK (`AIRoleDefenseman`): hold the
  offensive blue line **inside the dots** (|x| ≤ 6.7), tight gap, each bounded by the
  same race-home read F3 uses today (`race_home_radius`) so a stretch threat sags them
  out — the existing F3 pinch-safety logic generalized to a pair. No deliberate
  down-the-wall pinch in v1 (§ non-goals).

- **DZONE** — the researched hybrid ("man where the battles are, zone where speed
  kills"): five puck-relative **areas** with soft-lock man responsibility inside each.
  Full geometry in §3; behavior is one module (**new `AIRoleZoneDefense`**,
  parameterized by area role) + the shared evaluator (**new domain file
  `zone_coverage.gd`**, §5).

- **BREAKOUT** — D1-retrieves shape. The carrier (usually whoever got back first — in
  DZONE that's a D, so the retriever is naturally a D) breaks out; BREAKOUT_D2
  (reuses `AIRoleBreakout` weak-side valve) posts net-front/opposite post — the instant
  D-to-D "over" option, staying goal-side of the carrier; BREAKOUT_STRONG (reuses
  `AIRoleBreakout` strong) presents up the strong wall (its existing wall/mid-seam
  column argmax is exactly the half-wall winger job); BREAKOUT_C (**new decide**,
  small): the center's low swing — mirrors the puck side through the low slot, stays
  **below/level with the puck until the first pass is made** (chest open to the middle:
  its anchor hugs the mid-lane at the carrier's depth), then releases up the middle —
  the "second outlet" rule; BREAKOUT_STRETCH (reuses `AIRoleOutlet`): the weak-side
  winger's stretch option — OUTLET's paced-depth logic already climbs toward the far
  blue line at a pace the carrier's advance justifies and handles offside; from a deep
  breakout it hovers mid-NZ weak-side, which is the researched "cross or stretch" post.

- **TRANS_OD** — CONTAIN (reuses `AIRoleContain` verbatim — its gap-control ladder,
  blue-line stand, lane fan, and last-man-back election are already the researched
  behavior) is elected **within the D group** by soonest-to-our-net: the deepest D takes
  the carrier; MARK ×4 (reuses `AIRoleMark` + `AIThreatAssignment`): everyone else
  sprints home onto a distinct man via the existing value×reachability partition. The
  researched structure emerges: the weak-side D (deepest marker) draws the most
  dangerous man near our net via the house pin; the backchecking forwards inherit the
  trailer/wide lanes by reachability. The brute-force matcher's "≤ 3 backline" comment
  updates — at 4 defenders × 4 men it's ≤ 24 leaf orderings at 6 Hz, still trivial.

- **TRANS_DO** — the rush shape: WIDE_L / WIDE_R (**new thin decide, `AIRoleWide`**)
  drive the outside lanes (x ≈ ±(half-width − 4), paced to the carrier like OUTLET so
  they hit the line in stride, never offside); TRAILER (reuses `AIRoleSupport` — its
  weak-side-trail logic is the high-slot trailer job); DVALVE (`AIRoleDefenseman`): the
  safety valve — trails the play centrally ~one zone behind the carrier, capped by
  race-home (never beaten home), the D-to-D reset option. Election: DVALVE from D group
  (soonest home), WIDE from F group with L/R home-side bias, TRAILER cross-fills (the
  leftover D when the carrier is a forward — the activating D joining the rush as the
  fourth man; the leftover F when a D carries).

- **NEUTRAL** — CHASE (reuses chase; elected **globally**, any group): a loose puck is
  everyone's puck — at a faceoff the C is nearest and wins it naturally. FLANK_L/R
  (reuse) support the race from the sides. DBACK_L / DBACK_R (`AIRoleDefenseman`): the
  D pair holds the goal-side shape — staggered inside the dots between the puck and our
  blue line (the NZ 1-2-2's back wall). Cross-fill: if a D wins the race, a flank F
  drops into the vacated DBACK slot.

New `AIRoleSlots.Slot` enum members (5v5-only): `NET_FRONT`, `HIGH_SLOT`,
`POINT_STRONG`, `POINT_WEAK`, `F2_STRONG`, `F2_WEAK`, `DP_STRONG`, `DP_WEAK`,
`ZONE_D_STRONG`, `ZONE_D_WEAK`, `ZONE_C`, `ZONE_W_STRONG`, `ZONE_W_WEAK`,
`BREAKOUT_D2`, `BREAKOUT_C`, `BREAKOUT_STRETCH`, `WIDE_L`, `WIDE_R`, `TRAILER`,
`DVALVE`, `DBACK_L`, `DBACK_R`. The enum lives in `role_slots.gd` (additive, safe);
the 5v5 sets + group-scoped election live in a **new `role_slots_5v5.gd`
(`AIRoleSlots5`)** so the 3v3 file's logic is untouched. Cross-state hysteresis classes
extend for the 5v5 renames (e.g. BREAKOUT_STRONG→WIDE, POINT→DP→DBACK continuity for
the D pair) so possession flips don't reshuffle the pair.

## 3. D-zone: true zone with soft-lock

Pure zone that ignores men is a myth — the researched NHL default is **"man-on-man
below the dots, zone above"**: defenders own areas, lock onto the most dangerous man
*in* their area, and pass him off at the boundary instead of chasing. The model:

**The house is the threat mask.** The researched scoring-chance polygon: goal posts
(±0.92, depth 0) → end-zone dots (±6.71, depth ~6) → circle tops (±6.71, depth ~10.7),
closed across. Coverage doctrine: nobody stands uncovered in the house; outside it,
contain — don't chase.

**Five puck-relative areas** (functions of strong-side sign `s = strong_x` and puck
depth `d_p`; all breathing behavior slides with the puck rather than teleporting,
because anchors move continuously with `d_p` and the boundary tests use the live puck):

| Role | Area (owns men inside it) | Rest anchor (breathes with `d_p`) |
|---|---|---|
| ZONE_D_STRONG | strong half, depth < ~8 (corner + low boards + behind net) | the puck battle: at the puck when it's in-area; else low-slot strong edge (x ≈ 2s, depth ~3) |
| ZONE_D_WEAK | central band \|x\| ≤ ~3.5, depth < ~4.5 (net-front box) | net-front, x ≈ −s, depth ~2 (crease top edge, goal-side of the box-out man) |
| ZONE_C | central band \|x\| ≤ ~4.3, depth 4.5–9 (the slot) | mid-slot, x ≈ s·1.5, depth ~5.5; the seam-insurance man |
| ZONE_W_STRONG | strong half, depth 8–19.35 (wall + strong point) | strong wall lane, x ≈ 8.5s, depth ~9.5; extends up the shot lane when the puck is at the point |
| ZONE_W_WEAK | weak half, depth > ~4.5 + weak point | high-slot sag, x ≈ −4s, depth ~10 — loose on the weak point, first body on the backdoor seam |

- **Collapse** (puck below the goal line / corner, `d_p < ~2`): wingers sink — W_STRONG
  to the circle top (depth ~10.7), W_WEAK toward the high slot (depth ~8) — and ZONE_C
  tightens toward the low slot; 4–5 defenders end up below the circle tops, conceding
  the points. **Extend** (puck at the point, `d_p > ~10.7`): W_STRONG steps up his wall
  into the point man's **shot lane** (a fraction toward the puck along puck→net, the
  real technique — block the lane, don't body-chase); W_WEAK stays sagged. The anchors
  interpolate on `d_p` between these poses — the "breathing".
- **Two D = strong/weak, not fixed L/R.** The net-front is always covered by the
  far-side D; the puck-side D pressures the boards/corner battle. Rides the strong-side
  hysteresis; the D swap roles as the puck crosses, exactly the researched fluid switch.
- **Soft-lock man pickup.** Within its area, a defender picks up the most dangerous man
  (finish-danger read: `score_shoot` from the man's spot — same measurement the house
  pin uses) and covers him goal-side in the feed lane (`cover_man_target`), staying on
  him **until the man leaves the area** (+ ~1 m boundary hysteresis), then releasing to
  the breathing anchor. The release is keyed on the **area boundary**, not the man's
  speed — so a defender never chases his man out of his zone and leaves the slot open
  (the classic zone-defense bug). A man crossing a boundary is picked up by the
  neighbor whose area he enters; brief double-coverage at the seam is the real
  "pass him off" handshake, not a bug. ZONE_C's area overlaps the house core on
  purpose — the center claims seam-cutters ("too high for the D, too low for the
  winger"), the researched switch-insurance job.
- **Pressure trigger.** The puck (or its carrier) inside my area *is* the most dangerous
  man in it — the area owner pressures (reusing PRESSURE's goal-side approach), which
  reproduces "closest defender pressures, everyone else holds shape". Since areas are
  disjoint, exactly one defender presses at a time. (The researched eyes/numbers
  pressure-vs-contain read is deferred — PRESSURE's existing engage logic already
  modulates commitment via the body-check evaluator.)
- Implementation: the geometry (areas, anchors, membership tests, most-dangerous-man
  query) is the pure evaluator `zone_coverage.gd` (§5); `AIRoleZoneDefense.decide(ctx,
  role)` consumes it. The per-region man query replaces the team-global
  `AIThreatAssignment` partition in 5v5 DZONE (distinctness falls out of disjoint
  areas); TRANS_OD keeps the global partition.

## 4. New behavior: `defenseman.gd` (off-puck point play)

The one genuinely new behavior file — `AIRoleDefenseman`, serving four slots that are
all the same player-type doing the same philosophy at different game moments:

- **OZONE points** (POINT_STRONG / POINT_WEAK): hold the blue line; the strong point
  sinks toward the circle top as the cycle goes low, the weak point holds the line
  shaded central. "Walking the line" is a small lateral argmax (same
  candidate-set idiom every role uses) scoring: shooting-lane openness from the
  candidate (`lane_clear` toward the net) + pass-option value + **keep-in insurance**
  (never so central/deep that a cleared puck up his wall beats him — a race read
  against the nearest opponent, the same primitive as `race_home_radius`).
- **FORECHECK line-hold** (DP_STRONG / DP_WEAK): hold the offensive blue line inside
  the dots; sag down the NZ when the race home is no longer winnable (F3's existing
  bounded-hold logic, applied per-side).
- **TRANS_DO safety valve** (DVALVE): trail the rush centrally, ~a zone behind the
  carrier, always inside the race-home bound — the reset/D-to-D option and the first
  man back if the rush dies.
- **NEUTRAL back shape** (DBACK_L / DBACK_R): staggered goal-side pair inside the dots
  between puck and our blue line.

A **D-as-carrier in the O-zone is the same philosophy applied with the puck** — the
point-play envelope expressed through carry-candidate scoring (§6), not a separate
carrier brain: the transition-exposure term prices leaving the point, so the D carrier
walks the line and distributes instead of driving the net (unless the lane is truly
free — then he's allowed the activation, and his partner + HIGH_SLOT hold the fort,
which the exposure term also sees).

## 5. Zone-coverage evaluator

New grounded evaluator for DZONE (§3): `Scripts/domain/ai/zone_coverage.gd` — pure
static functions:

- `area_of(role, s, pos) -> bool` membership tests / `anchor_of(role, s, d_p) -> Vector3`
  breathing anchors (the §3 table);
- `most_dangerous_man_in_area(role, s, snapshot, ...) -> peer_id` — the soft-lock query:
  finish-danger (`score_shoot`) over opponents inside the area, with the boundary
  hysteresis for the incumbent;
- `defensive_anchor(group, side_sign, own_goal_dir) -> Vector3` — the shared
  **defensive-responsibility anchor** primitive: where this player's defensive post is
  (D → his point/blue-line side; F → the high slot / F3 post). Three consumers: the
  zone roles (§3), `AIRoleDefenseman`'s retreat bounds (§4), and the
  transition-exposure term (§6). One primitive, three consumers.

Built as a physical model (area responsibility + puck distance + race reads), not a
magic curve, per the grounded-models rule. GUT calibration tests pin: house men are
always covered across a sweep of puck positions; the strong/weak D swap on a cycle
crossing; wingers extend/collapse with puck depth; the soft-lock releases at the
boundary and the neighbor inherits.

## 6. Transition-exposure term (grounded ice-value primitive) — **5v5-gated for v1**

The carrier already prices getting caught: `AIActionScoring.turnover_cost` runs **per
carry/pass candidate** and is **self-localizing** — the cost is `loss_prob ×
threat_of_that_loss_point_to_our_net`, so an O-zone turnover is priced ~0 and an
own-zone one is priced huge, with no zone flag.

But it's keyed on **where the puck ends up** — and that's exactly why it *cannot* see
the D-caught-deep problem: a loss deep in their zone reads ~0 threat *at the loss
point*, while the true cost is the **counter-rush that develops** into the ice the
carrier vacated. Multiplying ~0 by an "amplifier" stays ~0, so the exposure term is an
**additive counter-attack cost**, not a scale on the local term:

### Design (the principled way — not a position gate, not a forked carrier)

For each candidate (carry destination / pass), alongside the existing local
`turnover_cost`, price the developing counter:

```
counter_cost = loss_prob × appetite × threat_surface_shoot(
        counter_point,            # where the counter-rush shoots from: our slot
        our_net, our_goalie,
        covering_defenders)       # ONLY the teammates who can beat the counter home
```

- `counter_point` — the attacking slot in front of **our** net (the researched rush
  destination), a fixed physical landmark.
- `t_counter` — time for the opponent nearest the loss point to reach it and carry to
  `counter_point` at his real speed cap (momentum-aware `time_to_arrive`, the same
  primitive every race read uses).
- `covering_defenders` — each teammate (and the carrier himself!) is included at his
  **defensive-responsibility anchor** (§5) iff his `time_to_arrive(anchor) ≤ t_counter`
  — i.e. only bodies that genuinely beat the rush home count as defense. A point D
  covering behind the play qualifies from the point; a winger cycling the corner does
  not. `threat_surface_shoot` then does what it always does: defenders in front of the
  net crush the threat, an empty slot reads near-breakaway.
- `appetite` — the **small per-position risk-aversion feel scalar** (legitimate
  hand-set knob, the "feel/tactical tunables" carve-out): how twitchy a D is vs. an
  activist-D coaching philosophy. The model does the *seeing*; the scalar sets the
  *appetite*.

### Why grounded, not `if is_defenseman`

Position is only a **prior**, not the true variable. The true variable is "how exposed
is the ice behind me if I lose it here," measured by who actually beats the counter
home. So this gives you, for free:

- A **caught-out forward** (deepest man / last back) plays conservative too — correct
  real hockey (F3 high), generalizes to a case we never tuned.
- **One-up-one-back D-pair emergent behavior**: if D2 holds the point, he beats any
  counter home → `covering_defenders` non-empty → D1's deep carry prices cheap and
  he's free to attack. If D2 also pinched, nobody covers → the counter reads as an
  open-slot look → D1's cost spikes and he holds the point — no pairing rule, no
  `if partner_pinched`. Falls out of the model.
- A **fast carrier is less exposed than a slow one** from the same spot — he covers
  himself. Speed attribute plugs straight in.

### Honest cost

It needs a genuinely **new perception input** — reading teammate positions relative to
the play to compute the back-cover set. Cheap (all in the snapshot, evaluated per
candidate at the AI dispatch cadence, not the 120 Hz path — and the covering-set test
is a handful of `time_to_arrive` calls against scratch arrays, no allocation), but it's
the first time carry scoring looks at *where its own teammates are*, so it gets a GUT
calibration test pinning the "one up, one back" behavior.

### v1 scope

**5v5-gated** via `RoleContext.team_size` (plus `RoleContext` gains the carrier's own
defensive anchor + group). It protects the already-shipping 3v3 tuning from a
carry-decision nudge. Follow-up (post-v1): consider **globalizing** it — it's correct
in 3v3 too (a caught rover concedes a rush), but that requires re-verifying 3v3 bot
feel. Tracked in §10.

## 7. Plumbing audit (the "easy" part, itemized)

No central team-size config today — `3` is implicit. A full trace of every consumer was
done against the codebase; the load-bearing items:

| Item | Change |
|---|---|
| Team size | `GameStateMachine.team_size ∈ {3,5}`, lobby-selected, latched by `apply_config` at `_spawn_world`, read via `GameManager.get_team_size()`; `NetworkManager.pending_team_size` + `pending_game_config["team_size"]` carry it pre-latch (exact `rule_set` rail: `notify_lobby_settings` / `notify_game_start` / `notify_join_in_progress` each gain a positional arg) |
| Wire format | **`PROTOCOL_VERSION` 30 → 31** (`build_info.gd`) — the three RPCs above change shape. `request_join` is untouched (slot allocation is host-side). `WorldStateCodec` needs **no** structural change (u8 count header, dictionary-keyed snapshots) |
| `LobbySlotKey` | **Stride must be the fixed capacity 5**, not the live team size — the lobby exists before the latch, and keys must be stable across a 3↔5 flip. Player keys become 0..9; spectator base 100 stays clear |
| Capacity constants | `PlayerRules.MAX_PER_TEAM` 3 → **5** (becomes *capacity*: array sizing, stride, bot windows); active-roster gates switch to the **latched size** (`game_manager.gd` join/promote gates, `game_state_machine.gd` `_first_available_slot` / `try_swap_slot`, `lobby_manager.gd` balance/swap gates). `GameRules.MAX_PLAYERS` 6 → 10 (`MAX_CONNECTIONS` → 14; Steam lobby cap fine) |
| Lobby | Team-size selector row in `LobbySettingsPanel` (host-gated, next to Rules); slot grid renders 2×5 and hides slots 3–4 in 3v3; display order `[3,1,0,2,4]`, labels/headers extended (away rows mirror L/R) |
| `team_slot` | Range {0,1,2} → {0–4}; label arrays in `slot_grid_panel.gd` / `scoreboard.gd` (and the matchup intro overlay reading them) extend to 5; `*3`/`<6`/`%3` stride literals in `slot_grid_panel.gd`, `lobby_manager.gd`, `game_manager.gd` switch to the capacity stride |
| Faceoff | `FACEOFF_OFFSETS` gains slots 3–4 per team: D behind the wingers (x ≈ ±2.4, ~7.0 back — behind the hash marks, staggered); `faceoff_position` clamps results inside the rink (an end-zone dot + defensive-D offset lands behind the goal line otherwise — clamp depth to ~1 m in front of the goal line). `BENCH_DOOR_SLOT_DZ` → 5 entries `[0.0, 2.4, −2.4, 4.8, −4.8]` |
| Bots | `BOT_ID_MAX` → BASE+9; `player_registry.gd` bot-id assert < 10; `game_manager.gd` bot spawn stride/window literals; `bot_identities.json` gains a **`position` field** (LD/RD/C/LW/RW) per identity (24 identities — plenty); `pick_for_slot` prefers an identity whose position matches the slot, falls back to any unused |
| `AIThreatAssignment` | No code cap — the "backline ≤ 3" note is a stale comment; update it (4×4 at 6 Hz is trivial) |
| Free play / drills | Offline free-play & drill config sites seed `team_size = 3` (unchanged feel); `reset()` restores the pending default |

## 8. Reuse ledger

- **Reuse as-is** (size-agnostic): `carrier.gd`, `pass_lead`, `shot_aim`, `steering`,
  `loose_puck_chase`, `body_check`, `action_scoring` EV models, `possession_state`,
  `contain.gd` (the D gap-control job, verbatim), `mark.gd` + `threat_assignment.gd`
  (TRANS_OD backcheck), `pressure.gd` (F1), `finisher.gd` (NET_FRONT), `support.gd`
  (TRAILER), `outlet.gd` (BREAKOUT_STRETCH), `breakout.gd` (strong wall + D2 valve),
  `chase.gd`/`flank.gd` (NEUTRAL).
- **3v3 role path**: reused **verbatim** behind the `team_size == 3` branch.
- **New files**: `role_slots_5v5.gd` (position-gated group election + 5v5 sets),
  `defenseman.gd` (§4), `zone_coverage.gd` (§5), `zone_defense.gd` (DZONE role),
  small decides for HIGH_SLOT / BREAKOUT_C / WIDE.
- **Heavy edit**: `role_slots.gd` (enum members + hysteresis classes only),
  `forecheck.gd` (lane parameter), carrier cost path (exposure term, §6), `team_brain.gd`
  (team_size + position map plumb-through), and the lobby/config/faceoff plumbing in §7.

## 9. Phasing

1. **Plumbing** — team-size latch rail, lobby selector, dynamic slot grid, capacity
   constants + stride, 5-man faceoff offsets + bench stagger, bot windows +
   `bot_identities` positions, PROTOCOL_VERSION bump. Proves 5v5 spawns and faceoffs
   correctly with the *3v3 role brain* (dumb but functional at 5).
2. **Position layer + slot sets** — `position_by_peer` into TeamBrain, F/D groups,
   `AIRoleSlots5` group-scoped election with home-side bias + cross-fill, the new 5v5
   slot sets mapped to existing behaviors (points/zone roles temporarily anchor-follow).
   The tactical skeleton.
3. **New brains** — `defenseman.gd`, `zone_coverage.gd` + `zone_defense.gd`, the small
   new decides, and the transition-exposure term. All share the
   defensive-responsibility-anchor geometry.
4. **Tune + calibrate** — spacing, forecheck lanes, zone collapse behavior, GUT
   calibration tests (incl. the "one up, one back" pin and the zone-coverage sweeps).

Each phase is shippable/testable on its own; 3v3 is untouched throughout.

## 10. Open details & follow-ups

- **Deliberate D pinch + eyes/numbers pressure read** (post-v1): the pinch-initiation
  ("keep the cycle alive down the wall, only with support behind") and the researched
  pressure-vs-contain trigger; v1 ships the cover rotation (emergent) without the
  aggressive halves.
- **3-on-3 OT for 5v5 matches** (post-v1): needs mid-game roster reduction machinery.
- **Positional faceoff variants** (post-v1): real O-zone vs D-zone draw alignments
  differ (net-side D behind the C on defensive draws); v1 uses one dot-relative offset
  table like 3v3.
- **Globalize transition-exposure** (post-v1): apply the exposure term to 3v3 too, with
  a 3v3 bot-feel re-verification pass. Deferred to protect shipping 3v3.
- **Positional inference for humans** (post-v1 polish): infer a human's position from
  where they skate so bots reshape around it. Deferred — explicit lobby picks are
  simpler and robust for v1.

## Decisions banked

- 5v5 is **additive**, lobby-selected, coexists with 3v3. Team size latched at drop.
- 3v3 role path **reused verbatim** (regression-safe); AI branches on `team_size` at one seam.
- **Explicit lobby positions** (LD/LW/C/RW/RD = team_slot 3/1/0/2/4) for humans and
  bots — no flex, no inference.
- Positions gate a **group-scoped kinematic election** with cross-fill; **strong/weak
  emergent**; L/R = home-side election bias (`POSITION_BIAS_S`).
- D-zone = **hybrid zone with soft-lock** (release on area boundary; house = threat mask).
- Transition-exposure = grounded **additive counter-rush cost** (back-cover set at the
  defensive anchors) × per-position feel scalar, **5v5-gated for v1**.
- OT stays 5v5; no line changes; no stamina rebalance (v1).

---

## Appendix — real-hockey tactics reference (research, condensed)

Sourced from NHL coaching material (The Coaches Site, Ice Hockey Systems, Weiss Tech,
USA Hockey, HockeyShare, Hockey Canada, Jack Han's Hockey Tactics, team-systems
breakdowns). NHL rink numbers transfer 1:1 to this rink (60 × 26 m, same landmark
geometry). Full source URLs live with the research notes in the PR description.

### D-zone coverage (drives §3)
- Modern NHL default is a **hybrid**: man-on-man below the dots (≤ ~6 m depth), zone
  principles above. Nobody plays pure zone or pure man.
- Canonical five: strong-side D on the puck battle; weak-side D net-front (never chases
  behind the net; the pair switches fluidly); center = third defenseman, low support +
  seam insurance ("too high for the D, too low for the winger"); strong winger covers
  wall/point with low-help duty; weak winger owns the whole weak side, sagged into the
  high slot ("the sole defence against backdoor play").
- **The house**: posts → dots → circle tops; deny the inside, contain outside.
- **Collapse** when the puck goes below the goal line (4–5 skaters below the circle
  tops); **extend** when it goes to the point (strong winger fronts the shot lane; a
  winger who collapses to the goal line leaves the points open — the classic error).
- Pressure trigger: "see his eyes → contain; see his numbers or a bobble → pressure."
- Net-front D: goal-side inside position at the crease top edge (~1.8–2.5 m off the
  goal line), control the stick, don't wrestle; never chase behind the net.
- Switching: pass men off at area boundaries; never chase up the wall; the winger goes
  man-on-man only with an *activating* point D.

### Forecheck (drives §2 FORECHECK)
- **1-2-2** is the modern NHL default. F1 "the dog": arc inside-out, take away D-to-D,
  steer the carrier up a wall — his job is *dictating the side*, not the turnover. F2
  shades the steered wall at half-wall/hash height (kills the first outlet); F3 holds
  the middle lane at circle-tops-to-blue height; they re-sort when the puck crosses.
  The two D hold the offensive blue line inside the dots; strong-side D pinches on
  rims/chips only when the receiver's back is turned (and F3 fills) — never both D.
- Angling mechanics: arc, aim the back shoulder, match speed, stick on puck in the
  inside lane, give the outside.

### Rush defense / gap control (validates CONTAIN + drives DVALVE/DBACK)
- Gap ladder: ~3 stick lengths at the offensive blue → 2 at the red line → 1 stick /
  contact at the defensive blue ("stand up at the line, stay inside the dots").
- Strong-side D takes the carrier; weak-side D holds mid-ice (the mid-lane drive is
  "fed to D2"); first backchecker tracks **through the middle**, takes the trailer.
- Backpressure doctrine: a backchecker within ~1–2 s of the carrier lets the D tighten
  the gap and stand up; without it, default conservative (concede entry, steer wide).

### Breakout (drives §2 BREAKOUT)
- D1 retrieves (shoulder checks); D2 nets-front/opposite post (the "over" option + a
  pick for the wheel); strong winger on the half-wall (hash marks to mid-zone), back to
  the boards; **center swings low mirroring the puck side, chest to the middle, stays
  below the puck until the first pass** — the second outlet; weak winger = mid-ice
  cross or stretch.
- Options ↔ reads: **Up** (F1 takes away the net side), **Over** (F1 floods strong
  side), **Wheel** (D1 has speed, F1 trailing), **Reverse** (F1 on his tail),
  **Rim** (two forecheckers deep). Called before first touch; first pass ≤ ~3 s.
- Stretch: weak winger leaves early against passive forechecks/pinching D; cost is the
  lost low outlet.

### O-zone structure (drives §2 OZONE + §4)
- Even strength = **3 low / 2 high** (the umbrella/1-3-1 is a power-play shape).
- Points staggered: strong-side D sinks toward the circle top on his wall (~6–8 m off
  the boards, above the dot lane); weak-side D holds the line shaded central.
- Point play: **walk the line** to open shot/seam/return lanes; D-to-D swings the
  attack; **pinch only with support; "D pinches, F3 fills"** is the standard exchange.
- **F3 high**: above the puck always, high slot between the dots (~8–10.7 m), one-timer
  seam option, first man back — "keeps the puck and all four teammates in front of him."
- Net-front: crease top edge, on the puck→goalie sightline, re-shading laterally as the
  puck moves; the "bumper" soft ice between the dots is where F3 floats at 5v5.

### Faceoffs (drives §7 offsets)
- Only centers inside the circle; everyone else outside behind the hash marks. Wingers
  at the circle edge level with the dot; D behind them — on O-zone draws at the blue
  line (one over the dot lane, one central for the one-timer), on D-zone draws
  net-side (retriever behind the C). v1 uses one dot-relative table (§10).
