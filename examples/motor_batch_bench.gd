extends "res://examples/motor_bench.gd"

## Micro-benchmark of the players' loop a dedicated server runs with [GSFpsMotorBatch] (game-fatal-contact's `_tick_players_batched`): N controllers in a collision world, their hulls in gs-sim's hull world, each tick begin_tick and add for every player, then finish and end_tick for every player. Prints microseconds per player per tick for each of the four steps, and a digest of every tick's states: one build prints one digest, and a change that keeps results identical prints the digest the tree before it printed. Also runs the one-by-one loop ([method GSFpsController.simulate_tick]) and says whether it ends in the same states. With no gs-sim library it says so and exits 0. Run: [code]godot --headless --path . res://examples/motor_batch_bench.tscn [-- --n=32 --ticks=1000 --rows][/code] (--rows: the batch over 55-value rows, not the states' columns; --phases: begin_tick and end_tick split by phase)


## A controller whose physics body is wrapped in a hull body, as game-fatal-contact's players are (FcSolidBody).
class HullController extends GSFpsController:
	func _make_body() -> GSFpsBody:
		return GSFpsHullBody.new().wrap(super._make_body(), Callable())


func _hull_player(i: int, parent: Node) -> GSFpsController:
	var player := CharacterBody3D.new()
	player.name = "P%d" % i
	player.collision_layer = 0
	player.collision_mask = 0
	parent.add_child(player)
	var collision := CollisionShape3D.new()
	collision.name = "Collision"
	collision.shape = CapsuleShape3D.new()
	player.add_child(collision)
	var head := Node3D.new()
	head.name = "Head"
	player.add_child(head)
	var camera := Camera3D.new()
	camera.name = "Camera"
	head.add_child(camera)
	var view := GSFpsView.new()
	view.name = "View"
	player.add_child(view)
	var c := HullController.new()
	c.name = "Controller"
	c.drive = GSFpsController.Drive.EXTERNAL
	c.register_default_actions = false
	c.register_service = false
	player.add_child(c)
	return c


## One run of [member _ticks] ticks; [param batched] picks the loop. Returns the microseconds per player per tick of
## each step and the digest of every tick's states.
func _loop(batched: bool) -> Dictionary:
	var root := Node3D.new()
	add_child(root)
	_world_into(root, true)
	var ctrls: Array[GSFpsController] = []
	for i in range(_n):
		ctrls.append(_hull_player(i, root))
	await get_tree().physics_frame
	await get_tree().physics_frame
	var world: Object = ClassDB.instantiate(&"GSSimHullWorld")
	var ids := PackedInt64Array()
	var wired := true
	for i in range(_n):
		var c := ctrls[i]
		if not c._started:
			c.setup()
		# Close together, so the hulls block each other now and then.
		c.teleport(Vector3(-6.0 + float(i % 8) * 1.5, 0.05, -6.0 + float(i / 8) * 1.5))
		wired = c.body.set_hull_world(world, i) and wired
		ids.append(100 + i)
	var batch := GSFpsMotorBatch.new()
	var rows := PackedInt64Array()
	rows.resize(_n)
	var us := PackedInt64Array([0, 0, 0, 0, 0])
	var digest := 0
	var tun := ctrls[0].tunables
	for tick in range(_ticks):
		var data := PackedFloat64Array()
		for i in range(_n):
			var p := ctrls[i].state.position
			data.append_array(PackedFloat64Array([p.x, p.y, p.z, tun.radius, tun.stand_height, 7]))
		world.begin(ids, data, Callable(), 1.0e9)
		for i in range(_n):
			ctrls[i].apply_command(command_for(tick, i, false))
		var t0 := Time.get_ticks_usec()
		if batched:
			wired = batch.start(STEP) and wired
			for i in range(_n):
				var c := ctrls[i]
				var t := Time.get_ticks_usec()
				var began := c.begin_tick(tick, STEP)
				var t1 := Time.get_ticks_usec()
				us[0] += t1 - t
				rows[i] = batch.add(c.motor, c.state, c.current_command) if began else -2
				us[1] += Time.get_ticks_usec() - t1
			for i in range(_n):
				var c := ctrls[i]
				if rows[i] < 0:
					continue
				var t := Time.get_ticks_usec()
				var told := batch.finish(rows[i])
				var t1 := Time.get_ticks_usec()
				us[2] += t1 - t
				c.end_tick(tick, STEP)
				us[3] += Time.get_ticks_usec() - t1
				if not told:
					var f := c.state.position
					world.moved(i, f.x, f.y, f.z)
		else:
			for i in range(_n):
				var c := ctrls[i]
				c.simulate_tick(tick, STEP)
				var f := c.state.position
				world.moved(i, f.x, f.y, f.z)
		us[4] += Time.get_ticks_usec() - t0
		world.end()
		for i in range(_n):
			var s := ctrls[i].state
			digest = hash([digest, s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.surface,
				s.time_since_grounded, s.time_since_jump, s.previous_buttons, ctrls[i].motor.view_turn])
	var counters := []
	for c in ctrls:
		counters.append_array([c.body.hull_blocks, c.motor.ticks_simulated, c.motor.wall_jumps, c.motor.slides])
	root.queue_free()
	await get_tree().physics_frame
	await get_tree().physics_frame
	var per := float(_n * _ticks)
	return {"begin": us[0] / per, "add": us[1] / per, "finish": us[2] / per, "end": us[3] / per, "total": us[4] / per,
		"digest": digest, "counters": hash(counters), "wired": wired, "rows": batch.rows, "runs": batch.runs}


## One more batched run with GameSpice Sim's query timers on (--profile): engine queries per row and their cost, split by
## where the motor asked them. The timers add their own cost, so the totals here are not the bench's numbers.
func _profiled() -> void:
	ClassDB.class_call_static(&"GSSimFpsBody", &"reset_profile")
	ClassDB.class_call_static(&"GSSimFpsBody", &"set_profile", true)
	await _loop(true)
	var c: PackedInt64Array = ClassDB.class_call_static(&"GSSimFpsBody", &"profile_counters")
	var sites: String = ClassDB.class_call_static(&"GSSimFpsBody", &"profile_sites")
	ClassDB.class_call_static(&"GSSimFpsBody", &"set_profile", false)
	var rows := float(maxi(c[8], 1))
	var line := "  profile per row:"
	var names := ["cast", "rest", "overlap", "ray", "tick"]
	for i in mini(names.size(), c.size() / 2):
		line += " %s %.2fx %.2fus" % [names[i], c[i * 2] / rows, c[i * 2 + 1] / rows]
	print(line)
	print("  " + sites)


func _run() -> void:
	# --rows: the batch over 55-value rows (GSFpsMotorBatch.native_cols off), for a before and after in one session.
	GSFpsMotorBatch.native_cols = not ("--rows" in OS.get_cmdline_user_args())
	# --no-events: the controller compares every change in script (GSFpsMotorBatch.native_events off), the level-41 loop.
	GSFpsMotorBatch.native_events = not ("--no-events" in OS.get_cmdline_user_args())
	# --no-crouch: the batch's crouch runs in script at add (GSFpsMotorBatch.native_crouch off), the level-42 loop.
	GSFpsMotorBatch.native_crouch = not ("--no-crouch" in OS.get_cmdline_user_args())
	print("motor batch bench: n=%d ticks=%d columns=%s events=%s crouch=%s" % [
		_n, _ticks, GSFpsMotorBatch.native_cols, GSFpsMotorBatch.native_events, GSFpsMotorBatch.native_crouch])
	if not GSFpsPhysicsBody.native_available() or not GSFpsMotorBatch.available() or not ClassDB.class_exists(&"GSSimHullWorld"):
		print("  gs-sim's motor batch is not loaded: skipped")
		get_tree().quit(0)
		return
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	GSFpsMotor.profile = false
	GSFpsController.phase_timers = "--phases" in OS.get_cmdline_user_args()
	await get_tree().physics_frame
	var best := {}
	var one: Dictionary = {}
	var digests := {}
	# Interleaved, best of three, so a loaded machine biases neither loop.
	for rep in range(3):
		one = await _loop(false)
		GSFpsController.phase_us.fill(0)
		var b: Dictionary = await _loop(true)
		b["phases"] = GSFpsController.phase_us.duplicate()
		digests[b["digest"]] = true
		if best.is_empty() or b["total"] < best["total"]:
			best = b
		print("  rep %d: one-by-one %.1f us/player, batched %.1f (begin_tick %.1f add %.1f finish %.1f end_tick %.1f)" % [
			rep, one["total"], b["total"], b["begin"], b["add"], b["finish"], b["end"]])
	print("  best batched %.1f us/player/tick: begin_tick %.1f, add %.1f, finish %.1f, end_tick %.1f; rows %d in %d runs" % [
		best["total"], best["begin"], best["add"], best["finish"], best["end"], best["rows"], best["runs"]])
	if GSFpsController.phase_timers:
		# --phases: begin_tick and end_tick split (GSFpsController.phase_us), us per player per tick of the best run.
		var ph: PackedInt64Array = best["phases"]
		var per := float(_n * _ticks)
		print("  phases: pre %.2f consume %.2f publish %.2f (body write %.2f) report %.2f signals+stats %.2f post %.2f" % [
			ph[0] / per, ph[1] / per, ph[3] / per, ph[7] / per, ph[4] / per, ph[5] / per, ph[6] / per])
	print("  BATCH_DIGEST %d counters %d" % [best["digest"], best["counters"]])
	if "--profile" in OS.get_cmdline_user_args():
		await _profiled()
	var ok: bool = best["wired"] and digests.size() == 1
	print("  batched runs identical to each other: %s; identical to the one-by-one loop: %s" % [
		digests.size() == 1, one["digest"] == best["digest"] and one["counters"] == best["counters"]])
	get_tree().quit(0 if ok else 1)
