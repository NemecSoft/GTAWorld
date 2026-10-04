class_name UITunable
extends Node

## Drop as child of any Control node to automatically expose visual properties
## in DebugTuner: modulate, custom_minimum_size, theme colors, font sizes,
## constants, and StyleBoxFlat properties. Zero code needed.

@export var section_name: String = ""
@export var section_id: String = ""

var _target: Control = null
var _bindings: Dictionary = {}  # key -> prop_path for set()
var _sb_bindings: Dictionary = {}  # key -> { "sb": StyleBoxFlat, "prop": String }
var _sb_corner_bindings: Dictionary = {}  # key -> StyleBoxFlat
var _sb_border_bindings: Dictionary = {}  # key -> StyleBoxFlat


func _ready() -> void:
	if not OS.is_debug_build():
		return
	_target = get_parent() as Control
	if not _target:
		push_warning("[gdtuner] UITunable must be a child of a Control node.")
		return
	if section_id.is_empty():
		if section_name.is_empty():
			section_name = _target.name
		section_id = "ui_" + section_name.to_snake_case()
	if section_name.is_empty():
		section_name = section_id
	var tuner := _get_tuner()
	if not tuner:
		return
	var script_path: String = _target.get_script().resource_path if _target.get_script() else ""
	tuner.register_section(section_id, section_name, script_path)
	_register_direct_properties(tuner)
	_register_theme_overrides(tuner)
	_register_stylebox_properties(tuner)
	tuner.value_changed.connect(_on_value_changed)


func _exit_tree() -> void:
	if not OS.is_debug_build():
		return
	var tuner := _get_tuner()
	if tuner:
		if tuner.value_changed.is_connected(_on_value_changed):
			tuner.value_changed.disconnect(_on_value_changed)
		tuner.unregister_section(section_id)


# --- Direct visual properties ---

func _register_direct_properties(tuner: Node) -> void:
	tuner.register_control(section_id, "modulate", {
		"type": "color", "label": "Modulate", "default": _target.modulate,
	})
	_bindings["modulate"] = "modulate"

	tuner.register_control(section_id, "self_modulate", {
		"type": "color", "label": "Self Modulate", "default": _target.self_modulate,
	})
	_bindings["self_modulate"] = "self_modulate"

	var min_size: Vector2 = _target.custom_minimum_size
	var max_val := _meta_or_default_vec2("custom_minimum_size", min_size, 500.0)
	tuner.register_control(section_id, "custom_minimum_size", {
		"type": "vector2", "label": "Min Size", "default": min_size,
		"min": Vector2.ZERO, "max": max_val, "step": 1.0,
	})
	_bindings["custom_minimum_size"] = "custom_minimum_size"


# --- Theme override properties ---

func _register_theme_overrides(tuner: Node) -> void:
	for prop in _target.get_property_list():
		var pname: String = prop.name
		if pname.begins_with("theme_override_colors/"):
			_register_theme_color(tuner, pname)
		elif pname.begins_with("theme_override_font_sizes/"):
			_register_theme_font_size(tuner, pname)
		elif pname.begins_with("theme_override_constants/"):
			_register_theme_constant(tuner, pname)


func _register_theme_color(tuner: Node, prop_path: String) -> void:
	var theme_name := prop_path.get_slice("/", 1)
	var current := Color.WHITE
	if _target.has_theme_color_override(theme_name):
		current = _target.get_theme_color(theme_name)
	elif _target.has_theme_color(theme_name):
		current = _target.get_theme_color(theme_name)
	tuner.register_control(section_id, theme_name, {
		"type": "color", "label": theme_name.capitalize(), "default": current,
	})
	_bindings[theme_name] = prop_path


func _register_theme_font_size(tuner: Node, prop_path: String) -> void:
	var theme_name := prop_path.get_slice("/", 1)
	var current: int = 16
	if _target.has_theme_font_size_override(theme_name):
		current = _target.get_theme_font_size(theme_name)
	elif _target.has_theme_font_size(theme_name):
		current = _target.get_theme_font_size(theme_name)
	var max_val := _meta_or_default_int(theme_name, current, 72)
	tuner.register_control(section_id, theme_name, {
		"type": "int", "label": theme_name.capitalize(), "default": current,
		"min": 1, "max": max_val, "step": 1,
	})
	_bindings[theme_name] = prop_path


func _register_theme_constant(tuner: Node, prop_path: String) -> void:
	var theme_name := prop_path.get_slice("/", 1)
	var current: int = 0
	if _target.has_theme_constant_override(theme_name):
		current = _target.get_theme_constant(theme_name)
	elif _target.has_theme_constant(theme_name):
		current = _target.get_theme_constant(theme_name)
	var max_val := _meta_or_default_int(theme_name, current, 100)
	tuner.register_control(section_id, theme_name, {
		"type": "int", "label": theme_name.capitalize(), "default": current,
		"min": 0, "max": max_val, "step": 1,
	})
	_bindings[theme_name] = prop_path


# --- StyleBoxFlat properties ---

const _STYLE_NAMES := ["panel", "normal", "hover", "pressed", "disabled", "focus"]

func _register_stylebox_properties(tuner: Node) -> void:
	for style_name in _STYLE_NAMES:
		var sb: StyleBox = null
		if _target.has_theme_stylebox_override(style_name):
			sb = _target.get_theme_stylebox(style_name)
		elif _target.has_theme_stylebox(style_name):
			sb = _target.get_theme_stylebox(style_name)
		if not sb is StyleBoxFlat:
			continue
		var flat := sb.duplicate() as StyleBoxFlat
		_target.add_theme_stylebox_override(style_name, flat)

		var prefix := style_name + "_"
		# bg_color
		var bg_key := prefix + "bg_color"
		tuner.register_control(section_id, bg_key, {
			"type": "color", "label": (style_name + " BG").capitalize(), "default": flat.bg_color,
		})
		_sb_bindings[bg_key] = {"sb": flat, "prop": "bg_color"}

		# border_color
		var bc_key := prefix + "border_color"
		tuner.register_control(section_id, bc_key, {
			"type": "color", "label": (style_name + " Border Color").capitalize(),
			"default": flat.border_color,
		})
		_sb_bindings[bc_key] = {"sb": flat, "prop": "border_color"}

		# corner_radius (uniform)
		var cr_key := prefix + "corner_radius"
		var cr_val: int = flat.corner_radius_top_left
		tuner.register_control(section_id, cr_key, {
			"type": "int", "label": (style_name + " Corners").capitalize(),
			"default": cr_val, "min": 0, "max": 100, "step": 1,
		})
		_sb_corner_bindings[cr_key] = flat

		# border_width (uniform)
		var bw_key := prefix + "border_width"
		var bw_val: int = flat.border_width_top
		tuner.register_control(section_id, bw_key, {
			"type": "int", "label": (style_name + " Border").capitalize(),
			"default": bw_val, "min": 0, "max": 50, "step": 1,
		})
		_sb_border_bindings[bw_key] = flat


# --- Value changed handler ---

func _on_value_changed(key: String, value: Variant) -> void:
	if not key.begins_with(section_id + "/"):
		return
	if not is_instance_valid(_target):
		return
	var prop_key := key.get_slice("/", 1)

	# Direct or theme override binding
	if _bindings.has(prop_key):
		_target.set(_bindings[prop_key], value)
		return

	# StyleBox simple property (bg_color, border_color)
	if _sb_bindings.has(prop_key):
		var binding: Dictionary = _sb_bindings[prop_key]
		binding.sb.set(binding.prop, value)
		return

	# StyleBox uniform corner_radius
	if _sb_corner_bindings.has(prop_key):
		var sb: StyleBoxFlat = _sb_corner_bindings[prop_key]
		var v: int = value
		sb.corner_radius_top_left = v
		sb.corner_radius_top_right = v
		sb.corner_radius_bottom_left = v
		sb.corner_radius_bottom_right = v
		return

	# StyleBox uniform border_width
	if _sb_border_bindings.has(prop_key):
		var sb: StyleBoxFlat = _sb_border_bindings[prop_key]
		var v: int = value
		sb.border_width_top = v
		sb.border_width_right = v
		sb.border_width_bottom = v
		sb.border_width_left = v


# --- Helpers ---

func _meta_or_default_vec2(prop_name: String, current: Vector2, fallback_max: float) -> Vector2:
	var meta_key := "tunable_range_" + prop_name
	if _target.has_meta(meta_key):
		var meta: Vector2 = _target.get_meta(meta_key)
		return Vector2(meta.y, meta.y)
	return Vector2(maxf(current.x * 3.0, fallback_max), maxf(current.y * 3.0, fallback_max))


func _meta_or_default_int(prop_name: String, current: int, fallback_max: int) -> int:
	var meta_key := "tunable_range_" + prop_name
	if _target.has_meta(meta_key):
		var meta: Vector2 = _target.get_meta(meta_key)
		return int(meta.y)
	return maxi(current * 3, fallback_max)


func _get_tuner() -> Node:
	var tree := get_tree()
	if tree == null:
		return null
	return tree.root.get_node_or_null("DebugTuner")
