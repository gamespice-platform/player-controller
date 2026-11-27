class_name GSFpsLadderMode
extends GSFpsMoveMode

## Climbing a ladder: a player whose hull touches a ladder box and pushes into it, or falls past it, is on it.
## Ladders are data, not areas, so a client replaying prediction gets the server's answer; the game calls [method update]
## once a tick after the move to put a player on, [method _simulate] takes them off.

## The ladder boxes, world space, metres.
var volumes: Array[AABB] = []

## Climb speed, m/s.
var climb_speed: float = 3.81

## Speed a jump pushes a climber off the ladder, away from it.
var jump_off_speed: float = 5.14

## How far past the hull a ladder still counts as touched.
var reach: float = 0.05

## Fraction of the sideways part of a climber's move removed, 0 to 1 (the classic ladder_dampen).
var dampen: float = 0.0

## Applies the ladder cvar. False for an unknown name or a value that is not a number.
func set_cvar(cvar_name: String, value: String) -> bool:
	if cvar_name != "sv_ladder_dampen" or not value.strip_edges().is_valid_float():
		return false
	dampen = clampf(value.strip_edges().to_float(), 0.0, 1.0)
	return true


## One entry per ladder cvar: name, value, description, member.
func cvar_specs() -> Array[Dictionary]:
	return [{"name": "sv_ladder_dampen", "value": dampen,
		"description": "Fraction of sideways ladder movement removed", "member": "dampen"}]

## Horizontal direction the player commands this tick, set by the caller before update; update clears it.
var wish := Vector3.ZERO

## The tick a climber last jumped off, so the ladder they are still touching does not
## take them straight back. One per player: every player has their own mode.
var _jumped_off_tick: int = -1000


func _name() -> StringName:
	return &"ladder"


func _uses_crouch() -> bool:
	return false


## The ladder the hull at [param feet] touches, or AABB() for none.
func touching(feet: Vector3, radius: float, height: float) -> AABB:
	var hull := AABB(feet - Vector3(radius + reach, 0.0, radius + reach),
		Vector3((radius + reach) * 2.0, height, (radius + reach) * 2.0))
	for box in volumes:
		if box.intersects(hull):
			return box
	return AABB()


## Once a tick, after the move: a player touching a ladder who is off the ground, or
## walking into it, is put on it. Read from the state rather than the command, so it
## needs nothing a replayed tick does not have. Noclip, and somebody already on, are left.
func update(motor: GSFpsMotor, state: GSFpsState) -> void:
	var intent := wish
	wish = Vector3.ZERO    # spent: a tick with no command must not reuse the last one
	if mode_id < 0 or volumes.is_empty() or state.mode == mode_id or state.mode == GSFpsState.Mode.NOCLIP:
		return
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		return
	if state.time_since_jump < 0.15 or state.tick - _jumped_off_tick < 32:
		return    # a jump at the foot of a ladder, or off it, is a jump
	var flat := Vector3(state.velocity.x, 0.0, state.velocity.z)
	var away := _away(box, state.position)
	var into := -flat.dot(away)
	# A wall behind a thin ladder zeroes the velocity before this reads it and the reach is under
	# one tick of travel, so pushing into the face is also judged by the commanded direction.
	# Not within 0.3 m of the top: someone standing there walks off the lip into the face.
	var pushing := -intent.dot(away) > 0.5 and state.position.y < box.position.y + box.size.y - 0.3
	if (not state.is_grounded() and state.velocity.y < 0.0) or into > 0.25 or pushing:
		motor.set_mode(state, mode_id)
		state.velocity = Vector3.ZERO


func _simulate(state: GSFpsState, command: GSFpsCommand, delta: float, motor: GSFpsMotor) -> void:
	var t := motor.tunables
	var box := touching(state.position, t.radius, t.height_at(state.crouch_fraction))
	if box.size == Vector3.ZERO:
		motor.set_mode(state, GSFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	var away := _away(box, state.position)
	if command.is_pressed(GSFpsCommand.BUTTON_JUMP):
		state.velocity = away * jump_off_speed
		_jumped_off_tick = state.tick
		motor.set_mode(state, GSFpsState.Mode.AIR)
		motor.move_and_slide(state, delta)
		return

	# The wish along the view, split into what goes into the ladder's face (turned into motion up it)
	# and the rest, which is kept: forward climbs, looking up climbs faster, strafe slides across.
	var basis := GSFpsMotor._view_basis(state.yaw, state.pitch)
	var wish := (basis.forward * clampf(command.move.y, -1.0, 1.0)
		+ basis.right * clampf(command.move.x, -1.0, 1.0)) * climb_speed
	var into := wish.dot(away)
	var lateral := wish - away * into
	var perp := Vector3.UP.cross(away).normalized()
	var up_face := away.cross(perp)
	var v := lateral * (1.0 - dampen) - up_face * into
	state.velocity = v.limit_length(climb_speed * 1.5)
	motor.move_and_slide(state, delta)

	# Down onto the floor at the foot: back to walking. Asked only while going down, and the mode
	# put back if there is no floor: the ground check writes AIR for every riser, which dropped
	# climbers off the ladder on every tick.
	if v.y <= 0.0:
		motor.categorise_ground(state)
		if not state.is_grounded():
			state.mode = mode_id


## GameSpice Sim's ladder tail (API 57) for this mode's [method _simulate]; none for a subclass, whose tick may differ.
## The jump-off tick is stamped here for a tick that runs natively, exactly as [method _simulate] would stamp it.
func _native_tail(
	state: GSFpsState, command: GSFpsCommand, motor: GSFpsMotor, out: PackedFloat64Array, at: int
) -> bool:
	if get_script() != GSFpsLadderMode:
		return false
	var t := motor.tunables
	var height := t.height_at(state.crouch_fraction)
	if not write_native_tail(
		out, at, mode_id, climb_speed, jump_off_speed, reach, dampen, false, t.radius, height, state.pitch, volumes
	):
		return false
	if command.is_pressed(GSFpsCommand.BUTTON_JUMP) and touching(state.position, t.radius, height).size != Vector3.ZERO:
		_jumped_off_tick = state.tick
	return true


## -1 not asked yet, else whether GameSpice Sim's whole tick runs a ladder tail ([code]has_ladder[/code]).
static var _native_known: int = -1


## Writes GameSpice Sim's ladder tail into [param out] from [param at] (resized); false, nothing written, without a library
## that runs one. [param carry_over_top]: off the top while rising and pushing forward, go on over the lip at climb speed.
## Static so a game's own copy of this mode, with the same tick, sends the same tail.
static func write_native_tail(
	out: PackedFloat64Array, at: int, id: int, climb: float, jump_off: float, reach_m: float, dampen_f: float,
	carry_over_top: bool, radius: float, height: float, pitch: float, boxes: Array[AABB]
) -> bool:
	if _native_known < 0:
		_native_known = 1 if (
			ClassDB.class_exists(&"GSSimFpsBody") and ClassDB.class_has_method(&"GSSimFpsBody", &"has_ladder")
		) else 0
	if _native_known == 0:
		return false
	out.resize(at + 11 + boxes.size() * 6)
	out[at] = 2.0
	out[at + 1] = id
	out[at + 2] = climb
	out[at + 3] = jump_off
	out[at + 4] = reach_m
	out[at + 5] = dampen_f
	out[at + 6] = 1.0 if carry_over_top else 0.0
	out[at + 7] = radius
	out[at + 8] = height
	out[at + 9] = pitch
	out[at + 10] = boxes.size()
	var o := at + 11
	for box in boxes:
		out[o] = box.position.x
		out[o + 1] = box.position.y
		out[o + 2] = box.position.z
		out[o + 3] = box.size.x
		out[o + 4] = box.size.y
		out[o + 5] = box.size.z
		o += 6
	return true


## Horizontal unit vector from the ladder's face out toward the player.
static func _away(box: AABB, feet: Vector3) -> Vector3:
	var c := box.get_center()
	var d := Vector3(feet.x - c.x, 0.0, feet.z - c.z)
	# A ladder is thin: its normal is the short horizontal axis.
	if box.size.x < box.size.z:
		d = Vector3(signf(d.x) if d.x != 0.0 else 1.0, 0.0, 0.0)
	else:
		d = Vector3(0.0, 0.0, signf(d.z) if d.z != 0.0 else 1.0)
	return d


func describe() -> Dictionary:
	var out := super.describe()
	out["volumes"] = volumes.size()
	return out
