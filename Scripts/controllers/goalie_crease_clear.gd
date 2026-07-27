class_name GoalieCreaseClear
extends RefCounted

# Loose-puck resolution in the blue paint — the sweep / cover / catch lifecycles,
# extracted from GoalieController (#519).
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
# ── Boundary (deliberately different from GoaliePuckPlay) ────────────────────
# This object owns the DECISIONS and the TIMERS. It owns no puck writes at all.
#
# That split is not arbitrary: unlike the behind-net trip, this behaviour is
# almost entirely *mutation* — pickup_locked, motion_pinned, set_puck_velocity,
# set_puck_position, apply_goalie_sweep, stick collision, and the `puck_covered`
# signal. Those are the future GoalieActuation layer, so pulling them into a
# behaviour object would just relocate the tangle. What genuinely wants separating
# is the "should I, and how far along am I" half — the dwell and cooldown clocks,
# the lane-aware corner pick, the sweep's windup→strike→follow-through phase
# machine, the cover race, and the catch hold. That is what lives here, and it is
# all pure value math: no scene lookups, no signals, no per-tick allocation (the
# opponent scan is a caller-owned PackedVector3Array).
#
# The controller keeps: every puck write, every state-machine transition, the
# stick-collision toggle, and the skater scans.

# ── Tuning (pushed in by GoalieController._configure_collaborators) ───────────
var reach: float = 1.4                  # m — goalie-to-puck distance the stick can sweep
var max_puck_speed: float = 4.0         # m/s — above this it's a live shot, leave it
var max_height: float = 0.12            # m — puck must be on the ice
var dwell: float = 0.35                 # s — must sit clearable this long before the sweep
var exit_speed: float = 7.0             # m/s imparted to the swept puck
var lateral_weight: float = 1.0         # corner-ward bias (lateral vs forward)
var forward_weight: float = 0.5         # out-of-crease bias
var center_deadband: float = 0.15       # m — |puck.x| under this picks the stick side
var cooldown: float = 0.45              # s between sweeps (anti-dribble)
var windup_s: float = 0.12              # s — backswing before the strike
var anim_duration: float = 0.22         # s — follow-through swing window
var cover_reach_time: float = 0.35      # s — glove-to-puck smother race window
var cover_secure_radius: float = 0.55   # m — puck must still be this close when the glove lands
var cover_hold_s: float = 0.85          # s — ARCADE hold before the live release
var cover_cooldown_s: float = 7.0       # s — between covers (success or failed gamble)
var cover_escape_height: float = 0.9    # m — above the collapsed torso = out of the smother
var body_rest_dwell_s: float = 0.3      # s — a body-rested puck must SIT there, not bounce through
var body_rest_max_height: float = 0.6   # m — pad/lap shelf envelope the glove can pin
var body_radius: float = 0.7            # m — butterfly's horizontal span
var catch_quick_drop_s: float = 0.4     # s — unpressured look-and-drop beat

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


func tick_cover_cooldown(delta: float) -> void:
	if cover_cooldown_timer > 0.0:
		cover_cooldown_timer = maxf(cover_cooldown_timer - delta, 0.0)


func cover_ready() -> bool:
	return cover_cooldown_timer <= 0.0


# ── Sweep: the clearable window ──────────────────────────────────────────────
# GEOMETRY only — is the puck sitting on the ice, in front of the goal line, slow
# and close enough to sweep? The caller supplies the scene-level gates (loose,
# unlocked, not reacting, not post-integrated, not covering), because those are
# state-machine and actor questions rather than geometric ones.
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


# Accumulate the settle dwell. The puck must sit clearable for a beat before the
# sweep fires, or the goalie bats pucks away the instant they drift into reach.
# Returns true once the dwell is satisfied.
func accumulate_dwell(delta: float, clearable: bool) -> bool:
	if not clearable:
		dwell_timer = 0.0
		return false
	dwell_timer += delta
	return dwell_timer >= dwell


# Tick the anti-dribble cooldown; true while it still blocks a fresh sweep.
func consume_clear_cooldown(delta: float) -> bool:
	if clear_cooldown_timer <= 0.0:
		return false
	clear_cooldown_timer = maxf(clear_cooldown_timer - delta, 0.0)
	return true


# ── Sweep: which corner ──────────────────────────────────────────────────────
# Natural-side exit (dead-centre pucks default to the goalie's stick side);
# `forced_side` != 0 overrides toward that corner.
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
# The clear is windup → STRIKE → follow-through. The decision starts a backswing;
# the clear VELOCITY applies only at the strike, when the blade snaps through the
# puck — so the stick is visibly what clears it, instead of the puck departing by
# itself with a trailing cosmetic wave. During the windup the puck is still live:
# if it gets whacked away or picked up first, the strike whiffs (the follow-through
# still plays — an honest missed sweep).
#
# `planned_vel` only picks the windup's visual direction; the caller re-solves the
# lane-aware exit at strike time against the live world.
func begin_windup(planned_vel: Vector3, cover_release: bool) -> void:
	pending_cover_release = cover_release
	windup_timer = windup_s
	dwell_timer = 0.0
	set_send_dir(planned_vel)


# Goalie-local lateral sign of the send, for the pose builder's swing direction.
func set_send_dir(vel: Vector3) -> void:
	var send_sign: float = signf(vel.x)
	if send_sign == 0.0:
		send_sign = 1.0 if catches_left else -1.0
	anim_dir = send_sign * -direction_sign


# True on the tick the backswing completes — the caller performs the strike.
func tick_windup(delta: float) -> bool:
	if windup_timer <= 0.0:
		return false
	windup_timer = maxf(windup_timer - delta, 0.0)
	return windup_timer <= 0.0


# True on the tick the follow-through window closes — the caller restores the
# stick's normal save collision.
func tick_anim(delta: float) -> bool:
	if anim_timer <= 0.0:
		return false
	anim_timer = maxf(anim_timer - delta, 0.0)
	return anim_timer <= 0.0


func begin_follow_through() -> void:
	anim_timer = anim_duration
	pending_cover_release = false


func start_clear_cooldown() -> void:
	clear_cooldown_timer = cooldown


func windup_in_flight() -> bool:
	return windup_timer > 0.0


# Windup (backswing) progress, 0 → 1 as the blade cocks over `windup_s`.
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


# Cancel an in-flight windup (the cover it belonged to fell through). Returns true
# when the caller must hand the stick its collision back — i.e. no follow-through
# is running to do it via `tick_anim`.
func cancel_windup() -> bool:
	if windup_timer <= 0.0:
		return false
	windup_timer = 0.0
	pending_cover_release = false
	return anim_timer <= 0.0


# ── Cover (smother) ──────────────────────────────────────────────────────────
# The smother is a race: the glove takes `cover_reach_time` to land, and until it
# does the puck is still live — a whack that moves it aborts the cover into a
# scramble. That gamble is the point.
func begin_cover() -> void:
	cover_secured = false
	cover_reach_timer = cover_reach_time
	cover_hold_timer = 0.0


# Has the puck escaped the collapsing body before the glove landed? Height uses
# the collapsed-body window, NOT the sweep's on-ice ceiling — a body-rested cover
# starts with the puck already at pad-top height and must not insta-abort. A real
# whack that pops it out also gives it speed, which the velocity gate reads.
const COVER_ESCAPE_SLACK_M: float = 0.3

func cover_escaped(dist: float, puck_speed: float, puck_height: float) -> bool:
	return dist > cover_secure_radius + COVER_ESCAPE_SLACK_M \
			or puck_speed > max_puck_speed \
			or puck_height > cover_escape_height


# Run the reach race. Returns REACH_PENDING while the glove is still travelling,
# REACH_SECURED on the tick it lands with the puck still under it, or REACH_LOST
# if it landed and the puck had slipped out of the secure radius.
enum { REACH_PENDING, REACH_SECURED, REACH_LOST }

func tick_cover_reach(delta: float, dist: float) -> int:
	cover_reach_timer -= delta
	if cover_reach_timer > 0.0:
		return REACH_PENDING
	if dist > cover_secure_radius:
		return REACH_LOST
	cover_secured = true
	cover_hold_timer = cover_hold_s
	return REACH_SECURED


# Run the ARCADE hold-and-release clock. True on the tick the hold expires and the
# goalie should wind up the release sweep.
func tick_cover_hold(delta: float) -> bool:
	cover_hold_timer -= delta
	return cover_hold_timer <= 0.0


func end_cover() -> void:
	cover_secured = false
	cover_cooldown_timer = cover_cooldown_s


# A puck at REST ON the goalie's body — a deadened save settling on top of the
# butterfly pads. The goalie is the only body that can support a puck off the ice
# (the puck mask excludes skaters), and a pad-shelf puck is unplayable through
# every normal path, so it triggers the same smother. Detection is the pure
# GoalieBehaviorRules window held for a dwell; returns true once the dwell is met.
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
# A controlled glove save is a CATCH: the puck pins into the glove instead of
# dropping dead at the feet. Held UNDER PRESSURE it freezes the play (the same
# rails as the smother); UNPRESSURED it quick-drops after a beat and plays on.
func begin_catch(pressured: bool) -> void:
	catch_secured = false
	catch_pressured = pressured
	catch_hold_timer = cover_hold_s if pressured else catch_quick_drop_s


# True on the tick the squeeze expires and the goalie should set the puck down.
func tick_catch_hold(delta: float) -> bool:
	catch_hold_timer -= delta
	return catch_hold_timer <= 0.0
