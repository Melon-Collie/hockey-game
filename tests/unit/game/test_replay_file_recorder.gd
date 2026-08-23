extends GutTest

# The .mreplay recording policy — the frame throttle, the movement-locked phase
# rule, and the game-id path guard.
#
# None of this had a test before, because all three lived inside GameManager and
# needed a whole match standing up to reach. They are the rules that decide what
# a recording CONTAINS: a throttle that drops a keyframe loses the faceoff snap,
# a phase rule that admits every locked tick quadruples the file with duplicate
# static frames, and a lax id guard lets a hostile host name a path.
#
# The two policy halves are static and pure over (phase, last_phase) and
# (host_ts, last_frame_ts, …), which is what makes them reachable here without a
# writer, a match, or a file on disk.

const _RATE: float = 1.0 / float(Constants.REPLAY_FILE_RATE)


# ── Game id guard ────────────────────────────────────────────────────────────

func test_a_game_id_may_not_name_a_path() -> void:
	# The wire permits arbitrary strings, so this guard is what stops a hostile
	# notify_game_reset writing outside the replays folder.
	for bad: String in ["../etc/passwd", "a/b", "..", "x.y", "a b", "",
			"/absolute", "a\\b", "réplay"]:
		assert_false(ReplayFileRecorder.is_valid_game_id(bad),
				"%s should be rejected" % [bad])
	assert_false(ReplayFileRecorder.is_valid_game_id("a".repeat(65)),
			"an over-long id is rejected before it reaches the filesystem")
	for ok: String in ["deadbeef-1234-5678-9abc-def012345678", "abc_DEF-123",
			"a", "a".repeat(64)]:
		assert_true(ReplayFileRecorder.is_valid_game_id(ok),
				"%s is a legitimate id" % ok)


# ── Phase policy ─────────────────────────────────────────────────────────────

func test_a_recording_that_predates_the_state_machine_takes_everything() -> void:
	assert_true(ReplayFileRecorder.phase_admits(-1, -1),
			"with no phase to judge by, record the frame")


func test_only_the_first_frame_of_a_movement_locked_phase_is_kept() -> void:
	# GOAL_SCORED's transition frame is the puck-in-net moment; the ticks after
	# it are duplicate static state. Keeping them all was the file-size problem
	# and keeping none of them lost the goal.
	var locked: int = GamePhase.Phase.GOAL_SCORED
	assert_true(PhaseRules.is_movement_locked(locked), "premise of this test")
	assert_true(ReplayFileRecorder.phase_admits(locked, GamePhase.Phase.PLAYING),
			"the transition frame into a locked phase is a keyframe")
	assert_false(ReplayFileRecorder.phase_admits(locked, locked),
			"and every duplicate static tick after it is dropped")


func test_the_faceoff_walk_up_is_recorded_frame_after_frame() -> void:
	# FACEOFF_PREP is movement-locked for INPUT, but the skaters skate in over
	# the "2 → 1 → DROP" countdown. Treating it as locked made the viewer
	# teleport from the pre-approach frame straight to the drop.
	var prep: int = GamePhase.Phase.FACEOFF_PREP
	assert_true(PhaseRules.is_movement_locked(prep),
			"premise: prep IS movement-locked, which is why it needs the exception")
	assert_true(ReplayFileRecorder.phase_admits(prep, GamePhase.Phase.GOAL_SCORED))
	assert_true(ReplayFileRecorder.phase_admits(prep, prep),
			"unlike the other locked phases, prep stays recordable")


func test_live_play_is_always_recordable() -> void:
	var playing: int = GamePhase.Phase.PLAYING
	assert_true(ReplayFileRecorder.phase_admits(playing, playing))


# ── Throttle ─────────────────────────────────────────────────────────────────

func test_the_steady_stream_is_decimated_to_the_file_rate() -> void:
	# The broadcast runs at STATE_RATE; the viewer interpolates, so the file
	# keeps roughly one frame in four.
	var playing: int = GamePhase.Phase.PLAYING
	assert_false(ReplayFileRecorder.admits_frame(10.0 + _RATE * 0.5, 10.0,
			playing, playing), "half a period in is too soon")
	# Nudged just past the boundary rather than sitting on it: 10.0 + _RATE
	# reads back a hair under _RATE, so an exact-boundary probe tests float
	# addition rather than the throttle.
	assert_true(ReplayFileRecorder.admits_frame(10.0 + _RATE * 1.01, 10.0,
			playing, playing), "a full period apart writes")
	assert_true(ReplayFileRecorder.admits_frame(10.0, -INF, playing, playing),
			"the first frame of a recording always writes")


func test_a_phase_transition_bypasses_the_throttle() -> void:
	# The first frame of a new phase is a keyframe — the faceoff snap, the
	# resume after a movement-locked gap — and dropping it to the throttle
	# leaves the viewer interpolating across the discontinuity.
	assert_true(ReplayFileRecorder.admits_frame(10.0 + _RATE * 0.01, 10.0,
			GamePhase.Phase.PLAYING, GamePhase.Phase.FACEOFF_PREP),
			"a transition frame writes however recently the last one did")
	assert_false(ReplayFileRecorder.admits_frame(10.0 + _RATE * 0.01, 10.0,
			-1, GamePhase.Phase.PLAYING),
			"but an unknown phase is not a transition, so the throttle still holds")


# ── Lifecycle ────────────────────────────────────────────────────────────────

func test_a_closed_recorder_is_inert() -> void:
	# The common case: recording disabled, free play, tutorial, drills. Every
	# call site is unguarded on purpose, so all of them have to be safe.
	var rec := ReplayFileRecorder.new()
	assert_false(rec.is_open())
	rec.record_frame(1.0, PackedByteArray([1, 2]), GamePhase.Phase.PLAYING)
	rec.force_frame(1.0, PackedByteArray([1, 2]), GamePhase.Phase.PLAYING)
	rec.record_event(1.0, PackedByteArray([3]))
	rec.close({"final_score_home": 1})
	rec.reset_phase()
	assert_false(rec.is_open(), "and it is still closed afterwards")


func test_an_empty_game_id_never_opens_a_file() -> void:
	# Free play / tutorial / drill have no game id, and must not leave a file
	# behind — nor purge the player's kept recordings on the way past.
	var rec := ReplayFileRecorder.new()
	rec.open("", {})
	assert_false(rec.is_open())


func test_the_roster_entry_is_the_one_description_of_a_player() -> void:
	# Header roster and the mid-game player_joined event go through this, so the
	# viewer spawns from either through the same path. GameManager re-exports it
	# under its old name for the viewer-side decode.
	var record := PlayerRecord.new(7, 2, false, null)
	record.player_name = "Tester"
	record.jersey_number = 44
	record.is_left_handed = false
	var entry: Dictionary = ReplayFileRecorder.roster_entry(record)
	assert_eq(entry.peer_id, 7)
	assert_eq(entry.jersey_number, 44)
	assert_eq(entry.team_id, 0, "a record with no team lands on team 0")
	for key: String in ["build", "tape_code", "skin_tone", "gear_style_code"]:
		assert_true(entry.has(key),
				"%s must survive into the file, or the viewer renders a stock kit" % key)
