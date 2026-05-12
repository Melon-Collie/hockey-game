class_name HitRules

# Pure rules for crediting a body check as a "hit" stat. No engine deps.
# A hit only counts when the contact represents a meaningful body check:
#   • impulse (weight × closing velocity) clears MIN_HIT_IMPULSE
#   • the attacker is not carrying the puck
#   • the victim is the puck carrier, or the puck is within
#     PUCK_PROXIMITY_RADIUS of the victim (a puck battle).

# Minimum impulse magnitude. Skater weight is uniform (1.0) today so this is
# effectively a closing-speed floor in m/s. Tune in playtesting.
const MIN_HIT_IMPULSE: float = 3.0
const PUCK_PROXIMITY_RADIUS: float = 3.0
const PUCK_PROXIMITY_RADIUS_SQ: float = PUCK_PROXIMITY_RADIUS * PUCK_PROXIMITY_RADIUS


static func is_valid_hit(
		impulse_magnitude: float,
		attacker_has_puck: bool,
		victim_puck_relevant: bool) -> bool:
	if impulse_magnitude < MIN_HIT_IMPULSE:
		return false
	if attacker_has_puck:
		return false
	if not victim_puck_relevant:
		return false
	return true


static func is_victim_puck_relevant(
		victim_peer_id: int,
		puck_carrier_peer_id: int,
		victim_pos: Vector3,
		puck_pos: Vector3) -> bool:
	if puck_carrier_peer_id == victim_peer_id:
		return true
	var dx: float = victim_pos.x - puck_pos.x
	var dz: float = victim_pos.z - puck_pos.z
	return (dx * dx + dz * dz) <= PUCK_PROXIMITY_RADIUS_SQ
