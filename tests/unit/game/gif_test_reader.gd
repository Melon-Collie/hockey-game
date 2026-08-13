class_name GifTestReader

# Minimal GIF89a reader for test_gif_encoder.gd — block walk plus an LZW
# decompressor, written from the spec rather than from NativeGifEncoder, so a
# compressor bug surfaces as a decode failure instead of two implementations
# quietly agreeing on the same mistake.
#
# Reads only what the encoder emits: a global color table, the NETSCAPE loop
# extension, and full-frame images with no local table and no interlacing.
# Anything else is reported as an error rather than guessed at.

const CLEAR_BASE: int = 256  # for the encoder's fixed 8-bit minimum code size


# Returns:
#   ok: bool, error: String,
#   version: String, width/height: int,
#   palette: PackedByteArray (256 * 3, RGB),
#   has_netscape: bool, loop_count: int, has_trailer: bool,
#   delays: Array[int] (1/100 s, one per frame),
#   frames: Array[PackedByteArray] (palette indices, width * height each)
static func parse(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {
		"ok": false, "error": "", "version": "", "width": 0, "height": 0,
		"palette": PackedByteArray(), "has_netscape": false, "loop_count": -1,
		"has_trailer": false, "delays": [] as Array[int],
		"frames": [] as Array[PackedByteArray],
	}
	if data.size() < 13:
		out.error = "shorter than a header"
		return out

	out.version = data.slice(0, 6).get_string_from_ascii()
	if out.version != "GIF89a" and out.version != "GIF87a":
		out.error = "bad signature '%s'" % out.version
		return out

	var width: int = data[6] | (data[7] << 8)
	var height: int = data[8] | (data[9] << 8)
	out.width = width
	out.height = height
	var packed: int = data[10]
	var has_gct: bool = (packed & 0x80) != 0
	if not has_gct:
		out.error = "no global color table"
		return out
	var gct_size: int = 2 << (packed & 0x07)
	var pos: int = 13
	out.palette = data.slice(pos, pos + gct_size * 3)
	pos += gct_size * 3

	var pending_delay: int = 0
	while pos < data.size():
		var block: int = data[pos]
		if block == 0x3B:  # trailer
			out.has_trailer = true
			break
		if block == 0x21:  # extension
			pos += 1
			if pos >= data.size():
				out.error = "truncated extension"
				return out
			var label: int = data[pos]
			pos += 1
			if label == 0xF9:  # graphic control
				# [size=4][packed][delay lo][delay hi][transparent idx][0]
				var size: int = data[pos]
				pending_delay = data[pos + 2] | (data[pos + 3] << 8)
				pos += 1 + size
			elif label == 0xFF:  # application
				var app_size: int = data[pos]
				var app_id: String = data.slice(pos + 1, pos + 1 + 11).get_string_from_ascii()
				pos += 1 + app_size
				if app_id == "NETSCAPE2.0":
					out.has_netscape = true
					# One sub-block: [size=3][1][loop lo][loop hi]
					if data[pos] == 3:
						out.loop_count = data[pos + 2] | (data[pos + 3] << 8)
			pos = _skip_sub_blocks(data, pos)
			continue
		if block == 0x2C:  # image descriptor
			pos += 1
			var fw: int = data[pos + 4] | (data[pos + 5] << 8)
			var fh: int = data[pos + 6] | (data[pos + 7] << 8)
			var img_packed: int = data[pos + 8]
			pos += 9
			if (img_packed & 0x80) != 0:
				out.error = "local color table not expected"
				return out
			if (img_packed & 0x40) != 0:
				out.error = "interlaced frame not expected"
				return out
			var min_code_size: int = data[pos]
			pos += 1
			var payload := PackedByteArray()
			pos = _read_sub_blocks(data, pos, payload)
			var indices: PackedByteArray = _lzw_decode(payload, min_code_size, fw * fh)
			if indices.size() != fw * fh:
				out.error = "frame decoded to %d bytes, expected %d" % [indices.size(), fw * fh]
				return out
			(out.frames as Array).append(indices)
			(out.delays as Array).append(pending_delay)
			pending_delay = 0
			continue
		out.error = "unknown block 0x%02X at %d" % [block, pos]
		return out

	out.ok = true
	return out


# Rebuilds one decoded frame as an RGB8 Image through the global palette.
static func frame_image(gif: Dictionary, index: int) -> Image:
	var indices: PackedByteArray = gif.frames[index]
	var palette: PackedByteArray = gif.palette
	var width: int = gif.width
	var height: int = gif.height
	var img: Image = Image.create_empty(width, height, false, Image.FORMAT_RGB8)
	for y: int in height:
		for x: int in width:
			var p: int = int(indices[y * width + x]) * 3
			img.set_pixel(x, y, Color8(palette[p], palette[p + 1], palette[p + 2]))
	return img


static func _skip_sub_blocks(data: PackedByteArray, pos: int) -> int:
	while pos < data.size() and data[pos] != 0:
		pos += 1 + data[pos]
	return pos + 1  # step past the zero terminator


static func _read_sub_blocks(data: PackedByteArray, pos: int, out: PackedByteArray) -> int:
	while pos < data.size() and data[pos] != 0:
		var size: int = data[pos]
		out.append_array(data.slice(pos + 1, pos + 1 + size))
		pos += 1 + size
	return pos + 1


# Standard GIF LZW. The decoder builds its dictionary one entry BEHIND the
# encoder (it can only add an entry once it has seen the following code), which
# is why the code-width step here reads `next == 1 << code_size` while the
# encoder steps on the entry it just assigned — both land on the same code.
static func _lzw_decode(bits: PackedByteArray, min_code_size: int, expected: int) -> PackedByteArray:
	var out := PackedByteArray()
	if bits.is_empty():
		return out
	var clear_code: int = 1 << min_code_size
	var eoi_code: int = clear_code + 1
	var dict: Array[PackedByteArray] = []
	var code_size: int = min_code_size + 1
	var next_code: int = clear_code + 2

	var reset_dict: Callable = func() -> void:
		dict.clear()
		for i: int in clear_code:
			dict.append(PackedByteArray([i]))
		# Placeholders so dictionary indices stay aligned with code values.
		dict.append(PackedByteArray())
		dict.append(PackedByteArray())
	reset_dict.call()

	var bit_pos: int = 0
	var total_bits: int = bits.size() * 8
	var prev: int = -1
	while bit_pos + code_size <= total_bits:
		# Codes are packed low bit first, and may straddle up to three bytes.
		var byte_idx: int = bit_pos >> 3
		var acc: int = bits[byte_idx]
		if byte_idx + 1 < bits.size():
			acc |= bits[byte_idx + 1] << 8
		if byte_idx + 2 < bits.size():
			acc |= bits[byte_idx + 2] << 16
		var code: int = (acc >> (bit_pos & 7)) & ((1 << code_size) - 1)
		bit_pos += code_size

		if code == clear_code:
			reset_dict.call()
			code_size = min_code_size + 1
			next_code = clear_code + 2
			prev = -1
			continue
		if code == eoi_code:
			break
		var entry: PackedByteArray
		if code < dict.size() and code != clear_code and code != eoi_code \
				and not dict[code].is_empty():
			entry = dict[code]
		elif prev >= 0:
			# The KwKwK case: a code referring to the entry being defined now.
			entry = dict[prev].duplicate()
			entry.append(dict[prev][0])
		else:
			break  # malformed: first code after a Clear must already exist
		out.append_array(entry)

		if prev >= 0 and next_code < 4096:
			var added: PackedByteArray = dict[prev].duplicate()
			added.append(entry[0])
			if next_code < dict.size():
				dict[next_code] = added
			else:
				dict.append(added)
			next_code += 1
			if next_code == (1 << code_size) and code_size < 12:
				code_size += 1
		prev = code
		if out.size() >= expected:
			break
	return out
