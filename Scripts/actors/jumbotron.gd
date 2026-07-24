@tool
class_name Jumbotron
extends Node3D

# Center-hung arena scoreboard — pure spectator/lobby set dressing. Every
# visual part lives on RENDER_LAYER_MASK (render layer 2, otherwise unused in
# the project), and GameCamera clears that bit from its cull_mask: the
# gameplay camera is top-down over center ice, so the cube would hang
# directly between it and the play. Only the non-gameplay cameras (lobby
# backdrop orbit, spectator/broadcast, chase, free, goal-replay) render it —
# they all keep Camera3D's default everything-on cull_mask, so no per-camera
# wiring is needed.
#
# The four faces share one SubViewport screen fed entirely by replicated
# GameManager signals (score / clock / period / phase / goal / team colors),
# so host, clients, and offline all show the same board with zero networking.
# What the screen shows per phase is decided by JumbotronRules (pure,
# GUT-tested); this node just renders the chosen mode. Perf contract: the
# viewport re-renders one 512×256 UI frame only when displayed content
# actually changes (UPDATE_ONCE per change — handlers early-return on
# no-change, so the per-tick clock signal costs one string compare), and the
# geometry is culled per-camera, so gameplay pays nothing at all.
#
# No physics: the puck's vertical clamp (Puck.max_height 3 m) keeps play far
# below the housing, so the board needs no collision shape.

# Render layer 2 (bit for layer index 1). Everything else in the project
# renders on the default layer 1; GameCamera masks this bit out.
const RENDER_LAYER_MASK: int = 1 << 1

const _SCREEN_SIZE: Vector2i = Vector2i(512, 256)
# Above the environment glow threshold (1.3) so screens and trim bloom.
const _SCREEN_EMISSION: float = 1.5
const _BAND_EMISSION_IDLE: float = 1.4
const _BAND_EMISSION_GOAL: float = 2.6
const _BAND_COLOR_IDLE: Color = Color(0.85, 0.82, 0.72)
const _BG_COLOR: Color = Color(0.05, 0.05, 0.07)
const _DIM_TEXT: Color = Color(0.75, 0.78, 0.82)

# Housing bottom ~9.9 m: above the shell wall's sightline band from the low
# cams, below nothing that matters — gameplay never renders it and the puck
# can't reach it. The column runs up into the dark above the shell top
# (~20.5 m) so it reads as hung from unseen rafters.
@export var hang_center_y: float = 11.2
@export var housing_size: Vector3 = Vector3(5.4, 2.6, 5.4)
@export var column_top_y: float = 28.0
@export var screen_size: Vector2 = Vector2(4.6, 1.9)
# Editor escape hatch: rebuild the geometry after code/param edits.
@export var rebuild: bool = false:
	set(_v):
		if is_inside_tree():
			_build()

# Same initial defaults as ArenaStands; real colors arrive via
# team_colors_ready (in game) or set_team_colors (lobby backdrop).
var _home_color: Color = Color(0.85, 0.20, 0.22)
var _away_color: Color = Color(0.18, 0.40, 0.85)

var _phase: int = GamePhase.Phase.PLAYING
# The board idles on the attract screen until a game signal arrives; the
# lobby backdrop locks it there for good (its arena has no live game).
var _attract_locked: bool = false
var _has_game_context: bool = false
var _score_home: int = 0
var _score_away: int = 0
var _clock_str: String = "0:00"
var _period_str: String = "1ST"
var _goal_scorer: String = ""
var _goal_color: Color = Color.WHITE

var _viewport: SubViewport = null
var _band_mat: StandardMaterial3D = null
# The four faces' shared screen material, held so exit teardown can drop its
# ViewportTexture bindings before the RenderingServer is finalized — see
# _teardown_viewport().
var _screen_mat: StandardMaterial3D = null
var _viewport_freed: bool = false

# Screen pages (one Control per JumbotronRules.Mode) and their labels.
var _pages: Dictionary = {}
var _live_home_panel: ColorRect = null
var _live_away_panel: ColorRect = null
var _live_score_home: Label = null
var _live_score_away: Label = null
var _live_clock: Label = null
var _live_period: Label = null
var _goal_bg: ColorRect = null
var _goal_scorer_lbl: Label = null
var _break_title: Label = null
var _break_score: Label = null
var _final_score: Label = null
var _attract_bar_home: ColorRect = null
var _attract_bar_away: ColorRect = null


func _ready() -> void:
	_build()
	var gm: Node = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	if gm.has_signal("team_colors_ready"):
		gm.team_colors_ready.connect(set_team_colors)
	if gm.has_signal("score_changed"):
		gm.score_changed.connect(_on_score_changed)
	if gm.has_signal("clock_updated"):
		gm.clock_updated.connect(_on_clock_updated)
	if gm.has_signal("period_synced"):
		gm.period_synced.connect(_on_period_synced)
	if gm.has_signal("goal_scored"):
		gm.goal_scored.connect(_on_goal_scored)
	if gm.has_signal("phase_changed"):
		gm.phase_changed.connect(_on_phase_changed)


# Release the screen SubViewport and its ViewportTexture bindings explicitly,
# before Godot finalizes the RenderingServer on quit. The four screen quads
# share one material holding the viewport's texture as albedo + emission; left
# bound at exit, the viewport — plus the canvas items and text-shaping RIDs from
# its Label pages — is torn down after the server and reported as leaked RIDs.
# Nulling the material's texture refs drops the binding and freeing the viewport
# releases the RIDs in order. WM_CLOSE fires on the OS window close; _exit_tree
# covers the menu Quit / scene-change paths. Guarded against a double-free, and
# reset in _build so a rebuild after a reparent still tears down cleanly. Mirrors
# HockeyRink._teardown_render_targets.
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_teardown_viewport()


func _exit_tree() -> void:
	_teardown_viewport()


func _teardown_viewport() -> void:
	if _viewport_freed:
		return
	_viewport_freed = true
	if _screen_mat != null:
		_screen_mat.albedo_texture = null
		_screen_mat.emission_texture = null
	_screen_mat = null
	if is_instance_valid(_viewport):
		_viewport.free()
	_viewport = null


# ── Public API ───────────────────────────────────────────────────────────────

# Pin the board to the attract screen regardless of game signals. Used by the
# lobby backdrop, whose arena instance has no live match behind it.
func lock_attract() -> void:
	_attract_locked = true
	_refresh()


# Signature matches GameManager.team_colors_ready so the signal connects
# directly; the lobby backdrop calls it by hand as its color votes resolve.
func set_team_colors(home_primary: Color, _home_secondary: Color,
		away_primary: Color, _away_secondary: Color) -> void:
	_home_color = home_primary
	_away_color = away_primary
	_apply_team_colors()
	_refresh()


func current_mode() -> JumbotronRules.Mode:
	return JumbotronRules.screen_mode(
			_phase, _attract_locked or not _has_game_context)


# ── Replay feed ──────────────────────────────────────────────────────────────
# The offline ReplayViewer has no live GameManager signals to drive the board,
# so it pushes the recorded game state (WorldStateCodec.decode_for_replay's
# game_state block) and goal events here instead. Change-detected like the
# signal handlers, so the one-redraw-per-content-change perf contract holds
# while the driver emits on every recorded clock tick.

func apply_replay_game_state(gs: Dictionary) -> void:
	var changed: bool = not _has_game_context
	_has_game_context = true
	var score0: int = int(gs.get("score0", _score_home))
	var score1: int = int(gs.get("score1", _score_away))
	if score0 != _score_home or score1 != _score_away:
		_score_home = score0
		_score_away = score1
		changed = true
	var phase: int = int(gs.get("phase", _phase))
	if phase != _phase:
		_phase = phase
		changed = true
	var clock_txt: String = JumbotronRules.clock_text(
			float(gs.get("time_remaining", 0.0)))
	if clock_txt != _clock_str:
		_clock_str = clock_txt
		changed = true
	var period_txt: String = JumbotronRules.period_text(int(gs.get("period", 1)))
	if period_txt != _period_str:
		_period_str = period_txt
		changed = true
	if changed:
		_refresh()


# Replayed goal event: the recorded event carries the scorer's display name
# and scoring team id (no Team object offline). The GOAL page itself is
# selected by the phase from apply_replay_game_state; this fills its content.
func show_goal(scorer_name: String, team_id: int) -> void:
	_has_game_context = true
	_goal_scorer = scorer_name
	_goal_color = _home_color if team_id == 0 else _away_color
	_refresh()


# ── Signal handlers ──────────────────────────────────────────────────────────

# First game signal of any kind flips the board off the attract screen — that
# alone changes the selected mode, so it refreshes even when the handler's
# own payload matches the current display (and would otherwise early-return).
func _mark_game_context() -> void:
	if _has_game_context:
		return
	_has_game_context = true
	_refresh()


func _on_score_changed(score_0: int, score_1: int) -> void:
	_mark_game_context()
	if score_0 == _score_home and score_1 == _score_away:
		return
	_score_home = score_0
	_score_away = score_1
	_refresh()


# Fires every broadcast tick; the string compare keeps redraws at one per
# displayed second.
func _on_clock_updated(time_remaining: float) -> void:
	_mark_game_context()
	var txt: String = JumbotronRules.clock_text(time_remaining)
	if txt == _clock_str:
		return
	_clock_str = txt
	_refresh()


func _on_period_synced(new_period: int) -> void:
	_mark_game_context()
	var txt: String = JumbotronRules.period_text(new_period)
	if txt == _period_str:
		return
	_period_str = txt
	_refresh()


func _on_goal_scored(scoring_team: Team, scorer_name: String,
		_assist1: String, _assist2: String) -> void:
	show_goal(scorer_name, scoring_team.team_id if scoring_team != null else 0)


func _on_phase_changed(new_phase: GamePhase.Phase) -> void:
	_mark_game_context()
	if new_phase == _phase:
		return
	_phase = new_phase
	_refresh()


# ── Screen refresh ───────────────────────────────────────────────────────────

# Re-select the page, push the current strings/colors into its labels, and
# queue exactly one viewport render. Callers already early-return when their
# datum didn't change, so every _refresh is a genuine content change.
func _refresh() -> void:
	if _viewport == null:
		return
	var mode: JumbotronRules.Mode = current_mode()
	for key: int in _pages:
		(_pages[key] as Control).visible = (key == mode)

	# Push every page's dynamic content — plain property writes, and only the
	# visible page gets rendered. Order-proof against how game signals arrive
	# (goal info lands before or after the phase flip depending on emitter).
	var score_line: String = "%d - %d" % [_score_home, _score_away]
	_live_score_home.text = str(_score_home)
	_live_score_away.text = str(_score_away)
	_live_clock.text = _clock_str
	_live_period.text = _period_str
	_goal_bg.color = _goal_color.darkened(0.25)
	_goal_scorer_lbl.text = _goal_scorer
	_break_title.text = "END OF %s" % _period_str
	_break_score.text = score_line
	_final_score.text = score_line

	if mode == JumbotronRules.Mode.GOAL:
		_set_band(_goal_color, _BAND_EMISSION_GOAL)
	else:
		_set_band(_BAND_COLOR_IDLE, _BAND_EMISSION_IDLE)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _apply_team_colors() -> void:
	if _viewport == null:
		return
	_live_home_panel.color = _home_color
	_live_away_panel.color = _away_color
	_attract_bar_home.color = _home_color
	_attract_bar_away.color = _away_color


func _set_band(color: Color, energy: float) -> void:
	_band_mat.emission = color
	_band_mat.emission_energy_multiplier = energy


# ── Build ────────────────────────────────────────────────────────────────────

func _build() -> void:
	# A prior _exit_tree (e.g. a reparent) may have latched the teardown guard;
	# clear it so a genuine later teardown still frees the freshly built viewport.
	_viewport_freed = false
	for child: Node in get_children():
		child.queue_free()
	_build_screen_viewport()
	_build_meshes()
	_apply_team_colors()
	_refresh()


func _build_meshes() -> void:
	var housing_mat: StandardMaterial3D = _matte(Color(0.09, 0.09, 0.11), 0.6)
	_add_box("Housing", housing_size, Vector3(0.0, hang_center_y, 0.0), housing_mat)

	# Gantry column up into the dark above the shell wall — the "rafters".
	var housing_top: float = hang_center_y + housing_size.y * 0.5
	var column_h: float = maxf(column_top_y - housing_top, 0.1)
	_add_box("Column", Vector3(0.7, column_h, 0.7),
			Vector3(0.0, housing_top + column_h * 0.5, 0.0),
			_matte(Color(0.07, 0.07, 0.09), 0.8))

	# Emissive LED trim bands along the housing's top and bottom edges; the
	# goal flash re-tints these to the scoring team's color.
	_band_mat = _matte(Color(0.05, 0.05, 0.06), 0.4)
	_band_mat.emission_enabled = true
	_band_mat.emission = _BAND_COLOR_IDLE
	_band_mat.emission_energy_multiplier = _BAND_EMISSION_IDLE
	var band_size: Vector3 = Vector3(housing_size.x + 0.12, 0.16, housing_size.z + 0.12)
	var band_dy: float = housing_size.y * 0.5 - 0.10
	_add_box("BandTop", band_size, Vector3(0.0, hang_center_y + band_dy, 0.0), _band_mat)
	_add_box("BandBottom", band_size, Vector3(0.0, hang_center_y - band_dy, 0.0), _band_mat)

	# Four screen quads, one per face, sharing the viewport texture. Unshaded
	# + emissive so the board reads as a lit display, not a lit surface.
	var screen_mat: StandardMaterial3D = StandardMaterial3D.new()
	_screen_mat = screen_mat
	screen_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var screen_tex: ViewportTexture = _viewport.get_texture()
	screen_mat.albedo_texture = screen_tex
	screen_mat.emission_enabled = true
	screen_mat.emission_texture = screen_tex
	screen_mat.emission_energy_multiplier = _SCREEN_EMISSION
	var quad: QuadMesh = QuadMesh.new()
	quad.size = screen_size
	var face_d: float = housing_size.z * 0.5 + 0.02
	for k: int in 4:
		var yaw: float = k * PI * 0.5
		var mi: MeshInstance3D = MeshInstance3D.new()
		mi.mesh = quad
		mi.material_override = screen_mat
		mi.transform = Transform3D(
				Basis(Vector3.UP, yaw),
				Vector3(sin(yaw), 0.0, cos(yaw)) * face_d
						+ Vector3(0.0, hang_center_y, 0.0))
		mi.name = "Screen%d" % k
		_finish_visual(mi)


func _add_box(part_name: String, size: Vector3, pos: Vector3,
		mat: StandardMaterial3D) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	var mesh: BoxMesh = BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.name = part_name
	_finish_visual(mi)


# The layer bit is the whole trick: gameplay's camera masks it out, every
# other camera renders it by default. No shadows — the board hangs above all
# spotlight ranges and its shadow would land on ice nobody sees it from.
func _finish_visual(mi: MeshInstance3D) -> void:
	mi.layers = RENDER_LAYER_MASK
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _matte(color: Color, roughness: float) -> StandardMaterial3D:
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = roughness
	return mat


# ── Screen UI ────────────────────────────────────────────────────────────────

# One SubViewport with a Control page per mode; _refresh toggles visibility
# and requests a single render. 2D only, renders on demand — see the perf
# contract in the class doc.
func _build_screen_viewport() -> void:
	_viewport = SubViewport.new()
	_viewport.name = "ScreenViewport"
	_viewport.size = _SCREEN_SIZE
	_viewport.disable_3d = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	var root: Control = Control.new()
	root.size = Vector2(_SCREEN_SIZE)
	_viewport.add_child(root)
	var bg: ColorRect = ColorRect.new()
	bg.color = _BG_COLOR
	bg.size = Vector2(_SCREEN_SIZE)
	root.add_child(bg)

	_pages = {
		JumbotronRules.Mode.LIVE: _build_live_page(root),
		JumbotronRules.Mode.GOAL: _build_goal_page(root),
		JumbotronRules.Mode.BREAK: _build_break_page(root),
		JumbotronRules.Mode.FINAL: _build_final_page(root),
		JumbotronRules.Mode.ATTRACT: _build_attract_page(root),
	}


func _build_live_page(root: Control) -> Control:
	var page: Control = _page(root)
	_live_home_panel = _rect(page, _home_color, Rect2(0, 0, 96, 256))
	_live_away_panel = _rect(page, _away_color, Rect2(416, 0, 96, 256))
	_live_score_home = _lbl(page, "0", 96, Color.WHITE, Rect2(96, 56, 120, 128))
	_live_score_away = _lbl(page, "0", 96, Color.WHITE, Rect2(296, 56, 120, 128))
	_live_clock = _lbl(page, "0:00", 46, Color.WHITE, Rect2(196, 62, 120, 62))
	_live_period = _lbl(page, "1ST", 28, _DIM_TEXT, Rect2(196, 134, 120, 40))
	return page


func _build_goal_page(root: Control) -> Control:
	var page: Control = _page(root)
	_goal_bg = _rect(page, _home_color, Rect2(0, 0, 512, 256))
	_lbl(page, "GOAL!", 100, Color.WHITE, Rect2(0, 30, 512, 120))
	_goal_scorer_lbl = _lbl(page, "", 36, Color.WHITE, Rect2(0, 168, 512, 52))
	return page


func _build_break_page(root: Control) -> Control:
	var page: Control = _page(root)
	_break_title = _lbl(page, "END OF 1ST", 46, Color.WHITE, Rect2(0, 52, 512, 62))
	_break_score = _lbl(page, "0 - 0", 52, _DIM_TEXT, Rect2(0, 130, 512, 70))
	return page


func _build_final_page(root: Control) -> Control:
	var page: Control = _page(root)
	_lbl(page, "FINAL", 52, _DIM_TEXT, Rect2(0, 34, 512, 66))
	_final_score = _lbl(page, "0 - 0", 76, Color.WHITE, Rect2(0, 110, 512, 100))
	return page


func _build_attract_page(root: Control) -> Control:
	var page: Control = _page(root)
	_lbl(page, "MITTS", 104, Color.WHITE, Rect2(0, 42, 512, 130))
	_attract_bar_home = _rect(page, _home_color, Rect2(86, 194, 150, 22))
	_attract_bar_away = _rect(page, _away_color, Rect2(276, 194, 150, 22))
	return page


func _page(root: Control) -> Control:
	var page: Control = Control.new()
	page.size = Vector2(_SCREEN_SIZE)
	page.visible = false
	root.add_child(page)
	return page


func _rect(parent: Control, color: Color, rect: Rect2) -> ColorRect:
	var cr: ColorRect = ColorRect.new()
	cr.color = color
	cr.position = rect.position
	cr.size = rect.size
	parent.add_child(cr)
	return cr


func _lbl(parent: Control, text: String, font_size: int, color: Color,
		rect: Rect2) -> Label:
	var lbl: Label = Label.new()
	lbl.text = text
	lbl.position = rect.position
	lbl.size = rect.size
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	parent.add_child(lbl)
	return lbl
