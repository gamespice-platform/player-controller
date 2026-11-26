@tool
extends GSPlayerController

## The signals, constants, settings and fields of [GSFpsController], kept apart so the controller file stays small.

## Emitted after every simulated tick, on whichever peer simulated it.
signal simulated(tick: int, state: GSFpsState)


## Emitted when the player touches down. [param impact] is the downward speed lost.
signal landed(impact: float)


signal jumped()


## Emitted when the movement mode changes. Modes are ints because a game registers its own;
## render one with [method GSFpsState.mode_name].
signal mode_changed(from: int, to: int)


## Emitted when the player steps up onto something, with the height gained.
signal stepped_up(height: float)


## Emitted when the ground under the player changes kind (ids, not resources): the hook for
## footstep sounds and decals.
signal surface_changed(from: StringName, to: StringName)


## Emitted when the player starts or stops being crouched.
signal crouch_changed(crouched: bool)


## Emitted when a slide starts or ends ([member GSFpsTunables.slide_enabled]). Not during a
## prediction replay, unlike [signal crouch_changed]: a replayed tick is one the player
## already heard.
signal slide_changed(sliding: bool)


## Emitted when the launch ability fires. Not during a replay, for the same reason.
signal launched()


## Emitted when the dash fires. Not during a replay.
signal dashed()


## Emitted when a wall run starts or ends. Not during a replay, like [signal slide_changed].
## See [member GSFpsTunables.wall_run_enabled].
signal wall_run_changed(running: bool)


## Emitted with the degrees a jump-started wall-run turns the view; a controller with a sampler has already applied it, a game that samples its own look input applies it there. Not during a replay.
signal view_turned(degrees: float)


## Emitted when a wall jump fires. Not during a replay. See
## [member GSFpsTunables.wall_jump_enabled].
signal wall_jumped()


## Emitted when a modifier starts or stops applying, on whichever peer simulates.
signal modifier_added(id: StringName)


signal modifier_removed(id: StringName)


var _external_velocity: Vector3 = Vector3.ZERO


## Queued and added on the next live tick, before the move, so the motor sees it and an upward
## change lifts the player off the ground instead of being snapped back down.
func apply_external_velocity(dv: Vector3) -> void:
	_external_velocity += dv


## Whether a push is waiting for the next tick's start (a game that began the tick earlier sees it came late).
func has_external_velocity() -> bool:
	return _external_velocity != Vector3.ZERO


func _consume_external_velocity(s: GSFpsState, replaying: bool) -> void:
	if _external_velocity == Vector3.ZERO or replaying:
		return
	s.velocity += _external_velocity
	if _external_velocity.y > 0.0:
		s.mode = GSFpsState.Mode.AIR
		s.time_since_grounded = 1000.0
	_external_velocity = Vector3.ZERO


const CHANNEL := "fps"
## The state's column layout, for the per-tick reads in begin_tick and end_tick.
const _Cols := preload("../core/gs_fps_state_columns.gd")
const SERVICE := &"gs_fps_controller"

## Who supplies commands and drives ticks.
enum Drive {
	## Sample input and tick in [method Node._physics_process]. Single-player.
	LOCAL,
	## Someone else calls [method apply_command] and [method simulate_tick].
	EXTERNAL,
	## Simulate nothing; only apply state written from elsewhere.
	## For a remote player's copy: running the motor on arriving network state would fight it.
	REMOTE,
}

@export_group("Role")

@export var drive: Drive = Drive.LOCAL

## Simulation ticks per second in [constant Drive.LOCAL].
## Ignored in the other modes, where the driver sets the rate (GameSpice Net: [code]GSNetConfig.tick_rate[/code]). It must match on client and server: delta is an input to the simulation.
@export_range(1, 240, 1) var tick_rate: int = 60

## [member GSFpsMotor.static_world]: nothing the body queries moves between ticks. Off by default.
@export var static_world: bool = false

## Register in [GSRegistry] under [constant SERVICE] so other systems can find this.
## Off by default: it is a global name and several players would overwrite each other. Set [member service_scope] for that case.
@export var register_service: bool = false

## Suffix for the registry name, so several controllers can coexist.
@export var service_scope: StringName = &""

@export_group("Configuration")

## Movement tunables. One is created with the defaults if this is left empty.
@export var tunables: GSFpsTunables = null

## The surfaces this game has. Null means every surface behaves identically.
##
## Opt-in: without one, the surface lookup never runs and costs nothing.
@export var surfaces: GSFpsSurfaceSet = null

## The movement style in force for this player, or null for the base tunables.
## Assign in the inspector or through [method set_style], never at runtime: the motor holds the tunables it was built with, so a bare assignment changes nothing.
@export var style: GSFpsStyle = null

## JSON file layered over the exported defaults. Empty disables the file layer.
## Layering order: exported defaults, this file, [code]GS_FPS_*[/code], [code]--fps-*[/code].
@export var config_file: String = ""

## Apply the environment and command-line layers.
## Wanted on a dedicated server, not in a client, where an ambient variable silently changing movement is a support call.
@export var load_layered_config: bool = false

@export_group("Wiring")

## The node the simulated position is written to. Defaults to the parent.
@export var body_ref: GSNodeRef = null

## The collision shape resized when crouching. Optional but strongly recommended.
## Without it the simulation crouches and the host's collider does not, so a bullet trace sees a standing player.
@export var collider_ref: GSNodeRef = null

## The view. Optional: a headless server has nothing to look through.
@export var view_ref: GSNodeRef = null

@export_group("Safety")

## Whether this instance honours the noclip button at all.
## Deliberately redundant with [member GSFpsTunables.can_noclip]: that is shared config the client also holds; this is one controller's property, which a server sets from its own permissions.
@export var allow_noclip: bool = false

## Register [GSFpsAdminModifiers] (forced noclip, freeze, speed and gravity steps) so a server can apply them and the owning client predicts them.
## Set it on every machine or on none: registration order is the wire contract, and a mismatch makes each replicated index mean a different modifier.
@export var admin_abilities: bool = false

## Register this addon's default input bindings if the project has none.
@export var register_default_actions: bool = true

## On a touch device ([method GSPlatform.has_touch]) a local controller samples touch ([GSFpsTouchSampler]): a stick, a look drag, and buttons the game holds.
@export var use_touch_sampler: bool = true

## The simulated state. Authoritative in [constant Drive.LOCAL] and
## [constant Drive.EXTERNAL]; written from the network in [constant Drive.REMOTE].
var state: GSFpsState = GSFpsState.new()

var motor: GSFpsMotor = null
var body: GSFpsBody = null
var sampler: GSFpsSampler = null
## Processing follows it: [method _process] only draws the view, so a controller without one (a remote body) skips the frame call.
var view: GSFpsView = null:
	set(value):
		view = value
		set_process(value != null)

## The command applied on the most recent tick. Held so a driver can resend it.
var current_command: GSFpsCommand = null

## Movement statistics for the current run: jumps, strafes, sync, speed.
## Folded once per simulated tick and not during a replay, or a client under packet loss would count jumps that climb on their own.
var stats := GSFpsStats.new()

## Whether each tick is folded into [member stats]. A game that never reads them (a server, a shooter with no run HUD)
## turns this off and saves the fold every tick per player; [member GSFpsState.airborne_time] is kept either way.
@export var observe_stats: bool = true

## The tunables before the style was applied. See [method set_style].
## A style derives from the original, not the previous style's output, or two changes compound their scales.
var _pass_out_mask: int = 0
var _extra_exclude: Array[RID] = []
var _base_tunables: GSFpsTunables = null

## The command the statistics last saw, for their own edge detection.
var _stats_previous: GSFpsCommand = null

var _body_node: Node3D = null
var _collider: CollisionShape3D = null
var _capsule: CapsuleShape3D = null

## State at the end of the previous tick, for render interpolation. Each tick refreshes only its position and
## crouch_fraction, the fields the blend reads; setup and teleport copy it whole.
var _previous_state: GSFpsState = GSFpsState.new()

## Where the player stood two ticks back, for a frame drawn before [member _previous_state]
## (a [member render_clock] alpha below 0). NAN until a tick has run since the last reset.
var _position_two_back: Vector3 = Vector3(NAN, NAN, NAN)

## The clock this controller's ticks are counted on, for a client predicting it: anything with a [code]render_alpha() -> float[/code] (GameSpice Net's [code]GSNetClock[/code]), asked by name so this addon needs no GameSpice Net. Null draws at the engine's physics fraction. See [method render_state].
## A connected client's ticks are the clock's: it stretches them while it settles, so a physics frame runs no tick and a later one two, and drawing at the engine's fraction jumped the eye 10 to 16 cm on 4 to 8 frames in 5 s at 60 Hz.
## Set it by [code]controller.set(&"render_clock", clock)[/code] from a game pack, so a shell with an older copy of this addon ignores it.
var render_clock: Object = null

## collider instance id -> surface id. See _resolve_surface_id.
var _surface_cache: Dictionary = {}

## The modifier set as of the last time changes were reported. See _report_changes.
var _last_modifiers: Array[Vector2i] = []

var _replaying: bool = false

var _accumulator: float = 0.0
var _tick: int = 0
var _started: bool = false
var _registered_name: StringName = &""


## What end_tick diffs the tick against, captured by begin_tick before the motor runs.
var _before_mode: GSFpsState.Mode = GSFpsState.Mode.GROUND
var _before_y: float = 0.0
var _before_fall: float = 0.0
var _before_crouched: bool = false
var _before_surface: StringName = &""
var _before_sliding: bool = false
var _before_launches: int = 0
var _before_dashes: int = 0
var _before_wall_running: bool = false
var _before_wall_jumps: int = 0


## end_tick's motor-driven change signals, outside a replay. The state's columns are read directly ([GSFpsStateColumns]):
## each property is a call, per player per tick. Fetched again here: the motor may have swapped the array since begin_tick.
func _emit_motor_changes(delta: float) -> void:
	var f := state._f
	var sliding := f[_Cols.SLIDE_TIME] >= 0.0
	if sliding != _before_sliding:
		slide_changed.emit(sliding)

	if motor.launches != _before_launches:
		launched.emit()

	if motor.dashes != _before_dashes:
		dashed.emit()

	if motor.wall_jumps != _before_wall_jumps:
		wall_jumped.emit()

	var wall_running := f[_Cols.WALL_RUN_TIME] >= 0.0
	if wall_running != _before_wall_running:
		wall_run_changed.emit(wall_running)

	var turn := motor.view_turn
	if turn != 0.0:
		view_turned.emit(turn)
		if sampler != null:
			sampler.look_at_angles(sampler.yaw + turn, sampler.pitch)

	# Not during a replay: the statistics have seen that tick, and a lossy client would double-count.
	state.airborne_time = (state.airborne_time + delta) if int(f[_Cols.MODE]) == GSFpsState.Mode.AIR else 0.0
