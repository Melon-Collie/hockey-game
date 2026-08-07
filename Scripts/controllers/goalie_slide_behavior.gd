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
# Push speed along the committed path, signed by `dir` (the name predates the
# path-normalized advance; pose hooks read |velocity_x| as slide intensity).
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
# spatial trigger check (the pad-coverage check in
# `GoalieController._try_commit_slide`).
func can_commit_slide() -> bool:
	return cooldown_timer >= slide_cooldown \
			and drop_progress >= 1.0 \
			and event_lockout <= 0.0

# Shortest committed path worth taking. Below this the slide would be a
# stationary re-drop on a seal the goalie is already sitting in.
const MIN_COMMIT_TRAVEL_M: float = 0.05

# Commit a new slide toward `target_x`. Captures arc endpoints + push-off
# direction. Post-seal depth scaling: more extreme lateral targets pull the
# goalie deeper so the sealing pad presses the post (backdoor coverage).
#
# Returns false — committing nothing — when he is ALREADY at the destination.
# That test is 2D on purpose: a goalie beaten in tight is often within a few
# centimetres of the seal's lateral spot while still a full stride out in DEPTH,
# and the seal he owes is the retreat to the post, not the sidestep. Measuring
# the lateral leg alone (the caller's old guard) declared that slide redundant
# and left him parked out at challenge depth with the tuck open — the same
# lateral-only reasoning about a 2D path that `advance_slide` documents.
func commit_slide(current_x: float, current_depth: float, target_x: float, net_half_width: float,
		coil_end_x: float, coil_end_depth: float) -> bool:
	var commit_dir: float = signf(target_x - current_x)
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
	if absf(target_x - current_x) < MIN_COMMIT_TRAVEL_M \
			and absf(depth_target - current_depth) < MIN_COMMIT_TRAVEL_M:
		return false
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
	dir = commit_dir
	arc_t = 0.0
	# Slide phase begins where the coil left off — the body has already
	# rotated around the pivot foot to (coil_end_x, coil_end_depth) by the
	# time push-off fires.
	start_x = coil_end_x
	start_depth = coil_end_depth
	end_x = target_x
	end_depth = depth_target
	return true

# Tick the COILING phase. Body lerps from (coil_start_x, coil_start_depth) to
# (start_x, start_depth) — the post-pivot-rotation position — as the coil
# timer drains. Returns the interpolated body (x, depth). When the coil timer
# hits zero this also applies push-off velocity so the next advance_slide()
# tick starts the translation phase with momentum; the controller should
# transition to State.SLIDING when `is_coil_complete()` reports true.
func tick_coil(delta: float) -> Vector2:
	if coil_timer <= 0.0:
		# Coil already done (or duration was zero); body sits at the
		# post-coil position.
		return Vector2(start_x, start_depth)
	coil_timer = maxf(coil_timer - delta, 0.0)
	if coil_timer == 0.0:
		# Coil completed this tick — arm push-off so the next advance_slide
		# tick starts the translation phase under momentum.
		velocity_x = dir * slide_initial_speed
		return Vector2(start_x, start_depth)
	var coil_progress: float = clampf(1.0 - coil_timer / coil_duration, 0.0, 1.0) \
			if coil_duration > 0.0 else 1.0
	return Vector2(
			lerpf(coil_start_x, start_x, coil_progress),
			lerpf(coil_start_depth, start_depth, coil_progress))

# True once the coil timer has expired and push-off has been applied. The
# controller polls this from State.COILING to transition into State.SLIDING.
func is_coil_complete() -> bool:
	return coil_timer <= 0.0


# Tick the translation phase of the slide. Returns the new (x, depth).
# Velocity decays via friction and drives arc progress (0→1) along the full
# 2D path (see the normalization note below); position is computed from arc
# progress rather than accumulated from velocity directly.
# Depth bows forward (sin(π·t)) at mid-arc, matching the "push out and settle"
# shape of a real pivot. When velocity falls below `slide_min_speed` the slide
# ends — caller should check `is_slide_finished()` after this call. Coil is
# handled separately by tick_coil() — this function assumes coil is already
# complete.
func advance_slide(delta: float, goal_center_x: float, net_half_width: float) -> Vector2:
	var decay: float = slide_friction * delta
	if velocity_x > 0.0:
		velocity_x = maxf(velocity_x - decay, 0.0)
	else:
		velocity_x = minf(velocity_x + decay, 0.0)
	# Progress normalizes by the FULL committed path length (lateral + depth),
	# not the lateral span alone. The seal targets clamp well inside the posts
	# (±(net_half_width − pad_edge_extent) ≈ ±0.36 m), so a slide committed
	# from challenge depth has a SHORT lateral leg and a metre-plus depth leg
	# back to the post seal — normalized by x alone, the depth rode the lateral
	# schedule and the body snapped backward at several times the push speed
	# (the "pinned back to the net" read). Path-normalized, the body translates
	# along the committed diagonal at the real push speed, so a deep slide is
	# visibly a slower, longer trip than a goal-line one.
	var span_x: float = end_x - start_x
	var span_depth: float = end_depth - start_depth
	var path_span: float = sqrt(span_x * span_x + span_depth * span_depth)
	if path_span > 0.001:
		arc_t = clampf(arc_t + absf(velocity_x) * delta / path_span, 0.0, 1.0)
	else:
		arc_t = 1.0
	var new_x: float = lerpf(start_x, end_x, arc_t)
	var new_depth: float = lerpf(start_depth, end_depth, arc_t) \
			+ slide_pivot_arc_depth * sin(PI * arc_t)
	new_x = clampf(new_x, goal_center_x - net_half_width, goal_center_x + net_half_width)
	# ARRIVAL ENDS THE SLIDE, not the decay of the push. Position is
	# `lerp(start, end, arc_t)`, so once arc_t saturates the body IS at the seal and
	# the leftover velocity moves nothing — it only runs the clock. Ending solely on
	# `|velocity_x| <= slide_min_speed` meant a short committed path finished
	# travelling long before the push had bled off, and the goalie sat pinned in
	# SLIDING for the remainder: he cannot recover (RECOVERING only fires from idle
	# BUTTERFLY) and cannot commit a new slide. Measured on a post seal off a lateral
	# beat — arrived 0.61 s, released 1.38 s, so 0.77 s frozen in the seal with the
	# rebound live. The second-effort push after a seal was unreachable for most of a
	# second, which is exactly the window a scramble lives in.
	#
	# The speed floor stays as the OTHER terminator: a push that decays before
	# covering its path has run out of slide, and snapping to the destination there
	# is the existing (short-)slide behaviour, unchanged.
	if arc_t >= 1.0 or absf(velocity_x) <= slide_min_speed:
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
func clamp_lateral_target(target_x: float, goal_center_x: float, net_half_width: float, edge_extent: float) -> float:
	var max_x: float = goal_center_x + (net_half_width - edge_extent)
	var min_x: float = goal_center_x - (net_half_width - edge_extent)
	return clampf(target_x, min_x, max_x)
