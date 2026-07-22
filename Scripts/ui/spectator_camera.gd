class_name SpectatorCamera
extends Camera3D

# Broadcast main-camera ("hard cam") preset for goal replays and spectator
# viewing. Sits at the press-box position outside the long-side boards and
# slides along the rail with the puck the way real NHL hard cams do (booth_z
# tracks the puck's z; can be disabled via rail_track for parked custom
# presets like GoalReplayDriver's inside-net cam). Pans/tilts to track the
# puck with a small velocity lead so the rotation anticipates the play instead
# of chasing it. Subtle perlin-style noise on yaw/pitch + position gives the
# gentle drift of a wire-rigged broadcast camera. Telephoto FOV (compared to
# the player-perspective cams) flattens depth in the broadcast style — players
# group up visually as the puck moves, which sells the play better than the
# wider game-cam framing.
#
# Close-play zoom-out: a fixed telephoto FOV frames a constant ANGLE, so the
# visible width shrinks linearly with distance — play at the camera-side
# boards (~19 m away vs ~27 m at center ice) used to get a claustrophobic
# frame that puck wiggle could exit. Rail cams instead hold a constant frame
# WIDTH at the play (frame_width_m), exactly what a real camera operator's
# zoom hand does: fov = 2·atan(W / 2d), floored at replay_fov so the far-side
# wide shot keeps the published telephoto framing and only close play widens.

@export var booth_x: float = 20.0        # outside the long boards (rink is ±13 wide)
@export var booth_y: float = 18.0        # press-box elevation (~42° down to center ice)
@export var booth_z: float = 0.0         # center-ice along the long axis (slides with rail_track)
# 28° vertical → ~50° horizontal at 16:9 → frames ~35% of the rink length from
# the booth distance, matching the published wide-shot guideline for NHL game-
# follow cameras. Telephoto enough to compress depth (players group visually
# as play moves) without losing the puck in long-bomb stretch passes. For rail
# cams this is the FLOOR of the adaptive close-play zoom below.
@export var replay_fov: float = 28.0
# Constant visible frame width (m) held at the tracked play by the adaptive
# zoom (rail cams only). 13.5 m is what replay_fov yields at the default
# booth's center-ice distance (~27 m), so far/mid-ice framing is unchanged
# and only closer play zooms out.
@export var frame_width_m: float = 13.5
# Zoom-out ceiling: past this the shot stops reading as a broadcast telephoto.
@export var max_close_fov: float = 46.0
@export var look_speed: float = 6.0      # rotation slerp speed
@export var lead_time: float = 0.35      # seconds of puck-velocity lookahead
@export var max_lead: float = 5.0        # cap the lead so fast shots don't overshoot
# Angular cap on the velocity lead: the leaded look-target stays within this
# fraction of the half-FOV of the puck itself. The absolute max_lead cap alone
# was tuned for the ~27 m center-ice distance — at close range the same 5 m
# subtends far more than the (narrower-in-meters) frame, letting a hard shot
# fling the look-target clean off the play.
@export var lead_fov_fraction: float = 0.75
@export var noise_yaw_deg: float = 0.55
@export var noise_pitch_deg: float = 0.30
@export var noise_pos_amp: float = 0.06  # meters
@export var noise_freq: float = 0.45     # Hz

# Rail tracking — slide along the long axis with the puck like a real NHL
# hard cam. Set false by callers that want a parked camera (e.g.
# GoalReplayDriver's inside-net preset). rail_strength < 1 keeps the rail
# behind the puck so the play stays framed instead of dead-center.
@export var rail_track: bool = true
@export var rail_strength: float = 0.65
@export var rail_max_offset: float = 12.0
@export var rail_smooth_rate: float = 1.5

# Low-pass filter on the target position. Real broadcast cameras don't react
# to puck wiggle during stickhandling — the operator follows the play, not
# the puck. With smooth_rate ≈ 2.5 (~0.4s time constant), stickhandle wiggle
# at ~5 Hz gets >80% attenuated, while a 1-second puck travel passes through
# nearly intact. Velocity for the broadcast lead is derived from the SMOOTHED
# target, so the lead vector itself stays wiggle-free too.
@export var target_smooth_rate: float = 2.5

var _target_getter: Callable = Callable()
var _prev_camera: Camera3D = null

# Smoothed target + its derived velocity. Same call sites work as before
# (live spectator reads the puck node, goal-replay also reads the puck node
# while ReplayPlaybackEngine drives its position from interpolated snapshots).
var _smoothed_target: Vector3 = Vector3.ZERO
var _target_velocity: Vector3 = Vector3.ZERO
var _smoothing_initialized: bool = false


func setup(target_getter: Callable) -> void:
	_target_getter = target_getter
	fov = replay_fov


func activate() -> void:
	# Guard against double-activation: a second call would overwrite _prev_camera
	# with our own current reference, breaking deactivate() restore. Goal-replay
	# overlapping with a stale spectator camera is the realistic trigger.
	if current:
		return
	_prev_camera = get_viewport().get_camera_3d()
	snap_to_position()
	make_current()


# Park the camera at booth_{x,y,z} and snap rotation to the current target,
# without touching `current`. Used by GoalReplayDriver to drive multi-cam cuts
# (it owns make_current() decisions for both cams) and by playback
# discontinuities (seeks, faceoff resets) where a pan across the jump would
# read as the camera drifting off the play; activate() also calls this. A cut
# is a full re-seed: the rail slides to where the target is NOW (rail_track
# cams only) and the target smoothing restarts from the raw target.
func snap_to_position() -> void:
	if _target_getter.is_valid():
		var target: Vector3 = _target_getter.call()
		if rail_track:
			booth_z = clampf(target.z * rail_strength, -rail_max_offset, rail_max_offset)
		_smoothed_target = target
		_target_velocity = Vector3.ZERO
		_smoothing_initialized = true
		global_position = Vector3(booth_x, booth_y, booth_z)
		# A cut re-seeds the zoom too: land on the new distance's framing
		# instead of easing from wherever the previous shot left the FOV.
		if rail_track:
			fov = _broadcast_fov(global_position.distance_to(target))
		if global_position.distance_to(target) > 0.1:
			look_at(target, Vector3.UP)
	else:
		global_position = Vector3(booth_x, booth_y, booth_z)


# Re-aim this camera at a different preset (position, FOV, lead time). Caller
# is responsible for snap_to_position() + make_current() afterward to actually
# execute the cut. Disables rail tracking since custom presets (e.g.
# GoalReplayDriver's inside-net cam) want a parked camera, not a hard-cam
# that slides.
func set_booth(pos: Vector3, new_fov: float, new_lead_time: float) -> void:
	booth_x = pos.x
	booth_y = pos.y
	booth_z = pos.z
	fov = new_fov
	replay_fov = new_fov
	lead_time = new_lead_time
	rail_track = false


func deactivate() -> void:
	if _prev_camera != null and is_instance_valid(_prev_camera):
		_prev_camera.make_current()
	_prev_camera = null


func _process(delta: float) -> void:
	if not current or not _target_getter.is_valid():
		return
	var target: Vector3 = _target_getter.call()
	_smooth_target_and_velocity(target, delta)

	# Rail tracking: slide booth_z toward the puck's z so the camera follows
	# the play up/down the ice. Strength < 1 keeps the puck framed ahead of
	# center rather than dead-center, mirroring real NHL hard-cam composition.
	if rail_track:
		var target_z: float = clampf(_smoothed_target.z * rail_strength,
				-rail_max_offset, rail_max_offset)
		var rail_alpha: float = clampf(delta * rail_smooth_rate, 0.0, 1.0)
		booth_z = lerpf(booth_z, target_z, rail_alpha)

	# Constant-frame-width zoom (see class doc): re-derive the FOV from the
	# smoothed target's distance so close play widens the shot instead of
	# cropping it. Smoothness comes from the target smoothing itself. Parked
	# custom presets (rail_track off, e.g. the inside-net cam) keep their
	# set_booth FOV.
	var booth_pos: Vector3 = Vector3(booth_x, booth_y, booth_z)
	var target_dist: float = booth_pos.distance_to(_smoothed_target)
	if rail_track:
		fov = _broadcast_fov(target_dist)

	# Velocity-lead so the rotation anticipates the puck path. Capped both
	# absolutely and angularly (lead_fov_fraction of the half-FOV at the
	# target's distance) so a slapshot doesn't fling the look-target past the
	# play — the angular cap is what keeps close-range leads inside the frame.
	var lead: Vector3 = _target_velocity * lead_time
	var lead_cap: float = minf(max_lead,
			target_dist * tan(deg_to_rad(fov * 0.5) * lead_fov_fraction))
	if lead.length() > lead_cap:
		lead = lead.normalized() * lead_cap
	var look_target: Vector3 = _smoothed_target + lead

	# Wire-rig drift: subtle perlin-style noise on the booth position + look
	# target. Two harmonics per axis so the motion doesn't look like a pure sine.
	var t: float = Time.get_ticks_msec() / 1000.0
	var w: float = noise_freq * TAU
	var pos_noise := Vector3(
			(sin(t * w * 1.10 + 0.31) + sin(t * w * 1.73 + 1.92)) * 0.5,
			(sin(t * w * 0.83 + 0.92) + sin(t * w * 1.41 + 2.71)) * 0.5,
			(sin(t * w * 1.27 + 2.14) + sin(t * w * 1.59 + 0.47)) * 0.5)
	var yaw_noise: float = (sin(t * w + 0.13) + sin(t * w * 1.61 + 1.27)) * 0.5
	var pitch_noise: float = (sin(t * w * 0.88 + 0.71) + sin(t * w * 1.39 + 2.05)) * 0.5

	global_position = Vector3(booth_x, booth_y, booth_z) + pos_noise * noise_pos_amp

	# Build a look transform pointing at the leaded target, then nudge it by
	# the rotation noise to add wire drift on top of the slerp. The weight must
	# clamp at 1: a frame hitch pushing look_speed * delta past 1 would make
	# interpolate_with EXTRAPOLATE beyond the target orientation.
	if global_position.distance_to(look_target) > 0.1:
		var look_xform: Transform3D = global_transform.looking_at(look_target, Vector3.UP)
		look_xform = look_xform.rotated_local(Vector3.UP, deg_to_rad(yaw_noise * noise_yaw_deg))
		look_xform = look_xform.rotated_local(Vector3.RIGHT, deg_to_rad(pitch_noise * noise_pitch_deg))
		global_transform = global_transform.interpolate_with(
				look_xform, clampf(look_speed * delta, 0.0, 1.0))


# The operator's-zoom model: hold frame_width_m of visible width at the play,
# never tighter than replay_fov (the far wide shot), never wider than
# max_close_fov. fov here is the vertical FOV; frame_width_m is measured
# vertically in the frame (the rink's short axis from the side booth), which
# is the axis that crops first at this camera's pitch.
func _broadcast_fov(dist: float) -> float:
	if dist <= 0.1:
		return max_close_fov
	var width_fov: float = rad_to_deg(2.0 * atan(frame_width_m / (2.0 * dist)))
	return clampf(width_fov, replay_fov, max_close_fov)


func _smooth_target_and_velocity(target_pos: Vector3, delta: float) -> void:
	if not _smoothing_initialized:
		_smoothed_target = target_pos
		_smoothing_initialized = true
		return
	if delta <= 0.0:
		return
	# Low-pass the target. Stickhandle wiggle has a short period and a tiny
	# net displacement, so it gets attenuated. Sustained motion (skating,
	# passes, shots) carries through with a small lag that the velocity lead
	# below substantially cancels out.
	var prev_smoothed: Vector3 = _smoothed_target
	var pos_alpha: float = clampf(delta * target_smooth_rate, 0.0, 1.0)
	_smoothed_target = _smoothed_target.lerp(target_pos, pos_alpha)
	# Velocity from the SMOOTHED target so the broadcast lead vector inherits
	# the same wiggle filtering. EMA on top keeps the velocity itself from
	# stepping per-frame.
	var raw_v: Vector3 = (_smoothed_target - prev_smoothed) / delta
	var v_alpha: float = clampf(delta * 5.0, 0.0, 1.0)
	_target_velocity = _target_velocity.lerp(raw_v, v_alpha)
