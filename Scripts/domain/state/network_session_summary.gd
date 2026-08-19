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
#   • Felt-lag markers: record_felt_lag() appends a capped list of
#     {at_sec, ...snapshot} dicts so a tester's subjective "this felt bad"
#     moments ride along in the same row, correlated with the numbers.
#   • Auto markers: record_auto_marker() is the same mechanism fired by
#     objective tripwires (hard-snap burst, host stall, …) with a per-trigger
#     cooldown — rare bugs land with a timestamp even when nobody pressed F4.
#     Both marker kinds can carry a `history` pre-trace (the ring of 1 s
#     samples leading up to the moment), budgeted across the session so the
#     row stays under the table's jsonb size cap.

# Metrics where a LOWER value is the bad direction, so the session minimum is
# the diagnostic extreme worth keeping (everything else keeps the maximum).
const MIN_KEYS: Array[String] = ["sim_rate_hz", "reconcile_match_pct", "client_fps",
		"buffer_depth_skater", "buffer_depth_puck"]

# Metrics observed as PER-WINDOW EVENT COUNTS rather than rates/levels — the
# rare discrete tripwires (puck hard-snaps, blade jumps). Averaging smears
# them invisible (3 hard snaps in a 10-minute game ≈ 0.005/s), so to_dict()
# emits a single "<key>_total" (the sum across the session) instead of the
# max/avg pair.
const TOTAL_KEYS: Array[String] = ["puck_predict_fallbacks", "delay_clamps",
	"puck_hard_snaps", "blade_jumps",
		"pickup_claims", "pickup_claim_misses", "pickup_claim_deflects",
		"poke_claims", "poke_claim_misses",
		"stick_lift_claims", "stick_lift_claim_misses",
		"claim_miss_recovered", "claim_continuity_clamps",
		"claim_stamp_rejects",
		"provisional_pins", "provisional_confirmed", "provisional_timeouts",
		"provisional_stolen",
		"reconcile_miss_empty", "reconcile_miss_older", "reconcile_miss_newer",
		"reconcile_miss_gap", "shot_launches", "host_stalls"]

# Cap on felt-lag markers per session — defense against a tester leaning on the
# key. Beyond the cap we keep a count so the total is still visible.
const MAX_FELT_LAG_MARKERS: int = 50

# Auto markers (objective tripwires, recorded by NetworkTelemetry) get a
# per-trigger cooldown plus a session cap: a broken session should record the
# ONSET of each failure mode, not one marker per second for ten minutes.
const MAX_AUTO_MARKERS: int = 20
const AUTO_MARKER_COOLDOWN_SEC: float = 30.0

# Markers that carry a pre-history trace, across BOTH lists. History is the
# bulky part of a marker (~6 rounded samples × every metric key). This static
# cap is the first line of restraint; the HARD size guarantee is
# to_dict_bounded() below — the metric-key set grows over time, so a fixed
# marker count can't bound the payload by itself (the first playtest's client
# rows blew the table's 64 KiB jsonb cap through exactly this cap).
const MAX_MARKERS_WITH_HISTORY: int = 8

var seconds: int = 0
var felt_lag_count: int = 0
var auto_marker_count: int = 0

var _min: Dictionary = {}
var _max: Dictionary = {}
var _sum: Dictionary = {}
var _markers: Array[Dictionary] = []
var _auto_markers: Array[Dictionary] = []
var _auto_last_at: Dictionary = {}
var _history_attached: int = 0


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
# `history` is the caller's pre-history ring (the seconds leading up to the
# press — the press comes AFTER the felt moment, so the instantaneous snapshot
# alone often looks recovered); attached within MAX_MARKERS_WITH_HISTORY.
func record_felt_lag(at_sec: float, snapshot: Dictionary, history: Array[Dictionary] = []) -> void:
	felt_lag_count += 1
	if _markers.size() >= MAX_FELT_LAG_MARKERS:
		return
	_markers.append(_build_marker(at_sec, snapshot, history))


# Append an objective tripwire marker (same shape as a felt-lag marker, plus
# the `trigger` name). Per-trigger cooldown keeps a sustained failure from
# spamming; the count keeps climbing past the storage cap so the total stays
# visible. Callers pass the tripwire name, e.g. "puck_hard_snaps".
func record_auto_marker(at_sec: float, trigger: String, snapshot: Dictionary,
		history: Array[Dictionary] = []) -> void:
	var last: float = _auto_last_at.get(trigger, -AUTO_MARKER_COOLDOWN_SEC)
	if at_sec - last < AUTO_MARKER_COOLDOWN_SEC:
		return
	_auto_last_at[trigger] = at_sec
	auto_marker_count += 1
	if _auto_markers.size() >= MAX_AUTO_MARKERS:
		return
	var marker: Dictionary = _build_marker(at_sec, snapshot, history)
	marker["trigger"] = trigger
	_auto_markers.append(marker)


func _build_marker(at_sec: float, snapshot: Dictionary, history: Array[Dictionary]) -> Dictionary:
	var marker: Dictionary = snapshot.duplicate()
	marker["at_sec"] = at_sec
	if not history.is_empty() and _history_attached < MAX_MARKERS_WITH_HISTORY:
		_history_attached += 1
		marker["history"] = history
	return marker


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
		"auto_marker_count": auto_marker_count,
		"auto_markers": _auto_markers,
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


# ── Size-bounded serialization ───────────────────────────────────────────────
# The table bounds the metrics blob with `pg_column_size(metrics) < 64 KiB`,
# measured on the COMPRESSED jsonb datum — so the safe TEXT budget sits well
# below 64 KiB (compression varies with value entropy: borderline ~100 KiB
# payloads have both passed and failed in the field — the first playtest's
# client rows all 400'd on the constraint while a same-sized host row landed).
# The static marker caps can't guarantee the bound because the metric-key set
# grows over time (each history sample carries every key), so the serializer
# enforces it directly.
const METRICS_MAX_TEXT_BYTES: int = 48 * 1024


# to_dict() with a hard serialized-size ceiling: sheds marker weight in
# increasing order of diagnostic value until the payload fits. Aggregates are
# never shed, and the counts (felt_lag_count / auto_marker_count) survive every
# stage — only per-moment detail is dropped. Shed order:
#   1. history traces off AUTO markers, last-attached first (earliest onsets
#      keep their run-up),
#   2. history traces off FELT markers, same order,
#   3. whole auto markers from the tail,
#   4. whole felt markers from the tail (the tester's explicit signal goes
#      last).
# If the aggregates alone exceed max_bytes (not reachable at real metric
# counts) the oversize dict is returned as-is — the POST fails like today, but
# the local mirror still lands.
func to_dict_bounded(max_bytes: int = METRICS_MAX_TEXT_BYTES) -> Dictionary:
	var out: Dictionary = to_dict()
	if _encoded_size(out) <= max_bytes:
		return out
	# Work on copies — to_dict embeds the live marker lists by reference, and
	# shedding must not mutate the session's own records.
	var felt: Array[Dictionary] = []
	for m: Dictionary in _markers:
		felt.append(m.duplicate())
	var auto: Array[Dictionary] = []
	for m: Dictionary in _auto_markers:
		auto.append(m.duplicate())
	out["felt_lag_markers"] = felt
	out["auto_markers"] = auto
	for i: int in range(auto.size() - 1, -1, -1):
		if _encoded_size(out) <= max_bytes:
			return out
		auto[i].erase("history")
	for i: int in range(felt.size() - 1, -1, -1):
		if _encoded_size(out) <= max_bytes:
			return out
		felt[i].erase("history")
	while _encoded_size(out) > max_bytes and not auto.is_empty():
		auto.pop_back()
	while _encoded_size(out) > max_bytes and not felt.is_empty():
		felt.pop_back()
	return out


static func _encoded_size(d: Dictionary) -> int:
	return JSON.stringify(d).to_utf8_buffer().size()
