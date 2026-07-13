extends Node

func _ready() -> void:
	PlayerPrefs.apply_video()
	NetworkManager.on_game_scene_ready()
	if NetworkManager.is_tutorial_mode:
		var id: String = NetworkManager.tutorial_id if not NetworkManager.tutorial_id.is_empty() else TutorialRegistry.MOVEMENT_ID
		add_child(preload("res://Scripts/game/tutorial_manager.gd").new(id))
	if not NetworkManager.drill_id.is_empty():
		var manager_path: String = DrillRegistry.get_manager_path(NetworkManager.drill_id)
		if manager_path.is_empty():
			push_error("game_scene: unknown drill id '%s'" % NetworkManager.drill_id)
		else:
			var manager_script: GDScript = load(manager_path)
			add_child(manager_script.new())
	if not NetworkManager.is_host and not NetworkManager.pending_join_slot.is_empty():
		var s: Dictionary = NetworkManager.pending_join_slot
		NetworkManager.pending_join_slot = {}
		NetworkManager.slot_assigned.emit(s.team_slot, s.team_id, s.jersey_color, s.helmet_color, s.pants_color)
		if not NetworkManager.pending_join_players.is_empty():
			var players: Array = NetworkManager.pending_join_players
			NetworkManager.pending_join_players = []
			NetworkManager.existing_players_synced.emit(players)
