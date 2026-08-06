extends GutTest

# RemoteController.sample_rendered_state_at — the source the local player's
# reconcile replay re-resolves body checks against.
#
# Stage-3 forward prediction moved the LIVE render onto a predicted timeline (an
# interpolated base a full interp_delay in the past, integrated forward toward
# host-present) but left this sampler reading the raw buffer at the caller's
# timestamp. Replay therefore re-derived contact against bodies roughly an
# interp_delay of travel behind the ones the live step — and the screen — actually
# collided with: ~0.5 m at skating speed, against a 0.7 m contact diameter, enough
# to flip the contact normal or lose the contact entirely on the very tick reconcile
# was correcting. These pin the sampler onto the render's construction, which is
# also the instant the host validates a hit claim at (HitClaimResolver rewinds the
# victim to remote_view_time, then forward-predicts by this same depth).

const _DELAY: float = 0.075   # interp_delay under test
const _SPEED: float = 6.0     # m/s, +X — skating pace

var _saved_delay: float = 0.0


func before_each() -> void:
	_saved_delay = NetworkManager._interp_delay
	NetworkManager._interp_delay = _DELAY


func after_each() -> void:
	NetworkManager._interp_delay = _saved_delay


func _controller() -> RemoteController:
	var rc := RemoteController.new()
	autofree(rc)
	return rc


# A body coasting straight down +X: no move intent, so the forward integration is
# a pure friction coast and the predicted travel is bounded by velocity × window.
func _state(x: float, ghost: bool = false) -> SkaterNetworkState:
	var s := SkaterNetworkState.new()
	s.position = Vector3(x, 0.0, 0.0)
	s.velocity = Vector3(_SPEED, 0.0, 0.0)
	s.facing = Vector2(0.0, 1.0)
	s.move_intent = Vector2.ZERO
	s.is_ghost = ghost
	return s


func _seed(rc: RemoteController, samples: Array) -> void:
	for pair: Array in samples:
		var buffered := BufferedSkaterState.new()
		buffered.timestamp = pair[0]
		buffered.state = pair[1]
		rc._state_buffer.append(buffered)


func test_sample_leads_its_interpolated_base_toward_the_requested_instant() -> void:
	# Base lands exactly on the middle sample (x = 0.6), so the prediction window
	# is the whole interp_delay and the expected travel is unambiguous.
	var rc := _controller()
	_seed(rc, [[0.0, _state(0.0)], [0.1, _state(0.6)], [0.2, _state(1.2)]])
	var sample: SkaterNetworkState = rc.sample_rendered_state_at(0.1 + _DELAY)
	assert_not_null(sample, "buffer brackets the base instant")
	var base_x: float = 0.6
	var coasting_x: float = base_x + _SPEED * _DELAY  # friction-free ceiling
	assert_gt(sample.position.x, base_x,
			"the sample must lead its interpolated-past base, not sit on it")
	assert_lt(sample.position.x, coasting_x + 0.001,
			"friction only ever slows the coast — never overshoot constant velocity")
	assert_gt(sample.position.x, base_x + _SPEED * _DELAY * 0.5,
			"at the shipped fraction the prediction covers most of the window")


func test_sample_is_not_the_raw_buffer_read_it_used_to_be() -> void:
	# The regression this file exists for: reading the buffer AT the passed
	# timestamp (rather than at timestamp − interp_delay, then predicting forward)
	# put replay a full interp_delay of travel behind the live contact. Query past
	# the newest sample — where the old code froze at the newest position.
	var rc := _controller()
	_seed(rc, [[0.0, _state(0.0)], [0.1, _state(0.6)]])
	var sample: SkaterNetworkState = rc.sample_rendered_state_at(0.1 + _DELAY)
	assert_not_null(sample, "buffer brackets the base instant")
	assert_gt(sample.position.x, 0.6 + _SPEED * _DELAY * 0.5,
			"a frozen newest-sample read would have returned 0.6")


func test_discrete_fields_come_from_the_newer_bracket_endpoint() -> void:
	# _interpolate takes booleans from the newer endpoint and writes them onto the
	# skater, so the LIVE resolver gated its contact on those values. Replay has to
	# gate on the same ones — is_ghost decides whether the pair collides at all, and
	# taking the earlier sample instead re-resolved pairs the live step had skipped.
	var rc := _controller()
	_seed(rc, [[0.0, _state(0.0, false)], [0.1, _state(0.6, true)],
			[0.2, _state(1.2, true)]])
	var sample: SkaterNetworkState = rc.sample_rendered_state_at(0.0 + _DELAY)
	assert_not_null(sample, "buffer brackets the base instant")
	assert_true(sample.is_ghost,
			"ghost flag follows the newer endpoint, matching what the render applied")


func test_empty_buffer_yields_null_so_the_caller_skips_the_pair() -> void:
	var rc := _controller()
	assert_null(rc.sample_rendered_state_at(0.1),
			"no buffer -> no reconstruction; the replay skips this skater")
