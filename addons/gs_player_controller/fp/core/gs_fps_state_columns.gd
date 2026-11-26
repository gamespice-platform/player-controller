class_name GSFpsStateColumns
extends RefCounted
## The layout of [method GSFpsState.columns]: the values of [GSFpsState] the motor tick reads and writes, packed into
## [constant STRIDE] float64s, so GameSpice Sim takes one array per player instead of [code]Object.get[/code] per field.
## The state's properties are accessors over it, so callers see no difference. Float64 holds every value exactly
## (float32 vector components, ints of 32 bits, the halves of [member GSFpsState.ground_id]), so nothing rounds.

## Offsets inside a slot. 14..29 are the motor row's clock block in its own order (input 39..54, output 23..38).
const POSITION := 0
const VELOCITY := 3
const GROUND_NORMAL := 6
const MODE := 9
const GROUND_ID_LOW := 10
const GROUND_ID_HIGH := 11
const YAW := 12
const PREVIOUS_BUTTONS := 13
const TIME_SINCE_JUMP := 14
const TIME_SINCE_GROUNDED := 15
const TIME_SINCE_JUMP_PRESSED := 16
const SLIDE_TIME := 17
const SLIDE_COOLDOWN_LEFT := 18
const LAUNCH_COOLDOWN_LEFT := 19
const DASH_COOLDOWN_LEFT := 20
const WALL_RUN_COOLDOWN_LEFT := 21
const WALL_RUN_TIME := 22
const WALL_RUN_SPENT := 23
const WALL_JUMP_COUNT := 24
const WALL_JUMPS_IN_AIR := 25
const WALL_JUMP_HEADING := 26
const WALL_NORMAL := 27
## The crouch: fraction, and held as 0 or 1. Kept in the slot so the native batch crouches without a round trip.
const CROUCH_FRACTION := 30
const CROUCH_HELD := 31
## The clock block's start and length.
const CLOCKS := 14
const CLOCK_COUNT := 16
const STRIDE := 32

## A new state's values: a fresh [GSFpsState]'s defaults (airborne, ground normal up, no jump or press for 1000 s, not
## sliding or wall running, standing).
const DEFAULTS := [
	0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 1.0, 0.0, 0.0, 0.0, 0.0,
	1000.0, 0.0, 1000.0, -1.0, 0.0, 0.0, 0.0, 0.0, -1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
	0.0, 0.0,
]
