class_name HitRules

# Pure rules for crediting a body check as a "hit" stat. No engine deps.
# Mirrors the NHL scorer definition: a hit is credited when a player initiates
# body contact with an opponent IN POSSESSION of the puck, and the contact
# causes that opponent to lose possession. Deterministic version:
#   • impulse (hitter weight × closing velocity, so Size lowers the closing
#     speed a heavy hitter needs) clears MIN_HIT_IMPULSE — the host-observed
#     contact and the lag-comp claim both validate this same weight-scaled
#     magnitude, so hosted and remote hitters meet one bar
#   • the attacker is not carrying the puck
#   • the victim just lost/released the puck within JUST_RELEASED_GRACE_S —
#     a finished check; NHL scorers credit a hit that lands right after the
#     pass → CREDIT
#   • the victim is carrying → CREDIT_PENDING: the stat lands only if they
#     lose the puck (strip, knock-loose, forced release) within
#     POSSESSION_LOSS_WINDOW_S of the contact
#   • otherwise (victim nowhere near possession) → REJECT

enum Verdict { REJECT, CREDIT, CREDIT_PENDING }

# Minimum impulse magnitude (hitter weight × closing speed, m/s).
const MIN_HIT_IMPULSE: float = 3.0
# A contact this soon after the victim lost/released the puck still counts as a
# hit on the carrier (the check "finishes" through the pass).
const JUST_RELEASED_GRACE_S: float = 0.5
# A contact on the carrier is credited only if possession is lost within this.
const POSSESSION_LOSS_WINDOW_S: float = 0.8


static func classify_contact(
		impulse_magnitude: float,
		attacker_has_puck: bool,
		victim_is_carrier: bool,
		seconds_since_victim_lost_possession: float) -> Verdict:
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
