extends GutTest

# PivotRules: detection thresholds and hysteresis, the sense latch, ψ-derived
# phase, and the hold/step-around yaw law. ψ = travel direction in the body
# frame (radians); sense +1 = forward→backward transit.

const LO: float = deg_to_rad(50.0)
const HI: float = deg_to_rad(130.0)


func test_engage_requires_band_rate_and_speed() -> void:
	assert_true(PivotRules.should_engage(deg_to_rad(80.0), 3.0, 5.0, LO, HI, 2.5, 2.5))
	assert_false(PivotRules.should_engage(deg_to_rad(30.0), 3.0, 5.0, LO, HI, 2.5, 2.5),
			"below the band is normal hip-alignment territory")
	assert_false(PivotRules.should_engage(deg_to_rad(150.0), 3.0, 5.0, LO, HI, 2.5, 2.5),
			"past the band is settled backward skating")
	assert_false(PivotRules.should_engage(deg_to_rad(80.0), 1.0, 5.0, LO, HI, 2.5, 2.5),
			"a slow cursor drift is not a pivot")
	assert_false(PivotRules.should_engage(deg_to_rad(80.0), 3.0, 1.0, LO, HI, 2.5, 2.5),
			"pivoting is a gliding move — no speed, no pivot")


func test_release_hysteresis() -> void:
	assert_false(PivotRules.should_release(LO - deg_to_rad(4.0), 5.0, LO, HI, 2.5),
			"hovering just under the entry edge must not flicker")
	assert_true(PivotRules.should_release(LO - deg_to_rad(12.0), 5.0, LO, HI, 2.5),
			"a clear abort releases")
	assert_true(PivotRules.should_release(HI + deg_to_rad(12.0), 5.0, LO, HI, 2.5),
			"completion releases through the far edge")
	assert_true(PivotRules.should_release(deg_to_rad(80.0), 1.0, LO, HI, 2.5),
			"losing the gliding speed releases mid-band")


func test_sense_latch() -> void:
	assert_eq(PivotRules.latch_sense(deg_to_rad(60.0), LO, HI), 1.0)
	assert_eq(PivotRules.latch_sense(deg_to_rad(120.0), LO, HI), -1.0)


func test_phase_tracks_transit_direction() -> void:
	assert_almost_eq(PivotRules.phase(LO, 1.0, LO, HI), 0.0, 0.001)
	assert_almost_eq(PivotRules.phase(HI, 1.0, LO, HI), 1.0, 0.001)
	assert_almost_eq(PivotRules.phase(HI, -1.0, LO, HI), 0.0, 0.001)
	assert_almost_eq(PivotRules.phase(LO, -1.0, LO, HI), 1.0, 0.001)


func test_yaw_holds_entry_then_steps_to_exit() -> void:
	var psi: float = deg_to_rad(100.0)
	# Before the step begins the hips track the entry anchor exactly.
	assert_almost_eq(PivotRules.pivot_yaw(psi, 1.0, 0.3, 0.6), -psi, 0.001)
	# At full phase they land on the exit anchor: −ψ + π for positive ψ.
	assert_almost_eq(PivotRules.pivot_yaw(psi, 1.0, 1.0, 0.6), -psi + PI, 0.001)
	# Negative ψ mirrors.
	assert_almost_eq(PivotRules.pivot_yaw(-psi, 1.0, 1.0, 0.6), psi - PI, 0.001)
	# The return transit holds the backward anchor and steps back to alignment.
	assert_almost_eq(PivotRules.pivot_yaw(psi, -1.0, 0.3, 0.6), -psi + PI, 0.001)
	assert_almost_eq(PivotRules.pivot_yaw(psi, -1.0, 1.0, 0.6), -psi, 0.001)
