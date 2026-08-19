class_name HitRules

# Pure rules for crediting a body check as a "hit" stat. No engine deps.
# Mirrors the NHL scorer definition: a hit is credited when a player initiates
# body contact with an opponent IN POSSESSION of the puck, and the contact
# causes that opponent to lose possession. Deterministic version:
#   • impulse (hitter weight × closing velocity, so mass lowers the closing
#     speed a heavy hitter needs) clears MIN_HIT_IMPULSE — the host-observed
#     contact and the lag-comp claim both validate this same weight-scaled
#     magnitude, so hosted and remote hitters meet one bar
#   • the attacker is not carrying the puck
#   • the victim just lost/released the puck within JUST_RELEASED_GRACE_S —
#     a finished check; NHL scorers credit a hit that lands right after the
#     pass → CREDIT
#   • the victim is carrying → CREDIT_PENDING: the stat lands only if the
#     check DISPOSSESSES them (strip / knock-loose) within
#     POSSESSION_LOSS_WINDOW_S of the contact. A deliberate pass or shot in
#     that window cancels the pending instead — they played through the
#     check, so the contact didn't cost possession (HitTracker resolves
#     the pending via note_possession_stripped vs note_possession_released)
#   • otherwise (victim nowhere near possession) → REJECT

enum Verdict { REJECT, CREDIT, CREDIT_PENDING }

# Minimum impulse magnitude (hitter weight × closing speed, m/s).
const MIN_HIT_IMPULSE: float = 3.0
# Empirical landmarks on the SAME impact_force scale, for presentation code that
# has to decide "how big did that hit read?" (VFX burst, thud gate, camera kick).
# They live here so the scale is described in ONE place instead of being restated
# as bare literals at each consumer.
#
# These are OBSERVED landmarks, not derivations. The victim-side impulse the
# stagger keys off (BodyCheckRules.Config.ref_impulse 1.35, knockdown_impulse
# 1.8) is this magnitude divided through the collision's reduced mass, so the
# mapping moves with the victim's build (mass_mult spans 0.79–1.28). There is no
# exact constant conversion — do not "derive" one.
const FULL_CHECK_IMPULSE: float = 4.0   # a one-sided full-strength check ("skate in at pace")
const KNOCKDOWN_IMPULSE: float = 5.5    # a committed solid hit that knocks the victim down
# A hard head-on MUTUAL collision (both bodies closing) lands ~12–14.
# A contact this soon after the victim lost/released the puck still counts as a
# hit on the carrier (the check "finishes" through the pass).
const JUST_RELEASED_GRACE_S: float = 0.5
# A contact on the carrier is credited only if possession is lost within this.
const POSSESSION_LOSS_WINDOW_S: float = 0.8


static func classify_contact(
		impulse_magnitude: float,
		attacker_has_puck: bool,
		victim_is_carrier: bool,
		seconds_since_victim_lost_possession: float,
		attacker_committed: bool = true) -> Verdict:
	# A "hit" now requires the attacker to have COMMITTED with the Hit button — an
	# uncommitted bump (e.g. drifting into someone right after a stick check, while
	# not holding Ctrl) is incidental contact, not a body check, and isn't credited.
	# This also gates the impact burst/sound (HitTracker only fires those on a
	# credited-or-pending verdict), so incidental contact stops reading as a hit.
	if not attacker_committed:
		return Verdict.REJECT
	if impulse_magnitude < MIN_HIT_IMPULSE:
		return Verdict.REJECT
	if attacker_has_puck:
		return Verdict.REJECT
	# Grace is checked BEFORE the carrier flag: a same-tick strip (or a lag-comp
	# claim arriving after the host already saw the puck come loose) can present
	# a stale victim_is_carrier — the live possession loss wins, so the hit
	# credits immediately instead of pending on a loss that already happened.
	if seconds_since_victim_lost_possession <= JUST_RELEASED_GRACE_S:
		return Verdict.CREDIT
	if victim_is_carrier:
		return Verdict.CREDIT_PENDING
	return Verdict.REJECT
