class_name GoalieSaveRules

# Pure save-rebound resolution. A real goalie CONTROLS rebounds — absorbs shots
# into the chest/glove, steers pads wide — rather than caroming every puck back
# into the slot at the material's restitution. Given the incoming (pre-bounce)
# puck velocity and which part made the save, this decides whether the save is
# "controlled" (chest/glove absorb to a dead drop; pad/blocker STEER the puck
# cornerward at a controlled pace — modern active-rebound doctrine, audit F12)
# or "live" (a hard pad save that kicks out a real physics rebound — the
# beatable-realism scramble chance).
#
# Deterministic (no randomness) so a client-predicted puck and the host agree
# before reconciliation. Deadening is rebound CONTROL, not a whistle — it never
# stops play, so it's correct under every ruleset. A whistle-on-cover is a
# separate, ruleset-gated layer that would reuse `is_controlled_save` to decide
# WHEN the goalie freezes the puck for a faceoff instead of sweeping it.

# Which save surface the puck struck. Absorbing surfaces (chest/glove) kill a
# shot at any speed; deflecting surfaces (pad/blocker) only deaden the easy ones
# and kick out a live rebound on a hard shot; the stick never deadens (it
# redirects — see the deflect / poke paths on Puck).
enum SavePart { STICK, PAD, BLOCKER, CHEST, GLOVE }

class DeadenConfig:
	# Pad / blocker saves above this incoming speed kick out a LIVE rebound (a
	# hard shot beats the pad). At/under it they deaden. Chest / glove ABSORB or
	# CATCH, so they deaden at any speed. Stick never deadens.
	# Grounded in the shot-speed distribution: ~28 m/s (≈63 mph) sits above a solid
	# wrister but below hard wristers / slappers, so pads control the medium stuff
	# and kick live rebounds only on genuinely hard shots — the beatable-realism
	# scramble chance. Re-anchored up from 22 when the wrister/slapper maxes rose
	# (24→33 / 34→40 m/s); at 22 nearly every shot was now beating the pad.
	var pad_max_incoming_speed: float = 28.0
	# Deadened exit-speed ceiling (m/s) for the ABSORBING surfaces. A chest or
	# glove save leaves the puck crawling so the crease sweep can whisk it away.
	var drop_speed: float = 1.2
	# Fraction of the incoming LATERAL speed retained by the absorbing surfaces.
	# Goalward (z) and vertical (y) motion are always killed so a deadened puck
	# settles in front of the goalie instead of trickling into the net.
	var glove_retain: float = 0.0    # a catch kills it dead
	var chest_retain: float = 0.12
	# Controlled PAD / BLOCKER saves are STEERED, not killed (modern "active
	# rebounds" doctrine — realism audit F12): pads and blockers are built to
	# fire the puck to the CORNER on the side it arrived at, at a firm but
	# controlled pace, instead of leaving it dead at the goalie's feet for a
	# net-front scramble. Chest/glove stay a dead absorb — the real "no rebound"
	# surfaces. Direction = mostly lateral toward the contact side, with an
	# out-of-crease forward bias (same shape as the crease clear).
	var pad_steer_speed: float = 5.0        # m/s — controlled cornerward exit
	var steer_lateral_weight: float = 1.0   # cornerward bias (lateral vs forward)
	var steer_forward_weight: float = 0.35  # out-of-crease bias

# Raw restitution off a goalie surface for a LIVE (uncontrolled) rebound — mirrors the Jolt
# PhysicsMaterials (Physics/goalie_pad.tres 0.2, Physics/goalie_stick.tres 0.4). Only reached
# on a live rebound: PAD/BLOCKER above pad_max_incoming_speed (a hard shot beats the pad), and
# STICK always (it redirects, never deadens). Chest/glove are always controlled, so their
# material bounce is never used. Named here because the analytic puck no longer reads the Jolt
# material; a mirror guard should pin the pair like the boards.
const PAD_RESTITUTION: float = 0.2
const STICK_RESTITUTION: float = 0.4


static func live_restitution(part: int) -> float:
	return STICK_RESTITUTION if part == SavePart.STICK else PAD_RESTITUTION


# Whole-contact result: the resolved velocity plus the two discrete flags the caller acts on
# (a controlled save vs a live rebound; a glove catch that freezes the play).
class ContactResult:
	var velocity: Vector3 = Vector3.ZERO
	var deadened: bool = false  # controlled save — velocity is the deaden/steer result
	var caught: bool = false    # glove catch — freeze the play


# Resolve a puck-vs-goalie contact end to end: classify via is_controlled_save, then either
# deaden/steer/catch (controlled) or reflect off the contact face at the surface restitution
# (live). `contact_normal` points from the goalie surface toward the puck (SweptDiscOBB's
# outward normal); `contact_side` / `direction_sign` are the goalie-frame terms
# deadened_velocity needs. Fills a caller-owned result (no allocation). Deterministic, so a
# client-predicted puck and the host agree before reconciliation.
static func resolve_contact(
		incoming: Vector3, part: int, contact_normal: Vector3,
		contact_side: float, direction_sign: int, cfg: DeadenConfig, result: ContactResult) -> void:
	if is_controlled_save(incoming.length(), part, cfg):
		result.velocity = deadened_velocity(incoming, part, contact_side, direction_sign, cfg)
		result.deadened = true
		result.caught = part == SavePart.GLOVE
		return
	# Live rebound: reflect the into-face velocity component with the surface restitution, keep
	# the tangential (a glancing pad save holds pace, a square hard shot kicks straight out).
	var n: Vector3 = contact_normal.normalized()
	var vn: float = incoming.dot(n)
	if vn < 0.0:
		result.velocity = incoming - (1.0 + live_restitution(part)) * vn * n
	else:
		result.velocity = incoming  # already separating — nothing to reflect
	result.deadened = false
	result.caught = false


# True when the save should be deadened (rebound killed) rather than left live.
static func is_controlled_save(incoming_speed: float, part: int, cfg: DeadenConfig) -> bool:
	match part:
		SavePart.STICK:
			return false
		SavePart.GLOVE, SavePart.CHEST:
			return true
		_:  # PAD, BLOCKER — deflecting surfaces only eat the easy ones
			return incoming_speed <= cfg.pad_max_incoming_speed

# Exit velocity for a controlled save. Two families (audit F12):
#   CHEST / GLOVE — absorb: keep only a clamped fraction of the incoming
#     lateral drift; goalward (z) and vertical (y) motion are zeroed so the
#     puck settles dead in front (the real "no rebound" surfaces).
#   PAD / BLOCKER — steer: fire the puck cornerward on `contact_side` (the
#     side of the goalie the puck arrived at, world-x sign) with an
#     out-of-crease forward bias, at `pad_steer_speed` — the modern active
#     rebound that takes the second chance out of the slot without a scramble.
# `direction_sign` follows the goalie convention (sign(-goal_line_z)): forward,
# away from the goal line, is the +direction_sign Z direction. Degenerate
# inputs (no side / no direction) fall back to the incoming lateral sign so the
# result stays deterministic on host and client.
# Caller applies this only when is_controlled_save is true.
static func deadened_velocity(
		incoming_velocity: Vector3, part: int,
		contact_side: float, direction_sign: int, cfg: DeadenConfig) -> Vector3:
	if part == SavePart.GLOVE or part == SavePart.CHEST:
		var retain: float = cfg.glove_retain if part == SavePart.GLOVE else cfg.chest_retain
		var lateral: float = incoming_velocity.x * retain
		if absf(lateral) > cfg.drop_speed:
			lateral = signf(lateral) * cfg.drop_speed
		return Vector3(lateral, 0.0, 0.0)
	# PAD / BLOCKER — steered cornerward exit.
	var side: float = signf(contact_side)
	if side == 0.0:
		side = signf(incoming_velocity.x)
	if side == 0.0:
		side = 1.0
	var dir := Vector3(side * cfg.steer_lateral_weight, 0.0,
			float(direction_sign) * cfg.steer_forward_weight)
	var dlen: float = dir.length()
	if dlen < 0.0001:
		return Vector3.ZERO
	return (dir / dlen) * cfg.pad_steer_speed
