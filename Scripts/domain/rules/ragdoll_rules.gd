class_name RagdollRules

# Pure verlet ragdoll for the body-check knockdown, plus the math that maps its
# particles back onto the skater's procedural rig. No engine state — static
# methods over a plain particle container — so it unit-tests headless like the
# rest of domain/rules.
#
# WHY A SOLVER AND NOT A POSE: the pre-ragdoll crumple was a single scalar
# (kd_t = knockdown_timer / knockdown_getup_seconds) driving a fixed body drop
# plus limp legs, so every knockdown played the identical fall regardless of how
# or how hard the hit landed. Here the fall is seeded FROM the hit — direction,
# strength, and the skater's own velocity — so being clipped at 4 m/s and being
# blown up head-on at 9 produce genuinely different tumbles, on the same impulse
# continuum BodyCheckRules already uses to size the down time.
#
# WHY THIS IS ALLOWED TO EXIST (the rig is normally off-limits at this fidelity):
# SkaterPoseCoordinator._apply_lean documents that the blade markers hang under
# upper_body, so anything that rotates the torso moves the blade's WORLD position
# — gameplay geometry that must agree across machines for reconcile. That stops
# being true while the victim is down: is_knocked_down gates the skater out of
# every blade-based path (pickup election, provisional carry, contest scan, local
# prediction — see puck_controller), and collision is the CharacterBody3D capsule,
# not the mesh. So for the knockdown window the rig under MeshRoot has no gameplay
# consumer and is free to be simulated. The CharacterBody3D keeps sliding on
# knockdown_friction and never learns this exists.
#
# FRAME: simulated in a world-axis-aligned frame (Y up, ice at y = 0) so gravity
# and ice contact are trivial. The rig mapping reads only DIRECTIONS between
# particles plus the pelvis HEIGHT — never a horizontal position — so the
# particle cloud's horizontal drift away from the sliding CharacterBody3D is
# unobservable by construction. That is deliberate: the ragdoll owns the pose,
# the character body owns the position, and neither has to agree with the other.
#
# DETERMINISM: verlet with a fixed dt and a fixed constraint-iteration count is
# reproducible from its seed. Every seed input (hit direction, hit strength,
# body velocity) is replicated, so all peers — and goal replays, which re-drive
# cosmetics from recorded state — render the same fall with no per-frame sync.
# Peers can differ by centimetres where the seeded velocity differs by prediction
# error; that is invisible in a tumble and never changes its character.

# ── Particles ─────────────────────────────────────────────────────────────────
const HEAD: int = 0
const CHEST: int = 1
const PELVIS: int = 2
const KNEE_L: int = 3
const KNEE_R: int = 4
const SKATE_L: int = 5
const SKATE_R: int = 6
const PARTICLE_COUNT: int = 7

# Inverse masses. The pelvis is the heaviest link (it anchors the chain), the
# head the lightest, so constraint corrections push the extremities around the
# trunk rather than dragging the trunk after the head.
const _INV_MASS: Array[float] = [
	1.60,  # HEAD
	0.70,  # CHEST
	0.50,  # PELVIS
	1.20,  # KNEE_L
	1.20,  # KNEE_R
	1.45,  # SKATE_L
	1.45,  # SKATE_R
]


# ── Config ────────────────────────────────────────────────────────────────────
# Segment lengths are READ FROM THE LIVE RIG by the caller (see
# SkaterRagdollCoordinator.build_config) rather than hard-coded, because
# SkaterAppearanceCoordinator scales every leg pivot and upper-body part by the
# build's height multiplier. A 6'7" ragdoll built from 6'1" constants would
# visibly detach from its own mesh.
class Config:
	var neck_len: float = 0.25       # chest -> head
	var spine_len: float = 0.42      # pelvis -> chest
	var hip_half_width: float = 0.13 # pelvis -> hip joint, lateral
	var thigh_len: float = 0.31      # hip -> knee
	var shin_len: float = 0.41       # knee -> skate
	var stand_pelvis_y: float = 0.87 # pelvis height of the neutral standing rig

	# Solver. dt is fixed by the caller (the 120 Hz physics tick); iterations is
	# the Jakobsen relaxation count — 6 is stiff enough that limbs don't visibly
	# stretch without the chain going rigid.
	var iterations: int = 6
	var gravity: float = -9.81
	var linear_damping: float = 0.012   # per-step velocity retention loss
	var ice_friction: float = 0.16      # tangential velocity shed per ice contact
	var ice_restitution: float = 0.0    # bodies do not bounce on ice
	var particle_radius: float = 0.06   # keeps particles off the ice plane

	# Hit response. Contact height is a physical measurement — a shoulder check
	# lands at chest height — not a shape parameter; it is what converts a linear
	# shove into rotation about the planted skates, which is the whole reason a
	# hard hit puts someone over instead of just sliding them.
	var hit_speed: float = 6.5        # m/s imparted at strength 1
	var hit_lift: float = 2.2         # m/s upward at strength 1 (feet leave the ice)
	var hit_contact_height: float = 1.40  # world Y the check lands at
	var hit_angular_gain: float = 3.0 # how strongly the contact lever rotates the body


# ── Body ──────────────────────────────────────────────────────────────────────
# Verlet state: current and previous positions (velocity is implicit in the
# difference). Held across frames by the coordinator; never allocated per tick.
class Body:
	var pos: PackedVector3Array = PackedVector3Array()
	var prev: PackedVector3Array = PackedVector3Array()
	var active: bool = false

	func _init() -> void:
		pos.resize(PARTICLE_COUNT)
		prev.resize(PARTICLE_COUNT)


# ── Seeding ───────────────────────────────────────────────────────────────────
# Build the neutral standing pose and launch it with the hit.
#
# Seeded from a CANONICAL standing rig rather than the skater's live pose: the
# gait's glide-sway phase is explicitly local-only (SkaterSkatingCoordinator), so
# the live rig differs slightly between machines and seeding from it would make
# the fall diverge. The pop from live pose to canonical pose at the instant of
# the hit is invisible — the tumble dominates within a frame or two.
#
# hit_dir_world: horizontal unit vector the victim was shoved along.
# strength:      0..1 hit hardness (BodyCheckRules.intensity of the transfer impulse).
# velocity:      the victim's world velocity at the moment of the hit — a skater
#                blown up while flying already carries that momentum into the fall.
static func seed_body(body: Body, cfg: Config, facing_world: Vector3,
		velocity: Vector3, hit_dir_world: Vector3, strength: float) -> void:
	var fwd: Vector3 = facing_world
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		fwd = Vector3.FORWARD
	fwd = fwd.normalized()
	var right: Vector3 = Vector3.UP.cross(fwd).normalized()

	var pelvis := Vector3(0.0, cfg.stand_pelvis_y, 0.0)
	body.pos[PELVIS] = pelvis
	body.pos[CHEST] = pelvis + Vector3.UP * cfg.spine_len
	body.pos[HEAD] = pelvis + Vector3.UP * (cfg.spine_len + cfg.neck_len)
	var hip_l: Vector3 = pelvis - right * cfg.hip_half_width
	var hip_r: Vector3 = pelvis + right * cfg.hip_half_width
	body.pos[KNEE_L] = hip_l - Vector3.UP * cfg.thigh_len
	body.pos[KNEE_R] = hip_r - Vector3.UP * cfg.thigh_len
	body.pos[SKATE_L] = body.pos[KNEE_L] - Vector3.UP * cfg.shin_len
	body.pos[SKATE_R] = body.pos[KNEE_R] - Vector3.UP * cfg.shin_len

	# Launch. Everything inherits the skater's own momentum, then the hit is
	# resolved as a real rigid-body impulse: a LINEAR part every particle takes
	# equally, plus an ANGULAR part from the moment arm between the contact
	# height and the body's centre of mass. Particles above the CoM get more of
	# the hit than those below (or the reverse, for a check that lands low), so
	# the body rotates about its own CoM instead of translating.
	#
	# That lever is what makes falls differ. A tall attacker's shoulder catching
	# a short victim high folds them forward over their skates; a hit landing at
	# or below the CoM — a hip check — sweeps the legs out ahead and drops them
	# on their back. Both come out of the same equation, and the input is real
	# geometry (see SkaterController._on_body_check_received, which measures it
	# from the two bodies), so no per-fall randomness or archetype table is
	# needed to keep knockdowns from looking stamped.
	var dir: Vector3 = hit_dir_world
	dir.y = 0.0
	if dir.length_squared() < 0.0001:
		dir = -fwd
	dir = dir.normalized()
	var s: float = clampf(strength, 0.0, 1.0)
	var com_y: float = center_of_mass_y(body)
	# Normalising the lever and the radius by body height keeps the angular term
	# dimensionally consistent with the linear one, so hit_angular_gain means the
	# same thing across builds instead of scaling with height².
	var span: float = maxf(body.pos[HEAD].y - body.pos[SKATE_L].y, 0.001)
	var lever: float = (cfg.hit_contact_height - com_y) / span
	var linear: Vector3 = dir * (cfg.hit_speed * s)
	var lift: Vector3 = Vector3.UP * (cfg.hit_lift * s)
	for i: int in PARTICLE_COUNT:
		var radius: float = (body.pos[i].y - com_y) / span
		var angular: Vector3 = dir * (cfg.hit_speed * s * cfg.hit_angular_gain * lever * radius)
		body.prev[i] = body.pos[i] - (velocity + linear + lift + angular) * _SEED_DT
	body.active = true


# Mass-weighted centroid height of the seeded pose. Derived from the same inverse
# masses the solver relaxes with, so the rotation pivots about the body's actual
# centre rather than a hand-placed one.
static func center_of_mass_y(body: Body) -> float:
	var total: float = 0.0
	var weighted: float = 0.0
	for i: int in PARTICLE_COUNT:
		var m: float = 1.0 / maxf(_INV_MASS[i], 0.0001)
		total += m
		weighted += m * body.pos[i].y
	if total <= 0.0:
		return 0.0
	return weighted / total


# Seed velocities are converted to a previous-position offset over this step, so
# the very first step() reproduces them exactly. Matches the 120 Hz tick the
# solver is advanced at.
const _SEED_DT: float = 1.0 / 120.0


# Height of the skate particle in the neutral standing pose. Derived from the
# same segment lengths that build that pose so the two can never drift apart.
static func neutral_skate_height(cfg: Config) -> float:
	return maxf(cfg.stand_pelvis_y - cfg.thigh_len - cfg.shin_len, 0.0)


# ── Integration ───────────────────────────────────────────────────────────────
# One fixed-dt verlet step: integrate, relax constraints, resolve ice contact.
static func step(body: Body, cfg: Config, dt: float) -> void:
	if not body.active or dt <= 0.0:
		return
	var retain: float = 1.0 - cfg.linear_damping
	var grav: Vector3 = Vector3.UP * cfg.gravity * dt * dt
	for i: int in PARTICLE_COUNT:
		var p: Vector3 = body.pos[i]
		var next: Vector3 = p + (p - body.prev[i]) * retain + grav
		body.prev[i] = p
		body.pos[i] = next
	for _it: int in cfg.iterations:
		_relax(body, cfg)
	_resolve_ice(body, cfg)


# Advance the sim by an arbitrary wall-clock span in fixed dt increments. Used to
# fast-forward a peer that observed the knockdown late (packet loss, or a client
# that joined mid-fall) to the same state every other machine is already in —
# the reason the seed inputs are constant for the whole knockdown window.
static func advance(body: Body, cfg: Config, seconds: float, dt: float) -> void:
	if dt <= 0.0:
		return
	var steps: int = int(seconds / dt)
	# Bound the catch-up: a pathological timer can't be allowed to spin the
	# solver for thousands of steps inside one frame.
	steps = clampi(steps, 0, 512)
	for _i: int in steps:
		step(body, cfg, dt)


# Jakobsen distance relaxation. Corrections are split between the two particles
# by inverse mass, so the heavy pelvis barely moves while a skate whips.
static func _relax(body: Body, cfg: Config) -> void:
	# Skeleton: neck, spine, thighs, shins.
	_constrain(body, HEAD, CHEST, cfg.neck_len, 1.0)
	_constrain(body, CHEST, PELVIS, cfg.spine_len, 1.0)
	_constrain(body, PELVIS, KNEE_L, _hip_to_knee(cfg), 1.0)
	_constrain(body, PELVIS, KNEE_R, _hip_to_knee(cfg), 1.0)
	_constrain(body, KNEE_L, SKATE_L, cfg.shin_len, 1.0)
	_constrain(body, KNEE_R, SKATE_R, cfg.shin_len, 1.0)
	# Stabilisers: without these the chain collapses into a line — the spine
	# folds flat, the knees cross, and the result reads as a puddle rather than
	# a body. Soft (stiffness < 1) so they shape the fall without making it rigid.
	_constrain(body, HEAD, PELVIS, cfg.spine_len + cfg.neck_len, 0.28)
	_constrain(body, KNEE_L, KNEE_R, cfg.hip_half_width * 2.0, 0.22)
	_constrain(body, CHEST, KNEE_L, _chest_to_knee(cfg), 0.16)
	_constrain(body, CHEST, KNEE_R, _chest_to_knee(cfg), 0.16)


static func _hip_to_knee(cfg: Config) -> float:
	return sqrt(cfg.thigh_len * cfg.thigh_len + cfg.hip_half_width * cfg.hip_half_width)


static func _chest_to_knee(cfg: Config) -> float:
	var dy: float = cfg.spine_len + cfg.thigh_len
	return sqrt(dy * dy + cfg.hip_half_width * cfg.hip_half_width)


static func _constrain(body: Body, a: int, b: int, rest: float, stiffness: float) -> void:
	var pa: Vector3 = body.pos[a]
	var pb: Vector3 = body.pos[b]
	var delta: Vector3 = pb - pa
	var d: float = delta.length()
	if d < 0.00001:
		return
	var inv_a: float = _INV_MASS[a]
	var inv_b: float = _INV_MASS[b]
	var inv_sum: float = inv_a + inv_b
	if inv_sum <= 0.0:
		return
	var diff: float = (d - rest) / d * stiffness
	var corr: Vector3 = delta * diff
	body.pos[a] = pa + corr * (inv_a / inv_sum)
	body.pos[b] = pb - corr * (inv_b / inv_sum)


# Ice contact: clamp above the plane, kill the downward component, and shed
# tangential speed to friction. Velocity is edited by moving prev, which is how
# impulses work in a verlet integrator.
static func _resolve_ice(body: Body, cfg: Config) -> void:
	var skate_floor: float = neutral_skate_height(cfg)
	for i: int in PARTICLE_COUNT:
		# The skate particle tracks the skate MESH CENTRE, which in the neutral
		# rig sits a boot's height above the ice (the blade hangs below it) — so
		# its contact plane is that height, not the generic particle radius.
		# Deriving it from the same lengths that build the standing pose is what
		# makes a zero-strength seed a true rest state instead of sagging into
		# the ice on the first step.
		var floor_y: float = skate_floor if (i == SKATE_L or i == SKATE_R) else cfg.particle_radius
		var p: Vector3 = body.pos[i]
		if p.y >= floor_y:
			continue
		var v: Vector3 = p - body.prev[i]
		p.y = floor_y
		# Normal: stop (or bounce, if a restitution is ever dialled in).
		var vy: float = -v.y * cfg.ice_restitution
		# Tangential: scrub.
		var keep: float = 1.0 - clampf(cfg.ice_friction, 0.0, 1.0)
		var vt := Vector3(v.x * keep, 0.0, v.z * keep)
		body.pos[i] = p
		body.prev[i] = p - Vector3(vt.x, vy, vt.z)


# ── Rig Mapping ───────────────────────────────────────────────────────────────
# The rig write API takes euler components, so these invert the rotations Godot
# will apply. All return values are in the skater's LOCAL frame (body_basis is
# the skater's global basis) because that is what Skater.set_* expects.

# Torso lean for Skater.set_upper_body_lean(lean_x, lean_z), matching the sign
# convention SkaterPoseCoordinator uses: negative rotation.x pitches the torso
# top toward local -Z (forward), negative rotation.z rolls it toward local +X.
static func torso_lean(body: Body, body_basis: Basis) -> Vector2:
	var spine: Vector3 = body.pos[CHEST] - body.pos[PELVIS]
	if spine.length_squared() < 0.000001:
		return Vector2.ZERO
	var d: Vector3 = (body_basis.inverse() * spine).normalized()
	# Rest is +Y (torso upright). Godot applies rotation.x then rotation.z to it:
	#   Rx(p) * (0,1,0) = (0, cos p,  sin p)   -> d.z =  sin(pitch)
	#   Rz(r) * (0,1,0) = (-sin r, cos r, 0)   -> d.x = -sin(roll)
	# which is exactly the convention SkaterPoseCoordinator documents (negative
	# pitch tips the torso top toward local -Z, negative roll toward local +X).
	var pitch: float = atan2(d.z, d.y)
	var roll: float = atan2(-d.x, d.y)
	return Vector2(pitch, roll)


# Per-leg angles for Skater.set_leg_swing(pitch, roll, knee).
#
# The rig applies rotation = (pitch, 0, roll) to a leg whose rest direction is
# -Y, in Godot's default YXZ euler order, giving
#   d = (sin(roll), -cos(roll)cos(pitch), -cos(roll)sin(pitch))
# which inverts cleanly to roll = asin(d.x), pitch = atan2(-d.z, -d.y). The shin
# then rotates about its own local X by `knee`, so the knee flex is the shin
# direction re-expressed in the rotated leg's frame.
static func leg_angles(body: Body, body_basis: Basis, side_left: bool) -> Vector3:
	var knee_i: int = KNEE_L if side_left else KNEE_R
	var skate_i: int = SKATE_L if side_left else SKATE_R
	var inv: Basis = body_basis.inverse()
	var thigh: Vector3 = body.pos[knee_i] - body.pos[PELVIS]
	if thigh.length_squared() < 0.000001:
		return Vector3.ZERO
	var td: Vector3 = (inv * thigh).normalized()
	var roll: float = asin(clampf(td.x, -1.0, 1.0))
	var pitch: float = atan2(-td.z, -td.y)

	var shin: Vector3 = body.pos[skate_i] - body.pos[knee_i]
	if shin.length_squared() < 0.000001:
		return Vector3(pitch, roll, 0.0)
	# Re-express the shin in the leg's own frame, then read its flex about X.
	var leg_basis: Basis = Basis.from_euler(Vector3(pitch, 0.0, roll))
	var sd: Vector3 = (leg_basis.inverse() * (inv * shin)).normalized()
	var knee: float = atan2(-sd.z, -sd.y)
	return Vector3(pitch, roll, knee)


# Cosmetic body drop (metres) for Skater.set_skating_crouch_drop — how far the
# pelvis has sunk from its standing height. Positive = down.
static func body_drop(body: Body, cfg: Config) -> float:
	return maxf(cfg.stand_pelvis_y - body.pos[PELVIS].y, 0.0)
