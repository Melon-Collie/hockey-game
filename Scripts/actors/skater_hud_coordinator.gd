class_name SkaterHUDCoordinator
extends RefCounted

# ── HUD geometry constants ────────────────────────────────────────────────────
# Slot ring sits just inside RING_OUTER_R. Charge ring is concentric, just
# outside, with a small gap. Chevron and player name sit below the rings on
# the screen-down side.
const RING_OUTER_R: float        = 0.45
const CHARGE_RING_GAP: float     = 0.02
const CHARGE_RING_OUTER_R: float = 0.49
const CHARGE_RING_INNER_R: float = CHARGE_RING_OUTER_R - 0.04
const _CHARGE_FULL_PULSE_HZ: float = 3.0
const _CHARGE_LOST_FLASH_DURATION: float = 0.35

# Player-name placement — billboarded Label3D just outside the slot ring.
const _NAME_RADIUS: float   = RING_OUTER_R + 0.10
const _CHEVRON_RADIUS: float = RING_OUTER_R + 0.10
const _CHEVRON_OFFSET_DEG: float = 60.0

# Slapper one-timer reticle. All geometry is built in unit (1 m) space;
# _slapper_indicator.scale = (radius, 1, radius) carries the zone radius.
const _SLAPPER_RING_MIN_SCALE: float   = 0.15
const _ARROW_TIP_DISTANCE_UNIT: float  = 1.8
const _ARROW_HEAD_LEN_UNIT: float      = 0.30
const _ARROW_HEAD_HALF_W_UNIT: float   = 0.20
const _ARROW_SHAFT_HALF_W_UNIT: float  = 0.06
const _RETICLE_HALF_LENGTH: float      = 0.06
const _RING_SEGMENTS: int              = 48
const _SLAPPER_HUD_Y: float            = 0.05

# Charge ring shader: angle-mask + tri-color blend. Fill goes clockwise from
# 12 o'clock. UV.x of the procedural ring encodes 0..1 clockwise; fragment
# discards above `fill`. Lost-flash overrides fill color.
const _CHARGE_RING_SHADER_CODE := """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_opaque, cull_disabled;

uniform float fill : hint_range(0.0, 1.0) = 0.0;
uniform float pulse : hint_range(0.0, 1.0) = 0.0;
uniform float lost_flash : hint_range(0.0, 1.0) = 0.0;
uniform vec4 color_low;
uniform vec4 color_high;
uniform vec4 color_full;
uniform vec4 color_lost;
uniform float opacity = 0.7;

void fragment() {
	float t = UV.x;
	if (t > fill && lost_flash < 0.001) {
		discard;
	}
	vec3 base = mix(color_low.rgb, color_high.rgb, clamp(fill, 0.0, 1.0));
	if (pulse > 0.001) {
		base = mix(base, color_full.rgb, pulse);
	}
	if (lost_flash > 0.001) {
		base = mix(base, color_lost.rgb, lost_flash);
	}
	ALBEDO = base;
	ALPHA = opacity * (lost_flash > 0.001 ? lost_flash : 1.0);
}
"""

var _skater: Skater

var _ring_mesh: MeshInstance3D
var _charge_ring_mesh: MeshInstance3D
var _charge_ring_mat: ShaderMaterial
var _chevron_mesh: MeshInstance3D
var _name_label: Label3D

var _slapper_indicator: Node3D
var _slapper_indicator_mat: StandardMaterial3D
var _slapper_reticle_node: MeshInstance3D
var _slapper_arrow_root: Node3D
var _slapper_arrow_mesh: MeshInstance3D
var _slapper_ring_mesh: MeshInstance3D

var _slapper_zone_radius_cached: float = 0.5
var _slapper_current_ring_scale: float = 1.0
var _charge_ring_visible: bool = false
var _charge_lost_flash_timer: float = 0.0


func setup(skater: Skater) -> void:
	_skater = skater

	_ring_mesh = MeshInstance3D.new()
	_ring_mesh.name = "RingIndicator"
	_ring_mesh.mesh = _create_ring_mesh(RING_OUTER_R - MenuStyle.HUD_LINE_THIN, RING_OUTER_R, 48)
	_ring_mesh.position = Vector3.ZERO
	_ring_mesh.material_override = _make_hud_ice_material()
	_skater.add_child(_ring_mesh)

	_charge_ring_mesh = MeshInstance3D.new()
	_charge_ring_mesh.name = "ChargeRing"
	_charge_ring_mesh.mesh = _create_ring_mesh_with_uv(CHARGE_RING_INNER_R, CHARGE_RING_OUTER_R, 64)
	_charge_ring_mat = _make_charge_ring_material()
	_charge_ring_mesh.material_override = _charge_ring_mat
	_charge_ring_mesh.visible = false
	_skater.add_child(_charge_ring_mesh)

	_chevron_mesh = MeshInstance3D.new()
	_chevron_mesh.name = "ElevatedChevron"
	_chevron_mesh.top_level = true
	_chevron_mesh.mesh = _create_chevron_mesh()
	_chevron_mesh.material_override = _make_hud_ice_material()
	_chevron_mesh.visible = false
	_skater.add_child(_chevron_mesh)

	# Player name. Single billboarded Label3D, top-level so its world
	# transform isn't tied to the skater's rotation. Position is rewritten
	# each tick from camera screen-down so it always sits below the ring.
	_name_label = Label3D.new()
	_name_label.name = "PlayerNameLabel"
	_name_label.top_level = true
	_name_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_name_label.no_depth_test = false
	_name_label.fixed_size = false
	_name_label.font_size = 40
	_name_label.outline_size = 0
	_name_label.modulate = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	_name_label.pixel_size = 0.005
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_skater.add_child(_name_label)

	# Slapper one-timer reticle. The parent _slapper_indicator carries the
	# zone offset + radius scale. Arrow + ring share _slapper_arrow_root's
	# rotation so the ring gap stays glued to the arrow tail.
	_slapper_indicator = Node3D.new()
	_slapper_indicator.name = "SlapperIndicator"
	_slapper_indicator.visible = true
	_skater.add_child(_slapper_indicator)
	_slapper_indicator_mat = _make_hud_ice_material()

	_slapper_reticle_node = _create_reticle_mesh(_RETICLE_HALF_LENGTH)
	_slapper_reticle_node.material_override = _slapper_indicator_mat
	_slapper_reticle_node.visible = false
	_slapper_reticle_node.position = Vector3(0.0, _SLAPPER_HUD_Y, 0.0)
	_slapper_indicator.add_child(_slapper_reticle_node)

	_slapper_arrow_root = Node3D.new()
	_slapper_arrow_root.name = "SlapperArrow"
	_slapper_arrow_root.position = Vector3(0.0, _SLAPPER_HUD_Y, 0.0)
	_slapper_indicator.add_child(_slapper_arrow_root)

	_slapper_arrow_mesh = MeshInstance3D.new()
	_slapper_arrow_mesh.material_override = _slapper_indicator_mat
	_slapper_arrow_mesh.visible = false
	_slapper_arrow_root.add_child(_slapper_arrow_mesh)

	_slapper_ring_mesh = MeshInstance3D.new()
	_slapper_ring_mesh.material_override = _slapper_indicator_mat
	_slapper_ring_mesh.visible = false
	_slapper_arrow_root.add_child(_slapper_ring_mesh)

	update_slapper_indicator_convergence(1.0)


func update(delta: float) -> void:
	if _ring_mesh != null:
		_ring_mesh.global_position.y = 0.05
	# Camera-aware screen axes for name + chevron. Falls back to +Z if no camera.
	var screen_down: Vector2 = _hud_screen_down_xz()
	var arc_base_angle: float = atan2(screen_down.x, screen_down.y)
	if _name_label != null and _name_label.visible:
		_name_label.global_position = Vector3(
				_skater.global_position.x + screen_down.x * _NAME_RADIUS,
				0.05,
				_skater.global_position.z + screen_down.y * _NAME_RADIUS)
	if _chevron_mesh != null:
		_chevron_mesh.visible = _skater.is_elevated and not _skater.is_ghost
		if _chevron_mesh.visible:
			var side_sign: float = 1.0 if _skater.is_left_handed else -1.0
			var chevron_angle: float = arc_base_angle + side_sign * deg_to_rad(_CHEVRON_OFFSET_DEG)
			var dir := Vector3(sin(chevron_angle), 0.0, cos(chevron_angle))
			_chevron_mesh.global_position = Vector3(
					_skater.global_position.x + dir.x * _CHEVRON_RADIUS,
					0.05,
					_skater.global_position.z + dir.z * _CHEVRON_RADIUS)
			_chevron_mesh.rotation = Vector3(0.0, arc_base_angle, 0.0)
	if _charge_ring_mesh != null and _charge_ring_mesh.visible:
		_charge_ring_mesh.global_position.y = 0.05
		var pulse_amount: float = 0.0
		if _skater.shot_charge >= 0.999:
			pulse_amount = 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.001 * TAU * _CHARGE_FULL_PULSE_HZ)
		_charge_ring_mat.set_shader_parameter("fill", clampf(_skater.shot_charge, 0.0, 1.0))
		_charge_ring_mat.set_shader_parameter("pulse", pulse_amount)
		var lost_t: float = 0.0
		if _charge_lost_flash_timer > 0.0:
			_charge_lost_flash_timer = maxf(_charge_lost_flash_timer - delta, 0.0)
			lost_t = _charge_lost_flash_timer / _CHARGE_LOST_FLASH_DURATION
		_charge_ring_mat.set_shader_parameter("lost_flash", lost_t)
		# Auto-hide once the lost flash finishes and there's nothing to show.
		if _skater.shot_charge <= 0.001 and lost_t <= 0.001 and not _charge_ring_visible:
			_charge_ring_mesh.visible = false
	if _slapper_indicator != null:
		_slapper_indicator.global_position.y = 0.0


func set_player_name(p_name: String) -> void:
	if _name_label != null:
		_name_label.text = p_name


func set_charge_ring_visible(visible: bool) -> void:
	_charge_ring_visible = visible
	if _charge_ring_mesh != null:
		_charge_ring_mesh.visible = visible or _charge_lost_flash_timer > 0.0


func trigger_charge_lost_flash() -> void:
	_charge_lost_flash_timer = _CHARGE_LOST_FLASH_DURATION
	if _charge_ring_mesh != null:
		_charge_ring_mesh.visible = true


func update_slapper_indicator_convergence(ratio: float) -> void:
	_slapper_current_ring_scale = lerpf(
			_SLAPPER_RING_MIN_SCALE, 1.0, clampf(ratio, 0.0, 1.0))
	_rebuild_slapper_geometry()


func set_slapshot_arrow(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = -1.0) -> void:
	if _slapper_arrow_mesh == null:
		return
	if not active:
		_slapper_arrow_mesh.visible = false
		return
	var r: float = radius if radius > 0.0 else _slapper_zone_radius_cached
	_apply_slapshot_zone_transform(offset_x, offset_z, r)
	_slapper_arrow_mesh.visible = true
	_rebuild_slapper_geometry()


func update_slapshot_arrow_direction(world_dir: Vector3) -> void:
	if _slapper_arrow_root == null or not _slapper_arrow_mesh.visible:
		return
	if world_dir.length() < 0.001:
		return
	var local_dir: Vector3 = _skater.global_transform.basis.inverse() * world_dir
	local_dir.y = 0.0
	if local_dir.length() < 0.001:
		return
	_slapper_arrow_root.rotation.y = atan2(local_dir.x, local_dir.z)


func set_slapper_indicator(active: bool, offset_x: float = 0.0, offset_z: float = 0.0, radius: float = 0.5) -> void:
	if _slapper_ring_mesh == null or _slapper_reticle_node == null:
		return
	if not active:
		_slapper_ring_mesh.visible = false
		_slapper_reticle_node.visible = false
		return
	_apply_slapshot_zone_transform(offset_x, offset_z, radius)
	_slapper_ring_mesh.visible = true
	_slapper_reticle_node.visible = true
	update_slapper_indicator_convergence(1.0)


func set_slapper_indicator_ready(_is_ready: bool) -> void:
	pass


func update_slapper_indicator_window(_t: float) -> void:
	pass


func apply_ghost(ghost: bool) -> void:
	if _ring_mesh != null:
		_ring_mesh.visible = not ghost
	if _name_label != null:
		_name_label.visible = not ghost
	if _charge_ring_mesh != null and ghost:
		_charge_ring_mesh.visible = false
	if ghost:
		if _slapper_arrow_mesh != null:
			_slapper_arrow_mesh.visible = false
		if _slapper_ring_mesh != null:
			_slapper_ring_mesh.visible = false
		if _slapper_reticle_node != null:
			_slapper_reticle_node.visible = false


# ── Private: zone transform ───────────────────────────────────────────────────

func _apply_slapshot_zone_transform(offset_x: float, offset_z: float, radius: float) -> void:
	var blade_side_sign: float = -1.0 if _skater.is_left_handed else 1.0
	_slapper_indicator.position = Vector3(blade_side_sign * offset_x, 0.0, offset_z)
	_slapper_indicator.scale = Vector3(radius, 1.0, radius)
	_slapper_zone_radius_cached = radius
	# Counter-scale the centre crosshair so it stays at fixed world size
	# regardless of the parent indicator's radius scale.
	if _slapper_reticle_node != null:
		var inv: float = 1.0 / max(radius, 0.001)
		_slapper_reticle_node.scale = Vector3(inv, 1.0, inv)


# ── Private: slapper geometry rebuild ────────────────────────────────────────

func _rebuild_slapper_geometry() -> void:
	if _slapper_arrow_mesh == null or _slapper_ring_mesh == null:
		return
	var r: float = _slapper_current_ring_scale
	var w: float = _ARROW_SHAFT_HALF_W_UNIT
	# Counter-scale stroke thickness so lines stay at HUD_LINE_THIN world meters.
	var t_unit: float = MenuStyle.HUD_LINE_THIN / max(_slapper_zone_radius_cached, 0.001)
	var tip_z: float = _ARROW_TIP_DISTANCE_UNIT
	var head_len: float = _ARROW_HEAD_LEN_UNIT
	var head_half_w: float = _ARROW_HEAD_HALF_W_UNIT
	var shoulder_z: float = tip_z - head_len

	# ── Arrow mesh (shaft sides + shoulders + head diagonals) ──
	var arrow_verts := PackedVector3Array()
	var arrow_normals := PackedVector3Array()
	var arrow_indices := PackedInt32Array()
	var shaft_base_z: float = 0.0
	if _slapper_ring_mesh.visible and r > w:
		shaft_base_z = sqrt(r * r - w * w)
	if shaft_base_z < shoulder_z:
		for sign_x: float in [-1.0, 1.0]:
			var shaft_tail := Vector2(sign_x * w, shaft_base_z)
			var shaft_top  := Vector2(sign_x * w, shoulder_z)
			_append_strip(arrow_verts, arrow_normals, arrow_indices, shaft_tail, shaft_top, t_unit)
	var tip := Vector2(0.0, tip_z)
	for sign_x_h: float in [-1.0, 1.0]:
		var shoulder_in  := Vector2(sign_x_h * w, shoulder_z)
		var shoulder_out := Vector2(sign_x_h * head_half_w, shoulder_z)
		_append_strip(arrow_verts, arrow_normals, arrow_indices, shoulder_in, shoulder_out, t_unit)
		_append_strip(arrow_verts, arrow_normals, arrow_indices, shoulder_out, tip, t_unit)
	_slapper_arrow_mesh.mesh = _build_array_mesh(arrow_verts, arrow_normals, arrow_indices)

	# ── Ring mesh (partial-arc annulus with gap on the arrow tail side) ──
	var ring_verts := PackedVector3Array()
	var ring_normals := PackedVector3Array()
	var ring_indices := PackedInt32Array()
	if r > w + t_unit:
		var gap_half: float = asin(clampf(w / r, -1.0, 1.0))
		var sweep_total: float = TAU - 2.0 * gap_half
		var seg_count: int = max(8, int(ceil(_RING_SEGMENTS * sweep_total / TAU)))
		_append_partial_ring(ring_verts, ring_normals, ring_indices,
				r - t_unit, r,
				gap_half, TAU - gap_half, seg_count)
	_slapper_ring_mesh.mesh = _build_array_mesh(ring_verts, ring_normals, ring_indices)


# ── Private: mesh builders ────────────────────────────────────────────────────

func _create_ring_mesh(inner_r: float, outer_r: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for i: int in segments:
		var a0: float = TAU * i / segments
		var a1: float = TAU * (i + 1) / segments
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r))
		verts.append(Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r))
		verts.append(Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r))
		verts.append(Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Bakes a clockwise-from-12-o'clock UV.x onto every vertex so the charge-ring
# shader can use it as an angular fill mask.
func _create_ring_mesh_with_uv(inner_r: float, outer_r: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	for i: int in segments:
		var t0: float = float(i) / float(segments)
		var t1: float = float(i + 1) / float(segments)
		var a0: float = -PI * 0.5 - t0 * TAU
		var a1: float = -PI * 0.5 - t1 * TAU
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r))
		verts.append(Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r))
		verts.append(Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r))
		verts.append(Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r))
		uvs.append(Vector2(t0, 0.0))
		uvs.append(Vector2(t0, 1.0))
		uvs.append(Vector2(t1, 0.0))
		uvs.append(Vector2(t1, 1.0))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Upward-pointing "^" chevron drawn flat on the ice.
func _create_chevron_mesh() -> ArrayMesh:
	var size: float = 0.14
	var leg_len: float = size * 0.7
	var thickness: float = MenuStyle.HUD_LINE_THIN
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var legs: Array = [
		{ "rot": deg_to_rad(135.0), "anchor": Vector3.ZERO },
		{ "rot": deg_to_rad(-135.0), "anchor": Vector3.ZERO },
	]
	for leg: Dictionary in legs:
		var rot_y: float = leg.rot
		var anchor: Vector3 = leg.anchor
		var dir := Vector3(sin(rot_y), 0.0, -cos(rot_y))
		var perp := Vector3(cos(rot_y), 0.0, sin(rot_y))
		var half_t: float = thickness * 0.5
		var p0: Vector3 = anchor + perp * half_t
		var p1: Vector3 = anchor - perp * half_t
		var p2: Vector3 = anchor + dir * leg_len + perp * half_t
		var p3: Vector3 = anchor + dir * leg_len - perp * half_t
		var base: int = verts.size()
		verts.append(p0); verts.append(p1); verts.append(p2); verts.append(p3)
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


# Centre crosshair for the slapper one-timer reticle.
func _create_reticle_mesh(half_len: float) -> MeshInstance3D:
	var thickness: float = MenuStyle.HUD_LINE_THIN
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	var half_t: float = thickness * 0.5
	_append_quad(verts, normals, indices,
			-half_len, -half_t, -half_len, half_t,
			half_len, half_t, half_len, -half_t)
	_append_quad(verts, normals, indices,
			-half_t, -half_len, -half_t, half_len,
			half_t, half_len, half_t, -half_len)
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	return inst


func _build_array_mesh(
		verts: PackedVector3Array,
		normals: PackedVector3Array,
		indices: PackedInt32Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	if verts.size() == 0:
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


func _append_strip(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		a_pt: Vector2, b_pt: Vector2, thickness: float) -> void:
	var edge: Vector2 = b_pt - a_pt
	var edge_len: float = edge.length()
	if edge_len < 0.0001:
		return
	var edge_dir: Vector2 = edge / edge_len
	var edge_perp := Vector2(-edge_dir.y, edge_dir.x)
	var half_t: float = thickness * 0.5
	var p0: Vector2 = a_pt + edge_perp * half_t
	var p1: Vector2 = a_pt - edge_perp * half_t
	var p2: Vector2 = b_pt - edge_perp * half_t
	var p3: Vector2 = b_pt + edge_perp * half_t
	_append_quad(verts, normals, indices,
			p0.x, p0.y, p1.x, p1.y, p2.x, p2.y, p3.x, p3.y)


func _append_partial_ring(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		inner_r: float, outer_r: float,
		start_angle: float, end_angle: float, segments: int) -> void:
	if segments <= 0:
		return
	var sweep: float = end_angle - start_angle
	for i: int in segments:
		var t0: float = float(i) / float(segments)
		var t1: float = float(i + 1) / float(segments)
		var a0: float = start_angle + sweep * t0
		var a1: float = start_angle + sweep * t1
		var s0: float = sin(a0); var c0: float = cos(a0)
		var s1: float = sin(a1); var c1: float = cos(a1)
		var base: int = verts.size()
		verts.append(Vector3(s0 * inner_r, 0.0, c0 * inner_r))
		verts.append(Vector3(s0 * outer_r, 0.0, c0 * outer_r))
		verts.append(Vector3(s1 * inner_r, 0.0, c1 * inner_r))
		verts.append(Vector3(s1 * outer_r, 0.0, c1 * outer_r))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base + 1, base + 3, base + 2])


func _append_quad(
		verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array,
		x0: float, z0: float, x1: float, z1: float,
		x2: float, z2: float, x3: float, z3: float) -> void:
	var base: int = verts.size()
	verts.append(Vector3(x0, 0.0, z0))
	verts.append(Vector3(x1, 0.0, z1))
	verts.append(Vector3(x2, 0.0, z2))
	verts.append(Vector3(x3, 0.0, z3))
	for _n: int in 4:
		normals.append(Vector3.UP)
	indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


func _make_hud_ice_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.albedo_color = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)
	return mat


func _make_charge_ring_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = _CHARGE_RING_SHADER_CODE
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("fill", 0.0)
	mat.set_shader_parameter("pulse", 0.0)
	mat.set_shader_parameter("lost_flash", 0.0)
	mat.set_shader_parameter("color_low", MenuStyle.CHARGE_LOW)
	mat.set_shader_parameter("color_high", MenuStyle.CHARGE_HIGH)
	mat.set_shader_parameter("color_full", MenuStyle.CHARGE_FULL)
	mat.set_shader_parameter("color_lost", MenuStyle.CHARGE_LOST)
	mat.set_shader_parameter("opacity", MenuStyle.HUD_OPACITY)
	return mat


# World XZ direction that maps to "down" on the local player's screen.
func _hud_screen_down_xz() -> Vector2:
	var vp: Viewport = _skater.get_viewport() if _skater != null else null
	var cam: Camera3D = vp.get_camera_3d() if vp != null else null
	if cam == null:
		return Vector2(0.0, 1.0)
	var up_world: Vector3 = cam.global_transform.basis.y
	var down := Vector2(-up_world.x, -up_world.z)
	if down.length_squared() < 0.0001:
		return Vector2(0.0, 1.0)
	return down.normalized()
