extends GutTest

# GameRules.push_out_of_goalie — analytic skater-vs-goalie body block. Holds a
# skater's center clear of the goalie footprint now that move_and_slide is gone
# and the goalie body parts are off the skater physics mask (see
# Skater.clamp_body_to_goalies). Two footprints by stance:
#   - standing / RVH → a cylinder of `radius` around the goalie center
#   - butterfly       → an oriented box (half_x × half_z, rotated by the goalie yaw)
#
# The caller pre-inflates `radius` / half-extents with the skater's own collision
# radius, so these tests pass explicit extents and treat them as the final surface.

const TOL: float = 0.001
const R: float = 0.9            # standing block radius (footprint + skater radius)
const HX: float = 1.25          # butterfly half-x (lateral pad spread)
const HZ: float = 0.65          # butterfly half-z (front-back depth)

# ── Standing cylinder ─────────────────────────────────────────────────────────

func test_standing_far_unchanged() -> void:
	# Well outside the cylinder — untouched.
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(3.0, 26.0), Vector2(0.0, 26.65), 0.0, false, R, HX, HZ)
	assert_almost_eq(r.x, 3.0, TOL, "x unchanged")
	assert_almost_eq(r.y, 26.0, TOL, "z unchanged")

func test_standing_inside_pushed_to_surface() -> void:
	# 0.3 m to the +x side of a goalie at (0, 26.65) — pushed out to the radius,
	# straight along +x (shortest exit for a pure lateral offset).
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(0.3, 26.65), g, 0.0, false, R, HX, HZ)
	assert_almost_eq(r.distance_to(g), R, TOL, "ejected onto the cylinder surface")
	assert_almost_eq(r.y, 26.65, TOL, "pure +x offset stays on the goalie's z")
	assert_true(r.x > 0.3, "pushed further out along +x")

func test_standing_on_surface_unchanged() -> void:
	# Exactly at the radius — dist >= radius, so untouched (boundary is 'clear').
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(0.0, 26.65 - R), g, 0.0, false, R, HX, HZ)
	assert_almost_eq(r.y, 26.65 - R, TOL, "point on the surface is not moved")

func test_standing_coincident_ejects_toward_center_ice() -> void:
	# Skater exactly on the goalie center — degenerate direction falls back to
	# 'toward center ice' (−sign(gz)), so a +Z-end goalie ejects toward −Z.
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(0.0, 26.65), g, 0.0, false, R, HX, HZ)
	assert_almost_eq(r.x, 0.0, TOL, "x centered")
	assert_almost_eq(r.y, 26.65 - R, TOL, "ejected toward center ice")

# ── Butterfly box (axis-aligned, yaw 0) ───────────────────────────────────────

func test_butterfly_far_unchanged() -> void:
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(2.0, 26.65), Vector2(0.0, 26.65), 0.0, true, R, HX, HZ)
	assert_almost_eq(r.x, 2.0, TOL, "x unchanged")

func test_butterfly_inside_ejects_along_shallow_axis() -> void:
	# Slightly off-center: the box is wide in x, shallow in z, so a near-center
	# point is nearest the z face and ejects front/back, not sideways.
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(0.1, 26.75), g, 0.0, true, R, HX, HZ)
	assert_almost_eq(r.x, 0.1, TOL, "x held (z was the nearest face)")
	assert_almost_eq(r.y, 26.65 + HZ, TOL, "ejected to the +z face")

func test_butterfly_lateral_ejects_sideways() -> void:
	# Near the wide side face → ejects along x.
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(1.2, 26.65), g, 0.0, true, R, HX, HZ)
	assert_almost_eq(r.x, HX, TOL, "ejected to the +x face")
	assert_almost_eq(r.y, 26.65, TOL, "z held during a sideways eject")

# ── Butterfly box respects the goalie yaw ─────────────────────────────────────

func test_butterfly_yaw_rotates_the_box() -> void:
	# Rotate the goalie 90°: the shallow (z) axis of the box now runs along world x.
	# A 0.5 m world-x offset maps to goalie-local z = -0.5 (inside, since HZ = 0.65)
	# and ejects along the shallow axis — back out to world x at the HZ face.
	var g := Vector2(0.0, 26.65)
	var yaw: float = PI / 2.0
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(0.5, 26.65), g, yaw, true, R, HX, HZ)
	assert_almost_eq(r.y, 26.65, TOL, "z held")
	assert_almost_eq(absf(r.x), HZ, TOL, "ejected to the (rotated) shallow face at HZ")

# ── Ordering-independence of the cylinder eject direction ─────────────────────

func test_standing_negative_side_ejects_negative() -> void:
	var g := Vector2(0.0, 26.65)
	var r: Vector2 = GameRules.push_out_of_goalie(
			Vector2(-0.3, 26.65), g, 0.0, false, R, HX, HZ)
	assert_true(r.x < -0.3, "pushed further out along -x")
	assert_almost_eq(r.distance_to(g), R, TOL, "on the surface")
