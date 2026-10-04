class_name AutoTunable
extends Node

## Drop as child of any node to auto-register @export variables inside
## @export_group("tunable") with DebugTuner. Uses property binding — changing
## a slider directly sets the property on the parent node. No get_value() needed.
##
## Usage in parent script:
##   @export_group("tunable")
##   @export var speed: float = 5.0
##   @export var jump_force: float = 10.0
##   @export_group("")

@export var section_name: String = ""
@export var section_id: String = ""

var _target: Node = null
var _properties: Dictionary = {}  # prop_name -> true


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_target = get_parent()
	if not _target:
		return
	if section_id.is_empty():
		if section_name.is_empty():
			section_name = _target.name
		section_id = section_name.to_snake_case()
	if section_name.is_empty():
		section_name = section_id
	var tuner := _get_tuner()
	if not tuner:
		return
	var props := _scan_tunable_exports()
	if props.is_empty():
		return
	var script_path: String = _target.get_script().resource_path if _target.get_script() else ""
	tuner.register_section(section_id, section_name, script_path)
	for prop in props:
		_register_property(tuner, prop)
	tuner.value_changed.connect(_on_value_changed)


func _exit_tree() -> void:
	if not OS.is_debug_build():
		return
	var tuner := _get_tuner()
	if tuner:
		if tuner.value_changed.is_connected(_on_value_changed):
			tuner.value_changed.disconnect(_on_value_changed)
		tuner.unregister_section(section_id)


func _scan_tunable_exports() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var in_tunable_group := false
	for prop in _target.get_property_list():
		if prop.type == TYPE_NIL and prop.usage & PROPERTY_USAGE_GROUP:
			in_tunable_group = prop.name == "tunable"
			continue
		if not in_tunable_group:
			continue
		if not (prop.usage & PROPERTY_USAGE_SCRIPT_VARIABLE):
			continue
		if not (prop.usage & PROPERTY_USAGE_STORAGE):
			continue
		result.append(prop)
	return result


func _register_property(tuner: Node, prop: Dictionary) -> void:
	var prop_name: String = prop.name
	var current: Variant = _target.get(prop_name)
	var config := _build_config(prop, current)
	if config.is_empty():
		return
	_properties[prop_name] = true
	tuner.register_control(section_id, prop_name, config)


func _build_config(prop: Dictionary, current: Variant) -> Dictionary:
	var prop_name: String = prop.name
	var label: String = prop_name.capitalize()

	# Parse @export_range hint if present
	var hint_min := 0.0
	var hint_max := 0.0
	var hint_step := 0.0
	var has_hint: bool = prop.hint == PROPERTY_HINT_RANGE and not prop.hint_string.is_empty()
	if has_hint:
		var parts: PackedStringArray = prop.hint_string.split(",")
		if parts.size() >= 2:
			hint_min = parts[0].to_float()
			hint_max = parts[1].to_float()
		if parts.size() >= 3:
			hint_step = parts[2].to_float()

	# Check metadata range override: set_meta("tunable_range_<prop>", Vector2(min, max))
	var meta_range: Variant = null
	if _target.has_meta("tunable_range_" + prop_name):
		meta_range = _target.get_meta("tunable_range_" + prop_name)

	match prop.type:
		TYPE_FLOAT:
			var val: float = current
			var min_val := minf(0.0, val * 3.0)
			var max_val := maxf(absf(val) * 3.0, 1.0)
			var step := 0.01
			if has_hint:
				min_val = hint_min
				max_val = hint_max
				if hint_step > 0:
					step = hint_step
			if meta_range is Vector2:
				min_val = meta_range.x
				max_val = meta_range.y
			return {"type": "float", "label": label, "default": val, "min": min_val, "max": max_val, "step": step}

		TYPE_INT:
			var val: int = current
			var min_val := mini(0, val * 3)
			var max_val := maxi(absi(val) * 3, 10)
			var step := 1
			if has_hint:
				min_val = int(hint_min)
				max_val = int(hint_max)
				if hint_step > 0:
					step = int(hint_step)
			if meta_range is Vector2:
				min_val = int(meta_range.x)
				max_val = int(meta_range.y)
			return {"type": "int", "label": label, "default": val, "min": min_val, "max": max_val, "step": step}

		TYPE_BOOL:
			return {"type": "bool", "label": label, "default": current}

		TYPE_COLOR:
			return {"type": "color", "label": label, "default": current}

		TYPE_VECTOR2:
			var val: Vector2 = current
			var min_val := Vector2(minf(0.0, val.x * 3.0), minf(0.0, val.y * 3.0))
			var max_val := Vector2(maxf(absf(val.x) * 3.0, 100.0), maxf(absf(val.y) * 3.0, 100.0))
			if meta_range is Vector2:
				min_val = Vector2(meta_range.x, meta_range.x)
				max_val = Vector2(meta_range.y, meta_range.y)
			return {"type": "vector2", "label": label, "default": val, "min": min_val, "max": max_val, "step": 1.0}

		TYPE_VECTOR3:
			var val: Vector3 = current
			var min_val := Vector3(minf(0.0, val.x * 3.0), minf(0.0, val.y * 3.0), minf(0.0, val.z * 3.0))
			var max_val := Vector3(maxf(absf(val.x) * 3.0, 100.0), maxf(absf(val.y) * 3.0, 100.0), maxf(absf(val.z) * 3.0, 100.0))
			return {"type": "vector3", "label": label, "default": val, "min": min_val, "max": max_val, "step": 1.0}

	return {}


func _on_value_changed(key: String, value: Variant) -> void:
	if not key.begins_with(section_id + "/"):
		return
	var prop_name := key.get_slice("/", 1)
	if _properties.has(prop_name) and is_instance_valid(_target):
		_target.set(prop_name, value)


func _get_tuner() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("DebugTuner")
