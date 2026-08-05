class_name TopHandIK

# Pure top-hand inverse kinematics. Given a desired blade target in
# upper-body-local XZ space and a fixed stick length, produces the hand and
# blade positions such that:
#
#   1. |blade − hand| == stick_length in 3D (rigid stick). In the horizontal
#      plane, |blade.xz − hand.xz| == stick_horiz = sqrt(stick_length² −
#      (hand.y − blade.y)²). Variable hand.y adjusts stick_horiz on the fly.
#   2. The hand lies within an asymmetric range-of-motion envelope centered
#      on the shoulder — small reach on the forehand (cross-body) side,
#      large reach on the backhand (same side as the top hand) side.
#   3. When the target is reachable, the blade lands exactly on the target.
#      Unreachable targets fall short (past-ROM) or overshoot (past-hand-Y-
#      ceiling at close range) **along the aim line**, preserving aim
#      direction but clipping distance.
#
# Two regimes (continuous at the boundary r = stick_horiz_at_rest):
#   FAR  (r ≥ stick_horiz_at_rest): hand.y = hand_rest_y; hand displaces in
#         XZ toward target up to ROM; blade sits stick_horiz from clamped
#         hand along the aim line (Phase 1 behavior).
#   CLOSE (r < stick_horiz_at_rest): hand.xz stays at shoulder; hand.y rises
#         so stick_horiz shrinks to exactly r and the blade lands on target.
#         Clamped by hand_y_max — if the hand can't rise far enough, the
#         stick's min horizontal projection overshoots the target along the
#         aim line.
#
# Blade-first feel: input is treated as a desired blade position, and the
# hand is solved as a consequence. No per-frame smoothing here — caller owns
# any smoothing if desired.
#
# All coordinates are in upper-body-local space.
#
# blade_side_sign: −1.0 for a left-handed shooter (blade lives on −X),
#                  +1.0 for a right-handed shooter (blade lives on +X).
# The shoulder is expected to live on the opposite (top-hand) side.
#
# Returns a Result (hand + blade in upper-body-local space). Callers on the
# per-tick path pass a reused `out` instance to avoid per-solve allocation;
# omitting it allocates a fresh Result (fine for tests / cold paths).

class Config:
	var stick_length: float = 0.0            # rigid stick length (meters)
	var blade_y: float = 0.0                 # fixed local Y for the blade
	var hand_rest_y: float = 0.0             # hand's resting local Y (FAR regime)
	var hand_y_max: float = 0.0              # ceiling the hand may rise to (CLOSE)
	var rom_forehand_angle_max: float = 0.0  # radians; ROM on forehand side (small)
	var rom_backhand_angle_max: float = 0.0  # radians; ROM on backhand side (large)
	var rom_forehand_reach_max: float = 0.0  # meters; max hand displacement forehand
	var rom_backhand_reach_max: float = 0.0  # meters; max hand displacement backhand
	# Hard cap on the blade's horizontal distance from the shoulder (meters).
	# An obstacle the blade cannot reach past — in practice the boards — makes the
	# reachable region the ROM envelope INTERSECTED with the open ice, and this is
	# that intersection expressed along the current aim line. Capping the DESIRED
	# distance up front routes a wall-limited reach into the CLOSE regime, where
	# the hand rises and the stick's horizontal projection shrinks: the choke-up a
	# real player does when jammed on the boards, rather than a full-reach pose
	# that a post-hoc clamp then has to drag back. INF = unconstrained.
	var max_blade_reach: float = INF

class Result:
	var hand: Vector3 = Vector3.ZERO
	var blade: Vector3 = Vector3.ZERO

# Projects a desired blade target onto the reachable blade region (the ROM
# envelope), in upper-body-local space. This is the closed-form clamp — no
# iteration, no hand work — that decides WHERE the blade ends up. solve() builds
# the full hand pose on top of it; callers that only need the resulting blade
# position (e.g. a per-tick speed cap chasing the reachable target) use this
# directly and skip the hand reconstruction. Returns the blade as (x, blade_y, z).
static func project_blade(
		shoulder: Vector3,
		desired_blade_xz: Vector2,
		blade_side_sign: float,
		cfg: Config) -> Vector3:
	var stick_length: float = cfg.stick_length
	var blade_y: float = cfg.blade_y
	var stick_horiz_at_rest: float = _stick_horiz_for(stick_length, cfg.hand_rest_y, blade_y)

	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var delta: Vector2 = desired_blade_xz - shoulder_xz
	var r: float = delta.length()
	var aim_dir: Vector2 = delta / r if r > 0.0001 else Vector2(0.0, -1.0)
	# Obstacle cap (the boards) applied to the desired DISTANCE, before the regime
	# split, so a wall-limited reach flows into the CLOSE branch and chokes up
	# naturally instead of being clamped back out of the FAR branch afterwards.
	r = minf(r, maxf(cfg.max_blade_reach, 0.0))

	# CLOSE regime: target is inside the default stick reach. The hand would
	# rise so the stick tilts more vertically, shortening its horizontal reach
	# to hit the target exactly. If it can't rise far enough (hand_y_max clamp),
	# the blade overshoots along the aim line at the minimum stick_horiz —
	# hand_y_max IS the inner boundary: sqrt(S² − drop²) grows super-linearly
	# with stick length near the vertical limit, so a long stick's blade can't
	# work in tight to the body while a short one plays the phone booth. The
	# AIM is clamped to the same angular ROM the FAR regime enforces — the
	# wrists don't gain articulation because the puck is close; without this
	# clamp a slowly-swept cursor could walk the blade fully behind the body.
	if r < stick_horiz_at_rest:
		aim_dir = _clamp_aim_to_rom(aim_dir, blade_side_sign, cfg)
		var ideal_drop_sq: float = stick_length * stick_length - r * r
		var ideal_hand_y: float = blade_y + sqrt(maxf(ideal_drop_sq, 0.0))
		var hand_y: float = minf(ideal_hand_y, cfg.hand_y_max)
		var stick_horiz: float = _stick_horiz_for(stick_length, hand_y, blade_y)
		var close_blade_xz: Vector2 = shoulder_xz + aim_dir * stick_horiz
		return Vector3(close_blade_xz.x, blade_y, close_blade_xz.y)

	# FAR regime: target is beyond the default stick reach. The hand displaces
	# toward the target in XZ, clamped to asymmetric ROM; the blade sits
	# stick_horiz_at_rest farther along the same (clamped) arm direction. Since
	# hand and blade are colinear from the shoulder, the blade lands at
	# radius + stick_horiz_at_rest along blade_dir — no need to place the hand.
	var disp: Vector2 = aim_dir * (r - stick_horiz_at_rest)

	# Forehand-signed polar: angle > 0 always means "displaced toward forehand
	# side of body" regardless of handedness. The shoulder lives on the
	# top-hand (backhand) side, so for a lefty a +X displacement is toward
	# the backhand side → angle_to_forehand ends up negative.
	var angle_raw: float = atan2(disp.x, -disp.y)
	var angle_to_forehand: float = angle_raw * blade_side_sign
	var radius: float = disp.length()

	# Clamp angle asymmetrically: forehand side is tight, backhand is open.
	angle_to_forehand = clampf(
			angle_to_forehand, -cfg.rom_backhand_angle_max, cfg.rom_forehand_angle_max)

	radius = clampf(radius, 0.0, max_reach_for_angle(angle_to_forehand, cfg))

	# Back to Cartesian. world_angle undoes the forehand-sign flip. Using the
	# clamped world_angle (not hand_to_target) keeps the blade at the ROM limit
	# when the mouse is past it — hand_to_target wraps around as the mouse moves
	# further past the limit, swinging the blade the wrong way.
	var world_angle: float = angle_to_forehand * blade_side_sign
	var blade_dir := Vector2(sin(world_angle), -cos(world_angle))
	var blade_xz: Vector2 = shoulder_xz + blade_dir * (radius + stick_horiz_at_rest)
	return Vector3(blade_xz.x, blade_y, blade_xz.y)

static func solve(
		shoulder: Vector3,
		desired_blade_xz: Vector2,
		blade_side_sign: float,
		cfg: Config,
		out: Result = null) -> Result:
	if out == null:
		out = Result.new()

	# Where the blade lands (closed-form ROM projection).
	var blade: Vector3 = project_blade(shoulder, desired_blade_xz, blade_side_sign, cfg)
	out.blade = blade

	# Reconstruct the hand from the blade. Hand and blade are colinear from the
	# shoulder with a rigid stick, so the blade's distance from the shoulder
	# fully determines the hand — no need to re-derive the clamped angle/regime:
	#   FAR  (d ≥ stick_horiz_at_rest): hand at rest Y, stick_horiz_at_rest
	#         closer to the shoulder along the same direction.
	#   CLOSE (d < stick_horiz_at_rest): hand at the shoulder XZ; its Y is fixed
	#         by the rigid stick (drop = sqrt(stick_length² − d²)). This inverts
	#         exactly even when the close-regime hand_y was clamped, since the
	#         blade distance already reflects the clamped stick_horiz.
	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var from_shoulder: Vector2 = Vector2(blade.x, blade.z) - shoulder_xz
	var d: float = from_shoulder.length()
	var stick_horiz_at_rest: float = _stick_horiz_for(cfg.stick_length, cfg.hand_rest_y, cfg.blade_y)
	if d >= stick_horiz_at_rest:
		var dir: Vector2 = from_shoulder / d if d > 0.0001 else Vector2(0.0, -1.0)
		var hand_xz: Vector2 = shoulder_xz + dir * (d - stick_horiz_at_rest)
		out.hand = Vector3(hand_xz.x, cfg.hand_rest_y, hand_xz.y)
	else:
		var drop_sq: float = cfg.stick_length * cfg.stick_length - d * d
		var hand_y: float = cfg.blade_y + sqrt(maxf(drop_sq, 0.0))
		out.hand = Vector3(shoulder_xz.x, hand_y, shoulder_xz.y)
	return out

# Reconstruct the top hand for a blade position that is AUTHORITATIVE — one an
# obstacle clamp (boards, net, goalie body) has already decided and that the
# caller must not move. Unlike solve(), which is free to place the blade, this
# takes the blade as given and builds the most plausible arm that reaches it.
#
# Something has to yield when the blade is pinned, and the priority is
# anatomical: the blade stays where gameplay put it, the ARM stays inside its
# ROM, and STICK LENGTH is what gives — the hand slides down the shaft, the
# choke-up a real player does when jammed on the boards or reaching around a
# net. Translating the hand rigidly with the blade instead (which preserves
# stick length) is what puts the hand behind the shoulder and folds the elbow
# through the torso, because nothing in that translation is bounded by the arm.
#
# The arm's DIRECTION is deliberately not ROM-clamped, unlike project_blade's:
# the hand has to lie along the shaft toward the blade, and swinging it onto a
# ROM boundary ray would detach the grip from the stick — worse than a stick
# that reads short. Only the reach RADIUS yields, and rom_*_reach_max is derived
# from arm length (SkaterController.apply_attributes), so the result is always
# within anatomical reach.
#
# For a blade that solve() itself placed this is an exact inverse — same hand,
# no discontinuity when a clamp starts or stops biting.
static func hand_for_clamped_blade(
		shoulder: Vector3,
		blade_xz: Vector2,
		blade_y: float,
		blade_side_sign: float,
		cfg: Config) -> Vector3:
	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var from_shoulder: Vector2 = blade_xz - shoulder_xz
	var d: float = from_shoulder.length()
	var stick_horiz_at_rest: float = _stick_horiz_for(cfg.stick_length, cfg.hand_rest_y, blade_y)
	if d < stick_horiz_at_rest:
		# CLOSE: hands come in over the shoulder and rise, tilting the stick
		# toward vertical. hand_y_max bounds the choke-up; past it the stick
		# simply reads shorter than it is.
		var drop_sq: float = cfg.stick_length * cfg.stick_length - d * d
		var hand_y: float = minf(blade_y + sqrt(maxf(drop_sq, 0.0)), cfg.hand_y_max)
		return Vector3(shoulder_xz.x, hand_y, shoulder_xz.y)
	var dir: Vector2 = from_shoulder / d
	var angle_to_forehand: float = clampf(
			atan2(dir.x, -dir.y) * blade_side_sign,
			-cfg.rom_backhand_angle_max, cfg.rom_forehand_angle_max)
	var reach: float = minf(
			d - stick_horiz_at_rest, max_reach_for_angle(angle_to_forehand, cfg))
	var hand_xz: Vector2 = shoulder_xz + dir * reach
	return Vector3(hand_xz.x, cfg.hand_rest_y, hand_xz.y)

# Enforce the one thing in the chain that has no give: the stick's LENGTH. Takes
# a pose whose hand and blade have drifted more than a stick apart — an authored
# shot finish that reaches past the arm, or a blade an obstacle clamp has just
# moved — and closes the gap along the shaft, filling `out`.
#
# Same anatomical priority the rest of this file keeps, with the stick moved to
# the bottom of it where a rigid object belongs. The HAND yields first: it slides
# down the shaft toward the blade, bounded by the arm's own reach (and by
# hand_y_max on the way up), because a player reaching through a finish extends
# the arm before anything else. Only what the arm cannot cover comes off the
# BLADE, which falls short along the same line — the finish simply doesn't get
# there, exactly as it wouldn't with a real stick.
#
# A pose already within a stick-length is returned untouched, so this is inert on
# every pose that was authored honestly, and never lengthens a shaft that reads
# short (the choke-up is legitimate and stays).
static func enforce_rigid_stick(
		shoulder: Vector3,
		hand: Vector3,
		blade: Vector3,
		blade_side_sign: float,
		cfg: Config,
		out: Result) -> void:
	out.hand = hand
	out.blade = blade
	var to_blade: Vector3 = blade - hand
	var span: float = to_blade.length()
	var over: float = span - cfg.stick_length
	if over <= 0.0 or span < 0.000001:
		return
	var dir: Vector3 = to_blade / span
	# How far the hand may slide before it leaves the arm. ROM is a HORIZONTAL
	# displacement from the shoulder, so the limit is where the sliding hand's
	# ground track leaves that disc — a ray/circle hit, with a purely vertical
	# slide (a near-upright shaft) unconstrained by it.
	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var hand_xz := Vector2(hand.x, hand.z)
	var dir_xz := Vector2(dir.x, dir.z)
	var arm_xz: Vector2 = hand_xz - shoulder_xz
	var reach_max: float = max_reach_for_angle(
			_arm_angle_to_forehand(arm_xz, Vector2(blade.x, blade.z) - shoulder_xz,
					blade_side_sign),
			cfg)
	var slide: float = over
	var a: float = dir_xz.length_squared()
	if a > 0.000001:
		var b: float = 2.0 * arm_xz.dot(dir_xz)
		var c: float = arm_xz.length_squared() - reach_max * reach_max
		var disc: float = b * b - 4.0 * a * c
		# From inside the disc there is always a root, so no real root means the
		# arm is ALREADY at or past its reach — which is exactly what the finish
		# poses author — and sliding further along the shaft only takes it further
		# out. The hand cannot help there, so it stays and the blade pays it all.
		var limit: float = ((-b + sqrt(disc)) / (2.0 * a)) if disc > 0.0 else 0.0
		slide = clampf(minf(slide, limit), 0.0, over)
	if dir.y > 0.000001:
		# Sliding up the shaft toward a raised blade: the same ceiling the CLOSE
		# regime uses stops the hand from climbing out of the body.
		slide = minf(slide, maxf((cfg.hand_y_max - hand.y) / dir.y, 0.0))
	out.hand = hand + dir * slide
	out.blade = blade - dir * (over - slide)


# Forehand-signed arm angle for the ROM lookup, taken from the hand's own bearing
# off the shoulder and falling back to the blade's when the hand sits on top of it
# (the CLOSE poses, where the arm has no bearing of its own).
static func _arm_angle_to_forehand(
		arm_xz: Vector2, blade_from_shoulder: Vector2, blade_side_sign: float) -> float:
	var bearing: Vector2 = arm_xz if arm_xz.length_squared() > 0.000001 else blade_from_shoulder
	if bearing.length_squared() < 0.000001:
		return 0.0
	return atan2(bearing.x, -bearing.y) * blade_side_sign


# Max hand displacement from the shoulder at a forehand-signed arm angle.
# Cross-body forehand reach is limited by anatomy, same-side backhand reach
# allows full extension; a small linear blend across zero avoids a seam.
static func max_reach_for_angle(angle_to_forehand: float, cfg: Config) -> float:
	var blend_band: float = deg_to_rad(5.0)
	if angle_to_forehand >= blend_band:
		return cfg.rom_forehand_reach_max
	if angle_to_forehand <= -blend_band:
		return cfg.rom_backhand_reach_max
	var t: float = (angle_to_forehand + blend_band) / (2.0 * blend_band)
	return lerpf(cfg.rom_backhand_reach_max, cfg.rom_forehand_reach_max, t)

# Clamp an aim direction (unit, from the shoulder) to the asymmetric angular
# ROM — the same limits the FAR regime applies to the hand displacement.
# Returns the input unchanged when already inside the ROM, else the boundary
# ray on the exceeded side (matching FAR's clamped-world-angle behavior: past
# the limit the blade holds at the boundary rather than wrapping).
static func _clamp_aim_to_rom(aim_dir: Vector2, blade_side_sign: float, cfg: Config) -> Vector2:
	var angle_to_forehand: float = atan2(aim_dir.x, -aim_dir.y) * blade_side_sign
	var clamped: float = clampf(
			angle_to_forehand, -cfg.rom_backhand_angle_max, cfg.rom_forehand_angle_max)
	if clamped == angle_to_forehand:
		return aim_dir
	var world_angle: float = clamped * blade_side_sign
	return Vector2(sin(world_angle), -cos(world_angle))


# Horizontal stick projection at a given hand Y. Clamped to a tiny positive
# value so the solver never divides by zero even at edge cases where the
# stick is nearly vertical.
static func _stick_horiz_for(stick_length: float, hand_y: float, blade_y: float) -> float:
	var drop: float = hand_y - blade_y
	var sq: float = stick_length * stick_length - drop * drop
	return sqrt(maxf(sq, 0.0001))
