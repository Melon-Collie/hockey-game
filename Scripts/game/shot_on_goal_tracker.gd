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
#   on_poke_check(peer_id)          → records the poke-checker as the last toucher
#                                     (so a puck poked into the net is the poker's
#                                     goal, and a poke that feeds a scoring teammate
#                                     earns the poker an assist — a defensive strip
#                                     that sets up the goal is a play, NHL-style)
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
# Fires on every shot RELEASE (armed pending shot), carrying the shooter —
# before it's known whether the shot is on goal. TurnoverTracker uses it so
# recovering ANY shot (saved, missed wide, blocked) reads as a rebound rather
# than a giveaway/takeaway; shot_on_goal_recorded then refreshes the window at
# the save so a rebound stays covered past the shot's flight time.
signal shot_attempted(peer_id: int)
# Fires once per resolved shot ATTEMPT (Corsi), carrying the full ShotEvent
# (credited shooter — tipper on a tip; outcome; release position; xG; type;
# period/clock). A "shot attempt" is a puck DIRECTED AT THE NET that resolves as
# on-goal, missed, or blocked — NOT a pass. AdvancedStatsTracker derives the
# Corsi/Fenwick/xGF counters from it AND buffers it for the shot map / xG-flow /
# heatmap. Unlike a release, this is the pass-filtered event: passes (off-net, or
# received by a teammate) never emit it.
signal shot_resolved(event: ShotEvent)

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
# scramble attach). The possession flag drives the NHL assist chain — opposing
# ESTABLISHED possession breaks it, an opposing touch doesn't. A pickup starts
# as a touch and upgrades via on_possession_established.
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
# Whether the pending shot is DIRECTED AT THE NET (the wider Corsi/Fenwick mouth,
# ShotOnNetRules.is_directed_at_net) — the shot-vs-pass gate for a MISS. Armed
# true at release (assume a shot until the trajectory read says otherwise), kept
# current by note_directed_at_net, and forced true on a post (a post is a directed
# miss). A puck NOT directed at net that clears is a pass/clear, not a Corsi miss.
var _pending_directed_at_net: bool = false
# The pending shot's expected-goals value (AIActionScoring.expected_goals),
# evaluated by the caller at release from the real goalie geometry and carried on
# the resolved ShotEvent. Set via note_xg; 0 until then.
var _pending_xg: float = 0.0
# The pending shot's release position (rink coordinates), set by the caller at
# release for the shot map. Set via note_shot_origin.
var _pending_origin: Vector3 = Vector3.ZERO
# Whether the pending shot was released as a one-timer (wind-up off the puck,
# fired the instant it entered the shooting zone). Read at goal time for the
# One-Timer achievement's goal-flavor tag. Set by on_shot_started, cleared with
# the rest of the pending state.
var _pending_one_timer: bool = false

var _registry: PlayerRegistry = null
var _state_machine: GameStateMachine = null


func setup(registry: PlayerRegistry, state_machine: GameStateMachine) -> void:
	_registry = registry
	_state_machine = state_machine


# ── Events ────────────────────────────────────────────────────────────────────

func on_pickup(peer_id: int) -> void:
	# Resolve the pending shot BEFORE clearing: a directed shot the picker didn't
	# receive as a teammate is a missed-shot attempt (Corsi); a teammate receiving
	# it (backdoor feed / saucer) is a pass, not a shot. _resolve_pending_miss
	# reads the picker's team, so it must see it before the clear.
	_resolve_pending_miss(peer_id)
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
	# Rebound re-shot: the pending shot was already SAVED and counted, and now an
	# ATTACKING player redirects the loose puck. That's a fresh shot attempt — the
	# prior save's SOG already landed, so re-arm a new pending shot (this player as
	# shooter) and let the next save, or a tap-in goal, count its own SOG. The
	# caller re-reads the trajectory right after, so _pending_on_net self-corrects.
	# Repeated goalie contact on the same rebound with no attacking touch between
	# never re-arms, so it stays one SOG. A first tip of a still-live (not yet
	# counted) shot is untouched here — keeping that pending shot alive is correct.
	if _shot_on_goal_counted and _shooter_peer_id != -1 and _registry != null \
			and _registry.resolve_team_id_for_peer(peer_id) \
				== _registry.resolve_team_id_for_peer(_shooter_peer_id):
		_shooter_peer_id = peer_id
		_pending_remaining = SHOT_ON_GOAL_TIMEOUT
		_block_window_remaining = -1.0
		_shot_on_goal_counted = false
		_pending_one_timer = false
		_pending_on_net = true
		_pending_directed_at_net = true  # re-armed shot; note_directed_at_net corrects
		_pending_xg = 0.0                # re-armed shot; note_xg re-reads its geometry
		_pending_origin = Vector3.ZERO   # re-armed shot; note_shot_origin re-reads
	_record_toucher(peer_id, false)


# A defender poke-checked the carrier. Record them as the most recent toucher
# so a puck poked directly off the carrier's stick into the net is attributed
# to the poker (get_last_toucher), and — since a poke that goes to a teammate is
# a play that sets up the goal — so the poker is assist-eligible in the chain
# like any other toucher. The opposing carrier they stripped still breaks the
# chain (their entry carries ESTABLISHED possession), so credit walks no further
# back than the strip.
func on_poke_check(peer_id: int) -> void:
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
# `is_one_timer` tags a wind-up-off-puck slapper release so a goal off it can be
# attributed to the One-Timer achievement (read via pending_is_one_timer).
func on_shot_started(shooter_peer_id: int, is_one_timer: bool = false) -> void:
	if shooter_peer_id == -1:
		return
	_shooter_peer_id = shooter_peer_id
	_pending_remaining = SHOT_ON_GOAL_TIMEOUT
	_block_window_remaining = BLOCK_WINDOW
	_shot_on_goal_counted = false
	_pending_one_timer = is_one_timer
	# Assume on net until the caller's ballistic read (note_trajectory, run
	# right after the authoritative release) says otherwise — a missed read
	# should over-credit, not swallow saves.
	_pending_on_net = true
	# Assume directed at net too (a shot until the trajectory read says pass); this
	# gates whether a MISS counts as a Corsi attempt. A release that supersedes an
	# uncounted pending shot (a one-timer over a feed) overwrites it without
	# resolving — the superseded feed never emits shot_counted, so it stays a pass.
	_pending_directed_at_net = true
	# A shot went off — mark the turnover shot window so a recovery of it reads as
	# a rebound (not a turnover), whether or not it turns out to be on goal.
	shot_attempted.emit(shooter_peer_id)


# Updates the pending shot's on-net read (computed by the caller from the live
# puck trajectory — ShotOnNetRules). Called after the authoritative release and
# again after every mid-flight deflection, so a wide shot tipped on net (or an
# on-net shot tipped wide) re-reads correctly. No-op without a pending shot.
func note_trajectory(on_net: bool) -> void:
	if _shooter_peer_id == -1:
		return
	_pending_on_net = on_net


# Updates the pending shot's directed-at-net read (the wider Corsi/Fenwick mouth,
# ShotOnNetRules.is_directed_at_net), computed by the caller alongside
# note_trajectory. Distinguishes a shot that misses (still directed → counts) from
# a pass/clear (not directed → never a Corsi miss). No-op without a pending shot.
func note_directed_at_net(directed: bool) -> void:
	if _shooter_peer_id == -1:
		return
	_pending_directed_at_net = directed


# Records the pending shot's expected-goals value (computed by the caller at
# release from the real goalie geometry — AIActionScoring.expected_goals). Carried
# on shot_counted at resolution. No-op without a pending shot.
func note_xg(xg: float) -> void:
	if _shooter_peer_id == -1:
		return
	_pending_xg = xg


# Records the pending shot's release position (rink coordinates) for the shot map.
# No-op without a pending shot.
func note_shot_origin(origin: Vector3) -> void:
	if _shooter_peer_id == -1:
		return
	_pending_origin = origin


# A shot off the pipes is a MISS in NHL scoring — it was never "on goal", so a
# goalie touch on the ricochet must not confirm a SOG. The pending shot stays
# alive for goal attribution: a carom that still crosses the line counts via
# on_goal_confirmed, which credits unconditionally.
func on_post_hit() -> void:
	if _shooter_peer_id == -1:
		return
	_pending_on_net = false
	# A post is by definition a shot directed at the net that just missed in — so
	# it stays a Corsi/Fenwick miss even though it's no longer on net.
	_pending_directed_at_net = true


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
	# Corsi/Fenwick: a blocked shot is an attempt (Corsi) but not unblocked
	# (excluded from Fenwick). on_block already requires _pending_on_net, so it was
	# directed at net. Attribute to the shooter; emit before clear_pending() zeroes
	# _shooter_peer_id, and mark counted so the trailing clear resolves no miss.
	_shot_on_goal_counted = true
	# Blocked: attributed to the shooter, on-net (on_block required it). The event
	# keeps the real xG (for the map); the xGF counter excludes blocked shots.
	shot_resolved.emit(_build_event(_shooter_peer_id, ShotEvent.Outcome.BLOCKED))
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
# v1 edge: a goal the goalie grazed first logged its ShotEvent as SAVED via
# on_goalie_touch (the dedup guard blocks the GOAL re-label); a clean goal (no
# goalie touch) logs GOAL here. Minor shot-map mislabel, acceptable.
func on_goal_confirmed(scorer_peer_id: int) -> void:
	_confirm(scorer_peer_id, ShotEvent.Outcome.GOAL)


# Returns up to 2 assist names for same-team recent carriers preceding scorer.
# Mutates PlayerStats.assists on each credited player. NHL chain rule: an
# opposing ESTABLISHED possession breaks the chain, but a mere opposing touch
# (a pass deflecting off a defender's blade or body, or a momentary attach in
# a goal-mouth scramble) does not — the player who sent the puck in still
# earns the assist when no opponent ever controlled it. A poke-check that feeds
# a teammate counts as such a play: the poker sits in the chain like any other
# toucher, and the opposing carrier they stripped breaks it a step further back.
func credit_assists(scorer_peer_id: int) -> Array[String]:
	var names: Array[String] = []
	var credited: Array[int] = []
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
		if pid in credited:
			continue  # already credited: a teammate touching twice earns one assist
		record.stats.assists += 1
		credited.append(pid)
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
		# Timed out with nobody recovering it — a directed shot that missed wide
		# (no teammate reception) is a Corsi/Fenwick miss; a stray pass isn't.
		_resolve_pending_miss(-1)
		clear_pending()


# ── Accessors ─────────────────────────────────────────────────────────────────

func get_shooter_peer_id() -> int:
	return _shooter_peer_id

# Returns the most recent player to touch the puck (carrier or deflector), or -1.
func get_last_toucher() -> int:
	return _recent_carriers[0] if not _recent_carriers.is_empty() else -1


func has_pending_shot() -> bool:
	return _shooter_peer_id != -1


# Whether the live pending shot was a one-timer. False without a pending shot.
func pending_is_one_timer() -> bool:
	return _shooter_peer_id != -1 and _pending_one_timer


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func clear_pending() -> void:
	_shooter_peer_id = -1
	_pending_remaining = -1.0
	_block_window_remaining = -1.0
	_shot_on_goal_counted = false
	_pending_on_net = false
	_pending_directed_at_net = false
	_pending_xg = 0.0
	_pending_origin = Vector3.ZERO
	_pending_one_timer = false


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

func _confirm(peer_id: int, outcome: int = ShotEvent.Outcome.SAVED) -> void:
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
	# A shot on goal is a Corsi/Fenwick attempt (unblocked). Outcome distinguishes
	# a save from a goal for the shot map.
	shot_resolved.emit(_build_event(peer_id, outcome))


# Resolves a still-pending shot into a MISS (Corsi/Fenwick) or a pass (nothing)
# when it clears without being counted as on-goal or blocked. A miss requires the
# shot to have been DIRECTED AT NET (else it was a pass/clear into space) and to
# NOT have been received by a teammate (a backdoor feed / saucer the target
# collected is a pass, not a shot). `picker_peer_id` is the recovering player
# (-1 on a timeout, where nobody recovered it). Credits the last attacking toucher
# (the tipper on a tip, else the shooter), matching on-goal attribution.
func _resolve_pending_miss(picker_peer_id: int) -> void:
	if _shooter_peer_id == -1 or _shot_on_goal_counted:
		return  # no pending shot, or already counted as on-goal / blocked
	if not _pending_directed_at_net:
		return  # not aimed at the net — a pass or a clear, not a shot
	if picker_peer_id != -1 and picker_peer_id != _shooter_peer_id \
			and _same_team(picker_peer_id, _shooter_peer_id):
		return  # a DIFFERENT teammate received it → completed pass, not a shot
		# (the shooter recovering their own wide shot is still a missed shot)
	_shot_on_goal_counted = true  # guard against a re-emit before clear_pending
	shot_resolved.emit(_build_event(_credit_peer(), ShotEvent.Outcome.MISSED))


# The peer a resolved shot is attributed to: the last attacking toucher (a
# same-team tipper) if there is one, else the shooter. Mirrors on_goalie_touch.
func _credit_peer() -> int:
	var last: int = get_last_toucher()
	if last != -1 and last != _shooter_peer_id and _same_team(last, _shooter_peer_id):
		return last
	return _shooter_peer_id


func _same_team(a: int, b: int) -> bool:
	if _registry == null:
		return false
	var ta: int = _registry.resolve_team_id_for_peer(a)
	return ta != -1 and ta == _registry.resolve_team_id_for_peer(b)


# Assembles the ShotEvent for a resolved shot: the credited shooter's team, the
# release geometry (position + xG), the outcome, and the shot type. Type is what
# the tracker knows for free — a one-timer (the pending flag), else a redirect
# when the credited peer differs from the original shooter (a tip), else a plain
# shot. Period/clock come from the state machine.
func _build_event(credit_peer: int, outcome: int) -> ShotEvent:
	var shot_type: int = ShotEvent.ShotType.SHOT
	if _pending_one_timer:
		shot_type = ShotEvent.ShotType.ONE_TIMER
	elif credit_peer != _shooter_peer_id:
		shot_type = ShotEvent.ShotType.TIP
	var period: int = _state_machine.current_period if _state_machine != null else 1
	var clock_s: float = _state_machine.time_remaining if _state_machine != null else 0.0
	return ShotEvent.make(
			credit_peer, _registry.resolve_team_id_for_peer(credit_peer),
			_pending_origin, _pending_xg, outcome, shot_type,
			_pending_on_net, period, clock_s)
