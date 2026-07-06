extends GutTest

# Gait stroke profile — the FOOT must push back faster than it recovers
# forward. Real skating is a slow forward recovery and an explosive
# backward push; the thigh-pitch wave gets this right by construction
# (stride_skew warps the sine), but the foot's fore-aft motion also folds
# in the knee (recovery tuck + push extension), and mistimed knee travel
# can concentrate the foot's forward motion into a fast late snap — which
# reads as a forward KICK from behind, where the feet are the visible part
# of the gait. This pins the profile the eye actually sees.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const DT: float = 1.0 / 120.0
const WARMUP_TICKS: int = 240  # let intensity/effort envelopes settle
const MEASURE_TICKS: int = 480 # 4 s — several full cycles at steady state
const THIGH_LEN: float = 0.31
const SHIN_LEN: float = 0.45


# Steady-state cruise straight up-ice; returns per-tick [foot_fwd_l, foot_fwd_r]
# — the feet's forward (−Z body frame) offsets from the hip, in metres.
func _run_cruise() -> Array:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	skater.set_physics_process(false)
	skater.set_process(false)
	var controller: SkaterController = SkaterController.new()
	autofree(controller)
	var sm := SkaterStateMachine.new()
	var coord := SkaterSkatingCoordinator.new()
	coord.setup(skater, sm, controller)
	skater.set_facing(Vector2(0.0, -1.0))
	skater.velocity = Vector3(0.0, 0.0, -6.0)
	# The stride is input-gated (v15 intent byte): without held movement
	# intent the gait is the GLIDE, not the stride — stamp it like a held key.
	skater.move_intent = Vector2(0.0, -1.0)

	var leg_l: Node3D = skater.get_node("MeshRoot/LowerBody/LegL") as Node3D
	var leg_r: Node3D = skater.get_node("MeshRoot/LowerBody/LegR") as Node3D
	var shin_l: Node3D = skater.get_node("MeshRoot/LowerBody/LegL/ShinL") as Node3D
	var shin_r: Node3D = skater.get_node("MeshRoot/LowerBody/LegR/ShinR") as Node3D

	for _i: int in WARMUP_TICKS:
		coord.apply(DT)
	var samples: Array = []
	for _i: int in MEASURE_TICKS:
		coord.apply(DT)
		samples.append([
			_foot_forward(leg_l.rotation.x, shin_l.rotation.x),
			_foot_forward(leg_r.rotation.x, shin_r.rotation.x),
			leg_l.rotation.x, leg_r.rotation.x,
		])
	return samples


# Sagittal-plane foot position: thigh pitched `pitch` from vertical (positive
# = forward), shin folded a further `knee` (negative = heel back). Forward
# offset of the skate from the hip pivot.
func _foot_forward(pitch: float, knee: float) -> float:
	return THIGH_LEN * sin(pitch) + SHIN_LEN * sin(pitch + knee)


func test_foot_push_is_faster_than_recovery() -> void:
	var samples: Array = _run_cruise()
	var peak_fwd: float = 0.0   # fastest forward foot speed (recovery)
	var peak_back: float = 0.0  # fastest backward foot speed (the push)
	var swing_min: float = INF
	var swing_max: float = -INF
	for i: int in range(1, samples.size()):
		for leg: int in 2:
			var v: float = (samples[i][leg] - samples[i - 1][leg]) / DT
			peak_fwd = maxf(peak_fwd, v)
			peak_back = maxf(peak_back, -v)
			swing_min = minf(swing_min, samples[i][leg])
			swing_max = maxf(swing_max, samples[i][leg])
	gut.p("foot: fwd peak %.3f m/s, back peak %.3f m/s, ratio back/fwd %.2f, swing %.0f cm (%.2f..%.2f)"
			% [peak_fwd, peak_back, peak_back / maxf(peak_fwd, 0.001),
			(swing_max - swing_min) * 100.0, swing_min, swing_max])
	assert_gt(peak_back, peak_fwd,
			"the push must be the fast phase: foot peak backward speed (%.3f) should exceed peak forward speed (%.3f)"
			% [peak_back, peak_fwd])
	assert_gt(swing_max - swing_min, 0.14,
			"the stride must still cover ground — fore-aft foot swing collapsed to %.0f cm"
			% [(swing_max - swing_min) * 100.0])


func test_thigh_push_is_faster_than_recovery() -> void:
	# Same guard on the THIGH pitch — the other limb segment the eye reads.
	var samples: Array = _run_cruise()
	var peak_fwd: float = 0.0
	var peak_back: float = 0.0
	for i: int in range(1, samples.size()):
		for leg: int in 2:
			var v: float = (samples[i][2 + leg] - samples[i - 1][2 + leg]) / DT
			peak_fwd = maxf(peak_fwd, v)
			peak_back = maxf(peak_back, -v)
	gut.p("thigh: fwd peak %.3f rad/s, back peak %.3f rad/s, ratio back/fwd %.2f"
			% [peak_fwd, peak_back, peak_back / maxf(peak_fwd, 0.001)])
	assert_gt(peak_back, peak_fwd,
			"thigh backswing (%.3f rad/s) should beat its forward swing (%.3f rad/s)"
			% [peak_back, peak_fwd])
