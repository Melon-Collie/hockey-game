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
	# scramble chance. It is anchored to that distribution, so it moves whenever
	# the wrister/slapper maxes move (GameRules.DEFAULT_*_POWER_MAX_M_S).
	var pad_max_incoming_speed: float = 28.0
	# Deadened exit-speed ceiling (m/s) for the ABSORBING surfaces — the whole exit
	# vector, not one channel of it. A chest or glove save leaves the puck crawling
	# so the crease sweep can whisk it away.
	var drop_speed: float = 1.2
	# Fraction of the incoming LATERAL speed retained by the absorbing surfaces.
	# Goalward (z) and vertical (y) motion are always killed so a deadened puck
	# settles in front of the goalie instead of trickling into the net.
	var glove_retain: float = 0.0    # a catch kills it dead
	var chest_retain: float = 0.12
	# Out-of-crease pace a chest save leaves on the puck. A chest protector's face
	# is angled down AND OUT, so a smothered shot lands in FRONT of the pads —
	# roughly half a metre out over the fall from chest height. Dropping it dead at
	# the contact point instead put it on the goalie's own skate line, where his
	# next shuffle or stick swing shoves it goalward: the "he beat himself off a
	# chest save" own goal. Under drop_speed, so this is still a drop rather than a
	# rebound the shooter can play. The GLOVE has none of this — a catch closes on
	# the puck rather than deflecting it.
	var chest_out_speed: float = 1.0
	# Controlled PAD / BLOCKER saves are STEERED, not killed (modern "active
	# rebounds" doctrine — realism audit F12): pads and blockers are built to
	# fire the puck to the CORNER on the side it arrived at, at a firm but
	# controlled pace, instead of leaving it dead at the goalie's feet for a
	# net-front scramble. Chest/glove stay a dead absorb — the real "no rebound"
	# surfaces. Direction = mostly lateral toward the contact side, with an
	# out-of-crease forward bias (same shape as the crease clear).
	# A CEILING on the cornerward exit, not a fixed pace: a pad redirects the shot
	# it was hit with, so a slower arrival leaves slower (see deadened_velocity).
	var pad_steer_speed: float = 5.0        # m/s — controlled cornerward exit
	var steer_lateral_weight: float = 1.0   # cornerward bias (lateral vs forward)
	var steer_forward_weight: float = 0.35  # out-of-crease bias

# Raw restitution off a goalie surface for a LIVE (uncontrolled) rebound. Only reached on a
# live rebound: PAD/BLOCKER above pad_max_incoming_speed (a hard shot beats the pad), and
# STICK always (it redirects, never deadens). Chest/glove are always controlled, so their
# restitution is never used.
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
		contact_side: float, direction_sign: int, cfg: DeadenConfig,
		result: ContactResult, goalie_forward: Vector3 = Vector3.ZERO) -> void:
	if is_face_presented(contact_normal, goalie_forward) \
			and is_controlled_save(incoming.length(), part, cfg):
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


# Is the struck surface one the goalie is actually PRESENTING to the puck?
#
# `contact_normal` points outward, from the goalie's surface toward the puck, so
# a normal aligned with the direction he FACES was struck on his front, and one
# pointing behind him was struck on his back.
#
# Facing, not the net. Testing the normal against `direction_sign` — is the
# contact on the play-side hemisphere — is wrong for exactly the plays that
# matter: a goalie tracking a wraparound or out playing a rim is turned, so the
# surface nearest his own goal can be the one his chest is pointed at, and the
# surface facing up-ice can be his shoulder. What he can absorb is what he is
# looking at.
#
# Why it gates the controlled save. Absorbing a puck dead into the chest or
# gloving it are things a goalie DOES, and he has to be facing the puck to do
# them. Without this gate the classification is orientation-blind — the torso
# collider reads as CHEST from any direction — so a puck into his back is a
# "chest save": deadened, goalward velocity zeroed, stopped on his spine, a free
# save on exactly the plays he should be beaten on. Same for a pad struck from
# behind, which would get the cornerward steer and be actively pushed away from
# the net.
#
# Not presented -> fall through to the live-rebound reflection, which is already
# the right physics for a puck caroming off a body. A gate, not new behaviour.
# Threshold-free: a face is presented or it is not, and a contact exactly side-on
# is not — you cannot smother with your shoulder either.
#
# A zero `goalie_forward` means the caller has no facing to offer, in which case
# every face counts as presented.
static func is_face_presented(contact_normal: Vector3, goalie_forward: Vector3) -> bool:
	if goalie_forward.length_squared() < 0.000001:
		return true
	return contact_normal.x * goalie_forward.x + contact_normal.z * goalie_forward.z > 0.0


# True when the save should be deadened (rebound killed) rather than left live.
# ORIENTATION-BLIND BY DESIGN — it answers "is this surface capable of a
# controlled save", not "was it struck on the right face". `resolve_contact`
# pairs it with `is_face_presented`; callers asking whether a save ended the play
# (the shot instruments) want this looser question and should keep using it.
static func is_controlled_save(incoming_speed: float, part: int, cfg: DeadenConfig) -> bool:
	match part:
		SavePart.STICK:
			return false
		SavePart.GLOVE, SavePart.CHEST:
			return true
		_:  # PAD, BLOCKER — deflecting surfaces only eat the easy ones
			return incoming_speed <= cfg.pad_max_incoming_speed

# Exit velocity for a controlled save. Two families (audit F12):
#   CHEST / GLOVE — absorb: keep only a fraction of the incoming lateral drift;
#     the incoming goalward (z) and vertical (y) motion are killed outright, so
#     nothing of the shot survives (the real "no rebound" surfaces). The chest
#     then adds its own out-of-crease drop (`chest_out_speed`), and the whole
#     exit is clamped to `drop_speed`.
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
		var out_speed: float = 0.0 if part == SavePart.GLOVE else cfg.chest_out_speed
		var exit := Vector3(incoming_velocity.x * retain, 0.0,
				float(direction_sign) * out_speed)
		# drop_speed bounds the WHOLE exit, not one channel of it — otherwise the
		# ceiling that makes these the "no rebound" surfaces isn't one.
		if exit.length() > cfg.drop_speed:
			exit = exit.normalized() * cfg.drop_speed
		return exit
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
	# A pad REDIRECTS the shot it was hit with; it cannot hand the puck more pace
	# than arrived. Steering every controlled contact out at the full
	# pad_steer_speed made the goalie fire a dead puck across his own crease — a
	# trickler nudging the pad left at 5 m/s, which reads as a kick at nothing and
	# hands the slot a live puck the shooter never earned.
	return (dir / dlen) * minf(cfg.pad_steer_speed, incoming_velocity.length())
