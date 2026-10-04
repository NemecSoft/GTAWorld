@tool
extends VBoxContainer

signal request_set_value(full_key: String, value_str: String)
signal request_press_button(full_key: String)
signal request_bake()

var _tab_container: TabContainer = null
var _status_label: Label = null
var _toolbar: HBoxContainer = null
var _sections: Dictionary = {}
var _values: Dictionary = {}
var _defaults: Dictionary = {}
var _control_configs: Dictionary = {}
var _widgets: Dictionary = {}  # full_key -> { "type", ... widget refs }
var _updating_from_remote: bool = false


func _ready() -> void:
	_build_layout()
	_show_status()


func _build_layout() -> void:
	_status_label = Label.new()
	_status_label.text = "Run your game to see tunables here."
	_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_status_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_status_label)

	_tab_container = TabContainer.new()
	_tab_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab_container.visible = false
	add_child(_tab_container)

	_toolbar = HBoxContainer.new()
	_toolbar.visible = false
	add_child(_toolbar)

	var copy_btn := Button.new()
	copy_btn.text = "Copy All Values"
	copy_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	copy_btn.pressed.connect(_on_copy_pressed)
	_toolbar.add_child(copy_btn)

	var bake_btn := Button.new()
	bake_btn.text = "Bake to Source"
	bake_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bake_btn.pressed.connect(func() -> void: request_bake.emit())
	_toolbar.add_child(bake_btn)


func _show_status() -> void:
	_status_label.visible = true
	_tab_container.visible = false
	_toolbar.visible = false


func _show_controls() -> void:
	_status_label.visible = false
	_tab_container.visible = true
	_toolbar.visible = true


func session_started() -> void:
	_clear_all()
	_show_controls()


func session_stopped() -> void:
	_clear_all()
	_show_status()


func _clear_all() -> void:
	for child in _tab_container.get_children():
		child.queue_free()
	_sections.clear()
	_values.clear()
	_defaults.clear()
	_control_configs.clear()
	_widgets.clear()


func _on_copy_pressed() -> void:
	var lines: PackedStringArray = []
	var datetime := Time.get_datetime_dict_from_system()
	lines.append("# gdtuner values — %04d-%02d-%02d %02d:%02d:%02d" % [
		datetime.year, datetime.month, datetime.day,
		datetime.hour, datetime.minute, datetime.second,
	])
	var keys := _values.keys()
	keys.sort()
	for key in keys:
		var val: Variant = _values[key]
		lines.append("%s = %s" % [key, _format_value(val)])
	DisplayServer.clipboard_set("\n".join(lines))


# --- Handlers called by tuner_debugger ---

func handle_register_section(section_id: String, display_name: String) -> void:
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
	_build_section_ui(section_id, section_data)
	_sections[section_id] = section_data


func handle_register_control(section_id: String, key: String, config: Dictionary) -> void:
	var full_key := section_id + "/" + key
	if _control_configs.has(full_key):
		return
	var default_value: Variant = config.get("default")
	_defaults[full_key] = default_value
	if not _values.has(full_key):
		_values[full_key] = default_value
	_control_configs[full_key] = config

	var control_type: String = config.get("type", "")
	var control_node: Control = null
	match control_type:
		"float", "int":
			control_node = _create_slider(full_key, config)
		"bool":
			control_node = _create_checkbox(full_key, config)
		"color":
			control_node = _create_color(full_key, config)
		"dropdown":
			control_node = _create_dropdown(full_key, config)
		"vector2":
			control_node = _create_vector2(full_key, config)
		"vector3":
			control_node = _create_vector3(full_key, config)
		"button":
			control_node = _create_button(full_key, config)
	if control_node == null:
		return

	if _sections.has(section_id):
		var section_data: Dictionary = _sections[section_id]
		if control_type == "button":
			var flow: FlowContainer = _get_or_create_button_flow(section_data)
			flow.add_child(control_node)
		else:
			section_data.content.add_child(control_node)
		section_data.controls.append(full_key)


func handle_value_changed(full_key: String, value: Variant) -> void:
	_values[full_key] = value
	if not _widgets.has(full_key):
		return
	_updating_from_remote = true
	var w: Dictionary = _widgets[full_key]
	var t: String = w.get("type", "")
	match t:
		"float", "int":
			var is_int: bool = t == "int"
			w.slider.value = value
			w.value_label.text = _format_number(value, is_int)
		"bool":
			w.checkbox.button_pressed = value
		"color":
			w.picker.color = value
		"dropdown":
			var options: Array = _control_configs[full_key].get("options", [])
			var idx := options.find(value)
			if idx >= 0:
				w.option_btn.selected = idx
		"vector2":
			for i in 2:
				var axis: String = ["x", "y"][i]
				w.sliders[i].value = value[axis]
				w.value_labels[i].text = _format_number(value[axis], false)
		"vector3":
			for i in 3:
				var axis: String = ["x", "y", "z"][i]
				w.sliders[i].value = value[axis]
				w.value_labels[i].text = _format_number(value[axis], false)
	_updating_from_remote = false


func handle_unregister_section(section_id: String) -> void:
	if not _sections.has(section_id):
		return
	var section_data: Dictionary = _sections[section_id]
	section_data.ref_count -= 1
	if section_data.ref_count <= 0:
		for ctrl_key in section_data.controls:
			_widgets.erase(ctrl_key)
			_control_configs.erase(ctrl_key)
		if section_data.container != null:
			section_data.container.queue_free()
		_sections.erase(section_id)


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

func _create_slider(full_key: String, config: Dictionary) -> Control:
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

	_widgets[full_key] = { "type": config.get("type"), "slider": slider, "value_label": value_label }

	slider.value_changed.connect(func(val: float) -> void:
		if _updating_from_remote:
			return
		var final_val: Variant = int(val) if is_int else val
		_values[full_key] = final_val
		value_label.text = _format_number(final_val, is_int)
		request_set_value.emit(full_key, var_to_str(final_val))
	)

	reset_btn.pressed.connect(func() -> void:
		var def: Variant = _defaults[full_key]
		slider.value = def
		var final_val: Variant = int(def) if is_int else def
		_values[full_key] = final_val
		value_label.text = _format_number(final_val, is_int)
		request_set_value.emit(full_key, var_to_str(final_val))
	)

	return vbox


func _create_checkbox(full_key: String, config: Dictionary) -> Control:
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

	_widgets[full_key] = { "type": "bool", "checkbox": checkbox }

	checkbox.toggled.connect(func(val: bool) -> void:
		if _updating_from_remote:
			return
		_values[full_key] = val
		request_set_value.emit(full_key, var_to_str(val))
	)

	reset_btn.pressed.connect(func() -> void:
		var def: bool = _defaults[full_key]
		checkbox.button_pressed = def
		_values[full_key] = def
		request_set_value.emit(full_key, var_to_str(def))
	)

	return hbox


func _create_color(full_key: String, config: Dictionary) -> Control:
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

	_widgets[full_key] = { "type": "color", "picker": picker }

	picker.color_changed.connect(func(val: Color) -> void:
		if _updating_from_remote:
			return
		_values[full_key] = val
		request_set_value.emit(full_key, var_to_str(val))
	)

	reset_btn.pressed.connect(func() -> void:
		var def: Color = _defaults[full_key]
		picker.color = def
		_values[full_key] = def
		request_set_value.emit(full_key, var_to_str(def))
	)

	return hbox


func _create_dropdown(full_key: String, config: Dictionary) -> Control:
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

	_widgets[full_key] = { "type": "dropdown", "option_btn": option_btn }

	option_btn.item_selected.connect(func(idx: int) -> void:
		if _updating_from_remote:
			return
		var val: String = option_btn.get_item_text(idx)
		_values[full_key] = val
		request_set_value.emit(full_key, var_to_str(val))
	)

	reset_btn.pressed.connect(func() -> void:
		option_btn.selected = default_index
		var val: String = option_btn.get_item_text(default_index)
		_values[full_key] = val
		request_set_value.emit(full_key, var_to_str(val))
	)

	return hbox


func _create_vector2(full_key: String, config: Dictionary) -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	header.add_child(reset_btn)
	vbox.add_child(header)

	var current: Vector2 = _values[full_key]
	var min_val: Vector2 = config.get("min", Vector2.ZERO)
	var max_val: Vector2 = config.get("max", Vector2(100, 100))
	var step: float = config.get("step", 1.0)
	var axes := ["x", "y"]

	var sliders: Array[HSlider] = []
	var value_labels: Array[Label] = []
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

	_widgets[full_key] = { "type": "vector2", "sliders": sliders, "value_labels": value_labels }

	var update_fn := func(_val: float) -> void:
		if _updating_from_remote:
			return
		var vec := Vector2(sliders[0].value, sliders[1].value)
		_values[full_key] = vec
		for j in 2:
			value_labels[j].text = _format_number(vec[axes[j]], false)
		request_set_value.emit(full_key, var_to_str(vec))
	for slider in sliders:
		slider.value_changed.connect(update_fn)

	reset_btn.pressed.connect(func() -> void:
		var def: Vector2 = _defaults[full_key]
		sliders[0].value = def.x
		sliders[1].value = def.y
		_values[full_key] = def
		value_labels[0].text = _format_number(def.x, false)
		value_labels[1].text = _format_number(def.y, false)
		request_set_value.emit(full_key, var_to_str(def))
	)

	return vbox


func _create_vector3(full_key: String, config: Dictionary) -> Control:
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var header := HBoxContainer.new()
	var label := Label.new()
	label.text = config.get("label", full_key.get_slice("/", 1))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(label)

	var reset_btn := Button.new()
	reset_btn.text = "↺"
	reset_btn.custom_minimum_size = Vector2(28, 28)
	header.add_child(reset_btn)
	vbox.add_child(header)

	var current: Vector3 = _values[full_key]
	var min_val: Vector3 = config.get("min", Vector3.ZERO)
	var max_val: Vector3 = config.get("max", Vector3(100, 100, 100))
	var step: float = config.get("step", 1.0)
	var axes := ["x", "y", "z"]

	var sliders: Array[HSlider] = []
	var value_labels: Array[Label] = []
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

	_widgets[full_key] = { "type": "vector3", "sliders": sliders, "value_labels": value_labels }

	var update_fn := func(_val: float) -> void:
		if _updating_from_remote:
			return
		var vec := Vector3(sliders[0].value, sliders[1].value, sliders[2].value)
		_values[full_key] = vec
		for j in 3:
			value_labels[j].text = _format_number(vec[axes[j]], false)
		request_set_value.emit(full_key, var_to_str(vec))
	for slider in sliders:
		slider.value_changed.connect(update_fn)

	reset_btn.pressed.connect(func() -> void:
		var def: Vector3 = _defaults[full_key]
		sliders[0].value = def.x
		sliders[1].value = def.y
		sliders[2].value = def.z
		_values[full_key] = def
		value_labels[0].text = _format_number(def.x, false)
		value_labels[1].text = _format_number(def.y, false)
		value_labels[2].text = _format_number(def.z, false)
		request_set_value.emit(full_key, var_to_str(def))
	)

	return vbox


func _create_button(full_key: String, config: Dictionary) -> Control:
	var btn := Button.new()
	btn.text = config.get("label", full_key.get_slice("/", 1))
	btn.pressed.connect(func() -> void:
		request_press_button.emit(full_key)
	)
	return btn


# --- Formatting ---

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
