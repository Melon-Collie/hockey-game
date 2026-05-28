class_name GoalieNetworkState

# Legacy fields — drive client-side AI sync (apply_state soft-correction) and
# replay reconstruction. Stay on the wire through step 1 of the goalie pose
# overhaul; will be slimmed once clients render broadcast pose directly.
var position_x: float = 0.0
var position_z: float = 0.0
var rotation_y: float = 0.0
var state_enum: int = 0
var five_hole_openness: float = 0.0
var velocity_x: float = 0.0
var velocity_z: float = 0.0

# Authoritative pose fields — added by goalie overhaul step 1. Populated on the
# host every tick from the live Goalie node body-part transforms. Clients
# currently ignore these (step 1 is wire/instrumentation only); step 2 swaps
# client rendering over to interpolated socket transforms and these become the
# source of truth.
#
# All offsets are goalie-local (relative to the Goalie node root). Rotations
# are radians. Body root has pitch+roll for shoulder-save lean (yaw is the
# existing rotation_y field).
var body_pitch: float = 0.0
var body_roll: float = 0.0
var left_pad_offset: Vector3 = Vector3.ZERO
var left_pad_pitch: float = 0.0
var left_pad_roll: float = 0.0
var right_pad_offset: Vector3 = Vector3.ZERO
var right_pad_pitch: float = 0.0
var right_pad_roll: float = 0.0
var glove_offset: Vector3 = Vector3.ZERO
var glove_yaw: float = 0.0
var glove_pitch: float = 0.0
var blocker_offset: Vector3 = Vector3.ZERO
var blocker_yaw: float = 0.0
var blocker_pitch: float = 0.0
# Stick is currently rigid-attached to the BlockArm; broadcast mirrors blocker
# for step 1. Step 2 lifts the stick out as its own authoritative socket.
var stick_offset: Vector3 = Vector3.ZERO
var stick_yaw: float = 0.0
var stick_pitch: float = 0.0
var head_yaw: float = 0.0

var host_timestamp: float = 0.0  # host-only, not serialized

func to_array() -> Array:
	return [position_x, position_z, rotation_y, state_enum, five_hole_openness, velocity_x, velocity_z]

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
	right_pad_offset = s.right_pad_offset
	right_pad_pitch = s.right_pad_pitch
	right_pad_roll = s.right_pad_roll
	glove_offset = s.glove_offset
	glove_yaw = s.glove_yaw
	glove_pitch = s.glove_pitch
	blocker_offset = s.blocker_offset
	blocker_yaw = s.blocker_yaw
	blocker_pitch = s.blocker_pitch
	stick_offset = s.stick_offset
	stick_yaw = s.stick_yaw
	stick_pitch = s.stick_pitch
	head_yaw = s.head_yaw
	host_timestamp = s.host_timestamp

static func from_array(data: Array) -> GoalieNetworkState:
	var s := GoalieNetworkState.new()
	s.position_x = data[0]
	s.position_z = data[1]
	s.rotation_y = data[2]
	s.state_enum = data[3]
	s.five_hole_openness = data[4]
	if data.size() > 5:
		s.velocity_x = data[5]
		s.velocity_z = data[6]
	return s
