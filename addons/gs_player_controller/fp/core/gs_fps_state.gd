class_name GSFpsState
extends RefCounted

## Everything the movement simulation carries from one tick to the next.
## A separate object so prediction can capture, restore and compare it: a field left on the node is not rewound, and the replay diverges only under latency.
## Rule: if the simulation reads it, it lives here.

## The built-in movement modes. [member mode] is an [code]int[/code] so [method GSFpsMotor.register_mode] can hand out ids above these for a game's own modes.
enum Mode {
	GROUND,
	AIR,
	NOCLIP,
}

## The first id [method GSFpsMotor.register_mode] hands out.
const FIRST_CUSTOM_MODE := 3

## Most modes one motor can have; the mode travels as a fixed-width field (see [GSFpsNetSync]).
const MAX_MODES := 16

## The columns layout by path, not by its global name, so a run whose class cache predates it still parses.
const _Cols := preload("gs_fps_state_columns.gd")

## The values the motor tick reads and writes, packed: [constant GSFpsStateColumns.STRIDE] float64s in
## [GSFpsStateColumns]' layout (API 36), so GameSpice Sim can take them as one array per player instead of a property
## read per field. The properties below that index it are accessors (the numbers are the layout's offsets, written out
## because a literal index is the cheapest read there is). [method copy_from] replaces it rather than writing through.
var _f := PackedFloat64Array(_Cols.DEFAULTS)

var mode: int:
	get: return int(_f[9])
	set(v): _f[9] = v

var position: Vector3:
	get: return Vector3(_f[0], _f[1], _f[2])
	set(v): _f[0] = v.x; _f[1] = v.y; _f[2] = v.z
var velocity: Vector3:
	get: return Vector3(_f[3], _f[4], _f[5])
	set(v): _f[3] = v.x; _f[4] = v.y; _f[5] = v.z

## View angles in degrees. Copied from the command each tick and kept here so a
## replay restores the view the tick was simulated with.
var yaw: float:
	get: return _f[12]
	set(v): _f[12] = v
var pitch: float = 0.0

## 0 standing, 1 fully crouched. Fractional mid-transition.
var crouch_fraction: float = 0.0

## Whether crouch was held on the command just applied.
## Distinct from [member crouch_fraction] > 0: releasing under a low ceiling stays crouched and retries the stand-up each tick.
var crouch_held: bool = false

## Normal of the floor under the player. Up when airborne.
var ground_normal: Vector3:
	get: return Vector3(_f[6], _f[7], _f[8])
	set(v): _f[6] = v.x; _f[7] = v.y; _f[8] = v.z

## The collider the player is standing on, or 0. A local physics handle, so not replicated and not in [method equals].
var ground_id: int:
	get: return (int(_f[11]) << 32) | int(_f[10])
	set(v):
		_f[10] = v & 0xFFFFFFFF
		_f[11] = v >> 32

## Id of the surface under the player, [code]&""[/code] when unmarked or airborne.
## Part of the simulation (it scales friction and acceleration), resolved from scene data so both machines agree. See [GSFpsSurfaceSet].
var surface: StringName = &""

## Active modifiers as (id index, tick they expire on), sorted by index; an expiry of [code]-1[/code] lasts until removed.
## In the state so a rewind restores them. Sorted because the aggregate is a float product, and a different order differs in the last bits so reconciliation never settles.
var modifiers: Array[Vector2i] = []

## Seconds since last on the ground, 0 while grounded. Drives coyote time; simulated seconds, so a replay reproduces it.
var time_since_grounded: float:
	get: return _f[15]
	set(v): _f[15] = v

## Seconds spent airborne in this stretch (mode AIR, a wall run included), 0 while anything else.
## Observed by the controller on live ticks only, so it is not replicated, not copied by [method copy_from] and not compared by [method equals]: a server reads it for statistics, a replay never feeds it. Unlike [member time_since_grounded] a jump does not seed it.
var airborne_time: float = 0.0

## Seconds since the jump button was pressed, or a large number if it never was.
var time_since_jump_pressed: float:
	get: return _f[16]
	set(v): _f[16] = v

## Seconds since the last jump left the ground.
var time_since_jump: float:
	get: return _f[14]
	set(v): _f[14] = v

## Consecutive ticks spent on the ground, 0 while airborne.
## Ticks, not seconds: a perfect hop must score the same at 64 Hz and 128 Hz. In the state so a rewind does not reset it.
var ground_ticks: int = 0

## Buttons on the previous command, for edge detection.
var previous_buttons: int:
	get: return int(_f[13])
	set(v): _f[13] = v

## Seconds into the current slide, or -1.0 when not sliding.
## In the state so a rewind replays a slide as a slide. See [member GSFpsTunables.slide_enabled].
var slide_time: float:
	get: return _f[17]
	set(v): _f[17] = v

## Seconds before another slide may start. 0 when one may.
var slide_cooldown_left: float:
	get: return _f[18]
	set(v): _f[18] = v

## Seconds before the launch ability may be used again, 0 when it may.
## Not replicated: the server decides, and the snapshot carries the velocity it produced.
var launch_cooldown_left: float:
	get: return _f[19]
	set(v): _f[19] = v

## Seconds before the dash may be used again. Replicated with the launch's; see
## [GSFpsNetSync].
var dash_cooldown_left: float:
	get: return _f[20]
	set(v): _f[20] = v

## Seconds before another wall run may start ([member GSFpsTunables.wall_run_cooldown]).
var wall_run_cooldown_left: float:
	get: return _f[21]
	set(v): _f[21] = v

## Sprint stamina, 0 empty to 1 full. Held in the state so a rewind restores it (see [GSFpsNetSync.pack_stamina]).
var stamina: float = 1.0

## Set when stamina ran out; sprint refuses until it recovers to [member GSFpsTunables.stamina_resume_at].
var stamina_exhausted: bool = false

## Seconds before stamina starts to refill after running out.
var stamina_delay_left: float = 0.0

## Whether the last tick moved at sprint speed. Read by HUDs, spread and the aim/reload rules.
var sprinting: bool = false

## Seconds into the current wall run, or -1.0 when not running.
## In the state and snapshot so a rewind does not replay a wall run as a fall. See [member GSFpsTunables.wall_run_enabled].
var wall_run_time: float:
	get: return _f[22]
	set(v): _f[22] = v

## A run has ended in this airborne stretch, so no other may start until the player lands
## or wall-jumps. Without it a run that timed out on a wall would start again on the next
## tick, and the time cap would mean nothing.
var wall_run_spent: bool:
	get: return _f[23] != 0.0
	set(v): _f[23] = 1.0 if v else 0.0

## Wall jumps made off the wall at [member wall_jump_heading] since last on the ground.
## 0 when there is no such wall. See [member GSFpsTunables.wall_jump_max_per_wall].
var wall_jump_count: int:
	get: return int(_f[24])
	set(v): _f[24] = v

## Wall jumps off any wall since last on the ground, 0..3. See
## [member GSFpsTunables.wall_jump_max_per_air]. Never less than [member wall_jump_count].
var wall_jumps_in_air: int:
	get: return int(_f[25])
	set(v): _f[25] = v

## Which wall [member wall_jump_count] counts, as the heading of its normal in eighths
## of a turn (0..7). Quantised in the simulation itself, not only on the wire, so a value
## restored from a snapshot is the one the simulation made.
var wall_jump_heading: int:
	get: return int(_f[26])
	set(v): _f[26] = v

## The normal of the wall being run along or touched this tick, or zero.
## An output the motor writes each tick (not replicated or compared), read by [GSFpsView] to roll the camera.
var wall_normal: Vector3:
	get: return Vector3(_f[27], _f[28], _f[29])
	set(v): _f[27] = v.x; _f[28] = v.y; _f[29] = v.z

## Ticks simulated. Diagnostic; not compared.
var tick: int = 0


## A readable name for a mode id; [param motor] supplies registered custom names, else the number is shown.
static func mode_name(id: int, motor: RefCounted = null) -> String:  # a GSFpsMotor, untyped so this file and the motor do not keep each other's parsers alive
	if id >= 0 and id < FIRST_CUSTOM_MODE:
		return Mode.keys()[id]

	if motor != null:
		var custom: RefCounted = motor.mode_for(id)
		if custom != null:
			return String(custom._name())

	return "mode#%d" % id


func is_grounded() -> bool:
	return mode == Mode.GROUND


## Seconds airborne in the current stretch, 0 on the ground. See [member airborne_time].
func airborne_seconds() -> float:
	return airborne_time


func is_crouched() -> bool:
	return crouch_fraction > 0.001


func is_sliding() -> bool:
	return slide_time >= 0.0


func is_wall_running() -> bool:
	return wall_run_time >= 0.0


## True while on, or just landed from, a wall run or wall jump: crouch held then slides on landing without a fresh press or sprint.
func came_off_wall() -> bool:
	return wall_run_spent or wall_jumps_in_air > 0 or wall_run_time >= 0.0


## Bits of [method move_flags]: what the body is doing, readable on a remote player too.
enum Move { CROUCH = 1, SLIDE = 2, SPRINT = 4, WALL_RUN = 8, AIR = 16 }


## Bitmask of [enum Move] from the replicated state (net_flags), so animation reads one int.
## Sprint falls back to the held sprint button because [member sprinting] is not on the wire.
func move_flags() -> int:
	var f := 0
	if is_crouched(): f |= Move.CROUCH
	if is_sliding(): f |= Move.SLIDE
	if sprinting or ((previous_buttons & GSFpsCommand.BUTTON_SPRINT) != 0 and is_grounded() and horizontal_speed() > 1.0): f |= Move.SPRINT
	if is_wall_running(): f |= Move.WALL_RUN
	if not is_grounded(): f |= Move.AIR
	return f


func speed() -> float:
	return velocity.length()


## Horizontal speed. The number a speedometer should show in a movement game —
## vertical velocity is gravity, not skill.
func horizontal_speed() -> float:
	return Vector2(velocity.x, velocity.z).length()


func copy_from(other: GSFpsState) -> void:
	_f = other._f.duplicate()
	pitch = other.pitch
	crouch_fraction = other.crouch_fraction
	crouch_held = other.crouch_held
	surface = other.surface
	# Two empty lists are already equal: a duplicate of nothing allocates an Array to be thrown away next tick.
	if not (modifiers.is_empty() and other.modifiers.is_empty()):
		modifiers = other.modifiers.duplicate()
	ground_ticks = other.ground_ticks
	stamina = other.stamina
	stamina_exhausted = other.stamina_exhausted
	stamina_delay_left = other.stamina_delay_left
	sprinting = other.sprinting
	tick = other.tick


## The state's [GSFpsStateColumns] values: the array itself, so a write to it is a write to the state.
func columns() -> PackedFloat64Array:
	return _f


func duplicate_state() -> GSFpsState:
	var s := GSFpsState.new()
	s.copy_from(self)
	return s


## Whether two states are the same to within [param epsilon].
## Proves a replay reproduces a simulation; the epsilon is for comparing across quantisation, not nondeterminism.
func equals(other: GSFpsState, epsilon: float = 0.0001) -> bool:
	if other == null:
		return false
	return (
		mode == other.mode
		and position.distance_to(other.position) <= epsilon
		and velocity.distance_to(other.velocity) <= epsilon
		and absf(crouch_fraction - other.crouch_fraction) <= epsilon
		and crouch_held == other.crouch_held
		and previous_buttons == other.previous_buttons
		and surface == other.surface
		and modifiers == other.modifiers
		# The timers are compared too: a replay that matched the position but not the timers jumps differently one tick later.
		and absf(time_since_grounded - other.time_since_grounded) <= epsilon
		and absf(time_since_jump - other.time_since_jump) <= epsilon
		and absf(time_since_jump_pressed - other.time_since_jump_pressed) <= epsilon
		and ground_ticks == other.ground_ticks
		and absf(slide_time - other.slide_time) <= epsilon
		and absf(slide_cooldown_left - other.slide_cooldown_left) <= epsilon
		and absf(launch_cooldown_left - other.launch_cooldown_left) <= epsilon
		and absf(dash_cooldown_left - other.dash_cooldown_left) <= epsilon
		and absf(wall_run_cooldown_left - other.wall_run_cooldown_left) <= epsilon
		and absf(stamina - other.stamina) <= 0.01
		and stamina_exhausted == other.stamina_exhausted
		and sprinting == other.sprinting
		and absf(wall_run_time - other.wall_run_time) <= epsilon
		and wall_run_spent == other.wall_run_spent
		and wall_jump_count == other.wall_jump_count
		and wall_jump_heading == other.wall_jump_heading
		and wall_jumps_in_air == other.wall_jumps_in_air
	)


## How far two states have diverged, in metres. For diagnostics and for deciding
## whether a correction is worth showing the player.
func divergence(other: GSFpsState) -> float:
	if other == null:
		return INF
	return position.distance_to(other.position)


func describe() -> Dictionary:
	return {
		"mode": mode_name(mode),
		"position": "(%.2f, %.2f, %.2f)" % [position.x, position.y, position.z],
		"velocity": "(%.2f, %.2f, %.2f)" % [velocity.x, velocity.y, velocity.z],
		"speed": "%.2f m/s (%.2f horizontal)" % [speed(), horizontal_speed()],
		"view": "%.1f / %.1f" % [yaw, pitch],
		"crouch": "%.2f%s" % [crouch_fraction, " held" if crouch_held else ""],
		"surface": String(surface) if surface != &"" else "-",
		"modifiers": modifiers.size(),
		"airborne_for": "%.2f s" % time_since_grounded,
		"slide": ("%.2f s" % slide_time) if is_sliding() else (
			"cooldown %.2f s" % slide_cooldown_left if slide_cooldown_left > 0.0 else "-"
		),
		"launch": ("cooldown %.1f s" % launch_cooldown_left) if launch_cooldown_left > 0.0 else "ready",
		"wall": _describe_wall(),
	}


func _describe_wall() -> String:
	var run := "-"
	if is_wall_running():
		run = "running %.2f s" % wall_run_time
	elif wall_run_spent:
		run = "run spent"

	if wall_jump_count > 0:
		run += ", %d jump(s) off the wall at %d/8, %d in all" % [
			wall_jump_count, wall_jump_heading, wall_jumps_in_air
		]

	return run


func describe_lines() -> PackedStringArray:
	var fields := describe()
	var out := PackedStringArray()
	for key in fields:
		out.append("%-14s %s" % [key, str(fields[key])])
	return out


func _to_string() -> String:
	return "GSFpsState(%s @ %.1f,%.1f,%.1f)" % [
		mode_name(mode), position.x, position.y, position.z
	]
