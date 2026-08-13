class_name ClipFrameCapture
extends Node

# Off-screen frame grabber behind the goal-clip GIF export. Owns a small
# SubViewport whose camera mirrors whatever camera is currently live, and
# reads that viewport back into an Image at a fixed cadence.
#
# Why a second viewport rather than reading the main one: the main window is
# at the player's display resolution, so a per-frame readback moves ~8 MB and
# stalls on a GPU sync. The mirror renders at CAPTURE_SIZE, which is both the
# readback the export actually wants and small enough to grab without a
# visible hitch.
#
# The mirror renders only on capture ticks (UPDATE_ONCE, re-armed each tick),
# NOT every frame — it is a second full pass over the 3D scene, so at 60 fps
# UPDATE_ALWAYS would roughly double the scene's draw cost for frames that get
# thrown away. Rendering is therefore requested one tick and read the next:
# UPDATE_ONCE draws at the end of the frame that arms it, so the image only
# exists on the following frame (the same beat tools/pose_capture_runner.gd
# works on).
#
# Capture necessarily runs speculatively for the WHOLE clip — the player
# presses save partway through and expects the entire goal, so there is no
# version of this that starts on the press.
#
# Framing caveat: the mirror keeps the live camera's vertical FOV, so on a
# display that isn't 16:9 the GIF shows a different horizontal extent than the
# player saw. Vertical framing — where the cinematic's composition lives — is
# identical.

const CAPTURE_SIZE: Vector2i = Vector2i(480, 270)
const CAPTURE_FPS: int = 20
# 10 s at CAPTURE_FPS, ~78 MB of RGB8. The goal cinematic runs ~7 s of
# wall-clock (slow-mo stretches the tail past the clip's sim duration) and the
# reel's clips less; this is the backstop that bounds memory if a driver is
# left running, not an expected limit.
const MAX_FRAMES: int = 200

var _viewport: SubViewport = null
var _camera: Camera3D = null
var _frames: Array[Image] = []
var _capturing: bool = false
var _accum: float = 0.0
# True between arming a render and reading it back on the next frame.
var _pending_read: bool = false


func _ready() -> void:
	_viewport = SubViewport.new()
	_viewport.size = CAPTURE_SIZE
	# Nothing is drawn until a capture tick arms it.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	# Inherit the main World3D (own_world_3d stays false) so the mirror sees
	# the live actors, rink, and environment with no duplication.
	_viewport.own_world_3d = false
	_viewport.transparent_bg = false
	_viewport.gui_disable_input = true
	_viewport.audio_listener_enable_3d = false
	# Fixed 2x MSAA rather than mirroring the player's display setting: at
	# CAPTURE_SIZE the cost is trivial either way, and edge aliasing that would
	# be invisible at display resolution is not at 480x270. Fixed also means the
	# exported clip looks the same whatever the player's graphics options say.
	_viewport.msaa_3d = Viewport.MSAA_2X
	add_child(_viewport)

	_camera = Camera3D.new()
	# Current within the SubViewport only — a camera never affects a viewport
	# it isn't parented under, so this can't steal the player's view.
	_camera.current = true
	# Both cameras this mirrors (SpectatorCamera, GameCamera) move in _process
	# and opt out of interpolation, so their global_transform IS the rendered
	# pose. Copying it into an interpolated node would re-interpolate an
	# already-interpolated pose and lag the mirror behind the live view.
	_camera.physics_interpolation_mode = Node.PHYSICS_INTERPOLATION_MODE_OFF
	_viewport.add_child(_camera)

	set_process(false)


func is_capturing() -> bool:
	return _capturing


func frame_count() -> int:
	return _frames.size()


func fps() -> int:
	return CAPTURE_FPS


# Begins a fresh capture segment, dropping anything previously buffered.
func start() -> void:
	_frames.clear()
	_accum = 0.0
	_pending_read = false
	_capturing = true
	set_process(true)


func stop() -> void:
	_capturing = false
	_pending_read = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	set_process(false)


# Stop and throw the buffer away — the segment ended without an export request.
func discard() -> void:
	stop()
	_frames.clear()


# Hands the buffered frames to the caller and clears our reference, so the
# encoder thread can free each one as it consumes it.
func take() -> Array[Image]:
	var out: Array[Image] = _frames
	_frames = []
	return out


func _process(delta: float) -> void:
	# Read back the frame armed on the previous tick before arming another.
	if _pending_read:
		_pending_read = false
		var tex: ViewportTexture = _viewport.get_texture()
		if tex != null:
			var img: Image = tex.get_image()
			if img != null:
				# The encoder takes RGB8; converting here also drops the alpha
				# byte from the buffer we hold for the length of the clip.
				if img.get_format() != Image.FORMAT_RGB8:
					img.convert(Image.FORMAT_RGB8)
				_frames.append(img)

	if not _capturing or _frames.size() >= MAX_FRAMES:
		return

	_accum += delta
	var interval: float = 1.0 / float(CAPTURE_FPS)
	if _accum < interval:
		return
	# Drop whole intervals rather than zeroing, so a slow frame doesn't push
	# the whole clip's cadence late.
	_accum = fmod(_accum, interval)

	var live: Camera3D = get_viewport().get_camera_3d()
	if live == null:
		return
	_camera.global_transform = live.global_transform
	_camera.fov = live.fov
	_camera.near = live.near
	_camera.far = live.far
	_camera.projection = live.projection
	_camera.keep_aspect = live.keep_aspect
	_camera.environment = live.environment
	_camera.attributes = live.attributes

	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_pending_read = true
