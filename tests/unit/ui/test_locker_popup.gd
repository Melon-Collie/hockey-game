extends GutTest

# The locker builds its rows and its mannequin in code, so nothing but running
# it proves the pickers are wired to the catalogues and that a pick reaches the
# figure. What is pinned here: every dropdown lists its whole catalogue with the
# player's current picks selected, a pick repaints the piece that wears it, Done
# hands back a gear code carrying all five fields, and the camera follows the
# group a row belongs to.

# A synthetic kit shaped like TeamColorRegistry.get_colors' output, with every
# slot distinguishable so a zone landing on the wrong one is visible.
const _PRIMARY := Color(0.10, 0.30, 0.80)
const _SECONDARY := Color(0.90, 0.30, 0.10)
const _LIGHT := Color(0.96, 0.93, 0.84)   # cream, like Plum's
const _KIT_GLOVES := Color(0.75, 0.15, 0.15)
# Whichever team color the glove body is not — see TeamColorRegistry.
const _GLOVE_ACCENT := Color(0.20, 0.70, 0.35)

var _popup: LockerPopup = null


func before_each() -> void:
	_popup = LockerPopup.new()
	add_child_autofree(_popup)
	_popup.set_focus_scope(null, null)


# Shaped like TeamColorRegistry.get_colors' output, typed arrays included —
# the stripe blocks really are Array[Dictionary] there, and the texture factory
# the mannequin paints through refuses an untyped one.
func _colors() -> Dictionary:
	var stripes: Array[Dictionary] = [
		{"pos": 0.55, "width": 0.10, "color": _SECONDARY},
	]
	var bare: Array[Dictionary] = []
	return {
		"primary": _PRIMARY,
		"secondary": _SECONDARY,
		"light": _LIGHT,
		"gloves": _KIT_GLOVES,
		"glove_accent": _GLOVE_ACCENT,
		"helmet": Color(0.2, 0.2, 0.2),
		"uniform": {
			"helmet": Color(0.2, 0.2, 0.2),
			"shoulders": {"color": _PRIMARY},
			"jersey": {"base": _PRIMARY, "stripes": stripes, "yoke": _SECONDARY},
			"arms": {"upper": {"base": _PRIMARY, "stripes": bare}},
			"gloves": _KIT_GLOVES,
			"pants": {"base": _SECONDARY, "stripes": bare},
			"socks": {"base": _PRIMARY, "stripes": stripes},
		},
	}


func _open(gear: GearStyleConfig = GearStyleConfig.new(),
		tape_code: int = StickTapeConfig.DEFAULT_CODE,
		attrs: PlayerAttributes = null) -> void:
	var build: PlayerAttributes = attrs if attrs != null else PlayerAttributes.new(
			PlayerAttributes.HEIGHT_MEDIUM, int(PlayerAttributes.NEUTRAL_WEIGHT_LBS),
			PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED,
			PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED)
	_popup.open(build, tape_code, gear.to_code(), false, _colors(),
			SkinToneRegistry.DEFAULT_INDEX, false)


func _btn(name: String) -> OptionButton:
	return _popup.get(name) as OptionButton


func _mannequin() -> LockerMannequin:
	return _popup.get("_mannequin") as LockerMannequin


# One MeshInstance3D out of the mannequin's paired part arrays.
func _part(name: String, index: int = 0) -> MeshInstance3D:
	var parts: Array = _mannequin().get(name) as Array
	return parts[index] as MeshInstance3D


func _surface_color(mi: MeshInstance3D, surface: int) -> Color:
	return (mi.get_surface_override_material(surface) as StandardMaterial3D).albedo_color


func test_every_dropdown_lists_its_catalogue_with_the_current_picks_selected() -> void:
	_open(GearStyleConfig.new(GearModelRegistry.SKATE_RETRO,
			GearModelRegistry.GLOVE_CONTRAST, GearStyleConfig.LACE_DEFAULT_INDEX,
			StickModelRegistry.count() - 1, GearModelRegistry.FACE_VISOR))
	assert_eq(_btn("_skate_btn").item_count, GearModelRegistry.skate_count(),
			"every skate model is offered")
	assert_eq(_btn("_glove_btn").item_count, GearModelRegistry.glove_count(),
			"every glove model is offered")
	assert_eq(_btn("_stick_model_btn").item_count, StickModelRegistry.count(),
			"every stick colorway is offered")
	assert_eq(_btn("_face_btn").item_count, GearModelRegistry.face_count(),
			"every face option is offered")
	assert_eq(_btn("_skate_btn").selected, GearModelRegistry.SKATE_RETRO)
	assert_eq(_btn("_glove_btn").selected, GearModelRegistry.GLOVE_CONTRAST)
	assert_eq(_btn("_stick_model_btn").selected, StickModelRegistry.count() - 1)
	assert_eq(_btn("_face_btn").selected, GearModelRegistry.FACE_VISOR)


# Re-opening must re-list rather than append — the gear items are rebuilt per
# open because a model's TEAM zones resolve against the kit being worn.
func test_reopening_does_not_stack_items() -> void:
	_open()
	_open(GearStyleConfig.new(GearModelRegistry.SKATE_WHITEOUT,
			GearModelRegistry.GLOVE_PRO))
	assert_eq(_btn("_skate_btn").item_count, GearModelRegistry.skate_count())
	assert_eq(_btn("_skate_btn").selected, GearModelRegistry.SKATE_WHITEOUT)
	assert_eq(_btn("_glove_btn").selected, GearModelRegistry.GLOVE_PRO)


func test_a_pick_repaints_the_mannequin() -> void:
	_open(GearStyleConfig.new(GearModelRegistry.SKATE_BLACKOUT,
			GearModelRegistry.GLOVE_TEAM))
	assert_eq(_surface_color(_part("_boots"), SkaterMeshBuilder.BOOT_SURF_SHELL),
			GearModelRegistry.BLACK, "the stock skate is on the feet in black")
	assert_eq(_surface_color(_part("_cuffs"), 0), _KIT_GLOVES,
			"the stock glove cuff wears the kit")

	# Whiteout's boot is light; Pro's cuff is light. Selecting must reach both,
	# and "light" is the TEAM's white — cream here, not a fixed one.
	_btn("_skate_btn").item_selected.emit(GearModelRegistry.SKATE_WHITEOUT)
	_btn("_glove_btn").item_selected.emit(GearModelRegistry.GLOVE_PRO)
	assert_eq(_surface_color(_part("_boots"), SkaterMeshBuilder.BOOT_SURF_SHELL),
			_LIGHT, "the picked boot repaints in the team's own white")
	assert_eq(_surface_color(_part("_cuffs"), 0), _LIGHT,
			"the picked cuff repaints in the team's own white")


# Both feet and both hands wear the pick — a loop that painted only index 0
# would leave the figure in mismatched gear and nothing else would catch it.
func test_a_pick_reaches_both_sides() -> void:
	_open()
	_btn("_skate_btn").item_selected.emit(GearModelRegistry.SKATE_WHITEOUT)
	_btn("_glove_btn").item_selected.emit(GearModelRegistry.GLOVE_PRO)
	for i: int in 2:
		assert_eq(_surface_color(_part("_boots", i), SkaterMeshBuilder.BOOT_SURF_SHELL),
				_LIGHT, "boot %d" % i)
		assert_eq(_surface_color(_part("_cuffs", i), 0), _LIGHT, "cuff %d" % i)


# The zones that only exist because a piece was SPLIT are the ones a wrong
# surface index would paint silently — pin that each lands on its own piece.
func test_split_pieces_paint_apart() -> void:
	# Two-Tone: light quarter, black toe cap. Pro: light toe cap under a black
	# quarter. Two-Tone gloves: the kit pairing flipped — the team's other
	# color on the back, the kit's own on the fingers.
	_open(GearStyleConfig.new(GearModelRegistry.SKATE_TWO_TONE,
			GearModelRegistry.GLOVE_TWO_TONE))
	var boot: MeshInstance3D = _part("_boots")
	assert_eq(_surface_color(_part("_hands"), SkaterMeshBuilder.FIST_PART_BACK),
			_GLOVE_ACCENT, "Two-Tone's back takes the team's other color")
	assert_eq(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_SHELL),
			_LIGHT, "the quarter is the team's white")
	assert_eq(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_TOE),
			GearModelRegistry.BLACK, "the toe cap is black")
	assert_eq(_surface_color(_part("_hands"), SkaterMeshBuilder.FIST_PART_FINGERS),
			_KIT_GLOVES, "Two-Tone's fingers keep the kit")
	assert_eq(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_HOLDER),
			_LIGHT, "the holder is the team's white")
	_btn("_skate_btn").item_selected.emit(GearModelRegistry.SKATE_PRO)
	assert_eq(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_TOE),
			_LIGHT, "Pro's toe cap is the team's white")
	# The steel runner is never a zone, whatever the model says — and it must
	# stay distinct from the white holder now sitting directly above it.
	assert_ne(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_RUNNER),
			_LIGHT, "the runner does not vanish into the holder")
	assert_eq(_surface_color(boot, SkaterMeshBuilder.BOOT_SURF_RUNNER),
			SkaterMeshBuilder.BLADE_STEEL_COLOR, "the runner stays steel")


func test_face_gear_dresses_the_helmet() -> void:
	_open(GearStyleConfig.new(0, 0, GearStyleConfig.LACE_DEFAULT_INDEX, 0,
			GearModelRegistry.FACE_VISOR))
	var piece: MeshInstance3D = _mannequin().get("_face") as MeshInstance3D
	assert_not_null(piece.mesh, "the picked visor is in the helmet")
	var mat: StandardMaterial3D = piece.material_override as StandardMaterial3D
	assert_lt(mat.albedo_color.a, 1.0, "the visor preview is translucent")
	_btn("_face_btn").item_selected.emit(GearModelRegistry.FACE_CAGE)
	assert_eq(piece.mesh, SkaterMeshBuilder.shared_face_gear(GearModelRegistry.FACE_CAGE))
	_btn("_face_btn").item_selected.emit(GearModelRegistry.FACE_NONE)
	assert_null(piece.mesh, "bare leaves the helmet open")


# The stick is the piece the old gear workbench never showed. Pin that a curve
# pick rebuilds the blade and a length pick moves the butt — the two stick gear
# rows with geometry behind them.
func test_stick_gear_reaches_the_blade_and_the_shaft() -> void:
	_open()
	var blade: MeshInstance3D = _mannequin().get("_blade") as MeshInstance3D
	var shaft: MeshInstance3D = _mannequin().get("_shaft") as MeshInstance3D
	var flat_mesh: Mesh = blade.mesh
	_btn("_curve_btn").item_selected.emit(2)   # M28 toe hook
	assert_ne(blade.mesh, flat_mesh, "a curve pick rebuilds the blade")

	var standard_len: float = shaft.transform.basis.get_scale().z
	_btn("_length_btn").item_selected.emit(0)  # Short
	var short_len: float = shaft.transform.basis.get_scale().z
	_btn("_length_btn").item_selected.emit(2)  # Long
	assert_lt(short_len, standard_len, "a short cut shortens the shaft")
	assert_lt(standard_len, shaft.transform.basis.get_scale().z,
			"a long cut outreaches standard")


# Both fists are pinned to the shaft, so a length change has to carry them —
# hands left behind at the old grip is exactly the failure the mannequin
# replaced the free-floating turntable to avoid.
func test_the_hands_stay_on_the_shaft_when_the_stick_is_recut() -> void:
	_open()
	var top: MeshInstance3D = _part("_hands", 0)
	var short_grip: Vector3 = Vector3.ZERO
	_btn("_length_btn").item_selected.emit(0)
	short_grip = top.position
	_btn("_length_btn").item_selected.emit(2)
	assert_lt(short_grip.y, top.position.y,
			"a longer stick raises the top hand's grip")


# The mannequin stands ON the case floor at every build: the boot is the one
# part the appearance rig never scales, so the seat has to be derived rather
# than assumed.
func test_every_build_stands_on_the_ice() -> void:
	for height: int in [PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MEDIUM,
			PlayerAttributes.HEIGHT_MAX]:
		var weight: int = PlayerAttributes.coerce_weight(height,
				int(PlayerAttributes.NEUTRAL_WEIGHT_LBS))
		_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
				PlayerAttributes.new(height, weight, PlayerAttributes.GEAR_BALANCED,
					PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED,
					PlayerAttributes.GEAR_BALANCED))
		var boot: MeshInstance3D = _part("_boots")
		var rig: Node3D = _mannequin().get("_rig") as Node3D
		# The runner bottoms out 0.12 m below the boot origin (pre-lift contact
		# plus the stance lift), and the mannequin's own origin is the ice.
		var contact: float = rig.position.y + boot.position.y - 0.12
		assert_almost_eq(contact, 0.0, 0.001, "height %d stands on the disc" % height)


# A taller build is visibly taller — the height dial has to reach the figure,
# not just the numbers in the player screen.
func test_height_reaches_the_figure() -> void:
	_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
			PlayerAttributes.new(PlayerAttributes.HEIGHT_MIN, 150,
				PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED,
				PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED))
	var short_head: float = (_mannequin().get("_helmet") as MeshInstance3D).position.y
	_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
			PlayerAttributes.new(PlayerAttributes.HEIGHT_MAX, 220,
				PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED,
				PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED))
	assert_lt(short_head, (_mannequin().get("_helmet") as MeshInstance3D).position.y,
			"a tall build carries its head higher")


# Landing on a row aims the case at the group that row dresses. Without this
# the locker is just a taller workbench.
func test_a_row_aims_the_case_at_its_own_group() -> void:
	_open()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.FULL,
			"it opens on the wide shot")
	_btn("_skate_btn").focus_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.SKATES)
	_btn("_glove_btn").focus_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.GLOVES)
	_btn("_face_btn").focus_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.HELMET)
	_btn("_curve_btn").focus_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.STICK)


# Each framing has to be its own shot — a piece anchor that never moved off the
# wide one would dolly nowhere.
func test_each_framing_looks_somewhere_different() -> void:
	_open()
	var seen: Array[Vector3] = []
	for focus: int in [LockerMannequin.Focus.FULL, LockerMannequin.Focus.STICK,
			LockerMannequin.Focus.SKATES, LockerMannequin.Focus.GLOVES,
			LockerMannequin.Focus.HELMET]:
		var anchor: Vector3 = _mannequin().focus_anchor(focus)
		for other: Vector3 in seen:
			assert_gt(anchor.distance_to(other), 0.05,
					"framing %d has its own anchor" % focus)
		seen.append(anchor)


func test_done_hands_back_every_pick() -> void:
	_open()
	_btn("_skate_btn").item_selected.emit(GearModelRegistry.SKATE_PRO)
	_btn("_glove_btn").item_selected.emit(GearModelRegistry.GLOVE_VINTAGE)
	_btn("_face_btn").item_selected.emit(GearModelRegistry.FACE_CAGE)
	_btn("_stick_model_btn").item_selected.emit(StickModelRegistry.count() - 1)
	_btn("_curve_btn").item_selected.emit(2)
	_btn("_profile_btn").item_selected.emit(2)   # Power grind
	watch_signals(_popup)
	_popup.call("_done")
	assert_signal_emitted(_popup, "locker_edited")
	var params: Array = get_signal_parameters(_popup, "locker_edited")
	assert_eq(params[0], 2, "profile")
	assert_eq(params[1], 2, "curve")
	var gear := GearStyleConfig.from_code(params[5])
	assert_eq(gear.skate_model, GearModelRegistry.SKATE_PRO)
	assert_eq(gear.glove_model, GearModelRegistry.GLOVE_VINTAGE)
	assert_eq(gear.helmet_face, GearModelRegistry.FACE_CAGE)
	assert_eq(gear.stick_model, StickModelRegistry.count() - 1)


# The lock is the online-match attribute freeze: gameplay rows go dead, every
# cosmetic row stays live.
func test_the_lock_freezes_gameplay_rows_only() -> void:
	_popup.open(PlayerAttributes.new(PlayerAttributes.HEIGHT_MEDIUM,
			int(PlayerAttributes.NEUTRAL_WEIGHT_LBS), PlayerAttributes.GEAR_BALANCED,
			PlayerAttributes.GEAR_BALANCED, PlayerAttributes.GEAR_BALANCED,
			PlayerAttributes.GEAR_BALANCED), StickTapeConfig.DEFAULT_CODE,
			GearStyleConfig.new().to_code(), true, _colors(),
			SkinToneRegistry.DEFAULT_INDEX, false)
	for name: String in ["_length_btn", "_curve_btn", "_flex_btn", "_profile_btn"]:
		assert_true(_btn(name).disabled, "%s locks" % name)
	for name: String in ["_skate_btn", "_glove_btn", "_face_btn", "_stick_model_btn",
			"_span_btn", "_style_btn"]:
		assert_false(_btn(name).disabled, "%s stays live" % name)
	# A locked row that still moved its pick would commit a frozen attribute.
	_btn("_curve_btn").item_selected.emit(2)
	assert_eq(_popup.get("_curve"), PlayerAttributes.GEAR_BALANCED,
			"a locked pick is refused")


# Each item's swatch strip shows that model's own zones against the pending kit.
func test_each_model_item_carries_its_own_zones_as_a_swatch() -> void:
	_open()
	for model: int in GearModelRegistry.skate_count():
		var img: Image = _btn("_skate_btn").get_item_icon(model).get_image()
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
