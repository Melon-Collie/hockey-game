extends Node

# The body of tools/pose_capture.gd — see that file for what the tool is for,
# how to run it, and why the work lives in a separate script.
#
# ── Why it drives the real controller ───────────────────────────────────────
# Poses are produced by feeding scripted InputStates to a real SkaterController
# on a real Skater, not by writing marker transforms directly. Writing the
# markers would test the renderer against itself: the conversion's whole risk is
# that a pose ARRIVES differently (a write landing on a bone instead of a node,
# in a different parent frame or a different order), and only running the code
# that produces the write exercises that.
#
# ── Determinism ─────────────────────────────────────────────────────────────
# A pixel diff is worthless if the same code renders differently twice, so
# nothing here may depend on wall-clock timing:
#   • The skater's own _process / _physics_process are switched OFF and called
#     by hand with a fixed DT, one of each per step. Real frame deltas would
#     advance the gait phase and the stick flex by a different amount each run.
#   • VFX and the world HUD are frozen (PerfProbe). Both are non-rig content —
#     particle systems are stochastic and the HUD is camera-derived — so they
#     would contribute diff noise about nothing.
#   • Each pose gets a FRESH skater and controller. Charge timers, lean
#     smoothing and stamina all persist, so reusing one actor would make a
#     pose's appearance depend on which pose ran before it.
#   • No shadow maps. Shadow rasterisation is the one part of this scene that
#     wanders between runs, and the acne would read as scattered diff pixels.
#
# ── Reading a diff ──────────────────────────────────────────────────────────
# Sub-perceptual differences localised to an alpha-sort seam are acceptable;
# anything structural or scattered is not. The bounding box is what separates
# them — a change confined to a few pixels at one silhouette edge reads very
# differently from the same pixel COUNT scattered across the whole tile.

const DT: float = 1.0 / 120.0
const TILE: int = 384
const SHEET_COLS: int = 4
# Per-channel 0-255 delta below which two pixels count as equal. Software
# rasterisation is not bit-exact run to run at silhouette edges, and a baseline
# may have been recorded on a different machine.
const DIFF_TOLERANCE: int = 6

const BACKGROUND: Color = Color(0.10, 0.11, 0.14)

const OUT_DIR: String = "user://pose_capture"
const BASELINE_DIR: String = "user://pose_capture/baseline"
const CURRENT_DIR: String = "user://pose_capture/current"

# One build for every pose. Keeping it fixed keeps the diff about articulation;
# proportions across builds are skater_matrix.gd's job.
const BUILD_HEIGHT_IN: int = 73
const BUILD_WEIGHT_LB: int = 201

# Fixed camera offset from the skater, with a fixed rotation — a chase rig that
# never turns. The skater translates several metres during the gait poses, so a
# world-fixed camera would frame them differently from the standing ones; a
# camera that turned with the body would hide exactly the facing changes worth
# diffing.
#
# BOTH vectors are relative to the SKATER's origin, which sits at hip height
# (GameRules.FACEOFF_SPAWN_HEIGHT), not at the ice. Aiming at a world-space point
# instead puts the whole frame a metre high and cuts the legs off — which loses
# the skates and the gait, the half of the rig these poses exist to cover.
const CAM_OFFSET: Vector3 = Vector3(1.9, 0.6, 2.9)
const CAM_AIM: Vector3 = Vector3(0.0, -0.05, 0.0)

# Each pose: a name, whether it starts with the puck, and a list of
# [tick_count, input_spec] segments run in order. Edge fields (shoot_pressed,
# slap_pressed, stick_lift_pressed) fire on the FIRST tick of their segment
# only, which is what makes "press, then hold" expressible as two segments.
#
# Spec keys: move (Vector2, world), aim (Vector3, RELATIVE to the skater —
# absolute would swing as the body translates), sprint, shoot, slap, block,
# deflect (bool), loft (int elevation level).
const POSES: Array = [
	{"name": "rest", "puck": false, "steps": [[40, {}]]},
	{"name": "carry", "puck": true, "steps": [[40, {"aim": Vector3(0.6, 0.0, -2.2)}]]},
	# Two gait phases at two facings. The tick counts are deliberately not
	# multiples of each other, so the stride lands at a different point in its
	# cycle rather than at the same phase twice.
	{"name": "stride_away", "puck": false, "steps": [
		[64, {"move": Vector2(0.0, -1.0), "sprint": true, "aim": Vector3(0.0, 0.0, -3.0)}],
	]},
	{"name": "stride_lateral", "puck": false, "steps": [
		[97, {"move": Vector2(1.0, 0.0), "sprint": true, "aim": Vector3(2.0, 0.0, 1.5)}],
	]},
	# Arm IK near its ROM limit: the cursor sits well across the body, so the
	# reach lean and the backhand ROM clamp both engage.
	{"name": "cross_body_reach", "puck": true, "steps": [
		[20, {"aim": Vector3(0.4, 0.0, -2.0)}],
		[50, {"aim": Vector3(-2.6, 0.0, -0.4)}],
	]},
	{"name": "wrister_aim", "puck": true, "steps": [
		[10, {"aim": Vector3(0.4, 0.0, -2.0)}],
		[45, {"aim": Vector3(1.4, 0.0, -3.0), "shoot": true}],
	]},
	# Released, then held long enough for the follow-through the state machine
	# plays out to be the pose on screen.
	{"name": "wrister_follow_through", "puck": true, "steps": [
		[10, {"aim": Vector3(0.4, 0.0, -2.0)}],
		[45, {"aim": Vector3(1.4, 0.0, -3.0), "shoot": true}],
		[14, {"aim": Vector3(1.4, 0.0, -3.0)}],
	]},
	# The overhead coil, authored in upper-body-local space — the pose most
	# likely to expose a wrong parent frame.
	{"name": "slapper_coil", "puck": true, "steps": [
		[10, {"aim": Vector3(0.4, 0.0, -2.0)}],
		[58, {"aim": Vector3(0.8, 0.0, -3.2), "slap": true}],
	]},
	{"name": "slapper_follow_through", "puck": true, "steps": [
		[10, {"aim": Vector3(0.4, 0.0, -2.0)}],
		[58, {"aim": Vector3(0.8, 0.0, -3.2), "slap": true}],
		[16, {"aim": Vector3(0.8, 0.0, -3.2)}],
	]},
	{"name": "shot_block", "puck": false, "steps": [
		[30, {"block": true, "aim": Vector3(0.0, 0.0, -3.0)}],
	]},
	# Blade tilt extreme: deflect intent at HIGH loft lifts the blade off the ice
	# and rolls it, the widest the blade transform ever swings.
	{"name": "blade_loft_high", "puck": false, "steps": [
		[36, {"deflect": true, "loft": 3, "aim": Vector3(1.2, 0.0, -2.6)}],
	]},
]


# Minimal stand-in for the game-state Node SkaterController takes; it only ever
# asks these two questions. Same stub the control micro-benchmark uses.
class StubGameState extends Node:
	func is_host() -> bool:
		return true

	func is_movement_locked() -> bool:
		return false


var _camera: Camera3D = null
var _state: StubGameState = null
var _skater_scene: PackedScene = null
var _puck_scene: PackedScene = null
var _record_baseline: bool = false
var _pose_index: int = -1
var _posed: bool = false
var _images: Array[Image] = []
var _skater: Skater = null
var _controller: SkaterController = null
var _puck: Puck = null


func begin(record_baseline: bool) -> void:
	_record_baseline = record_baseline
	PerfProbe.freeze_vfx = true
	PerfProbe.freeze_hud = true
	_skater_scene = load("res://Scenes/Skater.tscn")
	_puck_scene = load("res://Scenes/Puck.tscn")
	_state = StubGameState.new()
	add_child(_state)
	_build_stage()


func _build_stage() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = BACKGROUND
	env.environment = e
	add_child(env)

	_camera = Camera3D.new()
	_camera.fov = 45.0
	_camera.position = CAM_OFFSET
	add_child(_camera)
	_camera.look_at(CAM_AIM, Vector3.UP)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	key.light_energy = 1.3
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	add_child(fill)

	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(80, 80)
	floor_mesh.mesh = plane
	var fm := StandardMaterial3D.new()
	fm.albedo_color = Color(0.55, 0.60, 0.66)
	floor_mesh.material_override = fm
	add_child(floor_mesh)


func _process(_delta: float) -> void:
	# Three-beat cycle per pose: build the actor, run its ticks (the frame that
	# renders the pose), then grab the image. get_texture() returns the LAST
	# PRESENTED frame, so the capture has to be a frame behind the posing.
	if _posed:
		_posed = false
		_images.append(get_viewport().get_texture().get_image())
		_teardown()
		return
	if _skater != null:
		_run_pose()
		_posed = true
		return
	_pose_index += 1
	if _pose_index >= POSES.size():
		_finish()
		return
	_build_actor()


func _build_actor() -> void:
	_puck = _puck_scene.instantiate() as Puck
	add_child(_puck)
	# The puck is required by setup() and by the carry / shot paths, but nothing
	# here simulates puck physics — a released shot would otherwise fly it
	# through the frame at a position set by how many ticks it lived.
	_puck.visible = false
	_puck.set_physics_process(false)
	_puck.set_process(false)

	_skater = _skater_scene.instantiate() as Skater
	add_child(_skater)
	_skater.global_position = Vector3(0.0, GameRules.FACEOFF_SPAWN_HEIGHT, 0.0)
	# Driven by hand at a fixed DT. See the determinism note in the header.
	_skater.set_process(false)
	_skater.set_physics_process(false)

	var attrs := PlayerAttributes.new(BUILD_HEIGHT_IN, BUILD_WEIGHT_LB, 1, 1, 1, 1)
	_skater.set_uniform(TeamColorRegistry.get_colors(1, 0))
	_skater.set_jersey_info("POSE", 8)
	_skater.apply_appearance(attrs)

	_controller = SkaterController.new()
	add_child(_controller)
	_controller.setup(_skater, _puck, _state)
	_controller.apply_attributes(attrs)


func _teardown() -> void:
	_controller.queue_free()
	_skater.queue_free()
	_puck.queue_free()
	_controller = null
	_skater = null
	_puck = null


func _run_pose() -> void:
	var pose: Dictionary = POSES[_pose_index]
	if bool(pose.get("puck", false)):
		_puck.set_carrier(_skater)
		_controller.on_puck_picked_up_network()

	var input := InputState.new()
	var steps: Array = pose["steps"]
	for step: Array in steps:
		var ticks: int = step[0]
		var spec: Dictionary = step[1]
		for t: int in ticks:
			_fill_input(input, spec, t == 0)
			# Same order as a live tick: the controller runs at physics priority
			# -1, ahead of the skater's own integration, and the cosmetic rig
			# rebuild is the render pass that follows.
			_controller._process_input(input, DT)
			_skater._physics_process(DT)
			_skater._process(DT)
	_camera.global_position = _skater.global_position + CAM_OFFSET


func _fill_input(input: InputState, spec: Dictionary, first: bool) -> void:
	var aim: Vector3 = spec.get("aim", Vector3(0.0, 0.0, -3.0))
	var move: Vector2 = spec.get("move", Vector2.ZERO)
	var shoot: bool = spec.get("shoot", false)
	var slap: bool = spec.get("slap", false)
	var deflect: bool = spec.get("deflect", false)
	input.delta = DT
	input.host_timestamp += DT
	input.move_vector = move
	input.mouse_world_pos = _skater.global_position + aim
	input.sprint_held = spec.get("sprint", false)
	input.block_held = spec.get("block", false)
	input.elevation_level = spec.get("loft", 0)
	input.shoot_held = shoot
	input.shoot_pressed = shoot and first
	input.slap_held = slap
	input.slap_pressed = slap and first
	input.stick_lift_held = deflect
	input.stick_lift_pressed = deflect and first


func _finish() -> void:
	var dir: String = BASELINE_DIR if _record_baseline else CURRENT_DIR
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	for i: int in POSES.size():
		_images[i].save_png("%s/%s.png" % [dir, String(POSES[i]["name"])])
	var label: String = "baseline" if _record_baseline else "current"
	print("saved %d %s tiles to %s"
			% [POSES.size(), label, ProjectSettings.globalize_path(dir)])
	_save_sheet(_images, "%s/sheet.png" % OUT_DIR)
	if not _record_baseline:
		_diff_against_baseline()
	get_tree().quit()


# Lays the tiles out in a grid so the whole set is one glance. The legend goes to
# stdout rather than being drawn in — an Image has no text, and adding a font
# pass would put non-rig pixels into the thing being diffed.
func _save_sheet(images: Array[Image], path: String) -> void:
	var rows: int = int(ceil(float(images.size()) / float(SHEET_COLS)))
	var sheet := Image.create_empty(SHEET_COLS * TILE, rows * TILE, false, Image.FORMAT_RGBA8)
	sheet.fill(BACKGROUND)
	for i: int in images.size():
		var src: Image = images[i]
		src.convert(Image.FORMAT_RGBA8)
		@warning_ignore("integer_division")
		var row: int = i / SHEET_COLS
		sheet.blit_rect(src, Rect2i(0, 0, TILE, TILE),
				Vector2i((i % SHEET_COLS) * TILE, row * TILE))
	sheet.save_png(path)
	print("sheet: ", ProjectSettings.globalize_path(path))
	for i: int in POSES.size():
		@warning_ignore("integer_division")
		var row: int = i / SHEET_COLS
		print("  [%d,%d] %s" % [row, i % SHEET_COLS, String(POSES[i]["name"])])


func _diff_against_baseline() -> void:
	var missing: int = 0
	var changed_poses: int = 0
	var overlays: Array[Image] = []
	print("")
	print("── Pose diff vs baseline (tolerance %d/255) ──" % DIFF_TOLERANCE)
	for i: int in POSES.size():
		var pose_name: String = String(POSES[i]["name"])
		var baseline: Image = Image.load_from_file("%s/%s.png" % [BASELINE_DIR, pose_name])
		if baseline == null:
			print("  %-24s NO BASELINE" % pose_name)
			missing += 1
			overlays.append(_images[i])
			continue
		var report: Dictionary = _compare(baseline, _images[i])
		overlays.append(report["overlay"])
		var count: int = report["count"]
		if count == 0:
			print("  %-24s clean" % pose_name)
			continue
		changed_poses += 1
		var box: Rect2i = report["box"]
		print("  %-24s %6d px changed, worst delta %3d, box %dx%d at (%d,%d)"
				% [pose_name, count, int(report["worst"]), box.size.x, box.size.y,
				box.position.x, box.position.y])
	if missing > 0:
		print("  (%d pose(s) have no baseline — run with --baseline first)" % missing)
	if changed_poses == 0 and missing == 0:
		print("  all %d poses identical" % POSES.size())
	_save_sheet(overlays, "%s/diff.png" % OUT_DIR)


# Byte-wise compare of two images. Returns the changed-pixel count, the worst
# single-channel delta, the bounding box of the change, and an overlay tinting
# changed pixels magenta. Bytes rather than get_pixel(): a per-pixel Variant
# round trip over 150 k pixels x 11 poses is minutes of tool runtime for the
# same answer.
func _compare(baseline: Image, current: Image) -> Dictionary:
	baseline.convert(Image.FORMAT_RGBA8)
	current.convert(Image.FORMAT_RGBA8)
	var overlay: Image = current.duplicate() as Image
	if baseline.get_size() != current.get_size():
		return {"count": -1, "worst": 255, "box": Rect2i(), "overlay": overlay}
	var a: PackedByteArray = baseline.get_data()
	var b: PackedByteArray = current.get_data()
	var width: int = current.get_width()
	var count: int = 0
	var worst: int = 0
	var min_x: int = width
	var min_y: int = current.get_height()
	var max_x: int = -1
	var max_y: int = -1
	@warning_ignore("integer_division")
	var pixels: int = a.size() / 4
	for p: int in pixels:
		var o: int = p * 4
		var d: int = maxi(maxi(absi(a[o] - b[o]), absi(a[o + 1] - b[o + 1])),
				absi(a[o + 2] - b[o + 2]))
		if d <= DIFF_TOLERANCE:
			continue
		count += 1
		worst = maxi(worst, d)
		@warning_ignore("integer_division")
		var y: int = p / width
		var x: int = p % width
		min_x = mini(min_x, x)
		min_y = mini(min_y, y)
		max_x = maxi(max_x, x)
		max_y = maxi(max_y, y)
		overlay.set_pixel(x, y, Color(1.0, 0.0, 1.0, 1.0))
	var box := Rect2i()
	if max_x >= 0:
		box = Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)
	return {"count": count, "worst": worst, "box": box, "overlay": overlay}
