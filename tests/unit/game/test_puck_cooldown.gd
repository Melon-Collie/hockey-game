extends GutTest

# Puck per-skater pickup cooldowns store ABSOLUTE expiry timestamps (host
# local_time base) so the lag-comp pickup resolver can ask whether a skater was
# on cooldown at their view-time, not just at present time. These tests inject a
# controllable clock and pin: present-time query, the view-time query that the
# resolver relies on, the never-shorten max semantics, and removal.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")

var puck: Puck
var skater: Skater
var _clock: float = 100.0


func _now() -> float:
	return _clock


func before_each() -> void:
	puck = autofree(Puck.new())
	puck.set_time_provider(_now)
	skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)


func test_present_time_query_tracks_the_injected_clock() -> void:
	_clock = 100.0
	puck.set_skater_cooldown(skater, 0.5)   # expiry = 100.5
	assert_true(puck.is_on_cooldown(skater), "active right after arming")
	_clock = 100.4
	assert_true(puck.is_on_cooldown(skater), "still active before expiry")
	_clock = 100.6
	assert_false(puck.is_on_cooldown(skater), "expired past 100.5")


func test_view_time_query_denies_a_claim_that_was_on_cooldown_when_sent() -> void:
	# The reason the store is timestamp-based: a cooldown can expire between the
	# claimant's view-time and the host processing their claim. Present-time would
	# grant; the view-time query correctly denies.
	_clock = 100.0
	puck.set_skater_cooldown(skater, 0.5)    # expiry = 100.5
	_clock = 100.6                            # present: expired
	assert_false(puck.is_on_cooldown(skater), "off cooldown at present")
	assert_true(puck.is_on_cooldown_at(skater, 100.3),
		"but a claim viewed at 100.3 was still on cooldown")
	assert_false(puck.is_on_cooldown_at(skater, 100.55),
		"and one viewed just after expiry was not")


func test_never_shortens_an_in_flight_cooldown() -> void:
	# A shorter cooldown armed right after a longer one must not pull the expiry in.
	_clock = 100.0
	puck.set_skater_cooldown(skater, 0.5)    # expiry 100.5
	puck.set_skater_cooldown(skater, 0.1)    # 100.1 < 100.5 — must be ignored
	assert_true(puck.is_on_cooldown_at(skater, 100.4))


func test_stale_expired_entry_is_superseded_not_maxed() -> void:
	# An expired entry (expiry < now) must not clamp a fresh arming upward.
	_clock = 100.0
	puck.set_skater_cooldown(skater, 0.5)    # expiry 100.5
	_clock = 200.0                            # long past expiry, entry may linger
	puck.set_skater_cooldown(skater, 0.5)    # fresh expiry 200.5, not maxed to a stale value
	assert_true(puck.is_on_cooldown_at(skater, 200.4), "fresh window active")
	assert_false(puck.is_on_cooldown_at(skater, 200.6),
		"fresh cooldown expires at 200.5 — a stale entry did not inflate it")


func test_remove_clears_cooldown() -> void:
	_clock = 100.0
	puck.set_skater_cooldown(skater, 0.5)
	puck.remove_skater_cooldown(skater)
	assert_false(puck.is_on_cooldown(skater))


func test_unknown_skater_is_never_on_cooldown() -> void:
	assert_false(puck.is_on_cooldown(skater))
	assert_false(puck.is_on_cooldown_at(skater, 100.0))
