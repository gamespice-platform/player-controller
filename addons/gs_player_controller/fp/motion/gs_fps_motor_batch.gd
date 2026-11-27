class_name GSFpsMotorBatch
extends RefCounted

## The columns layout by path, not by its global name, so a run whose class cache predates it still parses.
const _Cols := preload("../core/gs_fps_state_columns.gd")
## Several players' motor ticks in runs of one native call (GameSpice Sim's [code]GSSimMotorBatch[/code]), for a server's players' loop.
## The game first [method add]s every player in roster order (each motor runs the part of its tick no other player can change), then in the same order [method finish]es one, does its own work for that player and goes on. A run is the consecutive rows GameSpice Sim can tick; it is ticked when its first row is finished, each row seeing the earlier ones where they came to rest, as the players' ticks one after another do. A player that ends its tick elsewhere (a teleport, a death) takes the rows after it back ([method moved_after]); they run again. The answers are [method GSFpsMotor.simulate]'s to the bit.

const NATIVE_CLASS := &"GSSimMotorBatch"
const _IN := 55
const _OUT := 45
## Values per row of [code]GSSimMotorBatch.run_slots[/code]'s answer: the 45, then the row's new state columns (API 49).
const _SLOT := _OUT + _Cols.STRIDE
## Values [method post_row] writes per row (API 34).
const POST := 7
## Values per row beside the state's columns where the batch hands GameSpice Sim the columns themselves (API 37).
const COLS_EXTRA := 27

## Whether the rows go to GameSpice Sim as each state's columns ([code]GSSimMotorBatch.run_cols[/code]: no per-field copy in or
## out of a 55-value row) when the library has it; off fills the rows field by field as before. Same bits either way
## (examples/motor_batch_parity.gd). On by default; a game's operator switch may turn it off. Read at [method start].
static var native_cols: bool = true
## Whether, on [member native_cols], GameSpice Sim also keeps each motor's rest stamp and decides its reuse, and keeps
## each player's state columns in a row of its own across ticks ([code]GSSimMotorBatch.run_slots[/code], API 49): a
## state's columns are sent again only when a script write marked them ([member GSFpsState.batch_dirty]), and no
## columns are copied in or out per tick but the answer. Same bits either way (examples/motor_batch_parity.gd). On by
## default. Read at [method start].
static var native_state: bool = true
## Whether, on [member native_state], GameSpice Sim also says what each tick changed (mode, height, slide, wall run;
## [member GSFpsMotor.batch_events], API 47), so the controller's tick end compares only those. Same signals either way
## (examples/motor_batch_parity.gd). On by default; the operator switch for it.
static var native_events: bool = true
## Whether, on [member native_state], GameSpice Sim also runs each row's crouch at the row's turn
## ([member GSFpsMotor.batch_crouch], API 48) instead of the script at [method add]. Same bits either way
## (examples/motor_batch_parity.gd). On by default; the operator switch for it.
static var native_crouch: bool = true

## Rows ticked natively, native calls, rows taken back and rows found stale, since the game last cleared them.
var rows: int = 0
var runs: int = 0
var retakes: int = 0
var stale: int = 0
## Of [member runs], the ones that handed GameSpice Sim the states' columns ([member native_cols]).
var cols_runs: int = 0
## Of [member cols_runs], the ones GameSpice Sim kept the rest stamps and the columns in ([member native_state]).
var state_runs: int = 0
## On [member native_state]: the states whose columns were sent to their resident row (made, marked dirty or moved).
var pushes: int = 0
## Of [member pushes], the ones a write that did not mark [member GSFpsState.batch_dirty] made (an error is printed).
var unmarked: int = 0

var _native: Object = null
## Meta values per row: 4 where GameSpice Sim runs the rows' clocks too ([code]run_rows[/code]), else 3.
var _meta_len: int = 3
## Whether the library has [code]run_cols[/code], and whether this loop uses it.
var _cols_ok := false
var _use_cols := false
## Whether the library has [code]run_slots[/code], and whether this loop uses it.
var _states_ok := false
var _crouch_ok := false
var _use_states := false
var _delta: float = 0.0
var _count: int = 0
var _motors: Array[GSFpsMotor] = []
var _states: Array[GSFpsState] = []
var _commands: Array[GSFpsCommand] = []
var _bodies: Array = []  # perf-lint: allow untyped_array handed to GSSimMotorBatch as is: the native run takes plain Arrays
var _tuns: Array = []  # perf-lint: allow untyped_array handed to GSSimMotorBatch as is: the native run takes plain Arrays
var _stage := PackedByteArray()
## Each row's tick length ([method add]'s delta, else [method start]'s).
var _deltas := PackedFloat64Array()
var _meta := PackedInt64Array()
var _in := PackedFloat64Array()
## On [member _use_cols]: the [constant COLS_EXTRA] values beside each row's columns and a whole row for
## [method GSFpsMotor.batch_refill]; without [member _use_states] also each row's state columns and the ones answered.
var _extra := PackedFloat64Array()
var _cols: Array = []  # perf-lint: allow untyped_array handed to GSSimMotorBatch as is: the native run takes plain Arrays
var _cols_new: Array = []  # perf-lint: allow untyped_array handed to GSSimMotorBatch as is: the native run takes plain Arrays
## On [member _use_states]: each row's resident row in GameSpice Sim ([member GSFpsMotor.batch_slot]).
var _slots := PackedInt64Array()
## Values per row in [member _out]: [constant _SLOT] on [member _use_states], else [constant _OUT].
var _stride: int = _OUT
var _row := PackedFloat64Array()
var _sent_position := PackedVector3Array()
var _sent_velocity := PackedVector3Array()
var _out := PackedFloat64Array()
## [member _out] holds rows [member _out_from] up to [member _out_to].
var _out_from: int = 0
var _out_to: int = 0
## The row [method finish] last ended with the batch's answer, at [member _applied_at] in [member _out]; -1 when none.
var _applied_row: int = -1
var _applied_at: int = 0


## Whether the loaded GameSpice Sim has the batch.
static func available() -> bool:
	return ClassDB.class_exists(NATIVE_CLASS)


## Runs the rows on [param native], a [code]GSSimMotorBatch[/code] someone else holds (a game's native server tick,
## [code]GSSimServerTick.motor[/code], reads the resident rows straight after the loop), instead of one of its own; null
## goes back to its own at the next [method start]. Every motor's resident row is made again in the new batch at its
## next tick (same bits); call it between loops, never inside one. False, and nothing changed, when [param native] is not a [code]GSSimMotorBatch[/code] (API 51).
func use_native(native: Object) -> bool:
	if native != null and not native.is_class(NATIVE_CLASS):
		push_error("GSFpsMotorBatch.use_native: %s is not a %s" % [native.get_class(), NATIVE_CLASS])
		return false
	_native = native
	if native != null:
		_take_native()
	return true


## The batch [method start] runs the rows on (made there when none was handed to [method use_native]).
func native() -> Object:
	return _native


## Starts a players' loop of ticks [param delta] long; false when GameSpice Sim has no batch (the game ticks each player itself).
func start(delta: float) -> bool:
	if _native == null:
		if delta <= 0.0 or not ClassDB.class_exists(NATIVE_CLASS):
			return false
		_native = ClassDB.instantiate(NATIVE_CLASS)
		_take_native()
	_use_cols = _cols_ok and native_cols
	_use_states = _use_cols and _states_ok and native_state
	_stride = _SLOT if _use_states else _OUT
	_delta = delta
	_count = 0
	_out_from = 0
	_out_to = 0
	_applied_row = -1
	_native.begin()
	return true


## Adds [param motor]'s tick and runs its start; the row to [method finish]. [param delta] above zero is this row's tick
## length instead of [method start]'s (a body that sat out ticks makes them up in one, API 26).
func add(motor: GSFpsMotor, state: GSFpsState, command: GSFpsCommand, delta: float = -1.0) -> int:
	var row := _count
	_count += 1
	if _stage.size() < _count:
		_motors.resize(_count)
		_states.resize(_count)
		_commands.resize(_count)
		_bodies.resize(_count)
		_tuns.resize(_count)
		_stage.resize(_count)
		_deltas.resize(_count)
		_meta.resize(_count * _meta_len)
		_in.resize(_count * _IN)
		_cols.resize(_count)
		_cols_new.resize(_count)
		_slots.resize(_count)
		_extra.resize(_count * COLS_EXTRA)
		_sent_position.resize(_count)
		_sent_velocity.resize(_count)
	_motors[row] = motor
	_states[row] = state
	_commands[row] = command
	_deltas[row] = delta if delta > 0.0 else _delta
	var stage: int
	motor.batch_states = _use_states and motor.batch_motor_state() != null
	motor.batch_crouch = motor.batch_states and _crouch_ok and native_crouch
	if _use_cols:
		stage = motor.batch_prepare(state, command, _deltas[row], _extra, _meta, row, _meta_len, COLS_EXTRA)
	else:
		stage = motor.batch_prepare(state, command, _deltas[row], _in, _meta, row, _meta_len)
	_stage[row] = stage
	if stage == GSFpsMotor.BATCH_READY:
		if motor.batch_states:
			_slots[row] = _slot_for(motor, state)
		elif _use_states:
			_slots[row] = -1
		elif _use_cols:
			_cols[row] = state._f
		_bodies[row] = motor.batch_body
		_tuns[row] = motor.batch_tun
		_sent_position[row] = state.position
		_sent_velocity[row] = state.velocity
	return row


## Ends row [param row]'s motor tick. True when GameSpice Sim's hull world already holds where the player came to rest; on false
## the game tells it ([method moved_after] is not needed then: no later row has run).
func finish(row: int) -> bool:
	var stage := _stage[row]
	_applied_row = -1
	if stage == GSFpsMotor.BATCH_DONE:
		return false
	var motor := _motors[row]
	var state := _states[row]
	if stage == GSFpsMotor.BATCH_READY:
		if state.position != _sent_position[row] or state.velocity != _sent_velocity[row]:
			# Something moved the player between add and its turn: the row and the ones after it are redone from here.
			stale += 1
			_take_back(row)
			if _use_cols:
				_refill_cols(motor, state, row)
			else:
				motor.batch_refill(state, _commands[row], _deltas[row], _in, row)
			if _meta_len > 3:
				_meta[row * _meta_len + 3] = motor.batch_clocks
		if row >= _out_to or row < _out_from:
			_run(row)
		if row < _out_to:
			_applied_row = row
			_applied_at = (row - _out_from) * _stride
			if _use_states:
				# The resident row holds the answered columns now; a write after this marks the state again.
				state.batch_dirty = false
				var at := _applied_at
				motor.batch_apply_cols(state, _commands[row], _out.slice(at + _OUT, at + _SLOT), _out, at)
				motor.batch_slot_position = state.position
				motor.batch_slot_velocity = state.velocity
			else:
				if _use_cols:
					motor.batch_apply_cols(state, _commands[row], _cols_new[row], _out, _applied_at)
				else:
					motor.batch_apply(state, _commands[row], _out, _applied_at)
				# Not through the setters, and no resident row took it: one kept from native_state on is stale now.
				state.batch_dirty = true
			return _meta[row * _meta_len] == 3
	motor.batch_resume(state, _commands[row], _deltas[row])
	return false


## Writes row [param row]'s state after its motor into [param into] at [param at], [constant POST] values: velocity x and z,
## mode, crouch fraction, slide time, wall-run time, sprinting (1 or 0); GameSpice Sim's [code]GSSimPlayerPost[/code]
## input columns. Call it after [method finish] of that row, before the next row's. True when they came from the batch's answer
## (the velocity unrounded: as a float32 it is the state's), false when read from the state (a row the script ended).
func post_row(row: int, into: PackedFloat64Array, at: int) -> bool:
	var state := _states[row]
	into[at + 3] = state.crouch_fraction
	into[at + 6] = 1.0 if state.sprinting else 0.0
	if row == _applied_row:
		var o := _applied_at
		into[at] = _out[o + 3]
		into[at + 1] = _out[o + 5]
		into[at + 2] = _out[o + 9]
		into[at + 4] = _out[o + 26]
		into[at + 5] = _out[o + 31]
		return true
	var v := state.velocity
	into[at] = v.x
	into[at + 1] = v.z
	into[at + 2] = state.mode
	into[at + 4] = state.slide_time
	into[at + 5] = state.wall_run_time
	return false


## The player of row [param row] will not tick after all (it died since [method add]). The start of its tick stays run:
## the tick is counted and the stance moved, which the loop one player after another would not have done.
func skip(row: int) -> void:
	if _stage[row] == GSFpsMotor.BATCH_DONE:
		return
	_take_back(row)
	_stage[row] = GSFpsMotor.BATCH_DONE
	_motors[row].batch_cancel(_states[row], _commands[row], _deltas[row])


## The player of row [param row] ended its tick somewhere else than its motor left it, or died: the rows after it run again.
## The game tells the hull world where the player is now.
func moved_after(row: int) -> void:
	_take_back(row + 1)


## Drops what the loop holds (the motors and states of the last tick). The players' resident rows stay: each motor gives
## its back when freed ([method GSFpsMotor.batch_slot_release]).
func clear() -> void:
	_count = 0
	_motors.clear()
	_states.clear()
	_commands.clear()
	_bodies.clear()
	_tuns.clear()
	_stage.clear()
	_deltas.clear()
	_cols.clear()
	_cols_new.clear()
	_slots.clear()


func _take_native() -> void:
	_meta_len = 4 if ClassDB.class_has_method(NATIVE_CLASS, &"run_rows") else 3
	_cols_ok = _meta_len > 3 and ClassDB.class_has_method(NATIVE_CLASS, &"run_cols")
	_states_ok = _cols_ok and ClassDB.class_has_method(NATIVE_CLASS, &"run_slots")
	_crouch_ok = _states_ok and ClassDB.class_has_method(NATIVE_CLASS, &"crouch_rows")


func _take_back(row: int) -> void:
	if row >= _out_to or _out_to <= _out_from:
		return
	retakes += 1
	_native.rollback(row)
	_out_to = maxi(row, _out_from)


## [method GSFpsMotor.batch_refill] for a row of columns: the whole row rebuilt as [method add] filled it, refilled from the
## state, and its columns taken again (on [member _use_states] sent to its resident row before the run).
func _refill_cols(motor: GSFpsMotor, state: GSFpsState, row: int) -> void:
	# The refill reads the state, so a crouch left to the batch is run first.
	motor.batch_crouch_now(state, _commands[row], _deltas[row])
	if _row.size() != _IN:
		_row.resize(_IN)
	var c: PackedFloat64Array = state._f if _use_states else _cols[row]
	var e := row * COLS_EXTRA
	for i in 12:
		_row[i] = c[i]
	for i in COLS_EXTRA:
		_row[12 + i] = _extra[e + i]
	for i in _Cols.CLOCK_COUNT:
		_row[39 + i] = c[_Cols.CLOCKS + i]
	motor.batch_refill(state, _commands[row], _deltas[row], _row, 0)
	for i in COLS_EXTRA:
		_extra[e + i] = _row[12 + i]
	if motor.batch_states:
		_extra[e + 1] = motor.batch_rest_bits(state)
	if _use_states:
		state.batch_dirty = true
	else:
		_cols[row] = state._f


## [param motor]'s resident row in this loop's GameSpice Sim batch, made (or made again for another body or state) when
## it has none, its tunables resent when they changed. A state whose columns moved without a write that marks it is an
## error: it is printed and the columns sent anyway.
func _slot_for(motor: GSFpsMotor, state: GSFpsState) -> int:
	var tun := motor.tunables
	if (
		motor.batch_slot < 0 or motor.batch_slot_owner != _native or motor.batch_slot_body != motor.batch_body
		or motor.batch_slot_state != state
	):
		motor.batch_slot_release()
		motor.batch_slot = _native.slot_add(motor.batch_body, motor.batch_motor_state(), motor.batch_tun)
		motor.batch_slot_owner = _native
		motor.batch_slot_body = motor.batch_body
		motor.batch_slot_state = state
		state.batch_dirty = true
	elif motor.batch_slot_tun_for != tun or motor.batch_slot_tun_rev != tun.revision:
		_native.slot_tun(motor.batch_slot, motor.batch_tun)
	elif not state.batch_dirty and (
		state.position != motor.batch_slot_position or state.velocity != motor.batch_slot_velocity
	):
		unmarked += 1
		push_error("GSFpsMotorBatch: a state's columns changed without GSFpsState.batch_dirty; sent again")
		state.batch_dirty = true
	motor.batch_slot_tun_for = tun
	motor.batch_slot_tun_rev = tun.revision
	return motor.batch_slot


func _run(row: int) -> void:
	var to := row
	while to < _count and _stage[to] == GSFpsMotor.BATCH_READY:
		to += 1
		# A body outside the hull world does not tell it where it came to rest: the game does, before the next row.
		if _meta[(to - 1) * _meta_len] != 3:
			break
	if _use_states:
		for r in range(row, to):
			var state := _states[r]
			if state.batch_dirty and _slots[r] >= 0:
				_native.slot_push(_slots[r], state._f)
				state.batch_dirty = false
				pushes += 1
		_out = _native.run_slots(_slots, _meta, _extra, row, to)
		cols_runs += 1
		state_runs += 1
	elif _use_cols:
		_out = _native.run_cols(_bodies, _tuns, _meta, _cols, _extra, _cols_new, row, to)
		cols_runs += 1
	elif _meta_len > 3:
		_out = _native.run_rows(_bodies, _tuns, _meta, _in, row, to)
	else:
		_out = _native.run(_bodies, _tuns, _meta, _in, row, to)
	_out_from = row
	_out_to = row + _out.size() / _stride
	rows += _out_to - row
	runs += 1
