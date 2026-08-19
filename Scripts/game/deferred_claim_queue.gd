class_name DeferredClaimQueue
extends RefCounted

# Holds a client claim until the host has actually simulated the instant it
# names.
#
# Every claim's rewind is anchored on `LagCompRewind.self_view_time` — host_ts
# plus the claimant's input lead — but the host holds a client's input until its
# stamp comes due (`RemoteController._drive_from_input` gates on
# `host_timestamp`), so at claim ARRIVAL the newest capture sits at
# host_ts + one_way. Whenever the lead exceeds the one-way trip — by design on
# any healthy link, since the lead's whole job is to buy host-side queue depth —
# resolving on arrival reads a world the host has not reached yet, and
# `StateBufferManager.get_state_at` answers that future query with the newest
# sample and no signal at all. The claim jumps ahead of the very input that
# defines the instant it is claiming about.
#
# So claims execute on the input stream's timeline rather than on arrival: park
# until the buffer covers the claim's self-view instant, then run the resolver
# against an ordinary past lookup. This is what Source gets for free by carrying
# the action IN the usercmd (the rewind happens when the command is executed,
# never when it arrives), and what Overwatch gets by buffering command frames to
# their referenced tick. Mitts' own shot release already works this way — the
# host replays the release input instead of taking an RPC — so this brings the
# four claim paths onto that footing.
#
# Release is gated on the BUFFER's newest capture, not on wall time: capture
# runs end-of-tick (`PostPhysicsNetHook`), so wall-now is always a tick ahead of
# what the buffer can answer. Gating on the buffer is the same "safe time" rule
# a distributed store uses to serve a snapshot read at a timestamp — wait until
# the timestamp is covered, never extrapolate to answer early.
#
# The cost is bounded and one-sided: a claim waits (lead - one_way), never more
# than the lead ceiling, and nothing at all once one_way exceeds the lead. Fast
# links pay a few ms; slow links pay zero and are bit-identical to before.

# Backstop on how long one claim may sit parked. `due` is already bounded — the
# stamp is validated at the RPC boundary (`is_claim_stamp_plausible`) and the
# lead is clamped — so this only catches a clock glitch that would otherwise
# park a claim past any instant the buffer will reach.
const MAX_HOLD_S: float = 0.25


class Entry:
	var due: float = 0.0
	var call: Callable = Callable()
	var args: Array = []


# Ascending by `due`, so the drain pops from the front and claims resolve in the
# order their instants OCCURRED rather than the order their packets landed.
var _pending: Array[Entry] = []


# Runs the resolver immediately when the buffer already covers `due`, otherwise
# parks it. `newest_ts` is `StateBufferManager.newest_host_timestamp()`; a
# negative value means nothing has been captured yet, in which case there is no
# timeline to wait for and the resolver's own readiness gate owns the outcome.
func submit(due: float, newest_ts: float, call: Callable, args: Array) -> void:
	if not call.is_valid():
		return
	if not is_finite(due) or newest_ts < 0.0 or due <= newest_ts:
		call.callv(args)
		return
	var entry := Entry.new()
	entry.due = minf(due, newest_ts + MAX_HOLD_S)
	entry.call = call
	entry.args = args
	var i: int = _pending.size()
	while i > 0 and _pending[i - 1].due > entry.due:
		i -= 1
	_pending.insert(i, entry)


# Releases every claim whose instant the buffer now covers, oldest first. Called
# once per host physics frame, BEFORE the resolvers' own tick so a released
# pickup claim can still arm the contest window on the frame it lands.
func drain(newest_ts: float) -> void:
	if _pending.is_empty() or newest_ts < 0.0:
		return
	while not _pending.is_empty() and _pending[0].due <= newest_ts:
		var entry: Entry = _pending.pop_front()
		if entry.call.is_valid():
			entry.call.callv(entry.args)


# Dropped wholesale on reset / rematch / dead-puck phases. A claim parked across
# a faceoff describes a world that no longer exists, and unlike the arm-and-wait
# inside PickupClaimResolver there is no partial state to unwind — every
# resolver's reject list is evaluated at RELEASE, not at submit, so dropping is
# always safe and never leaves a half-applied effect.
func clear() -> void:
	_pending.clear()


func size() -> int:
	return _pending.size()
