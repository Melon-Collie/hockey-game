---
name: Planned work
about: Tech debt, performance, an AI model gap, a feature — anything that isn't broken now
---

<!--
Title: what the change achieves, or the gap it closes. State the gap rather than
the wish where you can — "Per-tier shot scatter is inert as a selectivity lever"
locates itself; "Improve bot difficulty" does not.

Open with provenance in a sentence or two before the first heading: the branch,
PR or sweep this came out of, and — if it was lifted from a code comment —
that the comment is deleted and the content is now here. CLAUDE.md sends
deferred work to an issue precisely so it stops living in two places.

Pick a label: tech-debt, performance, enhancement.

Delete every section that does not apply, and delete these comments.
-->

## The gap

<!--
What the code does today and what it should do, in the terms the code models.
Where a doc or an area CLAUDE.md already claims the behaviour this issue is
asking for, quote it — a gap between the documented model and the running one
is a stronger case than a preference, and it tells you which of the two is
wrong.
-->

## Why it matters

<!--
The consequence of leaving it. For AI and evaluation work this is usually a
model argument rather than a numbers one: which quantity the actor cannot
currently see, and what the wrong behaviour reads as at the table (a bot that
is bad at hockey vs. one that is being cautious).

For performance work, bring the measurement. An unprofiled optimisation is a
guess about where the time goes, and this file has a section for that below.
-->

## Fix sketch

<!--
A sketch, not a spec — mark what is confident and what is guessing, and name
the judgement calls rather than settling them here. Grounded models over
tuned curves in anything that evaluates a situation; feel dials are a separate
kind of change and can be named as such.

For a native port, this is where the boundary goes: what moves, what stays as
the GDScript reference, and the known hazards.
-->

## Gates

<!--
What has to be true before this is worth starting, and what has to be true
before it lands. Native ports have standing ones (a seeded parity fuzz test, a
micro-bench row). Perf work's first gate is nearly always a measurement.

Delete if there is nothing to gate.
-->

## Verification

<!--
The measurement or test that shows it worked — named now, while the reasoning
is fresh. Prefer one that separates the thing being fixed from its side
effects: fewer attempts from low-value spots is the fix, a better conversion
rate is a consequence, and a fixture that only reports the second cannot tell
you whether it worked.
-->

## Worth doing?

<!--
An honest answer, and "unknown until measured" is a real one. Say what would
settle it. Delete this section only if the value is genuinely not in question.
-->

## Also update when this lands

<!--
Docs, area CLAUDE.md sections, or axis tables that will be wrong once this
lands — the ones that describe today's behaviour and would quietly become
false. Delete if nothing.
-->
