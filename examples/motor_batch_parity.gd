extends "res://examples/motor_native_tick_parity.gd"

## Holds [GSFpsMotorBatch] (several players' motor ticks in runs of one gs-sim call) to the players' loop it replaces, [method GSFpsMotor.simulate] one player after another, to the bit: eight players walking into each other on random streams, six in gs-sim's hull world, one with no hulls and one gathering by script, at two rates under two tunable sets. A push between the add and a player's turn, a teleport after its tick and a death during another player's turn take the rows after them back; every tick's state and the counters stay identical. One player ticks every other tick two ticks long ([method GSFpsMotorBatch.add]'s delta), as a server's far bot does. With no library it says so and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Run: [code]godot --headless --path . res://examples/motor_batch_parity.tscn[/code]

const PLAYERS := 8
const BATCH_TICKS := 1500
const PLAIN := 6
const SCRIPTED := 7
const DIES := 3
const DEATH_TICK := 900
## Sits out every odd tick and makes it up on the even one.
const SKIPS := 5


func _start(i: int) -> Vector3:
	return Vector3(-3.2 + 0.9 * float(i), 0.05, 0.4 * float(i % 3))


func _snap(s: GSFpsState, motor: GSFpsMotor) -> PackedByteArray:
	return var_to_bytes([s.position, s.velocity, s.mode, s.move_flags(), s.ground_normal, s.ground_id, s.surface,
		s.crouch_held, s.wall_jump_count, s.time_since_grounded, s.time_since_jump_pressed, s.time_since_jump, s.slide_time,
		s.slide_cooldown_left, s.launch_cooldown_left, s.dash_cooldown_left, s.wall_run_cooldown_left, s.wall_run_time,
		s.wall_run_spent, s.wall_jumps_in_air, s.wall_jump_heading, s.wall_normal, s.previous_buttons, motor.view_turn])


func _batch_replay(
	batched: bool, hz: int, variant: int, streams: Array, cols: bool = true, native_state: bool = true,
	native_events: bool = true
) -> Dictionary:
	GSFpsMotorBatch.native_cols = cols
	GSFpsMotorBatch.native_state = native_state
	GSFpsMotorBatch.native_events = native_events
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = true
	GSFpsMotor.native_full = true
	var step := 1.0 / float(hz)
	var tun := _tick_tunables(variant)
	var world: Object = ClassDB.instantiate(&"GSSimHullWorld")
	var motors: Array[GSFpsMotor] = []
	var states: Array[GSFpsState] = []
	var alive: Array[bool] = []
	var ids := PackedInt64Array()
	var script_gathers: Array[int] = [0]
	var wired := _batch_players(tun, world, motors, states, alive, script_gathers)
	for i in range(PLAYERS):
		ids.append(100 + i)
	var batch := GSFpsMotorBatch.new()
	var ticks: Array[PackedByteArray] = []
	var rows: Array[int] = []
	rows.resize(PLAYERS)
	var before := GSFpsPhysicsBody.native_ticks
	# post_row against the state it describes: [rows from the batch's answer, rows that differ].
	var post := PackedFloat64Array()
	post.resize(GSFpsMotorBatch.POST)
	var posts := [0, 0]
	# What each player's tick changed by the controller's compare (mode, height, slide, wall run), against what the
	# batch said (GSFpsMotor.batch_events): [rows it said, rows that differ, changes seen, mode/height/slide/wall run seen].
	var events := [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
	var was_at := []
	was_at.resize(PLAYERS)
	for tick in range(BATCH_TICKS):
		world.begin(ids, _hull_rows(tun, states, alive), Callable(), 1.0e9)
		# A surface edited in place (same object, new values): a row's kept values (ROW_CONSTS) must follow it.
		if tick == 300 or tick == 700:
			var surf: GSFpsSurface = motors[0]._surface
			surf.friction_scale = 0.5 if tick == 300 else 1.0
			surf.push = Vector3(0.4, 0.0, -0.2) if tick == 300 else Vector3.ZERO
			motors[4]._surface.max_speed_scale = 1.25 if tick == 300 else 1.0
		if batched:
			wired = batch.start(step) and wired
			for i in range(PLAYERS):
				if not alive[i] or (i == SKIPS and tick % 2 == 1):
					rows[i] = -1
				else:
					var b := states[i]
					was_at[i] = [b.mode, b.position.y, b.is_sliding(), b.is_wall_running()]
					motors[i].batch_events = 0
					motors[i].batch_events_allowed = true
					rows[i] = batch.add(motors[i], states[i], streams[i][tick], step * 2.0 if i == SKIPS else -1.0)
		for i in range(PLAYERS):
			if batched and rows[i] >= 0 and not alive[i]:
				# The one tick the loops differ in: its start had run when the player died, and stays counted.
				batch.skip(rows[i])
				rows[i] = -1
				motors[i].ticks_simulated -= 1
			if not alive[i] or (i == SKIPS and tick % 2 == 1):
				continue
			var s := states[i]
			if i == 2 and tick % 97 == 13:
				s.velocity += Vector3(0.5, 3.0, 1.0)
			var told := false
			if batched:
				told = batch.finish(rows[i])
				if rows[i] >= 0:
					_tally_events(motors[i], s, was_at[i], events)
					posts[0] += 1 if batch.post_row(rows[i], post, 0) else 0
					posts[1] += 0 if _post_matches(post, s) else 1
			else:
				motors[i].simulate(s, streams[i][tick], step * 2.0 if i == SKIPS else step)
			if not told:
				world.moved(i, s.position.x, s.position.y, s.position.z)
			var changed := false
			if i == 1 and tick % 131 == 50:
				s.position = _start(i) + Vector3(0.0, 0.5, 0.0)
				s.velocity = Vector3.ZERO
				world.moved(i, s.position.x, s.position.y, s.position.z)
				changed = true
			if i == 1 and tick == DEATH_TICK:
				alive[DIES] = false
				world.set_alive(DIES, false)
				changed = true
			if changed and batched:
				batch.moved_after(rows[i])
		world.end()
		var all := PackedByteArray()
		for i in range(PLAYERS):
			if alive[i]:
				all.append_array(_snap(states[i], motors[i]))
		ticks.append(all)
	return {"ticks": ticks, "counters": _counters(motors), "wired": wired, "script_gathers": script_gathers[0],
		"native_ticks": GSFpsPhysicsBody.native_ticks - before, "batch": batch, "posts": posts, "events": events, "blocks": motors[0].body.hull_blocks + motors[4].body.hull_blocks}

## The hull world's per-player rows for one tick: position, radius, height and the flags.
func _hull_rows(tun: Object, states: Array[GSFpsState], alive: Array[bool]) -> PackedFloat64Array:
	var data := PackedFloat64Array()
	for i in range(PLAYERS):
		var p := states[i].position
		var flags := 0 if i == PLAIN else (3 if i == SCRIPTED else 7)
		if not alive[i]:
			flags &= ~2
		data.append_array(PackedFloat64Array([p.x, p.y, p.z, tun.radius, tun.stand_height, flags]))
	return data


func _counters(motors: Array[GSFpsMotor]) -> Array:
	var counters := []
	for m in motors:
		counters.append_array([m.body.hull_blocks, m.body.world_touches, m.stuck_ticks, m.depenetrated_ticks, m.slides,
			m.launches, m.dashes, m.wall_runs, m.wall_jumps, m.ticks_simulated, m.reused_ground_ticks, m.settled_ground_ticks,
			m.embedded_ticks, m.lifted_ticks, m.duplicate_plane_ticks, m.crease_leg_ticks, m.split_leg_ticks, m.idle_ticks])
	return counters


const _COUNTER_NAMES := ["hull_blocks", "world_touches", "stuck", "depenetrated", "slides", "launches", "dashes",
	"wall_runs", "wall_jumps", "ticks_simulated", "reused_ground", "settled_ground", "embedded", "lifted",
	"duplicate_plane", "crease_leg", "split_leg", "idle"]


## Where two [method _counters] differ ("" when they do not): the first player and counter, both values.
func _counter_diff(a: Array, b: Array) -> String:
	for i in range(mini(a.size(), b.size())):
		if a[i] != b[i]:
			var n := _COUNTER_NAMES.size()
			return " (player %d %s: %s vs %s)" % [i / n, _COUNTER_NAMES[i % n], a[i], b[i]]
	return "" if a.size() == b.size() else " (%d vs %d values)" % [a.size(), b.size()]


## Whether [method GSFpsMotorBatch.post_row]'s [param post] is [param s]'s (the velocity as the float32 it is stored as).
func _post_matches(post: PackedFloat64Array, s: GSFpsState) -> bool:
	var v := Vector3(post[0], 0.0, post[1])
	return (v.x == s.velocity.x and v.z == s.velocity.z and post[2] == s.mode and post[3] == s.crouch_fraction
		and post[4] == s.slide_time and post[5] == s.wall_run_time and post[6] == (1.0 if s.sprinting else 0.0))


## [method _batch_replay]'s players: a motor and a state each, every player but PLAIN behind a hull body
## that sees the others (counting its gathers in [param script_gathers]). False when a hull world did not wire.
func _batch_players(
	tun: GSFpsTunables, world: Object, motors: Array[GSFpsMotor], states: Array[GSFpsState],
	alive: Array[bool], script_gathers: Array[int]
) -> bool:
	var wired := true
	for i in range(PLAYERS):
		var physics := GSFpsPhysicsBody.for_node(self)
		physics.pass_out_mask = 1 << 3
		var body: GSFpsBody = physics
		if i != PLAIN:
			var me := i
			body = GSFpsHullBody.new().wrap(physics, func() -> Array:
				script_gathers[0] += 1
				var boxes := []
				for j in range(PLAYERS):
					if j != me and j != PLAIN and alive[j]:
						var f := states[j].position
						boxes.append(AABB(f - Vector3(tun.radius, 0.0, tun.radius), Vector3(tun.radius * 2.0, tun.stand_height, tun.radius * 2.0)))
				return boxes)
			if i != SCRIPTED:
				wired = body.set_hull_world(world, i) and wired
		motors.append(GSFpsMotor.new(tun, body))
		var s := GSFpsState.new()
		s.position = _start(i)
		s.mode = GSFpsState.Mode.AIR
		states.append(s)
		alive.append(true)
	return wired


func _batch_runs() -> void:
	for variant: int in [0, 2]:
		for hz: int in [33, 66]:
			var streams := []
			for i in range(PLAYERS):
				streams.append(_random_stream(1000 + i * 77 + hz + variant, BATCH_TICKS))
			var a := _batch_replay(false, hz, variant, streams)
			var b := _batch_replay(true, hz, variant, streams)
			var label := "%d players @%d Hz set %d" % [PLAYERS, hz, variant]
			_cols_check(a, _batch_replay(true, hz, variant, streams, false), b, label)
			_states_check(a, _batch_replay(true, hz, variant, streams, true, false), b, label)
			_events_check(a, _batch_replay(true, hz, variant, streams, true, true, false), b, label)
			var first := -1
			for i in range(BATCH_TICKS):
				if a["ticks"][i] != b["ticks"][i]:
					first = i
					break
			var batch: GSFpsMotorBatch = b["batch"]
			print("  %-28s rows %d in %d runs, %d retakes, %d stale, hull blocks %d, script gathers %d" % [
				label, batch.rows, batch.runs, batch.retakes, batch.stale, a["blocks"], a["script_gathers"]])
			_check(a["wired"] and b["wired"], label + ": the hull world and the batch are there")
			_check(first < 0, label + ": every one of %d ticks identical for every player%s" % [BATCH_TICKS, "" if first < 0 else " (first differs at tick %d)" % first])
			_check(a["counters"] == b["counters"], label + ": the same motor and hull counters" + _counter_diff(a["counters"], b["counters"]))
			_check(a["native_ticks"] == b["native_ticks"], label + ": as many native ticks (%d, batched %d)" % [a["native_ticks"], b["native_ticks"]])
			_check(a["script_gathers"] == b["script_gathers"], label + ": as many script gathers")
			_check(a["blocks"] > 0, label + ": the players do walk into each other")
			_check(batch.rows > BATCH_TICKS * 5 and batch.runs * 2 < batch.rows, label + ": most ticks ran in the batch, several a call")
			_check(batch.stale > 0 and batch.retakes > batch.stale, label + ": the push, the teleport and the death took rows back")
			var posts: Array = b["posts"]
			_check(posts[1] == 0 and posts[0] > BATCH_TICKS, label + ": post_row is each row's state after its motor (%d from the batch's answer, %d differ)" % [posts[0], posts[1]])
	_sections += 1


## The batch over 55-value rows ([member GSFpsMotorBatch.native_cols] off) is held to the loop as well, so both of its
## paths stay; where the library has [code]run_cols[/code] the default run went through it.
func _cols_check(a: Dictionary, rows: Dictionary, cols: Dictionary, label: String) -> void:
	var first := -1
	for i in range(BATCH_TICKS):
		if a["ticks"][i] != rows["ticks"][i]:
			first = i
			break
	_check(first < 0 and a["counters"] == rows["counters"], label + ": the batch over 55-value rows is identical too%s" % [
		"" if first < 0 else " (first differs at tick %d)" % first])
	var by_rows: GSFpsMotorBatch = rows["batch"]
	var by_cols: GSFpsMotorBatch = cols["batch"]
	_check(by_rows.cols_runs == 0, label + ": native_cols off hands gs-sim no columns")
	if ClassDB.class_has_method(GSFpsMotorBatch.NATIVE_CLASS, &"run_cols"):
		_check(by_cols.cols_runs == by_cols.runs and by_cols.runs > 0, label + ": every run handed gs-sim the states' columns (%d)" % by_cols.cols_runs)
	else:
		print("  %s: the library has no run_cols; the columns path was not run" % label)


## The columns batch with the rest stamps kept by the script ([member GSFpsMotorBatch.native_state] off) is held to
## the loop too; where the library has [code]run_states[/code] the default run kept them natively.
func _states_check(a: Dictionary, script_kept: Dictionary, native_kept: Dictionary, label: String) -> void:
	var first := -1
	for i in range(BATCH_TICKS):
		if a["ticks"][i] != script_kept["ticks"][i]:
			first = i
			break
	_check(first < 0 and a["counters"] == script_kept["counters"], label + ": native_state off is identical too%s" % [
		"" if first < 0 else " (first differs at tick %d)" % first])
	var off: GSFpsMotorBatch = script_kept["batch"]
	var on: GSFpsMotorBatch = native_kept["batch"]
	_check(off.state_runs == 0 and off.cols_runs > 0, label + ": native_state off keeps the stamps in the script")
	if ClassDB.class_has_method(GSFpsMotorBatch.NATIVE_CLASS, &"run_states"):
		_check(on.state_runs == on.runs and on.runs > 0, label + ": every run kept the rest stamps natively (%d)" % on.state_runs)
	else:
		print("  %s: the library has no run_states; the native stamp path was not run" % label)


## The batch's events ([member GSFpsMotorBatch.native_events]) are each row's changes exactly, and change nothing else:
## with them off the run is identical and no row says any. Where the library has none, no row says any either.
func _events_check(a: Dictionary, off: Dictionary, on: Dictionary, label: String) -> void:
	var first := -1
	for i in range(BATCH_TICKS):
		if a["ticks"][i] != off["ticks"][i]:
			first = i
			break
	_check(first < 0 and a["counters"] == off["counters"], label + ": native_events off is identical too%s" % [
		"" if first < 0 else " (first differs at tick %d)" % first])
	var ev: Array = on["events"]
	_check(off["events"][0] == 0, label + ": native_events off: no row says what changed")
	_check(ev[1] == 0, label + ": every row's events hold each change the controller's compare sees (%d of %d rows miss bits %d; said unchanged: %s)" % [
		ev[1], ev[0], ev[2], ev.slice(7)])
	var cols: GSFpsMotorBatch = on["batch"]
	if cols.state_runs > 0 and ev[0] == 0:
		print("  %s: the library says no events (a gs-sim batch without events); the script compared every row" % label)
	elif cols.state_runs > 0:
		_check(ev[0] * 2 > cols.rows and ev[3] > 0 and ev[4] > 0,
			label + ": most rows said what changed (%d of %d; mode %d, height %d, slide %d, wall run %d)" % [
				ev[0], cols.rows, ev[3], ev[4], ev[5], ev[6]])


func _run() -> void:
	print("gs-player-controller motor batch parity")
	var expected := 1
	if not GSFpsPhysicsBody.native_available() or not GSFpsMotorBatch.available() or not ClassDB.class_exists(&"GSSimHullWorld"):
		print("  gs-sim's motor batch is not loaded: skipped")
		if OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1" and not GSFpsPhysicsBody.native_available():
			_check(false, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
		expected = 0
	else:
		_build_world()
		await get_tree().physics_frame
		await get_tree().physics_frame
		_batch_runs()
	GSFpsMotorBatch.native_cols = true
	GSFpsMotorBatch.native_state = true
	GSFpsMotorBatch.native_events = true
	GSFpsPhysicsBody.native_enabled = true
	GSFpsMotor.native_tick = false
	GSFpsMotor.native_full = true
	print("%d passed, %d failed" % [_passed, _failed])
	print("%d of %d sections ran to their last line" % [_sections, expected])
	get_tree().quit(1 if _failed > 0 or _sections != expected else 0)
