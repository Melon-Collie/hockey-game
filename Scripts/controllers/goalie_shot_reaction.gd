class_name GoalieShotReaction
extends RefCounted

# Reaction-freeze state: the goalie tracks up to release, then commits to
# their read and processes the outcome. While frozen, lateral movement and
# body rotation are suppressed; only body-part reactions (butterfly drop,
# glove/blocker reach) proceed. The freeze ends on a discrete resolving event
# (puck contact / boards / post / net / pickup) plus a short clear delay, or
# via a safety-net duration cap.
#
# Two parallel processing delays after release:
#   `shot_timer`     ≈ reaction_delay     — gates the butterfly drop on low shots
#   `arm_timer`      ≈ arm_reaction_delay — gates the glove/blocker reach on elevated shots
# Arms take longer than legs (close-range top-corner shots can score because
# the arm doesn't even start moving in time).

# ── Tuning (set by controller from exports in setup()) ───────────────────────
var reaction_delay: float = 0.13
var arm_reaction_delay: float = 0.18
var max_reaction_duration: float = 1.5
var reaction_clear_delay: float = 0.25
# Faster clear used when the puck actually CONTACTS this goalie (a save). The
# read is over the instant the goalie feels the save, so the freeze lifts quickly
# and the goalie can play the rebound — a slow full `reaction_clear_delay` left
# the goalie frozen in the crease while a rebound sat in the slot. Non-save
# resolutions (boards / post / net / pickup) keep the deliberate longer beat.
var save_clear_delay: float = 0.08

# ── Runtime state ────────────────────────────────────────────────────────────
var reacting: bool = false
var impact_x: float = 0.0
var impact_y: float = 0.0
var is_elevated: bool = false
var shot_timer: float = 0.0
var arm_timer: float = 0.0
var age: float = 0.0
# >= 0 → counting down to clear. -1 → not yet armed (no resolving event seen).
var clear_timer: float = -1.0

# Emitted host-side when a reaction starts; the controller hooks this to arm the
# slide lockout. Clients render the goalie purely from the interpolated host
# pose broadcast, so no client-facing reaction signal/RPC is needed.
signal started(impact_x: float, impact_y: float, is_elevated: bool)

func reset() -> void:
	reacting = false
	impact_x = 0.0
	impact_y = 0.0
	is_elevated = false
	shot_timer = 0.0
	arm_timer = 0.0
	age = 0.0
	clear_timer = -1.0

# Host-side: start a fresh reaction. `delay` is the per-shot reaction delay
# returned by `GoalieBehaviorRules.detect_shot` (usually `reaction_delay`).
# `back_date_s` lag-comps client-initiated releases: when the host receives a
# release RPC carrying client timestamp T, it passes `now - T` (≈ one-way
# latency) so the goalie's reaction window matches what the shooter
# perceived locally. Local host shots pass 0.0.
# Emits `started` so the controller can fire the RPC and arm the slide lockout.
# `read_delay_s` is extra latency before the goalie picks up the shot, from any
# source — a screen blocking the sightline, or being caught moving / unset at
# release. It pushes BOTH processing timers back: the goalie reads the leg drop
# AND the arm reach late.
# `arm_delay_cut_s` is the anticipation credit on the ARM read (the legs' credit
# arrives via a reduced `delay`): a set goalie who has been reading a visible
# windup has pre-programmed the response during the fixation (quiet-eye), so both
# limbs start sooner. Never cuts below zero.
func start(new_impact_x: float, new_impact_y: float, elevated: bool, delay: float,
		back_date_s: float = 0.0, read_delay_s: float = 0.0, arm_delay_cut_s: float = 0.0) -> void:
	# Cap back-date at 0.5s. Beyond that the connection is too rough for fair
	# lag-comp and we'd be starting reactions already past the puck-impact
	# moment, which looks like teleporting saves on the shooter's view.
	back_date_s = clampf(back_date_s, 0.0, 0.5)
	read_delay_s = maxf(read_delay_s, 0.0)
	impact_x = new_impact_x
	impact_y = new_impact_y
	is_elevated = elevated
	reacting = true
	age = back_date_s
	clear_timer = -1.0
	shot_timer = maxf(delay + read_delay_s - back_date_s, 0.0)
	arm_timer = maxf(arm_reaction_delay - maxf(arm_delay_cut_s, 0.0) \
			+ read_delay_s - back_date_s, 0.0)
	started.emit(impact_x, impact_y, is_elevated)

# Tick the shot/arm processing delays. Both decrement toward zero (clamped).
# The drop DECISION is split into `low_drop_ready` so the controller can gate
# the actual butterfly entry on shot imminence — a release is read instantly,
# but the leg drop waits until the puck is closing on the net (see
# GoalieController._update_shot_timer).
func tick_processing_timers(delta: float) -> void:
	if arm_timer > 0.0:
		arm_timer = maxf(arm_timer - delta, 0.0)
	if shot_timer > 0.0:
		shot_timer = maxf(shot_timer - delta, 0.0)

# True while the reflexive low-shot leg drop is eligible: actively reacting to
# a non-elevated shot whose processing delay has elapsed, with the goalie still
# upright. Level (not edge) — stays true every tick until the goalie drops or
# the reaction clears, so the controller can defer the drop until the puck is
# imminent and still fire it on a later tick.
func low_drop_ready(is_upright: bool) -> bool:
	return reacting and shot_timer <= 0.0 and not is_elevated and is_upright

# Tick the reaction-freeze countdown. Returns true if the freeze just cleared
# this call (clear-timer fired or duration cap hit).
#   carrier_present: true if there's now a puck-carrier (pickup happened) —
#                    arms the clear timer if not already armed.
func tick_freeze(delta: float, carrier_present: bool) -> bool:
	if not reacting:
		return false
	if carrier_present and clear_timer < 0.0:
		clear_timer = reaction_clear_delay
	if clear_timer >= 0.0:
		clear_timer -= delta
		if clear_timer <= 0.0:
			finish()
			return true
	age += delta
	if age >= max_reaction_duration:
		finish()
		return true
	return false

# Arm the post-event clear timer (puck contact / boards / post / net hit).
# No-op if not currently reacting, or if the clear timer is already armed
# (first event wins). `fast` uses the shorter `save_clear_delay` — passed by the
# save-contact path so the goalie unfreezes quickly to play the rebound; other
# resolving events keep the longer `reaction_clear_delay` beat.
func arm_clear(fast: bool = false) -> void:
	if not reacting:
		return
	if clear_timer < 0.0:
		clear_timer = save_clear_delay if fast else reaction_clear_delay

# Centralised reaction-clear. Every host-side cleanup path goes through here.
func finish() -> void:
	if not reacting:
		return
	reacting = false
	is_elevated = false
	clear_timer = -1.0

# Re-projection saw the elevated shot tip down to a low shot — start the
# butterfly drop timer (still allowed during freeze; arms-and-drop are the
# body reactions the freeze permits).
func tip_to_low(delay: float) -> void:
	if is_elevated and shot_timer <= 0.0:
		is_elevated = false
		shot_timer = delay

# Update the predicted impact, RE-CLASSIFYING the save family from the new height.
#
# The re-classification matters because the goalie's read can now be wrong from
# the start (GoalieController.read_lag): a shooter who sells a low shot and fires
# high has him committed to a non-elevated save, and without this he would stay
# committed for the whole flight — the arm would never deploy however clearly he
# came to see the puck rising. That is not a goalie being beaten, it is a goalie
# who cannot change his mind, and it made height deception unconditionally fatal
# at every range.
#
# A late low→elevated flip costs `late_arm_delay` before the reach engages. The
# caller passes the PRIMED read, not the cold one: he has had the puck in view the
# whole flight, so he is re-targeting an ongoing fixation rather than starting a
# read from nothing — the same credit any fixated goalie gets. In tight he still
# has no chance, which is the point; from distance he gets the honest late glove
# attempt a real goalie makes. The elevated→low direction stays owned by `tip_to_low`, which
# re-arms the leg timer the same way.
func update_impact(x: float, y: float, elevated_threshold: float = INF,
		late_arm_delay: float = 0.0) -> void:
	impact_x = x
	impact_y = y
	if is_inf(elevated_threshold):
		return
	if y >= elevated_threshold and not is_elevated:
		is_elevated = true
		arm_timer = maxf(arm_timer, late_arm_delay)

func arm_pending() -> bool:
	return arm_timer > 0.0
