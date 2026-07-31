class_name BotSprintRules

# Pure decision: should an AI bot hold sprint (Shift) this tick?
#
# Sprint is a stamina-gated top-speed burst — it raises the speed cap and
# thrust but WIDENS the turn radius (sprint_turn_multiplier) and drains the
# stamina pool (faster while carrying). So a smart bot sprints to CLOSE
# DISTANCE in roughly straight lines — racing to a loose puck, backchecking,
# breaking out up-ice, forechecking from depth — and conserves when it needs
# agility (positioning near its anchor, dangling through traffic) or when a
# sharp turn would make the wide sprint arc overshoot.
#
# The function is pure and deterministic from its inputs, so the bot's sprint
# choice survives reconcile replay alongside the rest of its synthesized input.
# The hard exhaustion lockout (empty → locked until regen past half) is owned
# by StaminaRules on the controller; this rule only layers the bot's
# *discretionary* engage/sustain logic on top — it never needs to re-derive
# the lockout, just respect the replicated `sprint_locked` flag.
#
# To retune: every knob below is a tunable constant. The gap band
# (ENGAGE/SUSTAIN) controls how committed the bot is to a sprint once started;
# the turn gate controls how straight a line it demands before paying the
# wide-arc cost.

# Minimum gap (m) to the steering target before STARTING a sprint is worth it.
# Below this the bot is arriving / fine-positioning and wants agility, not top
# speed. ~0.7 s of skating at the 9 m/s default top speed.
const GAP_ENGAGE_M: float = 6.0
# Once sprinting, keep it until the gap closes inside this smaller radius.
# Hysteresis band (ENGAGE → SUSTAIN) stops the bot toggling sprint on/off as it
# skates the last few metres up to a target.
const GAP_SUSTAIN_M: float = 3.0

# Stamina floor (0..1) to START a sprint. Keeps a bot from spending its last
# reserves on a non-critical chase and immediately tripping the controller's
# hard lockout. There is deliberately NO floor to SUSTAIN — once committed, the
# bot rides the burst down to the controller's exhaustion lockout rather than
# bailing at an arbitrary fraction (which would look like indecision).
const STAMINA_ENGAGE_FLOOR: float = 0.2

# Turn gate. Sprint widens the turn radius, so suppress it when the desired
# heading diverges sharply from current velocity — the bot would carve a wide
# arc and overshoot. Only applies once actually moving (below
# TURN_GATE_SPEED_M_S the bot is accelerating from near-rest, where a heading
# change is cheap and the burst should fire to build speed). cos(70°).
const TURN_ALIGN_MIN_DOT: float = 0.34
const TURN_GATE_SPEED_M_S: float = 3.0


# ── Read-side sprint model (race_speed) ──────────────────────────────────────
# Default stamina tuning mirrored for the READ side (the live pool runs the
# controller's exported StaminaConfig; league defaults here — per-peer stamina
# itself is replicated, the drain RATE is a league constant to the observer).
static var _read_stamina_cfg := StaminaRules.StaminaConfig.new()


# Effective top speed a skater delivers over a committed straight-line RACE of
# `dist` metres — the sprint model the body actually runs (the should_sprint
# gates above + StaminaRules' pool), collapsed to one cruise-equivalent cap
# for the ETA phase model. Without this every AI race read was Speed-blind:
# cruise speed is near-uniform by design (the attribute doc), the sprint
# ceiling is where Speed's separation lives, and the body sprints its races
# while the read priced cruise (~0.3 s off on a 3 s race — larger than the
# the race-read and kill-setup margins).
#
#   - locked out, or pool below the engage floor, or the race shorter than
#     the sprint engage gap → cruise (the bot genuinely won't sprint it).
#   - else: sprint at cruise × sprint_mult while the pool sustains it
#     (t_burst = stamina / drain), cruise for the remainder — returned as
#     the exact two-phase distance-weighted average speed.
#
# Approximations, both conservative-or-neutral: the ramp to the higher cap is
# charged at normal thrust (sprint's ×1.2 thrust bump is ignored), and the
# turn gate is ignored (races are priced as straight lines; a race the body
# refuses to sprint because it starts misaligned resolves over the first
# re-evaluation). Carriers don't sprint (no breakaway modelling here) — race
# consumers are loose-puck reads, where every racer is a non-carrier.
static func race_speed(cruise_vmax: float, sprint_mult: float,
		stamina: float, sprint_locked: bool, dist: float) -> float:
	if sprint_locked or sprint_mult <= 1.0 \
			or stamina < STAMINA_ENGAGE_FLOOR or dist < GAP_ENGAGE_M:
		return cruise_vmax
	var v_sprint: float = cruise_vmax * sprint_mult
	var t_burst: float = stamina / maxf(_read_stamina_cfg.drain_per_sec, 0.001)
	var d_sprint: float = v_sprint * t_burst
	if d_sprint >= dist:
		return v_sprint
	# Two-phase average: sprint covers d_sprint in t_burst, cruise covers the
	# rest — total distance over total time.
	var total_t: float = t_burst + (dist - d_sprint) / maxf(cruise_vmax, 0.001)
	return dist / maxf(total_t, 0.001)


# `was_sprinting` is last tick's decision (drives the gap hysteresis band).
# `desired_move` is the steering output for this tick (a direction; length may
# be < 1 when softened). `carrying` + `breakaway` gate the puck carrier: a
# carrier only sprints on a clear breakaway, because carrying drains stamina
# ~1.6× faster and dangling through traffic needs the agility sprint sacrifices.
# `facing_xz` is the bot's current body facing (world XZ packed as Vector2 like
# SkaterNetworkState.facing); ZERO skips the facing gate (unwired callers/tests).
static func should_sprint(
		was_sprinting: bool,
		gap_to_target: float,
		velocity_xz: Vector2,
		desired_move: Vector2,
		stamina: float,
		sprint_locked: bool,
		carrying: bool,
		breakaway: bool,
		facing_xz: Vector2 = Vector2.ZERO) -> bool:
	# Hard gates first.
	if sprint_locked:
		return false
	if carrying and not breakaway:
		return false
	# Stamina floor gates only the START; an in-progress sprint rides down.
	if not was_sprinting and stamina < STAMINA_ENGAGE_FLOOR:
		return false
	# Gap gate with hysteresis: need real ground to cover, and once committed
	# keep going until well inside the engage band.
	var gap_threshold: float = GAP_SUSTAIN_M if was_sprinting else GAP_ENGAGE_M
	if gap_to_target < gap_threshold:
		return false
	var desired_len: float = desired_move.length()
	# Turn gate: only when actually moving. A sharp required turn means the
	# wide sprint arc overshoots — let agility carve it at normal speed.
	var speed: float = velocity_xz.length()
	if speed > TURN_GATE_SPEED_M_S and desired_len > 0.01:
		var alignment: float = velocity_xz.dot(desired_move) / (speed * desired_len)
		if alignment < TURN_ALIGN_MIN_DOT:
			return false
	# Facing gate: sprint commits the body — you burst once you're pointed.
	# While the body still faces well off the travel direction, thrust is
	# crossover/backward-penalized (facing-alignment scale in
	# SkaterMovementRules) AND sprint halves the facing turn rate
	# (sprint_turn_multiplier), so sprinting mid-rotation both buys little
	# speed and drags the turn out — the "bot pinned mid-turn, rotating in
	# slow motion" read after every direction flip. Facing converges
	# monotonically toward the aim, so this releases cleanly once aligned
	# (no hysteresis needed).
	if facing_xz.length_squared() > 0.0001 and desired_len > 0.01:
		var face_alignment: float = facing_xz.normalized().dot(desired_move) / desired_len
		if face_alignment < TURN_ALIGN_MIN_DOT:
			return false
	return true
