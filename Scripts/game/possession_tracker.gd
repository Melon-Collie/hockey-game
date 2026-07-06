class_name PossessionTracker extends RefCounted
## Host-only established-possession model for stat attribution (the pure
## establishment test lives in PossessionRules). GameManager feeds it the
## authoritative pickup / release / strip hooks plus tick(delta); it emits
## `possession_established` once per possession spell — when the carrier has
## held the puck for PossessionRules.ESTABLISH_HOLD_S, or instantly when they
## make a deliberate play with it (pass/shot from carry). A spell that ends
## in a strip, drop, or fumble before establishing emits nothing: it was a
## touch, not possession.
##
## Also answers "which team has possession?" — the team of the last
## established spell, persisting through loose pucks and unestablished
## touches until the other team establishes (or a whistle resets it).
##
## Only ever constructed/called on the host (like HitTracker/TurnoverTracker);
## the stats its consumers write ride the normal stats broadcast.

signal possession_established(peer_id: int, team_id: int)

var _registry: PlayerRegistry = null
var _carrier_peer: int = -1
var _carrier_team: int = -1
var _hold_seconds: float = 0.0
var _established: bool = false
var _controlling_peer: int = -1
var _controlling_team: int = -1


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


func on_pickup(peer_id: int) -> void:
	_carrier_peer = peer_id
	_carrier_team = _team_of(peer_id)
	_hold_seconds = 0.0
	_established = false


# The carrier made a deliberate play (pass / shot from carry) — instant
# establishment, then the spell ends. Called BEFORE the puck's release signal
# fires (while the carrier is still set), so the trailing on_puck_lost no-ops.
func on_deliberate_release(peer_id: int) -> void:
	if peer_id == _carrier_peer and not _established:
		_establish()
	if peer_id == _carrier_peer:
		_clear_carrier()


# The puck left the carrier without a deliberate play — strip, knock-loose,
# whistle drop. No establishment; an unestablished spell was just a touch.
func on_puck_lost(peer_id: int) -> void:
	if peer_id == _carrier_peer:
		_clear_carrier()


func tick(delta: float) -> void:
	if _carrier_peer == -1 or _established:
		return
	_hold_seconds += delta
	if PossessionRules.is_established(_hold_seconds, false):
		_establish()


# Team of the last established possession (-1 before any / after a reset).
func get_controlling_team() -> int:
	return _controlling_team


func get_controlling_peer() -> int:
	return _controlling_peer


# Full clear — new game, or a whistle (a faceoff starts from neutral
# possession, matching the "every draw has a winner" crediting).
func reset() -> void:
	_clear_carrier()
	_controlling_peer = -1
	_controlling_team = -1


func _establish() -> void:
	_established = true
	_controlling_peer = _carrier_peer
	_controlling_team = _carrier_team
	possession_established.emit(_carrier_peer, _carrier_team)


func _clear_carrier() -> void:
	_carrier_peer = -1
	_carrier_team = -1
	_hold_seconds = 0.0
	_established = false


func _team_of(peer_id: int) -> int:
	if _registry == null:
		return -1
	var r: PlayerRecord = _registry.get_record(peer_id)
	return r.team.team_id if r != null and r.team != null else -1
