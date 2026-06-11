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
# 240 Hz tick path pass a reused `out` instance to avoid per-solve allocation;
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

class Result:
	var hand: Vector3 = Vector3.ZERO
	var blade: Vector3 = Vector3.ZERO

static func solve(
		shoulder: Vector3,
		desired_blade_xz: Vector2,
		blade_side_sign: float,
		cfg: Config,
		out: Result = null) -> Result:
	if out == null:
		out = Result.new()
	var stick_length: float = cfg.stick_length
	var blade_y: float = cfg.blade_y
	var hand_rest_y: float = cfg.hand_rest_y
	var hand_y_max: float = cfg.hand_y_max

	var stick_horiz_at_rest: float = _stick_horiz_for(stick_length, hand_rest_y, blade_y)

	var shoulder_xz := Vector2(shoulder.x, shoulder.z)
	var delta: Vector2 = desired_blade_xz - shoulder_xz
	var r: float = delta.length()
	var aim_dir: Vector2 = delta / r if r > 0.0001 else Vector2(0.0, -1.0)

	# CLOSE regime: target is inside the default stick reach. Raise the hand
	# so the stick tilts more vertically, shortening its horizontal reach to
	# hit the target exactly. If the hand can't rise far enough (hand_y_max
	# clamp), the blade overshoots along the aim line at the minimum
	# achievable stick_horiz.
	if r < stick_horiz_at_rest:
		var ideal_drop_sq: float = stick_length * stick_length - r * r
		var ideal_hand_y: float = blade_y + sqrt(maxf(ideal_drop_sq, 0.0))
		var hand_y: float = minf(ideal_hand_y, hand_y_max)
		var stick_horiz: float = _stick_horiz_for(stick_length, hand_y, blade_y)
		var close_blade_xz: Vector2 = shoulder_xz + aim_dir * stick_horiz
		out.hand = Vector3(shoulder_xz.x, hand_y, shoulder_xz.y)
		out.blade = Vector3(close_blade_xz.x, blade_y, close_blade_xz.y)
		return out

	# FAR regime: target is beyond the default stick reach. Hand stays at
	# rest Y; displaces toward target in XZ, clamped to asymmetric ROM.
	# Blade sits stick_horiz_at_rest from the clamped hand along the aim line.
	var disp_len: float = r - stick_horiz_at_rest
	var disp: Vector2 = aim_dir * disp_len

	# Forehand-signed polar: angle > 0 always means "displaced toward forehand
	# side of body" regardless of handedness. The shoulder lives on the
	# top-hand (backhand) side, so for a lefty a +X displacement is toward
	# the backhand side → angle_to_forehand ends up negative.
	var angle_raw: float = atan2(disp.x, -disp.y)
	var angle_to_forehand: float = angle_raw * blade_side_sign
	var radius: float = disp.length()

	# Clamp angle asymmetrically: forehand side is tight, backhand is open.
	var fore_angle_max: float = cfg.rom_forehand_angle_max
	var back_angle_max: float = cfg.rom_backhand_angle_max
	angle_to_forehand = clampf(angle_to_forehand, -back_angle_max, fore_angle_max)

	# Max reach is asymmetric: cross-body forehand reach is limited by
	# anatomy, same-side backhand reach allows full arm extension. Small
	# linear blend across zero avoids a seam.
	var blend_band: float = deg_to_rad(5.0)
	var fore_reach: float = cfg.rom_forehand_reach_max
	var back_reach: float = cfg.rom_backhand_reach_max
	var max_reach: float
	if angle_to_forehand >= blend_band:
		max_reach = fore_reach
	elif angle_to_forehand <= -blend_band:
		max_reach = back_reach
	else:
		var t: float = (angle_to_forehand + blend_band) / (2.0 * blend_band)
		max_reach = lerpf(back_reach, fore_reach, t)
	radius = clampf(radius, 0.0, max_reach)

	# Back to Cartesian. world_angle undoes the forehand-sign flip.
	var world_angle: float = angle_to_forehand * blade_side_sign
	var hand_disp := Vector2(sin(world_angle) * radius, -cos(world_angle) * radius)
	var hand_xz: Vector2 = shoulder_xz + hand_disp

	# Blade sits exactly stick_horiz_at_rest from the hand along the clamped
	# arm direction. Using the clamped world_angle (not hand_to_target) ensures
	# the blade stays at the ROM limit when the mouse is past it — hand_to_target
	# wraps around as the mouse moves further past the limit, causing the blade
	# to swing in the wrong direction.
	var blade_dir := Vector2(sin(world_angle), -cos(world_angle))
	var blade_xz: Vector2 = hand_xz + blade_dir * stick_horiz_at_rest

	out.hand = Vector3(hand_xz.x, hand_rest_y, hand_xz.y)
	out.blade = Vector3(blade_xz.x, blade_y, blade_xz.y)
	return out

# Horizontal stick projection at a given hand Y. Clamped to a tiny positive
# value so the solver never divides by zero even at edge cases where the
# stick is nearly vertical.
static func _stick_horiz_for(stick_length: float, hand_y: float, blade_y: float) -> float:
	var drop: float = hand_y - blade_y
	var sq: float = stick_length * stick_length - drop * drop
	return sqrt(maxf(sq, 0.0001))
