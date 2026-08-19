extends GutTest

# AccuracyDrillRules — the Shot Accuracy drill's target pool and its
# no-repeat random sequencing. Includes a calibration test pinning the
# advertised promise that the mid-side targets are reachable with one notch
# of loft (ELEVATION_LOW), so a loft retune that breaks the drill fails here.



func test_pool_and_names_are_parallel() -> void:
	assert_eq(AccuracyDrillRules.TARGET_POSITIONS.size(),
			AccuracyDrillRules.TARGET_NAMES.size())
	assert_gt(AccuracyDrillRules.TARGET_POSITIONS.size(), 1,
			"pick_next's no-repeat needs at least two targets")


func test_targets_sit_inside_the_net_mouth() -> void:
	for i: int in AccuracyDrillRules.TARGET_POSITIONS.size():
		var p: Vector2 = AccuracyDrillRules.TARGET_POSITIONS[i]
		assert_lte(absf(p.x), GameRules.NET_HALF_WIDTH,
				"%s centre is outside the posts" % AccuracyDrillRules.TARGET_NAMES[i])
		assert_gt(p.y, 0.0, "%s centre is at/below the ice" % AccuracyDrillRules.TARGET_NAMES[i])
		assert_lt(p.y, GameRules.NET_HEIGHT,
				"%s centre is above the crossbar" % AccuracyDrillRules.TARGET_NAMES[i])


# The SIDE targets' calibration: a LOW-loft shot launches at
# loft_vertical_speed_low vertically, so its apex above the launch height is
# vy²/2g. A crossing at that apex must land within HIT_RADIUS of the target
# centre — that's the "achievable with one notch of loft" promise. (FLAT
# stays on the ice and can't reach them; HIGH passes through on its arc.)
func test_side_targets_are_reachable_with_low_loft() -> void:
	# Read off a pristine controller rather than the script's property metadata:
	# the shot tunables are plain fields (no scene overrides any of them), and
	# get_property_default_value only answers for exported ones.
	var vy_low: float = float(autofree(SkaterController.new()).loft_vertical_speed_low)
	var apex: float = vy_low * vy_low / (2.0 * GameRules.GRAVITY_M_S2)
	for i: int in AccuracyDrillRules.TARGET_NAMES.size():
		if not AccuracyDrillRules.TARGET_NAMES[i].contains("SIDE"):
			continue
		var p: Vector2 = AccuracyDrillRules.TARGET_POSITIONS[i]
		assert_lte(p.y, apex + AccuracyDrillRules.HIT_RADIUS,
				"%s is out of a LOW-loft shot's reach (apex %.2f m)" % [
						AccuracyDrillRules.TARGET_NAMES[i], apex])
		# And meaningfully above the flat band, so it genuinely requires loft.
		assert_gt(p.y - AccuracyDrillRules.HIT_RADIUS, 0.0,
				"%s is hittable along the ice — it wouldn't need loft" %
						AccuracyDrillRules.TARGET_NAMES[i])


func test_pick_next_first_pick_stays_in_range() -> void:
	var n: int = AccuracyDrillRules.TARGET_POSITIONS.size()
	for roll: int in n * 2:
		var idx: int = AccuracyDrillRules.pick_next(-1, roll)
		assert_between(idx, 0, n - 1)


func test_pick_next_never_repeats_previous() -> void:
	var n: int = AccuracyDrillRules.TARGET_POSITIONS.size()
	for prev: int in n:
		for roll: int in (n - 1) * 2:
			var idx: int = AccuracyDrillRules.pick_next(prev, roll)
			assert_ne(idx, prev, "prev=%d roll=%d repeated" % [prev, roll])
			assert_between(idx, 0, n - 1)


func test_pick_next_reaches_every_other_target() -> void:
	var n: int = AccuracyDrillRules.TARGET_POSITIONS.size()
	for prev: int in n:
		var seen: Dictionary = {}
		for roll: int in n - 1:
			seen[AccuracyDrillRules.pick_next(prev, roll)] = true
		assert_eq(seen.size(), n - 1,
				"rolls 0..%d from prev=%d should cover all other targets" % [n - 2, prev])
