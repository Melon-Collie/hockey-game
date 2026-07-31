extends GutTest

# SkinToneRegistry — the identity skin-tone palette. Pins the wire/save
# contracts: index coercion (the join handshake and prefs load both clamp
# through it), palette-order stability at the ends, and that every tone is a
# real opaque color (a transparent or duplicate entry would ghost or alias
# two players' picks).


func test_clamp_coerces_any_index_into_the_palette() -> void:
	assert_eq(SkinToneRegistry.clamp_index(-5), 0, "negative clamps to first")
	assert_eq(SkinToneRegistry.clamp_index(0), 0)
	assert_eq(SkinToneRegistry.clamp_index(SkinToneRegistry.TONES.size() - 1),
			SkinToneRegistry.TONES.size() - 1)
	assert_eq(SkinToneRegistry.clamp_index(99), SkinToneRegistry.TONES.size() - 1,
			"overflow clamps to last")
	assert_eq(SkinToneRegistry.color_for(99),
			SkinToneRegistry.TONES[SkinToneRegistry.TONES.size() - 1],
			"color_for routes through the same clamp")


func test_default_index_is_valid() -> void:
	assert_eq(SkinToneRegistry.clamp_index(SkinToneRegistry.DEFAULT_INDEX),
			SkinToneRegistry.DEFAULT_INDEX)


func test_palette_tones_are_opaque_distinct_and_ordered_light_to_deep() -> void:
	var seen: Array[Color] = []
	var prev_luma: float = 2.0
	for tone: Color in SkinToneRegistry.TONES:
		assert_almost_eq(tone.a, 1.0, 0.001, "skin tones must be opaque")
		assert_false(seen.has(tone), "no duplicate tones — picks must stay distinguishable")
		seen.append(tone)
		var luma: float = tone.get_luminance()
		assert_lt(luma, prev_luma, "palette must stay ordered light to deep")
		prev_luma = luma
