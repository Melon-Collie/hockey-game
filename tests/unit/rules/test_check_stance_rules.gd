extends GutTest

# CheckStanceRules — the per-shoulder check-commit load-up. The two defects this
# replaced are what most of these pin: a straight-on closing hit produced NO
# shoulder work at all, and the side it picked flipped hard across zero lateral
# input. Both are properties of the lead scalar, so they are assertable without
# an engine.

const RIGHT_HANDED: float = 1.0   # forehand on the skater's right
const LEFT_HANDED: float = -1.0

# Skater facing world −Z: local +X is world +X.
const FACING_RIGHT := Vector2(1.0, 0.0)


func _lead(intent: Vector2, stick_side: float) -> float:
	return CheckStanceRules.lead_target(intent, FACING_RIGHT, stick_side)


# ── lead_target ───────────────────────────────────────────────────────────────

func test_a_straight_closing_hit_still_throws_a_shoulder() -> void:
	# The whole point: no lateral input at all, and the load-up is still live.
	var rh: float = _lead(Vector2(0.0, -1.0), RIGHT_HANDED)
	var lh: float = _lead(Vector2(0.0, -1.0), LEFT_HANDED)
	assert_almost_eq(rh, -CheckStanceRules.LEAD_STICK_BIAS, 0.001,
			"right-handed shot leads with the off-stick (left) shoulder")
	assert_almost_eq(lh, CheckStanceRules.LEAD_STICK_BIAS, 0.001,
			"left-handed shot leads with the off-stick (right) shoulder")


func test_no_input_at_all_still_leads_off_the_stick() -> void:
	assert_lt(_lead(Vector2.ZERO, RIGHT_HANDED), -0.4,
			"a standing commit is still decisively asymmetric")


func test_steering_hard_across_carries_the_lead_to_the_other_shoulder() -> void:
	var toward_stick: float = _lead(Vector2(1.0, 0.0), RIGHT_HANDED)
	var away: float = _lead(Vector2(-1.0, 0.0), RIGHT_HANDED)
	assert_gt(toward_stick, 0.0,
			"angling across to the stick side throws that shoulder instead")
	assert_lt(away, -CheckStanceRules.LEAD_STICK_BIAS,
			"steering off the stick side deepens the load")


func test_the_lead_never_jumps_across_zero_lateral_input() -> void:
	# The old pose was signed by signf(lateral velocity), so the load teleported
	# from one shoulder to the other as the skater crossed straight-ahead. Sweep
	# the steer input through zero and assert the lead is continuous.
	var prev: float = _lead(Vector2(-1.0, 0.0), RIGHT_HANDED)
	for i: int in range(1, 41):
		var steer: float = -1.0 + 0.05 * float(i)
		var lead: float = _lead(Vector2(steer, 0.0), RIGHT_HANDED)
		assert_lt(absf(lead - prev), 0.06,
				"step at steer=%.2f is a slide, not a snap" % steer)
		prev = lead


func test_lead_stays_in_range_under_the_widest_inputs() -> void:
	for stick_side: float in [RIGHT_HANDED, LEFT_HANDED]:
		for steer: float in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			var lead: float = _lead(Vector2(steer, 0.0), stick_side)
			assert_between(lead, -1.0, 1.0, "lead stays normalized")


# ── side_load / load_offset ───────────────────────────────────────────────────

func test_only_the_leading_shoulder_loads() -> void:
	# The asymmetry a trunk roll cannot express: one side moves, one does not.
	assert_eq(CheckStanceRules.side_load(-0.7, 1.0), 0.0,
			"right shoulder is idle while the left leads")
	assert_almost_eq(CheckStanceRules.side_load(-0.7, -1.0), 0.7, 0.001,
			"left shoulder carries the whole load")
	assert_eq(CheckStanceRules.load_offset(
			CheckStanceRules.side_load(-0.7, 1.0), 1.0, 0.22), Vector3.ZERO,
			"the trailing cap and arm root do not move at all")


func test_the_leading_shoulder_drives_forward_across_and_down() -> void:
	var left: Vector3 = CheckStanceRules.load_offset(1.0, -1.0, 0.22)
	assert_lt(left.z, 0.0, "forward is −z")
	assert_lt(left.y, 0.0, "and a little down")
	assert_gt(left.x, 0.0, "the left shoulder comes across toward the midline")
	assert_gt(absf(left.z), absf(left.y),
			"protraction dominates the drop — the drop alone read as a roll")

	var right: Vector3 = CheckStanceRules.load_offset(1.0, 1.0, 0.22)
	assert_lt(right.x, 0.0, "the right shoulder comes across the other way")
	assert_almost_eq(right.y, left.y, 0.0001, "the two sides load identically")
	assert_almost_eq(right.z, left.z, 0.0001, "the two sides load identically")


func test_the_load_scales_with_the_frame_and_with_depth() -> void:
	var narrow: Vector3 = CheckStanceRules.load_offset(1.0, -1.0, 0.20)
	var broad: Vector3 = CheckStanceRules.load_offset(1.0, -1.0, 0.26)
	assert_gt(absf(broad.z), absf(narrow.z),
			"a broader frame protracts further — the offsets are fractions of the half-width")
	var full: Vector3 = CheckStanceRules.load_offset(1.0, -1.0, 0.22)
	var half: Vector3 = CheckStanceRules.load_offset(0.5, -1.0, 0.22)
	assert_almost_eq(half.z, full.z * 0.5, 0.0001,
			"depth scales the whole displacement linearly")


func test_the_load_never_outruns_the_shoulder_it_moves() -> void:
	# A displacement of the order of the shoulder half-width is a load-up; much
	# past it and the pad leaves the torso.
	var full: Vector3 = CheckStanceRules.load_offset(1.0, -1.0, 0.22)
	assert_lt(full.length(), 0.22, "stays inside the half-width it derives from")


func test_load_is_clamped_past_full() -> void:
	assert_eq(CheckStanceRules.load_offset(2.0, -1.0, 0.22),
			CheckStanceRules.load_offset(1.0, -1.0, 0.22),
			"an over-unit lead cannot drive the shoulder past full load")


# ── tucked_pole ───────────────────────────────────────────────────────────────

func test_the_leading_elbow_tucks_in_and_back() -> void:
	var rest := Vector3(0.55, -1.0, 0.1)
	var tucked: Vector3 = CheckStanceRules.tucked_pole(rest, 1.0)
	assert_lt(tucked.x, rest.x, "the elbow comes off its outboard hang")
	assert_gt(tucked.x, 0.0, "but stays on its own side of the body")
	assert_gt(tucked.z, rest.z, "and settles behind the rest pole")


func test_the_tuck_mirrors_onto_a_left_arm() -> void:
	var tucked: Vector3 = CheckStanceRules.tucked_pole(Vector3(-0.55, -1.0, 0.1), 1.0)
	assert_lt(tucked.x, 0.0, "a −x pole tucks toward −x, never across the body")


func test_the_trailing_arm_keeps_its_rest_pole() -> void:
	var rest := Vector3(0.55, -1.0, 0.1)
	assert_eq(CheckStanceRules.tucked_pole(rest, 0.0), rest,
			"an unloaded arm is untouched")
