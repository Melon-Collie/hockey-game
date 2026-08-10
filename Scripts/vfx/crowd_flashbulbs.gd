class_name CrowdFlashbulbs
extends Node3D

# Camera flashes popping in the bowl while the crowd is at a roar — the
# broadcast tell that something big just happened. Driven by the same
# excitement scalar the crowd shader sways to (ArenaStands pushes it in), so
# the bulbs need no signal wiring of their own: goals (excite 1.0) and
# period/game ends (0.7) clear the threshold, the pre-game buzz (0.55) and
# body-check rumbles (≤0.45) stay dark.
#
# A handful of pooled billboard quads, not a particle system: each flash
# must land on an actual seated spectator, and per-flash placement is a
# transform read + a visible flip — a few per frame at peak. Sampling the
# head MultiMesh transforms keeps bulbs out of the empty-seat gaps the
# attendance scatter leaves.

const FLASH_MIN_EXCITEMENT: float = 0.65
# Poisson-ish pop rate across the whole bowl, scaled through the excitement
# band above the threshold.
const FLASH_RATE_MIN: float = 3.0    # flashes/s just past the threshold
const FLASH_RATE_MAX: float = 14.0   # flashes/s at a full goal roar
const FLASH_LIFETIME: float = 0.09   # a bulb pop, not a lamp
const FLASH_POOL: int = 6            # concurrent flashes ceiling (rate × lifetime ≈ 1.3)
const FLASH_SIZE_M: float = 0.22
# Above the RinkArena environment's glow HDR threshold (1.3) so a pop blooms.
const FLASH_EMISSION_ENERGY: float = 8.0
const HEAD_LIFT_M: float = 0.16      # flash held above the head, camera-height

var _quads: Array[MeshInstance3D] = []
var _life: PackedFloat32Array = PackedFloat32Array()
var _head_mms: Array[MultiMesh] = []
var _section_counts: PackedInt32Array = PackedInt32Array()
var _total_heads: int = 0
var _excitement: float = 0.0
var _spawn_accum: float = 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2(FLASH_SIZE_M, FLASH_SIZE_M)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.BLACK
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.98, 0.92)
	mat.emission_energy_multiplier = FLASH_EMISSION_ENERGY
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	quad.material = mat
	_life.resize(FLASH_POOL)
	for i: int in FLASH_POOL:
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visible = false
		add_child(mi)
		_quads.append(mi)
		_life[i] = 0.0


# The per-section head MultiMeshes (ArenaStands-local transforms, this node
# sits at the stands' origin so they can be used directly). Re-handed on
# every stands rebuild since the layout may have changed.
func set_sources(head_mms: Array[MultiMesh]) -> void:
	_head_mms = head_mms
	_section_counts.resize(head_mms.size())
	_total_heads = 0
	for k: int in head_mms.size():
		_section_counts[k] = head_mms[k].instance_count
		_total_heads += head_mms[k].instance_count


func set_excitement(v: float) -> void:
	_excitement = v


func _process(delta: float) -> void:
	var any_alive: bool = false
	for i: int in FLASH_POOL:
		if _life[i] > 0.0:
			_life[i] -= delta
			if _life[i] <= 0.0:
				_quads[i].visible = false
			else:
				any_alive = true

	if CosmeticFreeze.vfx or _excitement < FLASH_MIN_EXCITEMENT or _total_heads == 0:
		if not any_alive:
			_spawn_accum = 0.0
		return

	var band: float = (_excitement - FLASH_MIN_EXCITEMENT) / (1.0 - FLASH_MIN_EXCITEMENT)
	_spawn_accum += delta * lerpf(FLASH_RATE_MIN, FLASH_RATE_MAX, clampf(band, 0.0, 1.0))
	while _spawn_accum >= 1.0:
		_spawn_accum -= 1.0
		_spawn_flash()


func _spawn_flash() -> void:
	# Oldest-slot claim: with rate × lifetime ≈ 1.3 the pool almost never
	# saturates, and stealing the dimmest (oldest) flash is invisible when it does.
	var slot: int = 0
	var min_life: float = _life[0]
	for i: int in FLASH_POOL:
		if _life[i] < min_life:
			min_life = _life[i]
			slot = i
	var head_idx: int = _rng.randi_range(0, _total_heads - 1)
	for k: int in _section_counts.size():
		if head_idx < _section_counts[k]:
			var quad: MeshInstance3D = _quads[slot]
			quad.position = _head_mms[k].get_instance_transform(head_idx).origin \
					+ Vector3(0.0, HEAD_LIFT_M, 0.0)
			var s: float = _rng.randf_range(0.7, 1.3)
			quad.scale = Vector3.ONE * s
			quad.visible = true
			_life[slot] = FLASH_LIFETIME
			return
		head_idx -= _section_counts[k]
