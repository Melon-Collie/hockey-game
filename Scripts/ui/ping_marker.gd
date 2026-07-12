class_name PingMarker
extends Node3D

# World-space marker for a location smart ping (GO_THERE): a pulsing ring
# decal flat on the ice with the ping message floating above it. Built
# entirely from code (no scene), self-animating, self-freeing. Spawned by
# GameManager._spawn_ping_marker for the pinger's teammates only.

const _RING_INNER_R: float = 0.55
const _RING_OUTER_R: float = 0.70
const _RING_SEGMENTS: int = 48
const _ICE_Y: float = 0.05          # matches the skater HUD ice-decal height
const _LABEL_HOVER_Y: float = 0.9
const _HOLD_S: float = 2.4          # fully visible
const _FADE_S: float = 0.6          # alpha ramp to 0, then free
const _PULSE_HZ: float = 1.6
const _PULSE_SCALE_MAX: float = 1.18

var _ring_mat: StandardMaterial3D = null
var _label: Label3D = null
var _ring: MeshInstance3D = null
var _age: float = 0.0


static func create(pos: Vector3, text: String) -> PingMarker:
	var marker := PingMarker.new()
	marker.name = "PingMarker"
	marker.position = Vector3(pos.x, 0.0, pos.z)
	marker._build(text)
	return marker


func _build(text: String) -> void:
	_ring_mat = StandardMaterial3D.new()
	_ring_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_ring_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_ring_mat.albedo_color = Color(MenuStyle.HUD_ICE.r, MenuStyle.HUD_ICE.g,
			MenuStyle.HUD_ICE.b, MenuStyle.HUD_OPACITY)

	_ring = MeshInstance3D.new()
	_ring.name = "Ring"
	_ring.mesh = _create_annulus_mesh(_RING_INNER_R, _RING_OUTER_R, _RING_SEGMENTS)
	_ring.material_override = _ring_mat
	_ring.position = Vector3(0.0, _ICE_Y, 0.0)
	add_child(_ring)

	_label = Label3D.new()
	_label.name = "PingText"
	_label.text = text
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_label.no_depth_test = true
	_label.font_size = 44
	_label.outline_size = 10
	_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	_label.pixel_size = 0.005
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.position = Vector3(0.0, _LABEL_HOVER_Y, 0.0)
	add_child(_label)


func _process(delta: float) -> void:
	_age += delta
	if _age >= _HOLD_S + _FADE_S:
		queue_free()
		return
	var pulse_t: float = 0.5 + 0.5 * sin(_age * TAU * _PULSE_HZ)
	var s: float = lerpf(1.0, _PULSE_SCALE_MAX, pulse_t)
	_ring.scale = Vector3(s, 1.0, s)
	if _age > _HOLD_S:
		var a: float = 1.0 - (_age - _HOLD_S) / _FADE_S
		_ring_mat.albedo_color.a = MenuStyle.HUD_OPACITY * a
		_label.modulate.a = a
		_label.outline_modulate.a = 0.85 * a


# Flat annulus in the local XZ plane (an ice decal), same construction as the
# skater HUD's slot ring.
func _create_annulus_mesh(inner_r: float, outer_r: float, segments: int) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for i: int in segments:
		var a0: float = TAU * float(i) / float(segments)
		var a1: float = TAU * float(i + 1) / float(segments)
		var base: int = verts.size()
		verts.append(Vector3(cos(a0) * inner_r, 0.0, sin(a0) * inner_r))
		verts.append(Vector3(cos(a0) * outer_r, 0.0, sin(a0) * outer_r))
		verts.append(Vector3(cos(a1) * outer_r, 0.0, sin(a1) * outer_r))
		verts.append(Vector3(cos(a1) * inner_r, 0.0, sin(a1) * inner_r))
		for _n: int in 4:
			normals.append(Vector3.UP)
		indices.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
