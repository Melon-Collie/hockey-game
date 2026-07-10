class_name AIThreatAssignment

# Pure "man-on-threat" partition: assigns each backline defender to a
# DISTINCT opponent it should cover. One central partition (computed once
# per brain tick in TeamBrain) replaces each defensive role independently
# minimizing the global-MAX threat — which made every defender gravitate to
# the single most dangerous opponent and stack in the slot, leaving the
# others open (the "crowded slot, open men" failure).
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
# Brute-forced over permutations: the backline is ≤ 3 skaters, so the matching
# is tiny (≤ 3! leaves). Runs at the 6 Hz brain tick, never the 120 Hz path.

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
# below it, trust the efficiency matching. score_shoot returns 0..1; a real
# net-front look past a carrier-tracking goalie sits well above this.
const NET_FRONT_DANGER_BAR: float = 0.45


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
		man_danger: Dictionary = {}) -> Dictionary[int, int]:
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
		var house_def: int = _pick_house_defender(
				defenders, defender_pos, defender_vel, defender_caps,
				man_pos.get(house_man, Vector3.ZERO), house_man, our_net, prev)
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
		# This defender covers at ITS real top speed (Speed) — a fast defender
		# reaches a further man in time, so it's assigned the harder cover.
		var d_caps: AISkaterCaps = defender_caps.get(d)
		var d_speed: float = d_caps.max_speed if d_caps != null \
				else AIActionScoring.SKATER_REF_SPEED_M_S
		var row: Dictionary = {}
		for m: int in open_men:
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
	var best_danger: float = NET_FRONT_DANGER_BAR
	for m: int in men:
		var danger: float = man_danger.get(m, 0.0)
		if danger >= best_danger:
			# >= with a rising floor: ties resolve to the lower peer id
			# (deterministic) since a strictly-greater danger is needed to switch.
			if danger > best_danger or best_man == -1:
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
		prev: Dictionary) -> int:
	for d: int in defenders:
		if prev.get(d, -1) == house_man:
			return d
	var anchor: Vector3 = cover_anchor(house_man_pos, our_net)
	var best_def: int = -1
	var best_t: float = INF
	for d: int in defenders:
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
# so a man already at the net doesn't push the anchor past the goal line.
static func cover_anchor(man: Vector3, our_net: Vector3) -> Vector3:
	var to_net: Vector3 = our_net - man
	var dist: float = to_net.length()
	if dist < 0.001:
		return man
	var depth: float = minf(COVER_DEPTH_M, dist)
	return man + (to_net / dist) * depth


# Max-reward distinct-man matching, brute-forced. Returns [total_reward, map].
# Each defender either covers an unused man (adds reward[d][m]) or covers no one
# (adds 0) — so leaving a defender idle is allowed only when it can't improve
# the total (more defenders than men, or no positive-reward man left).
static func _best_matching(
		idx: int, defenders: Array[int], men: Array[int],
		used: Dictionary, reward: Dictionary) -> Array:
	if idx >= defenders.size():
		return [0.0, {}]
	var d: int = defenders[idx]
	var best_total: float = -1.0
	var best_map: Dictionary = {}
	# Option A: this defender covers some unused man.
	var row: Dictionary = reward[d]
	for m: int in men:
		if used.has(m):
			continue
		used[m] = true
		var sub: Array = _best_matching(idx + 1, defenders, men, used, reward)
		used.erase(m)
		var total: float = row[m] + sub[0]
		if total > best_total:
			best_total = total
			best_map = (sub[1] as Dictionary).duplicate()
			best_map[d] = m
	# Option B: this defender covers no one (idle). Only relevant when there's
	# no unused man left, but cheap to always consider for correctness.
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
