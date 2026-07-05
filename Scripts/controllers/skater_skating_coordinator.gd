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
	trunk_pitch_add = 0.0
	trunk_roll_add = 0.0
	_prev_velocity = Vector3.ZERO
	_have_prev_velocity = false
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
	stride_phase = wrapf(stride_phase + phase_rate * delta, 0.0, TAU)

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
	if _have_prev_velocity:
		var accel: Vector3 = (vel - _prev_velocity) / delta
		var travel: Vector2 = Vector2(vel.x, vel.z)
		if travel.length() > 0.1:
			var tangential: float = Vector2(accel.x, accel.z).dot(travel.normalized())
			effort_target = clampf(
					tangential / maxf(_controller.stride_effort_ref_accel, 0.001), -1.0, 1.0)
	_prev_velocity = vel
	_have_prev_velocity = true
	_effort = lerpf(_effort, effort_target, _controller.stride_effort_speed * delta)
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
	var roll_amp: float = deg_to_rad(_controller.stride_roll_deg) * _intensity * push_scale

	# Stance hip flex applies in every gait — thighs pitch forward into the sit.
	var l_pitch: float = stance_hip
	var l_roll: float = 0.0
	var r_pitch: float = stance_hip
	var r_roll: float = 0.0

	# Forward / backward gait. Shared side-to-side roll rocks the lower body onto
	# alternating edges (each leg pivots about its own hip, so the same roll
	# extends the outer leg while the inner one tucks under — the skating weight
	# shift). Alternating fore/aft pitch makes it a push. Backward skating reaches
	# the legs forward to pull through C-cuts, so the push flips sign and uses a
	# shallower amplitude.
	var push_deg: float = _controller.stride_pitch_deg if fwd >= 0.0 else _controller.stride_back_pitch_deg
	var push_dir: float = 1.0 if fwd >= 0.0 else -1.0
	var push_amp: float = deg_to_rad(push_deg) * _intensity * push_dir * push_scale
	# Rear-bias the pitch stroke so the stride pushes BACK instead of kicking
	# forward: subtracting bias·s² (smooth, always toward extension) stretches
	# the back half of the swing to (1+bias)·amp while the recovery reaches only
	# (1−bias)·amp ahead — the returning skate lands under the hips the way a
	# real stride does, rather than marching out in front. Pitch channel only;
	# the edge-rock roll and the abduction gate keep the symmetric wave. For the
	# backward gait push_amp is negated, which flips the bias toward the forward
	# reach — the C-cut's long pull happens out front, which is also correct.
	var bias: float = _controller.stride_rear_bias
	l_pitch += fb_w * (s - bias * s * s) * push_amp
	r_pitch += fb_w * (s_opp - bias * s_opp * s_opp) * push_amp
	l_roll += fb_w * s * roll_amp
	r_roll += fb_w * s * roll_amp

	# Abduction: the extending leg flares OUT to the side as it drives back —
	# the V-shaped hockey push — half-wave rectified (max(-s, 0) is that leg's
	# back-extension) so only the push half of each cycle flares while the
	# recovery returns under the body. Left leg flares toward -X: negative roll.
	var l_ext: float = maxf(-s, 0.0)
	var r_ext: float = maxf(-s_opp, 0.0)
	var abduct_amp: float = deg_to_rad(_controller.stride_abduction_deg) * _intensity * push_scale
	l_roll -= fb_w * abduct_amp * l_ext
	r_roll += fb_w * abduct_amp * r_ext

	# Crossover gait. Lean into the travel direction (static bias toward the inside
	# of the turn) plus a scissoring roll 180° out of phase between the legs so
	# they cross over one another laterally.
	var lean: float = signf(lat) * deg_to_rad(_controller.crossover_lean_deg) * _intensity
	var scissor: float = deg_to_rad(_controller.crossover_scissor_deg) * _intensity * push_scale
	l_roll += lr_w * (lean + s * scissor)
	r_roll += lr_w * (lean + s_opp * scissor)

	# Knee flex — three layers that read as one leg working. (1) The stance flex,
	# the seated base both knees carry. (2) Push extension: the loaded leg
	# straightens as it extends back (stance_knee_release of the stance flex gone
	# at full extension) — the power stroke. (3) Recovery tuck: the unloaded leg
	# folds as it swings back under the body (direction-gated on `c`, not
	# position, so the tuck rides the return swing and not the push-out through
	# the same spot). Negative folds the shin back under the body.
	var tuck_amp: float = deg_to_rad(_controller.stride_knee_deg) * _intensity * push_scale
	var release: float = _controller.stance_knee_release
	var l_knee: float = -(stance_knee * (1.0 - release * l_ext) + tuck_amp * maxf(c, 0.0))
	var r_knee: float = -(stance_knee * (1.0 - release * r_ext) + tuck_amp * maxf(c_opp, 0.0))

	# Body bob: the body rides highest at full extension (|s| = 1) and sits
	# deepest mid-transfer (s = 0) — a subtle vertical pulse at twice the leg
	# cadence that sells the weight moving from skate to skate.
	drop += _controller.stride_bob_m * _intensity * (1.0 - s * s)

	# Trunk texture, consumed by SkaterPoseCoordinator's next lean application:
	# effort digs the shoulders forward when driving (and tips them back on a
	# hard brake), and the torso rolls over the loaded leg with the weight shift.
	trunk_pitch_add = -deg_to_rad(_controller.stride_dig_lean_deg) * _effort
	trunk_roll_add = deg_to_rad(_controller.stride_sway_deg) * _intensity * fb_w * s

	_skater.set_leg_swing(l_pitch, l_roll, l_knee, r_pitch, r_roll, r_knee)
	_skater.set_skating_crouch_drop(drop)
