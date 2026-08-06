extends GutTest

# GoalieAnatomy's vertical profile — the shape half of "what does he cover at
# height y". Pinned against the poses in GoalieBodyConfigBuilder and the
# collider boxes in Goalie.tscn; if those resize, these move with them.

const SEAM: float = GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M   # 0.86


func test_standing_pads_top_out_at_the_pad_seam() -> void:
	# The seam the shot model has always used as its HIGH-band floor is not a
	# free constant — it is where the standing pad column ends and the trunk
	# begins. Both sides of that join are pinned here so they cannot drift.
	var pads: Vector2 = GoalieAnatomy.pad_span(false)
	assert_almost_eq(pads.x, 0.02, 0.001, "standing pads bottom at the ice")
	assert_almost_eq(pads.y, SEAM, 0.001, "and top out at the pad-top seam")
	assert_almost_eq(GoalieAnatomy.torso_span(false).x, SEAM, 0.001,
			"the standing trunk is glued to that same seam")


func test_butterfly_collapses_the_pads_to_their_own_width() -> void:
	# Rolled 90°, the pad presents its 0.28 m WIDTH vertically (11 inches — the
	# real NHL pad spec) and its 0.84 m length laterally. That trade is the
	# physical reason an over-the-pad shot exists at all.
	var pads: Vector2 = GoalieAnatomy.pad_span(true)
	assert_almost_eq(pads.x, 0.0, 0.001, "butterfly pads lie on the ice")
	assert_almost_eq(pads.y, GoalieAnatomy.PAD_BOX_WIDTH_M, 0.001,
			"and are only their own box width tall")
	assert_lt(pads.y, SEAM, "going down surrenders the whole standing column")
	assert_gt(GoalieAnatomy.butterfly_pad_edge_half_width(),
			GoalieBehaviorRules.STANDING_PAD_CENTER_X_M
					+ GoalieAnatomy.PAD_BOX_WIDTH_M * 0.5,
			"what it buys back is lateral splay")


func test_the_armpit_seam_is_a_real_gap_in_the_butterfly() -> void:
	# The shot the elevation ladder's MID rung aims at. With the pads flat the
	# trunk tops out at 0.76 m and the head does not start until 0.84 m, so a
	# puck arriving in between meets nothing structural at all — and even below
	# that, the trunk alone is far narrower than the splayed pads.
	var armpit: float = 0.70
	var structural: float = GoalieAnatomy.structural_cover_half_width_at(armpit, true)
	assert_almost_eq(structural, GoalieAnatomy.torso_half_width(), 0.001,
			"at the armpit only the trunk is in the way")
	assert_lt(structural, GoalieAnatomy.butterfly_pad_edge_half_width(),
			"which is much less than the pads cover along the ice")
	var above_torso: float = 0.80
	assert_eq(GoalieAnatomy.structural_cover_half_width_at(above_torso, true), 0.0,
			"between the trunk top and the head there is no structure at all")


func test_over_the_pad_shot_clears_the_splayed_pads() -> void:
	# The LOW rung's target (0.41 m). It is above the flat pads, so the 0.84 m
	# splay that dominates the along-the-ice band does not apply to it — which
	# is precisely what a two-band model reading 0.84 everywhere below the seam
	# cannot express.
	var over_pad: float = 0.41
	assert_gt(over_pad, GoalieAnatomy.pad_span(true).y, "clears the flat pads")
	assert_lt(GoalieAnatomy.structural_cover_half_width_at(over_pad, true),
			GoalieAnatomy.butterfly_pad_edge_half_width(),
			"so the splayed-pad half-width is the wrong cover for it")


func test_standing_keeper_covers_the_low_and_mid_net_with_pads() -> void:
	# The mirror case: upright, the same two heights are pad column, because
	# the column runs all the way to the seam. This is why the over-pad and
	# armpit shots are reads on POSTURE and not simply "shoot higher".
	var column: float = GoalieBehaviorRules.STANDING_PAD_CENTER_X_M \
			+ GoalieAnatomy.PAD_BOX_WIDTH_M * 0.5
	for y: float in [0.41, 0.70]:
		assert_almost_eq(GoalieAnatomy.structural_cover_half_width_at(y, false),
				column, 0.001, "standing, %.2f m is still pad" % y)


func test_hand_vertical_reach_is_the_glove_box() -> void:
	# Hands are excluded from the structural cover on purpose (they move and are
	# raced), so the anatomy's job for them is only "does one reach this height".
	var hand_y: float = 0.49   # GoalieStickRules butterfly hand height
	assert_true(GoalieAnatomy.hand_covers_height(0.49, hand_y), "own height")
	assert_true(GoalieAnatomy.hand_covers_height(0.60, hand_y), "just above")
	assert_false(GoalieAnatomy.hand_covers_height(0.70, hand_y),
			"a committed-low hand does not reach the armpit")
	assert_false(GoalieAnatomy.hand_covers_height(0.99, hand_y),
			"nor anywhere near upstairs")


func test_structural_cover_falls_off_with_height_when_down() -> void:
	# Monotone-ish sanity: going up through a downed keeper you pass pads →
	# trunk → nothing → head, never widening except at the head.
	var down_pads: float = GoalieAnatomy.structural_cover_half_width_at(0.10, true)
	var down_torso: float = GoalieAnatomy.structural_cover_half_width_at(0.50, true)
	var down_gap: float = GoalieAnatomy.structural_cover_half_width_at(0.80, true)
	assert_gt(down_pads, down_torso, "pads are the widest thing he has")
	assert_gt(down_torso, down_gap, "and the trunk still beats open air")
	assert_eq(down_gap, 0.0, "open air is open")
