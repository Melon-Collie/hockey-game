# Stickhandling push model — motion-keyed blade contact

Status: IMPLEMENTED (`CarryContactRules` + `Skater._update_carry_contact`),
pending on-ice tuning. Follows the contact-point tell (#596,
`docs/elevation-rework-plan.md` §6.3), which seated the carried puck heel→toe
by loft level and added a shaft-angle toe drag; this model subsumes that toe
drag. Deltas from the plan as written:

- The update lives in `Skater._physics_process`, not the IK call site — it
  runs identically on local, AI, and remote skaters (the IK pipeline never
  touches a client-rendered remote), which delivered §5's remote parity
  directly instead of via a separate feed. Consequence: remote views now
  reconstruct the full blade-beside-puck arrangement (the forehand factor is
  no longer 0 on remotes; a peer flipping a beat off the owner is absorbed by
  the factor smoothing).
- The transit lift became a sin-envelope hop fired per face flip (a flip
  during a live hop rides it out) — the "complete each hop" option from trap
  #2, replacing (1 − |smoothed factor|) outright.
- `carry_side_switch_threshold` (the position-hysteresis export) is retired;
  the flip-speed threshold is the hysteresis.

## 1. The defect in the current model

Everything about the carried contact is keyed off **position** — which side of
the body the cursor sits on. `Skater.update_carry_side` picks the rendered
face by body side with hysteresis and never flips within a side; the toe-drag
roll keys off shaft steepness, which is a proxy for "cursor near the feet."

Real stickhandling is keyed off **motion**: the blade contacts the puck on the
side *opposite* where the puck is going, because that is the side you push
from. To move the puck left you push from its right; to bring it down-left
you push from up-right. Dangling in place on one body side alternates faces
every stroke — the tick-tock texture — which a position-keyed side can never
produce. The current model conflates two distinct facts:

- **body side** = where the puck is (position) — governs ROM, reach, which
  strokes are anatomically available;
- **contact face** = which side of the puck the blade is on (motion) — governs
  what the blade is visibly doing.

Today both are driven by position. The fix is to key the contact face (and
the stroke dressing) off the puck's velocity **in the carrier's frame** —
dangle velocity, not world velocity; you stickhandle relative to yourself
while gliding.

## 2. The decomposition

Let `v_rel` = blade-contact velocity minus the skater's body velocity
(world XZ). Decompose at the blade against two axes that already exist in
`get_carry_target_global`:

- `stick_dir` — the horizontal hand→contact direction (≈ body-outward),
- `face_normal` — its 90° Y-rotation (the blade's face axis).

**Face-normal component** (`v_perp = v_rel · face_normal`) — the side-to-side
stroke. The blade sits on the trailing side: contact-face target =
`−sign(v_perp)`, with a speed deadband and velocity-space hysteresis. This
*replaces* the body-side key as the side driver (working decision — see §7).

**Inward component** (`v_in = −(v_rel · stick_dir)`, positive = pulled toward
the body) — and this is why toe drags exist at all: the blade's faces point
sideways off the stick line, so **no face points back at the carrier**. A flat
blade physically cannot push the puck toward the body. The only way to create
a pulling surface is to roll the wrists so the toe curve hooks over the far
side of the puck. Inward motion therefore *forces* toe contact + closed-face
roll; the model produces the toe drag as a consequence instead of bolting it
on.

## 3. Stroke grammar

Chirality picks which inward diagonal gets which dressing. For a lefty
(blade on −X, forehand = left side); mirror everything for a righty:

| stroke (lefty) | contact face | seat | wrists |
|---|---|---|---|
| push out / lateral, either side | trailing face, per `v_perp` | mid-blade (elevation seat untouched) | square |
| pull in from the forehand side (down/right) | forehand face rolled over | slides toward the toe | full roll — **the toe drag** |
| pull in from the backhand side (down/left) | backhand face | heel-to-mid | mild cup — the backhand cradle (a backhand can't roll to a forehand hook) |
| at rest / below deadband | hold last side | unchanged | cupped — the cradle |

Camera note: from the gameplay camera's ~75° tilt, roll about the blade's
long axis barely reads (that axis points near the viewer). What does read from
overhead is the toe visibly curling in around the puck. Implemented as an
**axial twist about the hosel line** — the axis a real wrist roll actually
has — which produces that horizontal toe sweep (~7 cm at 20°) as a
consequence AND keeps the hosel tip (the point the shaft aims at) invariant,
so no dressing can kink the shaft→blade junction. An earlier heel-local yaw
term did the same sweep but bent the junction; it's gone.

## 4. What is kept, what is reworked

**Kept as-is:**
- The pin is sacred: cursor = puck, `get_carry_target_global` stays the
  authority, no push physics, no independent puck motion during carry.
- The elevation seat (`carry_contact_flat_u/high_u`) — that is *intent*, not
  stroke; the heel→toe loft tell keeps working and composes with the stroke
  seat.
- The transit-lift mechanism (blade hops over the puck when the smoothed face
  factor crosses zero) — right mechanism, it just fires far more often once
  the side is motion-keyed.

**Reworked:**
- `update_carry_side` becomes the motion-keyed side tracker (deadband +
  velocity hysteresis instead of the position threshold).
- `get_toe_drag_factor` becomes the inward-pull grammar: composes the current
  positional read (shaft steep = stick tucked at the feet — still a legitimate
  drag posture) with the gestural read (`v_in` on the correct diagonal); all
  face-angle dressings ride one axial hosel-line twist (see §3 camera note).

**Where the code goes:** the stroke solver — (v_perp, v_in, current side,
handedness) → (face target, seat offset, twist) — is pure stateless math:
`domain/rules/` + GUT tests, per the project rule. `Skater` owns the smoothed
state and applies the solved targets; the IK coordinator feeds it, replacing
the `update_carry_side` call site.

## 5. Signal source and network posture

`Skater.blade_world_velocity` is already computed each tick on **every peer**
from the replicated (and, on remotes, interpolated) blade marker — so
`blade_world_velocity − skater.velocity` gives every machine the same `v_rel`
with **no new wire field**, the same posture as the contact-point tell. It is
one tick stale relative to the current tick's IK; irrelevant for a smoothed
cosmetic.

Reconcile: the side/seat state is cosmetic and replay-tolerant, exactly like
today's carry side — replay recomputes it from replayed blade motion; drift
across a snap is absorbed by the smoothing.

Hot path: value-type math only, a few floats of state on `Skater`, no
allocation — same budget as the code it replaces.

## 6. Traps (known going in)

1. **Deadband is the cradle, not an edge case.** Below the stroke threshold
   there is no motion to key off; hold the last side, cupped. Without a real
   deadband the side flips on interpolation noise at rest.
2. **Fast alternation vs the transit lift.** The lift peaks when the smoothed
   factor is mid-flip; under a fast dangle the factor lives near zero and the
   blade would hover permanently instead of hopping per stroke. Needs
   flip-rate awareness (scale lift by time-since-flip, or complete each hop
   before honoring the next flip).
3. **Rest-side feel changes.** Replacing the position key alters how the
   forehand/backhand carry reads when *not* stroking. Playtest checkpoint —
   the deadband cradle should preserve it, but that's a judgment call on ice.
4. **Blade marker vs mesh.** The face-side offset moves the blade *marker*
   (as today, ±`carry_blade_offset`); the twist dressing moves the *mesh
   only* — never the marker the contact math reads.

## 7. Open decisions

- **Replace vs compose** the body-side key: working decision is *replace*
  (body side keeps governing ROM/reach/dressing availability only). Revisit
  after the first on-ice pass if the rest carry feels wrong.
- Whether the elevation chevrons shrink/retire stays parked with the
  contact-point tell playtest (elevation plan §6.3).

## 7b. Wrister address (follow-up, implemented)

The freeze at LMB-down used to fossilize whatever carry side was live, so a
backhand-frozen pose could wind a forehand shot — the pose lied. During
WRISTER_AIM the controller now pushes the live aim line (`_wrister_aim_dir` —
origin→cursor for humans, the committed direction for bots) onto the skater
each tick, and the blade addresses the **trailing side of that line** — the
push model applied to the shot itself, decided by the same
`CarryContactRules.stroke_side` rule strokes use (aim·face_normal as the
stroke, `wrister_address_commit_dot` as the hysteresis so a near-parallel aim
holds instead of flickering). An address factor eases toward the committed
side and the delta to the live carry factor slides the blade **mesh** along
the face-normal axis (marker local +X), with the transit hop firing on the
crossing.

First cut keyed the side off the swing-chirality *label* mapped to the
body-relative carry arrangement — wrong whenever the label's natural pose
disagreed with where the aim line actually sat (the "wrong handedness on some
shots" report). Geometric trailing-side is handedness-free and cannot land on
the wrong side of the puck; the chirality classifier keeps its real job (the
release's backhand power penalty).

Mesh-only by design: the marker, pin, release spawn, and the pinned aim
origin are untouched (`wrister_origin_world` is load-bearing for the
gamepad's shot-cursor anchor and the chirality bearing, so it must not
move). On aim exit the address becomes the real carry side, so there is no
pop. Render-only remotes never receive the push and keep the frozen entry
pose rather than guessing (`_wrister_address_valid`).

## 8. What this buys

The blade side telegraphs the next stroke — a defender watching the carrier
sees the blade wind up on the side it is about to push from, before the puck
moves. Same deception axis as the contact-point tell: the read is real, and a
good dangler beats it by changing late. The whole blade becomes legible.

## 9. Tests

- GUT for the stroke solver: face target per quadrant of (v_perp, v_in) ×
  handedness, deadband hold, hysteresis (no flip-flop straddling the
  threshold), dressing clamps.
- Nothing mechanical beyond that — seat/twist are cosmetic; carry/release
  feel verified in a local session. The release-origin invariant (mid-blade,
  position-free trajectory) is untouched by construction.
