extends GutTest

# The puck's contact signals that used to fan out synchronously from inside the
# timed physics sections are latched into a fixed-size queue and emitted by
# drain_contact_events (called by GameManager immediately before the snapshot
# capture + broadcast). These tests pin the queue's contract: nothing emits at
# queue time, the drain fires in emission order (interleaved across signal
# types), payload objects arrive intact, freed payloads are skipped, overflow
# drops the NEWEST events, and a drain leaves the queue empty.

const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")

var puck: Puck
var _order: Array[String] = []
var _loose_skaters: Array[Skater] = []


func before_each() -> void:
	puck = autofree(Puck.new())
	_order = []
	_loose_skaters = []
	puck.puck_hit_boards.connect(func() -> void: _order.append("boards"))
	puck.puck_touched_post.connect(func() -> void: _order.append("post"))
	puck.puck_hit_goal_body.connect(func() -> void: _order.append("net"))
	puck.puck_touched_loose.connect(func(s: Skater) -> void:
		_order.append("loose")
		_loose_skaters.append(s))
	puck.puck_body_blocked.connect(func(_s: Skater) -> void: _order.append("block"))


func test_nothing_emits_at_queue_time() -> void:
	puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	puck._queue_contact_event(Puck.ContactEvent.POST)
	assert_eq(_order.size(), 0, "queueing must not emit — emission happens at the drain")


func test_drain_emits_in_emission_order_across_signal_types() -> void:
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(skater)
	puck._queue_contact_event(Puck.ContactEvent.NET)
	puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	puck._queue_contact_event(Puck.ContactEvent.LOOSE_TOUCH, skater)
	puck._queue_contact_event(Puck.ContactEvent.POST)
	puck.drain_contact_events()
	assert_eq(_order, ["net", "boards", "loose", "post"],
		"drain preserves the order events were queued, not signal-type order")
	assert_eq(_loose_skaters.size(), 1)
	assert_eq(_loose_skaters[0], skater, "object payload delivered intact")


func test_drain_clears_the_queue() -> void:
	puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	puck.drain_contact_events()
	puck.drain_contact_events()
	assert_eq(_order, ["boards"], "a second drain emits nothing")


func test_overflow_drops_newest_beyond_capacity() -> void:
	for _i: int in Puck.CONTACT_QUEUE_CAPACITY:
		puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	# One past capacity: policy is drop-newest (with a push_warning), keeping
	# the already-queued events and their ordering intact.
	puck._queue_contact_event(Puck.ContactEvent.POST)
	puck.drain_contact_events()
	assert_eq(_order.size(), Puck.CONTACT_QUEUE_CAPACITY)
	assert_false(_order.has("post"), "the overflowing (newest) event is the one dropped")


func test_freed_payload_object_is_skipped() -> void:
	# A lag-comp deflect queued outside the physics frame drains on the NEXT
	# frame's hook, so its skater can be freed in between — the drain must skip
	# the stale ref instead of emitting it.
	var skater: Skater = SKATER_SCENE.instantiate() as Skater
	puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	puck._queue_contact_event(Puck.ContactEvent.LOOSE_TOUCH, skater)
	skater.free()
	puck.drain_contact_events()
	assert_eq(_order, ["boards"], "freed-payload event skipped; the rest still emit")


func test_event_queued_during_drain_is_serviced_in_the_same_drain() -> void:
	# A listener that causes a further queue mid-drain (e.g. a contact response
	# nudging the puck into another detector) must still be emitted before the
	# drain returns — i.e. still ahead of the snapshot capture.
	var chained: Array[bool] = [false]
	puck.puck_hit_boards.connect(func() -> void:
		if not chained[0]:
			chained[0] = true
			puck._queue_contact_event(Puck.ContactEvent.POST))
	puck._queue_contact_event(Puck.ContactEvent.BOARDS)
	puck.drain_contact_events()
	assert_eq(_order, ["boards", "post"])


func test_on_body_block_defers_its_signal_to_the_drain() -> void:
	# End-to-end through a real interaction entry point: the body-block path
	# (driven from PuckController's timed interaction check) queues instead of
	# emitting synchronously. Scene puck in the tree — on_body_block reads the
	# blocker's transform for its degenerate-normal fallback.
	var scene_puck: Puck = PUCK_SCENE.instantiate() as Puck
	add_child_autofree(scene_puck)
	var blocker: Skater = SKATER_SCENE.instantiate() as Skater
	add_child_autofree(blocker)
	var blocked: Array[Skater] = []
	scene_puck.puck_body_blocked.connect(func(s: Skater) -> void: blocked.append(s))
	scene_puck.set_server_mode(true)
	scene_puck.on_body_block(blocker, Vector3(0.0, 0.0, 1.0))
	assert_eq(blocked.size(), 0, "on_body_block must not emit synchronously")
	scene_puck.drain_contact_events()
	assert_eq(blocked, [blocker] as Array[Skater])
