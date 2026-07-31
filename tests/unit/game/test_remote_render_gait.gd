extends GutTest

# The gait's rotations and the sizing seam's positions live on the leg rig's
# bones now, not on Node3Ds — see Skater.leg_bone_euler / leg_bone_position.
const _LEG_L: int = SkaterMeshBuilder.LegBone.LEG_L

# Regression: a client-rendered remote skater's cosmetic leg gait runs at render
# rate through the Skater.render_pose_update hook (perf #431), which yields while
# _self_posing is set. A goal/intermission replay drives the same live skater via
# apply_replay_state, which raises _self_posing — and on a client-rendered remote
# nothing lowers it again (_process_input, the only other reset, never runs on the
# interpolation path). Before the fix the flag stuck true after the first replay
# and every remote's legs froze for the rest of the match. RemoteController now
# clears it whenever live interpolation resumes.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const REMOTE_CONTROLLER_SCENE: PackedScene = preload("res://Scenes/RemoteController.tscn")
const DT: float = 1.0 / 60.0

var _skater: Skater = null
var _controller: RemoteController = null


class _GameStateStub:
	extends Node
	func is_host() -> bool: return false
	func is_movement_locked() -> bool: return false
	func is_replaying() -> bool: return false


func before_each() -> void:
	_skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(_skater)
	_skater.set_physics_process(false)
	_skater.set_process(false)
	var gs := _GameStateStub.new()
	add_child_autofree(gs)
	_controller = REMOTE_CONTROLLER_SCENE.instantiate() as RemoteController
	add_child_autofree(_controller)
	_controller.setup(_skater, null, gs)
	_controller.apply_attributes(PlayerAttributes.all_average())
	_skater.set_facing(Vector2(0.0, -1.0))


# Runs the render-rate hook for `count` frames while the skater is skating forward
# with movement intent (as _apply_state_to_skater would stamp each physics tick),
# and returns the peak-to-peak swing of the hip pivot. A live gait swings; a
# yielded (stuck _self_posing) hook leaves the leg frozen.
func _stride_range(count: int) -> float:
	var lo: float = INF
	var hi: float = -INF
	for _i: int in count:
		_skater.velocity = Vector3(0.0, 0.0, -6.0)
		_skater.move_intent = Vector2(0.0, -1.0)
		_skater.render_pose_update.call(DT)
		lo = minf(lo, _skater.leg_bone_euler(_LEG_L).x)
		hi = maxf(hi, _skater.leg_bone_euler(_LEG_L).x)
	return hi - lo


func test_gait_survives_a_replay_that_self_posed_this_remote() -> void:
	assert_true(_skater.render_pose_update.is_valid(),
			"the skater must have a valid render_pose_update hook after setup")

	# Baseline: a fresh remote strides through the render hook.
	assert_gt(_stride_range(120), 0.15, "a fresh client remote should stride")

	# A goal/intermission replay drives this same live skater. apply_replay_state
	# poses the gait itself and raises _self_posing so the render hook yields.
	var frozen := SkaterNetworkState.new()
	frozen.velocity = Vector3.ZERO
	frozen.move_intent = Vector2.ZERO
	frozen.facing = Vector2(0.0, -1.0)
	_controller.apply_replay_state(frozen, DT)

	# Replay ends and live interpolation resumes — one physics tick of the client
	# branch (empty buffer → _interpolate is a harmless no-op) must clear the flag.
	_controller._physics_process(DT)

	assert_gt(_stride_range(120), 0.15,
			"remote legs must stride again once live play resumes after a replay")
