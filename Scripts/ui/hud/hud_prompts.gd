class_name HudPrompts
extends Node

# The persistent bottom-edge affordances: skip-the-replay, save-the-clip, and
# the free-play menu hint. All three re-resolve their glyphs when the active
# input device flips.

# The skip line is mirrored into the intermission overlay, which draws its own
# copy under its scrim; the HUD forwards this to it.
signal skip_text_changed(text: String)

var _skip_label: Label = null
var _skip_tween: Tween = null
var _skip_vote_current: int = 0
var _skip_vote_total: int = 0
# "SAVE GIF" affordance, shown above the skip prompt whenever a goal clip is
# capturing (the cinematic, or a clip of the post-game reel).
var _clip_label: Label = null
var _clip_available: bool = false
var _clip_state: GoalClipExporter.State = GoalClipExporter.State.IDLE
var _menu_hint_label: Label = null
var _menu_hint_tween: Tween = null

# Bottom-right "[SPACE] TO SKIP" prompt shown during goal replays. Lives outside
# the chyron because the skip-UX is a player affordance, not broadcast chrome.
func build_skip(scale_root: Control) -> void:
	# Pad votes to skip with the south face button; keyboard with Space. Built from
	# the same device/brand-aware text the vote-tally refresh uses.
	_skip_label = HudChrome.lbl(skip_text(), 18, MenuStyle.BROADCAST_CREAM)
	_skip_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	_skip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_skip_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_skip_label.anchor_left = 1.0
	_skip_label.anchor_right = 1.0
	_skip_label.anchor_top = 1.0
	_skip_label.anchor_bottom = 1.0
	# Right edge sits at -52 so the prompt clears the bug-report icon (which
	# spans -36 to -8 from the right edge) with ~16px of breathing room.
	_skip_label.offset_left = -324.0
	_skip_label.offset_right = -52.0
	_skip_label.offset_top = -52.0
	_skip_label.offset_bottom = -24.0
	_skip_label.visible = false
	scale_root.add_child(_skip_label)

# "SAVE GIF" prompt, stacked directly above the skip prompt and sharing its
# right edge. Deliberately quieter than the skip prompt (smaller, dimmed, no
# pulse): skipping is the thing every player does every goal, saving is an
# occasional extra, and two pulsing prompts in one corner fight each other.
func build_clip(scale_root: Control) -> void:
	_clip_label = HudChrome.lbl(_clip_text(), 15, MenuStyle.BROADCAST_DIM)
	_clip_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	_clip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clip_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_clip_label.anchor_left = 1.0
	_clip_label.anchor_right = 1.0
	_clip_label.anchor_top = 1.0
	_clip_label.anchor_bottom = 1.0
	_clip_label.offset_left = -324.0
	_clip_label.offset_right = -52.0
	# One line above the skip prompt's -52/-24 band.
	_clip_label.offset_top = -76.0
	_clip_label.offset_bottom = -52.0
	_clip_label.visible = false
	scale_root.add_child(_clip_label)

func build_menu_hint(scale_root: Control) -> void:
	_menu_hint_label = HudChrome.lbl(_menu_hint_text(), 16, MenuStyle.BROADCAST_CREAM)
	_menu_hint_label.add_theme_font_override("font", MenuStyle.UI_FONT)
	# Bottom-center: anchored to the bottom edge, horizontally centered (a ~200px
	# box straddling the 0.5 anchor), sitting 16px above the bottom.
	_menu_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_menu_hint_label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_menu_hint_label.anchor_left = 0.5
	_menu_hint_label.anchor_right = 0.5
	_menu_hint_label.anchor_top = 1.0
	_menu_hint_label.anchor_bottom = 1.0
	_menu_hint_label.offset_left = -100.0
	_menu_hint_label.offset_right = 100.0
	_menu_hint_label.offset_top = -40.0
	_menu_hint_label.offset_bottom = -16.0
	# Starts hidden — the HUD opens the menu right away, which fires the opened
	# signal and keeps the hint down until the player first closes the menu.
	_menu_hint_label.visible = false
	scale_root.add_child(_menu_hint_label)

# ── Skip prompt ──────────────────────────────────────────────────────────────

func skip_text() -> String:
	var base: String = ControllerGlyphs.prompt(
			"[SPACE] TO SKIP", "[%s] TO SKIP" % ControllerGlyphs.joy_label(JOY_BUTTON_A))
	if _skip_vote_total <= 1:
		# Solo session — no tally, the single press just skips.
		return base
	return "%s  (%d/%d)" % [base, _skip_vote_current, _skip_vote_total]

# The HUD gates the skip bind on this: the (Space-shared) brake key must never
# fire a vote outside a skippable window.
func skip_visible() -> bool:
	return _skip_label != null and _skip_label.visible

func show_skip() -> void:
	_refresh_skip_text()
	_skip_label.visible = true
	if _skip_tween != null and _skip_tween.is_running():
		_skip_tween.kill()
	_skip_tween = MenuStyle.pulse(_skip_label)

func hide_skip() -> void:
	if _skip_tween != null and _skip_tween.is_running():
		_skip_tween.kill()
	_skip_tween = null
	_skip_label.modulate.a = 1.0
	_skip_label.visible = false
	reset_skip_votes()

func set_skip_votes(current: int, total: int) -> void:
	_skip_vote_current = current
	_skip_vote_total = total
	_refresh_skip_text()

func reset_skip_votes() -> void:
	_skip_vote_current = 0
	_skip_vote_total = 0

func _refresh_skip_text() -> void:
	var text: String = skip_text()
	if _skip_label != null:
		_skip_label.text = text
	skip_text_changed.emit(text)

# ── Clip prompt ──────────────────────────────────────────────────────────────

func set_clip_available(available: bool) -> void:
	_clip_available = available
	_refresh_clip()

func set_clip_state(state: GoalClipExporter.State) -> void:
	_clip_state = state
	_refresh_clip()

# Visible while a clip is capturing (press to save) or an export is in flight
# (so the player sees their press landed). Hidden otherwise.
func _refresh_clip() -> void:
	if _clip_label == null:
		return
	var busy: bool = _clip_state != GoalClipExporter.State.IDLE
	_clip_label.visible = _clip_available or busy
	_clip_label.text = _clip_text()

func _clip_text() -> String:
	if _clip_state != GoalClipExporter.State.IDLE:
		return tr("CLIP_SAVING")
	var key: String = ControllerGlyphs.prompt(
			"[F]", "[%s]" % ControllerGlyphs.joy_label(JOY_BUTTON_X))
	return tr("CLIP_SAVE_PROMPT") % key

# ── Menu hint ────────────────────────────────────────────────────────────────

func _menu_hint_text() -> String:
	return "%s MENU" % ControllerGlyphs.prompt(
			"[ESC]", "[%s]" % ControllerGlyphs.joy_label(JOY_BUTTON_START))

func show_menu_hint() -> void:
	if _menu_hint_label == null:
		return
	_menu_hint_label.visible = true
	if _menu_hint_tween != null and _menu_hint_tween.is_running():
		_menu_hint_tween.kill()
	_menu_hint_tween = MenuStyle.pulse(_menu_hint_label)

func hide_menu_hint() -> void:
	if _menu_hint_label == null:
		return
	if _menu_hint_tween != null and _menu_hint_tween.is_running():
		_menu_hint_tween.kill()
	_menu_hint_tween = null
	_menu_hint_label.modulate.a = 1.0
	_menu_hint_label.visible = false

# Re-resolve every persistent prompt to the current device. Fired by
# InputDeviceTracker.device_changed so the menu-open hint and the skip-vote
# prompt follow a mid-session mouse↔pad swap. (The spectator toast is one-shot —
# it keeps whatever device it was pushed with.)
func refresh_device_prompts() -> void:
	if _menu_hint_label != null:
		_menu_hint_label.text = _menu_hint_text()
	_refresh_skip_text()
	_refresh_clip()
