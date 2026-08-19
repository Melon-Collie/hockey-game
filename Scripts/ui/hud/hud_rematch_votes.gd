class_name HudRematchVotes
extends RefCounted

# The shared play-again vote pool (REMATCH and LOBBY are flavors of the same
# unanimous vote). Owns the tally; the HUD renders it and acts on `resolved`.

signal tally_changed(votes: Dictionary, total: int, local_vote: int)
signal resolved(choice: int)

# peer_id -> RematchVoteRules.Choice
var _votes: Dictionary[int, int] = {}
var _local_vote: int = RematchVoteRules.Choice.NONE
# Authoritative voter-pool size (connected humans minus spectators). The host
# computes and broadcasts it (skip-vote pattern: host counts, peers display) —
# clients can't derive it locally because from-lobby spectators are only
# tracked host-side. 0 = no broadcast landed yet (client fallback estimate).
var _total: int = 0

func reset() -> void:
	_votes.clear()
	_local_vote = RematchVoteRules.Choice.NONE
	# Zeroing forces the host's refresh below to see a change and broadcast a
	# fresh total (clients just zeroed their mirror and are waiting on it).
	_total = 0
	_publish()

# The two vote buttons toggle their own flavor and steal from the other:
# pressing the flavor you already voted withdraws (NONE); pressing the other
# switches the vote in one click.
func toggle_local(choice: int) -> void:
	_local_vote = RematchVoteRules.Choice.NONE if _local_vote == choice else choice
	NetworkManager.send_rematch_vote(_local_vote)

func on_vote_changed(peer_id: int, vote: int) -> void:
	_votes[peer_id] = vote
	_publish()
	_check_unanimous()

func on_peer_disconnected(peer_id: int) -> void:
	_votes.erase(peer_id)
	_publish()
	_check_unanimous()

func on_voters_changed(total: int) -> void:
	_total = total
	_publish()

func _publish() -> void:
	_refresh_voter_total()
	# Client fallback until the host's total lands: everyone connected. It can
	# overcount (unreplicated from-lobby spectators) for at most the RPC gap.
	var total: int = _total if _total > 0 \
			else NetworkManager.connected_peer_ids().size() + 1
	tally_changed.emit(_votes, total, _local_vote)

# Host-side: recompute the voter pool and broadcast it when it moves. Spectators
# don't have a vote button; spectator_peer_count already includes the host's
# peer (1) if the host is itself a spectator, so a single subtraction yields
# the actual pool. Re-run on every vote/disconnect funnel so a mid-screen
# spectator demotion is picked up on the next vote event.
func _refresh_voter_total() -> void:
	if not NetworkManager.is_host:
		return
	var total: int = NetworkManager.connected_peer_ids().size() + 1 \
			- GameManager.spectator_peer_count()
	if total == _total:
		return
	_total = total
	NetworkManager.send_rematch_voters_to_all(total)

# Host-side. _publish ran first on every path, so _total is freshly recomputed
# by the time the pool is resolved.
func _check_unanimous() -> void:
	if not NetworkManager.is_host:
		return
	var choice: int = RematchVoteRules.resolve(_votes, _total)
	if choice != RematchVoteRules.Choice.NONE:
		resolved.emit(choice)
