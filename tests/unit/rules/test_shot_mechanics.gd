extends GutTest

# ShotMechanics — wrister + slapper power/direction + wall-pin release.

func _wrister_cfg() -> ShotMechanics.WristerConfig:
	var cfg := ShotMechanics.WristerConfig.new()
	cfg.min_wrister_power = 8.0
	cfg.max_wrister_power = 25.0
	cfg.max_wrister_charge_distance = 3.0
	cfg.backhand_power_coefficient = 0.75
	cfg.quick_shot_power = 12.0
	cfg.quick_shot_threshold = 0.1
	cfg.quick_shot_elevation = 0.10
	cfg.elevation_target_height = 0.90
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = 26.65
	return cfg

func _slapper_cfg() -> ShotMechanics.SlapperConfig:
	var cfg := ShotMechanics.SlapperConfig.new()
	cfg.min_slapper_power = 20.0
	cfg.max_slapper_power = 40.0
	cfg.max_slapper_charge_time = 1.0
	cfg.elevation_target_height = 0.65
	cfg.elevation_blade_height = 0.05
	cfg.elevation_gravity = 9.8
	cfg.elevation_goal_line_z = 26.65
	return cfg

# ── Wrister: quick shot branch ───────────────────────────────────────────────

func test_wrister_very_short_charge_uses_quick_shot_power() -> void:
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO,                   # player_pos
		Vector3(10, 0, 0),              # mouse at (10, 0, 0)
		Vector3(0.5, 0, 0),             # blade world pos
		false, false,
		0.01,                           # charge below threshold
		_wrister_cfg())
	assert_almost_eq(result.power, 12.0, 0.01, "quick shot uses fixed quick_shot_power")

func test_wrister_quick_shot_direction_from_blade() -> void:
	# Quick shot aims from the blade, not the player
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3(0, 0, 0),
		Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, false,
		0.01,
		_wrister_cfg())
	assert_gt(result.direction.x, 0.0, "direction toward the target (+X)")

# ── Wrister: full charge branch ──────────────────────────────────────────────

func test_wrister_full_charge_maxes_power() -> void:
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO,
		Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, false,
		5.0,                            # over max_wrister_charge_distance
		_wrister_cfg())
	assert_almost_eq(result.power, 25.0, 0.01, "over-full charge clamps to max_wrister_power")

func test_wrister_backhand_penalty() -> void:
	var cfg := _wrister_cfg()
	# is_backhand is computed by the controller from the blade's upper-body-local X
	# at WRISTER_AIM entry. These calls directly express the classification result.
	var rh_forehand: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, false,                # is_backhand=false (righty forehand)
		3.0, cfg)
	var rh_backhand: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(-0.5, 0, 0),
		true, false,                 # is_backhand=true (righty backhand)
		3.0, cfg)
	assert_lt(rh_backhand.power, rh_forehand.power, "right-handed backhand penalised")

	# Left-handed: natural blade side is -X. Forehand = blade at negative X, backhand = positive X.
	var lh_forehand: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(-0.5, 0, 0),
		false, false,                # is_backhand=false (lefty forehand)
		3.0, cfg)
	var lh_backhand: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		true, false,                 # is_backhand=true (lefty backhand)
		3.0, cfg)
	assert_lt(lh_backhand.power, lh_forehand.power, "left-handed backhand penalised")

	# A lefty who starts with blade at +0.1 (cross-body, inside old shoulder threshold
	# of +0.22) is still a backhand — controller passes is_backhand=true.
	var lh_slight_backhand: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.1, 0, 0),
		true, false,                 # is_backhand=true (lefty slight backhand)
		3.0, cfg)
	assert_lt(lh_slight_backhand.power, lh_forehand.power,
		"left-handed slight backhand also penalised — threshold is body center")

func test_wrister_elevation_adds_y_component() -> void:
	var cfg := _wrister_cfg()
	var flat: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, false, 3.0, cfg)
	var elevated: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, true, 3.0, cfg)
	assert_almost_eq(flat.direction.y, 0.0, 0.01)
	assert_gt(elevated.direction.y, 0.0)

func test_wrister_charged_uses_drag_direction_not_player_to_mouse() -> void:
	# Player at origin, mouse to the right (+X), but blade was dragged forward (-Z).
	# Shot should go forward (-Z), not rightward (+X).
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO,           # player_pos
		Vector3(10, 0, 0),      # mouse far to the right
		Vector3(0.5, 0, 0),     # blade world pos
		false, false,
		3.0,                    # full charge
		_wrister_cfg(),
		Vector3(0, 0, -1))      # charge_direction: dragged forward
	assert_almost_eq(result.direction.z, -1.0, 0.05, "shot follows drag direction, not mouse position")
	assert_almost_eq(result.direction.x, 0.0, 0.05, "shot does not veer toward mouse")

func test_wrister_charged_falls_back_to_mouse_when_no_drag_direction() -> void:
	# No drag direction recorded — should fall back to player→mouse aim.
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO,
		Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, false,
		3.0,
		_wrister_cfg(),
		Vector3.ZERO)           # no drag direction
	assert_gt(result.direction.x, 0.9, "falls back to player→mouse direction (+X)")

# ── Slapper ──────────────────────────────────────────────────────────────────

func test_slapper_uses_shot_direction_when_provided() -> void:
	# Mouse is far to the right (+X), locked dir is straight forward (-Z).
	# Shot should ignore mouse and go forward.
	var result: Dictionary = ShotMechanics.release_slapper(
		Vector3(0.5, 0, 0), Vector3(10, 0, 0), false, 1.0,
		_slapper_cfg(), Vector3(0, 0, -1))
	assert_almost_eq(result.direction.z, -1.0, 0.05, "locked dir overrides blade→mouse")
	assert_almost_eq(result.direction.x, 0.0, 0.05, "no veer toward mouse")

func test_slapper_falls_back_to_blade_mouse_when_no_direction() -> void:
	# No locked dir provided — falls back to blade → mouse.
	var result: Dictionary = ShotMechanics.release_slapper(
		Vector3(0, 0, 0), Vector3(10, 0, 0), false, 1.0,
		_slapper_cfg(), Vector3.ZERO)
	assert_gt(result.direction.x, 0.9, "falls back to blade→mouse (+X)")

func test_slapper_power_scales_with_charge_time() -> void:
	var cfg := _slapper_cfg()
	var short_result: Dictionary = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), false, 0.1, cfg)
	var long_result: Dictionary = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), false, 1.0, cfg)
	assert_gt(long_result.power, short_result.power)
	assert_almost_eq(long_result.power, cfg.max_slapper_power, 0.01)

func test_slapper_elevation() -> void:
	var cfg := _slapper_cfg()
	var flat: Dictionary = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), false, 1.0, cfg)
	var elevated: Dictionary = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), true, 1.0, cfg)
	assert_almost_eq(flat.direction.y, 0.0, 0.01)
	assert_gt(elevated.direction.y, 0.0)

# ── Elevation apex cap ───────────────────────────────────────────────────────

# Point-blank max-power elevated shot used to compute v_y ≈ 12 m/s (apex ~7 m).
# With the apex cap at 1.5 m, v_y_max = sqrt(2·9.8·1.5) ≈ 5.42 m/s.
func test_elevation_caps_apex_for_close_max_power_shot() -> void:
	var cfg := _wrister_cfg()
	# Origin is 2 m from the +Z goal line so the math wants a steep angle.
	var origin := Vector3(0, 0, 24.65)
	var result: Dictionary = ShotMechanics.release_wrister(
		origin, origin + Vector3(0, 0, 10),
		origin + Vector3(0.5, 0, 0),
		false, true,
		3.0,                            # full charge → max_wrister_power = 25
		cfg,
		Vector3(0, 0, 1))               # shoot toward +Z goal
	var v_y: float = result.power * result.direction.y
	var v_y_max: float = sqrt(2.0 * 9.8 * cfg.max_apex_above_blade)
	assert_almost_eq(v_y, v_y_max, 0.05,
		"close-range elevated shot at max power should be capped at apex v_y")

func test_elevation_does_not_cap_blue_line_shot() -> void:
	var cfg := _wrister_cfg()
	# Blue-line distance (D ≈ 15 m) at max power: natural v_y ≈ 4.3 m/s, under cap.
	var origin := Vector3(0, 0, 11.65)
	var result: Dictionary = ShotMechanics.release_wrister(
		origin, origin + Vector3(0, 0, 15),
		origin + Vector3(0.5, 0, 0),
		false, true,
		3.0, cfg,
		Vector3(0, 0, 1))
	var v_y: float = result.power * result.direction.y
	var v_y_max: float = sqrt(2.0 * 9.8 * cfg.max_apex_above_blade)
	assert_lt(v_y, v_y_max, "mid-range shot should fit under apex cap unmodified")
	assert_gt(v_y, 0.0)

# ── Toward-net classification ────────────────────────────────────────────────

func test_elevation_uses_fallback_when_shooting_away_from_net() -> void:
	var cfg := _wrister_cfg()
	cfg.attacking_goal_z = 26.65          # team attacks +Z goal
	cfg.away_from_net_y = 0.10
	# Player at center, shooting toward -Z (away from offensive net).
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, -10),
		Vector3(0.5, 0, 0),
		false, true,
		3.0, cfg,
		Vector3(0, 0, -1))
	# Direction is normalized; Y component reflects the small fallback Y.
	# expected_y = away_from_net_y / sqrt(1 + away_from_net_y²) ≈ 0.0995
	assert_almost_eq(result.direction.y, 0.0995, 0.005,
		"shot away from offensive net should use small fallback elevation")

func test_elevation_uses_full_math_when_shooting_at_net() -> void:
	var cfg := _wrister_cfg()
	cfg.attacking_goal_z = 26.65
	cfg.away_from_net_y = 0.10
	# Player at center, shooting toward +Z (offensive net).
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, 10),
		Vector3(0.5, 0, 0),
		false, true,
		3.0, cfg,
		Vector3(0, 0, 1))
	# Full ballistic math gives a larger Y than the away_from_net fallback.
	assert_gt(result.direction.y, 0.10,
		"shot toward offensive net should use full ballistic elevation")

func test_elevation_lateral_shot_classified_as_away_from_net() -> void:
	var cfg := _wrister_cfg()
	cfg.attacking_goal_z = 26.65
	cfg.away_from_net_y = 0.10
	# Player at center, shooting purely along +X — perpendicular to goal axis,
	# dot(shot, to_goal) = 0 < threshold (0.5).
	var result: Dictionary = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, true,
		3.0, cfg,
		Vector3(1, 0, 0))
	assert_almost_eq(result.direction.y, 0.0995, 0.005,
		"lateral shot outside net cone uses fallback")

# ── Wall-pin release ─────────────────────────────────────────────────────────

func test_wall_pin_fires_above_threshold() -> void:
	assert_true(ShotMechanics.should_release_on_wall_pin(0.5, 0.3))

func test_wall_pin_ignored_below_threshold() -> void:
	assert_false(ShotMechanics.should_release_on_wall_pin(0.2, 0.3))

func test_wall_pin_ignored_at_threshold() -> void:
	assert_false(ShotMechanics.should_release_on_wall_pin(0.3, 0.3), "equal is not above")
