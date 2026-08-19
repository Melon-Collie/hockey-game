extends GutTest

# ClaimantView — the claimant-side half every lag-comp claim resolver shares.
# The catch-up needs a live SkaterController to integrate against, so what is
# covered here is the part that decides how hard the two anti-cheat clamps bite:
# where the bounds come from, and what happens when the peer has no caps.

var view: ClaimantView
var registry: PlayerRegistry
var snap: SkaterNetworkState


func before_each() -> void:
	view = ClaimantView.new()
	registry = PlayerRegistry.new()
	snap = SkaterNetworkState.new()
	snap.position = Vector3.ZERO
	snap.blade_contact_world = Vector3(1.0, 0.0, 0.0)


func _with_caps(peer_id: int, reach: float, blade_speed: float) -> void:
	var caps := AISkaterCaps.new()
	caps.max_blade_reach = reach
	caps.blade_speed = blade_speed
	registry.caps_by_peer[peer_id] = caps


# No controller → no integration, so the catch-up is zero and the clamps read
# the raw snapshot. That is the shape every assertion below runs in.
func test_resolve_without_a_controller_leaves_the_body_where_it_was() -> void:
	assert_true(view.resolve(registry, 9, snap, null, 1.0, 1.0))
	assert_eq(view.catch_up(), Vector3.ZERO)


func test_resolve_rejects_a_missing_snapshot() -> void:
	assert_false(view.resolve(registry, 9, null, null, 1.0, 1.0),
			"no snapshot to reconstruct from — the caller must reject the claim rather " +
			"than clamp against nothing")


func test_reach_clamp_pulls_an_impossible_point_back_to_the_caps_ceiling() -> void:
	_with_caps(9, 2.0, 10.0)
	view.resolve(registry, 9, snap, null, 1.0, 1.0)
	var clamped: Vector3 = view.reach_clamp(Vector3(8.0, 0.0, 0.0), snap.position)
	assert_almost_eq(clamped.x, 2.0, 1e-5, "pulled back along the aim line to max_blade_reach")
	assert_eq(view.reach_clamp(Vector3(1.5, 0.0, 0.0), snap.position), Vector3(1.5, 0.0, 0.0),
			"a point already within reach passes through untouched")


# Missing caps is can't-happen for a spawned claimant, and the failure mode
# matters: clamping to a ZERO ceiling would pin every blade onto the body and
# refuse every honest claim. It has to fail open.
func test_no_caps_entry_disables_the_reach_clamp_rather_than_closing_it() -> void:
	view.resolve(registry, 404, snap, null, 1.0, 1.0)
	assert_eq(view.reach_clamp(Vector3(8.0, 0.0, 0.0), snap.position), Vector3(8.0, 0.0, 0.0))


func test_continuity_clamp_bites_at_the_blade_speed_tolerance() -> void:
	_with_caps(9, 2.0, 10.0)
	view.resolve(registry, 9, snap, null, 1.0, 1.0)
	var tol: float = LagCompRewind.blade_continuity_tolerance(10.0)
	var far: Vector3 = snap.blade_contact_world + Vector3(tol * 4.0, 0.0, 0.0)
	assert_almost_eq(view.continuity_clamp(far, snap.blade_contact_world).x,
			snap.blade_contact_world.x + tol, 1e-5,
			"clipped to the host's own reconstruction plus the traverse tolerance")


func test_a_faster_blade_earns_a_wider_continuity_tolerance() -> void:
	_with_caps(1, 2.0, 4.0)
	view.resolve(registry, 1, snap, null, 1.0, 1.0)
	var slow: Vector3 = view.continuity_clamp(Vector3(9.0, 0.0, 0.0), snap.blade_contact_world)
	_with_caps(2, 2.0, 20.0)
	view.resolve(registry, 2, snap, null, 1.0, 1.0)
	var fast: Vector3 = view.continuity_clamp(Vector3(9.0, 0.0, 0.0), snap.blade_contact_world)
	assert_gt(fast.x, slow.x,
			"the tolerance is the distance the blade can actually traverse in the " +
			"reconstruction window, so Hands has to move it")


# The composition the poke and stick-lift resolvers call: reach first, then
# continuity. Order matters — continuity is the tighter bound, so a reach clamp
# applied after it could push a point back OUT.
func test_clamp_blade_applies_both_bounds() -> void:
	_with_caps(9, 2.0, 10.0)
	view.resolve(registry, 9, snap, null, 1.0, 1.0)
	var out: Vector3 = view.clamp_blade(Vector3(50.0, 0.0, 0.0), snap)
	assert_lt(out.x, 2.0 + 0.001, "inside the reach ceiling")
	assert_almost_eq(out.x, snap.blade_contact_world.x
			+ LagCompRewind.blade_continuity_tolerance(10.0), 1e-5,
			"and inside the tighter continuity bound, which is the one that decides")


# A resolve() for a new claim must not leave the previous claimant's bounds
# behind — the instance is reused for every claim the resolver sees.
func test_resolve_clears_the_previous_claimants_bounds() -> void:
	_with_caps(1, 2.0, 10.0)
	view.resolve(registry, 1, snap, null, 1.0, 1.0)
	view.resolve(registry, 404, snap, null, 1.0, 1.0)
	assert_eq(view.reach_clamp(Vector3(8.0, 0.0, 0.0), snap.position), Vector3(8.0, 0.0, 0.0),
			"peer 404 has no caps — it must not inherit peer 1's reach ceiling")
