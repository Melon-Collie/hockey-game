extends GutTest

# The net thump's volume, and the reason it needed a signal payload to get one.
#
# Contact cues are deferred until after the tick commits — deliberately, so a
# listener sees this tick's committed state rather than last tick's. That is
# right for a cue that wants to know where the puck ENDED UP, and wrong for one
# that wants to know how hard it arrived, because the collision has already
# destroyed that. The twine is the extreme case: NET_RESTITUTION is 0.05, so a
# 25 m/s shot is travelling ~1.25 m/s by the time anything hears about it.
#
# Fed that, GameManager's volume curve — which spans 1 to 21 m/s — returned the
# same value for every net contact in the game, and a slapshot into the mesh
# sounded exactly like a dump-in. So `puck_hit_goal_body` carries the arrival
# speed, and these tests are what stop it being dropped again.
#
# The curve is asserted through ReplayEventReplayer's static mirror of it, which
# is the same formula GameManager uses (and the reason goal replays inherited the
# same dead cue).


func _volume(speed: float) -> float:
	return ReplayEventReplayer._puck_speed_volume(speed)


# The mechanism. Posts rebound at 0.55 and boards similarly, so their cues keep
# enough speed to land somewhere sensible on the curve — the net is the one
# surface that absorbs nearly everything, which is why it is the one cue that
# was silently broken.
func test_the_twine_swallows_almost_everything_a_shot_arrives_with() -> void:
	var out: Vector3 = PuckGeometryCollision.reflect_3d(
			Vector3(0.0, 0.0, 25.0), Vector3(0.0, 0.0, -1.0),
			PuckGeometryCollision.NET_RESTITUTION)
	assert_lt(out.length(), 2.0,
			"a 25 m/s shot leaves the twine under 2 m/s, which is why no contact " +
			"listener can recover the impact speed from the puck afterwards")
	var post: Vector3 = PuckGeometryCollision.reflect_3d(
			Vector3(0.0, 0.0, 25.0), Vector3(0.0, 0.0, -1.0),
			PuckGeometryCollision.POST_RESTITUTION)
	assert_gt(post.length(), 10.0,
			"the iron keeps most of it — the reason this bug was specific to the net")


# The bug itself, stated as the thing a player could hear: fed rebound speeds,
# the curve has no range left to work with.
func test_rebound_speeds_leave_the_volume_curve_with_no_range() -> void:
	var soft: float = _volume(0.4)    # an 8 m/s dump-in, after the twine
	var hard: float = _volume(1.25)   # a 25 m/s slapshot, after the twine
	assert_lt(absf(hard - soft), 0.5,
			"off the rebound a dump-in and a slapshot land within half a decibel " +
			"of each other (%.3f vs %.3f) — the cue cannot express the shot" %
			[soft, hard])


func test_arrival_speeds_use_the_range_the_curve_was_built_for() -> void:
	var soft: float = _volume(8.0)
	var hard: float = _volume(25.0)
	assert_gt(hard - soft, 4.0,
			"fed what the puck ARRIVED at, the same curve separates a dump-in from " +
			"a slapshot by several decibels (%.3f vs %.3f)" % [soft, hard])


# The plumbing that carries it: the payload has to survive the deferral, because
# the deferral is what made it unrecoverable in the first place.
func test_the_net_signal_reports_a_speed_the_puck_no_longer_has() -> void:
	var puck: Puck = autofree(Puck.new())
	var seen: Array[float] = []
	puck.puck_hit_goal_body.connect(func(spd: float) -> void: seen.append(spd))
	puck._queue_contact_event(Puck.ContactEvent.NET, null, null, 25.0)
	# What a listener reading the puck directly would have got instead.
	puck.linear_velocity = Vector3(0.0, 0.0, 1.25)
	puck.drain_contact_events()
	assert_eq(seen.size(), 1, "the net event drains once")
	assert_almost_eq(seen[0], 25.0, 1e-6,
			"and reports the arrival speed, not the %.2f m/s the puck is left with" %
			puck.linear_velocity.length())


# All three paths that play this cue must carry the arrival speed, because none
# of them can recover it: the host's own contact, a client's local prediction,
# and the host's broadcast to peers whose prediction missed it. The broadcast is
# the one that needed a wire change (PROTOCOL_VERSION 60) — and it is also the
# one most easily forgotten, since it only fires when prediction has already
# failed, which is rare enough to go unnoticed for a long time.
func _signal_args(obj: Object, signal_name: String) -> Array:
	for sig: Dictionary in obj.get_signal_list():
		if sig["name"] == signal_name:
			return sig["args"]
	return []


func test_every_net_cue_path_carries_the_arrival_speed() -> void:
	var puck: Puck = autofree(Puck.new())
	var local: Array = _signal_args(puck, "puck_hit_goal_body")
	assert_eq(local.size(), 1,
			"Puck.puck_hit_goal_body must carry the arrival speed (the host's own path)")

	var broadcast: Array = _signal_args(NetworkManager, "goal_body_hit_received")
	assert_eq(broadcast.size(), 2,
			"NetworkManager.goal_body_hit_received must carry position AND arrival " +
			"speed — a peer receiving only a position is back to reading the rebound")
	assert_eq(broadcast[1]["name"], "impact_speed",
			"and the second argument is the speed, not something else that fits")
