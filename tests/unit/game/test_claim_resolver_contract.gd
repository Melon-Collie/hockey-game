extends GutTest

# Scripts/game/CLAUDE.md states the claim-resolver contract in prose and ends it
# with "A new claim resolver must follow all of it." Nothing held the four
# together, so each bullet was a coin-flip the next resolver re-flipped: the
# poke and stick-lift preambles were 33 duplicated lines, and the age bound was
# declared four times with a domain copy calling itself a mirror.
#
# The parts that are identical on every resolver are now single seams —
# LagCompRewind.claim_is_fresh for the age fence, ClaimantView for the
# claimant-side reconstruction — and this is what makes going through them the
# only way to write the fifth one.
#
# It reads source rather than exercising the resolvers because a resolver needs
# a live NetworkManager, a populated StateBufferManager and spawned skaters to
# reach the lines under test; the thing being asserted is structural anyway
# (WHICH seam is called), not numeric.

const _DIR: String = "res://Scripts/game"

var _sources: Dictionary = {}


# Comments are stripped: every assertion below is about which seam the resolver
# CALLS, and these headers name most of those seams in prose. Without this the
# ordering checks read `remote_view_time` out of the flow diagram at the top of
# the file and fail on a resolver that is correct.
func before_all() -> void:
	var dir: DirAccess = DirAccess.open(_DIR)
	assert_not_null(dir, "could not open %s" % _DIR)
	if dir == null:
		return
	for file: String in dir.get_files():
		if file.ends_with("_claim_resolver.gd"):
			_sources[file] = _strip(FileAccess.get_file_as_string("%s/%s" % [_DIR, file]))


func _strip(src: String) -> String:
	var out := PackedStringArray()
	for line: String in src.split("\n"):
		var h: int = line.find("#")
		out.append(line if h < 0 else line.substr(0, h))
	return "\n".join(out)


# Guards the guard — a discovery bug would leave every assertion below asserting
# nothing over an empty dictionary.
func test_every_resolver_is_discovered() -> void:
	for expected: String in ["pickup_claim_resolver.gd", "poke_claim_resolver.gd",
			"stick_lift_claim_resolver.gd", "hit_claim_resolver.gd"]:
		assert_true(_sources.has(expected), "%s should be discovered as a claim resolver" % expected)


func test_every_resolver_shares_one_age_fence() -> void:
	for file: String in _sources:
		var src: String = _sources[file]
		assert_true(src.contains("LagCompRewind.claim_is_fresh("),
				"%s must fence claim age through LagCompRewind.claim_is_fresh" % file)
		assert_false(src.contains("const MAX_CLAIM_AGE_S"),
				"%s declares its own claim-age bound — there is one, in ShotReleaseRules, " % file +
				"and four copies of a number is four chances to move one of them")


# The bullet with no symptom when skipped. Without the catch-up the claimant's
# own body is rewound short by (lead - one_way) and both clamps then fence an
# honest full-extension claim against a stale body — the claim just misses.
func test_every_resolver_reconstructs_the_claimant_through_one_seam() -> void:
	for file: String in _sources:
		var src: String = _sources[file]
		assert_true(src.contains("ClaimantView.new()") and src.contains(".resolve("),
				"%s must reconstruct the claimant through ClaimantView — the " % file +
				"self-view catch-up is not optional, and skipping it fails silently")
		for open_coded: String in ["LagCompRewind.self_view_catch_up(",
				"LagCompRewind.clamp_client_blade(", "LagCompRewind.continuity_clamp("]:
			assert_false(src.contains(open_coded),
					"%s open-codes `%s` instead of going through ClaimantView, " % [file, open_coded] +
					"which is how the three steps get done out of order or partially")


# Contract bullet 1: the client's self-reported delay is an anti-cheat bound, not
# a sanity check — unbounded, a modified client picks its own rewind depth. Tied
# to actually reading the delay, so PickupClaimResolver (whose rewinds are
# self-view and puck-view, neither of which consults it) is exempt structurally
# rather than by a comment saying so.
func test_any_resolver_that_reads_the_reported_delay_bounds_it_first() -> void:
	for file: String in _sources:
		var src: String = _sources[file]
		if not (src.contains("remote_view_time(") or src.contains("forward_predict_skater(")):
			continue
		var bound_at: int = src.find("LagCompRewind.plausible_interp_delay_ms(")
		assert_gt(bound_at, 0,
				"%s rewinds or forward-predicts a remote-view entity from the " % file +
				"client-reported interp delay without bounding it first")
		if bound_at <= 0:
			continue
		for reader: String in ["remote_view_time(", "forward_predict_skater("]:
			var uses_at: int = src.find(reader)
			if uses_at > 0:
				assert_gt(uses_at, bound_at,
						"%s reads the reported delay at `%s` before bounding it" % [file, reader])


# Bullet: "A claim resolves on the input stream's timeline, not on packet
# arrival" — every reject condition is evaluated at RELEASE from
# DeferredClaimQueue, so a resolver may not cache anything at the signal
# boundary. GameManager parking all four claims is what makes that true; a fifth
# wired straight from its signal to its resolver would adjudicate on arrival
# with nothing failing.
func test_no_claim_is_adjudicated_on_arrival() -> void:
	var gm: String = _strip(FileAccess.get_file_as_string("res://Scripts/game/game_manager.gd"))
	assert_false(gm.is_empty(), "could not read game_manager.gd")
	var handlers: PackedStringArray = _claim_handlers(gm)
	assert_eq(handlers.size(), 4,
			"expected one _on_*_claim_received handler per resolver, found %d" % handlers.size())
	for body: String in handlers:
		var head: String = body.split("\n")[0]
		assert_true(body.contains("_deferred_claims.submit("),
				"`%s` must park the claim in DeferredClaimQueue until the buffer " % head +
				"covers its self-view instant")
		assert_false(body.contains(".receive_claim("),
				"`%s` calls a resolver directly — that adjudicates on packet arrival, " % head +
				"where get_state_at silently answers the future query with its newest sample")


# Bodies of every `func _on_*_claim_received(...)`, up to the next top-level func.
func _claim_handlers(src: String) -> PackedStringArray:
	var out := PackedStringArray()
	var body: String = ""
	var inside: bool = false
	for line: String in src.split("\n"):
		if line.begins_with("func "):
			if inside:
				out.append(body)
			inside = line.begins_with("func _on_") and line.contains("_claim_received")
			body = ""
		if inside:
			body += line + "\n"
	if inside:
		out.append(body)
	return out
