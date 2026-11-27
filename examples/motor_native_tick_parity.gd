extends "res://examples/motor_native_parity.gd"

## Holds [member GSFpsMotor.native_tick] (the tick's start and end in gs-sim) and [member GSFpsMotor.native_full] (the whole tick in one call, [code]GSSimFpsBody.motor_tick[/code]) to the all-script motor, to the bit: the determinism world's scenarios at 22, 33 and 66 Hz, with and without other players' hulls, under four tunable sets (default; wall slides and jumps; launch, dash, auto-hop and aimed walking; auto and jump-started wall runs that turn the view), the last two on long randomized streams. Every tick's state, timers, wall fields and view turn, and the motor's counters, are identical. With no library it says the native half was skipped and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Run: [code]godot --headless --path . res://examples/motor_native_tick_parity.tscn[/code]


const RANDOM_TICKS := 3000
const SWIM_TICKS := 1000


func _tick_tunables(variant: int) -> GSFpsTunables:
	var t := _tunables()
	if variant == 1:
		t.wall_slide_speed = 2.5
		t.wall_jump_enabled = true
		t.air_friction = 0.2
	elif variant == 2:
		t.launch_enabled = true
		t.launch_button = GSFpsCommand.BUTTON_USER_0
		t.dash_enabled = true
		t.dash_button = GSFpsCommand.BUTTON_USER_1
		t.dash_from_air = false
		t.jump_adds_to_velocity = true
		t.bhop_speed_cap_scale = 1.4
		t.slide_requires_sprint = true
		t.wall_jump_enabled = true
		t.aim_button = GSFpsCommand.BUTTON_USER_2
		t.aim_speed_scale = 0.45
	elif variant == 3:
		t.wall_run_auto = true
		t.wall_run_on_jump = true
		t.wall_run_turn_view = true
		t.wall_jump_enabled = true
		t.launch_enabled = true
		t.launch_button = GSFpsCommand.BUTTON_USER_0
		t.launch_from_air = false
		t.aim_button = GSFpsCommand.BUTTON_USER_2
		t.aim_speed_scale = 0.6
		t.sprint_blocks_aim = true
	elif variant >= 4:
		# Edge friction (gs-sim's has_edge_friction): four times the ground friction with a drop ahead. Variant 5 is
		# the same walker without it, to show the streams do reach a ledge.
		t.edge_friction = 4.0 if variant == 4 else 1.0
		t.edge_friction_reach = 0.6
		t.edge_friction_drop = 0.5
	return t


## A seeded stream that changes its inputs every few ticks: any move, sprint, crouch, jump and the three move buttons.
func _random_stream(seed: int, ticks: int) -> Array[GSFpsCommand]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var out: Array[GSFpsCommand] = []
	var c := GSFpsCommand.new()
	var yaw := 0.0
	for tick in range(ticks):
		if tick % 6 == 0 or rng.randf() < 0.08:
			c = GSFpsCommand.new()
			c.move = Vector2(rng.randi_range(-1, 1), -1.0 if rng.randf() < 0.6 else float(rng.randi_range(-1, 1)))
			var b := 0
			for bit: int in [GSFpsCommand.BUTTON_SPRINT, GSFpsCommand.BUTTON_CROUCH, GSFpsCommand.BUTTON_JUMP,
					GSFpsCommand.BUTTON_USER_0, GSFpsCommand.BUTTON_USER_1, GSFpsCommand.BUTTON_USER_2]:
				if rng.randf() < (0.5 if bit == GSFpsCommand.BUTTON_SPRINT else 0.18):
					b |= bit
			c.buttons = b
		yaw = wrapf(yaw + rng.randf_range(-0.2, 0.2), -PI, PI)
		var d := GSFpsCommand.new()
		d.move = c.move
		d.buttons = c.buttons
		d.yaw = yaw
		out.append(d)
	return out


## [param way] 0 is all script, 1 the native start and end, 2 the whole tick native.
func _tick_replay(way: int, sc: Array, stream: Array[GSFpsCommand], step: float, hulls: bool, variant: int) -> Dictionary:
	GSFpsPhysicsBody.native_enabled = way > 0
	GSFpsMotor.native_tick = way > 0
	GSFpsMotor.native_full = way >= 2
	# Way 3: the whole tick as a one-row GSFpsMotorBatch run that says what each tick changed (API 47).
	var batch: GSFpsMotorBatch = GSFpsMotorBatch.new() if way == 3 else null
	var events := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	var physics := GSFpsPhysicsBody.for_node(self)
	physics.pass_out_mask = 1 << 3
	var body: GSFpsBody = physics
	var boxes := _hull_boxes()
	if hulls:
		body = GSFpsHullBody.new().wrap(physics, func() -> Array: return boxes)
	var motor := GSFpsMotor.new(_tick_tunables(variant), body)
	var s := GSFpsState.new()
	s.position = sc[1]
	s.velocity = sc[2]
	s.mode = GSFpsState.Mode.AIR
	var swim: GSFpsSwimMode = null
	if not _swim_boxes.is_empty():
		swim = GSFpsSwimMode.new()
		swim.volumes = _swim_boxes
		swim.idle_sink_speed = _swim_sink
		motor.register_mode(swim)
	var ticks: Array[PackedByteArray] = []
	var before := GSFpsPhysicsBody.native_ticks
	var runs_after_jump := 0
	var swims := 0
	for c in stream:
		var after_jump := s.wall_jumps_in_air > 0 and not s.is_wall_running()
		var runs := motor.wall_runs
		if swim != null:
			# The game's own entry, each tick (GSFpsSwimMode.update); the mode leaves by itself.
			swim.update(motor, s)
			swims += 1 if s.mode == swim.mode_id else 0
		if batch != null:
			var was := [s.mode, s.position.y, s.is_sliding(), s.is_wall_running()]
			batch.start(step)
			motor.batch_events = 0
			motor.batch_events_allowed = true
			var row := batch.add(motor, s, c)
			if row >= 0:
				batch.finish(row)
				_tally_events(motor, s, was, events)
		else:
			motor.simulate(s, c, step)
		if after_jump and motor.wall_runs > runs:
			runs_after_jump += 1
		ticks.append(var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
			s.crouch_held, s.wall_jump_count, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.slide_time,
			s.slide_cooldown_left, s.launch_cooldown_left, s.dash_cooldown_left, s.wall_run_cooldown_left, s.wall_run_time,
			s.wall_run_spent, s.wall_jumps_in_air, s.wall_jump_heading, s.wall_normal, s.previous_buttons, motor.view_turn]))
	var counters := [body.hull_blocks, body.world_touches, motor.stuck_ticks, motor.duplicate_plane_ticks,
		motor.crease_leg_ticks, motor.split_leg_ticks, motor.depenetrated_ticks, motor.embedded_ticks, motor.lifted_ticks,
		motor.settled_ground_ticks, motor.reused_ground_ticks, motor.slides, motor.launches, motor.dashes, motor.wall_runs,
		motor.wall_jumps]
	return {"ticks": ticks, "counters": counters, "end": s.position, "native_ticks": GSFpsPhysicsBody.native_ticks - before,
		"script_ticks": motor.wall_jump_script_ticks, "runs_after_jump": runs_after_jump, "events": events,
		"swims": swims, "custom": motor.custom_native_ticks}


## The water [method _tick_replay] swims in when not empty (a GSFpsSwimMode it registers), and that mode's sink speed.
var _swim_boxes: Array[AABB] = []
var _swim_sink := 0.0


## Swimmers on the walkers' random streams with pitch, in and out of two overlapping pools over the determinism world's
## floor, ramps and walls (the game's GSFpsSwimMode.update each tick): the whole tick native (gs-sim's swim tail,
## GSSimFpsBody.has_swim, API 56) and the one-row batch hold to the script to the bit, and the library ran the swim ticks.
func _swim_runs() -> void:
	if not ClassDB.class_has_method(&"GSSimFpsBody", &"has_swim"):
		print("  gs-sim has no GSSimFpsBody.has_swim: the swim runs are skipped")
		if OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library runs the swim tick (GS_SIM_REQUIRE_NATIVE=1)")
		return
	var batched := GSFpsMotorBatch.available()
	var swum := 0
	var native_swum := 0
	var total := 0
	for sink: float in [0.0, 0.6]:
		_swim_sink = sink
		for hulls: bool in [false, true]:
			for hz: int in RATES:
				var step := 1.0 / float(hz)
				for sc: Array in SCENARIOS:
					# The first pool is shallow (its top 1.6 m up: a wader stands, a swimmer climbs out); the deep one
					# overlaps it and comes second, so the first box holding a point decides its surface.
					_swim_boxes = [AABB(Vector3(-30, -1, -30), Vector3(60, 2.6, 60)), AABB(Vector3(8, -1, -30), Vector3(22, 7, 40))]
					var stream := _random_stream(sc[3] * 17 + hz, SWIM_TICKS)
					var rng := RandomNumberGenerator.new()
					rng.seed = sc[3] * 7 + hz
					var pitch := 0.0
					for c in stream:
						pitch = clampf(pitch + rng.randf_range(-6.0, 6.0), -89.0, 89.0)
						c.pitch = pitch
					var a := _tick_replay(0, sc, stream, step, hulls, 0)
					var label := "%s @%d Hz%s swim%s" % [sc[0], hz, " +hulls" if hulls else "", " sink" if sink > 0.0 else ""]
					_check(a["native_ticks"] == 0 and a["custom"] == 0, label + ": the script run did not tick in the library")
					swum += a["swims"]
					var ways: Array[int] = [2]
					if batched:
						ways.append(3)
					for way in ways:
						var b := _tick_replay(way, sc, stream, step, hulls, 0)
						var first := -1
						for i in range(a["ticks"].size()):
							if a["ticks"][i] != b["ticks"][i]:
								first = i
								break
						var lw: String = label + [" script", " halves", " full", " batch"][way]
						total += stream.size()
						native_swum += b["custom"]
						_check(b["swims"] == a["swims"] and b["custom"] == b["swims"],
							lw + ": the library ran every swim tick (%d of %d)" % [b["custom"], b["swims"]])
						_check(first < 0, lw + ": every one of %d ticks identical%s" % [stream.size(), "" if first < 0 else " (first differs at tick %d: script %s native %s)" % [first, bytes_to_var(a["ticks"][first]), bytes_to_var(b["ticks"][first])]])
						_check(a["counters"] == b["counters"], lw + ": the same motor and hull counters %s (native %s)" % [a["counters"], b["counters"]])
	_swim_boxes = []
	_swim_sink = 0.0
	print("  %d swim stream ticks compared, %d swim ticks in script, %d in the library" % [total, swum, native_swum])
	_check(swum > 0 and native_swum > 0, "the streams swim (%d script swim ticks)" % swum)
	_sections += 1


## Holds one row's [member GSFpsMotor.batch_events] to the controller's own compare of [param was] (mode, height,
## sliding, wall running at the tick start) with [param s], into [param events]: [rows that said, rows that missed a
## change, the bits missed, changes seen of mode, height, slide, wall run, then the bits said with no change seen].
## Saying more than changed costs only a compare; missing a change would lose a signal.
func _tally_events(motor: GSFpsMotor, s: GSFpsState, was: Array, events: Array) -> void:
	var ev := motor.batch_events
	motor.batch_events = 0
	if ev & GSFpsMotor.EVENTS_KNOWN == 0:
		return
	var want := GSFpsMotor.EVENTS_KNOWN
	var bits := [GSFpsMotor.EVENT_MODE, GSFpsMotor.EVENT_Y, GSFpsMotor.EVENT_SLIDE, GSFpsMotor.EVENT_WALL_RUN]
	var now := [s.mode, s.position.y, s.is_sliding(), s.is_wall_running()]
	for k in range(4):
		if now[k] != was[k]:
			want |= bits[k]
			events[3 + k] += 1
		elif ev & bits[k] != 0:
			events[7 + k] += 1
	events[0] += 1
	events[1] += 0 if want & ~ev == 0 else 1
	events[2] |= want & ~ev


func _tick_runs() -> void:
	var names := ["", " +walls", " +moves", " +wallruns", " +edge"]
	var edged := ClassDB.class_has_method(&"GSSimFpsBody", &"has_edge_friction")
	var edge_streams := [0, 0]
	var edge_halves := 0
	var total := 0
	var runs_after_jump := 0
	var batched := GSFpsMotorBatch.available()
	# The one-row batch's events over every stream: [rows that said, differ, mode, height, slide, wall run changes].
	var events := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	var batch_rows := 0
	var variants: Array[int] = [0, 1, 2, 3]
	if edged:
		variants.append(4)
	else:
		print("  gs-sim has no GSSimFpsBody.has_edge_friction: the edge friction runs are skipped")
	for variant: int in variants:
		for hulls: bool in [false, true]:
			for hz: int in RATES:
				var step := 1.0 / float(hz)
				for sc: Array in SCENARIOS:
					var stream := _record(sc[3], sc[4], RUN_TICKS) if variant < 2 else _random_stream(sc[3] * 31 + hz, RANDOM_TICKS)
					var a := _tick_replay(0, sc, stream, step, hulls, variant)
					var label := "%s @%d Hz%s%s" % [sc[0], hz, " +hulls" if hulls else "", names[variant]]
					_check(a["native_ticks"] == 0, label + ": the script run did not tick in the library")
					runs_after_jump += a["runs_after_jump"]
					if variant == 4:
						edge_streams[0] += 1
						if _tick_replay(0, sc, stream, step, hulls, 5)["ticks"] != a["ticks"]:
							edge_streams[1] += 1
					var ways: Array[int] = [2]
					if variant < 2 or variant == 4:
						ways = [1, 2]
					if batched:
						ways.append(3)
					for way in ways:
						var b := _tick_replay(way, sc, stream, step, hulls, variant)
						var first := -1
						for i in range(a["ticks"].size()):
							if a["ticks"][i] != b["ticks"][i]:
								first = i
								break
						var lw: String = label + [" script", " halves", " full", " batch"][way]
						total += stream.size()
						print("  %-44s end %s  native %d  counters %s" % [lw, a["end"], b["native_ticks"], a["counters"]])
						# With an older library, a tick a run after a wall jump may start in runs in script, its start and end still in the library: two calls.
						var calls: int = stream.size() + b["script_ticks"]
						if way == 2 and ClassDB.class_has_method(&"GSSimFpsBody", &"runs_after_wall_jump"):
							_check(b["script_ticks"] == 0, lw + ": a library that slows a run after a wall jump runs every such tick itself (%d in script)" % b["script_ticks"])
						var want: bool = b["native_ticks"] == calls if way == 2 else b["native_ticks"] > stream.size()
						if way == 1 and variant == 4:
							# The halves' end reads the edge friction from the full array's tail (P1h).
							edge_halves += b["native_ticks"]
						if way == 3:
							batch_rows += stream.size()
							for k in range(events.size()):
								events[k] += b["events"][k]
						else:
							_check(want, lw + ": the native run ticked in the library, one call a tick when whole (%d of %d, %d after a wall jump in script)" % [b["native_ticks"], stream.size(), b["script_ticks"]])
						_check(first < 0, lw + ": every one of %d ticks identical%s" % [stream.size(), "" if first < 0 else " (first differs at tick %d: script %s native %s)" % [first, bytes_to_var(a["ticks"][first]), bytes_to_var(b["ticks"][first])]])
						_check(a["counters"] == b["counters"], lw + ": the same motor and hull counters %s (native %s)" % [a["counters"], b["counters"]])
	print("  %d native ticks compared" % total)
	if batched:
		# Rows whose clocks run in script (the first tick, a tick off the ground with its clocks held) do not say: these
		# streams jump and wall-run so much that 45% of rows say (2026-11-26), the batch parity's walkers more than half.
		_check(events[1] == 0, "the one-row batch's events hold every change the controller's compare sees (%d of %d rows miss bits %d; said unchanged: %s)" % [
			events[1], events[0], events[2], events.slice(7)])
		if events[0] == 0:
			print("  the library says no events (a gs-sim batch without events); the script compared every row")
		else:
			_check(events[0] * 3 > batch_rows and events[3] > 0 and events[4] > 0 and events[5] > 0 and events[6] > 0,
				"over a third of batch rows said what changed (%d of %d; mode %d, height %d, slide %d, wall run %d)" % [
					events[0], batch_rows, events[3], events[4], events[5], events[6]])
	if edged:
		_check(edge_streams[1] > 0,
			"edge friction changed %d of %d edge streams against the same walker without it: some reach a ledge" % [edge_streams[1], edge_streams[0]])
		_check(edge_halves > 0, "the halves ran %d edge friction ticks in the library" % edge_halves)
	_check(runs_after_jump > 0, "the streams start a wall run after a wall jump in the same air (%d times), the case _run_speed slows" % runs_after_jump)
	_sections += 1


## The crouch tunables _native_full_tun appends after wall_jump_up_speed (API 48), then the edge friction's three.
const CROUCH_TUN := 6
const EDGE_TUN := 3

## The motor keeps its native tunables arrays between ticks; a changed value or a swapped resource must rebuild both.
func _tun_cache_check() -> void:
	var was := GSFpsMotor.native_tick
	GSFpsMotor.native_tick = true
	var t := _tunables()
	var motor := GSFpsMotor.new(t, GSFpsPhysicsBody.for_node(self))
	var s := GSFpsState.new()
	s.mode = GSFpsState.Mode.GROUND
	var tick := motor._native_tick_tun(s)
	var full := motor._native_full_tun(tick)
	_check(motor._native_tick_tun(s) == tick and motor._native_full_tun(tick) == full,
		"the native tunables arrays are reused while nothing changes")
	# A game assigning a tunable every tick (a speed scale, a gate) must not drop the cache when the value is the same.
	var rev := t.revision
	var written := 0
	for p in t.get_property_list():
		if p["usage"] & PROPERTY_USAGE_SCRIPT_VARIABLE and p["usage"] & PROPERTY_USAGE_EDITOR:
			t.set(p["name"], t.get(p["name"]))
			written += 1
	_check(written > 100 and t.revision == rev,
		"a same-value write to each of %d exported tunables leaves revision alone (%d -> %d)" % [written, rev, t.revision])
	t.can_noclip = not t.can_noclip
	_check(t.revision == rev + 1, "a changed value bumps revision once (%d -> %d)" % [rev, t.revision])
	t.can_noclip = not t.can_noclip
	t.max_speed += 1.0
	t.wall_jump_up_speed += 1.0
	var tick2 := motor._native_tick_tun(s)
	var full2 := motor._native_full_tun(tick2)
	_check(tick2[11] == t.max_speed and full2[11] == t.max_speed and full2[full2.size() - 1 - CROUCH_TUN - EDGE_TUN] == t.wall_jump_up_speed,
		"a changed tunable rebuilds the tick and full arrays (max_speed %s, wall_jump_up_speed %s)" % [tick2[11], full2[full2.size() - 1 - CROUCH_TUN - EDGE_TUN]])
	t.edge_friction_drop += 0.25
	var full3 := motor._native_full_tun(motor._native_tick_tun(s))
	_check(full3[full3.size() - 1] == t.edge_friction_drop and full3[full3.size() - 3] == t.edge_friction,
		"the full array ends with the edge friction, its reach and drop (%s)" % [full3.slice(full3.size() - 3)])
	var other := _tunables()
	other.max_speed = t.max_speed + 2.0
	motor.tunables = other
	_check(motor._native_tick_tun(s)[11] == other.max_speed, "swapped tunables rebuild the arrays")
	GSFpsMotor.native_tick = was


func _run() -> void:
	print("gs-player-controller motor native tick parity")
	_tun_cache_check()
	var loaded := GSFpsPhysicsBody.native_available()
	var expected := 1
	if not loaded or not ClassDB.class_has_method(GSFpsPhysicsBody.NATIVE_CLASS, &"motor_tick"):
		# A library from before the tick halves is a skip, not a failure: the slide's own suite still gates it.
		print("  gs-sim's motor tick is not loaded: the native half is skipped")
		if not loaded and OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		expected = 0
	else:
		_build_world()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_tick_runs()
		_swim_runs()
		expected = 2 if ClassDB.class_has_method(&"GSSimFpsBody", &"has_swim") else 1
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = false
	GSFpsMotor.native_full = true
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
