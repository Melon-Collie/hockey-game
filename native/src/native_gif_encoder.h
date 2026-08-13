#pragma once

#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>

#include <cstdint>
#include <vector>

namespace mitts {

// GIF89a encoder for the goal-clip export (Scripts/game/gif_exporter.gd).
//
// Unlike the other kernels here this is NOT a port — there is no GDScript
// reference and nothing about it runs on the 120 Hz tick. It lives in the
// extension because GIF needs color quantization plus LZW over ~150 frames,
// which is seconds of work in GDScript and well under one in C++. Correctness
// is pinned by tests/unit/game/test_gif_encoder.gd, which decodes the output
// with an independent GDScript LZW decoder rather than by parity against a
// second implementation.
//
// Frames are accumulated as RGB888 (add_frame) and encoded in one pass at the
// end (encode), because the palette is GLOBAL: one 256-color table shared by
// every frame. Per-frame palettes would quantize each frame better in
// isolation but make the flat expanses of ice shimmer between frames as the
// chosen whites drift, and cost 768 bytes a frame on top.
//
// Deliberately NOT implemented: inter-frame differencing (emitting only the
// changed sub-rectangle with disposal "do not dispose"). It is the standard
// GIF size win, but both replay cameras track the puck continuously, so
// nearly every pixel changes on nearly every frame and the bookkeeping would
// buy close to nothing.
class NativeGifEncoder : public godot::RefCounted {
	GDCLASS(NativeGifEncoder, godot::RefCounted)

	int width = 0;
	int height = 0;
	int delay_cs = 5;  // frame delay in GIF's 1/100 s units
	bool dither = false;
	// One entry per frame, RGB888, width * height * 3 bytes.
	std::vector<std::vector<uint8_t>> frames;

protected:
	static void _bind_methods();

public:
	// Sets the output geometry. Changing it drops any frames already added,
	// since every frame in a GIF shares the logical screen size.
	void configure(int p_width, int p_height, int p_delay_cs, bool p_dither);

	// Copies one frame in. The image must already be RGB8 or RGBA8 at the
	// configured size (the caller owns the conversion — it owns the Image).
	// Returns false and adds nothing on any mismatch.
	bool add_frame(const godot::Ref<godot::Image> &p_image);

	// Encodes every accumulated frame into a complete .gif byte stream,
	// looping forever. Returns empty if no frames were added. Does not clear
	// the frame list — call reset() for that.
	godot::PackedByteArray encode();

	void reset();
	int get_frame_count() const;
};

} // namespace mitts
