class_name GoalieSlideBehavior
extends RefCounted

# Butterfly drop animation + committed pivot-slide state. Real goalies plant
# the outside (non-post) leg, pivot off it, and ride the sealing leg through
# to the post — the body rotates around the push-off foot rather than
# translating laterally. Destination is committed at slide-start; mid-slide
# cannot correct. That's the realism win: fast cross-passes beat the slide
# because the goalie already committed the read.
#
# The controller owns state-machine transitions. This collaborator owns the
# numeric state of "are we sliding, and how far along the arc are we?" plus
# the butterfly drop animation timers shared with the idle butterfly pose.

# ── Tuning (set by controller from exports in setup()) ───────────────────────
var slide_initial_speed: float = 4.5
var slide_friction: float = 6.0
var slide_min_speed: float = 0.3
var slide_cooldown: float = 0.20
var slide_pivot_arc_depth: float = 0.04
var post_seal_depth: float = 0.10
# Pad edge extent: distance from body center to the OUTER edge of a splayed
# butterfly pad. Slide targets aim for `post - pad_edge_extent` so the visible
# pad edge lands on the post. Set by the controller (pad_local_offset +
# butterfly_pad_half_width).
var pad_edge_extent: float = 0.56
var post_event_slide_lockout: float = 0.25
# Coil phase duration. The slide is two-phase: COIL (body rotates in place,
# loading weight on the far leg) → SLIDE (body translates linearly toward
# the seal target). Reads as a deliberate plant-and-push motion instead of
# the body teleporting laterally with rotation lerping independently.
var coil_duration: float = 0.12
var butterfly_drop_speed: float = 0.08
var butterfly_min_hold_time: float = 0.35

# ── Runtime state ────────────────────────────────────────────────────────────
var velocity_x: float = 0.0
# Committed arc endpoints, captured at slide-start; advance_slide interpolates
# along these. Persist so animation hooks (pose builder) can read `dir` even
# after velocity decays to 0.
var dir: float = 0.0           # ±1, committed slide direction
var arc_t: float = 0.0         # 0→1 progress along the committed span
# start_x/start_depth are the SLIDE-PHASE start — i.e. the body's position
# after the coil completes. coil_start_x/coil_start_depth are where the body
# was AT commit (before the coil rotation moved it around the pivot foot).
var start_x: float = 0.0
var start_depth: float = 0.0
var end_x: float = 0.0
var end_depth: float = 0.0
var coil_start_x: float = 0.0
var coil_start_depth: float = 0.0
# Coil phase countdown. > 0 means we're still rotating around the pivot
# foot; advance_slide() lerps the body's position from (coil_start_x,
# coil_start_depth) to (start_x, start_depth) over this window. When it hits
# zero, push-off velocity is applied and the translation phase begins.
var coil_timer: float = 0.0
# Butterfly cycle timers. drop_progress drives the pads-to-floor animation;
# hold_timer counts butterfly time toward `butterfly_min_hold_time` before
# recovery can fire.
var drop_progress: float = 0.0
var hold_timer: float = 0.0
# Inter-slide cooldown (ticks every frame regardless of state). Event lockout
# suppresses slides for a beat after a shot release or puck contact so the
# goalie processes the outcome before reacting to a new lateral threat.
var cooldown_timer: float = 0.0
var event_lockout: float = 0.0

func reset() -> void:
	velocity_x = 0.0
	dir = 0.0
	arc_t = 0.0
	start_x = 0.0
	start_depth = 0.0
	end_x = 0.0
	end_depth = 0.0
	coil_start_x = 0.0
	coil_start_depth = 0.0
	drop_progress = 0.0
	hold_timer = 0.0
	cooldown_timer = 0.0
	event_lockout = 0.0
	coil_timer = 0.0

# Fresh butterfly entry resets timers + slide state. Called when entering
# BUTTERFLY from anywhere EXCEPT a finished SLIDING — slide→butterfly preserves
# the accumulated hold time and drop progress so the slide is part of the same
# butterfly cycle.
func enter_fresh_butterfly() -> void:
	drop_progress = 0.0
	hold_timer = 0.0
	cooldown_timer = 0.0
	event_lockout = 0.0
	coil_timer = 0.0
	dir = 0.0
	arc_t = 0.0
	velocity_x = 0.0

# Arm the event lockout (puck contact / shot release suppression window).
# `maxf` so a later, faster event can't shorten an in-progress lockout —
# first event wins.
func arm_event_lockout() -> void:
	event_lockout = maxf(event_lockout, post_event_slide_lockout)

# Per-frame: tick the inter-slide cooldown. Runs every frame regardless of
# state so the cooldown advances between slides whether the goalie is up or
# down.
func tick_cooldown(delta: float) -> void:
	cooldown_timer += delta

# Per-frame BUTTERFLY/SLIDING: advance hold timer, drop animation, and the
# event lockout countdown. Drop progress converges in `butterfly_drop_speed`
# seconds so pads visibly close before slide triggers unlock.
func tick_butterfly(delta: float) -> void:
	hold_timer += delta
	drop_progress = minf(drop_progress + delta / maxf(butterfly_drop_speed, 0.001), 1.0)
	if event_lockout > 0.0:
		event_lockout -= delta

# True when the butterfly cycle has held at least `butterfly_min_hold_time`.
# Caller still checks "threat pressing" before transitioning to RECOVERING.
func can_recover() -> bool:
	return hold_timer >= butterfly_min_hold_time

# True when the slide-trigger gate is open (cooldown elapsed, drop animation
# finished, no in-progress event lockout). Caller is responsible for the
# spatial trigger check (`GoalieBehaviorRules.should_commit_slide`).
func can_commit_slide() -> bool:
	return cooldown_timer >= slide_cooldown \
			and drop_progress >= 1.0 \
			and event_lockout <= 0.0

# Commit a new slide toward `target_x`. Captures arc endpoints + push-off
# direction. Post-seal depth scaling: more extreme lateral targets pull the
# goalie deeper so the sealing pad presses the post (backdoor coverage).
func commit_slide(current_x: float, current_depth: float, target_x: float, net_half_width: float,
		coil_end_x: float, coil_end_depth: float) -> void:
	var commit_dir: float = signf(target_x - current_x)
	# Start in COIL phase: body lerps from (current_x, current_depth) — captured
	# as coil_start_* — to (coil_end_x, coil_end_depth) as it rotates around the
	# pivot foot. The slide phase then translates from (coil_end_x, coil_end_depth)
	# — which is also start_x/start_depth — to the seal target. Push-off velocity
	# is applied in advance_slide() when coil_timer hits zero.
	velocity_x = 0.0
	coil_timer = coil_duration
	coil_start_x = current_x
	coil_start_depth = current_depth
	cooldown_timer = 0.0
	# Extremity is measured against the SLIDE CLAMP LIMIT (the puck-side
	# post-pad-edge, where target_x is already clamped to), not the post
	# position. The old normalization (absf(target_x) / net_half_width) capped
	# extremity at ~0.54 even on a full post-to-post slide because the clamp
	# eats half the range — so the depth pull toward post_seal_depth barely
	# fired and the slide looked nearly lateral instead of angling back to the
	# post. Normalizing against the clamp limit means a wide slide goes fully
	# back to post_seal_depth, giving the angled path real goalies use when
	# diving from an aggressive depth.
	var clamp_limit: float = maxf(net_half_width - pad_edge_extent, 0.001)
	var x_extremity: float = clampf(absf(target_x) / clamp_limit, 0.0, 1.0)
	var depth_target: float = lerpf(coil_end_depth, post_seal_depth, x_extremity)
	dir = commit_dir
	arc_t = 0.0
	# Slide phase begins where the coil left off — the body has already
	# rotated around the pivot foot to (coil_end_x, coil_end_depth) by the
	# time push-off fires.
	start_x = coil_end_x
	start_depth = coil_end_depth
	end_x = target_x
	end_depth = depth_target

# Tick the active slide. Returns the new (x, depth). Velocity decays via
# friction and drives arc progress (0→1); position is computed from arc
# progress rather than accumulated from velocity directly. Depth bows forward
# (sin(π·t)) at mid-arc, matching the "push out and settle" shape of a real
# pivot. When velocity falls below `slide_min_speed` the slide ends — caller
# should check `is_slide_finished()` after this call.
func advance_slide(delta: float, goal_center_x: float, net_half_width: float) -> Vector2:
	# COIL phase: body lerps from (coil_start_x, coil_start_depth) to
	# (start_x, start_depth) — the rotation-around-pivot-foot end position —
	# as the coil timer drains. When it hits zero, push-off velocity is applied
	# and we fall through to translation immediately so the slide doesn't
	# stall for one tick.
	if coil_timer > 0.0:
		coil_timer = maxf(coil_timer - delta, 0.0)
		if coil_timer > 0.0 and coil_duration > 0.0:
			var coil_progress: float = clampf(1.0 - coil_timer / coil_duration, 0.0, 1.0)
			return Vector2(
					lerpf(coil_start_x, start_x, coil_progress),
					lerpf(coil_start_depth, start_depth, coil_progress))
		# Coil just completed this frame — push off.
		velocity_x = dir * slide_initial_speed
	var decay: float = slide_friction * delta
	if velocity_x > 0.0:
		velocity_x = maxf(velocity_x - decay, 0.0)
	else:
		velocity_x = minf(velocity_x + decay, 0.0)
	var x_span: float = absf(end_x - start_x)
	if x_span > 0.001:
		arc_t = clampf(arc_t + absf(velocity_x) * delta / x_span, 0.0, 1.0)
	else:
		arc_t = 1.0
	var new_x: float = lerpf(start_x, end_x, arc_t)
	var new_depth: float = lerpf(start_depth, end_depth, arc_t) \
			+ slide_pivot_arc_depth * sin(PI * arc_t)
	new_x = clampf(new_x, goal_center_x - net_half_width, goal_center_x + net_half_width)
	if absf(velocity_x) <= slide_min_speed:
		velocity_x = 0.0
		arc_t = 1.0
		new_x = end_x
		new_depth = end_depth
		cooldown_timer = 0.0
	return Vector2(new_x, new_depth)

func is_slide_finished() -> bool:
	return velocity_x == 0.0 and arc_t >= 1.0

# Slide destination clamps to "diving pad EDGE even with post" — the lead pad's
# outer edge lands on the post rather than overhanging it. Threats heading wide
# park the lead pad at the post (sealed with the edge, no wasted overhang).
# Threats mid-net track threat.x directly.
func clamp_lateral_target(target_x: float, goal_center_x: float, net_half_width: float, pad_edge_extent: float) -> float:
	var max_x: float = goal_center_x + (net_half_width - pad_edge_extent)
	var min_x: float = goal_center_x - (net_half_width - pad_edge_extent)
	return clampf(target_x, min_x, max_x)
