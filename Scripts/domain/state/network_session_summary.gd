class_name NetworkSessionSummary extends RefCounted

# Pure, engine-free session-long aggregation of the per-second metrics that
# NetworkTelemetry publishes. NetworkTelemetry owns one of these and folds a
# sample into it once per 1 s window (see NetworkTelemetry.tick); the reporter
# reads to_dict() at game-over and POSTs one row to Supabase. The whole point
# is to answer "across a tester's whole session, what was the WORST and the
# TYPICAL connection quality?" — F3 only shows the live instant, which nobody
# is watching on a remote tester's machine.
#
# Design:
#   • Generic accumulator, not a wall of explicit fields: each observed key
#     tracks min / max / running mean. to_dict() emits "<key>_max" and
#     "<key>_avg" for every key, plus "<key>_min" for the keys in MIN_KEYS
#     (metrics where LOWER is worse — sim rate, reconcile-match %), while
#     TOTAL_KEYS event counters emit only "<key>_total" (session sum). The
#     column set the SQL views expect is therefore derived mechanically from
#     the sample keys + MIN_KEYS/TOTAL_KEYS; keep the views (and
#     docs/telemetry_dictionary.md) in sync when any of them move.
#   • No health classification here — it ships raw aggregates and lets the
#     analysis (SQL / overlay) own thresholds, so the band cutoffs aren't
#     duplicated out of network_telemetry.gd / the F3 overlay.
#   • Felt-lag markers (Phase 2): record_felt_lag() appends a capped list of
#     {at_sec, ...snapshot} dicts so a tester's subjective "this felt bad"
#     moments ride along in the same row, correlated with the numbers.

# Metrics where a LOWER value is the bad direction, so the session minimum is
# the diagnostic extreme worth keeping (everything else keeps the maximum).
const MIN_KEYS: Array[String] = ["sim_rate_hz", "reconcile_match_pct", "client_fps",
		"buffer_depth_skater", "buffer_depth_puck"]

# Metrics observed as PER-WINDOW EVENT COUNTS rather than rates/levels — the
# rare discrete tripwires (puck hard-snaps, blade jumps). Averaging smears
# them invisible (3 hard snaps in a 10-minute game ≈ 0.005/s), so to_dict()
# emits a single "<key>_total" (the sum across the session) instead of the
# max/avg pair.
const TOTAL_KEYS: Array[String] = ["puck_hard_snaps", "blade_jumps"]

# Cap on felt-lag markers per session — defense against a tester leaning on the
# key. Beyond the cap we keep a count so the total is still visible.
const MAX_FELT_LAG_MARKERS: int = 50

var seconds: int = 0
var felt_lag_count: int = 0

var _min: Dictionary = {}
var _max: Dictionary = {}
var _sum: Dictionary = {}
var _markers: Array[Dictionary] = []


# Fold one 1 s sample into the session aggregates. `sample` maps metric name →
# value (float). Keys are free-form; whatever is passed becomes a column pair.
func observe(sample: Dictionary) -> void:
	seconds += 1
	for key: String in sample:
		var v: float = float(sample[key])
		if _sum.has(key):
			_min[key] = minf(_min[key], v)
			_max[key] = maxf(_max[key], v)
			_sum[key] = _sum[key] + v
		else:
			_min[key] = v
			_max[key] = v
			_sum[key] = v


# Append a subjective "I felt lag" marker. `at_sec` is the in-session time; the
# rest of `snapshot` is whatever live telemetry the caller chose to capture.
func record_felt_lag(at_sec: float, snapshot: Dictionary) -> void:
	felt_lag_count += 1
	if _markers.size() >= MAX_FELT_LAG_MARKERS:
		return
	var marker: Dictionary = snapshot.duplicate()
	marker["at_sec"] = at_sec
	_markers.append(marker)


func has_data() -> bool:
	return seconds > 0


# Flat dict for Supabase. Per metric: "<key>_max" + "<key>_avg" always, plus
# "<key>_min" for MIN_KEYS metrics — except TOTAL_KEYS event counters, which
# emit only "<key>_total". Plus session-level fields.
func to_dict() -> Dictionary:
	var out: Dictionary = {
		"duration_sec": seconds,
		"felt_lag_count": felt_lag_count,
		"felt_lag_markers": _markers,
	}
	for key: String in _sum:
		if key in TOTAL_KEYS:
			out[key + "_total"] = _sum[key]
			continue
		out[key + "_max"] = _max[key]
		out[key + "_avg"] = _sum[key] / float(seconds)
		if key in MIN_KEYS:
			out[key + "_min"] = _min[key]
	return out
