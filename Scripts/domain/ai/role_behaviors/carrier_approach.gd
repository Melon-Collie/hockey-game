class_name AICarrierApproach
extends RefCounted

# What a defender who owns the puck carrier needs to know about him before it can
# decide anything: where he is, how fast, which way he is going home, how much
# route he has left, and how hard he is coming. Every role that closes a carrier
# — the rush gap (AIRoleRushD), the in-zone pressurer (AIRolePressure) and the
# backchecker running him down (AIRoleTrack) — derived these five from scratch,
# with three slightly different degenerate-case guards between them.
#
# Filled in place from a caller-owned instance (RoleContext.scratch_carrier_
# approach) by AIRoleHelpers.read_carrier_approach, so the read costs no
# allocation on the dispatch path.

# His position, and his velocity. This is his REAL body, never a velocity-led
# point: the stand rides him (RoleDecision.target_velocity), so leading as well
# double-counts his motion — see AIRoleHelpers.cover_threat for the same rule on
# the coverage side.
var carrier_pos: Vector3 = Vector3.ZERO
var carrier_vel: Vector3 = Vector3.ZERO

# Unit vector from him toward the net we defend — the line he retreats us down,
# and the axis every gap is measured on. ZERO when he is on top of the net, which
# is the one case with no well-defined line; roles handle that themselves rather
# than being handed a fabricated direction.
var dir_net: Vector3 = Vector3.ZERO

# Metres of route he has left to our net. This is the gap ladder's own input
# ("ice remaining"), so the ladder and the stand cannot disagree about it.
var net_dist: float = 0.0

# His pace ALONG that line, never below zero. Lateral drift buys no burst toward
# our net — the turn radius pays for that conversion first — so a carrier flying
# across the slot is not closing on us and the ladder must not price him as if
# he were.
var closing: float = 0.0
