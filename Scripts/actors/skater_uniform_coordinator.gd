class_name SkaterUniformCoordinator
extends RefCounted

# Paints the full skater uniform from a v2 colors dict (see
# TeamColorRegistry.get_colors). Two entry points:
#
#   apply_uniform(colors)        — colors, stripes, text colors, blade
#   apply_jersey_info(name, num) — name + number; re-renders decals
#                                  using cached text colors from apply_uniform
#
# Painting paths:
#   - Torso  → SubViewport + JerseyDecal (base + optional yoke + stripe array
#     + name/number text). One viewport per skater.
#   - Shoulders → shared SubViewport + ShoulderDecal (shoulder base color +
#     shoulder text color/outline; independent of jersey text).
#   - Forearm / upper arm / socks → ImageTexture with horizontal bands stacked
#     in array order; widths shrink to form concentric "centered cross-section"
#     bands (watermelon rind, lime pith).
#   - Pants thighs → ImageTexture with vertical columns positioned by stripe.pos
#     (kept as a vertical side stripe, not a horizontal band — pants are the
#     one region whose stripe.pos refers to U, not V).
#   - Helmet / gloves / cuffs / elbow / hand spheres / hips / knees / skates →
#     solid materials.

# Stick-flex vertex shader — the shaft's per-skater ShaderMaterial wraps it
# (see _make_stick_shaft_mat); Skater drives the flex_m uniform per frame.
# (Stick surface design — shaft paint/wordmark, blade weave — lives in
# StickStyle; this coordinator layers the player's tape job on top.)

var _skater: Skater
var _upper_body_mesh: MeshInstance3D
var _blade_mesh: MeshInstance3D
var _blade_tape: MeshInstance3D                    # team-colored tape band, child of _blade_mesh
var _helmet: MeshInstance3D
var _head: MeshInstance3D                          # skin parts under the helmet shell
var _neck: MeshInstance3D
var _blade_steel_l: MeshInstance3D                 # steel blade children of the boots
var _blade_steel_r: MeshInstance3D
var _laces_l: MeshInstance3D                       # drawn-on lace rungs, boot children
var _laces_r: MeshInstance3D
var _shoulder_l: MeshInstance3D
var _shoulder_r: MeshInstance3D
var _hip_l: MeshInstance3D
var _hip_r: MeshInstance3D
var _thigh_l: MeshInstance3D
var _thigh_r: MeshInstance3D
var _knee_l: MeshInstance3D
var _knee_r: MeshInstance3D
var _sock_l: MeshInstance3D
var _sock_r: MeshInstance3D
var _skate_l: MeshInstance3D
var _skate_r: MeshInstance3D
var _skate_stripe_l: MeshInstance3D                # accent band on each collar
var _skate_stripe_r: MeshInstance3D
var _foot_l: MeshInstance3D
var _foot_r: MeshInstance3D

# Cached jersey + shoulder decal inputs. Both decals are repainted whenever
# either the uniform (apply_uniform) or the name/number (apply_jersey_info)
# changes; the cache lets each entry point trigger a refresh without re-
# supplying the other side's data.
var _jersey_base_color: Color = Color.WHITE
var _jersey_yoke_color: Variant = null            # Color or null
var _jersey_stripes: Array[Dictionary] = []
var _shoulder_color: Color = Color.WHITE
var _shoulder_text_color: Color = Color.BLACK
var _shoulder_outline_color: Color = Color.BLACK
var _player_name: String = ""
var _jersey_number: int = 0
var _text_color: Color = Color.BLACK
var _text_outline_color: Color = Color.BLACK
# Team accent (colors.primary) from the last apply_uniform — what TEAM-palette
# tape picks resolve to, cached so a live tape change repaints without one.
var _team_accent: Color = Color.WHITE
# Kit glove color (uniform.gloves) from the last apply_uniform — what a TEAM
# glove pick resolves to, cached for the same live-repaint reason.
var _kit_gloves: Color = Color.BLACK
var _jersey_viewport: SubViewport
var _jersey_decal: JerseyDecal
var _shoulder_viewport: SubViewport
var _shoulder_decal: ShoulderDecal


func setup(skater: Skater) -> void:
	_skater = skater
	_upper_body_mesh = skater.upper_body.get_node("UpperBodyMesh") as MeshInstance3D
	_blade_mesh = skater.blade.get_node("MeshInstance3D") as MeshInstance3D
	_helmet = skater.upper_body.get_node("Helmet") as MeshInstance3D
	# Created by SkaterMeshBuilder before this setup runs. Never painted
	# (skin and steel, not kit) — resolved only so ghost fades reach them.
	_head = _helmet.get_node_or_null("Head") as MeshInstance3D
	_neck = _helmet.get_node_or_null("Neck") as MeshInstance3D
	_shoulder_l = skater.upper_body.get_node("ShoulderL") as MeshInstance3D
	_shoulder_r = skater.upper_body.get_node("ShoulderR") as MeshInstance3D
	# Leg meshes live under per-leg pivot chains: LowerBody/Leg{L,R} carries the
	# upper-leg meshes, and its ShinL/R child carries the lower-leg meshes. See
	# the Skating Stride block in skater.gd for the full hierarchy.
	_hip_l = skater.lower_body.get_node("LegL/HipL") as MeshInstance3D
	_hip_r = skater.lower_body.get_node("LegR/HipR") as MeshInstance3D
	_thigh_l = skater.lower_body.get_node("LegL/ThighL") as MeshInstance3D
	_thigh_r = skater.lower_body.get_node("LegR/ThighR") as MeshInstance3D
	_knee_l = skater.lower_body.get_node("LegL/KneeL") as MeshInstance3D
	_knee_r = skater.lower_body.get_node("LegR/KneeR") as MeshInstance3D
	_sock_l = skater.lower_body.get_node("LegL/ShinL/SockL") as MeshInstance3D
	_sock_r = skater.lower_body.get_node("LegR/ShinR/SockR") as MeshInstance3D
	_skate_l = skater.lower_body.get_node("LegL/ShinL/SkateL") as MeshInstance3D
	_skate_r = skater.lower_body.get_node("LegR/ShinR/SkateR") as MeshInstance3D
	# Created by SkaterMeshBuilder before this setup runs, like the blade steel.
	_skate_stripe_l = _skate_l.get_node_or_null("Stripe") as MeshInstance3D
	_skate_stripe_r = _skate_r.get_node_or_null("Stripe") as MeshInstance3D
	_foot_l = skater.lower_body.get_node("LegL/ShinL/FootL") as MeshInstance3D
	_foot_r = skater.lower_body.get_node("LegR/ShinR/FootR") as MeshInstance3D
	_blade_steel_l = _foot_l.get_node_or_null("Blade") as MeshInstance3D
	_blade_steel_r = _foot_r.get_node_or_null("Blade") as MeshInstance3D
	# Created by SkaterMeshBuilder with a placeholder white; repainted with
	# the gear style's lace pick on every uniform apply.
	_laces_l = _foot_l.get_node_or_null("Laces") as MeshInstance3D
	_laces_r = _foot_r.get_node_or_null("Laces") as MeshInstance3D
	_create_jersey_viewport()
	_create_shoulder_viewport()


# Spawns the SubViewport + JerseyDecal that renders the procedural jersey
# texture, and points the torso material at the viewport's texture. The
# albedo material is created once here so apply_uniform / apply_jersey_info
# can refresh the texture without recreating the material (which would lose
# ghost-mode transparency state). Same pattern as the rink's center-ice
# decal viewport.
func _create_jersey_viewport() -> void:
	_jersey_viewport = SubViewport.new()
	_jersey_viewport.name = "JerseyViewport"
	_jersey_viewport.size = Vector2i(JerseyDecal.IMG_W, JerseyDecal.IMG_H)
	_jersey_viewport.transparent_bg = false
	_jersey_viewport.disable_3d = true
	_jersey_viewport.handle_input_locally = false
	_jersey_viewport.gui_disable_input = true
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_skater.add_child(_jersey_viewport)

	_jersey_decal = JerseyDecal.new()
	_jersey_decal.name = "JerseyDecal"
	_jersey_viewport.add_child(_jersey_decal)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _jersey_viewport.get_texture()
	mat.roughness = _ROUGH_CLOTH
	# uv1_offset.x = 0.25 rotates the wrap 90° around the cylinder so the
	# texture's back-center (texel x=128) lands at the skater's +Z (back).
	# Godot's CylinderMesh starts U=0 at +Z and increases CCW.
	mat.uv1_offset = Vector3(0.25, 0.0, 0.0)
	BodyRim.apply(mat)
	_upper_body_mesh.material_override = mat


# Shared SubViewport + ShoulderDecal for both shoulder spheres. Sphere U=0 is
# at +Z, so per-shoulder uv1_offset.x rotates the wrap a quarter turn each
# way to face the number outward (-X on left, +X on right).
func _create_shoulder_viewport() -> void:
	_shoulder_viewport = SubViewport.new()
	_shoulder_viewport.name = "ShoulderViewport"
	_shoulder_viewport.size = Vector2i(ShoulderDecal.IMG_W, ShoulderDecal.IMG_H)
	_shoulder_viewport.transparent_bg = false
	_shoulder_viewport.disable_3d = true
	_shoulder_viewport.handle_input_locally = false
	_shoulder_viewport.gui_disable_input = true
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_skater.add_child(_shoulder_viewport)

	_shoulder_decal = ShoulderDecal.new()
	_shoulder_decal.name = "ShoulderDecal"
	_shoulder_viewport.add_child(_shoulder_decal)

	var tex: ViewportTexture = _shoulder_viewport.get_texture()
	var mat_l := StandardMaterial3D.new()
	mat_l.albedo_texture = tex
	mat_l.roughness = _ROUGH_CLOTH
	mat_l.uv1_offset = Vector3(-0.25, 0.0, 0.0)
	BodyRim.apply(mat_l)
	_shoulder_l.material_override = mat_l
	var mat_r := StandardMaterial3D.new()
	mat_r.albedo_texture = tex
	mat_r.roughness = _ROUGH_CLOTH
	mat_r.uv1_offset = Vector3(0.25, 0.0, 0.0)
	BodyRim.apply(mat_r)
	_shoulder_r.material_override = mat_r


# Applies the full v2 colors dict (TeamColorRegistry.get_colors output) to
# every uniform mesh. Reads colors.uniform for kit detail and colors.primary
# for the stick blade; text colors come from colors.text/.text_outline.
func apply_uniform(colors: Dictionary) -> void:
	# Sweep legacy mesh-based stripes from older builds (if a saved scene
	# happens to carry them) so they don't double up with the texture paint.
	for node: Node in _skater.upper_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.upper_body.remove_child(node)
			node.queue_free()
	for node: Node in _skater.lower_body.get_children():
		if node.name.begins_with("Stripe_"):
			_skater.lower_body.remove_child(node)
			node.queue_free()

	var uniform: Dictionary = colors.uniform
	_text_color = colors.text
	_text_outline_color = colors.text_outline

	# Jersey torso (decal repaint).
	_jersey_base_color = uniform.jersey.base
	_jersey_yoke_color = uniform.jersey.yoke
	_jersey_stripes = uniform.jersey.stripes
	_rebuild_jersey_texture()

	# Shoulder caps (decal repaint with shoulder-specific color + text).
	_shoulder_color = uniform.shoulders.color
	_shoulder_text_color = uniform.shoulders.text
	_shoulder_outline_color = uniform.shoulders.outline
	_rebuild_shoulder_texture()

	# Helmet — glossy hard plastic.
	_helmet.material_override = _make_solid_mat(uniform.helmet, _ROUGH_HELMET)

	# Blade — matte black with the player's tape job riding it (palette picks
	# resolve against colors.primary, so TEAM picks track the kit).
	_team_accent = colors.primary
	_rebuild_blade()

	# Stick shaft — near-black composite, satin finish, on the flex vertex
	# shader (Shaders/stick_flex.gdshader). A ShaderMaterial PER SKATER, so
	# one player's shot doesn't bend every stick on the ice;
	# Skater._update_stick_flex drives its flex_m uniform at render rate.
	# Ghost mode swaps this override for a translucent standard mat and
	# rebuilds it on un-ghost — see apply_ghost's stick special case.
	_skater.stick_mesh.material_override = _make_stick_shaft_mat()

	# Butt-end knob — recreated here so the tape color tracks the kit.
	_rebuild_stick_knob()

	# Gloves: the hands wear the kit's glove color; the gear style's glove
	# pick paints only the wrist CUFF rings — the glove's accent stripe
	# (TEAM resolves to the kit color, i.e. no visible stripe).
	_kit_gloves = uniform.gloves
	var gloves_mat: StandardMaterial3D = _make_solid_mat(uniform.gloves)
	if _skater.top_hand_sphere != null:
		_skater.top_hand_sphere.material_override = gloves_mat.duplicate()
	if _skater.bottom_hand_sphere != null:
		_skater.bottom_hand_sphere.material_override = gloves_mat.duplicate()
	_rebuild_glove_cuffs(_resolve_glove_color())

	# Arms — upper + lower bone cylinders, each painted with horizontal
	# stripes (or solid if the stripes array is empty).
	var arms_upper: Dictionary = uniform.arms.upper
	var arms_lower: Dictionary = uniform.arms.lower
	_paint_cylinder_h(_skater.upper_arm_mesh, arms_upper)
	_paint_cylinder_h(_skater.bottom_upper_arm_mesh, arms_upper)
	_paint_cylinder_h(_skater.forearm_mesh, arms_lower)
	_paint_cylinder_h(_skater.bottom_forearm_mesh, arms_lower)

	# Elbow spheres — paint as arms.lower.base so they read as the upper
	# edge of the lower-arm cuff. (Hand spheres above already covered.)
	var elbow_mat: StandardMaterial3D = _make_solid_mat(arms_lower.base)
	if _skater.top_elbow_sphere != null:
		_skater.top_elbow_sphere.material_override = elbow_mat.duplicate()
	if _skater.bottom_elbow_sphere != null:
		_skater.bottom_elbow_sphere.material_override = elbow_mat.duplicate()

	# Pants — vertical side stripes (pants stripe pos is U, width is column
	# thickness; see _make_v_stripes_texture). Hips/knees match pants base.
	var pants_block: Dictionary = uniform.pants
	_paint_pants_thigh(_thigh_l, pants_block, -0.25)
	_paint_pants_thigh(_thigh_r, pants_block, 0.25)
	var pants_solid: StandardMaterial3D = _make_solid_mat(pants_block.base)
	_hip_l.material_override = pants_solid.duplicate()
	_hip_r.material_override = pants_solid.duplicate()
	_knee_l.material_override = pants_solid.duplicate()
	_knee_r.material_override = pants_solid.duplicate()

	# Socks — horizontal stripes on the cylinder side.
	var sock_mat: StandardMaterial3D = _socks_material(uniform.socks)
	_sock_l.material_override = sock_mat
	_sock_r.material_override = sock_mat.duplicate()

	# Skates — the boot and collar stay fixed dark; the gear style's skate
	# pick paints only the collar's accent stripe band (BLACK by default ≈
	# invisible on the dark boot, TEAM resolves to the accent). Set
	# explicitly so ghost mode never leaves a blank gray override behind.
	var skate_mat: StandardMaterial3D = _make_solid_mat(Color(0.08, 0.08, 0.08), _ROUGH_SKATE)
	_skate_l.material_override = skate_mat.duplicate()
	_skate_r.material_override = skate_mat.duplicate()
	_foot_l.material_override = skate_mat.duplicate()
	_foot_r.material_override = skate_mat.duplicate()
	_repaint_skate_stripes()
	_repaint_laces()


# Repaints the jersey + shoulder decals with the new name/number using the
# text colors cached from the last apply_uniform.
func apply_jersey_info(p_name: String, number: int) -> void:
	# Clean up legacy floating decal meshes from older box-geometry builds.
	for child: Node in _skater.upper_body.get_children():
		if child.name in ["JerseyBackMesh", "JerseyShoulderL", "JerseyShoulderR"]:
			_skater.upper_body.remove_child(child)
			child.queue_free()
	_player_name = p_name
	_jersey_number = number
	_rebuild_jersey_texture()
	_rebuild_shoulder_texture()


func _rebuild_jersey_texture() -> void:
	if _jersey_decal == null:
		return
	_jersey_decal.update_jersey(
			_jersey_base_color, _jersey_yoke_color, _jersey_stripes,
			_player_name, _jersey_number, _text_color, _text_outline_color)
	_jersey_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _rebuild_shoulder_texture() -> void:
	if _shoulder_decal == null:
		return
	_shoulder_decal.update_shoulder(
			_shoulder_color, _jersey_number, _shoulder_text_color, _shoulder_outline_color)
	_shoulder_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


# Arm-vs-sock stripe scale. A stripe's `width` is a fraction of the cylinder's
# own side length (see _make_h_stripes_texture), and jerseys author arms and
# socks with the SAME fractions (data/team_colors.json — Dragonfruit/Blueberry
# use identical arrays). But the arm bones render longer than the socks: the
# forearm/upper-arm design length is 0.35 m (Skater.forearm_length /
# upper_arm_length) against the sock cylinder's 0.30 m height (SockL/R in
# Skater.tscn). Both scale together with Size (m_height), so the ratio is fixed.
# Without correction the identical fraction paints a physically taller band on
# the thinner arm — the "arm stripes are too big" mismatch. Shrink the arm
# pattern about its center by the length ratio so an authored width renders at
# the same physical band height on arms as on socks.
const _FOREARM_DESIGN_LEN: float = 0.35   # Skater.forearm_length / upper_arm_length default
const _SOCK_DESIGN_LEN: float = 0.30      # SockL/R CylinderMesh height (Skater.tscn)
const _ARM_STRIPE_SCALE: float = _SOCK_DESIGN_LEN / _FOREARM_DESIGN_LEN


# Paints a bone cylinder (upper or lower arm) with horizontal stripes.
# If the segment has no stripes, uses a solid material instead of building
# a single-color texture — slightly cheaper, and keeps the simple case
# trivially debuggable in the inspector.
func _paint_cylinder_h(bone: Node3D, segment: Dictionary) -> void:
	var visual: MeshInstance3D = _skater.bone_visual(bone)
	if visual == null:
		return
	if segment.stripes.is_empty():
		visual.material_override = _make_solid_mat(segment.base)
		return
	var scaled: Array[Dictionary] = _scale_stripes_about_center(segment.stripes, _ARM_STRIPE_SCALE)
	var tex: ImageTexture = make_h_stripes_texture(segment.base, scaled)
	visual.material_override = _make_texture_material(tex)


# Returns a copy of `stripes` with each band's width and its offset from the
# region center (0.5) multiplied by `scale`, shrinking the whole pattern about
# its center while keeping it centered. Runs on uniform apply, not per tick, so
# the fresh array is not a hot-path concern.
func _scale_stripes_about_center(stripes: Array[Dictionary], scale: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for s: Dictionary in stripes:
		out.append({
			"pos": 0.5 + (float(s.pos) - 0.5) * scale,
			"width": float(s.width) * scale,
			"color": s.color,
		})
	return out


# Paints a single thigh cylinder with vertical side-column stripes. Per-side
# uv1_offset rotates the wrap so the texture's stripe column (centered around
# U=0.5 by convention) lands on each thigh's outer face.
func _paint_pants_thigh(thigh: MeshInstance3D, pants_block: Dictionary, u_offset: float) -> void:
	if pants_block.stripes.is_empty():
		thigh.material_override = _make_solid_mat(pants_block.base)
		return
	var tex: ImageTexture = _make_v_stripes_texture(pants_block.base, pants_block.stripes)
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.uv1_offset = Vector3(u_offset, 0.0, 0.0)
	thigh.material_override = mat


# Returns the sock material — textured if stripes are present, solid otherwise.
func _socks_material(socks_block: Dictionary) -> StandardMaterial3D:
	if socks_block.stripes.is_empty():
		return _make_solid_mat(socks_block.base)
	return _make_texture_material(make_h_stripes_texture(socks_block.base, socks_block.stripes))


# Builds a (4 × height_px) image of horizontal stripe bands over the
# cylinder's side V range. Godot's CylinderMesh allocates roughly V ∈ [0, 0.5]
# of the texture to the side surface (cap disks use [0.5, 1.0]); each stripe's
# pos / width is normalized over that side region. Painted in array order so
# concentric-shrink stacks (Lime, Watermelon, Pomegranate) overprint correctly.
const _CYLINDER_SIDE_V_FRACTION: float = 0.5
const _STRIPE_TEX_HEIGHT_PX: int = 128
const _STRIPE_TEX_WIDTH_PX: int = 4

# Public static so the lobby's bench dummies can dress in the same stripe
# convention without duplicating the band math. `top_cap`, when a Color,
# overpaints the cylinder's NATIVE top-cap UV region (U ∈ [0, 0.5] of the
# caps' V half) — the dummies' stand-in for JerseyDecal's yoke, which paints
# the equivalent region on the real torso (shifted by that material's
# uv1_offset). Meshes whose caps are hidden (socks, arms) leave it null.
static func make_h_stripes_texture(base: Color, stripes: Array[Dictionary],
		top_cap: Variant = null) -> ImageTexture:
	var img := Image.create(_STRIPE_TEX_WIDTH_PX, _STRIPE_TEX_HEIGHT_PX, false, Image.FORMAT_RGBA8)
	img.fill(base)
	var side_px: int = int(round(_CYLINDER_SIDE_V_FRACTION * float(_STRIPE_TEX_HEIGHT_PX)))
	for s: Dictionary in stripes:
		var center_px: float = float(s.pos) * float(side_px)
		var half_px:   float = float(s.width) * float(side_px) * 0.5
		var y0: int = clampi(int(round(center_px - half_px)), 0, side_px)
		var y1: int = clampi(int(round(center_px + half_px)), 0, side_px)
		if y1 > y0:
			img.fill_rect(Rect2i(0, y0, _STRIPE_TEX_WIDTH_PX, y1 - y0), s.color)
	if top_cap is Color:
		img.fill_rect(Rect2i(0, side_px, _STRIPE_TEX_WIDTH_PX / 2,
				_STRIPE_TEX_HEIGHT_PX - side_px), top_cap)
	return ImageTexture.create_from_image(img)


# Builds a (width_px × 4) image of vertical stripe columns. Used by pants:
# each stripe.pos is the U position of the column center, stripe.width is the
# column width. The caller's per-thigh uv1_offset.x lands the centered column
# on the outer face of each leg.
const _PANTS_TEX_WIDTH_PX: int = 128

func _make_v_stripes_texture(base: Color, stripes: Array[Dictionary]) -> ImageTexture:
	var img := Image.create(_PANTS_TEX_WIDTH_PX, _STRIPE_TEX_WIDTH_PX, false, Image.FORMAT_RGBA8)
	img.fill(base)
	for s: Dictionary in stripes:
		var center_px: float = float(s.pos) * float(_PANTS_TEX_WIDTH_PX)
		var half_px:   float = float(s.width) * float(_PANTS_TEX_WIDTH_PX) * 0.5
		var x0: int = clampi(int(round(center_px - half_px)), 0, _PANTS_TEX_WIDTH_PX)
		var x1: int = clampi(int(round(center_px + half_px)), 0, _PANTS_TEX_WIDTH_PX)
		if x1 > x0:
			img.fill_rect(Rect2i(x0, 0, x1 - x0, _STRIPE_TEX_WIDTH_PX), s.color)
	return ImageTexture.create_from_image(img)


# ── Surface finishes ──────────────────────────────────────────────────────────
# Roughness presets so each material reads as its real surface instead of the
# uniform default-plastic look. Metallic stays 0 everywhere (all dielectric);
# the spread in roughness alone separates cloth / plastic / leather / composite.
const _ROUGH_CLOTH: float = 0.9    # jersey, socks, pants, arms, gloves
const _ROUGH_HELMET: float = 0.28  # glossy hard plastic
const _ROUGH_SKATE: float = 0.42   # synthetic boot leather
# (Stick shaft/blade finishes live in StickStyle with the rest of the design;
# the ghost stand-ins below reuse its colors.)


# Subtle rim light on every body part (BodyRim, shared with the goalie so both
# "players" read identically) — a Fresnel edge highlight that makes the rounded
# primitive forms read as lit volumes rather than flat blobs from the top-down
# camera. Applied at the two material factories + the inline viewport-textured
# mats, so it rides every part.
func _make_texture_material(tex: Texture2D, roughness: float = _ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	mat.roughness = roughness
	BodyRim.apply(mat)
	return mat


func _make_solid_mat(color: Color, roughness: float = _ROUGH_CLOTH) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	BodyRim.apply(mat)
	return mat


func _make_stick_shaft_mat() -> ShaderMaterial:
	# StickStyle owns the design (paint + wordmark); the grip wrap is the
	# player's tape job, layered here.
	var mat: ShaderMaterial = StickStyle.make_shaft_material()
	_write_grip_uniforms(mat)
	# Fresh material, default uniforms — the skater's dirty guards must
	# forget their last-written flex/length or they never re-send.
	_skater.notify_shaft_material_rebuilt()
	return mat


# The handle wrap (candy-cane / full grip) is painted by the flex shader from
# the tape job; the wrap color is the knob palette pick.
func _write_grip_uniforms(mat: ShaderMaterial) -> void:
	mat.set_shader_parameter(&"grip_mode", _skater.tape_config.knob_style)
	mat.set_shader_parameter(&"grip_color",
			TapeColorRegistry.resolve(_skater.tape_config.knob_color, _team_accent))


# Dresses the blade in the house carbon weave and (re)builds the tape wrap
# the skater's tape job describes (Skater.tape_config: palette color +
# coverage span). The wrap geometry comes from the skater
# (Skater.build_blade_tape_mesh — overlapping wrap bands of the same
# procedural curved-blade mesh), so it hugs the curve; on a handedness flip
# Skater._rebuild_blade_mesh regenerates the band mesh in place. The cosmetic
# tilt lives on the rig (Skater._apply_blade_tilt); the tape, being a child
# of the blade mesh, inherits it.
func _rebuild_blade() -> void:
	_blade_mesh.material_override = StickStyle.make_blade_material()

	if _blade_tape != null and is_instance_valid(_blade_tape):
		_blade_mesh.remove_child(_blade_tape)
		_blade_tape.queue_free()
	_blade_tape = null
	var tape_mesh: ArrayMesh = _skater.build_blade_tape_mesh()
	if tape_mesh == null:
		return  # bare blade — no tape node at all
	_blade_tape = MeshInstance3D.new()
	_blade_tape.name = "BladeTape"
	_blade_tape.mesh = tape_mesh
	_blade_tape.material_override = _make_solid_mat(
			TapeColorRegistry.resolve(_skater.tape_config.blade_color, _team_accent),
			_ROUGH_CLOTH)
	_blade_mesh.add_child(_blade_tape)


func _resolve_glove_color() -> Color:
	if _skater.gear_style.glove_color == TapeColorRegistry.TEAM_INDEX:
		return _kit_gloves
	return TapeColorRegistry.resolve(_skater.gear_style.glove_color, _kit_gloves)


func _resolve_skate_color() -> Color:
	return TapeColorRegistry.resolve(_skater.gear_style.skate_color, _team_accent)


func _resolve_lace_color() -> Color:
	return TapeColorRegistry.resolve(_skater.gear_style.lace_color, _team_accent)


func _repaint_skate_stripes() -> void:
	var stripe_mat: StandardMaterial3D = _make_solid_mat(_resolve_skate_color(), _ROUGH_SKATE)
	if _skate_stripe_l != null:
		_skate_stripe_l.material_override = stripe_mat.duplicate()
	if _skate_stripe_r != null:
		_skate_stripe_r.material_override = stripe_mat.duplicate()


func _repaint_laces() -> void:
	var lace_mat: StandardMaterial3D = _make_solid_mat(_resolve_lace_color())
	if _laces_l != null:
		_laces_l.material_override = lace_mat.duplicate()
	if _laces_r != null:
		_laces_r.material_override = lace_mat.duplicate()


# Repaints the gear-style accents (glove cuff rings, skate collar bands,
# laces) for a live gear-color change without touching the rest of the
# uniform. Same live-cosmetic contract as refresh_tape below.
func refresh_gear_style() -> void:
	_rebuild_glove_cuffs(_resolve_glove_color())
	_repaint_skate_stripes()
	_repaint_laces()


# Re-renders the tape-colored pieces (blade wrap, knob, handle-wrap paint) for
# a live tape-job change without touching the rest of the uniform. Safe before
# the first apply_uniform — the accent default just gets repainted when it
# lands. The shaft write skips the ghost window (a plain translucent standard
# mat holds the override there); un-ghost rebuilds the shader mat from the
# live config anyway.
func refresh_tape() -> void:
	_rebuild_blade()
	_rebuild_stick_knob()
	var shaft_mat: ShaderMaterial = _skater.stick_mesh.material_override as ShaderMaterial
	if shaft_mat != null:
		_write_grip_uniforms(shaft_mat)


# (Re)builds the butt-end knob cylinder, stored on the skater so update_stick_mesh
# rides it on the shaft each tick. Recreated per uniform so the knob's tape color
# tracks kit changes — same pattern as the glove cuffs.
func _rebuild_stick_knob() -> void:
	var color: Color = TapeColorRegistry.resolve(
			_skater.tape_config.knob_color, _team_accent)
	if _skater.stick_knob_mesh != null and is_instance_valid(_skater.stick_knob_mesh):
		_skater.upper_body.remove_child(_skater.stick_knob_mesh)
		_skater.stick_knob_mesh.queue_free()
	_skater.stick_knob_mesh = null
	var m := MeshInstance3D.new()
	m.name = "StickKnob"
	m.mesh = SkaterMeshBuilder.shared_knob()
	m.material_override = _make_solid_mat(color, _ROUGH_CLOTH)
	_skater.stick_knob_mesh = m
	_skater.upper_body.add_child(m)


func _rebuild_glove_cuffs(gloves_color: Color) -> void:
	if _skater.top_cuff_mesh != null and is_instance_valid(_skater.top_cuff_mesh):
		_skater.upper_body.remove_child(_skater.top_cuff_mesh)
		_skater.top_cuff_mesh.queue_free()
	_skater.top_cuff_mesh = null
	if _skater.bot_cuff_mesh != null and is_instance_valid(_skater.bot_cuff_mesh):
		_skater.upper_body.remove_child(_skater.bot_cuff_mesh)
		_skater.bot_cuff_mesh.queue_free()
	_skater.bot_cuff_mesh = null
	# Scaled by the Hands forearm bulk so the cuff stays proud of the forearm
	# cylinder it wraps — equal radii z-fight (see Skater.forearm_visual_mult).
	var cuff_radius: float = _skater.arm_mesh_thickness * 0.6 * _skater.forearm_visual_mult
	_skater.top_cuff_mesh = _make_glove_cuff_mesh(cuff_radius, gloves_color, "CuffTop")
	_skater.upper_body.add_child(_skater.top_cuff_mesh)
	_skater.bot_cuff_mesh = _make_glove_cuff_mesh(cuff_radius, gloves_color, "CuffBot")
	_skater.upper_body.add_child(_skater.bot_cuff_mesh)


# The shared cuff ring is unit-radius with its height baked (the wrist
# placement in Skater._update_cuff_transform reads CUFF_HEIGHT_M), so the
# radius rides node scale — same contract as the rest of the arm rig.
func _make_glove_cuff_mesh(radius: float, color: Color, mesh_name: String) -> MeshInstance3D:
	var m := MeshInstance3D.new()
	m.name = mesh_name
	m.mesh = SkaterMeshBuilder.shared_cuff()
	m.scale = Vector3(radius, 1.0, radius)
	m.material_override = _make_solid_mat(color)
	return m


func apply_ghost(ghost: bool) -> void:
	# The stick shaft and blade are handled apart from the loop: their
	# overrides are ShaderMaterials (flex/brand, carbon weave), which the
	# StandardMaterial3D cast below can't see — the loop would replace them
	# with a default (WHITE) material and the un-ghost pass would then restore
	# that white mat to full alpha, leaving the stick white forever after the
	# first offside. Swap in colored translucent standard mats while ghosted
	# (the flex driver no-ops on a non-ShaderMaterial override by design) and
	# rebuild the real design materials on un-ghost.
	if ghost:
		var stick_ghost: StandardMaterial3D = _make_solid_mat(
				StickStyle.SHAFT_COLOR, StickStyle.SHAFT_ROUGHNESS)
		stick_ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		stick_ghost.albedo_color.a = 0.3
		_skater.stick_mesh.material_override = stick_ghost
		var blade_ghost: StandardMaterial3D = _make_solid_mat(StickStyle.BLADE_COLOR, 0.5)
		blade_ghost.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		blade_ghost.albedo_color.a = 0.3
		_blade_mesh.material_override = blade_ghost
	else:
		_skater.stick_mesh.material_override = _make_stick_shaft_mat()
		_blade_mesh.material_override = StickStyle.make_blade_material()
	var meshes: Array[MeshInstance3D] = [
			_upper_body_mesh, _blade_tape,
			_skater.stick_knob_mesh,
			_skater.bone_visual(_skater.upper_arm_mesh),
			_skater.bone_visual(_skater.forearm_mesh),
			_skater.bone_visual(_skater.bottom_upper_arm_mesh),
			_skater.bone_visual(_skater.bottom_forearm_mesh),
			_skater.top_elbow_sphere, _skater.top_hand_sphere,
			_skater.bottom_elbow_sphere, _skater.bottom_hand_sphere,
			_helmet, _head, _neck, _shoulder_l, _shoulder_r,
			_hip_l, _hip_r, _thigh_l, _thigh_r,
			_knee_l, _knee_r, _sock_l, _sock_r,
			_skate_l, _skate_r, _foot_l, _foot_r,
			_skate_stripe_l, _skate_stripe_r,
			_blade_steel_l, _blade_steel_r,
			_laces_l, _laces_r,
			_skater.top_cuff_mesh, _skater.bot_cuff_mesh,
		]
	for mesh: MeshInstance3D in meshes:
		if mesh == null:
			continue
		var mat: StandardMaterial3D = mesh.material_override as StandardMaterial3D
		if mat == null:
			mat = StandardMaterial3D.new()
			mesh.material_override = mat
		if ghost:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mat.albedo_color.a = 0.3
		else:
			mat.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mat.albedo_color.a = 1.0
