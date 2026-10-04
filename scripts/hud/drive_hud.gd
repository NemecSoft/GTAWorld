extends CanvasLayer

## #31 驾驶 HUD：只在「正开着车」时出现的右下角速度 / 档位面板。
##
## 为什么不塞进 tune_hud：tune_hud 是给开发者调手感的工具（Tab 收起、14 个滑条藏在
## GDTuner 里），这个是玩家界面，两者生命周期和样式完全不同，混在一起迟早互相拖累。
##
## 进度条画的是「当前速度 ÷ 本档实际上限」，上限取 gear_top_mps()（已含驾驶训练
## 倍率与战损降速），所以血掉光时条子会跟着缩，不会出现「条满了速度还在爬」。

const MS_TO_KMH: float = 3.6

@export var margin: float = 16.0
@export var panel_w: float = 208.0
@export var panel_h: float = 86.0

var _game: Node3D = null
var _car: Node3D = null
var _panel: PanelContainer = null
var _lbl_speed: Label = null
var _lbl_gear: Label = null
var _lbl_top: Label = null
var _keys: Label = null
var _bar: ProgressBar = null


func _ready() -> void:
	layer = 2
	_game = get_parent() as Node3D

	_panel = PanelContainer.new()
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_panel.offset_left = -panel_w - margin
	_panel.offset_top = -panel_h - margin
	_panel.offset_right = -margin
	_panel.offset_bottom = -margin
	add_child(_panel)

	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.06, 0.08, 0.11, 0.72)
	bg.corner_radius_top_left = 6
	bg.corner_radius_top_right = 6
	bg.corner_radius_bottom_left = 6
	bg.corner_radius_bottom_right = 6
	bg.content_margin_left = 12.0
	bg.content_margin_right = 12.0
	bg.content_margin_top = 8.0
	bg.content_margin_bottom = 8.0
	_panel.add_theme_stylebox_override("panel", bg)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 2)
	_panel.add_child(col)

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 8)
	col.add_child(row)

	_lbl_speed = Label.new()
	_lbl_speed.text = "0"
	_lbl_speed.add_theme_font_size_override("font_size", 34)
	_lbl_speed.add_theme_color_override("font_color", Color(1.0, 0.84, 0.25, 1.0))
	row.add_child(_lbl_speed)

	var unit := Label.new()
	unit.text = "km/h"
	unit.add_theme_font_size_override("font_size", 13)
	unit.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9, 0.85))
	unit.size_flags_vertical = Control.SIZE_SHRINK_END
	row.add_child(unit)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(spacer)

	_lbl_gear = Label.new()
	_lbl_gear.text = "N"
	_lbl_gear.add_theme_font_size_override("font_size", 30)
	_lbl_gear.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0, 1.0))
	row.add_child(_lbl_gear)

	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.001
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 7)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_bar)

	_lbl_top = Label.new()
	_lbl_top.text = "本档 -- km/h"
	_lbl_top.add_theme_font_size_override("font_size", 11)
	_lbl_top.add_theme_color_override("font_color", Color(0.75, 0.8, 0.86, 0.7))
	col.add_child(_lbl_top)

	# 键位提示是死文字，单独一行常驻：以前和「本档 xx km/h」挤一行，
	# 那行把面板最小宽度撑到 240+，面板就从右边缘往屏幕外长，档位数字被切掉一半。
	_keys = Label.new()
	_keys.text = "1/2/3 换挡 · Z 倒档 · X 空档"
	_keys.add_theme_font_size_override("font_size", 10)
	_keys.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82, 0.55))
	col.add_child(_keys)

	# 面板宽度按内容实际需要的宽度从右往左算，不写死 panel_w
	var need: Vector2 = _panel.get_combined_minimum_size()
	_panel.offset_left = -margin - maxf(panel_w, need.x)


func _process(_delta: float) -> void:
	var car: Node3D = null
	if _game != null:
		car = _game.get("_driving") as Node3D
	if car != _car:
		_car = car
		# 上车先回到「起步档」。放在这里而不是改 urban_game.enter_vehicle：
		# 摘挂档是玩家界面的规矩，不该让场景脚本来管车辆内部状态。
		if car != null and car.has_method("shift_to"):
			car.call("shift_to", int(car.get("start_gear")))
	if _car == null or not is_instance_valid(_car) or not _car.has_method("get_speed_mps"):
		_panel.visible = false
		return
	_panel.visible = true

	var mps: float = float(_car.call("get_speed_mps"))
	var top: float = float(_car.call("gear_top_mps"))
	var label: String = String(_car.call("gear_label"))
	_lbl_speed.text = str(int(round(mps * MS_TO_KMH)))
	_lbl_gear.text = label
	# 倒档时数字前挂个负号，比只写个 R 更容易一眼看出在往后退
	if label == "R":
		_lbl_speed.text = "-" + _lbl_speed.text
	_lbl_gear.add_theme_color_override("font_color", _gear_color(label))
	if top > 0.05:
		_bar.value = clampf(mps / top, 0.0, 1.0)
		_lbl_top.text = "本档 %.0f km/h" % (top * MS_TO_KMH)
	else:
		_bar.value = 0.0
		_lbl_top.text = "空档 N（无动力）"


func _gear_color(label: String) -> Color:
	if label == "R":
		return Color(1.0, 0.42, 0.38, 1.0)
	if label == "N":
		return Color(0.75, 0.78, 0.82, 1.0)
	return Color(0.55, 0.95, 1.0, 1.0)
