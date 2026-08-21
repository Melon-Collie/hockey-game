extends GutTest

# ── THE STICK IS ONE SOLID PIECE ─────────────────────────────────────────────
# Shaft, paddle and blade are a rigid assembly hanging off the wrist: the whole
# thing swings with BlockArm and NOTHING inside it moves relative to anything
# else. That claim is load-bearing twice over — the puck's swept-OBB test reads
# these three colliders as a single object a shot bounces off, and
# GoalieStickRules solves the stance tilt from a wrist-to-blade lever it assumes
# is constant. A stick that stretched or hinged would put the blade somewhere
# the solve does not believe it is.
#
# Nothing in the code deliberately flexes it, which is exactly why this is a
# test rather than a comment: the failure would be silent, and it would arrive
# from a per-frame writer somewhere else — a bone scaler that caught the stick
# in its subtree, a rig that lerped the Stick node on its own instead of the
# arm, a mesh pass that scaled to a body dial.
#
# So drive a real goalie through every stance and every modifier that moves the
# hand, and assert two things about the three colliders each tick: the distances
# between them never change, and neither do their orientations relative to one
# another. Together those are rigidity — the first catches stretch, the second
# catches a hinge that preserves length.
const DT: float = 1.0 / 120.0
const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const TOLERANCE_M: float = 0.0005
const TOLERANCE_DEG: float = 0.05
const _PARTS: Array[String] = [
	"BlockArm/Stick/StickShaftCollider",
	"BlockArm/Stick/StickPaddleCollier",
	"BlockArm/Stick/StickBladeCollider",
]

var _goalie: Node3D
var _puck: Node
var _shooter: Skater
var _ctrl: GoalieController


func before_each() -> void:
	_goalie = load("res://Scenes/Goalie.tscn").instantiate() as Node3D
	_puck = load("res://Scenes/Puck.tscn").instantiate()
	_shooter = load("res://Scenes/Skater.tscn").instantiate() as Skater
	_ctrl = GoalieController.new()
	add_child_autofree(_goalie)
	add_child_autofree(_puck)
	add_child_autofree(_shooter)
	add_child_autofree(_ctrl)
	_shooter.set_physics_process(false)
	_ctrl.set_skater_getter(func() -> Array: return [_shooter])
	_ctrl.setup(_goalie, _puck, GOAL_Z, true)


func test_the_stick_never_stretches_or_hinges() -> void:
	var ref_spans: Array[float] = []
	var ref_angles: Array[float] = []
	var samples: int = 0
	var worst_stretch: float = 0.0
	var worst_hinge: float = 0.0
	var worst_stretch_where: String = "none"
	var worst_hinge_where: String = "none"
	for state: int in [
			GoalieStateMachine.State.STANDING,
			GoalieStateMachine.State.READY,
			GoalieStateMachine.State.BUTTERFLY,
			GoalieStateMachine.State.SLIDING,
			GoalieStateMachine.State.COVERING,
			GoalieStateMachine.State.RVH_LEFT,
			GoalieStateMachine.State.RVH_RIGHT,
			GoalieStateMachine.State.VH_LEFT,
			GoalieStateMachine.State.PLAYING_PUCK,
			GoalieStateMachine.State.CATCHING,
			GoalieStateMachine.State.CATCHING_DOWN]:
		# Walk the shooter across the slot as the pose settles, so the blade-aim
		# yaw, the sweeps and the reach all fire rather than only the rest pose.
		for step: int in 40:
			var x: float = -3.0 + 0.15 * float(step)
			var spot := Vector3(x, 0.0, GOAL_Z + 2.0 + 0.1 * float(step))
			_shooter.global_position = spot
			_shooter.current_shot_state = SkaterStateMachine.State.SKATING_WITH_PUCK
			_puck.set_carrier(_shooter)
			_puck.global_position = spot
			_ctrl._sm.transition_to(state)
			_ctrl._physics_process(DT)
			var spans: Array[float] = _spans()
			var angles: Array[float] = _relative_angles_deg()
			samples += 1
			if ref_spans.is_empty():
				ref_spans = spans
				ref_angles = angles
				continue
			# One assertion at the end, not one per sample: 440 poses would
			# otherwise bury the suite in 2200 passing lines. Carry the worst
			# deviation and the pose it came from instead.
			for i: int in spans.size():
				var d: float = absf(spans[i] - ref_spans[i])
				if d > worst_stretch:
					worst_stretch = d
					worst_stretch_where = "state %d span %d: %.4f → %.4f m" % [
							state, i, ref_spans[i], spans[i]]
			for i: int in angles.size():
				var d: float = absf(angles[i] - ref_angles[i])
				if d > worst_hinge:
					worst_hinge = d
					worst_hinge_where = "state %d joint %d: %.3f → %.3f deg" % [
							state, i, ref_angles[i], angles[i]]
	assert_gt(samples, 400, "sampled too few poses to mean anything")
	assert_lt(worst_stretch, TOLERANCE_M, "stick STRETCHED — %s" % worst_stretch_where)
	assert_lt(worst_hinge, TOLERANCE_DEG, "stick HINGED — %s" % worst_hinge_where)


# A rigid body's colliders also have unit scale — a scaled one would keep every
# span and angle above while the SHAPE it presents to the puck changed size.
func test_nothing_in_the_stick_is_scaled() -> void:
	var node: Node3D = _goalie.get_node("BlockArm") as Node3D
	while node != null:
		assert_almost_eq(node.scale.x, 1.0, 1e-5, "%s is scaled in x" % node.name)
		assert_almost_eq(node.scale.y, 1.0, 1e-5, "%s is scaled in y" % node.name)
		assert_almost_eq(node.scale.z, 1.0, 1e-5, "%s is scaled in z" % node.name)
		node = node.get_parent() as Node3D
	for path: String in _PARTS:
		var cs := _goalie.get_node(path) as Node3D
		assert_almost_eq(cs.scale.length(), Vector3.ONE.length(), 1e-5,
				"%s is scaled" % path)


func _spans() -> Array[float]:
	var out: Array[float] = []
	for i: int in _PARTS.size():
		for j: int in range(i + 1, _PARTS.size()):
			out.append((_goalie.get_node(_PARTS[i]) as Node3D).global_position.distance_to(
					(_goalie.get_node(_PARTS[j]) as Node3D).global_position))
	return out


# Each part's orientation as seen from the part before it — invariant for a
# rigid assembly however the wrist swings, and the half a pure length check
# cannot see.
func _relative_angles_deg() -> Array[float]:
	var out: Array[float] = []
	for i: int in range(1, _PARTS.size()):
		var a: Basis = (_goalie.get_node(_PARTS[i - 1]) as Node3D).global_transform.basis
		var b: Basis = (_goalie.get_node(_PARTS[i]) as Node3D).global_transform.basis
		var rel: Basis = a.inverse() * b
		out.append(rad_to_deg(rel.get_euler().length()))
	return out
