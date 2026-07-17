class_name PhaseCoordinator
extends RefCounted

# Owns all side effects that fire on phase transitions. Pulled out of
# GameManager because the phase-entry flow (puck lock/unlock/reset, goalie
# reset, faceoff teleport, goal scoring) is one coherent piece of game logic
# that reads better in its own file.
#
# Host vs client:
#   - handle_phase_entered()   : host-side, called after GameStateMachine.tick
#                                transitions (puck reset, faceoff, game-over)
#   - on_goal_scored_into()    : host-side, fired by the goal sensor
#   - on_goal_received()       : clients apply the authoritative goal RPC
#   - on_faceoff_positions()   : clients teleport to their new faceoff slot
#
# Collaborators talk back via signals (`phase_changed`, `goal_scored`, etc.)
# and via three injected Callables for puck drop / goal broadcast / faceoff
# broadcast. Nothing in here reaches into NetworkManager directly.

signal goal_scored(scoring_team: Team, scorer_name: String, assist1_name: String, assist2_name: String)
signal score_changed(score_0: int, score_1: int)
signal phase_changed(new_phase: GamePhase.Phase)
signal period_synced(new_period: int)
signal clock_updated(time_remaining: float)
signal game_over
signal stats_need_sync
signal faceoff_positions_ready(positions: Array)  # host → broadcast to clients
# Fires once per faceoff on the side that actually places skaters at the dot:
# the host emits it in _enter_faceoff_prep (alongside faceoff_positions_ready);
# the client emits it from on_faceoff_positions after the reliable RPC lands.
# HUD listens to this for the countdown so the banner appears together with
# the teleport, instead of racing the unreliable phase broadcast.
signal faceoff_prep_announced
signal goal_broadcast_needed(
		scoring_team_id: int, score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String)
signal replay_started
signal replay_stopped
# Fired on the peer that just started a period-break skate-off (host on
# END_OF_PERIOD entry; clients when the WS phase byte lands there). Listeners
# (camera wide hold) get the break length so their treatment spans the window.
signal period_break_started(duration: float)

var _state_machine: GameStateMachine = null
var _registry: PlayerRegistry = null
var _teams: Array[Team] = []
var _puck_getter: Callable = Callable()
var _goalie_controllers_getter: Callable = Callable()
# Returns true when the faceoff being entered is the opening/rematch intro.
# Period starts also skate out from the bench, but ride the separately-armed
# _period_break_pending flag; every other faceoff skates from the player's
# current position. Evaluated at placement time, before the prep-announce flips
# GameManager's _seen_first_prep. Both host (_enter_faceoff_prep) and client
# (on_faceoff_positions) call it. Defaults invalid → no intro.
var _is_pregame_intro_getter: Callable = Callable()
var _shot_tracker: ShotOnGoalTracker = null
# Drops a carried puck (host-only). Returns carrier peer_id or -1.
var _puck_drop_requester: Callable = Callable()
# Tells the host that a player has a pending shot (shot → timer arm).
# Used for the shot-on-goal tracker's `on_shot_started` event from inside the
# goal path; we pass it as a Callable rather than a direct tracker call so
# the caller stays in control of the "is this actually a shot" logic.

# Goal-replay cinematic. GameManager owns the Node lifecycle (add_child /
# queue_free); PhaseCoordinator drives start/stop and wires the signals.
# All three are null in offline / tutorial sessions.
var _recorder: ReplayRecorder = null
var _goal_replay_driver: GoalReplayDriver = null
var _codec: WorldStateCodec = null
var _scene_tree: SceneTree = null
# Host-only callable: captures the goal-moment world-state frame into the
# in-memory recorder immediately on goal detection, filling the up-to-25 ms
# gap since the last broadcast. Clients leave this as Callable() (invalid).
var _force_record_goal_frame: Callable = Callable()

# Captured at goal time on every peer (host via on_goal_scored_into, client via
# on_goal_received) so the driver knows which end to park the inside-net cam
# behind when GOAL_CELEBRATION transitions to GOAL_SCORED and the replay starts.
var _pending_defending_goal_z: float = 0.0

# True on the side that places skaters (host + each client for its own), so
# on_period_break_entered can branch between "drive every controller" and
# "drive only the local skater — remotes interpolate the host's motion".
var _is_host: bool = false

# Armed when END_OF_PERIOD begins (on_period_break_entered, both roles) and
# consumed by the next faceoff placement, which then runs the period-start
# bench intro: skaters skate on from their bench doors under an intro-length
# prep hold, mirroring the opening faceoff. Derived locally on host and client
# from the same replicated phase, so no wire change — the same pattern as the
# intro/staged tests. The pregame intro (a rematch reset during the break)
# overrides and clears it.
var _period_break_pending: bool = false

# The period the active/last break leads into (period-at-break + 1), stashed at
# break entry because a client's replicated current_period doesn't advance
# until the next period's world state lands — the faceoff RPC can beat it.
# GameManager reads this for the "2ND PERIOD" card when
# last_prep_was_period_intro is set.
var period_after_break: int = 0

# Set the moment a goal replay starts (host and client both call start_goal_replay);
# consumed by the next faceoff so post-goal skate-ins stage from behind the dot
# instead of the player's scattered goal-moment position. Setting it at replay
# START (not stop) keeps it independent of signal-connection order, and a replay
# always precedes exactly one post-goal faceoff. Only a replay having played
# arms it, so it triggers exactly when the replay-to-live camera cut exists to
# hide the reposition; period / stoppage faceoffs (no replay) skate from where
# play stopped.
var _staged_faceoff_pending: bool = false

# Cosmetic countdown pre-roll (seconds) the HUD should wait before the "2 → 1 →
# DROP" beat for the faceoff just placed — the skate-in window extension for
# period / stoppage faceoffs, 0 otherwise (the opening intro's pre-roll rides
# its own pregame_intro_started path). Set in _enter_faceoff_prep / on_faceoff_
# positions before faceoff_prep_announced fires; GameManager reads it there and
# relays it to the HUD. Both host and client derive it identically.
var last_prep_preroll: float = 0.0

# True when the faceoff just placed is a period-start bench intro (consumed
# period break). Set alongside last_prep_preroll on both host and client;
# GameManager reads it at announce time to fire period_intro_started (the
# period card + camera sweep) instead of the skate-in countdown hold.
var last_prep_was_period_intro: bool = false

# Host-only scoring log, one entry per goal in scoring order: x = scoring
# team id, y = credited scorer peer id (-1 when nobody could be credited).
# Feeds the game-winning-goal stamp at the final horn; cleared on rematch via
# reset_goal_log(). Stays empty on clients (their goals arrive via
# on_goal_received) — they read the GWG through the replicated stats instead.
var _goal_log: Array[Vector2i] = []


func setup(
		state_machine: GameStateMachine,
		registry: PlayerRegistry,
		teams: Array[Team],
		puck_getter: Callable,
		goalie_controllers_getter: Callable,
		shot_tracker: ShotOnGoalTracker,
		puck_drop_requester: Callable,
		recorder: ReplayRecorder,
		goal_replay_driver: GoalReplayDriver,
		codec: WorldStateCodec,
		scene_tree: SceneTree,
		is_host: bool,
		force_record_goal_frame: Callable,
		is_pregame_intro_getter: Callable = Callable()) -> void:
	_state_machine = state_machine
	_registry = registry
	_teams = teams
	_puck_getter = puck_getter
	_goalie_controllers_getter = goalie_controllers_getter
	_is_pregame_intro_getter = is_pregame_intro_getter
	_shot_tracker = shot_tracker
	_puck_drop_requester = puck_drop_requester
	_recorder = recorder
	_goal_replay_driver = goal_replay_driver
	_codec = codec
	_scene_tree = scene_tree
	_is_host = is_host
	_force_record_goal_frame = force_record_goal_frame
	if _goal_replay_driver != null:
		_goal_replay_driver.replay_started.connect(replay_started.emit)
		_goal_replay_driver.replay_stopped.connect(replay_stopped.emit)
		if is_host:
			_goal_replay_driver.replay_stopped.connect(_on_goal_replay_stopped)


# ── Host: phase transitions ──────────────────────────────────────────────────

func handle_phase_entered() -> void:
	var puck: Puck = _get_puck()
	match _state_machine.current_phase:
		GamePhase.Phase.FACEOFF_PREP:
			if _goal_replay_driver != null:
				_goal_replay_driver.stop()
			period_synced.emit(_state_machine.current_period)
			clock_updated.emit(_state_machine.time_remaining)
			stats_need_sync.emit()
			_enter_faceoff_prep(puck)
		GamePhase.Phase.FACEOFF:
			_enter_faceoff(puck)
		GamePhase.Phase.PLAYING:
			# Transition from FACEOFF timeout — unlock puck.
			if puck != null:
				puck.pickup_locked = false
		GamePhase.Phase.GOAL_SCORED:
			# State machine has auto-advanced from GOAL_CELEBRATION → GOAL_SCORED
			# (host-only transition; clients hit start_goal_replay via WS).
			# This is where the replay cinematic actually kicks in.
			start_goal_replay()
		GamePhase.Phase.END_OF_PERIOD:
			_puck_drop_requester.call()
			if puck != null:
				puck.pickup_locked = true
			clock_updated.emit(0.0)
			on_period_break_entered()
		GamePhase.Phase.GAME_OVER:
			_puck_drop_requester.call()
			if puck != null:
				puck.pickup_locked = true
			clock_updated.emit(0.0)
			_stamp_game_winning_goal()
			game_over.emit()
	# Breadcrumb for host-stall attribution: this is the one host-side hook that
	# fires on every phase transition (goal replay, faceoff, period, game over), so
	# a hitch logged moments after can be traced to the entering phase's handler.
	NetworkTelemetry.note_host_event(GamePhase.Phase.keys()[_state_machine.current_phase])
	phase_changed.emit(_state_machine.current_phase)


func _enter_faceoff_prep(puck: Puck) -> void:
	var dot: Vector2 = _state_machine.active_faceoff_dot
	if puck != null:
		puck.reset(dot)
		puck.pickup_locked = true
	for gc: GoalieController in _goalie_controllers_getter.call():
		gc.reset_to_crease()
	# Skaters skate in to the dot instead of teleport-snapping: from their bench
	# for the opening/rematch intro and for a period start (they just skated off
	# to that bench during the break), else from where play stopped.
	# Deterministic so clients (which interpolate host-driven remotes and run
	# their own local skater's approach) land on the same dot; the drop finds
	# everyone set.
	var is_intro: bool = _is_pregame_intro()
	var period_intro: bool = _consume_period_break(is_intro)
	var staged: bool = _consume_staged_faceoff(is_intro or period_intro)
	var from_bench: bool = is_intro or period_intro
	# Period / stoppage faceoffs (no bench intro, no post-goal replay cut) skate
	# in from where play stopped over a distance-scaled window; extend the prep
	# so a far player isn't forced into a dash, and pre-roll the HUD countdown.
	var skate_in: bool = not from_bench and not staged
	if skate_in:
		_state_machine.set_faceoff_prep_extra(GameRules.FACEOFF_SKATE_PREP_EXTRA)
	elif period_intro:
		# Period-start bench intro: hold the prep like the opening faceoff so
		# the camera sweep + skate-on play out before the countdown.
		_state_machine.set_faceoff_prep_extra(GameRules.PERIOD_INTRO_DURATION)
	last_prep_preroll = GameRules.FACEOFF_SKATE_PREP_EXTRA if skate_in else 0.0
	last_prep_was_period_intro = period_intro
	var positions: Array = []
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		# Centers spawn at their own reach-derived distance from the dot
		# (Size scales stick + arms, so the fixed 1.5 m offset left small
		# builds unable to touch the puck). Wingers ignore the argument.
		var reach: float = -1.0
		if record.team_slot == 0 and record.controller != null:
			reach = record.controller.faceoff_center_distance()
			# Arm the center's swipe capture for the draw (host-only). A swing
			# during the countdown pre-rolls in; the crest feeds the contest.
			if record.skater != null:
				record.skater.begin_draw_tracking(
						record.controller.faceoff_draw_peak_decay,
						record.controller.faceoff_draw_window)
		var pos: Vector3 = PlayerRules.faceoff_position(
				record.team.team_id, record.team_slot, dot, reach)
		var facing: Vector2 = PlayerRules.faceoff_facing(record.team.team_id)
		var start: Vector3 = _approach_start_for(record, pos, dot, from_bench, staged)
		var duration: float = _faceoff_approach_duration(peer_id, start, pos, from_bench, skate_in, staged)
		# Skate-in flows out of live momentum (start == current position); intro /
		# staged relocate to a fresh start, so they snap from rest.
		var v0: Vector3 = record.skater.velocity if skate_in and record.skater != null \
				else Vector3.ZERO
		record.controller.begin_approach(start, pos, facing, duration, v0)
		positions.append_array([peer_id, pos.x, pos.y, pos.z])
	faceoff_positions_ready.emit(positions)
	faceoff_prep_announced.emit()


func _enter_faceoff(puck: Puck) -> void:
	if puck == null:
		return
	puck.pickup_locked = false
	# The drop: stamp it on the centers so the draw's timing bonus is measured from
	# here (see FaceoffDrawRules.timing_weight). The stamp is the shared host clock
	# (== local_time on the host) so a remote center's crest, timed by its own
	# host_timestamp, is judged against the drop in the same base — ping-neutral.
	# The puck is now live and contests resolve within a few hundred ms.
	var drop_host_time: float = NetworkManager.estimated_host_time()
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record.team_slot == 0 and record.skater != null:
			record.skater.mark_draw_drop(drop_host_time)


# Period-break skate-off. Called on END_OF_PERIOD entry — by handle_phase_entered
# on the host, by GameManager's remote-phase handler on clients when the WS phase
# byte lands there. Skates every skater (host) / only the local skater (client —
# remotes interpolate the host's motion) from where play stopped to its bench
# door, over a distance-scaled glide capped so everyone is set at the bench
# PERIOD_BREAK_SETTLE before the break ends, and arms the next faceoff prep as
# the period-start bench intro. Idempotent per break — a duplicate phase echo
# must not restart mid-glide approaches.
func on_period_break_entered() -> void:
	if _period_break_pending:
		return
	_period_break_pending = true
	period_after_break = _state_machine.current_period + 1
	for peer_id: int in _registry.all():
		var record: PlayerRecord = _registry.get_record(peer_id)
		if record == null or record.controller == null or record.skater == null:
			continue
		if not _is_host and not record.is_local:
			continue
		var start: Vector3 = record.skater.global_position
		var target: Vector3 = PlayerRules.bench_start_position(
				record.team.team_id, record.team_slot)
		var dist: float = Vector2(start.x - target.x, start.z - target.z).length()
		var duration: float = PlayerRules.skate_in_duration(
				dist, GameRules.FACEOFF_APPROACH_DURATION,
				GameRules.INTERMISSION_DURATION - GameRules.PERIOD_BREAK_SETTLE)
		# Settle facing +X: squared up to the bench boards, as if stepping off.
		# Live velocity flows the glide out of end-of-period momentum, exactly
		# like a stoppage skate-in.
		record.controller.begin_approach(
				start, target, Vector2(1.0, 0.0), duration, record.skater.velocity)
	period_break_started.emit(GameRules.INTERMISSION_DURATION)


func on_pickup(_peer_id: int) -> void:
	if _state_machine.on_faceoff_puck_picked_up():
		phase_changed.emit(_state_machine.current_phase)


# A non-pickup puck engagement during FACEOFF (deflect / body redirect /
# one-timer) — ends the faceoff so a goal off the play is not voided.
func on_puck_touched_live() -> void:
	if _state_machine.on_faceoff_puck_touched():
		phase_changed.emit(_state_machine.current_phase)


# ── Host: goal scoring pipeline ──────────────────────────────────────────────

func on_goal_scored_into(defending_team: Team) -> void:
	# Scripted drills own the post-goal flow — running the state machine through
	# GOAL_CELEBRATION + faceoff prep would derail the lesson / drill. The drill
	# managers watch puck position directly to detect goals.
	if NetworkManager.is_drill_mode():
		return
	var carrier_peer_id: int = _puck_drop_requester.call()
	var scoring_team_id: int = _state_machine.on_goal_scored(defending_team.team_id)
	if scoring_team_id == -1:
		return  # wrong phase, ignored

	var scorer_name: String = ""
	var assist1_name: String = ""
	var assist2_name: String = ""
	var raw_scorer_id: int = carrier_peer_id if carrier_peer_id != -1 \
			else _shot_tracker.get_last_toucher()
	var is_own_goal: bool = _is_own_goal(raw_scorer_id, defending_team.team_id)
	var scorer_id: int = raw_scorer_id
	if is_own_goal:
		scorer_id = _shot_tracker.find_scorer_on_team(scoring_team_id)

	if scorer_id != -1:
		var record: PlayerRecord = _registry.get_record(scorer_id)
		if record != null:
			record.stats.goals += 1
			# Overtime winner: any non-own goal in sudden-death OT wins the game.
			if not is_own_goal and _state_machine.is_overtime():
				record.stats.ot_goals += 1
			# Tag one-timer / tip goal flavor BEFORE clear_pending() below wipes
			# the shot-tracker state these reads depend on.
			_tag_goal_flavor(record, scorer_id, carrier_peer_id, is_own_goal)
			var assist_names: Array[String] = _shot_tracker.credit_assists(scorer_id)
			assist1_name = assist_names[0] if assist_names.size() > 0 else ""
			assist2_name = assist_names[1] if assist_names.size() > 1 else ""
			if not is_own_goal:
				_shot_tracker.on_goal_confirmed(scorer_id)
			scorer_name = record.display_name()
	_goal_log.append(Vector2i(scoring_team_id, scorer_id))
	_shot_tracker.clear_pending()
	stats_need_sync.emit()

	var puck: Puck = _get_puck()
	if puck != null:
		puck.pickup_locked = true
	if defending_team.defended_goal != null:
		_pending_defending_goal_z = defending_team.defended_goal.goal_line_z()
		if defending_team.defended_goal.vfx != null:
			defending_team.defended_goal.vfx.celebrate()
	goal_scored.emit(_teams[scoring_team_id], scorer_name, assist1_name, assist2_name)
	score_changed.emit(_state_machine.scores[0], _state_machine.scores[1])
	phase_changed.emit(_state_machine.current_phase)
	goal_broadcast_needed.emit(
			scoring_team_id, _state_machine.scores[0], _state_machine.scores[1],
			scorer_name, assist1_name, assist2_name)
	_capture_goal_moment_frame()


# Host: stamp the scoring goal's "flavor" counters (one_timer_goals / tip_goals)
# on the scorer. These are broadcast like the other stat counters (via the
# stats_need_sync above), so a client scorer's own copy carries them into the
# game-over achievement sweep. Own goals carry no flavor. Reads the shot-tracker
# state, so the caller MUST invoke this before clear_pending().
#   one-timer — the scorer released the shot themselves as a one-timer.
#   tip-in    — the scorer was the last, deflecting toucher of a teammate's
#               in-flight shot (nobody carried it in).
func _tag_goal_flavor(scorer: PlayerRecord, scorer_id: int,
		carrier_peer_id: int, is_own_goal: bool) -> void:
	if is_own_goal or scorer == null or scorer.team == null:
		return
	if not _shot_tracker.has_pending_shot():
		return
	var shooter_id: int = _shot_tracker.get_shooter_peer_id()
	if shooter_id == scorer_id:
		if _shot_tracker.pending_is_one_timer():
			scorer.stats.one_timer_goals += 1
		return
	# Shooter differs from the scorer → a redirect. A tip-in requires the puck to
	# have gone in off the deflection (no carrier drove it in) and the shooter to
	# be a teammate feeding it — an opposing shot deflected in is an own goal path.
	if carrier_peer_id != -1:
		return
	var shooter: PlayerRecord = _registry.get_record(shooter_id)
	if shooter == null or shooter.team == null:
		return
	if shooter.team.team_id == scorer.team.team_id:
		scorer.stats.tip_goals += 1


# Host, final horn: stamp game_winning_goals on the scorer of the goal that
# put the winner past the loser's final total (the NHL GWG definition). It
# rides the ordinary stats broadcast (stats_need_sync) so every peer's Three
# Stars math reads the same counters. A draw stamps nobody, and so does an
# uncredited goal (own goal with no attributable scorer) at the pivotal slot.
func _stamp_game_winning_goal() -> void:
	var score0: int = _state_machine.scores[0]
	var score1: int = _state_machine.scores[1]
	if score0 == score1:
		return
	var winning_team: int = 0 if score0 > score1 else 1
	var gwg_idx: int = StarOfGameRules.game_winning_goal_index(
			maxi(score0, score1), mini(score0, score1))
	var seen: int = 0
	for goal: Vector2i in _goal_log:
		if goal.x != winning_team:
			continue
		if seen == gwg_idx:
			var record: PlayerRecord = _registry.get_record(goal.y)
			if record != null:
				record.stats.game_winning_goals = 1
				stats_need_sync.emit()
			return
		seen += 1


# Rematch reset: a fresh match must not inherit the previous game's scoring
# log (the stat counters themselves reset via PlayerRegistry.reset_all_stats).
func reset_goal_log() -> void:
	_goal_log.clear()


func _is_own_goal(raw_scorer_id: int, defending_team_id: int) -> bool:
	if raw_scorer_id == -1:
		return false
	var record: PlayerRecord = _registry.get_record(raw_scorer_id)
	return record != null and record.team.team_id == defending_team_id


# ── Clients: receive authoritative events ────────────────────────────────────

func on_goal_received(
		scoring_team_id: int,
		score0: int, score1: int,
		scorer_name: String, assist1_name: String, assist2_name: String) -> void:
	_state_machine.apply_remote_goal(scoring_team_id, score0, score1)
	var puck: Puck = _get_puck()
	if puck != null:
		puck.pickup_locked = true
	goal_scored.emit(_teams[scoring_team_id], scorer_name, assist1_name, assist2_name)
	var defended_goal: HockeyGoal = _teams[1 - scoring_team_id].defended_goal
	if defended_goal != null:
		_pending_defending_goal_z = defended_goal.goal_line_z()
		if defended_goal.vfx != null:
			defended_goal.vfx.celebrate()
	score_changed.emit(_state_machine.scores[0], _state_machine.scores[1])
	phase_changed.emit(_state_machine.current_phase)
	_capture_goal_moment_frame()


func on_faceoff_positions(positions: Array) -> void:
	var local_peer_id: int = _registry.get_local().peer_id if _registry.get_local() != null else -1
	# Remote skaters skate in via interpolation of the host's approach motion; the
	# client only drives its OWN skater's skate-in locally. Same intro / period /
	# staged tests as the host (all derived deterministically), so the local
	# player's start matches the host's view of it for the opening, period-start,
	# and post-goal faceoffs.
	var is_intro: bool = _is_pregame_intro()
	var period_intro: bool = _consume_period_break(is_intro)
	var staged: bool = _consume_staged_faceoff(is_intro or period_intro)
	var from_bench: bool = is_intro or period_intro
	var skate_in: bool = not from_bench and not staged
	# The host owns the drop timer; the client only needs the same pre-roll for
	# its cosmetic countdown (derived from the same fixed extra, so it matches).
	last_prep_preroll = GameRules.FACEOFF_SKATE_PREP_EXTRA if skate_in else 0.0
	last_prep_was_period_intro = period_intro
	var i: int = 0
	while i < positions.size():
		var peer_id: int = positions[i]
		var pos := Vector3(positions[i + 1], positions[i + 2], positions[i + 3])
		i += 4
		if peer_id == local_peer_id and _registry.has(peer_id):
			# Wire format stays position-only; clients derive facing locally
			# from the record's current team_id. Slot-swap RPCs land before
			# the faceoff broadcast, so record.team here is already the new
			# team after a mid-game switch.
			var record: PlayerRecord = _registry.get_record(peer_id)
			var facing: Vector2 = PlayerRules.faceoff_facing(record.team.team_id)
			# Staged faceoffs are always post-goal at center ice, so the dot the
			# radial staging is measured from is CENTER_ICE_DOT (unused otherwise).
			var start: Vector3 = _approach_start_for(
					record, pos, GameRules.CENTER_ICE_DOT, from_bench, staged)
			var duration: float = _faceoff_approach_duration(
					peer_id, start, pos, from_bench, skate_in, staged)
			var v0: Vector3 = record.skater.velocity if skate_in and record.skater != null \
					else Vector3.ZERO
			record.controller.begin_approach(start, pos, facing, duration, v0)
	# Drive the client's phase entry off this reliable RPC rather than leaving
	# it to the unreliable world-state phase byte — see apply_remote_faceoff_prep.
	if _state_machine != null and _state_machine.apply_remote_faceoff_prep():
		phase_changed.emit(_state_machine.current_phase)
	faceoff_prep_announced.emit()


# ── Internal ──────────────────────────────────────────────────────────────────

# True when the faceoff being placed is the opening/rematch intro — the only
# one skaters skate out from their benches for.
func _is_pregame_intro() -> bool:
	return _is_pregame_intro_getter.is_valid() and bool(_is_pregame_intro_getter.call())


# Reads and clears the post-goal staged-faceoff flag. A bench start (pregame or
# period intro) overrides it and clears any stale flag left by an OT-winning
# goal whose replay never led to a faceoff.
func _consume_staged_faceoff(overridden: bool) -> bool:
	var staged: bool = _staged_faceoff_pending and not overridden
	_staged_faceoff_pending = false
	return staged


# Reads and clears the period-break flag armed by on_period_break_entered. The
# pregame intro overrides it (a rematch reset mid-break restarts the match — the
# opening bench intro wins) and clears the stale arm either way.
func _consume_period_break(is_intro: bool) -> bool:
	var period_intro: bool = _period_break_pending and not is_intro
	_period_break_pending = false
	return period_intro


# Skate-in start point for a skater's approach to `target` (its faceoff dot):
#   - from_bench (opening/rematch intro or period start) → the team's bench
#                             door (long cinematic skate-out).
#   - post-goal (staged)    → a fixed short setback behind the dot; the replay's
#                             camera cut hides the jump here, so the skate is a
#                             short, consistent glide regardless of the goal.
#   - otherwise             → the skater's current position (skate from where
#                             play stopped — stoppage faceoffs).
func _approach_start_for(record: PlayerRecord, target: Vector3, dot_xz: Vector2,
		from_bench: bool, staged: bool) -> Vector3:
	if from_bench:
		return PlayerRules.bench_start_position(record.team.team_id, record.team_slot)
	if staged:
		return PlayerRules.faceoff_staging_position(target, dot_xz, record.team.team_id)
	if record.skater != null:
		return record.skater.global_position
	return PlayerRules.faceoff_staging_position(target, dot_xz, record.team.team_id)


func _approach_duration(from_bench: bool) -> float:
	return GameRules.INTRO_APPROACH_DURATION if from_bench else GameRules.FACEOFF_APPROACH_DURATION


# Glide time for one skater's approach:
#   - skate_in (stoppage)          → distance-scaled from current position.
#   - staged (post-goal)           → base faceoff duration ± a deterministic
#                                     per-player stagger so the fan doesn't arrive
#                                     in lockstep (seeded by peer + goals so far).
#   - otherwise (bench / default)  → the fixed intro / faceoff duration.
func _faceoff_approach_duration(peer_id: int, start: Vector3, target: Vector3,
		from_bench: bool, skate_in: bool, staged: bool) -> float:
	if skate_in:
		return _skate_in_duration(start, target)
	if staged:
		var goals: int = _state_machine.scores[0] + _state_machine.scores[1]
		var frac: float = PlayerRules.stagger01(peer_id, goals)  # [0, 1)
		var mult: float = 1.0 + (frac * 2.0 - 1.0) * GameRules.FACEOFF_STAGGER_FRACTION
		return GameRules.FACEOFF_APPROACH_DURATION * mult
	return _approach_duration(from_bench)


# Distance-scaled glide time for a stoppage skate-in: the planar start→
# dot distance at the target skate pace, floored at the base faceoff duration and
# capped so the skater is set FACEOFF_SKATE_SETTLE before the drop (the extended
# window's skate room). Everyone thus arrives before the puck drops.
func _skate_in_duration(start: Vector3, target: Vector3) -> float:
	var dist: float = Vector2(start.x - target.x, start.z - target.z).length()
	var max_dur: float = GameRules.FACEOFF_PREP_DURATION \
			+ GameRules.FACEOFF_SKATE_PREP_EXTRA - GameRules.FACEOFF_SKATE_SETTLE
	return PlayerRules.skate_in_duration(dist, GameRules.FACEOFF_APPROACH_DURATION, max_dur)


func _get_puck() -> Puck:
	if not _puck_getter.is_valid():
		return null
	return _puck_getter.call() as Puck


# ── Goal replay cinematic ─────────────────────────────────────────────────────

# Null _state_machine so _on_goal_replay_stopped's guard catches any late
# replay_stopped signal that fires during scene teardown.
func cleanup() -> void:
	_state_machine = null


# Capture the goal-moment world state directly into the recorder, in addition
# to whatever the normal broadcast loop captures. Without this, the latest
# frame in the ring buffer might be up to 25 ms (one WS broadcast period)
# before the puck crossed the line, so the replay's final frame would miss
# the actual puck-in-net moment.
func _capture_goal_moment_frame() -> void:
	if _recorder == null or _goal_replay_driver == null or _codec == null:
		return
	if _force_record_goal_frame.is_valid():
		_force_record_goal_frame.call()


# Kick off the cinematic. Called from handle_phase_entered (host) when the
# state machine transitions GOAL_CELEBRATION → GOAL_SCORED, and from GameManager.
# _on_remote_phase_changed (clients) when the same transition arrives via WS.
# No-op if already running (driver guards against double-start).
func start_goal_replay() -> void:
	if _recorder == null or _goal_replay_driver == null or _codec == null:
		return
	# Arm the post-goal staged skate-in: the replay's camera cut will hide the
	# jump to a staging point near the dot so the ensuing faceoff is a short skate.
	_staged_faceoff_pending = true
	_goal_replay_driver.start(_recorder, _codec, _registry,
			_puck_getter.call() as Puck, _goalie_controllers_getter.call(),
			_pending_defending_goal_z)


# Host-only: advance state machine once the cinematic finishes naturally.
func _on_goal_replay_stopped() -> void:
	if _state_machine == null or _state_machine.current_phase != GamePhase.Phase.GOAL_SCORED:
		return
	_state_machine.advance_post_goal()
	handle_phase_entered()
