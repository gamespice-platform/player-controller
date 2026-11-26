extends Node

## Holds [method GSFpsNetSync.pull]'s native pack (gs-sim's [code]GSSimFpsNetPack[/code]) to the script packers, to the bit: random and edge states (negative and huge timers, half-code boundaries, wall runs, spent runs, the heading's sign bit, odd stamina) pulled at several tick rates onto a full carrier and one without stamina, once each way, every replicated field compared. Then the cost of a pull each way. With no library it says so and passes; [code]GS_SIM_REQUIRE_NATIVE=1[/code] (CI) fails instead. Run: [code]godot --headless --path . res://examples/net_pack_parity.tscn[/code]

const STATES := 4000
const RATES := [20, 22, 33, 64, 66, 128]
const BENCH_PULLS := 20000
## The timer and cooldown columns (time since jump to wall-run time).
const TIMER_COLS := [14, 15, 16, 17, 18, 19, 20, 21, 22]
## Integer columns: mode, previous buttons, wall-run spent, wall-jump count, jumps in air, heading.
const INT_COLS := [9, 13, 23, 24, 25, 26]


class Carrier:
	var net_position: Vector3
	var net_velocity: Vector3
	var net_yaw: float
	var net_pitch: float
	var net_crouch: float
	var net_flags: int
	var net_modifiers: int
	var net_timers: int
	var net_timers2: int
	var net_stamina: int


class NoStamina:
	var net_position: Vector3
	var net_velocity: Vector3
	var net_yaw: float
	var net_pitch: float
	var net_crouch: float
	var net_flags: int
	var net_modifiers: int
	var net_timers: int
	var net_timers2: int


var _passed := 0
var _failed := 0


func _ready() -> void:
	print("gs-player-controller net pack parity")
	var had_scale := GSFpsNetSync.timer_scale
	if GSFpsNetSync._native_packer() == null:
		print("  gs-sim's net_pack module is not loaded: the native half is skipped")
		if OS.get_environment("GS_SIM_REQUIRE_NATIVE") == "1":
			_check(false, "the library is loaded (GS_SIM_REQUIRE_NATIVE=1)")
	else:
		_parity()
		_bench()
	GSFpsNetSync.native_pack = true
	GSFpsNetSync.timer_scale = had_scale
	print("%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL: ", msg)


## A timer value: plain random, on a code, half a code off one, negative, or past every field.
func _timer(rng: RandomNumberGenerator, scale: float) -> float:
	match rng.randi_range(0, 6):
		0: return -rng.randf_range(0.0, 3.0)
		1: return float(rng.randi_range(0, 200)) / scale
		2: return (float(rng.randi_range(0, 200)) + 0.5) / scale
		3: return (float(rng.randi_range(0, 16400)) + 0.5) / GSFpsNetSync.JUMP_TIMER_SCALE
		4: return rng.randf_range(10.0, 2000.0)
		5: return -1.0
	return rng.randf_range(0.0, 3.0)


func _random_state(rng: RandomNumberGenerator, scale: float) -> GSFpsState:
	var s := GSFpsState.new()
	for k in range(9):
		s._f[k] = rng.randf_range(-500.0, 500.0)
	s._f[12] = rng.randf_range(-720.0, 720.0)
	for k: int in TIMER_COLS:
		s._f[k] = _timer(rng, scale)
	for k: int in INT_COLS:
		s._f[k] = float(rng.randi_range(-3, 20 if k != 13 else 600))
	s.pitch = rng.randf_range(-89.0, 89.0)
	s.crouch_fraction = rng.randf()
	s.crouch_held = rng.randi() % 2 == 0
	s.stamina = rng.randf_range(-0.2, 1.2)
	s.stamina_exhausted = rng.randi() % 2 == 0
	s.stamina_delay_left = rng.randf_range(-1.0, 5.0) if rng.randi() % 4 != 0 else (float(rng.randi_range(0, 8200)) + 0.5) / 2048.0
	if rng.randi() % 3 == 0:
		s.modifiers.append(Vector2i(rng.randi_range(0, GSFpsNetSync.MODIFIER_BITS - 1), -1))
	return s


func _wire(c: Object) -> PackedByteArray:
	return var_to_bytes([c.net_position, c.net_velocity, c.net_yaw, c.net_pitch, c.net_crouch, c.net_flags,
		c.net_modifiers, c.net_timers, c.net_timers2, c.get(&"net_stamina")])


func _pulled(s: GSFpsState, native: bool, carrier: Object) -> PackedByteArray:
	GSFpsNetSync.native_pack = native
	GSFpsNetSync.pull(s, carrier)
	return _wire(carrier)


func _parity() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 2026_11_26
	var mismatches := 0
	var negative_flags := 0
	for rate: int in RATES:
		GSFpsNetSync.set_tick_rate(rate)
		for i in range(STATES):
			var s := GSFpsState.new() if i == 0 else _random_state(rng, GSFpsNetSync.timer_scale)
			var full := _pulled(s, false, Carrier.new()) == _pulled(s, true, Carrier.new())
			var part := _pulled(s, false, NoStamina.new()) == _pulled(s, true, NoStamina.new())
			if not (full and part):
				mismatches += 1
				if mismatches <= 5:
					print("  mismatch at rate %d state %d: %s" % [rate, i, s._f])
			var c := Carrier.new()
			GSFpsNetSync.pull(s, c)
			negative_flags += 1 if c.net_flags < 0 else 0
	_check(mismatches == 0, "every pull is identical both ways (%d of %d differ)" % [mismatches, STATES * RATES.size()])
	_check(negative_flags > 0, "the heading's sign bit was exercised")
	print("  %d states at %d rates, %d with the sign bit" % [STATES, RATES.size(), negative_flags])


func _bench() -> void:
	GSFpsNetSync.set_tick_rate(66)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var s := _random_state(rng, GSFpsNetSync.timer_scale)
	var c := Carrier.new()
	var us := []
	for native: bool in [false, true]:
		GSFpsNetSync.native_pack = native
		var t0 := Time.get_ticks_usec()
		for i in range(BENCH_PULLS):
			GSFpsNetSync.pull(s, c)
		us.append(float(Time.get_ticks_usec() - t0) / BENCH_PULLS)
	print("  pull: script %.2f us, native %.2f us" % us)
