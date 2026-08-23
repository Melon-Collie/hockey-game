class_name CrowdAudioController
extends Node

# Drives crowd audio: a looping ambient murmur that rides the danger on the ice,
# plus cheer one-shots on goals and period/game-end buzzers. Both stream types
# route through the dedicated "Arena" audio bus (created by SoundManager, shared
# with the horn/buzzer/whistle one-shots) so a single PlayerPrefs slider controls
# overall arena atmosphere independently of gameplay SFX.
#
# SoundManager stays one-shot-only — the looping ambient player and the small
# cheer pool both live here, mirroring how SkaterSoundController owns its own
# skate-loop AudioStreamPlayer3D.

@export var ambient_stream_path: String = "res://Sounds/crowd_ambient.wav"
@export var cheer_stream_path: String = "res://Sounds/crowd_cheer.wav"
@export var ambient_volume_db: float = -22.0
@export var cheer_volume_db: float = -7.0
@export var duck_volume_db: float = -10.0
@export var duck_recover_time: float = 4.0
# Stoppage "settle": a brief murmur swell above ambient when the whistle blows,
# easing back to baseline — so a whistle doesn't drop into dead air. Smaller and
# gentler than a goal cheer (no separate one-shot; just rides the ambient bed).
@export var settle_swell_db: float = 6.0
@export var settle_rise_time: float = 0.2
@export var settle_recover_time: float = 2.5

# ── Live energy ──────────────────────────────────────────────────────────────
# The bed tracks how good a chance the puck is sitting on rather than sitting
# flat between events (CrowdEnergyRules): a rush swells it, a cycle keeps it
# warm, a clear lets it settle. Peak swell sits above the whistle's, so the
# loudest thing in the building is still a live scoring chance.
var energy_swell_db: float = 8.0

var _energy: float = 0.0
var _pressure: float = 0.0
# -1 until GameManager announces one — no phase means no live play to read.
var _phase: int = -1

const _CHEER_POOL_SIZE: int = 3
const _ARENA_BUS: StringName = &"Arena"

var _ambient_player: AudioStreamPlayer = null
var _cheer_pool: Array[AudioStreamPlayer] = []
var _cheer_stream: AudioStream = null
var _tween: Tween = null


func _ready() -> void:
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.bus = _ARENA_BUS
	_ambient_player.volume_db = ambient_volume_db
	add_child(_ambient_player)

	if ResourceLoader.exists(ambient_stream_path):
		var stream: AudioStream = load(ambient_stream_path)
		# Defensive: if the .ogg wasn't marked looping in the import dock,
		# nudge it here so the ambient doesn't go silent after one play.
		if stream is AudioStreamOggVorbis:
			(stream as AudioStreamOggVorbis).loop = true
		_ambient_player.stream = stream
		_ambient_player.finished.connect(_on_ambient_finished)
		_ambient_player.play()

	if ResourceLoader.exists(cheer_stream_path):
		_cheer_stream = load(cheer_stream_path)
	for i: int in _CHEER_POOL_SIZE:
		var p: AudioStreamPlayer = AudioStreamPlayer.new()
		p.bus = _ARENA_BUS
		add_child(p)
		_cheer_pool.append(p)

	var gm: Node = get_node_or_null("/root/GameManager")
	if gm != null:
		if gm.has_signal("goal_scored"):
			gm.goal_scored.connect(_on_goal_scored)
		if gm.has_signal("phase_changed"):
			gm.phase_changed.connect(_on_phase_changed)
		# Whistle stoppages — a small crowd murmur so the dead-play beat has life.
		for sig: String in ["icing_called", "offside_called", "puck_out_of_play"]:
			if gm.has_signal(sig):
				gm.connect(sig, settle)


# Safety net: a properly-looping AudioStream won't emit `finished`, but this
# catches the case where the import-dock loop flag wasn't set on the file.
func _on_ambient_finished() -> void:
	if _ambient_player != null and _ambient_player.stream != null:
		_ambient_player.play()


func _on_goal_scored(_scoring_team: Variant, _scorer: String, _a1: String, _a2: String) -> void:
	_cheer()


func _on_phase_changed(new_phase: int) -> void:
	_phase = new_phase
	if new_phase == GamePhase.Phase.END_OF_PERIOD or new_phase == GamePhase.Phase.GAME_OVER:
		_cheer()


# Cosmetic, and sharing no spatial relationship with anything drawn, so it runs
# at render rate rather than on the tick.
func _process(delta: float) -> void:
	_advance_energy(delta)


func _advance_energy(delta: float) -> void:
	if _ambient_player == null or _ambient_player.stream == null:
		return
	var live: bool = false
	var sustained: bool = false
	var chance: float = 0.0
	if _phase == GamePhase.Phase.PLAYING:
		var puck: Puck = GameManager.get_puck()
		if is_instance_valid(puck):
			live = true
			var carrier: Skater = GameManager.get_puck_carrier()
			var carrier_team: int = carrier.get_team_id() if carrier != null else -1
			var pos: Vector3 = puck.global_position
			sustained = CrowdEnergyRules.is_sustaining_pressure(pos.z, carrier_team)
			chance = CrowdEnergyRules.chance(pos.x, pos.z, carrier_team)
	_pressure = CrowdEnergyRules.advance_pressure(_pressure, sustained, delta)
	# A dead puck targets silence outright rather than the decaying pressure:
	# whatever the shift had built, the whistle ended it, and the settle swell
	# is what covers the beat after.
	var target: float = CrowdEnergyRules.target_energy(chance, _pressure) if live else 0.0
	_energy = CrowdEnergyRules.advance_energy(_energy, target, delta)
	# A goal duck or a whistle swell owns the bed while it runs: those are the
	# crowd reacting to something that just happened, which outranks the ambient
	# read of a live play. Both tweens land back on ambient_volume_db, and the
	# energy has decayed through the dead phase by then, so the handover is
	# silent.
	if _tween != null and _tween.is_valid():
		return
	_ambient_player.volume_db = ambient_volume_db + _energy * energy_swell_db


# Public trigger for a crowd cheer + ambient duck. The replay viewer calls this
# off recorded goal events, since the live GameManager.goal_scored signal that
# normally drives _on_goal_scored doesn't fire during offline playback.
func cheer() -> void:
	_cheer()


func _cheer() -> void:
	if _cheer_stream != null:
		for p: AudioStreamPlayer in _cheer_pool:
			if not p.playing:
				p.stream = _cheer_stream
				p.volume_db = cheer_volume_db
				p.pitch_scale = randf_range(0.95, 1.05)
				p.play()
				break
	_duck_ambient()


func _duck_ambient() -> void:
	if _ambient_player == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_ambient_player, "volume_db", duck_volume_db, 0.15)
	_tween.tween_property(_ambient_player, "volume_db", ambient_volume_db, duck_recover_time)


# Brief crowd murmur swell on a whistle stoppage, easing back to baseline. Rides
# the ambient bed (no cheer one-shot) so it reads as the crowd reacting to the
# stop rather than celebrating. Shares _tween with the duck — last trigger wins,
# which is fine since a stoppage and a goal cheer never overlap.
func settle() -> void:
	if _ambient_player == null:
		return
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(_ambient_player, "volume_db",
			ambient_volume_db + settle_swell_db, settle_rise_time)
	_tween.tween_property(_ambient_player, "volume_db",
			ambient_volume_db, settle_recover_time)
