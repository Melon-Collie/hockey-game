class_name AIBreakoutEpisodeTracker
extends RefCounted

# Live breakout-outcome tracker — the in-game counterpart of
# `benchmarks/test_breakout_harness.gd`, classifying real defensive-zone
# possession episodes into the SAME four outcomes so the two numbers are
# directly comparable.
#
# It exists because the harness is staged. Its trials warm up organically, but
# the trigger events are still chosen, and one scenario (`cycle-turnover`)
# resolves identically regardless of jitter — which is either a real AI failure
# or an artifact of how that trial is set up, and nothing inside the harness can
# tell those apart. A live tally over ordinary play can: if the harness says 68%
# cough-up and live play says 68%, the harness is representative and its verdicts
# can be trusted. If they disagree, the harness is measuring its own staging.
#
# ── An EPISODE is one breakout ATTEMPT, not one zone entry ────────────────────
# Starts when the puck is ESTABLISHED in our zone (past the blue line by
# ESTABLISH_DEPTH_M, the same margin the harness uses so a puck hovering on the
# line can't arm it) and is NOT carried by an opponent — i.e. it is ours or it is
# loose and the retrieval race is on. An opponent carrying it in is not a
# breakout attempt, it is defense, and counting that time would bury the metric
# in cycle possessions we never had.
#
# Ends on the first of:
#   CLEAN_EXIT — left the zone under our control (our carrier over the line, or
#                a release of ours still in flight — see CONTROLLED_RELEASE_S)
#   CLEAR_EXIT — left the zone uncontrolled (a rim or chip out)
#   COUGH_UP   — an opponent established possession while still in our zone.
#                Losing the initial retrieval race counts, exactly as the
#                harness counts it.
#   TIMEOUT    — still bottled after LIMIT_S
#   STOPPAGE   — a whistle resolved it first. The harness has no such case; live
#                play does, and folding these into TIMEOUT would inflate a
#                failure bucket with plays that simply ended.
#
# After a COUGH_UP a new episode arms as soon as the opponent loses it again, so
# one long zone entry can legitimately contain several failed attempts — which is
# the honest reading, since each is a separate breakout we did not complete.

#
# Hot path: `tick` runs twice per physics tick. Counters are fixed-size packed
# storage; no allocation.

const TEAM_COUNT: int = 2

enum Outcome { CLEAN_EXIT, CLEAR_EXIT, COUGH_UP, TIMEOUT, STOPPAGE }
const OUTCOME_COUNT: int = 5

# Depth past the blue line before an episode arms. Mirrors the harness's
# `BLUE_LINE_Z + 2.0` establishment test; with the exit measured at the line
# itself this is also the hysteresis band that stops a puck sitting on the line
# from opening and closing episodes every tick.
const ESTABLISH_DEPTH_M: float = 2.0

# Bottled-in ceiling. Same value as the harness's LIMIT_S so the TIMEOUT buckets
# mean the same thing.
const LIMIT_S: float = 12.0

# How long after our last carrier an uncarried puck crossing out still counts as
# CONTROLLED. The harness credits a breakout PASS in flight as a clean exit
# (180 ticks at 120 Hz); this is that window, approximated from carrier history
# rather than a release log, since the live tracker has no access to one. The
# approximation can only mislabel a puck we lost and then had rim out inside the
# window — rare, and it errs toward crediting us, so a clean-exit READ here is
# the optimistic bound.
const CONTROLLED_RELEASE_S: float = 1.5

# Counts per (team, outcome), team-major.
var _counts: PackedInt32Array = PackedInt32Array()
# Summed episode durations per team, for a mean-length read.
var _durations: PackedFloat64Array = PackedFloat64Array()

# ── Per-team open-episode state ──────────────────────────────────────────────
var _active: PackedInt32Array = PackedInt32Array()        # 0/1
var _elapsed: PackedFloat64Array = PackedFloat64Array()
# Seconds since a player of ours last carried it this episode; INF = never.
var _since_our_carry: PackedFloat64Array = PackedFloat64Array()


func _init() -> void:
	reset()


func reset() -> void:
	_counts.resize(TEAM_COUNT * OUTCOME_COUNT)
	_counts.fill(0)
	_durations.resize(TEAM_COUNT)
	_durations.fill(0.0)
	_active.resize(TEAM_COUNT)
	_active.fill(0)
	_elapsed.resize(TEAM_COUNT)
	_elapsed.fill(0.0)
	_since_our_carry.resize(TEAM_COUNT)
	_since_our_carry.fill(INF)


# One live-play sample for `team_id`.
#   `own_goal_z`       — the net this team defends (±GOAL_LINE_Z)
#   `puck_pos`         — world puck position
#   `carrier_team`     — team_id of the carrier, or -1 when the puck is loose
# Callers must only sample during live play; stoppages go through
# `close_on_stoppage` so a whistled play isn't scored as a bottled-in failure.
func tick(team_id: int, own_goal_z: float, puck_pos: Vector3,
		carrier_team: int, dt: float) -> void:
	if team_id < 0 or team_id >= TEAM_COUNT or dt <= 0.0:
		return
	var own_dir: float = signf(own_goal_z)
	var depth: float = own_dir * puck_pos.z          # > BLUE_LINE_Z == in our zone
	var opp_carries: bool = carrier_team != -1 and carrier_team != team_id
	var we_carry: bool = carrier_team == team_id

	if _active[team_id] == 0:
		# Arm on an established puck in our zone that isn't theirs.
		if depth > GameRules.BLUE_LINE_Z + ESTABLISH_DEPTH_M and not opp_carries:
			_active[team_id] = 1
			_elapsed[team_id] = 0.0
			_since_our_carry[team_id] = 0.0 if we_carry else INF
		return

	_elapsed[team_id] += dt
	if we_carry:
		_since_our_carry[team_id] = 0.0
	elif _since_our_carry[team_id] < INF:
		_since_our_carry[team_id] += dt

	# Exit is tested BEFORE the cough, matching the harness's loop order: a puck
	# that crosses out on the same step it changes hands counts as having left.
	if depth < GameRules.BLUE_LINE_Z:
		var controlled: bool = we_carry \
				or _since_our_carry[team_id] <= CONTROLLED_RELEASE_S
		_close(team_id, Outcome.CLEAN_EXIT if controlled else Outcome.CLEAR_EXIT)
		return
	if opp_carries:
		_close(team_id, Outcome.COUGH_UP)
		return
	if _elapsed[team_id] >= LIMIT_S:
		_close(team_id, Outcome.TIMEOUT)


# Resolves any open episode as STOPPAGE. Call when play stops (a whistle, a
# goal, the period ending) so a play that simply ended is not scored as bottled.
func close_on_stoppage() -> void:
	for team_id: int in TEAM_COUNT:
		if _active[team_id] == 1:
			_close(team_id, Outcome.STOPPAGE)


func _close(team_id: int, outcome: int) -> void:
	_counts[team_id * OUTCOME_COUNT + outcome] += 1
	_durations[team_id] += _elapsed[team_id]
	_active[team_id] = 0
	_elapsed[team_id] = 0.0
	_since_our_carry[team_id] = INF


func count(team_id: int, outcome: int) -> int:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return 0
	if outcome < 0 or outcome >= OUTCOME_COUNT:
		return 0
	return _counts[team_id * OUTCOME_COUNT + outcome]


# Completed episodes for this team.
func total(team_id: int) -> int:
	if team_id < 0 or team_id >= TEAM_COUNT:
		return 0
	var n: int = 0
	for outcome: int in OUTCOME_COUNT:
		n += _counts[team_id * OUTCOME_COUNT + outcome]
	return n


func share(team_id: int, outcome: int) -> float:
	var n: int = total(team_id)
	if n <= 0:
		return 0.0
	return float(count(team_id, outcome)) / float(n)


func mean_duration_s(team_id: int) -> float:
	var n: int = total(team_id)
	if n <= 0 or team_id < 0 or team_id >= TEAM_COUNT:
		return 0.0
	return _durations[team_id] / float(n)


static func outcome_name(outcome: int) -> String:
	match outcome:
		Outcome.CLEAN_EXIT:
			return "clean-exit"
		Outcome.CLEAR_EXIT:
			return "clear-exit"
		Outcome.COUGH_UP:
			return "cough-up"
		Outcome.TIMEOUT:
			return "timeout"
		Outcome.STOPPAGE:
			return "stoppage"
		_:
			return "?"


# JSON-able snapshot. `mode_label` records which AI configuration produced these
# numbers — without it two A/B dumps are indistinguishable.
func to_dict(mode_label: String) -> Dictionary:
	var out: Dictionary = {"mode": mode_label}
	for team_id: int in TEAM_COUNT:
		var outcomes: Dictionary = {}
		for outcome: int in OUTCOME_COUNT:
			outcomes[outcome_name(outcome)] = {
				"count": count(team_id, outcome),
				"share": share(team_id, outcome),
			}
		out["team_%d" % team_id] = {
			"episodes": total(team_id),
			"mean_episode_s": mean_duration_s(team_id),
			"outcomes": outcomes,
		}
	return out
