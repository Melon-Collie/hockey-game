class_name GoalieController
extends Node

# ── Tuning ────────────────────────────────────────────────────────────────────
@export var catches_left: bool = true

@export var depth_aggressive: float = 1.2
@export var depth_base: float = 0.6
@export var depth_conservative: float = 0.3
@export var depth_defensive: float = 0.1
@export var zone_post_z: float = 2.0
@export var zone_aggressive_z: float = 8.0
@export var zone_base_z: float = 12.0
@export var zone_conservative_z: float = 20.0
@export var depth_speed: float = 2.0

@export var shuffle_speed: float = 2.0
@export var t_push_speed: float = 3.8
@export var lateral_threshold: float = 0.3
@export var max_facing_angle: float = 70.0
@export var rotation_speed: float = 8.0
@export var rvh_transition_speed: float = 6.0

@export var reaction_delay: float = 0.13

@export var shot_speed_threshold: float = 5.0
@export var net_half_width: float = 0.915
# Margin past the net edges for "is this a shot on goal" classification. Real
# goalies react to shots heading at their body even if technically wide of
# the post (a goalie is ~0.5m wide). Larger values misclassify passes through
# the slot as shots — was 1.0, dropped to 0.5 to roughly match a body-width
# reaction range.
@export var net_margin: float = 0.5

@export var rvh_depth: float = 0.1
@export var rvh_early_angle: float = 80.0
@export var rvh_post_pad_angle: float = 15.0

@export var five_hole_base: float = 0.02
@export var five_hole_shuffle_max: float = 0.06
@export var five_hole_t_push_max: float = 0.15

@export var tracking_speed: float = 6.0
@export var part_lerp_speed: float = 6.0
@export var reaction_lerp_speed: float = 18.0
# Recovery rises body parts from butterfly pose → READY pose. Default tuned
# so the rise is ~95% complete by `recovery_duration = 0.35 s` (lerp speed
# ≈ 3 / duration). Was 3.0 which only converged ~65% — body still looked
# half-butterfly when recovery ended.
@export var recovery_lerp_speed: float = 9.0

# ── Threat tracking ───────────────────────────────────────────────────────────
# "Play the chest, not the puck": carrier body is steady while the puck swings
# ±1.5 m during stickhandling. Higher weights track the carrier; pure-puck
# tracking causes the goalie to shuffle perfectly into 5-hole shots.
@export var shooter_weight_standing: float = 0.75
@export var shooter_weight_butterfly: float = 0.90  # more committed when down

# ── Butterfly commitment ─────────────────────────────────────────────────────
# Once the goalie drops they cannot stand-skate. Lateral movement is via
# committed butterfly slides only. They cannot reach RVH directly — must
# stand up first (RECOVERING window).
@export var butterfly_min_hold_time: float = 0.35   # s the goalie must stay down
@export var recovery_duration: float = 0.35         # s spent standing back up
@export var butterfly_drop_speed: float = 0.08      # s for pads to close to floor
@export var butterfly_radius: float = 0.40          # arc radius from goal center while down

# ── Butterfly slide (commit-and-ride) ────────────────────────────────────────
# Real goalies plant the outside leg, push off, and slide on the inside pad in
# a STRAIGHT LINE. Destination is committed at slide-start; mid-slide can't
# correct. That's the realism win — fast cross-passes can beat the slide
# because the goalie picked the wrong destination.
@export var slide_initial_speed: float = 4.5        # m/s push-off speed
@export var slide_friction: float = 6.0             # m/s² decay
@export var slide_min_speed: float = 0.3            # m/s — slide ends below this
@export var slide_trigger_distance: float = 0.40    # m — threat-X delta needed to commit
@export var slide_cooldown: float = 0.20            # s between committed slides
# Suppress slide triggers for this long after a "shot event" — either a shot
# being released OR the puck contacting the goalie. Real goalies track up to
# release, then commit to their read and process the outcome; they can't
# simultaneously read a shot AND react to a new lateral threat. After a save,
# deflection trajectories are also unpredictable in this window. One timer
# covers both cases.
@export var post_event_slide_lockout: float = 0.30

# ── Slapper tell ──────────────────────────────────────────────────────────────
# Slapshots have a visible windup (SLAPPER_CHARGE_WITH_PUCK on the carrier).
# Goalies read it: pull slightly deeper into the crease and raise hands.
# Wrist shots have no comparable tell — react on release only.
@export var slapper_tell_depth_pull: float = 0.10   # m deeper while reading windup

# Recovery proximity: while in BUTTERFLY, the goalie won't recover if the
# puck is slow / stationary AND within this Euclidean distance. Crease
# radius is 1.83m; this gate covers genuine jam plays at the feet without
# locking butterfly during routine post-save puck-settling.
@export var recovery_proximity_threshold: float = 1.8

# Hard cap on `_reacting_to_shot` duration. The flag normally clears when
# `detect_shot` re-projection fails (puck off-target, hit boards/posts/saved),
# but pathological cases (e.g. puck bouncing around still on net) could hold
# it indefinitely and freeze the goalie's lateral movement forever. Safety net.
@export var max_reaction_duration: float = 1.5

# ── Ready stance ──────────────────────────────────────────────────────────────
# Distinct half-down stance triggered when the play is in the goalie's
# defensive half AND the puck is loose or carried by an opponent. Crouched,
# weight forward, gloves more active — closer to butterfly so the drop is
# faster, and gives the player visual signal that the goalie is engaged. The
# goalie returns to READY (not STANDING) after butterfly recovery while the
# threat persists, so they aren't bouncing all the way upright between drops.
@export var ready_zone_distance: float = 25.0  # m — puck perp distance threshold to enter READY

# ── Client Correction Tuning ──────────────────────────────────────────────────
# Server broadcasts (40 Hz) soft-correct the client-side goalie simulation.
@export var correction_blend: float = 0.40      # per-broadcast blend strength toward server
@export var correction_hard_snap: float = 1.5   # metres — snap immediately if farther than this
@export var correction_dead_zone: float = 0.02  # metres — ignore errors smaller than this

@export var low_shot_threshold: float = 0.45
@export var elevated_threshold: float = 0.45
@export var react_hand_y_min: float = 0.50
@export var react_hand_y_max: float = 1.55
@export var react_hand_z: float = -0.28

@export var five_hole_butterfly_move_max: float = 0.18  # opens with slide velocity

# ── References ────────────────────────────────────────────────────────────────
signal state_transitioned(team_id: int, new_state: int)
signal shot_reaction_started(team_id: int, impact_x: float, impact_y: float, is_elevated: bool)

var goalie: Goalie = null
var puck: Puck = null
var is_server: bool = false
var team_id: int = -1

# ── Goal Geometry ─────────────────────────────────────────────────────────────
var _goal_line_z: float = 0.0
var _goal_center_x: float = 0.0
var _direction_sign: int = 1

# ── State Machine ─────────────────────────────────────────────────────────────
# RECOVERING is the standing-back-up window after butterfly. Goalie is upright
# but can't react / drop / engage RVH during this brief vulnerable period —
# this is what makes wraparounds and quick cross-creasers work, exactly as
# real coaches drill against. Sub-states for butterfly (IDLE vs SLIDING) are
# derived from `_slide_velocity_x` magnitude, not encoded as separate enum
# values — the broadcast velocity field carries it implicitly.
# READY appended at the end so existing enum values stay stable — replay
# files recorded under previous goalie code keep decoding correctly.
enum State { STANDING, BUTTERFLY, RECOVERING, RVH_LEFT, RVH_RIGHT, READY }
var _state: State = State.STANDING

# ── Runtime ───────────────────────────────────────────────────────────────────
var _current_depth: float = 0.1
var _current_x: float = 0.0
var _target_x: float = 0.0
var _velocity_x: float = 0.0
var _velocity_z: float = 0.0
var _five_hole_openness: float = 0.0
var _tracked_threat_position: Vector3 = Vector3.ZERO
var _shot_timer: float = 0.0
var _reacting_to_shot: bool = false
var _shot_impact_x: float = 0.0
var _shot_impact_y: float = 0.0
var _shot_is_elevated: bool = false
var _prev_puck_position: Vector3 = Vector3.ZERO
var _puck_approach_velocity: float = 0.0
# Butterfly sub-state: while in BUTTERFLY, _slide_velocity_x being non-zero
# means the goalie is currently sliding (committed motion, no corrections);
# zero means IDLE (committed pose, no lateral movement).
var _slide_velocity_x: float = 0.0
var _butterfly_drop_progress: float = 0.0   # 0..1, lerps pads from standing→down
var _butterfly_hold_timer: float = 0.0      # counts up while in BUTTERFLY
var _recovery_timer: float = 0.0            # counts up while in RECOVERING
var _slide_cooldown_timer: float = 0.0      # counts up between slides
var _slide_event_lockout: float = 0.0      # counts down after puck contact
var _reaction_age: float = 0.0             # counts up while _reacting_to_shot
var _reading_slapper_tell: bool = false

# ── Client Simulation ─────────────────────────────────────────────────────────
const _CLIENT_REACTION_DURATION_S: float = 1.5  # how long the client holds the shot-reaction visual after a goalie shot RPC
var is_extrapolating: bool = false  # always false; kept for telemetry compat
var _client_reaction_timer: float = 0.0
var _last_server_ts: float = 0.0

func get_buffer_depth() -> int:
	return 0  # no longer buffering; kept for telemetry compat

# ── Setup ─────────────────────────────────────────────────────────────────────
func setup(assigned_goalie: Goalie, assigned_puck: Puck, assigned_goal_line_z: float, assigned_is_server: bool) -> void:
	goalie = assigned_goalie
	puck = assigned_puck
	is_server = assigned_is_server
	_goal_line_z = assigned_goal_line_z
	_goal_center_x = 0.0
	_direction_sign = sign(-_goal_line_z)
	_current_x = _goal_center_x
	_target_x = _goal_center_x
	_current_depth = depth_defensive
	_tracked_threat_position = puck.global_position
	_prev_puck_position = puck.global_position
	# Place the goalie in the crease BEFORE the first physics tick — otherwise
	# the actor sits at scene-default (0,0,0) and the AI skates it to position
	# on tick 1, which players see as "spawning at center ice then moving."
	goalie.set_goalie_position(_current_x, _goal_line_z + _direction_sign * _current_depth)
	goalie.set_goalie_rotation_y(PI if _direction_sign == 1 else 0.0)
	if is_server:
		puck.puck_released.connect(_on_puck_released)
		puck.puck_touched_goalie.connect(_on_puck_contact)

func is_butterfly() -> bool:
	return _state == State.BUTTERFLY

func reset_to_crease() -> void:
	_state = State.STANDING
	_current_depth = depth_defensive
	_current_x = _goal_center_x
	_target_x = _goal_center_x
	_five_hole_openness = 0.0
	_shot_timer = 0.0
	_recovery_timer = 0.0
	_reacting_to_shot = false
	_shot_impact_x = 0.0
	_shot_impact_y = 0.0
	_shot_is_elevated = false
	_slide_velocity_x = 0.0
	_butterfly_drop_progress = 0.0
	_butterfly_hold_timer = 0.0
	_slide_cooldown_timer = 0.0
	_slide_event_lockout = 0.0
	_reaction_age = 0.0
	_reading_slapper_tell = false
	_puck_approach_velocity = 0.0
	_tracked_threat_position = puck.global_position if puck != null else Vector3.ZERO
	_prev_puck_position = _tracked_threat_position
	goalie.set_goalie_position(_current_x, _goal_line_z + _direction_sign * _current_depth)
	goalie.set_goalie_rotation_y(PI if _direction_sign == 1 else 0.0)

# ── Process ───────────────────────────────────────────────────────────────────
func _physics_process(delta: float) -> void:
	if goalie == null or puck == null:
		return
	# Client runs the full goalie AI every frame using its local puck position.
	# Server broadcasts correct the AI state softly via apply_state().
	if not is_server and _client_reaction_timer > 0.0:
		_client_reaction_timer -= delta
		if _client_reaction_timer <= 0.0:
			_reacting_to_shot = false
	_update_tracking(delta)
	_update_shot_timer(delta)
	_update_state(delta)
	_update_depth(delta)
	_update_position(delta)
	_update_facing(delta)
	_update_body_parts(delta)

# ── Tracking ──────────────────────────────────────────────────────────────────
# "Threat" = where the goalie's positioning targets. Carrier body (steady)
# blends with puck (jumpy from stickhandling) per shooter_weight. With no
# carrier the puck IS the threat. Shot in flight (post-release) drops to
# pure-puck via _reacting_to_shot — see compute_threat below.
func _update_tracking(delta: float) -> void:
	# Approach velocity from raw position delta — works for carried puck too
	# (linear_velocity is ~0 while carried since the body is frozen).
	var dz: float = (puck.global_position.z - _prev_puck_position.z) * -_direction_sign
	_puck_approach_velocity = dz / maxf(delta, 0.0001)
	_prev_puck_position = puck.global_position
	# Detect slapper windup on the carrier — stance tell, not a butterfly drop.
	var carrier: Skater = puck.get_carrier()
	_reading_slapper_tell = carrier != null \
			and carrier.current_shot_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
			and _is_upright()
	# Compute desired threat target. With a carrier we lerp toward the
	# blended (chest+puck) target so stickhandling jitter is smoothed. With
	# no carrier (loose puck, rebound, shot in flight) the threat is the
	# puck position directly — lerping here makes the goalie chase stale
	# positions and commit slides to where the rebound *was*, sliding away
	# from where it actually is.
	var target_threat: Vector3 = _compute_threat_position()
	if puck.get_carrier() != null and not _reacting_to_shot:
		_tracked_threat_position = _tracked_threat_position.lerp(target_threat, tracking_speed * delta)
	else:
		_tracked_threat_position = target_threat
	if not _reacting_to_shot or not is_server:
		return
	# Pickup clears the reaction immediately. If a carrier is set, the puck
	# was a pass that landed (or a teammate cleared a rebound) — there's no
	# shot on goal anymore. Resume normal tracking right away.
	if puck.get_carrier() != null:
		_reacting_to_shot = false
		_shot_is_elevated = false
		return
	# Hard cap on reaction duration so the lateral-movement freeze can't
	# stick forever if `detect_shot` keeps returning true on a chaotic puck.
	_reaction_age += delta
	if _reaction_age >= max_reaction_duration:
		_reacting_to_shot = false
		_shot_is_elevated = false
		return
	# Re-project each frame so impact position stays accurate (handles bounces, deflections).
	# detect_shot returns is_shot=false if puck slowed or moved away from net — clears reaction.
	# Client skips this: linear_velocity is unreliable during interpolation; impact
	# position comes from the shot_reaction RPC and clears via _client_reaction_timer.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
			puck.global_position, puck.linear_velocity,
			_goal_line_z, _goal_center_x, _shot_detection_config())
	if not result.is_shot:
		_reacting_to_shot = false
		_shot_is_elevated = false
		return
	_shot_impact_x = result.impact_x
	_shot_impact_y = result.impact_y
	# If an elevated shot has since hit the ice and is now tracking low, drop butterfly.
	if _shot_is_elevated and result.is_low and _shot_timer <= 0.0:
		_shot_is_elevated = false
		_shot_timer = reaction_delay

# Threat = blend of carrier body and puck. While reacting to a shot in flight
# the puck IS the threat (no chest to chase — react to trajectory). RVH and
# recovering states use raw puck position too because the carrier's body
# isn't the relevant target there. STANDING/READY/BUTTERFLY blend chest+puck.
func _compute_threat_position() -> Vector3:
	var carrier: Skater = puck.get_carrier()
	if carrier == null or _reacting_to_shot \
			or _state == State.RVH_LEFT or _state == State.RVH_RIGHT \
			or _state == State.RECOVERING:
		return puck.global_position
	var w: float = shooter_weight_butterfly if _state == State.BUTTERFLY else shooter_weight_standing
	return GoalieBehaviorRules.compute_threat_position(
			puck.global_position, carrier.global_position, true, w)

# ── Shot Timer ────────────────────────────────────────────────────────────────
func _update_shot_timer(delta: float) -> void:
	if _shot_timer <= 0.0:
		return
	_shot_timer -= delta
	if _shot_timer <= 0.0 and _is_upright():
		_enter_butterfly()

# Upright = goalie can drop to butterfly / engage RVH from this state. Both
# STANDING and READY qualify; RECOVERING does not (it's the vulnerable
# stand-up window).
func _is_upright() -> bool:
	return _state == State.STANDING or _state == State.READY

# ── State Machine ─────────────────────────────────────────────────────────────
# Entry rules:
#   STANDING ↔ READY         ─ READY when puck is in goalie's half AND not
#                              carried by own team. STANDING otherwise (own
#                              offense, or play is in opposing half).
#   STANDING/READY → BUTTERFLY ─ shot detected (low). Pressure-triggered drop
#                                is gone — close-range non-shooting threats
#                                are answered by stick + poke check (TBD).
#   STANDING/READY → RVH_*   ─ puck enters defensive zone (behind goal / sharp angle)
#   BUTTERFLY → RECOVERING   ─ min hold elapsed && puck not pressing && not sliding
#   BUTTERFLY ↛ RVH directly ─ must recover first (vulnerable window — exactly
#                              what makes wraparounds and quick cross-creasers work)
#   RECOVERING → READY/STAND ─ recovery_duration elapsed; back into READY if
#                              the threat persists, else fully STANDING.
#   RVH_* → READY/STANDING   ─ puck leaves defensive zone; same READY check.
func _update_state(delta: float) -> void:
	var prev_state := _state
	# Shot timer is only meaningful in upright stances (STANDING / READY) — drop
	# triggers come from there. Clear it as soon as we enter any other state so
	# a returning RECOVERING/RVH transition doesn't immediately re-fire butterfly.
	if not _is_upright():
		_shot_timer = 0.0
	_slide_cooldown_timer += delta
	# Convert puck global X into goalie local X. The -Z goal goalie is rotated PI
	# so its local +X is global -X; multiplying by -_direction_sign corrects for that.
	var puck_local_x: float = (_tracked_threat_position.x - _goal_center_x) * -_direction_sign
	match _state:
		State.STANDING, State.READY:
			if _is_puck_in_defensive_zone():
				_reacting_to_shot = false
				_state = State.RVH_LEFT if puck_local_x < 0.0 else State.RVH_RIGHT
			else:
				# Toggle STANDING ↔ READY based on threat conditions.
				var should_be_ready: bool = _is_ready_situation()
				if _state == State.STANDING and should_be_ready:
					_state = State.READY
				elif _state == State.READY and not should_be_ready:
					_state = State.STANDING
		State.BUTTERFLY:
			_butterfly_hold_timer += delta
			_butterfly_drop_progress = minf(
					_butterfly_drop_progress + delta / maxf(butterfly_drop_speed, 0.001),
					1.0)
			# Recovery is gated on min-hold elapsed AND puck no longer pressing
			# AND not currently sliding. Pressure detection is one-way (entry
			# only, via shot_timer) — once committed, only these conditions
			# release the goalie. RVH from butterfly is forbidden: must stand
			# first so the goalie eats a recovery window on wraparound plays.
			var sliding: bool = absf(_slide_velocity_x) > slide_min_speed
			if _butterfly_hold_timer >= butterfly_min_hold_time and not sliding \
					and not _is_threat_pressing():
				_state = State.RECOVERING
				_recovery_timer = 0.0
				_reacting_to_shot = false
		State.RECOVERING:
			_recovery_timer += delta
			if _recovery_timer >= recovery_duration:
				_state = State.READY if _is_ready_situation() else State.STANDING
				_recovery_timer = 0.0
		State.RVH_LEFT:
			if not _is_puck_in_defensive_zone():
				_state = State.READY if _is_ready_situation() else State.STANDING
			elif puck_local_x >= 0.0:
				_state = State.RVH_RIGHT
		State.RVH_RIGHT:
			if not _is_puck_in_defensive_zone():
				_state = State.READY if _is_ready_situation() else State.STANDING
			elif puck_local_x < 0.0:
				_state = State.RVH_LEFT
	if _state != prev_state:
		_on_state_changed(prev_state, _state)
		state_transitioned.emit(team_id, _state as int)

# True when the puck is in the goalie's defensive half AND not controlled by
# the goalie's own team (loose or carried by an opponent). Drives the
# STANDING ↔ READY transition.
func _is_ready_situation() -> bool:
	# Perpendicular distance from goal line; positive = in front of goal.
	var puck_perp: float = (puck.global_position.z - _goal_line_z) * _direction_sign
	if puck_perp > ready_zone_distance:
		return false
	# Puck is in our half. If a teammate carries it, no threat — they're
	# regrouping or holding possession in own offensive zone behind us.
	var carrier: Skater = puck.get_carrier()
	if carrier != null and carrier.team_id == team_id and team_id != -1:
		return false
	return true

func _enter_butterfly() -> void:
	if _state == State.BUTTERFLY:
		return
	var prev: State = _state
	_state = State.BUTTERFLY
	_on_state_changed(prev, _state)
	state_transitioned.emit(team_id, _state as int)

func _on_state_changed(_prev: State, new_state: State) -> void:
	match new_state:
		State.BUTTERFLY:
			_butterfly_drop_progress = 0.0
			_butterfly_hold_timer = 0.0
			_slide_velocity_x = 0.0
			_slide_cooldown_timer = 0.0
			_slide_event_lockout = 0.0
		State.RECOVERING:
			_slide_velocity_x = 0.0
		State.STANDING:
			_butterfly_drop_progress = 0.0
			_slide_velocity_x = 0.0

# Should the goalie keep holding butterfly because the puck is still a threat?
# Hold conditions, in priority:
#   1. Puck is fast AND approaching      → hold (active shot/play)
#   2. Puck is moving away (any speed)   → release (rebound clearing)
#   3. Puck is slow / stationary AND close to net  → hold (jam at the feet)
#   4. Otherwise                         → release
# Pressure detection is one-way: it only HOLDS butterfly, never triggers entry.
func _is_threat_pressing() -> bool:
	var speed_low: bool
	var moving_away: bool
	if is_server:
		speed_low = puck.linear_velocity.length() < shot_speed_threshold
		moving_away = puck.linear_velocity.z * _direction_sign > 0.0
	else:
		speed_low = absf(_puck_approach_velocity) < shot_speed_threshold
		moving_away = _puck_approach_velocity < 0.0
	# Moving away is always recover — that's the rebound clearing the slot.
	if moving_away:
		return false
	# Fast and approaching = active shot/play in motion.
	if not speed_low:
		return true
	# Puck is slow and not moving away — only hold if it's right on top of us.
	# Crease radius is 1.83m, so a 1.5–2m gate covers genuine jam plays at the
	# feet without forcing butterfly during routine post-save settling.
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			puck.global_position, _goal_line_z, _goal_center_x)
	return threat_dist < recovery_proximity_threshold

# ── Depth ─────────────────────────────────────────────────────────────────────
# Standing depth is the "challenge angle" arc radius from goal center. The
# Buckley chart still drives the radius via Euclidean threat distance — the
# geometric arc emerges from `target_arc_position` consuming radius for
# lateral motion when the threat is wide. This naturally pulls the goalie
# back on sharp angles (real goalie behaviour) instead of skating a flat
# line at fixed depth.
func _update_depth(delta: float) -> void:
	if _state == State.RVH_LEFT or _state == State.RVH_RIGHT:
		_current_depth = lerpf(_current_depth, rvh_depth, depth_speed * delta)
		return
	if _state == State.BUTTERFLY:
		_current_depth = lerpf(_current_depth, butterfly_radius, depth_speed * delta)
		return
	if _state == State.RECOVERING:
		# Gentle fade back toward defensive crease while standing up.
		_current_depth = lerpf(_current_depth, depth_defensive, depth_speed * delta)
		return
	# STANDING / READY: depth chart drives radius. Slapper tell pulls deeper.
	var threat_dist: float = GoalieBehaviorRules.threat_distance_to_goal(
			_tracked_threat_position, _goal_line_z, _goal_center_x)
	var target_radius: float = GoalieBehaviorRules.target_depth_for_puck_distance(
			threat_dist, _depth_config())
	if _reading_slapper_tell:
		target_radius = maxf(target_radius - slapper_tell_depth_pull, depth_defensive)
	_current_depth = lerpf(_current_depth, target_radius, depth_speed * delta)

# ── Position ──────────────────────────────────────────────────────────────────
# STANDING uses true 2D arc tracing: target is (arc_x, arc_z) from the threat,
# and both x and z move toward it together so the goalie stays on the arc as
# it shifts. RECOVERING also uses 2D motion back toward the defensive crease.
# BUTTERFLY uses commit-and-ride; RVH uses the existing pad-flush math.
func _update_position(delta: float) -> void:
	var prev_x: float = _current_x
	var prev_z: float = goalie.global_position.z
	var new_z: float
	# `_current_depth` is the **radius from goal center** (the depth chart
	# output), not perpendicular depth — read it that way uniformly. The arc
	# move outputs a (x, z) on the radius-N arc; the goalie's actual perp
	# depth at the resulting point is naturally <= _current_depth and is NOT
	# stored back. Next frame's _update_depth keeps lerping radius toward the
	# chart target without oscillation.
	match _state:
		State.STANDING, State.READY, State.RECOVERING:
			var pair: Vector2 = _move_along_arc(delta)
			_current_x = pair.x
			new_z = pair.y
		State.BUTTERFLY:
			_update_butterfly_motion(delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		State.RVH_LEFT:
			# 0.38 = outer pad reach (0.88) - 0.50 body inset toward post.
			_current_x = move_toward(_current_x, _goal_center_x + (net_half_width - 0.38) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		State.RVH_RIGHT:
			_current_x = move_toward(_current_x, _goal_center_x - (net_half_width - 0.38) * _direction_sign, rvh_transition_speed * delta)
			new_z = _goal_line_z + _direction_sign * _current_depth
		_:
			new_z = _goal_line_z + _direction_sign * _current_depth
	if delta > 0.0:
		_velocity_x = (_current_x - prev_x) / delta
		_velocity_z = (new_z - prev_z) / delta
	goalie.set_goalie_position(_current_x, new_z)

# 2D arc tracing for STANDING/RECOVERING. Target is the arc point at the
# current radius; choose lateral speed by 2D distance so X and Z move at the
# same rate (no asymmetric snap on Z when threat angle shifts). Five-hole
# openness scales with motion category exactly as before.
#
# While `_reacting_to_shot`, lateral movement freezes entirely — the goalie
# committed to their pre-release position and is now reading the shot. They
# react with body parts (butterfly drop / glove raise) but don't slide or
# shuffle. The freeze releases when `_reacting_to_shot` clears (`detect_shot`
# re-projection in `_update_tracking` returns false on board / post / wide /
# saved pucks) or via the safety timeout in `_update_tracking`.
func _move_along_arc(delta: float) -> Vector2:
	var current := Vector2(_current_x, goalie.global_position.z)
	if _reacting_to_shot:
		if is_server:
			_five_hole_openness = lerpf(_five_hole_openness, five_hole_base, part_lerp_speed * delta)
		return current
	var target_xz: Vector2 = _arc_target_xz()
	_target_x = target_xz.x
	var delta_2d: float = current.distance_to(target_xz)
	var move_speed: float
	var five_hole_target: float
	if delta_2d < 0.01:
		move_speed = shuffle_speed
		five_hole_target = five_hole_base
	elif delta_2d > lateral_threshold:
		move_speed = t_push_speed
		five_hole_target = five_hole_t_push_max
	else:
		move_speed = shuffle_speed
		five_hole_target = five_hole_shuffle_max
	var step: float = move_speed * delta
	var new_xz: Vector2
	if delta_2d <= step or delta_2d < 0.0001:
		new_xz = target_xz
	else:
		new_xz = current + (target_xz - current) * (step / delta_2d)
	if is_server:
		_five_hole_openness = lerpf(_five_hole_openness, five_hole_target, part_lerp_speed * delta)
	return new_xz

# Arc target (x, z) at the current radius — STANDING/RECOVERING tracing.
# BUTTERFLY uses compute_slide_destination directly with butterfly_radius.
func _arc_target_xz() -> Vector2:
	return GoalieBehaviorRules.target_arc_position(
			_tracked_threat_position, _goal_line_z, _goal_center_x,
			_direction_sign, _current_depth, net_half_width)

# Butterfly motion: pure commit-and-ride. While IDLE the goalie holds position;
# while SLIDING the velocity decays via friction with NO mid-slide corrections
# (destination was committed at slide-start). Slide trigger and commit are
# host-only; clients receive position/velocity through the world-state
# broadcast and forward-predict via `apply_state`.
func _update_butterfly_motion(delta: float) -> void:
	if _slide_event_lockout > 0.0:
		_slide_event_lockout -= delta
	# Pads-to-floor snap: while the drop is animating, force five-hole closed.
	# This is the explicit fix for "shuffle-then-drop leaves a perfect 5-hole":
	# during the drop window, openness goes to zero regardless of motion.
	if is_server:
		var sliding: bool = absf(_slide_velocity_x) > slide_min_speed
		if _butterfly_drop_progress < 1.0:
			# Snap closed during the active drop animation.
			_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta * 2.0)
		elif sliding:
			# IDLE-to-SLIDING transition opens the trail-leg gap; scale with speed.
			var speed_ratio: float = clampf(absf(_slide_velocity_x) / maxf(slide_initial_speed, 0.01), 0.0, 1.0)
			_five_hole_openness = lerpf(
					_five_hole_openness,
					five_hole_butterfly_move_max * speed_ratio,
					part_lerp_speed * delta)
		else:
			# IDLE: pads on the ice, touching at the knees.
			_five_hole_openness = lerpf(_five_hole_openness, 0.0, part_lerp_speed * delta)
	# Apply slide motion if we're already sliding.
	if absf(_slide_velocity_x) > slide_min_speed:
		_current_x += _slide_velocity_x * delta
		_current_x = clampf(
				_current_x,
				_goal_center_x - net_half_width,
				_goal_center_x + net_half_width)
		# Friction decay toward zero — slide ends naturally when speed bleeds out.
		var decay: float = slide_friction * delta
		if _slide_velocity_x > 0.0:
			_slide_velocity_x = maxf(_slide_velocity_x - decay, 0.0)
		else:
			_slide_velocity_x = minf(_slide_velocity_x + decay, 0.0)
		if absf(_slide_velocity_x) <= slide_min_speed:
			_slide_velocity_x = 0.0
			_slide_cooldown_timer = 0.0  # gate the next slide
		return
	# IDLE: only host triggers a new slide. Clients passively receive the host's
	# position/velocity via apply_state and don't attempt to commit on their own
	# (the host's threat data is canonical; client-local commits would diverge).
	if not is_server:
		return
	if _slide_cooldown_timer < slide_cooldown:
		return
	# Don't trigger slides during the drop animation — the goalie is still
	# closing pads. Only commit slides once the goalie is fully down.
	if _butterfly_drop_progress < 1.0:
		return
	# Suppress slides for a brief window after the puck contacts the goalie —
	# deflection trajectories are unpredictable and re-snapping threat to a
	# bouncing puck causes spurious slide commits.
	if _slide_event_lockout > 0.0:
		return
	var slide_target: Vector2 = GoalieBehaviorRules.compute_slide_destination(
			_tracked_threat_position, _goal_line_z, _goal_center_x,
			_direction_sign, butterfly_radius, net_half_width)
	if not GoalieBehaviorRules.should_commit_slide(_current_x, slide_target.x, slide_trigger_distance):
		return
	# Commit. Direction picked once; magnitude rides out via friction.
	var dir: float = signf(slide_target.x - _current_x)
	_slide_velocity_x = dir * slide_initial_speed
	_slide_cooldown_timer = 0.0

# ── Facing ────────────────────────────────────────────────────────────────────
# Threat-based facing: rotate toward where the goalie is tracking, not raw
# puck position. Stickhandling jitter no longer twists the body. Real goalies
# keep the body square once down — only the head/upper body track the puck
# (which we don't model), so BUTTERFLY/RECOVERING hold the body squared to
# centre. Rotating the entire rotation_y in butterfly looks unrealistic.
func _update_facing(delta: float) -> void:
	if _state == State.RVH_LEFT or _state == State.RVH_RIGHT:
		var target_y: float = PI if _direction_sign == 1 else 0.0
		goalie.set_goalie_rotation_y(lerp_angle(goalie.get_goalie_rotation_y(), target_y, rotation_speed * delta))
		return
	# Same freeze as `_move_along_arc` — once the shot's been released the
	# goalie commits and reads, no body rotation tracking the puck. Especially
	# visible on elevated shots where `_shot_timer` is never set (no butterfly
	# drop) and the rotation is otherwise the only thing the player sees move.
	if _reacting_to_shot:
		return
	if _shot_timer > 0.0:
		return
	if _state == State.BUTTERFLY or _state == State.RECOVERING:
		# Body stays square in butterfly; gentle return to centre during recovery.
		var center_angle: float = PI if _direction_sign == 1 else 0.0
		var return_speed: float = rotation_speed * 0.5 if _state == State.RECOVERING else rotation_speed * 0.25
		goalie.set_goalie_rotation_y(lerp_angle(
				goalie.get_goalie_rotation_y(), center_angle, return_speed * delta))
		return
	var dx: float = _tracked_threat_position.x - goalie.global_position.x
	var dz: float = _tracked_threat_position.z - goalie.global_position.z
	if Vector2(dx, dz).length() > 0.1:
		var base_angle: float = PI if _direction_sign == 1 else 0.0
		var target_y: float = atan2(-dx, -dz)
		var max_rad: float = deg_to_rad(max_facing_angle)
		var deviation: float = clampf(angle_difference(base_angle, target_y), -max_rad, max_rad)
		target_y = base_angle + deviation
		var new_y: float = lerp_angle(goalie.get_goalie_rotation_y(), target_y, rotation_speed * delta)
		goalie.set_goalie_rotation_y(new_y)

# ── Body Parts ────────────────────────────────────────────────────────────────
func _update_body_parts(delta: float) -> void:
	var config: GoalieBodyConfig = _get_config(_state)
	var lerp_t: float
	if _state == State.BUTTERFLY:
		# Drop snap: scale lerp speed inversely with butterfly_drop_speed so the
		# pads close fast (shorter butterfly_drop_speed → faster lerp). Once the
		# drop is complete, fall back to reaction speed for any remaining tweaks.
		var drop_lerp: float = 1.0 / maxf(butterfly_drop_speed, 0.001)
		lerp_t = drop_lerp * delta if _butterfly_drop_progress < 1.0 else reaction_lerp_speed * delta
	elif _reacting_to_shot:
		lerp_t = reaction_lerp_speed * delta
	elif _state == State.RECOVERING:
		lerp_t = recovery_lerp_speed * delta
	else:
		lerp_t = part_lerp_speed * delta
	goalie.apply_body_config(config, lerp_t)

func _get_config(state: State) -> GoalieBodyConfig:
	var c := GoalieBodyConfig.new()
	# Y-rotation on standing/ready/butterfly pads angles the toes outward so
	# pucks deflect toward the corners and boards instead of bouncing back
	# into the slot. Real goalies actively rotate the pads to control rebound
	# direction; here we approximate with a fixed angle since we don't model
	# active pad-angling behaviour.
	const PAD_TOE_OUT_DEG_STANDING: float = 8.0
	const PAD_TOE_OUT_DEG_BUTTERFLY: float = 12.0
	match state:
		State.STANDING:
			c.left_pad_pos  = Vector3(-0.22 - _five_hole_openness, 0.44, -0.20)
			c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_STANDING, -12.0)
			c.right_pad_pos = Vector3( 0.22 + _five_hole_openness, 0.44, -0.20)
			c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_STANDING,  12.0)
			c.body_pos      = Vector3(0.0,  1.16,  0.0)
			c.body_rot      = Vector3.ZERO
			c.head_pos      = Vector3(0.0,  1.69,  0.08)
			c.head_rot      = Vector3.ZERO
			c.blocker_pos   = Vector3( 0.38, 1.24, -0.18)
			c.blocker_rot   = Vector3.ZERO
			c.glove_pos     = Vector3(-0.35, 1.19, -0.18)
			c.glove_rot     = Vector3.ZERO
			c.stick_pos     = Vector3(0.0,  0.02,  -0.25)
			c.stick_rot     = Vector3.ZERO
			# Slapper tell: hands raised slightly to a half-ready position.
			# Pose-only — does not commit butterfly. Runs before elevated-shot
			# reach so a real elevated shot can still override hand position.
			if _reading_slapper_tell:
				c.glove_pos.y += 0.06
				c.blocker_pos.y += 0.06
			_apply_elevated_shot_reaction(c)
		State.READY, State.RECOVERING:
			# Half-down active stance: deep knee bend, weight well forward,
			# gloves dropped and reaching forward. Distinct silhouette from
			# STANDING — players should be able to read intent at a glance.
			# RECOVERING shares this pose: real goalies push up FROM butterfly
			# INTO a ready stance, not all the way to fully standing. If the
			# threat eases after recovery, the state becomes STANDING and the
			# body lerps the rest of the way up; if it persists the body is
			# already at READY and just stays there — single smooth rising
			# motion, no up-then-back-down overshoot.
			c.left_pad_pos  = Vector3(-0.22 - _five_hole_openness, 0.34, -0.16)
			c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_STANDING, -10.0)
			c.right_pad_pos = Vector3( 0.22 + _five_hole_openness, 0.34, -0.16)
			c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_STANDING,  10.0)
			c.body_pos      = Vector3(0.0,  0.92, -0.05)
			c.body_rot      = Vector3(-14.0, 0.0, 0.0)
			c.head_pos      = Vector3(0.0,  1.40, -0.22)
			c.head_rot      = Vector3.ZERO
			c.blocker_pos   = Vector3( 0.44, 0.94, -0.32)
			c.blocker_rot   = Vector3.ZERO
			c.glove_pos     = Vector3(-0.42, 0.90, -0.32)
			c.glove_rot     = Vector3.ZERO
			c.stick_pos     = Vector3(0.0,  0.02, -0.28)
			c.stick_rot     = Vector3.ZERO
			if _reading_slapper_tell:
				c.glove_pos.y += 0.06
				c.blocker_pos.y += 0.06
			_apply_elevated_shot_reaction(c)
		State.BUTTERFLY:
			c.left_pad_pos  = Vector3(-0.42 - _five_hole_openness, 0.14, -0.20)
			c.left_pad_rot  = Vector3(0.0,  PAD_TOE_OUT_DEG_BUTTERFLY, -90.0)
			c.right_pad_pos = Vector3( 0.42 + _five_hole_openness, 0.14, -0.20)
			c.right_pad_rot = Vector3(0.0, -PAD_TOE_OUT_DEG_BUTTERFLY,  90.0)
			c.body_pos      = Vector3(0.0,  0.46,  0.0)
			c.body_rot      = Vector3.ZERO
			c.head_pos      = Vector3(0.0,  0.99,  0.08)
			c.head_rot      = Vector3.ZERO
			c.blocker_pos   = Vector3( 0.46, 0.49, -0.18)
			c.blocker_rot   = Vector3.ZERO
			c.glove_pos     = Vector3(-0.42, 0.44, -0.18)
			c.glove_rot     = Vector3.ZERO
			c.stick_pos     = Vector3(0.0,  0.02,  -0.30)
			c.stick_rot     = Vector3.ZERO
			_apply_elevated_shot_reaction(c)
		State.RVH_LEFT:
			c.left_pad_pos  = Vector3( 0.04, 0.14, 0.0)
			c.left_pad_rot  = Vector3(0.0, rvh_post_pad_angle, -90.0)
			c.right_pad_pos = Vector3( 0.45, 0.33, 0.0)
			c.right_pad_rot = Vector3(0.0, 0.0,  60.0)
			c.body_pos      = Vector3(-0.02, 0.66,  0.05)
			c.body_rot      = Vector3.ZERO
			c.head_pos      = Vector3(-0.02, 1.19,  0.08)
			c.head_rot      = Vector3.ZERO
			c.glove_pos     = Vector3(-0.12, 0.69, -0.18)
			c.glove_rot     = Vector3.ZERO
			c.blocker_pos   = Vector3( 0.40, 0.64, -0.18)
			c.blocker_rot   = Vector3.ZERO
			c.stick_pos     = Vector3( 0.20, 0.02, -0.20)
			c.stick_rot     = Vector3.ZERO
		State.RVH_RIGHT:
			c.right_pad_pos = Vector3(-0.04, 0.14, 0.0)
			c.right_pad_rot = Vector3(0.0, -rvh_post_pad_angle,  90.0)
			c.left_pad_pos  = Vector3(-0.45, 0.33, 0.0)
			c.left_pad_rot  = Vector3(0.0, 0.0, -60.0)
			c.body_pos      = Vector3( 0.02, 0.66,  0.05)
			c.body_rot      = Vector3.ZERO
			c.head_pos      = Vector3( 0.02, 1.19,  0.08)
			c.head_rot      = Vector3.ZERO
			c.blocker_pos   = Vector3( 0.12, 0.69, -0.18)
			c.blocker_rot   = Vector3.ZERO
			c.glove_pos     = Vector3(-0.40, 0.64, -0.18)
			c.glove_rot     = Vector3.ZERO
			c.stick_pos     = Vector3(-0.20, 0.02, -0.20)
			c.stick_rot     = Vector3.ZERO
	if not catches_left:
		var tmp_pos: Vector3 = c.glove_pos
		var tmp_rot: Vector3 = c.glove_rot
		c.glove_pos   = Vector3(-c.blocker_pos.x, c.blocker_pos.y, c.blocker_pos.z)
		c.glove_rot   = c.blocker_rot
		c.blocker_pos = Vector3(-tmp_pos.x, tmp_pos.y, tmp_pos.z)
		c.blocker_rot = tmp_rot
	return c

# Move glove or blocker toward projected impact height when reacting to an
# elevated shot. shot_local_x > 0 = goalie's right = blocker side (for
# catches_left=true). Called from STANDING/BUTTERFLY branches of _get_config.
func _apply_elevated_shot_reaction(c: GoalieBodyConfig) -> void:
	if not _reacting_to_shot or not _shot_is_elevated:
		return
	var shot_local_x: float = (_shot_impact_x - _goal_center_x) * -_direction_sign
	var target_y: float = clampf(_shot_impact_y, react_hand_y_min, react_hand_y_max)
	if shot_local_x <= 0.0:
		c.glove_pos = Vector3(c.glove_pos.x, target_y, react_hand_z)
		c.glove_rot = Vector3(-25.0, 0.0, 0.0)
	else:
		c.blocker_pos = Vector3(c.blocker_pos.x, target_y, react_hand_z)
		c.blocker_rot = Vector3(-25.0, 0.0, 0.0)

# ── Shot Detection ────────────────────────────────────────────────────────────
func _on_puck_released() -> void:
	if not _is_upright():
		return
	# `get_release_velocity` returns the impending velocity even when
	# `linear_velocity` is still zero (Jolt's frozen→dynamic transition queues
	# the velocity in `_pending_elevation_vel` for the next physics step).
	# Reading raw `linear_velocity` here misses the shot every time.
	var result: GoalieBehaviorRules.ShotResult = GoalieBehaviorRules.detect_shot(
			puck.global_position,
			puck.get_release_velocity(),
			_goal_line_z,
			_goal_center_x,
			_shot_detection_config())
	if not result.is_shot:
		return
	_shot_impact_x = result.impact_x
	_shot_impact_y = result.impact_y
	_shot_is_elevated = result.is_elevated
	_reacting_to_shot = true
	_reaction_age = 0.0
	# Goalies track up until release, then commit to their read — they need a
	# beat to process the shot before they can react to a new lateral threat.
	# Suppresses slide triggers during that window. Same mechanism as the
	# post-contact lockout; one runtime timer covers both events (max wins).
	_slide_event_lockout = maxf(_slide_event_lockout, post_event_slide_lockout)
	shot_reaction_started.emit(team_id, _shot_impact_x, _shot_impact_y, _shot_is_elevated)
	if result.is_low:
		_shot_timer = result.reaction_delay
	# Elevated shot: stay standing, _get_config raises the glove or blocker

# Puck just hit a goalie body part. Re-arms the slide lockout so deflections
# don't trigger spurious slides, and clears the reaction freeze — the goalie
# has physically engaged with the shot, so they're no longer "reading" it.
# Subsequent rebounds are tracked normally (with the slide lockout still
# active, so no spam slide-reactions). Filters by identity since
# `Puck.puck_touched_goalie` fires on either net's goalie.
func _on_puck_contact(contacted: Goalie) -> void:
	if contacted != goalie:
		return
	_slide_event_lockout = maxf(_slide_event_lockout, post_event_slide_lockout)
	_reacting_to_shot = false
	_shot_is_elevated = false

# ── State Serialization ───────────────────────────────────────────────────────
# Returns the typed network state object. Flattening to Array happens at the
# RPC boundary (GameManager.get_world_state), not here.
func get_state() -> GoalieNetworkState:
	var s := GoalieNetworkState.new()
	s.position_x = goalie.global_position.x
	s.position_z = goalie.global_position.z
	s.rotation_y = goalie.get_goalie_rotation_y()
	s.state_enum = _state as int
	s.five_hole_openness = _five_hole_openness
	s.velocity_x = _velocity_x
	s.velocity_z = _velocity_z
	return s

func apply_state(network_state: GoalieNetworkState, host_ts: float) -> void:
	if is_server:
		return
	if host_ts < _last_server_ts:
		return  # out-of-order packet; discard
	_last_server_ts = host_ts
	# Forward-predict server position to compensate for broadcast transit time.
	# elapsed ≈ RTT/2 at call-time; capped to avoid over-shooting on bad connections.
	var elapsed: float = clampf(NetworkManager.estimated_host_time() - host_ts, 0.0, 0.15)
	var predicted_x: float = network_state.position_x + network_state.velocity_x * elapsed
	var predicted_z: float = network_state.position_z + network_state.velocity_z * elapsed
	# `_current_depth` carries different units per state — it's the arc radius
	# (Euclidean to goal center) in STANDING/RECOVERING and perpendicular depth
	# in BUTTERFLY/RVH. Pick the right one to lerp toward so the client doesn't
	# fight its own AI. Both reduce to the same value at the centerline.
	var server_dx: float = predicted_x - _goal_center_x
	var server_dz: float = predicted_z - _goal_line_z
	var server_depth_value: float
	if _state == State.STANDING or _state == State.READY or _state == State.RECOVERING:
		server_depth_value = sqrt(server_dx * server_dx + server_dz * server_dz)
	else:
		server_depth_value = server_dz * _direction_sign
	var client_z: float = goalie.global_position.z
	var dist: float = Vector2(_current_x - predicted_x, client_z - predicted_z).length()
	if dist > correction_hard_snap:
		_current_x = predicted_x
		_current_depth = server_depth_value
	elif dist > correction_dead_zone:
		_current_x = lerpf(_current_x, predicted_x, correction_blend)
		_current_depth = lerpf(_current_depth, server_depth_value, correction_blend)
	# Five hole: strong blend so client visual matches server physics within ~50 ms.
	# Client AI doesn't compute _five_hole_openness, so nothing fights the correction.
	_five_hole_openness = lerpf(_five_hole_openness, network_state.five_hole_openness, 0.80)

func apply_replay_state(state: GoalieNetworkState, delta: float) -> void:
	_state = state.state_enum as State
	_five_hole_openness = state.five_hole_openness
	_update_body_parts(delta)
	goalie.set_goalie_position(state.position_x, state.position_z)
	goalie.set_goalie_rotation_y(state.rotation_y)


func apply_state_transition(new_state: int) -> void:
	if is_server:
		return
	var prev_state: State = _state
	_state = new_state as State
	# Mirror host-side _on_state_changed so client timers stay aligned (drop
	# progress drives the body-parts lerp speed during the butterfly drop).
	_on_state_changed(prev_state, _state)
	if new_state == State.STANDING as int or new_state == State.READY as int:
		_reacting_to_shot = false
		_client_reaction_timer = 0.0
		_shot_timer = 0.0
	elif new_state == State.RECOVERING as int:
		_recovery_timer = 0.0
		_reacting_to_shot = false

func apply_shot_reaction(impact_x: float, impact_y: float, is_elevated: bool) -> void:
	if is_server:
		return
	_reacting_to_shot = true
	_shot_impact_x = impact_x
	_shot_impact_y = impact_y
	_shot_is_elevated = is_elevated
	_client_reaction_timer = _CLIENT_REACTION_DURATION_S
	# Mirror the host: low shots start the butterfly-drop countdown so the
	# client drops butterfly on the same frame cadence as the server.
	# Subtract the RPC transit time (≈ full RTT: shooter→server + server→client)
	# so the client butterfly lands at the same wall-clock offset as the host.
	# At RTT < reaction_delay the timer fires early enough to match T+reaction_delay.
	# At RTT >= reaction_delay the timer is clamped to 0 — butterfly drops on arrival.
	if not is_elevated and _is_upright():
		var rtt_s: float = NetworkManager.get_latest_rtt_ms() / 1000.0
		_shot_timer = maxf(reaction_delay - rtt_s, 0.0)

# ── Helpers ───────────────────────────────────────────────────────────────────
# Defensive-zone test uses raw puck position, not threat — the goalie reacts
# to where the puck physically is for RVH gating, not the blended chest.
func _is_puck_in_defensive_zone() -> bool:
	return GoalieBehaviorRules.is_puck_in_defensive_zone(
			puck.global_position, _goal_line_z, _goal_center_x,
			_direction_sign, _defensive_zone_config())

# ── Rule configs ──────────────────────────────────────────────────────────────
func _shot_detection_config() -> GoalieBehaviorRules.ShotDetectionConfig:
	var cfg := GoalieBehaviorRules.ShotDetectionConfig.new()
	cfg.shot_speed_threshold = shot_speed_threshold
	cfg.net_half_width = net_half_width
	cfg.net_margin = net_margin
	cfg.reaction_delay = reaction_delay
	cfg.low_shot_threshold = low_shot_threshold
	cfg.elevated_threshold = elevated_threshold
	return cfg

func _defensive_zone_config() -> GoalieBehaviorRules.DefensiveZoneConfig:
	var cfg := GoalieBehaviorRules.DefensiveZoneConfig.new()
	cfg.zone_post_z = zone_post_z
	cfg.rvh_early_angle = rvh_early_angle
	return cfg

func _depth_config() -> GoalieBehaviorRules.DepthConfig:
	var cfg := GoalieBehaviorRules.DepthConfig.new()
	cfg.zone_post_z = zone_post_z
	cfg.zone_aggressive_z = zone_aggressive_z
	cfg.zone_base_z = zone_base_z
	cfg.zone_conservative_z = zone_conservative_z
	cfg.depth_aggressive = depth_aggressive
	cfg.depth_base = depth_base
	cfg.depth_conservative = depth_conservative
	cfg.depth_defensive = depth_defensive
	return cfg
