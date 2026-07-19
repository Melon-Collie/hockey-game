class_name Puck
extends RigidBody3D

signal puck_released()
signal puck_stripped(ex_carrier: Skater)
signal puck_touched_loose(skater: Skater)  # blade redirect (deflection, tip-in)
signal puck_body_blocked(skater: Skater)   # puck absorbed by a player's body
signal puck_touched_goalie(goalie: Goalie)  # puck contacted a goalie StaticBody3D part while uncarried
# Controlled save landed on the GLOVE specifically — the catchable contact.
# Host-only (emitted from the host-authoritative rebound resolution); the
# goalie controller answers by pinning the puck in the glove (catch-and-hold).
signal puck_caught_by_goalie(goalie: Goalie)
signal puck_touched_post  # puck contacted any HockeyGoal geometry while uncarried
signal puck_hit_boards     # uncarried puck struck rink boards at meaningful speed
signal puck_hit_goal_body  # uncarried puck struck net panel or skirt (non-pipe goal geometry)

@export var max_speed: float = 38.0
@export var reattach_cooldown: float = 0.5
@export var nudge_cooldown: float = 0.30  # short re-grab denial after a self nudge tap
@export var ice_height: float = 0.0175  # = Puck.tscn cylinder half-height (0.035/2); disc bottom rests on y=0
@export var pickup_max_speed: float = 8.0
# RELATIVE puck-speed threshold for catch-vs-deflect: the puck's speed in the
# RECEIVER'S frame (puck velocity − skater velocity), so a stretch pass to a
# streaking receiver arrives soft while charging into the same pass steepens
# it, and retreating with a hard shot cushions it under the ceiling. Calibrated
# to real reception, not backwards from game pass speeds (rationale + force
# math on PuckReceptionRules.should_receive): 22 ≈ 49 mph closing catches at
# ANY blade angle — every pass-shaped launch (snap 14, AI arrival target 21.5,
# soft-sweep wristers) catches for a static or retreating receiver, and only
# sprinting head-on INTO a hard feed pushes past it. The alignment bonus
# extends the ceiling to 30 m/s (~67 mph closing) for a perfectly squared
# blade — reaching into the shot bands (wrister max 33 base / slapper 40),
# which otherwise always deflect.
@export var deflect_min_speed: float = 22.0
@export var alignment_receive_bonus: float = 8.0
# Passive-blade deflection via a normal/tangential decomposition (see
# PuckCollisionRules.deflect_velocity). The component INTO the blade face rebounds
# with a restitution; the component ALONG the face (a glance) is preserved. From
# one model this yields both real outcomes: a SQUARE hit off a hard puck dies in
# front (a bobble — see bobble_speed_threshold), while a GLANCING hit keeps its
# pace and only bends its line (a true tip/redirect). No angle cap is needed — the
# only way to reverse the puck is a square hit, and a square hard hit is killed by
# the low restitution, so there is no fast carom to clamp.
#   restitution eases from the soft/slow value toward the hard value as puck speed
#   climbs to deflect_speed_ref, so a squared blade smothers a slapper instead of
#   pinballing it. The falloff SHAPE is measured reality: puck COR decreases
#   roughly linearly with impact speed (0.50 at 15 mph → 0.34 at 85, rigid plate,
#   room temp) and frozen game-temp pucks plateau near 0.27 (WSU Sports Science
#   Lab, "Experimental Characterization of Ice Hockey Sticks and Pucks"). This
#   lerp evaluates to ≈0.27 right at deflect_min_speed — matching the frozen-puck
#   measurement where natural deflects begin — and bottoms below it because a
#   hand-held blade absorbs more than the rigid plate the lab measured against.
@export var deflect_normal_restitution: float = 0.6       # soft/slow puck bounces off the face
@export var deflect_normal_restitution_min: float = 0.15  # hard puck (at/above ref) barely rebounds — it dies; < 0 disables falloff
@export var deflect_tangential_retain: float = 0.85       # glancing slide is largely kept (a redirect keeps pace)
@export var deflect_speed_ref: float = 30.0               # speed (m/s) at which restitution bottoms out
@export var deflect_cooldown: float = 0.3
# Signed per-loft-level redirect for a deliberate deflect, expressed as a fixed
# VERTICAL LAUNCH SPEED (m/s) — the SAME loft model shots use (ShotMechanics.loft_y),
# not a fixed angle. Fixed-angle ties the tip's apex to the incoming puck's pace
# (apex ∝ pace²), so a hard tip sails over the net; a fixed launch speed gives a
# CONSISTENT apex regardless of pace, and the redirect keeps its horizontal pace
# minus what's carved into the lift (energy-conserving, like a lofted shot). LOW
# tips a grounded puck UP, HIGH bats an airborne puck DOWN, FLAT stays horizontal.
@export var deflect_up_loft_speed: float = 3.8     # LOW — tip up and in (apex ≈ 0.74 m)
@export var deflect_down_loft_speed: float = 3.5   # HIGH — drive an airborne puck down to the ice
# A deflect whose resulting speed lands below this reads as a BOBBLE — the blade
# smothered the puck (knocked it down) rather than redirecting it. The deflector
# gets the short bobble_cooldown so they can gather their own knockdown, instead
# of the full deflect_cooldown lockout; a genuine redirect (faster exit) keeps the
# lockout. Feedback (game_manager) also reads this threshold so a bobble sounds
# duller than a live redirect.
@export var bobble_speed_threshold: float = 11.0
@export var bobble_cooldown: float = 0.12
# Poke exit speed now scales with the blade-contest momentum (see
# PuckCollisionRules.poke_strip_velocity): a soft poke floors at min, a hard sweep
# squirts the puck up to max. Old behavior was a flat 6.0 regardless of how hard
# the poke was.
@export var poke_strip_min_speed: float = 3.0
@export var poke_strip_max_speed: float = 9.0
@export var poke_carrier_vel_blend: float = 0.5
@export var poke_checker_cooldown: float = 0.1
# Delivered victim-impulse (BodyCheckRules.puck_strip_impulse — the REAL applied
# knockback |Δv|, via SkaterCollisionRules.victim_kick) needed to knock the puck
# off the carrier. Deliberately EQUAL to the full-check point on the stagger ladder
# (SkaterController.stagger_ref_impulse, 1.35): a hit hard enough to count as a
# full-strength check is exactly a hit hard enough to strip the puck. The
# equal-mass baseline lands there at ~6 m/s closing (medium build) while
# Physical/mass move it honestly: an enforcer strips at lower closing speed, a
# low-Physical hit needs much more. Below it (down to stagger_min 0.6) a hit still
# staggers the carrier but leaves the puck on his stick — a jarring bump, not a
# turnover.
@export var body_check_strip_threshold: float = 1.35
@export var body_check_puck_speed: float = 3.0           # soft-strip trickle pace along the hit line
@export var body_check_loose_speed: float = 0.8          # forward carry a full-strength hit leaves (puck drops loose at contact)
@export var body_check_strip_ref_impulse: float = 5.5    # delivered impulse that fully deadens the strip (puck jarred dead)
@export var hit_pickup_cooldown: float = 0.6              # seconds victim cannot pick up after a hard hit
@export var hit_pickup_cooldown_threshold: float = 1.35   # delivered victim-impulse needed to apply hit pickup cooldown (see body_check_strip_threshold)
@export var body_block_dampen: float = 0.5
# Puck energy retention on an ACTIVE (shot-block crouch) block — lower than the passive
# dampen so a committed block kills more of the shot. Was SkaterController.active_block_dampen;
# consolidated here with the passive value now that on_body_block picks between them.
@export var body_block_active_dampen: float = 0.35
@export var body_block_cooldown: float = 0.1
# Vertical clamp: the puck's Y is capped at ice_height + max_height in
# _integrate_forces. Must stay BELOW the rink's collision top
# (HockeyRink.COLLISION_OVERGLASS_TOP, 3.2 m) — otherwise an elevated deflection
# that pegs this clamp sits above the boards and escapes the rink. If you raise
# this, raise COLLISION_OVERGLASS_TOP to keep the margin.
@export var max_height: float = 3.0

# Analytic rink-containment backstop (see _integrate_forces). The boards'
# trimesh + CCD contains the puck almost always, but a sustained wall slide can
# still squeeze the center past a facet plane, and a zero-thickness triangle
# then depenetrates it OUTWARD — the "puck leaves the arena" escape. Trigger:
# center past the inner (kickplate-lip) boundary by more than float noise —
# the disc is then embedded a full radius, provably beyond any contact slop.
const CONTAINMENT_EPSILON: float = 0.001
# An escape in progress is caught on its first tick, ≤ max_speed/120 ≈ 0.32 m
# past the boundary. Anything further out in a single step is a deliberate
# teleport (drill managers stash the puck at (100, 100) between attempts) and
# must be left alone — the drill owns puck placement.
const CONTAINMENT_TELEPORT_SKIP: float = 2.0
# Count of times the analytic containment backstop below has rescued an escaped puck
# (Jolt's trimesh let the center past the boards — the rim-around "falls out of the
# arena" bug). This is the TRUE escape frequency the Phase-0 harness wants: by the time
# PuckController reads the puck, the rescue has already reseated it, so the comparator's
# own boundary check reads ~0. Read via PuckController's shadow log.
var containment_rescue_count: int = 0
# The goalie StaticBody3D part Jolt reported the most recent contact against — read
# synchronously by the Phase-2 goalie-collision harness on the puck_touched_goalie
# signal (set just before that emit), to compare Jolt's part against the analytic pick.
var last_goalie_contact_body: Node = null

# ── Save-rebound control (host-authoritative) ─────────────────────────────────
# A real goalie controls rebounds instead of caroming every shot back into the
# slot. On a controlled save (chest/glove catch at any speed, or an easy pad/
# blocker save) the rebound is deadened to a crawl the goalie's crease-sweep then
# clears; hard pad saves and stick contacts keep the live restitution rebound
# (the beatable scramble chance). See GoalieSaveRules. Deadening is pose-neutral
# rebound control, correct under every ruleset — a whistle-on-cover would be a
# separate, ruleset-gated layer on top. Tunable so feel can be dialed in-editor.
@export var save_deaden_pad_max_speed: float = 28.0  # pad/blocker saves faster than this stay live (≈63 mph — above a solid wrister, below hard shots/slappers)
@export var save_deaden_drop_speed: float = 1.2      # absorbed exit-speed ceiling (m/s, chest/glove)
@export var save_deaden_glove_retain: float = 0.0    # glove catch — kill it dead
@export var save_deaden_chest_retain: float = 0.12
# Controlled pad/blocker saves STEER cornerward instead of dying at the
# goalie's feet — modern active-rebound doctrine (goalie realism audit F12).
@export var save_steer_speed: float = 5.0            # m/s cornerward exit off a controlled pad save
@export var save_steer_lateral_weight: float = 1.0   # cornerward bias (lateral vs forward)
@export var save_steer_forward_weight: float = 0.35  # out-of-crease bias

var carrier: Skater = null
var pickup_locked: bool = false
# Per-skater puck pickup cooldowns. Keyed by Skater.get_instance_id() rather
# than the Skater object directly so that the typed Dictionary's erase()
# validator doesn't reject freed-instance keys when a skater is queue_freed
# (e.g. tutorial puppet bot teardown) before the per-tick cleanup loop drops
# its stale entry. Public API still takes a Skater; the int conversion is
# internal.
#
# Values are ABSOLUTE expiry timestamps in the host's local_time() base — the
# same base StateBufferManager stamps its rewind snapshots with. Storing expiry
# (rather than a per-tick countdown) is what lets the lag-comp pickup resolver
# ask "was this skater on cooldown at their view-time?" via is_on_cooldown_at,
# consistent with how it rewinds is_ghost / shot_state. It also puts the cooldown
# clock on the same wall-time as the snapshot buffer instead of fixed-delta sim
# seconds (the two diverge under host dilation).
var _cooldown_timers: Dictionary[int, float] = {}
# Time source for cooldown expiry (host local_time). Injected by PuckController so
# the actor stays engine-clock-agnostic; falls back to monotonic wall-time for
# standalone use (tests that never run a lag-comp query).
var _now_provider: Callable = Callable()
# Reused scratch for the per-tick cooldown expiry sweep — cleared (capacity
# retained) each tick instead of reallocated, since cooldowns are active through
# most of live play (every touch arms a ~0.5s reattach window).
var _expired_cooldowns: Array[int] = []
var _is_server: bool = false
var _pending_reset: bool = false
var _pending_reset_xz: Vector2 = Vector2.ZERO
var _clamp_at_goal_line: bool = false
# Last known-finite puck position, cached each physics step so the non-finite
# guard in _integrate_forces can restore a sane position rather than crash Jolt.
var _last_finite_position: Vector3 = Vector3.ZERO
# Full velocity stored by release() for every shot, applied by _integrate_forces.
# Jolt does not preserve linear_velocity set on a frozen body when it activates
# as dynamic — state.linear_velocity on the first dynamic step is zero. Storing
# and applying the full vector here ensures XYZ reach the simulation correctly.
# For elevated shots (y > 0) _integrate_forces also writes the elevated Y position.
var _pending_elevation_vel: Vector3 = Vector3.ZERO
# Belt-and-suspenders for _physics_process: skip is_airborne() zeroing the
# same frame as release() so _pending_elevation_vel reaches _integrate_forces.
var _pending_elevation: bool = false
# Velocity the puck carried into this physics step (cached at the end of
# _integrate_forces), read by the save-deaden classifier as the pre-bounce
# incoming velocity — linear_velocity in _on_body_entered may already reflect the
# restitution response for the step.
var _pre_contact_velocity: Vector3 = Vector3.ZERO
# Queued controlled-save deaden, applied on the next _integrate_forces step so it
# definitively overrides the engine's restitution rebound (host-only; set in
# _on_body_entered). Mirrors the _pending_elevation_vel apply pattern.
var _pending_save_deaden: Vector3 = Vector3.ZERO
var _pending_save_deaden_active: bool = false
# Built once from the save-deaden exports (rebuilt only on demand — exports don't
# change at runtime), so the per-save classification allocates nothing.
var _deaden_cfg: GoalieSaveRules.DeadenConfig = null
# Callable (Skater) -> int team_id, or -1 if the skater isn't registered. Set
# by GameManager at spawn time so Puck doesn't reach upward for team checks.
var _team_resolver: Callable = Callable()

func set_team_resolver(resolver: Callable) -> void:
	_team_resolver = resolver

# ── Analytic host drive (determinism migration; dev + host only) ───────────────
# When enabled, the LOOSE puck is driven by the deterministic analytic sim instead of Jolt:
# integration + ice friction + gravity + board caroms (PuckAuthorityRules / step_puck_3d),
# goal-frame reflection (PuckGeometryCollision: posts / crossbar / top + back/side net), and
# goalie detection + response (GoalieContactDetector + GoalieSaveRules.resolve_contact). The
# puck is frozen so Jolt neither integrates nor collides it — gameplay pickup / deflect /
# poke / goal-detection are already analytic — and _on_body_entered is guarded off so the
# feedback signals fire once, from the drive. Host-only: the client still interpolates host
# snapshots (client-side prediction is a later phase). Everything _integrate_forces did for a
# free puck (reset staging, elevation, save deaden, clamps, containment) is re-homed into
# _drive_analytic. Gated by BuildInfo.VERSION == "dev" at the PuckController seam.
var _analytic_drive_enabled: bool = false
var _goalie_provider: Callable = Callable()  # returns Array of live Goalie nodes for contact detection
# Only run goalie contact detection when the puck is within this of a goal line (a goalie's
# deepest challenge + margin) — skips the swept-OBB test for the puck's mid-ice life.
const _GOALIE_DETECT_RANGE_Z: float = 6.0
# Sub-step the drive when the puck is within this of a goal line, so a hard shot can't tunnel
# through the thin posts / net panels (the goalie is already swept). Elsewhere the puck steps
# once per tick — only the boards, an untunnelable position clamp, live out there.
const _FRAME_SUBSTEP_RANGE_Z: float = 3.0
const _FRAME_SUBSTEP_M: float = 0.04         # max advance per sub-step (< a puck radius)
const _MAX_FRAME_SUBSTEPS: int = 16          # cap (16 × 0.04 m = 0.64 m/tick ≈ 77 m/s)
# Caller-owned scratch so the per-tick drive allocates nothing.
var _frame_result: PuckGeometryCollision.Result = null
var _goalie_contact: GoalieContactDetector.Contact = null
var _goalie_scratch: SweptDiscOBB.Result = null
var _save_result: GoalieSaveRules.ContactResult = null

func set_analytic_drive_enabled(enabled: bool) -> void:
	_analytic_drive_enabled = enabled
	if enabled and _frame_result == null:
		_frame_result = PuckGeometryCollision.Result.new()
		_goalie_contact = GoalieContactDetector.Contact.new()
		_goalie_scratch = SweptDiscOBB.Result.new()
		_save_result = GoalieSaveRules.ContactResult.new()
	if enabled:
		# The puck is frozen for its ENTIRE life under the analytic drive — carried (carry pin)
		# or loose (the drive) — so Jolt never integrates or collides it and there is no dynamic
		# tick anywhere, not at spawn, release, or reset. (Phase 4 replaces the frozen body with
		# a plain Node3D outright.)
		freeze = true

func set_goalie_provider(provider: Callable) -> void:
	_goalie_provider = provider

func _ready() -> void:
	# Puck body sits on its own layer so goal sensors can detect it.
	# Mask bounces it off boards (LAYER_BOARDS) + goalie bodies/nets/ice
	# (LAYER_WALLS) + goalie stick, but not skater bodies.
	collision_layer = Constants.LAYER_PUCK
	collision_mask  = Constants.MASK_PUCK
	continuous_cd = true
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
	contact_monitor = true
	max_contacts_reported = 4
	body_entered.connect(_on_body_entered)
	_last_finite_position = global_position
	_build_deaden_cfg()

	var vfx := PuckVFX.new()
	vfx.name = "VFX"
	add_child(vfx)

	# Ice-pinned tracking shadow so the small disc stays readable and airborne
	# pucks show their landing spot. Cosmetic; renders on every peer.
	var shadow := PuckShadow.new()
	shadow.name = "Shadow"
	add_child(shadow)

# ── Server Mode ───────────────────────────────────────────────────────────────
func set_server_mode(is_server: bool) -> void:
	_is_server = is_server
	if not is_server:
		freeze = true

func set_client_prediction_mode(active: bool) -> void:
	if _is_server:
		return
	freeze = not active
	if not active:
		linear_velocity = Vector3.ZERO
		_clamp_at_goal_line = false

func set_goal_line_clamp(enabled: bool) -> void:
	_clamp_at_goal_line = enabled

# ── Contract for PuckController ───────────────────────────────────────────────
func get_puck_position() -> Vector3:
	return global_position

func get_puck_velocity() -> Vector3:
	return linear_velocity

func set_puck_position(pos: Vector3) -> void:
	global_position = pos

func set_puck_velocity(vel: Vector3) -> void:
	linear_velocity = vel

# Immediately parks a LOOSE puck at rest at `pos` — used to restage the puck
# between offline-drill attempts. Unlike reset() the position lands THIS frame
# (no deferred _pending_reset) and no puck_released signal fires; unlike a bare
# set_puck_position + linear=0 it also zeroes ANGULAR velocity and any queued
# release/elevation velocity, so a fast, spinning missed puck can't keep rolling
# or carry momentum into the next rep (the "velocity carries over" annoyance). A
# loose puck is never frozen, so Jolt's unfreeze-zeroing doesn't apply here — the
# spin has to be cleared explicitly. Wakes the body so a settled puck honors the
# teleport.
func stage_at(pos: Vector3) -> void:
	if carrier != null:
		drop()
	sleeping = false
	global_position = pos
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	_pending_elevation_vel = Vector3.ZERO
	_pending_elevation = false

# Used by client-side prediction release (notify_local_release). Applies the
# same _pending_elevation_vel treatment as release() so Jolt's first dynamic
# integration step gets the full XYZ vector instead of starting at zero.
func apply_release_velocity(vel: Vector3) -> void:
	linear_velocity = vel
	if vel.y > 0.0:
		_pending_elevation_vel = vel
		_pending_elevation = true

func get_carrier() -> Skater:
	return carrier

# Returns linear_velocity, OR _pending_elevation_vel when release() has just
# fired and Jolt hasn't yet applied it (Jolt zeroes velocity on the first
# dynamic step after unfreeze, so release() stores the full vector here for
# _integrate_forces to write next tick). Use this from same-frame consumers
# of the puck_released signal — `linear_velocity` reads zero in that window.
func get_release_velocity() -> Vector3:
	if not _pending_elevation_vel.is_zero_approx():
		return _pending_elevation_vel
	return linear_velocity

func set_carrier(skater: Skater) -> void:
	carrier = skater
	freeze = true

func clear_carrier() -> void:
	carrier = null
	# Under the analytic drive the loose puck STAYS frozen — the drive owns it and Jolt never
	# integrates it, so there's no dynamic tick between release and the drive taking over. Only
	# the Jolt path unfreezes to a dynamic body.
	if not _analytic_drive_enabled:
		freeze = false

# ── Cooldown Helpers ──────────────────────────────────────────────────────────
# Host local_time() (injected) so cooldown expiry shares the snapshot-buffer base.
func set_time_provider(provider: Callable) -> void:
	_now_provider = provider

func _now() -> float:
	return _now_provider.call() if _now_provider.is_valid() else Time.get_ticks_msec() / 1000.0

func is_on_cooldown(skater: Skater) -> bool:
	return is_on_cooldown_at(skater, _now())

# Was the skater on cooldown at an arbitrary host-time `at`? Used by the lag-comp
# pickup resolver to judge eligibility at the claimant's view-time rather than at
# present time (up to one-way latency later), matching its rewound is_ghost /
# shot_state checks. Present-time `is_on_cooldown` is `is_on_cooldown_at(_, now)`.
func is_on_cooldown_at(skater: Skater, at: float) -> bool:
	return _cooldown_timers.get(skater.get_instance_id(), -1.0) > at

func _set_cooldown(skater: Skater, duration: float) -> void:
	# Take the max with any existing entry so a shorter cooldown set immediately
	# after a longer one (e.g. body_block_cooldown 0.1s right after reattach 0.5s)
	# never shortens the in-flight cooldown. Values are absolute expiry times, so
	# a lingering already-expired entry (expiry < now) is correctly superseded.
	var id: int = skater.get_instance_id()
	_cooldown_timers[id] = maxf(_cooldown_timers.get(id, -1.0), _now() + duration)

func set_skater_cooldown(skater: Skater, duration: float) -> void:
	_set_cooldown(skater, duration)

func remove_skater_cooldown(skater: Skater) -> void:
	_cooldown_timers.erase(skater.get_instance_id())

# ── Physics ───────────────────────────────────────────────────────────────────
func apply_blade_deflect(skater: Skater) -> void:
	# Reflect off the blade face — angle depends on how the player has angled
	# their stick, not just where the puck contacted.
	var contact_normal: Vector3 = skater.get_blade_face_normal(linear_velocity)

	var new_vel: Vector3 = PuckCollisionRules.deflect_velocity(
			linear_velocity, contact_normal,
			deflect_normal_restitution, deflect_normal_restitution_min,
			deflect_tangential_retain, deflect_speed_ref)

	# Signed per-level redirect as a fixed VERTICAL LAUNCH SPEED (LOW up, HIGH
	# down, FLAT horizontal), so the tip's apex is consistent regardless of the
	# incoming puck's pace — a hard tip no longer sails over the net. Reuses the
	# shot loft solve (ShotMechanics.loft_y): it carves the lift out of the
	# redirect's horizontal pace (energy-conserving, total speed unchanged), the
	# same way a lofted shot trades pace for height. A dead-square knockdown
	# collapses to ~zero speed (a bobble drop); skip the lift there — a smothered
	# puck shouldn't pop off the ice.
	var loft_vy: float = 0.0
	if skater.elevation_level == 1:
		loft_vy = deflect_up_loft_speed
	elif skater.elevation_level >= 2:
		loft_vy = -deflect_down_loft_speed
	var horiz_speed: float = new_vel.length()
	if not is_zero_approx(loft_vy) and horiz_speed > 0.001:
		# loft_y gives the Y/XZ ratio that yields launch speed |loft_vy| at this
		# horizontal pace; sign it for an up-tip (+) vs a down-knockdown (−).
		var y_ratio: float = ShotMechanics.loft_y(horiz_speed, absf(loft_vy)) * signf(loft_vy)
		var flat_dir: Vector3 = Vector3(new_vel.x, 0.0, new_vel.z).normalized()
		new_vel = Vector3(flat_dir.x, y_ratio, flat_dir.z).normalized() * horiz_speed

	linear_velocity = new_vel
	# A low-speed result is a bobble: the blade knocked the puck down instead of
	# redirecting it. Give the deflector a short window to gather it rather than
	# the full deflect lockout (which is meant to stop re-touching a live redirect).
	var is_bobble: bool = new_vel.length() < bobble_speed_threshold
	_set_cooldown(skater, bobble_cooldown if is_bobble else deflect_cooldown)
	puck_touched_loose.emit(skater)

func on_body_block(blocker: Skater) -> void:
	if not _is_server:
		return
	if pickup_locked:
		return
	if blocker.is_ghost:
		return
	if carrier != null:
		return  # only deflect loose/airborne pucks, not carried ones
	var body_world: Vector3 = blocker.global_position
	body_world.y = 0.0
	var puck_pos: Vector3 = global_position
	puck_pos.y = 0.0
	var contact_normal: Vector3 = puck_pos - body_world
	if contact_normal.length() < 0.001:
		contact_normal = -blocker.global_transform.basis.z
	contact_normal = contact_normal.normalized()
	# A committed shot-block crouch kills more of the shot than a passive body absorb.
	var dampen: float = body_block_active_dampen \
			if blocker.current_shot_state == SkaterStateMachine.State.SHOT_BLOCKING \
			else body_block_dampen
	linear_velocity = PuckCollisionRules.body_block_velocity(
			linear_velocity, contact_normal, dampen)
	_set_cooldown(blocker, body_block_cooldown)
	puck_body_blocked.emit(blocker)

func on_body_check(checker: Skater, victim: Skater, impact_force: float, hit_direction: Vector3) -> void:
	if not _is_server:
		return
	if checker.is_ghost or victim.is_ghost:
		return
	# Gate on the impulse actually DELIVERED to the victim (folds in the attacker's
	# Physical/transfer, both skaters' mass, and the closing speed) rather than the
	# raw attacker-weight × speed impact_force — so the same hit dislodges the puck
	# for an enforcer but not for a low-Physical player. Matches the stagger's
	# hardness measure; see BodyCheckRules.puck_strip_impulse.
	#
	# The attacker's transfer is commit-gated by the Hit button, the SAME way the
	# knockback is (Skater._resolve_player_collisions): a committed check strips at
	# full force, an uncommitted bump only at hit_passive_transfer_mult — so
	# "without the hit button, hits shouldn't be that powerful" holds for the puck
	# too, not just the knockback. The victim's brace (hit_committed) already cut it.
	var checker_transfer: float = checker.body_check_transfer \
			* (1.0 if checker.hit_committed else checker.hit_passive_transfer_mult)
	var strip_impulse: float = BodyCheckRules.puck_strip_impulse(
			impact_force, checker.weight, checker_transfer,
			victim.weight, victim.body_check_brace_resistance, victim.hit_committed)
	if strip_impulse < hit_pickup_cooldown_threshold:
		return
	# Hard hits temporarily deny the victim a pickup, even if they weren't carrying.
	_set_cooldown(victim, hit_pickup_cooldown)
	if carrier == null or carrier != victim:
		return
	if pickup_locked:
		return
	if strip_impulse < body_check_strip_threshold:
		return
	# 0..1 hardness from the strip threshold (barely strips) up to ref (jarred dead),
	# so a bigger hit deadens the loose puck more — see body_check_strip_velocity.
	var strip_intensity: float = clampf(
			(strip_impulse - body_check_strip_threshold)
			/ maxf(body_check_strip_ref_impulse - body_check_strip_threshold, 0.001),
			0.0, 1.0)
	_body_check_strip(checker, hit_direction, strip_intensity)

func _body_check_strip(checker: Skater, hit_direction: Vector3, strip_intensity: float) -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = PuckCollisionRules.body_check_strip_velocity(
			hit_direction, body_check_puck_speed, body_check_loose_speed, strip_intensity)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()

func apply_poke_check(checker_skater: Skater) -> void:
	var ex_carrier: Skater = carrier  # capture before clear_carrier()
	var fallback_dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	clear_carrier()
	linear_velocity = PuckCollisionRules.poke_strip_velocity(
			checker_skater.blade_world_velocity,
			ex_carrier.blade_world_velocity,
			ex_carrier.global_position,
			checker_skater.global_position,
			poke_carrier_vel_blend,
			poke_strip_min_speed,
			poke_strip_max_speed,
			fallback_dir)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker_skater, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()

# Stick-lift strip: unlike a poke (which squirts the puck off the blade contact),
# a lifted stick just leaves the puck where it was being carried — so it keeps
# travelling in the carrier's direction at the carrier's speed, as if the carry
# simply continued without the stick on it. Horizontal only; a stationary
# carrier's puck stays put (the reattach cooldown still denies an instant
# re-grab). Same cooldowns + signals as apply_poke_check so the carrier-clear,
# stats, and victim-notify paths fire identically.
func apply_stick_lift_strip(checker_skater: Skater) -> void:
	var ex_carrier: Skater = carrier  # capture before clear_carrier()
	clear_carrier()
	linear_velocity = Vector3(ex_carrier.velocity.x, 0.0, ex_carrier.velocity.z)
	_set_cooldown(ex_carrier, reattach_cooldown)
	_set_cooldown(checker_skater, poke_checker_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()
# blade_world_velocity / cooldown table entry), so it gets its own entry
# point. Strip velocity uses the goalie's blade position + the controller's
# computed blade velocity as the checker inputs.
#
# No checker-side cooldown — the goalie's lunge cooldown already prevents
# spam pokes, and adding the goalie to the per-skater cooldown table would
# fight every other system that filters by Skater identity.
func apply_goalie_poke_check(blade_pos: Vector3, blade_vel: Vector3) -> void:
	var ex_carrier: Skater = carrier
	var fallback_dir := Vector3(randf_range(-1.0, 1.0), 0.0, randf_range(-1.0, 1.0))
	clear_carrier()
	linear_velocity = PuckCollisionRules.poke_strip_velocity(
			blade_vel,
			ex_carrier.blade_world_velocity,
			ex_carrier.global_position,
			blade_pos,
			poke_carrier_vel_blend,
			poke_strip_min_speed,
			poke_strip_max_speed,
			fallback_dir)
	_set_cooldown(ex_carrier, reattach_cooldown)
	puck_stripped.emit(ex_carrier)
	puck_released.emit()


# Goalie loose-puck sweep / clear. The poke check (apply_goalie_poke_check)
# strips a CARRIED puck; this is its loose-puck counterpart — the goalie
# sweeps an uncarried puck out of the crease toward the corner. There's no
# carrier to clear and nobody was dispossessed, so it fires no strip/release
# signals; it just imparts the clearing velocity. No-op on a carried puck
# (the poke path owns that case). Host-only — the authoritative velocity
# replicates to clients through the normal puck sync.
func apply_goalie_sweep(sweep_velocity: Vector3) -> void:
	if carrier != null:
		return
	sleeping = false
	linear_velocity = sweep_velocity


func release(direction: Vector3, power: float) -> void:
	var ex_carrier: Skater = carrier
	# Set position while still frozen so Jolt activates from the correct state.
	# Slapshot wind-up: the blade is overhead and pulled back, but the puck has
	# been pinned to a stable ice offset via get_carry_target_global. Read from
	# that pin instead of the elevated blade contact so the shot fires from
	# where the puck visibly is.
	if ex_carrier != null:
		if ex_carrier.is_slapshot_pinning():
			global_position = ex_carrier.get_carry_target_global()
		else:
			global_position = ex_carrier.get_blade_contact_global()
	if direction.y > 0:
		global_position.y = ice_height + 0.1
		_pending_elevation = true
	else:
		global_position.y = ice_height
	_pending_elevation_vel = direction * power
	clear_carrier()
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

# Nudge: a soft self-pass off the carrier's own blade. Unlike release()
# (a shot, direction × power from the blade) the velocity is a full vector the
# controller computed from the carrier's momentum + a small stick-direction
# push. Grounded only (a nutmeg lives on the ice), and the ex-carrier gets only
# the short nudge_cooldown so they can re-collect the puck after it slips the
# gap. Reuses _pending_elevation_vel so Jolt's first dynamic step keeps the
# velocity (a frozen-body linear_velocity write is otherwise zeroed on unfreeze).
func nudge(velocity: Vector3) -> void:
	var ex_carrier: Skater = carrier
	if ex_carrier != null:
		global_position = ex_carrier.get_blade_contact_global()
	global_position.y = ice_height
	_pending_elevation = false
	var v := velocity
	v.y = 0.0
	_pending_elevation_vel = v
	clear_carrier()
	if ex_carrier != null:
		_set_cooldown(ex_carrier, nudge_cooldown)
	puck_released.emit()

func drop() -> void:
	var ex_carrier: Skater = carrier
	clear_carrier()
	linear_velocity = Vector3.ZERO
	# A shot fired the same tick as a stoppage could leave a release velocity
	# queued (release() runs before the physics step); clear it so the dropped
	# puck doesn't inherit it and rocket off on the next _integrate_forces.
	_pending_elevation_vel = Vector3.ZERO
	_pending_elevation = false
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

func reset(at_xz: Vector2 = Vector2.ZERO) -> void:
	carrier = null
	# Jolt path unfreezes so _integrate_forces runs next step; the analytic drive stays frozen
	# and applies the pending reset itself (no dynamic tick).
	if not _analytic_drive_enabled:
		freeze = false
	sleeping = false  # a slept body skips _integrate_forces, so it would ignore the teleport
	_cooldown_timers.clear()
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	# Discard any release velocity queued this frame — a faceoff / whistle reset
	# must not inherit a shot fired on the same tick (would launch the dot puck).
	_pending_elevation_vel = Vector3.ZERO
	_pending_elevation = false
	_pending_reset = true
	_pending_reset_xz = at_xz
	puck_released.emit()

func is_airborne() -> bool:
	return position.y > ice_height + GameRules.PUCK_AIRBORNE_HEIGHT_M

# Drops a puck that settled on low net geometry (the back/skirt frame) straight
# down to the ice so it becomes playable again — it was only a few cm up but
# never touched the ice, so it read as airborne forever. Host-authoritative; the
# new position replicates through the normal state buffer.
func settle_to_ice() -> void:
	global_position.y = ice_height
	linear_velocity.y = 0.0
	angular_velocity = Vector3.ZERO

# One-shot spark burst at the puck for a stick-lift strip. Delegated to PuckVFX
# (child "VFX"); the burst anchors to the puck, which sits at the dislodge point.
func fire_stick_lift_vfx() -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_stick_lift_burst()

# Ice-chip puff for a board hit; PuckVFX gates on speed and coalesces grinds.
func fire_board_impact_vfx(speed: float) -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_board_impact_burst(speed)

# Spark snap for a shot off the post; PuckVFX skips soft touches.
func fire_post_ping_vfx(speed: float) -> void:
	var vfx := get_node_or_null("VFX") as PuckVFX
	if vfx != null:
		vfx.fire_post_ping_burst(speed)

func _on_body_entered(body: Node3D) -> void:
	# Under the analytic drive the puck is frozen and never touches Jolt geometry; the drive
	# emits every contact signal itself, so ignore any stray Jolt contact to avoid double-fire.
	if _analytic_drive_enabled:
		return
	if carrier != null:
		return
	var goalie: Goalie = _goalie_ancestor(body)
	if goalie != null:
		# Host-authoritative rebound control: deaden a controlled save so it
		# doesn't carom into the slot. The deadened velocity replicates to clients
		# through the normal puck sync / reconciliation, same as pokes and sweeps.
		# Resolved BEFORE the generic contact signal so a glove CATCH transitions
		# the goalie first — _on_puck_contact's rebound-butterfly then sees a
		# non-upright catching state and skips, keeping an upright catch upright.
		if _is_server:
			_resolve_save_rebound(body)
		last_goalie_contact_body = body  # for the Phase-2 goalie-collision harness
		puck_touched_goalie.emit(goalie)
	elif body is HockeyGoal:
		puck_touched_post.emit()
	elif body.get_parent() is HockeyGoal:
		if linear_velocity.length() >= 1.0:
			puck_hit_goal_body.emit()
	elif body is HockeyRink and linear_velocity.length() >= 1.0:
		# Only the rink's perimeter boards (HockeyRink's own collider) fire the
		# board-hit thud / chip VFX / RPC. The ice surface is a SEPARATE
		# StaticBody3D child, so the old `body is StaticBody3D` also fired on every
		# grounded release and every landing — a board hit at the wrong spot.
		puck_hit_boards.emit()


# Host-only analytic drive for one tick of the LOOSE puck (determinism migration). Runs the
# deterministic sim in place of Jolt and re-homes everything _integrate_forces did for a free
# puck. The puck is frozen so Jolt never fights it; position + velocity are written directly.
func _drive_analytic(dt: float) -> void:
	# Faceoff / reset staging (re-homed from _integrate_forces).
	if _pending_reset:
		_pending_reset = false
		global_position = Vector3(_pending_reset_xz.x, ice_height, _pending_reset_xz.y)
		linear_velocity = Vector3.ZERO
		_pending_reset_xz = Vector2.ZERO
		freeze = true
		return
	# Deliberate far teleport (drills stash the puck off-rink between reps): leave it parked,
	# matching the CONTAINMENT_TELEPORT_SKIP guard in the Jolt path.
	var here := Vector2(global_position.x, global_position.z)
	if here.distance_to(GameRules.clamp_to_rink_inner(here)) > CONTAINMENT_TELEPORT_SKIP:
		return
	freeze = true  # keep Jolt off the loose puck (idempotent)
	var prev: Vector3 = global_position
	# Authoritative velocity: get_release_velocity() returns the queued shot/nudge vector on a
	# release tick (full XYZ incl. loft vy) and linear_velocity otherwise — so every analytic
	# interaction that writes linear_velocity mid-flight (deflect, poke, strip, sweep, body
	# block) is picked up. linear_velocity persists on the frozen body (it's never unfrozen).
	var incoming: Vector3 = get_release_velocity()
	_pending_elevation_vel = Vector3.ZERO  # consumed
	_pending_elevation = false

	# Integrate (ice friction + gravity + board caroms + clamps) AND resolve ALL near-net
	# collision — posts, crossbar, net panels, and the goalie — in ONE sub-stepped pass. Near the
	# thin frame the puck advances in < 4 cm sub-steps so a hard shot (0.33 m/tick at 40 m/s)
	# can't tunnel through the pipes/panels, and every contact is resolved in order on the
	# sub-step it happens (the goalie sees each sub-step's real segment, not one straight tick
	# chord — so a post-ricochet-into-a-save reads right). Open ice steps once: its only geometry
	# is the boards, a position clamp that can't tunnel. Two ranges: sub-step within
	# _FRAME_SUBSTEP_RANGE_Z of a goal line (the thin frame); run goalie detection out to the
	# wider _GOALIE_DETECT_RANGE_Z (a goalie challenges further than the frame sits).
	var radius: float = GameRules.PUCK_COLLISION_RADIUS
	var goalie_range: bool = absf(prev.z) > GameRules.GOAL_LINE_Z - _GOALIE_DETECT_RANGE_Z
	var goalies: Array = _goalie_provider.call() if goalie_range and not _goalie_provider.is_null() else []
	var substeps: int = 1
	if absf(prev.z) > GameRules.GOAL_LINE_Z - _FRAME_SUBSTEP_RANGE_Z:
		substeps = clampi(ceili(incoming.length() * dt / _FRAME_SUBSTEP_M), 1, _MAX_FRAME_SUBSTEPS)
	var sub_dt: float = dt / float(substeps)
	var pos: Vector3 = prev
	var vel: Vector3 = incoming
	for _sub in substeps:
		var sub_prev: Vector3 = pos
		var stepped: Transform3D = PuckAuthorityRules.advance_loose_puck(
				pos, vel, sub_dt, max_speed, ice_height, max_height)
		pos = stepped.origin
		vel = stepped.basis.x
		# Posts + crossbar (pipe ping), then top + back/side net panels (twine).
		if PuckGeometryCollision.resolve_posts(pos, vel, radius, _frame_result) \
				or PuckGeometryCollision.resolve_crossbar(pos, vel, radius, _frame_result):
			pos = _frame_result.position
			vel = _frame_result.velocity
			puck_touched_post.emit()
		if PuckGeometryCollision.resolve_top_net(pos, vel, _frame_result) \
				or PuckGeometryCollision.resolve_net_panels(pos, vel, radius, _frame_result):
			pos = _frame_result.position
			vel = _frame_result.velocity
			if incoming.length() >= 1.0:
				puck_hit_goal_body.emit()
		# Goalie: swept-OBB over THIS sub-step's segment → deaden / steer / catch / live reflect.
		if not goalies.is_empty() and GoalieContactDetector.nearest(
				goalies, sub_prev, pos, radius, _goalie_scratch, _goalie_contact):
			var part: int = _classify_save_part(_goalie_contact.part as Node3D)
			var g3: Node3D = _goalie_contact.goalie as Node3D
			var side: float = signf(pos.x - g3.global_position.x) if g3 != null else 0.0
			var dir_sign: int = int(signf(-g3.global_position.z)) if g3 != null else 0
			GoalieSaveRules.resolve_contact(
					vel, part, _goalie_contact.normal, side, dir_sign, _deaden_cfg, _save_result)
			vel = _save_result.velocity
			# Eject the disc flush off the contacted face so it never sits inside the pad.
			pos = _goalie_contact.point + _goalie_contact.normal * radius
			last_goalie_contact_body = _goalie_contact.part
			puck_touched_goalie.emit(_goalie_contact.goalie as Goalie)
			if _save_result.caught:
				puck_caught_by_goalie.emit(_goalie_contact.goalie as Goalie)
	# Board feedback: a real carom is the raw (un-reflected) full-tick position crossing the
	# boundary with into-board pace — a puck sliding parallel doesn't fire.
	var raw := Vector2(prev.x + incoming.x * dt, prev.z + incoming.z * dt)
	if raw.distance_to(GameRules.clamp_to_rink_inner(raw)) > 0.001 and incoming.length() >= 1.0:
		puck_hit_boards.emit()

	# 4) Goal-line clamp (re-homed from _integrate_forces).
	if _clamp_at_goal_line:
		var z: float = pos.z
		if absf(z) >= GameRules.GOAL_LINE_Z and z * vel.z > 0.0 \
				and absf(pos.x) <= GameRules.NET_HALF_WIDTH:
			pos.z = GameRules.GOAL_LINE_Z * signf(z)
			vel = Vector3.ZERO

	# 5) Commit. The puck can never sit below the ice — re-homes the Jolt path's grounded
	# `position.y = ice_height` pin, and catches a goalie eject / save whose normal drove the
	# disc down into the surface (the "puck in the ice, only the shadow shows" bug).
	if pos.y < ice_height:
		pos.y = ice_height
		if vel.y < 0.0:
			vel.y = 0.0
	# _pre_contact_velocity mirrors the Jolt path (pre-collision incoming) for any external
	# reader; linear_velocity is the authoritative store (persists on the frozen body) so
	# gameplay readers (get_puck_velocity, AI, HUD) and next tick's interactions see it.
	_pre_contact_velocity = incoming
	linear_velocity = vel
	global_position = pos


# The goalie's save surfaces are StaticBody3D parts at different scene depths —
# pads/body/head/glove sit directly under the Goalie root, but the stick and
# blocker hang off the BlockArm rig. Walk ancestors so a paddle or blocker save
# reads as a goalie touch too (a single get_parent() check silently dropped
# those saves from SOG tracking and goalie reaction resets). Contact-frequency
# only, never per-tick.
func _goalie_ancestor(node: Node) -> Goalie:
	var n: Node = node.get_parent()
	while n != null:
		if n is Goalie:
			return n as Goalie
		n = n.get_parent()
	return null


# Build the cached deaden config from the exports. Called from _ready; the
# exports don't change at runtime so it never needs rebuilding mid-play.
func _build_deaden_cfg() -> void:
	_deaden_cfg = GoalieSaveRules.DeadenConfig.new()
	_deaden_cfg.pad_max_incoming_speed = save_deaden_pad_max_speed
	_deaden_cfg.drop_speed = save_deaden_drop_speed
	_deaden_cfg.glove_retain = save_deaden_glove_retain
	_deaden_cfg.chest_retain = save_deaden_chest_retain
	_deaden_cfg.pad_steer_speed = save_steer_speed
	_deaden_cfg.steer_lateral_weight = save_steer_lateral_weight
	_deaden_cfg.steer_forward_weight = save_steer_forward_weight


# Classify a save surface by its StaticBody3D node name (LeftPad / RightPad /
# Body / Head / Glove / Blocker / Stick under Goalie.tscn). Unknown parts fall
# back to PAD (a live-on-hard, deaden-on-easy surface — the safe default).
func _classify_save_part(part_body: Node3D) -> int:
	match part_body.name:
		"Glove":
			return GoalieSaveRules.SavePart.GLOVE
		"Body", "Head":
			return GoalieSaveRules.SavePart.CHEST
		"Blocker":
			return GoalieSaveRules.SavePart.BLOCKER
		"Stick":
			return GoalieSaveRules.SavePart.STICK
	return GoalieSaveRules.SavePart.PAD


# Host-only: on a controlled save, queue a deadened rebound so the puck dies in
# the paint instead of caroming into the slot. The crease-sweep then clears it.
# Live saves (hard pad shots, stick redirects) return without queueing anything,
# so the engine's restitution rebound stands.
func _resolve_save_rebound(part_body: Node3D) -> void:
	if _deaden_cfg == null:
		return
	var part: int = _classify_save_part(part_body)
	var incoming: Vector3 = _pre_contact_velocity
	if not GoalieSaveRules.is_controlled_save(incoming.length(), part, _deaden_cfg):
		return
	# A controlled GLOVE save is a CATCH: the deaden below still kills the puck
	# this step (we're inside a physics callback — no freeze here), and the
	# goalie controller pins it into the glove on its next tick.
	if part == GoalieSaveRules.SavePart.GLOVE:
		var catch_goalie: Goalie = _goalie_ancestor(part_body)
		if catch_goalie != null:
			puck_caught_by_goalie.emit(catch_goalie)
	# Steered pad/blocker saves need the contact side (which side of the goalie
	# the puck arrived at → which corner the toe-out fires it to) and the
	# goalie's direction_sign (forward = out of the crease). Both derived from
	# the contacted goalie's transform, deterministic on host and client.
	var save_goalie: Goalie = _goalie_ancestor(part_body)
	var contact_side: float = 0.0
	var goalie_dir_sign: int = 0
	if save_goalie != null:
		contact_side = signf(global_position.x - save_goalie.global_position.x)
		goalie_dir_sign = int(signf(-save_goalie.global_position.z))
	_pending_save_deaden = GoalieSaveRules.deadened_velocity(
			incoming, part, contact_side, goalie_dir_sign, _deaden_cfg)
	_pending_save_deaden_active = true

func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	if _pending_reset:
		_pending_reset = false
		state.transform = Transform3D(Basis(),
				Vector3(_pending_reset_xz.x, ice_height, _pending_reset_xz.y))
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
		_pending_reset_xz = Vector2.ZERO
		return
	# Backstop: a non-finite velocity or position handed to Jolt is a hard native
	# crash (the max_speed clamp below can't catch it — NaN > max_speed is false).
	# Sanitize at the seam and log the source. Should never fire.
	if not state.linear_velocity.is_finite():
		push_error("Puck: non-finite velocity %s in _integrate_forces — zeroing." % state.linear_velocity)
		state.linear_velocity = Vector3.ZERO
	if state.transform.origin.is_finite():
		_last_finite_position = state.transform.origin
	else:
		push_error("Puck: non-finite position %s — restoring %s." % [state.transform.origin, _last_finite_position])
		var fixed: Transform3D = state.transform
		fixed.origin = _last_finite_position
		state.transform = fixed
		state.linear_velocity = Vector3.ZERO
		state.angular_velocity = Vector3.ZERO
	if not _pending_elevation_vel.is_zero_approx():
		# Write the full velocity vector directly into Jolt's physics state.
		# Jolt zeros state.linear_velocity on the first dynamic step after a
		# body unfreezes, so velocity set on a frozen body is lost without this.
		state.linear_velocity = _pending_elevation_vel
		if _pending_elevation_vel.y > 0.0:
			state.transform.origin.y = ice_height + 0.1
		_pending_elevation_vel = Vector3.ZERO
	if _pending_save_deaden_active:
		# Controlled-save deaden queued last step in _on_body_entered — override
		# the engine's restitution rebound so the puck dies in the paint. Applied
		# a step late (invisible ~8 ms) so it wins over the collision response.
		state.linear_velocity = _pending_save_deaden
		state.angular_velocity = Vector3.ZERO
		_pending_save_deaden = Vector3.ZERO
		_pending_save_deaden_active = false
	if state.linear_velocity.length() > max_speed:
		state.linear_velocity = state.linear_velocity.normalized() * max_speed
	if state.transform.origin.y > ice_height + max_height:
		state.transform.origin.y = ice_height + max_height
		if state.linear_velocity.y > 0.0:
			state.linear_velocity.y = 0.0
	# Analytic rink-containment backstop. The rink boundary is exactly known
	# (rounded rectangle — the same GameRules.clamp_to_rink_inner the boards'
	# collider is built on and that holds skaters in), so a center past it is
	# provably an escape the trimesh failed to stop: put the disc back flush
	# against the boards and reflect any outward velocity with the boards'
	# restitution (PuckCollisionRules.board_rescue_velocity — the same
	# reflection the AI trajectory model predicts), so a rescued rim reads as
	# a normal carom. Deliberate far teleports are skipped (see
	# CONTAINMENT_TELEPORT_SKIP). Pure value-type math, no allocation on the
	# per-tick path, and deterministic — client prediction and reconcile
	# replay resolve a rescue identically to the host.
	var xz := Vector2(state.transform.origin.x, state.transform.origin.z)
	var boundary_xz: Vector2 = GameRules.clamp_to_rink_inner(xz)
	var escape_depth: float = xz.distance_to(boundary_xz)
	if escape_depth > CONTAINMENT_EPSILON and escape_depth < CONTAINMENT_TELEPORT_SKIP:
		containment_rescue_count += 1  # Phase-0: true Jolt escape frequency (see the var)
		var inside_xz: Vector2 = GameRules.clamp_to_rink_inner(
				xz, GameRules.PUCK_COLLISION_RADIUS)
		state.transform.origin.x = inside_xz.x
		state.transform.origin.z = inside_xz.y
		var rescued: Vector3 = PuckCollisionRules.board_rescue_velocity(
				state.linear_velocity, (xz - boundary_xz) / escape_depth,
				GameRules.PUCK_BOARD_BOUNCE)
		if rescued != state.linear_velocity:
			state.linear_velocity = rescued
			# Mirror the contact path's board-hit feedback so the rescue
			# sounds/looks like the bounce it stands in for.
			if carrier == null and rescued.length() >= 1.0:
				puck_hit_boards.emit()
	if _clamp_at_goal_line:
		var z: float = state.transform.origin.z
		var goal_z: float = GameRules.GOAL_LINE_Z
		if abs(z) >= goal_z and z * state.linear_velocity.z > 0.0 \
				and abs(state.transform.origin.x) <= GameRules.NET_HALF_WIDTH:
			state.transform.origin.z = goal_z * sign(z)
			state.linear_velocity = Vector3.ZERO
	# Cache the velocity the puck carries out of this step — the save-deaden
	# classifier reads it as the pre-bounce incoming velocity, since
	# linear_velocity in _on_body_entered may already carry the restitution
	# response. Taken after all writes so it reflects a same-step release too.
	_pre_contact_velocity = state.linear_velocity

func _physics_process(delta: float) -> void:
	if not _is_server:
		return

	# Tick per-skater cooldowns regardless of carrier state. Keys are int
	# instance_ids; resolve back via instance_from_id and drop entries whose
	# skater has been freed (puppet bot teardown, etc.) alongside the
	# naturally-expired ones. The early-out keeps this fully skipped in the
	# no-cooldowns case; the reused _expired_cooldowns scratch avoids a per-tick
	# allocation while cooldowns are active (per-tick path).
	if not _cooldown_timers.is_empty():
		var now: float = _now()
		_expired_cooldowns.clear()
		for id: int in _cooldown_timers:
			var skater: Skater = instance_from_id(id) as Skater
			if not is_instance_valid(skater):
				_expired_cooldowns.append(id)
				continue
			# Expiry timestamps (local_time base), so drop once we pass them —
			# no per-tick decrement, and the sweep no longer depends on `delta`.
			if _cooldown_timers[id] <= now:
				_expired_cooldowns.append(id)
		for id: int in _expired_cooldowns:
			_cooldown_timers.erase(id)

	if carrier != null:
		_pending_elevation = false
		_pending_elevation_vel = Vector3.ZERO
		freeze = true
		# Pin at the carry target — same as blade contact when blade is
		# centered, but inverse-offset from the blade's actual position when
		# the IK shifted the marker for forehand/backhand carry. Result: puck
		# stays at the cursor while the blade renders to one side.
		global_position = carrier.get_carry_target_global()
		global_position.y = ice_height
	elif _analytic_drive_enabled:
		# Determinism migration: the analytic sim owns the loose puck (dev + host).
		_drive_analytic(delta)
	elif _pending_elevation:
		# Elevated release this frame: skip is_airborne() so linear_velocity.y
		# is not zeroed before _integrate_forces can apply _pending_elevation_vel.
		_pending_elevation = false
	elif not is_airborne():
		# Max-speed clamp already runs every physics substep in _integrate_forces.
		linear_velocity.y = 0.0
		position.y = ice_height
	elif sleeping and not freeze:
		# A loose airborne puck can only be supported by the goalie's body (the
		# puck mask excludes skater bodies) — e.g. a deadened save settling on
		# top of the butterfly pads. Jolt sleeping it there is a trap: the pads
		# are animated bodies, and kinematic support moving away never wakes a
		# slept body, so the puck would hang frozen in mid-air (a sleeping body
		# skips _integrate_forces, so even gravity stops). Keep a loose airborne
		# puck awake; the frozen case (goalie catch pin) is exempt by design.
		sleeping = false
