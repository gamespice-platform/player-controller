extends "gs_fps_motor_slide.gd"

## The columns layout by path, not by its global name, so a run whose class cache predates it still parses.
const _Cols := preload("../core/gs_fps_state_columns.gd")

## The motor's native side: the tunables and input rows it hands GameSpice Sim, the answers it writes back, and the rest
## stamp that lets a settled walker skip its ground probe. Split out of [GSFpsMotor] for file size; it is the layer
## between that and gs_fps_motor_slide.gd, and nothing outside the motor names this script.


## [member native_tick]'s tunables for this tick, or empty when this tick may not run natively.
func _native_tick_tun(state: GSFpsState) -> PackedFloat64Array:
	if (
		not native_tick or surfaces != null or tunables.edge_friction > 1.0
		or (state.mode != GSFpsState.Mode.GROUND and state.mode != GSFpsState.Mode.AIR)
	):
		return PackedFloat64Array()
	if tunables != _tun_for or tunables.revision != _tun_rev:
		_tun_cache = _build_tick_tun()
		_tun_full_cache = PackedFloat64Array()
		_tun_for = tunables
		_tun_rev = tunables.revision
	return _tun_cache


## [method _native_tick_tun]'s array and [method _native_full_tun]'s, kept until [member tunables] or one of its values
## changes ([member GSFpsTunables.revision]): rebuilding them was a per-tick copy of about 75 values per player.
var _tun_cache := PackedFloat64Array()
var _tun_full_cache := PackedFloat64Array()
var _tun_for: GSFpsTunables = null
var _tun_rev := -1


func _build_tick_tun() -> PackedFloat64Array:
	return PackedFloat64Array([
		tunables.max_slide_iterations, 1.0 if tunables.crease_slide else 0.0, tunables.skin_width,
		tunables.max_slide_planes, tunables.step_height, tunables.radius, tunables.max_slope_radians(),
		tunables.jump_velocity(), 1.0 if tunables.ground_snap else 0.0, tunables.ground_snap_distance,
		tunables.crest_launch_speed_scale, tunables.max_speed, tunables.stop_speed, tunables.air_friction,
		tunables.max_velocity, tunables.backward_speed_scale, tunables.max_air_wish_speed,
		tunables.wall_slide_speed, tunables.wall_run_vertical_damping,
	])


## The start ground check's answer from [method _native_tick_pre].
var _native_start_settled := false


## [method _depenetrate], [method _reuse_rest] and [method _categorise_ground_settled] in one native call; false (nothing
## written) when the body cannot. The script decides everything [method _reuse_rest] compares but the position, which the
## native depenetration may move.
func _native_tick_pre(state: GSFpsState, tun: PackedFloat64Array) -> bool:
	var height := _height(state)
	var rest_ok := _native_rest_ok(state, height)
	var p := state.position
	var v := state.velocity
	var n := state.ground_normal
	var id := state.ground_id
	var r := body.native_tick(0, PackedFloat64Array([
		p.x, p.y, p.z, v.x, v.y, v.z, n.x, n.y, n.z, state.mode, id & 0xFFFFFFFF, id >> 32, height,
		1.0 if rest_ok else 0.0, _rest_position.x, _rest_position.y, _rest_position.z,
	]), tun)
	if r.size() < 23:
		return false
	_rest_valid = false
	var flags := _native_tick_apply(state, r)
	# As in [method simulate]: a reused start proves nothing about the end of the tick.
	_native_start_settled = flags & 1 != 0 and flags & 2 == 0
	if flags & 2 != 0:
		reused_ground_ticks += 1
	return true


## Whether [method _reuse_rest] may reuse the last rest, for the native start: all it compares but the position.
func _native_rest_ok(state: GSFpsState, height: float) -> bool:
	if _rest_valid and not _rest_in_script:
		_rest_pull()
	return (
		_rest_valid and state.mode == GSFpsState.Mode.GROUND
		and state.velocity == _rest_velocity
		and state.ground_normal == _rest_normal and state.ground_id == _rest_ground_id
		and state.surface == _rest_surface and height == _rest_height
		and _rest_ground_unmoved()
	)


## The move tunables [method _native_tick_full] sends after the tick ones.
func _native_full_tun(tun: PackedFloat64Array) -> PackedFloat64Array:
	if not _tun_full_cache.is_empty():
		return _tun_full_cache
	var t := tunables
	var full := tun.duplicate()
	full.append_array(PackedFloat64Array([
		t.can_jump, t.auto_hop, t.jump_buffer_time, t.jump_cooldown, t.coyote_time, t.bhop_speed_cap_scale,
		t.jump_adds_to_velocity,
		t.launch_enabled, t.launch_button, t.launch_from_air, t.launch_velocity, t.launch_forward, t.launch_cooldown,
		t.dash_enabled, t.dash_button, t.dash_from_air, t.dash_speed, t.dash_cooldown, t.dash_lift,
		t.slide_enabled, t.slide_duration, t.slide_end_speed, t.can_crouch, t.slide_requires_sprint,
		t.slide_min_speed, t.slide_boost, t.slide_max_speed, t.slide_cooldown,
		t.friction, t.slide_friction, t.accelerate, t.slide_accelerate,
		t.wall_run_enabled, t.wall_jump_enabled, t.wall_run_auto, t.wall_run_on_jump, t.wall_run_jump_min_speed,
		t.wall_run_min_speed, t.wall_max_angle_from_vertical, t.wall_reach, t.wall_run_max_time,
		t.wall_run_end_speed, t.wall_run_requires_forward, t.wall_run_max_fall_speed,
		t.wall_run_max_approach_angle, t.wall_run_min_height, t.wall_run_min_length, t.wall_run_cooldown,
		t.wall_run_jump_max_angle, t.wall_run_turn_view, t.wall_run_turn_view_max_angle,
		t.wall_jump_max_per_wall, t.wall_jump_max_per_air, t.wall_jump_look_blend, t.wall_jump_push_speed,
		t.wall_jump_up_speed,
	]))
	_tun_full_cache = full
	return full


## [method _native_tick_full]'s input, kept and refilled each tick.
var _full_in := PackedFloat64Array()


## The whole tick from the start ground check to the end one in one native call: the halves and every move between;
## false (nothing written) when the body cannot.
func _native_tick_full(state: GSFpsState, command: GSFpsCommand, delta: float, tun: PackedFloat64Array) -> bool:
	var a := _full_in
	if a.size() != 55:
		a.resize(55)
	_fill_full_in(state, command, delta, a, 0)
	var r := body.native_tick(2, a, _native_full_tun(tun))
	if r.size() < 45:
		return false
	_native_full_apply(state, r)
	return true


## The whole tick's input, 55 values from [param o] in [param a] (set by index: a literal built a Variant Array of every value, each tick).
func _fill_full_in(state: GSFpsState, command: GSFpsCommand, delta: float, a: PackedFloat64Array, o: int) -> void:
	# Position, velocity, ground normal, mode and the ground id's halves: the state's first 12 columns, in this order.
	var f := state._f
	for i in 12:
		a[o + i] = f[i]
	_fill_full_extra(state, command, delta, a, o)
	# The clocks, wall counters and wall normal: the state's clock block, in this order.
	for i in _Cols.CLOCK_COUNT:
		a[o + 39 + i] = f[_Cols.CLOCKS + i]


## The values of [method _fill_full_in]'s row that are not the state's columns, 12..38 of the row starting at [param o]:
## all a row of [code]GSSimMotorBatch.run_cols[/code] needs beside the columns (there [param o] is 12 before the row's).
## With [param bits] the row is one of [code]GSSimMotorBatch.run_states[/code]: 13 holds [method batch_rest_bits], and the
## rest position is the native stamp's.
func _fill_full_extra(
	state: GSFpsState, command: GSFpsCommand, delta: float, a: PackedFloat64Array, o: int, bits: bool = false
) -> void:
	var height := _height(state)
	var push := _surface.push
	var buttons := command.buttons if state.sprinting else command.buttons & ~GSFpsCommand.BUTTON_SPRINT
	var t := tunables
	if t != _fill_for or t.revision != _fill_rev:
		_fill_for = t
		_fill_rev = t.revision
		_fill_clean.clear()
		_fill_buttons = -1
	if buttons != _fill_buttons or load_fraction != _fill_load:
		_fill_speed = t.speed_for(buttons, load_fraction)
		_fill_buttons = buttons
		_fill_load = load_fraction
	a[o + 12] = height
	if bits:
		a[o + 13] = batch_rest_bits(state)
	else:
		a[o + 13] = 1.0 if _native_rest_ok(state, height) else 0.0
		a[o + 14] = _rest_position.x
		a[o + 15] = _rest_position.y
		a[o + 16] = _rest_position.z
	a[o + 17] = delta
	a[o + 18] = command.buttons
	a[o + 19] = state.previous_buttons
	a[o + 20] = command.move.x
	a[o + 21] = command.move.y
	a[o + 22] = state.yaw
	var c := _fill_clean if _effects_clean else _fill_values()
	if c.is_empty():
		_fill_clean = _fill_values()
		c = _fill_clean
	if bits and _consts_native and _consts_kept(c):
		a[o + 13] = int(a[o + 13]) | 4
		return
	a[o + 23] = c[0]
	a[o + 24] = c[1]
	a[o + 25] = c[2] * _surface.jump_scale * c[1]
	a[o + 26] = _fill_speed
	a[o + 27] = c[3]
	a[o + 28] = _surface.max_speed_scale
	a[o + 29] = _surface.friction_scale
	a[o + 30] = c[4]
	a[o + 31] = _surface.accelerate_scale
	a[o + 32] = c[5]
	a[o + 33] = c[6]
	a[o + 34] = push.x
	a[o + 35] = push.y
	a[o + 36] = push.z
	a[o + 37] = c[7]
	a[o + 38] = c[8]
	if bits and _consts_native:
		_consts_keep(c, a.slice(o + 23, o + 39))


## [method _fill_full_in]'s values only the tunables and the effects decide: the effect flags, jump scale, jump velocity,
## max speed, friction and accelerate scales, air accelerate, gravity and wall-run gravity.
func _fill_values() -> PackedFloat64Array:
	var t := tunables
	var e := _effects
	return PackedFloat64Array([
		(1 if e.deny_move else 0) | (2 if e.deny_jump else 0) | (4 if e.deny_crouch else 0), e.jump, t.jump_velocity(),
		e.max_speed, e.friction, e.accelerate, t.air_accelerate * e.air_accelerate, t.gravity * e.gravity,
		t.gravity * t.wall_run_gravity_scale * e.gravity,
	])


## [method _fill_values] kept while the effects are clean (all ones, [member _effects_clean]) and [member tunables] and
## its [member GSFpsTunables.revision] stay, and the last [method GSFpsTunables.speed_for] with its buttons and load:
## about a dozen reads and two calls a player a tick.
var _fill_clean := PackedFloat64Array()
var _fill_for: GSFpsTunables = null
var _fill_rev := -1
var _fill_buttons := -1
var _fill_load := NAN
var _fill_speed := 0.0
## Whether this motor's native state keeps a [code]run_states[/code] row's values 23..38 ([code]set_consts[/code], API 40):
## the row then says so with bit 4 of value 13 and the script writes them only when what decides them changed.
var _consts_native := false
## What the kept values were made from: the effect and tunable values, the speed and the surface's values.
var _consts_c := PackedFloat64Array()
var _consts_speed := NAN
var _consts_surface: GSFpsSurface = null
var _consts_scales := PackedFloat64Array([NAN, NAN, NAN, NAN])
var _consts_push := Vector3(NAN, NAN, NAN)


## Whether the native state's kept values are the ones [method _fill_full_extra] would write now.
func _consts_kept(c: PackedFloat64Array) -> bool:
	var s := _surface
	return (
		s == _consts_surface and _fill_speed == _consts_speed and c == _consts_c and s.push == _consts_push
		and s.jump_scale == _consts_scales[0] and s.max_speed_scale == _consts_scales[1]
		and s.friction_scale == _consts_scales[2] and s.accelerate_scale == _consts_scales[3]
	)


## Hands the native state the values just written and remembers what they were made from.
func _consts_keep(c: PackedFloat64Array, vals: PackedFloat64Array) -> void:
	var s := _surface
	_consts_c = c.duplicate()
	_consts_speed = _fill_speed
	_consts_surface = s
	_consts_push = s.push
	_consts_scales = PackedFloat64Array([s.jump_scale, s.max_speed_scale, s.friction_scale, s.accelerate_scale])
	_mstate.set_consts(vals)


## Writes a whole native tick's 45 values into the state and the counters.
func _native_full_apply(state: GSFpsState, r: PackedFloat64Array, o: int = 0) -> void:
	_rest_valid = false
	_native_full_settle(state, _native_tick_apply(state, r, o))
	# The clocks and wall counters (float64 scalars, the flag and counts whole numbers) go into the clock block as they
	# are; the wall normal through its property, which rounds it to the float32 a Vector3 holds.
	var f := state._f
	for i in 13:
		f[_Cols.CLOCKS + i] = r[o + 23 + i]
	state.wall_normal = Vector3(r[o + 36], r[o + 37], r[o + 38])
	_native_full_counters(r, o)


## [method _native_full_apply]'s work on the answer's flags once the state holds the tick's end.
func _native_full_settle(state: GSFpsState, flags: int) -> void:
	if flags & 2 != 0:
		reused_ground_ticks += 1
	if flags & 16 != 0:
		GSLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
	if flags & 8 != 0:
		settled_ground_ticks += 1
		_stamp_rest(state)


## The whole tick's view turn and move counters, values 39..44 of the answer at [param o].
func _native_full_counters(r: PackedFloat64Array, o: int) -> void:
	view_turn = r[o + 39]
	slides += int(r[o + 40])
	launches += int(r[o + 41])
	dashes += int(r[o + 42])
	wall_runs += int(r[o + 43])
	wall_jumps += int(r[o + 44])


## From friction to the end ground check in one native call; false (nothing written) when the body cannot.
func _native_tick_post(
	state: GSFpsState, command: GSFpsCommand, delta: float, tun: PackedFloat64Array, jumped: bool,
	wall: GSFpsBody.Hit, start_settled: bool, start_position: Vector3, start_velocity: Vector3
) -> bool:
	if state.mode != GSFpsState.Mode.GROUND and state.mode != GSFpsState.Mode.AIR:
		return false
	var sliding := state.is_sliding()
	var buttons := command.buttons if state.sprinting else command.buttons & ~GSFpsCommand.BUTTON_SPRINT
	var flags := (
		(1 if jumped else 0) | (2 if sliding else 0) | (4 if _effects.deny_move else 0)
		| (8 if _wall_slide_ok(state, command, wall) else 0) | (16 if start_settled else 0)
	)
	var p := state.position
	var v := state.velocity
	var n := state.ground_normal
	var id := state.ground_id
	var push := _surface.push
	var r := body.native_tick(1, PackedFloat64Array([
		p.x, p.y, p.z, v.x, v.y, v.z, n.x, n.y, n.z, state.mode, id & 0xFFFFFFFF, id >> 32, _height(state),
		delta, flags, command.move.x, command.move.y, state.yaw,
		tunables.speed_for(buttons, load_fraction), _effects.max_speed, _surface.max_speed_scale,
		tunables.slide_friction if sliding else tunables.friction, _surface.friction_scale, _effects.friction,
		(tunables.slide_accelerate if sliding else tunables.accelerate) * _surface.accelerate_scale * _effects.accelerate,
		tunables.air_accelerate * _effects.air_accelerate,
		push.x, push.y, push.z, tunables.gravity * _effects.gravity,
		start_position.x, start_position.y, start_position.z, start_velocity.x, start_velocity.y, start_velocity.z,
	]), tun)
	if r.size() < 23:
		return false
	var out := _native_tick_apply(state, r)
	if out & 16 != 0:
		GSLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
	if out & 8 != 0:
		settled_ground_ticks += 1
		_stamp_rest(state)
	else:
		_rest_valid = false
	return true


## Writes a native tick half's answer to [param state] and the counters; returns its flags.
func _native_tick_apply(state: GSFpsState, r: PackedFloat64Array, o: int = 0) -> int:
	state.position = Vector3(r[o], r[o + 1], r[o + 2])
	state.velocity = Vector3(r[o + 3], r[o + 4], r[o + 5])
	state.ground_normal = Vector3(r[o + 6], r[o + 7], r[o + 8])
	state.mode = int(r[o + 9])
	state.ground_id = int(r[o + 10]) | (int(r[o + 11]) << 32)
	return _native_tick_flags(state, r, o)


## The answer's flags at [param o] + 12 and the collision counters after them; the flags clear the surface.
func _native_tick_flags(state: GSFpsState, r: PackedFloat64Array, o: int) -> int:
	var flags := int(r[o + 12])
	if flags & 4 != 0:
		state.surface = &""
	depenetrated_ticks += int(r[o + 13])
	embedded_ticks += int(r[o + 14])
	lifted_ticks += int(r[o + 15])
	stuck_ticks += int(r[o + 16])
	duplicate_plane_ticks += int(r[o + 17])
	crease_leg_ticks += int(r[o + 18])
	split_leg_ticks += int(r[o + 19])
	return flags


## The whole tick for a walker standing still on the floor the last tick proved, or false (nothing written) when anything differs.
## Same answers as the full path, which for such a tick changes nothing: wish, velocity and buttons are zero, so only the world can differ, and two queries ask it (embedded? floor still there?).
func _idle_tick(state: GSFpsState, command: GSFpsCommand) -> bool:
	if _rest_valid and not _rest_in_script:
		_rest_pull()
	if (
		not _rest_valid or command.move != Vector2.ZERO or command.buttons != 0
		or state.previous_buttons != 0 or state.mode != GSFpsState.Mode.GROUND
		or state.velocity != Vector3.ZERO or state.is_sliding() or state.is_wall_running()
		or state.position != _rest_position or state.velocity != _rest_velocity
		or state.ground_normal != _rest_normal or state.ground_id != _rest_ground_id
		or state.surface != _rest_surface or _height(state) != _rest_height
		or not state.modifiers.is_empty() or _surface.push != Vector3.ZERO
		or tunables.wall_run_enabled or tunables.wall_jump_enabled
		or not _rest_ground_unmoved()
	):
		return false

	_idle_streak += 1
	if idle_full_every > 0 and _idle_streak >= idle_full_every:
		_idle_streak = 0
		_rest_valid = false
		return false

	var height := _rest_height
	var centre := _capsule_centre(state.position, height)
	var resting := body.rest_contact(centre, height, tunables.radius)
	if resting.hit and resting.depth > 0.0:
		return false

	var probe := Vector3.DOWN * (tunables.skin_width * 2.0 + 0.02)
	var hit := _ground_probe(centre, probe, height)
	if (
		not hit.hit or hit.collider_id != _rest_ground_id or hit.normal != _rest_normal
		or probe.length() * hit.fraction < tunables.skin_width * 0.5
	):
		_idle_streak = 0
		_rest_valid = false
		return false

	_resolve_surface(state)
	idle_ticks += 1
	settled_ground_ticks += 1
	return true


## Remembers the state a settled ground check just proved, for [method _reuse_rest].
func _stamp_rest(state: GSFpsState) -> void:
	_rest_native = false
	_rest_in_script = true
	_rest_valid = reuse_settled_ground and state.mode == GSFpsState.Mode.GROUND
	_rest_position = state.position
	_rest_velocity = state.velocity
	_rest_height = _height(state)
	_rest_normal = state.ground_normal
	_rest_ground_id = state.ground_id
	_rest_surface = state.surface
	_rest_ground_node = _ground_node(state.ground_id)
	if _rest_ground_node != null:
		_rest_ground_xform = _rest_ground_node.global_transform


## Horizontal speed a blocked ground walk may keep this tick; 0 when the tick has no ground wish.
var _ground_cap := 0.0

var _rest_ground_node: Node3D = null
var _rest_ground_xform := Transform3D.IDENTITY


## The ground collider as a node, or null when it is not one (a stamp then never compares transforms).
func _ground_node(id: int) -> Node3D:
	return body.collider_node(id) if id != 0 else null


## Whether the state is the one the last tick ended on after a settled ground check, so the start-of-tick check would repeat its queries.
## Only the world can differ between ticks; the stamp is dropped on any other change, so a mover carrying its rider is still probed.
func _reuse_rest(state: GSFpsState) -> bool:
	if not _rest_valid:
		return false
	if not _rest_in_script:
		_rest_pull()
	_rest_valid = false
	if (
		state.mode == GSFpsState.Mode.GROUND
		and state.position == _rest_position and state.velocity == _rest_velocity
		and state.ground_normal == _rest_normal and state.ground_id == _rest_ground_id
		and state.surface == _rest_surface and _height(state) == _rest_height
		and _rest_ground_unmoved()
	):
		reused_ground_ticks += 1
		return true
	return false


## False when the ground collider was moved since the stamp (a teleported platform leaves
## from under a rider whose own state does not change), or has been freed or left the tree.
func _rest_ground_unmoved() -> bool:
	if _rest_ground_node == null:
		return true
	if not is_instance_valid(_rest_ground_node) or not _rest_ground_node.is_inside_tree():
		return false
	return _rest_ground_node.global_transform == _rest_ground_xform


## After a [constant BATCH_READY] answer: the native body and tunables of the row.
var batch_body: Object = null
var batch_tun := PackedFloat64Array()
## The clocks and cooldowns of the prepared tick left to GameSpice Sim's row (bit 0), the tick having begun on the ground
## (bit 1): a fourth meta value for [code]GSSimMotorBatch.run_rows[/code]. Every end but [method batch_apply] runs them here.
var batch_clocks: int = 0


## Ends a [constant BATCH_READY] tick with the batch's answer, the 45 values at [param at] in [param out].
func batch_apply(state: GSFpsState, command: GSFpsCommand, out: PackedFloat64Array, at: int) -> void:
	batch_clocks = 0
	body.native_batch_done(int(out[at + 20]), int(out[at + 21]), int(out[at + 22]))
	_native_full_apply(state, out, at)
	state.previous_buttons = command.buttons
	body.end_tick()


## [method batch_apply] for a row of [code]GSSimMotorBatch.run_cols[/code]: [param cols] is the state's columns the batch
## wrote, the answer's position to wall normal and the previous buttons in them as [method batch_apply] writes them; the
## rest of the answer (flags, counters, the view turn) is read from the 45 values at [param at] in [param out].
func batch_apply_cols(
	state: GSFpsState, command: GSFpsCommand, cols: PackedFloat64Array, out: PackedFloat64Array, at: int
) -> void:
	batch_clocks = 0
	body.native_batch_done(int(out[at + 20]), int(out[at + 21]), int(out[at + 22]))
	# The batch took the columns at add; the yaw is the one column the answer does not write, so the state's stays.
	var yaw := state._f[_Cols.YAW]
	state._f = cols
	if cols[_Cols.YAW] != yaw:
		state._f[_Cols.YAW] = yaw
	_rest_valid = false
	if batch_states:
		var flags := int(out[at + 12])
		if flags & EVENTS_KNOWN != 0:
			batch_events = flags
		_states_settle(state, cols, out, at)
	else:
		_native_full_settle(state, _native_tick_flags(state, out, at))
		_native_full_counters(out, at)
	body.end_tick()


## The rest stamp [code]GSSimMotorBatch.run_states[/code] keeps natively (GameSpice Sim's [code]GSSimMotorState[/code], API 38),
## made at the first such row.
var _mstate: Object = null
## Whether the native stamp is the current one, and whether the script's fields are ([method _rest_pull] copies them over).
var _rest_native := false
var _rest_in_script := true
## Set by [GSFpsMotorBatch] before [method batch_prepare]: this row goes to [code]run_states[/code].
var batch_states := false
## Set by the controller at its tick start ([method batch_events_begin], API 42): nothing but the motor
## has written the state since its end-of-tick snapshot, so a [code]run_states[/code] row may ask GameSpice Sim what the
## tick changed (row bit [constant ROW_EVENTS]). [method batch_prepare] adds what it knows: the clocks left to the row,
## the height unchanged by the crouch.
var batch_events_allowed := false
## What the batch said the tick changed, [constant EVENTS_KNOWN] and a bit per change ([constant EVENT_MODE],
## [constant EVENT_Y], [constant EVENT_SLIDE], [constant EVENT_WALL_RUN]); 0 when it was not asked. The controller reads
## it at its tick end and clears it.
var batch_events: int = 0
const ROW_EVENTS := 8
const EVENTS_KNOWN := 64
const EVENT_MODE := 128
const EVENT_Y := 256
const EVENT_SLIDE := 512
const EVENT_WALL_RUN := 1024
## [member batch_events] as the controller's tick end took it ([method batch_events_take]) for [method may_change].
var tick_events: int = 0
## Per controller script: whether it overrides [code]_on_pre_simulate[/code], which may write the state after the snapshot.
static var _pre_own := {}


## The controller's tick start: clears the events and allows them unless its [param script] overrides
## [code]_on_pre_simulate[/code] or [param external] velocity is pending.
func batch_events_begin(script: Script, external: Vector3) -> void:
	batch_events = 0
	tick_events = 0
	if not _pre_own.has(script):
		var own := script.get_script_method_list().filter(func(m): return m["name"] == "_on_pre_simulate")
		_pre_own[script] = own.size() > 1
	batch_events_allowed = not _pre_own[script] and external == Vector3.ZERO


## The controller's tick end: moves [member batch_events] to [member tick_events].
func batch_events_take() -> void:
	tick_events = batch_events
	batch_events = 0


## Whether the tick may have changed what [param bit] stands for ([constant EVENT_MODE] and the others): true unless the
## batch said what the tick changed and it was not that.
func may_change(bit: int) -> bool:
	return tick_events == 0 or tick_events & bit != 0


## This motor's native state for a [code]run_states[/code] row, or null when its rows cannot be ones.
func batch_motor_state() -> Object:
	if _mstate == null:
		if not ClassDB.class_exists(&"GSSimMotorState"):
			return null
		_mstate = ClassDB.instantiate(&"GSSimMotorState")
		_consts_native = _mstate.has_method(&"set_consts")
	return _mstate


## A [code]run_states[/code] row's value 13: the script's part of rest ok (1: the stamp is valid, the surface the stamped
## one, the ground node unmoved; a script stamp is handed to the native state first) and [member reuse_settled_ground] (2).
func batch_rest_bits(state: GSFpsState) -> int:
	var reuse := 2 if reuse_settled_ground else 0
	if not _rest_valid or state.surface != _rest_surface or not _rest_ground_unmoved():
		return reuse
	if not _rest_native:
		var p := _rest_position
		var v := _rest_velocity
		var n := _rest_normal
		var id := _rest_ground_id
		_mstate.set_rest(PackedFloat64Array([
			1.0, p.x, p.y, p.z, v.x, v.y, v.z, n.x, n.y, n.z, id & 0xFFFFFFFF, id >> 32, _rest_height,
		]))
		_rest_native = true
	return reuse | 1


## Copies the native stamp into the script's fields, for the script's own reuse checks.
func _rest_pull() -> void:
	_rest_in_script = true
	var r: PackedFloat64Array = _mstate.rest()
	_rest_position = Vector3(r[1], r[2], r[3])
	_rest_velocity = Vector3(r[4], r[5], r[6])
	_rest_normal = Vector3(r[7], r[8], r[9])
	_rest_ground_id = int(r[10]) | (int(r[11]) << 32)
	_rest_height = r[12]


## [method batch_apply_cols]'s flags for a [code]run_states[/code] row: the counters only when flag 32 says one counted,
## the stamp made natively (flag 8), only its surface kept here.
func _states_settle(state: GSFpsState, cols: PackedFloat64Array, out: PackedFloat64Array, at: int) -> void:
	var flags := int(out[at + 12])
	if flags & 4 != 0:
		state.surface = &""
	if flags & 32 != 0:
		_native_tick_flags(state, out, at)
		_native_full_counters(out, at)
	else:
		view_turn = out[at + 39]
	if flags & 2 != 0:
		reused_ground_ticks += 1
	if flags & 16 != 0:
		GSLog.warn(CHANNEL, "velocity became non-finite; reset to zero")
	if flags & 8 != 0:
		settled_ground_ticks += 1
		_rest_valid = reuse_settled_ground and int(cols[_Cols.MODE]) == GSFpsState.Mode.GROUND
		_rest_native = true
		_rest_in_script = false
		_rest_surface = state.surface
		_rest_ground_node = _ground_node(state.ground_id)
		if _rest_ground_node != null:
			_rest_ground_xform = _rest_ground_node.global_transform
