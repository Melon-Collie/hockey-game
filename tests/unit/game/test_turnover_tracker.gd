extends GutTest

# TurnoverTracker — takeaways / giveaways / faceoff wins credit only at
# ESTABLISHMENT (on_possession_established), never on the pickup itself, so
# scrambles of momentary touches mint nothing. The candidate classification
# is computed at pickup time against the last ESTABLISHED owner (pure logic
# in TurnoverRules). Faceoff wins pend from the draw pickup to the first
# establishment, with resolve_pending_faceoff as the stoppage fallback.
# PlayerRegistry is constructed but its setup() is skipped; we populate
# the `_players` dict directly since only lookup methods are exercised.

var tracker: TurnoverTracker
var registry: PlayerRegistry


func before_each() -> void:
	registry = PlayerRegistry.new()
	tracker = TurnoverTracker.new()
	tracker.setup(registry)


func _add_player(peer_id: int, team_id: int, team_slot: int = 1) -> PlayerRecord:
	var team := Team.new()
	team.team_id = team_id
	var record := PlayerRecord.new(peer_id, team_slot, false, team)
	record.stats = PlayerStats.new()
	registry._players[peer_id] = record
	return record


# Shorthand: `peer` gains the puck and establishes possession.
func _gain_and_establish(peer: int) -> bool:
	tracker.on_carrier_gained(peer, false)
	return tracker.on_possession_established(peer)


# ── Takeaways ────────────────────────────────────────────────────────────────

func test_takeaway_credits_only_at_establishment() -> void:
	_add_player(10, 0)
	var stealer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)  # 20 strips 10, then recovers it themselves
	tracker.on_carrier_gained(20, false)
	assert_eq(stealer.stats.takeaways, 0, "pickup alone credits nothing")
	assert_true(tracker.on_possession_established(20))
	assert_eq(stealer.stats.takeaways, 1)


func test_takeaway_credits_the_stripper_not_the_recoverer() -> void:
	# The user's poke-to-a-teammate case: 20 strips the carrier and the loose
	# puck is recovered by 20's linemate 21. The takeaway is the STRIPPER's.
	_add_player(10, 0)
	var stripper := _add_player(20, 1)
	var recoverer := _add_player(21, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)     # 20 makes the defensive play
	tracker.on_carrier_gained(21, false)  # 21 corrals the loose puck
	assert_true(tracker.on_possession_established(21))
	assert_eq(stripper.stats.takeaways, 1, "credit the player who caused the loss")
	assert_eq(recoverer.stats.takeaways, 0, "not whoever happened to pick it up")


func test_goalie_strip_credits_no_takeaway() -> void:
	# A goalie strip carries stripper = -1: a skater recovers, but no player
	# takeaway is credited (the goalie made the play).
	_add_player(10, 0)
	var recoverer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, -1)
	tracker.on_carrier_gained(20, false)
	assert_false(tracker.on_possession_established(20), "no stat credited")
	assert_eq(recoverer.stats.takeaways, 0, "no skater stripper — no takeaway")


func test_scramble_touches_credit_nothing() -> void:
	# Board battle: strip, alternating momentary touches, nobody establishes.
	var owner := _add_player(10, 0)
	var stealer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)
	tracker.on_carrier_gained(20, false)  # touch...
	tracker.note_strip(20, 10)
	tracker.on_carrier_gained(10, false)  # ...counter-touch...
	tracker.note_strip(10, 20)
	tracker.on_carrier_gained(20, false)  # ...and again — still no control
	assert_eq(stealer.stats.takeaways, 0, "no establishment, no takeaway chain")
	assert_eq(owner.stats.takeaways, 0)
	assert_eq(owner.stats.giveaways, 0)


func test_takeaway_candidate_dies_when_recoverer_loses_it() -> void:
	# Stealer grabs the stripped puck but a teammate of the original owner
	# pokes it back and establishes — the takeaway candidate never lands.
	_add_player(10, 0)
	var teammate := _add_player(11, 0)
	var stealer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)
	tracker.on_carrier_gained(20, false)  # takeaway candidate armed...
	tracker.note_strip(20, 11)
	assert_false(_gain_and_establish(11))  # ...overwritten: same team as owner
	assert_eq(stealer.stats.takeaways, 0)
	assert_eq(teammate.stats.takeaways, 0, "recovery from a non-established touch")


func test_same_team_recovery_after_strip_is_nothing() -> void:
	_add_player(10, 0)
	var teammate := _add_player(11, 0)
	_gain_and_establish(10)
	tracker.note_strip(10, -1)
	assert_false(_gain_and_establish(11))
	assert_eq(teammate.stats.takeaways, 0)


# ── Giveaways ────────────────────────────────────────────────────────────────

func test_intercepted_pass_charges_giveaway_at_establishment() -> void:
	var passer := _add_player(10, 0)
	_add_player(20, 1)
	_gain_and_establish(10)
	tracker.on_carrier_gained(20, false)  # no strip, no shot — a fumble/pick
	assert_eq(passer.stats.giveaways, 0, "waits for the interceptor to establish")
	assert_true(tracker.on_possession_established(20))
	assert_eq(passer.stats.giveaways, 1)


func test_no_giveaway_when_interceptor_never_establishes() -> void:
	# Pass picked off but immediately pried loose and re-established by the
	# passing team — possession never actually changed hands.
	var passer := _add_player(10, 0)
	var teammate := _add_player(11, 0)
	_add_player(20, 1)
	_gain_and_establish(10)
	tracker.on_carrier_gained(20, false)
	tracker.note_strip(20, 11)
	_gain_and_establish(11)
	assert_eq(passer.stats.giveaways, 0)
	assert_eq(teammate.stats.takeaways, 0, "prev owner was same-team — no stat")


func test_rebound_recovery_is_neither_giveaway_nor_takeaway() -> void:
	# Any shot the other team recovers (saved, missed, or blocked) is a rebound,
	# not a turnover — no giveaway to the shooter, no takeaway to the recoverer.
	var shooter := _add_player(10, 0)
	var recoverer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_shot(10)  # fed from every shot release, on goal or not
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(shooter.stats.giveaways, 0, "a shot is never a giveaway")
	assert_eq(recoverer.stats.takeaways, 0, "recovering a shot is not a takeaway")


func test_shot_recovery_beats_a_coincident_strip() -> void:
	# recent_shot is checked before recent_strip: if a puck was both shot and
	# (rarely) grazed, its recovery still reads as a rebound, not a takeaway.
	_add_player(10, 0)
	var stripper := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)
	tracker.note_shot(10)
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(stripper.stats.takeaways, 0, "a shot recovery outranks the strip")


func test_dump_recovery_is_neither_giveaway_nor_takeaway() -> void:
	# A dump/clear the other team retrieves is a deliberate surrender to open
	# ice, not a giveaway to the dumper.
	var dumper := _add_player(10, 0)
	var recoverer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_dump(10)
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(dumper.stats.giveaways, 0, "a dump is never a giveaway")
	assert_eq(recoverer.stats.takeaways, 0, "retrieving a dump is not a takeaway")


func test_decayed_strip_still_credits_a_takeaway_not_a_giveaway() -> void:
	# A poke whose loose puck skitters a beat before the opponent recovers still
	# credits the defender a takeaway (wide window + establishment consumption) —
	# the stripped victim is never charged a giveaway for it.
	var victim := _add_player(10, 0)
	var stripper := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)
	tracker.on_carrier_gained(20, false)
	assert_true(tracker.on_possession_established(20))
	assert_eq(stripper.stats.takeaways, 1)
	assert_eq(victim.stats.giveaways, 0, "the stripped victim is never charged")


func test_strip_is_consumed_at_establishment() -> void:
	# The wide strip window must not bleed a stale takeaway onto a later, clean
	# loss. After the victim's own team re-establishes, a subsequent clean cough
	# is a giveaway, not a takeaway off the old strip.
	var owner := _add_player(10, 0)
	var teammate := _add_player(11, 0)
	var opp := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.note_strip(10, 20)
	_gain_and_establish(11)             # same team re-establishes — strip consumed
	tracker.on_carrier_gained(20, false)  # now a clean loss to the opponent
	assert_true(tracker.on_possession_established(20))
	assert_eq(opp.stats.takeaways, 0, "the old strip must not linger")
	assert_eq(teammate.stats.giveaways, 1, "clean loss by the new owner")
	assert_eq(owner.stats.giveaways, 0)


func test_contested_loose_puck_is_not_a_giveaway() -> void:
	# Board battle: team 0 loses it, team 1 touches, team 0 fights it back with a
	# touch, team 1 finally comes out with control. The losing team contested it —
	# not a clean cough-up, so no giveaway.
	var loser := _add_player(10, 0)
	_add_player(11, 0)
	_add_player(20, 1)
	_gain_and_establish(10)
	tracker.on_carrier_gained(20, false)  # opponent touches the loose puck
	tracker.on_carrier_gained(11, false)  # loser's team fights it back
	tracker.on_carrier_gained(20, false)  # opponent recovers again
	assert_false(tracker.on_possession_established(20), "contested loss credits nothing")
	assert_eq(loser.stats.giveaways, 0, "a lost battle is not a giveaway")


func test_clean_interception_after_an_own_retouch_is_still_a_giveaway() -> void:
	# A carrier who drops and re-grabs their own puck (no opponent touch between)
	# has not contested anything — a later clean interception is still a giveaway.
	var owner := _add_player(10, 0)
	_add_player(11, 0)
	_add_player(20, 1)
	_gain_and_establish(10)
	tracker.on_carrier_gained(11, false)  # own team re-touches (no opp touch yet)
	tracker.on_carrier_gained(20, false)  # opponent picks it off cleanly
	assert_true(tracker.on_possession_established(20))
	assert_eq(owner.stats.giveaways, 1, "an own re-touch is not a contest")


func test_no_stats_before_any_established_owner() -> void:
	var first := _add_player(20, 1)
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(first.stats.takeaways, 0)
	assert_eq(first.stats.giveaways, 0)


# ── Faceoff wins / losses ────────────────────────────────────────────────────

func test_draw_win_goes_to_first_team_to_establish() -> void:
	# Winger touches first, loses it, the OPPOSING side comes out of the
	# scramble with control — their centre gets the win (NHL: the draw is won
	# by the team that first gains possession, credited to the centre). The
	# beaten centre is charged a loss so faceoff % has a real denominator.
	var centre0 := _add_player(10, 0, 0)
	_add_player(11, 0, 1)
	var centre1 := _add_player(20, 1, 0)
	var winger1 := _add_player(21, 1, 1)
	tracker.on_carrier_gained(11, true)   # first touch off the drop
	assert_eq(centre0.stats.faceoff_wins, 0, "first touch is not the win")
	tracker.on_carrier_gained(21, false)  # scramble continues...
	assert_true(tracker.on_possession_established(21))
	assert_eq(centre1.stats.faceoff_wins, 1, "centre credited, not the winner")
	assert_eq(winger1.stats.faceoff_wins, 0)
	assert_eq(centre0.stats.faceoff_wins, 0)
	assert_eq(centre0.stats.faceoff_losses, 1, "beaten centre charged a loss")
	assert_eq(centre1.stats.faceoff_losses, 0)
	assert_eq(winger1.stats.faceoff_losses, 0, "loss goes to the centre, not the winger")
	assert_false(tracker.has_pending_faceoff())


func test_no_turnover_charged_on_the_draw() -> void:
	# The strip-and-recover inside the draw scramble is part of the faceoff —
	# NHL never charges a takeaway/giveaway on it.
	var centre0 := _add_player(10, 0, 0)
	var centre1 := _add_player(20, 1, 0)
	tracker.on_carrier_gained(10, true)
	tracker.note_strip(10, 20)
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(centre1.stats.takeaways, 0)
	assert_eq(centre0.stats.giveaways, 0)
	assert_eq(centre1.stats.faceoff_wins, 1)
	assert_eq(centre0.stats.faceoff_losses, 1)


func test_turnovers_resume_after_the_draw_resolves() -> void:
	var centre0 := _add_player(10, 0, 0)
	var centre1 := _add_player(20, 1, 0)
	tracker.on_carrier_gained(10, true)
	tracker.on_possession_established(10)  # team 0 wins the draw
	tracker.on_carrier_gained(20, false)   # then coughs it up
	tracker.on_possession_established(20)
	assert_eq(centre0.stats.faceoff_wins, 1)
	assert_eq(centre1.stats.faceoff_losses, 1)
	assert_eq(centre0.stats.giveaways, 1, "post-draw play classifies normally")
	assert_eq(centre1.stats.takeaways, 0, "interception without a strip")


func test_stoppage_fallback_resolves_pending_draw() -> void:
	var centre1 := _add_player(20, 1, 0)
	var centre0 := _add_player(10, 0, 0)
	tracker.on_carrier_gained(10, true)
	assert_true(tracker.has_pending_faceoff())
	assert_true(tracker.resolve_pending_faceoff(1))  # last toucher was team 1
	assert_eq(centre1.stats.faceoff_wins, 1)
	assert_eq(centre0.stats.faceoff_losses, 1)
	assert_false(tracker.has_pending_faceoff())


func test_fallback_with_unknown_team_clears_without_credit() -> void:
	var centre0 := _add_player(10, 0, 0)
	tracker.on_carrier_gained(10, true)
	assert_false(tracker.resolve_pending_faceoff(-1))
	assert_false(tracker.has_pending_faceoff())
	assert_eq(centre0.stats.faceoff_losses, 0, "unknown-team fallback credits nothing")


func test_resolve_without_pending_is_noop() -> void:
	var centre0 := _add_player(10, 0, 0)
	assert_false(tracker.resolve_pending_faceoff(0))
	assert_eq(centre0.stats.faceoff_wins, 0)
	assert_eq(centre0.stats.faceoff_losses, 0)


# ── Reset ────────────────────────────────────────────────────────────────────

func test_reset_clears_owner_and_pending_draw() -> void:
	var owner := _add_player(10, 0)
	var stealer := _add_player(20, 1)
	_gain_and_establish(10)
	tracker.reset()
	tracker.on_carrier_gained(20, false)
	tracker.on_possession_established(20)
	assert_eq(owner.stats.giveaways, 0, "reset forgot the previous owner")
	assert_eq(stealer.stats.takeaways, 0)
