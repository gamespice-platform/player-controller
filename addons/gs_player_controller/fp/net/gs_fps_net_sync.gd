class_name GSFpsNetSync
extends RefCounted

## What a networked player has to replicate, and how to get it in and out of a [GSFpsState].
## GameSpice Net is not a dependency and is not imported here: a script that mentions a missing `class_name` fails to parse, so the thin `GSNetBehaviour` that joins the two lives in the host game.
##
## [codeblock]
## class_name PlayerNet extends GSNetBehaviour
##
## @export var controller: GSFpsController
##
## var net_position: Vector3
## var net_velocity: Vector3
## var net_yaw: float
## var net_pitch: float
## var net_crouch: float
## var net_flags: int
## var net_modifiers: int
##
## func _register_net_vars() -> void:
##     for spec in GSFpsNetSync.state_specs():
##         var declaration := replicate(spec.property, GSNetVar.Type[spec.type])
##         if spec.bits > 0:
##             declaration.bits(spec.bits)
##         if spec.interpolated:
##             declaration.interpolated()
##
## func _net_apply_input(input: GSNetInput, _tick: int) -> void:
##     controller.apply_command((input as PlayerInput).command)
##
## func _net_simulate(tick: int, delta: float) -> void:
##     controller.simulate_tick(tick, delta)
##     GSFpsNetSync.pull(controller.state, self)
##
## func _net_state_applied(_tick: int) -> void:
##     GSFpsNetSync.push(self, controller.state)
## [/codeblock]
##
## The full worked example is in docs/networking.md.

## Bits the movement mode occupies in the packed flags. See [method pack_flags].
## Wide enough for [constant GSFpsState.MAX_MODES]: the id travels, so a mode that did not fit would arrive as a different one.
const MODE_BITS := 4
const MODE_MASK := (1 << MODE_BITS) - 1

## Crouch is held, in the bit above the mode.
const FLAG_CROUCH_HELD := 1 << MODE_BITS

## The slide and launch timers, packed above the crouch bit, in sixty-fourths of a second.
## Replicated, unlike the jump timers: a rewind keeps the client's current cooldown, so a snapshot from before a predicted launch replayed the press with the cooldown running and refused it (3.2 m of drift measured).
## In the flags word, not a new property, so no game's net behaviour needs a new var.
const TIMER_SCALE := 64.0

## The highest tick rate whose ticks are the wire's unit: 125 codes of the wall-run field are 1.89 s at 66 Hz.
const EXACT_RATE_LIMIT := 66

## The scale in use: the tick rate up to [constant EXACT_RATE_LIMIT], so a timer counted a tick at a time round-trips exactly (the client rewinds to a decoded value and must land where the server is), and [constant TIMER_SCALE] above it, where the 7-bit fields could not hold their documented range. Set by [method set_tick_rate] (the simulator and the controller do), one value per process.
static var timer_scale: float = TIMER_SCALE
const LAUNCH_BITS := 12
const SLIDE_BITS := 7
const SLIDE_COOLDOWN_BITS := 7

## A slide_time of this many sixty-fourths means "not sliding".
const NOT_SLIDING := (1 << SLIDE_BITS) - 1

const LAUNCH_SHIFT := MODE_BITS + 1
const SLIDE_SHIFT := LAUNCH_SHIFT + LAUNCH_BITS
const SLIDE_COOLDOWN_SHIFT := SLIDE_SHIFT + SLIDE_BITS

## The buttons of the command the snapshot's tick applied, which every press is detected against ([member GSFpsState.previous_buttons]).
## Without it a rewind kept the current held buttons and the replayed press saw no edge.
const BUTTONS_SHIFT := SLIDE_COOLDOWN_SHIFT + SLIDE_COOLDOWN_BITS

## The dash's cooldown, the launch's reason and width.
const DASH_BITS := 12
const DASH_SHIFT := BUTTONS_SHIFT + GSFpsCommand.BUTTON_BITS

## The wall run and wall jump, the last fields in the word, so an older encoding reads as "not running, no wall jumps".
## The run field is one number: 0 ready, 1 spent this airborne stretch ([member GSFpsState.wall_run_spent]), 2 and up a run in progress (sixty-fourths plus two); 125 is the longest it holds ([constant GSFpsTunables.WALL_RUN_TIME_LIMIT]).
## The heading names the wall the per-wall counter counts, in eighths of a turn. The two jump counters share three bits: only seven pairs can occur, (0,0) (1,1) (2,1) (2,2) (3,1) (3,2) (3,3).
const WALL_RUN_BITS := 7
const WALL_RUN_READY := 0
const WALL_RUN_SPENT := 1
const WALL_RUN_FIRST_TIME := 2
const WALL_JUMP_COUNT_BITS := 3
const WALL_HEADING_BITS := 3

const WALL_RUN_SHIFT := DASH_SHIFT + DASH_BITS
const WALL_JUMP_COUNT_SHIFT := WALL_RUN_SHIFT + WALL_RUN_BITS
const WALL_HEADING_SHIFT := WALL_JUMP_COUNT_SHIFT + WALL_JUMP_COUNT_BITS

## 64: the word is full. GameSpice Net's UINT takes up to 64 bits, and the top field's high
## bit makes the int negative in GDScript, which every read here masks off. A field
## after this one needs a second property, not a wider word.
const FLAG_BITS := WALL_HEADING_SHIFT + WALL_HEADING_BITS

## Most modifiers a motor can register, and the width of the replicated mask (GameSpice Net's UINT takes up to 64).
const MODIFIER_BITS := 48


## What a networked player replicates.
## Types are named, not referenced, so this file never mentions [code]GSNetVar[/code]; a bridge resolves them with [code]GSNetVar.Type[spec.type][/code].
## Velocity is not redundant: it lets a receiver curve the path, extrapolate a late packet and place a late joiner without a stutter.
static func state_specs() -> Array[Dictionary]:
	return [
		{
			"property": &"net_position",
			"type": "VECTOR3_POSITION",
			"bits": 0,
			"interpolated": true,
			"source": "position",
		},
		{
			"property": &"net_velocity",
			"type": "VECTOR3_VELOCITY",
			"bits": 0,
			"interpolated": false,
			"source": "velocity",
		},
		{
			# 12 bits over 360° is about 0.09°, the same precision the command
			# carries. Replicating the view more precisely than it was sent is
			# paying for accuracy that was never there.
			"property": &"net_yaw",
			"type": "ANGLE",
			"bits": 12,
			"interpolated": true,
			"source": "yaw",
		},
		{
			"property": &"net_pitch",
			"type": "ANGLE",
			"bits": 9,
			"interpolated": true,
			"source": "pitch",
		},
		{
			# 6 bits over 0..1 is ~1.5% of the stand-to-crouch travel, well below
			# what is visible on a transition that takes a tenth of a second.
			"property": &"net_crouch",
			"type": "FLOAT_RANGE",
			"bits": 6,
			"interpolated": true,
			"source": "crouch_fraction",
		},
		{
			"property": &"net_flags",
			"type": "UINT",
			"bits": FLAG_BITS,
			"interpolated": false,
			"source": "flags",
		},
		{
			# A mask of active modifier indices: the definitions are configuration both machines hold, so only membership travels.
			# The expiry tick does not travel, so the client may hold a modifier up to one snapshot interval (50 ms at the default rate) past its end; the effect while active is predicted exactly.
			"property": &"net_modifiers",
			"type": "UINT",
			"bits": MODIFIER_BITS,
			"interpolated": false,
			"source": "modifiers",
		},
	]


## Bits one full state update costs, before GameSpice Net's own framing.
static func estimated_state_bits() -> int:
	# position 3x16 + velocity 3x12 + yaw 12 + pitch 9 + crouch 6 + flags (mode, crouch,
	# the slide, launch and dash timers, buttons, the wall run and wall jumps) + modifiers
	return 48 + 36 + 12 + 9 + 6 + FLAG_BITS + MODIFIER_BITS


static func pack_flags(state: GSFpsState) -> int:
	var flags := state.mode & MODE_MASK

	if state.crouch_held:
		flags |= FLAG_CROUCH_HELD

	flags |= _quantise(state.launch_cooldown_left, LAUNCH_BITS) << LAUNCH_SHIFT
	var slide := NOT_SLIDING if not state.is_sliding() else mini(
		_quantise(state.slide_time, SLIDE_BITS), NOT_SLIDING - 1
	)
	flags |= slide << SLIDE_SHIFT
	flags |= _quantise(state.slide_cooldown_left, SLIDE_COOLDOWN_BITS) << SLIDE_COOLDOWN_SHIFT
	flags |= (state.previous_buttons & ((1 << GSFpsCommand.BUTTON_BITS) - 1)) << BUTTONS_SHIFT
	flags |= _quantise(state.dash_cooldown_left, DASH_BITS) << DASH_SHIFT

	var wall_run := WALL_RUN_READY
	if state.is_wall_running():
		wall_run = WALL_RUN_FIRST_TIME + mini(
			_quantise(state.wall_run_time, WALL_RUN_BITS),
			(1 << WALL_RUN_BITS) - 1 - WALL_RUN_FIRST_TIME
		)
	elif state.wall_run_spent:
		wall_run = WALL_RUN_SPENT
	flags |= wall_run << WALL_RUN_SHIFT
	flags |= wall_jump_code(state.wall_jumps_in_air, state.wall_jump_count) << WALL_JUMP_COUNT_SHIFT
	flags |= (state.wall_jump_heading & ((1 << WALL_HEADING_BITS) - 1)) << WALL_HEADING_SHIFT

	return flags


## Derives [member timer_scale] from the simulation's tick rate. Both ends must run the same rate.
static func set_tick_rate(rate: int) -> void:
	timer_scale = float(maxi(rate, 1)) if rate <= EXACT_RATE_LIMIT else TIMER_SCALE


static func unpack_flags(state: GSFpsState, flags: int) -> void:
	state.crouch_held = (flags & FLAG_CROUCH_HELD) != 0
	state.mode = flags & MODE_MASK

	state.launch_cooldown_left = _field(flags, LAUNCH_SHIFT, LAUNCH_BITS) / timer_scale
	var slide := _field(flags, SLIDE_SHIFT, SLIDE_BITS)
	state.slide_time = -1.0 if slide == NOT_SLIDING else slide / timer_scale
	state.slide_cooldown_left = (
		_field(flags, SLIDE_COOLDOWN_SHIFT, SLIDE_COOLDOWN_BITS) / timer_scale
	)
	state.previous_buttons = (flags >> BUTTONS_SHIFT) & ((1 << GSFpsCommand.BUTTON_BITS) - 1)
	state.dash_cooldown_left = _field(flags, DASH_SHIFT, DASH_BITS) / timer_scale

	var wall_run := int(_field(flags, WALL_RUN_SHIFT, WALL_RUN_BITS))
	state.wall_run_time = (
		(wall_run - WALL_RUN_FIRST_TIME) / timer_scale if wall_run >= WALL_RUN_FIRST_TIME
		else -1.0
	)
	state.wall_run_spent = wall_run == WALL_RUN_SPENT
	var counts := wall_jump_counts(int(_field(flags, WALL_JUMP_COUNT_SHIFT, WALL_JUMP_COUNT_BITS)))
	state.wall_jumps_in_air = counts.x
	state.wall_jump_count = counts.y
	state.wall_jump_heading = int(_field(flags, WALL_HEADING_SHIFT, WALL_HEADING_BITS))


## The airborne total and the per-wall count of wall jumps as one number, 0..6. See
## [constant WALL_RUN_BITS] for why they share a field.
static func wall_jump_code(in_air: int, same_wall: int) -> int:
	var total := clampi(in_air, 0, 3)
	if total == 0:
		return 0
	return ((total * (total - 1)) >> 1) + clampi(same_wall, 1, total)


## [method wall_jump_code] undone: (airborne total, per-wall count).
static func wall_jump_counts(code: int) -> Vector2i:
	for total in range(1, 4):
		var first := ((total * (total - 1)) >> 1) + 1
		if code >= first and code < first + total:
			return Vector2i(total, code - first + 1)
	return Vector2i.ZERO


## Seconds as sixty-fourths, clamped into [param bits]. A cooldown longer than the field
## holds is sent as the longest it can say: the client may then predict an ability a few
## ticks early, and the next snapshot takes it back.
static func _quantise(seconds: float, bits: int) -> int:
	return clampi(roundi(maxf(seconds, 0.0) * timer_scale), 0, (1 << bits) - 1)


static func _field(flags: int, shift: int, bits: int) -> float:
	return float((flags >> shift) & ((1 << bits) - 1))


## The active modifier set as a bit per registered index.
static func pack_modifiers(state: GSFpsState) -> int:
	var mask := 0

	for entry in state.modifiers:
		if entry.x >= 0 and entry.x < MODIFIER_BITS:
			mask |= 1 << entry.x

	return mask


## Rebuilds the active set from a mask, preserving order.
## Expiries come back as "until removed" because they were not sent; see [code]net_modifiers[/code] in [method state_specs].
static func unpack_modifiers(state: GSFpsState, mask: int) -> void:
	state.modifiers.clear()

	# Ascending, which is the order GSFpsState.modifiers is required to be in — the
	# aggregate is a product, and floating-point multiplication is not associative.
	for index in range(MODIFIER_BITS):
		if mask & (1 << index):
			state.modifiers.append(Vector2i(index, -1))


## Copies a state onto a replicating object, ready to be sent.
## [param target] is a [Variant] because it is a [code]GSNetBehaviour[/code] in practice and this file cannot name it.
static func pull(state: GSFpsState, target: Variant) -> void:
	var has := _carrier_has(target)
	if has & _HAS_CORE and native_pack and _native_packer() != null:
		_pull_native(state, target, has)
		return
	elif has & _HAS_CORE:
		target.net_position = state.position
		target.net_velocity = state.velocity
		target.net_yaw = state.yaw
		target.net_pitch = state.pitch
		target.net_crouch = state.crouch_fraction
		target.net_flags = pack_flags(state)
		target.net_modifiers = pack_modifiers(state)
	else:
		_pull_partial(state, target as Object)
	if has & _HAS_TIMERS:
		target.net_timers = pack_timers(state)
	if has & _HAS_TIMERS2:
		target.net_timers2 = pack_timers2(state)
	if has & _HAS_STAMINA:
		target.net_stamina = pack_stamina(state)


## [method pull] packs the flags, timers and stamina in one GameSpice Sim call ([code]GSSimFpsNetPack[/code]) when the library is loaded, and [method push_core] unpacks them the same way: the same integers and columns as the script, which stays the specification (examples/net_pack_parity holds the two together). False keeps the script both ways.
static var native_pack := true
static var _packer: Object = null
static var _packer_tried := false
const _NATIVE_PACKER := &"GSSimFpsNetPack"


static func _native_packer() -> Object:
	if not _packer_tried:
		_packer_tried = true
		if ClassDB.class_exists(_NATIVE_PACKER):
			_packer = ClassDB.instantiate(_NATIVE_PACKER)
	return _packer


static var _unpacker_ok := -1


## Whether the loaded GSSimFpsNetPack has the receiving half (gs-sim 0.2.31 and later).
static func _native_unpacker() -> bool:
	if _unpacker_ok < 0:
		var packer := _native_packer()
		_unpacker_ok = 1 if packer != null and packer.has_method(&"unpack") else 0
	return _unpacker_ok == 1


static var _exact_ok := -1


## Whether the native packer also has [code]unpack_exact[/code] (push_core with an exact record in one call).
static func _native_exact() -> bool:
	if _exact_ok < 0:
		_exact_ok = 1 if _native_unpacker() and _packer.has_method(&"unpack_exact") else 0
	return _exact_ok == 1


static func _pull_native(state: GSFpsState, target: Variant, has: int) -> void:
	var f := state._f
	var codes: PackedInt64Array = _packer.pack(f, state.crouch_held, timer_scale,
		state.stamina, state.stamina_exhausted, state.stamina_delay_left)
	target.net_position = Vector3(f[0], f[1], f[2])
	target.net_velocity = Vector3(f[3], f[4], f[5])
	target.net_yaw = f[12]
	target.net_pitch = state.pitch
	target.net_crouch = state.crouch_fraction
	target.net_flags = codes[0]
	target.net_modifiers = pack_modifiers(state) if not state.modifiers.is_empty() else 0
	if has & _HAS_TIMERS:
		target.net_timers = codes[1]
	if has & _HAS_TIMERS2:
		target.net_timers2 = codes[2]
	if has & _HAS_STAMINA:
		target.net_stamina = codes[3]


const _HAS_CORE := 1
const _HAS_TIMERS := 2
const _HAS_TIMERS2 := 4
const _HAS_STAMINA := 8
const _CORE: Array[StringName] = [&"net_position", &"net_velocity", &"net_yaw", &"net_pitch", &"net_crouch", &"net_flags", &"net_modifiers"]
## The core seven, then the optional three, in the order [method _push_partial] reads them.
const _ALL: Array[StringName] = [&"net_position", &"net_velocity", &"net_yaw", &"net_pitch", &"net_crouch", &"net_flags",
	&"net_modifiers", &"net_timers", &"net_timers2", &"net_stamina"]


## [method pull] onto a carrier without all seven core values: [method Object.set] skips the missing ones, where
## an assignment would stop the script. Cold: every real carrier declares them and takes the typed path.
static func _pull_partial(state: GSFpsState, target: Object) -> void:
	for i in _CORE.size():
		target.set(_CORE[i], _pull_value(state, i))  # perf-lint: allow dynamic_call a partial carrier, which declares no typed fields to write


static func _pull_value(state: GSFpsState, index: int) -> Variant:
	match index:
		0: return state.position
		1: return state.velocity
		2: return state.yaw
		3: return state.pitch
		4: return state.crouch_fraction
		5: return pack_flags(state)
	return pack_modifiers(state)

## Which net_* a carrier's script declares (_HAS_*), by script. [method pull] runs per player per tick on a server, and
## `in` for a property the carrier lacks walks its scripts and every engine class above them, three times a pull.
## Main-thread use only, like the carrier itself. A script with a _get answers per instance, so it is asked each time.
static var _carriers: Dictionary = {}


static func _carrier_has(target: Variant) -> int:
	var script: Variant = (target as Object).get_script() if target is Object else null
	if script != null:
		var hit: Variant = _carriers.get(script)
		if hit != null:
			return hit
	var has := _HAS_CORE
	for property in _CORE:
		if not property in target:
			has = 0
			break
	if &"net_timers" in target:
		has |= _HAS_TIMERS
	if &"net_timers2" in target:
		has |= _HAS_TIMERS2
	if &"net_stamina" in target:
		has |= _HAS_STAMINA
	if script != null and not (target as Object).has_method(&"_get"):
		_carriers[script] = has
	return has


## The jump timers (coyote, jump buffer, cooldown) in 1/7680 s, which is a whole number of
## codes per tick at 20 to 128 Hz. Code 0 is "longer than the field holds" (restored as 1000 s).
const JUMP_TIMER_SCALE := 7680.0
const JUMP_TIMER_BITS := 14
const TIMERS_BITS := 4 * JUMP_TIMER_BITS


## The owner-only property a predicting client rewinds the jump timers from. Opt in by
## declaring [code]var net_timers: int[/code] and replicating these; [method pull] and
## [method push] then carry it. See docs/networking.md, "The jump timers".
static func rewind_specs() -> Array[Dictionary]:
	return [{"property": &"net_timers", "type": "UINT", "bits": TIMERS_BITS,
		"interpolated": false, "owner_only": true, "source": "jump timers"}]


## Owner-only stamina for a predicting client's rewind: opt in with [code]var net_stamina: int[/code]
## and replicate [method stamina_specs]. 14 bits of stamina, 1 exhausted, 13 of the refill delay (1/2048 s).
## Coarser steps made a rewound client decide a sprint or an exhaustion a tick away from the server.
const STAMINA_BITS := 28


static func stamina_specs() -> Array[Dictionary]:
	return [{"property": &"net_stamina", "type": "UINT", "bits": STAMINA_BITS,
		"interpolated": false, "owner_only": true, "source": "stamina"}]


static func pack_stamina(state: GSFpsState) -> int:
	return (roundi(clampf(state.stamina, 0.0, 1.0) * 16383.0)
		| (1 if state.stamina_exhausted else 0) << 14
		| clampi(roundi(state.stamina_delay_left * 2048.0), 0, 8191) << 15)


## Puts the state's stamina on the wire grid, so a state rewound from net_stamina is identical to the
## server's rather than close, which flips a sprint or exhaustion at the boundary.
static func snap_stamina(state: GSFpsState) -> void:
	unpack_stamina(state, pack_stamina(state))


static func unpack_stamina(state: GSFpsState, code: int) -> void:
	state.stamina = float(code & 16383) / 16383.0
	state.stamina_exhausted = (code >> 14) & 1 == 1
	state.stamina_delay_left = float((code >> 15) & 8191) / 2048.0


static func pack_timers(state: GSFpsState) -> int:
	return (_timer_code(state.time_since_grounded)
		| _timer_code(state.time_since_jump) << JUMP_TIMER_BITS
		| _timer_code(state.time_since_jump_pressed) << (2 * JUMP_TIMER_BITS)
		| _timer_code(state.wall_run_cooldown_left) << (3 * JUMP_TIMER_BITS))


static func unpack_timers(state: GSFpsState, code: int) -> void:
	state.time_since_grounded = _timer_value(code)
	state.time_since_jump = _timer_value(code >> JUMP_TIMER_BITS)
	state.time_since_jump_pressed = _timer_value(code >> (2 * JUMP_TIMER_BITS))
	# 1000 s is the field's "longer than it holds"; a cooldown that long is never set.
	state.wall_run_cooldown_left = minf(_timer_value(code >> (3 * JUMP_TIMER_BITS)), 10.0) if code >> (3 * JUMP_TIMER_BITS) != 0 else 0.0


## The slide time, the slide cooldown and the wall-run time in 1/7680 s, 14 bits each (up to 2.13 s), for a game that runs above [constant EXACT_RATE_LIMIT], where the coarse fields of net_flags are in sixty-fourths and a rewind lands up to half a code off. Opt in with [code]var net_timers2: int[/code] and replicate [method rewind_specs2]; [method pull] writes it and [method push] prefers it over the flags fields. Slide time: 0 not sliding, n+1 else. Wall run: 0 ready, 1 spent, n+2 running.
const TIMERS2_BITS := 3 * JUMP_TIMER_BITS
const _T2_MAX := (1 << JUMP_TIMER_BITS) - 1


static func rewind_specs2() -> Array[Dictionary]:
	return [{"property": &"net_timers2", "type": "UINT", "bits": TIMERS2_BITS,
		"interpolated": false, "owner_only": true, "source": "slide and wall-run timers"}]


static func pack_timers2(state: GSFpsState) -> int:
	var slide := 0
	if state.slide_time >= 0.0:
		slide = mini(roundi(state.slide_time * JUMP_TIMER_SCALE) + 1, _T2_MAX)
	var cooldown := mini(roundi(maxf(state.slide_cooldown_left, 0.0) * JUMP_TIMER_SCALE), _T2_MAX)
	var run := WALL_RUN_READY
	if state.wall_run_time >= 0.0:
		run = mini(roundi(state.wall_run_time * JUMP_TIMER_SCALE) + WALL_RUN_FIRST_TIME, _T2_MAX)
	elif state.wall_run_spent:
		run = WALL_RUN_SPENT
	return slide | cooldown << JUMP_TIMER_BITS | run << (2 * JUMP_TIMER_BITS)


static func unpack_timers2(state: GSFpsState, code: int) -> void:
	var slide := code & _T2_MAX
	state.slide_time = -1.0 if slide == 0 else float(slide - 1) / JUMP_TIMER_SCALE
	state.slide_cooldown_left = float((code >> JUMP_TIMER_BITS) & _T2_MAX) / JUMP_TIMER_SCALE
	var run := (code >> (2 * JUMP_TIMER_BITS)) & _T2_MAX
	state.wall_run_time = (
		float(run - WALL_RUN_FIRST_TIME) / JUMP_TIMER_SCALE if run >= WALL_RUN_FIRST_TIME else -1.0
	)
	state.wall_run_spent = run == WALL_RUN_SPENT


static func _timer_code(seconds: float) -> int:
	var n := roundi(maxf(seconds, 0.0) * JUMP_TIMER_SCALE)
	return 0 if n >= (1 << JUMP_TIMER_BITS) - 2 else n + 1


static func _timer_value(code: int) -> float:
	var c := code & ((1 << JUMP_TIMER_BITS) - 1)
	return 1000.0 if c == 0 else float(c - 1) / JUMP_TIMER_SCALE


## Copies received values back into a state; on a predicting client this is the rewind half of reconciliation.
## Everything the simulation reads must be restored here, or the replay starts from a state the server never computed.
static func push(source: Variant, state: GSFpsState) -> void:
	var has := _carrier_has(source)
	if has & _HAS_CORE:
		# Declared properties read directly: this runs per remote player per snapshot and per render frame.
		push_core(state, source.net_position, source.net_velocity, source.net_yaw, int(source.net_flags),
			int(source.net_timers2) if has & _HAS_TIMERS2 else -1)
		state.pitch = source.net_pitch
		state.crouch_fraction = source.net_crouch
		var mask := int(source.net_modifiers)
		# unpack_modifiers clears and refills: with nothing to add to an empty list it has nothing to do.
		if mask != 0 or not state.modifiers.is_empty():
			unpack_modifiers(state, mask)
		if has & _HAS_TIMERS:
			unpack_timers(state, int(source.net_timers))
		if has & _HAS_STAMINA:
			unpack_stamina(state, int(source.net_stamina))
		return
	_push_partial(source as Object, state)


## [method push] from a carrier without all seven core values (a test double, an old game's own node): read by
## name, in [constant _ALL] order. Cold: every real carrier declares them and takes the typed path.
static func _push_partial(source: Object, state: GSFpsState) -> void:
	for i in _ALL.size():
		_push_value(state, i, source.get(_ALL[i]))  # perf-lint: allow dynamic_call a partial carrier, which declares no typed fields to read


static func _push_value(state: GSFpsState, index: int, value: Variant) -> void:
	match index:
		0: state.position = value
		1: state.velocity = value
		2: state.yaw = value
		3: state.pitch = value
		4: state.crouch_fraction = value
		5: unpack_flags(state, int(value))
		6: unpack_modifiers(state, int(value))
		7:
			if value != null:
				unpack_timers(state, int(value))
		8:
			if value != null:
				unpack_timers2(state, int(value))
		9:
			if value != null:
				unpack_stamina(state, int(value))



## The column half of [method push]: [param position], [param velocity] and [param yaw] written, [param flags]
## unpacked ([method unpack_flags]), then [param timers2] when it is not negative ([method unpack_timers2], which
## overrides the coarse slide and wall-run fields), then [param exact] when it is an [constant EXACT_FLOATS] long
## record ([method push_exact], which overrides the quantised position, velocity and timers). With
## [member native_pack] and a GameSpice Sim whose [code]GSSimFpsNetPack[/code] has [code]unpack[/code]
## ([code]unpack_exact[/code] for a record), one native call writes the columns; the script writes stay the
## specification (examples/net_pack_parity holds the two together). A carrier with its own push (Fatal
## Contact's) calls this for the same writes.
static func push_core(state: GSFpsState, position: Vector3, velocity: Vector3, yaw: float, flags: int,
		timers2: int = -1, exact: PackedFloat32Array = PackedFloat32Array()) -> void:
	var has_exact := exact.size() == EXACT_FLOATS
	if native_pack and _native_unpacker():
		if has_exact and _native_exact():
			state._f = _packer.unpack_exact(state._f, position, velocity, yaw, flags, timers2, timer_scale, exact)
			_push_exact_fields(state, exact)
		else:
			state._f = _packer.unpack(state._f, position, velocity, yaw, flags, timers2, timer_scale)
			if has_exact:
				push_exact(state, exact)
		state.batch_dirty = true
		state.crouch_held = (flags & FLAG_CROUCH_HELD) != 0
		return
	state.position = position
	state.velocity = velocity
	state.yaw = yaw
	unpack_flags(state, flags)
	if timers2 >= 0:
		unpack_timers2(state, timers2)
	if has_exact:
		push_exact(state, exact)


## Floats in an exact movement record: position (3), velocity (3), crouch fraction, time since grounded, time
## since jump, time since jump pressed, wall-run cooldown, stamina, stamina exhausted (above 0.5), stamina delay.
## A carrier that sends its owner an unquantised copy to rewind from (Fatal Contact's [code]net_exact[/code])
## lays it out this way.
const EXACT_FLOATS := 14


## Writes an exact movement record ([constant EXACT_FLOATS] long) over [param state]; false, writing nothing,
## for a record of another length.
static func push_exact(state: GSFpsState, exact: PackedFloat32Array) -> bool:
	if exact.size() != EXACT_FLOATS:
		return false
	state.position = Vector3(exact[0], exact[1], exact[2])
	state.velocity = Vector3(exact[3], exact[4], exact[5])
	state.time_since_grounded = exact[7]
	state.time_since_jump = exact[8]
	state.time_since_jump_pressed = exact[9]
	state.wall_run_cooldown_left = exact[10]
	_push_exact_fields(state, exact)
	return true


## The record's values outside the columns.
static func _push_exact_fields(state: GSFpsState, exact: PackedFloat32Array) -> void:
	state.crouch_fraction = exact[6]
	state.stamina = exact[11]
	state.stamina_exhausted = exact[12] > 0.5
	state.stamina_delay_left = exact[13]


## Whether two peers will simulate the same way.
## Call it at connect time: differing tunables show up as small constant corrections, indistinguishable from packet loss.
static func agrees(mine: GSFpsTunables, theirs_fingerprint: String) -> bool:
	return mine != null and mine.fingerprint() == theirs_fingerprint


## Explains a fingerprint mismatch by naming the properties that differ.
static func differences(
	mine: GSFpsTunables,
	theirs: GSFpsTunables
) -> PackedStringArray:
	var out := PackedStringArray()

	if mine == null or theirs == null:
		out.append("one side has no tunables at all")
		return out

	for key in mine.config_keys():
		if key.begins_with("mouse_") or key == "invert_look_y":
			continue

		var a: Variant = mine.get(key)
		var b: Variant = theirs.get(key)

		if a != b:
			out.append("%s: mine %s, theirs %s" % [key, str(a), str(b)])

	return out
