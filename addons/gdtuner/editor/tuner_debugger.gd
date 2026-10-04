@tool
extends EditorDebuggerPlugin

var panel: Control = null  # Set by plugin.gd (tuner_panel instance)
var _active_session_id: int = -1


func _has_capture(prefix: String) -> bool:
	return prefix == "gdtuner"


func _capture(message: String, data: Array, session_id: int) -> bool:
	if not panel:
		return false
	match message:
		"gdtuner:register_section":
			panel.handle_register_section(data[0], data[1])
		"gdtuner:register_control":
			var config: Dictionary = str_to_var(data[2])
			panel.handle_register_control(data[0], data[1], config)
		"gdtuner:value_changed":
			var value: Variant = str_to_var(data[1])
			panel.handle_value_changed(data[0], value)
		"gdtuner:unregister_section":
			panel.handle_unregister_section(data[0])
		"gdtuner:button_pressed":
			pass
		_:
			return false
	return true


func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	session.started.connect(_on_started.bind(session_id))
	session.stopped.connect(_on_stopped.bind(session_id))


func _on_started(session_id: int) -> void:
	_active_session_id = session_id
	if panel:
		panel.session_started()


func _on_stopped(session_id: int) -> void:
	if _active_session_id == session_id:
		_active_session_id = -1
	if panel:
		panel.session_stopped()


func send_to_game(message: String, data: Array) -> void:
	if _active_session_id < 0:
		return
	var session := get_session(_active_session_id)
	if session and session.is_active():
		session.send_message(message, data)
