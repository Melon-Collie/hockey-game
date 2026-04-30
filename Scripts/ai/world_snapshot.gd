class_name WorldSnapshot
extends RefCounted

# A single physics-tick snapshot of the world that AI agents consume. Owned
# and recycled by PerceptionBuffer — never allocate a new one per tick.
#
# Schema (parallel arrays, size MAX_PLAYERS for skaters, 2 for goalies):
#   skater_peer_id[i] == -1 means the slot is empty.
#   puck_possessor_idx is an index into skater_peer_id, or -1 if loose.
#
# Phase 2 fills this from GameManager._registry.all() + GameManager.puck +
# GameManager.goalies once per host physics tick. Phase 3+ agents read with
# a tick delay (PerceptionBuffer.read) and may overlay positional noise.

const MAX_SKATERS: int = 6
const MAX_GOALIES: int = 2

var tick: int = 0
var time: float = 0.0

var num_skaters: int = 0
var skater_peer_id: PackedInt32Array = PackedInt32Array()    # size MAX_SKATERS, -1 = empty slot
var skater_pos: PackedVector3Array  = PackedVector3Array()    # size MAX_SKATERS
var skater_vel: PackedVector3Array  = PackedVector3Array()    # size MAX_SKATERS
var skater_team: PackedInt32Array   = PackedInt32Array()      # size MAX_SKATERS

var num_goalies: int = 0
var goalie_pos: PackedVector3Array  = PackedVector3Array()    # size MAX_GOALIES
var goalie_team: PackedInt32Array   = PackedInt32Array()      # size MAX_GOALIES

var puck_pos: Vector3 = Vector3.ZERO
var puck_vel: Vector3 = Vector3.ZERO
# Index into skater_peer_id of the carrier, or -1 if puck is loose.
var puck_possessor_idx: int = -1


func _init() -> void:
	skater_peer_id.resize(MAX_SKATERS)
	skater_pos.resize(MAX_SKATERS)
	skater_vel.resize(MAX_SKATERS)
	skater_team.resize(MAX_SKATERS)
	goalie_pos.resize(MAX_GOALIES)
	goalie_team.resize(MAX_GOALIES)
	_clear_skater_slots()


func clear() -> void:
	tick = 0
	time = 0.0
	num_skaters = 0
	num_goalies = 0
	puck_pos = Vector3.ZERO
	puck_vel = Vector3.ZERO
	puck_possessor_idx = -1
	_clear_skater_slots()


# Returns the index of the skater with the given peer_id, or -1 if not found.
# Linear scan; n=6 means this is faster than a Dictionary lookup.
func find_skater(peer_id: int) -> int:
	for i: int in num_skaters:
		if skater_peer_id[i] == peer_id:
			return i
	return -1


func _clear_skater_slots() -> void:
	for i: int in MAX_SKATERS:
		skater_peer_id[i] = -1
