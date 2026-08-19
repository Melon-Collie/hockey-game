@tool
class_name HockeyGoal
extends Node3D

signal goal_scored

var vfx: GoalVFX = null

# Hockey goal approximation. From top-down the footprint is a rectangle. The
# side profile is a trapezoid (top sloping down from the crossbar to the back
# of the crown). Red pipe forms the goal mouth (U) and the ice-level skirt
# (three-sided rounded rectangle on the ice). White pipe forms the top crown
# (three-sided rounded rectangle at crossbar height, inset from the posts).
# All values in metres. NHL regulation dimensions (rulebook: 40" deep base).

const GOAL_WIDTH: float         = 1.83    # 72" opening width
const NET_HEIGHT: float         = 1.22    # 48" post height
const BASE_DEPTH: float         = GameRules.NET_DEPTH  # 40" (NHL rulebook), single-sourced
const TOP_DEPTH: float          = 0.559   # 22" top shelf depth
const POST_RADIUS: float        = 0.030   # 2 3/8" OD pipe

const MOUTH_CORNER_RADIUS: float = 0.10   # post-to-crossbar bend
const SKIRT_CORNER_RADIUS: float = 0.15   # back corners of ice skirt
const CROWN_CORNER_RADIUS: float = 0.10   # back corners of top crown

const POST_HALF_WIDTH: float    = GOAL_WIDTH / 2.0              # 0.915
const CROWN_HALF_WIDTH: float   = POST_HALF_WIDTH - MOUTH_CORNER_RADIUS  # 0.815

const BEND_SEGMENTS: int        = 6       # curve tessellation per quarter bend
const PIPE_RADIAL_SEGMENTS: int = 8

# Net mesh texture: seamless diamond grid.
# Each tile of the texture covers NET_TEXTURE_TILE_SIZE x NET_TEXTURE_TILE_SIZE metres
# of world space. The texture is 4 diamonds wide per tile, so each diamond is
# NET_TEXTURE_TILE_SIZE / 4 metres across — currently 0.041 m (NHL regulation mesh).
const NET_TEXTURE_PATH: String    = "res://Assets/textures/net_diamond.png"
const NET_TEXTURE_TILE_SIZE: float = 0.164  # 4 diamonds × 41mm each

# All net panels share one ShaderMaterial (goal_net.gdshader) so an impact is a
# single uniform write for the whole cage. Rebuilt per _rebuild().
const NET_SHADER_PATH: String = "res://Shaders/goal_net.gdshader"

# Live impacts the twine is still settling from. Four is enough for a scramble
# in the crease — a fifth contact inside 0.7 s evicts the oldest, which by then
# has decayed to near nothing anyway.
const MAX_IMPACTS: int = 4
# 4 × the shader's DECAY_TAU: past here the envelope is under 6% of peak and
# the panel is visually at rest. Must stay in step with goal_net.gdshader —
# test_goal_net_impacts.gd holds the pair.
const IMPACT_LIFETIME: float = 0.7
# Peak bulge per m/s of closing speed, and the ceiling it saturates at. A hard
# shot buries about 18 cm of twine; the cap is what stops a freak deflection
# speed from turning the mesh inside out.
const IMPACT_METRES_PER_MPS: float = 0.006
const IMPACT_MAX_BULGE: float = 0.20
# Gaussian falloff radius of a puck strike. About a stick-blade's width of
# twine moves with the disc, which is what a struck net does.
const IMPACT_RADIUS: float = 0.45
# The goal celebration is the same displacement path, registered as one wide,
# deep impact rather than a second uniform: the whole cage shakes at once.
const CELEBRATION_BULGE: float = 0.22
const CELEBRATION_RADIUS: float = 1.20

# Goal lamp fixture placement: seated on the top edge of the end glass behind
# this net (glass tops out around 2.9 m — wall 1.07 + glass 1.83). Height is
# the base cylinder's center, so its underside rests flush on the glass top;
# zero outward offset centers the fixture on the board perimeter line, which
# is also the glass centerline.
const LAMP_HEIGHT: float = 2.95
const LAMP_BEHIND_BOARDS: float = 0.0

var defending_team_id: int = -1  # set by GameManager when goals are assigned to teams
var _net_material: ShaderMaterial = null  # shared across all net panels; every impact writes it once

# Impact ring buffer, mirroring goal_net.gdshader's two uniform arrays.
# xyz = origin (world), w = signed peak displacement; then x = start time,
# y = falloff radius. Kept as members and written in place so a contact costs
# two uniform writes and no allocation.
var _impact_origin_amp := PackedVector4Array()
var _impact_start_radius := PackedVector4Array()
var _impact_dir := PackedVector4Array()
var _impact_next: int = 0
# Clock the shader reads impact ages against, advanced only while the twine is
# still moving — see _process.
var _net_time: float = 0.0
var _impacts_live_until: float = -1.0


# The actual world-Z of this goal's goal line. The HockeyGoal *node* sits at
# scene origin — geometry is built procedurally around `goal_z = facing *
# (rink_length / 2.0 - distance_from_end)` inside _rebuild(). Callers that
# need the goal-line position (replay camera placement, on-ice VFX, etc.)
# read this instead of `global_position.z`, which is always 0.
func goal_line_z() -> float:
	return facing * (rink_length / 2.0 - distance_from_end)

# +1 for positive-Z end (Team 0 defends), -1 for negative-Z end (Team 1 defends)
@export var facing: int = 1:
	set(v):
		facing = v
		_rebuild()
@export var distance_from_end: float = 3.35:
	set(v):
		distance_from_end = v
		_rebuild()
@export var rink_length: float = 60.0:
	set(v):
		rink_length = v
		_rebuild()
@export var post_color: Color = Color(0.784, 0.063, 0.180):
	set(v):
		post_color = v
		_rebuild()
@export var crown_color: Color = Color(0.95, 0.95, 0.95):
	set(v):
		crown_color = v
		_rebuild()
@export var net_color: Color = Color(0.8, 0.8, 0.8, 1.0):  # tint for the diamond mesh texture
	set(v):
		net_color = v
		_rebuild()
@export var rebuild: bool = false:
	set(v):
		_rebuild()

func _ready() -> void:
	_rebuild()

func _rebuild() -> void:
	# A saved scene carrying a property under a name this script no longer
	# declares reads back Nil rather than a Color; fall back to the default.
	if typeof(crown_color) != TYPE_COLOR:
		crown_color = Color(0.95, 0.95, 0.95)
	if typeof(post_color) != TYPE_COLOR:
		post_color = Color(0.784, 0.063, 0.180)
	if typeof(net_color) != TYPE_COLOR:
		net_color = Color(0.8, 0.8, 0.8, 1.0)

	for child in get_children():
		child.queue_free()

	var goal_z: float = facing * (rink_length / 2.0 - distance_from_end)
	_net_material = _make_net_material()
	_net_material.set_shader_parameter(&"cavity_center", _cavity_center(goal_z))
	_reset_impacts()
	_build_mouth(goal_z)
	_build_skirt(goal_z)
	_build_crown(goal_z)
	_build_back_support(goal_z)
	_build_net_panels(goal_z)

	var goal_vfx := GoalVFX.new()
	goal_vfx.name = "GoalVFX"
	goal_vfx.position = Vector3(0.0, NET_HEIGHT / 2.0, goal_z)
	add_child(goal_vfx)
	vfx = goal_vfx
	# GoalVFX is not a @tool script, so only drive it at game runtime.
	if not Engine.is_editor_hint():
		var lamp_world := Vector3(0.0, LAMP_HEIGHT, facing * (rink_length / 2.0 + LAMP_BEHIND_BOARDS))
		goal_vfx.setup(shake_for_goal, lamp_world - goal_vfx.position)


# --------------------------------------------------------------------------
# RED MOUTH — U-shape: two posts + crossbar with rounded corners at the top.
# Each post runs from y=0 to y=(NET_HEIGHT - MOUTH_CORNER_RADIUS), then bends
# inward over a quarter torus, then the crossbar spans between the two bends.
# --------------------------------------------------------------------------
func _build_mouth(goal_z: float) -> void:
	var post_top_y: float = NET_HEIGHT - MOUTH_CORNER_RADIUS
	var post_height: float = post_top_y  # post stands from ice to where the bend begins

	# Two vertical posts
	for post_x: float in [-POST_HALF_WIDTH, POST_HALF_WIDTH]:
		_add_cylinder(
			Vector3(post_x, post_height / 2.0, goal_z),
			Basis(),
			post_height,
			POST_RADIUS,
			post_color
		)

	# Crossbar: spans between the two bend end-points at the top.
	# Each bend consumes MOUTH_CORNER_RADIUS of horizontal span, so crossbar
	# runs from -CROWN_HALF_WIDTH to +CROWN_HALF_WIDTH.
	var crossbar_len: float = CROWN_HALF_WIDTH * 2.0
	var crossbar_basis := Basis(Vector3(0, 0, 1), PI / 2.0)
	_add_cylinder(
		Vector3(0.0, NET_HEIGHT, goal_z),
		crossbar_basis,
		crossbar_len,
		POST_RADIUS,
		post_color
	)

	# Two mouth-corner bends (quarter torus each).
	# For each side, the bend connects:
	#   - the top of the post (at x=side*POST_HALF_WIDTH, y=post_top_y)
	#   - the end of the crossbar (at x=side*CROWN_HALF_WIDTH, y=NET_HEIGHT)
	# The bend curves through the corner, with its center at
	# (side*CROWN_HALF_WIDTH, post_top_y) — i.e., directly above the end of
	# the crossbar and directly inward from the top of the post.
	for side: float in [-1.0, 1.0]:
		var center := Vector3(side * CROWN_HALF_WIDTH, post_top_y, goal_z)
		# Bend starts at the top of the post: offset (+side*MOUTH_CORNER_RADIUS, 0, 0) from center
		# Bend ends at the crossbar end:     offset (0, +MOUTH_CORNER_RADIUS, 0) from center
		var start_offset := Vector3(side * MOUTH_CORNER_RADIUS, 0.0, 0.0)
		var end_offset := Vector3(0.0, MOUTH_CORNER_RADIUS, 0.0)
		_add_quarter_bend(center, start_offset, end_offset, post_color)


# --------------------------------------------------------------------------
# RED SKIRT — three-sided rounded rectangle on the ice.
# Left rail runs from post base backward; rounded back-left corner; back
# rail across the back; rounded back-right corner; right rail forward to
# the other post base. Sits at y = POST_RADIUS (center of pipe on the ice).
# --------------------------------------------------------------------------
func _build_skirt(goal_z: float) -> void:
	var y: float = POST_RADIUS
	var back_z: float = goal_z + facing * BASE_DEPTH
	# The two back corners sit SKIRT_CORNER_RADIUS in from the back and
	# SKIRT_CORNER_RADIUS in from each side. Straight rail sections connect
	# the post bases to the corner start-points.
	var corner_z_offset: float = SKIRT_CORNER_RADIUS
	var corner_x_offset: float = SKIRT_CORNER_RADIUS

	# Each side: straight rail from post base to the start of the corner bend.
	var rail_start_z: float = goal_z
	var rail_end_z: float = back_z - facing * corner_z_offset
	var rail_len: float = abs(rail_end_z - rail_start_z)
	var rail_mid_z: float = (rail_start_z + rail_end_z) / 2.0

	for side: float in [-1.0, 1.0]:
		# Side rail along Z axis
		var rail_x: float = side * POST_HALF_WIDTH
		var rail_basis := Basis(Vector3(1, 0, 0), PI / 2.0)
		_add_cylinder(
			Vector3(rail_x, y, rail_mid_z),
			rail_basis,
			rail_len,
			POST_RADIUS,
			post_color
		)

		# Corner bend in the X-Z plane at y = POST_RADIUS.
		# Connects side rail end (coming from the front) to back rail end.
		var corner_center_x: float = side * (POST_HALF_WIDTH - corner_x_offset)
		var corner_center_z: float = back_z - facing * corner_z_offset
		var corner_center := Vector3(corner_center_x, y, corner_center_z)
		# Start: where the side rail ends — offset (side*r, 0, 0) from center
		# End:   where the back rail ends on this side — offset (0, 0, facing*r) from center
		var start_offset := Vector3(side * SKIRT_CORNER_RADIUS, 0.0, 0.0)
		var end_offset := Vector3(0.0, 0.0, facing * SKIRT_CORNER_RADIUS)
		_add_quarter_bend(corner_center, start_offset, end_offset, post_color)

	# Back rail along X axis, spanning between the two corner end-points
	var back_rail_len: float = (POST_HALF_WIDTH - corner_x_offset) * 2.0
	var back_rail_basis := Basis(Vector3(0, 0, 1), PI / 2.0)
	_add_cylinder(
		Vector3(0.0, y, back_z),
		back_rail_basis,
		back_rail_len,
		POST_RADIUS,
		post_color
	)


# --------------------------------------------------------------------------
# WHITE CROWN — three-sided rounded rectangle at crossbar height, inset
# from the posts by MOUTH_CORNER_RADIUS (so it tucks inside the rounded
# top corners of the mouth). Depth = TOP_DEPTH (shorter than BASE_DEPTH).
# Attaches to the inside face of each post at y = NET_HEIGHT.
# --------------------------------------------------------------------------
func _build_crown(goal_z: float) -> void:
	var y: float = NET_HEIGHT
	var back_z: float = goal_z + facing * TOP_DEPTH
	var corner_z_offset: float = CROWN_CORNER_RADIUS
	var corner_x_offset: float = CROWN_CORNER_RADIUS

	var rail_start_z: float = goal_z
	var rail_end_z: float = back_z - facing * corner_z_offset
	var rail_len: float = abs(rail_end_z - rail_start_z)
	var rail_mid_z: float = (rail_start_z + rail_end_z) / 2.0

	for side: float in [-1.0, 1.0]:
		var rail_x: float = side * CROWN_HALF_WIDTH
		var rail_basis := Basis(Vector3(1, 0, 0), PI / 2.0)
		_add_cylinder(
			Vector3(rail_x, y, rail_mid_z),
			rail_basis,
			rail_len,
			POST_RADIUS,
			crown_color
		)

		var corner_center_x: float = side * (CROWN_HALF_WIDTH - corner_x_offset)
		var corner_center_z: float = back_z - facing * corner_z_offset
		var corner_center := Vector3(corner_center_x, y, corner_center_z)
		var start_offset := Vector3(side * CROWN_CORNER_RADIUS, 0.0, 0.0)
		var end_offset := Vector3(0.0, 0.0, facing * CROWN_CORNER_RADIUS)
		_add_quarter_bend(corner_center, start_offset, end_offset, crown_color)

	var back_rail_len: float = (CROWN_HALF_WIDTH - corner_x_offset) * 2.0
	var back_rail_basis := Basis(Vector3(0, 0, 1), PI / 2.0)
	_add_cylinder(
		Vector3(0.0, y, back_z),
		back_rail_basis,
		back_rail_len,
		POST_RADIUS,
		crown_color
	)


# --------------------------------------------------------------------------
# BACK SUPPORT — single slanted bar running from the center of the crown's
# back rail down to the center of the skirt's back rail. Matches crown color.
# Since TOP_DEPTH < BASE_DEPTH, the bar tilts backward going down.
# --------------------------------------------------------------------------
func _build_back_support(goal_z: float) -> void:
	var top_point := Vector3(0.0, NET_HEIGHT, goal_z + facing * TOP_DEPTH)
	var bot_point := Vector3(0.0, POST_RADIUS, goal_z + facing * BASE_DEPTH)
	var mid: Vector3 = (top_point + bot_point) / 2.0
	var dir: Vector3 = (top_point - bot_point).normalized()
	var length: float = top_point.distance_to(bot_point)
	var cyl_basis: Basis = _basis_from_up(dir)
	_add_cylinder(mid, cyl_basis, length, POST_RADIUS, crown_color)


# --------------------------------------------------------------------------
# NET PANELS — four translucent faces approximated as thin rotated boxes.
# Mesh only; the puck's carom off them is analytic (PuckGeometryCollision).
#
# The side panels take their X from POST_HALF_WIDTH even though the crown is inset
# by MOUTH_CORNER_RADIUS at the top, so they run straight vertically at the post
# line; the small inset at the top-back corner is accepted as visual slack.
#
# The four panels:
#   1. TOP — horizontal rectangle, crossbar to crown back rail. Flat, at y=NET_HEIGHT.
#   2. BACK — slanted rectangle, crown back rail (top/near) to skirt back rail (bottom/far).
#   3. SIDE (left) — right-triangle-ish panel in the Y-Z plane at x=-POST_HALF_WIDTH.
#      Corners: post base, post top, crown back corner, skirt back corner.
#      Approximated as a flat vertical rectangle that matches the side profile.
#   4. SIDE (right) — mirror of left.
#
# The side panels are true right trapezoids (seen from outside the goal): vertical
# front edge = NET_HEIGHT, flat bottom along the ice for BASE_DEPTH, slanted top
# going from post-top down to skirt-back-bottom. We approximate the whole trapezoid
# as a single flat box tilted to match the slant. Since the slant angle is gentle
# and the panel is thin, this reads as a slanted side face with minimal visual
# error at the front-top and back-bottom corners.
# --------------------------------------------------------------------------
func _build_net_panels(goal_z: float) -> void:
	var back_z_top: float = goal_z + facing * TOP_DEPTH   # back edge of crown (top)
	var back_z_bot: float = goal_z + facing * BASE_DEPTH  # back edge of skirt (bottom)

	# --- 1. TOP panel ---
	# Flat horizontal rectangle at y = NET_HEIGHT. Inset to crown width since
	# the top face of the goal is bounded by the crossbar + crown rails.
	#   Corners (going around):
	#     front-left:  (-CROWN_HALF_WIDTH, NET_HEIGHT, goal_z)
	#     front-right: (+CROWN_HALF_WIDTH, NET_HEIGHT, goal_z)
	#     back-right:  (+CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
	#     back-left:   (-CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
	_add_net_quad(
		Vector3(-CROWN_HALF_WIDTH, NET_HEIGHT, goal_z),
		Vector3( CROWN_HALF_WIDTH, NET_HEIGHT, goal_z),
		Vector3( CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),
		Vector3(-CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),
		goal_z
	)

	# --- 2. BACK panel ---
	# Slanted quad. Top edge at crown width + crown depth, bottom edge at
	# skirt width + skirt depth. The fact that the top edge is narrower than
	# the bottom edge means this is a trapezoid, not a rectangle.
	_add_net_quad(
		Vector3(-CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),  # top-left
		Vector3( CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),  # top-right
		Vector3( POST_HALF_WIDTH,  0.0,        back_z_bot),  # bottom-right
		Vector3(-POST_HALF_WIDTH,  0.0,        back_z_bot),  # bottom-left
		goal_z
	)

	# --- 3 & 4. SIDE panels (right trapezoids, vertical at ±POST_HALF_WIDTH) ---
	#   A front-bottom: (side*POST_HALF_WIDTH, 0,          goal_z)
	#   B front-top:    (side*POST_HALF_WIDTH, NET_HEIGHT, goal_z)
	#   C back-top:     (side*POST_HALF_WIDTH, NET_HEIGHT, back_z_top)
	#   D back-bottom:  (side*POST_HALF_WIDTH, 0,          back_z_bot)
	for side: float in [-1.0, 1.0]:
		var x: float = side * POST_HALF_WIDTH
		_add_net_quad(
			Vector3(x, 0.0,        goal_z),
			Vector3(x, NET_HEIGHT, goal_z),
			Vector3(x, NET_HEIGHT, back_z_top),
			Vector3(x, 0.0,        back_z_bot),
			goal_z
		)

	# --- 5 & 6. CROWN-TO-SIDE gusset rectangles (horizontal, at y=NET_HEIGHT) ---
	# Fills the horizontal gap on the TOP plane between the post line and the
	# crown line. This is a full rectangle — not a triangle — because the
	# crown attaches to the post at the FRONT as well as curving back. Corners:
	#   R1: post top (front)      (side*POST_HALF_WIDTH,  NET_HEIGHT, goal_z)
	#   R2: crown-post junction   (side*CROWN_HALF_WIDTH, NET_HEIGHT, goal_z)
	#   R3: crown back corner     (side*CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
	#   R4: side panel back-top   (side*POST_HALF_WIDTH,  NET_HEIGHT, back_z_top)
	for side: float in [-1.0, 1.0]:
		var r1 := Vector3(side * POST_HALF_WIDTH,  NET_HEIGHT, goal_z)
		var r2 := Vector3(side * CROWN_HALF_WIDTH, NET_HEIGHT, goal_z)
		var r3 := Vector3(side * CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
		var r4 := Vector3(side * POST_HALF_WIDTH,  NET_HEIGHT, back_z_top)
		_add_net_quad(r1, r2, r3, r4, goal_z)

	# --- 7 & 8. BACK-SIDE gusset triangles (vertical-ish, closes side↔back seam) ---
	# The side panel has its back edge at x=±POST_HALF_WIDTH, but the back
	# panel's side edge at the TOP is at x=±CROWN_HALF_WIDTH (crown-inset).
	# That leaves a triangular gap on each back-side corner. Corners:
	#   Q1: skirt back corner    (side*POST_HALF_WIDTH,  0,          back_z_bot)
	#   Q2: crown back corner    (side*CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
	#   Q3: side panel back-top  (side*POST_HALF_WIDTH,  NET_HEIGHT, back_z_top)
	# Note Q1 is shared with the back panel's bottom-side corner; Q2 is shared
	# with the back panel's top-side corner; Q3 is shared with the horizontal
	# gusset above. All three panels meet cleanly at these shared corners.
	for side: float in [-1.0, 1.0]:
		var q1 := Vector3(side * POST_HALF_WIDTH,  0.0,        back_z_bot)
		var q2 := Vector3(side * CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
		var q3 := Vector3(side * POST_HALF_WIDTH,  NET_HEIGHT, back_z_top)
		_add_net_tri(q1, q2, q3, goal_z)


# --------------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------------
func _add_cylinder(
	pos: Vector3,
	xform: Basis,
	length: float,
	radius: float,
	color: Color
) -> void:
	var cyl := CylinderMesh.new()
	cyl.height = length
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.radial_segments = PIPE_RADIAL_SEGMENTS
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = cyl
	mesh_inst.transform = Transform3D(xform, pos)
	_apply_mat(mesh_inst, color)
	add_child(mesh_inst)


# Build a quarter-circle bend. The bend lies in the plane defined by the
# two offset vectors from the center; it starts at (center + start_offset)
# and ends at (center + end_offset), sweeping through 90 degrees.
# start_offset and end_offset must be perpendicular and of equal length
# (the bend radius). The arc sweeps the short way (90°), not 270°.
func _add_quarter_bend(
	center: Vector3,
	start_offset: Vector3,
	end_offset: Vector3,
	color: Color
) -> void:
	var radius: float = start_offset.length()
	var u: Vector3 = start_offset.normalized()  # unit vector from center to arc start
	var v: Vector3 = end_offset.normalized()    # unit vector from center to arc end
	# Parametrize: p(t) = center + radius * (cos(theta) * u + sin(theta) * v)
	# where theta goes from 0 (start) to PI/2 (end).
	var arc_len: float = PI / 2.0 * radius
	var seg_len: float = arc_len / float(BEND_SEGMENTS)
	for i in range(BEND_SEGMENTS):
		var t0: float = float(i) / float(BEND_SEGMENTS) * (PI / 2.0)
		var t1: float = float(i + 1) / float(BEND_SEGMENTS) * (PI / 2.0)
		var p0: Vector3 = center + radius * (cos(t0) * u + sin(t0) * v)
		var p1: Vector3 = center + radius * (cos(t1) * u + sin(t1) * v)
		var mid: Vector3 = (p0 + p1) / 2.0
		var dir: Vector3 = (p1 - p0).normalized()
		var seg_basis: Basis = _basis_from_up(dir)
		# Overlap slightly so there's no visible seam
		_add_cylinder(mid, seg_basis, seg_len * 1.05, POST_RADIUS, color)


# Godot's CylinderMesh default axis is +Y. Build a Basis whose Y axis
# points along `up_dir`, with any valid perpendicular X/Z.
func _basis_from_up(up_dir: Vector3) -> Basis:
	var up: Vector3 = up_dir.normalized()
	# Pick a reference axis not parallel to up
	var ref: Vector3 = Vector3.UP if abs(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(up).normalized()
	var z_axis: Vector3 = up.cross(x_axis).normalized()
	return Basis(x_axis, up, z_axis)


# Centre of the cage's cavity, which is what NetPanelBuilder orients panel
# normals away from. Depth is taken at the ice, where the cage is deepest.
func _cavity_center(goal_z: float) -> Vector3:
	return Vector3(0.0, NET_HEIGHT / 2.0, goal_z + facing * BASE_DEPTH / 2.0)


# Triangular net panel (3 corners in world space), for the small gap-fillers
# where a quad would degenerate.
func _add_net_tri(a: Vector3, b: Vector3, c: Vector3, goal_z: float) -> void:
	_add_panel(NetPanelBuilder.tri(a, b, c, NET_TEXTURE_TILE_SIZE, _cavity_center(goal_z)))


# Quadrilateral net panel from four corners in world space, in order around the
# quad (A, B, C, D — either CW or CCW). Rendered double-sided via the net
# material's cull_disabled. Mesh only: the puck's carom off the panels is
# analytic (PuckGeometryCollision), and the skater is held out of the pocket by
# GameRules.push_out_of_net — so a panel that bulges under the shader does not
# move what anything collides with.
func _add_net_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, goal_z: float) -> void:
	_add_panel(NetPanelBuilder.quad(a, b, c, d, NET_TEXTURE_TILE_SIZE, _cavity_center(goal_z)))


func _add_panel(mesh: ArrayMesh) -> void:
	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = mesh
	# The shader displaces vertices outside the mesh's own bounds, so the
	# renderer must be told to expect it or a bulging panel culls at the edge
	# of frame while it is still on screen.
	mesh_inst.extra_cull_margin = IMPACT_MAX_BULGE + CELEBRATION_BULGE
	_apply_mat_net(mesh_inst)
	add_child(mesh_inst)


# Host-only swept goal test, driven once per physics tick by GameManager (which
# owns the authoritative puck and its previous position). Emits `goal_scored` the
# tick the WHOLE puck crosses the goal line inside the mouth. Never replace this
# with an Area3D sensor: an Area3D fires on shape-edge overlap from any face and
# cannot account for the puck's radius, so post grazes and side-net entries score
# and a fast shot tunnels straight through. The center-based swept crossing here
# (GoalDetectionRules) rejects all three.
func check_goal_crossing(prev_center: Vector3, curr_center: Vector3) -> void:
	if GoalDetectionRules.crossed_into_net(
			prev_center,
			curr_center,
			goal_line_z(),
			float(facing),
			POST_HALF_WIDTH,  # post centerline; the rule steps in by POST_RADIUS
			NET_HEIGHT,       # crossbar centerline
			POST_RADIUS,
			GameRules.PUCK_COLLISION_RADIUS,
			GameRules.PUCK_COLLISION_HALF_HEIGHT,
			BASE_DEPTH):
		goal_scored.emit()


# --------------------------------------------------------------------------
# NET IMPACTS — the twine's response to being hit.
#
# Purely cosmetic, and deliberately so. The puck's carom off these panels was
# already resolved analytically (PuckGeometryCollision) before anything here
# runs, and nothing here feeds back into it. That is what lets every peer drive
# its own twine from its own contact detection — the host from its authoritative
# sim, a client from its local prediction, either from the broadcast — without a
# single bulge going on the wire or into a reconcile snapshot.
# --------------------------------------------------------------------------

# A puck has reached the twine at `world_pos` carrying `speed` m/s. Bulges the
# mesh there: outward when the puck came from inside the cage, inward when it is
# pressing on the netting from outside (a rim behind the goal, a puck settling
# on the roof).
func net_impact(world_pos: Vector3, speed: float) -> void:
	var bulge: float = minf(speed * IMPACT_METRES_PER_MPS, IMPACT_MAX_BULGE)
	if bulge <= 0.0:
		return
	# Speed, not its component into the panel: the broadcast path carries only a
	# position, and a contact that fires at all has arrived roughly into the
	# twine rather than sliding along it.
	var normal: Vector3 = NetGeometry.nearest_surface_normal(world_pos)
	# A puck that came in through the mouth pushes the twine out of the cage; one
	# pressing on the netting from outside pushes it in.
	var dir: Vector3 = normal if NetGeometry.interior_or_mouth(world_pos) else -normal
	_register_impact(world_pos, bulge, IMPACT_RADIUS, dir)


# The goal celebration, as one wide deep impact at the mouth rather than a second
# displacement path: the whole cage billows outward at once. Radial rather than
# directional — a single direction would shove the cage sideways instead of
# swelling it.
func shake_for_goal() -> void:
	_register_impact(Vector3(0.0, NET_HEIGHT / 2.0, goal_line_z()),
			CELEBRATION_BULGE, CELEBRATION_RADIUS, Vector3.ZERO)


# `dir` is the unit direction the twine is pushed, or Vector3.ZERO for the radial
# billow the shader derives per vertex from cavity_center.
func _register_impact(origin: Vector3, amp: float, radius: float, dir: Vector3) -> void:
	if _net_material == null:
		return
	var radial: float = 1.0 if dir.is_zero_approx() else 0.0
	_impact_origin_amp[_impact_next] = Vector4(origin.x, origin.y, origin.z, amp)
	_impact_start_radius[_impact_next] = Vector4(_net_time, radius, 0.0, 0.0)
	_impact_dir[_impact_next] = Vector4(dir.x, dir.y, dir.z, radial)
	_impact_next = (_impact_next + 1) % MAX_IMPACTS
	_net_material.set_shader_parameter(&"impact_origin_amp", _impact_origin_amp)
	_net_material.set_shader_parameter(&"impact_start_radius", _impact_start_radius)
	_net_material.set_shader_parameter(&"impact_dir", _impact_dir)
	_impacts_live_until = _net_time + IMPACT_LIFETIME
	set_process(true)


# The twine's clock, running only while an impact is still settling: an idle net
# costs nothing at all, and the frame the last one expires the arrays are zeroed
# so the shader's per-vertex loop skips every slot from then on.
func _process(delta: float) -> void:
	_net_time += delta
	_net_material.set_shader_parameter(&"net_time", _net_time)
	if _net_time < _impacts_live_until:
		return
	_reset_impacts()


func _reset_impacts() -> void:
	# Written out rather than looped: packed arrays are value types, so a `for buf
	# in [...]` would resize and clear three copies and leave the members alone.
	_impact_origin_amp.resize(MAX_IMPACTS)
	_impact_start_radius.resize(MAX_IMPACTS)
	_impact_dir.resize(MAX_IMPACTS)
	_impact_origin_amp.fill(Vector4.ZERO)
	_impact_start_radius.fill(Vector4.ZERO)
	_impact_dir.fill(Vector4.ZERO)
	_impact_next = 0
	_impacts_live_until = -1.0
	set_process(false)
	if _net_material == null:
		return
	_net_material.set_shader_parameter(&"impact_origin_amp", _impact_origin_amp)
	_net_material.set_shader_parameter(&"impact_start_radius", _impact_start_radius)
	_net_material.set_shader_parameter(&"impact_dir", _impact_dir)
	_net_material.set_shader_parameter(&"net_time", _net_time)


func _apply_mat(mesh_inst: MeshInstance3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat


func _apply_mat_net(mesh_inst: MeshInstance3D) -> void:
	mesh_inst.material_override = _net_material


# One ShaderMaterial shared by every net panel of this goal, so an impact
# anywhere on the cage is a single uniform write rather than one per panel.
func _make_net_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(NET_SHADER_PATH)
	mat.set_shader_parameter(&"tint", net_color)
	# ResourceLoader.exists checks at runtime in case the asset isn't present
	# yet — in that case we just render the flat translucent color as before.
	if ResourceLoader.exists(NET_TEXTURE_PATH):
		var tex: Texture2D = load(NET_TEXTURE_PATH)
		mat.set_shader_parameter(&"albedo_tex", tex)
		mat.set_shader_parameter(&"use_texture", true)
	return mat
