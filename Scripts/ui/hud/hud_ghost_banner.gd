class_name HudGhostBanner
extends Node

# Local-player infraction banner. Shown whenever the local skater is ghosted
# for a reason the player can clear themselves (offside or crease violation),
# naming the infraction and the action that lifts it. Driven each frame from the
# local skater's own position; icing (a whole-team ghost) keeps its own toast.

var _root: Control = null
var _reason_label: Label = null
var _instr_label: Label = null
var _pulse_t: float = 0.0
# Lets the banner distinguish an offside from a pure crease violation deep in
# the attacking zone, where no offside ever occurred.
var _was_offside: bool = false

func build(scale_root: Control) -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_TOP_WIDE)
	# Sits below the scorebug, centred in the upper third — out of the way of the
	# lower-third phase chyron.
	root.offset_top = 96.0
	root.offset_bottom = 220.0
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root = root
	scale_root.add_child(root)

	var centering := CenterContainer.new()
	centering.set_anchors_preset(Control.PRESET_FULL_RECT)
	centering.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(centering)

	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.BROADCAST_BG
	style.set_corner_radius_all(4)
	style.anti_aliasing = false
	style.set_content_margin(SIDE_LEFT, 28)
	style.set_content_margin(SIDE_RIGHT, 28)
	style.set_content_margin(SIDE_TOP, 12)
	style.set_content_margin(SIDE_BOTTOM, 12)
	style.set_border_width_all(2)
	style.border_color = MenuStyle.DANGER

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", style)
	var wrapper: Control = MenuStyle.wrap_drop_shadow(panel, Vector2(4, 4))
	centering.add_child(wrapper)

	var vbox := VBoxContainer.new()
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	vbox.add_theme_constant_override("separation", 2)
	panel.add_child(vbox)

	_reason_label = HudChrome.lbl("", 30, MenuStyle.DANGER)
	_reason_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_reason_label)

	_instr_label = HudChrome.lbl("", 16, MenuStyle.BROADCAST_CREAM)
	_instr_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(_instr_label)

	root.visible = false

func update() -> void:
	if _root == null:
		return
	var record: PlayerRecord = GameManager.get_local_player()
	var skater: Skater = record.skater if record != null else null
	if skater == null or record.team == null or not skater.is_ghost:
		if _root.visible:
			_root.visible = false
		_was_offside = false
		return
	var pos: Vector3 = skater.global_position
	var team_id: int = record.team.team_id
	var reason: String = ""
	var instruction: String = ""
	# An offside ghost is held until the player tags up (has_tagged_up), so once
	# we see them offside we latch it and keep showing OFFSIDE until they cross
	# back — even after the puck enters the zone (which makes is_offside read
	# false). Tagging up clears the latch.
	var tagged_up: bool = InfractionRules.has_tagged_up(pos.z, team_id)
	if tagged_up:
		_was_offside = false
	elif GameManager.get_rule_set() == GameRules.RuleSet.ARCADE:
		var puck: Puck = GameManager.get_puck()
		if puck != null:
			# GameManager's resolver, not puck.carrier — the latter is host-only, so
			# a carrying client reads as puckless and latches OFFSIDE while
			# actually carrying the puck into the zone (carrying is never offside).
			var is_carrier: bool = GameManager.get_puck_carrier() == skater
			if InfractionRules.is_offside(pos.z, team_id, puck.global_position.z, is_carrier):
				_was_offside = true
	# Reason is derived from the local skater's position. Offside takes priority:
	# a skater serving an offside in the opponent crease must skate back to the
	# blue line, which clears the crease violation incidentally on the way. But a
	# player who is merely camping the crease while ONSIDE never went offside, so
	# the latch stays false and they get the crease prompt. (A defender camping
	# their OWN crease is never offside either — has_tagged_up holds in their own
	# end — so that case also falls through to the crease prompt.)
	if _was_offside and not tagged_up:
		reason = tr(&"INFRACTION_OFFSIDE")
		instruction = tr(&"GHOST_OFFSIDE_INSTRUCTION")
	elif CreaseRules.is_in_crease(Vector2(pos.x, pos.z)):
		reason = tr(&"INFRACTION_CREASE")
		instruction = tr(&"GHOST_CREASE_INSTRUCTION")
	else:
		# Any other ghost cause (e.g. a whole-team icing ghost) surfaces through
		# its own toast — no per-player recovery action to prompt here.
		if _root.visible:
			_root.visible = false
		return
	if _reason_label.text != reason:
		_reason_label.text = reason
	if _instr_label.text != instruction:
		_instr_label.text = instruction
	_root.visible = true
	# Slow attention pulse on the banner alpha so a persistent ghost keeps
	# drawing the eye without flashing.
	_pulse_t += get_process_delta_time() * 4.0
	_root.modulate.a = 0.75 + 0.25 * sin(_pulse_t)
