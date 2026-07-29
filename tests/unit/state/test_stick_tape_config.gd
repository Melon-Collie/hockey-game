extends GutTest

# StickTapeConfig is wire data (the packed code rides the join and spawn
# payloads), so the invariants worth pinning are the wire ones: every legal
# pick round-trips through the code exactly, garbage coerces to a legal job
# instead of being trusted, the all-default job IS code 0 (so payloads that
# omit the field decode to the pre-customization look), and the span table
# stays inside the blade the mesh builder will be handed.


func test_default_is_code_zero() -> void:
	var config := StickTapeConfig.new()
	assert_eq(config.to_code(), StickTapeConfig.DEFAULT_CODE, "untouched job packs to 0")
	assert_eq(config.blade_color, TapeColorRegistry.TEAM_INDEX)
	assert_eq(config.span, StickTapeConfig.Span.HEEL_TO_MID)
	assert_eq(config.knob_color, TapeColorRegistry.TEAM_INDEX)


func test_every_legal_pick_round_trips() -> void:
	for blade_color: int in TapeColorRegistry.count():
		for span: int in StickTapeConfig.Span.size():
			for knob_color: int in TapeColorRegistry.count():
				var config := StickTapeConfig.new(blade_color, span, knob_color)
				var back: StickTapeConfig = StickTapeConfig.from_code(config.to_code())
				assert_eq(back.blade_color, blade_color)
				assert_eq(back.span, span)
				assert_eq(back.knob_color, knob_color)


func test_garbage_codes_coerce_to_legal_jobs() -> void:
	for code: int in [-1, -999, 1 << 20, 0x7FFFFFFF]:
		var config: StickTapeConfig = StickTapeConfig.from_code(code)
		assert_true(TapeColorRegistry.is_valid(config.blade_color), "blade color legal")
		assert_true(TapeColorRegistry.is_valid(config.knob_color), "knob color legal")
		assert_between(config.span, 0, StickTapeConfig.Span.size() - 1, "span legal")
		# And the coerced job re-packs stably (idempotent coercion).
		var code2: int = config.to_code()
		assert_eq(StickTapeConfig.from_code(code2).to_code(), code2)


func test_span_ranges_stay_on_the_blade() -> void:
	for span: int in StickTapeConfig.Span.size():
		var config := StickTapeConfig.new(0, span, 0)
		var r: Vector2 = config.span_range()
		assert_between(r.x, -0.02, 1.0, "span start on the blade (heel overhang allowed)")
		assert_between(r.y, 0.0, 1.0, "span end on the blade")
		if config.has_blade_tape():
			assert_gt(r.y, r.x, "non-NONE spans run heel→toe")
		else:
			assert_eq(span, StickTapeConfig.Span.NONE, "only NONE is empty")


func test_team_and_invalid_indices_resolve_to_accent() -> void:
	var accent := Color(0.2, 0.6, 0.9)
	assert_eq(TapeColorRegistry.resolve(TapeColorRegistry.TEAM_INDEX, accent), accent,
			"TEAM resolves to the team accent")
	assert_eq(TapeColorRegistry.resolve(99, accent), accent, "out-of-range falls back")
	assert_eq(TapeColorRegistry.resolve(-3, accent), accent, "negative falls back")
	var white: Color = TapeColorRegistry.resolve(1, accent)
	assert_ne(white, accent, "a real palette pick ignores the accent")


func test_palette_and_name_keys_stay_in_lockstep() -> void:
	assert_eq(TapeColorRegistry.NAME_KEYS.size(), TapeColorRegistry.count(),
			"every palette entry has a display key")
