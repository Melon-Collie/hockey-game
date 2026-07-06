class_name SkaterSkatingCoordinator
extends RefCounted

# Procedural skating stride — no skeleton, no animation clips. Advances a stride
# phase by ground speed and swings each leg about its hip via Skater.set_leg_swing(),
# matching the same per-frame "write the transforms" idiom the arm-bone IK already
# uses. Beyond the leg swing it owns the skating STANCE: a speed-engaged crouch
# (hip + knee flex with a matching whole-body drop via Skater.set_skating_crouch_drop
# so the skates stay planted), a per-stride body bob, and the trunk texture the
# pose coordinator layers into the torso lean (trunk_pitch_add / trunk_roll_add —
# effort dig and weight-shift sway; this class never writes torso rotations
# itself). Purely cosmetic and derived entirely from the skater's velocity, so it
# costs zero network state: remote skaters animate identically from the velocity
# that interpolation already hands them.
#
# The phase is advanced only on real render ticks — SkaterController guards the
# call with `not is_replaying` so reconcile re-simulation (many ticks per frame)
# doesn't over-spin the gait. Standstill freezes the phase (advance is scaled by
# speed) and the intensity envelope eases the legs back to their rest pose, so
# nothing pops when starting or stopping.

const State = SkaterStateMachine.State

# Leg segment spans from Scenes/Skater.tscn — hip pivot to knee pivot (LegL →
# ShinL) and knee pivot to skate sole (ShinL → FootL). Used to derive the
# stance knee flex and body drop from the hip flex so the crouch keeps the
# skates planted. Keep in sync with the scene if the leg pivots move.
const _THIGH_LEN: float = 0.31
const _SHIN_LEN: float = 0.45

var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _controller: SkaterController = null  # tunables live as @export on the controller

# ── Runtime State ─────────────────────────────────────────────────────────────
var stride_phase: float = 0.0
# Per-stride trunk texture, read by SkaterPoseCoordinator when it applies the
# torso lean (this coordinator never writes torso rotations itself — the pose
# pass stays the single writer). Radians; updated on real ticks only, so it
# holds steady through reconcile replay like the rest of the gait.
var trunk_pitch_add: float = 0.0
var trunk_roll_add: float = 0.0
# Smoothed [0,1] stride intensity so the legs ease in/out of motion at the
# start/end of a stride instead of snapping to full amplitude.
var _intensity: float = 0.0
# Smoothed effort signal in [-1, +1]: +1 driving hard (deep push), -1
# coasting/braking (settle into a glide). Derived from tangential acceleration —
# see apply(). Previous velocity backs the finite-difference; the flag suppresses
# the spurious spike on the very first frame (no prior sample yet).
var _effort: float = 0.0
var _prev_velocity: Vector3 = Vector3.ZERO
var _have_prev_velocity: bool = false
# Smoothed faceoff ready-stance engagement, so the crouch eases in over the
# countdown and releases into the draw instead of popping on the phase flip.
var _faceoff_blend: float = 0.0
# Hockey-stop state (see the Hockey stop block in apply()). stop_yaw_offset
# (radians, lower-body rotation.y) is PUBLISHED for SkaterPoseCoordinator's
# lower-body write — this class never writes body rotations itself, same
# contract as the trunk texture.
var stop_yaw_offset: float = 0.0
var _stop_engaged: bool = false
var _stop_side: float = 1.0
var _stop_blend: float = 0.0
# Hip-to-travel alignment (see the block in apply()). Published for the pose
# coordinator's lower-body write, same contract as stop_yaw_offset.
var travel_align_yaw: float = 0.0
var _hip_align_yaw: float = 0.0
# Smoothed signed carve engagement [−1, +1] (CarveRules): path curvature
# drives the crossover gait. Sign = turn direction (+ = toward local +X).
var _carve: float = 0.0

func setup(skater: Skater, sm: SkaterStateMachine, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_controller = controller

# Snaps the gait back to a clean standstill and plants the legs at their rest
# pose. Called on faceoff / respawn teleports so a skater doesn't drop into the
# dot mid-stride carrying the previous shift's leg swing.
func reset_to_rest() -> void:
	stride_phase = 0.0
	_intensity = 0.0
	_effort = 0.0
	_faceoff_blend = 0.0
	trunk_pitch_add = 0.0
	trunk_roll_add = 0.0
	_prev_velocity = Vector3.ZERO
	_have_prev_velocity = false
	stop_yaw_offset = 0.0
	_stop_engaged = false
	_stop_blend = 0.0
	travel_align_yaw = 0.0
	_hip_align_yaw = 0.0
	_carve = 0.0
	if _skater != null:
		_skater.set_leg_swing(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
		_skater.set_skating_crouch_drop(0.0)

# ── Per-Tick Application ──────────────────────────────────────────────────────
# Three gait shapes — forward, backward, and lateral (crossover) — are computed
# from the same stride phase and blended by the direction of travel expressed in
# the skater's body frame. Because facing tracks the cursor independently of
# momentum, a skater can glide in any direction relative to where it's pointing;
# the blend reads that out of local velocity so diagonal motion mixes gaits
# smoothly instead of snapping between them.
func apply(delta: float) -> void:
	if _skater == null or delta <= 0.0:
		return

	var vel: Vector3 = _skater.velocity
	# Ground speed only — vertical velocity never feeds the stride.
	var ground_speed: float = Vector2(vel.x, vel.z).length()
	var speed_t: float = clampf(ground_speed / maxf(_controller.max_speed, 0.001), 0.0, 1.0)

	# Plant the legs while shot-blocking (the skater is crouched, knees together);
	# otherwise drive intensity from speed. Lerp so the envelope eases.
	var planted: bool = _sm.get_state() == State.SHOT_BLOCKING
	var target_intensity: float = 0.0 if planted else speed_t
	_intensity = lerpf(_intensity, target_intensity, _controller.stride_intensity_speed * delta)

	# Advance the stride phase. The naive law — rate = ground_speed × cadence — is
	# linear and uncapped, so leg turnover doubles when speed doubles and the gait
	# "whirs" at sprint. Real skating instead plateaus its stride *rate* and buys
	# extra speed with longer strides (more glide + reach per push), which the
	# speed-scaled amplitude below already delivers. So treat ground_speed × cadence
	# as the low-speed slope but saturate it through tanh toward a ceiling: near a
	# standstill the response is ~linear (phase still freezes at zero speed), and by
	# top speed the cadence has flattened to ~stride_cadence_max_rate. Cruise and
	# sprint then share almost the same leg turnover — the sprint reads as longer,
	# more powerful strides, not faster ones.
	var cadence_ceiling: float = maxf(_controller.stride_cadence_max_rate, 0.001)
	var linear_rate: float = ground_speed * _controller.stride_cadence
	var phase_rate: float = cadence_ceiling * tanh(linear_rate / cadence_ceiling)
	# The hockey-stop blend (previous frame's value — it's computed below,
	# and the one-frame lag is invisible through the smoothing) freezes the
	# stride: scraping blades don't stride.
	stride_phase = wrapf(stride_phase + phase_rate * (1.0 - _stop_blend) * delta, 0.0, TAU)

	# ── Effort: glide vs. push ─────────────────────────────────────────────────
	# Velocity-only skating pumps the legs purely by speed, so a skater coasting at
	# top speed strides exactly as hard as one digging for it. Real skating glides
	# when it isn't gaining speed and pushes hard when it is. Recover that intent
	# from the sign of tangential acceleration (the component of accel along travel):
	# speeding up reads as a push, coasting/braking as a glide. Acceleration is the
	# only "is the player pushing?" signal available without new network state — it
	# falls out of the velocity remotes and replays already have — so they inherit
	# the glide/push texture for free, exactly like the rest of the gait.
	var effort_target: float = 0.0
	var carve_target: float = 0.0
	if _have_prev_velocity:
		var accel: Vector3 = (vel - _prev_velocity) / delta
		var travel: Vector2 = Vector2(vel.x, vel.z)
		if travel.length() > 0.1:
			var tangential: float = Vector2(accel.x, accel.z).dot(travel.normalized())
			effort_target = clampf(
					tangential / maxf(_controller.stride_effort_ref_accel, 0.001), -1.0, 1.0)
		# Path curvature off the same velocity history — the carve/crossover
		# trigger (see CarveRules and the carve block below).
		carve_target = CarveRules.carve_target(
				CarveRules.turn_rate(
						Vector2(_prev_velocity.x, _prev_velocity.z),
						Vector2(vel.x, vel.z), delta, _controller.carve_min_speed),
				ground_speed, _controller.carve_ref_turn_rate, _controller.carve_min_speed)
	_prev_velocity = vel
	_have_prev_velocity = true
	_effort = lerpf(_effort, effort_target, _controller.stride_effort_speed * delta)
	_carve = lerpf(_carve, carve_target, _controller.carve_engage_speed * delta)
	# Push-amplitude scale around the speed baseline: >1 driving, easing toward
	# stride_glide_floor when coasting so the legs settle instead of churning. The
	# static crossover lean is intentionally left off this scale — you still lean
	# through a turn while gliding.
	var push_scale: float = clampf(1.0 + _effort * _controller.stride_push_gain,
			_controller.stride_glide_floor, _controller.stride_push_ceiling)

	# Decompose travel into the body frame: -Z is forward, +X is the skater's right.
	var local_vel: Vector3 = _skater.global_transform.basis.inverse() * vel
	var fwd: float = -local_vel.z   # >0 skating forward, <0 skating backward
	var lat: float = local_vel.x    # >0 strafing right, <0 strafing left (crossover)
	# Blend weights — fore/aft gait vs. lateral crossover gait — summing to 1.
	var fb_w: float = 1.0
	var lr_w: float = 0.0
	var denom: float = absf(fwd) + absf(lat)
	if denom > 0.001:
		fb_w = absf(fwd) / denom
		lr_w = absf(lat) / denom

	# ── Hockey stop ────────────────────────────────────────────────────────────
	# Braking hard at speed turns the LOWER BODY across the travel direction
	# (legs sideways, blades scraping) while the torso keeps facing the play —
	# the pose coordinator adds stop_yaw_offset to its lower-body write. The
	# engage/release decisions and the side latch live in HockeyStopRules
	# (pure, hysteresis-guarded so the legs never flip mid-skid); everything
	# derives from the velocity-based effort signal, so remotes and bots read
	# the identical stop from state they already have. While blended in, the
	# normal stride amplitudes are suppressed (blades scrape, they don't
	# stride) and the stop stance below takes over the legs.
	if _stop_engaged:
		if HockeyStopRules.should_release(_effort, ground_speed,
				_controller.hockey_stop_effort, _controller.hockey_stop_min_speed):
			_stop_engaged = false
	elif HockeyStopRules.should_engage(_effort, ground_speed,
			_controller.hockey_stop_effort, _controller.hockey_stop_min_speed):
		_stop_engaged = true
		_stop_side = HockeyStopRules.latch_side(local_vel)
	_stop_blend = lerpf(_stop_blend, 1.0 if _stop_engaged else 0.0,
			_controller.hockey_stop_blend_speed * delta)
	if _stop_blend > 0.001:
		stop_yaw_offset = HockeyStopRules.stop_yaw(local_vel, _stop_side,
				deg_to_rad(_controller.hockey_stop_max_yaw_deg)) * _stop_blend
	else:
		stop_yaw_offset = 0.0
	# Stride suppression factor: 1 = normal gait, 0 = full stop pose.
	var gait_scale: float = 1.0 - _stop_blend

	# ── Hip-to-travel alignment ────────────────────────────────────────────────
	# Real skaters' hips align with the direction of MOTION while the torso
	# twists toward the play; the legs stride along travel, not along the
	# chest. Facing follows the cursor here (twin-stick), so without this any
	# cursor-vs-movement misalignment bled the stride into the crossover /
	# backward blends and read as leg flail — systematically worse in the
	# rink direction where the tilted camera makes leading the cursor
	# awkward. The hips yaw toward travel (speed-gated so they settle back
	# under the torso at rest, clamped so genuinely backward/lateral skating
	# still plays the C-cut/crossover gaits on the residual), and the gait
	# below re-decomposes velocity in the HIP frame the legs actually occupy.
	# The hockey stop overrides alignment while blended in — perpendicular
	# beats parallel on the same lower-body channel.
	var align_target: float = 0.0
	if ground_speed > 0.1:
		var travel_angle: float = atan2(lat, fwd)
		var align_engage: float = clampf(
				_intensity / maxf(_controller.stance_full_speed_fraction, 0.01), 0.0, 1.0)
		# rotation.y positive turns the legs toward −X, i.e. toward NEGATIVE
		# body-frame angles — hence the negation.
		align_target = clampf(-travel_angle,
				-deg_to_rad(_controller.hip_align_max_deg),
				deg_to_rad(_controller.hip_align_max_deg)) * align_engage
	_hip_align_yaw = lerpf(_hip_align_yaw, align_target, _controller.hip_align_speed * delta)
	travel_align_yaw = _hip_align_yaw * (1.0 - _stop_blend)
	# Velocity in the yawed hip frame: v_hip = RotY(−ψ) · v_local.
	var hip_cos: float = cos(travel_align_yaw)
	var hip_sin: float = sin(travel_align_yaw)
	var hip_x: float = local_vel.x * hip_cos - local_vel.z * hip_sin
	var hip_z: float = local_vel.x * hip_sin + local_vel.z * hip_cos
	fwd = -hip_z
	lat = hip_x
	denom = absf(fwd) + absf(lat)
	fb_w = 1.0
	lr_w = 0.0
	if denom > 0.001:
		fb_w = absf(fwd) / denom
		lr_w = absf(lat) / denom

	# ── Stance: the speed-engaged crouch ───────────────────────────────────────
	# Real skaters sit into flexed hips and knees as soon as they're moving with
	# intent — the seated posture is most of what separates skating from walking
	# on blades. Engagement saturates well below top speed (stance_full_speed_
	# fraction) so even a cruise carries bent knees; effort then deepens the sit
	# when driving and lets it rise toward a taller glide when coasting. From
	# the hip flex alone, the knee flex that keeps the skate under the hip
	# (knee = hip + asin(thigh/shin · sin(hip))) and the vertical deficit of the
	# bent leg both follow from the leg geometry, so one export drives an
	# anatomically consistent crouch. The deficit is applied as a whole-body
	# drop (Skater.set_skating_crouch_drop) so the skates stay on the ice.
	var stance: float = clampf(
			_intensity / maxf(_controller.stance_full_speed_fraction, 0.01), 0.0, 1.0)
	stance *= clampf(1.0 + _effort * _controller.stance_push_gain, 0.0, 1.35)
	# Faceoff ready stance: at the dot the skater is at a standstill, so the
	# speed-driven envelope leaves them bolt upright — floor the engagement
	# through the countdown instead. Eased both ways: the crouch settles in
	# over the prep and releases into the draw as the players explode out.
	_faceoff_blend = lerpf(_faceoff_blend,
			1.0 if _controller.is_faceoff_ready() else 0.0,
			_controller.stride_intensity_speed * delta)
	if _faceoff_blend > 0.001:
		stance = maxf(stance, _controller.faceoff_stance * _faceoff_blend)
	# Hockey stop sits DEEP — the edges only bite under bent knees.
	if _stop_blend > 0.001:
		stance = maxf(stance, _controller.hockey_stop_stance * _stop_blend)
	var stance_hip: float = deg_to_rad(_controller.stance_hip_deg) * stance
	var stance_knee: float = stance_hip + asin(
			clampf(_THIGH_LEN / _SHIN_LEN * sin(stance_hip), -1.0, 1.0))
	var drop: float = _THIGH_LEN * (1.0 - cos(stance_hip)) \
			+ _SHIN_LEN * (1.0 - cos(stance_knee - stance_hip))

	# Asymmetric stroke: warp the phase before sampling the sine so each leg's swing
	# eases out to the push and snaps back, reading as skating rather than a
	# metronome tick-tock. The two legs are half a cycle apart, so the right leg
	# samples the SAME warp shifted by PI — `s_opp`, not a negated `s`. For a pure
	# sine sin(θ+PI) == -sin(θ), but once warped that identity breaks: negating
	# flips the skew, so `-s` would give the right leg the opposite (load-fast /
	# release-slow) asymmetry — one leg snappy, one not. Sampling θ+PI gives both
	# legs the identical slow-load / fast-release stroke. stride_skew in [0, 1);
	# 0 collapses both back to the pure sine (s_opp == -s). The fore/aft roll below
	# stays in-phase (`s` for both legs) on purpose — it's the shared weight-shift
	# edge rock, not a per-leg stroke.
	var skew: float = _controller.stride_skew
	var s: float = sin(stride_phase - skew * sin(stride_phase))
	var phase_opp: float = stride_phase + PI
	var s_opp: float = sin(phase_opp - skew * sin(phase_opp))
	# Swing-direction sample — d/dθ of the warped sine, positive while the leg
	# swings forward (its recovery). Normalized by (1 + skew), the derivative's
	# peak magnitude, so the tuck amplitude below is skew-independent.
	var c: float = cos(stride_phase - skew * sin(stride_phase)) \
			* (1.0 - skew * cos(stride_phase)) / (1.0 + skew)
	var c_opp: float = cos(phase_opp - skew * sin(phase_opp)) \
			* (1.0 - skew * cos(phase_opp)) / (1.0 + skew)
	var roll_amp: float = deg_to_rad(_controller.stride_roll_deg) * _intensity * push_scale * gait_scale

	# Stance hip flex applies in every gait — thighs pitch forward into the sit.
	var l_pitch: float = stance_hip
	var l_roll: float = 0.0
	var r_pitch: float = stance_hip
	var r_roll: float = 0.0

	# Faceoff foot stagger: stick-side foot drops back, braced for the draw.
	if _faceoff_blend > 0.001:
		var split: float = deg_to_rad(_controller.faceoff_split_deg) * _faceoff_blend \
				* (-1.0 if _skater.is_left_handed else 1.0)
		l_pitch += split
		r_pitch -= split

	# Hockey-stop leg pose, in the TURNED leg frame (the pose coordinator adds
	# stop_yaw_offset to the lower body): the leading leg braces ahead and the
	# trailing leg tucks behind (fore/aft split, side-signed), while both legs
	# roll the same way — the edges digging into the skid.
	if _stop_blend > 0.001:
		var stop_split: float = deg_to_rad(_controller.hockey_stop_split_deg) \
				* _stop_blend * _stop_side
		l_pitch += stop_split
		r_pitch -= stop_split
		var stop_edge: float = deg_to_rad(_controller.hockey_stop_edge_deg) \
				* _stop_blend * _stop_side
		l_roll += stop_edge
		r_roll += stop_edge

	# Forward / backward gait. Shared side-to-side roll rocks the lower body onto
	# alternating edges (each leg pivots about its own hip, so the same roll
	# extends the outer leg while the inner one tucks under — the skating weight
	# shift). Alternating fore/aft pitch makes it a push. Backward skating reaches
	# the legs forward to pull through C-cuts, so the push flips sign and uses a
	# shallower amplitude.
	var push_deg: float = _controller.stride_pitch_deg if fwd >= 0.0 else _controller.stride_back_pitch_deg
	var push_dir: float = 1.0 if fwd >= 0.0 else -1.0
	# A hard carve IS the stride — the fore/aft push bleeds out as the
	# crossover gait takes over (carve_stride_fade), instead of striding
	# straight ahead while the legs cross.
	var push_amp: float = deg_to_rad(push_deg) * _intensity * push_dir * push_scale * gait_scale \
			* (1.0 - absf(_carve) * _controller.carve_stride_fade)
	# Rear-bias the pitch stroke so the stride pushes BACK instead of kicking
	# forward: a CONSTANT offset shifts the whole swing rearward — the back
	# extension reaches (1+bias)·amp while the recovery lands only
	# (1−bias)·amp ahead, so the returning skate settles under the hips the
	# way a real stride does. A constant is load-bearing here: the earlier
	# s − bias·s² warp had the same endpoints but amplified the stroke SPEED
	# across the rear half in both directions, so the leg snapped forward out
	# of the push just as hard as it drove in — reading as a quick FORWARD
	# kick, the exact opposite of a real stride's explosive push / relaxed
	# recovery. An offset has zero effect on timing, leaving the stroke speed
	# purely to stride_skew (fast backswing, gentle return). Pitch channel
	# only; the edge-rock roll and the abduction gate keep the symmetric
	# wave. For the backward gait push_amp is negated, which flips the bias
	# toward the forward reach — the C-cut's long pull happens out front,
	# which is also correct.
	var bias: float = _controller.stride_rear_bias
	l_pitch += fb_w * (s - bias) * push_amp
	r_pitch += fb_w * (s_opp - bias) * push_amp
	l_roll += fb_w * s * roll_amp
	r_roll += fb_w * s * roll_amp

	# Abduction: the extending leg flares OUT to the side as it drives back —
	# the V-shaped hockey push — half-wave rectified (max(-s, 0) is that leg's
	# back-extension) so only the push half of each cycle flares while the
	# recovery returns under the body. Left leg flares toward -X: negative roll.
	var l_ext: float = maxf(-s, 0.0)
	var r_ext: float = maxf(-s_opp, 0.0)
	var abduct_amp: float = deg_to_rad(_controller.stride_abduction_deg) * _intensity * push_scale * gait_scale
	l_roll -= fb_w * abduct_amp * l_ext
	r_roll += fb_w * abduct_amp * r_ext

	# Strafe scissor. Lean into the travel direction (static bias toward the
	# inside) plus a scissoring roll 180° out of phase between the legs. This
	# is the AIM-LOCKED lateral shuffle — genuine crossovers (turning at
	# speed) are the carve block below, keyed off path curvature instead of
	# hip-frame lateral velocity (which hip alignment mostly removes anyway).
	var lean: float = signf(lat) * deg_to_rad(_controller.crossover_lean_deg) * _intensity * gait_scale
	var scissor: float = deg_to_rad(_controller.crossover_scissor_deg) * _intensity * push_scale * gait_scale
	l_roll += lr_w * (lean + s * scissor)
	r_roll += lr_w * (lean + s_opp * scissor)

	# ── Carve crossovers ──────────────────────────────────────────────────────
	# Turning at speed plays real crossovers, with FIXED roles set by the turn
	# direction (they never alternate): the OUTSIDE leg lifts and steps across
	# in front while the INSIDE leg extends in an under-push beneath the body.
	# Both act on the same half of the shared stride phase — the simultaneous
	# power stroke — and the wave's idle half is the glide between crossovers.
	# The clearance knee rides the RISE of the stroke (same derivative gate as
	# the recovery tuck) so the crossing skate lifts OVER the planted leg and
	# extends as it lands; the under-push leg feeds the existing knee-release
	# path through its ext value, so the extension stays anatomically
	# consistent with the stance geometry.
	var l_tuck_extra: float = 0.0
	var r_tuck_extra: float = 0.0
	var carve_amt: float = absf(_carve) * _intensity * gait_scale
	if carve_amt > 0.001:
		var stroke: float = maxf(s, 0.0)
		var over_roll: float = deg_to_rad(_controller.carve_over_roll_deg) * carve_amt * stroke
		var under_roll: float = deg_to_rad(_controller.carve_under_roll_deg) * carve_amt * stroke
		var over_pitch: float = deg_to_rad(_controller.carve_over_pitch_deg) * carve_amt * stroke
		var clearance: float = deg_to_rad(_controller.carve_clearance_knee_deg) \
				* carve_amt * maxf(c, 0.0)
		if _carve > 0.0:
			# Turning toward +X: left leg crosses over, right leg under-pushes.
			l_roll += over_roll
			l_pitch += over_pitch
			l_tuck_extra = clearance
			r_roll -= under_roll
			r_ext = maxf(r_ext, stroke)
		else:
			# Turning toward −X: mirrored roles.
			r_roll -= over_roll
			r_pitch += over_pitch
			r_tuck_extra = clearance
			l_roll += under_roll
			l_ext = maxf(l_ext, stroke)

	# Knee flex — three layers that read as one leg working. (1) The stance flex,
	# the seated base both knees carry. (2) Push extension: the loaded leg
	# straightens as it extends back (stance_knee_release of the stance flex gone
	# at full extension) — the power stroke. (3) Recovery tuck: the unloaded leg
	# folds as it swings back under the body (direction-gated on `c`, not
	# position, so the tuck rides the return swing and not the push-out through
	# the same spot). Negative folds the shin back under the body.
	var tuck_amp: float = deg_to_rad(_controller.stride_knee_deg) * _intensity * push_scale * gait_scale
	var release: float = _controller.stance_knee_release
	var l_knee: float = -(stance_knee * (1.0 - release * l_ext) + tuck_amp * maxf(c, 0.0) + l_tuck_extra)
	var r_knee: float = -(stance_knee * (1.0 - release * r_ext) + tuck_amp * maxf(c_opp, 0.0) + r_tuck_extra)

	# Body bob: the body rides highest at full extension (|s| = 1) and sits
	# deepest mid-transfer (s = 0) — a subtle vertical pulse at twice the leg
	# cadence that sells the weight moving from skate to skate.
	drop += _controller.stride_bob_m * _intensity * (1.0 - s * s) * gait_scale

	# Trunk texture, consumed by SkaterPoseCoordinator's next lean application:
	# effort digs the shoulders forward when driving (and tips them back on a
	# hard brake), and the torso rolls over the loaded leg with the weight shift.
	trunk_pitch_add = -deg_to_rad(_controller.stride_dig_lean_deg) * _effort
	trunk_roll_add = deg_to_rad(_controller.stride_sway_deg) * _intensity * fb_w * s * gait_scale
	# Hockey stop: the trunk banks over the skid (the dig-lean above already
	# tips the shoulders back against the braking effort).
	if _stop_blend > 0.001:
		trunk_roll_add += deg_to_rad(_controller.hockey_stop_trunk_roll_deg) \
				* _stop_blend * _stop_side

	# Stagger stumble: a checked player visibly fights for balance. The wobble
	# phase is derived FROM stagger_timer (a uniform countdown), so every
	# machine — and reconcile replay, which snaps the timer from the host —
	# renders the identical stumble with zero new network state. Amplitude
	# tracks the time left, so the wobble eases out with the recovery window;
	# the two axes run at incommensurate frequencies so it reads as a stumble,
	# not a metronome.
	var stagger_t: float = clampf(
			_controller.stagger_timer / maxf(_controller.stagger_max_seconds, 0.001), 0.0, 1.0)
	if stagger_t > 0.0:
		var wobble_amp: float = deg_to_rad(_controller.stagger_wobble_deg) * stagger_t
		var wobble_phase: float = _controller.stagger_timer * TAU * _controller.stagger_wobble_hz
		trunk_pitch_add += wobble_amp * sin(wobble_phase)
		trunk_roll_add += wobble_amp * 0.7 * sin(wobble_phase * 1.31)

	_skater.set_leg_swing(l_pitch, l_roll, l_knee, r_pitch, r_roll, r_knee)
	_skater.set_skating_crouch_drop(drop)
