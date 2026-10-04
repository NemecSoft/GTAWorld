extends Node

## Central manager for gdtuner. Registered as autoload singleton "DebugTuner".
## When running from the editor, controls appear in the "gdtuner" bottom panel
## via EditorDebuggerPlugin. Otherwise, a separate Window (desktop) or bottom
## sheet (mobile) is used as fallback. Release builds are zero-cost no-ops.

signal value_changed(key: String, value: Variant)
signal button_pressed(key: String)

var _is_debug: bool = false
var _is_mobile: bool = false
var _editor_mode: bool = false
var _suppress_editor_notify: bool = false
var _window: Window = null
var _overlay: CanvasLayer = null
var _sheet: PanelContainer = null
var _tab_container: TabContainer = null
var _values: Dictionary = {}
var _defaults: Dictionary = {}
var _sections: Dictionary = {}  # section_id -> { display_name, container, header, ref_count, controls }
var _control_nodes: Dictionary = {}  # full_key -> control node
var _control_configs: Dictionary = {}  # full_key -> config dict
var _section_scripts: Dictionary = {}  # section_id -> script res:// path


func _ready() -> void:
	_is_debug = OS.is_debug_build()
	if not _is_debug:
		return
	_is_mobile = OS.get_name() in ["iOS", "Android"]
	if not _is_mobile and EngineDebugger.is_active():
		_editor_mode = true
		EngineDebugger.register_message_capture("gdtuner", _on_editor_message)
	elif _is_mobile:
		_create_sheet()
	else:
		_create_window()


const SHAKE_THRESHOLD := 25.0  # m/s² — strong shake required
const SHAKE_COUNT_REQUIRED := 2  # number of shakes needed
const SHAKE_WINDOW := 1.0  # seconds to complete all shakes
var _shake_count: int = 0
var _shake_timer: float = 0.0
var _was_above_threshold: bool = false


func _process(delta: float) -> void:
	if not _is_debug or not _is_mobile:
		return
	if _shake_count > 0:
		_shake_timer += delta
		if _shake_timer > SHAKE_WINDOW:
			_shake_count = 0
			_shake_timer = 0.0
	var accel := Input.get_accelerometer()
	# Subtract gravity (~9.8 on Y) to get user acceleration magnitude
	var user_accel := accel - Vector3(0, -9.8, 0)
	var magnitude := user_accel.length()
	if magnitude > SHAKE_THRESHOLD:
		if not _was_above_threshold:
			_was_above_threshold = true
			_shake_count += 1
			if _shake_count == 1:
				_shake_timer = 0.0
			if _shake_count >= SHAKE_COUNT_REQUIRED:
				toggle_window()
				_shake_count = 0
	else:
		_was_above_threshold = false


func _input(event: InputEvent) -> void:
	if not _is_debug or _editor_mode:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F12:
			toggle_window()


# --- Editor Debugger Messages ---

func _on_editor_message(message: String, data: Array) -> bool:
	match message:
		"set_value":
			var full_key: String = data[0]
			var value: Variant = str_to_var(data[1])
			_suppress_editor_notify = true
			_set_value(full_key, value)
			_suppress_editor_notify = false
		"press_button":
			var full_key: String = data[0]
			print("[gdtuner:action] %s pressed (from editor)" % full_key)
			button_pressed.emit(full_key)
		"bake":
			bake_all_values()
		"copy_values":
			copy_all_values_to_clipboard()
		_:
			return false
	return true


# --- Public API ---

func get_value(key: String, fallback: Variant = null) -> Variant:
	if not _is_debug:
		return fallback
	return _values.get(key, fallback)


func toggle_window() -> void:
	if not _is_debug:
		return
	if _is_mobile:
		if _overlay:
			_overlay.visible = not _overlay.visible
	else:
		if _window:
			_window.visible = not _window.visible


func register_section(section_id: String, display_name: String, script_path: String = "") -> void:
	if not _is_debug:
		return
	if not script_path.is_empty():
		_section_scripts[section_id] = script_path
	if _sections.has(section_id):
		_sections[section_id].ref_count += 1
		return
	var section_data := {
		"display_name": display_name,
		"container": null,
		"header": null,
		"content": null,
		"ref_count": 1,
		"controls": [],
	}
	if _editor_mode:
		EngineDebugger.send_message("gdtuner:register_section", [section_id, display_name, script_path])
	else:
		_build_section_ui(section_id, section_data)
	_sections[section_id] = section_data


func register_control(section_id: String, key: String, config: Dictionary) -> void:
	if not _is_debug:
		return
	var full_key := section_id + "/" + key
	if _control_configs.has(full_key):
		return
	var default_value: Variant = config.get("default")
	_defaults[full_key] = default_value
	if not _values.has(full_key):
		_values[full_key] = default_value
	_control_configs[full_key] = config

	if _editor_mode:
		EngineDebugger.send_message("gdtuner:register_control", [section_id, key, var_to_str(config)])
		if _sections.has(section_id):
			_sections[section_id].controls.append(full_key)
		return

	var control_type: String = config.get("type", "")
	var control_node: Control = null
	match control_type:
		"float", "int":
			control_node = _create_slider_control(full_key, config)
		"bool":
			control_node = _create_checkbox_control(full_key, config)
		"color":
			control_node = _create_color_control(full_key, config)
		"dropdown":
			control_node = _create_dropdown_control(full_key, config)
		"vector2":
			control_node = _create_vector2_control(full_key, config)
		"vector3":
			control_node = _create_vector3_control(full_key, config)
		"button":
			control_node = _create_button_control(full_key, config)
	if control_node == null:
		return
	_control_nodes[full_key] = control_node
	if _sections.has(section_id):
		var section_data: Dictionary = _sections[section_id]
		if control_type == "button":
			var flow: FlowContainer = _get_or_create_button_flow(section_data)
			flow.add_child(control_node)
		else:
			section_data.content.add_child(control_node)
		section_data.controls.append(full_key)


func unregister_section(section_id: String) -> void:
	if not _is_debug:
		return
	if not _sections.has(section_id):
		return
	var section_data: Dictionary = _sections[section_id]
	section_data.ref_count -= 1
	if section_data.ref_count <= 0:
		for ctrl_key in section_data.controls:
			_control_nodes.erase(ctrl_key)
			_control_configs.erase(ctrl_key)
		if _editor_mode:
			EngineDebugger.send_message("gdtuner:unregister_section", [section_id])
		elif section_data.container != null:
			section_data.container.queue_free()
		_sections.erase(section_id)


func copy_all_values_to_clipboard() -> void:
	if not _is_debug:
		return
	DisplayServer.clipboard_set(get_all_values_as_string())
	print("[gdtuner] Values copied to clipboard")


func get_all_values_as_string() -> String:
	var lines: PackedStringArray = []
	var datetime := Time.get_datetime_dict_from_system()
	lines.append("# gdtuner values — %04d-%02d-%02d %02d:%02d:%02d" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second
	])
	var keys := _values.keys()
	keys.sort()
	for key in keys:
		var val: Variant = _values[key]
		lines.append("%s = %s" % [key, _format_value(val)])
	return "\n".join(lines)


# --- UI Creation ---

func _build_content(parent: Control) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(margin)

	var outer_vbox := VBoxContainer.new()
	outer_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(outer_vbox)

	_tab_container = TabContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer_vbox.add_child(_tab_container)

	var btn_row := HBoxContainer.new()
	outer_vbox.add_child(btn_row)

	var copy_btn := Button.new()
	copy_btn.text = "Copy All Values"
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.pressed.connect(copy_all_values_to_clipboard)
	btn_row.add_child(copy_btn)

	var bake_btn := Button.new()
	bake_btn.text = "Bake to Source"
	bake_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake_btn.pressed.connect(bake_all_values)
	btn_row.add_child(bake_btn)


func _create_window() -> void:
	_window = Window.new()
	_window.title = "gdtuner"
	_window.size = Vector2i(380, 650)
	_window.unfocusable = true
	_window.always_on_top = true
	_window.wrap_controls = true
	_window.visible = false
	_window.close_requested.connect(func() -> void: _window.visible = false)
	var screen_size := DisplayServer.screen_get_size()
	_window.position = Vector2i(screen_size.x - _window.size.x - 50, 50)

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_window.add_child(panel)
	_build_content(panel)

	add_child(_window)


func _create_sheet() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 100
	_overlay.visible = false
	add_child(_overlay)

	# Full-screen dimmed background — tap to close
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventScreenTouch and event.pressed:
			_overlay.visible = false
	)
	_overlay.add_child(bg)

	# Bottom sheet panel — covers bottom 60% of screen
	_sheet = PanelContainer.new()
	_sheet.anchor_left = 0.0
	_sheet.anchor_right = 1.0
	_sheet.anchor_top = 0.4
	_sheet.anchor_bottom = 1.0
	_sheet.offset_left = 0.0
	_sheet.offset_right = 0.0
	_sheet.offset_top = 0.0
	_sheet.offset_bottom = 0.0
	var sheet_style := StyleBoxFlat.new()
	sheet_style.bg_color = Color(0.12, 0.12, 0.12, 0.95)
	sheet_style.corner_radius_top_left = 16
	sheet_style.corner_radius_top_right = 16
	_sheet.add_theme_stylebox_override("panel", sheet_style)
	_overlay.add_child(_sheet)

	# Drag handle at top
	var handle_container := VBoxContainer.new()
	handle_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	handle_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_sheet.add_child(handle_container)

	var handle_bar := ColorRect.new()
	handle_bar.color = Color(0.4, 0.4, 0.4, 1.0)
	handle_bar.custom_minimum_size = Vector2(40, 4)
	handle_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	var handle_margin := MarginContainer.new()
	handle_margin.add_theme_constant_override("margin_top", 8)
	handle_margin.add_theme_constant_override("margin_bottom", 4)
	handle_margin.add_child(handle_bar)
	handle_container.add_child(handle_margin)

	_build_content(handle_container)


# --- Section UI ---

func _build_section_ui(section_id: String, section_data: Dictionary) -> void:
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var content_margin := MarginContainer.new()
	content_margin.add_theme_constant_override("margin_left", 8)
	content_margin.add_theme_constant_override("margin_right", 8)
	content_margin.add_theme_constant_override("margin_top", 8)
	content_margin.add_theme_constant_override("margin_bottom", 8)
	content_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(content_margin)

	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_margin.add_child(content)

	scroll.name = section_data.display_name
	_tab_container.add_child(scroll)

	section_data.container = scroll
	section_data.header = null
	section_data.content = content


func _get_or_create_button_flow(section_data: Dictionary) -> FlowContainer:
	var content: VBoxContainer = section_data.content
	for child in content.get_children():
		if child is FlowContainer:
			return child
	var flow := FlowContainer.new()
	flow.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_child(flow)
	return flow


# --- Control Factories ---

func _create_slider_control(full_key: String, config: Dictionary) -> Control:
	if _is_mobile:
		return _create_stepper_control(full_key, config)

	var is_int: bool = config.get("type") == "int"
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var hbox := HBoxContainer.new()
	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)

	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	value_label.custom_minimum_size.x = 50
	value_label.text = _format_number(_values[full_key], is_int)
	hbox.add_child(value_label)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	hbox.add_child(reset_btn)
	vbox.add_child(hbox)

	var slider := HSlider.new()
	slider.min_value = config.get("min", 0.0)
	slider.max_value = config.get("max", 1.0)
	slider.step = config.get("step", 0.01 if not is_int else 1)
	slider.value = _values[full_key]
	slider.scrollable = false
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(slider)

	slider.value_changed.connect(func(val: float) -> void:
		var final_val: Variant = int(val) if is_int else val
		_set_value(full_key, final_val)
		value_label.text = _format_number(final_val, is_int)
	)

	reset_btn.pressed.connect(func() -> void:
		var def: Variant = _defaults[full_key]
		slider.value = def
		var final_val: Variant = int(def) if is_int else def
		_set_value(full_key, final_val)
		value_label.text = _format_number(final_val, is_int)
	)

	return vbox


func _create_stepper_control(full_key: String, config: Dictionary) -> Control:
	var is_int: bool = config.get("type") == "int"
	var min_val: float = config.get("min", 0.0)
	var max_val: float = config.get("max", 1.0)
	var step: float = config.get("step", 0.01 if not is_int else 1)
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)

	var minus_btn := Button.new()
	minus_btn.text = "-"
	minus_btn.custom_minimum_size = Vector2(44, 44)
	hbox.add_child(minus_btn)

	var value_label := Label.new()
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	value_label.custom_minimum_size.x = 60
	value_label.text = _format_number(_values[full_key], is_int)
	hbox.add_child(value_label)

	var plus_btn := Button.new()
	plus_btn.text = "+"
	plus_btn.custom_minimum_size = Vector2(44, 44)
	hbox.add_child(plus_btn)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(44, 44)
	hbox.add_child(reset_btn)

	var apply_step := func(direction: float) -> void:
		var current: float = _values[full_key]
		var new_val: float = clampf(current + step * direction, min_val, max_val)
		var final_val: Variant = int(new_val) if is_int else new_val
		_set_value(full_key, final_val)
		value_label.text = _format_number(final_val, is_int)

	minus_btn.pressed.connect(func() -> void: apply_step.call(-1.0))
	plus_btn.pressed.connect(func() -> void: apply_step.call(1.0))

	reset_btn.pressed.connect(func() -> void:
		var def: Variant = _defaults[full_key]
		var final_val: Variant = int(def) if is_int else def
		_set_value(full_key, final_val)
		value_label.text = _format_number(final_val, is_int)
	)

	return hbox


func _create_checkbox_control(full_key: String, config: Dictionary) -> Control:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)

	var checkbox := CheckBox.new()
	checkbox.button_pressed = _values[full_key]
	hbox.add_child(checkbox)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	hbox.add_child(reset_btn)

	checkbox.toggled.connect(func(val: bool) -> void:
		_set_value(full_key, val)
	)

	reset_btn.pressed.connect(func() -> void:
		var def: bool = _defaults[full_key]
		checkbox.button_pressed = def
		_set_value(full_key, def)
	)

	return hbox


func _create_color_control(full_key: String, config: Dictionary) -> Control:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)

	var picker := ColorPickerButton.new()
	picker.color = _values[full_key]
	picker.custom_minimum_size = Vector2(40, 28)
	hbox.add_child(picker)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	hbox.add_child(reset_btn)

	picker.color_changed.connect(func(val: Color) -> void:
		_set_value(full_key, val)
	)

	reset_btn.pressed.connect(func() -> void:
		var def: Color = _defaults[full_key]
		picker.color = def
		_set_value(full_key, def)
	)

	return hbox


func _create_dropdown_control(full_key: String, config: Dictionary) -> Control:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(label)

	var option_btn := OptionButton.new()
	var options: Array = config.get("options", [])
	for opt in options:
		option_btn.add_item(opt)
	var default_index: int = config.get("default_index", 0)
	option_btn.selected = default_index
	option_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(option_btn)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	hbox.add_child(reset_btn)

	option_btn.item_selected.connect(func(idx: int) -> void:
		var val: String = option_btn.get_item_text(idx)
		_set_value(full_key, val)
	)

	reset_btn.pressed.connect(func() -> void:
		option_btn.selected = default_index
		var val: String = option_btn.get_item_text(default_index)
		_set_value(full_key, val)
	)

	return hbox


func _create_vector2_control(full_key: String, config: Dictionary) -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	var btn_size := Vector2(44, 44) if _is_mobile else Vector2(28, 28)
	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = btn_size
	header.add_child(reset_btn)
	vbox.add_child(header)

	var current: Vector2 = _values[full_key]
	var min_val: Vector2 = config.get("min", Vector2.ZERO)
	var max_val: Vector2 = config.get("max", Vector2(100, 100))
	var step: float = config.get("step", 1.0)

	var value_labels: Array[Label] = []
	var axes := ["x", "y"]

	if _is_mobile:
		var axis_values: Array[float] = [current.x, current.y]
		var axis_mins: Array[float] = [min_val.x, min_val.y]
		var axis_maxs: Array[float] = [max_val.x, max_val.y]
		for i in 2:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var axis_label := Label.new()
			axis_label.text = "  %s:" % axes[i]
			axis_label.custom_minimum_size.x = 30
			row.add_child(axis_label)

			var minus_btn := Button.new()
			minus_btn.text = "-"
			minus_btn.custom_minimum_size = Vector2(44, 44)
			row.add_child(minus_btn)

			var val_label := Label.new()
			val_label.text = _format_number(axis_values[i], false)
			val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			val_label.custom_minimum_size.x = 60
			val_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(val_label)
			value_labels.append(val_label)

			var plus_btn := Button.new()
			plus_btn.text = "+"
			plus_btn.custom_minimum_size = Vector2(44, 44)
			row.add_child(plus_btn)

			var axis_idx := i
			minus_btn.pressed.connect(func() -> void:
				var vec: Vector2 = _values[full_key]
				vec[axes[axis_idx]] = clampf(vec[axes[axis_idx]] - step, axis_mins[axis_idx], axis_maxs[axis_idx])
				_set_value(full_key, vec)
				for j in 2:
					value_labels[j].text = _format_number(vec[axes[j]], false)
			)
			plus_btn.pressed.connect(func() -> void:
				var vec: Vector2 = _values[full_key]
				vec[axes[axis_idx]] = clampf(vec[axes[axis_idx]] + step, axis_mins[axis_idx], axis_maxs[axis_idx])
				_set_value(full_key, vec)
				for j in 2:
					value_labels[j].text = _format_number(vec[axes[j]], false)
			)
			vbox.add_child(row)
	else:
		var sliders: Array[HSlider] = []
		for i in 2:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var axis_label := Label.new()
			axis_label.text = "  %s:" % axes[i]
			axis_label.custom_minimum_size.x = 30
			row.add_child(axis_label)

			var slider := HSlider.new()
			slider.min_value = min_val[axes[i]]
			slider.max_value = max_val[axes[i]]
			slider.step = step
			slider.value = current[axes[i]]
			slider.scrollable = false
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(slider)
			sliders.append(slider)

			var val_label := Label.new()
			val_label.text = _format_number(current[axes[i]], false)
			val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			val_label.custom_minimum_size.x = 50
			row.add_child(val_label)
			value_labels.append(val_label)

			vbox.add_child(row)

		var update_fn := func(_val: float) -> void:
			var vec := Vector2(sliders[0].value, sliders[1].value)
			_set_value(full_key, vec)
			for j in 2:
				value_labels[j].text = _format_number(vec[axes[j]], false)
		for slider in sliders:
			slider.value_changed.connect(update_fn)

		reset_btn.pressed.connect(func() -> void:
			var def: Vector2 = _defaults[full_key]
			sliders[0].value = def.x
			sliders[1].value = def.y
			_set_value(full_key, def)
			value_labels[0].text = _format_number(def.x, false)
			value_labels[1].text = _format_number(def.y, false)
		)
		return vbox

	reset_btn.pressed.connect(func() -> void:
		var def: Vector2 = _defaults[full_key]
		_set_value(full_key, def)
		value_labels[0].text = _format_number(def.x, false)
		value_labels[1].text = _format_number(def.y, false)
	)

	return vbox


func _create_vector3_control(full_key: String, config: Dictionary) -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	var btn_size := Vector2(44, 44) if _is_mobile else Vector2(28, 28)
	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = btn_size
	header.add_child(reset_btn)
	vbox.add_child(header)

	var current: Vector3 = _values[full_key]
	var min_val: Vector3 = config.get("min", Vector3.ZERO)
	var max_val: Vector3 = config.get("max", Vector3(100, 100, 100))
	var step: float = config.get("step", 1.0)

	var value_labels: Array[Label] = []
	var axes := ["x", "y", "z"]

	if _is_mobile:
		var axis_values: Array[float] = [current.x, current.y, current.z]
		var axis_mins: Array[float] = [min_val.x, min_val.y, min_val.z]
		var axis_maxs: Array[float] = [max_val.x, max_val.y, max_val.z]
		for i in 3:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var axis_label := Label.new()
			axis_label.text = "  %s:" % axes[i]
			axis_label.custom_minimum_size.x = 30
			row.add_child(axis_label)

			var minus_btn := Button.new()
			minus_btn.text = "-"
			minus_btn.custom_minimum_size = Vector2(44, 44)
			row.add_child(minus_btn)

			var val_label := Label.new()
			val_label.text = _format_number(axis_values[i], false)
			val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			val_label.custom_minimum_size.x = 60
			val_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(val_label)
			value_labels.append(val_label)

			var plus_btn := Button.new()
			plus_btn.text = "+"
			plus_btn.custom_minimum_size = Vector2(44, 44)
			row.add_child(plus_btn)

			var axis_idx := i
			minus_btn.pressed.connect(func() -> void:
				var vec: Vector3 = _values[full_key]
				vec[axes[axis_idx]] = clampf(vec[axes[axis_idx]] - step, axis_mins[axis_idx], axis_maxs[axis_idx])
				_set_value(full_key, vec)
				for j in 3:
					value_labels[j].text = _format_number(vec[axes[j]], false)
			)
			plus_btn.pressed.connect(func() -> void:
				var vec: Vector3 = _values[full_key]
				vec[axes[axis_idx]] = clampf(vec[axes[axis_idx]] + step, axis_mins[axis_idx], axis_maxs[axis_idx])
				_set_value(full_key, vec)
				for j in 3:
					value_labels[j].text = _format_number(vec[axes[j]], false)
			)
			vbox.add_child(row)
	else:
		var sliders: Array[HSlider] = []
		for i in 3:
			var row := HBoxContainer.new()
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var axis_label := Label.new()
			axis_label.text = "  %s:" % axes[i]
			axis_label.custom_minimum_size.x = 30
			row.add_child(axis_label)

			var slider := HSlider.new()
			slider.min_value = min_val[axes[i]]
			slider.max_value = max_val[axes[i]]
			slider.step = step
			slider.value = current[axes[i]]
			slider.scrollable = false
			slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(slider)
			sliders.append(slider)

			var val_label := Label.new()
			val_label.text = _format_number(current[axes[i]], false)
			val_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			val_label.custom_minimum_size.x = 50
			row.add_child(val_label)
			value_labels.append(val_label)

			vbox.add_child(row)

		var update_fn := func(_val: float) -> void:
			var vec := Vector3(sliders[0].value, sliders[1].value, sliders[2].value)
			_set_value(full_key, vec)
			for j in 3:
				value_labels[j].text = _format_number(vec[axes[j]], false)
		for slider in sliders:
			slider.value_changed.connect(update_fn)

		reset_btn.pressed.connect(func() -> void:
			var def: Vector3 = _defaults[full_key]
			sliders[0].value = def.x
			sliders[1].value = def.y
			sliders[2].value = def.z
			_set_value(full_key, def)
			value_labels[0].text = _format_number(def.x, false)
			value_labels[1].text = _format_number(def.y, false)
			value_labels[2].text = _format_number(def.z, false)
		)
		return vbox

	reset_btn.pressed.connect(func() -> void:
		var def: Vector3 = _defaults[full_key]
		_set_value(full_key, def)
		value_labels[0].text = _format_number(def.x, false)
		value_labels[1].text = _format_number(def.y, false)
		value_labels[2].text = _format_number(def.z, false)
	)

	return vbox


func _create_button_control(full_key: String, config: Dictionary) -> Control:
	var btn := Button.new()
	btn.text = config.get("label", full_key.get_slice("/", 1))
	if _is_mobile:
		btn.custom_minimum_size = Vector2(0, 44)
	btn.pressed.connect(func() -> void:
		print("[gdtuner:action] %s pressed" % full_key)
		button_pressed.emit(full_key)
	)
	return btn


# --- Internal ---

func _set_value(key: String, value: Variant) -> void:
	_values[key] = value
	print("[gdtuner] %s = %s" % [key, _format_value(value)])
	value_changed.emit(key, value)
	if _editor_mode and not _suppress_editor_notify:
		EngineDebugger.send_message("gdtuner:value_changed", [key, var_to_str(value)])


func _format_value(val: Variant) -> String:
	if val is String:
		return '"%s"' % val
	if val is Color:
		return "Color(%s, %s, %s, %s)" % [val.r, val.g, val.b, val.a]
	if val is Vector2:
		return "Vector2(%s, %s)" % [val.x, val.y]
	if val is Vector3:
		return "Vector3(%s, %s, %s)" % [val.x, val.y, val.z]
	return str(val)


func _format_number(val: Variant, is_int: bool) -> String:
	if is_int:
		return str(int(val))
	return "%.2f" % val


# --- Bake to Source ---

func bake_all_values() -> void:
	if not _is_debug:
		return
	# Group controls by script path
	var script_controls: Dictionary = {}
	for section_id in _sections:
		var script_path: String = _section_scripts.get(section_id, "")
		if script_path.is_empty():
			continue
		var section_data: Dictionary = _sections[section_id]
		for full_key in section_data.controls:
			if not _control_configs.has(full_key):
				continue
			var config: Dictionary = _control_configs[full_key]
			if config.get("type", "") == "button":
				continue
			if not script_controls.has(script_path):
				script_controls[script_path] = []
			script_controls[script_path].append({
				"full_key": full_key,
				"config": config,
			})

	var files_modified := 0
	for script_path in script_controls:
		var file := FileAccess.open(script_path, FileAccess.READ)
		if file == null:
			print("[gdtuner] ERROR: Cannot read %s" % script_path)
			continue
		var source: String = file.get_as_text()
		file.close()

		var modified := false
		for entry in script_controls[script_path]:
			var full_key: String = entry.full_key
			var config: Dictionary = entry.config
			var key: String = full_key.get_slice("/", 1)
			var current_value: Variant = _values.get(full_key)
			var new_source := _bake_control_value(source, config, key, current_value)
			if new_source != source:
				source = new_source
				modified = true

		if modified:
			file = FileAccess.open(script_path, FileAccess.WRITE)
			if file:
				file.store_string(source)
				file.close()
				files_modified += 1
				print("[gdtuner] Baked values to %s" % script_path)

	print("[gdtuner] Bake complete — %d file(s) modified" % files_modified)


func _bake_control_value(source: String, config: Dictionary, key: String, value: Variant) -> String:
	# Try @export var pattern first (AutoTunable), fall back to add_* pattern (TunableRegistrar)
	var export_result := _bake_export_var(source, key, value)
	if export_result != source:
		return export_result
	return _bake_registrar_call(source, config, key, value)


func _bake_export_var(source: String, key: String, value: Variant) -> String:
	## Matches: @export var <key>: <type> = <old_value>
	## Also handles trailing colon for setter: @export var <key>: <type> = <old_value>:
	var lines := source.split("\n")
	var pattern := RegEx.new()
	pattern.compile("^(\\s*@export\\s+var\\s+" + key + "\\s*(?::\\s*\\w+)?\\s*=\\s*)(.+?)\\s*$")
	for i in range(lines.size()):
		var m := pattern.search(lines[i])
		if m == null:
			continue
		var prefix_str: String = m.get_string(1)
		var old_val: String = m.get_string(2)
		var has_setter: bool = old_val.ends_with(":")
		if has_setter:
			old_val = old_val.substr(0, old_val.length() - 1).strip_edges()
		var new_val := _format_bake_value(value)
		lines[i] = prefix_str + new_val + (":" if has_setter else "")
		return "\n".join(lines)
	return source


func _bake_registrar_call(source: String, config: Dictionary, key: String, value: Variant) -> String:
	## Legacy: matches add_float("key", ...) patterns from TunableRegistrar scripts.
	var control_type: String = config.get("type", "")
	var method_name: String
	var default_arg_index: int
	match control_type:
		"float":
			method_name = "add_float"
			default_arg_index = 3
		"int":
			method_name = "add_int"
			default_arg_index = 3
		"bool":
			method_name = "add_bool"
			default_arg_index = 1
		"color":
			method_name = "add_color"
			default_arg_index = 1
		"dropdown":
			method_name = "add_dropdown"
			default_arg_index = 2
		"vector2":
			method_name = "add_vector2"
			default_arg_index = 1
		"vector3":
			method_name = "add_vector3"
			default_arg_index = 1
		_:
			return source

	var regex := RegEx.new()
	regex.compile(method_name + '\\s*\\(\\s*"' + key + '"')
	var result := regex.search(source)
	if result == null:
		return source

	var paren_start := source.find("(", result.get_start())
	var paren_end := _find_matching_paren(source, paren_start)
	if paren_end < 0:
		return source

	var args_str := source.substr(paren_start + 1, paren_end - paren_start - 1)
	var args := _split_args(args_str)
	if default_arg_index >= args.size():
		return source

	var new_value_str := _format_bake_value(value)
	if control_type == "dropdown":
		var options: Array = config.get("options", [])
		var idx := options.find(value)
		new_value_str = str(maxi(idx, 0))

	var old_arg: String = args[default_arg_index]
	var trimmed := old_arg.strip_edges()
	var prefix_str := old_arg.substr(0, old_arg.find(trimmed))
	var suffix_str := old_arg.substr(old_arg.find(trimmed) + trimmed.length())
	args[default_arg_index] = prefix_str + new_value_str + suffix_str

	var new_args_str := ",".join(args)
	return source.substr(0, paren_start + 1) + new_args_str + source.substr(paren_end)


func _format_bake_value(value: Variant) -> String:
	if value is float:
		return str(value)
	if value is int:
		return str(value)
	if value is bool:
		return "true" if value else "false"
	if value is Color:
		return "Color(%s, %s, %s, %s)" % [value.r, value.g, value.b, value.a]
	if value is Vector2:
		return "Vector2(%s, %s)" % [value.x, value.y]
	if value is Vector3:
		return "Vector3(%s, %s, %s)" % [value.x, value.y, value.z]
	return str(value)


func _find_matching_paren(source: String, open_pos: int) -> int:
	var depth := 0
	for i in range(open_pos, source.length()):
		var ch: String = source[i]
		if ch == "(" or ch == "[":
			depth += 1
		elif ch == ")" or ch == "]":
			depth -= 1
			if depth == 0:
				return i
	return -1


func _split_args(args_str: String) -> Array[String]:
	var args: Array[String] = []
	var depth := 0
	var in_string := false
	var current := ""
	var prev_ch := ""
	for i in range(args_str.length()):
		var ch: String = args_str[i]
		if ch == '"' and prev_ch != "\\":
			in_string = not in_string
			current += ch
		elif in_string:
			current += ch
		elif ch == "(" or ch == "[":
			depth += 1
			current += ch
		elif ch == ")" or ch == "]":
			depth -= 1
			current += ch
		elif ch == "," and depth == 0:
			args.append(current)
			current = ""
		else:
			current += ch
		prev_ch = ch
	if not current.is_empty():
		args.append(current)
	return args
