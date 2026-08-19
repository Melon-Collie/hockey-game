class_name GoalieCreaseClear
extends RefCounted

# Loose-puck geometry in the blue paint — the reads behind the sweep, the cover
# and the catch. GoalieController owns their lifecycles and calls in here to ask
# where the puck is and whether it can be played.
#
# The real hierarchy (USA Hockey "Controlling Rebounds"): COVER under pressure,
# SWEEP when there is time to play it, leave it only with clear teammate
# possession. The sweep is only the correct clear when a corner exit lane is OPEN,
# so the cover triggers exactly when the lane model says every sweep would feed an
# opponent's stick AND an opponent is on the puck. The catch is the same family
# from the other end: a controlled glove save PINS the puck, and resolves by
# pressure — held under pressure it freezes the play, unpressured it look-and-drops
# and plays on (the real delay-of-game incentive).
#
# ── Boundary ─────────────────────────────────────────────────────────────────
# GEOMETRY AND PREDICATES ONLY. This answers questions and owns the timer FIELDS
# those answers read; the controller advances every timer and makes every
# transition. Do NOT add a lifecycle API here (begin_cover / tick_cover_reach /
# end_cover and friends): the controller writes these fields itself, so any such
# method is unreachable the moment it is written. See
# Scripts/controllers/CLAUDE.md → "What kills a collaborator extraction".

# ── Tuning (pushed in by GoalieController._configure_collaborators) ───────────
var reach: float = 1.4                  # m — goalie-to-puck distance the stick can sweep
var max_puck_speed: float = 4.0         # m/s — above this it's a live shot, leave it
var max_height: float = 0.12            # m — puck must be on the ice
var exit_speed: float = 7.0             # m/s imparted to the swept puck
var lateral_weight: float = 1.0         # corner-ward bias (lateral vs forward)
var forward_weight: float = 0.5         # out-of-crease bias
var center_deadband: float = 0.15       # m — |puck.x| under this picks the stick side
var windup_s: float = 0.12              # s — backswing before the strike
var anim_duration: float = 0.22         # s — follow-through swing window
var cover_secure_radius: float = 0.55   # m — puck must still be this close when the glove lands
var cover_escape_height: float = 0.9    # m — above the collapsed torso = out of the smother
var body_rest_dwell_s: float = 0.3      # s — a body-rested puck must SIT there, not bounce through
var body_rest_max_height: float = 0.6   # m — pad/lap shelf envelope the glove can pin
var body_radius: float = 0.7            # m — butterfly's horizontal span

# ── Geometry / identity (set once at setup) ──────────────────────────────────
var goal_line_z: float = 0.0
var goal_center_x: float = 0.0
var direction_sign: int = 1
var catches_left: bool = true
var lane_cfg: GoalieBehaviorRules.SweepLaneConfig = null

# ── Sweep state ──────────────────────────────────────────────────────────────
# `windup_timer` counts the backswing; when it expires the caller performs the
# STRIKE (the moment the blade snaps through the puck and the clear velocity is
# applied) and `anim_timer` runs the follow-through. `anim_dir` is the
# goalie-local lateral sign of the send. `pending_cover_release` marks a windup
# begun from the COVERING hold: its strike also unlocks the pinned puck.
var clear_cooldown_timer: float = 0.0
var dwell_timer: float = 0.0
var windup_timer: float = 0.0
var anim_timer: float = 0.0
var anim_dir: float = 0.0
var pending_cover_release: bool = false

# ── Cover state ──────────────────────────────────────────────────────────────
var cover_secured: bool = false
var cover_reach_timer: float = 0.0
var cover_hold_timer: float = 0.0
var cover_cooldown_timer: float = 0.0
var body_rest_dwell_timer: float = 0.0

# ── Catch state ──────────────────────────────────────────────────────────────
var catch_secured: bool = false
var catch_pressured: bool = false
var catch_hold_timer: float = 0.0


func reset() -> void:
	clear_cooldown_timer = 0.0
	dwell_timer = 0.0
	windup_timer = 0.0
	anim_timer = 0.0
	anim_dir = 0.0
	pending_cover_release = false
	cover_secured = false
	cover_reach_timer = 0.0
	cover_hold_timer = 0.0
	cover_cooldown_timer = 0.0
	body_rest_dwell_timer = 0.0
	catch_secured = false
	catch_pressured = false
	catch_hold_timer = 0.0


func is_clearable_geometry(puck_pos: Vector3, puck_speed: float,
		goalie_pos: Vector3) -> bool:
	# In front of the goal line only — never sweep a puck behind the net.
	if (puck_pos.z - goal_line_z) * direction_sign <= 0.0:
		return false
	# On the ice only — a puck in the air is a live shot / deflection, not a loose
	# puck to sweep. Without this the goalie bats airborne pucks out of the air.
	if puck_pos.y > max_height:
		return false
	if puck_speed > max_puck_speed:
		return false
	return goalie_pos.distance_to(puck_pos) <= reach


# Is the loose puck still there for the STRIKE to hit? Mirrors the clearable
# window with a little sweep-reach slack — someone may have moved it during the
# windup.
const STRIKE_REACH_SLACK_M: float = 0.3

func is_strikeable_geometry(puck_pos: Vector3, puck_speed: float,
		goalie_pos: Vector3) -> bool:
	if (puck_pos.z - goal_line_z) * direction_sign <= 0.0:
		return false
	if puck_pos.y > max_height:
		return false
	if puck_speed > max_puck_speed:
		return false
	return goalie_pos.distance_to(puck_pos) <= reach + STRIKE_REACH_SLACK_M


func natural_exit(puck_pos: Vector3, forced_side: float) -> Vector3:
	var default_side: float = 1.0 if catches_left else -1.0
	return GoalieBehaviorRules.compute_clear_velocity(
			puck_pos, goal_center_x, direction_sign,
			lateral_weight, forward_weight, exit_speed,
			center_deadband, default_side, forced_side)


# Lane-aware corner pick: the natural side if its exit lane is clear of opposing
# reach, else the far corner, else ZERO — meaning no safe sweep exists, which is
# the COVER read (a sweep into a covered lane just feeds an opponent's stick).
func pick_exit(puck_pos: Vector3, opponents: PackedVector3Array) -> Vector3:
	var natural: Vector3 = natural_exit(puck_pos, 0.0)
	if not GoalieBehaviorRules.sweep_lane_blocked(puck_pos, natural, opponents, lane_cfg):
		return natural
	var other: Vector3 = natural_exit(puck_pos, -signf(natural.x))
	if not GoalieBehaviorRules.sweep_lane_blocked(puck_pos, other, opponents, lane_cfg):
		return other
	return Vector3.ZERO


# ── Sweep: the windup → strike → follow-through phase machine ────────────────


func set_send_dir(vel: Vector3) -> void:
	var send_sign: float = signf(vel.x)
	if send_sign == 0.0:
		send_sign = 1.0 if catches_left else -1.0
	anim_dir = send_sign * -direction_sign


func windup_progress() -> float:
	if windup_timer <= 0.0 or windup_s <= 0.0:
		return 0.0
	return clampf(1.0 - windup_timer / windup_s, 0.0, 1.0)


# Follow-through, sin-curved 0 → 1 (peak) → 0 over `anim_duration`. Same shape as
# the lunge; a distinct timer so a clear and a lunge don't fight over one window.
func anim_progress() -> float:
	if anim_timer <= 0.0 or anim_duration <= 0.0:
		return 0.0
	var elapsed: float = clampf((anim_duration - anim_timer) / anim_duration, 0.0, 1.0)
	return sin(PI * elapsed)


const COVER_ESCAPE_SLACK_M: float = 0.3

func cover_escaped(dist: float, puck_speed: float, puck_height: float) -> bool:
	return dist > cover_secure_radius + COVER_ESCAPE_SLACK_M \
			or puck_speed > max_puck_speed \
			or puck_height > cover_escape_height


# Run the reach race. Returns REACH_PENDING while the glove is still travelling,
# REACH_SECURED on the tick it lands with the puck still under it, or REACH_LOST
# if it landed and the puck had slipped out of the secure radius.

func tick_body_rest(delta: float, puck_pos: Vector3, puck_speed: float,
		goalie_pos: Vector3) -> bool:
	if not GoalieBehaviorRules.puck_resting_on_goalie(
			puck_pos, puck_speed, goalie_pos, max_height,
			body_rest_max_height, body_radius, max_puck_speed):
		body_rest_dwell_timer = 0.0
		return false
	body_rest_dwell_timer += delta
	if body_rest_dwell_timer < body_rest_dwell_s:
		return false
	body_rest_dwell_timer = 0.0
	return true


# ── Catch-and-hold (glove) ───────────────────────────────────────────────────