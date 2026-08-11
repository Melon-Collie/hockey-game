extends GutTest

# Does the blade actually end up on an incoming feed?
#
# The reception aim is a chain of reads — is it coming to me, where do we meet,
# which side do I stand, where does the blade wait — and every one of them is
# individually defensible while the catch still misses. So this measures the
# only thing that settles it: fire a feed at a bot and see whether it comes out
# of the sequence carrying the puck. Swept over crossing angles, lateral
# offsets, feed paces and the receiver's own motion, because the failure this
# was built for is specifically a MOVING receiver's (a standing one has no
# frame problem to get wrong).
#
# The blade-slew number below is the load-bearing one: a cursor that has to
# travel further than the hands can move it in a tick is a stick that arrives
# after the puck.

const Harness := preload("res://tests/unit/ai/duel_harness.gd")

const OURS: int = 1
const THEIRS: int = 11
# Long enough for the slowest sweep case to resolve, short enough that a bot
# which missed the catch and had to turn around doesn't get credit for the
# second attempt.
const CATCH_WINDOW_S: float = 1.6


# Fires a REAL feed at a receiver — aimed through AIPassLead, the same solver
# the carrier scores and fires with — and returns true if the receiver is
# carrying when the dust settles. Aiming it any other way measures the bot's
# ability to run down a bad pass, which is a different skill and swamps this one.
func _catches(recv_pos: Vector3, recv_vel: Vector3,
		from_pos: Vector3, speed: float) -> bool:
	var h = Harness.new()
	h.add_skater(OURS, 0, recv_pos, null, recv_vel)
	# A body on the other team, parked at the far end: the role election needs
	# two teams, and this one is much too far away to contest anything.
	h.add_skater(THEIRS, 1, Vector3(0, 0, 24))
	h.start(-1, from_pos)
	var target := SkaterNetworkState.new()
	target.position = recv_pos
	target.velocity = recv_vel
	var aim: Vector3 = AIPassLead.lead_point(from_pos, target, Vector3.ZERO, speed,
			AIRoleCarrier.PASS_LEAD_MAX_S)
	var dir: Vector3 = aim - from_pos
	dir.y = 0.0
	h.puck_vel = dir.normalized() * speed
	var n: int = int(CATCH_WINDOW_S / Harness.DT)
	for _i: int in n:
		h.step()
		if h.carrier() == OURS:
			return true
	return false


# One sweep row per receiver motion, over a spread of feed paces and passer
# bearings — the feed is led properly in every one, so a miss is a reception
# miss.
func _sweep(recv_vel: Vector3) -> Array:
	var caught: int = 0
	var total: int = 0
	for speed: float in [10.0, 13.0, 16.0, 19.0]:
		for from_pos: Vector3 in [
				Vector3(-11.0, 0, -4.0), Vector3(-7.0, 0, -14.0),
				Vector3(0.0, 0, -2.0), Vector3(9.0, 0, -9.0),
				Vector3(6.0, 0, -20.0), Vector3(-10.0, 0, -18.0)]:
			total += 1
			if _catches(Vector3(0, 0, -12), recv_vel, from_pos, speed):
				caught += 1
	return [caught, total]


func test_a_moving_receiver_catches_the_feed() -> void:
	# Four receiver motions over the same feed set: standing, skating into the
	# lane, streaking away up ice, and cutting across it. The standing row is the
	# control — it has no frame problem, so it must stay high whatever happens to
	# the others.
	var rows: Array = [
			["standing", Vector3.ZERO],
			["into the lane", Vector3(0, 0, 4.0)],
			["streaking away", Vector3(0, 0, -7.0)],
			["cutting across", Vector3(6.0, 0, -3.0)],
	]
	var caught_all: int = 0
	var total_all: int = 0
	for row: Array in rows:
		var r: Array = _sweep(row[1])
		caught_all += r[0]
		total_all += r[1]
		gut.p("  %-16s %d/%d caught (%.0f%%)"
				% [row[0], r[0], r[1], 100.0 * r[0] / maxf(r[1], 1)])
	var rate: float = 100.0 * caught_all / maxf(total_all, 1)
	gut.p("  overall %d/%d (%.0f%%)" % [caught_all, total_all, rate])
	assert_gt(rate, 80.0, "most feeds aimed at a bot are actually received")
