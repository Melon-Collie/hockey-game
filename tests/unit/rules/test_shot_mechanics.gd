extends GutTest

# ShotMechanics — wrister + slapper power/direction + wall-pin release.

func _wrister_cfg() -> ShotMechanics.WristerConfig:
	var cfg := ShotMechanics.WristerConfig.new()
	cfg.min_wrister_power = 8.0
	cfg.max_wrister_power = 25.0
	cfg.backhand_power_coefficient = 0.75
	cfg.quick_pass_power = 12.0
	cfg.loft_vy_low = 2.2
	cfg.loft_vy_high = 5.4
	cfg.full_sweep_speed = 7.0
	cfg.power_curve = 0.85
	return cfg

# Cursor/sweep speed that saturates the power model for _wrister_cfg() (> full_sweep_speed).
const FULL_SWEEP: float = 10.0

func _slapper_cfg() -> ShotMechanics.SlapperConfig:
	var cfg := ShotMechanics.SlapperConfig.new()
	cfg.min_slapper_power = 20.0
	cfg.max_slapper_power = 40.0
	cfg.max_slapper_charge_time = 1.0
	return cfg

# ── Wrister: quick pass branch ───────────────────────────────────────────────

func test_wrister_quick_pass_uses_quick_pass_power() -> void:
	# is_quick_pass=true — fixed quick power regardless of any sweep speed.
	var result: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO,                   # player_pos
		Vector3(10, 0, 0),              # mouse at (10, 0, 0)
		Vector3(0.5, 0, 0),             # blade world pos
		false, 0,
		_wrister_cfg(),
		Vector3.ZERO,
		true)                           # is_quick_pass
	assert_almost_eq(result.power, 12.0, 0.01, "quick pass uses fixed quick_pass_power")

func test_wrister_quick_pass_aims_at_cursor_not_blade_offset() -> void:
	# Regression guard for "quick passes don't go the right way": the pass aims
	# blade→cursor, so with the cursor straight ahead (−Z) the pass goes straight
	# ahead even though the blade sits off to the forehand side (+X, the carry
	# offset). The OLD player→blade aim would veer toward that +X offset; the
	# blade→cursor aim tracks the cursor line instead.
	var result: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3(0, 0, 0),               # player at origin
		Vector3(0, 0, -10),             # cursor straight ahead (−Z)
		Vector3(0.6, 0, -0.4),          # blade offset to the forehand carry side (+X)
		false, 0,
		_wrister_cfg(),
		Vector3.ZERO,
		true)                           # is_quick_pass
	assert_almost_eq(result.direction.z, -1.0, 0.05, "pass tracks the cursor line (−Z), not the blade offset")
	assert_lt(absf(result.direction.x), 0.1, "pass does not veer toward the carry-side blade offset")

# ── Wrister: charged branch ──────────────────────────────────────────────────

func test_wrister_full_speed_sweep_maxes_power() -> void:
	var result: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO,
		Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 0,
		_wrister_cfg(),
		Vector3.ZERO, false, FULL_SWEEP)  # sweep over full_sweep_speed
	assert_almost_eq(result.power, 25.0, 0.01, "over-full sweep speed clamps to max_wrister_power")

func test_wrister_backhand_penalty() -> void:
	var cfg := _wrister_cfg()
	# is_backhand is computed by the controller from the swing chirality
	# (ShotMechanics.is_backhand_from_swing) at release time. These calls
	# directly express the classification result.
	var rh_forehand: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 0, cfg)          # is_backhand=false (righty forehand)
	var rh_backhand: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(-0.5, 0, 0),
		true, 0, cfg)           # is_backhand=true (righty backhand)
	assert_lt(rh_backhand.power, rh_forehand.power, "right-handed backhand penalised")

	# Left-handed: natural blade side is -X. Forehand = blade at negative X, backhand = positive X.
	var lh_forehand: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(-0.5, 0, 0),
		false, 0, cfg)          # is_backhand=false (lefty forehand)
	var lh_backhand: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		true, 0, cfg)           # is_backhand=true (lefty backhand)
	assert_lt(lh_backhand.power, lh_forehand.power, "left-handed backhand penalised")

	# A lefty who starts with blade at +0.1 (cross-body, inside old shoulder threshold
	# of +0.22) is still a backhand — controller passes is_backhand=true.
	var lh_slight_backhand: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.1, 0, 0),
		true, 0, cfg)           # is_backhand=true (lefty slight backhand)
	assert_lt(lh_slight_backhand.power, lh_forehand.power,
		"left-handed slight backhand also penalised — threshold is body center")

func test_wrister_loft_levels_order_y_component() -> void:
	var cfg := _wrister_cfg()
	var flat: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 0, cfg)
	var low: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 1, cfg)
	var high: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 2, cfg)
	assert_almost_eq(flat.direction.y, 0.0, 0.001)
	assert_gt(low.direction.y, 0.0)
	assert_gt(high.direction.y, low.direction.y, "HIGH lofts more than LOW")

func test_wrister_charged_uses_drag_direction_not_player_to_mouse() -> void:
	# Player at origin, mouse to the right (+X), but blade was dragged forward (-Z).
	# Shot should go forward (-Z), not rightward (+X).
	var result: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO,           # player_pos
		Vector3(10, 0, 0),      # mouse far to the right
		Vector3(0.5, 0, 0),     # blade world pos
		false, 0,
		_wrister_cfg(),
		Vector3(0, 0, -1))      # charge_direction: dragged forward
	assert_almost_eq(result.direction.z, -1.0, 0.05, "shot follows drag direction, not mouse position")
	assert_almost_eq(result.direction.x, 0.0, 0.05, "shot does not veer toward mouse")

func test_wrister_hard_binary_quick_vs_charged() -> void:
	# HARD BINARY (no blend): with the SAME drag, is_quick_pass flips the shot
	# categorically. Quick = aim blade→cursor (+X here, toward the cursor) at
	# quick_pass_power; charged = aim along the drag (-Z) at charged power. Mouse is
	# +X, drag is -Z, so the aim axis itself flips between the two.
	var cfg := _wrister_cfg()
	var drag := Vector3(0, 0, -1)
	var quick: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, drag, true)          # is_quick_pass
	var charged: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, drag, false, FULL_SWEEP)  # charged wrister
	assert_gt(quick.direction.x, 0.9, "quick pass aims blade→cursor (+X), ignores drag")
	assert_almost_eq(charged.direction.z, -1.0, 0.05, "charged wrister aims along drag (-Z)")
	assert_almost_eq(quick.power, cfg.quick_pass_power, 0.01, "quick pass fires fixed quick_pass_power")
	assert_almost_eq(charged.power, cfg.max_wrister_power, 0.01, "charged wrister scales power with sweep speed")


func test_wrister_charged_direction_independent_of_body_position() -> void:
	# Netcode-critical: a charged wrister's aim is the drag vector, with NO blend
	# of the body-relative tap direction. So the same drag yields the same shot
	# direction regardless of where the shooter's body / blade sit — which is what
	# lets the host's re-derived shot match the client's predicted one.
	var cfg := _wrister_cfg()
	var drag := Vector3(0, 0, -1)
	var a: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, drag)
	var b: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3(3, 0, -2), Vector3(10, 0, 0), Vector3(-1.0, 0, 4),  # different body + blade
		false, 0, cfg, drag)
	assert_almost_eq(a.direction.x, b.direction.x, 0.001, "charged aim X independent of body")
	assert_almost_eq(a.direction.z, b.direction.z, 0.001, "charged aim Z independent of body")

func test_wrister_charged_falls_back_to_mouse_when_no_drag_direction() -> void:
	# No drag direction recorded — should fall back to player→mouse aim.
	var result: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO,
		Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 0,
		_wrister_cfg(),
		Vector3.ZERO)           # no drag direction
	assert_gt(result.direction.x, 0.9, "falls back to player→mouse direction (+X)")

# ── Wrister power model: pure cursor speed, feel-curve shaped ─────────────────

func test_wrister_slow_sweep_is_soft() -> void:
	# A slow deliberate sweep is a touch pass, not a full shot — the cursor speed
	# is the whole power signal (distance-independent).
	var cfg := _wrister_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3(1, 0, 0), false, 1.0)  # 1 m/s sweep
	var midpoint: float = (cfg.min_wrister_power + cfg.max_wrister_power) * 0.5
	assert_lt(r.power, midpoint, "slow sweep stays in the soft half")
	assert_gt(r.power, cfg.min_wrister_power, "still above the bare floor")

func test_wrister_power_monotonic_in_sweep_speed() -> void:
	var cfg := _wrister_cfg()
	var prev_power: float = -1.0
	for sweep: float in [0.0, 2.0, 4.0, 6.0, 8.0]:
		var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
			Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
			false, 0, cfg, Vector3(1, 0, 0), false, sweep)
		assert_gt(r.power, prev_power, "power never decreases as the sweep speeds up")
		prev_power = r.power

func test_wrister_zero_full_sweep_speed_floors_power() -> void:
	# Uncalibrated config: full_sweep_speed <= 0 disables the wrister power axis,
	# so power_t is zero and the release floors at min_wrister_power.
	var cfg := _wrister_cfg()
	cfg.full_sweep_speed = 0.0
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3(1, 0, 0), false, 5.0)
	assert_almost_eq(r.power, cfg.min_wrister_power, 0.01,
		"disabled speed axis floors the release power")

func test_wrister_quick_pass_ignores_sweep_speed() -> void:
	var cfg := _wrister_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3.ZERO, true, FULL_SWEEP)
	assert_almost_eq(r.power, cfg.quick_pass_power, 0.01,
		"quick pass stays at fixed pass power whatever the sweep did")

func test_wrister_speed_for_power_t_round_trip() -> void:
	# The bot inverse: a target power fraction → a cursor speed that, run forward
	# through the pure-speed model, releases at that fraction.
	var cfg := _wrister_cfg()
	for target: float in [0.0, 0.3, 0.62, 1.0]:
		var speed: float = ShotMechanics.wrister_speed_for_power_t(target, cfg)
		var t: float = ShotMechanics.wrister_power_t(speed, cfg)
		assert_almost_eq(t, target, 0.001, "speed_for_power_t inverts to %.2f" % target)

func test_wrister_speed_for_power_t_clamps() -> void:
	var cfg := _wrister_cfg()
	assert_almost_eq(ShotMechanics.wrister_speed_for_power_t(0.0, cfg), 0.0, 0.001)
	assert_almost_eq(ShotMechanics.wrister_speed_for_power_t(1.5, cfg),
			cfg.full_sweep_speed, 0.001, "over-1 target clamps to the full-speed reference")

# ── Wrister: travel-gated ceiling ─────────────────────────────────────────────
# The top of the band must be EARNED with blade travel: cursor speed alone (a
# twitch, a wiggle, a cranked sensitivity) caps at the flick-pass floor. The
# gate is a cap — it can only lower the speed-derived t, never raise it — so
# everything below the floor (the touch-pass precision band) is bit-identical
# to the ungated model.

func _gated_cfg() -> ShotMechanics.WristerConfig:
	var cfg := _wrister_cfg()
	cfg.full_stroke_travel = 1.0
	cfg.travel_cap_floor = 0.4
	return cfg

func test_travel_cap_disabled_when_full_travel_unset() -> void:
	# full_stroke_travel <= 0 disables the gate — cap is 1.0 for any travel.
	assert_almost_eq(ShotMechanics.wrister_travel_cap_t(0.0, _wrister_cfg()),
		1.0, 0.001, "unset gate never caps")

func test_travel_cap_zero_travel_floors_at_flick_pass_tier() -> void:
	assert_almost_eq(ShotMechanics.wrister_travel_cap_t(0.0, _gated_cfg()),
		0.4, 0.001, "zero travel earns the flick-pass floor, not zero")

func test_travel_cap_full_travel_unlocks_ceiling() -> void:
	assert_almost_eq(ShotMechanics.wrister_travel_cap_t(1.0, _gated_cfg()),
		1.0, 0.001, "a full stroke unlocks the whole band")
	assert_almost_eq(ShotMechanics.wrister_travel_cap_t(2.5, _gated_cfg()),
		1.0, 0.001, "over-travel clamps at 1")

func test_travel_cap_scales_between_floor_and_full() -> void:
	assert_almost_eq(ShotMechanics.wrister_travel_cap_t(0.7, _gated_cfg()),
		0.7, 0.001, "partial stroke earns a proportional ceiling")

func test_wrister_twitch_full_speed_no_travel_caps_at_floor() -> void:
	# THE exploit case: max cursor speed with no blade travel (wiggle / jerk /
	# cranked Shot Power Sensitivity) releases at the flick-pass tier, not max.
	var cfg := _gated_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3(1, 0, 0), false, FULL_SWEEP, 0.0)
	var floor_power: float = lerpf(cfg.min_wrister_power, cfg.max_wrister_power,
			cfg.travel_cap_floor)
	assert_almost_eq(r.power, floor_power, 0.01,
		"speed without travel caps at the flick-pass tier")

func test_wrister_full_sweep_with_full_travel_maxes_power() -> void:
	# The honest rip: full speed AND a real swept stroke — untouched by the gate.
	var cfg := _gated_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3(1, 0, 0), false, FULL_SWEEP, 1.2)
	assert_almost_eq(r.power, cfg.max_wrister_power, 0.01,
		"an earned stroke keeps the full ceiling")

func test_wrister_soft_sweep_below_floor_untouched_by_gate() -> void:
	# The mastered touch pass: a slow sweep's speed-derived t sits under the
	# floor, so gated and ungated release identically even at zero travel.
	var slow_sweep: float = 1.0
	var gated: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, _gated_cfg(), Vector3(1, 0, 0), false, slow_sweep, 0.0)
	var ungated: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, _wrister_cfg(), Vector3(1, 0, 0), false, slow_sweep)
	assert_almost_eq(gated.power, ungated.power, 0.001,
		"the soft band is bit-identical to the ungated model")

func test_wrister_default_travel_bypasses_gate() -> void:
	# Callers that pass no stroke_travel (bots via INF, quick shots) keep the
	# full ceiling even on a gated config.
	var cfg := _gated_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
		false, 0, cfg, Vector3(1, 0, 0), false, FULL_SWEEP)
	assert_almost_eq(r.power, cfg.max_wrister_power, 0.01,
		"default (INF) stroke_travel means no gate")

# ── Forehand/backhand from swing chirality ───────────────────────────────────
# Convention (empirically flippable): a POSITIVE net swing rotation is a
# forehand for a right-handed shooter, mirrored for lefties. The classifier
# reads only the accumulated rotation sign — the sweep geometry that produced
# it is tested against ChargeTracking.swing_step in test_charge_tracking.

func test_swing_positive_is_forehand_righty_backhand_lefty() -> void:
	assert_false(ShotMechanics.is_backhand_from_swing(0.8, false),
		"positive swing is a RH forehand")
	assert_true(ShotMechanics.is_backhand_from_swing(0.8, true),
		"positive swing is a LH backhand (mirrored)")

func test_swing_negative_is_backhand_righty_forehand_lefty() -> void:
	assert_true(ShotMechanics.is_backhand_from_swing(-0.8, false),
		"negative swing is a RH backhand")
	assert_false(ShotMechanics.is_backhand_from_swing(-0.8, true),
		"negative swing is a LH forehand (mirrored)")

func test_swing_deadband_defaults_forehand() -> void:
	# A small net rotation (a near-straight push) stays forehand for either hand.
	assert_false(ShotMechanics.is_backhand_from_swing(-0.2, false, 0.35),
		"RH: rotation inside the deadband defaults forehand")
	assert_false(ShotMechanics.is_backhand_from_swing(0.2, true, 0.35),
		"LH: rotation inside the deadband defaults forehand")
	assert_true(ShotMechanics.is_backhand_from_swing(-0.5, false, 0.35),
		"RH: rotation past the deadband is a backhand")

func test_swing_zero_is_forehand() -> void:
	assert_false(ShotMechanics.is_backhand_from_swing(0.0, false),
		"no rotation → forehand default")
	assert_false(ShotMechanics.is_backhand_from_swing(0.0, true),
		"no rotation → forehand default (LH)")

# ── Slapper ──────────────────────────────────────────────────────────────────

func test_slapper_uses_shot_direction_when_provided() -> void:
	# Mouse is far to the right (+X), locked dir is straight forward (-Z).
	# Shot should ignore mouse and go forward.
	var result: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3(0.5, 0, 0), Vector3(10, 0, 0), 0, 1.0,
		_slapper_cfg(), Vector3(0, 0, -1))
	assert_almost_eq(result.direction.z, -1.0, 0.05, "locked dir overrides blade→mouse")
	assert_almost_eq(result.direction.x, 0.0, 0.05, "no veer toward mouse")

func test_slapper_falls_back_to_blade_mouse_when_no_direction() -> void:
	# No locked dir provided — falls back to blade → mouse.
	var result: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3(0, 0, 0), Vector3(10, 0, 0), 0, 1.0,
		_slapper_cfg(), Vector3.ZERO)
	assert_gt(result.direction.x, 0.9, "falls back to blade→mouse (+X)")

func test_slapper_fills_and_reuses_out_scratch() -> void:
	# The goalie pre-lean re-solves the release every windup tick to publish
	# predicted_shot_velocity (SkaterController._update_slapper_charge). That hot
	# path passes a caller-owned scratch so it doesn't churn the heap — assert the
	# out instance is filled and returned (not a fresh allocation), mirroring the
	# wrister's out contract.
	var scratch := ShotMechanics.ShotResult.new()
	var result: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3(0.5, 0, 0), Vector3(10, 0, 0), 0, 1.0,
		_slapper_cfg(), Vector3(0, 0, -1), scratch)
	assert_eq(result, scratch, "release_slapper writes into the provided scratch")
	assert_almost_eq(scratch.direction.z, -1.0, 0.05, "scratch carries the locked heading")

func test_slapper_power_scales_with_charge_time() -> void:
	var cfg := _slapper_cfg()
	var short_result: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), 0, 0.1, cfg)
	var long_result: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), 0, 1.0, cfg)
	assert_gt(long_result.power, short_result.power)
	assert_almost_eq(long_result.power, cfg.max_slapper_power, 0.01)

func test_slapper_loft() -> void:
	var cfg := _slapper_cfg()
	var flat: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), 0, 1.0, cfg)
	var high: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
		Vector3.ZERO, Vector3(10, 0, 0), 2, 1.0, cfg)
	assert_almost_eq(flat.direction.y, 0.0, 0.001)
	assert_gt(high.direction.y, 0.0)

# ── Loft physics: the manual angle ladder ────────────────────────────────────
# docs/elevation-rework-plan.md v3 — four levels, each a SET launch angle from
# the gear's ladder. Power and position never enter the angle; arrival height
# is emergent from angle × charge × range, and missing high is a real outcome.

# Crossing height (m above launch) of a released shot `dist` meters along its
# own line, from the ShotResult alone.
func _crossing_height(r: ShotMechanics.ShotResult, dist: float) -> float:
	var v_y: float = r.power * r.direction.y
	var v_h: float = r.power * Vector2(r.direction.x, r.direction.z).length()
	var t: float = dist / v_h
	return v_y * t - 0.5 * GameRules.GRAVITY_M_S2 * t * t


func _wrister_at(cfg: ShotMechanics.WristerConfig, level: int,
		sweep: float, dir: Vector3 = Vector3(0, 0, 1)) -> ShotMechanics.ShotResult:
	return ShotMechanics.release_wrister(
			Vector3.ZERO, Vector3(0, 0, 10), Vector3(0.5, 0, 0),
			false, level, cfg, dir, false, sweep)


func test_levels_are_set_angles_independent_of_charge() -> void:
	# The defining property of the ladder: a level's launch ANGLE is constant
	# across shot power — charge buys pace, the level buys angle, and where
	# the arc arrives is the player's read.
	var cfg := _wrister_cfg()
	var expected: Array[float] = [
			0.0, cfg.loft_tan_low, cfg.loft_tan_mid, cfg.loft_tan_high]
	for level: int in 4:
		for sweep: float in [2.0, FULL_SWEEP]:
			var r: ShotMechanics.ShotResult = _wrister_at(cfg, level, sweep)
			var xz_len: float = Vector2(r.direction.x, r.direction.z).length()
			assert_almost_eq(r.direction.y / maxf(xz_len, 0.0001), expected[level],
					0.0001, "level %d at its set angle (sweep %.1f)" % [level, sweep])


func test_ladder_orders_by_level() -> void:
	var cfg := _wrister_cfg()
	var prev: float = -0.1
	for level: int in 4:
		var r: ShotMechanics.ShotResult = _wrister_at(cfg, level, FULL_SWEEP)
		assert_gt(r.direction.y, prev, "each rung launches steeper (level %d)" % level)
		prev = r.direction.y


func test_loft_is_direction_and_position_free() -> void:
	# Same level, same power -> same y, whatever the direction — the ladder
	# restored full position-independence (no goal-plane term anywhere).
	var cfg := _wrister_cfg()
	var toward: ShotMechanics.ShotResult = _wrister_at(cfg, 2, FULL_SWEEP, Vector3(0, 0, 1))
	var away: ShotMechanics.ShotResult = _wrister_at(cfg, 2, FULL_SWEEP, Vector3(0, 0, -1))
	var cross: ShotMechanics.ShotResult = _wrister_at(cfg, 2, FULL_SWEEP, Vector3(1, 0, 0))
	assert_almost_eq(toward.direction.y, away.direction.y, 0.0001, "direction-free")
	assert_almost_eq(toward.direction.y, cross.direction.y, 0.0001, "cross-ice too")


func test_missing_high_is_a_real_outcome() -> void:
	# A HIGH two zones past its home range crosses the goal plane above the
	# crossbar — the price of greed the model is built on. Ease the charge and
	# the same rung stays under the bar.
	# Runs at the LIVE wrister ceiling rather than this file's 25 m/s fixture:
	# the ladder is authored against the real 33 m/s top of the band, and at
	# 25 m/s the M92's HIGH apexes at 1.16 m — under the bar, so it could not
	# sail at any range and the property would be untestable.
	var cfg := _wrister_cfg()
	cfg.max_wrister_power = GameRules.DEFAULT_WRISTER_POWER_MAX_M_S
	var full: ShotMechanics.ShotResult = _wrister_at(cfg, 3, FULL_SWEEP)
	assert_gt(_crossing_height(full, 8.0), GameRules.NET_HEIGHT + 0.03,
			"full-charge HIGH from 8 m sails over the bar")
	var eased: ShotMechanics.ShotResult = _wrister_at(cfg, 3, 2.5)
	assert_lt(_crossing_height(eased, 8.0), GameRules.NET_HEIGHT,
			"an eased charge on the same rung stays under the bar")


func test_flattest_ladder_never_sails() -> void:
	# The same never-sails property as the table-level check, but driven
	# through the real release: the M88's LOW rung off a max slapper, INCLUDING
	# the blade's own +3% slapper lean (curve_slap_mult). That lean is the
	# M88's alone and is exactly what a bare-40 m/s fixture used to miss, so
	# the guard has to carry it or it is checking a shot nobody takes.
	var m88 := PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_CLOSED, 1, 1)
	var cfg := _slapper_cfg()
	cfg.max_slapper_power = GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S \
			* m88.curve_slap_mult()
	cfg.loft_tan_low = m88.curve_loft_tan_low()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_slapper(
			Vector3.ZERO, Vector3(0, 0, 10), 1, 1.0, cfg, Vector3(0, 0, 1))
	var v_y: float = r.power * r.direction.y
	var apex: float = v_y * v_y / (2.0 * GameRules.GRAVITY_M_S2)
	assert_lt(apex, GameRules.NET_HEIGHT,
			"M88 LOW at max slap apexes under the bar")


# Quick passes ride the fixed-speed loft table — LOW at pass power IS the
# saucer pass, in any direction including toward the net.
func test_quick_pass_loft_uses_level_table() -> void:
	var cfg := _wrister_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(10, 0, 0),
		Vector3(0.5, 0, 0),
		false, 1,
		cfg,
		Vector3.ZERO,
		true)                           # is_quick_pass
	var v_y: float = r.power * r.direction.y
	assert_almost_eq(v_y, cfg.loft_vy_low, 0.01,
		"quick-shot saucer launches at the LOW level vertical speed")


func test_quick_pass_flip_is_gear_free() -> void:
	# MID and HIGH quick passes both ride the fixed flip speed — pass
	# mechanics never read the shot ladder, so every blade sauces and flips
	# identically.
	var cfg := _wrister_cfg()
	cfg.loft_tan_high = 0.53171   # an M28 shot ladder changes nothing here
	for level: int in [2, 3]:
		var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
				Vector3.ZERO, Vector3(10, 0, 0), Vector3(0.5, 0, 0),
				false, level, cfg, Vector3.ZERO, true)
		assert_almost_eq(r.power * r.direction.y, cfg.loft_vy_high, 0.01,
				"the flip pass launches at the fixed speed at level %d" % level)


func test_direction_y_under_host_clamp_everywhere() -> void:
	# The steepest authored ladder (M28: 8.5/16/30°) at every level and
	# charge stays under the host's forged-direction clamp.
	var cfg := _wrister_cfg()
	cfg.loft_tan_low = 0.14945
	cfg.loft_tan_mid = 0.34433
	cfg.loft_tan_high = 0.53171
	for level: int in 4:
		for sweep: float in [0.0, 4.0, FULL_SWEEP]:
			var r: ShotMechanics.ShotResult = _wrister_at(cfg, level, sweep)
			assert_lt(r.direction.y, ShotReleaseRules.MAX_DIRECTION_Y,
					"honest shot under the clamp (lvl %d)" % level)


func test_loft_y_zero_for_flat() -> void:
	assert_almost_eq(ShotMechanics.loft_y(20.0, 0.0), 0.0, 0.000001)


func test_loft_y_exact_solution() -> void:
	# y = vy / sqrt(p^2 - vy^2): launching at power 20 with a fixed vy of 5.4
	# must give a vertical speed of exactly 5.4 after normalization. (The
	# fixed-speed path serves quick passes and the puck's deflect-tip solve.)
	var y: float = ShotMechanics.loft_y(20.0, 5.4)
	var v_y: float = 20.0 * y / sqrt(1.0 + y * y)
	assert_almost_eq(v_y, 5.4, 0.0001)


func test_shot_loft_y_is_the_ladder_lookup() -> void:
	assert_almost_eq(ShotMechanics.shot_loft_y(0, 0.1, 0.2, 0.3), 0.0, 0.000001)
	assert_almost_eq(ShotMechanics.shot_loft_y(1, 0.1, 0.2, 0.3), 0.1, 0.000001)
	assert_almost_eq(ShotMechanics.shot_loft_y(2, 0.1, 0.2, 0.3), 0.2, 0.000001)
	assert_almost_eq(ShotMechanics.shot_loft_y(3, 0.1, 0.2, 0.3), 0.3, 0.000001)
	# Above-HIGH clamps to HIGH; every rung is bounded by the universal guard.
	assert_almost_eq(ShotMechanics.shot_loft_y(7, 0.1, 0.2, 0.3), 0.3, 0.000001)
	assert_almost_eq(ShotMechanics.shot_loft_y(3, 0.1, 0.2, 9.9),
			ShotMechanics.MAX_LOFT_RATIO, 0.000001)


# ── Wall-pin release ─────────────────────────────────────────────────────────

func test_wall_pin_fires_above_threshold() -> void:
	assert_true(ShotMechanics.should_release_on_wall_pin(0.5, 0.3))

func test_wall_pin_ignored_below_threshold() -> void:
	assert_false(ShotMechanics.should_release_on_wall_pin(0.2, 0.3))

func test_wall_pin_ignored_at_threshold() -> void:
	assert_false(ShotMechanics.should_release_on_wall_pin(0.3, 0.3), "equal is not above")


# ── Wall-pin release direction ───────────────────────────────────────────────
# Convention: wall_normal points INWARD (away from the boards). A puck lost on
# the wall should squirt ALONG the boards in the carrier's travel direction.

func test_wall_pin_release_runs_along_boards_not_inward() -> void:
	# Boards on +X (normal points inward toward -X), carrier skating in +Z.
	var wall_normal := Vector3(-1, 0, 0)
	var carrier_vel := Vector3(0.2, 0, 5.0)  # mostly along the wall (+Z)
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, carrier_vel)
	assert_almost_eq(dir.length(), 1.0, 0.001, "normalized")
	assert_almost_eq(dir.z, 1.0, 0.001, "released along the boards (+Z)")
	assert_almost_eq(dir.x, 0.0, 0.001, "no inward/outward component")

func test_wall_pin_release_signs_by_carrier_direction() -> void:
	var wall_normal := Vector3(-1, 0, 0)
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, Vector3(0, 0, -4.0))
	assert_almost_eq(dir.z, -1.0, 0.001, "carrier going -Z loses it -Z along the boards")

func test_wall_pin_release_ignores_into_wall_velocity() -> void:
	# Velocity is purely into the wall (+X) — no along-wall component → inward normal.
	var wall_normal := Vector3(-1, 0, 0)
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, Vector3(6.0, 0, 0))
	assert_almost_eq(dir.x, -1.0, 0.001, "pinned dead into the wall frees along the inward normal")

func test_wall_pin_release_no_along_momentum_falls_back_inward() -> void:
	var wall_normal := Vector3(0, 0, -1)  # boards on +Z, inward toward -Z
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, Vector3.ZERO)
	assert_eq(dir, Vector3(0, 0, -1), "no momentum → inward normal so the puck still frees")

func test_wall_pin_release_no_wall_normal_uses_heading() -> void:
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(Vector3.ZERO, Vector3(3.0, 0, 0))
	assert_almost_eq(dir.x, 1.0, 0.001, "degenerate normal → carrier heading")

func test_wall_pin_release_fully_degenerate_returns_zero() -> void:
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(Vector3.ZERO, Vector3.ZERO)
	assert_eq(dir, Vector3.ZERO, "no normal and no momentum → ZERO (caller fallback)")

func test_wall_pin_release_inward_bias_peels_off_the_boards() -> void:
	# Boards on +X (inward -X), carrier along +Z. A positive bias tips the release
	# slightly inward (-X) while staying mostly along the boards (+Z).
	var wall_normal := Vector3(-1, 0, 0)
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, Vector3(0, 0, 5.0), 0.25)
	assert_almost_eq(dir.length(), 1.0, 0.001, "normalized")
	assert_lt(dir.x, 0.0, "biased inward, away from the boards")
	assert_gt(dir.z, 0.0, "still travelling along the boards")
	assert_gt(dir.z, absf(dir.x), "along-wall component dominates a small bias")

func test_wall_pin_release_bias_does_not_affect_dead_pin() -> void:
	# No along-wall momentum still returns the pure inward normal regardless of bias.
	var wall_normal := Vector3(-1, 0, 0)
	var dir: Vector3 = ShotMechanics.wall_pin_release_direction(wall_normal, Vector3.ZERO, 0.25)
	assert_eq(dir, Vector3(-1, 0, 0), "dead pin frees along the inward normal, bias irrelevant")


# ── Follow-through aim blend ──────────────────────────────────────────────────

func test_follow_through_aim_holds_shot_line_before_tail() -> void:
	# Below the tail (return_frac=0.4 → tail starts at t=0.6) the aim is the shot
	# line unchanged, however far the cursor has drifted.
	var shot_dir := Vector3(0, 0, -1)         # straight ahead
	var cursor_dir := Vector3(1, 0, 0)        # 90° to the right
	var aim: Vector3 = ShotMechanics.follow_through_aim(shot_dir, cursor_dir, 0.3, 0.4)
	assert_almost_eq(aim.x, 0.0, 0.0001, "still on the shot line")
	assert_almost_eq(aim.z, -1.0, 0.0001, "still on the shot line")

func test_follow_through_aim_lands_on_cursor_at_end() -> void:
	# At t=1 the finish has fully eased onto the live cursor direction.
	var shot_dir := Vector3(0, 0, -1)
	var cursor_dir := Vector3(1, 0, 0)
	var aim: Vector3 = ShotMechanics.follow_through_aim(shot_dir, cursor_dir, 1.0, 0.4)
	assert_almost_eq(aim.x, 1.0, 0.0001, "ends pointed at the cursor")
	assert_almost_eq(aim.z, 0.0, 0.0001, "ends pointed at the cursor")

func test_follow_through_aim_blends_partway_in_tail() -> void:
	# Mid-tail the aim sits strictly between the shot line and the cursor.
	var shot_dir := Vector3(0, 0, -1)
	var cursor_dir := Vector3(1, 0, 0)
	var aim: Vector3 = ShotMechanics.follow_through_aim(shot_dir, cursor_dir, 0.8, 0.4)
	assert_gt(aim.x, 0.0, "rotated toward the cursor")
	assert_lt(aim.x, 1.0, "not all the way yet")
	assert_almost_eq(aim.length(), 1.0, 0.0001, "stays a unit direction")

func test_follow_through_aim_zero_return_frac_keeps_shot_line() -> void:
	var shot_dir := Vector3(0, 0, -1)
	var cursor_dir := Vector3(1, 0, 0)
	var aim: Vector3 = ShotMechanics.follow_through_aim(shot_dir, cursor_dir, 1.0, 0.0)
	assert_almost_eq(aim.x, 0.0, 0.0001, "no blend with return_frac 0")
	assert_almost_eq(aim.z, -1.0, 0.0001, "no blend with return_frac 0")

func test_follow_through_aim_whiff_returns_zero() -> void:
	# Degenerate shot_dir (whiff) → ZERO so callers keep their release-angle hold.
	var aim: Vector3 = ShotMechanics.follow_through_aim(
			Vector3.ZERO, Vector3(1, 0, 0), 1.0, 0.4)
	assert_almost_eq(aim.length(), 0.0, 0.0001, "whiff yields no aim")

func test_follow_through_aim_ignores_degenerate_cursor() -> void:
	# No cursor direction (mouse on top of the skater) → hold the shot line.
	var shot_dir := Vector3(0, 0, -1)
	var aim: Vector3 = ShotMechanics.follow_through_aim(shot_dir, Vector3.ZERO, 1.0, 0.4)
	assert_almost_eq(aim.z, -1.0, 0.0001, "degenerate cursor holds shot line")


# ── Per-gear ladders: the posture vocabulary ─────────────────────────────────
# The level names the SHOT, the gear names the RANGE. Each level targets a
# goalie-posture landmark (absolute heights off the ice — GoalieAnatomy's pad,
# hand and torso boxes), and each gear places those same three shots at its own
# HOME RANGE. Checked at full wrister charge (33 m/s) with the same arrival
# arithmetic the AI rung-picker uses.

const _FULL_PACE: float = 33.0

# Posture landmarks the rungs are aimed to clear.
const _BUTTERFLY_PAD_TOP: float = 0.28   # GoalieAnatomy pad box width, rolled flat
const _BUTTERFLY_HANDS: float = 0.49     # GoalieStickRules butterfly hand height
const _STANDING_SEAM: float = 0.86       # GameRules.DEFAULT_GOALIE_PAD_TOP_SEAM_M
const _CAVITY_TOP: float = 1.17          # AIActionScoring.HIGH_BAND_CEILING_M

# Where each blade's menu is authored to land.
const _HOME_M88: float = 8.5
const _HOME_M92: float = 6.0
const _HOME_M28: float = 4.5


func _arrive(dist: float, speed: float, tan_a: float) -> float:
	return dist * tan_a \
			- 9.8 * dist * dist * (1.0 + tan_a * tan_a) / (2.0 * speed * speed)


func _m88() -> PlayerAttributes:
	return PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_CLOSED, 1, 1)


func _m28() -> PlayerAttributes:
	return PlayerAttributes.new(73, 201, 1, PlayerAttributes.CURVE_OPEN, 1, 1)


func _assert_menu_at_home(attrs: PlayerAttributes, home: float, gear: String) -> void:
	# The defining property of the ladder: at its own home range every blade
	# delivers the SAME three shots, each clearing a different posture landmark.
	var lo: float = _arrive(home, _FULL_PACE, attrs.curve_loft_tan_low())
	var mid: float = _arrive(home, _FULL_PACE, attrs.curve_loft_tan_mid())
	var hi: float = _arrive(home, _FULL_PACE, attrs.curve_loft_tan_high())
	assert_between(lo, _BUTTERFLY_PAD_TOP, _BUTTERFLY_HANDS,
			"%s LOW clears the butterfly pad, stays under his hands" % gear)
	assert_between(mid, _BUTTERFLY_HANDS, _STANDING_SEAM,
			"%s MID is the armpit — over his committed hands" % gear)
	assert_between(hi, _STANDING_SEAM, _CAVITY_TOP,
			"%s HIGH is upstairs — over the standing pad seam" % gear)


func test_every_gear_delivers_the_full_menu_at_its_home_range() -> void:
	_assert_menu_at_home(_m88(), _HOME_M88, "M88")
	_assert_menu_at_home(PlayerAttributes.all_average(), _HOME_M92, "M92")
	_assert_menu_at_home(_m28(), _HOME_M28, "M28")


func test_gears_own_different_zones() -> void:
	# The identity: at the SAME distance the three blades sit at different
	# heights, so which zone gives you the full menu is the gear choice. At the
	# M28's home the closed blade is still down at pad height on its top rung.
	var h88: float = _arrive(_HOME_M28, _FULL_PACE, _m88().curve_loft_tan_high())
	var h92: float = _arrive(_HOME_M28, _FULL_PACE,
			PlayerAttributes.all_average().curve_loft_tan_high())
	var h28: float = _arrive(_HOME_M28, _FULL_PACE, _m28().curve_loft_tan_high())
	assert_lt(h88, h92, "the range blade sits lowest in tight")
	assert_lt(h92, h28, "the close blade sits highest in tight")
	assert_lt(h88, _STANDING_SEAM, "M88 cannot go upstairs from the slot")
	assert_between(h28, _STANDING_SEAM, _CAVITY_TOP, "M28 owns upstairs in tight")


func test_the_crease_is_an_over_the_pad_zone_not_a_roof_zone() -> void:
	# Deliberate: nobody roofs the 2 m doorstep — reserving a rung for it is
	# what cost every blade its slot elevation. What the crease needs is the
	# over-the-butterfly-pad shot, and the close blade delivers exactly that.
	var m28 := _m28()
	assert_lt(_arrive(2.0, _FULL_PACE, m28.curve_loft_tan_high()), _STANDING_SEAM,
			"even the toe hook is under the standing seam from the crease")
	assert_gt(_arrive(2.0, _FULL_PACE, m28.curve_loft_tan_high()),
			_BUTTERFLY_PAD_TOP, "but it clears the butterfly pad")


func test_the_point_puts_a_shot_on_net_without_a_full_menu() -> void:
	# A point shot only has to reach the net — the whole cavity is a ~3.4°
	# window at 19 m, so no ladder could offer a menu there. What it must not
	# do is leave the flattest rung sailing.
	var m88 := _m88()
	assert_lt(_arrive(19.0, _FULL_PACE, m88.curve_loft_tan_low()), _CAVITY_TOP,
			"M88 LOW is on net from the point")
	assert_lt(_arrive(19.0, _FULL_PACE, _m28().curve_loft_tan_low()), _CAVITY_TOP,
			"M28 LOW is on net from the point")


func test_m28_flies_steeper_than_m88_on_every_rung() -> void:
	# The ordering that makes the open blade the close-range weapon: every M28
	# rung is steeper than the same M88 rung, so its menu sits nearer the net.
	var m88 := _m88()
	var m28 := _m28()
	assert_gt(m28.curve_loft_tan_low(), m88.curve_loft_tan_low())
	assert_gt(m28.curve_loft_tan_mid(), m88.curve_loft_tan_mid())
	assert_gt(m28.curve_loft_tan_high(), m88.curve_loft_tan_high())
	# ...and from range that steepness is what costs it the top of the net.
	assert_gt(_arrive(9.0, _FULL_PACE, m28.curve_loft_tan_mid()), _CAVITY_TOP,
			"M28 MID sails from long range")
	assert_lt(_arrive(9.0, _FULL_PACE, m88.curve_loft_tan_mid()), _STANDING_SEAM,
			"M88 MID is still the armpit there")


func test_no_low_rung_sails_on_any_gear_at_any_pace() -> void:
	# The flat bottom of every ladder is the universally safe shot: LOW cannot
	# put a puck over the bar on ANY blade, even off a max slapper — its whole
	# arc apexes under the crossbar. No clamp anywhere; the property IS the
	# gear table, and it is what makes LOW the rung you can always reach for.
	var max_slap: float = GameRules.DEFAULT_SLAPPER_POWER_MAX_M_S
	for attrs: PlayerAttributes in [
			_m88(), PlayerAttributes.all_average(), _m28()]:
		var t: float = attrs.curve_loft_tan_low()
		var sin_a: float = t / sqrt(1.0 + t * t)
		assert_lt(pow(max_slap * sin_a, 2.0) / (2.0 * 9.8), GameRules.NET_HEIGHT,
				"LOW apexes under the bar at max slap")
