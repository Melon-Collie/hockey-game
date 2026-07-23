class_name Minimap
extends Control

# Top-down rink minimap. A cosmetic HUD widget (like OffScreenPlayerIndicators):
# it reads live world state through GameManager and redraws every frame at render
# rate — never on the physics tick — so it costs nothing in the 120 Hz budget.
#
# Orientation MATCHES the game camera. The camera renders the rink with world +X
# to screen-right and world +Z toward screen-bottom, and flips 180° (yaw) only
# when the "Always Attack Up" pref is on AND the local player is on team 1 (see
# GameCamera._physics_process step 5b). The minimap reproduces exactly that flip
# via the same boolean, so the direction the local player attacks is always the
# same on the map as it is on screen — up-screen when attack-up is on, absolute
# otherwise. Because the transform is derived from the camera's own rule rather
# than hard-coded per team, the attacking net on the map can never disagree with
# the one in the game.
#
# Toggled by PlayerPrefs.minimap_enabled (Options → Camera). Hidden during replays
# (no local frame of reference — same reason the off-screen arrows bail).

# Ice draw area in virtual HUD pixels along the long (Z) axis; the short (X) axis
# is derived from the true rink aspect so the map never distorts.
const _ICE_LENGTH_PX: float = 210.0
const _MARGIN: float = 8.0

const _BG_COLOR: Color = Color(0.05, 0.06, 0.09, 0.72)
const _ICE_COLOR: Color = Color(0.74, 0.81, 0.90, 0.34)
const _BORDER_COLOR: Color = Color(0.85, 0.88, 0.94, 0.55)
const _CENTER_LINE_COLOR: Color = Color(0.86, 0.22, 0.22, 0.85)
const _BLUE_LINE_COLOR: Color = Color(0.28, 0.48, 0.92, 0.85)
const _GOAL_LINE_COLOR: Color = Color(0.86, 0.22, 0.22, 0.5)
const _PUCK_FILL: Color = Color(0.02, 0.02, 0.02, 1.0)
const _PUCK_OUTLINE: Color = Color(1.0, 1.0, 1.0, 0.9)
const _DOT_OUTLINE: Color = Color(0.0, 0.0, 0.0, 0.7)
const _LOCAL_RING: Color = Color(1.0, 1.0, 1.0, 0.95)

const _PLAYER_DOT_RADIUS: float = 3.5
const _GOALIE_DOT_RADIUS: float = 3.0
const _PUCK_DOT_RADIUS: float = 2.5

var _ice_width_px: float = 0.0   # short (X) axis, derived from rink aspect
var _bg_style: StyleBoxFlat = null
var _ice_style: StyleBoxFlat = null

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_contents = true  # keep an off-rink actor (tutorial stash, corner) inside the frame
	_ice_width_px = _ICE_LENGTH_PX * GameRules.RINK_HALF_WIDTH / GameRules.RINK_HALF_LENGTH

	# Anchored to the bottom-left corner of the (scalable) HUD chrome — the one
	# screen corner the existing chrome leaves clear (scorebug top-left, bug icon
	# / skip prompt / version bottom-right, chyron + menu hint bottom-center).
	var w: float = _ice_width_px + _MARGIN * 2.0
	var h: float = _ICE_LENGTH_PX + _MARGIN * 2.0
	anchor_left = 0.0
	anchor_right = 0.0
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 8.0
	offset_right = 8.0 + w
	offset_top = -(8.0 + h)
	offset_bottom = -8.0

	_bg_style = StyleBoxFlat.new()
	_bg_style.bg_color = _BG_COLOR
	_bg_style.set_corner_radius_all(6)
	_bg_style.border_color = _BORDER_COLOR
	_bg_style.set_border_width_all(1)
	_bg_style.anti_aliasing = false

	# Ice bed: a rounded rect whose corner radius is the REAL rink corner radius
	# (GameRules.CORNER_RADIUS, 8.53 m) mapped through the map scale, so the map's
	# corners bow exactly like the boards do instead of reading as a square. Scale
	# is uniform (see _ice_width_px derivation), so the world's circular corner
	# stays circular here. A thin border traces the rounded shape as the boards.
	var px_per_m: float = _ICE_LENGTH_PX / (GameRules.RINK_HALF_LENGTH * 2.0)
	var corner_px: int = int(round(GameRules.CORNER_RADIUS * px_per_m))
	_ice_style = StyleBoxFlat.new()
	_ice_style.bg_color = _ICE_COLOR
	_ice_style.set_corner_radius_all(corner_px)
	_ice_style.border_color = _BORDER_COLOR
	_ice_style.set_border_width_all(1)
	_ice_style.anti_aliasing = false

func _process(_delta: float) -> void:
	# Only churn a redraw when the map is actually shown. Disabled or in a replay,
	# _draw early-returns anyway — skip the queue so it costs literally nothing.
	if PlayerPrefs.minimap_enabled and not NetworkManager.is_replay_mode():
		queue_redraw()

func _draw() -> void:
	if not PlayerPrefs.minimap_enabled:
		return
	# Replay cuts to broadcast cameras with no local player, so there's no "attack
	# direction" to orient by — same bail as OffScreenPlayerIndicators.
	if NetworkManager.is_replay_mode():
		return

	var flip: bool = _local_attack_up_flip()

	# Frame + ice bed.
	draw_style_box(_bg_style, Rect2(Vector2.ZERO, size))
	var ice_rect := Rect2(Vector2(_MARGIN, _MARGIN), Vector2(_ice_width_px, _ICE_LENGTH_PX))
	draw_style_box(_ice_style, ice_rect)

	# Zone lines run across the short axis (constant world Z → constant map Y).
	_draw_zone_line(0.0, flip, _CENTER_LINE_COLOR, 1.5)
	_draw_zone_line(GameRules.BLUE_LINE_Z, flip, _BLUE_LINE_COLOR, 1.5)
	_draw_zone_line(-GameRules.BLUE_LINE_Z, flip, _BLUE_LINE_COLOR, 1.5)
	_draw_zone_line(GameRules.GOAL_LINE_Z, flip, _GOAL_LINE_COLOR, 1.0)
	_draw_zone_line(-GameRules.GOAL_LINE_Z, flip, _GOAL_LINE_COLOR, 1.0)

	# Nets — a short team-tinted bar across the mouth at each goal line.
	for goal: HockeyGoal in GameManager.goals:
		if not is_instance_valid(goal):
			continue
		var net_color: Color = _team_color(goal.defending_team_id)
		var gz: float = goal.global_position.z
		var a: Vector2 = _map_point(-GameRules.NET_HALF_WIDTH, gz, flip)
		var b: Vector2 = _map_point(GameRules.NET_HALF_WIDTH, gz, flip)
		draw_line(a, b, net_color, 3.0)

	# Goalies (defending-team tint), then skaters, then the puck on top.
	for goalie: Goalie in GameManager.goalies:
		if not is_instance_valid(goalie):
			continue
		var gpos: Vector2 = _map_point(goalie.global_position.x, goalie.global_position.z, flip)
		_draw_dot(gpos, _GOALIE_DOT_RADIUS, _goalie_team_color(goalie.global_position.z), false)

	var players: Dictionary[int, PlayerRecord] = GameManager.get_players()
	for peer_id: int in players:
		var record: PlayerRecord = players[peer_id]
		if record == null or record.skater == null:
			continue
		var pos: Vector2 = _map_point(record.skater.global_position.x, record.skater.global_position.z, flip)
		_draw_dot(pos, _PLAYER_DOT_RADIUS, record.jersey_color, record.is_local)

	var puck: Puck = GameManager.puck
	if puck != null and is_instance_valid(puck):
		var ppos: Vector2 = _map_point(puck.global_position.x, puck.global_position.z, flip)
		draw_circle(ppos, _PUCK_DOT_RADIUS + 1.0, _PUCK_OUTLINE)
		draw_circle(ppos, _PUCK_DOT_RADIUS, _PUCK_FILL)

# Maps a world XZ position into map-local pixels. Base orientation matches the
# unflipped camera (world +X → right, world +Z → down); the attack-up flip
# negates both axes, exactly like the camera's 180° yaw.
func _map_point(world_x: float, world_z: float, flip: bool) -> Vector2:
	var nx: float = world_x / GameRules.RINK_HALF_WIDTH
	var nz: float = world_z / GameRules.RINK_HALF_LENGTH
	if flip:
		nx = -nx
		nz = -nz
	var cx: float = _MARGIN + _ice_width_px * 0.5
	var cy: float = _MARGIN + _ICE_LENGTH_PX * 0.5
	return Vector2(cx + nx * _ice_width_px * 0.5, cy + nz * _ICE_LENGTH_PX * 0.5)

# A zone line spanning the rink's width at a constant world Z. Blue/center lines
# sit in the straight-wall middle, so they run the full width; the goal lines sit
# past the corner center, so this insets them to the curved boards' actual width
# there — otherwise they'd poke into the rounded-off corner void.
func _draw_zone_line(world_z: float, flip: bool, color: Color, width: float) -> void:
	var hw: float = _rink_half_width_at_z(world_z)
	var a: Vector2 = _map_point(-hw, world_z, flip)
	var b: Vector2 = _map_point(hw, world_z, flip)
	draw_line(a, b, color, width)

# The rink's half-width at a given world Z, following the rounded corners: full
# width through the straight middle, shrinking along the corner arc past the
# corner center. Mirrors the board geometry in GameRules.clamp_to_rink_inner but
# on the outer (board) dimensions.
func _rink_half_width_at_z(world_z: float) -> float:
	var az: float = absf(world_z)
	var corner_center_z: float = GameRules.RINK_HALF_LENGTH - GameRules.CORNER_RADIUS
	if az <= corner_center_z:
		return GameRules.RINK_HALF_WIDTH
	var dz: float = minf(az - corner_center_z, GameRules.CORNER_RADIUS)
	var inner: float = sqrt(GameRules.CORNER_RADIUS * GameRules.CORNER_RADIUS - dz * dz)
	return (GameRules.RINK_HALF_WIDTH - GameRules.CORNER_RADIUS) + inner

func _draw_dot(pos: Vector2, radius: float, fill: Color, is_local: bool) -> void:
	draw_circle(pos, radius + 1.0, _DOT_OUTLINE)
	draw_circle(pos, radius, fill)
	if is_local:
		draw_arc(pos, radius + 2.5, 0.0, TAU, 20, _LOCAL_RING, 1.5, true)

# True when the camera is (or would be) yaw-flipped for the local player: the
# "Always Attack Up" pref on and the local player on team 1. Mirrors the exact
# condition in GameCamera. Spectators / no local record → no flip.
func _local_attack_up_flip() -> bool:
	if not PlayerPrefs.attack_up:
		return false
	var record: PlayerRecord = GameManager.get_local_player()
	if record == null or record.team == null:
		return false
	return record.team.team_id == 1

# Tint a goalie by the team defending the goal it's nearest to — a goalie lives
# in its own crease, so the closest goal line is the one it defends. Robust to
# the goalies[] ordering (which doesn't carry a team id).
func _goalie_team_color(goalie_z: float) -> Color:
	var best_goal: HockeyGoal = null
	var best_dist: float = INF
	for goal: HockeyGoal in GameManager.goals:
		if not is_instance_valid(goal):
			continue
		var d: float = absf(goal.global_position.z - goalie_z)
		if d < best_dist:
			best_dist = d
			best_goal = goal
	if best_goal == null:
		return Color(0.6, 0.6, 0.6)
	return _team_color(best_goal.defending_team_id)

# Defending-team primary color for net / goalie tinting; grey fallback before
# teams are wired.
func _team_color(team_id: int) -> Color:
	if team_id >= 0 and team_id < GameManager.teams.size():
		var colors: Dictionary = TeamColorRegistry.get_colors(
				GameManager.teams[team_id].color_slot, team_id)
		return colors.primary
	return Color(0.6, 0.6, 0.6)
