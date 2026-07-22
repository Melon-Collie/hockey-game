# Phase 2 spec: goalie collision prototype (the real determinism risk)

Status: **spec, ready to build.** Phase 2 of the deterministic-puck migration
(`netcode-determinism-migration.md`). Phase 0 proved the analytic puck matches Jolt on
boards + rim-arounds (GO — see `netcode-phase0-shadow-puck-spec.md`). This addresses
the one piece with **no existing analytic model and the only genuine unknown**: the
puck bouncing off the *moving* goalie. If this works, the puck can be fully
deterministic; if it doesn't, the fallback (a hybrid) is still a big win.

## Why the goalie is the hard part — and why it's more tractable than feared

Board collision is disc-vs-*static* geometry. Goalie collision is disc-vs-**moving
oriented boxes**: the pads/glove/blocker/stick reposition every frame as the goalie
poses (butterfly, glove reach, RVH, stick lunge). That's the collision the audit
flagged as the migration's real risk.

But the geometry check is encouraging: **every goalie collision part is a `BoxShape3D`**
(`Scenes/Goalie.tscn`). No capsules, no convex meshes. So the whole problem is
swept-disc-vs-N-oriented-boxes (OBBs) — a standard, well-understood analytic test — and
the box transforms are already computed (they're the posed `StaticBody3D` children the
goalie controller drives). We don't have to reverse-engineer Jolt; we have to reproduce
disc-vs-OBB contact for boxes whose transforms we already know.

The collision parts (~9 OBBs):

| Part | Node | Layer |
|---|---|---|
| Left pad, Right pad | `LeftPad`, `RightPad` | `LAYER_WALLS` |
| Body, Head | `Body`, `Head` | `LAYER_WALLS` |
| Glove | `Glove` | `LAYER_WALLS` |
| Stick shaft / paddle / blade | `BlockArm/Stick/*Collider` | `LAYER_GOALIE_STICK` |
| Blocker | `BlockArm/Blocker/BlockerPadCollider` | `LAYER_GOALIE_STICK`-ish |

Each is a `CollisionShape3D` with a `BoxShape3D`: world transform = the shape's
`global_transform` (driven by the pose), half-extents = `BoxShape3D.size × 0.5`, plus
the per-surface restitution material (`goalie_pad` 0.2, `goalie_stick` 0.4).

**The response is already analytic.** `GoalieSaveRules` (deaden / steer / rebound) and
the save-deaden path already decide what happens *after* a goalie contact — the current
code only uses Jolt to *detect* the contact (`puck_touched_goalie` from
`Puck._on_body_entered`). So Phase 2 only has to reproduce the **detection + contact
normal**; the outcome logic is done.

## The question Phase 2 answers

*Can an analytic swept-disc-vs-goalie-OBBs test detect the same contacts Jolt does —
same part, same normal, same tick (±1) — closely enough that the (already analytic)
save response plays identically?*

- **GO:** high detection agreement + matching part + matching normal → the deterministic
  puck handles the goalie → the puck is fully deterministic (RL-family everywhere).
- **NO-GO / partial → hybrid (still a big win, see below).**

## The approach: a shadow detector, mirroring Phase 0

Run an analytic goalie-collision detector each tick alongside Jolt and compare, never
changing behavior:

1. **Gather** the goalie's ~9 OBBs each tick (world transform + half-extents from the
   posed `CollisionShape3D` nodes).
2. **Test** the swept puck disc (`prev → curr`, radius `PUCK_COLLISION_RADIUS`) against
   each OBB (closest-point-on-OBB to the swept segment, within radius) → nearest
   contact: which box, contact point, surface normal, penetration.
3. **Compare** to Jolt's authoritative `puck_touched_goalie` (+ the contact body/normal
   the current path already extracts):
   - **Detection agreement** — when Jolt reports a goalie contact, did the analytic test
     also fire within ±N ticks? And the converse: analytic-fired-but-Jolt-didn't
     (false positives).
   - **Part match** — same box (a pad vs the stick vs the blocker).
   - **Normal-angle error** — angle between the analytic contact normal and Jolt's (the
     rebound direction depends on it).
   - **Timing offset** — ticks between the two detections.

Same rails as `PuckShadowComparator`: dev + host only (`BuildInfo.VERSION == "dev"`),
log a digest on a throttle, never drive the real puck.

**Both directions are now instrumented** (`GoalieCollisionShadow`):
- `record_contact()` — REACTIVE, on Jolt's `puck_touched_goalie`: catch-rate, part-match,
  normal-sanity per real contact (the `jolt=/caught=/part_match=/normal_sane=` digest).
- `probe()` — PROACTIVE, every host tick the loose puck is within `_GOALIE_PROBE_RANGE_M`
  of a goalie: counts **false positives** (analytic fires, Jolt didn't). Ground truth for
  the tick is Jolt's entry signal **OR** continuous overlap (`get_colliding_bodies()`) —
  combining both is what stops a puck legitimately settling on the pads (which fires no
  fresh `body_entered`) from being miscounted as a phantom (the `probe=/hit=/phantom=`
  digest). This closes the false-positive metric the go/no-go needs.

## Metrics & go/no-go

- **Detection agreement** ≥ ~95% of Jolt's goalie contacts caught analytically, with a
  low false-positive rate → GO on detection.
- **Part-match** ≥ ~90% (the wrong box means the wrong restitution/normal).
- **Normal-angle error** < ~10° (the rebound goes the same way; the save response is
  forgiving because it re-steers, but a wildly wrong normal would send rebounds into the
  slot).
- **Timing** within ±1–2 ticks (a sub-tick contact instant, absorbed by reconcile like
  the board bounces in Phase 0).

## The hard cases the prototype MUST exercise (this is where it fails if it fails)

- **Fast pose transitions** — a butterfly drop or glove snap moves the boxes several cm
  *within* a tick; the swept test uses tick-boundary transforms, so a contact mid-drop
  is the worst case for timing/part agreement.
- **Overlapping boxes** — pad + stick + blocker cluster low in the butterfly; Jolt picks
  one contact, the analytic test must pick the *same* one (nearest / first-hit along the
  sweep).
- **Glancing vs square** — a glance off the pad shoulder vs a square blocker hit; the
  normal error is largest on glances off a box edge/corner.
- **Both bodies moving** — the puck and the box both move during the tick; a first pass
  uses the box's end-of-tick transform, and the prototype measures whether that's close
  enough or whether sub-stepping the box is needed.

## The hybrid fallback — NO-GO here does NOT kill the migration

If moving-box detection can't be matched tightly enough, the puck can be
**deterministic everywhere except a bounded region around the goalie**, where it defers
to Jolt (keep the goalie crease on the current Jolt + `puck_touched_goalie` +
`GoalieSaveRules` path, and hand the puck between the analytic sim and Jolt at the
region boundary). The crease is a small fraction of the ice; open-ice + boards (proven
GO) is where the puck spends almost all its time. So a hybrid still delivers: the
rim-around fix, the client-predicted open-ice puck, and most of the netcode
simplification. The prototype's job is to tell us **whether we need the hybrid or can go
fully deterministic** — either outcome is a shippable win, which is why the migration is
low-risk overall.

## Scope (narrow, like Phase 0)

**In:** detection + normal agreement for the loose puck vs the goalie OBBs, measured
against Jolt. Grounded and airborne both (a puck can hit a raised glove).

**Out (this prototype):** replacing the response (the save logic is already analytic —
wire it only after detection is proven), and the goalie *stick* poke of a carried puck
(a separate, already-analytic path).

## Implementation sketch

- **`SweptDiscOBB.contact(prev, curr, radius, box_transform, half_extents, result)`** —
  a pure domain rule (closest-point-on-OBB to the swept segment; contact point, normal,
  depth). Unit-testable in isolation (hit/miss, normal on each face, glance off an edge).
- **`GoalieCollisionShadow`** — gathers the goalie's OBBs each tick (references resolved
  by node path under the Goalie), runs `SweptDiscOBB` against each, keeps the nearest,
  and accumulates the agreement/part/normal/timing stats vs the `puck_touched_goalie`
  signal. Dev + host only; logs a digest. Never drives the puck.
- Wire it beside the Phase-0 harness in `PuckController` (host tick), gated the same way.

## Effort & sequence

Bigger than Phase 0 (which reused an existing sim) but bounded: the swept-disc-vs-OBB
math is standard (~a day, pure + tested), the shadow detector + goalie-OBB gather +
comparison is ~a day, then a session of shooting at the goalie in varied poses
(standing, butterfly, glove/blocker/stick saves, RVH). The all-boxes geometry is the
best case for this kind of collision.

Do this **before** committing to Phase 1 (making the analytic sim the primary puck
path): it's the one result that decides *fully deterministic vs hybrid*, and that
decision shapes how Phase 1 is built. Everything else in the migration (gravity/loft,
pipes, net) is static-geometry or a Y-channel — easy additions in the Phase-0 mold.

## Deliverable

A short report from a goalie-shooting session: detection agreement %, part-match %,
normal-angle error distribution, timing offset, and the call — **fully deterministic**
(agreement high across all pose cases) or **hybrid** (defer the crease to Jolt) — plus,
if hybrid, where the region boundary should sit.
