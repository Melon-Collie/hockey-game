class_name AdvancedStatsTracker extends RefCounted
## Host-only advanced-stat attribution (analytics plan A1). Turns the shot-event
## signals ShotOnGoalTracker already fires into per-player Corsi/Fenwick counters
## on PlayerStats, which ride the normal stats broadcast to every peer.
##
## Tracks shot-attempt volume and quality off ONE resolution-time signal:
##   shot_counted(pid, blocked, xg) → shot_attempts++ (individual Corsi, iCF);
##                                    shot_attempts_blocked++ when blocked
##                                    (→ Fenwick = iCF − blocked);
##                                    xg_for += xg for unblocked shots (A2, ixG)
##
## shot_counted fires only for genuine shot attempts — a puck directed at the net
## that resolves as on-goal, missed, or blocked. ShotOnGoalTracker does the
## shot-vs-pass classification (directed-at-net geometry + teammate-reception), so
## a quick pass, a wrister used as a pass, a backdoor feed, or a saucer to a
## teammate never reaches here. Counting at RESOLUTION (not release) is what lets
## that classification see the outcome.
##
## PDO and the team CF%/FF% percentages are DERIVED at display time (career_totals
## view / post-game screen) from these plus the existing goals/SOG counters — no
## extra counter here. This is also the seam where A2's expected-goals accumulation
## will live (computed from the shot's geometry).
##
## Only ever constructed/called on the host (like ShotOnGoalTracker / HitTracker);
## the counters it writes are broadcast, so clients see them without running it.

var _registry: PlayerRegistry = null


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


# A resolved shot attempt (ShotOnGoalTracker.shot_counted): Corsi always, the
# blocked subset so Fenwick = shot_attempts − shot_attempts_blocked, and xGF for
# unblocked shots (blocked shots carry no xG, matching the Fenwick convention).
func on_shot_counted(peer_id: int, blocked: bool, xg: float) -> void:
	var record: PlayerRecord = _record(peer_id)
	if record == null:
		return
	record.stats.shot_attempts += 1
	if blocked:
		record.stats.shot_attempts_blocked += 1
	else:
		record.stats.xg_for += xg


func _record(peer_id: int) -> PlayerRecord:
	if _registry == null or peer_id == -1:
		return null
	return _registry.get_record(peer_id)
