class_name AdvancedStatsTracker extends RefCounted
## Host-only advanced-stat attribution (analytics plan A1). Turns the shot-event
## signals ShotOnGoalTracker already fires into per-player Corsi/Fenwick counters
## on PlayerStats, which ride the normal stats broadcast to every peer.
##
## A1 tracks shot-attempt volume:
##   shot_attempted(pid)        → shot_attempts++          (individual Corsi, iCF)
##   shot_attempt_blocked(pid)  → shot_attempts_blocked++  (→ Fenwick = iCF − blocked)
##
## PDO and the team CF%/FF% percentages are DERIVED at display time (career_totals
## view / post-game screen) from these plus the existing goals/SOG counters — no
## extra counter here. This is also the seam where A2's expected-goals accumulation
## will live (computed at release from the shot's geometry).
##
## Only ever constructed/called on the host (like ShotOnGoalTracker / HitTracker);
## the counters it writes are broadcast, so clients see them without running it.

var _registry: PlayerRegistry = null


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


# Every shot RELEASE (ShotOnGoalTracker.shot_attempted) — the shooter's Corsi.
func on_shot_attempted(peer_id: int) -> void:
	var record: PlayerRecord = _record(peer_id)
	if record != null:
		record.stats.shot_attempts += 1


# The shooter's attempt was blocked (ShotOnGoalTracker.shot_attempt_blocked) —
# subtracted from Corsi to yield Fenwick.
func on_shot_blocked(peer_id: int) -> void:
	var record: PlayerRecord = _record(peer_id)
	if record != null:
		record.stats.shot_attempts_blocked += 1


func _record(peer_id: int) -> PlayerRecord:
	if _registry == null or peer_id == -1:
		return null
	return _registry.get_record(peer_id)
