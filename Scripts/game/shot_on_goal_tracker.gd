class_name ShotOnGoalTracker
extends RefCounted

# Host-only tracker for shot-on-goal + assist crediting. Pulled out of
# GameManager so the shot-tracking state machine (pending shot → goalie save or
# goal → credit) can be reasoned about and unit-tested in isolation.
#
# Flow:
#   on_pickup(peer_id)              → records toucher, clears any pending shot
#   on_possession_established(peer_id) → upgrades the toucher to ESTABLISHED
#                                     possession (breaks opposing assist chains)
#   on_deflection(peer_id)          → records toucher in carrier history, keeps pending shot alive
#   on_shot_started(peer_id)        → arms pending-shot timer (on net until told otherwise)
#   note_trajectory(on_net)         → live ballistic read (ShotOnNetRules) after
#                                     the release and after each deflection
#   on_post_hit()                   → pipes = a miss; pending shot no longer on net
#   on_goalie_touch(defending_tid)  → confirms SOG if eligible AND the shot was on net
#   on_goal_confirmed(scorer_id)    → confirms SOG (non-own-goal only)
#   on_block(blocker_peer_id)       → credits shots_blocked if defender intercepts a pending ON-NET shot
#   credit_assists(scorer_id)       → reads recent_carriers for 2 assists
#   tick(delta)                     → clears pending after timeout
#
# Nothing here reaches into Godot nodes. Writes stats through the injected
# `PlayerRegistry` (for per-player stats) and `GameStateMachine` (for team
# shots counter). Emits `shots_on_goal_changed(sog_0, sog_1)` for UI.

signal shots_on_goal_changed(sog_0: int, sog_1: int)
# Fires once per counted shot on goal, carrying the shooter. TurnoverTracker uses
# it to treat a rebound recovered by the other team as a shot (not a giveaway).
signal shot_on_goal_recorded(peer_id: int)

const SHOT_ON_GOAL_TIMEOUT: float = 5.0
# A genuine blocked shot happens within a beat of the release — the puck travels
# stick-to-blocker in a fraction of a second. The 5 s SOG window is far too wide
# to gate blocks: a defender corralling a loose rebound in the corner three
# seconds later isn't a "blocked shot." Blocks get their own short window so only
# an interception of the shot itself counts.
const BLOCK_WINDOW: float = 0.85
# Deep enough that the scorer + two assist candidates survive even when
# opposing deflections (which credit_assists skips, NHL-style) occupy slots.
const MAX_RECENT_CARRIERS: int = 5
const MAX_ASSISTS: int = 2

# Parallel arrays: the recent puck touchers (most recent first) and whether
# each touch became ESTABLISHED possession (held long enough / made a play —
# see PossessionTracker) or stayed a mere touch (deflection, momentary
# scramble attach). The distinction drives the NHL assist chain — opposing
# ESTABLISHED possession breaks it, an opposing touch doesn't. A pickup
# starts as a touch and upgrades via on_possession_established.
var _recent_carriers: Array[int] = []
var _recent_carrier_possession: Array[bool] = []
var _shooter_peer_id: int = -1
var _pending_remaining: float = -1.0
var _block_window_remaining: float = -1.0
var _shot_on_goal_counted: bool = false
# Whether the pending shot's current trajectory would enter the net (NHL: only
# such a puck stopped by the goalie is a shot on goal). Armed true at release,
# then kept current by note_trajectory / on_post_hit.
var _pending_on_net: bool = false

var _registry: PlayerRegistry = null
var _state_machine: GameStateMachine = null


func setup(registry: PlayerRegistry, state_machine: GameStateMachine) -> void:
	_registry = registry
	_state_machine = state_machine


# ── Events ────────────────────────────────────────────────────────────────────

func on_pickup(peer_id: int) -> void:
	clear_pending()
	# A pickup alone is only a touch — a momentary attach in a scramble must
	# not break the opposing assist chain. on_possession_established upgrades.
	_record_toucher(peer_id, false)


# The current carrier ESTABLISHED possession (PossessionTracker). Upgrade
# their history entry so an opposing goal's assist chain breaks on it.
func on_possession_established(peer_id: int) -> void:
	for i: int in _recent_carriers.size():
		if _recent_carriers[i] == peer_id:
			_recent_carrier_possession[i] = true
			return


# Called when a loose puck is deflected or body-blocked by a skater. Records the
# toucher in the carrier history (for assist credit) but keeps the pending shot
# alive — a tip-in off a shot still counts.
func on_deflection(peer_id: int) -> void:
	if peer_id == -1:
		return
	_record_toucher(peer_id, false)


func _record_toucher(peer_id: int, possession: bool) -> void:
	if not _recent_carriers.is_empty() and _recent_carriers[0] == peer_id:
		# Consecutive touches by the same player collapse into one entry; an
		# established flag already earned on the entry survives further touches.
		_recent_carrier_possession[0] = _recent_carrier_possession[0] or possession
		return
	_recent_carriers.push_front(peer_id)
	_recent_carrier_possession.push_front(possession)
	if _recent_carriers.size() > MAX_RECENT_CARRIERS:
		_recent_carriers.resize(MAX_RECENT_CARRIERS)
		_recent_carrier_possession.resize(MAX_RECENT_CARRIERS)


# Call when a carrier releases the puck as a normal shot. The carrier was
# already recorded via on_pickup, so just arm the pending-shot window.
func on_shot_started(shooter_peer_id: int) -> void:
	if shooter_peer_id == -1:
		return
	_shooter_peer_id = shooter_peer_id
	_pending_remaining = SHOT_ON_GOAL_TIMEOUT
	_block_window_remaining = BLOCK_WINDOW
	_shot_on_goal_counted = false
	# Assume on net until the caller's ballistic read (note_trajectory, run
	# right after the authoritative release) says otherwise — a missed read
	# should over-credit, not swallow saves.
	_pending_on_net = true


# Updates the pending shot's on-net read (computed by the caller from the live
# puck trajectory — ShotOnNetRules). Called after the authoritative release and
# again after every mid-flight deflection, so a wide shot tipped on net (or an
# on-net shot tipped wide) re-reads correctly. No-op without a pending shot.
func note_trajectory(on_net: bool) -> void:
	if _shooter_peer_id == -1:
		return
	_pending_on_net = on_net


# A shot off the pipes is a MISS in NHL scoring — it was never "on goal", so a
# goalie touch on the ricochet must not confirm a SOG. The pending shot stays
# alive for goal attribution: a carom that still crosses the line counts via
# on_goal_confirmed, which credits unconditionally.
func on_post_hit() -> void:
	if _shooter_peer_id == -1:
		return
	_pending_on_net = false


# Called when a skater (blade or body) intercepts a loose puck while a shot is
# in flight. If the blocker is on the defending team, credit the blocker with a
# blocked shot and clear the pending shot — the puck has been intercepted
# before reaching the goalie. Same-team contact (a tip-in attempt) doesn't
# count and is left for `on_deflection` to record. Returns true if a stat was
# credited.
func on_block(blocker_peer_id: int) -> bool:
	if blocker_peer_id == -1:
		return false
	if _shooter_peer_id == -1:
		return false
	# Only a touch within the short post-release window is a block — a later loose
	# puck touch is just a takeaway/rebound, not a blocked shot.
	if _block_window_remaining <= 0.0:
		return false
	# NHL: a blocked SHOT must have been directed on net — intercepting a wide
	# cross-crease pass or an errant shot is a takeaway, not a blocked shot.
	if not _pending_on_net:
		return false
	var shooter_team: int = _registry.resolve_team_id_for_peer(_shooter_peer_id)
	var blocker_team: int = _registry.resolve_team_id_for_peer(blocker_peer_id)
	if shooter_team == -1 or blocker_team == -1:
		return false
	if shooter_team == blocker_team:
		return false
	var record: PlayerRecord = _registry.get_record(blocker_peer_id)
	if record == null:
		return false
	record.stats.shots_blocked += 1
	clear_pending()
	return true


# Called when a goalie body contacts the puck while a shot is in flight.
# Counts a SOG unless the shooter's own goalie saved it (own-goal attempt).
func on_goalie_touch(defending_team_id: int) -> void:
	if _shooter_peer_id == -1:
		return
	if defending_team_id == -1:
		return
	var shooter_team: int = _registry.resolve_team_id_for_peer(_shooter_peer_id)
	if shooter_team == defending_team_id:
		return  # own-goal attempt — not a shot on their own net
	# NHL: only a puck that would have gone in counts when the goalie stops it.
	# The goalie playing a wide pass, corralling an errant shot, or covering a
	# post ricochet is not a save of a shot on goal.
	if not _pending_on_net:
		return
	# NHL tip attribution: a shot redirected by an attacking teammate is the
	# TIPPER's shot on goal (matching goal attribution, which credits the last
	# toucher when a tip goes in). A deflection off a defender stays the
	# shooter's shot. The only way the front of the carrier history differs
	# from the shooter mid-flight is an on_deflection touch — a pickup would
	# have cleared the pending shot.
	var credit_pid: int = _shooter_peer_id
	var last_toucher: int = get_last_toucher()
	if last_toucher != -1 and last_toucher != _shooter_peer_id \
			and _registry.resolve_team_id_for_peer(last_toucher) == shooter_team:
		credit_pid = last_toucher
	_confirm(credit_pid)
	# Keep _shooter_peer_id for post-save goal attribution; stop the timeout.
	_pending_remaining = -1.0


# Called when the ref confirms a goal. Confirms SOG (dedup-safe via counted flag).
func on_goal_confirmed(scorer_peer_id: int) -> void:
	_confirm(scorer_peer_id)


# Returns up to 2 assist names for same-team recent carriers preceding scorer.
# Mutates PlayerStats.assists on each credited player. NHL chain rule: an
# opposing ESTABLISHED possession breaks the chain, but a mere opposing touch
# (a pass deflecting off a defender's blade or body, or a momentary attach in
# a goal-mouth scramble) does not — the player who sent the puck in still
# earns the assist when no opponent ever controlled it.
func credit_assists(scorer_peer_id: int) -> Array[String]:
	var names: Array[String] = []
	var scorer_team_id: int = _registry.resolve_team_id_for_peer(scorer_peer_id)
	if scorer_team_id == -1:
		return names
	for i: int in range(1, _recent_carriers.size()):
		var pid: int = _recent_carriers[i]
		if pid == scorer_peer_id:
			break  # scorer's own prior touch ends the chain
		var record: PlayerRecord = _registry.get_record(pid)
		if record == null:
			continue
		if record.team.team_id != scorer_team_id:
			if _recent_carrier_possession[i]:
				break  # opponent possessed the puck — chain broken
			continue  # opponent only touched it — skip, keep walking
		record.stats.assists += 1
		names.append(record.display_name())
		if names.size() >= MAX_ASSISTS:
			break
	return names


func tick(delta: float) -> void:
	if _block_window_remaining > 0.0:
		_block_window_remaining -= delta
	if _pending_remaining < 0.0:
		return
	_pending_remaining -= delta
	if _pending_remaining <= 0.0:
		clear_pending()


# ── Accessors ─────────────────────────────────────────────────────────────────

func get_shooter_peer_id() -> int:
	return _shooter_peer_id

# Returns the most recent player to touch the puck (carrier or deflector), or -1.
func get_last_toucher() -> int:
	return _recent_carriers[0] if not _recent_carriers.is_empty() else -1


func has_pending_shot() -> bool:
	return _shooter_peer_id != -1


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func clear_pending() -> void:
	_shooter_peer_id = -1
	_pending_remaining = -1.0
	_block_window_remaining = -1.0
	_shot_on_goal_counted = false
	_pending_on_net = false


# Called on full game reset. Clears carrier history plus pending state, and
# zeroes the team shots counters (emitting the change signal).
func reset_all() -> void:
	_recent_carriers.clear()
	_recent_carrier_possession.clear()
	clear_pending()
	if _state_machine != null:
		_state_machine.team_shots[0] = 0
		_state_machine.team_shots[1] = 0
	shots_on_goal_changed.emit(0, 0)


# Called on scene exit.
func clear_state() -> void:
	_recent_carriers.clear()
	_recent_carrier_possession.clear()
	clear_pending()


# Returns a carrier from `recent_carriers` on `scoring_team_id`. Used when the
# direct shooter owned by the opposing team (own-goal rebound attribution).
func find_scorer_on_team(scoring_team_id: int) -> int:
	for pid: int in _recent_carriers:
		var record: PlayerRecord = _registry.get_record(pid)
		if record != null and record.team.team_id == scoring_team_id:
			return pid
	return -1


# ── Internal ──────────────────────────────────────────────────────────────────

func _confirm(peer_id: int) -> void:
	if _shot_on_goal_counted:
		return
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record == null:
		return
	_shot_on_goal_counted = true
	record.stats.shots_on_goal += 1
	_state_machine.team_shots[record.team.team_id] += 1
	shot_on_goal_recorded.emit(peer_id)
	shots_on_goal_changed.emit(
		_state_machine.team_shots[0], _state_machine.team_shots[1])
