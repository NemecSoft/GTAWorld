extends Control

## 右上角小地图。
##
## 【为什么从"SubViewport + 俯视正交相机"退回"按真实格子画"】
## 第一版按社区标准做法（Godot 官方 Viewport 教程、gameidea.org 的开源
## onlybits/godot-3d-minimap、GameDev.TV 的 Godot 4 联机课 minimap 章节）：
## SubViewport 里放一个俯视正交 Camera3D，直接渲染真实几何，配 cull_mask
## 把车标记单开一个 render layer。
##
## 接线全通之后（world 共享 = true、相机朝向/包围盒/标记朝向都实测正确），
## 渲染目标里**只有天空 + 车标记，地形一块都渲染不出来**。
## 交叉验证过：往相机正下方丢一个 layer1 的亮品红方块当 Signal，
## 同帧同相机同 cull_mask 的地形和方块都不出现，而同属 layer2 的标记正常；
## cull_mask 归零后仍然是纯天空（天空是相机背景，不受 cull_mask 管，所以
## 当时差点误判成"没重绘"）。结论：这个 build 的「共享世界的子视口只渲染
## 自己子树」这条路径是坏的，跟接线无关。
##
## 所以改成**数据驱动**：小地图画的就是 GridMap 自己的格子数据 +
## 车的真实世界坐标。地形和车用的是同一套数、同一个变换，
## **对齐是构造上保证的**，不需要第二次 3D 渲染 —— 也顺带省掉一整个渲染通道。
## （网格地图的 2D 俯视图本来就是这套数据的标准画法，
##   跟 Godot 编辑器自己的网格小地图是一回事。）
##
## 【坐标/朝向约定】
## * 屏幕右 = 世界 +X，屏幕下 = 世界 +Z（俯视、不跟车头转，图是钉死的）。
## * 车头 yaw=0 时朝 +Z（见 vehicles/vehicle.gd 的 _forward_from_yaw），
##   所以屏幕上的车头方向 = (forward.x, forward.z)。
## * GridMap 节点自带 0.75 缩放、cell_size=(9.99,1,9.99)：格子世界坐标必须走
##   _grid.transform * (cell_size * 格子下标) 手算（4.7 的 GridMap 没有
##   world_to_map / map_to_world），画出来的方块和渲染用的是同一个算式。

@export_group("小地图")
## 整图模式下地图在面板里留白的比例，免得赛道顶到边框上
@export_range(0.0, 0.5, 0.01) var padding: float = 0.08
## 标记离地高度（仅 follow 模式/未来 3D 标记用，现在纯 2D 不参与绘制）
@export_range(0.2, 6.0, 0.1) var marker_y: float = 1.35

@export_group("跟随模式（开放世界用）")
## true = 视野跟着玩家走、固定可视半径；false = 整张图压进面板（当前默认）
@export var follow_mode: bool = false
## 跟随模式下**赛道可见世界跨度**（米），面板横向正好装下这么多。
## 190px 的小地图上看 4 km² 整图会糊成一片，所以开放世界要开这个。
@export_range(20.0, 800.0, 5.0) var follow_span: float = 120.0

@export_group("车（按场景节点名找）")
@export var player_name: String = "Vehicle"
@export var enemy_names: Array[String] = [
	"vehicle-truck-green", "vehicle-truck-purple", "vehicle-truck-red",
]

@export_group("地形配色（按 item id）")
@export var col_bg: Color = Color8(16, 20, 26, 255)
@export var col_forest: Color = Color8(46, 104, 62, 255)
@export var col_tents: Color = Color8(38, 78, 96, 255)
@export var col_road: Color = Color8(58, 62, 72, 255)
@export var col_finish: Color = Color8(226, 200, 48, 255)
@export var col_ramp: Color = Color8(196, 106, 42, 255)

@export_group("标记/边框")
@export var col_border: Color = Color8(12, 14, 18, 255)
@export var col_edge: Color = Color8(158, 170, 186, 255)
@export var col_player: Color = Color8(240, 60, 62, 255)
@export var col_enemy: Color = Color8(196, 204, 212, 255)
@export_range(0.0, 4.0, 0.5) var border_width: float = 2.0
@export_range(0.0, 0.8, 0.02) var dim_alpha: float = 0.30

# item id：0 empty / 1 forest / 2 tents / 3 corner / 4 finish / 5 ramp / 6 straight
const IT_EMPTY := 0
const IT_FOREST := 1
const IT_TENTS := 2
const IT_FINISH := 4
const IT_RAMP := 5

var _grid: GridMap = null
## 场景根（从自己往上爬到顶）。别用 current_scene —— UI 挂着的场景未必就是装地图的
var _scene_root: Node = null
var _player_ref: Node = null
var _enemy_refs: Array = []

## 每格一个 [x0, z0, x1, z1, 颜色]（世界坐标），地图重建时重算
var _cells: Array = []
var _ncells: int = -1
## 屏幕坐标里的车：[pos, dir, is_player]
var _cars: Array = []
var _box_min := Vector2.ZERO
var _box_max := Vector2.ZERO
## 整图模式下的取景（整张地图的包围盒）
var _whole_center := Vector2.ZERO
var _whole_span: float = 200.0
## 当前取景（整图 = _whole_*，跟随 = 玩家附近）
var _span: float = 200.0
var _center := Vector2.ZERO


# Functions

func _ready() -> void:
	_bind()
	_collect_cells()
	_update_view()
	_process_cars()


func _bind() -> void:
	if _scene_root == null:
		var r: Node = self
		while r.get_parent() != null:
			r = r.get_parent()
		_scene_root = r
	if _scene_root == null:
		return
	if _grid == null:
		_grid = _find_grid(_scene_root)
	if _player_ref == null:
		_player_ref = _scene_root.find_child(player_name, true, false)
	_enemy_refs.clear()
	for nm in enemy_names:
		_enemy_refs.append(_scene_root.find_child(nm, true, false))


func _find_grid(from: Node) -> GridMap:
	if from == null:
		return null
	var q: Array = [from]
	while not q.is_empty():
		var n = q.pop_back()
		if n is GridMap:
			return n as GridMap
		for c in n.get_children():
			q.append(c)
	return null


## 把每个格子的世界 XZ 范围算出来。格子坐标 → 世界坐标必须走 GridMap 自己的
## transform 和 cell_size（节点带 0.75 缩放，cell_size 又是 9.99，手算必错）。
func _collect_cells() -> void:
	_cells.clear()
	if _grid == null:
		_grid = _find_grid(_scene_root)
	if _grid == null:
		_span = 200.0
		return
	var used: Array = _grid.get_used_cells()
	_ncells = used.size()
	if _ncells <= 0:
		_span = 200.0
		return

	var t: Transform3D = _grid.transform
	var cs: Vector3 = _grid.cell_size
	var x0 := 1e9
	var x1 := -1e9
	var z0 := 1e9
	var z1 := -1e9
	for c in used:
		var ci: Vector3i = c
		var a: Vector3 = t * (cs * Vector3(float(ci.x), 0.0, float(ci.z)))
		var b: Vector3 = t * (cs * Vector3(float(ci.x) + 1.0, 0.0, float(ci.z) + 1.0))
		x0 = min(x0, a.x, b.x)
		x1 = max(x1, a.x, b.x)
		z0 = min(z0, a.z, b.z)
		z1 = max(z1, a.z, b.z)
		var item: int = int(_grid.get_cell_item(ci))
		_cells.append([a.x, a.z, b.x, b.z, _cell_color(item)])
	if x0 > x1:
		_span = 200.0
		return
	_box_min = Vector2(x0, z0)
	_box_max = Vector2(x1, z1)
	_whole_center = (_box_min + _box_max) * 0.5
	_whole_span = maxf(_box_max.x - _box_min.x, _box_max.y - _box_min.y)
	_center = _whole_center
	_span = _whole_span


func _cell_color(item: int) -> Color:
	match item:
		IT_FOREST:
			return col_forest
		IT_TENTS:
			return col_tents
		IT_FINISH:
			return col_finish
		IT_RAMP:
			return col_ramp
		_:
			return col_road      # corner / straight / 其它都按路面画


## 世界 XZ → 面板像素。屏幕右 = +X，屏幕下 = +Z（俯视、不跟车头转）。
func _proj(wx: float, wz: float) -> Vector2:
	var s: Vector2 = size
	return Vector2((wx - _center.x) / _span * s.x * (1.0 + padding) + s.x * 0.5,
			(wz - _center.y) / _span * s.y * (1.0 + padding) + s.y * 0.5)


## 每帧刷取景：整图模式用整张地图的包围盒；跟随模式以玩家为中心、固定可视跨度。
func _update_view() -> void:
	if not follow_mode:
		_center = _whole_center
		_span = _whole_span
		return
	if _player_ref == null or not is_instance_valid(_player_ref):
		_bind()
	if _player_ref == null or not is_instance_valid(_player_ref):
		# 玩家还没出生（换场景 / 加载中）：退回整图，别让小地图闪成空白
		_center = _whole_center
		_span = _whole_span
		return
	var p: Vector3 = _player_ref.global_position
	_center = Vector2(p.x, p.z)
	# _proj 里世界跨度是放大 (1+padding) 倍才铺满面板的，这里除回去，
	# 保证 follow_span 就是"面板横向能看到的世界距离"
	_span = follow_span / (1.0 + padding)


var _frame: int = 0

func _process(_delta: float) -> void:
	_frame += 1
	if _grid == null or _scene_root == null:
		_bind()
		if _grid == null:
			return
	# 地图重建（mapgen 换种子 = clear + 重铺）才需要重画格子。
	# get_used_cells() 是 O(格数)，每帧全扫在开放世界里吃不消 —— 30 帧查一次。
	if _frame % 30 == 0 and _grid.get_used_cells().size() != _ncells:
		_collect_cells()
	_update_view()
	_process_cars()
	queue_redraw()


## 把车的真实世界坐标投到面板上，顺便取车头方向。
## 车头 = basis.z（vehicle.gd 里 yaw=0 时车头朝 +Z）；屏幕上的方向 = (x, z)。
func _process_cars() -> void:
	_cars.clear()
	var s: Vector2 = size
	var pad := 1.0 + padding
	for i in range(_enemy_refs.size() + 1):
		var n: Node = null
		if i == 0:
			n = _player_ref
		else:
			n = _enemy_refs[i - 1]
		if n == null or not is_instance_valid(n):
			continue
		var p: Vector3 = n.global_position
		var pv: Vector2 = _proj(p.x, p.z)
		# 画到面板外就丢掉（Control 会裁掉，省得白算）
		if pv.x < -20.0 or pv.y < -20.0 or pv.x > s.x + 20.0 or pv.y > s.y + 20.0:
			continue
		var f: Vector3 = n.global_basis.z
		var d := Vector2(f.x, f.z)
		if d.length_squared() > 0.0001:
			d = d.normalized()
		else:
			d = Vector2(0.0, 1.0)
		_cars.append([pv, d, i == 0])


# ---------------------------------------------------------------------------
# 面板外观
# ---------------------------------------------------------------------------

func _draw() -> void:
	var s: Vector2 = size
	if s.x < 16.0 or s.y < 16.0:
		return

	# 1) 底色
	draw_rect(Rect2(Vector2.ZERO, s), col_bg)

	# 2) 地形：一个格子一个实心矩形，坐标全来自 GridMap 自己的数据
	var pad0: float = s.x * padding * 0.5
	for c in _cells:
		var a: Vector2 = _proj(float(c[0]), float(c[1]))
		var b: Vector2 = _proj(float(c[2]), float(c[3]))
		# 跟随模式下视野外的格子直接跳过：开放世界里 _cells 会有几万条，
		# 全画一次 _draw 就废了（Control 不会替你剪裁）
		if a.x > s.x or b.x < 0.0 or a.y > s.y or b.y < 0.0:
			continue
		a -= Vector2(pad0, pad0)
		b += Vector2(pad0, pad0)
		draw_rect(Rect2(a, b - a), c[4])

	# 3) 压暗：3D 颜色（绿森林 / 灰路面）直接贴屏幕会过亮
	draw_rect(Rect2(Vector2.ZERO, s), Color(0.0, 0.0, 0.0, dim_alpha))

	# 4) 车标记：玩家是红色尖头箭头，AI 是灰点
	for car in _cars:
		var p: Vector2 = car[0]
		var d: Vector2 = car[1]
		var is_p: bool = car[2]
		if is_p:
			var perp := Vector2(d.y, -d.x)
			var tip := p + d * 8.0
			var b1 := p - d * 5.0 + perp * 5.5
			var b2 := p - d * 5.0 - perp * 5.5
			draw_colored_polygon([tip, b1, b2], col_player)
			draw_circle(p, 4.0, col_player)
		else:
			draw_circle(p, 3.0, col_enemy)

	# 5) 边框：draw_rect 是**实心填充**，要只留一圈必须画四条细矩形（当场踩过）
	var w: float = maxf(border_width, 1.0)
	draw_rect(Rect2(Vector2.ZERO, Vector2(s.x, w)), col_edge)
	draw_rect(Rect2(Vector2.ZERO, Vector2(w, s.y)), col_edge)
	draw_rect(Rect2(Vector2(0.0, s.y - w), Vector2(s.x, w)), col_edge)
	draw_rect(Rect2(Vector2(s.x - w, 0.0), Vector2(w, s.y)), col_edge)
