class_name GearEditorPopup
extends Control

# The gear workbench: the equipment picks that live below the stick — SKATE
# PROFILE (the blade grind, the one gameplay row) and the skate / glove
# accent colors — arranged as compact rows around a live turntable preview
# assembled from the skater's own shared meshes (boot on steel with its ankle
# collar, gloved fist with its cuff ring). The color picks paint ACCENT
# STRIPES, not the whole piece: the skate pick colors the band ringing the
# collar (boot stays dark), the glove pick colors the wrist cuff (the hand
# stays kit-colored) — exactly what the rink renders.
#
# Same sub-editor contract as StickEditorPopup: opened by PlayerSettingsPopup
# over its own modal, it edits pending values and hands them back through
# `gear_edited` on Done — the HOST owns snapshot/commit/revert, so Cancel here
# just discards this dialog's edits and the host's Cancel still reverts an
# applied Done. The profile row locks during online play; colors are cosmetic
# and never lock.

signal gear_edited(profile: int, skate_color: int, glove_color: int, lace_color: int)

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

# Pending picks (working state between open() and Done).
var _profile: int = PlayerAttributes.GEAR_BALANCED
var _skate_color: int = GearStyleConfig.SKATE_DEFAULT_INDEX
var _glove_color: int = TapeColorRegistry.TEAM_INDEX
var _lace_color: int = GearStyleConfig.LACE_DEFAULT_INDEX
var _gear_locked: bool = false
var _team_accent: Color = Color.WHITE
var _kit_gloves: Color = Color.BLACK

# Controls.
var _profile_btn: OptionButton = null
var _skate_dd: SwatchDropdown = null
var _glove_dd: SwatchDropdown = null
var _lace_dd: SwatchDropdown = null
var _lock_label: Label = null

# Preview scene.
var _viewport: SubViewport = null
var _turntable: Node3D = null
var _boot: MeshInstance3D = null
var _collar: MeshInstance3D = null
var _skate_stripe: MeshInstance3D = null
var _laces: MeshInstance3D = null
var _fist: MeshInstance3D = null
var _cuff: MeshInstance3D = null

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

	_skate_dd = SwatchDropdown.new(Vector2(180, 36))
	_skate_dd.selected.connect(_on_skate_color_selected)
	_add_row(rows, tr(&"GEAR_SKATES_LABEL"), _skate_dd, false, "")

	_glove_dd = SwatchDropdown.new(Vector2(180, 36))
	_glove_dd.selected.connect(_on_glove_color_selected)
	_add_row(rows, tr(&"GEAR_GLOVES_LABEL"), _glove_dd, false, "")

	_lace_dd = SwatchDropdown.new(Vector2(180, 36))
	_lace_dd.selected.connect(_on_lace_color_selected)
	_add_row(rows, tr(&"GEAR_LACES_LABEL"), _lace_dd, false, "")

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

	# Skate: boot + steel share the rotated boot frame, seated so the runner
	# stands on the disc; the ankle collar rises off the heel with a slight
	# backward lean, like the real boot line.
	var skate_at := Vector3(-0.16, _BLADE_ICE_M, 0.0)
	_boot = MeshInstance3D.new()
	_boot.mesh = SkaterMeshBuilder.shared_boot()
	_boot.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(_boot)

	var steel := MeshInstance3D.new()
	steel.mesh = SkaterMeshBuilder.shared_skate_blade()
	var steel_mat := StandardMaterial3D.new()
	steel_mat.albedo_color = Color(0.82, 0.85, 0.88)
	steel_mat.roughness = 0.25
	steel.material_override = steel_mat
	steel.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(steel)

	_laces = MeshInstance3D.new()
	_laces.mesh = SkaterMeshBuilder.shared_laces()
	_laces.transform = Transform3D(_BOOT_ROT, skate_at)
	_turntable.add_child(_laces)

	_collar = MeshInstance3D.new()
	_collar.mesh = SkaterMeshBuilder.shared_skate_collar()
	_collar.transform = Transform3D(
			Basis(Vector3(0, 0, 1), deg_to_rad(-10.0)),
			skate_at + Vector3(0.075, 0.10, 0.0))
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


# ── Host API ─────────────────────────────────────────────────────────────────

func set_focus_scope(background: Control, restore: Control) -> void:
	_focus_background = background
	_focus_restore = restore


# `profile`/colors are the host's PENDING picks; `gear_locked` mirrors the
# online-match attribute lock (colors stay live). TEAM color chips resolve
# against `team_accent` (skates) and `kit_gloves` (gloves) so the swatches
# preview the kit the player is about to wear.
func open(profile: int, skate_color: int, glove_color: int, lace_color: int,
		gear_locked: bool, team_accent: Color, kit_gloves: Color) -> void:
	_profile = clampi(profile, 0, _PROFILE_KEYS.size() - 1)
	_skate_color = skate_color
	_glove_color = glove_color
	_lace_color = lace_color
	_gear_locked = gear_locked
	_team_accent = team_accent
	_kit_gloves = kit_gloves
	_refresh()
	_repaint_preview()
	visible = true
	ControllerNav.open_modal(_focus_background, self, _profile_btn)


func _done() -> void:
	gear_edited.emit(_profile, _skate_color, _glove_color, _lace_color)
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


func _on_skate_color_selected(index: int) -> void:
	_skate_color = index
	_repaint_preview()


func _on_glove_color_selected(index: int) -> void:
	_glove_color = index
	_repaint_preview()


func _on_lace_color_selected(index: int) -> void:
	_lace_color = index
	_repaint_preview()


# ── Rendering ────────────────────────────────────────────────────────────────

func _resolved_skate() -> Color:
	return TapeColorRegistry.resolve(_skate_color, _team_accent)


func _resolved_glove() -> Color:
	if _glove_color == TapeColorRegistry.TEAM_INDEX:
		return _kit_gloves
	return TapeColorRegistry.resolve(_glove_color, _kit_gloves)


func _resolved_lace() -> Color:
	return TapeColorRegistry.resolve(_lace_color, _team_accent)


func _refresh() -> void:
	_profile_btn.select(clampi(_profile, 0, _PROFILE_KEYS.size() - 1))
	_profile_btn.disabled = _gear_locked
	_lock_label.visible = _gear_locked

	var skate_colors: Array[Color] = []
	var glove_colors: Array[Color] = []
	var names: Array[String] = []
	var chip_labels: Array[String] = []
	for i: int in TapeColorRegistry.count():
		skate_colors.append(TapeColorRegistry.resolve(i, _team_accent))
		glove_colors.append(_kit_gloves if i == TapeColorRegistry.TEAM_INDEX
				else TapeColorRegistry.resolve(i, _kit_gloves))
		names.append(tr(TapeColorRegistry.NAME_KEYS[i]))
		# The TEAM chip says so — it tracks the kit rather than being one
		# more fixed color.
		chip_labels.append(tr(&"TAPE_COLOR_TEAM_SHORT")
				if i == TapeColorRegistry.TEAM_INDEX else "")
	_skate_dd.set_palette(skate_colors, names, chip_labels)
	_skate_dd.set_selected(_skate_color)
	_glove_dd.set_palette(glove_colors, names, chip_labels)
	_glove_dd.set_selected(_glove_color)
	# Laces share the skate palette (TEAM resolves to the accent).
	_lace_dd.set_palette(skate_colors, names, chip_labels)
	_lace_dd.set_selected(_lace_color)


# Repaints the turntable pieces with the current picks — same finishes and
# stripe semantics as the rink (skate leather 0.42, glove cloth 0.9; the
# steel stays steel): the picks color only the collar band and the wrist
# cuff, while boot, collar, and fist keep the kit look.
func _repaint_preview() -> void:
	if _boot == null:
		return
	var boot_mat := StandardMaterial3D.new()
	boot_mat.albedo_color = Color(0.08, 0.08, 0.08)
	boot_mat.roughness = 0.42
	_boot.material_override = boot_mat
	_collar.material_override = boot_mat.duplicate()
	var stripe_mat := StandardMaterial3D.new()
	stripe_mat.albedo_color = _resolved_skate()
	stripe_mat.roughness = 0.42
	_skate_stripe.material_override = stripe_mat
	var laces_mat := StandardMaterial3D.new()
	laces_mat.albedo_color = _resolved_lace()
	laces_mat.roughness = 0.9
	_laces.material_override = laces_mat
	var fist_mat := StandardMaterial3D.new()
	fist_mat.albedo_color = _kit_gloves
	fist_mat.roughness = 0.9
	_fist.material_override = fist_mat
	var cuff_mat := StandardMaterial3D.new()
	cuff_mat.albedo_color = _resolved_glove()
	cuff_mat.roughness = 0.9
	_cuff.material_override = cuff_mat
