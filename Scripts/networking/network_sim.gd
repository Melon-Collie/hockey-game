extends Node

# delay_ms is one-way. Enable on both host and client for full RTT simulation.
# e.g. delay_ms=50 on both peers → ~100ms RTT.
var enabled: bool = false
var delay_ms: float = 0.0
var jitter_ms: float = 0.0
var loss_pct: float = 0.0
var current_preset: int = 0  # 0 = off, 1–5 = increasing degradation

const PRESETS: Array[Dictionary] = [
	{ delay = 0.0,   jitter = 0.0,  loss = 0.0  },  # 0: Off
	{ delay = 5.0,   jitter = 2.0,  loss = 0.0  },  # 1: LAN          (~10ms RTT)
	{ delay = 10.0,  jitter = 3.0,  loss = 0.0  },  # 2: Regional     (~20ms RTT, e.g. Dallas–Houston)
	{ delay = 20.0,  jitter = 5.0,  loss = 0.0  },  # 3: Coast        (~40ms RTT, e.g. LA–Chicago)
	{ delay = 50.0,  jitter = 8.0,  loss = 1.0  },  # 4: Average      (~100ms RTT, stable)
	{ delay = 75.0,  jitter = 20.0, loss = 6.0  },  # 5: Poor         (~150ms RTT, choppy)
	{ delay = 100.0, jitter = 25.0, loss = 12.0 },  # 6: Bad          (~200ms RTT, rough)
]

class PendingPacket:
	var fire_time: float
	var callable: Callable
	var args: Array

var _pending: Array[PendingPacket] = []
# ENet preserves reliable-RPC order per connection. Without this clamp,
# independently-jittered fire_times can put a later-sent reliable packet
# ahead of an earlier-sent one — test runs under NetworkSim would see
# orderings that can't happen in production. Tracked globally rather than
# per-peer for simplicity; over-strict in a multi-client scenario (a
# reliable to A would serialize a near-simultaneous reliable to B) but
# never under-strict. Reset alongside `_pending` whenever sim state clears.
var _last_reliable_fire_time: float = 0.0

func send(c: Callable, args: Array, reliable: bool) -> void:
	if not enabled:
		c.callv(args)
		return
	if not reliable and randf() * 100.0 < loss_pct:
		return
	var jitter := randf_range(0.0, jitter_ms * 2.0)
	var d := maxf((delay_ms + jitter) / 1000.0, 0.0)
	if d <= 0.0:
		c.callv(args)
		return
	var nominal_fire_time := Time.get_ticks_msec() / 1000.0 + d
	var p := PendingPacket.new()
	if reliable:
		p.fire_time = maxf(nominal_fire_time, _last_reliable_fire_time)
		_last_reliable_fire_time = p.fire_time
	else:
		p.fire_time = nominal_fire_time
	p.callable = c
	p.args = args
	_pending.append(p)

func _unhandled_input(event: InputEvent) -> void:
	# Preset hotkeys are dev-only — they inject artificial delay/jitter/loss
	# that's only useful for testing. In exported builds the keys are ignored
	# so a player can't accidentally hit one and break their session.
	if BuildInfo.VERSION != "dev":
		return
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var preset: int = -1
	match event.keycode:
		KEY_0: preset = 0
		KEY_1: preset = 1
		KEY_2: preset = 2
		KEY_3: preset = 3
		KEY_4: preset = 4
		KEY_5: preset = 5
		KEY_6: preset = 6
	if preset == -1:
		return
	apply_preset(preset)

func clear_pending() -> void:
	_pending.clear()
	_last_reliable_fire_time = 0.0

func apply_preset(preset: int) -> void:
	current_preset = preset
	var p: Dictionary = PRESETS[preset]
	enabled = preset > 0
	delay_ms = p.delay
	jitter_ms = p.jitter
	loss_pct = p.loss
	if not enabled:
		clear_pending()

func _process(_delta: float) -> void:
	if _pending.is_empty():
		return
	var now := Time.get_ticks_msec() / 1000.0
	var i := 0
	while i < _pending.size():
		if _pending[i].fire_time <= now:
			_pending[i].callable.callv(_pending[i].args)
			_pending.remove_at(i)
		else:
			i += 1
