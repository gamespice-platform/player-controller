@tool
extends EditorPlugin

## Editor entry point for GameSpice Player Controller. Registers inspector types only.
##
## No autoloads: one process can host a server, a client and a spectator camera.

const _ICON := "res://addons/dot_player_controller/icon_placeholder.svg"

const _BASE := "res://addons/dot_player_controller/nodes/"
const _FP := "res://addons/dot_player_controller/fp/nodes/"
const _TP := "res://addons/dot_player_controller/tp/nodes/"

const _TYPES := [
	["GSPlayerControllerSwitch", "Node", _BASE + "dot_player_controller_switch.gd"],
	["GSFpsController", "Node", _FP + "dot_fps_controller.gd"],
	["GSFpsView", "Node3D", _FP + "dot_fps_view.gd"],
	["GSFpsSampler", "Node", _FP + "dot_fps_sampler.gd"],
	["GSFpsTouchSampler", "Node", _FP + "dot_fps_touch_sampler.gd"],
	["GSTpsController", "Node", _TP + "dot_tps_controller.gd"],
	["GSTpsCameraRig", "Node3D", _TP + "dot_tps_camera_rig.gd"],
	["GSTpsSampler", "Node", _TP + "dot_tps_sampler.gd"],
]


func _enter_tree() -> void:
	var icon: Texture2D = null
	if ResourceLoader.exists(_ICON):
		icon = load(_ICON) as Texture2D

	for entry in _TYPES:
		if not ResourceLoader.exists(entry[2]):
			# A trimmed install — a game that copied only the base and one half — is a
			# supported shape, and a plugin that errored on it would make the trim
			# impossible.
			continue

		add_custom_type(entry[0], entry[1], load(entry[2]), icon)


func _exit_tree() -> void:
	for i in range(_TYPES.size() - 1, -1, -1):
		remove_custom_type(_TYPES[i][0])
