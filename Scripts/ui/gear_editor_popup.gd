class_name GearEditorPopup
extends Control

# The gear workbench: the equipment picks that live below the stick — SKATE
# PROFILE (the blade grind, the one gameplay row), the skate and glove MODELS,
# the lace color, and the helmet FACE option — arranged as compact rows around
# a live turntable preview assembled from the skater's own shared meshes (boot
# on its holder and steel with its ankle collar, gloved fist with its cuff
# ring, helmet with the picked face piece). A model paints the WHOLE piece
# from GearModelRegistry's slots — true black plus the wearing team's own
# white, primary and secondary — so the turntable shows the design you are
# buying on the kit you are buying it for; each row's dropdown carries a
# swatch strip of the model's zones next to its name. Face options are fixed
# looks (visor smoke, cage steel, fishbowl clear), so their row is plain names
# and the preview helmet wears a neutral display shell rather than a kit
# color.
#
# Same sub-editor contract as StickEditorPopup: opened by PlayerSettingsPopup
# over its own modal, it edits pending values and hands them back through
# `gear_edited` on Done — the HOST owns snapshot/commit/revert, so Cancel here
# just discards this dialog's edits and the host's Cancel still reverts an
# applied Done. The profile row locks during online play; models and laces are
# cosmetic and never lock.

signal gear_edited(profile: int, skate_model: int, glove_model: int,
		lace_color: int, helmet_face: int)

const _PROFILE_TOOLTIP: String = "Blade grind.\nAgility = quicker first step & tighter cornering, lower top speed.\nPower = higher top speed & better glide, wider turns."
const _PROFILE_KEYS: Array[StringName] = [
	&"GEAR_PROFILE_AGILITY", &"GEAR_PROFILE_BALANCED", &"GEAR_PROFILE_POWER"]

const _TURNTABLE_RAD_PER_S: float = 0.7
# Boot frame → display (see LobbyArenaBackdrop's bench dummies): the boot mesh
# is authored with local −Y = toe and local +Z = down, so this basis lands the
# toe on −X with the sole down.
const _BOOT_ROT := Basis(Vector3(0, 0, -1), Vector3(1, 0, 0), Vector3(0, -1, 0))
# The blade runner bottoms out at the pre-lift ice contact (boot-local z
# 0.080) plus the stance lift — seat the skate this high so the steel stands
# ON the disc.
const _BLADE_ICE_M: float = 0.080 + SkaterMeshBuilder.SKATE_LIFT_M
# Display scale for the unit glove-fist mesh (the live rig scales it by the
# hand sphere radius; slightly larger here so the pair reads evenly).
const _FIST_SCALE: float = 0.085
const _CUFF_RADIUS: float = 0.065

# The model swatch strip drawn on each dropdown row: one band per paint zone,
# in GearModelRegistry's zone order (quarter → toe → collar → band → holder;
# glove body → fingers → cuff).
const _SWATCH_W: int = 36
const _SWATCH_H: int = 18

# Pending picks (working state between open() and Done).
var _profile: int = PlayerAttributes.GEAR_BALANCED
var _skate_model: int = 0
var _glove_model: int = 0
var _lace_color: int = GearStyleConfig.LACE_DEFAULT_INDEX
var _face_option: int = GearModelRegistry.FACE_NONE
var _gear_locked: bool = false
# The kit a model's TEAM / ACCENT / LIGHT zones resolve against — the pending
# team pick, so the turntable previews the sweater you are about to wear.
var _team_accent: Color = Color.WHITE
var _kit_gloves: Color = Color.BLACK
var _team_secondary: Color = Color.WHITE
var _glove_accent: Color = Color.WHITE
var _team_light: Color = Color.WHITE
# Boot-node seat on the turntable, kept so open() can re-seat the collar
# against it per build.
var _skate_at: Vector3 = Vector3.ZERO

# Controls.
var _profile_btn: OptionButton = null
var _skate_btn: OptionButton = null
var _glove_btn: OptionButton = null
var _lace_dd: SwatchDropdown = null
var _face_btn: OptionButton = null
var _lock_label: Label = null

# Preview scene.
var _viewport: SubViewport = null
var _turntable: Node3D = null
var _boot: MeshInstance3D = null
var _blade: MeshInstance3D = null
var _collar: MeshInstance3D = null
var _skate_stripe: MeshInstance3D = null
var _laces: MeshInstance3D = null
var _fist: MeshInstance3D = null
var _cuff: MeshInstance3D = null
var _helmet: MeshInstance3D = null
var _face_piece: MeshInstance3D = null

# Focus scope (see ControllerNav.open_modal).
var _focus_background: Control = null
var _focus_restore: Control = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build()
	visible = false


func _process(delta: float) -> void:
	if not visible or _turntable == null:
		return
	_turntable.rotate_y(_TURNTABLE_RAD_PER_S * delta)


# ── Construction ─────────────────────────────────────────────────────────────

func _build() -> void:
	var overlay := ColorRect.new()
	overlay.color = MenuStyle.SCRIM
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.gui_input.connect(_on_overlay_clicked)
	add_child(overlay)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", MenuStyle.panel())
	panel.set_anchors_preset(Control.PRESET_CENTER)
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 12)
	panel.add_child(vbox)

	var close_row := HBoxContainer.new()
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_row.add_child(spacer)
	var close_btn := MenuStyle.close_button()
	close_btn.pressed.connect(_cancel)
	SoundManager.wire_button(close_btn)
	close_row.add_child(close_btn)
	vbox.add_child(close_row)

	var title := Label.new()
	title.text = tr(&"GEAR_EDITOR_TITLE")
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	MenuStyle.apply_heading(title)
	vbox.add_child(title)

	_build_preview(vbox)

	_lock_label = Label.new()
	_lock_label.text = tr(&"GEAR_LOCKED_NOTE")
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.add_theme_color_override("font_color", MenuStyle.TEXT_DIM)
	_lock_label.add_theme_font_size_override("font_size", 13)
	_lock_label.visible = false
	vbox.add_child(_lock_label)

	var rows := VBoxContainer.new()
	rows.alignment = BoxContainer.ALIGNMENT_BEGIN
	rows.add_theme_constant_override("separation", 12)
	rows.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(rows)

	_profile_btn = OptionButton.new()
	_profile_btn.custom_minimum_size = Vector2(180, 36)
	_profile_btn.add_theme_font_size_override("font_size", 15)
	_profile_btn.tooltip_text = _PROFILE_TOOLTIP
	for i: int in _PROFILE_KEYS.size():
		_profile_btn.add_item(tr(_PROFILE_KEYS[i]), i)
	SoundManager.wire_button(_profile_btn)
	_profile_btn.item_selected.connect(_on_profile_selected)
	_add_row(rows, tr(&"GEAR_PROFILE_LABEL"), _profile_btn, true, _PROFILE_TOOLTIP)

	_skate_btn = _model_button(_on_skate_model_selected)
	_add_row(rows, tr(&"GEAR_SKATES_LABEL"), _skate_btn, false, "")

	_glove_btn = _model_button(_on_glove_model_selected)
	_add_row(rows, tr(&"GEAR_GLOVES_LABEL"), _glove_btn, false, "")

	_lace_dd = SwatchDropdown.new(Vector2(180, 36))
	_lace_dd.selected.connect(_on_lace_color_selected)
	_add_row(rows, tr(&"GEAR_LACES_LABEL"), _lace_dd, false, "")

	# Face options are fixed looks with no kit zones, so the items are plain
	# names filled once here rather than rebuilt per open().
	_face_btn = _model_button(_on_face_option_selected)
	for i: int in GearModelRegistry.face_count():
		_face_btn.add_item(tr(GearModelRegistry.FACE_NAME_KEYS[i]), i)
	_add_row(rows, tr(&"GEAR_FACE_LABEL"), _face_btn, false, "")

	var legend := Label.new()
	legend.text = tr(&"STICK_GAMEPLAY_LEGEND")
	legend.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	legend.add_theme_color_override("font_color", MenuStyle.GOLD)
	legend.add_theme_font_size_override("font_size", 13)
	rows.add_child(legend)

	var action_row := HBoxContainer.new()
	action_row.alignment = BoxContainer.ALIGNMENT_CENTER
	action_row.add_theme_constant_override("separation", 12)
	vbox.add_child(action_row)

	var done_btn := Button.new()
	done_btn.text = tr(&"EDITOR_DONE")
	MenuStyle.apply_primary_cta(done_btn, 18)
	done_btn.custom_minimum_size = Vector2(140, 44)
	done_btn.pressed.connect(_done)
	SoundManager.wire_button(done_btn)
	action_row.add_child(done_btn)

	var cancel_btn := Button.new()
	cancel_btn.text = tr(&"EDITOR_CANCEL")
	cancel_btn.custom_minimum_size = Vector2(140, 44)
	cancel_btn.add_theme_font_size_override("font_size", 18)
	cancel_btn.pressed.connect(_cancel)
	SoundManager.wire_button(cancel_btn)
	action_row.add_child(cancel_btn)


# One labelled row, StickEditorPopup's layout: `gameplay` rows carry the gold
# asterisk the legend explains.
func _add_row(vbox: VBoxContainer, label_text: String, control: Control,
		gameplay: bool, tooltip: String) -> void:
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_BEGIN
	row.add_theme_constant_override("separation", 12)
	vbox.add_child(row)

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(110, 0)
	label.add_theme_font_size_override("font_size", 18)
	label.add_theme_color_override("font_color", MenuStyle.TEXT_BODY)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.tooltip_text = tooltip
	row.add_child(label)

	var star := Label.new()
	star.text = "*" if gameplay else " "
	star.custom_minimum_size = Vector2(14, 0)
	star.add_theme_font_size_override("font_size", 20)
	star.add_theme_color_override("font_color", MenuStyle.GOLD)
	star.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	star.tooltip_text = tr(&"STICK_GAMEPLAY_LEGEND") if gameplay else ""
	star.mouse_filter = Control.MOUSE_FILTER_STOP if gameplay else Control.MOUSE_FILTER_IGNORE
	row.add_child(star)

	row.add_child(control)


# A model dropdown, styled like the profile row it sits under. Its items are
# filled per open() (_rebuild_model_items) because a model's TEAM zones resolve
# against the kit the player is about to wear.
func _model_button(on_selected: Callable) -> OptionButton:
	var btn := OptionButton.new()
	btn.custom_minimum_size = Vector2(180, 36)
	btn.add_theme_font_size_override("font_size", 15)
	SoundManager.wire_button(btn)
	btn.item_selected.connect(on_selected)
	return btn


# The turntable viewport in the same "display case" well as the stick
# workbench: a soft ice disc the pieces stand on, real shadows, own 3D world.
# The pieces ARE the in-game meshes — the boot on its steel with the ankle
# collar, and a gloved fist with its cuff ring standing beside it.
func _build_preview(vbox: VBoxContainer) -> void:
	var case_panel := PanelContainer.new()
	var case_style := StyleBoxFlat.new()
	case_style.bg_color = MenuStyle.SURFACE_INPUT
	case_style.set_corner_radius_all(6)
	case_style.set_border_width_all(1)
	case_style.border_color = MenuStyle.TEAL_DIM
	case_style.set_content_margin_all(4)
	case_panel.add_theme_stylebox_override("panel", case_style)
	case_panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(case_panel)

	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(420, 230)
	case_panel.add_child(container)

	_viewport = SubViewport.new()
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	container.add_child(_viewport)

	var camera := Camera3D.new()
	# Close-in framing: the tallest piece is ~0.25 m and the spin radius ~0.3 m,
	# so a short throw keeps both filling the case without clipping.
	camera.position = Vector3(0.0, 0.22, 0.95)
	camera.rotation_degrees = Vector3(-10.0, 0.0, 0.0)
	camera.fov = 45.0
	_viewport.add_child(camera)

	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-42.0, 35.0, 0.0)
	light.light_energy = 1.3
	light.shadow_enabled = true
	_viewport.add_child(light)

	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-15.0, -140.0, 0.0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	var floor_disc := MeshInstance3D.new()
	var disc := CylinderMesh.new()
	disc.top_radius = 0.45
	disc.bottom_radius = 0.45
	disc.height = 0.02
	disc.radial_segments = 48
	floor_disc.mesh = disc
	var disc_mat := StandardMaterial3D.new()
	disc_mat.albedo_color = MenuStyle.SURFACE_ELEV
	disc_mat.roughness = 0.35
	floor_disc.material_override = disc_mat
	floor_disc.position = Vector3(0.0, -0.011, 0.0)
	_viewport.add_child(floor_disc)

	_turntable = Node3D.new()
	_viewport.add_child(_turntable)

	# Skate: boot + blade share the rotated boot frame, seated so the runner
	# stands on the disc. Both are multi-surface pieces (quarter/toe,
	# holder/runner), so they are painted per SURFACE — a material_override
	# would flatten each pair into one color.
	var skate_at := Vector3(-0.16, _BLADE_ICE_M, 0.0)
	_skate_at = skate_at
	_boot = MeshInstance3D.new()
	_boot.mesh = SkaterMeshBuilder.shared_boot()
	_boot.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(_boot)

	_blade = MeshInstance3D.new()
	_blade.mesh = SkaterMeshBuilder.shared_skate_blade()
	var steel_mat := StandardMaterial3D.new()
	steel_mat.albedo_color = SkaterMeshBuilder.BLADE_STEEL_COLOR
	steel_mat.roughness = 0.25
	_blade.set_surface_override_material(SkaterMeshBuilder.BLADE_PART_RUNNER, steel_mat)
	_blade.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(_blade)

	_laces = MeshInstance3D.new()
	_laces.mesh = SkaterMeshBuilder.shared_laces()
	_laces.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(_laces)

	# Collar seat relative to the boot — the rink's own arrangement
	# (Skater.tscn, Shin-local: SkateL y −0.41 vs FootL (−0.45, −0.1) → 0.04
	# above and 0.10 heel-ward of the boot origin). Scale and the height-scaled
	# seat are applied per open() from the pending build, mirroring the
	# appearance rig, so the preview skate IS your on-ice skate.
	_collar = MeshInstance3D.new()
	_collar.mesh = SkaterMeshBuilder.shared_skate_collar()
	_collar.position = skate_at + Vector3(0.10, 0.04, 0.0)
	_turntable.add_child(_collar)

	# The accent stripe band, seated on the collar exactly as the rink's
	# creation site places it (SkaterMeshBuilder._ensure_skate_stripe).
	_skate_stripe = MeshInstance3D.new()
	_skate_stripe.mesh = SkaterMeshBuilder.shared_skate_stripe()
	_skate_stripe.position = Vector3(0.0, 0.045, 0.0)
	_skate_stripe.scale = Vector3(0.092, 1.0, 0.092)
	_collar.add_child(_skate_stripe)

	# Glove: fist standing fingers-down (station order runs wrist → fingers
	# along −Y) with the cuff ring at the wrist above it.
	_fist = MeshInstance3D.new()
	_fist.mesh = SkaterMeshBuilder.shared_glove_fist()
	_fist.transform = Transform3D(
			Basis.from_scale(Vector3.ONE * _FIST_SCALE),
			Vector3(0.16, 0.95 * _FIST_SCALE + 0.001, 0.0))
	_turntable.add_child(_fist)

	_cuff = MeshInstance3D.new()
	_cuff.mesh = SkaterMeshBuilder.shared_cuff()
	_cuff.transform = Transform3D(
			Basis.from_scale(Vector3(_CUFF_RADIUS, 1.0, _CUFF_RADIUS)),
			Vector3(0.16, 1.9 * _FIST_SCALE + SkaterMeshBuilder.CUFF_HEIGHT_M * 0.4, 0.0))
	_turntable.add_child(_cuff)

	# Helmet behind the pair, spun to face the camera at rest (the mesh's face
	# opening is −Z), seated so the nape rim just clears the disc. The head/neck
	# skin surface keeps the mesh's default skin material; the shell is painted
	# a neutral display dark in _repaint_preview (face looks are kit-free, so
	# the case doesn't pretend to know your team's helmet). The face piece
	# shares the helmet's transform, exactly as it rides the HELMET bone on the
	# rink.
	var helmet_at := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, 0.115, -0.18))
	_helmet = MeshInstance3D.new()
	_helmet.mesh = SkaterMeshBuilder.shared_helmet_assembly()
	_helmet.transform = helmet_at
	_turntable.add_child(_helmet)

	_face_piece = MeshInstance3D.new()
	_face_piece.transform = helmet_at
	_turntable.add_child(_face_piece)


# ── Host API ─────────────────────────────────────────────────────────────────

func set_focus_scope(background: Control, restore: Control) -> void:
	_focus_background = background
	_focus_restore = restore


# `profile`/models/laces are the host's PENDING picks; `gear_locked` mirrors
# the online-match attribute lock (cosmetics stay live). `team_colors` is the
# pending team's TeamColorRegistry.get_colors dict — a model's TEAM zone
# resolves against its primary (skates, laces) or its glove color (gloves),
# ACCENT against its secondary and LIGHT against its own white, so the
# swatches preview the kit the player is about to wear. `attrs` is the
# pending BODY —
# the preview collar takes the same scale the appearance rig gives SkateL
# (calf girth laterally, height vertically; the boot deliberately never
# scales), so the preview skate is the one this build wears on the ice.
func open(profile: int, skate_model: int, glove_model: int, lace_color: int,
		helmet_face: int, gear_locked: bool, team_colors: Dictionary,
		attrs: PlayerAttributes = null) -> void:
	_profile = clampi(profile, 0, _PROFILE_KEYS.size() - 1)
	_skate_model = clampi(skate_model, 0, GearModelRegistry.skate_count() - 1)
	_glove_model = clampi(glove_model, 0, GearModelRegistry.glove_count() - 1)
	_lace_color = lace_color
	_face_option = clampi(helmet_face, 0, GearModelRegistry.face_count() - 1)
	_gear_locked = gear_locked
	_team_accent = team_colors.primary
	_kit_gloves = team_colors.gloves
	_team_secondary = team_colors.secondary
	_glove_accent = team_colors.glove_accent
	_team_light = team_colors.light
	var m_height: float = attrs.height_mult() if attrs != null else 1.0
	var m_calf: float = attrs.calf_mult() if attrs != null else 1.0
	_collar.scale = Vector3(m_calf, m_height, m_calf)
	# The seat's vertical gap rides height like the shin chain does; the
	# heel-ward offset is a Shin-frame Z position the rig never scales.
	_collar.position = _skate_at + Vector3(0.10, 0.04 * m_height, 0.0)
	_refresh()
	_repaint_preview()
	visible = true
	ControllerNav.open_modal(_focus_background, self, _profile_btn)


func _done() -> void:
	gear_edited.emit(_profile, _skate_model, _glove_model, _lace_color, _face_option)
	_close()


func _cancel() -> void:
	_close()


func _close() -> void:
	visible = false
	ControllerNav.close_modal(_focus_background, _focus_restore)


func _on_overlay_clicked(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		_cancel()


func _unhandled_input(event: InputEvent) -> void:
	if visible and event.is_action_pressed(&"ui_cancel"):
		_cancel()
		get_viewport().set_input_as_handled()


# ── Interaction ──────────────────────────────────────────────────────────────

func _on_profile_selected(option: int) -> void:
	if not _gear_locked:
		_profile = option
	_refresh()


func _on_skate_model_selected(index: int) -> void:
	_skate_model = index
	_repaint_preview()


func _on_glove_model_selected(index: int) -> void:
	_glove_model = index
	_repaint_preview()


func _on_lace_color_selected(index: int) -> void:
	_lace_color = index
	_repaint_preview()


func _on_face_option_selected(index: int) -> void:
	_face_option = index
	_repaint_preview()


# ── Rendering ────────────────────────────────────────────────────────────────

func _skate_zone(zone: int) -> Color:
	return GearModelRegistry.skate_color(_skate_model, zone,
			_team_accent, _team_secondary, _team_light)


func _glove_zone(zone: int) -> Color:
	return GearModelRegistry.glove_color(_glove_model, zone,
			_kit_gloves, _glove_accent, _team_light)


func _resolved_lace() -> Color:
	return TapeColorRegistry.resolve(_lace_color, _team_accent)


func _refresh() -> void:
	_profile_btn.select(clampi(_profile, 0, _PROFILE_KEYS.size() - 1))
	_profile_btn.disabled = _gear_locked
	_lock_label.visible = _gear_locked
	_face_btn.select(_face_option)
	_rebuild_model_items()

	var lace_colors: Array[Color] = []
	var names: Array[String] = []
	var chip_labels: Array[String] = []
	for i: int in TapeColorRegistry.count():
		lace_colors.append(TapeColorRegistry.resolve(i, _team_accent))
		names.append(tr(TapeColorRegistry.NAME_KEYS[i]))
		# The TEAM chip says so — it tracks the kit rather than being one
		# more fixed color.
		chip_labels.append(tr(&"TAPE_COLOR_TEAM_SHORT")
				if i == TapeColorRegistry.TEAM_INDEX else "")
	_lace_dd.set_palette(lace_colors, names, chip_labels)
	_lace_dd.set_selected(_lace_color)


# Fills both model dropdowns with the catalogue, each item carrying a swatch
# strip of that model's zones resolved against the pending kit.
func _rebuild_model_items() -> void:
	_skate_btn.clear()
	for model: int in GearModelRegistry.skate_count():
		var zones: Array[Color] = []
		for zone: int in GearModelRegistry.SKATE_ZONE_COUNT:
			zones.append(GearModelRegistry.skate_color(model, zone,
					_team_accent, _team_secondary, _team_light))
		_skate_btn.add_icon_item(_swatch_strip(zones),
				tr(GearModelRegistry.SKATE_NAME_KEYS[model]), model)
	_skate_btn.select(_skate_model)

	_glove_btn.clear()
	for model: int in GearModelRegistry.glove_count():
		var zones: Array[Color] = []
		for zone: int in GearModelRegistry.GLOVE_ZONE_COUNT:
			zones.append(GearModelRegistry.glove_color(model, zone,
					_kit_gloves, _glove_accent, _team_light))
		_glove_btn.add_icon_item(_swatch_strip(zones),
				tr(GearModelRegistry.GLOVE_NAME_KEYS[model]), model)
	_glove_btn.select(_glove_model)


# One model's zones as a strip of equal vertical bands. The last band absorbs
# the rounding remainder so a 3-zone strip fills the same width as a 2-zone one.
func _swatch_strip(zones: Array[Color]) -> ImageTexture:
	var img := Image.create(_SWATCH_W, _SWATCH_H, false, Image.FORMAT_RGBA8)
	var band: int = _SWATCH_W / zones.size()
	for i: int in zones.size():
		var x0: int = i * band
		var w: int = _SWATCH_W - x0 if i == zones.size() - 1 else band
		img.fill_rect(Rect2i(x0, 0, w, _SWATCH_H), zones[i])
	return ImageTexture.create_from_image(img)


# Repaints the turntable pieces with the current picks — same finishes as the
# rink (skate leather 0.42, glove cloth 0.9; the steel runner stays steel). The
# models paint every zone, so what stands on the disc is the pair you are
# equipping.
func _repaint_preview() -> void:
	if _boot == null:
		return
	_paint_surface(_boot, SkaterMeshBuilder.BOOT_PART_QUARTER,
			_skate_zone(GearModelRegistry.SKATE_QUARTER), 0.42)
	_paint_surface(_boot, SkaterMeshBuilder.BOOT_PART_TOE,
			_skate_zone(GearModelRegistry.SKATE_TOE), 0.42)
	_paint_surface(_blade, SkaterMeshBuilder.BLADE_PART_HOLDER,
			_skate_zone(GearModelRegistry.SKATE_HOLDER), 0.42)
	_collar.material_override = _preview_mat(
			_skate_zone(GearModelRegistry.SKATE_COLLAR), 0.42)
	_skate_stripe.material_override = _preview_mat(
			_skate_zone(GearModelRegistry.SKATE_STRIPE), 0.42)
	_laces.material_override = _preview_mat(_resolved_lace(), 0.9)
	_paint_surface(_fist, SkaterMeshBuilder.FIST_PART_BACK,
			_glove_zone(GearModelRegistry.GLOVE_BODY), 0.9)
	_paint_surface(_fist, SkaterMeshBuilder.FIST_PART_FINGERS,
			_glove_zone(GearModelRegistry.GLOVE_FINGERS), 0.9)
	_cuff.material_override = _preview_mat(
			_glove_zone(GearModelRegistry.GLOVE_CUFF), 0.9)
	# Neutral display shell (helmet gloss); the skin surface keeps its default.
	_paint_surface(_helmet, SkaterMeshBuilder.HELMET_SURF_SHELL,
			Color(0.16, 0.16, 0.18), 0.28)
	# The face piece is the rink's own mesh and material — null mesh for bare.
	_face_piece.mesh = SkaterMeshBuilder.shared_face_gear(_face_option)
	_face_piece.material_override = \
			SkaterMeshBuilder.make_face_gear_material(_face_option)


func _paint_surface(mi: MeshInstance3D, surface: int, color: Color,
		roughness: float) -> void:
	mi.set_surface_override_material(surface, _preview_mat(color, roughness))


func _preview_mat(color: Color, roughness: float) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat
