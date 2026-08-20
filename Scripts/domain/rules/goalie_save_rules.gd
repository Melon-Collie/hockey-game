class_name GoalieSaveRules

# Pure save resolution: what the puck does after it meets the goalie.
#
# It is a CONTACT, not a choice. The puck strikes a surface with a material and
# an orientation, and the rebound follows from the two — the same
# normal/tangential decomposition the blade deflect and the boards use
# (PuckCollisionRules.deflect_velocity_3d), through the real outward normal the
# swept-OBB test reports. There is no menu of save outcomes to pick from, no
# speed at which the model changes character, and no exit vector written down in
# advance.
#
# ONE THING IS NOT A CONTACT, and it is the only exception: a GLOVE CATCH. A
# puck does not stop because leather is soft, it stops because he closes his
# hand on it — an action he takes, which is why it is the one outcome that needs
# a gate rather than a material. It is also the only path that ends a play, so
# the whistle depends on it. See `resolve_contact`.
#
# Deterministic (no randomness) so a client-predicted puck and the host agree
# before reconciliation.

# Which save surface the puck struck. Ordering is load-bearing: it indexes
# MATERIALS.
enum SavePart { STICK, PAD, BLOCKER, CHEST, GLOVE }

# ── Materials ────────────────────────────────────────────────────────────────
# Three numbers per surface, flat, indexed by SavePart × STRIDE: the restitution
# against a SLOW puck, the restitution at/above SPEED_REF_M_S, and how much of a
# glance along the face survives.
#
# The speed falloff is the puck's own measured behaviour, not a shaping curve:
# COR drops roughly linearly with impact speed (0.50 at 15 mph to 0.34 at 85
# against a rigid plate; a frozen game-temperature puck plateaus near 0.27 — WSU
# Sports Science Lab, "Experimental Characterization of Ice Hockey Sticks and
# Pucks"). Every surface here is softer than that rigid plate, so every row sits
# under it.
#
# THE ORDERING IS THE PHYSICAL CLAIM, not the digits. Stiffest to softest: a
# composite paddle is the hardest thing on him; a blocker is a board behind thin
# foam; a leg pad is thick foam over a stiff core, built to absorb; a chest
# protector is foam over a torso that gives; and softest of all is a glove the
# hand did not close on, which is a floppy leather pocket. Move a row and you are
# asserting something about the equipment — keep the order.
#
# What used to be here instead: a speed threshold that switched between a
# scripted cornerward exit and a reflection. Nothing physical happens to a pad at
# 28 m/s, and the scripted branch kept 82% of pad rebounds in the slot because a
# constant vector cannot know where the shot came from
# (test_goalie_rebound_destination).
const MAT_STRIDE: int = 3
const MAT_SOFT: int = 0    # restitution against a slow puck
const MAT_HARD: int = 1    # restitution at/above SPEED_REF_M_S
const MAT_TANGENTIAL: int = 2
const SPEED_REF_M_S: float = 30.0
const MATERIALS: Array[float] = [
	0.50, 0.30, 0.85,   # STICK   — composite paddle, the stiffest surface on him
	0.35, 0.15, 0.80,   # PAD     — thick foam over a stiff core, built to absorb
	0.45, 0.25, 0.80,   # BLOCKER — a board behind thin foam
	0.15, 0.05, 0.65,   # CHEST   — foam over a torso that gives with the shot
	0.12, 0.05, 0.60,   # GLOVE   — softest of all: a leather pocket he did not close
]


# Whole-contact result: the resolved velocity plus the one discrete flag the
# caller acts on — a glove catch, which freezes the play.
class ContactResult:
	var velocity: Vector3 = Vector3.ZERO
	var caught: bool = false    # glove catch — the goalie holds it, play stops


# Resolve a puck-vs-goalie contact. `contact_normal` points out of the struck
# surface toward the puck (SweptDiscOBB's outward normal); `goalie_forward` is
# the direction he faces, used ONLY by the catch. Fills a caller-owned result
# (no allocation). Deterministic, so a client-predicted puck and the host agree
# before reconciliation.
static func resolve_contact(
		incoming: Vector3, part: int, contact_normal: Vector3,
		result: ContactResult, goalie_forward: Vector3 = Vector3.ZERO) -> void:
	if part == SavePart.GLOVE and is_face_presented(contact_normal, goalie_forward):
		# He closed his hand on it. Zero rather than a slow drift: the controller
		# pins the transform from the catch signal, which arrives on the next
		# frame's drain, and a puck still carrying pace crosses several
		# centimetres in between.
		result.velocity = Vector3.ZERO
		result.caught = true
		return
	result.velocity = rebound_velocity(incoming, part, contact_normal)
	result.caught = false


# The rebound off `part`'s material, through the real contact normal. A
# separating puck comes back unchanged.
static func rebound_velocity(
		incoming: Vector3, part: int, contact_normal: Vector3) -> Vector3:
	var base: int = clampi(part, 0, SavePart.size() - 1) * MAT_STRIDE
	return PuckCollisionRules.deflect_velocity_3d(
			incoming, contact_normal,
			MATERIALS[base + MAT_SOFT],
			MATERIALS[base + MAT_HARD],
			MATERIALS[base + MAT_TANGENTIAL],
			SPEED_REF_M_S)


# Is the struck surface one the goalie is actually PRESENTING to the puck?
#
# `contact_normal` points outward, from the goalie's surface toward the puck, so
# a normal aligned with the direction he FACES was struck on his front, and one
# pointing behind him was struck on his back.
#
# Facing, not the net. Testing the normal against which side of him the net is on
# is wrong for exactly the plays that matter: a goalie tracking a wraparound or
# out playing a rim is turned, so the surface nearest his own goal can be the one
# his chest is pointed at, and the surface facing up-ice can be his shoulder.
# What he can catch is what he is looking at.
#
# It gates the CATCH and nothing else now that every other outcome is a contact.
# Closing a hand on a puck is a thing a goalie DOES, and he has to be facing it;
# a puck into the back of his glove hand is leather, and leather is a material.
# Threshold-free: a face is presented or it is not, and a contact exactly side-on
# is not — you cannot catch with the edge of your hand either.
#
# A zero `goalie_forward` means the caller has no facing to offer, in which case
# every face counts as presented.
static func is_face_presented(contact_normal: Vector3, goalie_forward: Vector3) -> bool:
	if goalie_forward.length_squared() < 0.000001:
		return true
	return contact_normal.x * goalie_forward.x + contact_normal.z * goalie_forward.z > 0.0
