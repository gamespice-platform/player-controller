class_name GSPlayerHullView
extends RefCounted

## Where every other player stood on a mover's screen, for [GSPlayerHullRewind] ([member GSPlayerBodyRules.unlag]): the game-independent half of lag-compensated hulls.
## [b]One rule on both ends.[/b] A command names how far behind its tick the sender drew the others (`view_lag_q`, quarter ticks) and the snapshot pair it drew between (`view_back`, `view_span`). The server answers from its own per-tick ring of feet, the client from [member client_fn] (the interpolator's samples of the same two ticks), so the hull a bump meets is the same one on both and a bump is not a correction.
## The game supplies only [member snap_fn], [member view_fn] and (client) [member client_fn], and where its command keeps the four fields. Wiring: docs/collision.md, "Sharing the view".
## A null answer leaves that hull where it stands: no view sent (a bot), a tick the ring no longer holds, a teleport inside the pair. Misses are counted and warned about, not silent.

const CHANNEL := "gs.hullview"

## A jump over this many metres between two samples is a teleport (a pit, a respawn), not movement: the hull stays where it is rather than sliding across the map.
const DEFAULT_TELEPORT_CUT := 10.0

## Misses between two warnings.
const WARN_EVERY := 256

## The rewind this view feeds; [method around] runs through it. Its `feet_fn` and `snap_fn` are set to this view's.
var rewind := GSPlayerHullRewind.new()

## Ticks the ring keeps per player (server). Set from `max_rewind_sec * tick_rate` plus the bracket's slack; 0 keeps nothing (every answer is a miss).
var capacity: int = 0

## Metres between two samples above which they are a teleport and the answer is null.
var teleport_cut: float = DEFAULT_TELEPORT_CUT

## True on the machine that owns the ring (answers from [method record]); false on a client (answers from [member client_fn]).
var is_server: bool = false

## `(feet: Vector3) -> Vector3`: the wire grid of the replicated position (`GSNetVar.wire_value`). Applied to every recorded foot and every rewound hull. Unset: as given.
var snap_fn: Callable = Callable()

## `(mover) -> Array or null`: the last view the mover's command named, `[lag_q, command_tick, back, span]`. Null, or a negative `lag_q`, means none was sent. The game reads these from its command's fields.
var view_fn: Callable = Callable()

## Client only: `(other, older, span, render) -> Vector3 or null`: the other's drawn feet at [param render]. [param older] >= 0 names the bracket `[older, older + span]` (the interpolator's `value_between` with [member teleport_cut]); -1 names none (`value_at`). Null when the interpolator holds no such sample.
var client_fn: Callable = Callable()

## Answers by kind, for a test and a profile: `ring` (server), `interp` (client), `miss` (a tick not held), `teleport`, `none` (no view sent).
var counts: Dictionary = {"ring": 0, "interp": 0, "miss": 0, "teleport": 0, "none": 0}

var _feet: Dictionary = {}


func _init() -> void:
	rewind.feet_fn = feet_for
	rewind.snap_fn = _snap


## Runs [param work] for [param mover]'s step at [param tick] with the other hulls where the mover's last command said they were drawn.
func around(rules: GSPlayerBodyRules, mover: Variant, bodies: Dictionary, tick: int, work: Callable, mover_feet: Variant = null) -> Variant:
	return rewind.around(rules, mover, bodies, tick, work, mover_feet)


# --- The server's ring -------------------------------------------------------

## Records every player's feet (snapped) at [param tick], after the tick's moves. [param positions] is `{key: Vector3}`. A player absent from it is forgotten.
func record(tick: int, positions: Dictionary) -> void:
	if capacity <= 0:
		return
	for id: Variant in positions:
		var by_tick: Dictionary = _feet.get_or_add(id, {})
		by_tick[tick] = _snap(positions[id])
		by_tick.erase(tick - capacity)
	if _feet.size() > positions.size():
		for id: Variant in _feet.keys():
			if not positions.has(id):
				_feet.erase(id)


## Feet of [param id] at exactly [param tick], or null.
func ring_at(id: Variant, tick: int) -> Variant:
	var by_tick: Dictionary = _feet.get(id, {})
	return by_tick.get(tick)


## [param id]'s feet blended between the samples at [param older] and [param newer] at [param render]; null when either is not held or they are a teleport apart.
func ring_between(id: Variant, older: int, newer: int, render: float) -> Variant:
	var a: Variant = ring_at(id, older)
	var b: Variant = ring_at(id, newer)
	if a == null or b == null:
		return _miss()
	if (a as Vector3).distance_to(b) > teleport_cut:
		return _teleported()
	var alpha := 0.0 if newer <= older else clampf((render - float(older)) / float(newer - older), 0.0, 1.0)
	counts["ring"] += 1
	return (a as Vector3).lerp(b, alpha)


## [param id]'s feet at [param render] with no bracket named: the two ticks around it.
func ring_near(id: Variant, render: float) -> Variant:
	var low := floori(render)
	return ring_between(id, low, low + 1 if float(low) < render else low, render)


func _miss() -> Variant:
	counts["miss"] += 1
	if int(counts["miss"]) % WARN_EVERY == 1:
		GSLog.warn(CHANNEL, "a hull rewind asked for a tick the ring does not hold; the hull stays where it is", {"misses": counts["miss"], "capacity": capacity})
	return null


func _teleported() -> Variant:
	counts["teleport"] += 1
	return null


# --- The answer, both ends ---------------------------------------------------

## `(mover, other, tick) -> Vector3 or null` for [member rewind]: [param other]'s feet on [param mover]'s screen for its step at [param tick].
func feet_for(mover: Variant, other: Variant, tick: int) -> Variant:
	var sent: Variant = view_fn.call(mover) if view_fn.is_valid() else null
	if not (sent is Array) or (sent as Array).size() < 4 or int(sent[0]) < 0:
		counts["none"] += 1
		return null
	var view := resolve(int(sent[0]), int(sent[1]), int(sent[2]), int(sent[3]), tick)
	var render: float = view[0]
	var older: int = view[1]
	var span: int = view[2]
	if is_server:
		return ring_between(other, older, older + span, render) if older >= 0 else ring_near(other, render)
	if not client_fn.is_valid():
		return null
	var answer: Variant = client_fn.call(other, older, span, render)
	counts["interp" if answer != null else "miss"] += 1
	return answer


## `[render, older, span]` for a step at [param tick] from the last command heard: [param command_tick] is the tick it was for. A command repeated over a lost packet keeps its lag, and the pair it named is stepped on by [param span] until it brackets the render tick, as the client's would have been. `older` is -1 for no bracket.
static func resolve(lag_q: int, command_tick: int, back: int, span: int, tick: int) -> Array:
	var render := float(tick) - float(lag_q) * 0.25
	var older := -1
	if back >= 0 and command_tick >= 0:
		older = command_tick - back
		if span > 0 and render > float(older + span):
			older += int((render - float(older)) / float(span)) * span
			if float(older) > render:
				older -= span
	return [render, older, span]


## The lag half of the client's fill: quarter ticks between [param tick] and [param drawn] (the fractional tick the client draws the others at), clamped to `0..max_lag_q` (the command field's largest value). The game then asks its interpolator for `bracket_at(tick - lag_q / 4.0)` and passes it to [method bracket_for].
static func lag_q_for(tick: int, drawn: float, max_lag_q: int) -> int:
	return clampi(roundi((float(tick) - drawn) * 4.0), 0, max_lag_q)


## The bracket half of the fill: `[back, span]` for [param bracket] (`Vector2i(older, newer)`, x < 0: none) at [param tick] if both fit the command's bit widths [param back_bits] and [param span_bits], else `[-1, 0]` (left out, never wrapped).
static func bracket_for(tick: int, bracket: Vector2i, back_bits: int, span_bits: int) -> Array:
	if bracket.x >= 0 and tick - bracket.x < (1 << back_bits) and bracket.y - bracket.x < (1 << span_bits):
		return [tick - bracket.x, bracket.y - bracket.x]
	return [-1, 0]


func _snap(feet: Vector3) -> Vector3:
	return snap_fn.call(feet) if snap_fn.is_valid() else feet
