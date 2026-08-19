@tool
class_name ArenaStands
extends Node3D

# The arena around the rink: terraced stands, a MultiMesh spectator crowd, the
# rinkside furniture, and the signage overhead.
#
# This file is the orchestrator and nothing else. It owns the @export knobs, the
# rebuild, the layout cache and the game-signal wiring; every piece of geometry
# is built by a collaborator under Scripts/actors/arena/, each constructed from
# one immutable `ArenaBowlSpec` snapshot of those knobs. Pattern mirrors
# HockeyRink — single rebuild on @export change, no runtime updates. See
# Scripts/actors/arena/CLAUDE.md for how the pieces divide.
#
# **The order of the `_rebuild` calls below is load-bearing.** Each collaborator
# adds its own children at the moment it is called, so the call sequence IS the
# child order — and with it the draw order the opaque passes settle into and the
# order a test reads the bowl back in.

@export var rink_length: float = 60.0:
	set(v):
		rink_length = v
		_request_rebuild()
@export var rink_width: float = 26.0:
	set(v):
		rink_width = v
		_request_rebuild()
@export var corner_radius: float = 8.53:
	set(v):
		corner_radius = v
		_request_rebuild()
# Seat height of the first row. Fans look over the boards (Y=1.07) and
# through the glass (Y=1.07–2.22). With a seated body+head ~0.69 m tall,
# tread_y=0.8 puts eyes at ~1.5 m — mid-glass, behind the protective
# barrier, exactly how rinkside seats work.
@export var stands_base_y: float = 0.8:
	set(v):
		stands_base_y = v
		_request_rebuild()
@export var num_terraces: int = 15:
	set(v):
		num_terraces = v
		_request_rebuild()
@export var tread_depth: float = 0.6:
	set(v):
		tread_depth = v
		_request_rebuild()
@export var riser_height: float = 0.4:
	set(v):
		riser_height = v
		_request_rebuild()
# Outward offset measured from rink_width/2 (the wall/glass center). Boards
# and glass have wall_thickness=0.3 centered on this line, so their outer
# face sits at +0.15, and the kickplate/cap-rail lips protrude another
# ~1 cm beyond that. Default 0.20 keeps a few cm of clearance past the
# lips; values below ~0.17 will clip into the cap rail in the corners.
@export var base_outward_offset: float = 0.20:
	set(v):
		base_outward_offset = v
		_request_rebuild()
@export var corner_segments: int = 14:
	set(v):
		corner_segments = v
		_request_rebuild()
@export var concrete_color: Color = Color(0.42, 0.42, 0.45):
	set(v):
		concrete_color = v
		_request_rebuild()

@export_group("Upper Deck")
# Concourse walkway between the lower bowl's top row and the upper deck — a
# flat ring continuing the top tread's level outward. Also the shell wall's
# standoff from the bowl when the upper deck is disabled.
@export var walkway_depth: float = 2.2:
	set(v):
		walkway_depth = v
		_request_rebuild()
# Rows in the second tier. 0 disables the deck entirely (the shell wall then
# closes in right behind the walkway) — PlayerPrefs.apply_video drops it to 0
# on LOW crowd density, since the deck roughly doubles the spectator count.
@export var upper_terraces: int = 10:
	set(v):
		upper_terraces = v
		_request_rebuild()
# Steeper rake than the lower bowl (same tread depth, taller risers), the way
# a real second deck stacks over a concourse.
@export var upper_riser_height: float = 0.55:
	set(v):
		upper_riser_height = v
		_request_rebuild()
# Balcony rise from the walkway up to the deck's first tread; the concrete
# fascia wall the lower bowl's back rows sit against spans exactly this height.
#
# This is the number that makes the building read as two decks rather than one
# long bank of seats. A real second tier is cantilevered a storey up, so the
# level under it is a room you could stand in — and that headroom is also where
# the lower bowl's portals go. Anything near a single step (~1 m) is
# geometrically a concourse and visually a continuation of the lower bowl.
@export var upper_deck_rise: float = 4.0:
	set(v):
		upper_deck_rise = v
		_request_rebuild()

@export_group("Shell")
# Arena shell wall: rises this far above the top spectator row's tread, all
# the way around. 8 m puts the wall top at ~20.5 m with the default decks —
# high enough that the lobby backdrop's orbit camera and the replay chase cam
# keep their frame on building. Colored near the environment background so
# whatever sliver of void remains visible above it reads as dark rafters.
@export var shell_height: float = 8.0:
	set(v):
		shell_height = v
		_request_rebuild()
@export var shell_color: Color = Color(0.14, 0.15, 0.2):
	set(v):
		shell_color = v
		_request_rebuild()

@export_group("Crowd")
@export var spectator_spacing: float = 0.55:
	set(v):
		spectator_spacing = v
		_request_rebuild()
@export var spectator_inset_from_riser: float = 0.18:
	set(v):
		spectator_inset_from_riser = v
		_request_rebuild()
@export var spectator_yaw_jitter_deg: float = 18.0:
	set(v):
		spectator_yaw_jitter_deg = v
		_request_rebuild()
@export var spectator_y_jitter: float = 0.03:
	set(v):
		spectator_y_jitter = v
		_request_rebuild()

@export_group("Sections")
# Radial aisles dividing the bowl into seating sections. Aisle positions are
# evenly spaced along the boards' perimeter and shared by both decks (the
# stair corridors line up down the rake). 0 disables sections entirely.
@export var num_aisles: int = 12:
	set(v):
		num_aisles = v
		_request_rebuild()
# Cleared corridor width, measured along the base path (aisles fan slightly
# wider toward the back rows in the corners, like real stairways).
@export var aisle_width: float = 1.1:
	set(v):
		aisle_width = v
		_request_rebuild()
# Fraction of seats occupied. Real bowls are never packed solid — scattered
# empties break up the wall of bodies.
@export_range(0.0, 1.0) var attendance: float = 0.93:
	set(v):
		attendance = v
		_request_rebuild()

@export_group("Fan Mix")
# Crowd composition. Home + away + neutral should sum to 1.0; the neutral
# fraction is derived as max(0, 1 - home - away). Defaults model a typical
# home arena: a wall of home colors, a sprinkling of neutrals, and a few away
# colors scattered through — the bulk of the traveling support sits in the
# designated upper-deck visiting section (see ArenaBowlPath.away_section_id).
@export_range(0.0, 1.0) var home_fan_ratio: float = 0.65:
	set(v):
		home_fan_ratio = v
		_request_rebuild()
@export_range(0.0, 1.0) var away_fan_ratio: float = 0.08:
	set(v):
		away_fan_ratio = v
		_request_rebuild()
# Of team fans, fraction wearing secondary instead of primary. Keeps the
# bowl from reading as a solid block of one shade.
@export_range(0.0, 1.0) var secondary_color_ratio: float = 0.30:
	set(v):
		secondary_color_ratio = v
		_request_rebuild()
# Fraction of team fans whose head matches the team color (caps / face paint).
# Most heads use the neutral skin/hat palette regardless.
@export_range(0.0, 1.0) var team_cap_ratio: float = 0.22:
	set(v):
		team_cap_ratio = v
		_request_rebuild()

@export_group("Team Colors")
# Initial defaults; GameManager re-runs setup() with real team colors once
# TeamColorRegistry resolves them after _spawn_world.
@export var home_color: Color = Color(0.85, 0.20, 0.22):
	set(v):
		home_color = v
		_request_rebuild()
@export var home_color_secondary: Color = Color(0.97, 0.78, 0.20):
	set(v):
		home_color_secondary = v
		_request_rebuild()
@export var away_color: Color = Color(0.18, 0.40, 0.85):
	set(v):
		away_color = v
		_request_rebuild()
@export var away_color_secondary: Color = Color(0.92, 0.92, 0.95):
	set(v):
		away_color_secondary = v
		_request_rebuild()

@export_group("Seats")
@export var seats_enabled: bool = true:
	set(v):
		seats_enabled = v
		_request_rebuild()
# Multiplied by the per-seat shade jitter baked into the layout, so this applies
# live without invalidating the cached geometry — the same split the crowd uses
# between its layout and its paint pass.
@export var seat_color: Color = Color(0.13, 0.16, 0.26):
	set(v):
		seat_color = v
		_request_rebuild()
# How far a seat's shade may fall below `seat_color`. A bowl of one flat colour
# reads as a painted surface rather than as thousands of separate objects; a
# little unevenness is what makes the rows legible as rows.
@export_range(0.0, 0.5) var seat_shade_variation: float = 0.16:
	set(v):
		seat_shade_variation = v
		_request_rebuild()

@export_group("Vomitories")
# Portals where each aisle meets the shell. Without them the stairways climb the
# rake and stop dead against a blank wall — the bowl has no way out.
@export var vomitories_enabled: bool = true:
	set(v):
		vomitories_enabled = v
		_request_rebuild()
@export_range(0.0, 6.0) var vomitory_width: float = 2.2:
	set(v):
		vomitory_width = v
		_request_rebuild()
@export_range(0.0, 6.0) var vomitory_height: float = 2.9:
	set(v):
		vomitory_height = v
		_request_rebuild()
# How far the tunnel bores outward before its back wall. Deep enough to read as
# a passage at a glance, shallow enough that it never pokes out of the building.
@export_range(0.5, 8.0) var vomitory_depth: float = 2.6:
	set(v):
		vomitory_depth = v
		_request_rebuild()

@export_group("Rafter Banners")
@export var banners_enabled: bool = true:
	set(v):
		banners_enabled = v
		_request_rebuild()
# Hang height of the banner cloth. Width follows from the atlas cell's aspect,
# so this is the only dimension to touch.
@export_range(1.0, 10.0) var banner_height: float = 4.2:
	set(v):
		banner_height = v
		_request_rebuild()

@export_group("Ribbon Board")
@export var ribbon_enabled: bool = true:
	set(v):
		ribbon_enabled = v
		_request_rebuild()
# Metres of board travelling past a fixed point per second. Real ribbon boards
# run a walking pace — fast enough to be alive in peripheral vision, slow enough
# to read a sponsor before it leaves.
@export_range(0.0, 12.0) var ribbon_scroll_speed: float = 2.4

@export_group("")
# Editor escape hatch: also drops the static layout cache, so geometry *code*
# edits mid-session can't be masked by a stale cached bowl.
@export var rebuild: bool = false:
	set(_v):
		_layout_cache.clear()
		_request_rebuild()

# Crowd animation (Shaders/crowd.gdshader): how long a burst of excitement
# holds at peak and how long it takes to settle back to the idle murmur sway.
const _EXCITE_RISE_TIME: float = 0.25
const _EXCITE_HOLD_TIME: float = 3.5
const _EXCITE_DECAY_TIME: float = 3.0

# The ceiling rig's housings and its intro cue. Outlives rebuilds (see _ready).
const _HOUSE_LIGHTS_NAME: StringName = &"ArenaHouseLights"

var _excitement: float = 0.0
var _excite_tween: Tween = null
var _house_lights: ArenaHouseLights = null
var _render_targets_freed: bool = false
# Set while set_crowd_rows writes both row counts, so the two setters don't
# each trigger a rebuild of their own.
var _suspend_rebuild: bool = false

# Rebuilt from the exports at the top of every _rebuild; see _build_collaborators.
var _spec: ArenaBowlSpec = null
var _path: ArenaBowlPath = null
var _rake: ArenaBowlRake = null
var _deck: ArenaDeckMesh = null
var _crowd: ArenaCrowd = null
var _seating: ArenaSeating = null
var _rinkside: ArenaRinkside = null
var _signage: ArenaSignage = null

# geometry key → layout dict {terrace_mesh, shell_mesh, body/head/seat mms,
# away_flags, paint_key}.
# Everything in a layout is color-independent and deterministic, so it's built
# once per geometry-param set and reused for the process lifetime — a scene
# change's rebuild (free play → lobby → game) becomes at most a crowd repaint,
# and a same-colors rebuild skips even that. Bounded by clearing on editor param
# churn (steady state is one entry per crowd-density level).
static var _layout_cache: Dictionary = {}


# Drop the process-lifetime caches. They hold GPU RIDs that survive scene
# changes for perf, and a static var is freed at script-unload — AFTER the
# RenderingServer finalizes — so at exit these would destruct with a null server
# and their RIDs be reported as leaked. Clearing them here, from a real-shutdown
# hook (GameManager), drops the last reference while the server is still alive.
# Only call at app quit.
static func release_shared_cache() -> void:
	ArenaCrowd.release_shared_material()
	_layout_cache.clear()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_teardown_render_targets()


func _exit_tree() -> void:
	_teardown_render_targets()


func _teardown_render_targets() -> void:
	if _render_targets_freed:
		return
	_render_targets_freed = true
	set_process(false)
	if _signage != null:
		_signage.release_render_targets()


func _ready() -> void:
	_rebuild()
	# The house lights are runtime-only and live OUTSIDE the rebuild: they hold a
	# tween and the scene's captured light energies, and a rebuild mid-cue (team
	# colours arriving, say) would drop both and leave the bowl dark. _rebuild
	# skips this child by name for that reason.
	if not Engine.is_editor_hint() and get_parent() != null:
		_house_lights = ArenaHouseLights.new()
		_house_lights.name = _HOUSE_LIGHTS_NAME
		add_child(_house_lights)
		_house_lights.setup(get_parent())
	# The crowd material is static (see ArenaCrowd.shared_material): a bowl
	# mid-celebration when the scene changed would otherwise carry its excitement
	# into the fresh arena. New bowls start at the idle murmur.
	_set_excitement(0.0)
	_wire_game_signals()


func _wire_game_signals() -> void:
	var gm: Node = get_node_or_null("/root/GameManager")
	if gm == null:
		return
	if gm.has_signal("team_colors_ready"):
		gm.team_colors_ready.connect(setup)
	if gm.has_signal("goal_scored"):
		gm.goal_scored.connect(_on_goal_scored)
	if gm.has_signal("phase_changed"):
		gm.phase_changed.connect(_on_phase_changed)
	if gm.has_signal("body_check_broadcast"):
		gm.body_check_broadcast.connect(_on_body_check_broadcast)
	if gm.has_signal("faceoff_prep_announced"):
		# The cue is timed against an announced window, but a skipped intro or a
		# late joiner never reaches the end of it. Faceoff prep is the intro's
		# real exit — the same dismissal the resurfacer crew uses — so the house
		# comes back there whether the tween finished or not.
		gm.faceoff_prep_announced.connect(_on_faceoff_prep_announced)
	if gm.has_signal("pregame_intro_started"):
		gm.pregame_intro_started.connect(_on_pregame_intro_started)
	if gm.has_signal("period_intro_started"):
		# Same anticipation buzz as the opening intro when a new period's
		# skate-on begins.
		gm.period_intro_started.connect(
				func(_period: int, duration: float) -> void:
					_on_pregame_intro_started(duration))


# Called from GameManager.team_colors_ready once TeamColorRegistry resolves
# the live team colors (and again on any mid-game color change). Rebuild is
# the full path — cheap, and keeps the per-instance roll deterministic.
func setup(home_primary: Color, home_secondary: Color,
		away_primary: Color, away_secondary: Color) -> void:
	home_color = home_primary
	home_color_secondary = home_secondary
	away_color = away_primary
	away_color_secondary = away_secondary
	_rebuild()


func _request_rebuild() -> void:
	if _suspend_rebuild:
		return
	if is_inside_tree():
		_rebuild()


# One-shot crowd-density setter for PlayerPrefs.apply_video: both row counts
# land in a single rebuild instead of one per setter (which would also litter
# the layout cache with a never-again-used intermediate geometry).
func set_crowd_rows(lower: int, upper: int) -> void:
	if lower == num_terraces and upper == upper_terraces:
		return
	_suspend_rebuild = true
	num_terraces = lower
	upper_terraces = upper
	_suspend_rebuild = false
	_request_rebuild()


# Seat-surface center of a team's bench, in ArenaStands-local space. The lobby
# backdrop uses this to seat roster dummies.
func bench_seat_center(team_id: int) -> Vector3:
	if _rinkside == null:
		_build_collaborators()
	return _rinkside.bench_seat_center(team_id)


# Ramp the bowl to at least `level` (0..1), hold, then settle back to the idle
# sway. A stronger burst always wins over a fading weaker one.
func excite(level: float) -> void:
	var target: float = clampf(maxf(level, _excitement), 0.0, 1.0)
	if target <= 0.0:
		return
	if _excite_tween != null and _excite_tween.is_valid():
		_excite_tween.kill()
	_excite_tween = create_tween()
	_excite_tween.tween_method(_set_excitement, _excitement, target, _EXCITE_RISE_TIME)
	_excite_tween.tween_interval(_EXCITE_HOLD_TIME * target)
	_excite_tween.tween_method(_set_excitement, target, 0.0, _EXCITE_DECAY_TIME)


# ── Rebuild ──────────────────────────────────────────────────────────────────

# One immutable snapshot of every export that describes the bowl, handed to each
# collaborator's constructor. Collaborators read it and never write it, so the
# exports have exactly one owner: this node.
func _build_collaborators() -> void:
	var spec := ArenaBowlSpec.new()
	spec.rink_length = rink_length
	spec.rink_width = rink_width
	spec.corner_radius = corner_radius
	spec.corner_segments = corner_segments
	spec.base_outward_offset = base_outward_offset
	spec.stands_base_y = stands_base_y
	spec.num_terraces = num_terraces
	spec.tread_depth = tread_depth
	spec.riser_height = riser_height
	spec.walkway_depth = walkway_depth
	spec.upper_terraces = upper_terraces
	spec.upper_riser_height = upper_riser_height
	spec.upper_deck_rise = upper_deck_rise
	spec.shell_height = shell_height
	spec.shell_color = shell_color
	spec.concrete_color = concrete_color
	spec.vomitories_enabled = vomitories_enabled
	spec.vomitory_width = vomitory_width
	spec.vomitory_height = vomitory_height
	spec.vomitory_depth = vomitory_depth
	spec.num_aisles = num_aisles
	spec.aisle_width = aisle_width
	spec.attendance = attendance
	spec.spectator_spacing = spectator_spacing
	spec.spectator_inset_from_riser = spectator_inset_from_riser
	spec.spectator_yaw_jitter_deg = spectator_yaw_jitter_deg
	spec.spectator_y_jitter = spectator_y_jitter
	spec.home_fan_ratio = home_fan_ratio
	spec.away_fan_ratio = away_fan_ratio
	spec.secondary_color_ratio = secondary_color_ratio
	spec.team_cap_ratio = team_cap_ratio
	spec.home_color = home_color
	spec.home_color_secondary = home_color_secondary
	spec.away_color = away_color
	spec.away_color_secondary = away_color_secondary
	spec.seat_color = seat_color
	spec.seat_shade_variation = seat_shade_variation
	spec.banner_height = banner_height

	_spec = spec
	_path = ArenaBowlPath.new(spec)
	_rake = ArenaBowlRake.new(spec, _path)
	_deck = ArenaDeckMesh.new(spec, _path, _rake)
	_crowd = ArenaCrowd.new(spec, _path, _rake)
	_seating = ArenaSeating.new(spec, _path, _rake)
	_rinkside = ArenaRinkside.new(spec, _rake)
	_signage = ArenaSignage.new(spec, _path, _rake)


func _rebuild() -> void:
	if rink_length <= 0.0 or rink_width <= 0.0 or num_terraces <= 0:
		return
	_build_collaborators()
	# A prior _exit_tree (a reparent, say) may have latched the teardown guard;
	# clear it so a genuine later teardown still frees what this build creates.
	_render_targets_freed = false
	for child: Node in get_children():
		if child.name == _HOUSE_LIGHTS_NAME:
			continue   # survives rebuilds — see _ready
		child.queue_free()
	var layout: Dictionary = _get_or_build_layout()
	_deck.add_terraces(self, layout.terrace_mesh)
	_deck.add_shell(self, layout.shell_mesh)
	# Seats before spectators so the furniture is already there to sit in — and
	# so the opaque occupants draw over their own seat backs rather than the
	# other way round.
	if seats_enabled:
		_seating.attach(self, layout)
	_attach_spectators(layout)
	_deck.add_vomitory_tunnels(self)
	_rinkside.build_benches(self)
	_rinkside.build_penalty_boxes(self)
	_rinkside.build_staff(self)
	if ribbon_enabled:
		_signage.add_ribbon_board(self)
		# Editor previews hold still: a @tool node redrawing every frame for a
		# scrolling sign is churn the editor does not need.
		set_process(not Engine.is_editor_hint())
	if banners_enabled:
		_signage.add_rafter_banners(self)


# Attach the cached crowd MultiMeshes, repainting only if the colors/ratios
# moved since the layout was last painted. A rebuild with unchanged colors (e.g.
# re-entering a scene) reattaches without touching a single instance. The cache
# is this node's, so the decision to repaint is too — the crowd only paints.
func _attach_spectators(layout: Dictionary) -> void:
	var key: String = _spec.paint_key()
	if layout.paint_key != key:
		_crowd.paint(layout)
		layout.paint_key = key
	_crowd.attach(self, layout)


func _get_or_build_layout() -> Dictionary:
	var key: String = _spec.geometry_key()
	if _layout_cache.has(key):
		return _layout_cache[key]
	if _layout_cache.size() >= 4:
		_layout_cache.clear()
	var layout: Dictionary = {
		"terrace_mesh": _deck.build_terrace_mesh(),
		"shell_mesh": _deck.build_shell_mesh(),
		"paint_key": "",
	}
	_crowd.fill_layout(layout)
	_seating.fill_layout(layout)
	_layout_cache[key] = layout
	return layout


func _process(delta: float) -> void:
	if _signage != null:
		_signage.scroll_ribbon(delta, ribbon_scroll_speed)


# ── Crowd excitement ─────────────────────────────────────────────────────────

func _set_excitement(v: float) -> void:
	_excitement = v
	if _crowd != null:
		_crowd.set_excitement(v)


func _on_goal_scored(_team: Variant, _scorer: String, _a1: String, _a2: String) -> void:
	excite(1.0)


func _on_phase_changed(new_phase: int) -> void:
	if new_phase == GamePhase.Phase.END_OF_PERIOD or new_phase == GamePhase.Phase.GAME_OVER:
		excite(0.7)


# Big hits get a rumble out of the crowd, scaled by the same intensity curve
# the impact burst/sound use. Soft contact barely registers.
func _on_body_check_broadcast(force: float) -> void:
	excite(SkaterVFX.check_intensity(force) * 0.45)


# Pre-game buzz: the bowl comes alive under the opening camera sweep.
func _on_pregame_intro_started(duration: float) -> void:
	excite(0.55)
	if is_instance_valid(_house_lights):
		_house_lights.play_intro(duration)


func _on_faceoff_prep_announced() -> void:
	if is_instance_valid(_house_lights):
		_house_lights.restore()
