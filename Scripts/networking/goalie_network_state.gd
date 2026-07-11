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
# RVH / coiling) vs standing-family (standing / ready / recovering — RECOVERING
# counts as up because the rising legs re-open the standing five-hole slot).
# state_enum is written as `GoalieStateMachine.State as int` (see
# GoalieController.capture/apply) — this accessor is the one place that mapping
# is interpreted off the wire, so readers (bot AI shot model, remote pose) never
# hand-roll the enum split.
func is_down() -> bool:
	return state_enum == GoalieStateMachine.State.BUTTERFLY as int \
			or state_enum == GoalieStateMachine.State.SLIDING as int \
			or state_enum == GoalieStateMachine.State.RVH_LEFT as int \
			or state_enum == GoalieStateMachine.State.RVH_RIGHT as int \
			or state_enum == GoalieStateMachine.State.COILING as int


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
