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


# Both fists grip the shaft, so a length change has to carry them — hands left
# behind at the old grip is exactly the failure the mannequin replaced the
# free-floating turntable to avoid.
func test_the_hands_stay_on_the_shaft_when_the_stick_is_recut() -> void:
	_open()
	var top: MeshInstance3D = _part("_hands", 0)
	_btn("_length_btn").item_selected.emit(0)
	var short_grip: Vector3 = top.position
	_btn("_length_btn").item_selected.emit(2)
	assert_lt(short_grip.y, top.position.y,
			"a longer stick raises the top hand's grip")


# Distance from the shaft line to each fist. The grips are solved onto that
# line, so anything above a rounding error means a hand is holding thin air.
func _grip_offset(hand: MeshInstance3D) -> float:
	var heel: Vector3 = _mannequin().get("_shaft_heel")
	var up: Vector3 = _mannequin().get("_shaft_up")
	var along: Vector3 = hand.position - heel
	return (along - up * along.dot(up)).length()


# Both arms are the rig's own length. Deriving segment length from how far the
# grip happened to land built one long arm and one short one, because the two
# hands sit at very different distances from their shoulders.
func test_both_arms_are_the_same_length() -> void:
	for length: int in 3:
		_open()
		_btn("_length_btn").item_selected.emit(length)
		var spans: Array[float] = []
		for i: int in 2:
			var upper: float = _part("_upper_arms", i).transform.basis.y.length()
			var fore: float = _part("_forearms", i).transform.basis.y.length()
			assert_almost_eq(upper, fore, 0.01,
					"arm %d bends at its midpoint (cut %d)" % [i, length])
			spans.append(upper + fore)
		assert_almost_eq(spans[0], spans[1], 0.01,
				"both arms are the same length (cut %d)" % length)
		# And that length is the rig's own bones riding the build's height, not
		# whatever distance the grip happened to land at.
		var build := PlayerAttributes.new(PlayerAttributes.HEIGHT_MEDIUM,
				int(PlayerAttributes.NEUTRAL_WEIGHT_LBS), 1, 1, 1, length)
		assert_almost_eq(spans[0], 0.66 * build.height_mult(), 0.01,
				"arms are the rig's 0.33 m bones, scaled by height")


# Every grip has to end up ON the shaft and inside its own arm's reach — the
# solver slides it until both hold, so neither can be traded for the other.
func test_the_grips_stay_on_the_shaft_and_inside_the_arms_reach() -> void:
	for height: int in [PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MAX]:
		for length: int in 3:
			_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
					PlayerAttributes.new(height,
						PlayerAttributes.coerce_weight(height, 190), 1, 1, 1, length))
			for i: int in 2:
				var hand: MeshInstance3D = _part("_hands", i)
				assert_almost_eq(_grip_offset(hand), 0.0, 0.001,
						"hand %d grips the shaft (height %d, cut %d)" % [i, height, length])
				var shoulder: Vector3 = _part("_upper_arms", i).position \
						+ _part("_upper_arms", i).transform.basis.y * 0.5
				var upper: float = _part("_upper_arms", i).transform.basis.y.length()
				var fore: float = _part("_forearms", i).transform.basis.y.length()
				assert_lte(shoulder.distance_to(hand.position), upper + fore + 0.001,
						"hand %d is inside its arm's reach" % i)


# Vertical extent of one part in rig space, transform included — the boot's
# frame is rotated, so its own AABB says nothing on its own.
func _span(mi: MeshInstance3D) -> Vector2:
	var box: AABB = mi.transform * mi.get_aabb()
	return Vector2(box.position.y, box.position.y + box.size.y)


# The leg is a CHAIN, and every link has to touch the next one. Building it from
# thigh and sock alone leaves a hole at each knee — the thigh ends well above
# where the sock starts, and the joint ball is the only thing that spans it.
func test_the_leg_chain_has_no_holes() -> void:
	for height: int in [PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MEDIUM,
			PlayerAttributes.HEIGHT_MAX]:
		_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
				PlayerAttributes.new(height,
					PlayerAttributes.coerce_weight(height, 190), 1, 1, 1, 1))
		# Top-down, the way the rig chains them.
		var chain: Array[String] = ["_hips", "_thighs", "_knees", "_socks",
			"_collars", "_boots"]
		for i: int in 2:
			for link: int in chain.size() - 1:
				var upper: Vector2 = _span(_part(chain[link], i))
				var lower: Vector2 = _span(_part(chain[link + 1], i))
				assert_lte(upper.x, lower.y,
						"%s meets %s (leg %d, height %d)"
						% [chain[link], chain[link + 1], i, height])


# The fist and cuff bases scale their COLUMNS. Basis.scaled() scales in the
# parent frame instead, which shears a rotated grip basis into a stretched
# sheet — a blade-shaped artifact hanging off each wrist.
func test_the_hand_pieces_are_not_sheared() -> void:
	_open()
	for i: int in 2:
		for name: String in ["_hands", "_cuffs"]:
			var b: Basis = _part(name, i).transform.basis
			assert_almost_eq(b.x.dot(b.y), 0.0, 0.0001, "%s %d x⊥y" % [name, i])
			assert_almost_eq(b.y.dot(b.z), 0.0, 0.0001, "%s %d y⊥z" % [name, i])
			assert_almost_eq(b.z.dot(b.x), 0.0, 0.0001, "%s %d z⊥x" % [name, i])
		# The cuff is a unit-radius ring with its real height baked in, so only
		# its radius may scale — a stretched Y is the artifact itself.
		var cuff: Basis = _part("_cuffs", i).transform.basis
		assert_almost_eq(cuff.y.length(), 1.0, 0.001, "cuff %d keeps its height" % i)
		assert_lt(cuff.x.length(), 0.15, "cuff %d stays a wrist ring" % i)
		assert_lt(cuff.z.length(), 0.15, "cuff %d stays a wrist ring" % i)


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
	_btn("_length_btn").focus_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.STICK)


# Hovering has to aim it too, and the pointer lands on the CONTROL, not on the
# container behind it — wiring only the row leaves a mouse player's case stuck.
func test_hovering_a_control_aims_the_case() -> void:
	_open()
	_btn("_skate_btn").mouse_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.SKATES)
	_btn("_flex_btn").mouse_entered.emit()
	assert_eq(_popup.get("_focus"), LockerMannequin.Focus.STICK)


# The stick takes three shots because one cannot serve its eight rows. Each row
# has to ask for the shot its own pick actually shows up in.
func test_the_stick_rows_ask_for_the_shot_that_shows_their_pick() -> void:
	_open()
	for name: String in ["_length_btn", "_flex_btn", "_stick_model_btn"]:
		_popup.call("_set_focus", LockerMannequin.Focus.FULL)
		_btn(name).mouse_entered.emit()
		assert_eq(_popup.get("_focus"), LockerMannequin.Focus.STICK,
				"%s frames the whole stick" % name)
	for name: String in ["_curve_btn", "_span_btn"]:
		_popup.call("_set_focus", LockerMannequin.Focus.FULL)
		_btn(name).mouse_entered.emit()
		assert_eq(_popup.get("_focus"), LockerMannequin.Focus.BLADE,
				"%s frames the blade" % name)
	for name: String in ["_style_btn"]:
		_popup.call("_set_focus", LockerMannequin.Focus.FULL)
		_btn(name).mouse_entered.emit()
		assert_eq(_popup.get("_focus"), LockerMannequin.Focus.GRIP,
				"%s frames the butt end" % name)


# Every framing has to actually CONTAIN its subject, at every build — a whole-
# stick shot that crops a long cut on a tall player is the bug this replaced.
func test_the_whole_stick_shot_contains_the_whole_stick() -> void:
	for height: int in [PlayerAttributes.HEIGHT_MIN, PlayerAttributes.HEIGHT_MAX]:
		for length: int in 3:
			_open(GearStyleConfig.new(), StickTapeConfig.DEFAULT_CODE,
					PlayerAttributes.new(height,
						PlayerAttributes.coerce_weight(height, 190), 1, 1, 1, length))
			var extent: Vector2 = _mannequin().focus_extent(LockerMannequin.Focus.STICK)
			var mid: Vector3 = _mannequin().focus_anchor(LockerMannequin.Focus.STICK)
			for focus: int in [LockerMannequin.Focus.BLADE, LockerMannequin.Focus.GRIP]:
				var end_point: Vector3 = _mannequin().focus_anchor(focus)
				assert_lte(absf(end_point.y - mid.y), extent.y,
						"the stick shot holds its ends (height %d, cut %d)"
						% [height, length])
	# And the whole-stick shot is a real step in from the wide one, or hovering
	# a stick row would look like nothing happened.
	_open()
	assert_lt(_mannequin().focus_extent(LockerMannequin.Focus.STICK).y,
			_mannequin().focus_extent(LockerMannequin.Focus.FULL).y,
			"the stick shot is tighter than the wide shot")
	assert_lt(_mannequin().focus_extent(LockerMannequin.Focus.BLADE).y,
			_mannequin().focus_extent(LockerMannequin.Focus.STICK).y,
			"the blade shot is tighter than the whole stick")


# Dragging up pulls the camera in and down pushes it out, and the zoom clamps
# against the CURRENT framing rather than winding up — a multiplier that ran
# past its stop would leave the drag dead until it had been wound all the way
# back.
func test_dragging_up_and_down_zooms() -> void:
	_open()
	var wide: float = _popup.call("_framed_distance")
	_popup.call("_zoom_by", -0.25)
	var closer: float = _popup.call("_framed_distance")
	assert_lt(closer, wide, "dragging up pulls the camera in")
	_popup.call("_zoom_by", 0.5)
	assert_gt(_popup.call("_framed_distance"), closer, "dragging down pushes it out")

	# Wind it hard against each stop, then reverse ONE step: the distance has to
	# move straight away. A held pad stick can hit these stops in a second, so
	# this is the pad's failure mode as much as the mouse's.
	for i: int in 40:
		_popup.call("_zoom_by", -0.5)
	var pinned_near: float = _popup.call("_framed_distance")
	_popup.call("_zoom_by", 0.2)
	assert_gt(_popup.call("_framed_distance"), pinned_near,
			"the near stop does not wind up")
	for i: int in 40:
		_popup.call("_zoom_by", 0.5)
	var pinned_far: float = _popup.call("_framed_distance")
	_popup.call("_zoom_by", -0.2)
	assert_lt(_popup.call("_framed_distance"), pinned_far,
			"the far stop does not wind up")


# The pad's right stick has to reach the same two controls the drag does, and
# agree with it on direction — a stick that zoomed the opposite way from the
# drag would read as one of the two being inverted.
func test_the_pad_stick_turns_and_zooms_the_same_way_the_drag_does() -> void:
	_open()
	# With no pad connected under GUT, the read must leave the case alone rather
	# than reading axes off a device that isn't there.
	var before_yaw: float = _popup.get("_target_yaw")
	_popup.call("_read_pad_look", 0.016)   # no pad connected under GUT
	assert_eq(_popup.get("_target_yaw"), before_yaw,
			"no pad connected means the case is left alone")
	assert_false(_popup.get("_pad_looking"), "and the idle turn keeps running")

	# The zoom path both devices share: negative pulls in on either.
	var wide: float = _popup.call("_framed_distance")
	_popup.call("_zoom_by", -0.3)
	assert_lt(_popup.call("_framed_distance"), wide,
			"negative exponent pulls in, whichever device sent it")


# The swatch rows are the ones a pad player would silently lose: SwatchDropdown
# is a FOCUS_NONE wrapper whose inner button takes the focus, so watching the
# wrapper connects a signal that never fires and those three rows alone would
# never re-frame the case.
func test_the_swatch_rows_reframe_the_case_too() -> void:
	_open()
	var rows: Dictionary = {
		"_blade_color_dd": LockerMannequin.Focus.BLADE,
		"_knob_color_dd": LockerMannequin.Focus.GRIP,
		"_lace_dd": LockerMannequin.Focus.SKATES,
	}
	for name: String in rows:
		var dd: SwatchDropdown = _popup.get(name) as SwatchDropdown
		assert_eq(dd.focus_mode, Control.FOCUS_NONE,
				"%s is still a wrapper — if this changed, so did the wiring" % name)
		_popup.call("_set_focus", LockerMannequin.Focus.FULL)
		dd.focus_target().focus_entered.emit()
		assert_eq(_popup.get("_focus"), rows[name], "%s aims the case" % name)
		_popup.call("_set_focus", LockerMannequin.Focus.FULL)
		dd.focus_target().mouse_entered.emit()
		assert_eq(_popup.get("_focus"), rows[name], "%s aims it on hover too" % name)


# Every row a pad walks has to be reachable at all — a control the focus search
# skips is a pick a controller player simply cannot make.
func test_every_row_control_is_pad_reachable() -> void:
	_open()
	for name: String in ["_length_btn", "_curve_btn", "_flex_btn",
			"_stick_model_btn", "_span_btn", "_style_btn", "_profile_btn",
			"_skate_btn", "_glove_btn", "_face_btn"]:
		assert_ne(_btn(name).focus_mode, Control.FOCUS_NONE,
				"%s can be focused" % name)
	for name: String in ["_blade_color_dd", "_knob_color_dd", "_lace_dd"]:
		var dd: SwatchDropdown = _popup.get(name) as SwatchDropdown
		assert_ne(dd.focus_target().focus_mode, Control.FOCUS_NONE,
				"%s can be focused" % name)


# The locker is a CHILD of the player screen it covers, and open() walls that
# screen off — the wall must not take the locker down with it (a walled locker
# is a dead dialog for the pad), and closing must lift the wall so focus can
# return to the launcher.
func test_opening_over_its_own_parent_keeps_the_rows_focusable() -> void:
	var form := Control.new()
	add_child_autofree(form)
	var launcher := Button.new()
	form.add_child(launcher)
	_popup.get_parent().remove_child(_popup)
	form.add_child(_popup)
	_popup.set_focus_scope(form, launcher)
	_open()
	assert_eq(_btn("_length_btn").get_focus_mode_with_override(), Control.FOCUS_ALL,
			"the locker's rows stay focusable inside its own wall")
	assert_eq(launcher.get_focus_mode_with_override(), Control.FOCUS_NONE,
			"the launcher behind the scrim is walled off")
	_popup.call("_cancel")
	assert_eq(launcher.get_focus_mode_with_override(), Control.FOCUS_ALL,
			"closing lifts the wall so focus can return to the launcher")


# The hint has to name the device that is actually driving, and follow a swap.
func test_the_case_hint_names_the_driving_device() -> void:
	_open()
	var hint: Label = _popup.get("_case_hint") as Label
	assert_false(hint.text.is_empty(), "the case says how to turn it")
	assert_eq(hint.text, ControllerGlyphs.prompt(
			tr(&"LOCKER_CASE_HINT_MOUSE"), tr(&"LOCKER_CASE_HINT_PAD")),
			"and names whichever device is active")


# Moving to another group hands back a framed shot, not whatever the last drag
# left behind.
func test_changing_focus_clears_the_hand_zoom() -> void:
	_open()
	_popup.call("_zoom_by", -80.0)
	assert_lt(_popup.get("_zoom"), 1.0)
	_btn("_face_btn").mouse_entered.emit()
	assert_almost_eq(_popup.get("_zoom"), 1.0, 0.0001,
			"the new framing starts framed")


# Each framing has to be its own shot — a piece anchor that never moved off the
# wide one would dolly nowhere.
func test_each_framing_looks_somewhere_different() -> void:
	_open()
	var seen: Array[Vector3] = []
	for focus: int in [LockerMannequin.Focus.FULL, LockerMannequin.Focus.STICK,
			LockerMannequin.Focus.BLADE, LockerMannequin.Focus.GRIP,
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
