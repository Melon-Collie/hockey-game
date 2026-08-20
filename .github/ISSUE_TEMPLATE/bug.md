---
name: Bug
about: A defect that exists in the code now
labels: bug
---

<!--
Title: the symptom, then the cause after an em dash — specific enough to be
recognised from the issue list a month later.

  "F3 host row's Queue depth reads 0 frames and pins the header dot to
   PROBLEM — it displays the client-echo counter"

Open with provenance and confidence, in one or two sentences before the first
heading. Both matter to whoever picks this up:

  - where it came from — the branch or PR that surfaced it, or the comment it
    was lifted out of (CLAUDE.md sends deferred work here rather than to a
    TODO; if you deleted the comment, say so, or the content now lives twice)
  - whether it is VERIFIED or SUSPECTED — a report that has been read back
    against the code and one that has not are worth different things, and an
    issue that overstates its confidence gets a fix built on a wrong premise
  - that line numbers are against `main`

Delete every section that does not apply, and delete these comments.
-->

## The bug

<!--
The mechanism, not the symptom: `file.gd:NNN`, the lines themselves, and why
they produce what you are seeing. Follow the data to where it actually comes
from — the defect is usually one seam back from the line that displays it.
-->

## Why it matters

<!--
Who or what is hurt, and how badly. Worth stating plainly when the answer is
"barely" — a small blast radius honestly described is what lets this be ranked
against everything else, and an inflated one just gets discounted later.

If a wrong reading is worse than no reading (a permanently red gauge, a guard
that always passes), that is the thing to lead with.
-->

## Fix sketch

<!--
A sketch, not a spec. It will be read by someone who can see the code you were
looking at, so mark what you are confident in and what you are guessing — and
name any judgement call inside it rather than picking for them. Where you can
see several ways, list them with their real costs.

Expect this to be wrong sometimes: an implementer who measures and comes back
saying the sketch would have been a no-op is the process working.
-->

## Verification

<!--
How the fixer proves it, and how a test holds it afterward. Name the suite, the
measurement that should move, or the render that shows it — and if the only
real check is a live match, say that, since the headless suite cannot run one.

A guard that would have caught this class of defect is worth more than a test
pinning this one instance; if you can see one, sketch it.
-->

## Related

<!--
Issues, PRs, and prior instances. Three of a kind is not three point fixes —
it is an argument for a guard, and worth saying so here.
-->
