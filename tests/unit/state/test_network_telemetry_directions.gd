extends GutTest

# Send and receive are separate measurements taken on separate machines: a host
# never receives its own world state, and a client never broadcasts one. Reusing
# one counter for both is what made the F3 host row's "Snapshots out" read 0/s in
# every phase of every session — a broadcast failure's signature, shown to
# whoever was debugging a broadcast.
#
# These pin that the two counters stay independent, so a call site wired to the
# wrong one leaves its own field at zero instead of borrowing the other's number.

var _saved_instance: NetworkTelemetry = null

func before_each() -> void:
	_saved_instance = NetworkTelemetry.instance

func after_each() -> void:
	NetworkTelemetry.instance = _saved_instance


func _fresh() -> NetworkTelemetry:
	var t := NetworkTelemetry.new()
	NetworkTelemetry.instance = t
	return t


func test_the_host_side_counter_publishes_the_send_rate() -> void:
	var t := _fresh()
	for _i: int in Constants.STATE_RATE:
		NetworkTelemetry.record_world_state_sent()
	t.tick(1.0)
	assert_almost_eq(t.world_state_sent_hz, float(Constants.STATE_RATE), 0.001)
	# A host receives nothing, so its receive figure stays a structural zero.
	assert_almost_eq(t.world_state_hz, 0.0, 0.001)


func test_the_client_side_counter_publishes_the_receive_rate() -> void:
	var t := _fresh()
	for _i: int in Constants.STATE_RATE:
		NetworkTelemetry.record_world_state()
	t.tick(1.0)
	assert_almost_eq(t.world_state_hz, float(Constants.STATE_RATE), 0.001)
	assert_almost_eq(t.world_state_sent_hz, 0.0, 0.001)


func test_both_counters_reset_between_windows() -> void:
	var t := _fresh()
	NetworkTelemetry.record_world_state_sent()
	NetworkTelemetry.record_world_state()
	t.tick(1.0)
	t.tick(1.0)
	assert_almost_eq(t.world_state_sent_hz, 0.0, 0.001,
			"a stale send count would keep reporting a broadcast that stopped")
	assert_almost_eq(t.world_state_hz, 0.0, 0.001)
