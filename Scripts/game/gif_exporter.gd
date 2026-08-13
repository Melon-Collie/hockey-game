class_name GifExporter
extends Node

# Encodes captured clip frames to an animated GIF on a worker thread and
# writes it to user://clips/.
#
# The encode itself is NativeGifEncoder (native/src/native_gif_encoder.cpp) —
# palette quantization plus LZW over ~150 frames is seconds of work in
# GDScript and well under one in C++. Without the extension built the feature
# is simply absent (is_available() false) rather than degraded, so nothing
# pays the capture cost for an export that can't happen.
#
# Threaded because even the native encode is tens of milliseconds to a few
# hundred, and it runs while the game is live — the post-game reel keeps
# looping and, in an online lobby, the goal cinematic's end is a synchronized
# moment nobody's frame budget should stall on.

const CLIP_DIR: String = "user://clips/"
const CLIP_EXT: String = ".gif"
# Bounds the folder. Oldest goes first, and the purge runs before the new file
# is written so it can never be the one deleted.
const MAX_CLIPS_KEPT: int = 60
# Error-diffusion dithering trades file size for smoother gradients. Off: the
# rink is mostly flat ice, where the dither pattern re-randomizes every frame
# and inflates the LZW stream (it defeats run-length matching) for a
# difference nobody sees at 480x270.
const DITHER: bool = false

# ok = false covers a missing extension, a rejected frame, an empty encode,
# and a failed write; path is empty in those cases.
signal export_finished(path: String, ok: bool)

var _thread: Thread = null
var _frames: Array[Image] = []
var _fps: int = 20
var _out_path: String = ""
var _result_ok: bool = false


func _ready() -> void:
	# Only ticks while an encode is in flight — _process exists solely to notice
	# the worker thread finishing.
	set_process(false)


static func is_available() -> bool:
	return ClassDB.class_exists(&"NativeGifEncoder")


func is_busy() -> bool:
	return _thread != null


# Queues an encode. Returns false when one is already running or the input is
# unusable — the caller decides what to tell the player.
func export_frames(frames: Array[Image], fps: int, label: String) -> bool:
	if is_busy() or frames.is_empty() or not is_available():
		return false
	_frames = frames
	_fps = maxi(1, fps)
	_out_path = _next_path(label)
	_result_ok = false
	_thread = Thread.new()
	if _thread.start(_run) != OK:
		_thread = null
		_frames = []
		return false
	set_process(true)
	return true


func _run() -> void:
	var encoder: RefCounted = ClassDB.instantiate(&"NativeGifEncoder")
	if encoder == null:
		return
	var size: Vector2i = _frames[0].get_size()
	# GIF delays are in 1/100 s; the encoder clamps the floor.
	var delay_cs: int = int(round(100.0 / float(_fps)))
	encoder.configure(size.x, size.y, delay_cs, DITHER)
	for i: int in _frames.size():
		var img: Image = _frames[i]
		if img == null:
			continue
		if not bool(encoder.add_frame(img)):
			_frames = []
			return
		# Drop our reference as we go: the encoder now holds its own RGB copy,
		# so this keeps peak memory at roughly one buffer instead of two.
		_frames[i] = null
	_frames = []

	var bytes: PackedByteArray = encoder.encode()
	if bytes.is_empty():
		return

	if not DirAccess.dir_exists_absolute(CLIP_DIR):
		DirAccess.make_dir_recursive_absolute(CLIP_DIR)
	_purge_oldest(MAX_CLIPS_KEPT - 1)
	var file: FileAccess = FileAccess.open(_out_path, FileAccess.WRITE)
	if file == null:
		push_error("GifExporter: failed to open %s (err %d)"
				% [_out_path, FileAccess.get_open_error()])
		return
	file.store_buffer(bytes)
	file.close()
	_result_ok = true


func _process(_delta: float) -> void:
	if _thread == null or _thread.is_alive():
		return
	_thread.wait_to_finish()
	_thread = null
	set_process(false)
	var path: String = _out_path if _result_ok else ""
	_out_path = ""
	export_finished.emit(path, _result_ok)


func _exit_tree() -> void:
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func _next_path(label: String) -> String:
	var now: Dictionary = Time.get_datetime_dict_from_system()
	var stamp: String = "%04d-%02d-%02d_%02d-%02d-%02d" % [
		now.year, now.month, now.day, now.hour, now.minute, now.second,
	]
	var slug: String = _slugify(label)
	var name: String = "%s_%s" % [stamp, slug] if not slug.is_empty() else stamp
	return CLIP_DIR.path_join("goal_%s%s" % [name, CLIP_EXT])


# Scorer names reach the filename, so strip anything a filesystem would
# object to rather than trusting a display name to be path-safe.
static func _slugify(text: String) -> String:
	var out: String = ""
	for c: String in text.to_lower():
		if (c >= "a" and c <= "z") or (c >= "0" and c <= "9"):
			out += c
		elif (c == " " or c == "-" or c == "_") and not out.ends_with("-"):
			out += "-"
	return out.trim_suffix("-").substr(0, 32)


# Deletes oldest-first until at most `keep` files remain.
static func _purge_oldest(keep: int) -> void:
	var dir: DirAccess = DirAccess.open(CLIP_DIR)
	if dir == null:
		return
	var paths: Array[String] = []
	var mtime_by_path: Dictionary[String, int] = {}
	dir.list_dir_begin()
	var name: String = dir.get_next()
	while not name.is_empty():
		if not dir.current_is_dir() and name.ends_with(CLIP_EXT):
			var path: String = CLIP_DIR.path_join(name)
			paths.append(path)
			mtime_by_path[path] = FileAccess.get_modified_time(path)
		name = dir.get_next()
	dir.list_dir_end()
	if paths.size() <= keep:
		return
	paths.sort_custom(func(a: String, b: String) -> bool:
		return mtime_by_path[a] > mtime_by_path[b])
	for i: int in range(keep, paths.size()):
		DirAccess.remove_absolute(paths[i])
