extends Control
## 开局先选地图。
##
## 这一屏是纯代码搭的 UI（不拖场景节点），规矩如下：
##   · 整屏居中，左右各一张「地图卡」，卡里是这张地图的真实预览图
##   · 整张卡都能点：鼠标手型 + 悬停高亮 + 按下即可进图
##   · 键盘 1 / 2 等价点击，Enter / 空格进当前悬停的那张（没悬停就进第一张）
##
## 为什么卡片用 Panel 而不是 PanelContainer：PanelContainer 是 Container，
## 会把子控件竖着排开 —— 铺满整张卡的点击层会被挤到卡片下半截。Panel 只画
## 样式框、不管子控件布局，正好要的就是「一层底板 + 自由叠控件」。
##
## 现在只有一张卡：地图 1（res://scenes/main.tscn）。
## 地图 1 的场景是 scenes/main.tscn：默认用 mapgen.gd 进图现拼一条随机闭环赛道（GridMap 摆 mesh-library 的 tile），
## 进图就是原样那一条环路 —— 想看随机赛道，去 GridMap 节点勾一下 mapgen.gd 的
## 「Replace Map」，那些随机赛道才会在运行时铺上来。选图页只负责把人送进去。
## preview_map1.png 是 vendor 原赛道截图（风格基准：绿草 + 深灰柏油环 + 树/帐篷）。
##
## 这一屏现在是「选车 + 选地图」两步合一：
##   · 上面一排车卡（车库列表，见 autoload Garage）→ 点了只是**选中**，不切场景
##   · 下面那张地图卡 → 点了直接进图，开的是**当前选中**的那台车
##   · 车和地图的选择写在 Garage 里，进图后由 main.tscn 的 Garage 节点
##     （scripts/world/vehicle_picker.gd）照着换掉玩家那台车。
## 车卡的预览图是 headless 探针烘出来的 PNG（ui/preview_*.png），
## 不是实时渲染 —— 实时渲染要开 SubViewport，本项目那个路径在这个 build 上是坏的。

@export_group("地图")
@export var scene_map1: String = "res://scenes/main.tscn"
@export var scene_map2: String = "res://scenes/urban.tscn"

@export_group("预览图")
@export_file("*.png") var preview_map1: String = "res://ui/preview_map1.png"
@export_file("*.png") var preview_map2: String = "res://ui/preview_map2.png"

const ACCENT := Color("#5aa9ff")   # 悬停/选中的描边 / 序号底色
const CARD_W := 560                # 地图卡宽（1280×720 下放得下两张 + 间隙）
const CARD_H := 430                # 地图卡高：Panel 不是 Container，量不出内容高度，只能固定
const SHOT_H := 244                # 地图预览图高度
const VEH_W := 290                 # 车卡宽
const VEH_H := 132                 # 车卡高（预览图压扁 + 一行字，别抢地图的视觉重量）

var _cards: Array = []             # [卡片, 场景路径]
var _hovered: Panel = null         # 当前鼠标悬停的那张卡（Enter / 空格用它）
var _veh_cards: Array = []         # [卡片, 车款 id]，见 _select_vehicle


func _ready() -> void:

	_build_ui()
	# 把车库里已经记着的那台（比如上一次选过摩托）在 UI 上点亮
	_select_vehicle(Garage.selected_id)


# ------------------------------------------------------------------ 布局

func _build_ui() -> void:

	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 底：深蓝灰，比纯黑耐看，也不抢预览图
	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.color = Color("#0b0e14")
	add_child(bg)

	var root_vb := VBoxContainer.new()
	root_vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	root_vb.alignment = BoxContainer.ALIGNMENT_CENTER
	root_vb.add_theme_constant_override("separation", 30)
	root_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root_vb)

	root_vb.add_child(_build_head())

	root_vb.add_child(_build_vehicle_section())

	root_vb.add_child(_build_section_label("选择地图", 22))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 30)
	root_vb.add_child(row)

	row.add_child(_make_card({
		"scene": scene_map1, "preview": preview_map1, "num": "1",
		"title": "随机赛道",
		"sub": "进图现拼一条闭环：直道 + 转角 + 终点门 + 外圈林地帐篷。seed 相同就一模一样，换 seed 就是一张新图",
		"tags": ["程序生成", "闭环赛道", "终点门", "森林"],
	}))

	row.add_child(_make_card({
		"scene": scene_map2, "preview": preview_map2, "num": "2",
		"title": "洛圣都城区",
		"sub": "Kenney 画风开放世界的第一块城区：人物走跑跳 + 走到车旁按 E 上车开走。棋盘路网 + city-kit 建筑，Phase 1",
		"tags": ["开放世界", "人物", "上下车", "建造/生存后续"],
	}))

	root_vb.add_child(_build_foot())


func _build_section_label(txt: String, fs: int) -> Label:
	var l := Label.new()
	l.text = txt
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", Color("#8fa2ba"))
	return l


# ------------------------------------------------------------------ 选车

func _build_vehicle_section() -> Control:

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 12)

	box.add_child(_build_section_label("选择车辆", 22))

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)

	# 目录在 autoload Garage 里。tools/ 下的工具脚本也能 preload 它直读
	for d in Garage.CATALOG:
		row.add_child(_make_vehicle_card(d))

	return box


func _make_vehicle_card(d: Dictionary) -> Panel:

	var card := Panel.new()
	card.custom_minimum_size = Vector2(VEH_W, VEH_H)
	card.pivot_offset = Vector2(VEH_W / 2.0, VEH_H / 2.0)
	card.mouse_filter = Control.MOUSE_FILTER_PASS

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#12161d")
	sb.set_border_width_all(2)
	sb.border_color = Color("#262e3a")
	sb.set_corner_radius_all(14)
	sb.content_margin_left = 12
	sb.content_margin_right = 12
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	card.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 6)
	card.add_child(vb)

	# 预览图：烘好的 PNG（探针离线渲染，不占运行时渲染通道）
	var tex: Texture2D = load(String(d["preview"]))
	if tex != null:
		var tr := TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.texture = tex
		vb.add_child(tr)
	else:
		push_warning("[select] 车预览图没读到：" + String(d["preview"]))
		var ph := ColorRect.new()
		ph.set_anchors_preset(Control.PRESET_FULL_RECT)
		ph.color = Color("#111725")
		vb.add_child(ph)

	var name_l := Label.new()
	name_l.text = String(d["name"])
	name_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_l.add_theme_font_size_override("font_size", 20)
	name_l.add_theme_color_override("font_color", Color("#f4f7fb"))
	vb.add_child(name_l)

	# 点一下只是「选中」，不切场景 —— 车是进图之后才换的（见 vehicle_picker.gd）
	var hit := Button.new()
	hit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hit.flat = true
	hit.text = ""
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	var vid := String(d["id"])
	hit.pressed.connect(func() -> void: _select_vehicle(vid))
	hit.mouse_entered.connect(func() -> void: _set_hover(card, true))
	hit.mouse_exited.connect(func() -> void: _set_hover(card, false))
	card.add_child(hit)

	card.set_meta("sb", sb)
	_veh_cards.append([card, vid])

	# 入场淡入
	var tw := create_tween().set_parallel(true)
	tw.tween_property(card, "modulate", Color(1, 1, 1, 1), 0.36).set_trans(Tween.TRANS_BACK)
	tw.tween_property(card, "scale", Vector2(1, 1), 0.36).from(Vector2(0.94, 0.94))

	return card


func _select_vehicle(p_id: String) -> void:

	if not Garage.select_vehicle(p_id):
		return
	for c in _veh_cards:
		var on: bool = String(c[1]) == p_id
		var sb: StyleBoxFlat = c[0].get_meta("sb")
		if sb != null:
			sb.bg_color = Color("#17202b") if on else Color("#12161d")
			sb.border_color = ACCENT if on else Color("#262e3a")
			sb.set_border_width_all(3 if on else 2)


func _build_head() -> Control:

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var title := Label.new()
	title.text = "选择地图"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_color", Color("#f4f7fb"))
	box.add_child(title)

	var sub := Label.new()
	sub.text = "SELECT A MAP"
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.add_theme_font_size_override("font_size", 17)
	sub.add_theme_color_override("font_color", Color("#6d7b8d"))
	box.add_child(sub)

	return box


func _build_foot() -> Control:

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var tip := Label.new()
	tip.text = "鼠标点卡片就能进 · 也可以按 1"
	tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tip.add_theme_font_size_override("font_size", 20)
	tip.add_theme_color_override("font_color", Color("#c3cede"))
	box.add_child(tip)

	var keys := Label.new()
	keys.text = "进去后：W / S 油门刹车，A / D 转向，空格跳一下，鼠标滚轮调跟车距离；Tab 开调参面板，F12 开完整滑条"
	keys.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	keys.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	keys.add_theme_font_size_override("font_size", 16)
	keys.add_theme_color_override("font_color", Color("#7d8899"))
	box.add_child(keys)

	# 开跑按钮：选中什么车、进哪张图全按当前状态来
	var go := Button.new()
	go.text = "进入赛道  →"
	go.custom_minimum_size = Vector2(320, 58)
	go.alignment = HORIZONTAL_ALIGNMENT_CENTER
	go.add_theme_font_size_override("font_size", 24)
	box.add_child(go)
	go.pressed.connect(func() -> void: _hovered_scene())

	return box


# ------------------------------------------------------------------ 一张地图卡

func _make_card(m: Dictionary) -> Panel:

	var card := Panel.new()
	card.custom_minimum_size = Vector2(CARD_W, CARD_H)
	card.pivot_offset = Vector2(CARD_W / 2.0, CARD_H / 2.0)
	card.modulate = Color(1, 1, 1, 0)          # 入场淡入
	card.mouse_filter = Control.MOUSE_FILTER_PASS

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#12161d")
	sb.set_border_width_all(2)
	sb.border_color = Color("#262e3a")
	sb.set_corner_radius_all(16)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 15
	sb.content_margin_bottom = 15
	card.add_theme_stylebox_override("panel", sb)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.add_theme_constant_override("separation", 10)
	card.add_child(vb)                          # 先放内容

	vb.add_child(_make_shot(String(m["preview"]), card))

	# 名字行：序号圆片 + 标题
	var name_row := HBoxContainer.new()
	name_row.add_theme_constant_override("separation", 12)

	# 序号圆片：Label 直接挂一个圆角底，别再用 Panel 套一层
	# （Panel 不是 Container，子控件拿不到尺寸，会塌成 0、文字溢出来）
	var num_l := Label.new()
	num_l.text = String(m["num"])
	num_l.custom_minimum_size = Vector2(42, 42)
	num_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	num_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	num_l.add_theme_font_size_override("font_size", 23)
	num_l.add_theme_color_override("font_color", Color("#0b0e14"))
	var num_sb := StyleBoxFlat.new()
	num_sb.bg_color = Color("#5b6675")
	num_sb.set_corner_radius_all(21)
	num_sb.content_margin_left = 11
	num_sb.content_margin_right = 11
	num_sb.content_margin_top = 6
	num_sb.content_margin_bottom = 6
	num_l.add_theme_stylebox_override("normal", num_sb)
	num_l.set_meta("sb", num_sb)
	name_row.add_child(num_l)

	var title := Label.new()
	title.text = String(m["title"])
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 33)
	title.add_theme_color_override("font_color", Color("#f4f7fb"))
	name_row.add_child(title)
	vb.add_child(name_row)
	name_row.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var sub := Label.new()
	sub.text = String(m["sub"])
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	sub.add_theme_font_size_override("font_size", 16)
	sub.add_theme_color_override("font_color", Color("#8b96a6"))
	vb.add_child(sub)
	sub.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	# 标签行
	var tags := HBoxContainer.new()
	tags.alignment = BoxContainer.ALIGNMENT_CENTER
	tags.add_theme_constant_override("separation", 8)
	for t in m["tags"]:
		var cl := Label.new()   # 同样是「Label 自带圆角底」，不用 Panel 套娃
		cl.text = String(t)
		cl.add_theme_font_size_override("font_size", 14)
		cl.add_theme_color_override("font_color", Color("#9aabc0"))
		var csb := StyleBoxFlat.new()
		csb.bg_color = Color("#1b2431")
		csb.set_border_width_all(1)
		csb.border_color = Color("#2b3542")
		csb.set_corner_radius_all(9)
		csb.content_margin_left = 12
		csb.content_margin_right = 12
		csb.content_margin_top = 5
		csb.content_margin_bottom = 5
		cl.add_theme_stylebox_override("normal", csb)
		tags.add_child(cl)
	vb.add_child(tags)
	tags.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	# 余量全给这个空壳，别让上面的行被 VBox 平均拉高
	var filler := Control.new()
	filler.mouse_filter = Control.MOUSE_FILTER_PASS
	vb.add_child(filler)

	# 点击层：压在最上面，整张卡都能点
	var hit := Button.new()
	hit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hit.set_anchors_preset(Control.PRESET_FULL_RECT)
	hit.flat = true
	hit.text = ""
	hit.mouse_filter = Control.MOUSE_FILTER_STOP
	hit.set_meta("scene", String(m["scene"]))
	hit.pressed.connect(func() -> void: _go(String(m["scene"])))
	hit.mouse_entered.connect(func() -> void: _set_hover(card, true))
	hit.mouse_exited.connect(func() -> void: _set_hover(card, false))
	card.add_child(hit)                          # 后加 = 画在上面 = 吃到事件

	card.set_meta("sb", sb)
	card.set_meta("num_l", num_l)
	_cards.append([card, String(m["scene"])])

	# 入场：淡入 + 轻微放大，别「啪」一下全在那
	var tw := create_tween().set_parallel(true)
	tw.tween_property(card, "modulate", Color(1, 1, 1, 1), 0.36).set_trans(Tween.TRANS_BACK)
	tw.tween_property(card, "scale", Vector2(1, 1), 0.36).from(Vector2(0.94, 0.94))

	return card


func _make_shot(preview_path: String, card: Panel) -> Panel:

	var shot := Panel.new()
	shot.custom_minimum_size = Vector2(0, SHOT_H)
	shot.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	var sbs := StyleBoxFlat.new()
	sbs.bg_color = Color("#080a0e")
	sbs.set_border_width_all(2)
	sbs.border_color = Color("#232b36")
	sbs.set_corner_radius_all(11)
	shot.add_theme_stylebox_override("panel", sbs)

	# 预览图往里缩 3 像素，让圆角边框露出来
	var tex: Texture2D = load(preview_path)
	if tex != null:
		var tr := TextureRect.new()
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.set_anchor(SIDE_LEFT, 0.0)
		tr.set_anchor(SIDE_RIGHT, 1.0)
		tr.set_anchor(SIDE_TOP, 0.0)
		tr.set_anchor(SIDE_BOTTOM, 1.0)
		tr.offset_left = 3.0
		tr.offset_top = 3.0
		tr.offset_right = -3.0
		tr.offset_bottom = -3.0
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		tr.texture = tex
		shot.add_child(tr)
		card.set_meta("tex", tr)
	else:
		push_warning("[select] 预览图没读到：" + preview_path)
		var ph := ColorRect.new()
		ph.set_anchors_preset(Control.PRESET_FULL_RECT)
		ph.offset_left = 3.0
		ph.offset_top = 3.0
		ph.offset_right = -3.0
		ph.offset_bottom = -3.0
		ph.color = Color("#111725")
		shot.add_child(ph)
		card.set_meta("tex", null)

	# 左上角角标
	var badge := Label.new()
	badge.text = "预览"
	badge.add_theme_font_size_override("font_size", 13)
	badge.add_theme_color_override("font_color", Color("#f0f4fa"))
	badge.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	badge.add_theme_constant_override("shadow_offset_y", 1)
	badge.position = Vector2(14, 11)
	badge.mouse_filter = Control.MOUSE_FILTER_PASS
	shot.add_child(badge)

	# 右下角「点击进入」：平时半透明，悬停卡片时亮起来
	var go_hint := Label.new()
	go_hint.text = "点击进入 →"
	go_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	go_hint.mouse_filter = Control.MOUSE_FILTER_PASS
	go_hint.add_theme_font_size_override("font_size", 15)
	go_hint.add_theme_color_override("font_color", Color("#eaf1fb"))
	go_hint.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.75))
	go_hint.add_theme_constant_override("shadow_offset_y", 1)
	go_hint.offset_left = 14.0
	go_hint.offset_top = SHOT_H - 34.0
	go_hint.offset_right = -14.0
	go_hint.offset_bottom = -12.0
	go_hint.modulate = Color(1, 1, 1, 0)
	shot.add_child(go_hint)
	card.set_meta("hint", go_hint)

	return shot


# ------------------------------------------------------------------ 悬停反馈

func _set_hover(card: Panel, on: bool) -> void:

	_hovered = card if on else (null if _hovered == card else _hovered)

	# 车卡的悬停反馈和地图卡共用一套（sb 存在 meta 里），
	# 但车卡没有「进入」提示，别去动 hint —— 车卡压根没存这个 meta

	var sb: StyleBoxFlat = card.get_meta("sb")
	if sb != null:
		sb.bg_color = Color("#17202b") if on else Color("#12161d")
		sb.border_color = ACCENT if on else Color("#262e3a")
		sb.set_border_width_all(3 if on else 2)

	# 序号圆片的 stylebox 挂在 Label 的 theme override 上，取出来就能改色
	var num_l: Label = card.get_meta("num_l")
	var num_sb: StyleBoxFlat = num_l.get_theme_stylebox("normal") if num_l != null else null
	if num_sb != null:
		num_sb.bg_color = ACCENT if on else Color("#5b6675")

	# get_meta 必须带默认值：预览图没读到时存进去的是 null，
	# Godot 里 set_meta(key, null) 等于把这个 key 删掉，再 get 就抛错
	var tex: TextureRect = card.get_meta("tex", null)
	if tex != null:
		tex.modulate = Color(1.12, 1.12, 1.12, 1.0) if on else Color(1, 1, 1, 1)

	var hint: Label = card.get_meta("hint") if card.has_meta("hint") else null
	if hint != null:
		hint.modulate = Color(1, 1, 1, 0.95) if on else Color(1, 1, 1, 0)

	# 车卡：鼠标移开后要把「选中」那圈描边画回来，别停在普通态
	if on == false:
		for c in _veh_cards:
			if c[0] == card:
				_select_vehicle(String(c[1]))
				break

	# 4.7 里手型光标叫 CURSOR_POINTING_HAND（不是 CURSOR_POINTING，写错整个脚本就解析不过）
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if on else Input.CURSOR_ARROW)


# ------------------------------------------------------------------ 进图

func _go(scene_path: String) -> void:

	get_tree().paused = false
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	get_tree().change_scene_to_file(scene_path)


func _unhandled_input(event: InputEvent) -> void:

	if event is not InputEventKey:
		return
	var k: InputEventKey = event as InputEventKey
	if not k.pressed or k.echo:
		return

	if k.keycode == KEY_1:
		_go(scene_map1)
	elif k.keycode == KEY_2:
		_go(scene_map2)
	elif k.keycode == KEY_ENTER or k.keycode == KEY_SPACE:
		# 悬停谁就进谁，没悬停就进第一张
		_go(_hovered_scene())
	elif k.keycode == KEY_LEFT or k.keycode == KEY_RIGHT:
		# 左右方向键换车（1 / 2 留给地图，别抢）
		var i: int = 0
		for c in _veh_cards:
			if String(c[1]) == Garage.selected_id:
				i = _veh_cards.find(c)
				break
		i += 1 if k.keycode == KEY_RIGHT else -1
		var n: int = _veh_cards.size()
		if n > 0:
			_select_vehicle(String(_veh_cards[(i + n) % n][1]))


func _hovered_scene() -> String:

	if _hovered != null:
		for c in _cards:
			if c[0] == _hovered:
				return String(c[1])
		return scene_map1
	if _cards.size() > 0:
		return String(_cards[0][1])
	return scene_map1
