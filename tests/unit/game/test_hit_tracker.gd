extends GutTest

# HitTracker — NHL-style hit crediting: the victim must be in possession, and
# the stat lands only when the contact DISPOSSESSES them (or the check
# finishes within the just-released grace). Resolution is order-dependent:
# contact → strip credits, contact → deliberate pass/shot CANCELS (they
# played through the check), release → contact within grace credits (a
# finished check). `impact_landed` fires at contact time (drives the VFX
# broadcast); `hit_credited` fires when the stat lands.
# PlayerRegistry is constructed but its setup() is skipped; we populate
# the `_players` dict directly since only lookup methods are exercised.

const IMPULSE: float = HitRules.MIN_HIT_IMPULSE + 2.0

var tracker: HitTracker
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	tracker = HitTracker.new()
	tracker.setup(registry)


func _add_player(peer_id: int, team_id: int) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, 0, false, team)
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


# Cross-team contact on the puck carrier — the canonical pending-hit setup.
func _contact_on_carrier(hitter: int = 1, victim: int = 2, victim_team: int = 1,
		force: float = IMPULSE, dir: Vector3 = Vector3.FORWARD) -> void:
	tracker.on_contact(hitter, victim, victim_team, force, dir, false, true)


# ── Contact on the carrier: pending until dispossession ─────────────────────

func test_contact_on_carrier_does_not_credit_immediately() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	assert_eq(hitter.stats.hits, 0, "stat waits for the dispossession")

func test_strip_credits_pending_hit() -> void:
	var hitter := _add_player(1, 0)
	var victim := _add_player(2, 1)
	_contact_on_carrier()
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 1)
	assert_eq(victim.stats.hits_taken, 1)

func test_pending_expires_without_dispossession() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	tracker.tick(HitRules.POSSESSION_LOSS_WINDOW_S + 0.01)
	tracker.note_possession_stripped(2)  # too late — carrier absorbed the check
	assert_eq(hitter.stats.hits, 0)

func test_strip_within_window_after_ticks_credits() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	tracker.tick(HitRules.POSSESSION_LOSS_WINDOW_S / 2.0)
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 1)

func test_strip_of_other_player_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_add_player(3, 1)
	_contact_on_carrier()
	tracker.note_possession_stripped(3)
	assert_eq(hitter.stats.hits, 0)


# ── Order dependence: playing through the check is NOT a hit ─────────────────

func test_deliberate_release_cancels_pending_hit() -> void:
	# Contact lands while carrying, then the carrier gets a pass away within
	# the window — the check did NOT dispossess them, so no hit.
	var hitter := _add_player(1, 0)
	var victim := _add_player(2, 1)
	_contact_on_carrier()
	tracker.note_possession_released(2)
	assert_eq(hitter.stats.hits, 0, "the carrier played through the check")
	assert_eq(victim.stats.hits_taken, 0)

func test_strip_after_cancelling_release_does_not_revive_pending() -> void:
	# Pass cancels the pending; a later strip event (e.g. the pass receiver's
	# own battle misattributed to this victim) must find nothing to credit.
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	tracker.note_possession_released(2)
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 0)


# ── Contact within the just-released grace: immediate credit ─────────────────

func test_contact_right_after_pass_credits_immediately() -> void:
	# The classic finished check — the pass beats the contact by a beat, the
	# hit still lands. NHL scorers credit this.
	var hitter := _add_player(1, 0)
	var victim := _add_player(2, 1)
	tracker.note_possession_released(2)
	tracker.tick(HitRules.JUST_RELEASED_GRACE_S / 2.0)
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	assert_eq(hitter.stats.hits, 1, "finished check — credits without a new loss")
	assert_eq(victim.stats.hits_taken, 1)

func test_contact_right_after_strip_credits_immediately() -> void:
	# Same-tick strip race: the claim can arrive after the host already saw
	# the puck come loose — the strip-side grace covers it.
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.note_possession_stripped(2)
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	assert_eq(hitter.stats.hits, 1)

func test_contact_after_grace_expires_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.note_possession_released(2)
	tracker.tick(HitRules.JUST_RELEASED_GRACE_S + 0.01)
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	assert_eq(hitter.stats.hits, 0)

func test_regaining_possession_clears_grace() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.note_possession_released(2)
	tracker.note_possession_gained(2)
	# Not flagged as carrier here (stale claim view) — with the grace cleared
	# there is nothing to credit against.
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	assert_eq(hitter.stats.hits, 0)


# ── Stoppages: nothing carries across dead play ──────────────────────────────

func test_play_stopped_kills_pending_hit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	tracker.on_play_stopped()  # whistle before any dispossession
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 0, "the play the check would finish is dead")

func test_play_stopped_clears_release_grace() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.note_possession_released(2)
	tracker.on_play_stopped()
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	assert_eq(hitter.stats.hits, 0, "a post-whistle shove is not a finished check")


# ── Rejection gates ──────────────────────────────────────────────────────────

func test_contact_on_non_carrier_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	watch_signals(tracker)
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, false, false)
	tracker.note_possession_stripped(2)  # loose-puck battle bump — never possessed
	assert_eq(hitter.stats.hits, 0)
	assert_signal_not_emitted(tracker, "impact_landed")

func test_contact_on_teammate_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 0)
	watch_signals(tracker)
	tracker.on_contact(1, 2, 0, IMPULSE, Vector3.FORWARD, false, true)
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 0)
	assert_signal_not_emitted(tracker, "impact_landed")

func test_attacker_carrying_puck_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	tracker.on_contact(1, 2, 1, IMPULSE, Vector3.FORWARD, true, false)
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 0)

func test_below_impulse_threshold_does_not_credit() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier(1, 2, 1, HitRules.MIN_HIT_IMPULSE - 0.5)
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 0)

func test_unknown_hitter_does_nothing() -> void:
	_add_player(2, 1)
	watch_signals(tracker)
	tracker.on_contact(999, 2, 1, IMPULSE, Vector3.FORWARD, false, true)
	assert_signal_not_emitted(tracker, "impact_landed")


# ── Signals + impact broadcast payload (Lever A) ─────────────────────────────

func test_impact_fires_at_contact_time_for_pending_hit() -> void:
	_add_player(1, 0)
	_add_player(2, 1)
	watch_signals(tracker)
	var dir := Vector3(0.0, 0.0, 1.0)
	_contact_on_carrier(1, 2, 1, 7.5, dir)
	# Hitter peer id leads the payload (v19): the broadcast drives the hitter's
	# check-delivery pose as well as the victim-side burst/thud.
	assert_signal_emitted_with_parameters(tracker, "impact_landed", [1, 2, 7.5, dir])
	assert_signal_not_emitted(tracker, "hit_credited",
			"stat waits for the dispossession")

func test_impact_still_fires_when_pending_later_cancels() -> void:
	# The burst/sound already played at contact time — cancelling the stat via
	# a pass must not retract the impact, only withhold `hit_credited`.
	_add_player(1, 0)
	_add_player(2, 1)
	watch_signals(tracker)
	_contact_on_carrier()
	tracker.note_possession_released(2)
	assert_signal_emit_count(tracker, "impact_landed", 1)
	assert_signal_not_emitted(tracker, "hit_credited")

func test_hit_credited_carries_victim_force_and_dir() -> void:
	_add_player(1, 0)
	_add_player(2, 1)
	watch_signals(tracker)
	var dir := Vector3(0.0, 0.0, 1.0)
	_contact_on_carrier(1, 2, 1, 7.5, dir)
	tracker.note_possession_stripped(2)
	assert_signal_emitted_with_parameters(tracker, "hit_credited", [2, 7.5, dir])

func test_impact_suppressed_within_cooldown() -> void:
	# The per-pair dedup gates the broadcast payload — a sustained grind emits
	# at most one impact per cooldown, which is the cadence the broadcast wants.
	_add_player(1, 0)
	_add_player(2, 1)
	watch_signals(tracker)
	_contact_on_carrier(1, 2, 1, 7.5)
	_contact_on_carrier(1, 2, 1, 9.0)  # same pair, within cooldown
	assert_signal_emit_count(tracker, "impact_landed", 1)

func test_grind_credits_at_most_one_hit_per_cooldown() -> void:
	var hitter := _add_player(1, 0)
	_add_player(2, 1)
	_contact_on_carrier()
	_contact_on_carrier()  # same sustained contact, still within cooldown
	tracker.note_possession_stripped(2)
	assert_eq(hitter.stats.hits, 1)
