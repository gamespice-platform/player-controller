@tool
extends "gs_fps_controller_collider.gd"

## The motor edges [GSFpsController] reports after a tick (mode, landing, jump, step, crouch, slide, launch, dash, wall
## jump, wall run, view turn), emitted at once or, with [member event_rows], recorded as a row of a [GSFpsTickEvents]
## table the game derives once for every player and walks with [method dispatch_row]. Kept apart so the controller
## file stays small.

## A game's tick table: while set, [method GSFpsController.end_tick] emits no signal: it records its edges here and
## holds its surface and modifier changes and [signal simulated], and the game emits them all after the tick with
## [method dispatch_row] (API 54; [method dispatch_events] alone emits only the motor's edges). The statistics stay in
## [method GSFpsController.end_tick]. Null (the default) emits everything at once.
var event_rows: GSFpsTickEvents = null
## This controller's entity in [member event_rows].
var event_entity: int = 0

var _before_mode: GSFpsState.Mode = GSFpsState.Mode.GROUND
var _before_y: float = 0.0
var _before_fall: float = 0.0
var _before_crouched: bool = false
var _before_surface: StringName = &""
var _before_sliding: bool = false
var _before_launches: int = 0
var _before_dashes: int = 0
var _before_wall_running: bool = false
var _before_wall_jumps: int = 0
## What [method end_tick] held for [method dispatch_row] with [member event_rows] set: the table's side bits, the surface
## change and the modifier ids (reused, never reallocated a tick).
var _ev_side: int = 0
var _ev_surface_from: StringName = &""
var _ev_surface_to: StringName = &""
var _ev_added: Array[StringName] = []
var _ev_removed: Array[StringName] = []


## Mode, landing, jump and step edges, emitted now (before the crouch and surface ones).
func _emit_early_edges() -> void:
	if motor.may_change(GSFpsMotor.EVENT_MODE) and _before_mode != state.mode:
		mode_changed.emit(_before_mode, state.mode)
		if state.mode == GSFpsState.Mode.GROUND and _before_mode == GSFpsState.Mode.AIR:
			landed.emit(absf(_before_fall))
		elif state.mode == GSFpsState.Mode.AIR and _before_mode == GSFpsState.Mode.GROUND and state.velocity.y > 0.0:
			jumped.emit()

	# A grounded tick that gained height is a stair step, not a jump: the view absorbs it, no jolt per tread.
	if motor.may_change(GSFpsMotor.EVENT_Y) and state.mode == GSFpsState.Mode.GROUND:
		var gained := state.position.y - _before_y
		if gained > 0.001 and gained <= tunables.step_height + 0.01:
			_step_up(gained)


## Slide, launch, dash, wall jump, wall run and view turn edges, emitted now; never during a replay.
func _emit_late_edges() -> void:
	if motor.may_change(GSFpsMotor.EVENT_SLIDE) and state.is_sliding() != _before_sliding:
		slide_changed.emit(state.is_sliding())
	if motor.launches != _before_launches:
		launched.emit()
	if motor.dashes != _before_dashes:
		dashed.emit()
	if motor.wall_jumps != _before_wall_jumps:
		wall_jumped.emit()
	if motor.may_change(GSFpsMotor.EVENT_WALL_RUN) and state.is_wall_running() != _before_wall_running:
		wall_run_changed.emit(state.is_wall_running())
	if motor.view_turn != 0.0:
		_view_turn(motor.view_turn)


## This tick's before and after into [member event_rows].
func _record_event_row(rows: GSFpsTickEvents) -> void:
	var b_bits := (GSFpsTickEvents.BIT_CROUCHED if _before_crouched else 0) \
		| (GSFpsTickEvents.BIT_SLIDING if _before_sliding else 0) \
		| (GSFpsTickEvents.BIT_WALL_RUNNING if _before_wall_running else 0)
	var a_bits := (GSFpsTickEvents.BIT_CROUCHED if state.is_crouched() else 0) \
		| (GSFpsTickEvents.BIT_SLIDING if state.is_sliding() else 0) \
		| (GSFpsTickEvents.BIT_WALL_RUNNING if state.is_wall_running() else 0)
	rows.record(event_entity, GSFpsTickEvents.FLAG_REPLAYING if _replaying else 0, tunables.step_height,
		_before_mode, _before_y, _before_fall, b_bits, _before_launches, _before_dashes, _before_wall_jumps,
		state.mode, state.position.y, state.velocity.y, a_bits, motor.launches, motor.dashes, motor.wall_jumps,
		motor.view_turn)


## Emits the events of [param events] from [param cursor] on that belong to the entity at [param cursor] (this
## controller's [member event_entity]), in table order, with the side effects the at-once path has (the view's step,
## the sampler's turn); answers the cursor after them.
func dispatch_events(events: GSFpsTickEvents, cursor: int) -> int:
	var ints := events.ints
	var floats := events.floats
	var count := events.count
	if cursor >= count:
		return cursor
	var e := ints[cursor * GSFpsTickEvents.INTS]
	while cursor < count:
		var i := cursor * GSFpsTickEvents.INTS
		if ints[i] != e:
			break
		var f := floats[cursor * GSFpsTickEvents.FLOATS]
		match ints[i + 1]:
			GSFpsTickEvents.Kind.MODE_CHANGED:
				mode_changed.emit(ints[i + 2], ints[i + 3])  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.LANDED:
				landed.emit(f)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.JUMPED:
				jumped.emit()  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.STEPPED_UP:
				_step_up(f)
			GSFpsTickEvents.Kind.CROUCH_CHANGED:
				crouch_changed.emit(ints[i + 2] != 0)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.SLIDE_CHANGED:
				slide_changed.emit(ints[i + 2] != 0)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.LAUNCHED:
				launched.emit()  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.DASHED:
				dashed.emit()  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.WALL_JUMPED:
				wall_jumped.emit()  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.WALL_RUN_CHANGED:
				wall_run_changed.emit(ints[i + 2] != 0)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
			GSFpsTickEvents.Kind.VIEW_TURNED:
				_view_turn(f)
		cursor += 1
	return cursor


## Everything input row [param row] holds for this controller, from [param cursor] (its first derived event, or past
## them when it has none): the motor's edges as [method dispatch_events], then the surface change, the modifiers added
## and removed and [signal simulated]. Answers the cursor past its events. The game walks every row in order after
## [method GSFpsTickEvents.derive] (one row a controller a table); the tick's other signals are the same as one by one.
func dispatch_row(events: GSFpsTickEvents, row: int, cursor: int) -> int:
	if cursor < events.count and events.ints[cursor * GSFpsTickEvents.INTS] == events.entity_at(row):
		cursor = dispatch_events(events, cursor)
	var side := events.side[row]
	if side & GSFpsTickEvents.SIDE_SURFACE != 0:
		surface_changed.emit(_ev_surface_from, _ev_surface_to)
	if side & GSFpsTickEvents.SIDE_MODIFIERS != 0:
		for id in _ev_added:
			modifier_added.emit(id)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
		for id in _ev_removed:
			modifier_removed.emit(id)  # perf-lint: allow emit_in_loop the batched dispatch point: one public signal per recorded event, after the tick
	if side & GSFpsTickEvents.SIDE_SIMULATED != 0:
		simulated.emit(_tick, state)
	return cursor


func _step_up(gained: float) -> void:
	if view != null:
		view.note_step_up(gained)
	stepped_up.emit(gained)


func _view_turn(degrees: float) -> void:
	view_turned.emit(degrees)
	if sampler != null:
		sampler.look_at_angles(sampler.yaw + degrees, sampler.pitch)
