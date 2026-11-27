@tool
extends "gs_fps_controller_render.gd"

## How [GSFpsController] sizes and places its collider to the crouch, kept apart so the controller file stays small.


func _apply_collider(from: GSFpsState) -> void:
	if _capsule == null:
		return

	# Skipped when nothing it reads has changed since the last apply: the shape and the node are only ever written here, and a player that is not crouching
	# or standing up repeats the same key every tick. The checks below read three engine properties a player a tick, which this skips.
	var crouch := from.crouch_fraction
	var stand := tunables.stand_height
	var crouched := tunables.crouch_height
	var radius := tunables.radius
	if (
		crouch == _key_crouch and stand == _key_stand and crouched == _key_crouched
		and radius == _key_radius and _capsule == _key_capsule
	):
		return
	_key_crouch = crouch
	_key_stand = stand
	_key_crouched = crouched
	_key_radius = radius
	_key_capsule = _capsule

	var height := tunables.height_at(crouch)
	var shape_height := maxf(height, tunables.radius * 2.0)

	# Written only when it differs from the shape: assigning a size, even the same one, makes the shape emit `changed` and re-send itself to the physics server (the physics body does the same in `GSFpsPhysicsBody._configure`). Compared against the shape itself, so a size changed from outside is put back at the next change of the key above (or at once after [method _forget_collider_key]). The shape and the node hold 32-bit floats, so a value such as 1.8 never reads back equal to the one written: a value that is the one last written and reads back as it read back then is already there (without this every player re-sent its shape and moved its collider every tick).
	var shape_now := _capsule.height
	if shape_now != shape_height and not (shape_height == _sent_height and shape_now == _held_height):
		_capsule.height = shape_height
		_sent_height = shape_height
		_held_height = _capsule.height

	var radius_now := _capsule.radius
	if radius_now != radius and not (radius == _sent_radius and radius_now == _held_radius):
		_capsule.radius = radius
		_sent_radius = radius
		_held_radius = _capsule.radius

	if _collider != null:
		# The collider's origin is its centre and the body's is its feet.
		var centre := height * 0.5
		var centre_now := _collider.position.y
		if centre_now != centre and not (centre == _sent_centre and centre_now == _held_centre):
			_collider.position.y = centre
			_sent_centre = centre
			_held_centre = _collider.position.y


## [method _apply_collider]'s last writes and what the shape and node held after them (NAN: none yet).
var _sent_height := NAN
var _held_height := NAN
var _sent_radius := NAN
var _held_radius := NAN
var _sent_centre := NAN
var _held_centre := NAN
## The inputs of [method _apply_collider]'s last full pass (NAN: none yet); see [method _forget_collider_key].
var _key_crouch := NAN
var _key_stand := NAN
var _key_crouched := NAN
var _key_radius := NAN
var _key_capsule: CapsuleShape3D = null


## Makes the next [method _apply_collider] check the shape and node again, for code that moved or resized them itself.
func _forget_collider_key() -> void:
	_key_crouch = NAN
