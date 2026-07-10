class_name AIController
extends SkaterController

const _PhysicsConstants: GDScript = preload("res://Scripts/game/constants.gd")

# Bots synthesize inputs (no real mouse) — keep them on the blade-speed × distance
# wrister model regardless of the pure-mouse-speed experiment flag.
func is_ai_controlled() -> bool:
	return true

# Host-only controller for AI bots. Owns one SkaterAgent and forwards its
# per-tick InputState to SkaterController._process_input. Clients see the
# bot through the existing SkaterNetworkState broadcast (no input
# replication path — LocalController.get_input_batch is the human path).
#
# Reads a tick-delayed WorldSnapshot from GameManager.get_state_at, which
# forwards to StateBufferManager. We don't keep a separate AI perception
# buffer — the lag-comp ring is already capturing the same data.

var _agent: SkaterAgent = null
# Cached most-recent snapshot read this tick. Public for debug inspection.
var perceived_snapshot: WorldSnapshot = null


# Bots never set deliberate-deflect intent. The agent holds the shoot button
# off-puck to wind up wrister one-timers (SkaterAgentStateMachine._state_one_timer_pressed),
# expecting to CATCH the incoming puck and fire — routing that into a deflect
# would break it. Deliberate deflection is a human-only mechanic in v1.
func _wants_deflect(_input: InputState) -> bool:
	return false

# Scratch InputState reused every FACEOFF_PREP tick so we don't allocate per
# frame. All flags default to false; we only overwrite mouse_world_pos / time
# / delta. Lifetime is the controller — bots aren't re-allocated mid-match.
var _faceoff_input: InputState = InputState.new()

# Bot draw swing. A center bot loads its blade on the dot through the countdown,
# then in the final bot_draw_swing_time before the drop yanks the blade-aim target
# back toward its own zone by bot_draw_pull_distance. The blade IK saturates at
# max_blade_speed chasing that yank, so the crest is a real draw sweep (Hands sets
# how hard) that the draw buffer retains into the live contest — instead of the
# old "hold the blade on the puck" that produced a zero-momentum coin-flip. Timed
# to crest just before the drop (bots are movement-locked until then and can't
# react on the drop like a human), so a well-timed human still out-draws a bot.
@export var bot_draw_swing_time: float = 0.18   # s before the drop the rip fires
@export var bot_draw_windup_distance: float = 0.3  # m the blade loads on the far side of the puck
@export var bot_draw_pull_distance: float = 0.6  # m past the dot the rip follows through
@export var bot_draw_lateral_bias: float = 0.7   # angle off straight-back toward the backhand winger

# ── Scripted mode ─────────────────────────────────────────────────────────────
# When set_scripted_mode(true) is called the agent is bypassed entirely and
# the controller synthesizes its own InputState from script_* commands. Used
# by the tutorial to puppet bots ("move to X", "hold", "aim at Y", "fire").
# Caller is responsible for excluding the bot from TeamBrain role assignment
# (see TeamBrain.exclude_skater) so other bots don't try to play around it.
var scripted_mode: bool = false
var _script_input: InputState = InputState.new()
var _script_target_xz: Vector2 = Vector2.INF
var _script_aim: Vector3 = Vector3.INF
var _script_hold: bool = true
const _SCRIPT_ARRIVAL_RADIUS_M: float = 0.5
# Charge ticks: the scripted wrister holds a STATIC aim while "charging"
# (no cursor sweep → no charge accumulates), so it releases as a min-power
# wrister regardless of this window — the ticks only set a readable wind-up
# pause for tutorial demos. Deliberately longer than the bot SM's
# BOT_WRISTER_CHARGE_TICKS (~67 ms), which is a real charge sweep.
const _SCRIPT_WRIST_CHARGE_TICKS: int = _PhysicsConstants.PHYSICS_TICK / 4       # 250 ms
const _SCRIPT_SLAP_CHARGE_TICKS: int = _PhysicsConstants.PHYSICS_TICK * 3 / 8    # 375 ms
# Shot mini-state-machine: 0 idle, 1 press-edge, 2 charging, 3 release-pending.
var _script_shot_kind: String = ""   # "", "wrist", "slap", "quick"
var _script_shot_phase: int = 0
var _script_shot_ticks: int = 0

# Debug: floating label above each bot showing the bot's per-tick
# decision breakdown. Refreshes only when the rendered text actually
# changes (commit flip, winner flip, score moves enough to re-format)
# so it doesn't flicker on every wobble. Toggle to false to disable
# for shipping.
const SHOW_DEBUG_LABEL: bool = false
const DEBUG_LABEL_HEIGHT_M: float = 2.4    # above the head
var _debug_label: Label3D = null
var _debug_last_text: String = ""

# Reaction delay was 0.1s in the original design but reading delayed-past
# from StateBufferManager logged "ts predates oldest" warnings whenever the
# buffer hadn't filled (post-rehost, post-faceoff, etc.) — for Phase 4 we
# read the freshest captured state. A future phase can re-introduce delay
# via clamping the requested ts to the buffer's oldest entry.


func setup(assigned_skater: Skater, assigned_puck: Puck, game_state: Node) -> void:
	super.setup(assigned_skater, assigned_puck, game_state)
	_agent = SkaterAgent.new()


# Push the bot's attribute-scaled capabilities into the agent so the AI plans
# with the same numbers the controller drives the body with — top speed, thrust,
# blade reach, shot / pass speed — instead of league defaults. Called on every
# attribute apply (initial spawn + free-play picker changes) so the agent never
# sees stale values. The base controller has already written the scaled values
# to its own fields by the time super() returns; we just read them off.
func apply_attributes(attrs: PlayerAttributes) -> void:
	super.apply_attributes(attrs)
	if _agent == null:
		return
	# Push this bot's own scaled capabilities into the agent (the same struct the
	# registry memoizes per-peer for cross-player modeling). super() has already
	# written the scaled fields build_ai_caps reads.
	_agent.apply_capabilities(build_ai_caps())


# Bots are spawned by PlayerRegistry.spawn_bot, which knows the bot's
# peer_id and team_id but not the controller — so the registry calls this
# after spawn to wire the agent. Separate from setup() because setup() is
# called by ActorSpawner before the registry knows which slot it belongs to.
func setup_agent(peer_id: int, team_id: int, brain: TeamBrain, team_id_by_peer: Dictionary,
		is_left_handed: bool, profile: BotSkillProfile = null, caps_by_peer: Dictionary = {}) -> void:
	if _agent != null:
		_agent.setup(peer_id, team_id, brain, team_id_by_peer, is_left_handed, caps_by_peer)
		# Difficulty knobs (mouse slew / lerp / dispatch cadence). Null leaves
		# the perfect-bot defaults. Perception delay is applied globally by
		# GameManager, not here.
		_agent.apply_profile(profile)
	if SHOW_DEBUG_LABEL and skater != null:
		_debug_label = Label3D.new()
		_debug_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_debug_label.no_depth_test = true
		_debug_label.fixed_size = true
		_debug_label.pixel_size = 0.001
		_debug_label.outline_size = 2
		_debug_label.font_size = 24
		_debug_label.modulate = Color(1, 1, 1, 1)
		_debug_label.outline_modulate = Color(0, 0, 0, 1)
		_debug_label.position = Vector3(0, DEBUG_LABEL_HEIGHT_M, 0)
		skater.add_child(_debug_label)


func _physics_process(delta: float) -> void:
	if skater == null or puck == null or _agent == null:
		return
	if NetworkManager.is_replay_mode():
		return
	# Scripted mode bypasses the agent entirely — tutorial owns the inputs.
	# Movement-lock / celebration / input-blocked checks below assume normal
	# gameplay and don't apply to scripted tutorial bots (tutorial mode never
	# triggers a faceoff prep or celebration phase). The scripted shot
	# mini-state-machine still feeds the SkaterController, so shot release
	# behaviour matches a human pressing the same buttons.
	if scripted_mode:
		_build_script_input(delta)
		_process_input(_script_input, delta)
		skater.current_shot_state = _sm.get_state() as int
		return
	if _game_state.is_movement_locked():
		# Faceoff / intro skate-in: the bot glides from its bench / current spot
		# to the dot while an approach is active, then hands back to the draw-aim
		# freeze below on arrival (see SkaterController.begin_approach).
		if tick_faceoff_approach(delta):
			skater.current_shot_state = _sm.get_state() as int
			return
		# Mirror LocalController/RemoteController: zero velocity during dead
		# phases so residual inertia from before the lock can't drift the bot.
		skater.velocity = Vector3.ZERO
		# FACEOFF_PREP: keep the stick alive so the bot looks alive during
		# the countdown and naturally contests the drop. Aim at the puck —
		# centers clash over the dot, wings/D reach toward it. We don't run
		# _agent.tick here; the agent's full state machine isn't designed
		# for the locked phase and could drag in stale carrier / chase intent.
		if _game_state.allows_blade_aim_during_lock():
			_faceoff_input.delta = delta
			_faceoff_input.host_timestamp = NetworkManager.estimated_host_time()
			# Only the two centers are draw-tracking (armed by PhaseCoordinator);
			# they rip a real draw, everyone else just reaches toward the dot.
			if skater.is_draw_tracking():
				_faceoff_input.mouse_world_pos = _center_draw_target(puck.global_position)
			else:
				_faceoff_input.mouse_world_pos = puck.global_position
			apply_blade_aim_only(_faceoff_input, delta)
		return
	if _game_state.is_in_goal_celebration():
		# Celebration is movement-allowed live gameplay (humans can react),
		# but bots shouldn't be playing — they'd try to chase a pickup-locked
		# puck and bunch around the net. Skip agent input; physics friction
		# coasts whatever velocity the bot had at the goal moment to a stop.
		return
	if _game_state.is_input_blocked():
		return
	# Read the frame's shared snapshot. GameManager publishes it once per
	# host physics frame after StateBufferManager.capture; reading it here
	# avoids 6 bots × redundant interpolation passes per frame.
	perceived_snapshot = GameManager.current_snapshot
	var input: InputState = _agent.tick(perceived_snapshot, delta, NetworkManager.estimated_host_time())
	_process_input(input, delta)
	skater.current_shot_state = _sm.get_state() as int
	_refresh_debug_label()


# Blade-aim target for a center's draw during FACEOFF_PREP. Loads the blade on the
# side of the puck OPPOSITE the rip (bot_draw_windup_distance past the dot) through
# the countdown, then in the final bot_draw_swing_time sweeps it through the dot and
# out the far side, angled back toward our own zone / the backhand winger. Sweeping
# THROUGH the puck (not just pulling off it) gives the rip a real runway, so the
# blade is at full pace as it meets the puck; the crest is what the draw buffer
# carries into the contest.
func _center_draw_target(dot: Vector3) -> Vector3:
	var draw_dir: Vector3 = FaceoffDrawRules.bot_draw_heading(
			skater.global_position - dot, skater.is_left_handed, bot_draw_lateral_bias)
	if draw_dir.length() < 0.01:
		return dot
	var windup: Vector3 = dot - draw_dir * bot_draw_windup_distance
	var t_drop: float = _game_state.faceoff_time_until_drop()
	if t_drop > bot_draw_swing_time:
		return windup  # loaded on the far side, ready to rip through
	var follow_through: Vector3 = dot + draw_dir * bot_draw_pull_distance
	var progress: float = 1.0 - clampf(t_drop / maxf(bot_draw_swing_time, 0.0001), 0.0, 1.0)
	return windup.lerp(follow_through, progress)


func _refresh_debug_label() -> void:
	if _debug_label == null:
		return
	# Build the label text from the SM's per-tick scores. ► marks the
	# current winning option (independent of commit). intent: shows
	# what the bot is currently committed to (CARRY default; pre-aim
	# / charge states show the fire intent). last: persists the most
	# recent fired action.
	var winner: String = _agent.debug_winner()
	var intent: String = _agent.debug_intent()
	var lines: Array[String] = []
	lines.append("[%s] intent:%s" % [_agent.debug_role(), intent])

	var shoot_label: String = _agent.debug_shoot_label()
	var pass_slot: String = _agent.debug_pass_slot()
	var carry_dir: String = _agent.debug_carry_dir(perceived_snapshot)

	# Score lines, with ► on the winner. Round to 2 decimals — finer
	# precision changes the text every tick and defeats the change
	# detection.
	lines.append("%s %s %.2f" % [
			"►" if winner == shoot_label else " ", shoot_label, _agent.debug_shoot_score()])
	lines.append("%s PASS  %.2f →%s" % [
			"►" if winner == "PASS" else " ", _agent.debug_pass_score(), pass_slot])
	lines.append("%s CARRY %.2f %s" % [
			"►" if winner == "CARRY" else " ", _agent.debug_carry_score(), carry_dir])

	var last: String = _agent.debug_last_decision()
	if last != "":
		lines.append("last: " + last)

	var text: String = "\n".join(lines)
	if text != _debug_last_text:
		_debug_label.text = text
		_debug_last_text = text


# ── Scripted mode public API ──────────────────────────────────────────────────
# Tutorial-only puppet interface. Caller exclusively drives the bot's
# movement / aim / shot inputs after enabling scripted mode.

func set_scripted_mode(enabled: bool) -> void:
	scripted_mode = enabled
	if enabled:
		_script_hold = true
		_script_target_xz = Vector2.INF
		_script_aim = Vector3.INF
		_script_shot_kind = ""
		_script_shot_phase = 0
		_script_shot_ticks = 0
		if skater != null:
			skater.velocity = Vector3.ZERO


func script_move_to(world_pos: Vector3) -> void:
	_script_target_xz = Vector2(world_pos.x, world_pos.z)
	_script_hold = false


func script_hold() -> void:
	_script_hold = true
	_script_target_xz = Vector2.INF


func script_aim_at(world_pos: Vector3) -> void:
	_script_aim = world_pos


# kind ∈ {"wrist", "slap", "quick"}. No-op if a shot is already in progress.
# Each call triggers one full press → charge → release cycle synthesised
# across multiple physics ticks; the underlying SkaterController state
# machine sees the same edge pattern a human keyboard would emit.
func script_fire(kind: String) -> void:
	if kind != "wrist" and kind != "slap" and kind != "quick":
		push_warning("AIController.script_fire: invalid kind '%s'" % kind)
		return
	if _script_shot_phase != 0:
		return
	_script_shot_kind = kind
	_script_shot_phase = 1
	_script_shot_ticks = 0


# ── Scripted input synthesis ──────────────────────────────────────────────────

func _build_script_input(delta: float) -> void:
	_zero_script_input(delta)

	# Movement: head straight toward _script_target_xz until inside the
	# arrival radius (then naturally coast to a stop). The agent SM has a
	# subtler braking model but for tutorial demos point-and-go is enough.
	if not _script_hold and _script_target_xz != Vector2.INF and skater != null:
		var here := Vector2(skater.global_position.x, skater.global_position.z)
		var to_target: Vector2 = _script_target_xz - here
		if to_target.length() > _SCRIPT_ARRIVAL_RADIUS_M:
			_script_input.move_vector = to_target.normalized()

	# Aim: a non-INF script_aim drives blade IK; INF leaves mouse at ZERO and
	# the controller falls back to its no-aim default for the tick.
	if _script_aim != Vector3.INF:
		_script_input.mouse_world_pos = _script_aim

	_advance_script_shot()


func _advance_script_shot() -> void:
	if _script_shot_phase == 0:
		return
	var charge_target: int = 0
	match _script_shot_kind:
		"wrist": charge_target = _SCRIPT_WRIST_CHARGE_TICKS
		"slap":  charge_target = _SCRIPT_SLAP_CHARGE_TICKS
		"quick": charge_target = 0
	if _script_shot_phase == 1:
		# Press-edge tick: rising edge plus held for the same frame, mirroring
		# how a real key-down event from LocalController is composed.
		if _script_shot_kind == "slap":
			_script_input.slap_pressed = true
			_script_input.slap_held = true
		else:
			_script_input.shoot_pressed = true
			_script_input.shoot_held = true
		_script_shot_phase = 2
		_script_shot_ticks = 0
		return
	if _script_shot_phase == 2:
		_script_shot_ticks += 1
		if _script_shot_ticks <= charge_target:
			# Still charging — held stays true; pressed is edge-only so it's
			# already false from _zero_script_input above.
			if _script_shot_kind == "slap":
				_script_input.slap_held = true
			else:
				_script_input.shoot_held = true
		else:
			# Release: leaving held=false this tick is the falling edge the
			# SkaterController state machine watches for to fire the shot.
			_script_shot_phase = 0
			_script_shot_kind = ""


func _zero_script_input(delta: float) -> void:
	_script_input.delta = delta
	_script_input.host_timestamp = NetworkManager.estimated_host_time()
	_script_input.move_vector = Vector2.ZERO
	_script_input.mouse_world_pos = Vector3.ZERO
	_script_input.mouse_screen_pos = Vector2.ZERO
	_script_input.shoot_pressed = false
	_script_input.shoot_held = false
	_script_input.slap_pressed = false
	_script_input.slap_held = false
	_script_input.brake = false
	# Same flat default as SkaterAgent._zero_input — the loft level is
	# absolute per input frame, so scripted shots set it on their own ticks.
	_script_input.elevation_level = 0
	_script_input.block_held = false
	_script_input.stick_lift_held = false
