extends RefCounted

## Every player's controller tick in one call (API 53; its signals through the table since API 54): [method GSFpsController.begin_tick] and
## [method GSFpsMotorBatch.add] for each row in order, then for each row in order [method GSFpsMotorBatch.finish] and
## [method GSFpsController.end_tick], with the game's own work before and after each row as three hooks. The order is
## exactly the loop a game wrote by hand around the motor batch, so the states and signals are the same to the bit; what
## goes is that loop's glue per player.
##
## Every signal of the tick goes through the event table ([member GSFpsController.event_rows] is set for every row): the
## motor's edges, the surface and modifier changes and [signal GSFpsController.simulated] (API 54). The game derives and
## dispatches them once after the call ([method dispatch], or its own walk of [method GSFpsController.dispatch_row]). The
## statistics stay in [method GSFpsController.end_tick]. A player ticked one by one ([method GSFpsController.simulate_tick])
## is the fallback and is unchanged.
##
## No class_name: preload by path ([code]fp/nodes/gs_fps_controller_batch.gd[/code]); [code]examples/tick_events_parity[/code]
## holds it to the one-by-one course.

## What [member rows] holds for a row the game left out this tick (its [code]pre[/code] hook answered below zero).
const ABSENT := -1
## What [member rows] holds for a row present without a motor tick (its delta was zero, or the controller does not tick).
const NO_MOTOR := -2

## The game fills these, one per row in roster order, before [method tick] (a null entry is a row left out). Resized by
## [method resize], never per tick.
var controllers: Array[GSFpsController] = []
## The last [method tick]'s motor row per row, [constant ABSENT] or [constant NO_MOTOR] (the game's hooks may read it).
var rows := PackedInt32Array()
## Each row's delta from its [code]pre[/code] hook (what [method GSFpsController.end_tick] was given).
var deltas := PackedFloat64Array()
## Rows a [code]live[/code] hook refused after they were prepared, and rows finished with external velocity pending, since
## the game last zeroed it (the hand-written loop's batch faults).
var faults: int = 0


## Makes room for [param n] rows; entries past the old size are null.
func resize(n: int) -> void:
	if controllers.size() != n:
		var _c := controllers.resize(n)
		var _r := rows.resize(n)
		var _d := deltas.resize(n)


## One tick of every row. [param pre] [code](row: int) -> float[/code] runs the game's part before the controller (input,
## the command) and answers the row's delta: below zero leaves the row out, zero keeps it without a motor tick.
## [param live] [code](row: int) -> bool[/code] is asked before a prepared row finishes: false skips its motor row (an earlier
## row's turn killed it). [param post] [code](row: int, motor_row: int, told: bool) -> void[/code] runs the game's part after
## the controller's tick; [param told] is [method GSFpsMotorBatch.finish]'s answer, and a post that moves the player calls
## [method GSFpsMotorBatch.moved_after]. [param events] takes every row's motor edges (required: null is refused loudly).
## Answers the rows that ran a motor tick.
func tick(batch: GSFpsMotorBatch, tick_number: int, events: GSFpsTickEvents, pre: Callable, live: Callable, post: Callable) -> int:
	if events == null:
		push_error("GSFpsControllerBatch.tick: an event table is required; nothing ticked")
		return 0
	var n := controllers.size()
	var motored := 0
	for i in range(n):
		rows[i] = ABSENT
		var controller := controllers[i]
		if controller == null:
			continue
		var d: float = pre.call(i)  # perf-lint: allow dynamic_call the game hook per row is the batch API (level 53)
		if d < 0.0:
			continue
		deltas[i] = d
		if d > 0.0 and controller.begin_tick(tick_number, d):
			rows[i] = batch.add(controller.motor, controller.state, controller.current_command, d)
		else:
			rows[i] = NO_MOTOR
	for i in range(n):
		var row := rows[i]
		if row == ABSENT:
			continue
		if not bool(live.call(i)):  # perf-lint: allow dynamic_call the game hook per row is the batch API (level 53)
			faults += 1
			if row >= 0:
				batch.skip(row)
			continue
		var controller := controllers[i]
		controller.event_rows = events
		controller.event_entity = i
		var told := false
		if row >= 0:
			motored += 1
			if controller.has_external_velocity():
				faults += 1
			told = batch.finish(row)
			controller.end_tick(tick_number, deltas[i])
		post.call(i, row, told)  # perf-lint: allow dynamic_call the game hook per row is the batch API (level 53)
		controller.event_rows = null
	return motored


## After [method tick]: derives [param events] once and emits every row's signals through its controller
## ([method GSFpsController.dispatch_row], entities being row numbers as [method tick] records them), then clears the
## table. Answers the derived events.
func dispatch(events: GSFpsTickEvents) -> int:
	var count := events.derive()
	var n := controllers.size()
	var cursor := 0
	for r in range(events.row_count):
		var e := events.entity_at(r)
		var controller: GSFpsController = controllers[e] if e >= 0 and e < n else null
		if controller == null:
			cursor = events.skip(cursor, e)
			continue
		cursor = controller.dispatch_row(events, r, cursor)
	events.clear()
	return count
