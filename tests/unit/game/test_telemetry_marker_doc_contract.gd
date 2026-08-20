extends GutTest

# docs/telemetry_dictionary.md states every auto-marker tripwire in prose, and a
# playtester reading a `.json` summary reads THAT, not the source. So the doc is
# the third copy of these numbers, and the one most likely to rot: the audit that
# prompted this work measured ~29% of the identifiers that file names as no longer
# existing in the codebase.
#
# The other two copies are gone. NetworkTelemetry now owns the bands as named
# constants and NetworkDebugOverlay reads them, so the overlay's red and a
# recorded marker cannot describe different thresholds. This is what closes the
# loop on the third.
#
# Parsing prose is fragile on purpose here: it is exactly as fragile as a reader
# trusting the sentence. If the doc is reworded such that a threshold can no
# longer be found, that fails too — an unreadable spec and a wrong one are the
# same problem for the person holding the summary.
#
# The healthy-band COLUMN is held the same way wherever a band is expressed as an
# arithmetic relation to a named constant. That column is the other place these
# numbers rot, and it rots more quietly: a tripwire that never fires is noticed,
# a band that is always red is learned around.

const _DOC: String = "res://docs/telemetry_dictionary.md"


func _doc_text() -> String:
	var src: String = FileAccess.get_file_as_string(_DOC)
	assert_false(src.is_empty(), "could not read %s" % _DOC)
	return src


# Pulls the number out of e.g. "`reconcile_storm` (≥5/s)". Anchored on the ≥
# rather than "first number in the parens", because "broadcast p95 ≥500 ms" has a
# decoy in front of the real one — the first draft of this test read 95. Returns
# NAN when the trigger or its threshold cannot be found, so the caller fails
# loudly rather than silently comparing nothing.
func _documented_threshold(trigger: String) -> float:
	var re := RegEx.create_from_string(
			"`" + trigger + "`\\s*\\([^)]*?\u2265\\s*([0-9]+(?:\\.[0-9]+)?)")
	var m: RegExMatch = re.search(_doc_text())
	if m == null:
		return NAN
	return float(m.get_string(1))


func _assert_documented(trigger: String, expected: float) -> void:
	var found: float = _documented_threshold(trigger)
	assert_false(is_nan(found),
			"telemetry_dictionary.md no longer states a threshold for `%s` — " % trigger +
			"a tester reading a summary has nothing to check the marker against")
	assert_almost_eq(found, expected, 1e-6,
			"telemetry_dictionary.md says `%s` fires at %s, the code fires at %s"
			% [trigger, found, expected])


func test_documented_tripwires_match_the_shared_bands() -> void:
	_assert_documented("reconcile_storm", NetworkTelemetry.RECONCILE_BAD_PER_SEC)
	_assert_documented("extrapolation", NetworkTelemetry.EXTRAPOLATION_BAD_PCT)
	_assert_documented("host_stall", NetworkTelemetry.STALL_BAD_MS)
	_assert_documented("input_starvation", NetworkTelemetry.STARVATION_BAD_PER_SEC)


func test_documented_puck_snap_tripwire_matches_its_count() -> void:
	# The deliberate exception: fires at the WARN band, counted per window rather
	# than per second. The doc says "≥2 in a window", which is the count.
	_assert_documented("puck_hard_snaps", float(NetworkTelemetry.PUCK_SNAP_MARKER_COUNT))
	assert_almost_eq(float(NetworkTelemetry.PUCK_SNAP_MARKER_COUNT),
			NetworkTelemetry.PUCK_SNAP_WARN_PER_SEC, 1e-6,
			"the puck-snap marker is documented as the overlay's WARN band read as a " +
			"per-window count — if they diverge, say which one the doc means")


# The whole `| `key` | … |` table row, so one band's several numbers come out of
# one read. (?m) so ^ and $ anchor to lines rather than the whole document.
func _band_row(key: String) -> String:
	var re := RegEx.create_from_string("(?m)^\\|\\s*`" + key + "`\\s*\\|.*$")
	var m: RegExMatch = re.search(_doc_text())
	assert_true(m != null,
			"telemetry_dictionary.md no longer has a table row for `%s`" % key)
	return "" if m == null else m.get_string(0)


func _number_in(row: String, pattern: String, key: String, what: String) -> float:
	var re := RegEx.create_from_string(pattern)
	var m: RegExMatch = re.search(row)
	assert_true(m != null,
			"telemetry_dictionary.md's `%s` band no longer states %s in a form " % [key, what] +
			"this test can read — an unreadable band and a wrong one are the same " +
			"problem for the person holding the summary")
	return NAN if m == null else float(m.get_string(1))


# The healthy-band COLUMN, which the tripwire assertions above do not reach — and
# where the 120-vs-60 error lived. The broadcast cadence is COUNTED in physics
# ticks but fires every second one, so a band stated as the tick interval reads
# every healthy host as sagging by 2×, permanently.
func test_documented_broadcast_band_tracks_the_broadcast_rate() -> void:
	const KEY: String = "broadcast_interval_p95_ms"
	var row: String = _band_row(KEY)
	# The relation AND its arithmetic result are both stated, because both are
	# read by a human; the relation is what survives a rate change.
	assert_true(row.contains("1000 / STATE_RATE"),
			"the band must name the constant it derives from rather than only a " +
			"number, or the next rate change strands it: %s" % row)
	assert_almost_eq(_number_in(row, "=\\s*([0-9]+(?:\\.[0-9]+)?)\\s*ms", KEY, "a target interval"),
			1000.0 / float(Constants.STATE_RATE), 0.05,
			"telemetry_dictionary.md's broadcast target disagrees with " +
			"1000 / Constants.STATE_RATE (%d Hz)" % Constants.STATE_RATE)
	assert_almost_eq(_number_in(row, ">\\s*([0-9]+(?:\\.[0-9]+)?)×\\s*target", KEY, "a sag multiplier"),
			NetworkTelemetry.BROADCAST_SAG_WARN_MULT, 1e-6,
			"telemetry_dictionary.md's sag threshold disagrees with the band the " +
			"F3 overlay colours the row with")


func test_documented_freeze_tripwires_match() -> void:
	# These two deliberately do NOT track the overlay bands — 500 ms is a visibly
	# frozen world, not a degraded one — so the doc's claim is all a reader has.
	_assert_documented("broadcast_gap", 500.0)
	_assert_documented("input_backlog", 500.0)
