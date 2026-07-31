extends Node

# ── Step identifier aliases ───────────────────────────────────────────────────
# Step IDs live in TutorialRegistry (to avoid a preload cycle); re-exported
# here so the rest of this file reads like the original constant references.
const STEP_SKATE:       int = TutorialRegistry.STEP_SKATE
const STEP_SPRINT:      int = TutorialRegistry.STEP_SPRINT
const STEP_STAMINA:     int = TutorialRegistry.STEP_STAMINA
const STEP_BRAKE:       int = TutorialRegistry.STEP_BRAKE
const STEP_STICKHANDLE: int = TutorialRegistry.STEP_STICKHANDLE
const STEP_DEFLECT:     int = TutorialRegistry.STEP_DEFLECT
const STEP_BLADE_LIFT:  int = TutorialRegistry.STEP_BLADE_LIFT
const STEP_DROP_PUCK:   int = TutorialRegistry.STEP_DROP_PUCK
const STEP_SHOOT_WRIST:    int = TutorialRegistry.STEP_SHOOT_WRIST
const STEP_SHOOT_BACKHAND: int = TutorialRegistry.STEP_SHOOT_BACKHAND
const STEP_SHOOT_TARGETS: int = TutorialRegistry.STEP_SHOOT_TARGETS
const STEP_SHOOT_SLAP:    int = TutorialRegistry.STEP_SHOOT_SLAP
const STEP_ONE_TIMER:     int = TutorialRegistry.STEP_ONE_TIMER
const STEP_SHOOT_FINISH:  int = TutorialRegistry.STEP_SHOOT_FINISH
const STEP_QUICK_PASS:  int = TutorialRegistry.STEP_QUICK_PASS
const STEP_TOUCH_PASS:  int = TutorialRegistry.STEP_TOUCH_PASS
const STEP_SAUCER_PASS: int = TutorialRegistry.STEP_SAUCER_PASS
const STEP_RECEIVE:     int = TutorialRegistry.STEP_RECEIVE
const STEP_STICKCHECK:  int = TutorialRegistry.STEP_STICKCHECK
const STEP_BODY_CHECK:  int = TutorialRegistry.STEP_BODY_CHECK
const STEP_STICK_LIFT:  int = TutorialRegistry.STEP_STICK_LIFT
const STEP_SHOT_BLOCK:  int = TutorialRegistry.STEP_SHOT_BLOCK
const STEP_OFFSIDES:    int = TutorialRegistry.STEP_OFFSIDES


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
# Failed-feed retirement (deflect / blade-lift / receive / shot-block /
# one-timer feeds — see _feed_missed): a feed is decisively over once it goes
# dead slow, gets behind the player, or is receding beyond recovery range —
# restage then, rather than waiting for the puck to glide to rest at the
# boards (at the ice's ~0.49 m/s² glide decel a deflection sent flying at pace
# took ten-plus seconds to decay to the old 0.3 m/s rest threshold). The
# flight cap is a safety net for anything pathological (a wild ricochet
# orbiting the rink at pace, always "approaching" on some leg).
const _FEED_DEAD_SPEED:    float = 1.0   # m/s below which a loose feed is dead
const _FEED_PAST_PLAYER_M: float = 4.0   # up-lane (+Z) margin behind the player
const _FEED_GONE_DISTANCE: float = 6.0   # m from the player, receding = gone
const _FEED_MAX_FLIGHT_S:  float = 5.0   # hard cap; real feeds land in < 3 s
# Stick lift: how far a stray-poked loose puck may squirt from the carrier
# before it's clearly out of the contest and re-pins to his blade (paired with
# the _FEED_DEAD_SPEED rest test — same rationale as feed retirement).
const _REPIN_GONE_DISTANCE: float = 4.0

# ── Stick Basics tuning ───────────────────────────────────────────────────────
# Stickhandle: forehand↔backhand crossings required, and how far the blade
# must swing off-centre (in the skater's local X) before a side counts —
# hysteresis so jitter around centre doesn't rack up crossings.
const _STICKHANDLE_CROSSINGS: int   = 4
const _STICKHANDLE_SIDE_X:    float = 0.3
# Deflect: a grounded feed slow enough to read but quick enough to feel like a
# shot worth tipping. Well under the natural-deflect threshold (22 receiver-
# relative), so without Q held the blade would simply CATCH it — holding Q is
# exactly what turns the catch into the tip, which is the lesson.
const _DEFLECT_FEED_SPEED: float = 12.0
# Blade lift: an airborne lob the raised blade bats down. Horizontal pace +
# fixed vertical launch put the puck ~0.8 m off the ice as it reaches the
# player (fired from _FEED_DISTANCE away).
const _LOB_FEED_SPEED_XZ: float = 10.0
const _LOB_FEED_VY:       float = 4.9
# How far up-ice the feeder bot stands (deflect / blade-lift steps). Every feed
# in the tutorial comes off a visible bot's stick — a puck launching from
# off-screen leaves the camera chasing an arrow instead of showing the play.
const _FEED_DISTANCE: float = 9.0
# How far in front of the player a handed-back puck is staged. Drills never
# place the puck ON the stick — skating onto it runs the normal pickup path,
# which is what keeps controller/possession bookkeeping honest.
const _STAGE_PUCK_AHEAD: float = 1.2

# ── Passing module tuning ─────────────────────────────────────────────────────
# Player and teammate staging for the pass drills (player faces -Z at the bot).
const _PASS_PLAYER_POS: Vector3 = Vector3(0.0, 1.0, 2.0)
const _PASS_PUPPET_POS: Vector3 = Vector3(0.0, 1.0, -7.0)
# Saucer drill receiver sits DEEP. A LOW saucer at quick-shot pace is airborne
# for ~6 m off the blade (hang time × pass speed), and an airborne puck sails
# clean over a grounded blade (PuckReceptionRules.blade_can_interact) — on the
# standard 9 m lane the saucer reached the receiver still in the air and flew
# past him. The deep lane lets it land mid-flight and slide the rest of the way
# in, grounded and catchable — the same landing-runway bound the bots' saucer
# doctrine enforces (AIActionScoring.saucer_max_launch_speed): a shorter feed
# needs a softer flip.
const _SAUCER_PUPPET_POS: Vector3 = Vector3(0.0, 1.0, -12.0)
# The saucer wall stands this far in front of the player's staging spot —
# INSIDE the saucer's airborne span, but with enough runway that the saucer
# has climbed past board height (~0.12 m by ~1 m out) even when the player
# drifts a stride downlane before tapping the pass. (Midway down the deep
# lane the saucer has already landed and would clank off the board just like
# a flat pass.)
const _SAUCER_WALL_AHEAD: float = 4.0
# Touch pass: max normalized wrister charge that still reads as a soft touch
# pass. Above this the drill takes the puck back — physics would often bounce
# a hot feed off the receiver anyway, but the explicit gate keeps the lesson
# deterministic instead of depending on the bot's blade angle.
const _TOUCH_PASS_MAX_CHARGE: float = 0.55
# Saucer drill wall: knee-high board across the passing lane, a few strides in
# front of the passer (see _SAUCER_WALL_AHEAD). Low enough that a LOW saucer
# (0.26 m apex) clears it at any legal pass pace; a flat pass clanks off.
const _PASS_WALL_SIZE: Vector3 = Vector3(1.8, 0.12, 0.08)
# Receiving: soft feeds catch at any blade angle (< the 22 m/s receiver-
# relative deflect threshold); hot feeds sit between the 22 threshold and the
# 30 squared-blade ceiling, so they stick only when the blade is squared to
# the line (or the receiver gives ground to soften the relative speed).
const _RECEIVE_SPEED_SOFT:      float = 12.0
const _RECEIVE_SPEED_HOT:       float = 24.0
const _RECEIVE_CATCHES_PER_WAVE: int  = 2
# A missed pass that slides this far beyond the receiver is decisively missed —
# retire it there rather than waiting for it to settle at the boards.
const _PASS_MISS_BEYOND_M: float = 2.0

# ── Reps & spawn variation ────────────────────────────────────────────────────
# One-shot contact skills complete after several successful reps, restaged from
# varied spots so the skill generalises (one strip can be a fluke; three from
# different approaches is a skill). Steps absent from the table need one rep.
# Timing skills that already re-fire until success (one-timer, shot block) and
# the execution-gated passes (touch, saucer) stay single-rep.
const _STEP_REPS: Dictionary = {
	TutorialRegistry.STEP_STICKCHECK: 3,
	TutorialRegistry.STEP_STICK_LIFT: 2,
	TutorialRegistry.STEP_BODY_CHECK: 2,
	TutorialRegistry.STEP_DEFLECT: 2,
	TutorialRegistry.STEP_BLADE_LIFT: 2,
	TutorialRegistry.STEP_QUICK_PASS: 2,
}
# (player spot, carrier spot) per stick-check rep — head-on, then two fresh
# approach angles.
const _STICKCHECK_SPOTS: Array = [
	[Vector3(0.0, 1.0, 4.0), Vector3(0.0, 1.0, 0.0)],
	[Vector3(-4.5, 1.0, -2.0), Vector3(-1.0, 1.0, -5.0)],
	[Vector3(4.0, 1.0, -9.0), Vector3(1.5, 1.0, -5.5)],
]
# (player spot, target spot) per body-check rep — the straight lane, then a
# diagonal so the second hit is lined up from a different angle.
const _BODY_CHECK_SPOTS: Array = [
	[Vector3(-4.0, 1.0, 0.0), Vector3(4.0, 1.0, 0.0)],
	[Vector3(3.0, 1.0, 5.0), Vector3(-2.0, 1.0, -1.0)],
]
# Feeder spots per deflect / blade-lift rep — a straight-on feed, then an
# angled feed from the wing (the player holds position at z = 5).
const _FEED_SPOTS: Array = [
	Vector3(0.0, 1.0, 5.0 - _FEED_DISTANCE),
	Vector3(-4.5, 1.0, 6.5 - _FEED_DISTANCE),
]
# Teammate spots per quick-pass rep — the receiver relocates so the second
# pass takes a fresh read and aim, not a repeat click.
const _QUICK_PASS_SPOTS: Array = [
	Vector3(0.0, 1.0, -7.0),
	Vector3(-5.0, 1.0, -4.5),
]

# ── References ────────────────────────────────────────────────────────────────

var tutorial_id: String = TutorialRegistry.MOVEMENT_ID

var _local_record:     PlayerRecord    = null
var _local_controller: LocalController = null
var _skater:           Skater          = null
var _puck:             Puck            = null
# Puppeted bot used as a tutorial demo partner (stickcheck target, body-check
# target, pass receiver/feeder, shot-block shooter). Real bots get the team_id
# resolver wired correctly so stickcheck (apply_poke_check) and body-check
# signal filtering behave as they do in normal gameplay. Passing drills spawn
# it on team 0 (a teammate); defense drills on team 1 (an opponent).
# See GameManager.spawn_tutorial_bot.
var _puppet_record: PlayerRecord = null
var _puppet_team:   int          = 1

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
var _stamina_exhaust_seen:     bool  = false
var _stickhandle_crossings:    int   = 0
var _stickhandle_side:         int   = 0     # -1 / +1 once the blade commits to a side
var _drop_seen:                bool  = false # DROP_PUCK: nudge fired, waiting on re-pickup
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

# Prefire timer: counts down during a step's initial pause before launching
# the puck. -1 = no fire pending. _process dispatches to the right fire
# helper for the active step when it reaches 0. Feed steps also reuse it as
# the between-attempts beat.
var _prefire_timer: float = -1.0

# Seconds the current feed has been loose in flight — advanced by _feed_missed
# while its step watches the feed, zeroed at each fire. Backs the
# _FEED_MAX_FLIGHT_S safety cap.
var _feed_flight_time: float = 0.0

# Rep tracking for the multi-rep steps (_STEP_REPS). _rep_restage_timer counts
# down the beat between a credited rep and the next spawn variation; the
# step's own watch logic pauses while it runs.
var _reps_done:         int   = 0
var _rep_restage_timer: float = -1.0

# ── Shooting module (drill-based) ─────────────────────────────────────────────
# The net the tutorial player attacks (team 0 shoots toward -Z) and its lateral
# bound for goal/target detection.
const _GOAL_PLANE_Z:  float = -GameRules.GOAL_LINE_Z
const _NET_HALF_WIDTH: float = GameRules.NET_HALF_WIDTH
# Target sets, as (x = lateral, y = height) in the goal plane. The stationary
# goalie stands in the net for the whole Pick Your Spot drill, so the low set
# reads as the holes he leaves: low corners beside the pads, and the centre
# target is the five-hole (his stance is opened via snap_to_standing_pose).
const _LOW_TARGETS: Array[Vector2] = [
	Vector2(-0.62, 0.30), Vector2(0.0, 0.24), Vector2(0.62, 0.30)]
const _HIGH_TARGETS: Array[Vector2] = [
	Vector2(-0.62, 0.95), Vector2(0.62, 0.95)]
# Hit tolerance (m) around a target's centre — matched to the bullseye's drawn
# outer radius (TutorialTargets._BANDS), so hitting the target you SEE gives
# credit. Credit lands when the puck reaches the net-plane on the bullseye,
# instead of requiring it to cross cleanly through into the net.
const _TARGET_RADIUS:       float = 0.34
const _TARGET_FRONT_OFFSET: float = 0.10  # float the bullseyes just in front of the net
# Saucer wave wall: across the shooting lane, this far in front of the shooter.
const _TARGET_WALL_SIZE:  Vector3 = Vector3(2.0, 0.12, 0.08)
const _TARGET_WALL_AHEAD: float   = 2.2
# Where the HIGH wave restages the shooter. The top rung is an IN-TIGHT tool,
# so it gets its own station rather than sharing the slot: from SLOT_DIST_M a
# HIGH shot needs ~10.6 m/s to drop onto the 0.95 m targets — under the 10 m/s
# wrister floor, i.e. only makeable by bottoming out the power band — while
# from here it wants ~15 m/s and a full rip still crests at 1.07 m, under the
# 1.22 m crossbar, so the doorstep roof cannot sail. The same geometry is what
# makes the pairing teach range: MID tops out at 0.79 m from here and cannot
# reach these targets at any charge, having just cleared them from the slot.
const _DOORSTEP_DIST_M: float = 2.5

# Team 0 attacks toward -Z; the shot-resolution helpers project puck travel onto
# this axis (matches PenaltyShotRules' attack_dir convention).
const _ATTACK_DIR_Z: float = -1.0
# Dead-puck detection for a shot in flight. A shot is retired the instant it
# passes the net (a goal, a wide miss, or over the bar) OR goes dead — stops
# advancing toward the net for _SHOT_STALL_GRACE after the release settles. This
# is what makes a wide miss (or a save that stops the puck) reset promptly
# instead of waiting for the puck to trickle to a halt in the corner.
const _SHOT_REST_SPEED:  float = 0.5   # m/s of forward progress that counts as stopped
const _SHOT_STALL_GRACE: float = 0.4   # s stopped before the shot is called dead
const _SHOT_START_GRACE: float = 0.35  # s after release before the dead-puck rules arm
const _SHOT_BACKWARD_TOL: float = 0.75 # m the puck may retreat from its furthest point before a rebound is called dead
const _SHOT_MAX_TIME:    float = 3.0   # s safety cap — retire a wedged shot no matter what
# Long per-skater pickup cooldown applied at release so the loose puck can't be
# re-collected mid-flight. Removed the moment the drill hands the puck back.
const _PICKUP_LOCK_S:    float = 999.0
# Player's shooting spot for the slot drills, and the deeper start for Finish.
const _FINISH_START_Z: float = -10.0

var _shooting_active:     bool  = false
var _last_shot_qualifies: bool  = false   # did the last shot match the drill's required type
var _wrist_peak_charge:   float = 0.0     # peak normalised wrister charge this aim
var _shoot_restage_timer: float = -1.0    # countdown to re-stage the puck on the stick
# Shot-in-flight tracking. Once the player releases, the attempt is LIVE and the
# puck is locked from re-pickup (via a skater cooldown) until it resolves and
# restages — so mashing the shoot button can't just re-collect a rebound and
# keep possession. Resolution watches forward progress toward the net to call a
# wide/dead miss promptly (see TutorialShotRules.shot_missed).
var _shot_live:          bool  = false
var _shot_start_z:       float = 0.0
var _shot_max_progress:  float = 0.0
var _shot_last_progress: float = 0.0
var _shot_stall_time:    float = 0.0
var _shot_air_time:      float = 0.0
var _targets:          Array[Vector2] = []
var _target_hit:       Array[bool]    = []
var _targets_remaining: int = 0
# 0 flat wave, 1 saucer wave, 2 MID slot wave, 3 HIGH doorstep wave,
# 4 toggle-off beat.
var _targets_phase:     int = 0
var _target_noun:       String = "Targets hit"
var _target_node: TutorialTargets = null
var _wall_node:   TutorialWall    = null
var _on_shooting_shot_callable: Callable = Callable()

# ── Passing module state ──────────────────────────────────────────────────────
var _passing_active:     bool  = false
var _pass_live:          bool  = false   # a pass attempt in flight toward the teammate
var _pass_qualifies:     bool  = false   # last release matched the drill's required type
var _pass_hot:           bool  = false   # TOUCH_PASS: released above the soft-pass ceiling
var _pass_restage_timer: float = -1.0
var _pass_stall_time:    float = 0.0
var _pass_air_time:      float = 0.0
var _receive_wave:       int   = 0
var _receive_catches:    int   = 0
var _on_passing_shot_callable: Callable = Callable()

# Whether the elevation corrective alert is currently showing, so the per-frame
# prompt update only clears an alert it set itself (and never stomps another
# alert, e.g. the touch-pass "too hot" prompt).
var _elev_alert_shown: bool = false

# Connected callables stored for safe disconnection
var _on_one_timer_callable:        Callable = Callable()
var _on_body_check_callable:       Callable = Callable()
var _on_regular_shot_in_one_timer: Callable = Callable()
var _on_stickcheck_callable:       Callable = Callable()
var _on_stick_lift_callable:       Callable = Callable()
var _on_puck_touch_callable:       Callable = Callable()
var _on_block_callable:            Callable = Callable()
var _on_nudge_callable:            Callable = Callable()

# Live keybinding names, substituted into step copy via String.format so the
# instructions always show what the player actually has bound (see
# PlayerPrefs.action_display). Built once in _ready — rebinding mid-tutorial
# isn't a live path (the options popup isn't reachable inside the tutorial).
var _key_tokens: Dictionary = {}


# Constructor sets the tutorial id; game_scene.gd passes the id selected by
# NetworkManager.tutorial_id when it instantiates the manager.
func _init(id: String = TutorialRegistry.MOVEMENT_ID) -> void:
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

	_build_key_tokens()
	_build_steps()
	if _step_ids.is_empty():
		push_error("TutorialManager: no steps for tutorial id '%s'" % tutorial_id)
		return

	_hud = TutorialHUD.new()
	_hud.set_tutorial_id(tutorial_id)
	add_child(_hud)
	_hud.skip_pressed.connect(_on_skip)
	_hud.reset_pressed.connect(_on_reset)
	# Teaching copy follows the ACTIVE device (not just "gamepad allowed"), so a
	# mouse player who clicked Play sees keyboard prose and a pad player sees pad
	# prose — and it hot-swaps if they switch mid-tutorial (auto-disconnected on free).
	InputDeviceTracker.device_changed.connect(_on_device_changed)

	_begin_step(0)


func _exit_tree() -> void:
	_disconnect_all_signals()
	_free_puppet()
	_teardown_shooting()
	_teardown_passing()
	# Do NOT clear NetworkManager.is_tutorial_mode here. The continuation path
	# (Next: <tutorial> button → start_tutorial(next_id) → change_scene_to_file)
	# sets is_tutorial_mode = true BEFORE the deferred scene change tears down
	# this node — clearing it in _exit_tree would race with that and make the
	# new game_scene._ready miss the tutorial spawn. Every legitimate exit path
	# (HUD Exit / Free Play / SideMenu launchers) sets the right flag itself.


# ── Keybinding tokens ─────────────────────────────────────────────────────────

func _build_key_tokens() -> void:
	_key_tokens = _pad_key_tokens() if InputDeviceTracker.is_gamepad_active() else _keyboard_key_tokens()


func _keyboard_key_tokens() -> Dictionary:
	return {
		"move_keys": "%s, %s, %s, %s" % [
			PlayerPrefs.action_display("move_up"),
			PlayerPrefs.action_display("move_left"),
			PlayerPrefs.action_display("move_down"),
			PlayerPrefs.action_display("move_right")],
		"sprint":         PlayerPrefs.action_display("sprint"),
		"brake":          PlayerPrefs.action_display("brake"),
		"hit":            PlayerPrefs.action_display("hit"),
		"shoot":          PlayerPrefs.action_display("shoot"),
		"quick_pass":     PlayerPrefs.action_display("quick_pass"),
		"slapshot":       PlayerPrefs.action_display("slapshot"),
		"block":          PlayerPrefs.action_display("block"),
		"stick_lift":     PlayerPrefs.action_display("stick_lift"),
		"elevation_up":   PlayerPrefs.action_display("elevation_up"),
		"elevation_down": PlayerPrefs.action_display("elevation_down"),
	}


# Gamepad token set: the same slots resolved to pad glyphs. Movement is the left
# stick; aim/shoot are the right stick + triggers (fixed); the discrete actions
# read the player's live pad binds so a rebind shows here too. The step prose that
# describes a device-specific MECHANIC (cursor aim, drag-speed wrister) has its own
# pad variant via _pick(); these tokens fill the button names inside both.
func _pad_key_tokens() -> Dictionary:
	return {
		"move_keys":      "Left Stick",
		"sprint":         ControllerGlyphs.joy_label(PlayerPrefs.pad_button("sprint")),
		"brake":          ControllerGlyphs.joy_label(PlayerPrefs.pad_button("brake")),
		"hit":            ControllerGlyphs.joy_label(PlayerPrefs.pad_button("hit")),
		"shoot":          ControllerGlyphs.trigger_label(true),
		"quick_pass":     ControllerGlyphs.joy_label(PlayerPrefs.pad_button("quick_pass")),
		"slapshot":       ControllerGlyphs.trigger_label(false),
		"block":          ControllerGlyphs.joy_label(PlayerPrefs.pad_button("block")),
		"stick_lift":     ControllerGlyphs.joy_label(PlayerPrefs.pad_button("stick_lift")),
		"elevation_up":   ControllerGlyphs.joy_label(PlayerPrefs.pad_button("elevation_up")),
		"elevation_down": ControllerGlyphs.joy_label(PlayerPrefs.pad_button("elevation_down")),
	}


func _fmt(text: String) -> String:
	return text.format(_key_tokens)


# Device-aware copy: the pad variant in controller mode, else the mouse/keyboard
# one. Used for the steps whose MECHANIC differs by device — the cursor's aim-by-
# position + drag-speed wrister vs. the pad's right-stick aim + push-magnitude
# commit. Both variants still run through _fmt, so their {token}s resolve to the
# active device's button labels. Steps that read the same on both devices keep a
# single string. (See docs/gameplay-design.md for the two schemes.)
func _pick(keyboard_copy: String, pad_copy: String) -> String:
	return pad_copy if InputDeviceTracker.is_gamepad_active() else keyboard_copy


# TutorialStep factory that runs every string through the keybinding tokens.
func _step(title: String, instruction: String, hint: String = "") -> TutorialStep:
	return TutorialStep.new(_fmt(title), _fmt(instruction), _fmt(hint))


# Mid-step copy swap (wave changes, two-beat steps), tokenised the same way.
func _set_live_copy(title: String, instruction: String, hint: String) -> void:
	_hud.set_step(_step_index, _step_ids.size(), _fmt(title), _fmt(instruction), _fmt(hint))


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
			return _step(
				"Skate",
				"Press {move_keys} to skate around the ice.",
				"Hold a direction to build up speed — you keep gliding when you let go.")
		STEP_SPRINT:
			return _step(
				"Sprint",
				"Hold {sprint} while skating to sprint for a burst of speed.",
				"Sprinting widens your turn radius — use it in straight-line bursts.")
		STEP_STAMINA:
			return _step(
				"Stamina",
				"Sprint burns the stamina ring around your skater. Hold {sprint} and keep sprinting until it runs dry — go ahead, gas out.",
				"The ring hides while it's full and turns amber when you're low. Carrying the puck drains it faster.")
		STEP_BRAKE:
			return _step(
				"Brake",
				"Hold {brake} to brake hard and stop quickly.",
				"It kills your speed in any direction — stop on a dime to change lanes or hold your ground.")
		STEP_STICKHANDLE:
			return _step(
				"Stickhandling",
				_pick(
					"Your blade follows your cursor — every frame, no button. Pick up the puck and sweep the cursor side to side to dangle it across your body.",
					"Your blade follows the right stick — every frame, no button. Pick up the puck and sweep the right stick side to side to dangle it across your body."),
				"Big, smooth sweeps. The blade lifts slightly through centre, so the puck rides forehand to backhand.")
		STEP_DEFLECT:
			return _step(
				"Deflect",
				_pick(
					"Your teammate's going to feed you — don't catch it. Tap {elevation_up} to raise your loft to LOW, hold {stick_lift}, and angle the blade with your cursor to tip the pass as it arrives.",
					"Your teammate's going to feed you — don't catch it. Tap {elevation_up} to raise your loft to LOW, hold {stick_lift}, and angle the blade with the right stick to tip the pass as it arrives."),
				"Holding {stick_lift} means redirect, don't receive. At LOW loft the tip flicks the puck UP — that's the deflection goal.")
		STEP_BLADE_LIFT:
			return _step(
				"Blade Lift",
				"Now play the air. Tap {elevation_up} twice more to take your loft from LOW up to HIGH, hold {stick_lift} to raise your blade off the ice, and bat your teammate's lob down out of the air.",
				"The raised blade only plays airborne pucks — a grounded pass slides right under it. HIGH knocks the puck DOWN to the ice.")
		STEP_DROP_PUCK:
			return _step(
				"Drop the Puck",
				"With the puck, tap {stick_lift} to drop it — a soft push off the blade that keeps your momentum. Drop it, then skate onto it again.",
				"Slip it through a defender's feet and collect it on the far side — the nutmeg.")
		STEP_SHOOT_WRIST:
			return _step(
				"Wrist Shot",
				_pick(
					"You've got the puck. Hold {shoot}, drag toward the net, and release. The way you drag is your aim — and the faster you drag, the harder the shot.",
					"You've got the puck. Hold {shoot}, point the right stick at the net, and release. The stick direction is your aim — and the harder you push the stick, the harder the shot."),
				_pick(
					"A slow sweep is a soft pass — snap the drag toward the net to really rip it.",
					"A gentle push is a soft pass — shove the stick to the edge to really rip it."))
		STEP_SHOOT_BACKHAND:
			return _step(
				"Backhand",
				_pick(
					"Same wrister, other face of the blade: hold {shoot} and curl the drag across your body, then release — that's the backhand. It comes off softer than your forehand, but in tight it's the release you already have.",
					"Same wrister, other face of the blade: hold {shoot} and point the stick across your body, then release — that's the backhand. It comes off softer than your forehand, but in tight it's the release you already have."),
				_pick(
					"A straight-line drag always reads as forehand — the backhand is the deliberate curl around your body. It won't beat anyone with pace, so pick your spot.",
					"Pointing straight ahead always reads as forehand — the backhand is aiming back across your body. It won't beat anyone with pace, so pick your spot."))
		STEP_SHOOT_TARGETS:
			# Live copy is set per-wave by _show_targets_wave; this is the wave-0 default.
			return _step(
				"Pick Your Spot",
				"A goalie's in the net — but he's frozen stiff. Three targets mark the holes he leaves low. Stay flat and knock each one out — any order.",
				_pick(
					"Aim is the direction you drag, not where the cursor sits.",
					"Aim is the direction you push the stick."))
		STEP_SHOOT_SLAP:
			return _step(
				"Slapshot",
				_pick(
					"Hold {slapshot} to wind up a slapshot. It fires toward your mouse, and the shot's direction locks the moment you press — so aim with the cursor first. You'll keep gliding, but you can't steer or change the shot mid-wind-up.",
					"Hold {slapshot} to wind up a slapshot. It fires where the right stick points, and the shot's direction locks the moment you press — so aim the stick first. You'll keep gliding, but you can't steer or change the shot mid-wind-up."),
				_pick(
					"Point the cursor where you want it before you press. The longer you hold, the harder it goes.",
					"Point the stick where you want it before you press. The longer you hold, the harder it goes."))
		STEP_ONE_TIMER:
			return _step(
				"One-Timer",
				"Your teammate's about to slide a pass across from the far dot. Hold {slapshot} to wind up before it arrives, then release the instant it hits your tape.",
				"Start charging {slapshot} now — don't wait for the puck to get there.")
		STEP_SHOOT_FINISH:
			return _step(
				"Finish",
				"Last one. You've got the puck and a goalie ahead of you. Score however you like.",
				"Everything you've practiced is fair game — pick a corner, go five-hole, walk him side to side.")
		STEP_QUICK_PASS:
			return _step(
				"Quick Pass",
				_pick(
					"That instant snap on {quick_pass} is your pass — flat, fixed pace, fired toward your cursor the moment you tap. Put one on your teammate's blade.",
					"That instant snap on {quick_pass} is your pass — flat, fixed pace, fired where the right stick points the moment you tap. Put one on your teammate's blade."),
				_pick(
					"Lead with the cursor: point at their blade, tap {quick_pass}.",
					"Lead with the stick: point at their blade, tap {quick_pass}."))
		STEP_TOUCH_PASS:
			return _step(
				"Touch Pass",
				_pick(
					"Now with the wrister: hold {shoot} and sweep slowly toward your teammate. Sweep speed is pass weight — a hard flick at this range just bounces off their blade.",
					"Now with the wrister: hold {shoot} and push the stick gently toward your teammate. Push strength is pass weight — a hard shove at this range just bounces off their blade."),
				_pick(
					"Feather it. The slow, deliberate sweep is a genuinely soft touch pass.",
					"Feather it. A soft, deliberate push is a genuinely soft touch pass."))
		STEP_SAUCER_PASS:
			return _step(
				"Saucer Pass",
				"A board's in the passing lane — a flat pass can't get through. Tap {elevation_up} to loft the pass, then {quick_pass}: the saucer flips over the board and lands flat on the far side.",
				"Same quick pass, lofted. A LOW saucer clears blades and boards mid-flight, then sits down and slides to the target.")
		STEP_RECEIVE:
			# Live copy is swapped per-wave; this is the soft-feed default.
			return _step(
				"Receiving",
				"Your teammate's feeding you passes. Meet each one with your blade to catch it.",
				"A soft pass sticks to almost any blade angle — just get the blade on the line.")
		STEP_STICKCHECK:
			return _step(
				"Stick Check",
				"Skate your stick into the opponent's puck to knock it loose — that's a stick check.",
				"Get close and sweep your stick through the puck.")
		STEP_BODY_CHECK:
			return _step(
				"Body Check",
				"Build up speed, hold {hit} to commit, and drive straight through the opponent to knock them off the puck.",
				"Committing with {hit} throws your weight into the hit — you land it far harder AND shrug off the collision. An uncommitted bump barely moves them.")
		STEP_STICK_LIFT:
			return _step(
				"Stick Lift",
				"Tap {elevation_up} three times to take your loft all the way to HIGH, get under the opponent's stick, and hold {stick_lift} to lift it — that pops the puck off their blade.",
				"Same gesture as the blade lift: ride your blade high, slide it beneath their stick, and hold {stick_lift} to knock the puck free.")
		STEP_SHOT_BLOCK:
			return _step(
				"Shot Block",
				"A shot is coming at you. Hold {block} to drop into a blocking stance, get your body in its path, and eat it.",
				"Line up with the puck — the crouch widens you. The step completes when a shot actually hits you.")
		STEP_OFFSIDES:
			return _step(
				"Offsides",
				"The puck has to cross the blue line into the attacking zone before you do. You went in first, so you're offside — and now you're a ghost until you skate back out past the blue line.",
				"Skate back toward your own end and cross the blue line to reset.")
	push_error("TutorialManager: unknown step id %d" % step_id)
	return TutorialStep.new("", "", "")


# Returns the active step's ID, or -1 if outside the step list. Helpers use
# this in their match dispatchers so the index→id mapping stays in one place.
func _current_step_id() -> int:
	if _step_index < 0 or _step_index >= _step_ids.size():
		return -1
	return _step_ids[_step_index]


# Steps that override their own copy mid-step (two-beat gates / per-wave live copy).
# The device hot-swap skips them so it can't clobber the beat-specific text; their
# next live-copy beat re-picks with the now-current device via _pick.
func _step_has_live_copy(step_id: int) -> bool:
	return step_id == STEP_STAMINA or step_id == STEP_OFFSIDES \
		or step_id == STEP_SHOOT_TARGETS or step_id == STEP_RECEIVE


# Active-device handoff (InputDeviceTracker.device_changed): re-resolve the copy
# tokens and re-emit the current step so its prose + button glyphs match whoever's
# driving now. Skips live-copy steps (see above) and the between-steps gap.
func _on_device_changed(_is_gamepad: bool) -> void:
	if _hud == null:
		return
	_build_key_tokens()
	var step_id: int = _current_step_id()
	if step_id < 0 or _step_has_live_copy(step_id):
		return
	var step: TutorialStep = _step_def_for(step_id)
	_hud.set_step(_step_index, _step_ids.size(), step.title, step.instruction, step.hint)


# ── Step sequencing ───────────────────────────────────────────────────────────

# The close-quarters steps (movement, stickhandling, the drop) frame best on
# the player-locked camera, which centers on the skater rather than zooming
# out to chase a stashed or nearby puck.
func _step_uses_locked_camera(step_id: int) -> bool:
	return step_id == STEP_SKATE or step_id == STEP_SPRINT \
		or step_id == STEP_STAMINA or step_id == STEP_BRAKE \
		or step_id == STEP_STICKHANDLE or step_id == STEP_DROP_PUCK


func _begin_step(index: int) -> void:
	_disconnect_all_signals()
	_teardown_shooting()
	_teardown_passing()
	_step_index             = index
	_step_timer             = 0.0
	_hint_timer             = 0.0
	_complete_flash_timer   = 0.0
	_prefire_timer          = -1.0
	_feed_flight_time       = 0.0
	_wrister_aim_start      = -1.0
	_offside_ghost_seen     = false
	_stamina_exhaust_seen   = false
	_stickhandle_crossings  = 0
	_stickhandle_side       = 0
	_drop_seen              = false
	_one_timer_armed        = false
	_one_timer_restage_pending = false
	_elev_alert_shown       = false
	_reps_done              = 0
	_rep_restage_timer      = -1.0

	var step_id: int = _current_step_id()
	var step: TutorialStep = _step_defs[index]
	_hud.set_step(index, _step_ids.size(), step.title, step.instruction, step.hint)
	# Close-quarters steps force the player-locked camera so it sits centered
	# on the skater instead of zooming out toward a stashed puck.
	_local_controller.set_camera_force_locked(_step_uses_locked_camera(step_id))
	# Offsides detection runs only during the OFFSIDES step. Steps that put
	# the player deep in the O-zone with the puck temporarily off-rink
	# (one-timer, shot-block prefire) would otherwise trip offsides and
	# ghost the player.
	GameManager.set_tutorial_offsides_active(step_id == STEP_OFFSIDES)

	match step_id:
		STEP_SKATE, STEP_SPRINT, STEP_STAMINA:
			# Open ice, puck stashed out of the way — sprint and stamina both
			# read cleanest puck-free (carrying changes the drain rate).
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0))
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))  # out of the way

		STEP_BRAKE:
			pass  # player is already on the ice from the stamina/sprint steps

		STEP_STICKHANDLE:
			# Puck dropped just ahead for a natural pickup; crossings are then
			# counted from the blade's side-to-side travel while carrying.
			_local_controller.teleport_to(Vector3(0.0, 1.0, 2.0), Vector2(0.0, -1.0))
			_place_puck(Vector3(0.0, _ICE_Y, 0.5))
			_update_stickhandle_objective()

		STEP_DEFLECT, STEP_BLADE_LIFT:
			# A teammate feeder holds the puck through the read delay (visible
			# on his stick, so the camera frames the play instead of chasing an
			# off-screen arrow), then fires it at the player's live BLADE.
			# Two reps: the second feed comes angled from the wing (_FEED_SPOTS).
			# Completion comes from the puck-touch signal (a deliberate deflect
			# for DEFLECT, a raised-blade touch for BLADE_LIFT).
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0), Vector2(0.0, -1.0))
			_ensure_puppet(_FEED_SPOTS[0], 0)
			GameManager.tutorial_give_puck(_puppet_record)
			_prefire_timer = _PREFIRE_DELAY
			_update_rep_objective()
			_on_puck_touch_callable = func(toucher: Skater) -> void:
				_on_feed_touched(toucher)
			_puck.puck_touched_loose.connect(_on_puck_touch_callable)

		STEP_DROP_PUCK:
			_local_controller.teleport_to(Vector3(0.0, 1.0, 2.0), Vector2(0.0, -1.0))
			_place_puck(Vector3(0.0, _ICE_Y, 0.5))
			_on_nudge_callable = func(_velocity: Vector3) -> void:
				if _current_step_id() == STEP_DROP_PUCK:
					_drop_seen = true
			_local_controller.nudge_requested.connect(_on_nudge_callable)

		STEP_ONE_TIMER:
			# Left-handed players receive from right dot; right-handed from left dot
			# (forehand faces the incoming cross-ice pass)
			_cross_ice_dot_x = 6.0 if PlayerPrefs.is_left_handed else -6.0
			_local_controller.teleport_to(Vector3(_cross_ice_dot_x, 1.0, -GameRules.ICING_FACEOFF_DOT_Z))
			# A teammate at the far dot holds the puck through the read delay
			# (so the camera frames the pass), then slides it across once the
			# prefire timer elapses.
			_ensure_puppet(Vector3(-_cross_ice_dot_x, 1.0, -GameRules.ICING_FACEOFF_DOT_Z), 0)
			GameManager.tutorial_give_puck(_puppet_record)
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
			_local_controller.teleport_to(Vector3(0.0, 1.0, 5.0), Vector2(0.0, -1.0))
			# An opposing shooter holds the puck through the read delay so the
			# player can see where the shot comes from, then fires at their
			# live position when the prefire timer elapses.
			_ensure_puppet(Vector3(0.0, 1.0, -8.0), 1)
			GameManager.tutorial_give_puck(_puppet_record)
			_prefire_timer = _PREFIRE_DELAY
			# Completion is an ACTUAL block: the puck hitting the player's body
			# while they're in the blocking stance — not just holding the pose.
			_on_block_callable = func(blocker: Skater) -> void:
				if blocker == _skater \
						and _local_controller.get_shot_state() == SkaterStateMachine.State.SHOT_BLOCKING:
					_complete_step()
			_puck.puck_body_blocked.connect(_on_block_callable)

		STEP_STICK_LIFT:
			# Same puppet-with-the-puck setup as the stick-check step, but the
			# player strips by lifting the puppet's stick (blade up + under it)
			# instead of poking. Two reps, alternating flanks — the player
			# starts BESIDE the carrier (not in front) so their blade isn't
			# already through the puck at spawn. Positioning lives in
			# _stage_rep; completion only fires for a lift (see the
			# puck_stripped handler); a stray poke re-pins the puck (see _process).
			_update_rep_objective()
			_stage_rep()
			_on_stick_lift_callable = func(_ex: Skater) -> void:
				# A lifted blade can't poke (puck_controller skips the poke path
				# when blade_up), so a strip while the player's blade is up is a
				# stick lift. A no-blade poke falls through to the _process re-pin.
				if _skater.blade_up:
					_complete_rep()
			_puck.puck_stripped.connect(_on_stick_lift_callable)

		STEP_STICKCHECK:
			# Three strips from varied approaches (_STICKCHECK_SPOTS); the spots
			# keep the player far enough back that their blade can't already be
			# through the carrier's puck on frame 1 (2.5 m auto-completed the
			# step at spawn — both reaches overlapped). PuckController pins the
			# granted puck to the bot's blade each physics frame, and the bot's
			# team-1 resolver makes apply_poke_check treat the player as
			# opposing, so the strip fires when the blade sweeps through.
			_update_rep_objective()
			_stage_rep()
			_on_stickcheck_callable = func(_ex: Skater) -> void:
				_complete_rep()
			_puck.puck_stripped.connect(_on_stickcheck_callable)

		STEP_BODY_CHECK:
			_place_puck(Vector3(100.0, _ICE_Y, 100.0))
			# Prevent race-condition re-pickup: drop() is sync but set_puck_position is
			# deferred by Jolt; one physics tick sees the puck at the old position.
			_puck.set_skater_cooldown(_skater, 0.5)
			# Two hits from different approach lines (_BODY_CHECK_SPOTS).
			_update_rep_objective()
			_stage_rep()
			_on_body_check_callable = func(_victim: Skater, _force: float, _dir: Vector3) -> void:
				_complete_rep()
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

		STEP_SHOOT_BACKHAND:
			# Same open-net slot drill, hand-gated in _on_shooting_shot.
			_setup_shooting_drill(_slot_z())
			_hud.set_objective("Score off the backhand.")

		STEP_SHOOT_TARGETS:
			_setup_shooting_drill(_slot_z())
			# The stationary goalie stands in for the whole drill — the target
			# waves read as the holes he leaves open.
			GameManager.spawn_tutorial_goalie()
			_show_targets_wave(0)

		STEP_SHOOT_FINISH:
			# Deeper start so they skate in and finish however they like — against a
			# live, beginner-tuned (Easy) goalie (the step text already says
			# "walk him side to side").
			_setup_shooting_drill(_FINISH_START_Z)
			GameManager.spawn_tutorial_goalie(true)
			_hud.set_objective("Score.")

		STEP_QUICK_PASS, STEP_TOUCH_PASS:
			_setup_passing_drill(true)
			# Quick pass runs two reps — the receiver relocates between them
			# (_QUICK_PASS_SPOTS); touch pass is single-rep.
			_update_rep_objective()

		STEP_SAUCER_PASS:
			# Deep receiver — the saucer must have room to land and slide in
			# grounded (see _SAUCER_PUPPET_POS).
			_setup_passing_drill(true, _SAUCER_PUPPET_POS)
			# Knee-high board in the passing lane — the reason the flat pass
			# can't get there. Close to the passer, inside the airborne span.
			_ensure_wall_node()
			_wall_node.show_wall(Vector3(0.0, 0.0,
					_PASS_PLAYER_POS.z - _SAUCER_WALL_AHEAD), _PASS_WALL_SIZE)

		STEP_RECEIVE:
			_setup_passing_drill(false)
			_receive_wave = 0
			_receive_catches = 0
			# The feeder holds the puck through the read delay; every re-feed
			# also reloads onto his stick (see _restage_feed_on_bot).
			GameManager.tutorial_give_puck(_puppet_record)
			_prefire_timer = _PREFIRE_DELAY
			_update_receive_objective()


func _reps_required() -> int:
	return _STEP_REPS.get(_current_step_id(), 1)


# Marks one successful repetition of the active step. Single-rep steps
# complete outright; multi-rep steps tick the counter, play the target-hit
# blip, and restage at the next spawn variation after the standard beat.
func _complete_rep() -> void:
	if _rep_restage_timer >= 0.0 or _complete_flash_timer > 0.0:
		return  # this attempt is already credited (double-fire guard)
	_reps_done += 1
	if _reps_done >= _reps_required():
		_complete_step()
		return
	SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	_update_rep_objective()
	_hud.clear_alert()
	_rep_restage_timer = _REATTEMPT_DELAY


# Objective line for the multi-rep steps ("Strips — 1 / 3"). No-op for
# single-rep steps so their objective line stays free for other uses.
func _update_rep_objective() -> void:
	if _reps_required() <= 1:
		return
	var noun: String
	match _current_step_id():
		STEP_STICKCHECK: noun = "Strips"
		STEP_STICK_LIFT: noun = "Lifts"
		STEP_BODY_CHECK: noun = "Hits"
		STEP_DEFLECT: noun = "Tips"
		STEP_BLADE_LIFT: noun = "Knock-downs"
		STEP_QUICK_PASS: noun = "Passes"
		_: noun = "Reps"
	_hud.set_objective("%s — %d / %d" % [noun, _reps_done, _reps_required()])


# (Re)stages the active step's positions for the CURRENT rep index — called at
# step entry (rep 0) by the varied-spawn steps and again after each credited
# rep, so the spot tables give every rep a fresh approach.
func _stage_rep() -> void:
	match _current_step_id():
		STEP_STICKCHECK:
			var spots: Array = _STICKCHECK_SPOTS[_reps_done % _STICKCHECK_SPOTS.size()]
			var player_pos: Vector3 = spots[0]
			var bot_pos: Vector3 = spots[1]
			_local_controller.teleport_to(player_pos, Vector2(
					bot_pos.x - player_pos.x, bot_pos.z - player_pos.z).normalized())
			_ensure_puppet(bot_pos)
			GameManager.tutorial_give_puck(_puppet_record)
		STEP_STICK_LIFT:
			# Alternate flanks so the second lift comes from the other side.
			var side: float = 2.6 if (_reps_done % 2) == 0 else -2.6
			_local_controller.teleport_to(Vector3(side, 1.0, 0.0), Vector2(-signf(side), 0.0))
			_ensure_puppet(Vector3(0.0, 1.0, 0.0))
			# The carrier plays down-ice rather than squaring to the learner, so
			# the flank approach stays a flank approach.
			_puppet_record.controller.set_spawn_facing(Vector2(0.0, -1.0))
			var lift_ai: AIController = _puppet_record.controller as AIController
			if lift_ai != null:
				lift_ai.script_aim_at(
						_puppet_record.skater.global_position + Vector3(0.0, 0.0, -3.0))
			GameManager.tutorial_give_puck(_puppet_record)
		STEP_BODY_CHECK:
			var spots: Array = _BODY_CHECK_SPOTS[_reps_done % _BODY_CHECK_SPOTS.size()]
			var player_pos: Vector3 = spots[0]
			var bot_pos: Vector3 = spots[1]
			_local_controller.teleport_to(player_pos, Vector2(
					bot_pos.x - player_pos.x, bot_pos.z - player_pos.z).normalized())
			_ensure_puppet(bot_pos)
		STEP_DEFLECT, STEP_BLADE_LIFT:
			_ensure_puppet(_FEED_SPOTS[_reps_done % _FEED_SPOTS.size()], 0)
			_restage_feed_on_bot()
		STEP_QUICK_PASS:
			_ensure_puppet(_QUICK_PASS_SPOTS[_reps_done % _QUICK_PASS_SPOTS.size()], 0)
			_stage_puck_for_player()


func _complete_step() -> void:
	_disconnect_all_signals()
	_complete_flash_timer = TutorialHUD._COMPLETE_FLASH_DURATION
	_hud.flash_complete()
	# Drop any corrective prompt so it doesn't linger over the completion flash.
	_hud.clear_alert()
	_elev_alert_shown = false
	# Tear the puppet down after any step that used it so it doesn't linger
	# into a step that doesn't need it.
	if _step_uses_puppet(_current_step_id()):
		_free_puppet()
	# Drill modules tear down their targets / walls / stationary goalie on
	# completion (the final steps have no _begin_step after them to do the
	# cleanup).
	_teardown_shooting()
	_teardown_passing()


func _step_uses_puppet(step_id: int) -> bool:
	return step_id == STEP_BODY_CHECK or step_id == STEP_STICKCHECK \
		or step_id == STEP_STICK_LIFT or step_id == STEP_QUICK_PASS \
		or step_id == STEP_TOUCH_PASS or step_id == STEP_SAUCER_PASS \
		or step_id == STEP_RECEIVE or step_id == STEP_DEFLECT \
		or step_id == STEP_BLADE_LIFT or step_id == STEP_SHOT_BLOCK \
		or step_id == STEP_ONE_TIMER


func _advance_step() -> void:
	_hud.hide_complete_flash()
	_step_index += 1
	if _step_index >= _step_ids.size():
		# Mark this tutorial complete so first-launch routing skips it next time
		# and the SideMenu shows a checkmark next to it.
		PlayerPrefs.mark_tutorial_complete(tutorial_id)
		# Course-complete achievement check (no-op until every tutorial is done).
		GameManager.notify_tutorial_completed()
		_hud.show_tutorial_complete()
	else:
		_begin_step(_step_index)


func _on_skip() -> void:
	var step_id: int = _current_step_id()
	if step_id == STEP_SHOT_BLOCK or step_id == STEP_DEFLECT \
			or step_id == STEP_BLADE_LIFT or step_id == STEP_RECEIVE \
			or step_id == STEP_ONE_TIMER:
		_place_puck(Vector3(100.0, _ICE_Y, 100.0))  # clear the in-flight puck
	if _step_uses_puppet(step_id):
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
					_fire_feed_from_bot(_SHOT_BLOCK_PUCK_SPEED)
				STEP_DEFLECT:
					_fire_feed_from_bot(_DEFLECT_FEED_SPEED, 0.0, true)
				STEP_BLADE_LIFT:
					_fire_feed_from_bot(_LOB_FEED_SPEED_XZ, _LOB_FEED_VY, true)
				STEP_RECEIVE:
					_fire_feed_from_bot(
							_RECEIVE_SPEED_SOFT if _receive_wave == 0 else _RECEIVE_SPEED_HOT,
							0.0, true)
				STEP_ONE_TIMER:
					_one_timer_armed = true
					_fire_feed_from_bot(_ONE_TIMER_CROSS_SPEED)

	# Between-reps beat: a credited rep restages at the next spawn variation
	# after the standard delay; the step's own watch logic pauses meanwhile so
	# it can't double-credit or refire against half-staged positions.
	if _rep_restage_timer >= 0.0:
		_rep_restage_timer -= delta
		if _rep_restage_timer <= 0.0:
			_rep_restage_timer = -1.0
			_stage_rep()
		return

	# Track WRISTER_AIM entry (quick vs wrist shot distinction) and the peak
	# predicted release power while aiming (wrist-drill and touch-pass gates).
	var shot_state: int = _local_controller.get_shot_state()
	if shot_state == SkaterStateMachine.State.WRISTER_AIM:
		if _wrister_aim_start < 0.0:
			_wrister_aim_start = Time.get_ticks_msec() / 1000.0
		_wrist_peak_charge = maxf(_wrist_peak_charge, _skater.shot_charge)
	else:
		if _wrister_aim_start >= 0.0:
			_wrister_aim_start = -1.0

	# Loft corrective prompt — tracks the loft mode live on every step that
	# expects a specific level (shot waves, deflects, the saucer pass).
	_update_elevation_prompt()

	# Shooting module: a self-contained watch/restage loop plus the targets
	# drill's final scroll-down-to-go-flat beat. These steps don't use the
	# match below, so handle them here and return.
	if _shooting_active:
		_shooting_tick(delta)
		if _current_step_id() == STEP_SHOOT_TARGETS and _targets_phase == 4 \
				and _skater.elevation_level == 0:
			_complete_step()
		return

	# Passing module: pass drills watch the attempt in flight; the receiving
	# drill watches for catches and re-fires missed feeds.
	if _passing_active:
		if _current_step_id() == STEP_RECEIVE:
			_receive_tick(delta)
		else:
			_passing_tick(delta)
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

		STEP_STAMINA:
			# Two beats: gas out (the exhaustion lockout latches), then recover
			# (the lockout releases once the pool refills past half).
			if not _stamina_exhaust_seen:
				if _local_controller.is_sprint_exhausted():
					_stamina_exhaust_seen = true
					_set_live_copy(
						"Stamina",
						"You're gassed — sprint is locked out while the ring flashes red. Keep skating: it unlocks once stamina refills past half.",
						"Plain skating is free — stamina only drains while you sprint.")
			else:
				if not _local_controller.is_sprint_exhausted():
					_complete_step()

		STEP_BRAKE:
			# is_braced is true whenever the brake is held, with or without a direction
			if _skater.is_braced:
				_step_timer += delta
				if _step_timer >= _BRAKE_HOLD:
					_complete_step()
			else:
				_step_timer = 0.0

		STEP_STICKHANDLE:
			_stickhandle_tick()

		STEP_DEFLECT, STEP_BLADE_LIFT:
			_feed_watch_tick(delta)

		STEP_DROP_PUCK:
			# Complete once the dropped puck is gathered back up. The nudge sets
			# a short pickup cooldown on the dropper, so the re-collect is a real
			# chase onto the loose puck, not an instant re-attach.
			if _drop_seen and _puck.carrier == _skater:
				_complete_step()

		STEP_STICK_LIFT:
			# If the player knocked the puck loose without a lift (a stray
			# poke), give it back to the puppet so they can try the lift again
			# — as soon as it's dead or clearly out of the contest, not once it
			# fully settles (a poked-away puck glides for many seconds). A
			# successful lift completes the step in the strip handler, after
			# which _complete_flash_timer short-circuits _process.
			if _puck.carrier == null and _puppet_record != null \
					and is_instance_valid(_puppet_record.skater):
				var puck_v: float = _puck.get_puck_velocity().length()
				var puck_dist: float = _puck.get_puck_position().distance_to(
						_puppet_record.skater.global_position)
				if puck_v < _FEED_DEAD_SPEED or puck_dist > _REPIN_GONE_DISTANCE:
					GameManager.tutorial_give_puck(_puppet_record)

		STEP_SHOT_BLOCK:
			# Re-fire if the shot is decisively over without a block — passed
			# the player, died short, or got blocked/deflected away at pace.
			# The puck reloads onto the shooter's stick for the standard
			# between-attempts beat; the timer's own gate stops this branch
			# retriggering during the wait. The block itself completes via
			# the puck_body_blocked handler.
			if _prefire_timer < 0.0 and _puck.carrier == null and _feed_missed(delta):
				_restage_feed_on_bot()

		STEP_ONE_TIMER:
			# Re-fire if the cross-ice pass is decisively over (hit boards,
			# missed the player, got swatted away). The puck reloads onto the
			# far-dot teammate's stick for the standard beat. _one_timer_armed
			# flips false on restage so this branch can't retrigger during the
			# wait.
			if _one_timer_armed and _prefire_timer < 0.0 and _puck.carrier == null:
				if _feed_missed(delta):
					_one_timer_armed = false
					_restage_feed_on_bot()

		STEP_OFFSIDES:
			if not _offside_ghost_seen:
				if _skater.is_ghost:
					_offside_ghost_seen = true
					_set_live_copy(
						"Offsides",
						"Now you're a ghost — passes go right through you. Skate back out past the blue line to get back in the play.",
						"Skate toward your own end and cross the blue line.")
			else:
				if not _skater.is_ghost:
					_complete_step()


# ── Stick Basics helpers ──────────────────────────────────────────────────────

# Counts forehand↔backhand crossings while the player carries the puck. The
# blade's side is its X in the skater's local frame, with hysteresis so jitter
# around centre doesn't count. Rendered-frame sampling is plenty — a human
# sweep takes many frames to cross the body.
func _stickhandle_tick() -> void:
	if _puck.carrier != _skater:
		return
	var blade_world: Vector3 = _skater.upper_body_to_global(_skater.get_blade_position())
	var blade_local: Vector3 = _skater.global_transform.affine_inverse() * blade_world
	if absf(blade_local.x) < _STICKHANDLE_SIDE_X:
		return
	var side: int = 1 if blade_local.x > 0.0 else -1
	if _stickhandle_side == 0:
		# First committed side — flip the objective's directive from "swing
		# out to a side" to "now sweep across".
		_stickhandle_side = side
		_update_stickhandle_objective()
		return
	if side != _stickhandle_side:
		_stickhandle_crossings += 1
		_update_stickhandle_objective()
		if _stickhandle_crossings >= _STICKHANDLE_CROSSINGS:
			_stickhandle_side = side
			_complete_step()
			return
	_stickhandle_side = side


# Directive objective line: the count plus what to do RIGHT NOW, so the drill
# never reads as an unexplained counter.
func _update_stickhandle_objective() -> void:
	var prompt: String = "swing the puck out to one side" if _stickhandle_side == 0 \
			else "now sweep it across to the other side"
	_hud.set_objective("Sweeps — %d / %d — %s" % [
			_stickhandle_crossings, _STICKHANDLE_CROSSINGS, prompt])


# True when the loose feed in flight is decisively over: dead slow, got past
# the player, or receding beyond recovery range — plus a hard flight cap as a
# safety net. Shared by every bot-fed step (deflect / blade-lift / receive /
# shot-block / one-timer) so a failed attempt — a deflection sent flying, a
# blocked shot ricocheting into a corner — restages after the standard beat
# instead of waiting for the puck to glide to rest somewhere at the boards.
# Also advances the feed's flight clock, so call it at most once per frame,
# and only while the feed is actually loose in flight (prefire elapsed, no
# carrier) — every caller already gates on exactly that.
func _feed_missed(delta: float) -> bool:
	_feed_flight_time += delta
	if _feed_flight_time >= _FEED_MAX_FLIGHT_S:
		return true
	var vel: Vector3 = _puck.get_puck_velocity()
	if vel.length() < _FEED_DEAD_SPEED:
		return true
	var pos: Vector3 = _puck.get_puck_position()
	# Every feed lane faces -Z, so up-lane past the player is a clean miss.
	if pos.z > _skater.global_position.z + _FEED_PAST_PLAYER_M:
		return true
	# Receding out of range: an incoming feed always closes on the player, so
	# a puck this far out and moving AWAY can only be a failed contact.
	var to_puck := Vector3(pos.x - _skater.global_position.x, 0.0,
			pos.z - _skater.global_position.z)
	return to_puck.length() > _FEED_GONE_DISTANCE and vel.dot(to_puck) > 0.0


# Watch loop for the deflect / blade-lift feeds: re-fire when the feed is
# decisively missed, and take back a puck the player caught by mistake (the
# corrective moment — these steps are about NOT receiving).
func _feed_watch_tick(delta: float) -> void:
	if _puck.carrier == _skater:
		# Caught it instead of deflecting. Take it back, explain, re-feed.
		if _current_step_id() == STEP_DEFLECT:
			_hud.set_alert(_fmt("You caught that one — hold {stick_lift} before it arrives to deflect instead."))
		else:
			_hud.set_alert(_fmt("It got under your blade. Keep loft on HIGH and {stick_lift} held — meet the lob in the air."))
		_restage_feed_on_bot()
		return
	if _prefire_timer < 0.0 and _puck.carrier == null and _feed_missed(delta):
		_restage_feed_on_bot()


# Completion handler for the deflect / blade-lift steps: the puck-touch signal
# fires on any blade redirect; the gates pick out the deliberate gesture each
# step teaches. (Natural deflects can't fire here — the feeds are far below
# the natural-deflect threshold, so an un-held blade would receive instead.)
func _on_feed_touched(toucher: Skater) -> void:
	if toucher != _skater:
		return
	match _current_step_id():
		STEP_DEFLECT:
			if _skater.deflect_intent:
				_complete_rep()
		STEP_BLADE_LIFT:
			if _skater.blade_up:
				_complete_rep()


# ── One-timer helpers ─────────────────────────────────────────────────────────

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
	_restage_feed_on_bot()
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


# Fires the puck the feeder bot is holding at the player's CURRENT position
# (deflect / blade-lift / shot-block / one-timer / receive feeds). The puck
# leaves from the bot's blade — visible the whole time, so the camera frames
# the play — and aiming at the live position guarantees it heads straight at
# the player even if they've drifted off the staged spot. A vy > 0 turns the
# feed into an airborne lob (blade-lift step). `at_blade` feeds the player's
# BLADE contact point instead of their body: the stick-play steps (deflect /
# blade-lift / receive) meet the puck with the blade, and the blade rides a
# stride out from the body wherever the cursor holds it — a body-aimed feed
# arrives at the skates and makes the player guess the offset. The body-read
# steps keep the body line (shot block: body in the lane; one-timer: puck
# through the shooting zone).
func _fire_feed_from_bot(speed: float, vy: float = 0.0, at_blade: bool = false) -> void:
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		return
	if _puck.carrier == _puppet_record.skater:
		_puck.drop()
	# The feed launches right past the feeder's own blade — lock him out so he
	# can't instantly re-collect a slow one. Cleared by the next
	# tutorial_give_puck (explicit grants bypass cooldowns) or teardown.
	_puck.set_skater_cooldown(_puppet_record.skater, _PICKUP_LOCK_S)
	_feed_flight_time = 0.0
	var from: Vector3 = _puck.get_puck_position()
	var to: Vector3 = _skater.get_blade_contact_global() if at_blade \
			else _skater.global_position
	var dir := Vector3(to.x - from.x, 0.0, to.z - from.z)
	if dir.length() < 0.01:
		dir = Vector3.FORWARD * -1.0  # +Z fallback if player is right on top
	dir = dir.normalized()
	# Tiny Y floor so velocity survives Jolt's first integration step (without
	# it a flat feed can settle inert on tick 0).
	_puck.apply_release_velocity(dir * speed + Vector3(0.0, maxf(vy, 0.001), 0.0))


# Between-attempts reload for the bot-fed steps: the puck jumps back onto the
# feeder's stick (a visible "rearming" beat) and the prefire timer schedules
# the next feed. The prefire dispatch in _process maps the step to its feed.
func _restage_feed_on_bot() -> void:
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		return
	GameManager.tutorial_give_puck(_puppet_record)
	_prefire_timer = _REATTEMPT_DELAY


func _ensure_puppet(position: Vector3, team_id: int = 1) -> void:
	if _puppet_record != null and _puppet_team != team_id:
		_free_puppet()
	if _puppet_record == null or not is_instance_valid(_puppet_record.skater):
		_puppet_record = GameManager.spawn_tutorial_bot(position, 0, team_id)
		_puppet_team = team_id
		if _puppet_record == null:
			return
	else:
		_puppet_record.skater.global_position = position
	# Face toward the player so the puppet reads as engaged with the learner.
	# Facing is XZ in world space; bots default to a fixed facing, which is
	# wrong when the player is off-axis (e.g. body-check step spawns the
	# puppet at +X with the player at -X).
	var to_player := Vector2(
			_skater.global_position.x - _puppet_record.skater.global_position.x,
			_skater.global_position.z - _puppet_record.skater.global_position.z)
	if to_player.length() > 0.01:
		# Through the controller so BOTH facing stores update (root rotation +
		# pose coordinator) — setting only the skater desyncs them and the
		# next input tick snaps the puppet back to the stale pose facing.
		# Also resets lean/lag/gait, which a step teleport wants anyway.
		_puppet_record.controller.set_spawn_facing(to_player.normalized())
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

	if _on_puck_touch_callable.is_valid() and _puck != null:
		if _puck.puck_touched_loose.is_connected(_on_puck_touch_callable):
			_puck.puck_touched_loose.disconnect(_on_puck_touch_callable)
		_on_puck_touch_callable = Callable()

	if _on_block_callable.is_valid() and _puck != null:
		if _puck.puck_body_blocked.is_connected(_on_block_callable):
			_puck.puck_body_blocked.disconnect(_on_block_callable)
		_on_block_callable = Callable()

	if _on_nudge_callable.is_valid():
		if _local_controller.nudge_requested.is_connected(_on_nudge_callable):
			_local_controller.nudge_requested.disconnect(_on_nudge_callable)
		_on_nudge_callable = Callable()

	if _on_shooting_shot_callable.is_valid():
		if _local_controller.puck_release_requested.is_connected(_on_shooting_shot_callable):
			_local_controller.puck_release_requested.disconnect(_on_shooting_shot_callable)
		_on_shooting_shot_callable = Callable()

	if _on_passing_shot_callable.is_valid():
		if _local_controller.puck_release_requested.is_connected(_on_passing_shot_callable):
			_local_controller.puck_release_requested.disconnect(_on_passing_shot_callable)
		_on_passing_shot_callable = Callable()


# ── Shooting module helpers ───────────────────────────────────────────────────

# Player's shooting spot for the slot drills: in the slot, SLOT_DIST_M out from
# the attacking net (team 0 attacks -Z).
func _slot_z() -> float:
	return -(GameRules.GOAL_LINE_Z - GameRules.SLOT_DIST_M)


# Player's shooting spot for the HIGH wave — in tight on the same lane.
func _doorstep_z() -> float:
	return -(GameRules.GOAL_LINE_Z - _DOORSTEP_DIST_M)


# Shared setup for every shooting drill: stand the player at start_z facing the
# net, put the puck on the stick, and listen for shots.
func _setup_shooting_drill(start_z: float) -> void:
	_shooting_active     = true
	_shoot_restage_timer = -1.0
	_wrist_peak_charge   = 0.0
	_last_shot_qualifies = false
	_shot_live           = false
	_targets_phase       = 0
	_target_noun         = "Targets hit"
	_local_controller.teleport_to(Vector3(0.0, 1.0, start_z), Vector2(0.0, -1.0))
	_stage_puck_for_player()
	_on_shooting_shot_callable = func(d: Vector3, p: float, s: bool) -> void:
		_on_shooting_shot(d, p, s)
	_local_controller.puck_release_requested.connect(_on_shooting_shot_callable)


# Minimum normalized charge (0..1 predicted release power) for the Wrist Shot
# drill to count the shot as a real charged wrister rather than a soft flick.
# Wrister power is the pure mouse-speed model — a genuine sweep reads as real
# power in shot_charge (the every-tick predicted release) — so the drill's
# "drag to aim and rip it" lesson gates on the player having built meaningful
# power, not a drag distance.
const _WRIST_CHARGE_QUALIFY: float = 0.2

# Records whether the just-released shot satisfies the active drill's required
# type. Plain-goal drills (wrist, slap, finish) complete only when this is true;
# the target drill clears via the target test, so it never completes on
# a plain goal (qualifies stays false).
func _on_shooting_shot(_dir: Vector3, _power: float, is_slapper: bool) -> void:
	match _current_step_id():
		STEP_SHOOT_WRIST:
			_last_shot_qualifies = (not is_slapper) and TutorialShotRules.is_dragged_wrister(
					_wrist_peak_charge, _WRIST_CHARGE_QUALIFY)
		STEP_SHOOT_BACKHAND:
			# The release path classifies every wrister FH/BH from the sweep's
			# chirality and stamps last_release_hand just before this signal
			# fires ("" for quick passes / slappers — no backhand concept there).
			_last_shot_qualifies = (not is_slapper) \
					and _local_controller.last_release_hand == "BH"
			if _last_shot_qualifies:
				# Drop a lingering "off the forehand" prompt the moment a real
				# backhand leaves the blade. Safe to clear broadly: the loft
				# prompt re-asserts itself every frame if it still applies.
				_hud.clear_alert()
		STEP_SHOOT_SLAP:
			_last_shot_qualifies = is_slapper
		STEP_SHOOT_FINISH:
			_last_shot_qualifies = true
		_:
			_last_shot_qualifies = false
	_wrist_peak_charge = 0.0
	# Arm the in-flight watch and lock the puck from re-pickup until it resolves
	# and restages — so mashing the shoot button can't just re-collect a rebound
	# and keep possession. The cooldown blocks the loose-puck proximity pickup
	# (see PuckController); it's cleared in _stage_puck_for_player /
	# _teardown_shooting.
	_shot_live          = true
	_shot_start_z       = _skater.global_position.z
	_shot_max_progress  = 0.0
	_shot_last_progress = 0.0
	_shot_stall_time    = 0.0
	_shot_air_time      = 0.0
	_puck.set_skater_cooldown(_skater, _PICKUP_LOCK_S)


# Loft level the active drill/step expects, or _ELEV_ANY when it doesn't care.
# Drives a corrective prompt (never an auto-fix — managing the loft mode is
# part of the lesson).
const _ELEV_ANY: int = -1

func _expected_elevation() -> int:
	match _current_step_id():
		STEP_SHOOT_WRIST, STEP_SHOOT_BACKHAND, STEP_SHOOT_SLAP:
			return ShotMechanics.ELEVATION_FLAT
		STEP_SHOOT_TARGETS:
			match _targets_phase:
				1: return ShotMechanics.ELEVATION_LOW
				2: return ShotMechanics.ELEVATION_MID
				3: return ShotMechanics.ELEVATION_HIGH
				_: return ShotMechanics.ELEVATION_FLAT
		STEP_DEFLECT, STEP_SAUCER_PASS:
			return ShotMechanics.ELEVATION_LOW
		STEP_BLADE_LIFT, STEP_STICK_LIFT:
			# The stick lift rides the fully-raised blade, which needs HIGH loft
			# (MID lifts only to the low-air pivot; SkaterController: blade_up
			# requires elevation >= MID). Without HIGH the hold-{stick_lift} has
			# no reach and no tell — so the step tracks loft like the others.
			return ShotMechanics.ELEVATION_HIGH
	return _ELEV_ANY


# Shows / clears the amber loft prompt. Called every frame so it tracks the
# loft mode live; only ever clears an alert it set itself, so other correctives
# (the touch-pass "too hot" prompt) aren't stomped.
func _update_elevation_prompt() -> void:
	var expected: int = _expected_elevation()
	if expected == _ELEV_ANY:
		if _elev_alert_shown:
			_hud.clear_alert()
			_elev_alert_shown = false
		return
	if _skater.elevation_level < expected:
		_hud.set_alert(_fmt("Your loft is too low — tap {elevation_up} for more."))
		_elev_alert_shown = true
	elif _skater.elevation_level > expected:
		_hud.set_alert(_fmt("Your loft is too high — tap {elevation_down} to bring it down."))
		_elev_alert_shown = true
	elif _current_step_id() == STEP_STICK_LIFT:
		# Loft correct: unlike the shot steps (which have a visible arc as their
		# own feedback), the stick lift's raised blade has no tell, so confirm the
		# loft is set and point them at the gesture.
		_hud.set_alert(_fmt("Loft's on HIGH — get under his stick and hold {stick_lift}."))
		_elev_alert_shown = true
	elif _elev_alert_shown:
		_hud.clear_alert()
		_elev_alert_shown = false


# Per-frame watch/restage loop for shooting drills. Waits out the re-stage beat,
# then watches the loose in-flight puck: a target hit / goal resolves the
# attempt, a wide-or-dead shot retires it and restages. The scored/missed puck
# is deliberately LEFT in play (not teleported off-rink) so the player watches it
# reach the net — pickup stays locked so it can't be re-collected in the meantime.
func _shooting_tick(delta: float) -> void:
	if _shoot_restage_timer >= 0.0:
		_shoot_restage_timer -= delta
		if _shoot_restage_timer <= 0.0:
			_shoot_restage_timer = -1.0
			_restage_shooter()
		return
	if _puck.carrier != null:
		return  # puck on a stick — nothing in flight
	if not _shot_live:
		return  # loose puck already resolved; waiting for the restage beat

	var pos: Vector3 = _puck.get_puck_position()
	# Forward progress toward the net, and its rate. A carried puck reports ~0
	# rigidbody velocity, but by here the puck is loose, so the progress delta is
	# a clean forward-speed read that also goes negative on a rebound.
	var progress: float = (pos.z - _shot_start_z) * _ATTACK_DIR_Z
	var fwd_speed: float = (progress - _shot_last_progress) / delta if delta > 0.0 else 0.0
	_shot_last_progress = progress
	_shot_max_progress = maxf(_shot_max_progress, progress)
	_shot_air_time += delta
	# Only arm the dead-puck test after the release has settled, so a shot still
	# leaving the blade isn't read as stalled on its first frames.
	if _shot_air_time < _SHOT_START_GRACE:
		_shot_stall_time = 0.0
	elif fwd_speed <= _SHOT_REST_SPEED:
		_shot_stall_time += delta
	else:
		_shot_stall_time = 0.0

	var crossed_plane: bool = TutorialShotRules.crossed_goal_plane(
			pos.z, _GOAL_PLANE_Z, _ATTACK_DIR_Z)

	if not _targets.is_empty():
		# Target drills: reward ROUGH aim. When the puck reaches the net-plane,
		# credit the nearest bullseye within tolerance — it need not go cleanly in.
		if crossed_plane:
			var idx: int = TutorialShotRules.nearest_target(
					pos.x, pos.y, _targets, _TARGET_RADIUS)
			if idx >= 0 and not _target_hit[idx]:
				_on_target_hit(idx)
				return
			_resolve_shot_miss()
			return
	else:
		# Plain-goal drills (wrist / slap / finish): a real goal inside the posts.
		if TutorialShotRules.crossed_goal_line(
				pos.x, pos.y, pos.z, _GOAL_PLANE_Z, _ATTACK_DIR_Z,
				_NET_HALF_WIDTH, GameRules.NET_HEIGHT):
			_shot_live = false
			if _last_shot_qualifies:
				_complete_step()  # scored puck stays in the net through the flash
			else:
				# A goal off the wrong release restages after the standard beat.
				# The backhand drill explains why the goal didn't count — a
				# silent reset there reads as the drill eating a clean finish.
				if _current_step_id() == STEP_SHOOT_BACKHAND:
					_hud.set_alert(_pick(
						"In — but off the forehand. Curl the drag around your body and let it go from the backhand.",
						"In — but off the forehand. Point the stick back across your body and let it go from the backhand."))
				_begin_restage()
			return

	# Rebound off the goalie: the puck retreats past its furthest point back
	# toward the shooter. Retire it promptly rather than waiting out the stall.
	if _shot_air_time >= _SHOT_START_GRACE \
			and progress < _shot_max_progress - _SHOT_BACKWARD_TOL:
		_resolve_shot_miss()
		return
	# Not scored / no target hit yet — retire the shot if it has clearly missed
	# (crossed the plane wide/high) or gone dead (stopped advancing).
	if TutorialShotRules.shot_missed(false, pos.z, _GOAL_PLANE_Z, _ATTACK_DIR_Z,
			fwd_speed, _SHOT_REST_SPEED, _shot_stall_time, _SHOT_STALL_GRACE):
		_resolve_shot_miss()
		return
	# Safety: a wedged puck that never resolves any other way.
	if _shot_air_time >= _SHOT_MAX_TIME:
		_resolve_shot_miss()


# Credit a hit on target `idx`: pop the bullseye, tick the counter, and either
# finish the wave/step or restage for the next shot. The puck is left in play so
# the player sees it reach the net.
func _on_target_hit(idx: int) -> void:
	_shot_live = false
	_target_hit[idx] = true
	_targets_remaining -= 1
	if _target_node != null and is_instance_valid(_target_node):
		_target_node.hide_target(idx)
	SoundManager.play_ui(SoundManager.Sound.UI_CLICK)
	_update_target_objective()
	if _targets_remaining <= 0 and _on_targets_wave_cleared():
		_complete_step()
		return
	_begin_restage()


# Retire a shot that missed and schedule the next attempt. The puck is NOT
# teleported off-rink — it stays where the miss took it (a wide shot slides
# past, a save trickles away) so the miss reads honestly; pickup stays locked
# (from the release) so it can't be re-collected before the restage.
func _resolve_shot_miss() -> void:
	_shot_live = false
	_begin_restage()


# Schedule handing the puck back to the player after the standard between-attempts
# beat. Leaves the loose puck visible in the meantime (pickup already locked).
func _begin_restage() -> void:
	_shoot_restage_timer = _REATTEMPT_DELAY


# How far the shooter may wander from the station before the next attempt puts
# them back. Non-zero so stepping into a shot isn't undone on a rep the player
# barely moved on — and so a stationary shooter never pays teleport_to's
# prediction-history clear once per attempt.
const _STATION_DRIFT_TOL: float = 0.75

# Station the active targets wave shoots from: the slot for the flat / saucer /
# MID waves, the doorstep for the HIGH wave.
func _targets_station_z() -> float:
	return _doorstep_z() if _targets_phase == 3 else _slot_z()


# Returns the shooter to the wave's station, then stages the next puck. The
# target waves are calibrated per range — the rung that reaches the corners from
# the slot can't reach them from the doorstep, and vice versa — while the puck
# stages relative to wherever the player is STANDING. Without this the shooter
# creeps netward a stride per attempt and the range each wave teaches quietly
# drifts out from under it. Only the target drill re-stations: the other
# shooting steps have no range calibration to protect, and the free finish is
# meant to roam.
func _restage_shooter() -> void:
	if _current_step_id() == STEP_SHOOT_TARGETS:
		var station := Vector3(0.0, 1.0, _targets_station_z())
		var drift: float = Vector2(_skater.global_position.x - station.x,
				_skater.global_position.z - station.z).length()
		if drift > _STATION_DRIFT_TOL:
			_local_controller.teleport_to(station, Vector2(0.0, -1.0))
	_stage_puck_for_player()


# Called when the active wave's targets are all cleared. Returns true if the
# whole step is done, false if the drill advanced to a new wave / beat.
func _on_targets_wave_cleared() -> bool:
	match _current_step_id():
		STEP_SHOOT_TARGETS:
			if _targets_phase < 3:
				_show_targets_wave(_targets_phase + 1)
				return false
			# High wave cleared → the toggle-off beat. Completion happens in
			# _process once the player scrolls elevation back off.
			_targets_phase = 4
			_targets = []
			if _target_node != null and is_instance_valid(_target_node):
				_target_node.clear()
			_set_live_copy(
				"Pick Your Spot",
				"Nice. Your loft is still on full, though — tap {elevation_down} three times to flatten back out, or your next shot flies high too.",
				"Loft is a mode you manage: up for more, down for less.")
			_hud.set_objective("Take the loft back off.")
			return false
	return true


# Sets the copy + target set for one wave of the Pick Your Spot drill.
# Wave 0: flat shots at the low holes. Wave 1: same holes, but a board in the
# lane forces the LOW saucer. Wave 2: MID at the top corners from the slot.
# Wave 3: the same corners from the doorstep, where only HIGH reaches them —
# the pairing is the range lesson (see _DOORSTEP_DIST_M).
func _show_targets_wave(phase: int) -> void:
	_targets_phase = phase
	_target_noun = "Targets hit"
	match phase:
		0:
			_set_live_copy(
				"Pick Your Spot",
				"A goalie's in the net — but he's frozen stiff. Three targets mark the holes he leaves low. Stay flat and knock each one out — any order.",
				_pick(
					"Aim is the direction you drag, not where the cursor sits.",
					"Aim is the direction you push the stick."))
			_clear_wall()
			_show_target_set(_LOW_TARGETS)
		1:
			_set_live_copy(
				"Pick Your Spot",
				"Same low holes — but now a board's in the lane. Tap {elevation_up} to raise your loft one level: the saucer flips over the board and comes back down onto them.",
				"LOW loft clears sticks and pads mid-flight, then lands and slides. It's a mode — it stays on until you change it.")
			_ensure_wall_node()
			_wall_node.show_wall(
					Vector3(0.0, 0.0, _slot_z() - _TARGET_WALL_AHEAD), _TARGET_WALL_SIZE)
			_show_target_set(_LOW_TARGETS)
		2:
			_set_live_copy(
				"Pick Your Spot",
				"Up top. Tap {elevation_up} once more to MID, and put both away in the top corners over his shoulders.",
				"Loft buys the height, pace picks where the arc peaks — from out here an easy shot crests right at the bar.")
			_clear_wall()
			_show_target_set(_HIGH_TARGETS)
		3:
			# Same corners, in tight — MID can't climb to them from here, so the
			# player has to reach for the top rung. Moved on the spot rather than
			# on the restage beat that follows, so the player is already standing
			# on the doorstep as the copy telling them so appears; the puck lands
			# on the beat like every other wave change. HIGH is an in-tight tool
			# and the drill should stand them where it works (see
			# _DOORSTEP_DIST_M).
			_local_controller.teleport_to(
					Vector3(0.0, 1.0, _doorstep_z()), Vector2(0.0, -1.0))
			_set_live_copy(
				"Pick Your Spot",
				"Now you're on the doorstep — and MID can't climb this fast. Tap {elevation_up} once more to HIGH and roof both corners from in tight.",
				"Every rung has a range. From here HIGH gets over him in a stride and can't sail — out in the slot it'd be over the glass.")
			_clear_wall()
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


func _ensure_wall_node() -> void:
	if _wall_node == null or not is_instance_valid(_wall_node):
		_wall_node = TutorialWall.new()
		add_child(_wall_node)


func _clear_wall() -> void:
	if _wall_node != null and is_instance_valid(_wall_node):
		_wall_node.clear()


# Stages the puck a stride in front of the player for the next attempt, so
# skating onto it runs the NORMAL pickup path (PuckController's proximity
# grant). Never hand the puck to a stick from here: a bare Puck.set_carrier
# bypasses PuckController's carrier bookkeeping, so the following release never
# notified the controller — has_puck leaked true and the player could "shoot"
# a puck that wasn't there. Every drill lane faces -Z, so ahead = -Z.
func _stage_puck_for_player() -> void:
	# Lift the in-flight pickup lock set at release so the staged puck can be
	# collected normally.
	_puck.remove_skater_cooldown(_skater)
	_shot_live = false
	_pass_live = false
	if _puck.carrier != null:
		_puck.drop()
	_puck.set_puck_position(Vector3(_skater.global_position.x, _ICE_Y,
			_skater.global_position.z - _STAGE_PUCK_AHEAD))
	_puck.linear_velocity = Vector3.ZERO


# Clears all shooting-drill state: targets, the wall, the tutorial goalie, the
# watch loop. Safe to call on any step (no-op when no shooting drill is active).
func _teardown_shooting() -> void:
	# Release the in-flight pickup lock if a shot was mid-resolution when the
	# drill tore down (skip / reset / step advance).
	if _shot_live and is_instance_valid(_skater) and is_instance_valid(_puck):
		_puck.remove_skater_cooldown(_skater)
	_shooting_active     = false
	_shoot_restage_timer = -1.0
	_shot_live           = false
	_targets             = []
	_target_hit          = []
	_targets_remaining   = 0
	_targets_phase       = 0
	if _target_node != null and is_instance_valid(_target_node):
		_target_node.clear()
	_clear_wall()
	GameManager.despawn_tutorial_goalie()


# ── Passing module helpers ────────────────────────────────────────────────────

# Shared setup for the passing drills: player and teammate staged facing each
# other down the -Z lane. Pass drills (give_puck) start with the puck on the
# player's stick and listen for releases; the receiving drill starts empty-
# handed and fires feeds from the teammate instead.
func _setup_passing_drill(give_puck: bool, puppet_pos: Vector3 = _PASS_PUPPET_POS) -> void:
	_passing_active     = true
	_pass_live          = false
	_pass_qualifies     = false
	_pass_hot           = false
	_pass_restage_timer = -1.0
	_wrist_peak_charge  = 0.0
	_local_controller.teleport_to(_PASS_PLAYER_POS, Vector2(0.0, -1.0))
	_ensure_puppet(puppet_pos, 0)
	if give_puck:
		_stage_puck_for_player()
		_on_passing_shot_callable = func(d: Vector3, p: float, s: bool) -> void:
			_on_passing_shot(d, p, s)
		_local_controller.puck_release_requested.connect(_on_passing_shot_callable)
	else:
		# Receiving: make sure no stale pickup lock blocks the catch.
		_puck.remove_skater_cooldown(_skater)


# Records whether the just-released pass matches the drill's required type and
# arms the in-flight watch. Same pickup lock as the shooting drills, so the
# passer can't chase their own pass down and re-collect it.
func _on_passing_shot(_dir: Vector3, _power: float, is_slapper: bool) -> void:
	var was_aimed: bool = _wrister_aim_start >= 0.0
	match _current_step_id():
		STEP_QUICK_PASS, STEP_SAUCER_PASS:
			# The quick pass fires straight from carry without entering
			# WRISTER_AIM, so a never-aimed non-slapper release qualifies.
			_pass_qualifies = (not is_slapper) and not was_aimed
			_pass_hot = false
		STEP_TOUCH_PASS:
			_pass_qualifies = (not is_slapper) and was_aimed
			_pass_hot = _wrist_peak_charge > _TOUCH_PASS_MAX_CHARGE
		_:
			_pass_qualifies = false
			_pass_hot = false
	_wrist_peak_charge = 0.0
	_pass_live       = true
	_pass_stall_time = 0.0
	_pass_air_time   = 0.0
	_puck.set_skater_cooldown(_skater, _PICKUP_LOCK_S)


# Watch loop for the pass drills. Success = the teammate ends up carrying a
# qualifying pass — judged whenever he comes up with it, NOT only while the
# in-flight watch still considers the attempt live. A rough-but-honest pass
# can be retired by the flight watch (slid past him, bobbled off his blade
# and stalled) and STILL be corralled on his second touch a beat later; the
# player just watched their teammate retrieve the pass, so it counts. The
# credit window closes when the restage actually takes the puck back.
# Anything else (dead puck, wrong type, too hot) restages after the standard
# beat, with an alert explaining a caught-but-wrong-type attempt.
func _passing_tick(delta: float) -> void:
	# The receiver plays his part: whenever the puck is loose his blade chases
	# it (so a rough pass still gets caught — the drill tests the pass, not
	# pixel-perfect aim — and a retired-but-recoverable one gets picked back
	# up); otherwise he presents the blade to the passer as a target.
	if _puppet_record != null and is_instance_valid(_puppet_record.skater):
		var ai_ctrl: AIController = _puppet_record.controller as AIController
		if ai_ctrl != null:
			ai_ctrl.script_aim_at(_puck.get_puck_position() if _puck.carrier == null
					else _skater.global_position)
	# Teammate has it: resolve the attempt — credit a qualifying pass, explain
	# a disqualified one. Checked ahead of the restage countdown so a late
	# retrieval during the beat still counts instead of being yanked away.
	if _puppet_record != null and is_instance_valid(_puppet_record.skater) \
			and _puck.carrier == _puppet_record.skater:
		_pass_live = false
		if _pass_qualifies and not _pass_hot:
			_pass_restage_timer = -1.0  # cancel any pending restage — it counted
			# Pass stays on the teammate's blade through the rep blip / flash.
			_complete_rep()
			return
		if _pass_hot:
			_hud.set_alert("Too hot — sweep slower for a touch pass.")
		elif not _pass_qualifies:
			# He caught it, but off the wrong release — say so, or the reset
			# reads as the drill eating a good pass.
			if _current_step_id() == STEP_TOUCH_PASS:
				_hud.set_alert(_fmt("He got it — but that was the quick snap. Hold {shoot} and sweep it over slowly."))
			else:
				_hud.set_alert(_fmt("He got it — but off a sweep. Tap {quick_pass} for the snap pass instead."))
		if _pass_restage_timer < 0.0:
			_pass_restage_timer = _REATTEMPT_DELAY
		# Fall through to the countdown below while he holds the dead attempt.
	if _pass_restage_timer >= 0.0:
		_pass_restage_timer -= delta
		if _pass_restage_timer <= 0.0:
			_pass_restage_timer = -1.0
			# The attempt is spent — a stale qualify must never credit whatever
			# the teammate corrals after the puck goes back to the player.
			_pass_qualifies = false
			_pass_hot = false
			# The saucer drill's staging IS the lesson (the board must sit
			# between passer and receiver, inside the airborne span) — re-square
			# a player who chased their miss downlane, or the restaged puck can
			# land beyond the board and a flat pass completes the step.
			if _current_step_id() == STEP_SAUCER_PASS:
				_local_controller.teleport_to(_PASS_PLAYER_POS, Vector2(0.0, -1.0))
			_stage_puck_for_player()
		return
	if not _pass_live:
		return
	_pass_air_time += delta
	if _pass_air_time < _SHOT_START_GRACE:
		return
	# A hot pass that bounced off the teammate's blade, a saucer that clanked
	# off the board, or a pass that slid wide: retire it once it stops making
	# meaningful progress, once it's clearly slid PAST the receiver (waiting
	# for a missed pass to settle at the boards read as a hang), or after the
	# safety cap. The lane runs toward -Z, so past = beyond the bot's z.
	var past_receiver: bool = false
	if _puppet_record != null and is_instance_valid(_puppet_record.skater):
		past_receiver = _puck.carrier == null and _puck.get_puck_position().z \
				< _puppet_record.skater.global_position.z - _PASS_MISS_BEYOND_M
	# "No longer progressing" covers more than dying at the boards: a flat pass
	# that clanked off the saucer board, or a hot feed that bounced off the
	# receiver's blade, comes back UP the lane at pace and used to glide for
	# seconds before the rest-speed test tripped. The lane runs toward -Z, so
	# any non-negative z-velocity on a loose pass is zero progress — start the
	# stall clock immediately.
	var pass_vel: Vector3 = _puck.get_puck_velocity()
	if _puck.carrier == null \
			and (pass_vel.length() <= _SHOT_REST_SPEED or pass_vel.z >= 0.0):
		_pass_stall_time += delta
	else:
		_pass_stall_time = 0.0
	if past_receiver or _pass_stall_time >= _SHOT_STALL_GRACE \
			or _pass_air_time >= 2.0 * _SHOT_MAX_TIME:
		_pass_live = false
		if _current_step_id() == STEP_TOUCH_PASS and _pass_hot:
			_hud.set_alert("Too hot — it bounced off. Sweep slower.")
		_pass_restage_timer = _REATTEMPT_DELAY


# Watch loop for the receiving drill: credit catches, advance to the hot wave,
# re-fire feeds that got past the player, died, or deflected away at pace.
func _receive_tick(delta: float) -> void:
	if _puck.carrier == _skater:
		_receive_catches += 1
		_update_receive_objective()
		if _receive_catches >= _RECEIVE_CATCHES_PER_WAVE:
			if _receive_wave == 0:
				_receive_wave = 1
				_receive_catches = 0
				_set_live_copy(
					"Receiving",
					"These are coming in hot. Square your blade to the incoming line — face the pass head-on — or soften it by skating backward as it arrives.",
					"A hard pass off an angled blade deflects away. Squared up (or giving ground), it sticks.")
				_update_receive_objective()
			else:
				_complete_step()
				return
		# Reload onto the feeder's stick for the next feed (visible rearm —
		# this also takes the caught puck off the player's blade).
		_restage_feed_on_bot()
		return
	if _prefire_timer < 0.0 and _puck.carrier == null and _feed_missed(delta):
		_restage_feed_on_bot()


func _update_receive_objective() -> void:
	var wave_name: String = "Soft feeds" if _receive_wave == 0 else "Hot feeds"
	_hud.set_objective("%s — %d / %d" % [wave_name, _receive_catches, _RECEIVE_CATCHES_PER_WAVE])


# Clears all passing-drill state. Safe to call on any step.
func _teardown_passing() -> void:
	if _pass_live and is_instance_valid(_skater) and is_instance_valid(_puck):
		_puck.remove_skater_cooldown(_skater)
	# Lift the feeder's per-fire pickup lock (receiving drill).
	if _puppet_record != null and is_instance_valid(_puppet_record.skater) \
			and is_instance_valid(_puck):
		_puck.remove_skater_cooldown(_puppet_record.skater)
	_passing_active     = false
	_pass_live          = false
	_pass_qualifies     = false
	_pass_hot           = false
	_pass_restage_timer = -1.0
	_receive_wave       = 0
	_receive_catches    = 0
	_clear_wall()
