extends GutTest

# NetClampRules — the net treated as a solid object for the IK blade: five solid
# faces, only the front mouth open. Non-carry calls (allow_front=false) get pure
# exclusion; carry calls open the front so a blade whose PATH came through the
# mouth OPENING (between the post inner faces) carries the puck across, while
# side/back entry — and a plane crossing at the posts / side-netting strip —
# stays blocked regardless of where the skater's body is.
#
# Geometry (GameRules): goal line ±26.65, mouth half-width 0.915, post radius
# 0.030 (opening |x| < 0.885), buffer 0.10 (so the box is 1.015 wide / 1.12
# deep), crossbar 1.22.

const GL: float = 26.65
const HW: float = 0.915
const POST_R: float = 0.030
const BUF: float = 0.10
const DEPTH: float = 1.02
const NET_H: float = 1.22
const EFF_HW: float = 1.015   # HW + BUF
const MOUTH_HW: float = 0.885  # HW - POST_R (physical opening)
const BACK_Z: float = 27.77   # GL + DEPTH + BUF


func _clamp(point: Vector3, prev: Vector3, allow_front: bool) -> Vector3:
	return NetClampRules.clamp_out_of_net(point, prev, GL, HW, POST_R, BUF, DEPTH, NET_H, allow_front)


# ── Pure exclusion (non-carry, allow_front=false) ─────────────────────────────

func test_point_in_front_of_line_unchanged() -> void:
	var p := Vector3(0.0, 0.1, 20.0)
	assert_eq(_clamp(p, p, false), p)


func test_point_above_crossbar_unchanged() -> void:
	var p := Vector3(0.0, 1.5, 27.0)
	assert_eq(_clamp(p, p, false), p)


func test_front_center_escapes_out_the_side_not_the_mouth() -> void:
	var r := _clamp(Vector3(0.0, 0.1, 26.70), Vector3(0.0, 0.1, 20.0), false)
	assert_almost_eq(absf(r.x), EFF_HW, 0.001)
	assert_almost_eq(r.z, 26.70, 0.001, "never escapes through the front face")


func test_deep_center_escapes_out_the_back() -> void:
	var r := _clamp(Vector3(0.0, 0.1, 27.60), Vector3(0.0, 0.1, 20.0), false)
	assert_almost_eq(r.z, BACK_Z, 0.001)


func test_non_carry_still_excludes_even_from_the_front() -> void:
	# Follow-through (allow_front=false): the mouth is NOT open, so even a
	# front-approaching point is pushed out — old behavior preserved exactly.
	var p := Vector3(0.0, 0.1, GL + 0.07)
	var prev := Vector3(0.0, 0.1, GL - 0.2)  # in front
	assert_ne(_clamp(p, prev, false), p)


# ── Front-face entry (carry, allow_front=true) ────────────────────────────────

func test_front_entry_rides_in() -> void:
	# Blade came from in front of the line, crossing the mouth: allowed.
	var p := Vector3(0.0, 0.1, GL + 0.07)
	var prev := Vector3(0.0, 0.1, GL - 0.10)
	assert_eq(_clamp(p, prev, true), p)


func test_front_entry_allowed_deep() -> void:
	# Reaching deep through the mouth is still a front entry — physical (a stick
	# in through the opening). The back face still contains it.
	var p := Vector3(0.0, 0.1, GL + 0.6)
	var prev := Vector3(0.0, 0.1, GL - 0.05)
	assert_eq(_clamp(p, prev, true), p)


func test_prev_inside_stays_inside() -> void:
	# Inductive: already legally inside last tick → stays allowed this tick.
	var p := Vector3(0.1, 0.1, GL + 0.30)
	var prev := Vector3(0.0, 0.1, GL + 0.20)
	assert_eq(_clamp(p, prev, true), p)


# ── Blocked entries (carry, but not through the mouth) ────────────────────────

func test_side_entry_blocked() -> void:
	# Blade beside the net (outside the post line) sweeping in: it would cross a
	# SIDE face, not the mouth — blocked, pushed back out the near side.
	var p := Vector3(0.80, 0.1, GL + 0.15)
	var prev := Vector3(1.20, 0.1, GL + 0.15)
	var r := _clamp(p, prev, true)
	assert_ne(r, p)
	assert_almost_eq(r.x, EFF_HW, 0.001)


func test_back_entry_blocked() -> void:
	# Blade behind the net reaching forward: crosses the BACK face — blocked,
	# regardless of how close the body is. This is the wraparound-from-behind
	# case the solid-net model must deny.
	var p := Vector3(0.0, 0.1, GL + 0.9)
	var prev := Vector3(0.0, 0.1, BACK_Z + 0.3)  # behind the back mesh
	var r := _clamp(p, prev, true)
	assert_ne(r, p)
	assert_almost_eq(r.z, BACK_Z, 0.001)


func test_front_but_wide_of_the_mouth_blocked() -> void:
	# Came from in front but wide of the post line: the segment crosses the mouth
	# plane OUTSIDE the opening (it clips a side), so it isn't a front entry.
	var p := Vector3(0.90, 0.1, GL + 0.10)
	var prev := Vector3(1.20, 0.1, GL - 0.10)
	var r := _clamp(p, prev, true)
	assert_ne(r, p)


func test_crossing_at_the_post_strip_is_not_a_front_entry() -> void:
	# The wraparound own-goal bug: a blade sweeping across the goal-line plane
	# right AT the post (|x| between the opening 0.885 and the box edge 1.015)
	# used to register as a legal front entry — through the post / side-netting
	# strip — and could then roam the whole box, dragging the pinned puck
	# through the side mesh into the net. It must be clamped like any other
	# solid-face contact.
	var p := Vector3(0.95, 0.1, GL + 0.05)
	var prev := Vector3(0.95, 0.1, GL - 0.05)
	var r := _clamp(p, prev, true)
	assert_ne(r, p, "plane crossing at the post strip must not ride in")


func test_legal_occupant_confined_to_the_mouth_column() -> void:
	# Entered legally through the opening, then drifted laterally toward the
	# side netting while still inside the box: the side mesh holds it at the
	# post line instead of letting it pass through into the box's side strip.
	var p := Vector3(0.95, 0.1, GL + 0.20)
	var prev := Vector3(0.60, 0.1, GL + 0.20)  # legally inside the column
	var r := _clamp(p, prev, true)
	assert_almost_eq(r.x, MOUTH_HW, 0.001, "held at the post line")
	assert_almost_eq(r.z, p.z, 0.001, "depth untouched by the lateral confine")


func test_front_entry_at_the_opening_edge_rides_in() -> void:
	# Just inside the post inner face is still the opening.
	var p := Vector3(0.87, 0.1, GL + 0.07)
	var prev := Vector3(0.87, 0.1, GL - 0.10)
	assert_eq(_clamp(p, prev, true), p)


# ── Negative-Z net mirrors ────────────────────────────────────────────────────

func test_negative_net_front_entry_rides_in() -> void:
	var p := Vector3(0.0, 0.1, -GL - 0.07)
	var prev := Vector3(0.0, 0.1, -GL + 0.10)
	assert_eq(_clamp(p, prev, true), p)


func test_negative_net_back_entry_blocked() -> void:
	var p := Vector3(0.0, 0.1, -GL - 0.9)
	var prev := Vector3(0.0, 0.1, -BACK_Z - 0.3)
	var r := _clamp(p, prev, true)
	assert_ne(r, p)
	assert_almost_eq(r.z, -BACK_Z, 0.001)
