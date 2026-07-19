extends GutTest

# PuckAuthorityRules.advance_loose_puck — the analytic loose-puck integration core the
# determinism migration installs in place of Jolt. It wraps step_puck_3d (tested
# separately) with the same post-integration safety clamps _integrate_forces enforces for a
# free puck: max speed and max height. These tests pin those clamps and the delegation.

const DT: float = 1.0 / 120.0
const ICE: float = 0.0175
const MAX_SPEED: float = 60.0
const MAX_HEIGHT: float = 2.0


func test_free_slide_matches_step_puck_3d() -> void:
	# With speed/height well under the caps, advance == step_puck_3d (no clamp interference).
	var pos := Vector3(1, ICE, 2)
	var vel := Vector3(8, 0, -3)
	var got: Transform3D = PuckAuthorityRules.advance_loose_puck(pos, vel, DT, MAX_SPEED, ICE, MAX_HEIGHT)
	var ref: Transform3D = AITrajectory.step_puck_3d(pos, vel, DT, ICE)
	assert_almost_eq(got.origin.x, ref.origin.x, 1e-6, "position matches step_puck_3d (x)")
	assert_almost_eq(got.origin.z, ref.origin.z, 1e-6, "position matches step_puck_3d (z)")
	assert_almost_eq(got.basis.x.x, ref.basis.x.x, 1e-6, "velocity matches step_puck_3d (x)")


func test_max_speed_clamps_an_overspeed_puck() -> void:
	var vel := Vector3(200, 0, 0)  # far over the cap
	var got: Transform3D = PuckAuthorityRules.advance_loose_puck(
			Vector3(0, ICE, 0), vel, DT, MAX_SPEED, ICE, MAX_HEIGHT)
	assert_almost_eq(got.basis.x.length(), MAX_SPEED, 0.01, "speed clamped to max_speed")
	assert_gt(got.basis.x.x, 0.0, "direction preserved")


func test_max_height_clamps_and_kills_upward_velocity() -> void:
	# A puck already above the ceiling with upward velocity is pinned at the ceiling and its
	# climb killed (mirrors _integrate_forces' max_height clamp).
	var pos := Vector3(0, ICE + MAX_HEIGHT + 0.5, 0)
	var vel := Vector3(4, 3, 0)  # rising
	var got: Transform3D = PuckAuthorityRules.advance_loose_puck(pos, vel, DT, MAX_SPEED, ICE, MAX_HEIGHT)
	assert_almost_eq(got.origin.y, ICE + MAX_HEIGHT, 1e-6, "height pinned to the ceiling")
	assert_eq(got.basis.x.y, 0.0, "upward velocity killed at the ceiling")


func test_grounded_puck_stays_grounded() -> void:
	# A puck at rest height with no vertical motion stays on the ice (delegates to the
	# grounded step_puck_3d branch).
	var got: Transform3D = PuckAuthorityRules.advance_loose_puck(
			Vector3(0, ICE, 0), Vector3(10, 0, 0), DT, MAX_SPEED, ICE, MAX_HEIGHT)
	assert_almost_eq(got.origin.y, ICE, 1e-6, "stayed at ice height")
	assert_eq(got.basis.x.y, 0.0, "no vertical velocity introduced")
