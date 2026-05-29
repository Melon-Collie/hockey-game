class_name ActorSpawner
extends RefCounted

# Infrastructure factory. Owns PackedScene.instantiate() and add_child() — the
# engine-integration details that GameManager doesn't need to spell out.
#
# Returns raw node refs; game-level wiring (resolver injection, signal
# connections, NetworkManager registration, players-dict population) stays in
# GameManager, which is where the relevant state lives.

const PUCK_SCENE: PackedScene = preload("res://Scenes/Puck.tscn")
const SKATER_SCENE: PackedScene = preload("res://Scenes/Skater.tscn")
const GOALIE_SCENE: PackedScene = preload("res://Scenes/Goalie.tscn")
const LOCAL_CONTROLLER_SCENE: PackedScene = preload("res://Scenes/LocalController.tscn")
const REMOTE_CONTROLLER_SCENE: PackedScene = preload("res://Scenes/RemoteController.tscn")
const AI_CONTROLLER_SCENE: PackedScene = preload("res://Scenes/AIController.tscn")

var _scene_root: Node = null

func setup(scene_root: Node) -> void:
	_scene_root = scene_root

# ── Goals (already placed in the scene by the rink — we just sort them) ──────
func find_goals() -> Array[HockeyGoal]:
	var goals: Array[HockeyGoal] = []
	# Recursive: goals live under the RinkArena instance, not the scene root.
	for node in _scene_root.find_children("*", "HockeyGoal", true, false):
		if node is HockeyGoal:
			goals.append(node)
	# goals[0] is facing=-1 (negative-Z, Team 1 defends)
	# goals[1] is facing=+1 (positive-Z, Team 0 defends)
	goals.sort_custom(func(a: HockeyGoal, b: HockeyGoal) -> bool: return a.facing < b.facing)
	return goals

# ── Puck + PuckController ────────────────────────────────────────────────────
# Returns { "puck": Puck, "controller": PuckController }.
func spawn_puck_with_controller(is_server: bool) -> Dictionary:
	var puck: Puck = PUCK_SCENE.instantiate()
	puck.position = GameRules.PUCK_START_POS
	_scene_root.add_child(puck)
	var controller := PuckController.new()
	_scene_root.add_child(controller)
	controller.setup(puck, is_server)
	return {"puck": puck, "controller": controller}

# ── Goalies (both nets, with controllers) ────────────────────────────────────
# Returns {
#   "top_goalie", "bottom_goalie",           # Goalie nodes
#   "top_controller", "bottom_controller",   # GoalieControllers
# }
# Top defends the negative-Z goal (Team 1's end), bottom defends positive-Z
# (Team 0's end).
func spawn_goalie_pair(puck: Puck, is_server: bool) -> Dictionary:
	var top: Goalie = GOALIE_SCENE.instantiate()
	var bottom: Goalie = GOALIE_SCENE.instantiate()
	_scene_root.add_child(top)
	_scene_root.add_child(bottom)
	var top_controller := GoalieController.new()
	var bottom_controller := GoalieController.new()
	_scene_root.add_child(top_controller)
	_scene_root.add_child(bottom_controller)
	top_controller.setup(top, puck, -GameRules.GOAL_LINE_Z, is_server)
	bottom_controller.setup(bottom, puck, GameRules.GOAL_LINE_Z, is_server)
	return {
		"top_goalie": top,
		"bottom_goalie": bottom,
		"top_controller": top_controller,
		"bottom_controller": bottom_controller,
	}

# ── Local player (skater + LocalController) ──────────────────────────────────
# Returns { "skater": Skater, "controller": LocalController }. Caller is
# responsible for calling skater.set_uniform() + skater.set_jersey_info()
# after spawn — coloring is no longer applied here so the v2 uniform paint
# happens in one place (PlayerRegistry / GameManager mid-game flow).
func spawn_local_player(
		position: Vector3,
		is_left_handed: bool,
		puck: Puck,
		game_state: Node,
		team_id: int,
		attributes: PlayerAttributes = null) -> Dictionary:
	var skater: Skater = SKATER_SCENE.instantiate()
	skater.is_left_handed = is_left_handed  # must be set before add_child so _ready sees it
	skater.position = position
	_scene_root.add_child(skater)
	var controller: LocalController = LOCAL_CONTROLLER_SCENE.instantiate()
	_scene_root.add_child(controller)
	controller.setup(skater, puck, game_state)
	controller.set_local_team_id(team_id)
	controller.apply_attributes(attributes if attributes != null else PlayerAttributes.all_medium())
	return {"skater": skater, "controller": controller}

# ── AI player (skater + AIController) ────────────────────────────────────────
# Host-only. Same skater spawn as a remote player; only the controller class
# differs. Clients render this skater through their own RemoteController
# instance (spawned via the existing remote-skater RPC), so this method has
# no client-side counterpart.
# Returns { "skater": Skater, "controller": AIController }.
func spawn_ai_player(
		position: Vector3,
		is_left_handed: bool,
		puck: Puck,
		game_state: Node,
		attributes: PlayerAttributes = null) -> Dictionary:
	var skater: Skater = SKATER_SCENE.instantiate()
	skater.is_left_handed = is_left_handed
	skater.position = position
	_scene_root.add_child(skater)
	var controller: AIController = AI_CONTROLLER_SCENE.instantiate()
	_scene_root.add_child(controller)
	controller.setup(skater, puck, game_state)
	controller.apply_attributes(attributes if attributes != null else PlayerAttributes.all_medium())
	return {"skater": skater, "controller": controller}

# ── Remote player (skater + RemoteController) ────────────────────────────────
# Returns { "skater": Skater, "controller": RemoteController }.
func spawn_remote_player(
		position: Vector3,
		is_left_handed: bool,
		puck: Puck,
		game_state: Node,
		attributes: PlayerAttributes = null) -> Dictionary:
	var skater: Skater = SKATER_SCENE.instantiate()
	skater.is_left_handed = is_left_handed  # must be set before add_child so _ready sees it
	skater.position = position
	_scene_root.add_child(skater)
	var controller: RemoteController = REMOTE_CONTROLLER_SCENE.instantiate()
	_scene_root.add_child(controller)
	controller.setup(skater, puck, game_state)
	controller.apply_attributes(attributes if attributes != null else PlayerAttributes.all_medium())
	return {"skater": skater, "controller": controller}
