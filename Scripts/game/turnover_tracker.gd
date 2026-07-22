class_name TurnoverTracker extends RefCounted
## Host-only attribution of takeaways / giveaways / faceoff wins from
## possession changes. GameManager feeds it four authoritative hooks — a
## possession gain (puck picked up), an ESTABLISHED possession (see
## PossessionTracker), a strip (puck_stripped_from, carrying the defender who
## made the play), and a shot attempt — and it mutates the affected players'
## PlayerStats. The pure decision lives in TurnoverRules; this holds the
## short-lived context (last established owner + recent strip/shot) needed to
## classify each gain. A takeaway credits the STRIPPER (the defender who caused
## the loss), not whoever recovers the loose puck; recovering a shot (saved or
## missed) is neither a takeaway nor a giveaway.
##
## Crediting is deferred to ESTABLISHMENT: a pickup computes the candidate
## classification (against the last ESTABLISHED owner, with the strip/shot
## windows read at pickup time, when the context is freshest), but the stat
## lands only when that carrier establishes possession. A scramble of
## momentary touches — contested draws, board battles — therefore mints
## nothing until someone actually comes out of the pile with the puck.
##
## Faceoff wins follow the NHL definition: the draw is won by the team that
## FIRST ESTABLISHES possession after the drop (credited to that team's
## centre), not by the first blade to graze it. The win pends from the
## faceoff pickup until an establishment; resolve_pending_faceoff() is the
## terminal fallback (goal / whistle before anyone establishes) so every
## draw still gets a winner. While a draw is pending, no turnover is
## classified — the NHL never charges a giveaway/takeaway on the draw.
##
## Only ever constructed/called on the host (like HitTracker), so the stats
## it writes are authoritative and ride the normal stats broadcast.

# A recovery within this of a strip counts as a takeaway; within this of a shot
# attempt counts as a rebound (no turnover). Generous windows — possession often
# bounces loose for a moment between the event and the recovery.
const STRIP_WINDOW_S: float = 1.5
const SHOT_WINDOW_S: float = 2.0

var _registry: PlayerRegistry = null
# Last ESTABLISHED possession — the "previous owner" a new gain classifies
# against. Unestablished touches never advance this.
var _last_established_peer: int = -1
var _last_established_team: int = -1
var _strip_time: float = -INF
var _strip_victim_team: int = -1
# The defender who made the strip (poke / stick-lift / body-check). A takeaway
# is credited to THEM, not whoever recovers the loose puck. -1 for a goalie
# strip (no player takeaway).
var _strip_stripper_peer: int = -1
var _shot_time: float = -INF
var _shot_team: int = -1
# Candidate turnover computed at pickup, credited when the carrier establishes.
# Overwritten by the next pickup, so it always describes the current carrier.
var _candidate_type: String = TurnoverRules.NONE
var _candidate_carrier_peer: int = -1
var _candidate_credit_peer: int = -1
# Draw winner pending since the faceoff pickup, awaiting first establishment.
var _faceoff_pending: bool = false


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


# Possession gained by `peer_id`. `was_faceoff` = this pickup ended a faceoff
# (first touch after the drop). Computes the turnover candidate; nothing is
# credited until on_possession_established.
func on_carrier_gained(peer_id: int, was_faceoff: bool) -> void:
	if _registry == null:
		return
	var rec: PlayerRecord = _registry.get_record(peer_id)
	if rec == null or rec.team == null:
		return
	var new_team: int = rec.team.team_id
	if was_faceoff:
		# The draw is live — winner pends until the first establishment. A
		# faceoff is a fresh start, so clear stale turnover context too.
		_faceoff_pending = true
		_clear_candidate()
		_strip_time = -INF
		_shot_time = -INF
		return
	if _faceoff_pending:
		# Draw scramble — no turnovers until the draw resolves.
		_clear_candidate()
		return
	var now: float = _now()
	var recent_strip: bool = _strip_time + STRIP_WINDOW_S > now \
			and _strip_victim_team == _last_established_team
	var recent_shot: bool = _shot_time + SHOT_WINDOW_S > now \
			and _shot_team == _last_established_team
	_candidate_type = TurnoverRules.classify(
			_last_established_team, new_team, recent_strip, recent_shot)
	_candidate_carrier_peer = peer_id
	match _candidate_type:
		TurnoverRules.TAKEAWAY:
			# Credit the defender who made the strip, not this recoverer — a poke
			# to a teammate is the poker's takeaway. -1 (goalie strip) credits none.
			_candidate_credit_peer = _strip_stripper_peer
		TurnoverRules.GIVEAWAY:
			_candidate_credit_peer = _last_established_peer
		_:
			_candidate_credit_peer = -1


# `peer_id` ESTABLISHED possession (held it, or made a deliberate play).
# Lands the pending faceoff win or turnover candidate and advances the
# last-established owner. Returns true when a stat was credited, so the
# caller knows to broadcast the stats now rather than on the next event.
func on_possession_established(peer_id: int) -> bool:
	if _registry == null:
		return false
	var rec: PlayerRecord = _registry.get_record(peer_id)
	if rec == null or rec.team == null:
		return false
	var credited: bool = false
	if _faceoff_pending:
		_faceoff_pending = false
		credited = _credit_faceoff_win(rec.team.team_id)
	elif _candidate_carrier_peer == peer_id:
		match _candidate_type:
			TurnoverRules.TAKEAWAY:
				# Credit the stripper (the defender who made the play), which may
				# be this recoverer or a teammate they fed. -1 = goalie strip → none.
				var taker: PlayerRecord = _registry.get_record(_candidate_credit_peer)
				if taker != null and taker.stats != null:
					taker.stats.takeaways += 1
					credited = true
			TurnoverRules.GIVEAWAY:
				var prev: PlayerRecord = _registry.get_record(_candidate_credit_peer)
				if prev != null and prev.stats != null:
					prev.stats.giveaways += 1
					credited = true
	_clear_candidate()
	_last_established_peer = peer_id
	_last_established_team = rec.team.team_id
	return credited


# Terminal fallback so every draw has a winner: play stopped (goal, whistle)
# before anyone established, so the draw goes to `team_id` — the team of the
# last toucher at the stoppage (the scoring team on a goal). Returns true
# when a stat was credited.
func resolve_pending_faceoff(team_id: int) -> bool:
	if not _faceoff_pending:
		return false
	_faceoff_pending = false
	if team_id < 0:
		return false
	return _credit_faceoff_win(team_id)


func has_pending_faceoff() -> bool:
	return _faceoff_pending


# A defender stripped the puck from `victim_peer_id` (poke / stick-lift /
# body-check). `stripper_peer_id` is the defender who made the play — a takeaway
# credits THEM, not whoever recovers the loose puck. -1 (goalie strip) = no
# player takeaway.
func note_strip(victim_peer_id: int, stripper_peer_id: int) -> void:
	_strip_time = _now()
	_strip_victim_team = _team_of(victim_peer_id)
	_strip_stripper_peer = stripper_peer_id


# `shooter_peer_id` put the puck at the net (any shot attempt — saved, missed,
# or blocked). Opens the window in which recovering the loose puck reads as a
# rebound, not a turnover. Fed from every shot release, and refreshed at a
# confirmed shot-on-goal so a save's rebound stays covered past the shot flight.
func note_shot(shooter_peer_id: int) -> void:
	_shot_time = _now()
	_shot_team = _team_of(shooter_peer_id)


# Clear all context (new game / rematch reset).
func reset() -> void:
	_last_established_peer = -1
	_last_established_team = -1
	_strip_time = -INF
	_strip_victim_team = -1
	_strip_stripper_peer = -1
	_shot_time = -INF
	_shot_team = -1
	_clear_candidate()
	_faceoff_pending = false


func _clear_candidate() -> void:
	_candidate_type = TurnoverRules.NONE
	_candidate_carrier_peer = -1
	_candidate_credit_peer = -1


func _credit_faceoff_win(winning_team: int) -> bool:
	# The centre (team_slot 0) takes the draw, so the win/loss is theirs
	# regardless of which linemate actually corralled the loose puck. The
	# opposing centre is charged a loss so faceoff % has a real denominator.
	var credited: bool = false
	for pid: int in _registry.all():
		var r: PlayerRecord = _registry.get_record(pid)
		if r == null or r.team == null or r.team_slot != 0 or r.stats == null:
			continue
		if r.team.team_id == winning_team:
			r.stats.faceoff_wins += 1
			credited = true
		else:
			r.stats.faceoff_losses += 1
	return credited


func _team_of(peer_id: int) -> int:
	if _registry == null:
		return -1
	var r: PlayerRecord = _registry.get_record(peer_id)
	return r.team.team_id if r != null and r.team != null else -1


func _now() -> float:
	return Time.get_ticks_msec() / 1000.0
