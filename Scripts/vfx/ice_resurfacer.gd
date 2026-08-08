class_name IceResurfacer
extends Node3D

# Intermission resurfacer crew: two machines enter from opposite end boards
# during a scoreless period break, drive mirrored down-and-back lanes over
# center ice, and fade out before the next faceoff. Purely cosmetic and purely
# local — each peer runs its own crew off its own signals, nothing is
# networked, and the machines never touch the sim.
#
# The payoff is diegetic: the rear squeegee erases accumulated skate
# scratches (IceScratchMap.queue_wipe_segment) along its lane, so the
# instant full wipe every period start already gets (period_synced → clear)
# begins on screen as actual resurfacing. Built and wired by HockeyRink at
# runtime; started by GameManager.intermission_idle_started, torn down by
# intermission_ended / faceoff_prep_announced (a scoreless break emits no
# intermission_ended — the next faceoff prep is its exit, same as the HUD
# band).

# Lane geometry. The two machines run point-mirrored paths with opposite lane
# order (one works inner→outer, the other outer→inner), which keeps their
# hulls ≥ ~3 m apart when they pass mid-rink instead of shaving door handles.
const _LANE_X_INNER: float = 1.6
const _LANE_X_OUTER: float = 3.8
const _END_MARGIN: float = 3.0   # straights stop this far from the end boards
const _ARC_SEGMENTS: int = 16
# Wipe strip is wider than the 2.0 m hull — reads as full-blade coverage and
# leaves overlap between the two lanes of a machine's pass.
const _WIPE_WIDTH_M: float = 2.4
const _SQUEEGEE_BACK_M: float = 1.7  # wipe origin: just behind the rear bumper

const _FADE_S: float = 0.6
const _EXIT_MARGIN_S: float = 1.0    # gone this long before the window closes
const _MIN_SPEED: float = 3.5
const _MAX_SPEED: float = 8.0
const _BEACON_PERIOD_S: float = 0.4
const _BEACON_ON_ENERGY: float = 3.0

const _COLOR_BODY := Color(0.92, 0.90, 0.85)
const _COLOR_NAVY := Color(0.0, 0.22, 0.659)
const _COLOR_DARK := Color(0.15, 0.15, 0.17)
const _COLOR_BEACON := Color(1.0, 0.55, 0.1)

var _rink_width: float = 26.0
var _rink_length: float = 60.0
var _scratch_map: IceScratchMap = null

var _machines: Array[Node3D] = []
var _mesh_instances: Array[MeshInstance3D] = []
var _mat_body: StandardMaterial3D = null
var _mat_navy: StandardMaterial3D = null
var _mat_dark: StandardMaterial3D = null
var _mat_beacon: StandardMaterial3D = null

var _paths: Array[PackedVector3Array] = []
var _cums: Array[PackedFloat32Array] = []
var _seg_cursor: PackedInt32Array = PackedInt32Array()
var _prev_squeegee: PackedVector3Array = PackedVector3Array()
var _total_len: float = 0.0

var _active: bool = false
var _fading_out: bool = false
var _fade_out_start: float = 0.0
var _window_s: float = 0.0
var _speed: float = 0.0
var _elapsed: float = 0.0
var _last_transparency: float = -1.0
var _beacon_clock: float = 0.0
var _beacon_on: bool = false


func setup(rink_width: float, rink_length: float, scratch_map: IceScratchMap) -> void:
	_rink_width = rink_width
	_rink_length = rink_length
	_scratch_map = scratch_map
	_build_materials()
	for _i in range(2):
		var machine := _build_machine()
		add_child(machine)
		_machines.append(machine)
	_build_paths()
	_seg_cursor.resize(2)
	_prev_squeegee.resize(2)
	visible = false
	set_process(false)


# Begin the lap. `window_seconds` is the intermission band window; speed is
# derived so the crew finishes and fades before it closes (clamped to a
# plausible machine speed — a short window just means an unfinished lap that
# fades out wherever it is).
func start_lap(window_seconds: float) -> void:
	if _active:
		return
	_active = true
	_fading_out = false
	_window_s = window_seconds
	_elapsed = 0.0
	_last_transparency = -1.0
	_beacon_clock = 0.0
	_speed = clampf(
			_total_len / maxf(window_seconds - _FADE_S - _EXIT_MARGIN_S, 4.0),
			_MIN_SPEED, _MAX_SPEED)
	for i in range(2):
		_seg_cursor[i] = 0
		_place_machine(i, 0.0)
		_prev_squeegee[i] = _squeegee_world(i)
	visible = true
	set_process(true)


# Break ended (reel teardown, skip vote, faceoff prep, scene reset): fade out
# wherever the machines are. Safe to call repeatedly or while idle.
func abort() -> void:
	if not _active or _fading_out:
		return
	_begin_fade_out()


func _process(delta: float) -> void:
	_elapsed += delta
	var s: float = minf(_speed * _elapsed, _total_len)
	if not _fading_out and (s >= _total_len or _elapsed >= _window_s - _FADE_S):
		_begin_fade_out()

	for i in range(2):
		_place_machine(i, s)
		var squeegee: Vector3 = _squeegee_world(i)
		if is_instance_valid(_scratch_map) \
				and squeegee.distance_squared_to(_prev_squeegee[i]) > 0.0:
			_scratch_map.queue_wipe_segment(_prev_squeegee[i], squeegee, _WIPE_WIDTH_M)
		_prev_squeegee[i] = squeegee

	var alpha_in: float = clampf(_elapsed / _FADE_S, 0.0, 1.0)
	var alpha_out: float = 1.0
	if _fading_out:
		alpha_out = 1.0 - clampf((_elapsed - _fade_out_start) / _FADE_S, 0.0, 1.0)
	var transparency: float = 1.0 - minf(alpha_in, alpha_out)
	if transparency != _last_transparency:
		_last_transparency = transparency
		for mesh in _mesh_instances:
			mesh.transparency = transparency

	_beacon_clock += delta
	if _beacon_clock >= _BEACON_PERIOD_S:
		_beacon_clock = fmod(_beacon_clock, _BEACON_PERIOD_S)
		_beacon_on = not _beacon_on
		_mat_beacon.emission_energy_multiplier = _BEACON_ON_ENERGY if _beacon_on else 0.3

	if _fading_out and _elapsed - _fade_out_start >= _FADE_S:
		_active = false
		visible = false
		set_process(false)


func _begin_fade_out() -> void:
	_fading_out = true
	_fade_out_start = _elapsed


# --------------------------------------------------------------------------
# PATHS — straight lane, U-turn arc, straight lane back; machine 1 runs the
# point-mirrored path with the lane order swapped (see header).

func _build_paths() -> void:
	var path_a: PackedVector3Array = _lane_path(-_LANE_X_INNER, -_LANE_X_OUTER)
	var path_b_src: PackedVector3Array = _lane_path(-_LANE_X_OUTER, -_LANE_X_INNER)
	var path_b := PackedVector3Array()
	path_b.resize(path_b_src.size())
	for i in range(path_b_src.size()):
		var p: Vector3 = path_b_src[i]
		path_b[i] = Vector3(-p.x, 0.0, -p.z)
	_paths = [path_a, path_b]
	_cums.clear()
	for path in _paths:
		var cum := PackedFloat32Array()
		cum.resize(path.size())
		cum[0] = 0.0
		for i in range(1, path.size()):
			cum[i] = cum[i - 1] + path[i].distance_to(path[i - 1])
		_cums.append(cum)
	_total_len = _cums[0][_cums[0].size() - 1]


func _lane_path(first_x: float, second_x: float) -> PackedVector3Array:
	var pts := PackedVector3Array()
	var half_l: float = _rink_length / 2.0
	var radius: float = absf(second_x - first_x) / 2.0
	var z_start: float = -half_l + _END_MARGIN
	var z_turn: float = half_l - _END_MARGIN - radius
	var x_center: float = (first_x + second_x) / 2.0
	# Arc angle 0 sits at x_center + radius; pick endpoints so the sweep runs
	# first_x → second_x through the apex (sin ≥ 0 keeps it inside z_turn + r).
	var a0: float = 0.0 if first_x > x_center else PI
	var a1: float = PI - a0
	pts.push_back(Vector3(first_x, 0.0, z_start))
	pts.push_back(Vector3(first_x, 0.0, z_turn))
	for i in range(1, _ARC_SEGMENTS + 1):
		var a: float = lerpf(a0, a1, float(i) / float(_ARC_SEGMENTS))
		pts.push_back(Vector3(x_center + radius * cos(a), 0.0, z_turn + radius * sin(a)))
	pts.push_back(Vector3(second_x, 0.0, z_start))
	return pts


func _place_machine(idx: int, s: float) -> void:
	var pts: PackedVector3Array = _paths[idx]
	var cum: PackedFloat32Array = _cums[idx]
	var cursor: int = _seg_cursor[idx]
	while cursor < pts.size() - 2 and cum[cursor + 1] < s:
		cursor += 1
	_seg_cursor[idx] = cursor
	var seg_len: float = cum[cursor + 1] - cum[cursor]
	var t: float = 0.0 if seg_len <= 0.0 else clampf((s - cum[cursor]) / seg_len, 0.0, 1.0)
	var machine: Node3D = _machines[idx]
	machine.position = pts[cursor].lerp(pts[cursor + 1], t)
	var dir: Vector3 = pts[cursor + 1] - pts[cursor]
	if dir.length_squared() > 0.0001:
		machine.basis = Basis.looking_at(dir.normalized(), Vector3.UP)


# Wipe origin: behind the rear bumper, on the ice. Machines face local -Z, so
# +basis.z is backward.
func _squeegee_world(idx: int) -> Vector3:
	var machine: Node3D = _machines[idx]
	var p: Vector3 = machine.position + machine.basis.z * _SQUEEGEE_BACK_M
	p.y = 0.0
	return p


# --------------------------------------------------------------------------
# MESHES — low-poly resurfacer, front at local -Z: snow tank forward, open
# driver seat at the rear, squeegee bar trailing, amber beacon on the tank.

func _build_materials() -> void:
	_mat_body = StandardMaterial3D.new()
	_mat_body.albedo_color = _COLOR_BODY
	_mat_navy = StandardMaterial3D.new()
	_mat_navy.albedo_color = _COLOR_NAVY
	_mat_dark = StandardMaterial3D.new()
	_mat_dark.albedo_color = _COLOR_DARK
	_mat_beacon = StandardMaterial3D.new()
	_mat_beacon.albedo_color = _COLOR_BEACON
	_mat_beacon.emission_enabled = true
	_mat_beacon.emission = _COLOR_BEACON
	_mat_beacon.emission_energy_multiplier = 0.3


func _build_machine() -> Node3D:
	var machine := Node3D.new()
	# Chassis + snow tank over the front half.
	_add_box(machine, Vector3(1.9, 0.8, 3.4), Vector3(0.0, 0.75, 0.0), _mat_body)
	_add_box(machine, Vector3(1.7, 0.75, 1.9), Vector3(0.0, 1.5, -0.5), _mat_navy)
	# Console the driver looks over, seat, and a blocky driver silhouette.
	_add_box(machine, Vector3(1.2, 0.5, 0.3), Vector3(0.0, 1.4, 0.55), _mat_navy)
	_add_box(machine, Vector3(0.9, 0.4, 0.45), Vector3(0.0, 1.3, 1.25), _mat_dark)
	_add_box(machine, Vector3(0.55, 0.6, 0.35), Vector3(0.0, 1.8, 1.25), _mat_navy)
	var head := SphereMesh.new()
	head.radius = 0.16
	head.height = 0.32
	head.material = _mat_body
	_add_mesh(machine, head, Vector3(0.0, 2.22, 1.25))
	# Squeegee bar trailing at the ice, wheels, beacon.
	_add_box(machine, Vector3(2.1, 0.12, 0.25), Vector3(0.0, 0.1, 1.7), _mat_dark)
	for x_side in [-1.0, 1.0]:
		for z_side in [-1.0, 1.0]:
			var wheel := CylinderMesh.new()
			wheel.height = 0.25
			wheel.top_radius = 0.3
			wheel.bottom_radius = 0.3
			wheel.material = _mat_dark
			var wheel_inst := _add_mesh(machine, wheel,
					Vector3(0.85 * x_side, 0.3, 1.15 * z_side))
			wheel_inst.rotation = Vector3(0.0, 0.0, PI / 2.0)
	var beacon := SphereMesh.new()
	beacon.radius = 0.09
	beacon.height = 0.18
	beacon.material = _mat_beacon
	_add_mesh(machine, beacon, Vector3(0.6, 1.97, -1.2))
	return machine


func _add_box(parent: Node3D, size: Vector3, pos: Vector3,
		mat: StandardMaterial3D) -> void:
	var box := BoxMesh.new()
	box.size = size
	box.material = mat
	_add_mesh(parent, box, pos)


func _add_mesh(parent: Node3D, mesh: Mesh, pos: Vector3) -> MeshInstance3D:
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.position = pos
	parent.add_child(inst)
	_mesh_instances.append(inst)
	return inst
