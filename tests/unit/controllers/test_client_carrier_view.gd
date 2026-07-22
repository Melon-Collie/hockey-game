extends GutTest

# PuckController's client-side carrier view — _client_carrier_peer_id plus the
# get_client_carrier_peer_id / get_client_carrier_skater accessors that
# LocalController's claim gate branches on (loose → pickup claim, opposing
# carrier → poke/stick-lift claim). The view is written EXCLUSIVELY by the
# carrier-event notify paths; puck.carrier is host-only and permanently null on
# clients — gating claims on it is exactly the bug that left the
# poke/stick-lift claim path unreachable, so these tests pin the event-driven
# view transitions directly.
#
# Skater references are exercised with null (the unspawned-carrier shape) —
# instantiating a full Skater headless is integration territory; the peer-id
# watermarking is the load-bearing state here.

const REMOTE_PID: int = 424242


func _pc() -> PuckController:
	var pc := PuckController.new()
	# Off-tree Puck: only plain @export properties (reattach_cooldown,
	# nudge_cooldown) are read by the notify paths under test.
	pc.puck = Puck.new()
	autofree(pc.puck)
	autofree(pc)
	return pc


func test_view_starts_loose() -> void:
	var pc := _pc()
	assert_eq(pc.get_client_carrier_peer_id(), -1, "no carrier before any event")
	assert_null(pc.get_client_carrier_skater(), "no carrier skater before any event")


func test_remote_carrier_changed_sets_view_without_a_spawned_skater() -> void:
	# The "carrier known, skater unspawned/local" path: the view must still hold
	# the peer id (suppresses pickup claims against the carried puck) while the
	# skater accessor stays null (no geometry to aim a poke claim at).
	var pc := _pc()
	pc.notify_remote_carrier_changed(REMOTE_PID)
	assert_eq(pc.get_client_carrier_peer_id(), REMOTE_PID, "carrier event installs the pid")
	assert_null(pc.get_client_carrier_skater(), "no local skater for this carrier")


func test_remote_carrier_changed_to_loose_clears_view() -> void:
	var pc := _pc()
	pc.notify_remote_carrier_changed(REMOTE_PID)
	pc.notify_remote_carrier_changed(-1)
	assert_eq(pc.get_client_carrier_peer_id(), -1, "carrier=-1 event returns the view to loose")


func test_local_pickup_claims_local_peer_id() -> void:
	var pc := _pc()
	pc.notify_local_pickup(null)
	assert_eq(pc.get_client_carrier_peer_id(), NetworkManager.local_peer_id(),
			"granted local pickup marks US as the view carrier")


func test_remote_pickup_installs_carrier_pid() -> void:
	var pc := _pc()
	pc.notify_remote_pickup(null, REMOTE_PID)
	assert_eq(pc.get_client_carrier_peer_id(), REMOTE_PID, "remote pin carries its peer id")


func test_forced_drop_resets_view() -> void:
	var pc := _pc()
	pc.notify_local_pickup(null)
	pc.notify_local_puck_dropped()
	assert_eq(pc.get_client_carrier_peer_id(), -1, "forced drop (goal/steal) returns to loose")


func test_pickup_after_remote_carry_overwrites_view() -> void:
	# Steal shape: remote carried, then WE get the grant — the view must follow
	# the newest event, not the stale remote pin.
	var pc := _pc()
	pc.notify_remote_pickup(null, REMOTE_PID)
	pc.notify_local_pickup(null)
	assert_eq(pc.get_client_carrier_peer_id(), NetworkManager.local_peer_id(),
			"newest carrier event wins the view")
