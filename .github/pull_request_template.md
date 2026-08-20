<!--
A PR body here is a design record, not a changelog. It is what gets read when
this code looks wrong six months from now, and it is where the reasoning that
is too big to live in a comment goes. GitHub already lists the files that
changed — write the mechanism instead.

Title: an imperative sentence saying what the change does, specific enough to
mean something in `git log` ("Clamp a pre-oldest buffer query to the oldest
sample, not the newest" — not "Fix buffer bug").

Delete every section that does not apply, and delete these comments.
-->

Closes #

<!--
Then the substance, under headings of your own — one per independent change; a
single-purpose PR can just be prose. What belongs here:

  - the mechanism: what was actually wrong, in the terms the code models, not a
    restatement of the patch
  - why the fix has this shape, especially where the obvious one was tried and
    measured and does not work
  - anything reaching past the stated scope, named rather than buried
  - what was declined and on what grounds — a rejected fix sketch is worth more
    to the next reader than a summary of the accepted one
-->

## Ratchets

<!--
Only if `test_no_god_class_growth.gd` entries moved. Give the before/after
numbers and say why this growth is right — a bump with no justification is the
thing the ratchet exists to catch. A file that shrank well below its entry gets
the entry tightened; say that here too, or the win is re-spent quietly.
-->

## Verification

<!--
What was actually run, with results. Not "tests pass".

  bash .claude/hooks/run-gut.sh        full suite — give the counts and exit code
  .claude/hooks/run-lint.sh            gdlint, clean (the pre-commit gate is not proof)
  run-gut.sh -gdir=res://benchmarks    AI perf changes: before/after, per-tick p95/max
  .claude/hooks/render-arena.sh        arena geometry — proportion and placement
  .claude/hooks/render-poses.sh        articulation — diffed against the baseline

A render answers how it reads; it does not answer whether two placements agree.
If the question is the second one, it is a test, and the numbers go here.

A new guard is not verified until it has been seen to FAIL. Sabotage the rule it
holds, confirm the intended assertion fires, and say so — a guard that has only
ever passed may be passing vacuously.
-->

## What to test locally

<!--
Required for anything touching gameplay, netcode, audio or UI: the suite cannot
run the game, so this is the only coverage those changes get before merge.
Numbered steps concrete enough to follow without reading the diff, each saying
what the correct outcome looks like — and call out what will still look wrong on
purpose. If the change genuinely cannot show up in a match (pure domain,
comment-only), say that instead of leaving the section empty.
-->

## Before merging

<!--
Anything that has to happen outside this diff: `native/build.sh` after the gait
tunable list changes, a migration CI applies on merge to `main`, a `.tscn` or
`.tres` edit that is the user's to make in the editor.
-->

## Flagged, not fixed

<!--
Bugs and smells this work surfaced but did not touch — one line each, with
enough detail to file as an issue. Out of scope is a reason to name it, not a
reason to drop it.
-->
