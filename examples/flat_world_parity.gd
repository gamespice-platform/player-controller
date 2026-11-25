extends "res://examples/motor_native_tick_parity.gd"

## Holds [GSFpsFlatBody]'s native world (gs-sim's [code]GSSimFpsBody.set_flat_world[/code]: floor, boxes and half-space planes sent as two packed arrays) to the script flat body, to the bit. Tolerance: none, every float of every answer is compared exactly. Two levels: random sweeps, rest contacts and overlaps against a world of a floor, walls, steps, pillars and two planes, every field of every [GSFpsBody.Hit] compared; then the motor replays random input streams once with [member GSFpsFlatBody.use_native_world] off and once on, and every tick's state and the motor counters must be identical. A box added after the first native tick must reach the library. With no library it says so and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Run: [code]godot --headless --path . res://examples/flat_world_parity.tscn[/code]

const QUERIES := 6000
const FLAT_TICKS := 1500


func _flat_world() -> GSFpsFlatBody:
	var b := GSFpsFlatBody.with_floor(0.0)
	b.add_box(AABB(Vector3(-30, 0, -30), Vector3(60, 6, 1)))
	b.add_box(AABB(Vector3(-30, 0, 29), Vector3(60, 6, 1)))
	b.add_box(AABB(Vector3(-30, 0, -30), Vector3(1, 6, 60)))
	b.add_box(AABB(Vector3(29, 0, -30), Vector3(1, 6, 60)))
	for i in range(5):
		b.add_step(Vector3(2.0 + 1.5 * i, 0.0, -4.0), Vector3(1.5, 0.3 * float(i + 1), 4.0))
	for i in range(8):
		b.add_box(AABB(Vector3(-20.0 + 4.5 * i, 0.0, 8.0 + float(i % 3) * 3.0), Vector3(1.2, 2.5, 1.2)))
	b.add_ramp(Vector3(-12, 0, -10), Vector3(0, 0, -1), 25.0)
	b.add_plane(Plane(Vector3(-0.8, 0.6, 0.0).normalized(), -22.0))
	return b


func _bits(h: GSFpsBody.Hit) -> PackedByteArray:
	return var_to_bytes([h.hit, h.fraction, h.normal, h.point, h.depth, h.collider_id])


func _query_parity() -> void:
	GSFpsPhysicsBody.native_enabled = true
	var body := _flat_world()
	var nat: Object = body._nat()
	_check(nat != null, "the flat body hands its queries to the library")
	var rng := RandomNumberGenerator.new()
	rng.seed = 91
	var bad := 0
	var hits := 0
	var first := ""
	for i in range(QUERIES):
		var at := Vector3(rng.randf_range(-32, 32), rng.randf_range(-0.5, 8), rng.randf_range(-32, 32))
		var motion := Vector3(rng.randf_range(-3, 3), rng.randf_range(-3, 3), rng.randf_range(-3, 3))
		var height := rng.randf_range(1.0, 2.2)
		var radius := rng.randf_range(0.2, 0.5)
		var a := body.sweep(at, motion, height, radius)
		var b := GSFpsPhysicsBody._hit_of(nat.sweep(at, motion, height, radius, body.collision_mask, body.pass_out_mask))
		var ra := body.rest_contact(at, height, radius)
		var rb := GSFpsPhysicsBody._hit_of(nat.rest_contact(at, height, radius, body.collision_mask, body.pass_out_mask))
		var oa := body.overlaps(at, height, radius)
		var ob: bool = nat.overlaps(at, height, radius, body.collision_mask, body.pass_out_mask)
		if a.hit:
			hits += 1
		if _bits(a) != _bits(b) or _bits(ra) != _bits(rb) or oa != ob:
			bad += 1
			if first == "":
				first = "at %s motion %s: sweep %s vs %s, rest %s vs %s, overlap %s vs %s" % [at, motion, a, b, ra, rb, oa, ob]
	_check(bad == 0, "%d random sweeps, rest contacts and overlaps identical (%d sweeps hit)%s" % [QUERIES, hits, "" if bad == 0 else ": %d differ, first %s" % [bad, first]])
	_check(hits > QUERIES / 10, "the sweeps hit often enough to mean something (%d)" % hits)
	# A box added after the library has the world must reach it.
	var probe := Vector3(15.0, 3.0, -26.0)
	var before := body.sweep(probe, Vector3(0, 0, 4), 1.8, 0.4)
	body.add_box(AABB(Vector3(13, 0, -23), Vector3(4, 6, 1)))
	nat = body._nat()
	var a2 := body.sweep(probe, Vector3(0, 0, 4), 1.8, 0.4)
	var b2 := GSFpsPhysicsBody._hit_of(nat.sweep(probe, Vector3(0, 0, 4), 1.8, 0.4, body.collision_mask, body.pass_out_mask))
	_check(not before.hit and a2.hit and _bits(a2) == _bits(b2), "a box added after the first native call reaches the library (%s vs %s)" % [a2, b2])
	_sections += 1


func _flat_replay(native: bool, sc: Array, stream: Array[GSFpsCommand], step: float, variant: int) -> Dictionary:
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	GSFpsFlatBody.use_native_world = native
	var body := _flat_world()
	var motor := GSFpsMotor.new(_tick_tunables(variant), body)
	var s := GSFpsState.new()
	s.position = sc[1]
	s.velocity = sc[2]
	s.mode = GSFpsState.Mode.AIR
	var ticks: Array[PackedByteArray] = []
	var before := GSFpsFlatBody.native_ticks
	for c in stream:
		motor.simulate(s, c, step)
		ticks.append(var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
			s.crouch_held, s.wall_jump_count, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.slide_time,
			s.slide_cooldown_left, s.launch_cooldown_left, s.dash_cooldown_left, s.wall_run_cooldown_left, s.wall_run_time,
			s.wall_run_spent, s.wall_jumps_in_air, s.wall_jump_heading, s.wall_normal, s.previous_buttons, motor.view_turn]))
	GSFpsFlatBody.use_native_world = true
	var counters := [body.world_touches, motor.stuck_ticks, motor.duplicate_plane_ticks, motor.crease_leg_ticks,
		motor.split_leg_ticks, motor.depenetrated_ticks, motor.embedded_ticks, motor.lifted_ticks, motor.settled_ground_ticks,
		motor.reused_ground_ticks, motor.slides, motor.launches, motor.dashes, motor.wall_runs, motor.wall_jumps]
	return {"ticks": ticks, "counters": counters, "end": s.position, "native_ticks": GSFpsFlatBody.native_ticks - before}


func _flat_runs() -> void:
	var total := 0
	var starts := [Vector3(0, 0.05, 0), Vector3(-5, 0.05, 12), Vector3(3, 0.05, -2), Vector3(20, 4.0, 20), Vector3(-12, 0.05, -8)]
	for variant: int in [0, 1, 2, 3]:
		for hz: int in [22, 66]:
			var step := 1.0 / float(hz)
			for k in range(starts.size()):
				var sc := ["flat%d" % k, starts[k], Vector3.ZERO]
				var stream := _random_stream(k * 17 + hz + variant, FLAT_TICKS)
				var a := _flat_replay(false, sc, stream, step, variant)
				var b := _flat_replay(true, sc, stream, step, variant)
				var first := -1
				for i in range(stream.size()):
					if a["ticks"][i] != b["ticks"][i]:
						first = i
						break
				var label := "%s @%d Hz variant %d" % [sc[0], hz, variant]
				total += stream.size()
				_check(a["native_ticks"] == 0, label + ": the script run did not tick in the library")
				_check(b["native_ticks"] == stream.size(), label + ": the native run made one library call a tick (%d of %d)" % [b["native_ticks"], stream.size()])
				_check(first < 0, label + ": every one of %d ticks identical%s" % [stream.size(), "" if first < 0 else " (first differs at tick %d)" % first])
				_check(a["counters"] == b["counters"], label + ": the same motor counters %s (native %s)" % [a["counters"], b["counters"]])
	print("  %d flat-world ticks compared" % total)
	_sections += 1


func _run() -> void:
	print("gs-player-controller flat world parity")
	var loaded := GSFpsFlatBody.native_world_available()
	if not loaded:
		print("  gs-sim's flat world is not loaded: the native half is skipped")
		if OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library has the flat world (GS_SIM_REQUIRE_NATIVE=1)")
	else:
		_query_parity()
		_flat_runs()
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = false
	GSFpsMotor.native_full = true
	GSFpsFlatBody.use_native_world = true
	print("%d passed, %d failed" % [_passed, _failed])
	var expected := 2 if loaded else 0
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
