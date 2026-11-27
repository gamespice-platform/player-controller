extends "res://examples/fps_controller_selftest_base.gd"

## Holds [GSFpsTickEvents] (a tick's motor edges for every player as one table, derived once) to the signals
## [GSFpsController] emitted one at a time: gs-sim's [code]GSSimTickEvents[/code] against the script derive, to the bit,
## over seeded random rows that reach every kind and both edges of each comparison; then one controller's course
## (walking, jumping, crouching, stepping up a kerb) run three ways, signals at once, rows derived in script and rows
## derived natively, with the same signals in the same order and the same states. With no library the native half says
## so and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead.
## Run: [code]godot --headless --path . res://examples/tick_events_parity.tscn[/code]

const ROWS := 6000
const COURSE_TICKS := 720
const EDGES: Array[StringName] = [&"mode_changed", &"landed", &"jumped", &"stepped_up", &"crouch_changed",
	&"slide_changed", &"launched", &"dashed", &"wall_jumped", &"wall_run_changed", &"view_turned"]


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
	for k in [&"mode_changed", &"landed", &"jumped", &"stepped_up", &"crouch_changed"]:
		_check(legacy["seen"].has(k), "the course reaches %s" % k)
	_same(legacy, script, "rows derived in script")
	if native:
		var nat := await _course(2)
		_same(legacy, nat, "rows derived natively")
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


## [param how]: 0 signals at once, 1 rows derived in script, 2 rows derived natively.
func _course(how: int) -> Dictionary:
	var world := _make_world()
	var kerb := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4.0, 0.25, 4.0)
	shape.shape = box
	kerb.add_child(shape)
	kerb.position = Vector3(0.0, 0.125, -6.0)
	world.add_child(kerb)
	var controller := _make_player(world, GSFpsController.Drive.LOCAL)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var edges: Array = []
	var seen := {}
	for name in EDGES:
		controller.connect(name, func(a: Variant = null, b: Variant = null) -> void:
			edges.append([name, a, b])
			seen[name] = true)
	var events := GSFpsTickEvents.new()
	var states := PackedByteArray()
	for t in range(COURSE_TICKS):
		var buttons := 0
		if t % 90 == 30:
			buttons |= GSFpsCommand.BUTTON_JUMP
		if (t / 120) % 2 == 1:
			buttons |= GSFpsCommand.BUTTON_CROUCH
		var forward := 1.0 if (t / 240) % 2 == 0 else -1.0
		if how > 0:
			events.clear()
			controller.event_rows = events
			controller.event_entity = 7
		var before := edges.size()
		controller.apply_command(_command(forward, 0.0, 0.0, buttons))
		controller.simulate_tick(t, STEP)
		if how > 0:
			if edges.size() != before:
				_check(false, "no motor edge is emitted before the dispatch (tick %d)" % t)
			events.derive(how == 2)
			var end := controller.dispatch_events(events, 0)
			if end != events.count:
				_check(false, "dispatch takes every event of its entity (%d of %d)" % [end, events.count])
		var s := controller.state
		states.append_array(var_to_bytes([s.position, s.velocity, s.mode, s.crouch_fraction]))
	world.queue_free()
	await get_tree().process_frame
	return {"edges": edges, "seen": seen, "states": states, "native": events.native_runs}


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
	_check(a["states"] == b["states"], "%s: the same states every tick" % label)
