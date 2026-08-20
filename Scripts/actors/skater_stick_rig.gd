class_name SkaterStickRig
extends RefCounted

# The rendered stick: the shaft's pose, the knob that caps it, and the cosmetic
# flex that bows it through a shot.
#
# One collaborator because the two halves share `_flex_axis`. `update_mesh`
# solves which way "toward the target" points on the shaft's one available bow
# axis while it is aiming the shaft, and `update_flex` is the only reader — a
# split between them would hand that scalar back and forth across a seam every
# frame.
#
# Everything here is cosmetic and derived: every input is either replicated
# (current_shot_state, shot_charge) or re-read from the marker positions the
# controllers maintain, so local, bot, and remote skaters render the identical
# stick with zero network additions. Nothing gameplay reads comes from this file
# — the blade contact point the claim resolvers clamp against is the Blade
# marker, which this never writes.

# ── Shaft geometry ───────────────────────────────────────────────────────────
# The rendered shaft runs from the top hand to the HOSEL TIP, not the heel.
# The hosel is fixed blade-local geometry ascending in the blade's own
# vertical plane at the lie — but the hand is rarely in that plane (the blade
# yaws with the cursor while the hand stays by the body), so a heel-aimed
# shaft crossed the hosel at an angle over their whole overlap and the
# junction read as a broken elbow. Ending the shaft at the tip makes the
# connection point-exact in every pose; the residual angular mismatch shows
# only as a slight bend at a joint where the two cross-sections nearly match.
# A small overrun keeps the hosel's tip cap buried inside the shaft.
const _SHAFT_TIP_OVERRUN_M: float = 0.03
# The butt end extends past the TOP HAND so the knob rides visibly above the
# fist — a real grip holds the shaft just below the knob, not on top of it.
# Sized so the whole knob clears the glove sphere (hand_sphere_radius 0.06)
# with a finger's width of wrapped shaft showing between fist and knob.
# Public: the workbench preview extends its shaft to match.
const SHAFT_BUTT_EXTEND_M: float = 0.13
# The knob's cap sits slightly proud of the shaft's butt end (wrapped tape).
const _KNOB_PROUD_M: float = 0.01
# Shaft subdivisions the bend shader needs along the length.
const FLEX_SEGMENTS: int = 12

# ── Flex ─────────────────────────────────────────────────────────────────────
const _SLAP_SPIKE_SECONDS: float = 0.1  # contact load time before the whip
# Horizontal fraction of the shaft's bearing over which the bow fades out as the
# shot line swings onto the shaft itself (see _solve_flex_axis).
const _FLEX_AXIS_SPAN: float = 0.3

var _skater: Skater

var _flex: float = 0.0            # smoothed signed load bow (metres)
var _whip_amp: float = 0.0        # release-whip starting amplitude (signed)
var _whip_t: float = -1.0         # seconds since whip start; <0 = idle
var _spike_t: float = -1.0        # seconds into the contact spike; <0 = idle
var _spike_from: float = 0.0      # bow the contact spike ramps FROM (signed)
var _flex_axis: float = 0.0
var _prev_state: int = 0
var _flex_sent: float = 0.0       # last uniform written (dirty guard)
var _shaft_len_sent: float = 0.0  # last shaft_len_m uniform written (dirty guard)


func setup(skater: Skater) -> void:
	_skater = skater
	# The shaft BoxMesh is a scene sub-resource shared by every skater —
	# duplicate it before subdividing (the flex shader needs vertices along the
	# length to bend) so instances don't share the mutation.
	var shaft: BoxMesh = _skater.stick_mesh.mesh as BoxMesh
	if shaft != null:
		shaft = shaft.duplicate() as BoxMesh
		shaft.subdivide_depth = FLEX_SEGMENTS
		_skater.stick_mesh.mesh = shaft


# The uniform pass installs a fresh shaft ShaderMaterial (uniform apply,
# un-ghost); its uniforms are back at defaults, so the dirty guards must
# forget their last-written values or an unchanged flex/length never re-sends.
func notify_material_rebuilt() -> void:
	_shaft_len_sent = 0.0
	_flex_sent = 0.0


# ── Shaft ────────────────────────────────────────────────────────────────────

# `blade_mesh` is the blade's procedural MeshInstance3D, already carrying this
# frame's cosmetic tilt; null until Skater has built it.
func update_mesh(blade_mesh: MeshInstance3D) -> void:
	var stick_mesh: MeshInstance3D = _skater.stick_mesh
	var upper_body: Node3D = _skater.upper_body
	var stick_origin: Vector3 = _skater.top_hand.position
	var to_tip: Vector3 = _hosel_tip_upper_body(blade_mesh) - stick_origin
	if to_tip.length_squared() < 0.0001:
		return
	var dir: Vector3 = to_tip.normalized()
	_flex_axis = _solve_flex_axis(dir)
	var butt_start: Vector3 = stick_origin - dir * SHAFT_BUTT_EXTEND_M
	var shaft_len: float = to_tip.length() + SHAFT_BUTT_EXTEND_M + _SHAFT_TIP_OVERRUN_M
	# Single local write, replacing position + scale.z + look_at (see
	# SkaterArmRig's bone poses for why the trio is expensive). Unlike the arm bones
	# the shaft is NOT rotationally symmetric — the handle-wrap paint reads its
	# faces — so the up vector is carried through exactly rather than replaced by
	# a convenience fallback: world UP pulled into upper-body space reproduces
	# the previous roll, where any other choice would spin the wrap.
	# Z scale is the only component this owns; x/y are the shaft thickness the
	# sizing seams set, so they are read back rather than overwritten.
	var shaft_scale: Vector3 = stick_mesh.scale
	shaft_scale.z = shaft_len
	var up_local: Vector3 = upper_body.global_transform.basis.inverse() * Vector3.UP
	if absf(dir.dot(up_local.normalized())) > 0.999:
		up_local = Vector3.FORWARD
	stick_mesh.transform = Transform3D(
			Basis.looking_at(dir, up_local).scaled_local(shaft_scale),
			butt_start + dir * (shaft_len * 0.5))
	# The handle-wrap paint (grip/candy-cane) measures real metres down the
	# shaft, so the shader needs the live rendered length — node scale never
	# reaches object space. Dirty-guarded like flex_m.
	if not is_equal_approx(shaft_len, _shaft_len_sent):
		_shaft_len_sent = shaft_len
		var shaft_mat: ShaderMaterial = stick_mesh.material_override as ShaderMaterial
		if shaft_mat != null:
			shaft_mat.set_shader_parameter(&"shaft_len_m", _shaft_len_sent)
	_update_knob(stick_origin, to_tip)


# Which way "toward the target" points on the shaft's ONE available bow axis,
# as a signed −1..+1 factor. `shaft_dir` is the butt→tip direction in upper-body
# space, exactly as update_mesh aims the mesh with it.
#
# The shader can only displace along object X, and Basis.looking_at builds that
# axis as up × −dir — the horizontal normal of the blade's face (the same vector
# Skater.get_carry_target_global offsets the puck along). So object X is
# perpendicular to the shaft and rotates with its bearing: as the blade sweeps
# around the player, a FIXED sign points at the net in some poses and behind the
# shooter in others. The drive direction has to be re-projected onto it every
# frame.
#
# The drive is the shot line, and in upper-body space the shot line is FORWARD —
# the torso coils onto it through every wind-up (SkaterPoseCoordinator
# .apply_upper_body) and squares to it through the follow-through. Projecting
# (0, 0, −1) onto the normalized face normal collapses to −shaft_dir.x over the
# shaft's horizontal length, so the whole solve is two multiplies. The residual
# twist cap only scales the magnitude; the SIGN — the thing that reads as
# flexing the wrong way — is right in every pose except one where the shot line
# lies along the shaft, and _FLEX_AXIS_SPAN fades the bow out there anyway.
#
# Reads only the rendered stick pose, which every machine reconstructs from the
# replicated blade/hand markers, so the bow direction agrees across the lobby.
func _solve_flex_axis(shaft_dir: Vector3) -> float:
	var horiz: float = sqrt(shaft_dir.x * shaft_dir.x + shaft_dir.z * shaft_dir.z)
	if horiz < 0.0001:
		return 0.0
	return clampf(-shaft_dir.x / (horiz * _FLEX_AXIS_SPAN), -1.0, 1.0)


# The hosel throat's tip in upper-body space: the fixed blade-local tip (the
# lie axis × hosel length off the heel) carried through the blade mesh's
# cosmetic tilt and the marker's live orientation.
func _hosel_tip_upper_body(blade_mesh: MeshInstance3D) -> Vector3:
	var lie: float = deg_to_rad(_skater.blade_lie_deg)
	var tip_local: Vector3 = Vector3(0.0, sin(lie), cos(lie)) * _skater.blade_hosel_length
	if blade_mesh != null and is_instance_valid(blade_mesh):
		tip_local = blade_mesh.transform * tip_local
	return _skater.blade.transform * tip_local


# Caps the extended butt end with the knob, its long axis (local Y) aligned to
# the shaft — the same looking_at + X(+90°) composition as the glove cuffs.
# `to_shaft_end` is the hand→hosel-tip vector the shaft itself was aimed with,
# so the knob and the shaft always share one axis; the knob wraps the top of the
# butt extension, slightly proud of its end.
func _update_knob(stick_origin: Vector3, to_shaft_end: Vector3) -> void:
	var knob: MeshInstance3D = _skater.stick_knob_mesh
	if knob == null or not is_instance_valid(knob):
		return
	if to_shaft_end.length_squared() < 0.0001:
		return
	# Entirely in upper-body space — every input is already local and to_global
	# is affine, so a world round trip would compute the same direction. The knob
	# is a solid-coloured cylinder, so roll is unobservable and the up vector only
	# has to dodge colinearity, unlike the shaft above.
	var up_shaft: Vector3 = -to_shaft_end.normalized()
	var knob_h: float = SkaterMeshBuilder.KNOB_HEIGHT_M
	var knob_center: Vector3 = stick_origin \
			+ up_shaft * (SHAFT_BUTT_EXTEND_M - knob_h * 0.5 + _KNOB_PROUD_M)
	# Post-multiplied X(+90°) maps the cylinder's long axis onto the aim, which
	# is what rotate_object_local did. Safe to compose directly here because the
	# knob carries no node scale (SkaterUniformCoordinator._rebuild_stick_knob
	# never sets one) — with scale present this is the trap SkaterArmRig's
	# cuff pose documents.
	knob.transform = Transform3D(
			Basis.looking_at(up_shaft, SkaterArmRig.up_for_look_at(up_shaft))
					* Basis(Vector3.RIGHT, PI * 0.5),
			knob_center)


# ── Flex ─────────────────────────────────────────────────────────────────────
# Render-rate driver for the shaft-bow shader uniform. One signed scalar carries
# the whole swing, positive being toward the target (_flex_axis resolves that
# onto the shaft's bow axis), so the shot arc reads as one continuous load:
#
#   wrister aim    the puck pins the blade while the hands press into it, so the
#                  bow leads TOWARD the target and deepens with the charge.
#   slapper wind-up the stick is ripped back and up; the blade's inertia leaves it
#                  behind the hands, so the bow runs the OTHER way — a trailing
#                  load that deepens as the wind-up fills.
#   contact        the blade catches the puck and the hands keep coming. The bow
#                  crosses from the wind-up's trailing load through dead straight
#                  into a full drive-side load — that snap through zero is the
#                  moment the shot reads as leaving.
#   release        a damped cosine from wherever the bow got to; cos starts AT
#                  that value, so the whip is continuous at the release instant.
#
# A one-timer's retention hold IS the contact beat — same crossing, but it HOLDS
# at the apex until the shot actually leaves, straining against the caught puck.
func update_flex(delta: float) -> void:
	var state: int = _skater.current_shot_state
	var axis: float = _flex_axis
	if state != _prev_state:
		if state == SkaterStateMachine.State.ONE_TIMER_RETENTION:
			_start_contact_spike()
		elif state == SkaterStateMachine.State.FOLLOW_THROUGH:
			if _prev_state == SkaterStateMachine.State.ONE_TIMER_RETENTION:
				# Retention already carried the load through contact — release it
				# straight into the whip rather than re-ramping.
				_spike_t = -1.0
				_start_whip(_flex)
			elif _prev_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
					or _prev_state == SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK:
				_start_contact_spike()
			else:
				# Wrister / quick release: whip from the loaded bow, with a
				# minimum pop so uncharged snaps and passes still read.
				var amp: float = _flex
				var min_pop: float = _skater.stick_flex_max_m * 0.35 * axis
				if absf(amp) < absf(min_pop):
					amp = min_pop
				_start_whip(amp)
		_prev_state = state

	var display: float
	if _spike_t >= 0.0:
		# Contact: cross from the wind-up's trailing bow to the drive-side load.
		# The ramp is sized to the follow-through's own downswing (SkaterShot
		# PoseCoordinator.apply_slapper_follow_through), so the crossing lands on
		# the frame the blade reaches the puck and the whip starts there.
		_spike_t += delta
		var apex: float = _skater.stick_flex_slap_m * axis
		if _spike_t < _SLAP_SPIKE_SECONDS:
			_flex = lerpf(_spike_from, apex, _spike_t / _SLAP_SPIKE_SECONDS)
		elif state == SkaterStateMachine.State.ONE_TIMER_RETENTION:
			# Loaded and waiting on the release — hold the bow at the apex. The
			# transition out of retention starts the whip, not this timer, so a
			# retention longer than the ramp reads as a stick straining against a
			# puck it has caught instead of springing early.
			_flex = apex
		else:
			_start_whip(_flex)
			_spike_t = -1.0
		display = _flex
	elif _whip_t >= 0.0:
		_whip_t += delta
		var envelope: float = exp(-_skater.stick_whip_damping * _whip_t)
		display = _whip_amp * envelope * cos(TAU * _skater.stick_whip_hz * _whip_t)
		if absf(_whip_amp) * envelope < 0.002:
			_whip_t = -1.0
			display = 0.0
		_flex = display
	else:
		var target: float = 0.0
		if state == SkaterStateMachine.State.WRISTER_AIM:
			target = _skater.shot_charge * _skater.stick_flex_max_m * axis
		elif state == SkaterStateMachine.State.SLAPPER_CHARGE_WITH_PUCK \
				or state == SkaterStateMachine.State.SLAPPER_CHARGE_WITHOUT_PUCK:
			# Trailing wind-up load, negative because the blade lags the draw-back.
			# sqrt-eased off the replicated charge the way every machine can — the
			# wind-up pose fills over the same timer (SkaterController
			# .slapper_wind_up_t), so shot_charge IS the wind-up progress, and the
			# ease matches the torso coil's front-loaded snap.
			target = -sqrt(clampf(_skater.shot_charge, 0.0, 1.0)) \
					* _skater.stick_flex_windup_m * axis
		_flex = lerpf(_flex, target,
				minf(_skater.stick_flex_load_speed * delta, 1.0))
		display = _flex

	if is_equal_approx(display, _flex_sent):
		return
	_flex_sent = display
	var mat: ShaderMaterial = _skater.stick_mesh.material_override as ShaderMaterial
	if mat != null:
		mat.set_shader_parameter(&"flex_m", display)


# Begins the contact crossing FROM the live bow rather than from straight, so a
# wound-up slapper unloads through zero on its way to the drive-side apex and a
# short wind-up (or a quick-armed one-timer) simply travels less far.
func _start_contact_spike() -> void:
	_spike_t = 0.0
	_spike_from = _flex


func _start_whip(amp: float) -> void:
	_whip_amp = amp
	_whip_t = 0.0
	_flex = amp
