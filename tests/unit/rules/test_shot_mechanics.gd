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
	cfg.loft_vy_low = 2.2
	cfg.loft_vy_high = 5.4
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

# ── Loft physics: fixed vertical launch speed ────────────────────────────────

# The defining property of the loft system: a level's vertical launch speed is
# CONSTANT across shot power — charge buys pace, not height, so the apex is the
# same for a soft and a hard shot at the same level.
func test_loft_vertical_speed_fixed_across_power() -> void:
	var cfg := _wrister_cfg()
	for sweep: float in [2.0, FULL_SWEEP]:
		var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
			Vector3.ZERO, Vector3(0, 0, 10),
			Vector3(0.5, 0, 0),
			false, 2, cfg,
			Vector3(0, 0, 1), false, sweep)
		var v_y: float = r.power * r.direction.y
		assert_almost_eq(v_y, cfg.loft_vy_high, 0.01,
			"vertical launch speed is the level constant at sweep %.1f" % sweep)


func test_loft_low_level_uses_low_vy() -> void:
	var cfg := _wrister_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, 10),
		Vector3(0.5, 0, 0),
		false, 1, cfg,
		Vector3(0, 0, 1), false, FULL_SWEEP)
	assert_almost_eq(r.power * r.direction.y, cfg.loft_vy_low, 0.01)


# Loft is direction-agnostic — a backward flip clear and a toward-net shot get
# the identical y. (The old system classified toward-net vs away and used a
# different fallback loft, which made toward-net saucer passes impossible.)
func test_loft_direction_agnostic() -> void:
	var cfg := _wrister_cfg()
	var toward: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, 10),
		Vector3(0.5, 0, 0),
		false, 1, cfg,
		Vector3(0, 0, 1), false, FULL_SWEEP)
	var away: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, 10),
		Vector3(0.5, 0, 0),
		false, 1, cfg,
		Vector3(0, 0, -1), false, FULL_SWEEP)
	assert_almost_eq(toward.direction.y, away.direction.y, 0.0001,
		"same loft level and power -> same y, regardless of direction")


# Quick passes ride the same loft table — LOW at pass power IS the saucer pass,
# in any direction including toward the net.
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


func test_loft_ratio_capped_for_soft_shot() -> void:
	# Min-power backhand wrister (8.0 * 0.75 = 6.0 m/s) can't meaningfully
	# exceed the HIGH launch speed (5.4) — the y ratio caps at MAX_LOFT_RATIO
	# instead of running toward vertical.
	var cfg := _wrister_cfg()
	var r: ShotMechanics.ShotResult = ShotMechanics.release_wrister(
		Vector3.ZERO, Vector3(0, 0, 10),
		Vector3(0.5, 0, 0),
		true, 2, cfg,
		Vector3(0, 0, 1))
	var xz_len: float = Vector2(r.direction.x, r.direction.z).length()
	assert_almost_eq(r.direction.y / xz_len, ShotMechanics.MAX_LOFT_RATIO, 0.001,
		"soft lofted flip flattens to the ratio cap")
	# Every legit loft stays inside the host's forged-direction clamp.
	assert_lt(r.direction.y, ShotReleaseRules.MAX_DIRECTION_Y,
		"capped loft never trips ShotReleaseRules.sanitize_direction")


func test_loft_y_zero_for_flat() -> void:
	assert_almost_eq(ShotMechanics.loft_y(20.0, 0.0), 0.0, 0.000001)


func test_loft_y_exact_solution() -> void:
	# y = vy / sqrt(p^2 - vy^2): launching at power 20 with the HIGH vy of 5.4
	# must give a vertical speed of exactly 5.4 after normalization.
	var y: float = ShotMechanics.loft_y(20.0, 5.4)
	var v_y: float = 20.0 * y / sqrt(1.0 + y * y)
	assert_almost_eq(v_y, 5.4, 0.0001)


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
