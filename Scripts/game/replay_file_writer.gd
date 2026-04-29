class_name ReplayFileWriter
extends RefCounted

# Streams broadcast frames (and small game-state events) to a .mreplay file
# via a dedicated background thread so per-frame disk writes never block the
# physics tick. Producer / consumer is mutex + semaphore: enqueue_frame /
# enqueue_event push completed records onto a queue and post the semaphore;
# the worker drains the queue on each wake.
#
# File format (.mreplay v1, magic "MREPLAY2"):
#   [ MAGIC "MREPLAY2"  : 8 bytes      ]    -- bumped from MREPLAY1 when the
#                                              version byte was added
#   [ FORMAT_VERSION    : u8           ]    -- currently 1; reader rejects others
#   [ HEADER LENGTH     : u32 LE       ]
#   [ HEADER JSON       : N bytes      ]    -- game_id, build_version, roster, …
#   ([ FRAME LENGTH     : u32 LE       ]
#    [ host_ts          : f32 LE       ]
#    [ kind             : u8           ]    -- KIND_WORLD_STATE | KIND_EVENT
#    [ payload          : (len-5) bytes])*
#   [ END_OF_RECORDS    : u32 LE = 0   ]    -- sentinel marking clean shutdown
#   [ FOOTER LENGTH     : u32 LE       ]
#   [ FOOTER JSON       : N bytes      ]
#
# Versioning: the magic distinguishes incompatible-format generations (a v1
# reader must reject a v2 file outright). The u8 version byte distinguishes
# additive evolutions within a magic family — a future v2 reader can fast-path
# skip-forward when the version is older. Bump the magic for breaking changes;
# bump the version byte for additive changes.
#
# Crash-safety: a process kill mid-write leaves the file without
# END_OF_RECORDS; the reader walks records until it can't read a full frame
# and reports `truncated = true`. Only the in-flight frame is lost.

# PackedByteArray() can't be a const expression in GDScript, so this is a
# `static var` initialized once at class load. Same access pattern
# (ReplayFileWriter.MAGIC) for callers.
static var MAGIC: PackedByteArray = PackedByteArray([77, 82, 69, 80, 76, 65, 89, 50])  # "MREPLAY2"
const FORMAT_VERSION: int = 1
const KIND_WORLD_STATE: int = 0
const KIND_EVENT: int = 1
const FRAME_INNER_HEADER_SIZE: int = 5  # host_ts (4) + kind (1)
const END_OF_RECORDS: int = 0

var _path: String = ""
var _file: FileAccess = null
var _thread: Thread = null
var _mutex: Mutex = null
var _semaphore: Semaphore = null
var _queue: Array[PackedByteArray] = []
var _shutdown: bool = false
# Set by the worker on the first store_buffer error (disk full, permission
# changed mid-write, etc). Read by the main thread after wait_to_finish so
# close_async can skip the footer write — the file is already truncated, and
# writing on top of a failed handle just produces more confusing artifacts.
# Mutex-guarded for the rare case where _enqueue races the worker.
var _write_failed: bool = false


func open(path: String, header: Dictionary) -> bool:
	_path = path
	var dir: String = path.get_base_dir()
	if not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	_file = FileAccess.open(path, FileAccess.WRITE)
	if _file == null:
		push_error("ReplayFileWriter: failed to open %s (err %d)" % [path, FileAccess.get_open_error()])
		return false
	_file.store_buffer(MAGIC)
	_file.store_8(FORMAT_VERSION)
	var header_bytes: PackedByteArray = JSON.stringify(header).to_utf8_buffer()
	_file.store_32(header_bytes.size())
	_file.store_buffer(header_bytes)
	_file.flush()
	# If the very first writes failed (e.g. disk already full), refuse to start
	# the worker thread so the caller can react to the failed open.
	if _file.get_error() != OK:
		push_error("ReplayFileWriter: header write failed for %s (err %d)" % [path, _file.get_error()])
		_file.close()
		_file = null
		return false
	_mutex = Mutex.new()
	_semaphore = Semaphore.new()
	_thread = Thread.new()
	_thread.start(_worker_loop)
	return true


func enqueue_frame(host_ts: float, payload: PackedByteArray) -> void:
	_enqueue(host_ts, KIND_WORLD_STATE, payload)


func enqueue_event(host_ts: float, payload: PackedByteArray) -> void:
	_enqueue(host_ts, KIND_EVENT, payload)


# Drains pending writes and writes the footer + EOF marker. Must be called
# from the main thread; blocks until the worker has flushed everything.
func close_async(footer: Dictionary) -> void:
	if _file == null:
		return
	_mutex.lock()
	_shutdown = true
	_mutex.unlock()
	_semaphore.post()
	_thread.wait_to_finish()
	_thread = null
	# Skip the EOF + footer if the worker reported a write failure: the file is
	# already partial, and writing more on top produces confusing artifacts. The
	# reader's truncation path (missing END_OF_RECORDS) handles this cleanly.
	if not _write_failed:
		_file.store_32(END_OF_RECORDS)
		var footer_bytes: PackedByteArray = JSON.stringify(footer).to_utf8_buffer()
		_file.store_32(footer_bytes.size())
		_file.store_buffer(footer_bytes)
		_file.flush()
	_file.close()
	_file = null


func is_open() -> bool:
	return _file != null


func _enqueue(host_ts: float, kind: int, payload: PackedByteArray) -> void:
	if _file == null:
		return
	# Once the worker has reported a write failure, drop further frames on the
	# floor — the file is corrupted, and queueing more just delays shutdown.
	_mutex.lock()
	var failed: bool = _write_failed
	_mutex.unlock()
	if failed:
		return
	var inner_size: int = FRAME_INNER_HEADER_SIZE + payload.size()
	var record := PackedByteArray()
	record.resize(4 + FRAME_INNER_HEADER_SIZE)
	record.encode_u32(0, inner_size)
	record.encode_float(4, host_ts)
	record.encode_u8(8, kind)
	record.append_array(payload)
	_mutex.lock()
	_queue.append(record)
	_mutex.unlock()
	_semaphore.post()


# Runs on the worker thread. Wakes on every semaphore.post(), drains whatever
# the producer has queued in one batch, and goes back to sleep. Exits after
# the next drain once `_shutdown` is set. On the first store_buffer error
# (disk full, permission yanked, etc) sets _write_failed and stops writing —
# the partial file is left as-is for the reader to detect via missing
# END_OF_RECORDS.
func _worker_loop() -> void:
	while true:
		_semaphore.wait()
		_mutex.lock()
		var batch: Array[PackedByteArray] = _queue
		_queue = []
		var should_exit: bool = _shutdown
		var already_failed: bool = _write_failed
		_mutex.unlock()
		if not already_failed:
			for chunk: PackedByteArray in batch:
				_file.store_buffer(chunk)
				if _file.get_error() != OK:
					push_error("ReplayFileWriter: write failed (err %d); aborting recording" % _file.get_error())
					_mutex.lock()
					_write_failed = true
					_mutex.unlock()
					break
		if should_exit:
			_file.flush()
			return
