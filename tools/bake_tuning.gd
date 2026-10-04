extends SceneTree

## 把「面板上刚调好的手感」固化回源码默认值。
##
## 为什么不用 GDTuner 自带的 Bake to Source：
## 它的正则只认两行式 `@export var x: float = 0`，而 Godot 4.7 里这种写法是
## Parse Error（必须写成单行 `@export_range(0,10,0.1) var x: float = 0`），
## 于是 GDTuner 的 bake 匹配不到任何东西，点了没反应。
## 这个文件用我们自己的正则，两种写法都认，用完可以删。
##
## 用法（headless）：
##   # 干跑：只列出要改什么，不动文件
##   godot --headless --path . --script res://tools/bake_tuning.gd -- --dry
##   # 真写：先备份到 Temp/bak_<时间戳>/，再改源码
##   godot --headless --path . --script res://tools/bake_tuning.gd
##
## 默认读 scenes/main.tscn（随机赛道图）

const VEHICLE_SCRIPT := "res://scripts/vehicles/vehicle_arcade.gd"
const VIEW_SCRIPT := "res://scripts/camera/view.gd"

var _dry: bool = false

# --set=属性=值：临时把某个属性的"当前值"改掉，用来测写盘、或固化面板里拿到的一次性读数
var _set_overrides: Dictionary = {}

# 目标脚本 -> 场景里要读哪个节点 + 节点类型
const TARGETS := [
	{"script": VEHICLE_SCRIPT, "node": "Vehicle", "props": [
		"max_speed", "engine_power", "brake_power", "lateral_grip", "turn_rate", "steer_falloff",
	]},
	{"script": VIEW_SCRIPT, "node": "View", "props": [
		"distance", "height", "look_at_height", "look_ahead", "distance_speed", "distance_brake", "fov_base",
	]},
]

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if a == "--dry":
			_dry = true
		elif a.substr(0, 6) == "--set=":
			var kv: String = a.substr(6)
			var i: int = kv.find("=")
			if i > 0:
				_set_overrides[kv.substr(0, i)] = kv.substr(i + 1).to_float()

func _process(_delta: float) -> bool:
	var scene_path: String = "res://scenes/main.tscn"
	for a in OS.get_cmdline_user_args():
		if a.substr(0, 8) == "--scene=":
			scene_path = a.substr(8)

	var psc: PackedScene = load(scene_path)
	if psc == null:
		print("Bake: 场景加载失败 " + scene_path)
		return true
	var inst: Node = psc.instantiate()

	print("Bake: 源 = " + scene_path + "  模式 = " + ("干跑(不写文件)" if _dry else "写入源码"))
	print("")

	var changed_total: int = 0
	for t in TARGETS:
		var node: Node = inst.find_child(t.node, true, false)
		if node == null:
			print("Bake: 跳过，场景里没有 " + t.node + " 节点")
			continue
		changed_total += _bake_script(t.script, node, t.props)

	print("")
	print("Bake 完成：共改动 " + str(changed_total) + " 处" + ("（干跑，文件没动）" if _dry else ""))
	return true

## 把 node 上这些属性的当前值，写回 script 里的 @export 默认值

func _bake_script(script_path: String, node: Node, props: Array) -> int:
	var f := FileAccess.open(script_path, FileAccess.READ)
	if f == null:
		print("Bake: 读不了 " + script_path)
		return 0
	var src: String = f.get_as_text()
	f.close()

	# 两种写法都认：
	#   两行式（Godot 4.6 及以前）：@export var max_speed: float = 28.0
	#   单行式（Godot 4.7 强制）：  @export_range(4, 60, 0.5) var max_speed: float = 28.0
	# 踩过的坑：属性名之间必须用 | 才是"或"，写成 / 会被整串当字面量，结果 0 命中还不报错
	var name_alt := "|".join(props)
	var re := RegEx.new()
	# 两个捕获都要用命名组：命名组在 PCRE 里同样占编号，用数字下标会取串位
	re.compile("(\\s*(?:@export\\s+var|@export_range\\([^)]*\\)\\s+var)\\s+(?P<name>" + name_alt + ")\\s*:\\s*\\w+\\s*=\\s*)(?P<old>[-0-9.eE+]*)")

	var changed: int = 0
	var out := ""
	var last := 0
	var off := 0
	while true:
		var m := re.search(src, off)
		if m == null:
			break
		var prop_name: String = m.get_string("name")
		var current: Variant = node.get(prop_name)
		if _set_overrides.has(prop_name):
			current = _set_overrides[prop_name]
		if current == null:
			print("Bake: ! " + prop_name + " 在脚本里查不到，跳过")
			off = m.get_end()
			continue
		var new_text: String = _to_gd_literal(current)
		off = m.get_end()
		# 比数值而不是比字面：源码里写 28.0 时格式化出来是 28.00，字面上不同但值一样，不该算改动
		if absf(float(current) - m.get_string("old").to_float()) < 0.005:
			continue
		out += src.substr(last, m.get_start() - last) + m.get_string(1) + new_text
		last = m.get_end()
		changed += 1
		print("Bake: %-16s %s = %s" % [prop_name, script_path.get_file(), new_text])
	out += src.substr(last)

	if changed == 0:
		print("Bake: " + script_path.get_file() + " 无变化")
		return 0
	if _dry:
		return changed

	# 先备份再改，改坏了能捞回来
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "").replace(" ", "_")
	var bak_dir := "res://Temp/bak_" + stamp
	DirAccess.make_dir_recursive_absolute(bak_dir)
	if DirAccess.dir_exists_absolute(bak_dir):
		var dst := bak_dir + "/" + script_path.get_file() + ".bak"
		var err := DirAccess.copy_absolute(script_path, dst)
		if err == OK:
			print("Bake: 已备份 -> " + dst)

	var w := FileAccess.open(script_path, FileAccess.WRITE)
	if w == null:
		push_error("Bake: 写不了 " + script_path + "（导出版是只读的，只能在编辑器里改）")
		return changed
	w.store_string(out)
	w.close()
	return changed

func _to_gd_literal(v: Variant) -> String:
	if v is int:
		return str(v)
	if v is bool:
		return "true" if v else "false"
	return "%.2f" % float(v)
