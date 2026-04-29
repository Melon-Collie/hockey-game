class_name GoalieBodyConfig

var left_pad_pos: Vector3 = Vector3.ZERO
var left_pad_rot: Vector3 = Vector3.ZERO
var right_pad_pos: Vector3 = Vector3.ZERO
var right_pad_rot: Vector3 = Vector3.ZERO
var body_pos: Vector3 = Vector3.ZERO
var body_rot: Vector3 = Vector3.ZERO
var head_pos: Vector3 = Vector3.ZERO
var head_rot: Vector3 = Vector3.ZERO
var glove_pos: Vector3 = Vector3.ZERO
var glove_rot: Vector3 = Vector3.ZERO
var blocker_pos: Vector3 = Vector3.ZERO
# Pad orientation (BlockArm/Blocker child). Face stays forward toward the puck
# regardless of stick tilt — wrist articulation. Used by elevated-shot blocker
# raise too.
var blocker_rot: Vector3 = Vector3.ZERO
# Stick assembly tilt (BlockArm/Stick child). Forward tilt around X plants the
# blade on the ice in upright stances; flatter for butterfly. Decoupled from
# `blocker_rot` so the pad doesn't rotate down when the stick tilts forward.
var stick_rot: Vector3 = Vector3.ZERO
