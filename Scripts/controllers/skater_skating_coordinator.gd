class_name SkaterSkatingCoordinator
extends RefCounted

# Procedural skating stride — no skeleton, no animation clips. Advances a stride
# phase by ground speed and swings each leg about its hip via Skater.set_leg_swing(),
# matching the same per-frame "write the transforms" idiom the arm-bone IK already
# uses. Purely cosmetic and derived entirely from the skater's velocity, so it
# costs zero network state: remote skaters animate identically from the velocity
# that interpolation already hands them.
#
# The phase is advanced only on real render ticks — SkaterController guards the
# call with `not is_replaying` so reconcile re-simulation (many ticks per frame)
# doesn't over-spin the gait. Standstill freezes the phase (advance is scaled by
# speed) and the intensity envelope eases the legs back to their rest pose, so
# nothing pops when starting or stopping.

const State = SkaterStateMachine.State

var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _controller: SkaterController = null  # tunables live as @export on the controller

# ── Runtime State ─────────────────────────────────────────────────────────────
var stride_phase: float = 0.0
# Smoothed [0,1] stride intensity so the legs ease in/out of motion at the
# start/end of a stride instead of snapping to full amplitude.
var _intensity: float = 0.0

func setup(skater: Skater, sm: SkaterStateMachine, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_controller = controller

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

	# Advance phase by distance travelled so cadence scales with speed and freezes
	# at a standstill. stride_cadence is radians of phase per metre skated.
	stride_phase = wrapf(stride_phase + ground_speed * _controller.stride_cadence * delta, 0.0, TAU)

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

	var s: float = sin(stride_phase)
	var roll_amp: float = deg_to_rad(_controller.stride_roll_deg) * _intensity

	var l_pitch: float = 0.0
	var l_roll: float = 0.0
	var r_pitch: float = 0.0
	var r_roll: float = 0.0

	# Forward / backward gait. Shared side-to-side roll rocks the lower body onto
	# alternating edges (each leg pivots about its own hip, so the same roll
	# extends the outer leg while the inner one tucks under — the skating weight
	# shift). Alternating fore/aft pitch makes it a push. Backward skating reaches
	# the legs forward to pull through C-cuts, so the push flips sign and uses a
	# shallower amplitude.
	var push_deg: float = _controller.stride_pitch_deg if fwd >= 0.0 else _controller.stride_back_pitch_deg
	var push_dir: float = 1.0 if fwd >= 0.0 else -1.0
	var push_amp: float = deg_to_rad(push_deg) * _intensity * push_dir
	l_pitch += fb_w * s * push_amp
	r_pitch += fb_w * -s * push_amp
	l_roll += fb_w * s * roll_amp
	r_roll += fb_w * s * roll_amp

	# Crossover gait. Lean into the travel direction (static bias toward the inside
	# of the turn) plus a scissoring roll 180° out of phase between the legs so
	# they cross over one another laterally.
	var lean: float = signf(lat) * deg_to_rad(_controller.crossover_lean_deg) * _intensity
	var scissor: float = deg_to_rad(_controller.crossover_scissor_deg) * _intensity
	l_roll += lr_w * (lean + s * scissor)
	r_roll += lr_w * (lean - s * scissor)

	# Knee flex. Each knee tucks on the recovery half of its stroke and extends on
	# the push, 180° out of phase between legs. Direction-agnostic — the recovery
	# tuck reads the same whichever way the skater is travelling. Negative so the
	# shin folds back under the body (flip stride_knee_deg's sign to invert).
	var knee_amp: float = deg_to_rad(_controller.stride_knee_deg) * _intensity
	var l_knee: float = -knee_amp * (0.5 - 0.5 * s)
	var r_knee: float = -knee_amp * (0.5 + 0.5 * s)

	_skater.set_leg_swing(l_pitch, l_roll, l_knee, r_pitch, r_roll, r_knee)
