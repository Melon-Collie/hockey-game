class_name LegIKRules

# Sagittal-plane 2-bone inverse kinematics for the skating leg — the inverse of
# the forward model the gait and test_gait_stroke_profile already use:
#
#   fore = thigh·sin(hip) + shin·sin(hip + knee)   (skate's forward offset from the hip)
#   down = thigh·cos(hip) + shin·cos(hip + knee)   (skate's drop below the hip)
#
# where `hip` is LegL.rotation.x and `knee` is ShinL.rotation.x (both radians).
# Given a target (fore, down) it returns Vector2(hip_pitch, knee_local) that
# places the skate there. The knee takes the BACKWARD-fold branch (shin tucks
# behind the thigh), matching the skating stance where the neutral knee is
# negative. Targets beyond reach clamp to full extension rather than snapping.
#
# Pure/deterministic and value-typed (no allocation) — safe on the hot path and
# the reconcile-replay path, same contract as the other domain rule classes.
static func solve_sagittal(fore: float, down: float, thigh: float, shin: float) -> Vector2:
	var denom: float = 2.0 * thigh * shin
	if denom < 0.000001:
		return Vector2.ZERO
	var r2: float = fore * fore + down * down
	# Law of cosines for the interior knee angle; the negative branch folds the
	# shin back under the body (the stance knee), matching the FK sign.
	var cos_knee: float = clampf((r2 - thigh * thigh - shin * shin) / denom, -1.0, 1.0)
	var knee: float = -acos(cos_knee)
	# Hip pitch: aim the whole leg at the target (β), then rotate back by the
	# thigh↔target-line offset the bent knee introduces (γ).
	var beta: float = atan2(fore, down)
	var gamma: float = atan2(shin * sin(knee), thigh + shin * cos(knee))
	return Vector2(beta - gamma, knee)


# Skating stride conveyor: samples the foot's target for a stride phase θ (rad).
# Returns Vector2(fore, lift): `fore` in [-1, 1] is the fore/aft position along
# the stride (+1 = forward of neutral, -1 = driven back), `lift` in [0, 1] is
# how far the skate is off the ice (0 = planted).
#
# The shape IS a skate stride, not a walk: a SHORT, fast push (the foot snaps
# from its forward-most point back through the drive — the edge planted, so it
# tracks the ice and the body gains speed off it) followed by a LONG, slow
# recovery where the skate lifts and swings forward again. `push_frac` (< 0.5)
# is the fraction of the cycle spent pushing; the smaller it is, the more
# explosive the push relative to the recovery. Pure/value-typed.
static func foot_conveyor(theta: float, push_frac: float) -> Vector2:
	var t: float = wrapf(theta, 0.0, TAU) / TAU
	var p: float = clampf(push_frac, 0.05, 0.95)
	if t < p:
		# Push: fast forward → back, planted on the ice (the drive).
		return Vector2(1.0 - 2.0 * (t / p), 0.0)
	# Recovery: slow back → forward, lifted clear of the ice.
	var u: float = (t - p) / (1.0 - p)
	return Vector2(-1.0 + 2.0 * smoothstep(0.0, 1.0, u), sin(PI * u))
