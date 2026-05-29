class_name GoalieBodyConfigBuilder
extends RefCounted

# Pure pose builder. Given a per-tick `Inputs` bundle (current state,
# five-hole gap, reaction freeze fields, slide kinematics), returns a populated
# `GoalieBodyConfig` describing every body part's target pos+rot. The Goalie
# node consumes the config and lerps each part toward it.
#
# The scratch config is reused across every call — `Goalie.apply_body_config`
# reads but never stores the reference, so sharing is safe and avoids the
# largest known hot-path allocation (~150 LOC of Vector3 literals per goalie
# per physics tick).

# ── Tuning (set by controller from exports in setup()) ───────────────────────
var catches_left: bool = true
var rvh_post_pad_angle: float = 15.0

# Glove arm reach (in goalie-local coordinates, glove side = -X for
# `catches_left = true`).
var glove_max_x_outward: float = -0.85
var glove_max_x_inward: float = -0.10
var glove_max_z_reach: float = 0.10
var glove_max_yaw_deg: float = 60.0

# Blocker arm reach. Pad+stick are a rigid assembly so only the BlockArm
# translates / yaws toward the intercept; the per-state X tilt (which keeps
# the blade on the ice) stays intact.
var blocker_max_x_outward: float = 0.85
var blocker_max_x_inward: float = 0.10
var blocker_max_z_reach: float = 0.10
var blocker_max_yaw_deg: float = 60.0

# Body lean into the reach side during elevated saves.
var body_lean_max_deg: float = 14.0
var body_lean_reach_norm: float = 0.7
# Shoulder-save pitch. Forward for low-chest shots, back for upper-body / head
# shots. Applied additively on top of each state's resting body pitch so the
# butterfly's existing -10° forward lean still holds at neutral height.
var shoulder_pitch_y_neutral: float = 0.95
var shoulder_pitch_forward_max_deg: float = 8.0
var shoulder_pitch_back_max_deg: float = 5.0
var shoulder_pitch_y_range: float = 0.55

# Reach height clamp + rest Z for the glove/blocker target.
var react_hand_y_min: float = 0.50
var react_hand_y_max: float = 1.55
var react_hand_z: float = -0.28

# Slide pose tuning (push-off pad lift/rot, body lean into slide direction).
var slide_pushoff_lift: float = 0.05
var slide_pushoff_rot_deg: float = 35.0
var slide_body_lean_deg: float = 6.0
var slide_initial_speed: float = 4.5

# Pose constants — fixed across all goalies, never tuned.
# Pad Y-rotation angles the toes outward so pucks deflect toward corners
# rather than back into the slot.
const PAD_TOE_OUT_DEG_STANDING: float = 8.0
const PAD_TOE_OUT_DEG_BUTTERFLY: float = 12.0
# Blocker assembly forward tilt per state (X rotation puts the blade on the
# ice in front of the pads — pad and stick are rigidly attached at the wrist
# so they rotate together).
const STICK_TILT_STANDING: float = 22.0
const STICK_TILT_READY: float = 22.0
const STICK_TILT_BUTTERFLY: float = 72.0   # hand y=0.49 → ~72°, near-flat
const STICK_TILT_RVH: float = 65.0

# Active blade intent: max yaw on the blocker assembly to point the blade
# toward a close-range threat. Smaller cap than the elevated-shot reach yaw
# because the blocker pad is rigidly attached — swinging too far moves the
# whole pad off the right side of the body.
var active_blade_max_yaw_deg: float = 25.0
# Forward depth fed into the yaw atan2. Treating the threat as if it's
# `active_blade_lookahead` metres in front means a small lateral offset still
# produces a readable rotation (rather than the blade hard-snapping to 90°
# whenever the puck is even slightly off-centre).
var active_blade_lookahead: float = 1.5
# Lunge forward extension at peak. Pushes c.blocker_pos forward (in goalie-
# local -Z, the slot direction). Sin-curved by the controller's
# lunge_progress so it reads as a quick jab.
var lunge_extension: float = 0.35
# Paddle-down sweep tunables (BUTTERFLY-family only). Larger yaw cap than the
# upright-state active blade intent because the blocker pad sliding laterally
# is fine when the pads are already on the ice (it's part of the sweep
# motion). Y drop lowers the blocker hand so the paddle/blade trace closer to
# the ice. X extension pushes the assembly slightly toward the puck side so
# the blade reaches further laterally without yaw alone having to do all the
# work.
var paddle_sweep_max_yaw_deg: float = 65.0
var paddle_sweep_y_drop: float = 0.08
var paddle_sweep_x_extension: float = 0.10

# Per-tick input bundle. Controller scratches one instance and overwrites all
# fields before each `build()` call.
class Inputs:
	var state: int  # GoalieStateMachine.State
	var five_hole_openness: float = 0.0
	var reading_slapper_tell: bool = false
	var reacting_to_shot: bool = false
	var shot_is_elevated: bool = false
	var shot_impact_x: float = 0.0
	var shot_impact_y: float = 0.0
	var current_x: float = 0.0
	var goalie_z: float = 0.0
	var direction_sign: int = 1
	var slide_velocity_x: float = 0.0
	var slide_dir: float = 0.0
	# Arm reaction timer still running — suppress glove/blocker reach during
	# the processing window even though `reacting_to_shot` is true.
	var arm_reaction_pending: bool = false
	# Real puck position/velocity for the elevated-shot intercept calculation
	# at the goalie's z-plane. Server uses Jolt linear_velocity; client passes
	# the position-derived `_puck_velocity_est` estimate.
	var puck_position: Vector3 = Vector3.ZERO
	var puck_velocity_est: Vector3 = Vector3.ZERO
	# Active blade intent — set by the controller when there's a close-range
	# opposing threat. The pose builder applies a small yaw on the blocker
	# assembly so the stick blade points toward the puck side, making the
	# stick a deliberate obstacle the carrier has to dangle around. Elevated
	# shot reactions still override this (they have their own yaw math).
	var blade_intent_active: bool = false
	# Paddle-down sweep: stronger version of blade intent for BUTTERFLY-family
	# states. Lowers the blocker hand toward the ice + yaws more aggressively
	# toward the puck so the paddle traces flat across the front of the
	# crease. Replaces (not stacks with) blade_intent_active in the down
	# states.
	var paddle_sweep_active: bool = false
	# Lunge progress, sin-curved 0 → 1 → 0 over the active window. Pose
	# builder scales the forward blocker extension by this value.
	var lunge_progress: float = 0.0

# Scratch — `Goalie.apply_body_config` reads but never stores, so sharing
# one instance is safe and avoids per-tick allocation.
var _scratch: GoalieBodyConfig = GoalieBodyConfig.new()

func build(inputs: Inputs) -> GoalieBodyConfig:
	var c: GoalieBodyConfig = _scratch
	# Per-state baseline pose, then active blade intent (small yaw toward a
	# close-range threat), then elevated-shot reach (overrides the yaw with
	# its own intercept math when reacting). RVH skips both — post-hug pose
	# is committed.
	match inputs.state:
		GoalieStateMachine.State.STANDING:
			_set_standing_pose(c, inputs)
			_apply_active_blade_intent(c, inputs)
			_apply_lunge(c, inputs)
			_apply_elevated_shot_reaction(c, inputs)
		GoalieStateMachine.State.READY, GoalieStateMachine.State.RECOVERING:
			_set_ready_pose(c, inputs)
			_apply_active_blade_intent(c, inputs)
			_apply_lunge(c, inputs)
			_apply_elevated_shot_reaction(c, inputs)
		GoalieStateMachine.State.BUTTERFLY, GoalieStateMachine.State.COILING:
			# COILING shares the butterfly pose — pads on the ice, body
			# squared up. The body rotation is driven separately by the
			# controller's _update_facing branch and the pivot-foot motion
			# is driven by _update_position; the pose builder doesn't need
			# to model the planted-leg weight shift directly.
			_set_butterfly_pose(c, inputs)
			_apply_blade_intent_for_down_state(c, inputs)
			_apply_lunge(c, inputs)
			_apply_elevated_shot_reaction(c, inputs)
		GoalieStateMachine.State.SLIDING:
			_set_sliding_pose(c, inputs)
			_apply_blade_intent_for_down_state(c, inputs)
			_apply_lunge(c, inputs)
			_apply_elevated_shot_reaction(c, inputs)
		GoalieStateMachine.State.RVH_LEFT:
			_set_rvh_left_pose(c)
		GoalieStateMachine.State.RVH_RIGHT:
			_set_rvh_right_pose(c)
	if not catches_left:
		_mirror_hands(c)
	return c

# State-dependent body / head positions. The pose builder hardcodes these
# inside each per-state function, but the replay path needs them WITHOUT
# running the full pose pipeline (which depends on slide/reaction state
# the replay snapshot doesn't carry). This static lookup mirrors the
# values in `_set_*_pose` below — keep in sync if those change.
static func resting_body_position_for_state(state: int) -> Vector3:
	match state:
		GoalieStateMachine.State.STANDING:                        return Vector3(0.0,  1.16,  0.0)
		GoalieStateMachine.State.READY:                           return Vector3(0.0,  1.00, -0.05)
		GoalieStateMachine.State.RECOVERING:                      return Vector3(0.0,  1.00, -0.05)
		GoalieStateMachine.State.BUTTERFLY:                       return Vector3(0.0,  0.46,  0.0)
		GoalieStateMachine.State.COILING:                         return Vector3(0.0,  0.46,  0.0)
		GoalieStateMachine.State.SLIDING:                         return Vector3(0.0,  0.46,  0.0)
		GoalieStateMachine.State.RVH_LEFT:                        return Vector3(-0.02, 0.66, 0.05)
		GoalieStateMachine.State.RVH_RIGHT:                       return Vector3( 0.02, 0.66, 0.05)
	return Vector3(0.0, 1.16, 0.0)

static func resting_head_position_for_state(state: int) -> Vector3:
	match state:
		GoalieStateMachine.State.STANDING:                        return Vector3(0.0,  1.69,  0.08)
		GoalieStateMachine.State.READY:                           return Vector3(0.0,  1.48, -0.22)
		GoalieStateMachine.State.RECOVERING:                      return Vector3(0.0,  1.48, -0.22)
		GoalieStateMachine.State.BUTTERFLY:                       return Vector3(0.0,  0.99, -0.06)
		GoalieStateMachine.State.COILING:                         return Vector3(0.0,  0.99, -0.06)
		GoalieStateMachine.State.SLIDING:                         return Vector3(0.0,  0.99, -0.06)
		GoalieStateMachine.State.RVH_LEFT:                        return Vector3(-0.02, 1.19, 0.08)
		GoalieStateMachine.State.RVH_RIGHT:                       return Vector3( 0.02, 1.19, 0.08)
	return Vector3(0.0, 1.69, 0.08)


func _set_standing_pose(c: GoalieBodyConfig, inputs: Inputs) -> void:
	c.left_pad_pos  = Vector3(-0.22 - inputs.five_hole_openness, 0.44, -0.20)
	c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_STANDING, -12.0)
	c.right_pad_pos = Vector3( 0.22 + inputs.five_hole_openness, 0.44, -0.20)
	c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_STANDING,  12.0)
	c.body_pos      = Vector3(0.0,  1.16,  0.0)
	c.body_rot      = Vector3.ZERO
	c.head_pos      = Vector3(0.0,  1.69,  0.08)
	c.head_rot      = Vector3.ZERO
	c.blocker_pos   = Vector3( 0.38, 0.85, -0.18)
	c.blocker_rot   = Vector3(STICK_TILT_STANDING, 0.0, -20.0)
	c.glove_pos     = Vector3(-0.35, 1.19, -0.18)
	c.glove_rot     = Vector3.ZERO
	if inputs.reading_slapper_tell:
		# Pose-only slapper tell: hands lifted to half-ready. Runs before the
		# elevated-shot reach so a real elevated shot can still override.
		c.glove_pos.y += 0.06
		c.blocker_pos.y += 0.06

# Half-down active stance — deep knee bend, weight forward, gloves dropped
# and reaching forward. Distinct silhouette from STANDING so players read the
# goalie's engagement. RECOVERING shares this pose: real goalies push up FROM
# butterfly INTO a ready stance, not all the way upright. If threat eases
# the state becomes STANDING and the body lerps the rest of the way up; if
# it persists the body is already at READY — single smooth rising motion,
# no up-then-back-down overshoot.
func _set_ready_pose(c: GoalieBodyConfig, inputs: Inputs) -> void:
	c.left_pad_pos  = Vector3(-0.22 - inputs.five_hole_openness, 0.44, -0.16)
	c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_STANDING, -10.0)
	c.right_pad_pos = Vector3( 0.22 + inputs.five_hole_openness, 0.44, -0.16)
	c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_STANDING,  10.0)
	c.body_pos      = Vector3(0.0,  1.00, -0.05)
	c.body_rot      = Vector3(-14.0, 0.0, 0.0)
	c.head_pos      = Vector3(0.0,  1.48, -0.22)
	c.head_rot      = Vector3.ZERO
	c.blocker_pos   = Vector3( 0.44, 0.86, -0.32)
	c.blocker_rot   = Vector3(STICK_TILT_READY, 0.0, -20.0)
	c.glove_pos     = Vector3(-0.42, 0.90, -0.32)
	c.glove_rot     = Vector3.ZERO
	if inputs.reading_slapper_tell:
		c.glove_pos.y += 0.06
		c.blocker_pos.y += 0.06

func _set_butterfly_pose(c: GoalieBodyConfig, inputs: Inputs) -> void:
	c.left_pad_pos  = Vector3(-0.42 - inputs.five_hole_openness, 0.14, -0.20)
	c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_BUTTERFLY, -90.0)
	c.right_pad_pos = Vector3( 0.42 + inputs.five_hole_openness, 0.14, -0.20)
	c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_BUTTERFLY,  90.0)
	c.body_pos      = Vector3(0.0,  0.46,  0.0)
	c.body_rot      = Vector3(-10.0, 0.0, 0.0)
	c.head_pos      = Vector3(0.0,  0.99, -0.06)
	c.head_rot      = Vector3.ZERO
	c.blocker_pos   = Vector3( 0.46, 0.49, -0.18)
	c.blocker_rot   = Vector3(STICK_TILT_BUTTERFLY, 0.0, 0.0)
	c.glove_pos     = Vector3(-0.42, 0.44, -0.18)
	c.glove_rot     = Vector3.ZERO

# Pivot slide: sealing pad (toward post) stays flat; push-off pad (opposite
# side) kicks toward vertical at push-off and returns to flat as the slide
# decays. Body leans into the slide direction. `speed_ratio` = 1.0 at push,
# 0.0 when settled.
func _set_sliding_pose(c: GoalieBodyConfig, inputs: Inputs) -> void:
	var speed_ratio: float = clampf(
			absf(inputs.slide_velocity_x) / maxf(slide_initial_speed, 0.01), 0.0, 1.0)
	var push_lift: float = slide_pushoff_lift * speed_ratio
	var push_rot: float  = slide_pushoff_rot_deg * speed_ratio
	# Base butterfly pose shared with idle.
	c.body_pos    = Vector3(0.0,  0.46,  0.0)
	c.body_rot    = Vector3(-10.0, 0.0,
			inputs.slide_dir * -inputs.direction_sign * slide_body_lean_deg * speed_ratio)
	c.head_pos    = Vector3(0.0,  0.99, -0.06)
	c.head_rot    = Vector3.ZERO
	c.blocker_pos = Vector3( 0.46, 0.49, -0.18)
	c.blocker_rot = Vector3(STICK_TILT_BUTTERFLY, 0.0, 0.0)
	c.glove_pos   = Vector3(-0.42, 0.44, -0.18)
	c.glove_rot   = Vector3.ZERO
	if inputs.slide_dir * -inputs.direction_sign > 0.0:
		# Sliding right: right pad seals the post, left pad pushes off.
		c.right_pad_pos = Vector3( 0.42 + inputs.five_hole_openness, 0.14, -0.20)
		c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_BUTTERFLY,  90.0)
		c.left_pad_pos  = Vector3(-0.42, 0.14 + push_lift, -0.20)
		c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_BUTTERFLY, -(90.0 - push_rot))
	else:
		# Sliding left: left pad seals the post, right pad pushes off.
		c.left_pad_pos  = Vector3(-0.42 - inputs.five_hole_openness, 0.14, -0.20)
		c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_BUTTERFLY, -90.0)
		c.right_pad_pos = Vector3( 0.42, 0.14 + push_lift, -0.20)
		c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_BUTTERFLY,  90.0 - push_rot)

func _set_rvh_left_pose(c: GoalieBodyConfig) -> void:
	# RVH stick swings toward the post. Z rotation rolls the stick laterally
	# so the blade points along the goal line toward the post rather than
	# straight forward.
	c.left_pad_pos  = Vector3( 0.04, 0.14, 0.0)
	c.left_pad_rot  = Vector3(0.0, rvh_post_pad_angle, -90.0)
	c.right_pad_pos = Vector3( 0.45, 0.33, 0.0)
	c.right_pad_rot = Vector3(0.0, 0.0,  60.0)
	c.body_pos      = Vector3(-0.02, 0.66,  0.05)
	c.body_rot      = Vector3.ZERO
	c.head_pos      = Vector3(-0.02, 1.19,  0.08)
	c.head_rot      = Vector3.ZERO
	c.glove_pos     = Vector3(-0.12, 0.69, -0.18)
	c.glove_rot     = Vector3.ZERO
	c.blocker_pos   = Vector3( 0.40, 0.64, -0.18)
	c.blocker_rot   = Vector3(STICK_TILT_RVH, 0.0, -25.0)

func _set_rvh_right_pose(c: GoalieBodyConfig) -> void:
	c.right_pad_pos = Vector3(-0.04, 0.14, 0.0)
	c.right_pad_rot = Vector3(0.0, -rvh_post_pad_angle,  90.0)
	c.left_pad_pos  = Vector3(-0.45, 0.33, 0.0)
	c.left_pad_rot  = Vector3(0.0, 0.0, -60.0)
	c.body_pos      = Vector3( 0.02, 0.66,  0.05)
	c.body_rot      = Vector3.ZERO
	c.head_pos      = Vector3( 0.02, 1.19,  0.08)
	c.head_rot      = Vector3.ZERO
	c.blocker_pos   = Vector3( 0.12, 0.69, -0.18)
	c.blocker_rot   = Vector3(STICK_TILT_RVH, 0.0,  25.0)
	c.glove_pos     = Vector3(-0.40, 0.64, -0.18)
	c.glove_rot     = Vector3.ZERO

# Swap glove ↔ blocker positions for right-catching goalies. The pose data
# is authored assuming catches_left; mirror the X axis for the opposite stance.
func _mirror_hands(c: GoalieBodyConfig) -> void:
	var tmp_pos: Vector3 = c.glove_pos
	var tmp_rot: Vector3 = c.glove_rot
	c.glove_pos   = Vector3(-c.blocker_pos.x, c.blocker_pos.y, c.blocker_pos.z)
	c.glove_rot   = c.blocker_rot
	c.blocker_pos = Vector3(-tmp_pos.x, tmp_pos.y, tmp_pos.z)
	c.blocker_rot = tmp_rot

# Move glove or blocker toward projected impact during an elevated shot.
# Lateral target is GOALIE-relative (`shot_impact_x - current_x`), not goal-
# relative — the hands live in the goalie's body-local frame. The intercept is
# computed at the goalie's actual z-plane, not the goal line: the goalie sits
# forward of the goal line (~0.4-1.2 m) so the puck passes through the glove's
# plane before reaching the goal. Falls back to the goal-line impact value
# if the intercept can't be computed.
# Active blade intent: when an opposing shooter is close, yaw the blocker
# assembly so the stick blade points toward the puck side. Bot skaters
# stickhandle around exposed blades (see `_stickhandle_offset` in
# skater_agent_state_machine.gd), so an intent-driven stick makes the goalie
# meaningfully harder to dangle around without anything as crude as a "poke
# check" verb. Capped at active_blade_max_yaw_deg so the blocker pad doesn't
# swing all the way off the right side.
#
# Skipped during shot reactions — _apply_elevated_shot_reaction runs next and
# has its own intercept-based yaw math that should win.
func _apply_active_blade_intent(c: GoalieBodyConfig, inputs: Inputs) -> void:
	if not inputs.blade_intent_active:
		return
	if inputs.reacting_to_shot:
		return
	# Puck position in goalie-local X (matches the convention used by
	# _apply_elevated_shot_reaction: the +Z-defending goalie is rotated PI in
	# world so its local +X is global -X).
	var puck_local_x: float = (inputs.puck_position.x - inputs.current_x) * -inputs.direction_sign
	# Treat the puck as `active_blade_lookahead` metres in front of the
	# goalie so the yaw scales with lateral offset (atan2 against a fixed
	# depth) instead of hard-snapping. Same sign convention as the elevated
	# reach's blocker_yaw calc.
	var yaw_deg: float = rad_to_deg(atan2(-puck_local_x, -active_blade_lookahead))
	c.blocker_rot = Vector3(
			c.blocker_rot.x,
			clampf(yaw_deg, -active_blade_max_yaw_deg, active_blade_max_yaw_deg),
			c.blocker_rot.z)


# Dispatch the right blade-intent helper for the BUTTERFLY-family states.
# Paddle-down sweep, when active, is a stronger version of the upright
# active-blade-intent yaw — it replaces (not stacks with) the active intent
# so we don't double-apply the yaw math.
func _apply_blade_intent_for_down_state(c: GoalieBodyConfig, inputs: Inputs) -> void:
	if inputs.paddle_sweep_active:
		_apply_paddle_sweep(c, inputs)
	else:
		_apply_active_blade_intent(c, inputs)


# Paddle-down sweep: blocker hand drops toward the ice and the assembly
# yaws (and shifts laterally) aggressively toward the puck side, so the
# paddle traces a wider arc flat across the front of the crease. Replaces
# the upright active blade intent in BUTTERFLY-family states when active.
# Skipped during shot reactions — the reach math wins.
func _apply_paddle_sweep(c: GoalieBodyConfig, inputs: Inputs) -> void:
	if inputs.reacting_to_shot:
		return
	# Same goalie-local-X math as the elevated shot reach + active blade
	# intent (+Z-defending goalie's local +X is global -X).
	var puck_local_x: float = (inputs.puck_position.x - inputs.current_x) * -inputs.direction_sign
	var side: float = signf(puck_local_x)
	# Larger lookahead than the upright active intent so a small wiggle
	# doesn't whip the swept paddle — sweeps should commit to a direction.
	var yaw_deg: float = rad_to_deg(atan2(-puck_local_x, -active_blade_lookahead))
	c.blocker_rot = Vector3(
			c.blocker_rot.x,
			clampf(yaw_deg, -paddle_sweep_max_yaw_deg, paddle_sweep_max_yaw_deg),
			c.blocker_rot.z)
	c.blocker_pos = Vector3(
			c.blocker_pos.x + side * paddle_sweep_x_extension,
			c.blocker_pos.y - paddle_sweep_y_drop,
			c.blocker_pos.z)


# Lunge: push the blocker assembly forward (goalie-local -Z) by the
# lunge_progress fraction of lunge_extension. The blocker pad and stick are
# rigid, so the entire arm jabs forward — blade moves with it. Skipped
# during shot reactions (the reach math wins).
func _apply_lunge(c: GoalieBodyConfig, inputs: Inputs) -> void:
	if inputs.lunge_progress <= 0.0:
		return
	if inputs.reacting_to_shot:
		return
	c.blocker_pos = Vector3(
			c.blocker_pos.x,
			c.blocker_pos.y,
			c.blocker_pos.z - lunge_extension * inputs.lunge_progress)


func _apply_elevated_shot_reaction(c: GoalieBodyConfig, inputs: Inputs) -> void:
	if not inputs.reacting_to_shot or not inputs.shot_is_elevated:
		return
	# Arms have their own reaction delay, longer than the leg-drop delay —
	# reading where in the upper net the puck is going takes more processing
	# than the reflexive low-shot drop. Close-range top-corner shots score
	# because the arm doesn't start moving in time.
	if inputs.arm_reaction_pending:
		return
	var intercept_x: float = inputs.shot_impact_x
	var intercept_y: float = inputs.shot_impact_y
	if absf(inputs.puck_velocity_est.z) > 0.001:
		var dt_to_plane: float = (inputs.goalie_z - inputs.puck_position.z) / inputs.puck_velocity_est.z
		if dt_to_plane > 0.0:
			intercept_x = inputs.puck_position.x + inputs.puck_velocity_est.x * dt_to_plane
			intercept_y = maxf(inputs.puck_position.y + inputs.puck_velocity_est.y * dt_to_plane \
					- 0.5 * 9.8 * dt_to_plane * dt_to_plane, 0.0)
	# Convert world X into goalie-local X (the +Z-defending goalie is rotated
	# PI in world, so its local +X is global -X).
	var impact_local_x: float = (intercept_x - inputs.current_x) * -inputs.direction_sign
	var target_y: float = clampf(intercept_y, react_hand_y_min, react_hand_y_max)
	# Body lean toward the reach side. Magnitude scales with reach distance,
	# capped at `body_lean_max_deg`. +Z rotation tilts top toward -X (lean
	# left for glove side); -Z tilts toward +X (lean right for blocker side).
	var lean_factor: float = clampf(absf(impact_local_x) / maxf(body_lean_reach_norm, 0.001), 0.0, 1.0)
	var lean_sign: float = signf(-impact_local_x)
	var lean_deg: float = lean_sign * lean_factor * body_lean_max_deg
	# Shoulder-save pitch: forward for low-chest shots, back for upper-body /
	# head shots. Engages independently of lateral reach so a centre-chest shot
	# still gets a visible commit (no "arms flopping alone" look). Additive so
	# the state's resting pitch (e.g. butterfly's -10° forward lean) is
	# preserved at neutral height.
	var pitch_deg: float = 0.0
	if intercept_y < shoulder_pitch_y_neutral:
		var p: float = clampf((shoulder_pitch_y_neutral - intercept_y) \
				/ maxf(shoulder_pitch_y_neutral, 0.001), 0.0, 1.0)
		pitch_deg = -shoulder_pitch_forward_max_deg * p
	else:
		var p: float = clampf((intercept_y - shoulder_pitch_y_neutral) \
				/ maxf(shoulder_pitch_y_range, 0.001), 0.0, 1.0)
		pitch_deg = shoulder_pitch_back_max_deg * p
	c.body_rot = Vector3(c.body_rot.x + pitch_deg, c.body_rot.y, lean_deg)
	if impact_local_x <= 0.0:
		_reach_glove(c, impact_local_x, target_y)
	else:
		_reach_blocker(c, impact_local_x, target_y)

# Glove reach: extend toward impact_local_x, clamped to arm reach; Z extends
# forward with reach distance (real goalies thrust the glove out to meet the
# puck). Yaw points along the reach trajectory.
#
# Yaw convention: Godot +Y rotation takes local -Z → -X (goalie's left). For a
# leftward reach (move_dx < 0) we want positive yaw — hence the sign flip on
# move_dx in atan2.
func _reach_glove(c: GoalieBodyConfig, impact_local_x: float, target_y: float) -> void:
	var rest_x: float = c.glove_pos.x
	var rest_z: float = c.glove_pos.z
	var glove_x: float = clampf(impact_local_x, glove_max_x_outward, glove_max_x_inward)
	var reach: float = absf(glove_x - rest_x) / maxf(absf(glove_max_x_outward - rest_x), 0.001)
	var glove_z: float = react_hand_z - glove_max_z_reach * clampf(reach, 0.0, 1.0)
	c.glove_pos = Vector3(glove_x, target_y, glove_z)
	var move_dx: float = glove_x - rest_x
	var move_dz: float = glove_z - rest_z
	var yaw_deg: float = 0.0
	if absf(move_dx) > 0.001 or absf(move_dz) > 0.001:
		yaw_deg = clampf(rad_to_deg(atan2(-move_dx, -move_dz)),
				-glove_max_yaw_deg, glove_max_yaw_deg)
	c.glove_rot = Vector3(-25.0, yaw_deg, 0.0)

# Blocker reach: project the entire BlockArm assembly toward impact, clamped
# to arm reach. We do NOT touch blocker_rot.x (per-state stick tilt that keeps
# blade on ice); instead we add yaw on Y so the assembly rotates around the
# wrist without lifting the blade. Velocity cap is applied downstream in
# `Goalie.apply_body_config` via `blocker_max_step`.
func _reach_blocker(c: GoalieBodyConfig, impact_local_x: float, target_y: float) -> void:
	var rest_x: float = c.blocker_pos.x
	var rest_z: float = c.blocker_pos.z
	var blocker_x: float = clampf(impact_local_x, blocker_max_x_inward, blocker_max_x_outward)
	var reach: float = absf(blocker_x - rest_x) / maxf(absf(blocker_max_x_outward - rest_x), 0.001)
	var blocker_z: float = react_hand_z - blocker_max_z_reach * clampf(reach, 0.0, 1.0)
	c.blocker_pos = Vector3(blocker_x, target_y, blocker_z)
	var move_dx: float = blocker_x - rest_x
	var move_dz: float = blocker_z - rest_z
	var blocker_yaw: float = 0.0
	if absf(move_dx) > 0.001 or absf(move_dz) > 0.001:
		blocker_yaw = clampf(rad_to_deg(atan2(-move_dx, -move_dz)),
				-blocker_max_yaw_deg, blocker_max_yaw_deg)
	c.blocker_rot = Vector3(c.blocker_rot.x, blocker_yaw, c.blocker_rot.z)
