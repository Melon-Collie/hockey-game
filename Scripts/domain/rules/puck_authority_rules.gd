class_name PuckAuthorityRules

# The determinism migration (docs/netcode-determinism-migration.md): the LOOSE puck is
# driven by the analytic sim (the feel-validated AITrajectory.step_puck_3d — integration +
# ice friction + rounded-corner board caroms + the loft/gravity channel) instead of Jolt,
# so the puck's motion is deterministic and client-reproducible. Collision against the
# non-board geometry (goal pipes, net panels, and the moving goalie) is resolved
# analytically too — see PuckCollisionRules / GoalieSaveRules / SweptDiscOBB — so there is
# no Jolt "net zone": the puck is analytic everywhere.
#
# Pure / static — headless-testable, and (like every step_puck_3d caller) allocation-free
# on the per-tick path.


# Advance a free loose puck one tick under the analytic sim. step_puck_3d already applies
# ice friction, gravity, board caroms, and land-and-slide; this wraps it with the two
# post-integration safety clamps a free puck needs — max speed and max height.
# (Deliberately NO goal-line clamp, here or in Puck._drive_analytic: parking the puck at the
# line is CLIENT-only render suppression and lives on the client's prediction path, as
# PuckController._run_prediction's "no goal prediction" park. The host's puck is never
# clamped at the line; its authority is the real swept crossing, GoalDetectionRules.)
# Returns (pos, vel) packed into a Transform3D (origin = pos, basis.x = vel).
static func advance_loose_puck(pos: Vector3, vel: Vector3, dt: float,
		max_speed: float, ice_height: float, max_height: float) -> Transform3D:
	var stepped: Transform3D = AITrajectory.step_puck_3d(pos, vel, dt, ice_height)
	var p: Vector3 = stepped.origin
	var v: Vector3 = stepped.basis.x
	if v.length() > max_speed:
		v = v.normalized() * max_speed
	if p.y > ice_height + max_height:
		p.y = ice_height + max_height
		if v.y > 0.0:
			v.y = 0.0
	return Transform3D(Basis(v, Vector3.ZERO, Vector3.ZERO), p)


# ── Shared sub-stepped frame advance (host drive AND client prediction) ───────
# One tick of loose-puck motion against ALL static geometry — integration + ice
# friction + gravity + board caroms (advance_loose_puck) and the goal frame
# (posts, crossbar, top + back/side net panels), sub-stepped near the thin frame
# exactly like the host drive. This is THE shared step of the Phase-3
# predict-and-reconcile: Puck._drive_analytic (host authority) and the client's
# loose-puck prediction both call it, so their static-geometry trajectories
# agree by construction — the definition of the determinism migration. The
# goalie is deliberately NOT here: the host interleaves its swept goalie pass
# per sub-step (response = GoalieSaveRules), the client treats goalie contact
# as a prediction STOP; both run against the same sub-step segments.

# Sub-step the tick when the puck is within this of a goal line, so a hard shot
# can't tunnel through the thin posts / net panels. Elsewhere the puck steps
# once per tick — only the boards, an untunnelable position clamp, live there.
const FRAME_SUBSTEP_RANGE_Z: float = 3.0
const FRAME_SUBSTEP_M: float = 0.04          # max advance per sub-step (< a puck radius)
const MAX_FRAME_SUBSTEPS: int = 16           # cap (16 × 0.04 m = 0.64 m/tick ≈ 77 m/s)
# Run goalie contact detection when the puck is within this of a goal line (a
# goalie's deepest challenge + margin). Shared so host drive and client stop
# gate identically.
const GOALIE_DETECT_RANGE_Z: float = 6.0


# Sub-step count for one tick starting at z-coordinate `pos_z` at `speed` m/s.
static func frame_substeps(pos_z: float, speed: float, dt: float) -> int:
	if absf(pos_z) <= GameRules.GOAL_LINE_Z - FRAME_SUBSTEP_RANGE_Z:
		return 1
	return clampi(ceili(speed * dt / FRAME_SUBSTEP_M), 1, MAX_FRAME_SUBSTEPS)


class TickResult:
	var position: Vector3 = Vector3.ZERO
	var velocity: Vector3 = Vector3.ZERO
	var touched_post: bool = false
	var touched_net: bool = false


# One SUB-STEP of the frame advance: integrate `sub_dt` then resolve posts /
# crossbar / top net / back+side panels in the host drive's exact order. Fills
# `out` (position/velocity; touched flags OR-accumulate — caller clears them
# per tick). `frame_scratch` is a caller-owned PuckGeometryCollision.Result.
static func step_frame_substep(pos: Vector3, vel: Vector3, sub_dt: float,
		puck_radius: float, max_speed: float, ice_height: float, max_height: float,
		frame_scratch: PuckGeometryCollision.Result, out: TickResult) -> void:
	var sub_prev: Vector3 = pos
	var stepped: Transform3D = advance_loose_puck(pos, vel, sub_dt, max_speed, ice_height, max_height)
	var p: Vector3 = stepped.origin
	var v: Vector3 = stepped.basis.x
	if PuckGeometryCollision.resolve_posts(p, v, puck_radius, frame_scratch) \
			or PuckGeometryCollision.resolve_crossbar(p, v, puck_radius, frame_scratch):
		p = frame_scratch.position
		v = frame_scratch.velocity
		out.touched_post = true
	if PuckGeometryCollision.resolve_top_net(sub_prev, p, v, frame_scratch) \
			or PuckGeometryCollision.resolve_net_panels(sub_prev, p, v, puck_radius, frame_scratch):
		p = frame_scratch.position
		v = frame_scratch.velocity
		out.touched_net = true
	out.position = p
	out.velocity = v
