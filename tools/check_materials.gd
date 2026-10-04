extends Node
## 场景级「防黑材质」体检器 —— 地图 2（迷你中国城）改完必跑。
##
## 跑法（无头即可，不用开窗口）：
##     Godot --headless --path . res://tools/check_materials.tscn
##     想体检地图 1（官方赛道）就多带一个参数：
##     Godot --headless --path . res://tools/check_materials.tscn -- res://scenes/main.tscn
##
## 报告同时写 stdout 和 res://Temp/materials_report.txt（脚本自己落盘，
## 因为 PowerShell 通道常常只回退出码、stdout 全丢）。
##
## 检查项（对应「通用防黑材质提示词」四条）：
##   P0  裸网格：MeshInstance3D 既没有 material_override，mesh 也没有材质槽。
##              暗场景里这种东西就是一片黑，有 P0 一律判 FAIL。
##   P1  反照色过暗：材质 albedo 最亮通道 < MIN_ALBEDO（默认 0.12）。
##              这就是「黑咕隆咚」——必须把「材质太黑」和「光不够」分开判定。
##   P2  顶点色没开：mesh 带顶点色数组却没开 vertex_color_use_as_albedo，
##              整片会塌成一个颜色（看着像没贴图）。
##   P2  裸模型：mesh 来自外部资源（.glb/.fbx/.obj）却没有 material_override。
##              按提示词：要么别直接实例化裸模型，要么复用它自带的材质资源。
##
## 退出码：0 = 通过（P0 为 0），1 = 有 P0，2 = 场景加载失败。可以接进 CI。

const MIN_ALBEDO: float = 0.12

## 要体检的场景，可用命令行 user arg 覆盖（见文件头跑法）
var _target: String = "res://scenes/main.tscn"
var _scanned: bool = false
var _frames: int = 0

func _ready() -> void:
	# 探针自己把目标场景装进来：不加载的话一个节点都扫不到，报告会假 PASS
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0:
		_target = String(args[0]).replace("--", "")

	var packed: Resource = load(_target)
	if packed == null:
		push_error("[materials] 场景加载失败：" + _target)
		get_tree().quit(2)
		return

	# 探针本身就挂在场景树里，此刻父节点正在 setup children，直接 add_child 会被挡：
	#   "Parent node is busy setting up children"
	# 所以延迟挂；而延迟动作排在 idle，比 _process 晚，所以要等第三帧（见 _process）。
	get_tree().root.call_deferred("add_child", packed.instantiate())

## 注意签名必须是 _process(float) -> void，写 -> bool 会直接 Parse Error
func _process(_dt: float) -> void:

	if _scanned:
		return
	_frames += 1
	# 帧序是 process → idle → deferred 排队执行：
	# 第 1 帧排队、第 2 帧 idle 里才真挂上树、第 3 帧才能拿到完整子树。
	# 给到 3 别给 2，否则报告是「共 0 个 / PASS」的假绿灯。
	if _frames < 3:
		return
	_scanned = true
	_scan()

func _scan() -> void:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("== 防黑材质体检 %s ==" % Time.get_datetime_string_from_system())
	lines.append("目标场景：%s" % _target)

	var mis: Array = _collect_meshes(get_tree().root)
	# 注意：字符串拼接必须包在括号里（"a" + "b" % x 会先对 "b" 做格式化 → 参数不匹配报错）
	lines.append("扫描到 MeshInstance3D %d 个（手写的递归遍历，不用 find_children："
			% mis.size()
			+ "它带 class 参数时在这个版本会漏）")

	var p0: int = 0
	var p1: int = 0
	var p2: int = 0
	var ok: int = 0

	for n in mis:
		var mi: MeshInstance3D = n
		var mesh_: Mesh = mi.mesh
		if mesh_ == null:
			continue

		var name_: String = _path_of(mi)
		var mat: StandardMaterial3D = mi.material_override as StandardMaterial3D

		# ---- P0：完全没材质
		# 这里踩过两次坑，别再踩：
		#   1. MeshInstance3D 在 4.7 上没有 get_material_slot_count()；
		#   2. Mesh/ArrayMesh 上也没有它。
		# 能数材质槽的只有 Mesh.surface_get_material(i) 这一条路，
		# 所以「一个槽都没有」=(mesh 没有任何 surface)+没有 material_override。
		var surfaces: int = 0
		if mesh_.has_method("get_surface_count"):
			surfaces = mesh_.get_surface_count()

		if mat == null and surfaces == 0:
			p0 += 1
			lines.append("[P0] 裸网格（无材质）%s" % name_)
			continue

		if mat == null:
			# 没有覆盖，但 glb/fbx 的材质本来就**内嵌在 mesh 里**，这不算裸网格。
			# 关键是要验那份内嵌材质是不是黑的：只报「裸模型」而不查反照色，
			# 所有车模都会永远挂 P2，真黑的那个反而被噪音盖过去了。
			var slots: int = 0
			var dark: int = 0
			var lit: bool = false

			for s in surfaces:
				var em: Material = mesh_.surface_get_material(s)
				slots += 1
				if em == null:
					continue
				var ema: StandardMaterial3D = em as StandardMaterial3D
				if ema == null:
					# 非 Standard 材质（ShaderMaterial 之类）没法只看反照色，放行
					lit = true
					continue
				var ec: Color = ema.albedo_color
				var emx: float = maxf(maxf(ec.r, ec.g), ec.b)
				if emx < MIN_ALBEDO:
					dark += 1
				else:
					lit = true

			if slots == 0:
				p0 += 1
				lines.append("[P0] 裸网格（无 material_override，mesh 也没有材质槽）%s" % name_)
				continue

			# 每个槽都黑 = 这东西在场景里就是个洞，按 P1（材质太黑）算
			if not lit:
				p1 += 1
				lines.append("[P1] 内嵌材质反照色过暗（%d/%d 个槽）%s" % [dark, slots, name_])
				continue

			p2 += 1
			lines.append("[P2] 裸模型（无 material_override，靠 mesh 内嵌 %d 个材质槽，已验不过黑）%s"
					% [slots, name_])
			continue

		# ---- P1：反照色太黑
		var c: Color = mat.albedo_color
		var mx: float = maxf(maxf(c.r, c.g), c.b)
		if mx < MIN_ALBEDO:
			p1 += 1
			lines.append("[P1] 反照色过暗 %.3f（<%.2f）%s" % [mx, MIN_ALBEDO, name_])

		# ---- P2：反照色是纯白却没开顶点色开关。
		# 本来想直接查 mesh 的顶点色位，但 Godot 4.7 的 Mesh 既没有
		# surface_get_arrays_format()，也没有 FORMAT_COLOR / ARRAY_FORMAT_COLOR 常量，
		# 硬查会 Parse Error。改用启发式：纯白底 + 没开开关
		# = 这个 Builder 原打算靠顶点色上色，八成就是漏了开关。
		if c.r > 0.95 and c.g > 0.95 and c.b > 0.95 and not mat.vertex_color_use_as_albedo:
			p2 += 1
			lines.append("[P2] 反照色纯白却没开 use_as_albedo（多半漏了顶点色）%s" % name_)

		ok += 1

	lines.append("--")
	lines.append("MeshInstance3D 共 %d，通过 %d，P0=%d，P1=%d，P2=%d" % [mis.size(), ok, p0, p1, p2])
	lines.append("判定：%s" % ("PASS" if p0 == 0 else "FAIL"))

	var text: String = "\n".join(lines)
	print(text)

	var f := FileAccess.open("res://Temp/materials_report.txt", FileAccess.WRITE)
	if f != null:
		f.store_string(text + "\n")
		f.close()

	if p0 > 0:
		push_error("[materials] P0 裸网格 %d 个，必须修掉" % p0)
		get_tree().quit(1)
	else:
		get_tree().quit(0)

## 手写一个递归收集器。**必须返回 Array，不能收 out 参数再 append**：
## Packed*Array / Array 传参都是值拷贝（元素是引用，数组本身不是），
## 在函数里 append 的东西调用方一个都看不到，会误判成「树是空的」。
func _collect_meshes(node: Node) -> Array:

	var out: Array = []
	for ch in node.get_children():
		if ch is MeshInstance3D:
			out.append(ch)
		out.append_array(_collect_meshes(ch))
	return out

## 相对项目根目录的路径，报告里好认
func _path_of(node: Node) -> String:
	var parts: Array = []
	var cur: Node = node
	while cur != null and cur != get_tree().root:
		parts.push_front(cur.name)
		cur = cur.get_parent()
	return "res://" + "/".join(PackedStringArray(parts))
