extends GutTest

# GamepadAimRules — the right-stick deadzone + velocity-integrated cursor that
# lets a gamepad drive stickhandling and shooting through the mouse pipeline.
# Pure math, no engine input needed.

const DZ: float = 0.15
const RADIUS: float = 480.0
const ANCHOR := Vector2(960.0, 540.0)


func test_deadzone_zeros_small_input() -> void:
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2(0.1, 0.0), DZ), Vector2.ZERO,
			"input inside the deadzone reads dead-zero")
	assert_eq(GamepadAimRules.apply_radial_deadzone(Vector2.ZERO, DZ), Vector2.ZERO,
			"a centered stick reads zero")


func test_deadzone_edge_rescales_to_full_span() -> void:
	var near_edge: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(DZ + 0.001, 0.0), DZ)
	assert_almost_eq(near_edge.length(), 0.0, 0.01, "magnitude ramps up from zero at the deadzone edge")
	var full: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(1.0, 0.0), DZ)
	assert_almost_eq(full.length(), 1.0, 0.0001, "full deflection reaches magnitude 1")
	var mid_mag: float = DZ + (1.0 - DZ) * 0.5
	var mid: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(mid_mag, 0.0), DZ)
	assert_almost_eq(mid.length(), 0.5, 0.0001, "midpoint of the live span reads half")


func test_deadzone_preserves_direction_and_clamps_overrange() -> void:
	var raw := Vector2(0.6, 0.8)  # length 1.0, 3-4-5 direction
	var out: Vector2 = GamepadAimRules.apply_radial_deadzone(raw, DZ)
	assert_almost_eq(out.angle(), raw.angle(), 0.0001, "deadzone rescale keeps the heading")
	var over: Vector2 = GamepadAimRules.apply_radial_deadzone(Vector2(2.0, 0.0), DZ)
	assert_almost_eq(over.length(), 1.0, 0.0001, "over-range deflection clamps to unit")


func test_absolute_cursor_is_proportional_offset() -> void:
	# Stickhandle mode: cursor = anchor + stick * radius. Centered → on the anchor;
	# full deflection → a radius out; half → half-way (proportional placement).
	assert_eq(GamepadAimRules.absolute_cursor(ANCHOR, Vector2.ZERO, RADIUS), ANCHOR,
			"centered stick sits on the anchor")
	var full: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(1.0, 0.0), RADIUS)
	assert_almost_eq(full.x, ANCHOR.x + RADIUS, 0.01, "full-right places the blade a radius out")
	var half: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(0.0, 0.5), RADIUS)
	assert_almost_eq(half.y, ANCHOR.y + RADIUS * 0.5, 0.01, "half-deflection places half-way out")


func test_normalized_stick_parks_at_the_rim_for_aim() -> void:
	# Shot aim: a normalized stick places the cursor a full radius out in the stick
	# direction, so player→cursor is a clean stick-direction shot line regardless of
	# how hard the stick is pushed (power is the trigger's travel, not the stick's).
	var gentle: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(0.3, 0.0).normalized(), RADIUS)
	var hard: Vector2 = GamepadAimRules.absolute_cursor(ANCHOR, Vector2(1.0, 0.0).normalized(), RADIUS)
	assert_eq(gentle, hard, "aim direction is independent of push strength")
	assert_almost_eq((gentle - ANCHOR).length(), RADIUS, 0.01, "parked at the reach radius")


# --- Analog triggers: the wrister's power axis -------------------------------

const PRESS: float = 0.12
const RELEASE: float = 0.08
const FULL: float = 0.92
const SPRING_RATE: float = 6.0
const TICK: float = 1.0 / 120.0


func test_trigger_held_engages_at_press_and_holds_past_it() -> void:
	assert_false(GamepadAimRules.trigger_held(0.05, false, PRESS, RELEASE),
			"a resting trigger does not engage")
	assert_true(GamepadAimRules.trigger_held(PRESS, false, PRESS, RELEASE),
			"engages exactly at the press point")
	assert_true(GamepadAimRules.trigger_held(1.0, true, PRESS, RELEASE),
			"stays held while pulled")


func test_trigger_hysteresis_rejects_chatter_at_the_press_point() -> void:
	# A trigger resting ON the press point must not toggle: once held it takes a
	# fall below the LOWER release point to let go. Every spurious edge is a shot.
	var jitter: float = PRESS - 0.01
	assert_true(GamepadAimRules.trigger_held(jitter, true, PRESS, RELEASE),
			"a dip below the press point does not release while held")
	assert_false(GamepadAimRules.trigger_held(jitter, false, PRESS, RELEASE),
			"the same pull does not re-engage from released — that is the gap")
	assert_false(GamepadAimRules.trigger_held(RELEASE, true, PRESS, RELEASE),
			"falling to the release point lets go")


func test_trigger_power_spans_the_usable_travel() -> void:
	assert_almost_eq(GamepadAimRules.trigger_power_t(PRESS, PRESS, FULL), 0.0, 0.0001,
			"the pull that commits the shot is zero power, not a floor plus a step")
	assert_almost_eq(GamepadAimRules.trigger_power_t(FULL, PRESS, FULL), 1.0, 0.0001,
			"the full-power point tops the band out")
	assert_almost_eq(GamepadAimRules.trigger_power_t(1.0, PRESS, FULL), 1.0, 0.0001,
			"bottoming the trigger out stays a full rip, never over")
	var mid: float = PRESS + (FULL - PRESS) * 0.5
	assert_almost_eq(GamepadAimRules.trigger_power_t(mid, PRESS, FULL), 0.5, 0.0001,
			"power is linear in the usable travel")
	assert_almost_eq(GamepadAimRules.trigger_power_t(0.0, PRESS, FULL), 0.0, 0.0001,
			"below the press point clamps to zero rather than going negative")


func test_trigger_power_survives_a_pad_that_never_reports_full_deflection() -> void:
	# The reason FULL sits short of the stop: a pad topping out at ~0.95 must still
	# be able to fire a full-power shot.
	assert_almost_eq(GamepadAimRules.trigger_power_t(0.95, PRESS, FULL), 1.0, 0.0001,
			"a pad that maxes below 1.0 can still rip one")


func test_digital_shoulder_pad_reads_as_a_full_rip() -> void:
	# SDL maps a Switch-style digital ZR onto the trigger axis as a bare 0/1. It has
	# no travel to meter, so the only honest reading is maximum power.
	assert_true(GamepadAimRules.trigger_held(1.0, false, PRESS, RELEASE),
			"a digital shoulder engages on press")
	assert_almost_eq(GamepadAimRules.trigger_power_t(1.0, PRESS, FULL), 1.0, 0.0001,
			"and commits a full rip")


func test_spring_back_is_told_from_a_deliberate_ease_off_by_rate() -> void:
	# The whole reason the latch can hold a real power through the release: a return
	# spring unloads ~an order of magnitude faster than a thumb dials down.
	var spring_step: float = 20.0 * TICK   # ~20 units/s — trigger let go
	assert_true(GamepadAimRules.trigger_is_springing_back(
			0.8 - spring_step, 0.8, TICK, SPRING_RATE),
			"a released trigger reads as springing back")
	var ease_step: float = 2.0 * TICK      # ~2 units/s — thumb easing off
	assert_false(GamepadAimRules.trigger_is_springing_back(
			0.8 - ease_step, 0.8, TICK, SPRING_RATE),
			"a deliberate ease-off keeps feeding the latch, so it really does soften")


func test_spring_back_ignores_rising_and_steady_pulls() -> void:
	assert_false(GamepadAimRules.trigger_is_springing_back(0.9, 0.2, TICK, SPRING_RATE),
			"a fast PULL is a rise, never a spring-back — the press edge depends on it")
	assert_false(GamepadAimRules.trigger_is_springing_back(0.5, 0.5, TICK, SPRING_RATE),
			"a steady hold keeps the latch live")
	assert_false(GamepadAimRules.trigger_is_springing_back(0.1, 0.9, 0.0, SPRING_RATE),
			"a zero delta cannot imply a rate")


func test_spring_back_rate_is_tick_rate_independent() -> void:
	# Same physical motion (12 units/s), sampled at 120 Hz and at 60 Hz: the rate
	# read must agree, or power would depend on the player's frame rate.
	var fast_tick: float = 1.0 / 120.0
	var slow_tick: float = 1.0 / 60.0
	assert_true(GamepadAimRules.trigger_is_springing_back(
			0.8 - 12.0 * fast_tick, 0.8, fast_tick, SPRING_RATE), "12 units/s at 120 Hz")
	assert_true(GamepadAimRules.trigger_is_springing_back(
			0.8 - 12.0 * slow_tick, 0.8, slow_tick, SPRING_RATE), "12 units/s at 60 Hz")


func test_release_sweep_preserves_the_held_power() -> void:
	# End to end, the failure this design exists to prevent: the shot fires on
	# release, and a trigger sweeps its whole travel on the way out. Latching the
	# last sample before it drops under the release point would make every shot a
	# dribbler. Simulate holding at 0.8 and letting go over ~40 ms.
	var held_depth: float = 0.8
	var expected: float = GamepadAimRules.trigger_power_t(held_depth, PRESS, FULL)
	var latch: float = expected
	var prev: float = held_depth
	var depth: float = held_depth
	var engaged: bool = true
	while engaged:
		depth = maxf(depth - 20.0 * TICK, 0.0)   # spring return, ~20 units/s
		engaged = GamepadAimRules.trigger_held(depth, engaged, PRESS, RELEASE)
		if engaged and not GamepadAimRules.trigger_is_springing_back(
				depth, prev, TICK, SPRING_RATE):
			latch = GamepadAimRules.trigger_power_t(depth, PRESS, FULL)
		prev = depth
	assert_almost_eq(latch, expected, 0.0001,
			"the shot fires at the power that was held, not one sampled off the release")
	assert_gt(latch, 0.7, "sanity: that is a real shot, not the min-power floor")
