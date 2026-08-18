@tool
class_name ArenaStands
extends Node3D

# Procedural terraced stands wrapping the rink, plus a MultiMesh spectator
# crowd. Pattern mirrors HockeyRink — single rebuild on @export change, no
# runtime updates. Geometry is one ArrayMesh for all concrete (lower bowl +
# concourse walkway + upper-deck fascia and terraces), one for the arena
# shell wall, and the crowd as per-section MultiMesh pairs (bodies, heads)
# with a third MultiMesh per section for the seats they sit in: the bowl is
# split into _CROWD_SECTIONS angular slices, each with its own
# tight AABB, so the renderer frustum-culls off-screen crowd wholesale
# instead of vertex-processing every spectator every frame. The walkway /
# upper deck / shell exist so every camera sightline that clears the crowd
# lands on building rather than the bare background color — the bowl used to
# just end in the void.
#
# Seating sections: the bowl is divided into `num_aisles` seating sections by
# radial aisle gaps (stair corridors cleared of spectators), aligned across
# both decks via the shared base-path arc parameter (_base_path_s — the
# perpendicular projection onto the boards' perimeter, so aisles run straight
# up the rake like real stairways). A sub-1.0 `attendance` scatters empty
# seats through the rows, and one upper-deck section is the designated
# visiting-fan block — painted away-heavy so the bowl reads as a home crowd
# with a real away section rather than a uniform sea. (The angular render
# _CROWD_SECTIONS slices are unrelated: those exist purely for frustum
# culling and don't align with the seating sections.)

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
# long bank of seats. At the 1.1 m it shipped with, the upper deck began a step
# above the walkway: geometrically a concourse, visually a continuation. A real
# second tier is cantilevered a storey up, so the level under it is a room you
# could stand in — and that headroom is also what the lower bowl's portals need
# somewhere to be.
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
# designated upper-deck visiting section (see _away_section_id).
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
# Seats are furniture: one per seating position, occupied or not, which is the
# whole point — a bowl at 0.93 attendance shows bare concrete in the empty spots
# and in the 0.27 m of daylight between neighbours at the shipping spacing.
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

# Deterministic seed so the editor preview matches the runtime build.
const _SEED: int = 31337
# Angular crowd slices (see _fill_spectator_layout). 8 ≈ 45° per slice: tight
# enough that gameplay zoom keeps only a few slices in frustum, few enough
# that the extra draw calls (2 per slice) stay negligible.
const _CROWD_SECTIONS: int = 8
# Crowd animation (Shaders/crowd.gdshader): how long a burst of excitement
# holds at peak and how long it takes to settle back to the idle murmur sway.
const _CROWD_SHADER_PATH: String = "res://Shaders/crowd.gdshader"
const _EXCITE_RISE_TIME: float = 0.25
const _EXCITE_HOLD_TIME: float = 3.5
const _EXCITE_DECAY_TIME: float = 3.0
# Player benches: two team benches on the +X side straddling center ice,
# carved out of the first rows of crowd. 3v3 fields no reserves, so they're
# empty furniture — the break in the crowd wall is what sells the rink.
# The span is public because HockeyRink has to know it too: the stretch of board
# a bench sits behind is a gate and a doorway, not somewhere an ad can go.
const BENCH_CENTER_Z: float = 4.4    # bench centers at ±this along the boards
const BENCH_HALF_LEN: float = 3.0    # half-length of each bench along Z
const _BENCH_CLEAR_ROWS: int = 2      # spectator rows cleared behind the glass
const _BENCH_CLEAR_MARGIN: float = 0.3
const _BENCH_SEAT_X_OFFSET: float = 0.33  # seat center outward of the first tread's inner edge
const _BENCH_SEAT_HEIGHT: float = 0.46
# Penalty boxes and the off-ice officials between them, on the −X boards
# opposite the player benches — which is where a real rink puts them, and which
# is also the only stretch of this bowl that was an unbroken run of crowd. Two
# boxes flank centre ice with the timekeeper's table in the gap, so the whole
# assembly spans |z| < PENALTY_BOX_CENTER_Z + PENALTY_BOX_HALF_LEN.
const PENALTY_BOX_CENTER_Z: float = 2.9
const PENALTY_BOX_HALF_LEN: float = 1.7
const _OFFICIALS_HALF_LEN: float = 1.0
const _OFFICIALS_HEIGHT: float = 0.78
# Staff: the people the rinkside furniture was built for. Coaches stand behind
# each bench; the timekeeping crew and the penalty-box attendants sit at theirs,
# which is how a real rink works — the bench is the only post nobody works from a
# chair. They are the crowd's own body and head boxes, standing ones stood up per
# the stature block, but on a plain material rather than the crowd shader,
# because a coach does not do the wave.
const _STAFF_SEED: int = 5150
# Outward of the furniture they work behind, so they read as standing at it.
const _STAFF_BEHIND_BENCH: float = 0.92
const _STAFF_BEHIND_TABLE: float = 0.88
# Spacing the shell wall is resampled at before its openings are cut. Well under
# the narrowest portal, so an opening always spans several segments.
const _VOMITORY_SAMPLE_M: float = 0.25
# Spectator body dimensions — stacked boxes matching the skater art style.
const _BODY_SIZE: Vector3 = Vector3(0.28, 0.45, 0.28)
const _HEAD_SIZE: Vector3 = Vector3(0.22, 0.22, 0.22)
# Tiny lift to keep the body bottom face off the tread without a visible gap.
# Without it the two co-planar surfaces z-fight; without keeping the bottom
# face at all, back-row spectators look hollow when the camera ends up below
# their row (upper-bowl rows reach ~6 m, well above typical camera height).
const _BODY_Y_LIFT: float = 0.002

# ── Stature ──────────────────────────────────────────────────────────────────
# One unscaled figure stands 0.692 m from the tread to the crown of its head.
# That is not a person: these spectators sit with their base ON the tread rather
# than on a raised pan, so their whole height IS sitting height, and a real adult
# sitting height runs about 0.79 m to 0.97 m.
#
# Every stature below is divided by this to get a scale factor, so the figures
# are sized by anthropometry in one place instead of by eye in several.
const _FIGURE_HEIGHT: float = _BODY_Y_LIFT + _BODY_SIZE.y + 0.02 + _HEAD_SIZE.y
# Roughly 5th-percentile female to 95th-percentile male. Rolled per spectator, so
# a row is a mix of statures rather than a line of identical boxes — which reads
# as a crowd of people at a glance, where a uniform one reads as a texture.
const _SEATED_STATURE_MIN: float = 0.80
const _SEATED_STATURE_MAX: float = 0.96
const _CROWD_SCALE_MAX: float = _SEATED_STATURE_MAX / _FIGURE_HEIGHT
# The rinkside staff are the same population on their feet — the same percentiles
# read off the standing column of the same tables.
const _STANDING_STATURE_MIN: float = 1.52
const _STANDING_STATURE_MAX: float = 1.88
# Sitting height is about 52% of stature in adults, and that ratio is the entire
# bridge between the two populations. Standing widens nobody — it unfolds legs the
# seated figure has no geometry for — so a staffer is sized ACROSS by the seated
# scale of a person their height (`stature * this / _FIGURE_HEIGHT`) and lifted by
# the remaining 48%, which is their hip height. Scaling the whole figure uniformly
# to standing stature instead is what makes a coach read as a giant beside the
# crowd: at 1.75 m the body box comes out 0.71 m across under a half-metre head,
# both about double a spectator's, because a box that is a seated torso ends up
# standing in for torso AND legs.
const _SITTING_HEIGHT_FRACTION: float = 0.52

# Seat furniture: a pan on the tread and a backrest behind it, in the seated
# spectator's own local frame (local −Z faces the rink, so +Z is outward).
#
# Every number here is bounded by something already fixed, and the body it has
# to clear is the LARGEST stature roll — 0.39 m across and deep, not the mesh's
# nominal 0.28 m. The seat is wider than that so it shows either side of an
# occupant, and narrower than the 0.55 m spacing so neighbours don't merge into a
# bench. The pan reaches 0.17 m forward — the spectator sits 0.18 m outward of
# the tread's inner edge, so a deeper pan would hang over the drop. The backrest
# starts at 0.205 m, clearing that body's 0.195 m back face, and ends at 0.255 m,
# short of the next riser 0.42 m out. It stands 0.38 m against a seated occupant
# of 0.80–0.96 m, so shoulders and head clear the top of the seat.
const _SEAT_WIDTH: float = 0.46
const _SEAT_PAN_DEPTH: float = 0.34
const _SEAT_PAN_THICKNESS: float = 0.05
const _SEAT_BACK_HEIGHT: float = 0.38
const _SEAT_BACK_THICKNESS: float = 0.05
# Nudged back from 0.20 once spectators grew: the tallest stature roll is also
# the deepest body, and at 0.20 the backrest passed through it.
const _SEAT_BACK_OFFSET: float = 0.23
# Same trick as _BODY_Y_LIFT, for the same reason: the pan's underside would
# otherwise be coplanar with the tread it rests on.
const _SEAT_Y_LIFT: float = 0.002
# Seats roll their shade from their own stream. Sharing the crowd's would tie
# the two together — a change to seat jitter would repaint every spectator.
const _SEAT_SEED: int = 90210

# ── Ribbon board ─────────────────────────────────────────────────────────────
# The LED strip on the upper deck's fascia — the wall the lower bowl's back rows
# sit against, which is where a real arena puts one and which is otherwise a
# blank band of concrete right in the eyeline of every high camera.
const _RIBBON_HEIGHT: float = 0.55
# Stood this far proud of the fascia so the two faces are never coplanar.
const _RIBBON_INSET: float = 0.02
# Whole number of repeats around the bowl, and it must stay whole: the strip
# wraps in U, so a fractional count would put a hard seam where the band closes.
const _RIBBON_REPEATS: int = 3
# Gap between the strip and the upper deck's lip above it. The board hangs from
# the TOP of the fascia rather than the middle of it — that is where a real one
# goes, and on a fascia tall enough to be a storey it also leaves the lower half
# of the wall free for the concourse portals.
const _RIBBON_FASCIA_MARGIN: float = 0.25

# ── Rafter banners ───────────────────────────────────────────────────────────
# Hung inboard of the shell wall so they read as suspended over the bowl rather
# than as signs bolted to it, and high enough that the top deck's back row is
# well below them.
const _BANNER_INBOARD: float = 2.0
# Where the banners' top edge sits in the shell's height, as a fraction. Leaves
# the roof space above them dark, which is the whole reason they read as hanging
# from something rather than floating.
const _BANNER_TOP_FRACTION: float = 0.86
# Gap between a banner's two printed faces. Cloth is thinner than this; the
# number is set by depth precision at 30 m, not by upholstery.
const _BANNER_THICKNESS: float = 0.02
# How many times the registry goes round the ring. There are only a handful of
# banners and the ring is ~250 m, so hanging one of each would leave 60 m of
# empty roof between them and most cameras seeing none. Repeating puts a banner
# in view from anywhere without the roof becoming a wall of duplicates.
const _BANNER_RING_REPEATS: int = 2

# Civilian shirts/coats for the neutral fan slice.
var _neutral_body_palette: Array[Color] = [
	Color(0.25, 0.25, 0.28),  # charcoal
	Color(0.55, 0.45, 0.35),  # khaki
	Color(0.78, 0.74, 0.70),  # cream
	Color(0.40, 0.36, 0.32),  # taupe
	Color(0.92, 0.88, 0.85),  # off-white
	Color(0.35, 0.40, 0.45),  # slate
	Color(0.62, 0.30, 0.20),  # rust
]
# Skin tones + hat colors used for the head MultiMesh. Independent of body
# color (no team correlation) so the bowl reads as a sea of people, not a
# wall of identical avatars.
var _head_palette: Array[Color] = [
	Color(0.94, 0.82, 0.70),  # light skin
	Color(0.85, 0.69, 0.55),  # medium-light skin
	Color(0.72, 0.55, 0.42),  # medium skin
	Color(0.55, 0.40, 0.30),  # tan
	Color(0.40, 0.28, 0.22),  # dark skin
	Color(0.12, 0.10, 0.10),  # black hair / dark cap
	Color(0.32, 0.22, 0.16),  # brown hair
	Color(0.78, 0.74, 0.68),  # grey hair / pale cap
]


# Shared by both crowd MultiMeshes and — static — across arena instances:
# the cached body/head meshes embed this material, so it must be the same
# object for every ArenaStands the process ever builds, or excitement writes
# from a fresh arena would land on a dead material.
static var _crowd_material: ShaderMaterial = null
var _excitement: float = 0.0
var _excite_tween: Tween = null
# Rebuilt with the spectators (a rebuild frees all children), so guard reads
# with is_instance_valid during the free→re-add window.
var _flashbulbs: CrowdFlashbulbs = null
# Set while set_crowd_rows writes both row counts, so the two setters don't
# each trigger a rebuild of their own.
var _suspend_rebuild: bool = false
# Ribbon board: the strip SubViewport and the material holding its texture, kept
# so exit teardown can drop the binding before the RenderingServer finalizes,
# plus the world span of one repeat, which converts the scroll from m/s to UV/s.
var _ribbon_vp: SubViewport = null
var _ribbon_material: StandardMaterial3D = null
var _ribbon_span_m: float = 0.0
# Rafter banners: same story, one atlas viewport for the whole roof.
var _banner_vp: SubViewport = null
var _banner_material: StandardMaterial3D = null
# The ceiling rig's housings and its intro cue. Outlives rebuilds (see _ready).
const _HOUSE_LIGHTS_NAME: StringName = &"ArenaHouseLights"
var _house_lights: ArenaHouseLights = null
var _render_targets_freed: bool = false

# geometry key → layout dict {terrace_mesh, shell_mesh, body/head/seat mms,
# away_flags, paint_key}.
# Everything in a layout is color-independent and deterministic (fixed
# _SEED), so it's built once per geometry-param set and reused for the
# process lifetime — a scene change's rebuild (free play → lobby → game)
# becomes at most a crowd repaint, and a same-colors rebuild skips even
# that. Bounded by clearing on editor param churn (steady state is one
# entry per crowd-density level).
static var _layout_cache: Dictionary = {}


# Drop the process-lifetime crowd caches. The static _crowd_material
# (ShaderMaterial) and _layout_cache (terrace mesh + body/head MultiMeshes) hold
# GPU RIDs that survive scene changes for perf. A static var is freed at
# script-unload — AFTER the RenderingServer finalizes — so at exit these
# destruct with a null RenderingServer and their RIDs are reported as leaked.
# Clearing them here, from a real-shutdown hook (GameManager), drops the last
# reference while the server is still alive. Only call at app quit.
static func release_shared_cache() -> void:
	_crowd_material = null
	_layout_cache.clear()


# Release the ribbon strip's render target and its material binding before Godot
# finalizes the RenderingServer on quit — same contract, and same reasoning, as
# HockeyRink._teardown_render_targets and Jumbotron._teardown_viewport: a
# ViewportTexture still bound at exit takes its viewport and that viewport's
# canvas and text-shaping RIDs down after the server, which reports them leaked.
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
	if _ribbon_material != null:
		_ribbon_material.albedo_texture = null
	_ribbon_material = null
	if is_instance_valid(_ribbon_vp):
		_ribbon_vp.free()
	_ribbon_vp = null
	if _banner_material != null:
		_banner_material.albedo_texture = null
	_banner_material = null
	if is_instance_valid(_banner_vp):
		_banner_vp.free()
	_banner_vp = null


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
	# The crowd material is static (see its doc): a bowl mid-celebration when
	# the scene changed would otherwise carry its excitement into the fresh
	# arena. New bowls start at the idle murmur.
	_set_excitement(0.0)
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


func _rebuild() -> void:
	if rink_length <= 0.0 or rink_width <= 0.0 or num_terraces <= 0:
		return
	# A prior _exit_tree (a reparent, say) may have latched the teardown guard;
	# clear it so a genuine later teardown still frees what this build creates.
	_render_targets_freed = false
	_ribbon_material = null
	_banner_material = null
	for child: Node in get_children():
		if child.name == _HOUSE_LIGHTS_NAME:
			continue   # survives rebuilds — see _ready
		child.queue_free()
	var layout: Dictionary = _get_or_build_layout()
	_add_terraces(layout.terrace_mesh)
	_add_shell(layout.shell_mesh)
	# Seats before spectators so the furniture is already there to sit in — and
	# so the opaque occupants draw over their own seat backs rather than the
	# other way round.
	if seats_enabled:
		_add_seats(layout)
	_add_spectators(layout)
	_add_vomitory_tunnels()
	_build_benches()
	_build_penalty_boxes()
	_build_staff()
	if ribbon_enabled:
		_add_ribbon_board()
	if banners_enabled:
		_add_rafter_banners()


# ── Layout cache ─────────────────────────────────────────────────────────────

# Every param that moves geometry, transforms, or the AABB. The team colors and
# fan ratios are deliberately absent — they only repaint, and so is `seat_color`,
# which lives on the seat material. `seat_shade_variation` IS here, because it is
# rolled into per-instance colors baked into the cached MultiMeshes rather than
# applied at instancing time.
func _geometry_key() -> String:
	return str([rink_length, rink_width, corner_radius, stands_base_y,
			num_terraces, tread_depth, riser_height, base_outward_offset,
			corner_segments, spectator_spacing, spectator_inset_from_riser,
			spectator_yaw_jitter_deg, spectator_y_jitter,
			walkway_depth, upper_terraces, upper_riser_height, upper_deck_rise,
			shell_height, num_aisles, aisle_width, attendance,
			seat_shade_variation,
			# The shell mesh is cached, and these cut holes in it.
			vomitories_enabled, vomitory_width, vomitory_height])


# Everything the paint pass reads: the four team colors + the mix ratios.
func _paint_key() -> String:
	return str([home_color, home_color_secondary, away_color,
			away_color_secondary, home_fan_ratio, away_fan_ratio,
			secondary_color_ratio, team_cap_ratio])


func _get_or_build_layout() -> Dictionary:
	var key: String = _geometry_key()
	if _layout_cache.has(key):
		return _layout_cache[key]
	if _layout_cache.size() >= 4:
		_layout_cache.clear()
	var layout: Dictionary = {
		"terrace_mesh": _build_terrace_mesh(),
		"shell_mesh": _build_shell_mesh(),
		"paint_key": "",
	}
	_fill_spectator_layout(layout)
	_fill_seat_layout(layout)
	_layout_cache[key] = layout
	return layout


# ── Terrace geometry ─────────────────────────────────────────────────────────

func _build_terrace_mesh() -> ArrayMesh:
	# Compute step counts ONCE based on the base path (no offset). All rings
	# share the same sample count so tread quads stay aligned between the
	# inner and outer perimeter of each terrace.
	var counts: Vector2i = _path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	for i: int in num_terraces:
		var inner_off: float = base_outward_offset + i * tread_depth
		var outer_off: float = inner_off + tread_depth
		var y_top: float = stands_base_y + i * riser_height
		var y_bot: float = y_top - riser_height
		var inner_pts: PackedVector2Array = _sample_offset_path(inner_off, counts.x, counts.y)
		var outer_pts: PackedVector2Array = _sample_offset_path(outer_off, counts.x, counts.y)
		_emit_tread(st, inner_pts, outer_pts, y_top)
		_emit_riser(st, inner_pts, y_bot, y_top)
	# Concourse walkway: the top tread's level continues outward as a flat ring
	# to the upper-deck fascia (or the shell wall when the deck is disabled).
	if walkway_depth > 0.0:
		var walk_in: float = base_outward_offset + num_terraces * tread_depth
		_emit_tread(st,
				_sample_offset_path(walk_in, counts.x, counts.y),
				_sample_offset_path(walk_in + walkway_depth, counts.x, counts.y),
				_lower_top_tread_y())
	# Upper-deck fascia (balcony front): one tall riser spanning the whole
	# walkway → first-tread rise. Concrete like the terraces — it's the same
	# poured structure. Row 0 below emits no riser of its own, since a
	# duplicate co-planar wall here would z-fight this one.
	if upper_terraces > 0:
		var fascia_head: float = _fascia_portal_head()
		if fascia_head > _lower_top_tread_y():
			# Portals through to the concourse, at the head of every lower-bowl
			# stairway. Same treatment as the shell wall: resampled fine enough
			# that an opening always spans several segments, cut below, solid
			# above.
			var fine: PackedVector2Array = _resample_uniform(
					_sample_offset_path(_upper_deck_inner_offset()), _VOMITORY_SAMPLE_M)
			_emit_riser_gapped(st, fine, _lower_top_tread_y(), fascia_head)
			_emit_riser(st, fine, fascia_head, _upper_deck_base_y())
		else:
			_emit_riser(st,
					_sample_offset_path(_upper_deck_inner_offset(), counts.x, counts.y),
					_lower_top_tread_y(), _upper_deck_base_y())
	for j: int in upper_terraces:
		var inner_off: float = _upper_deck_inner_offset() + j * tread_depth
		var outer_off: float = inner_off + tread_depth
		var y_top: float = _upper_deck_base_y() + j * upper_riser_height
		var inner_pts: PackedVector2Array = _sample_offset_path(inner_off, counts.x, counts.y)
		var outer_pts: PackedVector2Array = _sample_offset_path(outer_off, counts.x, counts.y)
		_emit_tread(st, inner_pts, outer_pts, y_top)
		if j > 0:
			_emit_riser(st, inner_pts, y_top - upper_riser_height, y_top)
	st.generate_normals()
	return st.commit()


# ── Derived deck geometry ────────────────────────────────────────────────────

# Tread height of the lower bowl's back row — also the walkway level.
func _lower_top_tread_y() -> float:
	return stands_base_y + (num_terraces - 1) * riser_height


# Outward offset of the upper deck's first row (= the fascia ring).
func _upper_deck_inner_offset() -> float:
	return base_outward_offset + num_terraces * tread_depth + walkway_depth


# Tread height of the upper deck's first row (= the fascia top).
func _upper_deck_base_y() -> float:
	return _lower_top_tread_y() + upper_deck_rise


# Outward offset of the shell wall: behind the upper deck's back row, or
# straight behind the walkway when the deck is disabled.
func _shell_offset() -> float:
	return _upper_deck_inner_offset() + upper_terraces * tread_depth


# Tread height of the very back spectator row, whichever deck that is on.
func _top_tread_y() -> float:
	if upper_terraces > 0:
		return _upper_deck_base_y() + (upper_terraces - 1) * upper_riser_height
	return _lower_top_tread_y()


# Perimeter shell wall, its own mesh with the dark shell material. Split from
# the terrace mesh so the two can be colored independently without vertex
# colors or a second surface.
func _build_shell_mesh() -> ArrayMesh:
	var counts: Vector2i = _path_step_counts()
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	if shell_height > 0.0:
		var base_y: float = _top_tread_y()
		var top_y: float = base_y + shell_height
		var wall_pts: PackedVector2Array = _sample_offset_path(
				_shell_offset(), counts.x, counts.y)
		if _vomitories_wanted():
			# The wall is resampled at a fixed spacing before the openings are
			# cut. Its own sampling is geometric — the corners get
			# `corner_segments` steps regardless of how far out the shell sits,
			# which at this radius stretches them to ~3 m — and an opening barely
			# wider than that would fall between two samples and never appear.
			var fine: PackedVector2Array = _resample_uniform(wall_pts, _VOMITORY_SAMPLE_M)
			var head_y: float = minf(base_y + vomitory_height, top_y)
			_emit_riser_gapped(st, fine, base_y, head_y)
			_emit_riser(st, fine, head_y, top_y)
		else:
			_emit_riser(st, wall_pts, base_y, top_y)
	st.generate_normals()
	return st.commit()


# Top of the lower bowl's portals. They share the fascia with the ribbon board,
# which hangs under the upper deck's lip, so the lintel stops clear of it. A
# fascia too short for both (a shallow `upper_deck_rise`) yields the wall to the
# ribbon and gets no portals — the caller checks for that by comparing this
# against the walkway height.
func _fascia_portal_head() -> float:
	if not _vomitories_wanted():
		return -INF
	return minf(_lower_top_tread_y() + vomitory_height,
			_upper_deck_base_y() - _RIBBON_HEIGHT - _RIBBON_FASCIA_MARGIN * 2.0)


func _vomitories_wanted() -> bool:
	return vomitories_enabled and num_aisles > 0 and vomitory_width > 0.0 \
			and vomitory_height > 0.0


# True where the shell wall is a doorway rather than a wall. Shares the aisles'
# spacing so a portal lands at the head of every stairway, but takes its own
# width — a vomitory is wider than the steps that feed it.
func _in_vomitory(s: float) -> bool:
	if not _vomitories_wanted():
		return false
	var seg: float = _base_path_length() / float(num_aisles)
	var into: float = fposmod(s, seg)
	return minf(into, seg - into) < vomitory_width * 0.5


# _emit_riser, minus the segments that fall in a doorway.
func _emit_riser_gapped(st: SurfaceTool, inner: PackedVector2Array,
		y_bot: float, y_top: float) -> void:
	var n: int = inner.size()
	var cut: PackedByteArray = _shell_cut_flags(inner)
	for i: int in n:
		var j: int = (i + 1) % n
		if cut[i] == 1:
			continue
		var ba := Vector3(inner[i].x, y_bot, inner[i].y)
		var ta := Vector3(inner[i].x, y_top, inner[i].y)
		var bb := Vector3(inner[j].x, y_bot, inner[j].y)
		var tb := Vector3(inner[j].x, y_top, inner[j].y)
		st.add_vertex(ba)
		st.add_vertex(bb)
		st.add_vertex(tb)
		st.add_vertex(ba)
		st.add_vertex(tb)
		st.add_vertex(ta)


# Shell color lives on a per-instance material_override (same pattern as the
# terraces' concrete) so a color tweak repaints without a layout rebuild.
func _add_shell(mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = shell_color
	mat.roughness = 1.0
	# Same winding contract as the terraces: the wall's front faces the bowl
	# interior, so cull the never-visible outward side.
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mi.material_override = mat
	# The wall is beyond every shadow-casting spotlight's range; skip it in the
	# shadow maps like the crowd.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.name = "Shell"
	add_child(mi)


# Concrete color lives on a per-instance material_override, not in the cached
# mesh, so a concrete_color tweak repaints without invalidating the layout.
func _add_terraces(mesh: ArrayMesh) -> void:
	var mi: MeshInstance3D = MeshInstance3D.new()
	mi.mesh = mesh
	var mat: StandardMaterial3D = StandardMaterial3D.new()
	mat.albedo_color = concrete_color
	mat.roughness = 0.95
	# Every face is wound front-toward-the-bowl-interior (treads up, risers /
	# fascia rinkward), and the under-tread volumes are sealed by the riser
	# below, so back-face culling drops only never-visible geometry. Caveat: a
	# free-cam flight OUTSIDE the arena sees through the bowl's outer side —
	# acceptable for a dev/spectator edge case.
	mat.cull_mode = BaseMaterial3D.CULL_BACK
	mi.material_override = mat
	mi.name = "Terraces"
	add_child(mi)


# Tread: horizontal quad strip between inner and outer perimeter rings.
func _emit_tread(st: SurfaceTool, inner: PackedVector2Array, outer: PackedVector2Array, y: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		var j: int = (i + 1) % n
		var ia: Vector3 = Vector3(inner[i].x, y, inner[i].y)
		var oa: Vector3 = Vector3(outer[i].x, y, outer[i].y)
		var ib: Vector3 = Vector3(inner[j].x, y, inner[j].y)
		var ob: Vector3 = Vector3(outer[j].x, y, outer[j].y)
		# CCW from above so normals point +Y.
		st.add_vertex(ia)
		st.add_vertex(ib)
		st.add_vertex(ob)
		st.add_vertex(ia)
		st.add_vertex(ob)
		st.add_vertex(oa)


# Riser: vertical wall along the inner perimeter, facing toward the rink.
func _emit_riser(st: SurfaceTool, inner: PackedVector2Array, y_bot: float, y_top: float) -> void:
	var n: int = inner.size()
	for i: int in n:
		var j: int = (i + 1) % n
		var ba: Vector3 = Vector3(inner[i].x, y_bot, inner[i].y)
		var ta: Vector3 = Vector3(inner[i].x, y_top, inner[i].y)
		var bb: Vector3 = Vector3(inner[j].x, y_bot, inner[j].y)
		var tb: Vector3 = Vector3(inner[j].x, y_top, inner[j].y)
		# Wind so the wall's front face points toward the rink interior —
		# load-bearing now that the terrace/shell materials cull back faces.
		# (The mirror image of this winding fronts outward and gets culled from
		# every in-bowl camera, which hid all the risers, the fascia, and the
		# shell wall behind them.)
		st.add_vertex(ba)
		st.add_vertex(bb)
		st.add_vertex(tb)
		st.add_vertex(ba)
		st.add_vertex(tb)
		st.add_vertex(ta)


# Compute the (straight-X, straight-Z) sample counts, derived once from the
# base path so every ring shares the same vertex count regardless of offset.
func _path_step_counts() -> Vector2i:
	var arc_step_base: float = (PI / 2.0) * corner_radius / float(corner_segments)
	var straight_x: float = rink_width - 2.0 * corner_radius
	var straight_z: float = rink_length - 2.0 * corner_radius
	var nx: int = max(1, int(round(straight_x / arc_step_base)))
	var nz: int = max(1, int(round(straight_z / arc_step_base)))
	return Vector2i(nx, nz)


# Sample a rounded-rectangle path offset outward from the board outer face
# by `off` meters, using fixed step counts so rings stay vertex-aligned.
# Returns XZ points in CCW order (viewed from above with +X right, +Z up).
func _sample_offset_path(off: float, n_straight_x: int = -1, n_straight_z: int = -1) -> PackedVector2Array:
	var half_w: float = rink_width / 2.0
	var half_l: float = rink_length / 2.0
	var r: float = corner_radius
	var r_off: float = r + off
	# Corner arc centers (same as rink corner centers).
	var c_br: Vector2 = Vector2( half_w - r, -half_l + r)
	var c_tr: Vector2 = Vector2( half_w - r,  half_l - r)
	var c_tl: Vector2 = Vector2(-half_w + r,  half_l - r)
	var c_bl: Vector2 = Vector2(-half_w + r, -half_l + r)
	if n_straight_x < 0 or n_straight_z < 0:
		var counts: Vector2i = _path_step_counts()
		n_straight_x = counts.x
		n_straight_z = counts.y

	var pts: PackedVector2Array = PackedVector2Array()
	# Order, CCW from above: bottom edge → bottom-left corner → left edge →
	# top-left corner → top edge → top-right corner → right edge → bottom-right corner.
	_append_straight(pts,
			Vector2( half_w - r, -half_l - off),
			Vector2(-half_w + r, -half_l - off), n_straight_x)
	_append_arc(pts, c_bl, r_off, -PI / 2.0, -PI, corner_segments)
	_append_straight(pts,
			Vector2(-half_w - off, -half_l + r),
			Vector2(-half_w - off,  half_l - r), n_straight_z)
	_append_arc(pts, c_tl, r_off, PI, PI / 2.0, corner_segments)
	_append_straight(pts,
			Vector2(-half_w + r, half_l + off),
			Vector2( half_w - r, half_l + off), n_straight_x)
	_append_arc(pts, c_tr, r_off, PI / 2.0, 0.0, corner_segments)
	_append_straight(pts,
			Vector2(half_w + off,  half_l - r),
			Vector2(half_w + off, -half_l + r), n_straight_z)
	_append_arc(pts, c_br, r_off, 0.0, -PI / 2.0, corner_segments)
	return pts


# Append straight segment samples [start, ..., end) — endpoint omitted so
# the next segment's start point is not duplicated.
func _append_straight(pts: PackedVector2Array, start: Vector2, end: Vector2, steps: int) -> void:
	for i: int in steps:
		var t: float = float(i) / float(steps)
		pts.append(start.lerp(end, t))


# Append arc samples sweeping from a0 to a1 across `segments` steps.
# Endpoint omitted (matches _append_straight convention).
func _append_arc(pts: PackedVector2Array, center: Vector2, radius: float,
		a0: float, a1: float, segments: int) -> void:
	for i: int in segments:
		var t: float = float(i) / float(segments)
		var ang: float = lerp(a0, a1, t)
		pts.append(center + Vector2(cos(ang), sin(ang)) * radius)


# ── Seating sections ─────────────────────────────────────────────────────────
# All section math runs on the BASE path's arc-length parameter: every seat
# projects perpendicularly onto the boards' rounded-rect perimeter (straights
# → perpendicular foot, corners → same angle on the base corner arc), so
# seats stacked up the rake share one s value regardless of row offset. Aisles
# are cuts at fixed s — that's what makes them radial and deck-aligned.

# Arc length of the base (off = 0) path, in the sampler's traversal order.
func _base_path_length() -> float:
	return 2.0 * (rink_width - 2.0 * corner_radius) \
			+ 2.0 * (rink_length - 2.0 * corner_radius) \
			+ TAU * corner_radius


# Arc position s ∈ [0, _base_path_length()) of a seat's perpendicular
# projection onto the base path. p is (x, z), same packing as the samplers.
# Segment order and directions mirror _sample_offset_path exactly.
func _base_path_s(p: Vector2) -> float:
	var cx_max: float = rink_width / 2.0 - corner_radius
	var cz_max: float = rink_length / 2.0 - corner_radius
	var len_x: float = 2.0 * cx_max
	var len_z: float = 2.0 * cz_max
	var len_c: float = (PI / 2.0) * corner_radius
	var x: float = p.x
	var z: float = p.y
	if absf(x) <= cx_max:
		# Short-end straights (behind the goals).
		if z < 0.0:
			return cx_max - x  # bottom edge: +x → −x
		return len_x + 2.0 * len_c + len_z + (x + cx_max)  # top edge: −x → +x
	if absf(z) <= cz_max:
		# Long-side straights.
		if x < 0.0:
			return len_x + len_c + (z + cz_max)  # left edge: −z → +z
		return 2.0 * len_x + 3.0 * len_c + len_z + (cz_max - z)  # right: +z → −z
	# Corner fans: angular progress along the quarter arc, in sweep order.
	var ang: float = atan2(z - signf(z) * cz_max, x - signf(x) * cx_max)
	var progress: float
	var s0: float
	if x < 0.0 and z < 0.0:
		progress = (-PI / 2.0 - ang) / (PI / 2.0)  # −π/2 → −π
		s0 = len_x
	elif x < 0.0:
		progress = (PI - ang) / (PI / 2.0)  # π → π/2
		s0 = len_x + len_c + len_z
	elif z > 0.0:
		progress = (PI / 2.0 - ang) / (PI / 2.0)  # π/2 → 0
		s0 = 2.0 * len_x + 2.0 * len_c + len_z
	else:
		progress = -ang / (PI / 2.0)  # 0 → −π/2
		s0 = 2.0 * len_x + 3.0 * len_c + 2.0 * len_z
	return s0 + clampf(progress, 0.0, 1.0) * len_c


# Whether an arc position falls inside a cleared aisle corridor. Aisles sit
# at the section boundaries k · (perimeter / num_aisles).
func _in_aisle(s: float) -> bool:
	if num_aisles <= 0 or aisle_width <= 0.0:
		return false
	var seg: float = _base_path_length() / float(num_aisles)
	var into: float = fposmod(s, seg)
	return minf(into, seg - into) < aisle_width * 0.5


func _section_id(s: float) -> int:
	if num_aisles <= 0:
		return 0
	var seg: float = _base_path_length() / float(num_aisles)
	return clampi(int(s / seg), 0, num_aisles - 1)


# The visiting-fan block: the upper-deck section containing the top-left
# corner's midpoint — an upper corner on the −X side, opposite the benches,
# where real arenas park the away support.
func _away_section_id() -> int:
	if num_aisles <= 0:
		return -1
	var len_x: float = rink_width - 2.0 * corner_radius
	var len_z: float = rink_length - 2.0 * corner_radius
	var len_c: float = (PI / 2.0) * corner_radius
	return _section_id(len_x + len_c + len_z + len_c * 0.5)


# ── Spectator MultiMesh ──────────────────────────────────────────────────────

# Build the color-independent half of the crowd into `layout`: per-section
# MultiMesh pairs with meshes, transforms, anim data, and AABBs. Each section
# is a pair because bodies tint with the team-mix color while heads tint from
# the skin/hat palette — an extra draw call vs. a combined mesh, but it lets
# the head pick a color independent of the body without a custom shader.
# Colors stay default until the first _paint_spectators pass (a fresh
# layout's paint_key is "").
func _fill_spectator_layout(layout: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var anim_data: Array[Color] = []
	var away_block: PackedByteArray = PackedByteArray()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for i: int in num_terraces:
		# Spectators sit on the tread, inset slightly outward from the inner
		# (rink-facing) edge so their feet aren't on the riser corner.
		_append_spectator_row(transforms, anim_data, away_block, rng,
				base_outward_offset + i * tread_depth + spectator_inset_from_riser,
				stands_base_y + i * riser_height, i, false)
	# Upper deck rows. bench_row -1: the bench cutout is an ice-level concern
	# only — the deck hangs far above the benches.
	for j: int in upper_terraces:
		_append_spectator_row(transforms, anim_data, away_block, rng,
				_upper_deck_inner_offset() + j * tread_depth + spectator_inset_from_riser,
				_upper_deck_base_y() + j * upper_riser_height, -1, true)

	# Partition the bowl into angular slices around center ice, one MultiMesh
	# pair per slice with a tight custom AABB. A single whole-bowl MultiMesh
	# would put every spectator through the vertex stage every frame (its AABB
	# overlaps any conceivable frustum); per-section AABBs let the renderer
	# frustum-cull the off-screen slices wholesale, which is most of the crowd
	# at gameplay zoom. Section order is deterministic (angle bins over the
	# deterministic transform list), so the paint pass stays reproducible.
	var body_mesh: ArrayMesh = _build_body_mesh()
	var head_mesh: ArrayMesh = _build_head_mesh()
	var section_indices: Array[PackedInt32Array] = []
	section_indices.resize(_CROWD_SECTIONS)
	for k: int in _CROWD_SECTIONS:
		section_indices[k] = PackedInt32Array()
	for i: int in transforms.size():
		var o: Vector3 = transforms[i].origin
		var sector: int = int(floor((atan2(o.z, o.x) + PI) / TAU * _CROWD_SECTIONS))
		section_indices[clampi(sector, 0, _CROWD_SECTIONS - 1)].append(i)

	var body_mms: Array[MultiMesh] = []
	var head_mms: Array[MultiMesh] = []
	var away_flags: Array[PackedByteArray] = []
	for k: int in _CROWD_SECTIONS:
		var idxs: PackedInt32Array = section_indices[k]
		if idxs.is_empty():
			continue
		var body_mm: MultiMesh = _make_crowd_multimesh(body_mesh, idxs.size())
		var head_mm: MultiMesh = _make_crowd_multimesh(head_mesh, idxs.size())
		var slice_away: PackedByteArray = PackedByteArray()
		slice_away.resize(idxs.size())
		var seed_aabb: AABB = AABB(transforms[idxs[0]].origin, Vector3.ZERO)
		for n_i: int in idxs.size():
			var src: int = idxs[n_i]
			body_mm.set_instance_transform(n_i, transforms[src])
			body_mm.set_instance_custom_data(n_i, anim_data[src])
			head_mm.set_instance_transform(n_i, transforms[src])
			head_mm.set_instance_custom_data(n_i, anim_data[src])
			slice_away[n_i] = away_block[src]
			seed_aabb = seed_aabb.expand(transforms[src].origin)
		# Godot's auto-AABB for MultiMesh is unreliable when transforms are
		# pushed via set_instance_transform individually (vs. a single `buffer`
		# set), and especially when the source mesh AABB is offset from origin
		# (the head box is centered at y~0.58). Without an explicit AABB the
		# renderer mis-culls whole stretches of crowd from certain angles.
		var section_aabb: AABB = _grow_section_aabb(seed_aabb)
		body_mm.custom_aabb = section_aabb
		head_mm.custom_aabb = section_aabb
		body_mms.append(body_mm)
		head_mms.append(head_mm)
		away_flags.append(slice_away)
	layout["body_mms"] = body_mms
	layout["head_mms"] = head_mms
	layout["away_flags"] = away_flags


func _make_crowd_multimesh(mesh: ArrayMesh, count: int) -> MultiMesh:
	var mm: MultiMesh = MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


# Grow a section's origin-fit AABB to cover the spectators' full standing
# bodies plus the shader animation (crowd.gdshader): up to ~0.18 m of
# celebration hop on top, ~0.1 m of sway sideways; rotated bodies can extend
# by the box diagonal in any horizontal direction.
func _grow_section_aabb(seed_aabb: AABB) -> AABB:
	# Sized for the TALLEST spectator a stature roll can produce, not the mesh's
	# own dimensions — an under-sized AABB gets the whole section frustum-culled.
	var horizontal_margin: float = max(_BODY_SIZE.x, _BODY_SIZE.z) \
			* _CROWD_SCALE_MAX * 0.71 + 0.15
	var pos: Vector3 = seed_aabb.position - Vector3(horizontal_margin, 0.1, horizontal_margin)
	var end: Vector3 = seed_aabb.end + Vector3(
			horizontal_margin,
			(_BODY_SIZE.y + _HEAD_SIZE.y) * _CROWD_SCALE_MAX + 0.35,
			horizontal_margin)
	return AABB(pos, end - pos)


# One ring of spectators at `spectator_off` outward of the boards, feet at
# `y`. bench_row is the lower-bowl row index for the bench cutout, or -1 for
# rows the cutout can never apply to (the upper deck). is_upper selects the
# deck for the visiting-fan block (upper only). Appends a matching 0/1 flag
# to away_block per placed spectator.
func _append_spectator_row(transforms: Array[Transform3D], anim_data: Array[Color],
		away_block: PackedByteArray, rng: RandomNumberGenerator,
		spectator_off: float, y: float, bench_row: int, is_upper: bool) -> void:
	var away_section: int = _away_section_id()
	var samples: PackedVector2Array = _sample_offset_path(spectator_off)
	var resampled: PackedVector2Array = _resample_uniform(samples, spectator_spacing)
	for p: Vector2 in resampled:
		if bench_row >= 0 and _in_bench_zone(bench_row, p):
			continue
		# Vacancy roll first (before any jitter rolls) so the occupied seats'
		# jitter stream is stable relative to the seat sequence.
		if rng.randf() > attendance:
			continue
		var arc_s: float = _base_path_s(p)
		if _in_aisle(arc_s):
			continue
		var pos: Vector3 = Vector3(p.x, y + rng.randf_range(-spectator_y_jitter, spectator_y_jitter), p.y)
		# Face the rink: local forward (-Z) should point from p toward XZ
		# origin. With Basis(Y, yaw), forward_world = (-sin yaw, 0, -cos yaw);
		# solving for that to equal -p.normalized() yields yaw = atan2(p.x, p.z).
		var yaw: float = atan2(p.x, p.y) \
				+ deg_to_rad(rng.randf_range(-spectator_yaw_jitter_deg, spectator_yaw_jitter_deg))
		# Uniform, so the head rides the body without the two needing separate
		# transforms. Heads therefore vary a little with stature, which is not
		# how people are built but is invisible at this level of stylization.
		var stature: float = rng.randf_range(_SEATED_STATURE_MIN, _SEATED_STATURE_MAX)
		var spectator_basis: Basis = Basis(Vector3.UP, yaw).scaled(
				Vector3.ONE * (stature / _FIGURE_HEIGHT))
		transforms.append(Transform3D(spectator_basis, pos))
		away_block.append(1 if is_upper and num_aisles > 0
				and _section_id(arc_s) == away_section else 0)
		# Animation roll (crowd.gdshader INSTANCE_CUSTOM): phase de-sync,
		# sway amplitude, hop amplitude. Same data on body and head so the
		# two draw calls move as one person.
		anim_data.append(Color(
				rng.randf(),
				rng.randf_range(0.6, 1.4),
				rng.randf_range(0.2, 1.0),
				0.0))


# Attach the cached MultiMeshes and repaint only if the colors/ratios moved
# since the layout was last painted. A rebuild with unchanged colors (e.g.
# re-entering a scene) reattaches without touching a single instance.
func _add_spectators(layout: Dictionary) -> void:
	var paint_key: String = _paint_key()
	var body_mms: Array[MultiMesh] = layout.body_mms
	var head_mms: Array[MultiMesh] = layout.head_mms
	if layout.paint_key != paint_key:
		_paint_spectators(layout)
		layout.paint_key = paint_key

	for k: int in body_mms.size():
		var body_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		body_mmi.multimesh = body_mms[k]
		body_mmi.name = "SpectatorBodies%d" % k
		# The crowd casts no shadows. Thousands of instances × the 8 shadow-
		# casting ceiling spotlights (RinkArena.tscn) is the arena's biggest
		# shadow-map cost, and crowd-on-crowd shadows up in the stands are never
		# visible from the rink-focused camera — a shimmer at best, given the
		# sway/hop animation. (The goalie disables shadow casting the same way.)
		body_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(body_mmi)
		var head_mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		head_mmi.multimesh = head_mms[k]
		head_mmi.name = "SpectatorHeads%d" % k
		head_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(head_mmi)

	_flashbulbs = CrowdFlashbulbs.new()
	_flashbulbs.name = "CrowdFlashbulbs"
	_flashbulbs.set_sources(head_mms)
	add_child(_flashbulbs)


# ── Ribbon board ─────────────────────────────────────────────────────────────

# Turn one of this bowl's sampled paths into the {pos, inward} stations
# BoardAdBandBuilder wants.
#
# The traversal is REVERSED on the way in, because this file and HockeyRink wind
# their perimeters oppositely: _sample_offset_path runs bottom edge → left → top
# → right, while HockeyRink's stations run right → top → left → bottom. Arc
# length is the band's U axis, so feeding this bowl's own order would run U the
# other way round the building and hang every wordmark mirrored.
#
# Reversing flips the tangent, so inward — which must still point at the rink —
# is the +90° rotation here where the un-reversed path wanted −90°. Tangents
# come from a central difference so a station on a corner blends its two
# neighbours instead of inheriting one segment's normal wholesale.
func _path_stations(offset: float) -> Array:
	var pts: PackedVector2Array = _sample_offset_path(offset)
	pts.reverse()
	var stations: Array = []
	var count: int = pts.size()
	for i: int in count:
		var prev: Vector2 = pts[(i - 1 + count) % count]
		var next: Vector2 = pts[(i + 1) % count]
		var tangent: Vector2 = (next - prev).normalized()
		stations.append({
			"pos": pts[i],
			"inward": Vector2(-tangent.y, tangent.x),
		})
	return stations


# One continuous band around the fascia, sampled with U repeating _RIBBON_REPEATS
# times, so the whole board is a single mesh and a single material — and the
# scroll is one UV write per frame rather than anything rebuilt.
func _add_ribbon_board() -> void:
	if upper_terraces <= 0:
		return   # no upper deck means no fascia to mount it on
	var stations: Array = _path_stations(_upper_deck_inner_offset())
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	var centre_y: float = _upper_deck_base_y() \
			- _RIBBON_FASCIA_MARGIN - _RIBBON_HEIGHT * 0.5
	var band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			[Vector2(0.0, perimeter)] as Array[Vector2],
			[Rect2(0.0, 0.0, float(_RIBBON_REPEATS), 1.0)] as Array[Rect2],
			_RIBBON_INSET,
			centre_y - _RIBBON_HEIGHT * 0.5, centre_y + _RIBBON_HEIGHT * 0.5)
	if band == null:
		return

	var strip_vp := SubViewport.new()
	strip_vp.name = "RibbonStripViewport"
	strip_vp.size = RibbonPainter.strip_size(AdBrands.BRANDS.size())
	strip_vp.transparent_bg = false
	strip_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	strip_vp.disable_3d = true
	strip_vp.handle_input_locally = false
	strip_vp.gui_disable_input = true
	add_child(strip_vp)
	_ribbon_vp = strip_vp

	var painter := RibbonPainter.new()
	painter.brands = AdBrands.BRANDS
	strip_vp.add_child(painter)

	var mi := MeshInstance3D.new()
	mi.name = "RibbonBoard"
	mi.mesh = band
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = strip_vp.get_texture()
	# Unshaded so the board is its own light source rather than something the
	# ceiling rig has to reach, which at this height and angle it does not.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Double-sided like every other band in the project: BoardAdBandBuilder's
	# winding does not survive Godot's culling the way the world-space geometry
	# suggests it should (see HockeyRink._rebuild), so nothing built by it relies
	# on which face the renderer thinks is front.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	_ribbon_material = mat
	# One repeat spans this much wall, which converts the scroll speed from
	# metres per second into UV per second.
	_ribbon_span_m = perimeter / float(_RIBBON_REPEATS)
	# Editor previews hold still: a @tool node redrawing every frame for a
	# scrolling sign is churn the editor does not need.
	set_process(not Engine.is_editor_hint())


func _process(delta: float) -> void:
	if _ribbon_material == null or _ribbon_span_m <= 0.0:
		return
	var offset: Vector3 = _ribbon_material.uv1_offset
	offset.x = fposmod(offset.x + delta * ribbon_scroll_speed / _ribbon_span_m, 1.0)
	_ribbon_material.uv1_offset = offset


# ── Vomitories ───────────────────────────────────────────────────────────────

# A hole in the shell is only an improvement if it leads somewhere. Each opening
# gets a short recessed tunnel — two side walls, a ceiling, and a back wall lit
# as if the concourse beyond it were — so the portal reads as a way out rather
# than as a puncture showing the background colour through the building.
#
# Built as two meshes because the back wall is the only lit surface: everything
# else is the same dark concrete as the shell it is cut into.
func _add_vomitory_tunnels() -> void:
	if not _vomitories_wanted():
		return
	var walls := SurfaceTool.new()
	var backs := SurfaceTool.new()
	walls.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	backs.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)

	# The back of the top deck. These bore out through the shell, which is the
	# last thing modelled — the arena has no exterior and is not meant to, so
	# what they leave on the outside is not a consideration. Both rings are cut
	# to the same depth, and the depth is chosen for how a portal reads from
	# inside the bowl.
	var shell_base: float = _top_tread_y()
	_emit_vomitory_ring(walls, backs, _shell_offset(), shell_base,
			minf(shell_base + vomitory_height, shell_base + shell_height))
	# And the back of the lower bowl, boring outward UNDER the upper deck, which
	# is where a real concourse runs.
	var fascia_head: float = _fascia_portal_head()
	if upper_terraces > 0 and fascia_head > _lower_top_tread_y():
		_emit_vomitory_ring(walls, backs, _upper_deck_inner_offset(),
				_lower_top_tread_y(), fascia_head)

	walls.generate_normals()
	backs.generate_normals()
	# From a lit bowl a portal reads as a DARK hole with a hint of warmth deep in
	# it — not as a bright panel, which is what the first pass painted and which
	# reads as something stuck ON the wall rather than cut into it. The back is a
	# little lighter than the sides on purpose: that gradient from dark edges to
	# a warmer centre is the only depth cue a 2.6 m recess gets at this distance.
	_add_tunnel_instance(walls.commit(), "VomitoryTunnels", Color(0.055, 0.055, 0.065))
	_add_tunnel_instance(backs.commit(), "VomitoryLightSpill", Color(0.20, 0.16, 0.12))


# Tunnels behind every portal in one ring of wall.
#
# Extruded from the removed segments themselves rather than built as a box at
# each aisle's centre. An opening is cut by arc on the BASE path while the wall
# it is cut into stands metres further out, so the same arc span is a WIDER hole
# out there — wider still through a corner, and by a different amount for the
# fascia than for the shell. A box sized to the nominal width left daylight down
# both sides of every portal. Following the cut segments makes each tunnel
# exactly as wide as its own hole, whatever that ring's radius did to it.
func _emit_vomitory_ring(walls: SurfaceTool, backs: SurfaceTool, offset: float,
		base_y: float, head_y: float) -> void:
	var wall: PackedVector2Array = _resample_uniform(
			_sample_offset_path(offset), _VOMITORY_SAMPLE_M)
	var count: int = wall.size()
	if count < 4 or head_y <= base_y:
		return
	var cut: PackedByteArray = _shell_cut_flags(wall)

	for i: int in count:
		if cut[i] == 0:
			continue
		var j: int = (i + 1) % count
		var a: Vector2 = wall[i]
		var b: Vector2 = wall[j]
		var a_out: Vector2 = a + _outward_at(wall, i) * vomitory_depth
		var b_out: Vector2 = b + _outward_at(wall, j) * vomitory_depth
		# Back wall — the lit face at the end of the passage.
		_emit_quad_3d(backs, a_out, b_out, base_y, head_y)
		# Ceiling and floor. The floor matters: the ring's own walkway stops at
		# the wall, so without one a portal looks down into nothing.
		_emit_deck_quad(walls, a, b, b_out, a_out, head_y)
		_emit_deck_quad(walls, a, b, b_out, a_out, base_y)
		# Side walls, only where a run of cut segments begins or ends.
		if cut[(i - 1 + count) % count] == 0:
			_emit_quad_3d(walls, a, a_out, base_y, head_y)
		if cut[j] == 0:
			_emit_quad_3d(walls, b, b_out, base_y, head_y)


# A horizontal quad through four ground points at height `y`.
func _emit_deck_quad(st: SurfaceTool, a: Vector2, b: Vector2, c: Vector2,
		d: Vector2, y: float) -> void:
	st.add_vertex(Vector3(a.x, y, a.y))
	st.add_vertex(Vector3(b.x, y, b.y))
	st.add_vertex(Vector3(c.x, y, c.y))
	st.add_vertex(Vector3(a.x, y, a.y))
	st.add_vertex(Vector3(c.x, y, c.y))
	st.add_vertex(Vector3(d.x, y, d.y))


# Per-segment: is the wall between point i and i+1 a doorway? Shared by the
# shell mesh and the tunnels so the hole and what fills it can never disagree.
func _shell_cut_flags(wall: PackedVector2Array) -> PackedByteArray:
	var count: int = wall.size()
	var cut := PackedByteArray()
	cut.resize(count)
	for i: int in count:
		var mid: Vector2 = (wall[i] + wall[(i + 1) % count]) * 0.5
		cut[i] = 1 if _in_vomitory(_base_path_s(mid)) else 0
	return cut


# Outward (away from the rink) unit normal at a point on one of this bowl's
# sampled paths.
#
# The rotation sign is the whole content of this function, and it is the opposite
# of the one _path_stations uses, because that helper reverses the loop first.
# On the path as _sample_offset_path emits it, the bottom edge runs −X at
# z = −half_length, so its tangent is (−1, 0) and the rink lies at +Z: rotating
# the tangent by −90° gives (0, +1), which points at the ice. Outward is the +90°
# rotation. Getting this backwards bores every tunnel INTO the seating bowl,
# which looks like the portals are projecting out of the concourse rather than
# cut into it.
func _outward_at(wall: PackedVector2Array, index: int) -> Vector2:
	var count: int = wall.size()
	var tangent: Vector2 = (wall[(index + 1) % count]
			- wall[(index - 1 + count) % count]).normalized()
	return Vector2(-tangent.y, tangent.x)


# A vertical quad between two ground points. Wound either way is fine: every
# tunnel surface is double-sided, since the only camera that ever sees one is
# looking straight into it.
func _emit_quad_3d(st: SurfaceTool, a: Vector2, b: Vector2,
		y_bot: float, y_top: float) -> void:
	st.add_vertex(Vector3(a.x, y_bot, a.y))
	st.add_vertex(Vector3(b.x, y_bot, b.y))
	st.add_vertex(Vector3(b.x, y_top, b.y))
	st.add_vertex(Vector3(a.x, y_bot, a.y))
	st.add_vertex(Vector3(b.x, y_top, b.y))
	st.add_vertex(Vector3(a.x, y_top, a.y))


func _add_tunnel_instance(mesh: ArrayMesh, node_name: String, color: Color) -> void:
	if mesh == null:
		return
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# Unshaded, for two reasons. These surfaces are double-sided with winding
	# that carries no meaning (see _emit_quad_3d), so generated normals would
	# light half of them from behind and flatten the recess the values are there
	# to describe. And a concourse keeps its own lights: the tunnels holding
	# steady while the house dims for a skate-on is correct, not a miss.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


# ── Rinkside staff ───────────────────────────────────────────────────────────

# The benches, the penalty boxes, and the timekeeper's table were all furniture
# with nobody at it — a table with no timekeeper reads emptier than no table.
# Nine figures fix that: two coaches behind each bench, an attendant at each
# penalty box door, and three of the off-ice crew at the table.
#
# One MultiMesh pair for the lot, same body and head meshes the crowd uses, but
# with a plain material: the crowd shader sways and hops off per-instance custom
# data, and staff standing at their posts should do neither.
func _build_staff() -> void:
	var posts: Array[Vector3] = []
	var jackets: Array[Color] = []
	var standing: Array[bool] = []
	_staff_postings(posts, jackets, standing)

	var rng := RandomNumberGenerator.new()
	rng.seed = _STAFF_SEED
	# Body and head take separate transforms, where the crowd shares one: a
	# standing figure stretches in Y and its head does not, so the two cannot
	# ride the same basis.
	var body_mm: MultiMesh = _make_staff_multimesh(_build_body_mesh(), posts.size())
	var head_mm: MultiMesh = _make_staff_multimesh(_build_head_mesh(), posts.size())
	var bounds := AABB(posts[0], Vector3.ZERO)
	for i: int in posts.size():
		var stature: float = rng.randf_range(
				_STANDING_STATURE_MIN, _STANDING_STATURE_MAX)
		var girth: float = _staff_girth_scale(stature)
		# Sitting IS the unscaled figure, so a seated staffer lifts by nothing and
		# both transforms collapse to the spectator's.
		var lift: float = _staff_hip_height(stature) if standing[i] else 0.0
		var yaw: float = atan2(posts[i].x, posts[i].z)
		body_mm.set_instance_transform(i,
				_staff_body_transform(posts[i], yaw, girth, lift))
		head_mm.set_instance_transform(i,
				_staff_head_transform(posts[i], yaw, girth, lift))
		body_mm.set_instance_color(i, jackets[i])
		head_mm.set_instance_color(i, _head_palette[rng.randi() % _head_palette.size()])
		bounds = bounds.expand(posts[i])
	var staff_aabb: AABB = _grow_staff_aabb(bounds)
	body_mm.custom_aabb = staff_aabb
	head_mm.custom_aabb = staff_aabb

	for part: Array in [["StaffBodies", body_mm], ["StaffHeads", head_mm]]:
		var mmi := MultiMeshInstance3D.new()
		mmi.name = part[0]
		mmi.multimesh = part[1]
		mmi.material_override = _staff_material()
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mmi)


# Explicit bounds for the same reason the crowd sections have them: Godot's
# auto-AABB is unreliable when transforms are pushed one at a time rather than as
# a single buffer write, and an under-sized one gets the whole MultiMesh
# frustum-culled from angles where it should be visible. The seed box covers
# instance ORIGINS (their feet) only, so it has to grow by the tallest figure's
# own reach — sideways by a rotated body's half-diagonal, up by a full stature.
func _grow_staff_aabb(seed_aabb: AABB) -> AABB:
	var reach: float = maxf(_BODY_SIZE.x, _BODY_SIZE.z) \
			* _staff_girth_scale(_STANDING_STATURE_MAX)
	return AABB(seed_aabb.position - Vector3(reach, 0.1, reach),
			seed_aabb.size + Vector3(reach * 2.0, _STANDING_STATURE_MAX + 0.1,
					reach * 2.0))


# Who works where, filled into caller-owned arrays: a post, a jacket, and
# whether they work on their feet. Separate from the build because a MultiMesh's
# instance transforms are write-only under the headless renderer — this is the
# only seam a test can read the roster through.
func _staff_postings(posts: Array[Vector3], jackets: Array[Color],
		standing: Array[bool]) -> void:
	var bench_x: float = rink_width / 2.0 + base_outward_offset

	# Coaches: two behind each bench, on the tread a step up from the bench
	# itself, facing the ice. Jackets are only lightly darkened from the team
	# colour — staff stand against dark furniture behind tinted glass, and
	# anything nearer to black merges with the box they are in.
	for side: float in [-1.0, 1.0]:
		var jacket: Color = (home_color if side > 0.0 else away_color).darkened(0.3)
		for dz: float in [-1.15, 1.15]:
			posts.append(Vector3(bench_x + _STAFF_BEHIND_BENCH,
					_tread_y_at(_STAFF_BEHIND_BENCH), side * BENCH_CENTER_Z + dz))
			jackets.append(jacket)
			standing.append(true)

	# Penalty-box attendants, sitting on the box's own bench at the door end —
	# the same seat block a penalized player uses, so they need no chair.
	for side: float in [-1.0, 1.0]:
		posts.append(Vector3(-(bench_x + _BENCH_SEAT_X_OFFSET),
				stands_base_y + _BENCH_SEAT_HEIGHT,
				side * (PENALTY_BOX_CENTER_Z + PENALTY_BOX_HALF_LEN - 0.4)))
		jackets.append(Color(0.38, 0.40, 0.46))
		standing.append(false)

	# Timekeeping crew, seated at the table between the boxes.
	for dz: float in [-0.72, 0.0, 0.72]:
		posts.append(Vector3(-(bench_x + _STAFF_BEHIND_TABLE),
				_tread_y_at(_STAFF_BEHIND_TABLE), dz))
		# The off-ice crew works in shirtsleeves; pale is also what separates them
		# from the dark counter they sit behind.
		jackets.append(Color(0.74, 0.76, 0.80))
		standing.append(false)


# Floor height for someone standing `beyond` metres past the terraces' inner
# edge. Staff stand a metre back from the furniture they work at, which is far
# enough to be on the SECOND tread rather than the first — placing them at the
# bowl's base height instead sinks them into the riser and puts the bench
# backrest across their chest, which is where they were until this existed.
func _tread_y_at(beyond: float) -> float:
	var step: int = clampi(floori(beyond / tread_depth), 0, maxi(num_terraces - 1, 0))
	return stands_base_y + float(step) * riser_height


# The body box is the only part of a staffer that changes with posture: standing,
# it stands in for legs as well as torso, so it is stretched in Y by `lift` until
# its top lands at the neck. Across, it stays at `girth` either way — shoulders
# are shoulders, sitting or standing — and a seated figure (lift 0) comes out as
# exactly the spectator this geometry was drawn for.
func _staff_body_transform(post: Vector3, yaw: float, girth: float,
		lift: float) -> Transform3D:
	var y_scale: float = girth + lift / (_BODY_Y_LIFT + _BODY_SIZE.y)
	return Transform3D(
			Basis(Vector3.UP, yaw).scaled(Vector3(girth, y_scale, girth)), post)


# The head is that same figure's head untouched, carried up by whatever the body
# box grew — so the crown lands at full stature and the neck gap survives.
func _staff_head_transform(post: Vector3, yaw: float, girth: float,
		lift: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * girth),
			post + Vector3.UP * lift)


# What the crowd's scale would be for a spectator of this standing stature.
func _staff_girth_scale(stature: float) -> float:
	return stature * _SITTING_HEIGHT_FRACTION / _FIGURE_HEIGHT


# Everything standing adds over sitting: the hips a seated figure folds away.
func _staff_hip_height(stature: float) -> float:
	return stature * (1.0 - _SITTING_HEIGHT_FRACTION)


func _make_staff_multimesh(mesh: ArrayMesh, count: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = count
	return mm


# Lit, unlike the crowd — staff stand at ice level under the rig that lights the
# boards, close enough to the camera that flat shading would read as cardboard.
func _staff_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	return mat


# ── Rafter banners ───────────────────────────────────────────────────────────

# Banners are spaced evenly around a ring inboard of the shell and built as one
# band, exactly like the boards' ad panels — a 2.6 m banner on a ring this wide
# is very nearly flat, so following the arc costs nothing and saves writing a
# second quad builder.
func _add_rafter_banners() -> void:
	if shell_height <= 0.0 or BannerRegistry.BANNERS.is_empty():
		return
	var stations: Array = _path_stations(_shell_offset() - _BANNER_INBOARD)
	var cumulative: PackedFloat32Array = BoardAdBandBuilder.cumulative_arcs(stations)
	var perimeter: float = BoardAdBandBuilder.perimeter_of(cumulative)
	# Distinct banners (one atlas cell each) versus how many hang: the registry
	# goes round the ring more than once, so a name appears on opposite sides.
	var unique: int = BannerRegistry.BANNERS.size()
	var hung: int = unique * _BANNER_RING_REPEATS
	var width: float = banner_height \
			* float(BannerPainter.CELL_PX.x) / float(BannerPainter.CELL_PX.y)
	if width <= 0.0 or width * hung >= perimeter:
		return

	var placements: Array[Vector2] = []
	var uv_rects: Array[Rect2] = []
	for i: int in hung:
		# Evenly spaced around the ring, each centred on its share of it.
		var centre: float = perimeter * (float(i) + 0.5) / float(hung)
		placements.append(Vector2(centre - width * 0.5, width))
		uv_rects.append(BannerPainter.cell_uv(i % unique, unique))

	var top_y: float = _top_tread_y() + shell_height * _BANNER_TOP_FRACTION
	var band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			placements, uv_rects, 0.0, top_y - banner_height, top_y)
	if band == null:
		return
	# Cloth has two sides and a real banner is printed on both. A single
	# double-sided quad would show the reverse mirrored, so the back is its own
	# surface hung _BANNER_THICKNESS behind the front with its U reversed —
	# which reads right from outside the ring and keeps the two off each other's
	# depth.
	var back_rects: Array[Rect2] = []
	for cell: Rect2 in uv_rects:
		back_rects.append(Rect2(cell.position.x + cell.size.x, cell.position.y,
				-cell.size.x, cell.size.y))
	var back_band: ArrayMesh = BoardAdBandBuilder.build_band(stations, cumulative,
			placements, back_rects, -_BANNER_THICKNESS,
			top_y - banner_height, top_y)

	var atlas_vp := SubViewport.new()
	atlas_vp.name = "BannerAtlasViewport"
	atlas_vp.size = BannerPainter.atlas_size(unique)
	atlas_vp.transparent_bg = true
	atlas_vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	atlas_vp.disable_3d = true
	atlas_vp.handle_input_locally = false
	atlas_vp.gui_disable_input = true
	add_child(atlas_vp)
	_banner_vp = atlas_vp

	var painter := BannerPainter.new()
	painter.banners = BannerRegistry.BANNERS
	atlas_vp.add_child(painter)

	var mat := StandardMaterial3D.new()
	mat.albedo_texture = atlas_vp.get_texture()
	# Unshaded: nothing lights the roof space, so a lit banner is a black
	# rectangle. Double-sided per surface, since BoardAdBandBuilder's winding
	# does not survive culling the way the geometry suggests (see
	# HockeyRink._rebuild) — the two surfaces, not the culling, make the sides.
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_banner_material = mat

	for face: Array in [["RafterBanners", band], ["RafterBannersBack", back_band]]:
		if face[1] == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = face[0]
		mi.mesh = face[1]
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)


# ── Seats ────────────────────────────────────────────────────────────────────
#
# Same shape as the crowd — per-section MultiMeshes over the same angular
# slices, so seats frustum-cull with the spectators sitting in them — but built
# in a separate pass over the same rows rather than alongside the spectators.
# Two reasons, and both are load-bearing:
#
#   A seat exists whether or not anyone is in it, so this pass has no vacancy
#   roll. Weaving that difference into _append_spectator_row would mean two
#   traversals of one rng stream, and the crowd's whole appearance is downstream
#   of that stream's order.
#
#   Seats are bolted to the concrete: no yaw jitter, no height jitter, no
#   animation. The crowd's sway/hop comes from its shader reading per-instance
#   custom data; seats want none of it, so they carry no custom data and use a
#   plain material instead.
func _fill_seat_layout(layout: Dictionary) -> void:
	var transforms: Array[Transform3D] = []
	var shades: PackedFloat32Array = PackedFloat32Array()
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEAT_SEED
	for i: int in num_terraces:
		_append_seat_row(transforms, shades, rng,
				base_outward_offset + i * tread_depth + spectator_inset_from_riser,
				stands_base_y + i * riser_height, i)
	for j: int in upper_terraces:
		_append_seat_row(transforms, shades, rng,
				_upper_deck_inner_offset() + j * tread_depth + spectator_inset_from_riser,
				_upper_deck_base_y() + j * upper_riser_height, -1)

	var seat_mesh: ArrayMesh = _build_seat_mesh()
	var section_indices: Array[PackedInt32Array] = []
	section_indices.resize(_CROWD_SECTIONS)
	for k: int in _CROWD_SECTIONS:
		section_indices[k] = PackedInt32Array()
	for i: int in transforms.size():
		var o: Vector3 = transforms[i].origin
		var sector: int = int(floor((atan2(o.z, o.x) + PI) / TAU * _CROWD_SECTIONS))
		section_indices[clampi(sector, 0, _CROWD_SECTIONS - 1)].append(i)

	var seat_mms: Array[MultiMesh] = []
	for k: int in _CROWD_SECTIONS:
		var idxs: PackedInt32Array = section_indices[k]
		if idxs.is_empty():
			continue
		var mm: MultiMesh = MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = seat_mesh
		mm.instance_count = idxs.size()
		var seed_aabb: AABB = AABB(transforms[idxs[0]].origin, Vector3.ZERO)
		for n_i: int in idxs.size():
			var src: int = idxs[n_i]
			mm.set_instance_transform(n_i, transforms[src])
			# White scaled by the shade roll. The material's albedo carries the
			# actual colour and multiplies through, so seat_color stays a live
			# export instead of something baked into this cached layout.
			var shade: float = shades[src]
			mm.set_instance_color(n_i, Color(shade, shade, shade))
			seed_aabb = seed_aabb.expand(transforms[src].origin)
		mm.custom_aabb = _grow_seat_aabb(seed_aabb)
		seat_mms.append(mm)
	layout["seat_mms"] = seat_mms


# One ring of seats. Mirrors _append_spectator_row's placement rules — the bench
# cutout and the aisles take precedence over furniture the same way they take
# precedence over people — minus the vacancy roll and every jitter.
func _append_seat_row(transforms: Array[Transform3D], shades: PackedFloat32Array,
		rng: RandomNumberGenerator, seat_off: float, y: float, bench_row: int) -> void:
	var samples: PackedVector2Array = _sample_offset_path(seat_off)
	var resampled: PackedVector2Array = _resample_uniform(samples, spectator_spacing)
	for p: Vector2 in resampled:
		if bench_row >= 0 and _in_bench_zone(bench_row, p):
			continue
		if _in_aisle(_base_path_s(p)):
			continue
		transforms.append(Transform3D(Basis(Vector3.UP, atan2(p.x, p.y)),
				Vector3(p.x, y, p.y)))
		shades.append(1.0 - rng.randf() * seat_shade_variation)


# Unlike the crowd's, a seat's AABB needs no animation headroom — nothing here
# sways or hops. It still needs the mesh's own extent, since the seed box only
# covers instance ORIGINS, and the horizontal margin still has to allow for a
# seat rotated to any heading around the bowl.
func _grow_seat_aabb(seed_aabb: AABB) -> AABB:
	var reach: float = Vector2(_SEAT_WIDTH, _SEAT_BACK_OFFSET
			+ _SEAT_BACK_THICKNESS).length() * 0.5 + 0.1
	var pos: Vector3 = seed_aabb.position - Vector3(reach, 0.05, reach)
	var end: Vector3 = seed_aabb.end + Vector3(reach, _SEAT_BACK_HEIGHT + 0.1, reach)
	return AABB(pos, end - pos)


# Pan and backrest as one mesh. They are rigidly related and share a colour, so
# splitting them would double the instance count to buy nothing — unlike the
# crowd's body and head, which are separate only because they take different
# per-instance colours (shirt and skin) from the same transform.
func _build_seat_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	_emit_box(st, Vector3(0.0, _SEAT_Y_LIFT + _SEAT_PAN_THICKNESS * 0.5, 0.0),
			Vector3(_SEAT_WIDTH, _SEAT_PAN_THICKNESS, _SEAT_PAN_DEPTH))
	_emit_box(st, Vector3(0.0, _SEAT_Y_LIFT + _SEAT_BACK_HEIGHT * 0.5, _SEAT_BACK_OFFSET),
			Vector3(_SEAT_WIDTH, _SEAT_BACK_HEIGHT, _SEAT_BACK_THICKNESS))
	st.generate_normals()
	return st.commit()


func _add_seats(layout: Dictionary) -> void:
	var seat_mms: Array[MultiMesh] = layout.seat_mms
	if seat_mms.is_empty():
		return
	var mat: StandardMaterial3D = _seat_material()
	for k: int in seat_mms.size():
		var mmi: MultiMeshInstance3D = MultiMeshInstance3D.new()
		mmi.multimesh = seat_mms[k]
		mmi.name = "Seats%d" % k
		mmi.material_override = mat
		# Shadows off for the same reason the crowd's are (see _add_spectators):
		# thousands of instances across the eight shadow-casting ceiling lights
		# is the arena's biggest shadow-map cost, and seat shadows up in the
		# stands are invisible from a rink-focused camera.
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# And out of the GI probe: SDFGI voxelizes static geometry, which is
		# exactly what these are and exactly the volume it charges for. Seats
		# are small, dark, and mostly under an occupant — they have nothing to
		# contribute to bounce that the terrace beneath them doesn't already.
		mmi.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(mmi)


# Flat and unshiny — moulded plastic, not furniture polish. Vertex colour is on
# so the per-instance shade roll multiplies into the albedo.
func _seat_material() -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = seat_color
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.85
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return mat


# Roll body/head colors for every spectator. Own rng stream (same _SEED),
# consumed across the sections in their fixed build order, so the fan-mix
# assignment is deterministic and identical across repaints of the same
# layout. Seats flagged into the visiting-fan block roll the away-heavy mix.
func _paint_spectators(layout: Dictionary) -> void:
	var body_mms: Array[MultiMesh] = layout.body_mms
	var head_mms: Array[MultiMesh] = layout.head_mms
	var away_flags: Array[PackedByteArray] = layout.away_flags
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = _SEED
	for k: int in body_mms.size():
		var body_mm: MultiMesh = body_mms[k]
		var head_mm: MultiMesh = head_mms[k]
		var slice_away: PackedByteArray = away_flags[k]
		for i: int in body_mm.instance_count:
			var picked: Array[Color] = _pick_spectator_colors(rng, slice_away[i] != 0)
			body_mm.set_instance_color(i, picked[0])
			head_mm.set_instance_color(i, picked[1])


# Body box, origin at the spectator's base. Lifted 2 mm off the tread so the
# bottom face doesn't z-fight — the bottom is visible from any camera below
# the spectator's row (common for back-row spectators in the upper bowl).
func _build_body_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	_emit_box(st, Vector3(0.0, _BODY_Y_LIFT + _BODY_SIZE.y * 0.5, 0.0), _BODY_SIZE)
	st.generate_normals()
	st.set_material(_spectator_material())
	return st.commit()


# Head box, positioned above the body so it lines up when applied with the
# same transform as the body MultiMesh. Lifted with the body.
func _build_head_mesh() -> ArrayMesh:
	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PrimitiveType.PRIMITIVE_TRIANGLES)
	var head_center_y: float = _BODY_Y_LIFT + _BODY_SIZE.y + _HEAD_SIZE.y * 0.5 + 0.02
	_emit_box(st, Vector3(0.0, head_center_y, 0.0), _HEAD_SIZE)
	st.generate_normals()
	st.set_material(_spectator_material())
	return st.commit()


# Shared material — crowd.gdshader reads the per-instance MultiMesh color
# for albedo (matching the old vertex_color_use_as_albedo look) and animates
# sway/hop from INSTANCE_CUSTOM + the excitement uniform. One material across
# both MultiMeshes and across rebuilds, so excitement state persists and a
# single uniform write drives the whole bowl. Cull disabled matches the
# terrace material: back-face culling on individual spectators was leaving
# rink-facing faces invisible at certain camera angles (the boxes looked
# hollow), and the extra triangles are cheap on a few thousand instances of
# an 8-vert mesh.
func _spectator_material() -> ShaderMaterial:
	if _crowd_material == null:
		_crowd_material = ShaderMaterial.new()
		_crowd_material.shader = load(_CROWD_SHADER_PATH)
		_crowd_material.set_shader_parameter("excitement", _excitement)
	return _crowd_material


# True when a spectator slot falls inside a rinkside furniture cutout: the first
# _BENCH_CLEAR_ROWS rows on either side of the bowl, along the full stretch the
# furniture occupies — the player benches on +X, the penalty boxes and officials'
# table on −X. Both spans include the GAP between their two halves, which is
# gate and staff area rather than seating; fans at ice level in that sliver read
# as people sitting between the benches.
# Sample points are (x, z) packed as Vector2(x, y).
func _in_bench_zone(row: int, p: Vector2) -> bool:
	if row >= _BENCH_CLEAR_ROWS:
		return false
	if p.x >= 0.0:
		return absf(p.y) < BENCH_CENTER_Z + BENCH_HALF_LEN + _BENCH_CLEAR_MARGIN
	# −X: the penalty boxes and the officials' table between them.
	return absf(p.y) < PENALTY_BOX_CENTER_Z + PENALTY_BOX_HALF_LEN + _BENCH_CLEAR_MARGIN


# ── Player benches ───────────────────────────────────────────────────────────

# One solid team-colored bench block + a charcoal backrest per team, sitting
# on the first-row tread where the crowd was cleared. Rebuilt with the bowl,
# so bench colors re-tint when team_colors_ready re-runs setup().
func _build_benches() -> void:
	var x_inner: float = rink_width / 2.0 + base_outward_offset
	var tread_y: float = stands_base_y
	for side: float in [-1.0, 1.0]:
		var center_z: float = side * BENCH_CENTER_Z
		# Home (team 0) defends +Z, so its bench sits on the +Z half.
		var team_color: Color = home_color if side > 0.0 else away_color

		var seat := MeshInstance3D.new()
		seat.name = "BenchSeatHome" if side > 0.0 else "BenchSeatAway"
		var seat_mesh := BoxMesh.new()
		seat_mesh.size = Vector3(0.42, _BENCH_SEAT_HEIGHT, BENCH_HALF_LEN * 2.0)
		var seat_mat := StandardMaterial3D.new()
		seat_mat.albedo_color = team_color.darkened(0.25)
		seat_mat.roughness = 0.8
		seat_mesh.material = seat_mat
		seat.mesh = seat_mesh
		seat.position = Vector3(x_inner + _BENCH_SEAT_X_OFFSET,
				tread_y + _BENCH_SEAT_HEIGHT * 0.5, center_z)
		add_child(seat)

		var backrest := MeshInstance3D.new()
		backrest.name = "BenchBackHome" if side > 0.0 else "BenchBackAway"
		var back_mesh := BoxMesh.new()
		back_mesh.size = Vector3(0.06, 0.5, BENCH_HALF_LEN * 2.0)
		var back_mat := StandardMaterial3D.new()
		back_mat.albedo_color = Color(0.20, 0.20, 0.22)
		back_mat.roughness = 0.9
		back_mesh.material = back_mat
		backrest.mesh = back_mesh
		backrest.position = Vector3(x_inner + 0.57, tread_y + 0.55, center_z)
		add_child(backrest)


# The −X answer to the benches: a box per team either side of centre ice with
# the off-ice officials' table in the gap. Same construction as _build_benches
# and, like it, empty furniture — 3v3 fields no reserves and the game calls no
# penalties, so nobody ever sits here. It earns its place by breaking up the
# only stretch of this bowl that ran crowd from corner to corner, and by putting
# something behind the −X glass for the boards' gates to open onto.
func _build_penalty_boxes() -> void:
	var x_inner: float = -(rink_width / 2.0 + base_outward_offset)
	var tread_y: float = stands_base_y

	for side: float in [-1.0, 1.0]:
		var center_z: float = side * PENALTY_BOX_CENTER_Z
		# Matches the benches' convention: the +Z-half team is home.
		var team_color: Color = home_color if side > 0.0 else away_color

		var seat := MeshInstance3D.new()
		seat.name = "PenaltySeatHome" if side > 0.0 else "PenaltySeatAway"
		var seat_mesh := BoxMesh.new()
		seat_mesh.size = Vector3(0.42, _BENCH_SEAT_HEIGHT, PENALTY_BOX_HALF_LEN * 2.0)
		var seat_mat := StandardMaterial3D.new()
		seat_mat.albedo_color = team_color.darkened(0.35)
		seat_mat.roughness = 0.8
		seat_mesh.material = seat_mat
		seat.mesh = seat_mesh
		seat.position = Vector3(x_inner - _BENCH_SEAT_X_OFFSET,
				tread_y + _BENCH_SEAT_HEIGHT * 0.5, center_z)
		add_child(seat)

		var backrest := MeshInstance3D.new()
		backrest.name = "PenaltyBackHome" if side > 0.0 else "PenaltyBackAway"
		var back_mesh := BoxMesh.new()
		back_mesh.size = Vector3(0.06, 0.5, PENALTY_BOX_HALF_LEN * 2.0)
		var back_mat := StandardMaterial3D.new()
		back_mat.albedo_color = Color(0.20, 0.20, 0.22)
		back_mat.roughness = 0.9
		back_mesh.material = back_mat
		backrest.mesh = back_mesh
		backrest.position = Vector3(x_inner - 0.57, tread_y + 0.55, center_z)
		add_child(backrest)

		# Divider between this box and the officials, so the three read as three
		# compartments rather than one long shelf.
		var divider := MeshInstance3D.new()
		divider.name = "PenaltyDividerHome" if side > 0.0 else "PenaltyDividerAway"
		var divider_mesh := BoxMesh.new()
		divider_mesh.size = Vector3(0.72, 1.05, 0.07)
		var divider_mat := StandardMaterial3D.new()
		divider_mat.albedo_color = Color(0.24, 0.25, 0.28)
		divider_mat.roughness = 0.9
		divider_mesh.material = divider_mat
		divider.mesh = divider_mesh
		divider.position = Vector3(x_inner - 0.36, tread_y + 0.525,
				side * _OFFICIALS_HALF_LEN)
		add_child(divider)

	# Timekeeper's table: desk height, so the crew seated behind it clears the
	# top from the chest up rather than peering over it.
	var table := MeshInstance3D.new()
	table.name = "OfficialsTable"
	var table_mesh := BoxMesh.new()
	table_mesh.size = Vector3(0.60, _OFFICIALS_HEIGHT, _OFFICIALS_HALF_LEN * 2.0)
	var table_mat := StandardMaterial3D.new()
	table_mat.albedo_color = Color(0.17, 0.18, 0.21)
	table_mat.roughness = 0.85
	table_mesh.material = table_mat
	table.mesh = table_mesh
	table.position = Vector3(x_inner - 0.42, tread_y + _OFFICIALS_HEIGHT * 0.5, 0.0)
	add_child(table)


# Seat-surface center of a team's bench (top face of the seat block), in
# ArenaStands-local space. Home (team 0) sits on the +Z half, matching
# _build_benches. The lobby backdrop uses this to seat roster dummies.
func bench_seat_center(team_id: int) -> Vector3:
	var side: float = 1.0 if team_id == 0 else -1.0
	return Vector3(rink_width / 2.0 + base_outward_offset + _BENCH_SEAT_X_OFFSET,
			stands_base_y + _BENCH_SEAT_HEIGHT, side * BENCH_CENTER_Z)


# ── Crowd excitement ─────────────────────────────────────────────────────────

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


func _set_excitement(v: float) -> void:
	_excitement = v
	_spectator_material().set_shader_parameter("excitement", v)
	if _flashbulbs != null and is_instance_valid(_flashbulbs):
		_flashbulbs.set_excitement(v)


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


func _emit_box(st: SurfaceTool, center: Vector3, size: Vector3) -> void:
	var h: Vector3 = size * 0.5
	# 8 corners
	var p: Array[Vector3] = [
		center + Vector3(-h.x, -h.y, -h.z),  # 0
		center + Vector3( h.x, -h.y, -h.z),  # 1
		center + Vector3( h.x, -h.y,  h.z),  # 2
		center + Vector3(-h.x, -h.y,  h.z),  # 3
		center + Vector3(-h.x,  h.y, -h.z),  # 4
		center + Vector3( h.x,  h.y, -h.z),  # 5
		center + Vector3( h.x,  h.y,  h.z),  # 6
		center + Vector3(-h.x,  h.y,  h.z),  # 7
	]
	# Six faces, each two CCW-wound triangles (Godot front = CCW).
	# +Y (top)
	_emit_quad(st, p[4], p[7], p[6], p[5])
	# -Y (bottom)
	_emit_quad(st, p[0], p[1], p[2], p[3])
	# +Z (front)
	_emit_quad(st, p[3], p[2], p[6], p[7])
	# -Z (back)
	_emit_quad(st, p[1], p[0], p[4], p[5])
	# +X (right)
	_emit_quad(st, p[2], p[1], p[5], p[6])
	# -X (left)
	_emit_quad(st, p[0], p[3], p[7], p[4])


func _emit_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)
	st.add_vertex(a)
	st.add_vertex(c)
	st.add_vertex(d)


# Walk the (already-CCW) sample polyline at uniform arc-length `spacing` and
# return the resampled points. Keeps spectator placement even regardless of
# the underlying corner_segments / straight-step density.
func _resample_uniform(samples: PackedVector2Array, spacing: float) -> PackedVector2Array:
	var out: PackedVector2Array = PackedVector2Array()
	if samples.size() < 2 or spacing <= 0.0:
		return out
	var cum: float = 0.0
	var next_t: float = spacing * 0.5  # half-step inset so the first/last don't crowd a seam
	var n: int = samples.size()
	for i: int in n:
		var a: Vector2 = samples[i]
		var b: Vector2 = samples[(i + 1) % n]
		var seg_len: float = a.distance_to(b)
		if seg_len <= 0.0:
			continue
		while next_t <= cum + seg_len:
			var t: float = (next_t - cum) / seg_len
			out.append(a.lerp(b, t))
			next_t += spacing
		cum += seg_len
	return out


# Away-fan share inside the designated visiting block. A feel constant: real
# visiting sections read as a wall of away colors with locals mixed through,
# and 0.7 sells that without looking like a printed flag.
const _AWAY_SECTION_FILL: float = 0.7


# Roll a body + head color pair for one spectator. Returns [body, head].
# Body roll: home_fan_ratio of home colors, away_fan_ratio of away colors,
# rest neutral civilian shirts. Real arenas skew heavily toward home, with
# the traveling support concentrated in one visiting block (in_away_block —
# away-heavy, zero home) plus a sprinkle scattered through the bowl.
# Within each team slice, secondary_color_ratio swap to the secondary tint.
# Head roll: skin/hat palette by default, with a small team_cap_ratio chance
# of a team-colored hat for committed fans.
func _pick_spectator_colors(rng: RandomNumberGenerator,
		in_away_block: bool = false) -> Array[Color]:
	var roll: float = rng.randf()
	var home_cut: float = 0.0 if in_away_block else home_fan_ratio
	var away_cut: float = _AWAY_SECTION_FILL if in_away_block else away_fan_ratio
	var body: Color
	var team_loyalty: Color = Color(0, 0, 0, 0)  # alpha=0 sentinel = neutral
	if roll < home_cut:
		var base: Color = home_color_secondary if rng.randf() < secondary_color_ratio else home_color
		body = _shade(base, rng)
		team_loyalty = home_color
	elif roll < home_cut + away_cut:
		var base: Color = away_color_secondary if rng.randf() < secondary_color_ratio else away_color
		body = _shade(base, rng)
		team_loyalty = away_color
	else:
		body = _neutral_body_palette[rng.randi() % _neutral_body_palette.size()]
	var head: Color
	if team_loyalty.a > 0.0 and rng.randf() < team_cap_ratio:
		head = _shade(team_loyalty, rng)
	else:
		head = _head_palette[rng.randi() % _head_palette.size()]
	return [body, head]


func _shade(base: Color, rng: RandomNumberGenerator) -> Color:
	var s: float = rng.randf_range(-0.18, 0.18)
	return base.lightened(s) if s > 0.0 else base.darkened(-s)
