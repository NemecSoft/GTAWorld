class_name TunableRegistrar
extends Node

## Node that registers tuning controls with DebugTuner.
## Add as a child of any scene and override _register_tunables() to define controls.
## Controls are automatically registered on _ready() and unregistered on _exit_tree().

@export var section_name: String = ""
@export var section_id: String = ""

var _registered_keys: Array[String] = []


func _ready() -> void:
	if not OS.is_debug_build():
		return
	if section_id.is_empty():
		if section_name.is_empty():
			section_name = get_parent().name if get_parent() else name
		section_id = section_name.to_snake_case()
	if section_name.is_empty():
		section_name = section_id
	if not Engine.has_singleton("DebugTuner") and not _get_tuner():
		push_warning("[gdtuner] DebugTuner autoload not found. Is the plugin enabled?")
		return
	var tuner := _get_tuner()
	if tuner:
		tuner.register_section(section_id, section_name, get_script().resource_path)
		_register_tunables()


func _exit_tree() -> void:
	if not OS.is_debug_build():
		return
	var tuner := _get_tuner()
	if tuner:
		tuner.unregister_section(section_id)


## Override this method to register your tunable controls.
func _register_tunables() -> void:
	pass


func add_float(key: String, min_val: float, max_val: float, default: float, step: float = 0.01) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "float",
			"label": key.capitalize(),
			"min": min_val,
			"max": max_val,
			"default": default,
			"step": step,
		})
		_registered_keys.append(key)


func add_int(key: String, min_val: int, max_val: int, default: int, step: int = 1) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "int",
			"label": key.capitalize(),
			"min": min_val,
			"max": max_val,
			"default": default,
			"step": step,
		})
		_registered_keys.append(key)


func add_bool(key: String, default: bool) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "bool",
			"label": key.capitalize(),
			"default": default,
		})
		_registered_keys.append(key)


func add_color(key: String, default: Color) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "color",
			"label": key.capitalize(),
			"default": default,
		})
		_registered_keys.append(key)


func add_dropdown(key: String, options: Array[String], default_index: int = 0) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "dropdown",
			"label": key.capitalize(),
			"options": options,
			"default": options[default_index] if default_index < options.size() else "",
			"default_index": default_index,
		})
		_registered_keys.append(key)


func add_vector2(key: String, default: Vector2, min_val: Vector2, max_val: Vector2, step: float = 1.0) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "vector2",
			"label": key.capitalize(),
			"default": default,
			"min": min_val,
			"max": max_val,
			"step": step,
		})
		_registered_keys.append(key)


func add_vector3(key: String, default: Vector3, min_val: Vector3, max_val: Vector3, step: float = 1.0) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "vector3",
			"label": key.capitalize(),
			"default": default,
			"min": min_val,
			"max": max_val,
			"step": step,
		})
		_registered_keys.append(key)


func add_button(key: String, label: String) -> void:
	var tuner := _get_tuner()
	if tuner:
		tuner.register_control(section_id, key, {
			"type": "button",
			"label": label,
		})
		_registered_keys.append(key)


func _get_tuner() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("DebugTuner")
