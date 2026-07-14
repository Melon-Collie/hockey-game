class_name GameCamera
extends Camera3D

# ── Target References ─────────────────────────────────────────────────────────
@export var skater: Skater
@export var puck: Puck
@export var local_controller: LocalController

# ── Locked framing ────────────────────────────────────────────────────────────
# When true (or when the user picks Locked in Options, or no puck exists) the
# camera pins its center on the player and zooms out only enough to keep the
# puck in frame when the puck is actually in play. A stashed / off-rink / absent
# puck leaves the camera sitting centered on the player. The tutorial forces this
# on for its puckless movement steps via LocalController.set_camera_force_locked.
var force_locked: bool = false
# Margin (m) beyond the rink bounds within which a puck still counts as "in play"
# for locked-mode framing. A tutorial-stashed puck sits far outside this.
const _ON_RINK_MARGIN: float = 5.0

# ── Zone Bias ─────────────────────────────────────────────────────────────────
# Fraction of available slack to use when shifting toward the attacking zone.
# 1.0 = push player/puck to the trailing edge of the frame; 0.0 = no bias.
@export var zone_bias: float = 0.7
# How fast the bias transitions when possession changes (prevents snapping).
# Slower = stickier — possession changes ease over ~1.2s instead of ~0.5s.
@export var bias_smooth_speed: float = 0.8
# Seconds of velocity look-ahead for the in_ozone check. Engages/releases the
# zone bias before the player physically crosses the blue line, so the
# smoothing has time to settle before the player actually arrives.
@export var ozone_predict_time: float = 0.25

# ── Carrier Lookahead ─────────────────────────────────────────────────────────
# When the local player is carrying the puck, lean the anchor in the skating
# direction so they can see ahead. Magnitude scales with speed up to
# `carry_lookahead_distance` at `carry_lookahead_full_speed`. Inactive off-puck —
# the midpoint anchor handles neutral / defensive framing on its own.
@export var carry_lookahead_distance: float = 4.0
@export var carry_lookahead_full_speed: float = 12.0

# ── Carrier Vision ────────────────────────────────────────────────────────────
# Carrying collapses the player+puck fit set to a point, which pins the dynamic
# zoom at min height — a close-up exactly when the carrier most needs to read
# the ice (the ozone goal fit rescues the attacking zone; neutral and defensive
# zones had nothing). Extend the fit extent with a vision point ahead of the
# carrier: `carry_vision_min_distance` m up-ice (attacking direction) when
# slow, easing toward `carry_vision_distance` m along the skating direction at
# `carry_lookahead_full_speed`. The velocity lean never tilts behind the play —
# a backward regroup keeps the probe up-ice, where the carrier's eyes are
# (looking for the outlet), at full length. The zoom opens to fit it and the
# zone bias spends the extra slack shifting the frame ahead — same pattern as
# the ozone goal fit, so the neutral-zone carry reads like a smaller version
# of the attacking-zone framing.
@export var carry_vision_distance: float = 12.0
@export var carry_vision_min_distance: float = 5.0

# Minimum distance (m) the local skater is kept inside the frame edge. The
# zone-bias shift and carrier lookahead are each individually bounded, but
# their SUM can push the trailing player past the visible extent at full
# speed — this clamp is the hard guarantee the player never leaves frame.
@export var player_frame_margin: float = 2.0

# ── Zoom Tuning ───────────────────────────────────────────────────────────────
@export var min_height: float = 10.0
@export var max_height: float = 40.0
@export var zoom_speed: float = 3.0
@export var zoom_padding: float = 4.0  # extra visible space beyond player+puck span

# ── Rink Bounds ───────────────────────────────────────────────────────────────
@export var rink_half_width: float = 13.0
@export var rink_half_length: float = 30.0

# ── Smoothing ─────────────────────────────────────────────────────────────────
@export var smooth_speed: float = 3.0

# ── Goal Context (set via set_goal_context) ───────────────────────────────────
var _goal_0: HockeyGoal = null  # Team 0's defended goal
var _goal_1: HockeyGoal = null  # Team 1's defended goal
var _carrier_team_getter: Callable  # () -> int team_id, or -1 if no carrier
var _local_team_id: int = -1

# ── Runtime ───────────────────────────────────────────────────────────────────
var _current_height: float = 15.0
var _smoothed_attack_dir: float = 0.0    # lerps between -1, 0, +1 on possession change
var _smoothed_direction_factor: float = 1.0  # lerps movement-direction bias to avoid snapping

# ── Shake ─────────────────────────────────────────────────────────────────────
var _shake_trauma: float = 0.0
const _SHAKE_DECAY: float = 4.0
const _SHAKE_MAG: float = 0.25

# ── Impact kick ───────────────────────────────────────────────────────────────
# A directional camera lurch on a hard body check — a coherent shove along the hit
# line that springs back, distinct from the random jitter of shake, so a check
# reads as body-meets-body recoil rather than a symmetric rumble. Modelled as an
# under-damped spring toward zero: the hit injects VELOCITY (an impulse), the
# camera swings out, overshoots once, and settles. Purely a per-frame offset on
# global_position (like shake) — no gameplay state, decoupled from the physics
# body and blade anchors.
var _impact_kick: Vector3 = Vector3.ZERO      # current lurch offset (m), added to global_position
var _impact_kick_vel: Vector3 = Vector3.ZERO  # spring velocity (m/s)
const _KICK_IMPULSE_MAX: float = 6.0          # spring velocity injected at a full-intensity hit
const _KICK_STIFFNESS: float = 200.0          # spring pull toward rest (higher = snappier)
const _KICK_DAMPING: float = 17.0             # < 2·sqrt(stiffness) ≈ 28.3 → one recoil overshoot

# ── Pre-game intro sweep ──────────────────────────────────────────────────────
# Opening-faceoff crane shot: hold a high wide view of the rink and descend
# onto the live gameplay framing. Triggered by GameManager.pregame_intro_started
# (the opening prep window is host-extended by the same duration, so play
# never starts while the crane is still in the air).
const _INTRO_HEIGHT: float = 36.0
var _intro_duration: float = 0.0
var _intro_time_left: float = 0.0
var _intro_start: Transform3D = Transform3D.IDENTITY
var _intro_start_captured: bool = false

func play_intro(duration: float) -> void:
	_intro_duration = maxf(duration, 0.1)
	_intro_time_left = _intro_duration
	_intro_start_captured = false
	# An intro sweep takes over from any period-break wide hold: it captures its
	# start at the same wide framing the hold parked on, so the hand-off is a
	# seamless hold → crane-down.
	_wide_hold_left = 0.0
	_wide_blend = 0.0

# ── Period-break wide hold ────────────────────────────────────────────────────
# Between periods the camera eases up to the intro's high wide framing and
# holds there while the skaters skate off to their benches; the period-start
# intro sweep (play_intro) then descends from that same framing, so the whole
# break reads as one broadcast shot: rise → hold → crane down onto the faceoff.
# Slack keeps the hold alive past the nominal window so the intro hand-off
# never gaps on timing jitter; if no intro follows (edge: session reset), the
# blend decays back to the live framing on its own.
const _WIDE_RISE_TIME: float = 1.2
const _WIDE_HOLD_SLACK: float = 2.0
var _wide_hold_left: float = 0.0
var _wide_blend: float = 0.0
var _wide_hold_transform: Transform3D = Transform3D.IDENTITY
var _wide_hold_captured: bool = false

func hold_period_break_wide(duration: float) -> void:
	_wide_hold_left = duration + _WIDE_HOLD_SLACK
	_wide_hold_captured = false
	# Snap the live-framing state that the crane-down blends into once the wide
	# hold ends, so a period that ends on an extreme dynamic zoom / zone bias
	# (e.g. a rush at the buzzer) doesn't carry that framing into the next
	# period even if the intermission is skipped before it would otherwise
	# decay on its own.
	_current_height = min_height * PlayerPrefs.camera_distance
	_smoothed_attack_dir = 0.0
	_smoothed_direction_factor = 1.0

func set_goal_context(goal_0: HockeyGoal, goal_1: HockeyGoal, carrier_team_getter: Callable) -> void:
	_goal_0 = goal_0
	_goal_1 = goal_1
	_carrier_team_getter = carrier_team_getter

func set_local_team_id(team_id: int) -> void:
	_local_team_id = team_id

# Whether a world position sits within (a margin of) the rink — i.e. the puck is
# in play rather than stashed off-rink by the tutorial or genuinely absent.
func _is_on_rink(pos: Vector3) -> bool:
	return absf(pos.x) <= rink_half_width + _ON_RINK_MARGIN \
		and absf(pos.z) <= rink_half_length + _ON_RINK_MARGIN

# Returns +1 or -1 (attacking direction in Z) when someone has the puck, 0 otherwise.
func _get_attacking_direction() -> int:
	if not _carrier_team_getter.is_valid():
		return 0
	var carrier_team: int = _carrier_team_getter.call()
	if carrier_team == -1:
		return 0
	var attacking_goal: HockeyGoal = _goal_1 if carrier_team == 0 else _goal_0
	if attacking_goal == null:
		return 0
	return 1 if attacking_goal.defending_team_id == 0 else -1

# The point ahead of the carrier the camera should keep in frame. Blends from
# a fixed up-ice (attacking-direction) probe when slow toward a
# skating-direction probe at `carry_lookahead_full_speed`, and clamps to the
# rink so out-of-bounds space never drives the zoom. The probe never points
# behind the play: the velocity lean is weighted down by how backward the
# skate is, so a straight-backward regroup degrades to the pure up-ice probe
# (net up-ice component stays >= 0 for any velocity). Falls back to the player
# position (a framing no-op) when there's no direction at all — stationary or
# retreating with no attack context.
func _carrier_vision_point(player_pos: Vector3, attack_dir: int) -> Vector3:
	var vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
	var speed: float = vel_xz.length()
	var t_speed: float = clampf(speed / carry_lookahead_full_speed, 0.0, 1.0)
	var vision_dir: Vector3 = Vector3(0.0, 0.0, float(attack_dir))
	if speed > 0.5:
		var vel_dir: Vector3 = vel_xz / speed
		var backness: float = clampf(-vel_dir.z * float(attack_dir), 0.0, 1.0)
		vision_dir = vision_dir.lerp(vel_dir, t_speed * (1.0 - backness))
	if vision_dir.length_squared() < 0.0001:
		return player_pos
	var vision_len: float = lerpf(carry_vision_min_distance, carry_vision_distance, t_speed)
	var point: Vector3 = player_pos + vision_dir.normalized() * vision_len
	point.x = clampf(point.x, -rink_half_width, rink_half_width)
	point.z = clampf(point.z, -rink_half_length, rink_half_length)
	return point

func shake(trauma: float) -> void:
	if not PlayerPrefs.screen_shake:
		return
	_shake_trauma = minf(1.0, _shake_trauma + trauma)

func _ready() -> void:
	make_current()
	GameManager.pregame_intro_started.connect(play_intro)
	GameManager.period_break_started.connect(hold_period_break_wide)
	GameManager.period_intro_started.connect(
			func(_period: int, duration: float) -> void: play_intro(duration))
	GameManager.goal_scored.connect(func(_t, _n, _a1, _a2) -> void: shake(1.0))
	GameManager.local_player_hit.connect(func(mag: float) -> void:
		if mag >= 3.0:
			shake(clampf(mag / 12.0, 0.2, 0.4)))
	# Landing a check punches a touch harder than taking one — the hit you deliver
	# should read as the bigger moment. Same ~14 impact-force full-check scale the
	# VFX burst uses (SkaterVFX._CHECK_FORCE_REF), gated above incidental bumps.
	GameManager.local_player_landed_hit.connect(func(mag: float) -> void:
		if mag >= 3.0:
			shake(clampf(mag / 14.0, 0.25, 0.55)))
	# Directional recoil on a hard hit (delivered or taken), layered on the shake.
	GameManager.local_player_impact.connect(impact_kick)

# Inject a directional recoil impulse. `intensity` is a normalized 0..1 hit
# hardness (each emit site maps its own hit scale), `direction` the world heading
# to lurch toward — horizontal only. Silent no-op when screen shake is disabled or
# the hit is too soft / directionless.
func impact_kick(direction: Vector3, intensity: float) -> void:
	if not PlayerPrefs.screen_shake or intensity <= 0.01:
		return
	var dir: Vector3 = Vector3(direction.x, 0.0, direction.z)
	if dir.length_squared() < 0.0001:
		return
	_impact_kick_vel += dir.normalized() * _KICK_IMPULSE_MAX * clampf(intensity, 0.0, 1.0)


func _physics_process(delta: float) -> void:
	if not skater:
		return

	var has_puck: bool = puck != null and is_instance_valid(puck)
	# Locked framing pins the center on the player. Engaged by the user's
	# camera-mode pref, forced on by the tutorial for the puckless movement
	# steps, and used automatically whenever no puck exists at all.
	var locked: bool = force_locked \
		or PlayerPrefs.camera_mode == PlayerPrefs.CAMERA_MODE_LOCKED \
		or not has_puck

	var player_pos: Vector3 = skater.global_position + skater.visual_offset
	player_pos.y = 0.0
	var puck_pos: Vector3 = player_pos
	if has_puck:
		puck_pos = puck.global_position
		puck_pos.y = 0.0

	# Only frame the puck when it's actually in play on the rink. A stashed
	# (tutorial), out-of-bounds, or absent puck is ignored in BOTH modes — the
	# camera frames the player instead of lurching out toward it. (The tutorial
	# parks the puck at (100, _, 100) between drill attempts; without this the
	# dynamic cam would zoom to max and pan to center on every restage.) When the
	# puck isn't in play, collapse its target onto the player so every downstream
	# framing calc treats the fit set as "just the player".
	var fit_puck: bool = has_puck and _is_on_rink(puck_pos)
	if not fit_puck:
		puck_pos = player_pos

	# Pull FOV from prefs so the user-facing slider drives every downstream
	# computation (zoom math, ortho size, tilt offset).
	if not is_equal_approx(fov, PlayerPrefs.fov):
		fov = PlayerPrefs.fov
	var fov_rad: float = deg_to_rad(fov)
	var aspect: float = get_viewport().get_visible_rect().size.x / get_viewport().get_visible_rect().size.y
	var tan_half_fov: float = tan(fov_rad / 2.0)

	var attack_dir_now: int = _get_attacking_direction()

	# ── Step 1+2: Base center and the fit extent to zoom around ───────────────
	var base_center: Vector3
	var half_span_x: float
	var fit_min_z: float
	var fit_max_z: float
	if locked:
		# Center on the player; extend the fit set symmetrically so the puck
		# (when in play) stays in frame without shifting the center off the
		# player. No puck → zero span → sits at the minimum height.
		base_center = player_pos
		if fit_puck:
			half_span_x = absf(player_pos.x - puck_pos.x)
			var dz: float = absf(player_pos.z - puck_pos.z)
			fit_min_z = player_pos.z - dz
			fit_max_z = player_pos.z + dz
		else:
			half_span_x = 0.0
			fit_min_z = player_pos.z
			fit_max_z = player_pos.z
	else:
		# Dynamic broadcast framing: anchor on the midpoint of {player, puck}.
		# When the carrier is attacking and the local player is past the
		# carrier's attacking blue line, also fit the goal in the Z extent —
		# the attacking goal when carrying (ozone) and the local team's own goal
		# when defending against a carry-in (dzone). Fitting the goal here lets
		# the camera reach it via the dynamic zoom + the zone bias shift below,
		# instead of needing a separate `ozone_min_height` bump that wastes
		# screen on a wider general zoom-out.
		#
		# `in_ozone` uses a velocity-predicted Z so the bias engages/releases
		# before the player actually crosses the blue line, leaving time for the
		# smoothing to settle.
		base_center = (player_pos + puck_pos) * 0.5
		var predicted_z: float = player_pos.z + skater.velocity.z * ozone_predict_time
		var in_ozone: bool = attack_dir_now != 0 and \
			(predicted_z * float(attack_dir_now)) > GameRules.BLUE_LINE_Z
		half_span_x = abs(player_pos.x - puck_pos.x) * 0.5
		fit_min_z = minf(player_pos.z, puck_pos.z)
		fit_max_z = maxf(player_pos.z, puck_pos.z)
		if in_ozone:
			var goal_z: float = float(attack_dir_now) * GameRules.GOAL_LINE_Z
			fit_min_z = minf(fit_min_z, goal_z)
			fit_max_z = maxf(fit_max_z, goal_z)
		# Carrier vision: fit a probe point ahead of the carrier so the zoom
		# opens up instead of sitting at min height on the collapsed
		# player+puck span (see the Carrier Vision exports).
		if fit_puck and puck.get_carrier() == skater:
			var vision_point: Vector3 = _carrier_vision_point(player_pos, attack_dir_now)
			half_span_x = maxf(half_span_x, absf(vision_point.x - base_center.x))
			fit_min_z = minf(fit_min_z, vision_point.z)
			fit_max_z = maxf(fit_max_z, vision_point.z)
	var half_span_z: float = (fit_max_z - fit_min_z) * 0.5

	var needed_x: float = (half_span_x + zoom_padding) / (tan_half_fov * aspect)
	var needed_z: float = (half_span_z + zoom_padding) / tan_half_fov
	# User-facing camera-distance multiplier (Options → Game).
	var dist_mult: float = PlayerPrefs.camera_distance
	var effective_min: float = min_height * dist_mult
	var effective_max: float = max_height * dist_mult
	var target_height: float = clampf(maxf(needed_x, needed_z), effective_min, effective_max)
	_current_height = lerpf(_current_height, target_height, zoom_speed * delta)

	var visible_half_x: float = tan_half_fov * aspect * _current_height
	var visible_half_z: float = tan_half_fov * _current_height

	var target_center: Vector3 = base_center
	# Zone bias and carrier lookahead are dynamic-framing concerns; locked mode
	# keeps the center pinned on the player, so both are skipped there.
	if not locked:
		# ── Step 3: Attacking zone bias ───────────────────────────────────────
		# Lerp the attack direction so possession changes ease in rather than snap.
		_smoothed_attack_dir = lerpf(_smoothed_attack_dir, float(attack_dir_now), bias_smooth_speed * delta)

		if not is_zero_approx(_smoothed_attack_dir):
			# Scale bias by how much the player is moving toward the attacking zone.
			# Moving directly toward ozone = 1.0, sideways = 0.5, backward = 0.0.
			# Smoothed so a momentary backward step doesn't yank the bias away.
			var vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
			var raw_direction_factor: float = 1.0
			if vel_xz.length_squared() > 0.25:  # ignore drift when nearly stationary
				var vel_dir: Vector3 = vel_xz.normalized()
				var dot: float = vel_dir.z * float(attack_dir_now)
				raw_direction_factor = clampf((dot + 1.0) * 0.5, 0.0, 1.0)
			_smoothed_direction_factor = lerpf(_smoothed_direction_factor, raw_direction_factor, bias_smooth_speed * delta)
			var direction_factor: float = _smoothed_direction_factor

			# Slack = how far we can shift before the trailing subject hits the frame edge.
			var min_z: float = minf(player_pos.z, puck_pos.z)
			var max_z: float = maxf(player_pos.z, puck_pos.z)
			var slack_pos: float = maxf(visible_half_z - (base_center.z - min_z), 0.0)
			var slack_neg: float = maxf(visible_half_z - (max_z - base_center.z), 0.0)
			var blended_slack: float = 0.0
			if _smoothed_attack_dir > 0.0:
				blended_slack = _smoothed_attack_dir * slack_pos
			else:
				blended_slack = _smoothed_attack_dir * slack_neg
			target_center.z += blended_slack * zone_bias * direction_factor

		# ── Step 3b: Carrier velocity lookahead ──────────────────────────────
		# When the local player carries the puck, lean the anchor in the skating
		# direction. Stacks additively with the zone bias above (skating toward
		# the attacking goal: lookahead and bias both push the same way; skating
		# laterally with the puck: lookahead pushes sideways while bias keeps
		# pulling toward the goal — net is a forward-and-sideways framing).
		if fit_puck and puck.get_carrier() == skater:
			var carrier_vel_xz: Vector3 = Vector3(skater.velocity.x, 0.0, skater.velocity.z)
			var carrier_speed: float = carrier_vel_xz.length()
			if carrier_speed > 0.5:
				var t_speed: float = clampf(carrier_speed / carry_lookahead_full_speed, 0.0, 1.0)
				var lookahead: Vector3 = (carrier_vel_xz / carrier_speed) * t_speed * carry_lookahead_distance
				target_center.x += lookahead.x
				target_center.z += lookahead.z

		# ── Step 3c: Keep the local skater in frame ──────────────────────────
		# The zone-bias shift and carrier lookahead are each bounded, but their
		# sum can push the trailing player past the frame edge at full speed
		# (the rink clamp masks this in the end zones; open ice doesn't).
		# Hard-clamp the center so the player always stays visible with a
		# margin. The puck needs no equivalent: off-puck it bounds the bias
		# slack directly, on-puck it rides with the player.
		var keep_x: float = maxf(visible_half_x - player_frame_margin, 0.0)
		var keep_z: float = maxf(visible_half_z - player_frame_margin, 0.0)
		target_center.x = clampf(target_center.x, player_pos.x - keep_x, player_pos.x + keep_x)
		target_center.z = clampf(target_center.z, player_pos.z - keep_z, player_pos.z + keep_z)

		# ── Step 4: Rink clamp ────────────────────────────────────────────────
		# Keep the dynamic framing on valid ice. Locked mode deliberately skips
		# this so the player stays exactly centered even at the boards — the
		# arena surround fills any over-board sliver.
		var safe_x: float = maxf(rink_half_width - visible_half_x, 0.0)
		var safe_z: float = maxf(rink_half_length - visible_half_z, 0.0)
		target_center.x = clampf(target_center.x, -safe_x, safe_x)
		target_center.z = clampf(target_center.z, -safe_z, safe_z)

	# ── Step 5: Smooth movement ───────────────────────────────────────────────
	# The camera looks along a slanted ray, so a camera at target_center.xz
	# looks at a point ~h*tan(off-axis-angle) behind itself. Offset the camera
	# in the direction the view is being pulled away from so the play stays
	# centered. attack_up flip mirrors the offset sign. The tilt magnitude is
	# user-tunable in a tight band (Options → Game → Camera Tilt).
	var tilt_deg: float = PlayerPrefs.camera_tilt_deg
	var pitch: float = -tilt_deg
	var off_axis_rad: float = deg_to_rad(90.0 - tilt_deg)  # 15° at 75° tilt
	var raw_offset: float = _current_height * tan(off_axis_rad)
	var flip_sign: float = -1.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 1.0
	var tilt_z_offset: float = raw_offset * flip_sign
	var target_pos: Vector3 = Vector3(
			target_center.x, _current_height, target_center.z + tilt_z_offset)
	global_position = global_position.lerp(target_pos, smooth_speed * delta)

	# ── Step 5b: Apply pitch + attack-up yaw flip. Always tilted perspective. ──
	if projection != PROJECTION_PERSPECTIVE:
		projection = PROJECTION_PERSPECTIVE
	var flip_y: float = 180.0 if PlayerPrefs.attack_up and _local_team_id == 1 else 0.0
	rotation_degrees = Vector3(pitch, flip_y, 0.0)

	# ── Step 6: Shake ─────────────────────────────────────────────────────────
	if _shake_trauma > 0.0:
		_shake_trauma = maxf(0.0, _shake_trauma - _SHAKE_DECAY * delta)
		global_position += Vector3(
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG,
			0.0,
			randf_range(-1.0, 1.0) * _shake_trauma * _SHAKE_MAG)

	# ── Step 6b: Impact kick ──────────────────────────────────────────────────
	# Under-damped spring toward rest; the injected velocity swings the offset out
	# and back. Added as a per-frame offset (global_position is re-derived from the
	# framing each tick, so it never compounds).
	if _impact_kick.length_squared() > 1e-7 or _impact_kick_vel.length_squared() > 1e-7:
		var accel: Vector3 = -_KICK_STIFFNESS * _impact_kick - _KICK_DAMPING * _impact_kick_vel
		_impact_kick_vel += accel * delta
		_impact_kick += _impact_kick_vel * delta
		global_position += _impact_kick
	else:
		_impact_kick = Vector3.ZERO
		_impact_kick_vel = Vector3.ZERO

	# ── Step 6c: Period-break wide hold ───────────────────────────────────────
	# Ease from the live framing up to the captured wide transform and sit there
	# while the skate-off plays out below. Mutually exclusive with the intro
	# sweep in practice (play_intro clears the hold); the decay branch only runs
	# if the hold expires without an intro taking over.
	if _wide_hold_left > 0.0 or _wide_blend > 0.0:
		if _wide_hold_left > 0.0 and not _wide_hold_captured:
			_wide_hold_captured = true
			_wide_hold_transform = global_transform
			_wide_hold_transform.origin = Vector3(0.0, _INTRO_HEIGHT, global_position.z)
		_wide_hold_left = maxf(_wide_hold_left - delta, 0.0)
		var blend_dir: float = 1.0 if _wide_hold_left > 0.0 else -1.0
		_wide_blend = clampf(_wide_blend + blend_dir * delta / _WIDE_RISE_TIME, 0.0, 1.0)
		var eased_wide: float = _wide_blend * _wide_blend * (3.0 - 2.0 * _wide_blend)
		global_transform = global_transform.interpolate_with(_wide_hold_transform, eased_wide)

	# ── Step 7: Pre-game intro sweep ──────────────────────────────────────────
	# Crane down from a high wide shot onto the live gameplay framing computed
	# above. The blend target is re-sampled every frame, so at full weight the
	# handoff is seamless wherever the normal camera settled; the start shares
	# the live rotation (pitch/yaw prefs, attack-up flip), making the blend a
	# pure position glide.
	if _intro_time_left > 0.0:
		if not _intro_start_captured:
			_intro_start_captured = true
			_intro_start = global_transform
			_intro_start.origin = Vector3(0.0, _INTRO_HEIGHT, global_position.z)
		_intro_time_left = maxf(_intro_time_left - delta, 0.0)
		var w: float = 1.0 - _intro_time_left / _intro_duration
		var eased: float = w * w * (3.0 - 2.0 * w)
		global_transform = _intro_start.interpolate_with(global_transform, eased)
