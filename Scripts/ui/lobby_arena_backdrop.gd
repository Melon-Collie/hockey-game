class_name LobbyArenaBackdrop
extends Node3D

# Live 3D arena behind the lobby panel: the real RinkArena scene (rink,
# stands, crowd, lights) with a slowly drifting camera, replacing the old
# static ice-texture background. The crowd's fan mix re-tints as the lobby's
# team colors resolve (set_team_color_slots), so color votes repaint the
# bowl live, and the roster sits on the benches as kit-dressed dummies
# (set_bench_counts). PlayerPrefs.apply_video() is re-applied once the arena
# lands so the user's GI / crowd-density / shadow options carry into the
# lobby.

const _ARENA_SCENE_PATH: String = "res://Scenes/RinkArena.tscn"

# Camera path: a slow elliptical drift inside the bowl, matched to the rink's
# 60×26 footprint so the framing keeps a similar distance to the near boards
# all the way around. One lap ≈ 3.5 minutes — present, never distracting.
const _ORBIT_RADIUS_X: float = 16.0
const _ORBIT_RADIUS_Z: float = 22.0
const _ORBIT_HEIGHT: float = 8.5
const _ORBIT_SPEED: float = 0.03  # rad/s
const _LOOK_TARGET: Vector3 = Vector3(0.0, 1.2, 0.0)
const _CAMERA_FOV: float = 65.0

# Center-to-center spacing of seated dummies along the bench. 5 players
# (a full 5v5 side) at this spacing spans 4.2 m of the 6 m bench.
const _DUMMY_SEAT_SPACING: float = 1.05

var _camera: Camera3D = null
var _stands: ArenaStands = null
var _jumbotron: Jumbotron = null
var _orbit_angle: float = 0.0
var _home_slot: int = -1
var _away_slot: int = -1

# One seated mannequin per occupied lobby slot, on that team's bench, dressed
# in the team kit — pure furniture (no scripts, no physics) in the same
# stacked-primitive style as the skater and crowd. Rebuilt when the roster
# counts or the resolved team colors change.
var _dummies_root: Node3D = null
var _home_bench_count: int = 0
var _away_bench_count: int = 0


func _ready() -> void:
	var arena_scene: PackedScene = load(_ARENA_SCENE_PATH)
	var arena: Node3D = arena_scene.instantiate() as Node3D
	add_child(arena)
	_stands = arena.find_child("ArenaStands", false, false) as ArenaStands
	# The backdrop's arena has no live match behind it: pin the jumbotron to
	# its attract screen (wordmark + the lobby's team colors, re-tinted below).
	_jumbotron = arena.find_child("Jumbotron", false, false) as Jumbotron
	if _jumbotron != null:
		_jumbotron.lock_attract()
	_camera = Camera3D.new()
	_camera.fov = _CAMERA_FOV
	add_child(_camera)
	_update_camera(0.0)
	_camera.current = true
	# Deferred: apply_video reads the main loop's current_scene, which isn't
	# assigned yet while the lobby scene's children are still in _ready().
	PlayerPrefs.call_deferred(&"apply_video")


func _process(delta: float) -> void:
	_update_camera(delta)


func _update_camera(delta: float) -> void:
	_orbit_angle = fmod(_orbit_angle + _ORBIT_SPEED * delta, TAU)
	_camera.position = Vector3(
			cos(_orbit_angle) * _ORBIT_RADIUS_X,
			_ORBIT_HEIGHT,
			sin(_orbit_angle) * _ORBIT_RADIUS_Z)
	_camera.look_at(_LOOK_TARGET)


# Re-tint the crowd/benches to the lobby's currently-resolved color slots.
# ArenaStands.setup() is a full bowl rebuild, so skip when nothing changed —
# the lobby calls this from _refresh_grid, which also fires on ready toggles
# and roster churn that leave the colors alone.
func set_team_color_slots(home_slot: int, away_slot: int) -> void:
	if home_slot == _home_slot and away_slot == _away_slot:
		return
	_home_slot = home_slot
	_away_slot = away_slot
	if _stands == null:
		return
	var home: Dictionary = TeamColorRegistry.get_colors(home_slot, 0)
	var away: Dictionary = TeamColorRegistry.get_colors(away_slot, 1)
	_stands.setup(home.primary, home.secondary, away.primary, away.secondary)
	if _jumbotron != null:
		_jumbotron.set_team_colors(
				home.primary, home.secondary, away.primary, away.secondary)
	_rebuild_dummies()


# ── Bench dummies ────────────────────────────────────────────────────────────

func set_bench_counts(home_count: int, away_count: int) -> void:
	if home_count == _home_bench_count and away_count == _away_bench_count \
			and _dummies_root != null:
		return
	_home_bench_count = home_count
	_away_bench_count = away_count
	_rebuild_dummies()


func _rebuild_dummies() -> void:
	if _stands == null or _home_slot < 0:
		return
	if _dummies_root != null:
		_dummies_root.queue_free()
	_dummies_root = Node3D.new()
	_dummies_root.name = "BenchDummies"
	add_child(_dummies_root)
	var meshes: Dictionary = _dummy_meshes()
	for team_id: int in 2:
		var count: int = _home_bench_count if team_id == 0 else _away_bench_count
		if count <= 0:
			continue
		var color_slot: int = _home_slot if team_id == 0 else _away_slot
		var mats: Dictionary = _dummy_materials(TeamColorRegistry.get_colors(color_slot, team_id))
		var seat: Vector3 = _stands.bench_seat_center(team_id)
		for i: int in count:
			var z_off: float = (float(i) - float(count - 1) * 0.5) * _DUMMY_SEAT_SPACING
			var dummy: Node3D = _build_dummy(meshes, mats)
			dummy.position = seat + Vector3(0.0, 0.0, z_off)
			_dummies_root.add_child(dummy)


# One seated figure. Positions are relative to the seat-surface center under
# the pelvis; -X faces the ice. Parts are the skater's own shared low-poly
# meshes (SkaterMeshBuilder), so the bench wears exactly the in-game bodies:
# shaped torso, helmet shell over a head ball, deltoid caps, thighs, socks,
# boots on steel, and a stick held upright in front — the classic
# waiting-on-the-bench posture.
func _build_dummy(meshes: Dictionary, mats: Dictionary) -> Node3D:
	var d := Node3D.new()
	# Lathe axes are local Y; this basis lays a thigh along X.
	var thigh_rot := Basis(Vector3(0, 0, 1), PI / 2.0)
	var stick_lean := Basis(Vector3(0, 0, 1), deg_to_rad(-8.0))
	# Boot frame (see SkaterMeshBuilder._BOOT_STATIONS): local -Y is the toe,
	# local +Z is down. Toe toward the ice (-X), sole down: +Y -> +X, +Z -> -Y,
	# and X = cross closes the right-handed basis (-Z).
	var boot_rot := Basis(Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, -1, 0))
	_add_part(d, meshes.torso, mats.jersey, Vector3(-0.02, 0.32, 0.0))
	_add_part(d, meshes.helmet, mats.helmet, Vector3(0.0, 0.68, 0.0))
	_add_part(d, meshes.head, mats.skin, Vector3(0.0, 0.68, 0.0))
	_add_part(d, meshes.shoulder, mats.shoulder, Vector3(0.0, 0.50, -0.20))
	_add_part(d, meshes.shoulder, mats.shoulder, Vector3(0.0, 0.50, 0.20))
	_add_part(d, meshes.thigh, mats.pants, Vector3(-0.16, 0.10, -0.12), thigh_rot)
	_add_part(d, meshes.thigh, mats.pants, Vector3(-0.16, 0.10, 0.12), thigh_rot)
	_add_part(d, meshes.shin, mats.socks, Vector3(-0.33, -0.15, -0.12))
	_add_part(d, meshes.shin, mats.socks, Vector3(-0.33, -0.15, 0.12))
	_add_part(d, meshes.skate, mats.skate, Vector3(-0.36, -0.36, -0.12), boot_rot)
	_add_part(d, meshes.skate, mats.skate, Vector3(-0.36, -0.36, 0.12), boot_rot)
	_add_part(d, meshes.blade, mats.steel, Vector3(-0.36, -0.36, -0.12), boot_rot)
	_add_part(d, meshes.blade, mats.steel, Vector3(-0.36, -0.36, 0.12), boot_rot)
	_add_part(d, meshes.stick, mats.stick, Vector3(-0.38, 0.18, 0.04), stick_lean)
	# Arms: both hands stacked up on the stick — the classic bench lean. Pose
	# is baked (furniture runs no IK); segment lengths sit near the skater's
	# 0.35 m bones so the proportions match the rig they echo.
	_add_dummy_arm(d, mats,
			Vector3(0.0, 0.50, -0.20), Vector3(-0.19, 0.25, -0.17), Vector3(-0.40, 0.55, -0.045))
	_add_dummy_arm(d, mats,
			Vector3(0.0, 0.50, 0.20), Vector3(-0.19, 0.25, 0.17), Vector3(-0.40, 0.55, 0.045))
	return d


# Static two-segment arm from the skater's shared meshes: tapered bone prisms
# shoulder→elbow→hand, an elbow-pad ball, and a gloved fist gripping toward
# the stick. Radii mirror the live rig (arm 0.065, elbow 0.082, glove 0.064).
# Upper and lower segments wear their own kit materials, elbow ball reads as
# the lower-arm cuff — same split as SkaterUniformCoordinator.apply_uniform.
func _add_dummy_arm(d: Node3D, mats: Dictionary,
		shoulder: Vector3, elbow: Vector3, hand: Vector3) -> void:
	_add_bone(d, mats.arm_upper, shoulder, elbow)
	_add_bone(d, mats.arm_lower, elbow, hand)
	_add_part(d, SkaterMeshBuilder.shared_joint_ball(), mats.elbow, elbow,
			Basis.from_scale(Vector3.ONE * 0.082))
	# Glove fist: local +Y points back toward the elbow, same convention the
	# live rig orients it with.
	var grip: Basis = _basis_along((elbow - hand).normalized()).scaled(Vector3.ONE * 0.064)
	_add_part(d, SkaterMeshBuilder.shared_glove_fist(), mats.gloves, hand, grip)


# Unit bone prism stretched between two joints; +Y (the wide end) lands on
# the proximal joint to match the mesh's distal taper.
func _add_bone(d: Node3D, mat: StandardMaterial3D, proximal: Vector3, distal: Vector3) -> void:
	var dir: Vector3 = proximal - distal
	var length: float = dir.length()
	if length < 0.001:
		return
	var b: Basis = _basis_along(dir / length)
	b = Basis(b.x * 0.065, b.y * length, b.z * 0.065)
	var mi := MeshInstance3D.new()
	mi.mesh = SkaterMeshBuilder.shared_arm_bone()
	mi.material_override = mat
	mi.transform = Transform3D(b, (proximal + distal) * 0.5)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	d.add_child(mi)


# Right-handed orthonormal basis with +Y along `y_axis`.
func _basis_along(y_axis: Vector3) -> Basis:
	var ref: Vector3 = Vector3.FORWARD if absf(y_axis.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(y_axis).normalized()
	return Basis(x_axis, y_axis, x_axis.cross(y_axis))


func _add_part(parent: Node3D, mesh: Mesh, mat: StandardMaterial3D,
		pos: Vector3, basis: Basis = Basis.IDENTITY) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.transform = Transform3D(basis, pos)
	# Bench furniture — same no-shadow policy as the crowd.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)


# The skater's shared low-poly part meshes (materials carry the per-team tint
# via material_override, so the shared meshes stay color-free). The torso's
# cylinder-convention UVs are what let the jersey stripe/yoke texture land
# exactly as it does in-game.
func _dummy_meshes() -> Dictionary:
	var stick := BoxMesh.new()
	stick.size = Vector3(0.04, 1.05, 0.04)
	return {
		"torso": SkaterMeshBuilder.shared_torso(),
		"helmet": SkaterMeshBuilder.shared_helmet_shell(),
		"head": SkaterMeshBuilder.shared_head_ball(),
		"shoulder": SkaterMeshBuilder.shared_shoulder_cap(),
		"thigh": SkaterMeshBuilder.shared_thigh(),
		"shin": SkaterMeshBuilder.shared_sock(),
		"skate": SkaterMeshBuilder.shared_boot(),
		"blade": SkaterMeshBuilder.shared_skate_blade(),
		"stick": stick,
	}


# Dress the dummy in the real kit (colors.uniform), not flat team colors:
# striped jersey with the yoke on the torso's top cap, the shoulder pads'
# own color, striped arms (upper/lower segments each), striped socks, solid
# pants base. Stripe textures come from SkaterUniformCoordinator's
# make_h_stripes_texture / make_arm_stripes_texture so the bands land exactly
# where the in-game skater's do. Pants keep the base color only — the
# in-game vertical side stripe would ring the dummy's horizontally-rotated
# thigh cylinder the wrong way. Roughness values mirror the coordinator's
# surface finishes (cloth / helmet plastic / skate leather / stick).
func _dummy_materials(colors: Dictionary) -> Dictionary:
	var uniform: Dictionary = colors.uniform
	var jersey_block: Dictionary = uniform.jersey
	var socks_block: Dictionary = uniform.socks
	var arms_upper: Dictionary = uniform.arms.upper
	var arms_lower: Dictionary = uniform.arms.lower

	var jersey_mat := StandardMaterial3D.new()
	jersey_mat.albedo_texture = SkaterUniformCoordinator.make_h_stripes_texture(
			jersey_block.base, jersey_block.stripes, jersey_block.yoke)
	jersey_mat.roughness = 0.9

	var socks_mat: StandardMaterial3D
	if socks_block.stripes.is_empty():
		socks_mat = _matte(socks_block.base)
	else:
		socks_mat = StandardMaterial3D.new()
		socks_mat.albedo_texture = SkaterUniformCoordinator.make_h_stripes_texture(
				socks_block.base, socks_block.stripes)
		socks_mat.roughness = 0.9

	return {
		"jersey":    jersey_mat,
		"shoulder":  _matte(uniform.shoulders.color),
		"helmet":    _matte(uniform.helmet, 0.28),
		"pants":     _matte(uniform.pants.base),
		"socks":     socks_mat,
		"skate":     _matte(Color(0.08, 0.08, 0.08), 0.42),
		"steel":     _matte(SkaterMeshBuilder.BLADE_STEEL_COLOR, 0.25),
		"arm_upper": _arm_material(arms_upper),
		"arm_lower": _arm_material(arms_lower),
		"elbow":     _matte(arms_lower.base),
		"gloves":    _matte(uniform.gloves),
		"skin":      _matte(SkinToneRegistry.color_for(SkinToneRegistry.DEFAULT_INDEX)),
		"stick":     _matte(Color(0.06, 0.06, 0.07), 0.4),
	}


# One arm segment's material — striped like the in-game arm bones (the shared
# bone mesh carries cylinder-convention UVs, and make_arm_stripes_texture
# applies the coordinator's arm-vs-sock band scale), solid when the kit
# authors no arm stripes.
func _arm_material(segment: Dictionary) -> StandardMaterial3D:
	if segment.stripes.is_empty():
		return _matte(segment.base)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = SkaterUniformCoordinator.make_arm_stripes_texture(
			segment.base, segment.stripes)
	mat.roughness = 0.9
	return mat


func _matte(c: Color, roughness: float = 0.9) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = roughness
	return m
