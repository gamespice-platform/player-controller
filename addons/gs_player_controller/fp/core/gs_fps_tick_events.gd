class_name GSFpsTickEvents
extends RefCounted

## One tick's motor edges for every player as one packed table, instead of each [GSFpsController] diffing and emitting its
## own. A game hands the controllers one table ([member GSFpsController.event_rows]); each [method GSFpsController.end_tick]
## records an input row of what it compared ([method record]); after the tick the game calls [method derive] once and
## [method GSFpsController.dispatch_events] walks each player's events. With gs-sim's [code]GSSimTickEvents[/code]
## ([code]GSSim.has(&"events")[/code]) and [member native_enabled] the rows become events in one native call; otherwise
## in script, to the bit the same ([code]examples/tick_events_parity[/code]). The derive is gs-sim's
## [code]gs-sim-events[/code] crate: a change here must be made there too.

## Input row: 18 floats a player.
const IN := 18
const IN_ENTITY := 0
const IN_FLAGS := 1
const IN_STEP_HEIGHT := 2
const IN_B_MODE := 3
const IN_B_Y := 4
const IN_B_VY := 5
const IN_B_BITS := 6
const IN_B_LAUNCHES := 7
const IN_B_DASHES := 8
const IN_B_WALL_JUMPS := 9
const IN_A_MODE := 10
const IN_A_Y := 11
const IN_A_VY := 12
const IN_A_BITS := 13
const IN_A_LAUNCHES := 14
const IN_A_DASHES := 15
const IN_A_WALL_JUMPS := 16
const IN_VIEW_TURN := 17

## [constant IN_FLAGS]: the tick is a replay (only mode, step and crouch edges are reported).
const FLAG_REPLAYING := 1
const BIT_CROUCHED := 1
const BIT_SLIDING := 2
const BIT_WALL_RUNNING := 4
## [enum GSFpsState.Mode]'s GROUND and AIR, as the native derive knows them.
const MODE_GROUND := 0
const MODE_AIR := 1

## An event: [code][entity, kind, i0, i1][/code] in [member ints], [code][f0, f1][/code] in [member floats].
const INTS := 4
const FLOATS := 2
## [member side] bits: the row's controller holds a surface change, modifier changes, and its
## [signal GSFpsController.simulated] for [method GSFpsController.dispatch_row] (not derived: the payload stays on the
## controller, the native derive never sees them).
const SIDE_SURFACE := 1
const SIDE_MODIFIERS := 2
const SIDE_SIMULATED := 4
## The most events one row can make.
const MAX_PER_ROW := 10

## [code]i0, i1[/code] = from, to mode; LANDED [code]f0[/code] = impact; STEPPED_UP and VIEW_TURNED [code]f0[/code] = height,
## degrees; the *_CHANGED edges [code]i0[/code] = 1 when on.
enum Kind {
	MODE_CHANGED, LANDED, JUMPED, STEPPED_UP, CROUCH_CHANGED, SLIDE_CHANGED, LAUNCHED, DASHED, WALL_JUMPED,
	WALL_RUN_CHANGED, VIEW_TURNED, COUNT,
}

const NATIVE_CLASS := &"GSSimTickEvents"

## Derive natively when the library has the events module (a game's cvar).
static var native_enabled := true
## Whether, on a native table that has gs-sim's [code]derive_slots[/code] ([code]GSSimServerTick[/code], API 55), a
## controller whose motor the batch ran records only a marker row ([method record_slot]) and the native derive reads the
## before and after from the motor's resident row. Same events to the bit (examples/tick_events_parity.gd). On by
## default; a game's operator switch may turn it off.
static var native_slots := true

## [member row_count] input rows of [constant IN] floats; grows, never shrinks.
var rows := PackedFloat64Array()
var row_count: int = 0
## Per input row, its [constant SIDE_SURFACE] | [constant SIDE_MODIFIERS] | [constant SIDE_SIMULATED] bits ([method mark_side]).
var side := PackedInt32Array()
## The derived events: the first [member count] of each (the arrays may be longer).
var ints := PackedInt32Array()
var floats := PackedFloat64Array()
var count: int = 0
## Derives that ran natively.
var native_runs: int = 0
## Marker rows recorded since [method clear] ([method record_slot]).
var slot_rows: int = 0

var _native: Object = null
var _native_checked := false
## Whether [member _native] has [code]derive_slots[/code].
var _slots_ok := false


static func available() -> bool:
	return ClassDB.class_exists(NATIVE_CLASS)


## Forgets the rows and events (the arrays keep their size).
func clear() -> void:
	row_count = 0
	count = 0
	slot_rows = 0


## One controller's tick: [param entity] is what [method GSFpsController.dispatch_events] reports it as, b_* before the
## motor, a_* after; bits are [constant BIT_CROUCHED] | [constant BIT_SLIDING] | [constant BIT_WALL_RUNNING].
func record(entity: int, flags: int, step_height: float,
		b_mode: int, b_y: float, b_vy: float, b_bits: int, b_launches: int, b_dashes: int, b_wall_jumps: int,
		a_mode: int, a_y: float, a_vy: float, a_bits: int, a_launches: int, a_dashes: int, a_wall_jumps: int,
		view_turn: float) -> void:
	var o := row_count * IN
	if rows.size() < o + IN:
		rows.resize(maxi(rows.size() * 2, o + IN))
	rows[o + IN_ENTITY] = entity
	rows[o + IN_FLAGS] = flags
	rows[o + IN_STEP_HEIGHT] = step_height
	rows[o + IN_B_MODE] = b_mode
	rows[o + IN_B_Y] = b_y
	rows[o + IN_B_VY] = b_vy
	rows[o + IN_B_BITS] = b_bits
	rows[o + IN_B_LAUNCHES] = b_launches
	rows[o + IN_B_DASHES] = b_dashes
	rows[o + IN_B_WALL_JUMPS] = b_wall_jumps
	rows[o + IN_A_MODE] = a_mode
	rows[o + IN_A_Y] = a_y
	rows[o + IN_A_VY] = a_vy
	rows[o + IN_A_BITS] = a_bits
	rows[o + IN_A_LAUNCHES] = a_launches
	rows[o + IN_A_DASHES] = a_dashes
	rows[o + IN_A_WALL_JUMPS] = a_wall_jumps
	rows[o + IN_VIEW_TURN] = view_turn
	if side.size() <= row_count:
		var _s := side.resize(maxi(side.size() * 2, row_count + 1))
	side[row_count] = 0
	row_count += 1


## Whether a controller may [method record_slot] instead of [method record]: [member native_slots] and
## [member native_enabled] on, and the native table reads the motor's resident rows.
func slots_ready() -> bool:
	return _slots_ok and native_slots and native_enabled


## [method record] for a controller whose tick the motor batch ran natively at resident row [param slot]
## ([member GSFpsMotor.batch_slot]): only the entity, flags and step height; the native derive fills the rest from the
## row (a marker: [constant IN_B_MODE] -1, the slot in [constant IN_B_Y]). Only when [method slots_ready].
func record_slot(entity: int, flags: int, step_height: float, slot: int) -> void:
	var o := row_count * IN
	if rows.size() < o + IN:
		rows.resize(maxi(rows.size() * 2, o + IN))
	rows[o + IN_ENTITY] = entity
	rows[o + IN_FLAGS] = flags
	rows[o + IN_STEP_HEIGHT] = step_height
	rows[o + IN_B_MODE] = -1.0
	rows[o + IN_B_Y] = slot
	if side.size() <= row_count:
		var _s := side.resize(maxi(side.size() * 2, row_count + 1))
	side[row_count] = 0
	row_count += 1
	slot_rows += 1


## ORs [param bits] into the last recorded row's [member side].
func mark_side(bits: int) -> void:
	side[row_count - 1] |= bits


## The entity input row [param row] was recorded for.
func entity_at(row: int) -> int:
	return int(rows[row * IN + IN_ENTITY])


## The cursor past every derived event of [param entity] from [param cursor] (a row whose controller is gone).
func skip(cursor: int, entity: int) -> int:
	while cursor < count and ints[cursor * INTS] == entity:
		cursor += 1
	return cursor


## The rows' events into [member ints] and [member floats], in row order; answers [member count]. Marker rows
## ([method record_slot]) always derive natively.
func derive(native: bool = native_enabled) -> int:
	if slot_rows > 0 and _slots_ok:
		count = int(_native.call(&"derive_slots", rows, row_count))
		ints = _native.call(&"ints")
		floats = _native.call(&"floats")
		native_runs += 1
		return count
	if native and _native_ready():
		count = int(_native.call(&"derive", rows, row_count))
		ints = _native.call(&"ints")
		floats = _native.call(&"floats")
		native_runs += 1
		return count
	return derive_script()


## [method derive] in script, whatever the switch says (never with marker rows: those derive natively).
func derive_script() -> int:
	count = 0
	if slot_rows > 0:
		push_error("GSFpsTickEvents.derive_script: %d marker rows need the native table" % slot_rows)
	var need := row_count * MAX_PER_ROW
	if ints.size() < need * INTS:
		ints.resize(need * INTS)
		floats.resize(need * FLOATS)
	for r in range(row_count):
		if slot_rows > 0 and rows[r * IN + IN_B_MODE] < 0.0:
			continue
		_derive_row(r * IN)
	return count


func _derive_row(o: int) -> void:
	var e := int(rows[o + IN_ENTITY])
	var before := int(rows[o + IN_B_MODE])
	var after := int(rows[o + IN_A_MODE])
	if before != after:
		_push(e, Kind.MODE_CHANGED, before, after, 0.0)
		if after == MODE_GROUND and before == MODE_AIR:
			_push(e, Kind.LANDED, 0, 0, absf(rows[o + IN_B_VY]))
		elif after == MODE_AIR and before == MODE_GROUND and rows[o + IN_A_VY] > 0.0:
			_push(e, Kind.JUMPED, 0, 0, 0.0)
	if after == MODE_GROUND:
		var gained := rows[o + IN_A_Y] - rows[o + IN_B_Y]
		if gained > 0.001 and gained <= rows[o + IN_STEP_HEIGHT] + 0.01:
			_push(e, Kind.STEPPED_UP, 0, 0, gained)
	var bb := int(rows[o + IN_B_BITS])
	var ab := int(rows[o + IN_A_BITS])
	_edge(e, Kind.CROUCH_CHANGED, bb, ab, BIT_CROUCHED)
	if int(rows[o + IN_FLAGS]) & FLAG_REPLAYING != 0:
		return
	_edge(e, Kind.SLIDE_CHANGED, bb, ab, BIT_SLIDING)
	if rows[o + IN_A_LAUNCHES] != rows[o + IN_B_LAUNCHES]:
		_push(e, Kind.LAUNCHED, 0, 0, 0.0)
	if rows[o + IN_A_DASHES] != rows[o + IN_B_DASHES]:
		_push(e, Kind.DASHED, 0, 0, 0.0)
	if rows[o + IN_A_WALL_JUMPS] != rows[o + IN_B_WALL_JUMPS]:
		_push(e, Kind.WALL_JUMPED, 0, 0, 0.0)
	_edge(e, Kind.WALL_RUN_CHANGED, bb, ab, BIT_WALL_RUNNING)
	if rows[o + IN_VIEW_TURN] != 0.0:
		_push(e, Kind.VIEW_TURNED, 0, 0, rows[o + IN_VIEW_TURN])


func _edge(e: int, kind: int, before: int, after: int, bit: int) -> void:
	if (before ^ after) & bit != 0:
		_push(e, kind, 1 if after & bit != 0 else 0, 0, 0.0)


func _push(e: int, kind: int, i0: int, i1: int, f0: float) -> void:
	var i := count * INTS
	ints[i] = e
	ints[i + 1] = kind
	ints[i + 2] = i0
	ints[i + 3] = i1
	var f := count * FLOATS
	floats[f] = f0
	floats[f + 1] = 0.0
	count += 1


## Derives on [param native] instead of a `GSSimTickEvents` of its own: any object with gs-sim's `layout`, `derive`,
## `ints` and `floats` (a game's native server tick, gs-sim's `GSSimServerTick`, which then answers its `events()`).
## Answers whether it was taken; a wrong layout is said once and the table keeps what it had. Null goes back to its own.
func use_native(native: Object) -> bool:
	if native == null:
		_native = null
		_native_checked = false
		_slots_ok = false
		return true
	for m: StringName in [&"layout", &"derive", &"ints", &"floats"]:
		if not native.has_method(m):
			push_error("GSFpsTickEvents.use_native: %s has no %s" % [native, m])
			return false
	var layout: PackedInt32Array = native.call(&"layout")
	if layout != PackedInt32Array([IN, INTS, FLOATS, Kind.COUNT]):
		push_error("GSFpsTickEvents.use_native: layout %s is not this one" % layout)
		return false
	_native = native
	_native_checked = true
	_slots_ok = native.has_method(&"derive_slots")
	return true


## The object deriving natively (null: none yet, or script).
func native_table() -> Object:
	return _native


## The native table, once, if its layout is this one.
func _native_ready() -> bool:
	if _native_checked:
		return _native != null
	_native_checked = true
	if not available():
		return false
	var o: Object = ClassDB.instantiate(NATIVE_CLASS)
	if o == null or not o.has_method(&"layout"):
		return false
	var layout: PackedInt32Array = o.call(&"layout")
	if layout != PackedInt32Array([IN, INTS, FLOATS, Kind.COUNT]):
		push_warning("GSFpsTickEvents: gs-sim's event layout %s is not this one; deriving in script" % layout)
		return false
	_native = o
	return true
