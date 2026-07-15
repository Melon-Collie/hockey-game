@tool
class_name HockeyGoal
extends StaticBody3D

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
const BASE_DEPTH: float         = 1.016   # 40" base depth (NHL rulebook)
const TOP_DEPTH: float          = 0.559   # 22" top shelf depth
const POST_RADIUS: float        = 0.030   # 2 3/8" OD pipe

const MOUTH_CORNER_RADIUS: float = 0.10   # post-to-crossbar bend
const SKIRT_CORNER_RADIUS: float = 0.15   # back corners of ice skirt
const CROWN_CORNER_RADIUS: float = 0.10   # back corners of top crown

const POST_HALF_WIDTH: float    = GOAL_WIDTH / 2.0              # 0.915
const CROWN_HALF_WIDTH: float   = POST_HALF_WIDTH - MOUTH_CORNER_RADIUS  # 0.815

const BEND_SEGMENTS: int        = 6       # curve tessellation per quarter bend
const PIPE_RADIAL_SEGMENTS: int = 8

# Collision-wall depth for the thin side-net panels (see _wall_thicken_x). The
# visual panels are thin quads; their COLLISION is grown to this so a fast puck
# can't tunnel the side netting into the cavity when CCD misses a grazing sweep.
const NET_COLLISION_WALL_THICKNESS: float = 0.15

# Net mesh texture: seamless diamond grid. Place the PNG at this path in your project.
# Each tile of the texture covers NET_TEXTURE_TILE_SIZE x NET_TEXTURE_TILE_SIZE metres
# of world space. The texture is 4 diamonds wide per tile, so each diamond is
# NET_TEXTURE_TILE_SIZE / 4 metres across — currently 0.041 m (NHL regulation mesh).
const NET_TEXTURE_PATH: String    = "res://Assets/textures/net_diamond.png"
const NET_TEXTURE_TILE_SIZE: float = 0.164  # 4 diamonds × 41mm each

# Physics materials split by surface. The main HockeyGoal body carries the pipe
# frame (posts/crossbar/bends → lively steel ping); _net_body carries the net
# panels + skirt (twine → absorbs, puck drops). Neither existed before, so the
# whole goal ran on the engine default (friction 1.0, bounce 0.0) — pipe pinged
# dead and the net had no distinct feel. See the .tres files for the numbers and
# the combine reasoning (the puck carries no material, so each collapses to the
# surface value).
const PIPE_MATERIAL: PhysicsMaterial = preload("res://Physics/goal_pipe.tres")
const NET_MATERIAL: PhysicsMaterial = preload("res://Physics/goal_net.tres")

# All net panels share one ShaderMaterial (goal_net.gdshader) so GoalVFX can
# drive a single ripple uniform on goal. Rebuilt per _rebuild().
const NET_SHADER_PATH: String = "res://Shaders/goal_net.gdshader"

# Goal lamp fixture placement: above the glass on the end boards behind this
# net (glass tops out around 2.9 m — wall 1.07 + glass 1.83).
const LAMP_HEIGHT: float = 3.2
const LAMP_BEHIND_BOARDS: float = 0.35

var defending_team_id: int = -1  # set by GameManager when goals are assigned to teams
var _net_body: StaticBody3D = null  # holds net-panel collision shapes; kept separate so puck can distinguish pipe vs net contact
var _net_material: ShaderMaterial = null  # shared across all net panels; GoalVFX tweens its ripple uniform


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
	# Pipe frame (posts/crossbar/bends live directly on this StaticBody3D).
	# _rebuild() only frees children, never touches self's material, so setting
	# it once here survives every rebuild.
	physics_material_override = PIPE_MATERIAL
	_rebuild()

func _rebuild() -> void:
	# Guard against Nil color values from older scene files that stored
	# properties with names that have since been renamed (e.g. base_frame_color
	# was renamed to crown_color). If a color comes back as Nil, fall back to
	# the intended default.
	if typeof(crown_color) != TYPE_COLOR:
		crown_color = Color(0.95, 0.95, 0.95)
	if typeof(post_color) != TYPE_COLOR:
		post_color = Color(0.784, 0.063, 0.180)
	if typeof(net_color) != TYPE_COLOR:
		net_color = Color(0.8, 0.8, 0.8, 1.0)

	for child in get_children():
		child.queue_free()

	_net_body = StaticBody3D.new()
	_net_body.collision_layer = Constants.LAYER_WALLS  # puck must still bounce off net panels
	_net_body.physics_material_override = NET_MATERIAL  # twine absorbs; puck drops instead of pinging
	add_child(_net_body)

	var goal_z: float = facing * (rink_length / 2.0 - distance_from_end)
	_net_material = _make_net_material(goal_z)
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
		goal_vfx.setup(_net_material, lamp_world - goal_vfx.position)


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
			post_color,
			true
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
		post_color,
		true
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
		_add_quarter_bend(center, start_offset, end_offset, post_color, true)


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
			post_color,
			true,
			true
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
		_add_quarter_bend(corner_center, start_offset, end_offset, post_color, true, true)

	# Back rail along X axis, spanning between the two corner end-points
	var back_rail_len: float = (POST_HALF_WIDTH - corner_x_offset) * 2.0
	var back_rail_basis := Basis(Vector3(0, 0, 1), PI / 2.0)
	_add_cylinder(
		Vector3(0.0, y, back_z),
		back_rail_basis,
		back_rail_len,
		POST_RADIUS,
		post_color,
		true,
		true
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
			crown_color,
			false  # crown has no collision; net panels handle it
		)

		var corner_center_x: float = side * (CROWN_HALF_WIDTH - corner_x_offset)
		var corner_center_z: float = back_z - facing * corner_z_offset
		var corner_center := Vector3(corner_center_x, y, corner_center_z)
		var start_offset := Vector3(side * CROWN_CORNER_RADIUS, 0.0, 0.0)
		var end_offset := Vector3(0.0, 0.0, facing * CROWN_CORNER_RADIUS)
		_add_quarter_bend(corner_center, start_offset, end_offset, crown_color, false)

	var back_rail_len: float = (CROWN_HALF_WIDTH - corner_x_offset) * 2.0
	var back_rail_basis := Basis(Vector3(0, 0, 1), PI / 2.0)
	_add_cylinder(
		Vector3(0.0, y, back_z),
		back_rail_basis,
		back_rail_len,
		POST_RADIUS,
		crown_color,
		false
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
	_add_cylinder(mid, cyl_basis, length, POST_RADIUS, crown_color, false)


# --------------------------------------------------------------------------
# NET PANELS — four translucent faces approximated as thin rotated boxes.
# All four have collision so pucks stop when they enter.
#
# Per user decision (option 1a): we simplify by using POST_HALF_WIDTH for the
# side panels' X position even though the crown is inset by MOUTH_CORNER_RADIUS
# at the top. This means the side panels run straight vertically at the post
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
		Vector3(-CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top)
	)

	# --- 2. BACK panel ---
	# Slanted quad. Top edge at crown width + crown depth, bottom edge at
	# skirt width + skirt depth. The fact that the top edge is narrower than
	# the bottom edge means this is a trapezoid, not a rectangle.
	_add_net_quad(
		Vector3(-CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),  # top-left
		Vector3( CROWN_HALF_WIDTH, NET_HEIGHT, back_z_top),  # top-right
		Vector3( POST_HALF_WIDTH,  0.0,        back_z_bot),  # bottom-right
		Vector3(-POST_HALF_WIDTH,  0.0,        back_z_bot)   # bottom-left
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
			Vector3(x, 0.0,        back_z_bot)
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
		_add_net_quad(r1, r2, r3, r4)

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
		_add_net_tri(q1, q2, q3)


# --------------------------------------------------------------------------
# HELPERS
# --------------------------------------------------------------------------
func _add_cylinder(
	pos: Vector3,
	xform: Basis,
	length: float,
	radius: float,
	color: Color,
	with_collision: bool,
	use_net_body: bool = false
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

	if with_collision:
		var shape := CylinderShape3D.new()
		shape.height = length
		shape.radius = radius
		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = Transform3D(xform, pos)
		if use_net_body:
			_net_body.add_child(col)
		else:
			add_child(col)


# Build a quarter-circle bend. The bend lies in the plane defined by the
# two offset vectors from the center; it starts at (center + start_offset)
# and ends at (center + end_offset), sweeping through 90 degrees.
# start_offset and end_offset must be perpendicular and of equal length
# (the bend radius). The arc sweeps the short way (90°), not 270°.
func _add_quarter_bend(
	center: Vector3,
	start_offset: Vector3,
	end_offset: Vector3,
	color: Color,
	with_collision: bool,
	use_net_body: bool = false
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
		_add_cylinder(mid, seg_basis, seg_len * 1.05, POST_RADIUS, color, with_collision, use_net_body)


# Project a 3D point onto a 2D UV coordinate, given an anchor point and two
# perpendicular basis vectors in the panel's plane. The UV is the point's
# offset from the anchor expressed in the (u_axis, v_axis) basis, scaled.
func _project_uv(p: Vector3, anchor: Vector3, u_axis: Vector3, v_axis: Vector3, uv_scale: float) -> Vector2:
	var offset: Vector3 = p - anchor
	return Vector2(offset.dot(u_axis) * uv_scale, offset.dot(v_axis) * uv_scale)


# Godot's CylinderMesh default axis is +Y. Build a Basis whose Y axis
# points along `up_dir`, with any valid perpendicular X/Z.
func _basis_from_up(up_dir: Vector3) -> Basis:
	var up: Vector3 = up_dir.normalized()
	# Pick a reference axis not parallel to up
	var ref: Vector3 = Vector3.UP if abs(up.dot(Vector3.UP)) < 0.99 else Vector3.RIGHT
	var x_axis: Vector3 = ref.cross(up).normalized()
	var z_axis: Vector3 = up.cross(x_axis).normalized()
	return Basis(x_axis, up, z_axis)


# Turn a panel's AABB (box_size / box_center as value copies) into a SOLID WALL
# and return [size, center]. The visual net panels are thin quads, but their
# collision must actually contain a 120 Hz puck. The old code padded each thin
# axis to POST_RADIUS (3 cm); at shot speed the puck clears far more than that
# per tick, so containment leaned entirely on the puck's CCD — and thin static
# geometry is exactly where a swept collision test misses (a grazing sweep, a
# direction change off a post). A puck that slips through ends up inside the net
# having entered through a SOLID face, so no mouth crossing ever fired: it sits
# in the net with no goal, the worst failure.
#
# So thicken the thin VERTICAL-plane axis — x, the side netting, which is the
# real "in from the back/side" tunnelling vector — into a wall grown OUTWARD,
# away from the cavity. The cavity-side face stays exactly on the panel plane
# (x = ±POST_HALF_WIDTH), so nothing inside the net changes: mouth entries, tight
# post-and-ins, and a scored puck's rest position are all untouched; only the
# net's OUTER surface moves out. An inbound puck from behind/beside now meets the
# wall sooner, and a shallow CCD-miss penetration lands inside a fat box that
# depenetrates it back OUT rather than through.
#
# The thin HORIZONTAL top panel keeps the old thin pad on y: growing it upward
# would wrongly block a puck clearing the crossbar (over-the-net is a miss, not a
# save), and a puck leaving the cavity upward has already scored on entry. The
# back panel is thick on every axis and is left unchanged.
func _wall_thicken_x(box_size: Vector3, box_center: Vector3) -> Array:
	if box_size.x < POST_RADIUS:
		var outward: float = signf(box_center.x)
		if outward == 0.0:
			outward = 1.0
		var inner_face_x: float = box_center.x - outward * box_size.x * 0.5
		box_size.x = NET_COLLISION_WALL_THICKNESS
		box_center.x = inner_face_x + outward * NET_COLLISION_WALL_THICKNESS * 0.5
	if box_size.y < POST_RADIUS:
		box_size.y = POST_RADIUS
	if box_size.z < POST_RADIUS:
		box_size.z = POST_RADIUS
	return [box_size, box_center]


# Build a triangular net panel (3 corners in world space). For small gap-filler
# panels where a quad would degenerate. Same flat visual as _add_net_quad.
# Collision uses the AABB of the three corners, thin axes grown to a solid wall
# (see _wall_thicken_x).
func _add_net_tri(a: Vector3, b: Vector3, c: Vector3) -> void:
	var verts := PackedVector3Array([a, b, c])
	var normal: Vector3 = (b - a).cross(c - a).normalized()
	var normals := PackedVector3Array([normal, normal, normal])
	# UVs: same approach as _add_net_quad — project onto 2D basis anchored at A.
	var u_axis: Vector3 = (b - a).normalized()
	var v_axis: Vector3 = normal.cross(u_axis).normalized()
	var uv_scale: float = 1.0 / NET_TEXTURE_TILE_SIZE
	var uv_a: Vector2 = _project_uv(a, a, u_axis, v_axis, uv_scale)
	var uv_b: Vector2 = _project_uv(b, a, u_axis, v_axis, uv_scale)
	var uv_c: Vector2 = _project_uv(c, a, u_axis, v_axis, uv_scale)
	var uvs := PackedVector2Array([uv_a, uv_b, uv_c])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = array_mesh
	_apply_mat_net(mesh_inst)
	add_child(mesh_inst)

	# AABB collision box
	var min_p: Vector3 = Vector3(
		min(min(a.x, b.x), c.x),
		min(min(a.y, b.y), c.y),
		min(min(a.z, b.z), c.z)
	)
	var max_p: Vector3 = Vector3(
		max(max(a.x, b.x), c.x),
		max(max(a.y, b.y), c.y),
		max(max(a.z, b.z), c.z)
	)
	var box_center: Vector3 = (min_p + max_p) / 2.0
	var wall: Array = _wall_thicken_x(max_p - min_p, box_center)
	var shape := BoxShape3D.new()
	shape.size = wall[0]
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = wall[1]
	_net_body.add_child(col)


# Build an arbitrary quadrilateral net panel from four corners in world space.
# Corners must be given in order around the quad (A, B, C, D — either CW or CCW).
# The mesh is rendered double-sided via the net material's CULL_DISABLED flag.
# Collision uses a cheap axis-aligned BoxShape3D sized to the quad's bounding
# region (padded to POST_RADIUS on any thin axis).
func _add_net_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	# --- Mesh ---
	var verts := PackedVector3Array([a, b, c, a, c, d])  # two triangles (ABC, ACD)
	var normal: Vector3 = (b - a).cross(d - a).normalized()
	var normals := PackedVector3Array([normal, normal, normal, normal, normal, normal])
	# UVs: project each vertex onto the panel's plane using a 2D basis (U, V)
	# anchored at corner A. U runs along edge A->B, V runs along edge A->D.
	# UVs are then scaled by 1/NET_TEXTURE_TILE_SIZE so the diamond grid tiles
	# at the real-world target size regardless of panel dimensions.
	var u_axis: Vector3 = (b - a).normalized()
	var v_axis: Vector3 = normal.cross(u_axis).normalized()
	var uv_scale: float = 1.0 / NET_TEXTURE_TILE_SIZE
	var uv_a: Vector2 = _project_uv(a, a, u_axis, v_axis, uv_scale)
	var uv_b: Vector2 = _project_uv(b, a, u_axis, v_axis, uv_scale)
	var uv_c: Vector2 = _project_uv(c, a, u_axis, v_axis, uv_scale)
	var uv_d: Vector2 = _project_uv(d, a, u_axis, v_axis, uv_scale)
	var uvs := PackedVector2Array([uv_a, uv_b, uv_c, uv_a, uv_c, uv_d])
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var array_mesh := ArrayMesh.new()
	array_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	var mesh_inst := MeshInstance3D.new()
	mesh_inst.mesh = array_mesh
	_apply_mat_net(mesh_inst)
	add_child(mesh_inst)

	# --- Collision ---
	# Cheap BoxShape3D matching the quad's bounding region. For a right
	# trapezoid panel this is slightly larger than the visual mesh where the
	# slant is, but the back panel covers that overlap region, so the extra
	# collision is functionally redundant and keeps physics cheap.
	var min_p: Vector3 = Vector3(
		min(min(a.x, b.x), min(c.x, d.x)),
		min(min(a.y, b.y), min(c.y, d.y)),
		min(min(a.z, b.z), min(c.z, d.z))
	)
	var max_p: Vector3 = Vector3(
		max(max(a.x, b.x), max(c.x, d.x)),
		max(max(a.y, b.y), max(c.y, d.y)),
		max(max(a.z, b.z), max(c.z, d.z))
	)
	# Grow the panel's thin side-net axis into a solid containment wall (outward,
	# so the cavity is unchanged); thin top/seam axes keep a POST_RADIUS pad.
	var box_center: Vector3 = (min_p + max_p) / 2.0
	var wall: Array = _wall_thicken_x(max_p - min_p, box_center)
	var shape := BoxShape3D.new()
	shape.size = wall[0]
	var col := CollisionShape3D.new()
	col.shape = shape
	col.position = wall[1]
	_net_body.add_child(col)


# Host-only swept goal test, driven once per physics tick by GameManager (which
# owns the authoritative puck and its previous position). Emits `goal_scored` the
# tick the WHOLE puck crosses the goal line inside the mouth. Replaces the old
# Area3D `body_entered` sensor: an Area3D fires on shape-edge overlap from any
# face and never accounted for the puck's radius, so post grazes and side-net
# entries scored. The center-based swept crossing here (see GoalDetectionRules)
# rejects both and reliably catches fast shots the sensor could tunnel through.
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


func _apply_mat(mesh_inst: MeshInstance3D, color: Color) -> void:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mesh_inst.material_override = mat


func _apply_mat_net(mesh_inst: MeshInstance3D) -> void:
	mesh_inst.material_override = _net_material


# One ShaderMaterial shared by every net panel of this goal, so the goal
# ripple is a single uniform write. ripple_origin sits at the goal mouth —
# the wave radiates back through the net from there.
func _make_net_material(goal_z: float) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = load(NET_SHADER_PATH)
	mat.set_shader_parameter("tint", net_color)
	mat.set_shader_parameter("ripple_origin", Vector3(0.0, NET_HEIGHT / 2.0, goal_z))
	mat.set_shader_parameter("ripple_amount", 0.0)
	# ResourceLoader.exists checks at runtime in case the asset isn't present
	# yet — in that case we just render the flat translucent color as before.
	if ResourceLoader.exists(NET_TEXTURE_PATH):
		var tex: Texture2D = load(NET_TEXTURE_PATH)
		mat.set_shader_parameter("albedo_tex", tex)
		mat.set_shader_parameter("use_texture", true)
	return mat
