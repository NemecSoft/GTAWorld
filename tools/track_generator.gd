extends Node3D
class_name TrackGenerator

# ---------------------------------------------------------------------------
# 方案 A：红警2（C&C）式「区块拼接」-> 3D GridMap 极品飞车随机赛道
#
# 【复用的是哪个成熟方案】
#   主复用：红警2 随机地图（RMA）的**连接掩码拼图法**，这是 RMA 的事实标准。
#     - 社区工具 Handama 随机地图生成器的原话：
#       「本生成器的原理就是拼图，在一个方形的地形区块中，定义每个边的
#         连接方式，相同的连接方式相邻的边之间，其地形也是相连的」
#       https://bbs.ra2diy.com/forum.php?mod=viewthread&tid=20461
#     - 地形块文件名形如 `1,1,1,1,01.map`，四个数字 = 东北/西北/西南/东南
#       四边的连通位：1 = 那条边跟邻居连通，0 = 墙。
#       (`1,1,1,1` 四边全通，`1,0,1,0` = 仅南北通)
#     - 文件名带 `spawn` 的**强制当出生点块**，带 `tiberium` 的当矿区，
#       这类块四边分量归零（它们本来就不需要跟别块接）。
#     - 相邻块只校验一件事：A 块朝东是 1，B 块朝西就必须是 1，对上才能拼。
#
#   通用算法这一支的权威参考（同一套 4-bit 位运算）：
#     UFO: Alien Invasion 的 RMA1 / RMA2 地图组装算法
#     https://ufoai.org/w/index.php?title=Mapping/Random_map_assembly/Algorithm
#     原话「用位逻辑做更快的连接测试 / bit logic for quicker connection tests」，
#     流程是「固定块 -> 必要块 -> 填剩余块」，走不通就回溯。
#
#   参数骨架参考：Greaby/godot-2d-track-generator（GitHub，MIT，Godot 3.3）
#   https://github.com/Greaby/godot-2d-track-generator
#     Area / Min length / Max length / 直道优先度 这四个参数语义照搬成
#     area_radius / min_length / max_length / straight_ratio，
#     输出从 Vector2 2D 格子换成 GridMap 的 cell 三元组，
#     落盘从 Tilemap.set_cell 换成 GridMap.set_cell_item（直接复用原项目道路 tile）。
#
# 【这里和红警2最大的一处不同，需要注意】
#   红警2 的 tile 集是手绘大图块，块内地形千奇百怪；
#   本项目的 tile 是 10×10 的「格子化小方块」（track-straight / track-corner）。
#   所以不用红警2 那种「一格一整块地形」的做法，只取它的**连接掩码**这一层：
#     mask(4 bit) -> 选哪个 tile -> tile 转多少度
#   掩码是中间表示，tile 只是掩码的一种画法 —— 以后要在 MeshLibrary 里加
#   三通 / 十字块，只要那个 item 名字里带对关键字，这边自动就能拼。
#
# 【为什么选 A 不选 B（Curve3D 挤出 / godot-road-generator）】
#   - 曲线路线那一支的成熟方案是 TheDuckCow/godot-road-generator（MIT，
#     官方资源库 #3379，RoadManager/RoadContainer/RoadPoint 一键连闭合环路）。
#     但 RoadPoint 是「由点生成整条路面网格」，等于另造一套路面几何和材质，
#     正是「黑乎乎网格」的高发区，跟「复用原项目材质」直接冲突，故不采用。
#   - 原项目道路本来就是 10×10 的格子化方块，天生为 GridMap 服务，
#     MeshLibrary 里的路 tile 还自带碰撞体（shapes），一次 set_cell_item
#     同时拿到「看得见的路」和「撞得到的墙」。
#   - 方案 B 要另造路面网格，等于放弃这些。
#   - 原项目道路本来就是 10×10 的「格子化」方块（track-straight / track-corner），
#     天生为 GridMap 服务。方案 B 要另造一套路面网格，等于放弃复用。
#   - 方案 B 还得自己配材质，正是「黑乎乎网格」的高发区。
#   - MeshLibrary 里的路 tile 自带碰撞体（shapes），一次 set_cell_item 就同时
#     得到「看得见的路」和「撞得到的墙」。
#
# 【防黑：GridMap 这边有一条反直觉的规则，务必记住】
#   models/Library/mesh-library.tres 的道路 tile，材质是**内嵌在 ArrayMesh 的
#   surface 里**的（_surfaces[].material），GridMap 长出来的子网格没有
#   material_override。而 MeshLibrary 只吃「网格内部」的材质、节点上挂的会被忽略。
#   所以这里**故意不给 tile 加 material_override** —— 加了反而会把 tile 自带的
#   colormap 贴图整片盖掉，路面塌成纯白/纯黑。
#   本文件末尾 _audit_library() 把这条规则做成了跑得起来的断言。
# ---------------------------------------------------------------------------

# ===========================================================================
# MeshLibrary 的 item 编号（models/Library/mesh-library.tres 的实际顺序）
# 改了那个文件这里必须同步，否则会把「森林」铺成马路。
# ===========================================================================

const ITEM_EMPTY := 0
const ITEM_FOREST := 1
const ITEM_TENTS := 2
const ITEM_CORNER := 3
const ITEM_FINISH := 4
const ITEM_RAMP := 5
const ITEM_STRAIGHT := 6

## 四个方向：索引 +1 / -1 就是左右转 90°
const DIRS: Array[Vector2i] = [
	Vector2i(1, 0),   # +X
	Vector2i(0, 1),   # +Z
	Vector2i(-1, 0),  # -X
	Vector2i(0, -1),  # -Z
]

const UP := Vector3(0, 1, 0)

# ===========================================================================
# 红警2 式连接掩码（connection mask）
#
# 红警2 用一个地形块四边能不能跟邻居接，来表达「这里该放什么块」。
# 这里同样给每格路一个 4 bit 的 mask：第 n 位 = DIRS[n] 那个方向有没有路接着。
#
#   0001 (+X)  0010 (+Z)  0100 (-X)  1000 (-Z)
#
# 于是「南北通」= 0010|1000 = 10，「+X 与 +Z 通」的拐角 = 0001|0010 = 3。
# 掩码可以整体旋转 k 次（每次把 4 个 bit 往右挪一位），
# 这就是 tile 的朝向：红警2 是换一张图，这里是换一个 orientation。
# ===========================================================================

const MASK_PX := 1    ## +X
const MASK_PZ := 2    ## +Z
const MASK_NX := 4    ## -X
const MASK_NZ := 8    ## -Z
const MASK_ALL := MASK_PX | MASK_PZ | MASK_NX | MASK_NZ   ## 15 = 四边全通

## tile 建模时路面沿局部 +Z 走，所以「直道」落在 ±Z 这一对对边上。
const MASK_STRAIGHT_BASE := MASK_PZ | MASK_NZ   ## 10
## 「弯道」落在两条相邻边上。
const MASK_CORNER_BASE := MASK_PZ | MASK_PX     ## 3

## MeshLibrary 里 item 名字的关键字 -> 掩码类型。
## 照抄红警2「文件名带什么关键字就是什么块」的约定：
## 带 straight 的强制当直道块、带 curve/corner 的强制当弯道块、
## 带 finish/start 的强制当出生点块（分量归零，不参与连通校验）。
##
## 注意这三个**不能用 const**：GDScript 的 const 只接受编译期常量表达式，
## PackedStringArray([...]) 那个构造函数不算，会直接 Parse Error
## （报 "Assigned value ... isn't a constant expression"，位置还指到别行上，很误导）。
var KW_STRAIGHT: PackedStringArray = PackedStringArray(["straight"])
var KW_CURVE: PackedStringArray = PackedStringArray(["curve", "corner"])
var KW_SPAWN: PackedStringArray = PackedStringArray(["finish", "start", "ramp"])

# ===========================================================================

@export_group("赛道形状（对应成熟生成器的 Area / Min / Max length）")
## 赛道大致铺多大（格）。1 格 = cell_size = 10 世界单位。
##
## **它和 min/max_length 是绑死的，改一个必须跟着改另一个**：
## 角点绕原点一圈，曼哈顿周长大约 ≈ 2π × 平均半径（多边形比圆长一点）。
## 半径 22 → 周长 ~140 格；半径 34 → 周长 ~210 格，直接顶爆 max_length。
## 不配平时 200 次重试会全部以「长度不达标」失败，且**一条报错都没有**。
@export var area_radius: int = 22
## 闭环最短长度（格）。太短会绕成一坨，车还没加速完就撞墙。
@export var min_length: int = 60
## 闭环最长长度（格）。太长生成慢、自交率高。
## 经验值：max_length ≈ 2π × area_radius（配不平就见 area_radius 那条注释）。
@export var max_length: int = 160
## 直道比例（0~1）：每走一步「继续直行」的概率。
## 1.0 = 一条长直道加一个回头弯；0.2 = 蛇形扭来扭去。
@export var straight_ratio: float = 0.55
@export var straight_span_min: int = 2
@export var straight_span_max: int = 5
## 转角概率（1 = 每次都尝试拐 90°；0 = 一路直着走）
@export var turn_chance: float = 1.0

## 转角 tile 的朝向补偿（弧度）。corner tile 的建模朝向跟「入口方向」不一定对得上，
## 常见修法：· = 0 / 90°(PI*0.5) / 180°(PI) / -90°(-PI*0.5)。
## 做成属性而不是写死，是为了在 GUI 里拖着调、不用回去改代码重新编译。
@export var corner_rot_offset: float = 0.0

@export_group("赛道尺寸")
## 路面宽度（格）。**必须 >= 3**：车身 3 米宽、格宽 10 单位，2 格路根本塞不进去，
## 玩家全程挂路沿。3 = 勉强，4~5 = 街机赛车最舒服。
@export var track_width: int = 4
@export var road_layer: int = 0
## 是否先清掉 GridMap 上已有的格子（同一个 GridMap 要放两条赛道时关掉）
@export var clear_first: bool = true
## 铺面重试次数：一条中心线铺出末梢就换下一条。
## 实测 8 个 seed 里 1 个会撞上转角错位，给 6 次基本一次过。
@export var pave_attempts: int = 6
## 生成后是否打印铺设统计
@export var verbose: bool = true

@export_group("出发区（红警2 的 spawn 块）")
## 发车后第一格铺一个坡道（ramp）。默认关：开着开着突然被弹飞对街机手感是负分，
## 需要时在检查器里开。红警2 里 spawn 区周围也有一小片特殊地形，同理。
@export var spawn_ramp: bool = false

@export_group("装饰物")
@export var decorate: bool = true
## 装饰物离路沿最少几格（**必须 > 0**；0 = 直接长在路面上把赛道堵死）
@export var deco_margin: int = 2
@export var deco_reach: int = 4
@export var deco_density: float = 0.35
@export var deco_items: Array[int] = [ITEM_FOREST, ITEM_TENTS]

@export_group("兜底地面（防黑第二道闸）")
## 赛道底下补一张大平面。有些角度太阳照不到、tile 之间还有缝，
## 没这一层就会从缝里看到虚空 —— 玩家会说「地面是黑的」，其实那是有光没底。
@export var footer_floor: bool = true
@export var floor_size: float = 400.0
@export var floor_color: Color = Color(0.42, 0.66, 0.36)
@export var floor_y: float = -0.35
@export var floor_parent: Node3D

@export_group("随机")
## 固定 seed = 可复现的赛道（复现 bug 用）；0 = 每次都新随机
@export var seed: int = 0
@export var regenerate_on_ready: bool = true

@export_group("场景引用")
@export var gridmap: GridMap

# ---------------------------------------------------------------------------

var _route: Array[Vector2i] = []   # 闭环中心线（有序、首尾正好挨着）
## "x,z" -> {"item":int,"orient":int}
## orient 是 **int 正交索引**，不是 Basis —— Godot 4.7 的
## GridMap.set_cell_item(cell, item_id, orientation) 第 3 参收的是 int。
var _tiles: Dictionary = {}
## 连接掩码表：base_mask(int) -> {"item":int,"base_orient":int}
## 由 _scan_library() 从 MeshLibrary 的 item 名字里自动认出来。
## 这是「红警2 拼图法」在本项目里的落点：
## 想加三通块 / 十字块，往 mesh-library 里丢一个 item 就行，这边不用改代码。
var _tile_table: Dictionary = {}
## 掩码 -> tile 的解析缓存 mask(int) -> {"item":int,"orient":int}
var _mask_cache: Dictionary = {}
var _decor: Array = []             # [{cell:Vector3i,item:int}]
var _floor: MeshInstance3D = null
var _s: int = 0                    # LCG 状态

## 正交索引表：0..23 每个索引，旋转后 tile 的「局部 +Z 指哪」和「局部 +Y 指哪」。
## 见 _ensure_orient_table()。
var _orient_fwd: Array[Vector3i] = []
var _orient_up: Array[Vector3i] = []
## 「局部 +Y 仍朝世界 +Y」的索引（立面/平铺 tile 都只能用这批，
## 否则树会被倒着种）。用来给装饰物随机换朝向。
var _flat_orients: Array[int] = []

func _ready() -> void:
	if regenerate_on_ready:
		generate()

# ===========================================================================
# 公开接口
# ===========================================================================

## 生成闭合环路并铺进 GridMap。返回 false = 自交或长度不达标，换 seed 再试。
func generate() -> bool:

	# 这个脚本本来就挂在 GridMap 上时直接认自己。
	# 手写 .tscn 里写 gridmap = NodePath(".") 是**绑不上**的（实测解析到根节点去了，
	# 静默变 null），报错信息还很有迷惑性，所以这里兜一层。
	# 走 Variant 中转：本脚本 extends Node3D，静态类型不是 GridMap，
	# 直接写 `gridmap = self` 会被静态检查拒掉（"so it can't be of type GridMap"）
	if gridmap == null:
		var me: Variant = self
		if me is GridMap:
			gridmap = me

	if gridmap == null:
		push_error("[track] 没挂 GridMap。把场景里的 GridMap 拖到 gridmap 属性上，"
			+ "或者把本脚本直接挂到 GridMap 节点上")
		return false

	if track_width < 3:
		push_warning("[track] track_width=%d < 3（车会一直挂路沿），已强制抬到 3" % track_width)
		track_width = 3

	_reseed(seed)

	_route = []
	_tiles.clear()
	_decor = []

	# 先认 MeshLibrary 里「哪些 item 是直道 / 弯道 / 出生点块」，再查它们的材质。
	# 顺序不能反：材质断言要给 _scan_library 提供的候选集做体检，
	# 顺序反了会出现「表里有 item 但其实根本没材质」的漏网。
	if not _scan_library():
		return false
	if not _audit_library():
		return false

	# 红警2 那条「相邻边必须对上」的硬规则，落成跑得起来的断言。
	# 断头路在游戏里的表现是车开到一半撞上一堵看不见的墙，报错信息完全没有，
	# 所以这一关必须在铺盘之前拦掉。
	#
	# 它失败多半不是连通性真断了，而是**宽路转角处横带错位**偶发地多出一个末梢
	# （同一条中心线换个 seed 重来就没了），所以这里连「铺面」一起重试：
	# 一条中心线铺不通就换一条，别一上来就把「换 seed」当解决方案。
	var ok_road: bool = false
	for r in pave_attempts:
		if r > 0:
			_tiles.clear()
			_decor = []
		if not _build_loop(r * 104729):
			continue
		_pave_road()
		if not _verify_masks():
			if verbose:
				print("[track] 第 %d 条候选中心线铺出来有末梢，换一条" % (r + 1))
			continue
		ok_road = true
		break

	if not ok_road:
		push_error(("[track] 连铺 %d 条中心线都没铺出一条连通的路。"
			+ "把 track_width 调成 3（4 格宽在转角更容易错位）或调大 area_radius")
			% pave_attempts)
		return false

	_paint_finish_line()
	if decorate:
		_scatter_decor()
	if footer_floor:
		# NodePath 在手写 .tscn 里很容易绑成 null（绑错了只会静默失败），
		# 所以兜底地面不依赖属性绑定：自己找地方挂
		if floor_parent == null:
			floor_parent = _resolve_floor_holder()
		if floor_parent != null:
			_build_floor()

	_apply_to_gridmap()

	if verbose:
		print("[track] 闭环 %d 格 / 约 %.0f 米，路面 %d 格，装饰 %d 个" % [
			_route.size(), _route.size() * gridmap.cell_size.x, _tiles.size(), _decor.size()])
	return true

## 用指定 seed 生成一次（不放回节点属性）。
## 扫 seed 用的：单跑一次成功说明不了问题，得换一批 seed 看是不是次次成环。
func generate_with_seed(s: int) -> bool:

	var old: int = seed
	seed = s
	var ok: bool = generate()
	seed = old
	return ok

# ===========================================================================
# 闭环生成：随机游走 + BFS 收口（成熟生成器的核心思路）
# ===========================================================================

func _build_loop(seed_off: int = 0) -> bool:

	# 失败原因计数。生成器调参全靠这个：不统计就只能在黑屋里换 seed 撞运气
	var why: Dictionary = {"长度不达标": 0, "自交": 0}

	for attempt in 200:
		_reseed(seed + seed_off + attempt * 7919)

		var loop: Array[Vector2i] = _star_polygon()
		if loop.size() < min_length or loop.size() > max_length:
			why["长度不达标"] += 1
			continue
		if _self_intersects(loop):
			why["自交"] += 1
			continue

		_route = loop
		if verbose:
			print("[track] 第 %d 次尝试成环：周长 %d 格（约 %.0f 米）" % [
				attempt + 1, loop.size(), loop.size() * gridmap.cell_size.x])
		return true

	if verbose:
		var parts: PackedStringArray = PackedStringArray()
		for k in why.keys():
			parts.append("%s %d" % [str(k), int(why[k])])
		# 注意括号：GDScript 里 `+` 优先级高于 `%`，分行拼接而不套括号的话，
		# 格式化只会作用在最后那一段字面量上，前面带 %s 的不替换还会报
		# "not all arguments converted"
		push_warning(("[track] 200 次都没成环：%s。"
			+ "别急着换 seed，看哪项占比最大：自交多 = 拐角太尖（调大 area_radius、减小角度抖动）；"
			+ "长度不达标多 = 把 area_radius 调大") % ", ".join(parts))

	return false

## 找一个能挂兜底地面的父节点：优先「本节点上一层的同名子节点」，
## 再退到场景根。手写 .tscn 里 floor_parent 绑成 null 是常见事故，
## 这条兜底是为了让「地面消失（玩家看到虚空）」这类问题不会再冒出来。
func _resolve_floor_holder() -> Node3D:

	if get_parent() != null:
		var p := get_parent().get_node_or_null("FloorHolder")
		if p != null and p is Node3D:
			return p

	var scene: Node = get_tree().current_scene
	if scene != null:
		var s := scene.get_node_or_null("FloorHolder")
		if s != null and s is Node3D:
			return s

	return null

## ---------------------------------------------------------------------------
## 星形多边形：为什么放弃「随机游走 + BFS 收口」
## 第一版是这么干的：从原点随机游走 N 步，再 BFS 从终点绕回起点。
## 实测 120 次尝试，**120 次都失败**，失败原因统计清一色是「回程找不到路」。
## 这不是参数没调好，是结构性缺陷：随机游走从原点出发，本身就会把自己
## 盘成一圈围墙，把起点（也就是回程目标）封在里面 —— BFS 从外面怎么绕都进不去。
## 换 seed 只是换一种盘法，照样绕不过去。
##
## 星形多边形反过来做：先定一圈「按角度单调排列」的角点（这个前提就保证了
## 不自交），再用曼哈顿 L 形（先横后竖 / 先竖后横）逐段串成闭合折线。
## 闭合性与简单性由「角度单调 + 逐格曼哈顿走」两条性质保证，
## 剩下的自交风险交给 _self_intersects() 兜底，失败就换 seed。
## ---------------------------------------------------------------------------

## 一圈角点 + L 形连接 = 一条闭合正交环路。
func _star_polygon() -> Array[Vector2i]:

	var n: int = _ri_range(8, 16)
	var base: float = TAU / float(n)

	var corners: Array[Vector2i] = []
	var phase: float = _rnd() * TAU

	for i in n:
		# 角点沿圆周等分、带一点抖动；半径随机 —— 角度单调是「不自交」的保证，
		# 半径随机只是让形状有机一点，不会破坏它
		var ang: float = phase + base * float(i) + (_rnd() - 0.5) * base * 0.5
		var rad: float = float(_ri_range(5, area_radius))
		corners.append(Vector2i(int(roundf(sin(ang) * rad)), int(roundf(cos(ang) * rad))))

	# 末点接回首点，走满一圈
	corners.append(corners[0])

	var out: Array[Vector2i] = []
	for i in n:
		_lpath(corners[i], corners[i + 1], out)

	# 收尾：最后一步正好落回 out[0]，去掉这个重复格
	if out.size() > 1 and out[out.size() - 1] == out[0]:
		out.remove_at(out.size() - 1)

	return out

## 从 a 到 b 走一个「L 形」：先横一段再竖一段（或反过来）。
## 每段的先后随机，否则整条赛道会退化成一个正正方形。
func _lpath(a: Vector2i, b: Vector2i, out: Array) -> void:

	if _ri(2) == 0:
		_manhattan(a, Vector2i(b.x, a.y), out)
		_manhattan(Vector2i(b.x, a.y), b, out)
	else:
		_manhattan(a, Vector2i(a.x, b.y), out)
		_manhattan(Vector2i(a.x, b.y), b, out)

## 逐格曼哈顿走。顺手去重，免得原地打转时 append 出一串重复格。
func _manhattan(from: Vector2i, to: Vector2i, out: Array) -> void:

	if from == to:
		return

	var cx: int = from.x
	var cy: int = from.y
	var sx: int = 1 if to.x > cx else -1
	var sy: int = 1 if to.y > cy else -1

	var guard: int = 0
	while (cx != to.x or cy != to.y) and guard < 4096:
		guard += 1
		if cx != to.x:
			cx += sx
		elif cy != to.y:
			cy += sy
		var c := Vector2i(cx, cy)
		if out.is_empty() or out[out.size() - 1] != c:
			out.append(c)

## 自交 + 相邻性检查。闭环里每一步都必须正好差一格，且没有格子被占两次。
func _self_intersects(loop: Array[Vector2i]) -> bool:

	var occ: Dictionary = {}
	for i in loop.size():
		var c: Vector2i = loop[i]
		var key: String = "%d,%d" % [c.x, c.y]
		if occ.has(key):
			return true          # 同一个格出现两次 = 自交
		occ[key] = i

	for i in loop.size():
		var a: Vector2i = loop[i]
		var b: Vector2i = loop[(i + 1) % loop.size()]
		if absi(a.x - b.x) + absi(a.y - b.y) != 1:
			return true          # 有一步是跳格 = 断头路
	return false

# ===========================================================================
# 铺路
# ===========================================================================

## ---------------------------------------------------------------------------
## 中心线 -> 有宽度的路面。
## 这里是整套「红警2拼图法」的落点：不先写死「这格该用哪个 tile」，
## 而是先数清这一格四边哪些方向跟邻居连着（算 mask），
## 再拿这个连接类型去查表里对应的 tile 和朝向。
## 好处是以后 MeshLibrary 里加了三通 / 十字块，这边自动就能拼上。
## ---------------------------------------------------------------------------
func _pave_road() -> void:

	var n: int = _route.size()

	# 第一趟：给每个中心格算连接掩码，顺手把横向偏移方向存下来（第二趟铺面用）
	var perps: Array[Vector2i] = []

	for i in n:

		var here: Vector2i = _route[i]
		var prev_c: Vector2i = _route[(i - 1 + n) % n]
		var out_dir: Vector2i = _route[(i + 1) % n] - here

		var perp: Vector2i = Vector2i(-(here - prev_c).y, (here - prev_c).x)
		if perp == Vector2i.ZERO:
			perp = DIRS[0]
		perps.append(perp)

		var out_i: int = DIRS.find(out_dir)
		var in_i: int = DIRS.find(here - prev_c)
		if out_i < 0:
			# 相邻性早在 _self_intersects 里查过，走到这里说明环路本身坏了
			push_error("[track] route[%d] 的出向 (%d,%d) 不是四方向之一，环路断了"
				% [i, out_dir.x, out_dir.y])
			return
		if in_i < 0:
			push_error("[track] route[%d] 的入向 (%d,%d) 不是四方向之一，环路断了"
				% [i, (here - prev_c).x, (here - prev_c).y])
			return

		# 这一格的两扇门：**进门那扇开在入向的反面**，出门那扇开在出向上。
		#
		# 第一版写成 `bit(out_i) | bit((out_i+2)%4)`（把入向当成出向的反向），
		# 结果 Corner 块一个都铺不出来 —— 因为入向本来就跟着出向在转角处垂直，
		# 那样算出来只有 5 / 10 两种掩码（全是直道），转角处会铺成一道直角墙。
		# 这正是「不跑一遍看直方图就以为对了」会漏掉的问题。
		var mask: int = (1 << out_i) | (1 << ((in_i + 2) % 4))

		var t: Dictionary = _mask_tile(mask)
		if t.is_empty():
			return

		var item: int = int(t["item"])
		var orient: int = int(t["orient"])

		# 弯道朝向微调（GUI 里拖着调，不用回去改代码重新编译）
		if corner_rot_offset != 0.0 and item == ITEM_CORNER:
			orient = _rotate_orient(orient, int(roundf(corner_rot_offset / (PI * 0.5))))

		# 横向铺开的偏移方向第一趟就存好了，这里直接用（省得同一循环里重复声明变量）
		var half: int = track_width / 2
		for s in track_width:
			var c: Vector2i = here + perp * (s - half)
			var key: String = "%d,%d" % [c.x, c.y]
			# 转角 tile 别被后来的直行覆盖，先到先得（先到的朝向更贴合这里）
			if not _tiles.has(key):
				_tiles[key] = {"item": item, "orient": orient, "mask": mask}

# ===========================================================================
# 红警2 连接掩码：认区块 / 查区块 / 校验连通
# ===========================================================================

## 照抄红警2「文件名带什么关键字就是什么块」的约定，去 MeshLibrary 认路区块。
##
## 红警2 里地形块叫 map unit，文件名 `1,1,1,1,01.map` 四个数字是东北/西北/
## 西南/东南四边的连通位，带 spawn 的强制当出生点块、分量归零（它不需要接别人）。
## 这里把同样的话翻译成：item 名字里带 straight / curve / corner / finish /
## start / ramp 的，就按这个语义归类。
##
## 这么做的工程价值：以后要在 MeshLibrary 里加三通块、十字块，
## 只要那个 item 名字带得对关键字，这边一行都不用改。
func _scan_library() -> bool:

	_tile_table.clear()
	_mask_cache.clear()

	var lib: MeshLibrary = gridmap.mesh_library
	if lib == null:
		push_error("[track] GridMap 没挂 MeshLibrary，认不出任何区块，铺什么进去都是空的")
		return false

	for item_id in lib.get_item_list():

		var name_: String = lib.get_item_name(item_id).to_lower()

		# 出生点块（finish / start / ramp）：红警2 里这类块四边分量归零，
		# 不参与连通校验，所以不进掩码表，由 _paint_finish_line 单独点名
		if _has_kw(name_, KW_SPAWN):
			continue

		var base: int = -1
		if _has_kw(name_, KW_STRAIGHT):
			base = MASK_STRAIGHT_BASE
		elif _has_kw(name_, KW_CURVE):
			base = MASK_CORNER_BASE

		# 既不是直道也不是弯道（forest / tents 之类装饰），不是路
		if base < 0:
			continue

		# base_orient = 这个 tile 在「局部 +Z 就是路面方向」时的 orientation 索引。
		# 掩码匹配出来的是「转了几下 k」，朝向就是 base_orient 再转 k 下。
		_tile_table[base] = {
			"item": int(item_id),
			"base_orient": _orient_for_dir(Vector3i(0, 0, 1)),
		}

	if _tile_table.is_empty():
		push_error("[track] MeshLibrary 里一个路区块都没认出来。item 名字得带 "
			+ "straight / curve / corner / finish / start / ramp 关键字，"
			+ "例如 track-straight / track-corner。当前 item 名：%s"
			% _list_item_names())
		return false

	if verbose:
		print("[track] 认出 %d 类路区块：%s" % [_tile_table.size(), _describe_table()])

	return true

func _has_kw(name_: String, kws: PackedStringArray) -> bool:

	for k in kws:
		if name_.contains(k):
			return true
	return false

func _list_item_names() -> String:

	var lib: MeshLibrary = gridmap.mesh_library
	var parts: PackedStringArray = PackedStringArray()
	for item_id in lib.get_item_list():
		parts.append(lib.get_item_name(item_id))
	return ", ".join(parts)

func _describe_table() -> String:

	var parts: PackedStringArray = PackedStringArray()
	for base in _tile_table.keys():
		parts.append("mask %d -> item %d" % [int(base), int(_tile_table[base]["item"])])
	return ", ".join(parts)

## 掩码整体旋转 k 次（每次 4 个 bit 往右挪一位）。
func _rotate_mask(mask: int, k: int) -> int:

	var out: int = 0
	for i in 4:
		if (mask & (1 << i)) != 0:
			out |= 1 << ((i + k) % 4)
	return out

## 连接掩码 -> tile。红警2 那句「相邻边必须对上」就落在这一个函数里：
## mask 对不上表里任何一项，就是「没有能跟邻居接上的块」= 断头路。
func _mask_tile(mask: int) -> Dictionary:

	if _mask_cache.has(mask):
		return _mask_cache[mask]

	var found: Dictionary = {}

	for base_key in _tile_table.keys():
		var base: int = int(base_key)
		for k in 4:
			if _rotate_mask(base, k) == mask:
				var e: Dictionary = _tile_table[base_key]
				found = {
					"item": int(e["item"]),
					"orient": _rotate_orient(int(e["base_orient"]), k),
				}
				break
		if not found.is_empty():
			break

	if found.is_empty():
		push_error("[track] 连接类型 mask=%d 在 MeshLibrary 里找不到能接的 tile。"
			+ "红警2 的做法是换一张对得上的图，这里就是少放 / 名字没带对关键字"
			% mask)

	_mask_cache[mask] = found
	return found

## orientation 转 k 下（每次 90°）。用引擎自己的 Basis 换算，不抄内部表。
func _rotate_orient(o: int, k: int) -> int:

	if k == 0:
		return o

	_ensure_orient_table()

	var b: Basis = gridmap.get_basis_with_orthogonal_index(o) * Basis.IDENTITY.rotated(UP, float(k) * PI * 0.5)
	var got: int = gridmap.get_orthogonal_index_from_basis(b)

	# 自证：转完还得是「+Y 朝天」的正交朝向，否则会悄悄铺出「竖起来的路」
	if got < _orient_fwd.size() and _orient_up[got] != Vector3i(0, 1, 0):
		push_warning("[track] orientation %d 转 %d 下之后不是朝天的，已退回 %d"
			% [o, k, o])
		return o
	return got

## 局部 +Z 要指到世界方向 d，该用哪个 orientation 索引。
func _orient_for_dir(d: Vector3i) -> int:

	_ensure_orient_table()

	for i in 24:
		if _orient_fwd[i] == d and _orient_up[i] == Vector3i(0, 1, 0):
			return i

	return 0

## ---------------------------------------------------------------------------
## 连通性校验：红警2 的硬规则，A 块朝东是 1，B 块朝西就必须是 1。
##
## **这里的掩码是「反推」出来的，不是预先算好的** —— 这是个踩出来的教训：
## 第一版按中心线推掩码（这一格朝哪走就通哪边），结果转角处翻车了。
## 因为路面有宽度：转角处横带会「部分重叠 + 外侧那排往外凸一格」，
## 设计上认为连着的那条边，实际铺出来对面根本没格子 —— 29 条边对不上。
## 红警2 也是看**真拼上去的块**相邻什么样，不是看设计意图，这里照做。
##
## 反推出来之后按三条验收：
##   1. 没有孤立格（deg == 0）
##   2. 没有末梢（deg == 1）—— 闭环里每格都该接 2 条边（宽路内部是 4 条）
##   3. flood fill 能走遍所有路面格 = 整条赛道是一连通块，没有断开的残段
##
## 断头路在游戏里的表现是「车开到一半撞上一堵看不见的墙」，运行时零报错，
## 所以必须在这里拦掉，不能等玩家撞上去。
## ---------------------------------------------------------------------------
func _verify_masks() -> bool:

	if _tiles.is_empty():
		push_error("[track] 一块路面都没铺出来，连通性校验没法做")
		return false

	# 1) 双向记账：本格朝 i 有路 <-> 邻居朝 (i+2) 有路
	var mask: Dictionary = {}
	for key in _tiles.keys():
		mask[key] = 0

	var edges: int = 0
	for key in _tiles.keys():
		# 必须显式写 PackedStringArray：key 是 Variant，`:=` 推不出类型会 Parse Error
		var p: PackedStringArray = key.split(",")
		var c: Vector2i = Vector2i(int(p[0]), int(p[1]))

		for i in 4:
			var nb: Vector2i = c + DIRS[i]
			if not _tiles.has("%d,%d" % [nb.x, nb.y]):
				continue
			mask[key] = int(mask[key]) | (1 << i)
			mask["%d,%d" % [nb.x, nb.y]] = int(mask["%d,%d" % [nb.x, nb.y]]) | (1 << ((i + 2) % 4))
			edges += 1

	# 2) 度数统计 + 写回诊断字段
	var deg0: int = 0
	var deg1: int = 0
	var deg2: int = 0
	for key in mask.keys():
		var m: int = int(mask[key])
		_tiles[key]["mask"] = m
		var pop: int = 0
		for i in 4:
			if (m & (1 << i)) != 0:
				pop += 1
		if pop == 0:
			deg0 += 1
		elif pop == 1:
			deg1 += 1
		elif pop == 2:
			deg2 += 1

	# 3) flood fill：整条路必须是一连通块
	var reach: int = _flood_road()

	if deg0 > 0 or deg1 > 0 or reach != _tiles.size():
		# 括号必须把**整段拼接**一起套住再 % ：
		# GDScript 里 `%` 的优先级高于 `+`，写成 (A + B % args) 的话格式化只作用在 B 上，
		# A 里的 %d/%s 原样漏出去，还会报一句
		# "not all arguments converted during string formatting"（很不好定位）
		push_error((("[track] 赛道连通性校验失败：孤立格 %d、末梢 %d、"
			+ "flood 只走到 %d / %d 格。通常是转角处横带错位（把 track_width 调成 3）")
			% [deg0, deg1, reach, _tiles.size()]))
		return false

	if verbose:
		print("[track] 连通性校验通过：%d 格路，%d 条连接边，deg==2 的 %d 格"
			% [_tiles.size(), edges / 2, deg2])
	return true

## 从第一格路面 flood fill，返回能走到的格数。
func _flood_road() -> int:

	var pool: Array = []
	for key in _tiles.keys():
		pool.append(key)
	if pool.is_empty():
		return 0

	var seen: Dictionary = {}
	var stack: Array[Vector2i] = []
	var first: PackedStringArray = pool[0].split(",")
	var c0: Vector2i = Vector2i(int(first[0]), int(first[1]))
	stack.append(c0)
	seen["%d,%d" % [c0.x, c0.y]] = true

	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for d in DIRS:
			var nb: Vector2i = c + d
			var nkey: String = "%d,%d" % [nb.x, nb.y]
			if seen.has(nkey) or not _tiles.has(nkey):
				continue
			seen[nkey] = true
			stack.append(nb)

	return seen.size()

## tile 建模时朝向 +Z，转到 dir 方向要绕 Y 转多少。
## 绕 Y 转 θ 之后 +Z 变成 (sinθ, 0, cosθ)，所以 θ = atan2(dx, dz)。
func _angle_for(dir: Vector2i) -> float:
	return atan2(float(dir.x), float(dir.y))

## ---------------------------------------------------------------------------
## 角度 -> GridMap 要的 int 正交索引。这是本文件最坑的一段，四个坑一次踩齐：
##   1. set_cell_item(cell, item_id, orientation) 第 3 参是 **int**，不是 Basis。
##      照着 4.0/4.1 老教程传 Basis，直接 Parse Error。
##   2. Basis.get_orthogonal_index() 在 4.7 里**不存在**，BaseBasis 单例在
##      GDScript 里也访问不到（Identifier not declared）。
##   3. 网上能查到的引擎 _ortho_bases 24 项是内部实现细节，抄进来一遇版本
##      升级就悄悄错位 —— 路面莫名其妙朝错方向，还不报错。
##   4. 想「反推」也不行：4.7 的 GridMap.get_cell_item_orientation() 返回的是
##      **int**，没有 Basis 版本；headless 下 GridMap 压根不建子节点，
##      get_child_count() 恒为 0，靠读子 transform 的路子也是死的。
##
## 正解（Godot 4.7 把这三个方法放在 GridMap 上，的类上的没有）：
##     GridMap.get_basis_with_orthogonal_index(int) -> Basis
##     GridMap.get_orthogonal_index_from_basis(Basis) -> int
##     GridMap.get_cell_item_basis(Vector3i) -> Basis
## 只要有一个 GridMap 在手，索引 <-> 朝向就完全自洽，且跟引擎版本无关。
## ---------------------------------------------------------------------------

## 建「orientation 索引 -> 朝向」对照表。只跑一次，结果缓存。
func _ensure_orient_table() -> void:

	if not _orient_fwd.is_empty():
		return

	_orient_fwd.clear()
	_orient_up.clear()
	_flat_orients.clear()

	for i in 24:
		var b: Basis = gridmap.get_basis_with_orthogonal_index(i)
		# Basis 的三列就是局部 x/y/z 轴在世界里指哪
		_orient_fwd.append(_snap_dir(b.z))
		_orient_up.append(_snap_dir(b.y))
		if _orient_up[i] == Vector3i(0, 1, 0):
			_flat_orients.append(i)

	if _flat_orients.is_empty():
		push_error("[track] 一个「+Y 朝天」的 orientation 都读不出来，"
			+ "八成是 MeshLibrary 没加载成功，后面铺出来的路会全是黑的")

## 任意向量 -> 最接近的格方向（±X / ±Y / ±Z），用于比对朝向。
func _snap_dir(v: Vector3) -> Vector3i:

	var ax: float = absf(v.x)
	var ay: float = absf(v.y)
	var az: float = absf(v.z)
	if ax >= ay and ax >= az:
		return Vector3i(1 if v.x >= 0.0 else -1, 0, 0)
	if ay >= az:
		return Vector3i(0, 1 if v.y >= 0.0 else -1, 0)
	return Vector3i(0, 0, 1 if v.z >= 0.0 else -1)

## 角度 -> orientation int。找不到（几乎不可能）就退化成索引 0 并告警。
func _angle_index(ang: float) -> int:

	_ensure_orient_table()

	var want: Vector3i = _snap_dir(Vector3(sin(ang), 0.0, cos(ang)))

	for i in 24:
		if _orient_fwd[i] == want and _orient_up[i] == Vector3i(0, 1, 0):
			return i

	# 兜底：直接问引擎（走同一套正交索引，结果一定一致）
	if gridmap.has_method("get_orthogonal_index_from_basis"):
		return gridmap.get_orthogonal_index_from_basis(Basis.IDENTITY.rotated(UP, ang).orthonormalized())

	push_warning("[track] 找不到朝向 %s 的 orientation，退回 0" % str(want))
	return 0

## 装饰物朝向：只在「+Y 朝天」的那批索引里随机，别把树倒着种。
func _decor_orient() -> int:
	_ensure_orient_table()
	if _flat_orients.is_empty():
		return 0
	return _flat_orients[_ri(_flat_orients.size())]

## 起跑点：赛道第 0 格换成出生点块（finish tile）。
##
## 照红警2 的 spawn 语义走：文件名带 finish/start 的**强制**当出生点块，
## 而且这类块在红警2 里「分量归零」—— 它四边都不跟别块接，是特例块。
## 这里对应的是：出生点格不按连接掩码校验连通性，由 _verify_masks 跳过。
func _paint_finish_line() -> void:

	if _route.is_empty():
		return

	# 去 MeshLibrary 里按关键字找，别硬编码 item 编号：
	# ITEM_FINISH 那套数字是手抄 mesh-library.tres 的顺序，那个文件一改就全乱
	var spawn_item: int = _find_item_by_kw(KW_SPAWN)
	if spawn_item < 0:
		push_warning("[track] MeshLibrary 里没有名字带 finish/start 的出生点块，"
			+ "起跑线这格先跳过（不影响其余格）")
		return

	var c: Vector2i = _route[0]
	var in_dir: Vector2i = c - _route[_route.size() - 1]
	if in_dir == Vector2i.ZERO:
		in_dir = DIRS[0]

	_tiles["%d,%d" % [c.x, c.y]] = {
		"item": spawn_item,
		"orient": _orient_for_dir(Vector3i(in_dir.x, 0, in_dir.y)),
		# 出生点块分量归零：给个全通标记，让 _verify_masks 认出它是特例、跳过校验
		"mask": MASK_ALL,
	}

	# 发车后的第一个坡（ramp）。默认关：开着开着突然被弹飞对街机手感是负分，
	# 需要的时候在检查器里开（红警2 的 spawn 区周围也有一小片特殊地形）
	if spawn_ramp and _route.size() > 2:
		var rc: Vector2i = _route[1]
		var rdir: Vector2i = _route[2] - rc
		if rdir != Vector2i.ZERO:
			_tiles["%d,%d" % [rc.x, rc.y]] = {
				"item": ITEM_RAMP,
				"orient": _orient_for_dir(Vector3i(rdir.x, 0, rdir.y)),
				"mask": MASK_ALL,
			}

## 按关键字在 MeshLibrary 里找区块（红警2 的「文件名带什么就是什么块」）。
func _find_item_by_kw(kws: PackedStringArray) -> int:

	var lib: MeshLibrary = gridmap.mesh_library
	if lib == null:
		return -1

	for item_id in lib.get_item_list():
		if _has_kw(lib.get_item_name(item_id).to_lower(), kws):
			return int(item_id)

	return -1

func _is_spawn_item(item_id: int) -> bool:

	var lib: MeshLibrary = gridmap.mesh_library
	if lib == null:
		return false
	return _has_kw(lib.get_item_name(item_id).to_lower(), KW_SPAWN)

# ===========================================================================
# 装饰物
# ===========================================================================

## 硬规则：装饰物只许长在「离路面至少 deco_margin 格」的地方。
## 贴着路边种树 = 入弯就撞柱子，这类问题一旦出现很难靠调参救回来。
func _scatter_decor() -> void:

	if deco_items.is_empty() or gridmap == null:
		return

	var lib: MeshLibrary = gridmap.mesh_library

	# 候选格：路面上每个格往外扩 deco_margin ~ deco_margin+reach 圈
	var seeds: Array[Vector2i] = []
	for key in _tiles.keys():
		# 必须显式写 PackedStringArray：key 是 Variant，`:=` 推不出类型会 Parse Error
		var p: PackedStringArray = key.split(",")
		seeds.append(Vector2i(int(p[0]), int(p[1])))

	for c in seeds:
		for r in range(deco_margin, deco_margin + deco_reach):
			for d in DIRS:
				var c2: Vector2i = c + d * r
				var key: String = "%d,%d" % [c2.x, c2.y]
				if _tiles.has(key):
					continue
				if _decor_has(c2):
					continue
				if _ri(100) >= int(clampf(deco_density, 0.0, 1.0) * 100.0):
					continue
				_decor.append({
					"cell": Vector3i(c2.x, road_layer, c2.y),
					"item": deco_items[_ri(deco_items.size())],
				})
				break

func _decor_has(c: Vector2i) -> bool:
	for d in _decor:
		if (d["cell"] as Vector3i).x == c.x and (d["cell"] as Vector3i).z == c.y:
			return true
	return false

# ===========================================================================
# 兜底地面 + 材质断言
# ===========================================================================

## 兜底地面。「没贴图」可以，「没亮度」不行 ——
## 这张平面一定带 StandardMaterial + 明确的 albedo，纯色但绝对是亮的。
func _build_floor() -> void:

	if floor_parent == null:
		return

	if _floor != null and is_instance_valid(_floor):
		_floor.queue_free()

	var mi := MeshInstance3D.new()
	mi.name = "TrackFloor"
	mi.position = Vector3(0, floor_y, 0)

	var plane := PlaneMesh.new()
	plane.size = Vector2(floor_size, floor_size)
	plane.subdivide_width = 4
	plane.subdivide_depth = 4
	mi.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = floor_color
	mat.roughness = 0.95
	mat.metallic = 0.0
	mat.vertex_color_use_as_albedo = true
	mi.material_override = mat

	floor_parent.add_child(mi)
	_floor = mi

## 【防黑断言】直接去 MeshLibrary 里查每个要用的 tile 有没有内嵌材质。
## 这是「通用防黑提示词」第 1、6 条唯一能被机械验证的做法：
## 材质挂错位置（挂到节点上而不是网格内部）在运行时完全不报错，
## 只在画面上表现为一片黑 —— 等到看见黑块再查就太晚了。
func _audit_library() -> bool:

	var lib: MeshLibrary = gridmap.mesh_library
	if lib == null:
		push_error("[track] GridMap 没挂 MeshLibrary，铺什么进去都是空的")
		return false

	var need: Array[int] = [ITEM_STRAIGHT, ITEM_CORNER, ITEM_FINISH]
	if deco_items.is_empty() == false:
		need.append_array(deco_items)

	var ok: bool = true

	for item_id in need:
		var mesh_: Mesh = lib.get_item_mesh(item_id)
		if mesh_ == null:
			push_error("[track] MeshLibrary 里 item %d 没有 mesh" % item_id)
			ok = false
			continue

		# Godot 4.7 的 Mesh 上没 get_material_slot_count()，用 surface 数代替：
		# 0 个 surface = 0 个材质槽 = 铺出来必是黑块
		var slots: int = mesh_.get_surface_count()
		if slots == 0:
			push_error("[track] MeshLibrary item %d 是**裸网格**（0 个 surface，没有内嵌材质）→ 铺出来必是黑块" % item_id)
			ok = false
			continue

		var mat: Material = mesh_.surface_get_material(0)
		if mat == null:
			push_error("[track] MeshLibrary item %d 的槽 0 是空材质" % item_id)
			ok = false
			continue

		var sm: StandardMaterial3D = mat as StandardMaterial3D
		if sm != null:
			var c: Color = sm.albedo_color
			var lum: float = maxf(maxf(c.r, c.g), c.b)
			if lum < 0.12:
				push_error("[track] MeshLibrary item %d 反照色太暗 (%.2f < 0.12)" % [item_id, lum])
				ok = false

	if verbose:
		print("[track] MeshLibrary 自检：用到 %d 类 tile，%s" % [need.size(), "全部带内嵌材质" if ok else "有用例没通过"])
	return ok

# ===========================================================================
# 落盘
# ===========================================================================

## 一次性批量写进 GridMap。set_cell_item 比一个个 add_child 快一两个数量级。
func _apply_to_gridmap() -> void:

	if gridmap == null:
		return

	if clear_first:
		gridmap.clear()

	for key in _tiles.keys():
		var p: PackedStringArray = key.split(",")
		var info: Dictionary = _tiles[key]
		gridmap.set_cell_item(
			Vector3i(int(p[0]), road_layer, int(p[1])),
			info["item"],
			info["orient"])

	for d in _decor:
		var cell: Vector3i = d["cell"]
		var item: int = d["item"]
		gridmap.set_cell_item(cell, item, _decor_orient())

# ===========================================================================
# 可复现随机数（不依赖 Godot 全局 randomize，同一个 seed 一定出同一条赛道）
# ===========================================================================

func _reseed(s: int) -> void:
	# 0 当「随机」用；非 0 当「复现」用
	_s = s if s != 0 else int(Time.get_unix_time_from_system()) & 0x7fffffff
	if _s <= 0:
		_s = 1

func _rnd() -> float:
	# 64 位 LCG，取高位（低位周期短）
	_s = (_s * 6364136223846793005 + 1442695040888963407) & 0x7fffffffffffffff
	# 除数必须是 2^52：_s 被 mask 到 63 位，_s >> 11 最大只能到 2^52 - 1。
	# 拿 2^53 当除数会让返回值永远 < 0.5 —— 于是 _ri(2) 恒等于 0、
	# _ri_range(8, 16) 只取到 8~11，帐篷铺不出来、赛道角点永远偏少，
	# 而且**一点报错都没有**，只表现为"形状不太有机"。
	return float(_s >> 11) / 4503599627370496.0

func _ri(n: int) -> int:
	return int(_rnd() * float(n))

func _ri_range(a: int, b: int) -> int:
	if b <= a:
		return a
	return a + _ri(b - a + 1)
