extends CanvasLayer

## 屏幕上直接看得见的调参小面板：只放最常动的三根滑条（最高车速 / 镜头距离 / 镜头高度）。
##
## 为什么要有这个东西：GDTuner（按键 F12 弹出的独立窗口）能调全部 14 个参数，
## 但它藏在快捷键后面，调个车速要按 F12、找窗口、拖滑条，来回几次很烦。
## 这个面板就是给"我就想改个速度试试"用的最小切口。
##
## 分工：
##   - 这个面板：看得见、点得到，Tab 收起
##   - GDTuner：参数全（抓地、转向、FOV、视点前瞻、刹车距离…），F12 打开
##   - tools/bake_tuning.gd：把面板上定好的值永久写回脚本默认值
##
## 挂在 autoload 上（project.godot 的 [autoload]），所以不用改任何 .tscn。

const MS_TO_KMH: float = 3.6

var _vehicle: Node = null
var _view: Node = null
var _bound: bool = false
var _updating: bool = false
var _shown: bool = true
var _tab_held: bool = false

var _panel: PanelContainer = null

# 属性名 -> [滑条, 值标签]，建面板时顺手记下来
var _rows: Dictionary = {}

func _ready() -> void:
	layer = 128
	_build_ui()
	get_tree().scene_changed.connect(_on_scene_changed)

func _process(_delta: float) -> void:
	# 场景还没切过来时 current_scene 可能是 null，等它出现再绑
	if not _bound:
		_bind_targets()
	var tab: bool = Input.is_key_pressed(KEY_TAB)
	if tab and not _tab_held:
		_toggle()
	_tab_held = tab

## ---------- 场景绑定 ----------

func _on_scene_changed() -> void:
	_bound = false

func _bind_targets() -> void:
	var scene: Node = get_tree().current_scene
	# 手动 instantiate 出来的场景 current_scene 是空的，回退到 root 找一遍，别绑不上
	if scene == null:
		scene = get_tree().root
	# 不能直接用 find_child("Vehicle")：GDTuner / 选车界面里也有叫 Vehicle、View 的同名节点，
	# 命中 UI 控件的话 get() 返回 nil。所以认名字的同时校验它真有目标属性。
	_vehicle = _find_prop(scene, "Vehicle", "max_speed")
	_view = _find_prop(scene, "View", "distance")
	# 没车没镜头的场景（比如选车菜单）先把面板藏掉，等找到目标再自己弹出来
	if _panel != null:
		_panel.visible = _shown and _vehicle != null and _view != null
	if _vehicle == null and _view == null:
		return
	_bound = true
	if OS.is_debug_build():
		print("TuneHud: 已绑到 " + str(_vehicle) + " / " + str(_view))
	_updating = true
	if _vehicle != null:
		_set_slider("max_speed", _vehicle.get("max_speed"))
	if _view != null:
		_set_slider("distance", _view.get("distance"))
		_set_slider("height", _view.get("height"))
	_updating = false

## 广度优先找「名字对得上，而且真的有这个属性」的节点
func _find_prop(from: Node, name: String, prop: String) -> Node:
	var queue: Array = [from]
	while not queue.is_empty():
		var n = queue.pop_back()
		if n.name == name and _has_prop(n, prop):
			return n
		for c in n.get_children():
			queue.append(c)
	return null

func _has_prop(n: Node, prop: String) -> bool:
	for p in n.get_property_list():
		if p.name == prop:
			return true
	return false

func _toggle() -> void:
	_shown = not _shown
	if _panel != null:
		_panel.visible = _shown and _vehicle != null and _view != null

## ---------- 面板 ----------

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_panel.offset_left = 14.0
	_panel.offset_top = -12.0
	add_child(_panel)

	var margin := MarginContainer.new()
	_panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	margin.add_child(box)

	var title := Label.new()
	title.text = "调参  ·  [Tab] 收起  ·  [F12] 全部参数"
	box.add_child(title)

	_add_row(box, "最高车速", 4.0, 60.0, 0.5, "max_speed")
	_add_row(box, "镜头距离", 0.5, 12.0, 0.1, "distance")
	_add_row(box, "镜头高度", 0.3, 4.0, 0.05, "height")

	# 提示文字故意写短：Label 的 autowrap 枚举在 TextServer 下（Control.AUTOWrap 不存在），省得再踩
	var hint := Label.new()
	hint.text = "拖完立刻生效；想永久保存就跑 tools/bake_tuning.gd"
	box.add_child(hint)

func _add_row(parent: Node, name_text: String, mn: float, mx: float, stp: float, prop: String) -> void:
	var row := HBoxContainer.new()
	parent.add_child(row)

	var name_l := Label.new()
	name_l.text = name_text
	name_l.custom_minimum_size = Vector2(84.0, 0.0)
	row.add_child(name_l)

	var slider := HSlider.new()
	slider.min_value = mn
	slider.max_value = mx
	slider.step = stp
	slider.custom_minimum_size = Vector2(170.0, 0.0)
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(slider)

	var value_l := Label.new()
	value_l.custom_minimum_size = Vector2(84.0, 0.0)
	value_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(value_l)

	_rows[prop] = [slider, value_l]
	slider.value_changed.connect(Callable(self, "_on_row_changed").bind(prop))
	# 面板没绑上车时先别显示，免得拖了没反应
	slider.value = mn

func _on_row_changed(v: float, prop: String) -> void:
	if _updating:
		return
	var target: Node = _vehicle if prop == "max_speed" else _view
	if target == null:
		return
	target.set(prop, v)
	_refresh_value(prop, v)

func _refresh_value(prop: String, v: float) -> void:
	if not _rows.has(prop):
		return
	var lbl: Label = _rows[prop][1]
	if prop == "max_speed":
		lbl.text = "%.0f km/h" % (v * MS_TO_KMH)
	else:
		lbl.text = "%.2f m" % v

func _set_slider(prop: String, value: float) -> void:
	if not _rows.has(prop):
		return
	var slider: HSlider = _rows[prop][0]
	_updating = true
	slider.value = value
	_updating = false
	_refresh_value(prop, value)
