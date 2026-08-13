extends GutTest

# Parity: the native gather-once goalie-contact path (GoalieContactDetector
# .gather_boxes + nearest_packed, backed by NativePuckStep.obb_nearest)
# against the legacy per-call nearest(). Drives both over code-built goalie
# stand-ins (Node3D root → StaticBody3D parts → BoxShape3D shapes — the same
# fallback gather nearest() itself supports), including disabled shapes and
# layer-0 bodies, whose skip rules the gather must mirror exactly.
#
# Goes pending when the extension isn't built.

const TOLERANCE: float = 0.001
const SEED: int = 0x474F4C42  # "GOLB"

var _rng := RandomNumberGenerator.new()
var _roots: Array[Node3D] = []
var _packed := PackedFloat32Array()
var _parts: Array = []
var _part_goalies: Array = []


func before_each() -> void:
	_rng.seed = SEED


func after_each() -> void:
	for r: Node3D in _roots:
		r.free()
	_roots.clear()


func _native_missing() -> bool:
	if GoalieContactDetector.native_available():
		return false
	NativeParityGuard.report_missing(self, "NativeGoalieContact")
	return true


# A goalie stand-in with `part_count` box parts scattered near `center`.
# Roughly a third of parts get a random disable (shape or layer-0), matching
# the runtime toggles nearest() must skip.
func _build_goalie(center: Vector3, part_count: int) -> Node3D:
	var root := Node3D.new()
	add_child(root)
	_roots.append(root)
	root.global_position = center
	for i: int in part_count:
		var body := StaticBody3D.new()
		root.add_child(body)
		body.position = Vector3(_rng.randf_range(-0.5, 0.5),
				_rng.randf_range(0.0, 1.4), _rng.randf_range(-0.4, 0.4))
		body.rotation = Vector3(_rng.randf_range(-0.5, 0.5),
				_rng.randf_range(-PI, PI), _rng.randf_range(-0.5, 0.5))
		var cs := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(_rng.randf_range(0.1, 0.6), _rng.randf_range(0.1, 0.9),
				_rng.randf_range(0.1, 0.5))
		cs.shape = box
		body.add_child(cs)
		var roll: float = _rng.randf()
		if roll < 0.15:
			cs.disabled = true
		elif roll < 0.3:
			body.collision_layer = 0
	return root


func test_gather_path_matches_legacy_nearest() -> void:
	if _native_missing():
		return
	var scratch := SweptDiscOBB.Result.new()
	var legacy := GoalieContactDetector.Contact.new()
	var packed_out := GoalieContactDetector.Contact.new()
	for round_i: int in 60:
		var goalies: Array = [
			_build_goalie(Vector3(0.3, 0.0, 25.5), _rng.randi_range(3, 8)),
			_build_goalie(Vector3(-0.4, 0.0, 24.8), _rng.randi_range(3, 8)),
		]
		var count: int = GoalieContactDetector.gather_boxes(
				goalies, _packed, _parts, _part_goalies)
		# Many sweeps against one gather, like the sub-step loop does.
		for sweep: int in 40:
			var prev := Vector3(_rng.randf_range(-1.5, 1.5), _rng.randf_range(0.0, 1.6),
					_rng.randf_range(23.5, 26.5))
			var curr: Vector3 = prev + Vector3(_rng.randf_range(-0.6, 0.6),
					_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.6, 0.6))
			var radius: float = GameRules.PUCK_COLLISION_RADIUS

			var legacy_hit: bool = GoalieContactDetector.nearest(
					goalies, prev, curr, radius, scratch, legacy)
			var packed_hit: bool = GoalieContactDetector.nearest_packed(
					_packed, count, _parts, _part_goalies, prev, curr, radius, packed_out)

			if legacy_hit != packed_hit:
				fail_test("hit mismatch round %d sweep %d: legacy=%s packed=%s" % [
						round_i, sweep, legacy_hit, packed_hit])
				return
			if not legacy_hit:
				continue
			if legacy.part != packed_out.part or legacy.goalie != packed_out.goalie:
				fail_test("part/goalie mismatch round %d sweep %d" % [round_i, sweep])
				return
			var toi_err: float = absf(legacy.toi - packed_out.toi)
			var point_err: float = legacy.point.distance_to(packed_out.point)
			var normal_err: float = legacy.normal.distance_to(packed_out.normal)
			var depth_err: float = absf(legacy.depth - packed_out.depth)
			if toi_err > TOLERANCE or point_err > TOLERANCE \
					or normal_err > TOLERANCE or depth_err > TOLERANCE:
				fail_test("contact diverged round %d sweep %d: toi=%f point=%f normal=%f depth=%f" % [
						round_i, sweep, toi_err, point_err, normal_err, depth_err])
				return
		after_each()
		_rng.seed = SEED + round_i + 1
	pass_test("60 gathers x 40 sweeps: gather path matches legacy nearest")
