class_name Puck
extends Node3D

signal puck_released()
# `checker` is the defender who took the puck (poke / stick-lift / body-check),
# or null when no skater caused it (a goalie poke — no skater takeaway credit).
# Stat attribution credits the takeaway to the checker (the player who made the
# defensive play), not whoever recovers the loose puck.
signal puck_stripped(ex_carrier: Skater, checker: Skater)
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
# equal-mass baseline lands there at ~4 m/s closing (medium build, 0.65 transfer)
# while mass moves it honestly: a heavier checker strips at lower closing speed, a
# lighter one needs more. Below it (down to stagger_min 0.6) a hit still staggers
# the carrier but leaves the puck on his stick — a jarring bump, not a turnover.
@export var body_check_strip_threshold: float = 1.35
@export var body_check_puck_speed: float = 3.0           # soft-strip trickle pace along the hit line
@export var body_check_loose_speed: float = 0.8          # forward carry a full-strength hit leaves (puck drops loose at contact)
# Delivered impulse at which the strip fully deadens the puck (jarred dead at the
# carrier's feet). Re-anchored from 5.5 — which needed ~17 m/s closing at the 0.65
# transfer, so the deadening ramp never engaged in real play — down onto the
# reachable knockdown band, so a solid knockdown-grade check kills the puck dead.
@export var body_check_strip_ref_impulse: float = 3.5    # delivered impulse that fully deadens the strip (puck jarred dead)
@export var hit_pickup_cooldown: float = 0.6              # seconds victim cannot pick up after a hard hit
@export var hit_pickup_cooldown_threshold: float = 1.35   # delivered victim-impulse needed to apply hit pickup cooldown (see body_check_strip_threshold)
@export var body_block_dampen: float = 0.5
# Puck energy retention on an ACTIVE (shot-block crouch) block — lower than the passive
# dampen so a committed block kills more of the shot. Was SkaterController.active_block_dampen;
# consolidated here with the passive value now that on_body_block picks between them.
@export var body_block_active_dampen: float = 0.35
@export var body_block_cooldown: float = 0.1
# Vertical clamp: the puck's Y is capped at ice_height + max_height by the
# analytic step (PuckAuthorityRules). Must stay BELOW the rink's collision top
# (HockeyRink.COLLISION_OVERGLASS_TOP, 3.2 m) — otherwise an elevated deflection
# that pegs this clamp sits above the boards and escapes the rink. If you raise
# this, raise COLLISION_OVERGLASS_TOP to keep the margin.
@export var max_height: float = 3.0

# A puck further outside the rink boundary than this in a single step is a
# deliberate teleport (drill managers stash the puck at (100, 100) between
# attempts) and the analytic drive leaves it parked — the drill owns puck
# placement. Anything inside it is contained by construction: the shared step
# clamps the center to the rink's rounded rectangle every sub-step.
const CONTAINMENT_TELEPORT_SKIP: float = 2.0

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
# The puck's velocity store. The puck is a plain Node3D — no physics body, no
# engine integration — so this is just state the analytic drive (host) and the
# gameplay interactions (deflects, pokes, strips, sweeps) read and write; the
# name is kept from the RigidBody3D era so every external reader still works.
# On clients PuckController owns motion and this holds whatever the last
# prediction/seed wrote (position is the replicated truth).
var linear_velocity: Vector3 = Vector3.ZERO
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
# Full velocity queued by release()/nudge() for the analytic drive's next tick
# (get_release_velocity returns it until consumed), so same-frame consumers of
# the puck_released signal — and the drive itself — see the full XYZ launch
# vector (incl. loft vy) even though the release ran before the physics step.
var _pending_elevation_vel: Vector3 = Vector3.ZERO
# Built once from the save-deaden exports (rebuilt only on demand — exports don't
# change at runtime), so the per-save classification allocates nothing.
var _deaden_cfg: GoalieSaveRules.DeadenConfig = null
# Callable (Skater) -> int team_id, or -1 if the skater isn't registered. Set
# by GameManager at spawn time so Puck doesn't reach upward for team checks.
var _team_resolver: Callable = Callable()

func set_team_resolver(resolver: Callable) -> void:
	_team_resolver = resolver

# ── Analytic host drive (the ONE puck simulation) ─────────────────────────────
# The LOOSE puck is driven by the deterministic analytic sim on every host:
# integration + ice friction + gravity + board caroms (PuckAuthorityRules / step_puck_3d),
# goal-frame reflection (PuckGeometryCollision: posts / crossbar / top + back/side net), and
# goalie detection + response (GoalieContactDetector + GoalieSaveRules.resolve_contact).
# The puck is a plain Node3D — no physics engine ever touches it; gameplay pickup /
# deflect / poke / goal-detection are analytic too, and the drive emits every contact
# feedback signal itself. Clients never run this (_physics_process is host-only);
# they render through PuckController's shared-solver prediction.
var _goalie_provider: Callable = Callable()  # returns Array of live Goalie nodes for contact detection
# Sub-step ranges/counts and the goalie-detect gate live on PuckAuthorityRules —
# SHARED with the client's Phase-3 prediction so both sides step identically.
# Caller-owned scratch so the per-tick drive allocates nothing.
var _frame_result: PuckGeometryCollision.Result = null
var _goalie_contact: GoalieContactDetector.Contact = null
var _goalie_scratch: SweptDiscOBB.Result = null
var _save_result: GoalieSaveRules.ContactResult = null
var _tick_result: PuckAuthorityRules.TickResult = null
# Shared read-only empty (const arrays are frozen) — the no-goalies-in-range default
# every open-ice tick, instead of allocating a fresh `[]` per tick.
const _NO_GOALIES: Array = []
# Edge-trigger latches for the drive's contact signals: true = the matching contact
# occurred LAST tick, so a sustained contact re-fires nothing (Jolt's body_entered
# was edge-triggered per separation; the analytic tests are level-triggered).
var _contact_latch_boards: bool = false
var _contact_latch_post: bool = false
var _contact_latch_net: bool = false
var _contact_latch_goalie: bool = false
# Replay playback hold: the replay drivers own the puck transform while a goal /
# post-game replay plays — the drive must not simulate the loose puck underneath,
# so the drivers raise this for the playback's duration.
var _replay_hold: bool = false
# An external authority is actively positioning the puck THIS tick (the goalie
# pinning it under a glove / smother — see GoalieController). Distinct from
# pickup_locked: pickup_locked means "blades can't play it" and is true for every
# dead-puck phase (goal celebration, period end, whistle), but during those
# NOBODY owns the transform — the loose puck should keep coasting (bounce in the
# net after a goal, slide after the buzzer), the charm the Jolt RigidBody gave for
# free. Only motion_pinned (goalie pin) and _replay_hold freeze the drive; a mere
# pickup_lock lets the puck integrate to a natural rest while staying unplayable.
var motion_pinned: bool = false


# Raised by the goal / post-game replay drivers for the playback's duration: the
# driver scrubs recorded frames onto the live actors, and the analytic drive must
# not keep simulating the loose puck underneath (it would slide away and resume
# from wherever it drifted when playback ends).
func set_replay_hold(active: bool) -> void:
	_replay_hold = active

func set_goalie_provider(provider: Callable) -> void:
	_goalie_provider = provider

func _ready() -> void:
	process_physics_priority = 1  # Run after Skater.move_and_slide so blade world pos is current
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
	# The host drives the loose puck analytically every tick — build the drive's
	# reusable scratch once (the per-tick path must allocate nothing).
	if is_server and _frame_result == null:
		_frame_result = PuckGeometryCollision.Result.new()
		_goalie_contact = GoalieContactDetector.Contact.new()
		_goalie_scratch = SweptDiscOBB.Result.new()
		_save_result = GoalieSaveRules.ContactResult.new()
		_tick_result = PuckAuthorityRules.TickResult.new()

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
# set_puck_position + velocity=0 it also clears any queued release/elevation
# velocity, so a fast missed puck can't carry momentum into the next rep (the
# "velocity carries over" annoyance).
func stage_at(pos: Vector3) -> void:
	if carrier != null:
		drop()
	global_position = pos
	linear_velocity = Vector3.ZERO
	_pending_elevation_vel = Vector3.ZERO

# Direct-velocity launch used by the tutorial's staged pucks. Applies the
# same _pending_elevation_vel treatment as release() so the drive's next tick
# (and same-frame get_release_velocity readers) get the full XYZ vector.
func apply_release_velocity(vel: Vector3) -> void:
	linear_velocity = vel
	if vel.y > 0.0:
		_pending_elevation_vel = vel

func get_carrier() -> Skater:
	return carrier

# Returns linear_velocity, OR _pending_elevation_vel when release()/nudge() has
# just queued a launch the drive hasn't consumed yet. Use this from same-frame
# consumers of the puck_released signal — `linear_velocity` may still read the
# pre-release (carried ≈ zero) value in that window.
func get_release_velocity() -> Vector3:
	if not _pending_elevation_vel.is_zero_approx():
		return _pending_elevation_vel
	return linear_velocity

func set_carrier(skater: Skater) -> void:
	carrier = skater

func clear_carrier() -> void:
	carrier = null

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
	puck_stripped.emit(ex_carrier, checker)
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
	puck_stripped.emit(ex_carrier, checker_skater)
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
	puck_stripped.emit(ex_carrier, checker_skater)
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
	# No skater checker — a goalie strip earns no player takeaway credit.
	puck_stripped.emit(ex_carrier, null)
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
	linear_velocity = sweep_velocity


func release(direction: Vector3, power: float) -> void:
	var ex_carrier: Skater = carrier
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
# gap. Reuses _pending_elevation_vel so the drive's next tick launches with
# the full nudge vector.
func nudge(velocity: Vector3) -> void:
	var ex_carrier: Skater = carrier
	if ex_carrier != null:
		global_position = ex_carrier.get_blade_contact_global()
	global_position.y = ice_height
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
	# puck doesn't inherit it and rocket off on the drive's next tick.
	_pending_elevation_vel = Vector3.ZERO
	if ex_carrier != null:
		_set_cooldown(ex_carrier, reattach_cooldown)
	puck_released.emit()

func reset(at_xz: Vector2 = Vector2.ZERO) -> void:
	carrier = null
	_cooldown_timers.clear()
	linear_velocity = Vector3.ZERO
	# Discard any release velocity queued this frame — a faceoff / whistle reset
	# must not inherit a shot fired on the same tick (would launch the dot puck).
	_pending_elevation_vel = Vector3.ZERO
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

# Host-only analytic drive for one tick of the LOOSE puck — the one and only
# puck simulation. Position + velocity are written directly on the Node3D.
func _drive_analytic(dt: float) -> void:
	# Faceoff / reset staging.
	if _pending_reset:
		_pending_reset = false
		global_position = Vector3(_pending_reset_xz.x, ice_height, _pending_reset_xz.y)
		linear_velocity = Vector3.ZERO
		_pending_reset_xz = Vector2.ZERO
		return
	# Pinned puck (goalie cover / glove hold) and replay playback: the pinning
	# authority (GoalieController re-pins the position every tick; the replay driver
	# scrubs recorded frames) owns the transform — the drive must not integrate
	# gravity or collision against it. Without this gate the drive fought the glove
	# pin every tick (re-detecting the held puck inside the glove box and re-firing
	# puck_touched_goalie at 120 Hz).
	# NOTE: pickup_locked is deliberately NOT a freeze condition. A dead-puck phase
	# (goal celebration, period end, whistle) locks pickup but has no transform
	# owner, so the loose puck keeps coasting — friction, board caroms and net
	# reflections still run, and it settles to a natural rest instead of stopping
	# dead mid-flight. Blades/bots still see it as unplayable via pickup_locked.
	if motion_pinned or _replay_hold:
		_contact_latch_goalie = false
		_contact_latch_post = false
		_contact_latch_net = false
		_contact_latch_boards = false
		return
	# Deliberate far teleport (drills stash the puck off-rink between reps): leave it parked,
	# matching the CONTAINMENT_TELEPORT_SKIP guard in the Jolt path.
	var here := Vector2(global_position.x, global_position.z)
	if here.distance_to(GameRules.clamp_to_rink_inner(here)) > CONTAINMENT_TELEPORT_SKIP:
		return
	var prev: Vector3 = global_position
	# Authoritative velocity: get_release_velocity() returns the queued shot/nudge vector on a
	# release tick (full XYZ incl. loft vy) and linear_velocity otherwise — so every analytic
	# interaction that writes linear_velocity mid-flight (deflect, poke, strip, sweep, body
	# block) is picked up.
	var incoming: Vector3 = get_release_velocity()
	_pending_elevation_vel = Vector3.ZERO  # consumed

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
	var goalie_range: bool = absf(prev.z) > GameRules.GOAL_LINE_Z - PuckAuthorityRules.GOALIE_DETECT_RANGE_Z
	# _NO_GOALIES (a shared read-only const), not a `[]` literal — this line runs
	# every loose-puck tick and a fresh Array per tick is exactly the hot-path
	# allocation churn CLAUDE.md forbids.
	var goalies: Array = _NO_GOALIES
	if goalie_range and not _goalie_provider.is_null():
		goalies = _goalie_provider.call()
	var substeps: int = PuckAuthorityRules.frame_substeps(prev.z, incoming.length(), dt)
	var sub_dt: float = dt / float(substeps)
	var pos: Vector3 = prev
	var vel: Vector3 = incoming
	# Per-tick contact occurrence, latched across ticks so sustained contact
	# (grinding a post, a puck resting against a pad) emits ONCE like Jolt's
	# edge-triggered body_entered did — not per sub-step per tick. The physics
	# response still applies every sub-step; only the SIGNALS are edge-gated
	# (each emit fans out to sounds / RPCs / stat sync, so a level-triggered
	# re-fire was up to 120 RPCs/s during held contact).
	var touched_post: bool = false
	var touched_net: bool = false
	var touched_goalie: bool = false
	# Emissions are DEFERRED to after the commit below: synchronous listeners
	# (the save sound reading puck velocity, stat sync) must see this tick's
	# committed post-contact state, not last tick's — Jolt's body_entered fired
	# mid-step with current state; emitting mid-loop here read stale fields.
	var emit_goalie: Goalie = null
	var emit_caught: Goalie = null
	for _sub in substeps:
		var sub_prev: Vector3 = pos
		# Integration + boards + goal frame: the SHARED Phase-3 step (identical on
		# the client's prediction path), so static-geometry motion agrees by
		# construction. Touched flags OR-accumulate; clear per sub-step read.
		_tick_result.touched_post = false
		_tick_result.touched_net = false
		PuckAuthorityRules.step_frame_substep(pos, vel, sub_dt, radius,
				max_speed, ice_height, max_height, _frame_result, _tick_result)
		pos = _tick_result.position
		vel = _tick_result.velocity
		if _tick_result.touched_post:
			touched_post = true
		if _tick_result.touched_net and incoming.length() >= 1.0:
			touched_net = true
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
			# Eject the disc flush off the contacted face. `point` is the sphere
			# CENTRE at toi — already `radius` off the real face via the
			# Minkowski-expanded box — so only the start-inside depenetration
			# `depth` is added (adding `radius` again parked the puck ~13 cm off
			# every save, a visible pop).
			pos = _goalie_contact.point + _goalie_contact.normal * _goalie_contact.depth
			if not _contact_latch_goalie and not touched_goalie:
				emit_goalie = _goalie_contact.goalie as Goalie
			# The catch is gated on its own occurrence, NOT the touch latch — a
			# pad-contact tick followed by a glove catch next tick must still
			# fire the catch (it pins the puck and locks the play through the
			# goalie controller).
			if _save_result.caught and emit_caught == null:
				emit_caught = _goalie_contact.goalie as Goalie
			touched_goalie = true
	# Board feedback: a real carom is the raw (un-reflected) full-tick position crossing the
	# boundary with into-board pace — a puck sliding parallel doesn't fire. Latched like the
	# other contacts (a rim-around can re-cross the raw boundary every tick of the curve —
	# one carom must read as one thud, not a 120 Hz burst).
	var raw := Vector2(prev.x + incoming.x * dt, prev.z + incoming.z * dt)
	var touched_boards: bool = raw.distance_to(GameRules.clamp_to_rink_inner(raw)) > 0.001 \
			and incoming.length() >= 1.0

	# 4) Commit. The puck can never sit below the ice — re-homes the Jolt path's grounded
	# `position.y = ice_height` pin, and catches a goalie eject / save whose normal drove the
	# disc down into the surface (the "puck in the ice, only the shadow shows" bug).
	if pos.y < ice_height:
		pos.y = ice_height
		if vel.y < 0.0:
			vel.y = 0.0
	# linear_velocity is the authoritative store, so gameplay readers
	# (get_puck_velocity, AI, HUD) and next tick's interactions see it.
	linear_velocity = vel
	global_position = pos

	# Deferred contact signals (see the emit_* locals above): edge-gated by the
	# cross-tick latches, fired against the committed state. Order matters — the
	# goalie touch fires before the catch (the controller relies on that
	# sequence to transition the catching goalie first).
	if touched_boards and not _contact_latch_boards:
		puck_hit_boards.emit()
	if touched_post and not _contact_latch_post:
		puck_touched_post.emit()
	if touched_net and not _contact_latch_net:
		puck_hit_goal_body.emit()
	if emit_goalie != null:
		puck_touched_goalie.emit(emit_goalie)
	if emit_caught != null:
		puck_caught_by_goalie.emit(emit_caught)
	_contact_latch_boards = touched_boards
	_contact_latch_post = touched_post
	_contact_latch_net = touched_net
	_contact_latch_goalie = touched_goalie


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
		_pending_elevation_vel = Vector3.ZERO
		# Pin at the carry target — same as blade contact when blade is
		# centered, but inverse-offset from the blade's actual position when
		# the IK shifted the marker for forehand/backhand carry. Result: puck
		# stays at the cursor while the blade renders to one side.
		global_position = carrier.get_carry_target_global()
		global_position.y = ice_height
	else:
		# The analytic sim owns the loose puck on every host.
		_drive_analytic(delta)
