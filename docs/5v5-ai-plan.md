# 5v5 AI — Design Plan

Status: **design agreed, pre-implementation.** This is the handoff document per the
CLAUDE.md workflow ("design complex AI features first, then implement against the
codebase"). Everything below is the banked design; deviating from it means asking first.

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

## Guiding constraint: additive, mode-latched

Team size is a **match config latched at puck drop**, exactly like online-ness and
ruleset (`ARCADE`/`NHL`/`OFF`) are today. Concretely:

- A `MatchConfig.team_size ∈ {3, 5}` value, chosen in the lobby, frozen at drop.
- The AI role layer **branches** on team size at one explicit seam:
  - `AIRoleSlots.slots_for_state(state, team_size)`
  - `AIRoleSlots.assign(..., team_size)`
  - `TeamBrain` carries `team_size` and passes it through.
- `team_size == 3` → the **existing** slot arrays + election, unchanged.
- `team_size == 5` → the new position-aware path (§3–§6).

Everything **below** the role layer is shared and size-agnostic — `carrier.gd`,
`steering.gd`, `action_scoring.gd`'s EV models, `pass_lead`, `shot_aim`,
`loose_puck_chase`, `body_check`. They never counted bodies and won't start.

```
MatchConfig.team_size (latched at drop)
        │
        ▼
   TeamBrain (per team, carries team_size)
        │
        ▼
   AIRoleSlots.slots_for_state(state, team_size) ──┬── 3 → legacy arrays (UNTOUCHED)
   AIRoleSlots.assign(..., team_size)              └── 5 → position-aware path (NEW)
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
for this already exists — it's just decorative today.

### What exists today (and is decorative)

- The lobby slot grid is C/LW/RW (`slot_grid_panel.gd`: slot 0 = Center, 1 = LW, 2 = RW).
- `PlayerRecord.team_slot ∈ {0,1,2}` is that index.
- But that label currently drives **only faceoff alignment and column layout**
  (`team_slot → PlayerRules.faceoff_position`). It does **not** feed the TeamBrain at all.

### What 5v5 adds

- Promote the lobby position from a cosmetic label into a **real gameplay input**, and
  add **LD** and **RD**. Full 5v5 lineup: **LD, LW, C, RW, RD**.
- Position → group mapping: **{LD, RD} = D group, {C, LW, RW} = F group.**
- The kinematic soonest-to-arrive election runs **within each group**: the 2 D compete
  for the 2 D-roles; the 3 F compete for the 3 F-roles. Same election machinery, scoped.
- Positions are explicit lobby picks for **humans and bots alike** — not inferred, not
  flex. A human picks their spot like everyone else; bots fill the unselected slots. The
  slot grid guarantees 5 filled slots per team, so no position is ever uncovered.

### Strong/weak falls out for free

Because the 2 D compete for the 2 D-roles by live positioning, **strong/weak is
emergent**: whichever D is currently on the strong side wins the strong-side-D role, the
other fronts the net. No hard `LD → strong` tag needed. Same for the forwards' 3 roles.

### L/R as a home-side rest bias (not a discarded tag)

Real D hold their side and only exchange on puck movement. So the L/R label survives the
lobby as a **home-side hysteresis prior**: LD defaults left, RD right when play is
settled, but the *live* strong/weak assignment is kinematic and swaps them on a cross-ice
play. This reuses the strong-side hysteresis TeamBrain already computes
(`STRONG_SIDE_HYSTERESIS_M`). Symmetric for forwards — C/LW/RW bias the rest state, but
the 3 F-roles are assigned by live position within the F group.

### Residual edge (acceptable v1 behavior)

A human who picks C then freelances to the point: the brain still treats them as a forward
(their pick), bots hold D by their picks, and if the human abandons their spot the bots
don't auto-recover (no inference). That's fine and realistic — you picked C, play C.

## 2. New slot sets per possession state (5v5)

The 3v3 slot sets collapse to "one special role + N identical fill roles" — fine at N=2,
braindead at N=4. The 5v5 sets are position-tagged (F/D). Anchors are puck-relative, not
static (see §3 for the D-zone breathing model).

| Possession state | 5v5 slots (F = forward group, D = defense group) |
|---|---|
| **OZONE** (we possess, their end) | CARRIER + NET_FRONT (F) + HIGH_SLOT (F, the trailer / "third forward") + POINT_L (D) + POINT_R (D) |
| **FORECHECK** (opp possesses, their end) — **1-2-2** | F1_PRESSURE (F) + F2_STRONG (F) + F2_WEAK (F) + DP_L (D) + DP_R (D) holding the line |
| **DZONE** (opp possesses, our end) — **true zone, soft-lock** | 2 D own the net-front box + 3 F own strong-wall / high-slot / weak-side; pick up whoever enters your area (§3) |
| **BREAKOUT** (we possess, our end) | CARRIER (usu. D) + D2 reverse/net-front + winger strong-wall + center low swing + winger stretch |
| **TRANS_OD** (opp possesses, NZ) | D-pair gap control (2 back) + 3 F backcheck through the middle |
| **TRANS_DO** (we possess, NZ) | CARRIER + wingers wide + HIGH_SLOT trailer + D as safety valve |
| **NEUTRAL** (loose, no possession) | chase + shape (extend existing chase/flank logic to 5) |

The **"third forward on offense"** question resolves to the **HIGH_SLOT trailer** in
OZONE, with the two D at the points doing the cycle-anchor + retreat-safety job that 3v3
literally cannot staff.

New `AIRoleSlots.Slot` enum members (5v5-only): `NET_FRONT`, `HIGH_SLOT`, `POINT_L`,
`POINT_R`, `F2_STRONG`, `F2_WEAK`, `DP_L`, `DP_R`, plus zone-coverage roles for DZONE.
`slots_for_state` / `assign` branch on `team_size` to select legacy vs. these.

## 3. D-zone: true zone with soft-lock

Pure zone that ignores men is a myth — NHL zone is "zone with man responsibility *in your
area*." The model:

- **Puck-relative formation, not static cells.** Each of the 5 zone roles gets an anchor
  computed from `(strong-side sign, puck depth, own net)`. The structure slides with the
  puck and **breathes**: each anchor's radius-from-net scales with the puck's
  distance/threat — collapse tight as the puck goes below the goal line / into the corner,
  expand to the points as it goes high.
- **Two D = strong/weak, not fixed L/R.** The net-front is always covered by the *far-side*
  D; the puck-side D pressures the boards/corner battle. Rides the strong-side hysteresis.
- **Soft-lock man pickup.** Within its area, a defender picks up the most dangerous man and
  stays on him **until the man leaves the area**, then releases to the anchor. The release
  is keyed on the **area boundary**, not the man's speed — so a defender never chases his
  man out of his zone and leaves the slot open (the classic zone-defense bug).
- The leftover man-matcher machinery from `AIThreatAssignment` is **reused** here as the
  "who's the dangerous man *in my area*" picker, scoped per-region instead of team-global.

Geometry reference (real rink numbers): half-width **13 m**, half-length **30 m**, our
goal line at |z| = **26.65**, blue line **7.29**, end-zone faceoff dots x = **±6.71**,
slot depth **5.0** off the net, corner radius **8.4 m**. The D-zone we're carving is the
~19 m from goal line to blue line.

**Open detail for implementation** (Phase 3): the exact zone-cell geometry — how the 5
responsibility areas are drawn as functions of `(strong-side, puck depth)` and the precise
collapse curve. Agreed in principle (puck-relative + breathing); the numbers get pinned
against a GUT calibration test.

## 4. New behavior: `defenseman.gd` (off-puck point play)

The one genuinely new behavior file. The point/D-pair job doesn't exist in 3v3:

- Hold the blue line; walk for a shooting/passing lane.
- Point shot.
- Gap control on the rush (stay goal-side, controlled gap, never lunge).
- First man back on a turnover.

A **D-as-carrier in the O-zone is the same philosophy applied with the puck** — the
point-play envelope expressed through carry-candidate scoring (§6), not a separate carrier
brain.

## 5. Zone-coverage evaluator

New grounded evaluator for DZONE (§3): assigns each defender an ice-area responsibility
and the soft-lock pickup within it, plus the collapse-toward-net logic. Shares the
"defensive-responsibility anchor" geometry with §4 and §6 — **one primitive, three
consumers**. Built as a physical model (area responsibility + puck distance), not a magic
curve, per the grounded-models rule.

## 6. Transition-exposure term (grounded ice-value primitive) — **5v5-gated for v1**

The carrier already prices getting caught: `AIActionScoring.turnover_cost`
(`action_scoring.gd:2160`) runs **per carry candidate** and is **self-localizing** — the
cost is `loss_prob × threat_of_that_loss_point_to_our_net`, so an O-zone turnover is
priced ~0 and an own-zone one is priced huge, with no zone flag.

But it's keyed on **where the puck ends up**, so it can't yet tell a deep F from a deep D:
for both, a lost puck deep in the O-zone is far from our net → ~0. What it's missing is
that a **D** getting caught deep vacates the point and creates the odd-man rush — a
**transition-exposure** cost that's a function of *how far the carrier is from his
defensive responsibility* and *whether anyone is covering behind him*, not of where the
puck dies.

### Design (the principled way — not a position gate, not a forked carrier)

- Add a **transition-exposure amplifier** feeding `turnover_cost`: the counter-attack
  value of a loss is amplified by how out-of-position the carrier is — distance from his
  defensive-responsibility anchor × a **back-cover deficit** (teammates behind the play).
  Same candidate loop, same function, one richer input.
- Multiply by a **small per-position risk-aversion feel scalar** — this part *is* a
  legitimate hand-set knob (the "feel/tactical tunables" carve-out): how twitchy a D is vs.
  an activist-D coaching philosophy. The model does the *seeing*; the scalar sets the
  *appetite*.

### Why grounded, not `if is_defenseman`

Position is only a **prior**, not the true variable. The true variable is "how exposed is
the ice behind me if I lose it here." So this gives you, for free:

- A **caught-out forward** (deepest man / last back) plays conservative too — correct
  real hockey (F3 high), generalizes to a case we never tuned.
- **One-up-one-back D-pair emergent behavior**: because the term reads who's behind the
  play, if D1 jumps into the cycle, D2's own exposure cost spikes and he holds the point —
  no pairing rule, no `if partner_pinched`. Falls out of the model.

### Honest cost

It needs a genuinely **new perception input** — reading teammate positions relative to the
play to compute the back-cover deficit. Cheap (all in the snapshot, 6 Hz brain-tick, not
the 120 Hz path), but it's the first time carry scoring looks at *where its own teammates
are*, so it gets a GUT calibration test pinning the "one up, one back" behavior.

### v1 scope

**5v5-gated.** It rides the same `team_size` branch the rest of the exposure geometry
needs, and it protects the already-shipping 3v3 tuning from a carry-decision nudge.
Follow-up (post-v1): consider **globalizing** it — it's correct in 3v3 too (a caught rover
concedes a rush), but that requires re-verifying 3v3 bot feel. Tracked in §10.

## 7. Plumbing audit (the "easy" part, itemized)

No central `SKATERS_PER_TEAM` today — `3` is implicit. Making team size real config is
Phase 1 and is now genuinely user-facing:

| Item | Change |
|---|---|
| Team size | New `MatchConfig.team_size ∈ {3,5}`, lobby-selected, latched at drop |
| Lobby | Mode selector (3v3 / 5v5) |
| Slot grid | 2×3 → dynamic 2×3 **or** 2×5 (`slot_grid_panel.gd`); lineup row LD–LW–C–RW–RD |
| `team_slot` | Range {0,1,2} → {0–4} (`PlayerRecord`, everywhere it's assumed 0–2) |
| Positions | Promote lobby position → gameplay input; add LD/RD; F/D group mapping |
| Faceoff | `FACEOFF_OFFSETS` needs a **5-man** alignment table (currently 3-per-team) |
| `bot_identities.json` | Add a `position` field (LD/RD/C/LW/RW) per identity; ensure ≥10 usable for a full 5v5 bot game |
| `AIThreatAssignment` | Generalize the brute-force past "backline ≤ 3" (used by TRANS_OD man-marking at up to 4; 4! = 24 perms, trivial at 6 Hz) |
| Spawn loops | Any `for i in 3` skater-spawn assumption → `team_size` |

## 8. Reuse ledger

- **Reuse as-is** (size-agnostic): `carrier.gd`, `pass_lead`, `shot_aim`, `steering`,
  `loose_puck_chase`, `body_check`, `action_scoring` EV models, `possession_state`.
- **3v3 role path**: reused **verbatim** behind the `team_size == 3` branch.
- **New / heavy edit**: `role_slots` (size-branched sets + position-gated election),
  `defenseman.gd` (new), zone-coverage evaluator (new), `threat_assignment`
  (generalize past 3), `turnover_cost` (exposure term), and the lobby/config/faceoff
  plumbing in §7.

## 9. Phasing

1. **Plumbing** — `MatchConfig.team_size`, lobby mode selector, dynamic slot grid,
   `team_slot` 0–4, 5-man faceoff offsets, `bot_identities` position field. Proves 5v5
   spawns and faceoffs correctly with dumb (kinematic-only) roles.
2. **Position layer + slot sets** — promote lobby position → brain input, F/D groups,
   group-scoped election, the new 5v5 slot sets. The tactical skeleton.
3. **New brains** — `defenseman.gd`, the zone-coverage soft-lock evaluator, and the
   transition-exposure term. All share the defensive-responsibility-anchor geometry.
4. **Tune + calibrate** — spacing, forecheck triggers, zone collapse curve, GUT
   calibration tests (incl. the "one up, one back" pin).

Each phase is shippable/testable on its own; 3v3 is untouched throughout.

## 10. Open details & follow-ups

- **Zone-cell geometry** (Phase 3): exact area functions of `(strong-side, puck depth)`
  and the collapse curve. Principle agreed (puck-relative + breathing); numbers pinned
  against a calibration test.
- **Globalize transition-exposure** (post-v1): apply the exposure term to 3v3 too, with a
  3v3 bot-feel re-verification pass. Deferred to protect shipping 3v3.
- **Positional inference for humans** (post-v1 polish): infer a human's position from where
  they skate so bots reshape around it. Deferred — explicit lobby picks are simpler and
  robust for v1.

## Decisions banked

- 5v5 is **additive**, lobby-selected, coexists with 3v3. Team size latched at drop.
- 3v3 role path **reused verbatim** (regression-safe); AI branches on `team_size` at one seam.
- **Explicit lobby positions** (LD/LW/C/RW/RD) for humans and bots — no flex, no inference.
- Positions gate a **group-scoped kinematic election**; **strong/weak emergent**; L/R = home-side bias.
- D-zone = **true zone with soft-lock** (release on area boundary).
- Transition-exposure = grounded `turnover_cost` amplifier × per-position feel scalar,
  **5v5-gated for v1**.
