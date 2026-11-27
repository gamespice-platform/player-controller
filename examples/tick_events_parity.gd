extends "res://examples/fps_controller_selftest_base.gd"

## Holds [GSFpsTickEvents] (a tick's motor edges for every player as one table, derived once) to the signals
## [GSFpsController] emitted one at a time: gs-sim's [code]GSSimTickEvents[/code] against the script derive, to the bit,
## over seeded random rows that reach every kind and both edges of each comparison; then one controller's course
## (walking, jumping, crouching, stepping on and off a metal kerb, a modifier coming and going) run four ways: signals at
## once, rows derived in script, rows derived natively and the batched call, with the same signals in the same order and
## the same states (the held surface, modifier and simulated signals in their own order). With no library the native half
## says so and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/tick_events_parity.tscn[/code]

const ROWS := 6000
const COURSE_TICKS := 720
const ControllerBatch := preload("res://addons/gs_player_controller/fp/nodes/gs_fps_controller_batch.gd")
const EDGES: Array[StringName] = [&"mode_changed", &"landed", &"jumped", &"stepped_up", &"crouch_changed",
	&"slide_changed", &"launched", &"dashed", &"wall_jumped", &"wall_run_changed", &"view_turned"]
## The signals [method GSFpsController.end_tick] holds with a table (API 54) and [method GSFpsController.dispatch_row]
## emits after the row's motor edges: compared in their own order, since one by one the late edges come after them.
const SIDE: Array[StringName] = [&"surface_changed", &"modifier_added", &"modifier_removed", &"simulated"]


func _ready() -> void:
	print("gs-player-controller tick events parity")
	_check(GSFpsState.Mode.GROUND == GSFpsTickEvents.MODE_GROUND and GSFpsState.Mode.AIR == GSFpsTickEvents.MODE_AIR,
		"the table's mode numbers are GSFpsState.Mode's")
	var native := GSFpsTickEvents.available()
	if not native:
		print("  gs-sim's GSSimTickEvents is not loaded (no library, or one before the events module): the native half is skipped")
		if OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1" and not GSFpsPhysicsBody.native_available():
			_check(false, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
	_section("random rows")
	_random_rows(native)
	_done()
	_section("a controller's course")
	var legacy := await _course(0)
	var script := await _course(1)
	_check(legacy["edges"].size() > 20, "the course makes edges (%d)" % legacy["edges"].size())
	for k in [&"mode_changed", &"landed", &"jumped", &"stepped_up", &"crouch_changed", &"surface_changed",
			&"modifier_added", &"modifier_removed", &"simulated"]:
		_check(legacy["seen"].has(k), "the course reaches %s" % k)
	_same(legacy, script, "rows derived in script")
	if native:
		var nat := await _course(2)
		_same(legacy, nat, "rows derived natively")
	# The whole controller tick in one call (API 53) over a motor batch: the same signals and states as one by one.
	if GSFpsMotorBatch.available():
		var batched := await _course(3)
		_same(legacy, batched, "one batched call (GSFpsControllerBatch.tick)")
		_check(batched["motored"] == COURSE_TICKS, "the batched call ran a motor row every tick (%d)" % batched["motored"])
		# On a native server tick (gs-sim GSSimServerTick API 4, gs-player-controller 55) the rows the batch ran are marker
		# rows filled from the motor's resident rows: the same signals and states, with the switch on and off.
		if ClassDB.class_exists(&"GSSimServerTick") and ClassDB.class_has_method(&"GSSimServerTick", &"derive_slots"):
			# With surfaces the motor stays in script (no marker row); without them every row runs natively.
			var deferred := await _course(4)
			_same(legacy, deferred, "the server tick with surfaces (rows run in script)")
			legacy = await _course(0, false)
			var slots := await _course(4, false)
			_same(legacy, slots, "marker rows from the resident rows (GSSimServerTick.derive_slots)")
			_check(slots["slot_rows"] > COURSE_TICKS / 2,
				"most ticks recorded a marker row (%d of %d)" % [slots["slot_rows"], COURSE_TICKS])
			_check(slots["slot_misses"] == 0, "no marker row missed its resident row (%d)" % slots["slot_misses"])
			GSFpsTickEvents.native_slots = false
			var off := await _course(4, false)
			GSFpsTickEvents.native_slots = true
			_same(legacy, off, "the server tick with native_slots off")
			_check(off["slot_rows"] == 0, "native_slots off records no marker row (%d)" % off["slot_rows"])
		else:
			print("  gs-sim's GSSimServerTick has no derive_slots (API 4): the marker rows' course is skipped")
	else:
		print("  gs-sim's motor batch is not loaded: the batched call's course is skipped")
	_check(ControllerBatch.new().tick(GSFpsMotorBatch.new(), 0, null, Callable(), Callable(), Callable()) == 0,
		"the batched call refuses a missing event table")
	_done()
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_completed, _entered])
	get_tree().quit(1 if _failed > 0 or _completed != _entered else 0)


func _random_rows(native: bool) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x5eed
	var events := GSFpsTickEvents.new()
	_check(events.derive_script() == 0, "no rows, no events")
	var steps := PackedFloat64Array([0.0, 0.001, 0.0011, 0.2, 0.35, 0.36, 0.3600001, 0.5, -0.1])
	for r in range(ROWS):
		var sh := 0.35
		var b_y := rng.randf_range(-50.0, 50.0)
		var b_mode := rng.randi_range(0, 2)
		var a_mode := b_mode if rng.randf() < 0.4 else rng.randi_range(0, 2)
		var bl := rng.randi_range(0, 3)
		var bd := rng.randi_range(0, 3)
		var bw := rng.randi_range(0, 3)
		events.record(r / 3, rng.randi_range(0, 1) if rng.randf() < 0.2 else 0, sh,
			b_mode, b_y, rng.randf_range(-30.0, 30.0), rng.randi_range(0, 7), bl, bd, bw,
			a_mode, b_y + steps[rng.randi_range(0, steps.size() - 1)], rng.randf_range(-1.0, 8.0) if rng.randf() < 0.7 else 0.0,
			rng.randi_range(0, 7), bl + int(rng.randf() < 0.1), bd + int(rng.randf() < 0.1), bw + int(rng.randf() < 0.1),
			rng.randf_range(-90.0, 90.0) if rng.randf() < 0.1 else 0.0)
	var n := events.derive_script()
	var seen := PackedInt32Array()
	seen.resize(GSFpsTickEvents.Kind.COUNT)
	var ordered := true
	for i in range(n):
		seen[events.ints[i * 4 + 1]] += 1
		if i > 0 and events.ints[i * 4] < events.ints[i * 4 - 4]:
			ordered = false
	_check(not seen.has(0), "every kind is reached (%s)" % seen)
	_check(ordered, "events come in row order")
	if not native:
		return
	var s_ints := events.ints.slice(0, n * GSFpsTickEvents.INTS)
	var s_floats := events.floats.slice(0, n * GSFpsTickEvents.FLOATS)
	var m := events.derive(true)
	_check(events.native_runs == 1, "the native derive ran")
	_check(m == n, "native and script make as many events (%d, %d)" % [m, n])
	_check(events.ints.slice(0, m * GSFpsTickEvents.INTS) == s_ints, "native and script ints are identical")
	_check(events.floats.slice(0, m * GSFpsTickEvents.FLOATS).to_byte_array() == s_floats.to_byte_array(),
		"native and script floats are identical to the bit")
	events.clear()
	_check(events.derive(true) == 0, "native: no rows, no events")
	# A game's native server tick (gs-sim GSSimServerTick API 2) derives the same table and answers it from events().
	if not ClassDB.class_exists(&"GSSimServerTick") or not ClassDB.class_has_method(&"GSSimServerTick", &"derive"):
		print("  gs-sim's GSSimServerTick has no derive (API 2): the server tick half is skipped")
		return
	var tick: Object = ClassDB.instantiate(&"GSSimServerTick")
	_check(not events.use_native(RefCounted.new()), "use_native refuses an object without the table's methods")
	_check(events.use_native(tick) and events.native_table() == tick, "use_native takes the server tick")
	events.row_count = ROWS
	var t := events.derive(true)
	var wide: PackedInt64Array = tick.call(&"events")
	_check(t == n and events.ints.slice(0, t * GSFpsTickEvents.INTS) == s_ints, "the server tick derives the script's ints (%d, %d)" % [t, n])
	_check(events.floats.slice(0, t * GSFpsTickEvents.FLOATS).to_byte_array() == s_floats.to_byte_array(), "the server tick's floats are the script's to the bit")
	_check(wide.size() == n * GSFpsTickEvents.INTS and PackedInt32Array(Array(wide)) == s_ints, "GSSimServerTick.events() is the tick's ints (%d values)" % wide.size())
	var _back := events.use_native(null)
	_check(events.native_table() == null, "use_native(null) goes back to the table's own")


## [param how]: 0 signals at once, 1 rows derived in script, 2 rows derived natively, 3 the batched call (rows derived
## natively when the library is there), 4 the batched call on a native server tick (GSSimServerTick's motor and derive).
## Without [param surfaced] the kerb has no surface, so the motor may run natively.
func _course(how: int, surfaced: bool = true) -> Dictionary:
	var world := _make_world()
	var kerb := _add_kerb(world)
	var controller := _make_player(world, GSFpsController.Drive.LOCAL)
	await get_tree().physics_frame
	await get_tree().physics_frame
	_rig_course_player(controller, kerb.get_instance_id(), surfaced)
	var edges: Array = []
	var side: Array = []
	var seen := {}
	_listen_course(controller, edges, side, seen)
	var events := GSFpsTickEvents.new()
	var states := PackedByteArray()
	var batch := GSFpsMotorBatch.new()
	var calls := ControllerBatch.new()
	calls.resize(1)
	calls.controllers[0] = controller
	var motored := 0
	var server: Object = null
	if how == 4:
		server = ClassDB.instantiate(&"GSSimServerTick")
		_check(batch.use_native(server.call(&"motor")) and events.use_native(server), "the course runs on a GSSimServerTick")
	var cmd: Array[GSFpsCommand] = [null]
	var pre := func(_row: int) -> float:
		controller.apply_command(cmd[0])
		return STEP
	var live := func(_row: int) -> bool: return true
	var post := func(_row: int, _motor_row: int, _told: bool) -> void: pass
	for t in range(COURSE_TICKS):
		var buttons := _course_buttons(t)
		var forward := 1.0 if (t / 240) % 2 == 0 else -1.0
		if how > 0:
			events.clear()
			controller.event_rows = events
			controller.event_entity = 7
		var before := edges.size()
		var side_before := side.size()
		if t % 150 == 10:
			var _added := controller.add_modifier(&"boost")
		if how >= 3:
			cmd[0] = _command(forward, 0.0, 0.0, buttons)
			var _started := batch.start(STEP)
			motored += calls.tick(batch, t, events, pre, live, post)
		else:
			controller.apply_command(_command(forward, 0.0, 0.0, buttons))
			controller.simulate_tick(t, STEP)
		if how > 0:
			if edges.size() != before or side.size() != side_before:
				_check(false, "no signal is emitted before the dispatch (tick %d)" % t)
			if how >= 3:
				var _derived := calls.dispatch(events)
				if events.row_count != 0:
					_check(false, "the batch's dispatch clears the table (tick %d)" % t)
			else:
				events.derive(how >= 2)
				var end := controller.dispatch_row(events, 0, 0)
				if end != events.count:
					_check(false, "dispatch takes every event of its entity (%d of %d)" % [end, events.count])
		var s := controller.state
		states.append_array(var_to_bytes([s.position, s.velocity, s.mode, s.crouch_fraction]))
	# What the course emitted, taken before the frame that frees the world (a LOCAL player may tick itself in it).
	var course_side := side.duplicate()
	world.queue_free()
	await get_tree().process_frame
	var counted: PackedInt64Array = server.call(&"counters") if server != null else PackedInt64Array([0, 0, 0, 0, 0, 0, 0])
	return {"edges": edges, "side": course_side, "seen": seen, "states": states, "native": events.native_runs, "motored": motored,
		"slot_rows": counted[5], "slot_misses": counted[6]}


func _add_kerb(world: Node3D) -> StaticBody3D:
	var kerb := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 0.25, 4.0)
	shape.shape = box
	kerb.add_child(shape)
	kerb.position = Vector3(0.0, 0.125, -6.0)
	world.add_child(kerb)
	return kerb


## The kerb is metal and the floor has no surface: stepping on and off it changes the surface. Without
## [param surfaced] neither has one.
func _rig_course_player(controller: GSFpsController, kerb_id: int, surfaced: bool) -> void:
	if surfaced:
		var surfaces := GSFpsSurfaceSet.new()
		surfaces.add(GSFpsSurface.make(&"metal"))
		controller.surfaces = surfaces
		controller.motor.surfaces = surfaces
		controller.motor.surface_resolver = func(id: int) -> StringName: return &"metal" if id == kerb_id else &""
	var boost := GSFpsModifier.make(&"boost")
	boost.max_speed_scale = 1.5
	boost.duration_sec = 0.25
	controller.motor.register_modifier(boost)


func _listen_course(controller: GSFpsController, edges: Array, side: Array, seen: Dictionary) -> void:
	for name in EDGES:
		controller.connect(name, func(a: Variant = null, b: Variant = null) -> void:
			edges.append([name, a, b])
			seen[name] = true)
	for name in SIDE:
		controller.connect(name, func(a: Variant = null, b: Variant = null) -> void:
			# simulated's state is the controller's own: its position then, not the object.
			side.append([name, a, (b as GSFpsState).position if b is GSFpsState else b])
			seen[name] = true)


static func _course_buttons(t: int) -> int:
	var buttons := 0
	if t % 90 == 30:
		buttons |= GSFpsCommand.BUTTON_JUMP
	if (t / 120) % 2 == 1:
		buttons |= GSFpsCommand.BUTTON_CROUCH
	return buttons


func _same(a: Dictionary, b: Dictionary, label: String) -> void:
	var first := -1
	var ea: Array = a["edges"]
	var eb: Array = b["edges"]
	for i in range(mini(ea.size(), eb.size())):
		if var_to_bytes(ea[i]) != var_to_bytes(eb[i]):
			first = i
			break
	_check(ea.size() == eb.size() and first < 0, "%s: the same signals in the same order (%d, %d%s)" % [
		label, ea.size(), eb.size(), "" if first < 0 else "; first differs at %d: %s vs %s" % [first, ea[first], eb[first]]])
	var sa: Array = a["side"]
	var sb: Array = b["side"]
	var side_first := -1
	for i in range(mini(sa.size(), sb.size())):
		if var_to_bytes(sa[i]) != var_to_bytes(sb[i]):
			side_first = i
			break
	_check(sa.size() == sb.size() and side_first < 0, "%s: the same surface, modifier and simulated signals (%d, %d%s)" % [
		label, sa.size(), sb.size(), "" if side_first < 0 else "; first differs at %d: %s vs %s" % [side_first, sa[side_first], sb[side_first]]])
	_check(a["states"] == b["states"], "%s: the same states every tick" % label)
