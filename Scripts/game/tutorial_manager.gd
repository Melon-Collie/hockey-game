extends Node

# ── Step identifier aliases ───────────────────────────────────────────────────
# Step IDs live in TutorialRegistry (to avoid a preload cycle); re-exported
# here so the rest of this file reads like the original constant references.
const STEP_SKATE:       int = TutorialRegistry.STEP_SKATE
const STEP_BRAKE:       int = TutorialRegistry.STEP_BRAKE
const STEP_QUICK_SHOT:  int = TutorialRegistry.STEP_QUICK_SHOT
const STEP_WRIST_SHOT:  int = TutorialRegistry.STEP_WRIST_SHOT
const STEP_SLAPSHOT:    int = TutorialRegistry.STEP_SLAPSHOT
const STEP_ONE_TIMER:   int = TutorialRegistry.STEP_ONE_TIMER
const STEP_SHOT_BLOCK:  int = TutorialRegistry.STEP_SHOT_BLOCK
const STEP_STICKCHECK:  int = TutorialRegistry.STEP_STICKCHECK
const STEP_BODY_CHECK:  int = TutorialRegistry.STEP_BODY_CHECK
const STEP_ELEVATION:   int = TutorialRegistry.STEP_ELEVATION
const STEP_OFFSIDES:    int = TutorialRegistry.STEP_OFFSIDES
const STEP_SPRINT:      int = TutorialRegistry.STEP_SPRINT
const STEP_BLADE_LIFT:  int = TutorialRegistry.STEP_BLADE_LIFT
const STEP_STICK_LIFT:  int = TutorialRegistry.STEP_STICK_LIFT
const STEP_SHOOT_WRIST:   int = TutorialRegistry.STEP_SHOOT_WRIST
const STEP_SHOOT_TARGETS: int = TutorialRegistry.STEP_SHOOT_TARGETS
const STEP_SHOOT_SLAP:    int = TutorialRegistry.STEP_SHOOT_SLAP
const STEP_SHOOT_GOALIE:  int = TutorialRegistry.STEP_SHOOT_GOALIE
const STEP_SHOOT_FINISH:  int = TutorialRegistry.STEP_SHOOT_FINISH


# ── Step definition ───────────────────────────────────────────────────────────

class TutorialStep:
	var title: String
	var instruction: String
	var hint: String

	func _init(t: String, i: String, h: String = "") -> void:
		title = t
		instruction = i
		hint = h


# Duration thresholds for sustained-hold steps
const _SKATE_HOLD:           float = 1.5
const _BRAKE_HOLD:           float = 1.0
const _SPRINT_HOLD:          float = 1.0
# Blade-lift step (raise your own stick with Q): hold the blade up briefly so a
# stray tap doesn't auto-complete.
const _BLADE_LIFT_HOLD:      float = 0.75
const _BLOCK_HOLD:           float = 2.0
const _SHOT_BLOCK_HOLD:      float = 1.0
# Shot block: puck comes from the offensive zone toward the player's goal.
# 14 m/s is a paced-down "wrister" feel — fast enough to feel like a shot,
# slow enough that a learner has time to read it and crouch into the lane.
# A real wrister is closer to 25 m/s but blocking that on muscle memory is
# unrealistic for a tutorial intro.
const _SHOT_BLOCK_PUCK_SPEED: float = 14.0
# One-timer: cross-ice pass speed from the opposite faceoff dot
const _ONE_TIMER_CROSS_SPEED: float = 5.0
# Ice height for puck placement
const _ICE_Y:                float = 0.05
# Standardised pacing across every tutorial step:
#   PREFIRE_DELAY runs once at step entry so the learner can read the
#   instruction before any puck launches at them.
#   REATTEMPT_DELAY runs between attempts (puck stopped, deflected past,
#   failed shot restage) — short enough that an engaged player isn't
#   waiting around, long enough that the puck visibly resets.
const _PREFIRE_DELAY:   float = 2.5
const _REATTEMPT_DELAY: float = 1.0

# ── References ────────────────────────────────────────────────────────────────

var tutorial_id: String = TutorialRegistry.BASICS_ID

var _local_record:     PlayerRecord    = null
var _local_controller: LocalController = null
var _skater:           Skater          = null
var _puck:             Puck            = null
# Puppeted bot used as a tutorial demo partner (stickcheck target, body-check
# target, one-timer passer, shot-block shooter). Replaces the static dummy
# skater the tutorial used to spawn — real bots get the team_id resolver wired
# correctly so stickcheck (apply_poke_check) and body-check signal filtering
# behave as they do in normal gameplay. See GameManager.spawn_tutorial_bot.
var _puppet_record: PlayerRecord = null

# ── State ─────────────────────────────────────────────────────────────────────

# Ordered list of step IDs for this tutorial, sourced from TutorialRegistry.
# _step_index walks this array; _current_step_id() is the active step's ID.
var _step_ids:           Array[int]            = []
var _step_defs:          Array[TutorialStep]   = []
var _step_index:         int   = 0
var _step_timer:         float = 0.0
var _hint_timer:         float = 0.0
var _complete_flash_timer: float = 0.0
var _wrister_aim_start:  float = -1.0   # -1 when not in WRISTER_AIM
var _cross_ice_dot_x:          float = 6.0   # set in _begin_step based on handedness
var _offside_ghost_seen:       bool  = false
# True once the one-timer cross-ice pass is in flight. The re-fire branch
# in _process gates on this so it can't trigger before the puck launches,
# and the re-fire scheduler clears it during the wait to keep from
# stacking duplicate re-fires.
var _one_timer_armed:          bool  = false
# One-timer race guard: the player picked up the puck and shot it; we deferred
# the cross-ice restage. While true, ignore further shot signals so a follow-up
# shot during the restage window doesn't re-queue another restage.
var _one_timer_restage_pending: bool = false

var _hud: TutorialHUD = null

# Restage timer: counts down after a failed shot; re-places puck when it hits 0.
# Uses the standardised _REATTEMPT_DELAY so failed-shot retries match the
# pacing of in-step re-fires on the shot-block and one-timer steps.
var _restage_timer: float = -1.0

# Prefire timer: counts down during a step's initial pause before launching
# the puck. -1 = no fire pending. _process dispatches to the right fire
# helper for the active step when it reaches 0.
var _prefire_timer: float = -1.0

# Shot-on-net watch state for basics QUICK/WRIST/SLAP steps. Set when the
# player releases a shot of the right type; cleared either by the puck
# crossing the open net (success → complete) or by the watch timer expiring
# (restage and try again). Generous bounds — tutorial encourages "put the
# puck on net" without demanding perfect aim.
var _watch_for_on_net:  bool  = false
var _shot_watch_timer:  float = 0.0
const _SHOT_WATCH_DURATION: float = 4.0
const _ON_NET_HALF_WIDTH:   float = 1.2  # slightly wider than the 1.83 m goal opening

# ── Shooting module (drill-based) ─────────────────────────────────────────────
# The net the tutorial player attacks (team 0 shoots toward -Z) and its lateral
# bound for goal/target detection.
const _GOAL_PLANE_Z:  float = -GameRules.GOAL_LINE_Z
const _NET_HALF_WIDTH: float = GameRules.NET_HALF_WIDTH
# Target sets, as (x = lateral, y = height) in the goal plane.
const _LOW_TARGETS: Array[Vector2] = [
	Vector2(-0.62, 0.30), Vector2(0.0, 0.30), Vector2(0.62, 0.30)]
const _HIGH_TARGETS: Array[Vector2] = [
	Vector2(-0.62, 0.95), Vector2(0.62, 0.95)]
const _GOALIE_TARGETS: Array[Vector2] = [
	Vector2(-0.62, 0.95), Vector2(0.62, 0.95), Vector2(0.0, 0.22)]
const _TARGET_RADIUS:       float = 0.33
const _TARGET_FRONT_OFFSET: float = 0.10  # float the rings just in front of the net
# Player's shooting spot for the slot drills, and the deeper start for Finish.
const _FINISH_START_Z: float = -10.0

var _shooting_active:     bool  = false
var _last_shot_qualifies: bool  = false   # did the last shot match the drill's required type
var _wrist_peak_charge:   float = 0.0     # peak normalised wrister charge this aim
var _shoot_restage_timer: float = -1.0    # countdown to re-stage the puck on the stick
var _targets:          Array[Vector2] = []
var _target_hit:       Array[bool]    = []
var _targets_remaining: int = 0
var _targets_phase:     int = 0           # 0 = low wave, 1 = high wave, 2 = toggle-off beat
var _target_noun:       String = "Targets hit"
var _target_node: TutorialTargets = null
var _on_shooting_shot_callable: Callable = Callable()

# Connected callables stored for safe disconnection
var _on_release_callable:          Callable = Callable()
var _on_one_timer_callable:        Callable = Callable()
var _on_body_check_callable:       Callable = Callable()
var _on_regular_shot_in_one_timer: Callable = Callable()
var _on_stickcheck_callable:       Callable = Callable()
var _on_stick_lift_callable:       Callable = Callable()


# Constructor sets the tutorial id; game_scene.gd passes the id selected by
# NetworkManager.tutorial_id when it instantiates the manager.
func _init(id: String = TutorialRegistry.BASICS_ID) -> void:
	tutorial_id = id


# ── Lifecycle ─────────────────────────────────────────────────────────────────

func _ready() -> void:
	_local_record = GameManager.get_local_player()
	if _local_record == null:
		push_error("TutorialManager: no local player found")
		return
	_local_controller = _local_record.controller as LocalController
	_skater = _local_record.skater
	_puck = GameManager.get_puck()

	_build_steps()
	if _step_ids.is_empty():
		push_error("TutorialManager: no steps for tutorial id '%s'" % tutorial_id)
		return

	_hud = TutorialHUD.new()
	_hud.set_tutorial_id(tutorial_id)
	add_child(_hud)
	_hud.skip_pressed.connect(_on_skip)
	_hud.reset_pressed.connect(_on_reset)

	_begin_step(0)


func _exit_tree() -> void:
	_disconnect_all_signals()
	_free_puppet()
	_teardown_shooting()
	# Do NOT clear NetworkManager.is_tutorial_mode here. The continuation path
	# (Next: <tutorial> button → start_tutorial(next_id) → change_scene_to_file)
	# sets is_tutorial_mode = true BEFORE the deferred scene change tears down
	# this node — clearing it in _exit_tree would race with that and make the
	# new game_scene._ready miss the tutorial spawn. Every legitimate exit path
	# (HUD Exit / Free Play / SideMenu launchers) sets the right flag itself.


# ── Step definitions ──────────────────────────────────────────────────────────

func _build_steps() -> void:
	_step_ids = TutorialRegistry.get_step_ids(tutorial_id)
	_step_defs.clear()
	for step_id: int in _step_ids:
		_step_defs.append(_step_def_for(step_id))


# Returns the TutorialStep (title/instruction/hint) for a given step ID. Keeps
# all teaching copy in one place; the registry decides ordering per tutorial.
func _step_def_for(step_id: int) -> TutorialStep:
	match step_id:
		STEP_SKATE:
			return TutorialStep.new(
				"Skate",
				"Press W, A, S, D to skate around the ice.",
				"Hold a direction to build up speed — you keep gliding when you let go.")
		STEP_SPRINT:
			return TutorialStep.new(
				"Sprint",
				"Hold Shift while skating to sprint for a burst of speed.",
				"Sprinting drains stamina and widens your turn radius — use it in straight-line bursts.")
		STEP_BRAKE:
			return TutorialStep.new(
				"Brake",
				"Hold Space to brake hard and stop quickly.",
				"Tap Space while moving to scrub off speed fast.")
		STEP_BLADE_LIFT:
			return TutorialStep.new(
				"Blade Lift",
				"Hold Q to lift your stick blade up off the ice.",
				"Press and hold Q and your blade pops up. (You can't lift while carrying the puck.)")
		STEP_STICK_LIFT:
			return TutorialStep.new(
				"Stick Lift",
				"Get under the opponent's stick and hold Q to lift it — that pops the puck off their blade and strips it loose.",
				"Skate your blade beneath their stick, then hold Q to lift it and knock the puck free.")
		STEP_QUICK_SHOT:
			return TutorialStep.new(
				"Quick Shot",
				"Skate over the puck to pick it up, then press F to snap a quick shot into the net. This is also your pass.",
				"Tap F — the quick shot fires instantly toward your cursor. Aim at the open net ahead of you.")
		STEP_WRIST_SHOT:
			return TutorialStep.new(
				"Wrist Shot",
				"With the puck, hold the left mouse button and drag to aim, then release to fire a wrist shot into the net.",
				"Hold and drag — a longer drag means more power, and the drag direction is your aim.")
		STEP_SLAPSHOT:
			return TutorialStep.new(
				"Slapshot",
				"With the puck, hold the right mouse button to wind up, then release to blast a slapshot into the net.",
				"Hold right-click to charge — the longer you hold, the harder the shot.")
		STEP_ONE_TIMER:
			return TutorialStep.new(
				"One-Timer",
				"A pass is sliding toward you from the far dot. Hold the right mouse button to wind up before it arrives, then release the instant it reaches your stick.",
				"Start charging right-click now — don't wait for the puck to get there.")
		STEP_SHOT_BLOCK:
			return TutorialStep.new(
				"Shot Block",
				"A shot is coming at you. Hold Ctrl to drop into a blocking stance and get in its path.",
				"Hold Ctrl and line your body up with the puck.")
		STEP_STICKCHECK:
			return TutorialStep.new(
				"Stick Check",
				"Skate your stick into the opponent's puck to knock it loose — that's a stick check.",
				"Get close and sweep your stick through the puck.")
		STEP_BODY_CHECK:
			return TutorialStep.new(
				"Body Check",
				"Build up speed and skate straight into the opponent to knock them off the puck.",
				"Get a running start and aim right at them.")
		STEP_ELEVATION:
			return TutorialStep.new(
				"Lifting the Puck",
				"With the puck, scroll the mouse wheel up, then shoot to lift the puck off the ice.",
				"Scroll up first, then left- or right-click to shoot — the puck flies up off the ground.")
		STEP_OFFSIDES:
			return TutorialStep.new(
				"Offsides",
				"The puck has to cross the blue line into the attacking zone before you do. You went in first, so you're offside — and now you're a ghost until you skate back out past the blue line.",
				"Skate back toward your own end and cross the blue line to reset.")
		STEP_SHOOT_WRIST:
			return TutorialStep.new(
				"Wrist Shot",
				"You've got the puck. Hold left-click, drag toward the net, and release. The way you drag is your aim — and the farther you drag, the harder the shot.",
				"Don't just hold and sit still — drag the mouse toward the net before you let go.")
		STEP_SHOOT_TARGETS:
			# Live copy is set per-wave by _show_targets_wave; this is the wave-1 default.
			return TutorialStep.new(
				"Pick Your Spot",
				"Three targets are lit across the net. Drag each shot toward one to knock it out — any order.",
				"Aim is the direction you drag, not where the cursor sits.")
		STEP_SHOOT_SLAP:
			return TutorialStep.new(
				"Slapshot",
				"Hold right-click to wind up a slapshot. It fires toward your mouse, and the shot's direction locks the moment you press — so aim with the cursor first. You'll keep gliding, but you can't steer or change the shot mid-wind-up.",
				"Point the cursor where you want it before you press. The longer you hold, the harder it goes.")
		STEP_SHOOT_GOALIE:
			return TutorialStep.new(
				"Beat the Goalie",
				"A goalie's in the net now — but he's standing still. Pick him apart: top-left corner, top-right corner, and the five-hole between his pads.",
				"Elevation gets it over his glove. The five-hole is the gap between his legs — keep that one low.")
		STEP_SHOOT_FINISH:
			return TutorialStep.new(
				"Finish",
				"Last one. You've got the puck and a goalie ahead of you. Score however you like.",
				"Everything you've practiced is fair game — pick a corner, go five-hole, walk him side to side.")
	push_error("TutorialManager: unknown step id %d" % step_id)
	return TutorialStep.new("", "", "")


# Returns the active step's ID, or -1 if outside the step list. Helpers use
# this in their match dispatchers so the index→id mapping stays in one place.
func _current_step_id() -> int:
	if _step_index < 0 or _step_index >= _step_ids.size():
		return -1
	return _step_ids[_step_index]


# ── Step sequencing ───────────────────────────────────────────────────────────

# The puckless movement steps (the puck is stashed far off-rink) frame best on
# the player-locked camera, which centers on the skater rather than zooming out
# to chase the stashed puck.
func _step_uses_locked_camera(step_id: int) -> bool:
	return step_id == STEP_SKATE or step_id == STEP_SPRINT \
		or step_id == STEP_BRAKE or step_id == STEP_BLADE_LIFT


func _begin_step(index: int) -> void:
	_disconnect_all_signals()
	_teardown_shooting()
	_step_index             = index
	_step_timer             = 0.0
	_hint_timer             = 0.0
	_complete_flash_timer   = 0.0
	_restage_timer          = -1.0
	_prefire_timer          = -1.0
	_wrister_aim_start      = -1.0
	_offside_ghost_seen     = false
	_one_timer_armed        = false
	_one_timer_restage_pending = false
	_watch_for_on_net       = false
	_shot_watch_timer       = 0.0

	var step_id: int = _current_step_id()
	var step: TutorialStep = _step_defs[index]
	_hud.set_step(index, _step_ids.size(), step.title, step.instruction, step.hint)
	# Puckless movement steps stash the puck off-rink; force the player-locked
	# camera so it sits centered on the skater instead of zooming out toward it.
	_local_controller.set_camera_force_locked(_step_uses_locked_camera(step_id))
	# Offsides detection runs only during the OFFSIDES step. Steps that put
	# the player deep in the O-zone with the puck temporarily off-rink
	# (one-timer, shot-block prefire) would otherwise trip offsides and
	# ghost the player.
	GameManager.set_tutorial_offsides_active(step_id == STEP_OFFSIDES)

	match step_id:
		STEP_SKATE, STEP_SPRINT, STEP_BLADE_LIFT:
			# Open ice, puck stashed out of the way. Sprint and blade-lift both
			# need the player puck-free (sprint to read stamina cleanly, blade-lift
			# because the voluntary Q raise is gated off while carrying).
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0))
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))  # out of the way

		STEP_BRAKE:
			pass  # player is already on the ice from the sprint/skate step

		STEP_STICK_LIFT:
			# Same puppet-with-the-puck setup as the stick-check step, but the
			# player strips by lifting the puppet's stick (blade up + under it)
			# instead of poking. Completion only fires for a lift (see the
			# puck_stripped handler); a stray poke re-pins the puck (see _process).
			_local_controller.teleport_to(Vector3(0.0, 1.0, 2.5))
			_ensure_puppet(Vector3(0.0, 1.0, 0.0))
			if _puck.carrier != null:
				_puck.drop()
			_puck.set_carrier(_puppet_record.skater)
			_on_stick_lift_callable = func(_ex: Skater) -> void:
				# A lifted blade can't poke (puck_controller skips the poke path
				# when blade_up), so a strip while the player's blade is up is a
				# stick lift. A no-blade poke falls through to the _process re-pin.
				if _skater.blade_up:
					_complete_step()
			_puck.puck_stripped.connect(_on_stick_lift_callable)

		STEP_QUICK_SHOT, STEP_WRIST_SHOT, STEP_SLAPSHOT, STEP_ELEVATION:
			# Spawn in the slot — the prime scoring area right in front of the
			# attacking net (team 0 attacks -Z) — so it reads as "shoot the puck
			# into the net a few metres away" rather than from center ice.
			var slot_z: float = -(GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)
			_local_controller.teleport_to(Vector3(0.0, 1.0, slot_z))
			# Puck 1.5 m ahead toward the net so the player skates onto it facing the goal.
			_place_puck(Vector3(0.0, _ICE_Y, slot_z - 1.5))
			_on_release_callable = func(dir: Vector3, power: float, is_slapper: bool) -> void:
				_on_shot_released(dir, power, is_slapper)
			_local_controller.puck_release_requested.connect(_on_release_callable)

		STEP_ONE_TIMER:
			# Left-handed players receive from right dot; right-handed from left dot
			# (forehand faces the incoming cross-ice pass)
			_cross_ice_dot_x = 6.0 if PlayerPrefs.is_left_handed else -6.0
			_local_controller.teleport_to(Vector3(_cross_ice_dot_x, 1.0, -GameRules.ICING_FACEOFF_DOT_Z))
			# Stash the puck off-rink while the prefire delay counts down so
			# the player can read the instruction and ready RMB before the
			# cross-ice pass actually launches. _process fires it when the
			# timer hits 0.
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))
			_prefire_timer = _PREFIRE_DELAY
			_on_one_timer_callable = func(_dir: Vector3, _power: float) -> void:
				_complete_step()
			_local_controller.one_timer_release_requested.connect(_on_one_timer_callable)
			# Race fix: if the player picks up the puck and shoots normally instead
			# of timing the one-timer, the synchronous puck-release handler used to
			# restage the puck in the same frame as the shot's release-velocity
			# application — corrupting position/velocity. Defer with call_deferred
			# + wait two physics frames so the in-progress shot fully resolves
			# before we move the puck. _one_timer_restage_pending gates re-entry
			# so a second shot during the wait can't queue a duplicate restage.
			_on_regular_shot_in_one_timer = func(_dir: Vector3, _power: float, _is_slapper: bool) -> void:
				if _one_timer_restage_pending:
					return
				_one_timer_restage_pending = true
				_restage_one_timer_when_safe.call_deferred()
			_local_controller.puck_release_requested.connect(_on_regular_shot_in_one_timer)

		STEP_SHOT_BLOCK:
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0))
			# Stash + delay so the player can read "hold Ctrl" before the
			# puck launches. _process fires when the prefire timer hits 0.
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))
			_prefire_timer = _PREFIRE_DELAY

		STEP_STICKCHECK:
			_local_controller.teleport_to(Vector3(0.0, 1.0, 2.5))
			_ensure_puppet(Vector3(0.0, 1.0, 0.0))
			# Give the puppet the puck — PuckController pins it to the bot's blade
			# each physics frame. The bot's team_id resolver (wired by spawn_bot)
			# returns team 1, so apply_poke_check recognises the player as opposing
			# and the strip fires when the player's blade sweeps through.
			if _puck.carrier != null:
				_puck.drop()
			_puck.set_carrier(_puppet_record.skater)
			_on_stickcheck_callable = func(_ex: Skater) -> void:
				_complete_step()
			_puck.puck_stripped.connect(_on_stickcheck_callable)

		STEP_BODY_CHECK:
			_local_controller.teleport_to(Vector3(-4.0, 1.0, 0.0))
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))
			# Prevent race-condition re-pickup: drop() is sync but set_puck_position is
			# deferred by Jolt; one physics tick sees the puck at the old position.
			_puck.set_skater_cooldown(_skater, 0.5)
			_ensure_puppet(Vector3(4.0, 1.0, 0.0))
			_on_body_check_callable = func(_victim: Skater, _force: float, _dir: Vector3) -> void:
				_complete_step()
			_skater.body_checked_player.connect(_on_body_check_callable)

		STEP_OFFSIDES:
			# Place player deep in offensive zone (past far blue line, -Z direction)
			_local_controller.teleport_to(Vector3(0.0, 1.0, -12.0))
			# Puck in neutral zone — player is immediately offside
			_place_puck(Vector3(0.0, _ICE_Y, 0.0))

		STEP_SHOOT_WRIST, STEP_SHOOT_SLAP:
			# Open net, puck on the stick in the slot. Type-gated completion
			# (dragged wrister / slapper) handled in _on_shooting_shot.
			_setup_shooting_drill(_slot_z())
			_hud.set_objective("Score on the open net.")

		STEP_SHOOT_TARGETS:
			_setup_shooting_drill(_slot_z())
			_show_targets_wave(0)

		STEP_SHOOT_GOALIE:
			_setup_shooting_drill(_slot_z())
			GameManager.spawn_tutorial_goalie()
			_target_noun = "Beat him"
			_show_target_set(_GOALIE_TARGETS)

		STEP_SHOOT_FINISH:
			# Deeper start so they skate in and finish however they like — against a
			# live, beginner-tuned (Easy) goalie, not the static target from the
			# previous drill (the step text already says "walk him side to side").
			_setup_shooting_drill(_FINISH_START_Z)
			GameManager.spawn_tutorial_goalie(true)
			_hud.set_objective("Score.")


func _complete_step() -> void:
	_disconnect_all_signals()
	_complete_flash_timer = TutorialHUD._COMPLETE_FLASH_DURATION
	_hud.flash_complete()
	# Drop any corrective prompt so it doesn't linger over the completion flash.
	_hud.clear_alert()
	# Tear the puppet down after any step that used it so it doesn't linger
	# into a step that doesn't need it (e.g. body-check → elevation in the
	# advanced flow).
	var step_id: int = _current_step_id()
	if step_id == STEP_BODY_CHECK or step_id == STEP_STICKCHECK or step_id == STEP_STICK_LIFT:
		_free_puppet()
	# Shooting drills tear down their targets / stationary goalie on completion
	# (the final Finish step has no _begin_step after it to do the cleanup).
	_teardown_shooting()


func _advance_step() -> void:
	_hud.hide_complete_flash()
	_step_index += 1
	if _step_index >= _step_ids.size():
		# Mark this tutorial complete so first-launch routing skips it next time
		# and the SideMenu shows a checkmark next to it.
		PlayerPrefs.mark_tutorial_complete(tutorial_id)
		_hud.show_tutorial_complete()
	else:
		_begin_step(_step_index)


func _on_skip() -> void:
	var step_id: int = _current_step_id()
	if step_id == STEP_SHOT_BLOCK:
		_place_puck(Vector3(100.0, _ICE_Y, 100.0))  # clear the in-flight puck
	if step_id == STEP_STICKCHECK or step_id == STEP_BODY_CHECK or step_id == STEP_STICK_LIFT:
		_free_puppet()
	_complete_step()


func _on_reset() -> void:
	_begin_step(_step_index)


# ── Per-frame logic ───────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if _local_record == null:
		return

	if _complete_flash_timer > 0.0:
		_complete_flash_timer -= delta
		if _complete_flash_timer <= 0.0:
			_advance_step()
		return

	_hint_timer += delta
	if _hint_timer >= TutorialHUD._HINT_DELAY:
		_hud.show_hint()

	# Puck re-stage after a failed shot attempt
	if _restage_timer >= 0.0:
		_restage_timer -= delta
		if _restage_timer <= 0.0:
			_restage_timer = -1.0
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0))
			_place_puck(Vector3(0.0, _ICE_Y, 3.5))

	# Prefire delay — dispatches to the per-step fire helper once the
	# read-the-text pause elapses. Steps schedule this in _begin_step by
	# setting _prefire_timer; we map the active step id back to the right
	# helper here so adding a new prefire step doesn't need any plumbing.
	if _prefire_timer >= 0.0:
		_prefire_timer -= delta
		if _prefire_timer <= 0.0:
			_prefire_timer = -1.0
			match _current_step_id():
				STEP_SHOT_BLOCK:
					_fire_puck_for_shot_block()
				STEP_ONE_TIMER:
					_fire_puck_cross_ice()

	# Shot-on-net watch for basics QUICK/WRIST/SLAP. Player has released a
	# matching shot type; we're waiting for the puck to reach the empty net.
	# Team 0 attacks toward -Z, so "in the net" = puck.z past the negative
	# goal line and within ±_ON_NET_HALF_WIDTH of x=0.
	if _watch_for_on_net:
		_shot_watch_timer -= delta
		var p: Vector3 = _puck.get_puck_position()
		if p.z < -GameRules.GOAL_LINE_Z and absf(p.x) < _ON_NET_HALF_WIDTH:
			_watch_for_on_net = false
			# Tidy: keep the puck from bouncing around in the net during the
			# completion flash before the next step takes ownership of placement.
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))
			_complete_step()
			return
		if _shot_watch_timer <= 0.0:
			_watch_for_on_net = false
			_restage_timer = _REATTEMPT_DELAY

	# Track WRISTER_AIM (state 2) entry for quick vs wrist shot distinction
	var shot_state: int = _local_controller.get_shot_state()
	if shot_state == 2:
		if _wrister_aim_start < 0.0:
			_wrister_aim_start = Time.get_ticks_msec() / 1000.0
	else:
		if _wrister_aim_start >= 0.0:
			_wrister_aim_start = -1.0

	# Shooting module: a self-contained watch/restage loop plus the targets
	# drill's final scroll-down-to-go-flat beat. These steps don't use the
	# match below, so handle them here and return.
	if _shooting_active:
		if shot_state == 2:
			_wrist_peak_charge = maxf(_wrist_peak_charge, _skater.shot_charge)
		_shooting_tick(delta)
		_update_elevation_prompt()
		if _current_step_id() == STEP_SHOOT_TARGETS and _targets_phase == 2 \
				and not _skater.is_elevated:
			_complete_step()
		return

	match _current_step_id():
		STEP_SKATE:
			if _skater.velocity.length() > 2.5:
				_step_timer += delta
				if _step_timer >= _SKATE_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0

		STEP_SPRINT:
			# sprint_active is the resolved per-tick truth: sprint held, moving,
			# stamina available, not locked out. Hold it for a beat to complete.
			if _local_controller.sprint_active:
				_step_timer += delta
				if _step_timer >= _SPRINT_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0

		STEP_BRAKE:
			# is_braced is true whenever Space is held, with or without a direction
			if _skater.is_braced:
				_step_timer += delta
				if _step_timer >= _BRAKE_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0

		STEP_BLADE_LIFT:
			# blade_up is the voluntary Q raise (gated off while carrying). Hold
			# it briefly so a stray tap doesn't auto-complete.
			if _skater.blade_up:
				_step_timer += delta
				if _step_timer >= _BLADE_LIFT_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0

		STEP_STICK_LIFT:
			# If the player knocked the puck loose without a lift (a stray poke),
			# give it back to the puppet once it settles so they can try the lift
			# again. A successful lift completes the step in the strip handler,
			# after which _complete_flash_timer short-circuits _process.
			if _puck.carrier == null and _puppet_record != null \
					and is_instance_valid(_puppet_record.skater) \
					and _puck.get_puck_velocity().length() < 0.3:
				_puck.set_carrier(_puppet_record.skater)

		STEP_SHOT_BLOCK:
			# Complete when player holds the block stance for long enough
			if _local_controller.get_shot_state() == 6:  # SHOT_BLOCKING
				_step_timer += delta
				if _step_timer >= _SHOT_BLOCK_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0
			# Re-fire if the puck passed the player, came to rest before
			# reaching them (deflected into the boards), or got blocked into
			# a corner. Stash + schedule via _prefire_timer so the standard
			# 1s between-attempts beat applies and the timer's own gate
			# stops this branch retriggering during the wait.
			if _prefire_timer < 0.0 and _puck.carrier == null:
				var puck_z: float = _puck.get_puck_position().z
				var puck_v: float = _puck.get_puck_velocity().length()
				if puck_z > _skater.global_position.z + 4.0 or puck_v < 0.3:
					_place_puck(Vector3(100.0, _ICE_Y, 100.0))
					_prefire_timer = _REATTEMPT_DELAY

		STEP_ONE_TIMER:
			# Re-fire if the cross-ice pass stopped (hit boards or missed the
			# player). Stash + schedule via _prefire_timer so the standard 1s
			# between-attempts beat applies. _one_timer_armed flips false on
			# restage so this branch can't retrigger during the wait.
			if _one_timer_armed and _prefire_timer < 0.0 and _puck.carrier == null:
				if _puck.get_puck_velocity().length() < 0.3:
					_place_puck(Vector3(100.0, _ICE_Y, 100.0))
					_one_timer_armed = false
					_prefire_timer = _REATTEMPT_DELAY

		STEP_OFFSIDES:
			if not _offside_ghost_seen:
				if _skater.is_ghost:
					_offside_ghost_seen = true
					_hud.set_step(_step_index, _step_ids.size(),
						"Offsides",
						"Now you're a ghost — passes go right through you. Skate back out past the blue line to get back in the play.",
						"Skate toward your own end and cross the blue line.")
			else:
				if not _skater.is_ghost:
					_complete_step()


# ── Shot signal handler ───────────────────────────────────────────────────────

func _on_shot_released(dir: Vector3, _power: float, is_slapper: bool) -> void:
	# Two-stage completion: first match the shot TYPE the step is teaching,
	# then (for basics steps) wait for the puck to actually reach the empty
	# net. Wrong type → restage immediately so the player can try again.
	var type_correct := false
	match _current_step_id():
		STEP_QUICK_SHOT:
			# The quick shot (F) fires straight from carry without entering
			# WRISTER_AIM, so a never-aimed non-slapper release is the quick shot.
			if not is_slapper and _wrister_aim_start < 0.0:
				type_correct = true
		STEP_WRIST_SHOT:
			# The wrist shot goes through WRISTER_AIM (LMB), so it has an aim start.
			if not is_slapper and _wrister_aim_start >= 0.0:
				type_correct = true
		STEP_SLAPSHOT:
			if is_slapper:
				type_correct = true
		STEP_ELEVATION:
			if dir.y > 0.1:
				type_correct = true
	if not type_correct:
		_restage_timer = _REATTEMPT_DELAY
		return
	if _requires_shot_on_net():
		# Basics teaches shooting on an empty net — pass criterion is the
		# puck reaching the goal. _process watches puck position.
		_watch_for_on_net = true
		_shot_watch_timer = _SHOT_WATCH_DURATION
	else:
		_complete_step()


# Whether the active step requires a shot-on-net to complete, on top of
# matching the correct shot type. Basics steps run with no goalie spawned
# (see TutorialRegistry.wants_goalies), so we ask the player to actually
# put the puck in the net. Advanced's elevation step has a goalie present
# and is about the LIFT mechanic — type match alone completes that one.
func _requires_shot_on_net() -> bool:
	var sid: int = _current_step_id()
	return sid == STEP_QUICK_SHOT or sid == STEP_WRIST_SHOT or sid == STEP_SLAPSHOT


# Deferred restage for STEP_ONE_TIMER when the player picks up the puck and
# shoots normally. Waits two physics frames so the in-progress release-velocity
# application can't corrupt the new puck placement, and re-checks the step
# (player may have pressed Reset or auto-completed mid-await).
func _restage_one_timer_when_safe() -> void:
	if _current_step_id() != STEP_ONE_TIMER:
		_one_timer_restage_pending = false
		return
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _current_step_id() != STEP_ONE_TIMER:
		_one_timer_restage_pending = false
		return
	_local_controller.teleport_to(Vector3(_cross_ice_dot_x, 1.0, -GameRules.ICING_FACEOFF_DOT_Z))
	_one_timer_armed = false
	_fire_puck_cross_ice()
	_one_timer_restage_pending = false


# ── Staging helpers ───────────────────────────────────────────────────────────

# Places the puck at a position with zero velocity.
# Does NOT use Puck.reset() (which schedules a deferred reset via _pending_reset;
# the tutorial needs the position to land immediately).
func _place_puck(pos: Vector3) -> void:
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(pos)
	# Velocity: Jolt zeroes it on the first dynamic step after unfreeze, which is fine.
	_puck.linear_velocity = Vector3.ZERO


# Fires the puck from the opposite end-zone faceoff dot toward _cross_ice_dot_x for STEP_ONE_TIMER.
func _fire_puck_cross_ice() -> void:
	var from_x: float = -_cross_ice_dot_x
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(Vector3(from_x, _ICE_Y, -GameRules.ICING_FACEOFF_DOT_Z))
	# Slide toward the player's dot; tiny Y keeps velocity alive through Jolt's first integration step
	var vel_x: float = signf(-from_x) * _ONE_TIMER_CROSS_SPEED
	_puck.apply_release_velocity(Vector3(vel_x, 0.001, 0.0))
	_one_timer_armed = true


# Fires the puck from the offensive zone toward the player's CURRENT position
# for the shot-block step. Player starts at z=5 (own half) and the puck comes
# from z=-8; if the player has drifted off the center axis (or wandered out
# of the lane between re-fires) the shot used to fly past at x=0 and miss
# them entirely. Aiming at the live position guarantees the puck heads
# straight at them every fire.
func _fire_puck_for_shot_block() -> void:
	if _puck.carrier != null:
		_puck.drop()
	var from := Vector3(0.0, _ICE_Y, -8.0)
	_puck.set_puck_position(from)
	var to: Vector3 = _skater.global_position
	var dir := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if dir.length() < 0.01:
		dir = Vector3.FORWARD * -1.0  # +Z fallback if player is right on top
	dir = dir.normalized()
	# Tiny Y so velocity survives Jolt's first integration step (same trick as
	# _fire_puck_cross_ice — without it the puck can settle inert on tick 0).
	_puck.apply_release_velocity(dir * _SHOT_BLOCK_PUCK_SPEED + Vector3(0.0, 0.001, 0.0))


func _ensure_puppet(position: Vector3) -> void:
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		_puppet_record = GameManager.spawn_tutorial_bot(position, 0)
		if _puppet_record == null:
			return
	else:
		_puppet_record.skater.global_position = position
	# Face toward the player so the puppet reads as engaged with the learner.
	# Facing is XZ in world space; team-1 bots default to (0, 1) which faces
	# +Z, which is wrong when the player is off-axis (e.g. body-check step
	# spawns the puppet at +X with the player at -X).
	var to_player := Vector2(
			_skater.global_position.x - _puppet_record.skater.global_position.x,
			_skater.global_position.z - _puppet_record.skater.global_position.z)
	if to_player.length() > 0.01:
		_puppet_record.skater.set_facing(to_player.normalized())
	var ai_ctrl: AIController = _puppet_record.controller as AIController
	if ai_ctrl != null:
		ai_ctrl.script_hold()
		ai_ctrl.script_aim_at(_skater.global_position)


func _free_puppet() -> void:
	if _puppet_record == null:
		return
	GameManager.despawn_tutorial_bot(_puppet_record)
	_puppet_record = null


# ── Signal management ─────────────────────────────────────────────────────────

func _disconnect_all_signals() -> void:
	if _local_controller == null:
		return

	if _on_release_callable.is_valid():
		if _local_controller.puck_release_requested.is_connected(_on_release_callable):
			_local_controller.puck_release_requested.disconnect(_on_release_callable)
		_on_release_callable = Callable()

	if _on_one_timer_callable.is_valid():
		if _local_controller.one_timer_release_requested.is_connected(_on_one_timer_callable):
			_local_controller.one_timer_release_requested.disconnect(_on_one_timer_callable)
		_on_one_timer_callable = Callable()

	if _on_body_check_callable.is_valid() and _skater != null:
		if _skater.body_checked_player.is_connected(_on_body_check_callable):
			_skater.body_checked_player.disconnect(_on_body_check_callable)
		_on_body_check_callable = Callable()

	if _on_regular_shot_in_one_timer.is_valid():
		if _local_controller.puck_release_requested.is_connected(_on_regular_shot_in_one_timer):
			_local_controller.puck_release_requested.disconnect(_on_regular_shot_in_one_timer)
		_on_regular_shot_in_one_timer = Callable()

	if _on_stickcheck_callable.is_valid() and _puck != null:
		if _puck.puck_stripped.is_connected(_on_stickcheck_callable):
			_puck.puck_stripped.disconnect(_on_stickcheck_callable)
		_on_stickcheck_callable = Callable()

	if _on_stick_lift_callable.is_valid() and _puck != null:
		if _puck.puck_stripped.is_connected(_on_stick_lift_callable):
			_puck.puck_stripped.disconnect(_on_stick_lift_callable)
		_on_stick_lift_callable = Callable()

	if _on_shooting_shot_callable.is_valid():
		if _local_controller.puck_release_requested.is_connected(_on_shooting_shot_callable):
			_local_controller.puck_release_requested.disconnect(_on_shooting_shot_callable)
		_on_shooting_shot_callable = Callable()


# ── Shooting module helpers ───────────────────────────────────────────────────

# Player's shooting spot for the slot drills: in the slot, SLOT_DIST_M out from
# the attacking net (team 0 attacks -Z).
func _slot_z() -> float:
	return -(GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)


# Shared setup for every shooting drill: stand the player at start_z facing the
# net, put the puck on the stick, and listen for shots.
func _setup_shooting_drill(start_z: float) -> void:
	_shooting_active     = true
	_shoot_restage_timer = -1.0
	_wrist_peak_charge   = 0.0
	_last_shot_qualifies = false
	_targets_phase       = 0
	_target_noun         = "Targets hit"
	_local_controller.teleport_to(Vector3(0.0, 1.0, start_z), Vector2(0.0, -1.0))
	_give_puck_to_player()
	_on_shooting_shot_callable = func(d: Vector3, p: float, s: bool) -> void:
		_on_shooting_shot(d, p, s)
	_local_controller.puck_release_requested.connect(_on_shooting_shot_callable)


# Minimum blade-drag (m) for the Wrist Shot drill to count the shot as a real
# dragged wrister rather than a flick. The engine now splits quick-vs-charged by
# hold TIME (not drag distance), but the drill's lesson is "drag to aim/charge,"
# so it still gates on the player having dragged meaningfully.
const _WRIST_DRAG_QUALIFY_M: float = 0.15

# Records whether the just-released shot satisfies the active drill's required
# type. Plain-goal drills (wrist, slap, finish) complete only when this is true;
# the target/goalie drills clear via the target test, so they never complete on
# a plain goal (qualifies stays false).
func _on_shooting_shot(_dir: Vector3, _power: float, is_slapper: bool) -> void:
	match _current_step_id():
		STEP_SHOOT_WRIST:
			var peak_dist: float = _wrist_peak_charge * _local_controller.max_wrister_charge_distance
			_last_shot_qualifies = (not is_slapper) and TutorialShotRules.is_dragged_wrister(
					peak_dist, _WRIST_DRAG_QUALIFY_M)
		STEP_SHOOT_SLAP:
			_last_shot_qualifies = is_slapper
		STEP_SHOOT_FINISH:
			_last_shot_qualifies = true
		_:
			_last_shot_qualifies = false
	_wrist_peak_charge = 0.0


# Elevation toggle the active drill expects, or _ELEV_ANY when it doesn't care
# (the player picks per shot — e.g. the goalie drill, where the right answer
# depends on which target they're going for). Drills that assume a flat shot
# want it OFF; the high-targets wave wants it ON. Drives a corrective prompt
# (never an auto-fix — managing the sticky toggle is part of the lesson).
const _ELEV_ANY:    int = -1
const _ELEV_FLAT:   int = 0
const _ELEV_LIFTED: int = 1

func _expected_elevation() -> int:
	match _current_step_id():
		STEP_SHOOT_WRIST, STEP_SHOOT_SLAP:
			return _ELEV_FLAT
		STEP_SHOOT_TARGETS:
			# High wave needs a lifted shot; the low wave and the scroll-down beat
			# need it flat.
			return _ELEV_LIFTED if _targets_phase == 1 else _ELEV_FLAT
	return _ELEV_ANY


# Shows / clears the amber elevation prompt for the active drill. Called every
# frame from the shooting branch so it tracks the toggle live.
func _update_elevation_prompt() -> void:
	var expected: int = _expected_elevation()
	if expected == _ELEV_ANY:
		_hud.clear_alert()
		return
	if expected == _ELEV_LIFTED and not _skater.is_elevated:
		_hud.set_alert("Your shot is flat — scroll the wheel up to lift it.")
	elif expected == _ELEV_FLAT and _skater.is_elevated:
		_hud.set_alert("Your shot is set to lift — scroll the wheel down to go flat.")
	else:
		_hud.clear_alert()


# Per-frame watch/restage loop for shooting drills. Waits out the re-stage
# beat, then watches the loose puck for a goal-line crossing (handled by
# _on_puck_crossed_net) or a shot that died short (→ re-stage and try again).
func _shooting_tick(delta: float) -> void:
	if _shoot_restage_timer >= 0.0:
		_shoot_restage_timer -= delta
		if _shoot_restage_timer <= 0.0:
			_shoot_restage_timer = -1.0
			_give_puck_to_player()
		return
	if _puck.carrier != null:
		return  # puck on a stick — nothing in flight
	var pos: Vector3 = _puck.get_puck_position()
	if TutorialShotRules.crossed_goal_line(pos.x, pos.z, _GOAL_PLANE_Z, -1.0, _NET_HALF_WIDTH):
		_on_puck_crossed_net(pos)
		return
	# Use the release-aware velocity: the frame a shot fires, the puck's carrier
	# is already cleared but Jolt hasn't applied the release impulse yet, so raw
	# linear_velocity reads zero. get_release_velocity() returns the pending shot
	# vector in that window — without it the just-fired puck reads as "died short"
	# and gets stashed off-rink on its first airborne frame (looks like it
	# vanishes the instant you shoot).
	if _puck.get_release_velocity().length() < 0.3:
		_stash_and_restage()


# Resolve a puck that just crossed the goal line. Target drills clear the
# nearest lit target; plain-goal drills complete if the shot type matched.
func _on_puck_crossed_net(pos: Vector3) -> void:
	if not _targets.is_empty():
		var idx: int = TutorialShotRules.nearest_target(pos.x, pos.y, _targets, _TARGET_RADIUS)
		if idx >= 0 and not _target_hit[idx]:
			_target_hit[idx] = true
			_targets_remaining -= 1
			if _target_node != null and is_instance_valid(_target_node):
				_target_node.hide_target(idx)
			SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
			_update_target_objective()
			if _targets_remaining <= 0 and _on_targets_wave_cleared():
				_complete_step()
				return
		_stash_and_restage()
		return
	if _last_shot_qualifies:
		_complete_step()
	else:
		_stash_and_restage()


# Called when the active wave's targets are all cleared. Returns true if the
# whole step is done, false if the drill advanced to a new wave / beat.
func _on_targets_wave_cleared() -> bool:
	match _current_step_id():
		STEP_SHOOT_TARGETS:
			if _targets_phase == 0:
				_show_targets_wave(1)
				return false
			# High wave cleared → the toggle-off beat. Completion happens in
			# _process once the player scrolls elevation back off.
			_targets_phase = 2
			_targets = []
			if _target_node != null and is_instance_valid(_target_node):
				_target_node.clear()
			_hud.set_step(_step_index, _step_ids.size(),
				"Pick Your Spot",
				"Nice. Your lifted shot is still on, though — scroll the wheel DOWN to switch back to a flat shot, or your next one sails high too.",
				"Elevation is a toggle you manage: up to lift, down to flatten.")
			_hud.set_objective("Scroll down to go flat.")
			return false
		STEP_SHOOT_GOALIE:
			return true
	return true


# Sets the copy + target set for one wave of the Pick Your Spot drill.
func _show_targets_wave(phase: int) -> void:
	_targets_phase = phase
	_target_noun = "Targets hit"
	if phase == 0:
		_hud.set_step(_step_index, _step_ids.size(),
			"Pick Your Spot",
			"Three targets are lit across the net. Drag each shot toward one to knock it out — any order.",
			"Aim is the direction you drag, not where the cursor sits.")
		_show_target_set(_LOW_TARGETS)
	else:
		_hud.set_step(_step_index, _step_ids.size(),
			"Pick Your Spot",
			"Now two up high. Scroll the wheel UP to switch to a lifted shot — it's a toggle, so it stays on. Put both in the top corners.",
			"Scroll up first; you'll see the puck rise off the ice when you shoot.")
		_show_target_set(_HIGH_TARGETS)


# Spawns a fresh set of ring targets and resets the hit bookkeeping.
func _show_target_set(targets: Array[Vector2]) -> void:
	_ensure_target_node()
	_targets = targets
	_target_hit = []
	for _i: int in _targets.size():
		_target_hit.append(false)
	_targets_remaining = _targets.size()
	_target_node.show_targets(_targets, _GOAL_PLANE_Z, _TARGET_FRONT_OFFSET)
	_update_target_objective()


func _update_target_objective() -> void:
	var hit: int = _targets.size() - _targets_remaining
	_hud.set_objective("%s — %d / %d" % [_target_noun, hit, _targets.size()])


func _ensure_target_node() -> void:
	if _target_node == null or not is_instance_valid(_target_node):
		_target_node = TutorialTargets.new()
		add_child(_target_node)


# Puts the puck back on the player's stick for another attempt.
func _give_puck_to_player() -> void:
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(Vector3(_skater.global_position.x, _ICE_Y, _skater.global_position.z))
	_puck.linear_velocity = Vector3.ZERO
	_puck.set_carrier(_skater)
	# set_carrier only pins the puck to the blade; it does NOT tell the controller
	# it now has the puck. Without this the controller's has_puck stays false, so
	# _release_wrister / _release_slapper short-circuit and puck_release_requested
	# never fires — the player physically can't shoot. The Basics shot steps avoid
	# this by dropping the puck on the ice for a natural pickup (which routes
	# through on_puck_picked_up_network); the shooting drill hands it over directly,
	# so we replicate that notification here.
	_local_controller.on_puck_picked_up_network()


# Stash the puck off-rink (so a crossing can't re-trigger) and schedule the
# re-stage that hands it back to the player.
func _stash_and_restage() -> void:
	_place_puck(Vector3(100.0, _ICE_Y, 100.0))
	_shoot_restage_timer = _REATTEMPT_DELAY


# Clears all shooting-drill state: targets, the stationary goalie, the watch
# loop. Safe to call on any step (no-op when no shooting drill is active).
func _teardown_shooting() -> void:
	_shooting_active     = false
	_shoot_restage_timer = -1.0
	_targets             = []
	_target_hit          = []
	_targets_remaining   = 0
	_targets_phase       = 0
	if _target_node != null and is_instance_valid(_target_node):
		_target_node.clear()
	GameManager.despawn_tutorial_goalie()
