extends GutTest

# PuckAuthorityRules.advance_loose_puck — the analytic loose-puck integration core. It wraps
# step_puck_3d (tested separately) with the two post-integration safety clamps a free puck
# needs: max speed and max height. These tests pin those clamps and the delegation.

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
	# climb killed.
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


# ── step_frame_substep — the SHARED Phase-3 step (host drive == client predict) ──

const R: float = 0.065  # ~GameRules.PUCK_COLLISION_RADIUS


func _tick_scratch() -> Array:
	return [PuckGeometryCollision.Result.new(), PuckAuthorityRules.TickResult.new()]


func test_step_frame_open_ice_equals_advance_loose_puck() -> void:
	# Away from the goal frame the shared step must be EXACTLY advance_loose_puck —
	# this is the identity that makes host drive and client prediction agree in
	# open ice by construction.
	var s: Array = _tick_scratch()
	var pos := Vector3(2.0, ICE, 5.0)
	var vel := Vector3(9.0, 0.0, -4.0)
	PuckAuthorityRules.step_frame_substep(pos, vel, DT, R, MAX_SPEED, ICE, MAX_HEIGHT, s[0], s[1])
	var ref: Transform3D = PuckAuthorityRules.advance_loose_puck(pos, vel, DT, MAX_SPEED, ICE, MAX_HEIGHT)
	var out: PuckAuthorityRules.TickResult = s[1]
	assert_almost_eq(out.position.x, ref.origin.x, 1e-9)
	assert_almost_eq(out.position.z, ref.origin.z, 1e-9)
	assert_almost_eq(out.velocity.x, ref.basis.x.x, 1e-9)
	assert_false(out.touched_post)
	assert_false(out.touched_net)


func test_step_frame_resolves_a_post_contact() -> void:
	# A puck stepped into a post reflects and flags touched_post — the frame
	# geometry is inside the shared step, so the client predicts pipe pings too.
	var s: Array = _tick_scratch()
	var post_x: float = GameRules.NET_HALF_WIDTH
	var pos := Vector3(post_x, ICE, GameRules.GOAL_LINE_Z - 0.12)
	var vel := Vector3(0.0, 0.0, 14.0)  # straight at the post from in front
	PuckAuthorityRules.step_frame_substep(pos, vel, DT, R, MAX_SPEED, ICE, MAX_HEIGHT, s[0], s[1])
	var out: PuckAuthorityRules.TickResult = s[1]
	assert_true(out.touched_post, "driven into the pipe is a post contact")
	assert_lt(out.velocity.z, 14.0, "into-post component reflected/absorbed")


func test_step_frame_resolves_a_net_panel_contact() -> void:
	var s: Array = _tick_scratch()
	var back_z: float = GameRules.GOAL_LINE_Z + GameRules.NET_DEPTH
	var pos := Vector3(0.0, ICE, back_z - 0.05)
	var vel := Vector3(0.0, 0.0, 10.0)  # into the back mesh from inside the cavity
	PuckAuthorityRules.step_frame_substep(pos, vel, DT, R, MAX_SPEED, ICE, MAX_HEIGHT, s[0], s[1])
	var out: PuckAuthorityRules.TickResult = s[1]
	assert_true(out.touched_net, "into the back twine is a net contact")
	assert_lt(out.velocity.z, 0.0, "absorbed and reflected toward the mouth")


func test_frame_substeps_formula() -> void:
	# Open ice steps once regardless of speed; near the frame the count scales
	# with per-tick travel over FRAME_SUBSTEP_M, capped at MAX_FRAME_SUBSTEPS.
	assert_eq(PuckAuthorityRules.frame_substeps(0.0, 40.0, DT), 1, "mid-ice always 1")
	var near_z: float = GameRules.GOAL_LINE_Z - 1.0
	assert_eq(PuckAuthorityRules.frame_substeps(near_z, 40.0, DT),
			ceili(40.0 * DT / PuckAuthorityRules.FRAME_SUBSTEP_M), "near-frame scales with travel")
	assert_eq(PuckAuthorityRules.frame_substeps(near_z, 1.0, DT), 1, "slow puck needs no sub-steps")
	assert_eq(PuckAuthorityRules.frame_substeps(near_z, 10000.0, DT),
			PuckAuthorityRules.MAX_FRAME_SUBSTEPS, "hard cap")
