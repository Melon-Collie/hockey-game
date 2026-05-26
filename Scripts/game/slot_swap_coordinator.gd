class_name SlotSwapCoordinator
extends RefCounted

# Validates and applies mid-game slot swaps. Split out of GameManager because
# the request / confirmation flow is a self-contained feature.
#
# Flow:
#   host: request_swap(peer_id, new_team_id, new_slot, carrier)
#           → validates via GameStateMachine.try_swap_slot
#           → returns a confirmation dict (caller broadcasts via NetworkManager)
#           → signals carrier_swap_needs_drop if the swapping player held the puck
#   all peers: apply_confirmed_swap(...)  → mutates PlayerRecord + teleports

signal stats_updated
signal carrier_swap_needs_drop

var _registry: PlayerRegistry = null
var _state_machine: GameStateMachine = null
var _teams: Array[Team] = []


func setup(
		registry: PlayerRegistry,
		state_machine: GameStateMachine,
		teams: Array[Team]) -> void:
	_registry = registry
	_state_machine = state_machine
	_teams = teams


# Host-only: validates a swap request. Returns the confirmation data (to be
# broadcast via NetworkManager) or an empty dict if the swap is rejected.
# If the requesting player holds the puck, `carrier_swap_needs_drop` fires so
# the caller can drop the puck before the swap is finalized.
func request_swap(
		peer_id: int,
		new_team_id: int,
		new_slot: int,
		puck_carrier: Skater) -> Dictionary:
	if _state_machine == null:
		return {}
	var result: Dictionary = _state_machine.try_swap_slot(peer_id, new_team_id, new_slot)
	if result.is_empty():
		return {}
	var record: PlayerRecord = _registry.get_record(peer_id)
	if record != null and puck_carrier != null and record.skater == puck_carrier:
		carrier_swap_needs_drop.emit()
	var jersey: Color
	var helmet: Color
	var pants: Color
	if new_team_id != result.old_team_id:
		var colors: Dictionary = TeamColorRegistry.get_colors(_teams[new_team_id].color_slot, new_team_id)
		jersey = colors.jersey
		helmet = colors.helmet
		pants  = colors.pants
	else:
		jersey = record.jersey_color
		helmet = record.helmet_color
		pants  = record.pants_color
	return {
		"old_team_id": result.old_team_id,
		"old_slot":    result.old_slot,
		"new_team_id": new_team_id,
		"new_slot":    new_slot,
		"jersey":      jersey,
		"helmet":      helmet,
		"pants":       pants,
	}


# Applied on all peers when the confirmation RPC arrives (and locally on the
# host after its own broadcast). Safe to call even if the state_machine is
# already in sync — register_remote_assigned_player overwrites idempotently.
func apply_confirmed_swap(
		peer_id: int,
		_old_team_id: int,
		_old_slot: int,
		new_team_id: int,
		new_slot: int,
		jersey: Color,
		helmet: Color,
		pants: Color) -> void:
	if not _registry.has(peer_id):
		return
	if _state_machine != null:
		_state_machine.register_remote_assigned_player(peer_id, new_slot, new_team_id)
	var record: PlayerRecord = _registry.get_record(peer_id)
	var colors: Dictionary = TeamColorRegistry.get_colors(_teams[new_team_id].color_slot, new_team_id)
	record.team               = _teams[new_team_id]
	record.team_slot          = new_slot
	# Keep the hot-path team lookup tables in sync with the new
	# assignment. AI dispatch + puck poke-check read from these.
	_registry.team_id_by_peer[peer_id] = new_team_id
	if record.skater != null:
		_registry.team_id_by_skater[record.skater] = new_team_id
	record.jersey_color        = jersey
	record.helmet_color        = helmet
	record.pants_color         = pants
	record.jersey_stripe_color = colors.jersey_stripe
	record.gloves_color        = colors.gloves
	record.pants_stripe_color  = colors.pants_stripe
	record.socks_color         = colors.socks
	record.socks_stripe_color  = colors.socks_stripe
	record.secondary_color     = colors.secondary
	record.text_color          = colors.text
	record.text_outline_color  = colors.text_outline
	# Skater.get_team_id() resolves through the registry (record.team.team_id),
	# so the team write above is the single source of truth — no node-level
	# field needs re-syncing here.
	record.skater.set_player_color(jersey, helmet, pants, colors.socks, colors.primary, colors.gloves)
	record.skater.set_player_name(record.player_name)
	record.skater.set_jersey_info(record.player_name, record.jersey_number, colors.text, colors.text_outline)
	record.skater.set_jersey_stripes(colors.jersey_stripe, colors.pants_stripe, colors.socks_stripe)
	# LocalController caches the local player's team for offside prediction,
	# camera orientation, and attack-up. Without this the local skater would
	# be flagged offside in its new zone and the camera would still face the
	# old direction. RemoteController doesn't store team_id.
	if record.is_local and record.controller is LocalController:
		(record.controller as LocalController).set_local_team_id(new_team_id)
	# Square up to the new attacking goal — without facing, a cross-team
	# swap leaves the skater pointing backwards on their first frame.
	record.controller.teleport_to(
			PlayerRules.faceoff_position(new_team_id, new_slot),
			PlayerRules.faceoff_facing(new_team_id))
	stats_updated.emit()
