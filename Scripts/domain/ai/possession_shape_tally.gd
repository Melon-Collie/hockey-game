class_name AIPossessionShapeTally
extends RefCounted

# Occupancy tally for the team-shape state machine — how much of a game each
# team spends in each AIPossessionState shape, and how it gets there.
#
# A debug instrument, not a gameplay input: nothing reads it back into a
# decision. It exists because the shapes are the top-level control flow of the
# whole bot AI (which roles exist, which evaluators run) and we had no idea of
# their relative weight. "Is this shape worth the code it costs?" is a question
# about occupancy, and occupancy was unmeasured.
#
# Three numbers per shape, because share alone is misleading:
#   • SHARE       — fraction of live play in the shape. The headline.
#   • ENTRIES     — how many separate spells. 5% over 200 spells is a shape the
#                   team is constantly flickering through; 5% over 2 is a shape
#                   that happens rarely and lasts. Those want opposite fixes.
#   • MEAN SPELL  — seconds per spell, share/entries made legible.
#
# Plus the COVERAGE DOWNGRADE: seconds where the raw read said DZONE but
# TeamBrain held the rush shape because the backcheck wasn't home
# (AIRushRead.coverage_ready). That is a distinct failure surface from either
# shape's own occupancy — it is time the in-zone coverage was suppressed — so
# it is counted separately rather than being invisible inside TRANS_OD.
#
# Sampled per physics tick against each brain's PUBLISHED state, so the tally
# measures the shape actually being run (post-downgrade), not the raw table
# lookup. Fixed-size packed storage indexed by
# team × state: no allocation on a 240 calls/second path.

const TEAM_COUNT: int = 2
const STATE_COUNT: int = 7   # AIPossessionState.State member count

# Seconds accumulated, team-major (team * STATE_COUNT + state).
var _seconds: PackedFloat64Array = PackedFloat64Array()
# Spell count per (team, state) — incremented on ENTRY, so a shape held for a
# whole period counts once.
var _entries: PackedInt32Array = PackedInt32Array()
# Last sampled state per team (-1 = nothing sampled yet), for entry detection.
var _last_state: PackedInt32Array = PackedInt32Array()
# Transition counts, team-major then from-major
# (team * STATE_COUNT^2 + from * STATE_COUNT + to). Which shape a team leaves
# FOR WHICH other shape is the question spell counts raise but cannot answer: a
# shape entered 60 times in four minutes is churning, and the fix depends
# entirely on what it is churning against. A shape pair that swaps role sets
# wholesale is a real problem; one whose slots are deliberately identical is
# free.
var _transitions: PackedInt32Array = PackedInt32Array()
# Seconds per team spent with the D-zone coverage read suppressed.
var _downgrade_seconds: PackedFloat64Array = PackedFloat64Array()
# Live-play seconds sampled per team — the denominator. Tracked per team rather
# than shared so a team whose brain went missing mid-match doesn't silently
# inflate the other team's shares.
var _total_seconds: PackedFloat64Array = PackedFloat64Array()


func _init() -> void:
	reset()


func reset() -> void:
	_seconds.resize(TEAM_COUNT * STATE_COUNT)
	_seconds.fill(0.0)
	_entries.resize(TEAM_COUNT * STATE_COUNT)
	_entries.fill(0)
	_last_state.resize(TEAM_COUNT)
	_last_state.fill(-1)
	_transitions.resize(TEAM_COUNT * STATE_COUNT * STATE_COUNT)
	_transitions.fill(0)
	_downgrade_seconds.resize(TEAM_COUNT)
	_downgrade_seconds.fill(0.0)
	_total_seconds.resize(TEAM_COUNT)
	_total_seconds.fill(0.0)


# One sample of `team_id`'s live shape. `dt` is the elapsed live-play time this
# sample covers; callers must not sample while play is stopped, or the shares
# describe wall time rather than hockey. `coverage_downgraded` is TeamBrain's
# "I wanted DZONE but held the rush shape" flag for this tick.
func accumulate(team_id: int, state: int, dt: float,
		coverage_downgraded: bool = false) -> void:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return
	if state < 0 or state >= STATE_COUNT:
		return
	if dt <= 0.0:
		return
	var idx: int = team_id * STATE_COUNT + state
	_seconds[idx] += dt
	_total_seconds[team_id] += dt
	if _last_state[team_id] != state:
		var from_state: int = _last_state[team_id]
		_last_state[team_id] = state
		_entries[idx] += 1
		# -1 is the first sample of a fresh tally: an entry, but not a
		# transition FROM anything.
		if from_state != -1:
			_transitions[team_id * STATE_COUNT * STATE_COUNT
					+ from_state * STATE_COUNT + state] += 1
	if coverage_downgraded:
		_downgrade_seconds[team_id] += dt


func seconds_in(team_id: int, state: int) -> float:
	if team_id < 0 or team_id >= TEAM_COUNT or state < 0 or state >= STATE_COUNT:
		return 0.0
	return _seconds[team_id * STATE_COUNT + state]


func entries(team_id: int, state: int) -> int:
	if team_id < 0 or team_id >= TEAM_COUNT or state < 0 or state >= STATE_COUNT:
		return 0
	return _entries[team_id * STATE_COUNT + state]


func total_seconds(team_id: int) -> float:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return 0.0
	return _total_seconds[team_id]


# Fraction of this team's sampled live play spent in `state` (0..1). Zero
# before anything is sampled — never a division by zero.
func share(team_id: int, state: int) -> float:
	var total: float = total_seconds(team_id)
	if total <= 0.0:
		return 0.0
	return seconds_in(team_id, state) / total


# Mean seconds per spell. Zero when the shape was never entered.
func mean_spell_s(team_id: int, state: int) -> float:
	var n: int = entries(team_id, state)
	if n <= 0:
		return 0.0
	return seconds_in(team_id, state) / float(n)


func transitions(team_id: int, from_state: int, to_state: int) -> int:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return 0
	if from_state < 0 or from_state >= STATE_COUNT:
		return 0
	if to_state < 0 or to_state >= STATE_COUNT:
		return 0
	return _transitions[team_id * STATE_COUNT * STATE_COUNT
			+ from_state * STATE_COUNT + to_state]


# The most frequent shape transitions for `team_id`, most frequent first, as
# Vector3i(from_state, to_state, count). Allocates — this is a read-out for the
# debug overlay (4 Hz) and the JSON dump, never the 120 Hz accumulate path.
func top_transitions(team_id: int, limit: int = 4) -> Array[Vector3i]:
	var out: Array[Vector3i] = []
	if team_id < 0 or team_id >= TEAM_COUNT:
		return out
	for from_state: int in STATE_COUNT:
		for to_state: int in STATE_COUNT:
			var n: int = transitions(team_id, from_state, to_state)
			if n > 0:
				out.append(Vector3i(from_state, to_state, n))
	out.sort_custom(func(a: Vector3i, b: Vector3i) -> bool: return a.z > b.z)
	return out.slice(0, limit) if out.size() > limit else out


func downgrade_seconds(team_id: int) -> float:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return 0.0
	return _downgrade_seconds[team_id]


func downgrade_share(team_id: int) -> float:
	var total: float = total_seconds(team_id)
	if total <= 0.0:
		return 0.0
	return downgrade_seconds(team_id) / total


# Display name for a State enum value. Debug-surface only — deliberately not
# routed through tr(): the domain layer stays engine-free, and a dev overlay is
# not a localized surface (same call the network overlay makes).
static func state_name(state: int) -> String:
	match state:
		AIPossessionState.State.DZONE:
			return "DZONE"
		AIPossessionState.State.OZONE:
			return "OZONE"
		AIPossessionState.State.TRANS_DO:
			return "TRANS_DO"
		AIPossessionState.State.TRANS_OD:
			return "TRANS_OD"
		AIPossessionState.State.NEUTRAL:
			return "NEUTRAL"
		AIPossessionState.State.BREAKOUT:
			return "BREAKOUT"
		AIPossessionState.State.FORECHECK:
			return "FORECHECK"
		_:
			return "?"


# Flat JSON-able snapshot — the paste unit for a bug report or an analysis
# pass, same role the network overlay's session digest plays.
func to_dict() -> Dictionary:
	var out: Dictionary = {}
	for team_id: int in TEAM_COUNT:
		var shapes: Dictionary = {}
		for state: int in STATE_COUNT:
			if _entries[team_id * STATE_COUNT + state] == 0:
				continue
			shapes[state_name(state)] = {
				"seconds": seconds_in(team_id, state),
				"share": share(team_id, state),
				"entries": entries(team_id, state),
				"mean_spell_s": mean_spell_s(team_id, state),
			}
		var churn: Array = []
		for t: Vector3i in top_transitions(team_id, STATE_COUNT * STATE_COUNT):
			churn.append({
				"from": state_name(t.x),
				"to": state_name(t.y),
				"count": t.z,
			})
		out["team_%d" % team_id] = {
			"live_seconds": total_seconds(team_id),
			"transitions": churn,
			"coverage_downgrade_seconds": downgrade_seconds(team_id),
			"coverage_downgrade_share": downgrade_share(team_id),
			"shapes": shapes,
		}
	return out
