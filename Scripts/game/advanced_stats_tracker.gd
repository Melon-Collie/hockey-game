class_name AdvancedStatsTracker extends RefCounted
## Host-only advanced-stat attribution (analytics plan A1). Turns the shot-event
## signals ShotOnGoalTracker already fires into per-player Corsi/Fenwick counters
## on PlayerStats, which ride the normal stats broadcast to every peer.
##
## Tracks shot-attempt volume and quality off ONE resolution-time signal,
## shot_resolved(ShotEvent):
##   shot_attempts++ (individual Corsi, iCF);
##   shot_attempts_blocked++ when the outcome is BLOCKED (→ Fenwick = iCF − blocked);
##   xg_for += event.xg for unblocked shots (A2, ixG — blocked shots carry no xG,
##            matching the Fenwick convention);
## and buffers the ShotEvent (B1) for the shot map / xG-flow / career heatmap.
##
## shot_resolved fires only for genuine shot attempts — a puck directed at the net
## that resolves as on-goal, missed, or blocked. ShotOnGoalTracker does the
## shot-vs-pass classification (directed-at-net geometry + teammate-reception), so
## a quick pass, a wrister used as a pass, a backdoor feed, or a saucer to a
## teammate never reaches here. Counting at RESOLUTION (not release) is what lets
## that classification see the outcome.
##
## PDO and the team CF%/FF% percentages are DERIVED at display time (career_totals
## view / post-game screen) from these plus the existing goals/SOG counters.
##
## Only ever constructed/called on the host (like ShotOnGoalTracker / HitTracker);
## the counters it writes are broadcast, so clients see them without running it.
## The event buffer is host-only (the shot list is shipped to clients / persisted
## by GameManager at game-over) and lives for exactly one game — see reset().

var _registry: PlayerRegistry = null
# Per-game shot log (host-only). A world spawn builds a fresh tracker; a REMATCH
# reuses this one (it never respawns the world), so it is cleared through reset()
# instead — see there for what a stale log costs.
var _shot_events: Array[ShotEvent] = []


func setup(registry: PlayerRegistry) -> void:
	_registry = registry


# Rematch: drop the finished game's shots. The log is posted to Supabase at
# game-over stamped with the CURRENT game_id, so carrying it forward re-uploads
# every earlier game's shots under the new game's id — a career shot map that
# counts the first game of a session once per rematch played after it.
func reset() -> void:
	_shot_events.clear()


# A resolved shot attempt (ShotOnGoalTracker.shot_resolved): Corsi always, the
# blocked subset for Fenwick, xGF for unblocked shots, and the event buffered.
func on_shot_resolved(event: ShotEvent) -> void:
	_shot_events.append(event)
	var record: PlayerRecord = _record(event.shooter_peer)
	if record == null:
		return
	record.stats.shot_attempts += 1
	if event.outcome == ShotEvent.Outcome.BLOCKED:
		record.stats.shot_attempts_blocked += 1
	else:
		record.stats.xg_for += event.xg


# The game's shot log so far (host-only). Read at game-over to ship / persist.
func get_shot_events() -> Array[ShotEvent]:
	return _shot_events


func _record(peer_id: int) -> PlayerRecord:
	if _registry == null or peer_id == -1:
		return null
	return _registry.get_record(peer_id)
