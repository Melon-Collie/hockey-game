extends GutTest

# ── THE HUMAN'S MOVE, MEASURED ───────────────────────────────────────────────
# "Skate at the goalie to commit him to a butterfly, then skate around and wrap
# it around him." It is one player's whole offence and it is where the live log
# says the keeper is worst: inside 3 m against a DOWN keeper is 46.7% of that
# player's shots at 24.0% save percentage, and the COILING stance alone is 21.5%
# of them at 11.3%.
#
# `human_wraparound_harness` drives the real GoalieController and the real puck
# → goalie collision through the whole sequence. Everything below is either a
# structural assertion about the sequence or a pinned characterisation of it.
#
# ══ WHAT THE INSTRUMENT AGREES WITH, AND WHAT IT DOES NOT ═══════════════════
# It reproduces the SHAPE: the goals are in tight, off-angle, against a keeper
# who is not where the shot is. It does NOT reproduce the LEVEL — the best cell
# here converts 4 aim points of 7 where the live player converts three quarters
# of everything he takes from that cell. Two differences are known and neither
# is modelled: every trial starts from a fully settled keeper (live, 54.5% of
# this player's shots are at a keeper still in motion, at 35.0% save percentage),
# and there is no traffic, no rebound and no prior event to have disturbed him.
# Quote the ORDERING of cells from this file, not the rates.
#
# ══ AND ONE PLACE IT CONTRADICTS THE LIVE READING ═══════════════════════════
# `tools/goalie_shot_events_depth_when_down.sql` finds save percentage falling
# hard with the keeper's radius at the release while he is down, and that was
# read as "dropping while aggressive is the defect". Held to a FIXED release
# point, this instrument finds the opposite: a commit baited further out is
# beaten LESS, not more (test_committing_further_out_is_not_what_beats_him).
#
# The mechanism it offers for that is measured here too — the committed slide
# spends 94% of its travel on DEPTH, so a keeper who commits early has finished
# retreating to his line by the time the shot comes, and one who commits late is
# caught mid-transit. Which makes the live radius column a proxy for HOW
# RECENTLY HE WAS DISTURBED rather than a cause, and "he drops too far out" a
# description of the symptom rather than of the defect.

const GOAL_Z: float = -GameRules.GOAL_LINE_Z
const Harness := preload("res://tests/unit/ai/human_wraparound_harness.gd")
const SkaterScene := preload("res://Scenes/Skater.tscn")
const ST: Array[String] = ["STANDING", "BUTTERFLY", "RECOVERING", "RVH_LEFT",
		"RVH_RIGHT", "READY", "SLIDING", "COILING", "VH_LEFT", "VH_RIGHT",
		"COVERING", "PLAYING_PUCK", "CATCHING", "CATCHING_DOWN"]
# Seven aim points spanning the mouth, one puck radius inside each post. The
# measurement is HOW MUCH NET IS OPEN, not whether a shooter who already knows
# the answer can find it — so every trial fires the whole fan and the score is
# the count that goes in. A "best of the fan" reading would credit an oracle.
const AIM_X: Array[float] = [-0.85, -0.55, -0.25, 0.0, 0.25, 0.55, 0.85]
const SHOT_M_S: float = 18.0        # an in-tight tuck, not a bomb
const START_M: float = 9.0          # where the drive begins, perpendicular
const DRIVE_M_S: float = 5.0
const PULL_M: float = 1.1           # forehand→backhand amplitude
const PULL_S: float = 0.25

var _h: RefCounted = null
var _ctrl: GoalieController = null


func before_each() -> void:
	var goalie: Node = load("res://Scenes/Goalie.tscn").instantiate()
	var puck: Node = load("res://Scenes/Puck.tscn").instantiate()
	var shooter: Skater = SkaterScene.instantiate() as Skater
	_ctrl = GoalieController.new()
	for n: Node in [goalie, puck, shooter, _ctrl]:
		add_child_autofree(n)
	_h = Harness.new()
	_h.setup(goalie, puck, _ctrl, shooter)


func _reset() -> void:
	_h.settle_ready(Vector3(0.0, 0.0, GOAL_Z + START_M))
	_h.begin_trial()


# ── 1. NOTHING ABOUT DRIVING AT HIM MAKES HIM DROP ───────────────────────────
# The move is described as "skate at the goalie to commit him", and the drive on
# its own does not: not at any pace, not to any depth short of running him over,
# and not with the trigger held down the whole way in. Whatever commits him in a
# real game — traffic, a rebound, a previous shot — is not the straight skate.
#
# This has teeth in both directions. A doorstep-proximity drop reintroduced
# anywhere in `_should_block` fails it, and so does a shot-threat read that
# starts firing off a plain carried wind-up on the rush.
func test_a_straight_drive_never_takes_him_off_his_feet() -> void:
	var aims: Array = [Vector3.INF, Vector3(0.6, 0.10, GOAL_Z)]
	for declared: Vector3 in aims:
		for speed: float in [4.0, 5.5, 7.0]:
			for floor_d: float in [0.8, 1.2, 2.0, 3.2]:
				_reset()
				var down: bool = _h.bait_commit(0.0, START_M, floor_d, speed,
						0.0, PULL_S, INF, declared)
				assert_false(down,
						"%s drive at %.1f m/s to %.1f m must not take him off his feet"
						% ["winding" if declared != Vector3.INF else "cold",
						speed, floor_d])


# ── 2. THE PUCK GOING ACROSS IS THE WHOLE BAIT ───────────────────────────────
# And it commits him to a SLIDE (COILING), not to an idle butterfly — the
# beaten-wide post seal, fired on the accomplished fact that the puck has passed
# his standing sealing reach. That matters for reading the live log: the keeper
# the player describes "butterflying too far out" is a keeper mid-seal.
#
# The second assertion is the one this test exists for. Where he commits is a
# controllable input — pull earlier and he goes down further out — which is what
# lets every table below be cut on his commit radius.
func test_pulling_the_puck_across_is_what_commits_him() -> void:
	var radii: Array[float] = []
	for pull_at: float in [2.5, 3.5, 4.5]:
		_reset()
		var down: bool = _h.bait_commit(0.0, START_M, 0.9, DRIVE_M_S,
				PULL_M, PULL_S, pull_at)
		gut.p("pull at %.1f m -> commit %s at radius %.2f, carrier %.2f m out, %s"
				% [pull_at, down, _h.commit_radius, _h.commit_dist,
				ST[_h.commit_stance] if down else "-"])
		assert_true(down, "a %.1f m pull inside %.1f m must commit him"
				% [PULL_M, pull_at])
		assert_eq(_h.commit_stance, GoalieStateMachine.State.COILING as int,
				"the commit is the beaten-wide seal, not an idle butterfly")
		radii.append(_h.commit_radius)
	assert_lt(radii[0], radii[1], "pulling later commits him deeper")
	assert_lt(radii[1], radii[2], "pulling earlier commits him further out")
	# He runs out of room to be baited before the crease top: a pull outside
	# ~4.5 m is inside his standing coverage and he simply tracks it, so no clean
	# walk-in reaches the 1.30-1.60 m radius band the live log holds 26 shots in.
	# Those rows come from somewhere this instrument does not go.
	assert_lt(radii[2], 1.05,
			"a clean walk-in cannot bait a commit past ~1 m of challenge radius")


# ── 3. THE COMMITTED SLIDE IS A RETREAT, NOT A PUSH ──────────────────────────
# 94% of its travel is DEPTH. The lateral leg is 8 cm because the seal target is
# 15 cm off centre, and that is geometry rather than a tuning choice: a butterfly
# pad lies 0.84 m along the ice from the body, so the body sits at
# `net_half_width - 0.84 * cos(slide rotation)` = 0.154 m to put the pad's outer
# edge on the post. There is nowhere further to go.
#
# The consequence is the whole scenario. A commit at 0.78 m of challenge radius
# is a keeper who owes 1.2 m of retreat and takes ~0.48 s to pay it, and every
# tick of that is spent in COILING or SLIDING — the two stances the live log
# scores at 11.3% and 31.6% against this player.
func test_the_committed_slide_spends_itself_on_depth() -> void:
	_reset()
	_h.trace_enabled = true
	assert_true(_h.bait_commit(0.0, START_M, 0.9, DRIVE_M_S, PULL_M, PULL_S, 4.0),
			"precondition: the bait commits him")
	var x0: float = _ctrl.lateral_x()
	var r0: float = _ctrl.challenge_radius()
	_h.wrap_to(-1.35, 0.70, 4.0)
	var lateral: float = 0.0
	var depth: float = 0.0
	var settled_s: float = INF
	var px: float = x0
	var pr: float = r0
	for row: Array in _h.trace:
		lateral += absf(row[2] - px)
		depth += absf(row[3] - pr)
		px = row[2]
		pr = row[3]
		if is_inf(settled_s) and int(row[1]) == GoalieStateMachine.State.BUTTERFLY:
			settled_s = row[0]
	var seal_x: float = _ctrl.net_half_width \
			- (_ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width) \
			* cos(deg_to_rad(_ctrl.slide_max_rotation_deg))
	gut.p("commit at x %+.3f r %.3f | slide travel: lateral %.3f m, depth %.3f m | idle butterfly at %.3f s"
			% [x0, r0, lateral, depth, settled_s])
	gut.p("post-edge seal x %.3f  (pad edge %.2f m, %.0f deg of slide rotation, net half %.3f)"
			% [seal_x, _ctrl.pad_local_offset + _ctrl.butterfly_pad_half_width,
			_ctrl.slide_max_rotation_deg, _ctrl.net_half_width])
	assert_almost_eq(seal_x, 0.154, 0.01,
			"the seal spot is a pad length short of the post, by construction")
	assert_gt(depth, 8.0 * lateral,
			"the seal is overwhelmingly a retreat to the line, not a sideways push")
	assert_between(settled_s, 0.30, 0.75,
			"and it takes most of half a second, all of it spent down and moving")


# ── 4. THE WALKAROUND, AND WHAT IT IS WORTH ──────────────────────────────────
# Every trial baits the same commit and ends at the SAME release point, so the
# only thing that varies is which way the carrier went around him. Both
# directions are run because they are different plays: continuing to the side
# the puck was pulled to, and cutting back across into the space he left.
#
# The measurement is the count of the seven-point aim fan that goes in — how
# much net is open — and the finding is that the two directions are not close.
# Cutting back across converts nothing at all: he re-decides and re-commits
# toward the puck while it crosses, and arrives.
func test_the_walkaround_beats_him_and_the_cutback_does_not() -> void:
	var opened: Dictionary = {}
	for side: float in [-1.0, 1.0]:
		var open: int = 0
		var last: Dictionary = {}
		var rel_x: float = 0.0
		var rel_d: float = 0.0
		for ax: float in AIM_X:
			_reset()
			_h.bait_commit(0.0, START_M, 0.9, DRIVE_M_S, PULL_M, PULL_S, 3.5)
			var rel: Vector3 = _h.wrap_to(side * 1.35, 0.70, 4.0)
			last = _h.release_ctx()
			rel_x = rel.x
			rel_d = Vector2(rel.x, rel.z - GOAL_Z).length()
			if _h.fire_release_at(rel, Vector3(ax, 0.0, GOAL_Z), 0,
					SHOT_M_S, 0.0) == 0:
				open += 1
		opened[side] = open
		gut.p("%s | release x %+.2f (%.2f m from goal) | keeper x %+.2f r %.2f %s | open %d/%d"
				% ["walk to the pull side " if side < 0.0 else "cut back across",
				rel_x, rel_d, last["x"], last["radius"], ST[last["stance"]],
				open, AIM_X.size()])
	# THE INSTRUMENT'S TEETH. A harness that saves everything is measuring its
	# own setup, not the goalie: the move this file exists to model has to be
	# able to score, or nothing below it means anything.
	assert_gt(opened[-1.0] as int, 0,
			"walking around him on the pull side must open net — a shut-out harness measures nothing")
	assert_gt(opened[-1.0] as int, opened[1.0] as int,
			"and it must beat the cutback, which he answers by re-committing")


# ── 5. COMMITTING FURTHER OUT IS NOT WHAT BEATS HIM ──────────────────────────
# The live cut says save percentage collapses with his radius at the release
# while he is down. Held to one release point, the causal version of that claim
# is false here and reversed: baiting the commit EARLIER — further out — leaves
# less net open, because the extra time is time he spends completing the
# retreat. The keeper who gets beaten is the one caught mid-transit.
#
# Pinned as a characterisation, not as an assertion about the right behaviour.
# If a change to the drop decision or to the slide makes an early commit worse
# than a late one, this is the test that says so, and re-pinning it is the
# correct response once that change is the intended one.
func test_committing_further_out_is_not_what_beats_him() -> void:
	var by_radius: Array = []
	for pull_at: float in [2.5, 3.5, 4.5]:
		var open: int = 0
		var commit_r: float = 0.0
		var last: Dictionary = {}
		for ax: float in AIM_X:
			_reset()
			_h.bait_commit(0.0, START_M, 0.9, DRIVE_M_S, PULL_M, PULL_S, pull_at)
			var rel: Vector3 = _h.wrap_to(-1.35, 0.70, 4.0)
			commit_r = _h.commit_radius
			last = _h.release_ctx()
			if _h.fire_release_at(rel, Vector3(ax, 0.0, GOAL_Z), 0,
					SHOT_M_S, 0.0) == 0:
				open += 1
		by_radius.append([commit_r, open])
		gut.p("commit radius %.2f -> release radius %.2f %-9s | open %d/%d  (save %5.1f%%)"
				% [commit_r, last["radius"], ST[last["stance"]], open,
				AIM_X.size(), 100.0 * (AIM_X.size() - open) / AIM_X.size()])
	var shallow: int = by_radius[0][1]
	var deep: int = by_radius[2][1]
	assert_gte(shallow, deep,
			"a commit baited later (deeper) leaves at least as much net open as one baited early")
