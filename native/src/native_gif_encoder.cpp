#include "native_gif_encoder.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cstring>

using namespace godot;

namespace mitts {

namespace {

constexpr int PALETTE_SIZE = 256;
constexpr int CLEAR_CODE = 256;
constexpr int EOI_CODE = 257;
constexpr int MAX_LZW_CODE = 4095;
constexpr int MIN_CODE_SIZE = 8;  // fixed: the palette is always 256 entries

// Cap on the pixels fed to the median-cut splitter. A 480x270 clip is ~130k
// pixels per frame, so a 150-frame clip holds ~19M — sampling keeps palette
// cost flat as clips get longer, and a 200k sample is far more than enough to
// place 256 boxes.
constexpr int MAX_SAMPLES = 200000;

struct Sample {
	uint8_t c[3];
};

// A median-cut box: a half-open range of the sample array plus the bounding
// box of the colors inside it.
struct Box {
	int begin = 0;
	int end = 0;
	uint8_t lo[3] = {255, 255, 255};
	uint8_t hi[3] = {0, 0, 0};
};

void shrink_box(Box &box, const std::vector<Sample> &samples) {
	for (int ch = 0; ch < 3; ch++) {
		box.lo[ch] = 255;
		box.hi[ch] = 0;
	}
	for (int i = box.begin; i < box.end; i++) {
		for (int ch = 0; ch < 3; ch++) {
			const uint8_t v = samples[i].c[ch];
			box.lo[ch] = std::min(box.lo[ch], v);
			box.hi[ch] = std::max(box.hi[ch], v);
		}
	}
}

int widest_channel(const Box &box) {
	int best = 0;
	int best_range = box.hi[0] - box.lo[0];
	for (int ch = 1; ch < 3; ch++) {
		const int range = box.hi[ch] - box.lo[ch];
		if (range > best_range) {
			best_range = range;
			best = ch;
		}
	}
	return best;
}

// Splitting priority. Range alone over-serves a handful of outlier pixels
// (one bright advertising board out-ranks the whole ice sheet); count alone
// over-serves flat expanses that need one entry. The product spends entries
// where a wide spread covers many pixels.
int64_t split_score(const Box &box) {
	const int range = box.hi[widest_channel(box)] - box.lo[widest_channel(box)];
	if (range == 0 || box.end - box.begin < 2) {
		return 0;  // nothing left to separate
	}
	return (int64_t)range * (int64_t)(box.end - box.begin);
}

// Classic median cut: repeatedly split the highest-scoring box at the median
// of its widest channel until we have PALETTE_SIZE boxes (or every remaining
// box is a single color). Palette entries are box MEANS rather than midpoints
// — the mean lands on where the pixels actually are.
void build_palette(const std::vector<Sample> &samples_in, uint8_t palette[PALETTE_SIZE][3]) {
	std::memset(palette, 0, PALETTE_SIZE * 3);
	if (samples_in.empty()) {
		return;
	}
	std::vector<Sample> samples = samples_in;

	std::vector<Box> boxes;
	boxes.reserve(PALETTE_SIZE);
	Box first;
	first.begin = 0;
	first.end = (int)samples.size();
	shrink_box(first, samples);
	boxes.push_back(first);

	while ((int)boxes.size() < PALETTE_SIZE) {
		int target = -1;
		int64_t best = 0;
		for (int i = 0; i < (int)boxes.size(); i++) {
			const int64_t score = split_score(boxes[i]);
			if (score > best) {
				best = score;
				target = i;
			}
		}
		if (target < 0) {
			break;  // every box is a single color
		}
		Box &box = boxes[target];
		const int ch = widest_channel(box);
		std::sort(samples.begin() + box.begin, samples.begin() + box.end,
				[ch](const Sample &a, const Sample &b) { return a.c[ch] < b.c[ch]; });
		const int mid = box.begin + (box.end - box.begin) / 2;

		Box upper;
		upper.begin = mid;
		upper.end = box.end;
		box.end = mid;
		shrink_box(box, samples);
		shrink_box(upper, samples);
		boxes.push_back(upper);
	}

	for (int i = 0; i < (int)boxes.size(); i++) {
		const Box &box = boxes[i];
		const int count = box.end - box.begin;
		if (count <= 0) {
			continue;
		}
		int64_t sum[3] = {0, 0, 0};
		for (int s = box.begin; s < box.end; s++) {
			for (int ch = 0; ch < 3; ch++) {
				sum[ch] += samples[s].c[ch];
			}
		}
		for (int ch = 0; ch < 3; ch++) {
			palette[i][ch] = (uint8_t)(sum[ch] / count);
		}
	}
}

// Nearest-palette-entry lookup, memoized on the top 5 bits of each channel.
// An exact scan is 256 distance evaluations per pixel — ~5 billion for a
// full clip. The 32k-entry cache fills lazily and collapses that to one
// lookup per pixel. Bucketing the QUERY to 5 bits can only pick a different
// entry when two palette entries sit within ~4/255 of each other, i.e. when
// they are visually the same color anyway.
inline int nearest_index(int r, int g, int b,
		const uint8_t palette[PALETTE_SIZE][3], std::vector<int16_t> &cache) {
	const int key = ((r >> 3) << 10) | ((g >> 3) << 5) | (b >> 3);
	const int16_t hit = cache[key];
	if (hit >= 0) {
		return hit;
	}
	int best = 0;
	int best_dist = 1 << 30;
	for (int i = 0; i < PALETTE_SIZE; i++) {
		const int dr = r - (int)palette[i][0];
		const int dg = g - (int)palette[i][1];
		const int db = b - (int)palette[i][2];
		const int dist = dr * dr + dg * dg + db * db;
		if (dist < best_dist) {
			best_dist = dist;
			best = i;
			if (dist == 0) {
				break;
			}
		}
	}
	cache[key] = (int16_t)best;
	return best;
}

inline int clamp_byte(int v) {
	return v < 0 ? 0 : (v > 255 ? 255 : v);
}

void map_frame(const uint8_t *rgb, int width, int height, bool dither,
		const uint8_t palette[PALETTE_SIZE][3], std::vector<int16_t> &cache,
		std::vector<uint8_t> &out) {
	out.resize((size_t)width * height);
	if (!dither) {
		for (int i = 0; i < width * height; i++) {
			out[i] = (uint8_t)nearest_index(rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2],
					palette, cache);
		}
		return;
	}

	// Floyd-Steinberg. Two rows of accumulated error, padded by one pixel on
	// each side so the -1 / +1 neighbor writes need no bounds checks.
	const int stride = (width + 2) * 3;
	std::vector<int> err_cur(stride, 0);
	std::vector<int> err_next(stride, 0);
	for (int y = 0; y < height; y++) {
		std::fill(err_next.begin(), err_next.end(), 0);
		for (int x = 0; x < width; x++) {
			const int p = (y * width + x) * 3;
			const int e = (x + 1) * 3;
			const int r = clamp_byte((int)rgb[p] + err_cur[e]);
			const int g = clamp_byte((int)rgb[p + 1] + err_cur[e + 1]);
			const int b = clamp_byte((int)rgb[p + 2] + err_cur[e + 2]);
			const int pi = nearest_index(r, g, b, palette, cache);
			out[(size_t)y * width + x] = (uint8_t)pi;
			const int err[3] = {
				r - (int)palette[pi][0],
				g - (int)palette[pi][1],
				b - (int)palette[pi][2],
			};
			for (int ch = 0; ch < 3; ch++) {
				err_cur[e + 3 + ch] += err[ch] * 7 / 16;
				err_next[e - 3 + ch] += err[ch] * 3 / 16;
				err_next[e + ch] += err[ch] * 5 / 16;
				err_next[e + 3 + ch] += err[ch] * 1 / 16;
			}
		}
		err_cur.swap(err_next);
	}
}

// LSB-first bit packer — GIF's LZW codes are written low bit first.
struct BitWriter {
	std::vector<uint8_t> bytes;
	uint32_t acc = 0;
	int nbits = 0;

	void write(int code, int size) {
		acc |= (uint32_t)code << nbits;
		nbits += size;
		while (nbits >= 8) {
			bytes.push_back((uint8_t)(acc & 0xFF));
			acc >>= 8;
			nbits -= 8;
		}
	}

	void flush() {
		if (nbits > 0) {
			bytes.push_back((uint8_t)(acc & 0xFF));
			acc = 0;
			nbits = 0;
		}
	}
};

// GIF LZW over one frame's palette indices. `table` is a caller-owned
// (prefix, next_byte) -> code map, flat at 4096 * 256 entries so the lookup is
// a single index; 0 doubles as "empty" because no child code is ever below
// 258. Reused across frames to keep the 4 MB allocation out of the loop.
void lzw_compress(const std::vector<uint8_t> &indices, std::vector<int32_t> &table,
		std::vector<uint8_t> &out) {
	std::fill(table.begin(), table.end(), 0);
	BitWriter bw;
	int code_size = MIN_CODE_SIZE + 1;
	int max_code = EOI_CODE;  // last code handed out; first new one is 258

	bw.write(CLEAR_CODE, code_size);
	int cur = indices[0];
	for (size_t i = 1; i < indices.size(); i++) {
		const int k = indices[i];
		int32_t &slot = table[(size_t)cur * 256 + k];
		if (slot != 0) {
			cur = slot;
			continue;
		}
		bw.write(cur, code_size);
		slot = ++max_code;
		if (max_code >= (1 << code_size) && code_size < 12) {
			code_size++;
		}
		if (max_code == MAX_LZW_CODE) {
			// Dictionary full: emit Clear at the CURRENT width (the decoder
			// is still reading that width when it sees it), then reset.
			bw.write(CLEAR_CODE, code_size);
			std::fill(table.begin(), table.end(), 0);
			max_code = EOI_CODE;
			code_size = MIN_CODE_SIZE + 1;
		}
		cur = k;
	}
	bw.write(cur, code_size);
	bw.write(EOI_CODE, code_size);
	bw.flush();

	// Packed into sub-blocks of at most 255 bytes, zero-length terminated.
	size_t pos = 0;
	while (pos < bw.bytes.size()) {
		const size_t chunk = std::min<size_t>(255, bw.bytes.size() - pos);
		out.push_back((uint8_t)chunk);
		out.insert(out.end(), bw.bytes.begin() + pos, bw.bytes.begin() + pos + chunk);
		pos += chunk;
	}
	out.push_back(0);
}

void put_u16(std::vector<uint8_t> &out, int v) {
	out.push_back((uint8_t)(v & 0xFF));
	out.push_back((uint8_t)((v >> 8) & 0xFF));
}

} // namespace

void NativeGifEncoder::configure(int p_width, int p_height, int p_delay_cs, bool p_dither) {
	width = std::max(0, p_width);
	height = std::max(0, p_height);
	// GIF stores the delay in 1/100 s. Browsers and most viewers silently
	// rewrite a delay below 2 to 10 (the ancient "0 means as-fast-as-possible"
	// workaround), which would play the clip at a tenth speed, so clamp up.
	delay_cs = std::max(2, p_delay_cs);
	dither = p_dither;
	frames.clear();
}

bool NativeGifEncoder::add_frame(const Ref<Image> &p_image) {
	if (p_image.is_null() || width <= 0 || height <= 0) {
		return false;
	}
	if (p_image->get_width() != width || p_image->get_height() != height) {
		return false;
	}
	const Image::Format fmt = p_image->get_format();
	if (fmt != Image::FORMAT_RGB8 && fmt != Image::FORMAT_RGBA8) {
		return false;
	}
	const int stride = (fmt == Image::FORMAT_RGB8) ? 3 : 4;
	const PackedByteArray data = p_image->get_data();
	const int64_t needed = (int64_t)width * height * stride;
	if (data.size() < needed) {
		return false;
	}
	const uint8_t *src = data.ptr();

	std::vector<uint8_t> rgb((size_t)width * height * 3);
	for (int64_t i = 0; i < (int64_t)width * height; i++) {
		rgb[i * 3] = src[i * stride];
		rgb[i * 3 + 1] = src[i * stride + 1];
		rgb[i * 3 + 2] = src[i * stride + 2];
	}
	frames.push_back(std::move(rgb));
	return true;
}

PackedByteArray NativeGifEncoder::encode() {
	PackedByteArray result;
	if (frames.empty() || width <= 0 || height <= 0) {
		return result;
	}

	// Sample across ALL frames rather than per frame, so the shared palette is
	// fit to the whole clip. The stride walks pixels, not frames, so a color
	// that only appears late (the goal light, a crowd flash) still lands in it.
	const int64_t total_pixels = (int64_t)frames.size() * width * height;
	const int64_t stride = std::max<int64_t>(1, total_pixels / MAX_SAMPLES);
	std::vector<Sample> samples;
	samples.reserve((size_t)std::min<int64_t>(total_pixels, MAX_SAMPLES) + 1);
	for (int64_t p = 0; p < total_pixels; p += stride) {
		const std::vector<uint8_t> &frame = frames[(size_t)(p / ((int64_t)width * height))];
		const int64_t off = (p % ((int64_t)width * height)) * 3;
		Sample s;
		s.c[0] = frame[(size_t)off];
		s.c[1] = frame[(size_t)off + 1];
		s.c[2] = frame[(size_t)off + 2];
		samples.push_back(s);
	}

	uint8_t palette[PALETTE_SIZE][3];
	build_palette(samples, palette);
	samples.clear();
	samples.shrink_to_fit();

	std::vector<uint8_t> out;
	out.reserve((size_t)frames.size() * width * height / 2);

	// Header + logical screen descriptor.
	const char *magic = "GIF89a";
	out.insert(out.end(), magic, magic + 6);
	put_u16(out, width);
	put_u16(out, height);
	// 1 global color table | 8-bit color resolution | unsorted | 256 entries.
	out.push_back(0xF7);
	out.push_back(0x00);  // background color index
	out.push_back(0x00);  // pixel aspect ratio: none given
	for (int i = 0; i < PALETTE_SIZE; i++) {
		out.push_back(palette[i][0]);
		out.push_back(palette[i][1]);
		out.push_back(palette[i][2]);
	}

	// NETSCAPE2.0 application extension — loop forever.
	out.push_back(0x21);
	out.push_back(0xFF);
	out.push_back(0x0B);
	const char *netscape = "NETSCAPE2.0";
	out.insert(out.end(), netscape, netscape + 11);
	out.push_back(0x03);
	out.push_back(0x01);
	put_u16(out, 0);  // 0 = infinite
	out.push_back(0x00);

	std::vector<int16_t> cache(32768, -1);
	std::vector<int32_t> table((size_t)4096 * 256, 0);
	std::vector<uint8_t> indices;
	for (const std::vector<uint8_t> &frame : frames) {
		// Graphic control extension: disposal 1 (leave the frame in place),
		// no transparency, per-frame delay.
		out.push_back(0x21);
		out.push_back(0xF9);
		out.push_back(0x04);
		out.push_back(0x04);
		put_u16(out, delay_cs);
		out.push_back(0x00);  // transparent color index (unused)
		out.push_back(0x00);

		// Image descriptor: full-frame, no local color table, not interlaced.
		out.push_back(0x2C);
		put_u16(out, 0);
		put_u16(out, 0);
		put_u16(out, width);
		put_u16(out, height);
		out.push_back(0x00);

		map_frame(frame.data(), width, height, dither, palette, cache, indices);
		out.push_back((uint8_t)MIN_CODE_SIZE);
		lzw_compress(indices, table, out);
	}

	out.push_back(0x3B);  // trailer

	result.resize((int64_t)out.size());
	std::memcpy(result.ptrw(), out.data(), out.size());
	return result;
}

void NativeGifEncoder::reset() {
	frames.clear();
}

int NativeGifEncoder::get_frame_count() const {
	return (int)frames.size();
}

void NativeGifEncoder::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "width", "height", "delay_cs", "dither"),
			&NativeGifEncoder::configure);
	ClassDB::bind_method(D_METHOD("add_frame", "image"), &NativeGifEncoder::add_frame);
	ClassDB::bind_method(D_METHOD("encode"), &NativeGifEncoder::encode);
	ClassDB::bind_method(D_METHOD("reset"), &NativeGifEncoder::reset);
	ClassDB::bind_method(D_METHOD("get_frame_count"), &NativeGifEncoder::get_frame_count);
}

} // namespace mitts
