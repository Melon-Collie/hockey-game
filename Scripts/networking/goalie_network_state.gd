class_name GoalieNetworkState

# Goalie wire state — populated on the host each tick from the live Goalie
# node body-part transforms and broadcast as part of the world snapshot.
#
# Two layers of fields:
#   - Root: position_x/z + rotation_y carry the Goalie node's world placement,
#     state_enum/five_hole_openness/velocity_x/z carry AI sync metadata that
#     drive client soft-correction (until clients swap to rendering broadcast
#     pose directly).
#   - Pose: socket transforms for each body part, in goalie-local space.
#     Rotations are radians. Body root has pitch + roll for shoulder-save lean
#     (yaw is the existing rotation_y field).
#
# The stick is rigid-attached to the blocker arm IRL (blocker pad sits on the
# back of the stick hand). Its transform is derived from the blocker socket
# plus the fixed scene offset baked into BlockArm — no independent socket
# needed on the wire.
var position_x: float = 0.0
var position_z: float = 0.0
var rotation_y: float = 0.0
var state_enum: int = 0
var five_hole_openness: float = 0.0
var velocity_x: float = 0.0
var velocity_z: float = 0.0
var body_pitch: float = 0.0
var body_roll: float = 0.0
var left_pad_offset: Vector3 = Vector3.ZERO
var left_pad_pitch: float = 0.0
var left_pad_roll: float = 0.0
var left_pad_yaw: float = 0.0    # toe-out — rebound-steering angle (v13)
var right_pad_offset: Vector3 = Vector3.ZERO
var right_pad_pitch: float = 0.0
var right_pad_roll: float = 0.0
var right_pad_yaw: float = 0.0   # toe-out — rebound-steering angle (v13)
var glove_offset: Vector3 = Vector3.ZERO
var glove_yaw: float = 0.0
var glove_pitch: float = 0.0
var blocker_offset: Vector3 = Vector3.ZERO
var blocker_yaw: float = 0.0
var blocker_pitch: float = 0.0
var head_yaw: float = 0.0

var host_timestamp: float = 0.0  # host-only, not serialized


# Stance family of the replicated pose: pads ON the ice (butterfly / slide /
# RVH / VH / coiling — VH's back pad + post-sealed vertical pad close the ice
# slot like the other post stances) vs standing-family (standing / ready /
# recovering — RECOVERING counts as up because the rising legs re-open the
# standing five-hole slot). state_enum is written as `GoalieStateMachine.State
# as int` (see GoalieController.capture/apply) — this accessor is the one place
# that mapping is interpreted off the wire, so readers (bot AI shot model,
# remote pose) never hand-roll the enum split.
func is_down() -> bool:
	return state_enum == GoalieStateMachine.State.BUTTERFLY as int \
			or state_enum == GoalieStateMachine.State.SLIDING as int \
			or state_enum == GoalieStateMachine.State.RVH_LEFT as int \
			or state_enum == GoalieStateMachine.State.RVH_RIGHT as int \
			or state_enum == GoalieStateMachine.State.COILING as int \
			or state_enum == GoalieStateMachine.State.VH_LEFT as int \
			or state_enum == GoalieStateMachine.State.VH_RIGHT as int \
			or state_enum == GoalieStateMachine.State.COVERING as int \
			or state_enum == GoalieStateMachine.State.CATCHING_DOWN as int


# World-x sign (±1.0) of the post a post-seal stance (VH/RVH) is committed
# to; 0.0 in any other state. LEFT/RIGHT in the state names are goalie-LOCAL:
# the controller picks the side by puck_local_x = (world_x − goal_x) ·
# −direction_sign with direction_sign = sign(−goal_z), so the goalie's local
# LEFT sits at world-x sign(−goal_z). Callers pass the z of the goal this
# goalie guards (the shooter's attacking_goal.z). Like is_down(), this is the
# one place the state_enum ↔ world mapping is interpreted off the wire.
func post_seal_x_sign(guarded_goal_z: float) -> float:
	var left_sign: float = signf(-guarded_goal_z)
	if state_enum == GoalieStateMachine.State.VH_LEFT as int \
			or state_enum == GoalieStateMachine.State.RVH_LEFT as int:
		return left_sign
	if state_enum == GoalieStateMachine.State.VH_RIGHT as int \
			or state_enum == GoalieStateMachine.State.RVH_RIGHT as int:
		return -left_sign
	return 0.0


# The replicated HAND positions in the NET frame, packed for the shot
# model's pose-aware HIGH band (hole-model v3):
#   (glove_net_dx, glove_height, blocker_net_dx, blocker_height)
# net_dx is the hand's lateral offset from the goalie's own center in world
# x. Local→world x uses the same mapping the controller's post-seal pick
# documents above (local_x = world_dx · −direction_sign, direction_sign =
# sign(−goal_z)) → world_dx = local_x · sign(goal_z). Heights are the local
# offset y (the rig roots at ice level). Like is_down(), this is the one
# place the pose offsets are interpreted off the wire for the shot model.
func hands_read(guarded_goal_z: float) -> Vector4:
	# All-zero offsets mean the pose has not been captured/replicated yet
	# (a real stance always holds both hands off the body's origin —
	# READY/butterfly/RVH all have nonzero x). Report ABSENT so the shot
	# model keeps its declared-stance constants instead of reading a
	# phantom "hands at his feet, dead center" goalie.
	if glove_offset == Vector3.ZERO and blocker_offset == Vector3.ZERO:
		return Vector4.INF
	var m: float = signf(guarded_goal_z)
	return Vector4(glove_offset.x * m, glove_offset.y,
			blocker_offset.x * m, blocker_offset.y)


# The replicated PAD positions + rolls in the NET frame, packed for the shot
# model's pose-aware LOW band (hole-model v3):
#   (left_pad_net_dx, left_pad_roll, right_pad_net_dx, right_pad_roll)
# Same local→world x mapping as hands_read; rolls are radians straight off
# the wire (only |sin|/|cos| are consumed, so the roll's sign convention
# never matters). All-zero pad offsets = pose absent (a real stance always
# splits the pads off center).
func pads_read(guarded_goal_z: float) -> Vector4:
	if left_pad_offset == Vector3.ZERO and right_pad_offset == Vector3.ZERO:
		return Vector4.INF
	var m: float = signf(guarded_goal_z)
	return Vector4(left_pad_offset.x * m, left_pad_roll,
			right_pad_offset.x * m, right_pad_roll)


# TALL post seal = VH (post pad vertical, body upright at the post): the
# whole near-post column is a wall, ice to over the shoulder. False for RVH,
# whose compressed stance seals the ice at the post but leaves short-side
# high — its documented weakness and exactly what VH exists to close.
func is_post_seal_tall() -> bool:
	return state_enum == GoalieStateMachine.State.VH_LEFT as int \
			or state_enum == GoalieStateMachine.State.VH_RIGHT as int


func copy_from(s: GoalieNetworkState) -> void:
	position_x = s.position_x
	position_z = s.position_z
	rotation_y = s.rotation_y
	state_enum = s.state_enum
	five_hole_openness = s.five_hole_openness
	velocity_x = s.velocity_x
	velocity_z = s.velocity_z
	body_pitch = s.body_pitch
	body_roll = s.body_roll
	left_pad_offset = s.left_pad_offset
	left_pad_pitch = s.left_pad_pitch
	left_pad_roll = s.left_pad_roll
	left_pad_yaw = s.left_pad_yaw
	right_pad_offset = s.right_pad_offset
	right_pad_pitch = s.right_pad_pitch
	right_pad_roll = s.right_pad_roll
	right_pad_yaw = s.right_pad_yaw
	glove_offset = s.glove_offset
	glove_yaw = s.glove_yaw
	glove_pitch = s.glove_pitch
	blocker_offset = s.blocker_offset
	blocker_yaw = s.blocker_yaw
	blocker_pitch = s.blocker_pitch
	head_yaw = s.head_yaw
	host_timestamp = s.host_timestamp
