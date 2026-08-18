class_name ArenaHouseLights
extends Node3D

# The building's own lighting: visible housings for the ceiling rig, and the
# cue that takes the house down for a skate-on and brings it back up.
#
# Both halves belong together because they are the same eight lights. The rig in
# RinkArena.tscn is eight SpotLight3Ds hanging at ~22 m with no geometry at all,
# so the ice is lit from nothing; and nothing in the project has ever animated
# them, so a period has always started at full house. Housings alone would leave
# a lit fixture over a dark bowl during the cue, which is worse than either.
#
# The cue takes the whole house, not just the ceiling: the rig is eight overhead
# spots, six rinkside dashers, and four bowl omnis, and dimming only the first
# group leaves the boards and the crowd lit under a dark ceiling, which reads as
# a bug rather than as a blackout. Housings are built for the overhead group
# alone, since it is the only one whose fixtures would ever be in frame.
#
# Matched by NAME so the set is exactly the lights RinkArena.tscn authors. The
# alternative — every Light3D under the arena — would eventually capture the
# goal lamps, which GoalVFX drives itself, and the two would fight over the same
# property. Energies are captured once at setup and every level is a fraction of
# them, so this cooperates with whatever the scene was authored at.
const HOUSE_LIGHT_PATTERNS: Array[String] = [
	"SpotLight3D*",      # the overhead rig (matches PlayerPrefs._apply_shadow_quality)
	"DasherSpotLight*",  # rinkside
	"BowlLight*",        # the warm corner fill
]
# Only this group gets housings — the others are hidden behind the stands.
const HOUSING_PATTERN: String = "SpotLight3D*"

# How far down the house goes. Not to black: the crowd, the boards and the ice
# still have to read, and the arena's own emissive surfaces (jumbotron, ribbon
# board, banners) carry the picture while the rig is under.
const HOUSE_LOW: float = 0.12
const AMBIENT_LOW: float = 0.35
# The blackout snaps; the return is a slow build under the skate-on.
const FALL_TIME: float = 0.7
const RISE_TIME_MAX: float = 3.5
# Fraction of the intro window the rise is allowed to take.
const RISE_FRACTION: float = 0.4
# Leaves the bowl at full a beat before the puck drops, whatever the window.
const TAIL_S: float = 0.3

# Fixture housings. Sized in the LIGHT's own frame, which aims along its local
# −Z, so the thin axis of both boxes is Z: the housing is a slab facing the way
# the light points, whatever direction that happens to be.
const HOUSING_SIZE: Vector3 = Vector3(1.5, 1.5, 0.34)
const LENS_SIZE: Vector3 = Vector3(1.28, 1.28, 0.06)
# Set back along the aim so the housing sits behind the emitter rather than in
# its own beam.
const HOUSING_DROP: float = 0.3
const HOUSING_COLOR: Color = Color(0.10, 0.10, 0.12)
# The lens is the bright face. Above the environment's glow threshold at full
# house so the fixtures bloom like the real thing.
const LENS_COLOR: Color = Color(1.0, 0.97, 0.90)
const LENS_ENERGY: float = 1.9

var _lights: Array[Light3D] = []
var _base_energy: PackedFloat32Array = PackedFloat32Array()
# The overhead subset, in name order, that carries a visible housing.
var _housed: Array[Light3D] = []
var _lens_material: StandardMaterial3D = null
var _environment: Environment = null
var _base_ambient: float = 0.0
var _tween: Tween = null


# `arena_root` is the scene the lights live in — ArenaStands' own parent.
func setup(arena_root: Node) -> void:
	for pattern: String in HOUSE_LIGHT_PATTERNS:
		var found: Array[Node] = arena_root.find_children(pattern, "Light3D", true, false)
		found.sort_custom(
				func(a: Node, b: Node) -> bool: return String(a.name) < String(b.name))
		for node: Node in found:
			var light: Light3D = node as Light3D
			_lights.append(light)
			_base_energy.append(light.light_energy)
			if pattern == HOUSING_PATTERN:
				_housed.append(light)

	var we: WorldEnvironment = arena_root.find_child(
			"WorldEnvironment", true, false) as WorldEnvironment
	if we != null and we.environment != null:
		_environment = we.environment
		_base_ambient = _environment.ambient_light_energy

	_build_housings()


# A housing under each light, oriented to it, so the rig reads as hardware. Only
# the lens is bright; the body is dark so the fixture has a silhouette against
# the roof rather than glowing as a whole.
#
# On the overhead set-dressing layer, because the play-following cameras climb
# ABOVE the 22 m rig — GameCamera's zoom tops out at 32 m, the intro crane sits
# at 36, and the camera-distance pref scales both by up to 1.6 — and from up
# there a fixture is a dark slab over the crowd with its lit face pointed away.
func _build_housings() -> void:
	if _housed.is_empty():
		return
	var body_mesh := BoxMesh.new()
	body_mesh.size = HOUSING_SIZE
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = HOUSING_COLOR
	body_mat.roughness = 0.7
	body_mat.metallic = 0.3

	var lens_mesh := BoxMesh.new()
	lens_mesh.size = LENS_SIZE
	_lens_material = StandardMaterial3D.new()
	_lens_material.albedo_color = LENS_COLOR
	_lens_material.emission_enabled = true
	_lens_material.emission = LENS_COLOR
	_lens_material.emission_energy_multiplier = LENS_ENERGY

	for i: int in _housed.size():
		var light: Light3D = _housed[i]
		var fixture := Node3D.new()
		fixture.name = "Fixture%d" % i
		add_child(fixture)
		# The light's own transform, backed off along its aim so the housing sits
		# behind the emitter rather than in the beam.
		fixture.global_transform = light.global_transform
		# +Z is back along the aim, since a spot points down its local −Z.
		fixture.global_position = light.global_position \
				+ light.global_transform.basis.z * HOUSING_DROP

		var body := MeshInstance3D.new()
		body.mesh = body_mesh
		body.material_override = body_mat
		body.layers = RenderLayers.OVERHEAD_DRESSING
		# The rig hangs above everything and casts nothing: it IS the light.
		body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fixture.add_child(body)

		var lens := MeshInstance3D.new()
		lens.mesh = lens_mesh
		lens.material_override = _lens_material
		lens.layers = RenderLayers.OVERHEAD_DRESSING
		lens.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# On the housing's aim face, a hair proud so it never z-fights the body.
		lens.position = Vector3(0.0, 0.0,
				-(HOUSING_SIZE.z + LENS_SIZE.z) * 0.5 - 0.002)
		fixture.add_child(lens)


# Take the house down and build it back over `window_seconds`. Called for the
# opening skate-on and again at each period's, so a period starts on a cue
# rather than at full house.
func play_intro(window_seconds: float) -> void:
	if _lights.is_empty():
		return
	var rise: float = clampf(window_seconds * RISE_FRACTION, 1.0, RISE_TIME_MAX)
	var hold: float = maxf(window_seconds - FALL_TIME - rise - TAIL_S, 0.0)
	_kill_tween()
	_tween = create_tween()
	_tween.tween_method(_set_level, 1.0, HOUSE_LOW, FALL_TIME) \
			.set_trans(Tween.TRANS_SINE)
	if hold > 0.0:
		_tween.tween_interval(hold)
	_tween.tween_method(_set_level, HOUSE_LOW, 1.0, rise) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)


# Put the house back this instant. The cue is timed against an announced window,
# but a skipped intro, a late joiner, or a phase that ends early would otherwise
# leave the building dark with a game running in it — so every exit from the
# intro calls this, and it is safe to call when nothing is playing.
func restore() -> void:
	if _lights.is_empty():
		return
	_kill_tween()
	_set_level(1.0)


# The Environment is a sub-resource of RinkArena.tscn and is NOT local to the
# scene, so its ambient energy is shared by every instance built from it. Left
# dimmed by a teardown mid-cue it would stay dimmed for the rest of the process,
# in a fresh arena that never ran an intro — so going away restores it.
func _exit_tree() -> void:
	restore()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# `level` runs 0 (house down) to 1 (full). Ambient is lifted off the floor
# rather than scaled to it: the spec calls ambient the dominant even fill, and
# taking it to zero flattens the bowl into silhouette.
func _set_level(level: float) -> void:
	for i: int in _lights.size():
		_lights[i].light_energy = _base_energy[i] * level
	if _lens_material != null:
		_lens_material.emission_energy_multiplier = LENS_ENERGY * level
	if _environment != null:
		_environment.ambient_light_energy = _base_ambient * lerpf(AMBIENT_LOW, 1.0, level)
