extends GutTest

# The gear workbench builds its rows and its turntable preview in code, so
# nothing but running it proves the model picker is wired to the catalogue.
# What is pinned here: both dropdowns list the whole catalogue with the
# player's current picks selected, a pick reaches the preview meshes, and the
# swatch strip an item carries shows that model's own zones.

# A synthetic kit shaped like TeamColorRegistry.get_colors' output, with every
# slot distinguishable so a zone landing on the wrong one is visible.
const _PRIMARY := Color(0.10, 0.30, 0.80)
const _SECONDARY := Color(0.90, 0.30, 0.10)
const _LIGHT := Color(0.96, 0.93, 0.84)   # cream, like Plum's
const _KIT_GLOVES := Color(0.75, 0.15, 0.15)

var _popup: GearEditorPopup = null


func before_each() -> void:
	_popup = GearEditorPopup.new()
	add_child_autofree(_popup)
	_popup.set_focus_scope(null, null)


func _skate_btn() -> OptionButton:
	return _popup.get("_skate_btn") as OptionButton


func _glove_btn() -> OptionButton:
	return _popup.get("_glove_btn") as OptionButton


func _open(skate_model: int, glove_model: int) -> void:
	_popup.open(PlayerAttributes.GEAR_BALANCED, skate_model, glove_model,
			GearStyleConfig.LACE_DEFAULT_INDEX, false, {
				"primary": _PRIMARY,
				"secondary": _SECONDARY,
				"light": _LIGHT,
				"gloves": _KIT_GLOVES,
			})


func test_dropdowns_list_the_catalogue_with_the_current_picks_selected() -> void:
	_open(GearModelRegistry.SKATE_RETRO, GearModelRegistry.GLOVE_CONTRAST)
	assert_eq(_skate_btn().item_count, GearModelRegistry.skate_count(),
			"every skate model is offered")
	assert_eq(_glove_btn().item_count, GearModelRegistry.glove_count(),
			"every glove model is offered")
	assert_eq(_skate_btn().selected, GearModelRegistry.SKATE_RETRO)
	assert_eq(_glove_btn().selected, GearModelRegistry.GLOVE_CONTRAST)


# Re-opening must re-list rather than append — the items are rebuilt per open
# because a model's TEAM zones resolve against the kit being worn.
func test_reopening_does_not_stack_items() -> void:
	_open(0, 0)
	_open(GearModelRegistry.SKATE_WHITEOUT, GearModelRegistry.GLOVE_PRO)
	assert_eq(_skate_btn().item_count, GearModelRegistry.skate_count())
	assert_eq(_skate_btn().selected, GearModelRegistry.SKATE_WHITEOUT)
	assert_eq(_glove_btn().selected, GearModelRegistry.GLOVE_PRO)


func _surface_color(node_name: String, surface: int) -> Color:
	var mi: MeshInstance3D = _popup.get(node_name) as MeshInstance3D
	return (mi.get_surface_override_material(surface) as StandardMaterial3D).albedo_color


func test_a_pick_repaints_the_turntable() -> void:
	_open(GearModelRegistry.SKATE_BLACKOUT, GearModelRegistry.GLOVE_TEAM)
	var cuff: MeshInstance3D = _popup.get("_cuff") as MeshInstance3D
	assert_eq(_surface_color("_boot", SkaterMeshBuilder.BOOT_PART_QUARTER),
			GearModelRegistry.BLACK, "the stock skate stands on the disc in black")
	assert_eq((cuff.material_override as StandardMaterial3D).albedo_color,
			_KIT_GLOVES, "the stock glove cuff wears the kit")

	# Whiteout's boot is light; Pro's cuff is light. Selecting must reach both,
	# and "light" is the TEAM's white — cream here, not a fixed one.
	_skate_btn().item_selected.emit(GearModelRegistry.SKATE_WHITEOUT)
	_glove_btn().item_selected.emit(GearModelRegistry.GLOVE_PRO)
	assert_eq(_surface_color("_boot", SkaterMeshBuilder.BOOT_PART_QUARTER),
			_LIGHT, "the picked boot repaints in the team's own white")
	assert_eq((cuff.material_override as StandardMaterial3D).albedo_color,
			_LIGHT, "the picked cuff repaints in the team's own white")


# The zones that only exist because a piece was SPLIT are the ones a wrong
# surface index would paint silently — pin that each lands on its own piece.
func test_split_pieces_paint_apart() -> void:
	# Two-Tone: light quarter, black toe cap. Pro: primary holder under a black
	# boot. Two-Tone gloves: kit back, black fingers.
	_open(GearModelRegistry.SKATE_TWO_TONE, GearModelRegistry.GLOVE_TWO_TONE)
	assert_eq(_surface_color("_boot", SkaterMeshBuilder.BOOT_PART_QUARTER),
			_LIGHT, "the quarter is the team's white")
	assert_eq(_surface_color("_boot", SkaterMeshBuilder.BOOT_PART_TOE),
			GearModelRegistry.BLACK, "the toe cap is black")
	assert_eq(_surface_color("_fist", SkaterMeshBuilder.FIST_PART_BACK),
			_KIT_GLOVES, "the back of the hand keeps the kit")
	assert_eq(_surface_color("_fist", SkaterMeshBuilder.FIST_PART_FINGERS),
			GearModelRegistry.BLACK, "the fingers are black")
	# The steel runner is never a zone, whatever the model says.
	assert_eq(_surface_color("_blade", SkaterMeshBuilder.BLADE_PART_HOLDER),
			_LIGHT, "Two-Tone's holder is the team's white")
	_skate_btn().item_selected.emit(GearModelRegistry.SKATE_PRO)
	assert_eq(_surface_color("_blade", SkaterMeshBuilder.BLADE_PART_HOLDER),
			_PRIMARY, "Pro's holder is the team primary")
	assert_eq(_surface_color("_boot", SkaterMeshBuilder.BOOT_PART_TOE),
			_LIGHT, "Pro's toe cap is the team's white")
	assert_eq(_surface_color("_blade", SkaterMeshBuilder.BLADE_PART_RUNNER),
			SkaterMeshBuilder.BLADE_STEEL_COLOR, "the runner stays steel")


func test_done_hands_back_the_picks() -> void:
	_open(0, 0)
	watch_signals(_popup)
	_skate_btn().item_selected.emit(GearModelRegistry.SKATE_PRO)
	_glove_btn().item_selected.emit(GearModelRegistry.GLOVE_VINTAGE)
	_popup.call("_done")
	assert_signal_emitted_with_parameters(_popup, "gear_edited",
			[PlayerAttributes.GEAR_BALANCED, GearModelRegistry.SKATE_PRO,
			GearModelRegistry.GLOVE_VINTAGE, GearStyleConfig.LACE_DEFAULT_INDEX])


func test_each_item_carries_its_own_zones_as_a_swatch() -> void:
	_open(0, 0)
	for model: int in GearModelRegistry.skate_count():
		var img: Image = _skate_btn().get_item_icon(model).get_image()
		# One band per zone, sampled at each band's center.
		var band: int = img.get_width() / GearModelRegistry.SKATE_ZONE_COUNT
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			var swatch: Color = img.get_pixel(
					zone * band + band / 2, img.get_height() / 2)
			var want: Color = GearModelRegistry.skate_color(model, zone,
					_PRIMARY, _SECONDARY, _LIGHT)
			# The strip is RGBA8 — allow the one-step float→byte quantisation.
			var delta: float = maxf(maxf(absf(swatch.r - want.r),
					absf(swatch.g - want.g)), absf(swatch.b - want.b))
			assert_lt(delta, 1.5 / 255.0, "skate model %d band %d" % [model, zone])
