class_name SkaterSkatingCoordinator
extends RefCounted

# Procedural skating stride — no skeleton, no animation clips. Advances a stride
# phase by ground speed and swings each leg about its hip via Skater.set_leg_swing(),
# matching the same per-frame "write the transforms" idiom the arm-bone IK already
# uses. Beyond the leg swing it owns the skating STANCE: a speed-engaged crouch
# (hip + knee flex with a matching whole-body drop via Skater.set_skating_crouch_drop
# so the skates stay planted), a per-stride body bob, and the trunk texture the
# pose coordinator layers into the torso lean (trunk_pitch_add / trunk_roll_add
# — effort dig and weight-shift sway). Purely cosmetic and derived entirely from
# the skater's velocity, so it
# costs zero network state: remote skaters animate identically from the velocity
# that interpolation already hands them.
#
# The phase is advanced only on real render ticks — SkaterController guards the
# call with `not is_replaying` so reconcile re-simulation (many ticks per frame)
# doesn't over-spin the gait. Standstill freezes the phase (advance is scaled by
# speed) and the intensity envelope eases the legs back to their rest pose, so
# nothing pops when starting or stopping.

const State = SkaterStateMachine.State

# MESH-NATIVE leg segment spans from Scenes/Skater.tscn — hip pivot to knee
# pivot (LegL → ShinL) and knee pivot to skate sole (ShinL → FootL). Used to
# derive the stance knee flex and body drop from the hip flex so the crouch
# keeps the skates planted. Keep in sync with the scene if the leg pivots
# move. The knee-flex math only reads their RATIO, so it is build-independent;
# the vertical drop is a length and rides `leg_scale` below.
const _THIGH_LEN: float = 0.31
const _SHIN_LEN: float = 0.45
# Forward offset from the shin's end to the FOOT pivot (ShinL → FootL local −Z):
# the boot's centre sits ahead of the ankle, not under it. Folding the shin
# swings this offset from horizontal toward straight DOWN, so any solve that
# holds the boot LEVEL — the shot block's extended leg, the faceoff centre's
# address — owes the height it costs, or it buries that skate in the ice. A boot
# left to tilt with its shin does not: it keeps its sole planted, which is the
# model the stance crouch solves.
const _FOOT_FWD: float = 0.10

# Quiet time before the settled early-out in apply() engages. Sized to sit well
# past the slowest smoothed channel's convergence (the eases run at ≥ ~5/s, so
# one second leaves residuals under e⁻⁵ ≈ 0.7% of amplitude).
const _SETTLE_SECONDS: float = 1.0

# Cap on the effort/carve finite-difference sampling interval (see the aliasing
# note in apply()). A bit-identical velocity — true rest, or a cruise pinned
# exactly at the speed cap — never trips the changed-velocity sample, so the
# window forces a re-sample often enough (10 Hz, well above the ~5/s eases the
# targets feed) that the signals still read zero acceleration and decay.
const _FD_WINDOW_MAX: float = 0.1

# Smoothing rate of the ψ-rate signal the pivot detector thresholds. A trigger,
# not a pose channel, so a plain smoothed per-frame FD suffices (high-fps
# zero-tick frames average out through the ease instead of aliasing a pose).
const _PSI_RATE_EASE: float = 10.0

# Low-pass rate of the ψ every POSE-side consumer reads (the hemisphere fade
# and the whole pivot read). Raw ψ carries high-frequency content the pose must
# not: per-tick velocity-direction noise, and the facing tracker's
# freeze/unfreeze stutter at its unreachable-wedge gate — and the pivot
# consumes ψ multiplicatively (authority × phase × anchors), so every wiggle
# hits the hips three ways. One angle-aware filter upstream quiets all of them;
# the rate detector keeps reading raw ψ.
const _PSI_SMOOTH_EASE: float = 15.0

var _skater: Skater = null
var _sm: SkaterStateMachine = null
var _controller: SkaterController = null  # tunables live as @export on the controller

# Settled early-out state (see the block at the top of apply()).
var _settle_timer: float = 0.0
var _settled: bool = false

# Height multiplier for this build's legs, set by SkaterController
# .apply_attributes alongside the skeleton scaling (the appearance pass
# lengthens the actual leg pivot chain by the same factor). Scales the
# crouch's vertical body drop so the flexed legs' deficit matches the longer
# segments; the knee ANGLES are ratio-derived and stay build-independent.
var leg_scale: float = 1.0


# This build's (thigh, shin) segment lengths in metres — the knockdown sprawl
# solve (SkaterController._apply_knockdown_fall) shares the leg geometry the
# crouch solve uses, served from the one place that owns it.
func leg_segment_lengths() -> Vector2:
	return Vector2(_THIGH_LEN, _SHIN_LEN) * leg_scale


# How far the centre's faceoff address drops his body, in metres — the same
# crouch the gait settles at over the dot, derived instead of measured because
# the placement that needs it runs at the whistle, before the pose exists (and
# on a body still carrying whatever depth it was skating at). Full leg length
# minus the vertical span left by the address's hip flex, its knee (the flex
# that keeps the skate under the hip) and the cosine the width splay costs.
# test_faceoff_prep_pose.gd holds this against the settled live crouch.
func faceoff_address_drop() -> float:
	var hip: float = deg_to_rad(
			_controller.stance_hip_deg * _controller.faceoff_center_stance)
	var knee: float = hip + asin(
			clampf(_THIGH_LEN / _SHIN_LEN * sin(hip), -1.0, 1.0))
	var shin: float = knee - hip
	var span: float = leg_scale * (_THIGH_LEN * cos(hip) + _SHIN_LEN * cos(shin)
			+ _FOOT_FWD * sin(shin))
	return leg_scale * (_THIGH_LEN + _SHIN_LEN) \
			- span * cos(deg_to_rad(_controller.faceoff_center_width_deg))

# ── Runtime State ─────────────────────────────────────────────────────────────
var stride_phase: float = 0.0
# Per-stride trunk texture, written onto the cosmetic torso/helmet/shoulder
# BONES via Skater.set_trunk_texture — never onto the UpperBody node, whose
# rotation carries the blade markers (gameplay geometry; see the invariant in
# SkaterPoseCoordinator._apply_lean). Radians; updated on real ticks only, so
# it holds steady through reconcile replay like the rest of the gait.
var trunk_pitch_add: float = 0.0
var trunk_roll_add: float = 0.0
# Body drop of the crouch this pose pass settled on, in metres. Published
# because the faceoff placement measures the stick's span from the hand height
# the crouch leaves, and a skater's live depth is whatever he was skating at.
var crouch_drop: float = 0.0
# Inertia-filter state for the summed trunk texture (see the publish tail of
# apply() and trunk_texture_smooth_rate).
var _trunk_pitch_s: float = 0.0
var _trunk_roll_s: float = 0.0
# Eased 0..1 "committing a check" stance factor, tracked toward skater.hit_committed
# at render rate. Drives the load-up lean and crouch below.
var _hit_commit_blend: float = 0.0
# Smoothed [0,1] stride intensity so the legs ease in/out of motion at the
# start/end of a stride instead of snapping to full amplitude.
var _intensity: float = 0.0
# Smoothed effort signal in [-1, +1]: +1 driving hard (deep push), -1
# coasting/braking (settle into a glide). Derived from tangential acceleration —
# see apply(). Previous velocity backs the finite-difference; the flag suppresses
# the spurious spike on the very first frame (no prior sample yet). The _fd_*
# fields hold the last sampled targets between velocity changes — the FD is
# sampled over the accumulated interval since the velocity last stepped (see
# the aliasing note in apply()), not per render frame.
var _effort: float = 0.0
var _prev_velocity: Vector3 = Vector3.ZERO
var _have_prev_velocity: bool = false
var _fd_time: float = 0.0
var _fd_effort_target: float = 0.0
var _fd_turn: float = 0.0
var _fd_carve: float = 0.0
# Smoothed faceoff ready-stance engagement, so the crouch eases in over the
# countdown and releases into the draw instead of popping on the phase flip.
# Published: the address is not only a leg pose — the hands take their draw grip
# on the same ease (SkaterIKCoordinator.update_bottom_hand).
var faceoff_blend: float = 0.0
# Hockey-stop state (see the Hockey stop block in apply()). stop_yaw_offset is
# radians of lower-body rotation.y.
var stop_yaw_offset: float = 0.0
var _stop_engaged: bool = false
var _stop_side: float = 1.0
var _stop_blend: float = 0.0
# Hip-to-travel alignment (see the block in apply()).
var travel_align_yaw: float = 0.0
var _hip_align_yaw: float = 0.0
# Pivot read (PivotRules; the pivot block in apply()). The ψ finite difference
# mirrors the effort FD idiom; the engage/sense latches and blend mirror the
# hockey stop. Published THROUGH travel_align_yaw — while engaged the pivot IS
# the hip-alignment law, so it needs no lower-body channel of its own.
var _prev_psi: float = 0.0
var _have_prev_psi: bool = false
var _psi_smooth: float = 0.0
var _psi_rate: float = 0.0
var _pivot_engaged: bool = false
var _pivot_sense: float = 1.0
var _pivot_blend: float = 0.0
var _pivot_dwell: float = 0.0
# Pivot authority [0, 1], published for SkaterPoseCoordinator: while the hold
# owns the lower-body channel, the generic facing-lag pump fades out of the
# sum — two writers tracking the same rotation on different clocks is a
# wobble, not a pose.
var pivot_hold: float = 0.0
# Smoothed signed carve engagement [−1, +1] (CarveRules): path curvature
# drives the crossover gait. Sign = turn direction (+ = toward local +X).
var _carve: float = 0.0
# Curvature-only carve (no intent anticipation) and the smoothed travel turn
# rate (rad/s), for the crossover CADENCE: stride frequency during a carve
# follows the arc — crossovers per radian of heading change — not straight-line
# speed. Cadence keys off real curvature only, so an anticipatory intent-carve
# poses the legs without re-timing them until the path actually bends.
var _carve_curve: float = 0.0
var _turn_rate: float = 0.0
# Smoothed input-intent signals (GaitIntentRules) — what the player is TRYING
# to do, read from the replicated v15 intent byte. Eased so the 8-way octant
# flips remotes decode never pop the pose. _shuffle is SIGNED (+ = toward the
# body's +X); _glide is the no-keys coast engagement with its own slow sway
# phase (local-only — at sway amplitudes machines don't need to agree on it).
var _dig: float = 0.0
var _reversal: float = 0.0
var _shuffle: float = 0.0
var _backpedal: float = 0.0
var _glide: float = 0.0
var _glide_phase: float = 0.0
# Smoothed sprint engagement [0, 1], from the controller's resolved
# sprint_active (replicated for remotes, v16 intent byte). Sprint reads as
# LONGER strides — amplitude on top of push_scale, a deeper sit, and the
# shoulders driving — never faster leg turnover (the cadence tanh ceiling
# above stride_cadence_max_rate already owns that plateau).
var _sprint: float = 0.0
# Spring-damped lateral weight shift (Rosen-style secondary motion): the body
# RIDES over the loaded leg and settles with follow-through instead of rolling
# rigidly with the stride. Local integrator state, advanced only on real ticks
# and small in amplitude — machines needn't agree exactly (same contract as
# _glide_phase). Position + velocity of the critically-ish damped spring.
var _weight_shift: float = 0.0
var _weight_shift_vel: float = 0.0
# Shot body animation (see the Shot block in apply()). Driven from the
# replicated current_shot_state + shot_charge, exactly like the stick flex:
# the wrister load tracks the drag-charge through WRISTER_AIM, the slapper
# load tracks the wind-up through the charge states, and the transition into
# FOLLOW_THROUGH latches the smoothed load as the release kick's power (the
# raw charge may already be zeroed by then), with the kick's amplitude set
# picked by which charge it came from. shot_hip_yaw is radians of lower-body
# rotation.y.
var shot_hip_yaw: float = 0.0
var _shot_prev_state: int = 0
var _wrister_load: float = 0.0      # smoothed 0..1 drag-charge engagement
var _slap_load: float = 0.0         # smoothed 0..1 wind-up engagement
var _shot_kick_t: float = -1.0      # seconds into the release kick; <0 = idle
var _shot_kick_power: float = 0.0   # load latched at release (min-pop floored)
var _shot_kick_is_slap: bool = false
# Smoothed shot-block engagement: the one-knee drop snaps in with the committed
# plant and eases back out on release. Keyed off the replicated
# current_shot_state like the shot signals above.
var _block_blend: float = 0.0
# Check-delivery drive: the hitter's shoulder finishing through the contact.
# Started by SkaterController.start_check_drive off the host-authoritative
# body_check_landed broadcast (and the replay event dispatcher), so every
# machine plays the identical drive the same frame as the burst/thud.
var _drive_dir: Vector3 = Vector3.ZERO  # world-space, attacker → victim
var _drive_t: float = -1.0              # seconds into the drive; <0 = idle
var _drive_intensity: float = 0.0       # 0..1 VFX hit hardness
# Smoothed stick-lift engagement — the working posture while jabbing under an
# opponent's stick. Keyed off the replicated blade_up.
var _lift_blend: float = 0.0

# NativeSkaterGait (null = extension absent, the GDScript body below runs).
# The native port carries the full gait state machine; this class then acts as
# the wrapper that feeds inputs, writes the pose outputs, and republishes the
# trunk/yaw channels the pose coordinator reads.
var _native: RefCounted = null

func setup(skater: Skater, sm: SkaterStateMachine, controller: SkaterController) -> void:
	_skater = skater
	_sm = sm
	_controller = controller
	if ClassDB.class_exists(&"NativeSkaterGait"):
		_native = ClassDB.instantiate(&"NativeSkaterGait")
		_native.set_state_ids(
				State.SKATING_WITH_PUCK, State.SKATING_WITHOUT_PUCK,
				State.SHOT_BLOCKING, State.FOLLOW_THROUGH, State.WRISTER_AIM,
				State.SLAPPER_CHARGE_WITH_PUCK, State.SLAPPER_CHARGE_WITHOUT_PUCK,
				State.ONE_TIMER_RETENTION)
		native_reconfigure()

# Reloads the native port's tunables and leg scale from the controller.
# Called from setup and from SkaterController.apply_attributes (which rewrites
# the exports the config was built from — same invalidation moment as the
# cached movement/IK configs).
func native_reconfigure() -> void:
	if _native == null:
		return
	var missing: String = _native.configure(_controller)
	if missing != "":
		# A rename/removal desynced the port's tunable table — running it with
		# stale values would be a silent behavior fork. Loudly fall back.
		push_error("NativeSkaterGait disabled — controller exports missing: %s" % missing)
		_native = null
		return
	# A stale extension build can pass configure (all ITS exports still exist)
	# while running old gait math and lacking newer getters — which the
	# republish would then error on EVERY FRAME. Probe the NEWEST getter this
	# coordinator calls and loudly fall back instead.
	if not _native.has_method(&"get_faceoff_blend"):
		push_error("NativeSkaterGait disabled — stale extension build (rebuild native/)")
		_native = null
		return
	_native.set_leg_scale(leg_scale)

# Snaps the gait back to a clean standstill and plants the legs at their rest
# pose. Called on faceoff / respawn teleports so a skater doesn't drop into the
# dot mid-stride carrying the previous shift's leg swing.
func reset_to_rest() -> void:
	if _native != null:
		_native.reset_to_rest()
	stride_phase = 0.0
	_intensity = 0.0
	_effort = 0.0
	crouch_drop = 0.0
	faceoff_blend = 0.0
	trunk_pitch_add = 0.0
	trunk_roll_add = 0.0
	_trunk_pitch_s = 0.0
	_trunk_roll_s = 0.0
	_prev_velocity = Vector3.ZERO
	_have_prev_velocity = false
	_fd_time = 0.0
	_fd_effort_target = 0.0
	_fd_turn = 0.0
	_fd_carve = 0.0
	stop_yaw_offset = 0.0
	_stop_engaged = false
	_stop_blend = 0.0
	travel_align_yaw = 0.0
	_hip_align_yaw = 0.0
	_prev_psi = 0.0
	_have_prev_psi = false
	_psi_smooth = 0.0
	_psi_rate = 0.0
	_pivot_engaged = false
	_pivot_sense = 1.0
	_pivot_blend = 0.0
	_pivot_dwell = 0.0
	pivot_hold = 0.0
	_carve = 0.0
	_carve_curve = 0.0
	_turn_rate = 0.0
	_dig = 0.0
	_reversal = 0.0
	_shuffle = 0.0
	_backpedal = 0.0
	_glide = 0.0
	_glide_phase = 0.0
	_sprint = 0.0
	_weight_shift = 0.0
	_weight_shift_vel = 0.0
	shot_hip_yaw = 0.0
	_shot_prev_state = 0
	_wrister_load = 0.0
	_slap_load = 0.0
	_shot_kick_t = -1.0
	_shot_kick_power = 0.0
	_shot_kick_is_slap = false
	_block_blend = 0.0
	_drive_dir = Vector3.ZERO
	_drive_t = -1.0
	_drive_intensity = 0.0
	_lift_blend = 0.0
	if _skater != null:
		_skater.set_leg_swing(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
		_skater.set_skating_crouch_drop(0.0)
		_skater.set_trunk_texture(0.0, 0.0)
		_skater.set_edge_loads(0.0, 0.0)


# The ready-stance crouch floor and foot split for this skater's role at the
# dot: the centre taking the draw sits deeper and splits wider than the players
# lined up behind him (see SkaterController.faceoff_center_stance). Both read
# the same replicated-by-derivation flag, so a wire-fed remote centre poses
# identically to a locally-simulated one.
func _faceoff_stance_floor() -> float:
	return _controller.faceoff_center_stance if _skater.is_faceoff_center \
			else _controller.faceoff_stance


func _faceoff_split_deg() -> float:
	return _controller.faceoff_center_split_deg if _skater.is_faceoff_center \
			else _controller.faceoff_split_deg


# Arms the check-delivery drive (see the runtime state above). During
# sustained contact or a quick follow-up hit inside an active drive the
# broadcast can re-fire: harden the intensity but never restart the clock —
# a re-zeroed envelope would pin the pose at its rise for as long as the
# contact grinds.
func start_check_drive(hit_dir: Vector3, intensity: float) -> void:
	if _native != null:
		_native.start_check_drive(hit_dir, intensity)
	var flat := Vector3(hit_dir.x, 0.0, hit_dir.z)
	if flat.length_squared() < 0.0001 or intensity <= 0.0:
		return
	if _drive_t >= 0.0:
		_drive_intensity = maxf(_drive_intensity, intensity)
		return
	_drive_dir = flat.normalized()
	_drive_intensity = intensity
	_drive_t = 0.0

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
	if _native != null:
		_apply_native(delta)
		return

	# ── Settled early-out ──────────────────────────────────────────────────────
	# At true rest the converged gait pose is static: with no inputs, no speed,
	# no timers and a plain skating state, every smoothed channel decays to zero
	# and the pass rewrites the same rest pose every frame — the fixed cost the
	# micro-benchmark's "at rest" row measures. Detect the steady state from the
	# same replicated inputs the pass itself reads (so remotes settle too), and
	# once quiet has held for _SETTLE_SECONDS — long past every ease/spring's
	# convergence, residuals far below perception — snap to the exact rest pose
	# once (reset_to_rest) and hold. Any input, speed, timer, or state change
	# fails `quiet` and the full pass runs again the same frame.
	var qvel: Vector3 = _skater.velocity
	var quiet: bool = (
			qvel.x * qvel.x + qvel.z * qvel.z < 0.0025
			and _skater.move_intent.length_squared() <= 0.0025
			and not _skater.brake_intent
			and not _controller.sprint_active
			and not _skater.hit_committed
			and not _skater.blade_up
			and (_skater.current_shot_state == State.SKATING_WITH_PUCK
				or _skater.current_shot_state == State.SKATING_WITHOUT_PUCK)
			and _skater.current_shot_state == _shot_prev_state
			and _controller.stagger_timer <= 0.0
			and _controller.knockdown_timer <= 0.0
			and _drive_t < 0.0 and _shot_kick_t < 0.0
			and not _controller.is_faceoff_ready()
			and _controller.celebration_progress() <= 0.0)
	if quiet:
		_settle_timer = minf(_settle_timer + delta, _SETTLE_SECONDS)
		if _settle_timer >= _SETTLE_SECONDS:
			if not _settled:
				_settled = true
				reset_to_rest()
				# reset_to_rest clears the shot-transition latch to 0; re-stamp
				# the live state or `quiet` fails every other frame and the
				# settle/reset cycle never holds.
				_shot_prev_state = _skater.current_shot_state
			return
	else:
		_settle_timer = 0.0
		_settled = false

	var vel: Vector3 = _skater.velocity
	# Ground speed only — vertical velocity never feeds the stride.
	var ground_speed: float = Vector2(vel.x, vel.z).length()
	var speed_t: float = clampf(ground_speed / maxf(_controller.max_speed, 0.001), 0.0, 1.0)

	# Plant the legs while shot-blocking (the one-knee drop below owns them);
	# otherwise drive intensity from speed — GATED BY INTENT: no movement keys
	# means a glide, so the legs settle to rest and ride the edges even at full
	# speed. The stride is something the player DOES, not something speed does
	# to them. (Velocity lean, the carve/faceoff/stop stance floors, and the
	# glide stance floor below keep the posture alive while coasting.) Read off
	# the REPLICATED shot state, not the state machine — a wire-fed remote's
	# state machine is never ticked, so it would never see the block.
	var planted: bool = _skater.current_shot_state == State.SHOT_BLOCKING
	var has_move_intent: bool = _skater.move_intent.length_squared() > 0.0025

	# ── Intent signals ─────────────────────────────────────────────────────────
	# What the player is TRYING to do (GaitIntentRules), read from the same
	# replicated intent as the stride gate, decomposed into the body frame
	# where the read is facing-relative (forward = (0, −1)). All smoothed at
	# intent_signal_speed so the 8-way octant flips remotes decode never pop.
	var mi: Vector2 = _skater.move_intent
	var basis_inv: Basis = _skater.global_transform.basis.inverse()
	var local_intent3: Vector3 = basis_inv * Vector3(mi.x, 0.0, mi.y)
	var local_intent: Vector2 = Vector2(local_intent3.x, local_intent3.z)
	var dig_t: float = 0.0
	var rev_t: float = 0.0
	var shuf_t: float = 0.0
	var back_t: float = 0.0
	if not planted:
		dig_t = GaitIntentRules.dig_in(has_move_intent, ground_speed, _controller.dig_in_fade_speed)
		rev_t = GaitIntentRules.reversal(Vector2(vel.x, vel.z), mi, ground_speed,
				_controller.reversal_min_speed, _controller.reversal_start_opposition)
		shuf_t = GaitIntentRules.shuffle(local_intent, ground_speed,
				_controller.shuffle_fade_speed, _controller.shuffle_start_lateral)
		back_t = GaitIntentRules.backpedal(local_intent, _controller.backpedal_start)
	var intent_ease: float = _controller.intent_signal_speed * delta
	_dig = lerpf(_dig, dig_t, intent_ease)
	_reversal = lerpf(_reversal, rev_t, intent_ease)
	_shuffle = lerpf(_shuffle, shuf_t, intent_ease)
	_backpedal = lerpf(_backpedal, back_t, intent_ease)
	_glide = lerpf(_glide, 0.0 if (has_move_intent or planted or _skater.brake_intent) else 1.0,
			intent_ease)
	_sprint = lerpf(_sprint,
			1.0 if (_controller.sprint_active and not planted) else 0.0, intent_ease)

	# ── Shots: load + release kick signals ─────────────────────────────────────
	# The wrister load tracks the drag-charge through WRISTER_AIM; the slapper
	# load tracks the wind-up through the charge states. Entering FOLLOW_THROUGH
	# latches the smoothed load as the kick's power (floored by the min pop so
	# an uncharged snap still reads and a short-wind slap still commits), with
	# the amplitude set picked by which charge it came from — a quick-shot pass
	# (no charge state at all) rides the wrister set, the same split the stick
	# flex uses. The kick then rides the shared asymmetric arc (fast weight
	# transfer through the release, slow settle) on its own cosmetic timer —
	# remotes don't see the state machine's follow-through timer, only the
	# state flip.
	var shot_state: int = _skater.current_shot_state
	# The one-timer's retention hold is the loaded tail of the wind-up, so the
	# legs stay in the slapper load through it — and the follow-through it hands
	# off to is a slap kick, not a wrister's (every one-timer now reaches
	# FOLLOW_THROUGH via retention, so omitting it here would misclassify all of
	# them).
	var in_slap_charge: bool = shot_state == State.SLAPPER_CHARGE_WITH_PUCK \
			or shot_state == State.SLAPPER_CHARGE_WITHOUT_PUCK \
			or shot_state == State.ONE_TIMER_RETENTION
	if shot_state != _shot_prev_state:
		if shot_state == State.FOLLOW_THROUGH:
			_shot_kick_t = 0.0
			_shot_kick_is_slap = _shot_prev_state == State.SLAPPER_CHARGE_WITH_PUCK \
					or _shot_prev_state == State.SLAPPER_CHARGE_WITHOUT_PUCK \
					or _shot_prev_state == State.ONE_TIMER_RETENTION
			if _shot_kick_is_slap:
				_shot_kick_power = maxf(_slap_load, _controller.slapper_kick_min_power)
			else:
				# Latch from the release charge as well as the smoothed aim load:
				# the frozen wrister is a quick flick, so _wrister_load never builds
				# over the brief coil and would pin the kick at the min-power floor.
				# shot_charge holds the release power through the follow-through, so
				# a hard flick drives a hard leg kick; on the non-frozen path
				# _wrister_load ≈ shot_charge and the max changes nothing.
				_shot_kick_power = maxf(
						maxf(_wrister_load, _skater.shot_charge),
						_controller.wrister_kick_min_power)
		_shot_prev_state = shot_state
	var wrister_target: float = _skater.shot_charge if shot_state == State.WRISTER_AIM else 0.0
	_wrister_load = lerpf(_wrister_load, wrister_target,
			minf(_controller.wrister_load_blend_speed * delta, 1.0))
	# Slapper wind-up engagement, re-derived from the replicated charge the way
	# every machine can: shot_charge and the wind-up pose both fill over
	# max_slapper_charge_time (the pose is the charge gauge — see
	# SkaterController.slapper_wind_up_t), so shot_charge IS the wind-up
	# progress; sqrt-ease to match the torso coil's front-loaded snap
	# (SkaterPoseCoordinator.apply_upper_body).
	var slap_target: float = 0.0
	if in_slap_charge:
		slap_target = sqrt(clampf(_skater.shot_charge, 0.0, 1.0))
	_slap_load = lerpf(_slap_load, slap_target,
			minf(_controller.wrister_load_blend_speed * delta, 1.0))
	var kick_env: float = 0.0
	if _shot_kick_t >= 0.0:
		_shot_kick_t += delta
		var kick_total: float = _controller.slapper_kick_time if _shot_kick_is_slap \
				else _controller.wrister_kick_time
		var kt: float = _shot_kick_t / maxf(kick_total, 0.001)
		if kt >= 1.0:
			_shot_kick_t = -1.0
		else:
			kick_env = sin(PI * pow(kt, _controller.follow_through_arc_skew)) * _shot_kick_power
	# Shot-block engagement: fast into the committed plant, eased back out on
	# release so the knee drop doesn't pop back to a stride.
	_block_blend = lerpf(_block_blend, 1.0 if planted else 0.0,
			minf(_controller.block_pose_blend_speed * delta, 1.0))
	# Check-delivery drive envelope: an explosive rise (peaks ~15% in) easing
	# out over check_drive_time — the shoulder finishing through the contact.
	var drive_env: float = 0.0
	if _drive_t >= 0.0:
		_drive_t += delta
		var du: float = _drive_t / maxf(_controller.check_drive_time, 0.001)
		if du >= 1.0:
			_drive_t = -1.0
		else:
			drive_env = sin(PI * pow(du, 0.35)) * _drive_intensity
	# Stick-lift read, off the replicated blade_up (own lift or a forced pop —
	# either way the body reacts).
	_lift_blend = lerpf(_lift_blend, 1.0 if _skater.blade_up else 0.0,
			minf(_controller.stick_lift_blend_speed * delta, 1.0))
	# Celebration window: this pass runs at RENDER rate (Skater._process) and is
	# visibility-gated, so it only READS the progress — the callers age the timer
	# at physics rate (SkaterController._process_input / RemoteController.
	# _physics_process) so it stays deterministic and never freezes off-screen.
	var celebr_p: float = _controller.celebration_progress()
	# Combined engagement, for the stride suppression below — shooting is a
	# glide (the feet set through the load and drive through the release), and
	# a landed check plants through the finish.
	var shot_body: float = maxf(maxf(_wrister_load, _slap_load), maxf(kick_env, drive_env))
	var stick_side: float = -1.0 if _skater.is_left_handed else 1.0
	# Hips coil with the load (stick-side hip pulls back, riding the torso coil
	# — the wrister's blade-tracking twist or the slapper's authored wind-up
	# coil) and uncoil THROUGH the release — the stick-side hip drives forward
	# past square, mirroring the follow-through's torso `through` term.
	# Positive lower-body yaw turns the legs toward −X, i.e. pulls the +X hip
	# forward, hence the signs.
	var kick_hip_yaw_deg: float = _controller.slapper_kick_hip_yaw_deg if _shot_kick_is_slap \
			else _controller.wrister_kick_hip_yaw_deg
	shot_hip_yaw = -stick_side * (
				deg_to_rad(_controller.wrister_load_hip_coil_deg) * _wrister_load
				+ deg_to_rad(_controller.slapper_load_hip_coil_deg) * _slap_load) \
			+ stick_side * deg_to_rad(kick_hip_yaw_deg) * kick_env

	var target_intensity: float = speed_t if (has_move_intent and not planted) else 0.0
	# Dig-in / shuffle floors: the legs work from a standstill when the player
	# is ASKING for movement, before there's speed to drive them — the choppy
	# first strides and the net-front side-step.
	if not planted:
		target_intensity = maxf(target_intensity, maxf(
				_dig * _controller.dig_in_intensity,
				absf(_shuffle) * _controller.shuffle_intensity))
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
	# Cadence "gears" (grounded in on-ice biomechanics: stride frequency DROPS
	# from acceleration to sustained max velocity while the glide phase and
	# ground-contact time lengthen — speed comes from power per stride, not
	# faster turnover). cruise_gear is high when the skater is FAST but not still
	# driving to gain speed (prior-frame _effort — the one-frame lag is invisible
	# through the smoothing, same as the stop/reversal reads below). It eases the
	# stride rate down here, deepens the sit and lengthens the glide dwell (extra
	# stroke skew) further down — all zero while accelerating/digging, so the
	# start and chop feel is unchanged.
	var cruise_gear: float = speed_t * (1.0 - clampf(_effort, 0.0, 1.0))
	phase_rate *= 1.0 - _controller.cadence_cruise_falloff * cruise_gear
	# Crossover cadence: while the path is actually bending (curvature-only
	# carve + smoothed turn rate — prior-frame values, the same documented
	# one-frame lag as the stop/reversal reads below), stride frequency follows
	# the ARC instead of straight-line speed: the feet step per radian of
	# heading change (crossover_phase_per_turn), so a hard tight turn quickens
	# the crossovers while a wide arc at speed glides between steps. Gated to
	# forward travel — backward turning keeps its C-cuts on the speed law (the
	# carve overlay below is gated by the same forwardness).
	var carve_fwd_gate: float = clampf(-(basis_inv * vel).z
			/ maxf(_controller.carve_forward_ramp, 0.001), 0.0, 1.0)
	var carve_cadence: float = absf(_carve_curve) * carve_fwd_gate
	if carve_cadence > 0.001:
		phase_rate = lerpf(phase_rate,
				absf(_turn_rate) * _controller.crossover_phase_per_turn, carve_cadence)
	# Dig-in chop / shuffle steps put leg turnover UNDER the speed law: quick
	# first strides and side-steps cycle before the body is moving fast enough
	# to advance the phase on its own.
	phase_rate = maxf(phase_rate, maxf(_dig * _controller.dig_in_cadence_rate,
			absf(_shuffle) * _controller.shuffle_cadence_rate))
	# The stop/reversal plant and the pivot's gliding transit (previous frame's
	# values — computed below, and the one-frame lag is invisible through the
	# smoothing) freeze the stride: scraping, planted, and open-hip blades
	# don't stride.
	stride_phase = wrapf(stride_phase + phase_rate
			* (1.0 - maxf(maxf(_stop_blend, _reversal * _controller.reversal_stride_fade),
					_pivot_blend * _controller.pivot_stride_fade)) * delta,
			0.0, TAU)

	# ── Effort: glide vs. push ─────────────────────────────────────────────────
	# Velocity-only skating pumps the legs purely by speed, so a skater coasting at
	# top speed strides exactly as hard as one digging for it. Real skating glides
	# when it isn't gaining speed and pushes hard when it is. Recover that intent
	# from the sign of tangential acceleration (the component of accel along travel):
	# speeding up reads as a push, coasting/braking as a glide. Acceleration is the
	# only "is the player pushing?" signal available without new network state — it
	# falls out of the velocity remotes and replays already have — so they inherit
	# the glide/push texture for free, exactly like the rest of the gait.
	# The FD is sampled over the time since the velocity LAST CHANGED, not per
	# render frame: velocity only steps on 120 Hz physics ticks, so above 120 fps
	# a per-frame difference alternates between zero (no tick this frame) and
	# ~double the true acceleration — a beat-frequency shimmer on every
	# effort-driven channel (trunk dig pitch, stride amplitude, stance depth).
	# Holding the last sample through no-tick frames and dividing by the
	# accumulated interval reads the true acceleration at any frame rate.
	_fd_time += delta
	if not _have_prev_velocity:
		_prev_velocity = vel
		_have_prev_velocity = true
		_fd_time = 0.0
	elif vel != _prev_velocity or _fd_time >= _FD_WINDOW_MAX:
		var accel: Vector3 = (vel - _prev_velocity) / _fd_time
		var travel: Vector2 = Vector2(vel.x, vel.z)
		_fd_effort_target = 0.0
		if travel.length() > 0.1:
			var tangential: float = Vector2(accel.x, accel.z).dot(travel.normalized())
			_fd_effort_target = clampf(
					tangential / maxf(_controller.stride_effort_ref_accel, 0.001), -1.0, 1.0)
		# Path curvature off the same velocity history — the carve/crossover
		# trigger (see CarveRules and the carve block below). The raw turn
		# rate is kept for the crossover cadence law above.
		_fd_turn = CarveRules.turn_rate(
				Vector2(_prev_velocity.x, _prev_velocity.z),
				Vector2(vel.x, vel.z), _fd_time, _controller.carve_min_speed)
		_fd_carve = CarveRules.carve_target(_fd_turn,
				ground_speed, _controller.carve_ref_turn_rate, _controller.carve_min_speed)
		_prev_velocity = vel
		_fd_time = 0.0
	var effort_target: float = _fd_effort_target
	var carve_target: float = _fd_carve
	var raw_turn: float = _fd_turn
	# Curvature-only engagement for the cadence law, smoothed BEFORE intent is
	# folded in — anticipation poses the legs, only a real arc re-times them.
	var curve_only: float = carve_target
	# Intent carve: holding ACROSS the travel line anticipates the turn —
	# crossovers fire to show what the player is TRYING to do, before the
	# path visibly bends. Combined with the curvature signal by larger
	# magnitude so the two never double-count.
	var intent_carve: float = CarveRules.intent_carve(
			Vector2(vel.x, vel.z), _skater.move_intent,
			ground_speed, _controller.carve_min_speed)
	if absf(intent_carve) > absf(carve_target):
		carve_target = intent_carve
	_effort = lerpf(_effort, effort_target, _controller.stride_effort_speed * delta)
	_carve = lerpf(_carve, carve_target, _controller.carve_engage_speed * delta)
	_carve_curve = lerpf(_carve_curve, curve_only, _controller.carve_engage_speed * delta)
	_turn_rate = lerpf(_turn_rate, raw_turn, _controller.carve_engage_speed * delta)
	# Push-amplitude scale around the speed baseline: >1 driving, easing toward
	# stride_glide_floor when coasting so the legs settle instead of churning. The
	# static crossover lean is intentionally left off this scale — you still lean
	# through a turn while gliding.
	var push_scale: float = clampf(1.0 + _effort * _controller.stride_push_gain,
			_controller.stride_glide_floor, _controller.stride_push_ceiling)
	# Sprint lengthens every stroke channel that rides push_scale (push, roll,
	# abduction, tuck, scissor) — applied OUTSIDE the effort clamp because the
	# effort signal is tangential accel, which decays to zero once the sprint
	# reaches its raised speed cap: exactly when the sprint should still read.
	push_scale *= 1.0 + _sprint * _controller.sprint_stride_gain

	# Decompose travel into the body frame: -Z is forward, +X is the skater's right.
	var local_vel: Vector3 = basis_inv * vel
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
				_controller.hockey_stop_effort, _controller.hockey_stop_min_speed,
				_skater.brake_intent):
			_stop_engaged = false
	elif HockeyStopRules.should_engage(_effort, ground_speed,
			_controller.hockey_stop_effort, _controller.hockey_stop_min_speed,
			_skater.brake_intent):
		_stop_engaged = true
		_stop_side = HockeyStopRules.latch_side(local_vel)
	_stop_blend = lerpf(_stop_blend, 1.0 if _stop_engaged else 0.0,
			_controller.hockey_stop_blend_speed * delta)
	if _stop_blend > 0.001:
		stop_yaw_offset = HockeyStopRules.stop_yaw(local_vel, _stop_side,
				deg_to_rad(_controller.hockey_stop_max_yaw_deg)) * _stop_blend
	else:
		stop_yaw_offset = 0.0
	# Stride suppression factor: 1 = normal gait, 0 = fully planted (stop pose,
	# the reversal plant, or the pivot's gliding transit — fighting momentum
	# and swapping ends are edges, not strides).
	var gait_scale: float = 1.0 - maxf(
			maxf(_stop_blend, _reversal * _controller.reversal_stride_fade),
			_pivot_blend * _controller.pivot_stride_fade)
	# Shooting is a glide: while a shot load or the release kick is live the
	# stride blends out — a shooter sets their feet, they don't keep striding
	# through the shot.
	gait_scale *= 1.0 - shot_body * _controller.shot_stride_fade
	# Reversal engagement for the plant/lean adds below. The hockey stop wins
	# the shared channels when both fire (brake held while holding opposite).
	var rev_amt: float = _reversal * (1.0 - _stop_blend)

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
	# ψ — the travel direction in the body frame. Zero speed leaves it at the
	# previous sample: atan2 of a near-zero vector is noise, and the pivot
	# below releases on the speed floor anyway.
	var psi: float = _prev_psi
	if ground_speed > 0.1:
		psi = atan2(lat, fwd)
		var align_engage: float = clampf(
				_intensity / maxf(_controller.stance_full_speed_fraction, 0.01), 0.0, 1.0)
		# rotation.y positive turns the legs toward −X, i.e. toward NEGATIVE
		# body-frame angles — hence the negation.
		align_target = clampf(-psi,
				-deg_to_rad(_controller.hip_align_max_deg),
				deg_to_rad(_controller.hip_align_max_deg)) * align_engage
	# ψ low-passed for every pose-side consumer (see _PSI_SMOOTH_EASE). Snapped
	# on the first sample so a mid-motion spawn doesn't sweep the filter
	# through the band from zero.
	if not _have_prev_psi:
		_psi_smooth = psi
	else:
		_psi_smooth = wrapf(_psi_smooth
				+ angle_difference(_psi_smooth, psi) * minf(_PSI_SMOOTH_EASE * delta, 1.0),
				-PI, PI)
	var abs_psi: float = absf(_psi_smooth)
	var band_lo: float = deg_to_rad(_controller.pivot_band_lo_deg)
	var band_hi: float = deg_to_rad(_controller.pivot_band_hi_deg)
	# A deliberate backpedal or sidestep is an AIM-LOCKED stance — the
	# defender back-skates and the net-front shuffler side-steps with hips
	# square to the chest, so intent suppresses the travel alignment and the
	# body-frame backward / lateral gaits play in full.
	align_target *= 1.0 - maxf(_backpedal, absf(_shuffle))
	# Hips align TOWARD travel only while travel is broadly ahead: past 90° the
	# sensible anchor flips to hips-square (the backward C-cut stance), so the
	# clamp's ±hip_align_max pull fades out geometrically across the band's
	# back half. The intent suppression above covers the deliberate backpedal;
	# this covers the same geometry when no intent is held — most visibly the
	# pivot's release tail, which would otherwise hand the hips from the
	# step-around straight to a ±50° yank toward a behind-the-back travel line.
	align_target *= 1.0 - clampf(
			(abs_psi - PI * 0.5) / maxf(band_hi - PI * 0.5, 0.001), 0.0, 1.0)
	# ── Pivot: the facing↔travel swap ──────────────────────────────────────────
	# ψ transiting the lateral band at speed is a pivot — the one event the
	# twin-stick scheme produces two ways (cursor swung across a held travel
	# line, or travel swung under a held cursor) that are identical in the body
	# frame, so one read covers both. The dψ/dt trigger separates it from a
	# carve for free: ψ = travel heading − facing heading, and a coordinated
	# carve rotates both together (ψ barely moves) while a pivot whips facing
	# against travel. While engaged the hips get the one thing the alignment
	# clamp forbids — tracking ψ fully — holding the entry orientation on the
	# gliding blades, then stepping around to the exit orientation over the
	# transit's tail (PivotRules.pivot_yaw). Phase derives from ψ's actual
	# progress, not a timer: a snap pivot and a slow open-hip glide both read
	# right, and an aborted swing unwinds back through the same poses.
	var psi_rate_raw: float = 0.0
	if _have_prev_psi:
		psi_rate_raw = angle_difference(_prev_psi, psi) / delta
	_prev_psi = psi
	_have_prev_psi = true
	_psi_rate = lerpf(_psi_rate, psi_rate_raw, minf(_PSI_RATE_EASE * delta, 1.0))
	if _pivot_engaged:
		if PivotRules.should_release(abs_psi, ground_speed, band_lo, band_hi,
				_controller.pivot_min_speed):
			_pivot_engaged = false
	elif PivotRules.should_engage(abs_psi, absf(_psi_rate), ground_speed,
			band_lo, band_hi, _controller.pivot_rate_min, _controller.pivot_min_speed):
		_pivot_engaged = true
		_pivot_sense = PivotRules.latch_sense(abs_psi, band_lo, band_hi)
	# The blend eases toward authority earned three ways, never a latched 1 —
	# because this cursor also stickhandles and aims, and the blend gates the
	# STRIDE (gait_scale + phase rate), so spurious authority reads as the
	# legs stuttering mid-stride, not just a hip nudge:
	# depth — a flick clipping the band's shallow edge gets only a light lag;
	# dwell — a flick RETURNS inside ~150 ms while a pivot PARKS ψ across the
	# body, so full authority needs pivot_commit_time of continuous residence
	# (a real skater takes about that long to commit the hips anyway);
	# no carve — leading the cursor through a hard turn can carry ψ deep, but
	# blades committed to carving edges cannot pivot, so real path curvature
	# vetoes (the same smoothed curvature signal the crossover cadence uses).
	var pivot_target_blend: float = 0.0
	if _pivot_engaged:
		_pivot_dwell += delta
		pivot_target_blend = PivotRules.hold_depth(abs_psi, band_lo,
				deg_to_rad(_controller.pivot_depth_ramp_deg)) \
				* clampf(_pivot_dwell / maxf(_controller.pivot_commit_time, 0.001), 0.0, 1.0) \
				* (1.0 - clampf(absf(_carve_curve), 0.0, 1.0))
	else:
		_pivot_dwell = 0.0
	_pivot_blend = lerpf(_pivot_blend, pivot_target_blend,
			_controller.pivot_blend_speed * delta)
	pivot_hold = _pivot_blend
	var align_speed: float = _controller.hip_align_speed
	var pivot_yaw_l: float = 0.0
	var pivot_yaw_r: float = 0.0
	if _pivot_blend > 0.001:
		var pivot_p: float = PivotRules.phase(abs_psi, _pivot_sense, band_lo, band_hi)
		var pivot_target: float = PivotRules.pivot_yaw(_psi_smooth, _pivot_sense, pivot_p,
				_controller.pivot_step_begin)
		# Mohawk V — the replay-camera read: the LEAD skate externally rotates
		# toward the step direction while the trail skate holds the old line,
		# heel-to-heel through the middle of the transit. A half-sine of the
		# phase opens the V out of the entry and closes it into the step; the
		# yaw lands on the hip pivot so the shin and boot carry it. The lead
		# is the leg on the side the hips will rotate toward (positive
		# lower-body yaw turns the legs toward −X → left leads).
		var v_open: float = deg_to_rad(_controller.pivot_mohawk_deg) * _pivot_blend \
				* sin(PI * pivot_p)
		var step_sign: float = signf(_psi_smooth) * _pivot_sense
		if step_sign > 0.0:
			pivot_yaw_l = v_open
		elif step_sign < 0.0:
			pivot_yaw_r = -v_open
		# The pivot target overrides the intent suppression above on purpose: a
		# key held through the swing flips to a backpedal read mid-transit,
		# which must not zero the hold.
		align_target = lerpf(align_target, pivot_target, _pivot_blend)
		align_speed = lerpf(align_speed, _controller.pivot_yaw_speed, _pivot_blend)
	_hip_align_yaw = lerpf(_hip_align_yaw, align_target, align_speed * delta)
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
	# At a near-standstill velocity can't vote on the gait blend (fb_w
	# defaults to 1), so lateral INTENT biases the mix toward the scissor
	# gait the side-step needs.
	if absf(_shuffle) > 0.001:
		lr_w = maxf(lr_w, absf(_shuffle))
		fb_w = 1.0 - lr_w

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
	# Sprint sits DOWN into the burst — same rationale as the push_scale gain
	# above: the effort deepening fades once the sprint tops out, but a
	# sprinting skater stays low the whole way.
	stance *= 1.0 + _sprint * _controller.sprint_stance_gain
	# Cadence gear: a skater cruising at max velocity sits into a deeper glide
	# (joint angles shift from extended toward deeper as frequency drops).
	stance *= 1.0 + _controller.cadence_glide_stance_gain * cruise_gear
	# Faceoff ready stance: at the dot the skater is at a standstill, so the
	# speed-driven envelope leaves them bolt upright — floor the engagement
	# through the countdown instead. Eased both ways: the crouch settles in
	# over the prep and releases into the draw as the players explode out.
	# The two centres sit far deeper than the players behind them.
	faceoff_blend = lerpf(faceoff_blend,
			1.0 if _controller.is_faceoff_ready() else 0.0,
			_controller.stride_intensity_speed * delta)
	if faceoff_blend > 0.001:
		stance = maxf(stance, _faceoff_stance_floor() * faceoff_blend)
	# Hockey stop sits DEEP — the edges only bite under bent knees.
	if _stop_blend > 0.001:
		stance = maxf(stance, _controller.hockey_stop_stance * _stop_blend)
	# Gliding (no movement keys) keeps working knees at speed — the intensity
	# gate zeroed the stride, but a coasting skater still rides bent edges.
	if not has_move_intent:
		stance = maxf(stance, _controller.glide_stance * speed_t)
	# Dig-in and the reversal plant both sit DOWN — the power position for the
	# first strides, and the edges only kill momentum under bent knees.
	stance = maxf(stance, _controller.dig_in_stance * _dig)
	stance = maxf(stance, _controller.reversal_stance * rev_amt)
	# A committed carve sits DOWN — the edges hold a fast arc only under bent
	# knees, and the lowered center of mass is what lets the body bank into it.
	stance = maxf(stance, _controller.carve_stance * absf(_carve))
	# The pivot sits too: the open-hip glide and the step-around are both done
	# on bent knees.
	stance = maxf(stance, _controller.pivot_stance * _pivot_blend)
	# Shot loads sit INTO the shot as the charge builds (the slapper wind-up
	# deepest — the power position), and the release keeps the front leg seated
	# through the drive (the back knee is pulled out of this flex by the kick
	# extension below — that asymmetry IS the weight transfer read).
	stance = maxf(stance, _controller.wrister_load_stance * _wrister_load)
	stance = maxf(stance, _controller.slapper_load_stance * _slap_load)
	var kick_stance: float = _controller.slapper_kick_stance if _shot_kick_is_slap \
			else _controller.wrister_kick_stance
	stance = maxf(stance, kick_stance * kick_env)
	# A landed check drives with the LEGS — the finishing base under the
	# shoulder — and a stick lift works from a light coil.
	stance = maxf(stance, _controller.check_drive_stance * drive_env)
	stance = maxf(stance, _controller.stick_lift_stance * _lift_blend)
	# Celebration bounce: knee pumps between straight and seated (the body
	# drop follows, so it reads as a hop bob) — 3 pumps across the window,
	# double the raised-stick pose's bob rate. Gated to plain skating like the
	# pose (SkaterController's celebration block) so it never fights a
	# follow-through kick, and ramped in over the same first 20%.
	if celebr_p > 0.0 and (shot_state == State.SKATING_WITH_PUCK
			or shot_state == State.SKATING_WITHOUT_PUCK):
		var cel_ramp: float = clampf(celebr_p / 0.2, 0.0, 1.0)
		cel_ramp = cel_ramp * cel_ramp * (3.0 - 2.0 * cel_ramp)
		var pump: float = 0.5 - 0.5 * cos(celebr_p * TAU * 3.0)
		stance = maxf(stance, _controller.celebration_leg_stance * cel_ramp * pump)
	var stance_hip: float = deg_to_rad(_controller.stance_hip_deg) * stance
	var stance_knee: float = stance_hip + asin(
			clampf(_THIGH_LEN / _SHIN_LEN * sin(stance_hip), -1.0, 1.0))
	var stance_shin: float = stance_knee - stance_hip
	var drop: float = leg_scale * (_THIGH_LEN * (1.0 - cos(stance_hip)) \
			+ _SHIN_LEN * (1.0 - cos(stance_shin)))

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
	# Cadence gear also warps the stroke: at sustained cruise the push compresses
	# and the glide/recovery stretches (the 80/20 glide-to-propulsion split of a
	# top-speed stride) by adding to the stroke skew. Flows through s/s_opp/c/c_opp
	# and their (1 + skew) derivative normalization below automatically; clamped
	# under 1 so the warp stays well-defined.
	var skew: float = clampf(
			_controller.stride_skew + _controller.glide_hold_skew * cruise_gear, 0.0, 0.95)
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

	# Faceoff stance: the stick-side foot drops back, braced for the draw, and
	# the centre splays both legs into the wide base he sets over the dot — a sit
	# this deep over feet at hip width is a squat, not an address. The splay
	# rotates the whole leg chain, so its vertical span is span·cos(splay) and the
	# body pays the deficit as extra drop; without it the skates ride up off the
	# ice. The ankles give the whole chain back below (foot_flat_*) so the blades
	# still lie flat — the shot block's argument, at a gentler angle.
	var faceoff_splay: float = 0.0
	var faceoff_flat: float = 0.0
	if faceoff_blend > 0.001:
		var split: float = deg_to_rad(_faceoff_split_deg()) * faceoff_blend \
				* (-1.0 if _skater.is_left_handed else 1.0)
		l_pitch += split
		r_pitch -= split
		if _skater.is_faceoff_center:
			faceoff_splay = deg_to_rad(_controller.faceoff_center_width_deg) \
					* faceoff_blend
			l_roll -= faceoff_splay
			r_roll += faceoff_splay
			drop += (leg_scale * (_THIGH_LEN + _SHIN_LEN) - drop) \
					* (1.0 - cos(faceoff_splay))
			# A sit this deep, over a base this wide, would stand both blades on
			# their heels and outside edges; the ankles give it back (an address
			# is held on flat blades, and a real ankle has the range for it).
			faceoff_flat = faceoff_blend
			# Which changes what the drop above owes. A skate left to tilt with
			# its shin keeps its SOLE planted, and that is the crouch's model; a
			# level one hangs its blade below the FOOT pivot instead, and that
			# pivot swings down as the shin folds (_FOOT_FWD), so the hip rides
			# the same amount higher. The shot block's own solve pays it too.
			drop -= leg_scale * _FOOT_FWD * sin(stance_shin) * faceoff_blend

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

	# Reversal plant: fighting to go the other way plants both legs in a wide
	# outward V while the stride is suppressed (gait_scale) — edges killing
	# momentum, knees down (stance floor above), trunk tipped back (trunk add
	# below) until the velocity flips and the dig-in takes over the restart.
	if rev_amt > 0.001:
		var plant: float = deg_to_rad(_controller.reversal_plant_deg) * rev_amt
		l_roll -= plant
		r_roll += plant

	# Shot stance. Load: the shooting base — stick-side foot staggers back and
	# both legs roll toward it, settling the weight over the back leg while the
	# charge builds (same shared-roll idiom as the strafe lean: a common roll
	# rides the body over that side's leg); wrister and slapper loads sum, but
	# their charge states are exclusive so only the decay tails ever overlap.
	# Release: the roll flips to land the weight over the FRONT foot while the
	# back leg drives into extension behind — the kick pitch here; the knee
	# straighten below frees the shin into it.
	var shot_load_split_deg: float = _controller.wrister_load_split_deg * _wrister_load \
			+ _controller.slapper_load_split_deg * _slap_load
	var shot_load_lean_deg: float = _controller.wrister_load_lean_deg * _wrister_load \
			+ _controller.slapper_load_lean_deg * _slap_load
	if shot_load_split_deg > 0.001 or shot_load_lean_deg > 0.001:
		var load_split: float = deg_to_rad(shot_load_split_deg) * stick_side
		l_pitch += load_split
		r_pitch -= load_split
		var load_lean: float = deg_to_rad(shot_load_lean_deg) * stick_side
		l_roll += load_lean
		r_roll += load_lean
	if kick_env > 0.001:
		var kick_lean_deg: float = _controller.slapper_kick_lean_deg if _shot_kick_is_slap \
				else _controller.wrister_kick_lean_deg
		var kick_lean: float = deg_to_rad(kick_lean_deg) * kick_env * stick_side
		l_roll -= kick_lean
		r_roll -= kick_lean
		var kick_back_deg: float = _controller.slapper_kick_back_deg if _shot_kick_is_slap \
				else _controller.wrister_kick_back_deg
		var kick_back: float = deg_to_rad(kick_back_deg) * kick_env
		if stick_side > 0.0:
			r_pitch -= kick_back
		else:
			l_pitch -= kick_back

	# Forward / backward gait. Shared side-to-side roll rocks the lower body onto
	# alternating edges (each leg pivots about its own hip, so the same roll
	# extends the outer leg while the inner one tucks under — the skating weight
	# shift). Alternating fore/aft pitch makes it a push. Backward skating reaches
	# the legs forward to pull through C-cuts, so the push flips sign and uses a
	# shallower amplitude.
	var push_deg: float = _controller.stride_pitch_deg if fwd >= 0.0 else _controller.stride_back_pitch_deg
	var push_dir: float = 1.0 if fwd >= 0.0 else -1.0
	# Deliberate backpedal (intent behind the facing) widens the edge rock
	# into real C-cuts — the legs sweep out-and-in while the chest stays up
	# (trunk add below). Faded in over the first m/s of backward travel so
	# the read never pops on the fwd sign flip.
	var ccut: float = _backpedal * clampf(-fwd, 0.0, 1.0)
	roll_amp += deg_to_rad(_controller.backpedal_ccut_roll_deg) * ccut * _intensity * gait_scale
	# A hard carve IS the stride — the fore/aft push bleeds out as the
	# crossover gait takes over (carve_stride_fade), instead of striding
	# straight ahead while the legs cross. The dig-in chop shortens the push
	# the same way: quick feet out of the start, not full extensions. The
	# backpedal fades it too: a C-cut's push is the lateral sweep (the widened
	# abduction below), so the fore/aft pump shrinks toward a residual reach
	# instead of pumping like a mirrored forward stride.
	var push_amp: float = deg_to_rad(push_deg) * _intensity * push_dir * push_scale * gait_scale \
			* (1.0 - absf(_carve) * _controller.carve_stride_fade) \
			* (1.0 - _dig * _controller.dig_in_chop) \
			* (1.0 - ccut * _controller.backpedal_pitch_fade)
	# Rear-bias the pitch stroke so the stride pushes BACK instead of kicking
	# forward: a CONSTANT offset shifts the whole swing rearward — the back
	# extension reaches (1+bias)·amp while the recovery lands only
	# (1−bias)·amp ahead, so the returning skate settles under the hips the
	# way a real stride does. A constant is load-bearing: never make the bias a
	# warp of the phase (s − bias·s²) — same endpoints, but it speeds the stroke
	# across the rear half in BOTH directions, so the leg snaps forward out of
	# the push as hard as it drove in and reads as a quick FORWARD kick. An
	# offset has zero effect on timing, leaving the stroke speed purely to
	# stride_skew (fast backswing, gentle return). Pitch channel
	# only; the edge-rock roll and the abduction gate keep the symmetric
	# wave. For the backward gait push_amp is negated, which flips the bias
	# toward the forward reach — the C-cut's long pull happens out front,
	# which is also correct.
	var bias: float = _controller.stride_rear_bias
	l_pitch += fb_w * (s - bias) * push_amp
	r_pitch += fb_w * (s_opp - bias) * push_amp
	# A committed carve HOLDS its lean — fade the shared edge rock, the V-flare
	# abduction, and the strafe scissor as the crossover overlay takes over
	# their roll channels — without the fade all three write against the
	# overlay's fixed-role over/under rolls at partial blends, which reads as
	# leg flail at odd travel angles. Forward-gated like the overlay itself.
	var rock_fade: float = 1.0 - absf(_carve) * carve_fwd_gate * _controller.carve_rock_fade
	l_roll += fb_w * s * roll_amp * rock_fade
	r_roll += fb_w * s * roll_amp * rock_fade

	# Abduction: the extending leg flares OUT to the side as it drives back —
	# the V-shaped hockey push — half-wave rectified (max(-s, 0) is that leg's
	# back-extension) so only the push half of each cycle flares while the
	# recovery returns under the body. Left leg flares toward -X: negative roll.
	# The backpedal widens this into the C-cut's defining stroke: each leg
	# alternately sweeps out and pulls back in while the other glides.
	var l_ext: float = maxf(-s, 0.0)
	var r_ext: float = maxf(-s_opp, 0.0)
	var abduct_amp: float = deg_to_rad(_controller.stride_abduction_deg
			+ _controller.backpedal_ccut_sweep_deg * ccut) * _intensity * push_scale * gait_scale
	l_roll -= fb_w * abduct_amp * l_ext * rock_fade
	r_roll += fb_w * abduct_amp * r_ext * rock_fade

	# Strafe scissor. Lean into the travel direction (static bias toward the
	# inside) plus a scissoring roll 180° out of phase between the legs. This
	# is the AIM-LOCKED lateral shuffle — genuine crossovers (turning at
	# speed) are the carve block below, keyed off path curvature instead of
	# hip-frame lateral velocity (which hip alignment mostly removes anyway).
	# Lean sign: velocity votes when there's meaningful travel; a standstill
	# side-step leans by INTENT instead (lat is noise at near-zero speed).
	var strafe_sign: float = signf(_shuffle) if absf(_shuffle) > 0.3 else signf(lat)
	var lean: float = strafe_sign * deg_to_rad(_controller.crossover_lean_deg) * _intensity * gait_scale
	var scissor: float = deg_to_rad(_controller.crossover_scissor_deg) * _intensity * push_scale * gait_scale
	# rock_fade: on diagonal travel the residual lr_w would double-fire the
	# scissor against the carve overlay — turning at speed, the crossovers win.
	l_roll += lr_w * (lean + s * scissor) * rock_fade
	r_roll += lr_w * (lean + s_opp * scissor) * rock_fade

	# ── Carve crossovers ──────────────────────────────────────────────────────
	# Turning at speed plays real crossovers, with FIXED roles set by the turn
	# direction (they never alternate): the OUTSIDE leg lifts and steps across
	# in front while the INSIDE leg extends in an under-push beneath the body.
	# TWO-BEAT rhythm — the strokes alternate halves of the shared stride
	# phase (over-step on the positive half, under-push on the negative half),
	# the continuous push-push that runs a skater around a corner, instead of
	# both firing simultaneously with an idle half between. On top of the
	# alternating strokes both legs HOLD a static lean into the turn
	# (carve_base_lean_deg) so the turn read never pulses to zero between
	# steps. The clearance knee rides the RISE of the stroke (same derivative
	# gate as the recovery tuck) so the crossing skate lifts OVER the planted
	# leg and extends as it lands; the under-push leg feeds the existing
	# knee-release path through its ext value, so the extension stays
	# anatomically consistent with the stance geometry. Forward-gated
	# (carve_fwd_gate): a backward turn keeps its C-cuts and edges — forward
	# crossover roles mirror wrong when travel flips.
	var l_tuck_extra: float = 0.0
	var r_tuck_extra: float = 0.0
	var carve_amt: float = absf(_carve) * _intensity * gait_scale * carve_fwd_gate
	if carve_amt > 0.001:
		var over_stroke: float = maxf(s, 0.0)
		var under_stroke: float = maxf(-s, 0.0)
		var base_lean: float = deg_to_rad(_controller.carve_base_lean_deg) \
				* signf(_carve) * carve_amt
		l_roll += base_lean
		r_roll += base_lean
		var over_roll: float = deg_to_rad(_controller.carve_over_roll_deg) * carve_amt * over_stroke
		var under_roll: float = deg_to_rad(_controller.carve_under_roll_deg) * carve_amt * under_stroke
		var over_pitch: float = deg_to_rad(_controller.carve_over_pitch_deg) * carve_amt * over_stroke
		var clearance: float = deg_to_rad(_controller.carve_clearance_knee_deg) \
				* carve_amt * maxf(c, 0.0)
		if _carve > 0.0:
			# Turning toward +X: left leg crosses over, right leg under-pushes.
			l_roll += over_roll
			l_pitch += over_pitch
			l_tuck_extra = clearance
			r_roll -= under_roll
			r_ext = maxf(r_ext, under_stroke)
		else:
			# Turning toward −X: mirrored roles.
			r_roll -= over_roll
			r_pitch += over_pitch
			r_tuck_extra = clearance
			l_roll += under_roll
			l_ext = maxf(l_ext, under_stroke)

	# ── Glide reads ────────────────────────────────────────────────────────────
	# Releasing the keys mid-turn glides OUT of the carve on the edges: while
	# the smoothed carve decays, both legs hold a static lean into the arc and
	# the INSIDE knee tucks light — weight on the outside leg, the one-foot-
	# glide read — instead of pumping crossovers (the stroke gaits above are
	# intensity-gated to zero without intent, so this replaces, not stacks).
	var glide_amt: float = _glide * speed_t * gait_scale
	if glide_amt > 0.001 and absf(_carve) > 0.001:
		var glide_lean: float = deg_to_rad(_controller.glide_carve_lean_deg) * _carve * glide_amt
		l_roll += glide_lean
		r_roll += glide_lean
		var inside_tuck: float = deg_to_rad(_controller.glide_inside_tuck_deg) \
				* absf(_carve) * glide_amt
		if _carve > 0.0:
			r_tuck_extra += inside_tuck
		else:
			l_tuck_extra += inside_tuck

	# Knee flex — three layers that read as one leg working. (1) The stance flex,
	# the seated base both knees carry. (2) Push extension: the loaded leg
	# straightens as it extends back (stance_knee_release of the stance flex gone
	# at full extension) — the power stroke. (3) Recovery tuck: the unloaded leg
	# folds as it swings back under the body (direction-gated on `c`, not
	# position, so the tuck rides the return swing and not the push-out through
	# the same spot). Negative folds the shin back under the body.
	# The backpedal fades the tuck out: a C-cut keeps both blades ON the ice for
	# the whole cycle — the sweeping leg extends and re-flexes through the
	# stance/release channel, it never lifts under the body like a forward
	# recovery.
	var tuck_amp: float = deg_to_rad(_controller.stride_knee_deg) * _intensity * push_scale \
			* gait_scale * (1.0 - _controller.backpedal_tuck_fade * ccut)
	# The release is stride work, so it rides the stride intensity envelope
	# like every other stroke channel (tuck/push/roll already do via their
	# amps). Ungated, the phase — which advances with SPEED, not intent —
	# kept pumping the knees at full amplitude through a no-keys glide.
	var release: float = _controller.stance_knee_release * _intensity * gait_scale
	var l_knee: float = -(stance_knee * (1.0 - release * l_ext) + tuck_amp * maxf(c, 0.0) + l_tuck_extra)
	var r_knee: float = -(stance_knee * (1.0 - release * r_ext) + tuck_amp * maxf(c_opp, 0.0) + r_tuck_extra)

	# Shot release: the back (stick-side) knee straightens through the kick —
	# extension toward 0, never past straight — while the front knee keeps the
	# full stance flex (the kick_stance floor above). Applied before the
	# fore-aft compensation so the freed shin carries into the kick's rearward
	# reach, same anatomical bookkeeping as the stride's knee layers.
	if kick_env > 0.001:
		var kick_extend_deg: float = _controller.slapper_kick_knee_extend_deg \
				if _shot_kick_is_slap else _controller.wrister_kick_knee_extend_deg
		var kick_extend: float = deg_to_rad(kick_extend_deg) * kick_env
		if stick_side > 0.0:
			r_knee = minf(r_knee + kick_extend, 0.0)
		else:
			l_knee = minf(l_knee + kick_extend, 0.0)

	# ── Knee fore-aft compensation ────────────────────────────────────────────
	# The dynamic knee layers (push extension, recovery tuck, carve clearance)
	# exist for LIFT and leg-length texture, but each also drags the FOOT
	# fore-aft: uncompensated, unfolding mid-push shoves the skate forward
	# against the thigh's backward sweep and the tuck's release adds to the
	# forward swing, so measured AT THE SKATE the stride's fast phase comes out
	# FORWARD (recovery) — the inverse of a real push (test_gait_stroke_profile
	# pins the corrected profile). Counter-pitch the thigh by the small-angle
	# FK term (Δpitch = −Δknee · L_shin / L_leg) so the foot tracks the
	# thigh-design curve — slow recovery, fast push — while the knee keeps its
	# full fold/extend range and vertical travel. Anatomically this reads
	# right: a folded shin needs more hip flex for the same skate position,
	# and the compensated full extension sits the knee joint farther back.
	var shin_frac: float = _SHIN_LEN / (_THIGH_LEN + _SHIN_LEN)
	l_pitch += -(l_knee + stance_knee) * shin_frac
	r_pitch += -(r_knee + stance_knee) * shin_frac

	# Body bob: the body rides highest at full extension (|s| = 1) and sits
	# deepest mid-transfer (s = 0) — a subtle vertical pulse at twice the leg
	# cadence that sells the weight moving from skate to skate.
	drop += _controller.stride_bob_m * _intensity * (1.0 - s * s) * gait_scale

	# Trunk texture, consumed by SkaterPoseCoordinator's next lean application:
	# effort digs the shoulders forward when driving (and tips them back on a
	# hard brake), and the torso rolls over the loaded leg with the weight shift.
	# Both roll channels sample the stride FUNDAMENTAL (the unwarped sine), not
	# the skewed stroke waveform `s`: stride_skew models the leg's fast-release
	# snap, but the trunk is the body's most massive segment and its weight
	# transfers over the gliding leg smoothly — riding `s` puts the stroke's snap
	# harmonics on the torso, which reads as trunk jitter at cruise (where the
	# glide_hold_skew warp is deepest). The legs keep the skew.
	var s_fund: float = sin(stride_phase)
	trunk_pitch_add = -deg_to_rad(_controller.stride_dig_lean_deg) * _effort
	trunk_roll_add = deg_to_rad(_controller.stride_sway_deg) * _intensity * fb_w * s_fund * gait_scale
	# Spring weight transfer (Rosen-style secondary motion): a damped spring lags
	# the lateral weight shift behind the stride so the body settles OVER the
	# loaded leg with follow-through instead of the roll tracking the leg rigidly.
	# Semi-implicit Euler (update velocity, then position) for stability; local
	# integrator state, advanced only on real ticks like the rest of the gait.
	var shift_target: float = fb_w * s_fund * _intensity * gait_scale
	var shift_accel: float = _controller.weight_spring_stiffness * (shift_target - _weight_shift) \
			- _controller.weight_spring_damping * _weight_shift_vel
	_weight_shift_vel += shift_accel * delta
	_weight_shift += _weight_shift_vel * delta
	trunk_roll_add += deg_to_rad(_controller.weight_shift_deg) * _weight_shift
	# Intent trunk reads: dig-in drives the shoulders over the first strides,
	# a reversal tips them BACK against the travel it's fighting, and a
	# deliberate backpedal keeps the chest up over the C-cuts.
	trunk_pitch_add += -deg_to_rad(_controller.dig_in_lean_deg) * _dig \
			+ deg_to_rad(_controller.reversal_lean_deg) * rev_amt \
			+ deg_to_rad(_controller.backpedal_chest_deg) * ccut
	# Sprint drives the shoulders forward for the whole burst (the effort dig
	# above fades once the sprint tops out). gait_scale keeps it from fighting
	# the hockey-stop / reversal trunk reads on their shared channel.
	trunk_pitch_add += -deg_to_rad(_controller.sprint_lean_deg) * _sprint * gait_scale
	# Check-delivery drive: the trunk drives INTO the hit — the shoulder
	# finishing through the contact. Same directional decomposition as the
	# reach lean (pitch = mag·local.z folds toward local −Z, roll = −mag·local.x),
	# re-derived body-local each tick so the lean stays on the victim line
	# while the body carries through.
	if drive_env > 0.0:
		var drive_local: Vector3 = basis_inv * _drive_dir
		var drive_mag: float = deg_to_rad(_controller.check_drive_lean_deg) * drive_env
		trunk_pitch_add += drive_mag * drive_local.z
		trunk_roll_add += -drive_mag * drive_local.x
	# Stick lift: a slight chest-up pop while jabbing under the opponent's
	# stick (positive pitch tips the shoulders back).
	trunk_pitch_add += deg_to_rad(_controller.stick_lift_trunk_deg) * _lift_blend
	# Glide sway: a coasting skater shifts weight lazily edge-to-edge — a slow
	# roll (trunk plus a touch of shared leg roll) far below stride cadence.
	# The phase is local-only; at ~2° amplitude machines needn't agree on it.
	if _glide > 0.01:
		_glide_phase = wrapf(_glide_phase
				+ TAU * _controller.glide_sway_hz * _glide * delta, 0.0, TAU)
	if glide_amt > 0.001:
		var sway: float = sin(_glide_phase) * deg_to_rad(_controller.glide_sway_deg) * glide_amt
		trunk_roll_add += sway
		l_roll += sway * 0.5
		r_roll += sway * 0.5
	# Hockey stop: the trunk banks over the skid (the dig-lean above already
	# tips the shoulders back against the braking effort).
	if _stop_blend > 0.001:
		trunk_roll_add += deg_to_rad(_controller.hockey_stop_trunk_roll_deg) \
				* _stop_blend * _stop_side
	# Centripetal bank — the trunk inclines toward the arc's center like a
	# banking bicycle. The balancing inclination is atan(a_lat/g) with
	# a_lat = v·ω, both from signals already smoothed above (ground speed, the
	# turn rate), so remotes and replay derive the identical bank for free.
	# Decomposed body-local exactly like the check-drive lean (pitch = mag·dir.z,
	# roll = −mag·dir.x): the center sits 90° from travel in the turn sense, so
	# the bank stays correct at any facing-vs-travel angle, forward or backward.
	# The gain leaves the rest of the physical angle to the legs' carve lean;
	# the stop fade hands the channel to the hockey stop's authored bank.
	if ground_speed > 0.1:
		var a_lat: float = ground_speed * absf(_turn_rate)
		# Soft knee on the centripetal accel: the balancing bank's slope near
		# zero is v/g rad per rad/s — steep enough that residual turn-rate
		# noise from ordinary steering corrections read back as a trunk
		# shimmer while cruising. A real trunk ignores micro-curvature (the
		# transient is absorbed at the hips and ankles — the leg roll) and
		# banks only for a sustained arc, so gate by a rational sigmoid in
		# a_lat: dead at noise level, full by a genuine turn's several m/s².
		var knee: float = maxf(_controller.carve_bank_knee_accel, 0.001)
		var bank_engage: float = a_lat * a_lat / (a_lat * a_lat + knee * knee)
		var bank_mag: float = minf(
				atan2(a_lat, 9.8) * _controller.carve_bank_gain,
				deg_to_rad(_controller.carve_bank_max_deg)) * bank_engage * (1.0 - _stop_blend)
		var centri_x: float = signf(_turn_rate) * -local_vel.z / ground_speed
		var centri_z: float = signf(_turn_rate) * local_vel.x / ground_speed
		trunk_pitch_add += bank_mag * centri_z
		trunk_roll_add += -bank_mag * centri_x

	# Knockdown pose factor: holds full while more than knockdown_getup_seconds
	# remains on the timer, then eases to 0 over that tail (the get-up). Derived FROM
	# the replicated knockdown_timer, so it renders identically everywhere and through
	# reconcile — same discipline as the stagger stumble below. The entry end is
	# ramped over the buckle window (KnockdownFallRules.entry_ramp — kd_t alone
	# is 1 on the first down frame, landing the whole crumple in one frame);
	# the smoothstep is inlined here because the native port mirrors this body.
	var kd_t: float = clampf(
			_controller.knockdown_timer / maxf(_controller.knockdown_getup_seconds, 0.001), 0.0, 1.0)
	if kd_t > 0.0:
		var buckle_t: float = clampf(_controller.knockdown_elapsed()
				/ maxf(_controller.knockdown_fall_buckle_seconds, 0.001), 0.0, 1.0)
		kd_t *= buckle_t * buckle_t * (3.0 - 2.0 * buckle_t)

	# Stagger stumble: a checked player visibly fights for balance. The wobble
	# phase is derived FROM stagger_timer (a uniform countdown), so every
	# machine — and reconcile replay, which snaps the timer from the host —
	# renders the identical stumble with zero new network state. Amplitude
	# tracks the time left, so the wobble eases out with the recovery window;
	# the two axes run at incommensurate frequencies so it reads as a stumble,
	# not a metronome. It is kept OUT of the summed texture and added after the
	# inertia filter at the publish tail — a stumble is supposed to shake, and
	# the filter would blunt exactly the frequencies that sell it.
	var stagger_pitch: float = 0.0
	var stagger_roll: float = 0.0
	var stagger_t: float = clampf(
			_controller.stagger_timer / maxf(_controller.stagger_max_seconds, 0.001), 0.0, 1.0)
	if stagger_t > 0.0:
		# Knockdown supersedes the stumble — fade the wobble out as the player goes down.
		var wobble_amp: float = deg_to_rad(_controller.stagger_wobble_deg) * stagger_t * (1.0 - kd_t)
		var wobble_phase: float = _controller.stagger_timer * TAU * _controller.stagger_wobble_hz
		stagger_pitch = wobble_amp * sin(wobble_phase)
		stagger_roll = wobble_amp * 0.7 * sin(wobble_phase * 1.31)

	# How much of each leg's splay and fold its ankle gives back, so the blade
	# under it lies flat on the ice (SkaterLegRig.set_ankle_flatten). Seeded by
	# the faceoff address; the block overwrites both when it takes the legs (the
	# two poses never overlap — the whistle stands a blocker up).
	var foot_flat_l: float = faceoff_flat
	var foot_flat_r: float = faceoff_flat

	# ── Shot block: the one-knee drop ─────────────────────────────────────────
	# The block a real skater plays. The STICK-SIDE knee sinks toward the ice
	# with the shin folded back along it; the far leg extends out to the other
	# side, shin low and skate on the ice. Body and stick then seal opposite
	# halves of the lane — the blade lies flat on the stick side
	# (SkaterShotPoseCoordinator.apply_block_blade_position), the extended pad
	# covers the other, which is why the block's reach is wider than the torso.
	#
	# Geometry, not authored numbers: the kneeling hip height falls out of the
	# down leg's thigh/shin angles AND the boot's forward offset under them
	# (_FOOT_FWD), and the extended leg's abduction is SOLVED from that same
	# height (its vertical span is exactly leg·cos(roll), since the knee folds in
	# the rolled leg's own sagittal plane) so its skate lands on the ice instead
	# of floating above it or scissoring through it.
	#
	# The pose REPLACES the stance rather than layering on it — lerped on
	# _block_blend like the knockdown crumple below, which supersedes it (a
	# blocker who gets run over goes down, he doesn't hold the knee).
	if _block_blend > 0.001:
		var kneel_hip: float = deg_to_rad(_controller.block_kneel_hip_deg)
		var kneel_shin: float = deg_to_rad(_controller.block_kneel_shin_deg)
		var hip_h: float = leg_scale * (_THIGH_LEN * cos(kneel_hip)
				+ _SHIN_LEN * cos(kneel_shin) + _FOOT_FWD * sin(kneel_shin))
		var ext_knee: float = deg_to_rad(_controller.block_extend_knee_deg)
		var ext_len: float = leg_scale * (_THIGH_LEN
				+ _SHIN_LEN * cos(ext_knee) + _FOOT_FWD * sin(ext_knee))
		var ext_roll: float = acos(clampf(hip_h / maxf(ext_len, 0.001), -1.0, 1.0))
		# Knee value is the total fold (hip + shin-from-vertical), negative-folds-
		# back, matching the stance_knee convention above. The extended leg rolls
		# AWAY from the body: left toward −X (negative roll), right toward +X.
		var down_knee: float = -(kneel_hip + kneel_shin)
		# The extended leg's ankle gives back what that leg took, so its blade
		# lies flat on the ice instead of swinging up onto an edge under a leg
		# splayed 60° out of vertical. The kneeling leg keeps its fold — that
		# skate is up on its toe by design.
		if stick_side > 0.0:
			foot_flat_l = _block_blend
			foot_flat_r = 0.0
		else:
			foot_flat_r = _block_blend
			foot_flat_l = 0.0
		if stick_side > 0.0:
			r_pitch = lerpf(r_pitch, kneel_hip, _block_blend)
			r_roll = lerpf(r_roll, 0.0, _block_blend)
			r_knee = lerpf(r_knee, down_knee, _block_blend)
			l_pitch = lerpf(l_pitch, 0.0, _block_blend)
			l_roll = lerpf(l_roll, -ext_roll, _block_blend)
			l_knee = lerpf(l_knee, -ext_knee, _block_blend)
		else:
			l_pitch = lerpf(l_pitch, kneel_hip, _block_blend)
			l_roll = lerpf(l_roll, 0.0, _block_blend)
			l_knee = lerpf(l_knee, down_knee, _block_blend)
			r_pitch = lerpf(r_pitch, 0.0, _block_blend)
			r_roll = lerpf(r_roll, ext_roll, _block_blend)
			r_knee = lerpf(r_knee, -ext_knee, _block_blend)
		drop = lerpf(drop, leg_scale * (_THIGH_LEN + _SHIN_LEN) - hip_h, _block_blend)

	# Knockdown crumple: sink the body toward the ice and let the stride swing go
	# limp, blended by kd_t so a downed body doesn't keep pumping strides while it
	# slides. The torso fold is layered in SkaterPoseCoordinator._apply_lean (the
	# recoil channel); here it's the drop + limp legs. Both ease back over the get-up.
	if kd_t > 0.0:
		drop = lerpf(drop, _controller.knockdown_pose_drop_m, kd_t)
		l_pitch = lerpf(l_pitch, 0.0, kd_t)
		r_pitch = lerpf(r_pitch, 0.0, kd_t)
		l_roll = lerpf(l_roll, 0.0, kd_t)
		r_roll = lerpf(r_roll, 0.0, kd_t)
		l_knee = lerpf(l_knee, 0.0, kd_t)
		r_knee = lerpf(r_knee, 0.0, kd_t)

	# Commit stance: holding the Hit button loads the skater up for the check — lean
	# forward into it and sink a touch. Off the replicated skater.hit_committed
	# (renders on remotes), eased at render rate. Suppressed while going down (kd_t)
	# so it can't fight the crumple.
	#
	# The gait owns no shoulder channel here, and must not grow one: the trunk
	# texture is symmetric, so a roll raises the trailing shoulder by exactly what
	# it drops the leading one, which is a skater tipping over rather than one
	# loading up. The per-side geometry lives in CheckStanceRules, eased at physics
	# rate on the skater (Skater._update_commit_stance) — the loaded blade reads it.
	_hit_commit_blend = move_toward(_hit_commit_blend,
			1.0 if _skater.hit_committed else 0.0, _controller.hit_commit_pose_speed * delta)
	var commit_t: float = _hit_commit_blend * (1.0 - kd_t)
	if commit_t > 0.001:
		trunk_pitch_add += -deg_to_rad(_controller.hit_commit_lean_deg) * commit_t
		drop += _controller.hit_commit_crouch_m * commit_t

	# The centre's fold over the dot. It rides the trunk TEXTURE rather than the
	# torso lean the block uses, because the lean rotates the UpperBody node the
	# blade markers hang from: the blade-first IK then has to solve a stick onto
	# the ice out of a pitched frame, and at any fold worth seeing it gives up
	# and stands the shaft on end. The texture is bones only, so the chest reads
	# folded while the stick keeps the address the centre actually took.
	if faceoff_blend > 0.001 and _skater.is_faceoff_center:
		trunk_pitch_add += -deg_to_rad(_controller.faceoff_center_lean_deg) * faceoff_blend

	# The mohawk yaw fades with the crumple like every other leg channel.
	_skater.set_leg_swing(l_pitch, l_roll, l_knee, r_pitch, r_roll, r_knee,
			pivot_yaw_l * (1.0 - kd_t), pivot_yaw_r * (1.0 - kd_t))
	# Publish per-blade edge load for the ice VFX: the push half-wave (which
	# already carries the carve under-stroke) scaled by stride engagement,
	# floored by the stop scrape — and released through the crumple.
	_skater.set_edge_loads(
			clampf(maxf(l_ext * _intensity, _stop_blend), 0.0, 1.0) * (1.0 - kd_t),
			clampf(maxf(r_ext * _intensity, _stop_blend), 0.0, 1.0) * (1.0 - kd_t))
	_skater.set_ankle_flatten(foot_flat_l, foot_flat_r)
	crouch_drop = drop
	_skater.set_skating_crouch_drop(drop)
	# Trunk inertia: filter the summed texture, then layer the stumble wobble
	# back on top (see trunk_texture_smooth_rate).
	var tex_ease: float = 1.0
	if _controller.trunk_texture_smooth_rate > 0.0:
		tex_ease = minf(_controller.trunk_texture_smooth_rate * delta, 1.0)
	_trunk_pitch_s = lerpf(_trunk_pitch_s, trunk_pitch_add, tex_ease)
	_trunk_roll_s = lerpf(_trunk_roll_s, trunk_roll_add, tex_ease)
	trunk_pitch_add = _trunk_pitch_s + stagger_pitch
	trunk_roll_add = _trunk_roll_s + stagger_roll
	_skater.set_trunk_texture(trunk_pitch_add, trunk_roll_add)


# The native path: feed the replicated inputs to NativeSkaterGait, write its
# pose outputs onto the skater, republish the trunk/yaw channels. Behavior is
# pinned to the GDScript body above by tests/unit/rules/test_native_gait_parity.gd.
func _apply_native(delta: float) -> void:
	var flags: int = 0
	if _skater.brake_intent:
		flags |= 1   # FLAG_BRAKE
	if _skater.hit_committed:
		flags |= 2   # FLAG_HIT_COMMITTED
	if _skater.blade_up:
		flags |= 4   # FLAG_BLADE_UP
	if _skater.is_left_handed:
		flags |= 8   # FLAG_LEFT_HANDED
	if _controller.sprint_active:
		flags |= 16  # FLAG_SPRINT
	if _controller.is_faceoff_ready():
		flags |= 32  # FLAG_FACEOFF_READY
	if _skater.is_faceoff_center:
		flags |= 64  # FLAG_FACEOFF_CENTER
	var code: int = _native.apply(delta, _skater.velocity,
			_skater.global_transform.basis, _skater.move_intent,
			_skater.current_shot_state, _skater.shot_charge,
			_controller.stagger_timer, _controller.knockdown_timer,
			_controller.knockdown_elapsed(),
			_controller.celebration_progress(), flags)
	_settled = code != 0
	if code == 2:
		# Settle edge — mirror reset_to_rest's one-time rest-pose write.
		_skater.set_leg_swing(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
		crouch_drop = 0.0
		_skater.set_skating_crouch_drop(0.0)
		_skater.set_trunk_texture(0.0, 0.0)
		_skater.set_edge_loads(0.0, 0.0)
		stride_phase = 0.0
		trunk_pitch_add = 0.0
		trunk_roll_add = 0.0
		stop_yaw_offset = 0.0
		travel_align_yaw = 0.0
		shot_hip_yaw = 0.0
		pivot_hold = 0.0
		return
	if code != 0:
		return
	# Republish the public channels external readers consume (the pose
	# coordinator's yaw sum, stride_phase for tests/tooling) so the coordinator
	# surface stays truthful whichever implementation ran.
	stride_phase = _native.get_stride_phase()
	_skater.set_leg_swing(
			_native.get_l_pitch(), _native.get_l_roll(), _native.get_l_knee(),
			_native.get_r_pitch(), _native.get_r_roll(), _native.get_r_knee(),
			_native.get_l_yaw(), _native.get_r_yaw())
	_skater.set_ankle_flatten(_native.get_foot_flat_l(), _native.get_foot_flat_r())
	_skater.set_edge_loads(_native.get_edge_load_l(), _native.get_edge_load_r())
	crouch_drop = _native.get_crouch_drop()
	faceoff_blend = _native.get_faceoff_blend()
	_skater.set_skating_crouch_drop(crouch_drop)
	trunk_pitch_add = _native.get_trunk_pitch_add()
	trunk_roll_add = _native.get_trunk_roll_add()
	stop_yaw_offset = _native.get_stop_yaw_offset()
	travel_align_yaw = _native.get_travel_align_yaw()
	shot_hip_yaw = _native.get_shot_hip_yaw()
	pivot_hold = _native.get_pivot_blend()
	_skater.set_trunk_texture(trunk_pitch_add, trunk_roll_add)
