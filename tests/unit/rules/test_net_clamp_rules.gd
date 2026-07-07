extends GutTest

# NetClampRules — the blade net-exclusion clamp (IK-driven blades aren't physics-
# collided against the net, so this math is what keeps a stick out of the goal),
# plus the stick tuck-in front-slice exception.
#
# Geometry (GameRules): goal line at ±26.65, mouth half-width 0.915, buffer 0.10
# (so the exclusion box is 1.015 wide / 1.12 deep), crossbar 1.22, tuck depth 0.15.

const GL: float = 26.65
const HW: float = 0.915
const BUF: float = 0.10
const DEPTH: float = 1.02
const NET_H: float = 1.22
const TUCK: float = 0.15
const EFF_HW: float = 1.015   # HW + BUF
const BACK_Z: float = 27.77   # GL + DEPTH + BUF


func _clamp(p: Vector3, allow_tuck: bool = false) -> Vector3:
	return NetClampRules.clamp_out_of_net(p, GL, HW, BUF, DEPTH, NET_H, allow_tuck, TUCK)


# ── Exclusion (unchanged behavior, no tuck) ───────────────────────────────────

func test_point_in_front_of_line_unchanged() -> void:
	var p := Vector3(0.0, 0.1, 20.0)
	assert_eq(_clamp(p), p)


func test_point_above_crossbar_unchanged() -> void:
	var p := Vector3(0.0, 1.5, 27.0)
	assert_eq(_clamp(p), p)


func test_front_center_escapes_out_the_side_not_the_mouth() -> void:
	# Just inside the front, centered: nearest faces are the two sides — it must
	# be pushed sideways out of the posts, never back out the front toward center.
	var r := _clamp(Vector3(0.0, 0.1, 26.70))
	assert_almost_eq(absf(r.x), EFF_HW, 0.001)
	assert_almost_eq(r.z, 26.70, 0.001, "never escapes through the front face")


func test_deep_center_escapes_out_the_back() -> void:
	var r := _clamp(Vector3(0.0, 0.1, 27.60))
	assert_almost_eq(r.z, BACK_Z, 0.001)


func test_negative_net_excludes() -> void:
	var r := _clamp(Vector3(0.0, 0.1, -26.70))
	assert_almost_eq(absf(r.x), EFF_HW, 0.001)


# ── Tuck-in front slice ───────────────────────────────────────────────────────

func test_tuck_allows_shallow_front_of_mouth() -> void:
	# Carrier bringing the puck a few cm over the line, between the posts: allowed.
	var p := Vector3(0.0, 0.1, GL + 0.07)
	assert_eq(_clamp(p, true), p)


func test_tuck_allows_side_of_mouth() -> void:
	# A sharp-angle tuck near a post (|x| < 0.915) still rides in.
	var p := Vector3(0.80, 0.1, GL + 0.05)
	assert_eq(_clamp(p, true), p)


func test_tuck_blocked_beyond_tuck_depth() -> void:
	# Deeper than the shallow front slice: still excluded (can't reach the puck
	# through the back mesh).
	var r := _clamp(Vector3(0.0, 0.1, GL + 0.30), true)
	assert_almost_eq(r.z, BACK_Z, 0.001, "deep point escapes out the back even with tuck allowed")


func test_tuck_blocked_outside_the_posts() -> void:
	# In the shallow slice by depth, but wide of the post line (in the buffer
	# band): not the mouth opening — clamp it (no tucking through the side mesh).
	var p := Vector3(0.97, 0.1, GL + 0.05)
	var r := _clamp(p, true)
	assert_ne(r, p)
	assert_almost_eq(r.x, EFF_HW, 0.001, "pushed out the near side")


func test_tuck_flag_off_still_excludes_the_slice() -> void:
	# Follow-through / non-carry calls pass allow_tuck = false — the front slice
	# is NOT opened, so the old behavior is preserved exactly.
	var p := Vector3(0.0, 0.1, GL + 0.07)
	assert_ne(_clamp(p, false), p)


func test_tuck_allows_negative_net_front_slice() -> void:
	var p := Vector3(0.0, 0.1, -GL - 0.07)
	assert_eq(_clamp(p, true), p)


func test_tuck_depth_boundary() -> void:
	# Exactly at the tuck depth counts (<=); a hair past does not.
	var on_edge := Vector3(0.0, 0.1, GL + TUCK)
	assert_eq(_clamp(on_edge, true), on_edge)
	var past := Vector3(0.0, 0.1, GL + TUCK + 0.01)
	assert_ne(_clamp(past, true), past)
