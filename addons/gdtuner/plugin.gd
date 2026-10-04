@tool
extends EditorPlugin

const TunerPanel := preload("res://addons/gdtuner/editor/tuner_panel.gd")
const TunerDebugger := preload("res://addons/gdtuner/editor/tuner_debugger.gd")

var _debugger = null
var _panel = null


func _enter_tree() -> void:
	add_autoload_singleton("DebugTuner", "res://addons/gdtuner/debug_tuner.gd")
	add_custom_type(
		"TunableRegistrar", "Node",
		preload("res://addons/gdtuner/tunable_registrar.gd"),
		preload("res://addons/gdtuner/icon.svg")
	)

	_panel = TunerPanel.new()
	_panel.custom_minimum_size = Vector2(0, 200)

	_debugger = TunerDebugger.new()
	_debugger.panel = _panel

	_panel.request_set_value.connect(func(full_key: String, value_str: String) -> void:
		_debugger.send_to_game("gdtuner:set_value", [full_key, value_str])
	)
	_panel.request_press_button.connect(func(full_key: String) -> void:
		_debugger.send_to_game("gdtuner:press_button", [full_key])
	)
	_panel.request_bake.connect(func() -> void:
		_debugger.send_to_game("gdtuner:bake", [])
	)

	add_debugger_plugin(_debugger)
	add_control_to_bottom_panel(_panel, "GDTuner")


func _exit_tree() -> void:
	remove_autoload_singleton("DebugTuner")
	remove_custom_type("TunableRegistrar")

	if _debugger:
		remove_debugger_plugin(_debugger)
		_debugger = null

	if _panel:
		remove_control_from_bottom_panel(_panel)
		_panel.queue_free()
		_panel = null
