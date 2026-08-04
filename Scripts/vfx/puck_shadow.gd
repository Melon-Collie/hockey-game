class_name PuckShadow
extends MeshInstance3D

# EA-NHL-style tracking shadow. The puck's collision disc is small and hard to
# follow at speed, so a soft dark blob is pinned to the ice DIRECTLY BELOW the
# puck. It always stays on the ice plane (straight-down projection), so while an
# airborne puck arcs, the shadow holds on the landing spot and reads like a real
# cast shadow — grows and softens with the puck's height.
#
# Purely cosmetic: driven from _process (render rate, runs on every peer) reading
# the puck's rendered global_position — never gameplay state, never _physics_process.

const ICE_Y: float = 0.004            # just above the ice plane (y=0) to avoid z-fighting
const BASE_RADIUS: float = 0.11       # grounded blob radius — meaningfully wider than the puck disc so it reads as a pool of shadow you can track (not a tight rim that hides under the puck)
const BASE_ALPHA: float = 0.42        # grounded darkness
const AIR_GROW_PER_M: float = 0.55    # extra scale per meter of puck height
const AIR_MAX_SCALE: float = 2.2      # cap so a high pop doesn't balloon the blob
const AIR_FADE_HEIGHT: float = 2.0    # puck height (m) at which the shadow is faintest
const AIR_MIN_ALPHA: float = 0.12     # faintest alpha when high in the air
const _TEX_SIZE: int = 64
# Below this, a per-frame write is invisible and not worth pushing.
const _WRITE_EPSILON: float = 0.001

var _puck: Puck = null
var _mat: StandardMaterial3D = null

func _ready() -> void:
	_puck = get_parent() as Puck
	var quad := QuadMesh.new()
	quad.size = Vector2(BASE_RADIUS * 2.0, BASE_RADIUS * 2.0)
	mesh = quad
	# QuadMesh lies in its local XY plane facing +Z; pitch it flat so it faces up.
	rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	_mat = _make_material()
	material_override = _mat

# Soft radial blob: black with a smooth center→edge alpha falloff. albedo_color
# alpha is animated per-frame to fade the whole blob with puck height.
func _make_material() -> StandardMaterial3D:
	var img := Image.create(_TEX_SIZE, _TEX_SIZE, false, Image.FORMAT_RGBA8)
	for y: int in _TEX_SIZE:
		for x: int in _TEX_SIZE:
			var dx: float = (float(x) + 0.5) / float(_TEX_SIZE) * 2.0 - 1.0
			var dy: float = (float(y) + 0.5) / float(_TEX_SIZE) * 2.0 - 1.0
			var d: float = sqrt(dx * dx + dy * dy)
			# smoothstep gives a soft edge; pow tightens the core so it reads as a shadow.
			var a: float = pow(smoothstep(1.0, 0.0, d), 1.5)
			img.set_pixel(x, y, Color(1.0, 1.0, 1.0, a))
	var tex := ImageTexture.create_from_image(img)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_texture = tex
	# rgb 0 → black; texture alpha × this alpha → the animated falloff. Kept black,
	# the .a is updated each frame in _process.
	mat.albedo_color = Color(0.0, 0.0, 0.0, BASE_ALPHA)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.render_priority = -1  # draw behind the puck / trail dots
	return mat

func _process(_delta: float) -> void:
	if _puck == null:
		return
	# Player-toggleable (Options → Video). Read the live pref each frame so the
	# toggle applies instantly; the read is a single autoload property (no alloc).
	if not PlayerPrefs.puck_shadow_enabled:
		if visible:
			visible = false
		return
	if not visible:
		visible = true
	var puck_pos: Vector3 = _puck.global_position
	# Height of the puck above its resting height (0 when grounded).
	var height: float = maxf(0.0, puck_pos.y - _puck.ice_height)

	# Pin to the ice plane directly below the puck. position is local to the puck;
	# the puck only yaws (angular X/Z axis-locked), so local Y maps to world Y and
	# local X/Z=0 keeps the blob on the puck's vertical axis.
	# A grounded puck holds every value below constant, so the writes are guarded
	# rather than re-pushed each rendered frame (scale and albedo go through to
	# the servers; position dirties the transform).
	var offset_y: float = ICE_Y - puck_pos.y
	if absf(position.y - offset_y) > _WRITE_EPSILON:
		position = Vector3(0.0, offset_y, 0.0)

	# Grow + fade with height so it reads as a cast shadow.
	var s: float = minf(1.0 + AIR_GROW_PER_M * height, AIR_MAX_SCALE)
	if absf(scale.x - s) > _WRITE_EPSILON:
		scale = Vector3(s, s, 1.0)
	var fade: float = clampf(height / AIR_FADE_HEIGHT, 0.0, 1.0)
	var alpha: float = lerpf(BASE_ALPHA, AIR_MIN_ALPHA, fade)
	if absf(_mat.albedo_color.a - alpha) > _WRITE_EPSILON:
		_mat.albedo_color.a = alpha
