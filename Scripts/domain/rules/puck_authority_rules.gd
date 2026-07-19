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
# ice friction, gravity, board caroms, and land-and-slide; this wraps it with the SAME
# post-integration safety clamps _integrate_forces enforces for a free puck — max speed and
# max height — so the analytic authority path is behaviourally identical to the Jolt path it
# replaces. (The goal-line clamp is NOT here — Puck._drive_analytic applies it after the
# sub-step pass, re-homed from _integrate_forces like the rest; there is no Jolt net zone.)
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
