extends GutTest

# NativeGifEncoder (native/src/native_gif_encoder.cpp).
#
# Unlike the other native suites this is NOT a parity test — the encoder has no
# GDScript reference to agree with. Instead the output is decoded here by an
# independently written GIF reader (block walk + LZW decompressor), so a bug in
# the compressor shows up as a decode mismatch rather than as two
# implementations agreeing on the same mistake. The pixel assertions go through
# that decoder, so they exercise the LZW round trip on every frame.
#
# When the extension isn't built (fresh clone, CI without a native build) every
# test goes pending rather than failing — run native/build.sh.

const W: int = 32
const H: int = 24
# 256 palette entries over a handful of flat colors is exact, but the encoder
# maps through a 5-bit-per-channel memo, so allow a channel to land on a
# neighboring bucket rather than pinning to the byte.
const COLOR_TOLERANCE: int = 8


func _native_missing() -> bool:
	if ClassDB.class_exists(&"NativeGifEncoder"):
		return false
	pending("native extension not built — see native/README.md")
	return true


func _encoder() -> RefCounted:
	return ClassDB.instantiate(&"NativeGifEncoder")


# Flat-color frame, so the expected pixel value is unambiguous after
# quantization.
func _solid(color: Color, fmt: Image.Format = Image.FORMAT_RGB8) -> Image:
	var img: Image = Image.create_empty(W, H, false, fmt)
	img.fill(color)
	return img


# A frame with a distinct block in one corner, to prove frames aren't
# collapsing into each other and that row order survives the round trip.
func _marked(bg: Color, mark: Color, mark_x: int) -> Image:
	var img: Image = Image.create_empty(W, H, false, Image.FORMAT_RGB8)
	img.fill(bg)
	for y: int in range(4, 10):
		for x: int in range(mark_x, mark_x + 6):
			img.set_pixel(x, y, mark)
	return img


func _assert_color_near(actual: Color, expected: Color, msg: String) -> void:
	var da: int = absi(int(actual.r8) - int(expected.r8))
	var db: int = absi(int(actual.g8) - int(expected.g8))
	var dc: int = absi(int(actual.b8) - int(expected.b8))
	assert_true(da <= COLOR_TOLERANCE and db <= COLOR_TOLERANCE and dc <= COLOR_TOLERANCE,
			"%s: got %s want %s" % [msg, actual, expected])


# ── Structure ────────────────────────────────────────────────────────────────

func test_encodes_a_well_formed_gif89a_header() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	enc.add_frame(_solid(Color(0.2, 0.4, 0.8)))
	var gif: Dictionary = GifTestReader.parse(enc.encode())

	assert_true(gif.ok, "parse failed: %s" % gif.get("error", ""))
	assert_eq(gif.version, "GIF89a", "version signature")
	assert_eq(gif.width, W, "logical screen width")
	assert_eq(gif.height, H, "logical screen height")
	assert_eq((gif.palette as PackedByteArray).size(), 256 * 3, "global color table entries")
	assert_true(gif.has_trailer, "stream ends with the 0x3B trailer")


func test_loops_forever() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	enc.add_frame(_solid(Color.RED))
	var gif: Dictionary = GifTestReader.parse(enc.encode())

	# A highlight clip that plays once and freezes is not what anyone wants out
	# of a share button — the NETSCAPE block with count 0 is what makes it loop.
	assert_true(gif.has_netscape, "NETSCAPE2.0 application extension present")
	assert_eq(gif.loop_count, 0, "loop count 0 = infinite")


func test_frame_count_and_delay_match_configuration() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	for i: int in 4:
		enc.add_frame(_solid(Color(float(i) / 4.0, 0.5, 0.5)))
	assert_eq(int(enc.get_frame_count()), 4, "frames accumulated")

	var gif: Dictionary = GifTestReader.parse(enc.encode())
	assert_eq((gif.frames as Array).size(), 4, "image descriptors in the stream")
	for delay: int in gif.delays:
		assert_eq(delay, 5, "per-frame delay in 1/100 s")


func test_delay_is_clamped_above_the_viewer_rewrite_threshold() -> void:
	if _native_missing():
		return
	# Viewers silently rewrite a delay below 2 to 10, which would play a clip at
	# a tenth speed. The encoder clamps so that can't happen.
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 0, false)
	enc.add_frame(_solid(Color.GREEN))
	var gif: Dictionary = GifTestReader.parse(enc.encode())
	assert_eq(gif.delays[0], 2, "delay clamped up to 2")


# ── Pixel round trip ─────────────────────────────────────────────────────────

func test_flat_frames_survive_the_round_trip() -> void:
	if _native_missing():
		return
	var colors: Array[Color] = [
		Color(0.90, 0.92, 0.95),  # ice
		Color(0.80, 0.10, 0.12),  # home sweater
		Color(0.10, 0.20, 0.60),  # away sweater
	]
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	for c: Color in colors:
		enc.add_frame(_solid(c))

	var gif: Dictionary = GifTestReader.parse(enc.encode())
	assert_true(gif.ok, "parse failed: %s" % gif.get("error", ""))
	for i: int in colors.size():
		var img: Image = GifTestReader.frame_image(gif, i)
		_assert_color_near(img.get_pixel(1, 1), colors[i], "frame %d top-left" % i)
		_assert_color_near(img.get_pixel(W - 2, H - 2), colors[i], "frame %d bottom-right" % i)


func test_each_frame_keeps_its_own_content() -> void:
	if _native_missing():
		return
	# The mark walks across frames — the failure this catches is a frame stream
	# that decodes but repeats one frame's pixels for the whole clip.
	var bg := Color(0.9, 0.9, 0.9)
	var mark := Color(0.1, 0.1, 0.1)
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	for i: int in 3:
		enc.add_frame(_marked(bg, mark, 2 + i * 8))

	var gif: Dictionary = GifTestReader.parse(enc.encode())
	for i: int in 3:
		var img: Image = GifTestReader.frame_image(gif, i)
		var mark_x: int = 2 + i * 8
		_assert_color_near(img.get_pixel(mark_x + 2, 6), mark, "frame %d mark" % i)
		# Where the PREVIOUS frame's mark was must be background again — the
		# frames are full-rect, so nothing should be left standing.
		if i > 0:
			_assert_color_near(img.get_pixel(mark_x - 6, 6), bg,
					"frame %d cleared the previous mark" % i)


func test_gradients_round_trip_with_dithering_enabled() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 4, true)
	var img: Image = Image.create_empty(W, H, false, Image.FORMAT_RGB8)
	for y: int in H:
		for x: int in W:
			img.set_pixel(x, y, Color(float(x) / W, float(y) / H, 0.5))
	enc.add_frame(img)

	var gif: Dictionary = GifTestReader.parse(enc.encode())
	assert_true(gif.ok, "dithered stream parses: %s" % gif.get("error", ""))
	var out: Image = GifTestReader.frame_image(gif, 0)
	# Dithering trades per-pixel accuracy for local average accuracy, so assert
	# on a block mean rather than a pixel.
	var sum := Vector3.ZERO
	for y: int in range(16, 24):
		for x: int in range(16, 24):
			var c: Color = out.get_pixel(x, y)
			sum += Vector3(c.r, c.g, c.b)
	var mean: Vector3 = sum / 64.0
	assert_almost_eq(mean.x, 20.0 / W, 0.12, "dithered red mean")
	assert_almost_eq(mean.y, 20.0 / H, 0.12, "dithered green mean")


func test_accepts_rgba8_input() -> void:
	if _native_missing():
		return
	# The capture path converts to RGB8, but the viewport hands back RGBA8 and
	# the encoder is documented to take either.
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	assert_true(bool(enc.add_frame(_solid(Color(0.3, 0.7, 0.2), Image.FORMAT_RGBA8))),
			"RGBA8 frame accepted")
	var gif: Dictionary = GifTestReader.parse(enc.encode())
	var img: Image = GifTestReader.frame_image(gif, 0)
	_assert_color_near(img.get_pixel(5, 5), Color(0.3, 0.7, 0.2), "RGBA8 color")


# ── Rejection and reset ──────────────────────────────────────────────────────

func test_rejects_frames_that_do_not_match_the_configured_size() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	var wrong: Image = Image.create_empty(W + 1, H, false, Image.FORMAT_RGB8)
	wrong.fill(Color.BLUE)
	assert_false(bool(enc.add_frame(wrong)), "mismatched frame rejected")
	assert_eq(int(enc.get_frame_count()), 0, "rejected frame is not stored")


func test_encoding_with_no_frames_yields_nothing() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	assert_eq((enc.encode() as PackedByteArray).size(), 0, "empty encode")


func test_configure_drops_previously_added_frames() -> void:
	if _native_missing():
		return
	# Every frame in a GIF shares the logical screen size, so a reconfigure
	# can't keep frames sized for the old geometry.
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	enc.add_frame(_solid(Color.RED))
	enc.configure(W, H, 5, false)
	assert_eq(int(enc.get_frame_count()), 0, "frames cleared on reconfigure")


func test_reset_clears_accumulated_frames() -> void:
	if _native_missing():
		return
	var enc: RefCounted = _encoder()
	enc.configure(W, H, 5, false)
	enc.add_frame(_solid(Color.RED))
	enc.reset()
	assert_eq(int(enc.get_frame_count()), 0, "reset drops frames")


# ── Long clips ───────────────────────────────────────────────────────────────

func test_a_long_noisy_clip_still_decodes() -> void:
	if _native_missing():
		return
	# Noise defeats LZW run matching, so this is the path that actually fills
	# the 4096-code dictionary and exercises the mid-stream Clear + table reset
	# — the branch a short flat clip never reaches.
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x4D495454  # "MITT" — fixed so a failure reproduces
	var enc: RefCounted = _encoder()
	enc.configure(64, 64, 5, false)
	for _f: int in 8:
		var img: Image = Image.create_empty(64, 64, false, Image.FORMAT_RGB8)
		for y: int in 64:
			for x: int in 64:
				img.set_pixel(x, y, Color(rng.randf(), rng.randf(), rng.randf()))
		enc.add_frame(img)

	var gif: Dictionary = GifTestReader.parse(enc.encode())
	assert_true(gif.ok, "noisy stream parses: %s" % gif.get("error", ""))
	assert_eq((gif.frames as Array).size(), 8, "all frames present")
	for i: int in 8:
		var indices: PackedByteArray = gif.frames[i]
		assert_eq(indices.size(), 64 * 64, "frame %d decodes to a full raster" % i)
