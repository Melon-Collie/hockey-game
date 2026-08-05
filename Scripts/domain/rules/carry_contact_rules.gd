class_name CarryContactRules

# Stroke solver for the motion-keyed stickhandling push model
# (docs/stickhandling-push-model-plan.md): the blade contacts the carried puck
# on the side it is pushing from — the side opposite the puck's motion in the
# carrier's frame — and an inward pull (which no blade face can push, so the
# wrists must hook the toe over) plays the toe-drag or heel-cradle grammar by
# body side. Pure and stateless; the caller owns the smoothing memory and
# feeds back the current side for the hold path.
#
# Inputs are the decomposition of the blade-contact velocity relative to the
# carrier's body, against the blade axes of Skater.get_carry_target_global:
#   v_perp — component along face_normal (the lateral stroke),
#   v_in   — component along −stick_dir (positive = pulled toward the body).


# Which side of the puck the blade sits on, as a face-normal sign (+1 = the
# blade offset rides +face_normal). A stroke along +face_normal wants the
# blade trailing at −face_normal. Below flip_speed there is no stroke to key
# off — hold the current side (the cradle). The threshold doubles as the
# hysteresis: flip-flopping requires genuinely alternating strokes above it,
# and a stroke toward the side the blade already holds is a no-op.
static func stroke_side(current_sign: int, v_perp: float, flip_speed: float) -> int:
	if absf(v_perp) < flip_speed:
		return current_sign
	return -1 if v_perp > 0.0 else 1


# 0→1 strength of an inward pull, ramped over [ramp_min, ramp_max] m/s of
# toward-the-body contact speed. Zero for any outward or sub-threshold motion:
# pushing away always has a natural pushing face, so the pull grammar never
# engages there.
static func pull_gesture(v_in: float, ramp_min: float, ramp_max: float) -> float:
	if v_in <= ramp_min:
		return 0.0
	if v_in >= ramp_max:
		return 1.0
	return (v_in - ramp_min) / (ramp_max - ramp_min)


# 0→1 forehand-ness of the blade's body side, blended over ±band metres of
# handedness-normalized body-local X (positive = the blade's natural side).
# Splits an inward pull between the two grammars: full forehand → the rolled
# toe drag, full backhand → the heel cradle (a backhand cannot roll to a
# forehand hook), the blend covering pulls through body centre.
static func forehand_weight(body_x_norm: float, band: float) -> float:
	if band <= 0.0:
		return 1.0 if body_x_norm >= 0.0 else 0.0
	return clampf((body_x_norm + band) / (2.0 * band), 0.0, 1.0)
