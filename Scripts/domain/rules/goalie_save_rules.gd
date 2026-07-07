class_name GoalieSaveRules

# Pure save-rebound resolution. A real goalie CONTROLS rebounds — absorbs shots
# into the chest/glove, steers pads wide — rather than caroming every puck back
# into the slot at the material's restitution. Given the incoming (pre-bounce)
# puck velocity and which part made the save, this decides whether the save is
# "controlled" (deaden the rebound to a dead drop the goalie then sweeps clear)
# or "live" (a hard pad save that kicks out a real rebound — the beatable-realism
# scramble chance).
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
	var pad_max_incoming_speed: float = 22.0
	# Deadened exit-speed ceiling (m/s). Even a firm controlled save leaves the
	# puck crawling so the crease sweep can whisk it to the corner.
	var drop_speed: float = 1.2
	# Fraction of the incoming LATERAL speed retained per part. Goalward (z) and
	# vertical (y) motion are always killed so a deadened puck settles in front of
	# the goalie instead of trickling into the net or popping up.
	var glove_retain: float = 0.0    # a catch kills it dead
	var chest_retain: float = 0.12
	var pad_retain: float = 0.35
	var blocker_retain: float = 0.45

# True when the save should be deadened (rebound killed) rather than left live.
static func is_controlled_save(incoming_speed: float, part: int, cfg: DeadenConfig) -> bool:
	match part:
		SavePart.STICK:
			return false
		SavePart.GLOVE, SavePart.CHEST:
			return true
		_:  # PAD, BLOCKER — deflecting surfaces only eat the easy ones
			return incoming_speed <= cfg.pad_max_incoming_speed

# Deadened exit velocity for a controlled save. Keeps only a clamped fraction of
# the incoming LATERAL (world-x) drift; goalward (z) and vertical (y) motion are
# zeroed so the puck can't trickle into the net or pop up off a soft save. Caller
# applies this only when is_controlled_save is true.
static func deadened_velocity(incoming_velocity: Vector3, part: int, cfg: DeadenConfig) -> Vector3:
	var lateral: float = incoming_velocity.x * _retain_for_part(part, cfg)
	if absf(lateral) > cfg.drop_speed:
		lateral = signf(lateral) * cfg.drop_speed
	return Vector3(lateral, 0.0, 0.0)

static func _retain_for_part(part: int, cfg: DeadenConfig) -> float:
	match part:
		SavePart.GLOVE:
			return cfg.glove_retain
		SavePart.CHEST:
			return cfg.chest_retain
		SavePart.BLOCKER:
			return cfg.blocker_retain
	return cfg.pad_retain
