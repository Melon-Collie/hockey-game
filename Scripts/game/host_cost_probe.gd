class_name HostCostProbe
extends Object

# Per-tick timing of the host's MAIN-THREAD AI work, which the cosmetic freeze
# sweep (PerfProbe) structurally cannot see.
#
# Why a second probe rather than another PerfProbe mode: the sweep works by
# switching work OFF and reading the frame. That is only sound for cosmetics —
# suppressing a pose changes nothing anyone reads back. Freezing the AI changes
# what the bots do, which changes the physics, which changes the frame; the A/B
# would not be comparing two measurements of the same game. AI has clean call
# seams instead, so it can simply be timed where it runs.
#
# MEAN IS THE WRONG STATISTIC HERE, and that is the whole point of this class.
# The host's AI cost is not spread evenly across ticks:
#   • TeamBrain.tick is rate-limited to 6 Hz, so the full strategy computation
#     lands on roughly one physics tick in twenty and costs nothing on the other
#     nineteen — and force_retick() fires it off-cadence on every puck-carrier
#     change, so the spikes CLUSTER in scrums.
#   • AICoordinator only freezes brain views, preps agents and kicks a batch on
#     ticks where the worker is idle. Ticks therefore alternate between a heavy
#     harvest-and-kick and a run of nearly free ones.
# A 3 ms spike once per twenty ticks reads as 0.15 ms of mean — invisible next
# to anything steady, while being exactly the thing a player feels as an
# inconsistent frame rate. So every section publishes its window MAX beside its
# mean, and a max far above the mean IS the finding.
#
# Microseconds throughout, deliberately un-normalised: one 120 Hz physics tick is
# 8333 us, which is the number every reading here should be held against.
#
# Host-only. `enabled` is set by GameManager when it takes the host role and
# cleared on teardown, so a client pays two branch tests per tick and nothing
# else.

enum Section {
	SNAPSHOT,   # get_state_delayed + _enrich_snapshot_for_ai + accel tracker
	BRAINS,     # the TeamBrain.tick loop — 6 Hz strategy plus forced re-ticks
	DISPATCH,   # AICoordinator.dispatch, MAIN-thread portion only
	# DISPATCH's two halves, split for the same reason PerfProbe splits the rig:
	# knowing the total is 0.6 ms says nothing about what to do next.
	AI_APPLY,   # harvest + begin_tick + apply_decision, per bot
	# SkaterController._process_input, summed over the bots. Nested inside
	# AI_APPLY and broken out because it is NOT AI work: it is the ordinary
	# skater step, the same call a local human's controller makes, and the host
	# pays it per skater whoever is driving. Charging it to the AI would name the
	# wrong subsystem — the fix for it is a cheaper skater tick or fewer ticks,
	# not a cheaper bot.
	SKATER_STEP,
	AI_KICK,    # build_view + prep_for_decide + _stabilize_snapshot, per kick
	WORKER,     # the off-thread decide() batch: context, NOT main-thread cost
	# ── The rest of the host's physics tick ──────────────────────────────────
	# Everything above is reached from GameManager's AI block. These are the
	# other per-tick bodies, each summed over its actors, so the tick's cost is
	# attributed rather than left in a residual.
	SKATER_PHYS,   # Skater._physics_process, x10 — integrate, analytic contact, clamps
	PUCK_PHYS,     # Puck._physics_process + PuckController._physics_process
	GOALIE_PHYS,   # GoalieController._physics_process, x2
	GM_TAIL,       # goal / bounds / ghost checks and the four trackers
	NET_CAPTURE,   # end-of-tick ring capture + broadcast
}

const SECTION_COUNT: int = 12
const SECTION_NAMES: Array[String] = [
	"snapshot", "brains", "dispatch (total)", "  dispatch: apply",
	"    of which skater step", "  dispatch: kick", "worker (off-thread)",
	"skater bodies", "puck", "goalies", "game tail", "capture + broadcast",
]

# One publish per second of host simulation. Matches the cadence a reader can
# follow on screen, and is long enough that a 6 Hz section contributes ~6
# samples rather than 0 or 1.
const WINDOW_TICKS: int = 120

static var enabled: bool = false

# Live window. Sums are float64 for the same reason PerfProbe's are: a long
# session accumulates enough microseconds that float32 quietly stops adding.
static var _sum_us: PackedFloat64Array = _new_bins()
static var _max_us: PackedFloat64Array = _new_bins()
static var _ticks: int = 0
# Ticks that found the worker still chewing the previous batch, so no new one
# could be kicked. Sustained high values mean the bots are deciding at less than
# the tick rate — an AI-responsiveness fact rather than a frame-cost one, but it
# comes from the same place and is free to count here.
static var _worker_busy_ticks: int = 0

# Last completed window — what the panel and the digest read. Kept separate from
# the live window so a reader never catches a half-filled second and mistakes it
# for a quiet one.
static var _pub_mean_us: PackedFloat64Array = _new_bins()
static var _pub_max_us: PackedFloat64Array = _new_bins()
static var _pub_worker_busy_pct: float = 0.0
static var _pub_ticks: int = 0

# Worst single tick since the session began. A window max decays as soon as the
# window rolls; this is the one that survives to be pasted into a bug report.
static var _session_max_us: PackedFloat64Array = _new_bins()


static func _new_bins() -> PackedFloat64Array:
	var a := PackedFloat64Array()
	a.resize(SECTION_COUNT)
	return a


# Charge one tick's microseconds to a section. Callers time with
# Time.get_ticks_usec() around the block rather than passing a Callable — a
# Callable per section per tick is exactly the per-tick heap churn this codebase
# bans from hot paths.
static func record(section: int, us: int) -> void:
	if not enabled:
		return
	var v: float = float(us)
	_sum_us[section] += v
	if v > _max_us[section]:
		_max_us[section] = v
	if v > _session_max_us[section]:
		_session_max_us[section] = v


# Closes the host tick. The worker-busy share is collected by the coordinator
# itself via note_worker_busy — read at the point the kick decision is made,
# because after dispatch returns a batch has just been kicked and the in-flight
# flag is true on every healthy tick.
static func end_tick() -> void:
	if not enabled:
		return
	_ticks += 1
	if _ticks < WINDOW_TICKS:
		return
	for s: int in SECTION_COUNT:
		_pub_mean_us[s] = _sum_us[s] / float(_ticks)
		_pub_max_us[s] = _max_us[s]
		_sum_us[s] = 0.0
		_max_us[s] = 0.0
	_pub_worker_busy_pct = 100.0 * float(_worker_busy_ticks) / float(_ticks)
	_pub_ticks = _ticks
	_ticks = 0
	_worker_busy_ticks = 0


# Called once per dispatch, with the kick decision as the coordinator saw it:
# true means the previous batch was STILL RUNNING, so no fresh one could be
# started and every bot coasts on its last decision this tick.
static func note_worker_busy(busy: bool) -> void:
	if enabled and busy:
		_worker_busy_ticks += 1


static func has_data() -> bool:
	return _pub_ticks > 0


static func mean_us(section: int) -> float:
	return _pub_mean_us[section]


static func max_us(section: int) -> float:
	return _pub_max_us[section]


static func session_max_us(section: int) -> float:
	return _session_max_us[section]


# Share of ticks in the last window that could not kick a batch because the
# worker was still busy.
static func worker_busy_pct() -> float:
	return _pub_worker_busy_pct


# The sum of the MAIN-thread sections' means — what AI costs the host tick on
# average. WORKER is excluded: it runs on its own thread and adding it would
# double-count time the main thread never spent.
# AI_APPLY, SKATER_STEP and AI_KICK are excluded as well — they are nested
# inside DISPATCH, and adding them would count the same microseconds twice.
static func main_thread_mean_us() -> float:
	return _pub_mean_us[Section.SNAPSHOT] + _pub_mean_us[Section.BRAINS] \
			+ _pub_mean_us[Section.DISPATCH]


# The same figure with the skater step taken back out — what the AI itself costs
# the tick, as opposed to what simulating ten skaters costs. This is the number
# to quote when deciding whether the AI is worth optimising.
static func ai_only_mean_us() -> float:
	return maxf(main_thread_mean_us() - _pub_mean_us[Section.SKATER_STEP], 0.0)


# Every attributed main-thread section of the host tick. Nested sections
# (AI_APPLY, SKATER_STEP, AI_KICK) and the off-thread WORKER are left out. What
# this MISSES is as informative as what it holds: the gap between this and the
# engine's physics step is unattributed tick cost — engine-side transform
# propagation, signal dispatch, and whatever body has not been instrumented.
static func tick_total_mean_us() -> float:
	return _pub_mean_us[Section.SNAPSHOT] + _pub_mean_us[Section.BRAINS] \
			+ _pub_mean_us[Section.DISPATCH] + _pub_mean_us[Section.SKATER_PHYS] \
			+ _pub_mean_us[Section.PUCK_PHYS] + _pub_mean_us[Section.GOALIE_PHYS] \
			+ _pub_mean_us[Section.GM_TAIL] + _pub_mean_us[Section.NET_CAPTURE]


# The worst main-thread AI tick in the window. Not the sum of the per-section
# maxima — those can fall on different ticks, and adding them would invent a
# tick that never happened. This is a lower bound on the true worst tick, which
# is the safe direction for a number used to accuse a subsystem.
static func main_thread_max_us() -> float:
	return maxf(_pub_max_us[Section.SNAPSHOT],
			maxf(_pub_max_us[Section.BRAINS], _pub_max_us[Section.DISPATCH]))


static func reset() -> void:
	for s: int in SECTION_COUNT:
		_sum_us[s] = 0.0
		_max_us[s] = 0.0
		_pub_mean_us[s] = 0.0
		_pub_max_us[s] = 0.0
		_session_max_us[s] = 0.0
	_ticks = 0
	_worker_busy_ticks = 0
	_pub_ticks = 0
	_pub_worker_busy_pct = 0.0
