class_name AIThreatAssignment

# Pure "man-on-threat" partition: assigns each backline defender to a
# DISTINCT opponent it should cover, computed once per brain tick in TeamBrain.
# Distinctness is the point — defensive roles each minimizing the global-MAX
# threat all gravitate to the single most dangerous opponent and stack in the
# slot, leaving the others open.
#
# The puck CARRIER is handled separately (PRESSURE / gap-control), so this
# partitions only the off-puck opponents (the carrier's potential receivers)
# among the off-puck defenders.
#
# ── Objective: maximize covered value, weighted by reachability ──────────────
# For a defender d and a man m:
#     reward[d][m] = value[m] × reachability(time_to_cover(d, m))
#     reachability(t) = 1 / (1 + t)            (smooth, 1 at t=0, →0 as t→∞)
# We pick the matching (each man to ≤1 defender, each defender to ≤1 man) that
# MAXIMIZES the total reward.
#
# Why maximize-value, not minimize-distance: minimizing Σ value×time
# degenerates the moment a man can be left uncovered — "cover nobody" costs 0,
# which beats any positive travel cost, so the optimizer covers no one. Framed
# as reward, covering a man PAYS (positive reward), so:
#   • high-value men attract the closest reachable defender (value × proximity),
#   • on an odd-man rush (more men than defenders) the two most dangerous
#     reachable men get covered and the least dangerous is conceded — exactly
#     the right read when you're outnumbered,
#   • two defenders never take the same man (distinct-man matching), which is
#     the whole point.
#
# time_to_cover is the momentum-aware ETA (AIActionScoring.time_to_arrive) to a
# COVER ANCHOR goal-side of the man — the spot that denies his one-timer — not
# to the man's body. A defender already skating the right way wins the pairing.
#
# Hysteresis: keep last tick's assignment unless a fresh matching beats it by
# HYSTERESIS_MARGIN_FRAC. Without it two defenders swap men every tick when the
# rewards are close — the same oscillation we're fixing, just faster. Mirrors
# the strong-side / slot-assignment hysteresis already in the brain.
#
# Brute-forced over permutations: the backline is ≤ 4 skaters (5v5's TRANS_DEFENSE
# MARK crew), so the matching is tiny (≤ 4! orderings). Runs at the 6 Hz brain
# tick, never the 120 Hz path.

# How far goal-side of the man the cover anchor sits (m). Roughly a stick into
# the man→net lane: close enough to deny the one-timer, not on top of the body.
const COVER_DEPTH_M: float = 2.2

# A fresh matching must beat the retained one by this fraction of total reward
# to trigger a switch. Sticky enough to stop per-tick man-swapping; loose enough
# that a genuine threat change re-partitions.
const HYSTERESIS_MARGIN_FRAC: float = 0.15

# ── Net-front (house) override ───────────────────────────────────────────────
# The value×reachability matching maximizes EXPECTED covered pass-threat, so it
# can trade an unreachable-but-lethal net-front man for two reachable perimeter
# men — leaving the house open. Defense doesn't work that way: conceding a
# backdoor tap-in is categorically worse than conceding a perimeter shot, so
# whoever can best get to the most dangerous net-front man is pinned to him
# FIRST, then the rest optimally match. This is a tactical priority ("protect
# the house"), but the trigger is a real measurement: a man's FINISH danger if
# fed — score_shoot from his spot with the goalie where he currently is
# (tracking the carrier, not this off-puck man), so an off-axis net-front man
# reads as lethal because the net is open to his side. The lane factor is
# dropped on purpose: a contested feed still becomes a tap-in if it arrives, so
# the house is covered by consequence, not by feed-likelihood (that's what makes
# this add something over man_value, which already folds the lane in).
#
# The bar is the finish-danger floor that counts as a genuine house threat —
# below it, trust the efficiency matching. Under the make-probability
# currency the caller's read (goalie predicted over the feed's flight) is
# P(goal | clean feed): the canonical net-front man measures ~1.0, a
# perimeter winger ~0.0 (the keeper re-squares inside the feed's flight), so
# the bar is "more likely than not".
const NET_FRONT_DANGER_BAR: float = 0.5


# Returns Dictionary[int, int]: defender_peer_id -> assigned man (opponent)
# peer_id. Defenders left without a man (more defenders than men) are omitted.
#
# `defender_pos` / `defender_vel` are peer_id -> Vector3 lookups for the
# backline defenders; `man_pos` is peer_id -> Vector3 for the men;
# `man_value` is peer_id -> precomputed threat value (the caller scores this via
# AIActionScoring so this module stays free of scoring-magnitude coupling).
# `our_net` anchors the goal-side cover point. `prev` is last tick's
# defender->man mapping (pass {} on first tick / after a state change).
# `man_danger` is peer_id -> finish danger if fed (score_shoot from the man's
# spot); drives the net-front override (empty → override off, pure matching).
static func assign(
		defenders: Array[int],
		defender_pos: Dictionary,
		defender_vel: Dictionary,
		men: Array[int],
		man_pos: Dictionary,
		man_value: Dictionary,
		our_net: Vector3,
		prev: Dictionary,
		defender_caps: Dictionary = {},
		man_danger: Dictionary = {},
		eligible_men: Dictionary = {}) -> Dictionary[int, int]:
	var result: Dictionary[int, int] = {}
	if defenders.is_empty() or men.is_empty():
		return result

	# ── Net-front override: pin the house before the efficiency matching. ──
	# Whoever can best get to the most dangerous net-front man covers him, then
	# the remaining defenders optimally match the remaining men. This can't be
	# folded into the matching reward: a value large enough to guarantee house
	# coverage would swamp the relative-margin hysteresis and freeze the
	# perimeter, so the house is a separate pin and the matching runs on the rest.
	var open_defenders: Array[int] = defenders
	var open_men: Array[int] = men
	var house_man: int = _most_dangerous_house_man(men, man_danger)
	if house_man != -1:
		# Eligibility binds the pin as well: pulling a winger off the point to
		# the net front because he happens to be nearest is the double-commit
		# the areas exist to prevent, and the box already has an owner.
		var house_def: int = _pick_house_defender(
				defenders, defender_pos, defender_vel, defender_caps,
				man_pos.get(house_man, Vector3.ZERO), house_man, our_net, prev,
				eligible_men)
		if house_def != -1:
			result[house_def] = house_man
			open_defenders = _without(defenders, house_def)
			open_men = _without(men, house_man)

	if open_defenders.is_empty() or open_men.is_empty():
		return result

	# reward[d] = { man_peer: reward_value }
	var reward: Dictionary = {}
	for d: int in open_defenders:
		var d_pos: Vector3 = defender_pos.get(d, Vector3.ZERO)
		var d_vel: Vector3 = defender_vel.get(d, Vector3.ZERO)
		# This defender covers at ITS real top speed — a fast defender
		# reaches a further man in time, so it's assigned the harder cover.
		var d_caps: AISkaterCaps = defender_caps.get(d)
		var d_speed: float = d_caps.max_speed if d_caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		# ZONE ELIGIBILITY. A defender who owns a patch of ice may only be given
		# men standing in it — his coverage is defined by the area, not by the
		# whole rink. Omitting the pair from the row is the whole mechanism:
		# _best_matching skips men the row does not carry, _matching_reward
		# already rejects a mapping naming one, and _restrict_prev already drops
		# a stale pair — so hysteresis and the idle branch need no changes.
		# An absent/empty entry means "no restriction", which is the man-marking
		# backline's case and leaves it byte-identical.
		var allowed: Dictionary = eligible_men.get(d, {})
		var restricted: bool = not allowed.is_empty()
		var row: Dictionary = {}
		for m: int in open_men:
			if restricted and not allowed.has(m):
				continue
			var anchor: Vector3 = cover_anchor(man_pos.get(m, Vector3.ZERO), our_net)
			var t: float = AIActionScoring.time_to_arrive(d_pos, anchor, d_vel, d_speed)
			var reach: float = 1.0 / (1.0 + maxf(t, 0.0))
			row[m] = maxf(man_value.get(m, 0.0), 0.0) * reach
		reward[d] = row

	var best: Array = _best_matching(0, open_defenders, open_men, {}, reward)
	var best_reward: float = best[0]
	var best_map: Dictionary = best[1]

	# Hysteresis: retain prev (restricted to the still-open defenders/men) if
	# it's still a valid matching and the fresh best doesn't beat it by the
	# margin. The house pin is excluded — its stickiness lives in
	# _pick_house_defender — so a stable house doesn't freeze the perimeter.
	var prev_open: Dictionary = _restrict_prev(prev, reward)
	var prev_reward: float = _matching_reward(prev_open, reward)
	if prev_reward >= 0.0 \
			and best_reward <= prev_reward * (1.0 + HYSTERESIS_MARGIN_FRAC):
		var kept_any: bool = false
		for d: int in prev_open:
			result[d] = prev_open[d]
			kept_any = true
		if kept_any:
			return result

	for d: int in best_map:
		result[d] = best_map[d]
	return result


# The men peer with the highest finish danger, if it clears NET_FRONT_DANGER_BAR
# — the net-front man defense must not leave open. -1 when no man is a genuine
# house threat (or man_danger wasn't supplied), which disables the override.
static func _most_dangerous_house_man(men: Array[int], man_danger: Dictionary) -> int:
	var best_man: int = -1
	var best_danger: float = -INF
	for m: int in men:
		var danger: float = man_danger.get(m, 0.0)
		if danger < NET_FRONT_DANGER_BAR:
			continue
		# Ties break to the lower peer id. `men` follows the SNAPSHOT's insertion
		# order (peer registration), not peer order, so without an explicit
		# tiebreak the winner of a symmetric pair — two net-front men mirrored
		# about the slot, which score bit-identically because score_shoot is
		# x-symmetric — would depend on who joined first.
		if danger > best_danger or (danger == best_danger and m < best_man):
			best_danger = danger
			best_man = m
	return best_man


# The defender pinned to the house man. Sticky: the defender that covered him
# last tick keeps him (no thrash on which body takes the net-front). With no
# incumbent (new threat / just entered the state), the defender that can reach
# his goal-side cover anchor soonest — a real reachability read, each at its own
# top speed.
static func _pick_house_defender(
		defenders: Array[int],
		defender_pos: Dictionary,
		defender_vel: Dictionary,
		defender_caps: Dictionary,
		house_man_pos: Vector3,
		house_man: int,
		our_net: Vector3,
		prev: Dictionary,
		eligible_men: Dictionary = {}) -> int:
	for d: int in defenders:
		if not _may_cover(d, house_man, eligible_men):
			continue
		if prev.get(d, -1) == house_man:
			return d
	var anchor: Vector3 = cover_anchor(house_man_pos, our_net)
	var best_def: int = -1
	var best_t: float = INF
	for d: int in defenders:
		if not _may_cover(d, house_man, eligible_men):
			continue
		var d_caps: AISkaterCaps = defender_caps.get(d)
		var d_speed: float = d_caps.max_speed if d_caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var t: float = AIActionScoring.time_to_arrive(
				defender_pos.get(d, Vector3.ZERO), anchor,
				defender_vel.get(d, Vector3.ZERO), d_speed)
		if t < best_t or (t == best_t and (best_def == -1 or d < best_def)):
			best_t = t
			best_def = d
	return best_def


# May defender `d` be given man `m`? True when `d` carries no area restriction
# (the man-marking backline) or when `m` stands inside the area it owns.
static func _may_cover(d: int, m: int, eligible_men: Dictionary) -> bool:
	var allowed: Dictionary = eligible_men.get(d, {})
	return allowed.is_empty() or allowed.has(m)


# Typed copy of `arr` with `exclude` removed.
static func _without(arr: Array[int], exclude: int) -> Array[int]:
	var out: Array[int] = []
	for v: int in arr:
		if v != exclude:
			out.append(v)
	return out


# prev entries whose defender AND man both survive in the current reward table —
# i.e. the previous matching restricted to the still-open (post-pin) sets.
static func _restrict_prev(prev: Dictionary, reward: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for d: int in prev:
		var m: int = prev[d]
		if reward.has(d) and (reward[d] as Dictionary).has(m):
			out[d] = m
	return out


# Goal-side cover point for a man: a stick into the man→our-net lane. Clamped
# so a man already at the net doesn't push the anchor past the goal line, and
# held in front of the line outright for a man AT/BEHIND it (corner lurker,
# wraparound walker). min(depth, dist) alone only stops the anchor overshooting
# the net CENTER, which would station a marker behind the goal line with his
# man — you front that man from the post, you don't chase him behind your own
# net (the goalie's RVH owns the wrap).
static func cover_anchor(man: Vector3, our_net: Vector3) -> Vector3:
	var to_net: Vector3 = our_net - man
	var dist: float = to_net.length()
	if dist < 0.001:
		return man
	var depth: float = minf(COVER_DEPTH_M, dist)
	var anchor: Vector3 = man + (to_net / dist) * depth
	var line_z: float = GameRules.GOAL_LINE_Z - AIRoleHelpers.GOAL_LINE_BUFFER_M
	if absf(anchor.z) > line_z:
		anchor.z = signf(anchor.z) * line_z
	return anchor


# Max-reward distinct-man matching, brute-forced. Returns [total_reward, map].
# Each defender either covers an unused man (adds reward[d][m]) or covers no one
# (adds 0) — so leaving a defender idle is allowed only when it can't improve
# the total (more defenders than men, or no positive-reward man left).
#
# Matchings of EXACTLY equal total break to the lower man peer id at the earliest
# defender they differ on, so the result is a function of the defender/man SETS
# and not of `men` order — that order is snapshot insertion order (peer
# registration), not peer order, so a symmetric geometry (two defenders and two
# men mirrored about x=0, the faceoff net-front) would otherwise resolve by who
# joined the session first, and a rejoin re-registering mid-session would flip a
# standing tie. HYSTERESIS_MARGIN_FRAC can't damp that: both matchings score
# identically, so the retain branch holds and whichever got there first sticks.
#
# The tiebreak is local at each level and still yields the lexicographically
# smallest assignment overall: sub[1] is already lex-minimal among the
# sub-problem's optima, so max-total-then-lowest-man at the earliest defender
# composes. Sorting `men` at the caller would also settle it, but it reorders
# this enumeration and so can move NEAR-tied live assignments too — a behavior
# change rather than a fix.
static func _best_matching(
		idx: int, defenders: Array[int], men: Array[int],
		used: Dictionary, reward: Dictionary) -> Array:
	if idx >= defenders.size():
		return [0.0, {}]
	var d: int = defenders[idx]
	var best_total: float = -1.0
	var best_map: Dictionary = {}
	var best_man: int = -1
	# Option A: this defender covers some unused man.
	var row: Dictionary = reward[d]
	for m: int in men:
		# `not row.has(m)` is the eligibility skip — see assign()'s ZONE
		# ELIGIBILITY note. Unrestricted defenders carry every man.
		if used.has(m) or not row.has(m):
			continue
		used[m] = true
		var sub: Array = _best_matching(idx + 1, defenders, men, used, reward)
		used.erase(m)
		var total: float = row[m] + sub[0]
		if total > best_total or (total == best_total and m < best_man):
			best_total = total
			best_map = (sub[1] as Dictionary).duplicate()
			best_map[d] = m
			best_man = m
	# Option B: this defender covers no one (idle). Only relevant when there's
	# no unused man left, but cheap to always consider for correctness. Strict
	# `>` so an equal-total cover is kept over idling — a defender on a man is
	# never worse than the same defender on nobody.
	var sub_idle: Array = _best_matching(idx + 1, defenders, men, used, reward)
	if sub_idle[0] > best_total:
		best_total = sub_idle[0]
		best_map = (sub_idle[1] as Dictionary).duplicate()
	return [best_total, best_map]


# Total reward of a given defender->man mapping under the current reward table.
# Returns -1.0 if the mapping is not a valid distinct matching against the
# current reward table (stale defender/man entry, or a duplicate man) — which
# signals "don't apply hysteresis, the partition changed shape".
static func _matching_reward(mapping: Dictionary, reward: Dictionary) -> float:
	if mapping.is_empty():
		return -1.0
	var seen_men: Dictionary = {}
	var total: float = 0.0
	for d: int in mapping:
		var m: int = mapping[d]
		if not reward.has(d) or not (reward[d] as Dictionary).has(m):
			return -1.0
		if seen_men.has(m):
			return -1.0
		seen_men[m] = true
		total += reward[d][m]
	return total
